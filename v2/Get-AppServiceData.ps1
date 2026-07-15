[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppServiceName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.Web/sites' -ResourceName $AppServiceName -ResourceGroup $ResourceGroup -Subscription $Subscription

$site = Invoke-AzCommandJson -Label 'appService.show' -Arguments @('webapp','show','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $site

Add-CollectorSection -Document $doc -Name 'config' -Result (Invoke-AzCommandJson -Label 'appService.config.show' -Arguments @('webapp','config','show','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'appSettings' -Result (Invoke-AzCommandJson -Label 'appService.config.appsettings.list' -Arguments @('webapp','config','appsettings','list','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'connectionStrings' -Result (Invoke-AzCommandJson -Label 'appService.config.connection-string.list' -Arguments @('webapp','config','connection-string','list','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'authSettings' -Result (Invoke-AzCommandJson -Label 'appService.auth.show' -Arguments @('webapp','auth','show','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'identity' -Result (Invoke-AzCommandJson -Label 'appService.identity.show' -Arguments @('webapp','identity','show','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'accessRestrictions' -Result (Invoke-AzCommandJson -Label 'appService.accessRestriction.show' -Arguments @('webapp','config','access-restriction','show','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'logging' -Result (Invoke-AzCommandJson -Label 'appService.log.config.show' -Arguments @('webapp','log','config','show','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'slots' -Result (Invoke-AzCommandJson -Label 'appService.deployment.slot.list' -Arguments @('webapp','deployment','slot','list','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'hostNames' -Result (Invoke-AzCommandJson -Label 'appService.hostname.list' -Arguments @('webapp','hostname','list','--webapp-name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'vnetIntegration' -Result (Invoke-AzCommandJson -Label 'appService.vnet-integration.list' -Arguments @('webapp','vnet-integration','list','--name',$AppServiceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)

if ($site.success -and $site.data -and $site.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$site.data.id) -Subscription $Subscription)
}

if ($site.success -and $site.data -and $site.data.serverFarmId) {
    $planId = [string]$site.data.serverFarmId
    Add-CollectorSection -Document $doc -Name 'associatedAppServicePlan' -Result (Invoke-AzCommandJson -Label 'appServicePlan.show.byId' -Arguments @('appservice','plan','show','--ids',$planId) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $AppServiceName
$outFile = Join-Path $OutputDirectory ("appservice-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'appservice'; name = $AppServiceName; outputFile = $outFile }
