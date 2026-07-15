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

    # Number of days of metric history to pull for rightsizing checks.
    [int]$MetricLookbackDays = 30,

    # Optional: Azure Front Door resource group if different from $ResourceGroup.
    [string]$AfdResourceGroup
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helper utilities  (shared pattern across all review scripts)
# ---------------------------------------------------------------------------
function Write-StatusMessage {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO')
    Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message)
}

function Get-SafePropertyValue {
    param($InputObject, [Parameter(Mandatory)][string[]]$Path)
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
    param([Parameter(Mandatory)][string[]]$Arguments)
    $quoted = foreach ($a in $Arguments) { if ($a -match '\s') { '"{0}"' -f $a.Replace('"','\"') } else { $a } }
    'az {0}' -f ($quoted -join ' ')
}

function Invoke-AzCliCommand {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string[]]$Arguments, [switch]$Required)
    $full = [System.Collections.Generic.List[string]]::new(); $full.AddRange($Arguments)
    if ($Subscription) { $full.Add('--subscription'); $full.Add($Subscription) }
    $full.Add('--output'); $full.Add('json'); $full.Add('--only-show-errors')
    $cmd = Get-CommandText -Arguments $full.ToArray()
    $started = Get-Date
    Write-StatusMessage -Level INFO -Message ("Collecting {0}" -f $Label)
    $raw = & az @full 2>&1
    $exit = $LASTEXITCODE
    $output = (($raw | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ } }) -join [Environment]::NewLine).Trim()
    $data = $null
    if ($output) { try { $data = $output | ConvertFrom-Json -Depth 100 } catch { $data = $output } }
    $ok = $exit -eq 0
    if ($Required -and -not $ok) { Write-StatusMessage -Level ERROR -Message ("Failed {0}" -f $Label); Write-Error ("[CRITICAL] Required data collection failed for '{0}'. Findings for this area will be marked UNKNOWN. Command: {1}. Error: {2}" -f $Label, $cmd, $output) }
    if ($ok) { Write-StatusMessage -Level OK   -Message ("Collected {0} in {1:N1}s" -f $Label, ((Get-Date)-$started).TotalSeconds) }
    else      { Write-StatusMessage -Level WARN -Message ("Could not collect {0} in {1:N1}s" -f $Label, ((Get-Date)-$started).TotalSeconds) }
    [pscustomobject]@{ Label=$Label; Command=$cmd; Success=$ok; ExitCode=$exit; ErrorMessage=$(if($ok){$null}else{$output}); Data=$data }
}

function Test-SensitiveName { param([AllowNull()][string]$Name); if ([string]::IsNullOrWhiteSpace($Name)) { return $false }; return $Name -match '(?i)(password|passwd|pwd|secret|token|connectionstring|accountkey|sharedaccesskey|sharedkey|clientsecret|publishingpassword|sas|instrumentationkey)' }
function Test-SensitiveValue { param([AllowNull()][string]$Value); if ([string]::IsNullOrWhiteSpace($Value)) { return $false }; return $Value -match '(?i)(password\s*=|pwd\s*=|accountkey\s*=|sharedaccesssignature=|sig=|clientsecret\s*=|endpoint=.*;sharedaccesskey=)' }

function Protect-Object {
    param($InputObject, [string]$PropertyName = '')
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { if (Test-SensitiveName -Name $PropertyName -or Test-SensitiveValue -Value $InputObject) { return 'SECRET_FOUND_REDACTED' }; return $InputObject }
    if ($InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) { $c=[ordered]@{}; foreach ($k in $InputObject.Keys) { $c[$k] = Protect-Object -InputObject $InputObject[$k] -PropertyName ([string]$k) }; return [pscustomobject]$c }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) { return @(foreach ($i in $InputObject) { Protect-Object -InputObject $i -PropertyName $PropertyName }) }
    $props = @($InputObject.PSObject.Properties); if ($props.Length -eq 0) { return $InputObject }
    $c=[ordered]@{}; foreach ($p in $props) { $c[$p.Name] = Protect-Object -InputObject $p.Value -PropertyName $p.Name }; [pscustomobject]$c
}

function ConvertTo-MarkdownText { param([AllowNull()]$Value); if ($null -eq $Value) { return '' }; return ([string]$Value).Replace('|','\|').Replace("`r",' ').Replace("`n",'<br>') }
function Add-MarkdownLine { param([Parameter(Mandatory)][System.Text.StringBuilder]$Builder, [AllowNull()][string]$Text = ''); [void]$Builder.AppendLine($Text) }

function Add-KeyValueTable {
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Builder, [Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    Add-MarkdownLine -Builder $Builder -Text '| Property | Value |'; Add-MarkdownLine -Builder $Builder -Text '| --- | --- |'
    foreach ($e in $Values.GetEnumerator()) { Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} |' -f (ConvertTo-MarkdownText $e.Key),(ConvertTo-MarkdownText $e.Value)) }
    Add-MarkdownLine -Builder $Builder
}

function Add-JsonSection {
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Builder, [Parameter(Mandatory)][string]$Title, [int]$HeadingLevel=2, [Parameter(Mandatory)]$Result)
    try {
        $h='#'*$HeadingLevel
        $command = Get-SafePropertyValue -InputObject $Result -Path @('Command')
        $success = Get-SafePropertyValue -InputObject $Result -Path @('Success')
        $errorMessage = Get-SafePropertyValue -InputObject $Result -Path @('ErrorMessage')
        $data = Get-SafePropertyValue -InputObject $Result -Path @('Data')
        Add-MarkdownLine -Builder $Builder -Text ('{0} {1}' -f $h,$Title); Add-MarkdownLine -Builder $Builder -Text ('Command: `{0}`' -f $command); Add-MarkdownLine -Builder $Builder
        if (-not $success) { Add-MarkdownLine -Builder $Builder -Text 'Status: failed'; Add-MarkdownLine -Builder $Builder -Text ('Error: `{0}`' -f (ConvertTo-MarkdownText $errorMessage)); Add-MarkdownLine -Builder $Builder; return }
        if ($null -eq $data) { Add-MarkdownLine -Builder $Builder -Text 'Status: succeeded, but no data was returned.'; Add-MarkdownLine -Builder $Builder; return }
        Add-MarkdownLine -Builder $Builder -Text '```json'; Add-MarkdownLine -Builder $Builder -Text (Protect-Object -InputObject $data | ConvertTo-Json -Depth 100); Add-MarkdownLine -Builder $Builder -Text '```'; Add-MarkdownLine -Builder $Builder
    } catch {
        Write-StatusMessage -Level WARN -Message ("Could not write raw data section '{0}': {1}. Continuing." -f $Title, $_.Exception.Message)
        Add-MarkdownLine -Builder $Builder -Text ('## {0}' -f $Title); Add-MarkdownLine -Builder $Builder -Text ('Status: could not render section. Error: `{0}`' -f (ConvertTo-MarkdownText $_.Exception.Message)); Add-MarkdownLine -Builder $Builder
    }
}

function Add-CollectionStatusSection {
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Builder, [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Results)
    Add-MarkdownLine -Builder $Builder -Text '## Collection Status'; Add-MarkdownLine -Builder $Builder -Text '| Section | Success | Exit Code | Notes |'; Add-MarkdownLine -Builder $Builder -Text '| --- | --- | --- | --- |'
    foreach ($r in $Results) {
        try {
            $label = Get-SafePropertyValue -InputObject $r -Path @('Label')
            $success = Get-SafePropertyValue -InputObject $r -Path @('Success')
            $exitCode = Get-SafePropertyValue -InputObject $r -Path @('ExitCode')
            $errorMessage = Get-SafePropertyValue -InputObject $r -Path @('ErrorMessage')
            $notes = if ($success) { 'Collected' } else { $errorMessage }
            Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} | {2} | {3} |' -f (ConvertTo-MarkdownText $label),$success,$exitCode,(ConvertTo-MarkdownText $notes))
        } catch {
            Write-StatusMessage -Level WARN -Message ("Could not write a collection status row: {0}. Continuing." -f $_.Exception.Message)
            Add-MarkdownLine -Builder $Builder -Text ('| Unknown | False |  | Could not render status row: {0} |' -f (ConvertTo-MarkdownText $_.Exception.Message))
        }
    }
    Add-MarkdownLine -Builder $Builder
}

function Assert-ResourceGroupAvailable {
    param([Parameter(Mandatory)]$AccountResult, [Parameter(Mandatory)][string]$ResourceGroupName)
    $r = Invoke-AzCliCommand -Label 'Resource Group Overview' -Arguments @('group','show','--name',$ResourceGroupName)
    if (-not $r.Success) { Write-Error ("[CRITICAL] Resource group '{0}' was not found. Script will continue but all resource data will be unavailable. Error: {1}" -f $ResourceGroupName, $r.ErrorMessage) }
    return $r
}

