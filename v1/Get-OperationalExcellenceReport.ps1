[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppServiceName,

    [Parameter(Mandatory = $true)]
    [string]$MySqlServerName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Get-Location).Path,

    [string]$Subscription
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
# Operational Excellence assessment helpers
# ---------------------------------------------------------------------------
function New-OeFinding {
    param([Parameter(Mandatory)][string]$OeArea, [Parameter(Mandatory)][string]$SubArea, [Parameter(Mandatory)][string]$Question,
          [Parameter(Mandatory)][int]$Priority, [ValidateSet('PASS','FAIL','WARN','UNKNOWN','MANUAL')][string]$Status='UNKNOWN', [string]$Notes='')
    [pscustomobject]@{ OeArea=$OeArea; SubArea=$SubArea; Question=$Question; Priority=$Priority; Status=$Status; Notes=$Notes }
}

function Add-OeAssessmentSection {
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Builder, [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Findings)
    $pass=@($Findings|Where-Object{$_.Status-eq'PASS'}).Count; $fail=@($Findings|Where-Object{$_.Status-eq'FAIL'}).Count
    $warn=@($Findings|Where-Object{$_.Status-eq'WARN'}).Count; $unk=@($Findings|Where-Object{$_.Status-eq'UNKNOWN'}).Count; $man=@($Findings|Where-Object{$_.Status-eq'MANUAL'}).Count
    Add-MarkdownLine -Builder $Builder -Text '## Operational Excellence Assessment'; Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text ('**PASS:** {0} | **FAIL:** {1} | **WARN:** {2} | **UNKNOWN:** {3} | **MANUAL REVIEW REQUIRED:** {4}' -f $pass,$fail,$warn,$unk,$man); Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text '> Status key: **PASS** = confirmed good  |  **FAIL** = confirmed gap  |  **WARN** = partial/potential issue  |  **UNKNOWN** = data unavailable  |  **MANUAL** = cannot determine via az CLI alone'; Add-MarkdownLine -Builder $Builder
    foreach ($sub in ($Findings|Select-Object -ExpandProperty SubArea|Select-Object -Unique)) {
        $grp = $Findings|Where-Object{$_.SubArea-eq$sub}; $area=($grp|Select-Object -First 1).OeArea
        Add-MarkdownLine -Builder $Builder -Text ('### {0} — {1}' -f $area,$sub); Add-MarkdownLine -Builder $Builder
        Add-MarkdownLine -Builder $Builder -Text '| Priority | Status | Question | Notes |'; Add-MarkdownLine -Builder $Builder -Text '| --- | --- | --- | --- |'
        foreach ($f in $grp) {
            $b=switch($f.Status){'PASS'{'✅ PASS'}'FAIL'{'❌ FAIL'}'WARN'{'⚠️ WARN'}'UNKNOWN'{'❓ UNKNOWN'}'MANUAL'{'🔍 MANUAL'}}
            Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} | {2} | {3} |' -f $f.Priority,$b,(ConvertTo-MarkdownText $f.Question),(ConvertTo-MarkdownText $f.Notes))
        }
        Add-MarkdownLine -Builder $Builder
    }
}

# ---------------------------------------------------------------------------
# Script entry point
# ---------------------------------------------------------------------------
Test-AzureCliPrerequisites

