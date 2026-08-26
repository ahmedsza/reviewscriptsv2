# WordPress on Azure App Service Review Checklist

This checklist is the canonical review aid for a WordPress workload hosted on Azure App Service and assessed by the v4 collectors. It consolidates the existing Azure environment and WordPress App Service checklists, the five Azure Well-Architected Framework (WAF) design review checklists, service guidance, security baselines, and the Microsoft reference architecture for WordPress on App Service.

It applies to the workload and its supporting services: App Service plans, web apps and slots, Azure Database for MySQL Flexible Server, Azure Front Door and WAF, Blob Storage, Key Vault, Azure Managed Redis or Azure Cache for Redis, virtual networking, Azure Monitor, and optional Azure Communication Services.

## Review rules

1. Record `Pass`, `Fail`, `N/A`, or `Not verified` for every applicable control. Do not use `N/A` without a documented rationale and approver.
2. A failed collection, unavailable API, or missing evidence means `Not verified`; it does not prove a control is absent.
3. Attach collector output, Azure Policy, Defender for Cloud, Azure Advisor, Azure Monitor, deployment code, tests, or operational records as evidence.
4. Create a remediation item for each `Fail`, with owner, severity, target date, compensating control, and acceptance criteria.
5. Validate the controls against the workload's business impact, SLOs, RTO/RPO, data classification, compliance obligations, and regional feature availability.
6. Reassess after material changes and on an agreed operational cadence.

### Status and evidence key

| Status | Meaning |
|---|---|
| `Pass` | Evidence proves the control is implemented and operated as intended. |
| `Fail` | Evidence proves the control is not met or is ineffective. |
| `N/A` | The control does not apply; the rationale and approver are recorded. |
| `Not verified` | Evidence is unavailable, incomplete, or requires a manual test. |

## 1. Workload foundations and governance

| ID | Review control | Avoid | Evidence | Status |
|---|---|---|---|---|
| FND-01 | Define workload, business, technical, security, data, and 24x7 incident owners. | Shared ownership or stale escalation contacts. | Ownership register, tags, support rota. | [ ] |
| FND-02 | Document critical user and system flows, dependencies, data flows, trust boundaries, regions, and failure modes. | Reviewing isolated Azure resources without the end-to-end workload. | Architecture and data-flow diagrams, dependency map. | [ ] |
| FND-03 | Rate critical flows and define measurable SLOs, SLIs, RTOs, RPOs, and accepted availability and data-loss risks. | Selecting redundancy or backup settings without business targets. | Business impact analysis, SLO and recovery documentation. | [ ] |
| FND-04 | Maintain a current threat model for the internet edge, origin bypass, supply chain, identities, secrets, data stores, admin paths, and exfiltration. | Treating WAF, private endpoints, or Defender as a substitute for threat modeling. | Threat model, risk register, remediation backlog. | [ ] |
| FND-05 | Classify data and map residency, access, encryption, retention, deletion, backup, and recovery requirements to each store and log. | Applying one protection level to all data or retaining sensitive data indefinitely. | Data inventory, classification policy, compliance assessment. | [ ] |
| FND-06 | Separate production and nonproduction resources where blast radius, policy, identity, data, or billing isolation requires it. | Mixing production data and identities with test environments without explicit controls. | Subscription and resource-group design. | [ ] |
| FND-07 | Use least-privilege Azure RBAC, Microsoft Entra ID, MFA, Conditional Access, PIM/JIT, access reviews, and a protected emergency-access path. | Standing Owner access, shared admins, or broad custom roles. | RBAC export, PIM settings, access-review evidence. | [ ] |
| FND-08 | Separate control-plane and data-plane duties, especially for subscription administration, Key Vault purge, and data-owner permissions. | Giving deployment identities unrestricted data or purge access. | Segregation-of-duties matrix and role assignments. | [ ] |
| FND-09 | Apply the current GA Microsoft cloud security benchmark through Defender for Cloud and Azure Policy, with time-bound, documented exceptions. | Manual reviews as the only guardrail or permanent blanket exemptions. | Policy assignments, compliance results, exemption register. | [ ] |
| FND-10 | Review Defender for Cloud and Azure Advisor recommendations by attack path, exposure, business impact, severity, and cost; track decisions. | Chasing secure score alone or automatically applying every recommendation. | Review record, recommendation backlog, approved exceptions. | [ ] |
| FND-11 | Apply resource locks to critical stateful resources without blocking a documented break-glass recovery path. | No deletion protection or locks that prevent recovery automation. | Locks and emergency-change procedure. | [ ] |
| FND-12 | Enforce ownership, workload, environment, cost-center, and lifecycle tags; reconcile untaggable shared costs. | Untagged resources or tags that are not maintained. | Azure Policy, tag inventory, Cost Management export. | [ ] |

## 2. Reliability

