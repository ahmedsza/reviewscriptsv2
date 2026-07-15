[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppServiceName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Get-Location).Path,

    [string]$Subscription
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Continue'   # allow the script to keep running after non-terminating errors

function Write-StatusMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    Write-Host ("[{0}] [{1}] {2}" -f $timestamp, $Level, $Message)
}

function Get-SafePropertyValue {
    param(
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Path
    )

    $current = $InputObject
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            return $null
        }

        $property = $current.PSObject.Properties[$segment]
        if (-not $property) {
            return $null
        }

        $current = $property.Value
    }

    return $current
}

function Test-AzureCliPrerequisites {
    try {
        $azCommand = Get-Command -Name az
        if (-not $azCommand) {
            throw 'Azure CLI was not found in PATH.'
        }
    } catch {
        Write-Host '[ERROR] Azure CLI was not found in PATH. Install Azure CLI before running this script.' -ForegroundColor Red
        Write-Warning ('[ERROR] Azure CLI prerequisite check failed: {0}' -f $_)
        Write-Verbose $_.ScriptStackTrace
        throw
    }
}

function Split-AzureResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    $segments = $ResourceId.Trim('/') -split '/'
    $result = [ordered]@{}

    for ($index = 0; $index -lt $segments.Length; $index += 2) {
        $key = $segments[$index]
        $valueIndex = $index + 1

        if ($valueIndex -lt $segments.Length) {
            $result[$key] = $segments[$valueIndex]
        }
    }

    [pscustomobject]$result
}

function Get-CommandText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '\s') {
            '"{0}"' -f $argument.Replace('"', '\"')
        }
        else {
            $argument
        }
    }

    'az {0}' -f ($quoted -join ' ')
}

function Invoke-AzCliCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$Required
    )

    $fullArguments = [System.Collections.Generic.List[string]]::new()
    $fullArguments.AddRange($Arguments)

    if ($Subscription) {
        $fullArguments.Add('--subscription')
        $fullArguments.Add($Subscription)
    }

    $fullArguments.Add('--output')
    $fullArguments.Add('json')
    $fullArguments.Add('--only-show-errors')

    $commandText = Get-CommandText -Arguments $fullArguments.ToArray()
    $started = Get-Date
    Write-StatusMessage -Level 'INFO' -Message ("Collecting {0}" -f $Label)
    $rawItems = & az @fullArguments 2>&1
    $exitCode = $LASTEXITCODE
    $rawOutput = (($rawItems | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $_.ToString()
                }
                else {
                    [string]$_
                }
            }) -join [Environment]::NewLine).Trim()

    $data = $null
    if ($rawOutput) {
        try {
            $data = $rawOutput | ConvertFrom-Json -Depth 100
        }
        catch {
            $data = $rawOutput
        }
    }

    $success = $exitCode -eq 0
    if ($Required -and -not $success) {
        Write-StatusMessage -Level 'ERROR' -Message ("Failed {0} after {1:N1}s" -f $Label, ((Get-Date) - $started).TotalSeconds)
        throw "Required Azure CLI command failed for '$Label': $rawOutput"
    }

    if ($success) {
        Write-StatusMessage -Level 'OK' -Message ("Collected {0} in {1:N1}s" -f $Label, ((Get-Date) - $started).TotalSeconds)
    }
    else {
        Write-StatusMessage -Level 'WARN' -Message ("Could not collect {0} in {1:N1}s" -f $Label, ((Get-Date) - $started).TotalSeconds)
    }

    [pscustomobject]@{
        Label = $Label
        Command = $commandText
        Success = $success
        ExitCode = $exitCode
        ErrorMessage = if ($success) { $null } else { $rawOutput }
        Data = $data
    }
}

function Test-SensitiveName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return $Name -match '(?i)(password|passwd|pwd|secret|token|connectionstring|accountkey|sharedaccesskey|sharedkey|clientsecret|publishingpassword|sas|instrumentationkey)'
}

function Test-SensitiveValue {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value -match '(?i)(password\s*=|pwd\s*=|accountkey\s*=|sharedaccesssignature=|sig=|clientsecret\s*=|endpoint=.*;sharedaccesskey=)' 
}

