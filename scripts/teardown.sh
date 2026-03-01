#!/usr/bin/env bash
# scripts/teardown.sh
#
# Destroys all Azure resources for a KATE environment in reverse dependency order.
# Azure-scoped only — does NOT touch GitHub repos, teams, or org-level resources.
#
# Usage:
#   bash scripts/teardown.sh --project myplatform --env dev
#   bash scripts/teardown.sh --project myplatform --env dev --include-bootstrap
#   bash scripts/teardown.sh --project myplatform --env dev --dry-run
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT=""
ENVIRONMENT=""
DRY_RUN=false
INCLUDE_BOOTSTRAP=false

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)        PROJECT="$2"; shift 2 ;;
    --env)            ENVIRONMENT="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --include-bootstrap) INCLUDE_BOOTSTRAP=true; shift ;;
    *)                echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$PROJECT" || -z "$ENVIRONMENT" ]]; then
  echo "Usage: bash scripts/teardown.sh --project <name> --env <dev|staging|prod> [--dry-run] [--include-bootstrap]"
  exit 1
fi

PREFIX="${PROJECT}-${ENVIRONMENT}"
RG_NAME="rg-${PREFIX}"
KV_NAME="kv-${PREFIX}"
AKS_NAME="aks-${PREFIX}"
STATE_RG="rg-tfstate-${PROJECT}"
BOOTSTRAP_RG="rg-bootstrap-${PROJECT}"

# ── Confirmation ──────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
  echo "════════════════════════════════════════════════════════════════════"
  echo " WARNING: This will DESTROY all Azure resources for:"
  echo "   Project:     ${PROJECT}"
  echo "   Environment: ${ENVIRONMENT}"
  echo "   Resource Group: ${RG_NAME}"
  if [[ "$INCLUDE_BOOTSTRAP" == "true" ]]; then
    echo "   + Bootstrap RG: ${BOOTSTRAP_RG}"
    echo "   + State RG:     ${STATE_RG}"
  fi
  echo "════════════════════════════════════════════════════════════════════"
  echo ""
  read -rp "Type '${ENVIRONMENT}' to confirm destruction of Azure resources: " CONFIRM
  if [[ "$CONFIRM" != "$ENVIRONMENT" ]]; then
    echo "Confirmation failed. Aborting."
    exit 1
  fi
fi

STAGE_FAILED=""
trap 'if [[ -n "$STAGE_FAILED" ]]; then echo ""; echo "⚠ Teardown failed at: $STAGE_FAILED"; echo "  Manual cleanup may be required for subsequent stages."; fi' EXIT

# ── Helper ────────────────────────────────────────────────────────────────────
run_or_dry() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] $*"
  else
    "$@"
  fi
}

# ── Check if AKS exists ──────────────────────────────────────────────────────
AKS_EXISTS=false
if az aks show --name "$AKS_NAME" --resource-group "$RG_NAME" -o none 2>/dev/null; then
  AKS_EXISTS=true
fi

# ══════════════════════════════════════════════════════════════════════════════
# Stage 1: Drain ArgoCD Applications
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$AKS_EXISTS" == "true" ]]; then
  echo ""
  echo "▶ Stage 1: Draining ArgoCD Applications..."
  STAGE_FAILED="Stage 1: Drain ArgoCD"

  if [[ "$DRY_RUN" == "false" ]]; then
    az aks get-credentials --name "$AKS_NAME" --resource-group "$RG_NAME" --overwrite-existing
  fi

  if kubectl get namespace argocd &>/dev/null 2>&1; then
    run_or_dry kubectl delete application --all -n argocd --ignore-not-found --timeout=120s
    echo "  ✓ ArgoCD applications drained"
  else
    echo "  ↩ argocd namespace not found, skipping"
  fi

  # ════════════════════════════════════════════════════════════════════════════
  # Stage 2: Uninstall Helm releases
  # ════════════════════════════════════════════════════════════════════════════
  echo ""
  echo "▶ Stage 2: Uninstalling Helm releases..."
  STAGE_FAILED="Stage 2: Helm uninstall"

  for RELEASE_NS in "argocd:argocd" "external-secrets:external-secrets"; do
    RELEASE="${RELEASE_NS%%:*}"
    NS="${RELEASE_NS#*:}"
    if helm status "$RELEASE" -n "$NS" &>/dev/null 2>&1; then
      run_or_dry helm uninstall "$RELEASE" -n "$NS" --wait --timeout 5m
      echo "  ✓ uninstalled: $RELEASE"
    else
      echo "  ↩ not found: $RELEASE"
    fi
  done

  # ════════════════════════════════════════════════════════════════════════════
  # Stage 3: Delete AKS namespaces
  # ════════════════════════════════════════════════════════════════════════════
  echo ""
  echo "▶ Stage 3: Deleting AKS namespaces..."
  STAGE_FAILED="Stage 3: Delete namespaces"

  run_or_dry kubectl delete ns argocd external-secrets --ignore-not-found --timeout=120s
  echo "  ✓ namespaces cleaned up"
