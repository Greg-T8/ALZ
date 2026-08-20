<#
# -------------------------------------------------------------------------
# Program: Cleanup-LandingZone.ps1
# Description: Delete ALZ lab resource groups and optionally remove the deployed management group hierarchy.
# Context: ALZ lab - bootstrap cleanup of lab resource groups across platform subscriptions.
# Author: Greg Tate
# -------------------------------------------------------------------------
.SYNOPSIS
Deletes selected ALZ lab resource groups and optionally removes the ALZ management group hierarchy.

.DESCRIPTION
Lists resource groups from the configured subscription IDs and deletes each
group through Azure CLI. When requested, the script reads the configured ALZ
architecture, discovers its live management group subtree, moves attached
subscriptions to the root group's parent, and removes the subtree bottom-up.
Destructive actions are protected by PowerShell ShouldProcess: use -WhatIf to
preview them, and -Confirm to require confirmation for every action.

.CONTEXT
ALZ lab - bootstrap cleanup of lab resource groups across platform subscriptions.

.AUTHOR
Greg Tate

.NOTES
Program: Cleanup-LandingZone.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
	[ValidateSet(
		'Sample Security Subscription',
		'Sample Connectivity Subscription',
		'Sample Management Subscription',
		'Sample Identity Subscription'
	)]
	[string[]]$SubscriptionName,

	[switch]$CleanupManagementGroupHierarchy
)

