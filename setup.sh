#!/bin/bash
# --- DEMO EXAM AUTOMATED SETUP SCRIPT FOR ALT LINUX ---

DOMAIN="au-team.irpo"
PASS="P@ssw0rd"
TIMEZONE="Europe/Moscow"

timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true

echo "========================================="
echo "       SELECT ROLE FOR THIS NODE"
echo "========================================="
echo "1) ISP     (Provider Router)"
echo "2) HQ-RTR  (Central Office Router)"
echo "3) HQ-SRV  (Central Server + DNS + SSH)"
echo "4) HQ-CLI  (Client - DHCP receiver)"
echo "5) BR-RTR  (Branch Office Router)"
echo "6) BR-FW   (Branch Firewall)"
echo "7) BR-SRV  (Branch Server + SSH)"
echo "========================================="
read -p "Enter role number (1-7): " ROLE

case $ROLE in
    1)
        echo "[+] Configuring ISP..."
        hostnamectl set-hostname isp
        
        # ETC/NET CONFIG
        mkdir -p /etc/net/ifaces/ens2 /etc/net/ifaces/ens3
        cat << 'EOF' > /etc/net/ifaces/ens2/options
TYPE=eth
DISABLED=no
EOF
        echo "172.16.1.1/28" > /etc/net/ifaces/ens2/ipv4address

        cat << 'EOF' > /etc/net/ifaces/ens3/options
TYPE=eth
DISABLED=no
EOF
        echo "172.16.2.1/28" > /etc/net/ifaces/ens3/ipv4address

        # LIVE APPLY
        ip link set dev ens2 up
        ip link set dev ens3 up
        ip addr flush dev ens2 2>/dev/null
        ip addr flush dev ens3 2>/dev/null
        ip addr add 172.16.1.1/28 dev ens2
        ip addr add 172.16.2.1/28 dev ens3

        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        iptables -F
        iptables -t nat -F
        iptables -t nat -A POSTROUTING -o ens1 -j MASQUERADE
        iptables-save > /etc/sysconfig/iptables
        systemctl enable --now iptables 2>/dev/null || true
        echo "[V] ISP configured successfully!"
        ;;

    2)
        echo "[+] Configuring HQ-RTR..."
        hostnamectl set-hostname hq-rtr.au-team.irpo
        
        useradd -m -s /bin/bash net_admin 2>/dev/null || true
        echo "net_admin:$PASS" | chpasswd
        echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin

        # BASE INTERFACES
        mkdir -p /etc/net/ifaces/ens1 /etc/net/ifaces/ens2
        cat << 'EOF' > /etc/net/ifaces/ens1/options
TYPE=eth
DISABLED=no
EOF
        echo "172.16.1.2/28" > /etc/net/ifaces/ens1/ipv4address
        echo "default via 172.16.1.1" > /etc/net/ifaces/ens1/ipv4route

        cat << 'EOF' > /etc/net/ifaces/ens2/options
TYPE=eth
DISABLED=no
EOF

        # LIVE APPLY PHYSICAL
        ip link set dev ens1 up
        ip link set dev ens2 up
        ip addr flush dev ens1 2>/dev/null
        ip addr add 172.16.1.2/28 dev ens1
        ip route add default via 172.16.1.1 2>/dev/null || true

        # VLAN CONFIGURATION FOR ALT LINUX (/etc/net)
        # VLAN 100
        mkdir -p /etc/net/ifaces/ens2.100
        cat << 'EOF' > /etc/net/ifaces/ens2.100/options
TYPE=vlan
HOST=ens2
VID=100
DISABLED=no
EOF
        echo "192.168.100.1/27" > /etc/net/ifaces/ens2.100/ipv4address

        # VLAN 200
        mkdir -p /etc/net/ifaces/ens2.200
        cat << 'EOF' > /etc/net/ifaces/ens2.200/options
TYPE=vlan
HOST=ens2
VID=200
DISABLED=no
EOF
        echo "192.168.200.1/28" > /etc/net/ifaces/ens2.200/ipv4address

        # VLAN 999
        mkdir -p /etc/net/ifaces/ens2.999
        cat << 'EOF' > /etc/net/ifaces/ens2.999/options
TYPE=vlan
HOST=ens2
VID=999
DISABLED=no
EOF
        echo "192.168.99.1/29" > /etc/net/ifaces/ens2.999/ipv4address

        # LIVE APPLY VLANS
        for vlan in 100 200 999; do
            ip link add link ens2 name ens2.$vlan type vlan id $vlan 2>/dev/null || true
            ip link set dev ens2.$vlan up
        done
        ip addr flush dev ens2.100 2>/dev/null; ip addr add 192.168.100.1/27 dev ens2.100
        ip addr flush dev ens2.200 2>/dev/null; ip addr add 192.168.200.1/28 dev ens2.200
        ip addr flush dev ens2.999 2>/dev/null; ip addr add 192.168.99.1/29 dev ens2.999

        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        iptables -t nat -A POSTROUTING -o ens1 -j MASQUERADE 2>/dev/null || true

        # GRE TUNNEL
        ip tunnel del gre1 2>/dev/null || true
        ip tunnel add gre1 mode gre remote 172.16.2.2 local 172.16.1.2 ttl 255
        ip addr add 10.10.10.1/30 dev gre1
        ip link set gre1 up

        # SERVICES (IGNORE APT ERRORS IF NO INTERNET)
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y dnsmasq frr >/dev/null 2>&1 || true

        cat << 'EOF' > /etc/dnsmasq.d/dhcp-hq.conf
