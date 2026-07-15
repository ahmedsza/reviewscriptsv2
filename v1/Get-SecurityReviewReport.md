# Get-SecurityReviewReport.ps1

Collects security configuration data for an Azure App Service and MySQL Flexible Server deployment and produces a Markdown report with automated pass/fail assessments against WAF Security questions at **Priority 1, 2, and 3**.

---

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and authenticated (`az login`)
- Contributor or Reader access to the target resource group
- PowerShell 7.x or Windows PowerShell 5.1

---

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-AppServiceName` | Yes | Name of the App Service web app |
| `-MySqlServerName` | Yes | Name of the MySQL Flexible Server |
| `-ResourceGroup` | Yes | Resource group containing both resources |
| `-OutputDirectory` | No | Directory to write the report file (defaults to current directory) |
| `-Subscription` | No | Azure subscription name or ID (defaults to current az CLI context) |
| `-AfdProfileName` | No | Name of the Azure Front Door profile for WAF checks. Auto-discovered from the resource group if omitted. |
| `-AfdResourceGroup` | No | Resource group containing the AFD profile if different from `-ResourceGroup` |

---

## Usage

```powershell
# Basic usage
.\Get-SecurityReviewReport.ps1 `
    -AppServiceName "my-wordpress-app" `
    -MySqlServerName "my-mysql-server" `
    -ResourceGroup "my-resource-group"

# With explicit subscription and output directory
.\Get-SecurityReviewReport.ps1 `
    -AppServiceName "my-wordpress-app" `
    -MySqlServerName "my-mysql-server" `
    -ResourceGroup "my-resource-group" `
    -Subscription "my-subscription-id" `
    -OutputDirectory "C:\reports"

# With AFD profile in a separate resource group
.\Get-SecurityReviewReport.ps1 `
    -AppServiceName "my-wordpress-app" `
    -MySqlServerName "my-mysql-server" `
    -ResourceGroup "my-resource-group" `
    -AfdProfileName "my-afd-profile" `
    -AfdResourceGroup "my-shared-networking-rg"
```

---

## What the script checks

### SE:01 — Security Baseline and Governance
| Priority | Check | Method |
|---|---|---|
| 3 | Microsoft Defender for App Service enabled | `az security pricing show --name AppServices` |
| 3 | Resources tagged for security classification | `az webapp show` — inspects `.tags` |
| 3 | Azure Policy definitions applied | `az policy assignment list` |
| 3 | Azure Advisor security recommendations reviewed | `az advisor recommendation list --category Security` |
| 3 | MySQL parameter baseline documented | `az mysql flexible-server parameter list` |

### SE:04 — Segmentation and Network Isolation
| Priority | Check | Method |
|---|---|---|
| 1 | Public network access disabled on App Service | `az webapp show` — `.publicNetworkAccess` |
| 3 | VNet Integration configured | `az webapp vnet-integration list` |
| 3 | Private Endpoint for App Service | `az network private-endpoint list` |
| 3 | WAF deployed (AFD or App Gateway) | `az afd profile list` / `az network application-gateway list` |
| 3 | Egress to MySQL over private endpoint | `az mysql flexible-server show` — `.network` |
| 3 | MySQL deployed with private access mode | `az mysql flexible-server show` — `.network.delegatedSubnetResourceId` |
| 3 | No public network access on MySQL | `az mysql flexible-server show` — `.network.publicNetworkAccess` |
| 3 | NSG rules on subnets | **MANUAL** — `az network nsg rule list` collected; cross-reference required |

