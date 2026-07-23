#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)"
BACKUP_SCRIPT="${PROJECT_DIR}/backup.bash"

TEST_TMP_DIR="$(mktemp -d)"
SOURCE_DIR="${TEST_TMP_DIR}/source"
RESTORE_DIR="${TEST_TMP_DIR}/restore"
BACKUP_DIR="${TEST_TMP_DIR}/backups"
FAKE_DEPLOY="${TEST_TMP_DIR}/fake-deploy.bash"
DEPLOY_LOG="${TEST_TMP_DIR}/deploy.log"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT

write_fixture() {
  mkdir -p "$SOURCE_DIR"
  printf '%s\n' '0123456789abcdef0123456789abcdef' > "${SOURCE_DIR}/mtproxy-secret"
  printf '%s\n' 'telegram-secret' > "${SOURCE_DIR}/proxy-secret"
  printf '%s\n' 'telegram-config' > "${SOURCE_DIR}/proxy-multi.conf"
  printf '%s\n' 'nginx-config' > "${SOURCE_DIR}/nginx.conf"
  printf '%s\n' 'compose-config' > "${SOURCE_DIR}/docker-compose.yml"
  cat > "${SOURCE_DIR}/deployment.env" <<'EOF'
FORMAT_VERSION=1
PORT_RANGE=30000-30009
PUBLIC_IP=203.0.113.10
LB_PORT=8443
NAME_PREFIX=proxy
IMAGE=tg-mtproxy:local
BUILD_LOCAL_IMAGE=yes
MTPROXY_COMMIT=cafc3380a81671579ce366d0594b9a8e450827e9
MTPROXY_PLATFORM=linux/amd64
LB_NAME=mtproxy-lb
LB_IMAGE=tg-mtproxy-nginx:local
BUILD_LOCAL_LB_IMAGE=yes
PULL_POLICY=missing
PULL_RETRIES=3
PULL_RETRY_DELAY=5
USE_DD_SECRET=yes
ENABLE_LB=yes
EOF
  chmod 600 "${SOURCE_DIR}"/*

  cat > "$FAKE_DEPLOY" <<EOF
#!/usr/bin/env bash
{
  printf 'LB_NAME=%s\n' "\$LB_NAME"
  printf 'MTPROXY_PLATFORM=%s\n' "\$MTPROXY_PLATFORM"
  printf 'PULL_RETRY_DELAY=%s\n' "\$PULL_RETRY_DELAY"
  printf 'ARGS='
  printf '<%s>' "\$@"
  printf '\n'
} > "$DEPLOY_LOG"
EOF
  chmod 755 "$FAKE_DEPLOY"
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

run_test() {
  local name="$1"
  shift

  if (set -e; "$@"); then
    echo "ok - ${name}"
  else
    echo "not ok - ${name}" >&2
    return 1
  fi
}

test_backup_restore_and_redeploy() {
  local output archive

  write_fixture
  output="$("$BACKUP_SCRIPT" backup --workdir "$SOURCE_DIR" --backup-dir "$BACKUP_DIR")"
  archive="$(sed -n 's/^\[\*\] Backup created: //p' <<< "$output")"

  [[ -f "$archive" ]]
  [[ "$(file_mode "$BACKUP_DIR")" == "700" ]]
  [[ "$(file_mode "$archive")" == "600" ]]

  "$BACKUP_SCRIPT" restore "$archive" --workdir "$RESTORE_DIR" >/dev/null
  cmp "${SOURCE_DIR}/mtproxy-secret" "${RESTORE_DIR}/mtproxy-secret"
  cmp "${SOURCE_DIR}/deployment.env" "${RESTORE_DIR}/deployment.env"
  cmp "${SOURCE_DIR}/nginx.conf" "${RESTORE_DIR}/nginx.conf"
  [[ "$(file_mode "$RESTORE_DIR")" == "700" ]]
  [[ "$(file_mode "${RESTORE_DIR}/mtproxy-secret")" == "600" ]]

  DEPLOY_SCRIPT="$FAKE_DEPLOY" \
    "$BACKUP_SCRIPT" redeploy --workdir "$RESTORE_DIR" >/dev/null
  grep -Fqx 'LB_NAME=mtproxy-lb' "$DEPLOY_LOG"
  grep -Fqx 'MTPROXY_PLATFORM=linux/amd64' "$DEPLOY_LOG"
  grep -Fqx 'PULL_RETRY_DELAY=5' "$DEPLOY_LOG"
  grep -Fq '<--port-range><30000-30009>' "$DEPLOY_LOG"
  grep -Fq '<--enable-lb><yes>' "$DEPLOY_LOG"
}

test_restore_refuses_to_overwrite_without_force() {
  local output archive

  output="$("$BACKUP_SCRIPT" backup --workdir "$SOURCE_DIR" --backup-dir "$BACKUP_DIR")"
  archive="$(sed -n 's/^\[\*\] Backup created: //p' <<< "$output")"

  if "$BACKUP_SCRIPT" restore "$archive" --workdir "$RESTORE_DIR" >/dev/null 2>&1; then
    echo "Expected restore to refuse an existing deployment" >&2
    return 1
  fi
}

test_backup_rejects_invalid_secret() {
  printf '%s\n' 'not-a-secret' > "${SOURCE_DIR}/mtproxy-secret"

  if "$BACKUP_SCRIPT" backup --workdir "$SOURCE_DIR" --backup-dir "$BACKUP_DIR" >/dev/null 2>&1; then
    echo "Expected backup to reject an invalid secret" >&2
    return 1
  fi
}

run_test "backup, restore, and redeploy round trip" test_backup_restore_and_redeploy
run_test "restore refuses overwrite without force" test_restore_refuses_to_overwrite_without_force
run_test "backup rejects invalid secret" test_backup_rejects_invalid_secret
