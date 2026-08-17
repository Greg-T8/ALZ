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

    # Builds named parameters for scripts\deploy-local.ps1.
    function Get-DeploymentParameter {
        $parameters = @{
            root_module_folder_relative_path       = $RootModuleFolderRelativePath
            remote_state_resource_group_name       = $RemoteStateResourceGroupName
            remote_state_storage_account_name      = $RemoteStateStorageAccountName
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
