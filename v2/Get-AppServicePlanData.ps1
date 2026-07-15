[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.Web/serverfarms' -ResourceName $PlanName -ResourceGroup $ResourceGroup -Subscription $Subscription

$plan = Invoke-AzCommandJson -Label 'appServicePlan.show' -Arguments @('appservice','plan','show','--name',$PlanName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $plan
Add-CollectorSection -Document $doc -Name 'webapps' -Result (Invoke-AzCommandJson -Label 'webapp.list.by.plan' -Arguments @('webapp','list','--resource-group',$ResourceGroup,'--query',"[?serverFarmId=='$($plan.data.id)']") -Subscription $Subscription)

if ($plan.success -and $plan.data -and $plan.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$plan.data.id) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $PlanName
$outFile = Join-Path $OutputDirectory ("appservice-plan-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'appservicePlan'; name = $PlanName; outputFile = $outFile }
