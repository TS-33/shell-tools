# 确保以root权限运行
if [ "$EUID" -ne 0 ]; then 
  echo "请以 root 权限运行此脚本"
  exit 1
fi

#卸载原先的k3s
which k3s-uninstall.sh && k3s-uninstall.sh

#配置IPVS
apt-get update && apt-get install -y ipset ipvsadm
set -e
cat <<EOF | sudo tee /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
sudo systemctl restart systemd-modules-load

#安装k3s
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn K3S_KUBECONFIG_MODE="644" INSTALL_K3S_EXEC=" \
  --disable traefik \
  --disable servicelb \
  --kube-proxy-arg proxy-mode=ipvs \
  --kube-proxy-arg ipvs-scheduler=lc \
  --kube-proxy-arg=ipvs-strict-arp=true" sh -

# --- 1. 安装 nerdctl ---
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

# --- 2. 安装 CNI plugins ---
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

# --- 3. 安装 BuildKit ---
if [[ ! -f /usr/local/bin/buildkitd ]]; then
    echo "正在获取 BuildKit 最新版本..."
    VERSION=$(curl -sI https://github.com/moby/buildkit/releases/latest | grep -i "location:" | awk -F "/" '{print $NF}' | tr -d '\r ' | sed 's/v//')
    echo "最新版本: ${VERSION}"

    TEMP_DIR=$(mktemp -d)
    wget -P "$TEMP_DIR" "https://github.com/moby/buildkit/releases/download/v${VERSION}/buildkit-v${VERSION}.linux-amd64.tar.gz"
    tar -xzf "$TEMP_DIR/buildkit-v${VERSION}.linux-amd64.tar.gz" -C /usr/local

## 做软连接
ln -s /run/k3s/containerd/containerd.sock /run/containerd/containerd.sock
ln -s /var/lib/rancher/k3s/data/current/bin/runc /usr/bin/runc
ln -s /usr/lib/systemd/system/k3s.service /usr/lib/systemd/system/containerd.service

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
export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock
export CONTAINERD_NAMESPACE=k8s.io
alias docker=nerdctl
. <(kubectl completion bash)
. <(nerdctl completion bash)
EOF
. /etc/profile.d/nerdctl.sh

mkdir -p ~/.kube
if [ ! -f ~/.kube/config ]; then
    ln -sf /etc/rancher/k3s/k3s.yaml ~/.kube/config
fi




# 生成 worker_join.sh
cat > worker_join.sh << EOF
# 卸载原先的 k3s agent
which k3s-agent-uninstall.sh && k3s-agent-uninstall.sh

set -e
# 配置 IPVS
apt-get update && apt-get install -y ipset ipvsadm
cat << \INNEREOF | sudo tee /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
INNEREOF

sudo systemctl restart systemd-modules-load

# 安装 k3s
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | \
INSTALL_K3S_MIRROR=cn \
K3S_URL=https://$(hostname -I | awk '{print $1}'):6443 \
K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token) \
INSTALL_K3S_EXEC="--kube-proxy-arg=proxy-mode=ipvs --kube-proxy-arg=ipvs-strict-arp=true" sh -
set +e
EOF
echo 已生成worker_join.sh脚本,请拷贝到worker节点上执行
set +e
