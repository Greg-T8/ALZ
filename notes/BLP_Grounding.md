# ALZ Consolidation – Codex Grounding Context

## Objective

Rework the existing Azure Landing Zones / ALZ Accelerator configuration for a small client so that the management-group and subscription structure is substantially simpler than the default Microsoft ALZ reference architecture while preserving the governance capabilities that are actually needed.

This is a deliberate tailoring of ALZ, not an attempt to reproduce the default reference architecture exactly.

The key design goal is:

> Preserve meaningful governance, security, connectivity, and policy boundaries without creating management groups and subscriptions that provide no practical value for this client's scale.

---

# Client context

The client is small.

Platform administration:

- Approximately 3 people manage the Azure platform.
- The same small team is responsible for the major platform functions.
- There is no practical organizational need today for separate Azure subscriptions corresponding to:
  - Identity
  - Security
  - Management
  - Connectivity

Workload administration:

- There is currently only one developer creating workload resources.
- There is no current organizational or governance requirement that warrants separate `Corp` and `Online` workload branches.
- Current workloads have sufficiently similar ownership and governance requirements that a single workload management group is preferred.

The design should remain extensible so that additional management groups or subscriptions can be introduced later if governance requirements diverge.

---

# Default ALZ structure being simplified

The standard ALZ conceptual structure resembles:

```text
<Client Root>
│
├── Platform
│   ├── Connectivity
│   ├── Identity
│   ├── Management
│   └── Security
│
├── Landing Zones
│   ├── Corp
│   └── Online
│
├── Sandbox
└── Decommissioned
```

The intent is to consolidate this substantially.

---

# Proposed target management-group hierarchy

The desired model is approximately:

```text
<Client Root>
│
├── Platform
│
├── Workloads
│
├── Sandbox
│
└── Decommissioned
```

`Landing Zones` may be renamed to:

```text
Workloads
```

because that name more directly represents the purpose of the branch for this client.

If changing the management-group ID would cause unnecessary Terraform/ALZ churn, it is acceptable to retain an internal ID such as:

```text
landingzones
```

while changing only the display name to:

```text
Workloads
```

unless there is a compelling reason to rename the ID as well.

---

# Platform subscription design

The client likely does not need four separate subscriptions for:

```text
Identity
Security
Management
Connectivity
```

Instead, the intended architecture is:

```text
Platform
└── Platform Subscription
```

The Platform subscription can contain resource groups separating major platform responsibilities, for example:

```text
sub-platform
├── rg-connectivity
├── rg-management
├── rg-security
└── rg-identity
```

where applicable.

This is an intentional simplification of Microsoft's default ALZ subscription design.

The architectural rationale is that the operational boundaries that would normally justify separate subscriptions do not currently exist for this client.

Separate subscriptions can be introduced later if required by:

- RBAC / administrative separation
- Security isolation
- Regulatory requirements
- Subscription limits or quotas
- Billing or chargeback
- Blast-radius concerns
- Distinct operational teams

Platform must remain separate from Workloads even though the individual Platform functions are being consolidated.

---

# Workload management-group design

The standard ALZ design includes:

```text
Landing Zones
├── Corp
└── Online
```

Those branches are workload archetypes, not organizational teams.

For this client, separate Corp and Online management groups currently provide little practical benefit because the workloads do not have sufficiently different:

- governance requirements
- security requirements
- networking requirements
- compliance requirements
- ownership models

The target is therefore:

```text
Workloads
├── workload subscription
├── workload subscription
└── ...
```

rather than:

```text
Landing Zones
├── Corp
└── Online
```

The architecture should allow Corp/Online-like branches to be reintroduced later if workload governance diverges.

---

# Critical policy design principle

Do NOT treat consolidation as:

```text
Landing Zones policies
+
Corp policies
+
Online policies
=
Workloads policies
```

The consolidated `Workloads` archetype should instead represent:

> The common policy baseline that should apply to every workload subscription.

