#!/usr/bin/env python3
"""
Backup Unraid State - Docker Edition
A clean web interface for backing up VMs, appdata, and plugins
"""

from flask import Flask, render_template, request, jsonify, Response
import subprocess
import os
import json
import threading
from datetime import datetime
from pathlib import Path

app = Flask(__name__)

# Configuration
CONFIG_FILE = "/config/settings.json"
LOG_FILE = "/config/backup.log"
SCHEDULE_FILE = "/config/schedule.json"

@app.route('/favicon.ico')
def favicon():
    """Return empty favicon to prevent 404"""
    return '', 204

def load_config():
    """Load configuration from file"""
    default_config = {
        "backup_destination": "/backup",
        "vm_path": "/domains",
        "appdata_path": "/appdata",
        "max_backups": 2,
        "naming_scheme": "weekly"
    }
    
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, 'r') as f:
                saved = json.load(f)
                default_config.update(saved)
        except:
            pass
    
    return default_config

def save_config(config):
    """Save configuration to file"""
    try:
        with open(CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=2)
    except FileNotFoundError:
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        with open(CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=2)

def load_schedule():
    """Load schedule configuration"""
    default_schedule = {
        "enabled": False,
        "time": "03:00",
        "days": ["sunday"],
        "vm_enabled": True,
        "vm_list": [],
        "vm_handling": "stop",
        "vm_compress": True,
        "appdata_enabled": True,
        "appdata_mode": "all",
        "appdata_folders": [],
        "plugins_enabled": False,
        "flash_enabled": True,
        "naming_scheme": "weekly"
    }
    
    if os.path.exists(SCHEDULE_FILE):
        try:
            with open(SCHEDULE_FILE, 'r') as f:
                saved = json.load(f)
                default_schedule.update(saved)
        except:
            pass
    
    return default_schedule

def save_schedule(schedule):
    """Save schedule configuration"""
    try:
        with open(SCHEDULE_FILE, 'w') as f:
            json.dump(schedule, f, indent=2)
    except FileNotFoundError:
        os.makedirs(os.path.dirname(SCHEDULE_FILE), exist_ok=True)
        with open(SCHEDULE_FILE, 'w') as f:
            json.dump(schedule, f, indent=2)
    
    # Update crontab
    update_crontab(schedule)

def update_crontab(schedule):
    """Update crontab based on schedule"""
    cron_file = "/etc/cron.d/backup-schedule"
    
    if not schedule.get("enabled", False):
        # Remove cron job if disabled
        if os.path.exists(cron_file):
            os.remove(cron_file)
        return
    
    # Parse time
    time_parts = schedule.get("time", "03:00").split(":")
    hour = int(time_parts[0])
    minute = int(time_parts[1]) if len(time_parts) > 1 else 0
    
    # Convert days to cron format
    day_map = {
        "sunday": 0, "monday": 1, "tuesday": 2, "wednesday": 3,
        "thursday": 4, "friday": 5, "saturday": 6
    }
    days = schedule.get("days", ["sunday"])
    cron_days = ",".join(str(day_map.get(d.lower(), 0)) for d in days)
    
    # Create cron entry
    cron_line = f"{minute} {hour} * * {cron_days} /usr/bin/python3 /app/scheduled_backup.py >> /config/cron.log 2>&1\n"
    
    with open(cron_file, 'w') as f:
        f.write(cron_line)
    
    # Ensure cron can read it
    os.chmod(cron_file, 0o644)

