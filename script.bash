#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$HOME/mtproxy}"
IMAGE="${IMAGE:-tg-mtproxy:local}"
NAME_PREFIX="${NAME_PREFIX:-mtproxy}"
BUILD_LOCAL_IMAGE="${BUILD_LOCAL_IMAGE:-yes}"
MTPROXY_COMMIT="${MTPROXY_COMMIT:-cafc3380a81671579ce366d0594b9a8e450827e9}"
MTPROXY_PLATFORM="${MTPROXY_PLATFORM:-linux/amd64}"
PULL_POLICY="${PULL_POLICY:-missing}"
PULL_RETRIES="${PULL_RETRIES:-3}"
PULL_RETRY_DELAY="${PULL_RETRY_DELAY:-5}"

LB_NAME="${LB_NAME:-mtproxy-lb}"
LB_IMAGE="${LB_IMAGE:-tg-mtproxy-nginx:local}"
BUILD_LOCAL_LB_IMAGE="${BUILD_LOCAL_LB_IMAGE:-yes}"
LB_PORT="${LB_PORT:-443}"
ENABLE_LB="${ENABLE_LB:-yes}"

USE_DD_SECRET="${USE_DD_SECRET:-yes}"
CUSTOM_SECRET=""
PUBLIC_IP="${PUBLIC_IP:-}"

PORT_RANGE=""
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
  $0 --port-range START-END [options]

Examples:
  $0 --port-range 4000-4009
  $0 --port-range 5000-5009 --lb-port 443
  $0 --port-range 30000-30009 --prefix proxy --lb-port 8443
  $0 --port-range 4000-4009 --secret 0123456789abcdef0123456789abcdef

Options:
  --port-range START-END   Required. One host port per proxy container.
  --secret SECRET          Custom shared secret. Must be 32 hex chars.
                           A leading dd prefix is accepted and stripped.
  --public-ip IP           Public IPv4 address. Detected automatically by default.
  --lb-port PORT           Load balancer public port. Default: 443
  --prefix NAME            Proxy container prefix. Default: mtproxy
  --workdir PATH           Working directory. Default: ~/mtproxy
  --image IMAGE            Proxy image/tag. Default: tg-mtproxy:local
  --build-local-image yes|no
                           Build from Telegram's official source. Default: yes
  --mtproxy-commit SHA     Official source commit to build.
  --lb-image IMAGE         LB image/tag. Default: tg-mtproxy-nginx:local
  --build-local-lb yes|no  Build the NGINX load balancer locally. Default: yes
  --pull-policy POLICY     Image policy: missing, always, or never. Default: missing
  --pull-retries N         Retries after a transient pull failure. Default: 3
  --dd-secret yes|no       Prefix client secret with dd. Default: yes
  --enable-lb yes|no       Start NGINX load balancer. Default: yes
  -h, --help               Show help

Deployment secrets and settings are persisted in the work directory. Use
backup.bash to create, restore, or redeploy from a protected backup.
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

