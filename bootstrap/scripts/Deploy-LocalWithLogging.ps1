<#
.SYNOPSIS
Runs the local ALZ Terraform deployment with session and Terraform diagnostic logging.

.DESCRIPTION
Invokes scripts\deploy-local.ps1 from the alz-mgmt folder, writes console output to
the output folder, and enables Terraform diagnostic logging for the duration of the run.

.CONTEXT
Azure Landing Zones local Terraform deployment.

.AUTHOR
Greg Tate

.NOTES
Program: Deploy-LocalWithLogging.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Destroy,

    [string]$RootModuleFolderRelativePath = '.',

    [string]$RemoteStateResourceGroupName = 'rg-alz-mgmt-state',

    [string]$RemoteStateStorageAccountName,

    [string]$RemoteStateStorageContainerName = 'local-tfstate',

    [switch]$AutoApprove,

    [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR')]
    [string]$TerraformLogLevel = 'TRACE'
)

# Configuration for the generated deployment script and its persistent logs.
$DeploymentScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'scripts\deploy-local.ps1'
$OutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'output'
$SessionLogPath = Join-Path -Path $OutputPath -ChildPath 'terraform-local-environment.log'
$TerraformLogPath = Join-Path -Path $OutputPath -ChildPath 'terraform-debug.log'

# Main orchestration for a logged local Terraform deployment.
$Main = {
    . $Helpers

    Invoke-LoggedLocalDeployment
}

# Helper functions for validating, invoking, and restoring the deployment environment.
$Helpers = {
    # Runs the generated deployment script and records all console and Terraform diagnostics.
    function Invoke-LoggedLocalDeployment {
        if (-not (Test-Path -LiteralPath $DeploymentScriptPath -PathType Leaf)) {
            throw "The local deployment script was not found: ${DeploymentScriptPath}"
        }

        if (-not $PSCmdlet.ShouldProcess($DeploymentScriptPath, 'Run local Terraform deployment with logging')) {
            return
        }

        # Create the parent-level output directory only for a real deployment.
        $null = New-Item -ItemType Directory -Path $OutputPath -Force

        # Forward named parameters so the generated script does not treat them as positional values.
        $DeploymentParameters = Get-DeploymentParameter

        # Preserve caller-provided Terraform logging settings after the deployment completes.
        $originalTerraformLog = $env:TF_LOG
        $originalTerraformLogPath = $env:TF_LOG_PATH
        $hadTerraformLog = Test-Path -Path Env:TF_LOG
        $hadTerraformLogPath = Test-Path -Path Env:TF_LOG_PATH

        try {
            $env:TF_LOG = $TerraformLogLevel
            $env:TF_LOG_PATH = $TerraformLogPath

            Push-Location -Path $PSScriptRoot
            "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')" |
                Tee-Object -FilePath $SessionLogPath
            "Remote state storage account: $($DeploymentParameters.remote_state_storage_account_name)" |
                Tee-Object -FilePath $SessionLogPath -Append
            "Terraform diagnostics: $TerraformLogPath" |
                Tee-Object -FilePath $SessionLogPath -Append
            & $DeploymentScriptPath @DeploymentParameters *>&1 |
                Tee-Object -FilePath $SessionLogPath -Append
            $deploymentExitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location

            if ($hadTerraformLog) {
                $env:TF_LOG = $originalTerraformLog
            }
            else {
                Remove-Item -Path Env:TF_LOG -ErrorAction SilentlyContinue
            }

            if ($hadTerraformLogPath) {
                $env:TF_LOG_PATH = $originalTerraformLogPath
            }
            else {
                Remove-Item -Path Env:TF_LOG_PATH -ErrorAction SilentlyContinue
            }
        }

        # Propagate a native Terraform failure to the calling shell after logs are saved.
        if ($deploymentExitCode -and $deploymentExitCode -ne 0) {
            exit $deploymentExitCode
        }
    }

    # Returns an explicit storage account name or discovers the only account in the state resource group.
    function Resolve-RemoteStateStorageAccountName {
        if (-not [string]::IsNullOrWhiteSpace($RemoteStateStorageAccountName)) {
            return $RemoteStateStorageAccountName
        }

        if ([string]::IsNullOrWhiteSpace($RemoteStateResourceGroupName)) {
            throw 'RemoteStateResourceGroupName is required when RemoteStateStorageAccountName is not specified.'
        }

        # Query the active Azure CLI subscription for storage accounts in the configured state resource group.
        try {
            $storageAccountNames = @(
                & az storage account list `
                    --resource-group $RemoteStateResourceGroupName `
                    --query '[].name' `
                    --output tsv
            )
            $azureCliExitCode = $LASTEXITCODE
        }
        catch {
            throw "Unable to query storage accounts in resource group '$RemoteStateResourceGroupName'. Ensure Azure CLI is installed, authenticated, and set to the intended subscription, or specify -RemoteStateStorageAccountName. $($_.Exception.Message)"
        }

        # Stop before Terraform when Azure CLI could not read the state resource group.
        if ($azureCliExitCode -ne 0) {
            throw "Unable to query storage accounts in resource group '$RemoteStateResourceGroupName'. Ensure Azure CLI is authenticated and set to the intended subscription, or specify -RemoteStateStorageAccountName. Azure CLI exited with code $azureCliExitCode."
        }

        # Ignore empty CLI output lines before evaluating the discovery result.
        $storageAccountNames = @(
            $storageAccountNames |
                ForEach-Object { $_.ToString().Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        if ($storageAccountNames.Count -eq 1) {
            return $storageAccountNames[0]
        }

        # Do not guess when the state resource group has no account or more than one account.
        $candidateNames = if ($storageAccountNames.Count -eq 0) {
            '<none>'
        }
        else {
            $storageAccountNames -join ', '
        }
        throw "Exactly one storage account is required in resource group '$RemoteStateResourceGroupName' when -RemoteStateStorageAccountName is omitted. Found $($storageAccountNames.Count): $candidateNames. Specify -RemoteStateStorageAccountName explicitly."
    }

    # Builds named parameters for scripts\deploy-local.ps1.
    function Get-DeploymentParameter {
        # Resolve the state account after ShouldProcess approves a real deployment.
        $resolvedRemoteStateStorageAccountName = Resolve-RemoteStateStorageAccountName

        $parameters = @{
            root_module_folder_relative_path       = $RootModuleFolderRelativePath
            remote_state_resource_group_name       = $RemoteStateResourceGroupName
            remote_state_storage_account_name      = $resolvedRemoteStateStorageAccountName
            remote_state_storage_container_name    = $RemoteStateStorageContainerName
        }

        if ($Destroy) {
            $parameters.destroy = $true
        }

        if ($AutoApprove) {
            $parameters.auto_approve = $true
        }

        return $parameters
    }
}

# Run from the alz-mgmt folder and always restore the caller's location.
try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
