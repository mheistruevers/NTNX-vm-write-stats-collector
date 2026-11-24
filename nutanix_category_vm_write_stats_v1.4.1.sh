#!/usr/bin/env bash
#
# nutanix_category_vm_write_stats.sh
#
# Resolves VMs from Prism Central categories and queries historical AHV VM
# controller write bandwidth using the Nutanix v4 REST API.
#
# Requirements:
#   - bash 4+
#   - curl
#   - jq
#   - awk, sed, sort, date, mktemp
#
# Important:
#   controllerWriteIoBandwidthKbps is a VM/controller write-bandwidth metric.
#   It is a sizing proxy, not a direct Azure VNet-peering or SyncRep byte meter.
#   Data reduction, replication, metadata, retransmissions and protocol overhead
#   are not derived by this script.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.4.0"
WORK_DIR=""
CURL_CONFIG=""
PC_PASS=""
RUN_LOG="/dev/null"
PARAMETER_MODE="no"
DRY_RUN="no"
CONFIRM_READ_ONLY="no"
CATEGORY_ARGUMENTS=()
CATEGORY_SELECTION_OVERRIDE=""
LOOKBACK_OVERRIDE=""
START_OVERRIDE=""
END_OVERRIDE=""
VOLUME_WINDOWS="1h,24h,7d,4w"

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

log_event() {
    local level="$1"
    shift
    printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >> "$RUN_LOG" 2>/dev/null || true
}

on_error() {
    local rc=$?
    log_event ERROR "${SCRIPT_NAME}:${1:-?}: command failed: ${2:-unknown command} (exit ${rc})"
    echo "ERROR: ${SCRIPT_NAME}:${1:-?}: command failed (exit ${rc})" >&2
    [[ "$RUN_LOG" != "/dev/null" ]] && echo "       Detailed diagnostics: ${RUN_LOG}" >&2
    exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

fail() {
    log_event ERROR "$*"
    echo "ERROR: $*" >&2
    [[ "$RUN_LOG" != "/dev/null" ]] && echo "       Detailed diagnostics: ${RUN_LOG}" >&2
    exit 1
}

# ANSI colors are used only for interactive terminal output. Set NO_COLOR=1 to disable them.
if [[ -t 1 || -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_INFO=$'\033[36m'
    C_WARN=$'\033[33m'
    C_OK=$'\033[32m'
    C_PROMPT=$'\033[1;36m'
else
    C_RESET=''
    C_INFO=''
    C_WARN=''
    C_OK=''
    C_PROMPT=''
fi

# Keep progress, API diagnostics and warnings out of the interactive shell.
# They are retained in run.log and referenced in the final concise summary.
warn() {
    log_event WARNING "$*"
}

info() {
    log_event INFO "$*"
    printf '%sINFO:%s %s\n' "$C_INFO" "$C_RESET" "$*" >&2
}

show_help() {
    cat <<EOF_HELP
${SCRIPT_NAME} ${SCRIPT_VERSION}

Resolves VMs from Prism Central categories and calculates VM write-I/O
capacity and sampled volume/cost scenarios.

Modes:
  No configuration arguments: interactive mode.
  With configuration arguments: parameter mode; no configuration prompts.
  The password is always requested with a hidden prompt and is never accepted
  as a command-line argument.

Important:
  This performs read-only API calls against the selected Prism Central. It may
  create API load, especially for many VMs or long time ranges. It does not
  change Prism Central configuration.

Parameter requirements in parameter mode:
  Required:
    --host HOST                         Prism Central FQDN/IP
    --user USER                         Prism Central username
    --category KEY=VALUE                Repeatable; alternatively --categories CSV
    --confirm-read-only                 Required confirmation for read-only API load

  Optional (defaults are used when omitted):
    --port PORT                         default: 9440
    --categories-api-version VERSION    default: v4.4
    --vmm-api-version VERSION           default: v4.3
    --match-mode OR|AND                 default: OR
    --lookback DURATION                 default: 24h
    --start RFC3339 --end RFC3339       alternative to --lookback
    --sampling-interval SECONDS         default: 300
    --capacity-aggregation PEAK|AVG     default: PEAK
    --calculate-cost yes|no             default: yes
    --price-per-gb NUMBER               default: 0.009
    --volume-windows CSV                default: 1h,24h,7d,4w
    --csv-format auto|de|us             default: locale detection
    --output-dir DIRECTORY              default: timestamped directory
    --verify-tls yes|no                 default: yes
    --dry-run                           validate, authenticate and estimate only

  Credentials and special options:
    Password                            Always requested with a hidden prompt;
                                        never accepted as a command-line argument.
    --help                              Show this help and exit.

Time selection:
  Use either --lookback (for example 1h, 24h, 7d or 4w) or --start/--end.
  --start and --end must be supplied together. If none is supplied, 24h is used.

Interactive mode:
  Run without configuration arguments to be prompted for the required and
  optional values. The read-only environment confirmation is then interactive.

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --dry-run --host pc.example --user admin \\
      --category 'DR=Critical' --lookback 24h --confirm-read-only
  ${SCRIPT_NAME} --host pc.example --user admin \\
      --category 'DR=Critical' --start '2026-11-23T00:00:00Z' \\
      --end '2026-11-24T00:00:00Z' --confirm-read-only

Set NO_COLOR=1 to disable terminal colors.
EOF_HELP
}

require_arg() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a value"
}

# Any configuration argument selects parameter mode. --help exits before this
# distinction matters. In parameter mode, the password remains the only prompt.
if (( $# > 0 )); then
    PARAMETER_MODE="yes"
fi

CSV_FORMAT_OVERRIDE="${CSV_FORMAT:-}"
while (( $# > 0 )); do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --host|--prism-host)
            require_arg "$1" "${2:-}"
            PC_HOST="$2"; shift 2
            ;;
        --port)
            require_arg "$1" "${2:-}"
            PC_PORT="$2"; shift 2
            ;;
        --categories-api-version|--prism-api-version)
            require_arg "$1" "${2:-}"
            PRISM_API_VERSION="$2"; shift 2
            ;;
        --vmm-api-version|--stats-api-version)
            require_arg "$1" "${2:-}"
            VMM_API_VERSION="$2"; shift 2
            ;;
        --user|--username)
            require_arg "$1" "${2:-}"
            PC_USER="$2"; shift 2
            ;;
        --category)
            require_arg "$1" "${2:-}"
            CATEGORY_ARGUMENTS+=("$2"); shift 2
            ;;
        --categories|--category-selection)
            require_arg "$1" "${2:-}"
            CATEGORY_SELECTION_OVERRIDE="$2"; shift 2
            ;;
        --match-mode)
            require_arg "$1" "${2:-}"
            MATCH_MODE="$2"; shift 2
            ;;
        --lookback)
            require_arg "$1" "${2:-}"
            LOOKBACK_OVERRIDE="$2"; shift 2
            ;;
        --start)
            require_arg "$1" "${2:-}"
            START_OVERRIDE="$2"; shift 2
            ;;
        --end)
            require_arg "$1" "${2:-}"
            END_OVERRIDE="$2"; shift 2
            ;;
        --sampling-interval)
            require_arg "$1" "${2:-}"
            SAMPLING_INTERVAL="$2"; shift 2
            ;;
        --capacity-aggregation)
            require_arg "$1" "${2:-}"
            CAPACITY_AGGREGATION="$2"; shift 2
            ;;
        --calculate-cost)
            require_arg "$1" "${2:-}"
            CALCULATE_COST="$2"; shift 2
            ;;
        --price-per-gb)
            require_arg "$1" "${2:-}"
            PRICE_PER_GB="$2"; shift 2
            ;;
        --volume-windows)
            require_arg "$1" "${2:-}"
            VOLUME_WINDOWS="$2"; shift 2
            ;;
        --csv-format)
            require_arg "$1" "${2:-}"
            CSV_FORMAT_OVERRIDE="$2"; shift 2
            ;;
        --csv-format=*)
            CSV_FORMAT_OVERRIDE="${1#*=}"; shift
            ;;
        --output-dir)
            require_arg "$1" "${2:-}"
            OUTPUT_DIR="$2"; shift 2
            ;;
        --verify-tls)
            require_arg "$1" "${2:-}"
            VERIFY_TLS="$2"; shift 2
            ;;
        --dry-run)
            DRY_RUN="yes"; shift
            ;;
        --confirm-read-only|--yes)
            CONFIRM_READ_ONLY="yes"; shift
            ;;
        *)
            fail "Unknown argument: $1 (use --help for usage)"
            ;;
    esac
done

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

trim() {
    local value="$1"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    printf '%s' "$value"
}

prompt_default() {
    local prompt="$1"
    local default_value="$2"
    local variable_name="$3"
    local answer
    read -r -p "${C_PROMPT}${prompt}${C_RESET} [${default_value}]: " answer
    printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

prompt_secret() {
    local prompt="$1"
    local variable_name="$2"
    local answer
    if [[ -t 0 ]]; then
        read -r -s -p "${C_PROMPT}${prompt}${C_RESET}: " answer
    elif [[ -r /dev/tty ]]; then
        read -r -s -p "${C_PROMPT}${prompt}${C_RESET}: " answer < /dev/tty
    else
        read -r -s -p "${C_PROMPT}${prompt}${C_RESET}: " answer
    fi
    printf '\n' >&2
    printf -v "$variable_name" '%s' "$answer"
}

prompt_yes_no() {
    local prompt="$1"
    local default_value="${2:-n}"
    local answer
    while true; do
        read -r -p "${C_PROMPT}${prompt} [${default_value}]: ${C_RESET}" answer
        answer="${answer:-$default_value}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) printf 'Please answer y or n.\n' >&2 ;;
        esac
    done
}

parse_duration_seconds() {
    local value="${1,,}"
    local number unit
    [[ "$value" =~ ^([0-9]+)([hdw])$ ]] || return 1
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    (( number >= 1 )) || return 1
    case "$unit" in
        h) printf '%s\n' $(( number * 3600 )) ;;
        d) printf '%s\n' $(( number * 86400 )) ;;
        w) printf '%s\n' $(( number * 604800 )) ;;
    esac
}

