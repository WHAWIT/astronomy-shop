#!/usr/bin/env bash
# The otel-demo VM (GCP project whawit, us-central1-a). Access is through IAP
# tunnels only: the VM has no inbound rule from the internet.
#
#   whawit/vm.sh create [branch]   e2-standard-4, Debian 12, 80 GB; boots the stack
#   whawit/vm.sh start | stop      stop when not demoing: only the disk is billed
#   whawit/vm.sh status
#   whawit/vm.sh deploy            re-run the startup script (pull branch, make start)
#   whawit/vm.sh ssh [cmd]
#   whawit/vm.sh tunnel [port]     http://localhost:8080 -> store, /grafana, /jaeger/ui, /feature, /loadgen
#   whawit/vm.sh logs [n]          startup-script journal
#   whawit/vm.sh ps                docker ps on the VM
#   whawit/vm.sh delete
set -euo pipefail
PROJECT=whawit
ZONE=us-central1-a
NAME=otel-demo
MACHINE=e2-standard-4
SA=otel-demo-vm@whawit.iam.gserviceaccount.com
HERE=$(cd "$(dirname "$0")" && pwd)
g() { gcloud --project="$PROJECT" "$@"; }
vssh() { g compute ssh "$NAME" --zone="$ZONE" --tunnel-through-iap --quiet -- "$@"; }

case "${1:-}" in
  create)
    g compute instances create "$NAME" --zone="$ZONE" --machine-type="$MACHINE" \
      --image-family=debian-12 --image-project=debian-cloud \
      --boot-disk-size=80GB --boot-disk-type=pd-balanced \
      --service-account="$SA" --scopes=cloud-platform --tags=otel-demo \
      --metadata="astronomy-branch=${2:-main}" \
      --metadata-from-file="startup-script=$HERE/vm/startup.sh" ;;
  start|stop) g compute instances "$1" "$NAME" --zone="$ZONE" ;;
  status) g compute instances describe "$NAME" --zone="$ZONE" \
      --format="value(status,machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP,lastStartTimestamp)" ;;
  deploy) vssh "sudo google_metadata_script_runner startup && sudo /opt/astronomy-shop/whawit/change-event.sh" ;;
  ssh) shift; vssh "$@" ;;
  tunnel) g compute start-iap-tunnel "$NAME" "${2:-8080}" --local-host-port="localhost:${2:-8080}" --zone="$ZONE" ;;
  logs) vssh "sudo journalctl -o cat --no-pager -u google-startup-scripts | tail -n ${2:-80}" ;;
  ps) vssh "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'" ;;
  delete) g compute instances delete "$NAME" --zone="$ZONE" ;;
  *) sed -n 2,14p "$0"; exit 2 ;;
esac
