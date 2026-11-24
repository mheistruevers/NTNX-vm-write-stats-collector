#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT_DIR/nutanix_category_vm_write_stats_v1.4.1.sh"
bash -n "$ROOT_DIR/examples/non-interactive-example.sh"

test -x "$ROOT_DIR/nutanix_category_vm_write_stats_v1.4.1.sh"
test -x "$ROOT_DIR/examples/non-interactive-example.sh"

echo "Shell syntax and executable checks passed."
