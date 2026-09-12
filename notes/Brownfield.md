For brownfield Azure Landing Zones (ALZ), treat the Brownfield management group as a **migration control plane**: preserve existing workloads, assign only the policies you intentionally want, and progressively move from Audit/DoNotEnforce to enforcement.

For the current Test scenario, I recommend implementing brownfield as a
**temporary parallel Landing Zones management group**, not as a permanent
workload classification. Corp and Online are intentionally out of scope for
this scenario and can be introduced in later scenarios.

Microsoft's recommended brownfield approach is essentially this: duplicate the
Landing Zones management group, apply the same policy baseline in a
non-enforcing mode, move existing subscriptions into it, remediate them, and
then move them back into the normal Landing Zones management group when ready.
Corp and Online promotion paths are deferred until those management groups are
introduced in a later scenario.

## Recommended structure

For the current Test hierarchy, use something conceptually like:

```text
Tate Test
│
├── Platform
│   ├── Connectivity
│   ├── Identity
│   ├── Management
│   └── Security
│
├── Landing Zones
│
├── Landing Zones - Brownfield
│
├── Sandbox
└── Decommissioned
```

The important point for this scenario is that `Landing Zones - Brownfield` is
not a different permanent workload classification. It is a temporary
transition state for subscriptions that are being assessed against the current
Landing Zones policy baseline.

The lifecycle becomes:

```text
Existing subscription
        │
        ▼
Landing Zones - Brownfield
        │
        │  assess
        │  remediate
        │  validate
        ▼
Landing Zones
```

Microsoft specifically describes using a duplicate target management group
with policy assignments in `DoNotEnforce` mode and eventually moving compliant
subscriptions into the normal target group. In this Test scenario, the target
is `Landing Zones`; Corp and Online are reserved for later scenarios.

## Archetype design

For this Test scenario, do not create a separate Brownfield archetype
override. Both management groups use the existing
`landing_zones_consolidated` archetype:

| Management group           | Archetype                   | Based on        |
| -------------------------- | --------------------------- | --------------- |
| Landing Zones              | `landing_zones_consolidated` | `landing_zones` |
| Landing Zones - Brownfield | `landing_zones_consolidated` | `landing_zones` |

The Brownfield management group should contain the **same policy assignments
as the active Landing Zones management group**. Its temporary behavior is
provided by assignment-level `DoNotEnforce` settings, not by a different
policy-content archetype.

That is an important design principle. Do not make brownfield a watered-down permanent policy baseline. It should answer:

> What would happen if this subscription were moved into the current Landing Zones management group today?

The ALZ Library supports archetype overrides when a management group needs a
distinct named policy composition—for example, when it adds or removes policy
assignments, policy definitions, policy set definitions, or role definitions.
That is not needed here because `landing_zones_consolidated` already contains
the effective policy set required by both management groups.

The primary difference between the two management groups is therefore
**enforcement state**, not policy content. The `policy_assignments_to_modify`
map supplies that state for `landingzones-brownfield`.

The `corp_brownfield` and `online_brownfield` archetypes are intentionally not
part of this Test scenario. Introduce the corresponding target management
groups later, reusing their consolidated archetypes unless a distinct policy
composition is required.

When Corp and Online are introduced, repeat the same design for each target.
Do not create a separate Brownfield archetype override solely to change
enforcement. Reuse the target's policy composition where possible and use
`policy_assignments_to_modify` to set the Brownfield assignments to
`DoNotEnforce`.

## Put the management groups into the architecture

A custom architecture for the current Test scenario could contain something
along these lines. Keep the existing Test root and use its actual ID as the
parent; do not create a second ALZ root:

```yaml
- id: landingzones
  display_name: Landing Zones
  archetypes:
    - landing_zones_consolidated
  parent_id: tate-test
  exists: false

- id: landingzones-brownfield
  display_name: Landing Zones - Brownfield
  archetypes:
    - landing_zones_consolidated
  parent_id: tate-test
  exists: false
```

The example assumes `Landing Zones` and `Landing Zones - Brownfield` are
siblings beneath the Test root. If the active architecture uses a different
root ID, substitute that existing root ID consistently.

A custom ALZ architecture is the appropriate mechanism for adding the
Brownfield management-group branch. A separate archetype override is only
needed if the Brownfield branch must differ in policy composition.

### Adding Corp and Online Brownfield branches later

When Corp and Online become active targets, add target-specific Brownfield
management groups and give each one the policy composition it is intended to
assess. A Brownfield group should not be placed beneath an enforcing Corp or
Online management group when the purpose is to neutralize that parent's
assignments. A child group inherits its parent's assignments, and a local
`DoNotEnforce` modification cannot override an enforced ancestor assignment.

