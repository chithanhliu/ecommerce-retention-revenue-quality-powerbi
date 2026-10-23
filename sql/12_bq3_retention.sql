-- =============================================================================
-- 12_bq3_retention.sql — Stage 3, BQ3 Customer Retention
-- How consistently do identifiable customers return, and how does repeat purchasing
-- differ across cohorts? Reuses Stage 2 helpers customer_second_purchase and
-- kpi_cohort_retention. Rules: >= 100 eligible customers to rank a cohort, fixed repeat windows, headline excludes the Dec 2009 base.
-- Repeat within N days = another purchase day on day 1..N after the first purchase day;
-- eligible = at least N days of follow-up to 2011-12-08 (Stage 2 V2 rule).
-- =============================================================================

-- bq3_repeat_summary ------------------------------------------------------------------
-- Grain: population x measure. Every rate shows its own denominator.
-- "90-day on 365-eligible population" puts 90 and 365 days on the SAME customers.
CREATE OR REPLACE VIEW bq3_repeat_summary AS
WITH pops AS (
    SELECT '1 Headline: excluding Dec 2009 observed base' AS population, *
    FROM customer_second_purchase WHERE NOT is_observed_base
    UNION ALL
    SELECT '2 Supporting: all customers', * FROM customer_second_purchase
),
measures AS (
    SELECT * FROM (VALUES
        ('a 90-day repeat (all 90-day eligible)',        90,  90),
        ('b 365-day repeat (all 365-day eligible)',      365, 365),
        ('c 90-day repeat on the 365-eligible population', 90, 365)
    ) AS t(measure, window_days, eligibility_days)
)
SELECT
    p.population,
    m.measure,
    m.window_days,
    m.eligibility_days                                                                   AS follow_up_required_days,
    COUNT(*) FILTER (WHERE p.follow_up_days >= m.eligibility_days)                       AS eligible_customers,
    COUNT(*) FILTER (WHERE p.follow_up_days >= m.eligibility_days
                       AND p.days_to_second_purchase <= m.window_days)                   AS repeat_customers,
    ROUND(COUNT(*) FILTER (WHERE p.follow_up_days >= m.eligibility_days
                             AND p.days_to_second_purchase <= m.window_days)
          / COUNT(*) FILTER (WHERE p.follow_up_days >= m.eligibility_days), 4)           AS repeat_rate,
    -- Median only among customers who repeated within the window (labelling rule)
    quantile_disc(p.days_to_second_purchase, 0.5) FILTER (WHERE p.follow_up_days >= m.eligibility_days
                                                    AND p.days_to_second_purchase <= m.window_days)
                                                                                         AS median_days_among_repeaters
FROM pops AS p
CROSS JOIN measures AS m
GROUP BY p.population, m.measure, m.window_days, m.eligibility_days
ORDER BY p.population, m.measure;

-- bq3_cohort_comparison -----------------------------------------------------------------
-- Grain: one first-observed cohort month (Dec 2009 - Nov 2011).
-- rankable_90d = not the observed base, >= 100 eligible and fully eligible (no partial-
--   cohort selection). Ranks are only given to rankable cohorts.
CREATE OR REPLACE VIEW bq3_cohort_comparison AS
WITH c AS (
    SELECT
        d.first_observed_month                                                           AS cohort_month,
        BOOL_OR(d.is_observed_base)                                                      AS is_observed_base,
        COUNT(*)                                                                         AS cohort_size,
        COUNT(*) FILTER (WHERE s.follow_up_days >= 90)                                   AS eligible_90d,
        COUNT(*) FILTER (WHERE s.follow_up_days >= 90 AND s.days_to_second_purchase <= 90) AS repeat_90d,
        COUNT(*) FILTER (WHERE s.follow_up_days >= 365)                                  AS eligible_365d,
        COUNT(*) FILTER (WHERE s.follow_up_days >= 365 AND s.days_to_second_purchase <= 365) AS repeat_365d,
        COUNT(*) FILTER (WHERE s.follow_up_days >= 365 AND s.days_to_second_purchase <= 90)  AS repeat_90d_in_365_pop
    FROM customer_second_purchase AS s
    JOIN dim_customer AS d ON d.customer_id = s.customer_id
    WHERE d.first_observed_month <= DATE '2011-11-01'
    GROUP BY d.first_observed_month
),
r AS (
    SELECT cohort_month,
           MAX(retention_rate) FILTER (WHERE months_since_first = 1) AS m1_retention,
           MAX(retention_rate) FILTER (WHERE months_since_first = 3) AS m3_retention,
           MAX(retention_rate) FILTER (WHERE months_since_first = 6) AS m6_retention
    FROM kpi_cohort_retention GROUP BY cohort_month
),
j AS (
    SELECT c.*,
           ROUND(eligible_90d / cohort_size, 4)                                   AS eligible_share_90d,
           ROUND(repeat_90d / NULLIF(eligible_90d, 0), 4)                         AS repeat_rate_90d,
           ROUND(repeat_365d / NULLIF(eligible_365d, 0), 4)                       AS repeat_rate_365d,
           ROUND(repeat_90d_in_365_pop / NULLIF(eligible_365d, 0), 4)             AS repeat_rate_90d_on_365_pop,
           r.m1_retention, r.m3_retention, r.m6_retention,
           NOT is_observed_base AND eligible_90d >= 100 AND eligible_90d = cohort_size AS rankable_90d
    FROM c JOIN r USING (cohort_month)
)
SELECT *,
       CASE WHEN rankable_90d THEN RANK() OVER (PARTITION BY rankable_90d ORDER BY repeat_rate_90d DESC) END AS rank_90d,
       CASE WHEN is_observed_base THEN 'Observed base (excluded from headline)'
            WHEN eligible_90d = 0 THEN 'Not yet eligible'
            WHEN eligible_90d < cohort_size THEN 'Partial cohort: only early joiners eligible'
            WHEN eligible_90d < 100 THEN 'Low sample (< 100 eligible): shown, not ranked'
            ELSE 'Rankable' END AS comparison_note
