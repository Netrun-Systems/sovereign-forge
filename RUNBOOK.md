# Runbook

Day-2 operations. Commands assume a cloud host reached with `ssh` as the default user (`ubuntu` on AWS, `azureuser` on Azure) and `sudo`. Replace `[PLACEHOLDER]` values with your own; never paste real secrets into tickets or chat.

Handy on the host:

```bash
sudo forge-compose ps                      # the stack (wrapper installed by bootstrap)
sudo forge-compose logs -f forgejo
sudo journalctl -u forge-backup.service -n 50 --no-pager
systemctl list-timers forge-backup.timer
sudo /opt/forge/scripts/backup.sh          # run a backup now (or: systemctl start forge-backup.service)
```

From your machine: `scripts/verify.sh --host [FORGE_HOST] --ssh [USER]@[PUBLIC_IP]`.

## Routine

| Cadence | Task |
|---|---|
| Daily, automatic | Backup at 03:30 UTC (plus up to 10 minutes of jitter) |
| Weekly | `verify.sh`; confirm `last-success` is recent; glance at `df -h` and `free -m` (swap use is the early warning on a 2 GB host) |
| Monthly | **Restore drill** (below) |
| Monthly, and on any Forgejo security advisory | **Upgrade** check |
| Quarterly | Full restore onto a scratch machine; rotate the personal access tokens CI uses; review who has admin |
| Every 90 days | Rotate the AWS backup key if you use one |

## Upgrade

Images are pinned by tag **and** digest in `/opt/forge/compose/docker-compose.*.yml`. Nothing upgrades itself except the operating system.

**1. Back up first, and make sure it worked.**

```bash
sudo systemctl start forge-backup.service
sudo journalctl -u forge-backup.service -n 20 --no-pager     # must end with "backup OK"
```

**2. Read the release notes** for every version between yours and the target. Forgejo runs database migrations on start; they are forward-only, so the way back from a bad upgrade is a restore, not a downgrade.

**3. Resolve the new digest** (this queries the registry, it does not pull layers):

```bash
docker buildx imagetools inspect codeberg.org/forgejo/forgejo:[NEW_VERSION] --format '{{.Manifest.Digest}}'
```

**4. Edit the compose file** so the line reads `image: <name>:<new tag>@sha256:<new digest>`, then:

```bash
sudo forge-compose pull
sudo forge-compose up -d
sudo forge-compose ps
# then, from your machine:  scripts/verify.sh --host [FORGE_HOST] --ssh [USER]@[PUBLIC_IP]
```

What to know per component:

| Component | Note |
|---|---|
| Forgejo | Read the notes for each major. Do not skip majors without reading them. Take the backup first. |
| PostgreSQL | A minor or patch bump of `16.x-alpine` is a plain image swap. A **major** version (16 to 17) needs a dump and restore into a fresh volume: stop Forgejo, `pg_dump`, bring up the new major on an empty volume, restore, start Forgejo. Rehearse it on a scratch machine. |
| Caddy | Image swap. Certificates live in the `caddy-data` volume and survive. |
| Runner | Image swap. Keep it within the version range your Forgejo release documents as compatible. |
| Docker-in-Docker | Image swap. Job images cached inside it are lost, so the next jobs pull again. |
| Jenkins | Use the LTS line. Read the security advisories; update plugins from the UI, and expect plugin updates to be most of the work. |
| Operating system | `unattended-upgrades` applies security updates. Reboot when `/var/run/reboot-required` exists (`sudo reboot`; containers restart themselves). |

