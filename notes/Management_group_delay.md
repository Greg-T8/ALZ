Management groups sit in Azure’s tenant-wide governance plane, not the normal subscription/resource-group resource plane.

A VM, storage account, or VNet is primarily created in one subscription and region. Azure can acknowledge it once that resource provider’s local state is ready. A management group changes a shared hierarchy above subscriptions, and that hierarchy drives two inherited systems:

- RBAC: access assigned above a subscription must be recalculated for descendants.
- Azure Policy: assignments and scope relationships must be evaluated through the new hierarchy.

That creates more distributed state to converge: the Microsoft.Management service, ARM authorization, policy scope resolution, and cached hierarchy views. Azure explicitly documents that management-group hierarchy and user-token caches can take up to 30 minutes to refresh. [Microsoft Learn](https://learn.microsoft.com/en-us/azure/governance/management-groups/manage)

Your case was unusually sensitive because it reused the same `platform` ID shortly after deletion. The create request can succeed, but the GitHub Actions identity may temporarily receive a `404` (not yet visible) or `403` (inherited permissions not yet recognized) on the immediate read-back. AzAPI deliberately retries exactly those post-create responses. [AzAPI retry behavior](https://registry.terraform.io/providers/azure/azapi/latest/docs/guides/feature_customized_retry)

This is not the normal time for every management-group creation. Your three other siblings finishing in 22 seconds demonstrates that. The delay was the combination of:

1. Tenant-wide hierarchy change.
2. Recent deletion and immediate reuse of `platform`.
3. AzAPI correctly waiting for Azure’s read/authorization view to converge.

Azure even notes that the first management group in a tenant can take up to 15 minutes because it initializes management-group service processes—another sign that this resource type has special tenant-level behavior, though that was not the cause here. [Management group quickstart](https://learn.microsoft.com/en-us/azure/governance/management-groups/create-management-group-portal)
