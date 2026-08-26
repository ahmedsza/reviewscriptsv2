# Azure Environment Review Checklist

This checklist is for the WordPress on Azure App Service environment collected by the v4 scripts. It combines the five Azure Well-Architected Framework pillars with the Microsoft cloud security benchmark (MCSB), Azure service security guidance, Microsoft Defender for Cloud, and Azure Advisor.

The checklist is a review aid, not a substitute for workload requirements, threat modeling, live testing, or Microsoft documentation. Validate every item against the workload's business impact, service-level objectives (SLOs), recovery objectives, compliance obligations, data classification, and regional feature support.

## How to use this checklist

1. Record `Pass`, `Fail`, `N/A`, or `Not verified` for every item. A blank checkbox means the item has not been assessed.
2. Do not mark an item `N/A` without a documented reason and approver.
3. Attach evidence from the v4 JSON output, Azure Policy, Defender for Cloud, Azure Advisor, Azure Monitor, deployment code, tests, or an operational record.
4. Treat a collector failure as `Not verified`, not as evidence that the control is absent or unnecessary.
5. Create a remediation item for every `Fail`, including owner, severity, due date, compensating control, and acceptance criteria.
6. Reassess after material architecture changes and on a regular schedule. Security posture and cost/performance behavior change over time.

**Categories used below**

- **Security**: confidentiality, integrity, identity, network protection, data protection, detection, and response.
- **Resiliency**: availability, redundancy, backup, recovery, fault handling, and continuity.
- **Performance**: capacity, latency, throughput, scaling, efficiency, and load behavior.
- **Cost management**: cost allocation, right-sizing, commitment, retention, waste removal, and financial controls.
- **Operational practices**: observability, deployment safety, governance, automation, testing, incident response, and maintenance.

## 1. Workload and subscription foundations

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Operational practices | [ ] | Define workload owner, service owner, technical owner, security owner, data owner, and 24x7 escalation contacts. | Shared resources with no accountable owner or stale contact details. | Ownership register, tags, support rota. |
| Operational practices | [ ] | Document critical user and system flows, dependencies, regions, data flows, trust boundaries, and failure modes. | Reviewing isolated resources without understanding end-to-end flows. | Architecture/data-flow diagrams and dependency map. |
| Resiliency | [ ] | Define measurable SLOs/SLIs plus RTO and RPO for the workload and each stateful dependency. | Selecting redundancy and backup settings without business recovery targets. | SLO, RTO/RPO, business impact analysis. |
| Resiliency | [ ] | Test zone, regional, dependency, deployment, identity, DNS, and network failure scenarios at an agreed cadence. | Assuming an Azure SLA proves the application will recover. | Game-day records, failover tests, restore reports. |
| Security | [ ] | Maintain a current threat model covering internet edge, origin bypass, supply chain, identities, secrets, database, storage, admin paths, and data exfiltration. | Treating WAF, private endpoints, or Defender plans as a replacement for threat modeling. | Threat model and remediation backlog. |
| Security | [ ] | Classify data and map retention, residency, encryption, access, deletion, and recovery requirements to each data store and log. | Applying one control level to all data or retaining sensitive data indefinitely. | Data inventory and classification policy. |
| Security | [ ] | Use separate production and nonproduction subscriptions/resource groups where blast-radius, policy, identity, or billing isolation requires it. | Mixing production and test data, identities, or resources without explicit controls. | Subscription/resource-group design. |
| Security | [ ] | Use Microsoft Entra identities, managed identities, least-privilege Azure RBAC, PIM/JIT elevation, MFA, Conditional Access, and access reviews. | Standing Owner access, shared administrator accounts, broad custom roles, or credentials in code/settings. | Role assignments, PIM and access-review records. |
| Security | [ ] | Separate control-plane and data-plane duties; tightly restrict subscription Owner, User Access Administrator, Key Vault purge, and data-owner roles. | Giving deployment identities unrestricted data access or allowing one person to delete and purge protected data. | RBAC exports and segregation-of-duties matrix. |
| Security | [ ] | Assign the current GA Microsoft cloud security benchmark in Defender for Cloud and use Azure Policy guardrails for mandatory controls. Evaluate preview standards separately before production enforcement. | Relying only on manual reviews, or enforcing preview controls without change/risk review. | Defender regulatory compliance and policy assignments. |
| Security | [ ] | Review Defender for Cloud recommendations by attack path, internet exposure, data sensitivity, severity, and affected resources; remediate or formally exempt with expiry. | Chasing secure-score percentage alone or using permanent blanket exemptions. | Recommendations, attack paths, exemptions, secure-score trend. |
| Security | [ ] | Enable the Defender CSPM and workload protection plans justified by the architecture and risk, including relevant App Service, database, Storage, Key Vault, Resource Manager, and DNS protections. Verify coverage and agentless/configuration prerequisites. | Enabling plans without monitoring alerts, or disabling plans solely to reduce spend without risk acceptance. | Defender plan pricing/coverage and environment settings. |
| Security | [ ] | Route Defender for Cloud security alerts to a monitored process/SIEM, assign owners, and test triage and response. | Leaving high-severity alerts unassigned or assuming portal visibility is incident response. | Workflow automation, alert routing, incident exercise. |
| Security | [ ] | Review regulatory standards applicable to the organization and track control evidence and exceptions. | Treating MCSB compliance as proof of regulatory compliance. | Defender compliance dashboard and compliance register. |
| Security | [ ] | Require diagnostic logs for security-relevant control and data planes and protect logs from unauthorized alteration or deletion. | Collecting only platform metrics or allowing workload admins to erase audit evidence. | Diagnostic settings, workspace RBAC/retention/immutability. |
| Security | [ ] | Scan application code, WordPress core, themes, plugins, containers/packages, and IaC for vulnerabilities and secrets; patch within risk-based SLAs. | Unsupported WordPress/plugins, unreviewed extensions, secrets committed to source, or ignoring transitive dependencies. | SBOM, scan reports, patch SLA. |
| Security | [ ] | Restrict public exposure by default; use private connectivity and explicit ingress/egress controls where requirements justify it. | Public endpoints protected only by obscurity, DNS, or credentials. | Inventory, topology, NSGs, private endpoints, access restrictions. |
| Resiliency | [ ] | Apply resource locks where accidental deletion would violate recovery objectives, while preserving a documented emergency change path. | No locks on critical stateful resources, or locks that block tested recovery automation. | Resource locks and break-glass procedure. |
| Operational practices | [ ] | Deploy with version-controlled IaC and pipelines, policy checks, peer review, environment promotion, and drift detection. | Portal-only production changes, mutable scripts with no review, or configuration drift accepted silently. | Repository, pipeline and drift reports. |
| Operational practices | [ ] | Use safe deployment patterns, health validation, automated rollback, and change correlation in monitoring. | Large in-place releases, no rollback path, or swapping an unhealthy slot into production. | Release pipeline, deployment records, release annotations. |
| Operational practices | [ ] | Define actionable alerts from symptoms and SLO burn, with owners, severity, runbooks, deduplication, and regular test notifications. | Alerting on every metric, alerts with no owner, or dashboards that nobody watches. | Alert rules, action groups, runbooks and test results. |
| Operational practices | [ ] | Track Azure Service Health, Resource Health, planned maintenance, quota, certificate, secret, domain, and retirement events. | Discovering platform retirement, quota, or certificate expiry during an incident. | Service Health alerts and lifecycle register. |
| Operational practices | [ ] | Review Azure Advisor and Defender recommendations regularly; document implementation, deferral, or exemption decisions. | Automatically applying every recommendation without workload context, or ignoring recommendations wholesale. | Review minutes and recommendation backlog. |
| Performance | [ ] | Establish performance budgets and baselines for critical flows; load test at expected peak, growth, and failure-mode traffic. | Scaling by intuition or testing only happy-path average load. | Load-test reports and baseline dashboards. |
| Performance | [ ] | Instrument end-to-end latency, throughput, errors, saturation, dependency timing, queueing, cache behavior, and database performance. | Monitoring CPU alone or optimizing components without tracing critical flows. | Application Insights, metrics, traces and queries. |
| Cost management | [ ] | Use mandatory ownership, workload, environment, cost-center, and lifecycle tags; reconcile untaggable/shared costs. | Untagged resources or tags that are not enforced and maintained. | Azure Policy and Cost Management exports. |
| Cost management | [ ] | Define budgets, forecast thresholds, anomaly alerts, and accountable recipients at subscription/resource-group/workload scope. | Reviewing cost only after invoice close or using a budget with no action owner. | Budgets, alerts and monthly review. |
| Cost management | [ ] | Right-size from measured utilization and business headroom; remove idle/orphaned resources, stale slots, unused public IPs, snapshots, logs, and test services. | Permanent overprovisioning, or aggressive downsizing that violates SLOs. | Advisor, utilization trends and cleanup records. |
| Cost management | [ ] | Evaluate reservations/savings plans only for stable baseline usage and reassess coverage/utilization. | Committing volatile capacity or keeping unused commitments because they are already purchased. | Commitment utilization and coverage reports. |
| Cost management | [ ] | Model normal, peak, failover, security, logging, backup, data transfer, and disaster-recovery costs. | Budgeting only steady-state compute and database list prices. | Pricing model and cost allocation report. |

