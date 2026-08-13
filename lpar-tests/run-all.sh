#!/bin/bash
# Compatibility wrapper — full MQ suite lives in run_mq_all.sh.
# Help: ./suite-help.sh  or  ./run-all.sh --help
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/run_mq_all.sh" "$@"
