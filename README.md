# WadVPN

WadVPN is a self-hosted WireGuard VPN management project for automating server-side WireGuard client provisioning, route/firewall setup, QR config export, and per-client port forwarding.

## What this project does

- Creates WireGuard clients automatically
- Generates client config files and QR images
- Applies routes and firewall rules
- Supports protected/isolated clients
- Manages per-client TCP/UDP port forwards
- Verifies the resulting setup

## Requirements

- Ubuntu 22.04+
- WireGuard
- jq
- qrencode
- iptables

## Quick start

```bash
sudo ./scripts/install.sh
```

## Main commands

```bash
sudo ./scripts/create-client.sh <client-name> [--protected] [--isolated] [--route <network>] [--ip <address>]
sudo ./scripts/remove-client.sh <client-name> [--force]
sudo ./scripts/manage-port-forward.sh list
sudo ./scripts/manage-port-forward.sh add <client-name>
sudo ./scripts/manage-port-forward.sh remove
sudo ./scripts/verify.sh
```

## Project layout

```text
/opt/wad-vpn
├── clients/              # Per-client working directory with keys
├── config/               # Main configuration and runtime state
│   ├── clients.json      # Source of truth for clients
│   ├── settings.json     # Server and VPN settings
│   ├── routes.json       # Static routes
│   ├── keys/             # Server key material (ignored by git)
│   └── port-forwards.json# Port-forward definitions
├── generated/            # Generated client configs and QR files (ignored by git)
├── logs/                 # Runtime logs (ignored by git)
├── scripts/              # Automation scripts
├── backup/               # Backup directory (ignored by git)
└── templates/            # Currently empty placeholder folder
```

## Files that are actively used

These are the main runtime and automation files in the current workflow:

- [scripts/create-client.sh](scripts/create-client.sh) — creates clients end to end
- [scripts/remove-client.sh](scripts/remove-client.sh) — removes clients and related artifacts
- [scripts/manage-port-forward.sh](scripts/manage-port-forward.sh) — adds/removes port forwards
- [scripts/apply-port-forwards.sh](scripts/apply-port-forwards.sh) — applies iptables rules for forwards
- [scripts/apply-wireguard.sh](scripts/apply-wireguard.sh) — regenerates and reloads WireGuard
- [scripts/generate-server-config.sh](scripts/generate-server-config.sh) — writes the server WireGuard config
- [scripts/apply-routes.sh](scripts/apply-routes.sh) — applies static and client routes
- [scripts/apply-firewall.sh](scripts/apply-firewall.sh) — applies VPN firewall rules
- [scripts/install.sh](scripts/install.sh) — main installer entrypoint
- [scripts/verify.sh](scripts/verify.sh) — post-install verification
- [config/clients.json](config/clients.json) — client registry
- [config/settings.json](config/settings.json) — server settings
- [config/routes.json](config/routes.json) — static routes
- [config/port-forwards.json](config/port-forwards.json) — current port-forward state

## Files that are effectively placeholders or not used in the current flow

- [templates](templates) — currently empty, no active templates are referenced by the scripts
- [backup](backup) — present for manual backup use; not used by the automation scripts
- [config/firewall.json](config/firewall.json) — present but not consumed by the current active scripts

## Security and git hygiene

The repository now ignores the sensitive runtime files that should not be committed:

- client private keys
- server private keys
- generated WireGuard config with private material
- generated client configs and QR images
- logs and temporary files

The test workflow intentionally avoids touching the protected clients PocoF5 and Mikrotik.

## License

MIT
