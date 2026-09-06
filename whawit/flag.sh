#!/usr/bin/env bash
# Runs ON THE VM. Flips flagd feature flags by editing src/flagd/demo.flagd.json;
# flagd watches the file, so changes apply within seconds and need no restart.
#
#   flag.sh list                 every flag, its current variant, its variants
#   flag.sh status               flags that are not "off"
#   flag.sh on <flag> [variant]  variant defaults to "on"; percentage flags need one (e.g. 25%)
#   flag.sh off <flag>
#   flag.sh reset                back to the committed file (everything off)
set -euo pipefail
cd "$(dirname "$0")/.."
F=src/flagd/demo.flagd.json
set_variant() {
  local flag=$1 variant=$2
  if ! jq -e --arg f "$flag" '.flags[$f] != null' "$F" >/dev/null; then echo "unknown flag: $flag"; exit 1; fi
  if ! jq -e --arg f "$flag" --arg v "$variant" '.flags[$f].variants[$v] != null' "$F" >/dev/null; then
    echo "variant '$variant' not defined for $flag; variants: $(jq -r --arg f "$flag" '.flags[$f].variants | keys | join(", ")' "$F")"; exit 1
  fi
  jq --arg f "$flag" --arg v "$variant" '.flags[$f].defaultVariant = $v' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
  echo "$flag=$variant"
}
case "${1:-}" in
  list) jq -r '.flags | to_entries[] | "\(.key)\t\(.value.defaultVariant)\t[\(.value.variants|keys|join(","))]\t\(.value.description)"' "$F" | column -t -s $'\t' ;;
  status) jq -r '.flags | to_entries[] | select(.value.defaultVariant != "off") | "\(.key)=\(.value.defaultVariant)"' "$F" ;;
  on) [ -n "${2:-}" ] || { echo "usage: flag.sh on <flag> [variant]"; exit 2; }; set_variant "$2" "${3:-on}" ;;
  off) [ -n "${2:-}" ] || { echo "usage: flag.sh off <flag>"; exit 2; }; set_variant "$2" off ;;
  reset) git checkout -- "$F"; echo "all flags off" ;;
  *) sed -n 2,10p "$0"; exit 2 ;;
esac
