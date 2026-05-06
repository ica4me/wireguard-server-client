#!/bin/sh
# ============================================================
#  WireGuard Server Entrypoint
#  Semua setting EPHEMERAL - bersih saat container mati
# ============================================================
set -e

echo "[WG] Installing wireguard-tools & iptables..."
apk add --no-cache wireguard-tools iptables iproute2 2>/dev/null

# 1. Cek IP Forwarding di host
echo "[WG] IP forwarding host status: $(cat /proc/sys/net/ipv4/ip_forward)"
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
    echo "[WG] PERINGATAN: ip_forward belum aktif di host! Jalankan: sysctl -w net.ipv4.ip_forward=1"
fi

# 2. Bangun konfigurasi WireGuard Server
echo "[WG] Building WireGuard Server config for interface: ${WG_INTERFACE}..."
mkdir -p /etc/wireguard

# PostUp: MASQUERADE trafik dari subnet tunnel agar bisa akses internet/LAN via interface utama host
POSTUP="iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT"
POSTUP="${POSTUP}; iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT"
POSTUP="${POSTUP}; iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${HOST_PUBLIC_IFACE} -j MASQUERADE"

# PreDown: Bersihkan rule iptables saat container mati
PREDOWN="iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT"
PREDOWN="${PREDOWN}; iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT"
PREDOWN="${PREDOWN}; iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${HOST_PUBLIC_IFACE} -j MASQUERADE"

cat > /etc/wireguard/${WG_INTERFACE}.conf << EOF
[Interface]
Address     = ${WG_SERVER_IP}
ListenPort  = ${WG_LISTEN_PORT}
PrivateKey  = ${WG_SERVER_PRIVATE_KEY}
MTU         = ${WG_MTU}
PostUp      = ${POSTUP}
PreDown     = ${PREDOWN}

# Client 1
[Peer]
PublicKey   = ${WG_PEER1_PUBLIC_KEY}
AllowedIPs  = ${WG_PEER1_ALLOWED_IPS}
EOF

# 3. Naikan interface
echo "[WG] Bringing up interface ${WG_INTERFACE}..."
wg-quick up ${WG_INTERFACE}
echo "[WG] Interface ${WG_INTERFACE} UP - status:"
wg show ${WG_INTERFACE}

# 4. Trap sinyal - cleanup saat container di-stop
cleanup() {
    echo ""
    echo "[WG] SIGTERM diterima - membersihkan ${WG_INTERFACE}..."
    wg-quick down ${WG_INTERFACE} 2>/dev/null || true
    echo "[WG] Cleanup selesai. Container mati."
    exit 0
}

trap cleanup TERM INT

# 5. Loop hidup (blocking)
while true; do
    sleep 30 &
    wait $!
done