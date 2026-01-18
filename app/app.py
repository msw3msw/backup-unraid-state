#!/usr/bin/env python3
"""
Backup Unraid State - Docker Edition v2.0
A clean web interface for backing up VMs, appdata, and plugins
With real-time progress via Server-Sent Events (SSE)
"""

from flask import Flask, render_template, request, jsonify, Response
import subprocess
import os
import json
import threading
import time
import queue
from datetime import datetime, timedelta
from pathlib import Path

app = Flask(__name__)

# Configuration
CONFIG_FILE = "/config/settings.json"
LOG_FILE = "/config/backup.log"
SCHEDULE_FILE = "/config/schedule.json"
STATS_FILE = "/config/stats.json"

# Progress tracking - thread-safe state for each backup type
progress_state = {
    'vm': {'active': False, 'percent': 0, 'phase': '', 'eta': '', 'error': None, 'complete': False},
    'appdata': {'active': False, 'percent': 0, 'phase': '', 'eta': '', 'error': None, 'complete': False},
    'plugins': {'active': False, 'percent': 0, 'phase': '', 'eta': '', 'error': None, 'complete': False},
    'flash': {'active': False, 'percent': 0, 'phase': '', 'eta': '', 'error': None, 'complete': False}
}
progress_lock = threading.Lock()

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
            'complete': False
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
        "incremental_enabled": False
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
    
    if backup_type == "vm":
        stats["last_vm_backup"] = now
    elif backup_type == "appdata":
        stats["last_appdata_backup"] = now
    elif backup_type == "plugins":
        stats["last_plugins_backup"] = now
    elif backup_type == "flash":
        stats["last_flash_backup"] = now
    
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
    """Get list of existing backups"""
    config = load_config()
    backup_path = config.get("backup_destination", "/backup")
    
    backups = {"vms": [], "appdata": [], "plugins": [], "flash": []}
    
    def scan_dir(path, limit=5):
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
                        "date": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M")
                    })
                except:
                    pass
        except:
            pass
        return results
    
    try:
        backups["vms"] = scan_dir(os.path.join(backup_path, "vms"))
        backups["appdata"] = scan_dir(os.path.join(backup_path, "appdata"))
        backups["plugins"] = scan_dir(os.path.join(backup_path, "plugins"))
        backups["flash"] = scan_dir(os.path.join(backup_path, "flash"))
    except Exception as e:
        log_message(f"Error scanning backups: {e}")
    
    return backups

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
                # Regular log line
                log_message(line)
                update_progress(backup_type, log_line=line)
        
        process.wait()
        
        elapsed = time.time() - start_time
        elapsed_str = f"{int(elapsed // 60)}m {int(elapsed % 60)}s"
        
        if process.returncode == 0:
            log_message(f"Backup completed successfully: {backup_type} in {elapsed_str}")
            update_progress(backup_type, percent=100, phase="Complete", eta="", complete=True, log_line=f"Completed in {elapsed_str}")
            update_stats(backup_type, success=True)
            return True
        else:
            log_message(f"Backup failed with code {process.returncode}")
            update_progress(backup_type, error=f"Failed (code {process.returncode})", complete=True, log_line=f"Failed with code {process.returncode}")
            update_stats(backup_type, success=False)
            return False
            
    except Exception as e:
        log_message(f"Backup error: {e}")
        update_progress(backup_type, error=str(e), complete=True, log_line=f"Error: {e}")
        update_stats(backup_type, success=False)
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

@app.route('/api/restore/appdata', methods=['POST'])
def api_restore_appdata():
    """Start appdata restore"""
    data = request.json
    backup_file = data.get('backup_file')
    
    if not backup_file:
        return jsonify({"success": False, "error": "No backup file specified"})
    
    run_restore_async("appdata", backup_file)
    
    return jsonify({"success": True, "message": f"Appdata restore started from: {backup_file}"})

@app.route('/api/restore/plugins', methods=['POST'])
def api_restore_plugins():
    """Start plugins restore"""
    data = request.json
    backup_file = data.get('backup_file')
    
    if not backup_file:
        return jsonify({"success": False, "error": "No backup file specified"})
    
    run_restore_async("plugins", backup_file)
    
    return jsonify({"success": True, "message": f"Plugins restore started from: {backup_file}"})

@app.route('/api/stats')
def api_stats():
    """Get dashboard statistics"""
    stats = load_stats()
    stats["next_scheduled"] = get_next_scheduled_run()
    stats["total_backup_size_formatted"] = format_size(stats.get("total_backup_size", 0))
    return jsonify(stats)

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

if __name__ == '__main__':
    log_message("Backup Unraid State Docker starting...")
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)
