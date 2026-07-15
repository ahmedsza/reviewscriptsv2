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

    [int]$MetricLookbackDays = 30,

    [string]$AfdResourceGroup
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helper utilities
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
    if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) { throw 'Azure CLI not found in PATH.' }
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
        if ($null -eq $data) { Add-MarkdownLine -Builder $Builder -Text 'Status: succeeded, no data returned.'; Add-MarkdownLine -Builder $Builder; return }
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
# Reliability assessment helpers
# ---------------------------------------------------------------------------
function New-ReFinding {
    param([Parameter(Mandatory)][string]$ReArea, [Parameter(Mandatory)][string]$SubArea, [Parameter(Mandatory)][string]$Question,
          [Parameter(Mandatory)][int]$Priority, [ValidateSet('PASS','FAIL','WARN','UNKNOWN','MANUAL')][string]$Status='UNKNOWN', [string]$Notes='')
    [pscustomobject]@{ ReArea=$ReArea; SubArea=$SubArea; Question=$Question; Priority=$Priority; Status=$Status; Notes=$Notes }
}

function Add-ReAssessmentSection {
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Builder, [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Findings)
    $pass=@($Findings|Where-Object{$_.Status-eq'PASS'}).Count; $fail=@($Findings|Where-Object{$_.Status-eq'FAIL'}).Count
    $warn=@($Findings|Where-Object{$_.Status-eq'WARN'}).Count; $unk=@($Findings|Where-Object{$_.Status-eq'UNKNOWN'}).Count; $man=@($Findings|Where-Object{$_.Status-eq'MANUAL'}).Count
    Add-MarkdownLine -Builder $Builder -Text '## Reliability Assessment'; Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text ('**PASS:** {0} | **FAIL:** {1} | **WARN:** {2} | **UNKNOWN:** {3} | **MANUAL REVIEW REQUIRED:** {4}' -f $pass,$fail,$warn,$unk,$man); Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text '> Status key: **PASS** = confirmed good  |  **FAIL** = confirmed gap  |  **WARN** = partial/potential issue  |  **UNKNOWN** = data unavailable  |  **MANUAL** = cannot determine via az CLI alone'; Add-MarkdownLine -Builder $Builder
    foreach ($sub in ($Findings|Select-Object -ExpandProperty SubArea|Select-Object -Unique)) {
        $grp = $Findings|Where-Object{$_.SubArea-eq$sub}; $area=($grp|Select-Object -First 1).ReArea
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
    Write-StatusMessage -Level WARN -Message ("Unexpected non-fatal error: {0}. Continuing with the next Reliability action." -f $_.Exception.Message)
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

Write-StatusMessage -Level INFO -Message ("Starting reliability review for [{0}] and MySQL [{1}] in [{2}]" -f $AppServiceName,$MySqlServerName,$ResourceGroup)

$metricStart = (Get-Date).AddDays(-$MetricLookbackDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
$metricEnd   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')

# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------
$account    = Add-QueryResult -Label 'Azure Account'              -Arguments @('account','show') -Required
$rgResult   = Assert-ResourceGroupAvailable -AccountResult $account -ResourceGroupName $ResourceGroup
$results.Add($rgResult)

$webApp     = Add-QueryResult -Label 'App Service Overview'       -Arguments @('webapp','show','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Required
$webAppId   = Get-SafePropertyValue -InputObject $webApp.Data -Path @('id')
$planId     = Get-SafePropertyValue -InputObject $webApp.Data -Path @('serverFarmId')
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('appServicePlanId') }
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('properties', 'serverFarmId') }
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('properties', 'appServicePlanId') }
if (-not $webAppId) { Write-StatusMessage -Level WARN -Message 'Could not find App Service resource ID. Dependent App Service metric and diagnostic data will be marked unavailable.' }
if (-not $planId) { Write-StatusMessage -Level WARN -Message 'Could not find App Service plan ID. Plan and autoscale details will be marked unavailable.' }

$siteConfig = Add-QueryResult -Label 'App Service Site Config'    -Arguments @('webapp','config','show','--name',$AppServiceName,'--resource-group',$ResourceGroup)
$appSettings= Add-QueryResult -Label 'App Service App Settings'   -Arguments @('webapp','config','appsettings','list','--name',$AppServiceName,'--resource-group',$ResourceGroup)
$slots      = Add-QueryResult -Label 'App Service Deployment Slots'-Arguments @('webapp','deployment','slot','list','--name',$AppServiceName,'--resource-group',$ResourceGroup)
$hostnameBindings = Add-QueryResult -Label 'App Service Hostname Bindings' -Arguments @('webapp','config','hostname','list','--webapp-name',$AppServiceName,'--resource-group',$ResourceGroup)

# App Service Plan
$plan = $null; $autoscaleSettings = $null
if ($planId) {
    $planParts = $planId.Trim('/') -split '/'
    $planName=$null; $planRg=$ResourceGroup
    for ($i=0;$i -lt $planParts.Length;$i+=2) {
        if ($planParts[$i]-eq'serverfarms'  -and($i+1)-lt$planParts.Length) { $planName=$planParts[$i+1] }
        if ($planParts[$i]-eq'resourceGroups'-and($i+1)-lt$planParts.Length) { $planRg=$planParts[$i+1] }
    }
    if ($planName) {
        $plan             = Add-QueryResult -Label 'App Service Plan Overview'    -Arguments @('appservice','plan','show','--name',$planName,'--resource-group',$planRg)
        $autoscaleSettings= Add-QueryResult -Label 'App Service Autoscale'       -Arguments @('monitor','autoscale','list','--resource-group',$ResourceGroup)
    }
}

$appInsightsResult = Add-QueryResult -Label 'Application Insights Component' -Arguments @('resource','list','--resource-group',$ResourceGroup,'--resource-type','microsoft.insights/components')
$appAlertRules     = Add-QueryResult -Label 'Azure Monitor Alert Rules'       -Arguments @('monitor','metrics','alert','list','--resource-group',$ResourceGroup)
$appDiagSettings   = Add-QueryResultWhenValuePresent -Label 'App Service Diagnostic Settings' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','diagnostic-settings','list','--resource',$webAppId)

# App Service metrics
$appCpuMetrics   = Add-QueryResultWhenValuePresent -Label 'App Service CPU Metrics' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','metrics','list','--resource',$webAppId,'--metric','CpuPercentage','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)
$appHttp5xx      = Add-QueryResultWhenValuePresent -Label 'App Service HTTP 5xx' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','metrics','list','--resource',$webAppId,'--metric','Http5xx','--interval','PT1H','--aggregation','Total','--start-time',$metricStart,'--end-time',$metricEnd)
$appReqQueue     = Add-QueryResultWhenValuePresent -Label 'App Service Request Queue' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','metrics','list','--resource',$webAppId,'--metric','RequestsInApplicationQueue','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)

