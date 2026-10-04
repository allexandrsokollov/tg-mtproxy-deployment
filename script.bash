#!/usr/bin/env bash
# Debian/Ubuntu with systemd. Run as root; all build/config files are generated.
set -euo pipefail

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sudo bash script.bash [--public-ip IPv4] [--port PORT] [--secret HEX]

Installs Docker (if missing) and Nginx. Starts one MTProxy container per
available CPU core, with Nginx balancing TCP connections on a single public
port (default: 443). Prints the Telegram connection URL when ready.

The public IPv4 is detected automatically. A generated secret is retained
across deployments. WORKDIR defaults to /var/lib/mtproxy.
Rerunning replaces this script's containers and restarts its load balancer.
EOF
}

valid_ipv4() {
  local ip=$1 octet
  local -a octets
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
}

install_dependencies() {
  local -a packages=(ca-certificates curl openssl nginx libnginx-mod-stream iproute2)
  command -v docker >/dev/null 2>&1 || packages+=(docker.io)
  apt-get update >&2
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" >&2
  systemctl enable --now docker >&2
  docker info >/dev/null
}

prepare_files() {
  install -d -m 700 "$state_dir"
  exec 9>"$state_dir/deploy.lock"
  flock -n 9 || die 'Another deployment is running.'
  build_dir=$(mktemp -d "$state_dir/build.XXXXXX")
  trap 'rm -rf -- "$build_dir"' EXIT
  curl -fsS --connect-timeout 10 --max-time 60 \
    https://core.telegram.org/getProxySecret -o "$build_dir/proxy-secret"
  curl -fsS --connect-timeout 10 --max-time 60 \
    https://core.telegram.org/getProxyConfig -o "$build_dir/proxy-multi.conf"
  [[ -s $build_dir/proxy-secret && -s $build_dir/proxy-multi.conf ]] \
    || die 'Telegram returned an empty configuration.'
  if [[ -z $secret && -f $state_dir/mtproxy-secret ]]; then
    secret=$(cat "$state_dir/mtproxy-secret")
  elif [[ -z $secret ]]; then
    secret=$(openssl rand -hex 16)
  fi
  [[ $secret =~ ^[0-9a-fA-F]{32}$ ]] || die 'Stored secret must be 32 hex characters.'
  printf '%s\n' "$secret" >"$build_dir/mtproxy-secret"
  chmod 600 "$build_dir/mtproxy-secret"
}

build_image() {
  # Preserve the existing source revision and CentOS build environment.
  cat >"$build_dir/Dockerfile" <<'EOF'
FROM quay.io/centos/centos:stream9 AS builder
RUN dnf install -y gcc git make openssl-devel zlib-devel && dnf clean all
RUN git clone https://github.com/TelegramMessenger/MTProxy.git /usr/src/mtproxy \
    && cd /usr/src/mtproxy \
    && git checkout --detach cafc3380a81671579ce366d0594b9a8e450827e9 \
    && make -j"$(nproc)"
FROM quay.io/centos/centos:stream9
RUN dnf install -y iproute openssl-libs zlib && dnf clean all
COPY --from=builder /usr/src/mtproxy/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY entrypoint.bash /usr/local/bin/entrypoint.bash
RUN chmod 755 /usr/local/bin/entrypoint.bash
EXPOSE 443/tcp
ENTRYPOINT ["/usr/local/bin/entrypoint.bash"]
EOF
  cat >"$build_dir/entrypoint.bash" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
internal_ip=$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1);exit}}')
[[ -n $internal_ip ]] || exit 1
exec /usr/local/bin/mtproto-proxy -u nobody -p 2398 -H 443 -M 1 \
  -S "$SECRET" --nat-info "$internal_ip:$PUBLIC_IP" \
  --aes-pwd /data/proxy-secret /data/proxy-multi.conf
EOF
  docker build --platform linux/amd64 --tag tg-mtproxy:single-file "$build_dir" >&2
  mv -f "$build_dir/proxy-secret" "$state_dir/proxy-secret"
  mv -f "$build_dir/proxy-multi.conf" "$state_dir/proxy-multi.conf"
  mv -f "$build_dir/mtproxy-secret" "$state_dir/mtproxy-secret"
  chmod 600 "$state_dir/proxy-secret" "$state_dir/proxy-multi.conf" "$state_dir/mtproxy-secret"
}

wait_for_port() {
  local port=$1 attempt
  for ((attempt = 0; attempt < 30; attempt++)); do
    # The child Bash expands its positional argument, not this shell.
    # shellcheck disable=SC2016
    if timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/"$1"' _ "$port" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  die "TCP port $port did not become ready. Check Docker/Nginx logs."
}

