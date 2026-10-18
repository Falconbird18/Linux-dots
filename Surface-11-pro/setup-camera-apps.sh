#!/usr/bin/env bash
# Compatibility entry point: the app-specific Discord experiment is retired.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/setup-system-cameras.sh" "${@:-check}"
