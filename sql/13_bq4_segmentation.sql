-- =============================================================================
-- 13_bq4_segmentation.sql — Stage 3, BQ4 Customer Value & Segmentation
-- Which customer groups contribute most to observed product value?
-- Window Dec 2010 - Nov 2011; identified purchasing customers only (seg_customer_window, Stage 2).
-- Primary value = normalized gross product value. Primary segmentation on
-- Group A (observed before the window); Group B analysed separately.
-- Thresholds below are the final segmentation bands.
-- =============================================================================

-- bq4_customer_segment (helper, customer grain; NOT exported) -------------------------
-- Bands chosen for business meaning over 12 months and checked against the
-- Group A distribution (p25 1, p50 3, p75 5, p90 10 purchase days; value p50 ~GBP 835, p75 ~GBP 2,086):
--   Frequency (distinct purchase days in the 12-month window; labels are counts only,
--              they do not imply a monthly or quarterly buying rhythm):
--              F1 1 day | F2 2-3 days | F3 4-11 days | F4 12+ days
--   Value:     V1 < GBP 500 | V2 GBP 500-1,999 | V3 >= GBP 2,000
-- Sensitivity scenarios: S1 shifts frequency bands, S2 shifts value bands, S3 uses net value.
CREATE OR REPLACE VIEW bq4_customer_segment AS
SELECT
    s.*,
    CASE WHEN purchase_days = 1 THEN 'F1: 1 day' WHEN purchase_days <= 3 THEN 'F2: 2-3 days'
         WHEN purchase_days <= 11 THEN 'F3: 4-11 days' ELSE 'F4: 12+ days' END              AS frequency_band,
    CASE WHEN gross_product_value < 500 THEN 'V1: < 500' WHEN gross_product_value < 2000 THEN 'V2: 500-1,999'
         ELSE 'V3: >= 2,000' END                                                              AS value_tier,
    -- S1: frequency bands 1 / 2-4 / 5-11 / 12+
    CASE WHEN purchase_days = 1 THEN 'F1' WHEN purchase_days <= 4 THEN 'F2'
         WHEN purchase_days <= 11 THEN 'F3' ELSE 'F4' END                                      AS s1_frequency,
    -- S2: value tiers < 400 / 400-2,499 / >= 2,500
    CASE WHEN gross_product_value < 400 THEN 'V1' WHEN gross_product_value < 2500 THEN 'V2' ELSE 'V3' END
                                                                                              AS s2_value,
    -- S3: base value tiers applied to NET product value (after product cancellations)
    CASE WHEN net_product_value < 500 THEN 'V1' WHEN net_product_value < 2000 THEN 'V2' ELSE 'V3' END
                                                                                              AS s3_net_value
FROM seg_customer_window AS s;

-- bq4_segment_matrix ---------------------------------------------------------------------
-- Grain: Group A frequency band x value tier (proposed). Shares are of Group A totals.
-- Segment AIV uses identified invoices only.
CREATE OR REPLACE VIEW bq4_segment_matrix AS
SELECT
    frequency_band,
    value_tier,
    COUNT(*)                                                                         AS customers,
    ROUND(COUNT(*) / SUM(COUNT(*)) OVER (), 4)                                       AS customer_share,
    SUM(gross_product_value)                                                         AS gross_product_value,
    ROUND(SUM(gross_product_value) / SUM(SUM(gross_product_value)) OVER (), 4)       AS value_share,
    ROUND(MEDIAN(gross_product_value), 2)                                            AS median_customer_value,
    SUM(product_cancellation_value)                                                  AS product_cancellation_value,
    SUM(net_product_value)                                                           AS net_product_value,
    ROUND(-SUM(product_cancellation_value) / SUM(gross_product_value), 4)            AS cancellation_value_ratio,
    SUM(qualifying_invoices)                                                         AS qualifying_invoices,
    ROUND(SUM(gross_product_value) / SUM(qualifying_invoices), 2)                    AS aiv_identified,
    COUNT(*) FILTER (WHERE net_product_value <= 0)                                   AS customers_net_value_le_zero
FROM bq4_customer_segment
WHERE tenure_group LIKE 'A%'
GROUP BY frequency_band, value_tier
ORDER BY frequency_band, value_tier;