trap {
    Write-StatusMessage -Level WARN -Message ("Unexpected non-fatal error: {0}. Continuing with the next Operational Excellence action." -f $_.Exception.Message)
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

Write-StatusMessage -Level INFO -Message ("Starting operational excellence review for [{0}] and MySQL [{1}] in [{2}]" -f $AppServiceName,$MySqlServerName,$ResourceGroup)

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
if (-not $webAppId) { Write-StatusMessage -Level WARN -Message 'Could not find App Service resource ID. Dependent App Service diagnostic data will be marked unavailable.' }
if (-not $planId) { Write-StatusMessage -Level WARN -Message 'Could not find App Service plan ID. Plan and autoscale details will be marked unavailable.' }

$siteConfig = Add-QueryResult -Label 'App Service Site Config'    -Arguments @('webapp','config','show','--name',$AppServiceName,'--resource-group',$ResourceGroup)
$appSettings= Add-QueryResult -Label 'App Service App Settings'   -Arguments @('webapp','config','appsettings','list','--name',$AppServiceName,'--resource-group',$ResourceGroup)
$slots      = Add-QueryResult -Label 'App Service Deployment Slots'-Arguments @('webapp','deployment','slot','list','--name',$AppServiceName,'--resource-group',$ResourceGroup)
$hostnameBindings = Add-QueryResult -Label 'App Service Hostname Bindings' -Arguments @('webapp','config','hostname','list','--webapp-name',$AppServiceName,'--resource-group',$ResourceGroup)
$sslCerts   = Add-QueryResult -Label 'App Service SSL Certificates' -Arguments @('webapp','config','ssl','list','--resource-group',$ResourceGroup)
$appDiagSettings = Add-QueryResultWhenValuePresent -Label 'App Service Diagnostic Settings' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('monitor','diagnostic-settings','list','--resource',$webAppId)

# App Service Plan
$plan = $null; $autoscaleSettings = $null
if ($planId) {
    $planParts = $planId.Trim('/') -split '/'
    $planName=$null; $planRg=$ResourceGroup
    for ($i=0;$i -lt $planParts.Length;$i+=2) {
        if ($planParts[$i]-eq'serverfarms'   -and($i+1)-lt$planParts.Length) { $planName=$planParts[$i+1] }
        if ($planParts[$i]-eq'resourceGroups'-and($i+1)-lt$planParts.Length) { $planRg=$planParts[$i+1] }
    }
    if ($planName) {
        $plan             = Add-QueryResult -Label 'App Service Plan Overview'    -Arguments @('appservice','plan','show','--name',$planName,'--resource-group',$planRg)
        $autoscaleSettings= Add-QueryResult -Label 'App Service Autoscale'       -Arguments @('monitor','autoscale','list','--resource-group',$ResourceGroup)
    }
}

# App Insights / monitoring
$appInsightsResult = Add-QueryResult -Label 'Application Insights Component'   -Arguments @('resource','list','--resource-group',$ResourceGroup,'--resource-type','microsoft.insights/components')
$appAlertRules     = Add-QueryResult -Label 'Azure Monitor Alert Rules'         -Arguments @('monitor','metrics','alert','list','--resource-group',$ResourceGroup)
$serviceHealthAlerts= Add-QueryResult -Label 'Service Health Alerts'            -Arguments @('monitor','activity-log','alert','list','--resource-group',$ResourceGroup)

# Policy and governance
$policyAssignments = Add-QueryResult -Label 'Resource Group Policy Assignments' -Arguments @('policy','assignment','list','--resource-group',$ResourceGroup)
$resourceLocks     = Add-QueryResult -Label 'Resource Group Locks'              -Arguments @('lock','list','--resource-group',$ResourceGroup)
$mysqlLock         = Add-QueryResult -Label 'MySQL Server Lock'                  -Arguments @('lock','list','--resource-group',$ResourceGroup,'--resource-name',$MySqlServerName,'--resource-type','Microsoft.DBforMySQL/flexibleServers','--namespace','Microsoft.DBforMySQL')
$advisorRecs       = Add-QueryResult -Label 'Azure Advisor Recommendations'     -Arguments @('advisor','recommendation','list','--resource-group',$ResourceGroup)

# MySQL
$mysqlServer       = Add-QueryResult -Label 'MySQL Flexible Server Overview'    -Arguments @('mysql','flexible-server','show','--name',$MySqlServerName,'--resource-group',$ResourceGroup) -Required
$mysqlServerId     = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('id')
if (-not $mysqlServerId) { Write-StatusMessage -Level WARN -Message 'Could not find MySQL Flexible Server resource ID. Dependent MySQL diagnostic data will be marked unavailable.' }
$mysqlDiagSettings = Add-QueryResultWhenValuePresent -Label 'MySQL Diagnostic Settings' -Value $mysqlServerId -RequiredValueName 'MySQL Flexible Server resource ID' -Arguments @('monitor','diagnostic-settings','list','--resource',$mysqlServerId)
$mysqlAdmins       = Add-QueryResult -Label 'MySQL Entra Admins'                 -Arguments @('mysql','flexible-server','ad-admin','list','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup)
$mysqlFirewallRules= Add-QueryResult -Label 'MySQL Firewall Rules'                -Arguments @('mysql','flexible-server','firewall-rule','list','--name',$MySqlServerName,'--resource-group',$ResourceGroup)
$mysqlReplicas     = Add-QueryResult -Label 'MySQL Replicas'                      -Arguments @('mysql','flexible-server','replica','list','--name',$MySqlServerName,'--resource-group',$ResourceGroup)

# MySQL parameters relevant to operational baselines
$paramSlowQuery      = Add-QueryResult -Label 'MySQL: slow_query_log'              -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','slow_query_log')
$paramRequireSecure  = Add-QueryResult -Label 'MySQL: require_secure_transport'    -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','require_secure_transport')
$paramTlsVersion     = Add-QueryResult -Label 'MySQL: tls_version'                 -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','tls_version')
$paramMaxConn        = Add-QueryResult -Label 'MySQL: max_connections'             -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','max_connections')
$paramInnodbFilePer  = Add-QueryResult -Label 'MySQL: innodb_file_per_table'       -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','innodb_file_per_table')
$paramLocalInfile    = Add-QueryResult -Label 'MySQL: local_infile'                -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','local_infile')
$paramAuditLog       = Add-QueryResult -Label 'MySQL: audit_log_enabled'           -Arguments @('mysql','flexible-server','parameter','show','--server-name',$MySqlServerName,'--resource-group',$ResourceGroup,'--name','audit_log_enabled')
$paramMaintenanceWin = Add-QueryResult -Label 'MySQL: maintenance_window'          -Arguments @('mysql','flexible-server','show','--name',$MySqlServerName,'--resource-group',$ResourceGroup,'--query','maintenanceWindow')

# Supporting infrastructure
$logAnalytics    = Add-QueryResult -Label 'Log Analytics Workspaces'          -Arguments @('monitor','log-analytics','workspace','list','--resource-group',$ResourceGroup)
$storagAccts     = Add-QueryResult -Label 'Storage Accounts'                  -Arguments @('storage','account','list','--resource-group',$ResourceGroup)
$keyVaults       = Add-QueryResult -Label 'Key Vaults'                        -Arguments @('keyvault','list','--resource-group',$ResourceGroup)
$resourceTags    = Add-QueryResult -Label 'Resource Tags'                     -Arguments @('resource','list','--resource-group',$ResourceGroup,'--query','[].{name:name,type:type,tags:tags}')

# ---------------------------------------------------------------------------
# Assess findings
# ---------------------------------------------------------------------------
$findings = [System.Collections.Generic.List[object]]::new()

function Get-AppSettingValue {
    param([string]$Name)
    if (-not $appSettings.Success -or -not $appSettings.Data) { return $null }
    $s = @($appSettings.Data | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
    if ($s) { return $s.value } else { return $null }
}

# ---- OE:02 Standardised Operations ----
# MySQL maintenance window
if ($paramMaintenanceWin.Success -and $paramMaintenanceWin.Data) {
    $mw = $paramMaintenanceWin.Data
    $customWindow = Get-SafePropertyValue -InputObject $mw -Path @('customWindow')
    $dayOfWeek    = Get-SafePropertyValue -InputObject $mw -Path @('dayOfWeek')
    $startHour    = Get-SafePropertyValue -InputObject $mw -Path @('startHour')
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:02 Standardised Operations' -Question 'Has a Custom Managed Maintenance Window been set aligned to lowest-traffic period?' -Priority 3 -Status $(if($customWindow-eq'Enabled'){'PASS'}else{'FAIL'}) -Notes ("customWindow = {0}; dayOfWeek = {1}; startHour = {2}. {3}" -f $customWindow,$dayOfWeek,$startHour,$(if($customWindow-eq'Enabled'){'Custom window set. Confirm this is a low-traffic period.'}else{'Custom window not enabled. Azure may schedule maintenance during business hours.'}))))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:02 Standardised Operations' -Question 'Has a Custom Managed Maintenance Window been set aligned to lowest-traffic period?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve MySQL maintenance window.'))
}

# ---- OE:05 Infrastructure as Code ----
# CanNotDelete lock — P1
if ($mysqlLock.Success -and $mysqlLock.Data -and @($mysqlLock.Data).Count-gt 0) {
    $delLock = @($mysqlLock.Data|Where-Object{(Get-SafePropertyValue -InputObject $_ -Path @('properties','level')) -eq 'CanNotDelete' -or (Get-SafePropertyValue -InputObject $_ -Path @('level')) -eq 'CanNotDelete'})
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:05 Infrastructure as Code' -Question 'Is a CanNotDelete management lock applied in IaC?' -Priority 1 -Status $(if($delLock.Count-gt 0){'PASS'}else{'FAIL'}) -Notes ("{0} lock(s) on MySQL server; {1} CanNotDelete. A CanNotDelete lock on the MySQL Flexible Server prevents accidental deletion." -f @($mysqlLock.Data).Count,$delLock.Count)))
} elseif ($mysqlLock.Success) {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:05 Infrastructure as Code' -Question 'Is a CanNotDelete management lock applied in IaC?' -Priority 1 -Status 'FAIL' -Notes 'No locks found on MySQL Flexible Server. Apply a CanNotDelete lock via IaC.'))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:05 Infrastructure as Code' -Question 'Is a CanNotDelete management lock applied in IaC?' -Priority 1 -Status 'UNKNOWN' -Notes 'Could not retrieve MySQL server locks.'))
}

