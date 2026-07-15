[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppServiceName,

    [Parameter(Mandatory = $true)]
    [string]$MySqlServerName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Get-Location).Path,

    [string]$Subscription,

    # Number of days of metric history to pull for CPU/memory rightsizing checks.
    [int]$MetricLookbackDays = 30,

    # Optional: Azure Front Door resource group if different from $ResourceGroup.
    [string]$AfdResourceGroup,

    # Skip the slow subscription-wide reservations API call (enabled by default).
    [bool]$SkipReservations = $true
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helper utilities  (shared pattern across all review scripts)
# ---------------------------------------------------------------------------
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
        [Parameter(Mandatory = $true)][string[]]$Path
    )
    $current = $InputObject
    foreach ($segment in $Path) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$segment]
        if (-not $property) { return $null }
        $current = $property.Value
    }
    return $current
}

function Test-AzureCliPrerequisites {
    if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI was not found in PATH. Install Azure CLI before running this script.'
    }
}

function Get-CommandText {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '\s') { '"{0}"' -f $argument.Replace('"', '\"') } else { $argument }
    }
    'az {0}' -f ($quoted -join ' ')
}

function Invoke-AzCliCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][AllowNull()][object[]]$Arguments,
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
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
            }) -join [Environment]::NewLine).Trim()

    $data = $null
    if ($rawOutput) {
        try { $data = $rawOutput | ConvertFrom-Json -Depth 100 }
        catch { $data = $rawOutput }
    }

    $success = $exitCode -eq 0
    if ($Required -and -not $success) {
        Write-StatusMessage -Level 'ERROR' -Message ("Failed {0} after {1:N1}s" -f $Label, ((Get-Date) - $started).TotalSeconds)
        Write-Error ("[CRITICAL] Required data collection failed for '{0}'. Findings for this area will be marked UNKNOWN. Command: {1}. Error: {2}" -f $Label, $commandText, $rawOutput)
    }
    if ($success) {
        Write-StatusMessage -Level 'OK' -Message ("Collected {0} in {1:N1}s" -f $Label, ((Get-Date) - $started).TotalSeconds)
    } else {
        Write-StatusMessage -Level 'WARN' -Message ("Could not collect {0} in {1:N1}s" -f $Label, ((Get-Date) - $started).TotalSeconds)
    }

    [pscustomobject]@{
        Label        = $Label
        Command      = $commandText
        Success      = $success
        ExitCode     = $exitCode
        ErrorMessage = if ($success) { $null } else { $rawOutput }
        Data         = $data
    }
}

function Test-SensitiveName {
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name -match '(?i)(password|passwd|pwd|secret|token|connectionstring|accountkey|sharedaccesskey|sharedkey|clientsecret|publishingpassword|sas|instrumentationkey)'
}

function Test-SensitiveValue {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value -match '(?i)(password\s*=|pwd\s*=|accountkey\s*=|sharedaccesssignature=|sig=|clientsecret\s*=|endpoint=.*;sharedaccesskey=)'
}

function Protect-Object {
    param($InputObject, [string]$PropertyName = '')
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) {
        if (Test-SensitiveName -Name $PropertyName -or Test-SensitiveValue -Value $InputObject) { return 'SECRET_FOUND_REDACTED' }
        return $InputObject
    }
    if ($InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $InputObject.Keys) { $copy[$key] = Protect-Object -InputObject $InputObject[$key] -PropertyName ([string]$key) }
        return [pscustomobject]$copy
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = foreach ($item in $InputObject) { Protect-Object -InputObject $item -PropertyName $PropertyName }
        return @($items)
    }
    $properties = @($InputObject.PSObject.Properties)
    if ($properties.Length -eq 0) { return $InputObject }
    $copy = [ordered]@{}
    foreach ($property in $properties) { $copy[$property.Name] = Protect-Object -InputObject $property.Value -PropertyName $property.Name }
    [pscustomobject]$copy
}

# ---------------------------------------------------------------------------
# Markdown helpers
# ---------------------------------------------------------------------------
function ConvertTo-MarkdownText {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", '<br>')
}

function Add-MarkdownLine {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [AllowNull()][string]$Text = ''
    )
    [void]$Builder.AppendLine($Text)
}

function Add-KeyValueTable {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Values
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
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory = $true)][string]$Title,
        [int]$HeadingLevel = 2,
        [Parameter(Mandatory = $true)]$Result
    )
    $headingPrefix = '#' * $HeadingLevel
    Add-MarkdownLine -Builder $Builder -Text ('{0} {1}' -f $headingPrefix, $Title)
    Add-MarkdownLine -Builder $Builder -Text ('Command: `{0}`' -f $Result.Command)
    Add-MarkdownLine -Builder $Builder
    if (-not $Result.Success) {
        Add-MarkdownLine -Builder $Builder -Text 'Status: failed'
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
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Results
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
        [Parameter(Mandatory = $true)]$AccountResult,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName
    )
    $resourceGroupResult = Invoke-AzCliCommand -Label 'Resource Group Overview' -Arguments @('group', 'show', '--name', $ResourceGroupName)
    if (-not $resourceGroupResult.Success) {
        $subName  = Get-SafePropertyValue -InputObject $AccountResult.Data -Path @('name')
        $subId    = Get-SafePropertyValue -InputObject $AccountResult.Data -Path @('id')
        $effective = if ($Subscription) { $Subscription } elseif ($subId) { $subId } else { '(unknown)' }
        Write-Error ("[CRITICAL] Resource group '{0}' was not found. Active subscription: {1} ({2}). Effective: {3}. Script will continue but all resource data will be unavailable. Error: {4}" -f $ResourceGroupName, $subName, $subId, $effective, $resourceGroupResult.ErrorMessage)
    }
    return $resourceGroupResult
}

# ---------------------------------------------------------------------------
# Cost Assessment helpers
# ---------------------------------------------------------------------------
function New-CostFinding {
    param(
        [Parameter(Mandatory = $true)][string]$CoArea,
        [Parameter(Mandatory = $true)][string]$SubArea,
        [Parameter(Mandatory = $true)][string]$Question,
        [Parameter(Mandatory = $true)][int]$Priority,
        [ValidateSet('PASS', 'FAIL', 'WARN', 'UNKNOWN', 'MANUAL')][string]$Status = 'UNKNOWN',
        [string]$Notes = ''
    )
    [pscustomobject]@{
        CoArea   = $CoArea
        SubArea  = $SubArea
        Question = $Question
        Priority = $Priority
        Status   = $Status
        Notes    = $Notes
    }
}

function Add-CostAssessmentSection {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Findings
    )

    $passCount    = @($Findings | Where-Object { $_.Status -eq 'PASS' }).Count
    $failCount    = @($Findings | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warnCount    = @($Findings | Where-Object { $_.Status -eq 'WARN' }).Count
    $unknownCount = @($Findings | Where-Object { $_.Status -eq 'UNKNOWN' }).Count
    $manualCount  = @($Findings | Where-Object { $_.Status -eq 'MANUAL' }).Count

    Add-MarkdownLine -Builder $Builder -Text '## Cost Optimisation Assessment'
    Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text ('**PASS:** {0} | **FAIL:** {1} | **WARN:** {2} | **UNKNOWN:** {3} | **MANUAL REVIEW REQUIRED:** {4}' -f $passCount, $failCount, $warnCount, $unknownCount, $manualCount)
    Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text '> Status key: **PASS** = confirmed optimised  |  **FAIL** = confirmed gap  |  **WARN** = partially configured or potential issue  |  **UNKNOWN** = data unavailable  |  **MANUAL** = cannot be determined via az CLI alone'
    Add-MarkdownLine -Builder $Builder

    $subAreas = $Findings | Select-Object -ExpandProperty SubArea | Select-Object -Unique
    foreach ($subArea in $subAreas) {
        $group   = $Findings | Where-Object { $_.SubArea -eq $subArea }
        $coArea  = ($group | Select-Object -First 1).CoArea

        Add-MarkdownLine -Builder $Builder -Text ('### {0} — {1}' -f $coArea, $subArea)
        Add-MarkdownLine -Builder $Builder
        Add-MarkdownLine -Builder $Builder -Text '| Priority | Status | Question | Notes |'
        Add-MarkdownLine -Builder $Builder -Text '| --- | --- | --- | --- |'

        foreach ($finding in $group) {
            $badge = switch ($finding.Status) {
                'PASS'    { '✅ PASS' }
                'FAIL'    { '❌ FAIL' }
                'WARN'    { '⚠️ WARN' }
                'UNKNOWN' { '❓ UNKNOWN' }
                'MANUAL'  { '🔍 MANUAL' }
            }
            Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} | {2} | {3} |' -f $finding.Priority, $badge, (ConvertTo-MarkdownText -Value $finding.Question), (ConvertTo-MarkdownText -Value $finding.Notes))
        }
        Add-MarkdownLine -Builder $Builder
    }
}

# ---------------------------------------------------------------------------
# Script entry point
# ---------------------------------------------------------------------------
Test-AzureCliPrerequisites

trap {
    Write-StatusMessage -Level 'WARN' -Message ("Unexpected non-fatal error: {0}. Continuing with the next Cost Optimisation action." -f $_.Exception.Message)
    continue
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$results = [System.Collections.Generic.List[object]]::new()

function New-UnavailableResult {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][object[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $argumentText = (($Arguments | ForEach-Object { if ($null -eq $_ -or [string]::IsNullOrWhiteSpace([string]$_)) { '<missing>' } else { [string]$_ } }) -join ' ').Trim()
    $commandText = if ($argumentText) { 'az {0}' -f $argumentText } else { 'not run' }
    Write-StatusMessage -Level 'WARN' -Message ("{0}: {1}" -f $Label, $Message)
    [pscustomobject]@{ Label = $Label; Command = $commandText; Success = $false; ExitCode = $null; ErrorMessage = $Message; Data = $null }
}

function Add-QueryResult {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Required
    )
    try {
        $result = Invoke-AzCliCommand -Label $Label -Arguments $Arguments -Required:$Required
    } catch {
        $result = New-UnavailableResult -Label $Label -Arguments $Arguments -Message ("Could not collect this information. {0}" -f $_.Exception.Message)
    }
    $results.Add($result)
    return $result
}

function Add-QueryResultWhenValuePresent {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][AllowNull()][object[]]$Arguments,
        [AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$RequiredValueName
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $result = New-UnavailableResult -Label $Label -Arguments $Arguments -Message ("Could not find {0}; {1} was not run." -f $RequiredValueName, $Label)
        $results.Add($result)
        return $result
    }
    return Add-QueryResult -Label $Label -Arguments $Arguments
}

Write-StatusMessage -Level 'INFO' -Message ('Starting cost optimisation review for App Service [{0}] and MySQL [{1}] in resource group [{2}]' -f $AppServiceName, $MySqlServerName, $ResourceGroup)

