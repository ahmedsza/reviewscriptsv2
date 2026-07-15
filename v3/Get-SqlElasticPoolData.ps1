[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerName,

    [Parameter(Mandatory = $true)]
    [string]$ElasticPoolName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.Sql/servers/elasticPools' -ResourceName $ElasticPoolName -ResourceGroup $ResourceGroup -Subscription $Subscription
$doc.metadata.serverName = $ServerName

$pool = Invoke-AzCommandJson -Label 'sql.elastic-pool.show' -Arguments @('sql','elastic-pool','show','--server',$ServerName,'--name',$ElasticPoolName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $pool
Add-CollectorSection -Document $doc -Name 'databases' -Result (Invoke-AzCommandJson -Label 'sql.db.list.by.elasticpool' -Arguments @('sql','db','list','--server',$ServerName,'--resource-group',$ResourceGroup,'--query',"[?elasticPoolName=='$ElasticPoolName']") -Subscription $Subscription)

if ($pool.success -and $pool.data -and $pool.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$pool.data.id) -Subscription $Subscription)
}

$safeServer = ConvertTo-CollectorSafeFileName -Text $ServerName
$safePool = ConvertTo-CollectorSafeFileName -Text $ElasticPoolName
$outFile = Join-Path $OutputDirectory ("sql-elastic-pool-{0}-{1}.json" -f $safeServer, $safePool)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'sqlElasticPool'; name = $ElasticPoolName; outputFile = $outFile }
