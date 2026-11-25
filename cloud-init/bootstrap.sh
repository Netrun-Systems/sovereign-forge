#!/usr/bin/env bash
# First-boot provisioning, run once by cloud-init as root. Idempotent: a marker
# file stops a second run. Everything it needs was written by cloud-init:
#   /etc/forge/forge.env     non-secret settings (host name, CI engine, admin email)
#   /etc/forge/backup.env    backup remote + age PUBLIC key (+ storage credentials on AWS)
#   /opt/forge/{compose,scripts}   this kit
# Secrets (database password, Forgejo secret key) are generated here, on the host,
# and never pass through Terraform state or cloud user-data.
set -Eeuo pipefail
exec > >(tee -a /var/log/forge-bootstrap.log) 2>&1

MARK=/var/lib/forge/bootstrap.done
[ ! -e "$MARK" ] || { echo "bootstrap already completed"; exit 0; }
mkdir -p /var/lib/forge
export DEBIAN_FRONTEND=noninteractive

# shellcheck source=../scripts/lib.sh
. /opt/forge/scripts/lib.sh
log INFO "bootstrap start"

# --- non-secret settings -> environment for gen-env.sh
load_env /etc/forge/forge.env

# --- swap: small instances need it as a safety margin for CI jobs
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log INFO "created 2G swapfile"
fi

# --- docker: bounded logs so a chatty container cannot fill a small disk
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "live-restore": true
}
JSON
systemctl enable --now docker
systemctl restart docker

# --- containers must not reach the cloud metadata endpoint (it can serve user-data)
systemctl daemon-reload
systemctl enable --now forge-metadata-block.service

# --- ssh: keys only, no root
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/50-forge-hardening.conf <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
MaxAuthTries 3
CONF
systemctl reload ssh || systemctl reload sshd || true

# --- host firewall. Docker publishes ports around ufw (see ARCHITECTURE.md), so
# the cloud firewall is the real perimeter; ufw guards host services such as sshd.
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow "${SSH_PUBLIC_PORT:-2222}/tcp"
ufw --force enable

# --- fail2ban for the host sshd
cat > /etc/fail2ban/jail.d/forge-sshd.local <<'CONF'
[sshd]
enabled = true
backend = systemd
maxretry = 4
findtime = 10m
bantime = 1h
CONF
systemctl enable --now fail2ban
systemctl restart fail2ban

# --- unattended security upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
systemctl enable --now unattended-upgrades

# --- compose environment (generates secrets) and the helper command
chmod +x /opt/forge/scripts/*.sh
/opt/forge/scripts/gen-env.sh --example /opt/forge/compose/.env.example --out /opt/forge/compose/.env
ln -sf /opt/forge/scripts/forge-compose.sh /usr/local/sbin/forge-compose
install -d -m 0700 /var/backups/forge

# --- bring the stack up
export FORGE_COMPOSE_DIR=/opt/forge/compose
forge-compose pull --quiet
forge-compose up -d --wait --wait-timeout 300 postgres forgejo
[ "${WITH_CADDY:-true}" != true ] || forge-compose up -d caddy

# --- first admin (random password, written to a root-only file, never to a log)
ADMIN_USER=$(env_get /opt/forge/compose/.env ADMIN_USER)
ADMIN_EMAIL=$(env_get /opt/forge/compose/.env ADMIN_EMAIL)
if ! docker exec -u git forgejo forgejo admin user list --admin 2>/dev/null | grep -qw "$ADMIN_USER"; then
  (
    umask 077
    docker exec -u git forgejo forgejo admin user create --admin \
      --username "$ADMIN_USER" --email "$ADMIN_EMAIL" --random-password > /root/forge-admin-credentials.txt
  )
  log INFO "admin user created; credentials are in /root/forge-admin-credentials.txt (root only, change on first login)"
fi

# --- CI engine
if [ "${CI_ENGINE:-forgejo}" = forgejo ]; then
  /opt/forge/scripts/register-runner.sh
else
  forge-compose up -d jenkins
  log INFO "jenkins started; first-login password: docker exec forge-jenkins cat /var/jenkins_home/secrets/initialAdminPassword"
fi

# --- backups
systemctl enable --now forge-backup.timer

# --- scrub: delete the raw user-data copies. cloud-init also keeps cloud-config.txt and obj.pkl
# (root-only, same exposure as /etc/forge/backup.env); this does not remove those.
rm -f /var/lib/cloud/instance/user-data.txt /var/lib/cloud/instance/user-data.txt.i \
      /var/lib/cloud/instances/*/user-data.txt /var/lib/cloud/instances/*/user-data.txt.i \
      /var/lib/cloud/instances/*/scripts/* 2>/dev/null || true

touch "$MARK"
log INFO "bootstrap complete"
