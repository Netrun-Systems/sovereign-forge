# sovereign-forge

A self-hosted Git forge and CI that you can stand up on a small cloud VM, or on a machine you own, with one command. It packages [Forgejo](https://forgejo.org) for private repositories, a CI runner beside it, and encrypted nightly off-site backups with a restore drill. It grew out of our own setup: a snapshot copy of our repositories on hardware we own, with encrypted nightly backups. The AWS path has now been deployed end to end on real infrastructure and destroyed again; the Azure path has not. See [Verification status](#verification-status) for exactly what has and has not been tested.

```
make aws        # Lightsail + S3        -> https://forge.example.com
make azure      # small VM + Blob       -> https://forge.example.com
make local      # Docker Compose here   -> http://localhost:3000
```

Nothing in this repository is a secret. There is no hosted component and no account to create with us.

## Why

Three reasons people end up here:

- **Cost control.** A forge and its CI fit on one 2 GB machine. That is a flat monthly line you can read off an invoice, instead of per-seat and per-minute pricing that grows with the team.
- **Ownership.** Your repositories, your CI history and your backups sit in storage you control, encrypted with a key that never touches the server.
- **Reproducibility.** The machine is defined by files in this repo. Losing it costs you a restore, not a rebuild from memory.

The honest counter-argument is in [docs/CHOOSING.md](docs/CHOOSING.md). If your team lives in GitHub's ecosystem and nobody wants to patch a server, stay on GitHub.

## The cost argument, briefly

This is a kit, not a price list, so the numbers live in [docs/COSTS.md](docs/COSTS.md). The shape of the argument:

- One VM. On AWS Lightsail the 2 GB bundle is a flat monthly price with transfer included; the 4 GB bundle is double that. We pay $12 and $24 a month for those two bundles as of late 2026. Check current pricing before you rely on it.
- Object storage for backups is the only managed service in the design, because it is genuinely cheaper and more durable than anything you would run yourself. Weekly copies move to a cold tier on a schedule.
- If you already own hardware, the cheapest topology is the third one below. Our own forge runs on owned hardware; this kit exists for everyone who does not have a spare machine.

## Three topologies

| | Where | Host cost | TLS | Backups go to | Use it when |
|---|---|---|---|---|---|
| **AWS** | One Lightsail instance + static IP + firewall | Flat monthly bundle | Caddy + Let's Encrypt | S3 (versioned, lifecycle to Glacier Instant Retrieval), scoped IAM user | You are already on AWS, or want the simplest flat price |
| **Azure** | One burstable Linux VM + NSG | Pay for the VM and disk | Caddy + Let's Encrypt | Blob (versioned, Cool then Archive), managed identity, no stored secret | You are already on Azure, or want credential-less backups |
| **Local** | Any Linux box with Docker: a spare PC, a Proxmox container, a home server | Hardware you own | None by default | Anything rclone speaks, configured by you | You own hardware, or want to try it first |

All three run the same containers from the same compose files.

## Quickstart

You need: Terraform 1.5 or newer, `ssh`, `age`, `make`, bash 4.4 or newer (macOS ships 3.2: `brew install bash`), a DNS name you control, and (for the cloud paths) a logged-in cloud CLI. For `make local` you need Docker instead of Terraform.

**1. Make a backup key pair.** The private half stays with you and never goes on the server.

```bash
age-keygen -o identity.txt          # keep this safe, off the forge, out of git
age-keygen -y identity.txt          # prints the PUBLIC key (age1...) you put in tfvars
```

**2. Configure.**

```bash
cp terraform/aws/terraform.tfvars.example terraform/aws/terraform.tfvars   # or azure/
$EDITOR terraform/aws/terraform.tfvars    # forge_host, admin_email, ssh_public_key, admin_cidrs, age_recipient
```

**3. Run it.**

```bash
make aws        # or: make azure
```

Terraform shows its plan and asks before applying. When it finishes, the command prints the address to point your DNS at, then waits (up to 15 minutes) for first boot, DNS and the certificate, and runs `scripts/verify.sh` against the result. Create the A record when it tells you to.

**4. Sign in.** The first administrator's random password is written to a root-only file on the host:

```bash
ssh ubuntu@<public_ip> sudo cat /root/forge-admin-credentials.txt     # azureuser@ on Azure
```

**5. Prove the backups work, once, now.**

```bash
ssh ubuntu@<public_ip> sudo systemctl start forge-backup.service
make restore-drill AGE_IDENTITY=./identity.txt BACKUP_ENV=./backup.env
```

`backup.env` for the drill is a file on your machine with `BACKUP_REMOTE` and the `RCLONE_CONFIG_FORGE_*` settings; see [RUNBOOK.md](RUNBOOK.md#restore-drill). A backup you have not restored from is a hope, not a backup.

For a local trial: `make local`, then open <http://localhost:3000>.

## CI engine: Forgejo Actions by default, Jenkins if you need it

The default is **Forgejo Actions**. It reads GitHub-Actions-compatible workflow YAML, so existing `.github/workflows` files port with little or no change. That is a real migration argument. In one of our repositories, more than 400 GitHub Actions runs have ended in `startup_failure` since 2026-04-25: run creation is refused upstream of the workflow file, so no job has started there since. Under Forgejo Actions the same YAML should get a runner and run; we have not yet tested that migration. It is also light: the runner is a single Go binary.

**Jenkins** is also fully wired up (`CI_ENGINE=jenkins`), and it is the right choice for teams with existing Jenkinsfiles or plugin dependencies that have no Actions equivalent. It is a JVM service with a real memory floor and a plugin-update cadence you need to own, so it needs a bigger instance: **4 GB** (Lightsail `medium_3_0`, Azure `Standard_B2s`), against **2 GB** (`small_3_0`, `Standard_B1ms`) for Forgejo Actions.

| CI path | AWS Lightsail | Azure | Why |
|---|---|---|---|
| Forgejo Actions | `small_3_0` (2 GB, 2 vCPU) | `Standard_B1ms` (2 GB, 1 vCPU) | Forgejo, PostgreSQL, Caddy, a Go runner and its Docker-in-Docker sidecar. A 2 GB swapfile is created as a safety margin. |
| Jenkins | `medium_3_0` (4 GB, 2 vCPU) | `Standard_B2s` (4 GB, 2 vCPU) | The same stack minus the runner, plus a Jenkins controller capped at a 1 GB heap and a 2 GB container limit. |

These sizes began as reasoned starting points. On 26 November 2026 we load-tested the AWS default (`small_3_0`) and one compute-optimized plan on throwaway Lightsail instances; the results are under [Verification status](#verification-status). In short: memory is not what limits a 2 GB instance, sustained CPU is. A `small_3_0` runs at full speed for about its first hour and then holds 0.4 vCPU, and while a build runs on the same box the forge's web pages slow from tens of milliseconds to seconds. The test was one afternoon on a few instances with synthetic repositories, a public open-source build, and no real multi-user load, so the sizes are still starting points. Watch memory, swap and CPU steal for a week on your own workload, and set `bundle_id` or `vm_size` accordingly. The reasoning for the default is in [docs/CHOOSING.md](docs/CHOOSING.md).

## What is in here

```
terraform/aws, azure      one root per cloud; modules/common holds what they must agree on
compose/                  Forgejo + Postgres + runner, Jenkins, Caddy; every image pinned by tag AND digest
cloud-init/               first-boot hardening, the backup timer, the bootstrap
scripts/                  backup, restore drill, GitHub mirror, post-deploy verification
.forgejo/workflows/ci.yml the kit's own CI, which doubles as a runner smoke test
```

Start with [ARCHITECTURE.md](ARCHITECTURE.md) for how it fits together and what the threat model is, [RUNBOOK.md](RUNBOOK.md) for day-2 operations, and [MIGRATION.md](MIGRATION.md) to move off GitHub and keep it as a mirror.

## What this does not do

Read this before you trust it with anything.

- **No high availability.** One machine. If it dies you restore from backup onto a new one; plan for that to take an hour or more and for up to a day of data loss (the backup runs nightly).
- **The runner shares a machine with the forge.** CI jobs run in a Docker-in-Docker sidecar, which is isolation, not a security boundary. Do not run untrusted pull requests on it. Put the runner on its own machine for anything public. See the threat model in [ARCHITECTURE.md](ARCHITECTURE.md). It is also a performance reason: in our load test the forge's pages were slow whenever a build ran on the same instance (see [Verification status](#verification-status)). The kit has no script for a separate runner machine, and that topology was not tested.
- **No monitoring or alerting stack.** `verify.sh`, systemd and the journal are what you get. A failed backup is a log line and a stale timestamp, not a page. Wire it to whatever you already use.
- **No outbound email.** SMTP is not configured, so there are no notification mails or password-reset links until you set it up in Forgejo.
- **No SSO, LDAP, or SAML.** Local accounts only. Self-registration is off.
- **No DNS automation.** You create the A record. That keeps the kit vendor-neutral and means a typo cannot take over a zone.
- **Jenkins has no agents.** The controller runs builds on its built-in node, which is fine for trusted private repositories and wrong for anything else.
- **Containers are not auto-updated.** Image tags and digests are pinned on purpose. The operating system patches itself; Forgejo, Postgres, Caddy and the runner are upgraded by you ([RUNBOOK.md](RUNBOOK.md#upgrade)).
- **Windows and macOS runners, container registry hosting, package registries, and Pages** are outside the scope of the default setup.
- **`make local` has no TLS.** It listens on plain HTTP at `http://localhost:3000`, bound to loopback.

## Verification status

What was checked, and what was not. Update this section when you test it somewhere new. Nothing here was run on GitHub Actions; GitHub Actions does not execute for this project.

Environment of the 2026-11-24 run: Windows 11, WSL2 Ubuntu 26.04 (bash 5.3.9, GNU Make 4.4.1, Docker Engine 29.1.3 and Compose 2.40.3 from WSL's own engine, run as root), rclone 1.76.0, age 1.2.1. Images as pinned in `compose/`: Forgejo 15.0.12, PostgreSQL 16.16, runner 13.2.2, Docker-in-Docker 27.5.1.

Environment of the 2026-11-25 run: the same WSL2 engine for everything marked "local" below, plus Caddy 2.11.9 and Jenkins 2.580.2-lts-jdk21 (Java 21.0.13) as pinned, Terraform 1.17.2 (installed in WSL, release checksum verified) and shellcheck 0.11.0. The first-boot checks ran on a throwaway QEMU/KVM guest on Proxmox VE 9.1.1 (2 vCPU, 4 GB RAM, 25 GB disk, kernel 6.8.0-147), booted from the checksum-verified Ubuntu 24.04.5 LTS cloud image, with the kit's rendered user-data delivered through cloud-init's NoCloud datasource. The guest has been destroyed.

Environment of the 2026-11-26 run, the first real cloud deployment: AWS us-east-1, account owner's own account, driven from WSL2 Ubuntu 26.04 with Terraform 1.17.2 (providers aws 5.100.0, random 3.9.1). One Lightsail `small_3_0` instance (2 GB / 2 vCPU) on Ubuntu 24.04.5, kernel 7.0.0-1014-aws, with a static IP, a public DNS record, a versioned S3 bucket (SSE-AES256, public access blocked) and a dedicated IAM user for backups. The stack was destroyed the same day and the DNS record deleted. Cost at most about $0.26, estimated from instance-hours across the final instance, one failed instance and three disposable probe instances; the billed figure was not read, because Cost Explorer lags about a day.

### Checked, 2026-11-24

| Checked | How |
|---|---|
| `terraform fmt` and `terraform validate` clean for `aws/` and `azure/` | Terraform 1.17.2, providers aws 5.100.0, azurerm 4.81.0, random 3.9.1. Also run as the `terraform` job of the kit's own CI, on the runner this kit deploys: passed |
| Compose files parse and merge correctly for the local, cloud and Jenkins layouts, with the right profiles active | `docker compose config` (no containers started) |
| Rendered cloud-init bundle unpacks byte-for-byte | Rendered with Terraform, decoded and diffed. **The size half of this row was wrong and is withdrawn.** It claimed the render was under Lightsail's 16 KB limit; nothing had been submitted to Lightsail, and Lightsail's real ceiling turned out to be about 14.6 KB. The 14,809-byte render of the 2026-11-25 run sits inside the band where Lightsail's behaviour is untested. See the 2026-11-26 run |
| `make local` from an empty machine: Forgejo, PostgreSQL, Docker-in-Docker and the runner all up and healthy | `make local` exit 0 in about 70 s with a cold image cache, no Caddy |
| First administrator, API token, push and clone over HTTP and over SSH (port 2222) | The command `make local` prints, then `git push` / `git clone` against `localhost:3000` and `localhost:2222` |
| Forgejo Actions: a workflow runs on the runner, including `actions/checkout` | Two workflows pushed to a test repository, both succeeded. The kit's own `.forgejo/workflows/ci.yml` also passes both jobs (hygiene, with shellcheck 0.9.0 from Debian, and terraform) |
| `backup.sh` against real containers | Both artifacts built and encrypted, uploaded, read back and size/md5 verified, daily and weekly copies, to an rclone `local` remote |
| `restore.sh` drill, daily and weekly tiers, `--extract-to`, and failure with the wrong key | Run against that backup |
| Full restore per [RUNBOOK.md](RUNBOOK.md#full-restore) onto a fresh stack with newly generated secrets | Repository, branches, tag, issue and API token survived, `git fsck` clean, push works after `regenerate hooks`, runner re-registered per step 7 |
| `make destroy CLOUD=local PURGE=1`, then `make local` again | Containers, volumes and the runner registration are gone and the next `make local` registers a new runner |
| `mirror-from-github.sh`: dry run, mirror, re-run, archived repositories skipped, pull-request refs preserved | Against a stubbed GitHub API and local file origins, into the real local Forgejo. Not against github.com |
| `mirror-from-github.sh` safety options (2026-11-25): `--only-existing` creates nothing; a forge-only commit, a forge-only branch, rewritten GitHub history and a moved tag are each refused with exit 3 and nothing lost; `--overwrite-forge` still deletes forge-only refs; a bad token or an error on a later GitHub page aborts non-zero | 28 assertions (including a mixed-case GitHub name mirrored into a lowercase forge repo through a mixed-case owner) against a throwaway Forgejo 15.0.12 (SQLite) in WSL, a stubbed GitHub API and local file origins. Not against github.com |
| `shellcheck` on `scripts/` and `cloud-init/bootstrap.sh` | Clean with shellcheck 0.11.0 (container) and 0.9.0 (the version the CI job installs from Debian bookworm). Re-run clean with 0.11.0 on 2026-11-25 after the fixes below |
| Secret tripwire catches keys, private addresses and valued env files, and no longer prints the secret it found | `scripts/check-no-secrets.sh`, positive and negative |

### Checked, 2026-11-25

| Checked | How |
|---|---|
| Jenkins (`CI_ENGINE=jenkins`): the controller starts and stays healthy inside its 1 GB heap and 2 GB container cap | `CI_ENGINE=jenkins WITH_CADDY=false make local`. The container reported healthy and the log said "Jenkins is fully up and running". The JVM ran with `-Xms256m -Xmx1g`; the container used 593 MiB idle and 854 to 884 MiB after a plugin install, a restart and a pipeline build, against the 2 GiB cap, with 0 restarts and `OOMKilled=false`. Idle plus one trivial build only, not a load test |
| `jenkins/Jenkinsfile.example` runs to completion on the built-in node | The Pipeline suite, Git and Gitea plugins installed with `jenkins-plugin-cli`, the file pushed to the local Forgejo, a "Pipeline script from SCM" job with a credential: build result SUCCESS, with checkout, Build, Test and the post step all run. It FAILED the first time; see the bugs below. Forgejo webhooks, Multibranch jobs and external agents were not exercised. The stack was then destroyed with `PURGE=1` |
| `bootstrap.sh` on a clean Ubuntu 24.04 host, started by cloud-init's real first-boot sequence | The module's `user_data` output rendered with Terraform (14,809 bytes) and delivered as NoCloud user-data. `cloud-init status` reported `done`, the log ended "bootstrap complete" on the first attempt, with no errors. Five containers up (Forgejo and PostgreSQL healthy, runner registered, Docker-in-Docker, Caddy). The swapfile, ufw rules, fail2ban, unattended-upgrades, the metadata-endpoint DROP rule and the sshd hardening drop-in were all in effect |
| `/root/forge-admin-credentials.txt` and the secret files | Present as `0600 root:root`, as are `/opt/forge/compose/.env`, `/etc/forge/backup.env` and `/var/lib/forge/last-success`; `/var/backups/forge` is `0700` |
| `forge-backup.timer` and `forge-backup.service` install, and the timer fires the service | Both installed and the timer enabled by `bootstrap.sh`. To avoid waiting for 03:30, a temporary drop-in moved the timer to about two minutes ahead (and was then removed): the service started with `TriggeredBy: forge-backup.timer`, `Result=success`, exit 0, and `last-success` was written |
| The off-site artifact is encrypted and read back | Pointed at an rclone `local` remote on the guest, no cloud bucket. Both artifacts begin with the age header, are not readable as tar, the `.sha256` sidecars verify, and the script's own size and md5 read-back passed for all four objects. Copied off the guest, they decrypt with the private key that never touched it (the data archive lists the seeded repository, the dump contains the `repository` table) and a wrong key is refused |
| `verify.sh`, both halves, against a real host | On-box half: 15 PASS after the backup had run. Remote half, run from the guest against its own address with `--host forge.internal --ip <addr>`: ports 80, 443 and 2222 open, 3000 and 5432 closed, TLS verified, health endpoint 200, API reachable, registration closed. It exposed two bugs in the check itself (below), and it correctly turned FAIL when registration was deliberately opened on the guest |
| The stack comes back after a reboot | After the first reboot all five containers were up again (the data survived, the backup state was still recent) and the on-box half passed 14 of 15; the one FAIL was "sshd allows password authentication", which two further reboots, one of them sampled every 3 s from boot, never reproduced (`passwordauthentication no` each time). That single failure was explained by the 2026-11-26 run: a SIGPIPE under `pipefail`, in the check itself, not on the host. See the bugs below. The second reboot was only probed early, while containers were still starting, so full recovery was observed once |
| Caddy (`WITH_CADDY=true`) terminates TLS and proxies to Forgejo | With the internal name `forge.internal`, which Caddy serves from its own CA (`tls internal` is automatic for this name; the log says `"issuer":"local"`), both on the guest's bootstrap and on a cold local `WITH_CADDY=true make local`: HTTP/2 with a certificate from "Caddy Local Authority", chain verified when its root is trusted and `unable to get local issuer certificate` when it is not, port 80 answers 308 to HTTPS, HSTS and nosniff headers set and the `Server` header removed, zstd compression, the Forgejo login page reached through the proxy, port 3000 bound to loopback only, and a clone and push over HTTPS through Caddy. **Let's Encrypt issuance was not tested**: it needs a public IP and a public DNS record, and none was created |
| `terraform init -backend=false`, `validate` and `fmt -check` for `aws/` and `azure/` | Terraform 1.17.2, lock files unchanged by `init`, all clean, and clean again after the fix below |
| `terraform plan` for `aws/` | Read-only. Without credentials it stops at "No valid credential sources found". With a read-only session it first failed (bug below); after the fix: `Plan: 16 to add, 0 to change, 0 to destroy`, exit 0, no state file written. **No `apply` was run and nothing was created** |

### Bugs found and fixed by the 2026-11-25 run

| What was wrong | How it showed | Fix |
|---|---|---|
| `jenkins/Jenkinsfile.example` called `cleanWs()`, a Workspace Cleanup plugin step that the Pipeline suite does not provide | The build FAILED after its stages passed: `No such DSL method 'cleanWs'` | It uses core `deleteDir()`, and the header now says the file needs the Pipeline and Git plugins, because the controller image ships with none |
| `WITH_CADDY=true make local` wrote the Caddy compose layer but never started Caddy | It printed "forge is up at https://forge.internal/" with nothing listening on 80 or 443 | `forgectl.sh local` now runs `up -d caddy` when `WITH_CADDY=true`; confirmed on a cold re-run |
| `verify.sh` failed `/api/v1/version` on every host this kit builds | The kit sets `REQUIRE_SIGNIN_VIEW`, so the answer is `Only signed in user is allowed to call APIs.` | That answer now counts as the API responding and refusing anonymous callers |
| `verify.sh` failed the registration check on a host where registration is off | Forgejo answers `/user/sign_up` with 200 and the text "Registration is disabled" in place of the form, so status 200 was read as "open" | The body decides: the disabled notice passes, the sign-up form fails. Both were exercised |
| `terraform plan` (and so `apply`) for `aws/` died with `Output refers to sensitive values` on `user_data_bytes`, which `validate` cannot see | The rendered user-data embeds the backup key, so even its length is tainted as sensitive | The output in `terraform/aws/outputs.tf` is marked `sensitive = true` |
| `ARCHITECTURE.md` said the host copy of user-data is scrubbed after first boot, which is only partly true | After a real first boot `cloud-config.txt` and `obj.pkl` under `/var/lib/cloud/instances/` still hold the whole bundle, root-only, like `backup.env` | The documentation and the comment in `bootstrap.sh` now say so. Behaviour is unchanged: deleting cloud-init's own state was judged riskier than an exposure equal to `backup.env`'s |

### Checked, 2026-11-26 — a real deployment to AWS, then destroyed

| Checked | How |
|---|---|
| `forgectl.sh deploy aws` end to end, from `terraform apply` to a passing verify | 16 of 16 resources created, matching `Plan: 16 to add`. The final converged run reported `Apply complete! Resources: 0 added, 0 changed, 0 destroyed`, then verify 9/9 remote and 15/15 on-box, exit 0. Four separate defects had to be fixed before this worked at all; see the bugs below |
| First boot on real Lightsail, through Lightsail's own launch-script mechanism | `cloud-init status` reported `done` on Ubuntu 24.04.5 (kernel 7.0.0-1014-aws). `/root/forge-admin-credentials.txt` was `0600 root:root`, with the swapfile, ufw, fail2ban, unattended-upgrades and the sshd hardening drop-in all in effect. A container reaching 169.254.169.254 timed out while outbound traffic worked |
| Lightsail's real user-data ceiling | Measured rather than taken from the documentation. Lightsail refused 15,065 bytes with `Your user data launch script exceeds the 16 KB limit`; disposable probe instances accepted 14,500 bytes and refused 14,950, so the real ceiling is about 14.6 KB. The kit now renders 11,648 bytes, and a Terraform precondition fails above 14,000 |
| Let's Encrypt (ACME) issuance against a public name, with a fresh ACME account | Account `https://acme-v02.api.letsencrypt.org/acme/acct/4045838431`. Challenge `tls-alpn-01` on port 443, validated from 7 Let's Encrypt vantage points in about 3 s. Observed off-box against the client's own trust store: verify return code 0, `CN=forge-drill.netrunsystems.com`, serial `05F9E020A0E131F80ED1E16FB39951F9A216`, EC prime256v1, notBefore Nov 26 01:17:32 2026 GMT, notAfter Feb 24 01:17:31 2027 GMT, chain leaf then `CN=YE2` then `CN=Root YE`. `curl` with no `-k` returned 200 over HTTP/2, and port 80 answered 308. **Renewal was not waited for** |
| The backup timer on its own real schedule | No hand trigger, no drop-in, unit file mtimes unchanged since boot. Predicted next fire 03:39:44 UTC; it fired at 03:39:47 UTC, inside the randomised delay, with `TriggeredBy: forge-backup.timer`, `Result=success`, exit 0 and CPU 1.231 s, and scheduled the next for 2026-11-27 03:34:52 UTC |
| The S3 code path of `backup.sh`, with a real bucket and the deployed IAM key | Both artifacts built, encrypted, uploaded, read back and size/md5 verified. Bucket versioning Enabled, SSE AES256, public access blocked. Objects listed independently of the script: `daily/forge-data-20261126.tar.age` 171,240 B, `daily/forge-db-20261126.sql.gz.age` 34,137 B, and the two `.sha256` sidecars at 94 and 95 B. A forced weekly copy also worked |
| `restore.sh` from S3 | `restore.sh --date 20261126 --tier daily` printed `RESTORE DRILL PASS` with 1 repository. Daily and weekly tiers both passed, and a wrong key is refused |
| `verify.sh --ssh`, both halves, against a public host | 9 of 9 remote and 15 of 15 on-box, exit 0. The remote half covered ports 80, 443 and 2222 open and 3000 and 5432 closed, a verified public TLS handshake, the health endpoint at 200, the API refusing anonymous callers, and registration closed |
| fail2ban actually banning | Banned after 4 probes from a distinct source address, after which the port answered `Connection refused`; the ban was then lifted. The jail as previously shipped never banned at all, however many probes arrived; see the bugs below |
| unattended-upgrades actually installing | `curl` and `libcurl` were downgraded by hand, then `unattended-upgrade -v` reinstalled them from `noble-security` and also upgraded the kernel packages |
| `forgectl.sh destroy aws`, and the account afterwards | `Destroy complete! Resources: 16 destroyed.` with Terraform state at 0 entries. Confirmed from the account afterwards: Lightsail back to the two pre-existing instances with no leftover key pairs, snapshots or disks; S3 back to its four pre-existing buckets; the backup IAM user, its inline policy and its access key all answering `NoSuchEntity`. Local state, tfvars, the deployment's IAM key, the SSH key and the throwaway age identity were shredded, and the public DNS record was deleted |

### Bugs found and fixed by the 2026-11-26 run

Four of these made `make aws` impossible, and none of them was visible to `terraform validate`, to `docker compose config`, or to a complete local Docker run.

| What was wrong | How it showed | Fix |
|---|---|---|
| **Lightsail never executed the cloud-config, so the AWS path had never worked.** Lightsail wraps user-data in its own `#!/bin/sh` launch script, so every `#cloud-config` line ran as a shell command | cloud-init ended in error with `part-001: 17: package_update:: not found`, and nothing was installed | A new `cloud-init/lightsail-launch.sh.tftpl` performs the same first boot as a shell script, and the module exports `launch_script` and `launch_script_bytes`. Azure still uses the cloud-config, which has never been run |
| The 16 KB user-data limit in Lightsail's documentation is really about 14.6 KB | `CreateInstance` refused a 15,065-byte script | Comment-only and blank lines are stripped before submission, saving about 4 KB, and a Terraform precondition fails above 14,000 bytes |
| Replacing the instance orphaned its static IP and reset the firewall to the Lightsail default of 22 and 80 open to 0.0.0.0/0, silently discarding `admin_cidrs` | Seen after a `terraform apply -replace` of the instance | The IP attachment and the firewall now carry `replace_triggered_by`, and all three were confirmed to be replaced together |
| The backup IAM policy lacked `s3:GetObjectVersion`, which rclone needs to read an object back on a versioned bucket | Every upload logged a 403 and survived only on rclone's retry | The verb was added; uploads now log no errors. `s3:DeleteObjectVersion` is still deliberately absent |
| fail2ban never banned anything on Ubuntu 24.04: the jail watched `sshd.service`, but the journal records the unit as `ssh.service` | `Total failed: 0` and no bans, however many probes arrived | `bootstrap.sh` sets `journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd` |
| The intermittent "sshd allows password authentication" failure of the 2026-11-25 run was in the check, not the host | `grep -q` after a pipe, under `pipefail`, killed the writer with SIGPIPE | Restructured. It now passes every time: 6 of 6, and again in both final runs |
| Caddy falls back to ZeroSSL when Let's Encrypt validation fails, and registers a ZeroSSL account under `ADMIN_EMAIL` without saying so, while this kit's documentation says Let's Encrypt | Five Let's Encrypt failures while the name was still NXDOMAIN (`urn:ietf:params:acme:error:dns ... NXDOMAIN`), then an unannounced ZeroSSL account | Both Caddyfiles pin `acme_ca` to the Let's Encrypt directory, so a validation failure stays a failure instead of quietly becoming a different CA. Verified by adapting each file: exactly one issuer, module `acme`, at that directory |

### Measured, 2026-11-26 — a load test on throwaway Lightsail instances, then deleted

Environment: AWS us-east-1, driven from the command line, Ubuntu 24.04. Three throwaway instances over one afternoon, all deleted the same day (computed cost about $0.24 in total): one `small_3_0` ($12, 2 GB, 2 vCPU) for the first test, then a `c_large_1_0` ($42, 4 GB, 2 vCPU, compute-optimized) and a second `small_3_0` for a follow-up. The stack on the `small_3_0` boxes was this kit at `c409cd7`, unmodified, with Forgejo Actions, plain HTTP, no Caddy and no backup timer, on the kit's Docker Compose files rather than its Terraform path. The load came from scripts running on the instance itself against loopback, so client and server shared the same two vCPUs. The repository was synthetic (231 MiB, 301 commits, repacked once). The CI jobs were a synthetic memory-and-hash job and a build of a public open-source TypeScript monorepo (install, build, typecheck). **We did not run our own build on the kit.**

| Measured | Result |
|---|---|
| Idle footprint of Forgejo, PostgreSQL, the runner and Docker-in-Docker on `small_3_0` | 690 MB used of 1,905 MB (maximum 714 MB), 1 MB of swap, about 0.02 vCPU of CPU, over a 557-second window with the kit's 2 GiB swapfile |
| Sustained CPU on `small_3_0` | Both vCPUs ran at about 99% with no throttling for the first hour, then dropped abruptly to 0.4 vCPU (20% of the box) and stayed there for as long as we kept loading it, over an hour. Two separate instances were throttled 60.9 and 60.5 minutes after creation, although the second had done about 25 more vCPU-minutes of work, so the onset followed the clock and not the work done. A burstable plan tested for under about 70 minutes looks unthrottled. Lightsail's burst-capacity metrics read about 0% for the whole test, including while the box ran at 99%, so they are not an early warning on this plan; guest CPU steal (above 30% sustained) and the CPU-utilization metric pinned near 20% were |
| Sustained CPU on `c_large_1_0` ($42) | Synthetic two-vCPU load for 150 minutes: 99.9% busy, 0.00% steal, flat throughput, no throttle. This is raw CPU only. No CI job ran on this plan and its memory under a job was not measured |
| Forge cost per request, 231 MiB repository | A full clone cost about 3.0 server CPU-seconds at every concurrency from 1 to 20 clones, with 0 failures. A small push cost about 0.92. Forgejo's memory peaked at 189 MB with 20 concurrent clones and 735 MB with 20 concurrent pushers. On the throttled box, 20 pushers making 10 pushes each took 650 seconds, with a median of 63 seconds per push |
| CI jobs on a throttled `small_3_0` | The public TypeScript build took 808 seconds, peaked at 899 MB in its container and 433 MB of swap, with no out-of-memory kill. A synthetic 1.5 GB job ran in 579 seconds using about 1 GB of swap. Two of those at once (`capacity: 2`) both succeeded, each taking 2.66 times as long, which is 0.75 times the throughput of running them one after the other, with swap full and no out-of-memory kill. A second runner slot adds nothing on this plan |
| Forge web UI latency on `small_3_0` | Idle: 71 ms median, 229 ms 95th percentile, measured on the box. While a build ran on the same throttled box: **1.3 to 6.9 seconds at the median**, depending on the test. 6.9 seconds came from a single 180-second window of 75 requests. 1.3 to 1.5 seconds came from whole jobs with three simulated users browsing continuously (1.5 as the kit ships, 1.3 with the CPU and memory limits we tried). At full speed, before the throttle, pages answered in 85 to 93 ms during a build. So the slowness is the throttle, not the missing container limits. The limits recovered 10 to 15% of the delay and made the build 7% slower when throttled and 31% slower at full speed, so we do not recommend them as the fix |
| CI log size | 0.6 KB and 3.4 KB compressed on disk for two quiet jobs, and a 17 MB database after four runs. A noisy job was not tested |

**Calculated from those measurements, on assumed demand.** These are our arithmetic, not things we observed. They assume three CI runs per developer per working day at 13 minutes each (the mean build time on our own CI is 13.25 minutes; the three runs a day is our assumption), 21 working days a month, one runner slot, and 60% utilisation of business hours.

| Calculated | Result |
|---|---|
| Developers one `small_3_0` carries, human-only | About 7 on throughput alone (a single runner slot at 819 build-minutes per developer-month). About 2 to 3 if you want the pages to stay quick during builds. That second figure rests on the 1.3 to 6.9 second range above and on no latency target we can justify, so treat the true span as 2 to 7 |
| Monthly cost, human-only, cash only | About $14 at 5 developers (one $12 instance plus about $2 of backup storage at the kit's default retention for 2.5 GiB) and about $27 at 10 (two $12 instances, the runner on its own, plus backup). Operator time is not priced. At 5 developers on one instance, builds would slow the forge's pages as above |
| At our own CI volume | Our CI runs about 270 builds and 3,590 build-minutes a month for one operator working with agents (99 builds over 11.1 days). If each developer generated that much, 5 developers would produce about 17,700 build-minutes a month, more than a $12 runner holds, and the calculation puts the runner on the $42 compute-optimized plan, about $57 a month in total |

The separate-runner topology behind the $27 and $57 figures was not built or tested, and the kit has no script for it. Everything above 10 developers, and every plan larger than those named here, is extrapolation.

### Not checked

| **Not** checked | |
|---|---|
| Azure, in any form | `azure/` passes `fmt` and `validate`, but no `plan` and no `apply` has ever been run against it, and its first boot still relies on the cloud-config that Lightsail proved is not executed everywhere. Treat the Azure path as unverified, not merely untested |
| The `GLACIER_IR` lifecycle transition | The rule for `weekly/` at 30 days is present and correct in the bucket's configuration. The objects were hours old, so the transition cannot have happened and only the configuration is verified |
| Certificate renewal | Issuance was verified against Let's Encrypt. The renewal at about 60 days was not waited for |
| `Persistent=true` catch-up after downtime | The timer was observed firing on its own schedule, not catching up after a missed window |
| The Azure Blob code path of `backup.sh` | S3 and rclone's local backend are both exercised; Azure Blob is not. The "remote reports no checksum" branch was exercised only with `VERIFY_FULL=1` and `docker` stubbed |
| Jenkins with Caddy (`Caddyfile.jenkins`), Multibranch and Forgejo webhooks, external agents, and the "needs 4 GB" sizing under load | Controller plus one trivial build only. The `acme_ca` pin added to `Caddyfile.jenkins` was adapted but never served |
| `mirror-from-github.sh` against github.com, with `--lfs`, and with an organisation of more than one page of repositories | Needs a GitHub token |
| Docker Desktop's engine, macOS, and running as a non-root user in the `docker` group | Every run above used WSL's engine as root, and both the QEMU guest and the Lightsail instance ran everything as root, so the `chown` fallback in `register-runner.sh` was never taken |
| Upgrades between pinned image versions, and restores of a database larger than a few MB | Not attempted |
| Anything under sustained real multi-user load | Not checked. The load test above used scripted users and synthetic repositories on one instance at a time |
| Hosts and runners beyond what was named | No `medium_3_0`, `large_3_0` or other forge host was tested, and no compute-optimized plan above `c_large_1_0`. No CI job ran on any compute-optimized plan. A separate runner machine was not built. The per-developer and monthly figures for them are calculations |
| A build of our own on the kit | Not run. The only real build was a public open-source TypeScript monorepo. How much memory and CPU a production monorepo build needs is unmeasured, so the 4 GB floor for heavier builds is still an assumption |
| Beyond the load test's limits | Nothing past 152 minutes on any instance, nothing after stopping and starting an instance (whether the unthrottled first hour comes back is unknown), and no CPU-weight or priority setting for the build container as a way to protect the forge's pages |
| The forge as a real user would see it | No Caddy and no TLS in the load test, page timings from a remote browser only for a few small windows (idle, and one build), not for whole jobs, no transfer billing for checkouts through the public URL, no backup run under load, and no repository made of many small unpacked pushes |

## License

[MIT](LICENSE). Free to use, modify and redistribute, including commercially, with the
copyright notice kept. No warranty — read the verification table above before you trust any
of it with something that matters.
