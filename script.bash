#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-$HOME/mtproxy}"
IMAGE="${IMAGE:-telegrammessenger/proxy:latest}"
NAME_PREFIX="${NAME_PREFIX:-mtproxy}"
USE_DD_SECRET="${USE_DD_SECRET:-yes}"

PORT_START=""
PORT_END=""
COUNT=""

log() {
  echo "[*] $*"
}

err() {
  echo "[!] $*" >&2
}

usage() {
  cat <<EOF
Usage:
  $0 --port-range START-END [--prefix NAME] [--workdir PATH]

Examples:
  $0 --port-range 4000-4009
  $0 --port-range 3443-3452 --prefix proxy
  $0 --port-range 5000-5004 --workdir /opt/mtproxy

Options:
  --port-range START-END   Required. One port per container.
  --prefix NAME            Container prefix. Default: mtproxy
  --workdir PATH           Working directory. Default: ~/mtproxy
  --image IMAGE            Docker image. Default: telegrammessenger/proxy:latest
  --dd-secret yes|no       Prefix client secret with dd. Default: yes
EOF
}

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

get_public_ip() {
  curl -4 -fsS https://api.ipify.org || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port-range)
        PORT_RANGE="${2:-}"
        shift 2
        ;;
      --prefix)
        NAME_PREFIX="${2:-}"
        shift 2
        ;;
      --workdir)
        WORKDIR="${2:-}"
        shift 2
        ;;
      --image)
        IMAGE="${2:-}"
        shift 2
        ;;
      --dd-secret)
        USE_DD_SECRET="${2:-}"
        shift 2
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

  if [[ -z "${PORT_RANGE:-}" ]]; then
    err "--port-range is required"
    usage
    exit 1
  fi

  if [[ ! "$PORT_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    err "Invalid port range format: $PORT_RANGE"
    err "Expected format: START-END"
    exit 1
  fi

  PORT_START="${BASH_REMATCH[1]}"
  PORT_END="${BASH_REMATCH[2]}"

  if (( PORT_START < 1 || PORT_START > 65535 || PORT_END < 1 || PORT_END > 65535 )); then
    err "Ports must be between 1 and 65535"
    exit 1
  fi

  if (( PORT_START > PORT_END )); then
    err "Port range start must be <= end"
    exit 1
  fi

  COUNT=$((PORT_END - PORT_START + 1))
}

prepare_system() {
  run_as_root apt update
  run_as_root apt install -y docker.io curl xxd cron
  run_as_root systemctl enable --now docker
  run_as_root systemctl enable --now cron || true
}

prepare_files() {
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  if [[ ! -f proxy-secret ]]; then
    log "Downloading proxy-secret"
    curl -fsS https://core.telegram.org/getProxySecret -o proxy-secret
  else
    log "proxy-secret already exists, keeping it"
  fi

  if [[ ! -f proxy-multi.conf ]]; then
    log "Downloading proxy-multi.conf"
    curl -fsS https://core.telegram.org/getProxyConfig -o proxy-multi.conf
  else
    log "proxy-multi.conf already exists, keeping it"
  fi

  if [[ ! -f mtproxy-secret ]]; then
    log "Generating shared secret"
    head -c 16 /dev/urandom | xxd -ps -c 16 > mtproxy-secret
    chmod 600 mtproxy-secret
  else
    log "mtproxy-secret already exists, keeping it"
  fi
}

load_secret() {
  SECRET="$(tr -d '\r\n' < "$WORKDIR/mtproxy-secret")"
  if [[ -z "$SECRET" ]]; then
    err "Secret file is empty: $WORKDIR/mtproxy-secret"
    exit 1
  fi
}

prune_previous_containers() {
  log "Removing previous containers with prefix ${NAME_PREFIX}-"
  local ids
  ids="$(run_as_root docker ps -aq --filter "name=^${NAME_PREFIX}-[0-9]+$" || true)"

  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    run_as_root docker rm -f $ids
  else
    log "No previous containers found"
  fi
}

open_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    run_as_root ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
}

deploy_one() {
  local index="$1"
  local port="$2"
  local name="${NAME_PREFIX}-${index}"

  log "Deploying ${name} on port ${port}"

  run_as_root docker run -d \
    --name "$name" \
    --restart unless-stopped \
    -p "${port}:443" \
    -v "$WORKDIR/proxy-secret:/data/secret:ro" \
    -v "$WORKDIR/proxy-multi.conf:/data/proxy-multi.conf:ro" \
    -e SECRET="$SECRET" \
    "$IMAGE" >/dev/null

  open_port "$port"
}

deploy_from_port_range() {
  local port
  local index=1

  for ((port=PORT_START; port<=PORT_END; port++)); do
    deploy_one "$index" "$port"
    ((index++))
  done
}

install_refresh_cron() {
  local cron_line
  cron_line="0 4 * * * cd $WORKDIR && curl -fsS https://core.telegram.org/getProxyConfig -o proxy-multi.conf && sudo docker restart \$(sudo docker ps -q --filter 'name=^${NAME_PREFIX}-[0-9]+$') >/dev/null 2>&1"

  (
    crontab -l 2>/dev/null | grep -v "getProxyConfig -o proxy-multi.conf" || true
    echo "$cron_line"
  ) | crontab -
}

print_links() {
  local ip client_secret
  ip="$(get_public_ip)"
  [[ -n "$ip" ]] || ip="<YOUR_SERVER_IP>"

  if [[ "$USE_DD_SECRET" == "yes" ]]; then
    client_secret="dd${SECRET}"
  else
    client_secret="${SECRET}"
  fi

  echo
  echo "Deployed ${COUNT} containers"
  echo "Shared client secret: ${client_secret}"
  echo

  local port
  local index=1
  for ((port=PORT_START; port<=PORT_END; port++)); do
    echo "${NAME_PREFIX}-${index}: tg://proxy?server=${ip}&port=${port}&secret=${client_secret}"
    ((index++))
  done
}

main() {
  parse_args "$@"
  prepare_system
  prepare_files
  load_secret
  prune_previous_containers
  deploy_from_port_range
  install_refresh_cron
  print_links
}

main "$@"