-- =============================================================================
-- 11_bq2_commercial_performance.sql — Stage 3, BQ2 Commercial Performance
-- What contributes to changes in purchasing activity and observed product value?
-- Period A = Dec 2009-Nov 2010, Period B = Dec 2010-Nov 2011 (same 12 calendar months).
-- All values are normalized gross positive product value (Stage 2 rules).
-- Decomposition is arithmetic, not causal attribution.
-- =============================================================================

-- bq2_period_summary --------------------------------------------------------------
-- Business purpose: overall vs identified value and the three identified-customer drivers.
-- Grain: one period (A, B). Overall measures from fct_invoice; customer measures from
--   fct_customer_day; both aggregated to period before joining.
CREATE OR REPLACE VIEW bq2_period_summary AS
WITH inv AS (
    SELECT
        analysis_period(invoice_month)                                                   AS period,
        SUM(gross_product_value)                                                         AS overall_value,
        SUM(gross_product_value) FILTER (WHERE customer_id IS NOT NULL)                  AS identified_value_invoice_route,
        COUNT(*) FILTER (WHERE is_qualifying_purchase)                                   AS qualifying_invoices,
        COUNT(*) FILTER (WHERE is_qualifying_purchase AND customer_id IS NOT NULL)       AS qualifying_invoices_identified
    FROM fct_invoice
    GROUP BY 1
),
cust AS (
    SELECT
        analysis_period(purchase_month)        AS period,
        COUNT(DISTINCT customer_id)            AS purchasing_customers,
        COUNT(*)                               AS purchase_days,
        SUM(gross_product_value)               AS identified_value
    FROM fct_customer_day
    GROUP BY 1
)
SELECT
    c.period,
    i.overall_value,
    c.identified_value,
    i.overall_value - c.identified_value                                         AS unidentified_value,
    ROUND(c.identified_value / i.overall_value, 4)                               AS identified_share,
    i.qualifying_invoices,
    i.qualifying_invoices_identified,
    ROUND(i.overall_value / i.qualifying_invoices, 2)                            AS aiv_overall,
    ROUND(c.identified_value / i.qualifying_invoices_identified, 2)              AS aiv_identified,
    c.purchasing_customers,
    c.purchase_days,
    ROUND(c.purchase_days / c.purchasing_customers, 4)                           AS purchase_days_per_customer,
    ROUND(c.identified_value / c.purchase_days, 2)                               AS value_per_purchase_day,
    ROUND(i.qualifying_invoices_identified / c.purchase_days, 4)                 AS identified_invoices_per_purchase_day,
    -- Identity check: customers x days/customer x value/day must equal identified value.
    ROUND(c.purchasing_customers * (c.purchase_days / c.purchasing_customers)
          * (c.identified_value / c.purchase_days) - c.identified_value, 6)      AS identity_residual
FROM cust AS c
JOIN inv AS i ON i.period = c.period
WHERE c.period IN ('A: Dec 2009-Nov 2010', 'B: Dec 2010-Nov 2011')
ORDER BY c.period;

-- bq2_driver_decomposition -----------------------------------------------------------
-- Business purpose: split the identified value change A -> B into three drivers.
-- Method: Shapley decomposition of V = C x F x S
--   C = purchasing customers, F = purchase days per customer, S = value per purchase day.
--   Each driver's effect is averaged over all 6 orders in which the drivers can be switched
--   from A to B, so interaction effects are shared symmetrically and the effects add up
--   exactly to the total change. min/max_sequential show the range over those orders.
-- Grain: one driver (plus total rows).
CREATE OR REPLACE VIEW bq2_driver_decomposition AS
WITH p AS (
    SELECT
        MAX(purchasing_customers) FILTER (WHERE period LIKE 'A%')::DOUBLE            AS ca,
        MAX(purchasing_customers) FILTER (WHERE period LIKE 'B%')::DOUBLE            AS cb,
        MAX(purchase_days * 1.0 / purchasing_customers) FILTER (WHERE period LIKE 'A%')::DOUBLE AS fa,
        MAX(purchase_days * 1.0 / purchasing_customers) FILTER (WHERE period LIKE 'B%')::DOUBLE AS fb,
        MAX(identified_value / purchase_days) FILTER (WHERE period LIKE 'A%')::DOUBLE AS sa,
        MAX(identified_value / purchase_days) FILTER (WHERE period LIKE 'B%')::DOUBLE AS sb,
        MAX(identified_value) FILTER (WHERE period LIKE 'A%')::DOUBLE                AS va,
        MAX(identified_value) FILTER (WHERE period LIKE 'B%')::DOUBLE                AS vb,
        MAX(overall_value) FILTER (WHERE period LIKE 'A%')::DOUBLE                   AS oa,
        MAX(overall_value) FILTER (WHERE period LIKE 'B%')::DOUBLE                   AS ob
    FROM bq2_period_summary
),
effects AS (
    -- For driver X with the other two drivers Y, Z: marginal effect (xB - xA) * y * z, where
    -- y, z are at A or B. Shapley weights: 1/3 (both A), 1/6 (one B), 1/6 (other B), 1/3 (both B).
    SELECT 'C: Purchasing customers' AS driver, ca AS a, cb AS b,
           (cb - ca) * (fa * sa / 3 + fb * sa / 6 + fa * sb / 6 + fb * sb / 3) AS shapley,
           LEAST((cb - ca) * fa * sa, (cb - ca) * fb * sa, (cb - ca) * fa * sb, (cb - ca) * fb * sb) AS min_seq,
           GREATEST((cb - ca) * fa * sa, (cb - ca) * fb * sa, (cb - ca) * fa * sb, (cb - ca) * fb * sb) AS max_seq,
           1 AS ord
    FROM p
    UNION ALL
    SELECT 'F: Purchase days per customer', fa, fb,
           (fb - fa) * (ca * sa / 3 + cb * sa / 6 + ca * sb / 6 + cb * sb / 3),
           LEAST((fb - fa) * ca * sa, (fb - fa) * cb * sa, (fb - fa) * ca * sb, (fb - fa) * cb * sb),
           GREATEST((fb - fa) * ca * sa, (fb - fa) * cb * sa, (fb - fa) * ca * sb, (fb - fa) * cb * sb),
           2
    FROM p
    UNION ALL
    SELECT 'S: Product value per purchase day', sa, sb,
           (sb - sa) * (ca * fa / 3 + cb * fa / 6 + ca * fb / 6 + cb * fb / 3),
           LEAST((sb - sa) * ca * fa, (sb - sa) * cb * fa, (sb - sa) * ca * fb, (sb - sa) * cb * fb),
           GREATEST((sb - sa) * ca * fa, (sb - sa) * cb * fa, (sb - sa) * ca * fb, (sb - sa) * cb * fb),
           3
    FROM p
)
SELECT driver, ROUND(a, 4) AS value_a, ROUND(b, 4) AS value_b, ROUND(b / a - 1, 4) AS pct_change,
       ROUND(shapley, 2) AS contribution_gbp,
       ROUND(shapley / (SELECT vb - va FROM p), 4) AS share_of_identified_change,
       ROUND(min_seq, 2) AS min_sequential_gbp, ROUND(max_seq, 2) AS max_sequential_gbp
