#!/usr/bin/env bash
# Example launcher for parameter mode.
# The collector still requests the Prism Central password securely.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR="${SCRIPT_DIR}/nutanix_category_vm_write_stats_v1.4.1.sh"

: "${PRISM_CENTRAL_HOST:?Set PRISM_CENTRAL_HOST before running}"
: "${PRISM_CENTRAL_USER:?Set PRISM_CENTRAL_USER before running}"
: "${VM_CATEGORY:?Set VM_CATEGORY, for example DR=Critical}"

exec "$COLLECTOR" \
  --host "$PRISM_CENTRAL_HOST" \
  --port "${PRISM_CENTRAL_PORT:-9440}" \
  --categories-api-version "${CATEGORIES_API_VERSION:-v4.4}" \
  --vmm-api-version "${VMM_API_VERSION:-v4.3}" \
  --user "$PRISM_CENTRAL_USER" \
  --category "$VM_CATEGORY" \
  --match-mode "${MATCH_MODE:-OR}" \
  --lookback "${LOOKBACK:-24h}" \
  --sampling-interval "${SAMPLING_INTERVAL:-300}" \
  --capacity-aggregation "${CAPACITY_AGGREGATION:-PEAK}" \
  --calculate-cost "${CALCULATE_COST:-yes}" \
  --price-per-gb "${PRICE_PER_GB:-0.009}" \
  --volume-windows "${VOLUME_WINDOWS:-1h,24h,7d}" \
  --csv-format "${CSV_FORMAT:-auto}" \
  --verify-tls "${VERIFY_TLS:-yes}" \
  --confirm-read-only
