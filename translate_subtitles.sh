#!/bin/bash

# Subtitle Translation Script for ZenDRIVE
# Translates all .en.srt files to specified languages (default: French, Dutch, German, Arabic, Japanese, Danish)
#
# Usage:
#   ./translate_subtitles.sh [directory]              # Use Claude (sequential) in specified directory
#   ./translate_subtitles.sh                          # Use Claude (sequential) in current directory
#   TRANSLATE_SERVICE=aws ./translate_subtitles.sh [directory]  # Use AWS Translate (concurrent)
#   DEBUG=1 ./translate_subtitles.sh [directory]      # Enable debug mode
#   TRANSLATE_LANGUAGES="es,fr,de" ./translate_subtitles.sh    # Translate to specific languages

# Debug mode (set to 1 to enable debug output)
DEBUG=${DEBUG:-0}

# Translation service (claude or aws)
TRANSLATE_SERVICE=${TRANSLATE_SERVICE:-claude}

# Languages to translate to (default: fr,nl,de,ar,ja,da)
# Format: comma-separated list of language codes
TRANSLATE_LANGUAGES=${TRANSLATE_LANGUAGES:-"fr,nl,de,ar,ja,da"}

# File ownership after translation (default: no change)
# Format: user:group or uid:gid
FILE_OWNER=${FILE_OWNER:-"32574:32574"}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Language codes and names mapping
declare -A ALL_LANGUAGE_NAMES=(
    ["fr"]="French"
    ["nl"]="Dutch" 
    ["de"]="German"
    ["ar"]="Arabic"
    ["ja"]="Japanese"
    ["da"]="Danish"
    ["es"]="Spanish"
    ["it"]="Italian"
    ["pt"]="Portuguese"
    ["ko"]="Korean"
    ["zh"]="Chinese"
    ["ru"]="Russian"
    ["hi"]="Hindi"
    ["tr"]="Turkish"
    ["pl"]="Polish"
    ["sv"]="Swedish"
    ["no"]="Norwegian"
    ["fi"]="Finnish"
)

# Parse the TRANSLATE_LANGUAGES environment variable
declare -A LANGUAGES=()
IFS=',' read -ra LANG_CODES <<< "$TRANSLATE_LANGUAGES"
for lang_code in "${LANG_CODES[@]}"; do
    # Trim whitespace
    lang_code=$(echo "$lang_code" | xargs)
    if [[ -n "${ALL_LANGUAGE_NAMES[$lang_code]}" ]]; then
        LANGUAGES[$lang_code]="${ALL_LANGUAGE_NAMES[$lang_code]}"
    else
        echo -e "${YELLOW}WARNING${NC} Unknown language code: $lang_code (skipping)"
    fi
done

# AWS language codes (same as LANGUAGES)
declare -A AWS_LANGUAGES=()
for lang_code in "${!LANGUAGES[@]}"; do
    AWS_LANGUAGES[$lang_code]="${LANGUAGES[$lang_code]}"
done

# Check if at least one language is specified
if [ ${#LANGUAGES[@]} -eq 0 ]; then
    echo -e "${RED}ERROR${NC} No valid language codes specified in TRANSLATE_LANGUAGES"
    echo "Please use one or more of: fr nl de ar ja da es it pt ko zh ru hi tr pl sv no fi"
    exit 1
fi

# Function to log messages
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Debug logging function
debug() {
    if [ "$DEBUG" -eq 1 ]; then
        echo -e "${CYAN}[DEBUG $(date '+%H:%M:%S')]${NC} $1" >&2
    fi
}

# Function to parse SRT file into subtitle blocks
parse_srt_file() {
    local source_file="$1"
    local -n subtitle_blocks_ref=$2
    
    local current_block=""
    local in_subtitle=false
    local line_count=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_count++))
        
        if [[ "$line" =~ ^[0-9]+$ ]] && [[ -z "$current_block" ]]; then
            # Start of new subtitle block
            current_block="$line"
            in_subtitle=true
        elif [[ "$line" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}\ --\>\ [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}$ ]] && [[ -n "$current_block" ]]; then
            # Timecode line
            current_block="$current_block"$'\n'"$line"
        elif [[ -n "$line" ]] && [[ -n "$current_block" ]]; then
            # Subtitle text line
            current_block="$current_block"$'\n'"$line"
        elif [[ -z "$line" ]] && [[ -n "$current_block" ]]; then
            # Empty line - end of subtitle block
            subtitle_blocks_ref+=("$current_block")
            current_block=""
            in_subtitle=false
        elif [[ -n "$current_block" ]]; then
            # Continue building current block
            current_block="$current_block"$'\n'"$line"
        fi
    done < "$source_file"
    
    # Add final block if file doesn't end with empty line
    if [[ -n "$current_block" ]]; then
        subtitle_blocks_ref+=("$current_block")
    fi
    
    debug "Parsed $line_count lines into ${#subtitle_blocks_ref[@]} subtitle blocks"
}

