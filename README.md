# WireGuard Tunnel Docker: Server & Client

> Testing OS : Ubuntu 22.04/24.04 atau Linux systemd lain.  
> Mode Docker: `network_mode: host`, Interface WireGuard dibuat langsung pada network namespace host.
> Istilah Mikrotik = Server-VM

---

## 1. Gambaran Topologi

Contoh topologi yang dipakai:

```text
[Client Tunnel Lain]
  100.10.11.x
       |
       | WireGuard tunnel 100.10.11.0/24
       v
[Server WireGuard / MikroTik / Linux WG Server]
  Tunnel IP: 100.10.11.1
  UDP Port : 51820
       |
       | route via 100.10.11.2
       v
[VM Client Router: tunnel-wg-client]
  WG IP : 100.10.11.2
  LAN   : 172.16.1.0/24
          172.16.2.0/24
          172.16.3.0/24
          172.16.4.0/24
          172.16.5.0/24
```

Tujuan konfigurasi:

1. Client Docker membuat interface WireGuard, `wg-mikrotik`, di host.
2. VM client menjadi router menuju jaringan lokal `172.16.x.0/24`.
3. Server WireGuard mengetahui bahwa network `172.16.1.0/24` sampai `172.16.5.0/24` harus dikirim ke peer `100.10.11.2`.
4. Client tunnel lain dapat akses jaringan `172.16.x.0/24` melalui server WireGuard.

---

## 2. Struktur File

Download git

```
git clone https://github.com/ica4me/wireguard-server-client.git wireguard-conf
```

Isi ZIP/project:

```text
.
├─wireguard-conf
├── wg-server/
│   ├── docker-compose.yml
│   ├── entrypoint.sh
│   ├── example.env
│   ├── generate-keys.sh
│   └── README.md
│
└── wg-client/
    ├── docker-compose.yml
    ├── entrypoint.sh
    ├── example.env
    ├── Cara Deploy di VM.txt
    ├── client_privatekey
    └── client_publickey
```

Pada saat deployment, file `example.env` harus disalin menjadi `.env`:

```bash
cp example.env .env
nano .env
```

---

## 3. Prasyarat Host

Jalankan sebagai `root` atau gunakan `sudo`.

### 3.1 Update sistem

```bash
apt update
apt install -y curl ca-certificates gnupg lsb-release nano iproute2 iptables wireguard-tools
```

### 3.2 Pastikan kernel mendukung WireGuard

```bash
modprobe wireguard || true
lsmod | grep wireguard || true
wg --version
```

Jika `wg --version` berjalan normal, `wireguard-tools` sudah tersedia.

---

## 4. Instal Docker Jika Belum Ada

### 4.1 Cara cepat memakai script resmi Docker

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
```

Aktifkan dan jalankan Docker:

```bash
systemctl enable docker
systemctl start docker
systemctl status docker --no-pager
```

Cek Docker dan Docker Compose:

```bash
docker --version
docker compose version
```

### 4.2 Alternatif jika user non-root ingin menjalankan Docker

```bash
usermod -aG docker $USER
newgrp docker
```

Untuk server produksi, lebih aman tetap menjalankan deployment jaringan sebagai `root` agar akses `iptables`, `/dev/net/tun`, dan kernel module tidak bermasalah.

---

## 5. Konfigurasi Kernel / IP Forwarding Pertama Kali

IP forwarding wajib aktif pada host yang berperan sebagai router, terutama VM client yang meneruskan trafik dari WireGuard ke LAN `172.16.x.0/24`.

### 5.1 Aktifkan sekarang

```bash
sysctl -w net.ipv4.ip_forward=1
```

### 5.2 Tanam permanen agar survive reboot

Gunakan salah satu cara berikut.

Cara aman memakai file khusus:

```bash
cat >/etc/sysctl.d/99-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system
```

Atau cara langsung ke `/etc/sysctl.conf`:

```bash
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p
```

### 5.3 Verifikasi

```bash
cat /proc/sys/net/ipv4/ip_forward
```

Output harus:

```text
1
```

Jika output masih `0`, routing antar-interface tidak akan berjalan normal.

---

## 6. Setup Sisi Client Docker

Bagian ini untuk VM client/router, misalnya folder `wg-client/`.

### 6.1 Masuk ke folder client

```bash
cd wg-client
```

### 6.2 Siapkan `.env`

```bash
cp example.env .env
nano .env
```

Contoh variabel penting:

```env
WG_INTERFACE=wg-mikrotik
WG_MTU=1412
WG_KEEPALIVE=25

