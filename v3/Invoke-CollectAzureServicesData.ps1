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
    - Key Vault
    - Azure SQL Elastic Pool
    - Azure SQL Managed Instance
    - Storage Account
    - Virtual Network
    - Computer Vision and Custom Vision (Cognitive Services)
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
    'Microsoft.Sql/servers',
    'Microsoft.KeyVault/vaults',
    'Microsoft.Sql/servers/elasticPools',
    'Microsoft.Sql/managedInstances',
    'Microsoft.Storage/storageAccounts',
    'Microsoft.Network/virtualNetworks',
    'Microsoft.CognitiveServices/accounts'
)
$selectedCount = @($resources | Where-Object { $types -contains $_.type }).Count
$unsupported = @()

$manifest = [ordered]@{
    metadata = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        resourceGroup = $ResourceGroup
        subscription = $Subscription
    }
    discovery = [ordered]@{
        totalResourcesInGroup = @($resources).Count
        selectedResources = $selectedCount
        selectedTypes = $types
    }
    outputs = @()
    errors = @()
    unsupportedResources = @()
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

foreach ($r in $resources) {
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
        'Microsoft.KeyVault/vaults' {
            Invoke-ChildCollector -ScriptName 'Get-KeyVaultData.ps1' -Parameters ($common + @{ VaultName = $r.name })
        }
        'Microsoft.Sql/servers/elasticPools' {
            $segments = ([string]$r.id).Trim('/') -split '/'
            $serverName = $null
            for ($i = 0; $i -lt $segments.Length; $i++) {
                if ($segments[$i] -eq 'servers' -and ($i + 1) -lt $segments.Length) {
                    $serverName = $segments[$i + 1]
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($serverName)) {
                $manifest.errors += [ordered]@{
                    script = 'Get-SqlElasticPoolData.ps1'
                    message = "Could not determine SQL server name from resource ID: $($r.id)"
                }
                Write-CollectorMessage -Level 'WARN' -Message ("Skipping elastic pool {0}; server name could not be resolved" -f $r.name)
            }
            else {
                Invoke-ChildCollector -ScriptName 'Get-SqlElasticPoolData.ps1' -Parameters ($common + @{ ServerName = $serverName; ElasticPoolName = $r.name })
            }
        }
        'Microsoft.Sql/managedInstances' {
            Invoke-ChildCollector -ScriptName 'Get-SqlManagedInstanceData.ps1' -Parameters ($common + @{ ManagedInstanceName = $r.name })
        }
        'Microsoft.Storage/storageAccounts' {
            Invoke-ChildCollector -ScriptName 'Get-StorageAccountData.ps1' -Parameters ($common + @{ StorageAccountName = $r.name })
        }
        'Microsoft.Network/virtualNetworks' {
            Invoke-ChildCollector -ScriptName 'Get-VirtualNetworkData.ps1' -Parameters ($common + @{ VirtualNetworkName = $r.name })
        }
        'Microsoft.CognitiveServices/accounts' {
            $kind = [string]$r.kind
            if ($kind -match '^ComputerVision$' -or $kind -match '^CustomVision\.(Training|Prediction)$') {
                Invoke-ChildCollector -ScriptName 'Get-CognitiveVisionData.ps1' -Parameters ($common + @{ AccountName = $r.name })
            }
            else {
                $unsupported += [ordered]@{
                    name = $r.name
                    type = $r.type
                    kind = $kind
                    reason = 'Cognitive Services account kind is outside ComputerVision/CustomVision scope'
                }
                Write-CollectorMessage -Level 'INFO' -Message ("Skipping cognitive account {0} with kind {1}" -f $r.name, $kind)
            }
        }
        default {
            $unsupported += [ordered]@{
                name = $r.name
                type = $r.type
            }
            Write-CollectorMessage -Level 'INFO' -Message ("Skipping unsupported type: {0} ({1})" -f $r.type, $r.name)
        }
    }
}

$manifest.unsupportedResources = $unsupported

$manifestFile = Join-Path $OutputDirectory 'collection-manifest.json'
($manifest | ConvertTo-Json -Depth 100) | Set-Content -Path $manifestFile -Encoding utf8

Write-CollectorMessage -Level 'OK' -Message ("Collection completed. Manifest: {0}" -f $manifestFile)
[pscustomobject]@{ outputDirectory = $OutputDirectory; manifest = $manifestFile }
