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

    # Optional: Azure Front Door profile name for WAF checks.
    # If omitted the script will attempt to discover AFD profiles in the resource group.
    [string]$AfdProfileName,

    # Optional: resource group that contains the AFD profile when it differs from $ResourceGroup.
    [string]$AfdResourceGroup
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helper utilities
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

        [Parameter(Mandatory = $true)]
        [string[]]$Path
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

function Get-SafeArrayText {
    param($Value)

    if ($null -eq $Value) { return '' }
    return (@($Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join ','
}

function Test-AzureCliPrerequisites {
    if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI was not found in PATH. Install Azure CLI before running this script.'
    }
}

function Get-CommandText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '\s') { '"{0}"' -f $argument.Replace('"', '\"') }
        else { $argument }
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
        $subName = Get-SafePropertyValue -InputObject $AccountResult.Data -Path @('name')
        $subId   = Get-SafePropertyValue -InputObject $AccountResult.Data -Path @('id')
        $effective = if ($Subscription) { $Subscription } elseif ($subId) { $subId } else { '(unknown)' }
        Write-Error ("[CRITICAL] Resource group '{0}' was not found. Active subscription: {1} ({2}). Effective: {3}. Script will continue but all resource data will be unavailable. Error: {4}" -f $ResourceGroupName, $subName, $subId, $effective, $resourceGroupResult.ErrorMessage)
    }
    return $resourceGroupResult
}

# ---------------------------------------------------------------------------
# Security Assessment helpers
# ---------------------------------------------------------------------------
function New-SecurityFinding {
    param(
        [Parameter(Mandatory = $true)][string]$WafArea,
        [Parameter(Mandatory = $true)][string]$SubArea,
        [Parameter(Mandatory = $true)][string]$Question,
        [Parameter(Mandatory = $true)][int]$Priority,
        [ValidateSet('PASS', 'FAIL', 'UNKNOWN', 'MANUAL')][string]$Status = 'UNKNOWN',
        [string]$Notes = ''
    )
    [pscustomobject]@{
        WafArea  = $WafArea
        SubArea  = $SubArea
        Question = $Question
        Priority = $Priority
        Status   = $Status
        Notes    = $Notes
    }
}

function Add-SecurityAssessmentSection {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Findings
    )

    $passCount    = @($Findings | Where-Object { $_.Status -eq 'PASS' }).Count
    $failCount    = @($Findings | Where-Object { $_.Status -eq 'FAIL' }).Count
    $unknownCount = @($Findings | Where-Object { $_.Status -eq 'UNKNOWN' }).Count
    $manualCount  = @($Findings | Where-Object { $_.Status -eq 'MANUAL' }).Count

    Add-MarkdownLine -Builder $Builder -Text '## Security Assessment'
    Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text ('**PASS:** {0} | **FAIL:** {1} | **UNKNOWN:** {2} | **MANUAL REVIEW REQUIRED:** {3}' -f $passCount, $failCount, $unknownCount, $manualCount)
    Add-MarkdownLine -Builder $Builder
    Add-MarkdownLine -Builder $Builder -Text '> Status key: **PASS** = confirmed compliant  |  **FAIL** = confirmed non-compliant  |  **UNKNOWN** = data could not be retrieved  |  **MANUAL** = cannot be determined via az CLI alone'
    Add-MarkdownLine -Builder $Builder

    # Group by WAF sub-area
    $subAreas = $Findings | Select-Object -ExpandProperty SubArea | Select-Object -Unique
    foreach ($subArea in $subAreas) {
        $group = $Findings | Where-Object { $_.SubArea -eq $subArea }
        $wafArea = ($group | Select-Object -First 1).WafArea

        Add-MarkdownLine -Builder $Builder -Text ('### {0} — {1}' -f $wafArea, $subArea)
        Add-MarkdownLine -Builder $Builder
        Add-MarkdownLine -Builder $Builder -Text '| Priority | Status | Question | Notes |'
        Add-MarkdownLine -Builder $Builder -Text '| --- | --- | --- | --- |'

        foreach ($finding in $group) {
            $statusBadge = switch ($finding.Status) {
                'PASS'    { '✅ PASS' }
                'FAIL'    { '❌ FAIL' }
                'UNKNOWN' { '⚠️ UNKNOWN' }
                'MANUAL'  { '🔍 MANUAL' }
            }
            Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} | {2} | {3} |' -f $finding.Priority, $statusBadge, (ConvertTo-MarkdownText -Value $finding.Question), (ConvertTo-MarkdownText -Value $finding.Notes))
        }
        Add-MarkdownLine -Builder $Builder
    }
}

# ---------------------------------------------------------------------------
# Script entry point
# ---------------------------------------------------------------------------
Test-AzureCliPrerequisites

trap {
    Write-StatusMessage -Level 'WARN' -Message ("Unexpected non-fatal error: {0}. Continuing with the next Security action." -f $_.Exception.Message)
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
        [Parameter(Mandatory = $true)][AllowNull()][object[]]$Arguments,
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

Write-StatusMessage -Level 'INFO' -Message ('Starting security review for App Service [{0}] and MySQL [{1}] in resource group [{2}]' -f $AppServiceName, $MySqlServerName, $ResourceGroup)

# ---------------------------------------------------------------------------
# SECTION 1 — Account and resource group
# ---------------------------------------------------------------------------
$account             = Add-QueryResult -Label 'Azure Account' -Arguments @('account', 'show') -Required
$resourceGroupResult = Assert-ResourceGroupAvailable -AccountResult $account -ResourceGroupName $ResourceGroup
$results.Add($resourceGroupResult)

# ---------------------------------------------------------------------------
# SECTION 2 — App Service data collection
# ---------------------------------------------------------------------------
$webApp              = Add-QueryResult -Label 'App Service Overview'            -Arguments @('webapp', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup) -Required
$webAppId            = Get-SafePropertyValue -InputObject $webApp.Data -Path @('id')
$planId              = Get-SafePropertyValue -InputObject $webApp.Data -Path @('serverFarmId')
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('appServicePlanId') }
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('properties', 'serverFarmId') }
if (-not $planId) { $planId = Get-SafePropertyValue -InputObject $webApp.Data -Path @('properties', 'appServicePlanId') }
if (-not $webAppId) { Write-StatusMessage -Level 'WARN' -Message 'Could not find App Service resource ID. Dependent App Service ARM policy data will be marked unavailable.' }
if (-not $planId) { Write-StatusMessage -Level 'WARN' -Message 'Could not find App Service plan ID. Plan and autoscale details will be marked unavailable.' }