Child policies should only be promoted to `Workloads` if they are intended to be universally applicable.

The correct conceptual model is:

```text
Landing Zones baseline
+
Corp/Online policies determined to be universally applicable
=
Workloads baseline
```

This is important because assigning a policy at `Workloads` means every current and future workload underneath it receives that assignment.

Azure Policy assignments accumulate through the hierarchy.

A child management group cannot simply override an enforced ancestor assignment if requirements later diverge.

Therefore, moving a policy upward changes its architectural meaning.

---

# Existing test configuration

The existing test environment already performs management-group consolidation.

The test target hierarchy is:

```text
tate-test
├── platform
├── landingzones
├── sandbox
└── decommissioned
```

The child management groups intended for removal are:

```text
security
management
connectivity
identity
corp
online
```

The consolidation test uses two custom archetype overrides:

```text
platform_consolidated
landing_zones_consolidated
```

The relevant files are:

```text
ALZ_Test_Management_Group_Consolidation.md
Brownfield.md
```

The Terraform/ALZ configuration currently references files conceptually equivalent to:

```text
lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml

lib/archetype_definitions/platform_consolidated.alz_archetype_override.yaml

lib/archetype_definitions/landing_zones_consolidated.alz_archetype_override.yaml

platform-landing-zone.auto.tfvars
```

The ALZ library dependency used by the test is pinned to:

```text
2026.08.0
```

The pinned library definitions, not GitHub `main`, should be treated as authoritative when determining the effective policy composition.

---

# Existing Platform consolidation

The test currently consolidates child Platform policies upward into `Platform`.

The custom `platform_consolidated` archetype currently includes policies such as:

```text
Deny-MgmtPorts-Internet
Deny-Public-IP
Deny-Subnet-Without-Nsg
Deploy-VM-Backup
Deploy-AMBA-Connectivity
Deploy-AMBAConnectivity2
Deploy-AMBA-Identity
Deploy-AMBA-Management
```

The existing test documentation notes:

- Security has no direct ALZ policy assignments that need to move.
- Management has no direct ALZ policy assignments that need to move.
- Connectivity normally includes `Enable-DDoS-VNET`, but the active Connectivity customization removes it, so the test does not promote it to Platform.

When reworking this configuration, preserve the intent of those existing customizations rather than blindly using the raw upstream ALZ archetypes.

---

# Existing workload consolidation

The existing consolidation test currently starts from the Landing Zones archetype and promotes the following Corp policies to the parent:

```text
Audit-PeDnsZones
Deny-HybridNetworking
Deny-Public-Endpoints
Deny-Public-IP-On-NIC
Deploy-Private-DNS-Zones
```

The current Online archetype contributes no direct ALZ or AMBA policy assignments.

Online receives its governance primarily through inherited Landing Zones/root policies.

Therefore, from a policy perspective, the current workload consolidation is effectively:

```text
Landing Zones baseline
+
Corp-specific policies
```

rather than a meaningful combination of two independent Corp and Online policy sets.

This distinction is important when redesigning `Workloads`.

---

# Centralized Private DNS decision

There was an apparent inconsistency between the two source markdown files regarding:

```text
Deploy-Private-DNS-Zones
```

That design decision has now been resolved.

The Platform side of the architecture will contain the global Azure Private DNS zones.

Private DNS will be centrally managed by Platform.

Conceptually:

```text
Platform
│
└── Platform Subscription
    ├── Global Private DNS zones
    ├── Private DNS Resolver
    └── Central DNS management
```

Workload subscriptions should consume the centralized DNS service rather than deploy their own copies of shared/global zones.

Therefore:

```text
Deploy-Private-DNS-Zones
```

should NOT be promoted into the consolidated `Workloads` archetype.

The existing `corp_custom` behavior that removes `Deploy-Private-DNS-Zones` is consistent with the intended architecture.

