#!/bin/bash

# Backup Unraid State - Docker Edition v2.2
# With folder-level progress, container metadata, and restore support

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
INCREMENTAL_FILE="/config/last_backup_time"

EXCLUDE_PATTERNS=(
    "*/cache/*" "*/Cache/*" "*/logs/*" "*/Logs/*" "*/.cache/*"
    "*/temp/*" "*/tmp/*" "*.log" "*.tmp" "*Transcode*" "*transcodes*"
)

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
            if grep -q "<Name>$CONTAINER</Name>" "$tmpl" 2>/dev/null || \
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

get_backup_tag() {
    local naming_scheme="${1:-weekly}"
    case "$naming_scheme" in
        daily) echo "day$(date +%u)_week$(printf '%02d' $(date +%V))" ;;
        weekly) echo "week$(printf '%02d' $(date +%V))" ;;
        monthly) echo "$(date +%B_%Y)" ;;
        *) echo "week$(printf '%02d' $(date +%V))" ;;
    esac
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

# ============== VM BACKUP ==============
backup_vm() {
    local VM_NAME="$1"
    local VM_HANDLING="$2"
    local COMPRESS="$3"
    local NAMING_SCHEME="${4:-weekly}"
    
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    START_TIME=$(date +%s)
    
    # VM backup uses elapsed time (not ETA) because it's one big file
    progress 0 "Initializing VM backup" "elapsed:0s"
    
    log "=========================================="
    log "Starting VM backup: $VM_NAME"
    log "=========================================="
    
    mkdir -p "$BACKUP_BASE/vms"
    
    [ "$COMPRESS" == "1" ] && BACKUP_FILE="$BACKUP_BASE/vms/${VM_NAME}_${BACKUP_TAG}.tar.gz" || BACKUP_FILE="$BACKUP_BASE/vms/${VM_NAME}_${BACKUP_TAG}.tar"
    
    # Check VM
    ELAPSED=$(($(date +%s) - START_TIME))
    progress 5 "Checking VM status" "elapsed:$(format_time $ELAPSED)"
    
    if ! virsh dominfo "$VM_NAME" &>/dev/null; then
        log "ERROR: VM '$VM_NAME' not found"
        progress 100 "Error: VM not found" ""
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
            sleep 1
            VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
            [ "$VM_STATE" == "shut off" ] && break
            ELAPSED=$(($(date +%s) - START_TIME))
            progress 15 "Waiting for shutdown ($i/60)" "elapsed:$(format_time $ELAPSED)"
        done
        
        [ "$VM_STATE" != "shut off" ] && virsh destroy "$VM_NAME" && sleep 2
        log "VM stopped"
    fi
    
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
    cleanup_old_backups "${VM_NAME}_*.tar*" "$BACKUP_BASE/vms"
    
    DURATION=$(($(date +%s) - START_TIME))
    progress 100 "Complete in $(format_time $DURATION)" ""
    log "VM backup completed in $(format_time $DURATION)"
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
    EXCLUDE_ARGS=$(build_exclude_args)
    START_TIME=$(date +%s)
    
    progress 0 "Initializing appdata backup" ""
    
    log "=========================================="
    log "Starting appdata backup"
    log "Mode: $([ "$INCREMENTAL" == "1" ] && echo "Incremental (rsync+hardlinks)" || echo "Full (tar archive)")"
    log "=========================================="
    
    mkdir -p "$BACKUP_BASE/appdata"
    
    if [ "$BACKUP_TYPE" == "all" ]; then
        # Get all folders
        mapfile -t ALL_FOLDERS < <(find "$APPDATA_PATH" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
        TOTAL_FOLDERS=${#ALL_FOLDERS[@]}
        
        progress 2 "Found $TOTAL_FOLDERS folders" ""
        log "Found $TOTAL_FOLDERS folders to backup"
        
        if [ "$INCREMENTAL" == "1" ]; then
            # ============== RSYNC + HARDLINKS MODE ==============
            # Each backup is a complete folder, unchanged files hardlinked to previous
            
            BACKUP_DIR="$BACKUP_BASE/appdata/snapshots"
            mkdir -p "$BACKUP_DIR"
            
            # Current backup folder with timestamp
            CURRENT_BACKUP="$BACKUP_DIR/$(date +%Y-%m-%d_%H%M)"
            
            # Find most recent previous backup for hardlinking
            PREVIOUS_BACKUP=$(ls -1d "$BACKUP_DIR"/20* 2>/dev/null | sort -r | head -1)
            
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
            mkdir -p "$CURRENT_BACKUP"
            
            for FOLDER in "${ALL_FOLDERS[@]}"; do
                CURRENT=$((CURRENT + 1))
                PERCENT=$((5 + (CURRENT * 90 / TOTAL_FOLDERS)))
                ELAPSED=$(($(date +%s) - START_TIME))
                
                progress $PERCENT "$FOLDER ($CURRENT/$TOTAL_FOLDERS)" "elapsed:$(format_time $ELAPSED)"
                log "[$CURRENT/$TOTAL_FOLDERS] Syncing: $FOLDER"
                
                eval rsync -a $LINK_DEST $RSYNC_EXCLUDES "$APPDATA_PATH/$FOLDER" "$CURRENT_BACKUP/" 2>/dev/null
            done
            
            # Save metadata
            cat > "$CURRENT_BACKUP/.metadata.json" << EOF
{"backup_type":"appdata_incremental","mode":"rsync_hardlinks","folders":$TOTAL_FOLDERS,"backup_date":"$(date -Iseconds)","previous":"$(basename "$PREVIOUS_BACKUP" 2>/dev/null)"}
EOF
            
            # Calculate actual disk usage (shows hardlink savings)
            BACKUP_SIZE=$(du -sh "$CURRENT_BACKUP" | cut -f1)
            ACTUAL_SIZE=$(du -sh --apparent-size "$CURRENT_BACKUP" | cut -f1)
            log "Backup size: $BACKUP_SIZE (apparent: $ACTUAL_SIZE)"
            
            # Cleanup old snapshots
            progress 98 "Cleaning up old snapshots" ""
            ls -1d "$BACKUP_DIR"/20* 2>/dev/null | sort -r | tail -n +$((MAX_BACKUPS + 1)) | while read old; do
                log "Removing old snapshot: $(basename "$old")"
                rm -rf "$old"
            done
            
        else
            # ============== FULL TAR ARCHIVE MODE ==============
            BACKUP_FILE="$BACKUP_BASE/appdata/appdata_FULL_${BACKUP_TAG}.tar.gz"
            METADATA_FILE="${BACKUP_FILE%.tar.gz}.metadata.json"
            
            echo "{\"backup_type\":\"appdata_full\",\"folders\":$TOTAL_FOLDERS,\"backup_date\":\"$(date -Iseconds)\",\"backup_tag\":\"$BACKUP_TAG\"}" > "$METADATA_FILE"
            
            rm -f "$BACKUP_FILE" "$BACKUP_FILE.tmp"
            
            CURRENT=0
            for FOLDER in "${ALL_FOLDERS[@]}"; do
                CURRENT=$((CURRENT + 1))
                PERCENT=$((5 + (CURRENT * 85 / TOTAL_FOLDERS)))
                ELAPSED=$(($(date +%s) - START_TIME))
                
                progress $PERCENT "$FOLDER ($CURRENT/$TOTAL_FOLDERS)" "elapsed:$(format_time $ELAPSED)"
                log "[$CURRENT/$TOTAL_FOLDERS] Backing up: $FOLDER"
                
                if [ $CURRENT -eq 1 ]; then
                    eval tar -cf "$BACKUP_FILE.tmp" $EXCLUDE_ARGS -C "$APPDATA_PATH" "$FOLDER" 2>/dev/null
                else
                    eval tar -rf "$BACKUP_FILE.tmp" $EXCLUDE_ARGS -C "$APPDATA_PATH" "$FOLDER" 2>/dev/null
                fi
            done
            
            progress 92 "Compressing archive" ""
            log "Compressing archive..."
            gzip -$COMPRESSION_LEVEL "$BACKUP_FILE.tmp"
            mv "$BACKUP_FILE.tmp.gz" "$BACKUP_FILE"
            
            BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
            log "Archive created: $BACKUP_SIZE"
            
            progress 95 "Verifying ($BACKUP_SIZE)" ""
            verify_backup "$BACKUP_FILE"
            
            progress 98 "Cleaning up" ""
            cleanup_old_backups "appdata_FULL_*.tar.gz" "$BACKUP_BASE/appdata"
        fi
        
    else
        # Custom folder backup (always tar)
        TOTAL_FOLDERS=${#CUSTOM_FOLDERS[@]}
        CURRENT=0
        
        for FOLDER in "${CUSTOM_FOLDERS[@]}"; do
            CURRENT=$((CURRENT + 1))
            PERCENT=$((CURRENT * 95 / TOTAL_FOLDERS))
            ELAPSED=$(($(date +%s) - START_TIME))
            
            progress $PERCENT "$FOLDER ($CURRENT/$TOTAL_FOLDERS)" "elapsed:$(format_time $ELAPSED)"
            log "[$CURRENT/$TOTAL_FOLDERS] Backing up: $FOLDER"
            
            BACKUP_FILE="$BACKUP_BASE/appdata/containers/${FOLDER}/${FOLDER}_${BACKUP_TAG}.tar.gz"
            mkdir -p "$(dirname "$BACKUP_FILE")"
            
            [ -d "$APPDATA_PATH/$FOLDER" ] && eval tar -czf "$BACKUP_FILE" $EXCLUDE_ARGS -C "$APPDATA_PATH" "$FOLDER" 2>/dev/null
            
            cleanup_old_backups "${FOLDER}_*.tar.gz" "$BACKUP_BASE/appdata/containers/${FOLDER}"
        done
    fi
    
    # Collect container metadata for restore support
    ELAPSED=$(($(date +%s) - START_TIME))
    progress 99 "Collecting container metadata" "elapsed:$(format_time $ELAPSED)"
    collect_container_metadata "$BACKUP_BASE/appdata/container_metadata"
    
    DURATION=$(($(date +%s) - START_TIME))
    progress 100 "Complete in $(format_time $DURATION)" ""
    log "Appdata backup completed in $(format_time $DURATION)"
}

# ============== PLUGINS BACKUP ==============
backup_plugins() {
    local NAMING_SCHEME="${1:-weekly}"
    
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    START_TIME=$(date +%s)
    
    progress 0 "Initializing plugins backup" ""
    
    log "=========================================="
    log "Starting plugins backup"
    log "=========================================="
    
    mkdir -p "$BACKUP_BASE/plugins"
    BACKUP_FILE="$BACKUP_BASE/plugins/plugins_${BACKUP_TAG}.tar.gz"
    
    # Get plugin folders
    mapfile -t PLUGIN_FOLDERS < <(find "$PLUGINS_PATH" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
    TOTAL=${#PLUGIN_FOLDERS[@]}
    
    progress 5 "Found $TOTAL plugin configs" ""
    log "Found $TOTAL plugin configurations"
    
    # Remove old file
    rm -f "$BACKUP_FILE" "$BACKUP_FILE.tmp"
    
    # Backup each plugin folder
    CURRENT=0
    for PLUGIN in "${PLUGIN_FOLDERS[@]}"; do
        CURRENT=$((CURRENT + 1))
        PERCENT=$((5 + (CURRENT * 80 / TOTAL)))
        ELAPSED=$(($(date +%s) - START_TIME))
        
        progress $PERCENT "$PLUGIN ($CURRENT/$TOTAL)" "elapsed:$(format_time $ELAPSED)"
        log "[$CURRENT/$TOTAL] Backing up: $PLUGIN"
        
        if [ $CURRENT -eq 1 ]; then
            tar -cf "$BACKUP_FILE.tmp" -C "$PLUGINS_PATH" "$PLUGIN" 2>/dev/null
        else
            tar -rf "$BACKUP_FILE.tmp" -C "$PLUGINS_PATH" "$PLUGIN" 2>/dev/null
        fi
    done
    
    # Also get loose files in plugins directory
    tar -rf "$BACKUP_FILE.tmp" -C "$PLUGINS_PATH" --exclude='*/' . 2>/dev/null || true
    
    # Compress
    progress 90 "Compressing archive" ""
    gzip -$COMPRESSION_LEVEL "$BACKUP_FILE.tmp"
    mv "$BACKUP_FILE.tmp.gz" "$BACKUP_FILE"
    
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "Archive created: $BACKUP_SIZE"
    
    progress 95 "Verifying ($BACKUP_SIZE)" ""
    verify_backup "$BACKUP_FILE"
    
    progress 98 "Cleaning up" ""
    cleanup_old_backups "plugins_*.tar.gz" "$BACKUP_BASE/plugins"
    
    DURATION=$(($(date +%s) - START_TIME))
    progress 100 "Complete in $(format_time $DURATION)" ""
    log "Plugins backup completed in $(format_time $DURATION)"
}

# ============== FLASH BACKUP ==============
backup_flash() {
    local NAMING_SCHEME="${1:-weekly}"
    
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
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
        return 1
    fi
    
    mkdir -p "$BACKUP_BASE/flash"
    BACKUP_FILE="$BACKUP_BASE/flash/flash_config_${BACKUP_TAG}.tar.gz"
    
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
    rm -f "$BACKUP_FILE" "$BACKUP_FILE.tmp"
    
    ITEM_NUM=0
    for DIR in "${FLASH_DIRS[@]}"; do
        ITEM_NUM=$((ITEM_NUM + 1))
        SUB_PERCENT=$((20 + (ITEM_NUM * 50 / TOTAL_ITEMS)))
        ELAPSED=$(($(date +%s) - START_TIME))
        
        progress $SUB_PERCENT "$DIR ($ITEM_NUM/$TOTAL_ITEMS)" "elapsed:$(format_time $ELAPSED)"
        log "Archiving: $DIR"
        
        if [ $ITEM_NUM -eq 1 ]; then
            tar -cf "$BACKUP_FILE.tmp" --exclude='*.tmp' --exclude='logs/*' -C "$FLASH_PATH" "$DIR" 2>/dev/null
        else
            tar -rf "$BACKUP_FILE.tmp" --exclude='*.tmp' --exclude='logs/*' -C "$FLASH_PATH" "$DIR" 2>/dev/null
        fi
    done
    
    # Add root files
    tar -rf "$BACKUP_FILE.tmp" -C "$FLASH_PATH" --exclude='*/' . 2>/dev/null || true
    
    # Phase 3: Compress
    CURRENT_PHASE=3
    ETA=$(calc_eta $(($(date +%s) - START_TIME)) $CURRENT_PHASE $TOTAL_PHASES)
    progress $((CURRENT_PHASE * 100 / TOTAL_PHASES)) "Compressing archive" "$ETA"
    log "Compressing..."
    
    gzip -$COMPRESSION_LEVEL "$BACKUP_FILE.tmp"
    mv "$BACKUP_FILE.tmp.gz" "$BACKUP_FILE"
    
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
    cleanup_old_backups "flash_config_*.tar.gz" "$BACKUP_BASE/flash"
    
    # Create restore instructions
    cat > "$BACKUP_BASE/flash/RESTORE_INSTRUCTIONS.txt" << 'EOF'
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
# Usage: restore_appdata <backup_file_or_dir> <folder> <mode>
# Modes: appdata_only, pull_image, full_restore
restore_appdata() {
    local BACKUP_SOURCE="$1"
    local FOLDER="${2:-}"
    local MODE="${3:-appdata_only}"
    
    log "Starting appdata restore"
    log "Source: $BACKUP_SOURCE"
    log "Folder: ${FOLDER:-all}"
    log "Mode: $MODE"
    
    # Handle metadata directory for image/container info
    local METADATA_DIR="$BACKUP_BASE/appdata/container_metadata"
    
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
                # Stop container if running
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
        # It's a snapshot directory (incremental backup)
        if [ -n "$FOLDER" ]; then
            log "Restoring folder: $FOLDER from snapshot"
            cp -a "$BACKUP_SOURCE/$FOLDER" "$APPDATA_PATH/" 2>/dev/null
        else
            log "Restoring all folders from snapshot"
            cp -a "$BACKUP_SOURCE"/* "$APPDATA_PATH/" 2>/dev/null
        fi
    elif [ -f "$BACKUP_SOURCE" ]; then
        # It's a tar archive
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
    local METADATA_DIR="$BACKUP_BASE/appdata/container_metadata"
    
    if [ ! -d "$METADATA_DIR" ]; then
        echo "[]"
        return
    fi
    
    echo '['
    local FIRST=true
    for meta in "$METADATA_DIR"/*.json; do
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
