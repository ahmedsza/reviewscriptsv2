[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppServiceName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$Slot,

    [string]$OutputDirectory = (Get-Location).Path,

    [string]$Subscription,

    [int]$MaxDetectorResponsesPerCategory = 5
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
    Write-Host ("{0} {1} {2}" -f $timestamp, $paddedLevel, $Message) -ForegroundColor $color
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

function Invoke-AzRestQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [string]$Method = 'get',

        [switch]$Required
    )

    $baseUrl = 'https://management.azure.com'
    $url = '{0}{1}' -f $baseUrl, $RelativePath
    $arguments = @('rest', '--method', $Method, '--url', $url)
    Invoke-AzCliCommand -Label $Label -Arguments $arguments -Required:$Required
}

function Test-SensitiveName {
    param(
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return $Name -match '(?i)(password|passwd|pwd|secret|token|connectionstring|accountkey|sharedaccesskey|sharedkey|clientsecret|publishingpassword|sas|instrumentationkey|utterance|query)'
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

function Get-DiagnosticsBasePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$CurrentResourceGroup,

        [Parameter(Mandatory = $true)]
        [string]$CurrentAppServiceName,

        [string]$CurrentSlot
    )

    if ($CurrentSlot) {
        return '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Web/sites/{2}/slots/{3}' -f $SubscriptionId, $CurrentResourceGroup, $CurrentAppServiceName, $CurrentSlot
    }

    return '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Web/sites/{2}' -f $SubscriptionId, $CurrentResourceGroup, $CurrentAppServiceName
}

function Get-DetectorCategoryName {
    param(
        $Detector
    )

    $categoryName = Get-SafePropertyValue -InputObject $Detector -Path @('properties', 'metadata', 'category')
    if ([string]::IsNullOrWhiteSpace([string]$categoryName)) {
        return 'Uncategorized'
    }

    return [string]$categoryName
}

function Get-DetectorDisplayName {
    param(
        $Detector
    )

    $displayName = Get-SafePropertyValue -InputObject $Detector -Path @('properties', 'metadata', 'name')
    if ([string]::IsNullOrWhiteSpace([string]$displayName)) {
        return [string](Get-SafePropertyValue -InputObject $Detector -Path @('name'))
    }

    return [string]$displayName
}

Test-AzureCliPrerequisites
Write-StatusMessage -Level 'INFO' -Message ("Starting App Service diagnostics report for {0} in resource group {1}" -f $AppServiceName, $ResourceGroup)

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

function Add-RestResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [switch]$Required
    )

    $result = Invoke-AzRestQuery -Label $Label -RelativePath $RelativePath -Required:$Required
    $results.Add($result)
    return $result
}

$account = Add-QueryResult -Label 'Azure Account' -Arguments @('account', 'show') -Required
$resourceGroupResult = Assert-ResourceGroupAvailable -AccountResult $account -ResourceGroupName $ResourceGroup
$results.Add($resourceGroupResult)
$webAppArguments = @('webapp', 'show', '--name', $AppServiceName, '--resource-group', $ResourceGroup)
if ($Slot) {
    $webAppArguments += @('--slot', $Slot)
}
$webApp = Add-QueryResult -Label 'Web App Overview' -Arguments $webAppArguments -Required

$subscriptionId = $account.Data.id
$apiVersion = '2025-05-01'
$basePath = Get-DiagnosticsBasePath -SubscriptionId $subscriptionId -CurrentResourceGroup $ResourceGroup -CurrentAppServiceName $AppServiceName -CurrentSlot $Slot

# The /diagnostics categories endpoint is only supported on Windows App Service.
# Linux apps (including WordPress on App Service Linux) return 404 for this call.
$appIsLinux = $webApp.Success -and $webApp.Data -and ([string]$webApp.Data.kind -match 'linux')
if ($appIsLinux) {
    Write-Host "[INFO ] Skipping Site Diagnostic Categories — not supported on Linux App Service" -ForegroundColor DarkGray
    $categories = [pscustomobject]@{ Label = 'Site Diagnostic Categories'; Command = 'skipped'; Success = $false; ExitCode = $null; Data = $null; ErrorMessage = 'Not supported on Linux App Service' }
    $results.Add($categories)
} else {
    $categories = Add-RestResult -Label 'Site Diagnostic Categories' -RelativePath ("{0}/diagnostics?api-version={1}" -f $basePath, $apiVersion)
}
$detectorResponses = Add-RestResult -Label 'Site Detector Responses' -RelativePath ("{0}/detectors?api-version={1}" -f $basePath, $apiVersion)

