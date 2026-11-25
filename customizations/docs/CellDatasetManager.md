# Cell Dataset Manager — User Guide

The **Cell Dataset Manager** is the overview tool for the whole toolkit. Point
it at a parent folder and it finds **every dataset** underneath, shows how far
each one is (detected, rescored, how many cells reviewed, which sources are
marked complete, what was sent to the lab database), and opens the other tools
on whichever dataset you select.

It is also usable **from code** (no window) so scripts can ask "what has been
processed and what hasn't?"

---

## What counts as a "dataset"

A dataset is **one source image** (a `.tif`, possibly multi-page) together with
every file the other tools derive from it:

| File | Produced by | Meaning |
| --- | --- | --- |
| `<base>.tif` | (your images) | the image detection ran on |
| `<base>[_<channel><page>]_locs.csv` | Cell Discovery | detections |
| `<base>[_<channel><page>]_locs_resized.csv`, `<base>_resized.tif` | Cell Discovery | detections in resized coordinates, and the resized image |
| `<stem>_curation.csv`, `<stem>_curation.journal.csv`, `<stem>_final.csv`, `<base>.curation.json` | [Cell Curator](CellCurator.md) | your decisions on each detection, the log of changes, the final list of kept cells, and the exclusion regions and counts |
| `<base>[_<channel><page>]_locs_QC.csv` | Cell Localization QC (removed) | manual review labels from the old tool; still read |
| `.provenance\*.json` | Cell Curator | the lab database record of each completed source |

Each distinct `(channel, page)` localization stream is a **source** within the
dataset, so a two-page WFA/PV TIFF shows up as one dataset with two sources
(e.g. `ECM1`, `PV2`).