This section implements WAF reliability recommendations `RE:01` through `RE:10`.

| ID | Review control | Avoid | Evidence | Status |
|---|---|---|---|---|
| REL-01 | Keep the architecture simple; document and justify every dependency, including Front Door, cache, Key Vault, DNS, and background processing. | Adding components that do not improve a stated business requirement. | Architecture decision records and dependency map. | [ ] |
| REL-02 | Perform failure-mode analysis for critical flows, including zone, region, App Service worker, MySQL, cache, storage, identity, DNS, certificate, Front Door, deployment, and network failures. | Assuming individual Azure SLAs prove workload recovery. | FMA and mitigation backlog. | [ ] |
| REL-03 | Run production on at least two App Service instances; use zone redundancy and sufficient instance count where supported and justified by SLO. | A single-worker production site or a tier incapable of meeting availability targets. | Plan SKU, capacity, zone redundancy, regional capability. | [ ] |
| REL-04 | Enable Always On and use a fast, dependency-aware Health Check endpoint that removes unhealthy instances without disclosing sensitive data. | A health endpoint that always returns 200, is expensive, or performs destructive work. | App Service configuration and synthetic test. | [ ] |
| REL-05 | Make WordPress stateless across workers. Put durable state outside the App Service filesystem and design for cache/session loss. | Local session or uploaded-media state required for correctness after scale-out. | Application design, storage and cache configuration, failure test. | [ ] |
| REL-06 | Configure tested autoscale with minimum, maximum, triggers, cooldowns, quotas, and capacity headroom based on measured or forecast demand. | Manual-only scale-out, a minimum of one for critical production, or oscillating rules. | Autoscale profile, load test, quota review. | [ ] |
| REL-07 | Use warm-up and deployment health validation so a new instance or slot receives production traffic only when ready. | Sending user traffic to a cold or unhealthy worker. | Startup configuration, deployment logs, traces. | [ ] |
| REL-08 | Configure MySQL HA, backup retention, and geo-redundant backup according to RTO/RPO and regional recovery needs. | Assuming HA replaces backup or accepting default retention without analysis. | MySQL HA and backup configuration. | [ ] |
| REL-09 | Define a consistent recovery set for database, uploads/media, application and configuration, secrets, DNS, certificates, Front Door/WAF, and network policy. | Restoring the database and uploads from incompatible points in time. | Recovery design and runbook. | [ ] |
| REL-10 | Test point-in-time restore, application/media restore, cache loss, slot rollback, and, where required, regional recovery; measure achieved RTO/RPO. | Marking a backup compliant solely because it exists. | Dated exercise report and remediation actions. | [ ] |
| REL-11 | Replicate Blob data with an LRS/ZRS/GRS/GZRS/RA option that meets durability and regional recovery requirements. | LRS for critical data without risk acceptance or geo-replication as the only deletion protection. | Storage SKU and recovery requirements. | [ ] |
| REL-12 | Enable data-protection features suitable for WordPress media and backups, such as soft delete, versioning, point-in-time restore, snapshots, or immutability. | Assuming replication protects against accidental or malicious deletion. | Blob service data-protection configuration. | [ ] |
| REL-13 | Configure Front Door origin health probes against a lightweight, dependency-aware endpoint and define deliberate priority, weight, and failover behavior. | Probing `/` or a cached response that hides dependency failure. | Origin-group configuration and failure test. | [ ] |
| REL-14 | Evaluate multi-region App Service, MySQL, storage, and Front Door routing only when required by the workload SLO; test data consistency and failover. | Multiple origins with unsynchronized state or untested failover. | DR architecture, data strategy, game-day record. | [ ] |
| REL-15 | Implement bounded retries, timeouts, idempotency, circuit breaking, and graceful degradation for MySQL, Redis, storage, Key Vault, email, and external APIs. | Unlimited retries or retry storms during dependency failure. | Application configuration, fault-injection tests, traces. | [ ] |
| REL-16 | Queue and control asynchronous work such as email, image processing, and large imports; include dead-letter and reconciliation handling where appropriate. | Running heavy asynchronous work on user request paths. | Queue design, retry policy, operations runbook. | [ ] |
| REL-17 | Monitor availability and reliability indicators for critical flows and dependencies, retain evidence, and use it for post-incident learning. | Resource metrics alone without user-flow health. | Availability tests, SLO dashboard, incident reviews. | [ ] |

## 3. Security

This section implements WAF security recommendations `SE:01` through `SE:12` and the applicable Microsoft cloud security benchmark controls.

