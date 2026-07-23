#!/usr/bin/env bash
set -euo pipefail

ALLOY_CONFIG="/etc/alloy/config.alloy"
ALLOY_TOKEN_FILE="/etc/alloy/grafana-cloud-token"
ALLOY_TEXTFILE_DIR="/var/lib/alloy/textfile"
COLLECTOR_PATH="/usr/local/bin/mtproxy-stats-collector"
COLLECTOR_CONFIG="/etc/default/mtproxy-monitoring"
COLLECTOR_SERVICE="/etc/systemd/system/mtproxy-stats-collector.service"
COLLECTOR_TIMER="/etc/systemd/system/mtproxy-stats-collector.timer"
ALLOY_OVERRIDE_DIR="/etc/systemd/system/alloy.service.d"
ALLOY_OVERRIDE="${ALLOY_OVERRIDE_DIR}/mtproxy-monitoring.conf"

METRICS_URL="${GRAFANA_METRICS_URL:-}"
METRICS_USER="${GRAFANA_METRICS_USER:-}"
LOGS_URL="${GRAFANA_LOGS_URL:-}"
LOGS_USER="${GRAFANA_LOGS_USER:-}"
TOKEN_FILE="${GRAFANA_TOKEN_FILE:-}"
DEPLOYMENT_STATE=""
NAME_PREFIX="mtproxy"
PREFIX_EXPLICIT="no"
EXPECTED_COUNT=""
FORCE="no"
ALLOY_INSTALLED_NOW="no"

log() {
  echo "[*] $*"
}

err() {
  echo "[!] $*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./monitoring-setup.bash \
    --metrics-url URL \
    --metrics-user USERNAME \
    --logs-url URL \
    --logs-user USERNAME \
    --token-file PATH \
    [options]

Required:
  --metrics-url URL       Grafana Cloud Prometheus remote_write URL.
  --metrics-user USER     Grafana Cloud metrics username/instance ID.
  --logs-url URL          Grafana Cloud Loki push URL.
  --logs-user USER        Grafana Cloud logs username/instance ID.
  --token-file PATH       File containing one access-policy token with
                          metrics:write and logs:write permissions.

Options:
  --deployment-state PATH Read NAME_PREFIX and PORT_RANGE from deployment.env.
                          Defaults to ~/mtproxy/deployment.env for the invoking
                          user when that file exists.
  --prefix NAME           MTProxy container prefix. Overrides deployment state.
  --expected-count N      Expected proxy-container count. Overrides state.
  --force                 Replace an existing unmanaged Alloy configuration.
                          A timestamped backup is created first.
  -h, --help              Show this help.

The Grafana Cloud URLs and usernames are shown under:
  Connections -> Linux Server -> Configure -> Send metrics/logs

Environment alternatives:
  GRAFANA_METRICS_URL, GRAFANA_METRICS_USER, GRAFANA_LOGS_URL,
  GRAFANA_LOGS_USER, GRAFANA_TOKEN_FILE
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --metrics-url)
        METRICS_URL="${2:-}"
        shift 2
        ;;
      --metrics-user)
        METRICS_USER="${2:-}"
        shift 2
        ;;
      --logs-url)
        LOGS_URL="${2:-}"
        shift 2
        ;;
      --logs-user)
        LOGS_USER="${2:-}"
        shift 2
        ;;
      --token-file)
        TOKEN_FILE="${2:-}"
        shift 2
        ;;
      --deployment-state)
        DEPLOYMENT_STATE="${2:-}"
        shift 2
        ;;
      --prefix)
        NAME_PREFIX="${2:-}"
        PREFIX_EXPLICIT="yes"
        shift 2
        ;;
      --expected-count)
        EXPECTED_COUNT="${2:-}"
        shift 2
        ;;
      --force)
        FORCE="yes"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

default_deployment_state() {
  local invoking_user="${SUDO_USER:-$(id -un)}"
  local invoking_home

  invoking_home="$(getent passwd "$invoking_user" | cut -d: -f6)"
  if [[ -n "$invoking_home" && -f "${invoking_home}/mtproxy/deployment.env" ]]; then
    DEPLOYMENT_STATE="${invoking_home}/mtproxy/deployment.env"
  fi
}