function Get-RedactedString {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return $Value
    }

    return 'SECRET_FOUND_REDACTED'
}

function Protect-Object {
    param(
        $InputObject,

        [string]$PropertyName = ''
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string]) {
        if (Test-SensitiveName -Name $PropertyName -or Test-SensitiveValue -Value $InputObject) {
            return Get-RedactedString -Value $InputObject
        }

        return $InputObject
    }

    if ($InputObject -is [ValueType]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $copy[$key] = Protect-Object -InputObject $InputObject[$key] -PropertyName ([string]$key)
        }
        return [pscustomobject]$copy
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = foreach ($item in $InputObject) {
            Protect-Object -InputObject $item -PropertyName $PropertyName
        }
        return @($items)
    }

    $properties = @($InputObject.PSObject.Properties)
    if ($properties.Length -eq 0) {
        return $InputObject
    }

    $copy = [ordered]@{}
    foreach ($property in $properties) {
        $copy[$property.Name] = Protect-Object -InputObject $property.Value -PropertyName $property.Name
    }
    [pscustomobject]$copy
}

function ConvertTo-MarkdownText {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", '<br>')
}

function Add-MarkdownLine {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$Builder,

        [AllowNull()]
        [string]$Text = ''
    )

    [void]$Builder.AppendLine($Text)
}

function Add-KeyValueTable {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$Builder,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Values
    )

    Add-MarkdownLine -Builder $Builder -Text '| Property | Value |'
    Add-MarkdownLine -Builder $Builder -Text '| --- | --- |'

    foreach ($entry in $Values.GetEnumerator()) {
        Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} |' -f (ConvertTo-MarkdownText -Value $entry.Key), (ConvertTo-MarkdownText -Value $entry.Value))
    }

    Add-MarkdownLine -Builder $Builder
}

function Add-JsonSection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$Builder,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [int]$HeadingLevel = 2,

        [Parameter(Mandatory = $true)]
        $Result
    )

    $headingPrefix = '#' * $HeadingLevel
    Add-MarkdownLine -Builder $Builder -Text ('{0} {1}' -f $headingPrefix, $Title)
    Add-MarkdownLine -Builder $Builder -Text ('Command: `{0}`' -f $Result.Command)
    Add-MarkdownLine -Builder $Builder

    if (-not $Result.Success) {
        Add-MarkdownLine -Builder $Builder -Text ('Status: failed')
        Add-MarkdownLine -Builder $Builder -Text ('Error: `{0}`' -f (ConvertTo-MarkdownText -Value $Result.ErrorMessage))
        Add-MarkdownLine -Builder $Builder
        return
    }

    if ($null -eq $Result.Data) {
        Add-MarkdownLine -Builder $Builder -Text 'Status: succeeded, but no data was returned.'
        Add-MarkdownLine -Builder $Builder
        return
    }

    $json = Protect-Object -InputObject $Result.Data | ConvertTo-Json -Depth 100
    Add-MarkdownLine -Builder $Builder -Text '```json'
    Add-MarkdownLine -Builder $Builder -Text $json
    Add-MarkdownLine -Builder $Builder -Text '```'
    Add-MarkdownLine -Builder $Builder
}

function Add-CollectionStatusSection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$Builder,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Results
    )

    Add-MarkdownLine -Builder $Builder -Text '## Collection Status'
    Add-MarkdownLine -Builder $Builder -Text '| Section | Success | Exit Code | Notes |'
    Add-MarkdownLine -Builder $Builder -Text '| --- | --- | --- | --- |'

    foreach ($result in $Results) {
        $notes = if ($result.Success) { 'Collected' } else { $result.ErrorMessage }
        Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} | {2} | {3} |' -f (ConvertTo-MarkdownText -Value $result.Label), $result.Success, $result.ExitCode, (ConvertTo-MarkdownText -Value $notes))
    }

    Add-MarkdownLine -Builder $Builder
}