## 2. App Service plan, web apps, and deployment slots

Applies to `Microsoft.Web/serverfarms`, `Microsoft.Web/sites`, and `Microsoft.Web/sites/slots`.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Use a managed identity for Azure dependencies and Key Vault references for secrets; grant only required data-plane roles. | Passwords, storage keys, database credentials, or connection strings stored directly in app settings. | `identity`, `appSettings`, `connectionStrings`, Key Vault/RBAC evidence. |
| Security | [ ] | Require HTTPS, TLS 1.2 or later, secure FTPS settings, and current platform/runtime versions. | HTTP allowed, legacy TLS, plain FTP, or unsupported PHP/runtime versions. | `config`, custom-domain/TLS configuration. |
| Security | [ ] | Disable basic publishing credentials, SCM basic authentication, remote debugging, and unused deployment endpoints. | Long-lived FTP/Git credentials or remote debugging enabled in production. | App configuration and Azure Policy. |
| Security | [ ] | Use built-in authentication or application authentication where required; enforce strong session/cookie and admin protections for WordPress. | Exposed admin endpoints with password-only controls and no brute-force protection. | `auth`, application configuration and WAF logs. |
| Security | [ ] | Prevent origin bypass. Prefer Front Door Premium Private Link; otherwise restrict App Service ingress to Azure Front Door and validate `X-Azure-FDID`. Restrict the SCM endpoint separately. | Public origin reachable directly around Front Door/WAF, or trusting the header without source restrictions. | `accessRestrictions`, private endpoint and negative bypass test. |
| Security | [ ] | Integrate outbound traffic with the intended VNet and explicitly control DNS, routes, NSGs/firewall, and dependency access. | Assuming VNet integration makes inbound access private or leaving unrestricted internet egress. | `vnetIntegration`, network topology and egress tests. |
| Security | [ ] | Protect nonpublic slots with equivalent authentication, network restrictions, TLS, diagnostics, and secret handling. | A staging slot that bypasses production WAF/authentication or contains production secrets unnecessarily. | Slot `auth`, `accessRestrictions`, settings and diagnostics. |
| Resiliency | [ ] | Run production on at least two instances; use zone redundancy and sufficient zone-spread capacity where supported and required by SLO. | A production app on one worker or a tier that cannot meet availability requirements. | Plan SKU, capacity, zone redundancy and apps list. |
| Resiliency | [ ] | Enable Health Check on a dependency-aware endpoint and exclude unhealthy instances; keep the endpoint fast and access-controlled. | A health endpoint that always returns 200, performs destructive work, or exposes sensitive details. | Health Check config and synthetic test. |
| Resiliency | [ ] | Make the app stateless across instances; store durable state externally and handle session/cache loss. | Local filesystem/session state required for correctness or scale-out. | Architecture, app settings and failure test. |
| Resiliency | [ ] | Configure autoscale with tested minimum, maximum, trigger, cooldown, and headroom; validate subscription and plan limits. | Manual-only scaling, minimum one instance, or thresholds that oscillate under load. | Autoscale settings, load tests and quota review. |
| Resiliency | [ ] | Use deployment slots, warm-up/health validation, slot-specific settings, rollback, and database-compatible releases. | Swapping untested code, leaking slot-specific settings, or deploying irreversible schema changes first. | `slots`, pipeline and swap records. |
| Resiliency | [ ] | Back up and restore application content/configuration when not fully reproducible from source; test whole-workload recovery including WordPress uploads. | Treating App Service platform durability or a deployment slot as a backup. | Backup/restore test and IaC rebuild test. |
| Performance | [ ] | Select plan tier and worker size from CPU, memory, requests, response time, queue, and dependency measurements. | Upsizing to hide inefficient code/database calls or using Burstable-style assumptions for sustained load. | Plan metrics and load-test results. |
| Performance | [ ] | Enable Always On for production tiers and minimize startup/warm-up work. | Cold starts on user traffic or long synchronous initialization. | `config`, deployment timing and traces. |
| Performance | [ ] | Review co-hosted apps for noisy-neighbor and correlated-failure risk; isolate apps with different scaling/security/SLO needs. | Packing unrelated critical apps into one plan only to reduce cost. | Plan `apps`, per-app metrics and ownership. |
| Cost management | [ ] | Consolidate compatible apps where safe, use per-app scaling when appropriate, and remove unused slots/plans. | One mostly idle plan per app or uncontrolled plan sharing that creates reliability risk. | Plan inventory, utilization and cost. |
| Cost management | [ ] | Use lower-cost nonproduction tiers/schedules while preserving production-like validation for critical behavior. | Production-sized dev environments running continuously, or dev tiers used as proof of production reliability. | Environment cost and schedule. |
| Operational practices | [ ] | Enable App Service platform/application/web server logs and diagnostic settings with defined retention; correlate deployments. | Enabling verbose filesystem logging indefinitely or having no logs during incidents. | Diagnostic settings and release annotations. |
| Operational practices | [ ] | Track runtime, OS, WordPress, plugin, theme, and App Service feature retirement; patch through tested pipelines. | Auto-updating production without validation or leaving unsupported components exposed. | Lifecycle register, SBOM and release history. |

## 3. Azure Database for MySQL flexible server

