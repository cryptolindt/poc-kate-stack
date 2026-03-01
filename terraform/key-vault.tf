resource "azurerm_key_vault" "main" {
  name                = "kv-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # enable_rbac_authorization = true
  rbac_authorization_enabled = true

  # Deny all traffic except from AKS subnets and trusted Azure platform services.
  # Azure Resource Manager (used by Terraform) is covered by the AzureServices bypass.
  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = [
      azurerm_subnet.aks_system.id,
      azurerm_subnet.aks_user.id,
    ]
  }

  soft_delete_retention_days = var.environment == "prod" ? 90 : 7
  purge_protection_enabled   = var.environment == "prod"

  tags = local.tags
}
