<#
# -------------------------------------------------------------------------
# Program: New-BootstrapKeyVault.ps1
# Description: Create an Azure Key Vault for ALZ bootstrap PAT storage.
# Context: ALZ lab - bootstrap credential storage provisioning.
# Author: Greg Tate
# -------------------------------------------------------------------------
.SYNOPSIS
Creates an Azure Key Vault for the ALZ bootstrap PAT workflow.

.DESCRIPTION
Validates a target Azure subscription and existing resource group, inherits the
resource group's location, and creates a new Standard Key Vault with Azure RBAC
authorization and public network access. The signed-in human user receives the
Key Vault Secrets Officer role at vault scope.

The script never changes the active Azure CLI subscription. Every subscription-
scoped command receives the resolved subscription ID explicitly. Existing vaults
are treated as errors and are not modified.

.CONTEXT
ALZ lab - bootstrap credential storage provisioning.

.AUTHOR
Greg Tate

.NOTES
Program: New-BootstrapKeyVault.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    "PSReviewUnusedParameter",
    "",
    Justification = "Parameters are consumed by helpers dot-sourced into the Main script block."
)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [ValidatePattern("^(?!.*--)[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$")]
    [string]$KeyVaultName,

    [hashtable]$Tag = @{}
)

#region CONFIGURATION
# Define the fixed security, lifecycle, role, and governance settings for the vault.
$ScriptConfig = [ordered]@{
    RoleName          = "Key Vault Secrets Officer"
    Sku               = "standard"
    RetentionDays     = 7
    ProviderNamespace = "Microsoft.KeyVault"
    ProviderRegistrationPollSeconds = 5
    ProviderRegistrationMaxAttempts = 60
    GraphResourceUri  = "https://graph.microsoft.com"
    GraphMeUri        = "https://graph.microsoft.com/v1.0/me?`$select=id,userPrincipalName"
    DefaultTags       = [ordered]@{
        Environment      = "Lab"
        Purpose          = "ALZ Bootstrap"
        Owner            = "Greg Tate"
        DateCreated      = [DateTime]::UtcNow.ToString("yyyy-MM-dd")
        DeploymentMethod = "PowerShell"
    }
}
#endregion

#region MAIN
# Run the Key Vault provisioning workflow end-to-end.
$Main = {
    . $Helpers

    # Build and validate the effective provisioning configuration.
    $provisioningConfig = Get-BootstrapKeyVaultConfig
    Confirm-KeyVaultPrerequisite

    # Resolve all read-only target and caller information before mutation is considered.
    $subscriptionContext = Get-SubscriptionContext -Config $provisioningConfig
    $keyVaultProviderRegistration = Get-KeyVaultProviderRegistration `
        -Config $provisioningConfig `
        -SubscriptionContext $subscriptionContext
    $resourceGroup = Get-ResourceGroup `
        -Config $provisioningConfig `
        -SubscriptionContext $subscriptionContext
    Confirm-KeyVaultAvailability `
        -Config $provisioningConfig `
        -SubscriptionContext $subscriptionContext
    $signedInUser = Get-SignedInUser `
        -Config $provisioningConfig `
        -SubscriptionContext $subscriptionContext

    # Create the vault and its least-privilege caller assignment after ShouldProcess approval.
    Invoke-KeyVaultProvisioning `
        -Config $provisioningConfig `
        -SubscriptionContext $subscriptionContext `
        -ResourceGroup $resourceGroup `
        -SignedInUser $signedInUser `
        -ProviderRegistration $keyVaultProviderRegistration `
        -WhatIf:$WhatIfPreference
}
#endregion