$siteConfig          = Add-QueryResult -Label 'App Service Site Config'         -Arguments @('webapp', 'config', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$appSettings         = Add-QueryResult -Label 'App Service App Settings'        -Arguments @('webapp', 'config', 'appsettings', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$accessRestrictions  = Add-QueryResult -Label 'App Service Access Restrictions' -Arguments @('webapp', 'config', 'access-restriction', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$authSettings        = Add-QueryResult -Label 'App Service Auth Settings'       -Arguments @('webapp', 'auth', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$identity            = Add-QueryResult -Label 'App Service Managed Identity'    -Arguments @('webapp', 'identity', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$vnetIntegration     = Add-QueryResult -Label 'App Service VNet Integration'    -Arguments @('webapp', 'vnet-integration', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$slots               = Add-QueryResult -Label 'App Service Deployment Slots'    -Arguments @('webapp', 'deployment', 'slot', 'list', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
$hostnameBindings    = Add-QueryResult -Label 'App Service Hostname Bindings'   -Arguments @('webapp', 'config', 'hostname', 'list', '--webapp-name', $AppServiceName, '--resource-group', $ResourceGroup)
$sslCertificates     = Add-QueryResult -Label 'App Service SSL Certificates'    -Arguments @('webapp', 'config', 'ssl', 'list', '--resource-group', $ResourceGroup)
$corsSettings        = Add-QueryResult -Label 'App Service CORS Settings'       -Arguments @('webapp', 'cors', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)

# Basic publishing credentials policies (ARM resource — requires resource id path)
$scmBasicAuthPolicy  = Add-QueryResultWhenValuePresent -Label 'App Service SCM Basic Auth Policy' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('resource', 'show', '--ids', ('{0}/basicPublishingCredentialsPolicies/scm' -f $webAppId))
$ftpBasicAuthPolicy  = Add-QueryResultWhenValuePresent -Label 'App Service FTP Basic Auth Policy' -Value $webAppId -RequiredValueName 'App Service resource ID' -Arguments @('resource', 'show', '--ids', ('{0}/basicPublishingCredentialsPolicies/ftp' -f $webAppId))

# App Service Plan
$plan = $null
if ($planId) {
    $planParts = $planId.Trim('/') -split '/'
    $planName  = $null; $planRg = $ResourceGroup
    for ($i = 0; $i -lt $planParts.Length; $i += 2) {
        if ($planParts[$i] -eq 'serverfarms' -and ($i + 1) -lt $planParts.Length) { $planName = $planParts[$i + 1] }
        if ($planParts[$i] -eq 'resourceGroups' -and ($i + 1) -lt $planParts.Length) { $planRg = $planParts[$i + 1] }
    }
    if ($planName) {
        $plan = Add-QueryResult -Label 'App Service Plan Overview' -Arguments @('appservice', 'plan', 'show', '--name', $planName, '--resource-group', $planRg)
    }
}

# Autoscale settings for the plan
$autoscaleSettings = $null
if ($planId) {
    $autoscaleSettings = Add-QueryResult -Label 'App Service Plan Autoscale Settings' -Arguments @('monitor', 'autoscale', 'list', '--resource-group', $ResourceGroup)
}

# ---------------------------------------------------------------------------
# SECTION 3 — Networking — private endpoints and NSGs
# ---------------------------------------------------------------------------
$privateEndpoints    = Add-QueryResult -Label 'Resource Group Private Endpoints' -Arguments @('network', 'private-endpoint', 'list', '--resource-group', $ResourceGroup)
$nsgList             = Add-QueryResult -Label 'Resource Group NSGs'               -Arguments @('network', 'nsg', 'list', '--resource-group', $ResourceGroup)
$vnetList            = Add-QueryResult -Label 'Resource Group VNets'              -Arguments @('network', 'vnet', 'list', '--resource-group', $ResourceGroup)

# ---------------------------------------------------------------------------
# SECTION 4 — WAF / Azure Front Door
# ---------------------------------------------------------------------------
$afdProfileRg = if ($AfdResourceGroup) { $AfdResourceGroup } else { $ResourceGroup }

$afdProfiles  = Add-QueryResult -Label 'Azure Front Door Profiles' -Arguments @('afd', 'profile', 'list', '--resource-group', $afdProfileRg)

# Resolve the profile name: prefer explicit param, then first found in RG
$resolvedAfdProfileName = $AfdProfileName
if (-not $resolvedAfdProfileName -and $afdProfiles.Success -and $afdProfiles.Data) {
    $firstProfile = @($afdProfiles.Data)[0]
    $resolvedAfdProfileName = Get-SafePropertyValue -InputObject $firstProfile -Path @('name')
    if ($resolvedAfdProfileName) {
        Write-StatusMessage -Level 'INFO' -Message ("Auto-detected AFD profile: {0}" -f $resolvedAfdProfileName)
    } else {
        Write-StatusMessage -Level 'WARN' -Message 'Azure Front Door profile list returned data, but no profile name could be found.'
    }
}

$afdSecurityPolicies = $null
$afdWafPolicies      = $null

if ($resolvedAfdProfileName) {
    $afdSecurityPolicies = Add-QueryResult -Label 'AFD Security Policies' -Arguments @('afd', 'security-policy', 'list', '--profile-name', $resolvedAfdProfileName, '--resource-group', $afdProfileRg)

    # Discover WAF policy IDs from security policies and query each
    if ($afdSecurityPolicies.Success -and $afdSecurityPolicies.Data) {
        $wafPolicyIds = @(
            @($afdSecurityPolicies.Data) | ForEach-Object {
                $wafPolicyId = Get-SafePropertyValue -InputObject $_ -Path @('parameters', 'wafPolicy', 'id')
                if (-not $wafPolicyId) {
                    $wafPolicyId = Get-SafePropertyValue -InputObject $_ -Path @('wafPolicy', 'id')
                }
                $wafPolicyId
            } | Where-Object { $_ }
        )

        if ($wafPolicyIds.Count -gt 0) {
            $wafPolicyId = $wafPolicyIds[0]
            $afdWafPolicies = Add-QueryResult -Label 'AFD WAF Policy' -Arguments @('resource', 'show', '--ids', $wafPolicyId)
        }
    }
}

# Also check for classic Application Gateway WAF in the resource group
$appGateways = Add-QueryResult -Label 'Application Gateways' -Arguments @('network', 'application-gateway', 'list', '--resource-group', $ResourceGroup)

# ---------------------------------------------------------------------------
# SECTION 5 — MySQL data collection
# ---------------------------------------------------------------------------
$mysqlServer         = Add-QueryResult -Label 'MySQL Flexible Server Overview'    -Arguments @('mysql', 'flexible-server', 'show', '--name', $MySqlServerName, '--resource-group', $ResourceGroup) -Required

$mysqlParameters     = Add-QueryResult -Label 'MySQL Flexible Server Parameters'  -Arguments @('mysql', 'flexible-server', 'parameter', 'list', '--server-name', $MySqlServerName, '--resource-group', $ResourceGroup)
$mysqlFirewallRules  = Add-QueryResult -Label 'MySQL Flexible Server Firewall Rules' -Arguments @('mysql', 'flexible-server', 'firewall-rule', 'list', '--name', $MySqlServerName, '--resource-group', $ResourceGroup)
$mysqlEntraAdmins    = Add-QueryResult -Label 'MySQL Flexible Server Entra Admins' -Arguments @('mysql', 'flexible-server', 'ad-admin', 'list', '--server-name', $MySqlServerName, '--resource-group', $ResourceGroup)
$mysqlThreatProtect  = Add-QueryResult -Label 'MySQL Flexible Server Threat Protection' -Arguments @('mysql', 'flexible-server', 'advanced-threat-protection-setting', 'show', '--name', $MySqlServerName, '--resource-group', $ResourceGroup)

# Specific parameters needed for security checks
$paramRequireSecureTransport = Add-QueryResult -Label 'MySQL Parameter: require_secure_transport' -Arguments @('mysql', 'flexible-server', 'parameter', 'show', '--server-name', $MySqlServerName, '--resource-group', $ResourceGroup, '--name', 'require_secure_transport')
$paramTlsVersion             = Add-QueryResult -Label 'MySQL Parameter: tls_version'              -Arguments @('mysql', 'flexible-server', 'parameter', 'show', '--server-name', $MySqlServerName, '--resource-group', $ResourceGroup, '--name', 'tls_version')
$paramSlowQueryLog           = Add-QueryResult -Label 'MySQL Parameter: slow_query_log'           -Arguments @('mysql', 'flexible-server', 'parameter', 'show', '--server-name', $MySqlServerName, '--resource-group', $ResourceGroup, '--name', 'slow_query_log')

# ---------------------------------------------------------------------------
# SECTION 6 — Governance
# ---------------------------------------------------------------------------
$defenderAppService  = Add-QueryResult -Label 'Microsoft Defender for App Service' -Arguments @('security', 'pricing', 'show', '--name', 'AppServices')
$advisorSecurity     = Add-QueryResult -Label 'Azure Advisor Security Recommendations' -Arguments @('advisor', 'recommendation', 'list', '--resource-group', $ResourceGroup, '--category', 'Security')
$roleAssignments     = Add-QueryResult -Label 'Resource Group RBAC Role Assignments' -Arguments @('role', 'assignment', 'list', '--resource-group', $ResourceGroup, '--include-inherited')
$policyAssignments   = Add-QueryResult -Label 'Resource Group Policy Assignments'   -Arguments @('policy', 'assignment', 'list', '--resource-group', $ResourceGroup)
$resourceGroupTags   = Add-QueryResult -Label 'Resource Group Tags'                 -Arguments @('group', 'show', '--name', $ResourceGroup, '--query', 'tags')

# ---------------------------------------------------------------------------
# SECTION 7 — Evaluate security findings
# ---------------------------------------------------------------------------
$findings = [System.Collections.Generic.List[object]]::new()

# ---- SE:01 Security Baseline & Governance ----

# Microsoft Defender for App Service
if ($defenderAppService.Success -and $defenderAppService.Data) {
    $pricingTier = Get-SafePropertyValue -InputObject $defenderAppService.Data -Path @('pricingTier')
    if ($pricingTier -eq 'Standard') {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Is Microsoft Defender for App Service enabled?' -Priority 3 -Status 'PASS' -Notes ('Pricing tier: {0}' -f $pricingTier)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Is Microsoft Defender for App Service enabled?' -Priority 3 -Status 'FAIL' -Notes ('Pricing tier is [{0}] — expected Standard' -f $pricingTier)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Is Microsoft Defender for App Service enabled?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve Defender pricing tier.'))
}

# Resource tagging
$webAppTags = Get-SafePropertyValue -InputObject $webApp.Data -Path @('tags')
if ($webApp.Success -and $webAppTags -and ($webAppTags.PSObject.Properties | Measure-Object).Count -gt 0) {
    $tagList = ($webAppTags.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join ', '
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Are resources tagged for cost allocation and security classification?' -Priority 3 -Status 'PASS' -Notes ('Tags found: {0}' -f $tagList)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Are resources tagged for cost allocation and security classification?' -Priority 3 -Status 'FAIL' -Notes 'No tags found on the App Service resource.'))
}

# Azure Policy assignments
if ($policyAssignments.Success -and $policyAssignments.Data) {
    $policyCount = @($policyAssignments.Data).Count
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Are Azure Policy definitions for App Service applied?' -Priority 3 -Status 'MANUAL' -Notes ('{0} policy assignment(s) found in resource group. Review raw data to confirm App Service/MySQL policies are included.' -f $policyCount)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Are Azure Policy definitions for App Service applied?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve policy assignments.'))
}

# Advisor security recommendations
if ($advisorSecurity.Success -and $advisorSecurity.Data) {
    $openRecs = @($advisorSecurity.Data | Where-Object {
        $suppIds = if ($_.PSObject.Properties['properties'] -and $null -ne $_.properties) { $_.properties.suppressionIds } else { $null }
        $null -eq $suppIds -or @($suppIds).Count -eq 0
    })
    if ($openRecs.Count -eq 0) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Are Azure Advisor security recommendations reviewed and acted on regularly?' -Priority 3 -Status 'PASS' -Notes 'No open security recommendations found in resource group.'))
    } else {
        $recTitles = ($openRecs | Select-Object -First 5 | ForEach-Object { Get-SafePropertyValue -InputObject $_ -Path @('shortDescription', 'solution') }) -join '; '
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Are Azure Advisor security recommendations reviewed and acted on regularly?' -Priority 3 -Status 'FAIL' -Notes ('{0} open recommendation(s). Sample: {1}' -f $openRecs.Count, $recTitles)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Are Azure Advisor security recommendations reviewed and acted on regularly?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve Advisor recommendations.'))
}

# MySQL parameter baseline
if ($mysqlParameters.Success -and $mysqlParameters.Data) {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Is an approved MySQL parameter configuration baseline documented and changes audited?' -Priority 3 -Status 'MANUAL' -Notes ('MySQL parameter list retrieved ({0} parameters). Review raw data section against approved baseline.' -f @($mysqlParameters.Data).Count)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:01 Security Baseline and Governance' -Question 'Is an approved MySQL parameter configuration baseline documented and changes audited?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve MySQL parameters.'))
}

# ---- SE:04 Segmentation and Network Isolation ----

# Public network access disabled on App Service (Priority 1)
if ($webApp.Success -and $webApp.Data) {
    $pna = Get-SafePropertyValue -InputObject $webApp.Data -Path @('publicNetworkAccess')
    if ($pna -eq 'Disabled') {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is public network access disabled on App Service?' -Priority 1 -Status 'PASS' -Notes ('publicNetworkAccess = {0}' -f $pna)))
    } elseif ($null -eq $pna) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is public network access disabled on App Service?' -Priority 1 -Status 'UNKNOWN' -Notes 'publicNetworkAccess property not present in response. May not be supported at this API version.'))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is public network access disabled on App Service?' -Priority 1 -Status 'FAIL' -Notes ('publicNetworkAccess = {0}' -f $pna)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is public network access disabled on App Service?' -Priority 1 -Status 'UNKNOWN' -Notes 'App Service data not available.'))
}

# VNet Integration
if ($vnetIntegration.Success -and $vnetIntegration.Data -and @($vnetIntegration.Data).Count -gt 0) {
    $vnetName = Get-SafePropertyValue -InputObject @($vnetIntegration.Data)[0] -Path @('name')
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is App Service deployed with VNet Integration?' -Priority 3 -Status 'PASS' -Notes ('VNet integration found: {0}' -f $vnetName)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is App Service deployed with VNet Integration?' -Priority 3 -Status 'FAIL' -Notes 'No VNet integration found.'))
}

