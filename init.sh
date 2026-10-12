#!/usr/bin/env bash
# ============================================================
# OCI Ubuntu 26.04 LTS 基础初始化
#
# 适用：Oracle Cloud ARM / AMD Ubuntu 26.04
# 功能：
#   1. 检查系统版本、权限和 CPU 架构
#   2. 自动识别默认网卡
#   3. Netplan 持久化 MTU 1500
#   4. TCP BBR + fq（内核支持时启用）
#   5. 备份配置、验证执行结果
#
# 防火墙策略：
#   - 不清空 iptables / ip6tables / nftables
#   - 不修改默认防火墙策略
#   - 不创建 1PANEL_* 或 DOCKER-USER 链
#   - 不安装或启用 iptables-persistent
#   - 不修改 SSH 端口或放行任何入站端口
#
# 端口规划：
#   当前 SSH：22
#   1Panel：65510
#   未来 SSH：65511
#
# 建议在新实例安装 1Panel 前运行
# ============================================================

set -Eeuo pipefail
umask 077

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

trap 'rc=$?; echo -e "${RED}[ERROR] 第 ${LINENO} 行执行失败，退出码 ${rc}${NC}" >&2; exit "$rc"' ERR

echo -e "${GREEN}"
echo "============================================================"
echo " OCI Ubuntu 26.04 基础初始化"
echo " 防火墙交由后续 1Panel 初始化和管理"
echo "============================================================"
echo -e "${NC}"

# ------------------------------------------------------------
# 1. 权限与系统版本检查
# ------------------------------------------------------------
[[ "$EUID" -eq 0 ]] || die "请使用 root 运行：sudo -i"

[[ -r /etc/os-release ]] || die "无法读取系统版本信息"
# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] ||
    die "仅支持 Ubuntu，当前系统：${PRETTY_NAME:-unknown}"

[[ "${VERSION_ID:-}" == "26.04" ]] ||
    die "本脚本仅支持 Ubuntu 26.04，当前：${VERSION_ID:-unknown}"

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    arm64|amd64) ;;
    *) die "不支持的 CPU 架构：$ARCH（仅支持 arm64 / amd64）" ;;
esac

for cmd in ip awk grep sysctl apt-get dpkg; do
    command -v "$cmd" >/dev/null 2>&1 ||
        die "缺少必要命令：$cmd"
done

# ------------------------------------------------------------
# 2. 自动识别默认网卡
# ------------------------------------------------------------
log "检测默认网卡"

DEFAULT_ETH="$(
    ip -4 route show default 2>/dev/null |
    awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'
)"

if [[ -z "$DEFAULT_ETH" ]]; then
    DEFAULT_ETH="$(
        ip -6 route show default 2>/dev/null |
        awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'
    )"
fi

[[ -n "$DEFAULT_ETH" ]] || die "未找到 IPv4 或 IPv6 默认路由"
[[ -e "/sys/class/net/$DEFAULT_ETH" ]] ||
    die "网卡不存在：$DEFAULT_ETH"

MAC="$(cat "/sys/class/net/$DEFAULT_ETH/address")"
[[ -n "$MAC" ]] || die "无法读取网卡 MAC 地址"

log "系统：${PRETTY_NAME}"
log "架构：${ARCH}"
log "默认网卡：${DEFAULT_ETH}"
log "MAC 地址：${MAC}"

ip -brief address show dev "$DEFAULT_ETH"

# ------------------------------------------------------------
# 3. 备份配置
# ------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/oci-init-backup-${STAMP}"

mkdir -m 700 -p "$BACKUP_DIR"

NETPLAN_DIR="/etc/netplan"
NETPLAN_FILE="${NETPLAN_DIR}/99-oci-init.yaml"
SYSCTL_FILE="/etc/sysctl.d/99-oci-init.conf"

mkdir -p "$NETPLAN_DIR"

# 备份现有 Netplan 文件和本脚本涉及的 sysctl 文件
if compgen -G "${NETPLAN_DIR}/*.yaml" >/dev/null; then
    tar -czf "${BACKUP_DIR}/netplan-backup.tar.gz" \
        -C /etc netplan
fi

if [[ -e "$NETPLAN_FILE" ]]; then
    cp -a "$NETPLAN_FILE" "${BACKUP_DIR}/99-oci-init.yaml"
fi

if [[ -e "$SYSCTL_FILE" ]]; then
    cp -a "$SYSCTL_FILE" "${BACKUP_DIR}/99-oci-init.conf"
fi

log "配置备份目录：${BACKUP_DIR}"

# ------------------------------------------------------------
# 4. 检查 Netplan
# ------------------------------------------------------------
if ! command -v netplan >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y netplan.io
fi

command -v netplan >/dev/null 2>&1 ||
    die "Netplan 安装失败"

# ------------------------------------------------------------
# 5. Netplan 持久化 MTU 1500
# ------------------------------------------------------------
log "配置 MTU 1500"

TMP_FILE="${NETPLAN_FILE}.tmp"

cat > "$TMP_FILE" <<EOF
network:
  version: 2
  ethernets:
    ${DEFAULT_ETH}:
      mtu: 1500
EOF

chmod 600 "$TMP_FILE"
mv "$TMP_FILE" "$NETPLAN_FILE"

