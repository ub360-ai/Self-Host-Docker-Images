#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
# render-coolify-compose.sh — generate docker-compose.coolify.yml.
#
# Coolify's compose parser rejects variables inside volume definitions
# (see coollabsio/coolify#7127), so the Coolify variant uses literal
# absolute bind mounts under /data/harbor instead of the HARBOR_*_VOLUME
# variables used by docker-compose.yml.
#
# Usage:
#   scripts/render-coolify-compose.sh          # write the file
#   scripts/render-coolify-compose.sh --check  # fail if it is out of date
# ════════════════════════════════════════════════════════════════════

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT_DIR}/docker-compose.yml"
OUT="${ROOT_DIR}/docker-compose.coolify.yml"
MODE="${1:-write}"

[ -f "$SRC" ] || { echo "error: missing $SRC" >&2; exit 1; }

# Volume variable -> literal mapping used by the Coolify variant.
declare -A VOLUMES=(
    [HARBOR_DATA_VOLUME]="/data/harbor:/data"
    [HARBOR_DB_VOLUME]="/data/harbor/database:/var/lib/postgresql/data"
    [HARBOR_REDIS_VOLUME]="/data/harbor/redis:/var/lib/redis"
    [HARBOR_REGISTRY_DATA_VOLUME]="/data/harbor/registry:/storage"
    [HARBOR_JOB_LOGS_VOLUME]="/data/harbor/job_logs:/var/log/jobs"
    [HARBOR_CA_DOWNLOAD_VOLUME]="/data/harbor/ca_download:/etc/core/ca"
    [HARBOR_CORE_PRIVATE_KEY_VOLUME]="/data/harbor/secret/core/private_key.pem:/etc/core/private_key.pem:ro"
    [HARBOR_CORE_SECRET_KEY_VOLUME]="/data/harbor/secret/keys/secretkey:/etc/core/key:ro"
    [HARBOR_REGISTRY_PASSWD_VOLUME]="/data/harbor/secret/registry/passwd:/etc/registry/passwd:ro"
    [HARBOR_JOBSERVICE_CONFIG_VOLUME]="/data/harbor/secret/jobservice/config.yml:/etc/jobservice/config.yml:ro"
    [HARBOR_PORTAL_CONFIG_VOLUME]="/data/harbor/config/portal/nginx.conf:/etc/nginx/nginx.conf:ro"
    [HARBOR_ROUTER_CONFIG_VOLUME]="/data/harbor/config/nginx/router.conf:/etc/nginx/conf.d/default.conf:ro"
    [HARBOR_REGISTRY_CONFIG_VOLUME]="/data/harbor/config/registry/config.yml:/etc/registry/config.yml:ro"
    [HARBOR_REGISTRYCTL_CONFIG_VOLUME]="/data/harbor/config/registryctl/config.yml:/etc/registryctl/config.yml:ro"
)

tmp_body="$(mktemp)"
tmp_out="$(mktemp)"
trap 'rm -f "$tmp_body" "$tmp_out"' EXIT

# Drop the leading comment block of the source; the Coolify variant gets
# its own header below.
awk 'BEGIN { skip = 1 } skip && /^#/ { next } skip && /^$/ { next } { skip = 0; print }' \
    "$SRC" > "$tmp_body"

# Replace every HARBOR_*_VOLUME entry with its literal mapping.
for var in "${!VOLUMES[@]}"; do
    sed -i -E "s|^([[:space:]]*- )\"\\\$\{${var}:[?][^}]*\}\"$|\1\"${VOLUMES[$var]}\"|" "$tmp_body"
done

# Every volume entry must now be a literal /data/harbor path.
volume_count="$(grep -c '^[[:space:]]*- "/data/harbor' "$tmp_body" || true)"
if [ "$volume_count" -ne 17 ]; then
    echo "error: expected 17 literal volume entries, found ${volume_count}" >&2
    exit 1
fi
if grep -nE '^[[:space:]]*- "\$\{' "$tmp_body" >&2; then
    echo "error: unresolved variable in a volume entry" >&2
    exit 1
fi

{
    cat <<'HEADER'
# ════════════════════════════════════════════════════════════════════
# COOLIFY VARIANT — generated from docker-compose.yml by
# scripts/render-coolify-compose.sh. Do not edit by hand; run
# `make coolify-compose` after changing the main compose file.
#
# Coolify's compose parser rejects variables inside volume definitions
# (coollabsio/coolify#7127), so every bind mount here is a literal
# absolute path under /data/harbor. Point Coolify's
# "Docker Compose Location" at this file.
#
# One-time server prep:
#   sudo mkdir -p /data/harbor
#   rsync -avz config/ root@<host>:/data/harbor/config/
#   cp .env.production.example .env.production
#   ./scripts/gen-secrets.sh .env.production
# ════════════════════════════════════════════════════════════════════
HEADER
    echo
    cat "$tmp_body"
} > "$tmp_out"

if [ "$MODE" = "--check" ]; then
    if [ -f "$OUT" ] && diff -q "$OUT" "$tmp_out" >/dev/null; then
        echo "docker-compose.coolify.yml is up to date"
    else
        echo "error: docker-compose.coolify.yml is out of date (run: make coolify-compose)" >&2
        exit 1
    fi
else
    install -m 644 "$tmp_out" "$OUT"
    echo "wrote ${OUT#"$ROOT_DIR"/}"
fi
