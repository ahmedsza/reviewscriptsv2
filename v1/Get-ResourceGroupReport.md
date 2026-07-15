# Get-ResourceGroupReport Usage

This script collects broad Azure resource group details by using Azure CLI and writes a timestamped markdown report.

## Prerequisites

- Azure CLI is installed.
- You are signed in with `az login`.
- Your current Azure context, or the optional `-Subscription` parameter, can access the target resource group.
- PowerShell can run local scripts in your environment.

## Run

```powershell
.\Get-ResourceGroupReport.ps1 -ResourceGroup my-resource-group
```

Optional subscription, output directory, and collection limits:

```powershell
.\Get-ResourceGroupReport.ps1 \
  -ResourceGroup my-resource-group \
  -Subscription 00000000-0000-0000-0000-000000000000 \
  -OutputDirectory .\reports \
  -ActivityLogDays 30 \
  -ActivityLogMaxEvents 200 \
  -MaxDetailedResources 75 \
  -MaxDeploymentOperationGroups 15
```

## What The Report Includes

- Azure account context used for the query
- Resource group overview, tags, provisioning state, and basic metadata
- Full resource inventory for the resource group with summary tables by type, location, and kind
- Locks, deployments, recent deployment operations, role assignments, policy assignments, policy exemptions, policy compliance summary, diagnostic settings, and diagnostic categories
- Recent activity log events and Advisor recommendations for the resource group
- ARM template export for the full resource group
- Per-resource ARM snapshots for up to the configured `-MaxDetailedResources` limit
- A collection status table showing any sections that failed or were unavailable

## Notes

- The script is best-effort. If some Azure CLI calls fail because a feature is not configured, a command is unavailable, or your account lacks permission, the report still completes and records the failure in the markdown output.
- Sensitive values are redacted before writing the report.
- Very large resource groups can produce large markdown files. Lower `-MaxDetailedResources` if you only need the top-level inventory and ARM export.
- In Azure Cloud Shell, a "resource group could not be found" error usually means the shell is on a different active subscription than the one that contains the group. Check `az account show`, list subscriptions with `az account list --output table`, and either switch with `az account set --subscription <id-or-name>` or pass `-Subscription` to the script.