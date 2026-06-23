# Cell Localization QC — Manual Quality Control Review

[← Back to the User Guide home](Home.md)

The detector finds candidate cells, but you usually want a human to confirm
them. **Cell Localization QC** shows every detection as a small image crop in a
montage so you can quickly grade each one — **Good, Bad, Uncertain, or Ignore** —
using clicks or keyboard shortcuts. Your labels are saved to separate `*_QC.csv`
files, so the original detections are never overwritten. It is the **third** and
final tool in the workflow.

Open it from the MATLAB Command Window:

```matlab
CellLocalizationQCApp
```

---

## What it does

- Scans a folder for image datasets and their `*_locs.csv` localization files.
- Shows the detections for a chosen source as a **montage of small crops**, a
  block at a time.
- Lets you classify each detection by clicking, holding a class key, or
  selecting groups.
- Saves your review labels to a companion `*_QC.csv` file, merged back by row
  when you reopen a source.
- Provides bulk tools: classify by score threshold, plot score histograms by
  class, and a full-image map for region-based classification.

---

## Quick start

1. **Scan a folder.** Enter or **Browse** to the parent folder, then click
   **Scan**. Datasets it finds appear in the **Datasets** table on the left.

2. **Pick a dataset and source.** Click a dataset row, then choose the
   **Source** (which localization CSV / channel) from the toolbar dropdown.

3. **Review the montage.** The center panel fills with a montage of detection
   crops. Click a crop to select it; the large view and metadata appear on the
   right.

4. **Classify.** Press a class key (`g`, `b`, `u`, `i`) or click a class button.
   With **Auto advance** on, the selection moves to the next unreviewed cell
   automatically.

5. **Move through blocks.** Use **Block >** / **< Block** (or `w`/`q`) to page
   through all detections.

6. **Save.** Press **Save** (or `Ctrl+S`). Labels go to a `*_QC.csv` file.

---

## The window, panel by panel

### Toolbar

- **Parent / Browse / Scan** — Choose and scan the folder for datasets.
- **Open Folder** — Opens the current dataset's folder in your file browser.
- **Source** — Selects which localization CSV / channel you're reviewing.
- **Display** mode — How crops are shown: target channel only, companion channel
  only, side-by-side, or false-color overlay.
- **Contrast** mode — How brightness is scaled for display (per crop, per
  channel/dataset, manual, or percentile). Display only — never changes data.