# Private endpoint for App Service
if ($privateEndpoints.Success -and $privateEndpoints.Data) {
    $appServicePe = @($privateEndpoints.Data | Where-Object {
        $svcIds = @($_.privateLinkServiceConnections | ForEach-Object { $_.privateLinkServiceId })
        $svcIds -contains $webAppId
    })
    if ($appServicePe.Count -gt 0) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is a Private Endpoint configured for App Service to block public internet access?' -Priority 3 -Status 'PASS' -Notes ('{0} private endpoint(s) associated with App Service.' -f $appServicePe.Count)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is a Private Endpoint configured for App Service to block public internet access?' -Priority 3 -Status 'FAIL' -Notes 'No private endpoints found targeting the App Service resource id. Check raw private endpoint data.'))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is a Private Endpoint configured for App Service to block public internet access?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve private endpoints.'))
}

# WAF deployed
$wafDeployed = $false
$wafNote     = 'No Azure Front Door profile or Application Gateway found in resource group.'
if ($afdProfiles.Success -and $afdProfiles.Data -and @($afdProfiles.Data).Count -gt 0) {
    $wafDeployed = $true
    $wafNote = ('AFD profile(s) found: {0}' -f ((@($afdProfiles.Data) | ForEach-Object { $_.name }) -join ', '))
} elseif ($appGateways.Success -and $appGateways.Data -and @($appGateways.Data).Count -gt 0) {
    $wafDeployed = $true
    $wafNote = ('Application Gateway(s) found: {0}' -f ((@($appGateways.Data) | ForEach-Object { $_.name }) -join ', '))
}
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is a WAF deployed via Application Gateway or Azure Front Door?' -Priority 3 -Status $(if ($wafDeployed) { 'PASS' } else { 'FAIL' }) -Notes $wafNote))

# Egress to MySQL over private endpoint — MySQL private access check
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $mysqlPublicAccess   = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('network', 'publicNetworkAccess')
    $mysqlDelegatedSubnet = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('network', 'delegatedSubnetResourceId')

    if ($mysqlPublicAccess -eq 'Disabled' -and $mysqlDelegatedSubnet) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Does egress from App Service to MySQL go over private endpoints?' -Priority 3 -Status 'PASS' -Notes ('MySQL publicNetworkAccess=Disabled; delegated subnet configured: {0}' -f $mysqlDelegatedSubnet)))
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Was MySQL deployed with VNet integration (private access mode)?' -Priority 3 -Status 'PASS' -Notes ('Delegated subnet: {0}' -f $mysqlDelegatedSubnet)))
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is there no public network access enabled on MySQL?' -Priority 3 -Status 'PASS' -Notes ('publicNetworkAccess = {0}' -f $mysqlPublicAccess)))
    } else {
        $detail = ('publicNetworkAccess={0}; delegatedSubnet={1}' -f $mysqlPublicAccess, $mysqlDelegatedSubnet)
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Does egress from App Service to MySQL go over private endpoints?' -Priority 3 -Status 'FAIL' -Notes $detail))
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Was MySQL deployed with VNet integration (private access mode)?' -Priority 3 -Status $(if ($mysqlDelegatedSubnet) { 'PASS' } else { 'FAIL' }) -Notes $detail))
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Is there no public network access enabled on MySQL?' -Priority 3 -Status $(if ($mysqlPublicAccess -eq 'Disabled') { 'PASS' } else { 'FAIL' }) -Notes ('publicNetworkAccess = {0}' -f $mysqlPublicAccess)))
    }
} else {
    foreach ($q in @('Does egress from App Service to MySQL go over private endpoints?', 'Was MySQL deployed with VNet integration (private access mode)?', 'Is there no public network access enabled on MySQL?')) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question $q -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
    }
}