# MySQL
$mysqlServer       = Add-QueryResult -Label 'MySQL Flexible Server Overview' -Arguments @('mysql','flexible-server','show','--name',$MySqlServerName,'--resource-group',$ResourceGroup) -Required
$mysqlServerId     = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('id')
if (-not $mysqlServerId) { Write-StatusMessage -Level WARN -Message 'Could not find MySQL Flexible Server resource ID. Dependent MySQL metric and diagnostic data will be marked unavailable.' }
$mysqlFirewallRules= Add-QueryResult -Label 'MySQL Firewall Rules'           -Arguments @('mysql','flexible-server','firewall-rule','list','--name',$MySqlServerName,'--resource-group',$ResourceGroup)
$mysqlReplicas     = Add-QueryResult -Label 'MySQL Replicas'                  -Arguments @('mysql','flexible-server','replica','list','--name',$MySqlServerName,'--resource-group',$ResourceGroup)
$mysqlBackups      = Add-QueryResult -Label 'MySQL Backups'                   -Arguments @('mysql','flexible-server','backup','list','--name',$MySqlServerName,'--resource-group',$ResourceGroup)
$mysqlDiagSettings = Add-QueryResultWhenValuePresent -Label 'MySQL Diagnostic Settings' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','diagnostic-settings','list','--resource',$mysqlServerId)
$mysqlAdmins       = Add-QueryResult -Label 'MySQL Entra Admins'              -Arguments @('mysql','flexible-server','ad-admin','list','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup)

# MySQL parameters relevant to reliability
$paramRequireSecure  = Add-QueryResult -Label 'MySQL: require_secure_transport' -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','require_secure_transport')
$paramMaxConn        = Add-QueryResult -Label 'MySQL: max_connections'          -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','max_connections')
$paramSlowQuery      = Add-QueryResult -Label 'MySQL: slow_query_log'           -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','slow_query_log')
$paramMaintenanceWin = Add-QueryResult -Label 'MySQL: maintenance_window'       -Arguments @('mysql','flexible-server','show','--name',$MySqlServerName,'--resource-group',$ResourceGroup,'--query','maintenanceWindow')

# MySQL metrics
$mysqlCpuMetrics   = Add-QueryResultWhenValuePresent -Label 'MySQL CPU Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','metrics','list','--resource',$mysqlServerId,'--metric','cpu_percent','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)
$mysqlStorageMetrics=Add-QueryResultWhenValuePresent -Label 'MySQL Storage Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','metrics','list','--resource',$mysqlServerId,'--metric','storage_percent','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)
$mysqlConnMetrics  = Add-QueryResultWhenValuePresent -Label 'MySQL Connections Metrics' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','metrics','list','--resource',$mysqlServerId,'--metric','active_connections','--interval','PT1H','--aggregation','Average','--start-time',$metricStart,'--end-time',$metricEnd)

# Resource locks
$resourceLocks     = Add-QueryResult -Label 'Resource Group Locks'      -Arguments @('lock','list','--resource-group',$ResourceGroup)
$mysqlLock         = Add-QueryResult -Label 'MySQL Server Lock'          -Arguments @('lock','list','--resource-group',$ResourceGroup,'--resource-name',$MySqlServerName,'--resource-type','Microsoft.DBforMySQL/flexibleServers','--namespace','Microsoft.DBforMySQL')

# Supporting infrastructure
$afdRg       = if ($AfdResourceGroup) { $AfdResourceGroup } else { $ResourceGroup }
$afdProfiles = Add-QueryResult -Label 'Azure Front Door Profiles'  -Arguments @('afd','profile','list','--resource-group',$afdRg)
$cdnProfiles = Add-QueryResult -Label 'Azure CDN Profiles'         -Arguments @('cdn','profile','list','--resource-group',$ResourceGroup)
$redisList   = Add-QueryResult -Label 'Redis Instances'            -Arguments @('redis','list','--resource-group',$ResourceGroup)
$storagAccts = Add-QueryResult -Label 'Storage Accounts'           -Arguments @('storage','account','list','--resource-group',$ResourceGroup)
$appGateways = Add-QueryResult -Label 'Application Gateways'       -Arguments @('network','application-gateway','list','--resource-group',$ResourceGroup)
$serviceBus  = Add-QueryResult -Label 'Service Bus Namespaces'     -Arguments @('servicebus','namespace','list','--resource-group',$ResourceGroup)
$logAnalytics= Add-QueryResult -Label 'Log Analytics Workspaces'   -Arguments @('monitor','log-analytics','workspace','list','--resource-group',$ResourceGroup)
$serviceHealthAlerts = Add-QueryResult -Label 'Service Health Alerts' -Arguments @('monitor','activity-log','alert','list','--resource-group',$ResourceGroup)

# Private endpoint / network
$privateEndpoints= Add-QueryResult -Label 'Private Endpoints'      -Arguments @('network','private-endpoint','list','--resource-group',$ResourceGroup)

# ---------------------------------------------------------------------------
# Assess findings
# ---------------------------------------------------------------------------
$findings = [System.Collections.Generic.List[object]]::new()

$avgMysqlCpu  = Get-MetricAverage -MetricResult $mysqlCpuMetrics
$avgMysqlStore= Get-MetricAverage -MetricResult $mysqlStorageMetrics
$avgMysqlConn = Get-MetricAverage -MetricResult $mysqlConnMetrics

function Get-AppSettingValue {
    param([string]$Name)
    if (-not $appSettings.Success -or -not $appSettings.Data) { return $null }
    $s = @($appSettings.Data | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    if ($s) { return $s.value } else { return $null }
}

# ---- RE:01 Design for Simplicity and Efficiency ----
if ($plan -and $plan.Success -and $plan.Data) {
    $tier = Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','tier')
    $name = Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','name')
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:01 Design for Simplicity and Efficiency' -Question 'Is the App Service Plan SKU appropriately sized for expected traffic?' -Priority 3 -Status 'MANUAL' -Notes ("App Service Plan: {0} / {1}. Confirm this SKU meets the WordPress traffic SLO." -f $tier,$name)))
} else {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:01 Design for Simplicity and Efficiency' -Question 'Is the App Service Plan SKU appropriately sized for expected traffic?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve App Service plan.'))
}

if ($mysqlServer.Success -and $mysqlServer.Data) {
    $skuTier = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','tier')
    $skuName = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('sku','name')
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:01 Design for Simplicity and Efficiency' -Question 'Is the MySQL compute tier and SKU right-sized?' -Priority 3 -Status $(if($avgMysqlCpu -lt 20){'WARN'}elseif($avgMysqlCpu -gt 80){'WARN'}else{'MANUAL'}) -Notes ("MySQL SKU: {0} / {1}. Avg CPU over {2} days = {3}%. Confirm SKU is not over- or under-provisioned." -f $skuTier,$skuName,$MetricLookbackDays,$avgMysqlCpu)))
}

# ---- RE:03 Failure Mode Analysis ----
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $autoGrow = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','autoGrow')
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:03 Failure Mode Analysis' -Question 'Is the MySQL storage full failure mode documented — with autogrow enabled and an alert set?' -Priority 3 -Status $(if($autoGrow-eq'Enabled'){'MANUAL'}else{'FAIL'}) -Notes ("autoGrow = {0}. {1}" -f $autoGrow,$(if($autoGrow-eq'Enabled'){'Storage autogrow is enabled. Confirm an alert is set before the autogrow threshold.'}else{'Storage autogrow is DISABLED — storage full will cause MySQL to stop accepting writes. Enable autogrow.'}))))

    $maxConn = if($paramMaxConn.Success -and $paramMaxConn.Data){Get-SafePropertyValue -InputObject $paramMaxConn.Data -Path @('value')}else{'unknown'}
    $connPct  = if($null -ne $avgMysqlConn -and $maxConn -ne 'unknown') { [math]::Round(([double]$avgMysqlConn/[double]$maxConn)*100,1) } else { $null }
    $connStatus = if($null -ne $connPct -and $connPct -gt 80){'FAIL'}elseif($null -ne $connPct){'PASS'}else{'MANUAL'}
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:03 Failure Mode Analysis' -Question 'Is the MySQL connection exhaustion failure mode documented — with connection pool and max_connections alert?' -Priority 2 -Status $connStatus -Notes ("max_connections = {0}; avg active connections = {1}; usage = {2}%. Alert threshold should be ~80% of max_connections." -f $maxConn,$avgMysqlConn,$connPct)))

    $haMode = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','mode')
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:03 Failure Mode Analysis' -Question 'Is the MySQL planned maintenance restart accounted for in application retry logic?' -Priority 3 -Status 'MANUAL' -Notes ("HA mode = {0}. MySQL maintenance causes a 60-120 second restart. Confirm WordPress DB connection retry logic uses exponential backoff." -f $haMode)))
}

# ---- RE:04 Define Reliability and Recovery Targets ----
$mysqlRetention = if($mysqlServer.Success -and $mysqlServer.Data){Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup','backupRetentionDays')}else{$null}
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:04 Define Reliability and Recovery Targets' -Question 'Is the MySQL backup retention period set to satisfy the RPO?' -Priority 3 -Status $(if($null -ne $mysqlRetention){'MANUAL'}else{'UNKNOWN'}) -Notes ("backupRetentionDays = {0}. Verify this retention period is >= the defined RPO." -f $mysqlRetention)))
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:04 Define Reliability and Recovery Targets' -Question 'Has an RTO been defined for the WordPress workload?' -Priority 2 -Status 'MANUAL' -Notes 'Cannot determine from az CLI. Verify an RTO is documented and tested via forced failover tests.'))
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:04 Define Reliability and Recovery Targets' -Question 'Has an RPO been defined and does it drive backup frequency and retention?' -Priority 2 -Status 'MANUAL' -Notes ("backupRetentionDays = {0}. Verify the RPO is documented and that backup frequency/retention settings reflect it." -f $mysqlRetention)))

# ---- RE:05 Build Redundancy ----
if ($plan -and $plan.Success -and $plan.Data) {
    $tier      = Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','tier')
    $zoneRedun = Get-SafePropertyValue -InputObject $plan.Data -Path @('zoneRedundant')
    $workers   = Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','capacity')

    # P1: Premium v3 tier
    $isPv3 = $tier -match 'PremiumV3|Premium'
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:05 Build Redundancy' -Question 'Is the App Service Plan on Premium v3 (Pv3) tier?' -Priority 1 -Status $(if($isPv3){'PASS'}else{'FAIL'}) -Notes ("App Service Plan tier = {0}. Premium v3 is required for zone redundancy support." -f $tier)))

    # P1: Zone redundancy
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:05 Build Redundancy' -Question 'Is zone redundancy enabled on the App Service Plan?' -Priority 1 -Status $(if($zoneRedun-eq$true){'PASS'}else{'FAIL'}) -Notes ("zoneRedundant = {0}. Zone redundancy protects against AZ-level failures." -f $zoneRedun)))

    # P2: Min 3 instances for zone distribution
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:05 Build Redundancy' -Question 'Is a minimum of 3 instances configured for zone distribution?' -Priority 2 -Status $(if([int]$workers -ge 3){'PASS'}else{'FAIL'}) -Notes ("Current capacity (workers) = {0}. Zone-redundant Apps need >= 3 instances for AZ distribution." -f $workers)))
} else {
    foreach ($q in @('Is the App Service Plan on Premium v3 (Pv3) tier?','Is zone redundancy enabled on the App Service Plan?','Is a minimum of 3 instances configured for zone distribution?')) {
        $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:05 Build Redundancy' -Question $q -Priority 1 -Status 'UNKNOWN' -Notes 'Could not retrieve App Service plan.'))
    }
}

# ARR affinity
if ($webApp.Success -and $webApp.Data) {
    $clientAffinity = Get-SafePropertyValue -InputObject $webApp.Data -Path @('clientAffinityEnabled')
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:05 Build Redundancy' -Question 'Is ARR Affinity disabled with session state managed externally?' -Priority 3 -Status $(if($clientAffinity-eq$false){'PASS'}else{'FAIL'}) -Notes ("clientAffinityEnabled = {0}. With ARR affinity enabled, a failed instance causes session loss." -f $clientAffinity)))
}

# WordPress stateless — media in Blob
$hasStorage = $storagAccts.Success -and $storagAccts.Data -and @($storagAccts.Data).Count-gt 0
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:05 Build Redundancy' -Question 'Is WordPress configured as stateless — no local file system writes, media in Blob Storage?' -Priority 2 -Status $(if($hasStorage){'MANUAL'}else{'FAIL'}) -Notes $(if($hasStorage){'Storage account found. Confirm WordPress media library plugin routes uploads to Blob Storage, not the App Service filesystem.'}else{'No storage accounts found in resource group. WordPress media may be on App Service local filesystem — not HA, lost on instance recycle.'})))

# MySQL zone-redundant HA
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $haMode        = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','mode')
    $haState       = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','state')
    $primaryZone   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('availabilityZone')
    $standbyZone   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','standbyAvailabilityZone')
    $autoGrow      = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','autoGrow')

    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:05 Build Redundancy' -Question 'Is zone-redundant High Availability enabled on MySQL?' -Priority 3 -Status $(if($haMode-eq'ZoneRedundant'){'PASS'}elseif($haMode-eq'SameZone'){'WARN'}else{'FAIL'}) -Notes ("HA mode = {0}; state = {1}." -f $haMode,$haState)))

    # P1: Primary and standby in separate AZs
    $zonesOk = $haMode -eq 'ZoneRedundant' -and $null -ne $standbyZone -and $primaryZone -ne $standbyZone
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:05 Build Redundancy' -Question 'Are primary and standby placed in separate availability zones?' -Priority 1 -Status $(if($zonesOk){'PASS'}elseif($haMode-eq'ZoneRedundant'){'WARN'}else{'FAIL'}) -Notes ("HA mode = {0}; primary AZ = {1}; standby AZ = {2}." -f $haMode,$primaryZone,$standbyZone)))

    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:05 Build Redundancy' -Question 'Is storage autogrow enabled on MySQL?' -Priority 3 -Status $(if($autoGrow-eq'Enabled'){'PASS'}else{'FAIL'}) -Notes ("autoGrow = {0}." -f $autoGrow)))
}

# ---- RE:06 Implement a Scaling Strategy ----
if ($autoscaleSettings -and $autoscaleSettings.Success -and $autoscaleSettings.Data -and @($autoscaleSettings.Data).Count-gt 0) {
    $appPlanAs = @($autoscaleSettings.Data|Where-Object{(Get-SafePropertyValue -InputObject $_ -Path @('targetResourceUri')) -like "*$planId*"})
    if ($appPlanAs.Count -gt 0) {
        $as = $appPlanAs[0]
        $profiles = @(Get-SafePropertyValue -InputObject $as -Path @('profiles'))
        $firstProfile = if ($profiles.Count -gt 0) { $profiles[0] } else { $null }
        $minInst  = Get-SafePropertyValue -InputObject $firstProfile -Path @('capacity','minimum')
        $maxInst  = Get-SafePropertyValue -InputObject $firstProfile -Path @('capacity','maximum')
        $rules    = @(Get-SafePropertyValue -InputObject $firstProfile -Path @('rules'))
        $soRules  = @($rules|Where-Object{(Get-SafePropertyValue -InputObject $_ -Path @('scaleAction','direction'))-eq'Increase'})
        $cpu65    = @($soRules|Where-Object{$m=(Get-SafePropertyValue -InputObject $_ -Path @('metricTrigger','metricName'));$t=(Get-SafePropertyValue -InputObject $_ -Path @('metricTrigger','threshold'));$m-match'Cpu'-and[double]$t-ge55-and[double]$t-le75})

        $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:06 Implement a Scaling Strategy' -Question 'Is autoscale configured on the App Service Plan?' -Priority 2 -Status 'PASS' -Notes ("Autoscale found. Min = {0}; Max = {1}; Rules = {2}." -f $minInst,$maxInst,@($rules).Count)))
        $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:06 Implement a Scaling Strategy' -Question 'Do scale-out triggers fire at ~65% CPU?' -Priority 3 -Status $(if($cpu65.Count-gt0){'PASS'}else{'WARN'}) -Notes $(if($cpu65.Count-gt0){'CPU 55-75% scale-out rule found.'}else{'No CPU scale-out rule found in 55-75% range.'})))
        $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:06 Implement a Scaling Strategy' -Question 'Is the minimum instance count >= 2 (>= 3 for zone-redundant)?' -Priority 2 -Status $(if($null-ne$minInst -and [int]$minInst-ge2){'PASS'}else{'FAIL'}) -Notes ("Min instances = {0}. Zone-redundant plans require >= 3." -f $minInst)))
    } else {
        $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:06 Implement a Scaling Strategy' -Question 'Is autoscale configured on the App Service Plan?' -Priority 2 -Status 'FAIL' -Notes 'No autoscale settings targeting App Service plan.'))
        $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:06 Implement a Scaling Strategy' -Question 'Do scale-out triggers fire at ~65% CPU?' -Priority 3 -Status 'FAIL' -Notes 'No autoscale configured.'))
        $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:06 Implement a Scaling Strategy' -Question 'Is the minimum instance count >= 2 (>= 3 for zone-redundant)?' -Priority 2 -Status 'FAIL' -Notes 'No autoscale configured.'))
    }
} else {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:06 Implement a Scaling Strategy' -Question 'Is autoscale configured on the App Service Plan?' -Priority 2 -Status $(if($autoscaleSettings){'FAIL'}else{'UNKNOWN'}) -Notes 'Could not retrieve autoscale settings.'))
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:06 Implement a Scaling Strategy' -Question 'Do scale-out triggers fire at ~65% CPU?' -Priority 3 -Status 'UNKNOWN' -Notes 'No autoscale data.'))
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:06 Implement a Scaling Strategy' -Question 'Is the minimum instance count >= 2 (>= 3 for zone-redundant)?' -Priority 2 -Status 'UNKNOWN' -Notes 'No autoscale data.'))
}

# ---- RE:07 Self-Preservation and Self-Healing ----
if ($siteConfig.Success -and $siteConfig.Data) {
    $hcPath   = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('healthCheckPath')
    $autoHeal = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('autoHealEnabled')
    $alwaysOn = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('alwaysOn')

    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:07 Self-Preservation and Self-Healing' -Question 'Is Health Check enabled with a meaningful path?' -Priority 2 -Status $(if(-not[string]::IsNullOrWhiteSpace($hcPath)){'PASS'}else{'FAIL'}) -Notes ("healthCheckPath = '{0}'." -f $hcPath)))
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:07 Self-Preservation and Self-Healing' -Question 'Are Auto-heal rules configured?' -Priority 2 -Status $(if($autoHeal-eq$true){'PASS'}else{'FAIL'}) -Notes ("autoHealEnabled = {0}." -f $autoHeal)))
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:07 Self-Preservation and Self-Healing' -Question 'Is Always On enabled?' -Priority 3 -Status $(if($alwaysOn-eq$true){'PASS'}else{'FAIL'}) -Notes ("alwaysOn = {0}. Without Always On, the App Service process can be evicted after idle periods." -f $alwaysOn)))
} else {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:07 Self-Preservation and Self-Healing' -Question 'Is Health Check enabled with a meaningful path?' -Priority 2 -Status 'UNKNOWN' -Notes 'Site config unavailable.'))
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:07 Self-Preservation and Self-Healing' -Question 'Are Auto-heal rules configured?' -Priority 2 -Status 'UNKNOWN' -Notes 'Site config unavailable.'))
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:07 Self-Preservation and Self-Healing' -Question 'Is Always On enabled?' -Priority 3 -Status 'UNKNOWN' -Notes 'Site config unavailable.'))
}

# SSL/reconnection after interruptions
if ($paramRequireSecure.Success -and $paramRequireSecure.Data) {
    $val = Get-SafePropertyValue -InputObject $paramRequireSecure.Data -Path @('value')
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:07 Self-Preservation and Self-Healing' -Question 'Are MySQL require_secure_transport and TLS enabled and does the app handle reconnection after SSL interruptions?' -Priority 1 -Status $(if($val-eq'ON'){'MANUAL'}else{'FAIL'}) -Notes ("require_secure_transport = {0}. {1}" -f $val,$(if($val-eq'ON'){'SSL is enforced. Confirm WordPress connection retry handles SSL handshake interruptions after MySQL failover.'}else{'require_secure_transport is OFF — unencrypted MySQL connections are permitted.'}))))
} else {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:07 Self-Preservation and Self-Healing' -Question 'Are MySQL require_secure_transport and TLS enabled and does the app handle reconnection after SSL interruptions?' -Priority 1 -Status 'UNKNOWN' -Notes 'Could not retrieve require_secure_transport.'))
}

# ---- RE:09 Disaster Recovery ----
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $geoBackup  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup','geoRedundantBackup')
    $retention  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup','backupRetentionDays')

    # P1: geo-redundant backup
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:09 Disaster Recovery' -Question 'Is MySQL geo-redundant backup enabled?' -Priority 1 -Status $(if($geoBackup-eq'Enabled'){'PASS'}else{'FAIL'}) -Notes ("geoRedundantBackup = {0}. Geo-redundant backup is required to support cross-region restore for DR." -f $geoBackup)))

    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:09 Disaster Recovery' -Question 'Is the backup retention period set in line with defined RPO?' -Priority 3 -Status 'MANUAL' -Notes ("backupRetentionDays = {0}. Verify retention satisfies the defined RPO." -f $retention)))

    # Default MySQL port (required for geo-restore)
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:09 Disaster Recovery' -Question 'Does MySQL use the default port (required for geo-restore)?' -Priority 3 -Status 'MANUAL' -Notes "MySQL Flexible Server always uses port 3306 — custom ports are not supported. Geo-restore requires port 3306. Confirm application configuration does not hardcode a non-default port."))

    # Media in Blob Storage
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:09 Disaster Recovery' -Question 'Is WordPress media stored in Azure Blob Storage rather than App Service local file system?' -Priority 2 -Status $(if($hasStorage){'MANUAL'}else{'FAIL'}) -Notes $(if($hasStorage){'Storage account present. Confirm WordPress media plugin stores uploads in Blob Storage.'}else{'No storage accounts found. Media on App Service local filesystem is NOT preserved during DR restore.'})))
}

