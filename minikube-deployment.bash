#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Minikube on macOS without Docker + persistent port-forwarding
# ============================================================
#
# What this script does:
# 1. Installs required tools via Homebrew:
#    - minikube
#    - kubectl
#    - qemu
#    - socket_vmnet
# 2. Starts socket_vmnet (needed for full QEMU networking on macOS)
# 3. Starts Minikube using QEMU, not Docker
# 4. Enables the ingress addon
# 5. Optionally installs a persistent launchd agent for kubectl port-forward
#
# Why QEMU + socket_vmnet?
# Minikube docs state that with the QEMU driver on macOS,
# socket_vmnet provides full networking functionality, including
# service and tunnel commands.
#
# Usage examples:
#
#   # Just install and start minikube
#   ./setup-minikube-mac.sh
#
#   # Install/start minikube and create persistent port-forward
#   ./setup-minikube-mac.sh \
#       --pf-namespace default \
#       --pf-service my-service \
#       --pf-local-port 8080 \
#       --pf-remote-port 80
#
#   # Use a custom profile / memory / CPUs
#   ./setup-minikube-mac.sh \
#       --profile dev \
#       --cpus 4 \
#       --memory 8192
#
# Notes:
# - Persistent forwarding here is implemented with launchd by running:
#     kubectl port-forward svc/<service> LOCAL:REMOTE
# - This is the simplest durable option for a specific service.
# - For LoadBalancer services, minikube tunnel is often the better model.
#   You can create a separate launchd unit for "minikube tunnel" if needed.
#
# ============================================================

PROFILE="minikube"
K8S_VERSION=""
CPUS="4"
MEMORY_MB="8192"
DISK_SIZE="30g"

PF_NAMESPACE=""
PF_SERVICE=""
PF_LOCAL_PORT=""
PF_REMOTE_PORT=""

BREW_BIN=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${HOME}/Library/Logs/minikube-port-forward"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"

print_usage() {
  cat <<'EOF'
Usage:
  setup-minikube-mac.sh [options]

Options:
  --profile NAME             Minikube profile name (default: minikube)
  --k8s-version VERSION      Kubernetes version, e.g. v1.31.0
  --cpus N                   CPUs for the VM (default: 4)
  --memory MB                Memory in MB (default: 8192)
  --disk-size SIZE           Disk size for the VM (default: 30g)

  --pf-namespace NS          Namespace for persistent kubectl port-forward
  --pf-service NAME          Service name for persistent kubectl port-forward
  --pf-local-port PORT       Local port on your Mac
  --pf-remote-port PORT      Remote port of the Kubernetes Service

  -h, --help                 Show this help

Examples:
  ./setup-minikube-mac.sh

  ./setup-minikube-mac.sh \
    --pf-namespace default \
    --pf-service my-service \
    --pf-local-port 8080 \
    --pf-remote-port 80
EOF
}

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

err() {
  echo "[ERROR] $*" >&2
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Required command not found: $cmd"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        PROFILE="$2"
        shift 2
        ;;
      --k8s-version)
        K8S_VERSION="$2"
        shift 2
        ;;
      --cpus)
        CPUS="$2"
        shift 2
        ;;
      --memory)
        MEMORY_MB="$2"
        shift 2
        ;;
      --disk-size)
        DISK_SIZE="$2"
        shift 2
        ;;
      --pf-namespace)
        PF_NAMESPACE="$2"
        shift 2
        ;;
      --pf-service)
        PF_SERVICE="$2"
        shift 2
        ;;
      --pf-local-port)
        PF_LOCAL_PORT="$2"
        shift 2
        ;;
      --pf-remote-port)
        PF_REMOTE_PORT="$2"
        shift 2
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        err "Unknown argument: $1"
        print_usage
        exit 1
        ;;
    esac
  done
}

detect_brew() {
  if command -v brew >/dev/null 2>&1; then
    BREW_BIN="$(command -v brew)"
    return 0
  fi

  err "Homebrew is not installed."
  err "Install it first from https://brew.sh and run this script again."
  exit 1
}

