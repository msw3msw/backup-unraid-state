#!/bin/bash

# Backup Unraid State - Docker Edition v2.6.0
# Phase 2: Better Progress (cancel, ETA, current folder)
# Phase 3.5: Local Staging Mode
# RSYNC naming now uses week format

BACKUP_BASE="${BACKUP_BASE:-/backup}"
VM_PATH="${VM_PATH:-/domains}"
APPDATA_PATH="${APPDATA_PATH:-/appdata}"
PLUGINS_PATH="${PLUGINS_PATH:-/plugins}"
TEMPLATES_PATH="${TEMPLATES_PATH:-/boot/config/plugins/dockerMan/templates-user}"
LOG_FILE="${LOG_FILE:-/config/backup.log}"
MAX_BACKUPS="${MAX_BACKUPS:-2}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
VERIFY_BACKUPS="${VERIFY_BACKUPS:-1}"
EXCLUDE_FOLDERS="${EXCLUDE_FOLDERS:-}"
INCREMENTAL="${INCREMENTAL:-0}"
PROGRESS_ENABLED="${PROGRESS_ENABLED:-0}"
STAGING_ENABLED="${STAGING_ENABLED:-0}"
STAGING_DIR="/tmp/backup_staging"
INCREMENTAL_FILE="/config/last_backup_time"
PID_FILE="/config/backup.pid"

# Track if we're being cancelled
CANCELLED=0
CLEANUP_IN_PROGRESS=0

EXCLUDE_PATTERNS=(
    "*/cache/*" "*/Cache/*" "*/logs/*" "*/Logs/*" "*/.cache/*"
    "*/temp/*" "*/tmp/*" "*.log" "*.tmp" "*Transcode*" "*transcodes*"
    # Plex exclusions (reduces 222k+ files to ~1-2k)
    "binhex-plexpass/Library/Application Support/Plex Media Server/Cache"
    "binhex-plexpass/Library/Application Support/Plex Media Server/Logs"
    "binhex-plexpass/Library/Application Support/Plex Media Server/Crash Reports"
    "binhex-plexpass/Library/Application Support/Plex Media Server/Media"
    "binhex-plexpass/Library/Application Support/Plex Media Server/Cache/PhotoTranscoder"
    "binhex-plexpass/Library/Application Support/Plex Media Server/Codecs"
)

# ============== SIGNAL HANDLING ==============
cleanup_on_cancel() {
    if [ "$CLEANUP_IN_PROGRESS" = "1" ]; then
        return
    fi
    CLEANUP_IN_PROGRESS=1
    CANCELLED=1
    
    log "Backup cancelled by user - cleaning up..."
    
    # Clean up staging directory if it exists
    if [ -d "$STAGING_DIR" ]; then
        log "Cleaning up staging directory..."
        rm -rf "$STAGING_DIR"
    fi
    
    # Clean up any partial tar files
    find "${BACKUP_BASE}" -name "*.tmp" -type f -mmin -60 -delete 2>/dev/null
    find "${BACKUP_BASE}" -name "*.partial" -type f -mmin -60 -delete 2>/dev/null
    
    # Remove PID file
    rm -f "$PID_FILE"
    
    progress 100 "Cancelled by user" ""
    log "Cleanup complete - backup cancelled"
    exit 1
}

# Set up signal handlers
trap cleanup_on_cancel SIGTERM SIGINT

# Write PID file for cancel support
echo $$ > "$PID_FILE"

# Progress with ETA: PROGRESS|percent|phase|eta
progress() {
    local percent="$1"
    local phase="$2"
    local eta="${3:-}"
    [ "$PROGRESS_ENABLED" == "1" ] && echo "PROGRESS|${percent}|${phase}|${eta}"
}

# Format seconds to Xm Ys
format_time() {
    local secs="$1"
    local mins=$((secs / 60))
    local remain=$((secs % 60))
    if [ $mins -gt 0 ]; then
        echo "${mins}m ${remain}s"
    else
        echo "${remain}s"
    fi
}

# Format bytes to human readable (using awk, no bc dependency)
format_bytes() {
    local bytes="$1"
    if [ $bytes -ge 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes / 1073741824}")GB"
    elif [ $bytes -ge 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes / 1048576}")MB"
    elif [ $bytes -ge 1024 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes / 1024}")KB"
    else
        echo "${bytes}B"
    fi
}

# Calculate ETA based on bytes processed: calc_eta_bytes start_time processed_bytes total_bytes
calc_eta_bytes() {
    local start_time="$1"
    local processed="$2"
    local total="$3"
    
    local elapsed=$(($(date +%s) - start_time))
    
    if [ "$processed" -gt 0 ] && [ "$elapsed" -gt 2 ]; then
        local bytes_per_sec=$((processed / elapsed))
        if [ "$bytes_per_sec" -gt 0 ]; then
            local remaining_bytes=$((total - processed))
            local remaining_secs=$((remaining_bytes / bytes_per_sec))
            local speed=$(format_bytes $bytes_per_sec)
            echo "$(format_time $remaining_secs) @ ${speed}/s"
            return
        fi
    fi
    echo ""
}

