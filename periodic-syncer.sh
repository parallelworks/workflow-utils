#!/usr/bin/env bash
#
# pw_periodic_sync_multicloud.sh
#
# Periodically mirror a local directory to a destination that is EITHER:
#   * a filesystem path   (e.g. /home/user/backups)   -> uses `rsync`
#   * a PW bucket URI      (e.g. pw://user/bucket/sub) -> uses
#       `pw buckets get-token` to obtain short-term credentials, then the
#       provider-native tool:
#         AWS   -> aws s3 sync
#         GCS   -> gcloud storage rsync
#         Azure -> azcopy sync
#
# The destination type is auto-detected from the string (the "pw://" scheme).
# For buckets, the cloud provider AND the real bucket URI are discovered at
# sync time from the get-token output, so you never hard-code the provider.
#
# Every INTERVAL seconds the script refreshes credentials and runs one sync.
# The sync call BLOCKS the loop, so a long-running sync delays the next cycle
# rather than overlapping. A warning is printed if a sync exceeds a threshold.
#
# Usage:
#   ./pw_periodic_sync_multicloud.sh -i INTERVAL -s SOURCE -d DESTINATION [options]
#
# Required:
#   -i INTERVAL      Seconds between the START of each sync cycle.
#   -s SOURCE        Local source directory (e.g. ~/pw/outputs).
#   -d DESTINATION   Filesystem path OR pw:// bucket URI.
#
# Optional:
#   -w WARN_SECONDS  Warn if a single sync exceeds this many seconds.
#                    Default: 21600 (6 hours).
#   -e EXTRA_ARGS    Extra args passed verbatim to the underlying tool. Note
#                    each tool takes different flags: rsync / aws s3 sync /
#                    gcloud storage rsync / azcopy sync. Quote the whole string.
#   -1               Run a single sync and exit (no loop).
#   -h               Show this help.
#
# Notes:
#   * Requires the `pw` CLI (authenticated) for bucket destinations, plus the
#     relevant provider CLI (aws / gcloud / azcopy). On PW resources the PW CLI
#     is authenticated automatically in the run environment.
#   * PW bucket credentials are short-lived (AWS ~12h). Refreshing every cycle
#     keeps each sync authenticated; only a single sync longer than the token
#     lifetime is at risk.

set -uo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
INTERVAL=""
SOURCE=""
DEST=""
WARN_SECONDS=21600          # 6 hours
EXTRA_ARGS=""
ONESHOT=0

# ----------------------------------------------------------------------------
# Logging helpers
# ----------------------------------------------------------------------------
log()  { printf '%s [INFO]  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
human() { local s=$1; printf '%dh%02dm%02ds' $((s/3600)) $(((s%3600)/60)) $((s%60)); }

usage() {
    sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ----------------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------------
while getopts ":i:s:d:w:e:1h" opt; do
    case "$opt" in
        i) INTERVAL="$OPTARG" ;;
        s) SOURCE="$OPTARG" ;;
        d) DEST="$OPTARG" ;;
        w) WARN_SECONDS="$OPTARG" ;;
        e) EXTRA_ARGS="$OPTARG" ;;
        1) ONESHOT=1 ;;
        h) usage 0 ;;
        \?) err "Unknown option: -$OPTARG"; usage 1 ;;
        :)  err "Option -$OPTARG requires an argument."; usage 1 ;;
    esac
done

# ----------------------------------------------------------------------------
# Validate
# ----------------------------------------------------------------------------
[ -z "$INTERVAL" ] && [ "$ONESHOT" -eq 0 ] && { err "Missing -i INTERVAL."; usage 1; }
[ -z "$SOURCE"   ] && { err "Missing -s SOURCE.";      usage 1; }
[ -z "$DEST"     ] && { err "Missing -d DESTINATION."; usage 1; }

if [ "$ONESHOT" -eq 0 ]; then
    if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -le 0 ]; then
        err "INTERVAL must be a positive integer (seconds)."; exit 1
    fi
fi
if ! [[ "$WARN_SECONDS" =~ ^[0-9]+$ ]]; then
    err "WARN_SECONDS must be a non-negative integer (seconds)."; exit 1
fi
[ -d "$SOURCE" ] || { err "Source directory does not exist: $SOURCE"; exit 1; }

# ----------------------------------------------------------------------------
# Detect destination type
# ----------------------------------------------------------------------------
# PW bucket URIs look like:  pw://<user>/<bucket>[/optional/path]
# Anything else is treated as a filesystem path.
IS_BUCKET=0
case "$DEST" in
    pw://*) IS_BUCKET=1 ;;
    *)      IS_BUCKET=0 ;;
esac

if [ "$IS_BUCKET" -eq 1 ]; then
    command -v pw >/dev/null 2>&1 || { err "'pw' CLI not found; cannot sync to a bucket."; exit 1; }
    log "Destination is a PW bucket: $DEST"
    log "  (provider and CSP URI resolved from credentials each cycle)"
