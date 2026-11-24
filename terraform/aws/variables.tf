variable "region" {
  description = "AWS region for Lightsail and the bucket."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Lightsail availability zone. Defaults to <region>a."
  type        = string
  default     = null
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "sovereign-forge"
}

variable "forge_host" {
  description = "Public DNS name for the forge (e.g. forge.example.com). Create an A record to the output public_ip."
  type        = string
}

variable "admin_email" {
  description = "Let's Encrypt contact and first forge administrator."
  type        = string
}

variable "admin_user" {
  description = "First forge administrator username."
  type        = string
  default     = "forgeadmin"
}

variable "ci_engine" {
  description = "forgejo (default) or jenkins."
  type        = string
  default     = "forgejo"
  validation {
    condition     = contains(["forgejo", "jenkins"], var.ci_engine)
    error_message = "ci_engine must be \"forgejo\" or \"jenkins\"."
  }
}

variable "jenkins_host" {
  description = "Public DNS name for Jenkins; required when ci_engine = \"jenkins\"."
  type        = string
  default     = ""
}

variable "bundle_id" {
  description = "Lightsail bundle. Default: small_3_0 (2 GB) for Forgejo Actions, medium_3_0 (4 GB) for Jenkins."
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "Your SSH PUBLIC key (the line from the .pub file). Imported into Lightsail."
  type        = string
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the host sshd on port 22. Restrict this to your own address."
  type        = list(string)
  validation {
    condition     = length(var.admin_cidrs) > 0 && !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "admin_cidrs must be non-empty and must not be 0.0.0.0/0; list your own address, e.g. [\"203.0.113.7/32\"]."
  }
}

variable "git_ssh_cidrs" {
  description = "CIDRs allowed to push and pull over git SSH (port 2222)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "age_recipient" {
  description = "age PUBLIC key for backup encryption (output of: age-keygen -y identity.txt). Keep the private key off this host."
  type        = string
}

variable "bucket_name" {
  description = "Backup bucket name. Default: <name>-backups-<random>."
  type        = string
  default     = null
}

variable "force_destroy_bucket" {
  description = "Allow terraform destroy to delete a bucket that still holds backups. Leave false: it is a safety interlock."
  type        = bool
  default     = false
}

variable "remote_keep_daily" {
  description = "Daily backup sets kept on the remote."
  type        = number
  default     = 7
}

variable "weekly_transition_days" {
  description = "Days before weekly/ objects move to Glacier Instant Retrieval."
  type        = number
  default     = 30
}

variable "weekly_expire_days" {
  description = "Days before weekly/ objects are deleted."
  type        = number
  default     = 365
}

variable "noncurrent_expire_days" {
  description = "Recovery window for deleted or overwritten backups."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