The consolidation test that currently adds `Deploy-Private-DNS-Zones` to `landing_zones_consolidated` should therefore be corrected.

The intended ownership model is:

```text
Platform
    Own global Private DNS zones
    Own Private DNS Resolver infrastructure
    Own centralized DNS configuration
    Own shared/global zone management

Workloads
    Consume centralized DNS
    Do not deploy duplicate global Private DNS zones
```

Consider whether workload policies should audit or prevent unauthorized/decentralized Private DNS zone creation instead of deploying zones into workload subscriptions.

---

# Corp policy review

Do not automatically promote all remaining Corp policies.

Review each policy based on whether it should apply universally to every workload.

Current policies requiring review include:

```text
Audit-PeDnsZones
Deny-HybridNetworking
Deny-Public-Endpoints
Deny-Public-IP-On-NIC
```

## Audit-PeDnsZones

Likely useful at `Workloads`.

Since Private DNS is centrally owned by Platform, this policy may provide useful detection of Private DNS zones created in workload subscriptions.

Confirm the exact policy behavior before retaining it.

## Deny-HybridNetworking

Review against the client's intended connectivity architecture.

Do not retain simply because it existed in Corp.

Determine exactly what resources/configurations it denies and whether those restrictions should apply to every workload subscription.

## Deny-Public-Endpoints

This requires careful review.

Promoting it to Workloads means:

```text
No workload beneath Workloads may use the affected public endpoints.
```

That is a major architectural decision.

Retain it only if this organization intends all workload services to use private access.

If public-facing workloads could reasonably be required later, placing this policy at Workloads could make future separation more difficult.

## Deny-Public-IP-On-NIC

This may be appropriate as a universal workload rule if the client has no valid reason to attach public IPs directly to VM NICs.

However, validate the intended network model before retaining it.

A future internet-facing workload does not necessarily require a public IP directly on a NIC; public exposure could instead be provided through controlled ingress services.

---

# Important distinction: public workloads versus public NICs

Do not assume that removing Corp/Online means public workloads are unsupported.

A workload can be externally accessible while still complying with centrally controlled ingress patterns.

Examples could include:

```text
Application Gateway
Azure Front Door
Load Balancer
Firewall
other centralized ingress services
```

Therefore, evaluate the actual policy semantics instead of assuming every "public" policy must be removed when Corp/Online are collapsed.

---

# Design for future growth

The initial hierarchy should remain simple:

```text
Workloads
```

but it should be possible later to introduce differentiated workload branches such as:

```text
Workloads
├── Private
└── Public
```

or equivalent archetypes.

To preserve that option:

> Do not place a policy at Workloads if that policy represents a characteristic that might distinguish one future workload archetype from another.

Policies at `Workloads` should be common-denominator governance.

Policies representing workload-specific behavior should remain capable of being assigned lower in the hierarchy later.

---

# Policy consolidation matrix

Create or derive a policy consolidation matrix before changing the final configuration.

Suggested columns:

```text
Current Scope
Assignment
Current Effect
Current Parameters
Inherited From
Proposed Scope
Universal Requirement?
Promote?
Remove?
Reason
```

Example:

| Current Scope | Policy | Proposed Scope | Universal? | Action |
|---|---|---|---|---|
| Landing Zones | baseline policy | Workloads | Yes | Retain |
| Corp | Audit-PeDnsZones | Workloads | Likely | Review/retain |
| Corp | Deny-HybridNetworking | Workloads | TBD | Review |
| Corp | Deny-Public-Endpoints | Workloads | TBD | Review |
| Corp | Deny-Public-IP-On-NIC | Workloads | TBD | Review |
| Corp | Deploy-Private-DNS-Zones | None | No | Remove from workload consolidation |
| Online | No direct assignments | N/A | N/A | Nothing to promote |

This matrix should be based on the effective ALZ policy set, not simply raw archetype assignment counts.

---

# Effective policy composition

When analyzing the current architecture, distinguish between:

