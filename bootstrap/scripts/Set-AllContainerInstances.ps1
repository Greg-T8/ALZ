<#
# -------------------------------------------------------------------------
# Program: Set-AllContainerInstances.ps1
# Description: Show, start, or stop Azure Container Instances in one subscription.
# Context: ALZ lab - bootstrap cost control and workload recovery for container instances.
# Author: Greg Tate
# -------------------------------------------------------------------------
.SYNOPSIS
Shows, starts, or stops Azure Container Instances in a subscription.

.DESCRIPTION
Resolves a supplied subscription name or ID, or the currently selected Azure
CLI subscription when no subscription is supplied. With -Action Show, the
script outputs each group's provisioning, group instance-view, and first
container current state. With -Action Stop, it stops groups whose group
instance-view state is Running. With -Action Start, it starts groups whose
group instance-view state is Stopped.

Use -WhatIf to preview the targeted groups and -Confirm to require approval
for every state-change operation.

.CONTEXT
ALZ lab - bootstrap cost control and workload recovery for container instances.

.AUTHOR
Greg Tate

.NOTES
Program: Set-AllContainerInstances.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Parameters are consumed by helpers dot-sourced into the Main script block.'
)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Show', 'Start', 'Stop')]
    [string]$Action,

    [ValidateNotNullOrEmpty()]
    [string]$Subscription
)

#region MAIN
# Run the requested container instance state-change workflow.
$Main = {
    . $Helpers

    # Confirm Azure CLI access before resolving the target subscription.
    Confirm-ContainerInstancePrerequisite
    $subscriptionContext = Get-SubscriptionContext

    # Inventory the target subscription before either displaying or changing group states.
    $containerGroup = @(Get-ContainerGroup -SubscriptionContext $subscriptionContext)

    if ($Action -eq 'Show') {
        # Return read-only state objects without requesting a state change.
        Show-ContainerInstanceState -ContainerGroup $containerGroup
        return
    }

    # Select only groups that need the requested state change.
    $targetState = Get-TargetContainerInstanceState
    $containerGroup = $containerGroup |
        Where-Object { $_.InstanceState -eq $targetState }

    # Apply the requested action to each eligible group with ShouldProcess protection.
    Invoke-ContainerGroupAction `
        -ContainerGroup $containerGroup `
        -SubscriptionContext $subscriptionContext
}
#endregion

#region HELPERS
# Define Azure CLI validation, subscription resolution, inventory, display, and action helpers.
$Helpers = {
    function Confirm-ContainerInstancePrerequisite {
        # Verify Azure CLI is installed and the current session is authenticated.
        [CmdletBinding()]
        param()

        if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is required. Install it from https://aka.ms/azure-cli.'
        }

        # Confirm the caller can query the current Azure CLI context.
        $null = az account show --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI is not logged in. Run 'az login' and re-run this script."
        }
    }

    function Get-SubscriptionContext {
        # Resolve the supplied subscription, or the selected Azure CLI subscription, to an immutable ID.
        [CmdletBinding()]
        param()

        # Query the subscription once so every later Azure CLI command uses its explicit ID.
        $argumentList = @(
            'account',
            'show',
            '--query',
            '{Id:id,Name:name}',
            '--output',
            'json',
            '--only-show-errors'
        )

        if ($Subscription) {
            $argumentList += @('--subscription', $Subscription)
        }

        $subscriptionContext = az @argumentList | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $subscriptionContext.Id) {
            throw "Unable to resolve Azure subscription '$Subscription'."
        }

        return $subscriptionContext
    }

    function Get-TargetContainerInstanceState {
        # Map the requested action to the instance-view state that requires that action.
        [CmdletBinding()]
        param()

        if ($Action -eq 'Start') {
            return 'Stopped'
        }

        return 'Running'
    }

    function Get-ContainerGroup {
        # Return every container group with authoritative provisioning and instance-view states.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext
        )

        # List the container groups once; this Azure CLI operation does not return instance-view state.
        $containerGroupInventory = az container list `
            --subscription $SubscriptionContext.Id `
            --query '[].{Name:name,ResourceGroup:resourceGroup}' `
            --output json `
            --only-show-errors |
            ConvertFrom-Json

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to list container instances in subscription '$($SubscriptionContext.Name)' ($($SubscriptionContext.Id))."
        }

        # Query each group individually because container show includes the runtime instance-view state.
        foreach ($group in $containerGroupInventory) {
            $containerGroupState = az container show `
                --name $group.Name `
                --resource-group $group.ResourceGroup `
                --subscription $SubscriptionContext.Id `
                --query '{ProvisioningState:provisioningState,InstanceState:instanceView.state,ContainerState:containers[0].instanceView.currentState.state}' `
                --output json `
                --only-show-errors |
                ConvertFrom-Json

            if ($LASTEXITCODE -ne 0) {
                throw "Unable to retrieve the runtime state for container instance '$($group.Name)' in resource group '$($group.ResourceGroup)'."
            }

            # Return a unified record for display and Start or Stop state selection.
            [pscustomobject]@{
                Name              = $group.Name
                ResourceGroup     = $group.ResourceGroup
                ProvisioningState = $containerGroupState.ProvisioningState
                InstanceState     = $containerGroupState.InstanceState
                ContainerState    = $containerGroupState.ContainerState
            }
        }
    }

    function Show-ContainerInstanceState {
        # Output a concise read-only state record for each container group.
        [CmdletBinding()]
        param(
            [AllowEmptyCollection()]
            [pscustomobject[]]$ContainerGroup
        )

        if ($ContainerGroup.Count -eq 0) {
            Write-Host 'No container instances found in the target subscription.'
            return
        }

        # Emit structured objects so callers can view, filter, export, or format the state information.
        foreach ($group in $ContainerGroup) {
            [pscustomobject]@{
                Name              = $group.Name
                ResourceGroup     = $group.ResourceGroup
                ProvisioningState = $group.ProvisioningState
                InstanceState     = $group.InstanceState
                ContainerState    = $group.ContainerState
            }
        }
    }

    function Invoke-ContainerGroupAction {
        # Apply the requested action to each eligible container group after ShouldProcess approves it.
        [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
        param(
            [AllowEmptyCollection()]
            [pscustomobject[]]$ContainerGroup,

            [Parameter(Mandatory)]
            [pscustomobject]$SubscriptionContext
        )

        if ($ContainerGroup.Count -eq 0) {
            Write-Host "No container instances in the required state for action '$Action' were found in $($SubscriptionContext.Name) ($($SubscriptionContext.Id))."
            return
        }

        # Process every eligible group independently so a failure does not block the remaining groups.
        foreach ($group in $ContainerGroup) {
            $target = "{0} in resource group {1}, subscription {2} ({3})" -f `
                $group.Name, `
                $group.ResourceGroup, `
                $SubscriptionContext.Name, `
                $SubscriptionContext.Id

            if (-not $PSCmdlet.ShouldProcess($target, "$Action container instance")) {
                continue
            }

            # Submit the state-change request only after WhatIf and confirmation safeguards approve it.
            az container $Action.ToLowerInvariant() `
                --name $group.Name `
                --resource-group $group.ResourceGroup `
                --subscription $SubscriptionContext.Id `
                --only-show-errors

            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to $($Action.ToLowerInvariant()) container instance '$($group.Name)' in resource group '$($group.ResourceGroup)'."
                continue
            }

            Write-Host "Completed '$Action' for container instance '$($group.Name)' in resource group '$($group.ResourceGroup)'."
        }
    }
}
#endregion

#region EXECUTION
# Execute the script from its directory and restore the caller's location afterward.
try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
#endregion
