[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Get-Location).Path,

    [string]$Subscription
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

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

    return $Name -match '(?i)(password|passwd|pwd|secret|token|connectionstring|accountkey|sharedaccesskey|sharedkey|clientsecret|sas|accesskey)'
}

function Test-SensitiveValue {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value -match '(?i)(password\s*=|pwd\s*=|accountkey\s*=|sharedaccesssignature=|sig=|clientsecret\s*=|sslmode=require|://.+:.+@)'
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

function Get-AssociatedPrivateEndpoints {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerResourceId,

        [Parameter(Mandatory = $true)]
        [string]$CurrentResourceGroup
    )

    $privateEndpoints = Add-QueryResult -Label 'Resource Group Private Endpoints' -Arguments @('network', 'private-endpoint', 'list', '--resource-group', $CurrentResourceGroup)
    if (-not $privateEndpoints.Success -or -not $privateEndpoints.Data) {
        return $privateEndpoints
    }

    $matches = @(
        $privateEndpoints.Data | Where-Object {
            $serviceIds = @($_.privateLinkServiceConnections.privateLinkServiceId)
            $serviceIds -contains $ServerResourceId
        }
    )

    $privateEndpoints.Data = $matches
    return $privateEndpoints
}

Test-AzureCliPrerequisites
Write-StatusMessage -Level 'INFO' -Message ("Starting MySQL Flexible Server report for {0} in resource group {1}" -f $ServerName, $ResourceGroup)

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
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

$account = Add-QueryResult -Label 'Azure Account' -Arguments @('account', 'show') -Required
$resourceGroupResult = Assert-ResourceGroupAvailable -AccountResult $account -ResourceGroupName $ResourceGroup
$results.Add($resourceGroupResult)
$server = Add-QueryResult -Label 'MySQL Flexible Server Overview' -Arguments @('mysql', 'flexible-server', 'show', '--name', $ServerName, '--resource-group', $ResourceGroup) -Required

$serverId = $server.Data.id
$resourceView = Add-QueryResult -Label 'MySQL Flexible Server ARM Resource' -Arguments @('resource', 'show', '--ids', $serverId)
$databases = Add-QueryResult -Label 'MySQL Flexible Server Databases' -Arguments @('mysql', 'flexible-server', 'db', 'list', '--server-name', $ServerName, '--resource-group', $ResourceGroup)
$parameters = Add-QueryResult -Label 'MySQL Flexible Server Parameters' -Arguments @('mysql', 'flexible-server', 'parameter', 'list', '--server-name', $ServerName, '--resource-group', $ResourceGroup)
$firewallRules = Add-QueryResult -Label 'MySQL Flexible Server Firewall Rules' -Arguments @('mysql', 'flexible-server', 'firewall-rule', 'list', '--name', $ServerName, '--resource-group', $ResourceGroup)
$entraAdmins = Add-QueryResult -Label 'MySQL Flexible Server Entra Admins' -Arguments @('mysql', 'flexible-server', 'ad-admin', 'list', '--server-name', $ServerName, '--resource-group', $ResourceGroup)
$replicas = Add-QueryResult -Label 'MySQL Flexible Server Replicas' -Arguments @('mysql', 'flexible-server', 'replica', 'list', '--name', $ServerName, '--resource-group', $ResourceGroup)
$serverLogs = Add-QueryResult -Label 'MySQL Flexible Server Logs' -Arguments @('mysql', 'flexible-server', 'server-logs', 'list', '--server-name', $ServerName, '--resource-group', $ResourceGroup)
$backups = Add-QueryResult -Label 'MySQL Flexible Server Backups' -Arguments @('mysql', 'flexible-server', 'backup', 'list', '--name', $ServerName, '--resource-group', $ResourceGroup)
$maintenanceHistory = Add-QueryResult -Label 'MySQL Flexible Server Maintenance History' -Arguments @('mysql', 'flexible-server', 'maintenance', 'list', '--server-name', $ServerName, '--resource-group', $ResourceGroup)
$identityList = Add-QueryResult -Label 'MySQL Flexible Server Identity List' -Arguments @('mysql', 'flexible-server', 'identity', 'list', '--server-name', $ServerName, '--resource-group', $ResourceGroup)
$threatProtection = Add-QueryResult -Label 'MySQL Flexible Server Threat Protection' -Arguments @('mysql', 'flexible-server', 'advanced-threat-protection-setting', 'show', '--name', $ServerName, '--resource-group', $ResourceGroup)
$connectionString = Add-QueryResult -Label 'MySQL Flexible Server Connection String' -Arguments @('mysql', 'flexible-server', 'show-connection-string', '--server-name', $ServerName, '--admin-user', (Get-SafePropertyValue -InputObject $server.Data -Path @('administratorLogin')), '--database-name', 'mysql')
$privateEndpoints = Get-AssociatedPrivateEndpoints -ServerResourceId $serverId -CurrentResourceGroup $ResourceGroup
$diagnosticSettings = Add-QueryResult -Label 'MySQL Flexible Server Diagnostic Settings' -Arguments @('monitor', 'diagnostic-settings', 'list', '--resource', $serverId)
$diagnosticCategories = Add-QueryResult -Label 'MySQL Flexible Server Diagnostic Categories' -Arguments @('monitor', 'diagnostic-settings', 'categories', 'list', '--resource', $serverId)

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeServerName = ($ServerName -replace '[^A-Za-z0-9._-]', '-')
$reportPath = Join-Path -Path $OutputDirectory -ChildPath ("MySqlFlexibleServerReport-{0}-{1}.md" -f $safeServerName, $timestamp)