A section stored the way the lab stores it, `<x>_proj.tif` beside
`<x>_proj_ECM1_locs.csv`, is **one** dataset named `<x>_proj`. (Until
2026-11-24 it was listed twice, once as an image without detections.) The exact
rules are in the [Cell Dataset Manifest reference](CellDatasetManifest.md#the-base-of-a-dataset).

---

## Opening the tool

```matlab
addpath('customizations')
CellDatasetManager                 % open empty, then Browse + Scan
CellDatasetManager('D:\HISTOLOGY') % open and scan a folder
```

The window opens at once; the first scan starts a moment later. A scan that
takes longer than about a second shows a progress window with **Cancel**
(canceling leaves the list as it was).

### The dataset list

One row per dataset:

| Column | Meaning |
| --- | --- |
| **Subject**, **Section** | From the file name (`SUBJ-ID-<n>…_<Section>_<Hemi>_…`); empty when the name does not follow the lab's convention. A subject in **red** is not in the lab database (see below) |
| **Name** | The dataset's base name |
| **Sources**, **Detections** | Sources with detections, and detections over all of them |
| **Rescored** | Sources that carry Stage-2 scores, `k/n` |
| **Reviewed %** | Share of the cells a person has decided (Cell Curator; a legacy QC file counts until the source is opened in Cell Curator) |
| **Curated** | Sources marked complete in Cell Curator, `k/n` |
| **Kept** | Kept cells: labeled Good by a person, reviewed, outside every exclusion region |
| **Status** | `New (image only)`, `Detected`, `Rescored`, `Reviewed` (legacy QC), `Curating`, `Curated` (every source complete), or `Partial` |
| **Database** | Where the lab database records of the completed sources are, e.g. `2 sent`, `1 waiting`, `1 needs you`, `1 kept here` |
| **Tags** | The tags the subject carries in the lab database (`cohort:a pilot`), as **Check subjects** last read them; empty before that |

Click a column header to sort. The cards above the list total everything found,
whatever the filter shows: datasets, datasets still to detect, sources,
detections, share of cells reviewed, sources curated, cells kept, and completed
sources whose current state is in the lab database.

### Finding the next thing to do

- **Find** — type words; only datasets that contain every word in their name,
  subject, section, folder or status, or in the lab database tags and variables
  of their subject, stay listed (`Ctrl+F` puts the cursor there). `1127
  curating` lists the sections of animal 1127 that are in curation.
- **Tags** — a filter of lab database tags; press Enter (`Ctrl+T` puts the
  cursor there). Tags separated by spaces must all hold, a leading `-` means
  "does not have", `cohort:*` means any tag of that namespace, a bare word is a
  bare tag: `cohort:a -qc:fail` lists the sections of cohort a whose subject is
  not marked as failed. It goes by the tags **Check subjects** last read, so a
  dataset whose subject was never checked, whose subject the database does not
  have, or whose name names no subject is not listed while a filter is set. The
  status line says when no subject here carries a tag you typed.
- **Show** — *All datasets*, *To detect* (an image, no detections), *To curate*
  (detected, no cell reviewed), *In curation*, *Curated*, or *Database: not sent*
  (a completed source whose current state was not sent from this computer).
- **Next to curate** (`Ctrl+E`) — selects the next listed dataset that has
  detections and is not complete, and in it the first unfinished source.
- **Enter** or a **double-click** on a dataset opens it in Cell Curator (Cell
  Discovery when it has no detections yet). A double-click on a source row opens
  that source.
- **Scan** (`F5`) reads everything again. The list is also refreshed by itself
  when a tool opened from here closes, and keeps your selection.

### The selected dataset

Below the list: the subject and section in words, the image, the folder, the
progress, and one row per source with its counts (**Reviewed**, **Good**,
**Bad**, **Kept**, **Complete**), its lab database record and whatever the
removed tools left (**Legacy**: a QC file, a resolved locs file; Cell Curator
imports both the first time it opens the source).

- **Detect cells…** — opens **Cell Discovery** on this dataset's folder.
- **Curate…** — opens **[Cell Curator](CellCurator.md)** on the parent folder
  you scanned (so review can carry on from one dataset to the next), showing
  the selected dataset and source.
- **Analyze…** — opens **[Cell Analysis](CellAnalysis.md)** on the parent folder
  you scanned: measurements of every cell and their distributions within and
  across sections.
- **Set active locs…** — choose which localization CSV is the **active analysis
  file** for the selected source. Cell Discovery, the exports and this window
  read the file you pick here. Cell Curator is the exception: it always reads
  the detector's own `_locs` file.
- **Set active image…** — choose which image is the analysis image when a
  dataset has several (raw, projection, resized).
- **Open folder** / **Open manifest** — the dataset's folder, or its manifest
  file in your editor.

### Export report

**Export report…** writes a CSV with one row per source of every dataset found:
subject, section, hemisphere, stain, dataset, source, page, detections,
rescored, reviewed, Good, Bad, Uncertain, kept, complete, status, the lab
database state and time, the path of the source's `_final.csv` (the kept cells)
and the folder. It is the table to start an analysis from, or to see what is
left.

### TIFF preview

The right-hand **TIFF pages** panel previews the selected dataset's image, a
moment after you stop moving through the list. The **View** dropdown switches
between *Individual pages* (one gray tile per TIFF page) and a *Colorized
composite* (pages tinted distinct colors and merged). A scale bar is drawn from
the TIFF's resolution tags (falling back to 0.645 µm/pixel). Pages are kept in
memory, so going back to a dataset you looked at is immediate.

In the preview itself:

- **Scroll** to zoom in or out at the pointer; zooming all the way out shows the
  whole image again. The pages of a TIFF zoom and pan together, so the same
  region of every channel stays side by side.
- **Drag** to pan.
- **Double-click** a tile to open it full-size, at a higher resolution, in its
  own window.
- **Right-click** a tile for *Fit whole image* and *Open in its own window*.

The preview has no axes toolbar; the scale bar follows the zoom.

Check **Cell locations** to overlay each source's detected cell centers as
filled circles. On
individual pages only that page's source is shown; the composite shows every
source. The **Color** dropdown chooses how the markers are colored:

- **Uniform** — one bright tint per source (cyan for a single source), with a
  legend when a page carries more than one source.
- **By page** — all sources of a TIFF page share that page's composite tint.
- **By rescore** — each cell is colored by its latest Stage-2 rescore `[0-1]`
  on a turbo ramp (blue = low, red = high), with a compact rescore key.
  Cells with no rescore yet are drawn gray, and sources lacking a `rescore`
  column fall back to the uniform tint.
- **By class** — each cell is colored by its label. The source's Cell Curator
  record (`<stem>_curation.csv`) is read first, and the legacy `*_QC.csv` only
  when there is none. Cells not yet reviewed are gray; merged duplicates and
  stale rows are not drawn. Sources with neither fall back to the uniform
  tint.

---

## The lab database (CarasLabDB)

When a source is marked complete in Cell Curator, a record of that curation is
written beside its files (`.provenance`) and, when this computer is set up for
the lab database, queued to be sent. The manager shows where those records are
and lets you act on them. **Nothing the manager or the other tools write
depends on the database**: without it everything works the same, and the
window says what is missing.

| Database column | Meaning |
| --- | --- |
| *(empty)* | no record: no source of the dataset is marked complete |
| **kept here** | a record is beside the files and not in this computer's outbox: the database was turned off here, the client is not installed, or the record was made on another computer |
| **waiting** | in the outbox, sent when the server answers |
| **sent** | sent to the lab database from this computer |
| **needs you** / **refused** | waits for a person, or was refused: the source's row says why, and the Database window lets you fix it |
| **(changed since)** | the curation files changed after the record was made; marking the source complete again records the new state |

At the right end of the status bar:

- **Check subjects** — asks the lab database which of the subjects named by the
  file names it has, and for their **tags** and **variables** (a few seconds at
  most; the only time the manager talks to the server). A subject it does not
  have is shown in red, because a record for it waits in the outbox until the
  subject is added to the database or assigned in the Database window. The
  answers are remembered on this computer, so later scans show them without
  asking. The tags fill the **Tags** column and are what the **Tags** filter
  goes by; the detail of a selected dataset also lists the subject's variables
  (`Age at perfusion = 92 d; housing = pair`), and the exported report has both
  (`SubjectTags`, `SubjectVariables`). Tags and variables are set in the lab
  database's own window, not here; Cell Analysis groups and plots by them.
- **Queue records** — puts the records that are only *kept here* into the
  outbox (for curation done while the database was turned off, or before the
  client was installed).
- **Database…** and the lamp — the window every lab toolbox shares: the server,
  your login, the storage roots mapped on this computer and the outbox. The
  Database column follows the outbox while records are being sent.

A disabled button says why in its tooltip (the client is not installed, or the
database is turned off on this computer).

---

## Manifest files

Each dataset gets a small sidecar file next to its image:

```text
<base>.celldataset.json
```

The manifest is owned by its own class, **`CellDatasetManifest`** (schema
`celldataset/2.0`) — the manager and the other GUIs all go through it. It
records two kinds of information:

- **Derivable facts** — which CSVs exist, detection counts, whether a CSV
  carries `CURATED_*` (resolved) or `rescore` columns, and QC counts. These are
  re-measured from the files on every scan, so the manifest can never drift out
  of sync with reality.
- **Authoritative pointers + provenance** that cannot be re-derived — the
  analyzed image and pages, **which localization CSV is the active analysis
  file** for each source, and when each stage ran / which tool/model produced
  it (for a detection also how the detector's input was prepared: resize,
  background subtraction, normalization).

The other GUIs update the manifest as they save, so the status the manager
shows always reflects the latest work. If you add or delete files by hand, the
next scan reconciles the manifest; a scan of a folder where nothing changed
writes nothing. Use **Set active locs…** to re-point a source's active analysis
file.

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

% One row per dataset, and one row per source (the report the window exports):
T = CellDatasetManager.statusTable('D:\HISTOLOGY');
S = CellDatasetManager.sourceTable('D:\HISTOLOGY');
writetable(S, 'progress.csv');

% Both also take what scan() returned, so the folder is read once:
T = CellDatasetManager.statusTable(datasets);

% Counts and the stage ('detect', 'curate', 'curating', 'curated') of one dataset:
p = CellDatasetManager.progressOf(datasets(1));

% Faster, file-existence-only scan (skips reading CSV contents):
datasets = CellDatasetManager.scan('D:\HISTOLOGY', struct('Probe', false));

% Scan without rewriting manifests, and without looking for database records:
datasets = CellDatasetManager.scan('D:\HISTOLOGY', struct('WriteManifest', false, 'Database', false));
```

Each element of `datasets` has fields including `Base`, `Folder`, `DatasetID`,
`ImagePath`, `ManifestPath`, `PageCount`, `TotalDetections`, `Status`,
`SubjectID`, `SectionLabel`, `Section` (the parsed name), `SubjectAsked`,
`SubjectKnown`, `SubjectText` (what the lab database last said about the
subject), `SubjectTags`, `SubjectVariables` and `SubjectFactsRead` (its tags and
variable values there), `Database`, and `Sources` (a struct array with `Key`, `Channel`,
`Page`, `CsvPath`, `Detected`, `NumDetections`, `Rescored`, the `Cur*` counts of
Cell Curator, the legacy `Reviewed`/`Qc*` counts, and `Db`, the state of the
source's lab database record).

The window itself can be driven from a script (and is, by its tests):
`app = CellDatasetManager(folder, 'Scan', 'now')`, then `app.setFilter`,
`app.selectDataset`, `app.selectSource`, `app.nextToCurate`,
`app.exportReport(file)`; see `help CellDatasetManager`.

---

## Troubleshooting

- **A dataset is missing** — the manager anchors on images and `*_locs.csv`
  files. A folder with neither is ignored. Check the parent directory, the
  **Find** and **Show** filters, and that filenames follow the
  `<base>[_<channel><page>]_locs.csv` convention.
- **Status looks stale** — press **Scan** (`F5`); status is recomputed from the
  files every scan.
- **Provenance (tool/model/time) is blank** — that stage was run before manifest
  support existed, or the file was produced outside the tools. The done/counts
  status is still correct; only the history is missing.
- **Database says "needs you"** — select the dataset: the source's row says why
  (a subject the database does not have, a folder outside the storage roots
  mapped on this computer, …). Open **Database…** to fix it.
- **Database buttons are gray** — hover over them: the tooltip says whether the
  client is not installed or the database is turned off on this computer.
- **Callbacks stop working after an update** — run `clear classes` and reopen.
