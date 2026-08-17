<#
.SYNOPSIS
Stops running ALZ Azure Container Instance groups in one resource group.

.DESCRIPTION
Authenticates with the Azure Automation Account system-assigned managed identity,
finds container groups whose names begin with the configured prefix, and stops
each group whose authoritative instance-view state is Running. Failures are
reported after every eligible group has been attempted.

.CONTEXT
ALZ lab - scheduled cost control for self-hosted ACI agents.

.AUTHOR
Greg Tate

.NOTES
Program: Stop-AlzContainerInstance.ps1
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Parameters are consumed by helpers dot-sourced into the Main script block.'
)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [string]$ContainerNamePrefix = 'aci-alz'
)

# Configure terminating PowerShell errors so the Automation job records failures.
$ErrorActionPreference = 'Stop'

#region MAIN
# Run the managed-identity ACI shutdown workflow.
$Main = {
    . $Helpers

    Connect-AutomationAzureContext
    $containerGroup = @(Get-TargetContainerGroup)
    Invoke-TargetContainerGroupStop -ContainerGroup $containerGroup
}
#endregion

#region HELPERS
# Define Azure CLI authentication, discovery, state inspection, and stop helpers.
$Helpers = {
    function Invoke-AzureCliText {
        # Run Azure CLI and return its text output while preserving the native exit code.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string[]]$ArgumentList,

            [Parameter(Mandatory)]
            [string]$FailureMessage
        )

        # Capture both native streams so an Automation job contains actionable failure detail.
        $output = & az @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine

        if ($exitCode -ne 0) {
            # Include Azure CLI diagnostics without hiding which lifecycle operation failed.
            if ([string]::IsNullOrWhiteSpace($outputText)) {
                throw $FailureMessage
            }

            throw "$FailureMessage Azure CLI output: $outputText"
        }

        return $outputText
    }

    function Connect-AutomationAzureContext {
        # Authenticate Azure CLI with the Automation Account managed identity.
        [CmdletBinding()]
        param()

        # Confirm the PowerShell 7.4 runtime exposes the default Azure CLI package.
        if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is unavailable in the Automation runtime environment.'
        }

        # Establish a credential-free session isolated to this Automation job.
        $null = Invoke-AzureCliText `
            -ArgumentList @(
                'login',
                '--identity',
                '--allow-no-subscriptions',
                '--output',
                'none',
                '--only-show-errors'
            ) `
            -FailureMessage 'Managed-identity authentication failed.'

        # Verify the managed identity can resolve the explicitly supplied subscription.
        $null = Invoke-AzureCliText `
            -ArgumentList @(
                'account',
                'show',
                '--subscription',
                $SubscriptionId,
                '--output',
                'none',
                '--only-show-errors'
            ) `
            -FailureMessage "The managed identity cannot access subscription '$SubscriptionId'."
    }

    function Get-TargetContainerGroup {
        # List only container groups in the target resource group whose names match the prefix.
        [CmdletBinding()]
        param()

        # Retrieve the resource-group inventory once and filter it locally without JMESPath quoting.
        $inventoryJson = Invoke-AzureCliText `
            -ArgumentList @(
                'container',
                'list',
                '--resource-group',
                $ResourceGroupName,
                '--subscription',
                $SubscriptionId,
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to list container groups in resource group '$ResourceGroupName'."
        $inventory = @($inventoryJson | ConvertFrom-Json)

        # Select names case-insensitively so Azure name casing does not affect the schedule.
        foreach ($group in $inventory) {
            if ([string]$group.name -like "$ContainerNamePrefix*") {
                [pscustomobject]@{
                    Name          = [string]$group.name
                    ResourceGroup = [string]$group.resourceGroup
                }
            }
        }
    }

    function Get-ContainerGroupState {
        # Return the authoritative container-group instance-view state.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$ContainerGroup
        )

        # Query the group individually because list output omits the runtime instance-view state.
        $stateJson = Invoke-AzureCliText `
            -ArgumentList @(
                'container',
                'show',
                '--name',
                $ContainerGroup.Name,
                '--resource-group',
                $ContainerGroup.ResourceGroup,
                '--subscription',
                $SubscriptionId,
                '--query',
                '{ProvisioningState:provisioningState,InstanceState:instanceView.state}',
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to retrieve state for container group '$($ContainerGroup.Name)'."

        return $stateJson | ConvertFrom-Json
    }

    function Invoke-TargetContainerGroupStop {
        # Stop every matching running group and fail after reporting any individual errors.
        [CmdletBinding()]
        param(
            [AllowEmptyCollection()]
            [pscustomobject[]]$ContainerGroup
        )

        if ($ContainerGroup.Count -eq 0) {
            # A missing runtime target is an expected no-op after deployment or cleanup.
            Write-Output "No container groups beginning with '$ContainerNamePrefix' were found in resource group '$ResourceGroupName'."
            return
        }

        # Track structured results so every matching group receives an independent attempt.
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($group in $ContainerGroup) {
            try {
                # Skip groups that are already stopped, terminated, or transitioning.
                $state = Get-ContainerGroupState -ContainerGroup $group
                if ($state.InstanceState -ne 'Running') {
                    $result.Add([pscustomobject]@{
                            Name          = $group.Name
                            PreviousState = $state.InstanceState
                            Result        = 'SkippedNotRunning'
                            Error         = $null
                        })
                    continue
                }

                # Stop the complete container group without waiting for Azure DevOps job activity.
                $null = Invoke-AzureCliText `
                    -ArgumentList @(
                        'container',
                        'stop',
                        '--name',
                        $group.Name,
                        '--resource-group',
                        $group.ResourceGroup,
                        '--subscription',
                        $SubscriptionId,
                        '--output',
                        'none',
                        '--only-show-errors'
                    ) `
                    -FailureMessage "Unable to stop container group '$($group.Name)'."
                $result.Add([pscustomobject]@{
                        Name          = $group.Name
                        PreviousState = $state.InstanceState
                        Result        = 'Stopped'
                        Error         = $null
                    })
            }
            catch {
                # Preserve the failed group and continue stopping every remaining eligible group.
                $result.Add([pscustomobject]@{
                        Name          = $group.Name
                        PreviousState = $null
                        Result        = 'Failed'
                        Error         = $_.Exception.Message
                    })
            }
        }

        # Emit the complete operation record before converting partial failure into a failed job.
        $result | Write-Output
        $failedGroup = @($result | Where-Object { $_.Result -eq 'Failed' })

        if ($failedGroup.Count -gt 0) {
            # Mark the Automation job failed while retaining every per-group result in its output.
            throw "Failed to stop $($failedGroup.Count) of $($ContainerGroup.Count) matching container groups."
        }
    }
}
#endregion

#region EXECUTION
# Execute the runbook from its source directory when available and restore location afterward.
try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
#endregion
