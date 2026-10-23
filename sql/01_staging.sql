-- =============================================================================
-- 01_staging.sql
-- Business purpose: one combined, classified and flagged record per recorded
--   transaction line, so every metric starts from the same reconciled base.
-- Grain: one source invoice line (Dec-2010 cross-sheet overlap counted once).
-- Key:   line_id = '<source_sheet>:<Excel row>'.
-- Rules: KPI Framework v1.0. No row is deleted; rows are
--   classified and flagged instead.
-- =============================================================================

-- Reporting constants used across the pipeline -------------------------------
CREATE OR REPLACE MACRO observed_base_month() AS DATE '2009-12-01';  -- data start; history before it unknown
CREATE OR REPLACE MACRO history_start_month() AS DATE '2009-12-01';
CREATE OR REPLACE MACRO history_end_month()   AS DATE '2011-11-01';  -- last full month
CREATE OR REPLACE MACRO segment_start_month() AS DATE '2010-12-01';
CREATE OR REPLACE MACRO segment_end_month()   AS DATE '2011-11-01';
CREATE OR REPLACE MACRO last_complete_date()  AS DATE '2011-12-08';  -- 2011-12-09 ends at 12:50 (partial day)
CREATE OR REPLACE MACRO repeat_window_days()  AS 90;

CREATE OR REPLACE TABLE stg_transaction_line AS
WITH combined AS (
    SELECT '2009-2010' AS source_sheet, s1.*
    FROM raw_sheet_2009_2010 AS s1
    UNION ALL
    -- The 2010-2011 sheet repeats invoices of 1-9 Dec 2010 that are already in the
    -- 2009-2010 sheet (identical rows, Stage 1 audit 2.2). Add only invoices not seen yet.
    SELECT '2010-2011' AS source_sheet, s2.*
    FROM raw_sheet_2010_2011 AS s2
    WHERE s2."Invoice" NOT IN (SELECT "Invoice" FROM raw_sheet_2009_2010)
),

typed AS (
    SELECT
        source_sheet || ':' || source_row              AS line_id,
        source_sheet,
        source_row,
        "Invoice"                                      AS invoice_no,
        CASE WHEN "Invoice" LIKE 'C%' THEN 'CANCELLATION'
             WHEN "Invoice" LIKE 'A%' THEN 'ADJUSTMENT'
             ELSE 'STANDARD' END                       AS invoice_type,
        "StockCode"                                    AS stock_code,
        "Description"                                  AS description,
        "Quantity"                                     AS quantity,
        CAST("Price" AS DECIMAL(18, 3))                AS unit_price,
        "InvoiceDate"                                  AS invoice_ts,
        CAST("Customer ID" AS INTEGER)                 AS customer_id,
        "Country"                                      AS country
    FROM combined
),

classified AS (
    SELECT
        *,
        quantity * unit_price AS line_value,
        -- Rules are checked top to bottom; the first match decides the class.
        CASE
            WHEN invoice_type = 'ADJUSTMENT' OR stock_code = 'B'        THEN 'BAD_DEBT_ADJUSTMENT'
            -- C3 is not listed here: its only line has no description, qty -4999 and price 0,
            -- the pattern of a stock adjustment, not carriage. It falls through to ZERO_PRICE.
            WHEN stock_code IN ('POST', 'DOT', 'C2')                    THEN 'SHIPPING'
            WHEN stock_code IN ('AMAZONFEE', 'BANK CHARGES', 'CRUK')    THEN 'FEE'
            WHEN stock_code IN ('M', 'm', 'ADJUST', 'ADJUST2')          THEN 'MANUAL_ADJUSTMENT'
            WHEN stock_code = 'D'                                       THEN 'DISCOUNT'
            WHEN stock_code = 'S'                                       THEN 'SAMPLE'
            WHEN stock_code LIKE 'gift\_0001\_%' ESCAPE '\'
              OR stock_code = 'GIFT'                                    THEN 'VOUCHER'
            WHEN stock_code IN ('TEST001', 'TEST002')                   THEN 'TEST'
            WHEN invoice_type = 'CANCELLATION'                          THEN 'PRODUCT_CANCELLATION'
            WHEN unit_price = 0                                         THEN 'ZERO_PRICE'
            WHEN quantity > 0 AND unit_price > 0                        THEN 'PRODUCT_PURCHASE'
            ELSE 'UNCLASSIFIED'
        END AS transaction_class
    FROM typed
),

grouped AS (
    SELECT
        *,
        CASE transaction_class
            WHEN 'PRODUCT_PURCHASE'     THEN 'GROSS_PRODUCT'
            WHEN 'PRODUCT_CANCELLATION' THEN 'PRODUCT_CANCELLATION'
            WHEN 'ZERO_PRICE'           THEN 'ZERO_PRICE'
            WHEN 'UNCLASSIFIED'         THEN 'UNCLASSIFIED'
            ELSE 'NON_PRODUCT'
        END AS value_group
    FROM classified
),

-- Extreme reversal pairs (Stage 1 audit): a purchase line of >= 10,000 units
-- cancelled by the same customer, StockCode, quantity and price within 60 minutes.
extreme_pairs AS (
    SELECT p.line_id AS purchase_line_id, c.line_id AS cancellation_line_id, p.invoice_no AS pair_id
    FROM grouped AS p
    JOIN grouped AS c
      ON  c.customer_id = p.customer_id
      AND c.stock_code  = p.stock_code
      AND c.quantity    = -p.quantity
      AND c.unit_price  = p.unit_price
      AND c.invoice_ts BETWEEN p.invoice_ts AND p.invoice_ts + INTERVAL 60 MINUTE
    WHERE p.transaction_class = 'PRODUCT_PURCHASE' AND p.quantity >= 10000
      AND c.transaction_class = 'PRODUCT_CANCELLATION'
),

extreme_lines AS (
    SELECT purchase_line_id AS line_id, pair_id FROM extreme_pairs
    UNION
    SELECT cancellation_line_id, pair_id FROM extreme_pairs
)

SELECT
    g.*,
    g.customer_id IS NOT NULL                       AS has_customer_id,
    -- Identical in all 8 source fields: kept and flagged, never removed (Stage 1 audit).
    COUNT(*) OVER (PARTITION BY g.invoice_no, g.stock_code, g.description, g.quantity,
                                g.invoice_ts, g.unit_price, g.customer_id, g.country) > 1
                                                    AS is_exact_dup_candidate,
    ROW_NUMBER() OVER (PARTITION BY g.invoice_no, g.stock_code, g.description, g.quantity,
                                    g.invoice_ts, g.unit_price, g.customer_id, g.country
                       ORDER BY g.source_sheet, g.source_row)
                                                    AS dup_copy_number,
    e.line_id IS NOT NULL                           AS is_extreme_reversal,
    e.pair_id                                       AS extreme_pair_id,
    -- Normalized purchase = product purchase that is not part of an extreme reversal pair.
    g.transaction_class = 'PRODUCT_PURCHASE' AND e.line_id IS NULL
                                                    AS is_normalized_purchase
FROM grouped AS g
LEFT JOIN extreme_lines AS e ON e.line_id = g.line_id;