| ID | Review control | Avoid | Evidence | Status |
|---|---|---|---|---|
| SEC-01 | Maintain a security baseline aligned to the current Microsoft cloud security benchmark, the App Service security baseline, data classification, and regulatory requirements. | A one-time hardening exercise with no posture remeasurement. | Baseline, policy assignments, Defender compliance. | [ ] |
| SEC-02 | Run secure development practices for WordPress code, themes, plugins, dependencies, containers/packages, and IaC, including secret and vulnerability scanning with risk-based patch SLAs. | Unsupported or unreviewed components, secret-bearing source, or ignored transitive vulnerabilities. | SBOM, scan results, patch records, CI/CD gates. | [ ] |
| SEC-03 | Use managed identities for Azure dependencies where supported, use Key Vault references for secrets, and grant only required data-plane permissions. | Database passwords, storage keys, or long-lived connection strings in app settings. | App identity, Key Vault references, RBAC and application design. | [ ] |
| SEC-04 | Use Microsoft Entra authentication for MySQL where supported and appropriate; otherwise use a dedicated least-privilege MySQL user, store its credential in Key Vault, and test rotation. | Connecting WordPress as MySQL server administrator or using a shared permanent credential. | Entra setup or MySQL grants, Key Vault, rotation test. | [ ] |
| SEC-05 | Disable App Service basic publishing credentials, SCM basic authentication, remote debugging, and unused deployment endpoints; restrict SCM separately. | Long-lived FTP/Git credentials or publicly reachable Kudu administration. | App Service configuration, access restrictions, Azure Policy. | [ ] |
| SEC-06 | Require HTTPS, TLS 1.2 or later, secure FTPS settings or no FTP, and supported PHP and platform versions. | HTTP, legacy TLS, plain FTP, or unsupported runtime versions. | App configuration and runtime inventory. | [ ] |
| SEC-07 | Put Front Door Standard or Premium with WAF in front of the public site; associate the intended WAF policy with every production domain and route and use Prevention mode after tuning. | An unassociated WAF, permanent Detection mode, or disabled protection left unrestored. | Front Door routes, security policies, WAF logs. | [ ] |
| SEC-08 | Use current managed WAF rules, bot protection where supported, targeted rate limits, and narrow, reviewed exclusions. | Disabling an entire rule group or keeping permanent broad exclusions. | WAF policy, exclusions, approvals, test evidence. | [ ] |
| SEC-09 | Prevent origin bypass. Prefer Front Door Premium Private Link; otherwise restrict App Service ingress to Front Door and validate the expected Front Door identifier. | A public origin directly reachable around WAF or trusting a spoofable header without source restrictions. | Private Link or App Service access restrictions and negative bypass test. | [ ] |
| SEC-10 | Restrict WordPress login and administration paths using WAF and application controls; protect exceptions such as required `admin-ajax.php` routes deliberately. | Public password-only administrator access, unlimited login attempts, or blanket `/wp-admin` exclusions. | WAF rules, admin access design, negative tests. | [ ] |
| SEC-11 | Integrate App Service outbound traffic with the intended VNet, DNS, routes, NSGs, and firewall/proxy controls; treat NAT Gateway as address translation, not a firewall. | Assuming VNet integration makes inbound traffic private or leaving uncontrolled egress. | VNet integration, routes, NSGs, firewall, egress test. | [ ] |
| SEC-12 | Use private connectivity and correct private DNS for MySQL, Blob Storage, Key Vault, Redis, and other supporting PaaS services when the risk model requires it; disable public paths after validation. | Private endpoint configured while public access remains unintentionally usable. | Private endpoints, DNS zones, service network settings, connectivity tests. | [ ] |
| SEC-13 | Segment networks and apply least-privilege ingress and egress rules; review effective rules and custom routes. | Flat networks, broad `Internet`/`*` allows, or an untested NVA dependency. | VNet topology, NSGs, effective rules, UDRs. | [ ] |
| SEC-14 | Store WordPress salts, keys, database settings, SMTP credentials, certificates, and other secrets in Key Vault; set expiry, rotation ownership, alerts, and emergency rotation procedures. | Secrets in `wp-config.php`, source control, tickets, logs, or nonexpiring values. | Key Vault inventory, expiration, alerts, rotation test. | [ ] |
| SEC-15 | Harden Key Vault with RBAC, least privilege, purge protection, soft delete, audit diagnostics, and private or restricted network access. | Broad access policies, no purge protection, or unprotected secret audit logs. | Vault configuration, RBAC, diagnostics, private endpoint. | [ ] |
| SEC-16 | Require encryption in transit and at rest for MySQL, Blob Storage, Key Vault, cache, and telemetry; use customer-managed keys only when requirements justify their added operational dependency. | Disabling TLS or deploying CMK without key lifecycle and recovery ownership. | Service encryption settings, Key Vault and recovery design. | [ ] |
| SEC-17 | Disable anonymous Blob access unless explicit public media exposure is approved; use Microsoft Entra ID and managed identity or short-lived least-privilege SAS where possible. | Account keys or nonexpiring broad SAS tokens in settings or URLs. | Storage settings, identity design, SAS governance. | [ ] |
| SEC-18 | Protect WordPress application settings: disable `WP_DEBUG` in production, set `DISALLOW_FILE_EDIT`, remove unused plugins/themes, restrict phpMyAdmin, and block or restrict unused XML-RPC and application-password features. | Dashboard code editing, public backup/debug output, or unused remote interfaces. | WordPress configuration, plugin inventory, WAF and application tests. | [ ] |
| SEC-19 | Apply restrictive CORS, CSP, HSTS, `X-Frame-Options`, and `X-Content-Type-Options` appropriate to the application; validate behavior rather than adding headers blindly. | Overly permissive origins or headers that break legitimate flows and are disabled later. | HTTP-header scan and regression tests. | [ ] |
| SEC-20 | Use least-privilege WordPress roles, individual administrators, strong authentication/MFA where possible, and audited administrator access. | Shared administrator accounts or default administrator names. | WordPress user/role review, identity controls. | [ ] |
| SEC-21 | Enable Defender for Cloud plans justified by deployed services; route Defender security alerts into an owned SIEM or response process and test triage. | Paying for plans without coverage validation or alert ownership. | Defender pricing, coverage, alerts, workflow automation. | [ ] |
| SEC-22 | Enable security-relevant control-plane and data-plane diagnostics, prevent telemetry from collecting secrets or unnecessary PII, and protect the log destination. | No audit trail or sensitive request bodies, tokens, and credentials in logs. | Diagnostic settings, workspace RBAC, redaction tests. | [ ] |
| SEC-23 | Test WAF prevention, direct-origin bypass, authentication, authorization, admin protection, secret rotation, and security-alert response. | Declaring a configured control effective without an end-to-end test. | Security test results, WAF logs, incident exercise. | [ ] |
| SEC-24 | Verify WordPress App Service settings, including database connection settings, unique salts/keys, production debug settings, filesystem permissions, and multisite domain mapping when used. | Default/insecure values, production debugging, or settings copied unreviewed between environments. | App settings, Key Vault references, `wp-config.php` review, multisite tests. | [ ] |

