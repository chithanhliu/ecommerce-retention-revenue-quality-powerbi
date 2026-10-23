# Data source

The raw dataset is **not** stored in this repository. The dashboard PBIX already contains the imported, derived tables it needs. Download the raw data only if you want to rebuild the pipeline.

| Item | Value |
|---|---|
| Dataset | Online Retail II, UCI Machine Learning Repository, dataset #502 |
| Creator | Daqing Chen |
| DOI | https://doi.org/10.24432/C5CG6D |
| Landing page | https://archive.ics.uci.edu/dataset/502/online+retail+ii |
| Download | https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip |
| Licence | Creative Commons Attribution 4.0 International (CC BY 4.0) |

**Citation**

Chen, D. (2012). *Online Retail II* [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5CG6D

**Files used by the pipeline.** These checksums are from the copy retrieved on 19 Oct 2026.

| File | Size (bytes) | SHA-256 |
|---|---:|---|
| `online_retail_ii.zip` | 45,622,418 | `572e36277c2390fbfde10664750731e0a86f55e33470d91919085f0408e67bfb` |
| `online_retail_II.xlsx` (extracted) | 45,622,278 | `bcbe73b35f5b7babf197fb0cb983a11f5d9ff929078d4aa53d171b1f2df2e980` |

To rebuild, place the extracted workbook at `data/raw/extracted/online_retail_II.xlsx` and run `scripts/run_pipeline.py`. Generated files go to `data/processed/`, `data/powerbi/` and `outputs/`. All of them are git-ignored.
