# Everything the two clouds must agree on lives here: the firewall design, the
# object-storage retention design, and the cloud-init that provisions the host.
# The AWS and Azure roots only translate these into vendor resources, so the two
# stay honest about being the same machine.
#
# This module declares no providers and creates no resources.

terraform {
  required_version = ">= 1.5.0"
}

variable "kit_root" {
  description = "Path to the root of this repository (so the module can read compose/, scripts/, cloud-init/)."
  type        = string
}

variable "forge_host" {
  description = "Public DNS name of the forge, e.g. forge.example.com. Its A record must point at the instance."
  type        = string
}

variable "admin_email" {
  description = "Contact address for Let's Encrypt and the forge's first administrator."
  type        = string
}

variable "admin_user" {
  description = "Username of the first forge administrator."
  type        = string
  default     = "forgeadmin"
}

variable "ci_engine" {
  description = "forgejo (Forgejo Actions runner) or jenkins."
  type        = string
  default     = "forgejo"
  validation {
    condition     = contains(["forgejo", "jenkins"], var.ci_engine)
    error_message = "ci_engine must be \"forgejo\" or \"jenkins\"."
  }
}

variable "jenkins_host" {
  description = "Public DNS name for Jenkins. Required when ci_engine is jenkins."
  type        = string
  default     = ""
  validation {
    condition     = var.ci_engine != "jenkins" || var.jenkins_host != ""
    error_message = "jenkins_host is required when ci_engine is \"jenkins\"."
  }
}

variable "age_recipient" {
  description = "age PUBLIC key that backups are encrypted to. The matching private key never goes on the host."
  type        = string
  validation {
    condition     = startswith(var.age_recipient, "age1")
    error_message = "age_recipient must be an age public key (starts with age1)."
  }
}

variable "backup_remote" {
  description = "rclone path of the backup target, e.g. forge:my-bucket."
  type        = string
}

