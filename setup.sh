#!/usr/bin/env bash
#
# Единый разворачивающий скрипт для ГИА ДЭ БУ (ALT Linux / Proxmox VE)
# Задание 1. Настройка сетевой инфраструктуры и базовых сервисов
#
set -euo pipefail

DOMAIN="au-team.irpo"
PASS="P@ssw0rd"
CURRENT_HOST="$(hostname -s | tr '[:upper:]' '[:lower:]')"

echo "=========================================================="
echo " Starting System Configuration: ${CURRENT_HOST}"
echo " Date: $(date)"
echo "=========================================================="

# ----------------------------------------------------------------------
# 0. ВСПOМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ----------------------------------------------------------------------

install_pkg() {
    echo "[+] Installing packages: $*"
    apt-get update -q && apt-get install -y -q "$@"
}

set_timezone() {
    echo "[+] Setting timezone..."
    timedatectl set-timezone Europe/Moscow || true
}

enable_ip_forward() {
    echo "[+] Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf
}

save_iptables() {
    mkdir -p /etc/sysconfig
    iptables-save > /etc/sysconfig/iptables
    systemctl enable iptables 2>/dev/null || true
}

# ----------------------------------------------------------------------
# РОЛИ ВИРТУАЛЬНЫХ МАШИН
# ----------------------------------------------------------------------
case "${CURRENT_HOST}" in

  # ====================================================================
  # 1. ISP (Провайдер)
  # ====================================================================
  "isp")
    echo "[*] Configuring ISP..."

    # Предварительная настройка сети для гарантированного выхода в Интернет
    ip addr add 172.16.1.1/28 dev ens2 2>/dev/null || true
    ip addr add 172.16.2.1/28 dev ens3 2>/dev/null || true
    dhcpcd ens1 2>/dev/null || dhclient ens1 2>/dev/null || true

    set_timezone
    install_pkg iptables chrony

    enable_ip_forward

    # Маскарадинг (NAT) в интернет для офисов HQ и BR
    iptables -F
    iptables -t nat -F
    iptables -t nat -A POSTROUTING -o ens1 -j MASQUERADE
    iptables -t nat -A POSTROUTING -s 172.16.1.0/28 -o ens1 -j MASQUERADE
    iptables -t nat -A POSTROUTING -s 172.16.2.0/28 -o ens1 -j MASQUERADE
    save_iptables

    # Chrony NTP
    cat <<EOF > /etc/chrony.conf
server pool.ntp.org iburst
local stratum 5
allow 10.0.0.0/8
allow 172.16.0.0/12
EOF
    systemctl enable --now chronyd
    ;;

  # ====================================================================
  # 2. HQ-RTR (Маршрутизатор штаб-квартиры)
  # ====================================================================
  "hq-rtr")
    echo "[*] Configuring HQ-RTR..."

    # Первоначальный IP и маршрут к ISP
    ip addr add 172.16.1.2/28 dev ens1 2>/dev/null || true
    ip route add default via 172.16.1.1 dev ens1 2>/dev/null || true

    set_timezone
    install_pkg frr dhcp-server iptables chrony

    enable_ip_forward

    # NTP Клиент
    cat <<EOF > /etc/chrony.conf
server 172.16.1.1 iburst
EOF
    systemctl enable --now chronyd

    # Настройка VLAN-интерфейсов (один физический адаптер ens2)
    ip link set ens2 up
    ip link add link ens2 name ens2.100 type vlan id 100 2>/dev/null || true
    ip link add link ens2 name ens2.200 type vlan id 200 2>/dev/null || true
    ip link add link ens2 name ens2.999 type vlan id 999 2>/dev/null || true

    ip addr add 10.100.0.1/30 dev ens2.100 2>/dev/null || true
    ip addr add 10.200.0.1/28 dev ens2.200 2>/dev/null || true
    ip addr add 10.99.9.1/29 dev ens2.999 2>/dev/null || true

    ip link set ens2.100 up
    ip link set ens2.200 up
    ip link set ens2.999 up

    # GRE Туннель до BR-RTR (сеть 10.10.10.0/30)
    ip tunnel del gre-br 2>/dev/null || true
    ip tunnel add gre-br mode gre remote 172.16.2.2 local 172.16.1.2 ttl 255
    ip addr add 10.10.10.1/30 dev gre-br
    ip link set gre-br up

    # Настройка пользователя net_admin
    useradd -m -s /bin/bash net_admin 2>/dev/null || true
    echo "net_admin:${PASS}" | chpasswd
    echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
    chmod 0440 /etc/sudoers.d/net_admin

    # DHCP Сервер для HQ-CLI (VLAN 200)
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

    # NAT (SNAT/MASQUERADE) в сторону ISP
    iptables -F
    iptables -t nat -F
    iptables -t nat -A POSTROUTING -o ens1 -j MASQUERADE
    save_iptables

    # OSPF (FRR)
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
 network 10.100.0.0/30 area 0
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

    # Первоначальный IP и маршрут к ISP
    ip addr add 172.16.2.2/28 dev ens1 2>/dev/null || true
    ip route add default via 172.16.2.1 dev ens1 2>/dev/null || true

    set_timezone
    install_pkg frr iptables chrony

    enable_ip_forward

    # NTP Клиент
    cat <<EOF > /etc/chrony.conf
