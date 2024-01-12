#!/bin/bash

# 检查是否以 root 身份运行
if [ "$(id -u)" != "0" ]; then
    echo "此脚本必须以 root 身份运行。请使用 sudo 或以 root 用户登录后再试。"
    exit 1
fi

# 检测操作系统类型并安装必要的软件包
install_packages() {
    # 检测基于 Debian 的系统（如 Ubuntu）
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y wireguard git
    # 检测基于 Red Hat 的系统（如 CentOS）
    elif [ -f /etc/redhat-release ]; then
        yum update
        yum install -y epel-release
        yum install -y wireguard-tools git
    else
        echo "不支持的操作系统类型。"
        exit 1
    fi
}

# 调用安装函数
install_packages

generate_config() {
    # 生成 WireGuard 配置文件
    local config_file=$1
    local private_key=$2
    local address=$3
    local listen_port=$4
    local server_public_key=$5
    local endpoint=$6
    local client_allowed_ips="0.0.0.0/0, ::/0"

    echo "[Interface]" > $config_file
    echo "PrivateKey = $private_key" >> $config_file
    echo "Address = $address" >> $config_file

    if [ ! -z "$listen_port" ]; then
        echo "ListenPort = $listen_port" >> $config_file
    fi

    if [ ! -z "$server_public_key" ]; then
        echo "[Peer]" >> $config_file
        echo "PublicKey = $server_public_key" >> $config_file
        echo "Endpoint = $endpoint" >> $config_file
        echo "AllowedIPs = $client_allowed_ips" >> $config_file
    fi
}

# 询问用户是配置服务端还是客户端
echo "您要配置服务端还是客户端？请输入 'server' 或 'client':"
read ROLE

# 创建一个目录来存放下载的密钥或存放即将上传的密钥
mkdir -p ~/wireguard_keys
cd ~/wireguard_keys

if [ "$ROLE" = "server" ]; then
    # 服务端配置
    echo "您正在配置服务端。"

    # 询问服务端配置参数
    SERVER_ADDRESS="10.0.0.1/24"
    echo "请输入服务端使用的网段（默认 10.0.0.1/24）:"
    read INPUT_SERVER_ADDRESS
    if [ ! -z "$INPUT_SERVER_ADDRESS" ]; then
        SERVER_ADDRESS=$INPUT_SERVER_ADDRESS
    fi
    
    SERVER_PORT=51820
    echo "请输入服务端监听的端口（默认 51820）:"
    read INPUT_SERVER_PORT
    if [ ! -z "$INPUT_SERVER_PORT" ]; then
        SERVER_PORT=$INPUT_SERVER_PORT
    fi

    # 获取公网IP或域名
    SERVER_IP=$(curl ip.sb)
    echo "请输入服务端公网IP或域名（默认 ${SERVER_IP}）："
    read INPUT_SERVER_IP
    if [ ! -z "$INPUT_SERVER_IP" ]; then
        SERVER_IP=$INPUT_SERVER_IP
    fi

    # 生成服务端密钥
    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo $SERVER_PRIVATE_KEY | wg pubkey)

    # 生成服务端配置文件
    SERVER_CONFIG="wg0.conf"
    generate_config $SERVER_CONFIG $SERVER_PRIVATE_KEY $SERVER_ADDRESS $SERVER_PORT

    # 保存服务端密钥和配置
    echo $SERVER_PRIVATE_KEY > server_private_key
    echo $SERVER_PUBLIC_KEY > server_public_key
    mv $SERVER_CONFIG /etc/wireguard/

    # 询问用户输入 Git 仓库地址和 deploy key
    echo "请输入您的 GitHub 仓库地址（格式为 username/reponame）:"
    read REPO
    echo "请输入您的 deploy key:"
    read DEPLOY_KEY

    # 设置 SSH 配置以使用 deploy key
    SSH_DIR=~/.ssh
    mkdir -p $SSH_DIR
    echo "$DEPLOY_KEY" > $SSH_DIR/deploy_key
    chmod 600 $SSH_DIR/deploy_key

    # 设置 Git 仓库和远程
    git init
    git remote add origin git@github.com:$REPO.git

    # 配置 SSH 使用特定的 key
    echo -e "Host github.com\n\tIdentityFile ~/.ssh/deploy_key\n\tStrictHostKeyChecking no\n" > $SSH_DIR/config

    # 将服务端密钥存储到Git仓库
    mkdir -p 0
    mv server_public_key 0/
    mv server_private_key 0/
    git add 0/
    git commit -m "Add server keys"

    # 询问要为多少个客户端生成密钥
    echo "您要为多少个客户端生成密钥？"
    read CLIENT_COUNT

    # 为每个客户端生成密钥
    for ((i=1; i<=CLIENT_COUNT; i++))
    do
        CLIENT_PRIVATE_KEY=$(wg genkey)
        CLIENT_PUBLIC_KEY=$(echo $CLIENT_PRIVATE_KEY | wg pubkey)

        # 生成客户端配置文件
        CLIENT_CONFIG="wg_client_${i}.conf"
        generate_config $CLIENT_CONFIG $CLIENT_PRIVATE_KEY $SERVER_ADDRESS $SERVER_PORT $SERVER_PUBLIC_KEY "[您的公网IP或域名]:$SERVER_PORT"
        mv $CLIENT_CONFIG ~/wireguard_keys/$i/

        # 将客户端密钥存储到Git仓库
        mkdir -p $i
        echo $CLIENT_PRIVATE_KEY > $i/private_key
        echo $CLIENT_PUBLIC_KEY > $i/public_key
        git add $i/
        git commit -m "Add client $i keys"
    done

    # 推送到GitHub
    git push -u origin master

    echo "服务端和客户端密钥配置文件已生成并上传到GitHub仓库。"

elif [ "$ROLE" = "client" ]; then
    # 客户端配置
    echo "请输入您的GitHub仓库地址（格式为 username/reponame）:"
    read REPO

    # 生成GitHub基本URL
    BASE_URL="https://raw.githubusercontent.com/${REPO}/master/"

    echo "您正在配置客户端。请输入您的密钥编号（例如 1, 2, 3...）:"
    read KEY_PAIR_NUMBER

    echo "正在下载客户端密钥和配置..."
    curl -O ${BASE_URL}${KEY_PAIR_NUMBER}/private_key
    curl -O ${BASE_URL}${KEY_PAIR_NUMBER}/wg_client_${KEY_PAIR_NUMBER}.conf

    # 配置客户端的WireGuard
    mv wg_client_${KEY_PAIR_NUMBER}.conf /etc/wireguard/
    wg-quick down wg0
    wg-quick up wg0
    echo "客户端密钥配置完成。"
else
    echo "输入错误，请重新输入。"

fi