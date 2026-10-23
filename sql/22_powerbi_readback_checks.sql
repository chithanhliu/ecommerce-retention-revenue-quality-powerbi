-- =============================================================================
-- 22_powerbi_readback_checks.sql — Power BI export: Parquet read-back checks.
-- Runs AFTER the Parquet export. scripts/run_pipeline.py first creates one temp view
-- per exported file, pq_<table> = read_parquet('data/powerbi/<table>.parquet'), so every
-- check below reads the FILES, not the DuckDB tables they came from.
-- Each check compares file content with the validated Stage 2-3 source (or proves
-- structure: types, NULL keys, uniqueness at grain, orphan keys via NOT EXISTS).
-- Result: table pbi_readback_checks (check_no, area, check_name, expected, actual, passed).
-- =============================================================================
CREATE OR REPLACE TABLE pbi_readback_checks AS
WITH
-- Column name + type of every exported file vs its source table (same order)
cols_file AS (
    SELECT substr(table_name, 4) AS t, column_name, data_type, ordinal_position
    FROM information_schema.columns WHERE table_name LIKE 'pq\_%' ESCAPE '\'
),
cols_src AS (
    SELECT table_name AS t, column_name, data_type, ordinal_position
    FROM information_schema.columns
    WHERE table_name IN (SELECT DISTINCT t FROM cols_file) AND table_schema = 'main'
),
inv AS (SELECT i.*, m.period FROM pq_pbi_fct_invoice AS i JOIN pq_pbi_dim_month AS m ON m.month_start = i.invoice_month),
cd  AS (SELECT d.*, m.period FROM pq_pbi_fct_customer_day AS d
        JOIN pq_pbi_dim_date AS dt ON dt.date = d.purchase_date
        JOIN pq_pbi_dim_month AS m ON m.month_start = dt.month_start),
