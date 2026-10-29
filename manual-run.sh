#!/usr/bin/env bash
# manual-run.sh — transcribe ONE specific recording right now, through the real
# nightly pipeline (full WhisperX + speaker diarization + Ollama notes), instead
# of waiting for the 12:30am scheduled run.
#
# It is a targeted, on-demand version of the two scheduled pieces:
#   onedrive_pull.sh        (hourly)  : moves recordings OneDrive -> totranscribe/ queue
#   transcribe_workflow.py  (nightly) : transcribes the queue -> transcribed/
# Because it reuses transcribe_workflow.py, the output is the same shape as a
# nightly note (speaker labels, two-pass GPU handoff, clean markdown).
#
# Usage:
#   ./manual-run.sh <recording-name>
#     <recording-name> : the recording, with or without .m4a. A unique substring
#                        also works (e.g. "brumm").
#
# It finds the recording wherever it currently is:
#   1. the NAS queue (totranscribe/)  -- the hourly puller may have already grabbed it
#   2. OneDrive                       -- not pulled yet; it gets MOVED into the queue
#   3. transcribed/                   -- already done; it tells you and stops
#
# Only the recording you name is transcribed. If other files are sitting in the
# queue (waiting for tonight), they are moved aside for the run and put straight
# back — so a daytime manual run never burns GPU time on the whole backlog.
#
# Output lands in the NAS transcribed/ share exactly like a nightly run:
#   <base>_<timestamp>.md    (AI notes + full transcript)
#   <base>_<timestamp>.txt / .json
#   <base>.m4a               (archived audio)
# Pull it into Obsidian with the "Sync Transcripts to Obsidian" scheduled task.
#
# Needs the GPU. If CUDA is down it still runs, on CPU, much slower; see the
# gpu-cuda-804 note (the fix is a reboot).
set -euo pipefail

# --- config (mirrors onedrive_pull.sh) ----------------------------------------
WFDIR="$HOME/whisper/whisper-env/transcribe-workflow"
RCLONE="$HOME/whisper/whisper-env/bin/rclone"
PYTHON="$HOME/whisper/whisper-env/bin/python3"
REMOTE="onedrive"
SRC="Documents/Sound Recordings"            # OneDrive folder holding recordings
NFS_SERVER="10.0.0.136:volume1/NFS/rotation"
MOUNT_POINT="/mnt/rotation"
SOURCE_FOLDER="totranscribe"                # queue the pipeline reads
DEST_FOLDER="transcribed"                   # where finished output ends up
TRANSCRIBE_SERVICE="transcribe-workflow.service"
AUDIO_EXTS=(m4a mp3 wav flac ogg opus aac mp4)
LOCK="$WFDIR/.manual_run.lock"              # serialize manual runs (one GPU)
# ------------------------------------------------------------------------------

QDIR="$MOUNT_POINT/$SOURCE_FOLDER"
DONEDIR="$MOUNT_POINT/$DEST_FOLDER"
HOLD="$MOUNT_POINT/.manualrun_hold"         # same FS as the queue -> mv is instant

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_mount() {
    mountpoint -q "$MOUNT_POINT" && return 0
    echo ">> Mounting NFS $NFS_SERVER ..."
    sudo mount -t nfs "$NFS_SERVER" "$MOUNT_POINT" || die "failed to mount NFS"
}

# Resolve a <name> against a newline-separated list of filenames.
# Prints the single chosen filename, or returns 1 (none) / 2 (ambiguous).
resolve_one() {
    local name="$1" list="$2" exact="" m
    local -a hits=()
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        case "$m" in "$name"|"$name".* ) exact="$m" ;; esac
        hits+=("$m")
    done < <(printf '%s\n' "$list" | grep -i -- "$name" || true)
    if [ -n "$exact" ]; then printf '%s\n' "$exact"; return 0; fi
    case "${#hits[@]}" in
        1) printf '%s\n' "${hits[0]}"; return 0 ;;
        0) return 1 ;;
        *) printf '%s\n' "${hits[@]}" >&2; return 2 ;;
    esac
}

NAME="${1:-}"
[ -n "$NAME" ] || die "usage: $(basename "$0") <recording-name>  (with or without .m4a; a unique substring works)"

# Serialize: never let two manual runs fight over the one GPU (an overlap OOMs
# both and, worse, the second run's cleanup would restore the files the first
# one set aside). Hold fd 9 for the whole script; released automatically on exit.
exec 9>"$LOCK" || die "cannot open lock $LOCK"
if ! flock -n 9; then
    die "another manual-run.sh is already running (GPU busy) — wait for it to finish."
fi

# Never collide with the scheduled run either (same GPU, same queue).
if systemctl is-active --quiet "$TRANSCRIBE_SERVICE"; then
    die "the nightly $TRANSCRIBE_SERVICE is running right now — wait for it to finish."
fi

ensure_mount

