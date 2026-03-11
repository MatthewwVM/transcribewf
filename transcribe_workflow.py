#!/usr/bin/env python3
"""
Automated transcription workflow for NFS-mounted recordings.
Transcribes audio files using Whisper and generates markdown notes using Ollama.
"""

import os
import sys
import subprocess
import json
import logging
from pathlib import Path
from datetime import datetime
import whisper
import glob

# WhisperX imports (conditional based on configuration)
try:
    import whisperx
    from whisperx.diarize import DiarizationPipeline
    WHISPERX_AVAILABLE = True
except ImportError:
    WHISPERX_AVAILABLE = False
    DiarizationPipeline = None

# Load environment variables from .env file if it exists
def load_env_file():
    """Load environment variables from .env file in the script directory."""
    env_file = Path(__file__).parent / '.env'
    if env_file.exists():
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                # Skip comments and empty lines
                if line and not line.startswith('#'):
                    # Handle key=value pairs
                    if '=' in line:
                        key, value = line.split('=', 1)
                        key = key.strip()
                        value = value.strip()
                        # Remove quotes if present
                        if value.startswith('"') and value.endswith('"'):
                            value = value[1:-1]
                        elif value.startswith("'") and value.endswith("'"):
                            value = value[1:-1]
                        os.environ[key] = value

# Load .env file
load_env_file()

# Configuration - Load from environment variables with defaults
NFS_SERVER = os.getenv('NFS_SERVER', '10.0.0.136:volume1/NFS/rotation')
MOUNT_POINT = os.getenv('MOUNT_POINT', '/mnt/rotation')
SOURCE_FOLDER = os.getenv('SOURCE_FOLDER', 'totranscribe')
DEST_FOLDER = os.getenv('DEST_FOLDER', 'transcribed')
SOURCE_DIR = os.path.join(MOUNT_POINT, SOURCE_FOLDER)
DEST_DIR = os.path.join(MOUNT_POINT, DEST_FOLDER)
LOG_FILE = os.getenv('LOG_FILE', '/var/log/transcribe_workflow.log')
WHISPER_MODEL = os.getenv('WHISPER_MODEL', 'base')
OLLAMA_MODEL = os.getenv('OLLAMA_MODEL', 'llama2')
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
ENABLE_OLLAMA = os.getenv('ENABLE_OLLAMA', 'true').lower() in ('true', '1', 'yes')

# WhisperX Configuration
USE_WHISPERX = os.getenv('USE_WHISPERX', 'false').lower() in ('true', '1', 'yes')
ENABLE_SPEAKER_DIARIZATION = os.getenv('ENABLE_SPEAKER_DIARIZATION', 'false').lower() in ('true', '1', 'yes')
HUGGINGFACE_TOKEN = os.getenv('HUGGINGFACE_TOKEN', '')

# Ollama Prompt Template
OLLAMA_PROMPT_TEMPLATE = os.getenv('OLLAMA_PROMPT_TEMPLATE', '')

# Setup logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper()),
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


def run_command(cmd, check=True):
    """Execute a shell command and return the result."""
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            check=check,
            capture_output=True,
            text=True
        )
        return result.returncode == 0, result.stdout, result.stderr
    except subprocess.CalledProcessError as e:
        return False, e.stdout, e.stderr


def mount_nfs():
    """Mount the NFS share."""
    logger.info(f"Mounting NFS share {NFS_SERVER} to {MOUNT_POINT}")
    
    # Create mount point if it doesn't exist
    Path(MOUNT_POINT).mkdir(parents=True, exist_ok=True)
    
    # Check if already mounted
    success, stdout, _ = run_command(f"mountpoint -q {MOUNT_POINT}", check=False)
    if success:
        logger.info("NFS share already mounted")
        return True
    
    # Mount the NFS share
    success, stdout, stderr = run_command(
        f"sudo mount -t nfs {NFS_SERVER} {MOUNT_POINT}",
        check=False
    )
    
    if success:
        logger.info("NFS share mounted successfully")
        return True
    else:
        logger.error(f"Failed to mount NFS share: {stderr}")
        return False


def unmount_nfs():
    """Unmount the NFS share."""
    logger.info(f"Unmounting NFS share from {MOUNT_POINT}")
    success, stdout, stderr = run_command(f"sudo umount {MOUNT_POINT}", check=False)
    
    if success:
        logger.info("NFS share unmounted successfully")
    else:
        logger.warning(f"Failed to unmount NFS share: {stderr}")


