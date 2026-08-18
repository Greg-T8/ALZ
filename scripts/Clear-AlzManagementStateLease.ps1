<#
# -------------------------------------------------------------------------
# Program: Clear-AlzManagementStateLease.ps1
# Description: Break the stale Terraform state lease after a canceled ALZ pipeline run.
# Context: ALZ lab - Terraform state recovery after canceled pipeline runs.
# Author: Greg Tate
# -------------------------------------------------------------------------
.SYNOPSIS
Breaks a stale lease on the ALZ management Terraform state blob.

.DESCRIPTION
Uses the active Azure CLI subscription to find exactly one storage account
whose name begins with stalzmgm. After confirming the management Terraform
state blob is accessible with Microsoft Entra authentication, the script
breaks its lease only after PowerShell ShouldProcess confirmation approves it.

.CONTEXT
ALZ lab - Terraform state recovery after canceled pipeline runs.

.AUTHOR
Greg Tate

.NOTES
Program: Clear-AlzManagementStateLease.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

#region CONFIGURATION
# Preserve the script-level ShouldProcess context for nested helper functions.
$ScriptCmdlet = $PSCmdlet

# Stop immediately when an unexpected PowerShell error prevents safe lease recovery.
$ErrorActionPreference = 'Stop'

# Define the fixed management-state target and the storage-account discovery prefix.
$ScriptConfig = [ordered]@{
    StorageAccountNamePrefix = 'stalzmgm'
    StateContainerName       = 'mgmt-tfstate'
    StateBlobName            = 'terraform.tfstate'
    BlobAuthorizationMode    = 'login'
}
#endregion

#region MAIN
# Run the guarded management-state lease recovery workflow.
$Main = {
    . $Helpers

    $azureContext = Get-AzureCliContext
    $storageAccount = Get-StateStorageAccount -AzureContext $azureContext
    Confirm-StateBlob -StorageAccountName $storageAccount.Name
    Clear-StateBlobLease -StorageAccountName $storageAccount.Name
}
#endregion

#region HELPERS
# Define Azure CLI validation, storage discovery, blob verification, and lease recovery helpers.
$Helpers = {
    function Invoke-AzureCliCommand {
        # Run an Azure CLI command and surface native failures with their diagnostic output.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string[]]$ArgumentList,

            [Parameter(Mandatory)]
            [string]$FailureMessage
        )

        # Capture both native streams before evaluating the Azure CLI exit code.
        $output = & az @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine

        if ($exitCode -ne 0) {
            # Retain Azure CLI diagnostics so authentication and authorization failures are actionable.
            if ([string]::IsNullOrWhiteSpace($outputText)) {
                throw $FailureMessage
            }

            throw "$FailureMessage Azure CLI output: $outputText"
        }

        return $outputText
    }

    function Get-AzureCliContext {
        # Verify Azure CLI availability and return the active authenticated subscription context.
        [CmdletBinding()]
        param()

        if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is required. Install it from https://aka.ms/azure-cli.'
        }

        # Read the selected Azure CLI subscription without changing the caller's context.
        $contextJson = Invoke-AzureCliCommand `
            -ArgumentList @(
                'account',
                'show',
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Azure CLI is not logged in. Run 'az login' and select the intended subscription."
        $context = $contextJson | ConvertFrom-Json

        if ([string]::IsNullOrWhiteSpace([string]$context.id)) {
            throw 'Azure CLI did not return an active subscription ID.'
        }

        Write-Information `
            -MessageData "Using Azure subscription '$($context.name)' ($($context.id))." `
            -InformationAction Continue
        return $context
    }

    function Get-StateStorageAccount {
        # Find the only storage account in the active subscription that matches the management prefix.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$AzureContext
        )

        # Retrieve the subscription inventory as JSON and filter locally to avoid fragile CLI query quoting.
        $storageAccountJson = Invoke-AzureCliCommand `
            -ArgumentList @(
                'storage',
                'account',
                'list',
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to list storage accounts in subscription '$($AzureContext.id)'."
        $storageAccount = @($storageAccountJson | ConvertFrom-Json)
        $matchingStorageAccount = @(
            $storageAccount |
                Where-Object {
                    [string]$_.name -like "$($ScriptConfig.StorageAccountNamePrefix)*"
                }
        )

        if ($matchingStorageAccount.Count -ne 1) {
            # Reject ambiguous discovery so a lease is never broken on an unintended state account.
            $candidateName = if ($matchingStorageAccount.Count -eq 0) {
                '<none>'
            }
            else {
                $matchingStorageAccount.name -join ', '
            }
            throw (
                "Expected exactly one storage account beginning with " +
                "'$($ScriptConfig.StorageAccountNamePrefix)' in subscription " +
                "'$($AzureContext.id)'. Found $($matchingStorageAccount.Count): $candidateName."
            )
        }

        Write-Information `
            -MessageData "Using storage account '$($matchingStorageAccount[0].name)'." `
            -InformationAction Continue
        return $matchingStorageAccount[0]
    }

    function Confirm-StateBlob {
        # Confirm the fixed management Terraform state blob is reachable before any lease mutation.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$StorageAccountName
        )

        # Verify the blob exists and the current identity has Blob data-plane access through Entra ID.
        $null = Invoke-AzureCliCommand `
            -ArgumentList @(
                'storage',
                'blob',
                'show',
                '--account-name',
                $StorageAccountName,
                '--container-name',
                $ScriptConfig.StateContainerName,
                '--name',
                $ScriptConfig.StateBlobName,
                '--auth-mode',
                $ScriptConfig.BlobAuthorizationMode,
                '--output',
                'none',
                '--only-show-errors'
            ) `
            -FailureMessage (
                "Unable to access blob '$($ScriptConfig.StateBlobName)' in container " +
                "'$($ScriptConfig.StateContainerName)' on storage account '$StorageAccountName'."
            )

        Write-Output (
            "Confirmed access to '$($ScriptConfig.StateContainerName)/" +
            "$($ScriptConfig.StateBlobName)'."
        )
    }

    function Clear-StateBlobLease {
        # Break the verified management-state blob lease after explicit operator confirmation.
        [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$StorageAccountName
        )

        $target = (
            "blob '$($ScriptConfig.StateBlobName)' in container " +
            "'$($ScriptConfig.StateContainerName)' on storage account '$StorageAccountName'"
        )

        # Remind the operator that this fallback does not prove the Terraform lock is stale.
        Write-Warning (
            'Confirm all pipeline jobs that use this state have stopped before breaking the lease. ' +
            'This operation does not validate the Terraform lock ID.'
        )

        if (-not $ScriptCmdlet.ShouldProcess($target, 'Break lease')) {
            return
        }

        # Break the blob lease with Microsoft Entra authentication and report the Azure CLI response.
        $leaseBreakResult = Invoke-AzureCliCommand `
            -ArgumentList @(
                'storage',
                'blob',
                'lease',
                'break',
                '--account-name',
                $StorageAccountName,
                '--container-name',
                $ScriptConfig.StateContainerName,
                '--blob-name',
                $ScriptConfig.StateBlobName,
                '--auth-mode',
                $ScriptConfig.BlobAuthorizationMode,
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to break the lease on $target."

        Write-Output "Lease-break operation completed for $target."
        if (-not [string]::IsNullOrWhiteSpace($leaseBreakResult)) {
            Write-Output $leaseBreakResult
        }
    }
}
#endregion

#region EXECUTION
# Run from the script directory and always restore the caller's location.
try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
#endregion
