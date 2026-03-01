#!/usr/bin/env bash
# scripts/bootstrap.sh
#
# Creates the Terraform state backend and a temporary GitHub Actions identity
# with broad permissions for the first terraform apply.
#
# Prerequisites:
#   - az login with Owner/Contributor access on the subscription
#   - Edit the configuration variables below before running
#
# After first apply:
#   1. Run: terraform -chdir=terraform output github_actions_client_id
#   2. Update ARM_CLIENT_ID in GitHub Actions Variables to that value
#   3. Run: az group delete -n rg-bootstrap-${PROJECT} --yes
set -euo pipefail

# ── Edit these ───────────────────────────────────────────────────────────────
GITHUB_ORG="YOUR_ORG"
GITHUB_REPO="platform-azure-infra"
PROJECT="myplatform"
LOCATION="westeurope"
STATE_SA="sttfstate${PROJECT}"     # globally unique; 3–24 lowercase alphanumeric
# ─────────────────────────────────────────────────────────────────────────────

STATE_RG="rg-tfstate-${PROJECT}"
BOOTSTRAP_RG="rg-bootstrap-${PROJECT}"
BOOTSTRAP_UAMI="id-gha-bootstrap-${PROJECT}"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "▶ Creating Terraform state backend..."
az group create -n "$STATE_RG" -l "$LOCATION" -o none
az storage account create \
  -n "$STATE_SA" -g "$STATE_RG" -l "$LOCATION" \
  --sku Standard_LRS --min-tls-version TLS1_2 \
  --allow-blob-public-access false -o none
az storage container create \
  --name tfstate --account-name "$STATE_SA" --auth-mode login -o none
echo "✓ State backend: ${STATE_SA}/tfstate"

echo ""
echo "▶ Creating bootstrap GitHub Actions identity..."
az group create -n "$BOOTSTRAP_RG" -l "$LOCATION" -o none
az identity create -n "$BOOTSTRAP_UAMI" -g "$BOOTSTRAP_RG" -o none
CLIENT_ID=$(az identity show -n "$BOOTSTRAP_UAMI" -g "$BOOTSTRAP_RG" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -n "$BOOTSTRAP_UAMI" -g "$BOOTSTRAP_RG" --query principalId -o tsv)
STATE_SA_ID=$(az storage account show -n "$STATE_SA" -g "$STATE_RG" --query id -o tsv)

echo "▶ Creating federated credentials..."
for CONFIG in "fic-main:ref:refs/heads/main" "fic-pr:pull_request"; do
  NAME="${CONFIG%%:*}"; SUBJECT="repo:${GITHUB_ORG}/${GITHUB_REPO}:${CONFIG#*:}"
  az identity federated-credential create \
    --name "$NAME" --identity-name "$BOOTSTRAP_UAMI" -g "$BOOTSTRAP_RG" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "$SUBJECT" --audiences "api://AzureADTokenExchange" -o none
  echo "  ✓ $NAME → $SUBJECT"
done

echo "▶ Assigning roles..."
for ROLE in "Contributor" "Role Based Access Control Administrator"; do
  az role assignment create \
    --role "$ROLE" \
    --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
    --scope "/subscriptions/$SUBSCRIPTION_ID" -o none
  echo "  ✓ $ROLE → subscription"
done
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --scope "$STATE_SA_ID" -o none
echo "  ✓ Storage Blob Data Contributor → state account"

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo " Bootstrap complete. Set these GitHub Actions Repository Variables:"
echo ""
echo "  ARM_CLIENT_ID:       ${CLIENT_ID}"
echo "  ARM_TENANT_ID:       ${TENANT_ID}"
echo "  ARM_SUBSCRIPTION_ID: ${SUBSCRIPTION_ID}"
echo "  TF_STATE_RG:         ${STATE_RG}"
echo "  TF_STATE_SA:         ${STATE_SA}"
echo "  GITHUB_ORG:          ${GITHUB_ORG}"
echo ""
echo " After first terraform apply, rotate to the permanent identity:"
echo "  1. terraform -chdir=terraform output github_actions_client_id"
echo "  2. Update ARM_CLIENT_ID to that value"
echo "  3. az group delete -n ${BOOTSTRAP_RG} --yes"
echo "════════════════════════════════════════════════════════════════════"