# ---------------------------------------------------------------------------
# Performance Efficiency assessment helpers
# ---------------------------------------------------------------------------
function New-PeFinding {
    param([Parameter(Mandatory)][string]$PeArea, [Parameter(Mandatory)][string]$SubArea, [Parameter(Mandatory)][string]$Question,
          [Parameter(Mandatory)][int]$Priority, [ValidateSet('PASS','FAIL','WARN','UNKNOWN','MANUAL')][string]$Status='UNKNOWN', [string]$Notes='')
    [pscustomobject]@{ PeArea=$PeArea; SubArea=$SubArea; Question=$Question; Priority=$Priority; Status=$Status; Notes=$Notes }
}

function Add-PeAssessmentSection {
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Builder, [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Findings)
    $pass=@($Findings|Where-Object{$_.Status-eq'PASS'}).Count; $fail=@($Findings|Where-Object{$_.Status-eq'FAIL'}).Count
    $warn=@($Findings|Where-Object{$_.Status-eq'WARN'}).Count; $unk=@($Findings|Where-Object{$_.Status-eq'UNKNOWN'}).Count; $man=@($Findings|Where-Object{$_.Status-eq'MANUAL'}).Count
    Add-MarkdownLine -Builder $Builder -Text '## Performance Efficiency Assessment'; Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text ('**PASS:** {0} | **FAIL:** {1} | **WARN:** {2} | **UNKNOWN:** {3} | **MANUAL REVIEW REQUIRED:** {4}' -f $pass,$fail,$warn,$unk,$man); Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text '> Status key: **PASS** = confirmed good  |  **FAIL** = confirmed gap  |  **WARN** = partial/potential issue  |  **UNKNOWN** = data unavailable  |  **MANUAL** = cannot determine via az CLI alone'; Add-MarkdownLine -Builder $Builder
    foreach ($sub in ($Findings|Select-Object -ExpandProperty SubArea|Select-Object -Unique)) {
        $grp = $Findings|Where-Object{$_.SubArea-eq$sub}; $area=($grp|Select-Object -First 1).PeArea
        Add-MarkdownLine -Builder $Builder -Text ('### {0} — {1}' -f $area,$sub); Add-MarkdownLine -Builder $Builder
        Add-MarkdownLine -Builder $Builder -Text '| Priority | Status | Question | Notes |'; Add-MarkdownLine -Builder $Builder -Text '| --- | --- | --- | --- |'
        foreach ($f in $grp) {
            $b=switch($f.Status){'PASS'{'✅ PASS'}'FAIL'{'❌ FAIL'}'WARN'{'⚠️ WARN'}'UNKNOWN'{'❓ UNKNOWN'}'MANUAL'{'🔍 MANUAL'}}
            Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} | {2} | {3} |' -f $f.Priority,$b,(ConvertTo-MarkdownText $f.Question),(ConvertTo-MarkdownText $f.Notes))
        }
        Add-MarkdownLine -Builder $Builder
    }
}

function Get-MetricAverage {
    param($MetricResult)
    if (-not $MetricResult.Success -or -not $MetricResult.Data) { return $null }
    $series = $MetricResult.Data
    if (-not ($series -is [System.Array]) -and $series.PSObject.Properties['value']) { $series = $series.value }
    $ts = Get-SafePropertyValue -InputObject @($series)[0] -Path @('timeseries'); if (-not $ts) { return $null }
    $tsData = Get-SafePropertyValue -InputObject @($ts)[0] -Path @('data'); if (-not $tsData) { return $null }
    $values = @(foreach ($dp in @($tsData)) {
        $v = Get-SafePropertyValue -InputObject $dp -Path @('average')
        if ($null -ne $v) { [double]$v }
    })
    if ($values.Count -eq 0) { return $null }
    return [math]::Round(($values | Measure-Object -Average).Average, 1)
}

# ---------------------------------------------------------------------------
# Script entry point
# ---------------------------------------------------------------------------
Test-AzureCliPrerequisites

trap {
    Write-StatusMessage -Level WARN -Message ("Unexpected non-fatal error: {0}. Continuing with the next Performance action." -f $_.Exception.Message)
    continue
}

if (-not (Test-Path -Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }

$results = [System.Collections.Generic.List[object]]::new()
function New-UnavailableResult {
    param([Parameter(Mandatory)][string]$Label, [AllowNull()][object[]]$Arguments, [Parameter(Mandatory)][string]$Message)
    $argumentText = (($Arguments | ForEach-Object { if ($null -eq $_ -or [string]::IsNullOrWhiteSpace([string]$_)) { '<missing>' } else { [string]$_ } }) -join ' ').Trim()
    $commandText = if ($argumentText) { 'az {0}' -f $argumentText } else { 'not run' }
    Write-StatusMessage -Level WARN -Message ("{0}: {1}" -f $Label, $Message)
    [pscustomobject]@{ Label=$Label; Command=$commandText; Success=$false; ExitCode=$null; ErrorMessage=$Message; Data=$null }
}

function Add-QueryResult {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string[]]$Arguments, [switch]$Required)
    try { $r = Invoke-AzCliCommand -Label $Label -Arguments $Arguments -Required:$Required }
    catch { $r = New-UnavailableResult -Label $Label -Arguments $Arguments -Message ("Could not collect this information. {0}" -f $_.Exception.Message) }
    $results.Add($r); return $r
}

function Add-QueryResultWhenValuePresent {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][AllowNull()][object[]]$Arguments, [AllowNull()][string]$Value, [Parameter(Mandatory)][string]$RequiredValueName)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $r = New-UnavailableResult -Label $Label -Arguments $Arguments -Message ("Could not find {0}; {1} was not run." -f $RequiredValueName, $Label)
        $results.Add($r); return $r
    }
    return Add-QueryResult -Label $Label -Arguments $Arguments
}

Write-StatusMessage -Level INFO -Message ("Starting performance efficiency review for [{0}] and MySQL [{1}] in [{2}]" -f $AppServiceName,$MySqlServerName,$ResourceGroup)

$metricStart = (Get-Date).AddDays(-$MetricLookbackDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
$metricEnd   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')

# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------
$account         = Add-QueryResult -Label 'Azure Account'              -Arguments @('account','show') -Required
$rgResult        = Assert-ResourceGroupAvailable -AccountResult $account -ResourceGroupName $ResourceGroup
$results.Add($rgResult)

$webApp          = Add-QueryResult -Label 'App Service Overview'        -Arguments @('webapp','show','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Required
$webAppId        = Get-SafePropertyValue -InputObject $webApp.Data -Path @('id')
$planId          = Get-SafePropertyValue -InputObject $webApp.Data -Path @('serverFarmId')
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('appServicePlanId') }
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('properties', 'serverFarmId') }
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('properties', 'appServicePlanId') }
if (-not $webAppId) { Write-StatusMessage -Level WARN -Message 'Could not find App Service resource ID. Dependent App Service metric and diagnostic data will be marked unavailable.' }
if (-not $planId) { Write-StatusMessage -Level WARN -Message 'Could not find App Service plan ID. Plan and autoscale details will be marked unavailable.' }

$siteConfig      = Add-QueryResult -Label 'App Service Site Config'     -Arguments @('webapp','config','show','--name',$AppServiceName,'--resource-group',$ResourceGroup)
$appSettings     = Add-QueryResult -Label 'App Service App Settings'    -Arguments @('webapp','config','appsettings','list','--name',$AppServiceName,'--resource-group',$ResourceGroup)
$slots           = Add-QueryResult -Label 'App Service Deployment Slots'-Arguments @('webapp','deployment','slot','list','--name',$AppServiceName,'--resource-group',$ResourceGroup)
$hostnameBindings= Add-QueryResult -Label 'App Service Hostname Bindings'-Arguments @('webapp','config','hostname','list','--webapp-name',$AppServiceName,'--resource-group',$ResourceGroup)
$null            = Add-QueryResult -Label 'App Service Health Check'    -Arguments @('webapp','show','--name',$AppServiceName,'--resource-group',$ResourceGroup,'--query','siteConfig.healthCheckPath')

# App Service Plan
$plan = $null; $autoscaleSettings = $null; $allPlansInRg = $null
if ($planId) {
    $planParts = $planId.Trim('/') -split '/'
    $planName=$null; $planRg=$ResourceGroup
    for ($i=0;$i -lt $planParts.Length;$i+=2) {
        if ($planParts[$i]-eq'serverfarms'  -and($i+1)-lt$planParts.Length) { $planName=$planParts[$i+1] }
        if ($planParts[$i]-eq'resourceGroups'-and($i+1)-lt$planParts.Length) { $planRg=$planParts[$i+1] }
    }
    if ($planName) {
        $plan             = Add-QueryResult -Label 'App Service Plan Overview'    -Arguments @('appservice','plan','show','--name',$planName,'--resource-group',$planRg)
        $allPlansInRg     = Add-QueryResult -Label 'All App Service Plans in RG'  -Arguments @('appservice','plan','list','--resource-group',$ResourceGroup)
        $autoscaleSettings= Add-QueryResult -Label 'App Service Autoscale'       -Arguments @('monitor','autoscale','list','--resource-group',$ResourceGroup)
    }
}

