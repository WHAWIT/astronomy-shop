#!/usr/bin/env bash
# GCE startup script for the otel-demo VM. Runs as root on every boot (and on
# `whawit/vm.sh deploy`, which re-runs it). Idempotent.
#
#   1. installs docker + make + jq on first boot
#   2. clones or fast-forwards WHAWIT/astronomy-shop into /opt/astronomy-shop
#   3. fetches the Whawit collector api key from Secret Manager (VM service account)
#   4. `make start` — the full demo + observability stack + Whawit exporters
set -euo pipefail

REPO_URL=https://github.com/WHAWIT/astronomy-shop.git
APP_DIR=/opt/astronomy-shop
GCP_PROJECT=whawit
SECRET=whawit-otel-demo-api-key
MD=http://metadata.google.internal/computeMetadata/v1
md() { curl -sf -H "Metadata-Flavor: Google" "$MD/$1"; }
log() { echo "[astronomy-startup] $(date -u +%FT%TZ) $*"; }

BRANCH=$(md instance/attributes/astronomy-branch || echo main)

if ! command -v docker >/dev/null 2>&1; then
  log "installing docker"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git make jq >/dev/null
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
command -v jq >/dev/null 2>&1 || apt-get install -y -qq git make jq >/dev/null

# OpenSearch refuses to start below this.
sysctl -q -w vm.max_map_count=262144
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-astronomy.conf

if [ -d "$APP_DIR/.git" ]; then
  log "updating $APP_DIR to origin/$BRANCH"
  git -C "$APP_DIR" fetch -q origin
  git -C "$APP_DIR" checkout -q "$BRANCH" 2>/dev/null || git -C "$APP_DIR" checkout -q -b "$BRANCH" "origin/$BRANCH"
  git -C "$APP_DIR" reset -q --hard "origin/$BRANCH"
else
  log "cloning $REPO_URL ($BRANCH)"
  git clone -q --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
fi
mkdir -p "$APP_DIR/recordings"
git -C "$APP_DIR" config user.name "otel-demo vm"
git -C "$APP_DIR" config user.email "otel-demo-vm@whawit.iam.gserviceaccount.com"

log "fetching collector api key from Secret Manager"
TOKEN=$(md instance/service-accounts/default/token | jq -r .access_token)
WHAWIT_API_KEY=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "https://secretmanager.googleapis.com/v1/projects/$GCP_PROJECT/secrets/$SECRET/versions/latest:access" \
  | jq -r .payload.data | base64 -d)
[ -n "$WHAWIT_API_KEY" ] || { log "ERROR: empty api key"; exit 1; }
export WHAWIT_API_KEY

log "starting the stack"
cd "$APP_DIR"
make start
log "done: $(docker ps --format '{{.Names}}' | wc -l) containers"
