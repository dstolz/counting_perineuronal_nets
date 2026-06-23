# Cell Detection & QC Toolkit — User Guide

Welcome to the user guide for the MATLAB graphical tools in the
`customizations/` folder. These three GUIs wrap the project's Python deep
learning pipeline so you can detect, clean up, and quality-check cells in
fluorescence microscopy images **without writing any code or using the command
line**.

If you are new here, read this page first, then open the guide for whichever
tool you need.

---

## The three tools at a glance

| Tool | What it does | When you use it |
|------|--------------|-----------------|
| **[Cell Discovery](CellDiscovery.md)** | Runs automatic cell detection on a whole folder of images and writes one results file (`*_locs.csv`) per image. | **First.** To find cells in new images. |
| **[Cell Neighbor Resolver](CellNeighborResolverApp.md)** | Finds pairs of detections that sit too close together (likely duplicates of the same cell) and lets you keep one, keep both, or merge them. | **Second.** To clean up over-counting. |
| **[Cell Localization QC](CellLocalizationQCApp.md)** | Shows every detection as a small image crop so you can mark each one Good / Bad / Uncertain and produce a reviewed dataset. | **Third.** To verify and grade the detections. |

These are normally used **in order**, but each one can also be used on its own.

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
   │ Cell Neighbor        │   merge / remove duplicate detections
   │ Resolver             │   (updates *_locs.csv in place)
   └──────────────────────┘
            │
            ▼
   ┌──────────────────────┐
   │ Cell Localization QC │   review each cell, write *_QC.csv
   └──────────────────────┘
            │
            ▼
   Reviewed, graded cell counts
```

---

## The typical workflow

1. **Detect** — Open **Cell Discovery**, point it at the folder containing your
   images, choose the correct detection model, and start the batch. Each image
   gets a companion `*_locs.csv` file listing the X/Y location and score of
   every detected cell.

2. **Resolve duplicates** *(optional but recommended)* — Open the
   **Cell Neighbor Resolver**, scan the same folder, and step through pairs of
   detections that are very close together. Decide whether each pair is one cell
   or two. Your decisions are written back into the `*_locs.csv` files.

3. **Quality check** — Open **Cell Localization QC**, scan the folder, and grade
   each detection (Good / Bad / Uncertain / Ignore) by looking at a montage of
   image crops. Your labels are saved to separate `*_QC.csv` files so the
   original detections are never overwritten.

---

## Before you start: one-time setup

All three tools call the project's Python code behind the scenes, so you need a
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

All three tools **remember your settings** between MATLAB sessions, so you only
configure them once.

---

## Key concepts and shared vocabulary

These terms come up across all three tools.

- **Detection / localization** — A single cell the model found, recorded as an
  X/Y pixel coordinate plus a confidence **score**.

- **`*_locs.csv`** — The localization file written by Cell Discovery, with one
  row per detected cell (columns include `X`, `Y`, `class`, `score`). This is
  the file the Neighbor Resolver edits and the QC tool reads.

- **Detection model** — The trained network that finds cells. Use the model that
  matches your stain:
  - **WFA / PNN staining** → a `pnn_*` model (often the first page, "C1").
  - **PV staining** → a `pv_*` model (often the second page, "C2").

- **Rescore model (Stage 2)** — An optional second model that re-grades each
  detection with a `0–1` quality estimate. Available in Cell Discovery and the
  Neighbor Resolver.

- **Multi-page TIFF** — A single `.tif` file holding several channels as
  "pages" (e.g. page 1 = WFA, page 2 = PV). Cell Discovery can map a different
  model to each page.

- **Score vs. Rescore** — *Score* is the detector's raw confidence. *Rescore* is
  the optional Stage-2 quality estimate. Both can be used for sorting,
  filtering, and threshold classification in the QC tool.

---

## Tips that apply to every tool

- **Hover for help.** Almost every control has a tooltip — hold your mouse over
  a button or field to see what it does and its default value.

- **Your settings are saved automatically.** Window size, folders, and options
  persist across sessions.

- **The Command Window shows progress.** Detailed status and any error messages
  are printed to the MATLAB Command Window while a tool runs — keep it visible.

- **Original data is preserved.** The QC tool writes to separate `*_QC.csv`
  files. The Neighbor Resolver edits `*_locs.csv` in place but supports **Undo**
  and only saves when you choose to.

---

## Per-tool guides

- **[Cell Discovery](CellDiscovery.md)** — batch cell detection
- **[Cell Neighbor Resolver](CellNeighborResolverApp.md)** — resolving duplicate detections
- **[Cell Localization QC](CellLocalizationQCApp.md)** — manual quality control review

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
