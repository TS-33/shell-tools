#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本"
  exit 1
fi

echo "正在获取 Prometheus 最新版本号..."
VERSION=$(curl -s https://api.github.com/repos/prometheus/prometheus/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
if [ -z "$VERSION" ]; then
    echo "错误：无法获取版本号，请检查网络"
    exit 1
fi

FILE_NAME="prometheus-${VERSION}.linux-amd64.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/prometheus/releases/download/v${VERSION}/${FILE_NAME}"
echo "最新版本: v${VERSION}"
if [[ ! -f "$FILE_NAME" ]]; then
    echo "正在下载: ${FILE_NAME}..."
    wget -N "$DOWNLOAD_URL" &> /dev/null
else
    echo "文件 ${FILE_NAME} 已存在，跳过下载"
fi

tar xzf prometheus-3.9.1.linux-amd64.tar.gz -C /usr/local/
cd /usr/local/
mv prometheus-3.9.1.linux-amd64 prometheus
useradd prometheus -s /usr/sbin/nologin

cat > /usr/lib/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus Server
Documentation=https://prometheus.io/docs/introduction/overview/After=network.target[Service]Restart=on-failureUser=prometheus
[Service]
Restart=onfailure
User=prometheus
Group=prometheus
WorkingDirectory=/usr/local/prometheus/
ExecStart=/usr/local/prometheus/prometheus --config.file=/usr/local/prometheus/prometheus.yml --web.enable-lifecycle
ExecReload=/bin/kill -HUP $MAINPID
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prometheus
