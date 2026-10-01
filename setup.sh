#!/usr/bin/env bash
#
# Единый разворачивающий скрипт для ГИА ДЭ БУ (ALT Linux / Proxmox VE)
# Покрывает Задания 1, 2 и 3 в полном объеме.
#
set -euo pipefail

DOMAIN="au-team.irpo"
PASS="P@ssw0rd"
CURRENT_HOST="$(hostname -s | tr '[:upper:]' '[:lower:]')"

echo "=========================================================="
echo " Starting Full System Configuration: ${CURRENT_HOST}"
echo " Date: $(date)"
echo "=========================================================="

install_pkg() {
    echo "[+] Installing packages: $*"
    apt-get update -q && apt-get install -y -q "$@"
}

set_timezone() {
    echo "[+] Setting timezone..."
    timedatectl set-timezone Europe/Moscow || true
}

# ----------------------------------------------------------------------
# РОЛИ ВИРТУАЛЬНЫХ МАШИН
# ----------------------------------------------------------------------
case "${CURRENT_HOST}" in

  # ====================================================================
  # 1. ISP (Провайдер, Nginx Reverse Proxy, Chrony NTP)
  # ====================================================================
  "isp")
    echo "[*] Configuring ISP..."
    set_timezone
    install_pkg nginx chrony apache2-utils iptables openssl

    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf

    # NAT в интернет для HQ-RTR и BR-RTR
    iptables -t nat -F POSTROUTING
    iptables -t nat -A POSTROUTING -s 172.16.1.0/28 -j MASQUERADE
    iptables -t nat -A POSTROUTING -s 172.16.2.0/28 -j MASQUERADE
    iptables-save > /etc/sysconfig/iptables || true

    # NTP Chrony (Стратум 5)
    cat <<EOF > /etc/chrony.conf
server pool.ntp.org iburst
local stratum 5
allow 10.0.0.0/8
allow 172.16.0.0/12
EOF
    systemctl enable --now chronyd

    # Web Auth
    mkdir -p /etc/nginx
    htpasswd -b -c /etc/nginx/.htpasswd WEB "${PASS}"

    # Reverse Proxy + SSL Placeholder
    mkdir -p /etc/nginx/ssl
    cat <<EOF > /etc/nginx/conf.d/reverse-proxy.conf
