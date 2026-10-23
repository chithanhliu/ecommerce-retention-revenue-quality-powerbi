# Findings and Recommended Investigations

These are the four insights on dashboard Page 5, in priority order. Each one gives the measured finding, why it matters, the next investigation, what the data cannot show, and the data that would strengthen a decision.

**Priority method.** Business significance + observation evidence + actionability, each scored 1–3. Ties are broken by significance, then by how firmly the explanation is known. This is a decision-support heuristic, not a measured business-risk ranking. The recommendations are proposals, not implemented actions, and no financial benefit is estimated.

| # | Insight | Score | Next step |
|---|---|---|---|
| 1 | I-1 Customer Value Concentration | 9 (highest) | Investigate |
| 2 | I-2 Customer Identification Gap | 8 | Investigate |
| 3 | I-5 Cancellation Reporting Integrity | 8 | Act: reporting rule |
| 4 | I-3 Purchase Frequency Contribution | 8 | Investigate |

---

## 1. I-1 Customer Value Concentration

| | |
|---|---|
| **Finding (confirmed)** | 196 Group A customers (7.2%) hold 49.8% of Group A product value. The share is 47.7% without the largest account and 41.4% without the top 5 accounts. |
| **Evidence** | Dashboard Page 4: segment matrix, top-account sensitivity. 711 V3 customers (26% of Group A) hold 79.6% of its value. |
| **Implication** | Observed product value depends on a small number of accounts. |
| **Investigate** | Each F4 × V3 account's value and purchase-day trend, Period A → B, and possible commercial dependencies. |
| **Limitation** | Not profitability, lifetime value or a confirmed risk of losing customers. Concentration may be normal for a wholesale customer base. |
| **Data needed** | Account relationships, contracts, margins, customer engagement. |

## 2. I-2 Customer Identification Gap

| | |
|---|---|
| **Finding (confirmed)** | Value without a Customer ID rose 32.1% (£1.07M → £1.41M; 11.3% → 14.7% of value), while identified-customer value fell 2.3%. Overall value rose 1.6%. |
| **Evidence** | Dashboard Pages 1–2: monthly identified vs unidentified value, value by Customer ID status. |
| **Implication** | Customer-level KPIs describe a shrinking share of activity. |
| **Investigate** | The processes and transaction sources behind invoices without a Customer ID. |
| **Limitation** | The data has no channel field. Possible causes (a marketplace channel, a change in data capture, guest orders) are untested hypotheses. |
| **Data needed** | Order source, sales channel, account-capture process, system metadata. |

## 3. I-5 Cancellation Reporting Integrity

| | |
|---|---|
| **Finding (confirmed)** | The Period B cancellation ratio is 6.91% unclassified, 3.15% recorded and 2.37% normalized. Monthly spikes are often single invoices: in Apr 2011, one invoice is 69% of the month's product cancellations. |
| **Evidence** | Dashboard Page 1: value reconciliation, cancellation ratio by definition. |
| **Implication** | An unclassified cancellation KPI overstates product cancellations 2–3×. |
| **Action** | Standardise on the normalized product cancellation ratio; investigate abnormal cancellation events. |
| **Limitation** | A recorded cancellation is not a confirmed refund or return. |
| **Data needed** | Refund confirmation, return reasons, accounting treatment, operational logs. |

## 4. I-3 Purchase Frequency Contribution

| | |
|---|---|
| **Finding (confirmed, arithmetic)** | Purchase days per customer contribute −£219.9k of the −£193.2k identified-value change. Purchasing customers contribute +£102.7k and value per purchase day −£76.1k. |
| **Evidence** | Dashboard Page 2: Shapley decomposition (the range across the six decomposition orders is within ±2%), purchasing-activity table. Customers active in both periods bought on 7.4% fewer days. |
| **Implication** | Customer count held up; purchase days per customer fell. |
| **Investigate** | Purchase-day patterns and ordering behaviour (basket size vs frequency) for the 2,707 customers active in both periods. |
| **Limitation** | Arithmetic, not causal; it does not indicate churn or reduced loyalty. Alternative explanations include order consolidation and the composition of the Dec 2009 observed base. |
| **Data needed** | Ordering schedules, sales channels, promotions, seasonality, operational changes. |

---

## Supporting finding: retention timing

- **Finding:** 40.9% of first-observed customers (Dec 2009 base excluded) repeat within 90 days (n = 4,305). On the same 3,331 customers with a full year of follow-up, 40.6% repeat within 90 days and 69.7% within 365 days. 969 of the 2,323 one-year repeaters (41.7%) first return after day 90.
- **Implication:** the 90-day rate is an early signal, not a measure of whether customers return.
- **Tentative:** cohort-to-cohort differences may reflect seasonality and left censoring. They are not evidence of declining loyalty.