$metricStartTime = (Get-Date).AddDays(-$MetricLookbackDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
$metricEndTime   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')

# ---------------------------------------------------------------------------
# SECTION 1 — Account and resource group
# ---------------------------------------------------------------------------
$account             = Add-QueryResult -Label 'Azure Account'         -Arguments @('account', 'show') -Required
$resourceGroupResult = Assert-ResourceGroupAvailable -AccountResult $account -ResourceGroupName $ResourceGroup
$results.Add($resourceGroupResult)

# ---------------------------------------------------------------------------
# SECTION 2 — App Service data
# ---------------------------------------------------------------------------
$webApp             = Add-QueryResult -Label 'App Service Overview'            -Arguments @('webapp', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup) -Required
$webAppId           = Get-SafePropertyValue -InputObject $webApp.Data -Path @('id')
$planId             = Get-SafePropertyValue -InputObject $webApp.Data -Path @('serverFarmId')
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('appServicePlanId') }
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('properties', 'serverFarmId') }
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('properties', 'appServicePlanId') }
if (-not $webAppId) { Write-StatusMessage -Level 'WARN' -Message 'Could not find App Service resource ID. Dependent App Service metric and diagnostic data will be marked unavailable.' }
if (-not $planId) { Write-StatusMessage -Level 'WARN' -Message 'Could not find App Service plan ID. Plan and autoscale details will be marked unavailable.' }

$appSettings        = Add-QueryResult -Label 'App Service App Settings'        -Arguments @('webapp', 'config', 'appsettings', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$siteConfig         = Add-QueryResult -Label 'App Service Site Config'         -Arguments @('webapp', 'config', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$slots              = Add-QueryResult -Label 'App Service Deployment Slots'    -Arguments @('webapp', 'deployment', 'slot', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$hostnameBindings   = Add-QueryResult -Label 'App Service Hostname Bindings'   -Arguments @('webapp', 'config', 'hostname', 'list', '--webapp-name', $AppServiceName, '--resource-group', $ResourceGroup)
$sslCertificates    = Add-QueryResult -Label 'App Service SSL Certificates'    -Arguments @('webapp', 'config', 'ssl', 'list', '--resource-group', $ResourceGroup)
$allWebApps         = Add-QueryResult -Label 'All Web Apps in Resource Group'  -Arguments @('webapp', 'list', '--resource-group', $ResourceGroup)

# App Service Plan
$plan         = $null
$allPlansInRg = $null
$autoscaleSettings = $null
if ($planId) {
    $planParts = $planId.Trim('/') -split '/'
    $planName  = $null; $planRg = $ResourceGroup
    for ($i = 0; $i -lt $planParts.Length; $i += 2) {
        if ($planParts[$i] -eq 'serverfarms'   -and ($i + 1) -lt $planParts.Length) { $planName = $planParts[$i + 1] }
        if ($planParts[$i] -eq 'resourceGroups' -and ($i + 1) -lt $planParts.Length) { $planRg   = $planParts[$i + 1] }
    }
    if ($planName) {
        $plan            = Add-QueryResult -Label 'App Service Plan Overview'          -Arguments @('appservice', 'plan', 'show', '--name', $planName, '--resource-group', $planRg)
        $allPlansInRg    = Add-QueryResult -Label 'All App Service Plans in Resource Group' -Arguments @('appservice', 'plan', 'list', '--resource-group', $ResourceGroup)
        $autoscaleSettings = Add-QueryResult -Label 'App Service Autoscale Settings'  -Arguments @('monitor', 'autoscale', 'list', '--resource-group', $ResourceGroup)
    }
}

# App Service metrics (CPU and memory — for rightsizing)
$appServiceCpuMetrics = Add-QueryResultWhenValuePresent -Label 'App Service CPU Metrics' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @(
    'monitor', 'metrics', 'list',
    '--resource', $webAppId,
    '--metric', 'CpuPercentage',
    '--interval', 'PT1H',
    '--aggregation', 'Average',
    '--start-time', $metricStartTime,
    '--end-time', $metricEndTime
)

$appServiceMemoryMetrics = Add-QueryResultWhenValuePresent -Label 'App Service Memory Metrics' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @(
    'monitor', 'metrics', 'list',
    '--resource', $webAppId,
    '--metric', 'MemoryWorkingSet',
    '--interval', 'PT1H',
    '--aggregation', 'Average',
    '--start-time', $metricStartTime,
    '--end-time', $metricEndTime
)

# ---------------------------------------------------------------------------
# SECTION 3 — MySQL data
# ---------------------------------------------------------------------------
$mysqlServer        = Add-QueryResult -Label 'MySQL Flexible Server Overview'   -Arguments @('mysql', 'flexible-server', 'show', '--name', $MySqlServerName, '--resource-group', $ResourceGroup) -Required
$mysqlServerId      = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('id')
if (-not $mysqlServerId) { Write-StatusMessage -Level 'WARN' -Message 'Could not find MySQL Flexible Server resource ID. Dependent MySQL metric data will be marked unavailable.' }

$mysqlBackups       = Add-QueryResult -Label 'MySQL Flexible Server Backups'    -Arguments @('mysql', 'flexible-server', 'backup', 'list', '--name', $MySqlServerName, '--resource-group', $ResourceGroup)
$mysqlReplicas      = Add-QueryResult -Label 'MySQL Flexible Server Replicas'   -Arguments @('mysql', 'flexible-server', 'replica', 'list', '--name', $MySqlServerName, '--resource-group', $ResourceGroup)
$allMysqlServers    = Add-QueryResult -Label 'All MySQL Flexible Servers in Resource Group' -Arguments @('mysql', 'flexible-server', 'list', '--resource-group', $ResourceGroup)

# MySQL parameters relevant to cost
$paramSlowQueryLog      = Add-QueryResult -Label 'MySQL Parameter: slow_query_log'       -Arguments @('mysql', 'flexible-server', 'parameter', 'show', '--server-name', $MySqlServerName, '--resource-group', $ResourceGroup, '--name', 'slow_query_log')
$paramLongQueryTime     = Add-QueryResult -Label 'MySQL Parameter: long_query_time'      -Arguments @('mysql', 'flexible-server', 'parameter', 'show', '--server-name', $MySqlServerName, '--resource-group', $ResourceGroup, '--name', 'long_query_time')
$paramMaxConnections    = Add-QueryResult -Label 'MySQL Parameter: max_connections'      -Arguments @('mysql', 'flexible-server', 'parameter', 'show', '--server-name', $MySqlServerName, '--resource-group', $ResourceGroup, '--name', 'max_connections')
$paramInnodbBufferPool  = Add-QueryResult -Label 'MySQL Parameter: innodb_buffer_pool_size' -Arguments @('mysql', 'flexible-server', 'parameter', 'show', '--server-name', $MySqlServerName, '--resource-group', $ResourceGroup, '--name', 'innodb_buffer_pool_size')

# MySQL metrics (CPU, memory, I/O — for rightsizing)
$mysqlCpuMetrics     = Add-QueryResultWhenValuePresent -Label 'MySQL CPU Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @(
    'monitor', 'metrics', 'list',
    '--resource', $mysqlServerId,
    '--metric', 'cpu_percent',
    '--interval', 'PT1H',
    '--aggregation', 'Average',
    '--start-time', $metricStartTime,
    '--end-time', $metricEndTime
)

$mysqlMemoryMetrics  = Add-QueryResultWhenValuePresent -Label 'MySQL Memory Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @(
    'monitor', 'metrics', 'list',
    '--resource', $mysqlServerId,
    '--metric', 'memory_percent',
    '--interval', 'PT1H',
    '--aggregation', 'Average',
    '--start-time', $metricStartTime,
    '--end-time', $metricEndTime
)

$mysqlIoMetrics      = Add-QueryResultWhenValuePresent -Label 'MySQL IO Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @(
    'monitor', 'metrics', 'list',
    '--resource', $mysqlServerId,
    '--metric', 'io_consumption_percent',
    '--interval', 'PT1H',
    '--aggregation', 'Average',
    '--start-time', $metricStartTime,
    '--end-time', $metricEndTime
)

$mysqlStorageMetrics = Add-QueryResultWhenValuePresent -Label 'MySQL Storage Used Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @(
    'monitor', 'metrics', 'list',
    '--resource', $mysqlServerId,
    '--metric', 'storage_used',
    '--interval', 'PT1H',
    '--aggregation', 'Maximum',
    '--start-time', $metricStartTime,
    '--end-time', $metricEndTime
)

# ---------------------------------------------------------------------------
# SECTION 4 — Cost governance
# ---------------------------------------------------------------------------
$budgets            = Add-QueryResult -Label 'Subscription Budgets'           -Arguments @('consumption', 'budget', 'list')
$advisorCost        = Add-QueryResult -Label 'Azure Advisor Cost Recommendations' -Arguments @('advisor', 'recommendation', 'list', '--resource-group', $ResourceGroup, '--category', 'Cost')
$policyAssignments  = Add-QueryResult -Label 'Resource Group Policy Assignments'  -Arguments @('policy', 'assignment', 'list', '--resource-group', $ResourceGroup)
$resourceTags       = Add-QueryResult -Label 'Resource Group Resource Tags'       -Arguments @('resource', 'list', '--resource-group', $ResourceGroup, '--query', '[].{name:name,type:type,tags:tags}')
if ($SkipReservations) {
    Write-StatusMessage -Level 'INFO' -Message 'Skipping Subscription Reservations (use -SkipReservations $false to enable)'
    $reservations = $null
} else {
    $reservations = Add-QueryResult -Label 'Subscription Reservations' -Arguments @('reservations', 'reservation-order', 'list')
}

# ---------------------------------------------------------------------------
# SECTION 5 — Supporting infrastructure
# ---------------------------------------------------------------------------
$redisList          = Add-QueryResult -Label 'Azure Cache for Redis Instances'    -Arguments @('redis', 'list', '--resource-group', $ResourceGroup)
$afdRg              = if ($AfdResourceGroup) { $AfdResourceGroup } else { $ResourceGroup }
$afdProfiles        = Add-QueryResult -Label 'Azure Front Door Profiles'          -Arguments @('afd', 'profile', 'list', '--resource-group', $afdRg)
$cdnProfiles        = Add-QueryResult -Label 'Azure CDN Profiles'                 -Arguments @('cdn', 'profile', 'list', '--resource-group', $ResourceGroup)
$storageAccounts    = Add-QueryResult -Label 'Storage Accounts in Resource Group' -Arguments @('storage', 'account', 'list', '--resource-group', $ResourceGroup)
$logAnalyticsWs     = Add-QueryResult -Label 'Log Analytics Workspaces'           -Arguments @('monitor', 'log-analytics', 'workspace', 'list', '--resource-group', $ResourceGroup)
$serviceBusNs       = Add-QueryResult -Label 'Service Bus Namespaces'             -Arguments @('servicebus', 'namespace', 'list', '--resource-group', $ResourceGroup)