Applies to `Microsoft.DBforMySQL/flexibleServers`.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Disable public network access and use Private Link or private VNet integration with correct private DNS where feasible. | `0.0.0.0`/Allow Azure services, broad internet firewall ranges, or public access used by default. | `show`, `firewallRules`, private endpoint/DNS evidence. |
| Security | [ ] | Require TLS and current secure cipher/protocol settings for every client. | Disabling SSL enforcement to simplify application connectivity. | Server parameters and connection tests. |
| Security | [ ] | Prefer Microsoft Entra authentication and managed identity for applications; restrict local admin usage and rotate any unavoidable credentials. | Shared MySQL admin credentials in app settings or long-lived local users. | Entra configuration, identities and database users. |
| Security | [ ] | Apply least privilege in Azure RBAC and MySQL roles; separate schema migration, application read/write, reporting, and administration identities. | Application connects as server admin or wildcard grants are permanent. | Role assignments and MySQL grant review. |
| Security | [ ] | Enable auditing/diagnostics appropriate to risk and alert on authentication anomalies, privilege changes, firewall changes, and threats. | Logging all data indiscriminately or omitting security events. | Diagnostic settings, server parameters and alerts. |
| Security | [ ] | Use customer-managed keys only where required and operate the Key Vault identity, rotation, availability, and recovery dependencies correctly. | Adding CMK complexity without ownership, rotation tests, or Key Vault recovery controls. | Encryption settings, Key Vault and runbook. |
| Resiliency | [ ] | Enable same-zone or zone-redundant HA according to SLO; prefer zone redundancy for production where region/SKU supports it. | Single-server production with no documented acceptance of zonal failure. | `show` high-availability state and zone placement. |
| Resiliency | [ ] | Set backup retention from RPO/RTO, use geo-redundant backup when regional recovery requires it, and understand creation-time constraints. | Default retention accepted without recovery analysis or assuming HA replaces backup. | Backup configuration and `backups`. |
| Resiliency | [ ] | Perform point-in-time and geo/universal geo-restore exercises; measure RTO and document DNS, firewall, HA, identity, and app reconnection steps. | An untested backup marked compliant because it exists. | Restore exercise and runbook. |
| Resiliency | [ ] | Handle transient database faults with bounded exponential backoff, connection pooling, idempotency, and circuit breaking where appropriate. | Immediate unlimited retries that amplify database overload. | Application policy and fault test. |
| Resiliency | [ ] | Set and test a maintenance window; ensure application reconnects during failover/maintenance. | Maintenance at peak business time or clients that require manual restart after failover. | Maintenance config and failover test. |
| Performance | [ ] | Co-locate app and database where latency and resilience design require it; measure `SELECT 1` network latency and dependency time. | Cross-region synchronous database traffic without an explicit design. | Region/zone inventory and Application Insights dependencies. |
| Performance | [ ] | Monitor CPU, memory, storage, IOPS, connections, slow queries, waits, replication/HA state, and query-store insights; tune queries/indexes before scaling. | Scaling compute as the only response to missing indexes or chatty queries. | Metrics, slow-query/query-store analysis. |
| Performance | [ ] | Select General Purpose or Memory Optimized for predictable production load when Burstable cannot meet sustained requirements. | Burstable production instances with sustained CPU credit exhaustion. | SKU and utilization trend. |
| Performance | [ ] | Size storage and IOPS with headroom and alerts; account for storage auto-grow behavior and inability to shrink directly. | Waiting for storage saturation or overallocating permanently without review. | Storage/IO metrics and capacity plan. |
| Cost management | [ ] | Right-size compute/storage/IOPS from measured demand; use stop/start only for eligible nonproduction workloads. | Stopping a required service or leaving oversized nonproduction servers running. | Utilization, schedule and cost. |
| Cost management | [ ] | Evaluate reserved capacity for stable production usage and account for HA replica cost, backup storage, and cross-region transfer. | Comparing SKUs while excluding HA and backup costs. | Reservation analysis and cost model. |
| Operational practices | [ ] | Pin supported engine versions, review parameter deviations, schedule upgrades, and track end-of-support notices. | Unsupported MySQL versions or undocumented server-parameter changes. | `configurations`, lifecycle and change records. |
| Operational practices | [ ] | Alert on availability, failed connections, resource saturation, storage growth, backup/restore failures, replication/HA events, and certificate/identity issues. | Database incidents detected only through website errors. | Alert rules, runbooks and notification test. |

## 4. Key Vault

Applies to `Microsoft.KeyVault/vaults`.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Use the Azure RBAC permission model, least-privilege built-in roles, managed identities, PIM, and regular access reviews. | Legacy broad access policies, permanent Key Vault Administrator, or app identities with secret-management rights. | `show`, `roleAssignments`, access review. |
| Security | [ ] | Disable public access or restrict network access to approved private endpoints/networks; validate private DNS. | Public firewall default allow or private endpoint configured while public access remains unintentionally usable. | `networkRules`, private endpoints and DNS test. |
| Security | [ ] | Enable purge protection and retain soft-deleted vaults/objects for a period aligned to recovery requirements. | Soft delete without purge protection for critical keys/secrets, or granting broad purge rights. | `show`, policy compliance and role assignments. |
| Security | [ ] | Set expiry and automated rotation policies for keys, secrets, and certificates; alert before expiry and test consumers with new versions. | Nonexpiring credentials, manual rotation with no owner, or consumers pinned forever to obsolete versions. | `keys`, `secrets`, `certificates`, rotation policies and alerts. |
| Security | [ ] | Separate vaults by environment, workload, region, and administrative boundary where blast radius or policy differs. | One organization-wide vault containing unrelated production and development secrets. | Vault inventory and architecture. |
| Security | [ ] | Enable Defender for Key Vault when justified and investigate unusual access, disabled firewall, and suspicious operation alerts. | Paying for protection without alert routing, or suppressing repeated alerts without root-cause analysis. | Defender plans/alerts and response records. |
| Security | [ ] | Enable audit diagnostic logs and protect their destination and retention. | No data-plane audit trail or secrets/values emitted into application logs. | `diagnosticSettings`, Log Analytics queries. |
| Resiliency | [ ] | Design applications for Key Vault throttling/transient faults, cache secrets securely for an appropriate period, and avoid a per-request dependency. | Calling Key Vault repeatedly in hot paths or using an indefinite local secret cache. | Traces, retry/cache design and load test. |
| Resiliency | [ ] | Test vault/object recovery and critical key backup where required; document that recovered vault RBAC and integrations might need recreation. | Assuming soft-delete recovery automatically restores every role assignment/integration. | Recovery exercise and runbook. |
| Performance | [ ] | Monitor request latency, availability, saturation/throttling, and cache behavior; distribute workloads or vaults when limits require it. | Increasing retries during throttling or concentrating unrelated high-volume consumers in one vault. | Metrics and Application Insights dependency data. |
| Cost management | [ ] | Choose Standard versus Premium/HSM-backed keys from compliance and cryptographic requirements; remove expired unused versions after retention review. | Premium/HSM for every secret without a requirement, or destructive cleanup without dependency validation. | SKU, object inventory and cost. |
| Operational practices | [ ] | Automate object lifecycle, ownership metadata, expiry notifications, emergency rotation, and dependent-service validation. | Anonymous secrets named without purpose/owner or emergency rotation improvised during an incident. | Automation, naming standard and runbook test. |