-- bq4_group_b_profile ----------------------------------------------------------------------
-- Grain: Group B months observed in window (bands) x simple frequency (1 day / 2+ days).
-- Group B is NOT placed on Group A bands because it had fewer months to buy.
CREATE OR REPLACE VIEW bq4_group_b_profile AS
SELECT
    CASE WHEN months_in_window_since_first <= 3 THEN '1-3 months observed (Sep-Nov 2011 starters)'
         WHEN months_in_window_since_first <= 6 THEN '4-6 months observed (Jun-Aug 2011 starters)'
         ELSE '7-12 months observed (Dec 2010-May 2011 starters)' END                 AS observation_band,
    CASE WHEN purchase_days = 1 THEN '1 purchase day' ELSE '2+ purchase days' END    AS frequency_band,
    COUNT(*)                                                                          AS customers,
    SUM(gross_product_value)                                                          AS gross_product_value,
    ROUND(SUM(gross_product_value) / SUM(SUM(gross_product_value)) OVER (), 4)        AS share_of_group_b_value,
    ROUND(MEDIAN(gross_product_value), 2)                                             AS median_customer_value,
    ROUND(SUM(gross_product_value) / SUM(qualifying_invoices), 2)                     AS aiv_identified,
    SUM(net_product_value)                                                            AS net_product_value
FROM bq4_customer_segment
WHERE tenure_group LIKE 'B%'
GROUP BY ALL
ORDER BY observation_band DESC, frequency_band;

-- bq4_threshold_sensitivity -----------------------------------------------------------------
-- Business purpose: how much the proposed segmentation depends on exact cut-offs.
-- Grain: one scenario. "moved" = Group A customers whose cell differs from the baseline bands.
CREATE OR REPLACE VIEW bq4_threshold_sensitivity AS
WITH a AS (
    SELECT *, left(frequency_band, 2) AS f0, left(value_tier, 2) AS v0
    FROM bq4_customer_segment WHERE tenure_group LIKE 'A%'
),
scen AS (
    SELECT 'P: Proposed (F 1/2-3/4-11/12+, V <500/<2,000/2,000+, gross)' AS scenario, f0 AS f, v0 AS v, * FROM a
    UNION ALL SELECT 'S1: Frequency 1/2-4/5-11/12+', s1_frequency, v0, * FROM a
    UNION ALL SELECT 'S2: Value <400/<2,500/2,500+', f0, s2_value, * FROM a
    UNION ALL SELECT 'S3: Proposed bands on NET value', f0, s3_net_value, * FROM a
)
SELECT
    scenario,
    COUNT(*)                                                                                  AS customers,
    COUNT(*) FILTER (WHERE f <> f0 OR v <> v0)                                                AS customers_moved,
    ROUND(COUNT(*) FILTER (WHERE f <> f0 OR v <> v0) / COUNT(*), 4)                           AS share_moved,
    COUNT(*) FILTER (WHERE f = 'F4' AND v = 'V3')                                             AS top_cell_customers,
    ROUND(SUM(gross_product_value) FILTER (WHERE f = 'F4' AND v = 'V3') / SUM(gross_product_value), 4)
                                                                                              AS top_cell_value_share,
    ROUND(SUM(gross_product_value) FILTER (WHERE v = 'V3') / SUM(gross_product_value), 4)    AS v3_value_share,
    COUNT(*) FILTER (WHERE v = 'V3')                                                          AS v3_customers,
    COUNT(*) FILTER (WHERE f = 'F1' AND v = 'V1')                                             AS bottom_cell_customers
FROM scen
GROUP BY scenario
ORDER BY scenario;