# Immutable MySQL settings captured in current deployment
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $haMode        = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','mode')
    $networkMode   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('network','publicNetworkAccess')
    $mysqlVersion  = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('version')
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:05 Infrastructure as Code' -Question 'Are the immutable MySQL settings captured in the current deployment?' -Priority 3 -Status 'MANUAL' -Notes ("HA mode = {0}; publicNetworkAccess = {1}; version = {2}. These settings CANNOT be changed after server creation. Verify IaC explicitly declares them." -f $haMode,$networkMode,$mysqlVersion)))
}

# ---- OE:06 Workload Supply Chain and Deployment Pipelines ----
$runFromPkg = Get-AppSettingValue -Name 'WEBSITE_RUN_FROM_PACKAGE'
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:06 Workload Supply Chain and Deployment Pipelines' -Question 'Is deployment from ZIP package (WEBSITE_RUN_FROM_PACKAGE=1) used?' -Priority 3 -Status $(if($runFromPkg-eq'1'){'PASS'}else{'FAIL'}) -Notes ("WEBSITE_RUN_FROM_PACKAGE = {0}. ZIP deployment makes the filesystem read-only, preventing ad-hoc file edits and ensuring reproducible deployments." -f $runFromPkg)))

if ($slots.Success -and $slots.Data -and @($slots.Data).Count-gt 0) {
    $slotNames = (@($slots.Data)|ForEach-Object{$_.name}) -join ', '
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:06 Workload Supply Chain and Deployment Pipelines' -Question 'Does the pipeline deploy to a staging slot first, validate, then swap to production?' -Priority 3 -Status 'MANUAL' -Notes ("Slots found: {0}. Confirm deployment pipeline deploys to staging slot, runs smoke tests, then swaps." -f $slotNames)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:06 Workload Supply Chain and Deployment Pipelines' -Question 'Does the pipeline deploy to a staging slot first, validate, then swap to production?' -Priority 3 -Status 'FAIL' -Notes 'No deployment slots found. Without a staging slot, deployments go directly to production with no safe validation step.'))
}

# ---- OE:07 Observability and Monitoring ----
# Diagnostic logging to Log Analytics
$appLogsEnabled = $false
if ($appDiagSettings.Success -and $appDiagSettings.Data -and @($appDiagSettings.Data).Count-gt 0) {
    $hasLogAnalyticsDestination = @($appDiagSettings.Data|Where-Object{$_.workspaceId -and $_.workspaceId -ne ''})
    $appLogsEnabled = $hasLogAnalyticsDestination.Count -gt 0
}
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Is diagnostic logging enabled on App Service — routed to Log Analytics?' -Priority 2 -Status $(if($appLogsEnabled){'PASS'}else{'FAIL'}) -Notes $(if($appLogsEnabled){'App Service diagnostic settings with Log Analytics workspace destination found.'}else{'No diagnostic settings routing App Service logs to a Log Analytics workspace. Configure via Azure Monitor > Diagnostic Settings.'})))

# Application Insights
$hasAppInsights = $false
if ($appSettings.Success -and $appSettings.Data) {
    $aiKey = @($appSettings.Data|Where-Object{$_.name -match 'APPINSIGHTS_INSTRUMENTATIONKEY|APPLICATIONINSIGHTS_CONNECTION_STRING'}) | Select-Object -First 1
    $hasAppInsights = $null -ne $aiKey
}
if (-not $hasAppInsights -and $appInsightsResult.Success -and $appInsightsResult.Data) { $hasAppInsights = $true }
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Is Application Insights enabled for WordPress performance monitoring?' -Priority 2 -Status $(if($hasAppInsights){'PASS'}else{'FAIL'}) -Notes $(if($hasAppInsights){'Application Insights connection detected.'}else{'No Application Insights key or connection string found.'})))

# Health Check
if ($siteConfig.Success -and $siteConfig.Data) {
    $hcPath = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('healthCheckPath')
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Is the Health Check feature enabled with a path probing the app, database, and cache?' -Priority 2 -Status $(if(-not[string]::IsNullOrWhiteSpace($hcPath)){'PASS'}else{'FAIL'}) -Notes ("healthCheckPath = '{0}'." -f $hcPath)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Is the Health Check feature enabled with a path probing the app, database, and cache?' -Priority 2 -Status 'UNKNOWN' -Notes 'Site config unavailable.'))
}

# Azure Monitor alerts
if ($appAlertRules.Success -and $appAlertRules.Data -and @($appAlertRules.Data).Count-gt 0) {
    $alertNames = (@($appAlertRules.Data)|ForEach-Object{$_.name}) -join ', '
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Are Azure Monitor alerts configured on CPU, memory, HTTP 5xx, response time, request queue?' -Priority 2 -Status 'MANUAL' -Notes ("{0} alert rule(s) found: {1}. Review to confirm CPU, memory, HTTP 5xx, response time, and request queue are covered." -f @($appAlertRules.Data).Count,$alertNames)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Are Azure Monitor alerts configured on CPU, memory, HTTP 5xx, response time, request queue?' -Priority 2 -Status 'FAIL' -Notes 'No metric alert rules found in resource group.'))
}