# App Settings not hardcoded
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:09 Disaster Recovery' -Question 'Are WordPress settings managed via App Service App Settings rather than committed to source control?' -Priority 3 -Status $(if($appSettings.Success -and $appSettings.Data -and @($appSettings.Data).Count-gt 0){'MANUAL'}else{'UNKNOWN'}) -Notes ("{0} app setting(s) found. Confirm secrets and environment-specific configuration are App Service settings, not hardcoded in wp-config.php in source control." -f $(if($appSettings.Success -and $appSettings.Data){@($appSettings.Data).Count}else{0}))))

# CanNotDelete lock
if ($mysqlLock.Success -and $mysqlLock.Data -and @($mysqlLock.Data).Count-gt 0) {
    $delLock = @($mysqlLock.Data|Where-Object{$_.properties.level -eq 'CanNotDelete' -or $_.level -eq 'CanNotDelete'})
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:09 Disaster Recovery' -Question 'Is the deleted server recovery window documented — with CanNotDelete lock applied?' -Priority 1 -Status $(if($delLock.Count-gt 0){'PASS'}else{'WARN'}) -Notes ("{0} lock(s) on MySQL server; {1} CanNotDelete lock(s). MySQL servers deleted accidentally have a 5-day recovery window." -f @($mysqlLock.Data).Count,$delLock.Count)))
} elseif ($mysqlLock.Success) {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:09 Disaster Recovery' -Question 'Is the deleted server recovery window documented — with CanNotDelete lock applied?' -Priority 1 -Status 'FAIL' -Notes 'No locks found on MySQL Flexible Server. Apply a CanNotDelete lock to prevent accidental deletion.'))
} else {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:09 Disaster Recovery' -Question 'Is the deleted server recovery window documented — with CanNotDelete lock applied?' -Priority 1 -Status 'UNKNOWN' -Notes 'Could not retrieve locks on MySQL server.'))
}

