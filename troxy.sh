##################################################
# Troxy: transparent proxy installer
##################################################

# Installing into /usr/local and /etc/systemd requires root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This installer requires root privileges. Please run with sudo."
  exit 1
fi

# Wrap a value in YAML single quotes, escaping embedded quotes
yaml_quote() {
  local q="'"
  printf '%s' "'${1//$q/$q$q}'"
}

# Prompts read from /dev/tty, since stdin is the script itself under `curl ... | bash`
if ! { : < /dev/tty; } 2>/dev/null; then
  echo "Error: No terminal available for interactive input."
  exit 1
fi

# Prompt for the SOCKS5 server settings
while true; do
  read -rp "SOCKS5 server address (IPv4 / IPv6 / domain): " SOCKS5_ADDR < /dev/tty
  # Strip optional brackets around an IPv6 address
  SOCKS5_ADDR="${SOCKS5_ADDR#\[}"
  SOCKS5_ADDR="${SOCKS5_ADDR%\]}"
  if [[ -n "$SOCKS5_ADDR" && ! "$SOCKS5_ADDR" =~ [[:space:]] ]]; then
    break
  fi
  echo "Invalid address, please try again."
done

while true; do
  read -rp "SOCKS5 server port: " SOCKS5_PORT < /dev/tty
  if [[ "$SOCKS5_PORT" =~ ^[0-9]+$ ]] && [ "$SOCKS5_PORT" -ge 1 ] && [ "$SOCKS5_PORT" -le 65535 ]; then
    break
  fi
  echo "Invalid port, please enter a number between 1 and 65535."
done

read -rp "SOCKS5 username (leave empty to skip): " SOCKS5_USER < /dev/tty
read -rsp "SOCKS5 password (leave empty to skip): " SOCKS5_PASS < /dev/tty
echo ""

# Download and install hev-socks5-tunnel (latest x86_64 release)
if [ ! -f "/usr/local/bin/hev-socks5-tunnel" ]; then
  wget https://github.com/heiher/hev-socks5-tunnel/releases/latest/download/hev-socks5-tunnel-linux-x86_64 -O /usr/local/bin/hev-socks5-tunnel
  chmod +x /usr/local/bin/hev-socks5-tunnel
fi

# Generate the hev-socks5-tunnel config file
mkdir -p /usr/local/etc
cat << EOF > /usr/local/etc/hev-socks5-tunnel.yml
tunnel:
  name: tun0
  mtu: 1400
  ipv4: 198.18.0.1
socks5:
  port: ${SOCKS5_PORT}
  address: $(yaml_quote "$SOCKS5_ADDR")
  udp: 'udp'
EOF

if [[ -n "$SOCKS5_USER" && -n "$SOCKS5_PASS" ]]; then
  cat << EOF >> /usr/local/etc/hev-socks5-tunnel.yml
  username: $(yaml_quote "$SOCKS5_USER")
  password: $(yaml_quote "$SOCKS5_PASS")
EOF
fi

# The config holds credentials, so make it readable by root only
chmod 600 /usr/local/etc/hev-socks5-tunnel.yml

# Write the systemd service file
cat << 'EOF' > /etc/systemd/system/troxy.service
[Unit]
Description=Hev Socks5 Tunnel Transparent Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root

# Resolve the SOCKS5 host and render the runtime config
ExecStartPre=/usr/local/bin/troxy __prepare

# Start with the runtime config
ExecStart=/usr/local/bin/hev-socks5-tunnel /run/troxy/hev-socks5-tunnel.yml

# Once the tun device is ready, take over all outbound routing
ExecStartPost=/usr/local/bin/troxy __route-up

# On stop, remove the hijacked routes and restore native networking
ExecStopPost=/usr/local/bin/troxy __route-down

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Control script
cat << 'EOF' > /usr/local/bin/troxy
#!/usr/bin/env bash

# Configuration Variables
SERVICE_NAME="troxy.service"
CONFIG_FILE="/usr/local/etc/hev-socks5-tunnel.yml"
RUNTIME_DIR="/run/troxy"
RUNTIME_CONFIG="$RUNTIME_DIR/hev-socks5-tunnel.yml"
SERVER_IP_FILE="$RUNTIME_DIR/server_ip"
ROUTE_STATE="$RUNTIME_DIR/routes"
TUN_DEV="tun0"
SERVICE_FILE="/etc/systemd/system/troxy.service"
HEV_BIN="/usr/local/bin/hev-socks5-tunnel"
TROXY_BIN="/usr/local/bin/troxy"

# Function to check for root privileges
require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Error: This command requires root privileges. Please run with sudo (e.g., sudo troxy $1)."
    exit 1
  fi
}