def get_audio_files():
    """Get list of audio files to transcribe."""
    audio_extensions = ['*.mp3', '*.wav', '*.m4a', '*.flac', '*.ogg', '*.opus', '*.aac']
    audio_files = []
    
    for ext in audio_extensions:
        audio_files.extend(glob.glob(os.path.join(SOURCE_DIR, ext)))
    
    logger.info(f"Found {len(audio_files)} audio files to transcribe")
    return audio_files


def transcribe_audio(audio_file, model, device="cpu"):
    """Transcribe an audio file using Whisper or WhisperX."""
    logger.info(f"Transcribing: {audio_file}")

    try:
        if USE_WHISPERX and WHISPERX_AVAILABLE:
            logger.info("Using WhisperX for transcription")

            # Transcribe with WhisperX
            result = model.transcribe(audio_file, batch_size=16)

            # Align whisper output for better timestamps
            model_a, metadata = whisperx.load_align_model(
                language_code=result["language"],
                device=device
            )
            result = whisperx.align(
                result["segments"],
                model_a,
                metadata,
                audio_file,
                device,
                return_char_alignments=False
            )

            # Speaker diarization if enabled
            if ENABLE_SPEAKER_DIARIZATION and HUGGINGFACE_TOKEN:
                logger.info("Performing speaker diarization")
                diarize_model = DiarizationPipeline(
                    token=HUGGINGFACE_TOKEN,
                    device=device
                )
                diarize_segments = diarize_model(audio_file)
                result = whisperx.assign_word_speakers(diarize_segments, result)
                logger.info("Speaker diarization completed")

            # Format result to include speaker labels in text
            formatted_text = format_whisperx_output(result)

            # Create result dict compatible with vanilla Whisper format
            final_result = {
                'text': formatted_text,
                'segments': result.get('segments', []),
                'language': result.get('language', 'en')
            }

            logger.info(f"WhisperX transcription completed for: {audio_file}")
            return final_result

        else:
            # Use vanilla Whisper
            logger.info("Using vanilla Whisper for transcription")
            result = model.transcribe(audio_file, verbose=False)
            logger.info(f"Transcription completed for: {audio_file}")
            return result

    except Exception as e:
        logger.error(f"Error transcribing {audio_file}: {str(e)}")
        import traceback
        logger.error(traceback.format_exc())
        return None


def format_whisperx_output(result):
    """Format WhisperX output with speaker labels."""
    segments = result.get('segments', [])

    if not segments:
        return result.get('text', '')

    formatted_lines = []
    current_speaker = None
    current_text = []

    for segment in segments:
        speaker = segment.get('speaker', None)
        text = segment.get('text', '').strip()

        if not text:
            continue

        # If speaker changed, save previous segment and start new one
        if speaker != current_speaker and current_text:
            if current_speaker:
                formatted_lines.append(f"[{current_speaker}]: {' '.join(current_text)}")
            else:
                formatted_lines.append(' '.join(current_text))
            current_text = []

        current_speaker = speaker
        current_text.append(text)

    # Add final segment
    if current_text:
        if current_speaker:
            formatted_lines.append(f"[{current_speaker}]: {' '.join(current_text)}")
        else:
            formatted_lines.append(' '.join(current_text))

    return '\n\n'.join(formatted_lines)


