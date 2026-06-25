#!/usr/bin/env bash
#
# pw_periodic_sync.sh
#
# Periodically sync a local directory to a Parallel Works cloud bucket.
# Every INTERVAL seconds the script refreshes short-term credentials via
# `pw buckets get-token` and runs `aws s3 sync`. The sync call BLOCKS the
# loop, so a long-running sync will simply delay the next iteration rather
# than overlapping with it. If any sync runs longer than the warning
# threshold (default 6h), a warning is printed.
#
# Usage:
#   ./pw_periodic_sync.sh -i INTERVAL -s SOURCE -b BUCKET_URI [options]
#
# Required:
#   -i INTERVAL      Seconds between the START of each sync cycle.
#   -s SOURCE        Local source directory (e.g. ./data).
#   -b BUCKET_URI    Bucket URI. Accepts a PW URI (pw://ns/bucket) for the
#                    get-token call; the S3 destination is derived from it,
#                    or pass -d to set the s3:// destination explicitly.
#
# Optional:
#   -d DEST          Explicit s3:// destination (e.g. s3://my-bucket/path).
#                    Defaults to the bucket URI if it already starts s3://.
#   -w WARN_SECONDS  Warn if a single sync exceeds this many seconds.
#                    Default: 21600 (6 hours).
#   -e EXTRA_ARGS    Extra args passed verbatim to `aws s3 sync`
#                    (e.g. "--delete --exclude *.tmp"). Quote the whole thing.
#   -h               Show this help.
#
# Notes:
#   * AWS bucket credentials from PW expire after 12h; refreshing every
#     cycle (well under that) keeps each sync authenticated.
#   * INTERVAL is measured from the start of one cycle to the start of the
#     next. If a sync takes longer than INTERVAL, the next cycle starts
#     immediately after it finishes (no overlap, no skipped data).

set -uo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
INTERVAL=""
SOURCE=""
BUCKET_URI=""
DEST=""
WARN_SECONDS=21600          # 6 hours
EXTRA_ARGS=""

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '%s [INFO]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '%s [WARN]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ----------------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------------
while getopts ":i:s:b:d:w:e:h" opt; do
    case "$opt" in
        i) INTERVAL="$OPTARG" ;;
        s) SOURCE="$OPTARG" ;;
        b) BUCKET_URI="$OPTARG" ;;
        d) DEST="$OPTARG" ;;
        w) WARN_SECONDS="$OPTARG" ;;
        e) EXTRA_ARGS="$OPTARG" ;;
        h) usage 0 ;;
        \?) err "Unknown option: -$OPTARG"; usage 1 ;;
        :)  err "Option -$OPTARG requires an argument."; usage 1 ;;
    esac
done

# ----------------------------------------------------------------------------
# Validate
# ----------------------------------------------------------------------------
[[ -z "$INTERVAL"   ]] && { err "Missing -i INTERVAL.";   usage 1; }
[[ -z "$SOURCE"     ]] && { err "Missing -s SOURCE.";     usage 1; }
[[ -z "$BUCKET_URI" ]] && { err "Missing -b BUCKET_URI."; usage 1; }

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [[ "$INTERVAL" -le 0 ]]; then
    err "INTERVAL must be a positive integer (seconds)."; exit 1
fi
if ! [[ "$WARN_SECONDS" =~ ^[0-9]+$ ]]; then
    err "WARN_SECONDS must be a non-negative integer (seconds)."; exit 1
fi
if [[ ! -d "$SOURCE" ]]; then
    err "Source directory does not exist: $SOURCE"; exit 1
fi
command -v pw  >/dev/null 2>&1 || { err "'pw' CLI not found on PATH.";  exit 1; }
command -v aws >/dev/null 2>&1 || { err "'aws' CLI not found on PATH."; exit 1; }

