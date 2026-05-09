#!/bin/sh
# ============================================================
# WireGuard Server Entrypoint
# Host target : Ubuntu 22.04
# Image       : alpine
# Mode        : host network
#
# Tujuan:
# - Tanpa privileged: true
# - Ephemeral: interface, route, iptables dibersihkan saat stop
# - Tidak merusak koneksi host
# - Tidak flush iptables
# - Tidak mengubah default route
# ============================================================

set -eu

echo "[WG-SERVER] Installing required packages..."
apk add --no-cache \
    wireguard-tools \
    iptables \
    ip6tables \
    iproute2 \
    procps \
    kmod \
    2>/dev/null

# ------------------------------------------------------------
# Default variable fallback
# ------------------------------------------------------------
WG_INTERFACE="${WG_INTERFACE:-wg-server}"
WG_SERVER_IP="${WG_SERVER_IP:-100.10.11.1}"
WG_SERVER_CIDR="${WG_SERVER_CIDR:-24}"
WG_SERVER_PORT="${WG_SERVER_PORT:-51820}"
WG_MTU="${WG_MTU:-1420}"

WG_ENABLE_IPV4_FORWARD="${WG_ENABLE_IPV4_FORWARD:-1}"
WG_OPEN_FIREWALL_PORT="${WG_OPEN_FIREWALL_PORT:-1}"
WG_ENABLE_FORWARD_RULES="${WG_ENABLE_FORWARD_RULES:-1}"
WG_ENABLE_NAT="${WG_ENABLE_NAT:-0}"

WAN_IFACE="${WAN_IFACE:-}"
NAT_OUT_IFACE="${NAT_OUT_IFACE:-eth0}"
NAT_SOURCE_CIDR="${NAT_SOURCE_CIDR:-100.10.11.0/24}"

WG_SERVER_PRIVATE_KEY="${WG_SERVER_PRIVATE_KEY:-}"

if [ -z "$WG_SERVER_PRIVATE_KEY" ] || [ "$WG_SERVER_PRIVATE_KEY" = "ISI_PRIVATE_KEY_SERVER" ]; then
    echo "[WG-SERVER] ERROR: WG_SERVER_PRIVATE_KEY belum diisi di .env"
    echo "[WG-SERVER] Generate dulu dengan: ./generate-keys.sh"
    exit 1
fi

# ------------------------------------------------------------
# Cek /dev/net/tun
# ------------------------------------------------------------
if [ ! -e /dev/net/tun ]; then
    echo "[WG-SERVER] ERROR: /dev/net/tun tidak tersedia."
    echo "[WG-SERVER] Pastikan docker-compose.yml memiliki:"
    echo "            devices:"
    echo "              - /dev/net/tun:/dev/net/tun"
    exit 1
fi

# ------------------------------------------------------------
# Simpan nilai awal ip_forward host
# ------------------------------------------------------------
ORIGINAL_IPV4_FORWARD="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
echo "[WG-SERVER] Original host net.ipv4.ip_forward=${ORIGINAL_IPV4_FORWARD}"

if [ "$WG_ENABLE_IPV4_FORWARD" = "1" ]; then
    CURRENT_IPV4_FORWARD="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"

    if [ "$CURRENT_IPV4_FORWARD" = "1" ]; then
        echo "[WG-SERVER] IPv4 forwarding already enabled."
    else
        echo "[WG-SERVER] Enabling IPv4 forwarding ephemerally..."

        if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
            echo "[WG-SERVER] IPv4 forwarding enabled successfully."
        else
            echo "[WG-SERVER] WARNING: cannot change net.ipv4.ip_forward from inside container."
            echo "[WG-SERVER] WARNING: Please enable it on the host with:"
            echo "[WG-SERVER]          sysctl -w net.ipv4.ip_forward=1"
            echo "[WG-SERVER] Continuing because this may already be controlled by the host/container runtime."
        fi
    fi
else
    echo "[WG-SERVER] IPv4 forwarding not changed by container."
fi

CURRENT_IPV4_FORWARD="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)"
echo "[WG-SERVER] Current host net.ipv4.ip_forward=${CURRENT_IPV4_FORWARD}"

if [ "$WG_ENABLE_IPV4_FORWARD" = "1" ] && [ "$CURRENT_IPV4_FORWARD" != "1" ]; then
    echo "[WG-SERVER] WARNING: IPv4 forwarding is still not enabled."
    echo "[WG-SERVER] WARNING: WireGuard forwarding between peers/networks may not work."
fi

# ------------------------------------------------------------
# Cleanup helper
# ------------------------------------------------------------
delete_iptables_rule() {
    # Usage:
    #   delete_iptables_rule iptables -A INPUT ...
    #
    # Fungsi ini mengubah -A menjadi -D lalu mencoba hapus rule.
    CMD="$*"
    DEL_CMD="$(echo "$CMD" | sed 's/ -A / -D /')"
    sh -c "$DEL_CMD" 2>/dev/null || true
}