format_epoch_utc() {
    local epoch="$1"
    if date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
        return 0
    fi
    date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

detect_csv_format() {
    # German locales use semicolon-separated CSV with comma decimals. All other
    # locales use comma-separated CSV with dot decimals. The result can always
    # be overridden explicitly with --csv-format or CSV_FORMAT.
    local locale="${LC_NUMERIC:-${LC_ALL:-${LANG:-}}}"
    locale="${locale,,}"
    if [[ "$locale" =~ (^|[._-])de([._@-]|$) ]]; then
        printf 'DE\n'
    else
        printf 'US\n'
    fi
}

normalize_decimal_input() {
    local value="$1"
    value="${value//,/.}"
    printf '%s' "$value"
}

localize_number() {
    local value="$1"
    if [[ "$CSV_FORMAT" == "DE" ]]; then
        printf '%s' "${value//./,}"
    else
        printf '%s' "$value"
    fi
}

# Convert RFC3339/ISO-8601 to Unix epoch on GNU/Linux and macOS/BSD.
# GNU date supports -d; BSD date uses -j -f and -v.
iso8601_to_epoch() {
    local value="$1"
    local normalized="$1"
    local epoch

    if epoch="$(date -u -d "$value" '+%s' 2>/dev/null)"; then
        printf '%s\n' "$epoch"
        return 0
    fi

    # macOS/BSD date: UTC form ending in Z.
    if epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' 2>/dev/null)"; then
        printf '%s\n' "$epoch"
        return 0
    fi

    # macOS/BSD date commonly expects a numeric timezone without the colon.
    if [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]]; then
        normalized="${value:0:22}${value:23:2}"
        if epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S%z' "$normalized" '+%s' 2>/dev/null)"; then
            printf '%s\n' "$epoch"
            return 0
        fi
    fi

    return 1
}

validate_rfc3339() {
    local value="$1"
    iso8601_to_epoch "$value" >/dev/null 2>&1
}