# Diagnostic settings on App Service (for log retention check)
$appDiagSettings    = Add-QueryResultWhenValuePresent -Label 'App Service Diagnostic Settings' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor', 'diagnostic-settings', 'list', '--resource', $webAppId)

# ---------------------------------------------------------------------------
# SECTION 6 — Evaluate cost findings
# ---------------------------------------------------------------------------
$findings = [System.Collections.Generic.List[object]]::new()

# Helper: compute average of metric time series
function Get-MetricAverage {
    param($MetricResult, [string]$MetricName)
    if (-not $MetricResult.Success -or -not $MetricResult.Data) { return $null }
    $series = $MetricResult.Data
    if (-not ($series -is [System.Array]) -and $series.PSObject.Properties['value']) { $series = $series.value }
    $timeseries = Get-SafePropertyValue -InputObject @($series)[0] -Path @('timeseries')
    if (-not $timeseries) { return $null }
    $tsData = Get-SafePropertyValue -InputObject @($timeseries)[0] -Path @('data')
    if (-not $tsData) { return $null }
    $values = @(foreach ($dp in @($tsData)) {
        $v = Get-SafePropertyValue -InputObject $dp -Path @('average')
        if ($null -ne $v) { [double]$v }
    })
    if ($values.Count -eq 0) { return $null }
    return [math]::Round(($values | Measure-Object -Average).Average, 1)
}

function Get-MetricMax {
    param($MetricResult)
    if (-not $MetricResult.Success -or -not $MetricResult.Data) { return $null }
    $series = $MetricResult.Data
    if (-not ($series -is [System.Array]) -and $series.PSObject.Properties['value']) { $series = $series.value }
    $timeseries = Get-SafePropertyValue -InputObject @($series)[0] -Path @('timeseries')
    if (-not $timeseries) { return $null }
    $tsData = Get-SafePropertyValue -InputObject @($timeseries)[0] -Path @('data')
    if (-not $tsData) { return $null }
    $values = @(foreach ($dp in @($tsData)) {
        $v = Get-SafePropertyValue -InputObject $dp -Path @('maximum')
        if ($null -ne $v) { [double]$v }
    })
    if ($values.Count -eq 0) { return $null }
    return [math]::Round(($values | Measure-Object -Maximum).Maximum, 1)
}

# ---- CO:01 Financial Responsibility Culture ----

# Advisor cost recommendations
if ($advisorCost.Success -and $advisorCost.Data) {
    $openRecs = @($advisorCost.Data | Where-Object {
        $suppIds = if ($_.PSObject.Properties['properties'] -and $null -ne $_.properties) { $_.properties.suppressionIds } else { $null }
        $null -eq $suppIds -or @($suppIds).Count -eq 0
    })
    if ($openRecs.Count -eq 0) {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:01 Financial Responsibility Culture' -Question 'Are Azure Advisor cost recommendations reviewed and acted on regularly?' -Priority 3 -Status 'PASS' -Notes 'No open Advisor cost recommendations found in resource group.'))
    } else {
        $titles = ($openRecs | Select-Object -First 5 | ForEach-Object { Get-SafePropertyValue -InputObject $_ -Path @('shortDescription', 'solution') }) -join '; '
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:01 Financial Responsibility Culture' -Question 'Are Azure Advisor cost recommendations reviewed and acted on regularly?' -Priority 3 -Status 'FAIL' -Notes ('{0} open recommendation(s). Sample: {1}' -f $openRecs.Count, $titles)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:01 Financial Responsibility Culture' -Question 'Are Azure Advisor cost recommendations reviewed and acted on regularly?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve Advisor recommendations.'))
}

# Resource tags
if ($resourceTags.Success -and $resourceTags.Data) {
    $untagged = @($resourceTags.Data | Where-Object { $null -eq $_.tags -or ($_.tags.PSObject.Properties | Measure-Object).Count -eq 0 })
    $total    = @($resourceTags.Data).Count
    if ($untagged.Count -eq 0) {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:01 Financial Responsibility Culture' -Question 'Are resource tags applied for cost allocation?' -Priority 3 -Status 'PASS' -Notes ('All {0} resource(s) in resource group have tags.' -f $total)))
    } else {
        $names = ($untagged | Select-Object -First 5 | ForEach-Object { $_.name }) -join ', '
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:01 Financial Responsibility Culture' -Question 'Are resource tags applied for cost allocation?' -Priority 3 -Status 'FAIL' -Notes ('{0}/{1} resource(s) have no tags. Untagged (sample): {2}' -f $untagged.Count, $total, $names)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:01 Financial Responsibility Culture' -Question 'Are resource tags applied for cost allocation?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve resource tag data.'))
}

# ---- CO:06 Align Usage to Billing Increments ----

# MySQL storage scale-up-only — initial provisioning conservative
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $storageSizeGb = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'storageSizeGb')
    $autoGrow      = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'autoGrow')
    $notes = ('Current storageSizeGb = {0}; autoGrow = {1}. Storage cannot be scaled down — verify initial provisioning was conservative.' -f $storageSizeGb, $autoGrow)
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Is it understood that MySQL storage can only scale up — is initial provisioning conservative?' -Priority 3 -Status 'MANUAL' -Notes $notes))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Is it understood that MySQL storage can only scale up — is initial provisioning conservative?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# MySQL HA cost — doubles compute cost
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $haMode  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability', 'mode')
    $haState = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability', 'state')
    $skuTier = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'tier')
    if ($null -eq $haMode -or $haMode -eq 'Disabled') {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Is it understood that MySQL HA nearly doubles compute cost — and is HA justified for each environment?' -Priority 3 -Status 'PASS' -Notes ('HA mode = {0}. HA is not enabled — no doubled compute cost.' -f $haMode)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Is it understood that MySQL HA nearly doubles compute cost — and is HA justified for each environment?' -Priority 3 -Status 'MANUAL' -Notes ('HA mode = {0}; state = {1}; SKU tier = {2}. HA IS enabled — confirm this is justified for this environment and that cost has been accounted for.' -f $haMode, $haState, $skuTier)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Is it understood that MySQL HA nearly doubles compute cost — and is HA justified for each environment?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# Geo-redundant backup — costs twice LRS rate
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $geoBackup = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup', 'geoRedundantBackup')
    if ($geoBackup -eq 'Enabled') {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Is it understood that geo-redundant backup costs twice the LRS rate?' -Priority 3 -Status 'MANUAL' -Notes ('geoRedundantBackup = {0}. Geo-redundant backup IS enabled — confirm this cost is justified vs locally redundant backup.' -f $geoBackup)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Is it understood that geo-redundant backup costs twice the LRS rate?' -Priority 3 -Status 'PASS' -Notes ('geoRedundantBackup = {0}. Lower-cost backup redundancy is in use.' -f $geoBackup)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Is it understood that geo-redundant backup costs twice the LRS rate?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# Burstable tier CPU credit model evaluation
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $skuTier = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'tier')
    $skuName = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'name')
    if ($skuTier -eq 'Burstable') {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Has the Burstable tier CPU credit model been evaluated against the WordPress workload?' -Priority 3 -Status 'MANUAL' -Notes ('SKU tier = {0} ({1}). Currently using Burstable tier — validate that CPU credit accumulation is sufficient for the WordPress traffic pattern. Review CPU metrics to confirm no sustained credit depletion.' -f $skuTier, $skuName)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Has the Burstable tier CPU credit model been evaluated against the WordPress workload?' -Priority 3 -Status 'PASS' -Notes ('SKU tier = {0} ({1}). Not using Burstable tier — CPU credit model does not apply.' -f $skuTier, $skuName)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Has the Burstable tier CPU credit model been evaluated against the WordPress workload?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# ---- CO:07 Optimise Component Costs ----

# Slow query logs (Priority 2)
if ($paramSlowQueryLog.Success -and $paramSlowQueryLog.Data) {
    $slqValue = Get-SafePropertyValue -InputObject $paramSlowQueryLog.Data -Path @('value')
    $lqtValue = if ($paramLongQueryTime.Success -and $paramLongQueryTime.Data) { Get-SafePropertyValue -InputObject $paramLongQueryTime.Data -Path @('value') } else { 'unknown' }
    if ($slqValue -eq 'ON') {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Are slow query logs reviewed for expensive queries to reduce CPU/I/O?' -Priority 2 -Status 'PASS' -Notes ('slow_query_log = {0}; long_query_time = {1}s. Slow query logging is enabled.' -f $slqValue, $lqtValue)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Are slow query logs reviewed for expensive queries to reduce CPU/I/O?' -Priority 2 -Status 'FAIL' -Notes ('slow_query_log = {0}. Enable slow query logging to identify expensive queries driving unnecessary MySQL CPU and I/O costs.' -f $slqValue)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Are slow query logs reviewed for expensive queries to reduce CPU/I/O?' -Priority 2 -Status 'UNKNOWN' -Notes 'Could not retrieve slow_query_log parameter.'))
}

# WordPress media offloaded to Blob Storage / CDN (Priority 2)
$hasStorage = $storageAccounts.Success -and $storageAccounts.Data -and @($storageAccounts.Data).Count -gt 0
$hasCdn     = ($afdProfiles.Success -and $afdProfiles.Data -and @($afdProfiles.Data).Count -gt 0) -or
              ($cdnProfiles.Success -and $cdnProfiles.Data -and @($cdnProfiles.Data).Count -gt 0)
if ($hasStorage -and $hasCdn) {
    $storageNames = (@($storageAccounts.Data) | ForEach-Object { $_.name }) -join ', '
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Has the WordPress media library been reviewed with large files offloaded to Blob Storage / CDN?' -Priority 2 -Status 'MANUAL' -Notes ('Storage account(s) found: {0}; CDN/AFD present. Confirm WordPress media is actually configured to use these — check WordPress plugin configuration.' -f $storageNames)))
} elseif ($hasStorage) {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Has the WordPress media library been reviewed with large files offloaded to Blob Storage / CDN?' -Priority 2 -Status 'WARN' -Notes 'Storage account(s) found but no CDN/AFD detected. Media may be stored in Blob but is not being served via CDN — egress costs apply.'))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Has the WordPress media library been reviewed with large files offloaded to Blob Storage / CDN?' -Priority 2 -Status 'FAIL' -Notes 'No storage accounts or CDN profiles found in resource group. WordPress media is likely stored on the App Service filesystem, consuming App Service storage and bandwidth.'))
}