# ---- RE:10 Monitor Health and Measure Reliability ----
$hasAppInsights = $false
if ($appSettings.Success -and $appSettings.Data) {
    $aiKey = @($appSettings.Data|Where-Object{$_.name -match 'APPINSIGHTS_INSTRUMENTATIONKEY|APPLICATIONINSIGHTS_CONNECTION_STRING'}) | Select-Object -First 1
    $hasAppInsights = $null -ne $aiKey
}
if (-not $hasAppInsights -and $appInsightsResult.Success -and $appInsightsResult.Data) { $hasAppInsights = $true }
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:10 Monitor Health and Measure Reliability' -Question 'Is Application Insights (or equivalent APM) enabled?' -Priority 2 -Status $(if($hasAppInsights){'PASS'}else{'FAIL'}) -Notes $(if($hasAppInsights){'Application Insights instrumentation detected.'}else{'No Application Insights instrumentation key or connection string found.'})))

# Alert rules
if ($appAlertRules.Success -and $appAlertRules.Data -and @($appAlertRules.Data).Count-gt 0) {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:10 Monitor Health and Measure Reliability' -Question 'Are Azure Monitor metrics collected for App Service: CPU, memory, HTTP 5xx, response time, request queue?' -Priority 3 -Status 'MANUAL' -Notes ("{0} alert rule(s) found. Confirm rules cover CPU, memory, HTTP 5xx, response time, and request queue depth." -f @($appAlertRules.Data).Count)))
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:10 Monitor Health and Measure Reliability' -Question 'Are alerts configured for MySQL HA IO and SQL Status?' -Priority 3 -Status 'MANUAL' -Notes ("Review alert rules to confirm HA_IO_status and HA_SQL_status are covered. Total rules in RG = {0}." -f @($appAlertRules.Data).Count)))
    $storageAlert = @($appAlertRules.Data|Where-Object{$_.description -match 'storage|disk'})
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:10 Monitor Health and Measure Reliability' -Question 'Are alerts configured for MySQL storage utilisation approaching capacity before autogrow triggers?' -Priority 3 -Status $(if($storageAlert.Count-gt0){'MANUAL'}else{'FAIL'}) -Notes $(if($storageAlert.Count-gt0){"Possible storage alert found. Avg MySQL storage = {0}%. Verify threshold is below autogrow trigger." -f $avgMysqlStore}else{"No storage-related alerts detected. Avg MySQL storage = {0}%. Create alert at >70% storage_percent." -f $avgMysqlStore})))
} else {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:10 Monitor Health and Measure Reliability' -Question 'Are Azure Monitor metrics collected for App Service: CPU, memory, HTTP 5xx, response time, request queue?' -Priority 3 -Status 'FAIL' -Notes 'No metric alert rules found.'))
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:10 Monitor Health and Measure Reliability' -Question 'Are alerts configured for MySQL HA IO and SQL Status?' -Priority 3 -Status 'FAIL' -Notes 'No metric alert rules found.'))
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:10 Monitor Health and Measure Reliability' -Question 'Are alerts configured for MySQL storage utilisation approaching capacity before autogrow triggers?' -Priority 3 -Status 'FAIL' -Notes ("No metric alert rules found. Avg MySQL storage = {0}%." -f $avgMysqlStore)))
}