# api_get_json OUTFILE URL [additional curl arguments]
# HTTP response must be 2xx and body must be valid JSON.
api_get_json() {
    local outfile="$1"
    LAST_HTTP_CODE=""
    LAST_API_FAILURE=""
    local url="$2"
    shift 2
    local http_code
    local curl_rc
    local curl_err="${outfile}.curl.err"

    set +e
    http_code="$({ curl "${CURL_OPTIONS[@]}" "$@" -o "$outfile" -w '%{http_code}' "$url"; } 2>"$curl_err")"
    curl_rc=$?
    set -e

    if (( curl_rc != 0 )); then
        LAST_API_FAILURE="network"
        warn "curl failed for ${url} (exit ${curl_rc})"
        if [[ -s "$curl_err" ]]; then
            {
                printf 'curl diagnostics for %s:\n' "$url"
                sed 's/^/  /' "$curl_err"
            } >> "$RUN_LOG"
        fi
        return 1
    fi

    LAST_HTTP_CODE="$http_code"
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        case "$http_code" in
            401|403) LAST_API_FAILURE="auth" ;;
            404|405) LAST_API_FAILURE="version" ;;
            408|429|5*) LAST_API_FAILURE="transient" ;;
            *) LAST_API_FAILURE="http" ;;
        esac
        warn "HTTP ${http_code} returned by ${url}"
        if [[ -s "$outfile" ]]; then
            {
                printf 'API error details for %s:\n' "$url"
                jq -r '
                  if .data.error? then (.data.error[]?.message // .data.error[]?.details // empty)
                  elif .message? then .message
                  elif .error? then (.error.message // .error)
                  else empty end
                ' "$outfile" 2>/dev/null | sed 's/^/  /'
            } >> "$RUN_LOG" || true
        fi
        return 1
    fi

    if ! jq -e . "$outfile" >/dev/null 2>&1; then
        LAST_API_FAILURE="json"
        warn "The response from ${url} is not valid JSON"
        return 1
    fi

    return 0
}

csv_escape() {
    local value="$1"
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
}

# ---------- Prerequisite checks ----------
for command in curl jq awk sed sort comm date mktemp; do
    require_command "$command"
done

if (( BASH_VERSINFO[0] < 4 )); then
    fail "Bash 4 or newer is required. Detected: ${BASH_VERSION}"
fi

# ---------- Configuration ----------
echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
echo "This script performs read-only Prism Central API calls."
echo

# Defaults are used only when parameter mode has omitted an optional value.
if [[ "$PARAMETER_MODE" == "yes" ]]; then
    PC_HOST="${PC_HOST:-}"
    PC_PORT="${PC_PORT:-9440}"
    PRISM_API_VERSION="${PRISM_API_VERSION:-v4.4}"
    VMM_API_VERSION="${VMM_API_VERSION:-v4.3}"
    MATCH_MODE="${MATCH_MODE:-OR}"
    SAMPLING_INTERVAL="${SAMPLING_INTERVAL:-300}"
    CAPACITY_AGGREGATION="${CAPACITY_AGGREGATION:-PEAK}"
    CALCULATE_COST="${CALCULATE_COST:-yes}"
    PRICE_PER_GB="${PRICE_PER_GB:-0.009}"
    VERIFY_TLS="${VERIFY_TLS:-yes}"
    OUTPUT_DIR="${OUTPUT_DIR:-./nutanix-category-stats-$(date -u '+%Y%m%dT%H%M%SZ')}"
else
    prompt_default "Prism Central FQDN or IP (without https://)" "prism-central.example.local" PC_HOST
    prompt_default "Prism Central HTTPS port" "9440" PC_PORT
    prompt_default "Prism Categories API version" "v4.4" PRISM_API_VERSION
    prompt_default "VM/Stats API version" "v4.3" VMM_API_VERSION
    prompt_default "Category match mode (OR or AND)" "OR" MATCH_MODE
    prompt_default "Sampling interval in seconds" "300" SAMPLING_INTERVAL
    prompt_default "Capacity aggregation (PEAK or AVG; PEAK maps to API MAX)" "PEAK" CAPACITY_AGGREGATION
    prompt_default "Calculate scenario cost estimates? (y/n)" "y" CALCULATE_COST
    if [[ "${CALCULATE_COST,,}" =~ ^(y|yes)$ ]]; then
        prompt_default "Estimated scenario price per GB (decimal GB)" "0.009" PRICE_PER_GB
    fi
    prompt_default "Output directory" "./nutanix-category-stats-$(date -u '+%Y%m%dT%H%M%SZ')" OUTPUT_DIR
    prompt_default "Verify Prism Central TLS certificate? (y/n)" "y" VERIFY_TLS
fi

PC_HOST="$(trim "$PC_HOST")"
PC_HOST="${PC_HOST#https://}"
PC_HOST="${PC_HOST#http://}"
PC_HOST="${PC_HOST%/}"
[[ -n "$PC_HOST" ]] || fail "Prism Central host must not be empty"
[[ "$PC_HOST" != */* ]] || fail "Enter only the host/IP, without a path"
[[ "$PC_PORT" =~ ^[0-9]+$ ]] || fail "Port must be numeric"
(( PC_PORT >= 1 && PC_PORT <= 65535 )) || fail "Port is outside the valid range"
[[ "$PRISM_API_VERSION" =~ ^v[0-9]+\.[0-9]+([.][a-zA-Z0-9]+)?$ ]] || fail "Invalid Prism API version format"
[[ "$VMM_API_VERSION" =~ ^v[0-9]+\.[0-9]+([.][a-zA-Z0-9]+)?$ ]] || fail "Invalid VMM API version format"

if [[ "$PARAMETER_MODE" == "yes" ]]; then
    if (( ${#CATEGORY_ARGUMENTS[@]} > 0 )); then
        CATEGORY_PAIRS=("${CATEGORY_ARGUMENTS[@]}")
    elif [[ -n "$CATEGORY_SELECTION_OVERRIDE" ]]; then
        IFS=',' read -r -a CATEGORY_PAIRS <<< "$CATEGORY_SELECTION_OVERRIDE"
    else
        fail "Parameter mode requires --category KEY=VALUE or --categories CSV"
    fi
else
    prompt_default "Category selection (Key=Value, comma-separated)" "DR=Critical" CATEGORY_SELECTION_OVERRIDE
    IFS=',' read -r -a CATEGORY_PAIRS <<< "$CATEGORY_SELECTION_OVERRIDE"
fi
(( ${#CATEGORY_PAIRS[@]} > 0 )) || fail "At least one category is required"
CATEGORY_SELECTION="$(printf '%s,' "${CATEGORY_PAIRS[@]}" | sed 's/,$//')"

[[ "$MATCH_MODE" == "${MATCH_MODE^^}" ]] || MATCH_MODE="${MATCH_MODE^^}"
[[ "$MATCH_MODE" == "OR" || "$MATCH_MODE" == "AND" ]] || fail "Match mode must be OR or AND"

DEFAULT_END="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if DEFAULT_START="$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
    :
else
    DEFAULT_START="$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ')"
fi

if [[ "$PARAMETER_MODE" == "yes" ]]; then
    if [[ -n "$LOOKBACK_OVERRIDE" && ( -n "$START_OVERRIDE" || -n "$END_OVERRIDE" ) ]]; then
        fail "Use either --lookback or --start/--end, not both"
    fi
    if [[ -n "$LOOKBACK_OVERRIDE" ]]; then
        LOOKBACK_SECONDS="$(parse_duration_seconds "$LOOKBACK_OVERRIDE")" ||             fail "Invalid lookback '$LOOKBACK_OVERRIDE'; use values such as 1h, 24h, 7d or 4w"
        END_TIME="${END_OVERRIDE:-$DEFAULT_END}"
        END_EPOCH="$(iso8601_to_epoch "$END_TIME")" || fail "Invalid end time: $END_TIME"
        START_EPOCH=$(( END_EPOCH - LOOKBACK_SECONDS ))
        START_TIME="$(format_epoch_utc "$START_EPOCH")"
    elif [[ -n "$START_OVERRIDE" || -n "$END_OVERRIDE" ]]; then
        [[ -n "$START_OVERRIDE" && -n "$END_OVERRIDE" ]] || fail "--start and --end must be supplied together"
        START_TIME="$START_OVERRIDE"
        END_TIME="$END_OVERRIDE"
    else
        START_TIME="$DEFAULT_START"
        END_TIME="$DEFAULT_END"
    fi
else
    prompt_default "Time range (1h, 24h, 7d, 4w, custom)" "24h" TIME_CHOICE
    if [[ "${TIME_CHOICE,,}" == "custom" ]]; then
        prompt_default "Start time (RFC3339/ISO-8601)" "$DEFAULT_START" START_TIME
        prompt_default "End time (RFC3339/ISO-8601)" "$DEFAULT_END" END_TIME
    else
        LOOKBACK_OVERRIDE="$TIME_CHOICE"
        LOOKBACK_SECONDS="$(parse_duration_seconds "$LOOKBACK_OVERRIDE")" ||             fail "Invalid time range '$TIME_CHOICE'; use values such as 1h, 24h, 7d or 4w, or choose custom"
        END_TIME="$DEFAULT_END"
        END_EPOCH="$(iso8601_to_epoch "$END_TIME")" || fail "Could not convert current time"
        START_EPOCH=$(( END_EPOCH - LOOKBACK_SECONDS ))
        START_TIME="$(format_epoch_utc "$START_EPOCH")"
    fi
fi
validate_rfc3339 "$START_TIME" || fail "Invalid start time: $START_TIME"
validate_rfc3339 "$END_TIME" || fail "Invalid end time: $END_TIME"
START_EPOCH="$(iso8601_to_epoch "$START_TIME")" || fail "Could not convert start time to epoch: $START_TIME"
END_EPOCH="$(iso8601_to_epoch "$END_TIME")" || fail "Could not convert end time to epoch: $END_TIME"
(( START_EPOCH < END_EPOCH )) || fail "Start time must be earlier than end time"

[[ "$SAMPLING_INTERVAL" =~ ^[0-9]+$ ]] || fail "Sampling interval must be an integer"
(( SAMPLING_INTERVAL >= 1 )) || fail "Sampling interval must be at least 1 second"

CAPACITY_AGGREGATION="${CAPACITY_AGGREGATION^^}"
case "$CAPACITY_AGGREGATION" in
    PEAK|MAX) CAPACITY_AGGREGATION="PEAK"; CAPACITY_STAT_TYPE="MAX" ;;
    AVG) CAPACITY_STAT_TYPE="AVG" ;;
    *) fail "Capacity aggregation must be PEAK or AVG" ;;
esac
VOLUME_STAT_TYPE="AVG"

CALCULATE_COST="${CALCULATE_COST,,}"
case "$CALCULATE_COST" in
    y|yes)
        COST_ENABLED="yes"
        PRICE_PER_GB="$(normalize_decimal_input "${PRICE_PER_GB:-0.009}")"
        [[ "$PRICE_PER_GB" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "Price per GB must be a non-negative number"
        ;;
    n|no)
        COST_ENABLED="no"
        PRICE_PER_GB="0"
        ;;
    *) fail "Please answer y or n for cost estimates" ;;
esac

if [[ "$PARAMETER_MODE" == "no" && -z "$CSV_FORMAT_OVERRIDE" ]]; then
    CSV_FORMAT="$(detect_csv_format)"
    prompt_default "CSV output format (DE=semicolon/comma, US=comma/point)" "$CSV_FORMAT" CSV_FORMAT
else
    CSV_FORMAT="${CSV_FORMAT_OVERRIDE:-$(detect_csv_format)}"
fi
CSV_FORMAT="${CSV_FORMAT^^}"
[[ "$CSV_FORMAT" == "AUTO" ]] && CSV_FORMAT="$(detect_csv_format)"
case "$CSV_FORMAT" in
    DE) CSV_SEPARATOR=';'; CSV_DECIMAL=',' ;;
    US) CSV_SEPARATOR=','; CSV_DECIMAL='.' ;;
    *) fail "CSV format must be auto, de or us" ;;
esac

case "${VERIFY_TLS,,}" in
    y|yes) VERIFY_TLS="yes"; TLS_OPTION=() ;;
    n|no) VERIFY_TLS="no"; TLS_OPTION=(-k) ;;
    *) fail "Verify TLS must be yes or no" ;;
esac

mkdir -p -- "$OUTPUT_DIR" || fail "Could not create output directory: $OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd)"
DETAILS_DIR="$OUTPUT_DIR/details"
DIAGNOSTICS_DIR="$OUTPUT_DIR/diagnostics"
mkdir -p -- "$DETAILS_DIR" "$DIAGNOSTICS_DIR" || fail "Could not create output subdirectories"
RUN_LOG="$DIAGNOSTICS_DIR/run.log"
: > "$RUN_LOG"
log_event INFO "Starting ${SCRIPT_NAME} ${SCRIPT_VERSION} (mode=${PARAMETER_MODE}, dry_run=${DRY_RUN})"
log_event INFO "CSV format: ${CSV_FORMAT} (separator=${CSV_SEPARATOR}, decimal=${CSV_DECIMAL})"
[[ "$VERIFY_TLS" == "no" ]] && warn "TLS certificate verification is disabled for this run."

# Validate requested output horizons before contacting Prism Central.
IFS=',' read -r -a VOLUME_WINDOW_LIST <<< "$VOLUME_WINDOWS"
(( ${#VOLUME_WINDOW_LIST[@]} > 0 )) || fail "At least one volume window is required"
for volume_window in "${VOLUME_WINDOW_LIST[@]}"; do
    volume_window="$(trim "$volume_window")"
    parse_duration_seconds "$volume_window" >/dev/null ||         fail "Invalid volume window '$volume_window'; use values such as 1h, 24h, 7d or 4w"
done

if [[ "$PARAMETER_MODE" == "yes" ]]; then
    [[ "$CONFIRM_READ_ONLY" == "yes" ]] || fail "Parameter mode requires --confirm-read-only; this run performs read-only API calls against the target environment and can create API load"
else
    cat >&2 <<EOF_WARNING
WARNING: The following operation will query the Prism Central environment:
  ${PC_HOST}:${PC_PORT}
Only read-only API calls are performed, but the run can create API/system load,
especially for many VMs or long time ranges. No Prism Central configuration is changed.
EOF_WARNING
    prompt_yes_no "Continue with the environment check?" "y" || fail "Run cancelled by user"
fi

# Credentials are never accepted as a command-line argument. Ask only after
# syntactic/semantic parameter validation and the read-only confirmation.
if [[ "$PARAMETER_MODE" == "yes" ]]; then
    [[ -n "${PC_USER:-}" ]] || fail "Parameter mode requires --user USER"
else
    read -r -p "Prism Central username: " PC_USER
fi
[[ -n "${PC_USER:-}" ]] || fail "Username must not be empty"
prompt_secret "Prism Central password" PC_PASS
[[ -n "$PC_PASS" ]] || fail "Password must not be empty"

# ---------- Secure curl configuration ----------
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nutanix-category-stats.XXXXXX")"
chmod 700 "$WORK_DIR"
CURL_CONFIG="$WORK_DIR/curl.conf"

write_curl_config() {
    local escaped_user_pass
    escaped_user_pass="$(printf '%s:%s' "$PC_USER" "$PC_PASS" | sed 's/[\\"]/\\&/g')"
    printf 'user = "%s"\n' "$escaped_user_pass" > "$CURL_CONFIG"
    chmod 600 "$CURL_CONFIG"
    unset escaped_user_pass
}

write_curl_config

CURL_OPTIONS=(
    --config "$CURL_CONFIG"
    --silent
    --show-error
    --connect-timeout 15
    --max-time 180
    --retry 3
    --retry-delay 2
    --retry-connrefused
    --header 'Accept: application/json'
    --header 'Content-Type: application/json'
    "${TLS_OPTION[@]}"
)

BASE_URL="https://${PC_HOST}:${PC_PORT}"

set_api_bases() {
    CATEGORY_BASE="${BASE_URL}/api/prism/${PRISM_API_VERSION}/config/categories"
    VM_BASE="${BASE_URL}/api/vmm/${VMM_API_VERSION}/ahv/config/vms"
    STATS_BASE="${BASE_URL}/api/vmm/${VMM_API_VERSION}/ahv/stats/vms"
}
set_api_bases

prompt_new_credentials() {
    if [[ "$PARAMETER_MODE" == "yes" ]]; then
        return 1
    fi
    if prompt_yes_no "Authentication/authorization failed for user '${PC_USER}'. Use another user?" "n"; then
        read -r -p "Prism Central username: " PC_USER
        [[ -n "$PC_USER" ]] || fail "Username must not be empty"
        prompt_secret "Prism Central password" PC_PASS
        [[ -n "$PC_PASS" ]] || fail "Password must not be empty"
        write_curl_config
        return 0
    fi
    return 1
}

prompt_api_version() {
    local api_name="$1"
    local current="$2"
    local answer
    if [[ "$PARAMETER_MODE" == "yes" ]]; then
        return 1
    fi
    prompt_default "${api_name} API version was not available; enter another version" "$current" answer
    [[ "$answer" =~ ^v[0-9]+\.[0-9]+([.][a-zA-Z0-9]+)?$ ]] || fail "Invalid API version format: $answer"
    if [[ "$api_name" == "Categories" ]]; then
        PRISM_API_VERSION="$answer"
    else
        VMM_API_VERSION="$answer"
    fi
    set_api_bases
    return 0
}

preflight_categories() {
    HEALTH_JSON="$WORK_DIR/health.json"
    while true; do
        info "Testing Prism Central connectivity, authentication and Categories API ${PRISM_API_VERSION}"
        if api_get_json "$HEALTH_JSON" "$CATEGORY_BASE" --get --data-urlencode '$limit=1'; then
            return 0
        fi
        if [[ "$LAST_API_FAILURE" == "auth" ]] && prompt_new_credentials; then
            continue
        fi
        if [[ "$LAST_API_FAILURE" == "version" ]] && prompt_api_version "Categories" "$PRISM_API_VERSION"; then
            continue
        fi
        fail "Categories API preflight failed (version=${PRISM_API_VERSION}, HTTP=${LAST_HTTP_CODE:-n/a}, reason=${LAST_API_FAILURE:-unknown})"
    done
}

preflight_vmm() {
    local vmm_json="$WORK_DIR/vmm_preflight.json"
    while true; do
        info "Testing VM configuration and Stats API ${VMM_API_VERSION}"
        if api_get_json "$vmm_json" "$VM_BASE" --get --data-urlencode '$limit=1'; then
            return 0
        fi
        if [[ "$LAST_API_FAILURE" == "auth" ]] && prompt_new_credentials; then
            continue
        fi
        if [[ "$LAST_API_FAILURE" == "version" ]] && prompt_api_version "VM/Stats" "$VMM_API_VERSION"; then
            continue
        fi
        fail "VM/Stats API preflight failed (version=${VMM_API_VERSION}, HTTP=${LAST_HTTP_CODE:-n/a}, reason=${LAST_API_FAILURE:-unknown})"
    done
}

preflight_categories
preflight_vmm

# ---------- Resolve category selection to VM IDs ----------
VM_ID_FILES=()
CATEGORY_MATCHES_TSV="$DETAILS_DIR/category_matches.tsv"
printf 'category_key\tcategory_value\tvm_ext_id\n' > "$CATEGORY_MATCHES_TSV"


category_index=0
for raw_pair in "${CATEGORY_PAIRS[@]}"; do
    pair="$(trim "$raw_pair")"
    [[ "$pair" == *=* ]] || fail "Invalid category pair '$pair'; expected Key=Value"
    category_key="$(trim "${pair%%=*}")"
    category_value="$(trim "${pair#*=}")"
    [[ -n "$category_key" && -n "$category_value" ]] || fail "Category key/value must not be empty: $pair"

    category_index=$((category_index + 1))
    category_file="$WORK_DIR/category_${category_index}.ids"
    category_list_response="$WORK_DIR/category_${category_index}_list.json"
    category_detail_response="$WORK_DIR/category_${category_index}_detail.json"
    VM_ID_FILES+=("$category_file")

    info "Resolving category ${category_key}:${category_value}"
    category_filter="key eq '${category_key//\'/\'\'}' and value eq '${category_value//\'/\'\'}'"

    # Some Prism Central releases reject detailedAssociations on the List
    # Categories endpoint. Use a compatible two-step flow:
    #   1) list/filter the category and obtain its extId
    #   2) fetch that category by extId and expand detailedAssociations
    if ! api_get_json "$category_list_response" "$CATEGORY_BASE" \
        --get \
        --data-urlencode '$limit=100' \
        --data-urlencode "\$filter=${category_filter}"; then
        fail "Could not search category ${category_key}:${category_value}"
    fi

    category_ext_id="$(jq -r --arg key "$category_key" --arg value "$category_value" '
        [ .data[]?
          | select((.key // "") == $key and (.value // "") == $value)
        ]
        | if length > 0 then .[0].extId // empty else empty end
    ' "$category_list_response")"

    [[ -n "$category_ext_id" && "$category_ext_id" != "null" ]] || \
        fail "Category ${category_key}:${category_value} was not found or has no extId"

    : > "$category_file"
    category_page_url="${CATEGORY_BASE}/${category_ext_id}"
    category_page=0
    while true; do
        category_page=$((category_page + 1))
        category_detail_response="$WORK_DIR/category_${category_index}_detail_${category_page}.json"
        if ! api_get_json "$category_detail_response" "$category_page_url" \
            --get \
            --data-urlencode '$expand=detailedAssociations' \
            --data-urlencode '$limit=1000'; then
            fail "Could not retrieve details for category ${category_key}:${category_value} (${category_ext_id}), page ${category_page}"
        fi

        jq -r '
            .data.detailedAssociations[]?
            | select((.resourceType // "") == "VM")
            | .resourceId // empty
        ' "$category_detail_response" >> "$category_file"

        next_url="$(jq -r '
            .metadata.links.next.href // .metadata.links.next //
            .data.metadata.links.next.href // .data.metadata.links.next // empty
        ' "$category_detail_response" 2>/dev/null || true)"
        [[ -n "$next_url" && "$next_url" != "null" ]] || break
        if [[ "$next_url" == /* ]]; then
            category_page_url="${BASE_URL}${next_url}"
        elif [[ "$next_url" == http://* || "$next_url" == https://* ]]; then
            category_page_url="$next_url"
        else
            break
        fi
    done
    sort -u -o "$category_file" "$category_file"

    if [[ ! -s "$category_file" ]]; then
        fail "Category ${category_key}:${category_value} exists or was queried, but no VM associations were returned"
    fi

    while IFS= read -r vm_id; do
        printf '%s\t%s\t%s\n' "$category_key" "$category_value" "$vm_id" >> "$CATEGORY_MATCHES_TSV"
    done < "$category_file"

    info "  Found $(wc -l < "$category_file" | tr -d ' ') VM association(s)"
done

VM_IDS="$WORK_DIR/selected_vm_ids"
if [[ "$MATCH_MODE" == "OR" ]]; then
    cat "${VM_ID_FILES[@]}" | sort -u > "$VM_IDS"
else
    cp "${VM_ID_FILES[0]}" "$VM_IDS"
    for (( i=1; i<${#VM_ID_FILES[@]}; i++ )); do
        comm -12 "$VM_IDS" "${VM_ID_FILES[$i]}" > "$WORK_DIR/intersection.ids"
        mv "$WORK_DIR/intersection.ids" "$VM_IDS"
    done
fi

SELECTED_VM_COUNT="$(wc -l < "$VM_IDS" | tr -d ' ')"
(( SELECTED_VM_COUNT > 0 )) || fail "No VMs matched the selected category mode (${MATCH_MODE})"
info "Selected ${SELECTED_VM_COUNT} unique VM(s) using ${MATCH_MODE} mode"

REQUESTED_WINDOW_SECONDS=$(( END_EPOCH - START_EPOCH ))
ESTIMATED_SAMPLES_PER_VM=$(( REQUESTED_WINDOW_SECONDS / SAMPLING_INTERVAL + 1 ))
ESTIMATED_API_REQUESTS=$(( ${#CATEGORY_PAIRS[@]} * 2 + SELECTED_VM_COUNT * 3 + 3 ))
ESTIMATED_TOTAL_SAMPLES=$(( ESTIMATED_SAMPLES_PER_VM * SELECTED_VM_COUNT * 2 ))
if (( SELECTED_VM_COUNT >= 100 || ESTIMATED_TOTAL_SAMPLES >= 500000 )); then
    cat >&2 <<EOF_LARGE
WARNING: This selection is relatively large:
  Selected VMs:                  ${SELECTED_VM_COUNT}
  Estimated API requests:        ${ESTIMATED_API_REQUESTS}
  Estimated samples (both paths): ${ESTIMATED_TOTAL_SAMPLES}
  Sampling interval:             ${SAMPLING_INTERVAL} seconds
The run is sequential and may take a while and create API/system load.
EOF_LARGE
    if [[ "$PARAMETER_MODE" == "no" ]]; then
        prompt_yes_no "Continue with this large selection?" "n" || fail "Run cancelled by user"
    fi
fi

preflight_stats() {
    local vm_id="$1"
    local stats_preflight="$WORK_DIR/stats_preflight.json"
    while true; do
        info "Testing historical VM Stats permission with VM ${vm_id}"
        if api_get_json "$stats_preflight" "${STATS_BASE}/${vm_id}" \
            --get \
            --data-urlencode "\$startTime=${START_TIME}" \
            --data-urlencode "\$endTime=${END_TIME}" \
            --data-urlencode "\$samplingInterval=${SAMPLING_INTERVAL}" \
            --data-urlencode '$statType=AVG' \
            --data-urlencode '$select=stats/timestamp,stats/controllerWriteIoBandwidthKbps' \
            --data-urlencode '$limit=1'; then
            return 0
        fi
        if [[ "$LAST_API_FAILURE" == "auth" ]] && prompt_new_credentials; then
            continue
        fi
        if [[ "$LAST_API_FAILURE" == "version" ]] && prompt_api_version "VM/Stats" "$VMM_API_VERSION"; then
            continue
        fi
        fail "Historical VM Stats permission/API check failed (version=${VMM_API_VERSION}, HTTP=${LAST_HTTP_CODE:-n/a}, reason=${LAST_API_FAILURE:-unknown})"
    done
}

first_selected_vm="$(sed -n '1p' "$VM_IDS")"
preflight_stats "$first_selected_vm"

if [[ "$DRY_RUN" == "yes" ]]; then
    DRY_RUN_SUMMARY="$OUTPUT_DIR/dry_run_summary.txt"
    cat > "$DRY_RUN_SUMMARY" <<EOF_DRY
Nutanix category VM write-statistics dry-run
============================================
Script version:                  ${SCRIPT_VERSION}
Prism Central:                   ${PC_HOST}:${PC_PORT}
Categories API:                  ${PRISM_API_VERSION}
VM/Stats API:                    ${VMM_API_VERSION}
Category selection:              ${CATEGORY_SELECTION}
Category match mode:             ${MATCH_MODE}
Start time:                      ${START_TIME}
End time:                        ${END_TIME}
Sampling interval:               ${SAMPLING_INTERVAL} seconds
Selected VMs:                    ${SELECTED_VM_COUNT}
Estimated API requests:          ${ESTIMATED_API_REQUESTS}
Estimated samples (both paths):  ${ESTIMATED_TOTAL_SAMPLES}
Volume windows:                  ${VOLUME_WINDOWS}

Preflight completed. No full historical statistics collection was executed.
A minimal Stats API permission check was performed for the first selected VM.
EOF_DRY
    printf '\nDry-run completed successfully.\n\nSummary:\n  %s\n' "$DRY_RUN_SUMMARY"
    exit 0
fi

# ---------- Resolve VM names ----------
VM_MAP="$DETAILS_DIR/selected_vms.tsv"
printf 'vm_ext_id\tvm_name\n' > "$VM_MAP"
VM_CONFIG_FAILURES=0

while IFS= read -r vm_id; do
    vm_response="$WORK_DIR/vm_${vm_id}.json"
    if ! api_get_json "$vm_response" "${VM_BASE}/${vm_id}" --get; then
        warn "Could not retrieve VM configuration for ${vm_id}; using the VM UUID as display name"
        VM_CONFIG_FAILURES=$((VM_CONFIG_FAILURES + 1))
        vm_name="$vm_id"
    else
        vm_name="$(jq -r '.data.name // .data.spec.name // .data.metadata.name // empty' "$vm_response")"
        if [[ -z "$vm_name" || "$vm_name" == "null" ]]; then
            warn "VM name not present for ${vm_id}; using the VM UUID"
            vm_name="$vm_id"
        fi
    fi
    printf '%s\t%s\n' "$vm_id" "$vm_name" >> "$VM_MAP"
done < "$VM_IDS"

EXPECTED_VM_COUNT=$(( $(wc -l < "$VM_MAP") - 1 ))
(( EXPECTED_VM_COUNT > 0 )) || fail "No VM configuration could be read"

if (( VM_CONFIG_FAILURES > 0 )); then
    warn "${VM_CONFIG_FAILURES} selected VM(s) could not be resolved and will not be queried"
fi

# ---------- Query historical stats ----------
# Capacity uses API MAX (reported consistently as Peak); volume/cost uses AVG.
RAW_RESPONSE_DIR="$DIAGNOSTICS_DIR/raw_api_responses"
mkdir -p -- "$RAW_RESPONSE_DIR/capacity" "$RAW_RESPONSE_DIR/volume"
STATS_DIAGNOSTICS="$DIAGNOSTICS_DIR/stats_diagnostics.txt"
: > "$STATS_DIAGNOSTICS"

STATS_FAILURES_CAPACITY=0
EMPTY_STATS_CAPACITY=0
INVALID_POINTS_CAPACITY=0
STATS_FAILURES_VOLUME=0
EMPTY_STATS_VOLUME=0
INVALID_POINTS_VOLUME=0
NO_METRICS_CAPACITY="$WORK_DIR/no_metrics_capacity.tsv"
NO_METRICS_VOLUME="$WORK_DIR/no_metrics_volume.tsv"
: > "$NO_METRICS_CAPACITY"
: > "$NO_METRICS_VOLUME"

record_no_metrics() {
    local file="$1"
    local vm_name="$2"
    local vm_id="$3"
    local reason="$4"
    printf '%s\t%s\t%s\n' "$vm_name" "$vm_id" "$reason" >> "$file"
}

extract_stat_points() {
    local response="$1"
    local output="$2"
    jq -r '
        def rows($d):
          if (($d.stats // null) | type) == "array" then
            $d.stats[] as $s
            | {
                timestamp: ($s.timestamp // $d.timestamp // $s.time // $d.time // ""),
                value: (
                  $s.controllerWriteIoBandwidthKbps
                  // $s.value
                  // $d.controllerWriteIoBandwidthKbps
                  // $d.value
                )
              }
          else
            {
              timestamp: ($d.timestamp // $d.time // ""),
              value: ($d.controllerWriteIoBandwidthKbps // $d.value // empty)
            }
          end;

        (.data // null) as $data
        | if (($data | type) == "object") then
            rows($data)
          elif (($data | type) == "array") then
            $data[] | rows(.)
          else
            empty
          end
        | select(.timestamp != "" and .value != null)
        | [.timestamp, .value]
        | @tsv
    ' "$response" > "$output"
}

query_stats_mode() {
    local mode_label="$1"
    local stat_type="$2"
    local response_subdir="$3"
    local samples_tsv="$4"
    local vm_id vm_name stat_response stat_points raw_copy point_count timestamp write_kbps

    printf 'vm_name\tvm_ext_id\ttimestamp\twrite_kBps\n' > "$samples_tsv"

    while IFS=$'\t' read -r vm_id vm_name; do
        [[ "$vm_id" == "vm_ext_id" ]] && continue
        stat_response="$WORK_DIR/${response_subdir}_${vm_id}.json"
        stat_points="$WORK_DIR/${response_subdir}_points_${vm_id}.tsv"

        info "Querying ${mode_label} write statistics for ${vm_name} (${vm_id})"
        if ! api_get_json "$stat_response" "${STATS_BASE}/${vm_id}" \
            --get \
            --data-urlencode "\$startTime=${START_TIME}" \
            --data-urlencode "\$endTime=${END_TIME}" \
            --data-urlencode "\$samplingInterval=${SAMPLING_INTERVAL}" \
            --data-urlencode "\$statType=${stat_type}" \
            --data-urlencode '$select=stats/timestamp,stats/controllerWriteIoBandwidthKbps'; then
            warn "${mode_label} stats query failed for ${vm_name} (${vm_id}); continuing"
            if [[ "$mode_label" == "capacity" ]]; then
                record_no_metrics "$NO_METRICS_CAPACITY" "$vm_name" "$vm_id" "query failed"
            else
                record_no_metrics "$NO_METRICS_VOLUME" "$vm_name" "$vm_id" "query failed"
            fi
            if [[ "$mode_label" == "capacity" ]]; then
                STATS_FAILURES_CAPACITY=$((STATS_FAILURES_CAPACITY + 1))
            else
                STATS_FAILURES_VOLUME=$((STATS_FAILURES_VOLUME + 1))
            fi
            continue
        fi

        if ! extract_stat_points "$stat_response" "$stat_points"; then
            raw_copy="$RAW_RESPONSE_DIR/${response_subdir}/${vm_id}.json"
            cp -- "$stat_response" "$raw_copy"
            printf '\n=== %s %s (%s) - parser error ===\nRaw response: %s\n' \
                "$mode_label" "$vm_name" "$vm_id" "$raw_copy" >> "$STATS_DIAGNOSTICS"
            if [[ "$mode_label" == "capacity" ]]; then
                record_no_metrics "$NO_METRICS_CAPACITY" "$vm_name" "$vm_id" "parser error"
            else
                record_no_metrics "$NO_METRICS_VOLUME" "$vm_name" "$vm_id" "parser error"
            fi
            warn "Could not parse ${mode_label} stats for ${vm_name}; raw response saved to ${raw_copy}"
            if [[ "$mode_label" == "capacity" ]]; then
                STATS_FAILURES_CAPACITY=$((STATS_FAILURES_CAPACITY + 1))
            else
                STATS_FAILURES_VOLUME=$((STATS_FAILURES_VOLUME + 1))
            fi
            continue
        fi

        point_count=0
        while IFS=$'\t' read -r timestamp write_kbps; do
            [[ -n "${timestamp:-}" && -n "${write_kbps:-}" ]] || continue
            if [[ ! "$write_kbps" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
                if [[ "$mode_label" == "capacity" ]]; then
                    INVALID_POINTS_CAPACITY=$((INVALID_POINTS_CAPACITY + 1))
                else
                    INVALID_POINTS_VOLUME=$((INVALID_POINTS_VOLUME + 1))
                fi
                continue
            fi
            printf '%s\t%s\t%s\t%s\n' "$vm_name" "$vm_id" "$timestamp" "$write_kbps" >> "$samples_tsv"
            point_count=$((point_count + 1))
        done < "$stat_points"

        if (( point_count == 0 )); then
            raw_copy="$RAW_RESPONSE_DIR/${response_subdir}/${vm_id}.json"
            cp -- "$stat_response" "$raw_copy"
            {
                printf '\n=== %s %s (%s) ===\n' "$mode_label" "$vm_name" "$vm_id"
                printf 'Raw response: %s\n' "$raw_copy"
                jq -c '{
                    top_type: type,
                    top_keys: (if type == "object" then keys else [] end),
                    data_type: (.data | type),
                    data_keys: (if (.data | type) == "object" then (.data | keys) else [] end),
                    stats_type: (if (.data | type) == "object" then ((.data.stats // null) | type) else "n/a" end),
                    stats_count: (if (.data | type) == "object" and ((.data.stats // null) | type) == "array" then (.data.stats | length) else 0 end),
                    first_stat: (if (.data | type) == "object" and ((.data.stats // null) | type) == "array" then (.data.stats[0] // null) else null end)
                }' "$stat_response" 2>&1 || true
            } >> "$STATS_DIAGNOSTICS"
            if [[ "$mode_label" == "capacity" ]]; then
                record_no_metrics "$NO_METRICS_CAPACITY" "$vm_name" "$vm_id" "no usable points"
            else
                record_no_metrics "$NO_METRICS_VOLUME" "$vm_name" "$vm_id" "no usable points"
            fi
            warn "No usable ${mode_label} points returned for ${vm_name}; raw response saved to ${raw_copy}"
            if [[ "$mode_label" == "capacity" ]]; then
                EMPTY_STATS_CAPACITY=$((EMPTY_STATS_CAPACITY + 1))
            else
                EMPTY_STATS_VOLUME=$((EMPTY_STATS_VOLUME + 1))
            fi
        fi
    done < "$VM_MAP"
}

CAPACITY_SAMPLES_TSV="$WORK_DIR/capacity_samples.tsv"
VOLUME_SAMPLES_TSV="$WORK_DIR/volume_samples.tsv"
query_stats_mode "capacity" "$CAPACITY_STAT_TYPE" "capacity" "$CAPACITY_SAMPLES_TSV"
query_stats_mode "volume" "$VOLUME_STAT_TYPE" "volume" "$VOLUME_SAMPLES_TSV"

RAW_CAPACITY_POINT_COUNT=$(( $(wc -l < "$CAPACITY_SAMPLES_TSV") - 1 ))
RAW_VOLUME_POINT_COUNT=$(( $(wc -l < "$VOLUME_SAMPLES_TSV") - 1 ))
(( RAW_CAPACITY_POINT_COUNT > 0 )) || fail "No usable capacity statistics were returned for any selected VM"
(( RAW_VOLUME_POINT_COUNT > 0 )) || fail "No usable volume statistics were returned for any selected VM"

write_samples_csv() {
    local samples_tsv="$1"
    local output_csv="$2"
    {
        printf 'vm_name%svm_ext_id%stimestamp%swrite_bandwidth_kBps%swrite_bandwidth_MBps%sinterval_GB\n' \
            "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR"
        LC_ALL=C awk -F '\t' -v interval="$SAMPLING_INTERVAL" -v sep="$CSV_SEPARATOR" -v decimal="$CSV_DECIMAL" '
            NR == 1 { next }
            function csv(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
            function number(v, d, s) {
                s = sprintf("%.*f", d, v)
                if (decimal == ",") gsub(/\./, ",", s)
                return s
            }
            {
                printf "%s%s%s%s%s%s%s%s%s%s%s\n", \
                    csv($1), sep, csv($2), sep, csv($3), sep, \
                    number($4, 6), sep, number($4/1000, 6), sep, \
                    number(($4 * interval)/1000000, 9)
            }
        ' "$samples_tsv"
    } > "$output_csv"
}

# Keep the detailed sample CSVs from the original script. Only their locale
# formatting is configurable; the underlying sample data is unchanged.
write_samples_csv "$CAPACITY_SAMPLES_TSV" "$DETAILS_DIR/write_samples_capacity.csv"
write_samples_csv "$VOLUME_SAMPLES_TSV" "$DETAILS_DIR/write_samples_volume.csv"

write_aggregate_csv() {
    local input_tsv="$1"
    local output_csv="$2"
    {
        printf 'timestamp%stotal_write_bandwidth_kBps%svm_samples%sexpected_vms%scomplete%sinterval_GB\n' \
            "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR"
        LC_ALL=C awk -F '\t' -v sep="$CSV_SEPARATOR" -v decimal="$CSV_DECIMAL" '
            function number(v, d, s) {
                s = sprintf("%.*f", d, v)
                if (decimal == ",") gsub(/\./, ",", s)
                return s
            }
            NR > 1 {
                printf "%s%s%s%s%d%s%d%s%s%s%s\n", \
                    $1, sep, number($2, 6), sep, $3, sep, $4, sep, $5, sep, number($6, 9)
            }
        ' "$input_tsv"
    } > "$output_csv"
}

aggregate_samples() {
    local samples_tsv="$1"
    local output_tsv="$2"
    printf 'timestamp\ttotal_write_kBps\tvm_samples\texpected_vms\tcomplete\tinterval_GB\n' > "$output_tsv"
    LC_ALL=C awk -F '\t' -v expected="$EXPECTED_VM_COUNT" -v interval="$SAMPLING_INTERVAL" '
        NR == 1 { next }
        {
            total[$3] += $4
            count[$3]++
        }
        END {
            for (timestamp in total) {
                complete = (count[timestamp] == expected ? "yes" : "no")
                interval_gb = (total[timestamp] * interval) / 1000000
                printf "%s\t%.6f\t%d\t%d\t%s\t%.9f\n", timestamp, total[timestamp], count[timestamp], expected, complete, interval_gb
            }
        }
    ' "$samples_tsv" | LC_ALL=C sort -k1,1 >> "$output_tsv"
}

summarize_aggregate() {
    local summary_tsv="$1"
    local prefix="$2"
    local all_series="$WORK_DIR/${prefix}_all_series.txt"
    local complete_series="$WORK_DIR/${prefix}_complete_series.txt"
    local series
    local series_type
    local metrics="$WORK_DIR/${prefix}_metrics.tsv"

    local all_timestamps="$WORK_DIR/${prefix}_all_timestamps.txt"
    local complete_timestamps="$WORK_DIR/${prefix}_complete_timestamps.txt"
    local selected_timestamps
    local count avg p95 peak volume sampled_seconds interval_count

    : > "$all_series"
    : > "$complete_series"
    : > "$all_timestamps"
    : > "$complete_timestamps"
    awk -F '\t' -v complete_file="$complete_series" \
        -v all_timestamps_file="$all_timestamps" \
        -v complete_timestamps_file="$complete_timestamps" \
        'NR > 1 {
            print $2
            print $1 > all_timestamps_file
            if ($5 == "yes") {
                print $2 > complete_file
                print $1 > complete_timestamps_file
            }
        }' "$summary_tsv" > "$all_series"

    if [[ -s "$complete_series" ]]; then
        series="$complete_series"
        selected_timestamps="$complete_timestamps"
        series_type="complete timestamps only"
    else
        series="$all_series"
        selected_timestamps="$all_timestamps"
        series_type="all timestamps; no complete timestamp was available"
        warn "No ${prefix} timestamp contained data from all ${EXPECTED_VM_COUNT} VM(s); metrics may be incomplete"
    fi

    count="$(wc -l < "$series" | tr -d ' ')"
    interval_count="$count"
    avg="$(LC_ALL=C awk '{sum += $1} END {if (NR > 0) printf "%.6f", sum/NR; else print "0"}' "$series")"
    peak="$(LC_ALL=C awk 'BEGIN {max=0} {if ($1 > max) max=$1} END {printf "%.6f", max}' "$series")"
    volume="$(LC_ALL=C awk -v interval="$SAMPLING_INTERVAL" '{sum += ($1 * interval) / 1000000} END {printf "%.9f", sum}' "$series")"
    p95="$(LC_ALL=C sort -n "$series" | LC_ALL=C awk '
        {values[NR]=$1}
        END {
            if (NR == 0) { print "0"; exit }
            pos = int((NR * 95 + 99) / 100)
            if (pos < 1) pos=1
            if (pos > NR) pos=NR
            printf "%.6f", values[pos]
        }
    ')"

    # Sample count includes both endpoint timestamps. Report the actual
    # timestamp span instead of count * interval, which otherwise overstates
    # a 24-hour inclusive series by one sampling interval.
    sampled_seconds=0
    if [[ -s "$selected_timestamps" ]]; then
        local first_timestamp last_timestamp first_epoch last_epoch
        first_timestamp="$(sed -n '1p' "$selected_timestamps")"
        last_timestamp="$(tail -n 1 "$selected_timestamps")"
        if first_epoch="$(iso8601_to_epoch "$first_timestamp")" && \
           last_epoch="$(iso8601_to_epoch "$last_timestamp")"; then
            sampled_seconds=$(( last_epoch - first_epoch ))
            (( sampled_seconds < 0 )) && sampled_seconds=0
        fi
    fi
    if (( sampled_seconds == 0 && count > 1 )); then
        sampled_seconds=$(( (count - 1) * SAMPLING_INTERVAL ))
    fi

    {
        printf 'SERIES_TYPE\t%s\n' "$series_type"
        printf 'SAMPLE_COUNT\t%s\n' "$count"
        printf 'SAMPLED_SECONDS\t%s\n' "$sampled_seconds"
        printf 'INTERVALS_USED\t%s\n' "$interval_count"
        printf 'AVERAGE_KBPS\t%s\n' "$avg"
        printf 'P95_KBPS\t%s\n' "$p95"
        printf 'PEAK_KBPS\t%s\n' "$peak"
        printf 'VOLUME_GB\t%s\n' "$volume"
    } > "$metrics"
}

CAPACITY_SUMMARY_TSV="$WORK_DIR/capacity_summary.tsv"
VOLUME_SUMMARY_TSV="$WORK_DIR/volume_summary.tsv"
aggregate_samples "$CAPACITY_SAMPLES_TSV" "$CAPACITY_SUMMARY_TSV"
aggregate_samples "$VOLUME_SAMPLES_TSV" "$VOLUME_SUMMARY_TSV"
write_aggregate_csv "$CAPACITY_SUMMARY_TSV" "$OUTPUT_DIR/aggregate_capacity_summary.csv"
write_aggregate_csv "$VOLUME_SUMMARY_TSV" "$OUTPUT_DIR/aggregate_volume_summary.csv"
summarize_aggregate "$CAPACITY_SUMMARY_TSV" "capacity"
summarize_aggregate "$VOLUME_SUMMARY_TSV" "volume"

# Report sampled AVG volume independently for every requested horizon. Values are
# summed only from samples that actually fall inside the horizon; no missing time
# is extrapolated to the requested duration.
VOLUME_WINDOWS_TSV="$WORK_DIR/volume_windows.tsv"
printf 'requested_window\trequested_seconds\tfirst_sample\tlast_sample\tcovered_seconds\tsample_count\taverage_kBps\tobserved_volume_GB\tcoverage\n' > "$VOLUME_WINDOWS_TSV"
for volume_window in "${VOLUME_WINDOW_LIST[@]}"; do
    volume_window="$(trim "$volume_window")"
    window_seconds="$(parse_duration_seconds "$volume_window")"
    window_start_epoch=$(( END_EPOCH - window_seconds ))
    window_start_time="$(format_epoch_utc "$window_start_epoch")"
    window_points="$WORK_DIR/volume_window_${volume_window}.tsv"
    awk -F '\t' -v start="$window_start_time" -v end="$END_TIME" \
        'NR > 1 && $1 >= start && $1 <= end {print}' \
        "$VOLUME_SUMMARY_TSV" > "$window_points"

    window_count="$(wc -l < "$window_points" | tr -d ' ')"
    if (( window_count == 0 )); then
        printf '%s\t%s\t\t\t0\t0\t0\t0\tno_samples\n' \
            "$volume_window" "$window_seconds" >> "$VOLUME_WINDOWS_TSV"
        continue
    fi

    first_sample="$(sed -n '1p' "$window_points" | cut -f1)"
    last_sample="$(tail -n 1 "$window_points" | cut -f1)"
    first_epoch="$(iso8601_to_epoch "$first_sample" 2>/dev/null || printf '%s' "$window_start_epoch")"
    last_epoch="$(iso8601_to_epoch "$last_sample" 2>/dev/null || printf '%s' "$END_EPOCH")"
    covered_seconds=$(( last_epoch - first_epoch ))
    (( covered_seconds < 0 )) && covered_seconds=0
    coverage="partial"
    if (( first_epoch <= window_start_epoch && last_epoch >= END_EPOCH )); then
        coverage="complete"
    fi
    window_avg="$(LC_ALL=C awk -F '\t' '{sum += $2} END {if (NR > 0) printf "%.6f", sum/NR; else print "0"}' "$window_points")"
    window_volume="$(LC_ALL=C awk -F '\t' -v interval="$SAMPLING_INTERVAL" '{sum += $2 * interval / 1000000} END {printf "%.9f", sum}' "$window_points")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$volume_window" "$window_seconds" "$first_sample" "$last_sample" \
        "$covered_seconds" "$window_count" "$window_avg" "$window_volume" "$coverage" \
        >> "$VOLUME_WINDOWS_TSV"
done

write_volume_windows_csv() {
    local input_tsv="$1"
    local output_csv="$2"
    {
        printf 'requested_window%srequested_seconds%sfirst_sample%slast_sample%scovered_seconds%ssample_count%saverage_write_bandwidth_kBps%sobserved_sampled_volume_GB%scoverage\n' \
            "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR" "$CSV_SEPARATOR"
        LC_ALL=C awk -F '\t' -v sep="$CSV_SEPARATOR" -v decimal="$CSV_DECIMAL" '
            function csv(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
            function number(v, d, s) { s=sprintf("%.*f", d, v); if (decimal == ",") gsub(/\./, ",", s); return s }
            NR > 1 {
                printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
                    csv($1), sep, $2, sep, csv($3), sep, csv($4), sep, \
                    $5, sep, $6, sep, number($7,6), sep, number($8,9), sep, csv($9)
            }
        ' "$input_tsv"
    } > "$output_csv"
}
write_volume_windows_csv "$VOLUME_WINDOWS_TSV" "$OUTPUT_DIR/volume_windows.csv"

unique_missing_rows() {
    local input="$1"
    [[ -s "$input" ]] || return 0
    awk -F '\t' '!seen[$2]++' "$input" | LC_ALL=C sort -f -t $'\t' -k1,1
}

missing_count() {
    local input="$1"
    unique_missing_rows "$input" | awk 'NF > 0 { count++ } END { print count + 0 }'
}

format_missing_list() {
    local input="$1"
    local count="$2"
    local vm_name vm_id reason
    if (( count == 0 )); then
        printf '  None\n'
        return 0
    fi
    while IFS=$'\t' read -r vm_name vm_id reason; do
        printf '  - %s [%s] (%s)\n' "$vm_name" "$vm_id" "$reason"
    done < <(unique_missing_rows "$input")
}

NO_METRICS_CAPACITY_COUNT="$(missing_count "$NO_METRICS_CAPACITY")"
NO_METRICS_VOLUME_COUNT="$(missing_count "$NO_METRICS_VOLUME")"
MISSING_CAPACITY_LIST="$(format_missing_list "$NO_METRICS_CAPACITY" "$NO_METRICS_CAPACITY_COUNT")"
MISSING_VOLUME_LIST="$(format_missing_list "$NO_METRICS_VOLUME" "$NO_METRICS_VOLUME_COUNT")"

metric() {
    LC_ALL=C awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$2"
}

CAPACITY_SERIES_TYPE="$(metric SERIES_TYPE "$WORK_DIR/capacity_metrics.tsv")"
CAPACITY_SAMPLE_COUNT="$(metric SAMPLE_COUNT "$WORK_DIR/capacity_metrics.tsv")"
CAPACITY_SAMPLED_SECONDS="$(metric SAMPLED_SECONDS "$WORK_DIR/capacity_metrics.tsv")"
CAPACITY_INTERVAL_COUNT="$(metric INTERVALS_USED "$WORK_DIR/capacity_metrics.tsv")"
CAPACITY_AVG_KBPS="$(metric AVERAGE_KBPS "$WORK_DIR/capacity_metrics.tsv")"
CAPACITY_P95_KBPS="$(metric P95_KBPS "$WORK_DIR/capacity_metrics.tsv")"
CAPACITY_PEAK_KBPS="$(metric PEAK_KBPS "$WORK_DIR/capacity_metrics.tsv")"

VOLUME_SERIES_TYPE="$(metric SERIES_TYPE "$WORK_DIR/volume_metrics.tsv")"
VOLUME_SAMPLE_COUNT="$(metric SAMPLE_COUNT "$WORK_DIR/volume_metrics.tsv")"
VOLUME_SAMPLED_SECONDS="$(metric SAMPLED_SECONDS "$WORK_DIR/volume_metrics.tsv")"
VOLUME_INTERVAL_COUNT="$(metric INTERVALS_USED "$WORK_DIR/volume_metrics.tsv")"
OBSERVED_VOLUME_GB="$(metric VOLUME_GB "$WORK_DIR/volume_metrics.tsv")"

REQUESTED_WINDOW_SECONDS=$(( END_EPOCH - START_EPOCH ))
AVG_SCENARIO_GB="$(LC_ALL=C awk -v rate="$CAPACITY_AVG_KBPS" -v seconds="$REQUESTED_WINDOW_SECONDS" 'BEGIN {printf "%.9f", rate*seconds/1000000}')"
P95_SCENARIO_GB="$(LC_ALL=C awk -v rate="$CAPACITY_P95_KBPS" -v seconds="$REQUESTED_WINDOW_SECONDS" 'BEGIN {printf "%.9f", rate*seconds/1000000}')"
PEAK_SCENARIO_GB="$(LC_ALL=C awk -v rate="$CAPACITY_PEAK_KBPS" -v seconds="$REQUESTED_WINDOW_SECONDS" 'BEGIN {printf "%.9f", rate*seconds/1000000}')"

if [[ "$COST_ENABLED" == "yes" ]]; then
    OBSERVED_COST="$(LC_ALL=C awk -v gb="$OBSERVED_VOLUME_GB" -v price="$PRICE_PER_GB" 'BEGIN {printf "%.6f", gb*price}')"
    AVG_SCENARIO_COST="$(LC_ALL=C awk -v gb="$AVG_SCENARIO_GB" -v price="$PRICE_PER_GB" 'BEGIN {printf "%.6f", gb*price}')"
    P95_SCENARIO_COST="$(LC_ALL=C awk -v gb="$P95_SCENARIO_GB" -v price="$PRICE_PER_GB" 'BEGIN {printf "%.6f", gb*price}')"
    PEAK_SCENARIO_COST="$(LC_ALL=C awk -v gb="$PEAK_SCENARIO_GB" -v price="$PRICE_PER_GB" 'BEGIN {printf "%.6f", gb*price}')"
else
    OBSERVED_COST="disabled"
    AVG_SCENARIO_COST="disabled"
    P95_SCENARIO_COST="disabled"
    PEAK_SCENARIO_COST="disabled"
fi

REPORT_PRICE_PER_GB="$(localize_number "$PRICE_PER_GB")"
REPORT_CAPACITY_AVG_KBPS="$(localize_number "$CAPACITY_AVG_KBPS")"
REPORT_CAPACITY_P95_KBPS="$(localize_number "$CAPACITY_P95_KBPS")"
REPORT_CAPACITY_PEAK_KBPS="$(localize_number "$CAPACITY_PEAK_KBPS")"
REPORT_OBSERVED_VOLUME_GB="$(localize_number "$OBSERVED_VOLUME_GB")"
REPORT_AVG_SCENARIO_GB="$(localize_number "$AVG_SCENARIO_GB")"
REPORT_P95_SCENARIO_GB="$(localize_number "$P95_SCENARIO_GB")"
REPORT_PEAK_SCENARIO_GB="$(localize_number "$PEAK_SCENARIO_GB")"
REPORT_OBSERVED_COST="$(localize_number "$OBSERVED_COST")"
REPORT_AVG_SCENARIO_COST="$(localize_number "$AVG_SCENARIO_COST")"
REPORT_P95_SCENARIO_COST="$(localize_number "$P95_SCENARIO_COST")"
REPORT_PEAK_SCENARIO_COST="$(localize_number "$PEAK_SCENARIO_COST")"

RUN_SUMMARY="$OUTPUT_DIR/run_summary.txt"
cat > "$RUN_SUMMARY" <<EOF
Nutanix category VM write-statistics run
=======================================
Script version:                  ${SCRIPT_VERSION}
Prism Central:                   ${PC_HOST}:${PC_PORT}
Prism Categories API:             ${PRISM_API_VERSION}
VM/Stats API:                    ${VMM_API_VERSION}
Category selection:              ${CATEGORY_SELECTION}
Category match mode:             ${MATCH_MODE}
Start time:                      ${START_TIME}
End time:                        ${END_TIME}
Requested window:                ${REQUESTED_WINDOW_SECONDS} seconds
Sampling interval:               ${SAMPLING_INTERVAL} seconds
Capacity aggregation:            ${CAPACITY_AGGREGATION} (API statType=${CAPACITY_STAT_TYPE})
Volume/cost aggregation:         AVG (API statType=${VOLUME_STAT_TYPE})
Requested volume windows:         ${VOLUME_WINDOWS}
Per-window volume report:         ${OUTPUT_DIR}/volume_windows.csv
CSV format:                       ${CSV_FORMAT} (separator=${CSV_SEPARATOR}, decimal=${CSV_DECIMAL})

Output layout:
  Relevant result files:          ${OUTPUT_DIR}
  Supporting detail files:        ${DETAILS_DIR}
  Diagnostics and raw responses:  ${DIAGNOSTICS_DIR}

Selected VMs:                    ${SELECTED_VM_COUNT}
VMs successfully resolved:       ${EXPECTED_VM_COUNT}
VM config failures:              ${VM_CONFIG_FAILURES}
Capacity stats query failures:   ${STATS_FAILURES_CAPACITY}
Volume stats query failures:     ${STATS_FAILURES_VOLUME}
Capacity VMs with empty stats:   ${EMPTY_STATS_CAPACITY}
Volume VMs with empty stats:     ${EMPTY_STATS_VOLUME}
VMs without usable capacity metrics: ${NO_METRICS_CAPACITY_COUNT}
${MISSING_CAPACITY_LIST}
VMs without usable volume metrics:   ${NO_METRICS_VOLUME_COUNT}
${MISSING_VOLUME_LIST}
Invalid capacity points:         ${INVALID_POINTS_CAPACITY}
Invalid volume points:           ${INVALID_POINTS_VOLUME}
Raw capacity points:             ${RAW_CAPACITY_POINT_COUNT}
Raw volume points:               ${RAW_VOLUME_POINT_COUNT}

Capacity metrics (aggregated VM rates)
--------------------------------------
Series used:                     ${CAPACITY_SERIES_TYPE}
Aggregate samples:               ${CAPACITY_SAMPLE_COUNT}
Effective timestamp span:       ${CAPACITY_SAMPLED_SECONDS} seconds
Sample intervals represented:    ${CAPACITY_INTERVAL_COUNT}
Average observed rate:            ${REPORT_CAPACITY_AVG_KBPS} kB/s
P95 observed rate:                ${REPORT_CAPACITY_P95_KBPS} kB/s
Peak observed rate:               ${REPORT_CAPACITY_PEAK_KBPS} kB/s

Volume and cost metrics (AVG samples)
--------------------------------------
Series used:                     ${VOLUME_SERIES_TYPE}
Aggregate samples:               ${VOLUME_SAMPLE_COUNT}
Effective timestamp span:       ${VOLUME_SAMPLED_SECONDS} seconds
AVG intervals summed for volume: ${VOLUME_INTERVAL_COUNT}
Observed sampled volume:          ${REPORT_OBSERVED_VOLUME_GB} GB
Per-window sampled AVG volumes:   ${OUTPUT_DIR}/volume_windows.csv
  The CSV reports partial coverage as-is; no volume is extrapolated.

Constant-rate scenario estimates over the requested window
-----------------------------------------------------------
Average-rate scenario volume:    ${REPORT_AVG_SCENARIO_GB} GB
P95-rate scenario volume:         ${REPORT_P95_SCENARIO_GB} GB
Peak-rate scenario volume:        ${REPORT_PEAK_SCENARIO_GB} GB

Cost estimates
--------------
Cost calculation enabled:         ${COST_ENABLED}
Price supplied:                   ${REPORT_PRICE_PER_GB} per GB
Observed sampled cost:            ${REPORT_OBSERVED_COST}
Average-rate scenario cost:       ${REPORT_AVG_SCENARIO_COST}
P95-rate scenario cost:           ${REPORT_P95_SCENARIO_COST}
Peak-rate scenario cost:          ${REPORT_PEAK_SCENARIO_COST}

Interpretation and limitations
------------------------------
- Peak is the user-facing name for the API MAX aggregation.
- P95 and Peak are capacity indicators; they are not measured billing values.
- Effective timestamp span is calculated from the first to the last selected
  aggregate timestamp; the sample count includes both endpoints.
- Observed sampled volume/cost sums one configured sampling interval for each
  returned AVG sample:
    volume_GB = sum(aggregate_rate_kBps * sampling_interval_seconds) / 1,000,000
  The number of summed intervals is shown separately above.
- Scenario volumes assume a constant rate over the complete requested window.
- Missing VM statistics are not treated as zero; the affected VM names and reasons are listed above.
- Selected VMs are never removed because statistics are missing.
- The metric is controllerWriteIoBandwidthKbps per VM. It is a workload-write
  proxy and not a direct Azure VNet-peering/SyncRep byte counter. It does not
  separately calculate data-reduction effects, replication overhead, metadata,
  retransmissions or protocol overhead.
EOF

METHODOLOGY="$OUTPUT_DIR/calculation_methodology.txt"
cat > "$METHODOLOGY" <<EOF
Calculation methodology
=======================

1. Capacity path
   The script requests statType=MAX from Prism Central. In the report this
   is called Peak. VM rates are summed by timestamp. P95 is the 95th percentile
   of those aggregate timestamp totals; Peak is the highest aggregate total.

2. Volume/cost path
   The script independently requests statType=AVG. For each aggregate sample:
       interval_volume_GB = aggregate_rate_kBps * interval_seconds / 1,000,000
   The observed sampled volume is the sum of all returned interval volumes.
   The report shows the timestamp span separately. Sample count includes both
   endpoint timestamps, while the volume calculation retains one configured
   interval per returned AVG sample.
   For each value in --volume-windows, volume_windows.csv contains the sampled
   AVG volume from samples actually present in that horizon. Partial coverage is
   reported as partial; missing time is never extrapolated.

3. Scenario costs
   Average-, P95- and Peak-rate scenario volumes assume that the respective
   rate remained constant for the complete requested window. They are useful
   for comparison, but are not measured costs.

4. Coverage
   Missing VMs or missing timestamps are not filled with zero. Selected VMs
   remain in the run; VMs without usable metrics are listed in run_summary.txt
   with their VM ID and reason. The report includes selected VMs, resolved VMs,
   sample counts and the first-to-last timestamp span. The timestamp span is
   not calculated as sample_count * sampling_interval because endpoint samples
   are inclusive.

5. CSV output
   The CSV format is selected from the system locale by default and can be
   overridden interactively, with --csv-format auto|de|us, or with CSV_FORMAT.
   DE uses semicolon separators and comma decimals; US uses comma separators
   and dot decimals. Internal calculations always use locale-independent values.

6. Output layout
   The main output directory contains the relevant result files: run_summary.txt,
   calculation_methodology.txt, aggregate_capacity_summary.csv,
   aggregate_volume_summary.csv and volume_windows.csv.
   Supporting files such as per-VM samples and category/VM mappings are stored
   under details/. Execution logs, parser diagnostics and raw API responses are
   stored under diagnostics/.

7. Interactive output and diagnostics
   Progress messages, API details and parser diagnostics are written to
   diagnostics/run.log and diagnostics/stats_diagnostics.txt. The interactive
   shell prints only prompts, errors and the concise completion summary.

8. Metric limitation
   controllerWriteIoBandwidthKbps is a workload-write sizing proxy. It is not
   a direct Azure network, SyncRep or billing counter. Data reduction,
   replication, metadata, retransmissions and protocol overhead are outside
   the calculation.
EOF

# Optional machine-readable configuration/output manifest.
MANIFEST="$OUTPUT_DIR/manifest.txt"
cat > "$MANIFEST" <<EOF
# Relevant result files
$RUN_SUMMARY
$METHODOLOGY
$OUTPUT_DIR/aggregate_capacity_summary.csv
$OUTPUT_DIR/aggregate_volume_summary.csv
$OUTPUT_DIR/volume_windows.csv

# Supporting detail files
$DETAILS_DIR/write_samples_capacity.csv
$DETAILS_DIR/write_samples_volume.csv
$VM_MAP
$CATEGORY_MATCHES_TSV

# Diagnostics and raw API responses
$STATS_DIAGNOSTICS
$RUN_LOG
$RAW_RESPONSE_DIR/capacity/
$RAW_RESPONSE_DIR/volume/
EOF

# Remove sensitive values from shell variables before exiting.
unset PC_PASS

printf '\n%sCompleted successfully.%s\n\n' "$C_OK" "$C_RESET"
printf 'Output directory:\n  %s\n\n' "$OUTPUT_DIR"
printf 'Relevant result files (start here):\n'
printf '  %s\n' \
    "$RUN_SUMMARY" \
    "$METHODOLOGY" \
    "$OUTPUT_DIR/aggregate_capacity_summary.csv" \
    "$OUTPUT_DIR/aggregate_volume_summary.csv" \
    "$OUTPUT_DIR/volume_windows.csv"
printf '\nSupporting detail files:\n  %s\n' "$DETAILS_DIR"
printf 'Diagnostics and raw API responses:\n  %s\n' "$DIAGNOSTICS_DIR"
printf '\nKey result:\n'
printf '  Average observed rate: %s kB/s\n' "$REPORT_CAPACITY_AVG_KBPS"
printf '  P95 observed rate:     %s kB/s\n' "$REPORT_CAPACITY_P95_KBPS"
printf '  Peak observed rate:    %s kB/s\n' "$REPORT_CAPACITY_PEAK_KBPS"
printf '  Observed volume:       %s GB\n' "$REPORT_OBSERVED_VOLUME_GB"
printf '  Observed sampled cost: %s\n' "$REPORT_OBSERVED_COST"
printf '  P95 scenario cost:     %s\n' "$REPORT_P95_SCENARIO_COST"
printf '  Peak scenario cost:    %s\n' "$REPORT_PEAK_SCENARIO_COST"
printf '  VMs without capacity metrics: %s\n' "$NO_METRICS_CAPACITY_COUNT"
printf '  VMs without volume metrics:   %s\n' "$NO_METRICS_VOLUME_COUNT"
printf '\nDetailed diagnostics are in:\n  %s\n' "$DIAGNOSTICS_DIR"
printf 'Reminder: this is a workload-write sizing proxy, not a direct SyncRep network-meter reading.\n'
