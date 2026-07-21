#!/usr/bin/env bash
set -euo pipefail

secret="${SECRET:-}"
workers="${WORKERS:-2}"
external_ip="${EXTERNAL_IP:-}"

if [[ ! "$secret" =~ ^[0-9a-fA-F]{32}$ ]]; then
  echo "[!] SECRET must contain exactly 32 hexadecimal characters" >&2
  exit 1
fi

if [[ ! "$workers" =~ ^[1-9][0-9]*$ ]]; then
  echo "[!] WORKERS must be a positive integer" >&2
  exit 1
fi

if [[ ! -r /data/secret || ! -r /data/proxy-multi.conf ]]; then
  echo "[!] /data/secret and /data/proxy-multi.conf must be readable" >&2
  exit 1
fi

args=(
  -u nobody
  -p 2398
  -H 443
  -M "$workers"
  -C 60000
  -S "$secret"
  --http-stats
  --allow-skip-dh
  --aes-pwd /data/secret
)

if [[ -n "$external_ip" ]]; then
  internal_ip="$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  if [[ -n "$internal_ip" ]]; then
    args+=(--nat-info "${internal_ip}:${external_ip}")
  fi
fi

args+=(/data/proxy-multi.conf)

exec /usr/local/bin/mtproto-proxy "${args[@]}"