# Service health alerts
if ($serviceHealthAlerts.Success -and $serviceHealthAlerts.Data -and @($serviceHealthAlerts.Data).Count-gt 0) {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:10 Monitor Health and Measure Reliability' -Question 'Are Azure Service Health alerts configured for maintenance events?' -Priority 3 -Status 'PASS' -Notes ("{0} activity log alert(s) found." -f @($serviceHealthAlerts.Data).Count)))
} else {
    $findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:10 Monitor Health and Measure Reliability' -Question 'Are Azure Service Health alerts configured for maintenance events?' -Priority 3 -Status 'FAIL' -Notes 'No activity log alerts found. Configure Service Health alerts for planned maintenance events on App Service and MySQL.'))
}

# ---- RE WordPress-Specific ----
# wp-cron
$disableWpCron = if($appSettings.Success -and $appSettings.Data){$s=@($appSettings.Data|Where-Object{$_.name -eq 'DISABLE_WP_CRON'})|Select-Object -First 1;if($s){$s.value}else{$null}}else{$null}
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:WordPress-Specific' -Question 'Is WordPress wp-cron disabled and replaced with an external trigger?' -Priority 3 -Status $(if($disableWpCron-eq'true'){'PASS'}else{'FAIL'}) -Notes ("DISABLE_WP_CRON = {0}. wp-cron runs on every page request — in a multi-instance environment this causes duplicate job execution and MySQL lock contention." -f $disableWpCron)))

