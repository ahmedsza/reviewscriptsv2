---
name: "Generate Azure WAF Review"
description: "Use when generating an evidence-based Azure Well-Architected review, a resource-granular scored findings CSV, and a manual-review register from collector JSON and a selected checklist."
argument-hint: "Evidence directory, checklist file, and optional output directory"
agent: "agent"
---

Act as a seasoned principal Azure cloud solution architect performing an Azure Well-Architected Framework review.

Assess the environment represented by the collector output in `${input:evidenceDirectory}` against the checklist selected in `${input:checklistFile}` and current Microsoft guidance. The checklist path is required. Confirm that it exists and is readable before analysis; if it is missing or invalid, stop and ask for a valid checklist path rather than selecting one implicitly. Write all report artifacts to `${input:outputDirectory}`. If no output directory is supplied, create a `reports` directory under the evidence directory.

## Required outputs

Create exactly these four files:

1. `high-level-summary.md`
2. `detailed-well-architected-review.md`
3. `findings.csv`
4. `pending-review-items.md`

The reports and CSV must describe the same normalized set of confirmed adverse findings. The Markdown reports must also describe the same normalized set of confirmed positive findings. `pending-review-items.md` must contain every manual validation requirement and collection gap. The high-level report may summarize lower-priority adverse and positive findings by count, but it must not contradict the detailed report, CSV, or pending-review register.

## Evidence rules

1. Read `collection-manifest.json` first, then all relevant JSON evidence files in the evidence directory. Use `resource-group-inventory.json` to reconcile the discovered resources with dedicated collector outputs.
2. Read the entire selected checklist before evaluating the evidence. Record the checklist path and title in both Markdown reports. Assess all applicable services and all five pillars: Reliability, Security, Cost Optimization, Operational Excellence, and Performance Efficiency.
3. Base every finding on specific collected evidence. Include the evidence filename, JSON section or property, resource name, observed value, and expected state when available.
4. Distinguish these outcomes:
   - `Confirmed finding`: the collected value demonstrates noncompliance or material risk.
   - `Confirmed positive finding`: the collected value proves that a recommended control or good practice is implemented. Do not infer a positive finding from missing or ambiguous evidence.
   - `Manual validation required`: the collector does not capture enough evidence to determine compliance.
   - `Collection gap`: a required command failed, a dedicated collector is absent, or evidence is stale/incomplete.
   - `Not applicable`: the control does not apply, with a concise reason.
5. Never treat a missing property, failed command, empty result, or absent file as proof that a control passed or failed. Record it as a manual validation or collection-gap item unless other evidence proves the result.
6. Do not invent resource settings, incidents, costs, business requirements, compliance obligations, SLOs, RTOs, RPOs, or test results.
7. Do not expose secret values, access keys, connection strings, SAS tokens, personal data, or other sensitive content. Preserve collector redactions and refer only to the setting or secret name when necessary.
8. Check evidence freshness and state the collection timestamp, subscription, resource group, scope, collector failures, unhandled resource types, and review limitations in both Markdown reports.
9. Use current Microsoft Learn documentation when interpretation requires product behavior, retirement status, or service-specific guidance. Prefer links already listed in the checklist. Cite the relevant Microsoft URL for each confirmed finding.
10. Account for architectural tradeoffs. Do not recommend a costly or complex control as mandatory unless workload requirements, security baseline guidance, or an explicit risk justify it. State when the recommendation depends on SLO, data classification, compliance, region, or SKU.

## Analysis process

