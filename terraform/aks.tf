# ── Log Analytics (created before AKS — referenced by OMS agent) ──────────────
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = var.environment == "prod" ? 90 : 30
  tags                = local.tags
}

# ── AKS Cluster ────────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${local.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = local.prefix
  kubernetes_version  = var.kubernetes_version

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # System node pool — critical cluster components only.
  # only_critical_addons_enabled taints with CriticalAddonsOnly:NoSchedule
  # so user workloads schedule onto the user pool below.
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_pool.vm_size
    auto_scaling_enabled         = true
    # enable_auto_scaling          = true
    min_count                    = var.system_node_pool.min_count
    max_count                    = var.system_node_pool.max_count
    vnet_subnet_id               = azurerm_subnet.aks_system.id
    os_disk_size_gb              = 50
    type                         = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true

    upgrade_settings {
      max_surge = "10%"
    }

    node_labels = {
      "platform.io/nodepool-type" = "system"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico"
    dns_service_ip    = "172.16.0.10"
    service_cidr      = "172.16.0.0/16"
    load_balancer_sku = "standard"
  }

  azure_active_directory_role_based_access_control {
    
    //managed                = true
    azure_rbac_enabled     = true
    admin_group_object_ids = [var.admin_group_object_id]
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [
      kubernetes_version,
      default_node_pool[0].orchestrator_version,
    ]
  }
}

# ── User node pool — application workloads ─────────────────────────────────────
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.user_node_pool.vm_size
  auto_scaling_enabled  = true
  # enable_auto_scaling   = true
  min_count             = var.user_node_pool.min_count
  max_count             = var.user_node_pool.max_count
  vnet_subnet_id        = azurerm_subnet.aks_user.id
  os_disk_size_gb       = 128

  upgrade_settings {
    max_surge = "10%"
  }

  node_labels = {
    "platform.io/nodepool-type" = "user"
  }

  tags = local.tags
}
