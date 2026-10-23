-- =============================================================================
-- 03_kpis.sql — KPI Framework v1.0 calculations (views)
-- Normalized metrics exclude the 2 extreme reversal pairs; reconciliation and
-- sensitivity views show recorded (keep-all) values alongside.
-- Each view states its grain; no view mixes line, invoice and customer grains
-- without aggregating each to the output grain first.
-- =============================================================================

-- kpi_value_reconciliation -------------------------------------------------------
-- Business purpose: show that every recorded line is classified and that the
--   classes add back to the all-recorded net value. Window: full dataset.
-- Grain: value_group x transaction_class, with subtotals and a grand total.
CREATE OR REPLACE VIEW kpi_value_reconciliation AS
WITH by_class AS (
    SELECT
        value_group,
        transaction_class,
        COUNT(*)                                                    AS line_count,
        COUNT(*) FILTER (WHERE NOT has_customer_id)                 AS lines_without_customer_id,
        SUM(line_value)                                             AS recorded_value,
        COALESCE(SUM(line_value) FILTER (WHERE is_extreme_reversal), 0) AS extreme_reversal_value
    FROM stg_transaction_line
    GROUP BY ROLLUP (value_group, transaction_class)
)
SELECT
    COALESCE(value_group, 'ALL')                                         AS value_group,
    COALESCE(transaction_class, CASE WHEN value_group IS NULL THEN 'ALL_RECORDED_NET'
                                     ELSE 'SUBTOTAL' END)                AS transaction_class,
    line_count,
    lines_without_customer_id,
    recorded_value,
    extreme_reversal_value,
    recorded_value - extreme_reversal_value                              AS normalized_value
FROM by_class
ORDER BY
    CASE COALESCE(value_group, 'ALL')
        WHEN 'GROSS_PRODUCT' THEN 1 WHEN 'PRODUCT_CANCELLATION' THEN 2
        WHEN 'NON_PRODUCT' THEN 3 WHEN 'ZERO_PRICE' THEN 4 WHEN 'UNCLASSIFIED' THEN 5 ELSE 6 END,
    transaction_class IS NULL, transaction_class;

-- kpi_monthly -------------------------------------------------------------------
-- Business purpose: historical monthly value and customer activity, Dec 2009 - Nov 2011.
-- Grain: one calendar month. Value measures come from fct_invoice (invoice month);
--   customer measures come from fct_customer_day; each is aggregated to month first.
CREATE OR REPLACE VIEW kpi_monthly AS
WITH months AS (
    SELECT CAST(m AS DATE) AS month
    FROM generate_series(history_start_month(), history_end_month(), INTERVAL 1 MONTH) AS t(m)
),
invoice_value AS (
    SELECT
        invoice_month                                                    AS month,
        SUM(gross_product_value)                                         AS gross_product_value,
        SUM(gross_product_value) FILTER (WHERE customer_id IS NOT NULL)  AS gross_product_value_identified,
        SUM(product_cancellation_value)                                  AS product_cancellation_value,
        SUM(non_product_value)                                           AS non_product_value,
        SUM(all_recorded_value)                                          AS all_recorded_net_value,
        COUNT(*) FILTER (WHERE is_qualifying_purchase)                   AS qualifying_invoices,
        COUNT(*) FILTER (WHERE is_qualifying_purchase AND customer_id IS NOT NULL)
                                                                         AS qualifying_invoices_identified
    FROM fct_invoice
    GROUP BY invoice_month
),
customer_activity AS (
    SELECT
        d.purchase_month                                                       AS month,
        COUNT(DISTINCT d.customer_id)                                          AS active_customers,
        COUNT(*)                                                               AS purchase_occasions,
        COUNT(DISTINCT d.customer_id) FILTER (WHERE c.first_observed_month = d.purchase_month)
                                                                               AS first_observed_customers,
        COALESCE(SUM(d.gross_product_value) FILTER (WHERE c.first_observed_month < d.purchase_month), 0)
                                                                               AS previously_observed_value
    FROM fct_customer_day AS d
    JOIN dim_customer AS c ON c.customer_id = d.customer_id
    GROUP BY d.purchase_month
)
SELECT
    m.month,
    m.month = observed_base_month()                                    AS is_observed_base_month,
    v.gross_product_value,
    v.product_cancellation_value,
    v.gross_product_value + v.product_cancellation_value               AS net_recorded_product_value,
    v.non_product_value,
    v.all_recorded_net_value,
    ROUND(-v.product_cancellation_value / v.gross_product_value, 4)    AS product_cancellation_rate,
    v.gross_product_value_identified,
    ROUND(v.gross_product_value_identified / v.gross_product_value, 4) AS identified_value_share,
    -- AIV populations: overall AIV uses every qualifying invoice; identified AIV uses invoices with a Customer ID.
    v.qualifying_invoices,
    ROUND(v.gross_product_value / v.qualifying_invoices, 2)            AS average_invoice_value_overall,
    v.qualifying_invoices_identified,
    ROUND(v.gross_product_value_identified / v.qualifying_invoices_identified, 2)
                                                                       AS average_invoice_value_identified,
    a.active_customers,
    a.purchase_occasions,
    a.first_observed_customers,
    a.active_customers - a.first_observed_customers                    AS previously_observed_customers,
    ROUND(a.previously_observed_value / v.gross_product_value_identified, 4)
                                                                       AS previously_observed_value_share