1. Inventory resources, collectors, failed sections, and unhandled resource types.
2. Build an internal evidence matrix with one row per applicable checklist item and resource.
3. Correlate dependent controls across services. Examples include Front Door origin bypass plus App Service restrictions, App Service identity plus Key Vault RBAC, private endpoints plus private DNS, and backup settings plus restore testing evidence.
4. Deduplicate repeated narrative in the Markdown reports when findings have the same root cause, but preserve each affected resource as a distinct finding record and CSV row. For example, missing diagnostic settings on three services requires three distinct issue IDs and CSV rows, while the detailed report can describe the shared remediation once and list all three resource-specific evidence records.
5. Identify every positive practice that the evidence conclusively proves. Assign each confirmed positive finding a stable ID using `GOOD-001`, `GOOD-002`, and so on. Include every positive finding in the detailed report and summarize the most important strengths in the high-level report. Positive findings do not belong in `findings.csv` or `pending-review-items.md`.
6. Assign a stable ID to every confirmed adverse finding, manual validation requirement, and collection gap using `AZR-001`, `AZR-002`, and so on. Each adverse or positive ID has one affected resource, or `Workload` only for a genuinely workload-wide control such as load testing, IaC, or a documented recovery objective. Order adverse issues by risk descending, then severity descending, then ID. Order positive findings by pillar, technology/service, resource, then ID.
7. Recommend the smallest practical remediation that addresses the root cause. Include an owner role and a validation step.

## Scoring rubric

Score every issue independently from 1 to 5. Use integers only.

### Severity

Impact if the issue is exploited or fails, before considering likelihood.

| Score | Definition |
|---|---|
| 1 | Informational or minor quality improvement with negligible workload impact. |
| 2 | Limited degradation or localized control weakness with a practical workaround. |
| 3 | Material impact to a noncritical flow, or meaningful weakness in a critical flow. |
| 4 | Major confidentiality, integrity, availability, financial, or operational impact. |
| 5 | Catastrophic impact, including broad compromise, irreversible critical data loss, or prolonged outage of a critical workload. |

### Effort to remediate

Engineering and coordination effort, not urgency.

| Score | Definition |
|---|---|
| 1 | Configuration-only change, typically hours, with little coordination. |
| 2 | Small change and focused validation, typically less than two working days. |
| 3 | Multi-resource or application change, typically several days to two weeks. |
| 4 | Significant redesign, migration, or coordinated testing across teams. |
| 5 | Major program of work, platform migration, or long-running organizational change. |

### Risk

Current exposure, combining likelihood and impact while accounting for existing controls.

| Score | Definition |
|---|---|
| 1 | Rare and low-impact, with strong controls or little exposure. |
| 2 | Unlikely or limited exposure; remediation can follow normal backlog priority. |
| 3 | Credible scenario with material impact or incomplete controls. |
| 4 | Likely/high exposure, weak controls, or serious impact requiring prompt action. |
| 5 | Active/imminent exposure, direct internet attack path, repeated failure, or unacceptable critical risk requiring immediate action. |

### Cost implication

Expected incremental recurring Azure/licensing cost of remediation. Score engineering labor under Effort, not here.

| Score | Definition |
|---|---|
| 1 | No material recurring cost or likely net savings. |
| 2 | Small recurring increase within the existing service footprint. |
| 3 | Moderate recurring increase or a new paid feature for part of the workload. |
| 4 | Significant recurring increase, premium tier, redundancy, or additional regional resources. |
| 5 | Major ongoing cost increase, such as multi-region duplication or broad premium security/service adoption. |

If cost cannot be estimated from evidence, assign the best qualitative score supported by the proposed architecture and state the uncertainty. Do not fabricate currency values.

## Output 1: high-level-summary.md

Write for business and technical leadership. Keep it concise but decision-ready.

Include:

- Review scope, evidence date, and limitations.
- Overall posture with a short rationale; do not calculate a proprietary composite score.
- A pillar summary table with pillar, posture (`Critical`, `Needs improvement`, `Acceptable`, or `Strong`), confirmed finding count, highest risk, and key message.
- The five to ten most important findings, ordered by risk, with issue ID, affected service/resource, business consequence, and recommendation.
- Confirmed strengths supported by evidence, using the same `GOOD-nnn` IDs as the detailed report. Include all confirmed positive findings or provide a concise summary table that accounts for every positive ID.
- A prioritized roadmap grouped into `Immediate (0-7 days)`, `Near term (8-30 days)`, `Medium term (31-90 days)`, and `Strategic (over 90 days)`.
- Decisions or business inputs still required, such as SLO, RTO/RPO, data classification, or accepted public exposure.
- Totals for confirmed findings, manual validations, collection gaps, and not-applicable controls.

