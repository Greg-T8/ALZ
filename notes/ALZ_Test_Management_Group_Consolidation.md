# ALZ Test Management Group Consolidation

## Purpose

This document records the tested consolidation procedure for the `alz-test`
management configuration. The goal is to retain only the Platform and Landing
Zones management groups beneath the `tate-test` root while preserving the
policy coverage previously provided by their child management groups.

The test uses one subscription. Its successful Stage B move changed its parent
management group from `management` to `platform`.

## Scope and guardrails

This procedure applies to:

- Configuration root: `..\alz-test\alz-mgmt`
- Architecture definition:
  `lib\architecture_definitions\alz_custom.alz_architecture_definition.yaml`
- Subscription placement configuration: `platform-landing-zone.auto.tfvars`

Do not modify or remove these management groups:

- `sandbox`
- `decommissioned`

The management groups intended for eventual removal are:

- `security`
- `management`
- `connectivity`
- `identity`
- `corp`
- `online`

The Accelerator bootstrap configuration was intentionally not aligned for this
throwaway test. Do not reuse that exception in a persistent environment: the
maintained source configuration and the generated management repository must
be consistent before a production deployment.

## Definition reference map

All paths in this section are relative to the `ALZ` VS Code workspace root.

The test configuration is composed from the active local definitions below.
These are the files to change for this test; `.alzlib` is downloaded library
content and is not the place for custom edits.

| Purpose | Active test file |
| --- | --- |
| Management-group hierarchy and archetype assignments | `..\alz-test\alz-mgmt\lib\architecture_definitions\alz_custom.alz_architecture_definition.yaml` |
| Consolidated Platform override | `..\alz-test\alz-mgmt\lib\archetype_definitions\platform_consolidated.alz_archetype_override.yaml` |
| Consolidated Landing Zones override | `..\alz-test\alz-mgmt\lib\archetype_definitions\landing_zones_consolidated.alz_archetype_override.yaml` |
| Subscription placement and policy modifiers | `..\alz-test\alz-mgmt\platform-landing-zone.auto.tfvars` |

The consolidated overrides were derived from the following authoritative Azure
Landing Zones Library definitions on GitHub. The test library metadata pins
the dependency to `2026.08.0`; these links use that same version so their
content is stable and reviewable. Treat them as reference inputs when
reassessing which policy assignments need to move; do not edit the library to
create a local override.

