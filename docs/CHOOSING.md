# Choosing

Two decisions: which CI to run, and where to use a cloud vendor's feature versus the portable option.

## Forgejo Actions, Jenkins, or staying on GitHub Free

| | Forgejo Actions (default) | Jenkins | Stay on GitHub Free |
|---|---|---|---|
| Workflow format | GitHub-Actions-compatible YAML | Jenkinsfile (Groovy) and plugin configuration | GitHub Actions YAML |
| Moving existing GitHub workflows | Copy the files; fix the exceptions listed in [MIGRATION.md](../MIGRATION.md) | Rewrite every workflow | Nothing to move |
| Runtime | One Go binary (the runner) plus a Docker-in-Docker sidecar | A JVM service plus plugins | Hosted by GitHub, or your self-hosted runner |
| Smallest sensible instance | 2 GB (Lightsail `small_3_0`, Azure `Standard_B1ms`) | 4 GB (Lightsail `medium_3_0`, Azure `Standard_B2s`) | None |
| Maintenance you own | Forgejo, runner, Postgres, Caddy | All of those minus the runner, plus the controller and every plugin | None |
| Ecosystem | Most popular Actions work; some do not (artifact v4, OIDC) | Very large plugin catalogue, decades of integrations | The largest Actions marketplace; Dependabot, code scanning, Copilot |
| Fits when | You want GitHub-like CI on your own box | You already have Jenkinsfiles, or depend on plugins with no Actions equivalent | The ecosystem matters more than ownership and no one wants to run a server |

### Why Forgejo Actions is the default

Forgejo Actions consumes GitHub-Actions-compatible workflow YAML, so existing `.github/workflows` files port with little or no change. We have a concrete reason to care. In one of our repositories, more than 400 GitHub Actions runs have ended in `startup_failure` since 2026-04-25 with no job created: run creation is refused upstream of the workflow file, so no job has started there since, and a four-line `echo ok` workflow fails the same way. Under Forgejo Actions the same YAML should get a runner and run; we have not yet tested that migration. That is a migration argument Jenkins cannot match, because Jenkins would need every workflow rewritten.

Jenkins is a JVM service. It has a real memory floor and a plugin-update cadence that you take on: the controller wants a heap of its own (the kit caps it at 1 GB inside a 2 GB container limit), and its plugins carry a steady stream of security advisories. The Forgejo Actions runner is a single Go binary that sits idle at a small fraction of that. On the same machine budget that is the difference between a 2 GB and a 4 GB instance. Those sizes are reasoned starting points, not benchmarks.

None of this is a case against Jenkins. For a team with existing Jenkinsfiles, shared libraries, or plugins that integrate with systems you cannot replace (specific artifact stores, mainframes, test-lab hardware, approval workflows), Jenkins is the right answer and this kit ships a working path for it (`ci_engine = "jenkins"`). If that describes you, choose it and size the instance accordingly. The Forgejo side is identical either way.

### Why you might stay on GitHub Free

- Your workflows depend on GitHub's ecosystem: marketplace Actions that talk to GitHub's APIs, Dependabot, code scanning, Copilot, GitHub Apps.
- You collaborate with outside contributors who already have GitHub accounts and expect forks and pull requests there.
- Nobody on the team wants to be the person who patches the forge, tests the restore, and is awake when it is down.
- You do not mind per-minute limits and the lack of some controls on the free plan. For reference, in our experience a GitHub Free organisation with private repositories has no branch protection, so a passing status check is information rather than a gate. Check the plan's current terms before deciding; they change.

If any of those is true, the honest recommendation is to stay, perhaps adding a self-hosted runner or just a nightly mirror of your repositories to somewhere you control. This kit is for the case where owning the forge is worth the chore.

## Vendor feature or portable option

The rule we applied: **use the managed service where it is genuinely cheaper or safer than what you would build; use the portable option where the managed one is lock-in dressed as convenience.** Moving a self-hosted forge between clouds should cost a restore, not a rewrite.

| Concern | What we used | Why |
|---|---|---|
| **Object storage for backups** | **Vendor-managed**: S3 or Blob | The clear case for managed. Off-box and durable by default, versioning and lifecycle tiering built in, priced per gigabyte with nothing to operate. Self-hosting object storage means running a second service on a disk that fails with the machine it is meant to protect. The lock-in is small, because the only code that touches it is `rclone`, and the same script talks to any S3-compatible or Azure store. |
| **Backup tool** | **Portable**: `rclone` | One tool and one script for S3, Blob, Backblaze, Wasabi, SFTP or a local disk. The cloud CLIs (`aws s3`, `azcopy`) would have meant two scripts that drift apart. |
| **Encryption** | **Portable**: client-side `age` | The provider's server-side encryption is enabled as defence in depth, but it is not the control: the provider holds those keys. With age the provider only ever sees ciphertext, and the same backups restore anywhere. |
| **Compute** | **Plain VM**, Docker Compose | Not ECS, Fargate, Container Apps, ACI, AKS or EKS. A single stateful forge does not need an orchestrator, and each of those adds a bill, an API to learn and a place your configuration cannot follow you from. The cloud-init file is the entire machine. |
| **AWS VM flavour** | Lightsail | A flat price with transfer included, and no VPC, NAT gateway or volume line items to misread. It is still just an Ubuntu VM, so the lock-in is the Terraform file. The cost is that Lightsail instances cannot assume IAM roles, which is why the AWS path stores one scoped key. |
| **Database** | **Portable**: PostgreSQL in a container | Not RDS or Azure Database. A managed database costs more than the rest of this machine, and a `pg_dump` in the backup is the same on every provider. The trade-off is yours: no managed point-in-time recovery, no automatic failover. |
| **TLS** | **Portable**: Caddy and Let's Encrypt | Not ACM with a load balancer, or Front Door with Application Gateway. Those need a cloud load balancer in front, which is a recurring charge and a thing to migrate. |
| **Identity of the backup writer** | **Vendor-managed where it removes a secret** | On Azure the VM has a managed identity, so there is no credential on the host at all. We use it because there is no portable equivalent that is better. On AWS the identity is an IAM user with a key scoped to one bucket, because Lightsail offers nothing better. |
| **Firewall** | **Vendor-managed**, plus ufw | The network-level firewall belongs to the cloud, because Docker publishes ports around host firewalls. ufw is a second layer for host services. |
| **DNS** | **Not automated** | Neither `route53` nor `azurerm_dns` is wired in, because most people's DNS lives elsewhere and a Terraform mistake in a production zone is a bad day. You create one A record. |
| **Secrets** | **Generated on the host** | Not Secrets Manager or Key Vault. The database password and Forgejo's `SECRET_KEY` never leave the machine, never enter Terraform state, and cost nothing to store. If you already run a secret store, integrate it for the few values you have. |
| **Monitoring** | **None bundled** | CloudWatch or Azure Monitor agents would tie the host to one vendor. `verify.sh` and the journal are the baseline; add the tool you already use. |

### When to deviate

- **You are on a restricted network** and cannot reach a public object store: point `BACKUP_REMOTE` at SFTP or a self-hosted S3 (MinIO), and accept that you now own durability.
- **Compliance dictates the key store**: swap `AGE_RECIPIENT` for a KMS-backed workflow. The script's contract (encrypt before it leaves, verify by reading back) stays the same.
- **You need high availability**: this design is the wrong shape. You want an orchestrator and a managed database, and a different document.
