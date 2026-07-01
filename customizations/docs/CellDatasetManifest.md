# Cell Dataset Manifest — Reference

`CellDatasetManifest` is the toolkit's **authoritative per-dataset record**. One
instance represents one dataset — a source image (a `.tif`, possibly multi-page)
plus everything the Cell\* tools derive from it — and answers, for every file
operation, *which file is the correct one*.

It is not a GUI. The [Cell Dataset Manager](CellDatasetManager.md) dashboard and
the three working tools (Discovery, Neighbor Resolver, QC) all go through it
instead of guessing filenames from naming conventions.

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

Paths inside are stored relative to the dataset folder. Example:

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
      "stages": {
        "detection": {"done": true, "time": "...", "tool": "CellDiscovery", "model": "...", "count": 812},
        "resized":   {"done": true, "time": "..."},
        "resolve":   {"done": false},
        "rescore":   {"done": true, "time": "...", "model": "..."},
        "qc":        {"done": false}
      }
    }
  }
}
```

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
img2 = mf.imageForLocs(csv);       % image matching a CSV's coord space
[ch, pg] = mf.channelPage('PNN1');

% --- Recording (the GUIs call these right after they save) -----------
key = CellDatasetManifest.keyForCsv(csv);
mf.recordDetection(key, struct('image',img,'page',pg,'locs',csv, ...
                               'tool','CellDiscovery','model','m','count',n));
mf.recordResized(key, rcsv, 'slice42_resized.tif');
mf.recordResolve(key, struct('tool','CellNeighborResolution'));
mf.recordRescore(key, struct('tool','CellNeighborResolution','model','m'));
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
| **Cell Discovery** | `recordDetection` / `recordResized` / `recordRescore` — seeds the image, analyzed pages, the active locs CSV, and provenance. |
| **Cell Neighbor Resolver** | resolves the companion image/page via `imageForLocs` / `channelPage`; records `recordResolve` / `recordRescore`. Curation is in place, so the active pointer is unchanged. |
| **Cell Localization QC** | records `recordQc` (QC path + Good/Bad/Uncertain counts). |
| **Cell Dataset Manager** | `discover` for the dashboard; **Set active locs…** calls `setActiveLocs`. |

Every write is best-effort and guarded, so a manifest problem can never break a
tool's save.
