#!/usr/bin/env bash
# Drive failure scenarios on the VM from your laptop (wraps whawit/flag.sh over IAP ssh).
#   whawit/scenarios.sh list | status | on <flag> [variant] | off <flag> | reset
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
exec "$HERE/vm.sh" ssh "sudo /opt/astronomy-shop/whawit/flag.sh $*"
