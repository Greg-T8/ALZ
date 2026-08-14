<#
# -------------------------------------------------------------------------
# Program: Cleanup-LandingZone.ps1
# Description: Delete resource groups from the configured ALZ lab subscriptions.
# Context: ALZ lab - bootstrap cleanup of lab resource groups across platform subscriptions.
# Author: Greg Tate
# -------------------------------------------------------------------------
.SYNOPSIS
Deletes all resource groups from selected ALZ lab subscriptions.

.DESCRIPTION
Lists resource groups from the configured subscription IDs and deletes each
group through Azure CLI. Deletions are protected by PowerShell ShouldProcess:
use -WhatIf to preview the groups that would be deleted, and -Confirm to
require confirmation for every deletion. The script never uses the active
Azure CLI subscription implicitly.

.CONTEXT
ALZ lab - bootstrap cleanup of lab resource groups across platform subscriptions.

.AUTHOR
Greg Tate

.NOTES
Program: Remove-BootstrapResourceGroups.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet(
        'Sample Security Subscription',
        'Sample Connectivity Subscription',
        'Sample Management Subscription',
        'Sample Identity Subscription'
    )]
    [string[]]$SubscriptionName
)

#region CONFIGURATION
# Define the only subscriptions that this cleanup script is permitted to target.
$ScriptConfig = [ordered]@{
    Subscriptions = @(
        [pscustomobject]@{
            Name           = 'Sample Security Subscription'
            SubscriptionId = '44444444-4444-4444-4444-444444444444'
        },
        [pscustomobject]@{
            Name           = 'Sample Connectivity Subscription'
            SubscriptionId = '22222222-2222-2222-2222-222222222222'
        },
        [pscustomobject]@{
            Name           = 'Sample Management Subscription'
            SubscriptionId = '11111111-1111-1111-1111-111111111111'
        },
        [pscustomobject]@{
            Name           = 'Sample Identity Subscription'
            SubscriptionId = '33333333-3333-3333-3333-333333333333'
        }
    )
}
#endregion

#region MAIN
# Run the selected subscription cleanup workflow.
$Main = {
    . $Helpers

    # Confirm Azure CLI is available and authenticated before reading resource groups.
    Confirm-CleanupPrerequisite

    # Limit the cleanup to requested configured subscriptions, or use every configured subscription.
    $targetSubscription = Get-TargetSubscription

    # Enumerate resource groups and submit each deletion through ShouldProcess safeguards.
    foreach ($subscription in $targetSubscription) {
        Remove-SubscriptionResourceGroup -Subscription $subscription
    }
}
#endregion

#region HELPERS
# Helper functions for prerequisite checks, subscription selection, and group deletion.
$Helpers = {
    function Confirm-CleanupPrerequisite {
        # Verify Azure CLI is installed and the current session is authenticated.
        [CmdletBinding()]
        param()

        if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is required. Install it from https://aka.ms/azure-cli.'
        }

        # Confirm the caller can use Azure CLI before attempting any subscription-specific query.
        $null = az account show --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI is not logged in. Run 'az login' and re-run this script."
        }
    }

    function Get-TargetSubscription {
        # Return only configured subscriptions, optionally filtered by their friendly names.
        [CmdletBinding()]
        param()

        if ($SubscriptionName) {
            return @(
                $ScriptConfig.Subscriptions |
                    Where-Object { $_.Name -in $SubscriptionName }
            )
        }

        return $ScriptConfig.Subscriptions
    }

    function Remove-SubscriptionResourceGroup {
        # List and delete every resource group in one explicitly configured subscription.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Subscription
        )

        # Query names using the configured subscription ID so the active CLI context is never used.
        $resourceGroupName = @(
            az group list `
                --subscription $Subscription.SubscriptionId `
                --query '[].name' `
                --output tsv
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        if ($LASTEXITCODE -ne 0) {
            Write-Error (
                "Could not list resource groups for {0} ({1}). Skipping subscription." -f `
                    $Subscription.Name, $Subscription.SubscriptionId
            )
            return
        }

        if ($resourceGroupName.Count -eq 0) {
            Write-Host (
                "No resource groups found in {0} ({1})." -f `
                    $Subscription.Name, $Subscription.SubscriptionId
            )
            return
        }

        Write-Host (
            "Found {0} resource group(s) in {1} ({2})." -f `
                $resourceGroupName.Count, $Subscription.Name, $Subscription.SubscriptionId
        )

        # Process each group independently so a failure does not prevent the remaining cleanup.
        foreach ($name in $resourceGroupName) {
            $target = "{0} in {1} ({2})" -f `
                $name, $Subscription.Name, $Subscription.SubscriptionId

            if (-not $PSCmdlet.ShouldProcess($target, 'Delete resource group')) {
                continue
            }

            # Submit the Azure CLI deletion only after WhatIf and confirmation safeguards approve it.
            az group delete `
                --name $name `
                --subscription $Subscription.SubscriptionId `
                --yes

            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to delete resource group '$name' from $($Subscription.Name) ($($Subscription.SubscriptionId))."
                continue
            }

            Write-Host "Deletion requested for resource group '$name' in $($Subscription.Name) ($($Subscription.SubscriptionId))."
        }
    }
}
#endregion

#region EXECUTION
# Execute the cleanup from the script directory and restore the caller's location afterward.
try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
#endregion
