# Backup Unraid State

A modern, clean web interface for backing up your Unraid server's critical data including VMs, Docker appdata, plugin configurations, and USB flash drive for disaster recovery.

![Docker Pulls](https://img.shields.io/docker/pulls/msw3msw/backup-unraid-state) ![GitHub](https://img.shields.io/github/license/msw3msw/backup-unraid-state)

## Features

### Backup Types

- **VM Backups** - Full virtual machine disk images with stop or live backup options, automatic compression
- **Appdata Backups** - All Docker container data with smart exclusions (cache, logs, temp files) or selective folder backup
- **Plugin Backups** - Complete plugin configurations from /boot/config/plugins
- **Flash Drive Backups** - Critical disaster recovery backup including array config, network settings, user accounts, shares, SSL certs, Docker templates, and license key

### Real-Time Progress Tracking

- **Folder-by-folder progress** - See exactly which folder is being backed up: `plex (5/27)`
- **Elapsed time** - All backups show running time: `plex (5/27) • 2m 30s`
- **Progress bars** - Visual progress indicator on each backup card
- **Card-scoped logs** - Each backup card has its own activity log (no context switching)
- **Server-Sent Events (SSE)** - Live updates without polling

### Scheduling & Automation

- Flexible scheduling (daily/weekly/monthly)
- Choose specific days of the week
- Automatic backup rotation (configurable retention)
- Cron-based reliability

### Smart Features

- Week/day/month-based naming schemes (week01, day3_week15, January_2025)
- Automatic old backup cleanup
- Intelligent exclusions for cache, logs, and temp files
- Backup verification after creation
- VM path translation for Docker container compatibility
- **Container metadata saving** - images, ports, volumes saved during backup

### Container Restore (v2.2)

During appdata backup, container metadata is automatically saved:
- Docker image name (e.g., `lscr.io/linuxserver/plex:latest`)
- Container configuration (ports, volumes, environment)
- Unraid templates (copied to backup)

**Restore options when clicking Restore on appdata backup:**
1. **Restore appdata only** - Just extract the backup files
2. **Restore appdata + pull all images** - Extract backup AND pull all container images from saved metadata (for disaster recovery)

**Individual container restore** (when metadata exists):
- 📁 Restore appdata only for specific container
- ☁️ Pull image + restore appdata
- ⬇️ Pull image only

### Docker Template (XML) Management

In the **Settings** tab, manage your Docker container templates:
- View all templates on your flash drive
- See which templates have active containers (green) vs orphaned (orange)
- Delete orphaned XMLs from removed containers to keep flash drive clean

### Incremental Backups (Appdata)

When enabled in Settings, appdata backups use **rsync with hardlinks**:

- Each backup is a **complete, standalone folder**
- Unchanged files are hardlinked to previous backup (share disk space)
- **Easy restore** - just copy any snapshot folder, no chain to reconstruct
- **Storage efficient** - only changed files use additional space
- **Safe** - deleting old backups doesn't affect newer ones

```
/backup/appdata/snapshots/
├── 2025-01-15_0300/   ← Complete (50GB apparent, 50GB actual)
├── 2025-01-16_0300/   ← Complete (50GB apparent, 2GB actual - hardlinks!)
└── 2025-01-17_0300/   ← Complete (50GB apparent, 1GB actual)

Total: 53GB actual disk usage for 3 complete backups
```

### Web Interface

- Clean, modern dark theme matching Unraid's style
- 2x2 card grid layout for all backup types
- Green border/glow animation on active backups
- Instant page loading (fully async)
- Mobile responsive design

---

## Installation

### Option 1: Unraid Template (Easiest)

**One-time setup to add the template:**

1. Open Unraid terminal (or SSH)
2. Run this command to download the template:
   ```bash
   wget -O /boot/config/plugins/dockerMan/templates-user/my-BackupUnraidState.xml \
     https://raw.githubusercontent.com/msw3msw/backup-unraid-state/main/unraid-template.xml
   ```
3. Go to **Docker → Add Container**
4. Select **BackupUnraidState** from the Template dropdown
5. Set your **Backup Destination** path (REQUIRED - use a remote/NAS share!)
6. Adjust timezone if needed
7. Click **Apply**
8. Access web UI at: `http://[YOUR-UNRAID-IP]:5050`

**Or manually download:**
1. Download [unraid-template.xml](https://raw.githubusercontent.com/msw3msw/backup-unraid-state/main/unraid-template.xml)
2. Copy to: `/boot/config/plugins/dockerMan/templates-user/my-BackupUnraidState.xml`
3. Go to Docker → Add Container and select from Template dropdown

---

### Option 2: Docker Compose

```yaml
version: '3.8'

services:
  backup-unraid-state:
    image: msw3msw/backup-unraid-state:latest
    container_name: backup-unraid-state
    privileged: true
    ports:
      - "5050:5000"
    volumes:
      - /mnt/user/appdata/backup-unraid-state:/config
      - /mnt/remotes/YOUR_NAS/backups:/backup    # CHANGE THIS!
      - /mnt/user/domains:/domains:ro
      - /mnt/user/appdata:/appdata:ro
      - /boot/config/plugins:/plugins:ro
      - /boot:/boot:ro
      - /var/run/libvirt/libvirt-sock:/var/run/libvirt/libvirt-sock
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - TZ=America/New_York
      - MAX_BACKUPS=2
    restart: unless-stopped
```

---

### Option 3: Unraid Docker UI (Manual)

1. Go to **Docker → Add Container**
2. Set **Repository**: `msw3msw/backup-unraid-state:latest`
3. Set **Privileged**: `ON`
4. Add port: `5050` → `5000/tcp`
5. Add all volume mappings (see table below)
6. Click **Apply**

---

## Volume Mappings

| Container Path | Host Path | Mode | Description |
|----------------|-----------|------|-------------|
| `/config` | `/mnt/user/appdata/backup-unraid-state` | RW | Config & logs |
| `/backup` | **Your backup destination** | RW | Where backups are stored |
| `/domains` | `/mnt/user/domains` | RO | VM disk images |
| `/appdata` | `/mnt/user/appdata` | RO | Docker container data |
| `/plugins` | `/boot/config/plugins` | RO | Plugin configs |
| `/boot` | `/boot` | RW | USB flash drive (RW for XML management) |
| `/var/run/libvirt/libvirt-sock` | `/var/run/libvirt/libvirt-sock` | RW | VM control socket |
| `/var/run/docker.sock` | `/var/run/docker.sock` | RW | Container management & metadata |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `America/New_York` | Your timezone for scheduled backups |
| `MAX_BACKUPS` | `2` | Number of backup copies to keep per item |

---

## Important Notes

⚠️ **Backup Destination**: Use a remote/NAS share or separate disk - NOT the same array you're backing up!

⚠️ **Privileged Mode**: Required for VM control and accessing system paths

⚠️ **Docker Socket**: Required for container metadata collection and image pulling

💾 **Disaster Recovery**: Flash backups contain everything needed to rebuild your Unraid configuration on a new USB drive:
- Array configuration (disk assignments, parity)
- Network settings
- User accounts & passwords
- Share definitions
- Docker container templates (XMLs)
- VM settings
- SSL certificates
- License key

---

## Screenshots

### Backup Now Tab
- 2x2 grid of backup cards (VM, Appdata, Plugins, Flash)
- Each card shows: controls, progress bar, activity log
- Real-time progress on buttons during backup

### Progress Example
```
Button: [⏳ plex (5/27) • 2m 30s]
Progress: ████████████░░░░░░░░ 58%
Log:
  [14/27] Backing up: radarr
  [15/27] Backing up: sonarr
  [16/27] Backing up: plex
```

### Restore Tab
- Container Restore section (when metadata exists)
- Individual restore buttons for each container
- Full backup restore with modal options

### Settings Tab
- General settings (max backups, naming scheme)
- Backup behaviour (compression, verify, incremental)
- Exclude folders
- Docker Templates (XML) management

---

## Restore Instructions

### VM Restore
1. Extract the `.tar.gz` backup
2. Copy the vdisk image to `/mnt/user/domains/[VM_NAME]/`
3. Import the VM XML from the metadata file

### Appdata Restore

**From Web UI (recommended):**
1. Go to Restore tab
2. Click Restore on your appdata backup
3. Choose: "Restore appdata only" or "Restore appdata + pull all images"
4. Click Restore

**Manual - Full backup (tar):**
1. Stop the Docker container
2. Extract: `tar -xzf appdata_FULL_week03.tar.gz -C /mnt/user/appdata/`
3. Start the container

**Manual - Incremental backup (rsync snapshots):**
1. Stop the Docker container
2. Copy: `cp -a /backup/appdata/snapshots/2025-01-17_0300/* /mnt/user/appdata/`
3. Start the container

(Each snapshot is complete - no need to restore a chain!)

### Flash Drive Restore (Disaster Recovery)
1. Create a new Unraid USB using the USB Creator tool
2. Mount the USB on a computer
3. Extract the flash backup to the USB `/boot` directory
4. If USB GUID changed, reactivate your license at unraid.net
5. Boot from the new USB - your array configuration should be intact

---

## Changelog

### v2.2
- **Container restore modal** - Choose "appdata only" or "appdata + pull all images" when restoring
- **Container metadata** - Saves image names, config during appdata backup
- **Image pulling** - Pull images directly from Restore tab
- **Docker XML management** - View/delete orphaned templates in Settings tab
- **Brighter text** - Improved visibility for dates and sizes
- **Docker socket support** - Container management from within the app

### v2.1
- **Incremental backups redesigned** - Now uses rsync + hardlinks (each backup is complete, standalone)
- **Elapsed time display** - All backups show elapsed time with current folder: `plex (5/27) • 2m 30s`
- **Tooltip on incremental** - Hover info explaining how incremental works
- **Fixed schedule display** - "Next Scheduled" now updates after saving

### v2.0
- **Real-time folder progress** - See which folder is being backed up
- **Progress bars** - Visual progress on each backup card
- **Card-scoped logs** - Each backup type has its own log panel
- **SSE streaming** - Live updates via Server-Sent Events
- **Unraid template** - Easy one-command installation

### v1.x
- Initial releases with core backup functionality

---

## License

MIT License - See LICENSE file for details

## Contributing

Issues and pull requests welcome at [GitHub](https://github.com/msw3msw/backup-unraid-state)