server 172.16.2.1 iburst
EOF
    systemctl enable --now chronyd

    # Сеть в сторону BR-FW (/30)
    ip addr add 10.0.1.2/30 dev ens2 2>/dev/null || true
    ip link set ens2 up

    # GRE Туннель до HQ-RTR
    ip tunnel del gre-hq 2>/dev/null || true
    ip tunnel add gre-hq mode gre remote 172.16.1.2 local 172.16.2.2 ttl 255
    ip addr add 10.10.10.2/30 dev gre-hq
    ip link set gre-hq up

    # Настройка пользователя net_admin
    useradd -m -s /bin/bash net_admin 2>/dev/null || true
    echo "net_admin:${PASS}" | chpasswd
    echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
    chmod 0440 /etc/sudoers.d/net_admin

    # NAT (SNAT/MASQUERADE) в сторону ISP
    iptables -F
    iptables -t nat -F
    iptables -t nat -A POSTROUTING -o ens1 -j MASQUERADE
    save_iptables

    # OSPF (FRR)
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
 no passive-interface ens2
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

    # Подъем адресации к BR-RTR и дефолтного маршрута
    ip addr add 10.0.1.1/30 dev eth0 2>/dev/null || ip addr add 10.0.1.1/30 dev ens1 2>/dev/null || true
    ip route add default via 10.0.1.2 2>/dev/null || true

    set_timezone
    install_pkg frr iptables chrony

    enable_ip_forward

    # Настройка iptables
    iptables -F
    iptables -t nat -F
    save_iptables

    # OSPF (FRR) — участвует только интерфейс в сторону BR-RTR
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
  # 5. HQ-SRV (Основной сервер)
  # ====================================================================
  "hq-srv")
    echo "[*] Configuring HQ-SRV..."

    # Подъем сети в VLAN 100
    ip addr add 10.100.0.2/30 dev ens1 2>/dev/null || true
    ip route add default via 10.100.0.1 2>/dev/null || true

    set_timezone
    install_pkg bind chrony openssh-server

    # NTP Клиент
    cat <<EOF > /etc/chrony.conf
server 172.16.1.1 iburst
EOF
    systemctl enable --now chronyd

    # Пользователь sshuser (UID 2027)
    useradd -u 2027 -m -s /bin/bash sshuser 2>/dev/null || true
    echo "sshuser:${PASS}" | chpasswd
    echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
    chmod 0440 /etc/sudoers.d/sshuser

    # Настройка SSH (Порт 2027)
    sed -i 's/#Port 22/Port 2027/' /etc/ssh/sshd_config
    sed -i 's/Port 22/Port 2027/' /etc/ssh/sshd_config
    echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    echo "MaxAuthTries 2" >> /etc/ssh/sshd_config
    echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
    echo "Authorized access only" > /etc/issue.net
    systemctl restart sshd || systemctl restart ssh || true

    # BIND9 DNS Server
    mkdir -p /etc/bind /var/lib/bind
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

zone "0.100.10.in-addr.arpa" {
    type master;
    file "/etc/bind/db.10.100.0";
};

zone "0.2.10.in-addr.arpa" {
    type master;
    file "/etc/bind/db.10.2.0";
};
EOF

    # Прямая зона DNS
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
EOF

    # Обратные зоны DNS (PTR)
    cat <<EOF > /etc/bind/db.10.100.0
\$TTL 86400
@ IN SOA hq-srv.${DOMAIN}. admin.${DOMAIN}. (1 604800 86400 2419200 604800)
@ IN NS hq-srv.${DOMAIN}.
2 IN PTR hq-srv.${DOMAIN}.
EOF

    cat <<EOF > /etc/bind/db.10.2.0
\$TTL 86400
@ IN SOA hq-srv.${DOMAIN}. admin.${DOMAIN}. (1 604800 86400 2419200 604800)
@ IN NS hq-srv.${DOMAIN}.
2 IN PTR br-srv.${DOMAIN}.
EOF

    systemctl enable --now bind9 2>/dev/null || systemctl enable --now named 2>/dev/null || true
    ;;

  # ====================================================================
  # 6. BR-SRV (Сервер филиала)
  # ====================================================================
  "br-srv")
    echo "[*] Configuring BR-SRV..."

    # Подъем сети в филиале
    ip addr add 10.2.0.2/28 dev ens1 2>/dev/null || true
    ip route add default via 10.2.0.1 2>/dev/null || true

    set_timezone
    install_pkg chrony openssh-server

    # NTP Клиент
    cat <<EOF > /etc/chrony.conf
server 172.16.2.1 iburst
EOF
    systemctl enable --now chronyd

    # Пользователь sshuser (UID 2027)
    useradd -u 2027 -m -s /bin/bash sshuser 2>/dev/null || true
    echo "sshuser:${PASS}" | chpasswd
    echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
    chmod 0440 /etc/sudoers.d/sshuser

    # Настройка SSH (Порт 2027)
    sed -i 's/#Port 22/Port 2027/' /etc/ssh/sshd_config
    sed -i 's/Port 22/Port 2027/' /etc/ssh/sshd_config
    echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    echo "MaxAuthTries 2" >> /etc/ssh/sshd_config
    echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
    echo "Authorized access only" > /etc/issue.net
    systemctl restart sshd || systemctl restart ssh || true
    ;;

  # ====================================================================
  # 7. HQ-CLI (Рабочая станция)
  # ====================================================================
  "hq-cli")
    echo "[*] Configuring HQ-CLI..."

    # Клиент получает IP по DHCP, но задаем временный для первого запуска при необходимости
    dhcpcd ens1 2>/dev/null || dhclient ens1 2>/dev/null || true

    set_timezone
    install_pkg chrony

    cat <<EOF > /etc/chrony.conf
server 172.16.1.1 iburst
EOF
    systemctl enable --now chronyd
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
