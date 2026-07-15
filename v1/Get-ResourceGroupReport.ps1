[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Get-Location).Path,

    [string]$Subscription,

    [ValidateRange(1, 365)]
    [int]$ActivityLogDays = 30,

    [ValidateRange(1, 1000)]
    [int]$ActivityLogMaxEvents = 100,

    [ValidateRange(1, 500)]
    [int]$MaxDetailedResources = 50,

    [ValidateRange(1, 100)]
    [int]$MaxDeploymentOperationGroups = 10
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
    $color = switch ($Level) {
        'INFO'  { 'Cyan' }
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'White' }
    }
    $paddedLevel = switch ($Level) {
        'INFO'  { '[INFO ]' }
        'OK'    { '[OK   ]' }
        'WARN'  { '[WARN ]' }
        'ERROR' { '[ERROR]' }
        default { "[$Level]" }
    }
    Write-Host ('{0} {1} {2}' -f $timestamp, $paddedLevel, $Message) -ForegroundColor $color
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
        $azCmd = Get-Command -Name az
        if (-not $azCmd) {
            throw 'Azure CLI was not found in PATH. Install Azure CLI before running this script.'
        }
    } catch {
        Write-Warning "[ERROR] Azure CLI prerequisite check failed: $_"
        Write-Verbose $_.ScriptStackTrace
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
    Write-StatusMessage -Level 'INFO' -Message ('Collecting {0}' -f $Label)
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
        Write-StatusMessage -Level 'ERROR' -Message ('Failed {0} after {1:N1}s' -f $Label, ((Get-Date) - $started).TotalSeconds)
        throw "Required Azure CLI command failed for '$Label': $rawOutput"
    }

    if ($success) {
        Write-StatusMessage -Level 'OK' -Message ('Collected {0} in {1:N1}s' -f $Label, ((Get-Date) - $started).TotalSeconds)
    }
    else {
        Write-StatusMessage -Level 'WARN' -Message ('Could not collect {0} in {1:N1}s' -f $Label, ((Get-Date) - $started).TotalSeconds)
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

    return $Value -match '(?i)(password\s*=|pwd\s*=|accountkey\s*=|sharedaccesssignature=|sig=|clientsecret\s*=|://.+:.+@)'
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
        if ((Test-SensitiveName -Name $PropertyName) -or (Test-SensitiveValue -Value $InputObject)) {
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

    return [pscustomobject]$copy
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

function ConvertTo-Array {
    param(
        [AllowNull()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return @()
    }

    if ($InputObject -is [string]) {
        return @($InputObject)
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return @($InputObject)
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        return @($InputObject)
    }

    return @($InputObject)
}

function Get-ItemCount {
    param(
        [AllowNull()]
        $InputObject
    )

    return (ConvertTo-Array -InputObject $InputObject).Count
}

function Get-TagCount {
    param(
        [AllowNull()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return 0
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Keys.Count
    }

    return @($InputObject.PSObject.Properties).Count
}

function Get-TagSummary {
    param(
        [AllowNull()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return ''
    }

    $names = [string[]]$(if ($InputObject -is [System.Collections.IDictionary]) {
        @($InputObject.Keys)
    }
    else {
        @($InputObject.PSObject.Properties.Name)
    })

    if ($names.Count -eq 0) {
        return ''
    }

    return ($names | Sort-Object) -join ', '
}

function Get-GroupedCountMap {
    param(
        [AllowNull()]
        $Items,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Selector,

        [int]$Top = 20
    )

    $array = ConvertTo-Array -InputObject $Items
    if ($array.Count -eq 0) {
        return [ordered]@{ '(none)' = 0 }
    }

    $groups = @(
        $array | Group-Object -Property {
            $value = & $Selector $_
            $text = if ($null -eq $value) { '' } else { [string]$value }
            if ([string]::IsNullOrWhiteSpace($text)) {
                '(empty)'
            }
            else {
                $text
            }
        } | Sort-Object -Property Count -Descending
    )

    $result = [ordered]@{}
    $index = 0
    foreach ($group in $groups) {
        if ($index -ge $Top) {
            break
        }

        $result[$group.Name] = $group.Count
        $index++
    }

    if ($groups.Count -gt $Top) {
        $remainingCount = (($groups | Select-Object -Skip $Top | Measure-Object -Property Count -Sum).Sum)
        $result['(remaining)'] = $remainingCount
    }

    return $result
}

function Add-CountSection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$Builder,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Counts,

        [int]$HeadingLevel = 2
    )

    $headingPrefix = '#' * $HeadingLevel
    Add-MarkdownLine -Builder $Builder -Text ('{0} {1}' -f $headingPrefix, $Title)
    Add-KeyValueTable -Builder $Builder -Values $Counts
}

function Add-ResourceInventorySection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$Builder,

        [AllowNull()]
        $Resources
    )

    $resourceItems = @(ConvertTo-Array -InputObject $Resources | Sort-Object -Property type, name)
    Add-MarkdownLine -Builder $Builder -Text '## Resource Inventory Summary'

    if ($resourceItems.Count -eq 0) {
        Add-MarkdownLine -Builder $Builder -Text 'No resources were returned for this resource group.'
        Add-MarkdownLine -Builder $Builder
        return
    }

    Add-CountSection -Builder $Builder -Title 'Resource Types' -Counts (Get-GroupedCountMap -Items $resourceItems -Selector { $_.type } -Top 25) -HeadingLevel 3
    Add-CountSection -Builder $Builder -Title 'Resource Locations' -Counts (Get-GroupedCountMap -Items $resourceItems -Selector { $_.location } -Top 15) -HeadingLevel 3
    Add-CountSection -Builder $Builder -Title 'Resource Kinds' -Counts (Get-GroupedCountMap -Items $resourceItems -Selector { $_.kind } -Top 15) -HeadingLevel 3

    Add-MarkdownLine -Builder $Builder -Text '### Resource Table'
    Add-MarkdownLine -Builder $Builder -Text '| Name | Type | Location | Kind | Managed By | Tags | |'
    Add-MarkdownLine -Builder $Builder -Text '| --- | --- | --- | --- | --- | --- | --- |'

    foreach ($resource in $resourceItems) {
        $tagCount = Get-TagCount -InputObject $resource.tags
        $provisioningState = Get-SafePropertyValue -InputObject $resource -Path @('properties', 'provisioningState')
        Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f
            (ConvertTo-MarkdownText -Value $resource.name),
            (ConvertTo-MarkdownText -Value $resource.type),
            (ConvertTo-MarkdownText -Value $resource.location),
            (ConvertTo-MarkdownText -Value $resource.kind),
            (ConvertTo-MarkdownText -Value $resource.managedBy),
            (ConvertTo-MarkdownText -Value $tagCount),
            (ConvertTo-MarkdownText -Value $provisioningState))
    }

    Add-MarkdownLine -Builder $Builder
}