install_formula_if_missing() {
  local formula="$1"

  if brew list --formula "$formula" >/dev/null 2>&1; then
    log "Homebrew formula already installed: $formula"
  else
    log "Installing Homebrew formula: $formula"
    brew install "$formula"
  fi
}

install_tools() {
  log "Updating Homebrew metadata"
  brew update

  install_formula_if_missing minikube
  install_formula_if_missing kubectl
  install_formula_if_missing qemu
  install_formula_if_missing socket_vmnet
}

start_socket_vmnet() {
  # Minikube's QEMU driver docs recommend socket_vmnet on macOS
  # for full networking functionality.
  log "Starting socket_vmnet service (requires sudo)"
  sudo "${BREW_BIN}" services start socket_vmnet
}

configure_minikube_defaults() {
  log "Configuring minikube defaults for profile: ${PROFILE}"
  minikube config set driver qemu
  minikube config set memory "${MEMORY_MB}"
  minikube config set cpus "${CPUS}"
  minikube config set disk-size "${DISK_SIZE}"
}

start_minikube() {
  local args=(
    start
    --profile="${PROFILE}"
    --driver=qemu
    --network=socket_vmnet
    --cpus="${CPUS}"
    --memory="${MEMORY_MB}"
    --disk-size="${DISK_SIZE}"
  )

  # Optional k8s version pin
  if [[ -n "${K8S_VERSION}" ]]; then
    args+=(--kubernetes-version="${K8S_VERSION}")
  fi

  log "Starting minikube with QEMU + socket_vmnet"
  minikube "${args[@]}"
}

enable_addons() {
  log "Enabling ingress addon"
  minikube addons enable ingress -p "${PROFILE}" || warn "Could not enable ingress addon"
}

verify_cluster() {
  log "Verifying cluster status"
  minikube status -p "${PROFILE}"
  kubectl cluster-info
  kubectl get nodes -o wide
}

wait_for_service() {
  local ns="$1"
  local svc="$2"

  log "Waiting for Service ${svc} in namespace ${ns}"
  # Wait until the service exists.
  for _ in {1..60}; do
    if kubectl get svc "$svc" -n "$ns" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  err "Service ${svc} in namespace ${ns} was not found."
  exit 1
}

create_port_forward_script() {
  local ns="$1"
  local svc="$2"
  local local_port="$3"
  local remote_port="$4"

  local pf_script="${HOME}/.local/bin/minikube-port-forward-${PROFILE}-${ns}-${svc}.sh"
  mkdir -p "$(dirname "$pf_script")"
  mkdir -p "${LOG_DIR}"

  cat > "$pf_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# This helper is started by launchd.
# It waits for the cluster and service, then continuously port-forwards.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROFILE="${PROFILE}"
NAMESPACE="${ns}"
SERVICE="${svc}"
LOCAL_PORT="${local_port}"
REMOTE_PORT="${remote_port}"

log() {
  echo "[port-forward] \$*"
}

# Wait for minikube to become reachable
for i in {1..120}; do
  if minikube status -p "\$PROFILE" >/dev/null 2>&1; then
    if kubectl get nodes >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 2
done

# Wait for the target service to exist
for i in {1..120}; do
  if kubectl get svc "\$SERVICE" -n "\$NAMESPACE" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Keep restarting port-forward if the connection drops
while true; do
  log "Starting: kubectl port-forward -n \$NAMESPACE svc/\$SERVICE \$LOCAL_PORT:\$REMOTE_PORT --address 0.0.0.0"
  kubectl port-forward -n "\$NAMESPACE" "svc/\$SERVICE" "\$LOCAL_PORT:\$REMOTE_PORT" --address 0.0.0.0
  log "Port-forward stopped; retrying in 3 seconds"
  sleep 3
done
EOF

  chmod +x "$pf_script"
  echo "$pf_script"
}