## 4. Cost Optimization

This section implements WAF cost recommendations `CO:01` through `CO:14`.

| ID | Review control | Avoid | Evidence | Status |
|---|---|---|---|---|
| CST-01 | Maintain a workload cost model covering normal, peak, failover, security, monitoring, backup, data transfer, and DR costs, with a documented business-value and availability tradeoff. | Budgeting only steady-state App Service and database list prices. | Cost model and approved budget. | [ ] |
| CST-02 | Create budgets, forecast thresholds, daily cost reviews, anomaly alerts, accountable recipients, and spending guardrails at subscription, resource-group, and workload scope. | Reviewing spend after invoice close or using unowned budget alerts. | Budgets, alerts, cost reports, review minutes. | [ ] |
| CST-03 | Right-size App Service plans from CPU, memory, request, latency, queue, and worker utilization while preserving SLO headroom. | Sustained overprovisioning or downsizing that breaks reliability targets. | Metrics, load tests, Advisor and cost analysis. | [ ] |
| CST-04 | Right-size MySQL compute, storage, IOPS, HA, backup, and cross-region transfer from measured demand; use stop/start only for eligible nonproduction servers. | Ignoring HA/backup costs or stopping a required production dependency. | MySQL metrics, schedule, cost model. | [ ] |
| CST-05 | Use autoscale scale-in and planned nonproduction schedules, and remove idle App Service plans, slots, public IPs, private endpoints, caches, test services, snapshots, and logs. | Production-sized dev environments operating continuously. | Inventory, schedules, utilization and cleanup record. | [ ] |
| CST-06 | Evaluate reservations, savings plans, enterprise agreements, and license benefits for stable baseline use; monitor commitment utilization and coverage. | Committing volatile demand or retaining unused commitments. | Reservation analysis and utilization report. | [ ] |
| CST-07 | Select Blob redundancy and access tiers from durability, access, retrieval, and lifecycle requirements; use narrow lifecycle policies for media, backups, logs, versions, and soft-deleted data. | Tiering data too quickly or using broad deletion rules without recovery validation. | Storage policy, inventory, cost analysis. | [ ] |
| CST-08 | Model Front Door tier, WAF, requests, rule processing, data transfer, Private Link, and logging costs; use safe caching and compression to reduce origin transfer. | Enabling edge features without measuring benefit or retaining every request log indefinitely. | Cost model, cache metrics, logging retention. | [ ] |
| CST-09 | Manage Azure Monitor and Log Analytics ingestion, sampling, transformations, table plans, archive, and retention according to actual query needs. | A daily cap as the primary cost strategy or perpetual verbose duplicate telemetry. | Workspace configuration, ingestion and retention trend. | [ ] |
| CST-10 | Attribute cost across edge, compute, database, cache, storage, monitoring, security, network, backup, and messaging, then optimize the largest measured driver. | Optimizing minor resource costs while compute, database, or logging dominates. | Workload cost allocation and trend. | [ ] |
| CST-11 | Consolidate compatible applications and shared services only when their scaling, security, ownership, and SLO requirements are compatible. | One idle plan per app or co-hosting unrelated critical workloads solely to reduce spend. | Plan/service inventory, ownership and utilization. | [ ] |
| CST-12 | Optimize high-cost flows, media delivery, database queries, cache hit rate, and operational toil before adding capacity. | Scaling to hide inefficient code, database access, or administrative work. | Flow cost analysis, traces, database/cache metrics. | [ ] |
| CST-13 | Keep Defender, availability, security, backup, and DR spending that is required by the risk decision; review removal through formal risk acceptance. | Disabling high-value controls only to reduce visible service spend. | Risk acceptance, control mapping, cost review. | [ ] |
| CST-14 | Train operators to use cost tooling and automate repeatable cost controls, reporting, lifecycle management, and cleanup. | Manual cost reporting with no action owner or automation. | Operating model, automation, review cadence. | [ ] |

