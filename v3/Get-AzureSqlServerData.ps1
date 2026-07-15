[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.Sql/servers' -ResourceName $ServerName -ResourceGroup $ResourceGroup -Subscription $Subscription

$server = Invoke-AzCommandJson -Label 'sql.server.show' -Arguments @('sql','server','show','--name',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $server
Add-CollectorSection -Document $doc -Name 'databases' -Result (Invoke-AzCommandJson -Label 'sql.db.list' -Arguments @('sql','db','list','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'elasticPools' -Result (Invoke-AzCommandJson -Label 'sql.elastic-pool.list' -Arguments @('sql','elastic-pool','list','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'firewallRules' -Result (Invoke-AzCommandJson -Label 'sql.server.firewall-rule.list' -Arguments @('sql','server','firewall-rule','list','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'aadAdmins' -Result (Invoke-AzCommandJson -Label 'sql.server.ad-admin.list' -Arguments @('sql','server','ad-admin','list','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'vnetRules' -Result (Invoke-AzCommandJson -Label 'sql.server.vnet-rule.list' -Arguments @('sql','server','vnet-rule','list','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'auditPolicy' -Result (Invoke-AzCommandJson -Label 'sql.server.audit-policy.show' -Arguments @('sql','server','audit-policy','show','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'threatPolicy' -Result (Invoke-AzCommandJson -Label 'sql.server.threat-policy.show' -Arguments @('sql','server','threat-policy','show','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'connectionPolicy' -Result (Invoke-AzCommandJson -Label 'sql.server.conn-policy.show' -Arguments @('sql','server','conn-policy','show','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'dnsAliases' -Result (Invoke-AzCommandJson -Label 'sql.server.dns-alias.list' -Arguments @('sql','server','dns-alias','list','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'failoverGroups' -Result (Invoke-AzCommandJson -Label 'sql.failover-group.list' -Arguments @('sql','failover-group','list','--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)

if ($server.success -and $server.data -and $server.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$server.data.id) -Subscription $Subscription)
    Add-CollectorSection -Document $doc -Name 'privateEndpointConnections' -Result (Invoke-AzCommandJson -Label 'network.private-endpoint-connection.list' -Arguments @('network','private-endpoint-connection','list','--id',$server.data.id) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $ServerName
$outFile = Join-Path $OutputDirectory ("sql-server-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'azureSqlServer'; name = $ServerName; outputFile = $outFile }