FROM j
ORDER BY cohort_month;

-- bq3_cohort_groups ---------------------------------------------------------------------
-- Business purpose: like-for-like cohort comparisons that control for season and window.
-- Grain: one cohort group. Rates are pooled: total repeaters / total eligible (not averages
--   of cohort rates). M-k uses only cohorts whose month k is observed.
CREATE OR REPLACE VIEW bq3_cohort_groups AS
WITH g AS (
    SELECT '1 Jan-May 2010 cohorts' AS cohort_group, * FROM bq3_cohort_comparison
    WHERE cohort_month BETWEEN DATE '2010-01-01' AND DATE '2010-05-01'
    UNION ALL
    SELECT '2 Jan-May 2011 cohorts (same months, one year later)', * FROM bq3_cohort_comparison
    WHERE cohort_month BETWEEN DATE '2011-01-01' AND DATE '2011-05-01'
    UNION ALL
    SELECT '3 Jan-Aug 2010 cohorts', * FROM bq3_cohort_comparison
    WHERE cohort_month BETWEEN DATE '2010-01-01' AND DATE '2010-08-01'
    UNION ALL
    SELECT '4 Sep-Nov 2010 cohorts (pre-Christmas)', * FROM bq3_cohort_comparison
    WHERE cohort_month BETWEEN DATE '2010-09-01' AND DATE '2010-11-01'
),
cells AS (  -- active customers per cohort at M1/M3/M6, observed cells only
    SELECT g.cohort_group, g.cohort_month, g.cohort_size, kr.months_since_first, kr.active_customers
    FROM g JOIN kpi_cohort_retention AS kr
      ON kr.cohort_month = g.cohort_month AND kr.months_since_first IN (1, 3, 6) AND kr.is_observable
)
SELECT
    g.cohort_group,
    COUNT(*)                                                                         AS cohorts,
    SUM(g.cohort_size)                                                               AS customers,
    SUM(g.eligible_90d)                                                              AS eligible_90d,
    ROUND(SUM(g.repeat_90d) / SUM(g.eligible_90d), 4)                                AS pooled_repeat_rate_90d,
    SUM(g.eligible_365d)                                                             AS eligible_365d,
    ROUND(SUM(g.repeat_365d) / NULLIF(SUM(g.eligible_365d), 0), 4)                   AS pooled_repeat_rate_365d,
    (SELECT ROUND(SUM(active_customers) / SUM(cohort_size), 4) FROM cells AS x
      WHERE x.cohort_group = g.cohort_group AND x.months_since_first = 1)            AS pooled_m1,
    (SELECT ROUND(SUM(active_customers) / SUM(cohort_size), 4) FROM cells AS x
      WHERE x.cohort_group = g.cohort_group AND x.months_since_first = 3)            AS pooled_m3,
    (SELECT ROUND(SUM(active_customers) / SUM(cohort_size), 4) FROM cells AS x
      WHERE x.cohort_group = g.cohort_group AND x.months_since_first = 6)            AS pooled_m6
FROM g
GROUP BY g.cohort_group
ORDER BY g.cohort_group;
