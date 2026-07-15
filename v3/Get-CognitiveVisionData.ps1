[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AccountName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.CognitiveServices/accounts' -ResourceName $AccountName -ResourceGroup $ResourceGroup -Subscription $Subscription

$account = Invoke-AzCommandJson -Label 'cognitiveservices.account.show' -Arguments @('cognitiveservices','account','show','--name',$AccountName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $account
Add-CollectorSection -Document $doc -Name 'networkRule' -Result (Invoke-AzCommandJson -Label 'cognitiveservices.account.network-rule.list' -Arguments @('cognitiveservices','account','network-rule','list','--name',$AccountName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'identity' -Result (Invoke-AzCommandJson -Label 'cognitiveservices.account.identity.show' -Arguments @('cognitiveservices','account','identity','show','--name',$AccountName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'privateEndpointConnections.via.az.resource.show' -Result (Invoke-AzCommandJson -Label 'cognitiveservices.privateEndpointConnections' -Arguments @('resource','show','--resource-group',$ResourceGroup,'--name',$AccountName,'--resource-type','Microsoft.CognitiveServices/accounts','--query','properties.privateEndpointConnections') -Subscription $Subscription)

if ($account.success -and $account.data -and $account.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$account.data.id) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $AccountName
$outFile = Join-Path $OutputDirectory ("cognitive-vision-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'cognitiveVision'; name = $AccountName; outputFile = $outFile }
