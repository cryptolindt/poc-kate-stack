output "resource_group_name" {
  description = "Main resource group"
  value       = azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.main.name
}

output "aks_oidc_issuer_url" {
  description = "AKS OIDC issuer URL — reference when adding new federated credentials"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "key_vault_name" {
  description = "Key Vault name"
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "Key Vault URI — written to platform-gitops clusters/<env>/values.yaml for ESO"
  value       = azurerm_key_vault.main.vault_uri
}

output "eso_client_id" {
  description = "ESO UAMI client_id — injected into ESO ServiceAccount annotation via Helm"
  value       = azurerm_user_assigned_identity.eso.client_id
}

output "argocd_client_id" {
  description = "ArgoCD UAMI client_id"
  value       = azurerm_user_assigned_identity.argocd.client_id
}

output "github_actions_client_id" {
  description = "GitHub Actions UAMI client_id — update ARM_CLIENT_ID after first apply"
  value       = azurerm_user_assigned_identity.github_actions.client_id
}