The Brownfield branch may be a sibling beneath the Test root, or another
deliberately isolated branch, provided it receives the complete effective
policy composition of the target it represents. The normal target can remain
in the standard ALZ hierarchy. The Brownfield branch should use the target's
archetype composition directly, or a dedicated override if the target needs a
distinct policy composition.

For the current Test library snapshot:

| Target | Direct archetype baseline | Brownfield review |
| ------ | ------------------------- | ----------------- |
| Corp   | `corp_custom` removes `Deploy-Private-DNS-Zones` from `corp` | Include the target's complete effective set, including inherited Landing Zones policies |
| Online | `online_custom` adds no direct assignments to `online` | Do not assume zero assignments; review inherited Landing Zones policies |

The raw direct-assignment counts are not sufficient when Corp and Online are
children of `Landing Zones`. In that arrangement, both targets inherit the
Landing Zones policy assignments. The Brownfield design must either model the
combined target policy composition in its isolated branch or explicitly
account for the inherited assignments before onboarding subscriptions.

## The most important part: `DoNotEnforce`

Do **not** modify all the ALZ `Deny` policies to `Audit`.

Instead, keep the actual ALZ assignments intact and change their assignment-level enforcement mode:

```text
enforcementMode = DoNotEnforce
```

This distinction matters.

Suppose the active Landing Zones policy contains:

```text
Deny-Public-IP-On-NIC
```

In Landing Zones:

```text
effect = Deny
enforcementMode = Default
```

In Landing Zones - Brownfield:

```text
effect = Deny
enforcementMode = DoNotEnforce
```

The second configuration still evaluates resources and reports what would be noncompliant, but it does not block creation or update operations.

That gives a much more accurate answer to:

> Would this workload survive being moved to the current Landing Zones management group?

than changing the actual policy effect from `Deny` to `Audit`.

## With AVM/Terraform

The current `avm-ptn-alz` module supports `policy_assignments_to_modify`, including `enforcement_mode`.

For this Test scenario, the `policy_assignments_to_modify` block must contain
one explicit `DoNotEnforce` declaration for every policy assignment in the
effective `landing_zones_consolidated` archetype used by the Brownfield
management group. The count is calculated
as follows:

```text
53 assignments from the raw landing_zones archetype
+ 5 assignments added by landing_zones_consolidated
- 1 assignment removed by landing_zones_consolidated
= 57 effective assignments
```

The five additions are `Audit-PeDnsZones`, `Deny-HybridNetworking`,
`Deny-Public-Endpoints`, `Deny-Public-IP-On-NIC`, and
`Deploy-Private-DNS-Zones`. The removed assignment is `Enable-DDoS-VNET`.

Use the library version pinned by the Test checkout when calculating this set;
the GitHub `main` file is a reference and may change independently. The
assignment map controls enforcement state; `landing_zones_consolidated`
controls which assignments exist in both the normal and Brownfield copies.

When Corp and Online are later introduced, do not copy the current 57-entry
Landing Zones list blindly. Calculate the effective assignment set for each
target, including inherited assignments and any target-specific additions or
removals. Then create a separate explicit map for each Brownfield target, for
example:

```hcl
policy_assignments_to_modify = {
  landingzones-brownfield = {
    policy_assignments = {
      # One DoNotEnforce entry for each effective Landing Zones assignment
    }
  }

  corp-brownfield = {
    policy_assignments = {
      # One DoNotEnforce entry for each effective Corp assignment
    }
  }

  online-brownfield = {
    policy_assignments = {
      # One DoNotEnforce entry for each effective Online assignment
    }
  }
}
```

If a target archetype has no direct assignments, its Brownfield map may have
no direct entries. That does not make the target safe by itself: inherited
assignments must still be reviewed, and enforced ancestor assignments cannot
be neutralized from the child Brownfield group.

For example:

```hcl
policy_assignments_to_modify = {

  landingzones-brownfield = {
    policy_assignments = {

      Deny-HybridNetworking = {
        enforcement_mode = "DoNotEnforce"
      }

      Deny-Public-Endpoints = {
        enforcement_mode = "DoNotEnforce"
      }

      Deny-Public-IP-On-NIC = {
        enforcement_mode = "DoNotEnforce"
      }

      Deploy-Private-DNS-Zones = {
        enforcement_mode = "DoNotEnforce"
      }
    }
  }
}
```

The relevant assignment enforcement modes are:

```text
Default
DoNotEnforce
```

For an environment with a large ALZ policy set, generate this map
programmatically rather than manually maintaining hundreds of entries. For
this Test scenario, enumerate the complete effective assignment set attached
to the active Landing Zones management group and apply `DoNotEnforce` to all 57
assignments in the Brownfield copy. Do not assume that the examples above are
the complete set. `DoNotEnforce` is operationally most important for `Deny`,
`Modify`, and `DeployIfNotExists` effects; including `Audit` assignments keeps
the Brownfield declaration uniform but does not turn auditing off.

