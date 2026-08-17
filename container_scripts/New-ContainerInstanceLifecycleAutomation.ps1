<#
.SYNOPSIS
Deploys scheduled Azure Automation lifecycle control for ALZ container groups.

.DESCRIPTION
Validates an existing subscription, resource group, and ALZ Azure Container
Instance inventory before deploying an Automation Account with a system-assigned
managed identity, PowerShell 7.4 runtime environment, published stopping runbook,
daily schedule, and resource-group-scoped custom role. All Azure operations use
the supplied subscription ID explicitly. Use WhatIf to preview without mutation.

.CONTEXT
ALZ lab - scheduled cost control for self-hosted ACI agents.

.AUTHOR
Greg Tate

.NOTES
Program: New-ContainerInstanceLifecycleAutomation.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{4,48}[A-Za-z0-9]$')]
    [string]$AutomationAccountName = 'aa-alz-aci-lifecycle',

    [ValidateNotNullOrEmpty()]
    [string]$ContainerNamePrefix = 'aci-alz',

    [ValidateScript({ $_ -ge [TimeSpan]::Zero -and $_ -lt [TimeSpan]::FromDays(1) })]
    [TimeSpan]$ShutdownTime = [TimeSpan]::FromHours(8),

    [ValidateNotNullOrEmpty()]
    [string]$TimeZone = 'America/Chicago',

    [hashtable]$Tag = @{}
)

#region CONFIGURATION
# Define stable Azure resource names, API versions, tags, and retry behavior.
$ScriptConfig = [ordered]@{
    AutomationApiVersion       = '2024-10-23'
    AuthorizationApiVersion    = '2022-04-01'
    ProviderNamespace          = 'Microsoft.Automation'
    RuntimeEnvironmentName     = 'ps74-alz-aci'
    RunbookName                = 'Stop-AlzContainerInstance'
    ScheduleName               = 'daily-stop-alz-aci'
    RoleNamePrefix             = 'ALZ ACI Lifecycle Operator'
    RunbookDescription         = 'Stops running ALZ ACI groups selected by resource group and name prefix.'
    ScheduleDescription        = 'Daily shutdown for ALZ Azure Container Instance groups.'
    MinimumScheduleLeadMinutes = 10
    PollSeconds                = 3
    PollAttempts               = 60
    DefaultTags                = [ordered]@{
        Environment      = 'Lab'
        Category         = 'Learning'
        Workspace        = 'ALZ'
        Purpose          = 'ACI Lifecycle Automation'
        Owner            = 'Greg Tate'
        DateCreated      = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        DeploymentMethod = 'PowerShell'
        ManagedBy        = 'powershell'
    }
}

# Record the actual confirmation value before entering the first scriptblock.
$ScriptConfirm = (
    $PSBoundParameters.ContainsKey('Confirm') -and
    [bool]$PSBoundParameters['Confirm']
)
#endregion

#region MAIN
# Run discovery, preview, and the approved Automation provisioning workflow.
$Main = {
    . $Helpers

    $config = Get-ProvisioningConfig
    Confirm-ProvisioningPrerequisite -Config $config
    $context = Get-ProvisioningContext -Config $config
    Show-ProvisioningPlan -Config $config -Context $context
    $deployment = Invoke-AutomationProvisioning `
        -Config $config `
        -Context $context `
        -WhatIf:$WhatIfPreference `
        -Confirm:$ScriptConfirm

    if ($deployment) {
        $deployment
    }
}
#endregion