FROM months AS m
LEFT JOIN invoice_value AS v ON v.month = m.month
LEFT JOIN customer_activity AS a ON a.month = m.month
ORDER BY m.month;

-- customer_repeat_90d (helper, customer grain; not exported) -------------------
-- Eligibility rule: eligible if first purchase day + 90 <= last complete observed day
--   (2011-12-08, so first purchase day <= 2011-09-09); repeat if another purchase day
--   falls on day 1-90 after the first purchase day. Dec 2011 purchases count when inside the window.
CREATE OR REPLACE VIEW customer_repeat_90d AS
SELECT
    c.customer_id,
    c.first_purchase_date,
    c.first_observed_month,
    c.is_observed_base,
    c.first_purchase_date + repeat_window_days() <= last_complete_date()  AS is_eligible,
    EXISTS (
        SELECT 1
        FROM fct_customer_day AS d
        WHERE d.customer_id = c.customer_id
          AND d.purchase_date BETWEEN c.first_purchase_date + 1
                                  AND c.first_purchase_date + repeat_window_days()
    )                                                                     AS repeated_within_90d
FROM dim_customer AS c
WHERE c.has_qualifying_purchase;

-- kpi_repeat_90d ----------------------------------------------------------------
-- Grain: one population (overall, overall excluding Dec 2009 base, each first-observed month).
CREATE OR REPLACE VIEW kpi_repeat_90d AS
WITH populations AS (
    SELECT '1 All eligible customers' AS population, * FROM customer_repeat_90d
    UNION ALL
    SELECT '2 Excluding Dec 2009 observed base', * FROM customer_repeat_90d WHERE NOT is_observed_base
    UNION ALL
    SELECT '3 Cohort ' || strftime(first_observed_month, '%Y-%m'), * FROM customer_repeat_90d
)
SELECT
    population,
    COUNT(*)                                                             AS customers,
    COUNT(*) FILTER (WHERE is_eligible)                                  AS eligible_customers,
    ROUND(COUNT(*) FILTER (WHERE is_eligible) / COUNT(*), 4)             AS eligible_share,
    COUNT(*) FILTER (WHERE is_eligible AND repeated_within_90d)          AS repeat_customers,
    ROUND(COUNT(*) FILTER (WHERE is_eligible AND repeated_within_90d)
          / NULLIF(COUNT(*) FILTER (WHERE is_eligible), 0), 4)           AS repeat_rate_90d,
    COUNT(*) FILTER (WHERE NOT is_eligible)                              AS not_yet_eligible_customers,
    -- Minimum sample: comparisons and rankings need >= 100 eligible customers; smaller rows are kept with a warning.
    COUNT(*) FILTER (WHERE is_eligible) >= 100                           AS meets_min_sample,
    CASE WHEN COUNT(*) FILTER (WHERE is_eligible) = 0   THEN 'No eligible customers yet'
         WHEN COUNT(*) FILTER (WHERE is_eligible) < 100 THEN 'Low sample: < 100 eligible'
         WHEN COUNT(*) FILTER (WHERE NOT is_eligible) > 0 THEN 'Partially eligible cohort'
         ELSE 'OK' END                                                   AS sample_warning