function Assert-ResourceGroupAvailable {
    param(
        [Parameter(Mandatory = $true)]
        $AccountResult,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )

    $resourceGroupResult = Invoke-AzCliCommand -Label 'Resource Group Overview' -Arguments @('group', 'show', '--name', $ResourceGroupName)

    if (-not $resourceGroupResult.Success) {
        $currentSubscriptionName = Get-SafePropertyValue -InputObject $AccountResult.Data -Path @('name')
        $currentSubscriptionId = Get-SafePropertyValue -InputObject $AccountResult.Data -Path @('id')
        $effectiveSubscription = if ($Subscription) { $Subscription } elseif ($currentSubscriptionId) { $currentSubscriptionId } else { '(unknown)' }

        throw (
            "Resource group '{0}' was not found in the current Azure CLI context. Active subscription: {1} ({2}). In Cloud Shell this usually means you are connected to a different subscription. Run 'az account show' and 'az account list --output table', then rerun the script with -Subscription <subscription-id-or-name> or switch first with 'az account set --subscription <subscription-id-or-name>'. Effective subscription for this run: {3}. Original Azure CLI error: {4}" -f
            $ResourceGroupName,
            $currentSubscriptionName,
            $currentSubscriptionId,
            $effectiveSubscription,
            $resourceGroupResult.ErrorMessage
        )
    }

    return $resourceGroupResult
}

Test-AzureCliPrerequisites
Write-StatusMessage -Level 'INFO' -Message ("Starting App Service report for {0} in resource group {1}" -f $AppServiceName, $ResourceGroup)

if (-not (Test-Path -Path $OutputDirectory)) {
    try {
        Write-Host ('[INFO ] Creating output directory {0}...' -f $OutputDirectory) -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        Write-Host '[OK   ] Output directory created.' -ForegroundColor Green
    } catch {
        Write-Host ('[ERROR] Failed to create output directory {0}: {1}' -f $OutputDirectory, $_) -ForegroundColor Red
        Write-Warning ('[ERROR] Failed to create output directory: {0}' -f $_)
        Write-Verbose $_.ScriptStackTrace
    }
}

$results = [System.Collections.Generic.List[object]]::new()

function Add-QueryResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$Required
    )

    $result = Invoke-AzCliCommand -Label $Label -Arguments $Arguments -Required:$Required
    $results.Add($result)
    return $result
}

Write-Host '[INFO ] Collecting Azure account context...' -ForegroundColor Cyan
try {
    $account = Add-QueryResult -Label 'Azure Account' -Arguments @('account', 'show') -Required
    Write-Host '[OK   ] Azure account context collected.' -ForegroundColor Green
} catch {
    Write-Host ('[ERROR] Failed to collect Azure account context: {0}' -f $_) -ForegroundColor Red
    Write-Warning ('[ERROR] Failed to collect Azure account context: {0}' -f $_)
    Write-Verbose $_.ScriptStackTrace
    throw
}

Write-Host ('[INFO ] Validating resource group {0}...' -f $ResourceGroup) -ForegroundColor Cyan
try {
    $resourceGroupResult = Assert-ResourceGroupAvailable -AccountResult $account -ResourceGroupName $ResourceGroup
    $results.Add($resourceGroupResult)
    Write-Host ('[OK   ] Resource group {0} validated.' -f $ResourceGroup) -ForegroundColor Green
} catch {
    Write-Host ('[ERROR] Resource group validation failed: {0}' -f $_) -ForegroundColor Red
    Write-Warning ('[ERROR] Resource group validation failed: {0}' -f $_)
    Write-Verbose $_.ScriptStackTrace
    throw
}

Write-Host ('[INFO ] Collecting Web App overview for {0}...' -f $AppServiceName) -ForegroundColor Cyan
try {
    $webApp = Add-QueryResult -Label 'Web App Overview' -Arguments @('webapp', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup) -Required
    Write-Host '[OK   ] Web App overview collected.' -ForegroundColor Green
} catch {
    Write-Host ('[ERROR] Failed to collect Web App overview: {0}' -f $_) -ForegroundColor Red
    Write-Warning ('[ERROR] Failed to collect Web App overview: {0}' -f $_)
    Write-Verbose $_.ScriptStackTrace
    throw
}