FROM effects
UNION ALL
SELECT 'Total identified value change (V = C x F x S)', va, vb, ROUND(vb / va - 1, 4),
       ROUND(vb - va, 2), 1, NULL, NULL FROM p
UNION ALL
SELECT 'Unidentified value change (no Customer ID)', oa - va, ob - vb, ROUND((ob - vb) / (oa - va) - 1, 4),
       ROUND((ob - vb) - (oa - va), 2), NULL, NULL, NULL FROM p
UNION ALL
SELECT 'Overall value change (all qualifying invoices)', oa, ob, ROUND(ob / oa - 1, 4),
       ROUND(ob - oa, 2), NULL, NULL, NULL FROM p;

-- bq2_customer_flow -------------------------------------------------------------------
-- Business purpose: where the identified customers and value of each period come from.
-- Grain: one flow group. A customer "active" in a period has >= 1 purchase day in it.
-- "Active in A only" = not observed purchasing in B (not called churn).
CREATE OR REPLACE VIEW bq2_customer_flow AS
WITH per AS (
    SELECT customer_id,
           SUM(gross_product_value) FILTER (WHERE analysis_period(purchase_month) LIKE 'A%') AS value_a,
           SUM(gross_product_value) FILTER (WHERE analysis_period(purchase_month) LIKE 'B%') AS value_b,
           COUNT(*) FILTER (WHERE analysis_period(purchase_month) LIKE 'A%')                AS days_a,
           COUNT(*) FILTER (WHERE analysis_period(purchase_month) LIKE 'B%')                AS days_b
    FROM fct_customer_day
    WHERE purchase_month < DATE '2011-12-01'
    GROUP BY customer_id
),
grp AS (
    SELECT *,
           CASE WHEN days_a > 0 AND days_b > 0 THEN '1 Active in A and B'
                WHEN days_a > 0 THEN '2 Active in A only (not observed purchasing in B)'
                ELSE '3 First observed in B' END AS flow_group
    FROM per
)
SELECT
    flow_group,
    COUNT(*)                                              AS customers,
    COALESCE(SUM(value_a), 0)                             AS value_a,
    COALESCE(SUM(value_b), 0)                             AS value_b,
    COALESCE(SUM(value_b), 0) - COALESCE(SUM(value_a), 0) AS value_change,
    SUM(days_a)                                           AS purchase_days_a,
    SUM(days_b)                                           AS purchase_days_b,
    ROUND(MEDIAN(value_a), 2)                             AS median_customer_value_a,
    ROUND(MEDIAN(value_b), 2)                             AS median_customer_value_b
FROM grp
GROUP BY flow_group
ORDER BY flow_group;

-- bq2_monthly_yoy ---------------------------------------------------------------------
-- Business purpose: compare the same calendar month across the two periods (seasonality check).
-- Grain: one calendar month position (Dec ... Nov).
CREATE OR REPLACE VIEW bq2_monthly_yoy AS
SELECT
    strftime(b.month, '%b')                                                AS calendar_month,
    a.month                                                                AS month_a,
    b.month                                                                AS month_b,
    a.gross_product_value                                                  AS overall_value_a,
    b.gross_product_value                                                  AS overall_value_b,
    ROUND(b.gross_product_value / a.gross_product_value - 1, 4)            AS overall_value_change,
    a.gross_product_value_identified                                       AS identified_value_a,
    b.gross_product_value_identified                                       AS identified_value_b,
    a.active_customers                                                     AS active_customers_a,
    b.active_customers                                                     AS active_customers_b,
    ROUND(b.active_customers / a.active_customers - 1, 4)                  AS active_customers_change,
    a.identified_value_share                                               AS identified_share_a,
    b.identified_value_share                                               AS identified_share_b,
    a.is_observed_base_month                                               AS month_a_is_observed_base
FROM kpi_monthly AS b
JOIN kpi_monthly AS a ON a.month = CAST(b.month - INTERVAL 12 MONTH AS DATE)
WHERE b.month BETWEEN DATE '2010-12-01' AND DATE '2011-11-01'
ORDER BY b.month;