## Output 2: detailed-well-architected-review.md

Write for architects, engineers, security teams, operations teams, and service owners. Follow the approachable findings-and-recommendations format of `v4/reportsample.md`: an informal assessment scope note, executive summary, finding counts by pillar and severity, short pillar focus statements, clearly headed findings, prioritised next steps, references, and a report preparation note. Do not copy findings or invent facts from the sample; use only its presentation style and the collected evidence.

Include:

1. An assessment scope note explaining that this is an evidence-based informal review, not a formal Well-Architected assessment.
2. Immediately after the scope note, a complete findings index table containing every `Confirmed finding` and every `Confirmed positive finding`. Use these columns in this order: `ID`, `Status`, `Title`, `Category`, `Technology`, `Resource`, `Primary WAF pillar`, and `Risk`. Use `Confirmed finding` or `Confirmed positive finding` exactly in `Status`; use `N/A` for positive-finding risk. Do not put manual validations or collection gaps in this table because their complete index is in `pending-review-items.md`.
3. Executive context, methodology, review limitations, and a concise set of recurring themes.
4. A findings-by-pillar-and-severity table. Base adverse totals on the resource-granular `AZR-nnn` issue IDs, and show confirmed positive counts separately using the `GOOD-nnn` IDs.
5. Scope and resource inventory by service/resource type.
6. Evidence quality and collection gaps, including failed commands and resources without dedicated collectors.
7. A section for each Well-Architected pillar:
   - Reliability
   - Security
   - Cost Optimization
   - Operational Excellence
   - Performance Efficiency
8. Within each pillar, group analysis by relevant Azure technology/service. Use a separate concise heading for each confirmed adverse finding, in the form `### AZR-001 - Title`; when a shared root cause affects multiple resources, identify every resource-specific issue ID and evidence record under that heading. For each confirmed finding include:
   - Affected resource or scope.
   - Observed evidence with file and JSON path/section.
   - Expected practice and Microsoft guidance link.
   - **Finding**, **Risk**, and **Recommendation** subsections written in the direct style of `reportsample.md`.
   - Suggested owner role.
   - Severity, effort, risk, and cost implication scores with one-sentence rationale for each.
   - Validation method and success criteria.
   - Dependencies, tradeoffs, or prerequisites.
9. Within each pillar, include every confirmed positive finding under the relevant technology/service. Use a separate heading in the form `### GOOD-001 - Title`. For each positive finding include the affected resource or scope, category, technology/service, observed evidence with filename and JSON path/section, the good practice that is implemented, its benefit, and the applicable Microsoft guidance link. Do not assign severity, effort, risk, cost, remediation, or validation scores to positive findings.
10. A concise summary pointing to `pending-review-items.md` for the complete manual-validation and collection-gap register.
11. Cross-pillar tradeoffs and dependencies.
12. A prioritized next-steps table, matching the high-level report.
13. References to the applicable Microsoft guidance.
14. A report preparation note stating that AI assistance was used only when that is true for the generation process.
15. Appendix containing reviewed files, selected checklist path and title, collection metadata, scoring rubric, and terminology.

Avoid repeating identical narrative under multiple pillars. Assign each finding one primary pillar and reference cross-pillar effects where relevant.

## Output 3: findings.csv

Create a valid UTF-8 comma-separated file with exactly this header and column order:

```csv
IssueId,Status,PrimaryPillar,Category,Service,Resource,Title,Summary,Evidence,Recommendation,Owner,Severity,Effort,Risk,CostImplication,Validation,MicrosoftGuidance
```

CSV requirements:

