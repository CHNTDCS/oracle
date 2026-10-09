
#!/bin/bash
# ============================================================
# OCI Ubuntu 26.04 LTS 安全初始化脚本
#
# 适用：Oracle Cloud ARM / AMD Ubuntu 26.04
# 功能：
#   1. 自动识别默认网卡
#   2. Netplan 持久化 MTU 1500
#   3. TCP BBR + fq
#   4. IPv4 / IPv6 基础防火墙
#   5. Docker DOCKER-USER 链兼容
#   6. iptables-persistent 规则持久化
#   7. 默认放行 WiFi Calling UDP 500 / 4500
#
# 注意：建议新系统首次安装 1Panel 前运行
# ============================================================

set -Eeuo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}OCI Ubuntu 26.04 安全初始化${NC}"

# ------------------------------------------------------------
# 0. 权限与系统版本检查
# ------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}请使用 root 执行：sudo -i${NC}"
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo -e "${RED}无法识别操作系统版本，退出。${NC}"
    exit 1
fi

. /etc/os-release

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
    echo -e "${RED}本脚本仅允许在 Ubuntu 26.04 上执行。${NC}"
    echo -e "${YELLOW}当前系统：${PRETTY_NAME:-unknown}${NC}"
    exit 1
fi

# 防止重复执行时意外清空已投入使用的防火墙规则
if [[ -e /etc/1panel ]] || systemctl is-active --quiet docker 2>/dev/null; then
    echo -e "${RED}检测到 1Panel 配置目录或正在运行的 Docker。${NC}"
    echo -e "${YELLOW}为避免破坏现有规则，请勿直接执行本初始化脚本。${NC}"
    echo "请先检查现有防火墙和 Docker 规则，再决定如何迁移。"
    exit 1
fi

# ------------------------------------------------------------
# 1. 自动识别默认网卡
# ------------------------------------------------------------
echo -e "${GREEN}[1/6] 识别默认网卡${NC}"

DEFAULT_ETH=$(ip -4 route show default |
    awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')

if [[ -z "$DEFAULT_ETH" ]]; then
    echo -e "${RED}未发现 IPv4 默认路由，无法安全配置网卡。${NC}"
    exit 1
fi

if ! ip link show dev "$DEFAULT_ETH" >/dev/null 2>&1; then
    echo -e "${RED}网卡不存在：${DEFAULT_ETH}${NC}"
    exit 1
fi

echo -e "${BLUE}默认网卡：${DEFAULT_ETH}${NC}"

# ------------------------------------------------------------
# 2. 检查并安装系统组件
# ------------------------------------------------------------
echo -e "${GREEN}[2/6] 检查系统组件${NC}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    # 避免安装时交互询问是否保存旧规则
    echo iptables-persistent iptables-persistent/autosave_v4 boolean false \
        | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false \
        | debconf-set-selections

    apt-get install -y iptables iptables-persistent netplan.io
else
    apt-get install -y iptables netplan.io
fi

for cmd in iptables ip6tables iptables-save ip6tables-save netplan; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}缺少必要命令：${cmd}${NC}"
        exit 1
    fi
done

# 确认 IPv6 防火墙可用
ip6tables -L -n >/dev/null

# ------------------------------------------------------------
# 3. MTU 1500：Netplan 持久化
# ------------------------------------------------------------
echo -e "${GREEN}[3/6] 设置 MTU 1500${NC}"

NETPLAN_DIR="/etc/netplan"
NETPLAN_FILE="${NETPLAN_DIR}/99-oci-init.yaml"
NETPLAN_BACKUP="/root/netplan-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

mkdir -p "$NETPLAN_DIR"

# 备份原始配置
if compgen -G "${NETPLAN_DIR}/*.yaml" >/dev/null; then
    tar -czf "$NETPLAN_BACKUP" -C /etc netplan
    echo -e "${BLUE}Netplan 备份：${NETPLAN_BACKUP}${NC}"
fi

# 先生成独立配置并验证合并后的 Netplan 配置
cat > "${NETPLAN_FILE}.tmp" <<EOF
network:
  version: 2
  ethernets:
    ${DEFAULT_ETH}:
      mtu: 1500
EOF

mv "${NETPLAN_FILE}.tmp" "$NETPLAN_FILE"

if ! netplan generate; then
    echo -e "${RED}Netplan 配置验证失败。${NC}"
    echo -e "${YELLOW}请检查 ${NETPLAN_FILE} 和其他 Netplan 文件。${NC}"
    exit 1
fi

# 立即生效
ip link set dev "$DEFAULT_ETH" mtu 1500

if ! netplan apply; then
    echo -e "${YELLOW}Netplan apply 失败，请检查配置和控制台连接。${NC}"
fi

# ------------------------------------------------------------
# 4. TCP BBR + fq
# ------------------------------------------------------------
echo -e "${GREEN}[4/6] 配置 TCP BBR${NC}"

modprobe tcp_bbr 2>/dev/null || true

