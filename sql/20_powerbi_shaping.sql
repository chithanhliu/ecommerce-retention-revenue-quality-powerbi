-- =============================================================================
-- 20_powerbi_shaping.sql — Stage 4: Power BI shaping layer
-- Shapes validated Stage 2-3 tables for Power BI. No new business rule: every value
-- comes from an existing validated table or view.
-- Public safety: pbi_* and ref_* tables carry NO customer_id, invoice_no,
-- stock_code or description. Customers get a salted surrogate key; the mapping table
-- pbi_customer_key_map stays in DuckDB and is never exported.
-- Types: counts are BIGINT and GBP values DECIMAL(18,3). SUM() returns HUGEINT / DECIMAL(38,3),
-- and Parquet stores HUGEINT as DOUBLE (found by the read-back checks), so types are cast explicitly.
-- Requires: SET VARIABLE pbi_salt (set by scripts/run_pipeline.py from a local,
-- git-ignored file).
-- =============================================================================

-- pbi_customer_key_map (NOT exported) ---------------------------------------------
-- Grain: one Customer ID. customer_key 1..n in an order fixed by a salted hash, so the
-- key does not reveal the original ID. Key 0 is reserved for "Unidentified".
CREATE OR REPLACE TABLE pbi_customer_key_map AS
SELECT
    customer_id,
    CAST(ROW_NUMBER() OVER (ORDER BY md5(CAST(customer_id AS VARCHAR) || getvariable('pbi_salt'))) AS INTEGER)
        AS customer_key
FROM dim_customer;

-- pbi_dim_month -------------------------------------------------------------------
-- Grain: one calendar month, Dec 2009 - Dec 2011 (25 rows). The only date table used by
-- slicers. Period C = Dec 2011 (partial, 1-9 Dec) and is_reporting_month = FALSE.
CREATE OR REPLACE TABLE pbi_dim_month AS
SELECT
    CAST(m AS DATE)                                                       AS month_start,
    strftime(m, '%b %Y')                                                  AS month_label,
    CAST(strftime(m, '%Y%m') AS INTEGER)                                  AS month_sort,
    left(analysis_period(CAST(m AS DATE)), 1)                             AS period,
    analysis_period(CAST(m AS DATE))                                      AS period_label,
    CAST(m AS DATE) <= DATE '2011-11-01'                                  AS is_reporting_month,
    CASE WHEN CAST(m AS DATE) <= DATE '2011-11-01'
         THEN (date_diff('month', DATE '2009-12-01', CAST(m AS DATE)) % 12) + 1 END
                                                                          AS month_of_period,   -- 1 = Dec ... 12 = Nov
    strftime(m, '%b')                                                     AS calendar_month
FROM generate_series(TIMESTAMP '2009-12-01', TIMESTAMP '2011-12-01', INTERVAL 1 MONTH) AS t(m);

-- pbi_dim_date ----------------------------------------------------------------------
-- Grain: one calendar day, 2009-12-01 - 2011-12-09 (739 rows). Joins facts to pbi_dim_month.
CREATE OR REPLACE TABLE pbi_dim_date AS
SELECT
    CAST(d AS DATE)                                   AS date,
    CAST(date_trunc('month', d) AS DATE)              AS month_start,
    CAST(year(d) AS INTEGER)                          AS year,
    CAST(month(d) AS INTEGER)                         AS month_num,
    strftime(d, '%a')                                 AS weekday
FROM generate_series(TIMESTAMP '2009-12-01', TIMESTAMP '2011-12-09', INTERVAL 1 DAY) AS t(d);

