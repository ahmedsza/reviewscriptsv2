# Azure Review Scripts

A collection of PowerShell scripts that use Azure CLI to collect configuration and diagnostic data from Azure resources and write timestamped Markdown reports.

## Prerequisites (all scripts)

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and on `PATH`
- Signed in with `az login`
- Sufficient permissions to read the target resources
- PowerShell execution policy that allows running local scripts

---

## Scripts

### `Get-ResourceGroupReport.ps1`

Collects a broad snapshot of an Azure resource group and writes a timestamped Markdown report.

**What the report includes:** resource group overview and metadata, full resource inventory with summary tables by type/location/kind, locks, deployments, recent deployment operations, role assignments, policy assignments and compliance, diagnostic settings, recent activity log events, Advisor recommendations, and an ARM template export. Per-resource ARM snapshots are included up to a configurable limit.

**Usage:**
```powershell
.\Get-ResourceGroupReport.ps1 -ResourceGroup <rgname> -Subscription <subscriptionid>
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-ResourceGroup` | Yes | — | Resource group name |
| `-Subscription` | No | current context | Azure subscription ID |
| `-OutputDirectory` | No | current directory | Where to write the report file |
| `-ActivityLogDays` | No | 30 | Number of days of activity log to retrieve (1–365) |
| `-ActivityLogMaxEvents` | No | 100 | Maximum activity log events (1–1000) |
| `-MaxDetailedResources` | No | 50 | Maximum per-resource ARM snapshots (1–500) |
| `-MaxDeploymentOperationGroups` | No | 10 | Maximum deployment operation groups (1–100) |

---

### `Get-AppServiceReport.ps1`

Collects configuration and runtime details for an Azure App Service (Web App) and its App Service Plan, and writes a timestamped Markdown report.

**What the report includes:** Azure account context, web app overview and full site configuration, app settings and connection strings (sensitive values redacted), access restrictions, auth settings, identity, logging, backups, storage mounts, hostname bindings, SSL certificates, deployment source, publishing metadata, instances, VNet integration, deployment slots, App Service Plan details, and diagnostic settings.

**Usage:**
```powershell
.\Get-AppServiceReport.ps1 -AppServiceName <appname> -ResourceGroup <rgname> -Subscription <subscriptionid>
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-AppServiceName` | Yes | — | App Service name |
| `-ResourceGroup` | Yes | — | Resource group name |
| `-Subscription` | No | current context | Azure subscription ID |
| `-OutputDirectory` | No | current directory | Where to write the report file |

---

### `Get-AppServiceReportDiagnostics.ps1`

Collects App Service **Diagnose and Solve Problems** data via the App Service Diagnostics REST API (`az rest`) and writes a timestamped Markdown report. Complements `Get-AppServiceReport.ps1` with deeper diagnostic insight.

**What the report includes:** Azure account context, app overview, site diagnostic categories, top-level site detector responses, per-category detector and analysis lists, individual detector/analysis results for the first few entries in each category, and a collection status table.

**Usage:**
```powershell
.\Get-AppServiceReportDiagnostics.ps1 -AppServiceName <appname> -ResourceGroup <rgname> -Subscription <subscriptionid>
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-AppServiceName` | Yes | — | App Service name |
| `-ResourceGroup` | Yes | — | Resource group name |
| `-Slot` | No | production | Deployment slot name |
| `-Subscription` | No | current context | Azure subscription ID |
| `-OutputDirectory` | No | current directory | Where to write the report file |

---

### `Get-MySqlFlexibleServerReport.ps1`

Collects configuration details for an Azure Database for MySQL Flexible Server and writes a timestamped Markdown report.

**What the report includes:** server overview and ARM resource view, database inventory, server parameters, firewall rules, Entra admins, replicas, logs, backups, maintenance details, identity data, threat protection state, generated connection string, associated private endpoints, and diagnostic settings.

**Usage:**
```powershell
.\Get-MySqlFlexibleServerReport.ps1 -ServerName <servername> -ResourceGroup <rgname> -Subscription <subscriptionid>
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-ServerName` | Yes | — | MySQL Flexible Server name |
| `-ResourceGroup` | Yes | — | Resource group name |
| `-Subscription` | No | current context | Azure subscription ID |
| `-OutputDirectory` | No | current directory | Where to write the report file |

