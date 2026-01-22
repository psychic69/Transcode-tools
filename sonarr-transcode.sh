#!/bin/bash

# --- Global Binaries and Paths ---
JQ=/usr/bin/jq
FFMPEG="/usr/lib/jellyfin-ffmpeg/ffmpeg" 
FFPROBE="/usr/lib/jellyfin-ffmpeg/ffprobe"
MEDIAINFO="/usr/bin/mediainfo"
DEVICE="/dev/dri/renderD128"
LOG_DIR="/media/rips/logs"
ALLOWED_EXT="mp4,mkv"

export LIBVA_MESSAGING_LEVEL=1

# --- Global Log Definition ---
SHORT_DATE=$(date "+%m-%d-%y")
CURRENT_LOG="$LOG_DIR/logfile-${SHORT_DATE}-PID${$}"

TOTAL_SAVED_BYTES=0
TOTAL_FILES_PROCESSED=0

# ************************************************
function check_helper_bin {
    for bin in "$FFMPEG" "$FFPROBE" "$JQ" "$MEDIAINFO"; do
        if [[ ! -x "$bin" ]]; then echo "ERROR: $bin not found"; exit 1; fi
    done
}

function cleanup_on_exit {
    if [[ -n "$TEMP_IN_DIR" && -f "$TEMP_IN_DIR" ]]; then
        echo "[WARN] Script interrupted. Removing incomplete file: $TEMP_IN_DIR"
        rm -f "$TEMP_IN_DIR"
    fi
    exit 1
}
trap cleanup_on_exit SIGINT SIGTERM

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [-debug] [-plex] [-sonarr] [-keep] [-test] [-full] [-gc <val>] [-file] <input> [output]"
    exit 1
fi

# Parse command line arguments
DEBUG=0; DO_PLEX=0; SONARR=0; KEEP=0; TEST_MODE=0; OVERRIDE_GQ=""; SINGLE_FILE_MODE=0; FULL_SCAN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -debug) DEBUG=1; shift ;;
        -plex)  DO_PLEX=1; shift ;;
        -sonarr) SONARR=1; shift ;;
        -keep) KEEP=1; shift ;;
        -test) TEST_MODE=1; shift ;;
        -full) FULL_SCAN=1; shift ;;
        -file) SINGLE_FILE_MODE=1; shift ;;
        -gc) OVERRIDE_GQ="$2"; shift 2 ;;
        -*) shift ;; 
        *) break ;;  
    esac
done

# --- Path Resolution ---
TV_INPUT_DIR=$(realpath "$1")
if [[ -n "$2" ]]; then
    TV_OUTPUT_DIR=$(realpath "$2")
else
    # Correctly identify parent directory for single-file mode
    if [[ -f "$TV_INPUT_DIR" ]]; then
        TV_OUTPUT_DIR=$(dirname "$TV_INPUT_DIR")
    else
        TV_OUTPUT_DIR="$TV_INPUT_DIR"
    fi
fi

# Load parameter.ini
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAM_FILE="$SCRIPT_DIR/parameter.ini"
if [[ ! -f "$PARAM_FILE" ]]; then echo "ERROR: parameter.ini not found"; exit 1; fi
source "$PARAM_FILE"

# ************************************************
function write_log {
    local short_time=$(date "+%H:%M")
    if [[ -z "$ROTATION_DONE" ]]; then
        local days=${LOG_RETENTION_DAYS:-7}
        find "$LOG_DIR" -name "logfile-*" -type f -mtime +"$days" -delete 2>/dev/null
        ROTATION_DONE=1
    fi
    touch "${CURRENT_LOG}"
    case $1 in
        WARN | INFO | ERROR )
            echo "[$1] (${SHORT_DATE}, ${short_time}) [PID:$$]: $2" >> "${CURRENT_LOG}"
            [[ -t 1 ]] && echo "[$1] $2"
            if [ "$1" = "ERROR" ]; then exit 1; fi ;;
    esac
}

