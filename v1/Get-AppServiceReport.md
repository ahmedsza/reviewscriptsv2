# Get-AppServiceReport Usage

This script collects broad Azure App Service and App Service Plan details by using Azure CLI and writes a timestamped markdown report.

## Prerequisites

- Azure CLI is installed.
- You are signed in with `az login`.
- Your current Azure context, or the optional `-Subscription` parameter, can access the target App Service.
- PowerShell can run local scripts in your environment.

## Run

```powershell
.\Get-AppServiceReport.ps1 -AppServiceName my-app-service -ResourceGroup my-resource-group
```

Optional subscription and output directory:

```powershell
.\Get-AppServiceReport.ps1 \
  -AppServiceName my-app-service \
  -ResourceGroup my-resource-group \
  -Subscription 00000000-0000-0000-0000-000000000000 \
  -OutputDirectory .\reports
```

## What The Report Includes

- Azure account context used for the query
- Web app overview and full site configuration
- App settings and connection strings with sensitive values redacted
- Access restrictions, auth settings, identity, logging, backups, storage mounts, hostname bindings, SSL certificates, deployment source, publishing metadata, instances, VNet integration, and deployment slots
- App Service Plan details and plan diagnostic settings when the plan can be resolved from the web app
- Generic ARM resource views and diagnostic categories for both the app and the plan when available
- Per-slot detail for slots that exist
- A collection status table showing any sections that failed or were unavailable

## Notes

- The script is best-effort. If some Azure CLI calls fail because a feature is not configured or your account lacks permission, the report still completes and records the failure in the markdown output.
- Sensitive values are redacted before writing the report.
- In Azure Cloud Shell, a "resource group could not be found" error usually means the shell is on a different active subscription than the one that contains the app. Check `az account show`, list subscriptions with `az account list --output table`, and either switch with `az account set --subscription <id-or-name>` or pass `-Subscription` to the script.