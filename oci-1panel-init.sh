#!/usr/bin/env bash
#
# ============================================================================
#  OCI Ubuntu 一键初始化脚本 v2（面向 Linux 小白，可视化管防火墙版）
# ============================================================================
#  适用：Oracle Cloud（甲骨文云）Ubuntu 实例，创建后第一次登录运行
#
#  这个脚本帮你做 5 件事：
#    1) 配好 IPv6（自动获取；甲骨文分配异常时可在顶部填静态地址兜底）
#    2) 网卡 MTU 设为 1500（公网更稳定）
#    3) 开启 TCP BBR（跑代理 / 下载更稳更快）
#    4) 关掉 iptables-persistent/netfilter-persistent（否则会和 1Panel 防火墙“打架”）
#    5) 安装 1Panel 面板（端口 65510），由它接管系统防火墙
#
#  用法（两步走）：
#    A. 用 22 端口 SSH 登录新 VPS
#    B. 切到 root 后运行：
#         sudo -i
#         bash <(curl -fsSL https://你的github地址/oci-1panel-init.sh)
#       （也可以先把脚本传到机器上，再  bash oci-1panel-init.sh）
#
#  脚本不做任何会让你断线的危险操作。
#  SSH 端口改成 65511、开放应用端口，都在 1Panel 面板里点几下完成，见脚本末尾说明。
# ============================================================================

set -euo pipefail

# ========================= 配置区（一般不用改） =========================
PANEL_PORT=65510          # 1Panel 面板端口
PANEL_LANG="zh"           # 面板语言：zh 或 en
MTU=1500                  # 网卡 MTU
ENABLE_BBR=true           # 是否开启 TCP BBR（代理/下载更好，建议 true）
DISABLE_NETFILTER=true    # 是否关闭 netfilter-persistent（必关，否则和面板打架）

# —— IPv6 静态兜底（99% 情况留空 "" 即可）——
# 如果装完发现 IPv6 仍然不通，去 OCI 控制台「实例 → IPv6 地址」抄下来填到这里，
# 重新跑一遍脚本即可。格式：地址/64，例如 2603:c024:c01e:837e:0:3480:bbd7:ea6e/64
STATIC_IPV6_ADDR=""
# =========================================================================

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info(){ echo -e "${GREEN}[OK]${NC} $*"; }
step(){ echo -e "${BLUE}[*] $*${NC}"; }
warn(){ echo -e "${YELLOW}[!] $*${NC}"; }
die(){  echo -e "${RED}[X] $*${NC}"; exit 1; }

# 必须是 root
[[ $EUID -eq 0 ]] || die "请用 root 运行：先执行  sudo -i  再跑本脚本"

# 必须是 Ubuntu
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "本脚本仅支持 Ubuntu，当前系统：${PRETTY_NAME:-unknown}"

step "系统：${PRETTY_NAME}   架构：$(dpkg --print-architecture)"

