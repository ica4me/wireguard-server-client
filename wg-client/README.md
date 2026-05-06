# WireGuard Client — Docker Setup

## Host: tunnel-wg-client (Ubuntu 22.04)

---

## Struktur File

```
wg-client/
├── docker-compose.yml   ← definisi service
├── .env                 ← semua konfigurasi (EDIT INI DULU!)
├── entrypoint.sh        ← script setup/teardown ephemeral
└── README.md
```

---

## Langkah Setup

### 1. Generate Key (jalankan di host atau VM lain)

```bash
# Generate private key client
wg genkey | tee client_privatekey | wg pubkey > client_publickey

cat client_privatekey   # → isi ke WG_CLIENT_PRIVATE_KEY di .env
cat client_publickey    # → daftarkan sebagai Peer di server WireGuard
```

### 2. Edit .env

```bash
nano .env
```

Wajib diisi:
| Variable | Keterangan |
|---|---|
| `WG_CLIENT_PRIVATE_KEY` | Private key hasil generate |
| `WG_SERVER_PUBLIC_KEY` | Public key server WireGuard (MikroTik) |
| `WG_SERVER_ENDPOINT` | IP publik / domain server |
| `WG_SERVER_PORT` | Port WireGuard server (default 51820) |
| `WG_CLIENT_IP` | IP tunnel untuk VM ini, contoh: 100.10.11.2 |

### 3. Daftarkan Peer di Server (MikroTik/WireGuard Server)

Tambahkan peer dengan:

- **Public Key**: isi dari `client_publickey`
- **Allowed Address**: `100.10.11.2/32`
- **Tambahkan route** di server: `172.16.1.0/24 - 172.16.5.0/24` → via `100.10.11.2`

### 4. Set permission entrypoint

```bash
chmod +x entrypoint.sh
```

### 5. Jalankan Container

```bash
docker compose up -d
```

### 6. Cek Status

```bash
# Lihat log container
docker compose logs -f wg-mikrotik

# Cek interface WireGuard di host
ip a show wg-mikrotik
wg show wg-mikrotik

# Cek routing
ip route | grep -E "100\.10\.|172\.16\."

# Cek iptables NAT
iptables -t nat -L POSTROUTING -n -v
```

---

## Topologi

```
[Client Tunnel Lain]
  100.10.11.x
       │
       ▼
[Server WireGuard / MikroTik]  ← public IP
  100.10.11.1
       │  tunnel 100.10.11.0/24
       ▼
[VM ini: tunnel-wg-client]
  wg-mikrotik: 100.10.11.2
  ens19: 172.16.1.11  ──→ 172.16.1.0/24
  ens20: 172.16.2.11  ──→ 172.16.2.0/24
  ens21: 172.16.4.11  ──→ 172.16.4.0/24
  ens22: 172.16.5.11  ──→ 172.16.5.0/24
```

Traffic dari client tunnel lain → masuk ke VM via WireGuard → di-MASQUERADE → ke LAN lokal.

---

## Stop / Ephemeral Behavior

```bash
# Stop container → interface wg-mikrotik HILANG, iptables BERSIH
docker compose stop

# Start lagi → semua setting dibuat ulang dari .env
docker compose start
```

---

## Troubleshooting

```bash
# Kernel module WireGuard belum load
modprobe wireguard

# Cek apakah handshake berhasil
watch -n2 wg show wg-mikrotik

# Ping ke tunnel server
ping 100.10.11.1

# Test routing dari tunnel ke LAN
# (dari client tunnel lain, ping 172.16.1.11)
```