create_launch_agent() {
  local ns="$1"
  local svc="$2"
  local local_port="$3"
  local remote_port="$4"

  local label="local.minikube.portforward.${PROFILE}.${ns}.${svc}.${local_port}.${remote_port}"
  local plist="${LAUNCH_AGENTS_DIR}/${label}.plist"
  local pf_script
  pf_script="$(create_port_forward_script "$ns" "$svc" "$local_port" "$remote_port")"

  mkdir -p "${LAUNCH_AGENTS_DIR}"
  mkdir -p "${LOG_DIR}"

  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${label}</string>

    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>${pf_script}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/${label}.out.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/${label}.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
  </dict>
</plist>
EOF

  # Unload old version if it exists
  launchctl unload "$plist" >/dev/null 2>&1 || true

  log "Loading launch agent: ${plist}"
  launchctl load "$plist"

  echo "$plist"
}

validate_pf_args() {
  local any_pf_arg="false"

  [[ -n "${PF_NAMESPACE}" ]] && any_pf_arg="true"
  [[ -n "${PF_SERVICE}" ]] && any_pf_arg="true"
  [[ -n "${PF_LOCAL_PORT}" ]] && any_pf_arg="true"
  [[ -n "${PF_REMOTE_PORT}" ]] && any_pf_arg="true"

  if [[ "${any_pf_arg}" == "false" ]]; then
    return 0
  fi

  if [[ -z "${PF_NAMESPACE}" || -z "${PF_SERVICE}" || -z "${PF_LOCAL_PORT}" || -z "${PF_REMOTE_PORT}" ]]; then
    err "To configure persistent port-forwarding, you must provide all of:"
    err "  --pf-namespace --pf-service --pf-local-port --pf-remote-port"
    exit 1
  fi
}

show_summary() {
  echo
  echo "============================================================"
  echo "Minikube setup complete"
  echo "============================================================"
  echo "Profile:        ${PROFILE}"
  echo "Driver:         qemu"
  echo "Network:        socket_vmnet"
  echo "CPUs:           ${CPUS}"
  echo "Memory (MB):    ${MEMORY_MB}"
  echo "Disk size:      ${DISK_SIZE}"
  if [[ -n "${K8S_VERSION}" ]]; then
    echo "K8s version:    ${K8S_VERSION}"
  fi
  echo

  echo "Useful commands:"
  echo "  minikube status -p ${PROFILE}"
  echo "  kubectl get nodes"
  echo "  kubectl get pods -A"
  echo "  minikube dashboard -p ${PROFILE}"
  echo

  if [[ -n "${PF_SERVICE}" ]]; then
    echo "Persistent port-forward configured:"
    echo "  Namespace:     ${PF_NAMESPACE}"
    echo "  Service:       ${PF_SERVICE}"
    echo "  Local port:    ${PF_LOCAL_PORT}"
    echo "  Remote port:   ${PF_REMOTE_PORT}"
    echo "  Test locally:  curl http://127.0.0.1:${PF_LOCAL_PORT}"
    echo
    echo "LaunchAgent logs:"
    echo "  ${LOG_DIR}"
    echo
    echo "To stop the forwarding LaunchAgent later:"
    echo "  launchctl unload ~/Library/LaunchAgents/local.minikube.portforward.${PROFILE}.${PF_NAMESPACE}.${PF_SERVICE}.${PF_LOCAL_PORT}.${PF_REMOTE_PORT}.plist"
  fi
}

main() {
  parse_args "$@"
  validate_pf_args
  detect_brew

  require_command bash

  install_tools
  start_socket_vmnet
  configure_minikube_defaults
  start_minikube
  enable_addons
  verify_cluster

  if [[ -n "${PF_SERVICE}" ]]; then
    wait_for_service "${PF_NAMESPACE}" "${PF_SERVICE}"
    create_launch_agent "${PF_NAMESPACE}" "${PF_SERVICE}" "${PF_LOCAL_PORT}" "${PF_REMOTE_PORT}" >/dev/null
  fi

  show_summary
}

main "$@"