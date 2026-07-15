[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VirtualNetworkName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.Network/virtualNetworks' -ResourceName $VirtualNetworkName -ResourceGroup $ResourceGroup -Subscription $Subscription

$vnet = Invoke-AzCommandJson -Label 'network.vnet.show' -Arguments @('network','vnet','show','--name',$VirtualNetworkName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $vnet
Add-CollectorSection -Document $doc -Name 'subnets' -Result (Invoke-AzCommandJson -Label 'network.vnet.subnet.list' -Arguments @('network','vnet','subnet','list','--vnet-name',$VirtualNetworkName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'peerings' -Result (Invoke-AzCommandJson -Label 'network.vnet.peering.list' -Arguments @('network','vnet','peering','list','--vnet-name',$VirtualNetworkName,'--resource-group',$ResourceGroup) -Subscription $Subscription)

if ($vnet.success -and $vnet.data -and $vnet.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$vnet.data.id) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $VirtualNetworkName
$outFile = Join-Path $OutputDirectory ("virtual-network-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'virtualNetwork'; name = $VirtualNetworkName; outputFile = $outFile }