## 5. Operational Excellence

This section implements WAF operational excellence recommendations `OE:01` through `OE:11`.

| ID | Review control | Avoid | Evidence | Status |
|---|---|---|---|---|
| OPS-01 | Define standard development, security, operations, incident, and change-management practices with clear accountability and continuous improvement. | Undocumented, person-dependent production operations. | Operating model, RACI, review and postmortem records. | [ ] |
| OPS-02 | Use version-controlled declarative IaC for Azure resources, policy, networking, DNS, Front Door/WAF, diagnostics, and configuration; detect drift. | Portal-only changes or unreviewed mutable scripts. | Repository, pull requests, pipeline and drift reports. | [ ] |
| OPS-03 | Drive code, infrastructure, plugin/theme, and configuration changes through automated pipelines with peer review, tests, promotion gates, and traceable artifacts. | Direct production editing or untested WordPress auto-updates. | CI/CD definitions, release records, signed/versioned artifacts. | [ ] |
| OPS-04 | Use deployment slots where supported, slot-specific settings, warm-up and health validation, progressive exposure, and a tested rollback path. | Swapping an unhealthy slot, leaking slot settings, or irreversible database changes first. | Slot configuration, pipeline, swap and rollback test. | [ ] |
| OPS-05 | Keep database schema changes backward compatible with blue/green or slot rollout; plan and test data migration and rollback behavior. | Destructive production schema migration coupled to an unvalidated release. | Migration plan, deployment tests, rollback evidence. | [ ] |
| OPS-06 | Establish configuration baselines for App Service, MySQL parameters, Front Door/WAF, storage, Key Vault, Redis, and diagnostics; alert on drift. | Undocumented portal changes or inconsistent production and staging controls. | Baseline export, policy, drift report. | [ ] |
| OPS-07 | Enable application, web server, platform, WAF, access, health probe, MySQL, storage, Key Vault, cache, and network diagnostics with purposeful retention and centralized analysis. | Missing incident evidence or indefinite high-volume logging with no use case. | Diagnostic settings, workspace design, retention. | [ ] |
| OPS-08 | Instrument requests, dependencies, exceptions, distributed traces, business metrics, deployment markers, availability tests, and user-visible SLO symptoms. | Monitoring CPU alone or missing critical-flow behavior. | Application Insights, dashboards, availability tests. | [ ] |
| OPS-09 | Define actionable alerts with owners, severity, routing, deduplication, runbooks, and regular notification tests for errors, latency, saturation, availability, certificates, secrets, quota, and lifecycle events. | Alert storms, dashboards with no owner, or alerts that no one tests. | Alert rules, action groups, runbooks, test records. | [ ] |
| OPS-10 | Maintain runbooks for failed deployments, WAF false positives, origin bypass, compromised admin or plugin, MySQL failover/restore, cache loss, secret/certificate rotation, and outbound/SNAT failure. | A generic incident plan without Azure and WordPress actions or validation steps. | Runbooks and exercise records. | [ ] |
| OPS-11 | Establish a structured incident process for detection, diagnosis, communications, recovery, post-incident learning, and remediation ownership. | Incident response limited to portal visibility or a single administrator. | Incident plan, on-call rota, postmortems. | [ ] |
| OPS-12 | Perform unit, integration, end-to-end, security, backup/restore, performance, operational, and deployment tests in CI/CD with explicit acceptance criteria. | Resource deployment tests only, without proving the WordPress site and data work. | Test suites, pipeline results, release gates. | [ ] |
| OPS-13 | Track PHP, WordPress core, plugins, themes, MySQL, Azure services, certificates, secrets, domains, quotas, and service-retirement notices. | Unsupported runtimes or discovering expiry and retirement during an incident. | Lifecycle register, Service Health alerts, inventory. | [ ] |
| OPS-14 | Test and govern WordPress automatic updates and approved plugin/theme updates in staging before production. | Uncontrolled automatic production updates or unsupported extensions. | Governance policy, staging test, release record. | [ ] |
| OPS-15 | Create workbooks and dashboards for health, traffic, WAF activity, availability, database, cache, storage, cost, and security posture; review them regularly. | Dashboards without operational decisions or review ownership. | Workbooks, saved queries, review cadence. | [ ] |
| OPS-16 | Automate reliable, secure, and maintainable routine tasks such as validation, configuration export, cleanup, certificate/secret notifications, and recovery checks. | Manual procedures repeated without validation or audit trail. | Automation code, schedules, run history. | [ ] |
| OPS-17 | Use Azure Communication Services or an approved external SMTP relay for WordPress email; validate sender domain, SPF/DKIM/DMARC, delivery, bounce handling, and retry behavior. | Local sendmail, unverified sender domains, or treating send API success as confirmed delivery. | Provider configuration, DNS records, delivery reports, runbook. | [ ] |

