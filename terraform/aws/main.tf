# AWS topology: one Lightsail instance with a static IP, a firewall, a private
# S3 bucket for encrypted backups, and an IAM user that can touch only that bucket.
#
# Why Lightsail and not EC2: a flat, predictable monthly price with transfer
# included, and no VPC, NAT or EBS line items to forget about. Why S3 and not
# Lightsail's own object storage: S3 has object versioning, lifecycle rules down to
# Glacier Instant Retrieval, and per-prefix IAM, which the backup design needs.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}

locals {
  bundle_defaults = {
    forgejo = "small_3_0"  # 2 GB RAM, 2 vCPU
    jenkins = "medium_3_0" # 4 GB RAM, 2 vCPU
  }
  bundle_id   = coalesce(var.bundle_id, local.bundle_defaults[var.ci_engine])
  bucket_name = coalesce(var.bucket_name, "${var.name}-backups-${random_id.suffix.hex}")
  tags        = merge({ Project = "sovereign-forge", ManagedBy = "terraform" }, var.tags)
}

resource "random_id" "suffix" {
  byte_length = 4
}

module "common" {
  source = "../modules/common"

  kit_root      = abspath("${path.root}/../..")
  forge_host    = var.forge_host
  admin_email   = var.admin_email
  admin_user    = var.admin_user
  ci_engine     = var.ci_engine
  jenkins_host  = var.jenkins_host
  age_recipient = var.age_recipient

  backup_remote = "forge:${local.bucket_name}"
  # The Lightsail host has no instance role, so it needs one narrowly scoped key.
  backup_env = {
    RCLONE_CONFIG_FORGE_TYPE              = "s3"
    RCLONE_CONFIG_FORGE_PROVIDER          = "AWS"
    RCLONE_CONFIG_FORGE_REGION            = var.region
    RCLONE_CONFIG_FORGE_ACCESS_KEY_ID     = aws_iam_access_key.backup.id
    RCLONE_CONFIG_FORGE_SECRET_ACCESS_KEY = aws_iam_access_key.backup.secret
    RCLONE_CONFIG_FORGE_NO_CHECK_BUCKET   = "true"
  }

  remote_keep_daily      = var.remote_keep_daily
  weekly_transition_days = var.weekly_transition_days
  weekly_expire_days     = var.weekly_expire_days
  noncurrent_expire_days = var.noncurrent_expire_days
}

# ---------------------------------------------------------------- compute

resource "aws_lightsail_key_pair" "forge" {
  name       = "${var.name}-key"
  public_key = var.ssh_public_key
}

resource "aws_lightsail_instance" "forge" {
  name              = var.name
  availability_zone = coalesce(var.availability_zone, "${var.region}a")
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = local.bundle_id
  key_pair_name     = aws_lightsail_key_pair.forge.name
  ip_address_type   = "ipv4"
  user_data         = module.common.launch_script
  tags              = local.tags

  lifecycle {
    # user_data only runs on first boot; editing it must not replace a live forge.
    ignore_changes = [user_data]

    precondition {
      condition     = module.common.launch_script_bytes <= 14000
      error_message = "Rendered cloud-init exceeds the 14000-byte budget (Lightsail rejects user-data somewhere between 14,500 and 14,950 bytes). Trim the shipped files or use a shorter forge_host/age_recipient."
    }
  }
}

resource "aws_lightsail_static_ip" "forge" {
  name = "${var.name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "forge" {
  static_ip_name = aws_lightsail_static_ip.forge.name
  instance_name  = aws_lightsail_instance.forge.name

  # Replacing the instance detaches the IP and resets the firewall; redo both.
  lifecycle {
    replace_triggered_by = [aws_lightsail_instance.forge.id]
  }
}

# Declarative: this resource REPLACES all rules on the instance with exactly these.
resource "aws_lightsail_instance_public_ports" "forge" {
  instance_name = aws_lightsail_instance.forge.name

  lifecycle {
    replace_triggered_by = [aws_lightsail_instance.forge.id]
  }

  port_info {
    protocol  = "tcp"
    from_port = module.common.ports.ssh_admin.port
    to_port   = module.common.ports.ssh_admin.port
    cidrs     = var.admin_cidrs
  }
  port_info {
    protocol  = "tcp"
    from_port = module.common.ports.http_acme.port
    to_port   = module.common.ports.http_acme.port
    cidrs     = ["0.0.0.0/0"]
  }
  port_info {
    protocol  = "tcp"
    from_port = module.common.ports.https.port
    to_port   = module.common.ports.https.port
    cidrs     = ["0.0.0.0/0"]
  }
  port_info {
    protocol  = "udp"
    from_port = module.common.ports.https.port
    to_port   = module.common.ports.https.port
    cidrs     = ["0.0.0.0/0"]
  }
  port_info {
    protocol  = "tcp"
    from_port = module.common.ports.git_ssh.port
    to_port   = module.common.ports.git_ssh.port
    cidrs     = var.git_ssh_cidrs
  }
}

# ---------------------------------------------------------------- backup storage

resource "aws_s3_bucket" "backup" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy_bucket
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning is the ransomware control: the backup key can delete an object, but
# the delete only adds a marker, and the key has no right to remove versions.
resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket     = aws_s3_bucket.backup.id
  depends_on = [aws_s3_bucket_versioning.backup]

  # Weekly copies are the long-term tier: cheap Glacier Instant Retrieval, still
  # readable in milliseconds for a restore drill.
  rule {
    id     = "weekly-to-glacier-ir"
    status = "Enabled"
    filter {
      prefix = module.common.retention.weekly_prefix
    }
    transition {
      days          = module.common.retention.weekly_transition_days
      storage_class = "GLACIER_IR"
    }
    expiration {
      days = module.common.retention.weekly_expire_days
    }
    noncurrent_version_expiration {
      noncurrent_days = module.common.retention.noncurrent_expire_days
    }
  }

  # Daily objects are pruned by backup.sh; this rule cleans up what pruning leaves behind.
  rule {
    id     = "daily-noncurrent-cleanup"
    status = "Enabled"
    filter {
      prefix = module.common.retention.daily_prefix
    }
    noncurrent_version_expiration {
      noncurrent_days = module.common.retention.noncurrent_expire_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }

  rule {
    id     = "expired-delete-markers"
    status = "Enabled"
    filter {}
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  bucket     = aws_s3_bucket.backup.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.backup]
}

# ---------------------------------------------------------------- scoped identity

resource "aws_iam_user" "backup" {
  name = "${var.name}-backup"
  path = "/sovereign-forge/"
  tags = local.tags
}

data "aws_iam_policy_document" "backup" {
  statement {
    sid       = "ListAndLocateBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.backup.arn]
  }
  statement {
    sid = "DailyReadWritePrune"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion", # rclone reads a just-written object back by versionId on a versioned bucket
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.backup.arn}/daily/*"]
  }
  # No DeleteObject here: weekly copies expire by lifecycle only. No DeleteObjectVersion
  # anywhere, and no bucket-level administration (versioning, lifecycle, policy).
  statement {
    sid = "WeeklyReadWriteOnly"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion", # rclone reads a just-written object back by versionId on a versioned bucket
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.backup.arn}/weekly/*"]
  }
}

resource "aws_iam_user_policy" "backup" {
  name   = "forge-backup-bucket-only"
  user   = aws_iam_user.backup.name
  policy = data.aws_iam_policy_document.backup.json
}

resource "aws_iam_access_key" "backup" {
  user = aws_iam_user.backup.name
}