$categoryDetails = [System.Collections.Generic.List[object]]::new()
if ($categories.Success -and $categories.Data -and $categories.Data.value) {
    foreach ($category in @($categories.Data.value)) {
        $categoryName = [string]$category.name
        if ([string]::IsNullOrWhiteSpace($categoryName)) {
            continue
        }

        $detectors = Add-RestResult -Label ("Detectors: {0}" -f $categoryName) -RelativePath ("{0}/diagnostics/{1}/detectors?api-version={2}" -f $basePath, $categoryName, $apiVersion)
        $analyses = Add-RestResult -Label ("Analyses: {0}" -f $categoryName) -RelativePath ("{0}/diagnostics/{1}/analyses?api-version={2}" -f $basePath, $categoryName, $apiVersion)

        $detectorDetailResults = [System.Collections.Generic.List[object]]::new()
        if ($detectors.Success -and $detectors.Data -and $detectors.Data.value) {
            $selectedDetectors = @($detectors.Data.value | Select-Object -First $MaxDetectorResponsesPerCategory)
            foreach ($detector in $selectedDetectors) {
                $detectorName = [string]$detector.name
                if ([string]::IsNullOrWhiteSpace($detectorName)) {
                    continue
                }

                $detectorResponse = Add-RestResult -Label ("Detector Response: {0}/{1}" -f $categoryName, $detectorName) -RelativePath ("{0}/diagnostics/{1}/detectors/{2}?api-version={3}" -f $basePath, $categoryName, $detectorName, $apiVersion)
                $detectorDetailResults.Add($detectorResponse)
            }
        }

        $analysisDetailResults = [System.Collections.Generic.List[object]]::new()
        if ($analyses.Success -and $analyses.Data -and $analyses.Data.value) {
            $selectedAnalyses = @($analyses.Data.value | Select-Object -First $MaxDetectorResponsesPerCategory)
            foreach ($analysis in $selectedAnalyses) {
                $analysisName = [string]$analysis.name
                if ([string]::IsNullOrWhiteSpace($analysisName)) {
                    continue
                }

                $analysisResult = Add-RestResult -Label ("Analysis Result: {0}/{1}" -f $categoryName, $analysisName) -RelativePath ("{0}/diagnostics/{1}/analyses/{2}?api-version={3}" -f $basePath, $categoryName, $analysisName, $apiVersion)
                $analysisDetailResults.Add($analysisResult)
            }
        }

        $categoryDetails.Add([pscustomobject]@{
                Name = $categoryName
                Category = $category
                Detectors = $detectors
                Analyses = $analyses
                DetectorResponses = $detectorDetailResults
                AnalysisResults = $analysisDetailResults
            })
    }
}

