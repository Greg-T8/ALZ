# Integrating Azure Monitor Baseline Alerts (AMBA) with Azure Landing Zones

## Purpose

This guide explains how to integrate [Azure Monitor Baseline Alerts
(AMBA)](https://azure.github.io/azure-monitor-baseline-alerts/) into an Azure
Landing Zones (ALZ) Terraform Accelerator deployment. It covers the AMBA policy
library, Terraform prerequisites, policy deployment, validation, upgrades, and
remediation.

The examples use the ALZ Terraform Accelerator layout in `alz-test/alz-mgmt`.
Replace placeholders such as `<root-management-group-id>` and
`<management-subscription-id>` with values from the target environment. Do not
place webhook URLs, callback URLs, or other secrets in `.tfvars` files.

## How AMBA is integrated

AMBA has two independent versioned components:

| Component | Responsibility | Example version |
| --- | --- | --- |
| ALZ AMBA library | Archetypes, policy definitions, initiatives, and policy-default parameters | `platform/amba` `2026.06.2` |
| AMBA ALZ Terraform module | Resource group, user-assigned managed identity, and Monitoring Reader assignment | `Azure/avm-ptn-monitoring-amba-alz/azurerm` `0.4.0` |

The versions do not need to match. The library controls Azure Policy content;
the module controls only prerequisite Azure resources.

```text
# Terraform applies prerequisites and ALZ management-group policy assignments.
AMBA library -> amba_root archetype -> ALZ policy assignments
      |                                      |
      v                                      v
AMBA prerequisites                     Azure Policy evaluates resources
(RG, UAMI, Monitoring Reader)          and deploys alert assets with DINE
```

Terraform does not directly create every alert rule. It creates prerequisites
and assignments. The `DeployIfNotExists` (DINE) policies deploy relevant alerts
and action groups after Azure Policy evaluates target subscriptions. Existing
resources may need remediation.

## Prerequisites

- A deployed or planned ALZ management-group hierarchy.
- Permission to create management groups and Azure Policy assignments at the
  ALZ root scope.
- A management subscription for the AMBA resource group and managed identity.
- A notification destination, if notifications are required.
- Terraform and providers compatible with module `0.4.0`: Terraform `~> 1.9`,
  AzureRM `~> 4.0`, and AzAPI `~> 2.4`.

## 1. Reference the AMBA policy library

In `terraform.tf`, load a pinned AMBA library release before the local custom
library.

```hcl
# Load a reviewed AMBA library release before the local custom library.
provider "alz" {
  library_overwrite_enabled = true

  library_references = [
    {
      path = "platform/amba"
      ref  = "2026.06.2"
    },
    {
      custom_url = "${path.root}/lib"
    }
  ]
}
```

Check the [ALZ Library releases](https://github.com/Azure/Azure-Landing-Zones-Library/releases)
when intentionally updating the library. A library update is a policy-content
change, so review the resulting policy-definition and assignment plan.

## 2. Add the AMBA archetype at the root

In `lib/architecture_definitions/<architecture>.alz_architecture_definition.yaml`,
add `amba_root` to the intended root management group.

```yaml
# Assign AMBA policy content at the ALZ root management group.
management_groups:
  - id: <root-management-group-id>
    display_name: Azure Landing Zone
    parent_id: null
    exists: false
    archetypes:
      - root_custom
      - amba_root
```

Use the environment's actual `exists` and `parent_id` values. The AMBA root
must be the same hierarchy root used by the prerequisite module.

## 3. Configure names and AMBA policy defaults

In `platform-landing-zone.auto.tfvars`, add stable names through
`custom_replacements`.

```hcl
# Provide stable names for AMBA prerequisite resources.
custom_replacements = {
  names = {
    amba_resource_group_name                 = "<amba-resource-group-name>"
    amba_user_assigned_managed_identity_name = "<amba-managed-identity-name>"
  }
}
```

Supply common values to AMBA policy assignments through
`management_group_settings.policy_default_values`.

```hcl
# Supply shared AMBA values used by policy assignments.
management_group_settings = {
  policy_default_values = {
    amba_alz_management_subscription_id            = "$${subscription_id_management}"
    amba_alz_resource_group_location               = "$${starter_location_01}"
    amba_alz_resource_group_name                   = "$${amba_resource_group_name}"
    amba_alz_user_assigned_managed_identity_name   = "$${amba_user_assigned_managed_identity_name}"
    amba_alz_action_group_email                    = ["alerts@example.com"]
    amba_alz_arm_role_id                           = []
    amba_alz_resource_group_tags                   = {}
    amba_alz_byo_user_assigned_managed_identity_id = ""
    amba_alz_disable_tag_name                      = ""
    amba_alz_disable_tag_values                    = []
    amba_alz_webhook_service_uri                   = []
    amba_alz_event_hub_resource_id                 = []
    amba_alz_function_resource_id                  = ""
    amba_alz_function_trigger_url                  = ""
    amba_alz_logicapp_resource_id                  = ""
    amba_alz_logicapp_callback_url                 = ""
    amba_alz_byo_alert_processing_rule             = ""
    amba_alz_byo_action_group                      = []
  }
}
```

The `$${...}` values are Accelerator replacement tokens.
Keep both dollar signs; changing them to a single-dollar Terraform expression
would make Terraform evaluate something intended for the accelerator.

Set `amba_alz_action_group_email` to an approved operational recipient. Use a
secret store or pipeline secret for sensitive callback URLs rather than source
control.

## 4. Enable management-group deployment

The ALZ management-group module creates AMBA policy assignments. Ensure this
gate is enabled in `platform-landing-zone.auto.tfvars`.

```hcl
# Enable hierarchy and AMBA policy-assignment deployment.
management_groups_enabled = true
```

If the value is `false`, the prerequisite resource group and identity can
deploy, but the `amba_root` policy assignments will be absent.

## 5. Add the AMBA prerequisite module

Add the module to `main.management.groups.tf` or the equivalent management
Terraform file. Pass the management provider explicitly, then derive the root
ID from the selected architecture definition.

```hcl
# Read the root management-group ID from the selected YAML architecture.
locals {
  root_management_group_name = yamldecode(
    file("${path.root}/lib/architecture_definitions/<architecture>.alz_architecture_definition.yaml")
  ).management_groups[0].id
}

# Create AMBA prerequisites in the management subscription.
module "amba" {
  source  = "Azure/avm-ptn-monitoring-amba-alz/azurerm"
  version = "0.4.0"

  providers = {
    azurerm = azurerm.management
  }

  location                            = var.starter_locations[0]
  root_management_group_name          = local.root_management_group_name
  resource_group_name                 = module.config.custom_replacements.amba_resource_group_name
  user_assigned_managed_identity_name = module.config.custom_replacements.amba_user_assigned_managed_identity_name
}
```

For ALZ `0.21.x`, module `0.4.0` is preferable to the accelerator-page
example of `0.1.1`. It matches the current ALZ module example and fixes
aliased AzureRM provider inheritance in multi-subscription ALZ deployments.
Review the plan carefully because this correction can reveal a historic
provider or subscription-placement mismatch.

## 6. Initialize, plan, and apply

Run commands from the generated management Terraform root. First use a
non-production environment or isolated branch.

```powershell
# Refresh module selections, save the proposal, and inspect it.
terraform init -upgrade
terraform plan -out amba-integration.tfplan
terraform show -no-color amba-integration.tfplan
```

Before applying, confirm that:

- The resource group and identity are in the management subscription.
- Monitoring Reader targets the intended root management group.
- `Deploy-AMBA-*` assignments have the intended management-group scope.
- No AMBA prerequisite is unexpectedly destroyed or recreated.
- A module upgrade does not alter a resource's subscription ID.

```powershell
# Apply only the reviewed, saved AMBA integration plan.
terraform apply amba-integration.tfplan
```

Keep the resulting `.terraform.lock.hcl` update with the configuration change
so other environments resolve the reviewed provider versions.

## 7. Verify Terraform prerequisites and policy assignments

Verify both layers: prerequisites prove the module ran; policy assignments prove
the AMBA archetype was assigned.

```powershell
# Verify AMBA prerequisite resources in the management subscription.
az group show --name <amba-resource-group-name>
az identity show `
  --resource-group <amba-resource-group-name> `
  --name <amba-managed-identity-name>
```

```powershell
# Verify AMBA assignments at the ALZ root management-group scope.
az policy assignment list `
  --scope "/providers/Microsoft.Management/managementGroups/<root-management-group-id>" `
  --query "[?starts_with(name, 'Deploy-AMBA-')].[name,id]" `
  --output table
```

Assignment names vary by library release, but commonly include notification and
Service Health assignments. An assignment proves Azure Policy can begin
evaluation; it does not prove every existing resource already has alerts.

## 8. Evaluate policy and remediate existing resources

For existing resources, trigger a policy scan in every subscription beneath the
AMBA root.

```powershell
# Refresh policy compliance for one subscription beneath the AMBA root.
az policy state trigger-scan `
  --subscription <target-subscription-id> `
  --no-wait
```

The scan refreshes compliance state; it does not guarantee deployment of assets
for existing noncompliant resources. Inspect compliance for the relevant
`Deploy-AMBA-*` assignment and create a remediation task if required. For an
initiative assignment, the Azure portal is often clearest because it prompts
for the specific policy-definition reference.

After evaluation or remediation, inspect the AMBA resource group for action
groups and affected subscriptions for alert rules. Allow for Azure Policy
evaluation and remediation time before diagnosing a missing alert as a failure.

## Upgrade procedure

1. Record the module, library, provider, and lock-file versions.
2. Change one independently versioned component at a time where practical.
3. Run `terraform init -upgrade` and create a fresh saved plan.
4. Review policy definitions, initiatives, assignments, resource group, identity,
   and role-assignment changes separately.
5. Apply only a reviewed plan, then verify management-group assignments.
6. Scan and remediate existing resources only if needed.

For a deployment pinned to module `0.1.1`, do not assume an upgrade is a
no-op. A `0.x` module can change behavior; the plan is the decisive
compatibility test.

## Troubleshooting checklist

| Symptom | First check | Likely meaning |
| --- | --- | --- |
| Prerequisites exist, but no `Deploy-AMBA-*` assignment | `management_groups_enabled` and `amba_root` | Prerequisites deployed, but ALZ did not deploy the policy layer. |
| Assignments exist, but old resources have no alerts | Policy compliance and remediation | DINE policy needs evaluation; existing resources often need remediation. |
| Resources plan in the wrong subscription after an upgrade | Module `providers` block and planned IDs | Investigate provider inheritance before applying. |
| Wrong root scope | Parsed architecture root ID and assignment scope | The module role assignment and `amba_root` must use the same root. |
| Policy parameters are wrong | `policy_default_values` and custom replacement output | Verify token spelling and resolved values. |

## References

- [ALZ Terraform Accelerator: Deploy AMBA](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/options/amba/)
- [AMBA ALZ Terraform module](https://registry.terraform.io/modules/Azure/avm-ptn-monitoring-amba-alz/azurerm/latest)
- [AMBA custom-architecture example](https://registry.terraform.io/modules/Azure/avm-ptn-monitoring-amba-alz/azurerm/latest/examples/custom-architecture-definition)
- [ALZ Library releases](https://github.com/Azure/Azure-Landing-Zones-Library/releases)
- [Azure Policy remediation guidance](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources)
