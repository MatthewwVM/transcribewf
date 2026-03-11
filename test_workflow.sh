#!/bin/bash
# Test script to validate the transcription workflow setup

echo "=========================================="
echo "Transcription Workflow Validation"
echo "=========================================="
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
PASS=0
FAIL=0

# Function to check and report
check() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $2"
        ((PASS++))
    else
        echo -e "${RED}✗${NC} $2"
        ((FAIL++))
    fi
}

# Check Python environment
echo "Checking Python environment..."
python3 --version > /dev/null 2>&1
check $? "Python 3 is installed"

# Check if in virtual environment
if [[ "$VIRTUAL_ENV" != "" ]]; then
    check 0 "Virtual environment is activated"
else
    check 1 "Virtual environment is NOT activated (run: source bin/activate)"
fi

# Check Whisper installation
python3 -c "import whisper" > /dev/null 2>&1
check $? "Whisper module is installed"

# Check WhisperX installation (optional)
echo ""
echo "Checking WhisperX (optional)..."
if python3 -c "import whisperx" > /dev/null 2>&1; then
    check 0 "WhisperX is installed"
    WHISPERX_INSTALLED=true

    # Test WhisperX import with torch
    python3 -c "import whisperx; import torch" > /dev/null 2>&1
    check $? "WhisperX dependencies (torch) are working"
else
    echo -e "${YELLOW}ℹ${NC}  WhisperX is not installed (optional for speaker diarization)"
    WHISPERX_INSTALLED=false
fi

# Check .env configuration
echo ""
echo "Checking configuration..."
if [ -f ".env" ]; then
    check 0 ".env configuration file exists"

    # Check if WhisperX is enabled in config
    if grep -q "USE_WHISPERX=true" ".env" 2>/dev/null; then
        echo -e "${YELLOW}ℹ${NC}  WhisperX mode is ENABLED in .env"

        if [ "$WHISPERX_INSTALLED" = false ]; then
            check 1 "WhisperX is enabled but not installed!"
        else
            check 0 "WhisperX configuration is valid"
        fi

        # Check speaker diarization settings
        if grep -q "ENABLE_SPEAKER_DIARIZATION=true" ".env" 2>/dev/null; then
            echo -e "${YELLOW}ℹ${NC}  Speaker diarization is ENABLED"

            # Check for HuggingFace token
            if grep -q "HUGGINGFACE_TOKEN=hf_" ".env" 2>/dev/null; then
                check 0 "HuggingFace token is configured"
            else
                check 1 "HuggingFace token is missing or invalid"
                echo -e "${YELLOW}   Get token from: https://huggingface.co/settings/tokens${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}ℹ${NC}  WhisperX mode is DISABLED (using vanilla Whisper)"
    fi
else
    check 1 ".env configuration file is missing"
fi

# Check Ollama installation
echo ""
echo "Checking Ollama (optional)..."
which ollama > /dev/null 2>&1
check $? "Ollama is installed"

# Check if Ollama is running
ollama list > /dev/null 2>&1
check $? "Ollama is running and accessible"

# Check NFS client
which mount.nfs > /dev/null 2>&1
check $? "NFS client is installed"

# Check if files exist
echo ""
echo "Checking workflow files..."
[ -f "transcribe_workflow.py" ]
check $? "transcribe_workflow.py exists"

[ -x "transcribe_workflow.py" ]
check $? "transcribe_workflow.py is executable"

[ -f "transcribe-workflow.service" ]
check $? "transcribe-workflow.service exists"

[ -f "transcribe-workflow.timer" ]
check $? "transcribe-workflow.timer exists"

[ -f "setup_transcription_workflow.sh" ]
check $? "setup_transcription_workflow.sh exists"

[ -x "setup_transcription_workflow.sh" ]
check $? "setup_transcription_workflow.sh is executable"

# Check NFS server connectivity
echo ""
echo "Checking NFS server connectivity..."

# Try to read NFS server from .env if it exists
NFS_SERVER="10.0.0.136"
if [ -f ".env" ]; then
    NFS_IP=$(grep "^NFS_SERVER=" .env | cut -d'=' -f2 | cut -d':' -f1)
    if [ -n "$NFS_IP" ]; then
        NFS_SERVER="$NFS_IP"
    fi
fi

ping -c 1 -W 2 "$NFS_SERVER" > /dev/null 2>&1
check $? "NFS server ($NFS_SERVER) is reachable"

# Check if systemd files are installed
echo ""
echo "Checking systemd installation..."
[ -f "/etc/systemd/system/transcribe-workflow.service" ]
check $? "Service file is installed in /etc/systemd/system/"

[ -f "/etc/systemd/system/transcribe-workflow.timer" ]
check $? "Timer file is installed in /etc/systemd/system/"

# Check if timer is enabled
systemctl is-enabled transcribe-workflow.timer > /dev/null 2>&1
check $? "Timer is enabled"

# Check if timer is active
systemctl is-active transcribe-workflow.timer > /dev/null 2>&1
check $? "Timer is active/running"

# Check mount point
echo ""
echo "Checking directories..."
[ -d "/mnt/rotation" ]
check $? "Mount point /mnt/rotation exists"

# Check log file
[ -f "/var/log/transcribe_workflow.log" ]
check $? "Log file exists"

# Summary
echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo -e "${GREEN}Passed: $PASS${NC}"
echo -e "${RED}Failed: $FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All checks passed! The workflow is ready to use.${NC}"
    echo ""

    # Show configuration summary
    if [ -f ".env" ]; then
        echo "Configuration Summary:"
        if grep -q "USE_WHISPERX=true" ".env" 2>/dev/null; then
            echo "  Mode: WhisperX"
            if grep -q "ENABLE_SPEAKER_DIARIZATION=true" ".env" 2>/dev/null; then
                echo "  Speaker Diarization: Enabled"
            else
                echo "  Speaker Diarization: Disabled"
            fi
        else
            echo "  Mode: Vanilla Whisper"
        fi

        WHISPER_MODEL=$(grep "^WHISPER_MODEL=" .env | cut -d'=' -f2)
        OLLAMA_MODEL=$(grep "^OLLAMA_MODEL=" .env | cut -d'=' -f2)
        echo "  Whisper Model: ${WHISPER_MODEL:-base}"
        echo "  Ollama Model: ${OLLAMA_MODEL:-llama2}"
        echo ""
    fi

    echo "Next steps:"
    echo "  1. Place audio files in: /mnt/rotation/totranscribe"
    echo "  2. Wait for midnight, or run manually: sudo systemctl start transcribe-workflow.service"
    echo "  3. Check results in: /mnt/rotation/transcribed"
    echo ""
    echo "Documentation:"
    echo "  - README.md - Full documentation"
    echo "  - QUICK_START.md - Quick reference"
else
    echo -e "${YELLOW}Some checks failed. Please review the issues above.${NC}"
    echo ""
    if [[ "$VIRTUAL_ENV" == "" ]]; then
        echo "Tip: Activate the virtual environment first:"
        echo "  source bin/activate"
    fi
    echo ""
    echo "Common fixes:"
    echo "  - Missing dependencies: pip install openai-whisper whisperx"
    echo "  - Missing Ollama: curl -fsSL https://ollama.ai/install.sh | sh"
    echo "  - Missing .env: cp .env.example .env && nano .env"
    echo "  - Run setup: ./setup_transcription_workflow.sh"
fi

