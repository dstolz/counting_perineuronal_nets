# Cell Detection & QC Toolkit — User Guide

Welcome to the user guide for the MATLAB graphical tools in the
`customizations/` folder. These GUIs wrap the project's Python deep learning
pipeline so you can detect, review and correct cells in fluorescence microscopy
images **without writing any code or using the command line**.

If you are new here, read this page first, then open the guide for whichever
tool you need.

---

## The tools at a glance

| Tool | What it does | When you use it |
|------|--------------|-----------------|
| **[Cell Dataset Manager](CellDatasetManager.md)** | Finds every dataset under a folder, shows how far each has moved through the pipeline, and launches the other tools on a chosen dataset. | **Any time.** As your home base / status dashboard. |
| **[Cell Discovery](CellDiscovery.md)** | Runs automatic cell detection on a whole folder of images and writes one results file (`*_locs.csv`) per image. | **First.** To find cells in new images. |
| **[Cell Curator](CellCurator.md)** | Shows the detections a screenful at a time so you can mark the wrong ones and confirm the rest; adds missed cells, moves, merges duplicates and excludes damaged regions; writes the final list of kept cells. | **Second.** To review, correct and finish each section. |
| **[Cell Analysis](CellAnalysis.md)** | Measures every cell (distance from the brain surface, luminance, morphology, the shape of the nets) and plots the distributions within a section and across sections, grouped by subject, by the lab database's tags or by your own groups. | **Third.** To look at and export the results. |

Cell Discovery and Cell Curator are normally used **in order**, but each one can
also be used on its own. The **Cell Dataset Manager** sits above them: open it
first to see what still needs doing, then launch the right tool from there (its
**Curate…** button opens Cell Curator).

```
   Microscopy images (.tif)
            │
            ▼
   ┌──────────────────────┐
   │   Cell Discovery     │   detect cells, write *_locs.csv
   └──────────────────────┘
            │
            ▼
   ┌──────────────────────┐
   │ Cell Curator         │   review, correct and finish each section;
   │                      │   *_locs.csv is never modified
   └──────────────────────┘
            │
            ▼
   *_final.csv: the kept cells of each source
            │
            ▼
   ┌──────────────────────┐
   │ Cell Analysis        │   measure the kept cells, plot and export
   └──────────────────────┘
```

---

## The typical workflow

1. **Detect** — Open **Cell Discovery**, point it at the folder containing your
   images, choose the correct detection model, and start the batch. Each image
   gets a companion `*_locs.csv` file listing the X/Y location and score of
   every detected cell.

2. **Curate** — Select the dataset in the **Cell Dataset Manager** and press
   **Curate…** (or run `CellCurator('<folder>')`). Review each page of
   detections: mark the few that are wrong, press Enter to confirm the rest,
   resolve close pairs, add missed cells, and mark each source complete. Your
   decisions are saved in separate curation files and a final list
   (`*_final.csv`) of kept cells is written; the detector's `*_locs.csv` is
   never changed. See the **[Cell Curator guide](CellCurator.md)**.

3. **Analyze** — Press **Analyze…** in the **Cell Dataset Manager** (or run
   `CellAnalysis('<folder>')`), then **Measure all**. Every kept cell gets its
   distance from the brain surface, its luminance and its morphology; plot any
   of them for one section or across sections, grouped by subject or by your
   own groups, and export the numbers. See the
   **[Cell Analysis guide](CellAnalysis.md)**.

