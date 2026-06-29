#!/bin/bash
# ============================================================
# OCI Ubuntu 24.04 安全初始化脚本
#
# 特点：
#  - 适配 ARM / AMD 默认环境（自动识别网卡）
#  - Netplan 持久化 MTU 1500（公网稳定性优化）
#  - TCP BBR 拥塞控制优化
#  - IPv4/IPv6 双栈防火墙 + Docker 网络兼容 + 规则持久化
#  - 系统级最小白名单，高级策略由 1Panel 接管
# ============================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🚀 OCI Ubuntu 24.04 安全初始化${NC}"
echo -e "${BLUE}   功能：自动网卡识别 | MTU 1500 | TCP BBR | 双栈防火墙 | Docker 兼容${NC}"

# ------------------------------------------------------------
# 0. root 检查
# ------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 执行（sudo -i）${NC}"
    exit 1
fi

# ------------------------------------------------------------
# 1. 自动识别默认网卡
# ------------------------------------------------------------
echo -e "${GREEN}[1/6] 识别默认网卡${NC}"

# 优先通过默认路由精确提取网卡名，兼容 AMD(ens3) / ARM(enp0s6) 及未来命名
DEFAULT_ETH=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
[ -z "$DEFAULT_ETH" ] && DEFAULT_ETH=$(ip route | awk '/default/ {print $5; exit}')
[ -z "$DEFAULT_ETH" ] && DEFAULT_ETH="eth0"

echo -e "${BLUE}   ℹ️ 网卡: ${DEFAULT_ETH}${NC}"

# ------------------------------------------------------------
# 2. 检查系统组件（OCI 已预装，此处仅作兜底）
# ------------------------------------------------------------
echo -e "${GREEN}[2/6] 检查系统组件${NC}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    apt-get install -y -qq iptables iptables-persistent >/dev/null
    echo -e "${BLUE}   ✅ 已安装 iptables-persistent${NC}"
else
    echo -e "${BLUE}   ℹ️  iptables-persistent 已存在，跳过${NC}"
fi

# ------------------------------------------------------------
# 3. MTU 1500（Netplan 持久化 + 立即生效）
# ------------------------------------------------------------
echo -e "${GREEN}[3/6] 设置 MTU 1500${NC}"

# 立即生效（OCI 默认 9000，公网环境下 1500 更稳定）
ip link set dev "$DEFAULT_ETH" mtu 1500 2>/dev/null || true

# 备份现有 Netplan 配置（异常时可恢复）
NETPLAN_BACKUP="/root/netplan-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$NETPLAN_BACKUP" -C /etc netplan 2>/dev/null || true

# 通过独立 Netplan 文件设置 MTU，与 OCI 默认 DHCP 配置共存
cat > /etc/netplan/99-oci-init.yaml <<EOF
network:
  version: 2
  ethernets:
    ${DEFAULT_ETH}:
      mtu: 1500
EOF

netplan apply >/dev/null 2>&1 || {
    echo -e "${YELLOW}   ⚠️  netplan apply 返回非零，配置已备份至 ${NETPLAN_BACKUP}${NC}"
}

echo -e "${BLUE}   ✅ MTU 1500 已设置（Netplan 持久化）${NC}"

# ------------------------------------------------------------
# 4. TCP BBR 拥塞控制优化
# ------------------------------------------------------------
echo -e "${GREEN}[4/6] 启用 TCP BBR${NC}"

# 加载 BBR 内核模块（Ubuntu 24.04 通常已内置）
modprobe tcp_bbr 2>/dev/null || true

# 写入 sysctl 配置并立即生效
cat > /etc/sysctl.d/99-oci-init.conf <<EOF
# OCI 网络优化
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-oci-init.conf >/dev/null 2>&1

# 验证
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
echo -e "${BLUE}   ✅ 拥塞控制: ${CURRENT_CC} | 队列算法: ${CURRENT_QDISC}${NC}"

# ------------------------------------------------------------
# 5. 双栈防火墙 + Docker 兼容
# ------------------------------------------------------------
echo -e "${GREEN}[5/6] 配置双栈防火墙（Docker 兼容）${NC}"

# ---- 5.1 清空旧规则（先临时放行，防止 SSH 断连）----
echo -e "${BLUE}   → 清空历史规则...${NC}"

