<!--
# -------------------------------------------------------------------------
# Program: BLP_Platform_and_Workloads_Implementation_Guide.md
# Description: Configure the ALZ bootstrap source for consolidated Platform,
#              Workloads, and temporary Workloads - Brownfield management groups.
# Context: ALZ BLP effort - small-client management-group simplification
# Author: Greg Tate
# ------------------------------------------------------------------------
-->

# BLP Platform and Workloads implementation guide

## Purpose and scope

This guide describes how to revise the bootstrap configuration at
`C:\Users\gregt\LocalCode\Lab\alz-test\bootstrap\config` for the BLP
management-group model. The durable target has one **Platform** management
group and one **Workloads** management group below `tate-test`; **Sandbox**
and **Decommissioned** remain unchanged. A temporary **Workloads -
Brownfield** sibling is included to assess and remediate existing workload
subscriptions before their promotion to enforced Workloads governance.

The guide changes configuration only. It does not authorize a Terraform apply,
subscription move, policy exemption, remediation task, or bootstrap rerun.
Those actions require a reviewed plan and normal change approval.

## Target architecture

```text
tate-test
├── Platform
│   └── Platform subscription
│       ├── shared connectivity
│       ├── centralized Private DNS and DNS Resolver
│       ├── monitoring and security platform resources
│       └── other shared platform services
├── Workloads
│   └── enforced workload subscriptions
├── Workloads - Brownfield
│   └── existing workload subscriptions under assessment
├── Sandbox
└── Decommissioned
```

`Workloads - Brownfield` is a migration control plane, not a permanent
workload classification. Its policy content must mirror **Workloads**. Its
direct assignments use `DoNotEnforce` while a subscription is assessed;
promotion moves that subscription to **Workloads**, where the same assignment
set is enforced with `Default`.

> [!IMPORTANT]
> Azure Policy assignments and RBAC inherit down the management-group tree. A
> `DoNotEnforce` assignment at Brownfield cannot neutralize a separate
> enforcing assignment inherited from `tate-test` or the tenant root. Inventory
> those assignments before moving a subscription into Brownfield.

Azure Policy's enforcement mode evaluates compliance without applying the
policy effect during creates or updates, but remediation tasks can still be
run deliberately. See [Azure Policy assignment structure](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure)
and [safe deployment of Azure Policy assignments](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/policy-safe-deployment-practices).

## Current-state findings

The bootstrap source currently contains the default child groups beneath
`platform` (`security`, `management`, `connectivity`, and `identity`) and
the `corp` and `online` children beneath `landingzones`. It also places the
management subscription directly under `management`.

Two sources require deliberate reconciliation:

| Source | Role in this change | Important finding |
| --- | --- | --- |
| `bootstrap\config` | Source requested for change; make BLP edits here. | It is still the unconsolidated default shape. |
| `alz-test\alz-mgmt` | Evidence from an older generated/managed consolidation experiment; do not copy it blindly. | Its Brownfield modifier list is based on an old effective set and includes `Deploy-Private-DNS-Zones`. |
| `notes\BLP_Grounding.md` | BLP design authority for this guide. | Private DNS is centrally owned by Platform; `Deploy-Private-DNS-Zones` must not be promoted to Workloads. |

Do not maintain divergent definitions in both locations. For this effort,
make `bootstrap\config` the intended source, propagate it through the normal
Accelerator/repository workflow, and compare the resulting generated
configuration and plan before deployment. Do not edit downloaded `.alzlib`
content.

## Naming decision

Use the following IDs and display names unless an existing deployed
management group makes the compatibility option necessary:

| Purpose | Preferred ID | Display name | Compatibility option |
| --- | --- | --- | --- |
| Workload baseline | `workloads` | `Workloads` | Retain ID `landingzones` and change only the display name to `Workloads` to avoid a management-group replacement or state migration. |
| Brownfield staging | `workloads-brownfield` | `Workloads - Brownfield` | Use `landingzones-brownfield` only when retaining `landingzones` as the stable workload ID. |