| Concern | Azure Landing Zones Library reference |
| --- | --- |
| Base ALZ architecture | [alz architecture](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/alz/architecture_definitions/alz.alz_architecture_definition.json) |
| Parent archetypes | [platform](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/alz/archetype_definitions/platform.alz_archetype_definition.json); [landing_zones](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/alz/archetype_definitions/landing_zones.alz_archetype_definition.json) |
| Platform child archetypes | [security](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/alz/archetype_definitions/security.alz_archetype_definition.json); [management](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/alz/archetype_definitions/management.alz_archetype_definition.json); [connectivity](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/alz/archetype_definitions/connectivity.alz_archetype_definition.json); [identity](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/alz/archetype_definitions/identity.alz_archetype_definition.json) |
| Landing Zones child archetypes | [corp](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/alz/archetype_definitions/corp.alz_archetype_definition.json); [online](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/alz/archetype_definitions/online.alz_archetype_definition.json) |
| AMBA archetypes | [amba_platform](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/amba/archetype_definitions/amba_platform.alz_archetype_definition.json); [amba_connectivity](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/amba/archetype_definitions/amba_connectivity.alz_archetype_definition.json); [amba_management](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/amba/archetype_definitions/amba_management.alz_archetype_definition.json); [amba_identity](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/amba/archetype_definitions/amba_identity.alz_archetype_definition.json); [amba_landing_zones](https://github.com/Azure/Azure-Landing-Zones-Library/blob/2026.08.0/platform/amba/archetype_definitions/amba_landing_zones.alz_archetype_definition.json) |

## Target hierarchy

```text
tate-test
|- platform
|- landingzones
|- sandbox                 (preserved)
`- decommissioned          (preserved)
```

## Policy-consolidation design

Two custom archetype overrides were added in
`lib\archetype_definitions`:

- `platform_consolidated.alz_archetype_override.yaml`
- `landing_zones_consolidated.alz_archetype_override.yaml`

The architecture assigns these overrides to the existing `platform` and
`landingzones` management groups. The child management groups remain in the
architecture during Stages A and B so that hierarchy removal is a separate,
reversible phase.

### Platform policy coverage

`platform_consolidated` retains the Platform base archetype and adds the
child-level policy assignments required from Identity and AMBA:

- `Deny-MgmtPorts-Internet`
- `Deny-Public-IP`
- `Deny-Subnet-Without-Nsg`
- `Deploy-VM-Backup`
- `Deploy-AMBA-Connectivity`
- `Deploy-AMBAConnectivity2`
- `Deploy-AMBA-Identity`
- `Deploy-AMBA-Management`

The Security and Management ALZ archetype definitions have no ALZ policy
assignments to move. Connectivity has `Enable-DDoS-VNET` in its base
definition, but the active Connectivity override removes it; it was therefore
not added to the consolidated Platform archetype.

### Landing Zones policy coverage

`landing_zones_consolidated` retains the Landing Zones base archetype and adds
the Corp assignments:

- `Audit-PeDnsZones`
- `Deny-HybridNetworking`
- `Deny-Public-Endpoints`
- `Deny-Public-IP-On-NIC`
- `Deploy-Private-DNS-Zones`

The Online archetype defines no direct ALZ or AMBA policy assignments. It
inherits the Landing Zones and root governance instead, so no Online-specific
assignment was added.

## Stage A - create parent policy assignments

### Objective

Create the consolidated policy assignments and required policy role
assignments at the parent management groups without deleting child groups or
moving the subscription.

### Configuration changes

1. Create the two consolidated archetype override files.
2. Update the `platform` architecture entry to use
   `platform_consolidated`.
3. Update the `landingzones` architecture entry to use
   `landing_zones_consolidated`.
4. Leave all six child management-group blocks in the architecture.
5. Leave the original subscription placement unchanged for this stage.

### Validation and result

Create a saved plan from the generated Terraform working directory, review it,
and apply only that reviewed plan. The recorded `stage-a.tfplan` had:

- 26 creates
- 789 no-op actions
- 13 parent policy-assignment creates
- 13 policy role-assignment creates
- no management-group create/delete actions
- no subscription-placement changes
- no changes to Sandbox or Decommissioned

The expected temporary state is duplicate policy coverage at both parent and
child scopes. This is intentional and prevents a governance gap while the
subscription is moved and the child groups are later removed.

### Plan-only test commands

Open a PowerShell terminal at the `ALZ` VS Code workspace root, then run these
commands. They create and inspect a plan but make no Azure changes.

```powershell
Set-Location -LiteralPath '..\alz-test\alz-mgmt'

terraform fmt -check
terraform validate
terraform plan -input=false -out=stage-a.tfplan
terraform show -no-color stage-a.tfplan
```

Use the following PowerShell review to list every non-no-op action in the
saved plan:

```powershell
$plan = terraform show -json stage-a.tfplan | ConvertFrom-Json

$plan.resource_changes |
    Where-Object { $_.change.actions -notcontains 'no-op' } |
    Select-Object address, @{ Name = 'Actions'; Expression = {
        $_.change.actions -join ', '
    } }
```

For Stage A, review that the output contains only policy assignments and their
policy role assignments at `platform` and `landingzones`. Stop if it shows a
management-group create/delete, a subscription-placement action, or a change
to Sandbox or Decommissioned.

## Stage B - move the subscription

### Objective

Move the single management subscription from the `management` child group to
the `platform` parent group after Stage A has been applied successfully.

### Configuration change

In `platform-landing-zone.auto.tfvars`, comment out the old `management`
placement and leave one active placement:

```hcl
subscription_placement = {
  platform = {
    subscription_id       = "$${subscription_id_management}"
    management_group_name = "platform"
  }
}
```

The map must contain only one active entry for this subscription. A
subscription can have only one direct management-group parent.

### Validation and result

Generate a fresh plan after the Stage A apply. It should show only the
subscription-placement action(s), not policy-assignment or hierarchy changes.

The Stage B change was applied successfully: the subscription that was
previously placed in `management` is now placed in `platform`. Because
Platform is already governed by the consolidated archetype, the move does not
introduce a policy-coverage gap.

### Plan-only test commands

Open a PowerShell terminal at the `ALZ` VS Code workspace root and create a
new saved plan after the Stage A apply. Do not reuse `stage-a.tfplan`: the
Terraform state has changed.

```powershell
Set-Location -LiteralPath '..\alz-test\alz-mgmt'

terraform plan -input=false -out=stage-b.tfplan
terraform show -no-color stage-b.tfplan
```

List the planned changes with the same targeted review:

```powershell
$plan = terraform show -json stage-b.tfplan | ConvertFrom-Json

$plan.resource_changes |
    Where-Object { $_.change.actions -notcontains 'no-op' } |
    Select-Object address, @{ Name = 'Actions'; Expression = {
        $_.change.actions -join ', '
    } }
```

For Stage B, the non-no-op output should be limited to the subscription
placement action or actions needed to move the subscription to `platform`.
Stop if it includes management-group deletion, policy assignment changes, or
any action for Sandbox or Decommissioned.

## Stage C - remove obsolete child management groups

Stage C is deliberately separate and has not been recorded as completed by
this document. Only begin it after confirming the subscription is directly
under Platform and effective policy assignments are correct.

1. Remove the six obsolete child management-group entries from the architecture
   definition.
2. Remove or retire any policy modifiers that reference only those child
   management groups.
3. Do not remove or alter the `sandbox` or `decommissioned` entries.
4. Create a fresh plan and verify it deletes only the six intended child
   management groups and their now-redundant assignments/role assignments.
5. Confirm no subscriptions remain in the child groups before applying.
6. Apply the reviewed plan, then verify the resulting hierarchy and effective
   policy assignments in Azure.

## Post-change checks

After each apply, verify:

1. `tate-test` has direct children `platform`, `landingzones`, `sandbox`, and
   `decommissioned` only once Stage C is complete.
2. The management subscription is directly under `platform`.
3. The consolidated Platform and Landing Zones policy assignments exist and
   have the expected enforcement mode and parameters.
4. The required policy role assignments exist for deploy-if-not-exists and
   modify assignments.
5. Sandbox and Decommissioned still exist and retain their original
   governance.
6. No Terraform state or configuration is left with two owners for the same
   management group, policy assignment, role assignment, or subscription
   placement.

## Operational notes

- Always create a fresh plan after a successful or failed apply; do not reuse
  an earlier plan once configuration or state has changed.
- Review the actual resource actions. Terraform summary counts alone do not
  prove that the planned scope is safe.
- A management-group move immediately changes inherited policy and RBAC scope.
  Existing resources may be reported noncompliant; a policy assignment does
  not automatically change them unless its remediation behavior is invoked.
