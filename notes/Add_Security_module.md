Think of this as deploying a second, minimal copy of ALZ’s “Management Resources” pattern—but pointing it at the Security subscription. Sentinel is enabled on a Log Analytics workspace, so the workspace and Sentinel onboarding must use the same Security-subscription provider context.

| Piece | Responsibility |
|---|---|
| `azurerm.security` | Creates the Security resource group and Log Analytics workspace |
| `azapi.security` | Creates Sentinel onboarding for that workspace |
| `security_resource_settings` | Holds names, location, tags, and the Sentinel setting |
| `module "security_resources"` | Connects those settings and providers to the AVM module |

The stock starter has only the corresponding Management module: [main.management.resources.tf](C:/Users/gregt/LocalCode/Lab/ALZ/output/starter/v17.4.0/platform_landing_zone/main.management.resources.tf:1). You add a parallel Security path.

## 1. Make the Security subscription available

You need a real Security subscription ID in `subscription_ids["security"]`, and normally this placement remains:

```hcl
subscription_placement = {
  security = {
    subscription_id       = "$${subscription_id_security}"
    management_group_name = "security"
  }
}
```

That placement organizes the subscription beneath the Security management group. It does not deploy Sentinel by itself.

## 2. Add Security provider aliases

In `terraform.tf`, add providers analogous to the existing Management providers:

```hcl
provider "azurerm" {
  resource_provider_registrations = "none"
  alias                           = "security"
  subscription_id                 = var.subscription_ids["security"]

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {
  alias                      = "security"
  skip_provider_registration = true
  subscription_id            = var.subscription_ids["security"]
}
```

Both are needed because the AVM creates the workspace through AzureRM and Sentinel onboarding through AzAPI. The AVM explicitly supports `sentinel_onboarding = {}` to enable Sentinel with defaults. [AVM module documentation](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-management)

## 3. Declare and template the Security settings

Create `variables.security.tf` by copying the `management_resource_settings` type from [variables.management.tf](C:/Users/gregt/LocalCode/Lab/ALZ/output/starter/v17.4.0/platform_landing_zone/variables.management.tf:1), renaming the variable, and adding an explicit enablement switch:

```hcl
variable "security_resources_enabled" {
  description = "Whether to deploy the dedicated Security Log Analytics workspace and Sentinel."
  type        = bool
  default     = false
}

variable "security_resource_settings" {
  description = "Settings for the dedicated Security Sentinel workspace."
  type        = object({
    location                     = string
    log_analytics_workspace_name = optional(string)
    resource_group_name          = optional(string)

    data_collection_rules = optional(object({
      change_tracking = object({
        enabled  = optional(bool, true)
        name     = string
        location = optional(string)
        tags     = optional(map(string))
      })
      vm_insights = object({
        enabled  = optional(bool, true)
        name     = string
        location = optional(string)
        tags     = optional(map(string))
      })
      defender_sql = object({
        enabled = optional(bool, true)
        name    = string
        location = optional(string)
        tags     = optional(map(string))
        enable_collection_of_sql_queries_for_security_research = optional(bool, false)
      })
    }))

    log_analytics_solution_plans = optional(list(object({
      product   = string
      publisher = optional(string)
    })))

    sentinel_onboarding = optional(object({
      name                         = optional(string)
      customer_managed_key_enabled = optional(bool)
    }))

    tags = optional(map(string))

    user_assigned_managed_identities = optional(object({
      ama = object({
        enabled  = optional(bool)
        name     = string
        location = optional(string)
        tags     = optional(map(string))
      })
    }))
  })
  default = null
}
```

Then add this one entry to the `inputs` map in [main.config.tf](C:/Users/gregt/LocalCode/Lab/ALZ/output/starter/v17.4.0/platform_landing_zone/main.config.tf:13):

```hcl
security_resource_settings = var.security_resource_settings
```

