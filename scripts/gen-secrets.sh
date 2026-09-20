#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════
# gen-secrets.sh — bootstrap Harbor secrets and key material.
#
# Usage:
#   scripts/gen-secrets.sh [env-file] [--force]
#
# Defaults to ./.env. The script:
#   1. replaces every __GENERATED_*__ placeholder in the env file with a
#      strong random secret (env file becomes mode 600),
#   2. renders the secret-bearing jobservice config,
#   3. generates the registry htpasswd file,
#   4. generates the core token-signing key and encryption key,
#   5. creates every runtime directory at the paths configured by
#      HARBOR_DATA_DIR / HARBOR_CONFIG_DIR / the per-service overrides
#      and fixes ownership (harbor=10000:10000, postgres/valkey=999:999).
#
# Existing secrets and key material are NEVER overwritten unless --force
# is passed. Re-running is safe and only refreshes derived files.
# ════════════════════════════════════════════════════════════════════

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-${ROOT_DIR}/.env}"
FORCE=0
[ "${2:-}" = "--force" ] && FORCE=1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }

command -v openssl >/dev/null 2>&1 || die "openssl is required"

[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"
case "$ENV_FILE" in
    *.example) die "refusing to write secrets into an example file: $ENV_FILE" ;;
esac

read_env() {
    local key="$1" line
    line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)"
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}

