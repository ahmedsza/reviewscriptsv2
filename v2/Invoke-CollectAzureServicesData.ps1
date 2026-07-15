<#
.SYNOPSIS
    Collects detailed Azure resource data for WAF-style reporting inputs.

.DESCRIPTION
    Discovers relevant resources in a resource group and runs resource-type collectors.
    Outputs structured JSON files that are easy to consume for report generation.

    Target resources:
    - App Service Plan
    - App Service
    - Application Insights
    - Redis Cache (classic and enterprise)
    - Application Gateway
    - Azure SQL Server and Azure SQL Databases
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$OutputDirectory,

    [string]$Subscription
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'Common-AzureCollector.ps1')
Test-AzCliPrerequisites

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Get-Location).Path ('output_{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

if (-not (Test-Path $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

Write-CollectorMessage -Level 'INFO' -Message ("Output directory: {0}" -f $OutputDirectory)

$discover = Invoke-AzCommandJson -Label 'resource.list' -Arguments @('resource','list','--resource-group',$ResourceGroup) -Subscription $Subscription -Required
$resources = @()
if ($discover.success -and $discover.data) {
    $resources = @($discover.data)
}

$types = @(
    'Microsoft.Web/sites',
    'Microsoft.Web/serverfarms',
    'microsoft.insights/components',
    'Microsoft.Cache/Redis',
    'Microsoft.Cache/redisEnterprise',
    'Microsoft.Network/applicationGateways',
    'Microsoft.Sql/servers'
)

$selected = @($resources | Where-Object { $types -contains $_.type })

$manifest = [ordered]@{
    metadata = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        resourceGroup = $ResourceGroup
        subscription = $Subscription
    }
    discovery = [ordered]@{
        totalResourcesInGroup = @($resources).Count
        selectedResources = @($selected).Count
        selectedTypes = $types
    }
    outputs = @()
    errors = @()
}

function Invoke-ChildCollector {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    try {
        $result = & $scriptPath @Parameters
        if ($result) {
            $manifest.outputs += @($result)
        }
    }
    catch {
        $manifest.errors += [ordered]@{
            script = $ScriptName
            message = $_.Exception.Message
        }
        Write-CollectorMessage -Level 'WARN' -Message ("Collector failed: {0} ({1})" -f $ScriptName, $_.Exception.Message)
    }
}

$common = @{
    ResourceGroup = $ResourceGroup
    OutputDirectory = $OutputDirectory
}
if ($Subscription) {
    $common.Subscription = $Subscription
}

foreach ($r in $selected) {
    switch ($r.type) {
        'Microsoft.Web/sites' {
            Invoke-ChildCollector -ScriptName 'Get-AppServiceData.ps1' -Parameters ($common + @{ AppServiceName = $r.name })
        }
        'Microsoft.Web/serverfarms' {
            Invoke-ChildCollector -ScriptName 'Get-AppServicePlanData.ps1' -Parameters ($common + @{ PlanName = $r.name })
        }
        'microsoft.insights/components' {
            Invoke-ChildCollector -ScriptName 'Get-AppInsightsData.ps1' -Parameters ($common + @{ ComponentName = $r.name })
        }
        'Microsoft.Cache/Redis' {
            Invoke-ChildCollector -ScriptName 'Get-RedisCacheData.ps1' -Parameters ($common + @{ CacheName = $r.name; ResourceType = 'Microsoft.Cache/Redis' })
        }
        'Microsoft.Cache/redisEnterprise' {
            Invoke-ChildCollector -ScriptName 'Get-RedisCacheData.ps1' -Parameters ($common + @{ CacheName = $r.name; ResourceType = 'Microsoft.Cache/redisEnterprise' })
        }
        'Microsoft.Network/applicationGateways' {
            Invoke-ChildCollector -ScriptName 'Get-AppGatewayData.ps1' -Parameters ($common + @{ AppGatewayName = $r.name })
        }
        'Microsoft.Sql/servers' {
            Invoke-ChildCollector -ScriptName 'Get-AzureSqlServerData.ps1' -Parameters ($common + @{ ServerName = $r.name })

            $dbList = Invoke-AzCommandJson -Label 'sql.db.list.for.discovery' -Arguments @('sql','db','list','--server',$r.name,'--resource-group',$ResourceGroup) -Subscription $Subscription
            if ($dbList.success -and $dbList.data) {
                foreach ($db in @($dbList.data)) {
                    Invoke-ChildCollector -ScriptName 'Get-AzureSqlDatabaseData.ps1' -Parameters ($common + @{ ServerName = $r.name; DatabaseName = $db.name })
                }
            }
        }
        default {
            Write-CollectorMessage -Level 'INFO' -Message ("Skipping unsupported type: {0}" -f $r.type)
        }
    }
}

$manifestFile = Join-Path $OutputDirectory 'collection-manifest.json'
($manifest | ConvertTo-Json -Depth 100) | Set-Content -Path $manifestFile -Encoding utf8

Write-CollectorMessage -Level 'OK' -Message ("Collection completed. Manifest: {0}" -f $manifestFile)
[pscustomobject]@{ outputDirectory = $OutputDirectory; manifest = $manifestFile }
