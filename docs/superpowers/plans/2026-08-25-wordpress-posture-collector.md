# WordPress Azure Posture Collector Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `v4`, a resource-group-scoped Azure evidence collector for WordPress on Linux App Service that supports security and reliability assessment.

**Architecture:** The parent dispatcher inventories every resource in the supplied resource group, emits a redacted resource-topology document, and invokes a focused collector for each expected workload service. Each collector persists a JSON document containing command provenance, result state, and safe configuration evidence. A subscription-level Defender collector captures plan and posture data, filtering findings to resource IDs discovered in the workload.

**Tech Stack:** PowerShell 7+, Azure CLI, Pester 5+.

---

## Chunk 1: Framework and Discovery

### Task 1: Test document safety and resource classification

**Files:**
- Create: `v4/tests/Common-AzureCollector.Tests.ps1`
- Create: `v4/tests/Invoke-CollectWordPressPosture.Tests.ps1`

- [ ] Write Pester tests showing that sensitive values are redacted and expected WordPress resource types are classified.
- [ ] Run `Invoke-Pester ./v4/tests -Output Detailed` and confirm the tests fail because v4 code does not exist.
- [ ] Implement the minimum shared helpers and classification function.
- [ ] Re-run the Pester tests and confirm they pass.

### Task 2: Implement the resource-group dispatcher

**Files:**
- Create: `v4/Common-AzureCollector.ps1`
- Create: `v4/Invoke-CollectWordPressPosture.ps1`

- [ ] Capture generic resource inventory, topology, locks, role assignments, diagnostic settings, and unsupported resources.
- [ ] Route App Service, plans, MySQL, Key Vault, Redis, NAT Gateway, Front Door, Storage, Communication Services, App Insights, Log Analytics, and support-network resources.
- [ ] Preserve command failures in output rather than stopping optional evidence collection.
- [ ] Validate script parsing with `Invoke-ScriptAnalyzer` when available and Pester tests.

## Chunk 2: Application, Data, and Edge Collectors

### Task 3: Collect App Service, slots, plans, and observability

**Files:**
- Create: `v4/Get-AppServicePlanData.ps1`
- Create: `v4/Get-AppServiceData.ps1`
- Create: `v4/Get-AppServiceSlotData.ps1`
- Create: `v4/Get-AppInsightsData.ps1`
- Create: `v4/Get-LogAnalyticsWorkspaceData.ps1`

- [ ] Record security, resiliency, identity, network, diagnostics, and scaling configuration without retaining secret values.
- [ ] Include deployment slots as explicit resources, including settings and traffic/routing data.
- [ ] Confirm every script parses successfully.

### Task 4: Collect WordPress persistence and secret services

**Files:**
- Create: `v4/Get-MySqlFlexibleServerData.ps1`
- Create: `v4/Get-KeyVaultData.ps1`
- Create: `v4/Get-ManagedRedisData.ps1`
- Create: `v4/Get-StorageAccountData.ps1`

- [ ] Record MySQL backup, HA, networking, authentication, encryption, databases, configurations, and diagnostic evidence.
- [ ] Record Key Vault access model and inventory metadata without secret values.
- [ ] Record Redis TLS, clustering, persistence, access, and diagnostic configuration.
- [ ] Record Storage public exposure, HTTPS/TLS, encryption, retention, networking, and diagnostic configuration.

### Task 5: Collect ingress, egress, communication, and security posture

**Files:**
- Create: `v4/Get-FrontDoorData.ps1`
- Create: `v4/Get-NatGatewayData.ps1`
- Create: `v4/Get-AzureCommunicationServicesData.ps1`
- Create: `v4/Get-NetworkTopologyData.ps1`
- Create: `v4/Get-DefenderForCloudData.ps1`

- [ ] Record Front Door endpoints, routes, origin health/rules, custom domains, WAF policies, and diagnostic configuration.
- [ ] Record NAT Gateway public IP/prefix association and subnet placement.
- [ ] Record Communications Services identity, networking, and diagnostics.
- [ ] Capture VNet, subnets, NSGs, route tables, private endpoints, private DNS zones, and public IP configuration.
- [ ] Capture subscription Defender plans, pricing, security contacts, and only assessments/recommendations relevant to discovered resource IDs.

## Chunk 3: Documentation and Verification

### Task 6: Document use, scope, and evidence model

**Files:**
- Create: `v4/README.md`

- [ ] Explain prerequisites, least-privileged collection permissions, invocation, output layout, secret-redaction behavior, expected WordPress resources, and known API/permission gaps.
- [ ] Map collected evidence to Security and Reliability assessment domains and Microsoft cloud security benchmark baseline guidance.

### Task 7: Validate static behavior

**Files:**
- Test: `v4/tests/*.Tests.ps1`

- [ ] Run Pester tests.
- [ ] Run a PowerShell parse check over all `v4/*.ps1` files.
- [ ] Run PSScriptAnalyzer if installed.
- [ ] Review the diff to ensure no secrets or unrelated changes are included.