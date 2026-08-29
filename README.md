# Multica Coolify Sync

English | [简体中文](README.zh-CN.md)

Automatically deploy the latest compatible Multica release to a self-hosted Coolify service.

Every six hours, the workflow finds the newest stable semantic version that exists for both `multica-backend` and `multica-web`, updates the Coolify Compose definition, deploys it, and verifies the result. If verification fails, it restores the previous Compose definition and redeploys the last known version.

## How it works

1. Read all available tags from the public GHCR repositories.
2. Select the newest `vX.Y.Z` tag shared by both images.
3. Patch the target Coolify service with the candidate Compose definition.
4. Trigger a deployment and wait for the API process to restart.
5. Verify the API health endpoint and the web application.
6. Commit the deployed image version to `docker-compose.yml` when successful.
7. Restore the previous Compose definition when deployment or verification fails.

## Requirements

- A self-hosted Coolify instance with API access enabled
- A Coolify service created from this repository's `docker-compose.yml`
- A GitHub repository environment named `production`
- `curl`, `jq`, and standard GNU command-line tools on the workflow runner

## GitHub configuration

Add the following values under **Settings → Environments → production**. Deployment-specific URLs and identifiers must be stored in GitHub variables or secrets and must not be committed to the repository.

| Type | Name | Example | Description |
| --- | --- | --- | --- |
| Secret | `COOLIFY_TOKEN` | Not shown | A scoped Coolify API token that can update and deploy only the target service |
| Variable | `COOLIFY_URL` | `https://coolify.example.com` | Base URL of the Coolify instance, without `/api/v1` |
| Variable | `COOLIFY_SERVICE_UUID` | `your-service-uuid` | UUID of the target Coolify service |
| Variable | `MULTICA_WEB_URL` | `https://multica.example.com` | Public web URL used for post-deployment verification |
| Variable | `MULTICA_API_HEALTH_URL` | `https://api.multica.example.com/health` | API health endpoint that returns JSON containing `status` and `started_at` |

The workflow runs automatically every six hours. To run it manually, open **Actions → Sync Multica release to Coolify → Run workflow**.

## Coolify service configuration

1. Create a Docker Compose service in Coolify from `docker-compose.yml`.
2. Configure the application variables in Coolify. Use [`.env.example`](.env.example) as a list of required and optional values.
3. Keep passwords, API keys, database URLs, private endpoints, and deployment domains in Coolify or another secret manager.
4. Confirm that the external Docker network named `coolify` exists on the server.
5. Configure the public web and API domains in Coolify, then set the same public endpoints in the GitHub environment variables above.

Do not copy `.env.example` with real values into Git. Local `.env` files are ignored by `.gitignore`.

## Manual dry run

The script can check the registry and resolve the target version without changing Coolify:

```bash
DRY_RUN=true ./scripts/sync-release.sh
```

Deployment variables are required only when a newer compatible release is available and an actual deployment is requested.

## Security notes

- Use a dedicated, least-privilege Coolify API token.
- Store the token as a GitHub secret, never as a repository variable.
- Store private deployment URLs and service identifiers as GitHub environment variables.
- Protect the `production` environment with appropriate branch restrictions or approvals.
- Review changes to `docker-compose.yml` before using this automation in production.

## Files

- `.github/workflows/sync-multica-release.yml` — scheduled and manual GitHub Actions workflow
- `scripts/sync-release.sh` — version resolution, deployment, verification, and rollback logic
- `docker-compose.yml` — Coolify Compose definition and recorded deployed version
- `.env.example` — generic application configuration template