# Derive the s3:// destination if not given explicitly.
if [[ -z "$DEST" ]]; then
    if [[ "$BUCKET_URI" == s3://* ]]; then
        DEST="$BUCKET_URI"
    else
        err "Bucket URI is not an s3:// URI; please supply -d s3://... as the destination."
        exit 1
    fi
fi

# ----------------------------------------------------------------------------
# Credential loading
# ----------------------------------------------------------------------------
# `pw buckets get-token <uri>` prints short-term credentials to stdout as
# shell-ready `export ENV_VAR=value` lines, so we capture that output and
# source it directly into the current shell. We capture into a variable
# first (rather than piping straight into `source`) so that a non-zero exit
# from get-token is detected before we eval anything, and so a partial/empty
# output doesn't get sourced.
load_credentials() {
    local creds
    if ! creds="$(pw buckets get-token "$BUCKET_URI" 2>&1)"; then
        err "pw buckets get-token failed for $BUCKET_URI:"
        err "$creds"
        return 1
    fi

    if [[ -z "$creds" ]]; then
        err "pw buckets get-token returned no output for $BUCKET_URI."
        return 1
    fi

    # Sanity check: we expect at least one `export ...` line. This guards
    # against sourcing an unexpected message (e.g. an auth prompt or error
    # that still exited 0).
    if ! grep -q '^[[:space:]]*export[[:space:]]' <<<"$creds"; then
        err "get-token output did not contain any 'export' lines; not sourcing."
        err "Raw output was:"
        err "$creds"
        return 1
    fi

    # Source the export lines into the current shell.
    # shellcheck disable=SC1090  # sourcing dynamic content by design.
    source <(printf '%s\n' "$creds")
    return 0
}

# ----------------------------------------------------------------------------
# Graceful shutdown
# ----------------------------------------------------------------------------
RUNNING=1
trap 'warn "Signal received; will exit after the current sync completes."; RUNNING=0' INT TERM

# Format seconds as Hh Mm Ss for readable logs.
human() {
    local s=$1
    printf '%dh%02dm%02ds' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

# ----------------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------------
log "Starting periodic sync."
log "  source:        $SOURCE"
log "  bucket URI:    $BUCKET_URI"
log "  destination:   $DEST"
log "  interval:      ${INTERVAL}s"
log "  warn after:    ${WARN_SECONDS}s ($(human "$WARN_SECONDS"))"
[[ -n "$EXTRA_ARGS" ]] && log "  extra args:    $EXTRA_ARGS"

while [[ "$RUNNING" -eq 1 ]]; do
    cycle_start=$(date +%s)

    log "Refreshing credentials..."
    if ! load_credentials; then
        err "Skipping this cycle due to credential failure."
    else
        log "Starting sync: $SOURCE -> $DEST"
        sync_start=$(date +%s)

        # Blocking call: the loop will not proceed until aws s3 sync returns.
        # shellcheck disable=SC2086  # EXTRA_ARGS is intentionally word-split.
        aws s3 sync "$SOURCE" "$DEST" $EXTRA_ARGS
        sync_rc=$?

        sync_end=$(date +%s)
        sync_dur=$((sync_end - sync_start))

        if [[ "$sync_rc" -ne 0 ]]; then
            err "aws s3 sync exited with code $sync_rc after $(human "$sync_dur")."
        else
            log "Sync completed in $(human "$sync_dur")."
        fi

        if [[ "$sync_dur" -gt "$WARN_SECONDS" ]]; then
            warn "Sync took $(human "$sync_dur"), exceeding the $(human "$WARN_SECONDS") threshold."
            warn "Note: PW AWS credentials expire after 12h; very long syncs may outlast them."
        fi
    fi

    # Stop here if a signal arrived during the sync.
    [[ "$RUNNING" -eq 1 ]] || break

    # Sleep for the remainder of the interval, measured from cycle start.
    # If the sync already overran the interval, start the next cycle now.
    cycle_end=$(date +%s)
    elapsed=$((cycle_end - cycle_start))
    remaining=$((INTERVAL - elapsed))

    if [[ "$remaining" -gt 0 ]]; then
        log "Sleeping ${remaining}s until next cycle."
        # Sleep in 1s steps so signals interrupt promptly.
        for ((i=0; i<remaining && RUNNING==1; i++)); do sleep 1; done
    else
        log "Cycle ran ${elapsed}s (>= ${INTERVAL}s interval); starting next cycle now."
    fi
done

log "Exited cleanly."