add_iptables_rule_once() {
    # Usage:
    #   add_iptables_rule_once iptables -A INPUT ...
    #
    # Cek rule dengan -C, jika belum ada baru -A.
    CMD="$*"
    CHECK_CMD="$(echo "$CMD" | sed 's/ -A / -C /')"

    if sh -c "$CHECK_CMD" 2>/dev/null; then
        echo "[WG-SERVER] iptables rule already exists: $CMD"
    else
        echo "[WG-SERVER] Adding iptables rule: $CMD"
        sh -c "$CMD"
    fi
}

# ------------------------------------------------------------
# Bersihkan sisa interface dari run sebelumnya, jika ada
# ------------------------------------------------------------
if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
    echo "[WG-SERVER] Existing interface $WG_INTERFACE found. Bringing down first..."
    wg-quick down "$WG_INTERFACE" 2>/dev/null || ip link delete "$WG_INTERFACE" 2>/dev/null || true
fi

mkdir -p /etc/wireguard
CONF_FILE="/etc/wireguard/${WG_INTERFACE}.conf"

# ------------------------------------------------------------
# Build WireGuard config
# Table = off agar wg-quick tidak utak-atik routing table otomatis.
# Route peer akan ditambahkan manual dan spesifik.
# ------------------------------------------------------------
cat > "$CONF_FILE" << EOF
[Interface]
Address = ${WG_SERVER_IP}/${WG_SERVER_CIDR}
ListenPort = ${WG_SERVER_PORT}
PrivateKey = ${WG_SERVER_PRIVATE_KEY}
MTU = ${WG_MTU}
Table = off

EOF

# ------------------------------------------------------------
# Fungsi tambah peer
# ------------------------------------------------------------
add_peer_to_conf() {
    IDX="$1"

    eval PEER_NAME="\${PEER${IDX}_NAME:-}"
    eval PEER_PUBLIC_KEY="\${PEER${IDX}_PUBLIC_KEY:-}"
    eval PEER_ALLOWED_IPS="\${PEER${IDX}_ALLOWED_IPS:-}"
    eval PEER_KEEPALIVE="\${PEER${IDX}_PERSISTENT_KEEPALIVE:-}"

    if [ -z "$PEER_PUBLIC_KEY" ] || [ -z "$PEER_ALLOWED_IPS" ]; then
        return 0
    fi

    echo "[WG-SERVER] Adding peer ${IDX}: ${PEER_NAME:-peer-$IDX}"

    {
        echo "# ${PEER_NAME:-peer-$IDX}"
        echo "[Peer]"
        echo "PublicKey = ${PEER_PUBLIC_KEY}"
        echo "AllowedIPs = ${PEER_ALLOWED_IPS}"

        if [ -n "$PEER_KEEPALIVE" ] && [ "$PEER_KEEPALIVE" != "0" ]; then
            echo "PersistentKeepalive = ${PEER_KEEPALIVE}"
        fi

        echo ""
    } >> "$CONF_FILE"
}

for i in 1 2 3 4 5; do
    add_peer_to_conf "$i"
done

chmod 600 "$CONF_FILE"

echo "[WG-SERVER] Generated config:"
echo "------------------------------------------------------------"
sed 's/PrivateKey = .*/PrivateKey = ***hidden***/' "$CONF_FILE"
echo "------------------------------------------------------------"

# ------------------------------------------------------------
# Naikkan interface WireGuard
# ------------------------------------------------------------
echo "[WG-SERVER] Bringing up interface ${WG_INTERFACE}..."
wg-quick up "$WG_INTERFACE"

# ------------------------------------------------------------
# Tambah route spesifik untuk AllowedIPs peer.
# Tidak menambahkan:
# - 0.0.0.0/0
# - ::/0
# - IP server sendiri
# ------------------------------------------------------------
ROUTES_ADDED_FILE="/tmp/wg-server-routes-added"
: > "$ROUTES_ADDED_FILE"

add_route_for_prefix() {
    PREFIX="$1"

    # Trim spasi
    PREFIX="$(echo "$PREFIX" | xargs)"

    [ -z "$PREFIX" ] && return 0

    case "$PREFIX" in
        "0.0.0.0/0"|"::/0")
            echo "[WG-SERVER] Skipping default route prefix: $PREFIX"
            return 0
            ;;
    esac

    # Hindari route address interface server sendiri
    if [ "$PREFIX" = "${WG_SERVER_IP}/32" ] || [ "$PREFIX" = "${WG_SERVER_IP}/${WG_SERVER_CIDR}" ]; then
        echo "[WG-SERVER] Skipping server own prefix: $PREFIX"
        return 0
    fi

    # Hanya IPv4 untuk script ini
    echo "$PREFIX" | grep -q ":" && {
        echo "[WG-SERVER] Skipping IPv6 prefix in this script: $PREFIX"
        return 0
    }

    if ip route show "$PREFIX" | grep -q "$WG_INTERFACE"; then
        echo "[WG-SERVER] Route already exists: $PREFIX dev $WG_INTERFACE"
    else
        echo "[WG-SERVER] Adding route: $PREFIX dev $WG_INTERFACE"
        ip route replace "$PREFIX" dev "$WG_INTERFACE"
    fi

    echo "$PREFIX" >> "$ROUTES_ADDED_FILE"
}

