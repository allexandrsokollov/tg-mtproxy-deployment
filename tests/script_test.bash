#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../script.bash
source "${PROJECT_DIR}/script.bash"

TEST_TMP_DIR="$(mktemp -d)"
TEST_LOG_FILE="${TEST_TMP_DIR}/docker-pulls.log"
TEST_BUILD_LOG_FILE="${TEST_TMP_DIR}/docker-builds.log"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT

AVAILABLE_IMAGES=""
PULL_EXIT_CODE=0
PULL_OUTPUT="Pulled"
BUILD_EXIT_CODE=0

run_as_root() {
  "$@"
}

sleep() {
  :
}

docker() {
  if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
    grep -Fqx "${3:-}" <<< "$AVAILABLE_IMAGES"
    return
  fi

  if [[ "${1:-}" == "pull" ]]; then
    echo "${2:-}" >> "$TEST_LOG_FILE"
    echo "$PULL_OUTPUT" >&2
    return "$PULL_EXIT_CODE"
  fi

  if [[ "${1:-}" == "build" ]]; then
    echo "$*" >> "$TEST_BUILD_LOG_FILE"
    return "$BUILD_EXIT_CODE"
  fi

  return 0
}

reset_fixture() {
  : > "$TEST_LOG_FILE"
  : > "$TEST_BUILD_LOG_FILE"
  AVAILABLE_IMAGES=""
  PULL_EXIT_CODE=0
  PULL_OUTPUT="Pulled"
  BUILD_EXIT_CODE=0
  BUILD_LOCAL_IMAGE="no"
  BUILD_LOCAL_LB_IMAGE="no"
  PULL_POLICY="missing"
  PULL_RETRIES=3
  PULL_RETRY_DELAY=0
  IMAGE="telegrammessenger/proxy:latest"
  LB_IMAGE="nginx:stable"
  ENABLE_LB="no"
}

assert_build_count() {
  local expected="$1"
  local actual
  actual="$(wc -l < "$TEST_BUILD_LOG_FILE" | tr -d ' ')"

  if [[ "$actual" != "$expected" ]]; then
    echo "Expected ${expected} build calls, got ${actual}" >&2
    return 1
  fi
}

assert_pull_count() {
  local expected="$1"
  local actual
  actual="$(wc -l < "$TEST_LOG_FILE" | tr -d ' ')"

  if [[ "$actual" != "$expected" ]]; then
    echo "Expected ${expected} pull calls, got ${actual}" >&2
    return 1
  fi
}

assert_pulled_image() {
  local image="$1"
  grep -Fqx "$image" "$TEST_LOG_FILE"
}

test_cached_image_skips_pull() {
  reset_fixture
  AVAILABLE_IMAGES="$IMAGE"

  prepare_images >/dev/null

  assert_pull_count 0
}

test_public_ipv4_validation() {
  validate_ipv4 "203.0.113.10"
  validate_ipv4 "8.8.8.8"

  if validate_ipv4 "999.0.0.1" || validate_ipv4 "proxy.example.com"; then
    echo "Expected invalid public IPv4 input to be rejected" >&2
    return 1
  fi
}

test_missing_local_image_is_built() {
  reset_fixture
  BUILD_LOCAL_IMAGE="yes"
  IMAGE="tg-mtproxy:local"

  prepare_images >/dev/null

  assert_pull_count 0
  assert_build_count 1
  grep -Fq "MTPROXY_COMMIT=${MTPROXY_COMMIT}" "$TEST_BUILD_LOG_FILE"
}

test_cached_local_image_skips_build() {
  reset_fixture
  BUILD_LOCAL_IMAGE="yes"
  IMAGE="tg-mtproxy:local"
  AVAILABLE_IMAGES="$IMAGE"

  prepare_images >/dev/null

  assert_build_count 0
}

test_transient_failure_honors_retry_count() {
  reset_fixture
  PULL_RETRIES=2
  PULL_EXIT_CODE=1
  PULL_OUTPUT="429 Too Many Requests"

  if ensure_image "$IMAGE" >/dev/null 2>&1; then
    echo "Expected image preflight to fail" >&2
    return 1
  fi

  assert_pull_count 3
}

test_never_policy_requires_cached_image() {
  reset_fixture
  PULL_POLICY="never"

  if ensure_image "$IMAGE" >/dev/null 2>&1; then
    echo "Expected never policy to reject a missing image" >&2
    return 1
  fi

  assert_pull_count 0
}

test_load_balancer_image_is_preflighted_when_enabled() {
  reset_fixture
  ENABLE_LB="yes"

  prepare_images >/dev/null

  assert_pull_count 2
  assert_pulled_image "$IMAGE"
  assert_pulled_image "$LB_IMAGE"
}

test_local_load_balancer_image_is_built() {
  reset_fixture
  BUILD_LOCAL_IMAGE="yes"
  BUILD_LOCAL_LB_IMAGE="yes"
  IMAGE="tg-mtproxy:local"
  LB_IMAGE="tg-mtproxy-nginx:local"
  ENABLE_LB="yes"

  prepare_images >/dev/null

  assert_pull_count 0
  assert_build_count 2
  grep -Fq "nginx.Dockerfile" "$TEST_BUILD_LOG_FILE"
}

test_proxy_image_failure_stops_load_balancer_preflight() {
  reset_fixture
  ENABLE_LB="yes"
  PULL_RETRIES=0
  PULL_EXIT_CODE=1
  PULL_OUTPUT="unauthorized"

  if prepare_images >/dev/null 2>&1; then
    echo "Expected proxy image preflight to fail" >&2
    return 1
  fi

  assert_pull_count 1
  assert_pulled_image "$IMAGE"

  if grep -Fqx "$LB_IMAGE" "$TEST_LOG_FILE"; then
    echo "Load balancer image was checked after proxy image failure" >&2
    return 1
  fi
}

test_failed_preflight_does_not_prune_containers() {
  reset_fixture
  local prune_marker="${TEST_TMP_DIR}/pruned"

  prepare_system() { :; }
  prepare_images() { return 1; }
  prepare_files() { :; }
  load_secret() { :; }
  prune_previous_proxies() { touch "$prune_marker"; }
  prune_previous_lb() { touch "$prune_marker"; }
  deploy_from_port_range() { :; }
  start_lb() { :; }
  install_refresh_cron() { :; }
  print_result() { :; }

  if main --port-range 30000-30009 --enable-lb no >/dev/null 2>&1; then
    echo "Expected main to stop after image preflight failure" >&2
    return 1
  fi

  if [[ -e "$prune_marker" ]]; then
    echo "Container pruning ran after image preflight failure" >&2
    return 1
  fi
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

run_test "cached image skips pull" test_cached_image_skips_pull
run_test "public IPv4 validation" test_public_ipv4_validation
run_test "missing local image is built" test_missing_local_image_is_built
run_test "cached local image skips build" test_cached_local_image_skips_build
run_test "transient failure honors retry count" test_transient_failure_honors_retry_count
run_test "never policy requires cached image" test_never_policy_requires_cached_image
run_test "load balancer image is preflighted" test_load_balancer_image_is_preflighted_when_enabled
run_test "local load balancer image is built" test_local_load_balancer_image_is_built
run_test "proxy image failure stops load balancer preflight" test_proxy_image_failure_stops_load_balancer_preflight
run_test "failed preflight does not prune containers" test_failed_preflight_does_not_prune_containers
