# WadVPN

WadVPN is a self-hosted WireGuard VPN management project.

## Features

- Native WireGuard
- Full Tunnel VPN
- Site-to-Site support (MikroTik)
- Home network routing
- Automatic firewall configuration
- Automatic route management
- Client configuration generation
- QR code generation
- Git-friendly project structure

## Project Structure

```
/opt/wad-vpn
├── backup
├── clients
├── config
├── generated
├── logs
├── scripts
└── templates
```

## Requirements

- Ubuntu 22.04+
- WireGuard
- jq
- qrencode

## Installation

```
sudo ./scripts/install.sh
```

## License

MIT