# 验证合并后的 Netplan 配置
if ! netplan generate; then
    warn "Netplan 验证失败，恢复本脚本原有配置"

    if [[ -e "${BACKUP_DIR}/99-oci-init.yaml" ]]; then
        cp -a "${BACKUP_DIR}/99-oci-init.yaml" "$NETPLAN_FILE"
    else
        rm -f "$NETPLAN_FILE"
    fi

    netplan generate || true
    die "Netplan 配置验证失败，已尝试回滚"
fi

# 先设置当前 MTU，再应用持久化配置
ip link set dev "$DEFAULT_ETH" mtu 1500

if ! netplan apply; then
    warn "netplan apply 失败，尝试恢复本脚本之前的配置"

    if [[ -e "${BACKUP_DIR}/99-oci-init.yaml" ]]; then
        cp -a "${BACKUP_DIR}/99-oci-init.yaml" "$NETPLAN_FILE"
    else
        rm -f "$NETPLAN_FILE"
    fi

    netplan generate || true
    netplan apply || true

    die "Netplan 应用失败，请通过 OCI 控制台检查网络"
fi

CURRENT_MTU="$(cat "/sys/class/net/$DEFAULT_ETH/mtu")"
[[ "$CURRENT_MTU" == "1500" ]] ||
    die "MTU 验证失败，当前值：${CURRENT_MTU}"

log "MTU 当前值：${CURRENT_MTU}"
log "持久化配置：${NETPLAN_FILE}"

# ------------------------------------------------------------
# 6. TCP BBR + fq
# ------------------------------------------------------------
log "检测内核 BBR 支持"

modprobe tcp_bbr 2>/dev/null || true

AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

if awk -v cc="$AVAILABLE_CC" '
    BEGIN {
        n = split(cc, a, /[[:space:]]+/)
        for (i=1; i<=n; i++) if (a[i] == "bbr") found=1
        exit !found
    }'
then
    cat > "$SYSCTL_FILE" <<'EOF'
# OCI 基础 TCP 优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    chmod 644 "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE"

    CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control)"
    CURRENT_QDISC="$(sysctl -n net.core.default_qdisc)"

    [[ "$CURRENT_CC" == "bbr" ]] ||
        die "BBR 配置未生效"
    [[ "$CURRENT_QDISC" == "fq" ]] ||
        warn "fq 未能按预期生效，当前值：${CURRENT_QDISC}"

    log "BBR：${CURRENT_CC}"
    log "队列算法：${CURRENT_QDISC}"
else
    warn "当前内核未报告支持 BBR，本脚本不强制设置"
    warn "保留现有拥塞控制配置，不覆盖其他 sysctl 参数"
fi

# ------------------------------------------------------------
# 7. 防火墙安全检查（只检查，不修改）
# ------------------------------------------------------------
log "检查防火墙状态（不会修改规则）"

if command -v iptables >/dev/null 2>&1; then
    iptables -S INPUT 2>/dev/null || true
else
    warn "未发现 iptables 命令"
fi

if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -S INPUT 2>/dev/null || true
else
    warn "未发现 ip6tables 命令"
fi

if command -v nft >/dev/null 2>&1; then
    nft list ruleset 2>/dev/null || true
fi

# ------------------------------------------------------------
# 8. 输出结果
# ------------------------------------------------------------
echo
echo -e "${GREEN}"
echo "============================================================"
echo " 初始化完成"
echo "============================================================"
echo -e "${NC}"

echo "系统版本       : ${PRETTY_NAME}"
echo "CPU 架构       : ${ARCH}"
echo "默认网卡       : ${DEFAULT_ETH}"
echo "当前 MTU       : $(cat "/sys/class/net/$DEFAULT_ETH/mtu")"
echo "BBR 可用算法   : ${AVAILABLE_CC:-未知}"
echo "当前拥塞控制   : $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "当前队列算法   : $(sysctl -n net.core.default_qdisc)"
echo "备份目录       : ${BACKUP_DIR}"

echo
echo "防火墙处理     : 未修改"
echo "Docker 规则    : 未修改"
echo "SSH 配置       : 未修改"
echo "IPv6 地址/路由 : 未修改"
echo
echo "端口规划（不自动放行）："
echo "  当前 SSH     : TCP 22"
echo "  1Panel       : TCP 65510"
echo "  未来 SSH     : TCP 65511"
echo
echo -e "${YELLOW}后续建议：${NC}"
echo "1. 检查 OCI NSG / 安全列表中的入站规则。"
echo "2. 安装 1Panel。"
echo "3. 首次进入 1Panel 防火墙页面时执行初始化。"
echo "4. 应用端口和 SSH 端口变更由 1Panel / SSH 配置单独管理。"
echo
echo -e "${GREEN}完成。${NC}"
echo
echo -e "${YELLOW}后续操作：${NC}"
echo "1. OCI VCN 安全列表/NSG 检查相应入站规则"
echo "2. 安装 1Panel"
echo "3. 后续高级防火墙规则由 1Panel 管理"
echo
echo -e "${YELLOW}1Panel 安装命令：${NC}"
echo 'bash -c "$(curl -fsSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"'
echo
echo -e "${YELLOW}注意：执行前请确保 OCI 控制台允许所需入站端口。${NC}"