# MySQL logs to Log Analytics (MySqlAuditLogs, MySqlSlowLogs)
$mysqlAuditToLa = $false; $mysqlSlowToLa = $false
if ($mysqlDiagSettings.Success -and $mysqlDiagSettings.Data -and @($mysqlDiagSettings.Data).Count-gt 0) {
    $mysqlAuditToLa = @($mysqlDiagSettings.Data | ForEach-Object { $_.logs | Where-Object { $_.category -eq 'MySqlAuditLogs' -and $_.enabled -eq $true } }).Count -gt 0
    $mysqlSlowToLa  = @($mysqlDiagSettings.Data | ForEach-Object { $_.logs | Where-Object { $_.category -eq 'MySqlSlowLogs'  -and $_.enabled -eq $true } }).Count -gt 0
}
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Are MySqlAuditLogs and MySqlSlowLogs routed to Log Analytics?' -Priority 2 -Status $(if($mysqlAuditToLa -and $mysqlSlowToLa){'PASS'}elseif($mysqlAuditToLa -or $mysqlSlowToLa){'WARN'}else{'FAIL'}) -Notes ("MySqlAuditLogs to LA = {0}; MySqlSlowLogs to LA = {1}." -f $mysqlAuditToLa,$mysqlSlowToLa)))

# Server logs enabled (file-based)
if ($paramSlowQuery.Success -and $paramSlowQuery.Data) {
    $slqVal = Get-SafePropertyValue -InputObject $paramSlowQuery.Data -Path @('value')
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Are server logs (file-based) enabled for rapid MySQL troubleshooting?' -Priority 3 -Status $(if($slqVal-eq'ON'){'PASS'}else{'WARN'}) -Notes ("slow_query_log = {0}. File-based slow query logging supports rapid ad-hoc troubleshooting. Route to Log Analytics for historical analysis." -f $slqVal)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Are server logs (file-based) enabled for rapid MySQL troubleshooting?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve slow_query_log.'))
}

# MySQL HA alerts
if ($appAlertRules.Success -and $appAlertRules.Data -and @($appAlertRules.Data).Count-gt 0) {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Are Azure Monitor alerts created on HA IO Status, HA SQL Status, CPU, memory, storage, aborted connections?' -Priority 2 -Status 'MANUAL' -Notes ("{0} alert rule(s) found. Confirm rules cover HA_IO_status, HA_SQL_status, cpu_percent, memory_percent, storage_percent, and aborted_connections." -f @($appAlertRules.Data).Count)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Are Azure Monitor alerts created on HA IO Status, HA SQL Status, CPU, memory, storage, aborted connections?' -Priority 2 -Status 'FAIL' -Notes 'No metric alert rules found.'))
}

# Service health alerts
if ($serviceHealthAlerts.Success -and $serviceHealthAlerts.Data -and @($serviceHealthAlerts.Data).Count-gt 0) {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Are Azure Service Health alerts configured for MySQL maintenance events?' -Priority 3 -Status 'PASS' -Notes ("{0} activity log alert(s) found." -f @($serviceHealthAlerts.Data).Count)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:07 Observability and Monitoring' -Question 'Are Azure Service Health alerts configured for MySQL maintenance events?' -Priority 3 -Status 'FAIL' -Notes 'No activity log alerts found. Configure Service Health alerts for Azure Database for MySQL maintenance events.'))
}

# ---- OE:08 Incident Management ----
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:08 Incident Management' -Question 'Does a WordPress incident response runbook exist?' -Priority 2 -Status 'MANUAL' -Notes 'Cannot determine from az CLI. Verify a runbook exists covering: slow response, MySQL saturation, connection exhaustion, and platform maintenance events.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:08 Incident Management' -Question 'Is an on-call rotation and escalation path defined?' -Priority 2 -Status 'MANUAL' -Notes 'Cannot determine from az CLI. Confirm PagerDuty/Opsgenie/Action Group integration is configured for alert routing.'))

# Alert integration with action groups
if ($appAlertRules.Success -and $appAlertRules.Data -and @($appAlertRules.Data).Count-gt 0) {
    $withActionGroups = @($appAlertRules.Data|Where-Object{$_.actions -and @($_.actions).Count-gt 0})
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:08 Incident Management' -Question 'Are Azure Monitor alerts integrated with PagerDuty, Opsgenie, or Azure Action Groups?' -Priority 3 -Status $(if($withActionGroups.Count-gt 0){'PASS'}else{'WARN'}) -Notes ("{0}/{1} alert rule(s) have action groups configured." -f $withActionGroups.Count,@($appAlertRules.Data).Count)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:08 Incident Management' -Question 'Are Azure Monitor alerts integrated with PagerDuty, Opsgenie, or Azure Action Groups?' -Priority 3 -Status 'FAIL' -Notes 'No metric alert rules found in resource group.'))
}

# ---- OE:10 Automation ----
# MySQL parameter automation (slow_query_log, require_secure_transport, tls_version checks as baseline)
if ($paramRequireSecure.Success -and $paramRequireSecure.Data -and $paramTlsVersion.Success -and $paramTlsVersion.Data -and $paramSlowQuery.Success -and $paramSlowQuery.Data) {
    $reqSecVal  = Get-SafePropertyValue -InputObject $paramRequireSecure.Data -Path @('value')
    $tlsVal     = Get-SafePropertyValue -InputObject $paramTlsVersion.Data    -Path @('value')
    $slqVal     = Get-SafePropertyValue -InputObject $paramSlowQuery.Data     -Path @('value')
    $paramOk    = $reqSecVal-eq'ON' -and $tlsVal -match 'TLSv1.2' -and $slqVal-eq'ON'
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Is MySQL server parameter configuration automated for consistent baselines?' -Priority 3 -Status $(if($paramOk){'PASS'}else{'WARN'}) -Notes ("require_secure_transport = {0}; tls_version = {1}; slow_query_log = {2}. {3}" -f $reqSecVal,$tlsVal,$slqVal,$(if($paramOk){'Parameter baseline appears correctly set. Confirm automation (IaC or script) enforces these on every environment.'}else{'One or more baseline parameters are not at the expected value — confirm IaC or automation enforces the parameter baseline.'}))))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Is MySQL server parameter configuration automated for consistent baselines?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve all baseline parameters.'))
}