# Function to translate text using AWS Translate
translate_text_aws() {
    local text="$1"
    local target_lang="$2"
    
    debug "Translating ${#text} characters to $target_lang"
    
    # Use AWS Translate directly with text parameter
    local aws_output
    local aws_exit_code
    
    aws_output=$(aws translate translate-text \
        --source-language-code en \
        --target-language-code "$target_lang" \
        --text "$text" \
        --region us-east-1 \
        --output text \
        --query 'TranslatedText' 2>&1)
    aws_exit_code=$?
    
    if [ $aws_exit_code -eq 0 ]; then
        # Remove quotes from AWS output and handle escaped characters
        echo "$aws_output" | sed 's/^"//;s/"$//' | sed 's/\\n/\n/g'
        return 0
    else
        debug "AWS Translate failed: $aws_output"
        return 1
    fi
}

# Function to translate text in chunks for AWS
translate_text_chunks_aws() {
    local text="$1"
    local target_lang="$2"
    local max_chunk_size=4000  # Conservative limit for AWS
    
    # Split text into chunks by lines
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done <<< "$text"
    
    local translated_result=""
    local current_chunk=""
    local current_size=0
    
    for line in "${lines[@]}"; do
        local line_size=${#line}
        
        # If adding this line would exceed the chunk size, translate current chunk
        if [ $((current_size + line_size + 1)) -gt $max_chunk_size ] && [ -n "$current_chunk" ]; then
            debug "Translating chunk of size $current_size characters"
            
            local chunk_translation
            if chunk_translation=$(translate_text_aws "$current_chunk" "$target_lang"); then
                if [ -n "$translated_result" ]; then
                    translated_result="$translated_result"$'\n'"$chunk_translation"
                else
                    translated_result="$chunk_translation"
                fi
                current_chunk="$line"
                current_size=$line_size
            else
                debug "Failed to translate chunk"
                return 1
            fi
        else
            # Add line to current chunk
            if [ -n "$current_chunk" ]; then
                current_chunk="$current_chunk"$'\n'"$line"
                current_size=$((current_size + line_size + 1))
            else
                current_chunk="$line"
                current_size=$line_size
            fi
        fi
    done
    
    # Translate final chunk
    if [ -n "$current_chunk" ]; then
        debug "Translating final chunk of size $current_size characters"
        local chunk_translation
        if chunk_translation=$(translate_text_aws "$current_chunk" "$target_lang"); then
            if [ -n "$translated_result" ]; then
                translated_result="$translated_result"$'\n'"$chunk_translation"
            else
                translated_result="$chunk_translation"
            fi
        else
            debug "Failed to translate final chunk"
            return 1
        fi
    fi
    
    echo "$translated_result"
    return 0
}

# Function to translate entire subtitle file content using AWS batch processing with chunking
translate_file_content_aws() {
    local source_file="$1"
    local target_file="$2"
    local lang_code="$3"
    
    debug "Translating file content using AWS Translate with chunking"
    
    # Read the entire file and extract all subtitle text in one pass
    local all_subtitle_text=""
    local line_count=0
    local in_text=false
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_count++))
        
        # Skip subtitle numbers (lines that are just digits)
        if [[ "$line" =~ ^[0-9]+$ ]]; then
            in_text=false
            continue
        fi
        
        # Skip timecode lines
        if [[ "$line" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}\ --\>\ [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}$ ]]; then
            in_text=true
            continue
        fi
        
        # Skip empty lines
        if [[ -z "$line" ]]; then
            in_text=false
            continue
        fi
        
        # This should be subtitle text
        if [ "$in_text" = true ]; then
            if [ -n "$all_subtitle_text" ]; then
                all_subtitle_text="$all_subtitle_text"$'\n'"$line"
            else
                all_subtitle_text="$line"
            fi
        fi
    done < "$source_file"
    
    if [ -z "$all_subtitle_text" ]; then
        debug "No subtitle text found to translate"
        return 1
    fi
    
    debug "Extracted subtitle text length: ${#all_subtitle_text} characters"
    
    # Translate text (with chunking if needed)
    local translated_text
    if [ ${#all_subtitle_text} -gt 4000 ]; then
        debug "Text is large, using chunked translation"
        if ! translated_text=$(translate_text_chunks_aws "$all_subtitle_text" "$lang_code"); then
            debug "AWS chunked translation failed for file content"
            return 1
        fi
    else
        debug "Text is small enough for single translation"
        if ! translated_text=$(translate_text_aws "$all_subtitle_text" "$lang_code"); then
            debug "AWS translation failed for file content"
            return 1
        fi
    fi
    
    debug "Translation completed, reconstructing SRT format"
    
    # Reconstruct the SRT file with translated text
    local translated_lines=()
    while IFS= read -r line; do
        translated_lines+=("$line")
    done <<< "$translated_text"
    
    # Clear target file
    > "$target_file"
    
    # Parse original file structure and insert translated text
    local translated_index=0
    local in_text=false
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Subtitle numbers
        if [[ "$line" =~ ^[0-9]+$ ]]; then
            echo "$line" >> "$target_file"
            in_text=false
            continue
        fi
        
        # Timecode lines
        if [[ "$line" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}\ --\>\ [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}$ ]]; then
            echo "$line" >> "$target_file"
            in_text=true
            continue
        fi
        
        # Empty lines
        if [[ -z "$line" ]]; then
            echo >> "$target_file"
            in_text=false
            continue
        fi
        
        # Subtitle text - replace with translated text
        if [ "$in_text" = true ] && [ $translated_index -lt ${#translated_lines[@]} ]; then
            echo "${translated_lines[$translated_index]}" >> "$target_file"
            ((translated_index++))
        fi
    done < "$source_file"
    
    debug "SRT file reconstruction completed"
    
    # Change ownership if FILE_OWNER is set
    if [ -n "$FILE_OWNER" ] && [ "$FILE_OWNER" != "none" ]; then
        if chown "$FILE_OWNER" "$target_file" 2>/dev/null; then
            debug "Changed ownership of $target_file to $FILE_OWNER"
        else
            debug "Failed to change ownership of $target_file (may need root privileges)"
        fi
    fi
    
    return 0
}

# Function to translate subtitle blocks in chunks (Claude)
translate_subtitle_chunks() {
    local source_file="$1"
    local target_file="$2"
    local lang_name="$3"
    local -n blocks_ref=$4
    
    local chunk_size=10  # Process 10 subtitle blocks at a time
    local total_blocks=${#blocks_ref[@]}
    local processed=0
    
    debug "Translating $total_blocks subtitle blocks in chunks of $chunk_size"
    
    # Clear target file
    > "$target_file"
    
    for ((i=0; i<total_blocks; i+=chunk_size)); do
        local chunk_end=$((i + chunk_size - 1))
        if [ $chunk_end -ge $total_blocks ]; then
            chunk_end=$((total_blocks - 1))
        fi
        
        debug "Processing chunk $((i / chunk_size + 1)): blocks $((i + 1))-$((chunk_end + 1))"
        
        # Build chunk content
        local chunk_content=""
        for ((j=i; j<=chunk_end; j++)); do
            if [ $j -lt $total_blocks ]; then
                if [ -n "$chunk_content" ]; then
                    chunk_content="$chunk_content"$'\n\n'"${blocks_ref[$j]}"
                else
                    chunk_content="${blocks_ref[$j]}"
                fi
            fi
        done
        
        # Create translation prompt for this chunk
        local prompt="Translate these SRT subtitle entries from English to $lang_name. 

IMPORTANT: Only output the translated SRT content - no explanations or additional text.

Keep the exact same format:
- Same subtitle numbers
- Same timecodes (HH:MM:SS,mmm --> HH:MM:SS,mmm)
- Only translate the subtitle text
- Keep blank lines between entries

Input subtitles:
$chunk_content"

        debug "Chunk prompt length: ${#prompt} characters"
        
        # Call Claude for this chunk
        local claude_output
        local claude_exit_code
        
        claude_output=$(claude --model claude-sonnet-4-20250514 -p "$prompt" 2>&1)
        claude_exit_code=$?
        
        if [ $claude_exit_code -eq 0 ]; then
            # Append translated chunk to target file
            echo "$claude_output" >> "$target_file"
            echo >> "$target_file"  # Add blank line between chunks
            processed=$((chunk_end + 1))
            debug "Successfully translated chunk $((i / chunk_size + 1)), processed $processed/$total_blocks blocks"
        else
            debug "Claude failed for chunk $((i / chunk_size + 1)): $claude_output"
            echo -e "${RED}ERROR${NC} Translation failed for chunk $((i / chunk_size + 1))"
            return 1
        fi
        
    done
    
    debug "All chunks processed successfully"
    return 0
}

# Function to process single translation job (used for concurrent processing)
process_translation_job() {
    local source_file="$1"
    local lang_code="$2"
    local lang_name="$3"
    local job_id="$4"
    
    # Generate target filename
    local target_file="${source_file%.en.srt}.$lang_code.srt"
    
    # Check if target file already exists
    if [ -f "$target_file" ]; then
        echo "[$job_id] SKIP $target_file (already exists)"
        return 0
    fi
    
    # Check if source file exists
    if [ ! -f "$source_file" ]; then
        echo "[$job_id] ERROR Source file does not exist: $source_file"
        return 1
    fi
    
    echo "[$job_id] PROCESSING $(basename "$source_file") -> $lang_name"
    
    local start_time=$(date +%s)
    if translate_file_content_aws "$source_file" "$target_file" "$lang_code"; then
        # Validate line counts
        local source_lines=$(wc -l < "$source_file")
        local target_lines=$(wc -l < "$target_file")
        
        if [ "$source_lines" -eq "$target_lines" ]; then
            # Change ownership if FILE_OWNER is set
            if [ -n "$FILE_OWNER" ] && [ "$FILE_OWNER" != "none" ]; then
                if chown "$FILE_OWNER" "$target_file" 2>/dev/null; then
                    debug "Changed ownership of $target_file to $FILE_OWNER"
                else
                    debug "Failed to change ownership of $target_file (may need root privileges)"
                fi
            fi
            
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            echo "[$job_id] SUCCESS $target_file (${target_lines} lines, ${duration}s)"
            return 0
        else
            echo "[$job_id] ERROR Line count mismatch: source ($source_lines) vs target ($target_lines)"
            return 1
        fi
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "[$job_id] ERROR Translation failed (${duration}s)"
        return 1
    fi
}

# Function to translate a file (legacy function for Claude compatibility)
translate_file() {
    local source_file="$1"
    local lang_code="$2"
    local lang_name="$3"
    
    debug "Starting translation: $source_file -> $lang_code ($lang_name)"
    
    # Generate target filename by replacing .en.srt with .$lang_code.srt
    local target_file="${source_file%.en.srt}.$lang_code.srt"
    debug "Target file: $target_file"
    
    # Ensure target directory exists
    local target_dir=$(dirname "$target_file")
    if [ ! -d "$target_dir" ]; then
        debug "Creating target directory: $target_dir"
        mkdir -p "$target_dir"
    fi
    
    # Check if target file already exists
    if [ -f "$target_file" ]; then
        debug "Target file already exists, skipping"
        echo -e "${YELLOW}SKIP${NC} $target_file (already exists)"
        return 0
    fi
    
    # Check if source file exists
    if [ ! -f "$source_file" ]; then
        debug "Source file not found: $source_file"
        echo -e "${RED}ERROR${NC} Source file does not exist: $source_file"
        return 1
    fi
    
    # Get source file size for debugging
    local file_size=$(stat -c%s "$source_file" 2>/dev/null || echo "unknown")
    debug "Source file size: $file_size bytes"
    
    log "Translating $(basename "$source_file") to $lang_name..."
    
    # Parse SRT file into subtitle blocks
    local subtitle_blocks=()
    parse_srt_file "$source_file" subtitle_blocks
    
    if [ ${#subtitle_blocks[@]} -eq 0 ]; then
        debug "No subtitle blocks found in source file"
        echo -e "${RED}ERROR${NC} No subtitle blocks found in $source_file"
        return 1
    fi
    
    # Translate using selected service
    local translation_start_time=$(date +%s)
    local translation_success=false
    
    if [ "$TRANSLATE_SERVICE" = "aws" ]; then
        debug "Using AWS Translate service"
        if translate_subtitle_chunks_aws "$source_file" "$target_file" "$lang_code" subtitle_blocks; then
            translation_success=true
        fi
    else
        debug "Using Claude translation service"
        if translate_subtitle_chunks "$source_file" "$target_file" "$lang_name" subtitle_blocks; then
            translation_success=true
        fi
    fi
    
    local translation_end_time=$(date +%s)
    local translation_duration=$((translation_end_time - translation_start_time))
    debug "Translation execution time: ${translation_duration}s"
    
    if [ "$translation_success" = true ]; then
        
        # Check if the target file was created and has content
        if [ -f "$target_file" ] && [ -s "$target_file" ]; then
            local target_size=$(stat -c%s "$target_file" 2>/dev/null || echo "unknown")
            debug "Target file created, size: $target_size bytes"
            
            # Validate line counts match between source and target files
            local source_lines=$(wc -l < "$source_file")
            local target_lines=$(wc -l < "$target_file")
            debug "Source file lines: $source_lines, Target file lines: $target_lines"
            
            if [ "$source_lines" -eq "$target_lines" ]; then
                debug "Line count validation passed"
                
                # Change ownership if FILE_OWNER is set
                if [ -n "$FILE_OWNER" ] && [ "$FILE_OWNER" != "none" ]; then
                    if chown "$FILE_OWNER" "$target_file" 2>/dev/null; then
                        debug "Changed ownership of $target_file to $FILE_OWNER"
                    else
                        debug "Failed to change ownership of $target_file (may need root privileges)"
                    fi
                fi
                
                echo -e "${GREEN}SUCCESS${NC} Created $target_file (${target_lines} lines)"
                return 0
            else
                debug "Line count validation failed: source has $source_lines lines, target has $target_lines lines"
                echo -e "${RED}ERROR${NC} Translation incomplete - line count mismatch: source ($source_lines) vs target ($target_lines)"
                return 1
            fi
        else
            debug "Target file missing or empty after translation"
            echo -e "${RED}ERROR${NC} Translation failed - file not created or empty: $target_file"
            return 1
        fi
    else
        echo -e "${RED}ERROR${NC} Translation failed for $source_file -> $lang_name"
        return 1
    fi
}

# Main script for AWS concurrent processing
main_aws_concurrent() {
    local target_dir="${1:-.}"  # Use provided directory or current directory
    
    # Validate directory
    if [ ! -d "$target_dir" ]; then
        echo -e "${RED}ERROR${NC} Directory '$target_dir' does not exist"
        exit 1
    fi
    
    log "Starting ZenDRIVE subtitle translation script (AWS Concurrent Mode)"
    debug "Debug mode: $DEBUG"
    debug "Translation service: $TRANSLATE_SERVICE"
    debug "Target directory: $(realpath "$target_dir")"
    debug "Working directory: $(pwd)"
    log "Target directory: $(realpath "$target_dir")"
    
    # Build language list for display
    local lang_list=""
    for lang_code in "${!LANGUAGES[@]}"; do
        if [ -n "$lang_list" ]; then
            lang_list="$lang_list, ${LANGUAGES[$lang_code]} ($lang_code)"
        else
            lang_list="${LANGUAGES[$lang_code]} ($lang_code)"
        fi
    done
    log "Languages: $lang_list"
    
    # Find all .en.srt files in the target directory
    debug "Searching for *.en.srt files in $target_dir..."
    mapfile -t en_files < <(find "$target_dir" -name "*.en.srt" | sort)
    debug "Find command completed, found ${#en_files[@]} files"
    
    if [ ${#en_files[@]} -eq 0 ]; then
        debug "No .en.srt files found"
        echo -e "${RED}ERROR${NC} No .en.srt files found in $target_dir and subdirectories"
        exit 1
    fi
    
    log "Found ${#en_files[@]} English subtitle files to translate"
    
    # Count totals for progress tracking
    local total_jobs=$((${#en_files[@]} * ${#LANGUAGES[@]}))
    debug "Total translation jobs: $total_jobs (${#en_files[@]} files × ${#LANGUAGES[@]} languages)"
    
    local start_time=$(date +%s)
    
    # Create array of all translation jobs
    local jobs=()
    local job_id=1
    
    for source_file in "${en_files[@]}"; do
        for lang_code in "${!LANGUAGES[@]}"; do
            lang_name="${LANGUAGES[$lang_code]}"
            jobs+=("$source_file|$lang_code|$lang_name|$(printf "%03d" $job_id)")
            ((job_id++))
        done
    done
    
    log "Starting $total_jobs concurrent translation jobs..."
    echo
    
    # Process all jobs with proper concurrent tracking  
    local running_jobs=0
    local completed=0
    local errors=0
    local job_index=0
    
    # Function to wait for any job to complete and update counters
    wait_for_job_completion() {
        local any_completed=false
        local temp_pids=()
        
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                temp_pids+=("$pid")
            else
                # Job completed, check exit status
                wait "$pid"
                if [ $? -eq 0 ]; then
                    ((completed++))
                else
                    ((errors++))
                fi
                ((running_jobs--))
                any_completed=true
            fi
        done
        
        pids=("${temp_pids[@]}")
        
        if [ "$any_completed" = true ]; then
            # Show progress
            local total_processed=$((completed + errors))
            local progress=$((total_processed * 100 / total_jobs))
            echo "Progress: $progress% ($total_processed/$total_jobs) - Success: $completed, Errors: $errors, Running: $running_jobs"
        fi
    }
    
    local pids=()
    
    # Start all jobs immediately - no artificial throttling
    for job in "${jobs[@]}"; do
        IFS='|' read -r source_file lang_code lang_name job_id <<< "$job"
        ((job_index++))
        
        # Start new background job
        (
            if process_translation_job "$source_file" "$lang_code" "$lang_name" "$job_id" 2>&1; then
                exit 0
            else
                exit 1
            fi
        ) &
        
        pids+=($!)
        ((running_jobs++))
        
        # Check for completed jobs periodically for progress updates
        if [ $((job_index % 10)) -eq 0 ]; then
            wait_for_job_completion
        fi
    done
    
    # Wait for all remaining jobs to complete
    log "Waiting for remaining $running_jobs jobs to complete..."
    while [ $running_jobs -gt 0 ]; do
        wait_for_job_completion
        if [ $running_jobs -gt 0 ]; then
            sleep 0.5
        fi
    done
    
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    # Final verification by counting actual files
    local actual_translated_files=$(find "$target_dir" -name "*.srt" -not -name "*.en.srt" | wc -l)
    local expected_translated_files=$((${#en_files[@]} * ${#LANGUAGES[@]}))
    
    echo
    log "Translation complete!"
    log "Jobs processed: $((completed + errors))/$total_jobs"
    log "Successful jobs: $completed"
    log "Failed jobs: $errors"
    log "Files created: $actual_translated_files/$expected_translated_files"
    log "Total time: ${total_duration}s"
    
    # Double-check success by file count
    if [ $actual_translated_files -ge $expected_translated_files ] && [ $errors -eq 0 ]; then
        echo -e "${GREEN}All translations completed successfully!${NC}"
        echo -e "${GREEN}✓ Created $actual_translated_files subtitle files in ${total_duration}s${NC}"
        if [ $actual_translated_files -gt $expected_translated_files ]; then
            echo -e "${YELLOW}Note: Found $actual_translated_files files (expected $expected_translated_files) - some may be from previous runs${NC}"
        fi
        exit 0
    elif [ $actual_translated_files -ge $expected_translated_files ]; then
        echo -e "${YELLOW}All files created despite $errors reported job errors.${NC}"
        echo -e "${GREEN}✓ Created $actual_translated_files subtitle files in ${total_duration}s${NC}"
        if [ $actual_translated_files -gt $expected_translated_files ]; then
            echo -e "${YELLOW}Note: Found $actual_translated_files files (expected $expected_translated_files) - some may be from previous runs${NC}"
        fi
        exit 0
    else
        echo -e "${RED}Translation incomplete!${NC}"
        echo -e "${RED}Expected at least $expected_translated_files files, but only found $actual_translated_files${NC}"
        exit 1
    fi
}

# Main script for Claude sequential processing
main_claude_sequential() {
    local target_dir="${1:-.}"  # Use provided directory or current directory
    
    # Validate directory
    if [ ! -d "$target_dir" ]; then
        echo -e "${RED}ERROR${NC} Directory '$target_dir' does not exist"
        exit 1
    fi
    
    log "Starting ZenDRIVE subtitle translation script (Claude Sequential Mode)"
    debug "Debug mode: $DEBUG"
    debug "Translation service: $TRANSLATE_SERVICE"
    debug "Target directory: $(realpath "$target_dir")"
    debug "Working directory: $(pwd)"
    debug "Script arguments: $*"
    log "Translation service: $TRANSLATE_SERVICE"
    log "Target directory: $(realpath "$target_dir")"
    
    # Build language list for display
    local lang_list=""
    for lang_code in "${!LANGUAGES[@]}"; do
        if [ -n "$lang_list" ]; then
            lang_list="$lang_list, ${LANGUAGES[$lang_code]} ($lang_code)"
        else
            lang_list="${LANGUAGES[$lang_code]} ($lang_code)"
        fi
    done
    log "Languages: $lang_list"
    
    # Find all .en.srt files in the target directory
    debug "Searching for *.en.srt files in $target_dir..."
    mapfile -t en_files < <(find "$target_dir" -name "*.en.srt" | sort)
    debug "Find command completed, found ${#en_files[@]} files"
    
    if [ ${#en_files[@]} -eq 0 ]; then
        debug "No .en.srt files found"
        echo -e "${RED}ERROR${NC} No .en.srt files found in $target_dir and subdirectories"
        exit 1
    fi
    
    log "Found ${#en_files[@]} English subtitle files to translate"
    if [ "$DEBUG" -eq 1 ]; then
        debug "Files found:"
        for file in "${en_files[@]}"; do
            debug "  - $file"
        done
    fi
    
    # Count totals for progress tracking
    local total_files=$((${#en_files[@]} * ${#LANGUAGES[@]}))
    local completed=0
    local errors=0
    debug "Total translation jobs: $total_files (${#en_files[@]} files × ${#LANGUAGES[@]} languages)"
    
    local start_time=$(date +%s)
    
    # Process each file for each language
    for source_file in "${en_files[@]}"; do
        echo
        log "Processing: $(basename "$source_file")"
        debug "Full source path: $source_file"
        
        for lang_code in "${!LANGUAGES[@]}"; do
            lang_name="${LANGUAGES[$lang_code]}"
            debug "Processing language: $lang_code ($lang_name)"
            
            local file_start_time=$(date +%s)
            if translate_file "$source_file" "$lang_code" "$lang_name"; then
                ((completed++))
                debug "Translation successful"
            else
                ((errors++))
                debug "Translation failed"
            fi
            local file_end_time=$(date +%s)
            local file_duration=$((file_end_time - file_start_time))
            debug "File processing time: ${file_duration}s"
            
            # Progress indicator
            local progress=$(( (completed + errors) * 100 / total_files ))
            echo -e "${BLUE}Progress:${NC} $progress% ($((completed + errors))/$total_files) - ${GREEN}$completed success${NC}, ${RED}$errors errors${NC}"
        done
    done
    
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    debug "Total script execution time: ${total_duration}s"
    
    echo
    log "Translation complete!"
    log "Total files processed: $((completed + errors))/$total_files"
    log "Successful translations: $completed"
    log "Errors: $errors"
    
    if [ $errors -eq 0 ]; then
        echo -e "${GREEN}All translations completed successfully!${NC}"
        exit 0
    else
        echo -e "${YELLOW}Completed with $errors errors. Check the output above for details.${NC}"
        exit 1
    fi
}

# Show usage information
show_usage() {
    echo "Usage: $0 [directory]"
    echo
    echo "Translates all .en.srt files to specified languages"
    echo "Default languages: French (fr), Dutch (nl), German (de), Arabic (ar), Japanese (ja), Danish (da)"
    echo
    echo "Arguments:"
    echo "  directory    Directory to search for .en.srt files (default: current directory)"
    echo
    echo "Environment Variables:"
    echo "  TRANSLATE_SERVICE    Translation service to use: 'aws' or 'claude' (default: claude)"
    echo "  TRANSLATE_LANGUAGES  Comma-separated list of language codes (default: fr,nl,de,ar,ja,da)"
    echo "  FILE_OWNER          Ownership for created files as user:group (default: 32574:32574)"
    echo "  DEBUG               Enable debug output: 1 or 0 (default: 0)"
    echo
    echo "Supported Language Codes:"
    echo "  fr=French, nl=Dutch, de=German, ar=Arabic, ja=Japanese, da=Danish"
    echo "  es=Spanish, it=Italian, pt=Portuguese, ko=Korean, zh=Chinese, ru=Russian"
    echo "  hi=Hindi, tr=Turkish, pl=Polish, sv=Swedish, no=Norwegian, fi=Finnish"
    echo
    echo "Examples:"
    echo "  $0                                    # Translate files in current directory using Claude"
    echo "  $0 /path/to/videos                   # Translate files in specified directory using Claude"
    echo "  TRANSLATE_SERVICE=aws $0             # Use AWS Translate (concurrent processing)"
    echo "  TRANSLATE_LANGUAGES=\"es,fr,de\" $0    # Translate only to Spanish, French, and German"
    echo "  TRANSLATE_LANGUAGES=\"es\" $0          # Translate only to Spanish"
    echo "  FILE_OWNER=\"1000:1000\" $0            # Set different ownership"
    echo "  FILE_OWNER=\"none\" $0                 # Don't change ownership"
    echo "  DEBUG=1 $0 /path/to/videos           # Enable debug mode"
}

# Main script dispatcher
main() {
    # Check for help flag
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_usage
        exit 0
    fi
    
    # Check for too many arguments
    if [ $# -gt 1 ]; then
        echo -e "${RED}ERROR${NC} Too many arguments provided"
        echo
        show_usage
        exit 1
    fi
    
    if [ "$TRANSLATE_SERVICE" = "aws" ]; then
        main_aws_concurrent "$@"
    else
        main_claude_sequential "$@"
    fi
}

# Check if required translation service is available
if [ "$TRANSLATE_SERVICE" = "aws" ]; then
    debug "Checking for AWS CLI availability..."
    if ! command -v aws &> /dev/null; then
        debug "AWS CLI not found in PATH"
        echo -e "${RED}ERROR${NC} 'aws' command not found. Please ensure AWS CLI is installed and configured."
        exit 1
    fi
    debug "AWS CLI found: $(which aws)"
    
    # Test AWS credentials
    debug "Testing AWS credentials..."
    if ! aws sts get-caller-identity &> /dev/null; then
        debug "AWS credentials not configured"
        echo -e "${RED}ERROR${NC} AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi
    debug "AWS credentials configured"
else
    debug "Checking for Claude CLI availability..."
    if ! command -v claude &> /dev/null; then
        debug "Claude CLI not found in PATH"
        echo -e "${RED}ERROR${NC} 'claude' command not found. Please ensure Claude CLI is installed and in PATH."
        exit 1
    fi
    debug "Claude CLI found: $(which claude)"
fi

# Show usage information
if [ "$DEBUG" -eq 1 ]; then
    debug "=== DEBUG MODE ENABLED ==="
    debug "To disable debug mode, run: DEBUG=0 $0"
    debug "To enable debug mode, run: DEBUG=1 $0"
    debug "=========================="
    debug "=== TRANSLATION SERVICE ==="
    debug "Current service: $TRANSLATE_SERVICE"
    debug "To use AWS Translate: TRANSLATE_SERVICE=aws $0"
    debug "To use Claude: TRANSLATE_SERVICE=claude $0"
    debug "=========================="
fi

# Run main function
main "$@"
