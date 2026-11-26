output "forge_host" {
  description = "The DNS name you configured."
  value       = var.forge_host
}

output "public_ip" {
  description = "Create a DNS A record from forge_host (and jenkins_host) to this address."
  value       = aws_lightsail_static_ip.forge.ip_address
}

output "ssh_target" {
  description = "user@host for ssh (default Lightsail Ubuntu user)."
  value       = "ubuntu@${aws_lightsail_static_ip.forge.ip_address}"
}

output "ci_engine" {
  value = var.ci_engine
}

output "bucket" {
  description = "Backup bucket."
  value       = aws_s3_bucket.backup.bucket
}

output "bundle_id" {
  value = local.bundle_id
}

output "user_data_bytes" {
  description = "Rendered cloud-init size; Lightsail rejects more than about 14,600 (measured), despite its 16 KB documentation."
  value       = module.common.launch_script_bytes
  # The rendered user-data embeds the backup key, so Terraform taints even its length as sensitive.
  sensitive = true
}

# Needed only to rotate the key on the host (RUNBOOK.md, "Rotate"). Sensitive: it is
# also in Terraform state, so keep the state private (encrypted remote backend).
output "backup_access_key_id" {
  value     = aws_iam_access_key.backup.id
  sensitive = true
}

output "backup_secret_access_key" {
  value     = aws_iam_access_key.backup.secret
  sensitive = true
}