-- bq4_concentration ---------------------------------------------------------------------------
-- Grain: population x top-share band (window customers). Supporting view.
CREATE OR REPLACE VIEW bq4_concentration AS
WITH pops AS (
    SELECT 'All window customers' AS population, customer_id, gross_product_value FROM seg_customer_window
    UNION ALL
    SELECT 'Group A', customer_id, gross_product_value FROM seg_customer_window WHERE tenure_group LIKE 'A%'
    UNION ALL
    SELECT 'Group B', customer_id, gross_product_value FROM seg_customer_window WHERE tenure_group LIKE 'B%'
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY population ORDER BY gross_product_value DESC, customer_id) AS rn,
           COUNT(*) OVER (PARTITION BY population) AS n,
           SUM(gross_product_value) OVER (PARTITION BY population) AS total
    FROM pops
)
SELECT
    r.population,
    b.top_share,
    CAST(FLOOR(ANY_VALUE(r.n) * b.top_share) AS INTEGER)                                     AS customers_in_band,
    ROUND(SUM(r.gross_product_value) FILTER (WHERE r.rn <= FLOOR(r.n * b.top_share)) / ANY_VALUE(r.total), 4)
                                                                                             AS share_of_population_value
FROM ranked AS r
CROSS JOIN (VALUES (0.01), (0.05), (0.10), (0.20), (0.50)) AS b(top_share)
GROUP BY r.population, b.top_share
ORDER BY r.population, b.top_share;

-- bq4_top_account_sensitivity -----------------------------------------------------------------
-- Business purpose: test whether the F4 x V3 concentration finding depends on a few accounts.
-- Scenarios temporarily leave out the top 0 / 1 / 5 Group A customers by gross value; segment
-- thresholds and each remaining customer's segment stay fixed. Sensitivity only: no customer is
-- removed from any official KPI. Output is aggregated (no customer identifiers).
-- Grain: one scenario.
CREATE OR REPLACE VIEW bq4_top_account_sensitivity AS
WITH a AS (
    SELECT customer_id, gross_product_value,
           frequency_band LIKE 'F4%' AND value_tier LIKE 'V3%'                              AS is_f4_v3,
           ROW_NUMBER() OVER (ORDER BY gross_product_value DESC, customer_id)               AS value_rank
    FROM bq4_customer_segment
    WHERE tenure_group LIKE 'A%'
),
base AS (
    SELECT SUM(gross_product_value) AS total_value,
           SUM(gross_product_value) FILTER (WHERE is_f4_v3) / SUM(gross_product_value)     AS f4_v3_share
    FROM a
),
scen AS (
    SELECT * FROM (VALUES (0, '0 Baseline: all Group A'), (1, '1 Excluding top 1 customer'),
                          (5, '2 Excluding top 5 customers')) AS t(top_n, scenario)
)
SELECT
    s.scenario,
    s.top_n                                                                              AS excluded_customers,
    COUNT(*) FILTER (WHERE a.value_rank <= s.top_n AND a.is_f4_v3)                       AS excluded_in_f4_v3,
    ROUND(COALESCE(SUM(a.gross_product_value) FILTER (WHERE a.value_rank <= s.top_n), 0)
          / ANY_VALUE(b.total_value), 4)                                                 AS excluded_share_of_baseline_value,
    COUNT(*) FILTER (WHERE a.value_rank > s.top_n)                                       AS remaining_customers,
    SUM(a.gross_product_value) FILTER (WHERE a.value_rank > s.top_n)                     AS remaining_value,
    COUNT(*) FILTER (WHERE a.value_rank > s.top_n AND a.is_f4_v3)                        AS remaining_f4_v3_customers,
    ROUND(COUNT(*) FILTER (WHERE a.value_rank > s.top_n AND a.is_f4_v3)
          / COUNT(*) FILTER (WHERE a.value_rank > s.top_n), 4)                           AS f4_v3_customer_share,
    ROUND(SUM(a.gross_product_value) FILTER (WHERE a.value_rank > s.top_n AND a.is_f4_v3)
          / SUM(a.gross_product_value) FILTER (WHERE a.value_rank > s.top_n), 4)         AS f4_v3_value_share,
    ROUND(SUM(a.gross_product_value) FILTER (WHERE a.value_rank > s.top_n AND a.is_f4_v3)
          / SUM(a.gross_product_value) FILTER (WHERE a.value_rank > s.top_n)
          - ANY_VALUE(b.f4_v3_share), 4)                                                 AS change_vs_baseline_pp
FROM scen AS s
CROSS JOIN a
CROSS JOIN base AS b
GROUP BY s.scenario, s.top_n
ORDER BY s.top_n;
