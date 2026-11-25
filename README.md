# sovereign-forge

A self-hosted Git forge and CI that you can stand up on a small cloud VM, or on a machine you own, with one command. It packages [Forgejo](https://forgejo.org) for private repositories, a CI runner beside it, and encrypted nightly off-site backups with a restore drill. It grew out of our own setup, a snapshot copy of our repositories on hardware we own with encrypted nightly backups, but this repository has not yet been deployed end to end; see [Verification status](#verification-status) for exactly what has and has not been tested.

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

These sizes are reasoned starting points, not benchmarks. We have not load-tested the kit. Watch memory and swap for a week on your own workload, and set `bundle_id` or `vm_size` accordingly. The reasoning for the default is in [docs/CHOOSING.md](docs/CHOOSING.md).

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
- **The runner shares a machine with the forge.** CI jobs run in a Docker-in-Docker sidecar, which is isolation, not a security boundary. Do not run untrusted pull requests on it. Put the runner on its own machine for anything public. See the threat model in [ARCHITECTURE.md](ARCHITECTURE.md).
- **No monitoring or alerting stack.** `verify.sh`, systemd and the journal are what you get. A failed backup is a log line and a stale timestamp, not a page. Wire it to whatever you already use.
- **No outbound email.** SMTP is not configured, so there are no notification mails or password-reset links until you set it up in Forgejo.
- **No SSO, LDAP, or SAML.** Local accounts only. Self-registration is off.
- **No DNS automation.** You create the A record. That keeps the kit vendor-neutral and means a typo cannot take over a zone.
- **Jenkins has no agents.** The controller runs builds on its built-in node, which is fine for trusted private repositories and wrong for anything else.
- **Containers are not auto-updated.** Image tags and digests are pinned on purpose. The operating system patches itself; Forgejo, Postgres, Caddy and the runner are upgraded by you ([RUNBOOK.md](RUNBOOK.md#upgrade)).
- **Windows and macOS runners, container registry hosting, package registries, and Pages** are outside the scope of the default setup.
- **`make local` has no TLS.** It listens on plain HTTP at `http://localhost:3000`, bound to loopback.

## Verification status

What was checked, and what was not. Update this section when you test it somewhere new.

Environment of the 2026-11-24 run: Windows 11, WSL2 Ubuntu 26.04 (bash 5.3.9, GNU Make 4.4.1, Docker Engine 29.1.3 and Compose 2.40.3 from WSL's own engine, run as root), rclone 1.76.0, age 1.2.1. Images as pinned in `compose/`: Forgejo 15.0.12, PostgreSQL 16.16, runner 13.2.2, Docker-in-Docker 27.5.1.

| Checked | How |
|---|---|
| `terraform fmt` and `terraform validate` clean for `aws/` and `azure/` | Terraform 1.17.2, providers aws 5.100.0, azurerm 4.81.0, random 3.9.1. Also run as the `terraform` job of the kit's own CI, on the runner this kit deploys: passed |
| Compose files parse and merge correctly for the local, cloud and Jenkins layouts, with the right profiles active | `docker compose config` (no containers started) |
| Rendered cloud-init: size under Lightsail's 16 KB limit, bundle unpacks byte-for-byte | Rendered with Terraform, decoded and diffed |
| `make local` from an empty machine: Forgejo, PostgreSQL, Docker-in-Docker and the runner all up and healthy | `make local` exit 0 in about 70 s with a cold image cache, no Caddy |
| First administrator, API token, push and clone over HTTP and over SSH (port 2222) | The command `make local` prints, then `git push` / `git clone` against `localhost:3000` and `localhost:2222` |
| Forgejo Actions: a workflow runs on the runner, including `actions/checkout` | Two workflows pushed to a test repository, both succeeded. The kit's own `.forgejo/workflows/ci.yml` also passes both jobs (hygiene, with shellcheck 0.9.0 from Debian, and terraform) |
| `backup.sh` against real containers | Both artifacts built and encrypted, uploaded, read back and size/md5 verified, daily and weekly copies, to an rclone `local` remote |
| `restore.sh` drill, daily and weekly tiers, `--extract-to`, and failure with the wrong key | Run against that backup |
| Full restore per [RUNBOOK.md](RUNBOOK.md#full-restore) onto a fresh stack with newly generated secrets | Repository, branches, tag, issue and API token survived, `git fsck` clean, push works after `regenerate hooks`, runner re-registered per step 7 |
| `make destroy CLOUD=local PURGE=1`, then `make local` again | Containers, volumes and the runner registration are gone and the next `make local` registers a new runner |
| `mirror-from-github.sh`: dry run, mirror, re-run, archived repositories skipped, pull-request refs preserved | Against a stubbed GitHub API and local file origins, into the real local Forgejo. Not against github.com |
| `shellcheck` on `scripts/` and `cloud-init/bootstrap.sh` | Clean with shellcheck 0.11.0 (container) and 0.9.0 (the version the CI job installs from Debian bookworm) |
| Secret tripwire catches keys, private addresses and valued env files, and no longer prints the secret it found | `scripts/check-no-secrets.sh`, positive and negative |

| **Not** checked | |
|---|---|
| Any `terraform apply`, any real AWS or Azure resource | Nothing here has been deployed from this repository |
| Caddy and TLS (`WITH_CADDY=true`), Let's Encrypt issuance | `make local` runs without Caddy |
| `bootstrap.sh` on a real Ubuntu 24.04 host, the cloud-init first boot, the backup systemd timer | Needs a live host |
| Jenkins (`CI_ENGINE=jenkins`) | No Jenkins container was started |
| `verify.sh` (both halves), `forgectl.sh deploy` and `destroy` for aws and azure | Needs a live cloud host |
| The S3 and Azure Blob code paths of `backup.sh` | Exercised only through rclone's local backend; the "remote reports no checksum" branch was exercised with `VERIFY_FULL=1` in an earlier run with `docker` stubbed |
| `mirror-from-github.sh` against github.com, with `--lfs`, and with an organisation of more than one page of repositories | Needs a GitHub token |
| Docker Desktop's engine, macOS, and running as a non-root user in the `docker` group | The run above used WSL's engine as root, so the `chown` fallback in `register-runner.sh` was not taken |
| Upgrades between pinned image versions, restores of a database larger than a few MB, and anything under load | Not attempted. The instance sizes above are still reasoned, not measured |

## License

[MIT](LICENSE). Free to use, modify and redistribute, including commercially, with the
copyright notice kept. No warranty — read the verification table above before you trust any
of it with something that matters.