## 5. Azure Managed Redis and Azure Cache for Redis

Applies to `Microsoft.Cache/redisEnterprise` and legacy `Microsoft.Cache/Redis`.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Operational practices | [ ] | Identify every legacy Azure Cache for Redis instance and execute a tested migration plan to Azure Managed Redis before the applicable retirement date. | Creating new legacy caches or waiting until service disablement to migrate. | Resource type/SKU, retirement register and migration test. |
| Security | [ ] | Use private connectivity, disable public access where supported, require TLS, and use Microsoft Entra authentication/managed identity where supported. | Internet-exposed cache, non-TLS port, or access keys embedded in application settings. | `show`, private endpoint, auth and app configuration. |
| Security | [ ] | Restrict management/data access and rotate unavoidable keys; never store sensitive durable records only in cache. | Treating the cache key as low sensitivity or using Redis as an ungoverned system of record. | RBAC, key rotation and data classification. |
| Resiliency | [ ] | Use an HA/zone-redundant configuration appropriate to production SLOs and test planned/unplanned failover. | Basic/non-HA production cache or assuming cache failover is connection-transparent. | SKU, zones and failover test. |
| Resiliency | [ ] | Implement reconnect, bounded exponential retry, timeout, circuit breaker, and graceful cache-miss/fallback behavior. | Retry storms, no timeout, or total application failure whenever cache is unavailable. | Client configuration and fault injection. |
| Resiliency | [ ] | Use persistence only when the recovery model requires it; understand that persistence does not replace an authoritative durable store or DR plan. | Assuming in-memory replication guarantees no data loss. | Persistence config and recovery design. |
| Performance | [ ] | Reuse connections, use an approved client pattern, monitor server load, memory, evictions, cache hit rate, latency, bandwidth, connections, and errors. | A new connection per operation, large blocking commands, unbounded keys, or no eviction monitoring. | Metrics, client config and traces. |
| Performance | [ ] | Keep values appropriately sized, choose an eviction policy deliberately, reserve memory where applicable, and scale before saturation. | Scaling only after server load/memory is already critical or caching very large objects indiscriminately. | Redis config, key sampling and load tests. |
| Cost management | [ ] | Right-size tier/capacity/shards from peak memory and throughput; use lower-cost non-HA Managed Redis only for workloads that accept the risk. | Production HA cost removed without SLO approval or persistent overprovisioning. | SKU, metrics and cost model. |
| Cost management | [ ] | Review persistence storage behavior and retention, including soft-delete cost interactions for legacy cache persistence. | Unexpected storage growth caused by persistence combined with soft delete. | Persistence storage configuration and cost trend. |
| Operational practices | [ ] | Schedule maintenance where supported, track version/retirement notices, alert on saturation/evictions/failover, and maintain a cache-flush/rebuild runbook. | Clearing production cache without impact analysis or treating eviction spikes as normal. | Maintenance config, alerts and runbook. |

## 6. Azure Front Door and Web Application Firewall

Applies to `Microsoft.Cdn/profiles` and Front Door WAF policy resource types.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Use Front Door Standard/Premium rather than classic, and select Premium where managed WAF rules and origin Private Link are required. | Remaining on a retiring classic offering or selecting tier solely on price. | Profile SKU and lifecycle register. |
| Security | [ ] | Associate every production domain/route with the intended WAF policy; tune in Detection, then run production in Prevention mode. | WAF exists but is unassociated, permanently Detection-only, or disabled during troubleshooting and not restored. | `routes`, `securityPolicies`, WAF mode and logs. |
| Security | [ ] | Enable current managed default rule sets, bot protection where supported, targeted rate limits, and justified geo/IP restrictions. | Blanket exclusions, stale rule sets, or rate limits that block shared-proxy users without testing. | WAF policy/rules, logs and test results. |
| Security | [ ] | Keep exclusions narrow by rule, variable, value, route, and duration; review them periodically. | Disabling a complete rule group for one false positive. | WAF exclusions and approval records. |
| Security | [ ] | Require HTTPS, redirect HTTP, enforce minimum TLS 1.2 or later, and automate managed/custom certificate renewal using managed identity for Key Vault. | Expired certificates, HTTP origin/client traffic, or broad Key Vault access for certificate retrieval. | Custom domains, TLS policy, identities and certificate alerts. |
| Security | [ ] | Block origin bypass with Private Link or validated origin controls; permit only the intended Front Door profile and test direct-origin access. | Origin hostname publicly serves the app without WAF. | Origin config, App Service restrictions and negative test. |
| Security | [ ] | Inspect request bodies where required and protect admin/login paths with stronger WAF controls and application authentication. | Excluding `/wp-admin` or login payloads broadly because of false positives. | WAF config/logs and auth design. |
| Resiliency | [ ] | Use multiple healthy origins/regions when SLO requires them; configure priority, weight, latency sensitivity, and failover deliberately. | Multiple origins that depend on the same failure domain or contain unsynchronized state. | `originGroups`, origins, routes and DR test. |
| Resiliency | [ ] | Probe a lightweight dependency-aware health endpoint with correct protocol/host/path and interval; use `HEAD` when appropriate. | Probing `/`, a cached page, or a path that returns 200 while dependencies are failed. | Origin-group probe configuration and failure test. |
| Resiliency | [ ] | Document Front Door as a critical global dependency and evaluate redundant global routing only when mission-critical requirements justify complexity/cost. | Assuming a single global edge service can never fail, or adding an untested second provider. | Dependency analysis and continuity design. |
| Performance | [ ] | Cache only explicitly cache-safe content; design query-string/cache keys and TTLs to avoid leaking personalized/authenticated responses. | Caching cookies, admin pages, private content, or ignoring query strings that change responses. | Route/rules-engine config and cache tests. |
| Performance | [ ] | Enable compression for supported compressible content and use HTTP/2; measure edge hit ratio, origin latency, and total latency. | Compressing already compressed payloads or enabling caching without measuring correctness/hit rate. | Route config, metrics and synthetic tests. |
| Performance | [ ] | Select origin routing and session affinity from application behavior; prefer stateless distribution. | Sticky sessions used to conceal local session state or unhealthy instance behavior. | Origin-group settings and architecture. |
| Cost management | [ ] | Model tier, request, rule, WAF, data-transfer, origin, log-ingestion, and Private Link costs; use caching/compression to reduce origin transfer. | Logging every request indefinitely or enabling expensive features without using their controls. | Cost model, cache metrics and logging retention. |
| Operational practices | [ ] | Enable access, health-probe, and WAF logs; alert on origin health, 4xx/5xx, latency, certificate expiry, blocked/rate-limited traffic, and configuration changes. | WAF logs unavailable during attack investigation or alerts based on raw count without traffic baseline. | `diagnosticSettings`, alerts, workbooks and runbooks. |
| Operational practices | [ ] | Validate WAF and routing changes with synthetic security/function tests and a rollback path. | Editing production WAF exclusions/routing manually without testing or version control. | IaC, pipeline tests and change history. |

## 7. Storage accounts