-- pbi_dim_customer --------------------------------------------------------------------
-- Grain: one customer_key; key 0 = "Unidentified (no Customer ID)". Includes the final
-- Dec 2010 - Nov 2011 window segment columns (final bands, from bq4_customer_segment);
-- NULL window columns = not active in the window.
CREATE OR REPLACE TABLE pbi_dim_customer AS
SELECT
    k.customer_key,
    'Customer ' || lpad(CAST(k.customer_key AS VARCHAR), 4, '0')         AS customer_label,
    FALSE                                                                AS is_unidentified,
    c.primary_country,
    c.has_qualifying_purchase,
    c.first_purchase_date,
    c.first_observed_month,
    c.is_observed_base,
    CAST(c.purchase_days AS BIGINT)                                      AS purchase_days_all,
    CAST(c.qualifying_invoices AS BIGINT)                                AS qualifying_invoices_all,
    CAST(c.gross_product_value AS DECIMAL(18, 3))                        AS gross_product_value_all,
    left(s.tenure_group, 1)                                              AS tenure_group_window,   -- 'A' / 'B' / NULL
    s.frequency_band                                                     AS frequency_band_window,
    s.value_tier                                                         AS value_tier_window,
    CAST(s.purchase_days AS BIGINT)                                      AS purchase_days_window,
    CAST(s.qualifying_invoices AS BIGINT)                                AS qualifying_invoices_window,
    CAST(s.gross_product_value AS DECIMAL(18, 3))                        AS gross_product_value_window,
    CAST(s.product_cancellation_value AS DECIMAL(18, 3))                 AS product_cancellation_value_window,
    CAST(s.net_product_value AS DECIMAL(18, 3))                          AS net_product_value_window,
    s.months_in_window_since_first                                       AS months_observed_window
FROM dim_customer AS c
JOIN pbi_customer_key_map AS k ON k.customer_id = c.customer_id
LEFT JOIN bq4_customer_segment AS s ON s.customer_id = c.customer_id
UNION ALL
SELECT 0, 'Unidentified (no Customer ID)', TRUE, NULL, FALSE, NULL, NULL, FALSE, 0, 0, 0,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL;

-- pbi_fct_invoice -----------------------------------------------------------------------
-- Grain: one invoice (from fct_invoice). invoice_no is dropped; customer_key 0 = unidentified.
CREATE OR REPLACE TABLE pbi_fct_invoice AS
SELECT
    COALESCE(k.customer_key, 0)                     AS customer_key,
    i.invoice_date,
    i.invoice_month,
    i.invoice_type,
    i.country,
    i.line_count,
    CAST(i.all_recorded_value AS DECIMAL(18, 3))                    AS all_recorded_value,
    CAST(i.gross_product_value_recorded AS DECIMAL(18, 3))          AS gross_product_value_recorded,
    CAST(i.gross_product_value AS DECIMAL(18, 3))                   AS gross_product_value,
    CAST(i.product_cancellation_value_recorded AS DECIMAL(18, 3))   AS product_cancellation_value_recorded,
    CAST(i.product_cancellation_value AS DECIMAL(18, 3))            AS product_cancellation_value,
    CAST(i.non_product_value AS DECIMAL(18, 3))                     AS non_product_value,
    i.is_qualifying_purchase,
    i.has_extreme_reversal
FROM fct_invoice AS i
LEFT JOIN pbi_customer_key_map AS k ON k.customer_id = i.customer_id;

-- pbi_fct_customer_day -------------------------------------------------------------------
-- Grain: one identified customer x purchase day (from fct_customer_day).
CREATE OR REPLACE TABLE pbi_fct_customer_day AS
SELECT k.customer_key, d.purchase_date, d.purchase_month,
       CAST(d.qualifying_invoices AS BIGINT)               AS qualifying_invoices,
       CAST(d.gross_product_value AS DECIMAL(18, 3))       AS gross_product_value
FROM fct_customer_day AS d
JOIN pbi_customer_key_map AS k ON k.customer_id = d.customer_id;

-- pbi_agg_value_class_month -----------------------------------------------------------------
-- Grain: month x transaction_class x invoice_type x has_customer_id x is_extreme_reversal
-- (monthly aggregate design). Month = month of the line timestamp, as in bq1_value_bridge.
-- value_positive keeps the unclassified-ratio denominator exact (positive lines only).
CREATE OR REPLACE TABLE pbi_agg_value_class_month AS
SELECT
    CAST(date_trunc('month', invoice_ts) AS DATE)                    AS month_start,
    transaction_class,
    value_group,
    invoice_type,
    has_customer_id,
    is_extreme_reversal,
    COUNT(*)                                                         AS line_count,
    CAST(SUM(line_value) AS DECIMAL(18, 3))                                         AS value_total,
    CAST(COALESCE(SUM(line_value) FILTER (WHERE line_value > 0), 0) AS DECIMAL(18, 3)) AS value_positive