## 6. Performance Efficiency

This section implements WAF performance efficiency recommendations `PE:01` through `PE:12`.

| ID | Review control | Avoid | Evidence | Status |
|---|---|---|---|---|
| PRF-01 | Define numerical performance targets for critical flows, including availability, P50/P95/P99 response time, TTFB, throughput, error rate, and cache behavior. | Vague performance goals or optimizing noncritical pages first. | Performance budget, SLO dashboard. | [ ] |
| PRF-02 | Perform capacity planning before anticipated marketing events, seasonal traffic, launches, growth, or regulatory deadlines. | Scaling only after user-visible saturation. | Forecast, load test, capacity plan. | [ ] |
| PRF-03 | Select App Service, MySQL, Redis, storage, and Front Door SKUs/tier features that can meet workload targets and expected capacity changes. | Burstable assumptions for sustained production demand or costly tiers with no measured need. | SKU rationale, metrics, load test. | [ ] |
| PRF-04 | Measure end-to-end latency, throughput, errors, saturation, dependency timing, queueing, cache hit rate, and database performance consistently over time. | Monitoring CPU alone or comparing inconsistent time periods. | Application Insights, Azure Monitor, query dashboards. | [ ] |
| PRF-05 | Implement controlled scale-out and partitioning; validate App Service autoscale, MySQL limits, cache capacity, SNAT capacity, and Front Door origin behavior under load. | Scale thresholds that oscillate or dependency limits ignored by app scaling. | Load test, autoscale and dependency metrics. | [ ] |
| PRF-06 | Load, stress, soak, cache-invalidation, and failure-mode test production-like critical flows at expected peak and growth traffic. | Happy-path average-load testing only. | Versioned test scripts, reports, remediation backlog. | [ ] |
| PRF-07 | Use Front Door caching only for explicitly cache-safe content. Design cache keys, query handling, TTLs, invalidation, and cookie behavior to avoid leaking personalized or authenticated responses. | Caching admin, private, or query-dependent content without validation. | Front Door rules, cache tests, HTTP headers. | [ ] |
| PRF-08 | Cache WordPress static content at Front Door and offload media/uploads to Blob Storage where the workload supports it; use compression and HTTP/2. | Serving all media from App Service or compressing already-compressed content blindly. | Front Door route, Blob integration, response headers, metrics. | [ ] |
| PRF-09 | Use object and page caching deliberately, with Azure Managed Redis or Azure Cache for Redis where appropriate; test reconnect, timeouts, cache miss, eviction, and cache-loss behavior. | A new Redis connection per request or application failure when cache is unavailable. | Cache configuration, metrics, fault test. | [ ] |
| PRF-10 | Enable and tune PHP OPcache, optimize images and lazy loading, minimize plugins, and document NGINX/startup customizations. | Unbounded plugin overhead, unoptimized uploads, or undocumented web-server changes. | PHP/NGINX configuration, plugin inventory, page test. | [ ] |
| PRF-11 | Replace user-triggered WordPress cron behavior with a reliable scheduled mechanism where workload analysis justifies it; monitor scheduled-job duration and failures. | Heavy cron execution on page requests. | WordPress and scheduler configuration, job logs. | [ ] |
| PRF-12 | Optimize MySQL indexes, queries, connections, storage/IOPS, and slow-query handling before scaling compute; keep app and database appropriately co-located. | Treating database scale-up as the only performance remedy. | Slow-query log, Query Store/metrics, query review. | [ ] |
| PRF-13 | Monitor and minimize the performance effects of backup, reindexing, security scans, secret rotation, deployments, and operational tasks. | Running maintenance during critical traffic without capacity or impact planning. | Schedule, telemetry, change records. | [ ] |
| PRF-14 | Define a live performance incident process with clear responsibilities, telemetry, mitigations, and follow-up optimization. | Ad hoc troubleshooting without a recovery or learning path. | Performance runbook and incident records. | [ ] |
| PRF-15 | Continuously optimize components that degrade over time, including WordPress plugins, MySQL tables and indexes, cache behavior, storage lifecycle, and networking. | Treating a one-time tuning exercise as permanent capacity planning. | Trend reports, optimization backlog. | [ ] |