validate_ipv4() {
  local ip="$1"
  local octet
  local -a octets

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

resolve_public_ip() {
  if [[ -z "$PUBLIC_IP" ]]; then
    log "Detecting public IPv4 address"
    PUBLIC_IP="$(get_public_ip)"
  fi

  if ! validate_ipv4 "$PUBLIC_IP"; then
    err "Unable to determine a valid public IPv4 address"
    err "Pass it explicitly with --public-ip IP"
    return 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port-range)
        PORT_RANGE="${2:-}"
        shift 2
        ;;
      --lb-port)
        LB_PORT="${2:-}"
        shift 2
        ;;
      --secret)
        CUSTOM_SECRET="${2:-}"
        shift 2
        ;;
      --public-ip)
        PUBLIC_IP="${2:-}"
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
      --build-local-image)
        BUILD_LOCAL_IMAGE="${2:-}"
        shift 2
        ;;
      --mtproxy-commit)
        MTPROXY_COMMIT="${2:-}"
        shift 2
        ;;
      --lb-image)
        LB_IMAGE="${2:-}"
        shift 2
        ;;
      --build-local-lb)
        BUILD_LOCAL_LB_IMAGE="${2:-}"
        shift 2
        ;;
      --pull-policy)
        PULL_POLICY="${2:-}"
        shift 2
        ;;
      --pull-retries)
        PULL_RETRIES="${2:-}"
        shift 2
        ;;
      --dd-secret)
        USE_DD_SECRET="${2:-}"
        shift 2
        ;;
      --enable-lb)
        ENABLE_LB="${2:-}"
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

  if [[ -n "$CUSTOM_SECRET" ]]; then
    CUSTOM_SECRET="${CUSTOM_SECRET//$'\r'/}"
    CUSTOM_SECRET="${CUSTOM_SECRET//$'\n'/}"

    if [[ "$CUSTOM_SECRET" =~ ^[dD][dD]([0-9a-fA-F]{32})$ ]]; then
      CUSTOM_SECRET="${BASH_REMATCH[1]}"
    fi

    if [[ ! "$CUSTOM_SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
      err "Invalid secret: must be 32 hex characters"
      err "If you pass a client secret with a leading dd prefix, it must be dd plus 32 hex characters"
      exit 1
    fi

    CUSTOM_SECRET="${CUSTOM_SECRET,,}"
  fi

  if [[ ! "$LB_PORT" =~ ^[0-9]+$ ]] || (( LB_PORT < 1 || LB_PORT > 65535 )); then
    err "LB port must be between 1 and 65535"
    exit 1
  fi

  if [[ "$ENABLE_LB" == "yes" ]] && (( LB_PORT >= PORT_START && LB_PORT <= PORT_END )); then
    err "LB port ${LB_PORT} conflicts with proxy port range ${PORT_START}-${PORT_END}"
    err "Choose a load balancer port outside the proxy range"
    exit 1
  fi

  case "$PULL_POLICY" in
    missing|always|never)
      ;;
    *)
      err "Invalid pull policy: $PULL_POLICY"
      err "Expected one of: missing, always, never"
      exit 1
      ;;
  esac

  case "$BUILD_LOCAL_IMAGE" in
    yes|no)
      ;;
    *)
      err "--build-local-image must be yes or no"
      exit 1
      ;;
  esac

  case "$BUILD_LOCAL_LB_IMAGE" in
    yes|no)
      ;;
    *)
      err "--build-local-lb must be yes or no"
      exit 1
      ;;
  esac

  case "$USE_DD_SECRET" in
    yes|no)
      ;;
    *)
      err "--dd-secret must be yes or no"
      exit 1
      ;;
  esac

  case "$ENABLE_LB" in
    yes|no)
      ;;
    *)
      err "--enable-lb must be yes or no"
      exit 1
      ;;
  esac

  if [[ ! "$NAME_PREFIX" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    err "Proxy name prefix contains unsupported characters: $NAME_PREFIX"
    exit 1
  fi

  if [[ ! "$LB_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    err "Load balancer name contains unsupported characters: $LB_NAME"
    exit 1
  fi

  if [[ ! "$IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]]; then
    err "Proxy image reference contains unsupported characters: $IMAGE"
    exit 1
  fi

  if [[ ! "$LB_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]]; then
    err "Load balancer image reference contains unsupported characters: $LB_IMAGE"
    exit 1
  fi

  if [[ ! "$MTPROXY_PLATFORM" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./-]*$ ]]; then
    err "MTProxy platform contains unsupported characters: $MTPROXY_PLATFORM"
    exit 1
  fi

  if [[ ! "$MTPROXY_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    err "MTProxy commit must be a full 40-character hexadecimal Git commit"
    exit 1
  fi

  if [[ ! "$PULL_RETRIES" =~ ^[0-9]+$ ]]; then
    err "Pull retries must be a non-negative integer"
    exit 1
  fi

  if [[ ! "$PULL_RETRY_DELAY" =~ ^[0-9]+$ ]]; then
    err "Pull retry delay must be a non-negative integer"
    exit 1
  fi

  COUNT=$((PORT_END - PORT_START + 1))
}

prepare_system() {
  log "Installing dependencies"

  run_as_root apt update
  run_as_root apt install -y ca-certificates curl xxd cron

  if ! grep -qs "download.docker.com" /etc/apt/sources.list.d/docker.sources 2>/dev/null; then
    log "Adding Docker apt repository"
    run_as_root install -m 0755 -d /etc/apt/keyrings
    run_as_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    run_as_root chmod a+r /etc/apt/keyrings/docker.asc

    run_as_root bash -lc 'cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: '"$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"'
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF'
  fi

  log "Removing conflicting packages if present"
  run_as_root apt remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc || true

  run_as_root apt update
  run_as_root apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  run_as_root systemctl enable --now docker
  run_as_root systemctl enable --now cron || true
}

image_exists() {
  local image="$1"
  run_as_root docker image inspect "$image" >/dev/null 2>&1
}

build_local_proxy_image() {
  local dockerfile="${SCRIPT_DIR}/docker/mtproxy.Dockerfile"
  local context="${SCRIPT_DIR}/docker"

  if [[ ! -f "$dockerfile" || ! -f "${context}/mtproxy-entrypoint.bash" ]]; then
    err "Local MTProxy build files were not found under ${context}"
    err "Run this script from a complete checkout of the deployment repository"
    return 1
  fi

  log "Building ${IMAGE} from TelegramMessenger/MTProxy commit ${MTPROXY_COMMIT}"
  run_as_root docker build \
    --platform "$MTPROXY_PLATFORM" \
    --build-arg "MTPROXY_COMMIT=${MTPROXY_COMMIT}" \
    --file "$dockerfile" \
    --tag "$IMAGE" \
    "$context"
}

ensure_local_proxy_image() {
  case "$PULL_POLICY" in
    missing)
      if image_exists "$IMAGE"; then
        log "Using cached locally built image ${IMAGE}"
        return 0
      fi
      build_local_proxy_image
      ;;
    always)
      build_local_proxy_image
      ;;
    never)
      if image_exists "$IMAGE"; then
        log "Using cached locally built image ${IMAGE}"
        return 0
      fi
      err "Locally built image ${IMAGE} is missing and pull policy is 'never'"
      return 1
      ;;
  esac
}

build_local_lb_image() {
  local dockerfile="${SCRIPT_DIR}/docker/nginx.Dockerfile"

  if [[ ! -f "$dockerfile" ]]; then
    err "Local NGINX Dockerfile was not found: ${dockerfile}"
    err "Run this script from a complete checkout of the deployment repository"
    return 1
  fi

  log "Building local NGINX load balancer image ${LB_IMAGE}"
  run_as_root docker build \
    --platform "$MTPROXY_PLATFORM" \
    --file "$dockerfile" \
    --tag "$LB_IMAGE" \
    "${SCRIPT_DIR}/docker"
}

ensure_local_lb_image() {
  case "$PULL_POLICY" in
    missing)
      if image_exists "$LB_IMAGE"; then
        log "Using cached locally built image ${LB_IMAGE}"
        return 0
      fi
      build_local_lb_image
      ;;
    always)
      build_local_lb_image
      ;;
    never)
      if image_exists "$LB_IMAGE"; then
        log "Using cached locally built image ${LB_IMAGE}"
        return 0
      fi
      err "Locally built image ${LB_IMAGE} is missing and pull policy is 'never'"
      return 1
      ;;
  esac
}

is_retryable_pull_error() {
  local output="$1"
  grep -Eqi \
    '429|too many requests|timeout|timed out|temporary failure|connection reset|connection refused|tls handshake timeout|unexpected eof|i/o timeout|service unavailable|502 bad gateway|503 service unavailable|504 gateway timeout' \
    <<< "$output"
}

pull_image() {
  local image="$1"
  local attempt=1
  local max_attempts=$((PULL_RETRIES + 1))
  local delay="$PULL_RETRY_DELAY"
  local output

  while (( attempt <= max_attempts )); do
    log "Pulling image ${image} (attempt ${attempt}/${max_attempts})"

    if output="$(run_as_root docker pull "$image" 2>&1)"; then
      [[ -z "$output" ]] || echo "$output"
      return 0
    fi

    err "$output"

    if (( attempt >= max_attempts )) || ! is_retryable_pull_error "$output"; then
      break
    fi

    log "Transient image pull failure; retrying in ${delay}s"
    sleep "$delay"
    ((attempt++))

    if (( delay < 60 )); then
      delay=$((delay * 2))
      (( delay <= 60 )) || delay=60
    fi
  done

  err "Unable to obtain Docker image: ${image}"
  if grep -Eqi '429|too many requests' <<< "$output"; then
    err "Docker Hub rate-limited this server. Try 'docker login', wait for the limit to clear,"
    err "or pass --image with a trusted registry mirror. A cached image can be used with --pull-policy missing."
  fi
  return 1
}

ensure_image() {
  local image="$1"

  case "$PULL_POLICY" in
    missing)
      if image_exists "$image"; then
        log "Using cached image ${image}"
        return 0
      fi
      pull_image "$image"
      ;;
    always)
      pull_image "$image"
      ;;
    never)
      if image_exists "$image"; then
        log "Using cached image ${image}"
        return 0
      fi
      err "Image ${image} is not available locally and pull policy is 'never'"
      return 1
      ;;
  esac
}