WG_CLIENT_IP=100.10.11.2
WG_CLIENT_PRIVATE_KEY=ISI_PRIVATE_KEY_CLIENT

WG_SERVER_PUBLIC_KEY=ISI_PUBLIC_KEY_SERVER
WG_SERVER_ENDPOINT=IP_ATAU_DOMAIN_SERVER
WG_SERVER_PORT=51820

WG_ALLOWED_IPS=100.10.11.0/24

LOCAL_NET_1=172.16.1.0/24
LOCAL_NET_2=172.16.2.0/24
LOCAL_NET_3=172.16.3.0/24
LOCAL_NET_4=172.16.4.0/24
LOCAL_NET_5=172.16.5.0/24

LAN_IFACE_1=ens19
LAN_IFACE_2=ens20
LAN_IFACE_3=ens21
LAN_IFACE_4=ens22
```

Penjelasan variabel client:

| Variabel                | Keterangan                                          | Contoh                     |
| ----------------------- | --------------------------------------------------- | -------------------------- |
| `WG_INTERFACE`          | Nama interface WireGuard di host client             | `wg-mikrotik`              |
| `WG_CLIENT_IP`          | IP tunnel client yang diberikan server              | `100.10.11.2`              |
| `WG_CLIENT_PRIVATE_KEY` | Private key milik client                            | hasil `wg genkey`          |
| `WG_SERVER_PUBLIC_KEY`  | Public key server WireGuard                         | dari server/MikroTik       |
| `WG_SERVER_ENDPOINT`    | IP publik/domain server                             | `38.47.94.143` atau domain |
| `WG_SERVER_PORT`        | Port UDP WireGuard server                           | `51820`                    |
| `WG_ALLOWED_IPS`        | Network yang dilewatkan via tunnel dari sisi client | `100.10.11.0/24`           |
| `LOCAL_NET_1..5`        | Network lokal di belakang VM client                 | `172.16.1.0/24`            |
| `LAN_IFACE_1..4`        | Interface LAN fisik/virtual host client             | `ens19`, `ens20`           |

> Penting: sesuaikan `LAN_IFACE_*` dengan output `ip a` di host client.

Cek interface host:

```bash
ip a
ip route
```

### 6.3 Generate key client

Jalankan di folder `wg-client`:

```bash
umask 077
wg genkey | tee client_privatekey | wg pubkey > client_publickey
```

Lihat hasilnya:

```bash
cat client_privatekey
cat client_publickey
```

Masukkan:

```text
WG_CLIENT_PRIVATE_KEY = isi dari client_privatekey
```

Lalu public key client wajib didaftarkan di server:

```text
client_publickey → Public Key peer di server WireGuard/MikroTik
```

Contoh format output:

```text
client_privatekey: <PRIVATE_KEY_CLIENT_JANGAN_DIBAGIKAN>
client_publickey : <PUBLIC_KEY_CLIENT_UNTUK_SERVER>
```

### 6.4 Set permission dan jalankan client

```bash
chmod +x entrypoint.sh
docker compose up -d
```

Lihat log:

```bash
docker compose logs -f
```

Jika ingin spesifik service:

```bash
docker compose logs -f wg-mikrotik
```

### 6.5 Verifikasi client

```bash
wg show wg-mikrotik
ip a show wg-mikrotik
ip route | grep -E "100\.10\.|172\.16\."
iptables -t nat -L POSTROUTING -n -v
```

Tes koneksi ke server tunnel:

```bash
ping 100.10.11.1
```

Cek handshake:

```bash
watch -n2 wg show wg-mikrotik
```

Tanda normal:

- Ada `latest handshake` yang berubah/terisi.
- Ada transfer `rx` dan `tx`.
- Interface `wg-mikrotik` memiliki IP `100.10.11.2/24`.
- `cat /proc/sys/net/ipv4/ip_forward` output `1`.

---

## 7. Konfigurasi Sisi Server WireGuard

Ada dua kemungkinan server:

1. Server WireGuard memakai **MikroTik**.
2. Server WireGuard memakai folder **`wg-server/` Docker Linux**.

Pilih sesuai kondisi deployment.

---

## 8. Server MikroTik: Tambah Peer dan Routing

Agar client tunnel lain bisa akses jaringan `172.16.x.0/24` di belakang VM client, server MikroTik harus mengetahui peer dan route-nya.

### 8.1 Tambahkan peer WireGuard di MikroTik

Data yang dibutuhkan:

```text
Public Key client : isi dari file client_publickey
Allowed Address   : 100.10.11.2/32
Persistent Keepalive: 25 detik, optional tapi disarankan jika client di belakang NAT
```

Allowed Address minimal untuk peer client router:

```text
100.10.11.2/32
```

Jika MikroTik mendukung memasukkan subnet LAN di allowed-address peer, dapat juga ditambahkan:

```text
100.10.11.2/32,172.16.1.0/24,172.16.2.0/24,172.16.3.0/24,172.16.4.0/24,172.16.5.0/24
```

### 8.2 Tambahkan static route di MikroTik

Tambahkan route berikut agar MikroTik mengirim trafik LAN ke client router `100.10.11.2`:

```text
172.16.1.0/24 → gateway 100.10.11.2
172.16.2.0/24 → gateway 100.10.11.2
172.16.3.0/24 → gateway 100.10.11.2
172.16.4.0/24 → gateway 100.10.11.2
172.16.5.0/24 → gateway 100.10.11.2
```

Contoh command MikroTik RouterOS:

```routeros
/ip route add dst-address=172.16.1.0/24 gateway=100.10.11.2 comment="via wg client tunnel-wg-client"
/ip route add dst-address=172.16.2.0/24 gateway=100.10.11.2 comment="via wg client tunnel-wg-client"
/ip route add dst-address=172.16.3.0/24 gateway=100.10.11.2 comment="via wg client tunnel-wg-client"
/ip route add dst-address=172.16.4.0/24 gateway=100.10.11.2 comment="via wg client tunnel-wg-client"
/ip route add dst-address=172.16.5.0/24 gateway=100.10.11.2 comment="via wg client tunnel-wg-client"
```

### 8.3 Pastikan firewall MikroTik mengizinkan forward

Pastikan chain `forward` tidak memblokir trafik dari interface WireGuard ke peer dan ke route LAN. Contoh umum:

```routeros
/ip firewall filter add chain=forward in-interface=<interface-wireguard> action=accept comment="Allow WG forward"
/ip firewall filter add chain=forward out-interface=<interface-wireguard> action=accept comment="Allow WG forward return"
```

Ganti `<interface-wireguard>` dengan nama interface WireGuard di MikroTik.

### 8.4 Verifikasi di MikroTik

```routeros
/interface wireguard peers print detail
/ip route print where dst-address~"172.16."
/ping 100.10.11.2
/ping 172.16.1.1
```

Jika ping ke `100.10.11.2` berhasil tetapi ke `172.16.x.x` gagal, fokus cek:

- `ip_forward` di VM client.
- NAT/iptables di VM client.
- Route balik dari perangkat LAN `172.16.x.x`.
- Firewall di host/perangkat LAN.

---

## 9. Server Docker Linux: Setup `wg-server/`

Bagian ini jika server WireGuard juga dijalankan melalui Docker pada Linux.

### 9.1 Masuk ke folder server

```bash
cd wg-server
```

### 9.2 Generate key server

Pastikan `generate-keys.sh` executable:

```bash
chmod +x generate-keys.sh
./generate-keys.sh
```

Output akan membuat:

```text
server_privatekey
server_publickey
```

Masukkan `server_privatekey` ke `.env` server:

```env
WG_SERVER_PRIVATE_KEY=ISI_SERVER_PRIVATE_KEY
```

Masukkan `server_publickey` ke `.env` client:

```env
WG_SERVER_PUBLIC_KEY=ISI_SERVER_PUBLIC_KEY
```

### 9.3 Edit `.env` server

```bash
cp example.env .env
nano .env
```

Contoh konfigurasi penting:

```env
WG_INTERFACE=wg-server
WG_SERVER_IP=100.10.11.1
WG_SERVER_CIDR=24
WG_SERVER_PORT=51820
WG_MTU=1420
WG_SERVER_PRIVATE_KEY=ISI_PRIVATE_KEY_SERVER