# TLS certificate renewal automated
if ($sslCerts.Success -and $sslCerts.Data -and @($sslCerts.Data).Count-gt 0) {
    $managedCerts = @($sslCerts.Data|Where-Object{$_.issuer -match 'DigiCert|Let.s Encrypt|Microsoft' -or $_.certType -eq 'Managed'})
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Is TLS certificate renewal automated via managed certificates or Key Vault auto-rotation?' -Priority 3 -Status $(if($managedCerts.Count-gt 0){'PASS'}else{'MANUAL'}) -Notes ("{0} SSL cert(s); {1} appear to be managed/auto-renewed. Confirm all production certificates are on auto-renewal." -f @($sslCerts.Data).Count,$managedCerts.Count)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Is TLS certificate renewal automated via managed certificates or Key Vault auto-rotation?' -Priority 3 -Status 'MANUAL' -Notes 'No SSL certificates found in resource group or could not retrieve. Confirm TLS certificates are managed with auto-renewal.'))
}

# Scale-in rules automated
if ($autoscaleSettings -and $autoscaleSettings.Success -and $autoscaleSettings.Data -and @($autoscaleSettings.Data).Count-gt 0) {
    $appPlanAs = @($autoscaleSettings.Data|Where-Object{(Get-SafePropertyValue -InputObject $_ -Path @('targetResourceUri'))-like "*$planId*"})
    if ($appPlanAs.Count-gt 0) {
        $rules = try { @(@($appPlanAs[0].profiles)[0].rules) } catch { @() }
        $siRules = @($rules|Where-Object{(Get-SafePropertyValue -InputObject $_ -Path @('scaleAction','direction'))-eq'Decrease'})
        $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Are scale-in rules automated in Azure Monitor?' -Priority 3 -Status $(if($siRules.Count-gt 0){'PASS'}else{'FAIL'}) -Notes ("{0} scale-in rule(s) found in autoscale settings." -f $siRules.Count)))
    } else {
        $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Are scale-in rules automated in Azure Monitor?' -Priority 3 -Status 'FAIL' -Notes 'No autoscale settings targeting App Service plan.'))
    }
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Are scale-in rules automated in Azure Monitor?' -Priority 3 -Status $(if($autoscaleSettings){'FAIL'}else{'UNKNOWN'}) -Notes 'Could not retrieve autoscale settings.'))
}

# Azure Policy enforcement
if ($policyAssignments.Success -and $policyAssignments.Data -and @($policyAssignments.Data).Count-gt 0) {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Is Azure Policy used with deploy-if-not-exists effects to enforce configurations?' -Priority 3 -Status 'MANUAL' -Notes ("{0} policy assignment(s) found on resource group. Review to confirm DINE effects are in use for required configurations (e.g. diagnostic settings, tagging)." -f @($policyAssignments.Data).Count)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Is Azure Policy used with deploy-if-not-exists effects to enforce configurations?' -Priority 3 -Status 'WARN' -Notes 'No policy assignments found on resource group. Azure Policy with DINE effects can enforce diagnostic settings, tagging, and security configurations automatically.'))
}

# Advisor recommendations
if ($advisorRecs.Success -and $advisorRecs.Data) {
    $openRecs = @($advisorRecs.Data|Where-Object{$suppIds = Get-SafePropertyValue -InputObject $_ -Path @('properties','suppressionIds'); $null -eq $suppIds -or @($suppIds).Count -eq 0})
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Are Azure Advisor recommendations reviewed periodically with automation considered?' -Priority 3 -Status $(if($openRecs.Count-eq 0){'PASS'}else{'WARN'}) -Notes ("{0} open Advisor recommendation(s) in resource group." -f $openRecs.Count)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:10 Automation' -Question 'Are Azure Advisor recommendations reviewed periodically with automation considered?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve Advisor recommendations.'))
}

# ---- OE:11 Safe Deployment Practices ----
# Deployment slots
if ($slots.Success -and $slots.Data -and @($slots.Data).Count-gt 0) {
    $slotNames = (@($slots.Data)|ForEach-Object{$_.name}) -join ', '
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'Are deployment slots used for all WordPress application updates?' -Priority 3 -Status 'PASS' -Notes ("{0} deployment slot(s) found: {1}." -f @($slots.Data).Count,$slotNames)))
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'Is the previously deployed production version kept in a slot for rapid rollback?' -Priority 3 -Status 'MANUAL' -Notes ("Slots found: {0}. Confirm the previous production build is retained in a slot after each swap to enable instant rollback." -f $slotNames)))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'Are deployment slots used for all WordPress application updates?' -Priority 3 -Status 'FAIL' -Notes 'No deployment slots found. Add a staging slot for zero-downtime deployments.'))
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'Is the previously deployed production version kept in a slot for rapid rollback?' -Priority 3 -Status 'FAIL' -Notes 'No deployment slots found — no rollback slot possible.'))
}

# ARR affinity disabled
if ($webApp.Success -and $webApp.Data) {
    $affinity = Get-SafePropertyValue -InputObject $webApp.Data -Path @('clientAffinityEnabled')
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'Is ARR affinity disabled to keep WordPress stateless during deployment?' -Priority 3 -Status $(if($affinity-eq$false){'PASS'}else{'FAIL'}) -Notes ("clientAffinityEnabled = {0}. Disabling ARR affinity ensures slot swaps work correctly in a stateless configuration." -f $affinity)))
}

# ZIP package deployment
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'Are immutable deployments used via ZIP package?' -Priority 3 -Status $(if($runFromPkg-eq'1'){'PASS'}else{'FAIL'}) -Notes ("WEBSITE_RUN_FROM_PACKAGE = {0}." -f $runFromPkg)))