# 关键保护：先临时全部放行，再清空规则，防止规则清空瞬间 SSH 连接中断
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT
ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT

# 清空所有链/表的历史规则
iptables -F; iptables -X; iptables -t nat -F; iptables -t mangle -F
ip6tables -F; ip6tables -X; ip6tables -t nat -F; ip6tables -t mangle -F

# ---- 5.2 设置默认策略（白名单模式）----
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT ACCEPT

# ---- 5.3 系统保命规则（双栈通用）----
# 本地环回 + 已建立/相关连接（conntrack 状态跟踪）
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# OCI 元数据服务（169.254.169.254，用于 cloud-init、实例配置、iSCSI 挂载）
iptables -A INPUT -s 169.254.169.254/32 -j ACCEPT
iptables -A OUTPUT -d 169.254.169.254/32 -j ACCEPT

# IPv6 基础：ICMPv6（邻居发现必需） + DHCPv6 客户端
ip6tables -A INPUT -p icmpv6 -j ACCEPT
ip6tables -A INPUT -s fe80::/10 -p udp --dport 546 -j ACCEPT

# ---- 5.4 DOCKER-USER 链（Docker 用户自定义规则入口）----
# Docker 启动时会在 FORWARD 链前部插入自身规则。
# DOCKER-USER 是 Docker 预留的"用户自定义规则"入口，不会被 Docker 覆盖。
# 将其插入 FORWARD 链最前端，确保用户规则优先于 Docker 默认规则。
iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER
iptables -I FORWARD 1 -j DOCKER-USER
iptables -A DOCKER-USER -j RETURN

# ---- 5.5 业务端口放行（IPv4/IPv6 双栈）----
# 系统层最小端口：22(SSH) / 80(HTTP) / 443(HTTPS) / 65510(1Panel)
PORTS=(22 80 443 65510)
for p in "${PORTS[@]}"; do
    iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
    ip6tables -A INPUT -p tcp --dport "$p" -j ACCEPT
    echo -e "${BLUE}   ✅ 放行 TCP/$p (IPv4/IPv6)${NC}"
done

# ---- 5.6 Docker 容器网络转发规则 ----
# 以下规则追加在 FORWARD 链末尾，处理 Docker 网桥流量：
# 1. 容器间通信（docker0 → docker0）
# 2. 容器访问外网（docker0 → 非 docker0）
# 3. 外网响应回容器（物理网卡 → docker0，仅已建立连接）
iptables -A FORWARD -i docker0 -o docker0 -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i docker0 ! -o docker0 -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -i "$DEFAULT_ETH" -o docker0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

# ------------------------------------------------------------
# 6. 规则持久化
# ------------------------------------------------------------
echo -e "${GREEN}[6/6] 持久化防火墙规则${NC}"

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

# 禁用 UFW（与 iptables 规则冲突，OCI 官方推荐直接使用 iptables）
systemctl disable --now ufw 2>/dev/null || true

# 启用 netfilter-persistent，确保开机自动加载规则
systemctl enable netfilter-persistent >/dev/null 2>&1 || true
systemctl restart netfilter-persistent >/dev/null 2>&1 || true

# ------------------------------------------------------------
# 完成
# ------------------------------------------------------------
echo -e "\n${GREEN}🎉 初始化完成！${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  配置摘要：${NC}"
echo -e "  • 网卡: ${DEFAULT_ETH} (MTU 1500)"
echo -e "  • TCP: ${CURRENT_CC} / ${CURRENT_QDISC}"
echo -e "  • 防火墙: INPUT DROP，已放行 22/80/443/65510"
echo -e "  • Docker: DOCKER-USER 链已就绪"
echo -e "  • 持久化: netfilter-persistent / Netplan"
echo ""
echo -e "${YELLOW}  后续步骤：${NC}"
echo -e "  1) OCI 控制台 → VCN → 安全列表 → 放行 TCP 22/80/443/65510"
echo -e '  2) 安装 1Panel：bash -c "$(curl -fsSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"'
echo -e "  3) 1Panel 防火墙页面管理后续端口（无需再手动改 iptables）"
echo -e "${GREEN}当前状态：系统级防火墙已锁定，Docker 已兼容，等待 1Panel 接管高级策略。${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