function Add-DeploymentSummarySection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$Builder,

        [AllowNull()]
        $Deployments
    )

    $deploymentItems = @(ConvertTo-Array -InputObject $Deployments | Sort-Object -Property {
            $timestamp = Get-SafePropertyValue -InputObject $_ -Path @('properties', 'timestamp')
            if ($timestamp) {
                [DateTime]$timestamp
            }
            else {
                [DateTime]::MinValue
            }
        } -Descending)

    Add-MarkdownLine -Builder $Builder -Text '## Deployment Summary'

    if ($deploymentItems.Count -eq 0) {
        Add-MarkdownLine -Builder $Builder -Text 'No deployments were returned for this resource group.'
        Add-MarkdownLine -Builder $Builder
        return
    }

    Add-MarkdownLine -Builder $Builder -Text '| Deployment | Timestamp | State | Mode | Correlation Id |'
    Add-MarkdownLine -Builder $Builder -Text '| --- | --- | --- | --- | --- |'

    foreach ($deployment in ($deploymentItems | Select-Object -First 25)) {
        Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} | {2} | {3} | {4} |' -f
            (ConvertTo-MarkdownText -Value $deployment.name),
            (ConvertTo-MarkdownText -Value (Get-SafePropertyValue -InputObject $deployment -Path @('properties', 'timestamp'))),
            (ConvertTo-MarkdownText -Value (Get-SafePropertyValue -InputObject $deployment -Path @('properties', 'provisioningState'))),
            (ConvertTo-MarkdownText -Value (Get-SafePropertyValue -InputObject $deployment -Path @('properties', 'mode'))),
            (ConvertTo-MarkdownText -Value (Get-SafePropertyValue -InputObject $deployment -Path @('properties', 'correlationId'))))
    }

    Add-MarkdownLine -Builder $Builder
}

