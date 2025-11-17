#!/bin/bash

# Subtitle Translation Script for ZenDRIVE
# Translates all .en.srt files to specified languages (default: French, Dutch, German, Arabic, Japanese, Danish)
#
# Uses AWS Translate REST API (no AWS CLI required)
# Requires: curl, openssl, od (octal dump)
#
# Usage:
#   ./translate_subtitles.sh [directory]              # Translate in specified directory
#   ./translate_subtitles.sh                          # Translate in current directory
#   DEBUG=1 ./translate_subtitles.sh [directory]      # Enable debug mode
#   TRANSLATE_LANGUAGES="es,fr,de" ./translate_subtitles.sh    # Translate to specific languages

# Debug mode (set to 1 to enable debug output)
DEBUG=${DEBUG:-0}

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

# Function to get AWS credentials
get_aws_credentials() {
    local aws_access_key=""
    local aws_secret_key=""
    local aws_session_token=""

    # Try environment variables first
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
        aws_access_key="$AWS_ACCESS_KEY_ID"
        aws_secret_key="$AWS_SECRET_ACCESS_KEY"
        aws_session_token="${AWS_SESSION_TOKEN:-}"
        debug "Using AWS credentials from environment variables"
    # Try credentials file
    elif [ -f "$HOME/.aws/credentials" ]; then
        local profile="${AWS_PROFILE:-default}"
        aws_access_key=$(grep -A2 "\[$profile\]" "$HOME/.aws/credentials" | grep "aws_access_key_id" | cut -d'=' -f2 | xargs)
        aws_secret_key=$(grep -A2 "\[$profile\]" "$HOME/.aws/credentials" | grep "aws_secret_access_key" | cut -d'=' -f2 | xargs)
        aws_session_token=$(grep -A3 "\[$profile\]" "$HOME/.aws/credentials" | grep "aws_session_token" | cut -d'=' -f2 | xargs)
        debug "Using AWS credentials from credentials file (profile: $profile)"
    fi

    if [ -z "$aws_access_key" ] || [ -z "$aws_secret_key" ]; then
        debug "Failed to retrieve AWS credentials"
        return 1
    fi

    # Return credentials as pipe-separated string
    echo "$aws_access_key|$aws_secret_key|$aws_session_token"
    return 0
}

