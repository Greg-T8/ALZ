<#
# -------------------------------------------------------------------------
# Program: Deploy-BootstrapWithKeyVault.ps1
# Description: Deploy GitHub, Azure DevOps, or local bootstrap services with secure authentication.
# Context: ALZ lab - platform-selectable bootstrap deployment with optional Key Vault backed PAT secrets.
# Author: Greg Tate
# -------------------------------------------------------------------------
.SYNOPSIS
Deploys ALZ bootstrap services using Key Vault PAT values or the local Azure CLI identity.

.DESCRIPTION
Selects GitHub, Azure DevOps, or local bootstrap inputs. GitHub and Azure DevOps
deployments load matching PAT secrets from Azure Key Vault into process-scoped
TF_VAR environment variables. Local deployments use the active Azure CLI identity.
The script invokes Deploy-Accelerator for apply or destroy, optionally writes
Terraform diagnostic logs, and removes any PAT variables that it set.

.CONTEXT
ALZ lab - platform-selectable bootstrap deployment with secure authentication.

.AUTHOR
Greg Tate

.NOTES
Program: Deploy-BootstrapWithKeyVault.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidateSet("GitHub", "AzureDevOps", "Local")]
    [string]$Platform = 'GitHub',

    [switch]$Destroy,

    [switch]$EnableTerraformLogging = $true
)

#region CONFIGURATION
# Set deployment defaults and required Key Vault secret names here.
$ScriptConfig = [ordered]@{
    KeyVaultName                       = "kv-sample-bootstrap-0000"
    GitHubBootstrapPatSecretName       = "alz-github-bootstrap-pat"
    GitHubRunnerPatSecretName          = "alz-github-runner-pat"
    AzureDevOpsBootstrapPatSecretName  = "alz-ado-bootstrap-pat"
    AzureDevOpsAgentPatSecretName      = "alz-ado-runner-pat"
    PlatformInputsYamlPath             = @{
        GitHub       = ".\inputs.github.terraform.yaml"
        AzureDevOps  = ".\inputs.ado.terraform.yaml"
        Local        = ".\inputs.local.terraform.yaml"
    }
    DeploymentRootPath                 = ".."
    PlatformTfvarsRelativePath         = "config\platform-landing-zone.tfvars"
    StarterAdditionalFilesRelativePath = "config\lib"
    OutputRelativePath                 = "output"
    TerraformLogLevel                  = "INFO"
    TerraformLogFileName               = "terraform-bootstrap.log"
}
#endregion