$webAppId = $webApp.Data.id
$planId = if ($webApp.Data.PSObject.Properties['appServicePlanId']) {
    $webApp.Data.appServicePlanId
}
elseif ($webApp.Data.PSObject.Properties['serverFarmId']) {
    $webApp.Data.serverFarmId
}
else {
    $null
}
$siteConfig = Add-QueryResult -Label 'Web App Site Config' -Arguments @('webapp', 'config', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$appSettings = Add-QueryResult -Label 'Web App App Settings' -Arguments @('webapp', 'config', 'appsettings', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$connectionStrings = Add-QueryResult -Label 'Web App Connection Strings' -Arguments @('webapp', 'config', 'connection-string', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$accessRestrictions = Add-QueryResult -Label 'Web App Access Restrictions' -Arguments @('webapp', 'config', 'access-restriction', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$authSettings = Add-QueryResult -Label 'Web App Auth Settings' -Arguments @('webapp', 'auth', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$identity = Add-QueryResult -Label 'Web App Managed Identity' -Arguments @('webapp', 'identity', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$logging = Add-QueryResult -Label 'Web App Logging Configuration' -Arguments @('webapp', 'log', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$backupSchedule = Add-QueryResult -Label 'Web App Backup Schedule' -Arguments @('webapp', 'config', 'backup', 'show', '--webapp-name', $AppServiceName, '--resource-group', $ResourceGroup)
$backupHistory = Add-QueryResult -Label 'Web App Backup History' -Arguments @('webapp', 'config', 'backup', 'list', '--webapp-name', $AppServiceName, '--resource-group', $ResourceGroup)
$hostnameBindings = Add-QueryResult -Label 'Web App Hostname Bindings' -Arguments @('webapp', 'config', 'hostname', 'list', '--webapp-name', $AppServiceName, '--resource-group', $ResourceGroup)
$externalIp = Add-QueryResult -Label 'Web App External IP' -Arguments @('webapp', 'config', 'hostname', 'get-external-ip', '--webapp-name', $AppServiceName, '--resource-group', $ResourceGroup)
$sslCertificates = Add-QueryResult -Label 'Resource Group SSL Certificates' -Arguments @('webapp', 'config', 'ssl', 'list', '--resource-group', $ResourceGroup)
$storageAccounts = Add-QueryResult -Label 'Web App Storage Accounts' -Arguments @('webapp', 'config', 'storage-account', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$deploymentSource = Add-QueryResult -Label 'Web App Deployment Source' -Arguments @('webapp', 'deployment', 'source', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$publishingCredentials = Add-QueryResult -Label 'Web App Publishing Credentials' -Arguments @('webapp', 'deployment', 'list-publishing-credentials', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$publishingProfiles = Add-QueryResult -Label 'Web App Publishing Profiles' -Arguments @('webapp', 'deployment', 'list-publishing-profiles', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$instances = Add-QueryResult -Label 'Web App Instances' -Arguments @('webapp', 'list-instances', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$vnetIntegration = Add-QueryResult -Label 'Web App VNet Integration' -Arguments @('webapp', 'vnet-integration', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$slots = Add-QueryResult -Label 'Web App Deployment Slots' -Arguments @('webapp', 'deployment', 'slot', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$resourceView = Add-QueryResult -Label 'Web App ARM Resource' -Arguments @('resource', 'show', '--ids', $webAppId)
$webAppDiagnostics = Add-QueryResult -Label 'Web App Diagnostic Settings' -Arguments @('monitor', 'diagnostic-settings', 'list', '--resource', $webAppId)
$webAppDiagnosticCategories = Add-QueryResult -Label 'Web App Diagnostic Categories' -Arguments @('monitor', 'diagnostic-settings', 'categories', 'list', '--resource', $webAppId)

$plan = $null
$planIdentity = $null
$planResourceView = $null
$planDiagnostics = $null
$planDiagnosticCategories = $null

if ($planId) {
    try {
        Write-Host '[INFO ] Collecting App Service Plan details...' -ForegroundColor Cyan
        $planParts = Split-AzureResourceId -ResourceId $planId
        $planName = $planParts.serverfarms
        $planResourceGroup = if ($planParts.resourceGroups) { $planParts.resourceGroups } else { $ResourceGroup }

        $plan = Add-QueryResult -Label 'App Service Plan Overview' -Arguments @('appservice', 'plan', 'show', '--name', $planName, '--resource-group', $planResourceGroup)
        $planIdentity = Add-QueryResult -Label 'App Service Plan Identity' -Arguments @('appservice', 'plan', 'identity', 'show', '--name', $planName, '--resource-group', $planResourceGroup)
        $planResourceView = Add-QueryResult -Label 'App Service Plan ARM Resource' -Arguments @('resource', 'show', '--ids', $planId)
        $planDiagnostics = Add-QueryResult -Label 'App Service Plan Diagnostic Settings' -Arguments @('monitor', 'diagnostic-settings', 'list', '--resource', $planId)
        $planDiagnosticCategories = Add-QueryResult -Label 'App Service Plan Diagnostic Categories' -Arguments @('monitor', 'diagnostic-settings', 'categories', 'list', '--resource', $planId)
        Write-Host '[OK   ] App Service Plan details collected.' -ForegroundColor Green
    } catch {
        Write-Host ('[WARN ] Could not collect some App Service Plan details: {0}' -f $_) -ForegroundColor Yellow
        Write-Warning ('[WARN ] App Service Plan collection partially failed: {0}' -f $_)
        Write-Verbose $_.ScriptStackTrace
    }
}

$slotDetails = [System.Collections.Generic.List[object]]::new()
if ($slots.Success -and $slots.Data) {
    foreach ($slot in $slots.Data) {
        if (-not $slot.name) {
            continue
        }

        $slotName = [string]$slot.name
        if ($slotName.Contains('/')) {
            $slotName = ($slotName -split '/')[-1]
        }

        try {
            Write-Host (('[INFO ] Collecting details for slot {0}...' -f $slotName)) -ForegroundColor Cyan
            $slotOverview = Add-QueryResult -Label ("Slot Overview: {0}" -f $slotName) -Arguments @('webapp', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup, '--slot', $slotName)
            $slotConfig = Add-QueryResult -Label ("Slot Config: {0}" -f $slotName) -Arguments @('webapp', 'config', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup, '--slot', $slotName)
            $slotAppSettings = Add-QueryResult -Label ("Slot App Settings: {0}" -f $slotName) -Arguments @('webapp', 'config', 'appsettings', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup, '--slot', $slotName)
            $slotConnectionStrings = Add-QueryResult -Label ("Slot Connection Strings: {0}" -f $slotName) -Arguments @('webapp', 'config', 'connection-string', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup, '--slot', $slotName)
            $slotAuth = Add-QueryResult -Label ("Slot Auth Settings: {0}" -f $slotName) -Arguments @('webapp', 'auth', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup, '--slot', $slotName)
            $slotIdentity = Add-QueryResult -Label ("Slot Managed Identity: {0}" -f $slotName) -Arguments @('webapp', 'identity', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup, '--slot', $slotName)

            $slotDetails.Add([pscustomobject]@{
                    Name = $slotName
                    Overview = $slotOverview
                    Config = $slotConfig
                    AppSettings = $slotAppSettings
                    ConnectionStrings = $slotConnectionStrings
                    Auth = $slotAuth
                    Identity = $slotIdentity
                })
            Write-Host (('[OK   ] Slot {0} details collected.' -f $slotName)) -ForegroundColor Green
        } catch {
            Write-Host (('[ERROR] Failed to collect details for slot {0}: {1}' -f $slotName, $_)) -ForegroundColor Red
            Write-Warning ('[ERROR] Slot {0} collection failed: {1}' -f $slotName, $_)
            Write-Verbose $_.ScriptStackTrace
        }
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeAppName = ($AppServiceName -replace '[^A-Za-z0-9._-]', '-')
$reportPath = Join-Path -Path $OutputDirectory -ChildPath ("AppServiceReport-{0}-{1}.md" -f $safeAppName, $timestamp)

$builder = [System.Text.StringBuilder]::new()

Add-MarkdownLine -Builder $builder -Text ('# App Service Report: {0}' -f $AppServiceName)
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text ('Generated: {0}' -f (Get-Date).ToString('u'))
Add-MarkdownLine -Builder $builder -Text ('Resource Group: `{0}`' -f $ResourceGroup)
if ($Subscription) {
    Add-MarkdownLine -Builder $builder -Text ('Requested Subscription: `{0}`' -f $Subscription)
}
Add-MarkdownLine -Builder $builder -Text 'Sensitive values in settings, connection strings, publishing data, and similar fields are redacted.'
Add-MarkdownLine -Builder $builder

$summary = [ordered]@{
    'Subscription Name' = $account.Data.name
    'Subscription Id' = $account.Data.id
    'Tenant Id' = $account.Data.tenantId
    'Resource Group Location' = $resourceGroupResult.Data.location
    'App Service Name' = $webApp.Data.name
    'Kind' = $webApp.Data.kind
    'Location' = $webApp.Data.location
    'State' = $webApp.Data.state
    'Default Hostname' = $webApp.Data.defaultHostName
    'HTTPS Only' = $webApp.Data.httpsOnly
    'Client Affinity Enabled' = $webApp.Data.clientAffinityEnabled
    'Enabled' = $webApp.Data.enabled
    'Outbound IP Addresses' = $webApp.Data.outboundIpAddresses
    'Possible Outbound IP Addresses' = $webApp.Data.possibleOutboundIpAddresses
    'App Service Plan Id' = $planId
}

if ($plan -and $plan.Success) {
    $summary['Plan Name'] = $plan.Data.name
    $summary['Plan SKU'] = if ($plan.Data.sku) { '{0}/{1}' -f $plan.Data.sku.tier, $plan.Data.sku.name } else { $null }
    $summary['Plan Worker Count'] = Get-SafePropertyValue -InputObject $plan.Data -Path @('properties', 'numberOfWorkers')
    $summary['Plan Current Worker Count'] = Get-SafePropertyValue -InputObject $plan.Data -Path @('properties', 'currentNumberOfWorkers')
    $summary['Plan Reserved'] = Get-SafePropertyValue -InputObject $plan.Data -Path @('properties', 'reserved')
    $summary['Plan Zone Redundant'] = Get-SafePropertyValue -InputObject $plan.Data -Path @('properties', 'zoneRedundant')
}

Add-MarkdownLine -Builder $builder -Text '## Summary'
Add-KeyValueTable -Builder $builder -Values $summary

Add-JsonSection -Builder $builder -Title 'Azure Account Context' -Result $account
Add-JsonSection -Builder $builder -Title 'Resource Group Overview' -Result $resourceGroupResult
Add-JsonSection -Builder $builder -Title 'Web App Overview' -Result $webApp
Add-JsonSection -Builder $builder -Title 'Web App Site Config' -Result $siteConfig
Add-JsonSection -Builder $builder -Title 'Web App App Settings' -Result $appSettings
Add-JsonSection -Builder $builder -Title 'Web App Connection Strings' -Result $connectionStrings
Add-JsonSection -Builder $builder -Title 'Web App Access Restrictions' -Result $accessRestrictions
Add-JsonSection -Builder $builder -Title 'Web App Auth Settings' -Result $authSettings
Add-JsonSection -Builder $builder -Title 'Web App Managed Identity' -Result $identity
Add-JsonSection -Builder $builder -Title 'Web App Logging Configuration' -Result $logging
Add-JsonSection -Builder $builder -Title 'Web App Backup Schedule' -Result $backupSchedule
Add-JsonSection -Builder $builder -Title 'Web App Backup History' -Result $backupHistory
Add-JsonSection -Builder $builder -Title 'Web App Hostname Bindings' -Result $hostnameBindings
Add-JsonSection -Builder $builder -Title 'Web App External IP' -Result $externalIp
Add-JsonSection -Builder $builder -Title 'Resource Group SSL Certificates' -Result $sslCertificates
Add-JsonSection -Builder $builder -Title 'Web App Storage Accounts' -Result $storageAccounts
Add-JsonSection -Builder $builder -Title 'Web App Deployment Source' -Result $deploymentSource
Add-JsonSection -Builder $builder -Title 'Web App Publishing Credentials' -Result $publishingCredentials
Add-JsonSection -Builder $builder -Title 'Web App Publishing Profiles' -Result $publishingProfiles
Add-JsonSection -Builder $builder -Title 'Web App Instances' -Result $instances
Add-JsonSection -Builder $builder -Title 'Web App VNet Integration' -Result $vnetIntegration
Add-JsonSection -Builder $builder -Title 'Web App Deployment Slots' -Result $slots
Add-JsonSection -Builder $builder -Title 'Web App ARM Resource' -Result $resourceView
Add-JsonSection -Builder $builder -Title 'Web App Diagnostic Settings' -Result $webAppDiagnostics
Add-JsonSection -Builder $builder -Title 'Web App Diagnostic Categories' -Result $webAppDiagnosticCategories

if ($plan) {
    Add-JsonSection -Builder $builder -Title 'App Service Plan Overview' -Result $plan
    Add-JsonSection -Builder $builder -Title 'App Service Plan Identity' -Result $planIdentity
    Add-JsonSection -Builder $builder -Title 'App Service Plan ARM Resource' -Result $planResourceView
    Add-JsonSection -Builder $builder -Title 'App Service Plan Diagnostic Settings' -Result $planDiagnostics
    Add-JsonSection -Builder $builder -Title 'App Service Plan Diagnostic Categories' -Result $planDiagnosticCategories
}

if ($slotDetails.Count -gt 0) {
    Add-MarkdownLine -Builder $builder -Text '## Slot Details'
    Add-MarkdownLine -Builder $builder

    foreach ($slotDetail in $slotDetails) {
        Add-MarkdownLine -Builder $builder -Text ('### Slot: {0}' -f $slotDetail.Name)
        Add-MarkdownLine -Builder $builder
        Add-JsonSection -Builder $builder -Title ('Slot Overview: {0}' -f $slotDetail.Name) -HeadingLevel 4 -Result $slotDetail.Overview
        Add-JsonSection -Builder $builder -Title ('Slot Config: {0}' -f $slotDetail.Name) -HeadingLevel 4 -Result $slotDetail.Config
        Add-JsonSection -Builder $builder -Title ('Slot App Settings: {0}' -f $slotDetail.Name) -HeadingLevel 4 -Result $slotDetail.AppSettings
        Add-JsonSection -Builder $builder -Title ('Slot Connection Strings: {0}' -f $slotDetail.Name) -HeadingLevel 4 -Result $slotDetail.ConnectionStrings
        Add-JsonSection -Builder $builder -Title ('Slot Auth Settings: {0}' -f $slotDetail.Name) -HeadingLevel 4 -Result $slotDetail.Auth
        Add-JsonSection -Builder $builder -Title ('Slot Managed Identity: {0}' -f $slotDetail.Name) -HeadingLevel 4 -Result $slotDetail.Identity
    }
}

Add-CollectionStatusSection -Builder $builder -Results $results

try {
    Write-Host ('[INFO ] Writing report to {0}...' -f $reportPath) -ForegroundColor Cyan
    [System.IO.File]::WriteAllText($reportPath, $builder.ToString(), [System.Text.Encoding]::UTF8)
    Write-StatusMessage -Level 'OK' -Message ("Report written to {0}" -f $reportPath)
    Write-Host ('[OK   ] Report written to {0}' -f $reportPath) -ForegroundColor Green
} catch {
    Write-Host ('[ERROR] Failed to write report to {0}: {1}' -f $reportPath, $_) -ForegroundColor Red
    Write-Warning ('[ERROR] Failed to write report file: {0}' -f $_)
    Write-Verbose $_.ScriptStackTrace
}