#!/bin/sh
# ============================================================
# Generate WireGuard server keypair
# ============================================================

set -eu

if ! command -v wg >/dev/null 2>&1; then
    echo "[KEYGEN] wireguard-tools belum tersedia di host."
    echo "[KEYGEN] Install di Ubuntu 22.04:"
    echo "         sudo apt update"
    echo "         sudo apt install -y wireguard-tools"
    exit 1
fi

umask 077

if [ -f server_privatekey ] || [ -f server_publickey ]; then
    echo "[KEYGEN] File key sudah ada:"
    [ -f server_privatekey ] && echo "         - server_privatekey"
    [ -f server_publickey ] && echo "         - server_publickey"
    echo ""
    echo "[KEYGEN] Hapus file tersebut jika ingin generate ulang."
    exit 1
fi

wg genkey | tee server_privatekey | wg pubkey > server_publickey

echo "[KEYGEN] Generated:"
echo "         server_privatekey"
echo "         server_publickey"
echo ""
echo "[KEYGEN] Server private key:"
cat server_privatekey
echo ""
echo "[KEYGEN] Server public key:"
cat server_publickey
echo ""
echo "[KEYGEN] Masukkan isi server_privatekey ke .env:"
echo "         WG_SERVER_PRIVATE_KEY=<isi server_privatekey>"
echo ""
echo "[KEYGEN] Masukkan server_publickey ke konfigurasi client sebagai:"
echo "         WG_SERVER_PUBLIC_KEY=<isi server_publickey>"