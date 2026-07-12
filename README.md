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

Before the first install, create the deployment configuration:

```bash
cp .env.example .env
chmod 600 .env
# Edit .env with this server's endpoint, interfaces, and VPN network.
```

All configuration-dependent scripts load settings from `.env`. The tracked
`.env.example` documents the required variables; `.env` is intentionally
ignored by git.

## Configuration

| Variable | Purpose |
| --- | --- |
| `WADVPN_PROJECT_NAME` / `WADVPN_PROJECT_VERSION` | Deployment metadata. |
| `WADVPN_PUBLIC_HOSTNAME` | Preferred WireGuard endpoint placed in client configs. |
| `WADVPN_PUBLIC_IP` | Endpoint fallback when no hostname is set. |
| `WADVPN_WAN_INTERFACE` | Public interface used for NAT and port forwards. |
| `WADVPN_WG_INTERFACE` | WireGuard interface and systemd instance name. |
| `WADVPN_WG_ADDRESS` | Server WireGuard address with CIDR prefix. |
| `WADVPN_WG_LISTEN_PORT` | WireGuard UDP listen port. |
| `WADVPN_VPN_NETWORK` | Client VPN network and firewall source network. |
| `WADVPN_DNS_SERVERS` | Comma-separated DNS servers emitted into client configs. |

`WADVPN_PUBLIC_HOSTNAME` or `WADVPN_PUBLIC_IP` must be set. The current client
address allocator supports an IPv4 `/24` VPN network.

## Main commands

```bash
sudo ./scripts/manage-clients.sh
sudo ./scripts/manage-clients.sh add <client-name> [--protected] [--isolated] [--route <network>] [--ip <address>]
sudo ./scripts/manage-clients.sh remove <client-name> [--force] [--yes]
sudo ./scripts/manage-clients.sh --help
sudo ./scripts/manage-port-forward.sh list
sudo ./scripts/manage-port-forward.sh add <client-name> --protocol <tcp|udp> --external-port <port> --target-port <port> [--target-address <ip>]
sudo ./scripts/manage-port-forward.sh remove
sudo ./scripts/manage-port-forward.sh --help
sudo ./scripts/verify.sh
```

## Project layout

```text
<project-root>
├── clients/              # Per-client working directory with keys
├── config/               # Main configuration and runtime state
│   ├── clients.json      # Source of truth for clients
│   ├── routes.json       # Static routes
│   ├── keys/             # Server key material (ignored by git)
│   └── port-forwards.json# Port-forward definitions
├── generated/            # Generated client configs and QR files (ignored by git)
├── logs/                 # Runtime logs (ignored by git)
├── scripts/              # Runtime commands and main installer
│   ├── install/          # Internal scripts used only during installation
│   ├── internal/         # Internal apply/generation steps
│   └── lib/              # Shared configuration loader
├── backup/               # Backup directory (ignored by git)
├── .env                  # Deployment configuration (ignored by git)
├── .env.example          # Documented configuration template
└── templates/            # Currently empty placeholder folder
```

## Files that are actively used

These are the main runtime and automation files in the current workflow:

Public commands:

- [scripts/manage-clients.sh](scripts/manage-clients.sh) — interactive and flag-driven client creation/removal
- [scripts/manage-port-forward.sh](scripts/manage-port-forward.sh) — adds/removes port forwards
- [scripts/install.sh](scripts/install.sh) — main installer entrypoint
- [scripts/verify.sh](scripts/verify.sh) — post-install verification

Internal implementation scripts:

- [scripts/install](scripts/install) — package and system setup helpers for the installer
- [scripts/internal](scripts/internal) — WireGuard config generation and application of firewall, routes, and port forwards
- [config/clients.json](config/clients.json) — client registry
- [.env.example](.env.example) — required server and VPN setting template
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
- deployment-specific `.env` settings

The test workflow intentionally avoids touching the protected clients PocoF5 and Mikrotik.

## License

MIT