```text
direct assignments
```

and:

```text
effective assignments
```

A Corp or Online subscription receives:

```text
root policies
+
Landing Zones policies
+
child-specific policies
```

The effective policy set is therefore more important than the number of direct assignments on the child archetype.

The existing Brownfield documentation explicitly treats inherited policies as part of the target policy composition.

Use the same principle for consolidation.

---

# Brownfield implications

The Brownfield design should remain separate from permanent workload classification.

Brownfield is a migration/assessment mechanism, not a permanent workload archetype.

Conceptually:

```text
Existing Subscription
        │
        ▼
Workloads - Brownfield
        │
        ├── evaluate
        ├── remediate
        └── validate
        │
        ▼
Workloads
```

The Brownfield copy should represent the same policy content as the real Workloads target but use:

```text
enforcementMode = DoNotEnforce
```

where appropriate.

Do not change Deny policies themselves to Audit merely to make Brownfield safe.

Example:

```text
Workloads
effect = Deny
enforcementMode = Default
```

versus:

```text
Workloads - Brownfield
effect = Deny
enforcementMode = DoNotEnforce
```

This allows Azure Policy to show what would fail without blocking operations.

---

# Azure Policy inheritance caveat

Assignments inherited from a parent cannot be neutralized from a child simply by assigning a different enforcement mode locally.

For example:

```text
<Client Root>
   │
   │ enforced assignment
   ▼
Workloads - Brownfield
```

A `DoNotEnforce` assignment created at the Brownfield child does not disable a separate enforcing assignment inherited from the parent.

Therefore, review policies assigned at:

```text
Tenant Root
<Client Root>
Platform/Workloads parent scopes
```

before using Brownfield.

Root-level:

```text
Deny
Modify
DeployIfNotExists
```

assignments deserve particular scrutiny.

Possible treatments include:

- leave enforced because they are universally safe;
- move them lower in the hierarchy;
- use exclusions;
- use Azure Policy exemptions;
- temporarily use `DoNotEnforce` where architecturally possible.

---

# Existing staged consolidation method

Retain the staged approach already used successfully in the test.

## Stage A – establish parent policy coverage

Create the consolidated policy assignments at the parent scopes while leaving the existing child management groups intact.

Expected temporary state:

```text
parent assignment
+
child assignment
```

This temporary duplicate coverage is intentional.

The purpose is to eliminate governance gaps while transitioning.

Do not move subscriptions or delete management groups during this stage.

Review the Terraform plan carefully.

## Stage B – move subscriptions

After the new parent policies are confirmed:

```text
child MG → parent MG
```

For example:

```text
Management → Platform
```

or eventually:

```text
Corp/Online → Workloads
```

Verify the subscription receives the intended effective policy set.

A management-group move immediately changes inherited policy and RBAC scope.

Existing resources can become noncompliant immediately even though Azure Policy does not necessarily remediate them automatically.

## Stage C – remove obsolete child management groups

Only after effective policies have been validated:

remove:

```text
Identity
Security
Management
Connectivity
Corp
Online
```

Preserve:

```text
Sandbox
Decommissioned
```

Verify Terraform deletes only the intended management groups and redundant assignments.

Do not combine hierarchy deletion with unrelated policy changes.

---

# Terraform / ALZ implementation principles

When reworking the ALZ configuration:

1. Use custom architecture/archetype files.
2. Do not edit downloaded `.alzlib` content directly.
3. Base decisions on the pinned ALZ library version.
4. Preserve intentional existing overrides.
5. Calculate effective policy sets programmatically where practical.
6. Generate a fresh Terraform plan after every applied stage.
7. Do not reuse an old saved Terraform plan after state changes.
8. Review individual resource actions, not only the Terraform summary counts.
9. Ensure DeployIfNotExists and Modify assignments have the required managed identities / role assignments.
10. Ensure no resource is represented by two conflicting Terraform owners after consolidation.