# Resolve a possibly-relative path from the env file against the repo root.
resolve_path() {
    local raw="$1"
    case "$raw" in
        /*) printf '%s' "$raw" ;;
        ./*) printf '%s' "${ROOT_DIR}/${raw#./}" ;;
        *) printf '%s' "${ROOT_DIR}/${raw}" ;;
    esac
}

# Read an optional directory override; blank/unset falls back to $2.
read_dir() {
    local key="$1" fallback="$2" raw
    raw="$(read_env "$key" || true)"
    [ -n "$raw" ] || raw="$fallback"
    resolve_path "$raw"
}

gen_b64() { openssl rand -base64 "$1" | tr -d '\n'; }
gen_hex() { openssl rand -hex "$1" | tr -d '\n'; }

# ── 1. env file secrets ─────────────────────────────────────────────
if grep -qE '^[A-Z0-9_]+=__GENERATED_' "$ENV_FILE"; then
    info "Generating secrets for ${ENV_FILE#"$ROOT_DIR"/}"
    POSTGRES_PASSWORD="$(gen_b64 36)"
    REDIS_PASSWORD="$(gen_hex 32)"
    HARBOR_ADMIN_PASSWORD="Aa1!$(gen_hex 20)"
    CORE_SECRET="$(gen_b64 36)"
    JOBSERVICE_SECRET="$(gen_b64 36)"
    CSRF_KEY="$(gen_hex 16)"
    REGISTRY_PASSWORD="$(gen_hex 32)"
    REGISTRY_HTTP_SECRET="$(gen_b64 36)"
    REGISTRY_USERNAME="$(read_env REGISTRY_USERNAME || printf 'registry')"

    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    sed \
        -e "s|__GENERATED_POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|g" \
        -e "s|__GENERATED_REDIS_PASSWORD__|${REDIS_PASSWORD}|g" \
        -e "s|__GENERATED_ADMIN_PASSWORD__|${HARBOR_ADMIN_PASSWORD}|g" \
        -e "s|__GENERATED_CORE_SECRET__|${CORE_SECRET}|g" \
        -e "s|__GENERATED_JOBSERVICE_SECRET__|${JOBSERVICE_SECRET}|g" \
        -e "s|__GENERATED_CSRF_KEY__|${CSRF_KEY}|g" \
        -e "s|__GENERATED_REGISTRY_PASSWORD__|${REGISTRY_PASSWORD}|g" \
        -e "s|__GENERATED_REGISTRY_HTTP_SECRET__|${REGISTRY_HTTP_SECRET}|g" \
        "$ENV_FILE" > "$tmp"
    install -m 600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
    trap - EXIT
else
    info "No placeholders found — reusing secrets from ${ENV_FILE#"$ROOT_DIR"/}"
    REDIS_PASSWORD="$(read_env REDIS_PASSWORD)" \
        || die "REDIS_PASSWORD is missing from $ENV_FILE"
    REGISTRY_USERNAME="$(read_env REGISTRY_USERNAME || printf 'registry')"
    REGISTRY_PASSWORD="$(read_env REGISTRY_PASSWORD)" \
        || die "REGISTRY_PASSWORD is missing from $ENV_FILE"
fi

chmod 600 "$ENV_FILE"

# ── 2. resolve configured paths ─────────────────────────────────────
DATA_DIR_RAW="$(read_env HARBOR_DATA_DIR || true)"
[ -n "$DATA_DIR_RAW" ] || die "HARBOR_DATA_DIR is missing or empty in $ENV_FILE"

CONFIG_DIR_RAW="$(read_env HARBOR_CONFIG_DIR || true)"
[ -n "$CONFIG_DIR_RAW" ] || CONFIG_DIR_RAW='./config'

DATA_DIR="$(resolve_path "$DATA_DIR_RAW")"
CONFIG_DIR="$(resolve_path "$CONFIG_DIR_RAW")"
SECRET_DIR="$(read_dir HARBOR_SECRET_DIR "${DATA_DIR_RAW}/secret")"
DB_DATA_DIR="$(read_dir HARBOR_DB_DATA_DIR "${DATA_DIR_RAW}/database")"
REDIS_DATA_DIR="$(read_dir HARBOR_REDIS_DATA_DIR "${DATA_DIR_RAW}/redis")"
REGISTRY_DATA_DIR="$(read_dir HARBOR_REGISTRY_DATA_DIR "${DATA_DIR_RAW}/registry")"
JOB_LOGS_DIR="$(read_dir HARBOR_JOB_LOGS_DIR "${DATA_DIR_RAW}/job_logs")"
CA_DOWNLOAD_DIR="$(read_dir HARBOR_CA_DOWNLOAD_DIR "${DATA_DIR_RAW}/ca_download")"
JOB_TEMPLATE="${CONFIG_DIR}/jobservice/config.yml.tmpl"
JOB_CONFIG="${SECRET_DIR}/jobservice/config.yml"

# ── 3. key material ─────────────────────────────────────────────────
mkdir -p "${SECRET_DIR}/core" "${SECRET_DIR}/keys" \
         "${SECRET_DIR}/registry" "${SECRET_DIR}/jobservice" \
    || die "cannot create ${SECRET_DIR} (pre-create it or run as root)"

if [ ! -f "${SECRET_DIR}/core/private_key.pem" ] || [ "$FORCE" -eq 1 ]; then
    info "Generating core token signing key (RSA 4096)"
    rm -f "${SECRET_DIR}/core/private_key.pem"
    if ! openssl genrsa -traditional -out "${SECRET_DIR}/core/private_key.pem" 4096 2>/dev/null; then
        openssl genrsa -out "${SECRET_DIR}/core/private_key.pem" 4096
    fi
fi

if [ ! -f "${SECRET_DIR}/keys/secretkey" ] || [ "$FORCE" -eq 1 ]; then
    info "Generating core encryption key"
    # Harbor requires exactly 16 characters
    rm -f "${SECRET_DIR}/keys/secretkey"
    openssl rand -base64 12 | tr -d '\n' > "${SECRET_DIR}/keys/secretkey"
fi

# ── 4. registry htpasswd ────────────────────────────────────────────
write_passwd() {
    local user="$1" pass="$2" out="$3"
    rm -f "$out"
    if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -nbB "$user" "$pass" > "$out"
    elif python3 -c 'import bcrypt' >/dev/null 2>&1; then
        python3 -c '
import bcrypt, sys
print("%s:%s" % (sys.argv[1], bcrypt.hashpw(sys.argv[2].encode(), bcrypt.gensalt(rounds=12)).decode()))
' "$user" "$pass" > "$out"
    elif command -v docker >/dev/null 2>&1; then
        docker run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$pass" > "$out"
    else
        die "need htpasswd, python3+bcrypt or docker to generate the registry password file"
    fi
}

info "Writing registry htpasswd file"
write_passwd "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD" "${SECRET_DIR}/registry/passwd"

# ── 5. jobservice config (embeds the authenticated Redis URL) ───────
[ -f "$JOB_TEMPLATE" ] || die "missing template: $JOB_TEMPLATE"
info "Rendering jobservice config"
job_tmp="$(mktemp)"
sed "s|__REDIS_URL__|redis://:${REDIS_PASSWORD}@harbor-redis:6379/0|g" \
    "$JOB_TEMPLATE" > "$job_tmp"
rm -f "$JOB_CONFIG"
mv "$job_tmp" "$JOB_CONFIG"

# ── 6. runtime directories + ownership ──────────────────────────────
mkdir -p "$DATA_DIR" "$DB_DATA_DIR" "$REDIS_DATA_DIR" "$REGISTRY_DATA_DIR" \
         "$JOB_LOGS_DIR" "$CA_DOWNLOAD_DIR" \
    || die "cannot create data directories (pre-create them or run as root)"

# Directories stay owned by the deploy user (mode 711, traversable but not
# listable by containers) so this script can be re-run without root. Secret
# files are owned by harbor (10000:10000, mode 600).
fix_ownership() {
    if [ "$(id -u)" -eq 0 ]; then
        chown 10000:10000 "$DATA_DIR"; chmod 755 "$DATA_DIR"
        chown -R 999:999 "$DB_DATA_DIR" "$REDIS_DATA_DIR"
        chmod 700 "$DB_DATA_DIR" "$REDIS_DATA_DIR"
        chown -R 10000:10000 "$REGISTRY_DATA_DIR" "$JOB_LOGS_DIR" "$CA_DOWNLOAD_DIR"
        chmod 700 "$REGISTRY_DATA_DIR" "$JOB_LOGS_DIR" "$CA_DOWNLOAD_DIR"
        find "$SECRET_DIR" -type d -exec chown "$(id -u):$(id -g)" {} + \
            -exec chmod 711 {} +
        find "$SECRET_DIR" -type f -exec chown 10000:10000 {} + \
            -exec chmod 600 {} +
    elif command -v docker >/dev/null 2>&1; then
        docker run --rm \
            -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
            -v "$DATA_DIR:/data_root" \
            -v "$DB_DATA_DIR:/db" \
            -v "$REDIS_DATA_DIR:/redis" \
            -v "$REGISTRY_DATA_DIR:/registry" \
            -v "$JOB_LOGS_DIR:/job_logs" \
            -v "$CA_DOWNLOAD_DIR:/ca" \
            -v "$SECRET_DIR:/secret" \
            alpine:3 sh -c '
                set -e
                chown 10000:10000 /data_root; chmod 755 /data_root
                chown -R 999:999 /db /redis
                chmod 700 /db /redis
                chown -R 10000:10000 /registry /job_logs /ca
                chmod 700 /registry /job_logs /ca
                find /secret -type d -exec chown "$HOST_UID:$HOST_GID" {} + \
                    -exec chmod 711 {} +
                find /secret -type f -exec chown 10000:10000 {} + \
                    -exec chmod 600 {} +
            '
    else
        printf 'WARNING: cannot fix data ownership (need root or docker).\n' >&2
        printf '         Run: sudo chown -R 999:999 %s %s\n' "$DB_DATA_DIR" "$REDIS_DATA_DIR" >&2
        printf '              sudo chown -R 10000:10000 %s %s %s\n' \
            "$REGISTRY_DATA_DIR" "$JOB_LOGS_DIR" "$CA_DOWNLOAD_DIR" >&2
        printf '              sudo find %s -type f -exec chown 10000:10000 {} + -exec chmod 600 {} +\n' \
            "$SECRET_DIR" >&2
        return 0
    fi
}
fix_ownership

printf '\nDone.\n'
printf '  env file        : %s (mode 600)\n' "${ENV_FILE#"$ROOT_DIR"/}"
printf '  data root       : %s\n' "$DATA_DIR"
printf '  config root     : %s\n' "$CONFIG_DIR"
printf '  secret dir      : %s (files owned by 10000:10000)\n' "$SECRET_DIR"
printf '  jobservice cfg  : %s\n' "$JOB_CONFIG"
printf '\nStart the stack with:\n  docker compose --env-file %s up -d\n\n' "${ENV_FILE#"$ROOT_DIR"/}"
