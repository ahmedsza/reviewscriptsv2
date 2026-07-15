[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VaultName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.KeyVault/vaults' -ResourceName $VaultName -ResourceGroup $ResourceGroup -Subscription $Subscription

$vault = Invoke-AzCommandJson -Label 'keyvault.show' -Arguments @('keyvault','show','--name',$VaultName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $vault
Add-CollectorSection -Document $doc -Name 'keys' -Result (Invoke-AzCommandJson -Label 'keyvault.key.list' -Arguments @('keyvault','key','list','--vault-name',$VaultName) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'secrets' -Result (Invoke-AzCommandJson -Label 'keyvault.secret.list' -Arguments @('keyvault','secret','list','--vault-name',$VaultName) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'certificates' -Result (Invoke-AzCommandJson -Label 'keyvault.certificate.list' -Arguments @('keyvault','certificate','list','--vault-name',$VaultName) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'networkRules' -Result (Invoke-AzCommandJson -Label 'keyvault.network-rule.list' -Arguments @('keyvault','network-rule','list','--name',$VaultName) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'privateEndpointConnections.via.az.resource.show' -Result (Invoke-AzCommandJson -Label 'keyvault.privateEndpointConnections' -Arguments @('resource','show','--resource-group',$ResourceGroup,'--name',$VaultName,'--resource-type','Microsoft.KeyVault/vaults','--query','properties.privateEndpointConnections') -Subscription $Subscription)

if ($vault.success -and $vault.data -and $vault.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$vault.data.id) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $VaultName
$outFile = Join-Path $OutputDirectory ("keyvault-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'keyVault'; name = $VaultName; outputFile = $outFile }