# Display help menu
show_help() {
  echo "Usage: troxy <command> [arguments]"
  echo ""
  echo "Commands:"
  echo "  status              Show the current status of the transparent proxy"
  echo "  start               Start the proxy service"
  echo "  stop                Stop the proxy service and restore native routing"
  echo "  restart             Restart the proxy service"
  echo "  logs [-f]           View the service logs (append -f to follow logs in real-time)"
  echo "  socks [options]     Show or change the SOCKS5 server config"
  echo "  uninstall [-y]      Stop the proxy and remove troxy completely (-y skips confirmation)"
  echo ""
  echo "Socks options:"
  echo "  <addr[:port]>       Set the SOCKS5 host (IPv4, domain, or [IPv6]) and optionally port"
  echo "  -H, --host <addr>   Set the SOCKS5 host address"
  echo "  -p, --port <num>    Set the SOCKS5 port (1-65535)"
  echo "  -u, --user <name>   Set the auth username (prompts for password if -P is omitted)"
  echo "  -P, --pass <pass>   Set the auth password"
  echo "  --no-auth           Remove the auth credentials"
  echo ""
  echo "Examples:"
  echo "  sudo troxy socks                     Show current SOCKS5 config"
  echo "  sudo troxy socks 1.2.3.4:1080        Switch host and port"
  echo "  sudo troxy socks [2001:db8::1]:1080  Switch to an IPv6 host"
  echo "  sudo troxy socks -u alice            Enable auth (password prompted)"
  echo "  sudo troxy socks --no-auth           Disable auth"
}

# Read a key from the socks5 section of the config (unquotes YAML single-quoted values)
get_socks_value() {
  awk -v key="$1" -v q="'" '
    /^socks5:/ { in_socks = 1; next }
    /^[^[:space:]]/ { in_socks = 0 }
    in_socks && $0 ~ "^[[:space:]]+" key ":" {
      v = $0
      sub("^[[:space:]]+" key ":[[:space:]]*", "", v)
      if (length(v) >= 2 && substr(v, 1, 1) == q && substr(v, length(v), 1) == q) {
        v = substr(v, 2, length(v) - 2)
        gsub(q q, q, v)
      }
      print v
      exit
    }
  ' "$CONFIG_FILE"
}

# Wrap a value in YAML single quotes, escaping embedded quotes
yaml_quote() {
  local q="'"
  printf '%s' "'${1//$q/$q$q}'"
}

# Format host and port for display, bracketing IPv6 addresses
format_server() {
  if [[ "$1" == *:* ]]; then
    echo "[$1]:$2"
  else
    echo "$1:$2"
  fi
}

# Rewrite the socks5 section, keeping every other section intact
write_socks_config() {
  local addr=$1 port=$2 user=$3 pass=$4 udp=$5 tmp
  tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || exit 1

  awk '/^socks5:/ { skip = 1; next } /^[^[:space:]]/ { skip = 0 } !skip' "$CONFIG_FILE" > "$tmp"
  {
    echo "socks5:"
    echo "  port: $port"
    echo "  address: $(yaml_quote "$addr")"
    echo "  udp: $(yaml_quote "$udp")"
    if [[ -n "$user" ]]; then
      echo "  username: $(yaml_quote "$user")"
      echo "  password: $(yaml_quote "$pass")"
    fi
  } >> "$tmp"

  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

# Print the current SOCKS5 config (password masked)
show_socks_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found: $CONFIG_FILE"
    exit 1
  fi
  if [ ! -r "$CONFIG_FILE" ]; then
    echo "Error: Cannot read $CONFIG_FILE. Please run with sudo (e.g., sudo troxy socks)."
    exit 1
  fi

  local user
  user=$(get_socks_value username)
  echo "SOCKS5 config:"
  echo "  Server : $(format_server "$(get_socks_value address)" "$(get_socks_value port)")"
  echo "  UDP    : $(get_socks_value udp)"
  if [[ -n "$user" ]]; then
    echo "  Auth   : $user / ********"
  else
    echo "  Auth   : none"
  fi
}

# Function to restart and verify
restart_and_verify() {
  systemctl restart "$SERVICE_NAME"
  sleep 1.2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Success! Transparent proxy updated and running."
  else
    echo "Warning: $SERVICE_NAME failed to restart."
    echo "Check logs with: troxy logs"
  fi
}

