
#!/usr/bin/env bash
# OCI Ubuntu 26.04 LTS 基础初始化
# 功能：MTU 1500、IPv6 自动配置、BBR + fq
# 防火墙：只检查，不修改 iptables / ip6tables / nftables
# 适用架构：ARM64 / AMD64
# 不重启系统，不安装或初始化 1Panel

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="oci-ubuntu-init"
readonly NETPLAN_FILE="/etc/netplan/99-oci-init.yaml"
readonly SYSCTL_FILE="/etc/sysctl.d/99-oci-init.conf"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# ---------- 1. 基础检查 ----------

[[ "${EUID}" -eq 0 ]] || die "请使用 root 权限运行。"

[[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] || die "本脚本只支持 Ubuntu。"
[[ "${VERSION_ID:-}" == "26.04" ]] || \
    die "当前系统版本为 ${VERSION_ID:-未知}，本脚本仅针对 Ubuntu 26.04 LTS。"

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
case "$ARCH" in
    arm64|amd64) ;;
    *) die "不支持的 CPU 架构：${ARCH:-未知}。" ;;
esac

command -v ip >/dev/null 2>&1 || die "未找到 ip 命令。"
command -v netplan >/dev/null 2>&1 || die "未找到 netplan，请先检查系统网络组件。"

[[ -d /etc/netplan ]] || die "/etc/netplan 目录不存在。"

# 避免覆盖已有的同名文件
[[ ! -e "$NETPLAN_FILE" ]] || \
    die "$NETPLAN_FILE 已存在。为避免覆盖现有配置，脚本已停止；请先检查该文件。"

# ---------- 2. 自动识别默认网卡 ----------

DEFAULT_IFACE="$(
    ip -4 route show default 2>/dev/null |
    awk 'NR == 1 {
        for (i = 1; i <= NF; i++) {
            if ($i == "dev") {
                print $(i + 1)
                exit
            }
        }
    }'
)"

if [[ -z "$DEFAULT_IFACE" ]]; then
    DEFAULT_IFACE="$(
        ip -6 route show default 2>/dev/null |
        awk 'NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }'
    )"
fi

[[ -n "$DEFAULT_IFACE" ]] || die "无法识别默认网卡，请检查实例网络。"
ip link show dev "$DEFAULT_IFACE" >/dev/null 2>&1 || \
    die "识别出的网卡不存在：$DEFAULT_IFACE"

log "系统版本：Ubuntu ${VERSION_ID}"
log "CPU 架构：${ARCH}"
log "默认网卡：${DEFAULT_IFACE}"

# ---------- 3. 创建备份 ----------

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/oci-ubuntu-init-backup-${STAMP}"

mkdir -p "$BACKUP_DIR"
cp -a /etc/netplan "$BACKUP_DIR/netplan"

if [[ -e "$SYSCTL_FILE" ]]; then
    cp -a "$SYSCTL_FILE" "$BACKUP_DIR/99-oci-init.conf"
fi

log "原始配置已备份到：$BACKUP_DIR"

# ---------- 4. 添加 Netplan 补充配置 ----------
# 不指定 dhcp4，避免覆盖现有 IPv4 配置。
# 不指定静态 IPv6 地址或 IPv6 网关。
# Netplan 会将该文件与其他配置文件合并。

cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    ${DEFAULT_IFACE}:
      mtu: 1500
      dhcp6: true
      accept-ra: true
EOF

chmod 600 "$NETPLAN_FILE"

rollback_netplan() {
    warn "正在尝试恢复 Netplan 配置……"
    rm -f "$NETPLAN_FILE"

    if netplan generate; then
        netplan apply || warn "恢复后的 netplan apply 失败，请通过 OCI 控制台检查网络。"
    else
        warn "恢复后的 netplan generate 失败，请通过 OCI 控制台检查配置。"
    fi
}

if ! netplan generate; then
    rollback_netplan
    die "Netplan 配置校验失败，已尝试恢复。"
fi

log "Netplan 配置校验通过，正在应用网络设置……"

if ! netplan apply; then
    rollback_netplan
    die "Netplan 应用失败，已尝试恢复。"
fi

log "MTU 1500 和 IPv6 自动配置已写入并应用。"