$detectorGroups = [System.Collections.Generic.List[object]]::new()
if ($detectorResponses.Success -and $detectorResponses.Data -and $detectorResponses.Data.value) {
    $groupedDetectors = @($detectorResponses.Data.value | Group-Object -Property { Get-DetectorCategoryName -Detector $_ })
    foreach ($group in $groupedDetectors) {
        $sampleRows = foreach ($detector in @($group.Group | Select-Object -First $MaxDetectorResponsesPerCategory)) {
            [pscustomobject]@{
                Name = [string](Get-SafePropertyValue -InputObject $detector -Path @('name'))
                DisplayName = Get-DetectorDisplayName -Detector $detector
                StatusId = Get-SafePropertyValue -InputObject $detector -Path @('properties', 'status', 'statusId')
                Description = Get-SafePropertyValue -InputObject $detector -Path @('properties', 'metadata', 'description')
            }
        }

        $detectorGroups.Add([pscustomobject]@{
                Name = [string]$group.Name
                Count = @($group.Group).Count
                SampleDetectors = @($sampleRows)
            })
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeAppName = ($AppServiceName -replace '[^A-Za-z0-9._-]', '-')
$slotSuffix = if ($Slot) { '-slot-{0}' -f ($Slot -replace '[^A-Za-z0-9._-]', '-') } else { '' }
$reportPath = Join-Path -Path $OutputDirectory -ChildPath ("AppServiceDiagnosticsReport-{0}{1}-{2}.md" -f $safeAppName, $slotSuffix, $timestamp)

$summary = [ordered]@{
    'Subscription Name' = $account.Data.name
    'Subscription Id' = $account.Data.id
    'Tenant Id' = $account.Data.tenantId
    'Resource Group Location' = $resourceGroupResult.Data.location
    'App Service Name' = $webApp.Data.name
    'Slot' = if ($Slot) { $Slot } else { 'production' }
    'Kind' = $webApp.Data.kind
    'Location' = $webApp.Data.location
    'State' = $webApp.Data.state
    'Default Hostname' = $webApp.Data.defaultHostName
    'Diagnostic Categories Found' = if ($categories.Success -and $categories.Data.value) { @($categories.Data.value).Count } else { 0 }
    'Detector Responses Returned' = if ($detectorResponses.Success -and $detectorResponses.Data.value) { @($detectorResponses.Data.value).Count } else { 0 }
    'Detector Groups Derived' = $detectorGroups.Count
    'Category Discovery Mode' = if ($categories.Success) { 'REST categories endpoint' } else { 'Derived from detector metadata' }
}

$slotDisplayName = if ($Slot) { $Slot } else { 'production' }

$builder = [System.Text.StringBuilder]::new()
Add-MarkdownLine -Builder $builder -Text ('# App Service Diagnostics Report: {0}' -f $AppServiceName)
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text ('Generated: {0}' -f (Get-Date).ToString('u'))
Add-MarkdownLine -Builder $builder -Text ('Resource Group: `{0}`' -f $ResourceGroup)
Add-MarkdownLine -Builder $builder -Text ('Slot: `{0}`' -f $slotDisplayName)
if ($Subscription) {
    Add-MarkdownLine -Builder $builder -Text ('Requested Subscription: `{0}`' -f $Subscription)
}
Add-MarkdownLine -Builder $builder -Text ('API Version: `{0}`' -f $apiVersion)
Add-MarkdownLine -Builder $builder -Text 'This report targets the App Service Diagnose and Solve Problems REST surface via `az rest`.'
Add-MarkdownLine -Builder $builder
Add-MarkdownLine -Builder $builder -Text '## Summary'
Add-KeyValueTable -Builder $builder -Values $summary

if (-not $categories.Success -and $detectorResponses.Success) {
    Add-MarkdownLine -Builder $builder -Text '> Note: The site-level `/diagnostics` endpoint was unavailable for this app. Category-style sections below were derived from detector metadata returned by `/detectors`.'
    Add-MarkdownLine -Builder $builder
}

Add-JsonSection -Builder $builder -Title 'Azure Account Context' -Result $account
Add-JsonSection -Builder $builder -Title 'Resource Group Overview' -Result $resourceGroupResult
Add-JsonSection -Builder $builder -Title 'Web App Overview' -Result $webApp
Add-JsonSection -Builder $builder -Title 'Site Diagnostic Categories' -Result $categories
Add-JsonSection -Builder $builder -Title 'Site Detector Responses' -Result $detectorResponses

if ($detectorGroups.Count -gt 0) {
    Add-MarkdownLine -Builder $builder -Text '## Detector Groups'
    Add-MarkdownLine -Builder $builder -Text '| Group | Detector Count | Sample Detector Names |'
    Add-MarkdownLine -Builder $builder -Text '| --- | --- | --- |'

    foreach ($group in $detectorGroups) {
        $sampleNames = @($group.SampleDetectors | ForEach-Object { $_.DisplayName }) -join ', '
        Add-MarkdownLine -Builder $builder -Text ('| {0} | {1} | {2} |' -f (ConvertTo-MarkdownText -Value $group.Name), $group.Count, (ConvertTo-MarkdownText -Value $sampleNames))
    }

    Add-MarkdownLine -Builder $builder

    foreach ($group in $detectorGroups) {
        Add-MarkdownLine -Builder $builder -Text ('### Derived Group: {0}' -f $group.Name)
        Add-MarkdownLine -Builder $builder -Text '| Detector | Status Id | Description |'
        Add-MarkdownLine -Builder $builder -Text '| --- | --- | --- |'

        foreach ($sampleDetector in $group.SampleDetectors) {
            Add-MarkdownLine -Builder $builder -Text ('| {0} | {1} | {2} |' -f (ConvertTo-MarkdownText -Value $sampleDetector.DisplayName), (ConvertTo-MarkdownText -Value $sampleDetector.StatusId), (ConvertTo-MarkdownText -Value $sampleDetector.Description))
        }

        Add-MarkdownLine -Builder $builder
    }
}

if ($categoryDetails.Count -gt 0) {
    Add-MarkdownLine -Builder $builder -Text '## Category Details'
    Add-MarkdownLine -Builder $builder

    foreach ($categoryDetail in $categoryDetails) {
        Add-MarkdownLine -Builder $builder -Text ('### Category: {0}' -f $categoryDetail.Name)
        Add-MarkdownLine -Builder $builder
        Add-JsonSection -Builder $builder -Title ('Detectors: {0}' -f $categoryDetail.Name) -HeadingLevel 4 -Result $categoryDetail.Detectors
        Add-JsonSection -Builder $builder -Title ('Analyses: {0}' -f $categoryDetail.Name) -HeadingLevel 4 -Result $categoryDetail.Analyses

        foreach ($detectorResponse in $categoryDetail.DetectorResponses) {
            Add-JsonSection -Builder $builder -Title $detectorResponse.Label -HeadingLevel 4 -Result $detectorResponse
        }

        foreach ($analysisResult in $categoryDetail.AnalysisResults) {
            Add-JsonSection -Builder $builder -Title $analysisResult.Label -HeadingLevel 4 -Result $analysisResult
        }
    }
}

Add-CollectionStatusSection -Builder $builder -Results $results

Write-Host "[INFO ] Writing report to '$reportPath'..." -ForegroundColor Cyan
try {
    [System.IO.File]::WriteAllText($reportPath, $builder.ToString(), [System.Text.Encoding]::UTF8)
    Write-StatusMessage -Level 'OK' -Message ("Report written to {0}" -f $reportPath)
    Write-Host ("Report written to {0}" -f $reportPath)
} catch {
    Write-Warning "[ERROR] Failed to write report to '$reportPath': $_"
    Write-Verbose $_.ScriptStackTrace
}