# Connection pooling (Priority 2)
if ($paramMaxConnections.Success -and $paramMaxConnections.Data) {
    $maxConn = Get-SafePropertyValue -InputObject $paramMaxConnections.Data -Path @('value')
    $redisPresent = $redisList.Success -and $redisList.Data -and @($redisList.Data).Count -gt 0
    # Check app settings for proxy/pooling indicators
    $poolingAppSetting = $null
    if ($appSettings.Success -and $appSettings.Data) {
        $poolingAppSetting = @($appSettings.Data | Where-Object { $_.name -match 'PROXYSQL|DB_HOST|WP_PROXY|CONNECTION_POOL|MYSQL_PROXY' }) | Select-Object -First 1
    }
    $notes = ('max_connections = {0}. Redis present = {1}. Pooling app setting detected = {2}. Confirm connection pooling is in use at the application or proxy layer to reduce per-request connection overhead.' -f $maxConn, $redisPresent, ($null -ne $poolingAppSetting))
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Is connection pooling implemented to reduce MySQL connection creation overhead?' -Priority 2 -Status 'MANUAL' -Notes $notes))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Is connection pooling implemented to reduce MySQL connection creation overhead?' -Priority 2 -Status 'UNKNOWN' -Notes 'Could not retrieve max_connections parameter.'))
}

# Unused App Service plans or web apps (Priority 3)
if ($allPlansInRg -and $allPlansInRg.Success -and $allPlansInRg.Data) {
    $emptyPlans = @($allPlansInRg.Data | Where-Object {
        $siteCount = Get-SafePropertyValue -InputObject $_ -Path @('properties', 'numberOfSites')
        if ($null -eq $siteCount) { $siteCount = Get-SafePropertyValue -InputObject $_ -Path @('numberOfSites') }
        [int]$siteCount -eq 0
    })
    if ($emptyPlans.Count -gt 0) {
        $names = ($emptyPlans | ForEach-Object { $_.name }) -join ', '
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have unused App Service plans or web apps in the subscription been identified and removed?' -Priority 3 -Status 'FAIL' -Notes ('{0} App Service plan(s) with zero sites found: {1}' -f $emptyPlans.Count, $names)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have unused App Service plans or web apps in the subscription been identified and removed?' -Priority 3 -Status 'PASS' -Notes ('All {0} App Service plan(s) in resource group have sites assigned.' -f @($allPlansInRg.Data).Count)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have unused App Service plans or web apps in the subscription been identified and removed?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve App Service plan list.'))
}

# App Service CPU/memory utilisation for rightsizing (Priority 3)
$avgCpu    = Get-MetricAverage -MetricResult $appServiceCpuMetrics    -MetricName 'CpuPercentage'
$avgMem    = Get-MetricAverage -MetricResult $appServiceMemoryMetrics  -MetricName 'MemoryWorkingSet'
if ($null -ne $avgCpu) {
    $cpuStatus = if ($avgCpu -lt 20) { 'WARN' } elseif ($avgCpu -gt 80) { 'WARN' } else { 'PASS' }
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have CPU and memory utilisation trends been reviewed for App Service rightsizing?' -Priority 3 -Status $cpuStatus -Notes ('Average CPU over {0} days = {1}%. Average Memory = {2} bytes. Low CPU (<20%) may indicate over-provisioning; high CPU (>80%) may indicate under-provisioning.' -f $MetricLookbackDays, $avgCpu, $avgMem)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have CPU and memory utilisation trends been reviewed for App Service rightsizing?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve App Service CPU metrics. Check metric data collection is enabled.'))
}

# Unused deployment slots (Priority 3)
if ($slots.Success -and $slots.Data) {
    $slotCount = @($slots.Data).Count
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have unused deployment slots been audited?' -Priority 3 -Status 'MANUAL' -Notes ('{0} deployment slot(s) found. Review raw slot data to confirm each slot is actively used and not accumulating idle compute costs.' -f $slotCount)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have unused deployment slots been audited?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve deployment slot list.'))
}

# Custom domain and certificate audit (Priority 3)
if ($hostnameBindings.Success -and $hostnameBindings.Data) {
    $customDomains = @($hostnameBindings.Data | Where-Object { -not ($_.name -like '*.azurewebsites.net') })
    $certCount     = if ($sslCertificates.Success -and $sslCertificates.Data) { @($sslCertificates.Data).Count } else { 'unknown' }
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have custom domain registrations and certificates been audited?' -Priority 3 -Status 'MANUAL' -Notes ('{0} custom domain(s); {1} SSL certificate(s) in resource group. Verify no unused paid certificates are bound. Review SSL certificates section.' -f $customDomains.Count, $certCount)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have custom domain registrations and certificates been audited?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve hostname bindings.'))
}

# MySQL CPU/memory utilisation for rightsizing (Priority 3)
$avgMysqlCpu = Get-MetricAverage -MetricResult $mysqlCpuMetrics    -MetricName 'cpu_percent'
$avgMysqlMem = Get-MetricAverage -MetricResult $mysqlMemoryMetrics  -MetricName 'memory_percent'
if ($null -ne $avgMysqlCpu) {
    $mysqlCpuStatus = if ($avgMysqlCpu -lt 20) { 'WARN' } elseif ($avgMysqlCpu -gt 80) { 'WARN' } else { 'PASS' }
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have MySQL CPU and memory utilisation trends been reviewed for rightsizing?' -Priority 3 -Status $mysqlCpuStatus -Notes ('Average MySQL CPU over {0} days = {1}%. Average memory = {2}%. SKU: {3} / {4}. Low CPU (<20%) may indicate over-provisioning.' -f $MetricLookbackDays, $avgMysqlCpu, $avgMysqlMem, (Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','tier')), (Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','name')))))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Have MySQL CPU and memory utilisation trends been reviewed for rightsizing?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve MySQL CPU metrics.'))
}

# Burstable vs General Purpose evaluation (Priority 3)
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $skuTier = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'tier')
    $skuName = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'name')
    if ($skuTier -eq 'Burstable') {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Has it been evaluated whether Burstable tier is sufficient vs General Purpose?' -Priority 3 -Status 'MANUAL' -Notes ('SKU tier = {0} ({1}). Currently Burstable — review CPU metrics to confirm sustained workload does not exceed credit allowance. Burstable is cheaper but inappropriate for sustained loads.' -f $skuTier, $skuName)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Has it been evaluated whether Burstable tier is sufficient vs General Purpose?' -Priority 3 -Status 'MANUAL' -Notes ('SKU tier = {0} ({1}). Currently not Burstable. Confirm General Purpose is needed vs the lower-cost Burstable tier for non-production environments.' -f $skuTier, $skuName)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Has it been evaluated whether Burstable tier is sufficient vs General Purpose?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# Backup retention period (Priority 3)
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $retentionDays = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup', 'backupRetentionDays')
    if ([int]$retentionDays -gt 7) {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Is backup retention set to the minimum period that meets recovery requirements?' -Priority 3 -Status 'WARN' -Notes ('backupRetentionDays = {0}. Retention above 7 days may incur additional backup storage costs. Verify this meets — but does not exceed — recovery requirements.' -f $retentionDays)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Is backup retention set to the minimum period that meets recovery requirements?' -Priority 3 -Status 'PASS' -Notes ('backupRetentionDays = {0}. Retention is within the conservative range.' -f $retentionDays)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Is backup retention set to the minimum period that meets recovery requirements?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# WordPress object caching / Redis (Priority 3)
if ($redisList.Success -and $redisList.Data -and @($redisList.Data).Count -gt 0) {
    $redisNames = (@($redisList.Data) | ForEach-Object { $_.name }) -join ', '
    # Also check app settings for Redis configuration
    $redisAppSetting = $null
    if ($appSettings.Success -and $appSettings.Data) {
        $redisAppSetting = @($appSettings.Data | Where-Object { $_.name -match 'REDIS|WP_REDIS|OBJECT_CACHE' }) | Select-Object -First 1
    }
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Is WordPress object caching enabled (Redis) to reduce MySQL query volume and allow rightsizing?' -Priority 3 -Status 'MANUAL' -Notes ('Redis instance(s) found: {0}. Redis app setting found = {1}. Confirm the WordPress Redis object cache plugin is active and pointing to this instance.' -f $redisNames, ($null -ne $redisAppSetting))))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Is WordPress object caching enabled (Redis) to reduce MySQL query volume and allow rightsizing?' -Priority 3 -Status 'FAIL' -Notes 'No Redis instances found in resource group. Without object caching, every WordPress page request hits MySQL — preventing rightsizing to a smaller compute tier.'))
}

# CDN for static assets (Priority 3)
if ($hasCdn) {
    $cdnInfo = if ($afdProfiles.Success -and $afdProfiles.Data -and @($afdProfiles.Data).Count -gt 0) {
        'AFD profile(s): ' + ((@($afdProfiles.Data) | ForEach-Object { $_.name }) -join ', ')
    } else {
        'CDN profile(s): ' + ((@($cdnProfiles.Data) | ForEach-Object { $_.name }) -join ', ')
    }
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Is a CDN (Azure Front Door or Azure CDN) used to cache static WordPress assets?' -Priority 3 -Status 'MANUAL' -Notes ('{0}. Confirm WordPress is configured to route static assets through the CDN to reduce origin egress and App Service bandwidth costs.' -f $cdnInfo)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:07 Optimise Component Costs' -Question 'Is a CDN (Azure Front Door or Azure CDN) used to cache static WordPress assets?' -Priority 3 -Status 'FAIL' -Notes 'No AFD or CDN profiles found in resource group. Static assets are served directly from the App Service, consuming bandwidth and increasing origin compute load.'))
}

# ---- CO:08 Optimise Environment Costs ----

# MySQL Burstable B-series for dev/test — NOT production (Priority 1)
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $skuTier = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'tier')
    $skuName = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'name')
    # A production server should NOT be Burstable
    if ($skuTier -eq 'Burstable') {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Are MySQL Burstable B-series instances used for dev/test (not production)?' -Priority 1 -Status 'WARN' -Notes ('SKU tier = {0} ({1}). This server is Burstable. If this is a PRODUCTION server this is a cost and performance risk — upgrade to General Purpose. If dev/test, this is correct.' -f $skuTier, $skuName)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Are MySQL Burstable B-series instances used for dev/test (not production)?' -Priority 1 -Status 'PASS' -Notes ('Production SKU tier = {0} ({1}). Not Burstable — correct for a production workload.' -f $skuTier, $skuName)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Are MySQL Burstable B-series instances used for dev/test (not production)?' -Priority 1 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# MySQL free tier for proof-of-concept (Priority 3)
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $skuName = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'name')
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Is the MySQL free tier used for proof-of-concept?' -Priority 3 -Status 'MANUAL' -Notes ('Current SKU = {0}. Confirm proof-of-concept environments use the free-tier offer where available rather than paid SKUs.' -f $skuName)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Is the MySQL free tier used for proof-of-concept?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# Dev MySQL servers in cost-effective regions (Priority 3)
if ($allMysqlServers.Success -and $allMysqlServers.Data) {
    $serverLocations = (@($allMysqlServers.Data) | ForEach-Object { '{0} ({1})' -f $_.name, $_.location }) -join ', '
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Are dev MySQL servers deployed in cost-effective regions when data residency permits?' -Priority 3 -Status 'MANUAL' -Notes ('MySQL server(s) and locations: {0}. Verify dev/test servers are not in premium regions (e.g. West Europe) when a lower-cost region would suffice.' -f $serverLocations)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Are dev MySQL servers deployed in cost-effective regions when data residency permits?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve MySQL server list.'))
}