cat > /etc/sysctl.d/99-oci-init.conf <<'EOF'
# OCI 网络基础优化
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl --system >/dev/null

CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
CURRENT_QDISC=$(sysctl -n net.core.default_qdisc)

if [[ "$CURRENT_CC" != "bbr" ]]; then
    echo -e "${YELLOW}BBR 未成功启用，请检查内核支持。${NC}"
fi

echo -e "${BLUE}拥塞控制：${CURRENT_CC} | 队列算法：${CURRENT_QDISC}${NC}"

# ------------------------------------------------------------
# 5. IPv4 / IPv6 基础防火墙
# ------------------------------------------------------------
echo -e "${GREEN}[5/6] 配置双栈防火墙${NC}"

# 警告：以下会清空现有 iptables / ip6tables 规则。
# 仅适用于新系统首次初始化，不应直接用于已有业务的主机。

# 5.1 先设置 ACCEPT，避免清理规则时立即中断现有连接
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

ip6tables -P INPUT ACCEPT
ip6tables -P FORWARD ACCEPT
ip6tables -P OUTPUT ACCEPT

# 清理 filter、nat、mangle、raw 表的旧规则
for table in filter nat mangle raw; do
    iptables -t "$table" -F
    iptables -t "$table" -X
    ip6tables -t "$table" -F
    ip6tables -t "$table" -X
done

# 5.2 默认策略：拒绝入站和转发，允许出站
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

# 5.3 本地环回与已建立连接
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# OCI 元数据服务（IPv4）
iptables -A INPUT -s 169.254.169.254/32 -j ACCEPT
iptables -A OUTPUT -d 169.254.169.254/32 -j ACCEPT

# IPv6：ICMPv6 邻居发现、路径 MTU 等基础功能
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

# DHCPv6 客户端响应（如使用 DHCPv6）
ip6tables -A INPUT -s fe80::/10 -p udp --sport 547 --dport 546 -j ACCEPT

# 5.4 基础 TCP 端口：22 / 80 / 443 / 65510
TCP_PORTS=(22 80 443 65510)

for p in "${TCP_PORTS[@]}"; do
    iptables -A INPUT -p tcp --dport "$p" \
        -m conntrack --ctstate NEW -j ACCEPT

    ip6tables -A INPUT -p tcp --dport "$p" \
        -m conntrack --ctstate NEW -j ACCEPT

    echo -e "${BLUE}放行 TCP/${p}（IPv4/IPv6）${NC}"
done

# 5.5 WiFi Calling：IKE / IPsec NAT-T
# UDP 500  = IKE
# UDP 4500 = IPsec NAT Traversal
WFC_UDP_PORTS=(500 4500)

for p in "${WFC_UDP_PORTS[@]}"; do
    iptables -A INPUT -p udp --dport "$p" \
        -m conntrack --ctstate NEW -j ACCEPT

    ip6tables -A INPUT -p udp --dport "$p" \
        -m conntrack --ctstate NEW -j ACCEPT

    echo -e "${BLUE}放行 UDP/${p}（IPv4/IPv6）${NC}"
done

# 5.6 DOCKER-USER 链
# Docker 尚未安装时预先创建规则入口。
# Docker 启动后会使用此链；RETURN 表示继续后续 Docker 规则处理。
iptables -N DOCKER-USER 2>/dev/null || true
iptables -C FORWARD -j DOCKER-USER 2>/dev/null ||
    iptables -I FORWARD 1 -j DOCKER-USER

iptables -C DOCKER-USER -j RETURN 2>/dev/null ||
    iptables -A DOCKER-USER -j RETURN

# 注意：不在这里手动开放全部 Docker 转发流量。
# 由 Docker 自身的网络规则及 1Panel 后续配置管理。

# ------------------------------------------------------------
# 6. 防火墙规则持久化
# ------------------------------------------------------------
echo -e "${GREEN}[6/6] 持久化防火墙规则${NC}"

mkdir -p /etc/iptables

iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

systemctl enable netfilter-persistent >/dev/null 2>&1
systemctl restart netfilter-persistent

# ------------------------------------------------------------
# 完成
# ------------------------------------------------------------
echo
echo -e "${GREEN}初始化完成！${NC}"
echo "=============================================="
echo "系统版本：${PRETTY_NAME}"
echo "默认网卡：${DEFAULT_ETH}"
echo "MTU：$(ip -o link show dev "$DEFAULT_ETH" |
    sed -n 's/.*mtu \([0-9]*\).*/\1/p')"
echo "TCP 拥塞控制：${CURRENT_CC}"
echo "队列算法：${CURRENT_QDISC}"
echo "入站默认策略：DROP"
echo "TCP 放行：22 / 80 / 443 / 65510"
echo "UDP 放行：500 / 4500（WiFi Calling）"
echo "IPv4 / IPv6：已配置"
echo "规则持久化：netfilter-persistent"
echo "=============================================="
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
