<!--
Program: Terraform_Local_Check.md
Description: General procedure for running a local Terraform plan against a shared Azure Storage backend before CI execution.
Context: Azure Landing Zones and other Azure DevOps-managed Terraform environments.
Author: Greg Tate
-->

# Local Terraform Plan Before CI

Use this procedure to review Terraform changes locally before pushing them to a repository whose CI pipeline will run Terraform plan.

## 1. Confirm the Terraform root and version

Run Terraform from the directory containing the environment's `.tf` files and backend configuration:

```powershell
Set-Location '<terraform-root>'

git status --short --branch
terraform version
```

Use the same Terraform CLI version configured by CI. Confirm that the working tree, branch, and commit contain the changes you intend to review. Do not mix files, generated metadata, or plan files from another environment.

## 2. Authenticate to Azure

The local identity must be able to read the remote state, acquire the state lock, and read the Azure resources managed by the configuration.

```powershell
az login --tenant '<tenant-id>'
az account set --subscription '<backend-subscription-id>'
```

If CI uses a service principal, federated identity, or managed identity, the local Azure CLI identity must have equivalent permissions for the local plan to be representative.

## 3. Identify the exact remote backend

The Terraform configuration may contain an intentionally empty backend block:

```terraform
backend "azurerm" {}
```

Obtain the exact backend values from the CI template, pipeline variables, approved variable group, or the Azure resources. Do not guess the storage account, container, or state blob name.

Typical discovery commands are:

```powershell
az storage account list `
    --resource-group '<state-resource-group>' `
    --subscription '<backend-subscription-id>' `
    --query '[].name' `
    --output tsv

az storage container list `
    --account-name '<storage-account-name>' `
    --auth-mode login `
    --output table

az storage blob list `
    --account-name '<storage-account-name>' `
    --container-name '<container-name>' `
    --auth-mode login `
    --query '[].name' `
    --output tsv
```

## 4. Initialize against the shared state

Initialize Terraform with the exact backend values used by CI:

```powershell
terraform init `
    -reconfigure `
    -input=false `
    -backend-config="subscription_id=<backend-subscription-id>" `
    -backend-config="tenant_id=<tenant-id>" `
    -backend-config="resource_group_name=<state-resource-group>" `
    -backend-config="storage_account_name=<storage-account-name>" `
    -backend-config="container_name=<container-name>" `
    -backend-config="key=<exact-state-blob-name>" `
    -backend-config="use_cli=true" `
    -backend-config="use_azuread_auth=true"
```

`-reconfigure` updates only the local Terraform backend metadata. Do not use `-migrate-state` unless the explicit task is to move state. Do not use `-upgrade` for a routine plan review because it can change provider or module selections.

## 5. Run static checks

```powershell
terraform fmt -check -recursive
terraform validate
```

Terraform automatically loads `terraform.tfvars`, `terraform.tfvars.json`, and `*.auto.tfvars` files in the root. Add `-var-file` only when CI supplies an additional variable file that is also available locally.

## 6. Generate and inspect the plan

```powershell
terraform plan `
    -refresh=true `
    -input=false `
    -lock=true `
    -lock-timeout=5m `
    -out=tfplan `
    -detailed-exitcode

$planExitCode = $LASTEXITCODE

if ($planExitCode -eq 0) {
    Write-Output 'No changes are planned.'
}
elseif ($planExitCode -eq 2) {
    Write-Output 'Changes are planned; inspect the plan before pushing.'
}
else {
    throw "Terraform plan failed with exit code $planExitCode."
}

terraform show -no-color tfplan
```

The exit codes are:

- `0`: no changes
- `2`: changes are planned
- `1`: an error occurred

The normal plan reads live Azure and remote state and temporarily takes the remote state lock. It does not apply infrastructure changes. Do not use `-lock=false` to bypass another operation; investigate the competing plan or apply instead.

## 7. Review and hand off to CI

Review additions, changes, replacements, and especially destroys. If the plan is acceptable, commit and push the change so CI can run its own plan. Do not run `terraform apply` locally when CI/CD is the controlled deployment path.

The CI plan can differ from the local plan if Azure changes, state changes, variables differ, or the pipeline uses a different identity between the two runs.

Keep `tfplan`, any JSON representation of it, `.terraform`, and local state artifacts private. Plan files can contain sensitive configuration values and must not be committed or uploaded casually.
