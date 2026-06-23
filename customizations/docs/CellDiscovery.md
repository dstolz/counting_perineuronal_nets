# Cell Discovery — Batch Cell Detection

[← Back to the User Guide home](Home.md)

**Cell Discovery** runs automatic cell detection across a whole folder of
microscopy images. For each image it writes a `*_locs.csv` file listing the
location and confidence of every cell the model found. It is the **first** tool
in the workflow.

Open it from the MATLAB Command Window:

```matlab
CellDiscovery
```

---

## What it does

- Searches a folder (and all sub-folders) for image files matching a pattern.
- Runs the project's detection model (`predict.py`) on each image.
- Optionally re-grades each detection with a second "rescoring" model.
- Optionally pre-processes images first (background subtraction, resizing, and
  scanner-artifact correction).
- Handles **multi-page TIFFs**, letting you assign a different model to each
  page (e.g. a WFA model to page 1, a PV model to page 2).
- Writes one results CSV per image (per page), placed next to the source image.
- Shows an annotated preview figure and can save it as a PNG.

---

## Quick start

1. **Pick the image folder.** In *Directory & File Search*, click **Browse…**
   and select the parent folder. The tool searches it **recursively**, so all
   nested sub-folders are included. The count of matching files appears on the
   right.

2. **Set up Python** (first time only). In the *Python Environment* panel, enter
   your conda environment name (e.g. `countpnn`) and click **Test env**. See
   [Python environment](#python-environment) below.

3. **Map a model to each page.** In *Multi-page & Preprocessing*, set the
   **Detection Model** for the page(s) you want to process. See
   [Choosing models per page](#choosing-models-per-page).

4. **Choose your options.** Set the device (CPU/GPU), and decide whether to skip
   or overwrite images that already have results.

5. **Start.** Click **Start Batch**. Progress is shown at the bottom and printed
   in detail to the MATLAB Command Window. Use **Stop** to cancel.

---

## The window, panel by panel

### Directory & File Search

- **Parent directory** — The root folder searched recursively for images.
  Use **Browse…** to pick it.
- **File filter (regex)** — A pattern matched against each *file name* (not the
  full path). The default `(?i)\.tif$` matches any `.tif` file,
  case-insensitively. Edit it to narrow the search (for example, to match only
  files whose name contains `C1`).
- **Search** — Re-runs the search. The green label shows how many files matched.
- **Files to Process** list — Shows the matched files. By default **all** files
  are processed. To process only some, **Ctrl+click** to select a subset.

### Python Environment

See [Python environment](#python-environment).

### Multi-page & Preprocessing

This is where you tell the tool **which model to run on which page** and whether
to pre-process the image first. See
[Choosing models per page](#choosing-models-per-page) and
[Preprocessing](#preprocessing-optional).

### predict.py Options

- **Device** — Where to run: `cpu`, or a GPU such as `cuda:0`. GPU is much
  faster if you have one.
- **Batch size** — How many image tiles to process at once. Higher is faster but
  uses more memory. Leave at `1` if unsure.
- **Threshold** — The detection confidence cutoff (0–1). **Leave blank** to use
  the value baked into the model (recommended). Lower values find more cells but
  also more false positives.
- **Existing results** — Choose **Ignore (skip)** to leave already-processed
  images untouched (safe to re-run after an interruption), or **Overwrite** to
  re-process and replace them.

### Display & Export Options

- **Colormap** — Color scheme applied to grayscale images in the preview.
- **Auto contrast** — Stretches image brightness for easier viewing (display
  only; does not change the saved data).
- **Dot color / Dot size** — Appearance of the markers overlaid on detected
  cells.
- **Save annotated PNG…** — Also saves a `*_locs.png` preview image next to each
  CSV.
- **Save final preprocessed image as TIF…** — Saves the exact (pre-processed)
  image the model actually saw, as `*_preprocessed.tif`. Useful with the QC
  tool's "Use resized CSVs" mode.

### Run Controls

- **Start Batch** — Begins processing. The interface locks while running.
- **Stop** — Requests a stop; the current image finishes, then the batch halts.
- **Progress label** — Live status (e.g. which file of how many is running).

---

## Python environment

The tool runs the project's Python code, so it needs to know how to launch
Python. You configure this once in the *Python Environment* panel.

The simplest, recommended setup:

1. Leave **Python executable** as `python`.
2. Set **Conda env name** to your environment (e.g. `countpnn`).
3. Confirm **conda executable** is filled in (it is auto-detected; if blank,
   click **Browse…** and locate `conda.exe`).
4. Click **Test env**.

**Test env** does a quick check that Python plus the required `hydra` and
`torch` packages can be loaded. A green "Environment OK" message means you're
ready. If it fails, a dialog explains how to fix it — usually a misspelled
environment name or missing dependencies.

> **Repo root** is shown for reference — it's the project folder the tool found
> automatically (the folder containing `predict.py`). The detection and
> rescoring models are discovered from here.

You don't need to run **Test env** every time — the tool runs it automatically
as a pre-flight check when you press **Start Batch**.

---

## Choosing models per page

The **page-mapping table** is the heart of this tool. Each row says: *"for this
page number, run this detection model (and optionally this rescore model), with
these preprocessing settings."*

Columns:

| Column | Meaning |
|--------|---------|
| **Page** | The TIFF page number this row applies to (1 = first page). |
| **Suffix** | Text added to the output file name for this page (e.g. `page1`). |
| **Detection Model** | The model used to find cells. Choose `(skip)` to not process this page. |
| **Rescore Model** | Optional Stage-2 model that adds a quality score. `(none)` = no rescoring. |
| **Correct LSM** | Tick to apply bidirectional-scanner artifact correction first. |
| **Bg radius** | Background-subtraction disk radius in pixels (`0` = off). |
| **Resize x** | Resize factor applied before detection (`1` = no resize). |

- **Single-page images** only ever use the row for **page 1**.
- Use **Add page** / **Remove page** to manage rows for multi-page TIFFs.
- A page mapped to `(skip)` is ignored. This lets you, for example, process only
  page 2 of every file.

**Typical multi-page setup:** page 1 = a WFA/PNN model, page 2 = a PV model.

---

## Preprocessing (optional)

Pre-processing is applied to the image **before** detection, configured per page
in the mapping table:

- **Correct LSM** — Fixes the comb/stripe artifact that bidirectional laser
  scanning microscopes can produce. When at least one page has this ticked, the
  **LSM options…** button becomes available so you can fine-tune the correction
  parameters (with sensible defaults and a *Reset defaults* button).
- **Bg radius** — Morphological background subtraction; removes slowly-varying
  background using a disk of the given radius (in pixels). `0` disables it.
- **Resize x** — Rescales the image before detection. Use this if your images
  have a very different resolution from the training data
  (~0.645 µm/pixel). When resizing is used, a **second** CSV is written in the
  resized coordinate system (`*_locs_resized.csv`).

**Show preprocessed image in results** — When ticked, the preview shows the
processed image the model actually saw; when unticked, it shows the original raw
page with detections overlaid.

---

## Output files

For each processed image (and page), files are written **next to the source
image**:

| File | When | Contents |
|------|------|----------|
| `<name>[_page<k>]_locs.csv` | Always | One row per detected cell: `X`, `Y`, `class`, `score`, and more. |
| `<name>[_page<k>]_locs_resized.csv` | When resizing is used | Same detections, but in resized-image coordinates. |
| `<name>[_page<k>]_locs.png` | When *Save annotated PNG* is on | Preview image with detections overlaid. |
| `<name>[_page<k>]_preprocessed.tif` | When *Save preprocessed TIF* is on | The exact image the model received. |

These `*_locs.csv` files are the input to the
**[Cell Neighbor Resolver](CellNeighborResolverApp.md)** and
**[Cell Localization QC](CellLocalizationQCApp.md)** tools.

---

## Tips

- **Re-running is safe.** With **Ignore (skip)** selected, you can stop and
  restart the batch; already-finished images are skipped.
- **Process a subset.** Ctrl+click files in the *Files to Process* list to run
  only those.
- **Watch the Command Window.** Per-file progress, warnings, and Python output
  stream there in real time.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| **"No detection model found"** | No model folder (with a `best.pth`) was found in the project root. Make sure trained models are present. |
| **Test env fails / "cannot import hydra or torch"** | Your Python environment is wrong. Check the conda env name spelling, confirm the conda executable path, and that the env has the project requirements installed. |
| **"Invalid directory"** | The parent directory path doesn't exist — re-browse for it. |
| **No files found** | Your file filter (regex) excludes everything. The default `(?i)\.tif$` matches all `.tif` files. |
| **Buttons stopped responding after a code update** | Run `clear classes; CellDiscovery` in MATLAB. |
| **Detection is very slow** | Set **Device** to a GPU (`cuda:0`) if available, and/or increase **Batch size**. |

---

[← Back to the User Guide home](Home.md) ·
Next: [Cell Neighbor Resolver →](CellNeighborResolverApp.md)
