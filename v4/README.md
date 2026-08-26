# WordPress on App Service Posture Collection (v4)

`v4` collects redacted configuration evidence for a WordPress workload hosted on Azure Linux App Service. It is intended as input to an Azure Well-Architected review, with emphasis on Security and Reliability.

The collector accepts one resource group, inventories every resource in it, and then captures service-specific evidence for the WordPress topology deployed by the Azure WordPress Bicep sample: App Service Plan, App Service and slots, MySQL Flexible Server, Key Vault, Redis, NAT Gateway, Azure Front Door/WAF, Storage, Azure Communication Services, Application Insights, Log Analytics, and supporting network resources.

## Prerequisites

- PowerShell 7 is recommended.
- Azure CLI must be installed and authenticated with `az login`.
- `Reader` is sufficient for much configuration evidence. Use `Monitoring Reader`, `Security Reader`, and permissions to read Key Vault object metadata when the environment permits it.
- `Pester` is only required for the local tests.

## Run

```powershell
./Invoke-CollectWordPressPosture.ps1 -ResourceGroup <resource-group-name> -OutputDirectory <output-directory>
```

Use a specific subscription or output directory when required:

```powershell
./Invoke-CollectWordPressPosture.ps1 `
  -ResourceGroup <resource-group-name> `
  -Subscription <subscription-id> `
  -OutputDirectory C:\Reports\wordpress-posture
```

## Output

Each resource has its own JSON document. A section records the Azure CLI command, success state, exit code, error, and returned payload. `collection-manifest.json` indexes output files and identifies resources that were inventoried but have no dedicated collector. `resource-group-inventory.json` contains the complete RG inventory, its locks, and resource-group role assignments.

After collection and manifest creation complete, the collector compresses the output directory into a uniquely named ZIP archive beside that directory. The archive name uses the output directory name, a UTC timestamp, and a GUID fragment, for example `wordpress-posture-20260826-120000-20260826T121008636Z-6e1f1f1a.zip`.

The returned object includes `outputDirectory`, `manifest`, `zipFile`, and `discoveredResources`. Capture it to retrieve the archive path:

```powershell
$result = ./Invoke-CollectWordPressPosture.ps1 -ResourceGroup <resource-group-name>
$result.zipFile
```

Sensitive property names and values, including passwords, connection strings, account keys, SAS values, and instrumentation keys, are replaced with `SECRET_FOUND_REDACTED`. The collection intentionally lists Key Vault secret metadata but never reads secret values.

## Assessment Evidence

Security evidence includes public/private network exposure, App Service access restrictions and authentication, managed identities, RBAC, Key Vault access and networking, TLS settings, storage public access and shared-key configuration, Front Door custom domains and WAF policies, MySQL firewall/private access, diagnostic settings, and Defender for Cloud plans and recommendations.

Reliability evidence includes App Service Plan SKU and application placement, slots, App Service configuration and VNet integration, MySQL high availability/backup configuration, Redis configuration, Storage retention/lifecycle configuration, NAT Gateway subnet association, Front Door routing/origins, and Application Insights/Log Analytics availability telemetry.

The evidence model follows the Microsoft cloud security benchmark's feature-driven Azure baselines: network security, logging and threat detection, identity and access management, data protection, secure configuration, and data recovery. Refer to the [Azure security baselines overview](https://learn.microsoft.com/en-us/security/benchmark/azure/security-baselines-overview) during assessment interpretation.

## Limits

The collector preserves failed optional calls as evidence because Azure CLI extensions, resource-provider API versions, and the caller's RBAC permissions vary. Azure CLI output is point-in-time configuration evidence; it does not replace live availability testing, application vulnerability scanning, backup restore testing, WAF attack simulation, or an Azure Policy compliance review.

Run the local validation suite with:

```powershell
Invoke-Pester -Path ./v4/tests -PassThru
```