#region HELPERS
# Define configuration, Azure CLI, REST, scheduling, identity, RBAC, and deployment helpers.
$Helpers = {
    function Get-ProvisioningConfig {
        # Build the validated immutable configuration used throughout provisioning.
        [CmdletBinding()]
        param()

        # Validate caller-provided tags before combining them with governance defaults.
        $effectiveTag = @{}
        foreach ($entry in $ScriptConfig.DefaultTags.GetEnumerator()) {
            $effectiveTag[[string]$entry.Key] = [string]$entry.Value
        }

        foreach ($entry in $Tag.GetEnumerator()) {
            $tagName = [string]$entry.Key
            $tagValue = [string]$entry.Value

            if ([string]::IsNullOrWhiteSpace($tagName)) {
                throw 'Tag names cannot be empty.'
            }

            if ([string]::IsNullOrWhiteSpace($tagValue)) {
                throw "Tag '$tagName' must have a non-empty value."
            }

            if ($tagName.Length -gt 512 -or $tagValue.Length -gt 256) {
                throw "Tag '$tagName' exceeds Azure's tag name or value length limit."
            }

            $effectiveTag[$tagName] = $tagValue
        }

        # Resolve the companion runbook relative to the deployment utility.
        $runbookPath = Join-Path -Path $PSScriptRoot -ChildPath "$($ScriptConfig.RunbookName).ps1"

        return [pscustomobject]@{
            SubscriptionId             = $SubscriptionId.ToLowerInvariant()
            ResourceGroupName          = $ResourceGroupName
            AutomationAccountName      = $AutomationAccountName
            ContainerNamePrefix        = $ContainerNamePrefix
            ShutdownTime               = $ShutdownTime
            TimeZone                   = $TimeZone
            Tag                        = $effectiveTag
            RunbookPath                = $runbookPath
            AutomationApiVersion       = $ScriptConfig.AutomationApiVersion
            AuthorizationApiVersion    = $ScriptConfig.AuthorizationApiVersion
            ProviderNamespace          = $ScriptConfig.ProviderNamespace
            RuntimeEnvironmentName     = $ScriptConfig.RuntimeEnvironmentName
            RunbookName                = $ScriptConfig.RunbookName
            ScheduleName               = $ScriptConfig.ScheduleName
            RoleNamePrefix             = $ScriptConfig.RoleNamePrefix
            RunbookDescription         = $ScriptConfig.RunbookDescription
            ScheduleDescription        = $ScriptConfig.ScheduleDescription
            MinimumScheduleLeadMinutes = $ScriptConfig.MinimumScheduleLeadMinutes
            PollSeconds                = $ScriptConfig.PollSeconds
            PollAttempts               = $ScriptConfig.PollAttempts
        }
    }

    function Confirm-ProvisioningPrerequisite {
        # Validate local tooling, authentication, time zone, and companion runbook syntax.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config
        )

        # Confirm Azure CLI is installed before any discovery request.
        if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI is required. Install it from https://aka.ms/azure-cli.'
        }

        # Confirm the caller is authenticated without relying on the selected subscription.
        $null = Invoke-AzureCliText `
            -ArgumentList @('account', 'show', '--output', 'none', '--only-show-errors') `
            -FailureMessage "Azure CLI is not logged in. Run 'az login' and retry."

        # Resolve the requested IANA or Windows time-zone identifier locally.
        try {
            $null = [TimeZoneInfo]::FindSystemTimeZoneById($Config.TimeZone)
        }
        catch {
            throw "Time zone '$($Config.TimeZone)' is not available on this system."
        }

        if (-not (Test-Path -LiteralPath $Config.RunbookPath -PathType Leaf)) {
            # Refuse deployment when the companion source file cannot be published.
            throw "Required runbook file not found: $($Config.RunbookPath)"
        }

        # Parse the runbook before any Azure mutation is considered.
        $parseTokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $Config.RunbookPath,
            [ref]$parseTokens,
            [ref]$parseErrors
        )

        if ($parseErrors.Count -gt 0) {
            # Return every syntax error with its source extent for local correction.
            $errorText = ($parseErrors | ForEach-Object {
                    "Line $($_.Extent.StartLineNumber): $($_.Message)"
                }) -join [Environment]::NewLine
            throw "Runbook syntax validation failed.$([Environment]::NewLine)$errorText"
        }
    }

    function Invoke-AzureCliText {
        # Run Azure CLI and return text while converting native failures into terminating errors.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string[]]$ArgumentList,

            [Parameter(Mandatory)]
            [string]$FailureMessage
        )

        # Capture both streams so Azure authorization and validation failures remain actionable.
        $output = & az @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine

        if ($exitCode -ne 0) {
            # Preserve a concise caller-specific message when Azure CLI emits no diagnostics.
            if ([string]::IsNullOrWhiteSpace($outputText)) {
                throw $FailureMessage
            }

            throw "$FailureMessage Azure CLI output: $outputText"
        }

        return $outputText
    }

    function Invoke-AzureRest {
        # Submit one authenticated Azure Resource Manager REST request through Azure CLI.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [ValidateSet('get', 'put', 'post', 'patch')]
            [string]$Method,

            [Parameter(Mandatory)]
            [string]$Url,

            [string]$Body,

            [string[]]$Header = @(),

            [Parameter(Mandatory)]
            [string]$FailureMessage
        )

        # Default structured request bodies to the ARM-required JSON media type.
        $effectiveHeader = @($Header)
        $hasContentType = $effectiveHeader |
            Where-Object { $_ -match '(?i)^Content-Type=' }

        if ($PSBoundParameters.ContainsKey('Body') -and -not $hasContentType) {
            # Ensure Azure Resource Manager can deserialize JSON deployment bodies.
            $effectiveHeader += 'Content-Type=application/json'
        }

        # Initialize an exact temporary path only for structured ARM request content.
        $jsonBodyPath = $null
        $bodyArgument = $Body

        try {
            # Pass JSON through a UTF-8 file so native Windows argument handling cannot strip quotes.
            if (
                $PSBoundParameters.ContainsKey('Body') -and
                $effectiveHeader -contains 'Content-Type=application/json'
            ) {
                $jsonBodyPath = Join-Path `
                    -Path ([IO.Path]::GetTempPath()) `
                    -ChildPath "alz-aci-arm-$([Guid]::NewGuid().ToString('N')).json"
                [IO.File]::WriteAllText(
                    $jsonBodyPath,
                    $Body,
                    [Text.UTF8Encoding]::new($false)
                )
                $bodyArgument = "@$jsonBodyPath"
            }

            # Build the argument array without shell interpolation or a global subscription change.
            $argumentList = @(
                'rest',
                '--method',
                $Method,
                '--url',
                $Url,
                '--only-show-errors'
            )

            if ($PSBoundParameters.ContainsKey('Body')) {
                # Supply either a protected JSON file or the caller's explicit file reference.
                $argumentList += @('--body', $bodyArgument)
            }

            if ($effectiveHeader.Count -gt 0) {
                # Add the selected media type without overriding explicit raw-content headers.
                $argumentList += @('--headers')
                $argumentList += $effectiveHeader
            }

            return Invoke-AzureCliText `
                -ArgumentList $argumentList `
                -FailureMessage $FailureMessage
        }
        finally {
            # Delete only the unique JSON request file created by this function invocation.
            if ($jsonBodyPath -and [IO.File]::Exists($jsonBodyPath)) {
                [IO.File]::Delete($jsonBodyPath)
            }
        }
    }

    function Get-AzureRestResource {
        # Retrieve an ARM resource or return null only for a confirmed not-found response.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Url,

            [Parameter(Mandatory)]
            [string]$FailureMessage
        )

        # Call Azure CLI directly so a 404 can be distinguished from authorization failures.
        $output = & az rest `
            --method get `
            --url $Url `
            --only-show-errors 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine

        if ($exitCode -eq 0) {
            # Convert successful ARM JSON into a structured PowerShell object.
            if ([string]::IsNullOrWhiteSpace($outputText)) {
                return $null
            }

            return $outputText | ConvertFrom-Json
        }

        if (
            $outputText -match
            '(?i)ResourceNotFound|RoleDefinitionDoesNotExist|NotFound|StatusCode=404|status code 404|\(404\)'
        ) {
            # Treat only explicit ARM not-found evidence as an absent resource.
            return $null
        }

        throw "$FailureMessage Azure CLI output: $outputText"
    }

    function Get-EscapedArmSegment {
        # Escape one ARM path segment without altering Azure resource-name semantics.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Value
        )

        return [Uri]::EscapeDataString($Value)
    }

    function Get-DeterministicGuid {
        # Generate a stable GUID from resource identity text for idempotent ARM child resources.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Value
        )

        # Use the first 16 SHA-256 bytes only as a deterministic identifier, not a credential.
        $hash = [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Value)
        )
        $guidBytes = [byte[]]::new(16)
        [Array]::Copy($hash, $guidBytes, 16)

        return [Guid]::new($guidBytes)
    }

    function Get-ProvisioningContext {
        # Resolve the immutable Azure scope and matching ACI inventory before deployment.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config
        )

        # Resolve the supplied subscription ID without changing the active Azure CLI account.
        $subscriptionJson = Invoke-AzureCliText `
            -ArgumentList @(
                'account',
                'show',
                '--subscription',
                $Config.SubscriptionId,
                '--query',
                '{Id:id,Name:name,TenantId:tenantId}',
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to resolve subscription '$($Config.SubscriptionId)'."
        $subscription = $subscriptionJson | ConvertFrom-Json

        # Resolve the existing resource group and inherit its Azure location.
        $resourceGroupJson = Invoke-AzureCliText `
            -ArgumentList @(
                'group',
                'show',
                '--name',
                $Config.ResourceGroupName,
                '--subscription',
                $Config.SubscriptionId,
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Resource group '$($Config.ResourceGroupName)' was not found in subscription '$($Config.SubscriptionId)'."
        $resourceGroup = $resourceGroupJson | ConvertFrom-Json

        # Inventory only the target resource group and filter names locally.
        $containerJson = Invoke-AzureCliText `
            -ArgumentList @(
                'container',
                'list',
                '--resource-group',
                $Config.ResourceGroupName,
                '--subscription',
                $Config.SubscriptionId,
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to list container groups in resource group '$($Config.ResourceGroupName)'."
        $containerGroup = @(
            @($containerJson | ConvertFrom-Json) |
                Where-Object { [string]$_.name -like "$($Config.ContainerNamePrefix)*" }
        )

        if ($containerGroup.Count -eq 0) {
            # Prevent deploying automation against an accidentally selected empty resource group.
            throw "No container groups beginning with '$($Config.ContainerNamePrefix)' were found in resource group '$($Config.ResourceGroupName)'."
        }

        # Calculate stable ARM paths and names from the confirmed Azure scope.
        $resourceGroupId = [string]$resourceGroup.id
        $roleSuffix = (Get-DeterministicGuid -Value $resourceGroupId).ToString('N').Substring(0, 8)
        $roleName = "$($Config.RoleNamePrefix) $roleSuffix"
        $roleDefinitionId = Get-DeterministicGuid -Value "$resourceGroupId|$roleName"
        $jobScheduleId = Get-DeterministicGuid `
            -Value "$resourceGroupId|$($Config.AutomationAccountName)|$($Config.RunbookName)|$($Config.ScheduleName)"

        return [pscustomobject]@{
            Subscription       = $subscription
            ResourceGroup      = $resourceGroup
            ResourceGroupId    = $resourceGroupId
            ContainerGroup     = $containerGroup
            RoleName           = $roleName
            RoleDefinitionId   = $roleDefinitionId
            JobScheduleId      = $jobScheduleId
            NextSchedule       = Get-NextScheduleTime -Config $Config
        }
    }

    function Get-NextScheduleTime {
        # Calculate the next local shutdown time with a safe Automation scheduling lead.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config
        )

        # Convert the current instant into the requested DST-aware local time zone.
        $timeZoneInfo = [TimeZoneInfo]::FindSystemTimeZoneById($Config.TimeZone)
        $nowUtc = [DateTimeOffset]::UtcNow
        $localNow = [TimeZoneInfo]::ConvertTime($nowUtc, $timeZoneInfo)
        $candidateDate = $localNow.Date.Add($Config.ShutdownTime)
        $candidateLocal = [DateTime]::SpecifyKind($candidateDate, [DateTimeKind]::Unspecified)
        $candidateOffset = $timeZoneInfo.GetUtcOffset($candidateLocal)
        $candidate = [DateTimeOffset]::new($candidateLocal, $candidateOffset)

        if ($candidate.ToUniversalTime() -lt $nowUtc.AddMinutes($Config.MinimumScheduleLeadMinutes)) {
            # Move to the following day when today's occurrence is too close or already passed.
            $candidateLocal = $candidateLocal.AddDays(1)
            $candidateOffset = $timeZoneInfo.GetUtcOffset($candidateLocal)
            $candidate = [DateTimeOffset]::new($candidateLocal, $candidateOffset)
        }

        return $candidate
    }

    function Show-ProvisioningPlan {
        # Display the complete target set before ShouldProcess considers any mutation.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$Context
        )

        # Emit a structured preview suitable for console review or pipeline capture.
        [pscustomobject]@{
            SubscriptionName      = $Context.Subscription.Name
            SubscriptionId        = $Context.Subscription.Id
            ResourceGroupName     = $Context.ResourceGroup.name
            Location              = $Context.ResourceGroup.location
            AutomationAccountName = $Config.AutomationAccountName
            RuntimeEnvironment    = $Config.RuntimeEnvironmentName
            RunbookName           = $Config.RunbookName
            ScheduleName          = $Config.ScheduleName
            NextRun               = $Context.NextSchedule.ToString('o')
            TimeZone              = $Config.TimeZone
            RoleName              = $Context.RoleName
            ContainerNamePrefix   = $Config.ContainerNamePrefix
            ContainerGroups       = @($Context.ContainerGroup | ForEach-Object { $_.name })
        } | Write-Output
    }

    function Invoke-AutomationProvisioning {
        # Apply the complete Automation deployment after one cohesive ShouldProcess decision.
        [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$Context
        )

        $target = "$($Config.AutomationAccountName) in resource group $($Context.ResourceGroup.name), subscription $($Context.Subscription.Name) ($($Context.Subscription.Id))"
        if (-not $PSCmdlet.ShouldProcess($target, 'Deploy ALZ ACI lifecycle automation')) {
            # A declined or WhatIf request ends before every provider and ARM mutation.
            return
        }

        # Provision dependencies in the order required by identity, RBAC, and scheduling.
        Confirm-AutomationProvider -Config $Config
        $automationAccount = Invoke-AutomationAccountDeployment -Config $Config -Context $Context
        $principalId = Get-AutomationPrincipalId `
            -Config $Config `
            -AutomationAccount $automationAccount
        Invoke-AutomationRuntimeEnvironmentDeployment -Config $Config
        Invoke-AutomationRunbookDeployment -Config $Config -Context $Context
        Invoke-AutomationScheduleDeployment -Config $Config -Context $Context
        Invoke-AutomationJobScheduleDeployment -Config $Config -Context $Context
        $roleDefinitionId = Invoke-ContainerLifecycleRoleDeployment `
            -Config $Config `
            -Context $Context
        Invoke-ContainerLifecycleRoleAssignmentDeployment `
            -Config $Config `
            -Context $Context `
            -PrincipalId $principalId `
            -RoleDefinitionResourceId $roleDefinitionId

        # Return a concise deployment contract after every requested resource succeeds.
        return [pscustomobject]@{
            Status                = 'Ready'
            AutomationAccountName = $Config.AutomationAccountName
            PrincipalId           = $principalId
            RunbookName           = $Config.RunbookName
            ScheduleName          = $Config.ScheduleName
            NextRun               = $Context.NextSchedule.ToString('o')
            TimeZone              = $Config.TimeZone
            RoleName              = $Context.RoleName
            TargetContainerCount  = $Context.ContainerGroup.Count
        }
    }

    function Confirm-AutomationProvider {
        # Register Microsoft.Automation only when the target subscription requires it.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config
        )

        # Read the provider state before deciding whether registration is necessary.
        $registrationState = Invoke-AzureCliText `
            -ArgumentList @(
                'provider',
                'show',
                '--namespace',
                $Config.ProviderNamespace,
                '--subscription',
                $Config.SubscriptionId,
                '--query',
                'registrationState',
                '--output',
                'tsv',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to read provider '$($Config.ProviderNamespace)'."

        if ($registrationState.Trim() -eq 'Registered') {
            # Reuse the existing provider registration without a write operation.
            return
        }

        # Register and wait for the provider before creating Automation resources.
        $null = Invoke-AzureCliText `
            -ArgumentList @(
                'provider',
                'register',
                '--namespace',
                $Config.ProviderNamespace,
                '--subscription',
                $Config.SubscriptionId,
                '--wait',
                '--output',
                'none',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to register provider '$($Config.ProviderNamespace)'."
    }

    function Get-AutomationBaseUrl {
        # Build the escaped Automation Account ARM URL shared by child resources.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config
        )

        $resourceGroup = Get-EscapedArmSegment -Value $Config.ResourceGroupName
        $accountName = Get-EscapedArmSegment -Value $Config.AutomationAccountName
        return "https://management.azure.com/subscriptions/$($Config.SubscriptionId)/resourceGroups/$resourceGroup/providers/Microsoft.Automation/automationAccounts/$accountName"
    }

    function Get-MergedAutomationTag {
        # Preserve unrelated existing tags and the original DateCreated value.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [AllowNull()]
            [pscustomobject]$ExistingAccount
        )

        # Copy existing tags first so explicit governed values retain precedence.
        $mergedTag = @{}
        if ($ExistingAccount -and $ExistingAccount.tags) {
            foreach ($property in $ExistingAccount.tags.PSObject.Properties) {
                $mergedTag[$property.Name] = [string]$property.Value
            }
        }

        foreach ($entry in $Config.Tag.GetEnumerator()) {
            $mergedTag[[string]$entry.Key] = [string]$entry.Value
        }

        if ($ExistingAccount -and $ExistingAccount.tags.DateCreated) {
            # Retain the actual creation date during an idempotent rerun.
            $mergedTag.DateCreated = [string]$ExistingAccount.tags.DateCreated
        }

        return $mergedTag
    }

    function Invoke-AutomationAccountDeployment {
        # Create or safely reconcile the Basic Automation Account and managed identity.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$Context
        )

        $baseUrl = Get-AutomationBaseUrl -Config $Config
        $accountUrl = "${baseUrl}?api-version=$($Config.AutomationApiVersion)"
        $existingAccount = Get-AzureRestResource `
            -Url $accountUrl `
            -FailureMessage "Unable to inspect Automation Account '$($Config.AutomationAccountName)'."

        if ($existingAccount) {
            # Refuse an immutable location or SKU collision under the requested name.
            if ([string]$existingAccount.location -ine [string]$Context.ResourceGroup.location) {
                throw "Existing Automation Account '$($Config.AutomationAccountName)' is in location '$($existingAccount.location)', not '$($Context.ResourceGroup.location)'."
            }

            if ([string]$existingAccount.properties.sku.name -ine 'Basic') {
                throw "Existing Automation Account '$($Config.AutomationAccountName)' does not use the required Basic SKU."
            }

            if ([string]$existingAccount.identity.type -match 'UserAssigned') {
                throw "Existing Automation Account '$($Config.AutomationAccountName)' uses a user-assigned identity and will not be modified."
            }
        }

        # Preserve an existing public-network setting while defaulting new lab resources to enabled.
        $publicNetworkAccess = $true
        if ($existingAccount -and $null -ne $existingAccount.properties.publicNetworkAccess) {
            $publicNetworkAccess = [bool]$existingAccount.properties.publicNetworkAccess
        }

        # Submit a complete idempotent account representation with the system identity enabled.
        $body = @{
            location   = [string]$Context.ResourceGroup.location
            identity   = @{ type = 'SystemAssigned' }
            tags       = Get-MergedAutomationTag -Config $Config -ExistingAccount $existingAccount
            properties = @{
                publicNetworkAccess = $publicNetworkAccess
                sku                 = @{ name = 'Basic' }
                encryption          = @{ keySource = 'Microsoft.Automation' }
            }
        } | ConvertTo-Json -Depth 20 -Compress
        $responseJson = Invoke-AzureRest `
            -Method put `
            -Url $accountUrl `
            -Body $body `
            -FailureMessage "Unable to create or update Automation Account '$($Config.AutomationAccountName)'."

        if ([string]::IsNullOrWhiteSpace($responseJson)) {
            # Re-read the account when Azure returns an empty successful response.
            return Get-AzureRestResource `
                -Url $accountUrl `
                -FailureMessage "Unable to read Automation Account '$($Config.AutomationAccountName)' after deployment."
        }

        return $responseJson | ConvertFrom-Json
    }

    function Get-AutomationPrincipalId {
        # Poll until Azure exposes the Automation Account system-assigned principal ID.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$AutomationAccount
        )

        # Return the identity immediately when it is present in the PUT response.
        if (-not [string]::IsNullOrWhiteSpace([string]$AutomationAccount.identity.principalId)) {
            return [string]$AutomationAccount.identity.principalId
        }

        $accountUrl = "$(Get-AutomationBaseUrl -Config $Config)?api-version=$($Config.AutomationApiVersion)"
        for ($attempt = 1; $attempt -le $Config.PollAttempts; $attempt++) {
            # Re-read the identity because Entra principal materialization is asynchronous.
            $account = Get-AzureRestResource `
                -Url $accountUrl `
                -FailureMessage "Unable to poll Automation Account '$($Config.AutomationAccountName)'."
            if (-not [string]::IsNullOrWhiteSpace([string]$account.identity.principalId)) {
                return [string]$account.identity.principalId
            }

            Start-Sleep -Seconds $Config.PollSeconds
        }

        throw "Automation Account '$($Config.AutomationAccountName)' did not expose a system-assigned principal ID."
    }

    function Invoke-AutomationRuntimeEnvironmentDeployment {
        # Create or reuse the compatible PowerShell 7.4 Automation runtime environment.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config
        )

        $runtimeName = Get-EscapedArmSegment -Value $Config.RuntimeEnvironmentName
        $runtimeUrl = "$(Get-AutomationBaseUrl -Config $Config)/runtimeEnvironments/${runtimeName}?api-version=$($Config.AutomationApiVersion)"
        $existingRuntime = Get-AzureRestResource `
            -Url $runtimeUrl `
            -FailureMessage "Unable to inspect runtime environment '$($Config.RuntimeEnvironmentName)'."

        if ($existingRuntime) {
            # Runtime language and version are immutable, so only an exact match is reusable.
            if (
                [string]$existingRuntime.properties.runtime.language -ine 'PowerShell' -or
                [string]$existingRuntime.properties.runtime.version -ne '7.4'
            ) {
                throw "Existing runtime environment '$($Config.RuntimeEnvironmentName)' is not PowerShell 7.4."
            }

            return
        }

        # Create a PowerShell 7.4 environment that includes Azure CLI as a default package.
        $body = @{
            name       = $Config.RuntimeEnvironmentName
            properties = @{
                runtime = @{
                    language = 'PowerShell'
                    version  = '7.4'
                }
            }
        } | ConvertTo-Json -Depth 20 -Compress
        $null = Invoke-AzureRest `
            -Method put `
            -Url $runtimeUrl `
            -Body $body `
            -FailureMessage "Unable to create runtime environment '$($Config.RuntimeEnvironmentName)'."
    }

    function Invoke-AutomationRunbookDeployment {
        # Create, replace, and publish the companion stopping runbook.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$Context
        )

        $runbookName = Get-EscapedArmSegment -Value $Config.RunbookName
        $runbookBaseUrl = "$(Get-AutomationBaseUrl -Config $Config)/runbooks/$runbookName"
        $runbookUrl = "${runbookBaseUrl}?api-version=$($Config.AutomationApiVersion)"
        $existingRunbook = Get-AzureRestResource `
            -Url $runbookUrl `
            -FailureMessage "Unable to inspect runbook '$($Config.RunbookName)'."

        if ($existingRunbook) {
            # Protect unrelated runbooks that collide with the configured managed name.
            if (
                [string]$existingRunbook.properties.runbookType -ine 'PowerShell' -or
                [string]$existingRunbook.properties.runtimeEnvironment -ine $Config.RuntimeEnvironmentName -or
                [string]$existingRunbook.properties.description -ne $Config.RunbookDescription
            ) {
                throw "Existing runbook '$($Config.RunbookName)' is incompatible and will not be overwritten."
            }
        }

        # Create or reconcile runbook metadata while preserving governed tags.
        $body = @{
            name       = $Config.RunbookName
            location   = [string]$Context.ResourceGroup.location
            tags       = $Config.Tag
            properties = @{
                description        = $Config.RunbookDescription
                draft              = @{}
                logActivityTrace   = 0
                logProgress        = $false
                logVerbose         = $false
                runbookType        = 'PowerShell'
                runtimeEnvironment = $Config.RuntimeEnvironmentName
            }
        } | ConvertTo-Json -Depth 20 -Compress
        $null = Invoke-AzureRest `
            -Method put `
            -Url $runbookUrl `
            -Body $body `
            -FailureMessage "Unable to create or update runbook '$($Config.RunbookName)'."

        # Upload local PowerShell source as raw draft content through the stable REST endpoint.
        $draftUrl = "$runbookBaseUrl/draft/content?api-version=$($Config.AutomationApiVersion)"
        $null = Invoke-AzureRest `
            -Method put `
            -Url $draftUrl `
            -Body "@$($Config.RunbookPath)" `
            -Header @('Content-Type=text/plain') `
            -FailureMessage "Unable to upload content for runbook '$($Config.RunbookName)'."

        # Publish the validated draft so the linked schedule can execute it.
        $publishUrl = "$runbookBaseUrl/publish?api-version=$($Config.AutomationApiVersion)"
        $null = Invoke-AzureRest `
            -Method post `
            -Url $publishUrl `
            -FailureMessage "Unable to publish runbook '$($Config.RunbookName)'."
        Wait-AutomationRunbookPublished `
            -Config $Config `
            -RunbookUrl $runbookUrl
    }

    function Wait-AutomationRunbookPublished {
        # Poll the runbook until Azure reports the published state.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [string]$RunbookUrl
        )

        for ($attempt = 1; $attempt -le $Config.PollAttempts; $attempt++) {
            # Read publication state after the asynchronous publish request.
            $runbook = Get-AzureRestResource `
                -Url $RunbookUrl `
                -FailureMessage "Unable to poll runbook '$($Config.RunbookName)'."
            if ([string]$runbook.properties.state -eq 'Published') {
                return
            }

            Start-Sleep -Seconds $Config.PollSeconds
        }

        throw "Runbook '$($Config.RunbookName)' did not reach the Published state."
    }

    function Invoke-AutomationScheduleDeployment {
        # Create or safely update the daily DST-aware Automation schedule.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$Context
        )

        $scheduleName = Get-EscapedArmSegment -Value $Config.ScheduleName
        $scheduleUrl = "$(Get-AutomationBaseUrl -Config $Config)/schedules/${scheduleName}?api-version=$($Config.AutomationApiVersion)"
        $existingSchedule = Get-AzureRestResource `
            -Url $scheduleUrl `
            -FailureMessage "Unable to inspect schedule '$($Config.ScheduleName)'."

        if ($existingSchedule -and [string]$existingSchedule.properties.description -ne $Config.ScheduleDescription) {
            # Protect an unrelated schedule that happens to use the configured name.
            throw "Existing schedule '$($Config.ScheduleName)' is incompatible and will not be overwritten."
        }

        # Reconcile the next daily occurrence while preserving the configured local wall-clock time.
        $body = @{
            name       = $Config.ScheduleName
            properties = @{
                description = $Config.ScheduleDescription
                frequency   = 'Day'
                interval    = 1
                startTime   = $Context.NextSchedule.ToString('o')
                timeZone    = $Config.TimeZone
            }
        } | ConvertTo-Json -Depth 20 -Compress
        $null = Invoke-AzureRest `
            -Method put `
            -Url $scheduleUrl `
            -Body $body `
            -FailureMessage "Unable to create or update schedule '$($Config.ScheduleName)'."
    }

    function Invoke-AutomationJobScheduleDeployment {
        # Link the published runbook and daily schedule with immutable job parameters.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$Context
        )

        $jobScheduleUrl = "$(Get-AutomationBaseUrl -Config $Config)/jobSchedules/$($Context.JobScheduleId)?api-version=$($Config.AutomationApiVersion)"
        $existingJobSchedule = Get-AzureRestResource `
            -Url $jobScheduleUrl `
            -FailureMessage "Unable to inspect the runbook and schedule link '$($Context.JobScheduleId)'."

        if ($existingJobSchedule) {
            # Reuse the immutable link only when its runbook, schedule, and parameters match.
            $parametersMatch = (
                [string]$existingJobSchedule.properties.parameters.SubscriptionId -ieq $Config.SubscriptionId -and
                [string]$existingJobSchedule.properties.parameters.ResourceGroupName -ieq $Config.ResourceGroupName -and
                [string]$existingJobSchedule.properties.parameters.ContainerNamePrefix -ceq $Config.ContainerNamePrefix
            )

            if (
                [string]$existingJobSchedule.properties.runbook.name -ine $Config.RunbookName -or
                [string]$existingJobSchedule.properties.schedule.name -ine $Config.ScheduleName -or
                -not $parametersMatch
            ) {
                throw "Existing job-schedule link '$($Context.JobScheduleId)' is incompatible and will not be overwritten."
            }

            return
        }

        $body = @{
            properties = @{
                parameters = @{
                    SubscriptionId      = $Config.SubscriptionId
                    ResourceGroupName   = $Config.ResourceGroupName
                    ContainerNamePrefix = $Config.ContainerNamePrefix
                }
                runbook = @{ name = $Config.RunbookName }
                schedule = @{ name = $Config.ScheduleName }
            }
        } | ConvertTo-Json -Depth 20 -Compress

        # A deterministic job-schedule GUID makes repeated provisioning idempotent.
        $null = Invoke-AzureRest `
            -Method put `
            -Url $jobScheduleUrl `
            -Body $body `
            -FailureMessage "Unable to link runbook '$($Config.RunbookName)' to schedule '$($Config.ScheduleName)'."
    }

    function Invoke-ContainerLifecycleRoleDeployment {
        # Create or reuse the resource-group-scoped ACI read/start/stop custom role.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$Context
        )

        $roleDefinitionResourceId = "/subscriptions/$($Config.SubscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$($Context.RoleDefinitionId)"
        $roleUrl = "https://management.azure.com${roleDefinitionResourceId}?api-version=$($Config.AuthorizationApiVersion)"
        $existingRole = Get-AzureRestResource `
            -Url $roleUrl `
            -FailureMessage "Unable to inspect custom role '$($Context.RoleName)'."
        $requiredAction = @(
            'Microsoft.Resources/subscriptions/resourceGroups/read',
            'Microsoft.ContainerInstance/containerGroups/read',
            'Microsoft.ContainerInstance/containerGroups/start/action',
            'Microsoft.ContainerInstance/containerGroups/stop/action'
        )

        if ($existingRole) {
            # Require exact scope and permissions before reusing a deterministic role definition.
            $existingAction = @($existingRole.properties.permissions[0].actions | Sort-Object)
            $expectedAction = @($requiredAction | Sort-Object)
            $actionDifference = Compare-Object -ReferenceObject $expectedAction -DifferenceObject $existingAction
            $scopeMatches = @($existingRole.properties.assignableScopes) -contains $Context.ResourceGroupId

            if (
                [string]$existingRole.properties.roleName -ne $Context.RoleName -or
                -not $scopeMatches -or
                $actionDifference
            ) {
                throw "Existing custom role ID '$($Context.RoleDefinitionId)' is incompatible and will not be modified."
            }

            return $roleDefinitionResourceId
        }

        # Reject a same-name role with a different ID before creating the deterministic definition.
        $nameCollisionJson = Invoke-AzureCliText `
            -ArgumentList @(
                'role',
                'definition',
                'list',
                '--name',
                $Context.RoleName,
                '--subscription',
                $Config.SubscriptionId,
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage "Unable to check custom role name '$($Context.RoleName)'."
        if (@($nameCollisionJson | ConvertFrom-Json).Count -gt 0) {
            # Avoid adopting or overwriting a tenant custom role owned by another deployment.
            throw "A different custom role named '$($Context.RoleName)' already exists."
        }

        # Create only the four control-plane actions approved for the Automation identity.
        $body = @{
            properties = @{
                roleName         = $Context.RoleName
                description      = 'Lists, starts, and stops ALZ Azure Container Instance groups in one resource group.'
                type             = 'CustomRole'
                permissions      = @(
                    @{
                        actions        = $requiredAction
                        notActions     = @()
                        dataActions    = @()
                        notDataActions = @()
                    }
                )
                assignableScopes = @($Context.ResourceGroupId)
            }
        } | ConvertTo-Json -Depth 20 -Compress
        $null = Invoke-AzureRest `
            -Method put `
            -Url $roleUrl `
            -Body $body `
            -FailureMessage "Unable to create custom role '$($Context.RoleName)'."

        return $roleDefinitionResourceId
    }

    function Invoke-ContainerLifecycleRoleAssignmentDeployment {
        # Assign the custom lifecycle role to the Automation Account managed identity.
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [pscustomobject]$Config,

            [Parameter(Mandatory)]
            [pscustomobject]$Context,

            [Parameter(Mandatory)]
            [string]$PrincipalId,

            [Parameter(Mandatory)]
            [string]$RoleDefinitionResourceId
        )

        # Reuse any exact assignment even if it was created with a different GUID.
        $assignmentJson = Invoke-AzureCliText `
            -ArgumentList @(
                'role',
                'assignment',
                'list',
                '--assignee-object-id',
                $PrincipalId,
                '--scope',
                $Context.ResourceGroupId,
                '--subscription',
                $Config.SubscriptionId,
                '--output',
                'json',
                '--only-show-errors'
            ) `
            -FailureMessage 'Unable to inspect existing managed-identity role assignments.'
        $existingAssignment = @($assignmentJson | ConvertFrom-Json) |
            Where-Object { [string]$_.roleDefinitionId -ieq $RoleDefinitionResourceId } |
            Select-Object -First 1

        if ($existingAssignment) {
            # The required identity, role, and resource-group scope are already linked.
            return
        }

        # Use a stable GUID so partial deployments can safely retry assignment creation.
        $assignmentId = Get-DeterministicGuid `
            -Value "$($Context.ResourceGroupId)|$PrincipalId|$RoleDefinitionResourceId"
        $assignmentUrl = "https://management.azure.com$($Context.ResourceGroupId)/providers/Microsoft.Authorization/roleAssignments/${assignmentId}?api-version=$($Config.AuthorizationApiVersion)"
        $body = @{
            properties = @{
                roleDefinitionId = $RoleDefinitionResourceId
                principalId      = $PrincipalId
                principalType    = 'ServicePrincipal'
            }
        } | ConvertTo-Json -Depth 20 -Compress
        $null = Invoke-AzureRest `
            -Method put `
            -Url $assignmentUrl `
            -Body $body `
            -FailureMessage "Unable to assign custom role '$($Context.RoleName)' to the Automation managed identity."
    }
}
#endregion

#region EXECUTION
# Execute from the script directory and restore the caller's location afterward.
try {
    Push-Location -Path $PSScriptRoot
    & $Main
}
finally {
    Pop-Location
}
#endregion