# App Insights detection — use resource list (fast, no extension required) instead of app-insights CLI extension
$appInsightsResult = Add-QueryResult -Label 'Application Insights Components' -Arguments @('resource','list','--resource-group',$ResourceGroup,'--resource-type','microsoft.insights/components')

# App Service metrics
$appCpuMetrics = Add-QueryResultWhenValuePresent -Label 'App Service CPU Metrics' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','metrics','list','--resource',$webAppId,'--metric','CpuPercentage','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)
$appMemMetrics = Add-QueryResultWhenValuePresent -Label 'App Service Memory Metrics' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','metrics','list','--resource',$webAppId,'--metric','MemoryWorkingSet','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)
$appReqMetrics = Add-QueryResultWhenValuePresent -Label 'App Service Requests Metrics' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','metrics','list','--resource',$webAppId,'--metric','Requests','--interval','PT1H','--aggregation','Total','--start-time',$metricStart,'--end-time',$metricEnd)
$appHttp5xx    = Add-QueryResultWhenValuePresent -Label 'App Service HTTP 5xx Metrics' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','metrics','list','--resource',$webAppId,'--metric','Http5xx','--interval','PT1H','--aggregation','Total','--start-time',$metricStart,'--end-time',$metricEnd)
$appAlertRules = Add-QueryResult -Label 'App Service Alert Rules'      -Arguments @('monitor','metrics','alert','list','--resource-group',$ResourceGroup)

# MySQL
$mysqlServer     = Add-QueryResult -Label 'MySQL Flexible Server Overview' -Arguments @('mysql','flexible-server','show','--name',$MySqlServerName,'--resource-group',$ResourceGroup) -Required
$mysqlServerId   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('id')
if (-not $mysqlServerId) { Write-StatusMessage -Level WARN -Message 'Could not find MySQL Flexible Server resource ID. Dependent MySQL metric and diagnostic data will be marked unavailable.' }
$mysqlReplicas   = Add-QueryResult -Label 'MySQL Replicas'                  -Arguments @('mysql','flexible-server','replica','list','--name',$MySqlServerName,'--resource-group',$ResourceGroup)

# Key MySQL parameters for performance
$paramInnodbBuf      = Add-QueryResult -Label 'MySQL: innodb_buffer_pool_size'     -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','innodb_buffer_pool_size')
$paramInnodbFilePer  = Add-QueryResult -Label 'MySQL: innodb_file_per_table'       -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','innodb_file_per_table')
$paramInnodbLog      = Add-QueryResult -Label 'MySQL: innodb_log_file_size'        -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','innodb_log_file_size')
$paramSlowQuery      = Add-QueryResult -Label 'MySQL: slow_query_log'              -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','slow_query_log')
$paramLogNoIndex     = Add-QueryResult -Label 'MySQL: log_queries_not_using_indexes' -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','log_queries_not_using_indexes')
$paramMaxConn        = Add-QueryResult -Label 'MySQL: max_connections'             -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','max_connections')
$paramInnodbTmpDir   = Add-QueryResult -Label 'MySQL: innodb_tmpdir'               -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','innodb_tmpdir')
$paramLongQueryTime  = Add-QueryResult -Label 'MySQL: long_query_time'             -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','long_query_time')
$paramMaintenanceWin = Add-QueryResult -Label 'MySQL: maintenance_window'          -Arguments @('mysql','flexible-server','show','--name',$MySqlServerName,'--resource-group',$ResourceGroup,'--query','maintenanceWindow')

# MySQL metrics
$mysqlCpuMetrics  = Add-QueryResultWhenValuePresent -Label 'MySQL CPU Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','metrics','list','--resource',$mysqlServerId,'--metric','cpu_percent','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)
$mysqlMemMetrics  = Add-QueryResultWhenValuePresent -Label 'MySQL Memory Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','metrics','list','--resource',$mysqlServerId,'--metric','memory_percent','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)
$mysqlIoMetrics   = Add-QueryResultWhenValuePresent -Label 'MySQL IO Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','metrics','list','--resource',$mysqlServerId,'--metric','io_consumption_percent','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)
$mysqlConnMetrics = Add-QueryResultWhenValuePresent -Label 'MySQL Connections Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','metrics','list','--resource',$mysqlServerId,'--metric','active_connections','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)
$mysqlDiagSettings= Add-QueryResultWhenValuePresent -Label 'MySQL Diagnostic Settings' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','diagnostic-settings','list','--resource',$mysqlServerId)
$appDiagSettings  = Add-QueryResultWhenValuePresent -Label 'App Service Diagnostic Settings' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','diagnostic-settings','list','--resource',$webAppId)

# Supporting infrastructure
$afdRg       = if ($AfdResourceGroup) { $AfdResourceGroup } else { $ResourceGroup }
$afdProfiles = Add-QueryResult -Label 'Azure Front Door Profiles'   -Arguments @('afd','profile','list','--resource-group',$afdRg)
$cdnProfiles = Add-QueryResult -Label 'Azure CDN Profiles'          -Arguments @('cdn','profile','list','--resource-group',$ResourceGroup)
$redisList   = Add-QueryResult -Label 'Redis Instances'             -Arguments @('redis','list','--resource-group',$ResourceGroup)
$storagAccts = Add-QueryResult -Label 'Storage Accounts'            -Arguments @('storage','account','list','--resource-group',$ResourceGroup)
$appGateways = Add-QueryResult -Label 'Application Gateways'        -Arguments @('network','application-gateway','list','--resource-group',$ResourceGroup)
$logAnalytics= Add-QueryResult -Label 'Log Analytics Workspaces'    -Arguments @('monitor','log-analytics','workspace','list','--resource-group',$ResourceGroup)
$serviceBus  = Add-QueryResult -Label 'Service Bus Namespaces'      -Arguments @('servicebus','namespace','list','--resource-group',$ResourceGroup)

# ---------------------------------------------------------------------------
# Assess findings
# ---------------------------------------------------------------------------
$findings = [System.Collections.Generic.List[object]]::new()

$avgAppCpu  = Get-MetricAverage -MetricResult $appCpuMetrics
$avgMysqlCpu= Get-MetricAverage -MetricResult $mysqlCpuMetrics
$avgMysqlMem= Get-MetricAverage -MetricResult $mysqlMemMetrics
$avgMysqlIo = Get-MetricAverage -MetricResult $mysqlIoMetrics

# Helper to get app setting value
function Get-AppSettingValue {
    param([string]$Name)
    if (-not $appSettings.Success -or -not $appSettings.Data) { return $null }
    $s = @($appSettings.Data | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    if ($s) { return $s.value } else { return $null }
}

# ---- PE:03 Select the Right Services and Tiers ----
if ($plan -and $plan.Success -and $plan.Data) {
    $tier = Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','tier')
    $size = Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','name')
    if ($tier -match 'PremiumV3|P1v3|P2v3|P3v3|Premium') {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is the Premium v3 (Pv3) tier used for production WordPress?' -Priority 3 -Status 'PASS' -Notes ("Tier = {0}; Size = {1}." -f $tier,$size)))
    } elseif ($tier -match 'Free|Shared|Basic') {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is the Premium v3 (Pv3) tier used for production WordPress?' -Priority 3 -Status 'FAIL' -Notes ("Tier = {0}; Size = {1}. Free/Shared/Basic tiers are not recommended for production WordPress — no dedicated compute, no SLA." -f $tier,$size)))
    } else {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is the Premium v3 (Pv3) tier used for production WordPress?' -Priority 3 -Status 'WARN' -Notes ("Tier = {0}; Size = {1}. Not Premium v3 — confirm this meets WordPress performance requirements." -f $tier,$size)))
    }
    $dedicated = $tier -notmatch 'Free|Shared'
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is dedicated compute (Standard or Premium) used — avoiding Free/Shared tiers?' -Priority 3 -Status $(if($dedicated){'PASS'}else{'FAIL'}) -Notes ("Tier = {0}. {1}" -f $tier,$(if($dedicated){'Dedicated compute is in use.'}else{'Free/Shared tiers share compute — not suitable for production.'}))))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is the Premium v3 (Pv3) tier used for production WordPress?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve App Service plan.'))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is dedicated compute (Standard or Premium) used — avoiding Free/Shared tiers?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve App Service plan.'))
}

