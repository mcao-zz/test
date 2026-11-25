#!/bin/bash
# Compatibility wrapper for run_all.sh (MQ suite, then LEGACY adapters).
# Help: ./run_all.sh --help
#
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
exec "$DIR/run_all.sh" "$@"
