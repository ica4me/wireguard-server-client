#!/bin/sh
# ============================================================
# WireGuard Client Forward Router Entrypoint
# Image  : Alpine
# Mode   : Docker host network
# Tujuan :
# - WireGuard client UP
# - Auto-detect LAN interface dari LOCAL_NET_*
# - Auto-add FORWARD rules
# - Auto-add NAT/MASQUERADE
# - Cleanup saat container stop
# ============================================================

set -eu

echo "[WG-CLIENT] Installing required packages..."
apk add --no-cache \
    wireguard-tools \
    iptables \
    ip6tables \
    iproute2 \
    procps \
    2>/dev/null

# ------------------------------------------------------------
# Default variable fallback
# ------------------------------------------------------------
WG_INTERFACE="${WG_INTERFACE:-wg-mikrotik}"
WG_CLIENT_IP="${WG_CLIENT_IP:?WG_CLIENT_IP belum diisi}"
WG_CLIENT_CIDR="${WG_CLIENT_CIDR:-24}"
WG_CLIENT_PRIVATE_KEY="${WG_CLIENT_PRIVATE_KEY:?WG_CLIENT_PRIVATE_KEY belum diisi}"

WG_SERVER_PUBLIC_KEY="${WG_SERVER_PUBLIC_KEY:?WG_SERVER_PUBLIC_KEY belum diisi}"
WG_SERVER_ENDPOINT="${WG_SERVER_ENDPOINT:?WG_SERVER_ENDPOINT belum diisi}"
WG_SERVER_PORT="${WG_SERVER_PORT:?WG_SERVER_PORT belum diisi}"

WG_MTU="${WG_MTU:-1412}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-172.16.101.0/24}"

# Source subnet yang akan di-NAT ke LAN.
# Default: pakai WG_ALLOWED_IPS pertama.
WG_NAT_SOURCE_CIDR="${WG_NAT_SOURCE_CIDR:-}"

# 1 = tambah FORWARD rules
WG_ENABLE_FORWARD_RULES="${WG_ENABLE_FORWARD_RULES:-1}"

# 1 = tambah NAT MASQUERADE ke LOCAL_NET_*
WG_ENABLE_NAT="${WG_ENABLE_NAT:-1}"

# 1 = auto-detect interface dari route LOCAL_NET_*
WG_AUTO_DETECT_LAN_IFACE="${WG_AUTO_DETECT_LAN_IFACE:-1}"

# Jumlah maksimum LOCAL_NET_N yang akan diproses
WG_MAX_LOCAL_NETS="${WG_MAX_LOCAL_NETS:-20}"

# ------------------------------------------------------------
# Helper
# ------------------------------------------------------------
trim() {
    echo "$1" | xargs
}

first_ipv4_cidr_from_csv() {
    echo "$1" | tr ',' '\n' | while read -r item; do
        item="$(trim "$item")"
        [ -z "$item" ] && continue

        echo "$item" | grep -q ":" && continue
        echo "$item" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' || continue

        echo "$item"
        return 0
    done
}

detect_iface_for_net() {
    NET="$1"

    # Format umum:
    # 172.16.1.0/24 dev eth0 proto kernel scope link src 172.16.1.253
    ip -o route show "$NET" 2>/dev/null | awk '
        {
            for (i=1; i<=NF; i++) {
                if ($i == "dev") {
                    print $(i+1)
                    exit
                }
            }
        }
    '
}

iface_exists() {
    ip link show "$1" >/dev/null 2>&1
}

rule_exists() {
    sh -c "$*" >/dev/null 2>&1
}

add_rule_once() {
    CHECK_CMD="$1"
    ADD_CMD="$2"
    DESC="$3"

    if rule_exists "$CHECK_CMD"; then
        echo "[WG-CLIENT] Rule already exists: $DESC"
    else
        echo "[WG-CLIENT] Adding rule: $DESC"
        sh -c "$ADD_CMD"
    fi
}

delete_rule() {
    CMD="$1"
    DESC="$2"

    echo "[WG-CLIENT] Deleting rule: $DESC"
    sh -c "$CMD" 2>/dev/null || true
}

# ------------------------------------------------------------
# Cek /dev/net/tun
# ------------------------------------------------------------
if [ ! -e /dev/net/tun ]; then
    echo "[WG-CLIENT] ERROR: /dev/net/tun tidak tersedia."
    echo "[WG-CLIENT] Tambahkan di docker-compose.yml:"
    echo "            devices:"
    echo "              - /dev/net/tun:/dev/net/tun"
    exit 1
fi

# ------------------------------------------------------------
# IP forwarding
# ------------------------------------------------------------
IP_FORWARD_STATUS="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
echo "[WG-CLIENT] Host net.ipv4.ip_forward=${IP_FORWARD_STATUS}"