FROM populations
GROUP BY population
ORDER BY population;

-- kpi_cohort_retention ----------------------------------------------------------
-- Business purpose: share of each first-observed cohort that purchases again in month k.
-- Grain: cohort_month x months_since_first (0-23). Cells whose activity month is after
--   Nov 2011 are not fully observed and stay NULL (never 0).
CREATE OR REPLACE VIEW kpi_cohort_retention AS
WITH cohorts AS (
    SELECT first_observed_month AS cohort_month, BOOL_OR(is_observed_base) AS is_observed_base,
           COUNT(*) AS cohort_size
    FROM dim_customer
    WHERE has_qualifying_purchase
      AND first_observed_month BETWEEN history_start_month() AND history_end_month()
    GROUP BY first_observed_month
),
activity AS (
    SELECT c.first_observed_month AS cohort_month, d.purchase_month,
           COUNT(DISTINCT d.customer_id) AS active_customers
    FROM fct_customer_day AS d
    JOIN dim_customer AS c ON c.customer_id = d.customer_id
    GROUP BY c.first_observed_month, d.purchase_month
),
grid AS (
    SELECT co.*, k.months_since_first,
           CAST(co.cohort_month + to_months(CAST(k.months_since_first AS INTEGER)) AS DATE) AS activity_month
    FROM cohorts AS co
    CROSS JOIN range(0, 24) AS k(months_since_first)
)
SELECT
    g.cohort_month,
    g.is_observed_base,
    g.cohort_size,
    g.cohort_size >= 100                                                            AS meets_min_sample,  -- >= 100 eligible
    g.months_since_first,
    g.activity_month,
    g.activity_month <= history_end_month()                                         AS is_observable,
    CASE WHEN g.activity_month <= history_end_month() THEN COALESCE(a.active_customers, 0) END
                                                                                    AS active_customers,
    CASE WHEN g.activity_month <= history_end_month()
         THEN ROUND(COALESCE(a.active_customers, 0) / g.cohort_size, 4) END         AS retention_rate
FROM grid AS g
LEFT JOIN activity AS a ON a.cohort_month = g.cohort_month AND a.purchase_month = g.activity_month
ORDER BY g.cohort_month, g.months_since_first;

-- customer_second_purchase (helper, customer grain; not exported) ---------------
-- Second purchase = first purchase DAY after the first-observed purchase day (same rule as 90-day repeat).
-- follow_up_days = days observed after the first purchase day, up to the last complete day.
-- For the Dec 2009 base this is the next purchase after data start, not a true second purchase.
CREATE OR REPLACE VIEW customer_second_purchase AS
SELECT
    c.customer_id,
    c.first_purchase_date,
    c.is_observed_base,
    MIN(d.purchase_date)                               AS second_purchase_date,
    MIN(d.purchase_date) - c.first_purchase_date       AS days_to_second_purchase,
    last_complete_date() - c.first_purchase_date       AS follow_up_days
FROM dim_customer AS c
LEFT JOIN fct_customer_day AS d
       ON d.customer_id = c.customer_id
      AND d.purchase_date > c.first_purchase_date
WHERE c.has_qualifying_purchase
GROUP BY c.customer_id, c.first_purchase_date, c.is_observed_base;

