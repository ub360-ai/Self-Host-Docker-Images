# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 1.x     | Yes       |

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Use GitHub's private vulnerability reporting instead:

1. Open the **Security** tab of this repository.
2. Click **Report a vulnerability**.
3. Describe the issue, affected files/versions, and reproduction steps.

We will acknowledge reports as quickly as possible and coordinate a fix and
disclosure timeline with you.

## Secrets policy (read before contributing)

This project is a deployment template, and secrets are handled outside of git
on purpose:

- `.env`, `.env.development`, `.env.production` and `/data/` are **gitignored**.
- `scripts/gen-secrets.sh` generates all credentials, key material and the
  registry htpasswd file on the host that runs the stack.
- `docker-compose.yml` never contains secrets; every secret is injected via
  `${VAR:?}` fail-fast environment variables.

**Never commit** real credentials, private keys, `.env` files, database dumps
or registry data. If you accidentally do, rotate the affected credentials
immediately — assume anything pushed to a public remote is compromised.

## Hardening checklist for deployments

- Terminate TLS at your reverse proxy and set `EXTERNAL_URL`/`PORTAL_URL` to
  the public HTTPS URL.
- Do not publish container ports; only the reverse proxy should join the
  Docker network.
- Keep `HARBOR_DATA_DIR` outside the repository and restrict host access.
- Back up `.env` / key material to a secret manager, not to git.
- Rotate `HARBOR_ADMIN_PASSWORD` after first login if it was shared.
- Review resource limits and log rotation for your host.
