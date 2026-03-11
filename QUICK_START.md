# Quick Start Guide - Transcription Workflow

## Installation (One-Time Setup)

```bash
# 1. Activate the virtual environment
source bin/activate

# 2. Configure your settings
cp .env.example .env
nano .env  # Edit with your NFS server, models, etc.

# 3. (Optional) Enable WhisperX with speaker diarization
# In .env, set:
#   USE_WHISPERX=true
#   ENABLE_SPEAKER_DIARIZATION=true
#   HUGGINGFACE_TOKEN=hf_your_token_here
# Get token from: https://huggingface.co/settings/tokens
# Accept agreement: https://huggingface.co/pyannote/speaker-diarization

# 4. Run the setup script
./setup_transcription_workflow.sh

# 5. Configure sudo for NFS mounting (add to /etc/sudoers using 'sudo visudo')
# Replace with YOUR NFS server path from .env file
matt ALL=(ALL) NOPASSWD: /bin/mount -t nfs YOUR_NFS_SERVER /mnt/rotation
matt ALL=(ALL) NOPASSWD: /bin/umount /mnt/rotation

# Example:
# matt ALL=(ALL) NOPASSWD: /bin/mount -t nfs 10.0.0.136\:volume1/NFS/rotation /mnt/rotation
# matt ALL=(ALL) NOPASSWD: /bin/umount /mnt/rotation

# 6. Verify installation
./test_workflow.sh
```

## Daily Usage

**The workflow runs automatically at midnight!**

Just place audio files in: `/mnt/rotation/totranscribe`

Results will appear in: `/mnt/rotation/transcribed`

## Manual Run

```bash
# Run immediately (don't wait for midnight)
sudo systemctl start transcribe-workflow.service

# Or run the script directly
./transcribe_workflow.py
```

## Monitoring

```bash
# Check when next run is scheduled
sudo systemctl list-timers | grep transcribe

# View live logs
sudo journalctl -u transcribe-workflow.service -f

# Or check the log file
tail -f /var/log/transcribe_workflow.log
```

## Common Commands

| Task | Command |
|------|---------|
| Check timer status | `sudo systemctl status transcribe-workflow.timer` |
| Check service status | `sudo systemctl status transcribe-workflow.service` |
| Run now | `sudo systemctl start transcribe-workflow.service` |
| View logs | `sudo journalctl -u transcribe-workflow.service` |
| Stop timer | `sudo systemctl stop transcribe-workflow.timer` |
| Start timer | `sudo systemctl start transcribe-workflow.timer` |
| Disable auto-run | `sudo systemctl disable transcribe-workflow.timer` |
| Enable auto-run | `sudo systemctl enable transcribe-workflow.timer` |

## Output Files

For each audio file `recording.m4a`, you'll get:

- `recording_TIMESTAMP.txt` - Plain text transcription
- `recording_TIMESTAMP.json` - Full data with timestamps
- `recording_TIMESTAMP.md` - Formatted markdown note
- `recording.m4a` - Original file (moved to transcribed folder)

## Troubleshooting

### NFS won't mount
```bash
# Test connectivity
ping 10.0.0.136

# Check NFS exports
showmount -e 10.0.0.136

# Try manual mount
sudo mount -t nfs 10.0.0.136:/NFS/rotation /mnt/rotation
```

### Ollama not working
```bash
# Check if running
systemctl status ollama

# Test it
ollama run llama2 "test"
```

### Check what went wrong
```bash
# View detailed logs
sudo journalctl -u transcribe-workflow.service -n 50

# Check log file
cat /var/log/transcribe_workflow.log
```

## Configuration

Edit `.env` file to change settings:

```bash
nano .env
```

### Essential Settings:
- `NFS_SERVER` - Your NFS server and path
- `WHISPER_MODEL` - Model size (tiny/base/small/medium/large)
- `OLLAMA_MODEL` - AI model for notes (recommended: qwen2.5:14b)

### WhisperX Settings (Optional):
- `USE_WHISPERX=true` - Enable WhisperX for speaker diarization
- `ENABLE_SPEAKER_DIARIZATION=true` - Identify different speakers
- `HUGGINGFACE_TOKEN=hf_xxx` - Your HuggingFace token

### Other Options:
- `ENABLE_OLLAMA` - Set to `false` to skip AI note generation

After changes, reload:
```bash
sudo systemctl daemon-reload
```

## Configuration Presets

**BASIC (Fastest, no speaker labels):**
```bash
USE_WHISPERX=false
WHISPER_MODEL=tiny
OLLAMA_MODEL=llama2
```

**RECOMMENDED (Speaker labels, good quality):**
```bash
USE_WHISPERX=true
ENABLE_SPEAKER_DIARIZATION=true
WHISPER_MODEL=base
OLLAMA_MODEL=qwen2.5:14b
HUGGINGFACE_TOKEN=hf_your_token_here
```

**HIGH QUALITY (Best accuracy, slower):**
```bash
USE_WHISPERX=true
ENABLE_SPEAKER_DIARIZATION=true
WHISPER_MODEL=small
OLLAMA_MODEL=mixtral:8x7b
HUGGINGFACE_TOKEN=hf_your_token_here
```

## Documentation

- **README.md** - Full documentation
- **WHISPERX_SETUP.md** - WhisperX setup and troubleshooting
- **.env.example** - All configuration options with detailed comments