# Redis object cache
$hasRedis = $redisList.Success -and $redisList.Data -and @($redisList.Data).Count-gt 0
$redisAppSetting = if($appSettings.Success -and $appSettings.Data){@($appSettings.Data|Where-Object{$_.name -match 'REDIS|WP_REDIS'})|Select-Object -First 1}else{$null}
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:WordPress-Specific' -Question 'Is WordPress object cache externalised (Redis) — not per-instance in-memory?' -Priority 2 -Status $(if($hasRedis-and$null-ne$redisAppSetting){'MANUAL'}elseif($hasRedis){'WARN'}else{'FAIL'}) -Notes $(if($hasRedis){"Redis found: {0}. App setting found = {1}. Confirm WordPress Redis Object Cache plugin is active — per-instance in-memory cache breaks multi-instance environments." -f ((@($redisList.Data)|ForEach-Object{$_.name})-join', '),$null-ne$redisAppSetting}else{'No Redis found. Without a shared object cache, each App Service instance has its own in-memory cache — breaking cache coherence in a multi-instance deployment.'})))

# CDN to absorb traffic spikes
$hasCdn = ($afdProfiles.Success -and $afdProfiles.Data -and @($afdProfiles.Data).Count-gt 0) -or ($cdnProfiles.Success -and $cdnProfiles.Data -and @($cdnProfiles.Data).Count-gt 0)
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:WordPress-Specific' -Question 'Is a CDN placed in front of App Service to absorb traffic spikes?' -Priority 3 -Status $(if($hasCdn){'MANUAL'}else{'FAIL'}) -Notes $(if($hasCdn){'CDN/AFD profile found. Confirm static assets and anonymous page cache is served from the edge to reduce origin load during traffic spikes.'}else{'No CDN or AFD found. All traffic hits App Service origin — traffic spikes directly increase CPU and database load.'})))

