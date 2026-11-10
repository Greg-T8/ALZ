<#
.SYNOPSIS
    Triggers Azure Policy compliance evaluations at the tenant root or for one subscription.

.DESCRIPTION
    Scans all subscriptions below the tenant root management group, or scans a
    single subscription selected by ID. Scans are submitted without waiting
    for completion. Disabled subscriptions are skipped.

.CONTEXT
    ALZ lab — trigger Azure Policy compliance evaluations.
    Microsoft Azure Administrator

.AUTHOR
    Greg Tate & coding agent

.NOTES
    Last Modified : 2026-11-10
    Revision History:
      2026-11-10 - Skip disabled subscriptions
      2026-11-10 - Add root management group and subscription scan targets
#>

[CmdletBinding(DefaultParameterSetName = 'ManagementGroupRoot')]
param(
    [Parameter(ParameterSetName = 'ManagementGroupRoot')]
    [switch]$ManagementGroupRoot,

    [Parameter(Mandatory, ParameterSetName = 'Subscription')]
    [ValidatePattern('^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId
)

$Main = {
    . $Helpers

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        # Use the explicitly selected subscription as the only scan target.
        $TargetSubscriptionIds = @($SubscriptionId)
    }
    else {
        # Resolve every subscription beneath the tenant root management group.
        $TargetSubscriptionIds = @(Get-ManagementGroupRootSubscriptionId)
    }

    Invoke-PolicyComplianceScan -SubscriptionIds $TargetSubscriptionIds
}

$Helpers = {
    # Finds all subscription IDs beneath the current tenant's root management group.
    function Get-ManagementGroupRootSubscriptionId {
        [CmdletBinding()]
        param()

        $Context = Get-AzContext

        if ($null -eq $Context -or [string]::IsNullOrWhiteSpace($Context.Tenant.Id)) {
            throw 'No active Azure context with a tenant ID was found. Connect to Azure before running this script.'
        }

        $Hierarchy = Get-AzManagementGroup `
            -GroupName $Context.Tenant.Id `
            -Expand `
            -Recurse `
            -ErrorAction Stop

        $SubscriptionIds = @(
            Get-ChildSubscriptionId -Node $Hierarchy |
                Sort-Object -Unique
        )

        if ($SubscriptionIds.Count -eq 0) {
            throw 'No subscriptions were found beneath the tenant root management group. No scans will be triggered.'
        }

        return $SubscriptionIds
    }

    # Extracts subscription IDs from a management group hierarchy node.
    function Get-ChildSubscriptionId {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [object]$Node
        )

        if ($Node.Type -eq '/subscriptions') {
            $Node.Name
            return
        }

        foreach ($Child in $Node.Children) {
            # Walk nested management groups to find their subscription nodes.
            Get-ChildSubscriptionId -Node $Child
        }
    }

    # Submits a non-blocking policy compliance scan for each selected subscription.
    function Invoke-PolicyComplianceScan {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string[]]$SubscriptionIds
        )

        Write-Host "Subscriptions found: $($SubscriptionIds.Count)"

        foreach ($TargetSubscriptionId in $SubscriptionIds) {
            # Check the subscription state before deciding whether to submit a scan.
            $Subscription = Get-AzSubscription `
                -SubscriptionId $TargetSubscriptionId `
                -ErrorAction Stop

            if ($Subscription.State -eq 'Disabled') {
                # Skip disabled subscriptions because Azure Policy scans cannot run against them.
                Write-Warning "Skipping disabled subscription: $TargetSubscriptionId"
                continue
            }

            # Submit the scan asynchronously and report the target being scanned.
            Write-Host "Triggering compliance scan: $TargetSubscriptionId"

            Start-AzPolicyComplianceScan `
                -SubscriptionId $TargetSubscriptionId `
                -NoWait `
                -ErrorAction Stop
        }
    }
}

# Restore the caller's working location after script execution.
try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
