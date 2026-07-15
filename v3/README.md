# Azure Data Collection Scripts (v3)

This version is designed for custom solutions with no WordPress dependency.

Primary goal: collect as much technical detail as possible for these resource types and store it in structured JSON for later Azure Well-Architected reporting.

## Covered Resource Types

- App Service Plan (`Microsoft.Web/serverfarms`)
- App Service (`Microsoft.Web/sites`)
- Application Insights (`microsoft.insights/components`)
- Redis Cache classic (`Microsoft.Cache/Redis`)
- Redis Enterprise (`Microsoft.Cache/redisEnterprise`)
- Application Gateway (`Microsoft.Network/applicationGateways`)
- Azure SQL Server (`Microsoft.Sql/servers`)
- Azure SQL Database (`Microsoft.Sql/servers/databases`)
- Azure SQL Elastic Pool (`Microsoft.Sql/servers/elasticPools`)
- Azure SQL Managed Instance (`Microsoft.Sql/managedInstances`)
- Key Vault (`Microsoft.KeyVault/vaults`)
- Storage Account (`Microsoft.Storage/storageAccounts`)
- Virtual Network (`Microsoft.Network/virtualNetworks`)
- Computer Vision and Custom Vision (`Microsoft.CognitiveServices/accounts` where kind is `ComputerVision`, `CustomVision.Training`, or `CustomVision.Prediction`)

## Output Format

Each collector writes one JSON file per resource. JSON structure:

- `metadata`: schema/version, resource identity, generation timestamp
- `sections`: each section maps to one `az` command with:
  - command text
  - success/failure status
  - exit code
  - error (if any)
  - data payload

A top-level `collection-manifest.json` is written by the parent orchestrator to index all generated files.

## Prerequisites

- Azure CLI installed
- Logged in (`az login`)
- Reader (or higher) access to target resources
- Subscription parameter is optional; when omitted, scripts use the currently active Azure CLI subscription

## Main Entry Point

Use this script to:

- Accept a resource group as the key input parameter
- Discover all resources in that resource group
- Route each supported resource type to the correct collector script
- Record unsupported resource types in `collection-manifest.json`

Example:

```powershell
.\Invoke-CollectAzureServicesData.ps1 -ResourceGroup <rg-name> -Subscription <subscription-id>
```

Without explicit subscription (uses current `az account show` context):

```powershell
.\Invoke-CollectAzureServicesData.ps1 -ResourceGroup <rg-name>
```

When `-OutputDirectory` is omitted, the script creates a default directory named:

- `<ResourceGroupWithoutSpaces>_output`

Example: `My RG` -> `MyRG_output`

Specify custom output directory:

```powershell
.\Invoke-CollectAzureServicesData.ps1 -ResourceGroup <rg-name> -OutputDirectory C:\Reports\waf-input
```

## Subscription-Wide Collection

Use this script to collect data for all resource groups in a subscription:

```powershell
.\Invoke-CollectAllFromSubscription.ps1 -Subscription <subscription-id>
```

If `-Subscription` is omitted, the currently active Azure CLI subscription is used:

```powershell
.\Invoke-CollectAllFromSubscription.ps1
```

Optional parameters:

- `-OutputRootDirectory` to choose the base folder for all resource-group outputs
- `-ExcludeResourceGroups` to skip selected resource groups

## Individual Collectors

- `Get-AppServicePlanData.ps1`
- `Get-AppServiceData.ps1`
- `Get-AppInsightsData.ps1`
- `Get-RedisCacheData.ps1`
- `Get-AppGatewayData.ps1`
- `Get-AzureSqlServerData.ps1`
- `Get-AzureSqlDatabaseData.ps1`
- `Get-SqlElasticPoolData.ps1`
- `Get-SqlManagedInstanceData.ps1`
- `Get-KeyVaultData.ps1`
- `Get-StorageAccountData.ps1`
- `Get-VirtualNetworkData.ps1`
- `Get-CognitiveVisionData.ps1`
- `Invoke-CollectAllFromSubscription.ps1`

Run them directly if you want to collect by resource type manually.