if ($siteConfig.Success -and $siteConfig.Data) {
    $alwaysOn = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('alwaysOn')
    $http2    = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('http20Enabled')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is Always On enabled to prevent PHP cold-start latency?' -Priority 3 -Status $(if($alwaysOn){'PASS'}else{'FAIL'}) -Notes ("alwaysOn = {0}." -f $alwaysOn)))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is HTTP/2 enabled for improved protocol efficiency?' -Priority 3 -Status $(if($http2){'PASS'}else{'FAIL'}) -Notes ("http20Enabled = {0}." -f $http2)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is Always On enabled to prevent PHP cold-start latency?' -Priority 3 -Status 'UNKNOWN' -Notes 'Site config unavailable.'))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is HTTP/2 enabled for improved protocol efficiency?' -Priority 3 -Status 'UNKNOWN' -Notes 'Site config unavailable.'))
}

if ($mysqlServer.Success -and $mysqlServer.Data) {
    $skuTier = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','tier')
    $skuName = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','name')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is the General Purpose tier used for standard production MySQL workloads?' -Priority 3 -Status $(if($skuTier -eq 'GeneralPurpose'){'PASS'}elseif($skuTier -eq 'MemoryOptimized'){'PASS'}else{'WARN'}) -Notes ("MySQL SKU tier = {0} ({1}). General Purpose or Memory Optimized are recommended for production." -f $skuTier,$skuName)))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is the Burstable tier limited to development and test environments only?' -Priority 3 -Status $(if($skuTier -eq 'Burstable'){'WARN'}else{'PASS'}) -Notes ("MySQL SKU tier = {0}. {1}" -f $skuTier,$(if($skuTier-eq'Burstable'){'Burstable tier detected — confirm this is not a production workload.'}else{'Not Burstable — appropriate for production.'}))))
    $iops    = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','iops')
    $autoIo  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','autoIoScaling')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Have IOPS limits been verified to scale with compute size?' -Priority 3 -Status 'MANUAL' -Notes ("provisioned IOPS = {0}; autoIoScaling = {1}. Verify IOPS is sufficient for the WordPress write volume. Review io_consumption_percent metric." -f $iops,$autoIo)))
}

# ---- PE:04 Performance Measurement and Monitoring ----
# App Insights
$hasAppInsights = $false
if ($appSettings.Success -and $appSettings.Data) {
    $aiKey    = @($appSettings.Data|Where-Object{$_.name -match 'APPINSIGHTS_INSTRUMENTATIONKEY|APPLICATIONINSIGHTS_CONNECTION_STRING'}) | Select-Object -First 1
    $hasAppInsights = $null -ne $aiKey
}
if (-not $hasAppInsights -and $appInsightsResult.Success -and $appInsightsResult.Data -and @($appInsightsResult.Data).Count -gt 0) { $hasAppInsights = $true }
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Is Application Insights enabled for end-to-end transaction tracing?' -Priority 2 -Status $(if($hasAppInsights){'PASS'}else{'FAIL'}) -Notes $(if($hasAppInsights){'Application Insights connection detected in app settings or component.'}else{'No Application Insights instrumentation key or connection string found in app settings.'})))

# Alert rules for response time / CPU
if ($appAlertRules.Success -and $appAlertRules.Data -and @($appAlertRules.Data).Count -gt 0) {
    $alertNames = (@($appAlertRules.Data)|ForEach-Object{$_.name}) -join ', '
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Are Azure Monitor alerts set on response time, request queue depth, and CPU/memory thresholds?' -Priority 2 -Status 'MANUAL' -Notes ("{0} alert rule(s) found: {1}. Confirm alerts cover response time, CPU, memory, and HTTP error rates." -f @($appAlertRules.Data).Count,$alertNames)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Are Azure Monitor alerts set on response time, request queue depth, and CPU/memory thresholds?' -Priority 2 -Status 'FAIL' -Notes 'No metric alert rules found in resource group. Create alerts for CpuPercentage, MemoryWorkingSet, Http5xx, AverageResponseTime, and RequestQueueLength.'))
}

# Log Analytics for slow query log routing
$mysqlLogsToLa = $false
if ($mysqlDiagSettings.Success -and $mysqlDiagSettings.Data -and @($mysqlDiagSettings.Data).Count -gt 0) {
    $slowLogDiag = @($mysqlDiagSettings.Data | ForEach-Object { $_.logs | Where-Object { $_.category -eq 'MySqlSlowLogs' -and $_.enabled -eq $true } })
    $mysqlLogsToLa = $slowLogDiag.Count -gt 0
}
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Is Log Analytics used for historical trend analysis via KQL queries on MySqlSlowLogs?' -Priority 2 -Status $(if($mysqlLogsToLa){'PASS'}else{'FAIL'}) -Notes $(if($mysqlLogsToLa){'MySqlSlowLogs routing to Log Analytics found in diagnostic settings.'}else{'No diagnostic settings found routing MySqlSlowLogs to Log Analytics.'})))

# Slow_queries count tracked — slow_query_log
$slqVal = if($paramSlowQuery.Success -and $paramSlowQuery.Data){Get-SafePropertyValue -InputObject $paramSlowQuery.Data -Path @('value')}else{$null}
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Is the Slow_queries count tracked?' -Priority 3 -Status $(if($slqVal-eq'ON'){'PASS'}elseif($null-eq$slqVal){'UNKNOWN'}else{'FAIL'}) -Notes ("slow_query_log = {0}." -f $slqVal)))

# CPU / memory metrics for App Service
if ($null -ne $avgAppCpu) {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Are key App Service metrics captured: CPU, memory, response time, HTTP rates?' -Priority 3 -Status 'PASS' -Notes ("Metric data available. Avg CPU over {0} days = {1}%." -f $MetricLookbackDays,$avgAppCpu)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Are key App Service metrics captured: CPU, memory, response time, HTTP rates?' -Priority 3 -Status 'UNKNOWN' -Notes 'No metric data returned for App Service CPU. Diagnostic settings may not be configured.'))
}

# App Service instance count / autoscale events (checked via autoscale settings)
if ($autoscaleSettings -and $autoscaleSettings.Success -and $autoscaleSettings.Data) {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Is App Service plan instance count monitored with autoscale events correlated?' -Priority 3 -Status 'MANUAL' -Notes ("{0} autoscale setting(s) found in resource group. Confirm Azure Monitor tracks scale events and they are correlated with performance data." -f @($autoscaleSettings.Data).Count)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Is App Service plan instance count monitored with autoscale events correlated?' -Priority 3 -Status 'FAIL' -Notes 'No autoscale settings found — no autoscale events to monitor.'))
}

# MySQL metrics available
if ($null -ne $avgMysqlCpu) {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Are MySQL CPU, Memory, and Storage IO monitored for saturation?' -Priority 3 -Status $(if($avgMysqlCpu -gt 80 -or $avgMysqlIo -gt 80){'WARN'}else{'PASS'}) -Notes ("Avg MySQL CPU = {0}%; Avg Memory = {1}%; Avg IO = {2}% over {3} days." -f $avgMysqlCpu,$avgMysqlMem,$avgMysqlIo,$MetricLookbackDays)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:04 Performance Measurement and Monitoring' -Question 'Are MySQL CPU, Memory, and Storage IO monitored for saturation?' -Priority 3 -Status 'UNKNOWN' -Notes 'No MySQL metric data available.'))
}

