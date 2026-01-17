#!/bin/bash

# Backup Unraid State - Docker Edition
# Backup script for VMs, appdata, and plugins

# Environment variables (set by Docker or Python)
BACKUP_BASE="${BACKUP_BASE:-/backup}"
VM_PATH="${VM_PATH:-/domains}"
APPDATA_PATH="${APPDATA_PATH:-/appdata}"
PLUGINS_PATH="${PLUGINS_PATH:-/plugins}"
LOG_FILE="${LOG_FILE:-/config/backup.log}"
MAX_BACKUPS="${MAX_BACKUPS:-2}"

# Exclusion patterns for appdata
EXCLUDE_PATTERNS=(
    "*/cache/*"
    "*/Cache/*"
    "*/logs/*"
    "*/Logs/*"
    "*/.cache/*"
    "*/temp/*"
    "*/tmp/*"
    "*.log"
    "*.tmp"
    "*Transcode*"
    "*transcodes*"
)

# Get naming based on schedule
get_backup_tag() {
    local naming_scheme="${1:-weekly}"
    local tag=""
    
    case "$naming_scheme" in
        daily)
            local day_num=$(date +%u)
            local week_num=$(date +%V)
            tag="day${day_num}_week$(printf '%02d' $week_num)"
            ;;
        weekly)
            local week_num=$(date +%V)
            tag="week$(printf '%02d' $week_num)"
            ;;
        monthly)
            tag="$(date +%B_%Y)"
            ;;
        *)
            local week_num=$(date +%V)
            tag="week$(printf '%02d' $week_num)"
            ;;
    esac
    
    echo "$tag"
}

# Logging function
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Build exclude arguments for tar
build_exclude_args() {
    local args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        args="$args --exclude=$pattern"
    done
    echo "$args"
}

# Cleanup old backups - keep only MAX_BACKUPS newest
cleanup_old_backups() {
    local pattern="$1"
    local backup_dir="$2"
    
    log "Cleaning up old backups matching: $pattern in $backup_dir"
    
    if [ ! -d "$backup_dir" ]; then
        return
    fi
    
    cd "$backup_dir" || return
    
    # List files matching pattern, sorted by time (newest first), skip first MAX_BACKUPS
    ls -t $pattern 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | while read file; do
        log "Deleting old backup: $file"
        rm -f "$file"
        # Also remove metadata file if exists
        rm -f "${file%.tar.gz}.metadata.json" 2>/dev/null
        rm -f "${file%.tar}.metadata.json" 2>/dev/null
    done
}

