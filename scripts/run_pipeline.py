"""Pipeline runner (DuckDB): staging, model, KPIs, analysis views and Power BI export.

1. Loads the two raw worksheets into DuckDB unchanged (only on first run or with --reload).
2. Runs sql/01_staging.sql -> 04_validation.sql in order.
3. Prints the validation results and exports aggregated KPI tables to outputs/ as CSV.
4. Stage 4: writes the ID-free Power BI tables to data/powerbi/*.parquet (git-ignored) and
   checks every exported file (row count and identifier columns).

Usage:  .venv/Scripts/python scripts/run_pipeline.py [--reload]
Exit code 1 if any validation check fails.
"""
import sys
from pathlib import Path

import duckdb
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW_XLSX = ROOT / "data" / "raw" / "extracted" / "online_retail_II.xlsx"
DB_PATH = ROOT / "data" / "processed" / "online_retail.duckdb"
SQL_FILES = ["01_staging.sql", "02_model.sql", "03_kpis.sql", "04_validation.sql",
             # Stage 3 analysis views and their checks
             "10_bq1_value_reliability.sql", "11_bq2_commercial_performance.sql",
             "12_bq3_retention.sql", "13_bq4_segmentation.sql", "14_stage3_checks.sql",
             # Stage 4 Power BI shaping layer and its checks
             "20_powerbi_shaping.sql", "21_powerbi_checks.sql"]
RAW_TABLES = {"Year 2009-2010": "raw_sheet_2009_2010", "Year 2010-2011": "raw_sheet_2010_2011"}
# Aggregated outputs only (no customer-level tables) are exported as CSV.
EXPORTS = ["validation_results", "kpi_value_reconciliation", "kpi_monthly", "kpi_repeat_90d",
           "kpi_time_to_second_purchase", "kpi_cohort_retention", "kpi_segmentation_distribution",
           "kpi_segmentation_frequency", "kpi_segmentation_tenure", "kpi_concentration",
           "kpi_extreme_sensitivity"]
STAGE3_EXPORTS = ["stage3_checks", "bq1_value_bridge", "bq1_monthly_reliability", "bq1_cancellation_concentration", "bq2_period_summary",
                  "bq2_driver_decomposition", "bq2_customer_flow", "bq2_monthly_yoy", "bq3_repeat_summary",
                  "bq3_cohort_comparison", "bq3_cohort_groups", "bq4_segment_matrix", "bq4_group_b_profile",
                  "bq4_threshold_sensitivity", "bq4_concentration",
                  "bq4_top_account_sensitivity"]
# Power BI model tables (Parquet, local only). Never includes pbi_customer_key_map.
POWERBI_DIR = ROOT / "data" / "powerbi"
POWERBI_TABLES = ["pbi_dim_month", "pbi_dim_date", "pbi_dim_customer", "pbi_fct_invoice", "pbi_fct_customer_day",
                  "pbi_agg_value_class_month", "ref_repeat_summary", "ref_time_to_second", "ref_driver_decomposition",
                  "ref_customer_flow", "ref_top_account_sensitivity", "ref_cohort_presentation",
                  "ref_reconciliation_targets"]
FORBIDDEN_COLUMNS = {"customer_id", "invoice_no", "invoice", "stock_code", "stockcode", "description", "line_id", "source_row"}
# Salt for the surrogate customer key: local, git-ignored, created once.
SALT_FILE = ROOT / "data" / "processed" / "pbi_key_salt.txt"


def key_salt() -> str:
    if not SALT_FILE.exists():
        import secrets
        SALT_FILE.write_text(secrets.token_hex(16), encoding="utf-8")
    return SALT_FILE.read_text(encoding="utf-8").strip()


def export_powerbi(con: duckdb.DuckDBPyConnection) -> pd.DataFrame:
    """Write each Power BI table to Parquet, then read the file back to verify it."""
    POWERBI_DIR.mkdir(parents=True, exist_ok=True)
    rows = []
    for table in POWERBI_TABLES:
        path = (POWERBI_DIR / f"{table}.parquet").as_posix()
        con.execute(f"COPY (SELECT * FROM {table}) TO '{path}' (FORMAT PARQUET)")
        n_table = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        n_file = con.execute(f"SELECT COUNT(*) FROM read_parquet('{path}')").fetchone()[0]
        cols = [r[0] for r in con.execute(f"DESCRIBE SELECT * FROM read_parquet('{path}')").fetchall()]
        bad = sorted(c for c in cols if c.lower() in FORBIDDEN_COLUMNS)
        rows.append({"file": f"{table}.parquet", "rows_table": n_table, "rows_file": n_file, "columns": len(cols),
                     "identifier_columns": ", ".join(bad) or "none",
                     "passed": n_table == n_file and not bad})
    return pd.DataFrame(rows)