# NSG rules — manual review required
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Are NSG rules on the private endpoint subnet restricted to traffic from the reverse proxy only?' -Priority 3 -Status 'MANUAL' -Notes 'NSG rules collected in raw data. Cross-reference subnet address ranges with NSG inbound rules to confirm restriction.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:04 Segmentation and Network Isolation' -Question 'Are NSG rules applied to the MySQL delegated subnet to restrict inbound to App Service subnet only?' -Priority 3 -Status 'MANUAL' -Notes 'VNet and NSG data collected in raw data. Manual review required to verify subnet-to-subnet restriction.'))

# ---- SE:05 Identity and Access Management ----

# Managed identity (Priority 1)
if ($identity.Success -and $identity.Data) {
    $principalId = Get-SafePropertyValue -InputObject $identity.Data -Path @('principalId')
    $identityType = Get-SafePropertyValue -InputObject $identity.Data -Path @('type')
    if ($principalId) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is a managed identity assigned to the App Service instance?' -Priority 1 -Status 'PASS' -Notes ('Identity type: {0}; principalId: {1}' -f $identityType, $principalId)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is a managed identity assigned to the App Service instance?' -Priority 1 -Status 'FAIL' -Notes 'No principalId found — managed identity not assigned.'))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is a managed identity assigned to the App Service instance?' -Priority 1 -Status 'FAIL' -Notes 'Identity show returned no data — managed identity not configured.'))
}

# Basic auth disabled for SCM (Priority 2)
if ($scmBasicAuthPolicy.Success -and $scmBasicAuthPolicy.Data) {
    $scmAllow = Get-SafePropertyValue -InputObject $scmBasicAuthPolicy.Data -Path @('properties', 'allow')
    if ($scmAllow -eq $false) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is basic authentication disabled for SCM/FTP?' -Priority 2 -Status 'PASS' -Notes 'SCM basicPublishingCredentialsPolicy.allow = false'))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is basic authentication disabled for SCM/FTP?' -Priority 2 -Status 'FAIL' -Notes ('SCM basicPublishingCredentialsPolicy.allow = {0}' -f $scmAllow)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is basic authentication disabled for SCM/FTP?' -Priority 2 -Status 'UNKNOWN' -Notes 'Could not retrieve SCM basic auth policy.'))
}

# Basic auth disabled for FTP (Priority 2 — reported as part of SE:05 local auth)
if ($ftpBasicAuthPolicy.Success -and $ftpBasicAuthPolicy.Data) {
    $ftpAllow = Get-SafePropertyValue -InputObject $ftpBasicAuthPolicy.Data -Path @('properties', 'allow')
    if ($ftpAllow -eq $false) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Are local authentication methods disabled?' -Priority 2 -Status 'PASS' -Notes 'FTP basicPublishingCredentialsPolicy.allow = false'))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Are local authentication methods disabled?' -Priority 2 -Status 'FAIL' -Notes ('FTP basicPublishingCredentialsPolicy.allow = {0}' -f $ftpAllow)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Are local authentication methods disabled?' -Priority 2 -Status 'UNKNOWN' -Notes 'Could not retrieve FTP basic auth policy.'))
}

# MySQL Entra ID authentication (Priority 2)
if ($mysqlEntraAdmins.Success -and $mysqlEntraAdmins.Data -and @($mysqlEntraAdmins.Data).Count -gt 0) {
    $adminNames = (@($mysqlEntraAdmins.Data) | ForEach-Object { Get-SafePropertyValue -InputObject $_ -Path @('login') }) -join ', '
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is Microsoft Entra ID authentication configured on MySQL?' -Priority 2 -Status 'PASS' -Notes ('Entra admin(s) configured: {0}' -f $adminNames)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is Microsoft Entra ID authentication configured on MySQL?' -Priority 2 -Status 'FAIL' -Notes 'No Entra ID admins found on MySQL Flexible Server.'))
}

# Entra-only auth on MySQL (Priority 2)
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $aadAuth = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('authConfig', 'activeDirectoryAuthEnabled')
    $pwdAuth = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('authConfig', 'passwordAuthEnabled')
    if ($aadAuth -eq 'Enabled' -and $pwdAuth -eq 'Disabled') {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is Entra-only authentication in use on MySQL to eliminate password-based access?' -Priority 2 -Status 'PASS' -Notes ('activeDirectoryAuthEnabled={0}; passwordAuthEnabled={1}' -f $aadAuth, $pwdAuth)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is Entra-only authentication in use on MySQL to eliminate password-based access?' -Priority 2 -Status 'FAIL' -Notes ('activeDirectoryAuthEnabled={0}; passwordAuthEnabled={1}' -f $aadAuth, $pwdAuth)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is Entra-only authentication in use on MySQL to eliminate password-based access?' -Priority 2 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# WordPress app authenticates via Entra tokens — cannot verify via CLI
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Does the WordPress application authenticate to MySQL via short-lived Entra tokens?' -Priority 2 -Status 'MANUAL' -Notes 'Requires inspection of WordPress wp-config.php and the MySQL plugin configuration. Cannot be determined via az CLI.'))

# Conditional Access on MySQL Entra — requires Graph API
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Are Conditional Access policies applied to Entra authentication on MySQL?' -Priority 2 -Status 'MANUAL' -Notes 'Requires Microsoft Graph API: GET /identity/conditionalAccess/policies. Use az rest --method GET --url https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'))

# RBAC least privilege
if ($roleAssignments.Success -and $roleAssignments.Data) {
    $ownerRoles = @($roleAssignments.Data | Where-Object { $_.roleDefinitionName -eq 'Owner' })
    $contribRoles = @($roleAssignments.Data | Where-Object { $_.roleDefinitionName -eq 'Contributor' })
    $totalAssignments = @($roleAssignments.Data).Count
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is RBAC with least privilege roles configured for team members managing App Service?' -Priority 3 -Status 'MANUAL' -Notes ('{0} total assignment(s); {1} Owner(s); {2} Contributor(s). Review raw data to confirm least privilege.' -f $totalAssignments, $ownerRoles.Count, $contribRoles.Count)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Is RBAC with least privilege roles configured for team members managing App Service?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve role assignments.'))
}

# Dedicated database user accounts — requires MySQL client
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:05 Identity and Access Management' -Question 'Are dedicated database user accounts created per application component with minimum required privileges?' -Priority 3 -Status 'MANUAL' -Notes 'Requires MySQL client: SELECT user, host FROM mysql.user; — cannot be determined via az CLI alone.'))

# ---- SE:06 Network Security ----

# WAF cannot be bypassed — AFD lock (Priority 1)
if ($accessRestrictions.Success -and $accessRestrictions.Data) {
    $ipSecurityRestrictions = $accessRestrictions.Data.ipSecurityRestrictions
    if ($ipSecurityRestrictions) {
        $afdRule = @($ipSecurityRestrictions | Where-Object {
            $tag = Get-SafePropertyValue -InputObject $_ -Path @('tag')
            $serviceTag = Get-SafePropertyValue -InputObject $_ -Path @('ipAddressOrCidr')
            $action = Get-SafePropertyValue -InputObject $_ -Path @('action')
            ($tag -eq 'ServiceTag' -or $serviceTag -match 'AzureFrontDoor') -and $action -eq 'Allow'
        })
        $denyAll = @($ipSecurityRestrictions | Where-Object {
            $action = Get-SafePropertyValue -InputObject $_ -Path @('action')
            $action -eq 'Deny'
        })
        if ($afdRule.Count -gt 0 -and $denyAll.Count -gt 0) {
            $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Has it been confirmed the WAF cannot be bypassed — is App Service locked to accept traffic from AFD only?' -Priority 1 -Status 'PASS' -Notes ('AFD Allow rule present ({0} rule(s)) with deny rule(s) ({1}). Review raw access restrictions for completeness.' -f $afdRule.Count, $denyAll.Count)))
        } else {
            $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Has it been confirmed the WAF cannot be bypassed — is App Service locked to accept traffic from AFD only?' -Priority 1 -Status 'FAIL' -Notes ('No AzureFrontDoor.Backend service tag Allow rule or explicit Deny-All rule found. AFD-only lock not confirmed. Rule count: {0}' -f @($ipSecurityRestrictions).Count)))
        }
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Has it been confirmed the WAF cannot be bypassed — is App Service locked to accept traffic from AFD only?' -Priority 1 -Status 'FAIL' -Notes 'No IP security restrictions configured on App Service.'))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Has it been confirmed the WAF cannot be bypassed — is App Service locked to accept traffic from AFD only?' -Priority 1 -Status 'UNKNOWN' -Notes 'Could not retrieve access restrictions.'))
}