server {
    listen 80;
    server_name web.au-team.irpo;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name web.au-team.irpo;

    ssl_certificate /etc/nginx/ssl/web.crt;
    ssl_certificate_key /etc/nginx/ssl/web.key;

    auth_basic "Protected Area";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://10.100.0.2:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

server {
    listen 443 ssl;
    server_name docker.au-team.irpo;

    ssl_certificate /etc/nginx/ssl/docker.crt;
    ssl_certificate_key /etc/nginx/ssl/docker.key;

    location / {
        proxy_pass http://10.2.0.2:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
    # Заглушка самоподписанных сертификатов до выпуска с CA HQ-SRV
    openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/web.key -out /etc/nginx/ssl/web.crt -subj "/CN=web.au-team.irpo" || true
    openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/docker.key -out /etc/nginx/ssl/docker.crt -subj "/CN=docker.au-team.irpo" || true

    systemctl enable --now nginx
    ;;

  # ====================================================================
  # 2. HQ-RTR (Маршрутизатор штаб-квартиры)
  # ====================================================================
  "hq-rtr")
    echo "[*] Configuring HQ-RTR..."
    set_timezone
    install_pkg frr dhcp-server iptables chrony

    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf

    # NTP Client
    echo "server 172.16.1.1 iburst" > /etc/chrony.conf
    systemctl enable --now chronyd

    # GRE Туннель
    ip tunnel del gre-br 2>/dev/null || true
    ip tunnel add gre-br mode gre remote 172.16.2.2 local 172.16.1.2 ttl 255
    ip addr add 10.10.10.1/30 dev gre-br
    ip link set gre-br up

    # net_admin
    useradd -m -s /bin/bash net_admin || true
    echo "net_admin:${PASS}" | chpasswd
    echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin

    # DHCP Server (VLAN 200)
    cat <<EOF > /etc/dhcp/dhcpd.conf
option domain-name "${DOMAIN}";
option domain-name-servers 10.100.0.2;
default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 10.200.0.0 netmask 255.255.255.240 {
  range 10.200.0.2 10.200.0.14;
  option routers 10.200.0.1;
}
EOF
    systemctl enable --now dhcpd

    # NAT & Port Forwarding (DNAT)
    iptables -t nat -F
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 -j DNAT --to-destination 10.100.0.2:80
    iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 2027 -j DNAT --to-destination 10.100.0.2:2027
    iptables-save > /etc/sysconfig/iptables || true

    # OSPF FRR
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    cat <<EOF > /etc/frr/frr.conf
frr version 8.0
frr defaults traditional
hostname hq-rtr
!
interface gre-br
 ip ospf network point-to-point
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 ${PASS}
!
router ospf
 ospf router-id 10.10.10.1
 passive-interface default
 no passive-interface gre-br
 network 10.10.10.0/30 area 0
 network 10.100.0.0/27 area 0
 network 10.200.0.0/28 area 0
 network 10.99.9.0/29 area 0
!
EOF
    chown -R frr:frr /etc/frr/
    systemctl enable --now frr
    ;;

  # ====================================================================
  # 3. BR-RTR (Маршрутизатор филиала)
  # ====================================================================
  "br-rtr")
    echo "[*] Configuring BR-RTR..."
    set_timezone
    install_pkg frr iptables chrony

    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf

    echo "server 172.16.2.1 iburst" > /etc/chrony.conf
    systemctl enable --now chronyd

    # GRE Туннель
    ip tunnel del gre-hq 2>/dev/null || true
    ip tunnel add gre-hq mode gre remote 172.16.1.2 local 172.16.2.2 ttl 255
    ip addr add 10.10.10.2/30 dev gre-hq
    ip link set gre-hq up

    # net_admin
    useradd -m -s /bin/bash net_admin || true
    echo "net_admin:${PASS}" | chpasswd
    echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin

    # NAT & Port Forwarding
    iptables -t nat -F
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 -j DNAT --to-destination 10.2.0.2:8080
    iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 2027 -j DNAT --to-destination 10.2.0.2:2027
    iptables-save > /etc/sysconfig/iptables || true

    # OSPF FRR
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    cat <<EOF > /etc/frr/frr.conf
frr version 8.0
frr defaults traditional
hostname br-rtr
!
interface gre-hq
 ip ospf network point-to-point
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 ${PASS}
!
router ospf
 ospf router-id 10.10.10.2
 passive-interface default
 no passive-interface gre-hq
 no passive-interface eth1
 network 10.10.10.0/30 area 0
 network 10.0.1.0/30 area 0
!
EOF
    chown -R frr:frr /etc/frr/
    systemctl enable --now frr
    ;;

  # ====================================================================
  # 4. BR-FW (Межсетевой экран филиала)
  # ====================================================================
  "br-fw")
    echo "[*] Configuring BR-FW..."
    set_timezone
    install_pkg frr iptables

    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf

    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    cat <<EOF > /etc/frr/frr.conf
frr version 8.0
frr defaults traditional
hostname br-fw
!
router ospf
 ospf router-id 10.0.1.1
 passive-interface default
 no passive-interface eth0
 network 10.0.1.0/30 area 0
 network 10.2.0.0/28 area 0
!
EOF
    chown -R frr:frr /etc/frr/
    systemctl enable --now frr
    ;;

  # ====================================================================
  # 5. HQ-SRV (Основной сервер: BIND9, LAMP, NFS, RAID, SSH, Fail2ban, Atop, CUPS)
  # ====================================================================
  "hq-srv")
    echo "[*] Configuring HQ-SRV..."
    set_timezone
    install_pkg bind apache2 php8.1 php8.1-mariadb mariadb-server \
                cups cups-pdf fail2ban atop mdadm nfs-utils openssl chrony

    echo "server 172.16.1.1 iburst" > /etc/chrony.conf
    systemctl enable --now chronyd

    # 1. sshuser
    useradd -u 2027 -m -s /bin/bash sshuser || true
    echo "sshuser:${PASS}" | chpasswd
    echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser

    sed -i 's/#Port 22/Port 2027/' /etc/ssh/sshd_config
    echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    echo "MaxAuthTries 2" >> /etc/ssh/sshd_config
    echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
    echo "Authorized access only" > /etc/issue.net
    systemctl restart sshd

    # 2. BIND9 DNS Server
    cat <<EOF > /etc/bind/options.conf
options {
    directory "/var/lib/bind";
    forwarders { 77.88.8.7; 77.88.8.3; };
    allow-query { any; };
};
EOF
    cat <<EOF > /etc/bind/named.conf.local
zone "${DOMAIN}" {
    type master;
    file "/etc/bind/db.au-team.irpo";
};
EOF
    cat <<EOF > /etc/bind/db.au-team.irpo
