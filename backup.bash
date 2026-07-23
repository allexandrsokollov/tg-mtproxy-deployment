#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-${SCRIPT_DIR}/script.bash}"
WORKDIR="${WORKDIR:-$HOME/mtproxy}"
if [[ -n "${BACKUP_DIR:-}" ]]; then
  BACKUP_DIR_EXPLICIT="yes"
else
  BACKUP_DIR="${WORKDIR}-backups"
  BACKUP_DIR_EXPLICIT="no"
fi
STATE_FILE_NAME="deployment.env"
BACKUP_ROOT_NAME="mtproxy-backup"

log() {
  echo "[*] $*"
}

err() {
  echo "[!] $*" >&2
}

usage() {
  cat <<EOF
Usage:
  $0 backup [--workdir PATH] [--backup-dir PATH]
  $0 restore ARCHIVE [--workdir PATH] [--force] [--redeploy]
  $0 redeploy [--workdir PATH]

Commands:
  backup      Save secrets, Telegram runtime files, LB config, and deployment settings.
  restore     Restore a backup. Add --redeploy to immediately recreate the deployment.
  redeploy    Recreate the deployment from an existing work directory.

Defaults:
  Work directory: $WORKDIR
  Backup directory: $BACKUP_DIR

Backups contain credentials. Directories are mode 0700 and archives are mode 0600.
Copy archives off-machine only through an encrypted transport or encrypted storage.
EOF
}

