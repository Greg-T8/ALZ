<#
# -------------------------------------------------------------------------
# Program: New-AzureDevOpsBootstrapPat.ps1
# Description: Create ALZ Azure DevOps PATs and store them in Azure Key Vault.
# Context: ALZ lab - Azure DevOps bootstrap credential provisioning.
# Author: Greg Tate
# -------------------------------------------------------------------------
.SYNOPSIS
Creates the Azure DevOps PATs required by the ALZ bootstrap and stores them in Key Vault.

.DESCRIPTION
Uses the signed-in Azure CLI user's Microsoft Entra token to call the Azure DevOps
PAT Lifecycle Management API. The script creates a one-day bootstrap PAT and a
separate agent-registration PAT, then writes each value directly to Azure Key Vault.
PAT values are never written to the console or passed as command-line arguments.

The Azure CLI session must represent a human user. Azure DevOps does not allow
service principals or managed identities to create or manage PATs.

.CONTEXT
ALZ lab - Azure DevOps bootstrap credential provisioning.

.AUTHOR
Greg Tate

.NOTES
Program: New-AzureDevOpsBootstrapPat.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    "PSReviewUnusedParameter",
    "",
    Justification = "Parameters are consumed by helpers dot-sourced into the Main script block."
)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9-]*$")]
    [string]$OrganizationName,

    [Parameter(Mandatory)]
    [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9-]{1,22}[A-Za-z0-9]$")]
    [string]$KeyVaultName,

    [ValidatePattern("^[0-9A-Za-z-]+$")]
    [string]$BootstrapPatSecretName = "alz-ado-bootstrap-pat",

    [ValidatePattern("^[0-9A-Za-z-]+$")]
    [string]$AgentPatSecretName = "alz-ado-runner-pat",

    [ValidateRange(1, 7)]
    [int]$BootstrapPatLifetimeDays = 1,

    [ValidateRange(1, 365)]
    [int]$AgentPatLifetimeDays = 365
)

#region CONFIGURATION
# Define the Azure DevOps and Key Vault API contracts used by the workflow.
$ScriptConfig = [ordered]@{
    AzureDevOpsResourceId = "499b84ac-1321-427f-aa17-267ca6975798"
    AzureDevOpsApiVersion = "7.1-preview.1"
    KeyVaultResourceUri   = "https://vault.azure.net"
    KeyVaultApiVersion    = "2025-07-01"
    BootstrapPatScopes    = @(
        "vso.agentpools_manage"
        "vso.build_execute"
        "vso.code_full"
        "vso.environment_manage"
        "vso.graph_manage"
        "vso.pipelineresources_manage"
        "vso.project_manage"
        "vso.serviceendpoint_manage"
        "vso.variablegroups_manage"
    )
    AgentPatScopes        = @(
        "vso.agentpools_manage"
    )
}
#endregion