def generate_markdown_with_ollama(transcription_text, audio_filename):
    """Generate a markdown note from transcription using Ollama."""
    if not ENABLE_OLLAMA:
        logger.info("Ollama markdown generation is disabled")
        return None

    logger.info(f"Generating markdown note for: {audio_filename}")

    # Check if transcript has speaker labels
    has_speakers = '[SPEAKER_' in transcription_text or '[Speaker ' in transcription_text

    # Use custom prompt template if provided, otherwise use default
    if OLLAMA_PROMPT_TEMPLATE:
        # Replace placeholders in custom template
        prompt = OLLAMA_PROMPT_TEMPLATE.replace('{audio_filename}', audio_filename)
        prompt = prompt.replace('{transcription_text}', transcription_text)
        prompt = prompt.replace('{has_speakers}', 'true' if has_speakers else 'false')
    else:
        # Default prompt template
        speaker_instructions = ""
        if has_speakers:
            speaker_instructions = """
IMPORTANT - Speaker Labels:
The transcript includes speaker labels like [SPEAKER_00], [SPEAKER_01], etc.
- Identify which speaker is Matt Webb (usually the one presenting Pure Storage content)
- Other speakers are likely customers/attendees
- Use speaker patterns to distinguish Matt's standard pitch from customer-specific content
- When Matt presents standard Pure Storage value propositions, summarize briefly
- When customers speak, capture detailed requirements, questions, and concerns
"""

        prompt = f"""You are an expert technical note taker for Matt Webb, a Field Solutions Architect at Pure Storage specializing in Virtualization Infrastructure.

{speaker_instructions}

YOUR TASK:
Create comprehensive, hierarchical notes from this technical conversation. Focus on CUSTOMER-SPECIFIC information, not generic sales pitches.

CRITICAL REQUIREMENTS:

1. PRESERVE ALL QUANTITATIVE DATA:
   - Exact numbers (server counts, percentages, ratios, costs)
   - Dates and timelines (quarters, years, specific dates)
   - Technical specifications (vCPU ratios, memory sizes, IOPS, latency)
   - Version numbers and model numbers

2. MAINTAIN TECHNICAL ACCURACY:
   - Keep all technical terminology exact (e.g., "RDM", "Azure Arc", "vCPU to pCPU ratio")
   - Preserve product names, vendor names, and acronyms
   - Include direct quotes when they reveal sentiment or emphasis (use "quotes")

3. PROVIDE CONTEXT:
   - Explain WHY decisions were made, not just WHAT was decided
   - Connect related topics (e.g., "timeline aligns with SAP Rise project")
   - Note historical background when mentioned

4. HIERARCHICAL STRUCTURE:
   - Use main topics with bullet points and sub-bullets
   - Group related information logically
   - Use **bold** for section headers and key terms
   - Indent sub-points for clarity

5. DISTINGUISH CONTENT:
   - CUSTOMER environment details → VERY DETAILED
   - Customer pain points and requirements → CAPTURE EVERYTHING
   - Matt's standard Pure Storage pitch → SUMMARIZE BRIEFLY
   - Competitor mentions → NOTE WITH CONTEXT
   - Technical debt and constraints → DOCUMENT THOROUGHLY

OUTPUT FORMAT:

## Attendees
[List all participants with roles and companies]

## Executive Summary
[2-3 sentences: What is the customer trying to achieve and why does it matter?]

## [Topic-Based Sections]
Use descriptive section headers based on conversation content, such as:
- Current Infrastructure / Environment
- Technical Requirements
- Pain Points / Challenges
- Solutions Explored / Alternatives Considered
- Strategic Direction / Preferences
- Budget / Timeline Constraints

Within each section, use hierarchical bullets:
- **Main Point:**
    - Supporting detail with numbers
    - Sub-detail explaining context
    - **Specific Configuration:** Technical details

## Next Steps / Action Items
[Organized by owner with specific deliverables and deadlines]
1. **[Owner Name]:**
    - Action item with deadline
    - Required information or deliverable
2. **Matt Webb:**
    - Follow-up actions
    - Information to send

Audio file: {audio_filename}

Transcription:
{transcription_text}

Generate comprehensive, well-structured markdown notes following the format above. Be thorough but concise. Focus on actionable intelligence."""

    try:
        # Call Ollama API
        cmd = f'ollama run {OLLAMA_MODEL} "{prompt}"'
        success, stdout, stderr = run_command(cmd, check=False)

        if success and stdout:
            logger.info(f"Markdown note generated for: {audio_filename}")
            return stdout
        else:
            logger.error(f"Failed to generate markdown: {stderr}")
            return None
    except Exception as e:
        logger.error(f"Error calling Ollama: {str(e)}")
        return None