state_value() {
  local key="$1"
  local state_file="$2"

  awk -F= -v wanted="$key" '
    $1 == wanted {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$state_file"
}

load_deployment_state() {
  local port_range
  local port_start
  local port_end
  local state_prefix

  if [[ -z "$DEPLOYMENT_STATE" ]]; then
    default_deployment_state
  fi

  if [[ -z "$DEPLOYMENT_STATE" ]]; then
    return 0
  fi

  if [[ ! -r "$DEPLOYMENT_STATE" ]]; then
    err "Deployment state is not readable: ${DEPLOYMENT_STATE}"
    return 1
  fi

  if [[ "$PREFIX_EXPLICIT" != "yes" ]]; then
    state_prefix="$(state_value NAME_PREFIX "$DEPLOYMENT_STATE")"
    if [[ -n "$state_prefix" ]]; then
      NAME_PREFIX="$state_prefix"
    fi
  fi

  if [[ -z "$EXPECTED_COUNT" ]]; then
    port_range="$(state_value PORT_RANGE "$DEPLOYMENT_STATE")"
    if [[ "$port_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      port_start="${BASH_REMATCH[1]}"
      port_end="${BASH_REMATCH[2]}"
      if (( port_start <= port_end )); then
        EXPECTED_COUNT=$((port_end - port_start + 1))
      fi
    fi
  fi
}

validate_url() {
  local value="$1"
  [[ "$value" =~ ^https://[A-Za-z0-9./:_?=%+-]+$ ]]
}

validate_inputs() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this setup script as root, for example with sudo"
    return 1
  fi

  if ! validate_url "$METRICS_URL"; then
    err "--metrics-url must be a valid HTTPS URL"
    return 1
  fi

  if ! validate_url "$LOGS_URL"; then
    err "--logs-url must be a valid HTTPS URL"
    return 1
  fi

  if [[ ! "$METRICS_USER" =~ ^[A-Za-z0-9_-]+$ ]]; then
    err "--metrics-user contains unsupported characters"
    return 1
  fi

  if [[ ! "$LOGS_USER" =~ ^[A-Za-z0-9_-]+$ ]]; then
    err "--logs-user contains unsupported characters"
    return 1
  fi

  if [[ ! "$NAME_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    err "Container prefix must contain only letters, digits, underscores, and hyphens"
    return 1
  fi

  if [[ -z "$EXPECTED_COUNT" ]]; then
    EXPECTED_COUNT=0
  fi

  if [[ ! "$EXPECTED_COUNT" =~ ^[0-9]+$ ]]; then
    err "--expected-count must be a non-negative integer"
    return 1
  fi

  if [[ -z "$TOKEN_FILE" || ! -r "$TOKEN_FILE" ]]; then
    err "--token-file must point to a readable token file"
    return 1
  fi

  if [[ -z "$(tr -d '\r\n' < "$TOKEN_FILE")" ]]; then
    err "Grafana Cloud token file is empty"
    return 1
  fi
}

install_alloy() {
  if command -v alloy >/dev/null 2>&1; then
    log "Grafana Alloy is already installed"
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    err "Automatic Alloy installation currently supports Debian and Ubuntu"
    err "Install Alloy manually, then rerun this script"
    return 1
  fi

  log "Installing Grafana Alloy from the official Grafana apt repository"
  apt-get update
  apt-get install -y ca-certificates curl gpg
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
  chmod 0644 /etc/apt/keyrings/grafana.gpg

  printf '%s\n' \
    "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list

  apt-get update
  apt-get install -y alloy
  ALLOY_INSTALLED_NOW="yes"
}

install_token() {
  local token

  token="$(tr -d '\r\n' < "$TOKEN_FILE")"
  install -d -m 0750 -o root -g root /etc/alloy
  umask 077
  printf '%s' "$token" > "$ALLOY_TOKEN_FILE"
  chmod 0600 "$ALLOY_TOKEN_FILE"
  unset token
}

write_alloy_config() {
  local target="$1"

  cat > "$target" <<EOF
// Managed by monitoring-setup.bash.
// Grafana Cloud credentials are read from ${ALLOY_TOKEN_FILE}.

logging {
  level  = "info"
  format = "logfmt"
}

local.file "grafana_cloud_token" {
  filename  = "${ALLOY_TOKEN_FILE}"
  is_secret = true
}

prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = "${METRICS_URL}"

    basic_auth {
      username = "${METRICS_USER}"
      password = local.file.grafana_cloud_token.content
    }
  }
}

loki.write "grafana_cloud" {
  endpoint {
    url = "${LOGS_URL}"

    basic_auth {
      username = "${LOGS_USER}"
      password = local.file.grafana_cloud_token.content
    }
  }
}

prometheus.exporter.unix "host" {
  enable_collectors = ["systemd", "textfile"]

  filesystem {
    fs_types_exclude     = "^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
    mount_points_exclude = "^/(dev|proc|run/credentials/.+|sys|var/lib/docker/.+)(\$|/)"
    mount_timeout        = "5s"
  }

  netclass {
    ignored_devices = "^(veth.*|docker.*|br-.*)$"
  }

  netdev {
    device_exclude = "^(veth.*|docker.*|br-.*)$"
  }

  systemd {
    enable_restarts = true
    unit_include    = "(alloy|docker|mtproxy-stats-collector)\\.service"
  }

  textfile {
    directory = "${ALLOY_TEXTFILE_DIR}"
  }
}

discovery.relabel "host" {
  targets = prometheus.exporter.unix.host.targets

  rule {
    target_label = "job"
    replacement  = "integrations/linux-node"
  }

  rule {
    target_label = "instance"
    replacement  = constants.hostname
  }
}

prometheus.scrape "host" {
  targets         = discovery.relabel.host.output
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.grafana_cloud.receiver]
}

prometheus.exporter.cadvisor "docker" {
  docker_only = true
}

discovery.relabel "docker_metrics" {
  targets = prometheus.exporter.cadvisor.docker.targets

  rule {
    target_label = "job"
    replacement  = "integrations/docker"
  }

  rule {
    target_label = "instance"
    replacement  = constants.hostname
  }
}

prometheus.scrape "docker" {
  targets         = discovery.relabel.docker_metrics.output
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.grafana_cloud.receiver]
}

discovery.docker "docker_logs" {
  host             = "unix:///var/run/docker.sock"
  refresh_interval = "5s"
}

discovery.relabel "docker_logs" {
  targets = []

  rule {
    target_label = "job"
    replacement  = "integrations/docker"
  }

  rule {
    target_label = "instance"
    replacement  = constants.hostname
  }

  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }

  rule {
    source_labels = ["__meta_docker_container_log_stream"]
    target_label  = "stream"
  }
}

loki.source.docker "docker_logs" {
  host             = "unix:///var/run/docker.sock"
  targets          = discovery.docker.docker_logs.targets
  relabel_rules    = discovery.relabel.docker_logs.rules
  refresh_interval = "5s"
  forward_to       = [loki.write.grafana_cloud.receiver]
}
EOF
}

write_stats_collector() {
  local target="$1"

  cat > "$target" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${MTPROXY_MONITORING_CONFIG:-/etc/default/mtproxy-monitoring}"

if [[ -r "$CONFIG_FILE" ]]; then
  # This file is generated by monitoring-setup.bash and contains no secrets.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

NAME_PREFIX="${NAME_PREFIX:-mtproxy}"
EXPECTED_COUNT="${EXPECTED_COUNT:-0}"
METRICS_DIR="${METRICS_DIR:-/var/lib/alloy/textfile}"
OUTPUT_FILE="${METRICS_DIR}/mtproxy.prom"

mkdir -p "$METRICS_DIR"
temp_file="$(mktemp "${METRICS_DIR}/.mtproxy.prom.XXXXXX")"
trap 'rm -f "$temp_file"' EXIT

metric_value() {
  local key="$1"
  local input="$2"

  awk -F '\t' -v wanted="$key" '
    $1 == wanted && $2 ~ /^-?[0-9]+([.][0-9]+)?$/ {
      print $2
      exit
    }
  ' <<< "$input"
}

write_selected_metrics() {
  local container="$1"
  local stats="$2"
  local source_name
  local value
  local -a metric_names=(
    workers
    qps_get
    total_ready_targets
    total_allocated_targets
    total_declared_targets
    total_inactive_targets
    total_connections
    total_encrypted_connections
    total_special_connections
    total_max_special_connections
    ext_connections
    ext_connections_created
    total_network_buffers_used_size
    total_network_buffers_allocated_bytes
    mtproto_proxy_errors
    connections_failed_lru
    connections_failed_flood
  )

  for source_name in "${metric_names[@]}"; do
    value="$(metric_value "$source_name" "$stats")"
    if [[ -n "$value" ]]; then
      printf 'mtproxy_%s{container="%s"} %s\n' \
        "$source_name" "$container" "$value" >> "$temp_file"
    fi
  done
}

containers=()
while IFS= read -r container; do
  containers+=("$container")
done < <(
  docker ps --format '{{.Names}}' \
    | while IFS= read -r container; do
        if [[ "$container" =~ ^${NAME_PREFIX}-[0-9]+$ ]]; then
          printf '%s\n' "$container"
        fi
      done \
    | sort -V
)

printf 'mtproxy_expected_containers %s\n' "$EXPECTED_COUNT" >> "$temp_file"
printf 'mtproxy_running_containers %s\n' "${#containers[@]}" >> "$temp_file"

for container in "${containers[@]}"; do
  raw_stats=""
  stats=""

  if raw_stats="$(
    timeout 5s docker exec "$container" bash -c '
      exec 3<>/dev/tcp/127.0.0.1/2398
      printf "GET /stats HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3
      cat <&3
    ' 2>/dev/null
  )"; then
    stats="$(tr -d '\r' <<< "$raw_stats")"
  fi

  if [[ -n "$(metric_value total_ready_targets "$stats")" ]]; then
    printf 'mtproxy_scrape_success{container="%s"} 1\n' "$container" >> "$temp_file"
    printf 'mtproxy_stats_last_success_unixtime{container="%s"} %s\n' \
      "$container" "$(date +%s)" >> "$temp_file"
    write_selected_metrics "$container" "$stats"
  else
    printf 'mtproxy_scrape_success{container="%s"} 0\n' "$container" >> "$temp_file"
  fi
done

chmod 0644 "$temp_file"
mv -f "$temp_file" "$OUTPUT_FILE"
trap - EXIT
EOF
}

