# ALZ Terraform Library Update Guide

## Purpose

This guide describes how to update the Azure Landing Zones (ALZ) policy
library after the ALZ Terraform deployment is already established.

The update workflow applies to the maintained Terraform deployment directory,
for example:

```text
\Lab\alz-test\alz-mgmt
```

The exact path varies by checkout. Run Terraform from the deployment root that
contains the active `terraform.tf`, provider configuration, state backend, and
`lib\alz_library_metadata.json` files.

## Component ownership and update boundary

The ALZ Accelerator is composed of separate versioned components. They have
different responsibilities and should not be treated as one upgrade stream.

| Component | Responsibility | Normal update point after ALZ deployment |
| --- | --- | --- |
| Accelerator bootstrap modules | Creates the bootstrap environment, repositories, state storage, identity, and delivery plumbing | Initial bootstrap deployment only |
| Accelerator starter modules | Generates the initial Terraform starter/deployment source | Initial bootstrap deployment only |
| ALZ Terraform provider | Connects Terraform to the ALZ policy library and translates library assets into Terraform-managed policy resources | Update deliberately and independently |
| ALZ Terraform module | Defines the Terraform module implementation for the ALZ platform resources | Update deliberately and independently |
| ALZ policy library | Supplies policy definitions, initiatives, archetypes, parameters, and related policy assets | Ongoing post-deployment library updates |

Once the ALZ has been deployed, the `alz-mgmt` Terraform source is the
maintained deployment. The bootstrap modules and starter modules are not
intended to be repeatedly updated or rerun as the normal way to maintain that
deployment. Use them during the initial bootstrap deployment. Subsequent
changes should be made in the deployed Terraform source, reviewed with a
fresh plan, and delivered through the established workflow.

The policy library is the normal component to update when the objective is to
receive new or corrected ALZ policy assets. The ALZ documentation states that
the Terraform module and policy library are decoupled and can be updated
independently.

## Important GitHub and documentation links

### Bootstrap and starter components