## Important inheritance caveat

Policy inheritance is the part most likely to cause problems.

For this Test scenario, consider:

```text
Tate Test
   ↓ policy assignment
Landing Zones - Brownfield
```

If an enforcing policy is assigned at `Tate Test` or the tenant root, changing
an assignment at `Landing Zones - Brownfield` does **not** override the parent
assignment.

Azure Policy assignments accumulate.

Before placing subscriptions into the brownfield branch, inventory policies inherited from:

```text
Tenant Root
    ↓
Tate Test
    ↓
Landing Zones - Brownfield
```

The `DoNotEnforce` setting belongs to the **policy assignment**, not the evaluated subscription.

You cannot have the exact same parent assignment enforce for Landing Zones
while somehow becoming `DoNotEnforce` when inherited by
Landing Zones - Brownfield.

Classify ALZ assignments by scope:

| Assignment scope       | Brownfield treatment                                         |
| ---------------------- | ------------------------------------------------------------- |
| Tenant root/Test root  | Review carefully; cannot be overridden at child              |
| Landing Zones          | Mirror onto Landing Zones - Brownfield as `DoNotEnforce`     |
| Corp                   | For a Corp Brownfield branch, enumerate direct and inherited target assignments |
| Online                 | For an Online Brownfield branch, enumerate direct and inherited target assignments |
| Platform               | Normally irrelevant to application subscriptions            |

For any **root-level Deny, Modify, or DeployIfNotExists assignment** that could disrupt existing workloads, determine whether it:

* is already safe to enforce everywhere;
* should temporarily remain `DoNotEnforce`;
* should have the brownfield branch excluded;
* requires a policy exemption; or
* should be reassigned lower in the hierarchy.

This root-level review should be one of the first brownfield implementation steps.

## Recommended rollout

Use this progression for the current Test scenario:

1. **Build Landing Zones - Brownfield** as a sibling of Landing Zones.
2. **Mirror the active Landing Zones archetype** rather than creating a completely different brownfield policy baseline.
3. Set applicable brownfield assignments to **`DoNotEnforce`**.
4. Move a small representative subscription into Landing Zones - Brownfield.
5. Allow Azure Policy compliance evaluation to populate.
6. Categorize failures into:

   * configuration remediation;
   * legitimate exception;
   * policy parameter problem;
   * policy not applicable;
   * ALZ policy deliberately not wanted.
7. Remediate `DeployIfNotExists` and `Modify` policies deliberately rather than immediately launching remediation across all brownfield subscriptions.
8. Once a subscription meets the promotion threshold, move it:

```text
Landing Zones - Brownfield → Landing Zones
```

9. Continue until the Brownfield branch is empty.
10. Eventually remove the Brownfield branch from the ALZ architecture.

When Corp and Online are introduced in later scenarios, repeat this pattern
with `corp-brownfield` and `online-brownfield` as target-specific transition
groups. For each group, identify the complete effective target policy set and
declare every applicable assignment explicitly as `DoNotEnforce`. Do not
retroactively classify the current Test subscriptions as Corp or Online
without a separate target-policy and inheritance review.

This follows the general safe-deployment pattern:

```text
DoNotEnforce
      ↓
Evaluate
      ↓
Remediate
      ↓
Validate
      ↓
Enforce
```

## What to avoid

Do **not** create one generic:

```text
Brownfield
```

management group containing every existing subscription.

For this scenario, do not create a generic `Brownfield` group. Use the explicit
`Landing Zones - Brownfield` name so the tested policy target remains clear.
When Corp and Online are later introduced, retain the distinction between:

```text
Corp
Online
```

and any other workload archetypes.

In later scenarios, a privately addressed workload should be tested against the
**Corp target**, while an internet-facing workload should be tested against the
**Online target**. That classification is outside the scope of the current
Test scenario.

ALZ management groups should primarily represent differing governance, networking, security, and platform requirements rather than organizational structure or arbitrary lifecycle stages.

## Target design

The resulting model looks like:

```text
                       Tate Test
                            │
          ┌───────────────┬────────────────┬──────────────────────┐
          │               │                │                      │
        Platform      Landing Zones   Landing Zones - Brownfield Sandbox /
                                      Observe                  Decommissioned
                                          │
                                 Remediate / validate
                                          │
                                          ▼
                                  Move to Landing Zones
```

The brownfield branch should therefore be viewed as a **temporary compatibility and remediation zone**.

For a large ALZ policy estate, this approach cleanly separates **policy acceptance** from **policy enforcement**:

1. prove the Landing Zones baseline is appropriate;
2. measure existing subscription compliance;
3. remediate incompatibilities;
4. document legitimate exceptions;
5. move subscriptions back into the normal Landing Zones management group;
6. introduce Corp and Online as separate target scenarios when required; and
7. enable enforcement progressively rather than making one large enforcement change.
