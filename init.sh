#!/bin/bash
# ============================================================
# Oracle Cloud Ubuntu 24.04 安全初始化脚本 (1Panel 完美适配版)
# 功能：IPv4/IPv6 双栈防火墙 + Docker 底层兼容 + 规则持久化
# 设计：仅做系统级最小白名单，所有高级策略留给 1Panel 管理
# 适用：OCI 免费 tier / 付费实例，Ubuntu 24.04 全新系统
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}🚀 Oracle Cloud Ubuntu 24.04 双栈防火墙初始化 (1Panel适配版)${NC}"

# 必须 root 执行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 用户执行此脚本 (sudo -i)${NC}"
    exit 1
fi

# ------------------------------------------------------------
# 1. 安装必要组件
# ------------------------------------------------------------
echo -e "${GREEN}[1/6] 安装 iptables 持久化组件及 curl...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iptables iptables-persistent curl > /dev/null

# 自动识别默认网卡（OCI 通常是 ens3，也可能是 eth0）
DEFAULT_ETH=$(ip route | awk '/default/ {print $5; exit}')
[ -z "$DEFAULT_ETH" ] && DEFAULT_ETH="eth0"
echo -e "${BLUE}   ℹ️  检测到默认网卡: ${DEFAULT_ETH}${NC}"

# ------------------------------------------------------------
# 2. 清空旧规则 + 防 SSH 断连保护
# ------------------------------------------------------------
echo -e "${GREEN}[2/6] 清空残留防火墙规则（临时全放行防断连）${NC}"

# 关键：先临时全部放行，防止清空规则瞬间 SSH 断开
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT
ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT

# 清空所有链/表的历史规则
iptables -F; iptables -X; iptables -t nat -F; iptables -t mangle -F
ip6tables -F; ip6tables -X; ip6tables -t nat -F; ip6tables -t mangle -F

# ------------------------------------------------------------
# 3. 设置默认 DROP 策略（白名单模式）
# ------------------------------------------------------------
echo -e "${GREEN}[3/6] 设置默认安全 DROP 策略${NC}"
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT ACCEPT

# ------------------------------------------------------------
# 4. 系统保命规则（双栈通用 + OCI 特殊要求）
# ------------------------------------------------------------
echo -e "${GREEN}[4/6] 配置保命规则（lo、conntrack、元数据、IPv6基础）${NC}"

# 双栈通用：本地环回 + 已建立/相关的连接
for cmd in iptables ip6tables; do
    $cmd -A INPUT -i lo -j ACCEPT
    $cmd -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
done

# OCI 元数据服务（仅 IPv4，用于 cloud-init、iSCSI 挂载、实例配置）
# 169.254.0.0/16 是链路本地地址，必须放行否则实例可能异常
iptables -A INPUT -s 169.254.0.0/16 -j ACCEPT
iptables -A OUTPUT -d 169.254.0.0/16 -j ACCEPT

# IPv6 必须规则：ICMPv6（邻居发现等） + DHCPv6 客户端（OCI IPv6 地址分配可能依赖）
ip6tables -A INPUT -p icmpv6 -j ACCEPT
ip6tables -A INPUT -s fe80::/10 -d fe80::/10 -p udp --dport 546 -j ACCEPT

# ------------------------------------------------------------
# 5. 双栈放行业务端口（22 SSH, 80/443 Web, 10000 1Panel）
# ------------------------------------------------------------
echo -e "${GREEN}[5/6] 双栈放行 SSH / Web / 1Panel 端口${NC}"
PORTS=(22 80 443 10000)
for PORT in "${PORTS[@]}"; do
    iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
    ip6tables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
    echo -e "${BLUE}   ✅ 已放行端口: $PORT (IPv4/IPv6)${NC}"
done

# ------------------------------------------------------------
# 6. Docker 兼容 + 规则持久化
# ------------------------------------------------------------
echo -e "${GREEN}[6/6] 配置 Docker 网络支持并持久化规则${NC}"

# 开启内核 IPv4 转发（Docker 必需）
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 允许 Docker 容器与外网通信（2>/dev/null || true 防止 docker0 尚未创建时报错）
iptables -A FORWARD -i "$DEFAULT_ETH" -o docker0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i docker0 ! -o docker0 -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i docker0 -o docker0 -j ACCEPT 2>/dev/null || true

# 创建 DOCKER-USER 链并插入到 FORWARD 最前面
# 这是关键：Docker 启动时会在 FORWARD 前面插入自己的规则，
# 如果不把 DOCKER-USER 放到更前面，Docker 可能会覆盖你的自定义规则
iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER
iptables -A DOCKER-USER -j RETURN
iptables -I FORWARD -j DOCKER-USER

# 持久化规则
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

# 禁用与 iptables 冲突的 UFW（OCI 官方推荐直接用 iptables）
systemctl disable --now ufw 2>/dev/null || true
# 启用 netfilter-persistent 确保开机自动加载规则
systemctl enable --now netfilter-persistent 2>/dev/null || true

# ------------------------------------------------------------
# 完成提示
# ------------------------------------------------------------
echo -e "\n${GREEN}🎉 初始化完成！${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  重要提醒（请务必按顺序执行）：${NC}"
echo ""
echo -e "1️⃣  ${YELLOW}网页控制台放行端口${NC}"
echo "   登录 Oracle Cloud 控制台 → 虚拟云网络(VCN) → 安全列表(Security List)"
echo "   添加入站规则，放行 TCP: 22, 80, 443, 10000"
echo ""
echo -e "2️⃣ ${YELLOW}安装 1Panel${NC}"
echo "   bash -c \"\$(curl -fsSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)\""
echo ""
echo -e "3️⃣ ${YELLOW}后续管理建议${NC}"
echo "   - SSH 防暴力破解：在 1Panel 的【安全】→【Fail2ban】中启用"
echo "   - 防火墙策略：后续新增端口，优先在 1Panel 的【防火墙】页面操作"
echo "   - 国内访问优化：如需国内IP白名单，在 1Panel 中配置或后续脚本补充"
echo ""
echo -e "${GREEN}当前状态：系统级防火墙已锁定，Docker 已兼容，等待 1Panel 接管高级策略。${NC}"