- [ALZ Terraform Accelerator](https://github.com/Azure/alz-terraform-accelerator) -
  starter modules and accelerator source.
- [ALZ Terraform Accelerator releases](https://github.com/Azure/alz-terraform-accelerator/releases) -
  review accelerator releases before an initial bootstrap deployment.
- [Example accelerator release v17.5.1](https://github.com/Azure/alz-terraform-accelerator/releases/tag/v17.5.1)
- [Accelerator Bootstrap Modules](https://github.com/Azure/accelerator-bootstrap-modules) -
  Terraform modules used to deploy accelerator bootstrap environments.
- [Bootstrap module releases](https://github.com/Azure/accelerator-bootstrap-modules/releases)

### Terraform implementation

- [ALZ Terraform provider](https://github.com/Azure/terraform-provider-alz) -
  provider implementation, including library handling.
- [ALZ Terraform provider releases](https://github.com/Azure/terraform-provider-alz/releases)
- [Terraform ALZ module](https://github.com/Azure/terraform-azurerm-avm-ptn-alz) -
  Azure Verified Pattern module used by the Terraform deployment.
- [Terraform ALZ module releases](https://github.com/Azure/terraform-azurerm-avm-ptn-alz/releases)

### Policy library

- [Azure Landing Zones Library](https://github.com/Azure/Azure-Landing-Zones-Library) -
  policy definitions, initiatives, archetypes, and related assets.
- [ALZ Library releases](https://github.com/Azure/Azure-Landing-Zones-Library/releases)
- [Example library release: platform/alz/2026.08.1](https://github.com/Azure/Azure-Landing-Zones-Library/releases/tag/platform%2Falz%2F2026.08.1)
- [ALZ Terraform update guidance](https://azure.github.io/Azure-Landing-Zones/terraform/howtos/update/)

## How to update the ALZ policy library

### 1. Review the library release

Read the release notes and identify the exact library tag to test. Do not
assume that every library release will produce a Terraform diff. A release
may affect an asset that is not used by the current archetypes, policy
assignments, or enabled deployment features.

Also check the versioning implications. The ALZ documentation states that
patch releases are not expected to contain breaking changes, while a year or
month change may contain breaking changes and requires a more detailed review.

### 2. Update the maintained library reference

Use the reference mechanism already present in the active deployment.

For a local library checkout, update the dependency in:

```text
<deployment-root>\lib\alz_library_metadata.json
```

For example, the dependency should identify the reviewed `platform/alz` tag:

```json
{
  "dependencies": [
    {
      "path": "platform/alz",
      "ref": "2026.08.1"
    }
  ]
}
```

The exact surrounding metadata may differ. Preserve the existing structure
and change only the intended library reference.

If the deployment directly uses the ALZ provider's `library_references`
configuration instead, update the `platform/alz` reference there. Do not
create a second competing reference without understanding the provider's
precedence rules.

Do not update a different checkout by mistake. A plan run from
`alz-test\alz-mgmt` reads that deployment root's `lib` directory; changing
`alz-sbx\alz-mgmt\lib` does not change the `alz-test` plan.

### 3. Initialize without unintentionally upgrading other components

From the active deployment root, initialize Terraform:

```powershell
Set-Location 'C:\path\to\active\alz-mgmt'
terraform init -input=false
```

For a library-only update, do not use `terraform init -upgrade` unless a
provider or Terraform module upgrade is also intentional. `-upgrade` can
change provider or module selections beyond the library change being reviewed.

### 4. Create a fresh saved plan

Generate a new plan after changing the library reference:

```powershell
terraform plan `
  -refresh=true `
  -input=false `
  -out=.\library-update-2026.08.1.tfplan
```

Use a new, version-specific plan filename while testing. This makes it clear
which library version the plan was created against.

### 5. Inspect the plan before applying

Display the saved plan:

```powershell
terraform show -no-color .\library-update-2026.08.1.tfplan
```

`terraform show` only displays the saved plan. It does not reread the library
metadata or create a new plan. Always run `terraform plan` again after changing
the library reference.

Review at least:

- policy definition and policy set definition changes;
- policy assignment changes and their management-group scopes;
- parameter changes and default values;
- any additions, removals, or renames of policy assets;
- changes affecting protected scopes such as `Sandbox` or `Decommissioned`;
- unexpected resource replacement or deletion;
- whether the plan is truly a no-op.

A no-op is possible and does not automatically indicate a failed library
update. It can mean that the release contains fixes for assets not used by the
current deployment, or that the updated asset produces no difference in the
currently selected configuration. It can also indicate that the wrong
checkout was updated or that an old saved plan was displayed.

### 6. Apply only the reviewed plan

If the plan is correct and approved, apply the exact saved plan:

```powershell
terraform apply .\library-update-2026.08.1.tfplan
```

Do not regenerate the plan between review and apply unless the state or source
has changed. If it has changed, create and review a new plan.

### 7. Validate policy behavior

After applying a library update:

- confirm the Terraform apply completed successfully;
- inspect the resulting policy definitions, initiatives, and assignments in
  Azure;
- check policy assignment scopes and parameter values;
- determine whether remediation is required for `DeployIfNotExists` or
  `Modify` policies;
- record the library tag and plan result in the deployment change history.

Terraform updates the policy resources and assignments it manages. Azure
Policy compliance and remediation may take additional time and may require a
separate remediation operation.

## Recommended maintenance model

```text
Initial bootstrap
    -> bootstrap modules
    -> starter modules
    -> generated alz-mgmt deployment

Ongoing ALZ management
    -> maintain alz-mgmt source
    -> update reviewed ALZ library reference
    -> terraform plan
    -> review
    -> terraform apply
    -> validate Azure Policy and remediation
```

Keep the accelerator and bootstrap repositories bookmarked for release notes,
security notices, and future new deployments. Their release does not by
itself require regenerating an already deployed ALZ environment.
