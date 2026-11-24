output "forge_host" {
  description = "The DNS name you configured."
  value       = var.forge_host
}

output "public_ip" {
  description = "Create a DNS A record from forge_host (and jenkins_host) to this address."
  value       = azurerm_public_ip.forge.ip_address
}

output "ssh_target" {
  description = "user@host for ssh."
  value       = "azureuser@${azurerm_public_ip.forge.ip_address}"
}

output "ci_engine" {
  value = var.ci_engine
}

output "storage_account" {
  value = azurerm_storage_account.backup.name
}

output "container" {
  value = azurerm_storage_container.backup.name
}

output "vm_size" {
  value = local.vm_size
}

output "user_data_bytes" {
  description = "Rendered cloud-init size (Azure custom_data limit is 65536 before base64)."
  value       = module.common.user_data_bytes
}