Applies to `Microsoft.Storage/storageAccounts`.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Disable public network access or use selected networks/private endpoints; verify private DNS and each service endpoint (blob/file/queue/table) used. | Private endpoint for blob while another used storage service remains public unintentionally. | `show`, `networkRules`, private endpoints and DNS tests. |
| Security | [ ] | Disable anonymous blob access and prevent container-level public access. | Public WordPress media or backups exposed without explicit content/risk approval. | `allowBlobPublicAccess`, container access review. |
| Security | [ ] | Prefer Microsoft Entra ID, managed identity, and user-delegation SAS; disallow Shared Key where compatible. | Account keys in app settings or long-lived account SAS tokens with broad permissions. | Account config, app settings and access logs. |
| Security | [ ] | If SAS is unavoidable, use least privilege, short expiry, HTTPS-only, scoped resource, optional IP restriction, stored access policy where applicable, and revocation plan. | Nonexpiring SAS in source code, tickets, logs, or public URLs. | SAS governance and access review; do not collect token values. |
| Security | [ ] | Require secure transfer and minimum TLS 1.2 or later; use modern SMB security where Files is used. | HTTP access or legacy TLS/SMB enabled for obsolete clients without exception. | `show` security settings. |
| Security | [ ] | Use encryption at rest by default and customer-managed keys only when required, with tested Key Vault identity/rotation/recovery. | CMK configured without monitoring Key Vault availability, key expiry, or identity changes. | Encryption settings and Key Vault evidence. |
| Security | [ ] | Separate accounts by environment, sensitivity, workload, and region where trust/policy/blast radius differs. | Production uploads, diagnostics, backups, and dev data all share one account/key boundary. | Storage architecture and inventory. |
| Security | [ ] | Enable Defender for Storage where justified, including relevant malware scanning/sensitive-data features, and route alerts. | Scanning untrusted uploads but taking no action on malicious results, or scanning trusted high-volume data without cost review. | Defender plan/settings, alerts and response flow. |
| Resiliency | [ ] | Select LRS/ZRS/GRS/GZRS/RA variants from zone/regional durability and read-access requirements. | LRS for critical data without risk acceptance or geo-redundancy assumed to prevent malicious deletion. | `show` SKU and recovery requirements. |
| Resiliency | [ ] | Enable the appropriate combination of soft delete, versioning, change feed, point-in-time restore, snapshots, immutability, and container/file recovery. | Geo-replication used as the only ransomware/deletion protection. | `blobService`, data-protection and immutability settings. |
| Resiliency | [ ] | Test object/share restore and, where applicable, account failover/failback; validate application behavior and DNS after failover. | Recovery documented but never executed, or failover performed without understanding possible data loss. | Restore/failover exercise. |
| Performance | [ ] | Choose account type, access tier, partition/key naming, object size, concurrency, and transfer method from workload access patterns. | Hot small-object workloads moved blindly to archive/cool tiers or sequential naming that creates hotspots in applicable services. | Access pattern, metrics and benchmark. |
| Performance | [ ] | Monitor availability, latency, transactions, ingress/egress, throttling, capacity, and server/client errors; use bounded retries. | Unlimited retries on 429/5xx or treating all 4xx as platform failures. | Metrics, alerts and client policy. |
| Cost management | [ ] | Apply lifecycle policies using narrow prefixes/tags and timeframes aligned with retrieval, retention, and deletion requirements. | Very short tiering intervals, broad delete rules, or moving small objects when transaction/rehydration cost exceeds savings. | `managementPolicy`, inventory and cost analysis. |
| Cost management | [ ] | Include operations, retrieval, rehydration, replication, transfer, Defender scanning, logs, snapshots, versions, and soft-deleted data in cost reviews. | Comparing storage tiers using capacity price alone. | Cost analysis and usage metrics. |
| Operational practices | [ ] | Enable diagnostic settings and inventory where needed; alert on availability, throttling, capacity, public-access/config changes, and key/SAS anomalies. | Collecting high-volume data-plane logs with no query, retention, or response use case. | `diagnosticSettings`, alerts and log queries. |

## 8. Virtual networks, NSGs, route tables, private endpoints, and private DNS

Applies to the network topology resource types collected by v4.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Segment subnets by trust, workload, and function; apply least-privilege NSGs to ingress and egress and use service tags deliberately. | Flat VNet, broad `Internet`/`*` allow rules, or relying only on subnet names as controls. | VNet/subnets, NSGs and effective rules. |
| Security | [ ] | Remove default outbound access by using private subnets and explicit egress such as NAT Gateway/firewall where supported. | Untracked, changing default outbound IPs or unrestricted direct internet egress. | Subnet settings, routes and egress test. |
| Security | [ ] | Use Private Link for supported PaaS dependencies when required; approve endpoints explicitly and disable public access after validation. | Automatically approving unknown private endpoints or leaving a public path that bypasses the private design. | Private endpoints/connections and service network settings. |
| Security | [ ] | Control DNS centrally; link private DNS zones only to intended VNets and secure zone/record modification rights. | Ad hoc hosts-file entries, public DNS for private addresses, or broad DNS contributor permissions. | Private DNS zones, links, records and RBAC. |
| Security | [ ] | Inspect and restrict outbound destinations when exfiltration risk requires it; NAT Gateway provides address translation, not layer-7 filtering. | Claiming NAT Gateway alone is an outbound firewall. | Firewall/proxy design, routes and flow logs. |
| Security | [ ] | Enable Network Watcher/flow logging where required and protect logs; validate DDoS Network Protection need for public-IP VNet resources. | Logging without retention/analysis or assuming Front Door protects every public endpoint. | Flow logs, DDoS plan and public-IP inventory. |
| Resiliency | [ ] | Design address space with growth/peering/private-endpoint capacity and avoid overlaps with connected networks. | Nearly exhausted subnets or overlapping ranges discovered during DR/merger connectivity. | IP address management plan and subnet utilization. |
| Resiliency | [ ] | Test private DNS resolution and routing from every client path, including peered VNets, build agents, and on-premises networks. | A private endpoint declared healthy because it resolves only from one VNet. | DNS/routing tests and topology. |
| Resiliency | [ ] | Review custom routes and network virtual appliance dependencies for zone/region failure and asymmetric routing. | A single NVA or incorrect UDR silently blackholes production traffic. | Route tables, effective routes and failover test. |
| Performance | [ ] | Measure network latency, throughput, connection count, DNS time, packet drops, and path changes; keep dependent services appropriately close. | Assuming Azure backbone placement guarantees application latency. | Network Watcher, Connection Monitor and traces. |
| Cost management | [ ] | Review idle private endpoints, public IPs, peering, DNS Resolver, firewall, flow logs, and interregion/egress transfer. | Keeping unused network resources because their individual cost appears small. | Inventory and network cost report. |
| Operational practices | [ ] | Manage network and DNS changes as code with pre/post connectivity tests and rollback. | Manual NSG/UDR/DNS edits during incidents without effective-rule validation. | IaC, pipeline and change records. |

## 9. NAT Gateway

