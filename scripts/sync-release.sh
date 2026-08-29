#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose_file=${COMPOSE_FILE:-$repo_root/docker-compose.yml}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

for command_name in curl jq sed sort comm base64 mktemp tr; do
  require_command "$command_name"
done

resolve_tags() {
  local image=$1 output_file=$2 token url headers page next
  token=$(curl --fail --silent --show-error --retry 3 \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:multica-ai/${image}:pull" \
    | jq -er '.token')
  url="https://ghcr.io/v2/multica-ai/${image}/tags/list?n=100"
  headers=$(mktemp)
  page=$(mktemp)
  : > "$output_file"

  while [[ -n "$url" ]]; do
    curl --fail --silent --show-error --retry 3 \
      --dump-header "$headers" \
      -H "Authorization: Bearer $token" \
      "$url" > "$page"
    jq -r '.tags[]?' "$page" | sed -nE '/^v[0-9]+\.[0-9]+\.[0-9]+$/p' >> "$output_file"

    next=$(sed -nE 's/^[Ll]ink:[[:space:]]*<([^>]+)>;[[:space:]]*rel="next".*/\1/p' "$headers" | head -n1)
    case "$next" in
      /*) url="https://ghcr.io${next}" ;;
      "") url="" ;;
      *) url="$next" ;;
    esac
  done

  LC_ALL=C sort -u "$output_file" -o "$output_file"
  rm -f "$headers" "$page"
}

read_image_tag() {
  local image=$1
  sed -nE 's#^[[:space:]]*image:[[:space:]]*ghcr.io/multica-ai/'"$image"':(v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$#\1#p' "$compose_file"
}

backend_tags=$(mktemp)
web_tags=$(mktemp)
candidate_compose=$(mktemp)
original_compose=$(mktemp)
rollback_required=false

patch_service() {
  local source_file=$1 compose_base64
  compose_base64=$(base64 < "$source_file" | tr -d '\n')
  jq -n --arg compose "$compose_base64" '{docker_compose_raw:$compose,instant_deploy:false}' \
    | curl --fail --silent --show-error --retry 2 \
        -X PATCH \
        -H "Authorization: Bearer $COOLIFY_TOKEN" \
        -H 'Content-Type: application/json' \
        --data-binary @- \
        "$coolify_api/services/$COOLIFY_SERVICE_UUID" >/dev/null
}

trigger_deploy() {
  jq -n --arg uuid "$COOLIFY_SERVICE_UUID" '{uuid:$uuid,force:false}' \
    | curl --fail --silent --show-error --retry 2 \
        -X POST \
        -H "Authorization: Bearer $COOLIFY_TOKEN" \
        -H 'Content-Type: application/json' \
        --data-binary @- \
        "$coolify_api/deploy" >/dev/null
}

cleanup() {
  local exit_code=$?
  trap - EXIT

  if [[ $exit_code -ne 0 && "$rollback_required" == true ]]; then
    echo "Deployment failed; restoring the previous Compose definition." >&2
    set +e
    patch_service "$original_compose"
    trigger_deploy
    for _ in $(seq 1 30); do
      if curl --fail --silent --show-error --max-time 15 "$MULTICA_API_HEALTH_URL" >/dev/null \
        && curl --fail --silent --show-error --max-time 15 "$MULTICA_WEB_URL" >/dev/null; then
        echo "Rollback health checks passed." >&2
        break
      fi
      sleep 10
    done
    set -e
  fi

  rm -f "$backend_tags" "$web_tags" "$candidate_compose" "$original_compose"
  exit "$exit_code"
}
trap cleanup EXIT

resolve_tags multica-backend "$backend_tags"
resolve_tags multica-web "$web_tags"

latest_tag=$(comm -12 "$backend_tags" "$web_tags" | LC_ALL=C sort -V | tail -n1)
[[ -n "$latest_tag" ]] || {
  echo "No common stable semver tag exists for backend and web." >&2
  exit 1
}

current_backend_tag=$(read_image_tag multica-backend)
current_web_tag=$(read_image_tag multica-web)
[[ -n "$current_backend_tag" && "$current_backend_tag" == "$current_web_tag" ]] || {
  echo "The checked-in backend and web tags must be the same stable version." >&2
  exit 1
}

echo "Current version: $current_backend_tag"
echo "Latest compatible version: $latest_tag"

if [[ "$latest_tag" == "$current_backend_tag" ]]; then
  echo "Multica is already up to date."
  exit 0
fi

highest_tag=$(printf '%s\n%s\n' "$current_backend_tag" "$latest_tag" | LC_ALL=C sort -V | tail -n1)
[[ "$highest_tag" == "$latest_tag" ]] || {
  echo "Refusing to downgrade from $current_backend_tag to $latest_tag." >&2
  exit 1
}

cp "$compose_file" "$original_compose"
sed -E "s#(ghcr.io/multica-ai/multica-backend:)v[0-9]+\\.[0-9]+\\.[0-9]+#\\1${latest_tag}#" "$original_compose" \
  | sed -E "s#(ghcr.io/multica-ai/multica-web:)v[0-9]+\\.[0-9]+\\.[0-9]+#\\1${latest_tag}#" \
  > "$candidate_compose"

[[ $(grep -cF "ghcr.io/multica-ai/multica-backend:${latest_tag}" "$candidate_compose") -eq 1 ]]
[[ $(grep -cF "ghcr.io/multica-ai/multica-web:${latest_tag}" "$candidate_compose") -eq 1 ]]

if [[ "${DRY_RUN:-false}" == true ]]; then
  echo "Dry run: would deploy Multica $latest_tag."
  exit 0
fi

: "${COOLIFY_URL:?COOLIFY_URL is required when an update is available}"
: "${COOLIFY_SERVICE_UUID:?COOLIFY_SERVICE_UUID is required when an update is available}"
: "${COOLIFY_TOKEN:?COOLIFY_TOKEN is required when an update is available}"
: "${MULTICA_WEB_URL:?MULTICA_WEB_URL is required when an update is available}"
: "${MULTICA_API_HEALTH_URL:?MULTICA_API_HEALTH_URL is required when an update is available}"

[[ "$COOLIFY_URL" == https://* ]] || {
  echo "COOLIFY_URL must use HTTPS." >&2
  exit 1
}
[[ "$COOLIFY_SERVICE_UUID" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo "COOLIFY_SERVICE_UUID has an invalid format." >&2
  exit 1
}

coolify_api=${COOLIFY_URL%/}/api/v1
before_started_at=$(curl --fail --silent --show-error --max-time 15 "$MULTICA_API_HEALTH_URL" \
  | jq -r '.started_at // empty')

patch_service "$candidate_compose"
rollback_required=true
trigger_deploy

echo "Waiting for $latest_tag to become healthy."
sleep 10
for attempt in $(seq 1 60); do
  api_health=$(curl --fail --silent --show-error --max-time 15 "$MULTICA_API_HEALTH_URL" 2>/dev/null || true)
  new_started_at=$(jq -r '.started_at // empty' <<< "$api_health" 2>/dev/null || true)
  api_status=$(jq -r '.status // empty' <<< "$api_health" 2>/dev/null || true)

  if [[ "$api_status" == ok && -n "$new_started_at" && "$new_started_at" != "$before_started_at" ]] \
    && curl --fail --silent --show-error --max-time 15 "$MULTICA_WEB_URL" >/dev/null; then
    cp "$candidate_compose" "$compose_file"
    rollback_required=false
    echo "Multica $latest_tag is healthy."
    exit 0
  fi

  echo "Health check attempt $attempt/60 is not ready yet."
  sleep 10
done

echo "Timed out waiting for Multica $latest_tag." >&2
exit 1
