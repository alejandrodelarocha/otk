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

# Install dependencies
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv nginx curl

# Create OTK directory
mkdir -p /opt/otk/data

# Download server files
echo "Downloading OTK server..."
curl -fsSL https://raw.githubusercontent.com/alejandrodelarocha/otk/main/server/main.py -o /opt/otk/main.py
curl -fsSL https://raw.githubusercontent.com/alejandrodelarocha/otk/main/server/requirements.txt -o /opt/otk/requirements.txt

# Install Python deps
python3 -m venv /opt/otk/venv
/opt/otk/venv/bin/pip install -q -r /opt/otk/requirements.txt

# Systemd service
cat > /etc/systemd/system/otk.service <<EOF
[Unit]
Description=OTK Server
After=network.target

[Service]
ExecStart=/opt/otk/venv/bin/uvicorn main:app --host 0.0.0.0 --port 7654
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

# Nginx config
cat > /etc/nginx/sites-available/otk <<EOF
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

ln -sf /etc/nginx/sites-available/otk /etc/nginx/sites-enabled/otk
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

echo ""
echo "✓ OTK running on port 7654"
echo "✓ Nginx proxying /otk/ → localhost:7654"
echo ""
echo "Dashboard: http://$(curl -s ifconfig.me)/otk/dashboard"
echo "API:       http://$(curl -s ifconfig.me)/otk/api/gain"
echo ""
echo "Manage:"
echo "  systemctl status otk"
echo "  systemctl restart otk"
echo "  journalctl -u otk -f"
