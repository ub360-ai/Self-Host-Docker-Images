# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Breaking:** every bind-mount source is now a single complete-path
  variable (no variables embedded inside a path), so Coolify and other
  Compose consumers can parse the file cleanly. `HARBOR_CONFIG_DIR` and
  `HARBOR_SECRET_DIR` were removed in favor of per-file variables
  (`HARBOR_PORTAL_CONFIG`, `HARBOR_ROUTER_CONFIG`, `HARBOR_REGISTRY_CONFIG`,
  `HARBOR_REGISTRYCTL_CONFIG`, `HARBOR_JOBSERVICE_TEMPLATE`,
  `HARBOR_CORE_PRIVATE_KEY`, `HARBOR_CORE_SECRET_KEY`,
  `HARBOR_REGISTRY_PASSWD`, `HARBOR_JOBSERVICE_CONFIG`), and the data
  directories are now complete paths (`HARBOR_DB_DATA_DIR`,
  `HARBOR_REDIS_DATA_DIR`, `HARBOR_REGISTRY_DATA_DIR`, `HARBOR_JOB_LOGS_DIR`,
  `HARBOR_CA_DOWNLOAD_DIR`).
- `_REDIS_URL_CORE` is now supplied through the generated `REDIS_URL`
  variable instead of being composed from `REDIS_PASSWORD` in the compose
  file.

## [1.0.0] - 2026-09-20

### Added

- Hardened Harbor v2.15.2 stack on Docker Compose: `harbor-db` (PostgreSQL),
  `harbor-redis` (Valkey), `harbor-portal`, `harbor-core`, `registry`,
  `registryctl` and `harbor-jobservice`.
- `harbor-router` internal ingress that fans out `/` to the portal and
  `/api`, `/c`, `/service`, `/v2` to core, with correct `X-Forwarded-Proto`
  and `Host` handling for TLS-terminating proxies.
- `scripts/gen-secrets.sh` bootstrap: generates all credentials, the RSA-4096
  token-signing key, the 16-character encryption key, the registry htpasswd
  file and the rendered jobservice config, then fixes directory ownership.
- Fully externalized configuration: no secrets in the compose file, every
  value injected through `${VAR:?}` fail-fast environment variables.
- Env-configurable resource limits (`cpus`, `memory`, `pids` plus
  reservations) for every service.
- Env-configurable volume paths: `HARBOR_DATA_DIR` / `HARBOR_CONFIG_DIR`
  roots with optional per-service overrides.
- Password-protected Redis with a memory cap and LRU eviction.
- Network segmentation via a single configurable bridge network; no ports are
  published by default.
- Health checks and health-gated startup ordering, `no-new-privileges`,
  json-file log rotation.
- Local development ingress: `docker-compose.override.yml.example` publishes
  the router on `127.0.0.1:8080` only.
- Documentation: README with architecture, quick starts, configuration
  reference, operations and troubleshooting; SECURITY.md; Makefile shortcuts.

[1.0.0]: https://github.com/ub360-ai/Self-Host-Docker-Images/releases/tag/v1.0.0