# ---- CO:09 Optimise Flow Costs ----

# Full-page caching for anonymous visitors (Priority 3)
if ($appSettings.Success -and $appSettings.Data) {
    $cacheAppSetting = @($appSettings.Data | Where-Object { $_.name -match 'W3TC|LSCACHE|WP_CACHE|CACHE_ENABLER|LITESPEED|FASTCGI_CACHE' }) | Select-Object -First 1
    if ($cacheAppSetting) {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:09 Optimise Flow Costs' -Question 'Is full-page caching implemented to reduce PHP execution and MySQL calls for anonymous visitors?' -Priority 3 -Status 'MANUAL' -Notes ('Caching-related app setting found: {0}. Confirm the WordPress caching plugin is active and caching anonymous page requests.' -f $cacheAppSetting.name)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:09 Optimise Flow Costs' -Question 'Is full-page caching implemented to reduce PHP execution and MySQL calls for anonymous visitors?' -Priority 3 -Status 'MANUAL' -Notes 'No caching-related app settings detected. Check WordPress plugin configuration directly (W3 Total Cache, WP Super Cache, LiteSpeed Cache, etc.) — these are configured at the WordPress application level.'))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:09 Optimise Flow Costs' -Question 'Is full-page caching implemented to reduce PHP execution and MySQL calls for anonymous visitors?' -Priority 3 -Status 'UNKNOWN' -Notes 'App settings not available.'))
}

# Message queues for background tasks (Priority 3)
$hasServiceBus = $serviceBusNs.Success -and $serviceBusNs.Data -and @($serviceBusNs.Data).Count -gt 0
$hasQueue      = $storageAccounts.Success -and $storageAccounts.Data -and @($storageAccounts.Data).Count -gt 0
if ($hasServiceBus) {
    $sbNames = (@($serviceBusNs.Data) | ForEach-Object { $_.name }) -join ', '
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:09 Optimise Flow Costs' -Question 'Are message queues used to defer expensive background tasks off the main request path?' -Priority 3 -Status 'MANUAL' -Notes ('Service Bus namespace(s) found: {0}. Confirm WordPress background tasks (email, media processing) are actually routed through the queue.' -f $sbNames)))
} elseif ($hasQueue) {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:09 Optimise Flow Costs' -Question 'Are message queues used to defer expensive background tasks off the main request path?' -Priority 3 -Status 'MANUAL' -Notes 'Storage account present (Azure Queue Storage possible). No Service Bus found. Verify whether background tasks are being queued or running inline on the request thread.'))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:09 Optimise Flow Costs' -Question 'Are message queues used to defer expensive background tasks off the main request path?' -Priority 3 -Status 'MANUAL' -Notes 'No Service Bus namespace or storage queue infrastructure detected. Background tasks may be running synchronously on the request thread, increasing App Service CPU time and MySQL load.'))
}

# ---- CO:10 Optimise Data Costs ----

# Log Analytics workspace retention (Priority 2)
if ($logAnalyticsWs.Success -and $logAnalyticsWs.Data -and @($logAnalyticsWs.Data).Count -gt 0) {
    $wsDetails = (@($logAnalyticsWs.Data) | ForEach-Object { '{0}: {1} days' -f $_.name, $_.retentionInDays }) -join ', '
    $overRetention = @($logAnalyticsWs.Data | Where-Object { [int]$_.retentionInDays -gt 90 })
    if ($overRetention.Count -gt 0) {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Is a Log Analytics workspace retention policy implemented?' -Priority 2 -Status 'WARN' -Notes ('Workspace(s) with >90-day retention: {0}. Long retention periods increase data storage costs.' -f $wsDetails)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Is a Log Analytics workspace retention policy implemented?' -Priority 2 -Status 'PASS' -Notes ('Workspace(s): {0}. Retention is within 90 days.' -f $wsDetails)))
    }
} elseif ($logAnalyticsWs.Success -and (!$logAnalyticsWs.Data -or @($logAnalyticsWs.Data).Count -eq 0)) {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Is a Log Analytics workspace retention policy implemented?' -Priority 2 -Status 'WARN' -Notes 'No Log Analytics workspace found in resource group. Workspace may exist in another resource group — check cross-RG. Without a workspace, diagnostics and monitoring data are not being centralised.'))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Is a Log Analytics workspace retention policy implemented?' -Priority 2 -Status 'UNKNOWN' -Notes 'Could not retrieve Log Analytics workspaces.'))
}

# WordPress media in Blob Storage (Priority 2)
if ($hasStorage) {
    $storageNames = (@($storageAccounts.Data) | ForEach-Object { $_.name }) -join ', '
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Are WordPress media files stored in Azure Blob Storage with appropriate access tiers?' -Priority 2 -Status 'MANUAL' -Notes ('Storage account(s) found: {0}. Confirm the WordPress media library is stored in Blob Storage and that blobs are tiered appropriately (Hot for frequently accessed media, Cool/Archive for older assets).' -f $storageNames)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Are WordPress media files stored in Azure Blob Storage with appropriate access tiers?' -Priority 2 -Status 'FAIL' -Notes 'No storage accounts found in resource group. WordPress media is likely stored on the App Service filesystem, missing CDN delivery optimisation and Blob storage tiers.'))
}

# Geo-redundant backup necessity (Priority 3)
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $geoBackup = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup', 'geoRedundantBackup')
    if ($geoBackup -eq 'Enabled') {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Has it been evaluated whether geo-redundant MySQL backup is necessary?' -Priority 3 -Status 'MANUAL' -Notes ('geoRedundantBackup = Enabled. Geo-redundant backup doubles storage costs vs LRS. Confirm whether geo-redundancy is required by your RTO/RPO — if not, switch to locally redundant backup.')))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Has it been evaluated whether geo-redundant MySQL backup is necessary?' -Priority 3 -Status 'PASS' -Notes ('geoRedundantBackup = {0}. Lower-cost backup redundancy in use.' -f $geoBackup)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Has it been evaluated whether geo-redundant MySQL backup is necessary?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# MySQL backup frequency (Priority 3)
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $retentionDays    = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup', 'backupRetentionDays')
    $backupIntervalHr = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup', 'backupIntervalHours')
    $notes = ('backupRetentionDays = {0}; backupIntervalHours = {1}. For large databases consider 6-hour backup intervals to balance recovery granularity against backup storage costs.' -f $retentionDays, ($backupIntervalHr ?? 'default (24h)'))
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Is MySQL backup frequency configured appropriately?' -Priority 3 -Status 'MANUAL' -Notes $notes))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Is MySQL backup frequency configured appropriately?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# App Service diagnostic log retention (Priority 3)
if ($appDiagSettings.Success -and $appDiagSettings.Data -and @($appDiagSettings.Data).Count -gt 0) {
    $highRetention = @($appDiagSettings.Data | ForEach-Object {
        $_.logs | Where-Object { $_.retentionPolicy -and [int]$_.retentionPolicy.days -gt 90 }
    })
    if ($highRetention.Count -gt 0) {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Is App Service diagnostic log retention reviewed?' -Priority 3 -Status 'WARN' -Notes ('{0} log category/categories with >90-day retention found. High retention increases Log Analytics ingestion costs.' -f $highRetention.Count)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Is App Service diagnostic log retention reviewed?' -Priority 3 -Status 'PASS' -Notes 'App Service diagnostic log categories have retention within 90 days.'))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:10 Optimise Data Costs' -Question 'Is App Service diagnostic log retention reviewed?' -Priority 3 -Status 'MANUAL' -Notes 'No diagnostic settings found on App Service. Logs may not be configured, or may route to a workspace in another resource group. Verify in Azure Monitor.'))
}

# ---- CO:11 Optimise Code Costs ----

# WordPress database query optimisation (Priority 2)
if ($paramSlowQueryLog.Success -and $paramSlowQueryLog.Data) {
    $slqValue = Get-SafePropertyValue -InputObject $paramSlowQueryLog.Data -Path @('value')
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:11 Optimise Code Costs' -Question 'Have WordPress database queries been optimised using slow query logs?' -Priority 2 -Status $(if ($slqValue -eq 'ON') { 'MANUAL' } else { 'FAIL' }) -Notes ('slow_query_log = {0}. {1}' -f $slqValue, $(if ($slqValue -eq 'ON') { 'Slow query logs are enabled. Review MySqlSlowLogs in Log Analytics to identify and optimise expensive WordPress queries.' } else { 'Enable slow_query_log to identify queries driving unnecessary CPU and I/O costs.' }))))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:11 Optimise Code Costs' -Question 'Have WordPress database queries been optimised using slow query logs?' -Priority 2 -Status 'UNKNOWN' -Notes 'Could not retrieve slow_query_log parameter.'))
}

# PHP OPcache (Priority 3)
if ($appSettings.Success -and $appSettings.Data) {
    $opcacheSetting = @($appSettings.Data | Where-Object { $_.name -match 'OPCACHE|PHP_OPCACHE|PHP_INI' }) | Select-Object -First 1
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:11 Optimise Code Costs' -Question 'Is PHP OPcache enabled to reduce CPU consumption?' -Priority 3 -Status 'MANUAL' -Notes ('OPcache-related app setting found = {0}. OPcache is enabled by default on Azure App Service for PHP. Confirm opcache.enable=1 and tune opcache.memory_consumption and opcache.max_accelerated_files for the WordPress codebase size.' -f ($null -ne $opcacheSetting))))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:11 Optimise Code Costs' -Question 'Is PHP OPcache enabled to reduce CPU consumption?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve app settings.'))
}

# wp-cron offloaded (Priority 3)
if ($appSettings.Success -and $appSettings.Data) {
    $disableWpCron = @($appSettings.Data | Where-Object { $_.name -eq 'DISABLE_WP_CRON' -and $_.value -eq 'true' }) | Select-Object -First 1
    if ($disableWpCron) {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:11 Optimise Code Costs' -Question 'Have WordPress wp-cron jobs been audited and offloaded to an external scheduler?' -Priority 3 -Status 'PASS' -Notes 'DISABLE_WP_CRON=true found in app settings. WordPress internal cron is disabled — confirm an external scheduler (Azure Logic App, Azure Function, or server cron) is configured as a replacement.'))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:11 Optimise Code Costs' -Question 'Have WordPress wp-cron jobs been audited and offloaded to an external scheduler?' -Priority 3 -Status 'FAIL' -Notes 'DISABLE_WP_CRON=true not found. WordPress internal cron fires on every page request, adding CPU overhead and MySQL calls even under no-traffic conditions.'))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:11 Optimise Code Costs' -Question 'Have WordPress wp-cron jobs been audited and offloaded to an external scheduler?' -Priority 3 -Status 'UNKNOWN' -Notes 'App settings not available.'))
}

