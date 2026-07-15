[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CacheName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Microsoft.Cache/Redis','Microsoft.Cache/redisEnterprise')]
    [string]$ResourceType,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType $ResourceType -ResourceName $CacheName -ResourceGroup $ResourceGroup -Subscription $Subscription

if ($ResourceType -eq 'Microsoft.Cache/Redis') {
    $show = Invoke-AzCommandJson -Label 'redis.show' -Arguments @('redis','show','--name',$CacheName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
    Add-CollectorSection -Document $doc -Name 'show' -Result $show
    Add-CollectorSection -Document $doc -Name 'firewallRules' -Result (Invoke-AzCommandJson -Label 'redis.firewall-rules.list' -Arguments @('redis','firewall-rules','list','--name',$CacheName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
    Add-CollectorSection -Document $doc -Name 'patchSchedule' -Result (Invoke-AzCommandJson -Label 'redis.patch-schedule.show' -Arguments @('redis','patch-schedule','show','--name',$CacheName,'--resource-group',$ResourceGroup) -Subscription $Subscription)

    if ($show.success -and $show.data -and $show.data.id) {
        Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$show.data.id) -Subscription $Subscription)
        Add-CollectorSection -Document $doc -Name 'privateEndpointConnections' -Result (Invoke-AzCommandJson -Label 'network.private-endpoint-connection.list' -Arguments @('network','private-endpoint-connection','list','--id',$show.data.id) -Subscription $Subscription)
    }
}
else {
    $show = Invoke-AzCommandJson -Label 'redisenterprise.show' -Arguments @('redisenterprise','show','--cluster-name',$CacheName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
    Add-CollectorSection -Document $doc -Name 'show' -Result $show
    Add-CollectorSection -Document $doc -Name 'databases' -Result (Invoke-AzCommandJson -Label 'redisenterprise.database.list' -Arguments @('redisenterprise','database','list','--cluster-name',$CacheName,'--resource-group',$ResourceGroup) -Subscription $Subscription)

    if ($show.success -and $show.data -and $show.data.id) {
        Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$show.data.id) -Subscription $Subscription)
        Add-CollectorSection -Document $doc -Name 'privateEndpointConnections' -Result (Invoke-AzCommandJson -Label 'network.private-endpoint-connection.list' -Arguments @('network','private-endpoint-connection','list','--id',$show.data.id) -Subscription $Subscription)
    }
}

$safe = ConvertTo-CollectorSafeFileName -Text $CacheName
$outFile = Join-Path $OutputDirectory ("redis-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'redis'; name = $CacheName; outputFile = $outFile }
