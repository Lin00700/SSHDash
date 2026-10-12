import SwiftUI

/// 一键部署脚本。都是 POSIX sh，需要 root 权限。
/// 应用会在脚本前自动注入 SERVER_HOST 和参数变量（例如 PORT、SNI）。
enum Sh {
    static let common = #"""
[ "$(id -u)" = "0" ] || { echo "需要 root 权限，请用 root 用户登录后再运行"; exit 1; }

pm_install() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "$@"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  else
    echo "未识别的包管理器，请手动安装：$*"
    return 1
  fi
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    echo "sing-box 已安装：$(sing-box version | head -n 1)"
    return 0
  fi
  echo ">>> 安装 sing-box"
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache sing-box || { echo "apk 安装失败：请确认已启用 community 软件源"; return 1; }
  else
    command -v curl >/dev/null 2>&1 || pm_install curl ca-certificates
    command -v bash >/dev/null 2>&1 || pm_install bash
    curl -fsSL https://sing-box.app/install.sh | bash || return 1
  fi
  command -v sing-box >/dev/null 2>&1 || { echo "未找到 sing-box"; return 1; }
}

restart_singbox() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box
    sleep 1
    systemctl is-active sing-box
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add sing-box default >/dev/null 2>&1 || true
    rc-service sing-box restart
  else
    echo "未找到 systemd/openrc，请手动运行：sing-box run -c /etc/sing-box/config.json"
  fi
}

get_ip() {
  IP="$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$IP" ] || IP="$SERVER_HOST"
}

open_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$1/$2" >/dev/null 2>&1 && echo "已在 ufw 放行 $1/$2"
  fi
}

"""#

    static let baseEnv = common + #"""
set -e
echo ">>> 安装基础工具"
pm_install curl wget unzip ca-certificates
if command -v apk >/dev/null 2>&1; then
  pm_install bash openssl || true
else
  pm_install openssl || true
fi
echo ">>> 安装 vnstat（流量统计，失败可忽略）"
if pm_install vnstat; then
  systemctl enable --now vnstat >/dev/null 2>&1 || rc-update add vnstatd default >/dev/null 2>&1 || true
  rc-service vnstatd start >/dev/null 2>&1 || true
else
  echo "vnstat 安装失败，已跳过"
fi
echo "✅ 基础环境完成"
"""#

    static let bbr = common + #"""
echo "当前拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  modprobe tcp_bbr 2>/dev/null || true
fi
if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  echo "当前内核不支持 BBR（LXC/OpenVZ 等容器类 VPS 无法修改内核参数）"
  exit 1
fi
touch /etc/sysctl.conf
sed -i '/^net.core.default_qdisc/d;/^net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true
sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr
echo "现在拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)"
"""#

    static let docker = common + #"""
if command -v docker >/dev/null 2>&1; then
  echo "Docker 已安装：$(docker --version)"
  exit 0
fi
echo ">>> 安装 Docker"
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache docker docker-cli-compose
  rc-update add docker default >/dev/null 2>&1 || true
  rc-service docker start || true
else
  command -v curl >/dev/null 2>&1 || pm_install curl ca-certificates
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
fi
docker --version
"""#

    static let singboxInstall = common + #"""
install_singbox
echo "✅ 完成"
"""#

    static let reality = common + #"""
set -e
PORT="${PORT:-443}"
SNI="${SNI:-www.microsoft.com}"
install_singbox
mkdir -p /etc/sing-box
if [ -f /etc/sing-box/config.json ]; then
  cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)"
  echo "已备份原有配置"
fi

UUID="$(sing-box generate uuid)"
KEYS="$(sing-box generate reality-keypair)"
PRIV="$(echo "$KEYS" | grep -i 'PrivateKey' | awk '{print $2}')"
PUB="$(echo "$KEYS" | grep -i 'PublicKey' | awk '{print $2}')"
SID="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
  echo "生成 Reality 密钥失败"
  exit 1
fi