FROM stg_transaction_line
GROUP BY ALL;

-- Static reference tables (no relationships in Power BI) -------------------------------------
CREATE OR REPLACE TABLE ref_repeat_summary AS SELECT * FROM bq3_repeat_summary;
CREATE OR REPLACE TABLE ref_time_to_second AS SELECT * FROM kpi_time_to_second_purchase;
CREATE OR REPLACE TABLE ref_driver_decomposition AS SELECT * FROM bq2_driver_decomposition;
CREATE OR REPLACE TABLE ref_customer_flow AS
SELECT * REPLACE (CAST(purchase_days_a AS BIGINT) AS purchase_days_a, CAST(purchase_days_b AS BIGINT) AS purchase_days_b)
FROM bq2_customer_flow;
CREATE OR REPLACE TABLE ref_top_account_sensitivity AS SELECT * FROM bq4_top_account_sensitivity;

-- ref_cohort_presentation ---------------------------------------------------------------------
-- Business purpose: one table for the P3 cohort view, so
-- M1/M3/M6 retention and 90-day repeat sit on one row per cohort with no Power BI
-- relationship between reference tables.
-- Grain: one first-observed cohort month, Dec 2009 - Nov 2011 (24 rows).
-- Sources: kpi_cohort_retention (M1/M3/M6) and bq3_cohort_comparison (90-day), unchanged.
CREATE OR REPLACE TABLE ref_cohort_presentation AS
WITH r AS (
    SELECT cohort_month,
           MAX(active_customers) FILTER (WHERE months_since_first = 1) AS m1_active,
           MAX(retention_rate)   FILTER (WHERE months_since_first = 1) AS m1_retention,
           MAX(active_customers) FILTER (WHERE months_since_first = 3) AS m3_active,
           MAX(retention_rate)   FILTER (WHERE months_since_first = 3) AS m3_retention,
           MAX(active_customers) FILTER (WHERE months_since_first = 6) AS m6_active,
           MAX(retention_rate)   FILTER (WHERE months_since_first = 6) AS m6_retention
    FROM kpi_cohort_retention
    GROUP BY cohort_month
)
SELECT
    b.cohort_month,
    strftime(b.cohort_month, '%b %Y')                                 AS cohort_label,
    CAST(strftime(b.cohort_month, '%Y%m') AS INTEGER)                 AS cohort_sort,
    b.is_observed_base,
    b.cohort_size,
    b.cohort_size >= 100                                              AS meets_min_sample,
    r.m1_active, r.m1_retention,
    r.m3_active, r.m3_retention,
    r.m6_active, r.m6_retention,
    b.eligible_90d,
    b.repeat_90d,
    b.repeat_rate_90d,
    b.eligible_share_90d,
    b.rankable_90d,
    b.rank_90d,
    b.comparison_note
FROM bq3_cohort_comparison AS b
JOIN r ON r.cohort_month = b.cohort_month
ORDER BY b.cohort_month;

