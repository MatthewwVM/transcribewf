#!/bin/bash
# Setup script for the automated transcription workflow

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="transcribe-workflow.service"
TIMER_FILE="transcribe-workflow.timer"
PYTHON_SCRIPT="transcribe_workflow.py"
LOG_FILE="/var/log/transcribe_workflow.log"

echo "=========================================="
echo "Transcription Workflow Setup"
echo "=========================================="
echo ""

# Check if running as root for some operations
if [ "$EUID" -ne 0 ]; then
    echo "Note: Some operations will require sudo privileges"
    echo ""
fi

# Check Python dependencies
echo "Checking Python dependencies..."
if ! python3 -c "import whisper" 2>/dev/null; then
    echo "⚠️  WARNING: OpenAI Whisper not found!"
    echo "   Install with: pip install openai-whisper"
    echo ""
fi

# Check for WhisperX (optional)
if python3 -c "import whisperx" 2>/dev/null; then
    echo "✓ WhisperX is installed"
    WHISPERX_AVAILABLE=true
else
    echo "ℹ️  WhisperX not installed (optional for speaker diarization)"
    echo "   Install with: pip install whisperx"
    WHISPERX_AVAILABLE=false
fi

# Check for Ollama (optional)
if command -v ollama &> /dev/null; then
    echo "✓ Ollama is installed"
    if ollama list &> /dev/null; then
        echo "  Available models:"
        ollama list | tail -n +2 | awk '{print "    - " $1}'
    fi
else
    echo "ℹ️  Ollama not installed (optional for AI note generation)"
    echo "   Install from: https://ollama.ai/install.sh"
fi
echo ""

# Check for .env file
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Creating .env configuration file from template..."
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    echo ""
    echo "⚠️  IMPORTANT: Please edit .env file to configure your settings!"
    echo "   Edit: $SCRIPT_DIR/.env"
    echo ""
    echo "Quick start configurations:"
    echo "  BASIC:       USE_WHISPERX=false, WHISPER_MODEL=tiny, ENABLE_OLLAMA=true"
    echo "  RECOMMENDED: USE_WHISPERX=true, WHISPER_MODEL=tiny, ENABLE_SPEAKER_DIARIZATION=true, OLLAMA_MODEL=qwen2.5:14b"
    echo "  HIGH QUALITY: USE_WHISPERX=true, WHISPER_MODEL=small, ENABLE_SPEAKER_DIARIZATION=true, OLLAMA_MODEL=mixtral:8x7b"
    echo ""
    read -p "Press Enter to continue after editing .env, or Ctrl+C to exit..."
else
    echo "Found existing .env file"

    # Validate WhisperX configuration
    if grep -q "USE_WHISPERX=true" "$SCRIPT_DIR/.env" 2>/dev/null; then
        echo "  WhisperX mode: ENABLED"

        if [ "$WHISPERX_AVAILABLE" = false ]; then
            echo "  ⚠️  WARNING: WhisperX is enabled in .env but not installed!"
            echo "     Install with: pip install whisperx"
        fi

        if grep -q "ENABLE_SPEAKER_DIARIZATION=true" "$SCRIPT_DIR/.env" 2>/dev/null; then
            echo "  Speaker diarization: ENABLED"

            # Check for HuggingFace token
            if grep -q "HUGGINGFACE_TOKEN=your_token_here" "$SCRIPT_DIR/.env" 2>/dev/null || \
               ! grep -q "HUGGINGFACE_TOKEN=hf_" "$SCRIPT_DIR/.env" 2>/dev/null; then
                echo "  ⚠️  WARNING: Speaker diarization enabled but HuggingFace token not set!"
                echo "     Get token from: https://huggingface.co/settings/tokens"
                echo "     Accept agreement: https://huggingface.co/pyannote/speaker-diarization"
            else
                echo "  ✓ HuggingFace token configured"
            fi
        fi
    else
        echo "  WhisperX mode: DISABLED (using vanilla Whisper)"
    fi
fi
echo ""

# Make Python script executable
echo "Making Python script executable..."
chmod +x "$SCRIPT_DIR/$PYTHON_SCRIPT"

# Create log file with proper permissions
echo "Creating log file..."
sudo touch "$LOG_FILE"
sudo chown matt:matt "$LOG_FILE"
sudo chmod 644 "$LOG_FILE"

# Create mount point directory
echo "Creating mount point directory..."
sudo mkdir -p /mnt/rotation
sudo chown matt:matt /mnt/rotation

# Copy systemd files to system directory
echo "Installing systemd service and timer..."
sudo cp "$SCRIPT_DIR/$SERVICE_FILE" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/$TIMER_FILE" /etc/systemd/system/

# Reload systemd daemon
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Enable the timer (this will start it at boot)
echo "Enabling timer..."
sudo systemctl enable transcribe-workflow.timer

# Start the timer
echo "Starting timer..."
sudo systemctl start transcribe-workflow.timer

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "The transcription workflow is now configured to run daily at midnight."
echo ""

# Test WhisperX installation if enabled
if grep -q "USE_WHISPERX=true" "$SCRIPT_DIR/.env" 2>/dev/null && [ "$WHISPERX_AVAILABLE" = true ]; then
    echo "Testing WhisperX installation..."
    if python3 -c "import whisperx; import torch; print('WhisperX: OK')" 2>/dev/null; then
        echo "✓ WhisperX test passed"
    else
        echo "⚠️  WhisperX test failed - check dependencies"
    fi
    echo ""
fi

echo "Useful commands:"
echo "  - Check timer status:    sudo systemctl status transcribe-workflow.timer"
echo "  - List all timers:       sudo systemctl list-timers"
echo "  - Run service manually:  sudo systemctl start transcribe-workflow.service"
echo "  - Check service status:  sudo systemctl status transcribe-workflow.service"
echo "  - View logs:             sudo journalctl -u transcribe-workflow.service"
echo "  - View log file:         tail -f $LOG_FILE"
echo "  - Test workflow:         ./test_workflow.sh"
echo "  - Stop timer:            sudo systemctl stop transcribe-workflow.timer"
echo "  - Disable timer:         sudo systemctl disable transcribe-workflow.timer"
echo ""
echo "Configuration:"
echo "  - Config File:    $SCRIPT_DIR/.env"
echo "  - NFS Server:     (see .env file)"
echo "  - Mount Point:    (see .env file)"
echo "  - Source Dir:     (see .env file)"
echo "  - Dest Dir:       (see .env file)"
echo "  - Log File:       $LOG_FILE"
echo ""
echo "Next steps:"
echo "  1. Configure sudo for NFS mounting (see README.md)"
echo "  2. Run test: ./test_workflow.sh"
echo "  3. Place audio files in your NFS share's 'totranscribe' folder"
echo ""
echo "Documentation:"
echo "  - README.md - Full documentation"
echo "  - QUICK_START.md - Quick reference"
echo ""
echo "To modify settings, edit: $SCRIPT_DIR/.env"
echo ""