WG_ENABLE_IPV4_FORWARD=1
WAN_IFACE=
WG_OPEN_FIREWALL_PORT=1
WG_ENABLE_FORWARD_RULES=1
WG_ENABLE_NAT=0

PEER1_NAME=tunnel-wg-client
PEER1_PUBLIC_KEY=ISI_PUBLIC_KEY_CLIENT
PEER1_ALLOWED_IPS=100.10.11.2/32,172.16.1.0/24,172.16.2.0/24,172.16.3.0/24,172.16.4.0/24,172.16.5.0/24
PEER1_PERSISTENT_KEEPALIVE=25
```

Penjelasan variabel server:

| Variabel                  | Keterangan                                            |
| ------------------------- | ----------------------------------------------------- |
| `WG_INTERFACE`            | Nama interface WireGuard server                       |
| `WG_SERVER_IP`            | IP tunnel server                                      |
| `WG_SERVER_PORT`          | Port UDP listen WireGuard                             |
| `WG_SERVER_PRIVATE_KEY`   | Private key server                                    |
| `WG_ENABLE_IPV4_FORWARD`  | `1` agar entrypoint mengaktifkan forwarding sementara |
| `WG_OPEN_FIREWALL_PORT`   | `1` agar iptables membuka port UDP WireGuard          |
| `WG_ENABLE_FORWARD_RULES` | `1` agar forwarding dari/ke interface WG diizinkan    |
| `WG_ENABLE_NAT`           | Aktifkan hanya jika server juga perlu NAT             |
| `PEER1_PUBLIC_KEY`        | Public key client                                     |
| `PEER1_ALLOWED_IPS`       | IP tunnel client dan network LAN di belakang client   |

> Pada script `wg-server`, route untuk prefix di `PEER*_ALLOWED_IPS` akan dibuat otomatis ke interface WireGuard. Prefix default route `0.0.0.0/0` sengaja di-skip agar tidak merusak default route host.

### 9.4 Jalankan server Docker

```bash
chmod +x entrypoint.sh
docker compose up -d
```

Lihat log:

```bash
docker compose logs -f
```

### 9.5 Verifikasi server Docker

```bash
wg show wg-server
ip a show wg-server
ip route show dev wg-server
ss -lunp | grep 51820 || true
iptables -L INPUT -n -v | grep 51820 || true
iptables -L FORWARD -n -v | grep wg-server || true
```

Tes dari server:

```bash
ping 100.10.11.2
ping 172.16.1.1
```

---

## 10. Routing Agar Client Tunnel Lain Tahu Jalan

Masalah paling umum: tunnel aktif dan handshake berhasil, tetapi client tunnel lain tidak bisa akses `172.16.x.0/24`.

Agar routing normal, harus ada 3 komponen:

### 10.1 Server tahu rute ke LAN client

Di server tambahkan route:

```text
172.16.1.0/24 via 100.10.11.2
172.16.2.0/24 via 100.10.11.2
172.16.3.0/24 via 100.10.11.2
172.16.4.0/24 via 100.10.11.2
172.16.5.0/24 via 100.10.11.2
```

Pada server Docker Linux, ini dilakukan lewat:

```env
PEER1_ALLOWED_IPS=100.10.11.2/32,172.16.1.0/24,172.16.2.0/24,172.16.3.0/24,172.16.4.0/24,172.16.5.0/24
```

Pada MikroTik, tambahkan static route seperti bagian 8.2.

### 10.2 Client router meneruskan trafik ke LAN

Di VM client harus aktif:

```bash
cat /proc/sys/net/ipv4/ip_forward
```

Output wajib `1`.

Script client juga menambahkan rule NAT/MASQUERADE dari tunnel `100.10.11.0/24` ke interface LAN:

```text
100.10.11.0/24 -> LAN_IFACE_1
100.10.11.0/24 -> LAN_IFACE_2
100.10.11.0/24 -> LAN_IFACE_3
100.10.11.0/24 -> LAN_IFACE_4
```

Cek NAT:

```bash
iptables -t nat -L POSTROUTING -n -v
```

### 10.3 Peer lain tahu network tujuan

Jika peer lain adalah WireGuard client biasa, `AllowedIPs` peer tersebut harus memasukkan network yang ingin diakses.

Contoh pada client lain:

```ini
[Peer]
PublicKey = <PUBLIC_KEY_SERVER>
Endpoint = <IP_SERVER>:51820
AllowedIPs = 100.10.11.0/24, 172.16.1.0/24, 172.16.2.0/24, 172.16.3.0/24, 172.16.4.0/24, 172.16.5.0/24
PersistentKeepalive = 25
```

Jika `AllowedIPs` client lain hanya `100.10.11.0/24`, maka client itu hanya tahu rute ke subnet tunnel, bukan ke `172.16.x.0/24`.

---

## 11. Urutan Deployment yang Disarankan

### 11.1 Di client/router VM

```bash
cd wg-client