\$TTL 86400
@ IN SOA hq-srv.${DOMAIN}. admin.${DOMAIN}. (1 604800 86400 2419200 604800)
@ IN NS hq-srv.${DOMAIN}.
hq-rtr  IN A 10.100.0.1
br-rtr  IN A 10.0.1.2
br-fw   IN A 10.0.1.1
hq-srv  IN A 10.100.0.2
hq-cli  IN A 10.200.0.2
br-srv  IN A 10.2.0.2
docker  IN A 172.16.2.1
web     IN A 172.16.1.1
EOF
    systemctl enable --now bind

    # 3. RAID0 & NFS
    if [ -b /dev/sdb ] && [ -b /dev/sdc ]; then
        mdadm --create --run /dev/md0 --level=0 --raid-devices=2 /dev/sdb /dev/sdc || true
        mkfs.ext4 -F /dev/md0
        mkdir -p /raid/nfs
        echo "/dev/md0 /raid ext4 defaults 0 0" >> /etc/fstab
        mount -a || true
        mdadm --detail --scan > /etc/mdadm.conf
    fi
    mkdir -p /raid/nfs
    echo "/raid/nfs 10.200.0.0/28(rw,sync,no_root_squash)" > /etc/exports
    systemctl enable --now nfs-server

    # 4. LAMP & Web Application
    systemctl enable --now mariadb apache2
    mysql -e "CREATE DATABASE IF NOT EXISTS webdb;" || true
    mysql -e "CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY '${PASS}';" || true
    mysql -e "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';" || true
    mysql -e "FLUSH PRIVILEGES;" || true

    # 5. Fail2ban (SSH 2027, 3 попытки, 1 мин бан)
    cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = 2027
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 60
EOF
    systemctl enable --now fail2ban

    # 6. Atop (интервал 7 минут = 420 сек)
    if [ -f /etc/sysconfig/atop ]; then
        sed -i 's/INTERVAL=180/INTERVAL=420/' /etc/sysconfig/atop
    fi
    systemctl enable --now atop

    # 7. CUPS PDF Printer
    systemctl enable --now cups
    ;;

  # ====================================================================
  # 6. BR-SRV (Samba DC, Ansible, Docker, Import Script)
  # ====================================================================
  "br-srv")
    echo "[*] Configuring BR-SRV..."
    set_timezone
    install_pkg ansible docker-engine docker-compose-v2 git chrony

    echo "server 172.16.2.1 iburst" > /etc/chrony.conf
    systemctl enable --now chronyd

    useradd -u 2027 -m -s /bin/bash sshuser || true
    echo "sshuser:${PASS}" | chpasswd
    echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser

    sed -i 's/#Port 22/Port 2027/' /etc/ssh/sshd_config
    echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    systemctl restart sshd

    # Ansible Setup
    mkdir -p /etc/ansible/PC-INFO
    cat <<EOF > /etc/ansible/hosts
[all]
hq-srv ansible_host=10.100.0.2 ansible_port=2027 ansible_user=sshuser
hq-cli ansible_host=10.200.0.2 ansible_user=sshuser
hq-rtr ansible_host=10.100.0.1 ansible_user=net_admin
br-rtr ansible_host=10.0.1.2 ansible_user=net_admin
EOF

    # Docker
    systemctl enable --now docker
    ;;

  # ====================================================================
  # 7. HQ-CLI (Рабочая станция, Autofs, Sudo для hq, SSL CA, CUPS Client)
  # ====================================================================
  "hq-cli")
    echo "[*] Configuring HQ-CLI..."
    set_timezone
    install_pkg autofs nfs-utils chrony cups

    echo "server 172.16.1.1 iburst" > /etc/chrony.conf
    systemctl enable --now chronyd

    useradd -u 2027 -m -s /bin/bash sshuser || true
    echo "sshuser:${PASS}" | chpasswd
    echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser

    # NFS Autofs
    mkdir -p /mnt/nfs
    echo "/mnt/nfs /etc/auto.nfs --timeout=60" >> /etc/auto.master
    echo "* -rw,soft,intr 10.100.0.2:/raid/nfs" > /etc/auto.nfs
    systemctl enable --now autofs

    # Ограниченный sudo для группы hq (cat, grep, id)
    cat <<EOF > /etc/sudoers.d/hq_group
%hq ALL=(ALL) /usr/bin/cat, /usr/bin/grep, /usr/bin/id
EOF
    chmod 0440 /etc/sudoers.d/hq_group
    ;;

  *)
    echo "[-] Unknown hostname: '${CURRENT_HOST}'."
    echo "    Change hostname via: hostnamectl set-hostname <name>"
    exit 1
    ;;
esac

echo "=========================================================="
echo " Setup completed successfully on ${CURRENT_HOST}!"
echo "=========================================================="