# ---- PE:05 Scaling and Partitioning ----
if ($autoscaleSettings -and $autoscaleSettings.Success -and $autoscaleSettings.Data -and @($autoscaleSettings.Data).Count -gt 0) {
    $appPlanAs = @($autoscaleSettings.Data|Where-Object{(Get-SafePropertyValue -InputObject $_ -Path @('targetResourceUri')) -like "*$planId*"})
    if ($appPlanAs.Count -gt 0) {
        $as = $appPlanAs[0]
        $minInst     = try { [int]@($as.profiles)[0].capacity.minimum } catch { $null }
        $maxInst     = try { [int]@($as.profiles)[0].capacity.maximum } catch { $null }
        $rules       = try { @(@($as.profiles)[0].rules) } catch { @() }
        $scaleOutRules= @($rules|Where-Object{(Get-SafePropertyValue -InputObject $_ -Path @('scaleAction','direction')) -eq 'Increase'})
        $scaleInRules = @($rules|Where-Object{(Get-SafePropertyValue -InputObject $_ -Path @('scaleAction','direction')) -eq 'Decrease'})
        # Check for ~65% CPU scale-out trigger
        $cpu65Rule = @($scaleOutRules|Where-Object{
            $thresh = Get-SafePropertyValue -InputObject $_ -Path @('metricTrigger','threshold')
            $metric = Get-SafePropertyValue -InputObject $_ -Path @('metricTrigger','metricName')
            $metric -match 'CpuPercentage' -and [double]$thresh -ge 55 -and [double]$thresh -le 75
        })
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is autoscaling configured based on CPU, memory, or request queue depth?' -Priority 3 -Status 'PASS' -Notes ("Autoscale configured. Min = {0}; Max = {1}; Scale-out rules = {2}; Scale-in rules = {3}." -f $minInst,$maxInst,$scaleOutRules.Count,$scaleInRules.Count)))
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is the scale-out trigger set at ~65% CPU?' -Priority 3 -Status $(if($cpu65Rule.Count-gt0){'PASS'}else{'WARN'}) -Notes $(if($cpu65Rule.Count-gt0){'Scale-out rule with CPU threshold 55-75% found.'}else{'No CPU scale-out rule found in the 55-75% range. Review autoscale rules.'})))
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Are scale-in rules defined?' -Priority 3 -Status $(if($scaleInRules.Count-gt0){'PASS'}else{'FAIL'}) -Notes ("{0} scale-in rule(s) found." -f $scaleInRules.Count)))
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is the maximum instance count defined within App Service plan limits?' -Priority 3 -Status $(if($null-ne$maxInst-and$maxInst-gt1){'PASS'}else{'WARN'}) -Notes ("Max instances = {0}." -f $maxInst)))
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Have autoscaling rules been tested with load simulations?' -Priority 3 -Status 'MANUAL' -Notes ("Autoscale defined. Confirm load tests have been run to verify scale-out and scale-in behaviour, and that warm-up time has been accounted for." )))
    } else {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is autoscaling configured based on CPU, memory, or request queue depth?' -Priority 3 -Status 'FAIL' -Notes 'No autoscale settings found targeting the App Service plan.'))
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is the scale-out trigger set at ~65% CPU?' -Priority 3 -Status 'FAIL' -Notes 'No autoscale configured.'))
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Are scale-in rules defined?' -Priority 3 -Status 'FAIL' -Notes 'No autoscale configured.'))
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is the maximum instance count defined within App Service plan limits?' -Priority 3 -Status 'FAIL' -Notes 'No autoscale configured.'))
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Have autoscaling rules been tested with load simulations?' -Priority 3 -Status 'FAIL' -Notes 'No autoscale configured — nothing to test.'))
    }
} else {
    foreach ($q in @('Is autoscaling configured based on CPU, memory, or request queue depth?','Is the scale-out trigger set at ~65% CPU?','Are scale-in rules defined?','Is the maximum instance count defined within App Service plan limits?','Have autoscaling rules been tested with load simulations?')) {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question $q -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve autoscale settings.'))
    }
}

# ARR affinity
if ($webApp.Success -and $webApp.Data) {
    $clientAffinity = Get-SafePropertyValue -InputObject $webApp.Data -Path @('clientAffinityEnabled')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is ARR affinity disabled to evenly distribute requests?' -Priority 3 -Status $(if($clientAffinity-eq$false){'PASS'}else{'FAIL'}) -Notes ("clientAffinityEnabled = {0}. {1}" -f $clientAffinity,$(if($clientAffinity-eq$false){'ARR affinity is disabled — good for stateless scaling.'}else{'ARR affinity is enabled — routes sessions to the same instance, limiting autoscale effectiveness.'}))))
}

# MySQL autoscale IOPS
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $autoIo = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','autoIoScaling')
    $iops   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','iops')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is autoscale IOPS used for variable WordPress traffic?' -Priority 3 -Status $(if($autoIo-eq'Enabled'){'PASS'}else{'WARN'}) -Notes ("autoIoScaling = {0}; provisioned IOPS = {1}." -f $autoIo,$iops)))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is pre-provisioned IOPS used for steady predictable workloads?' -Priority 3 -Status $(if($autoIo-eq'Disabled'-or$null-eq$autoIo){'PASS'}else{'MANUAL'}) -Notes ("autoIoScaling = {0}; provisioned IOPS = {1}. {2}" -f $autoIo,$iops,$(if($autoIo-eq'Enabled'){'Autoscale IOPS in use — for steady workloads, pre-provisioned may be more predictable.'}else{'Pre-provisioned IOPS in use.'}))))

    # Read replicas
    $replicaCount = if($mysqlReplicas.Success -and $mysqlReplicas.Data){@($mysqlReplicas.Data).Count}else{0}
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is a connection proxy used to distribute read traffic?' -Priority 3 -Status 'MANUAL' -Notes ("Replica count = {0}. Confirm whether a read proxy or WordPress plugin routes SELECT queries to replicas." -f $replicaCount)))

    # HA zone separation
    $haMode = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','mode')
    $standbyZone = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','standbyAvailabilityZone')
    $primaryZone = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('availabilityZone')
    if ($haMode -eq 'ZoneRedundant') {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'For HA-enabled servers, is scaling performed on the standby first?' -Priority 3 -Status 'MANUAL' -Notes ("HA = ZoneRedundant; primary AZ = {0}; standby AZ = {1}. Confirm that compute tier scale operations are performed on the standby before the primary." -f $primaryZone,$standbyZone)))
    } else {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'For HA-enabled servers, is scaling performed on the standby first?' -Priority 3 -Status 'MANUAL' -Notes ("HA mode = {0}. Zone-redundant HA is not enabled — review if this is intentional." -f $haMode)))
    }
}

# ---- PE:07 Optimise Code and Infrastructure ----
# OPcache
if ($appSettings.Success -and $appSettings.Data) {
    $runFromPkg = Get-AppSettingValue -Name 'WEBSITE_RUN_FROM_PACKAGE'
    $disableWpCron = Get-AppSettingValue -Name 'DISABLE_WP_CRON'
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is PHP OPcache enabled on App Service?' -Priority 3 -Status 'MANUAL' -Notes 'OPcache is enabled by default on Azure App Service PHP. Confirm opcache.enable=1 via phpinfo() or App Service PHP configuration and tune opcache.memory_consumption and opcache.max_accelerated_files for the WordPress codebase.'))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is FastCGI page caching enabled for anonymous visitors?' -Priority 3 -Status 'MANUAL' -Notes 'Cannot determine FastCGI/page cache from az CLI. Check App Service PHP configuration and WordPress caching plugin (W3 Total Cache, WP Super Cache, LiteSpeed Cache).'))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Has WordPress wp-cron been offloaded to an external scheduler?' -Priority 3 -Status $(if($disableWpCron-eq'true'){'PASS'}else{'FAIL'}) -Notes ("DISABLE_WP_CRON = {0}. {1}" -f $disableWpCron,$(if($disableWpCron-eq'true'){'wp-cron is disabled — ensure an external scheduler triggers wp-cron.php.'}else{'DISABLE_WP_CRON not set. wp-cron runs on every page request, adding CPU overhead.'}))))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is WEBSITE_RUN_FROM_PACKAGE=1 configured?' -Priority 3 -Status $(if($runFromPkg-eq'1'){'PASS'}else{'FAIL'}) -Notes ("WEBSITE_RUN_FROM_PACKAGE = {0}. Read-only filesystem from ZIP package improves cold-start and prevents file-level drift." -f $runFromPkg)))
} else {
    foreach ($q in @('Is PHP OPcache enabled on App Service?','Is FastCGI page caching enabled for anonymous visitors?','Has WordPress wp-cron been offloaded to an external scheduler?','Is WEBSITE_RUN_FROM_PACKAGE=1 configured?')) {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question $q -Priority 3 -Status 'UNKNOWN' -Notes 'App settings unavailable.'))
    }
}

# Redis
$hasRedis = $redisList.Success -and $redisList.Data -and @($redisList.Data).Count -gt 0
$redisAppSetting = if($appSettings.Success -and $appSettings.Data){@($appSettings.Data|Where-Object{$_.name -match 'REDIS|WP_REDIS|OBJECT_CACHE'})|Select-Object -First 1}else{$null}
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is WordPress object caching backed by Azure Cache for Redis?' -Priority 2 -Status $(if($hasRedis-and$null-ne$redisAppSetting){'MANUAL'}elseif($hasRedis){'WARN'}else{'FAIL'}) -Notes $(if($hasRedis){"Redis instance(s): {0}. Redis app setting found = {1}. Confirm the WordPress Redis Object Cache plugin is active." -f ((@($redisList.Data)|ForEach-Object{$_.name})-join', '),$null-ne$redisAppSetting}else{'No Redis instances found in resource group. WordPress object caching defaults to database — consider Azure Cache for Redis.'})))

# CDN / AFD
$hasCdn = ($afdProfiles.Success -and $afdProfiles.Data -and @($afdProfiles.Data).Count-gt 0) -or ($cdnProfiles.Success -and $cdnProfiles.Data -and @($cdnProfiles.Data).Count-gt 0)
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Are static assets served from Azure CDN / Azure Front Door?' -Priority 3 -Status $(if($hasCdn){'MANUAL'}else{'FAIL'}) -Notes $(if($hasCdn){'CDN/AFD profile found. Confirm WordPress is configured to serve static assets through CDN.'}else{'No AFD or CDN profiles found. Static assets served directly from App Service increase response time and origin load.'})))

