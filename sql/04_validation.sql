-- =============================================================================
-- 04_validation.sql — automated checks for the Stage 2 model and KPIs.
-- Each check returns expected vs actual; "expected" is either an independent
-- figure from the Stage 1 pandas audit or a recomputation by a different route.
-- Result: table validation_results (check_no, area, check_name, expected, actual, passed).
-- =============================================================================
CREATE OR REPLACE TABLE validation_results AS
WITH
s1 AS (SELECT * EXCLUDE (source_row) FROM raw_sheet_2009_2010),
s2 AS (SELECT * EXCLUDE (source_row) FROM raw_sheet_2010_2011),
s2_overlap AS (SELECT * FROM s2 WHERE "Invoice" IN (SELECT "Invoice" FROM s1)),
s1_overlap AS (SELECT * FROM s1 WHERE "Invoice" IN (SELECT "Invoice" FROM s2)),
stg AS (SELECT * FROM stg_transaction_line),
stg_total AS (SELECT SUM(line_value) AS v, COUNT(*) AS n FROM stg),
raw_value AS (  -- independent route: raw sheets minus the repeated overlap, same price precision
    SELECT (SELECT SUM("Quantity" * CAST("Price" AS DECIMAL(18, 3))) FROM s1)
         + (SELECT SUM("Quantity" * CAST("Price" AS DECIMAL(18, 3))) FROM s2)
         - (SELECT SUM("Quantity" * CAST("Price" AS DECIMAL(18, 3))) FROM s2_overlap) AS v
),
recon AS (SELECT * FROM kpi_value_reconciliation),
id_norm AS (
    SELECT SUM(line_value) AS v FROM stg WHERE is_normalized_purchase AND has_customer_id
),
cust_repeat_lead AS (  -- independent route for the 90-day numerator: next purchase day via LEAD
    SELECT customer_id, purchase_date,
           LEAD(purchase_date) OVER (PARTITION BY customer_id ORDER BY purchase_date) AS next_date,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY purchase_date) AS n
    FROM fct_customer_day
),
-- Independent class totals from the Stage 1 pandas scripts (rows / GBP rounded).
-- SHIPPING and ZERO_PRICE reflect the single C3 line (value 0) classed as ZERO_PRICE.
class_expected AS (
    SELECT * FROM (VALUES
        (1,  'PRODUCT_PURCHASE',     1015088, 19700954),
        (2,  'PRODUCT_CANCELLATION',   17974,  -719693),
        (3,  'SHIPPING',                3788,   433411),
        (4,  'FEE',                      152,  -264936),
        (5,  'BAD_DEBT_ADJUSTMENT',        6,  -147614),
        (6,  'MANUAL_ADJUSTMENT',       1473,   -75369),
        (7,  'DISCOUNT',                 173,   -12880),
        (8,  'SAMPLE',                   102,    -6001),
        (9,  'VOUCHER+TEST',             118,     1890),
        (10, 'ZERO_PRICE',              5974,        0)
    ) AS t(ord, grp, exp_rows, exp_value)
),
class_actual AS (
    SELECT CASE WHEN transaction_class IN ('VOUCHER', 'TEST') THEN 'VOUCHER+TEST' ELSE transaction_class END AS grp,
           COUNT(*) AS act_rows, CAST(ROUND(SUM(line_value), 0) AS BIGINT) AS act_value
    FROM stg GROUP BY 1
),
-- Independent routes built straight from staging lines (not from the model tables).
ind_lines AS (
    SELECT customer_id, invoice_no, line_value, CAST(date_trunc('month', invoice_ts) AS DATE) AS m
    FROM stg WHERE is_normalized_purchase AND has_customer_id
),
ind_first AS (SELECT customer_id, MIN(m) AS cm FROM ind_lines GROUP BY customer_id),
ind_cells AS (
    SELECT f.cm, date_diff('month', f.cm, l.m) AS k, COUNT(DISTINCT l.customer_id) AS active
    FROM ind_lines AS l JOIN ind_first AS f USING (customer_id)
    WHERE l.m <= DATE '2011-11-01'
    GROUP BY f.cm, date_diff('month', f.cm, l.m)
),
kpi_cells AS (
    SELECT cohort_month AS cm, months_since_first AS k, active_customers AS active
    FROM kpi_cohort_retention WHERE active_customers > 0
),
ind_seg AS (
    SELECT customer_id, SUM(line_value) AS v FROM ind_lines
    WHERE m BETWEEN DATE '2010-12-01' AND DATE '2011-11-01' GROUP BY customer_id
),
hist_lines AS (
    SELECT * FROM stg WHERE is_normalized_purchase AND invoice_ts >= DATE '2009-12-01' AND invoice_ts < DATE '2011-12-01'
),
checks AS (
    -- 1. Raw and combined row counts
    SELECT 1 AS check_no, 'Row counts' AS area, 'Raw rows, sheet Year 2009-2010' AS check_name,
           '525461' AS expected, CAST((SELECT COUNT(*) FROM s1) AS VARCHAR) AS actual
    UNION ALL SELECT 2, 'Row counts', 'Raw rows, sheet Year 2010-2011',
           '541910', CAST((SELECT COUNT(*) FROM s2) AS VARCHAR)
    UNION ALL SELECT 3, 'Row counts', 'Combined rows = raw rows - repeated overlap rows (= 1,044,848 in Stage 1)',
           CAST((SELECT COUNT(*) FROM s1) + (SELECT COUNT(*) FROM s2) - (SELECT COUNT(*) FROM s2_overlap) AS VARCHAR)
           || ' / 1044848', CAST((SELECT n FROM stg_total) AS VARCHAR) || ' / ' || CAST((SELECT n FROM stg_total) AS VARCHAR)
    -- 2. Cross-sheet overlap counted once
    UNION ALL SELECT 4, 'Overlap', 'Overlap invoices / rows found in both sheets',
           '1088 / 22523', CAST((SELECT COUNT(DISTINCT "Invoice") FROM s2_overlap) AS VARCHAR) || ' / '
                           || CAST((SELECT COUNT(*) FROM s2_overlap) AS VARCHAR)
    UNION ALL SELECT 5, 'Overlap', 'Overlap rows identical in both sheets (rows differing, both directions)',
           '0', CAST((SELECT COUNT(*) FROM (SELECT * FROM s1_overlap EXCEPT ALL SELECT * FROM s2_overlap))
                   + (SELECT COUNT(*) FROM (SELECT * FROM s2_overlap EXCEPT ALL SELECT * FROM s1_overlap)) AS VARCHAR)
    UNION ALL SELECT 6, 'Overlap', 'Invoices taken from more than one sheet in staging',
           '0', CAST((SELECT COUNT(*) FROM (SELECT invoice_no FROM stg GROUP BY invoice_no
                                            HAVING COUNT(DISTINCT source_sheet) > 1)) AS VARCHAR)
    -- 3. Classification coverage
    UNION ALL SELECT 7, 'Classification', 'line_id unique (distinct line_id = rows)',
           CAST((SELECT n FROM stg_total) AS VARCHAR), CAST((SELECT COUNT(DISTINCT line_id) FROM stg) AS VARCHAR)
    UNION ALL SELECT 8, 'Classification', 'Unclassified lines',
           '0', CAST((SELECT COUNT(*) FROM stg WHERE transaction_class = 'UNCLASSIFIED') AS VARCHAR)
    UNION ALL SELECT 9, 'Classification', 'Rows across class rows of reconciliation = staging rows',
           CAST((SELECT n FROM stg_total) AS VARCHAR),
           CAST((SELECT SUM(line_count) FROM recon WHERE transaction_class NOT IN ('SUBTOTAL', 'ALL_RECORDED_NET')) AS VARCHAR)
    UNION ALL SELECT 10, 'Classification', 'Non-product / zero-price rows (Stage 1 audit 5,813 / 5,973; C3 line classed as ZERO_PRICE)',
           '5812 / 5974', CAST((SELECT COUNT(*) FROM stg WHERE value_group = 'NON_PRODUCT') AS VARCHAR) || ' / '
                          || CAST((SELECT COUNT(*) FROM stg WHERE value_group = 'ZERO_PRICE') AS VARCHAR)
    -- 4. Value reconciliation
    UNION ALL SELECT 11, 'Reconciliation', 'All-recorded net = raw value recomputed from raw sheets (GBP)',
           CAST((SELECT v FROM raw_value) AS VARCHAR), CAST((SELECT v FROM stg_total) AS VARCHAR)
    UNION ALL SELECT 12, 'Reconciliation', 'All-recorded net = Stage 1 pandas figure (GBP, 2 dp)',
           '18909762.12', CAST(ROUND((SELECT v FROM stg_total), 2) AS VARCHAR)
    UNION ALL SELECT 13, 'Reconciliation', 'Sum of class values = all-recorded net',
           CAST((SELECT v FROM stg_total) AS VARCHAR),
           CAST((SELECT SUM(recorded_value) FROM recon WHERE transaction_class NOT IN ('SUBTOTAL', 'ALL_RECORDED_NET')) AS VARCHAR)
    UNION ALL SELECT 14, 'Reconciliation', 'Normalized total + extreme reversal value = recorded total',
           CAST((SELECT v FROM stg_total) AS VARCHAR),
           CAST((SELECT normalized_value + extreme_reversal_value FROM recon WHERE transaction_class = 'ALL_RECORDED_NET') AS VARCHAR)
    -- 5. No value duplicated by aggregation or joins
    UNION ALL SELECT 15, 'Join integrity', 'fct_invoice rows = distinct invoices; value = staging value',
           CAST((SELECT COUNT(DISTINCT invoice_no) FROM stg) AS VARCHAR) || ' / ' || CAST((SELECT v FROM stg_total) AS VARCHAR),
           CAST((SELECT COUNT(*) FROM fct_invoice) AS VARCHAR) || ' / ' || CAST((SELECT SUM(all_recorded_value) FROM fct_invoice) AS VARCHAR)
    UNION ALL SELECT 16, 'Join integrity', 'fct_customer_day value = identified normalized purchase lines',
           CAST((SELECT v FROM id_norm) AS VARCHAR), CAST((SELECT SUM(gross_product_value) FROM fct_customer_day) AS VARCHAR)
    UNION ALL SELECT 17, 'Join integrity', 'dim_customer: unique key; value = fct_customer_day value',
           CAST((SELECT COUNT(DISTINCT customer_id) FROM dim_customer) AS VARCHAR) || ' / ' || CAST((SELECT v FROM id_norm) AS VARCHAR),
           CAST((SELECT COUNT(*) FROM dim_customer) AS VARCHAR) || ' / ' || CAST((SELECT SUM(gross_product_value) FROM dim_customer) AS VARCHAR)
    UNION ALL SELECT 18, 'Join integrity', 'kpi_monthly gross (Dec 2009-Nov 2011) = staging normalized gross by line month',
           CAST((SELECT SUM(line_value) FROM stg WHERE is_normalized_purchase
                 AND invoice_ts >= DATE '2009-12-01' AND invoice_ts < DATE '2011-12-01') AS VARCHAR),
           CAST((SELECT SUM(gross_product_value) FROM kpi_monthly) AS VARCHAR)
    UNION ALL SELECT 19, 'Join integrity', 'Invoices with more than one Customer ID / country',
           '0 / 0', CAST((SELECT COUNT(*) FROM (SELECT invoice_no FROM stg GROUP BY invoice_no
                                                HAVING COUNT(DISTINCT customer_id) > 1)) AS VARCHAR) || ' / '
                    || CAST((SELECT COUNT(*) FROM (SELECT invoice_no FROM stg GROUP BY invoice_no
                                                   HAVING COUNT(DISTINCT country) > 1)) AS VARCHAR)
    -- 6. Customer ID coverage
    UNION ALL SELECT 20, 'Customer coverage', 'Lines without Customer ID (Stage 1: 235,287)',
           '235287', CAST((SELECT COUNT(*) FROM stg WHERE NOT has_customer_id) AS VARCHAR)
    UNION ALL SELECT 21, 'Customer coverage', 'Distinct Customer IDs (5,942) / with qualifying purchase (5,852)',
           '5942 / 5852', CAST((SELECT COUNT(*) FROM dim_customer) AS VARCHAR) || ' / '
                          || CAST((SELECT COUNT(*) FROM dim_customer WHERE has_qualifying_purchase) AS VARCHAR)
    UNION ALL SELECT 22, 'Customer coverage', 'Identified share of normalized gross: line route = invoice route',
           CAST(ROUND((SELECT v FROM id_norm) / (SELECT SUM(line_value) FROM stg WHERE is_normalized_purchase), 6) AS VARCHAR),
           CAST(ROUND((SELECT SUM(gross_product_value) FILTER (WHERE customer_id IS NOT NULL) FROM fct_invoice)
                      / (SELECT SUM(gross_product_value) FROM fct_invoice), 6) AS VARCHAR)
    -- 7. Purchase days vs invoices
    UNION ALL SELECT 23, 'Frequency', 'Purchase days = distinct customer x date pairs from qualifying lines',
           CAST((SELECT COUNT(*) FROM (SELECT DISTINCT l.customer_id, i.invoice_date FROM stg AS l
                 JOIN fct_invoice AS i ON i.invoice_no = l.invoice_no
                 WHERE l.is_normalized_purchase AND l.has_customer_id)) AS VARCHAR),
           CAST((SELECT COUNT(*) FROM fct_customer_day) AS VARCHAR)
    UNION ALL SELECT 24, 'Frequency', 'fct_customer_day unique per customer x date',
           '0', CAST((SELECT COUNT(*) FROM (SELECT customer_id, purchase_date FROM fct_customer_day
                                            GROUP BY ALL HAVING COUNT(*) > 1)) AS VARCHAR)
    UNION ALL SELECT 25, 'Frequency', 'Purchase days (sum) < identified qualifying invoices (they must differ)',
           'days < invoices',
           CAST((SELECT SUM(purchase_days) FROM dim_customer) AS VARCHAR) || ' < '
           || CAST((SELECT COUNT(*) FROM fct_invoice WHERE is_qualifying_purchase AND customer_id IS NOT NULL) AS VARCHAR)
    -- 8. 90-day repeat
    UNION ALL SELECT 26, '90-day repeat', 'Latest eligible first purchase day (must be <= 2011-09-09)',
           '<= 2011-09-09', CAST((SELECT MAX(first_purchase_date) FROM customer_repeat_90d WHERE is_eligible) AS VARCHAR)
    UNION ALL SELECT 27, '90-day repeat', 'Ineligible customers with first purchase day <= 2011-09-09',
           '0', CAST((SELECT COUNT(*) FROM customer_repeat_90d
                      WHERE NOT is_eligible AND first_purchase_date <= DATE '2011-09-09') AS VARCHAR)
    UNION ALL SELECT 28, '90-day repeat', 'Numerator: EXISTS route = LEAD (next purchase day) route',
           CAST((SELECT COUNT(*) FROM cust_repeat_lead AS l JOIN customer_repeat_90d AS r USING (customer_id)
                 WHERE l.n = 1 AND r.is_eligible
                   AND l.next_date BETWEEN l.purchase_date + 1 AND l.purchase_date + 90) AS VARCHAR),
           CAST((SELECT COUNT(*) FROM customer_repeat_90d WHERE is_eligible AND repeated_within_90d) AS VARCHAR)
    -- 9. Cohorts
    UNION ALL SELECT 29, 'Cohorts', 'Sum of cohort sizes = customers first observed Dec 2009-Nov 2011',
           CAST((SELECT COUNT(*) FROM dim_customer WHERE has_qualifying_purchase
                 AND first_observed_month BETWEEN DATE '2009-12-01' AND DATE '2011-11-01') AS VARCHAR),
           CAST((SELECT SUM(cohort_size) FROM kpi_cohort_retention WHERE months_since_first = 0) AS VARCHAR)
    UNION ALL SELECT 30, 'Cohorts', 'Month-0 retention = 100% for every cohort (cohorts not at 100%)',
           '0', CAST((SELECT COUNT(*) FROM kpi_cohort_retention WHERE months_since_first = 0 AND retention_rate <> 1) AS VARCHAR)
    UNION ALL SELECT 31, 'Cohorts', 'Cells NULL exactly when activity month > Nov 2011 (violations)',
           '0', CAST((SELECT COUNT(*) FROM kpi_cohort_retention
                      WHERE (activity_month > DATE '2011-11-01') <> (retention_rate IS NULL)) AS VARCHAR)
    UNION ALL SELECT 32, 'Cohorts', 'Active customers <= cohort size (violations)',
           '0', CAST((SELECT COUNT(*) FROM kpi_cohort_retention WHERE active_customers > cohort_size) AS VARCHAR)
    -- 10. Extreme reversal pairs
    UNION ALL SELECT 33, 'Extreme reversals', 'Flagged lines / pairs',
           '4 / 2', CAST((SELECT COUNT(*) FROM stg WHERE is_extreme_reversal) AS VARCHAR) || ' / '
                    || CAST((SELECT COUNT(DISTINCT extreme_pair_id) FROM stg WHERE is_extreme_reversal) AS VARCHAR)
    UNION ALL SELECT 34, 'Extreme reversals', 'Flagged invoices = Stage 1 audit list',
           '541431,581483,C541433,C581484',
           (SELECT string_agg(invoice_no, ',' ORDER BY invoice_no) FROM stg WHERE is_extreme_reversal)
    UNION ALL SELECT 35, 'Extreme reversals', 'Net value of flagged lines / gross removed (Stage 1: 245,653.20)',
           '0.000 / 245653.200', CAST((SELECT SUM(line_value) FROM stg WHERE is_extreme_reversal) AS VARCHAR) || ' / '
           || CAST((SELECT SUM(line_value) FROM stg WHERE is_extreme_reversal AND quantity > 0) AS VARCHAR)
    UNION ALL SELECT 36, 'Extreme reversals', 'Customers 12346 and 16446 keep other qualifying purchases',
           '2', CAST((SELECT COUNT(*) FROM dim_customer WHERE customer_id IN (12346, 16446) AND has_qualifying_purchase) AS VARCHAR)
    -- Other retained-record checks
    UNION ALL SELECT 37, 'Retention of records', 'Exact duplicate candidates kept: rows in groups / extra copies',
           '22813 / 11812', CAST((SELECT COUNT(*) FROM stg WHERE is_exact_dup_candidate) AS VARCHAR) || ' / '
                            || CAST((SELECT COUNT(*) FROM stg WHERE dup_copy_number > 1) AS VARCHAR)
    UNION ALL SELECT 38, 'Retention of records', 'Raw prices with more than 3 decimals (DECIMAL(18,3) safe)',
           '0', CAST((SELECT COUNT(*) FROM (SELECT "Price" FROM s1 UNION ALL SELECT "Price" FROM s2)
                      WHERE ABS("Price" - ROUND("Price", 3)) > 1e-9) AS VARCHAR)
    -- 11. Classification vs independent Stage 1 totals (checks 39-48)
    UNION ALL SELECT 38 + e.ord, 'Classification (independent)',
           'Class ' || e.grp || ': rows / GBP vs Stage 1 pandas',
           CAST(e.exp_rows AS VARCHAR) || ' / ' || CAST(e.exp_value AS VARCHAR),
           COALESCE(CAST(a.act_rows AS VARCHAR), '0') || ' / ' || COALESCE(CAST(a.act_value AS VARCHAR), '0')
    FROM class_expected AS e LEFT JOIN class_actual AS a ON a.grp = e.grp
    UNION ALL SELECT 49, 'Classification (rules)', 'Lines breaking their class definition (purchase qty/price > 0, cancellation on C invoice, zero price = 0)',
           '0', CAST((SELECT COUNT(*) FROM stg WHERE
                 (transaction_class = 'PRODUCT_PURCHASE' AND (quantity <= 0 OR unit_price <= 0))
              OR (transaction_class = 'PRODUCT_CANCELLATION' AND invoice_type <> 'CANCELLATION')
              OR (transaction_class = 'ZERO_PRICE' AND unit_price <> 0)) AS VARCHAR)
    UNION ALL SELECT 50, 'Classification (rules)', 'C3 evidence: class / description / quantity / price',
           'ZERO_PRICE / none / -4999 / 0.000',
           (SELECT transaction_class || ' / ' || COALESCE(description, 'none') || ' / ' || CAST(quantity AS VARCHAR)
                   || ' / ' || CAST(unit_price AS VARCHAR) FROM stg WHERE stock_code = 'C3')
    -- 12. KPI checks by independent routes
    UNION ALL SELECT 51, 'KPI (independent)', 'Monthly active customers summed: staging lines route = kpi_monthly',
           CAST((SELECT SUM(n) FROM (SELECT m, COUNT(DISTINCT customer_id) AS n FROM ind_lines
                 WHERE m <= DATE '2011-11-01' GROUP BY m)) AS VARCHAR),
           CAST((SELECT SUM(active_customers) FROM kpi_monthly) AS VARCHAR)
    UNION ALL SELECT 52, 'KPI (independent)', 'Overall AIV Dec 2009-Nov 2011 (all qualifying invoices): lines route = kpi_monthly',
           CAST(ROUND((SELECT SUM(line_value) / COUNT(DISTINCT invoice_no) FROM hist_lines), 4) AS VARCHAR),
           CAST(ROUND((SELECT SUM(gross_product_value) / SUM(qualifying_invoices) FROM kpi_monthly), 4) AS VARCHAR)
    UNION ALL SELECT 53, 'KPI (independent)', 'Identified AIV Dec 2009-Nov 2011 (invoices with Customer ID): lines route = kpi_monthly',
           CAST(ROUND((SELECT SUM(line_value) / COUNT(DISTINCT invoice_no) FROM hist_lines WHERE has_customer_id), 4) AS VARCHAR),
           CAST(ROUND((SELECT SUM(gross_product_value_identified) / SUM(qualifying_invoices_identified) FROM kpi_monthly), 4) AS VARCHAR)
    UNION ALL SELECT 54, 'KPI (independent)', '90-day eligible customers: all / excl. Dec 2009 (Stage 1 pandas 5,256 / 4,305)',
           '5256 / 4305',
           (SELECT CAST(MAX(eligible_customers) FILTER (WHERE population LIKE '1%') AS VARCHAR) || ' / '
                || CAST(MAX(eligible_customers) FILTER (WHERE population LIKE '2%') AS VARCHAR) FROM kpi_repeat_90d)
    UNION ALL SELECT 55, 'KPI (independent)', 'Cohort cells: active customers from staging lines vs kpi_cohort_retention (mismatched cells)',
           '0', CAST((SELECT COUNT(*) FROM ind_cells AS i FULL OUTER JOIN kpi_cells AS c USING (cm, k)
                      WHERE i.active IS DISTINCT FROM c.active) AS VARCHAR)
    UNION ALL SELECT 56, 'KPI (independent)', 'Top 20% value share (segmentation window): lines route = kpi_concentration',
           CAST((SELECT ROUND(SUM(v) FILTER (WHERE rn <= FLOOR(n * 0.2)) / SUM(v), 4)
                 FROM (SELECT v, ROW_NUMBER() OVER (ORDER BY v DESC, customer_id) AS rn, COUNT(*) OVER () AS n FROM ind_seg)) AS VARCHAR),
           CAST((SELECT share_of_identified_value FROM kpi_concentration WHERE top_share = 0.20) AS VARCHAR)
    UNION ALL SELECT 57, 'KPI (independent)', 'Segmentation customers: lines route = all customers = tenure A + B',
           CAST((SELECT COUNT(*) FROM ind_seg) AS VARCHAR) || ' / ' || CAST((SELECT COUNT(*) FROM ind_seg) AS VARCHAR),
           CAST((SELECT customers FROM kpi_segmentation_distribution WHERE tenure_group = 'All customers') AS VARCHAR) || ' / '
           || CAST((SELECT SUM(customers) FROM kpi_segmentation_distribution WHERE tenure_group <> 'All customers') AS VARCHAR)
    UNION ALL SELECT 58, 'KPI (consistency)', 'Time to 2nd purchase at 90 days = 90-day repeat (eligible / converted)',
           (SELECT CAST(eligible_customers AS VARCHAR) || ' / ' || CAST(repeat_customers AS VARCHAR)
            FROM kpi_repeat_90d WHERE population LIKE '1%'),
           (SELECT CAST(eligible_customers AS VARCHAR) || ' / ' || CAST(converted_customers AS VARCHAR)
            FROM kpi_time_to_second_purchase WHERE population LIKE '1%' AND window_days = 90)
    UNION ALL SELECT 59, 'KPI (consistency)', 'Second purchase on the same day as the first, or before it (violations)',
           '0', CAST((SELECT COUNT(*) FROM customer_second_purchase WHERE days_to_second_purchase < 1) AS VARCHAR)
    UNION ALL SELECT 60, 'KPI (consistency)', '90-day rows: eligible + not eligible = customers; min-sample flag = (eligible >= 100) (violations)',
           '0', CAST((SELECT COUNT(*) FROM kpi_repeat_90d
                      WHERE eligible_customers + not_yet_eligible_customers <> customers
                         OR meets_min_sample <> (eligible_customers >= 100)) AS VARCHAR)
)
SELECT
    check_no, area, check_name, expected, actual,
    CASE
        WHEN check_no = 25 THEN (SELECT SUM(purchase_days) FROM dim_customer)
                              < (SELECT COUNT(*) FROM fct_invoice WHERE is_qualifying_purchase AND customer_id IS NOT NULL)
        WHEN check_no = 26 THEN CAST(actual AS DATE) <= DATE '2011-09-09'
        WHEN check_no = 3  THEN split_part(expected, ' / ', 1) = split_part(actual, ' / ', 1)
                            AND split_part(expected, ' / ', 2) = split_part(actual, ' / ', 2)
        ELSE expected = actual
    END AS passed
FROM checks
ORDER BY check_no;
