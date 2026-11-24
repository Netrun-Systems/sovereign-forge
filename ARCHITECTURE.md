# Architecture

One machine, one compose project, one backup path. Everything else is a consequence of keeping that true.

## Topologies

### Cloud (AWS or Azure)

```
                     Internet
                        |
          +-------------+--------------+----------------+
          | 80/443 tcp  | 443 udp      | 2222 tcp       | 22 tcp
          | (public)    | (public)     | (git cidrs)    | (admin cidrs only)
   ===== cloud firewall: Lightsail ports / Azure NSG =======================
          |             |              |                |
   +------v-------------v--------------v----------------v-----------------+
   |  Ubuntu 24.04 VM        host: ufw, fail2ban, sshd (keys only),        |
   |                              unattended-upgrades, 2 GB swapfile       |
   |                                                                       |
   |   forge-caddy  :80 :443  ----> forgejo:3000  (compose network)        |
   |                                                                       |
   |   forgejo  :3000 -> 127.0.0.1 only        forge-db (PostgreSQL 16)    |
   |            :22   -> host :2222            no published port           |
   |                                                                       |
   |   forge-runner --tcp 2375--> forge-dind  (privileged; job containers  |
   |   (Forgejo Actions path)                  run inside this daemon)     |
   |   -- or --                                                            |
   |   forge-jenkins  :8080 (compose network; Caddy serves it on its own   |
   |   (Jenkins path)         host name)                                   |
   |                                                                       |
   |   systemd: forge-backup.timer 03:30 UTC -> scripts/backup.sh          |
   +-------------------------------+---------------------------------------+
                                   | age-encrypted, then HTTPS
                                   v
                   S3 bucket (versioned)  /  Blob container (versioned)
                   daily/   pruned by backup.sh
                   weekly/  tiered and expired by lifecycle rules
```

### Local

The same compose files without Caddy and without the cloud wrapper.

```
  you --http--> 127.0.0.1:3000 forgejo --> forge-db
  you --ssh---> :2222          forgejo
                forge-runner --> forge-dind
```

## Port map

| Port | Proto | Who can reach it | What it is |
|---|---|---|---|
| 22 | tcp | `admin_cidrs` only (cloud firewall); ufw also allows it on the host | Host `sshd`. Keys only, no root login. |
| 80 | tcp | Public | Caddy: ACME HTTP-01 challenge and redirect to HTTPS |
| 443 | tcp, udp | Public | Caddy: HTTPS (and HTTP/3) for the forge, and for Jenkins on its own host name |
| 2222 | tcp | `git_ssh_cidrs` (default public) | Forgejo's built-in SSH server, for `git clone ssh://git@host:2222/...` |
| 3000 | tcp | Loopback only (`HTTP_BIND`) | Forgejo HTTP. Never published beyond the host |
| 5432 | tcp | Nobody outside the compose network | PostgreSQL |
| 2375 | tcp | Compose network only | Docker-in-Docker API for the runner. No TLS, no auth, which is why it is not published |
| 8080 | tcp | Compose network only | Jenkins controller |

`verify.sh` asserts the exposed ports are open and that 3000 and 5432 are not reachable from outside.

**Docker publishes ports around ufw.** Published container ports are inserted into iptables ahead of ufw's rules, so ufw does not protect them. The cloud firewall is the perimeter; ufw guards host services such as `sshd`. Do not rely on ufw alone if you move this to a provider without a network-level firewall.

## Data flow

**Push.** `git push` over SSH reaches Forgejo's SSH server on 2222 and over HTTPS reaches Caddy, which proxies to Forgejo on 3000. Repositories are bare repos on the `forgejo-data` volume; metadata is in PostgreSQL.

**CI (Forgejo Actions).** A push creates a run in Forgejo. The runner, which long-polls Forgejo over the compose network, picks up the job and asks the Docker-in-Docker daemon to start a job container from the image named by the runner label. The job container checks out code from the forge's public `ROOT_URL`, runs the steps, and reports back through the runner.

**CI (Jenkins).** A Forgejo webhook calls Jenkins on the compose network (`FORGEJO__webhook__ALLOWED_HOST_LIST` allows the `jenkins` host name and external addresses, nothing else private). Jenkins pulls the code and runs the Jenkinsfile.

**Backup.** `backup.sh` runs from a systemd timer:

```
docker exec forgejo tar  /data/{git,gitea,ssh} --stdout --+
docker exec forge-db pg_dump | gzip  ----------------------+--> age -r <public key> --> /var/backups/forge/*.age
                                                                       |
                                          rclone copyto  <------------+  (+ .sha256 sidecar)
                                              |
                                              v
                              remote:daily/forge-{data,db}-YYYYMMDD.*.age
                                              |
              READ BACK: size, then md5 from the remote (or a full download and sha256)
                                              |
              Sunday: server-side copy to remote:weekly/  (read back again)
                                              |
              prune: keep newest REMOTE_KEEP daily sets, LOCAL_KEEP local sets
```