-- kpi_time_to_second_purchase -----------------------------------------------------
-- Business purpose: how quickly customers make a second purchase, without censoring bias.
-- Method: fixed windows. For window N only customers with >= N days of follow-up are counted
--   (right-censored customers are left out, not treated as non-converters). The median is the
--   median days among customers who converted within N days.
-- Grain: population x window_days.
CREATE OR REPLACE VIEW kpi_time_to_second_purchase AS
WITH populations AS (
    SELECT '1 All customers' AS population, * FROM customer_second_purchase
    UNION ALL
    SELECT '2 Excluding Dec 2009 observed base', * FROM customer_second_purchase WHERE NOT is_observed_base
),
windows AS (
    SELECT * FROM (VALUES (30), (60), (90), (180), (365)) AS w(window_days)
)
SELECT
    p.population,
    w.window_days,
    COUNT(*) FILTER (WHERE p.follow_up_days >= w.window_days)                           AS eligible_customers,
    COUNT(*) FILTER (WHERE p.follow_up_days >= w.window_days
                       AND p.days_to_second_purchase <= w.window_days)                  AS converted_customers,
    ROUND(COUNT(*) FILTER (WHERE p.follow_up_days >= w.window_days
                             AND p.days_to_second_purchase <= w.window_days)
          / COUNT(*) FILTER (WHERE p.follow_up_days >= w.window_days), 4)               AS conversion_rate,
    quantile_disc(p.days_to_second_purchase, 0.25) FILTER (WHERE p.follow_up_days >= w.window_days
                                                     AND p.days_to_second_purchase <= w.window_days)
                                                                                         AS p25_days_among_converted,
    quantile_disc(p.days_to_second_purchase, 0.50) FILTER (WHERE p.follow_up_days >= w.window_days
                                                     AND p.days_to_second_purchase <= w.window_days)
                                                                                         AS median_days_among_converted,
    quantile_disc(p.days_to_second_purchase, 0.75) FILTER (WHERE p.follow_up_days >= w.window_days
                                                     AND p.days_to_second_purchase <= w.window_days)
                                                                                         AS p75_days_among_converted
FROM populations AS p
CROSS JOIN windows AS w
GROUP BY p.population, w.window_days
ORDER BY p.population, w.window_days;

-- seg_customer_window (helper, customer grain; not exported) -------------------
-- Business purpose: inputs for Purchase Frequency x Observed Product Value segmentation.
-- Window: Dec 2010 - Nov 2011. Grain: one identified customer with >= 1 purchase day in window.
-- Tenure: customers first observed inside the window had fewer months to buy.
CREATE OR REPLACE VIEW seg_customer_window AS
WITH purchases AS (
    SELECT customer_id, COUNT(*) AS purchase_days, SUM(qualifying_invoices) AS qualifying_invoices,
           SUM(gross_product_value) AS gross_product_value
    FROM fct_customer_day
    WHERE purchase_month BETWEEN segment_start_month() AND segment_end_month()
    GROUP BY customer_id
),
cancellations AS (
    SELECT customer_id, SUM(product_cancellation_value) AS product_cancellation_value
    FROM fct_invoice
    WHERE invoice_month BETWEEN segment_start_month() AND segment_end_month()
      AND customer_id IS NOT NULL
    GROUP BY customer_id
)
SELECT
    p.customer_id,
    p.purchase_days,
    p.qualifying_invoices,
    p.gross_product_value,
    COALESCE(x.product_cancellation_value, 0)                          AS product_cancellation_value,
    p.gross_product_value + COALESCE(x.product_cancellation_value, 0)  AS net_product_value,
    c.first_observed_month,
    CASE WHEN c.first_observed_month < segment_start_month()
         THEN 'A Observed before window' ELSE 'B First observed in window' END AS tenure_group,
    date_diff('month', GREATEST(c.first_observed_month, segment_start_month()), segment_end_month()) + 1
                                                                       AS months_in_window_since_first
FROM purchases AS p
JOIN dim_customer AS c ON c.customer_id = p.customer_id
LEFT JOIN cancellations AS x ON x.customer_id = p.customer_id;

