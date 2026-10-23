-- =============================================================================
-- 10_bq1_value_reliability.sql — Stage 3, BQ1 Data Reliability
-- How reliable is the recorded product value after cancellations and adjustments?
-- Reuses stg_transaction_line (Stage 2). No definitions are changed here.
-- =============================================================================

-- Analysis periods used across Stage 3 (two aligned 12-month periods + partial Dec 2011).
CREATE OR REPLACE MACRO analysis_period(d) AS
    CASE WHEN d >= DATE '2009-12-01' AND d < DATE '2010-12-01' THEN 'A: Dec 2009-Nov 2010'
         WHEN d >= DATE '2010-12-01' AND d < DATE '2011-12-01' THEN 'B: Dec 2010-Nov 2011'
         ELSE 'C: Dec 2011 (partial, 1-9 Dec)' END;

-- bq1_value_bridge ---------------------------------------------------------------
-- Business purpose: from recorded gross product value to net values, per period, showing
--   what each classification step removes and how much value has no Customer ID.
-- Grain: one period (A, B, partial Dec 2011) plus the full dataset. Period = line date.
CREATE OR REPLACE VIEW bq1_value_bridge AS
WITH lines AS (
    SELECT *, analysis_period(CAST(invoice_ts AS DATE)) AS period FROM stg_transaction_line
),
agg AS (
    SELECT
        COALESCE(period, 'Full dataset')                                                           AS period,
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE')                       AS gross_recorded,
        COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE' AND is_extreme_reversal), 0)
                                                                                                    AS extreme_purchase_value,
        SUM(line_value) FILTER (WHERE is_normalized_purchase)                                       AS gross_normalized,
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION')                   AS cancellation_recorded,
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION' AND NOT is_extreme_reversal)
                                                                                                    AS cancellation_normalized,
        COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'SHIPPING'), 0)                  AS shipping,
        COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'FEE'), 0)                       AS fees,
        COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'BAD_DEBT_ADJUSTMENT'), 0)       AS bad_debt,
        COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'MANUAL_ADJUSTMENT'), 0)         AS manual_adjustments,
        COALESCE(SUM(line_value) FILTER (WHERE transaction_class IN ('DISCOUNT', 'SAMPLE', 'VOUCHER', 'TEST')), 0)
                                                                                                    AS discount_sample_voucher_test,
        COALESCE(SUM(line_value) FILTER (WHERE value_group = 'NON_PRODUCT'), 0)                     AS non_product_total,
        SUM(line_value)                                                                             AS all_recorded_net,
        SUM(line_value) FILTER (WHERE is_normalized_purchase AND NOT has_customer_id)               AS gross_normalized_unidentified,
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION' AND NOT is_extreme_reversal
                                  AND NOT has_customer_id)                                          AS cancellation_normalized_unidentified,
        -- What a reader would compute WITHOUT the classification: every line on a C invoice
        -- against every positive line on a standard invoice (includes fees, postage, manual entries).
        SUM(line_value) FILTER (WHERE invoice_type = 'CANCELLATION')                                AS unclassified_c_invoice_value,
        SUM(line_value) FILTER (WHERE invoice_type = 'STANDARD' AND line_value > 0)                 AS unclassified_positive_value
    FROM lines
    GROUP BY ROLLUP (period)
)
SELECT
    period,
    gross_recorded,
    extreme_purchase_value,
    gross_normalized,
    cancellation_recorded,
    cancellation_normalized,
    gross_normalized + cancellation_normalized                                  AS net_product_value,
    shipping, fees, bad_debt, manual_adjustments, discount_sample_voucher_test,
    non_product_total,
    all_recorded_net,
    ROUND(-cancellation_normalized / gross_normalized, 4)                      AS cancellation_value_ratio_normalized,
    ROUND(-cancellation_recorded / gross_recorded, 4)                          AS cancellation_value_ratio_recorded,
    ROUND(-unclassified_c_invoice_value / unclassified_positive_value, 4)       AS cancellation_ratio_unclassified,
    ROUND(gross_normalized_unidentified / gross_normalized, 4)                 AS unidentified_share_of_gross,
    ROUND(cancellation_normalized_unidentified / cancellation_normalized, 4)   AS unidentified_share_of_cancellations,
    ROUND(non_product_total / (gross_normalized + cancellation_normalized), 4) AS non_product_to_net_product_ratio
FROM agg
ORDER BY period;