def readback_checks(con: duckdb.DuckDBPyConnection) -> pd.DataFrame:
    """Point a temp view at each exported Parquet file, then run the content checks on the files."""
    for table in POWERBI_TABLES:
        path = (POWERBI_DIR / f"{table}.parquet").as_posix()
        con.execute(f"CREATE OR REPLACE TEMP VIEW pq_{table} AS SELECT * FROM read_parquet('{path}')")
    con.execute((ROOT / "sql" / "22_powerbi_readback_checks.sql").read_text(encoding="utf-8"))
    print("ran sql/22_powerbi_readback_checks.sql (on the Parquet files)")
    return con.execute("SELECT * FROM pbi_readback_checks ORDER BY check_no").df()


def load_raw(con: duckdb.DuckDBPyConnection) -> None:
    """Copy each worksheet into DuckDB as-is, adding only the Excel row number for traceability."""
    sheets = pd.read_excel(RAW_XLSX, sheet_name=None, dtype={"Invoice": str, "StockCode": str})
    for sheet, table in RAW_TABLES.items():
        df = sheets[sheet]
        df.insert(0, "source_row", df.index + 2)  # Excel row (row 1 is the header)
        con.register("df_raw", df)
        con.execute(f"CREATE OR REPLACE TABLE {table} AS SELECT * FROM df_raw")
        con.unregister("df_raw")
        print(f"loaded {table}: {len(df):,} rows")


def main() -> int:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(DB_PATH))
    existing = {r[0] for r in con.execute("SELECT table_name FROM information_schema.tables").fetchall()}
    if "--reload" in sys.argv or not set(RAW_TABLES.values()) <= existing:
        load_raw(con)

    con.execute("SET VARIABLE pbi_salt = ?", [key_salt()])
    for name in SQL_FILES:
        con.execute((ROOT / "sql" / name).read_text(encoding="utf-8"))
        print(f"ran sql/{name}")

    results = con.execute("SELECT * FROM validation_results ORDER BY check_no").df()
    stage3 = con.execute("SELECT * FROM stage3_checks ORDER BY check_no").df()
    pbi = con.execute("SELECT * FROM pbi_checks ORDER BY check_no").df()
    manifest = export_powerbi(con)
    readback = readback_checks(con)
    with pd.option_context("display.width", 200, "display.max_colwidth", 60, "display.max_rows", 100):
        print(results.to_string(index=False))
        print(stage3.to_string(index=False))
        print(pbi.to_string(index=False))
        print(manifest.to_string(index=False))
        print(readback.to_string(index=False))

    out = ROOT / "outputs"
    out.mkdir(exist_ok=True)
    for view in EXPORTS:
        con.execute(f"COPY (SELECT * FROM {view}) TO '{(out / f'{view}.csv').as_posix()}' (HEADER)")
    (out / "stage3").mkdir(exist_ok=True)
    for view in STAGE3_EXPORTS:
        con.execute(f"COPY (SELECT * FROM {view}) TO '{(out / 'stage3' / f'{view}.csv').as_posix()}' (HEADER)")
    (out / "stage4").mkdir(exist_ok=True)
    for view in ["pbi_checks", "pbi_readback_checks", "ref_reconciliation_targets"]:
        con.execute(f"COPY (SELECT * FROM {view}) TO '{(out / 'stage4' / f'{view}.csv').as_posix()}' (HEADER)")
    manifest.to_csv(out / "stage4" / "powerbi_export_manifest.csv", index=False)
    print(f"exported {len(EXPORTS)} tables to outputs/, {len(STAGE3_EXPORTS)} to outputs/stage3/, "
          f"4 to outputs/stage4/ and {len(manifest)} Parquet files to data/powerbi/")

    failed = int((~results["passed"]).sum())
    failed3 = int((~stage3["passed"]).sum())
    print(f"Stage 2 validation: {len(results) - failed} passed, {failed} failed")
    print(f"Stage 3 checks: {len(stage3) - failed3} passed, {failed3} failed")
    failed4 = int((~pbi["passed"]).sum()) + int((~manifest["passed"]).sum())
    failed4r = int((~readback["passed"]).sum())
    print(f"Stage 4 export checks (original): {len(pbi) + len(manifest) - failed4} passed, {failed4} failed")
    print(f"Stage 4 Parquet read-back checks (new): {len(readback) - failed4r} passed, {failed4r} failed")
    return 1 if failed or failed3 or failed4 or failed4r else 0


if __name__ == "__main__":
    sys.exit(main())