Applies to `Microsoft.Network/natGateways`.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Associate the gateway only with intended private subnets and use predictable public IP prefixes for downstream allowlists. | NAT attached to the wrong subnet or destination allowlists based on undocumented ephemeral addresses. | `show`, `subnetAssociations`, public IP resources. |
| Security | [ ] | Combine with firewall/proxy controls when outbound inspection or destination restriction is required. | Treating NAT Gateway as content inspection or threat prevention. | Topology, UDR and firewall policy. |
| Resiliency | [ ] | Use StandardV2 automatic zone redundancy where supported/appropriate; otherwise understand Standard SKU zonal placement and failure implications. | Calling a zonal Standard gateway zone-redundant. | SKU, zone and regional support. |
| Resiliency | [ ] | Size public IP/SNAT capacity and connection limits; monitor failed/total SNAT connections and datapath availability. | Waiting for intermittent timeouts before assessing port exhaustion. | Metrics, alerts and capacity calculation. |
| Performance | [ ] | Reuse/pool connections, close them correctly, use bounded backoff, and avoid unnecessarily high idle timeouts. | New TCP connection per request, aggressive retries, or long idle connections consuming ports. | Application client settings and connection metrics. |
| Performance | [ ] | Use Private Link/service endpoints for Azure PaaS traffic where appropriate to reduce latency/exposure and free SNAT inventory. | Sending all PaaS traffic through public endpoints and NAT by default. | Dependency endpoints and flow data. |
| Cost management | [ ] | Review gateway hourly/data processing/public IP costs against actual subnet use; remove unattached/idle gateways and IPs. | A dedicated gateway for an idle environment with no egress requirement. | Association, flow/metric and cost data. |
| Operational practices | [ ] | Enable supported flow logs/diagnostics and alert on datapath degradation, failed connections, drops, saturation, and resource health. | No telemetry for intermittent outbound failures. | `diagnosticSettings`, metrics, alerts and runbook. |

## 10. Application Insights and Log Analytics

Applies to `microsoft.insights/components` and `Microsoft.OperationalInsights/workspaces`.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Use workspace-based Application Insights, Microsoft Entra/RBAC, managed identity where supported, and least-privilege query/export access. | Sharing instrumentation/API keys broadly or granting all engineers unrestricted sensitive-log access. | `show`, workspace link and `roleAssignments`. |
| Security | [ ] | Prevent secrets, tokens, credentials, personal data, and unnecessary request bodies/query strings from entering telemetry; apply redaction and access controls. | Treating logs as nonsensitive because they are operational data. | Telemetry schema, sampling/redaction tests and queries. |
| Security | [ ] | Use Azure Monitor Private Link Scope when private ingestion/query is required and configure public access deliberately. | Private application dependencies but unrestricted public monitoring endpoints without review. | Workspace network settings and AMPLS design. |
| Security | [ ] | Separate operational/security workspaces when access, retention, residency, Sentinel billing, or blast-radius requirements differ. | One workspace by habit, or excessive workspace sprawl with no governance. | Workspace strategy and RBAC. |
| Resiliency | [ ] | Create availability tests from multiple relevant locations and alert on user-visible symptoms and critical dependency failure. | Testing only the home page from one location or relying on platform resource health. | Availability tests, action groups and runbooks. |
| Resiliency | [ ] | Define monitoring continuity and export/archive needs; understand regional workspace dependency and data-latency behavior. | Assuming monitoring can never be impaired during the incident it must diagnose. | Monitoring architecture and continuity test. |
| Performance | [ ] | Instrument distributed traces, dependency calls, exceptions, requests, custom business metrics, browser data where justified, and deployment markers. | High-cardinality/noisy telemetry with no critical-flow context, or sampling away all failures. | Application map, traces, telemetry config and release annotations. |
| Performance | [ ] | Use consistent correlation and OpenTelemetry/Application Insights SDK versions; monitor telemetry throttling/drop and ingestion latency. | Mixed correlation schemes or unsupported SDKs that break end-to-end traces. | SDK inventory, telemetry health and trace sample. |
| Cost management | [ ] | Configure sampling and ingestion-time transformations at the source/collection path; use table plans, commitment tiers, summary rules, archive, and retention based on query needs. | Using a daily cap as the primary filter or collecting verbose duplicate telemetry indefinitely. | Workspace tables, DCRs, sampling, pricing and retention. |
| Cost management | [ ] | If a daily cap is used as a last-resort guardrail, alert before and at the cap and investigate spikes; avoid reaching it. | Regularly hitting the cap and becoming blind during peak load or attack. | Cap settings, 90%/cap alerts and usage trend. |
| Cost management | [ ] | Place workspace-based Application Insights and its Log Analytics workspace in the same region where supported and review cross-region ingestion/export. | Accidental cross-region telemetry transfer and latency. | Resource regions and workspace linkage. |
| Operational practices | [ ] | Define a telemetry taxonomy, retention owners, saved queries/workbooks, alert quality review, and dashboard/runbook ownership. | Dashboards without decisions/actions or alerts that remain permanently noisy. | Monitoring standard, workbooks and alert review. |
| Operational practices | [ ] | Monitor workspace health, ingestion volume, query performance, data collection rules, retention changes, and diagnostic-setting drift. | Discovering missing logs only after an incident. | Workspace health alerts and policy compliance. |

## 11. Azure Communication Services

Applies to `Microsoft.Communication/communicationServices` and any connected email/domain resources.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Prefer managed identity/Microsoft Entra for supported operations; protect and rotate access keys/connection strings when keys remain necessary. | Communication Services keys in source code, client-side code, tickets, or unprotected app settings. | `show`, identities, RBAC and secret store. |
| Security | [ ] | Apply least-privilege RBAC and separate application sending identities from resource administrators. | Application identity has Contributor/Owner on the Communication Services resource. | `roleAssignments` and identity design. |
| Security | [ ] | Validate data residency/privacy requirements and obtain consent for communications; minimize message metadata/content retained in logs. | Sending regulated data without residency/consent review or logging full message bodies. | Privacy assessment and logging schema. |
| Security | [ ] | For email, configure and validate sender domains, SPF, DKIM, DMARC, suppression/opt-out handling, and anti-abuse controls. | Using unverified domains, ignoring bounces/complaints, or sending without unsubscribe controls where required. | Domain DNS and deliverability reports. |
| Resiliency | [ ] | Handle throttling and transient errors with bounded retries, idempotency/deduplication, status callbacks, and dead-letter/reconciliation workflow. | Blindly retrying sends and producing duplicate email/SMS. | Client policy, message IDs and failure test. |
| Performance | [ ] | Respect service limits, batch/queue outbound work, and monitor send latency, delivery status, throttling, and failure rates by channel. | Synchronous bulk sending on user request paths or scaling without quota review. | Metrics, queue design and load test. |
| Cost management | [ ] | Budget and alert by channel, destination, volume, phone/domain resources, and failed/retried sends; prevent abuse-driven spend. | No spend guardrail for compromised send credentials or retry storms. | Cost analysis, quotas and anomaly alerts. |
| Operational practices | [ ] | Enable available diagnostics, track delivery/bounce/complaint rates, maintain provider/status escalation, and test key/domain rotation. | Declaring send API success as confirmed delivery. | Diagnostic settings, delivery reports and runbook. |

## 12. Defender for Cloud review