# FTP/FTPS disabled (Priority 1)
if ($siteConfig.Success -and $siteConfig.Data) {
    $ftpsState = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('ftpsState')
    if ($ftpsState -eq 'Disabled') {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is FTP/FTPS access disabled if not required?' -Priority 1 -Status 'PASS' -Notes ('ftpsState = {0}' -f $ftpsState)))
    } elseif ($ftpsState -eq 'FtpsOnly') {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is FTP/FTPS access disabled if not required?' -Priority 1 -Status 'FAIL' -Notes ('ftpsState = {0} — FTPS is enabled. Disable entirely if FTP is not required.' -f $ftpsState)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is FTP/FTPS access disabled if not required?' -Priority 1 -Status 'FAIL' -Notes ('ftpsState = {0}' -f $ftpsState)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is FTP/FTPS access disabled if not required?' -Priority 1 -Status 'UNKNOWN' -Notes 'Site config not available.'))
}

# Remote debugging disabled (Priority 2)
if ($siteConfig.Success -and $siteConfig.Data) {
    $remoteDebugging = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('remoteDebuggingEnabled')
    if ($remoteDebugging -eq $false) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is remote debugging disabled on App Service?' -Priority 2 -Status 'PASS' -Notes 'remoteDebuggingEnabled = false'))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is remote debugging disabled on App Service?' -Priority 2 -Status 'FAIL' -Notes ('remoteDebuggingEnabled = {0}' -f $remoteDebugging)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is remote debugging disabled on App Service?' -Priority 2 -Status 'UNKNOWN' -Notes 'Site config not available.'))
}

# WAF rules OWASP Top 10 (Priority 3)
try {
if ($afdWafPolicies -and $afdWafPolicies.Success -and $afdWafPolicies.Data) {
    $managedRuleSets = Get-SafePropertyValue -InputObject $afdWafPolicies.Data -Path @('properties', 'managedRules', 'managedRuleSets')
    if (-not $managedRuleSets) {
        $managedRuleSets = Get-SafePropertyValue -InputObject $afdWafPolicies.Data -Path @('managedRules', 'managedRuleSets')
    }
    if ($managedRuleSets) {
        $owaspRuleSet = @($managedRuleSets | Where-Object { (Get-SafePropertyValue -InputObject $_ -Path @('ruleSetType')) -match 'DefaultRuleSet|OWASP' })
        $botRuleSet   = @($managedRuleSets | Where-Object { (Get-SafePropertyValue -InputObject $_ -Path @('ruleSetType')) -match 'BotManager|BotProtection' })
        $policyMode   = Get-SafePropertyValue -InputObject $afdWafPolicies.Data -Path @('properties', 'policySettings', 'mode')
        if (-not $policyMode) { $policyMode = Get-SafePropertyValue -InputObject $afdWafPolicies.Data -Path @('policySettings', 'mode') }

        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Are WAF rules configured for OWASP Top 10 threats?' -Priority 3 -Status $(if ($owaspRuleSet.Count -gt 0) { 'PASS' } else { 'FAIL' }) -Notes ('Managed rule sets found: {0}' -f (($managedRuleSets | ForEach-Object { Get-SafePropertyValue -InputObject $_ -Path @('ruleSetType') }) -join ', '))))
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Are bot protection rules enabled on the WAF?' -Priority 3 -Status $(if ($botRuleSet.Count -gt 0) { 'PASS' } else { 'FAIL' }) -Notes ('Bot rule set count: {0}' -f $botRuleSet.Count)))
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is the WAF in Prevention mode (not Detection only) for production?' -Priority 3 -Status $(if ($policyMode -eq 'Prevention') { 'PASS' } else { 'FAIL' }) -Notes ('WAF policy mode: {0}' -f $policyMode)))
    } else {
        foreach ($q in @('Are WAF rules configured for OWASP Top 10 threats?', 'Are bot protection rules enabled on the WAF?', 'Is the WAF in Prevention mode (not Detection only) for production?')) {
            $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question $q -Priority 3 -Status 'UNKNOWN' -Notes 'WAF policy found but managed rules structure could not be parsed. Review raw AFD WAF Policy section.'))
        }
    }
    # WordPress admin path custom rules
    $customRules = Get-SafePropertyValue -InputObject $afdWafPolicies.Data -Path @('properties', 'customRules', 'rules')
    if (-not $customRules) { $customRules = Get-SafePropertyValue -InputObject $afdWafPolicies.Data -Path @('customRules', 'rules') }
    if ($customRules) {
        $wpAdminRule = @($customRules | Where-Object {
            $conditions = Get-SafePropertyValue -InputObject $_ -Path @('matchConditions')
            if ($conditions) {
                $conditions | Where-Object {
                    $matchValues = Get-SafePropertyValue -InputObject $_ -Path @('matchValues')
                    if ($null -eq $matchValues) { $matchValues = Get-SafePropertyValue -InputObject $_ -Path @('matchValue') }
                    (Get-SafeArrayText -Value $matchValues) -match 'wp-admin|wp-login'
                }
            }
        })
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Are WordPress admin paths (/wp-admin, /wp-login.php) restricted via WAF custom rules?' -Priority 3 -Status $(if ($wpAdminRule.Count -gt 0) { 'PASS' } else { 'FAIL' }) -Notes ('Custom rules targeting wp-admin/wp-login: {0}. Review raw WAF policy for full detail.' -f $wpAdminRule.Count)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Are WordPress admin paths (/wp-admin, /wp-login.php) restricted via WAF custom rules?' -Priority 3 -Status 'MANUAL' -Notes 'No custom rules data retrieved. Review AFD WAF Policy custom rules manually.'))
    }
} else {
    foreach ($q in @('Are WAF rules configured for OWASP Top 10 threats?', 'Are bot protection rules enabled on the WAF?', 'Is the WAF in Prevention mode (not Detection only) for production?', 'Are WordPress admin paths (/wp-admin, /wp-login.php) restricted via WAF custom rules?')) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question $q -Priority 3 -Status 'UNKNOWN' -Notes 'AFD WAF policy not retrieved. Provide -AfdProfileName parameter if the profile exists in a different resource group.'))
    }
}
} catch {
    $wafParseError = $_.Exception.Message
    Write-StatusMessage -Level 'WARN' -Message ("Could not evaluate AFD WAF rule details: {0}. Continuing with remaining Security checks." -f $wafParseError)
    foreach ($q in @('Are WAF rules configured for OWASP Top 10 threats?', 'Are bot protection rules enabled on the WAF?', 'Is the WAF in Prevention mode (not Detection only) for production?', 'Are WordPress admin paths (/wp-admin, /wp-login.php) restricted via WAF custom rules?')) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question $q -Priority 3 -Status 'UNKNOWN' -Notes ("Could not evaluate WAF rule details safely. Error: {0}. Review raw AFD WAF Policy section." -f $wafParseError)))
    }
}

# CORS (Priority 3)
if ($corsSettings.Success -and $corsSettings.Data) {
    $allowedOrigins = Get-SafePropertyValue -InputObject $corsSettings.Data -Path @('allowedOrigins')
    if ($allowedOrigins -and @($allowedOrigins) -contains '*') {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Are CORS policies configured to only accept requests from allowed domains?' -Priority 3 -Status 'FAIL' -Notes 'Wildcard (*) found in allowedOrigins — allows any origin.'))
    } elseif ($allowedOrigins -and @($allowedOrigins).Count -gt 0) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Are CORS policies configured to only accept requests from allowed domains?' -Priority 3 -Status 'PASS' -Notes ('Allowed origins: {0}' -f ($allowedOrigins -join ', '))))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Are CORS policies configured to only accept requests from allowed domains?' -Priority 3 -Status 'PASS' -Notes 'No CORS origins configured (CORS not enabled).'))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Are CORS policies configured to only accept requests from allowed domains?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve CORS settings.'))
}