# VM Backup Function
backup_vm() {
    local VM_NAME="$1"
    local VM_HANDLING="$2"
    local COMPRESS="$3"
    local NAMING_SCHEME="${4:-weekly}"
    
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    
    log "=========================================="
    log "Starting VM backup: $VM_NAME"
    log "Naming: $BACKUP_TAG (scheme: $NAMING_SCHEME)"
    log "Handling: $VM_HANDLING"
    log "Compress: $COMPRESS"
    log "=========================================="
    
    mkdir -p "$BACKUP_BASE/vms"
    
    if [ "$COMPRESS" == "1" ]; then
        BACKUP_FILE="$BACKUP_BASE/vms/${VM_NAME}_${BACKUP_TAG}.tar.gz"
    else
        BACKUP_FILE="$BACKUP_BASE/vms/${VM_NAME}_${BACKUP_TAG}.tar"
    fi
    
    METADATA_FILE="${BACKUP_FILE%.tar.gz}.metadata.json"
    [ "$COMPRESS" == "0" ] && METADATA_FILE="${BACKUP_FILE%.tar}.metadata.json"
    
    # Check if VM exists
    if ! virsh dominfo "$VM_NAME" &>/dev/null; then
        log "ERROR: VM '$VM_NAME' not found"
        return 1
    fi
    
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
    log "VM current state: $VM_STATE"
    
    # Get VM disk path (this returns the HOST path from libvirt)
    VM_DISK_HOST=$(virsh domblklist "$VM_NAME" | grep -E 'vd|hd|sd' | awk '{print $2}' | head -1)
    if [ -z "$VM_DISK_HOST" ]; then
        log "ERROR: Could not find VM disk"
        return 1
    fi
    
    log "VM disk (host path): $VM_DISK_HOST"
    
    # Translate host path to container path
    # /mnt/user/domains -> /domains (as mounted in docker-compose)
    VM_DISK=$(echo "$VM_DISK_HOST" | sed 's|/mnt/user/domains|/domains|')
    
    log "VM disk (container path): $VM_DISK"
    
    # Verify the path exists inside the container
    if [ ! -f "$VM_DISK" ]; then
        log "ERROR: VM disk not accessible at container path: $VM_DISK"
        log "Make sure /mnt/user/domains is mounted to /domains in docker-compose.yml"
        return 1
    fi
    
    # Get VM XML config
    VM_XML=$(virsh dumpxml "$VM_NAME" 2>/dev/null)
    if [ -z "$VM_XML" ]; then
        log "ERROR: Could not get VM configuration"
        return 1
    fi
    
    # Save metadata (use HOST path for restore purposes)
    cat > "$METADATA_FILE" << METADATA_EOF
{
    "backup_type": "vm",
    "vm_name": "$VM_NAME",
    "vm_disk_path": "$VM_DISK_HOST",
    "vm_disk_dir": "$(dirname "$VM_DISK_HOST")",
    "vm_disk_name": "$(basename "$VM_DISK_HOST")",
    "backup_date": "$(date -Iseconds)",
    "backup_tag": "$BACKUP_TAG",
    "naming_scheme": "$NAMING_SCHEME",
    "compressed": $COMPRESS,
    "original_state": "$VM_STATE",
    "vm_xml_config": $(echo "$VM_XML" | jq -Rs .)
}
METADATA_EOF
    
    log "Metadata saved to: $METADATA_FILE"
    
    # Handle VM state
    NEED_RESTART=false
    if [ "$VM_HANDLING" == "stop" ]; then
        if [ "$VM_STATE" == "running" ]; then
            log "Shutting down VM..."
            virsh shutdown "$VM_NAME"
            NEED_RESTART=true
            
            # Wait for shutdown
            for i in {1..60}; do
                sleep 1
                VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
                if [ "$VM_STATE" == "shut off" ]; then
                    log "VM shut down successfully"
                    break
                fi
            done
            
            # Force if needed
            if [ "$VM_STATE" != "shut off" ]; then
                log "VM did not shut down gracefully, forcing off..."
                virsh destroy "$VM_NAME"
                sleep 2
            fi
        fi
    fi
    
    # Create backup
    log "Creating backup..."
    START_TIME=$(date +%s)
    
    if [ "$COMPRESS" == "1" ]; then
        tar -czf "$BACKUP_FILE" -C "$(dirname "$VM_DISK")" "$(basename "$VM_DISK")" 2>&1 | while read line; do
            log "$line"
        done
    else
        tar -cf "$BACKUP_FILE" -C "$(dirname "$VM_DISK")" "$(basename "$VM_DISK")" 2>&1 | while read line; do
            log "$line"
        done
    fi
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    
    log "Backup completed: $BACKUP_FILE"
    log "Size: $BACKUP_SIZE"
    log "Duration: ${DURATION} seconds"
    
    # Restart VM if needed
    if [ "$NEED_RESTART" == "true" ]; then
        log "Restarting VM..."
        virsh start "$VM_NAME"
        log "VM restarted"
    fi
    
    # Cleanup old backups
    cleanup_old_backups "${VM_NAME}_*.tar*" "$BACKUP_BASE/vms"
    
    log "VM backup finished successfully"
}