prepare_images() {
  log "Checking required Docker images"
  if [[ "$BUILD_LOCAL_IMAGE" == "yes" ]]; then
    ensure_local_proxy_image || return 1
  else
    ensure_image "$IMAGE" || return 1
  fi

  if [[ "$ENABLE_LB" == "yes" ]]; then
    if [[ "$BUILD_LOCAL_LB_IMAGE" == "yes" ]]; then
      ensure_local_lb_image || return 1
    else
      ensure_image "$LB_IMAGE" || return 1
    fi
  fi
}

prepare_files() {
  mkdir -p "$WORKDIR"
  chmod 700 "$WORKDIR"
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

  if [[ -n "$CUSTOM_SECRET" ]]; then
    log "Writing custom shared secret"
    printf '%s\n' "$CUSTOM_SECRET" > mtproxy-secret
    chmod 600 mtproxy-secret
  elif [[ ! -f mtproxy-secret ]]; then
    log "Generating shared secret"
    head -c 16 /dev/urandom | xxd -ps -c 16 > mtproxy-secret
    chmod 600 mtproxy-secret
  else
    log "mtproxy-secret already exists, keeping it"
  fi

  chmod 600 proxy-secret proxy-multi.conf mtproxy-secret
}

load_secret() {
  SECRET="$(tr -d '\r\n' < "$WORKDIR/mtproxy-secret")"
  if [[ ! "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
    err "Secret file must contain exactly 32 hexadecimal characters: $WORKDIR/mtproxy-secret"
    exit 1
  fi
  SECRET="${SECRET,,}"
}

prune_previous_proxies() {
  log "Removing previous proxy containers with prefix ${NAME_PREFIX}-"
  local ids
  ids="$(run_as_root docker ps -aq --filter "name=^${NAME_PREFIX}-[0-9]+$" || true)"

  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    run_as_root docker rm -f $ids
  else
    log "No previous proxy containers found"
  fi
}

prune_previous_lb() {
  log "Removing previous load balancer container if it exists"
  run_as_root docker rm -f "$LB_NAME" >/dev/null 2>&1 || true
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
    --pull never \
    -p "${port}:443" \
    -v "$WORKDIR/proxy-secret:/data/secret:ro" \
    -v "$WORKDIR/proxy-multi.conf:/data/proxy-multi.conf:ro" \
    -e SECRET="$SECRET" \
    -e EXTERNAL_IP="$PUBLIC_IP" \
    "$IMAGE" >/dev/null
}

deploy_from_port_range() {
  local port
  local index=1

  for ((port=PORT_START; port<=PORT_END; port++)); do
    deploy_one "$index" "$port"
    ((index++))
  done
}

write_nginx_cfg() {
  log "Writing NGINX load balancer config"

  {
    if [[ "$BUILD_LOCAL_LB_IMAGE" == "yes" ]]; then
      echo "load_module /usr/lib64/nginx/modules/ngx_stream_module.so;"
      echo
    fi

    cat <<EOF
worker_processes auto;

events {
    worker_connections 4096;
}

stream {
    upstream mtproxy_backend {
EOF

    local port
    for ((port=PORT_START; port<=PORT_END; port++)); do
      echo "        server host.docker.internal:${port};"
    done

    cat <<EOF
    }

    server {
        listen ${LB_PORT};
        proxy_connect_timeout 5s;
        proxy_timeout 2m;
        proxy_pass mtproxy_backend;
    }
}
EOF
  } > "$WORKDIR/nginx.conf"
}

write_lb_compose() {
  log "Writing docker-compose.yml for NGINX load balancer"
  cat > "$WORKDIR/docker-compose.yml" <<EOF
services:
  ${LB_NAME}:
    image: ${LB_IMAGE}
    pull_policy: never
    container_name: ${LB_NAME}
    restart: unless-stopped
    ports:
      - "${LB_PORT}:${LB_PORT}"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
EOF
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    err "Neither 'docker compose' nor 'docker-compose' is available"
    exit 1
  fi
}

start_lb() {
  [[ "$ENABLE_LB" == "yes" ]] || return 0

  write_nginx_cfg
  write_lb_compose

  log "Starting load balancer on port ${LB_PORT}"
  local dc
  dc="$(compose_cmd)"
  (
    cd "$WORKDIR"
    run_as_root bash -lc "$dc up -d"
  )

  open_port "$LB_PORT"
}

install_refresh_cron() {
  log "Installing daily config refresh cron"
  local cron_line
  cron_line="0 4 * * * cd $WORKDIR && curl -fsS https://core.telegram.org/getProxyConfig -o proxy-multi.conf && sudo docker restart \$(sudo docker ps -q --filter 'name=^${NAME_PREFIX}-[0-9]+$') >/dev/null 2>&1"

  (
    crontab -l 2>/dev/null | grep -v "getProxyConfig -o proxy-multi.conf" || true
    echo "$cron_line"
  ) | crontab -
}

write_deployment_state() {
  local state_file="${WORKDIR}/deployment.env"
  local temp_file

  temp_file="$(mktemp "${WORKDIR}/.deployment.env.XXXXXX")"
  chmod 600 "$temp_file"

  {
    echo "FORMAT_VERSION=1"
    printf 'PORT_RANGE=%s\n' "$PORT_RANGE"
    printf 'PUBLIC_IP=%s\n' "$PUBLIC_IP"
    printf 'LB_PORT=%s\n' "$LB_PORT"
    printf 'NAME_PREFIX=%s\n' "$NAME_PREFIX"
    printf 'IMAGE=%s\n' "$IMAGE"
    printf 'BUILD_LOCAL_IMAGE=%s\n' "$BUILD_LOCAL_IMAGE"
    printf 'MTPROXY_COMMIT=%s\n' "$MTPROXY_COMMIT"
    printf 'MTPROXY_PLATFORM=%s\n' "$MTPROXY_PLATFORM"
    printf 'LB_NAME=%s\n' "$LB_NAME"
    printf 'LB_IMAGE=%s\n' "$LB_IMAGE"
    printf 'BUILD_LOCAL_LB_IMAGE=%s\n' "$BUILD_LOCAL_LB_IMAGE"
    printf 'PULL_POLICY=%s\n' "$PULL_POLICY"
    printf 'PULL_RETRIES=%s\n' "$PULL_RETRIES"
    printf 'PULL_RETRY_DELAY=%s\n' "$PULL_RETRY_DELAY"
    printf 'USE_DD_SECRET=%s\n' "$USE_DD_SECRET"
    printf 'ENABLE_LB=%s\n' "$ENABLE_LB"
  } > "$temp_file"

  mv -f "$temp_file" "$state_file"
  chmod 600 "$state_file"
  log "Saved redeployment settings to ${state_file}"
}

print_result() {
  local ip client_secret
  ip="$PUBLIC_IP"

  if [[ "$USE_DD_SECRET" == "yes" ]]; then
    client_secret="dd${SECRET}"
  else
    client_secret="${SECRET}"
  fi

  echo
  echo "========================================"
  echo "Deployed ${COUNT} proxy containers"
  echo "Proxy range: ${PORT_START}-${PORT_END}"
  echo "Shared client secret: ${client_secret}"
  echo "========================================"
  echo

  if [[ "$ENABLE_LB" == "yes" ]]; then
    echo "Load balancer link:"
    echo "tg://proxy?server=${ip}&port=${LB_PORT}&secret=${client_secret}"
    echo
  fi

  echo "Direct links:"
  local port
  local index=1
  for ((port=PORT_START; port<=PORT_END; port++)); do
    echo "${NAME_PREFIX}-${index}: tg://proxy?server=${ip}&port=${port}&secret=${client_secret}"
    ((index++))
  done

  echo
  echo "Useful commands:"
  echo "  sudo docker ps"
  echo "  sudo docker logs ${LB_NAME}"
  echo "  sudo docker logs ${NAME_PREFIX}-1"
  echo "========================================"
}

main() {
  parse_args "$@"
  prepare_system
  prepare_images || return 1
  prepare_files
  load_secret
  resolve_public_ip || return 1
  prune_previous_proxies
  prune_previous_lb
  deploy_from_port_range
  start_lb
  install_refresh_cron
  write_deployment_state
  print_result
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
