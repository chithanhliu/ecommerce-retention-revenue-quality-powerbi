# Methodology and Business Definitions

This document defines every measure used in the SQL and in the Power BI dashboard, and explains how the data was prepared and validated.

## 1. Analytical stages

The SQL comments and the pipeline output refer to four analytical stages. They are the steps of the analysis pipeline, from audit to dashboard; the project's management and review workflow is not part of this repository.

| Stage | Content | Where |
|---|---|---|
| 1 Audit | An independent pandas audit of the raw workbook: structure, overlap, cancellations, customer coverage. Its totals are used as independent reference figures in the SQL validation. The audit scripts are not part of this repository. | — |
| 2 Data model | Staging, classification, model tables, KPI views, 60 validation checks | `sql/01`–`04` |
| 3 Analysis | One view set per business question, 24 checks | `sql/10`–`14` |
| 4 Dashboard | Power BI shaping layer and export checks; Power BI report | `sql/20`–`22`, `powerbi/` |

## 2. Data preparation

**Combining the sheets**
- The two worksheets (2009–2010, 2010–2011) overlap on 1–9 Dec 2010.
- The 1,088 overlapping invoices are identical across the sheets and are counted once.
- Result: 1,044,848 lines out of 1,067,371 raw rows.

**Transaction classes** (rules applied in order; the first match wins)

| # | Rule | Class |
|---|---|---|
| 1 | Invoice starts with `A`, or StockCode `B` | Bad debt adjustment |
| 2 | StockCode `POST`, `DOT`, `C2` | Shipping |
| 3 | StockCode `AMAZONFEE`, `BANK CHARGES`, `CRUK` | Fee |
| 4 | StockCode `M`, `m`, `ADJUST`, `ADJUST2` | Manual adjustment |
| 5 | StockCode `D` | Discount |
| 6 | StockCode `S` | Sample |
| 7 | StockCode `gift_0001_*`, `GIFT` | Voucher |
| 8 | StockCode `TEST001`, `TEST002` | Test |
| 9 | Any remaining line on an invoice starting with `C` | Product cancellation |
| 10 | Any remaining line with price 0 | Zero-price |
| 11 | Any remaining line with quantity > 0 and price > 0 | Product purchase |

- 0 lines are unclassified.
- `C3` (one line: no description, quantity −4,999, price £0) is classed as zero-price, because the evidence does not support shipping.

**Records are flagged, not deleted**
- 22,813 exact-duplicate candidate rows are kept.
- **Extreme reversal pairs** are flagged. A pair is a purchase of 10,000 units or more, reversed within 60 minutes by the same customer, StockCode, quantity and price.
  - Two pairs exist: Jan 2011 (£77,183.60) and Dec 2011 (£168,469.60).
  - Each nets to £0.
  - They are excluded from normalized product value and kept for reconciliation.

## 3. Value measures

The word "revenue" is not used: there is no cost, tax or refund data.

| Measure | Definition |
|---|---|
| Gross positive product value (normalized) | Product purchase lines, excluding the extreme reversal pairs |
| Product cancellation adjustments | Product cancellation lines, excluding the extreme reversal pairs |
| Net recorded product value | Gross + cancellation adjustments |
| Non-product charges & adjustments | Shipping, fees, bad debt, manual, discount, sample, voucher, test |
| All-recorded net transaction value | Every recorded line, including the extreme pairs (which net to £0) |

**Cancellation ratios.** Each ratio has its own denominator:

| Ratio | Numerator | Denominator |
|---|---|---|
| Normalized (headline) | Product cancellations, excl. extreme pairs | Normalized gross product value |
| Recorded | All product cancellations | All gross product purchases |
| Unclassified (what a naive reading gives) | Every line on a cancellation (`C`) invoice, any class | Every positive line on standard invoices, any class |

A recorded cancellation does not confirm a return or a refund.

**Customer ID coverage** is value-based: identified product value ÷ overall product value.

## 4. Customer measures (identified customers only)