Cell Curator replaced two older tools, the **Cell Neighbor Resolver**
(duplicates) and **Cell Localization QC** (Good / Bad grading), which have been
removed. If you used them, Cell Curator imports what they saved the first time
it opens a source (see
[Coming from the old tools](CellCurator.md#coming-from-the-old-tools)).

---

## Before you start: one-time setup

The tools call the project's Python code behind the scenes, so you need a
working Python environment with the project dependencies installed. This is set
up once.

1. **Install the Python environment.** Follow the *Setup* section in the
   project's main `README` (create the `countpnn` conda environment and install
   the requirements).

2. **Add the tools to your MATLAB path.** In MATLAB, run:

   ```matlab
   addpath('customizations')
   ```

   (Use the full path to the `customizations` folder if MATLAB is not already in
   the project directory.)

3. **Tell the tools where Python is.** The first time you open **Cell
   Discovery**, fill in the **Python Environment** panel — typically just your
   conda environment name (e.g. `countpnn`). Use the **Test env** button to
   confirm everything is found. See the
   [Cell Discovery guide](CellDiscovery.md#python-environment) for details.

All the tools **remember your settings** between MATLAB sessions, so you only
configure them once.

---

## Key concepts and shared vocabulary

These terms come up across the tools.

- **Detection / localization** — A single cell the model found, recorded as an
  X/Y pixel coordinate plus a confidence **score**.

- **`*_locs.csv`** — The localization file written by Cell Discovery, with one
  row per detected cell (columns include `X`, `Y`, `class`, `score`). Cell
  Curator reads it and never modifies it.

- **Curation files** — What Cell Curator writes for each source:
  `<name>_curation.csv` (your decisions), a journal beside it,
  `<base>.curation.json` (exclusion regions, counts) and, when a source is
  complete, `<name>_final.csv` (the kept cells).

- **Detection model** — The trained network that finds cells. Use the model that
  matches your stain:
  - **WFA / PNN staining** → a `pnn_*` model (often the first page, "C1").
  - **PV staining** → a `pv_*` model (often the second page, "C2").

- **Rescore model (Stage 2)** — An optional second model that re-grades each
  detection with a `0–1` quality estimate. Available in Cell Discovery and Cell
  Curator (for cells you add or move).

- **Multi-page TIFF** — A single `.tif` file holding several channels as
  "pages" (e.g. page 1 = WFA, page 2 = PV). Cell Discovery can map a different
  model to each page.

- **Score vs. Rescore** — *Score* is the detector's raw confidence. *Rescore* is
  the optional Stage-2 quality estimate. Cell Curator uses the rescore to
  propose a label for each page.

- **Dataset manifest** — A small sidecar file (`<base>.celldataset.json`) each
  tool keeps next to your image. It is the toolkit's record of which image and
  page were analyzed, and **which localization file is the active analysis
  file** for each channel/page. Every tool reads/writes the file recorded there,
  so they all agree on "the right file." You never edit it by hand; if you need a
  different localization file treated as the active one, use **Set active
  locs…** in the [Cell Dataset Manager](CellDatasetManager.md).

---

## Tips that apply to every tool

- **Hover for help.** Almost every control has a tooltip — hold your mouse over
  a button or field to see what it does and its default value.

- **Your settings are saved automatically.** Window size, folders, and options
  persist across sessions.

- **The Command Window shows progress.** Detailed status and any error messages
  are printed to the MATLAB Command Window while a tool runs — keep it visible.

- **Original data is preserved.** Cell Curator never modifies `*_locs.csv`; its
  decisions go to separate curation files and are saved as you work, with
  **Undo** (`Ctrl+Z`).

---

## Per-tool guides

- **[Cell Dataset Manager](CellDatasetManager.md)** — dataset discovery, status overview, and launcher
- **[Cell Discovery](CellDiscovery.md)** — batch cell detection
- **[Cell Curator](CellCurator.md)** — review, correct and finish detections
- **[Cell Curation Reference](CellCuration-Reference.md)** — for maintainers: files, schema, tests, limitations
- **[Cell Dataset Manifest](CellDatasetManifest.md)** — the per-dataset record behind the tools (schema + code API)

---

## Getting help / troubleshooting basics

- **"No detection model found"** — Make sure the trained model folders (each
  containing a `best.pth` file) are present in the project root.
- **"Cannot import hydra or torch" / Test env fails** — Your Python environment
  isn't set correctly. See
  [Cell Discovery → Python environment](CellDiscovery.md#python-environment).
- **Nothing happens / callbacks stop working after an update** — In MATLAB run
  `clear classes` and reopen the tool.

Each tool's guide has a fuller **Troubleshooting** section.
