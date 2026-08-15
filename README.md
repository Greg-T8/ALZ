# Azure Landing Zones Terraform Accelerator Lab

This repository contains a sample configuration for bootstrapping and operating an
Azure Landing Zone (ALZ) with the
[Azure Landing Zones Terraform Accelerator](https://github.com/Azure/alz-terraform-accelerator).
It supports GitHub, Azure DevOps, and local deployment workflows while keeping
credentials outside the checked-in input files.

The checked-in bootstrap subscription IDs, subscription names, organization names,
approvers, email addresses, resource names, and network ranges are
documentation-only samples. Replace them before using this repository in an Azure
environment.

## Getting started

1. Review the ALZ documentation and select the scenario that fits the target
   environment.
2. Choose one platform input file in `bootstrap/`, then replace every sample
   subscription, organization, approver, and resource-name value.
3. For GitHub or Azure DevOps, create the bootstrap Key Vault and PATs with the
   scripts in `bootstrap/scripts/`.
4. Preview the selected bootstrap with
   `./bootstrap/Deploy-BootstrapWithKeyVault.ps1 -Platform <platform> -WhatIf`.
5. Review a fresh generated Terraform plan before applying it.

## References

| Reference | Significance |
| --- | --- |
| [Azure Landing Zones main page](https://azure.github.io/Azure-Landing-Zones/accelerator/) | Primary documentation for the Azure Landing Zones Accelerator, its architecture, and deployment guidance. |
| [ALZ scenarios](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/) | Scenario guidance for choosing and tailoring a starter Terraform configuration. |
| [Accelerator bootstrap modules](https://github.com/Azure/accelerator-bootstrap-modules) | Source for the modules and configuration that bootstrap the chosen deployment platform. |
| [ALZ Terraform Accelerator](https://github.com/Azure/alz-terraform-accelerator) | ALZ-specific Terraform modules used by this solution, including the scenario templates. |
| [Azure Landing Zones Library](https://github.com/Azure/Azure-Landing-Zones-Library) | The ALZ policy, initiative, archetype, and role-definition library consumed by the configuration. |

## Repository contents

```text
ALZ/
├── bootstrap/
│   ├── inputs.ado.terraform.yaml
│   ├── inputs.github.terraform.yaml
│   ├── inputs.local.terraform.yaml
│   ├── Deploy-BootstrapWithKeyVault.ps1
│   ├── scripts/
│   │   ├── Cleanup-LandingZone.ps1
│   │   ├── Deploy-LocalWithLogging.ps1
│   │   ├── New-AzureDevOpsBootstrapPat.ps1
│   │   ├── New-BootstrapKeyVault.ps1
│   │   └── Set-AllContainerInstances.ps1
│   └── config/
│       ├── platform-landing-zone.tfvars
│       ├── templates/
│       └── lib/
├── notes/
│   ├── scripts/
│   └── troubleshooting and design notes
├── .gitignore
└── README.md
```

| Path | Purpose |
| --- | --- |
| [`bootstrap/inputs.github.terraform.yaml`](bootstrap/inputs.github.terraform.yaml) | GitHub bootstrap inputs, repository settings, and sample subscription mappings. |
| [`bootstrap/inputs.ado.terraform.yaml`](bootstrap/inputs.ado.terraform.yaml) | Azure DevOps bootstrap inputs, project settings, and sample subscription mappings. |
| [`bootstrap/inputs.local.terraform.yaml`](bootstrap/inputs.local.terraform.yaml) | Local bootstrap inputs that use the authenticated Azure CLI identity. |
| [`bootstrap/scripts/New-BootstrapKeyVault.ps1`](bootstrap/scripts/New-BootstrapKeyVault.ps1) | Creates the RBAC-enabled Key Vault used to store bootstrap PATs and grants the signed-in user secret access. |
| [`bootstrap/scripts/New-AzureDevOpsBootstrapPat.ps1`](bootstrap/scripts/New-AzureDevOpsBootstrapPat.ps1) | Creates the two Azure DevOps bootstrap PATs as the signed-in user and stores them directly in Key Vault. |
| [`bootstrap/Deploy-BootstrapWithKeyVault.ps1`](bootstrap/Deploy-BootstrapWithKeyVault.ps1) | Selects a platform, retrieves required PATs from Key Vault when applicable, and invokes `Deploy-Accelerator`. |
| [`bootstrap/scripts/Deploy-LocalWithLogging.ps1`](bootstrap/scripts/Deploy-LocalWithLogging.ps1) | Runs a local Terraform deployment while recording a session log and Terraform diagnostics; supports remote-state settings, `Destroy`, `AutoApprove`, and `WhatIf`. |
| [`bootstrap/scripts/Set-AllContainerInstances.ps1`](bootstrap/scripts/Set-AllContainerInstances.ps1) | Shows, starts, or stops every Azure Container Instance in one subscription; state changes support `WhatIf` and `Confirm`. |
| [`bootstrap/scripts/Cleanup-LandingZone.ps1`](bootstrap/scripts/Cleanup-LandingZone.ps1) | Deletes resource groups from an explicit subscription allowlist with `WhatIf` and confirmation safeguards. |
| [`bootstrap/config/platform-landing-zone.tfvars`](bootstrap/config/platform-landing-zone.tfvars) | Active platform landing-zone configuration supplied to the Accelerator. |
| [`bootstrap/config/templates/`](bootstrap/config/templates) | Reusable management-only and Virtual WAN configuration profiles. |
| [`bootstrap/config/lib/`](bootstrap/config/lib) | Custom ALZ library metadata, management-group architecture, and archetype overrides. |
| [`notes/`](notes) | Design records, experiments, prerequisites, and troubleshooting guidance. Some notes describe older generated layouts and should not override the current source files. |

Local planning files under `.azure/`, generated `output/`, and the local VS Code
workspace are intentionally ignored and are not part of the published project.

## Recently added scripts

`Deploy-LocalWithLogging.ps1` is a convenience wrapper for a generated local
Terraform deployment. It captures console output in a session log and enables
Terraform diagnostic logging for the run. Use it when diagnosing a local
deployment, and use `-WhatIf` before a state-changing run.

`Set-AllContainerInstances.ps1` provides subscription-scoped Azure Container
Instance inventory and lifecycle control. `Show` is read-only; `Start` and `Stop`
only target groups already in the matching runtime state and support standard
PowerShell preview and confirmation safeguards:

```powershell
# Show the current state of every container group in one subscription.
.\bootstrap\scripts\Set-AllContainerInstances.ps1 `
    -Action Show `
    -Subscription '<subscription-name-or-id>'

# Preview stopping only currently running container groups.
.\bootstrap\scripts\Set-AllContainerInstances.ps1 `
    -Action Stop `
    -Subscription '<subscription-name-or-id>' `
    -WhatIf
```

## How the configuration is used

The deployment wrapper combines three maintained inputs:

```text
platform bootstrap input
        +
active platform-landing-zone.tfvars
        +
custom ALZ library
        |
        v
Deploy-Accelerator -> generated output -> GitHub, Azure DevOps, or local workflow
```

The bootstrap and starter packages are independently versioned. The current inputs
pin bootstrap `v7.3.0` and starter `v17.4.0`. The custom ALZ library metadata depends
on `platform/alz/2026.08.0`.

Generated files belong under `output/` and are excluded from source control. Make
durable changes in `bootstrap/` and regenerate the output instead of maintaining
direct edits inside generated modules.

## Prerequisites

Before running a deployment, install and configure:

- PowerShell.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with an authenticated account.
- The ALZ PowerShell module that provides the `Deploy-Accelerator` command.
- Terraform CLI for direct formatting and validation checks.
- Azure permissions for the parent management group, target subscriptions, bootstrap subscription, and Key Vault.
- A GitHub organization or Azure DevOps organization/project when using those platforms.
- Platform PATs stored in Azure Key Vault when using GitHub or Azure DevOps.

Review the platform-specific PAT notes before creating credentials:

- [GitHub PAT requirements](notes/PAT_GitHub_Requirements.md)
- [Azure DevOps PAT requirements](notes/PAT_ADO_Requirements.md)
- [PAT security guidance](notes/Securing_PAT_Bootstrap_Guidance.md)

Create the bootstrap Key Vault before provisioning PATs. The resource group must
already exist; its Azure location is inherited by the vault. Preview both the vault
creation and vault-scoped role assignment before running them. The script checks
`Microsoft.KeyVault` provider registration in the selected subscription and, when
needed, registers it and waits for Azure to finish before creating the vault:

```powershell
# Preview an RBAC-enabled bootstrap Key Vault in an existing resource group.
.\bootstrap\scripts\New-BootstrapKeyVault.ps1 `
    -ResourceGroupName "<existing-resource-group>" `
    -Subscription "55555555-5555-5555-5555-555555555555" `
    -KeyVaultName "kvsamplebootstrap00" `
    -WhatIf

# Create the vault and grant the signed-in user Key Vault Secrets Officer.
.\bootstrap\scripts\New-BootstrapKeyVault.ps1 `
    -ResourceGroupName "<existing-resource-group>" `
    -Subscription "55555555-5555-5555-5555-555555555555" `
    -KeyVaultName "kvsamplebootstrap00"
```

The script uses the ALZ lab governance tags by default. Supply `-Tag` to override
individual values. It stops without making changes if the vault already exists.
Azure RBAC propagation can take several minutes after creation.

For Azure DevOps, preview PAT creation and Key Vault storage before running it.
The Azure CLI session must be signed in as a human user because Azure DevOps does
not permit service principals or managed identities to mint PATs:

```powershell
# Preview creation of the ALZ bootstrap and self-hosted agent PATs.
.\bootstrap\scripts\New-AzureDevOpsBootstrapPat.ps1 `
    -OrganizationName "sample-organization" `
    -KeyVaultName "kvsamplebootstrap00" `
    -WhatIf

# Create both PATs and store them under the secret names used by the wrapper.
.\bootstrap\scripts\New-AzureDevOpsBootstrapPat.ps1 `
    -OrganizationName "sample-organization" `
    -KeyVaultName "kvsamplebootstrap00"
```

The bootstrap PAT defaults to one day. The agent-registration PAT defaults to 365
days and only receives `Agent Pools — Read & manage`; shorten its lifetime with
`-AgentPatLifetimeDays` when organization policy requires it. Re-running the script
creates new Key Vault secret versions but does not revoke earlier PATs.

Confirm the Azure CLI context before continuing:

```powershell
# Show the tenant, subscription, and signed-in identity used by Azure CLI.
az account show --output table
```

## Configure the samples

1. Select one platform input file under `bootstrap/`.
2. Replace the sample parent management-group identifier and all five sample
   subscription IDs.
3. Replace the sample organization, project, and approver values for GitHub or
   Azure DevOps.
4. Review the bootstrap region, naming, agent or runner settings, networking,
   module versions, and `auto_approve` behavior.
5. For GitHub or Azure DevOps, update `KeyVaultName` and the secret names in
   `Deploy-BootstrapWithKeyVault.ps1` to match your Key Vault.
6. Review the active landing-zone configuration and custom ALZ library before
   generating output.

The active [`platform-landing-zone.tfvars`](bootstrap/config/platform-landing-zone.tfvars)
currently matches the management-only template. To start from the Virtual WAN
profile, deliberately copy the template over the active file and review the complete
plan before applying it:

```powershell
# Select the Virtual WAN profile as the active landing-zone configuration.
Copy-Item `
    -LiteralPath .\bootstrap\config\templates\custom_virtual-wan.tfvars `
    -Destination .\bootstrap\config\platform-landing-zone.tfvars
```

## Preview and deploy

Run commands from the repository root. Start with `WhatIf` so the wrapper resolves
and validates the requested workflow without invoking `Deploy-Accelerator`.

```powershell
# Preview a local bootstrap using the current Azure CLI identity.
.\bootstrap\Deploy-BootstrapWithKeyVault.ps1 `
    -Platform Local `
    -WhatIf

# Preview a GitHub bootstrap using PATs read from Azure Key Vault.
.\bootstrap\Deploy-BootstrapWithKeyVault.ps1 `
    -Platform GitHub `
    -WhatIf

# Preview an Azure DevOps bootstrap using PATs read from Azure Key Vault.
.\bootstrap\Deploy-BootstrapWithKeyVault.ps1 `
    -Platform AzureDevOps `
    -WhatIf
```

After reviewing the inputs and preview, remove `-WhatIf` to run the selected
deployment. Terraform diagnostic logging is enabled by default. Disable it when it
is unnecessary:

```powershell
# Run the selected bootstrap without Terraform diagnostic logging.
.\bootstrap\Deploy-BootstrapWithKeyVault.ps1 `
    -Platform Local `
    -EnableTerraformLogging:$false
```

For GitHub and Azure DevOps, the wrapper reads the PATs with Azure CLI, exposes them
only through process-scoped `TF_VAR_*` variables, and removes the variables in a
`finally` block. The local workflow does not retrieve PATs.

## Validation

Format-check the maintained Terraform variable files before committing changes:

```powershell
# Verify that the active configuration and both templates use Terraform formatting.
terraform fmt -check `
    .\bootstrap\config\platform-landing-zone.tfvars `
    .\bootstrap\config\templates\custom_management_only.tfvars `
    .\bootstrap\config\templates\custom_virtual-wan.tfvars
```

After generating a Terraform root module, initialize it without a backend and
validate it from that generated module's directory:

```powershell
# Validate generated Terraform without connecting to the remote backend.
terraform init -backend=false
terraform validate
```

Always inspect a fresh Terraform plan before an apply. Do not reuse a saved plan
from a failed or cancelled deployment.

## Destroy and cleanup

Bootstrap destruction uses the same wrapper and should always be previewed first:

```powershell
# Preview destruction of the selected local bootstrap deployment.
.\bootstrap\Deploy-BootstrapWithKeyVault.ps1 `
    -Platform Local `
    -Destroy `
    -WhatIf
```

`Cleanup-LandingZone.ps1` is a separate, destructive utility that removes every
resource group in its configured subscription allowlist. The checked-in IDs and
names are samples, but replacing them with live values makes the script capable of
real deletion.

```powershell
# Preview every resource group that the cleanup allowlist would target.
.\bootstrap\scripts\Cleanup-LandingZone.ps1 -WhatIf

# Preview one explicitly selected subscription from the allowlist.
.\bootstrap\scripts\Cleanup-LandingZone.ps1 `
    -SubscriptionName 'Sample Management Subscription' `
    -WhatIf
```

Review the complete preview before removing `-WhatIf`. The cleanup script uses
explicit subscription IDs and never relies on the active Azure CLI subscription for
its deletion targets.

## Security and publication

- Never commit PATs, client secrets, Terraform state, saved plans, generated output,
  diagnostic logs, or local CLI configuration.
- Treat Terraform state, backups, and logs as sensitive even when input files do not
  contain plaintext secrets.
- Rotate any credential that has previously been exposed.
- Sanitizing the latest files does not remove sensitive values from Git history.
  Rewrite the affected history or publish from a new clean repository before making
  an old repository public.
- Review `.gitignore` whenever new generated-file locations or tools are introduced.
- Run a secret scanner over the complete repository and its intended publication
  history before pushing to a public remote.

## Notes and troubleshooting

The `notes/` folder contains working material covering security-module experiments,
OIDC trust mismatches, PAT permissions, regional capacity issues, management-group
delays, and existing-subscription side effects. These documents are useful evidence
and background, but they may refer to generated paths or versions that are no longer
present. Prefer the current `bootstrap/` source and a newly generated plan when the
two disagree. The notes were not part of the bootstrap sanitization pass; review them
separately for historical tenant, application, subscription, path, and organization
identifiers before publication.

This project is a lab and reference implementation, not a production-ready landing
zone. Review governance, networking, identity, policy, cost, and operational settings
for the target tenant before deployment.