# Aktifkan IP forwarding
sysctl -w net.ipv4.ip_forward=1
cat >/etc/sysctl.d/99-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system
cat /proc/sys/net/ipv4/ip_forward

# Generate key client
umask 077
wg genkey | tee client_privatekey | wg pubkey > client_publickey
cat client_publickey

# Edit env
cp example.env .env
nano .env

# Jalankan
chmod +x entrypoint.sh
docker compose up -d
docker compose logs -f
```

### 11.2 Di server MikroTik

1. Tambahkan peer dengan public key dari `client_publickey`.
2. Set `allowed-address=100.10.11.2/32`.
3. Tambahkan static route `172.16.1.0/24` sampai `172.16.5.0/24` via `100.10.11.2`.
4. Pastikan firewall `forward` mengizinkan trafik WireGuard.

### 11.3 Di server Docker Linux

```bash
cd wg-server
chmod +x generate-keys.sh entrypoint.sh
./generate-keys.sh
cp example.env .env
nano .env
docker compose up -d
docker compose logs -f
```

---

## 12. Command Operasional Harian

### Start

```bash
docker compose up -d
```

### Stop

```bash
docker compose stop
```

### Restart

```bash
docker compose restart
```

### Lihat log

```bash
docker compose logs -f
```

### Lihat status WireGuard

Client:

```bash
wg show wg-mikrotik
```

Server Docker:

```bash
wg show wg-server
```

### Lihat route

```bash
ip route
ip route | grep -E "100\.10\.|172\.16\."
```

### Lihat iptables NAT

```bash
iptables -t nat -L POSTROUTING -n -v
```

### Lihat firewall forward

```bash
iptables -L FORWARD -n -v
```

---

## 13. Troubleshooting

### 13.1 Container gagal membuat interface WireGuard

Cek module dan TUN:

```bash
modprobe wireguard || true
ls -l /dev/net/tun
```

Jika `/dev/net/tun` tidak ada:

```bash
mkdir -p /dev/net
mknod /dev/net/tun c 10 200
chmod 600 /dev/net/tun
```

### 13.2 Handshake tidak muncul

Cek:

```bash
wg show
ping <IP_PUBLIC_SERVER>
nc -zvu <IP_PUBLIC_SERVER> 51820
```

Kemungkinan penyebab:

- Public key server/client salah.
- Endpoint server salah.
- Port UDP `51820` tertutup firewall/NAT.
- Waktu sistem terlalu jauh meleset.
- Peer belum ditambahkan di server.

### 13.3 Handshake ada, tetapi ping ke `172.16.x.x` gagal

Cek di VM client:

```bash
cat /proc/sys/net/ipv4/ip_forward
iptables -t nat -L POSTROUTING -n -v
ip route
```

Cek di server:

```bash
ip route | grep 172.16
```

Cek di MikroTik:

```routeros
/ip route print where dst-address~"172.16."
/interface wireguard peers print detail
```

Kemungkinan penyebab:

- Route `172.16.x.0/24 via 100.10.11.2` belum ada di server.
- `AllowedIPs` peer belum memasukkan subnet LAN.
- IP forwarding VM client belum aktif.
- NAT/MASQUERADE tidak cocok dengan interface LAN.
- Firewall LAN/perangkat tujuan menolak ICMP/traffic.

### 13.4 Interface LAN berbeda dari contoh

Contoh `.env` memakai `ens19`, `ens20`, `ens21`, `ens22`. Pada VM lain bisa berbeda, misalnya `eth1`, `ens18`, `enp0s8`.

Cek interface:

```bash
ip -br a
```

Lalu edit:

```env
LAN_IFACE_1=<interface-untuk-172.16.1.0/24>
LAN_IFACE_2=<interface-untuk-172.16.2.0/24>
LAN_IFACE_3=<interface-untuk-172.16.3.0/24>
LAN_IFACE_4=<interface-untuk-172.16.4.0/24>
```

### 13.5 Cek jalur paket dengan tcpdump

Install:

```bash
apt install -y tcpdump
```

Pantau tunnel:

```bash
tcpdump -ni wg-mikrotik
```

Pantau LAN:

```bash
tcpdump -ni ens19 host 172.16.1.1
```

Jika paket terlihat masuk di `wg-mikrotik` tetapi tidak keluar ke LAN, cek forwarding dan iptables. Jika paket keluar ke LAN tetapi tidak ada balasan, cek gateway/firewall perangkat LAN.

---

## 14. Checklist Tunnel Normal

Gunakan checklist ini setelah deployment.

### Di client/router VM

```bash
cat /proc/sys/net/ipv4/ip_forward       # harus 1
wg show wg-mikrotik                     # harus ada handshake
ip a show wg-mikrotik                   # harus ada 100.10.11.2/24
iptables -t nat -L POSTROUTING -n -v    # harus ada MASQUERADE ke LAN_IFACE
ping 100.10.11.1                        # harus reply dari server
```

### Di server

```bash
wg show                                 # peer client terlihat
ip route | grep 172.16                  # route LAN via tunnel tersedia
ping 100.10.11.2                        # client tunnel reply
```

### Dari client tunnel lain

```bash
ping 100.10.11.2
ping 172.16.1.1
traceroute 172.16.1.1
```

Tunnel dianggap normal jika:

- Semua peer handshake.
- Server bisa ping `100.10.11.2`.
- Client lain bisa ping `100.10.11.2`.
- Client lain bisa akses host di `172.16.x.0/24`.
- Counter `rx/tx` di `wg show` bertambah saat ada traffic.

---

## 15. Catatan Keamanan

1. Jangan membagikan `client_privatekey` atau `server_privatekey`.
2. File `.env` sebaiknya permission ketat:

   ```bash
   chmod 600 .env
   ```

3. Jika private key pernah terlanjur tersebar, generate ulang keypair dan update peer di server/client.
4. Batasi firewall hanya pada port UDP WireGuard yang diperlukan.
5. Hindari `AllowedIPs=0.0.0.0/0` kecuali memang ingin full tunnel.

---

## 16. Ringkasan Cepat

Client:

```bash
cd wg-client
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p
cat /proc/sys/net/ipv4/ip_forward

umask 077
wg genkey | tee client_privatekey | wg pubkey > client_publickey
cat client_publickey

cp example.env .env
nano .env
chmod +x entrypoint.sh
docker compose up -d
docker compose logs -f
```

Server MikroTik:

```text
Peer public key : isi dari client_publickey
Allowed Address : 100.10.11.2/32
Static route    : 172.16.1.0/24 sampai 172.16.5.0/24 via 100.10.11.2
Firewall        : allow forward dari/ke interface WireGuard
```

Server Docker Linux:

```bash
cd wg-server
chmod +x generate-keys.sh entrypoint.sh
./generate-keys.sh
cp example.env .env
nano .env
docker compose up -d
docker compose logs -f
```
