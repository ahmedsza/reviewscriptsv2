<#
.SYNOPSIS
    Runs all five WAF review scripts (Security, Cost Optimisation, Performance Efficiency,
    Reliability, Operational Excellence) and writes reports to a single output directory.

.DESCRIPTION
    This parent script is a convenience wrapper.  It calls each of the five individual
    review scripts in sequence, passing a shared set of parameters.  Each script produces
    its own Markdown report file in the output directory.

    Scripts called (in order):
      1. Get-SecurityReviewReport.ps1
      2. Get-CostOptimisationReport.ps1
      3. Get-PerformanceEfficiencyReport.ps1
      4. Get-ReliabilityReport.ps1
      5. Get-OperationalExcellenceReport.ps1

.PARAMETER AppServiceName
    The name of the Azure App Service (Web App).

.PARAMETER MySqlServerName
    The name of the Azure MySQL Flexible Server.

.PARAMETER ResourceGroup
    The resource group containing the App Service and MySQL server.

.PARAMETER OutputDirectory
    Directory where all report files will be written. Defaults to the current directory.
    Created automatically if it does not exist.

.PARAMETER Subscription
    Optional Azure subscription ID or name to target. If omitted the current az CLI
    subscription context is used.

.PARAMETER MetricLookbackDays
    Number of days of metric history to retrieve for performance and reliability checks.
    Defaults to 30. Applies to Cost Optimisation, Performance Efficiency, and Reliability scripts.

.PARAMETER AfdProfileName
    Optional Azure Front Door profile name. Used by the Security script.

.PARAMETER AfdResourceGroup
    Optional resource group for the Azure Front Door profile.
    Defaults to ResourceGroup if not specified.

.PARAMETER SkipScripts
    Optional list of script short-names to skip.
    Valid values: Security, Cost, Performance, Reliability, OperationalExcellence

.EXAMPLE
    .\Invoke-WafReview.ps1 `
        -AppServiceName  'my-wordpress-app' `
        -MySqlServerName 'my-mysql-server' `
        -ResourceGroup   'my-resource-group' `
        -OutputDirectory 'C:\Reports\waf-review'

.EXAMPLE
    # Run only Security and Reliability
    .\Invoke-WafReview.ps1 `
        -AppServiceName  'my-wordpress-app' `
        -MySqlServerName 'my-mysql-server' `
        -ResourceGroup   'my-resource-group' `
        -SkipScripts     @('Cost','Performance','OperationalExcellence')
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppServiceName,

    [Parameter(Mandatory = $true)]
    [string]$MySqlServerName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory,

    [string]$Subscription,

    [int]$MetricLookbackDays = 30,

    [string]$AfdProfileName,

    [string]$AfdResourceGroup,

    [ValidateSet('Security','Cost','Performance','Reliability','OperationalExcellence')]
    [string[]]$SkipScripts = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Banner {
    param([string]$Title)
    $line = '=' * 70
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-StepResult {
    param([string]$Name, [bool]$Success, [string]$Detail = '')
    if ($Success) {
        Write-Host "  [DONE] $Name" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $Name  — $Detail" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot

# Resolve output directory — create a timestamped folder if none was supplied
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Get-Location).Path ('output_{0}' -f (Get-Date -Format 'ddMMyyyyHHmm'))
}
if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Write-Host "Created output directory: $OutputDirectory" -ForegroundColor Yellow
}

# Build common splatted args
$commonArgs = @{
    AppServiceName  = $AppServiceName
    MySqlServerName = $MySqlServerName
    ResourceGroup   = $ResourceGroup
    OutputDirectory = $OutputDirectory
}
if ($Subscription) { $commonArgs['Subscription'] = $Subscription }

$metricArgs = @{ MetricLookbackDays = $MetricLookbackDays }

$afdArgs = @{}
if ($AfdResourceGroup) { $afdArgs['AfdResourceGroup'] = $AfdResourceGroup }