if [ "$IP_FORWARD_STATUS" != "1" ]; then
    echo "[WG-CLIENT] WARNING: ip_forward belum aktif."
    echo "[WG-CLIENT] Jalankan di host:"
    echo "[WG-CLIENT]   sysctl -w net.ipv4.ip_forward=1"
    echo "[WG-CLIENT]   echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ip-forward.conf"
    echo "[WG-CLIENT]   sysctl --system"
fi

# ------------------------------------------------------------
# Tentukan source NAT
# ------------------------------------------------------------
if [ -z "$WG_NAT_SOURCE_CIDR" ]; then
    WG_NAT_SOURCE_CIDR="$(first_ipv4_cidr_from_csv "$WG_ALLOWED_IPS" || true)"
fi

if [ -z "$WG_NAT_SOURCE_CIDR" ]; then
    echo "[WG-CLIENT] ERROR: WG_NAT_SOURCE_CIDR kosong dan tidak bisa diambil dari WG_ALLOWED_IPS."
    echo "[WG-CLIENT] Contoh:"
    echo "[WG-CLIENT]   WG_NAT_SOURCE_CIDR=172.16.101.0/24"
    exit 1
fi

echo "[WG-CLIENT] NAT source CIDR: ${WG_NAT_SOURCE_CIDR}"

# ------------------------------------------------------------
# Bersihkan interface lama jika ada
# ------------------------------------------------------------
if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
    echo "[WG-CLIENT] Existing interface ${WG_INTERFACE} found. Bringing down first..."
    wg-quick down "$WG_INTERFACE" 2>/dev/null || ip link delete "$WG_INTERFACE" 2>/dev/null || true
fi

# ------------------------------------------------------------
# Build WireGuard config
# Jangan pakai PostUp/PreDown untuk iptables.
# Rule dikelola manual oleh script agar lebih fleksibel.
# ------------------------------------------------------------
mkdir -p /etc/wireguard
CONF_FILE="/etc/wireguard/${WG_INTERFACE}.conf"

cat > "$CONF_FILE" <<EOF
[Interface]
Address = ${WG_CLIENT_IP}/${WG_CLIENT_CIDR}
PrivateKey = ${WG_CLIENT_PRIVATE_KEY}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${WG_SERVER_PUBLIC_KEY}
Endpoint = ${WG_SERVER_ENDPOINT}:${WG_SERVER_PORT}
AllowedIPs = ${WG_ALLOWED_IPS}
PersistentKeepalive = ${WG_KEEPALIVE}
EOF

chmod 600 "$CONF_FILE"

echo "[WG-CLIENT] Generated config:"
echo "------------------------------------------------------------"
sed 's/PrivateKey = .*/PrivateKey = ***hidden***/' "$CONF_FILE"
echo "------------------------------------------------------------"

# ------------------------------------------------------------
# Naikkan WireGuard
# ------------------------------------------------------------
echo "[WG-CLIENT] Bringing up interface ${WG_INTERFACE}..."
wg-quick up "$WG_INTERFACE"

# ------------------------------------------------------------
# File tracking rule untuk cleanup
# ------------------------------------------------------------
RULES_FILE="/tmp/${WG_INTERFACE}-iptables-rules"
: > "$RULES_FILE"

remember_delete_rule() {
    echo "$1|$2" >> "$RULES_FILE"
}

