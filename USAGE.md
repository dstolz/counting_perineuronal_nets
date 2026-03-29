# Usage Guide — Counting Perineuronal Nets

This guide covers all practical aspects of using this repository for inference, batch
processing, and training. For a high-level project overview see [README.md](README.md).

---

## Table of Contents

1. [Repository Overview](#1-repository-overview)
2. [Environment Setup](#2-environment-setup)
3. [Pretrained Models](#3-pretrained-models)
4. [Quick Start — Single Image (CLI)](#4-quick-start--single-image-cli)
5. [Python API — CellDetector class](#5-python-api--celldetector-class)
6. [Batch Processing a Dataset](#6-batch-processing-a-dataset)
7. [Output CSV Format](#7-output-csv-format)
8. [Troubleshooting](#8-troubleshooting)
9. [Training Your Own Models](#9-training-your-own-models)
10. [Evaluating Models](#10-evaluating-models)

---

## 1. Repository Overview

The pipeline has two stages:

```
┌──────────────────────────────────────────────────────────────┐
│  Stage 1 — Detection (FasterRCNN)                            │
│  Input: large TIFF/HDF5 image                                │
│  → patch into 640×640 tiles                                  │
│  → detect cell centres per tile                              │
│  → stitch results back with NMS                              │
│  Output: DataFrame with (X, Y, score, imgName, thr)          │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼  (optional)
┌──────────────────────────────────────────────────────────────┐
│  Stage 2 — Rescoring (ConvNet rank model)                    │
│  Input: detections + 64×64 crops around each centre          │
│  → predict agreement score per cell [0–1]                    │
│  Output: DataFrame with extra column (rescore)               │
└──────────────────────────────────────────────────────────────┘
```

Two staining channels are supported, each with its own pair of pretrained models:

| Staining | Channel | Detection model           | Scoring model                      |
|----------|---------|---------------------------|------------------------------------|
| WFA (PNN)| C1      | `pnn_v2_fasterrcnn_640`   | `pnn_v2_scoring_rank_learning`     |
| PV       | C2      | `pv_v2_fasterrcnn_640`    | `pv_v2_scoring_rank_learning`      |

---

## 2. Environment Setup

### Requirements

- Python 3.10 or 3.11 (recommended)
- PyTorch 2.6+ with CUDA 12.8 (recommended — see below)
- CUDA-capable GPU strongly recommended for batch processing

> **Compatibility note:** The original README lists PyTorch 1.7.1 / Python 3.8, but
> that combination no longer works on modern GPUs. Python 3.8 reached end-of-life in
> October 2024 and PyTorch dropped support for it in version 2.5. **Use Python 3.10+.**

### Fresh install

```bash
# 1. Create a new conda environment with Python 3.10
conda create -n countpnn python=3.10
conda activate countpnn

# 2. Install PyTorch with CUDA 12.8 support
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128

# 3. Install remaining dependencies
pip install -r requirements.txt

# 4. Verify GPU is available
python -c "import torch; print(torch.__version__); print(torch.cuda.is_available())"

# Note: torchsort is an optional dependency used only for the spearmanr_optimization
# training method. It requires the full CUDA Toolkit and nvcc to compile.
# For inference and training with pairwise_balanced / ordinal_regression (the default
# pretrained models), it is NOT needed — a scipy fallback is used automatically.
```

### Migrating from an older environment (Python 3.8)

The `--index-url` install will fail on Python 3.8 because PyTorch 2.6+ no longer ships
3.8 wheels. Create a fresh environment instead:

```bash
conda create -n countpnn310 python=3.10
conda activate countpnn310
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
pip install -r requirements.txt
```

### GPU architecture compatibility

| GPU generation          | Example GPUs               | Min PyTorch | Min Python | CUDA build |
|-------------------------|----------------------------|-------------|------------|------------|
| Turing (RTX 20xx)       | RTX 2060, 2080 Ti          | 2.6+        | 3.9+       | cu128      |
| Ampere (RTX 30xx)       | RTX 3060, 3090             | 2.6+        | 3.9+       | cu128      |
| Ada Lovelace (RTX 40xx) | RTX 4070, 4090             | 2.6+        | 3.9+       | cu128      |
| Blackwell (RTX 50xx)    | RTX 5060, 5090             | 2.6+        | 3.9+       | cu128      |

All current GPU generations use the same install command:
```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
```

### Docker (alternative)

A `Dockerfile` is provided, though it targets the original PyTorch 1.7.1 environment.
For modern GPUs, the pip install above is simpler:

```bash
docker build -t countpnn .
docker run --gpus all -v /your/data:/data countpnn python predict.py ...
```

---

## 3. Pretrained Models

Each model is a self-contained folder with the following structure:

```
pnn_v2_fasterrcnn_640/
├── .hydra/
│   └── config.yaml      # training configuration (read automatically at inference)
├── best.pth             # model weights
├── train_log.csv        # training metrics per epoch
└── valid_log.csv        # validation metrics per epoch
```

The detection threshold is stored inside `best.pth` alongside the weights and is used
automatically when `threshold` is not specified.

### Available pretrained models

| Folder                              | Type      | Staining | Backbone   |
|-------------------------------------|-----------|----------|------------|
| `pnn_v2_fasterrcnn_640`             | Detection | WFA/PNN  | ResNet50   |
| `pv_v2_fasterrcnn_640`              | Detection | PV       | ResNet50   |
| `pnn_v2_scoring_rank_learning`      | Scoring   | WFA/PNN  | ConvNet    |
| `pv_v2_scoring_rank_learning`       | Scoring   | PV       | ConvNet    |
| `pnn_v2_scoring_ordinal_regression` | Scoring   | WFA/PNN  | ConvNet    |
| `pv_v2_scoring_ordinal_regression`  | Scoring   | PV       | ConvNet    |

---

## 4. Quick Start — Single Image (CLI)

`predict.py` is the command-line entry point for single-image or small-batch prediction.

### Syntax

```bash
python predict.py <model_folder> <image(s)> [options]
```

### Arguments

| Argument             | Default             | Description                                                      |
|----------------------|---------------------|------------------------------------------------------------------|
| `run`                | *(required)*        | Detection model folder (e.g. `pnn_v2_fasterrcnn_640`)           |
| `data`               | *(required)*        | One or more input images (TIFF, PNG, JPEG, HDF5)                 |
| `-d`, `--device`     | `cpu`               | PyTorch device — use `cuda:0` for GPU                            |
| `-b`, `--batch-size` | `1`                 | Number of image patches processed per forward pass               |
| `-t`, `--threshold`  | *(from checkpoint)* | Detection threshold; lower = more detections, higher = fewer     |
| `-r`, `--rescore`    | `None`              | Scoring model folder; omit to skip rescoring                     |
| `-o`, `--output`     | `localizations.csv` | Output CSV path                                                  |

### Examples

```bash
# Detection only, threshold from checkpoint, CPU
python predict.py pnn_v2_fasterrcnn_640 image.tif

# Detection + rescoring, GPU, low threshold for high recall
python predict.py pnn_v2_fasterrcnn_640 image.tif \
    -d cuda:0 \
    -r pnn_v2_scoring_rank_learning \
    -t 0.0 \
    -o results.csv

# Process multiple images at once
python predict.py pnn_v2_fasterrcnn_640 slice_*.tif \
    -d cuda:0 \
    -r pnn_v2_scoring_rank_learning \
    -o results.csv

# PV cells (C2 channel)
python predict.py pv_v2_fasterrcnn_640 slice_C2.tif \
    -d cuda:0 \
    -r pv_v2_scoring_rank_learning \
    -o pv_results.csv
```

### Input format

- **TIFF / PNG / JPEG**: A single 2-D (H×W) or 3-D (1×H×W) grayscale image.
- **HDF5**: Image stored in the `/data` dataset.
- Large images are automatically split into overlapping 640×640 patches; results are
  stitched back with NMS to avoid duplicates at tile boundaries.

---

## 5. Python API — CellDetector class

`CellDetector` is a stateful wrapper that loads the models **once** and reuses them
across many images. This is the recommended approach for batch processing because
reloading weights on every image wastes time and VRAM.

### Import

```python
from detector import CellDetector
```

### Constructor

```python
detector = CellDetector(
    run_path,           # str or Path — detection model folder
    device='cpu',       # str — e.g. 'cuda:0'
    threshold=None,     # float or None — None = use value from checkpoint
    rescorer_path=None, # str or Path or None — None = skip rescoring
)
```

At construction time the models are loaded from disk and transferred to the device.
All subsequent `predict()` calls reuse the same GPU tensors.

### predict()

```python
localizations = detector.predict(
    image_path,     # str or Path
    batch_size=1,   # int — patches per forward pass
)
```

Returns a `pandas.DataFrame` (see [Output CSV Format](#7-output-csv-format)).

### Examples

```python
from detector import CellDetector

# WFA staining with rescoring
detector = CellDetector(
    run_path='pnn_v2_fasterrcnn_640',
    device='cuda:0',
    threshold=0.05,
    rescorer_path='pnn_v2_scoring_rank_learning',
)

df = detector.predict('slice_001_C1.tif')
df.to_csv('slice_001_cells.csv', index=False)

# Reuse the same detector for more images — no reloading
for path in image_paths:
    df = detector.predict(path)
    df.to_csv(path.replace('.tif', '_cells.csv'), index=False)
```

```python
# Detection only — skip rescoring
detector = CellDetector(
    run_path='pnn_v2_fasterrcnn_640',
    device='cuda:0',
    rescorer_path=None,   # <-- omit rescoring
)
```

```python
# PV cells
detector = CellDetector(
    run_path='pv_v2_fasterrcnn_640',
    device='cuda:0',
    rescorer_path='pv_v2_scoring_rank_learning',
)
```

```python
# Switch to a future model version — no other changes needed
detector = CellDetector(
    run_path='pnn_v3_fasterrcnn_640',   # new folder, same API
    device='cuda:0',
    rescorer_path='pnn_v3_scoring_rank_learning',
)
```

---

## 6. Batch Processing a Dataset

`count_all_images_dataset.py` processes an entire experiment folder in one run.

### Expected dataset folder structure

```
DATASET_PATH/
├── MouseA/
│   ├── hiRes/
│   │   ├── MouseA_001_A1_1-C1.tif
│   │   ├── MouseA_001_A1_2-C1.tif
│   │   └── ...
│   └── counts/             ← created automatically if missing
│       ├── MouseA_001_A1_1-cells_C1.csv
│       └── ...
├── MouseB/
│   ├── hiRes/
│   └── counts/
└── ...
```

Mouse folders without a `hiRes/` subfolder are skipped automatically.

### Configuration

Open `count_all_images_dataset.py` and edit the constants at the top of `main()`:

```python
DATASET_PATH = r'E:\path\to\your\DATASET'   # root folder containing mouse subfolders
STAINING     = "WFA"                          # "WFA" or "PV"
THRESHOLD    = 0.05                           # detection threshold
DEVICE       = "cuda:0"                       # "cpu" if no GPU available
# Set SCORING_MODEL = None to skip rescoring:
# SCORING_MODEL = None
```

Switching `STAINING` automatically selects the correct file pattern, detection model,
and scoring model:

| `STAINING` | File pattern | Detection model         | Scoring model                  |
|------------|--------------|-------------------------|--------------------------------|
| `"WFA"`    | `*-C1.tif`   | `pnn_v2_fasterrcnn_640` | `pnn_v2_scoring_rank_learning` |
| `"PV"`     | `*-C2.tif`   | `pv_v2_fasterrcnn_640`  | `pv_v2_scoring_rank_learning`  |

### Running

```bash
python count_all_images_dataset.py
```

### Resuming an interrupted run

The script automatically **skips images whose output CSV already exists**. If the run
is interrupted (CUDA error, power loss, etc.), simply re-run the same command and it
will continue from where it left off.

### Error handling

- Per-image exceptions are caught and logged; the run continues with the next image.
- If a **CUDA error** occurs, the CUDA context is marked as broken. All subsequent
  images are skipped (rather than causing further errors) and recorded in the error log.
- After every mouse, GPU memory is freed with `torch.cuda.empty_cache()`.
- A 10-second pause between mice reduces sustained GPU load.

### Error log

At the end of the run, a file named `bad_images_{STAINING}.csv` is written to
`DATASET_PATH`. It contains:

| Column   | Description                           |
|----------|---------------------------------------|
| mouse    | Mouse folder name                     |
| image    | Image filename                        |
| staining | `"WFA"` or `"PV"`                     |
| error    | Exception message or skip reason      |

Re-running the script after fixing the underlying issue will process only the failed
images (since successful outputs already exist on disk).

---

## 7. Output CSV Format

All prediction scripts produce a CSV file with one row per detected cell.

### Columns

| Column    | Type    | Description                                                             |
|-----------|---------|-------------------------------------------------------------------------|
| `X`       | float   | Horizontal coordinate (column index, pixels) of the cell centre         |
| `Y`       | float   | Vertical coordinate (row index, pixels) of the cell centre              |
| `class`   | int     | Cell class — always `0` for single-class models                         |
| `score`   | float   | Detection confidence score from FasterRCNN [0–1]                        |
| `imgName` | str     | Source image filename (basename)                                        |
| `thr`     | float   | Detection threshold that was applied                                    |
| `rescore` | float   | *(only if scoring model used)* Agreement quality score [0–1]            |

### Example

```
X,Y,class,score,imgName,thr,rescore
150.5,200.3,0,0.85,MouseA_001_A1_1-C1.tif,0.05,0.73
155.2,205.1,0,0.92,MouseA_001_A1_1-C1.tif,0.05,0.81
312.0,480.7,0,0.78,MouseA_001_A1_1-C1.tif,0.05,0.41
```

### Coordinate system

`X` is the column (horizontal) and `Y` is the row (vertical), with the origin at the
top-left corner of the image, consistent with numpy/PIL conventions.

### Filtering by score

After running, you can filter cells by detection confidence or agreement score in
Python:

```python
import pandas as pd

df = pd.read_csv('MouseA_001_A1_1-cells_C1.csv')

# Keep only high-confidence detections
high_conf = df[df['score'] > 0.5]

# Keep only cells with good inter-rater agreement
agreed = df[df['rescore'] > 0.6]

print(f"Total: {len(df)}, High-conf: {len(high_conf)}, Agreed: {len(agreed)}")
```

---

## 8. Troubleshooting

### `CUDA error: unknown error`

The GPU context has been corrupted, typically by one of:

1. **VRAM exhaustion** — too many allocations across many images without freeing memory.
   The script handles this by marking the CUDA context as broken and skipping remaining
   images. Re-run the script; already-completed images are skipped automatically.

2. **Driver/thermal event** — rare on healthy hardware. Check temperatures with:
   ```bash
   nvidia-smi --query-gpu=temperature.gpu,power.draw,memory.used --format=csv -l 2
   ```
   For an RTX 3060, throttling starts around 83°C.

3. **Many DataLoader workers on Windows** — `num_workers > 0` with multiprocessing on
   Windows can corrupt shared memory across long runs. The code already sets
   `num_workers=0` to avoid this.

### `[Errno 22] Invalid argument` + `pickle data was truncated`

This is caused by DataLoader worker processes crashing on Windows when
`num_workers > 0`. Already fixed by setting `num_workers=0` in `predict.py`.

### `RuntimeError: CUDA out of memory`

Reduce the batch size to `1` (already the default). If it still fails the image may
have an unusually large number of patches. Try reducing the image resolution before
processing.

### Output CSV is empty / no cells detected

- The threshold may be too high. Try lowering it (`THRESHOLD = 0.01` or even `0.0`).
- Verify the correct staining channel is selected (`STAINING = "WFA"` → C1 files,
  `STAINING = "PV"` → C2 files).
- Check the image is 1-channel grayscale. RGB images will cause unexpected behaviour.

### `FileNotFoundError: No checkpoint found in ...`

The model folder is missing or incomplete. It must contain:
```
<model_folder>/
├── .hydra/config.yaml
└── best.pth
```

---

## 9. Training Your Own Models

### Stage 1 — Localization model

Training uses [Hydra](https://hydra.cc/) config composition. Experiment configs are in
`conf/experiment/`.

```bash
# FasterRCNN on Perineuronal Nets dataset (640×640 patches)
python train.py experiment=perineuronal-nets/detection/fasterrcnn_640

# FasterRCNN on Perineuronal Nets dataset (480×480 patches)
python train.py experiment=perineuronal-nets/detection/fasterrcnn_480

# CSRNet density model on VGG Cells
python train.py experiment=vgg-cells/density/csrnet

# Override seed or GPU
python train.py experiment=perineuronal-nets/detection/fasterrcnn_640 seed=42 gpu=1
```

Checkpoints and logs are written to `runs/`. The best model is saved as `best.pth`
and can be used directly with `CellDetector` or `predict.py`.

### Stage 2 — Scoring model

Scoring models require the Perineuronal Nets dataset (multi-rater annotations).

```bash
# Pairwise rank learning (recommended)
python train_score.py method=pairwise_balanced seed=67

# Ordinal regression
python train_score.py method=ordinal_regression seed=87

# Simple regression
python train_score.py method=simple_regression seed=42
```

Runs are written to `runs_score/`.

### Adding a new model version

To create e.g. `pnn_v3_fasterrcnn_640`:

1. Add or copy an experiment config in `conf/experiment/perineuronal-nets/detection/`.
2. Run training: `python train.py experiment=perineuronal-nets/detection/fasterrcnn_v3`
3. Copy the resulting run folder and rename it `pnn_v3_fasterrcnn_640`.
4. Use it with `CellDetector(run_path='pnn_v3_fasterrcnn_640', ...)`.

No code changes are needed — the folder structure is all that matters.

---

## 10. Evaluating Models

### Localization model

```bash
python evaluate.py runs/experiment=perineuronal-nets/detection/fasterrcnn_640/ \
    --device cuda \
    --best-on-metric count/game-3/macro
```

Results are saved under `test_predictions/` inside the run folder:
- `all_gt_preds.csv.gz` — matched ground-truth and predicted points per threshold
- `all_metrics.csv.gz` — per-image metrics (GAME, precision, recall, etc.)

### Scoring model

```bash
python evaluate_score.py runs_score/method=pairwise_balanced,seed=67/ \
    --device cuda
```

Reports Spearman correlation between predicted scores and ground-truth agreement.

### Rescoring existing predictions

If you have a localization CSV from a previous run and want to add/update the rescore
column without re-running detection:

```bash
python score.py pnn_v2_scoring_rank_learning localizations.csv \
    --root /path/to/images \
    --device cuda:0 \
    --output rescored.csv
```

---

*For questions or issues, open a ticket on the project repository.*