def log_message(message):
    """Write to log file"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"[{timestamp}] {message}\n"
    
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(log_line)
    except FileNotFoundError:
        # Create directory if needed
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, 'a') as f:
            f.write(log_line)
    except Exception as e:
        print(f"Log error: {e}")
    
    print(log_line.strip())

def get_vms():
    """Get list of VMs from virsh - fast version"""
    try:
        # Get all VMs with state in one call
        result = subprocess.run(
            ['virsh', 'list', '--all'],
            capture_output=True, text=True, timeout=10
        )
        
        vm_list = []
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            # Skip header lines (first 2 lines)
            for line in lines[2:]:
                if line.strip():
                    parts = line.split()
                    if len(parts) >= 2:
                        # Format: "Id  Name  State" or "-  Name  shut off"
                        if parts[0] == '-':
                            vm_name = parts[1]
                            state = ' '.join(parts[2:]) if len(parts) > 2 else 'shut off'
                        else:
                            vm_name = parts[1]
                            state = ' '.join(parts[2:]) if len(parts) > 2 else 'unknown'
                        vm_list.append({"name": vm_name, "state": state})
        
        return vm_list
    except Exception as e:
        log_message(f"Error getting VMs: {e}")
        return []

def get_appdata_folders():
    """Get list of appdata folders - fast version without size calculation"""
    config = load_config()
    appdata_path = config.get("appdata_path", "/appdata")
    
    try:
        folders = []
        if os.path.exists(appdata_path):
            for item in sorted(os.listdir(appdata_path)):
                item_path = os.path.join(appdata_path, item)
                if os.path.isdir(item_path):
                    folders.append({"name": item, "size": "-"})
        
        return folders
    except Exception as e:
        log_message(f"Error getting appdata folders: {e}")
        return []

def get_existing_backups():
    """Get list of existing backups - fast version with limits and timeout"""
    config = load_config()
    backup_path = config.get("backup_destination", "/backup")
    
    backups = {"vms": [], "appdata": [], "plugins": [], "flash": []}
    
    def scan_dir(path, limit=5):
        """Scan directory for backup files, return most recent ones"""
        results = []
        try:
            if not os.path.exists(path):
                return results
            
            # Quick timeout check - if path takes too long, skip
            files = []
            try:
                files = os.listdir(path)
            except OSError:
                return results
            
            # Filter and sort
            backup_files = [f for f in files if f.endswith(('.tar', '.tar.gz'))]
            backup_files.sort(reverse=True)
            
            for f in backup_files[:limit]:
                fpath = os.path.join(path, f)
                try:
                    stat = os.stat(fpath)
                    results.append({
                        "name": f,
                        "size": format_size(stat.st_size),
                        "date": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M")
                    })
                except:
                    pass
        except Exception as e:
            pass
        return results
    
    # Scan each directory - if backup path is slow, this might timeout
    try:
        backups["vms"] = scan_dir(os.path.join(backup_path, "vms"))
        backups["appdata"] = scan_dir(os.path.join(backup_path, "appdata"))
        backups["plugins"] = scan_dir(os.path.join(backup_path, "plugins"))
        backups["flash"] = scan_dir(os.path.join(backup_path, "flash"))
    except Exception as e:
        log_message(f"Error scanning backups: {e}")
    
    return backups

def format_size(size_bytes):
    """Format bytes to human readable"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"

def run_backup_async(backup_type, **kwargs):
    """Run backup in background thread"""
    thread = threading.Thread(target=run_backup, args=(backup_type,), kwargs=kwargs)
    thread.daemon = True
    thread.start()
    return True

def run_backup(backup_type, **kwargs):
    """Execute backup script"""
    config = load_config()
    
    script_path = "/app/backup.sh"
    env = os.environ.copy()
    env["BACKUP_BASE"] = config.get("backup_destination", "/backup")
    env["VM_PATH"] = config.get("vm_path", "/domains")
    env["APPDATA_PATH"] = config.get("appdata_path", "/appdata")
    env["MAX_BACKUPS"] = str(config.get("max_backups", 2))
    
    try:
        if backup_type == "vm":
            vm_name = kwargs.get("vm_name")
            handling = kwargs.get("handling", "stop")
            compress = "1" if kwargs.get("compress", True) else "0"
            naming = kwargs.get("naming_scheme", "weekly")
            
            log_message(f"Starting VM backup: {vm_name}")
            cmd = [script_path, "backup_vm", vm_name, handling, compress, naming]
            
        elif backup_type == "appdata":
            mode = kwargs.get("mode", "all")
            folders = kwargs.get("folders", [])
            naming = kwargs.get("naming_scheme", "weekly")
            
            log_message(f"Starting appdata backup: {mode}")
            if mode == "all":
                cmd = [script_path, "backup_appdata", "all", naming]
            else:
                cmd = [script_path, "backup_appdata", "custom"] + folders + [naming]
                
        elif backup_type == "plugins":
            naming = kwargs.get("naming_scheme", "weekly")
            log_message("Starting plugins backup")
            cmd = [script_path, "backup_plugins", naming]
        
        elif backup_type == "flash":
            naming = kwargs.get("naming_scheme", "weekly")
            log_message("Starting flash drive backup (disaster recovery)")
            cmd = [script_path, "backup_flash", naming]
        
        else:
            log_message(f"Unknown backup type: {backup_type}")
            return False
        
        log_message(f"Running: {' '.join(cmd)}")
        
        result = subprocess.run(
            cmd,
            env=env,
            capture_output=True,
            text=True
        )
        
        if result.stdout:
            for line in result.stdout.strip().split('\n'):
                log_message(line)
        
        if result.stderr:
            for line in result.stderr.strip().split('\n'):
                log_message(f"STDERR: {line}")
        
        if result.returncode == 0:
            log_message(f"Backup completed successfully: {backup_type}")
            return True
        else:
            log_message(f"Backup failed with code {result.returncode}")
            return False
            
    except Exception as e:
        log_message(f"Backup error: {e}")
        return False

