#!/usr/bin/env bash
#
# onedrive_pull.sh
# Pull new audio recordings from OneDrive into the NAS `totranscribe` queue,
# then delete them from OneDrive (rclone `move` = copy + verify + delete source).
#
# Designed to run hourly (cron). The nightly transcribe-workflow.service then
# transcribes whatever is queued and moves the audio to `transcribed`.
#
# Why this is safe against re-transcription:
#   * `move` drains OneDrive, so a recording is pulled exactly once.
#   * the nightly job drains `totranscribe`, so a recording is transcribed once.
#   * belt-and-suspenders: any file whose exact name already exists in
#     `transcribed/` is excluded from the pull (handles duplicate names).
#
set -uo pipefail

# ---------------- config ----------------
RCLONE="$HOME/whisper/whisper-env/bin/rclone"
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
REMOTE="onedrive"
SRC="Documents/Sound Recordings"          # OneDrive folder holding recordings

NFS_SERVER="10.0.0.136:volume1/NFS/rotation"
MOUNT_POINT="/mnt/rotation"
SOURCE_FOLDER="totranscribe"              # queue the nightly job reads
DEST_FOLDER="transcribed"                 # where finished audio ends up

AUDIO_EXTS=(m4a mp3 wav flac ogg opus aac mp4)

LOG="$HOME/whisper/whisper-env/transcribe-workflow/onedrive_pull.log"
LOCK="$HOME/whisper/whisper-env/transcribe-workflow/.onedrive_pull.lock"
TRANSCRIBE_SERVICE="transcribe-workflow.service"
# ----------------------------------------

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Serialize: never let two pulls run at once.
exec 9>"$LOCK" || { log "cannot open lock"; exit 1; }
if ! flock -n 9; then
    log "another pull is in progress; exiting"
    exit 0
fi

TODIR="$MOUNT_POINT/$SOURCE_FOLDER"
DONEDIR="$MOUNT_POINT/$DEST_FOLDER"

# Mount the NFS share if it isn't already mounted (reuses the workflow's
# passwordless-sudo rule). Track whether WE mounted it.
WE_MOUNTED=0
if ! mountpoint -q "$MOUNT_POINT"; then
    if sudo mount -t nfs "$NFS_SERVER" "$MOUNT_POINT"; then
        WE_MOUNTED=1
        log "mounted NFS $NFS_SERVER"
    else
        log "ERROR: failed to mount $NFS_SERVER"
        exit 1
    fi
fi

cleanup() {
    # Only unmount if we mounted it AND the nightly transcribe job isn't running,
    # so we never yank the share out from under a transcription.
    if [ "$WE_MOUNTED" = "1" ]; then
        if systemctl is-active --quiet "$TRANSCRIBE_SERVICE"; then
            log "transcribe job active; leaving NFS mounted"
        else
            if sudo umount "$MOUNT_POINT" 2>/dev/null; then
                log "unmounted NFS"
            else
                log "WARN: could not unmount NFS"
            fi
        fi
    fi
}
trap cleanup EXIT

if [ ! -d "$TODIR" ]; then
    log "ERROR: queue dir $TODIR missing"
    exit 1
fi

# Build an rclone filter file:
#   1. exclude any audio already present in transcribed/  (dedup guard)
#   2. include audio extensions
#   3. exclude everything else (@eaDir metadata, etc.)
FILTER="$(mktemp)"
trap 'rm -f "$FILTER"' RETURN 2>/dev/null || true
if [ -d "$DONEDIR" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] && printf -- '- /%s\n' "$f" >> "$FILTER"
    done < <(cd "$DONEDIR" && ls -1 2>/dev/null | grep -iE "\.($(IFS='|'; echo "${AUDIO_EXTS[*]}"))$")
fi
for ext in "${AUDIO_EXTS[@]}"; do
    printf -- '+ /*.%s\n' "$ext" >> "$FILTER"
done
echo '- **' >> "$FILTER"

log "pull start (src=$REMOTE:$SRC dest=$TODIR)"
"$RCLONE" --config "$RCLONE_CONF" move "$REMOTE:$SRC" "$TODIR" \
    --filter-from "$FILTER" \
    --contimeout 15s --timeout 5m --low-level-retries 3 --retries 2 \
    --log-file "$LOG" --log-level INFO </dev/null
rc=$?
rm -f "$FILTER"
if [ "$rc" -eq 0 ]; then
    log "pull done OK"
else
    log "WARN: rclone move exited $rc"
fi
exit 0