# ---- RE:09 Disaster Recovery — P5 additions ----
$findings.Add((New-ReFinding -ReArea 'Reliability' -SubArea 'RE:09 Disaster Recovery' -Question 'Is a multi-region failover strategy defined, with Azure Front Door routing?' -Priority 5 -Status $(if($hasCdn){'MANUAL'}else{'WARN'}) -Notes $(if($hasCdn){'AFD/CDN profile found. Confirm the AFD origin group is configured with priority routing to a secondary region origin so that if the primary App Service becomes unhealthy, AFD fails over automatically. Confirm MySQL geo-restore or cross-region replica is the data recovery path.'}else{'No AFD found. Multi-region failover requires Azure Front Door with health probe-based origin failover. Without AFD, there is no automated routing failover to a secondary region.'})))

# ---------------------------------------------------------------------------
# Build report
# ---------------------------------------------------------------------------
$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeAppName = ($AppServiceName -replace '[^A-Za-z0-9._-]','-')
$reportPath  = Join-Path -Path $OutputDirectory -ChildPath ("ReliabilityReport-{0}-{1}.md" -f $safeAppName,$timestamp)

$builder = [System.Text.StringBuilder]::new()
Add-MarkdownLine -Builder $builder -Text ('# WAF Reliability Review Report: {0}' -f $AppServiceName)
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text ('Generated: {0}' -f (Get-Date).ToString('u'))
Add-MarkdownLine -Builder $builder -Text ('Resource Group: `{0}`' -f $ResourceGroup)
Add-MarkdownLine -Builder $builder -Text ('App Service: `{0}`' -f $AppServiceName)
Add-MarkdownLine -Builder $builder -Text ('MySQL Flexible Server: `{0}`' -f $MySqlServerName)
Add-MarkdownLine -Builder $builder -Text ('Metric Lookback: {0} days' -f $MetricLookbackDays)
if ($Subscription) { Add-MarkdownLine -Builder $builder -Text ('Subscription: `{0}`' -f $Subscription) }
Add-MarkdownLine -Builder $builder -Text 'Sensitive values redacted.'
Add-MarkdownLine -Builder $builder -Text '> Covers WAF Reliability questions at Priority 1 through 5.'
Add-MarkdownLine -Builder $builder