# ============== ROUTES ==============

@app.route('/')
def index():
    """Main dashboard - INSTANT: no blocking calls, everything loads via AJAX"""
    # Only load local config files (fast)
    config = load_config()
    schedule = load_schedule()
    
    # DON'T load VMs, folders, or backups here - all via AJAX
    # This prevents ANY slow mount from blocking page load
    vms = []
    folders = []
    backups = {"vms": [], "appdata": [], "plugins": [], "flash": []}
    
    return render_template('index.html',
        config=config,
        schedule=schedule,
        vms=vms,
        folders=folders,
        backups=backups
    )

@app.route('/api/backup/vm', methods=['POST'])
def api_backup_vm():
    """Start VM backup"""
    data = request.json
    vm_name = data.get('vm_name')
    handling = data.get('handling', 'stop')
    compress = data.get('compress', True)
    naming = data.get('naming_scheme', 'weekly')
    
    if not vm_name:
        return jsonify({"success": False, "error": "No VM specified"})
    
    run_backup_async("vm", vm_name=vm_name, handling=handling, 
                     compress=compress, naming_scheme=naming)
    
    return jsonify({"success": True, "message": f"VM backup started: {vm_name}"})

@app.route('/api/backup/appdata', methods=['POST'])
def api_backup_appdata():
    """Start appdata backup"""
    data = request.json
    mode = data.get('mode', 'all')
    folders = data.get('folders', [])
    naming = data.get('naming_scheme', 'weekly')
    
    run_backup_async("appdata", mode=mode, folders=folders, naming_scheme=naming)
    
    return jsonify({"success": True, "message": "Appdata backup started"})

@app.route('/api/backup/plugins', methods=['POST'])
def api_backup_plugins():
    """Start plugins backup"""
    data = request.json
    naming = data.get('naming_scheme', 'weekly')
    
    run_backup_async("plugins", naming_scheme=naming)
    
    return jsonify({"success": True, "message": "Plugins backup started"})

@app.route('/api/backup/flash', methods=['POST'])
def api_backup_flash():
    """Start flash drive backup (disaster recovery)"""
    data = request.json
    naming = data.get('naming_scheme', 'weekly')
    
    run_backup_async("flash", naming_scheme=naming)
    
    return jsonify({"success": True, "message": "Flash backup started - this is your disaster recovery backup!"})

@app.route('/api/schedule', methods=['GET', 'POST'])
def api_schedule():
    """Get or update schedule"""
    if request.method == 'GET':
        return jsonify(load_schedule())
    
    data = request.json
    save_schedule(data)
    return jsonify({"success": True, "message": "Schedule saved"})

@app.route('/api/settings', methods=['GET', 'POST'])
def api_settings():
    """Get or update settings"""
    if request.method == 'GET':
        return jsonify(load_config())
    
    data = request.json
    save_config(data)
    return jsonify({"success": True, "message": "Settings saved"})

@app.route('/api/vms')
def api_vms():
    """Get VM list"""
    return jsonify(get_vms())

@app.route('/api/folders')
def api_folders():
    """Get appdata folders"""
    return jsonify(get_appdata_folders())

@app.route('/api/backups')
def api_backups():
    """Get existing backups"""
    return jsonify(get_existing_backups())

@app.route('/api/log')
def api_log():
    """Get recent log entries"""
    lines = request.args.get('lines', 50, type=int)
    
    if os.path.exists(LOG_FILE):
        with open(LOG_FILE, 'r') as f:
            all_lines = f.readlines()
            return jsonify({"log": all_lines[-lines:]})
    
    return jsonify({"log": []})

@app.route('/api/log/stream')
def api_log_stream():
    """Stream log file (Server-Sent Events)"""
    def generate():
        last_pos = 0
        while True:
            if os.path.exists(LOG_FILE):
                with open(LOG_FILE, 'r') as f:
                    f.seek(last_pos)
                    new_lines = f.readlines()
                    last_pos = f.tell()
                    
                    for line in new_lines:
                        yield f"data: {line.strip()}\n\n"
            
            import time
            time.sleep(1)
    
    return Response(generate(), mimetype='text/event-stream')

if __name__ == '__main__':
    log_message("Backup Unraid State Docker starting...")
    app.run(host='0.0.0.0', port=5000, debug=False)
