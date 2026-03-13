# Automated Audio Transcription Workflow

Automatically transcribe audio recordings from an NFS share every night at midnight using OpenAI's Whisper (or WhisperX with speaker diarization) and generate formatted markdown notes with Ollama.

## Features

- 🎙️ **Automatic Transcription** - Uses OpenAI Whisper for high-quality speech-to-text
- 🎤 **Speaker Diarization** - Optional WhisperX integration identifies different speakers (who said what)
- 📝 **AI-Generated Notes** - Creates formatted markdown summaries using Ollama
- ⏰ **Scheduled Processing** - Runs automatically at midnight via systemd timer
- 💾 **Multiple Output Formats** - Saves as TXT, JSON, and Markdown
- 🔧 **Easy Configuration** - Simple `.env` file for all settings
- 📊 **Comprehensive Logging** - Detailed logs for monitoring and debugging
- 🔒 **Secure** - Mounts NFS only when needed, unmounts after processing

## How It Works

1. **Midnight trigger** - Systemd timer starts the workflow
2. **Mount NFS** - Connects to your network storage
3. **Scan for files** - Finds audio files in the `totranscribe` folder
4. **Transcribe** - Processes each file with Whisper
5. **Generate notes** - Creates markdown summaries with Ollama (optional)
6. **Save results** - Outputs TXT, JSON, and MD files
7. **Move files** - Relocates processed audio to `transcribed` folder
8. **Unmount** - Disconnects from NFS

## Prerequisites