# ============== CONTAINER METADATA COLLECTION ==============
collect_container_metadata() {
    local METADATA_DIR="$1"
    mkdir -p "$METADATA_DIR"
    
    log "Collecting container metadata..."
    
    # Get all container names
    local CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
    
    if [ -z "$CONTAINERS" ]; then
        log "No containers found or docker not accessible"
        return 1
    fi
    
    # Create master mapping file
    local MAPPING_FILE="$METADATA_DIR/container_mapping.json"
    echo '{"containers":[' > "$MAPPING_FILE"
    local FIRST=true
    
    for CONTAINER in $CONTAINERS; do
        # Check for cancellation
        [ "$CANCELLED" = "1" ] && return 1
        
        # Get container inspect data
        local INSPECT=$(docker inspect "$CONTAINER" 2>/dev/null)
        [ -z "$INSPECT" ] && continue
        
        # Extract key info
        local IMAGE=$(echo "$INSPECT" | jq -r '.[0].Config.Image // empty')
        local STATE=$(echo "$INSPECT" | jq -r '.[0].State.Status // empty')
        
        # Find appdata folder by checking volume mounts
        local APPDATA_FOLDER=""
        local VOLUMES=$(echo "$INSPECT" | jq -r '.[0].Mounts[]? | select(.Destination == "/config" or .Destination == "/data") | .Source' 2>/dev/null)
        
        for VOL in $VOLUMES; do
            if [[ "$VOL" == */appdata/* ]]; then
                APPDATA_FOLDER=$(basename "$(dirname "$VOL")" 2>/dev/null)
                [ "$APPDATA_FOLDER" == "appdata" ] && APPDATA_FOLDER=$(basename "$VOL")
                break
            fi
        done
        
        # Also try matching container name to appdata folder
        if [ -z "$APPDATA_FOLDER" ] && [ -d "$APPDATA_PATH/$CONTAINER" ]; then
            APPDATA_FOLDER="$CONTAINER"
        fi
        
        # Check for Unraid template
        local TEMPLATE_FILE=""
        local TEMPLATE_NAME=""
        for tmpl in "$TEMPLATES_PATH"/*.xml; do
            [ ! -f "$tmpl" ] && continue
            if grep -q "<n>$CONTAINER</n>" "$tmpl" 2>/dev/null || \
               grep -q ">$CONTAINER<" "$tmpl" 2>/dev/null; then
                TEMPLATE_FILE="$tmpl"
                TEMPLATE_NAME=$(basename "$tmpl")
                break
            fi
        done
        
        # Save individual container metadata
        local CONTAINER_FILE="$METADATA_DIR/${CONTAINER}.json"
        cat > "$CONTAINER_FILE" << EOF
{
    "container_name": "$CONTAINER",
    "image": "$IMAGE",
    "state": "$STATE",
    "appdata_folder": "$APPDATA_FOLDER",
    "unraid_template": "$TEMPLATE_NAME",
    "inspect": $INSPECT
}
EOF
        
        # Copy Unraid template if exists
        if [ -n "$TEMPLATE_FILE" ] && [ -f "$TEMPLATE_FILE" ]; then
            cp "$TEMPLATE_FILE" "$METADATA_DIR/templates/" 2>/dev/null || {
                mkdir -p "$METADATA_DIR/templates"
                cp "$TEMPLATE_FILE" "$METADATA_DIR/templates/"
            }
        fi
        
        # Add to mapping file
        [ "$FIRST" != "true" ] && echo ',' >> "$MAPPING_FILE"
        FIRST=false
        cat >> "$MAPPING_FILE" << EOF
{
    "name": "$CONTAINER",
    "image": "$IMAGE",
    "appdata_folder": "$APPDATA_FOLDER",
    "template": "$TEMPLATE_NAME"
}
EOF
        
        log "  - $CONTAINER -> $APPDATA_FOLDER (image: $IMAGE)"
    done
    
    echo ']}' >> "$MAPPING_FILE"
    
    # Count what we collected
    local COUNT=$(echo "$CONTAINERS" | wc -w)
    log "Collected metadata for $COUNT containers"
    
    return 0
}

# Calculate ETA: calc_eta elapsed_secs done_units total_units
calc_eta() {
    local elapsed="$1"
    local done="$2"
    local total="$3"
    
    if [ "$done" -gt 0 ] && [ "$done" -lt "$total" ]; then
        local avg=$((elapsed / done))
        local remaining=$(((total - done) * avg))
        format_time $remaining
    else
        echo ""
    fi
}

# Get backup directory for specific backup type and naming scheme
get_backup_dir() {
    local backup_type="$1"
    local naming_scheme="${2:-weekly}"
    
    # Determine mode suffix for appdata backups
    local mode_suffix=""
    if [ "$backup_type" = "appdata" ]; then
        if [ "$INCREMENTAL" = "1" ]; then
            mode_suffix="_rsync"
        else
            mode_suffix="_tar"
        fi
    fi
    
    case "$backup_type" in
        appdata)
            echo "$BACKUP_BASE/backup_${naming_scheme}${mode_suffix}"
            ;;
        vm)
            echo "$BACKUP_BASE/VMs"
            ;;
        plugins)
            echo "$BACKUP_BASE/plugins"
            ;;
        flash)
            echo "$BACKUP_BASE/flash"
            ;;
        *)
            echo "$BACKUP_BASE"
            ;;
    esac
}

# Get backup name tag based on naming scheme (UNIFIED for both TAR and RSYNC)
get_backup_name() {
    local naming_scheme="${1:-weekly}"
    case "$naming_scheme" in
        daily) echo "day$(date +%u)_week$(printf '%02d' $(date +%V))" ;;
        weekly) echo "week$(printf '%02d' $(date +%V))" ;;
        monthly) echo "$(date +%B_%Y)" ;;
        *) echo "week$(printf '%02d' $(date +%V))" ;;
    esac
}

# Alias for backward compatibility
get_backup_tag() {
    get_backup_name "$1"
}

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

build_exclude_args() {
    local args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        args="$args --exclude=$pattern"
    done
    if [ -n "$EXCLUDE_FOLDERS" ]; then
        IFS=',' read -ra FOLDERS <<< "$EXCLUDE_FOLDERS"
        for folder in "${FOLDERS[@]}"; do
            [ -n "$folder" ] && args="$args --exclude=./$folder --exclude=$folder"
        done
    fi
    echo "$args"
}

verify_backup() {
    local backup_file="$1"
    [ "$VERIFY_BACKUPS" != "1" ] && return 0
    
    log "Verifying backup integrity..."
    if [[ "$backup_file" == *.tar.gz ]]; then
        gzip -t "$backup_file" 2>/dev/null && log "✓ Verification PASSED" && return 0
    elif [[ "$backup_file" == *.tar ]]; then
        tar -tf "$backup_file" >/dev/null 2>&1 && log "✓ Verification PASSED" && return 0
    fi
    log "✗ Verification FAILED"
    return 1
}

cleanup_old_backups() {
    local pattern="$1"
    local backup_dir="$2"
    [ ! -d "$backup_dir" ] && return
    cd "$backup_dir" || return
    ls -t $pattern 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | while read file; do
        log "Removing old: $file"
        rm -f "$file" "${file%.tar.gz}.metadata.json" "${file%.tar}.metadata.json" 2>/dev/null
    done
}

# Transfer from staging to destination
transfer_from_staging() {
    local source="$1"
    local dest="$2"
    local description="${3:-files}"
    
    log "Transferring $description to NAS..."
    progress 90 "Transferring to NAS..." ""
    
    local transfer_start=$(date +%s)
    local source_size=$(du -sb "$source" 2>/dev/null | cut -f1)
    
    # Use rsync for reliable transfer
    # -O (--omit-dir-times) prevents "failed to set times" warnings on CIFS/SMB
    rsync -aO --remove-source-files "$source" "$dest" 2>&1 | grep -v "failed to set times"
    
    local transfer_elapsed=$(($(date +%s) - transfer_start))
    log "Transfer completed in $(format_time $transfer_elapsed)"
    
    # Clean up empty staging directory
    rm -rf "$STAGING_DIR" 2>/dev/null
    
    return 0
}

# ============== VM BACKUP ==============
backup_vm() {
    local VM_NAME="$1"
    local VM_HANDLING="$2"
    local COMPRESS="$3"
    local NAMING_SCHEME="${4:-weekly}"
    
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    BACKUP_DIR=$(get_backup_dir "vm" "$NAMING_SCHEME")
    START_TIME=$(date +%s)
    
    # VM backup uses elapsed time (not ETA) because it's one big file
    progress 0 "Initializing VM backup" "elapsed:0s"
    
    log "=========================================="
    log "Starting VM backup: $VM_NAME"
    log "=========================================="
    
    mkdir -p "$BACKUP_DIR"
    
    [ "$COMPRESS" == "1" ] && BACKUP_FILE="$BACKUP_DIR/${VM_NAME}_${BACKUP_TAG}.tar.gz" || BACKUP_FILE="$BACKUP_DIR/${VM_NAME}_${BACKUP_TAG}.tar"
    
    # Check VM
    ELAPSED=$(($(date +%s) - START_TIME))
    progress 5 "Checking VM status" "elapsed:$(format_time $ELAPSED)"
    
    if ! virsh dominfo "$VM_NAME" &>/dev/null; then
        log "ERROR: VM '$VM_NAME' not found"
        progress 100 "Error: VM not found" ""
        rm -f "$PID_FILE"
        return 1
    fi
    
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
    log "VM state: $VM_STATE"
    
    # Get disk info
    ELAPSED=$(($(date +%s) - START_TIME))
    progress 10 "Getting VM disk info" "elapsed:$(format_time $ELAPSED)"
    
    VM_DISK_HOST=$(virsh domblklist "$VM_NAME" | grep -E 'vd|hd|sd' | awk '{print $2}' | head -1)
    VM_DISK=$(echo "$VM_DISK_HOST" | sed 's|/mnt/user/domains|/domains|')
    
    if [ ! -f "$VM_DISK" ]; then
        log "ERROR: VM disk not accessible: $VM_DISK"
        progress 100 "Error: Disk not accessible" ""
        rm -f "$PID_FILE"
        return 1
    fi
    
    # Get disk size for logging
    VM_SIZE=$(du -h "$VM_DISK" 2>/dev/null | cut -f1)
    log "VM disk: $VM_DISK ($VM_SIZE)"
    
    VM_XML=$(virsh dumpxml "$VM_NAME" 2>/dev/null)
    
    # Save metadata
    METADATA_FILE="${BACKUP_FILE%.tar.gz}.metadata.json"
    [ "$COMPRESS" == "0" ] && METADATA_FILE="${BACKUP_FILE%.tar}.metadata.json"
    cat > "$METADATA_FILE" << EOF
{"backup_type":"vm","vm_name":"$VM_NAME","vm_disk_path":"$VM_DISK_HOST","backup_date":"$(date -Iseconds)","backup_tag":"$BACKUP_TAG","compressed":$COMPRESS,"original_state":"$VM_STATE"}
EOF
    
    # Stop VM if needed
    NEED_RESTART=false
    if [ "$VM_HANDLING" == "stop" ] && [ "$VM_STATE" == "running" ]; then
        ELAPSED=$(($(date +%s) - START_TIME))
        progress 15 "Shutting down VM" "elapsed:$(format_time $ELAPSED)"
        log "Shutting down VM..."
        virsh shutdown "$VM_NAME"
        NEED_RESTART=true
        
        for i in {1..60}; do
            [ "$CANCELLED" = "1" ] && cleanup_on_cancel
            sleep 1
            VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
            [ "$VM_STATE" == "shut off" ] && break
            ELAPSED=$(($(date +%s) - START_TIME))
            progress 15 "Waiting for shutdown ($i/60)" "elapsed:$(format_time $ELAPSED)"
        done
        
        [ "$VM_STATE" != "shut off" ] && virsh destroy "$VM_NAME" && sleep 2
        log "VM stopped"
    fi
    
    # Check for cancellation
    [ "$CANCELLED" = "1" ] && cleanup_on_cancel
    
    # Create archive - this is the long part, update elapsed time periodically
    ELAPSED=$(($(date +%s) - START_TIME))
    progress 20 "Creating archive ($VM_SIZE)" "elapsed:$(format_time $ELAPSED)"
    log "Creating backup archive..."
    
    # Run tar in background and update progress with elapsed time
    if [ "$COMPRESS" == "1" ]; then
        tar -I "gzip -$COMPRESSION_LEVEL" -cf "$BACKUP_FILE" -C "$(dirname "$VM_DISK")" "$(basename "$VM_DISK")" 2>&1 &
    else
        tar -cf "$BACKUP_FILE" -C "$(dirname "$VM_DISK")" "$(basename "$VM_DISK")" 2>&1 &
    fi
    TAR_PID=$!
    
    # Update elapsed time while tar runs
    while kill -0 $TAR_PID 2>/dev/null; do
        [ "$CANCELLED" = "1" ] && { kill $TAR_PID 2>/dev/null; cleanup_on_cancel; }
        sleep 3
        ELAPSED=$(($(date +%s) - START_TIME))
        CURRENT_SIZE=$(du -h "$BACKUP_FILE" 2>/dev/null | cut -f1 || echo "0")
        progress 25 "Archiving: $CURRENT_SIZE" "elapsed:$(format_time $ELAPSED)"
    done
    wait $TAR_PID
    
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "Archive created: $BACKUP_SIZE"
    
    # Verify
    ELAPSED=$(($(date +%s) - START_TIME))
    progress 85 "Verifying ($BACKUP_SIZE)" "elapsed:$(format_time $ELAPSED)"
    verify_backup "$BACKUP_FILE"
    
    # Restart VM if needed
    if [ "$NEED_RESTART" == "true" ]; then
        ELAPSED=$(($(date +%s) - START_TIME))
        progress 92 "Restarting VM" "elapsed:$(format_time $ELAPSED)"
        log "Restarting VM..."
        virsh start "$VM_NAME"
    fi
    
    # Cleanup
    ELAPSED=$(($(date +%s) - START_TIME))
    progress 96 "Cleaning up" "elapsed:$(format_time $ELAPSED)"
    cleanup_old_backups "${VM_NAME}_*.tar*" "$BACKUP_DIR"
    
    DURATION=$(($(date +%s) - START_TIME))
    progress 100 "Complete in $(format_time $DURATION)" ""
    log "VM backup completed in $(format_time $DURATION)"
    rm -f "$PID_FILE"
}

# ============== APPDATA BACKUP ==============
backup_appdata() {
    local BACKUP_TYPE="$1"
    shift
    
    local NAMING_SCHEME="weekly"
    local CUSTOM_FOLDERS=()
    
    for arg in "$@"; do
        if [[ "$arg" == "daily" || "$arg" == "weekly" || "$arg" == "monthly" ]]; then
            NAMING_SCHEME="$arg"
        else
            CUSTOM_FOLDERS+=("$arg")
        fi
    done
    
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    BACKUP_DIR=$(get_backup_dir "appdata" "$NAMING_SCHEME")
    EXCLUDE_ARGS=$(build_exclude_args)
    START_TIME=$(date +%s)
    
    # Determine actual backup destination (staging or direct)
    local ACTUAL_DEST="$BACKUP_DIR"
    local USING_STAGING=false
    
    if [ "$STAGING_ENABLED" = "1" ]; then
        USING_STAGING=true
        ACTUAL_DEST="$STAGING_DIR/appdata_backup"
        mkdir -p "$ACTUAL_DEST"
        log "Staging mode enabled - backing up to local disk first"
    fi
    
    progress 0 "Initializing appdata backup" ""
    
    log "=========================================="
    log "Starting appdata backup"
    log "Mode: $([ "$INCREMENTAL" == "1" ] && echo "Incremental (rsync+hardlinks)" || echo "Full (tar archive)")"
    [ "$USING_STAGING" = true ] && log "Staging: Enabled (local disk first)"
    log "=========================================="
    
    mkdir -p "$ACTUAL_DEST"
    mkdir -p "$BACKUP_DIR"  # Also ensure final destination exists
    
    if [ "$BACKUP_TYPE" == "all" ]; then
        # Get all folders
        mapfile -t ALL_FOLDERS < <(find "$APPDATA_PATH" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
        TOTAL_FOLDERS=${#ALL_FOLDERS[@]}
        
        # Calculate total size for better ETA
        TOTAL_BYTES=0
        for FOLDER in "${ALL_FOLDERS[@]}"; do
            FOLDER_BYTES=$(du -sb "$APPDATA_PATH/$FOLDER" 2>/dev/null | cut -f1 || echo 0)
            TOTAL_BYTES=$((TOTAL_BYTES + FOLDER_BYTES))
        done
        
        progress 2 "Found $TOTAL_FOLDERS folders ($(format_bytes $TOTAL_BYTES))" ""
        log "Found $TOTAL_FOLDERS folders to backup ($(format_bytes $TOTAL_BYTES))"
        
        if [ "$INCREMENTAL" == "1" ]; then
            # ============== RSYNC + HARDLINKS MODE ==============
            INCREMENTAL_DIR="$ACTUAL_DEST/snapshots"
            mkdir -p "$INCREMENTAL_DIR"
            
            # Use week format for RSYNC snapshots (matches TAR naming!)
            CURRENT_BACKUP="$INCREMENTAL_DIR/$(get_backup_name "$NAMING_SCHEME")"
            
            # Find most recent previous backup for hardlinking (look for week* pattern)
            PREVIOUS_BACKUP=$(ls -1d "$INCREMENTAL_DIR"/week* "$INCREMENTAL_DIR"/day* 2>/dev/null | sort -r | head -1)
            
            # Also check old format for migration
            if [ -z "$PREVIOUS_BACKUP" ]; then
                PREVIOUS_BACKUP=$(ls -1d "$INCREMENTAL_DIR"/20* 2>/dev/null | sort -r | head -1)
            fi
            
            if [ -n "$PREVIOUS_BACKUP" ] && [ -d "$PREVIOUS_BACKUP" ]; then
                log "Linking unchanged files to: $(basename "$PREVIOUS_BACKUP")"
                LINK_DEST="--link-dest=$PREVIOUS_BACKUP"
            else
                log "No previous backup found - creating full backup"
                LINK_DEST=""
            fi
            
            # Build rsync exclude args
            RSYNC_EXCLUDES=""
            for pattern in "${EXCLUDE_PATTERNS[@]}"; do
                RSYNC_EXCLUDES="$RSYNC_EXCLUDES --exclude=$pattern"
            done
            if [ -n "$EXCLUDE_FOLDERS" ]; then
                IFS=',' read -ra FOLDERS <<< "$EXCLUDE_FOLDERS"
                for folder in "${FOLDERS[@]}"; do
                    [ -n "$folder" ] && RSYNC_EXCLUDES="$RSYNC_EXCLUDES --exclude=$folder"
                done
            fi
            
            # Rsync each folder with progress
            CURRENT=0
            PROCESSED_BYTES=0
            mkdir -p "$CURRENT_BACKUP"
            
            for FOLDER in "${ALL_FOLDERS[@]}"; do
                # Check for cancellation
                [ "$CANCELLED" = "1" ] && cleanup_on_cancel
                
                CURRENT=$((CURRENT + 1))
                PERCENT=$((5 + (CURRENT * 85 / TOTAL_FOLDERS)))
                ELAPSED=$(($(date +%s) - START_TIME))
                
                # Get folder info
                FOLDER_BYTES=$(du -sb "$APPDATA_PATH/$FOLDER" 2>/dev/null | cut -f1 || echo 0)
                FILE_COUNT=$(find "$APPDATA_PATH/$FOLDER" -type f 2>/dev/null | wc -l)
                FOLDER_SIZE=$(format_bytes $FOLDER_BYTES)
                
                # Calculate ETA based on bytes
                ETA_STR=$(calc_eta_bytes $START_TIME $PROCESSED_BYTES $TOTAL_BYTES)
                
                # Show current folder with count
                local PHASE_STR="$FOLDER ($CURRENT/$TOTAL_FOLDERS)"
                [ "$USING_STAGING" = true ] && PHASE_STR="[Staging] $PHASE_STR"
                
                progress $PERCENT "$PHASE_STR" "$ETA_STR"
                log "[$CURRENT/$TOTAL_FOLDERS] Syncing: $FOLDER ($FILE_COUNT files, $FOLDER_SIZE)"
                
                eval rsync -a $LINK_DEST $RSYNC_EXCLUDES "$APPDATA_PATH/$FOLDER" "$CURRENT_BACKUP/" 2>/dev/null
                
                PROCESSED_BYTES=$((PROCESSED_BYTES + FOLDER_BYTES))
            done
            
            # Save metadata
            cat > "$CURRENT_BACKUP/.metadata.json" << EOF
{"backup_type":"appdata_incremental","mode":"rsync_hardlinks","folders":$TOTAL_FOLDERS,"backup_date":"$(date -Iseconds)","previous":"$(basename "$PREVIOUS_BACKUP" 2>/dev/null)"}
EOF
            
            # Calculate actual disk usage (shows hardlink savings)
            BACKUP_SIZE=$(du -sh "$CURRENT_BACKUP" | cut -f1)
            BACKUP_BYTES=$(du -sb "$CURRENT_BACKUP" | cut -f1)
            ACTUAL_SIZE=$(du -sh --apparent-size "$CURRENT_BACKUP" | cut -f1)
            log "Backup size: $BACKUP_SIZE (apparent: $ACTUAL_SIZE)"
            
            # Save size to file for fast lookup (avoids slow du over network)
            echo "$BACKUP_BYTES" > "$CURRENT_BACKUP/.backup_size"
            
            # Transfer from staging if enabled
            if [ "$USING_STAGING" = true ]; then
                local TRANSFER_START=$(date +%s)
                local TRANSFER_SIZE_MB=$((BACKUP_BYTES / 1048576))
                
                progress 92 "Transferring to NAS... (${TRANSFER_SIZE_MB}MB)" "starting..."
                log "Transferring from staging to NAS..."
                
                # Ensure destination structure exists
                mkdir -p "$BACKUP_DIR/snapshots"
                
                # Use rsync for cross-device transfer (mv fails across filesystems)
                # -O (--omit-dir-times) prevents "failed to set times" warnings on CIFS/SMB
                # Remove existing target first if it exists
                local TARGET_DIR="$BACKUP_DIR/snapshots/$(basename "$CURRENT_BACKUP")"
                [ -d "$TARGET_DIR" ] && rm -rf "$TARGET_DIR"
                
                # Run rsync in background and update progress every 5 seconds
                rsync -aO "$CURRENT_BACKUP/" "$TARGET_DIR/" 2>&1 | grep -v "failed to set times" &
                local RSYNC_PID=$!
                
                while kill -0 $RSYNC_PID 2>/dev/null; do
                    sleep 5
                    local ELAPSED=$(($(date +%s) - TRANSFER_START))
                    progress 92 "Transferring to NAS... (${TRANSFER_SIZE_MB}MB)" "elapsed:$(format_time $ELAPSED)"
                done
                wait $RSYNC_PID
                
                local TRANSFER_ELAPSED=$(($(date +%s) - TRANSFER_START))
                rm -rf "$STAGING_DIR"
                log "Transfer complete in $(format_time $TRANSFER_ELAPSED)"
            fi
            
            # Cleanup old snapshots - count ALL formats together
            progress 98 "Cleaning up old snapshots" ""
            # Get all snapshots sorted by modification time (newest first)
            local ALL_SNAPSHOTS=$(ls -1td "$BACKUP_DIR/snapshots"/*/ 2>/dev/null)
            local SNAPSHOT_COUNT=0
            
            for snapshot in $ALL_SNAPSHOTS; do
                SNAPSHOT_COUNT=$((SNAPSHOT_COUNT + 1))
                if [ $SNAPSHOT_COUNT -gt $MAX_BACKUPS ]; then
                    [ "$CANCELLED" = "1" ] && break
                    log "Removing old snapshot: $(basename "$snapshot")"
                    rm -rf "$snapshot"
                fi
            done
            
        else
            # ============== FULL TAR ARCHIVE MODE ==============
            BACKUP_FILE="$ACTUAL_DEST/appdata_FULL_${BACKUP_TAG}.tar.gz"
            TAR_FILE="$ACTUAL_DEST/appdata_FULL_${BACKUP_TAG}.tar"
            [ "$USING_STAGING" = true ] && BACKUP_FILE="$ACTUAL_DEST/appdata_FULL_${BACKUP_TAG}.tar.gz"
            [ "$USING_STAGING" = true ] && TAR_FILE="$ACTUAL_DEST/appdata_FULL_${BACKUP_TAG}.tar"
            FINAL_BACKUP_FILE="$BACKUP_DIR/appdata_FULL_${BACKUP_TAG}.tar.gz"
            METADATA_FILE="${FINAL_BACKUP_FILE%.tar.gz}.metadata.json"
            
            echo "{\"backup_type\":\"appdata_full\",\"folders\":$TOTAL_FOLDERS,\"backup_date\":\"$(date -Iseconds)\",\"backup_tag\":\"$BACKUP_TAG\"}" > "$METADATA_FILE"
            
            rm -f "$BACKUP_FILE" "$TAR_FILE"
            
            CURRENT=0
            PROCESSED_BYTES=0
            for FOLDER in "${ALL_FOLDERS[@]}"; do
                # Check for cancellation
                [ "$CANCELLED" = "1" ] && cleanup_on_cancel
                
                CURRENT=$((CURRENT + 1))
                PERCENT=$((5 + (CURRENT * 80 / TOTAL_FOLDERS)))
                ELAPSED=$(($(date +%s) - START_TIME))
                
                # Get folder info
                FOLDER_BYTES=$(du -sb "$APPDATA_PATH/$FOLDER" 2>/dev/null | cut -f1 || echo 0)
                FILE_COUNT=$(find "$APPDATA_PATH/$FOLDER" -type f 2>/dev/null | wc -l)
                FOLDER_SIZE=$(format_bytes $FOLDER_BYTES)
                
                # Calculate ETA based on bytes
                ETA_STR=$(calc_eta_bytes $START_TIME $PROCESSED_BYTES $TOTAL_BYTES)
                
                # Show current folder with count
                local PHASE_STR="$FOLDER ($CURRENT/$TOTAL_FOLDERS)"
                [ "$USING_STAGING" = true ] && PHASE_STR="[Staging] $PHASE_STR"
                
                progress $PERCENT "$PHASE_STR" "$ETA_STR"
                log "[$CURRENT/$TOTAL_FOLDERS] Backing up: $FOLDER ($FILE_COUNT files, $FOLDER_SIZE)"
                
                if [ $CURRENT -eq 1 ]; then
                    eval tar -cf "$TAR_FILE" $EXCLUDE_ARGS -C "$APPDATA_PATH" "$FOLDER" 2>/dev/null
                else
                    eval tar -rf "$TAR_FILE" $EXCLUDE_ARGS -C "$APPDATA_PATH" "$FOLDER" 2>/dev/null
                fi
                
                PROCESSED_BYTES=$((PROCESSED_BYTES + FOLDER_BYTES))
            done
            
            [ "$CANCELLED" = "1" ] && cleanup_on_cancel
            
            local COMPRESS_PHASE="Compressing archive"
            [ "$USING_STAGING" = true ] && COMPRESS_PHASE="[Staging] Compressing archive"
            progress 88 "$COMPRESS_PHASE" ""
            log "Compressing archive..."
            gzip -$COMPRESSION_LEVEL "$TAR_FILE"
            
            BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
            BACKUP_BYTES=$(du -b "$BACKUP_FILE" | cut -f1)
            log "Archive created: $BACKUP_SIZE"
            
            # Transfer from staging if enabled
            if [ "$USING_STAGING" = true ]; then
                local TRANSFER_START=$(date +%s)
                local TRANSFER_SIZE_MB=$((BACKUP_BYTES / 1048576))
                
                progress 92 "Transferring to NAS... (${BACKUP_SIZE})" "starting..."
                log "Transferring from staging to NAS..."
                
                # Try mv first, fall back to cp+rm for cross-device
                # Run in background for progress updates
                (
                    if ! mv "$BACKUP_FILE" "$FINAL_BACKUP_FILE" 2>/dev/null; then
                        cp "$BACKUP_FILE" "$FINAL_BACKUP_FILE"
                        rm -f "$BACKUP_FILE"
                    fi
                ) &
                local TRANSFER_PID=$!
                
                while kill -0 $TRANSFER_PID 2>/dev/null; do
                    sleep 3
                    local ELAPSED=$(($(date +%s) - TRANSFER_START))
                    progress 92 "Transferring to NAS... (${BACKUP_SIZE})" "elapsed:$(format_time $ELAPSED)"
                done
                wait $TRANSFER_PID
                
                local TRANSFER_ELAPSED=$(($(date +%s) - TRANSFER_START))
                rm -rf "$STAGING_DIR"
                BACKUP_FILE="$FINAL_BACKUP_FILE"
                
                log "Transfer complete in $(format_time $TRANSFER_ELAPSED)"
            fi
            
            progress 95 "Verifying ($BACKUP_SIZE)" ""
            verify_backup "$BACKUP_FILE"
            
            progress 98 "Cleaning up" ""
            cleanup_old_backups "appdata_FULL_*.tar.gz" "$BACKUP_DIR"
        fi
        
    else
        # Custom folder backup (always tar)
        TOTAL_FOLDERS=${#CUSTOM_FOLDERS[@]}
        CURRENT=0
        
        for FOLDER in "${CUSTOM_FOLDERS[@]}"; do
            [ "$CANCELLED" = "1" ] && cleanup_on_cancel
            
            CURRENT=$((CURRENT + 1))
            PERCENT=$((CURRENT * 95 / TOTAL_FOLDERS))
            ELAPSED=$(($(date +%s) - START_TIME))
            
            progress $PERCENT "$FOLDER ($CURRENT/$TOTAL_FOLDERS)" "elapsed:$(format_time $ELAPSED)"
            log "[$CURRENT/$TOTAL_FOLDERS] Backing up: $FOLDER"
            
            BACKUP_FILE="$BACKUP_DIR/containers/${FOLDER}/${FOLDER}_${BACKUP_TAG}.tar.gz"
            mkdir -p "$(dirname "$BACKUP_FILE")"
            
            [ -d "$APPDATA_PATH/$FOLDER" ] && eval tar -czf "$BACKUP_FILE" $EXCLUDE_ARGS -C "$APPDATA_PATH" "$FOLDER" 2>/dev/null
            
            cleanup_old_backups "${FOLDER}_*.tar.gz" "$BACKUP_DIR/containers/${FOLDER}"
        done
    fi
    
    # Collect container metadata for restore support
    ELAPSED=$(($(date +%s) - START_TIME))
    progress 99 "Collecting container metadata" "elapsed:$(format_time $ELAPSED)"
    collect_container_metadata "$BACKUP_DIR/container_metadata"
    
    DURATION=$(($(date +%s) - START_TIME))
    progress 100 "Complete in $(format_time $DURATION)" ""
    log "Appdata backup completed in $(format_time $DURATION)"
    rm -f "$PID_FILE"
}

# ============== PLUGINS BACKUP ==============
backup_plugins() {
    local NAMING_SCHEME="${1:-weekly}"
    
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    BACKUP_DIR=$(get_backup_dir "plugins" "$NAMING_SCHEME")
    START_TIME=$(date +%s)
    
    progress 0 "Initializing plugins backup" ""
    
    log "=========================================="
    log "Starting plugins backup"
    log "=========================================="
    
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/plugins_${BACKUP_TAG}.tar.gz"
    TAR_FILE="$BACKUP_DIR/plugins_${BACKUP_TAG}.tar"
    
    # Get plugin folders
    mapfile -t PLUGIN_FOLDERS < <(find "$PLUGINS_PATH" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
    TOTAL=${#PLUGIN_FOLDERS[@]}
    
    progress 5 "Found $TOTAL plugin configs" ""
    log "Found $TOTAL plugin configurations"
    
    # Remove old file
    rm -f "$BACKUP_FILE" "$TAR_FILE"
    
    # Backup each plugin folder
    CURRENT=0
    for PLUGIN in "${PLUGIN_FOLDERS[@]}"; do
        [ "$CANCELLED" = "1" ] && cleanup_on_cancel
        
        CURRENT=$((CURRENT + 1))
        PERCENT=$((5 + (CURRENT * 80 / TOTAL)))
        ELAPSED=$(($(date +%s) - START_TIME))
        
        progress $PERCENT "$PLUGIN ($CURRENT/$TOTAL)" "elapsed:$(format_time $ELAPSED)"
        log "[$CURRENT/$TOTAL] Backing up: $PLUGIN"
        
        if [ $CURRENT -eq 1 ]; then
            tar -cf "$TAR_FILE" -C "$PLUGINS_PATH" "$PLUGIN" 2>/dev/null
        else
            tar -rf "$TAR_FILE" -C "$PLUGINS_PATH" "$PLUGIN" 2>/dev/null
        fi
    done
    
    # Also get loose files in plugins directory
    tar -rf "$TAR_FILE" -C "$PLUGINS_PATH" --exclude='*/' . 2>/dev/null || true
    
    # Compress
    progress 90 "Compressing archive" ""
    gzip -$COMPRESSION_LEVEL "$TAR_FILE"
    
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "Archive created: $BACKUP_SIZE"
    
    progress 95 "Verifying ($BACKUP_SIZE)" ""
    verify_backup "$BACKUP_FILE"
    
    progress 98 "Cleaning up" ""
    cleanup_old_backups "plugins_*.tar.gz" "$BACKUP_DIR"
    
    DURATION=$(($(date +%s) - START_TIME))
    progress 100 "Complete in $(format_time $DURATION)" ""
    log "Plugins backup completed in $(format_time $DURATION)"
    rm -f "$PID_FILE"
}

# ============== FLASH BACKUP ==============
backup_flash() {
    local NAMING_SCHEME="${1:-weekly}"
    
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    BACKUP_DIR=$(get_backup_dir "flash" "$NAMING_SCHEME")
    START_TIME=$(date +%s)
    TOTAL_PHASES=5
    CURRENT_PHASE=0
    
    progress 0 "Initializing flash backup" ""
    
    log "=========================================="
    log "Starting FLASH backup (Disaster Recovery)"
    log "=========================================="
    
    FLASH_PATH="/boot"
    
    if [ ! -d "$FLASH_PATH/config" ]; then
        log "ERROR: Flash drive not accessible"
        progress 100 "Error: Flash not accessible" ""
        rm -f "$PID_FILE"
        return 1
    fi
    
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/flash_config_${BACKUP_TAG}.tar.gz"
    TAR_FILE="$BACKUP_DIR/flash_config_${BACKUP_TAG}.tar"
    
    # Phase 1: Scan
    CURRENT_PHASE=1
    ETA=$(calc_eta $(($(date +%s) - START_TIME)) $CURRENT_PHASE $TOTAL_PHASES)
    progress $((CURRENT_PHASE * 100 / TOTAL_PHASES)) "Scanning flash drive" "$ETA"
    
    # Get key directories
    mapfile -t FLASH_DIRS < <(find "$FLASH_PATH" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null)
    TOTAL_ITEMS=${#FLASH_DIRS[@]}
    log "Found $TOTAL_ITEMS directories on flash"
    
    # Phase 2: Create archive
    CURRENT_PHASE=2
    rm -f "$BACKUP_FILE" "$TAR_FILE"
    
    ITEM_NUM=0
    for DIR in "${FLASH_DIRS[@]}"; do
        [ "$CANCELLED" = "1" ] && cleanup_on_cancel
        
        ITEM_NUM=$((ITEM_NUM + 1))
        SUB_PERCENT=$((20 + (ITEM_NUM * 50 / TOTAL_ITEMS)))
        ELAPSED=$(($(date +%s) - START_TIME))
        
        progress $SUB_PERCENT "$DIR ($ITEM_NUM/$TOTAL_ITEMS)" "elapsed:$(format_time $ELAPSED)"
        log "Archiving: $DIR"
        
        if [ $ITEM_NUM -eq 1 ]; then
            tar -cf "$TAR_FILE" --exclude='*.tmp' --exclude='logs/*' -C "$FLASH_PATH" "$DIR" 2>/dev/null
        else
            tar -rf "$TAR_FILE" --exclude='*.tmp' --exclude='logs/*' -C "$FLASH_PATH" "$DIR" 2>/dev/null
        fi
    done
    
    # Add root files
    tar -rf "$TAR_FILE" -C "$FLASH_PATH" --exclude='*/' . 2>/dev/null || true
    
    # Phase 3: Compress
    CURRENT_PHASE=3
    ETA=$(calc_eta $(($(date +%s) - START_TIME)) $CURRENT_PHASE $TOTAL_PHASES)
    progress $((CURRENT_PHASE * 100 / TOTAL_PHASES)) "Compressing archive" "$ETA"
    log "Compressing..."
    
    gzip -$COMPRESSION_LEVEL "$TAR_FILE"
    
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "Archive created: $BACKUP_SIZE"
    
    # Phase 4: Verify
    CURRENT_PHASE=4
    ETA=$(calc_eta $(($(date +%s) - START_TIME)) $CURRENT_PHASE $TOTAL_PHASES)
    progress $((CURRENT_PHASE * 100 / TOTAL_PHASES)) "Verifying ($BACKUP_SIZE)" "$ETA"
    verify_backup "$BACKUP_FILE"
    
    # Phase 5: Cleanup
    CURRENT_PHASE=5
    progress $((CURRENT_PHASE * 100 / TOTAL_PHASES)) "Cleaning up" ""
    cleanup_old_backups "flash_config_*.tar.gz" "$BACKUP_DIR"
    
    # Create restore instructions
    cat > "$BACKUP_DIR/RESTORE_INSTRUCTIONS.txt" << 'EOF'
FLASH BACKUP - RESTORE INSTRUCTIONS
====================================
1. Create new Unraid USB with USB Creator
2. Extract this backup to USB /boot directory
3. Transfer license at unraid.net if USB GUID changed
4. Boot and verify array configuration
EOF
    
    DURATION=$(($(date +%s) - START_TIME))
    progress 100 "Complete in $(format_time $DURATION)" ""
    log "Flash backup completed in $(format_time $DURATION)"
    rm -f "$PID_FILE"
}

# ============== RESTORE FUNCTIONS ==============
restore_vm() {
    local BACKUP_FILE="$1"
    local TARGET_VM_NAME="$2"
    
    log "Starting VM restore from: $BACKUP_FILE"
    [ ! -f "$BACKUP_FILE" ] && log "ERROR: File not found" && return 1
    
    METADATA_FILE="${BACKUP_FILE%.tar.gz}.metadata.json"
    [ -f "$METADATA_FILE" ] && VM_DISK_DIR=$(jq -r '.vm_disk_dir // "/mnt/user/domains"' "$METADATA_FILE")
    RESTORE_DIR=$(echo "${VM_DISK_DIR:-/mnt/user/domains}" | sed 's|/mnt/user/domains|/domains|')
    
    mkdir -p "$RESTORE_DIR"
    log "Extracting to: $RESTORE_DIR"
    
    [[ "$BACKUP_FILE" == *.tar.gz ]] && tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR" || tar -xf "$BACKUP_FILE" -C "$RESTORE_DIR"
    
    log "VM restore complete"
}

# Enhanced appdata restore with options
restore_appdata() {
    local BACKUP_SOURCE="$1"
    local FOLDER="${2:-}"
    local MODE="${3:-appdata_only}"
    
    log "Starting appdata restore"
    log "Source: $BACKUP_SOURCE"
    log "Folder: ${FOLDER:-all}"
    log "Mode: $MODE"
    
    # Handle metadata directory for image/container info
    local METADATA_DIR=""
    local CONTAINER_META=""
    
    # Find the most recent metadata
    for backup_dir in "$BACKUP_BASE"/backup_*/container_metadata; do
        [ ! -d "$backup_dir" ] && continue
        METADATA_DIR="$backup_dir"
        break
    done
    
    # If restoring specific folder with image pull or full restore
    if [ -n "$FOLDER" ] && [ "$MODE" != "appdata_only" ]; then
        local CONTAINER_META="$METADATA_DIR/${FOLDER}.json"
        
        if [ ! -f "$CONTAINER_META" ]; then
            # Try to match by container name
            for meta in "$METADATA_DIR"/*.json; do
                [ ! -f "$meta" ] && continue
                local appdata_folder=$(jq -r '.appdata_folder // empty' "$meta" 2>/dev/null)
                if [ "$appdata_folder" == "$FOLDER" ]; then
                    CONTAINER_META="$meta"
                    break
                fi
            done
        fi
        
        if [ -f "$CONTAINER_META" ]; then
            local IMAGE=$(jq -r '.image // empty' "$CONTAINER_META")
            local CONTAINER_NAME=$(jq -r '.container_name // empty' "$CONTAINER_META")
            local TEMPLATE=$(jq -r '.unraid_template // empty' "$CONTAINER_META")
            
            log "Found container metadata:"
            log "  Container: $CONTAINER_NAME"
            log "  Image: $IMAGE"
            log "  Template: $TEMPLATE"
            
            # Pull image if requested
            if [ "$MODE" == "pull_image" ] || [ "$MODE" == "full_restore" ]; then
                if [ -n "$IMAGE" ]; then
                    log "Pulling image: $IMAGE"
                    docker pull "$IMAGE" 2>&1 | while read line; do log "  $line"; done
                fi
            fi
            
            # Full restore - stop container, restore appdata, optionally recreate
            if [ "$MODE" == "full_restore" ]; then
                if docker ps -q -f name="^${CONTAINER_NAME}$" | grep -q .; then
                    log "Stopping container: $CONTAINER_NAME"
                    docker stop "$CONTAINER_NAME" 2>/dev/null
                fi
            fi
        else
            log "Warning: No container metadata found for $FOLDER"
        fi
    fi
    
    # Restore appdata files
    if [ -d "$BACKUP_SOURCE" ]; then
        if [ -n "$FOLDER" ]; then
            log "Restoring folder: $FOLDER from snapshot"
            cp -a "$BACKUP_SOURCE/$FOLDER" "$APPDATA_PATH/" 2>/dev/null
        else
            log "Restoring all folders from snapshot"
            cp -a "$BACKUP_SOURCE"/* "$APPDATA_PATH/" 2>/dev/null
        fi
    elif [ -f "$BACKUP_SOURCE" ]; then
        log "Extracting from archive to: $APPDATA_PATH"
        if [ -n "$FOLDER" ]; then
            tar -xzf "$BACKUP_SOURCE" -C "$APPDATA_PATH" "$FOLDER" 2>/dev/null
        else
            tar -xzf "$BACKUP_SOURCE" -C "$APPDATA_PATH"
        fi
    else
        log "ERROR: Backup source not found: $BACKUP_SOURCE"
        return 1
    fi
    
    log "Appdata restore complete"
}

# List available containers with their restore info
list_container_metadata() {
    local FOUND_METADATA=false
    
    echo '['
    local FIRST=true
    
    for backup_dir in "$BACKUP_BASE"/backup_*/container_metadata; do
        [ ! -d "$backup_dir" ] && continue
        FOUND_METADATA=true
        
        for meta in "$backup_dir"/*.json; do
            [ ! -f "$meta" ] && continue
            [ "$(basename "$meta")" == "container_mapping.json" ] && continue
            
            [ "$FIRST" != "true" ] && echo ','
            FIRST=false
            
            local name=$(jq -r '.container_name // empty' "$meta")
            local image=$(jq -r '.image // empty' "$meta")
            local folder=$(jq -r '.appdata_folder // empty' "$meta")
            local template=$(jq -r '.unraid_template // empty' "$meta")
            local state=$(jq -r '.state // empty' "$meta")
            
            cat << EOF
{
    "container_name": "$name",
    "image": "$image",
    "appdata_folder": "$folder",
    "template": "$template",
    "state": "$state"
}
EOF
        done
    done
    echo ']'
}

restore_plugins() {
    local BACKUP_FILE="$1"
    log "Starting plugins restore from: $BACKUP_FILE"
    [ ! -f "$BACKUP_FILE" ] && log "ERROR: File not found" && return 1
    
    log "Extracting to: /boot/config"
    tar -xzf "$BACKUP_FILE" -C "/boot/config"
    log "Plugins restore complete"
}

# ============== MAIN ==============
case "$1" in
    backup_vm) backup_vm "$2" "$3" "$4" "$5" ;;
    backup_appdata) backup_appdata "$2" "${@:3}" ;;
    backup_plugins) backup_plugins "$2" ;;
    backup_flash) backup_flash "$2" ;;
    restore_vm) restore_vm "$2" "$3" ;;
    restore_appdata) restore_appdata "$2" "$3" "$4" ;;
    restore_plugins) restore_plugins "$2" ;;
    list_container_metadata) list_container_metadata ;;
    *) echo "Usage: $0 {backup_vm|backup_appdata|backup_plugins|backup_flash|restore_vm|restore_appdata|restore_plugins|list_container_metadata}" ;;
esac
