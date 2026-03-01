locals {
  prefix = "${var.project}-${var.environment}"

  tags = {
    environment = var.environment
    project     = var.project
    managed_by  = "terraform"
    repository  = "${var.github_org}/${var.github_repo}"
  }
}

data "azurerm_client_config" "current" {}

# ── Resource Group ─────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = "rg-${local.prefix}"
  location = var.location
  tags     = local.tags
}

# ── Virtual Network ────────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.0.0.0/8"]
  tags                = local.tags
}

# System node pool subnet — kube-system, ArgoCD, ESO, monitoring
resource "azurerm_subnet" "aks_system" {
  name                 = "snet-aks-system"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.240.0.0/16"]

  service_endpoints = ["Microsoft.KeyVault"]
}

# User node pool subnet — application workloads
resource "azurerm_subnet" "aks_user" {
  name                 = "snet-aks-user"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.241.0.0/16"]

  service_endpoints = ["Microsoft.KeyVault"]
}
