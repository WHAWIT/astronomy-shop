#!/usr/bin/env bash
# Runs ON THE VM. Reports the currently deployed commit to Whawit as a change
# event (GitHub-shaped deployment_status, the same payload acme-orders sends),
# so the incident timeline shows what shipped. The webhook URL carries its auth
# token: it is read from Secret Manager at call time and never logged.
#   change-event.sh [description]
set -euo pipefail
cd "$(dirname "$0")/.."
GCP_PROJECT=whawit
SECRET=whawit-otel-demo-change-webhook-url
REPO=WHAWIT/astronomy-shop
MD=http://metadata.google.internal/computeMetadata/v1
TOKEN=$(curl -sf -H "Metadata-Flavor: Google" "$MD/instance/service-accounts/default/token" | jq -r .access_token)
URL=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "https://secretmanager.googleapis.com/v1/projects/$GCP_PROJECT/secrets/$SECRET/versions/latest:access" \
  | jq -r .payload.data | base64 -d)
[ -n "$URL" ] || { echo "no change webhook url"; exit 1; }
SHA=$(git rev-parse HEAD)
SUBJECT=$(git log -1 --pretty=%s)
DESC=${1:-"astronomy-shop deploy: $SUBJECT"}
NOW=$(date -u +%FT%TZ)
BODY=$(jq -n --arg sha "$SHA" --arg desc "$DESC" --arg now "$NOW" --arg repo "$REPO" --argjson id "$(date +%s)" '{
  __event: "deployment_status",
  deployment: { id: $id, sha: $sha, ref: "main", environment: "production", task: "deploy", description: $desc, created_at: $now },
  deployment_status: { state: "success", environment: "production", created_at: $now, creator: { login: "otel-demo-vm" },
    target_url: ("https://github.com/" + $repo + "/commit/" + $sha), description: $desc },
  repository: { full_name: $repo, html_url: ("https://github.com/" + $repo) } }')
CODE=$(curl -s -o /tmp/change-event.out -w '%{http_code}' -X POST -H 'content-type: application/json' --data "$BODY" "$URL")
echo "change event for ${SHA:0:7} -> HTTP $CODE $(head -c 200 /tmp/change-event.out)"
