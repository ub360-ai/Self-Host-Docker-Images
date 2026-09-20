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
#   5. creates every runtime directory at the complete paths configured
#      by the HARBOR_* path variables and fixes ownership
#      (harbor=10000:10000, postgres/valkey=999:999).
#
# Every path variable holds a complete path; nothing is composed at
# runtime. Missing variables fall back to the conventional ./data and
# ./config layout.
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

# Read a complete-path variable; blank/unset falls back to $2.
read_path() {
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
    REDIS_URL_VALUE="redis://:${REDIS_PASSWORD}@harbor-redis:6379/0"
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
        -e "s|__GENERATED_REDIS_URL__|${REDIS_URL_VALUE}|g" \
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

DATA_DIR="$(resolve_path "$DATA_DIR_RAW")"
DB_DATA_DIR="$(read_path HARBOR_DB_DATA_DIR "${DATA_DIR_RAW}/database")"
REDIS_DATA_DIR="$(read_path HARBOR_REDIS_DATA_DIR "${DATA_DIR_RAW}/redis")"
REGISTRY_DATA_DIR="$(read_path HARBOR_REGISTRY_DATA_DIR "${DATA_DIR_RAW}/registry")"
JOB_LOGS_DIR="$(read_path HARBOR_JOB_LOGS_DIR "${DATA_DIR_RAW}/job_logs")"
CA_DOWNLOAD_DIR="$(read_path HARBOR_CA_DOWNLOAD_DIR "${DATA_DIR_RAW}/ca_download")"
CORE_PRIVATE_KEY="$(read_path HARBOR_CORE_PRIVATE_KEY "${DATA_DIR_RAW}/secret/core/private_key.pem")"
CORE_SECRET_KEY="$(read_path HARBOR_CORE_SECRET_KEY "${DATA_DIR_RAW}/secret/keys/secretkey")"
REGISTRY_PASSWD="$(read_path HARBOR_REGISTRY_PASSWD "${DATA_DIR_RAW}/secret/registry/passwd")"
JOB_CONFIG="$(read_path HARBOR_JOBSERVICE_CONFIG "${DATA_DIR_RAW}/secret/jobservice/config.yml")"
JOB_TEMPLATE="$(read_path HARBOR_JOBSERVICE_TEMPLATE './config/jobservice/config.yml.tmpl')"

# Redis URL used verbatim by harbor-core and the jobservice config.
REDIS_URL_VALUE="$(read_env REDIS_URL || true)"
if [ -z "$REDIS_URL_VALUE" ]; then
    REDIS_URL_VALUE="redis://:${REDIS_PASSWORD}@harbor-redis:6379/0"
fi
redis_url_pw="$(printf '%s' "$REDIS_URL_VALUE" | sed -n 's|^redis://[^:]*:\([^@]*\)@.*|\1|p')"
if [ -n "$redis_url_pw" ] && [ "$redis_url_pw" != "$REDIS_PASSWORD" ]; then
    printf 'WARNING: REDIS_URL password does not match REDIS_PASSWORD in %s\n' "$ENV_FILE" >&2
fi

# ── 3. key material ─────────────────────────────────────────────────
mkdir -p "$(dirname "$CORE_PRIVATE_KEY")" "$(dirname "$CORE_SECRET_KEY")" \
         "$(dirname "$REGISTRY_PASSWD")" "$(dirname "$JOB_CONFIG")" \
    || die "cannot create secret directories (pre-create them or run as root)"

if [ ! -f "$CORE_PRIVATE_KEY" ] || [ "$FORCE" -eq 1 ]; then
    info "Generating core token signing key (RSA 4096)"
    rm -f "$CORE_PRIVATE_KEY"
    if ! openssl genrsa -traditional -out "$CORE_PRIVATE_KEY" 4096 2>/dev/null; then
        openssl genrsa -out "$CORE_PRIVATE_KEY" 4096
    fi
fi

if [ ! -f "$CORE_SECRET_KEY" ] || [ "$FORCE" -eq 1 ]; then
    info "Generating core encryption key"
    # Harbor requires exactly 16 characters
    rm -f "$CORE_SECRET_KEY"
    openssl rand -base64 12 | tr -d '\n' > "$CORE_SECRET_KEY"
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
write_passwd "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD" "$REGISTRY_PASSWD"

# ── 5. jobservice config (embeds the authenticated Redis URL) ───────
[ -f "$JOB_TEMPLATE" ] || die "missing template: $JOB_TEMPLATE"
info "Rendering jobservice config"
job_tmp="$(mktemp)"
sed "s|__REDIS_URL__|${REDIS_URL_VALUE}|g" "$JOB_TEMPLATE" > "$job_tmp"
rm -f "$JOB_CONFIG"
mv "$job_tmp" "$JOB_CONFIG"

# ── 6. runtime directories + ownership ──────────────────────────────
mkdir -p "$DATA_DIR" "$DB_DATA_DIR" "$REDIS_DATA_DIR" "$REGISTRY_DATA_DIR" \
         "$JOB_LOGS_DIR" "$CA_DOWNLOAD_DIR" \
    || die "cannot create data directories (pre-create them or run as root)"

# Unique parent directories of the generated secret files.
secret_parents=()
for f in "$CORE_PRIVATE_KEY" "$CORE_SECRET_KEY" "$REGISTRY_PASSWD" "$JOB_CONFIG"; do
    d="$(dirname "$f")"
    found=0
    for existing in "${secret_parents[@]:-}"; do
        [ "$existing" = "$d" ] && found=1 && break
    done
    [ "$found" -eq 0 ] && secret_parents+=("$d")
done

# Secret directories stay owned by the deploy user (mode 711, traversable
# but not listable by containers) so this script can be re-run without
# root. Secret files are owned by harbor (10000:10000, mode 600).
fix_ownership() {
    if [ "$(id -u)" -eq 0 ]; then
        chown 10000:10000 "$DATA_DIR"; chmod 755 "$DATA_DIR"
        chown -R 999:999 "$DB_DATA_DIR" "$REDIS_DATA_DIR"
        chmod 700 "$DB_DATA_DIR" "$REDIS_DATA_DIR"
        chown -R 10000:10000 "$REGISTRY_DATA_DIR" "$JOB_LOGS_DIR" "$CA_DOWNLOAD_DIR"
        chmod 700 "$REGISTRY_DATA_DIR" "$JOB_LOGS_DIR" "$CA_DOWNLOAD_DIR"
        for d in "${secret_parents[@]}"; do
            find "$d" -type d -exec chown "$(id -u):$(id -g)" {} + \
                -exec chmod 711 {} +
            find "$d" -type f -exec chown 10000:10000 {} + \
                -exec chmod 600 {} +
        done
    elif command -v docker >/dev/null 2>&1; then
        docker_args=(
            -v "$DATA_DIR:/data_root"
            -v "$DB_DATA_DIR:/db"
            -v "$REDIS_DATA_DIR:/redis"
            -v "$REGISTRY_DATA_DIR:/registry"
            -v "$JOB_LOGS_DIR:/job_logs"
            -v "$CA_DOWNLOAD_DIR:/ca"
        )
        secret_targets=""
        i=0
        for d in "${secret_parents[@]}"; do
            i=$((i + 1))
            docker_args+=(-v "$d:/secret$i")
            secret_targets="$secret_targets /secret$i"
        done
        docker run --rm \
            -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
            -e SECRET_TARGETS="$secret_targets" \
            "${docker_args[@]}" \
            alpine:3 sh -c '
                set -e
                chown 10000:10000 /data_root; chmod 755 /data_root
                chown -R 999:999 /db /redis
                chmod 700 /db /redis
                chown -R 10000:10000 /registry /job_logs /ca
                chmod 700 /registry /job_logs /ca
                for d in $SECRET_TARGETS; do
                    find "$d" -type d -exec chown "$HOST_UID:$HOST_GID" {} + \
                        -exec chmod 711 {} +
                    find "$d" -type f -exec chown 10000:10000 {} + \
                        -exec chmod 600 {} +
                done
            '
    else
        printf 'WARNING: cannot fix data ownership (need root or docker).\n' >&2
        printf '         Run: sudo chown -R 999:999 %s %s\n' "$DB_DATA_DIR" "$REDIS_DATA_DIR" >&2
        printf '              sudo chown -R 10000:10000 %s %s %s\n' \
            "$REGISTRY_DATA_DIR" "$JOB_LOGS_DIR" "$CA_DOWNLOAD_DIR" >&2
        printf '              sudo find <secret-dirs> -type f -exec chown 10000:10000 {} + -exec chmod 600 {} +\n' >&2
        return 0
    fi
}
fix_ownership

printf '\nDone.\n'
printf '  env file        : %s (mode 600)\n' "${ENV_FILE#"$ROOT_DIR"/}"
printf '  data root       : %s\n' "$DATA_DIR"
printf '  secret files    : %s\n' "$(printf '%s ' "${secret_parents[@]}")"
printf '  jobservice cfg  : %s\n' "$JOB_CONFIG"
printf '\nStart the stack with:\n  docker compose --env-file %s up -d\n\n' "${ENV_FILE#"$ROOT_DIR"/}"
