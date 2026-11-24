# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a deep learning framework for detecting and scoring biological structures (perineuronal nets and parvalbumin cells) in fluorescence microscopy images. Originally from [ciampluca/counting_perineuronal_nets](https://github.com/ciampluca/counting_perineuronal_nets), adapted for the Caras Lab.

Two-stage pipeline:

- **Stage 1 (Detection)**: FasterRCNN detects cell centres via patch-based inference on overlapping 640×640 tiles (`--overlap`, default 120 px from the model config); each tile contributes only the detections centred in the region it owns (`_owned_by_tile` in `methods/detection/train_fn.py`), which removes the clipped/duplicated boxes of cells cut by tile edges
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
- `RandomAccessMultiImageDataset` — 64×64 crops around detected centres for rescoring

`datasets/PerineuronalNetsDataset.py` — Multi-image dataset concatenating single-file patch datasets.

### MATLAB Customizations (`customizations/`)

- **`CellCurator.m`** — The app for reviewing and correcting detections; **replaces `CellNeighborResolution.m` and `CellQualityControl.m`**. Review by exception: pages of crop tiles with one proposed label each (the assist model orders them and proposes; it never decides), the user marks the exceptions and Enter confirms the rest; blind audit tiles measure the reviewer and the model; a map for adding, moving, merging, lassoing and excluding regions; close pairs; an optional missed-cell sweep; a finish checklist that writes `<stem>_final.csv`; the Training tab (exports, scorer fine-tune, detector command). Launched from the Dataset Manager's **Curate…** button or `CellCurator(parentDir)`. Test seams (`handleKey`, `galleryClick`, `confirmPage`, ...) are listed in its class help. User guide: `customizations/docs/CellCurator.md`
- **`+curation/`** — Everything behind `CellCurator` that is not window code. Key classes: `Store` (the curation store of one source: files, schema, journal, undo/redo, reconcile against a re-detection, locking; its header comment is the contract), `Queues`/`Proposals` (review pages and P(Good)), `CropCache`/`GalleryView`/`MapView` (rendering), `MapMarkers`/`MarkerDialog` (the map's markers per cell state, chosen in *Markers…* and kept in the settings), `AssistRunner`/`AssistModel`/`ProjectIndex`/`Features` (assist model), `BlindTiles`/`Audit` (audit tiles and the report), `Export`/`Trainer`/`Rescore`/`RescoreRunner`/`TrainingPanel` (retraining loop), `LegacyImport` (one-time import of old QC and Resolver results), and `UiText` (every word the window shows). Maintainer's reference: `customizations/docs/CellCuration-Reference.md`
- **`+celldb/`** — The only code that touches the CarasLabDB client (`labclient`): provenance record of a completed source (`recordCuration`, `Run`), the status-bar lamp, and `available`/`capturing`/`backfill`. Offline-first: nothing the app writes depends on the database
- **`CellDatasetManifest.m`** — Authoritative per-dataset record and the single source of truth for file resolution (schema `celldataset/2.0`, sidecar `<base>.celldataset.json`). One instance == one dataset (a source TIFF + everything derived from it). Records the analyzed image/pages and, per `(channel,page)` **source**, the **active analysis CSV** (`activeLocs`), its resized companion, QC file, and stage provenance. All Cell* tools resolve files through it (`forImage`/`forCsv`/`activeLocs`/`imageForLocs`/`qcPath`/`channelPage`) and record through it (`recordDetection`/`recordResized`/`recordResolve`/`recordRescore`/`recordQc`/`recordCuration`/`setActiveLocs`; stage `curation`, `curationPath`, `curationJsonPath`); naming conventions (via `CellToolkit`) only bootstrap a missing manifest. `discover(parentDir)` returns all datasets below a folder. Clean break: non-`2.0` manifests are rebuilt from files (no migration)
- **`CellDatasetManager.m`** — Dataset discovery + status dashboard. `scan(parentDir)` / `statusTable(parentDir)` are headless APIs returning each dataset with per-source pipeline status (detected/resolved/rescored/QC'd); `scan` now delegates discovery to `CellDatasetManifest.discover` and projects each manifest onto the dashboard's dataset struct (with the live manifest attached as `.ManifestObj`). The GUI lists all datasets, launches the other Cell* GUIs pre-pointed at a selected dataset (**Curate…** opens CellCurator; the two old launch buttons are relabelled "Legacy: …"; the "By class" overlay reads the curation store first), and via the **Set active locs…** button re-points a source's active analysis file (`CellDatasetManifest.setActiveLocs`)
- **`CellToolkit.m`** — Stateless shared helpers (Python/conda exec, filesystem scan, TIFF/locs naming conventions, settings persistence, UI helpers, and the model-input pipeline `modelInputPage`/`modelInputFromFile`/`modelInputFactsFor` that CellDiscovery, the exports and rescoring all use) used by all Cell* GUIs
- **`CellDiscovery.m`** — Batch processing GUI with recursive directory search, per-page model mapping for multi-page TIFFs, optional preprocessing (morphological background subtraction, LSM artifact correction), resize to the training pixel size (`Resize x` = 0 computes the factor per file from the TIFF calibration via `CellToolkit.tiffPixelSizeUm`), per-page intensity normalisation of the detector/scorer input (`Normalize` column, `CellToolkit.normalizeIntensity`; the saved `_resized.tif` and snap input stay un-normalised), optional `snapToCellCentroid` post-processing (per-page enable + per-page parameter dialog; adds non-destructive `SNAP_X/Y/Shift/Snapped` columns and can overwrite `X/Y`), and real-time subprocess streaming
- **`CellNeighborResolution.m`** — **Legacy (superseded by CellCurator, not yet deleted; kept unfixed until parity).** GUI to review/resolve duplicate nearby detections; edits `*_locs.csv` in place (adds `CURATED_X/Y`) and can run Stage-2 rescoring (`score.py`)
- **`CellQualityControl.m`** — **Legacy (superseded by CellCurator, not yet deleted; kept unfixed until parity).** Interactive QC GUI for marking detections as Good/Bad
- **`correctBidirectionalLSMArtifact.m`** — Preprocesses bidirectional LSM scanner artifacts
- **`snapToCellCentroid.m`** — Pulls detected `X/Y` locations to the refined cell centre (localization refinement). Takes an image + `[X Y]` (or a *_locs table) and snaps each point, with cell-type presets (`round` for PV somata, `oval` for ring-like PNNs) and a `Method` that defaults to `auto` (resolved from the preset). Methods: `weighted-centroid` (intensity-weighted centroid of the segmented local blob — best for solid somata), `radial-symmetry` (a localized Fast Radial Symmetry Transform that votes each bright ring-wall pixel's gradient back to the **centre of the ring**, recovering the dark hole of an open/reticular PNN where a centroid would sit on the bright arc — the default for `oval`), and `mean-shift` (threshold-free climb to the brightest mode; note it lands on the wall, not the hole). Shared: targeted preprocessing (median/top-hat/Gaussian background, smoothing), bounded search radius, and a `MaxShift` cap so isolated points are never dragged onto a neighbour. Non-destructive on tables (adds `SNAP_X/Y/Shift/Snapped`)

### Curation data

The detector's `*_locs.csv` is **read-only input**: CellCurator never modifies it (the legacy Neighbor Resolver still does). Every human decision lives in per-source sidecar files keyed by a stable `CellID`, so decisions survive a re-detection: `<stem>_curation.csv` (snapshot), `<stem>_curation.journal.csv` (append-only log, replayed after a crash) and the dataset-level `<base>.curation.json` (exclusion regions, per-source counts). `<stem>_final.csv` holds the kept cells of a completed source. **The header comment of `customizations/+curation/Store.m` is the contract** (files, schema, kept rule, reconcile, locking); read it before touching these files, and do not write them from anywhere but `curation.Store`. A kept cell is active, labelled Good by a person, reviewed, and not inside an exclusion region. The app never rejects a detection without a person seeing it.

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

Tags: `Slow`, `Python` (needs the `countpnn` env), `Benchmark` (speed budgets), `RealData` (needs the local copy of real sections in `%LOCALAPPDATA%\counting_perineuronal_nets\real_sections`; skipped without it). Exit codes: 0 passed, 1 failed, 2 runner error, 3 a dialog waits for a person (an `ACTION NEEDED` block says which), 124 timeout. Tests are in `tests/t*.m` (synthetic dataset: `tests/fixtures/makeSyntheticDataset.m`); the full suite is about 515 tests and 13 minutes. See `customizations/docs/CellCuration-Reference.md` for the budgets and the test setup.

## Key Implementation Notes

**Windows**: `num_workers=0` in all DataLoaders (multiprocessing corrupts shared memory on Windows).

**Checkpoint loading**: Detection threshold is stored inside `best.pth` and loaded automatically when `--threshold` is not specified.

**Pretrained models**: WFA staining → `pnn_v2_fasterrcnn_640` (C1 files). PV staining → `pv_v2_fasterrcnn_640` (C2 files). Scoring models follow the same `pnn_v2_*` / `pv_v2_*` naming convention.

**Pixel size**: The original training data used 0.645 µm/pixel. If images have very different resolution, background subtraction and/or resizing may be needed before detection.

**Intensity scale**: `PatchedImageDataset` divides pixel values by 255, i.e. the detectors expect 8-bit-scaled input, and detection counts track image brightness when the input is on another scale. The scoring ConvNet is insensitive to input scale (per-channel GroupNorm after the first conv).
