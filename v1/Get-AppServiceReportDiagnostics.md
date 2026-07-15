# Get-AppServiceReportDiagnostics Usage

This script collects App Service Diagnose and Solve Problems data by using the App Service Diagnostics REST API through `az rest`, then writes a timestamped markdown report.

## Prerequisites

- Azure CLI is installed.
- You are signed in with `az login`.
- Your current Azure context, or the optional `-Subscription` parameter, can access the target App Service.
- PowerShell can run local scripts in your environment.

## Run

```powershell
.\Get-AppServiceReportDiagnostics.ps1 -AppServiceName my-app-service -ResourceGroup my-resource-group
```

Optional slot, subscription, and output directory:

```powershell
.\Get-AppServiceReportDiagnostics.ps1 \
  -AppServiceName my-app-service \
  -ResourceGroup my-resource-group \
  -Slot staging \
  -Subscription 00000000-0000-0000-0000-000000000000 \
  -OutputDirectory .\reports
```

## What The Report Includes

- Azure account context and app overview
- Site diagnostic categories from the App Service Diagnostics REST API
- Top-level site detector responses
- Fallback detector grouping derived from detector metadata when the site-level `/diagnostics` endpoint is unavailable
- Per-category detector lists
- Per-category analysis lists
- Individual detector responses and analysis results for the first few entries in each category
- A collection status table showing any sections that failed or were unavailable

## Notes

- The script is best-effort. If some REST calls fail because a detector is unavailable or your account lacks permission, the report still completes and records the failure in the markdown output.
- Some App Services return `404 Not Found` for the documented `/diagnostics` category endpoints while still returning valid data from `/detectors`. In that case the report continues and builds groupings from detector metadata instead of stopping.
- It uses `az rest` against the App Service Diagnostics API version `2025-05-01`.
- The `-MaxDetectorResponsesPerCategory` parameter controls how many individual detector responses and analysis results are expanded per category.
- In Azure Cloud Shell, a "resource group could not be found" error usually means the shell is on a different active subscription than the one that contains the app. Check `az account show`, list subscriptions with `az account list --output table`, and either switch with `az account set --subscription <id-or-name>` or pass `-Subscription` to the script.