# ---- CO:12 Optimise Scaling Costs ----

# Autoscale min/max instance limits (Priority 3)
try {
if ($autoscaleSettings -and $autoscaleSettings.Success -and $autoscaleSettings.Data -and @($autoscaleSettings.Data).Count -gt 0) {
    $appPlanAutoscale = @($autoscaleSettings.Data | Where-Object {
        $targetId = Get-SafePropertyValue -InputObject $_ -Path @('targetResourceUri')
        $targetId -and $targetId -like "*$planId*"
    })
    if ($appPlanAutoscale.Count -gt 0) {
        $as = $appPlanAutoscale[0]
        $profiles = @(Get-SafePropertyValue -InputObject $as -Path @('profiles'))
        $firstProfile = if ($profiles.Count -gt 0) { $profiles[0] } else { $null }
        $minInstances = Get-SafePropertyValue -InputObject $firstProfile -Path @('capacity', 'minimum')
        $maxInstances = Get-SafePropertyValue -InputObject $firstProfile -Path @('capacity', 'maximum')
        if ($null -eq $minInstances) { $minInstances = 'unknown' }
        if ($null -eq $maxInstances) { $maxInstances = 'unknown' }
        $rules = Get-SafePropertyValue -InputObject $firstProfile -Path @('rules')
        $ruleCount = if ($rules) { @($rules).Count } else { 0 }
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Are autoscale minimum/maximum instance limits, trigger thresholds, scale-in rules, and load test validation defined?' -Priority 3 -Status 'MANUAL' -Notes ('Autoscale found for App Service plan. Min instances = {0}; Max instances = {1}; Rule count = {2}. Review raw autoscale data to confirm scale-in rules and CPU thresholds are tuned to avoid paying for short-lived unnecessary instances.' -f $minInstances, $maxInstances, $ruleCount)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Are autoscale minimum/maximum instance limits, trigger thresholds, scale-in rules, and load test validation defined?' -Priority 3 -Status 'FAIL' -Notes 'No autoscale settings found for the App Service plan. Without autoscaling the App Service runs at a fixed instance count regardless of traffic, potentially wasting cost at low-traffic periods.'))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Are autoscale minimum/maximum instance limits, trigger thresholds, scale-in rules, and load test validation defined?' -Priority 3 -Status $(if ($autoscaleSettings) { 'FAIL' } else { 'UNKNOWN' }) -Notes 'Could not retrieve autoscale settings for the resource group.'))
}
} catch {
    $autoscaleError = $_.Exception.Message
    Write-StatusMessage -Level 'WARN' -Message ("Could not evaluate autoscale settings: {0}. Continuing with remaining Cost checks." -f $autoscaleError)
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Are autoscale minimum/maximum instance limits, trigger thresholds, scale-in rules, and load test validation defined?' -Priority 3 -Status 'UNKNOWN' -Notes ("Could not evaluate autoscale settings safely. Error: {0}. Review raw autoscale data if available." -f $autoscaleError)))
}

# MySQL storage provisioned conservatively (Priority 3)
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $storageSizeGb = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'storageSizeGb')
    $autoGrow      = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'autoGrow')
    # Check actual storage used from metrics
    $maxStorageUsedBytes = Get-MetricMax -MetricResult $mysqlStorageMetrics
    $maxStorageUsedGb    = if ($null -ne $maxStorageUsedBytes) { [math]::Round($maxStorageUsedBytes / 1GB, 1) } else { $null }
    $usagePct = if ($null -ne $maxStorageUsedGb -and [int]$storageSizeGb -gt 0) { [math]::Round(($maxStorageUsedGb / [int]$storageSizeGb) * 100, 1) } else { $null }
    $notes = ('storageSizeGb = {0}; autoGrow = {1}; Max used in last {2} days = {3} GB ({4}% utilisation). Storage cannot be scaled down — initial provisioning should be conservative.' -f $storageSizeGb, $autoGrow, $MetricLookbackDays, $maxStorageUsedGb, $usagePct)
    $status = if ($null -ne $usagePct -and $usagePct -lt 30) { 'WARN' } elseif ($null -ne $usagePct) { 'PASS' } else { 'MANUAL' }
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Has MySQL storage been provisioned conservatively?' -Priority 3 -Status $status -Notes $notes))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Has MySQL storage been provisioned conservatively?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# Autoscale IOPS vs pre-provisioned IOPS (Priority 3)
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $autoIoScaling = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'autoIoScaling')
    $iops          = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'iops')
    if ($autoIoScaling -eq 'Enabled') {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Is autoscale IOPS used for variable traffic?' -Priority 3 -Status 'PASS' -Notes ('autoIoScaling = Enabled. Pay-per-use IOPS is configured — optimal for variable WordPress traffic patterns. Current IOPS setting = {0}.' -f $iops)))
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Is pre-provisioned IOPS used for steady predictable workloads?' -Priority 3 -Status 'MANUAL' -Notes ('autoIoScaling = Enabled. Pre-provisioned IOPS is NOT in use. If the workload is steady and predictable, pre-provisioned IOPS may provide a lower and more predictable cost than pay-per-use autoscale.')))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Is autoscale IOPS used for variable traffic?' -Priority 3 -Status 'MANUAL' -Notes ('autoIoScaling = {0}; provisioned IOPS = {1}. Autoscale IOPS is NOT enabled. If traffic is variable, autoscale IOPS may reduce cost vs over-provisioning a fixed IOPS value.' -f $autoIoScaling, $iops)))
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Is pre-provisioned IOPS used for steady predictable workloads?' -Priority 3 -Status 'PASS' -Notes ('autoIoScaling = {0}; provisioned IOPS = {1}. Pre-provisioned IOPS is in use — appropriate for steady, predictable workloads.' -f $autoIoScaling, $iops)))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Is autoscale IOPS used for variable traffic?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:12 Optimise Scaling Costs' -Question 'Is pre-provisioned IOPS used for steady predictable workloads?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# ---- CO:14 Consolidation ----

# Shared Log Analytics workspace (Priority 2)
if ($logAnalyticsWs.Success -and $logAnalyticsWs.Data) {
    $wsCount = @($logAnalyticsWs.Data).Count
    if ($wsCount -eq 1) {
        $wsName = @($logAnalyticsWs.Data)[0].name
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Is a shared Log Analytics workspace used across environments?' -Priority 2 -Status 'MANUAL' -Notes ('Single workspace found: {0}. Confirm all environments (prod, staging, dev) send diagnostics to this shared workspace rather than provisioning separate workspaces per environment.' -f $wsName)))
    } elseif ($wsCount -gt 1) {
        $wsNames = (@($logAnalyticsWs.Data) | ForEach-Object { $_.name }) -join ', '
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Is a shared Log Analytics workspace used across environments?' -Priority 2 -Status 'WARN' -Notes ('{0} Log Analytics workspaces found in resource group: {1}. Multiple workspaces may mean environments are not sharing a workspace, increasing ingestion and retention costs.' -f $wsCount, $wsNames)))
    } else {
        $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Is a shared Log Analytics workspace used across environments?' -Priority 2 -Status 'MANUAL' -Notes 'No Log Analytics workspaces found in this resource group. Workspace may be in a shared resource group — verify and confirm all environments point to a single shared workspace.'))
    }
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Is a shared Log Analytics workspace used across environments?' -Priority 2 -Status 'UNKNOWN' -Notes 'Could not retrieve Log Analytics workspaces.'))
}

# CO:14 Consolidation — P5 additions
if ($redisList.Success -and $redisList.Data -and @($redisList.Data).Count -gt 0) {
    $redisCount = @($redisList.Data).Count
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Is a shared Redis cache used across multiple WordPress instances?' -Priority 5 -Status 'MANUAL' -Notes ('{0} Redis instance(s) found in resource group. If multiple WordPress sites run in the same region, confirm they share a Redis cache instance rather than provisioning one per site.' -f $redisCount)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Is a shared Redis cache used across multiple WordPress instances?' -Priority 5 -Status 'MANUAL' -Notes 'No Redis instances found in this resource group. If Redis is in a shared resource group, confirm it is shared across WordPress instances to avoid per-site provisioning cost.'))
}
if ($afdProfiles.Success -and $afdProfiles.Data -and @($afdProfiles.Data).Count -gt 0) {
    $afdCount = @($afdProfiles.Data).Count
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Is a shared Azure Front Door profile used across multiple WordPress instances?' -Priority 5 -Status 'MANUAL' -Notes ('{0} AFD profile(s) found. If multiple WordPress sites exist, confirm they use routes within a single AFD profile rather than separate profiles per site to consolidate AFD monthly cost.' -f $afdCount)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Is a shared Azure Front Door profile used across multiple WordPress instances?' -Priority 5 -Status 'MANUAL' -Notes 'No AFD profiles found in this resource group. Confirm AFD is shared across WordPress instances if running in a hub-and-spoke topology.'))
}
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Are multiple WordPress databases hosted on the same MySQL Flexible Server instance?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. If multiple WordPress sites exist, hosting all databases on a single MySQL Flexible Server (using separate logical databases) avoids per-server compute and HA costs.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:14 Consolidation' -Question 'Are non-critical applications or WordPress dev/test instances running on a shared App Service plan?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Running multiple non-critical App Service apps on the same plan avoids per-plan base compute cost.'))

# ---- CO:02 Budget — P4 (new section) ----
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:02 Budget' -Question 'Is a cost model / budget baseline documented for the WordPress workload?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Verify a documented cost model exists that accounts for App Service plan, MySQL, AFD, Redis, Storage, bandwidth, and monitoring.'))
if ($budgets.Success -and $budgets.Data -and @($budgets.Data).Count -gt 0) {
    $budgetCount = @($budgets.Data).Count
    $overBudget  = @($budgets.Data | Where-Object { [double]($_.currentSpend.amount) -ge ([double]($_.amount.amount) * 0.9) })
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:02 Budget' -Question 'Is the Azure budget set with a buffer to account for spike activity?' -Priority 4 -Status $(if ($overBudget.Count -gt 0) { 'WARN' } else { 'PASS' }) -Notes ('{0} budget(s) defined. {1}' -f $budgetCount, $(if ($overBudget.Count -gt 0) { '{0} budget(s) are at or above 90% of limit — review whether budget limit includes headroom for traffic spikes.' -f $overBudget.Count } else { 'Budgets appear within limits. Confirm limits include buffer for seasonal or traffic spike events.' }))))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:02 Budget' -Question 'Is the Azure budget set with a buffer to account for spike activity?' -Priority 4 -Status 'FAIL' -Notes 'No Azure Consumption budgets found in this scope. Create a budget in Cost Management for the resource group or subscription with at least a 10–20% buffer above expected spend.'))
}
if ($reservations.Success -and $reservations.Data -and @($reservations.Data).Count -gt 0) {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:02 Budget' -Question 'Have reserved instances been evaluated and purchased for predictable workloads?' -Priority 4 -Status 'PASS' -Notes ('{0} reservation order(s) found. Confirm they cover App Service and MySQL capacity at the appropriate commitment term.' -f @($reservations.Data).Count)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:02 Budget' -Question 'Have reserved instances been evaluated and purchased for predictable workloads?' -Priority 4 -Status 'WARN' -Notes 'No Azure Reservations found. For steady-state App Service and MySQL workloads, 1-year Reserved Instances can reduce compute cost by up to 41% over pay-as-you-go.'))
}