function Add-ActivityLogSummarySection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]$Builder,

        [AllowNull()]
        $Events
    )

    $eventItems = @(ConvertTo-Array -InputObject $Events | Sort-Object -Property eventTimestamp -Descending)

    Add-MarkdownLine -Builder $Builder -Text '## Activity Log Summary'

    if ($eventItems.Count -eq 0) {
        Add-MarkdownLine -Builder $Builder -Text 'No activity log events were returned for the selected period.'
        Add-MarkdownLine -Builder $Builder
        return
    }

    Add-MarkdownLine -Builder $Builder -Text '| Timestamp | Level | Operation | Status | Caller | Resource |'
    Add-MarkdownLine -Builder $Builder -Text '| --- | --- | --- | --- | --- | --- |'

    foreach ($eventItem in ($eventItems | Select-Object -First 25)) {
        $resourceText = '{0} ({1})' -f $eventItem.resourceId, $eventItem.resourceGroupName
        Add-MarkdownLine -Builder $Builder -Text ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f
            (ConvertTo-MarkdownText -Value $eventItem.eventTimestamp),
            (ConvertTo-MarkdownText -Value $eventItem.level),
            (ConvertTo-MarkdownText -Value (Get-SafePropertyValue -InputObject $eventItem -Path @('operationName', 'localizedValue'))),
            (ConvertTo-MarkdownText -Value (Get-SafePropertyValue -InputObject $eventItem -Path @('status', 'localizedValue'))),
            (ConvertTo-MarkdownText -Value $eventItem.caller),
            (ConvertTo-MarkdownText -Value $resourceText))
    }

    Add-MarkdownLine -Builder $Builder
}

function Get-RecentDeploymentOperationResult {
    param(
        [AllowNull()]
        $Deployments,

        [Parameter(Mandatory = $true)]
        [string]$CurrentResourceGroup,

        [int]$MaxDeployments = 10
    )

    $deploymentItems = @(ConvertTo-Array -InputObject $Deployments | Sort-Object -Property {
            $timestamp = Get-SafePropertyValue -InputObject $_ -Path @('properties', 'timestamp')
            if ($timestamp) {
                [DateTime]$timestamp
            }
            else {
                [DateTime]::MinValue
            }
        } -Descending)

    $selectedDeployments = @($deploymentItems | Select-Object -First $MaxDeployments)
    $operationItems = [System.Collections.Generic.List[object]]::new()
    $allSucceeded = $true

    foreach ($deployment in $selectedDeployments) {
        if ([string]::IsNullOrWhiteSpace($deployment.name)) {
            continue
        }

        $result = Invoke-AzCliCommand -Label ('Deployment Operations: {0}' -f $deployment.name) -Arguments @('deployment', 'group', 'operation', 'list', '--resource-group', $CurrentResourceGroup, '--name', $deployment.name)
        # Azure prunes operation history for older/completed deployments — treat as empty, not a failure
        if (-not $result.Success -and $result.ErrorMessage -notmatch 'DeploymentOperationNotFound|Operation history is not available') {
            $allSucceeded = $false
        }

        $operationItems.Add([pscustomobject]@{
                DeploymentName = $deployment.name
                Timestamp = Get-SafePropertyValue -InputObject $deployment -Path @('properties', 'timestamp')
                Success = $result.Success
                ExitCode = $result.ExitCode
                ErrorMessage = $result.ErrorMessage
                Command = $result.Command
                Data = $result.Data
            })
    }

    return [pscustomobject]@{
        Label = 'Recent Deployment Operations'
        Command = 'multiple az deployment group operation list --resource-group <rg> --name <deployment>'
        Success = $allSucceeded
        ExitCode = if ($allSucceeded) { 0 } else { 1 }
        ErrorMessage = if ($allSucceeded) { $null } else { 'One or more deployment operation queries failed.' }
        Data = [pscustomobject]@{
            TotalDeployments = $deploymentItems.Count
            IncludedDeployments = $selectedDeployments.Count
            Truncated = $deploymentItems.Count -gt $selectedDeployments.Count
            Items = @($operationItems)
        }
    }
}

