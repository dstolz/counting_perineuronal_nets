# Cell Dataset Manager — User Guide

The **Cell Dataset Manager** is the overview tool for the whole toolkit. Point
it at a parent folder and it finds **every dataset** underneath, shows how far
each one has moved through the pipeline (Detected → Resolved → Rescored →
Reviewed), and launches the other three tools pointed straight at whichever
dataset you select.

It is also usable **from code** (no GUI) so other scripts can ask "what has been
processed and what hasn't?"

---

## What counts as a "dataset"

A dataset is **one source image** (a `.tif`, possibly multi-page) together with
every file the other tools derive from it, grouped by the image's base name:

| File | Produced by | Meaning |
|------|-------------|---------|
| `<base>.tif` / `<base>_proj.tif` / `<base>_resized.tif` | (your images) | the source image |
| `<base>[_<channel><page>]_locs.csv` | Cell Discovery | detections |
| `<base>[_<channel><page>]_locs_resized.csv` | Cell Discovery | detections in resized coordinates |
| `<base>[_<channel><page>]_locs_QC.csv` | Cell Localization QC | manual review labels |

Each distinct `(channel, page)` localization stream is a **source** within the
dataset, so a two-page WFA/PV TIFF shows up as one dataset with two sources
(e.g. `PNN1`, `PV2`).

---

## Opening the tool

```matlab
addpath('customizations')
CellDatasetManager                 % open empty, then Browse + Scan
CellDatasetManager('D:\HISTOLOGY') % open and scan a folder immediately
```

The window has two tables:

- **Datasets** (left) — one row per dataset with page count, number of sources,
  total detections, and `k/n` progress for each stage, plus an overall
  **Status** (`New (image only)`, `Detected`, `Resolved`, `Rescored`,
  `Reviewed`, or `Partial`).
- **Selected dataset** (right) — a per-source breakdown of the highlighted
  dataset, plus buttons to act on it.

### Launch buttons

With a dataset (and optionally a source row) selected:

- **Detect cells…** — opens **Cell Discovery** on this dataset's folder.
- **Resolve neighbors…** — opens the **Cell Neighbor Resolver** on this folder
  and loads the selected source's CSV.
- **QC review…** — opens **Cell Localization QC** on this folder.
- **Set active locs…** — choose which localization CSV is the **active analysis
  file** for the selected source. Every other tool then reads/writes the file
  you pick here. Offers the source's discovered variants (plain `_locs`, resized
  `_locs_resized`) plus a browse option for anything else. (See *Manifest files*
  below.)
- **Open folder** / **Open manifest** — open the dataset's folder or its
  manifest file in your editor.

### TIFF preview

The right-hand **TIFF pages** panel previews the selected dataset's image. The
**View** dropdown switches between *Individual pages* (one gray tile per TIFF
page) and a *Colorized composite* (pages tinted distinct colours and merged).
Clicking a tile opens it full-size in its own zoom/pan window. A scale bar is
drawn from the TIFF's resolution tags (falling back to 0.645 µm/pixel).

Tick **Cell locations** to overlay each source's detected cell centres (read
from its `_locs.csv`) as bright open circles. On individual pages only that
page's source is shown; the composite shows every source. The **Colour**
dropdown chooses how the markers are coloured:

- **Uniform** — one bright tint per source (cyan for a single source), with a
  legend when a page carries more than one source.
- **By rescore** — each cell is coloured by its latest Stage-2 rescore `[0-1]`
  on a turbo ramp (blue = low, red = high), with a compact rescore key.
  Cells with no rescore yet are drawn grey, and sources lacking a `rescore`
  column fall back to the uniform tint.

---

## Manifest files

Each dataset gets a small sidecar file next to its image:

```
<base>.celldataset.json
```

The manifest is owned by its own class, **`CellDatasetManifest`** (schema
`celldataset/2.0`) — the manager and the other three GUIs all go through it. It
records two kinds of information:

- **Derivable facts** — which CSVs exist, detection counts, whether a CSV
  carries `CURATED_*` (resolved) or `rescore` columns, and QC counts. These are
  re-measured from the files on every scan, so the manifest can never drift out
  of sync with reality.
- **Authoritative pointers + provenance** that cannot be re-derived — the
  analyzed image and pages, **which localization CSV is the active analysis
  file** for each source, and when each stage ran / which tool/model produced
  it.

The other three GUIs update the manifest as they save, so the status the manager
shows always reflects the latest work. If you add or delete files by hand, the
next scan reconciles and rewrites the manifest. Use **Set active locs…** to
re-point a source's active analysis file; every other tool then honors it.

See the [Cell Dataset Manifest reference](CellDatasetManifest.md) for the schema
and the code API.

> You never edit these files by hand. Deleting one loses only the provenance
> history; the next scan rebuilds it from the files that are present. There is no
> migration from the older `celldataset/1.1` format — those are simply rebuilt.

---

## Using it from code

The discovery and manifest logic is a static API — handy for batch reporting or
custom scripts:

```matlab
% Struct array, one element per dataset, with full per-source status:
datasets = CellDatasetManager.scan('D:\HISTOLOGY');

% Flat one-row-per-dataset summary table:
T = CellDatasetManager.statusTable('D:\HISTOLOGY');

% Faster, file-existence-only scan (skips reading CSV contents):
datasets = CellDatasetManager.scan('D:\HISTOLOGY', struct('Probe', false));

% Scan without rewriting manifests:
datasets = CellDatasetManager.scan('D:\HISTOLOGY', struct('WriteManifest', false));
```

Each element of `datasets` has fields including `Base`, `Folder`, `DatasetID`,
`ImagePath`, `ManifestPath`, `PageCount`, `TotalDetections`, `Status`, and
`Sources` (a struct array with `Key`, `Channel`, `Page`, `CsvPath`, `Detected`,
`NumDetections`, `Resolved`, `Rescored`, `Reviewed`, and the QC counts).

---

## Troubleshooting

- **A dataset is missing** — the manager anchors on images and `*_locs.csv`
  files. A folder with neither is ignored. Check the parent directory and that
  filenames follow the `<base>[_<channel><page>]_locs.csv` convention.
- **Status looks stale** — press **Scan** again; status is recomputed from the
  files every scan.
- **Provenance (tool/model/time) is blank** — that stage was run before manifest
  support existed, or the file was produced outside the tools. The done/counts
  status is still correct; only the history is missing.
- **Callbacks stop working after an update** — run `clear classes` and reopen.