write_collector_config() {
  cat > "$COLLECTOR_CONFIG" <<EOF
NAME_PREFIX=${NAME_PREFIX}
EXPECTED_COUNT=${EXPECTED_COUNT}
METRICS_DIR=${ALLOY_TEXTFILE_DIR}
EOF
  chmod 0644 "$COLLECTOR_CONFIG"
}

write_systemd_units() {
  cat > "$COLLECTOR_SERVICE" <<EOF
[Unit]
Description=Collect Telegram MTProxy Prometheus metrics
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${COLLECTOR_PATH}
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  cat > "$COLLECTOR_TIMER" <<'EOF'
[Unit]
Description=Collect Telegram MTProxy metrics every 30 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true
Unit=mtproxy-stats-collector.service

[Install]
WantedBy=timers.target
EOF

  install -d -m 0755 "$ALLOY_OVERRIDE_DIR"
  cat > "$ALLOY_OVERRIDE" <<'EOF'
[Service]
User=root
Group=root
EOF
}

install_configuration() {
  local config_temp
  local config_backup
  local timestamp

  install_token
  install -d -m 0755 "$ALLOY_TEXTFILE_DIR"

  config_temp="$(mktemp /etc/alloy/.config.alloy.XXXXXX)"
  write_alloy_config "$config_temp"

  if [[ -f "$ALLOY_CONFIG" ]] \
    && ! grep -Fq "Managed by monitoring-setup.bash" "$ALLOY_CONFIG"; then
    if [[ "$FORCE" != "yes" && "$ALLOY_INSTALLED_NOW" != "yes" ]]; then
      rm -f "$config_temp"
      err "Existing Alloy configuration is not managed by this script: ${ALLOY_CONFIG}"
      err "Rerun with --force to back it up and replace it"
      return 1
    fi

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    config_backup="${ALLOY_CONFIG}.backup.${timestamp}"
    cp -a "$ALLOY_CONFIG" "$config_backup"
    log "Backed up existing Alloy configuration to ${config_backup}"
  fi

  alloy validate "$config_temp"
  install -m 0600 -o root -g root "$config_temp" "$ALLOY_CONFIG"
  rm -f "$config_temp"

  write_stats_collector "$COLLECTOR_PATH"
  chmod 0755 "$COLLECTOR_PATH"
  write_collector_config
  write_systemd_units
}

