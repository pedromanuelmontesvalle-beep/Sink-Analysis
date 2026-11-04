# Flood Sink Analysis Pipeline (Japan)

A pipeline that finds **terrain sinks** (closed depressions where surface water would collect) across Japan from GSI elevation data. It attaches sink depth, population and administrative information to every road and building, and publishes the results as a STAC catalog backed by pgstac.

It has been run for **all 47 prefectures**. A case study in **Chiba** checks the sink layer against a flood mask derived from Sentinel-1 SAR for the August 2026 flood event around Oamishirasato.

---

## Repository contents

| File | Purpose |
|---|---|
| `FINAL_SINK_PIPELINE.ipynb` | Main pipeline, run once per prefecture: DEM → sinks → roads/buildings enrichment → GeoParquet → STAC → pgstac |
| `Chiba_flooding_mask.ipynb` | Builds a flood mask from Sentinel-1 before/after scenes (VV + VH change detection) for Oamishirasato, Chiba |
| `flooding_sinks_comparison.ipynb` | Validates the Chiba sink layer against the observed flood mask (confusion matrix, depth threshold sweep, missed-flood analysis) |
| `build_flood_catalog.py` | Builds the root "Flood Analysis" STAC catalog that links every prefecture's catalog, and prepares the served directory (imported by the pipeline) |
| `start_services.ps1` | Starts the local serving stack (PostgreSQL/pgstac, stac-fastapi, http-server, pg_featureserv, STAC Browser) |

Run order for the Chiba validation:

```
FINAL_SINK_PIPELINE (chiba)  ──► sink COGs ─────────────────────┐
                                                                ├──► flooding_sinks_comparison
Chiba_flooding_mask  ──► floods_chiba_final_mask.tif ───────────┘
```

---

## 1. Sink pipeline — `FINAL_SINK_PIPELINE.ipynb`

### Inputs

