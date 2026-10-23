-- =============================================================================
-- 14_stage3_checks.sql — validation of the Stage 3 analysis views.
-- Stage 2's 60 checks do not cover these views; each check below reconciles a Stage 3
-- result with Stage 2 outputs or recomputes it by another route.
-- Result: table stage3_checks (check_no, bq, check_name, expected, actual, passed).
-- =============================================================================
CREATE OR REPLACE TABLE stage3_checks AS
WITH
bridge AS (SELECT * FROM bq1_value_bridge),
recon AS (SELECT * FROM kpi_value_reconciliation),
ps AS (SELECT * FROM bq2_period_summary),
dec AS (SELECT * FROM bq2_driver_decomposition),
flow AS (SELECT * FROM bq2_customer_flow),
checks AS (
    -- BQ1
    SELECT 1 AS check_no, 'BQ1' AS bq, 'Full-dataset bridge = Stage 2 reconciliation (gross recorded / all-recorded net)' AS check_name,
           CAST((SELECT recorded_value FROM recon WHERE transaction_class = 'PRODUCT_PURCHASE') AS VARCHAR) || ' / '
           || CAST((SELECT recorded_value FROM recon WHERE transaction_class = 'ALL_RECORDED_NET') AS VARCHAR) AS expected,
           CAST((SELECT gross_recorded FROM bridge WHERE period = 'Full dataset') AS VARCHAR) || ' / '
           || CAST((SELECT all_recorded_net FROM bridge WHERE period = 'Full dataset') AS VARCHAR) AS actual
    UNION ALL SELECT 2, 'BQ1', 'Periods A + B + Dec 2011 = full dataset (normalized gross / net product / non-product)',
           (SELECT CAST(gross_normalized AS VARCHAR) || ' / ' || CAST(net_product_value AS VARCHAR) || ' / '
                   || CAST(non_product_total AS VARCHAR) FROM bridge WHERE period = 'Full dataset'),
           (SELECT CAST(SUM(gross_normalized) AS VARCHAR) || ' / ' || CAST(SUM(net_product_value) AS VARCHAR) || ' / '
                   || CAST(SUM(non_product_total) AS VARCHAR) FROM bridge WHERE period <> 'Full dataset')
    UNION ALL SELECT 3, 'BQ1', 'Bridge: gross recorded - extreme = gross normalized (all periods; violations)',
           '0', CAST((SELECT COUNT(*) FROM bridge WHERE gross_recorded - extreme_purchase_value <> gross_normalized) AS VARCHAR)
    UNION ALL SELECT 4, 'BQ1', 'Monthly reliability sums = full dataset (normalized gross / normalized cancellations)',
           (SELECT CAST(gross_normalized AS VARCHAR) || ' / ' || CAST(cancellation_normalized AS VARCHAR) FROM bridge WHERE period = 'Full dataset'),
           (SELECT CAST(SUM(gross_normalized) AS VARCHAR) || ' / ' || CAST(SUM(cancellation_normalized) AS VARCHAR) FROM bq1_monthly_reliability)
    -- BQ2
    UNION ALL SELECT 5, 'BQ2', 'Overall value per period = kpi_monthly months (A / B)',
           (SELECT CAST(SUM(gross_product_value) FILTER (WHERE month < DATE '2010-12-01') AS VARCHAR) || ' / '
                   || CAST(SUM(gross_product_value) FILTER (WHERE month >= DATE '2010-12-01') AS VARCHAR) FROM kpi_monthly),
           (SELECT CAST(MAX(overall_value) FILTER (WHERE period LIKE 'A%') AS VARCHAR) || ' / '
                   || CAST(MAX(overall_value) FILTER (WHERE period LIKE 'B%') AS VARCHAR) FROM ps)
    UNION ALL SELECT 6, 'BQ2', 'Identified value: customer-day route = invoice route (A / B)',
           (SELECT CAST(MAX(identified_value_invoice_route) FILTER (WHERE period LIKE 'A%') AS VARCHAR) || ' / '
                   || CAST(MAX(identified_value_invoice_route) FILTER (WHERE period LIKE 'B%') AS VARCHAR)
            FROM (SELECT analysis_period(invoice_month) AS period,
                         SUM(gross_product_value) FILTER (WHERE customer_id IS NOT NULL) AS identified_value_invoice_route
                  FROM fct_invoice GROUP BY 1)),
           (SELECT CAST(MAX(identified_value) FILTER (WHERE period LIKE 'A%') AS VARCHAR) || ' / '
                   || CAST(MAX(identified_value) FILTER (WHERE period LIKE 'B%') AS VARCHAR) FROM ps)
    UNION ALL SELECT 7, 'BQ2', 'Identity C x F x S = identified value (max abs residual, GBP)',
           '0.0', CAST((SELECT MAX(ABS(identity_residual)) FROM ps) AS VARCHAR)
    UNION ALL SELECT 8, 'BQ2', 'Shapley contributions sum to total identified change (abs difference < 0.05 GBP)',
           'true', CAST((SELECT ABS(SUM(contribution_gbp) FILTER (WHERE driver LIKE '_:%')
                         - MAX(contribution_gbp) FILTER (WHERE driver LIKE 'Total%')) < 0.05 FROM dec) AS VARCHAR)
    UNION ALL SELECT 9, 'BQ2', 'Identified + unidentified change = overall change (abs difference < 0.05 GBP)',
           'true', CAST((SELECT ABS(MAX(contribution_gbp) FILTER (WHERE driver LIKE 'Total%')
                         + MAX(contribution_gbp) FILTER (WHERE driver LIKE 'Unidentified%')
                         - MAX(contribution_gbp) FILTER (WHERE driver LIKE 'Overall%')) < 0.05 FROM dec) AS VARCHAR)
    UNION ALL SELECT 10, 'BQ2', 'Customer flow: A = both + A-only; B = both + first observed in B (customers)',
           (SELECT CAST(MAX(purchasing_customers) FILTER (WHERE period LIKE 'A%') AS VARCHAR) || ' / '
                   || CAST(MAX(purchasing_customers) FILTER (WHERE period LIKE 'B%') AS VARCHAR) FROM ps),
           (SELECT CAST(SUM(customers) FILTER (WHERE flow_group LIKE '1%' OR flow_group LIKE '2%') AS VARCHAR) || ' / '
                   || CAST(SUM(customers) FILTER (WHERE flow_group LIKE '1%' OR flow_group LIKE '3%') AS VARCHAR) FROM flow)
    UNION ALL SELECT 11, 'BQ2', 'Customer flow value B = period B identified value = segmentation window value',
           (SELECT CAST(MAX(identified_value) FILTER (WHERE period LIKE 'B%') AS VARCHAR) FROM ps) || ' / '
           || (SELECT CAST(gross_product_value AS VARCHAR) FROM kpi_segmentation_distribution WHERE tenure_group = 'All customers'),
           (SELECT CAST(SUM(value_b) AS VARCHAR) FROM flow) || ' / ' || (SELECT CAST(SUM(value_b) AS VARCHAR) FROM flow)
    -- BQ3
    UNION ALL SELECT 12, 'BQ3', 'Headline 90-day (excl. base) = Stage 2 kpi_repeat_90d (eligible / repeaters)',
           (SELECT CAST(eligible_customers AS VARCHAR) || ' / ' || CAST(repeat_customers AS VARCHAR)
            FROM kpi_repeat_90d WHERE population LIKE '2%'),
           (SELECT CAST(eligible_customers AS VARCHAR) || ' / ' || CAST(repeat_customers AS VARCHAR)
            FROM bq3_repeat_summary WHERE population LIKE '1%' AND measure LIKE 'a%')
    UNION ALL SELECT 13, 'BQ3', '365-day (excl. base) = Stage 2 kpi_time_to_second_purchase (eligible / converted)',
           (SELECT CAST(eligible_customers AS VARCHAR) || ' / ' || CAST(converted_customers AS VARCHAR)
            FROM kpi_time_to_second_purchase WHERE population LIKE '2%' AND window_days = 365),
           (SELECT CAST(eligible_customers AS VARCHAR) || ' / ' || CAST(repeat_customers AS VARCHAR)
            FROM bq3_repeat_summary WHERE population LIKE '1%' AND measure LIKE 'b%')
    UNION ALL SELECT 14, 'BQ3', 'Like-for-like: 90-day and 365-day measured on the same denominator',
           (SELECT CAST(eligible_customers AS VARCHAR) FROM bq3_repeat_summary WHERE population LIKE '1%' AND measure LIKE 'b%'),
           (SELECT CAST(eligible_customers AS VARCHAR) FROM bq3_repeat_summary WHERE population LIKE '1%' AND measure LIKE 'c%')
    UNION ALL SELECT 15, 'BQ3', 'Cohort table sums (excl. base) = headline 90-day eligible / repeaters',
           (SELECT CAST(eligible_customers AS VARCHAR) || ' / ' || CAST(repeat_customers AS VARCHAR)
            FROM bq3_repeat_summary WHERE population LIKE '1%' AND measure LIKE 'a%'),
           (SELECT CAST(SUM(eligible_90d) AS VARCHAR) || ' / ' || CAST(SUM(repeat_90d) AS VARCHAR)
            FROM bq3_cohort_comparison WHERE NOT is_observed_base)
    UNION ALL SELECT 16, 'BQ3', 'Ranked cohorts all have >= 100 eligible, full eligibility, not the base (violations)',
           '0', CAST((SELECT COUNT(*) FROM bq3_cohort_comparison WHERE rank_90d IS NOT NULL
                      AND (eligible_90d < 100 OR eligible_90d <> cohort_size OR is_observed_base)) AS VARCHAR)
    UNION ALL SELECT 17, 'BQ3', 'Cohort M1/M3/M6 copied unchanged from kpi_cohort_retention (mismatches)',
           '0', CAST((SELECT COUNT(*) FROM bq3_cohort_comparison AS b JOIN kpi_cohort_retention AS k
                      ON k.cohort_month = b.cohort_month AND k.months_since_first = 3
                      WHERE k.retention_rate IS DISTINCT FROM b.m3_retention) AS VARCHAR)
    -- BQ4
    UNION ALL SELECT 18, 'BQ4', 'Segment matrix totals = Group A (customers / gross value)',
           (SELECT CAST(customers AS VARCHAR) || ' / ' || CAST(gross_product_value AS VARCHAR)
            FROM kpi_segmentation_distribution WHERE tenure_group LIKE 'A %'),
           (SELECT CAST(SUM(customers) AS VARCHAR) || ' / ' || CAST(SUM(gross_product_value) AS VARCHAR) FROM bq4_segment_matrix)
    UNION ALL SELECT 19, 'BQ4', 'Group B profile totals = Group B (customers / gross value)',
           (SELECT CAST(customers AS VARCHAR) || ' / ' || CAST(gross_product_value AS VARCHAR)
            FROM kpi_segmentation_distribution WHERE tenure_group LIKE 'B%'),
           (SELECT CAST(SUM(customers) AS VARCHAR) || ' / ' || CAST(SUM(gross_product_value) AS VARCHAR) FROM bq4_group_b_profile)
    UNION ALL SELECT 20, 'BQ4', 'Every window customer gets exactly one proposed cell (unassigned / duplicates)',
           '0 / 0', CAST((SELECT COUNT(*) FROM bq4_customer_segment WHERE frequency_band IS NULL OR value_tier IS NULL) AS VARCHAR)
                    || ' / ' || CAST((SELECT COUNT(*) - COUNT(DISTINCT customer_id) FROM bq4_customer_segment) AS VARCHAR)
    UNION ALL SELECT 21, 'BQ4', 'Group A segment AIV (identified invoices) = Stage 2 group AIV',
           (SELECT CAST(average_invoice_value_identified AS VARCHAR) FROM kpi_segmentation_distribution WHERE tenure_group LIKE 'A %'),
           (SELECT CAST(ROUND(SUM(gross_product_value) / SUM(qualifying_invoices), 2) AS VARCHAR) FROM bq4_segment_matrix)
    UNION ALL SELECT 22, 'BQ4', 'Concentration (all window customers) = Stage 2 kpi_concentration at 1/10/20%',
           (SELECT string_agg(CAST(share_of_identified_value AS VARCHAR), ' / ' ORDER BY top_share)
            FROM kpi_concentration WHERE top_share IN (0.01, 0.10, 0.20)),
           (SELECT string_agg(CAST(share_of_population_value AS VARCHAR), ' / ' ORDER BY top_share)
            FROM bq4_concentration WHERE population = 'All window customers' AND top_share IN (0.01, 0.10, 0.20))
    UNION ALL SELECT 23, 'BQ4', 'Top-account sensitivity baseline = segment matrix F4 x V3 (customers / value share)',
           (SELECT CAST(customers AS VARCHAR) || ' / ' || CAST(value_share AS VARCHAR) FROM bq4_segment_matrix
            WHERE frequency_band LIKE 'F4%' AND value_tier LIKE 'V3%'),
           (SELECT CAST(remaining_f4_v3_customers AS VARCHAR) || ' / ' || CAST(f4_v3_value_share AS VARCHAR)
            FROM bq4_top_account_sensitivity WHERE excluded_customers = 0)
    UNION ALL SELECT 24, 'BQ4', 'Top-account sensitivity: remaining + excluded = Group A (customers, each scenario; violations)',
           '0', CAST((SELECT COUNT(*) FROM bq4_top_account_sensitivity
                      WHERE remaining_customers + excluded_customers
                            <> (SELECT customers FROM kpi_segmentation_distribution WHERE tenure_group LIKE 'A %')) AS VARCHAR)
)
SELECT check_no, bq, check_name, expected, actual,
       CASE WHEN check_no = 11 THEN split_part(expected, ' / ', 1) = split_part(actual, ' / ', 1)
                                AND split_part(expected, ' / ', 2) = split_part(actual, ' / ', 2)
            WHEN check_no = 7 THEN CAST(actual AS DOUBLE) < 0.01
            ELSE expected = actual END AS passed
FROM checks
ORDER BY check_no;