function refresh_plex {
    if [[ $DO_PLEX -eq 1 && -n "$PLEX_TOKEN" && -n "$PLEX_URL" ]]; then
        write_log INFO "Triggering Plex library refresh via API..."
        curl -s -X GET "$PLEX_URL/library/sections/all/refresh?X-Plex-Token=$PLEX_TOKEN" > /dev/null
    fi
}

function refresh_sonarr {
    if [[ $SONARR -eq 1 && -n "$SONARR_API_KEY" && -n "$SONARR_URL" ]]; then
        write_log INFO "Triggering Sonarr RescanSeries via API..."
        curl -s -X POST "$SONARR_URL/api/v3/command" \
             -H "X-Api-Key: $SONARR_API_KEY" \
             -H "Content-Type: application/json" \
             -d '{"name": "RescanSeries"}' > /dev/null
    fi
}

function transcode {
    local gq=28
    [[ -n "$OVERRIDE_GQ" ]] && gq="$OVERRIDE_GQ"
    
    local bf=7; local min_size_mb=100
    INPUT="$1"; BASENAME=$(basename "$INPUT")
    INPUT_DIR=$(dirname "$INPUT")
    OUTPUT_MIRROR_DIR="$2"

    if [[ $SONARR -eq 1 && -n "$sonarr_episodefile_path" ]]; then
        INPUT="$sonarr_episodefile_path"
        BASENAME=$(basename "$INPUT")
        INPUT_DIR=$(dirname "$INPUT")
    fi

    # --- GLOBAL SKIP: Already Optimized or Tagged DV5 ---
    if [[ "$BASENAME" == *"-OPT.mkv" || "$BASENAME" == *"-DV5.mkv" || "$BASENAME" == *"-OPT.mp4" || "$BASENAME" == *"-DV5.mp4" ]]; then
        if [[ "$TV_INPUT_DIR" != "$TV_OUTPUT_DIR" ]]; then
            write_log INFO "Migrating already processed file: $BASENAME"
            mkdir -p "$OUTPUT_MIRROR_DIR" 2>/dev/null
            mv "$INPUT" "$OUTPUT_MIRROR_DIR/$BASENAME"
            ((TOTAL_FILES_PROCESSED++)); return
        else
            [[ $DEBUG -eq 1 ]] && echo "[DEBUG] Already processed, skipping: $BASENAME"
            return
        fi
    fi

    # --- DV PROFILE 5 DETECTION (Highest Reliability) ---
    # We search the entire MediaInfo output for the specific Profile 5 string
    IS_DV5=$($MEDIAINFO "$INPUT" | grep -i "HDR format" | grep "Profile 5")
    
    if [[ -n "$IS_DV5" ]]; then
        NEW_NAME="${BASENAME%.*}-DV5.mkv"
        write_log WARN "Dolby Vision Profile 5 detected! Tagging and bypassing: $NEW_NAME"
        
        if [[ "$INPUT_DIR" == "$OUTPUT_MIRROR_DIR" ]]; then
            mv "$INPUT" "$INPUT_DIR/$NEW_NAME"
        else
            mkdir -p "$OUTPUT_MIRROR_DIR" 2>/dev/null
            mv "$INPUT" "$OUTPUT_MIRROR_DIR/$NEW_NAME"
        fi
        return
    fi

    TEMP_IN_DIR="$INPUT_DIR/.${BASENAME%.*}.av1.tmp"
    rm -f "$TEMP_IN_DIR"*

    # --- METADATA GATHERING ---
    METADATA=$($FFPROBE -v error -show_entries stream=index,codec_name,codec_type,r_frame_rate,channels:stream_tags=language -of json "$INPUT")
    V_CODEC=$(echo "$METADATA" | $JQ -r '.streams[] | select(.codec_type=="video") | .codec_name' | head -n1)
    SRC_FPS=$(echo "$METADATA" | $JQ -r '.streams[] | select(.codec_type=="video") | .r_frame_rate' | head -n1)

    # Audio Ranking: Most Channels > Best Source
    BEST_A_INDEX=-1; MAX_CHANNELS=0; MAX_PRIORITY=0
    while read -r idx codec channels; do
        PRIORITY=1
        case "$codec" in dca|truehd|eac3|ac3) PRIORITY=5 ;; flac) PRIORITY=4 ;; opus|aac) PRIORITY=3 ;; esac
        if (( channels > MAX_CHANNELS )); then MAX_CHANNELS=$channels; MAX_PRIORITY=$PRIORITY; BEST_A_INDEX=$idx
        elif (( channels == MAX_CHANNELS )) && (( PRIORITY > MAX_PRIORITY )); then MAX_PRIORITY=$PRIORITY; BEST_A_INDEX=$idx; fi
    done < <(echo "$METADATA" | $JQ -r '.streams[] | select(.codec_type=="audio") | "\(.index) \(.codec_name) \(.channels)"')

    if [[ "$BEST_A_INDEX" -eq -1 ]]; then write_log WARN "No audio found in $BASENAME"; return; fi

    # Subtitle selection
    BEST_S_INDEX=$(echo "$METADATA" | $JQ -r '.streams[] | select(.codec_type=="subtitle" and (.tags.language=="eng" or .tags.language=="en")) | .index' | head -n1)

    A_INFO=$(echo "$METADATA" | $JQ -r ".streams[] | select(.index==$BEST_A_INDEX)")
    A_CODEC=$(echo "$A_INFO" | $JQ -r '.codec_name'); A_CHANNELS=$(echo "$A_INFO" | $JQ -r '.channels')

    if [[ "$A_CODEC" == "aac" || "$A_CODEC" == "opus" ]]; then AUDIO_OPTS=("-c:a" "copy")
    else
        case $A_CHANNELS in 
            2) A_BIT="128k" ;; 6) A_BIT="256k" ;; 8) A_BIT="320k" ;; *) A_BIT="128k" ;; 
        esac
        AUDIO_OPTS=("-af" "aresample=async=1" "-c:a" "libopus" "-b:a" "$A_BIT" "-vbr" "on")
        [[ $A_CHANNELS -gt 2 ]] && AUDIO_OPTS+=("-mapping_family" "1")
    fi

    COMMON_V_OPTS=("-c:v" "av1_qsv" "-preset" "3" "-global_quality:v" "$gq" "-extbrc" "1" "-b_strategy" "1" "-bf" "$bf" "-g" "600" "-low_power" "0" "-async_depth" "12")

    write_log INFO "Processing: $BASENAME"
    write_log INFO "Video: $V_CODEC | Audio: $A_CODEC ($A_CHANNELS ch) | GQ: $gq"
    
    local log_lvl="error"; [[ $DEBUG -eq 1 ]] && log_lvl="info"
    FFMPEG_CMD=("$FFMPEG" "-hide_banner" "-loglevel" "$log_lvl" "-y" "-init_hw_device" "vaapi=va:$DEVICE" "-init_hw_device" "qsv=hw@va" "-hwaccel" "vaapi" "-hwaccel_device" "va" "-hwaccel_output_format" "vaapi")
    FILTER_OPTS=("-vf" "hwmap=derive_device=qsv,vpp_qsv=format=p010,fps=fps=$SRC_FPS")

    MAP_OPTS=("-map" "0:v:0" "-map" "0:$BEST_A_INDEX")
    [[ -n "$BEST_S_INDEX" ]] && MAP_OPTS+=("-map" "0:$BEST_S_INDEX")

    TEST_OPTS=(); [[ $TEST_MODE -eq 1 ]] && TEST_OPTS=("-t" "300")

    [[ $DEBUG -eq 1 ]] && echo "[DEBUG] Mapping: ${MAP_OPTS[@]}"

    "${FFMPEG_CMD[@]}" -i "$INPUT" "${TEST_OPTS[@]}" \
        "${MAP_OPTS[@]}" -c:s copy -map_metadata -1 \
        "${FILTER_OPTS[@]}" "${COMMON_V_OPTS[@]}" "${AUDIO_OPTS[@]}" \
        -f matroska "$TEMP_IN_DIR" >> "${CURRENT_LOG}" 2>&1
    
    exit_code=$?
    if [ $exit_code -eq 0 ] && [[ -f "$TEMP_IN_DIR" ]]; then
        OLD_SIZE=$(stat -c%s "$INPUT"); NEW_SIZE=$(stat -c%s "$TEMP_IN_DIR")
        SAVINGS=$(echo "scale=2; 100 - ($NEW_SIZE * 100 / $OLD_SIZE)" | bc -l)

        if [[ $(echo "$NEW_SIZE > 104857600" | bc -l) -eq 1 ]] || [[ $TEST_MODE -eq 1 ]]; then
            write_log INFO "Success. Savings: ${SAVINGS}%"
            TOTAL_SAVED_BYTES=$((TOTAL_SAVED_BYTES + (OLD_SIZE - NEW_SIZE)))
            ((TOTAL_FILES_PROCESSED++))

            if [[ $KEEP -eq 1 ]]; then
                mv "$TEMP_IN_DIR" "$OUTPUT_MIRROR_DIR/${BASENAME%.*}-OPT.mkv"
            else
                mv "$TEMP_IN_DIR" "$INPUT_DIR/${BASENAME%.*}-OPT.mkv" && rm "$INPUT"
                if [[ "$INPUT_DIR" != "$OUTPUT_MIRROR_DIR" ]]; then
                    mkdir -p "$OUTPUT_MIRROR_DIR" 2>/dev/null; mv "$INPUT_DIR/${BASENAME%.*}-OPT.mkv" "$OUTPUT_MIRROR_DIR/${BASENAME%.*}-OPT.mkv"
                fi
            fi
        else
            write_log WARN "Safety check failed (file too small). Cleaning up."
            mv "$INPUT" "$INPUT_DIR/ERROR-$BASENAME"
            rm -f "$TEMP_IN_DIR"
        fi
    else
        write_log WARN "FFmpeg failed on $BASENAME. Check log."
        rm -f "$TEMP_IN_DIR"
    fi
}