start_monitoring() {
  systemctl daemon-reload
  systemctl enable --now mtproxy-stats-collector.timer
  systemctl start mtproxy-stats-collector.service
  systemctl enable --now alloy
  systemctl restart alloy
}

verify_monitoring() {
  log "Checking services"
  systemctl --no-pager --full status alloy
  systemctl --no-pager --full status mtproxy-stats-collector.timer

  if [[ ! -s "${ALLOY_TEXTFILE_DIR}/mtproxy.prom" ]]; then
    err "MTProxy metrics file was not created"
    return 1
  fi

  log "Alloy and the MTProxy collector are running"
  echo
  echo "Local health check:"
  echo "  curl -fsS http://127.0.0.1:12345/-/healthy"
  echo
  echo "MTProxy metrics:"
  echo "  sudo cat ${ALLOY_TEXTFILE_DIR}/mtproxy.prom"
  echo
  echo "Next Grafana Cloud steps:"
  echo "  1. Install the Linux Server and Docker dashboards under Connections."
  echo "  2. Add a Synthetic Monitoring TCP check for the public load-balancer port."
  echo "  3. Create alert rules and a Telegram contact point."
}

main() {
  parse_args "$@"
  load_deployment_state
  validate_inputs
  install_alloy
  install_configuration
  start_monitoring
  verify_monitoring
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