# ---------------------------------------------------------------------------
# Script definitions
# ---------------------------------------------------------------------------
$scripts = [ordered]@{
    Security             = @{
        File        = 'Get-SecurityReviewReport.ps1'
        ExtraArgs   = if ($AfdProfileName) { @{ AfdProfileName = $AfdProfileName } + $afdArgs } else { $afdArgs }
    }
    Cost                 = @{
        File        = 'Get-CostOptimisationReport.ps1'
        ExtraArgs   = $metricArgs + $afdArgs
    }
    Performance          = @{
        File        = 'Get-PerformanceEfficiencyReport.ps1'
        ExtraArgs   = $metricArgs + $afdArgs
    }
    Reliability          = @{
        File        = 'Get-ReliabilityReport.ps1'
        ExtraArgs   = $metricArgs + $afdArgs
    }
    OperationalExcellence = @{
        File        = 'Get-OperationalExcellenceReport.ps1'
        ExtraArgs   = @{}
    }
}

# ---------------------------------------------------------------------------
# Run each script
# ---------------------------------------------------------------------------
Write-Banner -Title 'WAF Review — All Pillars'
Write-Host "  App Service  : $AppServiceName"
Write-Host "  MySQL Server : $MySqlServerName"
Write-Host "  Resource Group: $ResourceGroup"
Write-Host "  Output Dir   : $OutputDirectory"
Write-Host "  Lookback Days: $MetricLookbackDays"
if ($SkipScripts.Count -gt 0) {
    Write-Host "  Skipping     : $($SkipScripts -join ', ')" -ForegroundColor Yellow
}

$startTime = Get-Date
$results   = [ordered]@{}  # key → @{ Status; Error; ReportFile }