# HA scaling on standby first
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $haMode = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','mode')
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'For HA-enabled servers is scaling performed on the standby first?' -Priority 3 -Status 'MANUAL' -Notes ("HA mode = {0}. {1}" -f $haMode,$(if($haMode-eq'ZoneRedundant'){'Zone-redundant HA is enabled. Confirm the operational procedure scales the standby server before the primary to avoid failover during compute tier changes.'}else{'HA is not ZoneRedundant — standby-first scaling procedure may not apply.'}))))

    # Primary keys for near-zero-downtime patching
    $innodbFilePer = if($paramInnodbFilePer.Success -and $paramInnodbFilePer.Data){Get-SafePropertyValue -InputObject $paramInnodbFilePer.Data -Path @('value')}else{'unknown'}
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'Do all tables have explicit primary keys to enable near-zero-downtime patching?' -Priority 3 -Status 'MANUAL' -Notes ("innodb_file_per_table = {0}. MySQL online DDL and near-zero-downtime patching require all InnoDB tables to have explicit primary keys. Verify via: SELECT * FROM information_schema.tables WHERE table_type='BASE TABLE' AND engine='InnoDB' AND table_rows > 0 ... (check for no implicit PKs)." -f $innodbFilePer)))
}

# OE:11 Safe Deployment Practices — P5 additions
$oeSlotCount = if ($slots.Success -and $slots.Data) { @($slots.Data).Count } else { 0 }
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'Are blue-green or canary deployment patterns used?' -Priority 5 -Status $(if($oeSlotCount -gt 0){'MANUAL'}else{'FAIL'}) -Notes ("Slot count = {0}. {1}" -f $oeSlotCount,$(if($oeSlotCount -gt 0){'Deployment slots are present. Confirm the deployment process follows blue-green (100% swap) or canary (percentage routing via slot routing rules) patterns to limit blast radius of bad deployments.'}else{'No deployment slots — blue-green and canary patterns are not possible without at least one non-production slot.'}))))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:11 Safe Deployment Practices' -Question 'Is early-access maintenance policy applied to non-production MySQL servers to detect breaking changes?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine non-production server list via az CLI. Configure non-production MySQL Flexible Servers to receive minor version updates earlier than production to detect breaking changes in the lower environment first.'))

# ---- OE:01 Organisational Standards — P4 (new section) ----
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:01 Organisational Standards' -Question 'Is there clear workload ownership with a named owner for the WordPress App Service and MySQL resources?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm a named individual or team is designated as the workload owner in the RACI or operating model documentation.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:01 Organisational Standards' -Question 'Is there an up-to-date operational runbook for the WordPress workload?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. The runbook should cover: deployment procedure, slot swap steps, autoscale verification, MySQL failover procedure, backup/restore testing, and DR activation.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:01 Organisational Standards' -Question 'Is there a post-incident review (PIR) process defined for P1 and P2 incidents?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. A PIR process ensures learnings from incidents drive operational improvements. Confirm PIRs are mandatory for P1/P2 incidents and findings are tracked to closure.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:01 Organisational Standards' -Question 'Is an Architecture Decision Record (ADR) log maintained?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. ADRs document key technology choices (e.g. why AFD over Application Gateway, why MySQL over other engines) to preserve context for future changes.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:01 Organisational Standards' -Question 'Is a designated database owner assigned for the MySQL Flexible Server?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm a named owner is responsible for MySQL server parameter configuration, maintenance windows, backup policy, and major version upgrades.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:01 Organisational Standards' -Question 'Does the MySQL database owner understand immutable settings (HA mode cannot be changed after creation)?' -Priority 4 -Status 'MANUAL' -Notes 'High Availability mode on MySQL Flexible Server cannot be changed after server creation — HA can only be enabled/disabled, not the mode. Confirm the owner understands which settings require server recreation.'))

# ---- OE:03 Source Control — P4 (new section) ----
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:03 Source Control' -Question 'Are WordPress customisations (themes, plugins, configuration) stored in source control?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm all WordPress customisations are tracked in a git repository — not managed via SFTP or wp-admin file editor.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:03 Source Control' -Question 'Is all infrastructure defined as code and stored in source control?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Bicep/ARM/Terraform templates for App Service, MySQL, AFD, Key Vault, and networking should be version-controlled alongside application code.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:03 Source Control' -Question 'Is a branching strategy (e.g. GitFlow or trunk-based) consistently followed?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. A defined branching strategy reduces merge conflicts and clarifies the path from feature development through staging to production.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:03 Source Control' -Question 'Are pull requests required and reviewed before merging to main/production branches?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Mandatory PRs with at least one reviewer prevent unreviewed code from reaching production.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:03 Source Control' -Question 'Is a changelog maintained for WordPress customisation releases?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. A changelog provides an audit trail for what changed in each release and supports post-incident root cause identification.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:03 Source Control' -Question 'Are GTID-incompatible MySQL operations (CREATE TABLE ... SELECT, non-transactional DDL) validated before execution?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. MySQL Flexible Server uses GTID-based replication — operations incompatible with GTID will break replication. Review DDL scripts before execution in HA or replicated environments.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:03 Source Control' -Question 'Is a MySQL major version upgrade plan documented (e.g. MySQL 8.0 → 8.4 → 9.x)?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Major version upgrades on MySQL Flexible Server require in-place upgrade testing on a restored copy. Confirm an upgrade plan exists before the current version reaches end-of-support.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:03 Source Control' -Question 'Is an upgrade runbook available for MySQL minor version patch procedures?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm the maintenance window, health check path, and rollback steps are documented for minor version patches.'))

# ---- OE:08 Incident Management — P4 additions ----
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:08 Incident Management' -Question 'Is the manual failover procedure for MySQL zone-redundant HA documented?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Manual failover can be triggered via: az mysql flexible-server restart --name {server} --resource-group {rg} --failover Forced. Confirm this is documented and tested.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:08 Incident Management' -Question 'Is the slot rollback procedure (immediate swap-back) documented?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm a documented procedure exists to immediately re-swap slots to the last known good build within the 48-hour swap history window.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:08 Incident Management' -Question 'Has MySQL PITR been tested as part of the DR exercise?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. MySQL PITR should be tested at least annually. Confirm RTO from a PITR restore to a new server has been measured and documented.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:08 Incident Management' -Question 'Has forced failover of MySQL HA been tested in a non-production environment?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Forced failover tests confirm the standby promotion time meets RTO requirements and the application reconnects automatically after failover.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:08 Incident Management' -Question 'Is a post-incident review (PIR) process used after every P1/P2 incident?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. PIRs should be completed within 48 hours of resolution. Findings should be tracked as remediation tasks with owners and due dates.'))