else
    command -v rsync >/dev/null 2>&1 || warn "rsync not found; filesystem syncs will fail."
    log "Destination is a filesystem path: $DEST"
fi

# ----------------------------------------------------------------------------
# Credential loader (bucket mode only)
# ----------------------------------------------------------------------------
# `pw buckets get-token` prints shell-ready `export VAR=value` lines on STDOUT,
# and human-readable hints (e.g. "To use the gcloud CLI...") on STDERR. We
# capture STDOUT ONLY so prose can't be sourced, then defensively keep only
# well-formed `export VAR=` lines before sourcing. This avoids errors like
# `line N: To: command not found` from sourcing prose. Stderr is captured
# separately and surfaced only on failure.
load_credentials() {
    local creds errout
    errout="$(mktemp)"
    if ! creds="$(pw buckets get-token "$DEST" 2>"$errout")"; then
        err "pw buckets get-token failed for $DEST:"; err "$(cat "$errout")"
        rm -f "$errout"; return 1
    fi
    rm -f "$errout"
    [ -z "$creds" ] && { err "get-token returned no output on stdout."; return 1; }

    local export_lines
    export_lines="$(printf '%s\n' "$creds" \
        | grep -E '^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=')"
    if [ -z "$export_lines" ]; then
        err "get-token stdout had no 'export VAR=' lines; not sourcing:"
        err "$creds"; return 1
    fi
    # shellcheck disable=SC1090
    source <(printf '%s\n' "$export_lines")
}

# ----------------------------------------------------------------------------
# Resolve provider + destination URI from sourced credentials
# ----------------------------------------------------------------------------
# After load_credentials, exactly one provider's variables are present. All
# providers emit the REAL bucket as BUCKET_URI (the pw:// name is NOT the actual
# cloud bucket name), so we use BUCKET_URI and append any sub-path from the
# pw:// URI for prefix targeting.
#   AWS  : AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (+ AWS_SESSION_TOKEN)
#          + BUCKET_URI=s3://...   -> aws s3 sync <src> <BUCKET_URI>/<path>
#   GCS  : CLOUDSDK_AUTH_ACCESS_TOKEN + BUCKET_URI=gs://...
#          -> gcloud storage rsync --recursive <src> <BUCKET_URI>/<path>
#   Azure: SAS token + BUCKET_URI=https://...blob.core.windows.net/...
#          -> azcopy sync <src> "<BUCKET_URI>/<path>?<SAS>"
# Sets PROVIDER, CSP_URI, CSP_TOOL_DESC. Returns 0 on success, 1 otherwise.
resolve_provider() {
    # Sub-path after the bucket from the pw:// URI (pw://user/bucket/sub -> /sub).
    local no_scheme no_user bkt
    no_scheme="${DEST#pw://}"            # user/bucket/sub/dir
    no_user="${no_scheme#*/}"            # bucket/sub/dir
    bkt="${no_user%%/*}"                 # bucket
    DEST_SUBPATH="${no_user#"$bkt"}"     # /sub/dir  (or empty)

    if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        PROVIDER="aws"
        # Use the real bucket URI from get-token (e.g. s3://663ba9...). The pw://
        # name is NOT the actual cloud bucket, so deriving s3://<name> fails with
        # NoSuchBucket. Fall back to deriving only if BUCKET_URI is absent.
        if [ -n "${BUCKET_URI:-}" ]; then
            CSP_URI="${BUCKET_URI%/}${DEST_SUBPATH}"
        else
            CSP_URI="s3://${bkt}${DEST_SUBPATH}"
        fi
        CSP_TOOL_DESC="aws s3 sync"
        command -v aws >/dev/null 2>&1 || { err "'aws' CLI not found."; return 1; }
    elif [ -n "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}" ] && [ -n "${BUCKET_URI:-}" ]; then
        PROVIDER="google"
        CSP_URI="${BUCKET_URI%/}${DEST_SUBPATH}"
        CSP_TOOL_DESC="gcloud storage rsync"
        command -v gcloud >/dev/null 2>&1 || { err "'gcloud' CLI not found."; return 1; }
    elif [ -n "${AZURE_STORAGE_SAS_TOKEN:-}" ] || [ -n "${AZURE_STORAGE_CONNECTION_STRING:-}" ] || [ -n "${BUCKET_URI:-}" ]; then
        PROVIDER="azure"
        # NOTE: Azure get-token output is not yet verified against the platform.
        # Assumes BUCKET_URI=https://...blob.core.windows.net/<container> and a
        # SAS in AZURE_STORAGE_SAS_TOKEN. Adjust here once confirmed.
        CSP_URI="${BUCKET_URI%/}${DEST_SUBPATH}"
        CSP_TOOL_DESC="azcopy sync"
        command -v azcopy >/dev/null 2>&1 || { err "'azcopy' CLI not found."; return 1; }
    else
        err "Could not determine cloud provider from get-token output."
        err "Expected AWS_*, CLOUDSDK_AUTH_ACCESS_TOKEN+BUCKET_URI, or Azure vars."
        return 1
    fi
    return 0
}

