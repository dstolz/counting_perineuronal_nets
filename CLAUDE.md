# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a deep learning framework for detecting and scoring biological structures (perineuronal nets and parvalbumin cells) in fluorescence microscopy images. Originally from [ciampluca/counting_perineuronal_nets](https://github.com/ciampluca/counting_perineuronal_nets), adapted for the Caras Lab.

Two-stage pipeline:

- **Stage 1 (Detection)**: FasterRCNN detects cell centers via patch-based inference on overlapping 640×640 tiles (`--overlap`, default 120 px from the model config); each tile contributes only the detections centered in the region it owns (`_owned_by_tile` in `methods/detection/train_fn.py`), which removes the clipped/duplicated boxes of cells cut by tile edges
- **Stage 2 (Rescoring)**: ConvNet rescores detections using 64×64 crops to estimate inter-rater agreement quality [0–1]

## Architecture

### Core Inference

`detector.py` — `CellDetector` class is the primary API. Loads detection + optional scoring model once; `predict(image_path)` returns a DataFrame with columns: `X`, `Y`, `class`, `score`, `imgName`, `thr`, `rescore`.

`predict.py` — CLI wrapper around `CellDetector`.

`count_all_images_dataset.py` — Batch processing script for a full dataset folder. Skips images whose output CSV already exists (safe to re-run after interruption). Edit constants at top of `main()` to configure.

### Training