-- kpi_segmentation_distribution ---------------------------------------------------
-- Grain: tenure group (plus all customers). Percentiles to inform thresholds; no thresholds set here.
-- Segmentation value: primary value = normalized gross product value; net and cancellations are supporting.
-- Segment AIV uses identified invoices only (all customers here are identified).
CREATE OR REPLACE VIEW kpi_segmentation_distribution AS
SELECT
    COALESCE(tenure_group, 'All customers')                            AS tenure_group,
    COUNT(*)                                                           AS customers,
    SUM(gross_product_value)                                           AS gross_product_value,
    SUM(product_cancellation_value)                                    AS product_cancellation_value,
    SUM(net_product_value)                                             AS net_product_value,
    SUM(qualifying_invoices)                                           AS qualifying_invoices_identified,
    ROUND(SUM(gross_product_value) / SUM(qualifying_invoices), 2)      AS average_invoice_value_identified,
    quantile_disc(purchase_days, 0.25)                                 AS purchase_days_p25,
    quantile_disc(purchase_days, 0.50)                                 AS purchase_days_p50,
    quantile_disc(purchase_days, 0.75)                                 AS purchase_days_p75,
    quantile_disc(purchase_days, 0.90)                                 AS purchase_days_p90,
    MAX(purchase_days)                                                 AS purchase_days_max,
    ROUND(quantile_cont(gross_product_value, 0.25), 2)                 AS value_p25,
    ROUND(quantile_cont(gross_product_value, 0.50), 2)                 AS value_p50,
    ROUND(quantile_cont(gross_product_value, 0.75), 2)                 AS value_p75,
    ROUND(quantile_cont(gross_product_value, 0.90), 2)                 AS value_p90,
    ROUND(quantile_cont(gross_product_value, 0.99), 2)                 AS value_p99,
    MAX(gross_product_value)                                           AS value_max,
    COUNT(*) FILTER (WHERE net_product_value <= 0)                     AS customers_net_value_le_zero
FROM seg_customer_window
GROUP BY ROLLUP (tenure_group)
ORDER BY tenure_group IS NULL, tenure_group;

-- kpi_segmentation_frequency -------------------------------------------------------
-- Grain: tenure group x purchase days in window (12 = 12 or more). Shows where customers and value sit.
CREATE OR REPLACE VIEW kpi_segmentation_frequency AS
SELECT
    tenure_group,
    LEAST(purchase_days, 12)                                                       AS purchase_days_capped,
    COUNT(*)                                                                       AS customers,
    ROUND(COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY tenure_group), 4)            AS customer_share_in_group,
    SUM(gross_product_value)                                                       AS gross_product_value,
    ROUND(SUM(gross_product_value) / SUM(SUM(gross_product_value)) OVER (), 4)     AS value_share_all_customers,
    ROUND(MEDIAN(gross_product_value), 2)                                          AS median_customer_value,
    SUM(net_product_value)                                                         AS net_product_value,
    COUNT(*) FILTER (WHERE net_product_value <= 0)                                 AS customers_net_value_le_zero
FROM seg_customer_window
GROUP BY tenure_group, LEAST(purchase_days, 12)
ORDER BY tenure_group, purchase_days_capped;

-- kpi_segmentation_tenure ------------------------------------------------------------
-- Business purpose: show how observation time drives frequency and value, before thresholds.
-- Grain: tenure group x months observed in window since first purchase (group A is always 12).
-- Per-month figures divide by months observed; they are a sensitivity view, not a KPI.
CREATE OR REPLACE VIEW kpi_segmentation_tenure AS
SELECT
    tenure_group,
    months_in_window_since_first,
    COUNT(*)                                                                    AS customers,
    quantile_disc(purchase_days, 0.50)                                          AS median_purchase_days,
    ROUND(AVG(purchase_days), 2)                                                AS mean_purchase_days,
    ROUND(MEDIAN(purchase_days / months_in_window_since_first), 3)              AS median_purchase_days_per_month,
    ROUND(MEDIAN(gross_product_value), 2)                                       AS median_value,
    ROUND(MEDIAN(gross_product_value / months_in_window_since_first), 2)        AS median_value_per_month,
    ROUND(COUNT(*) FILTER (WHERE purchase_days >= 2) / COUNT(*), 4)             AS share_with_2plus_purchase_days
FROM seg_customer_window
GROUP BY tenure_group, months_in_window_since_first
ORDER BY tenure_group, months_in_window_since_first DESC;