function Get-DetailedResourceSnapshotResult {
    param(
        [AllowNull()]
        $Resources,

        [int]$MaxResources = 50
    )

    $resourceItems = @(ConvertTo-Array -InputObject $Resources | Sort-Object -Property type, name)
    $selectedResources = @($resourceItems | Select-Object -First $MaxResources)
    $detailItems = [System.Collections.Generic.List[object]]::new()
    $allSucceeded = $true

    foreach ($resource in $selectedResources) {
        if ([string]::IsNullOrWhiteSpace($resource.id)) {
            continue
        }

        $result = Invoke-AzCliCommand -Label ('Resource ARM Detail: {0}' -f $resource.id) -Arguments @('resource', 'show', '--ids', $resource.id)
        if (-not $result.Success) {
            $allSucceeded = $false
        }

        $detailItems.Add([pscustomobject]@{
                Name = $resource.name
                Type = $resource.type
                Id = $resource.id
                Success = $result.Success
                ExitCode = $result.ExitCode
                ErrorMessage = $result.ErrorMessage
                Command = $result.Command
                Data = $result.Data
            })
    }

    return [pscustomobject]@{
        Label = 'Detailed Resource ARM Snapshots'
        Command = 'multiple az resource show --ids <resourceId>'
        Success = $allSucceeded
        ExitCode = if ($allSucceeded) { 0 } else { 1 }
        ErrorMessage = if ($allSucceeded) { $null } else { 'One or more resource detail queries failed.' }
        Data = [pscustomobject]@{
            TotalResources = $resourceItems.Count
            IncludedResources = $selectedResources.Count
            Truncated = $resourceItems.Count -gt $selectedResources.Count
            Items = @($detailItems)
        }
    }
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
Write-StatusMessage -Level 'INFO' -Message ('Starting resource group report for {0}' -f $ResourceGroup)

if (-not (Test-Path -Path $OutputDirectory)) {
    Write-Host "[INFO ] Creating output directory '$OutputDirectory'..." -ForegroundColor Cyan
    try {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        Write-Host "[OK   ] Output directory created." -ForegroundColor Green
    } catch {
        Write-Warning "[ERROR] Failed to create output directory '$OutputDirectory': $_"
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

$account = Add-QueryResult -Label 'Azure Account' -Arguments @('account', 'show') -Required
$resourceGroupResult = Assert-ResourceGroupAvailable -AccountResult $account -ResourceGroupName $ResourceGroup
$results.Add($resourceGroupResult)
$resourceGroupId = $resourceGroupResult.Data.id
$resources = Add-QueryResult -Label 'Resource Group Resources' -Arguments @('resource', 'list', '--resource-group', $ResourceGroup) -Required
$locks = Add-QueryResult -Label 'Resource Group Locks' -Arguments @('lock', 'list', '--resource-group', $ResourceGroup)
$deployments = Add-QueryResult -Label 'Resource Group Deployments' -Arguments @('deployment', 'group', 'list', '--resource-group', $ResourceGroup)
$policyAssignments = Add-QueryResult -Label 'Policy Assignments At Scope' -Arguments @('policy', 'assignment', 'list', '--scope', $resourceGroupId)
$policyExemptions = Add-QueryResult -Label 'Policy Exemptions At Scope' -Arguments @('policy', 'exemption', 'list', '--scope', $resourceGroupId)
$policySummary = Add-QueryResult -Label 'Policy Compliance Summary' -Arguments @('policy', 'state', 'summarize', '--resource-group', $ResourceGroup)
$roleAssignments = Add-QueryResult -Label 'Role Assignments At Scope' -Arguments @('role', 'assignment', 'list', '--scope', $resourceGroupId, '--include-inherited')
# Note: Resource groups do not support diagnostic settings (ResourceTypeNotSupported) — activity log covers this instead
$activityLog = Add-QueryResult -Label 'Resource Group Activity Log' -Arguments @('monitor', 'activity-log', 'list', '--resource-group', $ResourceGroup, '--offset', ('{0}d' -f $ActivityLogDays), '--max-events', $ActivityLogMaxEvents)
$advisorRecommendations = Add-QueryResult -Label 'Advisor Recommendations For Resource Group' -Arguments @('advisor', 'recommendation', 'list', '--resource-group', $ResourceGroup)
$armExport = Add-QueryResult -Label 'Resource Group ARM Export' -Arguments @('group', 'export', '--name', $ResourceGroup, '--include-parameter-default-value')

$recentDeploymentOperations = Get-RecentDeploymentOperationResult -Deployments $deployments.Data -CurrentResourceGroup $ResourceGroup -MaxDeployments $MaxDeploymentOperationGroups
$results.Add($recentDeploymentOperations)

$detailedResourceSnapshots = Get-DetailedResourceSnapshotResult -Resources $resources.Data -MaxResources $MaxDetailedResources
$results.Add($detailedResourceSnapshots)

$resourceItems = @(ConvertTo-Array -InputObject $resources.Data)
$lockItems = @(ConvertTo-Array -InputObject $locks.Data)
$deploymentItems = @(ConvertTo-Array -InputObject $deployments.Data)
$policyAssignmentItems = @(ConvertTo-Array -InputObject $policyAssignments.Data)
$policyExemptionItems = @(ConvertTo-Array -InputObject $policyExemptions.Data)
$roleAssignmentItems = @(ConvertTo-Array -InputObject $roleAssignments.Data)
$advisorItems = @(ConvertTo-Array -InputObject $advisorRecommendations.Data)

$summary = [ordered]@{
    'Subscription Name' = $account.Data.name
    'Subscription Id' = $account.Data.id
    'Tenant Id' = $account.Data.tenantId
    'Resource Group Name' = $resourceGroupResult.Data.name
    'Resource Group Id' = $resourceGroupId
    'Location' = $resourceGroupResult.Data.location
    'Managed By' = $resourceGroupResult.Data.managedBy
    'Provisioning State' = $resourceGroupResult.Data.properties.provisioningState
    'Tag Count' = Get-TagCount -InputObject $resourceGroupResult.Data.tags
    'Tag Names' = Get-TagSummary -InputObject $resourceGroupResult.Data.tags
    'Resource Count' = $resourceItems.Count
    'Lock Count' = $lockItems.Count
    'Deployment Count' = $deploymentItems.Count
    'Policy Assignment Count' = $policyAssignmentItems.Count
    'Policy Exemption Count' = $policyExemptionItems.Count
    'Role Assignment Count' = $roleAssignmentItems.Count
    'Advisor Recommendation Count' = $advisorItems.Count
    'Activity Log Window (Days)' = $ActivityLogDays
    'Activity Log Max Events' = $ActivityLogMaxEvents
    'Detailed Resource Snapshot Limit' = $MaxDetailedResources
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeResourceGroupName = ($ResourceGroup -replace '[^A-Za-z0-9._-]', '-')
$reportPath = Join-Path -Path $OutputDirectory -ChildPath ('ResourceGroupReport-{0}-{1}.md' -f $safeResourceGroupName, $timestamp)

$builder = [System.Text.StringBuilder]::new()
Add-MarkdownLine -Builder $builder -Text ('# Resource Group Report: {0}' -f $ResourceGroup)
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text ('Generated: {0}' -f (Get-Date).ToString('u'))
Add-MarkdownLine -Builder $builder -Text ('Resource Group: `{0}`' -f $ResourceGroup)
if ($Subscription) {
    Add-MarkdownLine -Builder $builder -Text ('Requested Subscription: `{0}`' -f $Subscription)
}
Add-MarkdownLine -Builder $builder -Text 'Sensitive values in exported templates, nested ARM properties, and other secret-bearing fields are redacted.'
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text '## Summary'
Add-KeyValueTable -Builder $builder -Values $summary

Add-ResourceInventorySection -Builder $builder -Resources $resources.Data
Add-DeploymentSummarySection -Builder $builder -Deployments $deployments.Data
Add-ActivityLogSummarySection -Builder $builder -Events $activityLog.Data

Add-JsonSection -Builder $builder -Title 'Azure Account Context' -Result $account
Add-JsonSection -Builder $builder -Title 'Resource Group Overview' -Result $resourceGroupResult
Add-JsonSection -Builder $builder -Title 'Resource Group Resources' -Result $resources
Add-JsonSection -Builder $builder -Title 'Resource Group Locks' -Result $locks
Add-JsonSection -Builder $builder -Title 'Resource Group Deployments' -Result $deployments
Add-JsonSection -Builder $builder -Title 'Recent Deployment Operations' -Result $recentDeploymentOperations
Add-JsonSection -Builder $builder -Title 'Policy Assignments At Scope' -Result $policyAssignments
Add-JsonSection -Builder $builder -Title 'Policy Exemptions At Scope' -Result $policyExemptions
Add-JsonSection -Builder $builder -Title 'Policy Compliance Summary' -Result $policySummary
Add-JsonSection -Builder $builder -Title 'Role Assignments At Scope' -Result $roleAssignments
Add-JsonSection -Builder $builder -Title 'Resource Group Activity Log' -Result $activityLog
Add-JsonSection -Builder $builder -Title 'Advisor Recommendations For Resource Group' -Result $advisorRecommendations
Add-JsonSection -Builder $builder -Title 'Resource Group ARM Export' -Result $armExport
Add-JsonSection -Builder $builder -Title 'Detailed Resource ARM Snapshots' -Result $detailedResourceSnapshots
Add-CollectionStatusSection -Builder $builder -Results $results

Write-Host "[INFO ] Writing report to '$reportPath'..." -ForegroundColor Cyan
try {
    [System.IO.File]::WriteAllText($reportPath, $builder.ToString(), [System.Text.Encoding]::UTF8)
    Write-StatusMessage -Level 'OK' -Message ('Report written to {0}' -f $reportPath)
    Write-Host ('Report written to {0}' -f $reportPath)
} catch {
    Write-Warning "[ERROR] Failed to write report to '$reportPath': $_"
    Write-Verbose $_.ScriptStackTrace
}