Applies to the subscription-level posture collected by `Get-DefenderForCloudData.ps1`.

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Verify Foundational CSPM/Defender CSPM state, MCSB assignment, secure-score controls, recommendations, attack paths, and governance rules at every in-scope subscription. | Assuming Defender is enabled because the portal opens or because one subscription is covered. | `pricing`, security settings, assessments and compliance. |
| Security | [ ] | Confirm each paid Defender plan maps to present resource types and intended protections; verify subplans/extensions and coverage status. | Paying for irrelevant plans, or believing a top-level plan name guarantees every resource is protected. | `pricing`, plan settings and coverage workbook. |
| Security | [ ] | For App Service, Storage, Key Vault, Resource Manager, DNS, and database protections, validate prerequisites, alert generation, routing, and response ownership. | Enabling a plan but never exercising or triaging its alerts. | Defender settings, sample/tabletop alert and action flow. |
| Security | [ ] | Prioritize recommendations that break attack paths, remove internet exposure, protect identities/secrets/data, and cover high-value resources. | Prioritizing only easy secure-score points while high-risk paths remain open. | Attack-path and risk-prioritized backlog. |
| Security | [ ] | Review recommendation exemptions for scope, justification, compensating controls, owner, expiry, and revalidation. | Permanent subscription-wide exemptions with no expiry. | `exemptions` and exception register. |
| Security | [ ] | Use continuous export/workflow automation/SIEM integration where required and protect exported data. | Security findings retained only in the portal with no case-management path. | Automation/export settings and incident workflow. |
| Cost management | [ ] | Review protected-resource counts, per-resource/per-transaction charges, Defender CSPM benefits, and duplicate third-party tooling. | Disabling high-value detection without risk review or running overlapping tools with no use case. | Defender cost report and control mapping. |
| Operational practices | [ ] | Set governance rules/owners/due dates, review posture trends, and test incident procedures; monitor plan/configuration changes. | A static quarterly screenshot used as the security program. | Governance rules, secure-score trend and review minutes. |

## 13. Cross-service recovery and WordPress-specific validation

| Category | Check | Required best practice | Bad practice to avoid | Evidence |
|---|---|---|---|---|
| Security | [ ] | Restrict WordPress administrator access, enforce MFA where possible, disable unused XML-RPC/application-password features, and protect login/admin endpoints with rate limiting. | Default administrator names, shared admins, unlimited login attempts, or exposed unused remote interfaces. | WordPress config, identity controls and WAF tests. |
| Security | [ ] | Allow only approved, supported plugins/themes; verify provenance, integrity, update ownership, and vulnerability monitoring. | Pirated/abandoned plugins, direct production editing, or writable code directories without need. | Plugin/theme inventory, SBOM and scan results. |
| Security | [ ] | Use least-privilege database credentials and filesystem permissions; protect `wp-config.php`, uploads, backups, and debug output. | Database admin credentials, public backup files, production debug logs, or executable untrusted uploads. | App/filesystem configuration and security test. |
| Resiliency | [ ] | Define a consistent recovery set for database, uploaded media, application/configuration, DNS, certificates, secrets, Front Door/WAF, and network policy. | Restoring the database from one point and uploads from another with no consistency strategy. | Recovery design and end-to-end restore. |
| Resiliency | [ ] | Rebuild an isolated environment from IaC and backups, then validate login, content, media, email, cache, scheduled jobs, and integrations. | Testing only that resources deploy, not that the site and data work. | Full recovery exercise and acceptance test. |
| Performance | [ ] | Validate full-page/object cache behavior, cache invalidation, PHP workers, database queries/indexes, media optimization, CDN cacheability, and scheduled jobs under peak load. | Adding cache layers without invalidation tests or running heavy cron work on user request paths. | Load test, traces, Redis/MySQL metrics and cache headers. |
| Cost management | [ ] | Attribute cost to edge, compute, database, cache, storage, monitoring, security, networking, backup, and communication services; optimize the dominant measured drivers. | Spending effort on minor resources while database/compute/logging dominates cost. | Workload cost allocation and trend. |
| Operational practices | [ ] | Maintain tested runbooks for failed deployment, compromised admin/plugin, origin bypass, WAF false positive, database failover/restore, Redis loss, secret rotation, certificate expiry, and outbound/SNAT failure. | Generic incident plan with no Azure/WordPress commands, owners, or validation steps. | Runbooks and exercise results. |

## 14. Mandatory manual-validation register

The collector cannot prove the following controls from Azure resource configuration alone. Review them manually for every assessment and record the result as `Pass`, `Fail`, `N/A`, or `Not verified`. Where an item is service-specific, record it once per affected resource; use `Workload` only for genuinely workload-wide controls.

| Pillar | Category | Manual review item | Required evidence or test | Why manual review is required |
|---|---|---|---|---|
| Reliability | Resiliency | Confirm business-critical flows, dependencies, SLOs/SLIs, RTOs, RPOs, and accepted downtime/data-loss risks. | Approved business impact analysis, SLO document, dependency map, and risk acceptance. | Azure configuration does not reveal required availability or recovery targets. |
| Reliability | Resiliency | Perform and document restore, failover, and whole-workload recovery exercises for application content/configuration, databases, uploads, secrets, DNS, certificates, edge routing, and network policy. | Dated exercise reports with measured RTO/RPO, defects, owners, and remediation evidence. | Configured backups, redundancy, or soft-delete settings do not prove recovery works. |
| Reliability | Resiliency | Test dependency, identity, DNS, network, zone, regional, and deployment failure scenarios at the agreed cadence. | Game-day/fault-injection records and updated runbooks. | The collector cannot exercise failure paths or application behavior. |
| Security | Security | Maintain and review a current threat model covering internet edge, origin bypass, supply chain, identities, secrets, data stores, administrative paths, and exfiltration. | Threat model, data-flow diagram, risk register, and remediation backlog. | Resource metadata cannot determine threat scenarios or control sufficiency. |
| Security | Security | Verify data classification, residency, privacy, retention, deletion, encryption, and compliance obligations for each data store and log. | Data inventory/classification, retention policy, privacy/compliance assessment, and approved exceptions. | Business and regulatory obligations are outside collector scope. |
| Security | Security | Review Entra, Azure RBAC, PIM/JIT, MFA, Conditional Access, break-glass accounts, service identities, database roles, and access-review outcomes. | RBAC/data-plane role export, PIM settings, access-review records, and segregation-of-duties matrix. | Some data-plane and tenant controls are unavailable or incomplete in the collector output. |
| Security | Security | Verify application, WordPress, plugin/theme, package, container, and IaC vulnerability/secret scanning plus risk-based patching. | SBOM, scan reports, patch records, secret-scanning configuration, and remediation SLAs. | The collector does not inspect source control, build artifacts, or application packages. |
| Security | Security | Exercise secret, certificate, key, and credential rotation, including dependent application validation and emergency access. | Rotation policies, expiry alerts, change records, and successful rotation test. | An expiry setting or Key Vault configuration does not prove consumers can rotate safely. |
| Security | Security | Test direct-origin bypass, WAF enforcement, authentication, authorization, administrator protection, and security-alert response. | Negative security tests, WAF logs, penetration-test results where required, and incident records. | Network and WAF settings do not prove effective end-to-end enforcement. |
| Operational Excellence | Operational practices | Verify all infrastructure, policies, DNS, WAF rules, diagnostics, and application configuration are version-controlled IaC with peer-reviewed deployment pipelines and drift detection. | Repository, pull requests, pipeline definitions/runs, policy checks, and drift reports. | Azure resource state cannot prove reproducible, reviewed delivery practices. |
| Operational Excellence | Operational practices | Verify safe deployment, rollback, health validation, slot/swap procedures, database migration compatibility, and release correlation. | Release records, deployment tests, rollback exercise, and telemetry annotations. | Configuration alone does not show that releases are safely operated. |
| Operational Excellence | Operational practices | Review observability quality: alert ownership, SLO/symptom coverage, action groups, dashboards, retention, runbooks, notification tests, and incident triage. | Alert test results, runbooks, on-call rota, dashboards, and incident postmortems. | Existing alerts and diagnostic settings do not prove they are actionable or monitored. |
| Operational Excellence | Operational practices | Confirm architecture, data-flow, dependency, configuration, naming, tagging, ownership, change, lifecycle, and service-retirement documentation is current. | Version-controlled diagrams, ADRs, configuration baseline, ownership register, and lifecycle register. | Documentation quality and operating ownership are not resource properties. |
| Operational Excellence | Operational practices | Verify unit, integration, end-to-end, security, backup/restore, and operational tests run in CI/CD with defined acceptance criteria. | Test suites, pipeline results, coverage/quality reports, and release gates. | The collector cannot inspect test quality or execution history. |
| Performance Efficiency | Performance | Load, stress, soak, scalability, cache-invalidation, and failure-mode test critical flows at expected peak and growth traffic. | Dated load-test scripts in source control, test reports, baselines, capacity conclusions, and remediation backlog. | SKU and metric snapshots cannot establish behavior under representative demand. |
| Performance Efficiency | Performance | Review end-to-end latency, throughput, saturation, dependency time, database/query efficiency, cache behavior, browser experience, and autoscale behavior against performance budgets. | Application Insights traces, database/cache analysis, synthetic tests, and performance-budget report. | Collector configuration cannot determine user-flow performance or query efficiency. |
| Cost Optimization | Cost management | Validate cost allocation, budgets, forecasts, anomaly alerts, ownership, rightsizing decisions, idle-resource cleanup, and reservation/savings-plan utilization. | Cost Management exports, budget/alert configuration, monthly reviews, utilization trends, and commitment reports. | Resource configuration lacks consumption, organizational ownership, and decision history. |
| Cost Optimization | Cost management | Model normal, peak, failover, security, monitoring, backup, data-transfer, and disaster-recovery costs against the workload's business value. | Cost model, pricing assumptions, architecture decisions, and approved budget. | The collector does not contain workload demand or financial requirements. |