variable "backup_env" {
  description = "Extra KEY=VALUE settings for /etc/forge/backup.env (the rclone remote definition and any credentials)."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "remote_keep_daily" {
  description = "How many daily backup sets the script keeps on the remote."
  type        = number
  default     = 7
}

variable "ssh_public_port" {
  description = "Public TCP port for git over SSH (the host's own sshd stays on 22)."
  type        = number
  default     = 2222
}

variable "weekly_transition_days" {
  description = "Days before objects under weekly/ move to the cold storage class."
  type        = number
  default     = 30
}

variable "weekly_expire_days" {
  description = "Days before objects under weekly/ are deleted."
  type        = number
  default     = 365
}

variable "noncurrent_expire_days" {
  description = "Days a deleted or overwritten backup stays recoverable (versioning / soft delete window)."
  type        = number
  default     = 14
}

locals {
  root = var.kit_root

  # Source files shipped to the host. Destination, mode. restore.sh, verify.sh and
  # mirror-from-github.sh run elsewhere (your laptop) and are not shipped.
  static_files = concat(
    [
      { src = "compose/docker-compose.forgejo.yml", dst = "/opt/forge/compose/docker-compose.forgejo.yml", mode = "0644" },
      { src = "compose/docker-compose.caddy.yml", dst = "/opt/forge/compose/docker-compose.caddy.yml", mode = "0644" },
      { src = "compose/.env.example", dst = "/opt/forge/compose/.env.example", mode = "0644" },
      { src = "compose/caddy/Caddyfile.forgejo", dst = "/opt/forge/compose/caddy/Caddyfile.forgejo", mode = "0644" },
      { src = "scripts/lib.sh", dst = "/opt/forge/scripts/lib.sh", mode = "0644" },
      { src = "scripts/gen-env.sh", dst = "/opt/forge/scripts/gen-env.sh", mode = "0755" },
      { src = "scripts/forge-compose.sh", dst = "/opt/forge/scripts/forge-compose.sh", mode = "0755" },
      { src = "scripts/register-runner.sh", dst = "/opt/forge/scripts/register-runner.sh", mode = "0755" },
      { src = "scripts/backup.sh", dst = "/opt/forge/scripts/backup.sh", mode = "0755" },
      { src = "cloud-init/bootstrap.sh", dst = "/opt/forge/cloud-init/bootstrap.sh", mode = "0755" },
      { src = "cloud-init/forge-backup.service", dst = "/etc/systemd/system/forge-backup.service", mode = "0644" },
      { src = "cloud-init/forge-backup.timer", dst = "/etc/systemd/system/forge-backup.timer", mode = "0644" },
      { src = "cloud-init/forge-metadata-block.service", dst = "/etc/systemd/system/forge-metadata-block.service", mode = "0644" },
    ],
    var.ci_engine == "jenkins" ? [
      { src = "compose/docker-compose.jenkins.yml", dst = "/opt/forge/compose/docker-compose.jenkins.yml", mode = "0644" },
      { src = "compose/caddy/Caddyfile.jenkins", dst = "/opt/forge/compose/caddy/Caddyfile.jenkins", mode = "0644" },
    ] : []
  )

  forge_env = join("\n", [
    "FORGE_HOST=${var.forge_host}",
    "ADMIN_EMAIL=${var.admin_email}",
    "ADMIN_USER=${var.admin_user}",
    "CI_ENGINE=${var.ci_engine}",
    "WITH_CADDY=true",
    "JENKINS_HOST=${var.jenkins_host}",
    "SSH_PUBLIC_PORT=${var.ssh_public_port}",
    "DATA_DIR=/opt/forge/data",
    "",
  ])

  backup_env = join("\n", concat(
    [
      "AGE_RECIPIENT=${var.age_recipient}",
      "BACKUP_REMOTE=${var.backup_remote}",
      "REMOTE_KEEP=${var.remote_keep_daily}",
    ],
    [for k in sort(keys(nonsensitive(var.backup_env))) : "${k}=${nonsensitive(var.backup_env)[k]}"],
    [""],
  ))

  # One text bundle, one gzip stream: much smaller than gzipping each file alone,
  # which matters because Lightsail caps user-data at 16 KB. forge-unpack (written
  # by the cloud-config template) splits it back into files on the host.
  bundle = join("", concat(
    [for f in local.static_files : "#@@FILE ${f.dst} ${f.mode}\n${trimsuffix(file("${local.root}/${f.src}"), "\n")}\n"],
    [
      "#@@FILE /etc/forge/forge.env 0644\n${local.forge_env}\n",
      "#@@FILE /etc/forge/backup.env 0600\n${local.backup_env}\n",
    ]
  ))
}

# Ports every topology exposes. The vendor roots turn this into their own
# firewall syntax. Port 22 is the host sshd and is limited to admin CIDRs;
# 3000 (HTTP) and 5432 (PostgreSQL) are deliberately absent: they never leave
# the machine.
output "ports" {
  description = "Public port design shared by both clouds."
  value = {
    ssh_admin = { port = 22, scope = "admin" }
    http_acme = { port = 80, scope = "public" }
    https     = { port = 443, scope = "public" }
    git_ssh   = { port = var.ssh_public_port, scope = "git" }
  }
}

output "retention" {
  description = "Object-storage retention design shared by both clouds."
  value = {
    daily_prefix           = "daily/"
    weekly_prefix          = "weekly/"
    weekly_transition_days = var.weekly_transition_days
    weekly_expire_days     = var.weekly_expire_days
    noncurrent_expire_days = var.noncurrent_expire_days
  }
}

output "user_data" {
  description = "Rendered cloud-config (contains the backup credentials on AWS)."
  sensitive   = true
  value = templatefile("${local.root}/cloud-init/cloud-init.yaml.tftpl", {
    bundle_b64gz = base64gzip(local.bundle)
  })
}

output "user_data_bytes" {
  description = "Size of the rendered user-data in bytes (Lightsail caps it at 16384)."
  value       = length(templatefile("${local.root}/cloud-init/cloud-init.yaml.tftpl", { bundle_b64gz = base64gzip(local.bundle) }))
}