# Function to create AWS Signature Version 4
# Based on: https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html
sign_aws_request() {
    local method="$1"
    local service="$2"
    local region="$3"
    local host="$4"
    local endpoint="$5"
    local payload="$6"
    local access_key="$7"
    local secret_key="$8"
    local session_token="$9"

    # Get current timestamp
    local amz_date=$(date -u +"%Y%m%dT%H%M%SZ")
    local date_stamp=$(date -u +"%Y%m%d")

    # Create canonical request
    local canonical_uri="$endpoint"
    local canonical_querystring=""
    local canonical_headers="content-type:application/x-amz-json-1.1
host:$host
x-amz-date:$amz_date"

    if [ -n "$session_token" ]; then
        canonical_headers="$canonical_headers
x-amz-security-token:$session_token"
    fi

    local signed_headers="content-type;host;x-amz-date"
    if [ -n "$session_token" ]; then
        signed_headers="$signed_headers;x-amz-security-token"
    fi

    local payload_hash=$(echo -n "$payload" | openssl dgst -sha256 -hex | sed 's/^.* //')

    local canonical_request="$method
$canonical_uri
$canonical_querystring
$canonical_headers

$signed_headers
$payload_hash"

    # Create string to sign
    local algorithm="AWS4-HMAC-SHA256"
    local credential_scope="$date_stamp/$region/$service/aws4_request"
    local canonical_request_hash=$(echo -n "$canonical_request" | openssl dgst -sha256 -hex | sed 's/^.* //')

    local string_to_sign="$algorithm
$amz_date
$credential_scope
$canonical_request_hash"

    # Calculate signature
    # Use od instead of xxd/hexdump for better portability
    local k_secret="AWS4$secret_key"
    local k_date=$(echo -n "$date_stamp" | openssl dgst -sha256 -hmac "$k_secret" -binary)
    local k_region=$(echo -n "$region" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(echo -n "$k_date" | od -A n -t x1 | tr -d ' \n')" -binary)
    local k_service=$(echo -n "$service" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(echo -n "$k_region" | od -A n -t x1 | tr -d ' \n')" -binary)
    local k_signing=$(echo -n "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(echo -n "$k_service" | od -A n -t x1 | tr -d ' \n')" -binary)
    local signature=$(echo -n "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(echo -n "$k_signing" | od -A n -t x1 | tr -d ' \n')" -hex | sed 's/^.* //')

    # Create authorization header
    local authorization_header="$algorithm Credential=$access_key/$credential_scope, SignedHeaders=$signed_headers, Signature=$signature"

    # Return headers as pipe-separated values
    echo "$authorization_header|$amz_date|$session_token"
    return 0
}

# Function to translate text using AWS Translate REST API
translate_text_aws() {
    local text="$1"
    local target_lang="$2"
    local region="us-east-1"

    debug "Translating ${#text} characters to $target_lang using REST API"

    # Get AWS credentials
    local creds
    if ! creds=$(get_aws_credentials); then
        debug "Failed to get AWS credentials"
        return 1
    fi

    IFS='|' read -r access_key secret_key session_token <<< "$creds"

    # Prepare request
    local service="translate"
    local host="translate.$region.amazonaws.com"
    local endpoint="/"
    local method="POST"

    # Create JSON payload - escape special characters in text
    local escaped_text=$(echo -n "$text" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    local payload="{\"Text\":\"$escaped_text\",\"SourceLanguageCode\":\"en\",\"TargetLanguageCode\":\"$target_lang\"}"

    # Sign the request
    local sign_result
    if ! sign_result=$(sign_aws_request "$method" "$service" "$region" "$host" "$endpoint" "$payload" "$access_key" "$secret_key" "$session_token"); then
        debug "Failed to sign AWS request"
        return 1
    fi

    IFS='|' read -r authorization amz_date returned_token <<< "$sign_result"

    # Make the request using curl
    local response
    local http_code

    if [ -n "$session_token" ]; then
        response=$(curl -s -w "\n%{http_code}" -X POST "https://$host$endpoint" \
            -H "Content-Type: application/x-amz-json-1.1" \
            -H "X-Amz-Target: AWSShineFrontendService_20170701.TranslateText" \
            -H "X-Amz-Date: $amz_date" \
            -H "X-Amz-Security-Token: $session_token" \
            -H "Authorization: $authorization" \
            -d "$payload" 2>&1)
    else
        response=$(curl -s -w "\n%{http_code}" -X POST "https://$host$endpoint" \
            -H "Content-Type: application/x-amz-json-1.1" \
            -H "X-Amz-Target: AWSShineFrontendService_20170701.TranslateText" \
            -H "X-Amz-Date: $amz_date" \
            -H "Authorization: $authorization" \
            -d "$payload" 2>&1)
    fi

    # Extract HTTP code and body
    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')

    debug "HTTP response code: $http_code"

    if [ "$http_code" = "200" ]; then
        # Extract TranslatedText from JSON response
        # Using grep and sed to avoid dependency on jq
        local translated_text=$(echo "$body" | grep -o '"TranslatedText":"[^"]*"' | sed 's/"TranslatedText":"//;s/"$//' | sed 's/\\n/\n/g' | sed 's/\\"/"/g')

        if [ -n "$translated_text" ]; then
            echo "$translated_text"
            return 0
        else
            debug "Failed to extract TranslatedText from response: $body"
            return 1
        fi
    else
        debug "AWS Translate API request failed with HTTP $http_code: $body"
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


# Main script for AWS concurrent processing
main_aws_concurrent() {
    local target_dir="${1:-.}"  # Use provided directory or current directory

    # Validate directory
    if [ ! -d "$target_dir" ]; then
        echo -e "${RED}ERROR${NC} Directory '$target_dir' does not exist"
        exit 1
    fi

    log "Starting ZenDRIVE subtitle translation script (AWS Translate REST API)"
    debug "Debug mode: $DEBUG"
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


# Show usage information
show_usage() {
    echo "Usage: $0 [directory]"
    echo
    echo "Translates all .en.srt files to specified languages using AWS Translate REST API"
    echo "Default languages: French (fr), Dutch (nl), German (de), Arabic (ar), Japanese (ja), Danish (da)"
    echo
    echo "Arguments:"
    echo "  directory    Directory to search for .en.srt files (default: current directory)"
    echo
    echo "Environment Variables:"
    echo "  TRANSLATE_LANGUAGES  Comma-separated list of language codes (default: fr,nl,de,ar,ja,da)"
    echo "  FILE_OWNER          Ownership for created files as user:group (default: 32574:32574)"
    echo "  DEBUG               Enable debug output: 1 or 0 (default: 0)"
    echo
    echo "Requirements:"
    echo "  - curl, openssl, od (no AWS CLI required)"
    echo "  - AWS credentials via environment variables or ~/.aws/credentials:"
    echo "    * AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    echo "    * Optional: AWS_SESSION_TOKEN for temporary credentials"
    echo "    * Optional: AWS_PROFILE to select credential profile (default: default)"
    echo
    echo "Supported Language Codes:"
    echo "  fr=French, nl=Dutch, de=German, ar=Arabic, ja=Japanese, da=Danish"
    echo "  es=Spanish, it=Italian, pt=Portuguese, ko=Korean, zh=Chinese, ru=Russian"
    echo "  hi=Hindi, tr=Turkish, pl=Polish, sv=Swedish, no=Norwegian, fi=Finnish"
    echo
    echo "Examples:"
    echo "  $0                                    # Translate files in current directory"
    echo "  $0 /path/to/videos                   # Translate files in specified directory"
    echo "  TRANSLATE_LANGUAGES=\"es,fr,de\" $0    # Translate only to Spanish, French, and German"
    echo "  TRANSLATE_LANGUAGES=\"es\" $0          # Translate only to Spanish"
    echo "  FILE_OWNER=\"1000:1000\" $0            # Set different ownership"
    echo "  FILE_OWNER=\"none\" $0                 # Don't change ownership"
    echo "  DEBUG=1 $0 /path/to/videos           # Enable debug mode"
    echo
    echo "  # Using AWS environment variables:"
    echo "  AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... $0"
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

    main_aws_concurrent "$@"
}

# Check if required tools are available
debug "Checking for required tools (curl, openssl, od)..."

# Check for curl
if ! command -v curl &> /dev/null; then
    debug "curl not found in PATH"
    echo -e "${RED}ERROR${NC} 'curl' command not found. Please install curl to use AWS Translate API."
    exit 1
fi
debug "curl found: $(which curl)"

# Check for openssl
if ! command -v openssl &> /dev/null; then
    debug "openssl not found in PATH"
    echo -e "${RED}ERROR${NC} 'openssl' command not found. Please install openssl to use AWS Translate API."
    exit 1
fi
debug "openssl found: $(which openssl)"

# Check for od
if ! command -v od &> /dev/null; then
    debug "od not found in PATH"
    echo -e "${RED}ERROR${NC} 'od' command not found. Please install od (usually part of coreutils package) to use AWS Translate API."
    exit 1
fi
debug "od found: $(which od)"

# Test AWS credentials availability
debug "Testing AWS credentials availability..."
test_creds=""
if ! test_creds=$(get_aws_credentials); then
    debug "AWS credentials not configured"
    echo -e "${RED}ERROR${NC} AWS credentials not configured."
    echo -e "Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables,"
    echo -e "or configure credentials in ~/.aws/credentials file."
    echo -e ""
    echo -e "Example:"
    echo -e "  export AWS_ACCESS_KEY_ID=your_access_key"
    echo -e "  export AWS_SECRET_ACCESS_KEY=your_secret_key"
    echo -e ""
    echo -e "Or create ~/.aws/credentials with:"
    echo -e "  [default]"
    echo -e "  aws_access_key_id = your_access_key"
    echo -e "  aws_secret_access_key = your_secret_key"
    exit 1
fi
debug "AWS credentials configured"

# Run main function
main "$@"
