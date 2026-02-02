#!/usr/bin/env python3
"""
Backup Unraid State - Docker Edition v2.6.0
Phase 2: Cancel support, better progress tracking
Phase 3.5: Local staging mode
"""

from flask import Flask, render_template, request, jsonify, Response
import subprocess
import os
import json
import threading
import time
import queue
import signal
from datetime import datetime, timedelta
from pathlib import Path

app = Flask(__name__)

# Configuration
CONFIG_FILE = "/config/settings.json"
LOG_FILE = "/config/backup.log"
SCHEDULE_FILE = "/config/schedule.json"
STATS_FILE = "/config/stats.json"
PID_FILE = "/config/backup.pid"

# Path configuration (from environment or defaults)
BACKUP_BASE = os.environ.get('BACKUP_BASE', '/backup')
APPDATA_PATH = os.environ.get('APPDATA_PATH', '/appdata')
DOMAINS_PATH = os.environ.get('DOMAINS_PATH', '/domains')
PLUGINS_PATH = os.environ.get('PLUGINS_PATH', '/plugins')

# Progress tracking - thread-safe state for each backup type
progress_state = {
    'vm': {'active': False, 'percent': 0, 'phase': '', 'eta': '', 'error': None, 'complete': False, 'pid': None},
    'appdata': {'active': False, 'percent': 0, 'phase': '', 'eta': '', 'error': None, 'complete': False, 'pid': None},
    'plugins': {'active': False, 'percent': 0, 'phase': '', 'eta': '', 'error': None, 'complete': False, 'pid': None},
    'flash': {'active': False, 'percent': 0, 'phase': '', 'eta': '', 'error': None, 'complete': False, 'pid': None}
}
progress_lock = threading.Lock()

# Running process tracking for cancel support
running_processes = {
    'vm': None,
    'appdata': None,
    'plugins': None,
    'flash': None
}
process_lock = threading.Lock()

# Message queues for SSE streaming (one per backup type)
progress_queues = {
    'vm': [],
    'appdata': [],
    'plugins': [],
    'flash': []
}

def update_progress(backup_type, percent=None, phase=None, eta=None, error=None, complete=False, log_line=None):
    """Update progress state and notify all listeners"""
    with progress_lock:
        state = progress_state[backup_type]
        if percent is not None:
            state['percent'] = percent
        if phase is not None:
            state['phase'] = phase
        if eta is not None:
            state['eta'] = eta
        if error is not None:
            state['error'] = error
        state['complete'] = complete
        state['active'] = not complete and error is None
        
        # Create event data
        event = {
            'percent': state['percent'],
            'phase': state['phase'],
            'eta': state['eta'],
            'error': state['error'],
            'complete': state['complete'],
            'log': log_line
        }
        
        # Add to all queues for this backup type
        for q in progress_queues[backup_type]:
            try:
                q.put_nowait(event)
            except:
                pass

def reset_progress(backup_type):
    """Reset progress state for a new backup"""
    with progress_lock:
        progress_state[backup_type] = {
            'active': True, 
            'percent': 0, 
            'phase': 'Starting...', 
            'eta': 'Calculating...', 
            'error': None, 
            'complete': False,
            'pid': None
        }

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
        "naming_scheme": "weekly",
        "compression_level": 6,
        "verify_backups": True,
        "exclude_folders": [],
        "incremental_enabled": False,
        "staging_enabled": False  # NEW: Local staging mode
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

def load_stats():
    """Load backup statistics"""
    default_stats = {
        "last_vm_backup": None,
        "last_appdata_backup": None,
        "last_plugins_backup": None,
        "last_flash_backup": None,
        "total_backup_size": 0,
        "backup_history": []
    }
    
    if os.path.exists(STATS_FILE):
        try:
            with open(STATS_FILE, 'r') as f:
                saved = json.load(f)
                default_stats.update(saved)
        except:
            pass
    
    return default_stats

def save_stats(stats):
    """Save backup statistics"""
    try:
        with open(STATS_FILE, 'w') as f:
            json.dump(stats, f, indent=2)
    except FileNotFoundError:
        os.makedirs(os.path.dirname(STATS_FILE), exist_ok=True)
        with open(STATS_FILE, 'w') as f:
            json.dump(stats, f, indent=2)

def update_stats(backup_type, size_bytes=0, success=True):
    """Update statistics after a backup"""
    stats = load_stats()
    now = datetime.now().isoformat()
    
    # Format size for display
    formatted_size = format_size(size_bytes)
    
    if backup_type == "vm":
        stats["last_vm_backup"] = now
        stats["last_vm_size"] = formatted_size
    elif backup_type == "appdata":
        stats["last_appdata_backup"] = now
        stats["last_appdata_size"] = formatted_size
    elif backup_type == "plugins":
        stats["last_plugins_backup"] = now
        stats["last_plugins_size"] = formatted_size
    elif backup_type == "flash":
        stats["last_flash_backup"] = now
        stats["last_flash_size"] = formatted_size
    
    stats["backup_history"].append({
        "type": backup_type,
        "timestamp": now,
        "size": size_bytes,
        "success": success
    })
    
    stats["backup_history"] = stats["backup_history"][-50:]
    
    try:
        config = load_config()
        backup_path = config.get("backup_destination", "/backup")
        total = 0
        for root, dirs, files in os.walk(backup_path):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except:
                    pass
        stats["total_backup_size"] = total
    except:
        pass
    
    save_stats(stats)

