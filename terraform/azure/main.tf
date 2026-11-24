# Azure topology: one small burstable Linux VM, an NSG, a Blob container for
# encrypted backups, and a managed identity scoped to that one container.
#
# The design matches terraform/aws: same cloud-init, same ports, same daily/ and
# weekly/ prefixes, same retention numbers. The one deliberate difference is the
# credential model. Azure lets a VM carry an identity, so the host needs NO
# stored storage secret at all; rclone authenticates with the VM's managed identity.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

locals {
  size_defaults = {
    forgejo = "Standard_B1ms" # 1 vCPU, 2 GB
    jenkins = "Standard_B2s"  # 2 vCPU, 4 GB
  }
  vm_size       = coalesce(var.vm_size, local.size_defaults[var.ci_engine])
  account_name  = coalesce(var.storage_account_name, "${substr(replace(lower(var.name), "/[^a-z0-9]/", ""), 0, 16)}${random_string.suffix.result}")
  container     = "forge-backups"
  tags          = merge({ Project = "sovereign-forge", ManagedBy = "terraform" }, var.tags)
  admin_account = "azureuser"
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
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

  backup_remote = "forge:${local.container}"
  # No credentials: the VM's system-assigned identity is granted the container.
  backup_env = {
    RCLONE_CONFIG_FORGE_TYPE               = "azureblob"
    RCLONE_CONFIG_FORGE_ACCOUNT            = local.account_name
    RCLONE_CONFIG_FORGE_USE_MSI            = "true"
    RCLONE_CONFIG_FORGE_NO_CHECK_CONTAINER = "true"
  }

  remote_keep_daily      = var.remote_keep_daily
  weekly_transition_days = var.weekly_transition_days
  weekly_expire_days     = var.weekly_expire_days
  noncurrent_expire_days = var.noncurrent_expire_days
}

# ---------------------------------------------------------------- network

resource "azurerm_resource_group" "forge" {
  name     = "${var.name}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "forge" {
  name                = "${var.name}-vnet"
  location            = azurerm_resource_group.forge.location
  resource_group_name = azurerm_resource_group.forge.name
  address_space       = ["10.42.0.0/24"]
  tags                = local.tags
}

resource "azurerm_subnet" "forge" {
  name                 = "forge"
  resource_group_name  = azurerm_resource_group.forge.name
  virtual_network_name = azurerm_virtual_network.forge.name
  address_prefixes     = ["10.42.0.0/26"]
}

resource "azurerm_public_ip" "forge" {
  name                = "${var.name}-ip"
  location            = azurerm_resource_group.forge.location
  resource_group_name = azurerm_resource_group.forge.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_security_group" "forge" {
  name                = "${var.name}-nsg"
  location            = azurerm_resource_group.forge.location
  resource_group_name = azurerm_resource_group.forge.name
  tags                = local.tags

  security_rule {
    name                       = "ssh-admin"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(module.common.ports.ssh_admin.port)
    source_address_prefixes    = var.admin_cidrs
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "http-acme"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(module.common.ports.http_acme.port)
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "https-tcp"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(module.common.ports.https.port)
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "https-udp"
    priority                   = 121
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = tostring(module.common.ports.https.port)
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "git-ssh"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = tostring(module.common.ports.git_ssh.port)
    source_address_prefixes    = var.git_ssh_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "forge" {
  name                = "${var.name}-nic"
  location            = azurerm_resource_group.forge.location
  resource_group_name = azurerm_resource_group.forge.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.forge.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.forge.id
  }
}

resource "azurerm_network_interface_security_group_association" "forge" {
  network_interface_id      = azurerm_network_interface.forge.id
  network_security_group_id = azurerm_network_security_group.forge.id
}

# ---------------------------------------------------------------- compute

resource "azurerm_linux_virtual_machine" "forge" {
  name                            = var.name
  location                        = azurerm_resource_group.forge.location
  resource_group_name             = azurerm_resource_group.forge.name
  size                            = local.vm_size
  admin_username                  = local.admin_account
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.forge.id]
  custom_data                     = base64encode(module.common.user_data)
  tags                            = local.tags

  admin_ssh_key {
    username   = local.admin_account
    public_key = var.ssh_public_key
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = var.os_disk_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    # custom_data only runs on first boot; editing it must not replace a live forge.
    ignore_changes = [custom_data]
  }
}

# ---------------------------------------------------------------- backup storage

resource "azurerm_storage_account" "backup" {
  name                            = local.account_name
  resource_group_name             = azurerm_resource_group.forge.name
  location                        = azurerm_resource_group.forge.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  access_tier                     = "Hot"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags

  # Versioning plus soft delete is the ransomware control: a delete from the host
  # leaves a recoverable version for noncurrent_expire_days.
  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = module.common.retention.noncurrent_expire_days
    }
    container_delete_retention_policy {
      days = module.common.retention.noncurrent_expire_days
    }
  }
}

resource "azurerm_storage_container" "backup" {
  name                  = local.container
  storage_account_id    = azurerm_storage_account.backup.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "backup" {
  storage_account_id = azurerm_storage_account.backup.id

  # Weekly copies: Cool, then Archive, then delete. Archive blobs must be rehydrated
  # (hours) before they can be read, so restore drills use daily/ or recent weekly/.
  rule {
    name    = "weekly-tiering"
    enabled = true
    filters {
      prefix_match = ["${local.container}/${module.common.retention.weekly_prefix}"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = module.common.retention.weekly_transition_days
        tier_to_archive_after_days_since_modification_greater_than = var.weekly_archive_days
        delete_after_days_since_modification_greater_than          = module.common.retention.weekly_expire_days
      }
    }
  }
}

# ---------------------------------------------------------------- scoped identity

# The VM's identity may read and write blobs in this one container, nothing else.
resource "azurerm_role_assignment" "backup" {
  scope                = azurerm_storage_container.backup.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.forge.identity[0].principal_id
}
