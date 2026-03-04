# --- 安装 runc ---
if [[ ! -f /usr/local/sbin/runc ]]; then
    echo "正在获取 runc 最新版本..."
    RUNC_VERSION=$(curl -sI https://github.com/opencontainers/runc/releases/latest | grep -i "location:" | awk -F "/" '{print $NF}' | tr -d '\r ' | sed 's/v//')
    echo "最新版本: v${RUNC_VERSION}"
    
    # runc 是单二进制文件，直接下载并赋予执行权限
    wget -O /usr/local/sbin/runc "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"
    chmod +x /usr/local/sbin/runc
    echo "runc 安装成功"
fi

# --- 安装 containerd ---
if [[ ! -f /usr/local/bin/containerd ]]; then
    echo "正在获取 containerd 最新版本..."
    VERSION=$(curl -sI https://github.com/containerd/containerd/releases/latest | grep -i "location:" | awk -F "/" '{print $NF}' | tr -d '\r ' | sed 's/v//')
    echo "最新版本: v${VERSION}"
    
    TEMP_DIR=$(mktemp -d)
    wget -P "$TEMP_DIR" "https://github.com/containerd/containerd/releases/download/v${VERSION}/containerd-${VERSION}-linux-amd64.tar.gz"
    # containerd 压缩包内含 bin/ 目录，直接解压到 /usr/local 即可进入 /usr/local/bin
    tar -C /usr/local -xzf "$TEMP_DIR/containerd-${VERSION}-linux-amd64.tar.gz"
    
    # 生成默认配置文件
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    
    # 写入 Systemd Service 文件
    cat > /usr/lib/systemd/system/containerd.service << EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now containerd
    
    rm -rf "$TEMP_DIR"
    echo "containerd 安装成功"
fi


# ---  安装 nerdctl ---
if [[ ! -f /usr/local/bin/nerdctl ]]; then
    echo "正在获取 nerdctl 最新版本..."
    VERSION=$(curl -sI https://github.com/containerd/nerdctl/releases/latest | grep -i "location:" | awk -F "/" '{print $NF}' | tr -d '\r ' | sed 's/v//')
    echo "最新版本: v${VERSION}"
    
    TEMP_DIR=$(mktemp -d)
    wget -P "$TEMP_DIR" "https://github.com/containerd/nerdctl/releases/download/v${VERSION}/nerdctl-${VERSION}-linux-amd64.tar.gz"
    tar -xzf "$TEMP_DIR/nerdctl-${VERSION}-linux-amd64.tar.gz" -C /usr/local/bin
    rm -rf "$TEMP_DIR"
    echo "nerdctl 安装成功"
fi

# ---  安装 CNI plugins ---
if [[ ! -f /opt/cni/bin/bridge ]]; then
    echo "正在获取 CNI 最新版本..."
    VERSION=$(curl -sI https://github.com/containernetworking/plugins/releases/latest | grep -i "location:" | awk -F "/" '{print $NF}' | tr -d '\r ')
    echo "最新版本: ${VERSION}"
    
    TEMP_DIR=$(mktemp -d)
    wget -P "$TEMP_DIR" "https://github.com/containernetworking/plugins/releases/download/${VERSION}/cni-plugins-linux-amd64-${VERSION}.tgz"
    mkdir -p /opt/cni/bin
    tar -xzf "$TEMP_DIR/cni-plugins-linux-amd64-${VERSION}.tgz" -C /opt/cni/bin
    rm -rf "$TEMP_DIR"
    echo "cni-plugins 安装成功"
fi

# ---  安装 BuildKit ---
if [[ ! -f /usr/local/bin/buildkitd ]]; then
    echo "正在获取 BuildKit 最新版本..."
    VERSION=$(curl -sI https://github.com/moby/buildkit/releases/latest | grep -i "location:" | awk -F "/" '{print $NF}' | tr -d '\r ' | sed 's/v//')
    echo "最新版本: ${VERSION}"

    TEMP_DIR=$(mktemp -d)
    wget -P "$TEMP_DIR" "https://github.com/moby/buildkit/releases/download/v${VERSION}/buildkit-v${VERSION}.linux-amd64.tar.gz"
    tar -xzf "$TEMP_DIR/buildkit-v${VERSION}.linux-amd64.tar.gz" -C /usr/local

### 做软连接
#ln -s /run/k3s/containerd/containerd.sock /run/containerd/containerd.sock
#ln -s /var/lib/rancher/k3s/data/current/bin/runc /usr/bin/runc
#ln -s /usr/lib/systemd/system/k3s.service /usr/lib/systemd/system/containerd.service

## service文件
cat > /usr/lib/systemd/system/buildkit.socket << EOF
[Unit]
Description=BuildKit socket
Documentation=https://github.com/moby/buildkit
 
[Socket]
ListenStream=/run/buildkit/buildkitd.sock
SocketMode=0660
 
[Install]
WantedBy=sockets.target
EOF

cat > /usr/lib/systemd/system/buildkit.service << EOF
[Unit]
Description=BuildKit
Documentation=https://github.com/moby/buildkit
After=containerd.service
Requires=containerd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/buildkitd \
  --oci-worker=false \
  --containerd-worker=true \
  --containerd-worker-addr=/run/containerd/containerd.sock
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

## 启动buildkit服务
systemctl daemon-reload && systemctl enable --now buildkit

echo " BuildKit 安装成功"
fi


#配置命令补全
cat > /etc/profile.d/nerdctl.sh << \EOF
export CONTAINERD_ADDRESS=/run/containerd/containerd.sock
export CONTAINERD_NAMESPACE=k8s.io
alias docker=nerdctl
. <(nerdctl completion bash)
EOF
. /etc/profile.d/nerdctl.sh
