# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a deep learning framework for detecting and scoring biological structures (perineuronal nets and parvalbumin cells) in fluorescence microscopy images. Originally from [ciampluca/counting_perineuronal_nets](https://github.com/ciampluca/counting_perineuronal_nets), adapted for the Caras Lab.

Two-stage pipeline:

- **Stage 1 (Detection)**: FasterRCNN detects cell centres via patch-based inference on 640×640 tiles with NMS stitching
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

- **`CellDatasetManifest.m`** — Authoritative per-dataset record and the single source of truth for file resolution (schema `celldataset/2.0`, sidecar `<base>.celldataset.json`). One instance == one dataset (a source TIFF + everything derived from it). Records the analyzed image/pages and, per `(channel,page)` **source**, the **active analysis CSV** (`activeLocs`), its resized companion, QC file, and stage provenance. All Cell* tools resolve files through it (`forImage`/`forCsv`/`activeLocs`/`imageForLocs`/`qcPath`/`channelPage`) and record through it (`recordDetection`/`recordResized`/`recordResolve`/`recordRescore`/`recordQc`/`setActiveLocs`); naming conventions (via `CellToolkit`) only bootstrap a missing manifest. `discover(parentDir)` returns all datasets below a folder. Clean break: non-`2.0` manifests are rebuilt from files (no migration)
- **`CellDatasetManager.m`** — Dataset discovery + status dashboard. `scan(parentDir)` / `statusTable(parentDir)` are headless APIs returning each dataset with per-source pipeline status (detected/resolved/rescored/QC'd); `scan` now delegates discovery to `CellDatasetManifest.discover` and projects each manifest onto the dashboard's dataset struct (with the live manifest attached as `.ManifestObj`). The GUI lists all datasets, launches the other Cell* GUIs pre-pointed at a selected dataset, and via the **Set active locs…** button re-points a source's active analysis file (`CellDatasetManifest.setActiveLocs`)
- **`CellToolkit.m`** — Stateless shared helpers (Python/conda exec, filesystem scan, TIFF/locs naming conventions, settings persistence, UI helpers) used by all Cell* GUIs
- **`CellDiscovery.m`** — Batch processing GUI with recursive directory search, per-page model mapping for multi-page TIFFs, optional preprocessing (morphological background subtraction, LSM artifact correction), optional `snapToCellCentroid` post-processing (per-page enable + per-page parameter dialog; adds non-destructive `SNAP_X/Y/Shift/Snapped` columns and can overwrite `X/Y`), and real-time subprocess streaming
- **`CellNeighborResolution.m`** — GUI to review/resolve duplicate nearby detections; edits `*_locs.csv` in place (adds `CURATED_X/Y`) and can run Stage-2 rescoring (`score.py`)
- **`CellQualityControl.m`** — Interactive QC GUI for marking detections as Good/Bad
- **`BinaryCellCropDataset.m`** — Builds training dataset from QC classifications
- **`correctBidirectionalLSMArtifact.m`** — Preprocesses bidirectional LSM scanner artifacts
- **`snapToCellCentroid.m`** — Pulls detected `X/Y` locations to the refined cell centre (localization refinement). Takes an image + `[X Y]` (or a *_locs table) and snaps each point, with cell-type presets (`round` for PV somata, `oval` for ring-like PNNs) and a `Method` that defaults to `auto` (resolved from the preset). Methods: `weighted-centroid` (intensity-weighted centroid of the segmented local blob — best for solid somata), `radial-symmetry` (a localized Fast Radial Symmetry Transform that votes each bright ring-wall pixel's gradient back to the **centre of the ring**, recovering the dark hole of an open/reticular PNN where a centroid would sit on the bright arc — the default for `oval`), and `mean-shift` (threshold-free climb to the brightest mode; note it lands on the wall, not the hole). Shared: targeted preprocessing (median/top-hat/Gaussian background, smoothing), bounded search radius, and a `MaxShift` cap so isolated points are never dragged onto a neighbour. Non-destructive on tables (adds `SNAP_X/Y/Shift/Snapped`)

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
```

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

## Key Implementation Notes

**Windows**: `num_workers=0` in all DataLoaders (multiprocessing corrupts shared memory on Windows).

**Checkpoint loading**: Detection threshold is stored inside `best.pth` and loaded automatically when `--threshold` is not specified.

**Pretrained models**: WFA staining → `pnn_v2_fasterrcnn_640` (C1 files). PV staining → `pv_v2_fasterrcnn_640` (C2 files). Scoring models follow the same `pnn_v2_*` / `pv_v2_*` naming convention.

**Pixel size**: The original training data used 0.645 µm/pixel. If images have very different resolution, background subtraction and/or resizing may be needed before detection.