# ---- OE:09 Testing — P4 (new section) ----
if ($siteConfig.Success -and $siteConfig.Data) {
    $healthCheckPath = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('healthCheckPath')
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Has the App Service health check path been validated to return 200 under all deployment configurations?' -Priority 4 -Status $(if($null -ne $healthCheckPath -and $healthCheckPath -ne ''){'MANUAL'}else{'WARN'}) -Notes ("healthCheckPath = {0}. {1}" -f $healthCheckPath,$(if($null -ne $healthCheckPath -and $healthCheckPath -ne ''){'Confirm the health check endpoint returns HTTP 200 within the timeout after a slot swap and after autoscale scale-out events.'}else{'No health check path configured. Add a dedicated health check endpoint to enable App Service instance health monitoring and deployment validation.'}))))
} else {
    $findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Has the App Service health check path been validated to return 200 under all deployment configurations?' -Priority 4 -Status 'UNKNOWN' -Notes 'Could not retrieve site config to verify health check path.'))
}
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Are performance and load tests performed before major deployments?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Load tests (e.g. Azure Load Testing or k6) should be run against the staging slot before slot swap to validate response time and autoscale behaviour under expected peak load.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Are functional tests run in the staging slot before production swap?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm a smoke test suite runs against the staging slot URL after each deployment and before any slot swap is initiated.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Are WordPress plugin compatibility tests run before activating new or updated plugins?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Plugin conflicts are a leading cause of WordPress outages. Confirm a staging/test environment is used to validate plugin compatibility before production activation.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Are MySQL migration scripts tested with dry-run before production execution?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Schema migrations should be rehearsed against a PITR-restored copy of the production database to validate execution time, locking impact, and rollback steps.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Has autoscale been validated — does scale-out occur as expected under load?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Validate autoscale by running a load test that exceeds the CPU/memory threshold and confirming: (1) scale-out fires within the cooldown window, (2) new instances pass health checks before receiving traffic.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Are auto-heal rules tested to confirm they trigger and recover correctly?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Auto-heal rules (request count, slow requests, HTTP error count, memory limit) should be tested by simulating the trigger condition to confirm the action (recycle, custom action) fires as configured.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Has chaos/fault injection testing been performed?' -Priority 5 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Chaos engineering (Azure Chaos Studio or manual fault injection) validates that the system self-heals from instance failures, MySQL failovers, and network partitions.'))
$findings.Add((New-OeFinding -OeArea 'Operational Excellence' -SubArea 'OE:09 Testing' -Question 'Has connection retry and exponential back-off been validated after MySQL failover?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. MySQL HA failover (typically 60–120 seconds) requires the application to retry connections. Confirm the WordPress MySQL driver (mysqli/PDO) is configured with connection retry logic and the WordPress object cache handles reconnection correctly.'))

# ---------------------------------------------------------------------------
# Build report
# ---------------------------------------------------------------------------
$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeAppName = ($AppServiceName -replace '[^A-Za-z0-9._-]','-')
$reportPath  = Join-Path -Path $OutputDirectory -ChildPath ("OperationalExcellenceReport-{0}-{1}.md" -f $safeAppName,$timestamp)

$builder = [System.Text.StringBuilder]::new()
Add-MarkdownLine -Builder $builder -Text ('# WAF Operational Excellence Review Report: {0}' -f $AppServiceName)
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text ('Generated: {0}' -f (Get-Date).ToString('u'))
Add-MarkdownLine -Builder $builder -Text ('Resource Group: `{0}`' -f $ResourceGroup)
Add-MarkdownLine -Builder $builder -Text ('App Service: `{0}`' -f $AppServiceName)
Add-MarkdownLine -Builder $builder -Text ('MySQL Flexible Server: `{0}`' -f $MySqlServerName)
if ($Subscription) { Add-MarkdownLine -Builder $builder -Text ('Subscription: `{0}`' -f $Subscription) }
Add-MarkdownLine -Builder $builder -Text 'Sensitive values redacted.'
Add-MarkdownLine -Builder $builder -Text '> Covers WAF Operational Excellence questions at Priority 1 through 5.'
Add-MarkdownLine -Builder $builder

$mysqlHaMode    = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('highAvailability','mode')
$mysqlVersion   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('version')
$mysqlNetMode   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('network','publicNetworkAccess')
$planTier       = if($plan -and $plan.Data){Get-SafePropertyValue -InputObject $plan.Data -Path @('sku','tier')}else{'unknown'}
$planZoneRedun  = if($plan -and $plan.Data){Get-SafePropertyValue -InputObject $plan.Data -Path @('zoneRedundant')}else{'unknown'}

$mysqlMaintenanceCustom = if($paramMaintenanceWin.Success -and $paramMaintenanceWin.Data){Get-SafePropertyValue -InputObject $paramMaintenanceWin.Data -Path @('customWindow')}else{'unknown'}
$mysqlMaintenanceDay    = if($paramMaintenanceWin.Success -and $paramMaintenanceWin.Data){Get-SafePropertyValue -InputObject $paramMaintenanceWin.Data -Path @('dayOfWeek')}else{'unknown'}
$mysqlMaintenanceHour   = if($paramMaintenanceWin.Success -and $paramMaintenanceWin.Data){Get-SafePropertyValue -InputObject $paramMaintenanceWin.Data -Path @('startHour')}else{'unknown'}