# Appdata Backup Function  
backup_appdata() {
    local BACKUP_TYPE="$1"
    shift
    
    local NAMING_SCHEME="weekly"
    local FOLDERS=()
    
    # Parse arguments
    for arg in "$@"; do
        if [[ "$arg" == "daily" || "$arg" == "weekly" || "$arg" == "monthly" ]]; then
            NAMING_SCHEME="$arg"
        else
            FOLDERS+=("$arg")
        fi
    done
    
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    EXCLUDE_ARGS=$(build_exclude_args)
    
    log "=========================================="
    log "Starting appdata backup"
    log "Naming: $BACKUP_TAG (scheme: $NAMING_SCHEME)"
    log "Type: $BACKUP_TYPE"
    log "=========================================="
    
    mkdir -p "$BACKUP_BASE/appdata"
    
    if [ "$BACKUP_TYPE" == "all" ]; then
        # FULL BACKUP - Single combined archive
        BACKUP_FILE="$BACKUP_BASE/appdata/appdata_FULL_${BACKUP_TAG}.tar.gz"
        METADATA_FILE="${BACKUP_FILE%.tar.gz}.metadata.json"
        
        # Get list of all folders
        ALL_FOLDERS=$(find "$APPDATA_PATH" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | jq -R . | jq -s .)
        
        cat > "$METADATA_FILE" << METADATA_EOF
{
    "backup_type": "appdata_full",
    "backup_mode": "all",
    "appdata_path": "$APPDATA_PATH",
    "folders": $ALL_FOLDERS,
    "backup_date": "$(date -Iseconds)",
    "backup_tag": "$BACKUP_TAG",
    "naming_scheme": "$NAMING_SCHEME",
    "compressed": true
}
METADATA_EOF
        
        log "Metadata saved to: $METADATA_FILE"
        log "Creating FULL appdata backup..."
        
        START_TIME=$(date +%s)
        
        eval tar -czf "$BACKUP_FILE" $EXCLUDE_ARGS -C "$APPDATA_PATH" . 2>&1 | while read line; do
            log "$line"
        done
        
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        
        log "FULL backup completed: $BACKUP_FILE"
        log "Size: $BACKUP_SIZE"
        log "Duration: ${DURATION} seconds"
        
        # Cleanup
        cleanup_old_backups "appdata_FULL_*.tar.gz" "$BACKUP_BASE/appdata"
        
    else
        # INDIVIDUAL BACKUPS
        log "Creating INDIVIDUAL backups for ${#FOLDERS[@]} folders..."
        
        for FOLDER in "${FOLDERS[@]}"; do
            log "Backing up: $FOLDER"
            
            BACKUP_FILE="$BACKUP_BASE/appdata/containers/${FOLDER}/${FOLDER}_${BACKUP_TAG}.tar.gz"
            METADATA_FILE="${BACKUP_FILE%.tar.gz}.metadata.json"
            mkdir -p "$(dirname "$BACKUP_FILE")"
            
            if [ ! -d "$APPDATA_PATH/$FOLDER" ]; then
                log "WARNING: Folder not found: $FOLDER (skipping)"
                continue
            fi
            
            cat > "$METADATA_FILE" << METADATA_EOF
{
    "backup_type": "appdata_individual",
    "backup_mode": "custom",
    "appdata_path": "$APPDATA_PATH",
    "folder": "$FOLDER",
    "backup_date": "$(date -Iseconds)",
    "backup_tag": "$BACKUP_TAG",
    "naming_scheme": "$NAMING_SCHEME",
    "compressed": true
}
METADATA_EOF
            
            START_TIME=$(date +%s)
            
            eval tar -czf "$BACKUP_FILE" $EXCLUDE_ARGS -C "$APPDATA_PATH" "$FOLDER" 2>&1 | while read line; do
                log "$line"
            done
            
            END_TIME=$(date +%s)
            DURATION=$((END_TIME - START_TIME))
            BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
            
            log "✓ Completed: $FOLDER ($BACKUP_SIZE, ${DURATION}s)"
            
            cleanup_old_backups "${FOLDER}_*.tar.gz" "$BACKUP_BASE/appdata/containers/${FOLDER}"
        done
        
        log "All individual backups completed"
    fi
    
    log "Appdata backup finished successfully"
}

# Plugins Backup Function
backup_plugins() {
    local NAMING_SCHEME="${1:-weekly}"
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    
    log "=========================================="
    log "Starting plugins backup"
    log "Naming: $BACKUP_TAG (scheme: $NAMING_SCHEME)"
    log "=========================================="
    
    mkdir -p "$BACKUP_BASE/plugins"
    
    BACKUP_FILE="$BACKUP_BASE/plugins/plugins_${BACKUP_TAG}.tar.gz"
    
    if [ ! -d "$PLUGINS_PATH" ]; then
        log "ERROR: Plugins path not found: $PLUGINS_PATH"
        return 1
    fi
    
    log "Backing up plugin configs from $PLUGINS_PATH"
    
    START_TIME=$(date +%s)
    
    tar -czf "$BACKUP_FILE" -C "$(dirname "$PLUGINS_PATH")" "$(basename "$PLUGINS_PATH")" 2>&1 | while read line; do
        log "$line"
    done
    
    if [ $? -eq 0 ]; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        
        log "Plugin backup completed: $BACKUP_FILE"
        log "Size: $BACKUP_SIZE"
        log "Duration: ${DURATION} seconds"
        
        # Cleanup
        cleanup_old_backups "plugins_*.tar.gz" "$BACKUP_BASE/plugins"
    else
        log "ERROR: Plugin backup failed"
        return 1
    fi
    
    log "Plugin backup finished successfully"
}

