# WadVPN

WadVPN is a self-hosted WireGuard VPN management project for automating server-side WireGuard client provisioning, route/firewall setup, QR config export, and per-client port forwarding.

## What this project does

- Creates WireGuard clients automatically
- Generates client config files and QR images
- Applies routes and firewall rules
- Supports protected clients and client groups (clients see each other only inside a shared group)
- Enables and disables clients without deleting them
- Adds and removes clients without disconnecting the others
- Rotates the server key pair and rebuilds all client configs
- Restores the firewall at boot before WireGuard starts
- Manages per-client TCP/UDP port forwards
- Verifies the resulting setup

## Requirements

- Ubuntu 22.04+
- WireGuard
- jq
- qrencode
- iptables
- ipset

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
sudo ./scripts/manage-clients.sh add <client-name> [--protected] [--group <group>]... [--route <network>] [--ip <address>]
sudo ./scripts/manage-clients.sh remove <client-name> [--force] [--yes]
sudo ./scripts/manage-clients.sh list
sudo ./scripts/manage-clients.sh enable|disable <client-name>
sudo ./scripts/manage-clients.sh show-config <client-name>
sudo ./scripts/manage-clients.sh rotate-server-key [--yes]
sudo ./scripts/manage-clients.sh group list
sudo ./scripts/manage-clients.sh group create|rename|delete ...
sudo ./scripts/manage-clients.sh group add-client|remove-client|move-client ...
sudo ./scripts/manage-clients.sh --help
sudo ./scripts/manage-port-forward.sh list
sudo ./scripts/manage-port-forward.sh add <client-name> --protocol <tcp|udp> --external-port <port> --target-port <port> [--target-address <ip>]
sudo ./scripts/manage-port-forward.sh remove
sudo ./scripts/manage-port-forward.sh --help
sudo ./scripts/verify.sh
```

## Client groups

VPN clients can reach each other only when they share at least one group. A
client can belong to several groups and then reaches the members of each of
them, while those groups stay separated from one another. A client without
groups is isolated from all other VPN clients. Internet access, the server
itself, and port forwards are not affected by groups.

Groups are stored in `config/clients.json` (top-level `groups` list and a
per-client `groups` list). `scripts/internal/apply-firewall.sh` turns every
group into an ipset `wadvpn-g-<group>` containing the members' VPN addresses
and routed networks, and the `WADVPN-C2C` iptables chain accepts traffic only
when source and destination are in the same set. Membership changes only
reload the firewall; WireGuard is not restarted.

## How changes are applied

- Adding, removing, enabling, or disabling a client updates the running
  interface with `wg syncconf`, so other clients stay connected.
- `wadvpn-firewall.service` (installed by `install.sh`) rebuilds the firewall,
  groups, and port forwards at boot, before `wg-quick@<interface>`. WireGuard
  does not start when the firewall fails, so clients are never connected
  without the group filter. Static routes from `config/routes.json` are
  applied by `PostUp` in the generated server config.
- Client configs send both `0.0.0.0/0` and `::/0` into the tunnel. The server
  accepts only IPv4 from peers, so IPv6 traffic is dropped instead of leaking
  outside the VPN.
- Port forwards store the client name only. The target defaults to the
  client's current VPN address, looked up whenever rules are applied, and
  forwards of disabled clients are skipped.

## Rotating the server key

`manage-clients.sh rotate-server-key` backs up the current keys, server config,
and generated client files to `backup/server-key-rotation-<timestamp>/`,
generates a new key pair, applies it, and rebuilds every client config and QR.
Clients keep their own keys; each one only needs the new server public key in
the `PublicKey` line of its `[Peer]` section. Clients disconnect until they are
updated.

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
│   └── lib/              # Shared configuration, registry, and IPv4 helpers
├── backup/               # Automatic backups before key rotation (ignored by git)
├── .env                  # Deployment configuration (ignored by git)
└── .env.example          # Documented configuration template
```

## Files that are actively used

These are the main runtime and automation files in the current workflow:

Public commands:

- [scripts/manage-clients.sh](scripts/manage-clients.sh) — clients, groups, configs and QR codes, server key rotation
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