The remainder of this guide uses the compatibility option: `landingzones` is
the stable management-group ID and **Workloads** is its display name. This
minimizes churn for an existing configuration. If `tate-test` is genuinely
greenfield, substitute `workloads` consistently in the architecture,
`policy_assignments_to_modify`, subscription placement, Terraform state, and
validation commands before any deployment.

## Prerequisites and evidence to collect

1. Confirm that the current ALZ Library pin remains `platform/alz` version
   `2026.08.1` in `lib\alz_library_metadata.json`. Base all policy decisions
   on that pinned version, not GitHub `main`.
2. Capture the live management-group tree, subscription placement, policy
   assignments, policy exemptions, and management-group RBAC assignments for
   the tenant root, `tate-test`, current `platform`, current `landingzones`,
   `corp`, and `online`.
3. Confirm that the identity executing a subscription move has the required
   permissions on the subscription, its current parent, and its target parent.
   A moved subscription inherits policy and RBAC from its new parent. See
   [move subscriptions between management groups](https://learn.microsoft.com/en-us/azure/governance/management-groups/manage).
4. Record the effective policy set for each current scope. Effective means
   inherited assignments plus direct assignments, with assignment parameters,
   enforcement mode, identity, and exclusions; it does not mean only the
   assignments listed in an archetype file.
5. Decide whether the existing AMBA archetypes are part of the intended
   Workloads baseline. If they are, attach the same AMBA archetype(s) to both
   Workloads and Brownfield. If they are not, do not introduce them as an
   incidental part of this consolidation.

Use this policy-consolidation matrix before writing an override:

| Current scope | Assignment | Effect and parameters | Inherited from | Proposed scope | Universal requirement? | Decision and rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `landingzones` | Each base assignment | Capture from the `2026.08.1` effective set | `tate-test` as applicable | Workloads | Review | Baseline; retain only if it is required for every workload. |
| `corp` | `Audit-PeDnsZones` | Verify exact definition behavior | Landing Zones/root as applicable | Workloads or future child | Pending | Likely useful only if it supports the centralized-DNS model for every workload. |
| `corp` | `Deny-HybridNetworking` | Verify exact denied configuration | Landing Zones/root as applicable | Future child by default | No decision yet | Promote only if every workload must have the same hybrid-networking restriction. |
| `corp` | `Deny-Public-Endpoints` | Verify affected services and parameters | Landing Zones/root as applicable | Future child by default | No decision yet | A universal deny would constrain a future public-workload branch. |
| `corp` | `Deny-Public-IP-On-NIC` | Verify effect and exclusions | Landing Zones/root as applicable | Workloads if approved | Conditional | Reasonable for controlled ingress, but document the approved ingress pattern first. |
| `corp` | `Deploy-Private-DNS-Zones` | DeployIfNotExists | Landing Zones/root as applicable | None | No | Exclude: Platform owns global Private DNS zones and Resolver infrastructure. |
| `online` | Direct assignments | Verify from the pinned library | Landing Zones/root as applicable | N/A | N/A | The prior test found no direct assignments; recheck the pin before relying on that result. |

> [!NOTE]
> An internet-facing workload does not require a public IP on a VM NIC. It may
> use controlled ingress such as Application Gateway, Front Door, Load
> Balancer, or Firewall. Do not equate `Deny-Public-IP-On-NIC` with "no public
> workloads."

## Task 1: Create the consolidated override definitions

Create these files under
`bootstrap\config\lib\archetype_definitions`:

- `platform_consolidated.alz_archetype_override.yaml`
- `workloads_consolidated.alz_archetype_override.yaml`

An archetype override is a local delta over a named base archetype; the
architecture must reference the override name. See [ALZ Library archetype overrides](https://azure.github.io/Azure-Landing-Zones-Library/assets/archetype-overrides/).

### Platform override

Start from `platform`. Preserve the prior consolidation intent only after
reconfirming it against the pinned library. The BLP grounding identifies these
child-derived assignments as the previous Platform candidates:

```yaml
base_archetype: platform
name: platform_consolidated
policy_assignments_to_add:
  - Deny-MgmtPorts-Internet
  - Deny-Public-IP
  - Deny-Subnet-Without-Nsg
  - Deploy-VM-Backup
  - Deploy-AMBA-Connectivity
  - Deploy-AMBAConnectivity2
  - Deploy-AMBA-Identity
  - Deploy-AMBA-Management
policy_assignments_to_remove: []
policy_definitions_to_add: []
policy_definitions_to_remove: []
policy_set_definitions_to_add: []
policy_set_definitions_to_remove: []
role_definitions_to_add: []
role_definitions_to_remove: []
```

Do not reintroduce `Enable-DDoS-VNET` unless the current, intentional
`connectivity_custom` decision to remove it has been revisited and approved.
The Security and Management base archetypes previously had no direct ALZ
policy assignments to promote; confirm that remains true for the pin.

### Workloads override

Start from `landing_zones`, which retains the ALZ workload baseline. Add only
the child assignments that the completed policy matrix marks as universal. The
following is a safe scaffold, not permission to populate every former Corp
assignment:

```yaml
base_archetype: landing_zones
name: workloads_consolidated
policy_assignments_to_add:
  # Add only policy names approved as common-denominator workload governance.
  # Example: Deny-Public-IP-On-NIC, after the ingress decision is documented.
policy_assignments_to_remove:
  # Keep existing intentional Landing Zones exclusions, if any.
  - Enable-DDoS-VNET
policy_definitions_to_add: []
policy_definitions_to_remove: []
policy_set_definitions_to_add: []
policy_set_definitions_to_remove: []
role_definitions_to_add: []
role_definitions_to_remove: []
```

Never add `Deploy-Private-DNS-Zones` to this file. If the completed matrix
shows a need to prevent decentralized DNS, use a separately reviewed audit or
deny control that fits centralized Platform ownership; do not duplicate global
Private DNS zones in workload subscriptions.

## Task 2: Stage the architecture before retiring legacy children

In `lib\architecture_definitions\alz_custom.alz_architecture_definition.yaml`,
make the parent-archetype and Brownfield additions first. The block below is
the **final Stage D architecture**, not the Stage A change for a live tree.
Retain `sandbox` and `decommissioned` exactly as management-group branches.

```yaml
name: alz_custom
management_groups:
  - id: tate-test
    display_name: Tate Test
    archetypes:
      - root_custom
    exists: false
    parent_id: null

  - id: platform
    display_name: Platform
    archetypes:
      - platform_consolidated
      # Retain an approved AMBA platform archetype here only if it is part of
      # the confirmed target effective policy set.
    exists: false
    parent_id: tate-test

  - id: landingzones
    display_name: Workloads
    archetypes:
      - workloads_consolidated
      # Include every approved AMBA workload archetype here.
    exists: false
    parent_id: tate-test

  - id: landingzones-brownfield
    display_name: Workloads - Brownfield
    archetypes:
      - workloads_consolidated
      # Repeat every approved AMBA workload archetype from landingzones here.
    exists: false
    parent_id: tate-test

  - id: sandbox
    display_name: Sandbox
    archetypes:
      - sandbox_custom
    exists: false
    parent_id: tate-test

  - id: decommissioned
    display_name: Decommissioned
    archetypes:
      - decommissioned_custom
    exists: false
    parent_id: tate-test
```

The Brownfield and Workloads `archetypes` lists must be identical. A missing
AMBA archetype on Brownfield would make it a different policy baseline rather
than a safe preview of the target state. Architecture definitions describe the
management-group hierarchy and its archetype assignments; see [ALZ Library architectures](https://azure.github.io/Azure-Landing-Zones-Library/assets/architectures/).

For **Stage A** in an existing environment, do not yet remove the `security`,
`management`, `connectivity`, `identity`, `corp`, or `online` blocks. Instead:

1. Change the `platform` archetype reference to `platform_consolidated`.
2. Change the `landingzones` display name to `Workloads` and its archetype
   reference to `workloads_consolidated`.
3. Add `landingzones-brownfield` as a sibling of `landingzones`.
4. Retain the six legacy child blocks and their current archetype references
   until Stage D.

This is intentional temporary duplicate coverage. Removing the legacy blocks
in the same change as adding parent policy assignments can create a governance
gap and makes the plan harder to review. After Stage D succeeds, remove the
now-unreferenced custom override files (`corp_custom`, `online_custom`,
`security_custom`, `management_custom`, `connectivity_custom`, and
`identity_custom`) only if no other architecture definition references them.

## Task 3: Update policy modifiers and subscription placement

Edit `bootstrap\config\platform-landing-zone.tfvars`.

### Set the Platform subscription placement

Replace the active `management` placement with one direct parent under
Platform. Do not leave two active entries for the same subscription.

```hcl
subscription_placement = {
  platform = {
    subscription_id       = "$${subscription_id_management}"
    management_group_name = "platform"
  }
}
```

### Rebuild the Brownfield modifier map

Under `policy_assignments_to_modify`, add a Brownfield entry whose keys are
the complete, **final direct assignment set** created on
`landingzones-brownfield` by `workloads_consolidated` plus any approved AMBA
workload archetypes:

```hcl
landingzones-brownfield = {
  policy_assignments = {
    # Populate from the reviewed, final Workloads effective-policy inventory.
    # Each direct assignment created at Brownfield uses DoNotEnforce.
    "<assignment-name>" = {
      enforcement_mode = "DoNotEnforce"
    }
  }
}
```

Do not copy the old 57-assignment list from `alz-mgmt`. It reflects an older
target composition and contains `Deploy-Private-DNS-Zones`, which conflicts
with the BLP centralized-DNS decision. Do not change policy definitions from
`Deny` to `Audit` for Brownfield; preserve the definition and adjust the
assignment enforcement mode instead.

Assignments inherited from `tate-test` or the tenant root are not created at
Brownfield and cannot be overridden by this map. For each potentially
disruptive inherited `Deny`, `Modify`, or `DeployIfNotExists` assignment,
choose one explicit treatment: accept enforcement, move the assignment lower,
exclude the Brownfield scope where appropriate, or create a time-bound policy
exemption.

## Task 4: Deploy in controlled stages

The stages prevent a governance gap and keep a management-group deletion from
being mixed with policy redesign. Create a new Terraform plan after every
state change; never apply an old saved plan.

### Stage A: Add target parent coverage

1. Add `platform_consolidated` and `workloads_consolidated`.
2. Add Workloads and Workloads - Brownfield to the architecture.
3. Keep the six current child management-group blocks and subscription
   placements in the configuration and live environment until the new policy
   assignment set is created and reviewed.
4. Generate a fresh plan from the generated management repository that
   consumes this source. Review every non-no-op action.
5. Apply only after confirming the plan creates the intended management groups,
   direct policy assignments, and required policy role assignments. It must
   not delete child groups or move subscriptions in this stage.

Temporary duplicate coverage is acceptable during this stage. It is safer
than moving a subscription before the parent baseline exists.

### Stage B: Move the Platform subscription

1. Apply the Platform subscription-placement change only after Stage A
   confirms the consolidated Platform assignments exist.
2. Generate and review a new plan.
3. Confirm that the non-no-op actions are limited to the intended subscription
   placement and its dependent management-group association.
4. Apply through the approved deployment process.
5. Verify inherited Azure Policy and RBAC at the subscription after the move.

### Stage C: Brownfield migration

1. Select one representative workload subscription.
2. Recheck its effective inherited policy and RBAC path, including tenant-root
   and `tate-test` assignments.
3. Move it to Workloads - Brownfield only after confirming the enforced
   ancestor assignments are safe.
4. Wait for policy evaluation to populate, then classify every noncompliance
   finding as a remediation, valid exception, parameter issue, inapplicable
   policy, or policy to remove from the Workloads baseline.
5. Run remediation tasks for `DeployIfNotExists` and `Modify` assignments only
   after review of their managed identity, role assignments, target resources,
   and expected effect.
6. Promote the subscription from Workloads - Brownfield to Workloads when it
   meets the approved compliance and exception threshold.
7. Repeat one subscription at a time until Brownfield is empty.

### Stage D: Retire obsolete management groups

1. Confirm that no subscriptions remain in `security`, `management`,
   `connectivity`, `identity`, `corp`, or `online`.
2. Confirm the direct and effective policy sets at Platform and Workloads match
   the approved matrix.
3. Remove only the six obsolete management-group blocks and policy modifiers
   that reference them.
4. Create a new plan and stop unless every delete is an intended obsolete
   management group or redundant assignment/role assignment.
5. Verify that Sandbox and Decommissioned are unchanged before apply.
6. Apply the reviewed plan and verify the resulting hierarchy, effective
   policy, policy exemptions, and RBAC inheritance.

Remove `landingzones-brownfield` only after its last subscription has been
promoted and the retention/reporting needs for its compliance evidence have
been satisfied.

## Plan review commands

Run plan commands from the actual generated Terraform repository, not from the
bootstrap `config` folder. The configuration source does not itself contain a
Terraform root. The following PowerShell commands are plan-only and use the
existing `alz-test\alz-mgmt` checkout as an example; substitute the generated
repository that is proven to consume this exact source.

```powershell
Set-Location -LiteralPath 'C:\Users\gregt\LocalCode\Lab\alz-test\alz-mgmt'

terraform init -input=false
terraform fmt -check
terraform validate
terraform plan -refresh=true -input=false `
  -out='.\blp-stage-a.tfplan'
terraform show -no-color '.\blp-stage-a.tfplan'
```

Review planned actions in a compact list:

```powershell
$plan = terraform show -json '.\blp-stage-a.tfplan' |
    ConvertFrom-Json

$plan.resource_changes |
    Where-Object { $_.change.actions -notcontains 'no-op' } |
    Select-Object address, @{ Name = 'Actions'; Expression = {
        $_.change.actions -join ', '
    } }
```

For each stage, save the plan under a new stage-specific name. Do not use
`terraform init -upgrade` for a configuration-only policy change because it
can update unrelated providers and modules.

## Post-implementation validation

Validate each completed stage with evidence, not only a successful Terraform
summary:

1. The target hierarchy contains Platform, Workloads, Workloads - Brownfield,
   Sandbox, and Decommissioned as direct `tate-test` children during the
   migration; the Brownfield branch disappears only after it is empty.
2. The Platform subscription has Platform as its sole direct management-group
   parent.
3. Workloads and Brownfield have identical direct policy content and
   parameters. Their enforcement modes differ only where Brownfield uses
   `DoNotEnforce`.
4. `Deploy-Private-DNS-Zones` is absent from Workloads and Brownfield. Global
   Private DNS zones and Resolver resources remain Platform-owned.
5. Every policy assignment with a managed identity still has its required role
   assignment after consolidation.
6. The policy matrix records the final disposition for
   `Audit-PeDnsZones`, `Deny-HybridNetworking`, `Deny-Public-Endpoints`, and
   `Deny-Public-IP-On-NIC`.
7. Sandbox and Decommissioned retain their original hierarchy, assignments,
   and RBAC.
8. Each subscription promotion has recorded policy-compliance evidence,
   approved exemptions, and application health validation.

## Future growth

Keep **Workloads** limited to common-denominator governance. When requirements
genuinely diverge, introduce child branches such as **Private** and **Public**
under Workloads, give each a separately reviewed archetype, and create a
matching temporary Brownfield branch only when migration assessment is needed.
Do not create those branches solely because the default ALZ architecture has
`Corp` and `Online`.

## Sources

- `notes\BLP_Grounding.md` — client-specific BLP design constraints.
- `notes\Brownfield.md` — earlier Brownfield model; superseded where it
  conflicts with centralized Private DNS or the finalized Workloads policy set.
- `bootstrap\config\lib\alz_library_metadata.json` — pinned ALZ Library
  dependency, currently `2026.08.1`.
- [Azure Landing Zones Library architecture definitions](https://azure.github.io/Azure-Landing-Zones-Library/assets/architectures/)
  and [archetype overrides](https://azure.github.io/Azure-Landing-Zones-Library/assets/archetype-overrides/).
- [Azure management groups: moving subscriptions](https://learn.microsoft.com/en-us/azure/governance/management-groups/manage)
  and [Azure Policy assignment enforcement modes](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/assignment-structure).