# MySQL firewall rules (Priority 3)
if ($mysqlFirewallRules.Success -and $mysqlFirewallRules.Data) {
    $broadRules = @($mysqlFirewallRules.Data | Where-Object {
        $startIp = Get-SafePropertyValue -InputObject $_ -Path @('startIpAddress')
        $endIp   = Get-SafePropertyValue -InputObject $_ -Path @('endIpAddress')
        $startIp -eq '0.0.0.0' -or $endIp -eq '255.255.255.255'
    })
    if ($broadRules.Count -eq 0) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Have MySQL firewall rules been verified to not expose 0.0.0.0-255.255.255.255?' -Priority 3 -Status 'PASS' -Notes ('No 0.0.0.0/255.255.255.255 firewall rules found. Total rules: {0}' -f @($mysqlFirewallRules.Data).Count)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Have MySQL firewall rules been verified to not expose 0.0.0.0-255.255.255.255?' -Priority 3 -Status 'FAIL' -Notes ('{0} overly-broad firewall rule(s) found.' -f $broadRules.Count)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Have MySQL firewall rules been verified to not expose 0.0.0.0-255.255.255.255?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve MySQL firewall rules.'))
}

# MySQL port 3306 not public — inferred from publicNetworkAccess
if ($mysqlServer.Success -and $mysqlServer.Data) {
    $mysqlPna = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('network', 'publicNetworkAccess')
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is MySQL port 3306 not exposed on any public interface?' -Priority 3 -Status $(if ($mysqlPna -eq 'Disabled') { 'PASS' } else { 'FAIL' }) -Notes ('Inferred from publicNetworkAccess = {0}' -f $mysqlPna)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:06 Network Security' -Question 'Is MySQL port 3306 not exposed on any public interface?' -Priority 3 -Status 'UNKNOWN' -Notes 'MySQL server data not available.'))
}

# ---- SE:07 Encryption ----

# HTTPS only (Priority 1)
if ($webApp.Success -and $webApp.Data) {
    $httpsOnly = Get-SafePropertyValue -InputObject $webApp.Data -Path @('httpsOnly')
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is HTTPS only enforced on App Service?' -Priority 1 -Status $(if ($httpsOnly -eq $true) { 'PASS' } else { 'FAIL' }) -Notes ('httpsOnly = {0}' -f $httpsOnly)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is HTTPS only enforced on App Service?' -Priority 1 -Status 'UNKNOWN' -Notes 'App Service data not available.'))
}

# require_secure_transport on MySQL (Priority 1)
if ($paramRequireSecureTransport.Success -and $paramRequireSecureTransport.Data) {
    $sslValue = Get-SafePropertyValue -InputObject $paramRequireSecureTransport.Data -Path @('value')
    if ($sslValue -eq 'ON') {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is SSL/TLS enforced on all MySQL connections (require_secure_transport = ON)?' -Priority 1 -Status 'PASS' -Notes ('require_secure_transport = {0}' -f $sslValue)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is SSL/TLS enforced on all MySQL connections (require_secure_transport = ON)?' -Priority 1 -Status 'FAIL' -Notes ('require_secure_transport = {0}' -f $sslValue)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is SSL/TLS enforced on all MySQL connections (require_secure_transport = ON)?' -Priority 1 -Status 'UNKNOWN' -Notes 'Could not retrieve require_secure_transport parameter.'))
}

# Min TLS 1.2 on App Service (Priority 3)
if ($siteConfig.Success -and $siteConfig.Data) {
    $minTls = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('minTlsVersion')
    $tlsOk = $minTls -ge '1.2'
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is the minimum TLS version set to 1.2 on App Service?' -Priority 3 -Status $(if ($tlsOk) { 'PASS' } else { 'FAIL' }) -Notes ('minTlsVersion = {0}' -f $minTls)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is the minimum TLS version set to 1.2 on App Service?' -Priority 3 -Status 'UNKNOWN' -Notes 'Site config not available.'))
}

# Custom domain with TLS (Priority 3)
if ($hostnameBindings.Success -and $hostnameBindings.Data) {
    $defaultSuffix   = '.azurewebsites.net'
    $customHostnames = @($hostnameBindings.Data | Where-Object { -not ($_.name -like "*$defaultSuffix*") })
    if ($customHostnames.Count -gt 0) {
        $names = ($customHostnames | ForEach-Object { $_.name }) -join ', '
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is a custom domain configured with a valid TLS certificate for production?' -Priority 3 -Status 'MANUAL' -Notes ('Custom domain(s) found: {0}. Review SSL certificates section to confirm valid cert is bound.' -f $names)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is a custom domain configured with a valid TLS certificate for production?' -Priority 3 -Status 'FAIL' -Notes 'No custom domains configured — only default azurewebsites.net hostname found.'))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is a custom domain configured with a valid TLS certificate for production?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve hostname bindings.'))
}

# tls_version on MySQL (Priority 3)
if ($paramTlsVersion.Success -and $paramTlsVersion.Data) {
    $tlsVersionValue = Get-SafePropertyValue -InputObject $paramTlsVersion.Data -Path @('value')
    $tlsOk = $tlsVersionValue -match 'TLSv1\.2' -or $tlsVersionValue -match 'TLSv1\.3'
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is tls_version set to TLS 1.2 and 1.3 on MySQL?' -Priority 3 -Status $(if ($tlsOk) { 'PASS' } else { 'FAIL' }) -Notes ('tls_version = {0}' -f $tlsVersionValue)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:07 Encryption' -Question 'Is tls_version set to TLS 1.2 and 1.3 on MySQL?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve tls_version parameter.'))
}

# ---- SE:08 Harden Resources and Reduce Attack Surface ----

# Premium v3 tier (Priority 3)
if ($plan -and $plan.Success -and $plan.Data) {
    $skuTier = Get-SafePropertyValue -InputObject $plan.Data -Path @('sku', 'tier')
    $skuName = Get-SafePropertyValue -InputObject $plan.Data -Path @('sku', 'name')
    if ($skuTier -match 'PremiumV3|Premium V3') {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is the Premium v3 tier used for production WordPress (security context)?' -Priority 3 -Status 'PASS' -Notes ('SKU tier: {0}; name: {1}' -f $skuTier, $skuName)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is the Premium v3 tier used for production WordPress (security context)?' -Priority 3 -Status 'FAIL' -Notes ('SKU tier: {0}; name: {1}. Expected PremiumV3 for network isolation.' -f $skuTier, $skuName)))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is the Premium v3 tier used for production WordPress (security context)?' -Priority 3 -Status 'UNKNOWN' -Notes 'App Service plan data not available.'))
}

# ARR affinity disabled (Priority 3)
if ($webApp.Success -and $webApp.Data) {
    $arrAffinity = Get-SafePropertyValue -InputObject $webApp.Data -Path @('clientAffinityEnabled')
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is ARR affinity (sticky sessions) disabled?' -Priority 3 -Status $(if ($arrAffinity -eq $false) { 'PASS' } else { 'FAIL' }) -Notes ('clientAffinityEnabled = {0}' -f $arrAffinity)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is ARR affinity (sticky sessions) disabled?' -Priority 3 -Status 'UNKNOWN' -Notes 'App Service data not available.'))
}

# Latest PHP runtime (Priority 3)
if ($siteConfig.Success -and $siteConfig.Data) {
    $linuxFx = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('linuxFxVersion')
    $phpVer  = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('phpVersion')
    $runtimeInfo = if ($linuxFx) { $linuxFx } elseif ($phpVer) { $phpVer } else { 'Not detected' }
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is the latest supported PHP runtime used for WordPress?' -Priority 3 -Status 'MANUAL' -Notes ('Runtime: {0}. Verify this is the latest supported PHP version for WordPress at https://learn.microsoft.com/en-us/azure/app-service/overview-patch-os-runtime' -f $runtimeInfo)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is the latest supported PHP runtime used for WordPress?' -Priority 3 -Status 'UNKNOWN' -Notes 'Site config not available.'))
}

