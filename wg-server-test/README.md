# ini hanya versi test

```
# Aktifkan sekarang
sudo sysctl -w net.ipv4.ip_forward=1

# Tanam permanen agar bertahan saat reboot
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

Cara Menjalankan test

```
chmod +x entrypoint.sh
```

```
docker compose up -d
```

⚠️ Yang Perlu Dikonfigurasi di Server-test
Agar client tunnel lain bisa akses 172.16.x.0/24, di server WireGuard tambahkan:

Peer dengan public key client ini, allowed-address 100.10.11.2/32
Route static: 172.16.1.0/24 - 172.16.5.0/24 → via 100.10.11.2