`train.py` — Stage 1 training via [Hydra](https://hydra.cc/) config composition. Experiment configs in `conf/experiment/`. Outputs to `runs/experiment=<name>/`.

`train_score.py` — Stage 2 scoring model training. Configs in `conf_score/method/`. Outputs to `runs_score/method=<name>,seed=<seed>/`.

Each trained run folder contains:

```text
<model_folder>/
├── .hydra/config.yaml    # training config (read automatically at inference)
└── best.pth              # model weights (also stores the detection threshold)
```

### Method Abstraction

`methods/{detection,density,segmentation,rank}/` — Each method implements:

- `train_fn.py` — `train_one_epoch()`, `validate()`, `predict_points()`/`predict()`
- `target_builder.py`, `metrics.py`, `transforms.py`, `utils.py`

Methods are loaded dynamically via Hydra: `hydra.utils.get_method(f'methods.{cfg.method}.train_fn.<fn>')`.

### Datasets

`datasets/patched_datasets.py`:

- `PatchedMultiImageDataset` — fixed patches with overlap for training/validation
- `RandomAccessMultiImageDataset` — 64×64 crops around detected centers for rescoring

`datasets/PerineuronalNetsDataset.py` — Multi-image dataset concatenating single-file patch datasets.

### MATLAB Customizations (`customizations/`)

- **`CellCurator.m`** — The app for reviewing and correcting detections; it replaced the legacy `CellNeighborResolution.m` and `CellQualityControl.m`, which are deleted (last version in commit `1874dc1`; their old files are still imported by `curation.LegacyImport`). Review by exception: pages of crop tiles with one proposed label each (the assist model orders them and proposes; it never decides), the user marks the exceptions and Enter confirms the rest; blind audit tiles measure the reviewer and the model; a map for adding, moving, merging, lassoing and excluding regions; close pairs; an optional missed-cell sweep; a finish checklist that writes `<stem>_final.csv`; the Training tab (exports, scorer fine-tune, detector command). Launched from the Dataset Manager's **Curate…** button or `CellCurator(parentDir)`. Test seams (`handleKey`, `galleryClick`, `confirmPage`, ...) are listed in its class help. User guide: `customizations/docs/CellCurator.md`
- **`+curation/`** — Everything behind `CellCurator` that is not window code. Key classes: `Store` (the curation store of one source: files, schema, journal, undo/redo, reconcile against a re-detection, locking; its header comment is the contract), `Queues`/`Proposals` (review pages and P(Good)), `CropCache`/`GalleryView`/`MapView` (rendering), `MapMarkers`/`MarkerDialog` (the map's markers per cell state, chosen in *Markers…* and kept in the settings), `AssistRunner`/`AssistModel`/`ProjectIndex`/`Features` (assist model), `BlindTiles`/`Audit` (audit tiles and the report), `Export`/`Trainer`/`Rescore`/`RescoreRunner`/`TrainingPanel` (retraining loop), `LegacyImport` (one-time import of old QC and Resolver results), and `UiText` (every word the window shows). Maintainer's reference: `customizations/docs/CellCuration-Reference.md`
- **`CellAnalysis.m`** — Post-processing analysis window: measures every cell and plots distributions within a section and across sections. Launched from the Dataset Manager's **Analyze…** button or `CellAnalysis(parentDir)`. Left: one row per section of the chosen cell type (Use, Subject, Section, Group, Cells, Measured, Surface). *Distributions* tab: Histogram, Cumulative, Box by group, Metric by depth, Cell density by depth, Colocalization (share of each channel paired with the other, against a chance level), Scatter of any metric (one point per cell, section or subject), grouped by file-name tags (section, subject, hemisphere, stain), by the lab database's cached subject facts (sex, species, project, and every tag namespace, bare tag and variable of the subjects: `Tag_<namespace>`, `HasTag_<tag>`, `Var_<name>` columns from `celldb.subjectFactors` through `cellanalysis.Project.readDatabase`), by the user's groups (`cellanalysis_groups.csv`, typed or imported) or by colocalization; one observation per cell, section or subject. A number variable of the lab database is also offered as the Metric and as the scatter's horizontal axis. **Check subjects** renews the cache; **Use by tags** ticks sections by a tag filter. *Section* tab: the section with its brain surface (automatic, corrected by switching empty areas on/off, or traced) and its cells colored by the metric. Exports: cells, one row per section, the figure. **Reject near surface (um)** (`setMinDepthUm`; `Project.load` option `MinDepthUm`) leaves out every cell closer than that to the brain surface, in both channels, and the tissue there from the areas and densities; sections without a surface keep their cells, and the curation is not changed. Test seams (`scanFolder`, `setKind`, `measure`, `setPlot`, `setMetric`, `setGroupBy`, `checkSubjects`, `useByTags`, `setSurfaceLine`, `toggleSurfaceArea`, `exportCells`, ...) are listed in its class help. User guide: `customizations/docs/CellAnalysis.md`
- **`+cellanalysis/`** — Everything behind `CellAnalysis` that is not window code, all static: `Surface` (tissue mask, which empty areas are the outside of the brain, distance map, tissue area per depth; on maps of about 3 um pixels), `Measure` (per-cell luminance and morphology from a bicubic resampling of the page around each cell; `catalog()` is the list of metrics the window shows; net-specific ring measures for kind `pnn`; `colocalize` pairs the two channels one to one within a distance and gives the chance level from displaced copies of the other channel), `Project` (sources below a folder, which cells are measured, the cache and its staleness, groupings; **its header comment is the contract of the files**), `Stats` (observations per cell/section/subject, summary, histogram, cdf, depth profiles, colocalization per section and group) and `Plots`. Neighborhood and colocalization (`NnUm`, `LocalDensity`, `OtherDistUm`, `Colocalized`, `ColocChance`, `PartnerID`) are computed by `Project.load` among the chosen population, not stored. Cells come from `curation.Store` opened read-only (active, not excluded; `Kept` as the store says), so curated positions are measured and the curation files are never written. Files: `<stem>_metrics.csv` beside the locs (one row per cell, keyed by `CellID`), `<base>.cellanalysis.json` in the dataset folder (surface definition shared by the dataset's sources, per-source record with the stamps of image/locs/curation it was made from, tissue area per depth), `cellanalysis_groups.csv` in the scanned folder. A source is "stale" when any stamp, the surface definition or a code version (`Project.VERSION`, `Measure.VERSION`, `Surface.VERSION`: bump the one whose results change) differs; a re-measure keeps the rows whose `CellID` and position did not change
- **`+celldb/`** — The only code that touches the CarasLabDB client (`labclient`): provenance record of a completed source (`recordCuration`, `Run`), the status-bar lamp, `available`/`capturing`/`backfill`, and the read side the Dataset Manager shows: `sourceRecords` (where each completed source's record is: none, kept here, waiting, sent, held, refused; and whether the files changed since), `subjectInfo`/`refreshSubjects` (which subjects the database has; only `refreshSubjects` asks the server, on a person's click), the subjects' **tags and variables** from the same cache (`subjectTags`, `subjectVariables`, `subjectFactors`: one column per tag namespace, bare tag and variable; `tagFilter`: the lab database's filter grammar, where a subject never checked or not in the database never passes; needs labclient interface 4, an older client only shows none) and `listen` (outbox and state changes). The GUIs only read tags and variables: Dataset Manager (Tags column, Tags filter, report), Cell Discovery (Subject tags filter of the file list), Cell Analysis (grouping and plotting), Cell Curator (the Subject... button, on request only, so review stays blind to the group). Offline-first: nothing the app writes depends on the database
- **`CellDatasetManifest.m`** — Authoritative per-dataset record and the single source of truth for file resolution (schema `celldataset/2.0`, sidecar `<base>.celldataset.json`). One instance == one dataset (a source TIFF + everything derived from it). Records the analyzed image/pages and, per `(channel,page)` **source**, the **active analysis CSV** (`activeLocs`), its resized companion, QC file, and stage provenance. All Cell* tools resolve files through it (`forImage`/`forCsv`/`activeLocs`/`imageForLocs`/`qcPath`/`channelPage`) and record through it (`recordDetection`/`recordResized`/`recordRescore`/`recordCuration`/`setActiveLocs`; stage `curation`, `curationPath`, `curationJsonPath`; `recordResolve`/`recordQc` have had no caller since the legacy tools were deleted, and the `resolve`/`qc` stages are derived from old files); naming conventions (via `CellToolkit`) only bootstrap a missing manifest. `discover(parentDir)` returns all datasets below a folder. Clean break: non-`2.0` manifests are rebuilt from files (no migration) **The base of a dataset** is the stem its locs files start with (`forCsv` is the authority; `forImage` and `discover` follow the same three rules, see the class help): the lab's layout `<x>_proj.tif` + `<x>_proj_ECM1_locs.csv` is ONE dataset `<x>_proj`. CellDiscovery records a detection in the manifest of the locs file it wrote; `adoptStrayFacts` takes over what an earlier version recorded in `<x>.celldataset.json`. An unchanged manifest is not rewritten by a scan
- **`CellDatasetManager.m`** — Dataset discovery + status window. Headless API: `scan(parentDir)` (one struct per dataset with per-source status, the section and subject its file name names, and the state of each source's lab database record; delegates discovery to `CellDatasetManifest.discover`, live manifest attached as `.ManifestObj`), `statusTable`, `sourceTable` (one row per source: the report the window exports) and `progressOf` (counts and the stage `detect`/`curate`/`curating`/`curated`). The window lists every dataset (Subject, Section, Name, Sources, Detections, Rescored, Reviewed %, Curated, Kept, Status, Database, Tags), narrows the list with **Find**, **Tags** (a lab database tag filter, `setTagFilter`) and **Show**, selects the **Next to curate**, opens the selected dataset on Enter or a double-click (**Curate…** opens CellCurator, **Detect cells…** CellDiscovery), exports the report, previews the TIFF (deferred and cached; the "By class" overlay reads the curation store first, then a legacy `*_QC.csv`), re-points a source's active analysis file (**Set active locs…**, `CellDatasetManifest.setActiveLocs`), and holds the lab database lamp with **Check subjects**, **Queue records** and **Database…** (all through `celldb`). A scan shows its progress window only when it takes longer than 0.7 s. Test seams (`scanFolder`, `setFilter`, `selectDataset`, `nextToCurate`, `openSelected`, `exportReport`, `LaunchFcn`, ...) are listed in its class help. User guide: `customizations/docs/CellDatasetManager.md`
- **`CellToolkit.m`** — Stateless shared helpers (Python/conda exec, filesystem scan, TIFF/locs naming conventions, settings persistence, UI helpers, and the model-input pipeline `modelInputPage`/`modelInputFromFile`/`modelInputFactsFor` that CellDiscovery, the exports and rescoring all use) used by all Cell* GUIs
- **`CellDiscovery.m`** — Batch processing GUI with recursive directory search, per-page model mapping for multi-page TIFFs, optional preprocessing (morphological background subtraction, LSM artifact correction), resize to the training pixel size (`Resize x` = 0 computes the factor per file from the TIFF calibration via `CellToolkit.tiffPixelSizeUm`), per-page intensity normalization of the detector/scorer input (`Normalize` column, `CellToolkit.normalizeIntensity`; the saved `_resized.tif` and snap input stay un-normalized), optional `snapToCellCentroid` post-processing (per-page enable + per-page parameter dialog; adds non-destructive `SNAP_X/Y/Shift/Snapped` columns and can overwrite `X/Y`), and real-time subprocess streaming
- **`correctBidirectionalLSMArtifact.m`** — Preprocesses bidirectional LSM scanner artifacts
- **`snapToCellCentroid.m`** — Pulls detected `X/Y` locations to the refined cell center (localization refinement). Takes an image + `[X Y]` (or a *_locs table) and snaps each point, with cell-type presets (`round` for PV somata, `oval` for ring-like PNNs) and a `Method` that defaults to `auto` (resolved from the preset). Methods: `weighted-centroid` (intensity-weighted centroid of the segmented local blob — best for solid somata), `radial-symmetry` (a localized Fast Radial Symmetry Transform that votes each bright ring-wall pixel's gradient back to the **center of the ring**, recovering the dark hole of an open/reticular PNN where a centroid would sit on the bright arc — the default for `oval`), and `mean-shift` (threshold-free climb to the brightest mode; note it lands on the wall, not the hole). Shared: targeted preprocessing (median/top-hat/Gaussian background, smoothing), bounded search radius, and a `MaxShift` cap so isolated points are never dragged onto a neighbor. Non-destructive on tables (adds `SNAP_X/Y/Shift/Snapped`)

### Curation data

The detector's `*_locs.csv` is **read-only input**: CellCurator never modifies it (the deleted legacy Neighbor Resolver did, so old files may carry `CURATED_X/Y`). Every human decision lives in per-source sidecar files keyed by a stable `CellID`, so decisions survive a re-detection: `<stem>_curation.csv` (snapshot), `<stem>_curation.journal.csv` (append-only log, replayed after a crash) and the dataset-level `<base>.curation.json` (exclusion regions, per-source counts). `<stem>_final.csv` holds the kept cells of a completed source. **The header comment of `customizations/+curation/Store.m` is the contract** (files, schema, kept rule, reconcile, locking); read it before touching these files, and do not write them from anywhere but `curation.Store`. A kept cell is active, labeled Good by a person, reviewed, and not inside an exclusion region. The app never rejects a detection without a person seeing it.

## Commands

### Setup

```bash
conda create -n countpnn python=3.10
conda activate countpnn
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
pip install -r requirements.txt
```

> Python 3.10+ and PyTorch 2.6+ are required. The original README lists Python 3.8/PyTorch 1.11 but those are EOL and incompatible with modern GPUs.

### Running Inference

```bash
# Single image, detection only
python predict.py pnn_v2_fasterrcnn_640 image.tif

# With rescoring, GPU, low threshold for high recall
python predict.py pnn_v2_fasterrcnn_640 image.tif -d cuda:0 -r pnn_v2_scoring_rank_learning -t 0.0 -o results.csv

# Batch processing (edit constants in main() first)
python count_all_images_dataset.py
```

### Training Models

```bash
# Stage 1 — detection model
python train.py experiment=perineuronal-nets/detection/fasterrcnn_640

# Stage 1 — custom seed/GPU
python train.py experiment=perineuronal-nets/detection/fasterrcnn_640 seed=42 gpu=1

# Stage 2 — scoring model
python train_score.py method=pairwise_balanced seed=67

# Resume interrupted training
python train.py experiment=perineuronal-nets/detection/fasterrcnn_640 optim.resume=true

# Stage 2 — fine-tune the shipped scorer on a curated export (curation.Export.stage2; the CellCurator
# Training tab builds and runs exactly this through curation.Trainer; paths with forward slashes)
python train_score.py data=curated method=ordinal_regression data.train.root=<export>/train data.validation.root=<export>/validation data.train.neg_fraction=0 data.validation.neg_fraction=0 model.pretrained=<repo>/<kind>_v2_scoring_ordinal_regression/best.pth optim.epochs=10 optim.optimizer.lr=0.0001 optim.batch_size=32 optim.num_workers=0 seed=10 gpu=0 hydra.run.dir=<repo>/runs_score/curated_<kind>_<yyyyMMdd_HHmmss>

# Stage 1 — fine-tune the detector on a curated export (curation.Export.stage1; only sources marked
# complete AND swept for missed cells; hours to days, so the Training tab only copies the command)
python train.py experiment=curated/fasterrcnn_640 data.train.root=<export> data.validation.root=<export> model.pretrained=<repo>/<kind>_v2_fasterrcnn_640/best.pth optim.epochs=20 gpu=0 hydra.run.dir=<repo>/runs/curated_<kind>_<yyyyMMdd_HHmmss>
```

`<kind>` is `pnn` or `pv`. `model.pretrained=<path to a best.pth>` starts either trainer from existing weights (it crashed before; fixed in `train.py` and `train_score.py`). A fine-tuned scorer changes the meaning of `rescore`; `curation.Trainer` deploys it as `<kind>_curated_<date>_scoring_ordinal_regression/`.

### Evaluation and Rescoring Commands

```bash
# Evaluate localization model
python evaluate.py runs/experiment=perineuronal-nets/detection/fasterrcnn_640/ --device cuda

# Evaluate scoring model
python evaluate_score.py runs_score/method=pairwise_balanced,seed=67/ --device cuda

# Rescore existing detections without re-running detection
python score.py pnn_v2_scoring_rank_learning localizations.csv --root /path/to/images --device cuda:0 --output rescored.csv

# Reproduce all paper experiments
bash reproduce.sh
```

## Tests

Run MATLAB tests **only** with the runner, which puts them on a hidden Windows desktop so windows never take the focus (never start `matlab` for a test run any other way, and never run two at once):

```powershell
pwsh -File tools\Run-Tests.ps1                          # default set, hidden desktop
pwsh -File tools\Run-Tests.ps1 tStoreSmoke 'tCurator*'  # by class or wildcard; 'Class/method' for one test
pwsh -File tools\Run-Tests.ps1 -IncludeSlow             # also tests tagged Slow, Python, Benchmark
pwsh -File tools\Run-Tests.ps1 -WithoutClient           # no CarasLabDB client (CELLDB_NO_CLIENT=1)
pwsh -File tools\Run-Tests.ps1 tFixture -Visible        # on your own desktop, to watch (-Interactive: answer dialogs)
```

Tags: `Slow`, `Python` (needs the `countpnn` env), `Benchmark` (speed budgets), `RealData` (needs the local copy of real sections in `%LOCALAPPDATA%\counting_perineuronal_nets\real_sections`; skipped without it). Exit codes: 0 passed, 1 failed, 2 runner error, 3 a dialog waits for a person (an `ACTION NEEDED` block says which), 124 timeout. Tests are in `tests/t*.m` (synthetic dataset: `tests/fixtures/makeSyntheticDataset.m`; `addEmptyMargin` blanks the left of its picture so there is a brain surface to find); the full suite (`-IncludeSlow`) is about 700 tests and 26 minutes. Lab database tags and variables: `tCelldbFacts` (its `seed` gives the fake server the tags and variables the GUI tests use), `tAnalysisDatabase`, and tests in `tManagerDatabase`, `tDiscoveryGui`, `tCuratorDatabase`. Cell Analysis: `tAnalysisSurface`, `tAnalysisMeasure`, `tAnalysisStats` (pure, on synthetic pictures of known geometry), `tAnalysisProject`, `tAnalysisGui`, and `tAnalysisReal` (`Slow`, `RealData`; writes screenshots when `CELLANALYSIS_SCREENS_OUT` names a folder). See `customizations/docs/CellCuration-Reference.md` for the budgets and the test setup.

## Key Implementation Notes

**Windows**: `num_workers=0` in all DataLoaders (multiprocessing corrupts shared memory on Windows).

**Checkpoint loading**: Detection threshold is stored inside `best.pth` and loaded automatically when `--threshold` is not specified.

**Pretrained models**: WFA staining → `pnn_v2_fasterrcnn_640` (C1 files). PV staining → `pv_v2_fasterrcnn_640` (C2 files). Scoring models follow the same `pnn_v2_*` / `pv_v2_*` naming convention.

**Pixel size**: The original training data used 0.645 µm/pixel. If images have very different resolution, background subtraction and/or resizing may be needed before detection.

**Intensity scale**: `PatchedImageDataset` divides pixel values by 255, i.e. the detectors expect 8-bit-scaled input, and detection counts track image brightness when the input is on another scale. The scoring ConvNet is insensitive to input scale (per-channel GroupNorm after the first conv).