foreach ($key in $scripts.Keys) {
    if ($SkipScripts -contains $key) {
        Write-Host ''
        Write-Host "  [SKIP] $key" -ForegroundColor DarkGray
        $results[$key] = @{ Status = 'Skipped'; Error = $null; ReportFile = $null }
        continue
    }

    $def        = $scripts[$key]
    $scriptPath = Join-Path -Path $scriptDir -ChildPath $def.File

    if (-not (Test-Path -Path $scriptPath)) {
        Write-Host ''
        Write-Host "  [MISS] $key — script not found: $scriptPath" -ForegroundColor Yellow
        $results[$key] = @{ Status = 'Script not found'; Error = $null; ReportFile = $null }
        continue
    }

    Write-Banner -Title "Running: $key  ($($def.File))"

    # Snapshot existing report files so we can detect what was newly created
    $beforeFiles = @(Get-ChildItem -Path $OutputDirectory -Filter '*.md' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

    $invokeArgs  = $commonArgs + $def.ExtraArgs
    $scriptError = $null
    try {
        & $scriptPath @invokeArgs
    }
    catch {
        $scriptError = $_.Exception.Message
        Write-Host ''
        Write-Host ("  [ERROR] $key threw an exception: {0}" -f $scriptError) -ForegroundColor Red
        Write-Host  "          Script output above may be partial but was preserved." -ForegroundColor Yellow
    }

    # Find the new report file (if any) created during this run
    $afterFiles  = @(Get-ChildItem -Path $OutputDirectory -Filter '*.md' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $newFile     = $afterFiles | Where-Object { $beforeFiles -notcontains $_ } | Select-Object -First 1

    $status = if ($null -ne $scriptError) { 'Completed with errors' } else { 'OK' }
    $stepDetail = if ($scriptError) { $scriptError } else { '' }
    Write-StepResult -Name $key -Success ($null -eq $scriptError) -Detail $stepDetail
    $results[$key] = @{ Status = $status; Error = $scriptError; ReportFile = $newFile }
}

# ---------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------
$elapsed = (Get-Date) - $startTime

Write-Banner -Title 'WAF Review — Summary'
foreach ($key in $results.Keys) {
    $r      = $results[$key]
    $status = $r.Status
    $colour = switch ($status) {
        'OK'                    { 'Green'    }
        'Skipped'               { 'DarkGray' }
        'Completed with errors' { 'Yellow'   }
        default                 { 'Red'      }
    }
    $filePart = if ($r.ReportFile) { "  → $(Split-Path $r.ReportFile -Leaf)" } else { '' }
    Write-Host ("  {0,-25} {1}{2}" -f $key, $status, $filePart) -ForegroundColor $colour
    if ($r.Error) {
        Write-Host ("    Error: {0}" -f $r.Error) -ForegroundColor Red
    }
}
Write-Host ''
Write-Host ("  Total elapsed : {0:mm\:ss}" -f $elapsed) -ForegroundColor Cyan
Write-Host ("  Reports saved : {0}" -f $OutputDirectory) -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------------------
# Markdown summary report
# ---------------------------------------------------------------------------
$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeAppName = ($AppServiceName -replace '[^A-Za-z0-9._-]', '-')
$summaryPath = Join-Path -Path $OutputDirectory -ChildPath ("WafReviewSummary-{0}-{1}.md" -f $safeAppName, $timestamp)

$md = [System.Text.StringBuilder]::new()
$null = $md.AppendLine("# WAF Review Summary Report")
$null = $md.AppendLine('')
$null = $md.AppendLine('| Property | Value |')
$null = $md.AppendLine('|---|---|')
$null = $md.AppendLine("| App Service | ``$AppServiceName`` |")
$null = $md.AppendLine("| MySQL Server | ``$MySqlServerName`` |")
$null = $md.AppendLine("| Resource Group | ``$ResourceGroup`` |")
$null = $md.AppendLine("| Subscription | $(if ($Subscription) { '``' + $Subscription + '``' } else { '*(default)*' }) |")
$null = $md.AppendLine("| Metric Lookback Days | $MetricLookbackDays |")
$null = $md.AppendLine("| Run Date | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
$null = $md.AppendLine("| Elapsed | $("{0:mm\:ss}" -f $elapsed) |")
$null = $md.AppendLine('')
$null = $md.AppendLine('## Pillar Results')
$null = $md.AppendLine('')
$null = $md.AppendLine('| Pillar | Status | Report File | Errors |')
$null = $md.AppendLine('|---|---|---|---|')

foreach ($key in $results.Keys) {
    $r       = $results[$key]
    $icon    = switch ($r.Status) {
        'OK'                    { '✅' }
        'Skipped'               { '⏭️' }
        'Completed with errors' { '⚠️' }
        default                 { '❌' }
    }
    $fileCell  = if ($r.ReportFile) { "[$(Split-Path $r.ReportFile -Leaf)]($(Split-Path $r.ReportFile -Leaf))" } else { '—' }
    $errorCell = if ($r.Error) { $r.Error -replace '\|', '\|' -replace "`n", ' ' -replace "`r", '' } else { '—' }
    $null = $md.AppendLine("| $key | $icon $($r.Status) | $fileCell | $errorCell |")
}

$null = $md.AppendLine('')
$null = $md.AppendLine('## Report Files')
$null = $md.AppendLine('')
$allReports = @($results.Values | Where-Object { $_.ReportFile } | ForEach-Object { $_.ReportFile })
if ($allReports.Count -gt 0) {
    foreach ($f in $allReports) {
        $null = $md.AppendLine("- [$(Split-Path $f -Leaf)]($(Split-Path $f -Leaf))")
    }
} else {
    $null = $md.AppendLine('*No report files were generated.*')
}

$null = $md.AppendLine('')
$null = $md.AppendLine('---')
$null = $md.AppendLine("*Generated by Invoke-WafReview.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')*")

$md.ToString() | Set-Content -Path $summaryPath -Encoding utf8
Write-Host "  Summary report: $summaryPath" -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------------------
# Zip the output directory
# ---------------------------------------------------------------------------
$zipTimestamp = $timestamp  # reuse the same timestamp used for the summary file
$zipName      = "wafreview-{0}.zip" -f $zipTimestamp
$zipPath      = Join-Path -Path (Split-Path -Path $OutputDirectory -Parent) -ChildPath $zipName

try {
    Compress-Archive -Path (Join-Path $OutputDirectory '*') -DestinationPath $zipPath -Force
    Write-Host "  Archive created: $zipPath" -ForegroundColor Cyan
} catch {
    Write-Host ("  [WARN] Could not create archive: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}
Write-Host ''
