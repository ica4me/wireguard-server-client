#!/bin/sh
# ============================================================
#  WireGuard Client Entrypoint
#  VM: tunnel-wg-client | Image: alpine | Mode: host network
#  Semua setting EPHEMERAL — bersih saat container mati
# ============================================================
set -e

echo "[WG] Installing wireguard-tools & iptables..."
apk add --no-cache wireguard-tools iptables ip6tables iproute2 2>/dev/null

# ── 1. IP Forwarding — dikelola HOST via /etc/sysctl.conf ─
# Tidak diset dari container. Pastikan host sudah:
#   echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p
echo "[WG] IP forwarding host status: $(cat /proc/sys/net/ipv4/ip_forward)"
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || \
    echo "[WG] PERINGATAN: ip_forward belum aktif di host! Jalankan: sysctl -w net.ipv4.ip_forward=1"

# ── 2. Bangun konfigurasi WireGuard dari env vars ─────────
echo "[WG] Building WireGuard config for interface: ${WG_INTERFACE}..."
mkdir -p /etc/wireguard

# PostUp: MASQUERADE ke semua LAN iface
POSTUP="iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT"
POSTUP="${POSTUP}; iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT"
POSTUP="${POSTUP}; iptables -t nat -A POSTROUTING -s 100.10.11.0/24 -o ${LAN_IFACE_1} -j MASQUERADE"
POSTUP="${POSTUP}; iptables -t nat -A POSTROUTING -s 100.10.11.0/24 -o ${LAN_IFACE_2} -j MASQUERADE"
POSTUP="${POSTUP}; iptables -t nat -A POSTROUTING -s 100.10.11.0/24 -o ${LAN_IFACE_3} -j MASQUERADE"
POSTUP="${POSTUP}; iptables -t nat -A POSTROUTING -s 100.10.11.0/24 -o ${LAN_IFACE_4} -j MASQUERADE"

# PreDown: bersihkan semua rule saat container mati
PREDOWN="iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT"
PREDOWN="${PREDOWN}; iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT"
PREDOWN="${PREDOWN}; iptables -t nat -D POSTROUTING -s 100.10.11.0/24 -o ${LAN_IFACE_1} -j MASQUERADE"
PREDOWN="${PREDOWN}; iptables -t nat -D POSTROUTING -s 100.10.11.0/24 -o ${LAN_IFACE_2} -j MASQUERADE"
PREDOWN="${PREDOWN}; iptables -t nat -D POSTROUTING -s 100.10.11.0/24 -o ${LAN_IFACE_3} -j MASQUERADE"
PREDOWN="${PREDOWN}; iptables -t nat -D POSTROUTING -s 100.10.11.0/24 -o ${LAN_IFACE_4} -j MASQUERADE"

cat > /etc/wireguard/${WG_INTERFACE}.conf << EOF
[Interface]
Address     = ${WG_CLIENT_IP}/24
PrivateKey  = ${WG_CLIENT_PRIVATE_KEY}
MTU         = ${WG_MTU}
PostUp      = ${POSTUP}
PreDown     = ${PREDOWN}

[Peer]
PublicKey           = ${WG_SERVER_PUBLIC_KEY}
Endpoint            = ${WG_SERVER_ENDPOINT}:${WG_SERVER_PORT}
AllowedIPs          = ${WG_ALLOWED_IPS}
PersistentKeepalive = ${WG_KEEPALIVE}
EOF

# ── 3. Naikan interface WireGuard ─────────────────────────
echo "[WG] Bringing up interface ${WG_INTERFACE}..."
wg-quick up ${WG_INTERFACE}
echo "[WG] Interface ${WG_INTERFACE} UP — status:"
wg show ${WG_INTERFACE}

echo ""
echo "[WG] Routing info:"
ip route show | grep -E "100\.10\.|172\.16\." || true

echo ""
echo "[WG] Container running — semua setting akan dihapus saat container mati."

# ── 4. Trap sinyal → cleanup saat container di-stop ───────
cleanup() {
    echo ""
    echo "[WG] SIGTERM diterima — membersihkan ${WG_INTERFACE}..."
    wg-quick down ${WG_INTERFACE} 2>/dev/null || true
    echo "[WG] Cleanup selesai. Container mati."
    exit 0
}
trap cleanup TERM INT

# ── 5. Loop hidup (blocking) ──────────────────────────────
while true; do
    sleep 30 &
    wait $!
done