# --- 1. find the recording: queue -> OneDrive -> already-transcribed ----------
FILE=""; FROM=""

# 1a. already in the NAS queue? (the hourly puller may have grabbed it)
queue_list="$(cd "$QDIR" 2>/dev/null && ls -1 2>/dev/null || true)"
if hit="$(resolve_one "$NAME" "$queue_list")"; then
    FILE="$hit"; FROM="queue"
elif [ "$?" -eq 2 ]; then
    die "'$NAME' matches more than one file already in the queue (listed above)."
fi

# 1b. else in OneDrive?
if [ -z "$FILE" ]; then
    od_list="$("$RCLONE" lsf "$REMOTE:$SRC" 2>/dev/null || true)"
    if hit="$(resolve_one "$NAME" "$od_list")"; then
        FILE="$hit"; FROM="onedrive"
    elif [ "$?" -eq 2 ]; then
        die "'$NAME' matches more than one OneDrive recording (listed above)."
    fi
fi

# 1c. else already transcribed?
if [ -z "$FILE" ]; then
    done_hit="$(ls -1 "$DONEDIR" 2>/dev/null | grep -i -- "$NAME" | head -1 || true)"
    if [ -n "$done_hit" ]; then
        echo ">> '$NAME' has already been transcribed — see $DONEDIR/ (e.g. $done_hit)."
        echo "   To redo it, re-run this script against the archived .m4a there."
        exit 0
    fi
fi

# 1d. nowhere to be found
if [ -z "$FILE" ]; then
    echo "No recording matches '$NAME'." >&2
    echo "OneDrive:" >&2; "$RCLONE" lsf "$REMOTE:$SRC" 2>/dev/null | sed 's/^/  /' >&2 || true
    echo "Queue ($QDIR):" >&2; printf '%s\n' "$queue_list" | sed 's/^/  /' >&2
    exit 1
fi

echo ">> Found '$FILE' (${FROM})."
BASE="${FILE%.*}"

# --- 2. make sure the recording is staged in the queue ------------------------
if [ "$FROM" = "onedrive" ]; then
    echo ">> Moving '$FILE'  OneDrive -> $QDIR/  (frees OneDrive storage) ..."
    "$RCLONE" move "$REMOTE:$SRC/$FILE" "$QDIR/" --progress || die "rclone move failed"
fi
[ -f "$QDIR/$FILE" ] || die "'$FILE' is not in the queue after staging"

# --- 3. isolate it: move every OTHER queued audio file aside, restore on exit -
restore_held() {
    ensure_mount >/dev/null 2>&1 || true
    [ -d "$HOLD" ] || return 0
    shopt -s nullglob
    local f n=0
    for f in "$HOLD"/*; do mv -f "$f" "$QDIR/" 2>/dev/null && n=$((n+1)); done
    shopt -u nullglob
    rmdir "$HOLD" 2>/dev/null || true
    [ "$n" -gt 0 ] && echo ">> Restored $n other file(s) to the queue."
}
trap restore_held EXIT

mkdir -p "$HOLD"
held=0
shopt -s nullglob
for ext in "${AUDIO_EXTS[@]}"; do
    for f in "$QDIR"/*."$ext"; do
        [ "$(basename "$f")" = "$FILE" ] && continue
        mv -f "$f" "$HOLD/" && held=$((held+1))
    done
done
shopt -u nullglob
[ "$held" -gt 0 ] && echo ">> Set aside $held other queued file(s); only '$FILE' will run now."

# --- 4. GPU sanity check (warn only) ------------------------------------------
if "$PYTHON" -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    echo ">> GPU: CUDA available."
else
    echo ">> WARNING: CUDA NOT available — this will run on CPU (very slow)."
    echo "            See the gpu-cuda-804 note; a reboot usually fixes it."
fi

# --- 5. run the real pipeline now (identical to the service's ExecStart) ------
echo ">> Running the transcription pipeline on '$FILE' ..."
cd "$WFDIR"
set +e
PATH="$HOME/whisper/whisper-env/bin:$PATH" "$PYTHON" "$WFDIR/transcribe_workflow.py"
rc=$?
set -e

# The pipeline unmounts the NAS when it finishes; the EXIT trap remounts and
# restores the held files. Remount here too so we can report.
ensure_mount

# --- 6. report ----------------------------------------------------------------
echo "=================================================================="
if [ "$rc" -eq 0 ]; then
    echo ">> Done. Outputs for '$BASE' now in $DONEDIR/ :"
    ls -1 "$DONEDIR/${BASE}"_* 2>/dev/null | sed 's/^/   /' || echo "   (none found — check $WFDIR/onedrive_pull.log or the journal)"
    echo ">> Pull into Obsidian:  Start-ScheduledTask -TaskName \"Sync Transcripts to Obsidian\""
else
    echo ">> Pipeline exited $rc. '$FILE' is still queued in $QDIR; the nightly run will retry it."
fi
exit "$rc"
