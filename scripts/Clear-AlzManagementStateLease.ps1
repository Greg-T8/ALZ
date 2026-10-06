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
Uses the active Azure CLI subscription to find storage accounts in resource
groups whose names begin with rg-alz-mgmt. It identifies accounts containing
the management or local Terraform state container, then breaks the state blob
lease only after PowerShell ShouldProcess confirmation approves it.

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

# Define the fixed management-state target and resource-group discovery prefix.
$ScriptConfig = [ordered]@{
    ResourceGroupNamePrefix = 'rg-alz-mgmt'
    StateContainerNames     = @('mgmt-tfstate', 'local-tfstate')
    StateBlobName           = 'terraform.tfstate'
    BlobAuthorizationMode   = 'login'
}
#endregion

#region MAIN
# Run the guarded management-state lease recovery workflow.
$Main = {
    . $Helpers

    $azureContext = Get-AzureCliContext
    $storageAccount = Get-StateStorageAccount -AzureContext $azureContext
    Confirm-StateBlob `
        -StorageAccountName $storageAccount.Name `
        -ContainerName $storageAccount.ContainerName
    Clear-StateBlobLease `
        -StorageAccountName $storageAccount.Name `
        -ContainerName $storageAccount.ContainerName
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
        # Find management-state storage accounts by resource group and container identity.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$AzureContext
        )

        # Retrieve resource groups as JSON and filter locally to avoid fragile CLI query quoting.
        $resourceGroupJson = Invoke-AzureCliCommand `
            -ArgumentList @(
                'group',
                'list',
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to list resource groups in subscription '$($AzureContext.id)'."
        $resourceGroup = @($resourceGroupJson | ConvertFrom-Json)
        $matchingResourceGroup = @(
            $resourceGroup |
                Where-Object {
                    [string]$_.name -like "$($ScriptConfig.ResourceGroupNamePrefix)*"
                }
        )

        if ($matchingResourceGroup.Count -eq 0) {
            throw (
                "No resource groups beginning with '$($ScriptConfig.ResourceGroupNamePrefix)' " +
                "were found in subscription '$($AzureContext.id)'."
            )
        }

        # Test every storage account for each supported Terraform state container.
        $matchingStorageAccount = [System.Collections.Generic.List[object]]::new()
        foreach ($group in $matchingResourceGroup) {
            $storageAccountJson = Invoke-AzureCliCommand `
                -ArgumentList @(
                    'storage',
                    'account',
                    'list',
                    '--resource-group',
                    $group.name,
                    '--output',
                    'json',
                    '--only-show-errors'
                ) `
                -FailureMessage "Unable to list storage accounts in resource group '$($group.name)'."
            $storageAccount = @($storageAccountJson | ConvertFrom-Json)

            foreach ($account in $storageAccount) {
                foreach ($containerName in $ScriptConfig.StateContainerNames) {
                    if (
                        Test-StateStorageContainer `
                            -StorageAccountName $account.name `
                            -ContainerName $containerName
                    ) {
                        $matchingStorageAccount.Add([pscustomobject]@{
                                Name          = [string]$account.name
                                ResourceGroup = [string]$group.name
                                ContainerName = [string]$containerName
                            })
                    }
                }
            }
        }

        if ($matchingStorageAccount.Count -eq 0) {
            throw (
                "No storage accounts containing any of these containers " +
                "('$($ScriptConfig.StateContainerNames -join "', '")') " +
                "were found in resource groups beginning with " +
                "'$($ScriptConfig.ResourceGroupNamePrefix)'."
            )
        }

        # Use a unique match automatically and require an operator choice only for ambiguity.
        $selectedStorageAccount = if ($matchingStorageAccount.Count -eq 1) {
            $matchingStorageAccount[0]
        }
        else {
            Select-StateStorageAccount -StorageAccount $matchingStorageAccount.ToArray()
        }

        Write-Information `
            -MessageData (
                "Using container '$($selectedStorageAccount.ContainerName)' on storage account " +
                "'$($selectedStorageAccount.Name)' in resource group " +
                "'$($selectedStorageAccount.ResourceGroup)'."
            ) `
            -InformationAction Continue
        return $selectedStorageAccount
    }

    function Test-StateStorageContainer {
        # Return whether one storage account contains the requested state container.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$StorageAccountName,

            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$ContainerName
        )

        # Use Entra data-plane authorization to test the target container without retrieving account keys.
        $containerExistsJson = Invoke-AzureCliCommand `
            -ArgumentList @(
                'storage',
                'container',
                'exists',
                '--account-name',
                $StorageAccountName,
                '--name',
                $ContainerName,
                '--auth-mode',
                $ScriptConfig.BlobAuthorizationMode,
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage (
                "Unable to determine whether container '$ContainerName' " +
                "exists on storage account '$StorageAccountName'."
            )
        $containerExists = $containerExistsJson | ConvertFrom-Json

        if ($null -eq $containerExists.exists) {
            throw (
                "Azure CLI did not return an 'exists' result for container " +
                "'$ContainerName' on storage account '$StorageAccountName'."
            )
        }

        return [bool]$containerExists.exists
    }

    function Select-StateStorageAccount {
        # Prompt the operator to choose one state account when container discovery is ambiguous.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [pscustomobject[]]$StorageAccount
        )

        # Display the matching resource-group and storage-account pairs for an explicit choice.
        for ($index = 0; $index -lt $StorageAccount.Count; $index++) {
            Write-Information `
                -MessageData (
                    "[{0}] Resource group: {1}; storage account: {2}; container: {3}" -f `
                        ($index + 1),
                        $StorageAccount[$index].ResourceGroup,
                        $StorageAccount[$index].Name,
                        $StorageAccount[$index].ContainerName
                ) `
                -InformationAction Continue
        }

        # Continue prompting until the operator supplies a valid one-based selection.
        while ($true) {
            $selectionText = Read-Host -Prompt 'Select the management state storage account by number'
            $selectionIndex = 0

            if (
                [int]::TryParse($selectionText, [ref]$selectionIndex) -and
                $selectionIndex -ge 1 -and
                $selectionIndex -le $StorageAccount.Count
            ) {
                return $StorageAccount[$selectionIndex - 1]
            }

            Write-Warning "Enter a number from 1 through $($StorageAccount.Count)."
        }
    }

    function Confirm-StateBlob {
        # Confirm the selected Terraform state blob is reachable before any lease mutation.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$StorageAccountName,

            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$ContainerName
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
                $ContainerName,
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
                "'$ContainerName' on storage account '$StorageAccountName'."
            )

        Write-Output (
            "Confirmed access to '$ContainerName/" +
            "$($ScriptConfig.StateBlobName)'."
        )
    }

    function Clear-StateBlobLease {
        # Break the verified Terraform state blob lease after explicit operator confirmation.
        [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$StorageAccountName,

            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$ContainerName
        )

        $target = (
            "blob '$($ScriptConfig.StateBlobName)' in container " +
            "'$ContainerName' on storage account '$StorageAccountName'"
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
                $ContainerName,
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
