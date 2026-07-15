[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerName,

    [Parameter(Mandatory = $true)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.Sql/servers/databases' -ResourceName $DatabaseName -ResourceGroup $ResourceGroup -Subscription $Subscription
$doc.metadata.serverName = $ServerName

$db = Invoke-AzCommandJson -Label 'sql.db.show' -Arguments @('sql','db','show','--name',$DatabaseName,'--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $db
Add-CollectorSection -Document $doc -Name 'auditPolicy' -Result (Invoke-AzCommandJson -Label 'sql.db.audit-policy.show' -Arguments @('sql','db','audit-policy','show','--name',$DatabaseName,'--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'threatPolicy' -Result (Invoke-AzCommandJson -Label 'sql.db.threat-policy.show' -Arguments @('sql','db','threat-policy','show','--name',$DatabaseName,'--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'transparentDataEncryption' -Result (Invoke-AzCommandJson -Label 'sql.db.tde.show' -Arguments @('sql','db','tde','show','--name',$DatabaseName,'--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'shortTermRetentionPolicy' -Result (Invoke-AzCommandJson -Label 'sql.db.str-policy.show' -Arguments @('sql','db','str-policy','show','--name',$DatabaseName,'--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'longTermRetentionPolicy' -Result (Invoke-AzCommandJson -Label 'sql.db.ltr-policy.show' -Arguments @('sql','db','ltr-policy','show','--name',$DatabaseName,'--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'replicationLinks' -Result (Invoke-AzCommandJson -Label 'sql.db.replica.list-links' -Arguments @('sql','db','replica','list-links','--name',$DatabaseName,'--server',$ServerName,'--resource-group',$ResourceGroup) -Subscription $Subscription)

if ($db.success -and $db.data -and $db.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$db.data.id) -Subscription $Subscription)
}

$safeServer = ConvertTo-CollectorSafeFileName -Text $ServerName
$safeDb = ConvertTo-CollectorSafeFileName -Text $DatabaseName
$outFile = Join-Path $OutputDirectory ("sql-database-{0}-{1}.json" -f $safeServer, $safeDb)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'azureSqlDatabase'; name = $DatabaseName; outputFile = $outFile }
