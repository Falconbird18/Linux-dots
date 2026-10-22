#!/usr/bin/env bash
# Compatibility entry point; both installers use the current checkout.
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec "$REPO_DIR/install.sh" "$@"