-- bq1_monthly_reliability ----------------------------------------------------------
-- Business purpose: find months where classification choices change the reading of performance.
-- Grain: one calendar month (Dec 2009 - Dec 2011; Dec 2011 is partial and flagged).
CREATE OR REPLACE VIEW bq1_monthly_reliability AS
WITH m AS (
    SELECT
        CAST(date_trunc('month', invoice_ts) AS DATE)                                              AS month,
        SUM(line_value) FILTER (WHERE is_normalized_purchase)                                       AS gross_normalized,
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION' AND NOT is_extreme_reversal)
                                                                                                    AS cancellation_normalized,
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE')                       AS gross_recorded,
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION')                   AS cancellation_recorded,
        SUM(line_value) FILTER (WHERE invoice_type = 'CANCELLATION')                                AS unclassified_c_invoice_value,
        SUM(line_value) FILTER (WHERE invoice_type = 'STANDARD' AND line_value > 0)                 AS unclassified_positive_value,
        COALESCE(SUM(line_value) FILTER (WHERE value_group = 'NON_PRODUCT'), 0)                     AS non_product_total,
        COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'BAD_DEBT_ADJUSTMENT'), 0)       AS bad_debt,
        COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'FEE'), 0)                       AS fees,
        SUM(line_value) FILTER (WHERE is_normalized_purchase AND NOT has_customer_id)               AS gross_normalized_unidentified,
        BOOL_OR(is_extreme_reversal)                                                                AS has_extreme_reversal
    FROM stg_transaction_line
    GROUP BY 1
)
SELECT
    month,
    month = DATE '2011-12-01'                                                    AS is_partial_month,
    gross_normalized,
    cancellation_normalized,
    gross_normalized + cancellation_normalized                                   AS net_product_value,
    non_product_total,
    bad_debt,
    fees,
    has_extreme_reversal,
    ROUND(-cancellation_normalized / gross_normalized, 4)                       AS cancellation_value_ratio_normalized,
    ROUND(-cancellation_recorded / gross_recorded, 4)                           AS cancellation_value_ratio_recorded,
    ROUND(-unclassified_c_invoice_value / unclassified_positive_value, 4)        AS cancellation_ratio_unclassified,
    ROUND(-unclassified_c_invoice_value / unclassified_positive_value
          + cancellation_normalized / gross_normalized, 4)                       AS ratio_gap_unclassified_vs_normalized,
    ROUND(non_product_total / (gross_normalized + cancellation_normalized), 4)  AS non_product_to_net_product_ratio,
    ROUND(gross_normalized_unidentified / gross_normalized, 4)                  AS unidentified_share_of_gross
FROM m
ORDER BY month;

-- bq1_cancellation_concentration -----------------------------------------------------------
-- Business purpose: test whether a month's high cancellation ratio comes from one or two large
--   cancellation invoices (event) rather than broad behaviour. Normalized product cancellations.
-- Grain: one calendar month.
CREATE OR REPLACE VIEW bq1_cancellation_concentration AS
WITH c AS (
    SELECT CAST(date_trunc('month', invoice_ts) AS DATE) AS month, invoice_no,
           ANY_VALUE(customer_id) AS customer_id, SUM(line_value) AS cancel_value
    FROM stg_transaction_line
    WHERE transaction_class = 'PRODUCT_CANCELLATION' AND NOT is_extreme_reversal
    GROUP BY 1, 2
),
r AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY month ORDER BY cancel_value, invoice_no) AS rn,
           SUM(cancel_value) OVER (PARTITION BY month) AS month_cancel_value,
           COUNT(*) OVER (PARTITION BY month) AS cancellation_invoices
    FROM c
)
SELECT
    month,
    ANY_VALUE(cancellation_invoices)                                                    AS cancellation_invoices,
    ANY_VALUE(month_cancel_value)                                                       AS month_cancel_value,
    MAX(invoice_no) FILTER (WHERE rn = 1)                                               AS largest_invoice,
    MAX(customer_id) FILTER (WHERE rn = 1)                                              AS largest_invoice_customer,
    ROUND(SUM(cancel_value) FILTER (WHERE rn = 1) / ANY_VALUE(month_cancel_value), 4)   AS largest_invoice_share,
    ROUND(SUM(cancel_value) FILTER (WHERE rn <= 3) / ANY_VALUE(month_cancel_value), 4)  AS top3_invoice_share
FROM r
GROUP BY month
ORDER BY month;