That is what allows `$${starter_location_01}` and your custom name replacements to resolve before reaching the new module.

## 4. Add the Security module

Create `main.security.resources.tf` as a parallel of the Management module:

```hcl
module "security_resources" {
  source  = "Azure/avm-ptn-alz-management/azurerm"
  version = "0.9.0"
  count   = var.security_resources_enabled ? 1 : 0

  providers = {
    azurerm = azurerm.security
    azapi   = azapi.security
  }

  automation_account_name                    = null
  linked_automation_account_creation_enabled = false

  location = module.config.outputs.security_resource_settings.location

  resource_group_name = coalesce(
    module.config.outputs.security_resource_settings.resource_group_name,
    "rg-security-${module.config.outputs.security_resource_settings.location}",
  )

  log_analytics_workspace_name = coalesce(
    module.config.outputs.security_resource_settings.log_analytics_workspace_name,
    "law-security-${module.config.outputs.security_resource_settings.location}",
  )

  resource_group_creation_enabled     = true
  data_collection_rules               = module.config.outputs.security_resource_settings.data_collection_rules
  log_analytics_solution_plans        = module.config.outputs.security_resource_settings.log_analytics_solution_plans
  sentinel_onboarding                 = module.config.outputs.security_resource_settings.sentinel_onboarding
  user_assigned_managed_identities    = module.config.outputs.security_resource_settings.user_assigned_managed_identities
  tags                                = coalesce(module.config.outputs.security_resource_settings.tags, module.config.outputs.tags)
  enable_telemetry                    = var.enable_telemetry
}
```

The important difference from the stock module is the provider map: both resources are bound to Security.

## 5. Configure the minimal Security workspace

In your authored `config/platform-landing-zone.tfvars`:

```hcl
security_resources_enabled = true

security_resource_settings = {
  location                     = "$${starter_location_01}"
  resource_group_name          = "$${security_resource_group_name}"
  log_analytics_workspace_name = "$${security_log_analytics_workspace_name}"

  # An empty object enables Sentinel with its default onboarding settings.
  sentinel_onboarding = {}

  # Prevent the AVM's monitoring defaults from being created here.
  data_collection_rules = {
    change_tracking = {
      enabled = false
      name    = "dcr-security-change-tracking"
    }
    vm_insights = {
      enabled = false
      name    = "dcr-security-vm-insights"
    }
    defender_sql = {
      enabled = false
      name    = "dcr-security-defender-sql"
    }
  }

  log_analytics_solution_plans = []

  user_assigned_managed_identities = {
    ama = {
      enabled = false
      name    = "uami-security-ama"
    }
  }

  tags = {
    Environment      = "Lab"
    Category         = "Learning"
    Workspace        = "AzureLandingZone"
    Purpose          = "Microsoft Sentinel"
    Owner            = "Greg Tate"
    DateCreated      = "2026-08-11"
    DeploymentMethod = "Terraform"
    ManagedBy        = "terraform"
  }
}
```

With `automation_account_name = null`, Automation disabled, all three DCRs disabled, AMA disabled, and solution plans empty, the intended Security scope is:

```text
Security subscription
└── rg-security-sentinel-...
    └── law-security-sentinel-...
        └── Microsoft Sentinel onboarding
```

Finally, remove `sentinel_onboarding` from `management_resource_settings` if it was previously enabled. The plan should show removal of the Management Sentinel onboarding and creation of the Security workspace/onboarding—not a state move, since these are different Azure resource IDs.

Run:

```powershell
terraform fmt -check
terraform init
terraform validate
terraform plan -refresh=false
```

Make this durable in a maintained starter-template fork or landing-zone repository; edits under generated `output` are liable to be replaced on the next bootstrap/regeneration. The Accelerator is designed for customization, but the stock starter intentionally ships with a single Management-resources deployment path. [ALZ Terraform customization overview](https://azure.github.io/Azure-Landing-Zones/terraform/)