cat > /etc/sing-box/config.json <<CONF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [ { "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIV}",
          "short_id": [ "${SID}" ]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
CONF

sing-box check -c /etc/sing-box/config.json
open_port "$PORT" tcp
restart_singbox
get_ip
NAME="$(hostname)-reality"
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp#${NAME}"
echo "NODE_LINK=${LINK}" >> /etc/sing-box/nodes.txt
echo ""
echo "=== 部署完成 ==="
echo "NODE_LINK=${LINK}"
echo "提示：使用 AWS / Lightsail 等云厂商时，还需要在安全组/防火墙放行 TCP ${PORT}"
"""#

    static let hysteria2 = common + #"""
set -e
PORT="${PORT:-8443}"
SNI="${SNI:-bing.com}"
install_singbox
command -v openssl >/dev/null 2>&1 || pm_install openssl
mkdir -p /etc/sing-box
if [ -f /etc/sing-box/config.json ]; then
  cp /etc/sing-box/config.json "/etc/sing-box/config.json.bak.$(date +%s)"
  echo "已备份原有配置"
fi

PASS="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout /etc/sing-box/hy2.key -out /etc/sing-box/hy2.crt \
  -subj "/CN=${SNI}" -days 3650 >/dev/null 2>&1

cat > /etc/sing-box/config.json <<CONF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [ { "password": "${PASS}" } ],
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "/etc/sing-box/hy2.crt",
        "key_path": "/etc/sing-box/hy2.key"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
CONF

sing-box check -c /etc/sing-box/config.json
open_port "$PORT" udp
restart_singbox
get_ip
NAME="$(hostname)-hy2"
LINK="hysteria2://${PASS}@${IP}:${PORT}/?insecure=1&sni=${SNI}#${NAME}"
echo "NODE_LINK=${LINK}" >> /etc/sing-box/nodes.txt
echo ""
echo "=== 部署完成 ==="
echo "NODE_LINK=${LINK}"
echo "提示：Hysteria2 使用 UDP，云厂商安全组需要放行 UDP ${PORT}；客户端需允许不安全证书（insecure=1）"
"""#

    static let status = #"""
echo "=== sing-box 状态 ==="
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl status sing-box --no-pager 2>&1 | head -n 12
  echo ""
  echo "=== 最近日志 ==="
  journalctl -u sing-box -n 30 --no-pager 2>&1
elif command -v rc-service >/dev/null 2>&1; then
  rc-service sing-box status 2>&1
else
  if pidof sing-box >/dev/null 2>&1; then echo "sing-box 正在运行"; else echo "sing-box 未运行"; fi
fi
echo ""
echo "=== 监听端口 ==="
(ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null) | head -n 30
"""#

    static let restart = common + #"""
restart_singbox
echo "✅ 已重启"
"""#

    static let nodes = #"""
if [ -f /etc/sing-box/nodes.txt ]; then
  grep '^NODE_LINK=' /etc/sing-box/nodes.txt
else
  echo "还没有部署记录（只记录用本 App 部署的节点）"
fi
"""#
}

enum DeployTemplates {
    static let all: [DeployTemplate] = [
        DeployTemplate(
            id: "reality",
            title: "部署 VLESS + Reality 节点",
            subtitle: "自动安装 sing-box，生成 UUID/密钥，输出分享链接",
            icon: "bolt.shield",
            tint: Theme.cyan,
            params: [
                DeployParam(id: "PORT", label: "监听端口（TCP）", value: "443"),
                DeployParam(id: "SNI", label: "伪装域名（SNI）", value: "www.microsoft.com")
            ],
            script: Sh.reality,
            warning: "会覆盖 /etc/sing-box/config.json（旧配置自动备份为 .bak）"
        ),
        DeployTemplate(
            id: "hy2",
            title: "部署 Hysteria2 节点",
            subtitle: "自签证书，UDP 协议，输出分享链接",
            icon: "bolt.horizontal",
            tint: Theme.purple,
            params: [
                DeployParam(id: "PORT", label: "监听端口（UDP）", value: "8443"),
                DeployParam(id: "SNI", label: "证书域名（CN/SNI）", value: "bing.com")
            ],
            script: Sh.hysteria2,
            warning: "会覆盖 /etc/sing-box/config.json（旧配置自动备份为 .bak）"
        ),
        DeployTemplate(
            id: "nodes",
            title: "查看已部署节点",
            subtitle: "读取本 App 部署时保存的分享链接",
            icon: "link",
            tint: Theme.cyan,
            script: Sh.nodes
        ),
        DeployTemplate(
            id: "status",
            title: "服务状态与日志",
            subtitle: "sing-box 状态、最近日志、监听端口",
            icon: "waveform.path.ecg",
            tint: Theme.pink,
            script: Sh.status
        ),
        DeployTemplate(
            id: "restart",
            title: "重启 sing-box",
            subtitle: "systemd / openrc 自动识别",
            icon: "arrow.clockwise.circle",
            tint: Theme.purple,
            script: Sh.restart
        ),
        DeployTemplate(
            id: "singbox",
            title: "只安装 sing-box",
            subtitle: "官方安装脚本 / Alpine 用 apk",
            icon: "shippingbox",
            tint: Theme.cyan,
            script: Sh.singboxInstall
        ),
        DeployTemplate(
            id: "base",
            title: "基础环境",
            subtitle: "curl / wget / unzip / openssl / vnstat（流量统计）",
            icon: "wrench.and.screwdriver",
            tint: Theme.pink,
            script: Sh.baseEnv
        ),
        DeployTemplate(
            id: "bbr",
            title: "开启 BBR",
            subtitle: "fq + bbr；容器类 VPS 不支持",
            icon: "speedometer",
            tint: Theme.purple,
            script: Sh.bbr
        ),
        DeployTemplate(
            id: "docker",
            title: "安装 Docker",
            subtitle: "官方脚本 / Alpine 用 apk",
            icon: "cube.box",
            tint: Theme.cyan,
            script: Sh.docker
        )
    ]
}
