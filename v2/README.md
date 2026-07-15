# Azure Data Collection Scripts (v2)

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

## Main Entry Point

Use this script to auto-discover resources in a resource group and run all collectors:

```powershell
.\Invoke-CollectAzureServicesData.ps1 -ResourceGroup <rg-name> -Subscription <subscription-id>
```

Specify custom output directory:

```powershell
.\Invoke-CollectAzureServicesData.ps1 -ResourceGroup <rg-name> -OutputDirectory C:\Reports\waf-input
```

## Individual Collectors

- `Get-AppServicePlanData.ps1`
- `Get-AppServiceData.ps1`
- `Get-AppInsightsData.ps1`
- `Get-RedisCacheData.ps1`
- `Get-AppGatewayData.ps1`
- `Get-AzureSqlServerData.ps1`
- `Get-AzureSqlDatabaseData.ps1`

Run them directly if you want to collect by resource type manually.
