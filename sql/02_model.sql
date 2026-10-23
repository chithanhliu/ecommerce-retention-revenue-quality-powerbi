-- =============================================================================
-- 02_model.sql — analytical model built on stg_transaction_line
--   fct_invoice       one row per invoice
--   fct_customer_day  one row per identified customer x purchase day (purchase occasion)
--   dim_customer      one row per identified Customer ID
-- "Normalized" values exclude the extreme reversal pairs; "_recorded" values keep them.
-- =============================================================================

-- fct_invoice -----------------------------------------------------------------
-- Business purpose: invoice counts and basket value (Average Invoice Value).
-- Grain: one invoice_no. Invoice date = earliest line timestamp (83 invoices span 1 minute).
CREATE OR REPLACE TABLE fct_invoice AS
SELECT
    invoice_no,
    ANY_VALUE(invoice_type)                                         AS invoice_type,
    MIN(invoice_ts)                                                 AS invoice_ts,
    CAST(MIN(invoice_ts) AS DATE)                                   AS invoice_date,
    CAST(date_trunc('month', MIN(invoice_ts)) AS DATE)              AS invoice_month,
    ANY_VALUE(customer_id)                                          AS customer_id,  -- one per invoice (validated)
    ANY_VALUE(country)                                              AS country,      -- one per invoice (validated)
    COUNT(*)                                                        AS line_count,
    SUM(line_value)                                                 AS all_recorded_value,
    COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_PURCHASE'), 0)
                                                                    AS gross_product_value_recorded,
    COALESCE(SUM(line_value) FILTER (WHERE is_normalized_purchase), 0)
                                                                    AS gross_product_value,
    COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION'), 0)
                                                                    AS product_cancellation_value_recorded,
    COALESCE(SUM(line_value) FILTER (WHERE transaction_class = 'PRODUCT_CANCELLATION'
                                       AND NOT is_extreme_reversal), 0)
                                                                    AS product_cancellation_value,
    COALESCE(SUM(line_value) FILTER (WHERE value_group = 'NON_PRODUCT'), 0)
                                                                    AS non_product_value,
    COUNT(*) FILTER (WHERE is_normalized_purchase) > 0              AS is_qualifying_purchase,
    BOOL_OR(is_extreme_reversal)                                    AS has_extreme_reversal
FROM stg_transaction_line
GROUP BY invoice_no;

-- fct_customer_day -------------------------------------------------------------
-- Business purpose: purchase occasions (definition: Customer ID x calendar day with a
--   qualifying purchase). Basis for frequency, 90-day repeat, cohorts, segmentation.
-- Grain: one identified customer x purchase_date.
CREATE OR REPLACE TABLE fct_customer_day AS
SELECT
    customer_id,
    invoice_date                                    AS purchase_date,
    CAST(date_trunc('month', invoice_date) AS DATE) AS purchase_month,
    COUNT(*)                                        AS qualifying_invoices,
    SUM(gross_product_value)                        AS gross_product_value
FROM fct_invoice
WHERE is_qualifying_purchase
  AND customer_id IS NOT NULL
GROUP BY customer_id, invoice_date;

-- dim_customer -----------------------------------------------------------------
-- Business purpose: one place for customer attributes (first-observed date, cohort,
--   country). Includes every Customer ID seen, so all facts can join to it.
-- Grain: one Customer ID. Purchase attributes are NULL/0 if the customer has no
--   qualifying purchase (e.g. cancellation-only IDs).
CREATE OR REPLACE TABLE dim_customer AS
WITH all_ids AS (
    SELECT DISTINCT customer_id FROM stg_transaction_line WHERE customer_id IS NOT NULL
),
purchases AS (
    SELECT
        customer_id,
        MIN(purchase_date)       AS first_purchase_date,
        MAX(purchase_date)       AS last_purchase_date,
        COUNT(*)                 AS purchase_days,
        SUM(qualifying_invoices) AS qualifying_invoices,
        SUM(gross_product_value) AS gross_product_value
    FROM fct_customer_day
    GROUP BY customer_id
),
country_rank AS (
    -- Primary country = country on most qualifying purchase invoices (13 customers have 2 countries)
    SELECT
        customer_id,
        country,
        ROW_NUMBER() OVER (PARTITION BY customer_id
                           ORDER BY COUNT(*) FILTER (WHERE is_qualifying_purchase) DESC,
                                    COUNT(*) DESC, country) AS country_rank,
        COUNT(*) OVER (PARTITION BY customer_id)            AS country_count
    FROM fct_invoice
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id, country
)
SELECT
    a.customer_id,
    c.country                                                AS primary_country,
    c.country_count,
    p.customer_id IS NOT NULL                                AS has_qualifying_purchase,
    p.first_purchase_date,
    CAST(date_trunc('month', p.first_purchase_date) AS DATE) AS first_observed_month,
    COALESCE(date_trunc('month', p.first_purchase_date) = observed_base_month(), FALSE)
                                                             AS is_observed_base,
    p.last_purchase_date,
    COALESCE(p.purchase_days, 0)                             AS purchase_days,
    COALESCE(p.qualifying_invoices, 0)                       AS qualifying_invoices,
    COALESCE(p.gross_product_value, 0)                       AS gross_product_value
FROM all_ids AS a
JOIN country_rank AS c ON c.customer_id = a.customer_id AND c.country_rank = 1
LEFT JOIN purchases AS p ON p.customer_id = a.customer_id;
