#!/usr/bin/env python3
"""
Scheduled Backup Runner
Called by cron to run scheduled backups
"""

import json
import subprocess
import os
from datetime import datetime

CONFIG_DIR = "/config"
SCHEDULE_FILE = f"{CONFIG_DIR}/schedule.json"
LOG_FILE = f"{CONFIG_DIR}/backup.log"

def log(message):
    """Write to log file"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"[{timestamp}] [SCHEDULED] {message}\n"
    
    with open(LOG_FILE, 'a') as f:
        f.write(log_line)
    
    print(log_line.strip())

def load_schedule():
    """Load schedule configuration"""
    if os.path.exists(SCHEDULE_FILE):
        with open(SCHEDULE_FILE, 'r') as f:
            return json.load(f)
    return {}

def run_backup(backup_type, **kwargs):
    """Run a backup"""
    script_path = "/app/backup.sh"
    
    env = os.environ.copy()
    env["BACKUP_BASE"] = os.environ.get("BACKUP_BASE", "/backup")
    env["VM_PATH"] = os.environ.get("VM_PATH", "/domains")
    env["APPDATA_PATH"] = os.environ.get("APPDATA_PATH", "/appdata")
    env["PLUGINS_PATH"] = os.environ.get("PLUGINS_PATH", "/plugins")
    env["MAX_BACKUPS"] = os.environ.get("MAX_BACKUPS", "2")
    env["LOG_FILE"] = LOG_FILE
    
    try:
        if backup_type == "vm":
            vm_name = kwargs.get("vm_name")
            handling = kwargs.get("handling", "stop")
            compress = "1" if kwargs.get("compress", True) else "0"
            naming = kwargs.get("naming_scheme", "weekly")
            
            cmd = [script_path, "backup_vm", vm_name, handling, compress, naming]
            
        elif backup_type == "appdata":
            mode = kwargs.get("mode", "all")
            naming = kwargs.get("naming_scheme", "weekly")
            
            if mode == "all":
                cmd = [script_path, "backup_appdata", "all", naming]
            else:
                folders = kwargs.get("folders", [])
                cmd = [script_path, "backup_appdata", "custom"] + folders + [naming]
                
        elif backup_type == "plugins":
            naming = kwargs.get("naming_scheme", "weekly")
            cmd = [script_path, "backup_plugins", naming]
            
        elif backup_type == "flash":
            naming = kwargs.get("naming_scheme", "weekly")
            cmd = [script_path, "backup_flash", naming]
        
        else:
            log(f"Unknown backup type: {backup_type}")
            return False
        
        log(f"Running: {' '.join(cmd)}")
        
        result = subprocess.run(
            cmd,
            env=env,
            capture_output=True,
            text=True
        )
        
        if result.stdout:
            for line in result.stdout.strip().split('\n'):
                if line:
                    log(line)
        
        if result.stderr:
            for line in result.stderr.strip().split('\n'):
                if line:
                    log(f"STDERR: {line}")
        
        return result.returncode == 0
        
    except Exception as e:
        log(f"Error running {backup_type} backup: {e}")
        return False

def main():
    """Main scheduled backup runner"""
    log("=" * 50)
    log("Starting scheduled backup run")
    log("=" * 50)
    
    schedule = load_schedule()
    
    if not schedule.get("enabled", False):
        log("Scheduled backups are disabled, exiting")
        return
    
    naming_scheme = schedule.get("naming_scheme", "weekly")
    
    # Run VM backups
    if schedule.get("vm_enabled", False):
        vm_list = schedule.get("vm_list", [])
        vm_handling = schedule.get("vm_handling", "stop")
        vm_compress = schedule.get("vm_compress", True)
        
        if vm_list:
            for vm in vm_list:
                log(f"Starting scheduled VM backup: {vm}")
                run_backup("vm", 
                          vm_name=vm,
                          handling=vm_handling,
                          compress=vm_compress,
                          naming_scheme=naming_scheme)
        else:
            # If no specific VMs, try to get all VMs
            log("No specific VMs configured, backing up all VMs")
            try:
                result = subprocess.run(
                    ['virsh', 'list', '--all', '--name'],
                    capture_output=True, text=True, timeout=10
                )
                vms = [vm.strip() for vm in result.stdout.strip().split('\n') if vm.strip()]
                
                for vm in vms:
                    log(f"Starting scheduled VM backup: {vm}")
                    run_backup("vm",
                              vm_name=vm,
                              handling=vm_handling,
                              compress=vm_compress,
                              naming_scheme=naming_scheme)
            except Exception as e:
                log(f"Error getting VM list: {e}")
    
    # Run appdata backup
    if schedule.get("appdata_enabled", False):
        mode = schedule.get("appdata_mode", "all")
        folders = schedule.get("appdata_folders", [])
        
        log(f"Starting scheduled appdata backup (mode: {mode})")
        run_backup("appdata",
                  mode=mode,
                  folders=folders,
                  naming_scheme=naming_scheme)
    
    # Run plugins backup
    if schedule.get("plugins_enabled", False):
        log("Starting scheduled plugins backup")
        run_backup("plugins", naming_scheme=naming_scheme)
    
    # Run flash backup (disaster recovery)
    if schedule.get("flash_enabled", False):
        log("Starting scheduled flash backup (disaster recovery)")
        run_backup("flash", naming_scheme=naming_scheme)
    
    log("=" * 50)
    log("Scheduled backup run completed")
    log("=" * 50)

if __name__ == "__main__":
    main()
