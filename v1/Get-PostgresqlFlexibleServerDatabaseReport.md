# Get-PostgresqlFlexibleServerDatabaseReport Usage

This script collects broad Azure Database for PostgreSQL Flexible Server metadata for one database by using Azure CLI and writes a timestamped markdown report.

## Prerequisites

- Azure CLI is installed.
- You are signed in with `az login`.
- Your current Azure context, or the optional `-Subscription` parameter, can access the target PostgreSQL Flexible Server and database.
- PowerShell can run local scripts in your environment.

## Run

```powershell
.\Get-PostgresqlFlexibleServerDatabaseReport.ps1 -ServerName my-postgres-flex-server -ResourceGroup my-resource-group -DatabaseName appdb
```

Optional subscription and output directory:

```powershell
.\Get-PostgresqlFlexibleServerDatabaseReport.ps1 \
  -ServerName my-postgres-flex-server \
  -ResourceGroup my-resource-group \
  -DatabaseName appdb \
  -Subscription 00000000-0000-0000-0000-000000000000 \
  -OutputDirectory .\reports
```

## What The Report Includes

- Azure account context used for the query
- PostgreSQL Flexible Server overview plus the selected database overview
- Generic ARM resource views for both the server and the selected database
- Database inventory for the server so you can see the target database in context
- Server parameters, targeted encoding and collation parameters, firewall rules, Entra admins, replicas, server logs, backups, long-term retention, identity data, private endpoint data, private link resources, and diagnostic settings
- Generated direct and PgBouncer connection strings for the selected database
- A collection status table showing any sections that failed or were unavailable

## Notes

- The script uses Azure CLI management-plane commands only. It reports Azure resource metadata for the PostgreSQL server and database.
- It does not inspect schemas, tables, views, functions, indexes, or data inside the database. For that you need data-plane access and credentials, for example through `psql` or another PostgreSQL client.
- Sensitive values are redacted before writing the report.
- In Azure Cloud Shell, a "resource group could not be found" error usually means the shell is on a different active subscription than the one that contains the server. Check `az account show`, list subscriptions with `az account list --output table`, and either switch with `az account set --subscription <id-or-name>` or pass `-Subscription` to the script.