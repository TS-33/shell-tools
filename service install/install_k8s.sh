# 变量设置
## k8s版本，格式：v1.xx.x
K8S_VERSION=v1.29.9

## 主节点
MASTER_NAME=master
MASTER_IP=192.168.36.40

## 从节点
WORKER_NAMES=("worker1" "worker2")
WORKER_IPS=("192.168.36.41" "192.168.36.42")



# 检测环境
function pre_check()
{
if [[ `id -u` != 0 ]];then
    echo 请以root身份运行
    exit 1
fi

ping pkgs.k8s.io -c 2 > /dev/null
if [[ $? != 0 ]];then
    echo 网络故障
    exit 1
fi

which git &> /dev/null
if [[ $? != 0 ]];then
    echo 未安装git
    exit
fi

K8S_VERSION_CHECK=$(git ls-remote --tags https://github.com/kubernetes/kubernetes.git refs/tags/$K8S_VERSION)
if [ ! -n "$K8S_VERSION_CHECK" ]; then
    echo k8s版本 $K8S_VERSION 不存在
    exit 1
fi
}

# 修改hosts文件，添加域名解析
function hostsFile_edit()
{
grep "k8s_installer modifid" /etc/hosts &> /dev/null
if [[ $? != 0 ]];then
cat >> /etc/hosts << EOF

# k8s_installer modifid
$MASTER_IP $MASTER_NAME
`for i in "${!WORKER_NAMES[@]}";do echo "${WORKER_IPS[$i]} ${WORKER_NAMES[$i]}";done`
EOF
fi
}

# 安装chrony，配置时间同步
function chrony_install()
{
timedatectl set-timezone Asia/Shanghai
apt install chrony -y
if [[ $? != 0 ]];then
    echo 网络连接错误
    exit 1
fi

sed -i '/^pool/d' /etc/chrony/chrony.conf

grep "k8s_installer modifid" /etc/chrony/chrony.conf &> /dev/null
if [[ $? != 0 ]];then
cat >> /etc/chrony/chrony.conf <<EOF

# k8s_installer modifid
server ntp.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp10.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp11.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp12.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp7.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp8.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp9.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
EOF
fi

systemctl restart chrony
systemctl restart chronyd
}

# 配置内核参数，下载IPvs
function load_mod()
{
grep "k8s_installer modifid" /etc/modules-load.d/k8s.conf &> /dev/null
if [[ $? != 0 ]];then
cat >>  /etc/modules-load.d/k8s.conf <<EOF

# k8s_installer modifid
overlay
br_netfilter
EOF
fi

modprobe overlay
modprobe br_netfilter
grep "k8s_installer modifid" /etc/sysctl.d/k8s.conf &> /dev/null
if [[ $? != 0 ]];then
cat >> /etc/sysctl.d/k8s.conf <<EOF

# k8s_installer modifid
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
fi

sysctl --system

apt install ipset ipvsadm -y

grep "k8s_installer modifid" /etc/modules-load.d/ipvs.conf &> /dev/null
if [[ $? != 0 ]];then
cat >> /etc/modules-load.d/ipvs.conf <<EOF

# k8s_installer modifid
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
fi

modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack
}

function off_swap()
{
sed -i '/swap/s/^/# /' /etc/fstab
mount -a
swapoff -a
}


function containerd_install()
{
if [[ ! -f /usr/local/bin/containerd ]]; then
    echo "正在获取 containerd 最新版本..."
    VERSION=$(curl -sI https://github.com/containerd/containerd/releases/latest | grep -i "location:" | awk -F "/" '{print $NF}' | tr -d '\r ' | sed 's/v//')
    echo "最新版本: v${VERSION}"
    TEMP_DIR=$(mktemp -d)
    echo "正在下载 containerd v${VERSION}..."
    wget -q -P "$TEMP_DIR" "https://github.com/containerd/containerd/releases/download/v${VERSION}/containerd-${VERSION}-linux-amd64.tar.gz"
    tar -xzf "$TEMP_DIR/containerd-${VERSION}-linux-amd64.tar.gz" -C "$TEMP_DIR"
    cp "$TEMP_DIR/bin/"* /usr/local/bin/
    rm -rf "$TEMP_DIR"
    if [[ -f /usr/local/bin/containerd ]]; then
        echo "containerd 安装成功，当前版本: $(containerd --version)"
    cat > /etc/systemd/system/containerd.service <<EOF
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
    mkdir /etc/containerd -p
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    systemctl enable --now containerd
    systemctl restart containerd
    else
        echo "安装失败，请检查网络或权限。"
        exit 1
    fi
else
    echo "containerd 已存在，跳过安装。"
fi
}

function runc_install()
{
if [[ ! -f /usr/local/sbin/runc ]]; then
    echo "正在获取 runc 最新版本..."
    VERSION=$(curl -sI https://github.com/opencontainers/runc/releases/latest | grep -i "location:" | awk -F "/" '{print $NF}' | tr -d '\r ')
    echo "最新版本: ${VERSION}"
    TEMP_DIR=$(mktemp -d)
    echo "正在下载 runc ${VERSION}..."
    wget -P "$TEMP_DIR" "https://github.com/opencontainers/runc/releases/download/${VERSION}/runc.amd64"
    install -m 755 "$TEMP_DIR/runc.amd64" /usr/local/sbin/runc
    
    rm -rf "$TEMP_DIR"
    
    if [[ -f /usr/local/sbin/runc ]]; then
        echo "runc 安装成功，当前版本: $(runc --version | head -n 1)"
    else
        echo "runc 安装失败"
        exit 1
    fi
fi
}

# nerdctl、cni、buildkit安装
function nerdctl_install()
{
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

if [[ ! -f /usr/local/bin/buildkitd ]]; then
    echo "正在获取 BuildKit 最新版本..."
    VERSION=$(curl -sI https://github.com/moby/buildkit/releases/latest | grep -i "location:" | awk -F "/" '{print $NF}' | tr -d '\r ' | sed 's/v//')
    echo "最新版本: ${VERSION}"

    TEMP_DIR=$(mktemp -d)
    wget -P "$TEMP_DIR" "https://github.com/moby/buildkit/releases/download/v${VERSION}/buildkit-v${VERSION}.linux-amd64.tar.gz"
    tar -xzf "$TEMP_DIR/buildkit-v${VERSION}.linux-amd64.tar.gz" -C /usr/local
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
systemctl daemon-reload && systemctl enable --now buildkit
echo " BuildKit 安装成功"
fi

}

function load_image()
{
if [[ -f /root/k8s_images.tar ]];then
nerdctl load -i /root/k8s_images.tar
fi
}

function k8s_install()
{
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg  /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION%.*}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
if [[ $? != 0 ]];then
  echo 密钥获取失败
  exit 1
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION%.*}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
apt update

INSTALL_VERSION=`apt-cache madison kubeadm | grep ${K8S_VERSION/v/} | awk '{print $3}'`
apt install -y kubelet=$INSTALL_VERSION kubeadm=$INSTALL_VERSION kubectl=$INSTALL_VERSION
if [[ $? != 0 ]];then
    echo kubeadm 安装错误
    exit 1
fi
apt-mark hold kubelet kubeadm kubectl

#配置命令补全
cat > /etc/profile.d/nerdctl.sh << \EOF
export CONTAINERD_ADDRESS=/run/containerd/containerd.sock
export CONTAINERD_NAMESPACE=k8s.io
alias docker=nerdctl
. <(kubectl completion bash)
. <(nerdctl completion bash)
EOF
. /etc/profile.d/nerdctl.sh

# 设置Cgroup模式
mkdir /etc/sysconfig -p
grep "k8s_installer modifid"  /etc/sysconfig/kubelet &> /dev/null
if [[ $? != 0 ]];then
cat >> /etc/sysconfig/kubelet <<EOF

# k8s_installer modifid
KUBELET_EXTRA_ARGS="--cgroup-driver=systemd"
EOF
fi
systemctl enable kubelet

# kubeadm 配置文件
cat > kubeadm-config.yaml << EOF
apiVersion: kubeadm.k8s.io/v1beta3
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: abcdef.0123456789abcdef
  ttl: 24h0m0s
  usages:
  - signing
  - authentication
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${MASTER_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: ${MASTER_NAME}
  taints: null
---
apiServer:
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
controllerManager: {}
dns: {}
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: registry.k8s.io
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION/v/}
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
scheduler: {}
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF
kubeadm init --config kubeadm-config.yaml > kubeadm-init.log

if [[ $? != 0 ]];then
    kubeadm init 初始化失败
    exit
fi

printf "\n\n\nkubeadm init 信息已保存到kubeadm-init.log\n\n\n"
rm kubeadm-config.yaml -f

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

}


function make_worker_init()
{
cat > worker_init.sh <<EOF
MASTER_IP=$MASTER_IP
MASTER_NAME=$MASTER_NAME
K8S_VERSION=$K8S_VERSION
WORKER_NAMES=$WORKER_NAMES
WORKER_IPS=$WORKER_IPS
# 检测环境
function pre_check()
{
if [[ `id -u` != 0 ]];then
    echo 请以root身份运行
    exit 1
fi

ping pkgs.k8s.io -c 2 > /dev/null
if [[ \$? != 0 ]];then
    echo 网络故障
    exit 1
fi
}

# 修改hosts文件，添加域名解析
function hostsFile_edit()
{
grep "k8s_installer modifid" /etc/hosts &> /dev/null
if [[ \$? != 0 ]];then
cat >> /etc/hosts << EOF1

# k8s_installer modifid
\$MASTER_IP \$MASTER_NAME
\$(for i in "\${!WORKER_NAMES[@]}";do echo "\${WORKER_IPS[\$i]} \${WORKER_NAMES[\$i]}";done)
EOF1
fi
}

# 安装chrony，配置时间同步
function chrony_install()
{
timedatectl set-timezone Asia/Shanghai
apt install chrony -y
if [[ \$? != 0 ]];then
    echo 网络连接错误
    exit 1
fi

sed -i '/^pool/d' /etc/chrony/chrony.conf

grep "k8s_installer modifid" /etc/chrony/chrony.conf &> /dev/null
if [[ \$? != 0 ]];then
cat > /etc/chrony/chrony.conf <<EOF2

# k8s_installer modifid
server ntp.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp10.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp11.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp12.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp7.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp8.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
server ntp9.cloud.aliyuncs.com minpoll 4 maxpoll 10 iburst
EOF2
fi

systemctl restart chrony
systemctl restart chronyd
}

# 配置内核参数，下载IPvs
function load_mod()
{
grep "k8s_installer modifid" /etc/modules-load.d/k8s.conf &> /dev/null
if [[ \$? != 0 ]];then
cat >>  /etc/modules-load.d/k8s.conf <<EOF3

# k8s_installer modifid
overlay
br_netfilter
EOF3
fi

modprobe overlay
modprobe br_netfilter
grep "k8s_installer modifid" /etc/sysctl.d/k8s.conf &> /dev/null
if [[ \$? != 0 ]];then
cat >> /etc/sysctl.d/k8s.conf <<EOF4

# k8s_installer modifid
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF4
fi

sysctl --system

apt install ipset ipvsadm -y

grep "k8s_installer modifid" /etc/modules-load.d/ipvs.conf &> /dev/null
if [[ \$? != 0 ]];then
cat >> /etc/modules-load.d/ipvs.conf <<EOF5

# k8s_installer modifid
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF5
fi

modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack
}

function off_swap()
{
sed -i '/swap/s/^/# /' /etc/fstab
mount -a
swapoff -a
}


function containerd_install()
{
if [[ ! -f /usr/local/bin/containerd ]]; then
    echo "正在获取 containerd 最新版本..."
    VERSION=\$(curl -sI https://github.com/containerd/containerd/releases/latest | grep -i "location:" | awk -F "/" '{print \$NF}' | tr -d '\r ' | sed 's/v//')
    echo "最新版本: v\${VERSION}"
    TEMP_DIR=\$(mktemp -d)
    echo "正在下载 containerd v\${VERSION}..."
    wget -q -P "\$TEMP_DIR" "https://github.com/containerd/containerd/releases/download/v\${VERSION}/containerd-\${VERSION}-linux-amd64.tar.gz"
    tar -xzf "\$TEMP_DIR/containerd-\${VERSION}-linux-amd64.tar.gz" -C "\$TEMP_DIR"
    cp "\$TEMP_DIR/bin/"* /usr/local/bin/
    rm -rf "\$TEMP_DIR"
    if [[ -f /usr/local/bin/containerd ]]; then
        echo "containerd 安装成功，当前版本: \$(containerd --version)"
    cat > /etc/systemd/system/containerd.service <<EOF6
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
EOF6
    mkdir /etc/containerd -p
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    systemctl enable --now containerd
    systemctl restart containerd
    else
        echo "安装失败，请检查网络或权限。"
        exit 1
    fi
else
    echo "containerd 已存在，跳过安装。"
fi
}

function runc_install()
{
if [[ ! -f /usr/local/sbin/runc ]]; then
    echo "正在获取 runc 最新版本..."
    VERSION=\$(curl -sI https://github.com/opencontainers/runc/releases/latest | grep -i "location:" | awk -F "/" '{print \$NF}' | tr -d '\r ')
    echo "最新版本: \${VERSION}"
    TEMP_DIR=\$(mktemp -d)
    echo "正在下载 runc \${VERSION}..."
    wget -P "\$TEMP_DIR" "https://github.com/opencontainers/runc/releases/download/\${VERSION}/runc.amd64"
    install -m 755 "\$TEMP_DIR/runc.amd64" /usr/local/sbin/runc
    
    rm -rf "\$TEMP_DIR"
    
    if [[ -f /usr/local/sbin/runc ]]; then
        echo "runc 安装成功，当前版本: \$(runc --version | head -n 1)"
    else
        echo "runc 安装失败"
        exit 1
    fi
fi
}


function k8s_install()
{
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg  /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/\${K8S_VERSION%.*}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
if [[ \$? != 0 ]];then
  echo 密钥获取失败
  exit 1
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/\${K8S_VERSION%.*}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
apt update

INSTALL_VERSION=`apt-cache madison kubeadm | grep \${K8S_VERSION/v/} | awk '{print $3}'`
apt install -y kubelet=\$INSTALL_VERSION kubeadm=\$INSTALL_VERSION kubectl=\$INSTALL_VERSION
if [[ \$? != 0 ]];then
    echo kubectl 安装错误
    exit 1
fi
apt-mark hold kubelet kubeadm kubectl

# 设置Cgroup模式
mkdir /etc/sysconfig -p
grep "k8s_installer modifid"  /etc/sysconfig/kubelet &> /dev/null
if [[ \$? != 0 ]];then
cat >> /etc/sysconfig/kubelet <<EOF7

# k8s_installer modifid
KUBELET_EXTRA_ARGS="--cgroup-driver=systemd"
EOF7
fi
systemctl enable kubelet
}


function join_k8s()
{
$(tail -2 kubeadm-init.log)
}


pre_check
hostsFile_edit
chrony_install
load_mod
off_swap
containerd_install
runc_install
k8s_install
join_k8s

EOF

printf "\n\n\n已生成worker_join.sh 请复制到worker节点并执行\n\n\n"
}


pre_check
hostsFile_edit
chrony_install
load_mod
off_swap
containerd_install
runc_install
nerdctl_install
load_image
k8s_install
make_worker_init