interface=ens2.200
dhcp-range=192.168.200.2,192.168.200.14,255.255.255.240,12h
dhcp-option=option:router,192.168.200.1
dhcp-option=option:dns-server,192.168.100.10
dhcp-option=option:domain-search,au-team.irpo
EOF
        systemctl enable --now dnsmasq 2>/dev/null || true

        cat << 'EOF' > /etc/frr/frr.conf
frr version 8.1
frr defaults traditional
hostname hq-rtr
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
router ospf
 ospf router-id 10.10.10.1
 network 10.10.10.0/30 area 0
 network 192.168.100.0/27 area 0
 network 192.168.200.0/28 area 0
EOF
        chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
        systemctl enable --now frr 2>/dev/null || true
        echo "[V] HQ-RTR configured successfully!"
        ;;

    3)
        echo "[+] Configuring HQ-SRV..."
        hostnamectl set-hostname hq-srv.au-team.irpo
        mkdir -p /etc/net/ifaces/ens1
        cat << 'EOF' > /etc/net/ifaces/ens1/options
TYPE=eth
DISABLED=no
EOF
        echo "192.168.100.10/27" > /etc/net/ifaces/ens1/ipv4address
        echo "default via 192.168.100.1" > /etc/net/ifaces/ens1/ipv4route

        ip link set dev ens1 up
        ip addr flush dev ens1 2>/dev/null
        ip addr add 192.168.100.10/27 dev ens1
        ip route add default via 192.168.100.1 2>/dev/null || true

        useradd -u 2027 -m -s /bin/bash sshuser 2>/dev/null || true
        echo "sshuser:$PASS" | chpasswd
        echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser

        echo "Authorized access only" > /etc/issue.net
        cat << 'EOF' > /etc/ssh/sshd_config.d/custom_sec.conf
Port 2027
AllowUsers sshuser
MaxAuthTries 2
Banner /etc/issue.net
EOF
        systemctl restart sshd 2>/dev/null || true

        apt-get update >/dev/null 2>&1 || true
        apt-get install -y bind bind-utils >/dev/null 2>&1 || true

        cat << 'EOF' > /etc/bind/options.conf
options {
    directory "/var/lib/bind";
    forwarders { 77.88.8.7; 77.88.8.3; };
    allow-query { any; };
    listen-on { any; };
};
EOF
        cat << 'EOF' >> /etc/bind/named.conf
zone "au-team.irpo" { type master; file "/etc/bind/db.au-team.irpo"; };
zone "100.168.192.in-addr.arpa" { type master; file "/etc/bind/db.192.168.100"; };
zone "1.20.10.in-addr.arpa" { type master; file "/etc/bind/db.10.20.1"; };
EOF

        cat << 'EOF' > /etc/bind/db.au-team.irpo
$TTL 604800
@ IN SOA hq-srv.au-team.irpo. root.au-team.irpo. ( 2 604800 86400 2419200 604800 )
@ IN NS hq-srv.au-team.irpo.
hq-rtr  IN A 172.16.1.2
br-rtr  IN A 172.16.2.2
br-fw   IN A 10.20.0.2
hq-srv  IN A 192.168.100.10
hq-cli  IN A 192.168.200.2
br-srv  IN A 10.20.1.10
docker  IN A 172.16.1.1
web     IN A 172.16.2.1
EOF

        cat << 'EOF' > /etc/bind/db.192.168.100
$TTL 604800
@ IN SOA hq-srv.au-team.irpo. root.au-team.irpo. ( 1 604800 86400 2419200 604800 )
@ IN NS hq-srv.au-team.irpo.
10 IN PTR hq-srv.au-team.irpo.
EOF
        cat << 'EOF' > /etc/bind/db.10.20.1
$TTL 604800
@ IN SOA hq-srv.au-team.irpo. root.au-team.irpo. ( 1 604800 86400 2419200 604800 )
@ IN NS hq-srv.au-team.irpo.
10 IN PTR br-srv.au-team.irpo.
EOF
        systemctl enable --now bind 2>/dev/null || true
        echo "[V] HQ-SRV configured successfully!"
        ;;

    4)
        echo "[+] Configuring HQ-CLI..."
        hostnamectl set-hostname hq-cli.au-team.irpo
        mkdir -p /etc/net/ifaces/ens1
        cat << 'EOF' > /etc/net/ifaces/ens1/options
