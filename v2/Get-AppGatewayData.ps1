[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppGatewayName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.Network/applicationGateways' -ResourceName $AppGatewayName -ResourceGroup $ResourceGroup -Subscription $Subscription

$gateway = Invoke-AzCommandJson -Label 'applicationGateway.show' -Arguments @('network','application-gateway','show','--name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $gateway
Add-CollectorSection -Document $doc -Name 'backendHealth' -Result (Invoke-AzCommandJson -Label 'applicationGateway.show-backend-health' -Arguments @('network','application-gateway','show-backend-health','--name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'addressPools' -Result (Invoke-AzCommandJson -Label 'applicationGateway.address-pool.list' -Arguments @('network','application-gateway','address-pool','list','--gateway-name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'httpSettings' -Result (Invoke-AzCommandJson -Label 'applicationGateway.http-settings.list' -Arguments @('network','application-gateway','http-settings','list','--gateway-name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'frontendPorts' -Result (Invoke-AzCommandJson -Label 'applicationGateway.frontend-port.list' -Arguments @('network','application-gateway','frontend-port','list','--gateway-name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'frontendIpConfigs' -Result (Invoke-AzCommandJson -Label 'applicationGateway.frontend-ip.list' -Arguments @('network','application-gateway','frontend-ip','list','--gateway-name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'listeners' -Result (Invoke-AzCommandJson -Label 'applicationGateway.http-listener.list' -Arguments @('network','application-gateway','http-listener','list','--gateway-name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'routingRules' -Result (Invoke-AzCommandJson -Label 'applicationGateway.rule.list' -Arguments @('network','application-gateway','rule','list','--gateway-name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'probes' -Result (Invoke-AzCommandJson -Label 'applicationGateway.probe.list' -Arguments @('network','application-gateway','probe','list','--gateway-name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'sslCertificates' -Result (Invoke-AzCommandJson -Label 'applicationGateway.ssl-cert.list' -Arguments @('network','application-gateway','ssl-cert','list','--gateway-name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'rewriteRuleSets' -Result (Invoke-AzCommandJson -Label 'applicationGateway.rewrite-rule.set.list' -Arguments @('network','application-gateway','rewrite-rule','set','list','--gateway-name',$AppGatewayName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'wafPoliciesInGroup' -Result (Invoke-AzCommandJson -Label 'waf-policy.list' -Arguments @('network','application-gateway','waf-policy','list','--resource-group',$ResourceGroup) -Subscription $Subscription)

if ($gateway.success -and $gateway.data -and $gateway.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$gateway.data.id) -Subscription $Subscription)
    Add-CollectorSection -Document $doc -Name 'privateEndpointConnections' -Result (Invoke-AzCommandJson -Label 'network.private-endpoint-connection.list' -Arguments @('network','private-endpoint-connection','list','--id',$gateway.data.id) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $AppGatewayName
$outFile = Join-Path $OutputDirectory ("appgateway-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'appGateway'; name = $AppGatewayName; outputFile = $outFile }