# Flash/USB Backup Function - CRITICAL for disaster recovery
backup_flash() {
    local NAMING_SCHEME="${1:-weekly}"
    BACKUP_TAG=$(get_backup_tag "$NAMING_SCHEME")
    
    log "=========================================="
    log "Starting FLASH DRIVE backup (Disaster Recovery)"
    log "Naming: $BACKUP_TAG (scheme: $NAMING_SCHEME)"
    log "=========================================="
    
    mkdir -p "$BACKUP_BASE/flash"
    
    BACKUP_FILE="$BACKUP_BASE/flash/flash_config_${BACKUP_TAG}.tar.gz"
    METADATA_FILE="${BACKUP_FILE%.tar.gz}.metadata.json"
    
    FLASH_PATH="${FLASH_PATH:-/boot}"
    
    if [ ! -d "$FLASH_PATH/config" ]; then
        log "ERROR: Flash config path not found: $FLASH_PATH/config"
        return 1
    fi
    
    # Catalog what we're backing up
    log "Cataloging flash contents..."
    
    # Check for important files
    local has_super="false"
    local has_license="false"
    local has_network="false"
    local has_shares="false"
    local has_docker="false"
    local has_vms="false"
    local has_users="false"
    local has_ssl="false"
    local has_wireguard="false"
    
    [ -f "$FLASH_PATH/config/super.dat" ] && has_super="true"
    [ -f "$FLASH_PATH/*.key" ] 2>/dev/null && has_license="true"
    ls "$FLASH_PATH/"*.key &>/dev/null && has_license="true"
    [ -f "$FLASH_PATH/config/network.cfg" ] && has_network="true"
    [ -d "$FLASH_PATH/config/shares" ] && has_shares="true"
    [ -f "$FLASH_PATH/config/docker.cfg" ] && has_docker="true"
    [ -d "$FLASH_PATH/config/libvirt" ] && has_vms="true"
    [ -f "$FLASH_PATH/config/passwd" ] && has_users="true"
    [ -d "$FLASH_PATH/config/ssl" ] && has_ssl="true"
    [ -d "$FLASH_PATH/config/wireguard" ] && has_wireguard="true"
    
    # Create metadata
    cat > "$METADATA_FILE" << METADATA_EOF
{
    "backup_type": "flash",
    "flash_path": "$FLASH_PATH",
    "backup_date": "$(date -Iseconds)",
    "backup_tag": "$BACKUP_TAG",
    "naming_scheme": "$NAMING_SCHEME",
    "compressed": true,
    "contents": {
        "array_config": $has_super,
        "license_key": $has_license,
        "network_config": $has_network,
        "share_config": $has_shares,
        "docker_config": $has_docker,
        "vm_config": $has_vms,
        "user_accounts": $has_users,
        "ssl_certs": $has_ssl,
        "wireguard_vpn": $has_wireguard
    },
    "restore_notes": "To restore: Copy contents to new USB flash drive /boot/ directory. License may need reactivation if USB GUID changes."
}
METADATA_EOF
    
    log "Metadata saved to: $METADATA_FILE"
    log ""
    log "Backup will include:"
    [ "$has_super" == "true" ] && log "  ✓ Array configuration (super.dat)"
    [ "$has_license" == "true" ] && log "  ✓ License key"
    [ "$has_network" == "true" ] && log "  ✓ Network configuration"
    [ "$has_shares" == "true" ] && log "  ✓ Share definitions"
    [ "$has_docker" == "true" ] && log "  ✓ Docker settings"
    [ "$has_vms" == "true" ] && log "  ✓ VM/Libvirt configuration"
    [ "$has_users" == "true" ] && log "  ✓ User accounts"
    [ "$has_ssl" == "true" ] && log "  ✓ SSL certificates"
    [ "$has_wireguard" == "true" ] && log "  ✓ WireGuard VPN config"
    log ""
    
    log "Creating flash backup..."
    START_TIME=$(date +%s)
    
    # Backup the entire /boot except for large unnecessary files
    # We INCLUDE plugins folder here since it has configs, but exclude the actual plugin packages
    tar -czf "$BACKUP_FILE" \
        --exclude="*.txz" \
        --exclude="*.zip" \
        --exclude="previous/" \
        --exclude="bz*" \
        --exclude="logs/" \
        -C "$(dirname "$FLASH_PATH")" "$(basename "$FLASH_PATH")" 2>&1 | while read line; do
        log "$line"
    done
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    
    log ""
    log "Flash backup completed: $BACKUP_FILE"
    log "Size: $BACKUP_SIZE"
    log "Duration: ${DURATION} seconds"
    
    # Create README with restore instructions
    README_FILE="$BACKUP_BASE/flash/RESTORE_INSTRUCTIONS.txt"
    cat > "$README_FILE" << 'README_EOF'
==========================================
FLASH BACKUP - RESTORE INSTRUCTIONS
==========================================

This backup contains your complete Unraid USB flash drive configuration.

WHAT'S INCLUDED:
- Array configuration (disk assignments, parity)
- Network settings
- User accounts & passwords
- Share definitions
- Docker & VM settings
- SSL certificates
- Plugin configurations
- License key

HOW TO RESTORE:
==========================================

1. CREATE NEW UNRAID USB
   - Download Unraid USB Creator from unraid.net
   - Create a fresh Unraid USB drive
   - Boot once to initialize (optional)

2. EXTRACT THIS BACKUP
   - Mount the USB drive on a computer
   - Extract the .tar.gz backup file
   - Copy contents to the USB /boot directory
   - Overwrite existing files when prompted

3. REACTIVATE LICENSE (if needed)
   - If the new USB has a different GUID than original
   - Go to unraid.net -> My Servers
   - Transfer your license to the new USB GUID

4. BOOT AND VERIFY
   - Insert USB into server and boot
   - Array configuration should be intact
   - Start array and verify all disks are recognized

IMPORTANT NOTES:
==========================================
- This backup does NOT include your actual data (array contents)
- This backup does NOT include Docker container data (appdata)
- This backup does NOT include VM disk images
- Those should be backed up separately

For full disaster recovery, you need:
1. This flash backup (USB configuration)
2. Appdata backup (Docker container data)  
3. VM backups (if applicable)
4. Your actual array data (parity protected or separate backup)

==========================================
Backup created by: Backup Unraid State
==========================================
README_EOF
    
    log "Created restore instructions: $README_FILE"
    
    # Cleanup old backups
    cleanup_old_backups "flash_config_*.tar.gz" "$BACKUP_BASE/flash"
    
    log ""
    log "=========================================="
    log "IMPORTANT RESTORE INSTRUCTIONS:"
    log "=========================================="
    log "1. Create new Unraid USB using USB Creator"
    log "2. Extract this backup to the USB /boot directory"
    log "3. If USB GUID changed, reactivate license at unraid.net"
    log "4. Boot from new USB - array should be intact"
    log "=========================================="
    log ""
    log "Flash backup finished successfully"
}

# Main script logic
case "$1" in
    backup_vm)
        backup_vm "$2" "$3" "$4" "$5"
        ;;
    backup_appdata)
        backup_appdata "$2" "${@:3}"
        ;;
    backup_plugins)
        backup_plugins "$2"
        ;;
    backup_flash)
        backup_flash "$2"
        ;;
    *)
        echo "Backup Unraid State - Docker Edition"
        echo ""
        echo "Usage:"
        echo "  $0 backup_vm <vmname> <stop|live> <compress: 0|1> [daily|weekly|monthly]"
        echo "  $0 backup_appdata <all|custom> [folder_list] [daily|weekly|monthly]"
        echo "  $0 backup_plugins [daily|weekly|monthly]"
        echo "  $0 backup_flash [daily|weekly|monthly]"
        exit 1
        ;;
esac