TYPE=eth
BOOTPROTO=dhcp
DISABLED=no
EOF
        service network restart 2>/dev/null || true
        echo "[V] HQ-CLI configured successfully!"
        ;;

    5)
        echo "[+] Configuring BR-RTR..."
        hostnamectl set-hostname br-rtr.au-team.irpo
        useradd -m -s /bin/bash net_admin 2>/dev/null || true
        echo "net_admin:$PASS" | chpasswd
        echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin

        mkdir -p /etc/net/ifaces/ens1 /etc/net/ifaces/ens2
        cat << 'EOF' > /etc/net/ifaces/ens1/options
TYPE=eth
DISABLED=no
EOF
        echo "172.16.2.2/28" > /etc/net/ifaces/ens1/ipv4address
        echo "default via 172.16.2.1" > /etc/net/ifaces/ens1/ipv4route

        cat << 'EOF' > /etc/net/ifaces/ens2/options
TYPE=eth
DISABLED=no
EOF
        echo "10.20.0.1/30" > /etc/net/ifaces/ens2/ipv4address

        ip link set dev ens1 up
        ip link set dev ens2 up
        ip addr flush dev ens1 2>/dev/null
        ip addr flush dev ens2 2>/dev/null
        ip addr add 172.16.2.2/28 dev ens1
        ip addr add 10.20.0.1/30 dev ens2
        ip route add default via 172.16.2.1 2>/dev/null || true

        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        iptables -t nat -A POSTROUTING -o ens1 -j MASQUERADE 2>/dev/null || true

        ip tunnel del gre1 2>/dev/null || true
        ip tunnel add gre1 mode gre remote 172.16.1.2 local 172.16.2.2 ttl 255
        ip addr add 10.10.10.2/30 dev gre1
        ip link set gre1 up

        apt-get update >/dev/null 2>&1 || true
        apt-get install -y frr >/dev/null 2>&1 || true

        cat << 'EOF' > /etc/frr/frr.conf
frr version 8.1
frr defaults traditional
hostname br-rtr
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
router ospf
 ospf router-id 10.10.10.2
 network 10.10.10.0/30 area 0
 network 10.20.0.0/30 area 0
EOF
        chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
        systemctl enable --now frr 2>/dev/null || true
        echo "[V] BR-RTR configured successfully!"
        ;;

    6)
        echo "[+] Configuring BR-FW..."
        hostnamectl set-hostname br-fw.au-team.irpo
        mkdir -p /etc/net/ifaces/eth0 /etc/net/ifaces/eth1
        cat << 'EOF' > /etc/net/ifaces/eth0/options
TYPE=eth
DISABLED=no
EOF
        echo "10.20.0.2/30" > /etc/net/ifaces/eth0/ipv4address
        echo "default via 10.20.0.1" > /etc/net/ifaces/eth0/ipv4route

        cat << 'EOF' > /etc/net/ifaces/eth1/options
TYPE=eth
DISABLED=no
EOF
        echo "10.20.1.1/28" > /etc/net/ifaces/eth1/ipv4address

        ip link set dev eth0 up
        ip link set dev eth1 up
        ip addr flush dev eth0 2>/dev/null
        ip addr flush dev eth1 2>/dev/null
        ip addr add 10.20.0.2/30 dev eth0
        ip addr add 10.20.1.1/28 dev eth1
        ip route add default via 10.20.0.1 2>/dev/null || true

        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y frr >/dev/null 2>&1 || true

        cat << 'EOF' > /etc/frr/frr.conf
frr version 8.1
frr defaults traditional
hostname br-fw
router ospf
 ospf router-id 10.20.0.2
 network 10.20.0.0/30 area 0
 network 10.20.1.0/28 area 0
 passive-interface eth1
EOF
        chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
        systemctl enable --now frr 2>/dev/null || true
        echo "[V] BR-FW configured successfully!"
        ;;

    7)
        echo "[+] Configuring BR-SRV..."
        hostnamectl set-hostname br-srv.au-team.irpo
        mkdir -p /etc/net/ifaces/ens3
        cat << 'EOF' > /etc/net/ifaces/ens3/options
TYPE=eth
DISABLED=no
EOF
        echo "10.20.1.10/28" > /etc/net/ifaces/ens3/ipv4address
        echo "default via 10.20.1.1" > /etc/net/ifaces/ens3/ipv4route

        ip link set dev ens3 up
        ip addr flush dev ens3 2>/dev/null
        ip addr add 10.20.1.10/28 dev ens3
        ip route add default via 10.20.1.1 2>/dev/null || true

        useradd -u 2027 -m -s /bin/bash sshuser 2>/dev/null || true
        echo "sshuser:$PASS" | chpasswd
        echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser

        echo "Authorized access only" > /etc/issue.net
        cat << 'EOF' > /etc/ssh/sshd_config.d/custom_sec.conf
Port 2027
AllowUsers sshuser
MaxAuthTries 2
Banner /etc/issue.net
EOF
        systemctl restart sshd 2>/dev/null || true
        echo "[V] BR-SRV configured successfully!"
        ;;

    *)
        echo "[-] Invalid option!"
        exit 1
        ;;
esac