# ---- CO:03 Cost Monitoring — P4 (new section) ----
if ($budgets.Success -and $budgets.Data -and @($budgets.Data).Count -gt 0) {
    $alertedBudgets = @($budgets.Data | Where-Object { $_.notifications -and $_.notifications.PSObject.Properties.Count -gt 1 })
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:03 Cost Monitoring' -Question 'Are budget alerts configured at multiple thresholds (e.g. 80%, 100%, 120%)?' -Priority 4 -Status $(if ($alertedBudgets.Count -gt 0) { 'PASS' } else { 'WARN' }) -Notes ('{0} budget(s) found; {1} have multiple notification thresholds. Configure alerts at ≥2 thresholds (e.g. 80% forecast, 100% actual) to provide early warning before breaching.' -f @($budgets.Data).Count, $alertedBudgets.Count)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:03 Cost Monitoring' -Question 'Are budget alerts configured at multiple thresholds (e.g. 80%, 100%, 120%)?' -Priority 4 -Status 'FAIL' -Notes 'No budgets found — alerts cannot be configured. Create Azure Consumption budgets with notification thresholds at 80%, 100%, and 120%.'))
}
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:03 Cost Monitoring' -Question 'Is Azure Cost Management anomaly detection configured?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Enable cost anomaly alerts in Azure Cost Management to detect unexpected spend increases automatically.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:03 Cost Monitoring' -Question 'Is Cost Analysis reviewed regularly (weekly or after traffic events)?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm a regular cost review cadence is in place and cost dashboards are reviewed after major traffic events or deployments.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:03 Cost Monitoring' -Question 'Are MySQL performance metrics monitored for over-provisioning signals?' -Priority 4 -Status 'MANUAL' -Notes 'Review CPU, memory, storage, and connection metrics over the lookback period above. Low sustained utilisation against a large SKU may indicate an over-provisioning opportunity.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:03 Cost Monitoring' -Question 'Are scaling events tracked to correlate cost spikes with traffic patterns?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Correlate autoscale activity logs with Cost Management data to confirm scaling events are anticipated in the budget model.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:03 Cost Monitoring' -Question 'Is backup storage reviewed regularly for excessive retention?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Review MySQL backup retention setting (shown above) and App Service backup size monthly. Excessive retention generates ongoing storage cost.'))

# ---- CO:04 Policy — P4 (new section) ----
if ($policyAssignments.Success -and $policyAssignments.Data -and @($policyAssignments.Data).Count -gt 0) {
    $allPolicies = @($policyAssignments.Data)
    $appSkuPolicy    = @($allPolicies | Where-Object { $_.displayName -match 'App Service' -or $_.policyDefinitionId -match 'appservice' })
    $mysqlSkuPolicy  = @($allPolicies | Where-Object { $_.displayName -match '[Mm]y[Ss][Qq][Ll]' -or $_.policyDefinitionId -match 'mysql' })
    $tagPolicy       = @($allPolicies | Where-Object { $_.displayName -match '[Tt]ag' -or $_.policyDefinitionId -match 'tag' })
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:04 Policy' -Question 'Is Azure Policy used to enforce approved App Service SKUs?' -Priority 4 -Status $(if ($appSkuPolicy.Count -gt 0) { 'PASS' } else { 'WARN' }) -Notes $(if ($appSkuPolicy.Count -gt 0) { '{0} App Service-related policy assignment(s) found.' -f $appSkuPolicy.Count } else { 'No App Service SKU restriction policy found. Assign the built-in "Allowed locations" or a custom SKU-allowlist policy to prevent accidental provisioning of expensive SKUs.' })))
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:04 Policy' -Question 'Is Azure Policy used to enforce approved MySQL SKUs?' -Priority 4 -Status $(if ($mysqlSkuPolicy.Count -gt 0) { 'PASS' } else { 'WARN' }) -Notes $(if ($mysqlSkuPolicy.Count -gt 0) { '{0} MySQL-related policy assignment(s) found.' -f $mysqlSkuPolicy.Count } else { 'No MySQL SKU restriction policy found. A custom policy can enforce the approved MySQL tier list.' })))
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:04 Policy' -Question 'Is Azure Policy used to enforce required resource tags (cost centre, workload)?' -Priority 4 -Status $(if ($tagPolicy.Count -gt 0) { 'PASS' } else { 'WARN' }) -Notes $(if ($tagPolicy.Count -gt 0) { '{0} tag-related policy assignment(s) found.' -f $tagPolicy.Count } else { 'No tagging policy found. Enforce required tags (environment, owner, costCentre) via Azure Policy Modify/Deny effects to support cost allocation.' })))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:04 Policy' -Question 'Is Azure Policy used to enforce approved App Service SKUs?' -Priority 4 -Status 'WARN' -Notes 'No policy assignments found. Use Azure Policy to restrict App Service plan SKUs to approved tiers.'))
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:04 Policy' -Question 'Is Azure Policy used to enforce approved MySQL SKUs?' -Priority 4 -Status 'WARN' -Notes 'No policy assignments found. Use Azure Policy to restrict MySQL Flexible Server SKUs to approved tiers.'))
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:04 Policy' -Question 'Is Azure Policy used to enforce required resource tags?' -Priority 4 -Status 'WARN' -Notes 'No tagging policy found. Enforce required tags via Azure Policy to support cost centre allocation reporting.'))
}
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:04 Policy' -Question 'Are deployment regions restricted to approved regions via Azure Policy?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI which policies are at subscription scope. Confirm an "Allowed locations" policy prevents accidental deployment to expensive or unapproved regions.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:04 Policy' -Question 'Are alerts configured for MySQL storage autogrow events?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Configure an Azure Monitor alert on the mysql_storage_percent metric (>80%) to provide early warning before automatic autogrow triggers additional storage charges.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:04 Policy' -Question 'Are MySQL read replica usage and costs monitored?' -Priority 4 -Status 'MANUAL' -Notes 'Each read replica is billed at the same rate as the primary. Confirm read replica metrics are reviewed regularly and decommissioned when no longer needed.'))

# ---- CO:05 Get the Best Rates — P4 (new section) ----
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:05 Get the Best Rates' -Question 'Is Dev/Test pricing used for non-production App Service plans?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Dev/Test pricing is available for Visual Studio subscribers and can reduce App Service plan cost by ~55% for non-production workloads.'))
if ($reservations.Success -and $reservations.Data -and @($reservations.Data).Count -gt 0) {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:05 Get the Best Rates' -Question 'Have App Service reserved instances been purchased for production workloads?' -Priority 4 -Status 'PASS' -Notes ('{0} reservation order(s) found. Confirm 1- or 3-year reserved instances cover the production App Service plan for maximum discount.' -f @($reservations.Data).Count)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:05 Get the Best Rates' -Question 'Have App Service reserved instances been purchased for production workloads?' -Priority 4 -Status 'WARN' -Notes 'No Azure Reservations found. For predictable App Service capacity, 1-year reserved instances provide up to 41% savings vs pay-as-you-go on Pv2/Pv3 plans.'))
}
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:05 Get the Best Rates' -Question 'Have Azure Savings Plans been evaluated alongside or instead of reserved instances?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Azure Savings Plans offer compute flexibility (any region/SKU) vs Reserved Instances which are region+SKU specific. Evaluate both for the App Service and MySQL commitment.'))
if ($reservations.Success -and $reservations.Data -and @($reservations.Data).Count -gt 0) {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:05 Get the Best Rates' -Question 'Have MySQL Flexible Server reserved instances been purchased?' -Priority 4 -Status 'PASS' -Notes ('{0} reservation order(s) found. Confirm coverage includes MySQL Flexible Server compute at the appropriate vCore tier.' -f @($reservations.Data).Count)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:05 Get the Best Rates' -Question 'Have MySQL Flexible Server reserved instances been purchased?' -Priority 4 -Status 'WARN' -Notes 'No Azure Reservations found. MySQL Flexible Server reserved instances (1- or 3-year) can reduce compute cost by up to 62% on burstable and general-purpose tiers.'))
}

# CO:06 Align Usage to Billing Increments — P5 additions
if ($mysqlReplicas.Success -and $mysqlReplicas.Data -and @($mysqlReplicas.Data).Count -gt 0) {
    $replicaCount = @($mysqlReplicas.Data).Count
    $replicaNames = (@($mysqlReplicas.Data) | ForEach-Object { $_.name }) -join ', '
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Are read replica charges understood and justified by measured read offload?' -Priority 5 -Status 'MANUAL' -Notes ('{0} read replica(s) found: {1}. Each replica is billed independently at the same compute+storage rate as the primary. Confirm read query offload justifies the per-replica cost.' -f $replicaCount, $replicaNames)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:06 Align Usage to Billing Increments' -Question 'Are read replica charges understood and justified by measured read offload?' -Priority 5 -Status 'PASS' -Notes 'No read replicas found — no per-replica billing to review.'))
}

# CO:08 Optimise Environment Costs — P5 additions
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Are Free or Basic App Service tiers used for dev/test environments?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Dev and test environments should use Free (F1), Shared (D1), or Basic (B1/B2/B3) App Service plans rather than Standard or Premium to reduce cost.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Are non-production MySQL servers stopped during out-of-hours periods?' -Priority 5 -Status 'MANUAL' -Notes 'MySQL Flexible Server supports stop/start. Stopping a dev/test server out of hours (e.g. 18:00–08:00 weekdays, all weekend) can reduce compute cost by up to ~65%.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Is MySQL High Availability disabled for non-production servers?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine non-production server list via az CLI without broader scope. Confirm HA mode = Disabled on dev/test MySQL servers to avoid standby replica charges.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Is MySQL backup retention reduced for non-production servers (e.g. 1–3 days)?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine non-production server list via az CLI. Reduce backup retention to 1–3 days on dev/test servers to reduce backup storage cost.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:08 Optimise Environment Costs' -Question 'Is Locally Redundant Storage (LRS) used for MySQL backups in non-production environments?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine non-production server list via az CLI. Use LRS backup redundancy for non-production MySQL servers to avoid geo-redundant backup storage cost.'))