#region HELPERS
# Provide configuration, validation, Azure CLI, Graph, creation, and RBAC helpers.
$Helpers = {
    function Get-BootstrapKeyVaultConfig {
        # Merge governance defaults with deliberate caller-provided tag overrides.
        [CmdletBinding()]
        param()

        # Copy defaults so the script-level configuration remains immutable.
        $effectiveTag = @{}
        foreach ($entry in $ScriptConfig.DefaultTags.GetEnumerator()) {
            $effectiveTag[$entry.Key] = $entry.Value
        }

        # Validate and apply explicit tag overrides with highest precedence.
        foreach ($entry in $Tag.GetEnumerator()) {
            $tagName = [string]$entry.Key
            $tagValue = [string]$entry.Value

            if ([string]::IsNullOrWhiteSpace($tagName)) {
                throw "Tag names cannot be empty."
            }

            if ([string]::IsNullOrWhiteSpace($tagValue)) {
                throw "Tag '$tagName' must have a non-empty value."
            }

            if ($tagName.StartsWith("-") -or $tagName.Contains("=")) {
                throw "Tag '$tagName' cannot begin with a hyphen or contain an equals sign."
            }

            if ($tagName.Length -gt 512 -or $tagValue.Length -gt 256) {
                throw "Tag '$tagName' exceeds Azure's tag name or value length limit."
            }

            $effectiveTag[$tagName] = $tagValue
        }

        return [pscustomobject]@{
            ResourceGroupName = $ResourceGroupName
            Subscription      = $Subscription
            KeyVaultName      = $KeyVaultName
            Tag               = $effectiveTag
            RoleName          = $ScriptConfig.RoleName
            Sku               = $ScriptConfig.Sku
            RetentionDays     = $ScriptConfig.RetentionDays
            ProviderNamespace = $ScriptConfig.ProviderNamespace
            ProviderRegistrationPollSeconds = $ScriptConfig.ProviderRegistrationPollSeconds
            ProviderRegistrationMaxAttempts = $ScriptConfig.ProviderRegistrationMaxAttempts
            GraphResourceUri  = $ScriptConfig.GraphResourceUri
            GraphMeUri        = $ScriptConfig.GraphMeUri
        }
    }

    function Confirm-KeyVaultPrerequisite {
        # Ensure Azure CLI is installed before any account or resource query is attempted.
        [CmdletBinding()]
        param()

        if (-not (Get-Command -Name "az" -ErrorAction SilentlyContinue)) {
            throw "Azure CLI is required. Install it from https://aka.ms/azure-cli."
        }
    }

    function Get-AzureCliText {
        # Run Azure CLI and return one trimmed text value without changing CLI context.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string[]]$ArgumentList,

            [Parameter(Mandatory)]
            [string]$FailureMessage,

            [switch]$AllowEmptyOutput
        )

        # Capture standard error with command output so Azure failure details remain actionable.
        $commandOutput = & az @ArgumentList 2>&1
        $commandExitCode = $LASTEXITCODE
        $textOutput = ($commandOutput | Out-String).Trim()

        if ($commandExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($textOutput)) {
                throw $FailureMessage
            }

            throw "$FailureMessage Azure CLI detail: $textOutput"
        }

        if (-not $AllowEmptyOutput -and [string]::IsNullOrWhiteSpace($textOutput)) {
            throw $FailureMessage
        }

        return $textOutput
    }

    function Get-AzureCliJson {
        # Run Azure CLI and deserialize its JSON response with a caller-specific error.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string[]]$ArgumentList,

            [Parameter(Mandatory)]
            [string]$FailureMessage
        )

        # Require successful, non-empty JSON output from the Azure CLI command.
        $jsonOutput = Get-AzureCliText `
            -ArgumentList $ArgumentList `
            -FailureMessage $FailureMessage

        try {
            # Deserialize locally to avoid fragile shell-level JMESPath filtering.
            return $jsonOutput | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "$FailureMessage Azure CLI returned invalid JSON."
        }
    }

    function Get-SubscriptionContext {
        # Resolve a subscription name or ID and require a human Azure CLI identity.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config
        )

        # Resolve the caller's supplied subscription to its canonical ID and tenant.
        $account = Get-AzureCliJson `
            -ArgumentList @(
                "account",
                "show",
                "--subscription",
                $Config.Subscription,
                "--output",
                "json",
                "--only-show-errors"
            ) `
            -FailureMessage "Unable to resolve subscription '$($Config.Subscription)'. Confirm Azure CLI login and subscription access."

        if ($account.user.type -ne "user") {
            throw "The target subscription is being accessed as '$($account.user.type)'. Sign in with a human user so the vault-scoped role can be assigned to the bootstrap operator."
        }

        return [pscustomobject]@{
            Id        = $account.id
            Name      = $account.name
            TenantId  = $account.tenantId
            UserName  = $account.user.name
            UserType  = $account.user.type
        }
    }

    function Get-KeyVaultProviderRegistration {
        # Retrieve the Microsoft.KeyVault resource provider registration state.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext
        )

        # Query the provider state in the resolved subscription without changing its active context.
        return Get-AzureCliJson `
            -ArgumentList @(
                "provider",
                "show",
                "--namespace",
                $Config.ProviderNamespace,
                "--subscription",
                $SubscriptionContext.Id,
                "--output",
                "json",
                "--only-show-errors"
            ) `
            -FailureMessage "Unable to determine whether resource provider '$($Config.ProviderNamespace)' is registered in subscription '$($SubscriptionContext.Name)' ($($SubscriptionContext.Id))."
    }

    function Register-KeyVaultProvider {
        # Register Microsoft.KeyVault when needed and wait for it to become usable.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            "PSUseShouldProcessForStateChangingFunctions",
            "",
            Justification = "Invoke-KeyVaultProvisioning gates the complete mutation before this helper is called."
        )]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext,

            [Parameter(Mandatory)]
            [pscustomobject]$ProviderRegistration
        )

        # Avoid an unnecessary registration request when the provider is already ready.
        if ($ProviderRegistration.registrationState -eq "Registered") {
            return
        }

        # Start registration unless Azure has already begun the asynchronous process.
        if ($ProviderRegistration.registrationState -ne "Registering") {
            $null = Get-AzureCliText `
                -ArgumentList @(
                    "provider",
                    "register",
                    "--namespace",
                    $Config.ProviderNamespace,
                    "--subscription",
                    $SubscriptionContext.Id,
                    "--output",
                    "json",
                    "--only-show-errors"
                ) `
                -FailureMessage "Unable to register resource provider '$($Config.ProviderNamespace)' in subscription '$($SubscriptionContext.Name)' ($($SubscriptionContext.Id))." `
                -AllowEmptyOutput
        }

        # Wait for Azure to finish registration before issuing the Key Vault create request.
        for ($attempt = 1; $attempt -le $Config.ProviderRegistrationMaxAttempts; $attempt++) {
            $currentRegistration = Get-KeyVaultProviderRegistration `
                -Config $Config `
                -SubscriptionContext $SubscriptionContext

            if ($currentRegistration.registrationState -eq "Registered") {
                return
            }

            if ($currentRegistration.registrationState -ne "Registering") {
                throw "Resource provider '$($Config.ProviderNamespace)' entered unexpected registration state '$($currentRegistration.registrationState)'. Complete registration in Azure, then rerun this script."
            }

            if ($attempt -lt $Config.ProviderRegistrationMaxAttempts) {
                Start-Sleep -Seconds $Config.ProviderRegistrationPollSeconds
            }
        }

        throw "Resource provider '$($Config.ProviderNamespace)' did not become registered within $($Config.ProviderRegistrationMaxAttempts * $Config.ProviderRegistrationPollSeconds) seconds. Wait for registration to finish, then rerun this script."
    }

    function Get-ResourceGroup {
        # Retrieve the required existing resource group and its authoritative location.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext
        )

        # Query the named group explicitly in the resolved target subscription.
        return Get-AzureCliJson `
            -ArgumentList @(
                "group",
                "show",
                "--name",
                $Config.ResourceGroupName,
                "--subscription",
                $SubscriptionContext.Id,
                "--output",
                "json",
                "--only-show-errors"
            ) `
            -FailureMessage "Resource group '$($Config.ResourceGroupName)' does not exist or is not accessible in subscription '$($SubscriptionContext.Name)' ($($SubscriptionContext.Id))."
    }

    function Confirm-KeyVaultAvailability {
        # Stop before mutation when the supplied vault name already exists in the subscription.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext
        )

        # List subscription vaults once and perform the exact-name comparison locally.
        $existingVault = @(
            Get-AzureCliJson `
                -ArgumentList @(
                    "keyvault",
                    "list",
                    "--subscription",
                    $SubscriptionContext.Id,
                    "--output",
                    "json",
                    "--only-show-errors"
                ) `
                -FailureMessage "Unable to inspect existing Key Vaults in subscription '$($SubscriptionContext.Name)' ($($SubscriptionContext.Id))."
        ) | Where-Object { $_.name -ieq $Config.KeyVaultName }

        if ($existingVault.Count -gt 0) {
            throw "Key Vault '$($Config.KeyVaultName)' already exists in resource group '$($existingVault[0].resourceGroup)'. Existing vaults are not modified by this script."
        }
    }

    function Get-SignedInUser {
        # Resolve the signed-in user's object ID from the target subscription's tenant.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext
        )

        # Acquire a target-tenant Microsoft Graph token without changing active CLI context.
        $graphAccessToken = Get-AzureCliText `
            -ArgumentList @(
                "account",
                "get-access-token",
                "--subscription",
                $SubscriptionContext.Id,
                "--resource",
                $Config.GraphResourceUri,
                "--query",
                "accessToken",
                "--output",
                "tsv",
                "--only-show-errors"
            ) `
            -FailureMessage "Unable to acquire a Microsoft Graph token for tenant '$($SubscriptionContext.TenantId)'."

        try {
            # Query the caller's tenant-specific user object for least-privilege role assignment.
            $graphResponse = Invoke-RestMethod `
                -Method Get `
                -Uri $Config.GraphMeUri `
                -Headers @{
                    Accept        = "application/json"
                    Authorization = "Bearer $graphAccessToken"
                } `
                -ErrorAction Stop

            if ([string]::IsNullOrWhiteSpace($graphResponse.id)) {
                throw "Microsoft Graph returned no signed-in user object ID."
            }

            return [pscustomobject]@{
                Id                = $graphResponse.id
                UserPrincipalName = $graphResponse.userPrincipalName
            }
        }
        catch {
            throw "Unable to resolve the signed-in user's Entra object ID in tenant '$($SubscriptionContext.TenantId)'. $($_.Exception.Message)"
        }
        finally {
            # Release in-memory references containing the short-lived Graph access token.
            $graphAccessToken = $null
            $graphResponse = $null
        }
    }

    function New-KeyVaultResource {
        # Create the new RBAC-enabled Key Vault with explicit lab security settings.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            "PSUseShouldProcessForStateChangingFunctions",
            "",
            Justification = "Invoke-KeyVaultProvisioning gates the complete mutation before this helper is called."
        )]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext,

            [Parameter(Mandatory)]
            [pscustomobject]$ResourceGroup
        )

        # Convert the effective tags into deterministic, safely splatted CLI arguments.
        $tagArgument = @(
            $Config.Tag.GetEnumerator() |
                Sort-Object -Property Key |
                ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }
        )

        # Build vault settings explicitly and omit purge protection because Key Vault defaults it to disabled.
        $argumentList = @(
            "keyvault",
            "create",
            "--name",
            $Config.KeyVaultName,
            "--resource-group",
            $Config.ResourceGroupName,
            "--location",
            $ResourceGroup.location,
            "--subscription",
            $SubscriptionContext.Id,
            "--sku",
            $Config.Sku,
            "--enable-rbac-authorization",
            "true",
            "--public-network-access",
            "Enabled",
            "--default-action",
            "Allow",
            "--bypass",
            "None",
            "--retention-days",
            [string]$Config.RetentionDays,
            "--enabled-for-deployment",
            "false",
            "--enabled-for-disk-encryption",
            "false",
            "--enabled-for-template-deployment",
            "false",
            "--tags"
        )

        # Append tags and output controls as individual arguments to preserve spaces in values.
        $argumentList += $tagArgument
        $argumentList += @(
            "--output",
            "json",
            "--only-show-errors"
        )

        return Get-AzureCliJson `
            -ArgumentList $argumentList `
            -FailureMessage "Unable to create Key Vault '$($Config.KeyVaultName)' in resource group '$($Config.ResourceGroupName)'. The name may be unavailable globally, reserved by soft delete, or blocked by permissions or policy."
    }

    function New-KeyVaultRoleAssignment {
        # Grant the signed-in user secret read/write access at only the vault scope.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            "PSUseShouldProcessForStateChangingFunctions",
            "",
            Justification = "Invoke-KeyVaultProvisioning gates the complete mutation before this helper is called."
        )]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext,

            [Parameter(Mandatory)]
            [pscustomobject]$SignedInUser,

            [Parameter(Mandatory)]
            [pscustomobject]$Vault
        )

        # Assign the built-in role by object ID to avoid a secondary Graph lookup by Azure CLI.
        return Get-AzureCliJson `
            -ArgumentList @(
                "role",
                "assignment",
                "create",
                "--assignee-object-id",
                $SignedInUser.Id,
                "--assignee-principal-type",
                "User",
                "--role",
                $Config.RoleName,
                "--scope",
                $Vault.id,
                "--subscription",
                $SubscriptionContext.Id,
                "--output",
                "json",
                "--only-show-errors"
            ) `
            -FailureMessage "Unable to assign '$($Config.RoleName)' to the signed-in user at vault scope."
    }

    function Invoke-KeyVaultProvisioning {
        # Create the vault and caller role as one deliberate, previewable workflow.
        [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext,

            [Parameter(Mandatory)]
            [pscustomobject]$ResourceGroup,

            [Parameter(Mandatory)]
            [pscustomobject]$SignedInUser,

            [Parameter(Mandatory)]
            [pscustomobject]$ProviderRegistration
        )

        # Preview or confirm provider registration, vault creation, and role assignment together.
        $target = "Key Vault '$($Config.KeyVaultName)' in resource group '$($Config.ResourceGroupName)' and subscription '$($SubscriptionContext.Name)' ($($SubscriptionContext.Id))"
        $action = "Register '$($Config.ProviderNamespace)' if needed, create the bootstrap Key Vault, and assign '$($Config.RoleName)' to the signed-in user"

        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            return
        }

        # Ensure the Key Vault resource provider is ready before its first resource is created.
        Register-KeyVaultProvider `
            -Config $Config `
            -SubscriptionContext $SubscriptionContext `
            -ProviderRegistration $ProviderRegistration

        # Create the vault first because its resource ID is the least-privilege RBAC scope.
        $vault = New-KeyVaultResource `
            -Config $Config `
            -SubscriptionContext $SubscriptionContext `
            -ResourceGroup $ResourceGroup

        try {
            # Make the new vault usable by the current PAT provisioning and deployment workflow.
            $null = New-KeyVaultRoleAssignment `
                -Config $Config `
                -SubscriptionContext $SubscriptionContext `
                -SignedInUser $SignedInUser `
                -Vault $vault
        }
        catch {
            throw "Key Vault '$($Config.KeyVaultName)' was created successfully, but its role assignment failed. The vault was retained to avoid soft-delete name reservation. Assign '$($Config.RoleName)' to object '$($SignedInUser.Id)' at scope '$($vault.id)' before storing PATs. $($_.Exception.Message)"
        }

        # Report safe metadata and the expected Azure RBAC propagation delay.
        Write-Warning "Azure RBAC propagation can take several minutes. If PAT storage is denied, wait briefly and retry."

        return [pscustomobject]@{
            Name              = $vault.name
            ResourceId        = $vault.id
            VaultUri          = $vault.properties.vaultUri
            SubscriptionId    = $SubscriptionContext.Id
            ResourceGroupName = $Config.ResourceGroupName
            Location          = $ResourceGroup.location
            RoleAssignment    = $Config.RoleName
        }
    }
}
#endregion

#region EXECUTION
# Execute the workflow from the script directory and restore the caller's location.
try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
#endregion