# Storage for media
$hasStorage = $storagAccts.Success -and $storagAccts.Data -and @($storagAccts.Data).Count-gt 0
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is WordPress media stored in Azure Blob Storage with CDN delivery?' -Priority 2 -Status $(if($hasStorage -and $hasCdn){'MANUAL'}elseif($hasStorage){'WARN'}else{'FAIL'}) -Notes $(if($hasStorage-and$hasCdn){'Storage account and CDN/AFD found. Confirm WordPress media is stored in Blob and delivered via CDN.'}elseif($hasStorage){'Storage account found but no CDN. Media delivery lacks CDN acceleration.'}else{'No storage accounts found. WordPress media may be on App Service filesystem.'})))

# innodb_buffer_pool_size
if ($paramInnodbBuf.Success -and $paramInnodbBuf.Data) {
    $bufSize  = Get-SafePropertyValue -InputObject $paramInnodbBuf.Data -Path @('value')
    $bufBytes = try{[long]$bufSize}catch{$null}
    $bufMb    = if ($null -ne $bufBytes) { [math]::Round($bufBytes/1MB,0) } else { 'unknown' }
    $skuName  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','name')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is innodb_buffer_pool_size set to the maximum the SKU supports?' -Priority 3 -Status 'MANUAL' -Notes ("innodb_buffer_pool_size = {0} bytes (~{1} MB); MySQL SKU = {2}. Set this to 70-80% of total RAM for the selected SKU for maximum cache hit rate." -f $bufSize,$bufMb,$skuName)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is innodb_buffer_pool_size set to the maximum the SKU supports?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve innodb_buffer_pool_size.'))
}

if ($paramInnodbFilePer.Success -and $paramInnodbFilePer.Data) {
    $val = Get-SafePropertyValue -InputObject $paramInnodbFilePer.Data -Path @('value')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is innodb_file_per_table enabled?' -Priority 3 -Status $(if($val-eq'ON'){'PASS'}else{'FAIL'}) -Notes ("innodb_file_per_table = {0}. Enabled reduces fragmentation and allows OPTIMIZE TABLE to reclaim space." -f $val)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is innodb_file_per_table enabled?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve innodb_file_per_table.'))
}

if ($paramInnodbLog.Success -and $paramInnodbLog.Data) {
    $val = Get-SafePropertyValue -InputObject $paramInnodbLog.Data -Path @('value')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is innodb_log_file_size tuned based on write volume?' -Priority 3 -Status 'MANUAL' -Notes ("innodb_log_file_size = {0} bytes (~{1} MB). For write-heavy WordPress sites, increase to 256MB-1GB to reduce checkpoint frequency." -f $val,[math]::Round([double]$val/1MB,0))))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is innodb_log_file_size tuned based on write volume?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve innodb_log_file_size.'))
}

# innodb_tmpdir
if ($paramInnodbTmpDir.Success -and $paramInnodbTmpDir.Data) {
    $val = Get-SafePropertyValue -InputObject $paramInnodbTmpDir.Data -Path @('value')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is innodb_tmpdir set to /mnt/temp for SSD-speed temporary sort operations?' -Priority 3 -Status $(if($val-match'/mnt/temp'){'PASS'}else{'WARN'}) -Notes ("innodb_tmpdir = '{0}'. Set to /mnt/temp to use the SSD-backed temp volume for sort and group-by operations." -f $val)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is innodb_tmpdir set to /mnt/temp for SSD-speed temporary sort operations?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve innodb_tmpdir.'))
}

# accelerated logs
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $accLogs = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','logOnDisk')
    $skuTier  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','tier')
    if ($skuTier -eq 'Burstable') {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is accelerated logs enabled on MySQL?' -Priority 3 -Status 'MANUAL' -Notes ("MySQL SKU tier = {0}. Accelerated logs are only available on General Purpose and Memory Optimized tiers." -f $skuTier)))
    } else {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is accelerated logs enabled on MySQL?' -Priority 3 -Status 'MANUAL' -Notes ("logOnDisk = {0} (accelerated logs = logOnDisk not set to true). Check MySQL server blade in portal — accelerated logs may require explicit enablement for GP/MO tiers." -f $accLogs)))
    }
}

# Connection pooling
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is connection pooling set up at proxy or application layer?' -Priority 2 -Status 'MANUAL' -Notes ("Redis present = {0}; Service Bus present = {1}. Confirm connection pooling is configured via ProxySQL, application-level pooling (PDO persistent connections), or a sidecar proxy." -f $hasRedis,($serviceBus.Success -and $serviceBus.Data -and @($serviceBus.Data).Count-gt 0))))

# max_connections
if ($paramMaxConn.Success -and $paramMaxConn.Data) {
    $maxConn = Get-SafePropertyValue -InputObject $paramMaxConn.Data -Path @('value')
    $avgConn = Get-MetricAverage -MetricResult $mysqlConnMetrics
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is MySQL max_connections configured to reflect actual WordPress concurrency needs?' -Priority 3 -Status $(if($null-ne$avgConn-and[int]$avgConn-gt([int]$maxConn*0.8)){'WARN'}else{'MANUAL'}) -Notes ("max_connections = {0}; avg active connections over {1} days = {2}. Connections above 80% of max_connections risk connection exhaustion." -f $maxConn,$MetricLookbackDays,$avgConn)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:07 Optimise Code and Infrastructure' -Question 'Is MySQL max_connections configured to reflect actual WordPress concurrency needs?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve max_connections.'))
}

# ---- PE:08 Optimise Data Performance ----
if ($paramLogNoIndex.Success -and $paramLogNoIndex.Data) {
    $val = Get-SafePropertyValue -InputObject $paramLogNoIndex.Data -Path @('value')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:08 Optimise Data Performance' -Question 'Is log_queries_not_using_indexes enabled?' -Priority 3 -Status $(if($val-eq'ON'){'PASS'}else{'FAIL'}) -Notes ("log_queries_not_using_indexes = {0}. Enable to capture queries missing indexes in slow query log." -f $val)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:08 Optimise Data Performance' -Question 'Is log_queries_not_using_indexes enabled?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve log_queries_not_using_indexes.'))
}

if ($slqVal) {
    $lqtVal = if($paramLongQueryTime.Success -and $paramLongQueryTime.Data){Get-SafePropertyValue -InputObject $paramLongQueryTime.Data -Path @('value')}else{'unknown'}
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:08 Optimise Data Performance' -Question 'Have WordPress database indexes been reviewed using slow query logs?' -Priority 2 -Status $(if($slqVal-eq'ON'){'MANUAL'}else{'FAIL'}) -Notes ("slow_query_log = {0}; long_query_time = {1}s. {2}" -f $slqVal,$lqtVal,$(if($slqVal-eq'ON'){'Slow query logging enabled. Review MySqlSlowLogs in Log Analytics to identify missing indexes.'}else{'Enable slow_query_log to identify queries that would benefit from indexes.'}))))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:08 Optimise Data Performance' -Question 'Have WordPress database indexes been reviewed using slow query logs?' -Priority 2 -Status 'UNKNOWN' -Notes 'Could not retrieve slow_query_log parameter.'))
}

$maxConnVal = if($paramMaxConn.Success -and $paramMaxConn.Data){Get-SafePropertyValue -InputObject $paramMaxConn.Data -Path @('value')}else{'unknown'}
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:08 Optimise Data Performance' -Question 'Is MySQL max_connections configured to reflect actual WordPress concurrency needs?' -Priority 3 -Status 'MANUAL' -Notes ("max_connections = {0}. Verify this reflects actual WordPress + connection pool concurrency needs." -f $maxConnVal)))

# ---- PE:09 Prioritise Critical Flows ----
# Health check
if ($siteConfig.Success -and $siteConfig.Data) {
    $hcPath = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('healthCheckPath')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:09 Prioritise Critical Flows' -Question 'Is the App Service health check configured to probe the critical WordPress flow path?' -Priority 3 -Status $(if([string]::IsNullOrWhiteSpace($hcPath)){'FAIL'}else{'PASS'}) -Notes ("healthCheckPath = '{0}'." -f $hcPath)))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:09 Prioritise Critical Flows' -Question 'Is the App Service health check configured to probe the critical WordPress flow path?' -Priority 3 -Status 'UNKNOWN' -Notes 'Site config unavailable.'))
}