## 15. Review completion record

| Field | Value |
|---|---|
| Workload/environment | |
| Subscription and resource group | |
| Review date | |
| Reviewers | |
| Business owner | |
| Security owner | |
| SLO / RTO / RPO | |
| Data classification | |
| Total Pass / Fail / N/A / Not verified | |
| Critical/high findings | |
| Accepted risks and approver | |
| Remediation backlog link | |
| Next review date | |

## Microsoft source guidance

The links below are the primary Microsoft sources used to construct this checklist. Product behavior, support, retirement dates, policy definitions, and Defender plan capabilities can change; use the live pages during each review.

### Framework and security baseline

- [Azure Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/what-is-well-architected-framework)
- [Azure Well-Architected Framework pillars](https://learn.microsoft.com/azure/well-architected/pillars)
- [Reliability design review checklist](https://learn.microsoft.com/azure/well-architected/reliability/checklist)
- [Security design review checklist](https://learn.microsoft.com/azure/well-architected/security/checklist)
- [Cost Optimization design review checklist](https://learn.microsoft.com/azure/well-architected/cost-optimization/checklist)
- [Operational Excellence design review checklist](https://learn.microsoft.com/azure/well-architected/operational-excellence/checklist)
- [Performance Efficiency design review checklist](https://learn.microsoft.com/azure/well-architected/performance-efficiency/checklist)
- [Introduction to the Microsoft cloud security benchmark](https://learn.microsoft.com/security/benchmark/azure/introduction)
- [Azure security baselines overview](https://learn.microsoft.com/security/benchmark/azure/security-baselines-overview)
- [Security policies and recommendations in Defender for Cloud](https://learn.microsoft.com/azure/defender-for-cloud/security-policy-concept)
- [Microsoft cloud security benchmark in Defender for Cloud](https://learn.microsoft.com/azure/defender-for-cloud/concept-regulatory-compliance)
- [Microsoft Defender for Cloud overview](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-cloud-introduction)

### Service guidance

- [Well-Architected best practices for App Service](https://learn.microsoft.com/azure/well-architected/service-guides/app-service-web-apps)
- [Reliability in Azure App Service](https://learn.microsoft.com/azure/reliability/reliability-app-service)
- [Well-Architected best practices for Azure Database for MySQL](https://learn.microsoft.com/azure/well-architected/service-guides/azure-database-for-mysql)
- [Secure Azure Database for MySQL](https://learn.microsoft.com/azure/mysql/security/security-overview)
- [Azure Database for MySQL performance best practices](https://learn.microsoft.com/azure/mysql/flexible-server/concept-performance-best-practices)
- [Secure Azure Key Vault](https://learn.microsoft.com/azure/key-vault/general/secure-key-vault)
- [Azure Key Vault security baseline](https://learn.microsoft.com/security/benchmark/azure/baselines/key-vault-security-baseline)
- [Azure Cache for Redis retirement FAQ](https://learn.microsoft.com/azure/azure-cache-for-redis/retirement-faq)
- [Azure Cache for Redis connection resilience](https://learn.microsoft.com/azure/azure-cache-for-redis/cache-best-practices-connection)
- [Well-Architected best practices for Azure Front Door](https://learn.microsoft.com/azure/well-architected/service-guides/azure-front-door)
- [Secure Azure Front Door](https://learn.microsoft.com/azure/frontdoor/secure-front-door)
- [Well-Architected best practices for Blob Storage](https://learn.microsoft.com/azure/well-architected/service-guides/azure-blob-storage)
- [Secure an Azure Storage account](https://learn.microsoft.com/azure/storage/common/secure-storage)
- [Azure Storage security baseline](https://learn.microsoft.com/security/benchmark/azure/baselines/storage-security-baseline)
- [Reliability in Azure NAT Gateway](https://learn.microsoft.com/azure/reliability/reliability-nat-gateway)
- [Design virtual networks with NAT Gateway](https://learn.microsoft.com/azure/nat-gateway/nat-gateway-design)
- [Private Endpoint DNS integration](https://learn.microsoft.com/azure/private-link/private-endpoint-dns-integration)
- [Well-Architected best practices for Application Insights](https://learn.microsoft.com/azure/well-architected/service-guides/application-insights)
- [Well-Architected best practices for Log Analytics](https://learn.microsoft.com/azure/well-architected/service-guides/azure-log-analytics)
- [Azure Monitor Logs best practices](https://learn.microsoft.com/azure/azure-monitor/logs/best-practices-logs)
- [Azure Monitor daily cap guidance](https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap)
- [Azure Communication Services security baseline](https://learn.microsoft.com/security/benchmark/azure/baselines/communication-services-security-baseline)