## 7. Service-specific evidence register

Use this register to ensure the collector and manual review cover the deployed services. Mark absent services `N/A` with a rationale.

| Service | Required review focus | Evidence sources | Status |
|---|---|---|---|
| App Service plan, web app, and slots | SKU/capacity, zone redundancy, Always On, Health Check, autoscale, TLS, deployment authentication, managed identity, VNet integration, access restrictions, slots, diagnostics, runtime support. | `Microsoft.Web/serverfarms`, `Microsoft.Web/sites`, slots, configuration, metrics, pipeline. | [ ] |
| Azure Database for MySQL Flexible Server | Private connectivity/DNS, Entra or credential design, least-privilege MySQL roles, TLS, HA, backups, restore, maintenance, storage autogrow, query and connection performance, diagnostics. | `Microsoft.DBforMySQL/flexibleServers`, parameters, backups, diagnostics, metrics, grant review. | [ ] |
| Azure Front Door and WAF | Standard/Premium tier, routes/domains, WAF association/mode/rules/exclusions, rate limiting, origin protection, health probes, caching, compression, certificates, logs, alerts. | `Microsoft.Cdn/profiles`, WAF policy, diagnostics, synthetic and negative tests. | [ ] |
| Blob Storage | Private connectivity, public access, Entra/SAS/keys, TLS/encryption, redundancy, soft delete/versioning/immutability, lifecycle, media delivery, diagnostics and cost. | `Microsoft.Storage/storageAccounts`, blob service, management policy, private endpoints, metrics. | [ ] |
| Key Vault | RBAC, managed identities, private/restricted network, soft delete/purge protection, secret/key/certificate expiry and rotation, recovery, diagnostics. | `Microsoft.KeyVault/vaults`, role assignments, private endpoints, diagnostics, rotation records. | [ ] |
| Azure Managed Redis or Azure Cache for Redis | Product lifecycle, private access, TLS/authentication, HA, client resilience, connection reuse, evictions, memory, persistence, failover, cost. | `Microsoft.Cache/redisEnterprise` or `Microsoft.Cache/Redis`, metrics, client configuration, migration plan. | [ ] |
| Network, private endpoints, private DNS, and NAT Gateway | Segmentation, NSGs, UDRs, DNS links and ownership, approved private endpoints, explicit egress, NAT/SNAT capacity, flow telemetry, DDoS decision. | VNets, subnets, NSGs, route tables, private endpoints/zones, NAT, effective-rule tests. | [ ] |
| Application Insights and Log Analytics | Workspace design, telemetry redaction, availability tests, distributed tracing, alert ownership, retention, sampling/transforms, daily-cap alerting if used, cost. | Application Insights, Log Analytics workspace, DCRs, diagnostic settings, alerts. | [ ] |
| Azure Communication Services | Identity/key protection, sender-domain validation, consent, deliverability, queue/retry/idempotency, quotas, diagnostics, spend controls. | Communication Services resource, identity/RBAC, domain DNS, delivery and cost reports. | [ ] |
| Defender for Cloud and Azure Policy | MCSB assignment, Defender plan coverage, recommendations, attack paths, exemptions, alert routing, governance, security cost. | Subscription pricing/settings, assessments, compliance, recommendations, workflows. | [ ] |

## 8. Mandatory manual-validation register

The v4 collectors cannot prove the following. Review every applicable item manually and retain dated evidence.

