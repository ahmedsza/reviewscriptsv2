[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.Storage/storageAccounts' -ResourceName $StorageAccountName -ResourceGroup $ResourceGroup -Subscription $Subscription

$account = Invoke-AzCommandJson -Label 'storage.account.show' -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $account
Add-CollectorSection -Document $doc -Name 'networkRules' -Result (Invoke-AzCommandJson -Label 'storage.account.network-rule.list' -Arguments @('storage','account','network-rule','list','--account-name',$StorageAccountName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'blobServiceProperties' -Result (Invoke-AzCommandJson -Label 'storage.account.blob-service-properties.show' -Arguments @('storage','account','blob-service-properties','show','--account-name',$StorageAccountName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'managementPolicy' -Result (Invoke-AzCommandJson -Label 'storage.account.management-policy.show' -Arguments @('storage','account','management-policy','show','--account-name',$StorageAccountName,'--resource-group',$ResourceGroup) -Subscription $Subscription)

if ($account.success -and $account.data -and $account.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$account.data.id) -Subscription $Subscription)
    Add-CollectorSection -Document $doc -Name 'privateEndpointConnections' -Result (Invoke-AzCommandJson -Label 'network.private-endpoint-connection.list' -Arguments @('network','private-endpoint-connection','list','--id',$account.data.id) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $StorageAccountName
$outFile = Join-Path $OutputDirectory ("storage-account-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'storageAccount'; name = $StorageAccountName; outputFile = $outFile }
