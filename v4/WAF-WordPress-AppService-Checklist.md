# Azure Well-Architected Framework Review Checklist
## WordPress on Azure App Service

> **Purpose:** Structured checklist for reviewing a WordPress on Azure App Service deployment across all five pillars of the Azure Well-Architected Framework.
>
> **Sources:** [Azure WAF – App Service Web Apps](https://learn.microsoft.com/en-us/azure/well-architected/service-guides/app-service-web-apps) | [WordPress on App Service Overview](https://learn.microsoft.com/en-us/azure/app-service/overview-wordpress) | [App Service Security Baseline](https://learn.microsoft.com/en-us/security/benchmark/azure/baselines/app-service-security-baseline)

---

## 1. Reliability

_Ensure the WordPress site remains available and can recover from failures._

### App Service Plan & Compute

| # | Check Item | Status |
|---|-----------|--------|
| 1.1 | App Service Plan is running on **Premium v3** (or higher) tier for production workloads | ☐ |
| 1.2 | **Multiple instances** are provisioned (minimum 2, ideally 3+) — no single point of failure | ☐ |
| 1.3 | **Zone redundancy** is enabled on the App Service Plan (requires 3+ instances) | ☐ |
| 1.4 | The deployment region supports Availability Zones and this has been verified | ☐ |
| 1.5 | **Always On** is enabled to prevent the app from unloading during idle periods | ☐ |
| 1.6 | **ARR Affinity** (sticky sessions) is disabled to allow even distribution of requests | ☐ |
| 1.7 | Application is **stateless** — session state is stored externally (database, Redis, etc.) | ☐ |

### Health & Auto-Healing

| # | Check Item | Status |
|---|-----------|--------|
| 1.8 | **Health Check** is enabled with a meaningful endpoint path (e.g., `/wp-login.php` or custom health probe) that validates database + cache connectivity | ☐ |
| 1.9 | **Auto-heal rules** are configured for conditions like slow requests, memory limits, HTTP error thresholds | ☐ |
| 1.10 | App Service **Diagnostics / Resiliency Score** report has been reviewed and recommendations acted on | ☐ |

### Scaling

| # | Check Item | Status |
|---|-----------|--------|
| 1.11 | **Autoscaling** rules are defined (CPU, memory, HTTP queue length triggers) | ☐ |
| 1.12 | Minimum and maximum instance counts are set based on capacity planning | ☐ |
| 1.13 | Autoscale rules have been **load-tested** to confirm they trigger correctly | ☐ |
| 1.14 | Application **warm-up** (Application Initialization) is configured so new instances serve traffic only when ready | ☐ |

### Backup & Disaster Recovery

| # | Check Item | Status |
|---|-----------|--------|
| 1.15 | **Azure Database for MySQL Flexible Server** backups are configured using native MySQL backup capabilities (not App Service backup for linked databases — deprecated) | ☐ |
| 1.16 | Database **geo-redundant backup** is enabled if cross-region DR is required | ☐ |
| 1.17 | WordPress file system content (themes, plugins, uploads) backup strategy is documented and tested | ☐ |
| 1.18 | **Recovery Time Objective (RTO)** and **Recovery Point Objective (RPO)** are defined and tested | ☐ |
| 1.19 | Multi-region deployment with **Azure Front Door** or **Traffic Manager** is evaluated for mission-critical workloads | ☐ |
| 1.20 | Failover and recovery procedures are **documented and rehearsed** | ☐ |

### Resiliency Patterns

| # | Check Item | Status |
|---|-----------|--------|
| 1.21 | **Retry pattern** is applied for transient failures (database, external API calls) | ☐ |
| 1.22 | **Circuit Breaker pattern** is implemented where external dependencies are consumed | ☐ |
| 1.23 | **Queue-Based Load Leveling** is considered for asynchronous workloads (e.g., email, image processing) | ☐ |

---

## 2. Security

_Protect the WordPress site and its data against threats._

### Identity & Access Management

| # | Check Item | Status |
|---|-----------|--------|
| 2.1 | **Managed Identity** is enabled for the App Service (system-assigned or user-assigned) | ☐ |
| 2.2 | Managed Identity is used to access **Azure Database for MySQL**, **Key Vault**, **Blob Storage**, and other dependent services | ☐ |
| 2.3 | **Basic authentication** (publish profile credentials / FTP credentials) is disabled | ☐ |
| 2.4 | **SCM site** (Kudu) authentication uses Microsoft Entra ID, not basic auth | ☐ |
| 2.5 | WordPress admin accounts use **strong passwords** and MFA is enforced (plugin-level) | ☐ |
| 2.6 | **Role-Based Access Control (RBAC)** is applied at the resource group / App Service level using least-privilege principle | ☐ |
| 2.7 | WordPress **user roles** (Administrator, Editor, Author, etc.) follow least-privilege principles | ☐ |

### Network Security

| # | Check Item | Status |
|---|-----------|--------|
| 2.8 | App Service is integrated with an **Azure Virtual Network** (VNet integration) | ☐ |
| 2.9 | **Private Endpoints** are configured for the MySQL Flexible Server (deployed in VNet by default) | ☐ |
| 2.10 | **Private Endpoints** are configured for Azure Blob Storage | ☐ |
| 2.11 | Public internet access to the database is **disabled** | ☐ |
| 2.12 | **Network Security Groups (NSGs)** are applied to relevant subnets with appropriate rules | ☐ |
| 2.13 | A **Web Application Firewall (WAF)** is deployed in front of the site via Azure Front Door or Application Gateway | ☐ |
| 2.14 | WAF is configured with **OWASP managed rule sets** and WordPress-specific custom rules | ☐ |
| 2.15 | **DDoS Protection** (Standard tier) is evaluated and enabled if required | ☐ |
| 2.16 | Egress traffic from App Service is routed through a **firewall / NVA** to prevent data exfiltration | ☐ |
| 2.17 | **Access restrictions** on the App Service allow traffic only from the WAF / Front Door (via service tags or IP restrictions) | ☐ |

### Encryption & Certificates

| # | Check Item | Status |
|---|-----------|--------|
| 2.18 | **HTTPS Only** is enforced (HTTP → HTTPS redirect) | ☐ |
| 2.19 | **Minimum TLS version** is set to **1.2** (or higher) | ☐ |
| 2.20 | **End-to-end TLS** is enabled (Premium plans support this between Front Door/AppGW and the app) | ☐ |
| 2.21 | Custom domain is configured with a valid **TLS certificate** (App Service Managed Certificate or Key Vault-backed) | ☐ |
| 2.22 | **Customer-managed keys (CMK)** are evaluated for data-at-rest encryption where compliance requires it | ☐ |
| 2.23 | MySQL Flexible Server has **encryption at rest** enabled (Azure-managed or customer-managed keys) | ☐ |
| 2.24 | Azure Blob Storage encryption is verified | ☐ |

### Application Hardening

| # | Check Item | Status |
|---|-----------|--------|
| 2.25 | **Remote debugging** is disabled | ☐ |
| 2.26 | **FTP** access is disabled (FTPS only or disabled entirely) | ☐ |
| 2.27 | **CORS policies** are restrictive and only allow intended domains | ☐ |
| 2.28 | WordPress core, themes, and plugins are **kept up-to-date** | ☐ |
| 2.29 | Unused/unnecessary plugins and themes are **removed** | ☐ |
| 2.30 | WordPress **file editing** via Dashboard is disabled (`DISALLOW_FILE_EDIT`) | ☐ |
| 2.31 | `wp-config.php` secrets are stored in **Azure Key Vault** and referenced via App Settings | ☐ |
| 2.32 | **phpMyAdmin** access is restricted (IP-restricted or disabled in production) | ☐ |
| 2.33 | `xmlrpc.php` is blocked or restricted unless explicitly required | ☐ |
| 2.34 | WordPress **security headers** are configured (CSP, X-Frame-Options, X-Content-Type-Options, HSTS) | ☐ |

### Monitoring & Threat Protection

| # | Check Item | Status |
|---|-----------|--------|
| 2.35 | **Microsoft Defender for Cloud** is enabled for the App Service Plan | ☐ |
| 2.36 | **Microsoft Defender for Cloud** is enabled for the MySQL Flexible Server | ☐ |
| 2.37 | **Resource logs** are enabled and forwarded to Log Analytics / SIEM | ☐ |
| 2.38 | **Azure Policy** is applied to enforce security baselines (e.g., HTTPS-only, disable basic auth, VNet integration) | ☐ |

---

## 3. Cost Optimization

_Ensure cost-efficiency without compromising quality or reliability._

### SKU & Tier Selection

| # | Check Item | Status |
|---|-----------|--------|
| 3.1 | App Service Plan SKU is **right-sized** for observed workload (not over-provisioned) | ☐ |
| 3.2 | MySQL Flexible Server SKU tier (Burstable / General Purpose / Business Critical) matches actual workload patterns | ☐ |
| 3.3 | **Dev/Test pricing** (or Free/Basic tiers) is used for non-production environments | ☐ |
| 3.4 | Pre-production environments are **ephemeral** and torn down when not in use | ☐ |

### Reservations & Savings

| # | Check Item | Status |
|---|-----------|--------|
| 3.5 | **Azure Reservations** (1- or 3-year) are evaluated for stable production workloads (App Service, MySQL) | ☐ |
| 3.6 | **Azure Savings Plans** for compute are evaluated | ☐ |
| 3.7 | **Azure Hybrid Benefit** applicability has been checked | ☐ |

### Scaling & Resource Utilization

| # | Check Item | Status |
|---|-----------|--------|
| 3.8 | Autoscale **scale-in rules** are configured to avoid idle over-provisioned instances | ☐ |
| 3.9 | Azure Blob Storage **access tiers** (Hot/Cool/Archive) are configured correctly for media assets lifecycle | ☐ |
| 3.10 | **Log retention policies** are defined to avoid unlimited log storage costs | ☐ |
| 3.11 | Azure Front Door / CDN costs are monitored and justified by performance improvements | ☐ |

### Monitoring & Governance

| # | Check Item | Status |
|---|-----------|--------|
| 3.12 | **Azure Cost Management** budgets and alerts are configured for the resource group | ☐ |
| 3.13 | **Cost analysis** is reviewed regularly to identify spending anomalies | ☐ |
| 3.14 | **Tags** are applied to all resources for cost attribution and reporting | ☐ |

---

## 4. Operational Excellence

_Ensure smooth operations, deployments, and monitoring._

### Deployment & Release Management

| # | Check Item | Status |
|---|-----------|--------|
| 4.1 | **Deployment slots** (staging) are used — changes are validated before swapping to production | ☐ |
| 4.2 | **Swap with preview** (multi-phase swap) is used to validate staging against production settings | ☐ |
| 4.3 | A **CI/CD pipeline** (GitHub Actions or Azure Pipelines) automates deployments | ☐ |
| 4.4 | Deployments are **immutable** — container images or packaged deployments are versioned | ☐ |
| 4.5 | **Infrastructure as Code (IaC)** (Bicep/Terraform/ARM) is used for all Azure resource provisioning | ☐ |
| 4.6 | Rollback procedures are documented and tested (slot swap back, previous container image) | ☐ |

### Environment Management

| # | Check Item | Status |
|---|-----------|--------|
| 4.7 | **Separate App Service Plans** are used for production vs. pre-production | ☐ |
| 4.8 | Production environment is **not modified directly** — all changes flow through IaC/CI-CD | ☐ |
| 4.9 | WordPress **automatic updates** are managed and tested in staging before production | ☐ |
| 4.10 | PHP runtime version is current and supported per [App Service language support policy](https://learn.microsoft.com/en-us/azure/app-service/language-support-policy) | ☐ |

### Monitoring & Diagnostics

| # | Check Item | Status |
|---|-----------|--------|
| 4.11 | **Application Insights** is enabled for application performance monitoring (APM) | ☐ |
| 4.12 | **App Service diagnostic logs** are enabled (application logs, web server logs, detailed error messages) | ☐ |
| 4.13 | **Azure Monitor** alerts are configured for key metrics (HTTP 5xx errors, response time, CPU %, memory %) | ☐ |
| 4.14 | **MySQL Flexible Server** monitoring is enabled (slow query log, audit log, metrics) | ☐ |
| 4.15 | Log data flows to a **centralized Log Analytics workspace** | ☐ |
| 4.16 | **Dashboards / Workbooks** are created for operational visibility | ☐ |
| 4.17 | **Diagnostic settings** are configured for all relevant resources (App Service, MySQL, Blob Storage, Front Door) | ☐ |

### Certificate Management

| # | Check Item | Status |
|---|-----------|--------|
| 4.18 | TLS certificates are managed via **App Service Managed Certificates** or **Key Vault** with auto-renewal | ☐ |
| 4.19 | Certificate expiry monitoring and alerting is in place | ☐ |

### Incident Response

| # | Check Item | Status |
|---|-----------|--------|
| 4.20 | **Runbooks** exist for common operational procedures (restart, scale, failover, DB restore) | ☐ |
| 4.21 | An **incident response plan** is documented covering WordPress-specific failure scenarios | ☐ |

---

## 5. Performance Efficiency

_Ensure the WordPress site delivers optimal user experience under expected and peak load._

### Caching Strategy

| # | Check Item | Status |
|---|-----------|--------|
| 5.1 | **Azure Front Door / CDN** is configured for static content caching (CSS, JS, images) | ☐ |
| 5.2 | **Azure Blob Storage** is used to offload media/uploads from the App Service file system | ☐ |
| 5.3 | WordPress **object caching** plugin is configured (e.g., Redis Object Cache with Azure Cache for Redis) | ☐ |
| 5.4 | WordPress **page caching** plugin is implemented and configured | ☐ |
| 5.5 | Browser caching headers (Cache-Control, Expires) are configured in NGINX | ☐ |
| 5.6 | **OPcache** is enabled and tuned for PHP | ☐ |

### Database Performance

| # | Check Item | Status |
|---|-----------|--------|
| 5.7 | MySQL Flexible Server SKU is appropriately sized (IOPS, compute, memory) | ☐ |
| 5.8 | **Slow query log** is enabled and queries are optimized | ☐ |
| 5.9 | Database **connection pooling** is configured | ☐ |
| 5.10 | WordPress database tables are regularly **optimized** (wp-cron or managed task) | ☐ |
| 5.11 | Database is in the **same region** as the App Service to minimize latency | ☐ |

### Application Performance

| # | Check Item | Status |
|---|-----------|--------|
| 5.12 | **HTTP/2** is enabled on the App Service | ☐ |
| 5.13 | **Gzip/Brotli compression** is enabled in NGINX configuration | ☐ |
| 5.14 | Unnecessary plugins are minimized to reduce PHP execution overhead | ☐ |
| 5.15 | WordPress **cron** (`wp-cron.php`) is disabled and replaced with a real server-side cron (Azure WebJobs or Linux cron) | ☐ |
| 5.16 | Image optimization (compression, lazy loading, WebP format) is implemented | ☐ |
| 5.17 | **NGINX startup script** customizations are documented and tuned for WordPress | ☐ |

### Load Testing & Baselines

| # | Check Item | Status |
|---|-----------|--------|
| 5.18 | **Azure Load Testing** has been used to simulate expected and peak traffic | ☐ |
| 5.19 | Performance **baselines** are established (P50/P95/P99 response times, throughput) | ☐ |
| 5.20 | Performance targets (response time, TTFB) are defined and monitored | ☐ |
| 5.21 | Anti-patterns have been reviewed: **Busy Front End**, **No Caching**, **Noisy Neighbor** | ☐ |

### Content Delivery

| # | Check Item | Status |
|---|-----------|--------|
| 5.22 | Azure Front Door **dynamic site acceleration** is enabled for non-cacheable content | ☐ |
| 5.23 | CDN **POP locations** are aligned with target audience geography | ☐ |
| 5.24 | **Cache invalidation** strategy is documented for content updates | ☐ |

---

## 6. WordPress-Specific Cross-Cutting Concerns

_Items unique to the WordPress on App Service offering that span multiple pillars._

### WordPress Platform Configuration

| # | Check Item | Status |
|---|-----------|--------|
| 6.1 | WordPress **application settings** in App Service are correctly configured (DATABASE_HOST, DATABASE_NAME, etc.) | ☐ |
| 6.2 | **WordPress salts and keys** are unique and stored securely (Key Vault references) | ☐ |
| 6.3 | **WP_DEBUG** is disabled in production | ☐ |
| 6.4 | WordPress **multisite** configuration (if used) is correctly configured with domain mapping | ☐ |
| 6.5 | **Email delivery** uses Azure Communication Services or an external SMTP relay (not local sendmail) | ☐ |

### Plugin & Theme Governance

| # | Check Item | Status |
|---|-----------|--------|
| 6.6 | A governance policy exists for **approved plugins and themes** | ☐ |
| 6.7 | All plugins and themes are sourced from **trusted repositories** | ☐ |
| 6.8 | Plugin/theme updates are tested in staging before production deployment | ☐ |
| 6.9 | A **vulnerability scanning** process exists for installed plugins and themes | ☐ |

### Compliance & Data Protection

| # | Check Item | Status |
|---|-----------|--------|
| 6.10 | **Data residency** requirements are met (region selection for App Service, MySQL, Blob Storage) | ☐ |
| 6.11 | **GDPR / POPIA / regulatory** compliance requirements are addressed (cookie consent, data retention, right to erasure) | ☐ |
| 6.12 | **Personally Identifiable Information (PII)** handling in WordPress forms/comments is reviewed | ☐ |
| 6.13 | Database and storage account **diagnostic data** does not leak PII into logs | ☐ |

---

## Summary Scoring Template

| WAF Pillar | Total Checks | Passed | Failed | N/A | Score % |
|---|---|---|---|---|---|
| **1. Reliability** | 23 | | | | |
| **2. Security** | 38 | | | | |
| **3. Cost Optimization** | 14 | | | | |
| **4. Operational Excellence** | 21 | | | | |
| **5. Performance Efficiency** | 24 | | | | |
| **6. WordPress Cross-Cutting** | 13 | | | | |
| **TOTAL** | **133** | | | | |

---

> **Key References:**
> - [WordPress on App Service Overview](https://learn.microsoft.com/en-us/azure/app-service/overview-wordpress)
> - [WAF – App Service Web Apps Service Guide](https://learn.microsoft.com/en-us/azure/well-architected/service-guides/app-service-web-apps)
> - [App Service Security Baseline](https://learn.microsoft.com/en-us/security/benchmark/azure/baselines/app-service-security-baseline)
> - [App Service Baseline Architecture](https://learn.microsoft.com/en-us/azure/architecture/web-apps/app-service/architectures/baseline-zone-redundant)
> - [Mission-Critical App Service](https://learn.microsoft.com/en-us/azure/architecture/guide/networking/global-web-applications/mission-critical-app-service)
> - [App Service Networking Features](https://learn.microsoft.com/en-us/azure/app-service/networking-features)
> - [Azure Database for MySQL Flexible Server](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/)
