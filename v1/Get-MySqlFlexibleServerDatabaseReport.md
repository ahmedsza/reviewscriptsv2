# Get-MySqlFlexibleServerDatabaseReport Usage

This script collects broad Azure Database for MySQL Flexible Server metadata for one database by using Azure CLI and writes a timestamped markdown report.

## Prerequisites

- Azure CLI is installed.
- You are signed in with `az login`.
- Your current Azure context, or the optional `-Subscription` parameter, can access the target MySQL Flexible Server and database.
- PowerShell can run local scripts in your environment.

## Run

```powershell
.\Get-MySqlFlexibleServerDatabaseReport.ps1 -ServerName my-mysql-flex-server -ResourceGroup my-resource-group -DatabaseName appdb
```

Optional subscription and output directory:

```powershell
.\Get-MySqlFlexibleServerDatabaseReport.ps1 \
  -ServerName my-mysql-flex-server \
  -ResourceGroup my-resource-group \
  -DatabaseName appdb \
  -Subscription 00000000-0000-0000-0000-000000000000 \
  -OutputDirectory .\reports
```

## What The Report Includes

- Azure account context used for the query
- MySQL Flexible Server overview plus the selected database overview
- Generic ARM resource views for both the server and the selected database
- Database inventory for the server so you can see the target database in context
- Server parameters, targeted charset and collation parameters, firewall rules, Entra admins, replicas, server logs, backups, maintenance details, identity data, threat protection state, private endpoints, and diagnostic settings
- A generated connection string for the selected database
- A collection status table showing any sections that failed or were unavailable

## Notes

- The script uses Azure CLI management-plane commands only. It reports Azure resource metadata for the MySQL server and database.
- It does not inspect schemas, tables, views, stored procedures, indexes, or data inside the database. For that you need data-plane access and credentials, for example through `az mysql flexible-server execute` or a MySQL client.
- Sensitive values are redacted before writing the report.
- In Azure Cloud Shell, a "resource group could not be found" error usually means the shell is on a different active subscription than the one that contains the server. Check `az account show`, list subscriptions with `az account list --output table`, and either switch with `az account set --subscription <id-or-name>` or pass `-Subscription` to the script.