# Cell Dataset Manifest — Reference

`CellDatasetManifest` is the toolkit's **authoritative per-dataset record**. One
instance represents one dataset — a source image (a `.tif`, possibly multi-page)
plus everything the Cell\* tools derive from it — and answers, for every file
operation, *which file is the correct one*.

It is not a GUI. The [Cell Dataset Manager](CellDatasetManager.md) dashboard and
the working tools (Discovery and [Cell Curator](CellCurator.md)) all go through
it instead of guessing filenames from naming conventions.

---

## Why it exists

Before this class, every tool re-derived the image/CSV/QC paths it needed from
filename patterns, and the same logic lived in several places. There was no
single answer to *"which localization CSV is the one being used for analysis"*
when a source had more than one (plain `_locs`, resized `_locs_resized`, a
curated copy, …).

`CellDatasetManifest` fixes that:

- **One source of truth.** The manifest records the analyzed image, its page
  count and analyzed pages, and — per channel/page **source** — the **active
  analysis CSV**, its resized companion, and the QC file.
- **Authoritative, conventions only bootstrap.** A query first trusts a recorded
  path if the file exists; otherwise it derives the path from the naming
  convention, **records it**, and returns it. Hand-dropped files still work, and
  once recorded the manifest wins.
- **Self-healing.** Derivable facts (counts, which CSVs exist, whether a CSV has
  `CURATED_*`/`rescore` columns, QC counts) are re-measured from disk on every
  scan; provenance that cannot be re-derived (when each stage ran, which
  tool/model produced it) is preserved.

---

## On disk

Each dataset has a sidecar next to its image:

```
<base>.celldataset.json        schema "celldataset/2.0"
```

Paths inside are stored relative to the dataset folder. A scan of a folder where
nothing changed writes nothing (`updatedUtc` is the time of the last real change).

### The base of a dataset

Cell Discovery names what it writes after the image it read, suffix included
(`<x>_proj.tif` → `<x>_proj_ECM1_locs.csv`), so the base of a dataset is the stem
its localization files start with: `forCsv` is the authority. An image whose name
ends in a role suffix (`_proj`, `_resized`, `_preprocessed`) is settled by the
same three rules in `forImage` and in `discover`:

1. localization files named after the image exist → it is **the** image of the
   dataset with its own name as base (`<x>_proj`);
2. else the name without the suffix has an image of its own or localization files
   → it is that dataset's companion (base `<x>`, the projection of `<x>.tif`);
3. else a projection alone is a dataset of its own (`<x>_proj`), so its base does
   not change when detections are added. A resized image alone stays with the
   base without the suffix.

So the lab's layout, `<x>_proj.tif` beside `<x>_proj_ECM1_locs.csv` and
`<x>_proj_PV2_locs.csv`, is one dataset `<x>_proj` with two sources, and its
manifest is `<x>_proj.celldataset.json`.