| ID | Manual validation | Required evidence | Status |
|---|---|---|---|
| MAN-01 | Confirm critical flows, dependencies, SLOs/SLIs, RTOs/RPOs, and accepted risks with business owners. | Approved business impact analysis, SLO document, dependency map, risk acceptance. | [ ] |
| MAN-02 | Exercise whole-workload restore and recovery for database, uploads, application/configuration, secrets, DNS, certificates, edge routing, and network policy. | Measured RTO/RPO report, defects, owners, remediation evidence. | [ ] |
| MAN-03 | Test zone, region, dependency, identity, DNS, network, deployment, and cache failure scenarios at an agreed cadence. | Game-day/fault-injection records and updated runbooks. | [ ] |
| MAN-04 | Review Entra tenant controls, Azure RBAC, PIM/JIT, MFA, Conditional Access, break-glass accounts, MySQL roles, and access-review outcomes. | Identity/RBAC exports, PIM settings, access-review records. | [ ] |
| MAN-05 | Verify WordPress core, plugin, theme, package, container, and IaC vulnerability and secret scanning, provenance, patching, and ownership. | SBOM, scan reports, patch SLA, CI/CD configuration. | [ ] |
| MAN-06 | Exercise secret, certificate, key, and credential rotation, including dependent application validation and emergency access. | Rotation policy, expiry alerts, change records, successful test. | [ ] |
| MAN-07 | Test direct-origin bypass, WAF enforcement, authentication, authorization, WordPress admin protection, and security-alert response. | Negative tests, WAF logs, incident/tabletop evidence. | [ ] |
| MAN-08 | Verify IaC, peer review, policy checks, pipeline promotion, safe release, rollback, and drift detection. | Repository, pull requests, pipeline runs, drift reports. | [ ] |
| MAN-09 | Validate alert ownership, SLO/symptom coverage, action groups, dashboards, retention, runbooks, and notification tests. | Alert tests, dashboards, runbooks, on-call rota, postmortems. | [ ] |
| MAN-10 | Load, stress, soak, scalability, cache-invalidation, and failure-mode test critical flows in a production-like environment. | Versioned test scripts, reports, baselines, capacity conclusions. | [ ] |
| MAN-11 | Validate cost allocation, budgets, forecasts, anomaly alerts, cleanup, right-sizing, and commitment utilization. | Cost exports, budget alerts, monthly reviews, utilization reports. | [ ] |
| MAN-12 | Confirm WordPress operational governance for approved plugins/themes, staging validation, administrator access, privacy/consent, PII handling, and email deliverability. | Governance policy, access review, privacy assessment, delivery reports. | [ ] |

## 9. Review completion record

| Field | Value |
|---|---|
| Workload/environment | |
| Subscription and resource group | |
| Review date | |
| Reviewers | |
| Business owner | |
| Security owner | |
| Data classification | |
| SLO / RTO / RPO | |
| Pass / Fail / N/A / Not verified totals | |
| Critical and high findings | |
| Accepted risks and approver | |
| Remediation backlog | |
| Next review date | |

## Microsoft guidance used

### Framework checklists

- [Reliability design review checklist](https://learn.microsoft.com/azure/well-architected/reliability/checklist)
- [Security design review checklist](https://learn.microsoft.com/azure/well-architected/security/checklist)
- [Cost Optimization design review checklist](https://learn.microsoft.com/azure/well-architected/cost-optimization/checklist)
- [Operational Excellence design review checklist](https://learn.microsoft.com/azure/well-architected/operational-excellence/checklist)
- [Performance Efficiency design review checklist](https://learn.microsoft.com/azure/well-architected/performance-efficiency/checklist)
- [Microsoft cloud security benchmark](https://learn.microsoft.com/security/benchmark/azure/introduction)
- [Security policies and recommendations in Defender for Cloud](https://learn.microsoft.com/azure/defender-for-cloud/security-policy-concept)

### WordPress, service guidance, and reference architectures

- [WordPress on App Service](https://learn.microsoft.com/azure/app-service/overview-wordpress)
- [WordPress on Azure](https://learn.microsoft.com/azure/architecture/guide/infrastructure/wordpress-overview)
- [WordPress on App Service reference architecture](https://learn.microsoft.com/azure/architecture/example-scenario/infrastructure/wordpress-app-service)
- [Well-Architected best practices for App Service](https://learn.microsoft.com/azure/well-architected/service-guides/app-service-web-apps)
- [Well-Architected best practices for Azure Blob Storage](https://learn.microsoft.com/azure/well-architected/service-guides/azure-blob-storage)
- [Well-Architected best practices for Azure Database for MySQL](https://learn.microsoft.com/azure/well-architected/service-guides/azure-database-for-mysql)
- [Well-Architected best practices for Azure Front Door](https://learn.microsoft.com/azure/well-architected/service-guides/azure-front-door)
- [App Service security baseline](https://learn.microsoft.com/security/benchmark/azure/baselines/app-service-security-baseline)
- [Key Vault security baseline](https://learn.microsoft.com/security/benchmark/azure/baselines/key-vault-security-baseline)
- [Storage security baseline](https://learn.microsoft.com/security/benchmark/azure/baselines/storage-security-baseline)
- [Secure Azure Database for MySQL](https://learn.microsoft.com/azure/mysql/security/security-overview)
- [Secure Azure Front Door](https://learn.microsoft.com/azure/frontdoor/secure-front-door)
- [Azure App Service baseline architecture](https://learn.microsoft.com/azure/architecture/web-apps/app-service/architectures/baseline-zone-redundant)
- [Mission-critical App Service](https://learn.microsoft.com/azure/architecture/guide/networking/global-web-applications/mission-critical-app-service)