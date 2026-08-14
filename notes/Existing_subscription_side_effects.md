Short answer: moving an existing subscription under ALZ should not immediately modify, restart, or disable its existing resources. However, it is not completely “side-effect free” because inherited policies immediately govern future resource writes.

| Event | Effect on existing services |
|---|---|
| Subscription moved into ALZ | Existing resources are evaluated and can become noncompliant. They aren’t automatically changed. |
| `Deny` policy finds an existing violation | The resource remains running, but a later create/update operation can be rejected. |
| `DeployIfNotExists` or `Modify` finds an existing violation | It is reported as noncompliant. Existing resources require an explicit remediation task. |
| Someone starts remediation | Policy can modify existing resources or deploy related configuration. |
| A resource is later created or updated | `Deny`, `Modify`, and `DeployIfNotExists` can act automatically. |

Microsoft documents this exact transition behavior: existing resources are assessed but not automatically remediated, while all subsequent writes are evaluated in real time. [Transition existing environments to ALZ](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/enterprise-scale/transition) and [Azure Policy impact guidance](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/evaluate-impact).

For SQL Managed Instance in your configuration:

- The Landing Zones management group assigns `Enforce-TLS-SSL-Q225` with enforcement enabled. Its SQL MI component defaults to `DeployIfNotExists` and targets minimum TLS 1.2: [assignment](C:/Users/gregt/LocalCode/Lab/Azure-Landing-Zones-Library/platform/alz/policy_assignments/Enforce-TLS-SSL-Q225.alz_policy_assignment.json:14), [initiative parameters](C:/Users/gregt/LocalCode/Lab/Azure-Landing-Zones-Library/platform/alz/policy_set_definitions/Enforce-EncryptTransit_20241211.alz_policy_set_definition.json:269).

  - It won’t change an MI merely because the subscription was moved.
  - A later MI update could trigger the deployment.
  - TLS 1.2 is already enforced by Azure SQL MI as of 2026, but legacy clients unable to use TLS 1.2 would lose connectivity. [SQL MI TLS guidance](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/minimal-tls-version-configure?view=azuresql).

- A subscription placed under `Corp` also inherits `Deny-Public-Endpoints`, with SQL MI public access defaulting to `Deny`: [Corp assignments](C:/Users/gregt/LocalCode/Lab/Azure-Landing-Zones-Library/platform/alz/archetype_definitions/corp.alz_archetype_definition.json:7), [SQL MI parameter](C:/Users/gregt/LocalCode/Lab/Azure-Landing-Zones-Library/platform/alz/policy_set_definitions/Deny-PublicPaaSEndpoints.alz_policy_set_definition.json:488).

  - It won’t turn off an existing public endpoint.
  - It can block a subsequent MI update while the instance remains noncompliant.

- The broader SQL guardrail initiative is currently `DoNotEnforce`, so its Entra-only authentication denies and Defender deployment are presently compliance-only: [Enforce-GR-SQL0](C:/Users/gregt/LocalCode/Lab/Azure-Landing-Zones-Library/platform/alz/policy_assignments/Enforce-GR-SQL0.alz_policy_assignment.json:14).

- Root-level policy enables Defender-related SQL configuration, and your override changes `enableAscForSql` to `DeployIfNotExists`: [platform-landing-zone.tfvars](C:/Users/gregt/LocalCode/Lab/ALZ/config/platform-landing-zone.tfvars:171). That is more likely to introduce billing, logging, or security-configuration changes than an outage, but it still deserves deliberate remediation review.

- Your Corp Private DNS deployment assignment is disabled in the active tfvars, reducing that particular onboarding risk: [platform-landing-zone.tfvars](C:/Users/gregt/LocalCode/Lab/ALZ/config/platform-landing-zone.tfvars:205).

I also found no policy-remediation resources authored in the accelerator or generated management repository. Therefore, ALZ deployment itself is not currently configured to launch bulk remediation tasks. An operator could still create one later.

The safe brownfield pattern is:

1. Place the subscription first in a brownfield/canary management group where every effective assignment—including inherited root assignments—is `DoNotEnforce`, disabled, excluded, or covered by a temporary policy exemption.
2. Run compliance evaluation and inventory every `Deny`, `Modify`, and `DeployIfNotExists` result.
3. Specifically test MI, its delegated subnet/NSG/route table, public endpoint setting, TLS clients, monitoring, and Defender configuration.
4. Enable policies incrementally.
5. Run remediation one policy at a time, reviewing the deployment and using a maintenance window where appropriate.
6. Move the subscription into `Corp` or `Online` only after its required control-plane operations have been tested.

Microsoft recommends this duplicated audit-only brownfield approach specifically to avoid affecting active applications. [Brownfield audit-only transition](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/align-approach-duplicate-brownfield-audit-only).

One current-state caveat: the checked-in configuration still has `management_groups_enabled = false`, so this assessment describes the policy behavior after you enable and deploy it; it does not confirm live Azure assignments or compliance: [platform-landing-zone.tfvars](C:/Users/gregt/LocalCode/Lab/ALZ/config/platform-landing-zone.tfvars:122).