# --- Main Execution ---
check_helper_bin
write_log INFO "Start. Input: $TV_INPUT_DIR"

# Clean stale tmp files
TEMP_FIND_DIR=$( [[ -f "$TV_INPUT_DIR" ]] && echo "$(dirname "$TV_INPUT_DIR")" || echo "$TV_INPUT_DIR" )
find "$TEMP_FIND_DIR" -maxdepth 2 -name ".*.av1.tmp" -type f -delete 2>/dev/null

if [[ -f "$TV_INPUT_DIR" ]]; then
    transcode "$TV_INPUT_DIR" "$TV_OUTPUT_DIR"
else
    FIND_CMD="find \"$TV_INPUT_DIR\" -type f \( -iname \"*.mkv\" -o -iname \"*.mp4\" \) ! -iname \"*-OPT.mkv\" ! -iname \"*-OPT.mp4\" ! -iname \"*-DV5.mkv\" ! -iname \"*-DV5.mp4\" ! -iname \"*.tmp\" ! -iname \"ERROR-*\""
    [[ $FULL_SCAN -eq 0 ]] && FIND_CMD+=" -mtime -$DAYS_TO_LOOK_BACK"
    
    while IFS= read -r -d '' item; do
        REL_PATH="${item#$TV_INPUT_DIR/}"; SUB_DIR=$(dirname "$REL_PATH")
        if [[ "$SUB_DIR" == "." ]]; then TARGET_OUT="$TV_OUTPUT_DIR"; else TARGET_OUT="$TV_OUTPUT_DIR/$SUB_DIR"; fi
        transcode "$item" "$TARGET_OUT"
    done < <(eval "$FIND_CMD -print0")
    find "$TV_INPUT_DIR" -depth -type d -not -path "$TV_INPUT_DIR" -exec rmdir {} + 2>/dev/null
fi

refresh_sonarr; refresh_plex
write_log INFO "Finished. Files: $TOTAL_FILES_PROCESSED. Total Saved: $(echo "scale=2; $TOTAL_SAVED_BYTES / 1073741824" | bc)GB."