# Function to handle SOCKS5 config changes
handle_socks() {
  if [[ $# -eq 0 ]]; then
    show_socks_config
    return
  fi

  require_root "socks $*"

  if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found!"
    exit 1
  fi

  local addr port user pass udp user_set=0 pass_set=0
  local bracket_re='^\[([^]]+)\](:(.*))?$'
  addr=$(get_socks_value address)
  port=$(get_socks_value port)
  user=$(get_socks_value username)
  pass=$(get_socks_value password)
  udp=$(get_socks_value udp)
  udp=${udp:-udp}

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -H|--host|-p|--port|-u|--user|-P|--pass)
      if [[ $# -lt 2 ]]; then
        echo "Error: Option '$1' requires a value."
        exit 1
      fi
      case "$1" in
      -H|--host) addr="${2#\[}"; addr="${addr%\]}" ;;
      -p|--port) port=$2 ;;
      -u|--user) user=$2; user_set=1 ;;
      -P|--pass) pass=$2; pass_set=1 ;;
      esac
      shift 2
      ;;
    --no-auth)
      user=""
      pass=""
      shift
      ;;
    -*)
      echo "Error: Unknown option '$1'"
      echo "Run 'troxy help' for usage."
      exit 1
      ;;
    *)
      # Positional <addr[:port]>: [IPv6]:port, bare IPv6, host:port, or host
      if [[ "$1" =~ $bracket_re ]]; then
        addr=${BASH_REMATCH[1]}
        [[ -n "${BASH_REMATCH[2]}" ]] && port=${BASH_REMATCH[3]}
      elif [[ "$1" == *:*:* ]]; then
        addr=$1
      elif [[ "$1" == *:* ]]; then
        addr=${1%:*}
        port=${1##*:}
      else
        addr=$1
      fi
      shift
      ;;
    esac
  done

  # Prompt for the password when a user is given without one
  if [[ $user_set -eq 1 && $pass_set -eq 0 ]]; then
    read -rsp "Password for '$user': " pass
    echo ""
  fi

  if [[ -z "$addr" || "$addr" =~ [[:space:]] ]]; then
    echo "Error: '$addr' is not a valid address."
    exit 1
  fi

  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Error: '$port' is not a valid port number (1-65535)."
    exit 1
  fi

  if [[ -n "$user" && -z "$pass" ]] || [[ -z "$user" && -n "$pass" ]]; then
    echo "Error: Username and password must be set together (use --no-auth to remove both)."
    exit 1
  fi

  if [ "${#user}" -gt 255 ] || [ "${#pass}" -gt 255 ]; then
    echo "Error: Username and password must be at most 255 characters."
    exit 1
  fi

  write_socks_config "$addr" "$port" "$user" "$pass" "$udp"
  echo "Switching to $(format_server "$addr" "$port") (auth: ${user:-none})..."
  restart_and_verify
}

# [service] Resolve the SOCKS5 host and render the runtime config for hev.
# hev would otherwise resolve domains per connection, and those DNS queries loop into the tunnel.
prepare_runtime() {
  local host server_ip
  host=$(get_socks_value address)
  if [[ -z "$host" ]]; then
    echo "Error: SOCKS5 address missing in $CONFIG_FILE" >&2
    exit 1
  fi

  # Prefer IPv4, fall back to IPv6 (literal IPs resolve to themselves)
  server_ip=$(getent ahostsv4 "$host" | awk 'NR == 1 { print $1 }')
  [[ -z "$server_ip" ]] && server_ip=$(getent ahosts "$host" | awk 'NR == 1 { print $1 }')
  if [[ -z "$server_ip" ]]; then
    echo "Error: Cannot resolve SOCKS5 host '$host'" >&2
    exit 1
  fi

  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR"
  (
    umask 077
    awk -v addr="$(yaml_quote "$server_ip")" '
      /^socks5:/ { in_socks = 1; print; next }
      /^[^[:space:]]/ { in_socks = 0 }
      in_socks && /^[[:space:]]+address:/ { print "  address: " addr; next }
      { print }
    ' "$CONFIG_FILE" > "$RUNTIME_CONFIG"
  )
  echo "$server_ip" > "$SERVER_IP_FILE"
  [[ "$server_ip" != "$host" ]] && echo "Resolved SOCKS5 host $host -> $server_ip"
  return 0
}