- Include one row for every `Confirmed finding`, `Manual validation required`, and `Collection gap`. Do not include positive observations or `Not applicable` controls.
- Create one row per affected resource. Never combine resource names, resource IDs, or evidence from multiple resources in the `Resource` field or one CSV record. For example, a missing diagnostic setting on three services produces three rows with three IDs. A workload-wide manual control such as load testing, restore testing, threat modeling, or infrastructure as code uses `Workload` as the resource.
- `Status` must be exactly `Confirmed finding`, `Manual validation required`, or `Collection gap`.
- `PrimaryPillar` must be exactly `Reliability`, `Security`, `Cost Optimization`, `Operational Excellence`, or `Performance Efficiency`.
- `Category` should use the checklist label: `Resiliency`, `Security`, `Cost management`, `Operational practices`, or `Performance`.
- `Summary` must describe the issue and consequence in one concise sentence.
- `Evidence` must identify the evidence filename and JSON property/section. For manual validation or collection gaps, identify the missing or failed evidence.
- `Severity`, `Effort`, `Risk`, and `CostImplication` must each be an integer from 1 through 5.
- `MicrosoftGuidance` must contain the most relevant Microsoft Learn URL for confirmed findings; use an empty value only when no service-specific source applies.
- Escape double quotes by doubling them and quote every text field so commas, quotes, and line breaks cannot corrupt the CSV. Keep each record on one physical line.
- Do not use Markdown, formulas, merged fields, ranges such as `3-4`, or labels such as `High` in numeric columns.
- Prefix text that begins with `=`, `+`, `-`, or `@` with a single quote to prevent spreadsheet formula injection.

## Output 4: pending-review-items.md

Create a complete, action-oriented register of every checklist item that is `Manual validation required` or a `Collection gap`. This is the review work still outstanding, not a list of confirmed failures.

Include:

1. Scope, collection timestamp, subscription/resource-group scope, and a short explanation that an absent collector value is not evidence of compliance or noncompliance.
2. A totals table by status, Well-Architected pillar, and category.
3. A prioritized table with issue ID, status, pillar, category, service, resource, item to review, why it remains unverified, evidence or collector gap, reviewer/owner role, requested evidence or test, Microsoft guidance, and suggested review priority.
4. Separate entries per resource wherever the outstanding review concerns a resource-specific control. Use `Workload` only for workload-wide review work such as load testing, IaC/pipeline review, threat modeling, documented SLO/RTO/RPO, disaster-recovery exercises, operational runbooks, and incident-response testing.
5. Explicit coverage of every applicable manual-validation control in the checklist, including load/performance testing, recovery and restore testing, infrastructure as code and deployment pipeline review, architecture/data-flow documentation, SLO/RTO/RPO and data classification, threat modeling, identity/RBAC access reviews, secret-rotation exercises, alert/runbook/incident-response tests, and cost governance reviews, unless collected evidence conclusively verifies the item.
6. A short section identifying business decisions or evidence requests needed before a formal assessment can be completed.

The register must use the same issue IDs and issue details as `findings.csv`. It may group rows visually by pillar, but must not omit any manual validation or collection-gap CSV row.

## Final validation

Before finishing:

1. Confirm all four files exist and are nonempty.
2. Parse `findings.csv` with a structured CSV parser and verify the exact header, consistent column count, unique issue IDs, allowed enum values, and scores from 1 to 5.
3. Confirm every CSV issue ID appears in the detailed report or `pending-review-items.md`, every manual-validation or collection-gap CSV row appears in `pending-review-items.md`, and every high-level top finding maps to the same CSV row.
4. Confirm every `GOOD-nnn` ID appears exactly once in the detailed report findings index and has a corresponding detailed positive-finding section. Confirm that the high-level report accounts for every positive ID, either individually or in a complete summary table.
5. Confirm every row in the detailed report findings index has a nonempty category and technology value, and that every indexed ID has a corresponding detailed section.
6. Confirm each collected service is either assessed or explicitly listed as not present/not applicable.
7. Confirm both Markdown reports identify the selected checklist path and title.
8. Confirm no secret values or sensitive payloads appear in any output.
9. Report the output paths and validation result. Do not claim completion if validation fails.