#region MAIN
# Run the PAT creation and Key Vault storage workflow end-to-end.
$Main = {
    . $Helpers

    # Build and validate the effective provisioning configuration.
    $provisioningConfig = Get-PatProvisioningConfig
    Confirm-ProvisioningPrerequisite

    # Acquire user-delegated access and provision both ALZ credentials.
    $authenticationContext = Get-AuthenticationContext -Config $provisioningConfig
    Invoke-PatProvisioning `
        -Config $provisioningConfig `
        -AuthenticationContext $authenticationContext `
        -WhatIf:$WhatIfPreference
}
#endregion

#region HELPERS
# Provide configuration, authentication, API, rollback, and storage helpers.
$Helpers = {
    function Get-PatProvisioningConfig {
        # Build immutable runtime values for both PATs and the target Key Vault.
        [CmdletBinding()]
        param()

        # Use one timestamp so the related token display names can be correlated.
        $timestamp = [DateTimeOffset]::UtcNow
        $displayTimestamp = $timestamp.ToString("yyyyMMdd-HHmmss")

        return [pscustomobject]@{
            OrganizationName       = $OrganizationName
            KeyVaultName           = $KeyVaultName
            BootstrapSecretName    = $BootstrapPatSecretName
            AgentSecretName        = $AgentPatSecretName
            BootstrapDisplayName   = "ALZ Bootstrap $displayTimestamp"
            AgentDisplayName       = "ALZ Agent Registration $displayTimestamp"
            BootstrapValidTo       = $timestamp.AddDays($BootstrapPatLifetimeDays)
            AgentValidTo           = $timestamp.AddDays($AgentPatLifetimeDays)
            BootstrapScopes        = $ScriptConfig.BootstrapPatScopes
            AgentScopes            = $ScriptConfig.AgentPatScopes
            AzureDevOpsResourceId  = $ScriptConfig.AzureDevOpsResourceId
            AzureDevOpsApiVersion  = $ScriptConfig.AzureDevOpsApiVersion
            KeyVaultResourceUri    = $ScriptConfig.KeyVaultResourceUri
            KeyVaultApiVersion     = $ScriptConfig.KeyVaultApiVersion
        }
    }

    function Confirm-ProvisioningPrerequisite {
        # Ensure Azure CLI is available before any remote operation is attempted.
        [CmdletBinding()]
        param()

        if (-not (Get-Command -Name "az" -ErrorAction SilentlyContinue)) {
            throw "Azure CLI is required. Install it from https://aka.ms/azure-cli."
        }
    }

    function Get-AzureCliOutput {
        # Run Azure CLI and return one trimmed value without echoing sensitive output.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string[]]$ArgumentList,

            [Parameter(Mandatory)]
            [string]$FailureMessage
        )

        # Capture both output and exit status so failed authentication cannot continue.
        $commandOutput = & az @ArgumentList 2>$null
        $commandExitCode = $LASTEXITCODE

        if ($commandExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($commandOutput)) {
            throw $FailureMessage
        }

        return ($commandOutput | Out-String).Trim()
    }

    function Get-AuthenticationContext {
        # Acquire user-delegated Azure DevOps and Key Vault access tokens.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config
        )

        # Confirm the active Azure CLI principal is a human user as required by the PAT API.
        $accountJson = Get-AzureCliOutput `
            -ArgumentList @("account", "show", "--output", "json") `
            -FailureMessage "Azure CLI is not logged in. Run 'az login' and retry."
        $account = $accountJson | ConvertFrom-Json

        if ($account.user.type -ne "user") {
            throw "The active Azure CLI identity is '$($account.user.type)'. Sign in with a human user because service principals and managed identities cannot create Azure DevOps PATs."
        }

        # Resolve the target vault URI through the ARM control plane.
        $vaultUri = Get-AzureCliOutput `
            -ArgumentList @(
                "keyvault",
                "show",
                "--name",
                $Config.KeyVaultName,
                "--query",
                "properties.vaultUri",
                "--output",
                "tsv"
            ) `
            -FailureMessage "Unable to resolve Key Vault '$($Config.KeyVaultName)'. Confirm the name, subscription context, and ARM permissions."

        # Acquire the delegated token used by the Azure DevOps PAT Lifecycle API.
        $azureDevOpsAccessToken = Get-AzureCliOutput `
            -ArgumentList @(
                "account",
                "get-access-token",
                "--resource",
                $Config.AzureDevOpsResourceId,
                "--query",
                "accessToken",
                "--output",
                "tsv"
            ) `
            -FailureMessage "Unable to acquire a user-delegated Microsoft Entra token for Azure DevOps."

        # Acquire a separate data-plane token for the Key Vault secret SET operations.
        $keyVaultAccessToken = Get-AzureCliOutput `
            -ArgumentList @(
                "account",
                "get-access-token",
                "--resource",
                $Config.KeyVaultResourceUri,
                "--query",
                "accessToken",
                "--output",
                "tsv"
            ) `
            -FailureMessage "Unable to acquire a Microsoft Entra token for Azure Key Vault."

        return [pscustomobject]@{
            AzureDevOpsAccessToken = $azureDevOpsAccessToken
            KeyVaultAccessToken    = $keyVaultAccessToken
            VaultUri               = $vaultUri.TrimEnd("/")
            SignedInUser           = $account.user.name
            TenantId               = $account.tenantId
        }
    }

    function New-AzureDevOpsPat {
        # Create one PAT for the signed-in user with the requested scopes and lifetime.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            "PSUseShouldProcessForStateChangingFunctions",
            "",
            Justification = "Invoke-PatProvisioning gates the complete mutation before this helper is called."
        )]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$AuthenticationContext,

            [Parameter(Mandatory)]
            [string]$DisplayName,

            [Parameter(Mandatory)]
            [string[]]$Scopes,

            [Parameter(Mandatory)]
            [DateTimeOffset]$ValidTo
        )

        # Build the organization-scoped PAT request without logging its response.
        $requestUri = "https://vssps.dev.azure.com/$($Config.OrganizationName)/_apis/tokens/pats?api-version=$($Config.AzureDevOpsApiVersion)"
        $requestHeaders = @{
            Accept        = "application/json"
            Authorization = "Bearer $($AuthenticationContext.AzureDevOpsAccessToken)"
        }
        $requestBody = [ordered]@{
            displayName = $DisplayName
            scope       = $Scopes -join " "
            validTo     = $ValidTo.UtcDateTime.ToString("o")
            allOrgs     = $false
        } | ConvertTo-Json -Compress

        try {
            # Create the token and retain its one-time value only in process memory.
            $response = Invoke-RestMethod `
                -Method Post `
                -Uri $requestUri `
                -Headers $requestHeaders `
                -ContentType "application/json" `
                -Body $requestBody `
                -ErrorAction Stop

            if (
                [string]::IsNullOrWhiteSpace($response.patToken.token) -or
                [string]::IsNullOrWhiteSpace($response.patToken.authorizationId)
            ) {
                # Revoke a token that was created but returned without its one-time value.
                if (-not [string]::IsNullOrWhiteSpace($response.patToken.authorizationId)) {
                    try {
                        Revoke-AzureDevOpsPat `
                            -Config $Config `
                            -AuthenticationContext $AuthenticationContext `
                            -AuthorizationId $response.patToken.authorizationId
                    }
                    catch {
                        Write-Warning "Azure DevOps returned an incomplete PAT response and automatic rollback failed. Revoke authorization '$($response.patToken.authorizationId)' manually."
                    }
                }

                throw "Azure DevOps returned an incomplete PAT response."
            }

            return [pscustomobject]@{
                DisplayName     = $response.patToken.displayName
                AuthorizationId = $response.patToken.authorizationId
                Token           = $response.patToken.token
                Scope           = $response.patToken.scope
                ValidTo         = [DateTimeOffset]$response.patToken.validTo
            }
        }
        catch {
            throw "Unable to create Azure DevOps PAT '$DisplayName'. $($_.Exception.Message)"
        }
        finally {
            # Release request and response references that can contain authentication material.
            $requestBody = $null
            $response = $null
        }
    }

    function Revoke-AzureDevOpsPat {
        # Revoke a newly created PAT when its Key Vault write does not complete.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$AuthenticationContext,

            [Parameter(Mandatory)]
            [string]$AuthorizationId
        )

        # Address the exact token authorization returned by the create operation.
        $encodedAuthorizationId = [Uri]::EscapeDataString($AuthorizationId)
        $requestUri = "https://vssps.dev.azure.com/$($Config.OrganizationName)/_apis/tokens/pats?authorizationId=$encodedAuthorizationId&api-version=$($Config.AzureDevOpsApiVersion)"
        $requestHeaders = @{
            Accept        = "application/json"
            Authorization = "Bearer $($AuthenticationContext.AzureDevOpsAccessToken)"
        }

        # Revoke the orphaned credential without emitting the REST response.
        $null = Invoke-RestMethod `
            -Method Delete `
            -Uri $requestUri `
            -Headers $requestHeaders `
            -ErrorAction Stop
    }

    function Set-KeyVaultPatSecret {
        # Store one PAT through the Key Vault REST API without a command-line secret value.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            "PSUseShouldProcessForStateChangingFunctions",
            "",
            Justification = "Invoke-PatProvisioning gates the complete mutation before this helper is called."
        )]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$AuthenticationContext,

            [Parameter(Mandatory)]
            [string]$SecretName,

            [Parameter(Mandatory)]
            [string]$Purpose,

            [Parameter(Mandatory)]
            [pscustomobject]$Pat
        )

        # Build a versioned Key Vault secret with non-secret rotation metadata.
        $encodedSecretName = [Uri]::EscapeDataString($SecretName)
        $requestUri = "$($AuthenticationContext.VaultUri)/secrets/${encodedSecretName}?api-version=$($Config.KeyVaultApiVersion)"
        $requestHeaders = @{
            Accept        = "application/json"
            Authorization = "Bearer $($AuthenticationContext.KeyVaultAccessToken)"
        }
        $requestBody = [ordered]@{
            value       = $Pat.Token
            contentType = "application/vnd.azure-devops.pat"
            attributes  = @{
                enabled = $true
                exp     = $Pat.ValidTo.ToUnixTimeSeconds()
            }
            tags        = @{
                AuthorizationId = $Pat.AuthorizationId
                Organization    = $Config.OrganizationName
                Purpose         = $Purpose
                ValidToUtc      = $Pat.ValidTo.UtcDateTime.ToString("o")
            }
        } | ConvertTo-Json -Depth 5 -Compress

        try {
            # Write the PAT to Key Vault and retain only the non-secret version identifier.
            $response = Invoke-RestMethod `
                -Method Put `
                -Uri $requestUri `
                -Headers $requestHeaders `
                -ContentType "application/json" `
                -Body $requestBody `
                -ErrorAction Stop

            return $response.id
        }
        finally {
            # Release request and response references that contain the PAT value.
            $requestBody = $null
            $response = $null
        }
    }

    function New-StoredAzureDevOpsPat {
        # Create one PAT, store it in Key Vault, and roll it back if storage fails.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            "PSUseShouldProcessForStateChangingFunctions",
            "",
            Justification = "Invoke-PatProvisioning gates the complete mutation before this helper is called."
        )]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$AuthenticationContext,

            [Parameter(Mandatory)]
            [string]$DisplayName,

            [Parameter(Mandatory)]
            [string[]]$Scopes,

            [Parameter(Mandatory)]
            [DateTimeOffset]$ValidTo,

            [Parameter(Mandatory)]
            [string]$SecretName,

            [Parameter(Mandatory)]
            [string]$Purpose
        )

        # Create the PAT before performing the one-time Key Vault value write.
        $pat = New-AzureDevOpsPat `
            -Config $Config `
            -AuthenticationContext $AuthenticationContext `
            -DisplayName $DisplayName `
            -Scopes $Scopes `
            -ValidTo $ValidTo

        try {
            # Store the credential and return only safe metadata to the caller.
            $secretId = Set-KeyVaultPatSecret `
                -Config $Config `
                -AuthenticationContext $AuthenticationContext `
                -SecretName $SecretName `
                -Purpose $Purpose `
                -Pat $pat

            return [pscustomobject]@{
                Purpose         = $Purpose
                SecretName      = $SecretName
                AuthorizationId = $pat.AuthorizationId
                ValidToUtc      = $pat.ValidTo.UtcDateTime
                SecretId        = $secretId
            }
        }
        catch {
            # Preserve the storage failure while attempting to revoke the orphaned PAT.
            $storageError = $_

            try {
                # Remove the unusable credential because its one-time value was not stored.
                Revoke-AzureDevOpsPat `
                    -Config $Config `
                    -AuthenticationContext $AuthenticationContext `
                    -AuthorizationId $pat.AuthorizationId
            }
            catch {
                Write-Warning "Key Vault storage failed and automatic PAT rollback also failed. Revoke authorization '$($pat.AuthorizationId)' manually in Azure DevOps."
            }

            throw $storageError
        }
        finally {
            # Release the in-memory object containing the one-time PAT value.
            $pat = $null
        }
    }

    function Invoke-PatProvisioning {
        # Provision the bootstrap and agent PATs as one deliberate workflow.
        [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$AuthenticationContext
        )

        # Preview or confirm the complete remote mutation before minting either PAT.
        $target = "Azure DevOps organization '$($Config.OrganizationName)' and Key Vault '$($Config.KeyVaultName)'"
        $action = "Create two ALZ PATs and store them as '$($Config.BootstrapSecretName)' and '$($Config.AgentSecretName)'"

        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            return
        }

        # Create the short-lived, broadly scoped bootstrap credential first.
        $bootstrapResult = New-StoredAzureDevOpsPat `
            -Config $Config `
            -AuthenticationContext $AuthenticationContext `
            -DisplayName $Config.BootstrapDisplayName `
            -Scopes $Config.BootstrapScopes `
            -ValidTo $Config.BootstrapValidTo `
            -SecretName $Config.BootstrapSecretName `
            -Purpose "ALZ bootstrap"

        # Create the long-lived, narrowly scoped self-hosted agent credential second.
        $agentResult = New-StoredAzureDevOpsPat `
            -Config $Config `
            -AuthenticationContext $AuthenticationContext `
            -DisplayName $Config.AgentDisplayName `
            -Scopes $Config.AgentScopes `
            -ValidTo $Config.AgentValidTo `
            -SecretName $Config.AgentSecretName `
            -Purpose "ALZ self-hosted agent registration"

        # Return only identifiers and expiry metadata; never return PAT values.
        Write-Output @($bootstrapResult, $agentResult)
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
