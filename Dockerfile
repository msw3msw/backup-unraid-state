# Backup Unraid State - Docker Edition
# A clean web interface for backing up VMs, appdata, and plugins

FROM python:3.11-slim

LABEL maintainer="Michael"
LABEL description="Backup Unraid State - VM, appdata, and plugin backups with container restore"
LABEL version="2.2.0"

# Install system dependencies including Docker CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
    cron \
    libvirt-clients \
    jq \
    tar \
    gzip \
    rsync \
    curl \
    gnupg \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Install Python dependencies
RUN pip install --no-cache-dir \
    flask \
    gunicorn

# Create app directory
WORKDIR /app

# Copy application files
COPY app/ /app/

# Make scripts executable
RUN chmod +x /app/backup.sh \
    && chmod +x /app/scheduled_backup.py

# Create directories
RUN mkdir -p /config /backup

# Create startup script
RUN echo '#!/bin/bash\n\
\n\
# Start cron daemon\n\
service cron start\n\
\n\
# Start web application\n\
exec gunicorn --bind 0.0.0.0:5000 --workers 2 --threads 4 app:app\n\
' > /app/start.sh && chmod +x /app/start.sh

# Expose web interface port
EXPOSE 5000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:5000/ || exit 1

# Volume mounts
VOLUME ["/config", "/backup", "/domains", "/appdata", "/plugins", "/boot"]

# Start the application
CMD ["/app/start.sh"]