# ---------- 5. 启用 BBR + fq ----------
# 仅在内核明确支持 BBR 时配置，不安装第三方内核或工具。

AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

if printf '%s\n' "$AVAILABLE_CC" | grep -qw bbr; then
    cat > "$SYSCTL_FILE" <<'EOF'
# OCI Ubuntu basic TCP tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    chmod 600 "$SYSCTL_FILE"

    if sysctl -p "$SYSCTL_FILE" >/dev/null; then
        log "BBR + fq 已启用并持久化。"
    else
        warn "BBR 参数应用失败，请检查内核及 sysctl 状态。"
    fi
else
    warn "当前内核未报告支持 BBR，跳过 BBR 配置。"
fi

# ---------- 6. 防火墙只读检查 ----------
# 不执行任何规则增删、清空、保存或服务启停操作。

printf '\n===== 防火墙只读检查 =====\n'

if command -v iptables >/dev/null 2>&1; then
    log "iptables："
    iptables -S INPUT 2>/dev/null | head -n 12 || true
else
    log "未安装 iptables 命令。"
fi

if command -v ip6tables >/dev/null 2>&1; then
    log "ip6tables："
    ip6tables -S INPUT 2>/dev/null | head -n 12 || true
else
    log "未安装 ip6tables 命令。"
fi

if command -v nft >/dev/null 2>&1; then
    log "nftables：仅检查规则集是否可读取。"
    nft list ruleset >/dev/null 2>&1 \
        && log "nftables 规则集可读取。" \
        || log "nftables 规则集为空或当前不可读取。"
else
    log "未安装 nft 命令。"
fi

# ---------- 7. 重新检查 IPv6 ----------
# 地址、路由和外网连通性分别判断，避免单项失败就下结论。

printf '\n===== IPv6 检查 =====\n'

GLOBAL_V6="$(
    ip -6 -o address show dev "$DEFAULT_IFACE" scope global 2>/dev/null |
    awk '{print $4}' || true
)"

V6_DEFAULT_ROUTE="$(
    ip -6 route show default dev "$DEFAULT_IFACE" 2>/dev/null || true
)"

if [[ -n "$GLOBAL_V6" ]]; then
    printf '全球单播 IPv6 地址：\n%s\n' "$GLOBAL_V6"
else
    warn "暂未发现全球单播 IPv6 地址。"
fi

if [[ -n "$V6_DEFAULT_ROUTE" ]]; then
    printf 'IPv6 默认路由：\n%s\n' "$V6_DEFAULT_ROUTE"
else
    warn "暂未发现该网卡的 IPv6 默认路由。"
fi

if command -v curl >/dev/null 2>&1; then
    if [[ -n "$GLOBAL_V6" && -n "$V6_DEFAULT_ROUTE" ]]; then
        if V6_TEST="$(curl -6 -fsS --connect-timeout 5 --max-time 8 \
            https://api6.ipify.org 2>/dev/null)"; then
            log "IPv6 外网连通性测试成功：${V6_TEST}"
        else
            warn "IPv6 外网连通性测试失败；请结合路由、DNS 和 OCI 网络设置排查。"
        fi
    else
        warn "缺少 IPv6 地址或默认路由，跳过外网连通性测试。"
    fi
else
    log "未安装 curl，跳过 IPv6 外网连通性测试。"
fi

# ---------- 8. 最终状态 ----------

printf '\n===== 初始化完成 =====\n'
printf '系统：Ubuntu %s (%s)\n' "$VERSION_ID" "$ARCH"
printf '默认网卡：%s\n' "$DEFAULT_IFACE"
printf '当前 MTU：'
ip -o link show dev "$DEFAULT_IFACE" | sed -n 's/.*mtu \([0-9]*\).*/\1/p'

printf '当前拥塞控制算法：'
sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true

printf '当前默认队列算法：'
sysctl -n net.core.default_qdisc 2>/dev/null || true

printf '备份目录：%s\n' "$BACKUP_DIR"
printf '\n防火墙规则未被本脚本修改。\n'
printf '未重启系统；建议确认 SSH 连接正常后再安装 1Panel。\n'

# ------------------------------------------------------------
# 9. 输出结果
# ------------------------------------------------------------
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