- Python 3.8+ with virtual environment
- [OpenAI Whisper](https://github.com/openai/whisper) or [WhisperX](https://github.com/m-bain/whisperX) installed
- [Ollama](https://ollama.ai/) installed and running (optional, for AI notes)
- NFS client utilities (`nfs-common` on Debian/Ubuntu)
- Sudo access for NFS mounting
- HuggingFace account (optional, for WhisperX speaker diarization)

## Quick Start

```bash
# 1. Clone or download this repository
cd transcribe-workflow

# 2. Configure your settings
cp .env.example .env
nano .env  # Edit with your NFS server, models, etc.

# 3. Run the setup script
./setup_transcription_workflow.sh

# 4. Configure passwordless sudo for NFS (see Installation section)

# 5. Test it
./test_workflow.sh
```

## Installation

### 1. Install Prerequisites

```bash
# Install NFS client
sudo apt update
sudo apt install nfs-common

# Install Ollama (optional, for AI notes)
curl -fsSL https://ollama.ai/install.sh | sh
ollama pull llama2  # or your preferred model
```

### 2. Configure Settings

Copy and edit the configuration file:

```bash
cp .env.example .env
nano .env
```

Key settings to configure:
- `NFS_SERVER` - Your NFS server address and path
- `WHISPER_MODEL` - Model size (tiny/base/small/medium/large)
- `OLLAMA_MODEL` - AI model for markdown generation

### 3. Run Setup

```bash
./setup_transcription_workflow.sh
```

### 4. Configure Sudo Access

Add these lines to `/etc/sudoers` using `sudo visudo`:

```bash
# Replace with your username and NFS server from .env
matt ALL=(ALL) NOPASSWD: /bin/mount -t nfs YOUR_NFS_SERVER /mnt/rotation
matt ALL=(ALL) NOPASSWD: /bin/umount /mnt/rotation
```

Example:
```bash
matt ALL=(ALL) NOPASSWD: /bin/mount -t nfs 10.0.0.136\:volume1/NFS/rotation /mnt/rotation
matt ALL=(ALL) NOPASSWD: /bin/umount /mnt/rotation
```

## Configuration

All settings are in the `.env` file. See `.env.example` for detailed documentation.

### Core Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `NFS_SERVER` | NFS server and path | `10.0.0.136:volume1/NFS/rotation` |
| `MOUNT_POINT` | Local mount directory | `/mnt/rotation` |
| `SOURCE_FOLDER` | Folder with files to transcribe | `totranscribe` |
| `DEST_FOLDER` | Folder for processed files | `transcribed` |
| `WHISPER_MODEL` | Whisper model size | `tiny` |
| `OLLAMA_MODEL` | Ollama model name | `qwen2.5:14b` |
| `OLLAMA_PROMPT_TEMPLATE` | Custom prompt for note generation | (empty = use default) |
| `LOG_FILE` | Log file location | `/var/log/transcribe_workflow.log` |
| `LOG_LEVEL` | Logging verbosity | `INFO` |
| `ENABLE_OLLAMA` | Enable AI note generation | `true` |

### WhisperX Settings (Optional)

| Setting | Description | Default |
|---------|-------------|---------|
| `USE_WHISPERX` | Use WhisperX instead of vanilla Whisper | `false` |
| `ENABLE_SPEAKER_DIARIZATION` | Identify different speakers | `false` |
| `HUGGINGFACE_TOKEN` | HuggingFace API token for speaker diarization | - |

**WhisperX Benefits:**
- ✅ Better word-level timestamps
- ✅ Speaker identification (labels like `[SPEAKER_00]`, `[SPEAKER_01]`)
- ✅ Improved AI note quality (Ollama can distinguish speakers)

**WhisperX Drawbacks:**
- ⏱️ Slower processing (~2-3x vanilla Whisper)
- 🔑 Requires HuggingFace token for speaker diarization

### Whisper Model Sizes

| Model | Speed | Accuracy | RAM Required | Time (10min audio) |
|-------|-------|----------|--------------|-------------------|
| tiny | Fastest | Basic | ~1 GB | ~30s |
| base | Fast | Good | ~1 GB | ~60s |
| small | Medium | Better | ~2 GB | ~2min |
| medium | Slow | Great | ~5 GB | ~5min |
| large | Slowest | Best | ~10 GB | ~10min |

**Note:** WhisperX with speaker diarization adds ~60-90s processing time.

### Customizing AI Note Generation

You can customize how Ollama generates notes by setting `OLLAMA_PROMPT_TEMPLATE` in your `.env` file.

**Option 1: Inline prompt (simple)**
```bash
OLLAMA_PROMPT_TEMPLATE="You are a meeting note taker. Create bullet-point notes from this transcript. Audio: {audio_filename} Transcript: {transcription_text}"
```

**Option 2: External file (recommended for complex prompts)**
```bash
# Create a custom prompt file
cat > /path/to/my_prompt.txt << 'EOF'
You are an expert note taker.

Create detailed notes with:
- Key discussion points
- Action items
- Decisions made

Audio file: {audio_filename}
Transcript: {transcription_text}
EOF

# Reference it in .env
OLLAMA_PROMPT_TEMPLATE=$(cat /path/to/my_prompt.txt)
```

**Available placeholders:**
- `{audio_filename}` - Name of the audio file
- `{transcription_text}` - Full transcript with speaker labels (if enabled)
- `{has_speakers}` - "true" or "false" indicating if speaker diarization is enabled

**Leave empty** to use the built-in default prompt (optimized for technical sales calls with hierarchical structure, quantitative data preservation, and speaker distinction).

## Usage

### Automatic (Recommended)

The workflow runs automatically at midnight. Just place audio files in your NFS share's `totranscribe` folder.

### Manual Run

```bash
# Run immediately
sudo systemctl start transcribe-workflow.service

# Or run the script directly
./transcribe_workflow.py
```

## Monitoring

```bash
# Check timer status
sudo systemctl status transcribe-workflow.timer

# View recent logs
sudo journalctl -u transcribe-workflow.service -n 50

# Follow live logs
tail -f /var/log/transcribe_workflow.log
```

## Output Files

For each audio file `recording.m4a`, the workflow creates:

- `recording_TIMESTAMP.txt` - Plain text transcription (with speaker labels if WhisperX enabled)
- `recording_TIMESTAMP.json` - Full transcription with timestamps and metadata
- `recording_TIMESTAMP.md` - AI-generated markdown note with summary
- `recording.m4a` - Original file (moved to transcribed folder)


## Supported Audio Formats

MP3, WAV, M4A, FLAC, OGG, OPUS, AAC

## Troubleshooting

### NFS Mount Issues
```bash
# Test connectivity
ping YOUR_NFS_SERVER

# Check NFS exports
showmount -e YOUR_NFS_SERVER

# Try manual mount
sudo mount -t nfs YOUR_NFS_SERVER /mnt/rotation
```

### Ollama Not Working
```bash
# Check if running
systemctl status ollama

# Test it
ollama run llama2 "test"

# Pull a model if needed
ollama pull qwen2.5:14b
```

### WhisperX Issues
```bash
# Verify WhisperX is installed
python3 -c "import whisperx; print('OK')"

# Check HuggingFace token (if using speaker diarization)
# Make sure you accepted the agreement at:
# https://huggingface.co/pyannote/speaker-diarization
```

### Check Logs
```bash
# View detailed logs
sudo journalctl -u transcribe-workflow.service -n 50

# Follow live logs
tail -f /var/log/transcribe_workflow.log
```

## Additional Documentation

- **[QUICK_START.md](QUICK_START.md)** - Fast setup guide with configuration presets

## License

MIT License - Feel free to use and modify!

## Contributing

Contributions welcome! Please open an issue or pull request.

