variable "environment" {
  type        = string
  description = "Deployment environment"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be one of: dev, staging, prod."
  }
}

variable "location" {
  type        = string
  description = "Azure region for all resources"
  default     = "westeurope"
}

variable "project" {
  type        = string
  description = "Short platform identifier used in resource name prefix (e.g. 'myplatform')"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the AKS cluster"
  default     = "1.29"
}

variable "system_node_pool" {
  description = "System node pool — hosts kube-system, ArgoCD, monitoring, ESO"
  type = object({
    vm_size   = string
    min_count = number
    max_count = number
  })
  default = {
    vm_size   = "Standard_D2s_v3"
    min_count = 1
    max_count = 3
  }
}

variable "user_node_pool" {
  description = "User node pool — hosts application workloads"
  type = object({
    vm_size   = string
    min_count = number
    max_count = number
  })
  default = {
    vm_size   = "Standard_D4s_v3"
    min_count = 1
    max_count = 10
  }
}

variable "admin_group_object_id" {
  type        = string
  description = "Azure AD group object ID granted AKS Cluster Admin role"
}

variable "github_org" {
  type        = string
  description = "GitHub organisation — used in GitHub Actions federated credential subject claim"
}

variable "github_repo" {
  type        = string
  description = "This repository name — used in GitHub Actions federated credential subject claim"
  default     = "platform-azure-infra"
}

variable "tf_state_resource_group" {
  type        = string
  description = "Resource group containing the Terraform state storage account (created by bootstrap.sh)"
}

variable "tf_state_storage_account" {
  type        = string
  description = "Storage account name for Terraform remote state (created by bootstrap.sh)"
}