$mysqlHaMode   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','mode')
$mysqlHaState  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','state')
$mysqlPriAZ    = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('availabilityZone')
$mysqlStdbyAZ  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','standbyAvailabilityZone')
$mysqlAutoGrow = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('storage','autoGrow')
$mysqlGeoBack  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup','geoRedundantBackup')
$mysqlRetention= Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('backup','backupRetentionDays')
$planTier      = if($plan -and $plan.Data){Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','tier')}else{'unknown'}
$planZoneRedun = if($plan -and $plan.Data){Get-SafePropertyValue -InputObject $plan.Data -Path @('zoneRedundant')}else{'unknown'}
$planCapacity  = if($plan -and $plan.Data){Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','capacity')}else{'unknown'}

$summary = [ordered]@{
    'Subscription'                     = Get-SafePropertyValue -InputObject $account.Data -Path @('name')
    'Resource Group'                   = $ResourceGroup
    'App Service Plan Tier'            = $planTier
    'App Service Plan Zone Redundant'  = $planZoneRedun
    'App Service Plan Capacity'        = $planCapacity
    'App Service clientAffinityEnabled'= Get-SafePropertyValue -InputObject $webApp.Data -Path @('clientAffinityEnabled')
    'MySQL HA Mode'                    = $mysqlHaMode
    'MySQL HA State'                   = $mysqlHaState
    'MySQL Primary AZ'                 = $mysqlPriAZ
    'MySQL Standby AZ'                 = $mysqlStdbyAZ
    'MySQL Storage AutoGrow'           = $mysqlAutoGrow
    'MySQL Geo-Redundant Backup'       = $mysqlGeoBack
    'MySQL Backup Retention Days'      = $mysqlRetention
    'MySQL max_connections'            = if($paramMaxConn.Success -and $paramMaxConn.Data){Get-SafePropertyValue -InputObject $paramMaxConn.Data -Path @('value')}else{'unknown'}
    'MySQL require_secure_transport'   = if($paramRequireSecure.Success -and $paramRequireSecure.Data){Get-SafePropertyValue -InputObject $paramRequireSecure.Data -Path @('value')}else{'unknown'}
    'MySQL Avg CPU %'                  = if($null-ne$avgMysqlCpu){'{0}%' -f $avgMysqlCpu}else{'No data'}
    'MySQL Avg Storage %'              = if($null-ne$avgMysqlStore){'{0}%' -f $avgMysqlStore}else{'No data'}
    'MySQL Avg Active Connections'     = if($null-ne$avgMysqlConn){$avgMysqlConn}else{'No data'}
    'App Insights Present'             = $hasAppInsights
    'Redis Present'                    = $hasRedis
    'CDN/AFD Present'                  = $hasCdn
    'CanNotDelete Lock on MySQL'       = ($mysqlLock.Success -and $mysqlLock.Data -and @($mysqlLock.Data|Where-Object{$_.level-eq'CanNotDelete'-or$_.properties.level-eq'CanNotDelete'}).Count-gt 0)
    'DISABLE_WP_CRON'                  = $disableWpCron
}

Add-MarkdownLine -Builder $builder -Text '## Summary'
Add-KeyValueTable -Builder $builder -Values $summary
Add-ReAssessmentSection -Builder $builder -Findings $findings

Add-MarkdownLine -Builder $builder -Text '## Raw Data'; Add-MarkdownLine -Builder $builder
Add-JsonSection -Builder $builder -Title 'Azure Account Context'               -Result $account
Add-JsonSection -Builder $builder -Title 'Resource Group Overview'             -Result $rgResult
Add-JsonSection -Builder $builder -Title 'App Service Overview'                -Result $webApp
Add-JsonSection -Builder $builder -Title 'App Service Site Config'             -Result $siteConfig
Add-JsonSection -Builder $builder -Title 'App Service App Settings'            -Result $appSettings
Add-JsonSection -Builder $builder -Title 'App Service Deployment Slots'        -Result $slots
Add-JsonSection -Builder $builder -Title 'App Service Hostname Bindings'       -Result $hostnameBindings
Add-JsonSection -Builder $builder -Title 'App Service Diagnostic Settings'     -Result $appDiagSettings
Add-JsonSection -Builder $builder -Title 'Application Insights Component'      -Result $appInsightsResult
Add-JsonSection -Builder $builder -Title 'Azure Monitor Alert Rules'           -Result $appAlertRules
Add-JsonSection -Builder $builder -Title 'App Service CPU Metrics'             -Result $appCpuMetrics
Add-JsonSection -Builder $builder -Title 'App Service HTTP 5xx Metrics'        -Result $appHttp5xx
Add-JsonSection -Builder $builder -Title 'App Service Request Queue Metrics'   -Result $appReqQueue
if ($plan) { Add-JsonSection -Builder $builder -Title 'App Service Plan Overview' -Result $plan }
if ($autoscaleSettings) { Add-JsonSection -Builder $builder -Title 'App Service Autoscale Settings' -Result $autoscaleSettings }
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Overview'      -Result $mysqlServer
Add-JsonSection -Builder $builder -Title 'MySQL Firewall Rules'                -Result $mysqlFirewallRules
Add-JsonSection -Builder $builder -Title 'MySQL Replicas'                      -Result $mysqlReplicas
Add-JsonSection -Builder $builder -Title 'MySQL Backups'                       -Result $mysqlBackups
Add-JsonSection -Builder $builder -Title 'MySQL Diagnostic Settings'           -Result $mysqlDiagSettings
Add-JsonSection -Builder $builder -Title 'MySQL Entra Admins'                  -Result $mysqlAdmins
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: require_secure_transport' -Result $paramRequireSecure
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: max_connections'    -Result $paramMaxConn
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: slow_query_log'     -Result $paramSlowQuery
Add-JsonSection -Builder $builder -Title 'MySQL Maintenance Window'            -Result $paramMaintenanceWin
Add-JsonSection -Builder $builder -Title 'MySQL CPU Metrics'                   -Result $mysqlCpuMetrics
Add-JsonSection -Builder $builder -Title 'MySQL Storage Metrics'               -Result $mysqlStorageMetrics
Add-JsonSection -Builder $builder -Title 'MySQL Connections Metrics'           -Result $mysqlConnMetrics
Add-JsonSection -Builder $builder -Title 'Resource Group Locks'                -Result $resourceLocks
Add-JsonSection -Builder $builder -Title 'MySQL Server Lock'                   -Result $mysqlLock
Add-JsonSection -Builder $builder -Title 'Redis Instances'                     -Result $redisList
Add-JsonSection -Builder $builder -Title 'Azure Front Door Profiles'           -Result $afdProfiles
Add-JsonSection -Builder $builder -Title 'Azure CDN Profiles'                  -Result $cdnProfiles
Add-JsonSection -Builder $builder -Title 'Storage Accounts'                    -Result $storagAccts
Add-JsonSection -Builder $builder -Title 'Application Gateways'                -Result $appGateways
Add-JsonSection -Builder $builder -Title 'Service Bus Namespaces'              -Result $serviceBus
Add-JsonSection -Builder $builder -Title 'Log Analytics Workspaces'            -Result $logAnalytics
Add-JsonSection -Builder $builder -Title 'Service Health Alerts'               -Result $serviceHealthAlerts
Add-JsonSection -Builder $builder -Title 'Private Endpoints'                   -Result $privateEndpoints
Add-CollectionStatusSection -Builder $builder -Results $results

[System.IO.File]::WriteAllText($reportPath, $builder.ToString(), [System.Text.Encoding]::UTF8)
Write-StatusMessage -Level OK -Message ("Reliability report written to {0}" -f $reportPath)