agg AS (SELECT a.*, m.period FROM pq_pbi_agg_value_class_month AS a JOIN pq_pbi_dim_month AS m ON m.month_start = a.month_start),
file_period AS (   -- product values per period read from the invoice file
    SELECT period,
           SUM(gross_product_value)                                      AS gross,
           SUM(product_cancellation_value)                               AS cancel,
           SUM(gross_product_value) + SUM(product_cancellation_value)    AS net
    FROM inv GROUP BY period
),
file_ratios AS (
    SELECT COALESCE(period, 'Full') AS slice,
           ROUND(-SUM(value_total) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION' AND NOT is_extreme_reversal)
                 / SUM(value_total) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE' AND NOT is_extreme_reversal), 4) AS r_norm,
           ROUND(-SUM(value_total) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION')
                 / SUM(value_total) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE'), 4)                             AS r_rec,
           ROUND(-SUM(value_total) FILTER (WHERE invoice_type = 'CANCELLATION')
                 / SUM(value_positive) FILTER (WHERE invoice_type = 'STANDARD'), 4)                                     AS r_uncl
    FROM agg GROUP BY ROLLUP (period)
),
src_ratios AS (
    SELECT CASE WHEN period = 'Full dataset' THEN 'Full' ELSE left(period, 1) END AS slice,
           cancellation_value_ratio_normalized AS r_norm, cancellation_value_ratio_recorded AS r_rec,
           cancellation_ratio_unclassified AS r_uncl
    FROM bq1_value_bridge
),
fmt_ratio AS (
    SELECT 'file' AS src, string_agg(slice || ' ' || CAST(r_norm AS VARCHAR) || '/' || CAST(r_rec AS VARCHAR) || '/' || CAST(r_uncl AS VARCHAR), ' | ' ORDER BY slice) AS s
    FROM file_ratios WHERE slice IN ('A', 'B', 'Full')
    UNION ALL
    SELECT 'src', string_agg(slice || ' ' || CAST(r_norm AS VARCHAR) || '/' || CAST(r_rec AS VARCHAR) || '/' || CAST(r_uncl AS VARCHAR), ' | ' ORDER BY slice)
    FROM src_ratios WHERE slice IN ('A', 'B', 'Full')
),
-- Surrogate keys resolved back to Customer IDs through the private key map (DuckDB only)
cd_resolved AS (
    SELECT k.customer_id, d.purchase_date, d.qualifying_invoices, d.gross_product_value
    FROM pq_pbi_fct_customer_day AS d JOIN pbi_customer_key_map AS k ON k.customer_key = d.customer_key
),
dim_resolved AS (
    SELECT k.customer_id, d.*
    FROM pq_pbi_dim_customer AS d JOIN pbi_customer_key_map AS k ON k.customer_key = d.customer_key
),
checks AS (
    -- 1. Structure: names, order and types identical to the source tables
    SELECT 1 AS check_no, 'Structure' AS area, 'Files read back / columns whose name, position or type differ from source table' AS check_name,
           '13 / 0' AS expected,
           CAST((SELECT COUNT(DISTINCT t) FROM cols_file) AS VARCHAR) || ' / '
           || CAST((SELECT COUNT(*) FROM (
                (SELECT * FROM cols_file EXCEPT SELECT * FROM cols_src)
                UNION ALL
                (SELECT * FROM cols_src EXCEPT SELECT * FROM cols_file))) AS VARCHAR) AS actual
    UNION ALL SELECT 2, 'Structure', 'Key types in files: value DECIMAL(18,3) / dates DATE / keys INTEGER',
           'DECIMAL(18,3) / DATE,DATE,DATE,DATE / INTEGER,INTEGER',
           (SELECT data_type FROM cols_file WHERE t = 'pbi_fct_invoice' AND column_name = 'gross_product_value') || ' / '
           || (SELECT string_agg(data_type, ',' ORDER BY t, column_name) FROM cols_file
               WHERE (t, column_name) IN (('pbi_fct_invoice', 'invoice_date'), ('pbi_fct_customer_day', 'purchase_date'),
                                          ('pbi_dim_date', 'date'), ('pbi_dim_month', 'month_start'))) || ' / '
           || (SELECT string_agg(data_type, ',' ORDER BY t) FROM cols_file
               WHERE column_name = 'customer_key' AND t IN ('pbi_fct_invoice', 'pbi_dim_customer'))
    -- 2. NULL keys (each listed separately)
    UNION ALL SELECT 3, 'NULL keys', 'NULLs: invoice key | invoice date | cust-day key | cust-day date | dim cust key | dim date | dim month | agg month | agg class',
           '0|0|0|0|0|0|0|0|0',
           CAST((SELECT COUNT(*) FROM pq_pbi_fct_invoice WHERE customer_key IS NULL) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_fct_invoice WHERE invoice_date IS NULL) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_fct_customer_day WHERE customer_key IS NULL) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_fct_customer_day WHERE purchase_date IS NULL) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_dim_customer WHERE customer_key IS NULL) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_dim_date WHERE date IS NULL OR month_start IS NULL) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_dim_month WHERE month_start IS NULL OR period IS NULL) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_agg_value_class_month WHERE month_start IS NULL) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_agg_value_class_month WHERE transaction_class IS NULL OR invoice_type IS NULL) AS VARCHAR)
    -- 3. Uniqueness at the stated grain
    UNION ALL SELECT 4, 'Uniqueness', 'Duplicates at grain: dim customer | dim date | dim month | cust-day (key,date) | agg 5-part grain | cohort month | target (kpi,slice)',
           '0|0|0|0|0|0|0',
           CAST((SELECT COUNT(*) - COUNT(DISTINCT customer_key) FROM pq_pbi_dim_customer) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) - COUNT(DISTINCT date) FROM pq_pbi_dim_date) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) - COUNT(DISTINCT month_start) FROM pq_pbi_dim_month) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) - COUNT(DISTINCT (customer_key, purchase_date)) FROM pq_pbi_fct_customer_day) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) - COUNT(DISTINCT (month_start, transaction_class, invoice_type, has_customer_id, is_extreme_reversal))
                    FROM pq_pbi_agg_value_class_month) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) - COUNT(DISTINCT cohort_month) FROM pq_ref_cohort_presentation) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) - COUNT(DISTINCT (kpi_id, slice)) FROM pq_ref_reconciliation_targets) AS VARCHAR)
    -- 4. Orphan keys (NOT EXISTS anti-joins)
    UNION ALL SELECT 5, 'Orphan keys', 'Orphans: invoice->customer | invoice->date | cust-day->customer | cust-day->date | date->month | agg->month',
           '0|0|0|0|0|0',
           CAST((SELECT COUNT(*) FROM pq_pbi_fct_invoice AS f WHERE NOT EXISTS (SELECT 1 FROM pq_pbi_dim_customer AS d WHERE d.customer_key = f.customer_key)) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_fct_invoice AS f WHERE NOT EXISTS (SELECT 1 FROM pq_pbi_dim_date AS d WHERE d.date = f.invoice_date)) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_fct_customer_day AS f WHERE NOT EXISTS (SELECT 1 FROM pq_pbi_dim_customer AS d WHERE d.customer_key = f.customer_key)) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_fct_customer_day AS f WHERE NOT EXISTS (SELECT 1 FROM pq_pbi_dim_date AS d WHERE d.date = f.purchase_date)) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_dim_date AS f WHERE NOT EXISTS (SELECT 1 FROM pq_pbi_dim_month AS d WHERE d.month_start = f.month_start)) AS VARCHAR) || '|'
           || CAST((SELECT COUNT(*) FROM pq_pbi_agg_value_class_month AS f WHERE NOT EXISTS (SELECT 1 FROM pq_pbi_dim_month AS d WHERE d.month_start = f.month_start)) AS VARCHAR)
    -- 5. Surrogate keys and unknown member
    UNION ALL SELECT 6, 'Surrogate keys', 'Unknown member: key-0 rows in dim (flagged unidentified) | key-0 invoices | key-0 customer-days',
           '1 | ' || CAST((SELECT COUNT(*) FROM fct_invoice WHERE customer_id IS NULL) AS VARCHAR) || ' | 0',
           CAST((SELECT COUNT(*) FROM pq_pbi_dim_customer WHERE customer_key = 0 AND is_unidentified) AS VARCHAR) || ' | '
           || CAST((SELECT COUNT(*) FROM pq_pbi_fct_invoice WHERE customer_key = 0) AS VARCHAR) || ' | '
           || CAST((SELECT COUNT(*) FROM pq_pbi_fct_customer_day WHERE customer_key = 0) AS VARCHAR)
    UNION ALL SELECT 7, 'Surrogate keys', 'Keys 1..n contiguous for identified customers (count / min / max)',
           '5942 / 1 / 5942',
           (SELECT CAST(COUNT(*) AS VARCHAR) || ' / ' || CAST(MIN(customer_key) AS VARCHAR) || ' / ' || CAST(MAX(customer_key) AS VARCHAR)
            FROM pq_pbi_dim_customer WHERE customer_key > 0)
    UNION ALL SELECT 8, 'Surrogate keys', 'Customer-day file resolved via key map = fct_customer_day (rows differing, both directions)',
           '0', CAST((SELECT COUNT(*) FROM (
                (SELECT customer_id, purchase_date, qualifying_invoices, gross_product_value FROM cd_resolved
                 EXCEPT SELECT customer_id, purchase_date, qualifying_invoices, gross_product_value FROM fct_customer_day)
                UNION ALL
                (SELECT customer_id, purchase_date, qualifying_invoices, gross_product_value FROM fct_customer_day
                 EXCEPT SELECT customer_id, purchase_date, qualifying_invoices, gross_product_value FROM cd_resolved))) AS VARCHAR)
    UNION ALL SELECT 9, 'Surrogate keys', 'Customer file window segment resolved via key map = bq4_customer_segment (rows differing)',
           '0', CAST((SELECT COUNT(*) FROM (
                (SELECT customer_id, frequency_band_window, value_tier_window, gross_product_value_window, purchase_days_window
                 FROM dim_resolved WHERE tenure_group_window IS NOT NULL
                 EXCEPT SELECT customer_id, frequency_band, value_tier, gross_product_value, purchase_days FROM bq4_customer_segment)
                UNION ALL
                (SELECT customer_id, frequency_band, value_tier, gross_product_value, purchase_days FROM bq4_customer_segment
                 EXCEPT SELECT customer_id, frequency_band_window, value_tier_window, gross_product_value_window, purchase_days_window
                 FROM dim_resolved WHERE tenure_group_window IS NOT NULL))) AS VARCHAR)
    -- 6. Values by period, read from files vs validated sources
    UNION ALL SELECT 10, 'Values (file)', 'Period A gross / product cancellations / net product = bq1_value_bridge',
           (SELECT CAST(gross_normalized AS VARCHAR) || ' / ' || CAST(cancellation_normalized AS VARCHAR) || ' / ' || CAST(net_product_value AS VARCHAR)
            FROM bq1_value_bridge WHERE period LIKE 'A%'),
           (SELECT CAST(gross AS VARCHAR) || ' / ' || CAST(cancel AS VARCHAR) || ' / ' || CAST(net AS VARCHAR) FROM file_period WHERE period = 'A')
    UNION ALL SELECT 11, 'Values (file)', 'Period B gross / product cancellations / net product = bq1_value_bridge',
           (SELECT CAST(gross_normalized AS VARCHAR) || ' / ' || CAST(cancellation_normalized AS VARCHAR) || ' / ' || CAST(net_product_value AS VARCHAR)
            FROM bq1_value_bridge WHERE period LIKE 'B%'),
           (SELECT CAST(gross AS VARCHAR) || ' / ' || CAST(cancel AS VARCHAR) || ' / ' || CAST(net AS VARCHAR) FROM file_period WHERE period = 'B')
    UNION ALL SELECT 12, 'Values (file)', 'Identified value A | B (invoice file, key <> 0) = bq2_period_summary',
           (SELECT string_agg(CAST(identified_value AS VARCHAR), ' | ' ORDER BY period) FROM bq2_period_summary),
           (SELECT string_agg(CAST(v AS VARCHAR), ' | ' ORDER BY period) FROM (
                SELECT period, SUM(gross_product_value) FILTER (WHERE customer_key <> 0) AS v FROM inv
                WHERE period IN ('A', 'B') GROUP BY period))
    UNION ALL SELECT 13, 'Values (file)', 'Purchasing customers - purchase days, A | B (customer-day file) = bq2_period_summary',
           (SELECT string_agg(CAST(purchasing_customers AS VARCHAR) || '-' || CAST(purchase_days AS VARCHAR), ' | ' ORDER BY period) FROM bq2_period_summary),
           (SELECT string_agg(CAST(n AS VARCHAR) || '-' || CAST(d AS VARCHAR), ' | ' ORDER BY period) FROM (
                SELECT period, COUNT(DISTINCT customer_key) AS n, COUNT(*) AS d FROM cd WHERE period IN ('A', 'B') GROUP BY period))
    UNION ALL SELECT 14, 'Values (file)', 'Group A | B customers - gross value (customer file) = kpi_segmentation_distribution',
           (SELECT string_agg(CAST(customers AS VARCHAR) || '-' || CAST(gross_product_value AS VARCHAR), ' | ' ORDER BY tenure_group)
            FROM kpi_segmentation_distribution WHERE tenure_group <> 'All customers'),
           (SELECT string_agg(CAST(n AS VARCHAR) || '-' || CAST(v AS VARCHAR), ' | ' ORDER BY g) FROM (
                SELECT tenure_group_window AS g, COUNT(*) AS n, SUM(gross_product_value_window) AS v
                FROM pq_pbi_dim_customer WHERE tenure_group_window IS NOT NULL GROUP BY g))
    UNION ALL SELECT 15, 'Values (file)', 'Cancellation ratios norm/rec/uncl for A | B | Full (agg file) = bq1_value_bridge',
           (SELECT s FROM fmt_ratio WHERE src = 'src'), (SELECT s FROM fmt_ratio WHERE src = 'file')
    -- 7. Reference tables: full content equality with validated sources + headline figures
    UNION ALL SELECT 16, 'Reference (file)', 'ref_repeat_summary file = bq3_repeat_summary (rows differing); headline 90d / 365d rate (n)',
           '0; 0.4091 (4305) / 0.6974 (3331)',
           CAST((SELECT COUNT(*) FROM ((SELECT * FROM pq_ref_repeat_summary EXCEPT SELECT * FROM bq3_repeat_summary)
                 UNION ALL (SELECT * FROM bq3_repeat_summary EXCEPT SELECT * FROM pq_ref_repeat_summary))) AS VARCHAR) || '; '
           || (SELECT string_agg(CAST(repeat_rate AS VARCHAR) || ' (' || CAST(eligible_customers AS VARCHAR) || ')', ' / ' ORDER BY measure)
               FROM pq_ref_repeat_summary WHERE population LIKE '1%' AND measure IN ('a 90-day repeat (all 90-day eligible)', 'b 365-day repeat (all 365-day eligible)'))
    UNION ALL SELECT 17, 'Reference (file)', 'ref_driver_decomposition file = bq2 (rows differing); Shapley C+F+S = total change (abs diff < 0.05)',
           '0; true',
           CAST((SELECT COUNT(*) FROM ((SELECT * FROM pq_ref_driver_decomposition EXCEPT SELECT * FROM bq2_driver_decomposition)
                 UNION ALL (SELECT * FROM bq2_driver_decomposition EXCEPT SELECT * FROM pq_ref_driver_decomposition))) AS VARCHAR) || '; '
           || CAST((SELECT ABS(SUM(contribution_gbp) FILTER (WHERE driver LIKE '_:%') - MAX(contribution_gbp) FILTER (WHERE driver LIKE 'Total%')) < 0.05
                    FROM pq_ref_driver_decomposition) AS VARCHAR)
    UNION ALL SELECT 18, 'Reference (file)', 'ref_top_account_sensitivity file = bq4 (rows differing); F4xV3 share baseline / top1 / top5',
           '0; 0.4982 / 0.4774 / 0.4143',
           CAST((SELECT COUNT(*) FROM ((SELECT * FROM pq_ref_top_account_sensitivity EXCEPT SELECT * FROM bq4_top_account_sensitivity)
                 UNION ALL (SELECT * FROM bq4_top_account_sensitivity EXCEPT SELECT * FROM pq_ref_top_account_sensitivity))) AS VARCHAR) || '; '
           || (SELECT string_agg(CAST(f4_v3_value_share AS VARCHAR), ' / ' ORDER BY excluded_customers) FROM pq_ref_top_account_sensitivity)
    UNION ALL SELECT 19, 'Reference (file)', 'ref_cohort_presentation file: 90-day eligible/repeat/rate/rankable differ from bq3_cohort_comparison (cohorts)',
           '0', CAST((SELECT COUNT(*) FROM pq_ref_cohort_presentation AS p JOIN bq3_cohort_comparison AS b ON b.cohort_month = p.cohort_month
                      WHERE p.cohort_size <> b.cohort_size OR p.eligible_90d <> b.eligible_90d OR p.repeat_90d <> b.repeat_90d
                         OR p.repeat_rate_90d IS DISTINCT FROM b.repeat_rate_90d OR p.rankable_90d <> b.rankable_90d
                         OR p.rank_90d IS DISTINCT FROM b.rank_90d) AS VARCHAR)
    UNION ALL SELECT 20, 'Reference (file)', 'ref_cohort_presentation file: M1/M3/M6 cells differ from kpi_cohort_retention; headline eligible / repeaters',
           '0; 4305 / 1761',
           CAST((SELECT COUNT(*) FROM pq_ref_cohort_presentation AS p JOIN kpi_cohort_retention AS k ON k.cohort_month = p.cohort_month
                 WHERE (k.months_since_first = 1 AND (k.retention_rate IS DISTINCT FROM p.m1_retention OR k.active_customers IS DISTINCT FROM p.m1_active))
                    OR (k.months_since_first = 3 AND (k.retention_rate IS DISTINCT FROM p.m3_retention OR k.active_customers IS DISTINCT FROM p.m3_active))
                    OR (k.months_since_first = 6 AND (k.retention_rate IS DISTINCT FROM p.m6_retention OR k.active_customers IS DISTINCT FROM p.m6_active))) AS VARCHAR)
           || '; ' || (SELECT CAST(SUM(eligible_90d) AS VARCHAR) || ' / ' || CAST(SUM(repeat_90d) AS VARCHAR)
                       FROM pq_ref_cohort_presentation WHERE NOT is_observed_base)
    UNION ALL SELECT 21, 'Reference (file)', 'ref_time_to_second and ref_customer_flow files = validated sources (rows differing)',
           '0 / 0',
           CAST((SELECT COUNT(*) FROM ((SELECT * FROM pq_ref_time_to_second EXCEPT SELECT * FROM kpi_time_to_second_purchase)
                 UNION ALL (SELECT * FROM kpi_time_to_second_purchase EXCEPT SELECT * FROM pq_ref_time_to_second))) AS VARCHAR) || ' / '
           || CAST((SELECT COUNT(*) FROM ((SELECT * FROM pq_ref_customer_flow EXCEPT SELECT * FROM bq2_customer_flow)
                 UNION ALL (SELECT * FROM bq2_customer_flow EXCEPT SELECT * FROM pq_ref_customer_flow))) AS VARCHAR)
    UNION ALL SELECT 22, 'Reference (file)', 'ref_reconciliation_targets file = table (rows differing); K01 A target = bq2 overall value A',
           '0; ' || (SELECT CAST(CAST(overall_value AS DOUBLE) AS VARCHAR) FROM bq2_period_summary WHERE period LIKE 'A%'),
           CAST((SELECT COUNT(*) FROM ((SELECT * FROM pq_ref_reconciliation_targets EXCEPT SELECT * FROM ref_reconciliation_targets)
                 UNION ALL (SELECT * FROM ref_reconciliation_targets EXCEPT SELECT * FROM pq_ref_reconciliation_targets))) AS VARCHAR) || '; '
           || (SELECT CAST(target AS VARCHAR) FROM pq_ref_reconciliation_targets WHERE kpi_id = 'K01' AND slice = 'A')
)
SELECT check_no, area, check_name, expected, actual, expected = actual AS passed
FROM checks
ORDER BY check_no;
