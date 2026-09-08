[CmdletBinding()] param([string]$ResourceName,[string]$ResourceType,[Parameter(Mandatory)][string]$ResourceGroup,[Parameter(Mandatory)][string]$OutputDirectory,[string]$Subscription)
. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
$doc=New-CollectorDocument $ResourceType $ResourceName $ResourceGroup $Subscription
$plan=Invoke-AzCommandJson 'appservice.plan.show' @('appservice','plan','show','--name',$ResourceName,'--resource-group',$ResourceGroup) $Subscription -Required; Add-CollectorSection $doc 'show' $plan
$apps=Invoke-AzCommandJson 'webapp.list' @('webapp','list','--resource-group',$ResourceGroup) $Subscription
if($apps.success -and $plan.data.PSObject.Properties['id']){
	$planId=[string]$plan.data.id
	$apps.data=@($apps.data | Where-Object {$null -ne $_ -and $_.PSObject.Properties['serverFarmId'] -and [string]$_.serverFarmId -ieq $planId})
}
Add-CollectorSection $doc 'apps' $apps
if($plan.data.id){Add-StandardResourceEvidence $doc $plan.data.id $Subscription}
$file=Join-Path $OutputDirectory ('appservice-plan-{0}.json' -f (ConvertTo-CollectorSafeFileName $ResourceName)); Save-CollectorDocument $doc $file
[pscustomobject]@{resourceType='appServicePlan';name=$ResourceName;outputFile=$file}