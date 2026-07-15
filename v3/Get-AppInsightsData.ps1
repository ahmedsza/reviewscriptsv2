[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComponentName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'microsoft.insights/components' -ResourceName $ComponentName -ResourceGroup $ResourceGroup -Subscription $Subscription

$component = Invoke-AzCommandJson -Label 'appInsights.component.show' -Arguments @('monitor','app-insights','component','show','--app',$ComponentName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $component
Add-CollectorSection -Document $doc -Name 'quota' -Result (Invoke-AzCommandJson -Label 'appInsights.component.quota.show' -Arguments @('monitor','app-insights','component','quota','show','--app',$ComponentName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'linkedStorage' -Result (Invoke-AzCommandJson -Label 'appInsights.component.linked-storage.show' -Arguments @('monitor','app-insights','component','linked-storage','show','--app',$ComponentName,'--resource-group',$ResourceGroup) -Subscription $Subscription)

if ($component.success -and $component.data -and $component.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$component.data.id) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $ComponentName
$outFile = Join-Path $OutputDirectory ("appinsights-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'appInsights'; name = $ComponentName; outputFile = $outFile }