- **Settings** — Opens persistent options (file patterns, channels, categories,
  autosave, markers). See [Settings](#settings).
- **Save** — Writes the review table to `*_QC.csv`.
- **Cells/block** — How many crops per montage block (default 20).
- **Crop W / Crop H / Square** — Size of each crop in pixels; **Square** keeps
  them equal.
- **Marker** — Show/hide the marker at each detection's center.
- **Sort** (two levels) — Order the detections (e.g. by score) for review.
- **Filter** — Limit which detections are shown (e.g. unreviewed only, Bad
  only) without deleting anything.
- **Auto advance** — After classifying a single cell, jump to the next
  unreviewed one.

### Left panel — Datasets

A table of all scanned datasets with per-dataset counts: total, reviewed,
unreviewed, and how many are Good / Bad / Uncertain, plus a status column. The
active dataset row is highlighted. Click a row to load it.

### Center panel — Current block

The montage of detection crops for the current block.

- **Click a crop** to select it.
- **Hold a class key and click** to classify that specific crop (see
  [Classifying](#classifying-detections)).
- **Block navigation** — **< Block** / **Block >** buttons, a block dropdown to
  jump directly, and a summary label.

### Right panel — Selected detection

- **Large crop view** of the selected detection.
- **Class buttons** — One per category (Good / Bad / Uncertain / Ignore by
  default), color-coded. Click to label the selected cell.
- **Classify by score/rescore threshold…** — Bulk-classify by a numeric cutoff
  (see [Bulk tools](#bulk-classification-tools)).
- **Plot score/rescore histogram…** — Histogram of scores colored by QC class.
- **Plot full image QC map…** — Full-image scatter of all detections, colored by
  class, with freehand-region classification.
- **Update coordinate by click…** — Nudge a detection's recorded X/Y by clicking
  the correct spot (after confirmation).
- **Notes** — Free-text note saved with the selected detection.
- **Original CSV metadata** — The source row's values for reference.

---

## Classifying detections

There are several ways to assign a QC label, from one-at-a-time to bulk:

**One cell at a time**

- Select a crop, then click a **class button** or press its **class key**.
- Or **hold the class key and click** a crop to label just that crop.

**A whole visible block**

- Hold **Ctrl** or **Shift** and press a class key to classify **all visible
  cells** in the current block at once.

**By score/rescore threshold**

- Use **Classify by score/rescore threshold…** to label every cell whose score
  (or rescore) is *Above*, *Below*, or *Between* values you set — applied to the
  whole source or just the current filtered cells. NaN values are skipped.

**By region (full-image map)**

- Open **Plot full image QC map…**, then right-click to draw a freehand region
  and classify (or select) all cells inside it.

The default categories are **Good (`g`)**, **Bad (`b`)**, **Uncertain (`u`)**,
and **Ignore (`i`)**. You can change these in [Settings](#settings).

---

## Keyboard shortcuts

Shortcuts work when a text field is **not** focused. Press `Ctrl + /` inside the
app to see the live list (it reflects your current categories).

**Classification**

| Key | Action |
|-----|--------|
| `g` / `b` / `u` / `i` | Classify selected cell (Good / Bad / Uncertain / Ignore) |
| Hold class key + click | Classify the clicked crop |
| `Ctrl`/`Shift` + class key | Classify **all visible** cells in the block |
| `1`–`4` | Same as the class keys, by position |
| `Backspace` / `Delete` | Clear the selected cell's classification |

**Navigation**

| Key | Action |
|-----|--------|
| `Right` / `Tab` | Next cell |
| `Shift+Tab` / `Left` | Previous cell |
| `Space` | Next **unreviewed** cell |
| `w` / `n` | Next block |
| `q` / `p` | Previous block |
| `Home` / `End` | First / last cell |
| `Ctrl+Right` / `Ctrl+Left` | Next / previous dataset or source |

**View & file**

| Key | Action |
|-----|--------|
| `m` | Toggle the detection marker |
| `o` | Cycle the display channel mode |
| `a` | Select all visible cells |
| `f` | Open the selected crop in its own figure |
| `z` / `Ctrl+Z` | Undo last classification |
| `s` / `Ctrl+S` | Save |
| `Ctrl + /` | Show the keyboard shortcuts dialog |

---

## Sorting and filtering

- **Sort** the detections (two levels) by any numeric column — for example,
  lowest score first so you review the most doubtful detections early.
- **Filter** to focus the montage, e.g. *Show unreviewed only* or *Bad only*.
  Filtering hides rows but never deletes them.

These two combined make review fast: sort by score ascending, filter to
unreviewed, and work through the questionable cells first.

---

## Settings

The **Settings** dialog holds options that persist across sessions:

- **File patterns** — How datasets and localization files are recognized.
- **Channels** — The channel→page mapping (default: page 1 = `ECM`, page 2 =
  `PV`).
- **Categories** — The QC classes, their shortcut keys, and colors. Edit these
  to match your grading scheme.
- **Autosave** and **markers** — Automatic saving cadence and marker defaults.

### Project options

Also reachable from Settings:

- **Use resized CSVs** — Review the resized-coordinate detections
  (`*_locs_resized.csv`) paired with the preprocessed image
  (`*_preprocessed.tif`) instead of the standard `*_locs.csv` + projection
  image. Use this when you detected with resizing enabled in Cell Discovery.
- **Location source** — Choose **Original** (the detector's X/Y) or **Modified**
  (the [Cell Neighbor Resolver](CellNeighborResolverApp.md)'s curated X/Y,
  hiding cells the resolver deleted or merged away). Sources that were never
  curated fall back to the original X/Y with a warning. Your QC labels stay tied
  to the original CSV row, so they remain consistent whichever mode you use.

---

## Output

- Review labels are written to a separate **`*_QC.csv`** file alongside each
  source — your original `*_locs.csv` is never modified.
- Labels are keyed to the original CSV row, so reopening a source **merges your
  previous labels back in**, and they survive switching between Original and
  Modified location sources.
- Use **Export → Export observation CSV…** for a combined export of observations
  with their QC labels.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| **No datasets after Scan** | Check the folder and that it contains `*_proj.tif` images with matching `*_locs.csv` files. For resized review, enable **Use resized CSVs** in Settings. |
| **Crops are blank / wrong channel** | Check the **Display** mode and **Channels** mapping in Settings; confirm the right **Source** is selected. |
| **Crops look too dark/bright** | Change the **Contrast** mode (this is display-only and doesn't change data). |
| **"Modified" source shows a warning** | That source was never curated by the Neighbor Resolver; it falls back to original X/Y. |
| **Freehand region tool unavailable** | The full-image map's freehand classification needs the Image Processing Toolbox. |
| **Buttons stopped responding after a code update** | Run `clear classes; CellLocalizationQCApp` in MATLAB. |

---

[← Cell Neighbor Resolver](CellNeighborResolverApp.md) ·
[Back to the User Guide home](Home.md)