Properties worth stating plainly:

- Encryption happens in the pipeline, before a byte reaches disk or the network. The host holds only the age **public** key.
- A backup that cannot be read back with the right size and checksum is a failure, and pruning does not run after a failure.
- With no `BACKUP_REMOTE` configured, the script logs that it skipped and exits 0, so a half-configured host does not generate noise, and `verify.sh` reports the timer as armed with no backups.
- The repository tar and the database dump are taken a moment apart, not atomically. A push that lands between them leaves the dump slightly behind the repositories. Forgejo tolerates this; if you need a quiesced snapshot, stop the `forgejo` service around the backup (and accept the downtime).

## What lives where

| Thing | Location | Notes |
|---|---|---|
| Repositories, LFS, attachments, `app.ini`, SSH host keys | Docker volume `forge_forgejo-data` (`/data` in the container) | Backed up |
| Database | Docker volume `forge_pgdata` | Backed up as a `pg_dump` |
| Compose files, scripts | `/opt/forge/compose`, `/opt/forge/scripts` | Delivered once, by cloud-init |
| Compose environment, including generated secrets | `/opt/forge/compose/.env`, mode 0600 | Generated on the host. Never in Terraform state or user-data |
| Backup configuration | `/etc/forge/backup.env`, mode 0600 | Age **public** key, remote, and (AWS only) the scoped storage key |
| First admin password | `/root/forge-admin-credentials.txt`, mode 0600 | Change it, then delete the file |
| Runner identity | `/opt/forge/data/runner/.runner` | Written by `register-runner.sh` |
| TLS certificates | Docker volume `forge_caddy-data` | Issued and renewed by Caddy |
| Jenkins state | Docker volume `forge_jenkins-home` | **Not in the backup** (see below) |
| Local backup copies | `/var/backups/forge` | Newest 2 |
| Backup state | `/var/lib/forge/last-success`, `last-failure` | Read by `verify.sh` |
| Age **private** key | Wherever you keep it. Not here | Needed only to restore |

**Jenkins state is not backed up by default.** `backup.sh` covers Forgejo and its database. If you run Jenkins, add `jenkins-home` to your own backup, or keep all job configuration as code in the repositories (Jenkinsfiles, Job DSL or Configuration as Code), which is what we recommend.

## Configuration surface

`compose/.env.example` lists every variable by name, with no values. `scripts/gen-env.sh` fills in a real `.env` from your environment and generates the secrets.

