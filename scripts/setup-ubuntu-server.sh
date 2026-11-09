#!/usr/bin/env bash
# setup-ubuntu-server.sh — one-shot preparation for an Ubuntu Server 26.04 LTS
# (or Debian 13) box that will host a Forge 1.20.1 server with Villager Recruits
# and Villager Workers for ~30 players.
#
# Usage:  sudo ./setup-ubuntu-server.sh
# Idempotent: safe to re-run. Only third-party repo used is Adoptium (Temurin 21).
set -euo pipefail

MC_USER="minecraft"
MC_DIR="/opt/minecraft"
WORLD_DISK="/mnt/world"
BACKUP_DISK="/mnt/backups"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo)"

# ---------------------------------------------------------------- base packages
log "Installing base packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl wget gnupg ca-certificates lsb-release apt-transport-https zstd \
  ufw fail2ban unattended-upgrades chrony rsync htop iotop tmux \
  smartmontools nvme-cli lm-sensors nut-client prometheus-node-exporter

# ------------------------------------------------------------------- Java 21
log "Installing Eclipse Temurin 21 (JRE)"
install -d -m 0755 /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/adoptium.gpg ]]; then
  wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
fi
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${CODENAME} main" \
  > /etc/apt/sources.list.d/adoptium.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y temurin-21-jre
java -version 2>&1 | head -1

# ------------------------------------------------------------------- user/dirs
log "Creating service user and directories"
id -u "$MC_USER" >/dev/null 2>&1 || useradd -r -m -d "$MC_DIR" -s /usr/sbin/nologin "$MC_USER"
install -d -o "$MC_USER" -g "$MC_USER" "$MC_DIR" "$MC_DIR/logs" "$MC_DIR/scripts" "$MC_DIR/backups"

# RCON password file used by scripts/rcon.py and systemd ExecStop (0600, service user).
# Generate once; keep it identical to rcon.password in server.properties.
if [[ ! -f "$MC_DIR/rcon.password" ]]; then
  head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$MC_DIR/rcon.password"
  chown "$MC_USER:$MC_USER" "$MC_DIR/rcon.password"
  chmod 600 "$MC_DIR/rcon.password"
  log "Generated RCON password in $MC_DIR/rcon.password - put the same value in server.properties"
fi

if [[ -d "$WORLD_DISK" ]]; then
  log "Linking world storage at $WORLD_DISK/world"
  install -d -o "$MC_USER" -g "$MC_USER" "$WORLD_DISK/world"
  [[ -e "$MC_DIR/world" ]] || ln -s "$WORLD_DISK/world" "$MC_DIR/world"
  chown -h "$MC_USER:$MC_USER" "$MC_DIR/world" 2>/dev/null || true
fi
if [[ -d "$BACKUP_DISK" ]]; then
  install -d -o "$MC_USER" -g "$MC_USER" "$BACKUP_DISK/minecraft"
fi

# ------------------------------------------------------------------ CPU tuning
log "CPU governor -> performance"
cat > /etc/systemd/system/cpu-performance.service <<'UNIT'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'command -v cpupower >/dev/null && cpupower frequency-set -g performance || true'

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now cpu-performance.service

# ------------------------------------------------------------------ sysctl
log "Applying sysctl tuning"
cat > /etc/sysctl.d/99-minecraft.conf <<'SYSCTL'
# Keep the JVM heap in RAM; swap is emergency-only insurance.
vm.swappiness = 10
# 30 players x chunk packets: default socket buffers are too small.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
SYSCTL
sysctl --system >/dev/null

cat > /etc/systemd/system/thp-madvise.service <<'UNIT'
[Unit]
Description=Set transparent hugepages to madvise
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled'

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now thp-madvise.service

# ------------------------------------------------------------------ limits
log "Raising file limits for the service user"
cat > /etc/security/limits.d/99-minecraft.conf <<'LIMITS'
minecraft soft nofile 65535
minecraft hard nofile 65535
minecraft soft nproc  65535
minecraft hard nproc  65535
LIMITS

# ------------------------------------------------------------------ firewall
log "Configuring ufw"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'ssh'
ufw allow 25565/tcp comment 'minecraft'
ufw --force enable
ufw status verbose

# ------------------------------------------------------------------ updates
log "Enabling security-only unattended upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UPG'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
UPG

# ------------------------------------------------------------------ swap
log "Creating 8 GB swapfile as GC-spike insurance"
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 8G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ------------------------------------------------------------------ logrotate
log "Adding logrotate rule for the console log"
cat > /etc/logrotate.d/minecraft <<'LOGROTATE'
/opt/minecraft/logs/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su minecraft minecraft
}
LOGROTATE

log "Done. Next steps:"
cat <<'NEXT'

  1. Copy the Forge server files to /opt/minecraft, then:
       chown -R minecraft:minecraft /opt/minecraft
  2. Copy the scripts and set the RCON password:
       install -o minecraft -g minecraft -m 750 -d /opt/minecraft/scripts
       cp scripts/{backup-world.sh,rotate-backups.py,rcon.py} /opt/minecraft/scripts/
       chmod 750 /opt/minecraft/scripts/*.sh /opt/minecraft/scripts/*.py
       cat /opt/minecraft/rcon.password          # put this in rcon.password= in server.properties
  3. Install the unit:
       cp systemd/minecraft.service /etc/systemd/system/
       systemctl daemon-reload && systemctl enable --now minecraft
  4. Accept the EULA (before first start):
       echo 'eula=true' > /opt/minecraft/eula.txt
  5. Schedule backups (README.md section 10):
       crontab -u minecraft -e   ->   */30 * * * * /opt/minecraft/scripts/backup-world.sh
  6. Configure NUT for the UPS (README.md section 10).
  7. Pre-generate the map before opening it to players:
       tmux new -s pregen
       cd /opt/minecraft && java -jar forge-1.20.1-47.4.0-shim.jar --nogui
       # in the server console:  chunky radius 5000   then   chunky start
NEXT