| Input | Source | Notes |
|---|---|---|
| 1 m DEM tiles (`FG-GML-<mesh>-DEM1A-<date>.tif`) | GSI 基盤地図情報 数値標高モデル | Primary elevation source |
| 5 m DEM tiles (`DEM5A` / `DEM5B`) | GSI 基盤地図情報 数値標高モデル | Fallback where 1 m coverage is partial or missing |
| Administrative boundaries (`N03-20260101_GML.zip`) | 国土数値情報 行政区域 (N03) | Filtered to the prefecture; `N03_004` gives the city name |
| Roads (`segment`) and buildings | [Overture Maps](https://overturemaps.org/), fetched live by bounding box | Clipped to the prefecture polygons |
| Population mesh (optional) | `<prefecture>_population_mesh.parquet` with `PTN_2020`, `PTN_2025`, `PTC_2025` | If missing, the population columns are written as NaN |

### Configuration

Set these in the second cell:

```python
Prefecture = "千葉県"          # Japanese name, matched against N03_001
English_Prefecture = "chiba"   # used in all folder/file names
tif_dir = ...                  # folder with the 1 m DEM tifs
tif_dir_5m = ...               # folder with the 5 m DEM tifs
data_dir = ...                 # inputs + intermediates (checkpoints, cleaned DEMs)
final_dir = ...                # final deliverables for this prefecture
MIN_SINK_CELLS = 0             # drop sink regions smaller than N cells (0 = off)
MIN_FLAT_WATER_CELLS = 0       # mask large constant-elevation flats (lakes) before processing (0 = off)
```

### Processing steps

1. **Tile inventory.** All 1 m and 5 m DEM files are indexed by mesh code, and only tiles that intersect the prefecture boundary are kept.
2. **Building a DEM for each tile** (`build_tile_dem`):
   - full 1 m coverage → the original 1 m tile is used unchanged (`"1m"`)
   - partial 1 m coverage → the gaps are filled with 5 m data upsampled to the 1 m grid (`"1m+5m"`)
   - no 1 m tile → 5 m data upsampled to 1 m (`"5m"`)

   Upsampling is **bilinear** rather than cubic, because cubic overshoots at steep edges and creates false sinks.
3. **Conditioning the terrain** with [whitebox_workflows](https://www.whiteboxgeo.com/):
   - optional lake masking (large flats make `depth_in_sink` hang)
   - `feature_preserving_smoothing` (filter 11, normal diff 8°, 3 iterations)
   - `fill_pits`
   - `depth_in_sink` → sink depth in metres
   - written as a deflate-compressed **COG** in EPSG:6668 (JGD2011). The GSI tiles carry no CRS, so it is added at this step.
4. **Enriching roads and buildings** for each tile:
   - **Tile ownership:** a feature that crosses tiles belongs only to the tile that holds most of its length or area, so there are no duplicates.
   - **City:** for roads, the city covering the largest share of the road's length; for buildings, the city polygon that contains the centroid. The centroid test is about 7× faster and agrees with the area-dominant result more than 99.9% of the time.
   - **Population:** a length-weighted average for roads and an area-weighted average for buildings.
   - **Sink depth:** `sink_mean` / `sink_max`, sampled at every vertex of the feature.
5. **Checkpointing.** Each finished tile is saved to `<pref>_checkpoints/`, and re-running the cell resumes where it stopped. `tile_dem_source.json` records which DEM source each tile used.
6. **Writing outputs.** GeoParquet 1.1 files, Hilbert-sorted, zstd-compressed and with a bbox covering column so DuckDB can skip row groups, written via `geoparquet_io`.

### Outputs (`final_dir`)

```
<pref>/
├── <pref>_sinks/<mesh>_sink.tif            # sink depth COG per mesh tile
├── <pref>_roads_all.parquet
├── <pref>_buildings_all.parquet
├── <pref>_roads_by_city/<city>_roads.parquet
├── <pref>_buildings_by_city/<city>_buildings.parquet
└── <pref>_stac/                            # self-contained STAC catalog + items.parquet
```

Road and building attributes:

| Column | Description |
|---|---|
| `id`, `subtype`, `class`, `name` | From Overture |
| `height`, `num_floors` | Buildings only, from Overture |
| `sink_mesh_code` | Mesh tile that owns the feature |
| `city` | Municipality (`N03_004`) |
| `population_total_2020`, `population_total_2025`, `population_65_plus_2025`, `population_65_plus_ratio_2025` | Weighted from the population mesh |
| `sink_mean`, `sink_max` | Sink depth (m) sampled along the feature |

### STAC catalog and pgstac ingestion

- Each prefecture gets a catalog with three collections: **`sinks`** (one item per mesh tile), **`streets`** and **`buildings`** (one item per city). Item IDs are prefixed with the prefecture so that prefectures can share collections in pgstac.
- `build_flood_catalog.py` creates a root **"Flood Analysis"** catalog (`flood_stac/catalog.json`) that links every prefecture's catalog. It also creates `_flood_serve/`, a folder of NTFS directory junctions, so that http-server exposes only the catalog folders while keeping relative hrefs valid.
- The final cell converts asset hrefs to `http://localhost:8000/...` URLs, writes a STAC GeoParquet (`items.parquet`), and upserts collections and items into **pgstac** using `pypgstac`.

The database password is never stored in the code. Set it as an environment variable (the notebook connects as `postgres@localhost:5432/pss_geo`):

```powershell
setx PGPASSWORD "<password>"     # then restart VS Code / Jupyter
```

To use a different user, host or database, set `PGSTAC_DSN` to a full connection string instead.

---

## 2. Serving stack — `start_services.ps1`

After a reboot, set the database password once (`setx PGPASSWORD "<password>"`, then open a new terminal) and run `.\start_services.ps1` to start:

| Service | URL | Purpose |
|---|---|---|
| PostgreSQL + PostGIS + pgstac | `localhost:5432` | Storage (runs as a Windows service) |
| http-server | http://localhost:8000/flood_stac/catalog.json | Serves the static catalog and the COG/Parquet assets |
| stac-fastapi (pgstac) | http://127.0.0.1:8080/collections | Dynamic STAC API across all prefectures |
| pg_featureserv | http://127.0.0.1:58211/ | Feature queries and map view for roads and buildings |
| STAC Browser | http://localhost:5173/ | Browsable catalog UI |

Requirements: PostgreSQL with PostGIS and pgstac installed, Node.js (`npx http-server`, `vite`), `stac-fastapi-pgstac`, and a [pg_featureserv](https://github.com/CrunchyData/pg_featureserv) binary. The paths and credentials in the script are set for the original machine and need to be edited.

---

## 3. Flood mask — `Chiba_flooding_mask.ipynb`

Change detection on two Sentinel-1 IW GRDH dual-polarization scenes:

- **Before:** `S1D_IW_GRDH_1SDV_20260801T204256_...` (2026-08-01)
- **After:** `S1D_IW_GRDH_1SDV_20260813T204257_...` (2026-08-13)

Area of interest: Oamishirasato and its surroundings (`140.25–140.66 E, 35.37–35.58 N`), on a grid of about 11 m (0.0001°) in EPSG:6668.

### Method

1. **Radiometric calibration** to σ⁰ (dB) using each scene's own `sigmaNought` calibration LUT.
2. **Georeferencing** with a GDAL **thin-plate-spline** warp on the scene's GCPs. GDAL's default global polynomial produced a systematic shift of about 5 px.
3. **Speckle filtering** with a 5×5 median filter, followed by `after − before` in dB, separately for VV and VH.
4. **Detrending:** a 301 px (~3.3 km) moving average is subtracted, isolating local change from the broad background shift.
5. **"Was land" filter:** VV before > −18 dB and VH before > −22 dB. This excludes the ocean and permanent water, which otherwise light up after detrending.
6. **Two-tier threshold:**
   - *strict* (VV only): anomaly < −4 dB **or** after < −16 dB
   - *relaxed:* −16 dB ≤ VV after < −12 dB, counted **only if VH also confirms**

   VH can only add detections, never remove them. Requiring both polarizations for everything rejected 17% of correct VV detections.
7. **Morphological clean-up:** opening and closing, then removal of blobs smaller than 50 px.

A comparison mask without detrending is also produced for reference.

### Cross-validation with an external mask

A second flood mask (`flood_mask_20260801_20260813.tif`, covering all of Chiba at about 12 m) was provided by the project supervisor, made independently from the same two dates; its exact method is not documented here. It is resampled (nearest neighbour) onto the Oamishirasato grid, and **only pixels flagged by both masks** are kept as `floods_chiba_final_mask.tif`.

### Outputs

- `oamishirasato_flood_mask.tif`: our VV+VH mask (1 = flood, 0 = nodata)
- `oamishirasato_flood_anomaly_db.tif`: detrended VV anomaly (dB)
- `oamishirasato_flood_mask_no_detrend.tif`: reference mask without detrending
- `floods_chiba_final_mask.tif`: intersection with the external mask, used for validation

### Known limitation

Double-bounce flooding, where water under vegetation or next to vertical structures *increases* backscatter, cannot be detected by any "backscatter drop" rule. A known example at 35.51882 N, 140.3124 E stays undetected in both polarizations at every threshold tested.

---

## 4. Validation — `flooding_sinks_comparison.ipynb`

This notebook compares the Chiba sink tiles with the flood mask **at native resolution, with no resampling**:

- Sink tiles (~1.1 m) are placed at exact integer pixel offsets. Each sink pixel looks up its flood-mask value through direct coordinate indexing. An earlier version that resampled the sinks to the 12 m flood grid inflated sink coverage from about 21–37% to over 90%.
- Pixels outside the prefecture, outside tile coverage, or with **no data in the source DEM** are excluded rather than counted as "no sink".
- The full-Chiba mask is cropped to the Oamishirasato extent, which reduces the comparison to the 7 overlapping tiles.

### Analysis

- **Confusion matrix** (TP / FP / FN / TN), precision, recall, IoU, base flood rate and lift, accumulated tile by tile so memory stays bounded.
- **Depth threshold sweep** (0–5 m): how precision and recall change when only sinks at least *x* m deep are counted.
- **Detected vs. missed raster**, written to disk one tile at a time (works at any scale).
- When the combined grid is under 2 billion px: a classification raster, previews, missed-flood masks, a patch-size comparison of TP vs. FN, and a zoom on the largest missed patch with a Chiba locator map.

Outputs are written to `flood_sink_comparison/`.

---

## Environment

Developed on **Windows** with Python 3 in a conda environment. Main dependencies:

```
geopandas  rasterio  gdal  shapely  pyproj  numpy  pandas  scipy  pyarrow  matplotlib
whitebox-workflows  overturemaps  geoparquet-io
pystac  pypgstac  stac-geoparquet  stac-fastapi-pgstac
```

GDAL and whitebox-workflows are easiest to install through conda-forge.

## Notes before running

- **Paths are hardcoded** (`C:\Users\...`) in the configuration cell of each notebook. Update them before running. The comparison notebook's `SINK_DIR` and `TERRAIN_DIR` must point to the Chiba sink output and the DEM tiles used to produce it.
- `build_flood_catalog.py` uses NTFS junctions (`mklink /J`), so the catalog serving step is **Windows-only**. Everything else is cross-platform.
- Large raw data (DEMs, Sentinel-1 SAFE zips, N03, outputs) is **not included** in this repository. See the input tables above for sources.
