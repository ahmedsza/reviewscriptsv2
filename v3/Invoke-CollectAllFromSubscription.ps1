<#
.SYNOPSIS
    Collects Azure service data for all resource groups in a subscription.

.DESCRIPTION
    Enumerates all resource groups in the target subscription and invokes
    Invoke-CollectAzureServicesData.ps1 for each resource group.

    If -Subscription is omitted, the currently active Azure CLI subscription
    from az account show is used.
#>
[CmdletBinding()]
param(
    [string]$Subscription,

    [string]$OutputRootDirectory = (Join-Path (Get-Location).Path 'reports'),

    [string[]]$ExcludeResourceGroups = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

if (-not $Subscription) {
    $account = Invoke-AzCommandJson -Label 'account.show' -Arguments @('account','show') -Required
    if ($account.success -and $account.data -and $account.data.id) {
        $Subscription = [string]$account.data.id
        Write-CollectorMessage -Level 'INFO' -Message ("Using current Azure CLI subscription: {0}" -f $Subscription)
    }
    else {
        throw 'Could not determine current Azure CLI subscription. Run az login and az account set if needed.'
    }
}

if (-not (Test-Path $OutputRootDirectory)) {
    New-Item -Path $OutputRootDirectory -ItemType Directory -Force | Out-Null
}

Write-CollectorMessage -Level 'INFO' -Message ("Output root directory: {0}" -f $OutputRootDirectory)

$reportsFolderName = Split-Path -Leaf $OutputRootDirectory
$reportsParentDirectory = Split-Path -Parent $OutputRootDirectory
if (-not $reportsParentDirectory) {
    $reportsParentDirectory = (Get-Location).Path
}
$reportsZipPath = Join-Path $reportsParentDirectory ("{0}.zip" -f $reportsFolderName)

$rgResult = Invoke-AzCommandJson -Label 'group.list' -Arguments @('group','list','--query','[].name') -Subscription $Subscription -Required
$resourceGroups = @()
if ($rgResult.success -and $rgResult.data) {
    $resourceGroups = @($rgResult.data)
}

if ($ExcludeResourceGroups.Count -gt 0) {
    $resourceGroups = @($resourceGroups | Where-Object { $ExcludeResourceGroups -notcontains $_ })
}

if ($resourceGroups.Count -eq 0) {
    Write-CollectorMessage -Level 'WARN' -Message 'No resource groups found to process.'

    if (Test-Path $reportsZipPath) {
        Remove-Item -Path $reportsZipPath -Force
    }
    Compress-Archive -Path $OutputRootDirectory -DestinationPath $reportsZipPath -Force
    Write-CollectorMessage -Level 'OK' -Message ("Reports archive created: {0}" -f $reportsZipPath)

    return [pscustomobject]@{
        subscription = $Subscription
        totalResourceGroups = 0
        outputRootDirectory = $OutputRootDirectory
        reportsZipPath = $reportsZipPath
        summaryFile = $null
    }
}

$childScript = Join-Path $PSScriptRoot 'Invoke-CollectAzureServicesData.ps1'
if (-not (Test-Path $childScript)) {
    throw "Required child script not found: $childScript"
}

$runSummary = [ordered]@{
    metadata = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        subscription = $Subscription
        outputRootDirectory = $OutputRootDirectory
    }
    totals = [ordered]@{
        resourceGroups = $resourceGroups.Count
        succeeded = 0
        failed = 0
    }
    resourceGroups = @()
}

foreach ($rg in $resourceGroups) {
    $rgOutputDirectory = Join-Path $OutputRootDirectory $rg

    Write-CollectorMessage -Level 'INFO' -Message ("Processing resource group: {0}" -f $rg)

    try {
        $result = & $childScript -ResourceGroup $rg -Subscription $Subscription -OutputDirectory $rgOutputDirectory
        $runSummary.totals.succeeded++
        $runSummary.resourceGroups += [ordered]@{
            resourceGroup = $rg
            status = 'Succeeded'
            outputDirectory = $rgOutputDirectory
            result = $result
        }
        Write-CollectorMessage -Level 'OK' -Message ("Completed resource group: {0}" -f $rg)
    }
    catch {
        $runSummary.totals.failed++
        $runSummary.resourceGroups += [ordered]@{
            resourceGroup = $rg
            status = 'Failed'
            outputDirectory = $rgOutputDirectory
            error = $_.Exception.Message
        }
        Write-CollectorMessage -Level 'WARN' -Message ("Failed resource group: {0} ({1})" -f $rg, $_.Exception.Message)
    }
}

$summaryFile = Join-Path $OutputRootDirectory 'subscription-collection-summary.json'
($runSummary | ConvertTo-Json -Depth 100) | Set-Content -Path $summaryFile -Encoding utf8

if (Test-Path $reportsZipPath) {
    Remove-Item -Path $reportsZipPath -Force
}
Compress-Archive -Path $OutputRootDirectory -DestinationPath $reportsZipPath -Force
Write-CollectorMessage -Level 'OK' -Message ("Reports archive created: {0}" -f $reportsZipPath)

Write-CollectorMessage -Level 'OK' -Message ("Subscription collection complete. Summary: {0}" -f $summaryFile)

[pscustomobject]@{
    subscription = $Subscription
    totalResourceGroups = $resourceGroups.Count
    succeeded = $runSummary.totals.succeeded
    failed = $runSummary.totals.failed
    outputRootDirectory = $OutputRootDirectory
    reportsZipPath = $reportsZipPath
    summaryFile = $summaryFile
}