**Rollback.** If the new version fails before it migrated anything, put the old line back and `up -d`. If it migrated the database, restore the backup you took in step 1 ([Full restore](#full-restore)).

**Updating the kit's own files** (compose, scripts, units) on a running host is manual. cloud-init runs once. Copy the changed files to `/opt/forge` and run `sudo systemctl daemon-reload` if a unit changed.

## Rotate

| Secret | How |
|---|---|
| **Backup encryption key (age)** | `age-keygen -o new-identity.txt`. Put the new `age1...` public key in `AGE_RECIPIENT` in `/etc/forge/backup.env`. Run a backup. Keep the **old** identity until every backup encrypted to it has expired or been re-encrypted: `age -d -i old-identity.txt f.age \| age -r [NEW_PUBLIC_KEY] -o f.new.age`. Never delete the only identity that can open a backup you still need. |
| **AWS backup access key** | `terraform -chdir=terraform/aws apply -replace=aws_iam_access_key.backup`. Then on the host edit `RCLONE_CONFIG_FORGE_ACCESS_KEY_ID` and `..._SECRET_ACCESS_KEY` in `/etc/forge/backup.env` using `terraform output -raw backup_access_key_id` and `backup_secret_access_key`. Run `sudo systemctl start forge-backup.service` to prove it. The old key is already revoked by the replace. |
| **Azure backup identity** | Nothing to rotate: the VM's managed identity has no secret. |
| **Forgejo admin password** | In the UI. Then `sudo shred -u /root/forge-admin-credentials.txt`. |
| **Personal access tokens, deploy keys** | In the UI. Rotate any token that a CI job or mirror uses on a schedule. |
| **PostgreSQL password** | `sudo forge-compose exec postgres psql -U [DB_USER] -c "ALTER USER [DB_USER] PASSWORD '[NEW]'"`, edit `POSTGRES_PASSWORD` in `/opt/forge/compose/.env`, then `sudo forge-compose up -d forgejo`. |
| **Forgejo `SECRET_KEY`** | Do not rotate casually: it protects stored secrets and 2FA seeds, and changing it invalidates them. Rotate only after a suspected compromise, expect users to re-enrol 2FA, and re-enter CI secrets. |
| **Runner registration** | `sudo rm /opt/forge/data/runner/.runner`, delete the old runner in the forge's admin UI, `sudo /opt/forge/scripts/register-runner.sh`. |
| **Git host keys** | They live in the `forgejo-data` volume (`/data/ssh`) and are restored with the backup, so a restored forge keeps the same host key and clients see no warning. |
| **TLS certificates** | Automatic (Caddy). |
| **Your SSH key to the host** | Replace the line in `~/.ssh/authorized_keys`, and update the cloud key pair. |

## Restore drill

The point is to prove, on a schedule, that the person who holds the age identity can turn the stored objects back into repositories. Run it from a machine that has `age` and `rclone`, **not** from the forge host.

1. Create `backup.env` on your machine with `BACKUP_REMOTE` and `RCLONE_CONFIG_FORGE_*` (read access is enough):

   ```
   BACKUP_REMOTE=[forge:BUCKET_OR_CONTAINER]
   RCLONE_CONFIG_FORGE_TYPE=s3
   RCLONE_CONFIG_FORGE_PROVIDER=AWS
   RCLONE_CONFIG_FORGE_REGION=[REGION]
   RCLONE_CONFIG_FORGE_ACCESS_KEY_ID=[READ_ONLY_KEY_ID]
   RCLONE_CONFIG_FORGE_SECRET_ACCESS_KEY=[READ_ONLY_SECRET]
   RCLONE_CONFIG_FORGE_NO_CHECK_BUCKET=true
   ```

   For Azure use `RCLONE_CONFIG_FORGE_TYPE=azureblob`, `..._ACCOUNT=[STORAGE_ACCOUNT]` and `..._KEY=[ACCOUNT_KEY]` (or a SAS URL) from your own login, since the VM's managed identity is not available off the VM. Keep this file out of git (it is in `.gitignore`).

2. Run it:

   ```bash
   make restore-drill AGE_IDENTITY=./identity.txt BACKUP_ENV=./backup.env            # latest daily
   make restore-drill AGE_IDENTITY=./identity.txt BACKUP_ENV=./backup.env DRILL_TIER=weekly
   ```

3. **A pass means**: both objects downloaded, their SHA-256 sidecars matched, the data object decrypted to a valid tar, the tar contained at least one repository (the script prints the count and, with `--list`, every `owner/repo`), and the database dump decrypted and contains the `repository` table. **Compare the repository count with what the forge says it has.** A passing drill with a count that is lower than expected is a failure.

4. A pass does **not** prove the data restores into a running Forgejo, which is why the quarterly full restore exists.

Archived weekly objects: on Azure, blobs in the Archive tier must be rehydrated (hours) before they can be read. Drill against `daily/` or a recent `weekly/`.

## Full restore

Use this for disaster recovery, for moving to another cloud, and for the quarterly rehearsal. Expect to need the age identity on the new host for a few minutes; delete it afterwards.

1. **Provision a fresh forge** with `make aws` (or `azure`). It comes up empty and healthy with a new admin. Use the same `forge_host`, and point the A record at the new IP when you are ready to cut over.

2. **Fetch the backup** onto the new host (or any machine with a fast link to it), choosing a date, e.g. `20261123`:

   ```bash
   sudo bash -c 'set -a; . /etc/forge/backup.env; set +a
     rclone copyto "$BACKUP_REMOTE/daily/forge-data-[YYYYMMDD].tar.age" /var/backups/forge/restore-data.age
     rclone copyto "$BACKUP_REMOTE/daily/forge-db-[YYYYMMDD].sql.gz.age" /var/backups/forge/restore-db.age'
   ```

3. **Stop Forgejo** (leave PostgreSQL running) and copy your identity over temporarily (`scp identity.txt [USER]@[HOST]:/tmp/identity.txt`).

   ```bash
   sudo forge-compose stop forgejo
   ```

4. **Restore the data** into the Forgejo volume, preserving ownership:

   ```bash
   sudo age -d -i /tmp/identity.txt /var/backups/forge/restore-data.age \
     | sudo docker run --rm -i -v forge_forgejo-data:/data alpine:3.20 tar -xf - -C /data
   ```

5. **Restore the database.** The dump was taken with `--clean --if-exists`, so it replaces the empty schema:

   ```bash
   sudo age -d -i /tmp/identity.txt /var/backups/forge/restore-db.age | gunzip \
     | sudo docker exec -i forge-db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
   ```

6. **Remove the identity and the downloaded ciphertext**, then start Forgejo and rebuild what the restore does not carry:

   ```bash
   sudo shred -u /tmp/identity.txt /var/backups/forge/restore-*.age
   sudo forge-compose up -d forgejo
   sudo docker exec -u git forgejo forgejo admin regenerate hooks
   sudo docker exec -u git forgejo forgejo admin regenerate keys
   ```

7. **Runner:** the restored database still lists the old runner. Delete it in the admin UI, then `sudo rm /opt/forge/data/runner/.runner && sudo /opt/forge/scripts/register-runner.sh`.

8. **Verify:** `scripts/verify.sh --host [FORGE_HOST] --ssh [USER]@[HOST]`, sign in, clone a repository over SSH and HTTPS, push a commit, run a workflow.

Record how long it took. That number is your real recovery time objective.

## Incidents

First move in every incident: write down the time and what you saw, before you change anything.

### The forge is unreachable

1. From your machine: `scripts/verify.sh --host [FORGE_HOST]`. It tells you which port or check failed.
2. DNS: `dig +short [FORGE_HOST]` must be the instance's static IP. A changed IP means a recreated instance.
3. Certificate: `forge-compose logs caddy | tail`. A missing or wrong A record, a blocked port 443 or 80, or Let's Encrypt rate limits are the usual causes. Caddy uses `tls-alpn-01` on 443 when it can and falls back to `http-01` on 80, so both ports have to be reachable from the internet. The Caddyfiles pin `acme_ca` to Let's Encrypt, so a validation failure now stays a visible failure: if the name does not resolve yet, Caddy will keep failing rather than silently obtaining a certificate from another CA. Fix DNS first, then restart Caddy.
4. Forgejo: `forge-compose ps`; `forge-compose logs --tail 100 forgejo`. If it is restarting, look for a database connection error before anything else.
5. Database: `forge-compose logs --tail 50 postgres`.
6. Disk: `df -h /` and `docker system df`. See below.
7. Last resort: `sudo reboot`, and read `journalctl -b -1` afterwards.

### Disk is full

1. `df -h /`; `sudo du -xh /var/lib/docker --max-depth=2 | sort -h | tail`.
2. Reclaim: `docker image prune -a` (frees old image layers; running containers are untouched), `sudo journalctl --vacuum-size=200M`, remove old restore files in `/var/backups/forge`.
3. If the Docker-in-Docker volume is the culprit (CI image cache): `docker exec forge-dind docker system prune -af`.
4. Then fix the cause: grow the disk (`os_disk_gb` on Azure; a larger Lightsail bundle on AWS), shorten CI image retention, or move the runner off-box.

### Backup failed, or is stale

1. `journalctl -u forge-backup.service -n 100 --no-pager` shows the failing step. `backup FAILED` is always preceded by an `ERROR` line.
2. Common causes and fixes:
   - `container not running`: start the stack.
   - `AGE_RECIPIENT is unset` or malformed: fix `/etc/forge/backup.env`.
   - upload errors: credentials expired or revoked (rotate), bucket policy changed, no outbound HTTPS.
   - `size mismatch` or `md5 mismatch` on read-back: treat as real. Re-run once. If it repeats, do not prune by hand; open the object in the console and compare, and check the remote's status page.
   - `is only N bytes`: the dump or tar was empty. Check the containers' health.
3. Re-run: `sudo systemctl start forge-backup.service`. A failure never prunes, so older backups are intact.
4. `last-failure` older than `last-success` in `/var/lib/forge/` means it recovered.

### The runner is not picking up jobs

1. `forge-compose ps` for `forge-runner` and `forge-dind`; `forge-compose logs --tail 50 runner`.
2. "waiting for registration": run `/opt/forge/scripts/register-runner.sh`.
3. Jobs stuck "waiting" with the runner online: the workflow's `runs-on` label must be one of `RUNNER_LABELS` (`docker`, `ubuntu-latest` by default).
4. Out of memory: `dmesg | grep -i oom`, `free -m`. The default capacity is one job at a time. A 2 GB host that swaps heavily needs a bigger bundle or a separate runner machine.

### Suspected compromise

1. **Contain without destroying evidence.** Close the cloud firewall to your own address only (Lightsail networking tab; Azure NSG), do not reboot.
2. Snapshot the disk with the cloud's snapshot tool, for later analysis.
3. Revoke: every personal access token, every deploy key, every CI secret, the `SECRET_KEY` question above, the storage key.
4. Decide what was touched using Forgejo's site-admin audit data and `journalctl`.
5. Rebuild from a known-good backup onto a fresh VM ([Full restore](#full-restore)) rather than trying to clean the old one. Pick a backup older than the earliest sign of compromise.
6. Tell anyone whose token or key was on the forge.

### A secret was committed

Revoke it first, in the system that issued it. Then remove it from history (`git filter-repo`), force-push, and ask everyone to re-clone. Revocation is the fix; the rewrite is hygiene.

### Backups were deleted or overwritten

AWS: `aws s3api list-object-versions --bucket [BUCKET] --prefix daily/` shows delete markers and prior versions. Restore a version by copying it over the current key or deleting the delete marker with an administrator credential (the backup key cannot do either). The recovery window is `noncurrent_expire_days` (14 by default), so act inside it. Azure: soft-deleted blobs and previous versions are restorable in the portal or with `az storage blob undelete` within the same window.

## Contacts

| Role | Who | How to reach |
|---|---|---|
| Primary operator | [NAME] | [CONTACT] |
| Backup operator | [NAME] | [CONTACT] |
| Holder of the age identity | [NAME] | [CONTACT] |
| Cloud account owner | [NAME] | [CONTACT] |

Fill this in and keep it somewhere that is not the forge.