---

# Desired final architecture

Conceptually:

```text
<Client Root>
│
├── Platform
│   │
│   └── Platform Subscription
│       ├── shared networking
│       ├── Private DNS Resolver
│       ├── global Private DNS zones
│       ├── centralized monitoring
│       ├── security platform resources
│       └── other shared platform services
│
├── Workloads
│   │
│   ├── Workload Subscription A
│   ├── Workload Subscription B
│   └── ...
│
├── Sandbox
│
└── Decommissioned
```

Potential temporary migration structure:

```text
<Client Root>
│
├── Platform
│
├── Workloads
│
├── Workloads - Brownfield
│
├── Sandbox
│
└── Decommissioned
```

---

# Core architectural rules

Treat these as the principal design constraints.

## Rule 1

Platform and workloads remain separate governance boundaries.

## Rule 2

Platform functions may share one subscription because the client currently lacks meaningful ownership/isolation requirements requiring four separate Platform subscriptions.

## Rule 3

Corp and Online should not exist merely because the default ALZ architecture contains them.

Create workload child archetypes only when actual policy/governance requirements diverge.

## Rule 4

`Workloads` contains common-denominator workload governance.

Do not define it as the union of every possible ALZ workload archetype.

## Rule 5

A child policy may be promoted to `Workloads` only if the policy should apply to every workload beneath it.

## Rule 6

Global Private DNS is centrally owned by Platform.

Do not promote `Deploy-Private-DNS-Zones` into Workloads.

## Rule 7

Preserve future extensibility.

Avoid parent-level assignments that would make a future Private/Public or regulated/unregulated workload split unnecessarily difficult.

## Rule 8

Brownfield policy content should match the target workload baseline while enforcement is relaxed using assignment-level `DoNotEnforce`.

## Rule 9

Always reason about effective policy inheritance, not only direct archetype assignments.

## Rule 10

Policy consolidation should be intentional and documented policy-by-policy.

---

# Immediate Codex task

Review and rework the existing ALZ configuration to implement the simplified architecture.

Specifically:

1. Review the current custom architecture definition.
2. Review:
   - `platform_consolidated`
   - `landing_zones_consolidated`
   - Corp customizations
   - Online customizations
   - AMBA archetypes
   - policy modifiers
3. Calculate the effective policy composition of:
   - Platform
   - Identity
   - Security
   - Management
   - Connectivity
   - Landing Zones
   - Corp
   - Online
4. Produce a proposed consolidated Platform policy set.
5. Produce a proposed consolidated Workloads policy set.
6. Do not automatically union all child assignments.
7. Explicitly exclude `Deploy-Private-DNS-Zones` from Workloads because Private DNS zones are centrally managed by Platform.
8. Identify each Corp/Online policy whose semantics change materially when promoted to Workloads.
9. Pay particular attention to:
   - `Audit-PeDnsZones`
   - `Deny-HybridNetworking`
   - `Deny-Public-Endpoints`
   - `Deny-Public-IP-On-NIC`
10. Recommend whether each of those policies should:
    - move to Workloads,
    - remain available only for a future child archetype,
    - be removed,
    - or be replaced by a different centralized governance control.
11. Preserve Sandbox and Decommissioned.
12. Maintain the staged migration pattern:
    - establish parent policies,
    - validate,
    - move subscriptions,
    - validate effective policy,
    - remove obsolete child groups.
13. Update the Brownfield design so its policy composition mirrors the finalized Workloads target.
14. Recalculate Brownfield `policy_assignments_to_modify` based on the finalized effective Workloads policy set rather than the old 57-assignment assumption.
15. Produce Terraform/ALZ changes in a way that minimizes unnecessary resource replacement and management-group churn.

Do not assume the current consolidation test is the final desired policy model. It was a functional test proving that policies could be moved upward safely in stages.

The new task is to turn that successful consolidation mechanism into the correct client-specific ALZ architecture.