deploy_containers() {
  local id index binding backend_port old_ids
  old_ids=$(docker ps -aq --filter label=mtproxy.single-file=true)
  while IFS= read -r id; do
    [[ -z $id ]] || docker rm -f "$id" >&2
  done <<<"$old_ids"
  {
    cat <<'EOF'
include /etc/nginx/modules-enabled/*.conf;
worker_processes auto;
pid /run/mtproxy-lb.pid;
error_log /var/log/nginx/mtproxy-lb-error.log;
events { worker_connections 4096; }
stream {
    upstream mtproxy_backend {
        least_conn;
EOF
    for ((index = 1; index <= cpu_count; index++)); do
      docker run -d --platform linux/amd64 --name "mtproxy-$index" \
        --label mtproxy.single-file=true --restart unless-stopped --cpus 1 \
        -p '127.0.0.1::443' \
        -v "$state_dir/proxy-secret:/data/proxy-secret:ro" \
        -v "$state_dir/proxy-multi.conf:/data/proxy-multi.conf:ro" \
        -e "SECRET=$secret" -e "PUBLIC_IP=$public_ip" \
        tg-mtproxy:single-file >&2
      binding=$(docker port "mtproxy-$index" 443/tcp)
      [[ $binding =~ ^127\.0\.0\.1:([0-9]+)$ ]] || die 'Unexpected Docker port binding.'
      backend_port=${BASH_REMATCH[1]}
      wait_for_port "$backend_port"
      printf '        server 127.0.0.1:%s max_fails=2 fail_timeout=10s;\n' "$backend_port"
    done
    cat <<EOF
    }
    server {
        listen $port;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        proxy_socket_keepalive on;
        proxy_pass mtproxy_backend;
    }
}
EOF
  } >"$build_dir/nginx.conf"
  nginx -t -c "$build_dir/nginx.conf" >&2
  mv -f "$build_dir/nginx.conf" "$state_dir/nginx.conf"
}

start_nginx() {
  # A dedicated unit/config leaves other Nginx sites intact.
  cat >"$state_dir/mtproxy-lb.service" <<EOF
[Unit]
Description=MTProxy Nginx TCP load balancer
Requires=docker.service
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=forking
PIDFile=/run/mtproxy-lb.pid
ExecStart=/usr/sbin/nginx -c $state_dir/nginx.conf
ExecReload=/usr/sbin/nginx -c $state_dir/nginx.conf -s reload
KillSignal=SIGQUIT
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
  install -m 644 "$state_dir/mtproxy-lb.service" /etc/systemd/system/mtproxy-lb.service
  systemctl daemon-reload
  systemctl enable mtproxy-lb.service >&2
  systemctl restart mtproxy-lb.service
  systemctl is-active --quiet mtproxy-lb.service
  wait_for_port "$port"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$port/tcp" >&2
  fi
}

main() {
  umask 077
  public_ip=''
  port=443
  secret=''
  state_dir=${WORKDIR:-/var/lib/mtproxy}
  while (($#)); do
    case $1 in
      --public-ip | --port | --secret)
        (($# >= 2)) && [[ -n $2 ]] || die "Missing value for $1."
        case $1 in
          --public-ip) public_ip=$2 ;;
          --port) port=$2 ;;
          --secret) secret=$2 ;;
        esac
        shift 2
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
  [[ $port =~ ^[0-9]{1,5}$ ]] || die 'Port must be between 1 and 65535.'
  port=$((10#$port))
  ((port >= 1 && port <= 65535)) || die 'Port must be between 1 and 65535.'
  [[ -z $public_ip ]] || valid_ipv4 "$public_ip" || die 'Invalid public IPv4.'
  [[ -z $secret || $secret =~ ^[0-9a-fA-F]{32}$ ]] || die 'Secret must be 32 hex characters.'
  [[ $state_dir =~ ^/[a-zA-Z0-9_./-]+$ && $state_dir != / ]] \
    || die 'WORKDIR must be an absolute path without spaces or special characters.'
  [[ $(id -u) == 0 ]] || die 'Run this script as root (sudo bash script.bash).'
  [[ $(uname -s) == Linux ]] || die 'Debian/Ubuntu Linux is required.'
  local required
  for required in apt-get systemctl nproc flock timeout; do
    command -v "$required" >/dev/null 2>&1 || die "Required command missing: $required"
  done
  unset OMP_NUM_THREADS OMP_THREAD_LIMIT
  cpu_count=$(nproc)
  [[ $cpu_count =~ ^[1-9][0-9]*$ ]] || die 'Unable to determine available CPU cores.'
  install_dependencies
  if [[ -z $public_ip ]]; then
    public_ip=$(curl -4 -fsS --connect-timeout 10 --max-time 20 https://api.ipify.org)
    valid_ipv4 "$public_ip" || die 'IP detection failed; pass --public-ip IPv4.'
  fi
  prepare_files
  build_image
  deploy_containers
  start_nginx
  printf 'Deployed %s MTProxy containers. Load balancer: %s:%s\n' "$cpu_count" "$public_ip" "$port"
  printf 'tg://proxy?server=%s&port=%s&secret=dd%s\n' "$public_ip" "$port" "$secret"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