#region MAIN
# Run the platform-selectable bootstrap deployment workflow end-to-end.
$Main = {
    . $Helpers

    # Resolve and validate all runtime configuration before secrets are read.
    $deploymentConfig = New-DeploymentConfig
    Confirm-DeploymentPrerequisite -DeploymentConfig $deploymentConfig

    # Load Key Vault-backed PATs only for version-control-system deployments.
    if ($deploymentConfig.UsesKeyVaultPat) {
        $tokenValue = Get-TokenValue -DeploymentConfig $deploymentConfig
        Set-PlatformTokenVariable -TokenValue $tokenValue
    }
    $terraformLogConfiguration = $null

    try {
        # Enable temporary Terraform diagnostics unless explicitly disabled.
        if ($deploymentConfig.EnableTerraformLogging -and -not $WhatIfPreference) {
            $terraformLogConfiguration = Set-TerraformLogConfiguration `
                -DeploymentConfig $deploymentConfig
        }

        # Invoke bootstrap deployment using the selected authentication flow.
        Invoke-BootstrapDeployment -DeploymentConfig $deploymentConfig
    }
    finally {
        # Restore any Terraform logging settings that predated this script invocation.
        Restore-TerraformLogConfiguration -TerraformLogConfiguration $terraformLogConfiguration

        # Clear only the PAT variables set for a version-control-system deployment.
        if ($deploymentConfig.UsesKeyVaultPat) {
            Clear-PlatformTokenVariable
        }
    }
}
#endregion

#region HELPERS
# Helper functions for validation, secret retrieval, and deployment invocation.
$Helpers = {
    function Confirm-CommandAvailability {
        # Ensure a required command exists before deployment continues.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$CommandName,

            [Parameter(Mandatory)]
            [string]$FailureMessage
        )

        if (-not (Get-Command -Name $CommandName -ErrorAction SilentlyContinue)) {
            throw $FailureMessage
        }
    }

    function Confirm-AzureLogin {
        # Verify the current terminal session is authenticated to Azure CLI.
        [CmdletBinding()]
        param()

        $null = az account show --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI is not logged in. Run 'az login' and re-run this script."
        }
    }

    function Resolve-ExistingFilePath {
        # Resolve a file path to a full path and fail if the file does not exist.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        $candidatePath = if ([System.IO.Path]::IsPathRooted($Path)) {
            $Path
        }
        else {
            Join-Path -Path $PSScriptRoot -ChildPath $Path
        }

        if (-not (Test-Path -Path $candidatePath -PathType Leaf)) {
            throw "Required file not found: $candidatePath"
        }

        return (Resolve-Path -Path $candidatePath).Path
    }

    function Resolve-ExistingDirectoryPath {
        # Resolve a directory path to a full path and fail if the directory does not exist.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        $candidatePath = if ([System.IO.Path]::IsPathRooted($Path)) {
            $Path
        }
        else {
            Join-Path -Path $PSScriptRoot -ChildPath $Path
        }

        if (-not (Test-Path -Path $candidatePath -PathType Container)) {
            throw "Required directory not found: $candidatePath"
        }

        return (Resolve-Path -Path $candidatePath).Path
    }

    function Resolve-DirectoryPath {
        # Resolve a directory path and create it when it does not exist yet.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        $candidatePath = if ([System.IO.Path]::IsPathRooted($Path)) {
            $Path
        }
        else {
            Join-Path -Path $PSScriptRoot -ChildPath $Path
        }

        if (-not (Test-Path -Path $candidatePath -PathType Container)) {
            New-Item -Path $candidatePath -ItemType Directory -Force | Out-Null
        }

        return (Resolve-Path -Path $candidatePath).Path
    }

    function New-DeploymentConfig {
        # Build the effective deployment configuration from the script config block.
        [CmdletBinding()]
        param()

        # Select the platform-specific bootstrap input before resolving deployment paths.
        $inputsYamlPath = Resolve-ExistingFilePath -Path $ScriptConfig.PlatformInputsYamlPath[$Platform]

        $deploymentRootPath = Resolve-ExistingDirectoryPath -Path $ScriptConfig.DeploymentRootPath
        $platformTfvarsPath = Resolve-ExistingFilePath -Path (
            Join-Path -Path $deploymentRootPath -ChildPath $ScriptConfig.PlatformTfvarsRelativePath
        )
        $starterAdditionalFilesPath = Resolve-ExistingDirectoryPath -Path (
            Join-Path -Path $deploymentRootPath -ChildPath $ScriptConfig.StarterAdditionalFilesRelativePath
        )
        $outputPath = Resolve-DirectoryPath -Path (
            Join-Path -Path $deploymentRootPath -ChildPath $ScriptConfig.OutputRelativePath
        )

        return [pscustomobject]@{
            KeyVaultName                      = $ScriptConfig.KeyVaultName
            GitHubBootstrapPatSecretName      = $ScriptConfig.GitHubBootstrapPatSecretName
            GitHubRunnerPatSecretName         = $ScriptConfig.GitHubRunnerPatSecretName
            AzureDevOpsBootstrapPatSecretName = $ScriptConfig.AzureDevOpsBootstrapPatSecretName
            AzureDevOpsAgentPatSecretName     = $ScriptConfig.AzureDevOpsAgentPatSecretName
            Platform                          = $Platform
            InputsYamlPath                    = $inputsYamlPath
            PlatformTfvarsPath                = $platformTfvarsPath
            StarterAdditionalFilesPath        = $starterAdditionalFilesPath
            OutputPath                        = $outputPath
            EnableTerraformLogging             = [bool]$EnableTerraformLogging
            UsesKeyVaultPat                    = $Platform -ne "Local"
        }
    }

    function Confirm-DeploymentPrerequisite {
        # Validate commands, authentication, and required runtime configuration values.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$DeploymentConfig
        )

        Confirm-CommandAvailability `
            -CommandName "az" `
            -FailureMessage "Azure CLI is required. Install it from https://aka.ms/azure-cli."
        Confirm-CommandAvailability `
            -CommandName "Deploy-Accelerator" `
            -FailureMessage "Deploy-Accelerator command is not available. Install/import the ALZ PowerShell module before running this script."
        Confirm-AzureLogin

        if ($DeploymentConfig.UsesKeyVaultPat -and (
                [string]::IsNullOrWhiteSpace($DeploymentConfig.KeyVaultName) -or
                $DeploymentConfig.KeyVaultName -eq "replace-with-key-vault-name"
            )) {
            throw "Set ScriptConfig.KeyVaultName to your Azure Key Vault name before running this script."
        }
    }

    function Get-KeyVaultSecretValue {
        # Read a secret value from Azure Key Vault without writing the value to console output.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$VaultName,

            [Parameter(Mandatory)]
            [string]$SecretName
        )

        $secretValue = az keyvault secret show `
            --vault-name $VaultName `
            --name $SecretName `
            --query value `
            --output tsv 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($secretValue)) {
            throw "Unable to read secret '$SecretName' from Key Vault '$VaultName'."
        }

        return $secretValue.Trim()
    }

    function Get-TokenValue {
        # Collect required PAT secret values for bootstrap deployment.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$DeploymentConfig
        )

        # Select the platform-specific Key Vault secrets for the requested deployment.
        $secretNames = switch ($DeploymentConfig.Platform) {
            "GitHub" {
                [pscustomobject]@{
                    Bootstrap = $DeploymentConfig.GitHubBootstrapPatSecretName
                    Agent     = $DeploymentConfig.GitHubRunnerPatSecretName
                }
            }
            "AzureDevOps" {
                [pscustomobject]@{
                    Bootstrap = $DeploymentConfig.AzureDevOpsBootstrapPatSecretName
                    Agent     = $DeploymentConfig.AzureDevOpsAgentPatSecretName
                }
            }
        }

        # Retrieve the selected platform's bootstrap and agent PATs from Key Vault.
        $bootstrapPat = Get-KeyVaultSecretValue `
            -VaultName $DeploymentConfig.KeyVaultName `
            -SecretName $secretNames.Bootstrap
        $agentPat = Get-KeyVaultSecretValue `
            -VaultName $DeploymentConfig.KeyVaultName `
            -SecretName $secretNames.Agent

        return [pscustomobject]@{
            Platform     = $DeploymentConfig.Platform
            BootstrapPat = $bootstrapPat
            AgentPat     = $agentPat
        }
    }

    function Set-PlatformTokenVariable {
        # Export PAT values into process-scoped TF_VAR environment variables for the selected platform.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$TokenValue
        )

        # Set only the selected platform's variables for this process.
        switch ($TokenValue.Platform) {
            "GitHub" {
                Remove-Item Env:\TF_VAR_azure_devops_personal_access_token -ErrorAction SilentlyContinue
                Remove-Item Env:\TF_VAR_azure_devops_agents_personal_access_token -ErrorAction SilentlyContinue
                $env:TF_VAR_github_personal_access_token = $TokenValue.BootstrapPat
                $env:TF_VAR_github_runners_personal_access_token = $TokenValue.AgentPat
            }
            "AzureDevOps" {
                Remove-Item Env:\TF_VAR_github_personal_access_token -ErrorAction SilentlyContinue
                Remove-Item Env:\TF_VAR_github_runners_personal_access_token -ErrorAction SilentlyContinue
                $env:TF_VAR_azure_devops_personal_access_token = $TokenValue.BootstrapPat
                $env:TF_VAR_azure_devops_agents_personal_access_token = $TokenValue.AgentPat
            }
        }
    }

    function Clear-PlatformTokenVariable {
        # Remove selected-platform TF_VAR token values from the current process after deployment completes.
        [CmdletBinding()]
        param()

        Remove-Item Env:\TF_VAR_github_personal_access_token -ErrorAction SilentlyContinue
        Remove-Item Env:\TF_VAR_github_runners_personal_access_token -ErrorAction SilentlyContinue
        Remove-Item Env:\TF_VAR_azure_devops_personal_access_token -ErrorAction SilentlyContinue
        Remove-Item Env:\TF_VAR_azure_devops_agents_personal_access_token -ErrorAction SilentlyContinue
    }

    function Set-TerraformLogConfiguration {
        # Enable Terraform diagnostics in the deployment output while preserving prior process settings.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$DeploymentConfig
        )

        # Capture the existing process-scoped Terraform logging configuration for restoration.
        $terraformLogConfiguration = [pscustomobject]@{
            LogDefined     = Test-Path -Path Env:\TF_LOG
            LogValue       = $env:TF_LOG
            LogPathDefined = Test-Path -Path Env:\TF_LOG_PATH
            LogPathValue   = $env:TF_LOG_PATH
        }

        # Direct Terraform diagnostics to a predictable file outside generated version folders.
        $terraformLogPath = Join-Path `
            -Path $DeploymentConfig.OutputPath `
            -ChildPath $ScriptConfig.TerraformLogFileName

        # Start each bootstrap run with a clean workflow-specific Terraform log.
        if (Test-Path -LiteralPath $terraformLogPath -PathType Leaf) {
            Clear-Content -LiteralPath $terraformLogPath -Force
        }
        else {
            New-Item -Path $terraformLogPath -ItemType File -Force | Out-Null
        }

        $env:TF_LOG = $ScriptConfig.TerraformLogLevel
        $env:TF_LOG_PATH = $terraformLogPath

        Write-Warning "Terraform diagnostic logging is enabled at '$terraformLogPath'. Logs can contain sensitive values; handle the file accordingly."

        return $terraformLogConfiguration
    }

    function Restore-TerraformLogConfiguration {
        # Restore Terraform logging environment variables after the deployment invocation.
        [CmdletBinding()]
        param(
            [pscustomobject]$TerraformLogConfiguration
        )

        if ($null -eq $TerraformLogConfiguration) {
            return
        }

        # Restore the prior TF_LOG value or remove the variable if it did not previously exist.
        if ($TerraformLogConfiguration.LogDefined) {
            $env:TF_LOG = $TerraformLogConfiguration.LogValue
        }
        else {
            Remove-Item Env:\TF_LOG -ErrorAction SilentlyContinue
        }

        # Restore the prior TF_LOG_PATH value or remove the variable if it did not previously exist.
        if ($TerraformLogConfiguration.LogPathDefined) {
            $env:TF_LOG_PATH = $TerraformLogConfiguration.LogPathValue
        }
        else {
            Remove-Item Env:\TF_LOG_PATH -ErrorAction SilentlyContinue
        }
    }

    function Invoke-BootstrapDeployment {
        # Invoke Deploy-Accelerator with the configured inputs and run mode.
        [CmdletBinding(SupportsShouldProcess = $true)]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$DeploymentConfig
        )

        $operation = if ($Destroy.IsPresent) { "destroy" } else { "apply" }
        $inputFiles = @(
            $DeploymentConfig.InputsYamlPath,
            $DeploymentConfig.PlatformTfvarsPath
        )

        if (-not $PSCmdlet.ShouldProcess($DeploymentConfig.OutputPath, "Run Deploy-Accelerator ($operation)")) {
            return
        }

        $deployParameters = @{
            Inputs = $inputFiles
            saf    = $DeploymentConfig.StarterAdditionalFilesPath
            output = $DeploymentConfig.OutputPath
        }

        if ($Destroy.IsPresent) {
            $deployParameters.destroy = $true
        }

        Deploy-Accelerator @deployParameters
    }
}
#endregion

#region EXECUTION
# Execute main workflow from the script directory and restore the original location.
try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
#endregion
