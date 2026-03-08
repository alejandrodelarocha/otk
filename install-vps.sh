#!/bin/bash
set -e

echo ""
echo "=== OTK VPS Installer ==="
echo ""

# Must be root
if [ "$(id -u)" != "0" ]; then
  echo "Run as root: sudo bash install-vps.sh"
  exit 1
fi

# ── Package manager detection ──────────────────────────────────────────────────
install_pkg() {
  if command -v apt-get &>/dev/null; then
    apt-get install -y -qq "$@"
  elif command -v yum &>/dev/null; then
    yum install -y -q "$@"
  elif command -v dnf &>/dev/null; then
    dnf install -y -q "$@"
  elif command -v apk &>/dev/null; then
    apk add --quiet "$@"
  else
    echo "ERROR: No supported package manager found (apt/yum/dnf/apk)"
    exit 1
  fi
}

update_pkg() {
  if command -v apt-get &>/dev/null; then
    apt-get update -qq
  elif command -v yum &>/dev/null; then
    yum makecache -q
  elif command -v dnf &>/dev/null; then
    dnf makecache -q
  elif command -v apk &>/dev/null; then
    apk update --quiet
  fi
}

echo "Updating package index..."
update_pkg

# ── Python ─────────────────────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
  echo "Installing Python3..."
  install_pkg python3
fi

# pip
if ! command -v pip3 &>/dev/null && ! python3 -m pip --version &>/dev/null 2>&1; then
  echo "Installing pip..."
  install_pkg python3-pip 2>/dev/null || \
    curl -fsSL https://bootstrap.pypa.io/get-pip.py | python3
fi

# venv
if ! python3 -m venv --help &>/dev/null 2>&1; then
  echo "Installing python3-venv..."
  install_pkg python3-venv 2>/dev/null || install_pkg python3-virtualenv 2>/dev/null || true
fi

# ── curl ───────────────────────────────────────────────────────────────────────
if ! command -v curl &>/dev/null; then
  echo "Installing curl..."
  install_pkg curl
fi

# ── nginx ──────────────────────────────────────────────────────────────────────
NGINX_OK=false
if ! command -v nginx &>/dev/null; then
  echo "Installing nginx..."
  install_pkg nginx 2>/dev/null && NGINX_OK=true || echo "  (nginx not available, skipping)"
else
  NGINX_OK=true
fi

# ── OTK server files ───────────────────────────────────────────────────────────
mkdir -p /opt/otk/data
echo "Downloading OTK server..."
curl -fsSL https://raw.githubusercontent.com/alejandrodelarocha/otk/main/server/main.py -o /opt/otk/main.py || {
  echo "ERROR: Could not download main.py"
  exit 1
}
curl -fsSL https://raw.githubusercontent.com/alejandrodelarocha/otk/main/server/requirements.txt -o /opt/otk/requirements.txt || {
  echo "ERROR: Could not download requirements.txt"
  exit 1
}

# ── Python venv + deps ─────────────────────────────────────────────────────────
echo "Installing Python dependencies..."
if python3 -m venv /opt/otk/venv 2>/dev/null; then
  /opt/otk/venv/bin/pip install -q -r /opt/otk/requirements.txt
  PYTHON_BIN=/opt/otk/venv/bin/python3
  UVICORN_BIN=/opt/otk/venv/bin/uvicorn
else
  # Fallback: install globally
  echo "  (venv not available, installing globally)"
  pip3 install -q fastapi uvicorn 2>/dev/null || python3 -m pip install -q fastapi uvicorn
  PYTHON_BIN=$(command -v python3)
  UVICORN_BIN=$(command -v uvicorn || echo "$PYTHON_BIN -m uvicorn")
fi

# ── Systemd ────────────────────────────────────────────────────────────────────
if command -v systemctl &>/dev/null; then
  cat > /etc/systemd/system/otk.service <<EOF
[Unit]
Description=OTK Server
After=network.target

[Service]
ExecStart=$UVICORN_BIN main:app --host 0.0.0.0 --port 7654
WorkingDirectory=/opt/otk
Environment=OTK_DB=/opt/otk/data/otk.db
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable otk
  systemctl restart otk
  echo "✓ OTK service started via systemd"
else
  # Fallback: run with nohup
  echo "  (systemd not available, starting with nohup)"
  pkill -f "uvicorn main:app" 2>/dev/null || true
  OTK_DB=/opt/otk/data/otk.db nohup $UVICORN_BIN main:app \
    --host 0.0.0.0 --port 7654 \
    --app-dir /opt/otk \
    > /opt/otk/otk.log 2>&1 &
  echo "✓ OTK started (PID $!), log: /opt/otk/otk.log"
fi

# ── Nginx ──────────────────────────────────────────────────────────────────────
if $NGINX_OK; then
  SITES_AVAILABLE=/etc/nginx/sites-available
  SITES_ENABLED=/etc/nginx/sites-enabled
  # Some distros use conf.d instead
  if [ ! -d "$SITES_AVAILABLE" ]; then
    SITES_AVAILABLE=/etc/nginx/conf.d
    SITES_ENABLED=/etc/nginx/conf.d
  fi
  mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED"

  cat > "$SITES_AVAILABLE/otk" <<EOF
server {
    listen 80;
    server_name _;

    location /otk/ {
        proxy_pass http://127.0.0.1:7654/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

  [ "$SITES_AVAILABLE" != "$SITES_ENABLED" ] && \
    ln -sf "$SITES_AVAILABLE/otk" "$SITES_ENABLED/otk"
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  if nginx -t 2>/dev/null; then
    systemctl restart nginx 2>/dev/null || service nginx restart 2>/dev/null || true
    echo "✓ Nginx configured"
  else
    echo "  (nginx config test failed, skipping)"
  fi
fi

# ── Done ───────────────────────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo "✓ OTK installed"
echo ""
echo "  Direct:    http://$PUBLIC_IP:7654/dashboard"
if $NGINX_OK; then
  echo "  Via nginx: http://$PUBLIC_IP/otk/dashboard"
fi
echo ""
echo "Manage:"
echo "  systemctl status otk"
echo "  systemctl restart otk"
echo "  journalctl -u otk -f"
