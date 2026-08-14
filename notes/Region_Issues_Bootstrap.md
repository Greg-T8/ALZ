# Regional Issue Notes w/ Bootstrap Deployment

## Container Instances

Capacity issue with 2 vCPU / 4 GB Linux container groups:

- centralus
- southcentralus
- westus2

**Error Messsage:**

"The requested resource is not available in the location 'westus2' at this moment."

**Resolution:**

Fix is documented here: <https://azure.github.io/Azure-Landing-Zones/accelerator/troubleshooting/#error-creating-container-group>

Specify the following in the inputs.yaml file.

```yaml
# GitHub
runner_container_zone_support: false

# Azure DevOps
agent_container_zone_support: false
```

## Storage Accounts

Storage account Standard_ZRS availability issue

- westus

**Error Message:**  

"The storage account failed to create due to redundancy configuration - Sku: Standard_ZRS, Kind: StorageV2 - not available in selected Region - westus.

Set the zone redundancy type in the inputs.yaml file to LRS to avoid this issue."

```yaml
storage_account_replication_type: "LRS"
```

"