-- kpi_concentration -----------------------------------------------------------------
-- Business purpose: supporting view of customer value concentration (segmentation window).
-- Grain: one top-share band.
CREATE OR REPLACE VIEW kpi_concentration AS
WITH ranked AS (
    SELECT gross_product_value,
           ROW_NUMBER() OVER (ORDER BY gross_product_value DESC, customer_id) AS value_rank,
           COUNT(*) OVER ()                                                 AS customers,
           SUM(gross_product_value) OVER ()                                 AS total_value
    FROM seg_customer_window
)
SELECT
    b.top_share,
    CAST(FLOOR(r.customers * b.top_share) AS INTEGER)                        AS customers_in_band,
    SUM(r.gross_product_value) FILTER (WHERE r.value_rank <= FLOOR(r.customers * b.top_share))
                                                                             AS band_value,
    ROUND(SUM(r.gross_product_value) FILTER (WHERE r.value_rank <= FLOOR(r.customers * b.top_share))
          / ANY_VALUE(r.total_value), 4)                                     AS share_of_identified_value
FROM ranked AS r
CROSS JOIN (VALUES (0.01), (0.05), (0.10), (0.20), (0.50)) AS b(top_share)
GROUP BY b.top_share, r.customers
ORDER BY b.top_share;

-- kpi_extreme_sensitivity -----------------------------------------------------------
-- Business purpose: show exactly what the 2 extreme reversal pairs change.
-- Grain: one metric; recorded (keep all) vs normalized.
CREATE OR REPLACE VIEW kpi_extreme_sensitivity AS
WITH totals AS (
    SELECT
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE')            AS gross_rec,
        SUM(line_value) FILTER (WHERE is_normalized_purchase)                            AS gross_norm,
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION')        AS canc_rec,
        SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION'
                                  AND NOT is_extreme_reversal)                            AS canc_norm
    FROM stg_transaction_line
),
monthly AS (
    SELECT invoice_month,
           -SUM(product_cancellation_value_recorded) / SUM(gross_product_value_recorded) AS rate_rec,
           -SUM(product_cancellation_value) / SUM(gross_product_value)                   AS rate_norm
    FROM fct_invoice
    WHERE invoice_month IN (DATE '2011-01-01', DATE '2011-12-01')
    GROUP BY invoice_month
),
customer_value AS (  -- full period, identified customers
    SELECT customer_id,
           SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE') AS value_rec,
           COALESCE(SUM(line_value) FILTER (WHERE is_normalized_purchase), 0)    AS value_norm
    FROM stg_transaction_line
    WHERE customer_id IS NOT NULL AND transaction_class = 'PRODUCT_PURCHASE'
    GROUP BY customer_id
),
customer_rank AS (
    SELECT customer_id, value_rec, value_norm,
           RANK() OVER (ORDER BY value_rec DESC)  AS rank_rec,
           RANK() OVER (ORDER BY value_norm DESC) AS rank_norm
    FROM customer_value
)
SELECT 'Gross positive product value (full dataset)' AS metric,
       CAST(gross_rec AS DOUBLE) AS recorded, CAST(gross_norm AS DOUBLE) AS normalized FROM totals
UNION ALL SELECT 'Product cancellation adjustments (full dataset)', canc_rec, canc_norm FROM totals
UNION ALL SELECT 'Net recorded product value (full dataset)', gross_rec + canc_rec, gross_norm + canc_norm FROM totals
UNION ALL SELECT 'Product cancellation rate (full dataset)',
                 ROUND(-canc_rec / gross_rec, 4), ROUND(-canc_norm / gross_norm, 4) FROM totals
UNION ALL SELECT 'Product cancellation rate ' || strftime(invoice_month, '%Y-%m'),
                 ROUND(rate_rec, 4), ROUND(rate_norm, 4) FROM monthly
UNION ALL SELECT 'Customer ' || customer_id || ' value rank (full period)', rank_rec, rank_norm
          FROM customer_rank WHERE customer_id IN (12346, 16446)
UNION ALL SELECT 'Customer ' || customer_id || ' gross product value (full period)', value_rec, value_norm
          FROM customer_rank WHERE customer_id IN (12346, 16446);