def save_transcription(audio_file, transcription_result, markdown_note):
    """Save transcription results to the destination directory."""
    # Create destination directory if it doesn't exist
    Path(DEST_DIR).mkdir(parents=True, exist_ok=True)
    
    base_name = Path(audio_file).stem
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    
    # Save raw transcription as text
    txt_file = os.path.join(DEST_DIR, f"{base_name}_{timestamp}.txt")
    with open(txt_file, 'w', encoding='utf-8') as f:
        f.write(transcription_result['text'])
    logger.info(f"Saved transcription to: {txt_file}")

    # Save JSON with full details
    json_file = os.path.join(DEST_DIR, f"{base_name}_{timestamp}.json")
    with open(json_file, 'w', encoding='utf-8') as f:
        json.dump(transcription_result, f, indent=2, ensure_ascii=False)
    logger.info(f"Saved JSON to: {json_file}")

    # Save markdown note if available
    if markdown_note:
        md_file = os.path.join(DEST_DIR, f"{base_name}_{timestamp}.md")
        with open(md_file, 'w', encoding='utf-8') as f:
            # Write the Ollama-generated notes
            f.write(markdown_note)

            # Append the full transcript at the end
            f.write("\n\n---\n\n")
            f.write("## Full Transcript\n\n")
            f.write("```\n")
            f.write(transcription_result['text'])
            f.write("\n```\n")
        logger.info(f"Saved markdown note to: {md_file}")

    # Move original audio file to transcribed directory
    dest_audio = os.path.join(DEST_DIR, Path(audio_file).name)
    try:
        os.rename(audio_file, dest_audio)
        logger.info(f"Moved audio file to: {dest_audio}")
    except Exception as e:
        logger.error(f"Failed to move audio file: {str(e)}")


def main():
    """Main workflow execution."""
    logger.info("=" * 80)
    logger.info("Starting transcription workflow")
    logger.info("=" * 80)
    logger.info("Configuration:")
    logger.info(f"  NFS Server: {NFS_SERVER}")
    logger.info(f"  Mount Point: {MOUNT_POINT}")
    logger.info(f"  Source Directory: {SOURCE_DIR}")
    logger.info(f"  Destination Directory: {DEST_DIR}")
    logger.info(f"  Whisper Model: {WHISPER_MODEL}")
    logger.info(f"  Use WhisperX: {USE_WHISPERX}")
    if USE_WHISPERX:
        logger.info(f"  Speaker Diarization: {ENABLE_SPEAKER_DIARIZATION}")
    logger.info(f"  Ollama Model: {OLLAMA_MODEL}")
    logger.info(f"  Ollama Enabled: {ENABLE_OLLAMA}")
    logger.info("=" * 80)

    try:
        # Mount NFS share
        if not mount_nfs():
            logger.error("Failed to mount NFS share. Exiting.")
            return 1

        # Check if source directory exists
        if not os.path.exists(SOURCE_DIR):
            logger.error(f"Source directory does not exist: {SOURCE_DIR}")
            unmount_nfs()
            return 1

        # Get audio files
        audio_files = get_audio_files()

        if not audio_files:
            logger.info("No audio files found to transcribe")
            unmount_nfs()
            return 0

        # Load Whisper or WhisperX model
        # Auto-detect CUDA availability
        import torch
        device = "cuda" if torch.cuda.is_available() else "cpu"
        logger.info(f"Using device: {device}")

        if USE_WHISPERX and WHISPERX_AVAILABLE:
            logger.info(f"Loading WhisperX model: {WHISPER_MODEL}")
            # Use float16 for GPU, int8 for CPU
            compute_type = "float16" if device == "cuda" else "int8"
            model = whisperx.load_model(WHISPER_MODEL, device, compute_type=compute_type)
            logger.info("WhisperX model loaded successfully")
            if ENABLE_SPEAKER_DIARIZATION:
                logger.info("Speaker diarization is enabled")
        else:
            if USE_WHISPERX and not WHISPERX_AVAILABLE:
                logger.warning("WhisperX requested but not available, falling back to vanilla Whisper")
            logger.info(f"Loading Whisper model: {WHISPER_MODEL}")
            model = whisper.load_model(WHISPER_MODEL)
            logger.info("Whisper model loaded successfully")

        # Process each audio file
        success_count = 0
        error_count = 0

        for audio_file in audio_files:
            try:
                # Transcribe audio
                transcription_result = transcribe_audio(audio_file, model)

                if transcription_result is None:
                    error_count += 1
                    continue

                # Generate markdown note with Ollama
                markdown_note = generate_markdown_with_ollama(
                    transcription_result['text'],
                    Path(audio_file).name
                )

                # Save results
                save_transcription(audio_file, transcription_result, markdown_note)
                success_count += 1

            except Exception as e:
                logger.error(f"Error processing {audio_file}: {str(e)}")
                error_count += 1

        logger.info("=" * 80)
        logger.info(f"Workflow completed: {success_count} successful, {error_count} errors")
        logger.info("=" * 80)

    except Exception as e:
        logger.error(f"Unexpected error in workflow: {str(e)}")
        return 1

    finally:
        # Always try to unmount
        unmount_nfs()

    return 0 if error_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