else
  echo ""
  echo "▶ Stages 1-3: Skipped (AKS cluster '${AKS_NAME}' not found)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Stage 4: Terraform destroy
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "▶ Stage 4: Terraform destroy..."
STAGE_FAILED="Stage 4: Terraform destroy"

TF_DIR="terraform"
TFVARS_FILE="${TF_DIR}/environments/${ENVIRONMENT}.tfvars"

if [[ -d "$TF_DIR" && -f "$TFVARS_FILE" ]]; then
  STATE_SA=$(grep 'tf_state_storage_account' "$TFVARS_FILE" | sed 's/.*= *"\(.*\)"/\1/' | tr -d ' ')
  STATE_RG_VAR=$(grep 'tf_state_resource_group' "$TFVARS_FILE" | sed 's/.*= *"\(.*\)"/\1/' | tr -d ' ')

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] terraform plan -destroy -var-file=${TFVARS_FILE}"
    cd "$TF_DIR"
    terraform init \
      -backend-config="resource_group_name=${STATE_RG_VAR}" \
      -backend-config="storage_account_name=${STATE_SA}" \
      -backend-config="container_name=tfstate" \
      -backend-config="key=${ENVIRONMENT}.tfstate" \
      -input=false 2>/dev/null || echo "  ⚠ terraform init failed (state backend may be gone)"
    terraform plan -destroy -var-file="environments/${ENVIRONMENT}.tfvars" -no-color 2>/dev/null || true
    cd - >/dev/null
  else
    cd "$TF_DIR"
    terraform init \
      -backend-config="resource_group_name=${STATE_RG_VAR}" \
      -backend-config="storage_account_name=${STATE_SA}" \
      -backend-config="container_name=tfstate" \
      -backend-config="key=${ENVIRONMENT}.tfstate" \
      -input=false 2>/dev/null || echo "  ⚠ terraform init failed"

    terraform destroy \
      -var-file="environments/${ENVIRONMENT}.tfvars" \
      -auto-approve || {
        echo "  ⚠ terraform destroy failed — falling back to az group delete"
        cd - >/dev/null
        az group delete -n "$RG_NAME" --yes --no-wait 2>/dev/null || true
      }
    cd - >/dev/null
  fi
  echo "  ✓ Terraform destroy complete"
else
  echo "  ⚠ Terraform directory or tfvars not found — falling back to az group delete"
  if az group show -n "$RG_NAME" -o none 2>/dev/null; then
    run_or_dry az group delete -n "$RG_NAME" --yes --no-wait
    echo "  ✓ Resource group deletion initiated: $RG_NAME"
  else
    echo "  ↩ Resource group not found: $RG_NAME"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Stage 5: Purge Key Vault (soft-deleted)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "▶ Stage 5: Purging soft-deleted Key Vault..."
STAGE_FAILED="Stage 5: Key Vault purge"

if az keyvault show-deleted --name "$KV_NAME" -o none 2>/dev/null; then
  run_or_dry az keyvault purge --name "$KV_NAME" --no-wait
  echo "  ✓ Key Vault purge initiated: $KV_NAME"
else
  echo "  ↩ No soft-deleted vault found: $KV_NAME"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Stage 6: Remove bootstrap resources (opt-in)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$INCLUDE_BOOTSTRAP" == "true" ]]; then
  echo ""
  echo "▶ Stage 6: Removing bootstrap resources..."
  STAGE_FAILED="Stage 6: Bootstrap cleanup"

  if az group show -n "$BOOTSTRAP_RG" -o none 2>/dev/null; then
    run_or_dry az group delete -n "$BOOTSTRAP_RG" --yes --no-wait
    echo "  ✓ Bootstrap RG deletion initiated: $BOOTSTRAP_RG"
  else
    echo "  ↩ Bootstrap RG not found: $BOOTSTRAP_RG"
  fi

  if az group show -n "$STATE_RG" -o none 2>/dev/null; then
    run_or_dry az group delete -n "$STATE_RG" --yes --no-wait
    echo "  ✓ State RG deletion initiated: $STATE_RG"
  else
    echo "  ↩ State RG not found: $STATE_RG"
  fi
else
  echo ""
  echo "▶ Stage 6: Skipped (pass --include-bootstrap to remove state backend and bootstrap RG)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
STAGE_FAILED=""
echo ""
echo "════════════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "true" ]]; then
  echo " DRY RUN COMPLETE — no resources were modified."
else
  echo " Teardown complete for ${PREFIX}."
  echo ""
  echo " Note: Some deletions run asynchronously (--no-wait)."
  echo " Verify with: az group show -n ${RG_NAME} -o none 2>/dev/null && echo 'still exists' || echo 'gone'"
fi
echo "════════════════════════════════════════════════════════════════════"