# Always On (Priority 3)
if ($siteConfig.Success -and $siteConfig.Data) {
    $alwaysOn = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('alwaysOn')
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is Always On enabled?' -Priority 3 -Status $(if ($alwaysOn -eq $true) { 'PASS' } else { 'FAIL' }) -Notes ('alwaysOn = {0}' -f $alwaysOn)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is Always On enabled?' -Priority 3 -Status 'UNKNOWN' -Notes 'Site config not available.'))
}

# Health Check (Priority 2)
if ($siteConfig.Success -and $siteConfig.Data) {
    $healthCheckPath = Get-SafePropertyValue -InputObject $siteConfig.Data -Path @('healthCheckPath')
    if ($healthCheckPath) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is Health Check enabled?' -Priority 2 -Status 'PASS' -Notes ('healthCheckPath = {0}' -f $healthCheckPath)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is Health Check enabled?' -Priority 2 -Status 'FAIL' -Notes 'healthCheckPath is not configured.'))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is Health Check enabled?' -Priority 2 -Status 'UNKNOWN' -Notes 'Site config not available.'))
}

# WEBSITE_RUN_FROM_PACKAGE (Priority 3)
if ($appSettings.Success -and $appSettings.Data) {
    $runFromPackage = @($appSettings.Data | Where-Object { $_.name -eq 'WEBSITE_RUN_FROM_PACKAGE' })
    if ($runFromPackage.Count -gt 0 -and $runFromPackage[0].value -eq '1') {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is code run from a ZIP package (WEBSITE_RUN_FROM_PACKAGE=1) for a read-only file system?' -Priority 3 -Status 'PASS' -Notes 'WEBSITE_RUN_FROM_PACKAGE = 1'))
    } elseif ($runFromPackage.Count -gt 0) {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is code run from a ZIP package (WEBSITE_RUN_FROM_PACKAGE=1) for a read-only file system?' -Priority 3 -Status 'FAIL' -Notes ('WEBSITE_RUN_FROM_PACKAGE = {0}' -f $runFromPackage[0].value)))
    } else {
        $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is code run from a ZIP package (WEBSITE_RUN_FROM_PACKAGE=1) for a read-only file system?' -Priority 3 -Status 'FAIL' -Notes 'WEBSITE_RUN_FROM_PACKAGE app setting not found.'))
    }
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is code run from a ZIP package (WEBSITE_RUN_FROM_PACKAGE=1) for a read-only file system?' -Priority 3 -Status 'UNKNOWN' -Notes 'App settings not available.'))
}

# Deployment slots (Priority 3)
if ($slots.Success -and $slots.Data) {
    $slotCount = @($slots.Data).Count
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Are deployment slots used?' -Priority 3 -Status $(if ($slotCount -gt 0) { 'PASS' } else { 'FAIL' }) -Notes ('{0} deployment slot(s) configured.' -f $slotCount)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Are deployment slots used?' -Priority 3 -Status 'UNKNOWN' -Notes 'Could not retrieve deployment slots.'))
}

# ---- SE:08 Harden Resources and Reduce Attack Surface — P4 additions ----
if ($appSettings.Success -and $appSettings.Data) {
    $disallowSetting = @($appSettings.Data | Where-Object { $_.name -eq 'DISALLOW_FILE_EDIT' }) | Select-Object -First 1
    $forceSslSetting = @($appSettings.Data | Where-Object { $_.name -eq 'FORCE_SSL_ADMIN' }) | Select-Object -First 1
    $disallowVal = if ($disallowSetting) { $disallowSetting.value } else { $null }
    $forceSslVal = if ($forceSslSetting) { $forceSslSetting.value } else { $null }
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is file editing disabled in WordPress admin (DISALLOW_FILE_EDIT)?' -Priority 4 -Status $(if ($disallowVal -eq 'true') { 'PASS' } else { 'FAIL' }) -Notes ("DISALLOW_FILE_EDIT = {0}. Set to 'true' in App Service App Settings to prevent editing plugins/themes from wp-admin." -f $disallowVal)))
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is WordPress configured to use HTTPS (FORCE_SSL_ADMIN)?' -Priority 4 -Status $(if ($forceSslVal -eq 'true') { 'PASS' } else { 'WARN' }) -Notes ("FORCE_SSL_ADMIN = {0}. Recommended defense-in-depth even when App Service httpsOnly=true." -f $forceSslVal)))
} else {
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is file editing disabled in WordPress admin (DISALLOW_FILE_EDIT)?' -Priority 4 -Status 'UNKNOWN' -Notes 'Could not retrieve app settings.'))
    $findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is WordPress configured to use HTTPS (FORCE_SSL_ADMIN)?' -Priority 4 -Status 'UNKNOWN' -Notes 'Could not retrieve app settings.'))
}
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Has the WordPress database table prefix been changed from default wp_?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Verify in wp-config.php that $table_prefix is not the default "wp_".'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Are WordPress login attempts limited via plugin or WAF rules?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm a login-limiting plugin is active or a WAF custom rule throttles /wp-login.php brute-force attempts.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is XML-RPC disabled if not needed?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Block xmlrpc.php via WAF custom rule or web.config if XML-RPC is not required.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:08 Harden Resources and Reduce Attack Surface' -Question 'Is regular penetration testing conducted?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm annual or risk-driven penetration tests are conducted and findings are tracked to closure.'))

# ---- SE:09 Application Secrets Management — P4 ----
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:09 Application Secrets Management' -Question 'Is Credential Scanner used in build pipelines?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Verify that CredScan or equivalent secret-scanning tooling (e.g. GitHub Advanced Security, Gitleaks) is integrated into CI/CD pipelines.'))

# ---- SE:11 Security Testing — P4 ----
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Is OWASP ZAP or equivalent DAST tool run regularly against the WordPress site?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm scheduled DAST scans run against the staging slot before production deployments.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Are WordPress-specific security scans (WPScan) performed?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. WPScan identifies known-vulnerable plugins, themes, and WordPress core versions.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Are security test cases in CI/CD pipelines (SAST, dependency scanning)?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm SAST and dependency vulnerability scanning are pipeline gates before slot swap.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Has WAF rule effectiveness been tested against known attack payloads?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Test WAF rules using OWASP test vectors to confirm detection and blocking in Prevention mode.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Have authentication and authorisation controls been validated?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Validate Entra ID role boundaries and WordPress capability assignments under test conditions.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Have backup and restore procedures been tested?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm MySQL PITR and App Service backup restore have been rehearsed end-to-end with RTO documented.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Has SSL/TLS enforcement been verified — has a connection with ssl-mode=DISABLED been confirmed rejected?' -Priority 4 -Status 'MANUAL' -Notes 'Test via: mysql -h {server}.mysql.database.azure.com -u {user} -p --ssl-mode=DISABLED — connection should be refused when require_secure_transport=ON.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Have MySQL least privilege boundaries been tested?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm the WordPress DB user cannot access tables outside the WordPress database.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Has MySQL admin account isolation been tested?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm the server admin credentials are not used by the application and are break-glass only.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Has MySQL audit log completeness been validated?' -Priority 4 -Status 'MANUAL' -Notes 'Verify audit_log_enabled = ON and review MySqlAuditLogs in Log Analytics to confirm login and query events are captured as expected.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:11 Security Testing' -Question 'Has MySQL point-in-time restore been tested?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm PITR has been tested to a non-production environment with RTO measured and results documented.'))

