# ALZ Bootstrap — Proxmox runner migration plan

> **Status:** Planning/scaffolding only. Runner installers have not been executed and the ALZ Terraform bootstrap modules have not been customized or applied.

## Current repository inputs

- `bootstrap/Deploy-BootstrapWithKeyVault.ps1` selects GitHub, Azure DevOps, or Local; it fetches bootstrap PATs from Key Vault for platform bootstraps.
- `bootstrap/inputs.github.terraform.yaml` and `bootstrap/inputs.ado.terraform.yaml` currently use self-hosted ACI agents and `use_private_networking: false`.
- Both checked-in inputs pin bootstrap `v7.3.0` and starter `v17.4.0`; confirm deployed versions before modifying or upgrading.
- **Sandbox/ADO currently has `auto_approve: true`**. Explicitly disable it for migration.
- All sample subscription IDs, organizations, regions, Key Vault names and resource names must be replaced and verified for each actual tenant. Do not commit actual secrets.
- Source utility scripts are in top-level `scripts/`, **not** `bootstrap/scripts/`.

## Shared runner hosts

See [runners/README.md](../runners/README.md) for GitHub and Azure DevOps registration scripts.

| Tenant | Pipeline | VM | Selector |
|---|---|---|---|
| Lab | GitHub Actions | `ci-gh-01` | `[self-hosted, linux, x64, azure-iac]` |
| Sandbox | Azure DevOps | `ci-ado-01` | `Azure-IaC` pool |
| Test | Local Terraform | Workstation | None |

Runner VMs are independent of ALZ. Keep registration PATs/tokens separate from OIDC deployment identities. Public Azure Blob state access must be restricted by explicit firewall policy, not inferred from `use_private_networking: false`.

## Change plan for bootstrap modules

1. Pin a checkout/fork of [Azure/accelerator-bootstrap-modules](https://github.com/Azure/accelerator-bootstrap-modules) at the **deployed** version. Apply patches to that pinned checkout, not an unreviewed latest main.
2. **Lab (GitHub):** add separate controls for runner selection and ACI provisioning; let generated `runs-on` use the existing `azure-iac` runner; retain GitHub OIDC environments, identities and Terraform backend.
3. **Sandbox (ADO):** add externally supplied organization pool name; disable Azure ACI/ACR compute but retain or reconcile project agent queue and pipeline authorization; retain ADO federated service connections.
4. Separate Azure Storage public endpoint/firewall rules from ACI/private-networking control. Review existing private endpoints/networking before removing anything.
5. Validate with `terraform fmt`, `terraform init -backend=false`, `terraform validate`, generated YAML inspection, smoke workflows, and **actual state-aware plans**.
6. Only after non-destructive validation, apply an explicitly reviewed migration plan to retire ACI/ACR; confirm no unintended deletion of state, identities, repositories or governance resources.

### Bootstrap wrapper override

The existing wrapper now accepts a local module checkout:

```powershell
.\bootstrap\Deploy-BootstrapWithKeyVault.ps1 `
    -Platform GitHub `
    -BootstrapModuleOverrideFolderPath 'C:\LocalCode\Projects\accelerator-bootstrap-modules' `
    -WhatIf
```

`-WhatIf` previews the wrapper; it does **not** substitute for a Terraform plan. The source path must be an existing folder. Replace `GitHub` with `AzureDevOps` for Sandbox and verify the correct Azure CLI tenant/subscription before running.

### Deployment gates

**Gate 0 — Source inventory:** record ALZ PowerShell version, pinned modules, git SHA, Terraform/provider versions, tenant/subscription, bootstrap state location and state backup.

**Gate 1 — Runner operations:** runner VM is isolated, service starts after reboot, toolchain meets pipeline requirements, selected jobs can reach Azure Storage through approved public network rules.

**Gate 2 — Identity:** GitHub `id-token: write` or ADO `AzureCLI@2/addSpnToEnvironment` federated plan identity works; an apply identity is only tested through approved pipeline checks.

**Gate 3 — Generated workflows:** pipeline routes to external VM; templates, approvals, plan/apply identity, state backend and version pins are unchanged.

**Gate 4 — Terraform plan:** delete only ACI/ACR and demonstrably unused supporting resources; no deletions of storage accounts/containers, service connections, federated credentials, ALZ resources, or shared pools.

**Gate 5 — Cutover:** plan/apply succeed via external runner; no-drift bootstrap plan; previous ACI/ACR billing ceases.

### Rollback

Pause deployment workflows. Restore prior runner routing and, if already removed, reconstruct ACI/ACR from the prior pinned bootstrap code and an approved plan. Reconcile actual resources and Terraform state first; never blindly restore an old state over newer changes.

## Authoritative implementation references

- [ALZ Terraform Accelerator](https://github.com/Azure/alz-terraform-accelerator)
- [Accelerator bootstrap modules](https://github.com/Azure/accelerator-bootstrap-modules)
- [ALZ PowerShell local module override](https://github.com/Azure/ALZ-PowerShell-Module/blob/main/CONTRIBUTING.md)
- [Platform GitHub bootstrap locals](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/alz/github/locals.tf)
- [Platform ADO agent pool](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/modules/azure_devops/agent_pool.tf)
- [Platform bootstrap storage](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/modules/azure/storage.tf)

The [Google Docs implementation guide](https://docs.google.com/document/d/1D9LvkEuGgECXqNT0BvvD3U1tGI9_aKBqDYcCohYxDk4/edit) and [progress tracker](https://docs.google.com/document/d/1rcSpxl0k062yMSowG9I0dJV8Rs0tMzQCG89PfGPMlK4/edit) contain the detailed migration and evidence checklist.