# 0) 静态 IPv6 地址格式预检（填了就必须带 /前缀长度，避免 netplan 报错）
if [[ -n "$STATIC_IPV6_ADDR" && ! "$STATIC_IPV6_ADDR" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
  die "STATIC_IPV6_ADDR 格式不对（当前：$STATIC_IPV6_ADDR），应为 地址/64，例如 2603:c024:c01e:837e:0:3480:bbd7:ea6e/64"
fi

# 1) 识别默认网卡
DEFAULT_ETH=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
[[ -n "$DEFAULT_ETH" ]] || DEFAULT_ETH=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
[[ -n "$DEFAULT_ETH" ]] || die "找不到默认网卡，无法继续"
info "默认网卡：$DEFAULT_ETH"

# 2) 写入 Netplan（IPv6 + MTU）——先备份、先校验、失败自动回滚，绝不留下坏配置
step "写入网络配置（IPv6 + MTU ${MTU}）"

# netplan 命令不存在则先装（正常 OCI 镜像自带，这里兜底防呆）
if ! command -v netplan >/dev/null 2>&1; then
  step "未找到 netplan，先安装 netplan.io"
  apt-get update -y && apt-get install -y netplan.io
fi

NETPLAN_DIR=/etc/netplan
NETPLAN_FILE="$NETPLAN_DIR/99-oci-init.yaml"
mkdir -p "$NETPLAN_DIR"

# 备份原有 netplan（含可能已存在的旧 99 文件），方便回滚
if ls "$NETPLAN_DIR"/*.yaml >/dev/null 2>&1; then
  BK="/root/netplan-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$BK" -C /etc netplan
  info "已备份原网络配置到：$BK"
fi
# 单独留一份旧 99 文件（如果有），校验失败时恢复它
OLD_99=""
if [[ -f "$NETPLAN_FILE" ]]; then
  OLD_99="/root/99-oci-init.yaml.old"
  cp -a "$NETPLAN_FILE" "$OLD_99"
fi

{
  echo "network:"
  echo "  version: 2"
  echo "  ethernets:"
  echo "    $DEFAULT_ETH:"
  echo "      dhcp4: true"
  echo "      mtu: $MTU"
  if [[ -n "$STATIC_IPV6_ADDR" ]]; then
    echo "      accept-ra: true"
    echo "      addresses:"
    echo "        - $STATIC_IPV6_ADDR"
  else
    echo "      dhcp6: true"
    echo "      accept-ra: true"
  fi
} > "$NETPLAN_FILE.tmp"

# 校验通过才落地；失败则恢复原状，避免坏配置在重启后让机器失联
mv "$NETPLAN_FILE.tmp" "$NETPLAN_FILE"
chmod 600 "$NETPLAN_FILE"
if ! netplan generate; then
  if [[ -n "$OLD_99" ]]; then
    cp -a "$OLD_99" "$NETPLAN_FILE"
  else
    rm -f "$NETPLAN_FILE"
  fi
  die "Netplan 配置校验失败，已恢复原配置并中止（机器网络不受影响）"
fi
netplan apply || warn "netplan apply 未立即生效，稍后可在面板里重启网络或重启机器试试"
sleep 12   # 多等一会儿，给路由通告(RA)/DHCPv6 足够时间

# IPv6 自检
step "检查 IPv6 全球地址是否拿到"
GLOBAL6=$(ip -6 addr show "$DEFAULT_ETH" | awk '/inet6/ {split($2,a,"/"); ip=a[1]; if (ip !~ /^fe80/ && ip !~ /^::1/) print ip}')
if [[ -n "$GLOBAL6" ]]; then
  info "已获得 IPv6 全球地址："
  echo "$GLOBAL6" | sed 's/^/      /'
else
  if [[ -z "$STATIC_IPV6_ADDR" ]]; then
    warn "未自动拿到 IPv6 全球地址（甲骨文部分实例的 DHCPv6 不通，属正常现象）。"
    warn "  解决：去 OCI 控制台复制本实例的 IPv6 地址，填到脚本顶部 STATIC_IPV6_ADDR，重跑本脚本；"
    warn "  或先 reboot 一次让网络重新初始化，再观察。"
  else
    warn "静态地址已写入但仍未生效，建议重启机器：  reboot"
  fi
fi

# 3) TCP BBR
if [[ "$ENABLE_BBR" == true ]]; then
  step "开启 TCP BBR"
  modprobe tcp_bbr 2>/dev/null || true
  cat > /etc/sysctl.d/99-oci-init.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p /etc/sysctl.d/99-oci-init.conf >/dev/null 2>&1 || true
  info "BBR 状态：拥塞控制=$(sysctl -n net.ipv4.tcp_congestion_control)  队列=$(sysctl -n net.core.default_qdisc)"
fi

# 4) 关闭 netfilter-persistent（关键！否则和 1Panel 防火墙双轨冲突、规则顺序漂移）
if [[ "$DISABLE_NETFILTER" == true ]]; then
  step "关闭 netfilter-persistent，避免与 1Panel 防火墙冲突"
  systemctl disable --now netfilter-persistent 2>/dev/null || true
  rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null || true
  info "已关闭 netfilter-persistent（防火墙以后完全由 1Panel 管理）"
fi

# 5) 安装 1Panel（在 /tmp 子 shell 里跑，装完即清，不在 root 目录留 60MB+ 垃圾）
if command -v 1pctl >/dev/null 2>&1; then
  warn "检测到 1Panel 已安装，跳过安装步骤"
else
  step "安装 1Panel（端口 ${PANEL_PORT}，语言 ${PANEL_LANG}）"
  if ! command -v curl >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y curl
  fi
  curl -fsSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh -o /tmp/1panel_quick_start.sh
  # --non-interactive 保证不卡在交互问询；--port / --lang 设定面板参数
  # 安装器会把端口写进 1pctl 和核心配置，并在装完自行等待端口就绪
  ( cd /tmp && bash /tmp/1panel_quick_start.sh --port "$PANEL_PORT" --lang "$PANEL_LANG" --non-interactive ) \
      | tee /tmp/1panel-install.log
  rm -rf /tmp/1panel-v2.*-linux-* /tmp/1panel_quick_start.sh 2>/dev/null || true

  # 验证：面板端口必须已在监听，没监听就是真异常，直接报错（不粉饰）
  sleep 3
  if ss -tln 2>/dev/null | grep -q ":$PANEL_PORT "; then
    info "1Panel 已在端口 $PANEL_PORT 正常监听"
  else
    echo
    warn "未检测到 $PANEL_PORT 端口在监听，安装可能未成功。"
    warn "排查：cat /tmp/1panel-install.log 看安装日志末尾的报错。"
  fi
fi

# 打印访问信息（v2 默认 http；账号/密码/安全入口在安装日志末尾，可用 1pctl user-info 复查）
PUB_IP=$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null || echo "你的服务器公网IP")
echo
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  初始化完成！${NC}"
echo "================================================================"
echo "1Panel 访问地址：  http://${PUB_IP}:${PANEL_PORT}"
echo
echo -e "${YELLOW}【重要】面板的账号 / 密码 / 安全入口：${NC}"
echo "  往上翻看安装输出的最后几行（已同时存到 /tmp/1panel-install.log）；"
echo "  随时可用命令查看：  1pctl user-info"
echo
echo -e "${YELLOW}接下来在面板里做 3 件事（全程可视化，不用敲命令）：${NC}"
echo "  1) 左侧【主机】→【防火墙】→ 点【启用 / 初始化】，让面板接管防火墙"
echo "     （面板启用防火墙时会自动放行当前 SSH 端口 22，不会把你踢下线；"
echo "       启用后确认列表里有 22 和 ${PANEL_PORT} 再继续下一步）"
echo "  2) 左侧【主机】→【SSH】→ 把端口改成 65511 并保存"
echo "     （面板会同时改 sshd 配置和防火墙；改完先用 65511 连一次确认能登，再考虑关 22）"
echo "  3) 以后装任何软件（代理、网站等），在【防火墙】里加一条对应端口的放行规则即可"
echo
echo -e "${YELLOW}提醒：${NC}"
echo "  - OCI 控制台的安全列表(安全组)默认全放行，一般不用动；"
echo "    若你收紧过，记得把 ${PANEL_PORT} / 65511 和你的应用端口也放进去，否则面板打不开。"
echo "  - 本脚本已关闭系统自带防火墙服务，以后所有端口都在 1Panel 面板里管理。"
echo -e "${GREEN}================================================================${NC}"