| Measure | Definition |
|---|---|
| Purchase occasion | One Customer ID × one calendar day with a qualifying purchase |
| Purchase frequency | Distinct purchase days. Labels such as "12+ days" are counts, not a monthly rhythm. |
| Average invoice value | Overall: every qualifying invoice. Identified: invoices with a Customer ID only. |
| Shapley decomposition | Identified value V = C (purchasing customers) × F (purchase days per customer) × S (value per purchase day). Changes A → B are attributed by averaging the six orders of changing C, F and S, so the three contributions sum exactly to the change. This is arithmetic, not causal. |

## 5. Retention definitions

- **Cohort** = the month of a customer's first observed purchase day.
  - **Dec 2009** is the base observed at data start. It is labelled *Observed base* and excluded from headline rates.
- **90-day repeat** = another purchase day on day 1–90 after the first purchase day.
  - A customer is eligible only with full follow-up: first purchase on or before 9 Sep 2011, the last complete day (8 Dec 2011) minus 90.
- **365-day repeat** (supporting) uses the same rule with 365 days. The 90-day and 365-day rates use different eligible customers, so the dashboard also compares them on the same 3,331 customers.
- Cohorts with fewer than 100 eligible customers are shown but not ranked.
- Horizons that cannot be observed yet are blank, never 0%.
- **Time to second purchase:** for each window (30/60/90/180/365 days), only customers with full follow-up are counted. Medians cover converted customers only.

## 6. Segmentation (window Dec 2010 – Nov 2011)

- **Group A** = customers first observed before the window and purchasing in it (2,707). This is the primary segmentation population.
- **Group B** = customers first observed in the window (1,585). It is profiled by months observed × 1 vs 2+ purchase days, and never ranked against Group A, because its customers had fewer months to buy.
- **Bands** (Group A):
  - frequency F1 = 1, F2 = 2–3, F3 = 4–11, F4 = 12+ purchase days;
  - value V1 < £500, V2 £500–£1,999, V3 ≥ £2,000 normalized gross product value.
- **Sensitivity:**
  - The F4 × V3 share is recomputed without the single largest account and without the top 5, with segments held fixed. These are scenarios only.
  - Shifting the frequency or value thresholds, or using net instead of gross value, moves the top segment's share by at most 0.2 pp (49.8% → 49.6%).

## 7. Power BI model

- **Tables:**
  - `dim_month`, the only slicer date table; `dim_date`;
  - `fct_invoice` (one invoice);
  - `fct_customer_day` (one customer × purchase day);
  - `dim_customer` (one customer; surrogate key, 0 = no Customer ID);
  - `agg_value_class_month` (monthly totals by class, for the cancellation ratios and reconciliation);
  - disconnected `ref_*` tables holding SQL results.
- All relationships are single-direction, from dimension to fact. There are no fact-to-fact or many-to-many relationships.
- Fixed comparisons (Period A vs B, Group A, headline retention) are set inside the measures. Page interactions that would change a validated population are switched off.
  - Only two selections drive other visuals: the cohort table → *Selected cohort* panel, and the segment matrix → *Selected segment* panel.

## 8. Validation approach

1. **Source reconciliation:**
   - row counts after combining the sheets;
   - class totals against the independent pandas audit;
   - all-recorded net = £18,909,762.12.
2. **Second route:** key KPIs are rebuilt directly from staging lines, such as AIV, 90-day eligibility, cohort cells and top-20% share.
3. **Grain and integrity:** keys are unique, no orphan rows, identified value is equal from the invoice fact and the customer-day fact, and the Shapley contributions sum to the change.
4. **Export and Power BI:**
   - No identifier columns are exported.
   - Each Parquet file is read back and checked against its source.
   - DAX measures are compared with 53 SQL targets on the hidden *Data Notes & Reconciliation* page.

## 9. Limitations

- No cost, margin, channel, campaign or refund data, so no profit, lifetime value, churn or causal claims.
- Left censoring: the Dec 2009 base and early 2010 cohorts probably include customers active before the data starts.
- Right censoring: Dec 2011 covers only 9 days, and recent cohorts have short follow-up.
- Coverage: customer-level results cover 85–89% of product value.