# AFD / App Gateway for routing critical flows
$hasGateway = ($appGateways.Success -and $appGateways.Data -and @($appGateways.Data).Count-gt 0)
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:09 Prioritise Critical Flows' -Question 'Is Azure Front Door or Application Gateway used to route critical flows to healthy instances?' -Priority 3 -Status $(if($hasCdn -or $hasGateway){'MANUAL'}else{'FAIL'}) -Notes $(if($hasCdn){'AFD profile found. Confirm routing rules prioritise critical WordPress flows.'}elseif($hasGateway){'Application Gateway found. Confirm routing rules prioritise critical flows.'}else{'No AFD or Application Gateway detected. Without a reverse proxy, no global health-based routing is possible.'})))

# Queue-based load levelling
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:09 Prioritise Critical Flows' -Question 'Is Queue-Based Load Levelling used for non-critical background tasks?' -Priority 3 -Status $(if($serviceBus.Success -and $serviceBus.Data -and @($serviceBus.Data).Count-gt 0){'MANUAL'}else{'MANUAL'}) -Notes ("Service Bus found = {0}. Confirm background tasks (email, media processing, WooCommerce jobs) are queued rather than executed synchronously on the request path." -f ($serviceBus.Success -and $serviceBus.Data -and @($serviceBus.Data).Count-gt 0))))

# ---- PE:10 Optimise Operational Tasks ----
# MySQL maintenance window
if ($paramMaintenanceWin.Success -and $paramMaintenanceWin.Data) {
    $mw = $paramMaintenanceWin.Data
    $customWindow = Get-SafePropertyValue -InputObject $mw -Path @('customWindow')
    $dayOfWeek    = Get-SafePropertyValue -InputObject $mw -Path @('dayOfWeek')
    $startHour    = Get-SafePropertyValue -InputObject $mw -Path @('startHour')
    if ($customWindow -eq 'Enabled') {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:10 Optimise Operational Tasks' -Question 'Are MySQL maintenance windows scheduled during the lowest-traffic period?' -Priority 3 -Status 'PASS' -Notes ("Custom maintenance window enabled. Day = {0}; Hour = {1}. Verify this is a low-traffic period for the WordPress site." -f $dayOfWeek,$startHour)))
    } else {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:10 Optimise Operational Tasks' -Question 'Are MySQL maintenance windows scheduled during the lowest-traffic period?' -Priority 3 -Status 'FAIL' -Notes 'Custom maintenance window is not enabled. Azure may apply maintenance during business hours. Set a custom window aligned to your lowest-traffic period.'))
    }
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:10 Optimise Operational Tasks' -Question 'Are MySQL maintenance windows scheduled during the lowest-traffic period?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve MySQL maintenance window configuration.'))
}

# Deployment slots used
if ($slots.Success -and $slots.Data) {
    $slotCount = @($slots.Data).Count
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:10 Optimise Operational Tasks' -Question 'Are deployment slots and swap used for App Service deployments?' -Priority 3 -Status $(if($slotCount-gt0){'PASS'}else{'FAIL'}) -Notes ("{0} deployment slot(s) configured. {1}" -f $slotCount,$(if($slotCount-gt0){'Deployment slots allow zero-downtime deployments via slot swap.'}else{'No deployment slots. Deploy directly to production — risk of downtime during deployments.'}))))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:10 Optimise Operational Tasks' -Question 'Are deployment slots and swap used for App Service deployments?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve deployment slots.'))
}

# MySQL backup interval
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $backupInterval = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup','backupIntervalHours')
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:10 Optimise Operational Tasks' -Question 'Is MySQL backup frequency reduced to 6-hour intervals for large databases?' -Priority 3 -Status 'MANUAL' -Notes ("backupIntervalHours = {0}. For large WordPress databases, consider 6-hour backup intervals to reduce backup I/O impact during peak periods." -f ($backupInterval ?? 'default (24h)'))))
}

# ---- PE:03 Select the Right Services and Tiers — P5 additions ----
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $skuTier    = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','tier')
    $haMode     = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','mode')
    $replicaCount = if ($mysqlReplicas.Success -and $mysqlReplicas.Data) { @($mysqlReplicas.Data).Count } else { 0 }
    $needsGpOrMo = ($haMode -ne 'Disabled') -or ($replicaCount -gt 0)
    if ($needsGpOrMo) {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is General Purpose or Memory Optimized selected when HA, read replicas, or accelerated logs are required?' -Priority 5 -Status $(if ($skuTier -match 'GeneralPurpose|MemoryOptimized') { 'PASS' } else { 'FAIL' }) -Notes ("SKU tier = {0}, HA mode = {1}, read replicas = {2}. HA and read replicas require General Purpose or Memory Optimized tiers — Burstable does not support these features." -f $skuTier, $haMode, $replicaCount)))
    } else {
        $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is General Purpose or Memory Optimized selected when HA, read replicas, or accelerated logs are required?' -Priority 5 -Status 'PASS' -Notes ("SKU tier = {0}, HA mode = {1}, read replicas = {2}. No HA or replicas configured — Burstable is permitted in this configuration." -f $skuTier, $haMode, $replicaCount)))
    }
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Is General Purpose or Memory Optimized selected when HA, read replicas, or accelerated logs are required?' -Priority 5 -Status 'UNKNOWN' -Notes 'Could not retrieve MySQL server SKU or HA configuration.'))
}
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:03 Select the Right Services and Tiers' -Question 'Has App Service Environment (ASE) been evaluated for isolated dedicated compute requirements?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. ASE v3 provides dedicated isolated compute with no per-instance cost (just the Isolated v2 plan charge). Evaluate if the WordPress workload requires isolation from other tenants or has strict network boundary requirements.'))

# ---- PE:05 Scaling and Partitioning — P5 additions ----
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Has the Deployment Stamps pattern been considered for scale beyond a single App Service plan?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. For WordPress workloads expected to grow beyond the capacity of a single App Service plan, the Deployment Stamps pattern (Azure Front Door + multiple regional stamps) provides horizontal scale without single-region limits.'))
if ($mysqlReplicas.Success -and $mysqlReplicas.Data -and @($mysqlReplicas.Data).Count -gt 0) {
    $replicaCount = @($mysqlReplicas.Data).Count
    $replicaNames = (@($mysqlReplicas.Data) | ForEach-Object { $_.name }) -join ', '
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Are read replicas used to distribute WordPress read workloads?' -Priority 5 -Status 'PASS' -Notes ('{0} read replica(s) found: {1}. Confirm the WordPress application is configured to route SELECT queries to a replica endpoint (e.g. via HyperDB or a connection proxy).' -f $replicaCount, $replicaNames)))
    # Compare primary SKU vs replica SKUs
    $primarySku  = if ($mysqlServer.Success -and $mysqlServer.Data) { Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','name') } else { $null }
    $primaryVcores = if ($primarySku -match '(\d+)') { [int]$Matches[1] } else { 0 }
    $underSizedReplicas = @()
    foreach ($rep in @($mysqlReplicas.Data)) {
        $repSku    = Get-SafePropertyValue -InputObject $rep -Path @('sku','name')
        $repVcores = if ($repSku -match '(\d+)') { [int]$Matches[1] } else { 0 }
        if ($repVcores -lt $primaryVcores) { $underSizedReplicas += $rep.name }
    }
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Are read replicas provisioned with equal or greater compute and storage than the primary?' -Priority 5 -Status $(if ($underSizedReplicas.Count -eq 0) { 'PASS' } else { 'WARN' }) -Notes $(if ($underSizedReplicas.Count -eq 0) { ('Primary SKU = {0}. All {1} replica(s) have equal or greater vCore count.' -f $primarySku, $replicaCount) } else { ('Primary SKU = {0}. Replica(s) with fewer vCores: {1}. Under-sized replicas may lag under load.' -f $primarySku, ($underSizedReplicas -join ', ')) })))
    # Check for replication lag alert rule
    $lagAlertExists = $false
    if ($appAlertRules.Success -and $appAlertRules.Data) {
        $lagAlertExists = @($appAlertRules.Data | Where-Object { $_.description -match 'replication' -or $_.name -match 'replica' -or ($_.criteria.allOf | Where-Object { $_.metricName -match 'replication_lag' }) }).Count -gt 0
    }
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is replication lag on MySQL read replicas monitored via an alert rule?' -Priority 5 -Status $(if ($lagAlertExists) { 'PASS' } else { 'WARN' }) -Notes $(if ($lagAlertExists) { 'A replication lag-related alert rule was detected.' } else { 'No replication lag alert rule detected. Create an Azure Monitor alert on the replication_lag_in_seconds metric with a threshold of ≤30 seconds to detect replica drift.' })))
} else {
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Are read replicas used to distribute WordPress read workloads?' -Priority 5 -Status 'MANUAL' -Notes 'No MySQL read replicas found. For high read-to-write ratio workloads (typical for WordPress), read replicas can offload SELECT queries from the primary to improve throughput.'))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Are read replicas provisioned with equal or greater compute and storage than the primary?' -Priority 5 -Status 'PASS' -Notes 'No read replicas found — not applicable.'))
    $findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:05 Scaling and Partitioning' -Question 'Is replication lag on MySQL read replicas monitored via an alert rule?' -Priority 5 -Status 'PASS' -Notes 'No read replicas found — not applicable.'))
}

