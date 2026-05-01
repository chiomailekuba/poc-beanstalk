#!/bin/bash
set -e

echo "NOTICE: deploy-holesky.sh is deprecated. Use deploy-hoodi.sh instead."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/deploy-hoodi.sh"