# [service] Pin the SOCKS5 server to its native route, then send everything else into the tunnel
route_up() {
  local server_ip fam route gw dev i
  server_ip=$(cat "$SERVER_IP_FILE" 2>/dev/null)
  if [[ -z "$server_ip" ]]; then
    echo "Error: SOCKS5 server IP unknown ($SERVER_IP_FILE missing)" >&2
    exit 1
  fi
  fam="-4"
  [[ "$server_ip" == *:* ]] && fam="-6"

  # Wait for hev to create the tun device
  for ((i = 0; i < 50; i++)); do
    ip link show "$TUN_DEV" &>/dev/null && break
    sleep 0.2
  done
  if ! ip link show "$TUN_DEV" &>/dev/null; then
    echo "Error: $TUN_DEV did not come up" >&2
    exit 1
  fi

  route=$(ip "$fam" route get "$server_ip" 2>/dev/null | head -n 1)
  gw=$(awk '{ for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1) }' <<< "$route")
  dev=$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' <<< "$route")
  if [[ -z "$dev" || "$dev" == "$TUN_DEV" ]]; then
    echo "Error: No native route to SOCKS5 server $server_ip" >&2
    exit 1
  fi

  : > "$ROUTE_STATE"
  # A server on this host (dev lo) needs no pinned route
  if [[ "$dev" != "lo" ]]; then
    ip "$fam" route replace "$server_ip" ${gw:+via "$gw"} dev "$dev" || exit 1
    echo "$fam $server_ip" >> "$ROUTE_STATE"
  fi

  ip link set dev "$TUN_DEV" up
  ip route replace default dev "$TUN_DEV" metric 1
}

# [service] Remove exactly the routes added by route_up, even if the config has changed since
route_down() {
  local fam addr
  if [[ -f "$ROUTE_STATE" ]]; then
    while read -r fam addr; do
      [[ -n "$addr" ]] && ip "$fam" route del "$addr" 2>/dev/null
    done < "$ROUTE_STATE"
  fi
  ip route del default dev "$TUN_DEV" metric 1 2>/dev/null
  rm -f "$ROUTE_STATE" "$SERVER_IP_FILE" "$RUNTIME_CONFIG"
  return 0
}

# Remove the service, config, hev-socks5-tunnel and troxy itself
handle_uninstall() {
  require_root "uninstall"

  if [[ "$1" != "-y" && "$1" != "--yes" ]]; then
    local answer
    echo "This will stop the proxy and remove:"
    echo "  $SERVICE_FILE"
    echo "  $CONFIG_FILE"
    echo "  $RUNTIME_DIR"
    echo "  $HEV_BIN"
    echo "  $TROXY_BIN"
    read -rp "Continue? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  systemctl disable --now "$SERVICE_NAME" 2>/dev/null
  # Clean up in case the service was already dead with routes left behind
  route_down

  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" 2>/dev/null
  rm -rf "$RUNTIME_DIR"
  rm -f "$CONFIG_FILE" "$HEV_BIN" "$TROXY_BIN"

  echo "Troxy uninstalled. Native network restored."
  exit 0
}

# Main Command Router
case "$1" in
status)
  systemctl status "$SERVICE_NAME"
  ;;
start)
  require_root "start"
  systemctl start "$SERVICE_NAME"
  echo "Started $SERVICE_NAME."
  ;;
stop)
  require_root "stop"
  systemctl stop "$SERVICE_NAME"
  echo "Stopped $SERVICE_NAME. Native network restored."
  ;;
restart)
  require_root "restart"
  systemctl restart "$SERVICE_NAME"
  echo "Restarted $SERVICE_NAME."
  ;;
logs)
  shift # Remove 'logs' from arguments so '-f' or other flags can be passed natively
  journalctl -u "$SERVICE_NAME" "$@"
  ;;
socks)
  shift
  handle_socks "$@"
  ;;
uninstall)
  shift
  handle_uninstall "$@"
  ;;
__prepare)
  require_root "$1"
  prepare_runtime
  ;;
__route-up)
  require_root "$1"
  route_up
  ;;
__route-down)
  require_root "$1"
  route_down
  ;;
help|--help|-h|"")
  show_help
  ;;
*)
  echo "Error: Unknown command '$1'"
  echo ""
  show_help
  exit 1
  ;;
esac
EOF

# Ensure the script is executable
chmod +x /usr/local/bin/troxy

# Reload systemd and enable the proxy at boot (the service calls troxy, so this must come after installing it)
systemctl daemon-reload
systemctl enable --now troxy.service

# Installation summary
echo ""
echo "=========================================="
echo " Troxy transparent proxy installed"
echo "=========================================="
echo " SOCKS5 address : ${SOCKS5_ADDR}"
echo " SOCKS5 port    : ${SOCKS5_PORT}"
if [[ -n "$SOCKS5_USER" && -n "$SOCKS5_PASS" ]]; then
  echo " SOCKS5 auth    : configured"
else
  echo " SOCKS5 auth    : none"
fi
echo "------------------------------------------"
echo " Usage: troxy help"
echo "=========================================="