#region CONFIGURATION
# Define the only subscriptions that this cleanup script is permitted to target.
$ScriptConfig = [ordered]@{
	Subscriptions = @(
		[pscustomobject]@{
			Name           = 'lab-security'
			SubscriptionId = ''
		},
		[pscustomobject]@{
			Name           = 'lab-connectivity'
			SubscriptionId = ''
		},
		[pscustomobject]@{
			Name           = 'lab-management'
			SubscriptionId = ''
		},
		[pscustomobject]@{
			Name           = 'lab-identity'
			SubscriptionId = ''
		}
		[pscustomobject]@{
			Name           = 'lab-corp'
			SubscriptionId = ''
		}
		[pscustomobject]@{
			Name           = 'lab-online'
			SubscriptionId = ''
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

	# Discover and remove the ALZ management group hierarchy only when explicitly requested.
	if ($CleanupManagementGroupHierarchy) {
		Remove-ALZManagementGroupHierarchy -WhatIf:$WhatIfPreference
	}
}
#endregion

#region HELPERS
# Helper functions for prerequisite checks and ALZ resource and hierarchy cleanup.
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
				'Could not list resource groups for {0} ({1}). Skipping subscription.' -f `
					$Subscription.Name, $Subscription.SubscriptionId
			)
			return
		}

		if ($resourceGroupName.Count -eq 0) {
			Write-Host (
				'No resource groups found in {0} ({1}).' -f `
					$Subscription.Name, $Subscription.SubscriptionId
			)
			return
		}

		Write-Host (
			'Found {0} resource group(s) in {1} ({2}).' -f `
				$resourceGroupName.Count, $Subscription.Name, $Subscription.SubscriptionId
		)

		# Process each group independently so a failure does not prevent the remaining cleanup.
		foreach ($name in $resourceGroupName) {
			$target = '{0} in {1} ({2})' -f `
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

	function Get-ALZArchitectureRootManagementGroup {
		# Return the unique architecture management group that uses the root_custom archetype.
		[CmdletBinding()]
		param()

		# Support both bootstrap-root and bootstrap-scripts placements of this cleanup script.
		$architectureDefinitionRelativePath = `
			'config\lib\architecture_definitions\alz_custom.alz_architecture_definition.yaml'
		$architectureDefinitionPath = @(
			Join-Path `
				-Path $PSScriptRoot `
				-ChildPath $architectureDefinitionRelativePath
			Join-Path `
				-Path (Split-Path -Path $PSScriptRoot -Parent) `
				-ChildPath $architectureDefinitionRelativePath
		) |
			Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
			Select-Object -First 1

		if ([string]::IsNullOrWhiteSpace($architectureDefinitionPath)) {
			throw (
				"The ALZ architecture definition was not found beneath '$PSScriptRoot'. " +
				"Expected '$architectureDefinitionRelativePath' under the bootstrap directory."
			)
		}

		if (-not (Get-Command -Name 'ConvertFrom-Yaml' -ErrorAction SilentlyContinue)) {
			throw "The powershell-yaml module is required. Install it with 'Install-Module powershell-yaml -Scope CurrentUser'."
		}

		try {
			# Parse the architecture so the cleanup root follows the checked-in ALZ definition.
			$architectureDefinition = Get-Content `
				-LiteralPath $architectureDefinitionPath `
				-Raw |
				ConvertFrom-Yaml
		}
		catch {
			throw "Could not parse the ALZ architecture definition '$architectureDefinitionPath': $($_.Exception.Message)"
		}

		# Require exactly one root_custom group to avoid selecting an unintended hierarchy.
		$rootManagementGroup = @(
			$architectureDefinition.management_groups |
				Where-Object { $_.archetypes -contains 'root_custom' }
		)

		if ($rootManagementGroup.Count -ne 1) {
			throw (
				"Expected exactly one management group with the 'root_custom' archetype in " +
				"'$architectureDefinitionPath', but found $($rootManagementGroup.Count)."
			)
		}

		$rootManagementGroupName = [string]$rootManagementGroup[0].id
		if ([string]::IsNullOrWhiteSpace($rootManagementGroupName)) {
			throw "The management group with the 'root_custom' archetype has no id in '$architectureDefinitionPath'."
		}

		return $rootManagementGroupName
	}

	function Get-ALZManagementGroupHierarchy {
		# Retrieve the live management group hierarchy rooted at the ALZ architecture root.
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)]
			[string]$RootManagementGroupName
		)

		# Retrieve every descendant so cleanup scope comes from the live hierarchy rather than a fixed list.
		$hierarchyJson = az account management-group show `
			--name $RootManagementGroupName `
			--expand `
			--recurse `
			--output json

		if ($LASTEXITCODE -ne 0) {
			throw "Could not retrieve the management group hierarchy rooted at '$RootManagementGroupName'."
		}

		try {
			# Convert the Azure CLI response into objects that can be traversed safely.
			$managementGroupHierarchy = $hierarchyJson | ConvertFrom-Json
		}
		catch {
			throw "Azure CLI returned invalid management group data for '$RootManagementGroupName': $($_.Exception.Message)"
		}

		if ($null -eq $managementGroupHierarchy) {
			throw "Azure CLI returned no management group data for '$RootManagementGroupName'."
		}

		$parentResourceId = [string]$managementGroupHierarchy.properties.details.parent.id
		if ([string]::IsNullOrWhiteSpace($parentResourceId)) {
			# A custom management group directly beneath the tenant root may omit its parent in this response.
			$tenantRootManagementGroupName = az account show `
				--query tenantId `
				--output tsv

			if ($LASTEXITCODE -ne 0) {
				throw "Could not determine the tenant root management group for '$RootManagementGroupName'."
			}

			if ([string]::IsNullOrWhiteSpace($tenantRootManagementGroupName)) {
				throw "Azure CLI returned no tenant ID while resolving '$RootManagementGroupName'."
			}

			if ($RootManagementGroupName -eq $tenantRootManagementGroupName) {
				throw "Management group '$RootManagementGroupName' is the tenant root and is never eligible for cleanup."
			}

			$parentManagementGroupName = $tenantRootManagementGroupName
		}
		else {
			# Extract the immediate parent management group name from its Azure resource ID.
			$parentManagementGroupName = ($parentResourceId -split '/')[-1]
			if ([string]::IsNullOrWhiteSpace($parentManagementGroupName)) {
				throw "Could not determine the parent management group for '$RootManagementGroupName'."
			}
		}

		return [pscustomobject]@{
			ManagementGroup       = $managementGroupHierarchy
			ParentManagementGroup = $parentManagementGroupName
		}
	}

	function Add-ALZManagementGroupCleanupTarget {
		# Collect subscriptions and management groups in post-order from a live hierarchy node.
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)]
			[pscustomobject]$ManagementGroup,

			[Parameter(Mandatory)]
			[AllowEmptyCollection()]
			[System.Collections.ArrayList]$ManagementGroupName,

			[Parameter(Mandatory)]
			[AllowEmptyCollection()]
			[System.Collections.ArrayList]$SubscriptionId
		)

		# Visit child nodes first so groups are deleted only after their descendants.
		foreach ($child in @($ManagementGroup.children)) {
			if ($null -eq $child) {
				continue
			}

			$childType = [string]$child.type
			if ($childType -match '(?i)subscriptions$') {
				# Preserve the subscription identifier reported by Azure for an explicit reassignment.
				$childSubscriptionId = [string]$child.name
				if ([string]::IsNullOrWhiteSpace($childSubscriptionId)) {
					throw 'A subscription in the management group hierarchy has no name or subscription ID.'
				}

				if (-not $SubscriptionId.Contains($childSubscriptionId)) {
					$null = $SubscriptionId.Add($childSubscriptionId)
				}

				continue
			}

			if ($childType -notmatch '(?i)managementgroups$') {
				throw "Unexpected child type '$childType' was returned in the management group hierarchy."
			}

			# Recurse into child management groups before adding the current parent to the deletion list.
			Add-ALZManagementGroupCleanupTarget `
				-ManagementGroup $child `
				-ManagementGroupName $ManagementGroupName `
				-SubscriptionId $SubscriptionId
		}

		$currentManagementGroupName = [string]$ManagementGroup.name
		if ([string]::IsNullOrWhiteSpace($currentManagementGroupName)) {
			throw 'A management group in the hierarchy has no name.'
		}

		if (-not $ManagementGroupName.Contains($currentManagementGroupName)) {
			$null = $ManagementGroupName.Add($currentManagementGroupName)
		}
	}

	function Get-ALZManagementGroupCleanupTarget {
		# Build the explicit subscription and post-order management group cleanup lists.
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)]
			[pscustomobject]$ManagementGroupHierarchy
		)

		# Use mutable collections while recursively collecting unique cleanup targets.
		$managementGroupName = [System.Collections.ArrayList]::new()
		$subscriptionId = [System.Collections.ArrayList]::new()

		Add-ALZManagementGroupCleanupTarget `
			-ManagementGroup $ManagementGroupHierarchy `
			-ManagementGroupName $managementGroupName `
			-SubscriptionId $subscriptionId

		return [pscustomobject]@{
			ManagementGroupName = $managementGroupName.ToArray()
			SubscriptionId       = $subscriptionId.ToArray()
		}
	}

	function Move-ALZManagementGroupSubscription {
		# Move one discovered hierarchy subscription to the ALZ root's current parent.
		[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
		param(
			[Parameter(Mandatory)]
			[string]$SubscriptionId,

			[Parameter(Mandatory)]
			[string]$ParentManagementGroupName
		)

		$target = "subscription '$SubscriptionId' to management group '$ParentManagementGroupName'"
		if (-not $PSCmdlet.ShouldProcess($target, 'Move')) {
			return
		}

		# Assigning a subscription to the parent management group removes it from its current ALZ group.
		az account management-group subscription add `
			--name $ParentManagementGroupName `
			--subscription $SubscriptionId `
			--only-show-errors `
			--output none

		if ($LASTEXITCODE -ne 0) {
			Write-Error "Failed to move subscription '$SubscriptionId' to management group '$ParentManagementGroupName'."
			return $false
		}

		Write-Host "Moved subscription '$SubscriptionId' to management group '$ParentManagementGroupName'."
		return $true
	}

	function Remove-ALZManagementGroup {
		# Delete one management group after all its discovered children have been processed.
		[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
		param(
			[Parameter(Mandatory)]
			[string]$ManagementGroupName
		)

		if (-not $PSCmdlet.ShouldProcess("management group '$ManagementGroupName'", 'Delete')) {
			return
		}

		# Submit the management group deletion only after the ShouldProcess safeguard approves it.
		az account management-group delete `
			--name $ManagementGroupName `
			--only-show-errors `
			--output none

		if ($LASTEXITCODE -ne 0) {
			Write-Error "Failed to delete management group '$ManagementGroupName'."
			return $false
		}

		Write-Host "Deleted management group '$ManagementGroupName'."
		return $true
	}

	function Remove-ALZManagementGroupHierarchy {
		# Move discovered subscriptions and remove the live ALZ management group subtree bottom-up.
		[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
		param()

		# Derive the intended ALZ root from source before querying its live Azure hierarchy.
		$rootManagementGroupName = Get-ALZArchitectureRootManagementGroup
		$hierarchyResult = Get-ALZManagementGroupHierarchy `
			-RootManagementGroupName $rootManagementGroupName
		$cleanupTarget = Get-ALZManagementGroupCleanupTarget `
			-ManagementGroupHierarchy $hierarchyResult.ManagementGroup
		$failure = [System.Collections.ArrayList]::new()

		# Reassign every subscription before deleting any management group that contains it.
		foreach ($subscriptionId in $cleanupTarget.SubscriptionId) {
			$moveResult = Move-ALZManagementGroupSubscription `
				-SubscriptionId $subscriptionId `
				-ParentManagementGroupName $hierarchyResult.ParentManagementGroup `
				-WhatIf:$WhatIfPreference `
				-Confirm:$false

			if ($moveResult -eq $false) {
				$null = $failure.Add("move subscription '$subscriptionId'")
			}
		}

		# Delete all descendants first and the YAML-derived root group last.
		foreach ($managementGroupName in $cleanupTarget.ManagementGroupName) {
			$deleteResult = Remove-ALZManagementGroup `
				-ManagementGroupName $managementGroupName `
				-WhatIf:$WhatIfPreference `
				-Confirm:$false

			if ($deleteResult -eq $false) {
				$null = $failure.Add("delete management group '$managementGroupName'")
			}
		}

		if ($failure.Count -gt 0) {
			Write-Warning (
				'Management group hierarchy cleanup completed with failures: ' +
				($failure -join '; ') + '.'
			)
			return
		}

		Write-Host (
			"Management group hierarchy cleanup processed $($cleanupTarget.SubscriptionId.Count) subscription(s) " +
			"and $($cleanupTarget.ManagementGroupName.Count) management group(s)."
		)
	}
}
#endregion

#region EXECUTION
# Execute the cleanup from the script directory and restore the caller's location afterward.
if ($MyInvocation.InvocationName -ne '.') {
	try {
		Push-Location -Path $PSScriptRoot
		& $Main
	}
	finally {
		Pop-Location
	}
}
#endregion
