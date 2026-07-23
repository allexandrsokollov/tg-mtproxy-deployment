#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../monitoring-setup.bash
source "${PROJECT_DIR}/monitoring-setup.bash"

TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT

assert_contains() {
  local expected="$1"
  local file="$2"
  grep -Fq "$expected" "$file"
}

test_deployment_state_is_loaded_without_sourcing_it() {
  local state_file="${TEST_TMP_DIR}/deployment.env"

  cat > "$state_file" <<'EOF'
NAME_PREFIX=proxy
PORT_RANGE=30000-30009
UNRELATED=$(touch /tmp/monitoring-setup-must-not-source)
EOF

  DEPLOYMENT_STATE="$state_file"
  NAME_PREFIX="mtproxy"
  PREFIX_EXPLICIT="no"
  EXPECTED_COUNT=""

  load_deployment_state

  [[ "$NAME_PREFIX" == "proxy" ]]
  [[ "$EXPECTED_COUNT" == "10" ]]
  [[ ! -e /tmp/monitoring-setup-must-not-source ]]
}

test_alloy_config_references_protected_token_file() {
  local config_file="${TEST_TMP_DIR}/config.alloy"
  local secret="secret-must-not-appear"

  METRICS_URL="https://prometheus.example.test/api/prom/push"
  METRICS_USER="12345"
  LOGS_URL="https://logs.example.test/loki/api/v1/push"
  LOGS_USER="67890"
  GRAFANA_CLOUD_TOKEN="$secret"

  write_alloy_config "$config_file"

  assert_contains 'prometheus.exporter.cadvisor "docker"' "$config_file"
  assert_contains 'loki.source.docker "docker_logs"' "$config_file"
  assert_contains 'textfile {' "$config_file"
  assert_contains "$ALLOY_TOKEN_FILE" "$config_file"

  if grep -Fq "$secret" "$config_file"; then
    echo "Rendered Alloy configuration contains a Grafana token" >&2
    return 1
  fi
}

test_collector_converts_mtproxy_stats() {
  local bin_dir="${TEST_TMP_DIR}/bin"
  local collector="${TEST_TMP_DIR}/collector"
  local collector_config="${TEST_TMP_DIR}/collector.env"
  local metrics_dir="${TEST_TMP_DIR}/metrics"

  mkdir -p "$bin_dir" "$metrics_dir"
  write_stats_collector "$collector"
  chmod +x "$collector"

  cat > "${bin_dir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "ps" ]]; then
  printf '%s\n' proxy-1 proxy-2 mtproxy-lb unrelated
  exit 0
fi

if [[ "${1:-}" == "exec" && "${2:-}" == "proxy-1" ]]; then
  printf 'HTTP/1.0 200 OK\r\n\r\n'
  printf 'workers\t2\n'
  printf 'total_ready_targets\t10\n'
  printf 'total_declared_targets\t9\n'
  printf 'total_connections\t42\n'
  printf 'total_special_connections\t31\n'
  printf 'mtproto_proxy_errors\t3\n'
  exit 0
fi

exit 1
EOF
  chmod +x "${bin_dir}/docker"

  cat > "${bin_dir}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
exec "$@"
EOF
  chmod +x "${bin_dir}/timeout"

  cat > "$collector_config" <<EOF
NAME_PREFIX=proxy
EXPECTED_COUNT=2
METRICS_DIR=${metrics_dir}
EOF

  PATH="${bin_dir}:${PATH}" \
    MTPROXY_MONITORING_CONFIG="$collector_config" \
    "$collector"

  assert_contains 'mtproxy_expected_containers 2' "${metrics_dir}/mtproxy.prom"
  assert_contains 'mtproxy_running_containers 2' "${metrics_dir}/mtproxy.prom"
  assert_contains 'mtproxy_scrape_success{container="proxy-1"} 1' "${metrics_dir}/mtproxy.prom"
  assert_contains 'mtproxy_total_ready_targets{container="proxy-1"} 10' "${metrics_dir}/mtproxy.prom"
  assert_contains 'mtproxy_total_declared_targets{container="proxy-1"} 9' "${metrics_dir}/mtproxy.prom"
  assert_contains 'mtproxy_scrape_success{container="proxy-2"} 0' "${metrics_dir}/mtproxy.prom"
}

run_test() {
  local name="$1"
  shift

  if "$@"; then
    echo "ok - ${name}"
  else
    echo "not ok - ${name}" >&2
    return 1
  fi
}

run_test "deployment state is parsed safely" test_deployment_state_is_loaded_without_sourcing_it
run_test "Alloy config protects token" test_alloy_config_references_protected_token_file
run_test "collector converts MTProxy stats" test_collector_converts_mtproxy_stats