# ---- SE:12 Incident Response — P4 ----
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:12 Incident Response' -Question 'Is the procedure for rotating all secrets in an emergency documented?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Verify a secret rotation runbook covers: Key Vault secrets, WordPress auth keys and salts, MySQL admin password, and App Service publish profiles.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:12 Incident Response' -Question 'Is the procedure to disable compromised accounts or block IPs via WAF documented?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm the WAF custom rule creation/update procedure is documented for emergency IP blocking and account disablement.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:12 Incident Response' -Question 'Is the deleted MySQL server recovery window (5 days) documented?' -Priority 4 -Status 'MANUAL' -Notes 'MySQL Flexible Servers have a 5-day recovery window after accidental deletion (subject to the CanNotDelete lock check in SE Backup). Confirm this recovery procedure is in the DR runbook.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:12 Incident Response' -Question 'Is PITR of MySQL tested regularly?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot determine via az CLI. Confirm MySQL PITR is tested at least annually, with RTO measured and documented.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:12 Incident Response' -Question 'Are post-restore tasks documented (HA reactivation, firewall rules, parameter resets)?' -Priority 4 -Status 'MANUAL' -Notes 'After PITR or geo-restore: HA mode must be re-enabled on a new server (cannot be enabled on existing), firewall rules revalidated, and server parameters re-applied. Confirm these tasks are in the DR runbook.'))
$findings.Add((New-SecurityFinding -WafArea 'Security' -SubArea 'SE:12 Incident Response' -Question 'Are alerts integrated into SecOps/SIEM processes?' -Priority 4 -Status 'MANUAL' -Notes 'Cannot fully determine via az CLI. Verify Azure Monitor action groups on alert rules are configured to route to a SIEM, security operations team, or on-call tool (PagerDuty/Opsgenie).'))

# ---------------------------------------------------------------------------
# SECTION 8 — Build the markdown report
# ---------------------------------------------------------------------------
$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeAppName = ($AppServiceName -replace '[^A-Za-z0-9._-]', '-')
$reportPath  = Join-Path -Path $OutputDirectory -ChildPath ("SecurityReviewReport-{0}-{1}.md" -f $safeAppName, $timestamp)

$builder = [System.Text.StringBuilder]::new()

Add-MarkdownLine -Builder $builder -Text ('# WAF Security Review Report: {0}' -f $AppServiceName)
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text ('Generated: {0}' -f (Get-Date).ToString('u'))
Add-MarkdownLine -Builder $builder -Text ('Resource Group: `{0}`' -f $ResourceGroup)
Add-MarkdownLine -Builder $builder -Text ('App Service: `{0}`' -f $AppServiceName)
Add-MarkdownLine -Builder $builder -Text ('MySQL Flexible Server: `{0}`' -f $MySqlServerName)
if ($Subscription) {
    Add-MarkdownLine -Builder $builder -Text ('Requested Subscription: `{0}`' -f $Subscription)
}
Add-MarkdownLine -Builder $builder -Text 'Sensitive values in settings, connection strings, and similar fields are redacted.'
Add-MarkdownLine -Builder $builder -Text '> This report covers WAF Security questions at Priority 1 through 5.'
Add-MarkdownLine -Builder $builder

# Summary table
$summary = [ordered]@{
    'Subscription Name'      = Get-SafePropertyValue -InputObject $account.Data -Path @('name')
    'Subscription Id'        = Get-SafePropertyValue -InputObject $account.Data -Path @('id')
    'Tenant Id'              = Get-SafePropertyValue -InputObject $account.Data -Path @('tenantId')
    'Resource Group'         = $ResourceGroup
    'Resource Group Location'= Get-SafePropertyValue -InputObject $resourceGroupResult.Data -Path @('location')
    'App Service Name'       = Get-SafePropertyValue -InputObject $webApp.Data -Path @('name')
    'App Service State'      = Get-SafePropertyValue -InputObject $webApp.Data -Path @('state')
    'HTTPS Only'             = Get-SafePropertyValue -InputObject $webApp.Data -Path @('httpsOnly')
    'Public Network Access'  = Get-SafePropertyValue -InputObject $webApp.Data -Path @('publicNetworkAccess')
    'MySQL Server Name'      = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('name')
    'MySQL State'            = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('state')
    'MySQL Public Network Access' = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('network', 'publicNetworkAccess')
    'MySQL Auth: AAD Enabled'= Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('authConfig', 'activeDirectoryAuthEnabled')
    'MySQL Auth: Password Enabled' = Get-SafePropertyValue -InputObject $mysqlServer.Data -Path @('authConfig', 'passwordAuthEnabled')
}

Add-MarkdownLine -Builder $builder -Text '## Summary'
Add-KeyValueTable -Builder $builder -Values $summary

# Security assessment
Add-SecurityAssessmentSection -Builder $builder -Findings $findings

# Raw data sections
Add-MarkdownLine -Builder $builder -Text '## Raw Data'
Add-MarkdownLine -Builder $builder
Add-JsonSection -Builder $builder -Title 'Azure Account Context'                           -Result $account
Add-JsonSection -Builder $builder -Title 'Resource Group Overview'                         -Result $resourceGroupResult
Add-JsonSection -Builder $builder -Title 'App Service Overview'                            -Result $webApp
Add-JsonSection -Builder $builder -Title 'App Service Site Config'                         -Result $siteConfig
Add-JsonSection -Builder $builder -Title 'App Service App Settings'                        -Result $appSettings
Add-JsonSection -Builder $builder -Title 'App Service Access Restrictions'                 -Result $accessRestrictions
Add-JsonSection -Builder $builder -Title 'App Service Auth Settings'                       -Result $authSettings
Add-JsonSection -Builder $builder -Title 'App Service Managed Identity'                    -Result $identity
Add-JsonSection -Builder $builder -Title 'App Service VNet Integration'                    -Result $vnetIntegration
Add-JsonSection -Builder $builder -Title 'App Service Deployment Slots'                    -Result $slots
Add-JsonSection -Builder $builder -Title 'App Service Hostname Bindings'                   -Result $hostnameBindings
Add-JsonSection -Builder $builder -Title 'App Service SSL Certificates'                    -Result $sslCertificates
Add-JsonSection -Builder $builder -Title 'App Service CORS Settings'                       -Result $corsSettings
Add-JsonSection -Builder $builder -Title 'App Service SCM Basic Auth Policy'               -Result $scmBasicAuthPolicy
Add-JsonSection -Builder $builder -Title 'App Service FTP Basic Auth Policy'               -Result $ftpBasicAuthPolicy

if ($plan) {
    Add-JsonSection -Builder $builder -Title 'App Service Plan Overview'                   -Result $plan
}
if ($autoscaleSettings) {
    Add-JsonSection -Builder $builder -Title 'App Service Plan Autoscale Settings'         -Result $autoscaleSettings
}

Add-JsonSection -Builder $builder -Title 'Resource Group Private Endpoints'                -Result $privateEndpoints
Add-JsonSection -Builder $builder -Title 'Resource Group NSGs'                             -Result $nsgList
Add-JsonSection -Builder $builder -Title 'Resource Group VNets'                            -Result $vnetList
Add-JsonSection -Builder $builder -Title 'Azure Front Door Profiles'                       -Result $afdProfiles

if ($afdSecurityPolicies) {
    Add-JsonSection -Builder $builder -Title 'AFD Security Policies'                       -Result $afdSecurityPolicies
}
if ($afdWafPolicies) {
    Add-JsonSection -Builder $builder -Title 'AFD WAF Policy'                              -Result $afdWafPolicies
}

Add-JsonSection -Builder $builder -Title 'Application Gateways'                            -Result $appGateways
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Overview'                  -Result $mysqlServer
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Parameters'                -Result $mysqlParameters
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Firewall Rules'            -Result $mysqlFirewallRules
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Entra Admins'             -Result $mysqlEntraAdmins
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Threat Protection'         -Result $mysqlThreatProtect
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: require_secure_transport'       -Result $paramRequireSecureTransport
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: tls_version'                    -Result $paramTlsVersion
Add-JsonSection -Builder $builder -Title 'MySQL Parameter: slow_query_log'                 -Result $paramSlowQueryLog
Add-JsonSection -Builder $builder -Title 'Microsoft Defender for App Service'              -Result $defenderAppService
Add-JsonSection -Builder $builder -Title 'Azure Advisor Security Recommendations'          -Result $advisorSecurity
Add-JsonSection -Builder $builder -Title 'Resource Group RBAC Role Assignments'            -Result $roleAssignments
Add-JsonSection -Builder $builder -Title 'Resource Group Policy Assignments'               -Result $policyAssignments
Add-JsonSection -Builder $builder -Title 'Resource Group Tags'                             -Result $resourceGroupTags

Add-CollectionStatusSection -Builder $builder -Results $results

[System.IO.File]::WriteAllText($reportPath, $builder.ToString(), [System.Text.Encoding]::UTF8)
Write-StatusMessage -Level 'OK' -Message ("Security review report written to {0}" -f $reportPath)