$summary = [ordered]@{
    'Subscription'                    = Get-SafePropertyValue -InputObject $account.Data -Path @('name')
    'Resource Group'                  = $ResourceGroup
    'App Service Plan Tier'           = $planTier
    'App Service Plan Zone Redundant' = $planZoneRedun
    'App Service clientAffinityEnabled'= Get-SafePropertyValue -InputObject $webApp.Data -Path @('clientAffinityEnabled')
    'WEBSITE_RUN_FROM_PACKAGE'        = $runFromPkg
    'Deployment Slots'                = if($slots.Success -and $slots.Data){@($slots.Data).Count}else{0}
    'App Insights Present'            = $hasAppInsights
    'App Diagnostic Settings to LA'   = $appLogsEnabled
    'MySQL Version'                   = $mysqlVersion
    'MySQL HA Mode'                   = $mysqlHaMode
    'MySQL Network Mode'              = $mysqlNetMode
    'MySQL Maintenance Custom Window' = $mysqlMaintenanceCustom
    'MySQL Maintenance Day'           = $mysqlMaintenanceDay
    'MySQL Maintenance Start Hour'    = $mysqlMaintenanceHour
    'MySQL AuditLogs to LA'           = $mysqlAuditToLa
    'MySQL SlowLogs to LA'            = $mysqlSlowToLa
    'CanNotDelete Lock on MySQL'      = ($mysqlLock.Success -and $mysqlLock.Data -and @($mysqlLock.Data|Where-Object{(Get-SafePropertyValue -InputObject $_ -Path @('level')) -eq 'CanNotDelete' -or (Get-SafePropertyValue -InputObject $_ -Path @('properties','level')) -eq 'CanNotDelete'}).Count-gt 0)
    'Policy Assignments'              = if($policyAssignments.Success -and $policyAssignments.Data){@($policyAssignments.Data).Count}else{0}
    'Alert Rules'                     = if($appAlertRules.Success -and $appAlertRules.Data){@($appAlertRules.Data).Count}else{0}
    'Open Advisor Recommendations'    = if($advisorRecs.Success -and $advisorRecs.Data){@($advisorRecs.Data|Where-Object{$suppIds = Get-SafePropertyValue -InputObject $_ -Path @('properties','suppressionIds'); $null -eq $suppIds -or @($suppIds).Count -eq 0}).Count}else{'unknown'}
    'require_secure_transport'        = if($paramRequireSecure.Success -and $paramRequireSecure.Data){Get-SafePropertyValue -InputObject $paramRequireSecure.Data -Path @('value')}else{'unknown'}
    'tls_version'                     = if($paramTlsVersion.Success -and $paramTlsVersion.Data){Get-SafePropertyValue -InputObject $paramTlsVersion.Data -Path @('value')}else{'unknown'}
    'slow_query_log'                  = if($paramSlowQuery.Success -and $paramSlowQuery.Data){Get-SafePropertyValue -InputObject $paramSlowQuery.Data -Path @('value')}else{'unknown'}
    'audit_log_enabled'               = if($paramAuditLog.Success -and $paramAuditLog.Data){Get-SafePropertyValue -InputObject $paramAuditLog.Data -Path @('value')}else{'unknown'}
    'local_infile'                    = if($paramLocalInfile.Success -and $paramLocalInfile.Data){Get-SafePropertyValue -InputObject $paramLocalInfile.Data -Path @('value')}else{'unknown'}
}

Add-MarkdownLine -Builder $builder -Text '## Summary'
Add-KeyValueTable -Builder $builder -Values $summary
Add-OeAssessmentSection -Builder $builder -Findings $findings

Add-MarkdownLine -Builder $builder -Text '## Raw Data'; Add-MarkdownLine -Builder $builder
Add-JsonSection -Builder $builder -Title 'Azure Account Context'               -Result $account
Add-JsonSection -Builder $builder -Title 'Resource Group Overview'             -Result $rgResult
Add-JsonSection -Builder $builder -Title 'App Service Overview'                -Result $webApp
Add-JsonSection -Builder $builder -Title 'App Service Site Config'             -Result $siteConfig
Add-JsonSection -Builder $builder -Title 'App Service App Settings'            -Result $appSettings
Add-JsonSection -Builder $builder -Title 'App Service Deployment Slots'        -Result $slots
Add-JsonSection -Builder $builder -Title 'App Service Hostname Bindings'       -Result $hostnameBindings
Add-JsonSection -Builder $builder -Title 'App Service SSL Certificates'        -Result $sslCerts
Add-JsonSection -Builder $builder -Title 'App Service Diagnostic Settings'     -Result $appDiagSettings
Add-JsonSection -Builder $builder -Title 'Application Insights Component'      -Result $appInsightsResult
Add-JsonSection -Builder $builder -Title 'Azure Monitor Alert Rules'           -Result $appAlertRules
Add-JsonSection -Builder $builder -Title 'Service Health Alerts'               -Result $serviceHealthAlerts
if ($plan) { Add-JsonSection -Builder $builder -Title 'App Service Plan Overview' -Result $plan }
if ($autoscaleSettings) { Add-JsonSection -Builder $builder -Title 'App Service Autoscale Settings' -Result $autoscaleSettings }
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Overview'      -Result $mysqlServer
Add-JsonSection -Builder $builder -Title 'MySQL Diagnostic Settings'           -Result $mysqlDiagSettings
Add-JsonSection -Builder $builder -Title 'MySQL Entra Admins'                  -Result $mysqlAdmins
Add-JsonSection -Builder $builder -Title 'MySQL Firewall Rules'                -Result $mysqlFirewallRules
Add-JsonSection -Builder $builder -Title 'MySQL Replicas'                      -Result $mysqlReplicas
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: slow_query_log'     -Result $paramSlowQuery
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: require_secure_transport' -Result $paramRequireSecure
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: tls_version'        -Result $paramTlsVersion
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: max_connections'    -Result $paramMaxConn
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: innodb_file_per_table' -Result $paramInnodbFilePer
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: local_infile'       -Result $paramLocalInfile
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: audit_log_enabled'  -Result $paramAuditLog
Add-JsonSection -Builder $builder -Title 'MySQL Maintenance Window'            -Result $paramMaintenanceWin
Add-JsonSection -Builder $builder -Title 'Resource Group Locks'                -Result $resourceLocks
Add-JsonSection -Builder $builder -Title 'MySQL Server Lock'                   -Result $mysqlLock
Add-JsonSection -Builder $builder -Title 'Resource Group Policy Assignments'   -Result $policyAssignments
Add-JsonSection -Builder $builder -Title 'Azure Advisor Recommendations'       -Result $advisorRecs
Add-JsonSection -Builder $builder -Title 'Log Analytics Workspaces'            -Result $logAnalytics
Add-JsonSection -Builder $builder -Title 'Storage Accounts'                    -Result $storagAccts
Add-JsonSection -Builder $builder -Title 'Key Vaults'                          -Result $keyVaults
Add-JsonSection -Builder $builder -Title 'Resource Tags'                       -Result $resourceTags
Add-CollectionStatusSection -Builder $builder -Results $results

[System.IO.File]::WriteAllText($reportPath, $builder.ToString(), [System.Text.Encoding]::UTF8)
Write-StatusMessage -Level OK -Message ("Operational Excellence report written to {0}" -f $reportPath)