collect_peer_routes() {
    IDX="$1"
    eval PEER_ALLOWED_IPS="\${PEER${IDX}_ALLOWED_IPS:-}"

    [ -z "$PEER_ALLOWED_IPS" ] && return 0

    OLD_IFS="$IFS"
    IFS=","
    for prefix in $PEER_ALLOWED_IPS; do
        add_route_for_prefix "$prefix"
    done
    IFS="$OLD_IFS"
}

for i in 1 2 3 4 5; do
    collect_peer_routes "$i"
done

# ------------------------------------------------------------
# iptables ephemeral
# Tidak flush firewall host.
# Hanya tambah rule spesifik.
# ------------------------------------------------------------
IPTABLES_RULES_FILE="/tmp/wg-server-iptables-rules"
: > "$IPTABLES_RULES_FILE"

remember_rule() {
    echo "$*" >> "$IPTABLES_RULES_FILE"
}

if [ "$WG_OPEN_FIREWALL_PORT" = "1" ]; then
    if [ -n "$WAN_IFACE" ]; then
        RULE="iptables -A INPUT -i ${WAN_IFACE} -p udp --dport ${WG_SERVER_PORT} -j ACCEPT"
    else
        RULE="iptables -A INPUT -p udp --dport ${WG_SERVER_PORT} -j ACCEPT"
    fi

    add_iptables_rule_once $RULE
    remember_rule $RULE
fi

if [ "$WG_ENABLE_FORWARD_RULES" = "1" ]; then
    RULE="iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT"
    add_iptables_rule_once $RULE
    remember_rule $RULE

    RULE="iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT"
    add_iptables_rule_once $RULE
    remember_rule $RULE
fi

if [ "$WG_ENABLE_NAT" = "1" ]; then
    RULE="iptables -t nat -A POSTROUTING -s ${NAT_SOURCE_CIDR} -o ${NAT_OUT_IFACE} -j MASQUERADE"
    add_iptables_rule_once $RULE
    remember_rule $RULE
else
    echo "[WG-SERVER] NAT disabled. No MASQUERADE rule added."
fi

# ------------------------------------------------------------
# Status
# ------------------------------------------------------------
echo ""
echo "[WG-SERVER] Interface ${WG_INTERFACE} is UP."
echo "[WG-SERVER] WireGuard status:"
wg show "$WG_INTERFACE" || true

echo ""
echo "[WG-SERVER] Routes related to ${WG_INTERFACE}:"
ip route show dev "$WG_INTERFACE" || true

echo ""
echo "[WG-SERVER] Listening UDP port:"
ss -lunp 2>/dev/null | grep ":${WG_SERVER_PORT}" || true

echo ""
echo "[WG-SERVER] Running. Semua setting ephemeral akan dibersihkan saat container stop."

# ------------------------------------------------------------
# Cleanup saat container stop
# ------------------------------------------------------------
cleanup() {
    echo ""
    echo "[WG-SERVER] Stop signal received. Cleaning up..."

    # Hapus iptables rules yang ditambahkan
    if [ -f "$IPTABLES_RULES_FILE" ]; then
        tac "$IPTABLES_RULES_FILE" 2>/dev/null | while read -r RULE; do
            [ -z "$RULE" ] && continue
            echo "[WG-SERVER] Deleting iptables rule: $RULE"
            delete_iptables_rule $RULE
        done
    fi

    # Hapus route yang ditambahkan
    if [ -f "$ROUTES_ADDED_FILE" ]; then
        tac "$ROUTES_ADDED_FILE" 2>/dev/null | while read -r PREFIX; do
            [ -z "$PREFIX" ] && continue
            echo "[WG-SERVER] Deleting route: $PREFIX dev $WG_INTERFACE"
            ip route del "$PREFIX" dev "$WG_INTERFACE" 2>/dev/null || true
        done
    fi

    # Turunkan WireGuard interface
    echo "[WG-SERVER] Bringing down ${WG_INTERFACE}..."
    wg-quick down "$WG_INTERFACE" 2>/dev/null || ip link delete "$WG_INTERFACE" 2>/dev/null || true

    # Kembalikan ip_forward ke nilai awal
    if [ "$WG_ENABLE_IPV4_FORWARD" = "1" ]; then
        echo "[WG-SERVER] Restoring net.ipv4.ip_forward=${ORIGINAL_IPV4_FORWARD}"
        sysctl -w "net.ipv4.ip_forward=${ORIGINAL_IPV4_FORWARD}" >/dev/null 2>&1 || true
    fi

    echo "[WG-SERVER] Cleanup complete."
    exit 0
}

trap cleanup TERM INT

while true; do
    sleep 30 &
    wait $!
done