-- ref_reconciliation_targets ------------------------------------------------------------------
-- Business purpose: target values for the hidden reconciliation page, taken
-- directly from validated Stage 2-3 views (not from the pbi_* tables).
-- Grain: one KPI x slice.
CREATE OR REPLACE TABLE ref_reconciliation_targets AS
WITH ps AS (SELECT * FROM bq2_period_summary),
br AS (SELECT * FROM bq1_value_bridge),
t AS (
    SELECT 'K01' AS kpi_id, 'Overall Product Value' AS kpi, left(period, 1) AS slice, CAST(overall_value AS DOUBLE) AS target, 'bq2_period_summary' AS source FROM ps
    UNION ALL SELECT 'K02', 'Identified Customer Value', left(period, 1), identified_value, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K03', 'Unidentified Value', left(period, 1), unidentified_value, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K04', 'Customer ID Coverage', left(period, 1), identified_share, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K05', 'Qualifying Invoices', left(period, 1), qualifying_invoices, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K06', 'AIV overall', left(period, 1), aiv_overall, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K07', 'AIV identified', left(period, 1), aiv_identified, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K08', 'Purchasing Customers', left(period, 1), purchasing_customers, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K09', 'Purchase Days', left(period, 1), purchase_days, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K10', 'Purchase Days per Customer', left(period, 1), purchase_days_per_customer, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K11', 'Value per Purchase Day', left(period, 1), value_per_purchase_day, 'bq2_period_summary' FROM ps
    UNION ALL SELECT 'K12', 'Product Cancellation Adjustments', CASE WHEN period = 'Full dataset' THEN 'Full' ELSE left(period, 1) END,
                     cancellation_normalized, 'bq1_value_bridge' FROM br
    UNION ALL SELECT 'K13', 'Net Recorded Product Value', CASE WHEN period = 'Full dataset' THEN 'Full' ELSE left(period, 1) END,
                     net_product_value, 'bq1_value_bridge' FROM br
    UNION ALL SELECT 'K14', 'Cancellation Ratio normalized', CASE WHEN period = 'Full dataset' THEN 'Full' ELSE left(period, 1) END,
                     cancellation_value_ratio_normalized, 'bq1_value_bridge' FROM br
    UNION ALL SELECT 'K15', 'Cancellation Ratio recorded', CASE WHEN period = 'Full dataset' THEN 'Full' ELSE left(period, 1) END,
                     cancellation_value_ratio_recorded, 'bq1_value_bridge' FROM br
    UNION ALL SELECT 'K16', 'Cancellation Ratio unclassified', CASE WHEN period = 'Full dataset' THEN 'Full' ELSE left(period, 1) END,
                     cancellation_ratio_unclassified, 'bq1_value_bridge' FROM br
    UNION ALL SELECT 'K17', 'Non-product Charges & Adjustments', CASE WHEN period = 'Full dataset' THEN 'Full' ELSE left(period, 1) END,
                     non_product_total, 'bq1_value_bridge' FROM br
    UNION ALL SELECT 'K18', 'All-recorded Net Transaction Value', CASE WHEN period = 'Full dataset' THEN 'Full' ELSE left(period, 1) END,
                     all_recorded_net, 'bq1_value_bridge' FROM br
    UNION ALL SELECT 'K19', 'Group customers (window)', left(tenure_group, 1), customers, 'kpi_segmentation_distribution'
              FROM kpi_segmentation_distribution WHERE tenure_group <> 'All customers'
    UNION ALL SELECT 'K20', 'Group gross product value (window)', left(tenure_group, 1), gross_product_value, 'kpi_segmentation_distribution'
              FROM kpi_segmentation_distribution WHERE tenure_group <> 'All customers'
    UNION ALL SELECT 'K21', 'F4 x V3 customers (Group A)', 'A', customers, 'bq4_segment_matrix'
              FROM bq4_segment_matrix WHERE frequency_band LIKE 'F4%' AND value_tier LIKE 'V3%'
    UNION ALL SELECT 'K22', 'F4 x V3 value share (Group A)', 'A', value_share, 'bq4_segment_matrix'
              FROM bq4_segment_matrix WHERE frequency_band LIKE 'F4%' AND value_tier LIKE 'V3%'
    UNION ALL SELECT 'K23', '90-day repeat rate', CASE WHEN population LIKE '1%' THEN 'Headline' ELSE 'All customers' END,
                     repeat_rate, 'bq3_repeat_summary' FROM bq3_repeat_summary WHERE measure LIKE 'a%'
    UNION ALL SELECT 'K24', '365-day repeat rate', CASE WHEN population LIKE '1%' THEN 'Headline' ELSE 'All customers' END,
                     repeat_rate, 'bq3_repeat_summary' FROM bq3_repeat_summary WHERE measure LIKE 'b%'
)
SELECT * FROM t WHERE slice IN ('A', 'B', 'Full', 'Headline', 'All customers') ORDER BY kpi_id, slice;