### SE:05 — Identity and Access Management
| Priority | Check | Method |
|---|---|---|
| 1 | Managed identity assigned to App Service | `az webapp identity show` |
| 2 | Basic auth disabled for SCM | ARM resource `basicPublishingCredentialsPolicies/scm` |
| 2 | Basic auth (local auth) disabled for FTP | ARM resource `basicPublishingCredentialsPolicies/ftp` |
| 2 | Entra ID authentication configured on MySQL | `az mysql flexible-server ad-admin list` |
| 2 | Entra-only auth on MySQL | `az mysql flexible-server show` — `.authConfig` |
| 2 | WordPress authenticates via Entra tokens | **MANUAL** — requires wp-config.php inspection |
| 2 | Conditional Access on MySQL Entra auth | **MANUAL** — requires Microsoft Graph API |
| 3 | RBAC least privilege roles | `az role assignment list` |
| 3 | Dedicated MySQL user accounts per component | **MANUAL** — requires MySQL client query |

### SE:06 — Network Security
| Priority | Check | Method |
|---|---|---|
| 1 | WAF cannot be bypassed (AFD lock) | `az webapp config access-restriction show` — checks for AFD service tag + deny-all |
| 1 | FTP/FTPS access disabled | `az webapp config show` — `.ftpsState` |
| 2 | Remote debugging disabled | `az webapp config show` — `.remoteDebuggingEnabled` |
| 3 | WAF OWASP Top 10 rules configured | `az resource show` on WAF policy — `.managedRules.managedRuleSets` |
| 3 | Bot protection rules enabled | WAF policy — checks for BotManagerRuleSet |
| 3 | WAF in Prevention mode | WAF policy — `.policySettings.mode` |
| 3 | WordPress admin paths restricted via WAF | WAF policy custom rules — checks for wp-admin/wp-login match |
| 3 | CORS restricted to allowed domains | `az webapp cors show` |
| 3 | MySQL firewall rules not 0.0.0.0/255.255.255.255 | `az mysql flexible-server firewall-rule list` |
| 3 | MySQL port 3306 not publicly exposed | Inferred from `publicNetworkAccess` |

### SE:07 — Encryption
| Priority | Check | Method |
|---|---|---|
| 1 | HTTPS only enforced on App Service | `az webapp show` — `.httpsOnly` |
| 1 | SSL/TLS enforced on MySQL (require_secure_transport=ON) | `az mysql flexible-server parameter show --name require_secure_transport` |
| 3 | Minimum TLS 1.2 on App Service | `az webapp config show` — `.minTlsVersion` |
| 3 | Custom domain with valid TLS certificate | `az webapp config hostname list` + `az webapp config ssl list` |
| 3 | tls_version set to TLS 1.2/1.3 on MySQL | `az mysql flexible-server parameter show --name tls_version` |

### SE:08 — Harden Resources and Reduce Attack Surface
| Priority | Check | Method |
|---|---|---|
| 2 | Health Check enabled | `az webapp config show` — `.healthCheckPath` |
| 3 | Premium v3 tier in use | `az appservice plan show` — `.sku.tier` |
| 3 | ARR affinity disabled | `az webapp show` — `.clientAffinityEnabled` |
| 3 | Always On enabled | `az webapp config show` — `.alwaysOn` |
| 3 | WEBSITE_RUN_FROM_PACKAGE=1 | `az webapp config appsettings list` |
| 3 | Deployment slots used | `az webapp deployment slot list` |
| 3 | Latest PHP runtime | `az webapp config show` — `.linuxFxVersion` (MANUAL — requires version verification) |

---

## Report structure

The output Markdown file contains:

1. **Summary table** — key properties for quick orientation
2. **Security Assessment** — grouped by WAF sub-area with PASS / FAIL / UNKNOWN / MANUAL status per question
3. **Raw Data** — full JSON output from every az CLI command for manual follow-up

---

## Limitations / items requiring manual review

The following checks **cannot be fully automated** via az CLI and are flagged as `MANUAL` in the report:

- WordPress application-level Entra token authentication (requires `wp-config.php` inspection)
- Conditional Access policies on Entra authentication (requires Microsoft Graph API)
- Dedicated MySQL user accounts with minimum privileges (requires `mysql` client)
- NSG subnet-to-subnet restriction verification (requires cross-referencing address ranges)
- WAF custom rules for WordPress admin paths when WAF policy is not accessible
- PHP runtime currency (requires comparison against Microsoft's supported runtime list)