$summary = [ordered]@{
    'Subscription Name' = $account.Data.name
    'Subscription Id' = $account.Data.id
    'Tenant Id' = $account.Data.tenantId
    'Resource Group Location' = $resourceGroupResult.Data.location
    'Server Name' = $server.Data.name
    'Location' = $server.Data.location
    'State' = $server.Data.state
    'Administrator Login' = Get-SafePropertyValue -InputObject $server.Data -Path @('administratorLogin')
    'Version' = Get-SafePropertyValue -InputObject $server.Data -Path @('version')
    'Fully Qualified Domain Name' = Get-SafePropertyValue -InputObject $server.Data -Path @('fullyQualifiedDomainName')
    'Public Network Access' = Get-SafePropertyValue -InputObject $server.Data -Path @('publicNetworkAccess')
    'SKU Name' = Get-SafePropertyValue -InputObject $server.Data -Path @('sku', 'name')
    'SKU Tier' = Get-SafePropertyValue -InputObject $server.Data -Path @('sku', 'tier')
    'Storage Size GB' = Get-SafePropertyValue -InputObject $server.Data -Path @('storage', 'storageSizeGb')
    'Backup Retention Days' = Get-SafePropertyValue -InputObject $server.Data -Path @('backup', 'backupRetentionDays')
    'Geo Redundant Backup' = Get-SafePropertyValue -InputObject $server.Data -Path @('backup', 'geoRedundantBackup')
    'High Availability Mode' = Get-SafePropertyValue -InputObject $server.Data -Path @('highAvailability', 'mode')
    'Availability Zone' = Get-SafePropertyValue -InputObject $server.Data -Path @('availabilityZone')
}

$builder = [System.Text.StringBuilder]::new()
Add-MarkdownLine -Builder $builder -Text ('# MySQL Flexible Server Report: {0}' -f $ServerName)
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text ('Generated: {0}' -f (Get-Date).ToString('u'))
Add-MarkdownLine -Builder $builder -Text ('Resource Group: `{0}`' -f $ResourceGroup)
if ($Subscription) {
    Add-MarkdownLine -Builder $builder -Text ('Requested Subscription: `{0}`' -f $Subscription)
}
Add-MarkdownLine -Builder $builder -Text 'Sensitive values in connection strings, identity data, logs, and other secret-bearing fields are redacted.'
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text '## Summary'
Add-KeyValueTable -Builder $builder -Values $summary

Add-JsonSection -Builder $builder -Title 'Azure Account Context' -Result $account
Add-JsonSection -Builder $builder -Title 'Resource Group Overview' -Result $resourceGroupResult
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Overview' -Result $server
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server ARM Resource' -Result $resourceView
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Databases' -Result $databases
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Parameters' -Result $parameters
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Firewall Rules' -Result $firewallRules
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Entra Admins' -Result $entraAdmins
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Replicas' -Result $replicas
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Logs' -Result $serverLogs
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Backups' -Result $backups
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Maintenance History' -Result $maintenanceHistory
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Identity List' -Result $identityList
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Threat Protection' -Result $threatProtection
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Connection String' -Result $connectionString
Add-JsonSection -Builder $builder -Title 'Associated Private Endpoints' -Result $privateEndpoints
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Diagnostic Settings' -Result $diagnosticSettings
Add-JsonSection -Builder $builder -Title 'MySQL Flexible Server Diagnostic Categories' -Result $diagnosticCategories
Add-CollectionStatusSection -Builder $builder -Results $results

[System.IO.File]::WriteAllText($reportPath, $builder.ToString(), [System.Text.Encoding]::UTF8)
Write-StatusMessage -Level 'OK' -Message ("Report written to {0}" -f $reportPath)
Write-Host ("Report written to {0}" -f $reportPath)