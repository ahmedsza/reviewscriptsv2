[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManagedInstanceName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'output'),

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

$doc = New-CollectorDocument -ResourceType 'Microsoft.Sql/managedInstances' -ResourceName $ManagedInstanceName -ResourceGroup $ResourceGroup -Subscription $Subscription

$mi = Invoke-AzCommandJson -Label 'sql.mi.show' -Arguments @('sql','mi','show','--name',$ManagedInstanceName,'--resource-group',$ResourceGroup) -Subscription $Subscription -Required
Add-CollectorSection -Document $doc -Name 'show' -Result $mi
Add-CollectorSection -Document $doc -Name 'databases' -Result (Invoke-AzCommandJson -Label 'sql.midb.list' -Arguments @('sql','midb','list','--managed-instance',$ManagedInstanceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'aadAdmins' -Result (Invoke-AzCommandJson -Label 'sql.mi.ad-admin.list' -Arguments @('sql','mi','ad-admin','list','--name',$ManagedInstanceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'failoverGroup' -Result (Invoke-AzCommandJson -Label 'sql.instance-failover-group.list' -Arguments @('sql','instance-failover-group','list','--name',$ManagedInstanceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)
Add-CollectorSection -Document $doc -Name 'startStopSchedule' -Result (Invoke-AzCommandJson -Label 'sql.mi.start-stop-schedule.list' -Arguments @('sql','mi','start-stop-schedule','list','--mi',$ManagedInstanceName,'--resource-group',$ResourceGroup) -Subscription $Subscription)

if ($mi.success -and $mi.data -and $mi.data.id) {
    Add-CollectorSection -Document $doc -Name 'diagnosticSettings' -Result (Invoke-AzCommandJson -Label 'monitor.diagnostic-settings.list' -Arguments @('monitor','diagnostic-settings','list','--resource',$mi.data.id) -Subscription $Subscription)
    Add-CollectorSection -Document $doc -Name 'privateEndpointConnections' -Result (Invoke-AzCommandJson -Label 'network.private-endpoint-connection.list' -Arguments @('network','private-endpoint-connection','list','--id',$mi.data.id) -Subscription $Subscription)
}

$safe = ConvertTo-CollectorSafeFileName -Text $ManagedInstanceName
$outFile = Join-Path $OutputDirectory ("sql-managed-instance-{0}.json" -f $safe)
Save-CollectorDocument -Document $doc -OutputPath $outFile

Write-CollectorMessage -Level 'OK' -Message ("Saved {0}" -f $outFile)
[pscustomobject]@{ resourceType = 'sqlManagedInstance'; name = $ManagedInstanceName; outputFile = $outFile }