# ------------------------------------------------------------
# Tambah FORWARD + NAT per LOCAL_NET_N
# ------------------------------------------------------------
setup_lan_net() {
    IDX="$1"

    eval LOCAL_NET="\${LOCAL_NET_${IDX}:-}"
    eval LAN_IFACE_ENV="\${LAN_IFACE_${IDX}:-}"

    LOCAL_NET="$(trim "$LOCAL_NET")"
    LAN_IFACE_ENV="$(trim "$LAN_IFACE_ENV")"

    [ -z "$LOCAL_NET" ] && return 0

    echo ""
    echo "[WG-CLIENT] Processing LOCAL_NET_${IDX}=${LOCAL_NET}"

    LAN_IFACE=""

    if [ -n "$LAN_IFACE_ENV" ] && iface_exists "$LAN_IFACE_ENV"; then
        LAN_IFACE="$LAN_IFACE_ENV"
        echo "[WG-CLIENT] Using LAN_IFACE_${IDX}=${LAN_IFACE}"
    elif [ "$WG_AUTO_DETECT_LAN_IFACE" = "1" ]; then
        LAN_IFACE="$(detect_iface_for_net "$LOCAL_NET" || true)"

        if [ -n "$LAN_IFACE" ] && iface_exists "$LAN_IFACE"; then
            echo "[WG-CLIENT] Auto-detected interface for ${LOCAL_NET}: ${LAN_IFACE}"
        else
            echo "[WG-CLIENT] WARNING: cannot auto-detect interface for ${LOCAL_NET}. Skipping."
            return 0
        fi
    else
        echo "[WG-CLIENT] WARNING: LAN_IFACE_${IDX} kosong/tidak valid dan auto-detect disabled. Skipping ${LOCAL_NET}."
        return 0
    fi

    # Hindari NAT ke interface WireGuard sendiri
    if [ "$LAN_IFACE" = "$WG_INTERFACE" ]; then
        echo "[WG-CLIENT] WARNING: ${LOCAL_NET} resolved to WG interface ${WG_INTERFACE}. Skipping."
        return 0
    fi

    if [ "$WG_ENABLE_FORWARD_RULES" = "1" ]; then
        # Forward dari WireGuard ke LAN
        CHECK="iptables -C FORWARD -i ${WG_INTERFACE} -o ${LAN_IFACE} -j ACCEPT"
        ADD="iptables -A FORWARD -i ${WG_INTERFACE} -o ${LAN_IFACE} -j ACCEPT"
        DEL="iptables -D FORWARD -i ${WG_INTERFACE} -o ${LAN_IFACE} -j ACCEPT"

        add_rule_once "$CHECK" "$ADD" "FORWARD ${WG_INTERFACE} -> ${LAN_IFACE}"
        remember_delete_rule "$DEL" "FORWARD ${WG_INTERFACE} -> ${LAN_IFACE}"

        # Return traffic dari LAN ke WireGuard
        CHECK="iptables -C FORWARD -i ${LAN_IFACE} -o ${WG_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        ADD="iptables -A FORWARD -i ${LAN_IFACE} -o ${WG_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        DEL="iptables -D FORWARD -i ${LAN_IFACE} -o ${WG_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"

        add_rule_once "$CHECK" "$ADD" "FORWARD ${LAN_IFACE} -> ${WG_INTERFACE} RELATED,ESTABLISHED"
        remember_delete_rule "$DEL" "FORWARD ${LAN_IFACE} -> ${WG_INTERFACE} RELATED,ESTABLISHED"
    else
        echo "[WG-CLIENT] Forward rules disabled."
    fi

    if [ "$WG_ENABLE_NAT" = "1" ]; then
        CHECK="iptables -t nat -C POSTROUTING -s ${WG_NAT_SOURCE_CIDR} -d ${LOCAL_NET} -o ${LAN_IFACE} -j MASQUERADE"
        ADD="iptables -t nat -A POSTROUTING -s ${WG_NAT_SOURCE_CIDR} -d ${LOCAL_NET} -o ${LAN_IFACE} -j MASQUERADE"
        DEL="iptables -t nat -D POSTROUTING -s ${WG_NAT_SOURCE_CIDR} -d ${LOCAL_NET} -o ${LAN_IFACE} -j MASQUERADE"

        add_rule_once "$CHECK" "$ADD" "NAT ${WG_NAT_SOURCE_CIDR} -> ${LOCAL_NET} via ${LAN_IFACE}"
        remember_delete_rule "$DEL" "NAT ${WG_NAT_SOURCE_CIDR} -> ${LOCAL_NET} via ${LAN_IFACE}"
    else
        echo "[WG-CLIENT] NAT disabled for ${LOCAL_NET}."
    fi
}

i=1
while [ "$i" -le "$WG_MAX_LOCAL_NETS" ]; do
    setup_lan_net "$i"
    i=$((i + 1))
done

# ------------------------------------------------------------
# Status
# ------------------------------------------------------------
echo ""
echo "[WG-CLIENT] Interface ${WG_INTERFACE} is UP."
echo "[WG-CLIENT] WireGuard status:"
wg show "$WG_INTERFACE" || true

echo ""
echo "[WG-CLIENT] Routes related to WireGuard/local networks:"
ip route show | grep -E "(${WG_INTERFACE}|172\.16\.|10\.|192\.168\.)" || true

echo ""
echo "[WG-CLIENT] FORWARD rules related to ${WG_INTERFACE}:"
iptables -S FORWARD | grep "$WG_INTERFACE" || true

echo ""
echo "[WG-CLIENT] NAT rules:"
iptables -t nat -S POSTROUTING | grep -E "$WG_INTERFACE|MASQUERADE|${WG_NAT_SOURCE_CIDR}" || true

echo ""
echo "[WG-CLIENT] Running. Rules are ephemeral and will be cleaned on stop."

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
cleanup() {
    echo ""
    echo "[WG-CLIENT] Stop signal received. Cleaning up..."

    if [ -f "$RULES_FILE" ]; then
        tac "$RULES_FILE" 2>/dev/null | while IFS='|' read -r DEL_CMD DESC; do
            [ -z "$DEL_CMD" ] && continue
            delete_rule "$DEL_CMD" "$DESC"
        done
    fi

    echo "[WG-CLIENT] Bringing down ${WG_INTERFACE}..."
    wg-quick down "$WG_INTERFACE" 2>/dev/null || ip link delete "$WG_INTERFACE" 2>/dev/null || true

    echo "[WG-CLIENT] Cleanup complete."
    exit 0
}

trap cleanup TERM INT

while true; do
    sleep 30 &
    wait $!
done
