# Backup Unraid State - Docker Edition

A modern, clean web interface for backing up your Unraid server's critical data including VMs, Docker appdata, plugin configurations, and USB flash drive for disaster recovery.

![Docker Pulls](https://img.shields.io/docker/pulls/msw3msw/backup-unraid-state)
![GitHub](https://img.shields.io/github/license/msw3msw/backup-unraid-state)

## Features

### Backup Types
- **VM Backups** - Full virtual machine disk images with stop or live backup options, automatic compression
- **Appdata Backups** - All Docker container data with smart exclusions (cache, logs, temp files) or selective folder backup
- **Plugin Backups** - Complete plugin configurations from /boot/config/plugins
- **Flash Drive Backups** - Critical disaster recovery backup including array config, network settings, user accounts, shares, SSL certs, and license key

### Scheduling & Automation
- Flexible scheduling (daily/weekly/monthly)
- Choose specific days of the week
- Automatic backup rotation (configurable retention)
- Cron-based reliability

### Web Interface
- Clean, modern dark theme matching Unraid's style
- Real-time backup progress with elapsed time counter
- Live activity log with Server-Sent Events
- Green pulse animation on active backups
- Instant page loading (fully async)

### Smart Features
- Week/day/month-based naming schemes (week01, day3_week15, January_2025)
- Automatic old backup cleanup
- Intelligent exclusions for cache, logs, and temp files
- Detailed restore instructions generated with flash backups
- VM path translation for Docker container compatibility

## Installation

### Option 1: Unraid Docker UI

1. In Unraid, go to **Docker** → **Add Container**
2. Set **Repository** to: `msw3msw/backup-unraid-state:latest`
3. Set **Privileged** to: `ON`
4. Add the port mapping: Container Port `5000` → Host Port `5050`
5. Add the volume mappings (see below)
6. Click **Apply**
7. Access web UI at: `http://[YOUR-UNRAID-IP]:5050`

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
      - /mnt/remotes/YOUR_NAS/backups:/backup
      - /mnt/user/domains:/domains:ro
      - /mnt/user/appdata:/appdata:ro
      - /boot/config/plugins:/plugins:ro
      - /boot:/boot:ro
      - /var/run/libvirt/libvirt-sock:/var/run/libvirt/libvirt-sock
    environment:
      - TZ=America/New_York
      - MAX_BACKUPS=2
    restart: unless-stopped
```

## Volume Mappings

| Container Path | Host Path | Mode | Description |
|----------------|-----------|------|-------------|
| /config | /mnt/user/appdata/backup-unraid-state | RW | Config & logs |
| /backup | Your backup destination | RW | Where backups are stored |
| /domains | /mnt/user/domains | RO | VM disk images |
| /appdata | /mnt/user/appdata | RO | Docker container data |
| /plugins | /boot/config/plugins | RO | Plugin configs |
| /boot | /boot | RO | USB flash drive |
| /var/run/libvirt/libvirt-sock | /var/run/libvirt/libvirt-sock | RW | VM control socket |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| TZ | America/New_York | Your timezone for scheduled backups |
| MAX_BACKUPS | 2 | Number of backup copies to keep per item |

## Important Notes

⚠️ **Backup Destination**: Use a remote/NAS share or separate disk - NOT the same array you're backing up!

⚠️ **Privileged Mode**: Required for VM control and accessing system paths

💾 **Disaster Recovery**: Flash backups contain everything needed to rebuild your Unraid configuration on a new USB drive:
- Array configuration (disk assignments, parity)
- Network settings
- User accounts & passwords
- Share definitions
- Docker & VM settings
- SSL certificates
- License key

## Restore Instructions

### VM Restore
1. Extract the .tar.gz backup
2. Copy the vdisk image to /mnt/user/domains/[VM_NAME]/
3. Import the VM XML from the metadata file

### Appdata Restore
1. Stop the Docker container
2. Extract the backup to /mnt/user/appdata/
3. Start the container

### Flash Drive Restore (Disaster Recovery)
1. Create a new Unraid USB using the USB Creator tool
2. Mount the USB on a computer
3. Extract the flash backup to the USB /boot directory
4. If USB GUID changed, reactivate your license at unraid.net
5. Boot from the new USB - your array configuration should be intact

## Changelog

### v1.4
- UI polish: symmetrical cards, green pulse animation on active backups
- Elapsed time counter during backups

### v1.3
- Fully async page loading - instant page render

### v1.2
- VM path translation fix for Docker container compatibility

### v1.1
- Async backup list loading - no more slow page loads

### v1.0
- Initial release

## License

MIT License

## Support

- [GitHub Issues](https://github.com/msw3msw/backup-unraid-state/issues)
- [Docker Hub](https://hub.docker.com/r/msw3msw/backup-unraid-state)