| Name | Meaning |
|---|---|
| `FORGE_HOST` | DNS name of the forge |
| `FORGE_ROOT_URL` | Public base URL. Derived from `FORGE_HOST` |
| `ADMIN_USER`, `ADMIN_EMAIL` | First administrator; the email is also the Let's Encrypt contact |
| `CI_ENGINE` | `forgejo` or `jenkins` |
| `WITH_CADDY` | `true` on cloud hosts; `false` for local |
| `CADDYFILE`, `COMPOSE_PROFILES` | Derived from `CI_ENGINE` |
| `HTTP_BIND` | Where Forgejo's HTTP port binds on the host. Default loopback |
| `SSH_PUBLIC_PORT` | Public git SSH port. Default 2222 |
| `DATA_DIR` | Host directory for bind mounts (the runner's state) |
| `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | Database. The password is generated |
| `FORGEJO_SECRET_KEY` | Forgejo's `SECRET_KEY`, generated |
| `RUNNER_NAME`, `RUNNER_LABELS` | Runner identity and the labels workflows target with `runs-on` |
| `JENKINS_HOST`, `JENKINS_HEAP` | Jenkins path only |

Backup settings (`BACKUP_REMOTE`, `AGE_RECIPIENT`, `REMOTE_KEEP`, `LOCAL_KEEP`, `WEEKLY_DOW`, `VERIFY_FULL`, `RCLONE_CONFIG_FORGE_*`) are documented at the top of `scripts/backup.sh`.

## One design, two clouds

`terraform/modules/common` declares no providers and creates nothing. It holds what the clouds must agree on: the shipped files, the cloud-init bundle, the public port design, and the retention numbers (daily/weekly prefixes, tiering days, recovery window). The two roots translate those into vendor resources. If you change a port or a retention rule, you change it once.

| | AWS | Azure |
|---|---|---|
| Machine | Lightsail instance + static IP | Linux VM + Standard public IP |
| Firewall | `aws_lightsail_instance_public_ports` | NSG |
| Object store | S3: versioning, SSE-S3, TLS-only policy, public access blocked | Storage account: versioning, soft delete, TLS 1.2 minimum, no public blobs |
| Tiering | `weekly/` to Glacier Instant Retrieval, then expire | `weekly/` to Cool, then Archive, then delete |
| Backup identity | IAM user, access key on the host | System-assigned managed identity, **no secret on the host** |
| Scope of that identity | One bucket: read/write/delete under `daily/`, read/write under `weekly/`, no version deletion | `Storage Blob Data Contributor` on one container |

The AWS asymmetry is forced, not chosen: Lightsail instances cannot assume an IAM role, so the host needs one narrowly scoped key. [docs/CHOOSING.md](docs/CHOOSING.md) covers where we used the vendor feature and where we did not.

## Threat model

### What we are protecting

1. Source code and history in the repositories.
2. Credentials that flow through the forge: access tokens, deploy keys, and CI secrets stored in Forgejo.
3. The integrity and availability of the backups.

### Who we are defending against

- Internet scanners and opportunistic attackers hitting 80, 443 and 2222.
- A leaked or stolen personal access token or SSH key.
- A malicious or compromised pull request, workflow or dependency running in CI.
- A compromised host, including an attacker who tries to destroy the backups so you cannot recover.
- Your own mistakes: an open firewall, a committed secret, a skipped restore test.

### Controls and where they live

| Risk | Control | Where |
|---|---|---|
| Open admin surface | Host sshd limited to `admin_cidrs`, keys only, no root, fail2ban; Terraform refuses `0.0.0.0/0` for admin | `variables.tf`, `bootstrap.sh` |
| Open data services | PostgreSQL and the Docker API are never published; Forgejo HTTP is loopback-only | compose files |
| Self-registration abuse | `DISABLE_REGISTRATION` and `REQUIRE_SIGNIN_VIEW` are on | `docker-compose.forgejo.yml` |
| Plaintext in transit | Caddy terminates TLS with HSTS; S3 policy denies non-TLS | Caddyfiles, S3 bucket policy |
| Unpatched OS | `unattended-upgrades` | `bootstrap.sh` |
| Unpatched containers | Pinned by tag and digest, upgraded deliberately | `RUNBOOK.md` |
| Secrets in the repo | `.env.example` carries names only; tripwire in CI and `make lint`; `.gitignore` | `scripts/check-no-secrets.sh` |
| Secrets in Terraform state | Generated on the host; only the AWS backup key is in state | `gen-env.sh` |
| Cloud metadata theft from a container | iptables `DOCKER-USER` rule drops container traffic to `169.254.169.254` | `forge-metadata-block.service` |
| Attacker reads backups | Client-side age encryption; private key is not on the host | `backup.sh` |
| Attacker deletes backups | Versioning plus a key that cannot delete versions or change lifecycle (AWS); soft delete and versioning (Azure). The recovery window is `noncurrent_expire_days` | Terraform |
| Silent backup failure | Read-back verification; `verify.sh` fails if the last success is older than 36 hours | `backup.sh`, `verify.sh` |
| Untested backups | `restore.sh` drill with tamper and wrong-key failure paths | `restore.sh`, `RUNBOOK.md` |
| Typosquatted or mutated image | Tag **and** digest pin; CI rejects an unpinned image | `ci.yml` |

### Residual risks you are accepting

- **CI job escape reaches the forge.** The runner and Docker-in-Docker daemon share a VM with Forgejo and its database. A privileged dind container is a smaller target than the host socket but it is not a hard boundary. A job that escapes it is on the machine that holds every repository. **For public projects or untrusted contributors, run the runner on a separate machine.** Workflows from pull requests of forks should require approval (a Forgejo setting) until you have done so.
- **A compromised host can read live data** and, on AWS, use the backup key to overwrite `daily/` and `weekly/` objects. Versioning keeps the previous versions recoverable for `noncurrent_expire_days` (14 by default). It cannot be used to read old backups, because they are encrypted to a key the host does not have.
- **The AWS backup key sits in two places**: `/etc/forge/backup.env` and Terraform state. Use an encrypted remote state backend. The host copy of user-data is scrubbed after first boot, and containers cannot reach the metadata endpoint, but the cloud provider still holds the original user-data for the life of the instance. If that matters to you, rotate the key after first boot ([RUNBOOK.md](RUNBOOK.md#rotate)).
- **No intrusion detection or audit-log shipping.** Forgejo's own audit data and the journal are on the box.
- **Single point of failure.** See the README.
- **Digest pins freeze vulnerabilities as well as behaviour.** A pinned image does not patch itself, so the upgrade chore in the runbook needs a calendar entry. Subscribe to Forgejo's release announcements and security advisories.