def get_next_scheduled_run():
    """Calculate when the next scheduled backup will run"""
    schedule = load_schedule()
    
    if not schedule.get("enabled", False):
        return None
    
    now = datetime.now()
    time_parts = schedule.get("time", "03:00").split(":")
    scheduled_hour = int(time_parts[0])
    scheduled_minute = int(time_parts[1]) if len(time_parts) > 1 else 0
    
    day_map = {
        "sunday": 6, "monday": 0, "tuesday": 1, "wednesday": 2,
        "thursday": 3, "friday": 4, "saturday": 5,
        "sun": 6, "mon": 0, "tue": 1, "wed": 2,
        "thu": 3, "fri": 4, "sat": 5
    }
    
    scheduled_days = [day_map.get(d.lower(), 6) for d in schedule.get("days", ["sunday"])]
    
    for i in range(8):
        check_date = now + timedelta(days=i)
        if check_date.weekday() in scheduled_days:
            next_run = check_date.replace(hour=scheduled_hour, minute=scheduled_minute, second=0, microsecond=0)
            if next_run > now:
                return next_run.strftime("%Y-%m-%d %H:%M")
    
    return None

def format_size(size_bytes):
    """Format bytes to human readable"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"

def load_schedule():
    """Load schedule configuration"""
    default_schedule = {
        "enabled": False,
        "time": "03:00",
        "days": ["sun"],
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
    
    update_crontab(schedule)

def update_crontab(schedule):
    """Update crontab based on schedule"""
    cron_file = "/etc/cron.d/backup-schedule"
    
    if not schedule.get("enabled", False):
        if os.path.exists(cron_file):
            os.remove(cron_file)
        return
    
    time_parts = schedule.get("time", "03:00").split(":")
    hour = int(time_parts[0])
    minute = int(time_parts[1]) if len(time_parts) > 1 else 0
    
    day_map = {
        "sunday": 0, "monday": 1, "tuesday": 2, "wednesday": 3,
        "thursday": 4, "friday": 5, "saturday": 6,
        "sun": 0, "mon": 1, "tue": 2, "wed": 3,
        "thu": 4, "fri": 5, "sat": 6
    }
    days = schedule.get("days", ["sunday"])
    cron_days = ",".join(str(day_map.get(d.lower(), 0)) for d in days)
    
    cron_line = f"{minute} {hour} * * {cron_days} /usr/bin/python3 /app/scheduled_backup.py >> /config/cron.log 2>&1\n"
    
    with open(cron_file, 'w') as f:
        f.write(cron_line)
    
    os.chmod(cron_file, 0o644)

def log_message(message):
    """Write to log file"""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"[{timestamp}] {message}\n"
    
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(log_line)
    except FileNotFoundError:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, 'a') as f:
            f.write(log_line)
    except Exception as e:
        print(f"Log error: {e}")
    
    print(log_line.strip())

def get_vms():
    """Get list of VMs from virsh"""
    try:
        result = subprocess.run(
            ['virsh', 'list', '--all'],
            capture_output=True, text=True, timeout=10
        )
        
        vm_list = []
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            for line in lines[2:]:
                if line.strip():
                    parts = line.split()
                    if len(parts) >= 2:
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
    """Get list of appdata folders"""
    config = load_config()
    appdata_path = config.get("appdata_path", "/appdata")
    exclude_list = config.get("exclude_folders", [])
    
    try:
        folders = []
        if os.path.exists(appdata_path):
            for item in sorted(os.listdir(appdata_path)):
                item_path = os.path.join(appdata_path, item)
                if os.path.isdir(item_path):
                    excluded = item in exclude_list
                    folders.append({"name": item, "size": "-", "excluded": excluded})
        
        return folders
    except Exception as e:
        log_message(f"Error getting appdata folders: {e}")
        return []

def get_existing_backups():
    """Get list of existing backups (handles both TAR and RSYNC modes)"""
    config = load_config()
    backup_path = config.get("backup_destination", "/backup")
    incremental = config.get("incremental_enabled", False)
    
    backups = {"vms": [], "appdata": [], "plugins": [], "flash": []}
    
    def scan_tar_dir(path, limit=5):
        """Scan directory for .tar.gz files"""
        results = []
        try:
            if not os.path.exists(path):
                return results
            
            files = os.listdir(path)
            backup_files = [f for f in files if f.endswith(('.tar', '.tar.gz'))]
            backup_files.sort(reverse=True)
            
            for f in backup_files[:limit]:
                fpath = os.path.join(path, f)
                try:
                    stat = os.stat(fpath)
                    results.append({
                        "name": f,
                        "path": fpath,
                        "size": format_size(stat.st_size),
                        "date": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
                        "mode": "tar"
                    })
                except:
                    pass
        except:
            pass
        return results
    
    def scan_rsync_snapshots(path, limit=5):
        """Scan snapshots directory for RSYNC backups"""
        results = []
        try:
            snapshots_dir = os.path.join(path, "snapshots")
            if not os.path.exists(snapshots_dir):
                return results
            
            # Get all snapshot directories
            snapshots = []
            for item in os.listdir(snapshots_dir):
                item_path = os.path.join(snapshots_dir, item)
                if os.path.isdir(item_path):
                    try:
                        stat = os.stat(item_path)
                        snapshots.append({
                            "name": item,
                            "path": item_path,
                            "mtime": stat.st_mtime
                        })
                    except:
                        pass
            
            # Sort by modification time (newest first)
            snapshots.sort(key=lambda x: x['mtime'], reverse=True)
            
            for snap in snapshots[:limit]:
                total_size = 0
                # Try to read size from .backup_size file (instant)
                size_file = os.path.join(snap['path'], '.backup_size')
                try:
                    if os.path.exists(size_file):
                        with open(size_file, 'r') as f:
                            total_size = int(f.read().strip())
                except:
                    pass
                
                # Fallback to du if no size file (slower, but needed for old backups)
                if total_size == 0:
                    try:
                        result = subprocess.run(
                            ['du', '-sb', snap['path']], 
                            capture_output=True, text=True, timeout=60
                        )
                        if result.returncode == 0:
                            total_size = int(result.stdout.split()[0])
                    except:
                        pass
                
                results.append({
                    "name": snap['name'],
                    "path": snap['path'],
                    "size": format_size(total_size) if total_size else "~",
                    "date": datetime.fromtimestamp(snap['mtime']).strftime("%Y-%m-%d %H:%M"),
                    "mode": "rsync"
                })
        except:
            pass
        return results
    
    try:
        # VMs - always TAR
        backups["vms"] = scan_tar_dir(os.path.join(backup_path, "VMs"))
        
        # Plugins - always TAR
        backups["plugins"] = scan_tar_dir(os.path.join(backup_path, "plugins"))
        
        # Flash - always TAR
        backups["flash"] = scan_tar_dir(os.path.join(backup_path, "flash"))
        
        # Appdata - check both TAR and RSYNC directories
        appdata_backups = []
        
        # Check TAR directories (backup_weekly_tar, backup_daily_tar, etc.)
        for naming in ['weekly', 'daily', 'monthly']:
            tar_path = os.path.join(backup_path, f"backup_{naming}_tar")
            appdata_backups.extend(scan_tar_dir(tar_path))
            
            # Also check old format (backup_weekly without suffix)
            old_path = os.path.join(backup_path, f"backup_{naming}")
            if os.path.exists(old_path) and not os.path.exists(os.path.join(old_path, "snapshots")):
                appdata_backups.extend(scan_tar_dir(old_path))
        
        # Check RSYNC directories (backup_weekly_rsync, etc.)
        for naming in ['weekly', 'daily', 'monthly']:
            rsync_path = os.path.join(backup_path, f"backup_{naming}_rsync")
            appdata_backups.extend(scan_rsync_snapshots(rsync_path))
            
            # Also check old format with snapshots subdirectory
            old_path = os.path.join(backup_path, f"backup_{naming}")
            if os.path.exists(os.path.join(old_path, "snapshots")):
                appdata_backups.extend(scan_rsync_snapshots(old_path))
        
        # Sort all appdata backups by date (newest first)
        appdata_backups.sort(key=lambda x: x['date'], reverse=True)
        backups["appdata"] = appdata_backups[:5]  # Keep top 5
        
    except Exception as e:
        log_message(f"Error scanning backups: {e}")
    
    return backups

def calculate_backup_size(backup_type, naming_scheme="weekly"):
    """Calculate the size of the most recent backup"""
    config = load_config()
    backup_base = config.get("backup_destination", "/backup")
    incremental = config.get("incremental_enabled", False)
    
    # Determine backup mode suffix
    mode_suffix = "_rsync" if incremental else "_tar"
    
    total_size = 0
    
    try:
        if backup_type == "vm":
            vm_dir = os.path.join(backup_base, "VMs")
            if os.path.exists(vm_dir):
                # Get most recent VM backup
                files = [f for f in os.listdir(vm_dir) if f.endswith('.tar.gz')]
                if files:
                    files.sort(reverse=True)
                    latest = os.path.join(vm_dir, files[0])
                    total_size = os.path.getsize(latest)
        
        elif backup_type == "appdata":
            # Check both new format (with mode suffix) and old format
            backup_dir_new = os.path.join(backup_base, f"backup_{naming_scheme}{mode_suffix}")
            backup_dir_old = os.path.join(backup_base, f"backup_{naming_scheme}")
            
            # Prefer new format, fall back to old
            backup_dir = backup_dir_new if os.path.exists(backup_dir_new) else backup_dir_old
            
            if incremental:
                # RSYNC mode - check snapshots
                snapshots_dir = os.path.join(backup_dir, "snapshots")
                if os.path.exists(snapshots_dir):
                    # Get most recent snapshot
                    snapshots = [d for d in os.listdir(snapshots_dir) if os.path.isdir(os.path.join(snapshots_dir, d))]
                    if snapshots:
                        snapshots.sort(reverse=True)
                        latest = os.path.join(snapshots_dir, snapshots[0])
                        for root, dirs, files in os.walk(latest):
                            for f in files:
                                try:
                                    total_size += os.path.getsize(os.path.join(root, f))
                                except:
                                    pass
            else:
                # TAR mode - check for .tar.gz
                if os.path.exists(backup_dir):
                    files = [f for f in os.listdir(backup_dir) if f.endswith('.tar.gz')]
                    if files:
                        files.sort(reverse=True)
                        latest = os.path.join(backup_dir, files[0])
                        total_size = os.path.getsize(latest)
        
        elif backup_type == "plugins":
            plugins_dir = os.path.join(backup_base, "plugins")
            if os.path.exists(plugins_dir):
                files = [f for f in os.listdir(plugins_dir) if f.endswith('.tar.gz')]
                if files:
                    files.sort(reverse=True)
                    latest = os.path.join(plugins_dir, files[0])
                    total_size = os.path.getsize(latest)
        
        elif backup_type == "flash":
            flash_dir = os.path.join(backup_base, "flash")
            if os.path.exists(flash_dir):
                files = [f for f in os.listdir(flash_dir) if f.endswith('.tar.gz')]
                if files:
                    files.sort(reverse=True)
                    latest = os.path.join(flash_dir, files[0])
                    total_size = os.path.getsize(latest)
    
    except Exception as e:
        log_message(f"Error calculating backup size: {e}")
    
    return total_size

def run_backup_async(backup_type, **kwargs):
    """Run backup in background thread with progress tracking"""
    thread = threading.Thread(target=run_backup_with_progress, args=(backup_type,), kwargs=kwargs)
    thread.daemon = True
    thread.start()
    return True

def run_backup_with_progress(backup_type, **kwargs):
    """Execute backup script with real-time progress parsing"""
    config = load_config()
    reset_progress(backup_type)
    
    script_path = "/app/backup.sh"
    env = os.environ.copy()
    env["BACKUP_BASE"] = config.get("backup_destination", "/backup")
    env["VM_PATH"] = config.get("vm_path", "/domains")
    env["APPDATA_PATH"] = config.get("appdata_path", "/appdata")
    env["MAX_BACKUPS"] = str(config.get("max_backups", 2))
    env["COMPRESSION_LEVEL"] = str(config.get("compression_level", 6))
    env["VERIFY_BACKUPS"] = "1" if config.get("verify_backups", True) else "0"
    env["EXCLUDE_FOLDERS"] = ",".join(config.get("exclude_folders", []))
    env["INCREMENTAL"] = "1" if config.get("incremental_enabled", False) else "0"
    env["STAGING_ENABLED"] = "1" if config.get("staging_enabled", False) else "0"
    env["PROGRESS_ENABLED"] = "1"  # Tell script to output progress markers
    
    start_time = time.time()
    
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
            update_progress(backup_type, error="Unknown backup type", complete=True)
            return False
        
        log_message(f"Running: {' '.join(cmd)}")
        
        # Use Popen for real-time output
        process = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        
        # Store process reference for cancel support
        with process_lock:
            running_processes[backup_type] = process
        
        # Store PID in progress state
        with progress_lock:
            progress_state[backup_type]['pid'] = process.pid
        
        # Read output line by line
        for line in process.stdout:
            line = line.strip()
            if not line:
                continue
            
            # Parse PROGRESS markers: PROGRESS|percent|phase|eta
            if line.startswith("PROGRESS|"):
                parts = line.split("|", 3)
                if len(parts) >= 3:
                    try:
                        percent = int(parts[1])
                        phase = parts[2]
                        eta = parts[3] if len(parts) > 3 else ""
                        update_progress(backup_type, percent=percent, phase=phase, eta=eta, log_line=phase)
                    except ValueError:
                        pass
            else:
                # Regular log line - just send to SSE (backup.sh already wrote to log file via tee)
                update_progress(backup_type, log_line=line)
        
        process.wait()
        
        # Clear process reference
        with process_lock:
            running_processes[backup_type] = None
        
        elapsed = time.time() - start_time
        elapsed_str = f"{int(elapsed // 60)}m {int(elapsed % 60)}s"
        
        if process.returncode == 0:
            log_message(f"Backup completed successfully: {backup_type} in {elapsed_str}")
            update_progress(backup_type, percent=100, phase="Complete", eta="", complete=True, log_line=f"Completed in {elapsed_str}")
            
            # Calculate backup size
            naming = kwargs.get("naming_scheme", "weekly")
            backup_size = calculate_backup_size(backup_type, naming)
            log_message(f"Backup size: {format_size(backup_size)}")
            
            update_stats(backup_type, size_bytes=backup_size, success=True)
            return True
        else:
            # Check if it was cancelled
            if process.returncode == 1:
                # Could be cancel or error - check log
                log_message(f"Backup ended with code {process.returncode}")
            else:
                log_message(f"Backup failed with code {process.returncode}")
            update_progress(backup_type, error=f"Failed (code {process.returncode})", complete=True, log_line=f"Failed with code {process.returncode}")
            update_stats(backup_type, size_bytes=0, success=False)
            return False
            
    except Exception as e:
        log_message(f"Backup error: {e}")
        update_progress(backup_type, error=str(e), complete=True, log_line=f"Error: {e}")
        update_stats(backup_type, success=False)
        
        # Clear process reference on error
        with process_lock:
            running_processes[backup_type] = None
        
        return False

# ============== ROUTES ==============

@app.route('/')
def index():
    """Main dashboard"""
    config = load_config()
    schedule = load_schedule()
    
    return render_template('index.html',
        config=config,
        schedule=schedule,
        vms=[],
        folders=[],
        backups={"vms": [], "appdata": [], "plugins": [], "flash": []}
    )

@app.route('/api/backup/progress/<backup_type>')
def api_backup_progress(backup_type):
    """SSE endpoint for real-time backup progress"""
    if backup_type not in progress_state:
        return jsonify({"error": "Invalid backup type"}), 400
    
    def generate():
        # Create a queue for this client
        q = queue.Queue()
        progress_queues[backup_type].append(q)
        
        try:
            # Send initial state
            with progress_lock:
                state = progress_state[backup_type].copy()
            yield f"data: {json.dumps(state)}\n\n"
            
            # Stream updates
            while True:
                try:
                    event = q.get(timeout=30)  # 30 second timeout for keep-alive
                    yield f"data: {json.dumps(event)}\n\n"
                    
                    # Stop if complete or error
                    if event.get('complete') or event.get('error'):
                        break
                except queue.Empty:
                    # Send keep-alive
                    yield f": keepalive\n\n"
                    
                    # Check if backup is still active
                    with progress_lock:
                        if not progress_state[backup_type]['active']:
                            break
        finally:
            # Remove queue when done
            try:
                progress_queues[backup_type].remove(q)
            except:
                pass
    
    return Response(generate(), mimetype='text/event-stream', headers={
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no'
    })

@app.route('/api/backup/status/<backup_type>')
def api_backup_status(backup_type):
    """Get current backup status (non-streaming)"""
    if backup_type not in progress_state:
        return jsonify({"error": "Invalid backup type"}), 400
    
    with progress_lock:
        return jsonify(progress_state[backup_type].copy())

@app.route('/api/backup/cancel/<backup_type>', methods=['POST'])
def api_backup_cancel(backup_type):
    """Cancel a running backup"""
    if backup_type not in progress_state:
        return jsonify({"success": False, "error": "Invalid backup type"}), 400
    
    with progress_lock:
        if not progress_state[backup_type]['active']:
            return jsonify({"success": False, "error": "No backup running"})
    
    # Try to get the process
    with process_lock:
        process = running_processes.get(backup_type)
    
    if process is None:
        # Try to read PID from file as fallback
        try:
            if os.path.exists(PID_FILE):
                with open(PID_FILE, 'r') as f:
                    pid = int(f.read().strip())
                    os.kill(pid, signal.SIGTERM)
                    log_message(f"Sent SIGTERM to backup process (PID: {pid})")
                    update_progress(backup_type, phase="Cancelling...", log_line="Cancel requested - cleaning up...")
                    return jsonify({"success": True, "message": "Cancel signal sent"})
        except Exception as e:
            log_message(f"Error reading PID file: {e}")
        
        return jsonify({"success": False, "error": "Could not find backup process"})
    
    try:
        # Send SIGTERM for graceful shutdown
        process.send_signal(signal.SIGTERM)
        log_message(f"Cancel requested for {backup_type} backup")
        update_progress(backup_type, phase="Cancelling...", log_line="Cancel requested - cleaning up...")
        return jsonify({"success": True, "message": "Cancel signal sent"})
    except Exception as e:
        log_message(f"Error cancelling backup: {e}")
        return jsonify({"success": False, "error": str(e)})

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
    """Start flash drive backup"""
    data = request.json
    naming = data.get('naming_scheme', 'weekly')
    
    run_backup_async("flash", naming_scheme=naming)
    
    return jsonify({"success": True, "message": "Flash backup started"})

# ============== RESTORE FUNCTIONS ==============

def run_restore_async(restore_type, backup_file, **kwargs):
    """Run restore in background thread"""
    thread = threading.Thread(target=run_restore, args=(restore_type, backup_file), kwargs=kwargs)
    thread.daemon = True
    thread.start()
    return True

def run_restore(restore_type, backup_file, **kwargs):
    """Execute restore script"""
    config = load_config()
    
    script_path = "/app/backup.sh"
    env = os.environ.copy()
    env["BACKUP_BASE"] = config.get("backup_destination", "/backup")
    env["VM_PATH"] = config.get("vm_path", "/domains")
    env["APPDATA_PATH"] = config.get("appdata_path", "/appdata")
    
    try:
        log_message(f"Starting restore: {restore_type} from {backup_file}")
        
        if restore_type == "vm":
            vm_name = kwargs.get("vm_name", "")
            cmd = [script_path, "restore_vm", backup_file, vm_name]
        elif restore_type == "appdata":
            cmd = [script_path, "restore_appdata", backup_file]
        elif restore_type == "plugins":
            cmd = [script_path, "restore_plugins", backup_file]
        else:
            log_message(f"Unknown restore type: {restore_type}")
            return False
        
        log_message(f"Running: {' '.join(cmd)}")
        
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
        
        if result.stdout:
            for line in result.stdout.strip().split('\n'):
                log_message(line)
        
        if result.stderr:
            for line in result.stderr.strip().split('\n'):
                log_message(f"STDERR: {line}")
        
        if result.returncode == 0:
            log_message(f"Restore completed successfully: {restore_type}")
            return True
        else:
            log_message(f"Restore failed with code {result.returncode}")
            return False
            
    except Exception as e:
        log_message(f"Restore error: {e}")
        return False

@app.route('/api/restore/vm', methods=['POST'])
def api_restore_vm():
    """Start VM restore"""
    data = request.json
    backup_file = data.get('backup_file')
    vm_name = data.get('vm_name', '')
    
    if not backup_file:
        return jsonify({"success": False, "error": "No backup file specified"})
    
    run_restore_async("vm", backup_file, vm_name=vm_name)
    
    return jsonify({"success": True, "message": f"VM restore started from: {backup_file}"})

@app.route('/api/restore/plugins', methods=['POST'])
def api_restore_plugins():
    """Start plugins restore"""
    data = request.json
    backup_file = data.get('backup_file')
    
    if not backup_file:
        return jsonify({"success": False, "error": "No backup file specified"})
    
    run_restore_async("plugins", backup_file)
    
    return jsonify({"success": True, "message": f"Plugins restore started from: {backup_file}"})

@app.route('/api/vms')
def api_vms():
    """Get list of VMs"""
    return jsonify(get_vms())

@app.route('/api/folders')
def api_folders():
    """Get list of appdata folders"""
    return jsonify(get_appdata_folders())

@app.route('/api/backups')
def api_backups():
    """Get existing backups"""
    return jsonify(get_existing_backups())

@app.route('/api/backups/<backup_type>')
def api_backups_by_type(backup_type):
    """Get backups for a specific type (for progressive loading)"""
    config = load_config()
    backup_path = config.get("backup_destination", "/backup")
    
    def scan_tar_dir(path, limit=5):
        results = []
        try:
            if not os.path.exists(path):
                return results
            files = os.listdir(path)
            backup_files = [f for f in files if f.endswith(('.tar', '.tar.gz'))]
            backup_files.sort(reverse=True)
            for f in backup_files[:limit]:
                fpath = os.path.join(path, f)
                try:
                    stat = os.stat(fpath)
                    results.append({
                        "name": f, "path": fpath,
                        "size": format_size(stat.st_size),
                        "date": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
                        "mode": "tar"
                    })
                except: pass
        except: pass
        return results
    
    def scan_rsync_fast(path, limit=5):
        results = []
        try:
            snapshots_dir = os.path.join(path, "snapshots")
            if not os.path.exists(snapshots_dir):
                return results
            snapshots = []
            for item in os.listdir(snapshots_dir):
                item_path = os.path.join(snapshots_dir, item)
                if os.path.isdir(item_path):
                    try:
                        stat = os.stat(item_path)
                        snapshots.append({"name": item, "path": item_path, "mtime": stat.st_mtime})
                    except: pass
            snapshots.sort(key=lambda x: x['mtime'], reverse=True)
            for snap in snapshots[:limit]:
                total_size = 0
                # Try to read size from .backup_size file (instant)
                size_file = os.path.join(snap['path'], '.backup_size')
                try:
                    if os.path.exists(size_file):
                        with open(size_file, 'r') as f:
                            total_size = int(f.read().strip())
                except: pass
                
                # Fallback to du if no size file (slower, but needed for old backups)
                if total_size == 0:
                    try:
                        result = subprocess.run(['du', '-sb', snap['path']], capture_output=True, text=True, timeout=60)
                        total_size = int(result.stdout.split()[0]) if result.returncode == 0 else 0
                    except: pass
                
                results.append({
                    "name": snap['name'], "path": snap['path'],
                    "size": format_size(total_size) if total_size else "~",
                    "date": datetime.fromtimestamp(snap['mtime']).strftime("%Y-%m-%d %H:%M"),
                    "mode": "rsync"
                })
        except: pass
        return results
    
    try:
        if backup_type == 'vms':
            return jsonify(scan_tar_dir(os.path.join(backup_path, "VMs")))
        elif backup_type == 'plugins':
            return jsonify(scan_tar_dir(os.path.join(backup_path, "plugins")))
        elif backup_type == 'flash':
            return jsonify(scan_tar_dir(os.path.join(backup_path, "flash")))
        elif backup_type == 'appdata':
            appdata_backups = []
            for naming in ['weekly', 'daily', 'monthly']:
                appdata_backups.extend(scan_tar_dir(os.path.join(backup_path, f"backup_{naming}_tar")))
                old_path = os.path.join(backup_path, f"backup_{naming}")
                if os.path.exists(old_path) and not os.path.exists(os.path.join(old_path, "snapshots")):
                    appdata_backups.extend(scan_tar_dir(old_path))
                appdata_backups.extend(scan_rsync_fast(os.path.join(backup_path, f"backup_{naming}_rsync")))
                if os.path.exists(os.path.join(old_path, "snapshots")):
                    appdata_backups.extend(scan_rsync_fast(old_path))
            appdata_backups.sort(key=lambda x: x['date'], reverse=True)
            return jsonify(appdata_backups[:5])
        else:
            return jsonify([])
    except Exception as e:
        log_message(f"Error scanning {backup_type}: {e}")
        return jsonify([])

@app.route('/api/server-time')
def api_server_time():
    """Get current server time"""
    return jsonify({
        "time": datetime.now().strftime("%H:%M:%S"),
        "date": datetime.now().strftime("%Y-%m-%d"),
        "timezone": os.environ.get('TZ', 'UTC')
    })

@app.route('/api/stats')
def api_stats():
    """Get backup statistics"""
    stats = load_stats()
    stats["next_scheduled"] = get_next_scheduled_run()
    return jsonify(stats)

@app.route('/api/settings', methods=['GET', 'POST'])
def api_settings():
    """Get or update settings"""
    if request.method == 'POST':
        data = request.json
        config = load_config()
        
        # Update allowed settings
        for key in ['max_backups', 'naming_scheme', 'compression_level', 
                    'verify_backups', 'exclude_folders', 'incremental_enabled',
                    'staging_enabled']:  # NEW: staging_enabled
            if key in data:
                config[key] = data[key]
        
        save_config(config)
        return jsonify({"success": True})
    
    return jsonify(load_config())

@app.route('/api/schedule', methods=['GET', 'POST'])
def api_schedule():
    """Get or update schedule"""
    if request.method == 'POST':
        data = request.json
        schedule = load_schedule()
        schedule.update(data)
        save_schedule(schedule)
        return jsonify({"success": True})
    
    return jsonify(load_schedule())

@app.route('/api/validate-backup')
def api_validate_backup():
    """Validate backup destination is accessible"""
    config = load_config()
    backup_dest = config.get("backup_destination", "/backup")
    issues = []
    
    # Check if backup path exists
    if not os.path.exists(backup_dest):
        issues.append(f"Backup destination does not exist: {backup_dest}")
    elif not os.path.isdir(backup_dest):
        issues.append(f"Backup destination is not a directory: {backup_dest}")
    else:
        # Check if writable
        test_file = os.path.join(backup_dest, ".write_test")
        try:
            with open(test_file, 'w') as f:
                f.write("test")
            os.remove(test_file)
        except Exception as e:
            issues.append(f"Backup destination not writable: {e}")
    
    # Get free space
    try:
        stat = os.statvfs(backup_dest)
        free_bytes = stat.f_bavail * stat.f_frsize
        free_gb = free_bytes / (1024**3)
        
        if free_gb < 1:
            issues.append(f"Low disk space: {free_gb:.1f}GB free")
    except:
        pass
    
    return jsonify({
        "valid": len(issues) == 0,
        "issues": issues,
        "path": backup_dest,
        "free_space": f"{free_gb:.1f}GB" if 'free_gb' in dir() else "Unknown"
    })

@app.route('/api/container-metadata')
def api_container_metadata():
    """Get saved container metadata from backups"""
    config = load_config()
    backup_base = config.get("backup_destination", "/backup")
    
    containers = []
    
    # Search all backup directories for container metadata
    for backup_dir in Path(backup_base).glob("backup_*/container_metadata"):
        if not backup_dir.is_dir():
            continue
        
        metadata_dir = str(backup_dir)
        for filename in os.listdir(metadata_dir):
            if filename.endswith('.json') and filename != 'container_mapping.json':
                filepath = os.path.join(metadata_dir, filename)
                try:
                    with open(filepath, 'r') as f:
                        data = json.load(f)
                        containers.append({
                            'container_name': data.get('container_name', ''),
                            'image': data.get('image', ''),
                            'appdata_folder': data.get('appdata_folder', ''),
                            'template': data.get('unraid_template', ''),
                            'state': data.get('state', '')
                        })
                except:
                    pass
    
    return jsonify({'containers': containers})

@app.route('/api/docker-xmls', methods=['GET', 'DELETE'])
def api_docker_xmls():
    """List or delete Docker template XMLs"""
    templates_path = "/boot/config/plugins/dockerMan/templates-user"
    
    if request.method == 'DELETE':
        data = request.get_json()
        filenames = data.get('filenames', [])
        
        # Support single filename for backward compatibility
        if not filenames and data.get('filename'):
            filenames = [data.get('filename')]
        
        if not filenames:
            return jsonify({'success': False, 'error': 'No files specified'})
        
        deleted = []
        errors = []
        
        for filename in filenames:
            if not filename or '..' in filename or '/' in filename:
                errors.append(f"{filename}: Invalid filename")
                continue
            
            filepath = os.path.join(templates_path, filename)
            
            if not os.path.exists(filepath):
                errors.append(f"{filename}: File not found")
                continue
            
            try:
                os.remove(filepath)
                log_message(f"Deleted Docker template: {filename}")
                deleted.append(filename)
            except Exception as e:
                errors.append(f"{filename}: {str(e)}")
        
        return jsonify({
            'success': len(deleted) > 0,
            'deleted': deleted,
            'errors': errors
        })
    
    # GET - List XMLs
    xmls = []
    
    if not os.path.isdir(templates_path):
        return jsonify({'xmls': []})
    
    # Get list of all containers (running and stopped)
    try:
        result = subprocess.run(['docker', 'ps', '-a', '--format', '{{.Names}}'], 
                                capture_output=True, text=True, timeout=10)
        container_names = result.stdout.strip().split('\n') if result.returncode == 0 else []
        # Create normalized lookup (lowercase, no hyphens/underscores/numbers)
        def normalize(name):
            return name.lower().replace('-', '').replace('_', '').replace(' ', '')
        
        # Store both normalized and original names
        container_lookup = {normalize(c): c for c in container_names if c}
        container_list = [c for c in container_names if c]
    except:
        container_lookup = {}
        container_list = []
    
    def find_matching_container(template_name, appdata_path=None, filename=""):
        """Try to match template to a container using multiple strategies"""
        norm_template = normalize(template_name)
        
        # Strategy 1: Exact normalized match
        if norm_template in container_lookup:
            return True
        
        # Strategy 2: Partial match - template name contains container name or vice versa
        for container in container_list:
            norm_container = normalize(container)
            # Check if one contains the other (at least 4 chars to avoid false positives)
            if len(norm_template) >= 4 and len(norm_container) >= 4:
                if norm_template in norm_container or norm_container in norm_template:
                    return True
            # Also check original names for partial match
            template_lower = template_name.lower()
            container_lower = container.lower()
            if len(template_lower) >= 4 and len(container_lower) >= 4:
                if template_lower in container_lower or container_lower in template_lower:
                    return True
        
        # Strategy 3: Match by appdata folder name
        if appdata_path:
            appdata_folder = appdata_path.rstrip('/').split('/')[-1].lower()
            if len(appdata_folder) >= 3:
                for container in container_list:
                    if appdata_folder in container.lower() or container.lower() in appdata_folder:
                        return True
        
        return False
    
    for filename in sorted(os.listdir(templates_path)):
        if not filename.endswith('.xml'):
            continue
        
        filepath = os.path.join(templates_path, filename)
        
        # Try to extract container name and appdata path from XML
        container_name = filename.replace('my-', '').replace('.xml', '')
        appdata_path = None
        
        try:
            with open(filepath, 'r') as f:
                content = f.read()
                import re
                # Look for <n> tag (container name)
                match = re.search(r'<n>([^<]+)</n>', content)
                if match:
                    container_name = match.group(1)
                
                # Look for appdata path in volume mappings
                appdata_match = re.search(r'/mnt/user/appdata/([^/<"\']+)', content)
                if appdata_match:
                    appdata_path = appdata_match.group(1)
                
                print(f"DEBUG XML: file='{filename}' container_name='{container_name}' appdata='{appdata_path}'")
        except Exception as e:
            print(f"DEBUG XML ERROR: file='{filename}' error={str(e)}")
            pass
        
        # Check if container exists using multiple matching strategies
        has_container = find_matching_container(container_name, appdata_path, filename)
        
        xmls.append({
            'filename': filename,
            'name': container_name,
            'has_container': has_container
        })
    
    return jsonify({'xmls': xmls})


@app.route('/api/restore/appdata', methods=['POST'])
def api_restore_appdata():
    """Restore appdata with options"""
    data = request.get_json()
    backup_source = data.get('backup_source', '')
    folder = data.get('folder', '')
    mode = data.get('mode', 'appdata_only')  # appdata_only, pull_image, full_restore
    
    if not backup_source:
        return jsonify({'success': False, 'error': 'No backup source specified'})
    
    # Validate mode
    if mode not in ['appdata_only', 'pull_image', 'full_restore']:
        mode = 'appdata_only'
    
    try:
        env = os.environ.copy()
        env['BACKUP_BASE'] = BACKUP_BASE
        env['APPDATA_PATH'] = APPDATA_PATH
        
        cmd = ['/app/backup.sh', 'restore_appdata', backup_source, folder, mode]
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)
        
        if result.returncode == 0:
            log_message(f"Restore completed: {folder or 'all'} ({mode})")
            return jsonify({'success': True, 'output': result.stdout})
        else:
            log_message(f"Restore failed: {result.stderr}")
            return jsonify({'success': False, 'error': result.stderr})
            
    except Exception as e:
        log_message(f"Restore error: {str(e)}")
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/restore/pull-image', methods=['POST'])
def api_pull_image():
    """Pull a Docker image"""
    data = request.get_json()
    image = data.get('image', '')
    
    if not image:
        return jsonify({'success': False, 'error': 'No image specified'})
    
    try:
        result = subprocess.run(['docker', 'pull', image], capture_output=True, text=True, timeout=600)
        
        if result.returncode == 0:
            log_message(f"Image pulled: {image}")
            return jsonify({'success': True, 'output': result.stdout})
        else:
            return jsonify({'success': False, 'error': result.stderr})
            
    except subprocess.TimeoutExpired:
        return jsonify({'success': False, 'error': 'Pull timed out after 10 minutes'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/log')
def api_log():
    """Get recent log entries"""
    lines = request.args.get('lines', 50, type=int)
    
    if os.path.exists(LOG_FILE):
        with open(LOG_FILE, 'r') as f:
            all_lines = f.readlines()
            return jsonify({"log": all_lines[-lines:]})
    
    return jsonify({"log": []})

if __name__ == '__main__':
    log_message("Backup Unraid State Docker v2.6.0 starting...")
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)