# ---- CO:13 Optimise Personnel Time — P4 (new section) ----
if ($sslCertificates.Success -and $sslCertificates.Data -and @($sslCertificates.Data).Count -gt 0) {
    $allCertCount = @($sslCertificates.Data).Count
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:13 Optimise Personnel Time' -Question 'Are App Service Managed Certificates used for custom domains to eliminate certificate management cost?' -Priority 4 -Status $(if ($allCertCount -gt 0) { 'MANUAL' } else { 'MANUAL' }) -Notes ('{0} SSL certificate(s) found on the App Service. Review the certificate list above — App Service Managed Certificates are free and auto-renew. Third-party certs incur purchase and renewal overhead.' -f $allCertCount)))
} else {
    $findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:13 Optimise Personnel Time' -Question 'Are App Service Managed Certificates used for custom domains?' -Priority 4 -Status 'MANUAL' -Notes 'Could not retrieve SSL certificate list. App Service Managed Certificates are free and auto-renewing — use them for custom domains instead of purchasing certificates externally.'))
}
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:13 Optimise Personnel Time' -Question 'Is infrastructure defined as code (IaC) to reduce manual provisioning effort?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm Bicep/ARM/Terraform templates are used to provision App Service, MySQL, AFD, and supporting resources to minimise manual deployment effort.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:13 Optimise Personnel Time' -Question 'Are Azure Monitor dashboards and workbooks used to reduce manual reporting effort?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Pre-built or custom Monitor workbooks for WordPress performance and MySQL health reduce the time spent on manual reporting.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:13 Optimise Personnel Time' -Question 'Are MySQL server parameter changes managed via IaC to reduce configuration drift?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Managing MySQL parameters through Bicep or Terraform prevents manual configuration drift and reduces remediation effort after restore events.'))
$findings.Add((New-CostFinding -CoArea 'Cost Optimization' -SubArea 'CO:13 Optimise Personnel Time' -Question 'Are Azure Advisor recommendations reviewed and acted on regularly?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Azure Advisor provides cost, performance, reliability, and security recommendations that reduce manual investigation effort. Review the Advisor recommendations tab monthly.'))

# ---------------------------------------------------------------------------
# SECTION 7 — Build the markdown report
# ---------------------------------------------------------------------------
$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeAppName = ($AppServiceName -replace '[^A-Za-z0-9._-]', '-')
$reportPath  = Join-Path -Path $OutputDirectory -ChildPath ("CostOptimisationReport-{0}-{1}.md" -f $safeAppName, $timestamp)

$builder = [System.Text.StringBuilder]::new()

Add-MarkdownLine -Builder $builder -Text ('# WAF Cost Optimisation Review Report: {0}' -f $AppServiceName)
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text ('Generated: {0}' -f (Get-Date).ToString('u'))
Add-MarkdownLine -Builder $builder -Text ('Resource Group: `{0}`' -f $ResourceGroup)
Add-MarkdownLine -Builder $builder -Text ('App Service: `{0}`' -f $AppServiceName)
Add-MarkdownLine -Builder $builder -Text ('MySQL Flexible Server: `{0}`' -f $MySqlServerName)
Add-MarkdownLine -Builder $builder -Text ('Metric Lookback: {0} days ({1} to {2})' -f $MetricLookbackDays, $metricStartTime, $metricEndTime)
if ($Subscription) {
    Add-MarkdownLine -Builder $builder -Text ('Requested Subscription: `{0}`' -f $Subscription)
}
Add-MarkdownLine -Builder $builder -Text 'Sensitive values in settings, connection strings, and similar fields are redacted.'
Add-MarkdownLine -Builder $builder -Text '> This report covers WAF Cost Optimisation questions at Priority 1 through 5.'
Add-MarkdownLine -Builder $builder

# Summary table
$mysqlSkuTier  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'tier')
$mysqlSkuName  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku', 'name')
$mysqlHaMode   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability', 'mode')
$mysqlStorage  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'storageSizeGb')
$mysqlAutoGrow = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'autoGrow')
$mysqlGeoBackup= Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup', 'geoRedundantBackup')
$mysqlRetention= Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup', 'backupRetentionDays')
$mysqlAutoIops = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'autoIoScaling')
$mysqlIops     = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage', 'iops')

$summary = [ordered]@{
    'Subscription Name'              = Get-SafePropertyValue -InputObject $account.Data -Path @('name')
    'Subscription Id'                = Get-SafePropertyValue -InputObject $account.Data -Path @('id')
    'Resource Group'                 = $ResourceGroup
    'Resource Group Location'        = Get-SafePropertyValue -InputObject $resourceGroupResult.Data -Path @('location')
    'App Service Name'               = Get-SafePropertyValue -InputObject $webApp.Data -Path @('name')
    'App Service State'              = Get-SafePropertyValue -InputObject $webApp.Data -Path @('state')
    'App Service Plan SKU'           = if ($plan -and $plan.Data) { '{0}/{1}' -f (Get-SafePropertyValue -InputObject $plan.Data -Path @('sku', 'tier')), (Get-SafePropertyValue -InputObject $plan.Data -Path @('sku', 'name')) } else { 'unknown' }
    'MySQL Server Name'              = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('name')
    'MySQL Location'                 = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('location')
    'MySQL SKU Tier'                 = $mysqlSkuTier
    'MySQL SKU Name'                 = $mysqlSkuName
    'MySQL HA Mode'                  = $mysqlHaMode
    'MySQL Storage GB'               = $mysqlStorage
    'MySQL Storage AutoGrow'         = $mysqlAutoGrow
    'MySQL Geo-Redundant Backup'     = $mysqlGeoBackup
    'MySQL Backup Retention Days'    = $mysqlRetention
    'MySQL AutoScale IOPS'           = $mysqlAutoIops
    'MySQL Provisioned IOPS'         = $mysqlIops
    'App Service Avg CPU %'          = if ($null -ne $avgCpu) { '{0}%' -f $avgCpu } else { 'No data' }
    'MySQL Avg CPU %'                = if ($null -ne $avgMysqlCpu) { '{0}%' -f $avgMysqlCpu } else { 'No data' }
    'MySQL Avg Memory %'             = if ($null -ne $avgMysqlMem) { '{0}%' -f $avgMysqlMem } else { 'No data' }
    'Redis Instances Found'          = if ($redisList.Success -and $redisList.Data) { @($redisList.Data).Count } else { 0 }
    'CDN / AFD Present'              = $hasCdn
    'Log Analytics Workspaces'       = if ($logAnalyticsWs.Success -and $logAnalyticsWs.Data) { @($logAnalyticsWs.Data).Count } else { 0 }
    'Metric Lookback Days'           = $MetricLookbackDays
}

Add-MarkdownLine -Builder $builder -Text '## Summary'
Add-KeyValueTable -Builder $builder -Values $summary

# Cost assessment
Add-CostAssessmentSection -Builder $builder -Findings $findings

# Raw data
Add-MarkdownLine -Builder $builder -Text '## Raw Data'
Add-MarkdownLine -Builder $builder
Add-JsonSection -Builder $builder -Title 'Azure Account Context'                            -Result $account
Add-JsonSection -Builder $builder -Title 'Resource Group Overview'                          -Result $resourceGroupResult
Add-JsonSection -Builder $builder -Title 'App Service Overview'                             -Result $webApp
Add-JsonSection -Builder $builder -Title 'App Service Site Config'                          -Result $siteConfig
Add-JsonSection -Builder $builder -Title 'App Service App Settings'                         -Result $appSettings
Add-JsonSection -Builder $builder -Title 'App Service Deployment Slots'                     -Result $slots
Add-JsonSection -Builder $builder -Title 'App Service Hostname Bindings'                    -Result $hostnameBindings
Add-JsonSection -Builder $builder -Title 'App Service SSL Certificates'                     -Result $sslCertificates
Add-JsonSection -Builder $builder -Title 'App Service Diagnostic Settings'                  -Result $appDiagSettings
Add-JsonSection -Builder $builder -Title 'All Web Apps in Resource Group'                   -Result $allWebApps

if ($plan) {
    Add-JsonSection -Builder $builder -Title 'App Service Plan Overview'                    -Result $plan
}
if ($allPlansInRg) {
    Add-JsonSection -Builder $builder -Title 'All App Service Plans in Resource Group'      -Result $allPlansInRg
}
if ($autoscaleSettings) {
    Add-JsonSection -Builder $builder -Title 'App Service Autoscale Settings'               -Result $autoscaleSettings
}

Add-JsonSection -Builder $builder -Title 'App Service CPU Metrics'                          -Result $appServiceCpuMetrics
Add-JsonSection -Builder $builder -Title 'App Service Memory Metrics'                       -Result $appServiceMemoryMetrics
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Overview'                   -Result $mysqlServer
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Backups'                    -Result $mysqlBackups
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Replicas'                   -Result $mysqlReplicas
Add-JsonSection -Builder $builder -Title 'All MySQL Flexible Servers in Resource Group'     -Result $allMysqlServers
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: slow_query_log'                  -Result $paramSlowQueryLog
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: long_query_time'                 -Result $paramLongQueryTime
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: max_connections'                 -Result $paramMaxConnections
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: innodb_buffer_pool_size'         -Result $paramInnodbBufferPool
Add-JsonSection -Builder $builder -Title 'MySQL CPU Metrics'                                -Result $mysqlCpuMetrics
Add-JsonSection -Builder $builder -Title 'MySQL Memory Metrics'                             -Result $mysqlMemoryMetrics
Add-JsonSection -Builder $builder -Title 'MySQL IO Metrics'                                 -Result $mysqlIoMetrics
Add-JsonSection -Builder $builder -Title 'MySQL Storage Used Metrics'                       -Result $mysqlStorageMetrics
Add-JsonSection -Builder $builder -Title 'Subscription Budgets'                             -Result $budgets
Add-JsonSection -Builder $builder -Title 'Azure Advisor Cost Recommendations'               -Result $advisorCost
Add-JsonSection -Builder $builder -Title 'Resource Group Policy Assignments'                -Result $policyAssignments
Add-JsonSection -Builder $builder -Title 'Resource Group Resource Tags'                     -Result $resourceTags
if ($null -ne $reservations) { Add-JsonSection -Builder $builder -Title 'Subscription Reservations' -Result $reservations }
Add-JsonSection -Builder $builder -Title 'Azure Cache for Redis Instances'                  -Result $redisList
Add-JsonSection -Builder $builder -Title 'Azure Front Door Profiles'                        -Result $afdProfiles
Add-JsonSection -Builder $builder -Title 'Azure CDN Profiles'                               -Result $cdnProfiles
Add-JsonSection -Builder $builder -Title 'Storage Accounts in Resource Group'               -Result $storageAccounts
Add-JsonSection -Builder $builder -Title 'Log Analytics Workspaces'                         -Result $logAnalyticsWs
Add-JsonSection -Builder $builder -Title 'Service Bus Namespaces'                           -Result $serviceBusNs

Add-CollectionStatusSection -Builder $builder -Results $results

[System.IO.File]::WriteAllText($reportPath, $builder.ToString(), [System.Text.Encoding]::UTF8)
Write-StatusMessage -Level 'OK' -Message ("Cost optimisation report written to {0}" -f $reportPath)
