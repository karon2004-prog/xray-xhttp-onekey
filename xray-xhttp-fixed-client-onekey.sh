#!/bin/sh
set -eu

# Xray VLESS + XHTTP + REALITY fixed-parameter one-key installer.
# Usage: run this once as root on the NAT VPS/container. Client only needs to change IP and public port.

INTERNAL_PORT="443"
SNI="www.microsoft.com"
DEST="www.microsoft.com:443"

UUID="64400d0f-2870-4f3d-bc14-378e9ecf7b58"
PRIVATE_KEY="OBtbynsjUMvS42CWqySHQYh9vGDD-X2CR5yOzNKzj2Q"
PUBLIC_KEY="qxZkLiBxh3NalNffRLTr3WSoqbJ4TKw-2r4OgucHJhg"
SHORT_ID="c9eb70ff6bb64fbf"
XHTTP_PATH="/de9dec5a62ba"

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/etc/xray"
LOG_DIR="/var/log/xray"
DATA_DIR="/usr/local/share/xray"

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

install_deps() {
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl unzip jq openssl ca-certificates iproute2 >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip jq openssl ca-certificates iproute2 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl unzip jq openssl ca-certificates iproute >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip jq openssl ca-certificates iproute >/dev/null
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl unzip jq openssl ca-certificates iproute2 >/dev/null
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl unzip jq openssl ca-certificates iproute2 >/dev/null
  else
    echo "Unsupported OS: no known package manager found." >&2
    exit 1
  fi
}

xray_asset() {
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7) echo "Xray-linux-arm32-v7a.zip" ;;
    *) echo "Unsupported arch: $arch" >&2; exit 1 ;;
  esac
}

install_xray() {
  asset="$(xray_asset)"
  mkdir -p "$XRAY_DIR" "$LOG_DIR" "$DATA_DIR"
  url="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .browser_download_url')"
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "Cannot find Xray release asset: $asset" >&2
    exit 1
  fi
  rm -rf /tmp/xray-install
  mkdir -p /tmp/xray-install/out
  curl -fsL "$url" -o /tmp/xray-install/xray.zip
  unzip -oq /tmp/xray-install/xray.zip -d /tmp/xray-install/out
  install -m 755 /tmp/xray-install/out/xray "$XRAY_BIN"
  for f in geoip.dat geosite.dat; do
    if [ -f "/tmp/xray-install/out/$f" ]; then
      install -m 644 "/tmp/xray-install/out/$f" "$DATA_DIR/"
    fi
  done
}

stop_existing() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl stop xray >/dev/null 2>&1 || true
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service xray stop >/dev/null 2>&1 || true
  fi
  pkill -f "$XRAY_BIN run -config $XRAY_DIR/config.json" >/dev/null 2>&1 || true
}

write_config() {
  chmod 700 "$XRAY_DIR"
  cat >"$XRAY_DIR/config.json" <<EOF
{
  "log": {
    "access": "$LOG_DIR/access.log",
    "error": "$LOG_DIR/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $INTERNAL_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        },
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF
  chmod 600 "$XRAY_DIR/config.json"
  "$XRAY_BIN" run -test -config "$XRAY_DIR/config.json" >/dev/null
}

install_service() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $XRAY_DIR/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray >/dev/null
    systemctl restart xray
  elif command -v rc-service >/dev/null 2>&1; then
    cat >/etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="$XRAY_BIN"
command_args="run -config $XRAY_DIR/config.json"
pidfile="/run/xray.pid"
command_background=true
start_stop_daemon_args="--stdout $LOG_DIR/stdout.log --stderr $LOG_DIR/stderr.log"
depend() { need net; }
EOF
    chmod 755 /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
    rc-service xray restart
  else
    nohup "$XRAY_BIN" run -config "$XRAY_DIR/config.json" >"$LOG_DIR/nohup.log" 2>&1 &
  fi
}

write_client_template() {
  ENCODED_PATH="$(printf '%s' "$XHTTP_PATH" | sed 's#/#%2F#g')"
  TEMPLATE="vless://$UUID@YOUR_PUBLIC_IP:YOUR_PUBLIC_PORT?type=xhttp&security=reality&pbk=$PUBLIC_KEY&fp=chrome&sni=$SNI&sid=$SHORT_ID&path=$ENCODED_PATH&mode=auto&encryption=none#nat-xhttp"
  cat >/root/xray-xhttp-client-template.txt <<EOF
Only replace these two fields in your client:
- YOUR_PUBLIC_IP
- YOUR_PUBLIC_PORT

NAT rule example:
YOUR_PUBLIC_PORT -> this VPS/container internal port $INTERNAL_PORT/TCP

Client template:
$TEMPLATE

Fixed parameters:
UUID=$UUID
PublicKey=$PUBLIC_KEY
ShortID=$SHORT_ID
Path=$XHTTP_PATH
SNI=$SNI
InternalPort=$INTERNAL_PORT
EOF
  echo
  echo "========== Xray XHTTP REALITY installed =========="
  cat /root/xray-xhttp-client-template.txt
  echo "=================================================="
  echo "Saved to: /root/xray-xhttp-client-template.txt"
}

show_status() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl --no-pager --full status xray | sed -n '1,12p' || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service xray status || true
  fi
  ss -lntp 2>/dev/null | grep ":$INTERNAL_PORT " || true
}

need_root
install_deps
install_xray
stop_existing
write_config
install_service
write_client_template
show_status
