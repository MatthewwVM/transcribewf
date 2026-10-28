#!/usr/bin/env bash
# manual-run.sh — transcribe ONE specific recording right now, through the real
# nightly pipeline (full WhisperX + speaker diarization + Ollama notes), instead
# of waiting for the 12:30am scheduled run.
#
# It is a targeted, on-demand version of the two scheduled pieces:
#   onedrive_pull.sh        (hourly)  : moves recordings OneDrive -> totranscribe/ queue
#   transcribe_workflow.py  (nightly) : transcribes the queue -> transcribed/
# This script does the pull for ONE named file, then runs the pipeline now. Because
# it reuses transcribe_workflow.py, the output is byte-for-byte the same shape as a
# nightly note (speaker labels, two-pass GPU handoff, clean markdown) — no separate
# note-generation code to drift out of sync.
#
# Usage:
#   ./manual-run.sh <recording-name>
#     <recording-name> : OneDrive recording, with or without .m4a. A unique
#                        substring also works (e.g. "langer").
#
# Examples:
#   ./manual-run.sh SE-bootccamp-feedback-langer-102826
#   ./manual-run.sh SE-bootccamp-feedback-langer-102826.m4a
#   ./manual-run.sh langer
#
# Output lands in the NAS transcribed/ share exactly like a nightly run:
#   <base>_<timestamp>.md    (AI notes + full transcript)
#   <base>_<timestamp>.txt / .json
#   <base>.m4a               (archived audio)
# Pull it into Obsidian with the "Sync Transcripts to Obsidian" scheduled task.
#
# Notes:
#  * Processes the WHOLE queue, which is normally just the file you add (the hourly
#    puller + nightly job keep it drained). Any other queued file gets done too —
#    that only drains pending work early, it never re-transcribes anything.
#  * Frees OneDrive storage: the recording is MOVED (copy + verify + delete), the
#    same as the hourly puller — so you don't go over your quota.
#  * Needs the GPU. If CUDA is down it still runs, on CPU, much slower; see the
#    gpu-cuda-804 note (the fix is a reboot).
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
# ------------------------------------------------------------------------------

QDIR="$MOUNT_POINT/$SOURCE_FOLDER"
DONEDIR="$MOUNT_POINT/$DEST_FOLDER"

die() { echo "ERROR: $*" >&2; exit 1; }

NAME="${1:-}"
[ -n "$NAME" ] || die "usage: $(basename "$0") <recording-name>  (with or without .m4a; a unique substring works)"

# Never collide with the scheduled run (same GPU, same queue).
if systemctl is-active --quiet "$TRANSCRIBE_SERVICE"; then
    die "the nightly $TRANSCRIBE_SERVICE is running right now — wait for it to finish."
fi

# --- 1. find the recording in OneDrive ----------------------------------------
echo ">> Looking for '$NAME' in OneDrive:$SRC ..."
mapfile -t MATCHES < <("$RCLONE" lsf "$REMOTE:$SRC" 2>/dev/null | grep -i -- "$NAME" || true)

EXACT=""
for m in "${MATCHES[@]:-}"; do
    case "$m" in
        "$NAME"|"$NAME".* ) EXACT="$m"; break ;;
    esac
done

if [ -n "$EXACT" ]; then
    FILE="$EXACT"
elif [ "${#MATCHES[@]}" -eq 1 ] && [ -n "${MATCHES[0]:-}" ]; then
    FILE="${MATCHES[0]}"
elif [ "${#MATCHES[@]}" -eq 0 ] || [ -z "${MATCHES[0]:-}" ]; then
    echo "Available recordings:" >&2
    "$RCLONE" lsf "$REMOTE:$SRC" 2>/dev/null | sed 's/^/  /' >&2
    die "no OneDrive recording matches '$NAME'."
else
    echo "ERROR: '$NAME' is ambiguous — matches:" >&2
    printf '  %s\n' "${MATCHES[@]}" >&2
    exit 1
fi
echo ">> Found: $FILE"
BASE="${FILE%.*}"

# --- 2. ensure the NAS is mounted (passwordless `sudo mount` rule) -------------
if ! mountpoint -q "$MOUNT_POINT"; then
    echo ">> Mounting NFS $NFS_SERVER ..."
    sudo mount -t nfs "$NFS_SERVER" "$MOUNT_POINT" || die "failed to mount NFS"
fi

# Warn (don't block) if this name was already transcribed.
if ls "$DONEDIR/${BASE}"_*.md >/dev/null 2>&1; then
    echo ">> NOTE: '$BASE' already has notes in transcribed/ — re-running adds a new timestamped copy."
fi

# --- 3. GPU sanity check (warn only) ------------------------------------------
if "$PYTHON" -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null; then
    echo ">> GPU: CUDA available."
else
    echo ">> WARNING: CUDA NOT available — this will run on CPU (very slow)."
    echo "            See the gpu-cuda-804 note; a reboot usually fixes it."
fi

# --- 4. move the recording OneDrive -> queue (frees OneDrive storage) ----------
echo ">> Moving '$FILE'  OneDrive -> $QDIR/ ..."
"$RCLONE" move "$REMOTE:$SRC/$FILE" "$QDIR/" --progress || die "rclone move failed"
[ -f "$QDIR/$FILE" ] || die "'$FILE' did not land in the queue"

# --- 5. run the real pipeline now (identical to the service's ExecStart) -------
echo ">> Running the transcription pipeline (this is the nightly job, on demand)..."
cd "$WFDIR"
set +e
PATH="$HOME/whisper/whisper-env/bin:$PATH" "$PYTHON" "$WFDIR/transcribe_workflow.py"
rc=$?
set -e

# The pipeline unmounts the NAS when it finishes; remount to report the results.
if ! mountpoint -q "$MOUNT_POINT"; then
    sudo mount -t nfs "$NFS_SERVER" "$MOUNT_POINT" 2>/dev/null || true
fi

# --- 6. report ----------------------------------------------------------------
echo "=================================================================="
if [ "$rc" -eq 0 ]; then
    echo ">> Done. Outputs for '$BASE' now in $DONEDIR/ :"
    ls -1 "$DONEDIR/${BASE}"_* 2>/dev/null | sed 's/^/   /' || echo "   (none found — check $WFDIR/onedrive_pull.log or the journal)"
    echo ">> Pull into Obsidian:  Start-ScheduledTask -TaskName \"Sync Transcripts to Obsidian\""
else
    echo ">> Pipeline exited $rc. '$FILE' is still queued in $QDIR and the nightly run will retry it."
fi
exit "$rc"