---

### `Get-MySqlFlexibleServerDatabaseReport.ps1`

Collects configuration details scoped to a single database on an Azure Database for MySQL Flexible Server and writes a timestamped Markdown report.

**What the report includes:** server and database overviews, ARM resource views for both, full database inventory (for context), server parameters (including charset/collation for the target database), firewall rules, Entra admins, replicas, logs, backups, maintenance, identity, threat protection, private endpoints, diagnostic settings, and a generated connection string for the selected database.

**Usage:**
```powershell
.\Get-MySqlFlexibleServerDatabaseReport.ps1 -ServerName <servername> -ResourceGroup <rgname> -DatabaseName <databasename> -Subscription <subscriptionid>
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-ServerName` | Yes | — | MySQL Flexible Server name |
| `-ResourceGroup` | Yes | — | Resource group name |
| `-DatabaseName` | Yes | — | Database name |
| `-Subscription` | No | current context | Azure subscription ID |
| `-OutputDirectory` | No | current directory | Where to write the report file |

---

### `Get-PostgresqlFlexibleServerReport.ps1`

Collects configuration details for an Azure Database for PostgreSQL Flexible Server and writes a timestamped Markdown report.

**What the report includes:** server overview and ARM resource view, database inventory, server parameters, firewall rules, Entra admins, replicas, logs, backups, long-term retention, identity data, generated connection string, private endpoint and private link resource data, and diagnostic settings.

**Usage:**
```powershell
.\Get-PostgresqlFlexibleServerReport.ps1 -ServerName <servername> -ResourceGroup <rgname> -Subscription <subscriptionid>
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-ServerName` | Yes | — | PostgreSQL Flexible Server name |
| `-ResourceGroup` | Yes | — | Resource group name |
| `-Subscription` | No | current context | Azure subscription ID |
| `-OutputDirectory` | No | current directory | Where to write the report file |

---

### `Get-PostgresqlFlexibleServerDatabaseReport.ps1`

Collects configuration details scoped to a single database on an Azure Database for PostgreSQL Flexible Server and writes a timestamped Markdown report.

**What the report includes:** server and database overviews, ARM resource views for both, full database inventory (for context), server parameters (including encoding/collation for the target database), firewall rules, Entra admins, replicas, logs, backups, long-term retention, identity, private endpoint and private link data, diagnostic settings, and generated direct and PgBouncer connection strings for the selected database.

**Usage:**
```powershell
.\Get-PostgresqlFlexibleServerDatabaseReport.ps1 -ServerName <servername> -ResourceGroup <rgname> -DatabaseName <databasename> -Subscription <subscriptionid>
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-ServerName` | Yes | — | PostgreSQL Flexible Server name |
| `-ResourceGroup` | Yes | — | Resource group name |
| `-DatabaseName` | Yes | — | Database name |
| `-Subscription` | No | current context | Azure subscription ID |
| `-OutputDirectory` | No | current directory | Where to write the report file |

---

## Companion Documentation Files

Each `.ps1` script has a matching `.md` file with full usage details, parameter descriptions, and notes:

| Script | Documentation |
|--------|---------------|
| `Get-ResourceGroupReport.ps1` | `Get-ResourceGroupReport.md` |
| `Get-AppServiceReport.ps1` | `Get-AppServiceReport.md` |
| `Get-AppServiceReportDiagnostics.ps1` | `Get-AppServiceReportDiagnostics.md` |
| `Get-MySqlFlexibleServerReport.ps1` | `Get-MySqlFlexibleServerReport.md` |
| `Get-MySqlFlexibleServerDatabaseReport.ps1` | `Get-MySqlFlexibleServerDatabaseReport.md` |
| `Get-PostgresqlFlexibleServerReport.ps1` | `Get-PostgresqlFlexibleServerReport.md` |
| `Get-PostgresqlFlexibleServerDatabaseReport.ps1` | `Get-PostgresqlFlexibleServerDatabaseReport.md` |

## Notes

- All scripts are best-effort. If an Azure CLI call fails because a feature is not configured or the account lacks permission, the report still completes and records the failure in the output Markdown.
- Reports are written as timestamped Markdown files in the `-OutputDirectory` (defaults to the current directory).
- `notes.txt` contains quick-reference example command lines for all scripts.
