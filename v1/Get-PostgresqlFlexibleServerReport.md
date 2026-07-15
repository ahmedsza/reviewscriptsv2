# Get-PostgresqlFlexibleServerReport Usage

This script collects broad Azure Database for PostgreSQL Flexible Server details by using Azure CLI and writes a timestamped markdown report.

## Prerequisites

- Azure CLI is installed.
- You are signed in with `az login`.
- Your current Azure context, or the optional `-Subscription` parameter, can access the target PostgreSQL Flexible Server.
- PowerShell can run local scripts in your environment.

## Run

```powershell
.\Get-PostgresqlFlexibleServerReport.ps1 -ServerName my-postgres-flex-server -ResourceGroup my-resource-group
```

Optional subscription and output directory:

```powershell
.\Get-PostgresqlFlexibleServerReport.ps1 \
  -ServerName my-postgres-flex-server \
  -ResourceGroup my-resource-group \
  -Subscription 00000000-0000-0000-0000-000000000000 \
  -OutputDirectory .\reports
```

## What The Report Includes

- Azure account context used for the query
- PostgreSQL Flexible Server overview and generic ARM resource view
- Database inventory, server parameters, firewall rules, Entra admins, replicas, logs, backups, long-term retention, and identity data
- Generated connection string output
- Private endpoint connection data, private link resources, and associated private endpoints discovered in the resource group
- Diagnostic settings and diagnostic categories
- A collection status table showing any sections that failed or were unavailable

## Notes

- The script is best-effort. If some Azure CLI calls fail because a feature is not configured or your account lacks permission, the report still completes and records the failure in the markdown output.
- Sensitive values are redacted before writing the report.
- In Azure Cloud Shell, a "resource group could not be found" error usually means the shell is on a different active subscription than the one that contains the server. Check `az account show`, list subscriptions with `az account list --output table`, and either switch with `az account set --subscription <id-or-name>` or pass `-Subscription` to the script.