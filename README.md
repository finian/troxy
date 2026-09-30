# Troxy

Troxy turns a Linux machine into a transparent proxy client. All outbound traffic, TCP and UDP, is routed through a SOCKS5 server, and no application needs its own proxy settings.

Under the hood, [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) creates a `tun0` device and forwards its traffic to the SOCKS5 server. Troxy handles the rest: it installs a systemd service, manages routes, and provides the `troxy` command to control it.

## Requirements

- Linux with systemd, on x86_64
- Root privileges
- `bash`, `wget`, `iproute2` (`ip`), and `getent` (glibc)
- A reachable SOCKS5 server, with UDP ASSOCIATE support if UDP traffic should be proxied

## Installation

Run the installer as root from a terminal. It prompts for the SOCKS5 server settings.

```bash
curl -fsSL https://example.com/troxy.sh | sudo bash -
```

Replace the URL with wherever you host `troxy.sh`. You can also run a local copy:

```bash
sudo bash troxy.sh
```

The installer asks for:

| Prompt   | Notes                                                    |
| -------- | -------------------------------------------------------- |
| Address  | IPv4, IPv6 (with or without brackets), or a domain name  |
| Port     | 1-65535                                                  |
| Username | Optional; leave empty for no authentication              |
| Password | Optional; hidden while typing                            |

The proxy starts right after installation and is enabled at boot.

## Usage

```
troxy <command> [arguments]
```

| Command             | Description                                                    |
| ------------------- | -------------------------------------------------------------- |
| `status`            | Show the service status                                        |
| `start`             | Start the proxy                                                |
| `stop`              | Stop the proxy and restore native routing                      |
| `restart`           | Restart the proxy                                              |
| `logs [-f]`         | View service logs; `-f` follows them in real time              |
| `socks [options]`   | Show or change the SOCKS5 server config                        |
| `uninstall [-y]`    | Remove troxy completely; `-y` skips the confirmation prompt    |
| `help`              | Show help                                                      |

Every command except `status`, `logs`, and `help` requires `sudo`.

### Configuring the SOCKS5 server

With no options, `troxy socks` prints the current config and masks the password:

```bash
sudo troxy socks
```

```
SOCKS5 config:
  Server : 1.2.3.4:1080
  UDP    : udp
  Auth   : alice / ********
```

Options change only the settings you pass and leave the rest alone. After saving, troxy restarts the service to apply the change.

| Option              | Description                                                     |
| ------------------- | --------------------------------------------------------------- |
| `<addr[:port]>`     | Host (IPv4, domain, or `[IPv6]`) and optional port              |
| `-H, --host <addr>` | Set the host                                                    |
| `-p, --port <num>`  | Set the port                                                    |
| `-u, --user <name>` | Set the username; if `-P` is omitted, the password is prompted  |
| `-P, --pass <pass>` | Set the password                                                |
| `--no-auth`         | Remove the username and password                                |

Examples:

```bash
sudo troxy socks 1.2.3.4:1080              # switch host and port
sudo troxy socks proxy.example.com         # switch host, keep port
sudo troxy socks [2001:db8::1]:1080        # IPv6 host
sudo troxy socks -p 7890                   # change port only
sudo troxy socks -u alice                  # enable auth, password prompted
sudo troxy socks --no-auth                 # disable auth
```

Prefer the password prompt over `-P`. A password passed on the command line ends up in your shell history and in the process list.

## How it works

Starting `troxy.service` runs these steps:

1. **Prepare** (`ExecStartPre`). Resolve the SOCKS5 host to an IP address, preferring IPv4. Then write a runtime config to `/run/troxy/` that uses this IP. Resolving once at startup keeps hev from sending DNS lookups for the proxy server through its own tunnel. A domain is resolved again on every start or restart.
2. **Tunnel** (`ExecStart`). Run `hev-socks5-tunnel` with the runtime config. It creates `tun0`.
3. **Route up** (`ExecStartPost`). Pin a host route to the SOCKS5 server through its current native gateway and interface, so proxy traffic doesn't loop back into the tunnel. Then add `default dev tun0 metric 1` to send everything else through the tunnel.
4. **Route down** (`ExecStopPost`). Remove exactly the routes added in step 3, as recorded in `/run/troxy/routes`. This works even if the config changed while the service was running.

## Files

| Path                                 | Purpose                                         |
| ------------------------------------ | ----------------------------------------------- |
| `/usr/local/bin/troxy`               | Control script                                  |
| `/usr/local/bin/hev-socks5-tunnel`   | Tunnel binary                                   |
| `/usr/local/etc/hev-socks5-tunnel.yml` | Config file (mode `600`, holds credentials)   |
| `/etc/systemd/system/troxy.service`  | systemd unit                                    |
| `/run/troxy/`                        | Runtime config, resolved server IP, route state |

## Uninstall

```bash
sudo troxy uninstall
```

This stops the proxy, restores native routing, and removes every file listed above.

## Troubleshooting

- **The service fails to start.** Check `troxy logs`. A common cause is a SOCKS5 domain that can't be resolved, which logs `Cannot resolve SOCKS5 host`.
- **No network after a crash.** Run `sudo troxy stop`. If the service is already gone, a reboot clears all troxy routes; none of them persist.
- **Only TCP works.** The SOCKS5 server may not support UDP ASSOCIATE.
