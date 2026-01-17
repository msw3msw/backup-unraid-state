# Backup Unraid State - Docker Edition

A clean web interface for backing up VMs, appdata, plugins, and flash drive configurations.

## Quick Start

```bash
# Remove old container and image
docker stop backup-unraid-state
docker rm backup-unraid-state
docker rmi backup-unraid-state

# Remove old appdata folder
rm -rf /mnt/user/appdata/backup-unraid-state-docker

# Extract this zip to appdata
unzip backup-unraid-state-docker.zip -d /mnt/user/appdata/

# Build and run (no cache)
cd /mnt/user/appdata/backup-unraid-state-docker
docker-compose build --no-cache
docker-compose up -d
```

## What's Fixed

### v1.4 - UI Polish
- **Symmetrical cards** - All backup cards now have equal height
- **Green pulse animation** - Active backup card pulses green to show it's running
- **Elapsed time counter** - Shows how long the current backup has been running

### v1.3 - Fully Async Page Load
- **Problem**: Page still slow because `get_vms()` and `get_appdata_folders()` were blocking page render
- **Solution**: Everything now loads via AJAX - page renders instantly, then VMs, folders, and backups load in background

### v1.2 - VM Path Translation Fix
- **Problem**: VM backups failed with "No such file or directory" - virsh returns host paths (`/mnt/user/domains/...`) but container sees `/domains`
- **Solution**: Script now translates host paths to container paths before backup, and validates disk exists

### v1.1 - Fast Page Load
- **Problem**: Page took 1-2 minutes to load due to network mount scanning
- **Solution**: Backup list now loads asynchronously via JavaScript AFTER page renders

## Features

- **VM Backups**: Full VM disk images with optional compression
- **Appdata Backups**: All Docker container data with smart exclusions
- **Plugin Backups**: Plugin configurations from /boot/config/plugins
- **Flash Backups**: Complete USB drive backup for disaster recovery
- **Scheduling**: Automated backups with cron
- **Live Activity**: Real-time log streaming via Server-Sent Events

## Volume Mappings

| Container Path | Host Path | Purpose |
|---------------|-----------|---------|
| /config | /mnt/user/appdata/backup-unraid-state | Config & logs |
| /backup | Your backup destination | Backup storage |
| /domains | /mnt/user/domains | VM storage |
| /appdata | /mnt/user/appdata | Docker data |
| /plugins | /boot/config/plugins | Plugin configs |
| /boot | /boot | Flash drive |

## Web Interface

Access at: `http://your-server-ip:5050`

## License

MIT License
