# ═══════════════════════════════════════════════════════════════════════════════
# identity.tf — Azure Workload Identity Setup
#
# Pattern for every component needing Azure API access:
#   1. azurerm_user_assigned_identity   — stable Azure AD principal (no secrets)
#   2. azurerm_federated_identity_credential — trust rule: accept OIDC tokens
#      where iss=X and sub=Y
#   3. azurerm_role_assignment          — least-privilege RBAC
#
# The Kubernetes ServiceAccount (with azure.workload.identity/client-id annotation)
# lives in platform-gitops. The client_id flows:
#   outputs.tf → GHA workflow → platform-gitops clusters/<env>/values.yaml
#   → Helm → ServiceAccount annotation → webhook reads at pod start.
# ═══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════
# 1. External Secrets Operator (ESO)
# ══════════════════════════════════════════════════════════════

resource "azurerm_user_assigned_identity" "eso" {
  name                = "id-eso-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "eso" {
  name                = "fic-eso-aks"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.eso.id
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:external-secrets:external-secrets"
  audience            = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "eso_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}

# ══════════════════════════════════════════════════════════════
# 2. ArgoCD Repo Server
# ══════════════════════════════════════════════════════════════

resource "azurerm_user_assigned_identity" "argocd" {
  name                = "id-argocd-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "argocd" {
  name                = "fic-argocd-aks"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.argocd.id
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:argocd:argocd-repo-server"
  audience            = ["api://AzureADTokenExchange"]
}

# ══════════════════════════════════════════════════════════════
# 3. GitHub Actions — Terraform workflow identity
#
# BOOTSTRAP NOTE:
#   This UAMI is created BY Terraform, so it cannot exist for the first run.
#   Run scripts/bootstrap.sh once to create a temporary bootstrap identity.
#   After first apply, update ARM_CLIENT_ID in GitHub Actions Variables
#   to this UAMI's client_id, then delete the bootstrap RG.
# ══════════════════════════════════════════════════════════════

resource "azurerm_user_assigned_identity" "github_actions" {
  name                = "id-gha-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "gha_main" {
  name                = "fic-gha-main"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.github_actions.id
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
  audience            = ["api://AzureADTokenExchange"]
}

resource "azurerm_federated_identity_credential" "gha_pr" {
  name                = "fic-gha-pr"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.github_actions.id
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_org}/${var.github_repo}:pull_request"
  audience            = ["api://AzureADTokenExchange"]
}

# ── GitHub Actions RBAC ────────────────────────────────────────────────────────

data "azurerm_storage_account" "tfstate" {
  name                = var.tf_state_storage_account
  resource_group_name = var.tf_state_resource_group
}

resource "azurerm_role_assignment" "gha_tfstate" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_role_assignment" "gha_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

# ABAC condition restricts which role definition IDs this identity may assign,
# preventing privilege escalation.
# 4633458b-17de-408a-b874-0445c86b69e6 = Key Vault Secrets User
# acdd72a7-3385-48ef-bd42-f606fba81ae7 = Reader
resource "azurerm_role_assignment" "gha_rbac_admin" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id

  condition_version = "2.0"
  condition         = <<-EOT
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
    ) OR (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
      ForAnyOfAllValues:GuidEquals {
        4633458b-17de-408a-b874-0445c86b69e6,
        acdd72a7-3385-48ef-bd42-f606fba81ae7
      }
    )
  EOT
}
