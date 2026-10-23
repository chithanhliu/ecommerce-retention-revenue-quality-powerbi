-- =============================================================================
-- 21_powerbi_checks.sql — Stage 4: validation of the Power BI exports.
-- Grains, keys, relationships (FK coverage), value and denominator reconciliation with
-- Stage 2-3, and the public-safety rule (no raw identifiers in exported tables).
-- Result: table pbi_checks (check_no, area, check_name, expected, actual, passed).
-- =============================================================================
CREATE OR REPLACE TABLE pbi_checks AS
WITH
inv AS (SELECT i.*, m.period FROM pbi_fct_invoice AS i JOIN pbi_dim_month AS m ON m.month_start = i.invoice_month),
cd  AS (SELECT d.*, m.period FROM pbi_fct_customer_day AS d JOIN pbi_dim_month AS m ON m.month_start = d.purchase_month),
agg AS (SELECT a.*, m.period FROM pbi_agg_value_class_month AS a JOIN pbi_dim_month AS m ON m.month_start = a.month_start),
-- Cancellation ratios rebuilt from the monthly aggregate (monthly aggregate design), per period and full dataset
ratios AS (
    SELECT COALESCE(period, 'Full') AS slice,
           ROUND(-SUM(value_total) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION' AND NOT is_extreme_reversal)
                 / SUM(value_total) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE' AND NOT is_extreme_reversal), 4) AS r_norm,
           ROUND(-SUM(value_total) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION')
                 / SUM(value_total) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE'), 4)                             AS r_rec,
           ROUND(-SUM(value_total) FILTER (WHERE invoice_type = 'CANCELLATION')
                 / SUM(value_positive) FILTER (WHERE invoice_type = 'STANDARD'), 4)                                     AS r_uncl
    FROM agg GROUP BY ROLLUP (period)
),
bridge AS (
    SELECT CASE WHEN period = 'Full dataset' THEN 'Full' ELSE left(period, 1) END AS slice,
           cancellation_value_ratio_normalized AS r_norm, cancellation_value_ratio_recorded AS r_rec,
           cancellation_ratio_unclassified AS r_uncl
    FROM bq1_value_bridge
),
seg AS (SELECT * FROM pbi_dim_customer WHERE tenure_group_window IS NOT NULL),
forbidden AS (
    SELECT table_name, column_name FROM information_schema.columns
    WHERE (table_name LIKE 'pbi\_%' ESCAPE '\' OR table_name LIKE 'ref\_%' ESCAPE '\')
      AND table_name NOT IN ('pbi_customer_key_map', 'pbi_checks')
      AND lower(column_name) IN ('customer_id', 'invoice_no', 'invoice', 'stock_code', 'stockcode', 'description', 'line_id', 'source_row')
),
checks AS (
    -- Grains and keys
    SELECT 1 AS check_no, 'Grain & keys' AS area, 'pbi_dim_month: rows / distinct months / months in period C' AS check_name,
           '25 / 25 / 1' AS expected,
           (SELECT CAST(COUNT(*) AS VARCHAR) || ' / ' || CAST(COUNT(DISTINCT month_start) AS VARCHAR) || ' / '
                   || CAST(COUNT(*) FILTER (WHERE period = 'C') AS VARCHAR) FROM pbi_dim_month) AS actual
    UNION ALL SELECT 2, 'Grain & keys', 'pbi_dim_date: rows / distinct dates / dates whose month is missing from dim_month',
           '739 / 739 / 0',
           (SELECT CAST(COUNT(*) AS VARCHAR) || ' / ' || CAST(COUNT(DISTINCT date) AS VARCHAR) || ' / '
                   || CAST(COUNT(*) FILTER (WHERE month_start NOT IN (SELECT month_start FROM pbi_dim_month)) AS VARCHAR)
            FROM pbi_dim_date)
    UNION ALL SELECT 3, 'Grain & keys', 'pbi_dim_customer: rows / distinct keys / key-0 rows / max key',
           '5943 / 5943 / 1 / 5942',
           (SELECT CAST(COUNT(*) AS VARCHAR) || ' / ' || CAST(COUNT(DISTINCT customer_key) AS VARCHAR) || ' / '
                   || CAST(COUNT(*) FILTER (WHERE customer_key = 0) AS VARCHAR) || ' / ' || CAST(MAX(customer_key) AS VARCHAR)
            FROM pbi_dim_customer)
    UNION ALL SELECT 4, 'Grain & keys', 'Key map is one-to-one (distinct IDs / distinct keys / rows)',
           '5942 / 5942 / 5942',
           (SELECT CAST(COUNT(DISTINCT customer_id) AS VARCHAR) || ' / ' || CAST(COUNT(DISTINCT customer_key) AS VARCHAR)
                   || ' / ' || CAST(COUNT(*) AS VARCHAR) FROM pbi_customer_key_map)
    UNION ALL SELECT 5, 'Grain & keys', 'pbi_fct_invoice: rows / key-0 rows (= invoices without Customer ID in fct_invoice)',
           '53628 / ' || CAST((SELECT COUNT(*) FROM fct_invoice WHERE customer_id IS NULL) AS VARCHAR),
           (SELECT CAST(COUNT(*) AS VARCHAR) || ' / ' || CAST(COUNT(*) FILTER (WHERE customer_key = 0) AS VARCHAR) FROM pbi_fct_invoice)
    UNION ALL SELECT 6, 'Grain & keys', 'pbi_fct_customer_day: rows / key-0 rows / duplicate key x date',
           '32876 / 0 / 0',
           (SELECT CAST(COUNT(*) AS VARCHAR) || ' / ' || CAST(COUNT(*) FILTER (WHERE customer_key = 0) AS VARCHAR) || ' / '
                   || CAST(COUNT(*) - COUNT(DISTINCT (customer_key, purchase_date)) AS VARCHAR) FROM pbi_fct_customer_day)
    -- Relationships (many-to-one coverage)
    UNION ALL SELECT 7, 'Relationships', 'Fact rows with no matching dimension row (invoice key / invoice date / customer-day key / customer-day date / agg month)',
           '0 / 0 / 0 / 0 / 0',
           CAST((SELECT COUNT(*) FROM pbi_fct_invoice WHERE customer_key NOT IN (SELECT customer_key FROM pbi_dim_customer)) AS VARCHAR) || ' / '
           || CAST((SELECT COUNT(*) FROM pbi_fct_invoice WHERE invoice_date NOT IN (SELECT date FROM pbi_dim_date)) AS VARCHAR) || ' / '
           || CAST((SELECT COUNT(*) FROM pbi_fct_customer_day WHERE customer_key NOT IN (SELECT customer_key FROM pbi_dim_customer)) AS VARCHAR) || ' / '
           || CAST((SELECT COUNT(*) FROM pbi_fct_customer_day WHERE purchase_date NOT IN (SELECT date FROM pbi_dim_date)) AS VARCHAR) || ' / '
           || CAST((SELECT COUNT(*) FROM pbi_agg_value_class_month WHERE month_start NOT IN (SELECT month_start FROM pbi_dim_month)) AS VARCHAR)
    UNION ALL SELECT 8, 'Relationships', 'invoice_month = month of invoice_date (rows differing) — fact month and dim_date month agree',
           '0', CAST((SELECT COUNT(*) FROM pbi_fct_invoice WHERE invoice_month <> CAST(date_trunc('month', invoice_date) AS DATE)) AS VARCHAR)
    -- Values reconcile with Stage 2
    UNION ALL SELECT 9, 'Values', 'pbi_fct_invoice totals = fct_invoice (all-recorded / normalized gross)',
           (SELECT CAST(SUM(all_recorded_value) AS VARCHAR) || ' / ' || CAST(SUM(gross_product_value) AS VARCHAR) FROM fct_invoice),
           (SELECT CAST(SUM(all_recorded_value) AS VARCHAR) || ' / ' || CAST(SUM(gross_product_value) AS VARCHAR) FROM pbi_fct_invoice)
    UNION ALL SELECT 10, 'Values', 'pbi_agg_value_class_month: lines / total value = staging (1,044,848 / £18,909,762.118)',
           '1044848 / 18909762.118',
           (SELECT CAST(SUM(line_count) AS VARCHAR) || ' / ' || CAST(SUM(value_total) AS VARCHAR) FROM pbi_agg_value_class_month)
    UNION ALL SELECT 11, 'Values', 'Customer-day value = fct_customer_day; identified value same from both facts (V-2)',
           (SELECT CAST(SUM(gross_product_value) AS VARCHAR) FROM fct_customer_day) || ' / '
           || (SELECT CAST(SUM(gross_product_value) AS VARCHAR) FROM fct_customer_day),
           (SELECT CAST(SUM(gross_product_value) AS VARCHAR) FROM pbi_fct_customer_day) || ' / '
           || (SELECT CAST(SUM(gross_product_value) FILTER (WHERE customer_key <> 0) AS VARCHAR) FROM pbi_fct_invoice)
    -- Period reconciliation with Stage 3 (bq2_period_summary)
    UNION ALL SELECT 12, 'Periods', 'Overall / identified value, Period A',
           (SELECT CAST(overall_value AS VARCHAR) || ' / ' || CAST(identified_value AS VARCHAR) FROM bq2_period_summary WHERE period LIKE 'A%'),
           (SELECT CAST(SUM(gross_product_value) AS VARCHAR) || ' / ' || CAST(SUM(gross_product_value) FILTER (WHERE customer_key <> 0) AS VARCHAR)
            FROM inv WHERE period = 'A')
    UNION ALL SELECT 13, 'Periods', 'Overall / identified value, Period B',
           (SELECT CAST(overall_value AS VARCHAR) || ' / ' || CAST(identified_value AS VARCHAR) FROM bq2_period_summary WHERE period LIKE 'B%'),
           (SELECT CAST(SUM(gross_product_value) AS VARCHAR) || ' / ' || CAST(SUM(gross_product_value) FILTER (WHERE customer_key <> 0) AS VARCHAR)
            FROM inv WHERE period = 'B')
    UNION ALL SELECT 14, 'Periods', 'Purchasing customers / purchase days / qualifying invoices, A and B',
           (SELECT string_agg(CAST(purchasing_customers AS VARCHAR) || '-' || CAST(purchase_days AS VARCHAR) || '-'
                              || CAST(qualifying_invoices AS VARCHAR), ' | ' ORDER BY period) FROM bq2_period_summary),
           (SELECT string_agg(x, ' | ' ORDER BY period) FROM (
                SELECT c.period, CAST(c.n_cust AS VARCHAR) || '-' || CAST(c.n_days AS VARCHAR) || '-' || CAST(i.n_inv AS VARCHAR) AS x
                FROM (SELECT period, COUNT(DISTINCT customer_key) AS n_cust, COUNT(*) AS n_days FROM cd
                      WHERE period IN ('A', 'B') GROUP BY period) AS c
                JOIN (SELECT period, COUNT(*) FILTER (WHERE is_qualifying_purchase) AS n_inv FROM inv GROUP BY period) AS i
                  ON i.period = c.period))
    -- Cancellation ratios: A, B and full dataset (normalized | recorded | unclassified)
    UNION ALL SELECT 15, 'Cancellation ratios', 'Period A: normalized | recorded | unclassified = bq1_value_bridge',
           (SELECT CAST(r_norm AS VARCHAR) || ' | ' || CAST(r_rec AS VARCHAR) || ' | ' || CAST(r_uncl AS VARCHAR) FROM bridge WHERE slice = 'A'),
           (SELECT CAST(r_norm AS VARCHAR) || ' | ' || CAST(r_rec AS VARCHAR) || ' | ' || CAST(r_uncl AS VARCHAR) FROM ratios WHERE slice = 'A')
    UNION ALL SELECT 16, 'Cancellation ratios', 'Period B: normalized | recorded | unclassified = bq1_value_bridge',
           (SELECT CAST(r_norm AS VARCHAR) || ' | ' || CAST(r_rec AS VARCHAR) || ' | ' || CAST(r_uncl AS VARCHAR) FROM bridge WHERE slice = 'B'),
           (SELECT CAST(r_norm AS VARCHAR) || ' | ' || CAST(r_rec AS VARCHAR) || ' | ' || CAST(r_uncl AS VARCHAR) FROM ratios WHERE slice = 'B')
    UNION ALL SELECT 17, 'Cancellation ratios', 'Full dataset: normalized | recorded | unclassified = bq1_value_bridge',
           (SELECT CAST(r_norm AS VARCHAR) || ' | ' || CAST(r_rec AS VARCHAR) || ' | ' || CAST(r_uncl AS VARCHAR) FROM bridge WHERE slice = 'Full'),
           (SELECT CAST(r_norm AS VARCHAR) || ' | ' || CAST(r_rec AS VARCHAR) || ' | ' || CAST(r_uncl AS VARCHAR) FROM ratios WHERE slice = 'Full')
    -- Segmentation (window Dec 2010 - Nov 2011)
    UNION ALL SELECT 18, 'Segmentation', 'Group A / B customers and gross value from pbi_dim_customer = Stage 2',
           (SELECT string_agg(CAST(customers AS VARCHAR) || '-' || CAST(gross_product_value AS VARCHAR), ' | ' ORDER BY tenure_group)
            FROM kpi_segmentation_distribution WHERE tenure_group <> 'All customers'),
           (SELECT string_agg(CAST(n AS VARCHAR) || '-' || CAST(v AS VARCHAR), ' | ' ORDER BY g)
            FROM (SELECT tenure_group_window AS g, COUNT(*) AS n, SUM(gross_product_value_window) AS v FROM seg GROUP BY g))
    UNION ALL SELECT 19, 'Segmentation', 'F4 x V3 customers / value share of Group A = bq4_segment_matrix',
           (SELECT CAST(customers AS VARCHAR) || ' / ' || CAST(value_share AS VARCHAR) FROM bq4_segment_matrix
            WHERE frequency_band LIKE 'F4%' AND value_tier LIKE 'V3%'),
           (SELECT CAST(COUNT(*) FILTER (WHERE frequency_band_window LIKE 'F4%' AND value_tier_window LIKE 'V3%') AS VARCHAR) || ' / '
                   || CAST(ROUND(SUM(gross_product_value_window) FILTER (WHERE frequency_band_window LIKE 'F4%' AND value_tier_window LIKE 'V3%')
                                 / SUM(gross_product_value_window), 4) AS VARCHAR)
            FROM seg WHERE tenure_group_window = 'A')
    UNION ALL SELECT 20, 'Segmentation', 'Group A segment AIV (identified invoices) = Stage 2 (£487.70)',
           (SELECT CAST(average_invoice_value_identified AS VARCHAR) FROM kpi_segmentation_distribution WHERE tenure_group LIKE 'A %'),
           (SELECT CAST(ROUND(SUM(gross_product_value_window) / SUM(qualifying_invoices_window), 2) AS VARCHAR)
            FROM seg WHERE tenure_group_window = 'A')
    -- Cohort presentation table
    UNION ALL SELECT 21, 'Cohort presentation', 'Rows / headline 90-day eligible / repeaters (excl. observed base) = bq3_repeat_summary',
           '24 / ' || (SELECT CAST(eligible_customers AS VARCHAR) || ' / ' || CAST(repeat_customers AS VARCHAR)
                       FROM bq3_repeat_summary WHERE population LIKE '1%' AND measure LIKE 'a%'),
           (SELECT CAST(COUNT(*) AS VARCHAR) || ' / ' || CAST(SUM(eligible_90d) FILTER (WHERE NOT is_observed_base) AS VARCHAR)
                   || ' / ' || CAST(SUM(repeat_90d) FILTER (WHERE NOT is_observed_base) AS VARCHAR) FROM ref_cohort_presentation)
    UNION ALL SELECT 22, 'Cohort presentation', 'M1/M3/M6 rates and active counts differ from kpi_cohort_retention (cells)',
           '0', CAST((SELECT COUNT(*) FROM ref_cohort_presentation AS p
                      JOIN kpi_cohort_retention AS k ON k.cohort_month = p.cohort_month
                      WHERE (k.months_since_first = 1 AND (k.retention_rate IS DISTINCT FROM p.m1_retention OR k.active_customers IS DISTINCT FROM p.m1_active))
                         OR (k.months_since_first = 3 AND (k.retention_rate IS DISTINCT FROM p.m3_retention OR k.active_customers IS DISTINCT FROM p.m3_active))
                         OR (k.months_since_first = 6 AND (k.retention_rate IS DISTINCT FROM p.m6_retention OR k.active_customers IS DISTINCT FROM p.m6_active))) AS VARCHAR)
    UNION ALL SELECT 23, 'Cohort presentation', 'Unobserved months stay NULL (cells with a value but month after Nov 2011)',
           '0', CAST((SELECT COUNT(*) FROM ref_cohort_presentation
                      WHERE (m1_retention IS NOT NULL AND cohort_month + INTERVAL 1 MONTH > DATE '2011-11-01')
                         OR (m3_retention IS NOT NULL AND cohort_month + INTERVAL 3 MONTH > DATE '2011-11-01')
                         OR (m6_retention IS NOT NULL AND cohort_month + INTERVAL 6 MONTH > DATE '2011-11-01')) AS VARCHAR)
    -- Reference tables copied unchanged
    UNION ALL SELECT 24, 'Reference tables', 'Row counts: repeat / time-to-2nd / drivers / flow / top-account = sources',
           CAST((SELECT COUNT(*) FROM bq3_repeat_summary) AS VARCHAR) || ' / ' || CAST((SELECT COUNT(*) FROM kpi_time_to_second_purchase) AS VARCHAR)
           || ' / ' || CAST((SELECT COUNT(*) FROM bq2_driver_decomposition) AS VARCHAR) || ' / ' || CAST((SELECT COUNT(*) FROM bq2_customer_flow) AS VARCHAR)
           || ' / ' || CAST((SELECT COUNT(*) FROM bq4_top_account_sensitivity) AS VARCHAR),
           CAST((SELECT COUNT(*) FROM ref_repeat_summary) AS VARCHAR) || ' / ' || CAST((SELECT COUNT(*) FROM ref_time_to_second) AS VARCHAR)
           || ' / ' || CAST((SELECT COUNT(*) FROM ref_driver_decomposition) AS VARCHAR) || ' / ' || CAST((SELECT COUNT(*) FROM ref_customer_flow) AS VARCHAR)
           || ' / ' || CAST((SELECT COUNT(*) FROM ref_top_account_sensitivity) AS VARCHAR)
    UNION ALL SELECT 25, 'Reference tables', 'Reconciliation targets: rows / NULL targets',
           '53 / 0', (SELECT CAST(COUNT(*) AS VARCHAR) || ' / ' || CAST(COUNT(*) FILTER (WHERE target IS NULL) AS VARCHAR) FROM ref_reconciliation_targets)
    -- Public safety
    UNION ALL SELECT 26, 'Public safety', 'Identifier columns in pbi_* / ref_* export tables',
           'none', COALESCE((SELECT string_agg(table_name || '.' || column_name, ', ') FROM forbidden), 'none')
)
SELECT check_no, area, check_name, expected, actual, expected = actual AS passed
FROM checks
ORDER BY check_no;