# Run the provider-specific sync. BLOCKS until it completes.
run_bucket_sync() {
    case "$PROVIDER" in
        aws)
            # shellcheck disable=SC2086
            aws s3 sync "$SOURCE" "$CSP_URI" $EXTRA_ARGS
            ;;
        google)
            # gcloud uses CLOUDSDK_AUTH_ACCESS_TOKEN from the environment.
            # shellcheck disable=SC2086
            gcloud storage rsync --recursive $EXTRA_ARGS "$SOURCE" "$CSP_URI"
            ;;
        azure)
            local target="$CSP_URI"
            if [ -n "${AZURE_STORAGE_SAS_TOKEN:-}" ]; then
                case "$CSP_URI" in
                    *\?*) target="${CSP_URI}&${AZURE_STORAGE_SAS_TOKEN#\?}" ;;
                    *)    target="${CSP_URI}?${AZURE_STORAGE_SAS_TOKEN#\?}" ;;
                esac
            fi
            # shellcheck disable=SC2086
            azcopy sync "$SOURCE" "$target" $EXTRA_ARGS
            ;;
        *)
            err "Unknown provider '$PROVIDER'."; return 1 ;;
    esac
}

# ----------------------------------------------------------------------------
# One sync iteration. Returns the tool's exit code (or 98/99 for setup errors).
# BLOCKS until the sync completes.
# ----------------------------------------------------------------------------
do_sync() {
    if [ "$IS_BUCKET" -eq 1 ]; then
        log "Refreshing bucket credentials..."
        load_credentials || return 99
        resolve_provider || return 98
        log "Provider: $PROVIDER | tool: $CSP_TOOL_DESC"
        log "Starting bucket sync: $SOURCE -> $CSP_URI"
        run_bucket_sync
    else
        log "Starting filesystem sync: $SOURCE -> $DEST"
        mkdir -p "$DEST" 2>/dev/null || true
        # -a archive, -z compress; --delete is NOT default (add via -e extra args).
        # shellcheck disable=SC2086
        rsync -az $EXTRA_ARGS "$SOURCE" "$DEST"
    fi
}

# Evaluate one sync's result + duration, printing the right message/warning.
report_sync() {
    local rc=$1 dur=$2
    if [ "$rc" -eq 99 ]; then
        err "Could not obtain credentials."
    elif [ "$rc" -eq 98 ]; then
        err "Could not determine cloud provider from credentials."
    elif [ "$rc" -ne 0 ]; then
        err "Sync tool exited with code $rc after $(human "$dur")."
    else
        log "Sync completed in $(human "$dur")."
    fi
    if [ "$dur" -gt "$WARN_SECONDS" ]; then
        warn "Sync took $(human "$dur"), exceeding the $(human "$WARN_SECONDS") threshold."
        [ "$IS_BUCKET" -eq 1 ] && warn "Note: PW bucket credentials are short-lived (AWS ~12h); a single sync longer than the token lifetime may fail partway. Credentials are refreshed each cycle."
    fi
}

# ----------------------------------------------------------------------------
# One-shot mode
# ----------------------------------------------------------------------------
if [ "$ONESHOT" -eq 1 ]; then
    start=$(date +%s)
    do_sync
    rc=$?
    report_sync "$rc" "$(( $(date +%s) - start ))"
    [ "$rc" -ge 98 ] && exit 1
    exit "$rc"
fi

# ----------------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------------
log "Starting periodic syncer."
log "  source:     $SOURCE"
log "  interval:   ${INTERVAL}s"
log "  warn after: ${WARN_SECONDS}s ($(human "$WARN_SECONDS"))"
[ -n "$EXTRA_ARGS" ] && log "  extra args: $EXTRA_ARGS"

# Trap signals so an in-flight sync finishes before we exit.
RUNNING=1
trap 'warn "Signal received; exiting after current sync."; RUNNING=0' INT TERM

while [ "$RUNNING" -eq 1 ]; do
    cycle_start=$(date +%s)

    sync_start=$(date +%s)
    do_sync            # BLOCKING: next cycle waits for this to finish
    rc=$?
    report_sync "$rc" "$(( $(date +%s) - sync_start ))"

    [ "$RUNNING" -eq 1 ] || break

    # Sleep the remainder of the interval, measured from cycle start. If the
    # sync overran the interval, start the next cycle immediately.
    elapsed=$(( $(date +%s) - cycle_start ))
    remaining=$(( INTERVAL - elapsed ))
    if [ "$remaining" -gt 0 ]; then
        log "Sleeping ${remaining}s until next cycle."
        i=0
        while [ "$i" -lt "$remaining" ] && [ "$RUNNING" -eq 1 ]; do
            sleep 1; i=$((i+1))
        done
    else
        log "Cycle ran ${elapsed}s (>= ${INTERVAL}s); starting next cycle now."
    fi
done

log "Syncer exited cleanly."