validate_state_value() {
  local key="$1"
  local value="$2"

  case "$key" in
    FORMAT_VERSION)
      [[ "$value" == "1" ]]
      ;;
    PORT_RANGE)
      [[ "$value" =~ ^[0-9]+-[0-9]+$ ]]
      ;;
    PUBLIC_IP)
      [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
      ;;
    LB_PORT|PULL_RETRIES|PULL_RETRY_DELAY)
      [[ "$value" =~ ^[0-9]+$ ]]
      ;;
    NAME_PREFIX|LB_NAME)
      [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]
      ;;
    IMAGE|LB_IMAGE)
      [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$ ]]
      ;;
    BUILD_LOCAL_IMAGE|BUILD_LOCAL_LB_IMAGE|USE_DD_SECRET|ENABLE_LB)
      [[ "$value" == "yes" || "$value" == "no" ]]
      ;;
    MTPROXY_COMMIT)
      [[ "$value" =~ ^[0-9a-fA-F]{40}$ ]]
      ;;
    MTPROXY_PLATFORM)
      [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./-]*$ ]]
      ;;
    PULL_POLICY)
      [[ "$value" == "missing" || "$value" == "always" || "$value" == "never" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

load_state() {
  local state_file="$1"
  local line key value
  local expected_keys=(
    FORMAT_VERSION
    PORT_RANGE
    PUBLIC_IP
    LB_PORT
    NAME_PREFIX
    IMAGE
    BUILD_LOCAL_IMAGE
    MTPROXY_COMMIT
    MTPROXY_PLATFORM
    LB_NAME
    LB_IMAGE
    BUILD_LOCAL_LB_IMAGE
    PULL_POLICY
    PULL_RETRIES
    PULL_RETRY_DELAY
    USE_DD_SECRET
    ENABLE_LB
  )
  local seen_keys=" "

  if [[ ! -r "$state_file" ]]; then
    err "Deployment settings are missing or unreadable: $state_file"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ ! "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
      err "Invalid line in deployment settings: $state_file"
      return 1
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    if [[ "$seen_keys" == *" ${key} "* ]] || ! validate_state_value "$key" "$value"; then
      err "Invalid or duplicate deployment setting: $key"
      return 1
    fi

    seen_keys+="${key} "
    printf -v "$key" '%s' "$value"
  done < "$state_file"

  for key in "${expected_keys[@]}"; do
    if [[ "$seen_keys" != *" ${key} "* ]]; then
      err "Required deployment setting is missing: $key"
      return 1
    fi
  done
}

validate_secret_file() {
  local secret_file="$1"
  local secret

  if [[ ! -r "$secret_file" ]]; then
    err "MTProxy secret is missing or unreadable: $secret_file"
    return 1
  fi

  secret="$(tr -d '\r\n' < "$secret_file")"
  if [[ ! "$secret" =~ ^[0-9a-fA-F]{32}$ ]]; then
    err "MTProxy secret is invalid: $secret_file"
    return 1
  fi
}

create_backup() {
  local timestamp archive temp_dir staging file
  local required=(
    "$STATE_FILE_NAME"
    mtproxy-secret
    proxy-secret
    proxy-multi.conf
  )
  local optional=(
    nginx.conf
    docker-compose.yml
  )
  local -a files=()

  load_state "${WORKDIR}/${STATE_FILE_NAME}"
  validate_secret_file "${WORKDIR}/mtproxy-secret"
  for file in "${required[@]}"; do
    if [[ ! -f "${WORKDIR}/${file}" || -L "${WORKDIR}/${file}" ]]; then
      err "Required deployment file must be a regular, non-symlink file: ${WORKDIR}/${file}"
      return 1
    fi
    files+=("$file")
  done
  for file in "${optional[@]}"; do
    if [[ -L "${WORKDIR}/${file}" ]]; then
      err "Optional deployment file must not be a symlink: ${WORKDIR}/${file}"
      return 1
    fi
    [[ ! -f "${WORKDIR}/${file}" ]] || files+=("$file")
  done

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  temp_dir="$(mktemp -d "${BACKUP_DIR}/.backup.XXXXXX")"
  staging="${temp_dir}/${BACKUP_ROOT_NAME}"
  mkdir -p "$staging"
  trap 'rm -rf "$temp_dir"; trap - RETURN' RETURN

  printf '1\n' > "${staging}/backup-version"
  for file in "${files[@]}"; do
    cp "${WORKDIR}/${file}" "${staging}/${file}"
  done
  chmod 600 "${staging}"/*

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="${BACKUP_DIR}/mtproxy-${timestamp}-$$.tar.gz"
  tar -C "$temp_dir" -czf "${temp_dir}/archive.tar.gz" "$BACKUP_ROOT_NAME"
  chmod 600 "${temp_dir}/archive.tar.gz"
  mv "${temp_dir}/archive.tar.gz" "$archive"

  log "Backup created: $archive"
  log "Keep this archive private; it contains the MTProxy client secret."
}

validate_archive_members() {
  local archive="$1"
  local member

  while IFS= read -r member; do
    case "$member" in
      "${BACKUP_ROOT_NAME}"|"${BACKUP_ROOT_NAME}/"|"${BACKUP_ROOT_NAME}/backup-version"|"${BACKUP_ROOT_NAME}/${STATE_FILE_NAME}"|"${BACKUP_ROOT_NAME}/mtproxy-secret"|"${BACKUP_ROOT_NAME}/proxy-secret"|"${BACKUP_ROOT_NAME}/proxy-multi.conf"|"${BACKUP_ROOT_NAME}/nginx.conf"|"${BACKUP_ROOT_NAME}/docker-compose.yml")
        ;;
      *)
        err "Backup contains an unexpected path: $member"
        return 1
        ;;
    esac
  done < <(tar -tzf "$archive")
}

restore_backup() {
  local archive="$1"
  local force="$2"
  local temp_dir restored file
  local required=(
    backup-version
    "$STATE_FILE_NAME"
    mtproxy-secret
    proxy-secret
    proxy-multi.conf
  )
  local optional=(
    nginx.conf
    docker-compose.yml
  )

  if [[ ! -r "$archive" || ! -f "$archive" ]]; then
    err "Backup archive is missing or unreadable: $archive"
    return 1
  fi

  validate_archive_members "$archive"
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"; trap - RETURN' RETURN
  tar -C "$temp_dir" -xzf "$archive" --no-same-owner --no-same-permissions
  restored="${temp_dir}/${BACKUP_ROOT_NAME}"

  for file in "${required[@]}"; do
    if [[ ! -f "${restored}/${file}" || -L "${restored}/${file}" ]]; then
      err "Backup is missing required regular file: $file"
      return 1
    fi
  done

  if [[ "$(< "${restored}/backup-version")" != "1" ]]; then
    err "Unsupported backup format"
    return 1
  fi

  load_state "${restored}/${STATE_FILE_NAME}"
  validate_secret_file "${restored}/mtproxy-secret"

  if [[ "$force" != "yes" && -e "${WORKDIR}/${STATE_FILE_NAME}" ]]; then
    err "Deployment already exists in ${WORKDIR}; pass --force to overwrite its saved files"
    return 1
  fi

  mkdir -p "$WORKDIR"
  chmod 700 "$WORKDIR"
  for file in "${required[@]:1}"; do
    install -m 600 "${restored}/${file}" "${WORKDIR}/${file}"
  done
  for file in "${optional[@]}"; do
    if [[ -f "${restored}/${file}" && ! -L "${restored}/${file}" ]]; then
      install -m 600 "${restored}/${file}" "${WORKDIR}/${file}"
    fi
  done

  log "Backup restored to ${WORKDIR}"
}

redeploy() {
  load_state "${WORKDIR}/${STATE_FILE_NAME}"
  validate_secret_file "${WORKDIR}/mtproxy-secret"

  if [[ ! -x "$DEPLOY_SCRIPT" ]]; then
    err "Deployment script is not executable: $DEPLOY_SCRIPT"
    return 1
  fi

  log "Redeploying from settings in ${WORKDIR}/${STATE_FILE_NAME}"
  LB_NAME="$LB_NAME" \
  MTPROXY_PLATFORM="$MTPROXY_PLATFORM" \
  PULL_RETRY_DELAY="$PULL_RETRY_DELAY" \
    "$DEPLOY_SCRIPT" \
      --port-range "$PORT_RANGE" \
      --public-ip "$PUBLIC_IP" \
      --lb-port "$LB_PORT" \
      --prefix "$NAME_PREFIX" \
      --workdir "$WORKDIR" \
      --image "$IMAGE" \
      --build-local-image "$BUILD_LOCAL_IMAGE" \
      --mtproxy-commit "$MTPROXY_COMMIT" \
      --lb-image "$LB_IMAGE" \
      --build-local-lb "$BUILD_LOCAL_LB_IMAGE" \
      --pull-policy "$PULL_POLICY" \
      --pull-retries "$PULL_RETRIES" \
      --dd-secret "$USE_DD_SECRET" \
      --enable-lb "$ENABLE_LB"
}

main() {
  local command="${1:-}"
  local archive=""
  local force="no"
  local run_redeploy="no"
  local workdir_changed="no"

  if [[ -z "$command" || "$command" == "-h" || "$command" == "--help" ]]; then
    usage
    [[ -n "$command" ]] || return 1
    return 0
  fi
  shift

  if [[ "$command" == "restore" ]]; then
    archive="${1:-}"
    if [[ -z "$archive" || "$archive" == --* ]]; then
      err "restore requires a backup archive path"
      usage
      return 1
    fi
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workdir)
        WORKDIR="${2:-}"
        workdir_changed="yes"
        shift 2
        ;;
      --backup-dir)
        BACKUP_DIR="${2:-}"
        BACKUP_DIR_EXPLICIT="yes"
        shift 2
        ;;
      --force)
        force="yes"
        shift
        ;;
      --redeploy)
        run_redeploy="yes"
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        err "Unknown argument: $1"
        usage
        return 1
        ;;
    esac
  done

  if [[ "$workdir_changed" == "yes" && "$BACKUP_DIR_EXPLICIT" != "yes" ]]; then
    BACKUP_DIR="${WORKDIR}-backups"
  fi

  if [[ -z "$WORKDIR" || ( "$command" == "backup" && -z "$BACKUP_DIR" ) ]]; then
    err "Work and backup directory paths must not be empty"
    return 1
  fi

  case "$command" in
    backup)
      create_backup
      ;;
    restore)
      restore_backup "$archive" "$force"
      if [[ "$run_redeploy" == "yes" ]]; then
        redeploy
      fi
      ;;
    redeploy)
      redeploy
      ;;
    *)
      err "Unknown command: $command"
      usage
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
