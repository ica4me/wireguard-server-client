# WireGuard Server — Docker Ephemeral Setup

Target host: **Ubuntu 22.04**

Mode:

- Docker Compose
- `network_mode: host`
- Tanpa `privileged: true`
- Ephemeral
- Tidak flush iptables
- Tidak mengubah default route host
- Cleanup otomatis saat container stop

---

## Struktur Folder

```text
wg-server/
├── docker-compose.yml
├── example.env
├── entrypoint.sh
├── generate-keys.sh
└── README.md
```