# ---- PE:06 Partition and Distribute Load — P5 additions ----
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:06 Partition and Distribute Load' -Question 'Has read replica lag under load been simulated to validate replication tolerance?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Load-test the WordPress site while monitoring replication_lag_in_seconds on replicas to confirm application behaviour remains acceptable when replicas lag.'))
$findings.Add((New-PeFinding -PeArea 'Performance Efficiency' -SubArea 'PE:06 Partition and Distribute Load' -Question 'Have WordPress read vs write query ratios been measured to validate read replica sizing?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Use slow query logs or Performance Insights to measure the SELECT:INSERT/UPDATE/DELETE ratio. Typical WordPress sites are 80–95% reads, validating read replica investment.'))

# ---------------------------------------------------------------------------
# Build report
# ---------------------------------------------------------------------------
$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeAppName = ($AppServiceName -replace '[^A-Za-z0-9._-]','-')
$reportPath  = Join-Path -Path $OutputDirectory -ChildPath ("PerformanceEfficiencyReport-{0}-{1}.md" -f $safeAppName,$timestamp)

$builder = [System.Text.StringBuilder]::new()
Add-MarkdownLine -Builder $builder -Text ('# WAF Performance Efficiency Review Report: {0}' -f $AppServiceName)
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text ('Generated: {0}' -f (Get-Date).ToString('u'))
Add-MarkdownLine -Builder $builder -Text ('Resource Group: `{0}`' -f $ResourceGroup)
Add-MarkdownLine -Builder $builder -Text ('App Service: `{0}`' -f $AppServiceName)
Add-MarkdownLine -Builder $builder -Text ('MySQL Flexible Server: `{0}`' -f $MySqlServerName)
Add-MarkdownLine -Builder $builder -Text ('Metric Lookback: {0} days' -f $MetricLookbackDays)
if ($Subscription) { Add-MarkdownLine -Builder $builder -Text ('Subscription: `{0}`' -f $Subscription) }
Add-MarkdownLine -Builder $builder -Text 'Sensitive values redacted.'
Add-MarkdownLine -Builder $builder -Text '> Covers WAF Performance Efficiency questions at Priority 1 through 5.'
Add-MarkdownLine -Builder $builder

$mysqlSku = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','name')
$mysqlTier= Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','tier')
$planTier = if($plan -and $plan.Data){Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','tier')}else{'unknown'}
$planSize = if($plan -and $plan.Data){Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','name')}else{'unknown'}

$summary = [ordered]@{
    'Subscription'           = Get-SafePropertyValue -InputObject $account.Data -Path @('name')
    'Resource Group'         = $ResourceGroup
    'App Service Plan Tier'  = $planTier
    'App Service Plan Size'  = $planSize
    'MySQL SKU Tier'         = $mysqlTier
    'MySQL SKU Name'         = $mysqlSku
    'MySQL HA Mode'          = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','mode')
    'MySQL autoIoScaling'    = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','autoIoScaling')
    'MySQL Provisioned IOPS' = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','iops')
    'App Insights Present'   = $hasAppInsights
    'Redis Present'          = $hasRedis
    'CDN/AFD Present'        = $hasCdn
    'Avg App Service CPU %'  = if($null-ne$avgAppCpu){'{0}%' -f $avgAppCpu}else{'No data'}
    'Avg MySQL CPU %'        = if($null-ne$avgMysqlCpu){'{0}%' -f $avgMysqlCpu}else{'No data'}
    'Avg MySQL Memory %'     = if($null-ne$avgMysqlMem){'{0}%' -f $avgMysqlMem}else{'No data'}
    'Avg MySQL IO %'         = if($null-ne$avgMysqlIo){'{0}%' -f $avgMysqlIo}else{'No data'}
    'slow_query_log'         = $slqVal
    'innodb_file_per_table'  = if($paramInnodbFilePer.Success -and $paramInnodbFilePer.Data){Get-SafePropertyValue -InputObject $paramInnodbFilePer.Data -Path @('value')}else{'unknown'}
    'max_connections'        = $maxConnVal
    'Metric Lookback Days'   = $MetricLookbackDays
}

Add-MarkdownLine -Builder $builder -Text '## Summary'
Add-KeyValueTable -Builder $builder -Values $summary
Add-PeAssessmentSection -Builder $builder -Findings $findings

Add-MarkdownLine -Builder $builder -Text '## Raw Data'; Add-MarkdownLine -Builder $builder
Add-JsonSection -Builder $builder -Title 'Azure Account Context'                    -Result $account
Add-JsonSection -Builder $builder -Title 'Resource Group Overview'                  -Result $rgResult
Add-JsonSection -Builder $builder -Title 'App Service Overview'                     -Result $webApp
Add-JsonSection -Builder $builder -Title 'App Service Site Config'                  -Result $siteConfig
Add-JsonSection -Builder $builder -Title 'App Service App Settings'                 -Result $appSettings
Add-JsonSection -Builder $builder -Title 'App Service Deployment Slots'             -Result $slots
Add-JsonSection -Builder $builder -Title 'App Service Hostname Bindings'            -Result $hostnameBindings
Add-JsonSection -Builder $builder -Title 'App Service Diagnostic Settings'          -Result $appDiagSettings
Add-JsonSection -Builder $builder -Title 'Application Insights Component'           -Result $appInsightsResult
Add-JsonSection -Builder $builder -Title 'App Service Alert Rules'                  -Result $appAlertRules
Add-JsonSection -Builder $builder -Title 'App Service CPU Metrics'                  -Result $appCpuMetrics
Add-JsonSection -Builder $builder -Title 'App Service Memory Metrics'               -Result $appMemMetrics
Add-JsonSection -Builder $builder -Title 'App Service Requests Metrics'             -Result $appReqMetrics
Add-JsonSection -Builder $builder -Title 'App Service HTTP 5xx Metrics'             -Result $appHttp5xx
if ($plan) { Add-JsonSection -Builder $builder -Title 'App Service Plan Overview'   -Result $plan }
if ($allPlansInRg) { Add-JsonSection -Builder $builder -Title 'All App Service Plans in RG' -Result $allPlansInRg }
if ($autoscaleSettings) { Add-JsonSection -Builder $builder -Title 'App Service Autoscale Settings' -Result $autoscaleSettings }
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Overview'           -Result $mysqlServer
Add-JsonSection -Builder $builder -Title 'MySQL Replicas'                           -Result $mysqlReplicas
Add-JsonSection -Builder $builder -Title 'MySQL Diagnostic Settings'                -Result $mysqlDiagSettings
Add-JsonSection -Builder $builder -Title 'MySQL CPU Metrics'                        -Result $mysqlCpuMetrics
Add-JsonSection -Builder $builder -Title 'MySQL Memory Metrics'                     -Result $mysqlMemMetrics
Add-JsonSection -Builder $builder -Title 'MySQL IO Metrics'                         -Result $mysqlIoMetrics
Add-JsonSection -Builder $builder -Title 'MySQL Connections Metrics'                -Result $mysqlConnMetrics
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: innodb_buffer_pool_size' -Result $paramInnodbBuf
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: innodb_file_per_table'   -Result $paramInnodbFilePer
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: innodb_log_file_size'    -Result $paramInnodbLog
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: innodb_tmpdir'           -Result $paramInnodbTmpDir
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: slow_query_log'          -Result $paramSlowQuery
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: log_queries_not_using_indexes' -Result $paramLogNoIndex
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: max_connections'         -Result $paramMaxConn
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: long_query_time'         -Result $paramLongQueryTime
Add-JsonSection -Builder $builder -Title 'MySQL Maintenance Window'                 -Result $paramMaintenanceWin
Add-JsonSection -Builder $builder -Title 'Redis Instances'                          -Result $redisList
Add-JsonSection -Builder $builder -Title 'Azure Front Door Profiles'                -Result $afdProfiles
Add-JsonSection -Builder $builder -Title 'Azure CDN Profiles'                       -Result $cdnProfiles
Add-JsonSection -Builder $builder -Title 'Storage Accounts'                         -Result $storagAccts
Add-JsonSection -Builder $builder -Title 'Application Gateways'                     -Result $appGateways
Add-JsonSection -Builder $builder -Title 'Log Analytics Workspaces'                 -Result $logAnalytics
Add-JsonSection -Builder $builder -Title 'Service Bus Namespaces'                   -Result $serviceBus
Add-CollectionStatusSection -Builder $builder -Results $results

[System.IO.File]::WriteAllText($reportPath, $builder.ToString(), [System.Text.Encoding]::UTF8)
Write-StatusMessage -Level OK -Message ("Performance efficiency report written to {0}" -f $reportPath)