> **Until 2026-11-24** only rule 2 existed. A section in the lab's layout was
> listed twice (bases `<x>` and `<x>_proj`), and Cell Discovery recorded its
> detection (tool, model, and how the detector's input was prepared) in
> `<x>.celldataset.json`, where the exports, rescoring and the lab database record
> did not look, and from where the next scan removed it. `discover` now adopts
> what such a stray manifest still holds for the same locs file
> (`adoptStrayFacts`); the stray file itself is left alone and can be deleted.

Example:

```jsonc
{
  "schema": "celldataset/2.0",
  "datasetBase": "slice42",
  "image": {
    "file": "slice42.tif",
    "pageCount": 2,
    "umPerPixel": 0.645,
    "proj": "slice42_proj.tif",
    "resized": "slice42_resized.tif",
    "analyzedPages": [1, 2]
  },
  "sources": {
    "PNN1": {
      "channel": "PNN", "page": 1,
      "activeLocs": "slice42_PNN1_locs.csv",   // the analysis file
      "coordSpace": "full",                    // 'full' | 'resized'
      "locs":        "slice42_PNN1_locs.csv",
      "locsResized": "slice42_PNN1_locs_resized.csv",
      "qc":          "slice42_PNN1_locs_QC.csv",
      "curation":    "slice42_PNN1_curation.csv",
      "stages": {
        "detection": {"done": true, "time": "...", "tool": "CellDiscovery", "model": "...", "count": 812},
        "resized":   {"done": true, "time": "..."},
        "resolve":   {"done": false},
        "rescore":   {"done": true, "time": "...", "model": "..."},
        "qc":        {"done": false},
        "curation":  {"done": true, "time": "...", "tool": "CellCurator", "total": 812,
                      "reviewed": 812, "good": 590, "bad": 222, "kept": 590, "complete": true}
      }
    }
  }
}
```

### Curation (Cell Curator)

Cell Curator keeps its own files (`<stem>_curation.csv`, a journal, and the
dataset-level `<base>.curation.json`; see the [Cell Curator guide](CellCurator.md)
and the [maintainer's reference](CellCuration-Reference.md)). The manifest holds
only a pointer and the counts:

- stage **`curation`**, alongside `detection`, `resized`, `resolve`, `rescore`
  and `qc`; `sources.<key>.curation` is the snapshot's relative path.
- `curationPath(key)` resolves the snapshot (recorded path, else the stem the
  store wrote into the curation JSON); `curationJsonPath()` is the JSON.
- `recordCuration(key, csv, counts)` records it, with `reviewed`, `good`, `bad`,
  `uncertain`, `kept`, `autoRejected`, `complete`, `tool` and `total` (active
  candidates; merged duplicates and stale rows are not cells).
- On every scan the status fields are re-derived **from the counts in the
  curation JSON** (the curation CSV is not parsed): `CurFound`, `Curated` (some
  cell reviewed, or the source complete), `CurComplete`, `CurTotal`,
  `CurReviewed`, `CurGood`, `CurBad`, `CurUncertain`, `CurKept`,
  `CurAutoRejected`, `CurationPath`, `CurationInfo`. A missing or unreadable JSON
  leaves the recorded facts untouched rather than zeroing them.
- The dataset's overall status is `Curated` when every source is complete and
  `Curating` when any source is curated.

> **Greenfield format.** Nothing reads the previous `celldataset/1.1` files; a
> non-`2.0` sidecar is treated as absent and a fresh one is built from the files
> on the next scan. There is no migration.

---

## Using it from code

```matlab
addpath('customizations')

% --- Factories -------------------------------------------------------
mf = CellDatasetManifest.forImage('D:\data\slice42.tif');   % by image
mf = CellDatasetManifest.forCsv('D:\data\slice42_PNN1_locs.csv'); % by a CSV
arr = CellDatasetManifest.discover('D:\data');              % all datasets below

% --- Authoritative file resolution (use for ALL file operations) -----
img  = mf.imagePath();             % analyzed TIFF
np   = mf.pageCount();
keys = mf.sourceKeys();            % e.g. {'PNN1','PV2'}
csv  = mf.activeLocs('PNN1');      % THE analysis CSV for a source
rcsv = mf.locsPath('PNN1','resized');
qc   = mf.qcPath('PNN1');
cur  = mf.curationPath('PNN1');    % <stem>_curation.csv (Cell Curator's snapshot)
cj   = mf.curationJsonPath();      % <base>.curation.json (shared by all sources)
img2 = mf.imageForLocs(csv);       % image matching a CSV's coord space
[ch, pg] = mf.channelPage('PNN1');

% --- Recording (the GUIs call these right after they save) -----------
key = CellDatasetManifest.keyForCsv(csv);
mf.recordDetection(key, struct('image',img,'page',pg,'locs',csv, ...
                               'tool','CellDiscovery','model','m','count',n));
mf.recordResized(key, rcsv, 'slice42_resized.tif');
mf.recordRescore(key, struct('tool','CellDiscovery','model','m'));
mf.recordCuration(key, curCsv, store.counts());   % counts plus .complete and .tool, as Cell Curator passes them
% No caller since the legacy Neighbor Resolver and QC tools were removed:
mf.recordResolve(key, struct('tool','CellNeighborResolution'));
mf.recordQc(key, qc, struct('reviewed',r,'good',g,'bad',b,'uncertain',u));
mf.setActiveLocs(key, rcsv, 'resized');   % re-point the active file
mf.save();
```

A **source** is one `(channel, page)` stream; a two-page PNN/PV TIFF has two
sources (`PNN1`, `PV2`), each with its own active analysis file. The source key
is `'<channel><page>'` (or `'default'` for an unsuffixed single source) — use
`CellDatasetManifest.keyForCsv(csvPath)` to get it for a CSV.

The configured localization-CSV suffix (default `_locs`, set in the dashboard)
is shared via `CellDatasetManifest.locsToken()`.

---

## Who calls it

| Tool | What it records / resolves |
|------|-----------------------------|
| **Cell Discovery** | `recordDetection` / `recordResized` / `recordRescore` in the manifest of the locs file it just wrote (`forCsv`) — seeds the image, analyzed pages, the active locs CSV, and provenance. |
| **Cell Curator** | `recordCuration` whenever you leave a source, complete it or close the window (the curation CSV path and its counts). It reads the detector's `locs` file, **not** `activeLocs`. |
| **Cell Dataset Manager** | `discover` for the list; **Set active locs…** calls `setActiveLocs`, **Set active image…** `setActiveImage`. |

Every write is best-effort and guarded, so a manifest problem can never break a
tool's save.
