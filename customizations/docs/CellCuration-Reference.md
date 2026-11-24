# Cell Curation — Maintainer's Reference

[← Back to the User Guide home](Home.md) · User guide: [Cell Curator](CellCurator.md)

For whoever maintains the code behind `CellCurator`: the `customizations/+curation`
and `customizations/+celldb` packages, the files they write, the tests that guard
them, and what is known to be unfinished. It is a map, not a copy of the code. The
code is the source of truth, and each section says where.

---

## 1. Overview

`CellCurator.m` (the window) holds no data rules. Every decision about a cell goes
through `curation.Store`, one per source (a source is one channel/page stream of a
section, such as `ECM1` or `PV2`). The detector's `*_locs.csv` is read-only input.
Decisions live in a snapshot CSV, an append-only journal and a shared JSON, all
keyed by a stable `CellID`, so they survive re-detection.

```
CellDatasetManager --Curate...--> CellCurator(parentDir)
                                     |
   CellDatasetManifest.discover  <---+   (which sources have detections; counts)
                                     |
                           curation.CuratorSession   one per open source (two kept)
                           |        |        |
        curation.Store     |   curation.CropCache --> curation.GalleryView   (review pages)
        (Reconciler,       |   curation.Queues, Proposals, DisplayDefaults
         Journal,          |   curation.MapView, Pairs, Regions               (map, edits)
         AtomicIO,         |
         LegacyImport,     +-- curation.AssistRunner --> ProjectIndex, Features, AssistModel,
         ChangeSet, Hash)  |                            BlindTiles, Audit       (assist, audit)
                           +-- curation.RescoreRunner --> Rescore --> score.py   (edited cells)
                           +-- curation.TrainingPanel --> Export, Trainer --> train_score.py / train.py
                           +-- celldb.recordCuration / addLamp                   (lab database)
```

Rules that hold everywhere:

- Nothing on the key path touches the disk beyond one journal append; snapshots are
  debounced; model fitting, feature computation and rescoring run off the UI thread
  and are applied between pages.
- Every user action is one `Store` transaction: one undo step, one `Changed` event,
  its journal lines written at once.
- The store never guesses. When the files do not show which cell a decision belongs
  to, it refuses (an error) or opens read-only (a warning). It never deletes or
  rebuilds a file it cannot read.
- Nothing `CellCurator` computes or writes depends on the lab database.

---

## 2. Files and schema

**Authoritative description: the header comment of
`customizations/+curation/Store.m` (FILES, COLUMN SCHEMA, SEMANTICS, RECONCILE,
LOCKING, ERRORS).** `curation.Store.schema()` returns the column table. What follows
is a summary.

### Per source (next to the detector's locs file; stem such as `SUBJ-…_proj_ECM1`)

| File | Content |
|------|---------|
| `<stem>_curation.csv` | Snapshot, one row per candidate, columns in `Store.COLUMNS` order. Written atomically on a debounce (default 2 s) and on source switch and close |
| `<stem>_curation.journal.csv` | One line per changed field per cell, each transaction framed by `#begin` / `#commit` lines (columns: `Time,Reviewer,Session,Seq,Revision,Action,CellID,Field,Old,New,Queue,PageId,DwellMs`). Also event lines (`create`, `open`, `snapshot`, `reconcile`, `legacy-import`) that replay ignores |
| `<stem>_curation.lock` | `{host, user, pid, time, session}`, created exclusively |
| `<stem>_final.csv` | Kept rows only; columns `X,Y,class,score,imgName,thr,rescore,CellID` |
| `<stem>_final.stale.csv` | A `_final.csv` retired because the source is no longer complete or the kept cells changed |
| `<stem>_curation.archived-<ts>.csv` etc. | What `Rebuild` leaves (snapshot, journal, JSON record) |

### Per dataset (in the dataset folder)

`<ManifestBase>.curation.json`, schema `cellcuration/1.0`, shared by every source of
the dataset. It holds `jsonRevision`, `nextRegionId`, `regions` (`{id, kind
"exclude"|"analysis"|"reference", scope "image"|<key>, xy, note}`) and
`sources.<key>` (`nextCellId, revision, locsFile, locsFingerprint, umPerPixel,
umSource, imageSize, legacyImported, keptPairs, sweepDone, complete, counts,
autoReject, stem, journalBytes, csvFingerprint, updated`). Every write is a locked
load-modify-write (`curation.AtomicIO.updateJson`); a JSON that cannot be read is
never overwritten.

Regions live here, not in a source, because an exclusion region with scope `image`
applies to every channel of the section.

### Per folder of sections

| Path | Content |
|------|---------|
| `.cellcuration\holdout_<kind>.csv` | The blind holdout list per channel kind (first list written wins) |
| `.cellcuration\assist_<kind>.mat` and `.json` | The saved assist model and its summary |
| `.cellcuration\audit_report_<date>.txt/.csv` (`_sections.csv`, `_bands.csv`) | A saved audit report |
| `%LOCALAPPDATA%\counting_perineuronal_nets\cache\<hash of folder>\` | Feature cache (`curation.ProjectIndex`, `assistfeat_<hash>.mat`); never inside the data tree |
| `<output folder>\.provenance\<time>_<step>_<id>.json` | Lab database record (`cellcuration-provenance/1`) |

### Snapshot columns

`CellID` (uint32, per source, never reused), `X`, `Y` (effective position, full-res
pixels), `DET_X`, `DET_Y` (detector position at the last match; NaN if added by
hand), `class`, `score`, `rescore`, `RescoreSource`, `imgName`, `thr`, `Origin`
(`detected | added | merged`), `State` (`active | merged | stale`), `MergedInto`,
`PosSource` (`det | snap | human`), `InLocs`, `DetRun`, `MatchDistUm`, `Label`
(`"" | Good | Bad | Uncertain`), `LabelSource` (`"" | human | confirmed | blind |
auto | legacy-qc | legacy-resolver`), `Reviewed`, `Flag` (`"" | later | recheck`),
`Excluded`, `ProposalP`, `ModelP`, `ModelVersion`, `AuditRole` (`"" | holdout |
reject-audit | confirm-audit | catch`), `Reviewer`, `ReviewedAt`, `Notes`.

`rescore` is the Stage-2 score of a crop centred on the cell, so it belongs to a
position. `RescoreSource` names what produced it: `"detector"` (the locs file's
value at the detector position), a scoring model's folder name, or `""` (pending,
`rescore` NaN). A move of more than 0.01 px makes a score pending.

---

## 3. Rules

### The kept rule

**Kept** = `State == "active"` and `Label == "Good"` and `Reviewed` and not
`Excluded` and `LabelSource` in `{human, confirmed, blind, legacy-qc}`.
`keptMask`, `kept()`, `counts().kept`, `counts().vanishedGood` and `exportFinal`
all use it. `Uncertain` is not kept. `auto` can only ever be `Bad`
(`setLabel(..,"Good","auto")` throws `curation:Store:autoNotBad`). A duplicate's
loser is `State = "merged"`, never `Bad`, so a merge cannot become a negative
training example.

`Excluded` is derived and kept equal to "the row's X/Y lies inside an `exclude`
region whose scope is `image` or this source's key"; the store maintains it when
rows are created or moved and when regions change, in the same transaction as the
cause.

### Reconcile

Runs on open when the locs fingerprint (size, mtime in UTC, rows) differs from the
stored one, journaled as a structural transaction. Passes, each one-to-one and
nearest first, each seeing only what is still unmatched (`curation.Reconciler.plan`):

1. exact (0.01 px) on `DET_X/Y`, every row;
2. within `TolUm` (8 µm) on `DET_X/Y`, rows a person decided or touched;
3. the same rows within `TolUm` on effective `X/Y` (added and moved cells);
4. `merged` rows within `TolUm` (a re-detected duplicate stays merged);
5. every other row (unreviewed, auto, stale) within `TolUm` on `DET_X/Y`;
6. a detection still unmatched within `TolUm` of an active reviewed row that is
   still unmatched is linked to it.

So a person's cell gets its re-detection before an unreviewed neighbour can.
Matched rows refresh `score`, `class`, `imgName`, `thr` and `rescore` (by the
position rule above). Unmatched: merged and human-touched rows unchanged; reviewed
Good stays active and kept (counted as "vanished Good"); reviewed Bad/Uncertain
retained; unreviewed and auto rows go `stale`, and rows already stale are purged
(except those with a flag, note or audit role). New detections are appended
unreviewed; one within `TolUm` of an active reviewed row that matched another
detection is reported (`nNearKept`, `nearKeptIds`) so the GUI queues it as a close
pair. Refused, nothing changed, store opens read-only: `emptyLocs` (no detections
while rows are matched to the current locs) and `reconcileMismatch` (fewer than half
the matched rows find a match). The 8 µm tolerance was chosen in the design and
checked on a re-detection of one real section; see `tStoreReconcile*`.

### Legacy import (`curation.LegacyImport`)

Once per source, on a store just created from the locs (never on one loaded from a
snapshot or with journal history; `ImportLegacy="force"` overrides, sparing rows a
person decided). Resolver rules A1–A7 (a `Merged` pair's result row becomes
`Origin merged` at the mean of its parents, parents `State merged`; `Keep A/B` losers
`merged`; appended live rows `Origin added`; an unpaired deleted row is `merged` into
a live row within `OrphanMergePx` (10 px), else `Bad` with `LabelSource
legacy-resolver` and a note; `CURATED_X/Y` differing from `X/Y` becomes a human move;
`Keep Both` pairs go to `KeptPairs`). QC rows are matched by the QC file's own X/Y
(exact, then within tolerance), never by `QCSourceRow`; Good/Bad/Uncertain become
`legacy-qc` labels; `Ignore` and custom categories become `Flag = later` with a note.
The header of `LegacyImport.m` has the full rule list.

### Locking and recovery

`open` takes `<stem>_curation.lock` with an exclusive create. A live holder (same
host: the pid runs; other host: always) makes the store read-only unless `Force`; a
dead one is taken over. The store re-checks the lock file before each snapshot write
and at most every 2 s before a journal append; when another session takes over, the
store reverts the change, turns read-only and throws `curation:Store:lockLost`.
Open-time failures that open read-only instead of writing: unreadable JSON, a
snapshot the record and journal do not identify, a journal transaction that does not
fit, a refused reconcile. A missing snapshot with history throws
`curation:Store:snapshotMissing`. Remedy for both: restore from backup, or
`Rebuild=true` (archives under timestamped names, deletes nothing; needs the lock).
**The GUI has no control for `Rebuild` or `Force`**; they are options of
`curation.Store.open` / `openCsv`.

---

## 4. Package layout

### `customizations/` (top level)

| File | Role |
|------|------|
| `CellCurator.m` | The window: layout, key and mouse handling, queues, map tasks, finish checklist, assist and rescore wiring, settings (`CellToolkit` settings under `CellCurator`). Test seams listed in its class help |
| `CellDatasetManifest.m` | Adds the `curation` stage, `curationPath`, `curationJsonPath`, `recordCuration`, `Cur*` status fields (see its doc) |
| `CellDatasetManager.m` | `Curate…` button, `Legacy:` buttons, `Review` column, `By class` overlay reads the curation snapshot first |
| `CellToolkit.m` | Adds `modelInputPage`, `modelInputFromFile`, `modelInputFactsFor`: the detector's input pipeline, shared by `CellDiscovery`, the exports and rescoring |
| `CellNeighborResolution.m`, `CellQualityControl.m` | **Legacy**, superseded, kept until parity |

### `+curation`

| Class | Role |
|-------|------|
| `Store` | Curation store of one source: files, schema, transactions, undo/redo, reconcile, locking, recovery |
| `Reconciler` | Pure position matching used by `Store.reconcile` and `LegacyImport` |
| `Journal` | The append-only change log (transactions, replay, torn-tail handling) |
| `AtomicIO` | Crash-safe writes (temp file + replace), strict JSON read, locked `updateJson` |
| `ChangeSet`, `ChangeEventData` | One transaction as a value; the `Changed` event's data |
| `LegacyImport` | One-time import of `_QC.csv` labels and Neighbor Resolver edits |
| `Hash` | Short pure-MATLAB content hash (works on thread workers) |
| `CuratorSession` | One open source: store, crop cache, history, pace log; closes and records to the manifest |
| `CropCache` | Every crop of a source, extracted once (44 µm window, 80 px, uint8, both channels) |
| `GalleryView` | A page of tiles as one image object whose `CData` is replaced; cursor and selection lines |
| `MapView` | The whole section as one image and one scatter per marker style (`setMarkerStyles`; every layer's rows line up with `Ids`, NaN where a point is in another layer); regions, reference strip, sweep fields, lasso |
| `MapMarkers` | The map's markers: colour, symbol and fill per cell state (to review, Good, Bad, Uncertain, flagged), defaults, validation of saved settings, the state-to-marker rule, legend swatches |
| `MarkerDialog` | The *Markers…* window: live preview, OK keeps (saved in `CellCurator`'s settings as `MarkerStyles`), Cancel goes back |
| `Queues` | Review and list queues cut into homogeneous pages; blind-tile interleaving |
| `Proposals` | P(Good): cold start `sigmoid(rescore - c4)` (c4 = −0.170 PNN, −0.401 PV), else `score`; the model's `ModelP` when there is one |
| `DisplayDefaults` | A source's default brightness and gamma from its cells' crops |
| `Regions` | Polygon regions, ImageJ ROI import (rect, oval, polygon, freehand, wide line as strip) |
| `Pairs` | Close-pair clusters (16.6 µm; proposal merge under 8.3 µm) |
| `Features` | Per-candidate image features for the model |
| `AssistModel` | Bagged trees, grouped cross-validation, isotonic calibration; the training-label policy |
| `AssistRunner` | The model of a folder, off the key path: reads the project, fits, predicts, chooses the holdout, builds the report |
| `ProjectIndex` | Read-only gathering of every source's curation rows and cached features |
| `BlindTiles` | Which tiles are shown blind: the holdout and the confirm audit |
| `Audit` | The report (reviewer consistency, model accuracy), sampling, binomial and DeLong helpers; also the **experimental** auto-reject functions, unused by the app |
| `Rescore` | Stage-2 scores (`score.py`) for added, moved and merged cells |
| `RescoreRunner` | Runs `Rescore` in the background and applies the scores between pages |
| `Export` | Curated labels to Stage-2, Stage-1 and observation-table training data |
| `Trainer` | Builds the training commands; runs and deploys the Stage-2 fine-tune |
| `TrainingPanel` | The Training tab |
| `UiText` | Every word the window shows (tooltips, labels, messages, key map, cheat sheet, legend, colours) |

### `+celldb` (the only code that touches `labclient`)

| Function | Role |
|----------|------|
| `Run` | One run's provenance record; writes the sidecar beside the outputs, then queues it |
| `recordCuration` | Builds and finishes the `counting_perineuronal_nets/curate` run for a completed source |
| `available`, `capturing` | Whether the client is usable here; whether this computer keeps records for the database |
| `enqueue`, `backfill` | Put a record in the client's outbox; queue records that never reached it |
| `addLamp`, `openWindow`, `statusText` | The status-bar lamp; the Database window; one sentence on the database state |
| `parseSectionName` | The lab's section-name convention (`SUBJ-ID-<n>…`) |
| `codeVersion`, `clientCandidates`, `suspend` | Git commit (`-dirty`); where to look for CarasLabDB; pause sending during a batch |
| `private/` | `absolutePath, fileSnapshot, newId, queueRecord, sha256File, timeText, writeTextAtomic` |

### Manifest integration

`CellDatasetManifest` knows `curation` as a stage, resolves `curationPath(key)`
(recorded path, else the stem the store wrote into the JSON) and
`curationJsonPath()`, records a session with `recordCuration(key, csv, counts)`,
and derives the status fields `CurFound, Curated, CurComplete, CurTotal,
CurReviewed, CurGood, CurBad, CurUncertain, CurKept, CurAutoRejected,
CurationPath, CurationInfo` from the curation JSON's counts (no CSV parsing).
`Curated` is true when something is reviewed or the source is complete;
`rollupStatus` gives `Curated` when every source is complete and `Curating` when
any is curated. `CellCurator` reads the detector's `locs` field, **not**
`activeLocs`, so **Set active locs…** does not affect it.

---

## 5. Speed budgets and the tests that enforce them

All are medians in milliseconds from the call until `drawnow` returned, on a
real-size source (two 3277 × 2355 float32 pages, 2,000 cells, 126 tiles of 80 px).
They are in tests tagged `Benchmark` (and `Slow`/`RealData` where noted), so they
run only with `-IncludeSlow`. A test fails when a budget is exceeded.

| Test | Budgets (ms) |
|------|--------------|
| `tGalleryPerf` | build 2000, compose 10, show (prefetched) 100, show (cold) 130, update one tile 30, update all 30 |
| `tMapPerf` | new source 500, update one point 50, update 150 points 50, zoom step 50, pan step 50, centre on 50, pick 1, drag frame 30 |
| `tCuratorMapPerf` | first open 2000, first map show 500, gallery↔map toggle 150, label on map 50, add 100, add with snap 250, next pair 100, next field 100 |
| `tCuratorGestures` (Benchmark) | label key 30, Enter 100, source cold 2000, source back 300 |
| `tCuratorReal` (Slow, RealData) | first open 2000, open 1000, label key 30, Enter 100, toggle 150 |
| `tCuratorAssist` (Benchmark) | key while a fit runs 30, apply predictions 50 |
| `tStoreSmoke` (Benchmark) | setLabel of 150 ids: 5 without journal, 15 with; undo/redo 15; flush 150; open an existing store 300 |
| `tStoreRescore` (Benchmark) | `setRescore` of 150 ids with journal 15 |
| `tFeatures`, `tAssistModel` (Benchmark) | features of 2,800 candidates 1,500 ms; fit 20,000 × 30 in 10 s; predict 3,000 rows 150 ms |

Measured on real sections: a label shows in about 16 ms, Enter-to-next-page about
17 ms, a source opens in about 0.5 s (1.5 s for the first of a session). A real
source has roughly 1,200–2,000 detections, 11–17 pages of 126 tiles.

How they are met: one `image` object per view and only `CData` changes; crops
cached per source and the next page prefetched; the full-section image pushed once
per source; point colours updated in place; fitting, feature computation and
rescoring off the UI thread (`backgroundPool`, thread workers).

---

## 6. Testing

**Never start MATLAB tests any other way than the runner.**

```
pwsh -File tools\Run-Tests.ps1                         # default set
pwsh -File tools\Run-Tests.ps1 tStoreSmoke 'tCurator*' # by class or wildcard; 'Class/method' for one test
pwsh -File tools\Run-Tests.ps1 -IncludeSlow            # also Slow, Python, Benchmark (and RealData)
pwsh -File tools\Run-Tests.ps1 -WithoutClient          # CELLDB_NO_CLIENT=1
pwsh -File tools\Run-Tests.ps1 tFixture -Visible       # on your desktop, to watch
```

- **Hidden desktop.** The runner creates a Win32 desktop that is never shown
  (`CreateDesktop "counting_pnn_tests"`) and starts MATLAB on it, so test windows
  never take the focus. `-Visible` runs on your desktop instead; `-Interactive`
  (implies `-Visible`) uses `-r` so a person can answer a dialog.
- **Dialogs.** Nobody can answer one on the hidden desktop. `run_all_tests` prints
  `[needs you]` lines when `uiwait`, `questdlg`, … has waited `-DialogSec` seconds
  (default 30); the runner also looks for native dialogs (`#32770`), prints an
  `ACTION NEEDED` block and stops the run.
- **Exit codes:** 0 passed, 1 failed, 2 runner or launch error, 3 a dialog waits
  for a person, 124 killed at `-TimeoutMin` (default 20).
- **Preferences.** MATLAB runs with its own preferences folder
  (`%LOCALAPPDATA%\counting_perineuronal_nets\test_prefs\<run>`), deleted after the
  run, so tests never touch your real settings.
- **Logs and screenshots:** `%LOCALAPPDATA%\counting_perineuronal_nets\test_logs\`
  (the run log, a results CSV, and `screens\` with PNGs of the real window for a
  person to look at).

### Tags

| Tag | Meaning | Default run |
|-----|---------|-------------|
| `Slow` | Takes long | left out |
| `Python` | Needs the `countpnn` environment (training smoke, exports, rescoring) | left out |
| `Benchmark` | Speed budgets and benchmarks | left out |
| `RealData` | Needs the local copy of real sections (below); skipped (not failed) when absent | left out (also `Slow`) |

### Fixtures and real data

- `tests\fixtures\makeSyntheticDataset.m` builds a synthetic two-channel dataset
  (with a re-detected variant and legacy files); `FakeRescoreJob.m` stands in for
  `score.py`.
- **Real sections.** `tCuratorReal`, `tRealSection` and `tDisplayCandidates` read
  a **local** copy (never the NAS) in
  `%LOCALAPPDATA%\counting_perineuronal_nets\real_sections\<animal>\<section>\`,
  holding `<x>_proj.tif`, `<x>_proj_ECM1_locs.csv`, `<x>_proj_PV2_locs.csv` and
  `<x>_proj_roi.roi`. Each test copies it to a temporary folder and opens only the
  copy; `tCuratorReal` checks the master is unchanged at the end.
- **`-WithoutClient`** proves nothing here needs the lab database client:
  `tCelldbClient` and the client states of `tCelldbInvariance` are skipped, the rest
  must pass.
- Python helper scripts for the training tests are in `tests\python\`.

The full suite is 515 tests and takes about 13 minutes. Do not run it while someone
else's run is in progress: one MATLAB on the hidden desktop at a time.

---

## 7. The lab database record (CarasLabDB)

Offline-first. The shared client is the `+labclient` package of a CarasLabDB
checkout (found via `CARASLABDB_DIR`, else a `CarasLabDB` folder beside this
repository; `labclient.Api.atLeast(3)` required). **Rule: nothing CellCurator
computes or writes depends on it; outputs are byte-identical with the client
absent, disabled, unreachable or connected (tested by `tCelldbInvariance`).**

On **Mark source complete**, `celldb.recordCuration(store)` (off the key path, at
the next idle step) builds one run, `counting_perineuronal_nets/curate`, writes the
provenance record `<output folder>\.provenance\<time>_curate_<id>.json`
(`cellcuration-provenance/1`) **whatever the state of the database**, and queues an
analysis event when this computer keeps records (`celldb.capturing`). No event when
nothing changed (the latest earlier record of the same source lists outputs with
the same SHA-256s), unless `Force`.

| Field | Content |
|-------|---------|
| `subject` | `SUBJ-ID-<n>` parsed from the image name (`celldb.parseSectionName`), or none |
| `inputs` | The section image (role `derived`, kind `section_image`, not hashed: 50–60 MB), the detector's locs CSV, `<image stem>_roi.roi` when it exists |
| `outputs` | `<stem>_curation.csv` and `<stem>_final.csv` (role `derived`), each with its SHA-256; `replaces_sha256` / `replaces_artifact_id` when an earlier record lists the same file with other bytes |
| `parameters` | `source_key`, `channel_kind`, `um_per_pixel`, `detector_tool/_model`, `scorer_tool/_model` (from the manifest, `""` when not recorded), `assist_model_version`, `reconcile_tolerance_um` |
| `attributes` | `app = "CellCurator"`, every field of `store.counts()`, `complete`, `reviewer`, the parsed section fields, `image_key`, the exclusion regions that apply |
| record | `run_id` (uuid, becomes the event id), `code_version` (commit, `-dirty`), host, OS user, timestamps, status |

**What waits for the server or the schema** (from the design record; none of it
exercised against a real server): counts as variables, `qc:` / `stage:` tags,
section and image records (`tissue_section`, `section_image` are planned, not
built), and a detection event from `CellDiscovery` for lineage. **Held** on the
CarasLabDB side until it is ready: subjects (the master-log migration; a record
naming an unknown subject is held, not lost) and a storage root that covers the
histology folders (registration of the image and locs files). `celldb.backfill`
queues records that never reached the outbox.

---

## 8. The retraining loop

```
curate -> Export -> (train_score.py | train.py) -> deploy a model folder -> rescore / re-detect
   ^                                                                              |
   +----------------------- better proposals, better detections -----------------+
```

### The model input image

Both trainers need the image the models actually saw: LSM-corrected (optional),
top-hat background subtracted, resized to 0.645 µm/px, normalised to 0–255. It is
never saved by Cell Discovery, so each export and each rescore regenerates it with
**one shared function**, `CellToolkit.modelInputPage` (via `modelInputFromFile`),
from the facts the manifest recorded for the source's detection
(`CellToolkit.modelInputFactsFor`). Coordinates: a cell at full-res X lies at
`X * resize` in the model input, the inverse of `CellDiscovery`'s mapping of
detector output.

**Fallback when facts were not recorded** (sections detected before they were):
`resize` is *inferred* (from the TIFF calibration, `round(um/0.645, 4)`, else the
median X_resized/X ratio of the two locs files, else 1); `bgRadius` is *assumed* 0,
`correctLSM` *assumed* false, `normalized` *assumed* true with [1 99.9] → 255
(today's default). The export report lists, per image, what was assumed or
inferred. Pass `Assume` (for example `struct('bgRadius', 20)`) to override.

### Export formats (`curation.Export`; reads through `ProjectIndex`, writes only under the export folder)

**Stage 2** (`datasets.PerineuronalNetsRankDataset`, `conf_score/data/curated.yaml`):

```
<out>/train/annotations.csv              imgName, X, Y, AV, R2, R3, R4, R5, R6, VT
<out>/train/annotations_provenance.csv   + SourceId, Section, Animal, Key, CellID, Label, LabelSource, Xfull, Yfull
<out>/train/fullFramesH5/<stem>.h5       float32 /data (H, W), the model input; imgName = <stem>.tif
<out>/validation/...                     the same, validation animals
export_report.json, export_summary.txt
```

`X`, `Y` are `round(X_full * resize)`. The seven 0/1 rater columns carry the label
on the 8-level agreement scale the shipped scorers were trained on: **Good → 7,
Uncertain → 4 (`UncertainLevel`), Bad → 0**, so shipped weights fine-tune directly
and `rescore` keeps its scale. A row is exported when active, reviewed, a person's
label source (`human, confirmed, blind, legacy-qc`), labelled, not excluded (store
flag or current regions), not audit evidence (`holdout`, `reject-audit`, `catch`),
not flagged, inside the model image. Everything else is counted per rule in the
report. The split is **by animal** (an animal's sections all go to train or all to
validation); with one animal the export stops (`curation:Export:oneAnimal`) unless
`AllowSameValidation`.

**Stage 1** (`datasets.PerineuronalNetsDataset`, `conf/experiment/curated/fasterrcnn_640.yaml`):
`train/annotations.csv` (`imgName, Y, X, class`) and `train/fullFramesH5/`.
**Only sources that are `Complete` AND `SweepDone`** are exported, because
FasterRCNN treats every unannotated pixel as background. Positives: Good (and
Uncertain by default); Bad and unreviewed are background. Painted to 0 in the image:
every `exclude` region, and a 12 µm disk around every active row that may be neither
positive nor background (audit evidence, resolver labels, flagged Good). An image is
skipped when either half has no positive.

**Observations** (`curation.Export.observations`): one CSV in the legacy QC
observation format.

### Trainer commands (`curation.Trainer`)

Stage 2, run by the Training tab in its own process (`start`; output to
`<RunDir>/curation_trainer.log`; deployed to `<repo>/<kind>_curated_<yyyyMMdd>_scoring_ordinal_regression[_n]`
with the run's `.hydra/config.yaml`, `best.pth`, logs and `curation_provenance.json`):

```
python train_score.py data=curated method=ordinal_regression
  data.train.root=<export>/train data.validation.root=<export>/validation
  data.train.neg_fraction=0 data.validation.neg_fraction=0
  model.pretrained=<repo>/<kind>_v2_scoring_ordinal_regression/best.pth
  optim.epochs=10 optim.optimizer.lr=0.0001 optim.batch_size=32
  optim.num_workers=0 seed=10 gpu=0 hydra.run.dir=<RunDir>
```

Stage 1, only built (hours to days; a person runs it):

```
python train.py experiment=curated/fasterrcnn_640 data.train.root=<export>
  data.validation.root=<export> model.pretrained=<repo>/<kind>_v2_fasterrcnn_640/best.pth
  optim.epochs=20 gpu=0 hydra.run.dir=<RunDir>
```

Deploy a Stage-1 run by copying `<RunDir>/.hydra/config.yaml` and the chosen
`best_models/best_model_metric_*.pth` to
`<repo>/<kind>_curated_<date>_fasterrcnn_640/{.hydra/config.yaml, best.pth}`.

Python-side changes this needed: `model.pretrained` loading in `train.py` and
`train_score.py` (with `weights_only=False`); `pd.concat` for `DataFrame.append`;
the two `breakpoint()` calls removed; optional `CenterLoss` import;
`CheckpointManager` accepts a dict of metric modes and falls back to a copy where
it cannot symlink (Windows); `writer.close()` before Hydra restores the working
directory; new configs `conf_score/data/curated.yaml`,
`conf/experiment/curated/fasterrcnn_640.yaml` and `model.pretrained: null` in
`conf_score/model/convnet.yaml`.

### Rescore scales

`rescore` is a score from one scorer at one position. `RescoreSource` records which.
`curation.RescoreRunner.defaultModel` picks the newest deployed curated scorer of
the channel kind, else the shipped ordinal one. A fine-tuned scorer changes the
scale, existing detections keep their old scores until rescored, and the cold-start
proposals use the **shipped** scorer's cutpoints (`curation.Proposals.cutpoint`:
−0.170 PNN, −0.401 PV) and are not valid for a retrained scale. The assist model
uses `rescore` as a feature, so mixed scales degrade it.

---

## 9. Known limitations

State these honestly to users and reviewers.

1. **Exports and the image preparation for rescoring block the window briefly.**
   The exports write while the window waits (the status bar says so); the rescore's
   page regeneration runs in MATLAB's own thread before `score.py` starts in the
   background.
2. **A missed mouse button-up** (for example the pointer released outside the
   window) is only cleared by a key press, the window losing focus, or `Esc`.
3. **A 0.7-pixel offset between hand-placed and detector coordinates.** MATLAB
   treats X as 1-based and the detector writes 0-based columns, so a clicked
   position sits about 0.7 full-resolution pixels (about 1.2 µm at 1.657 µm/px;
   about 1.8 model-input pixels) right and down of where the detector would put the
   same cell. The convention is `CellDiscovery`'s throughout (see `Export`).
4. **Nothing was tested against a real database server.** Only against the client's
   fake backend and the outbox.
5. **Stage-1 fine-tuning was not run end to end.** The command and config are built
   and a one-step check exists (`tests\python\stage1_one_step.py`); a full run takes
   hours to days.
6. **Real keyboard focus and auto-repeat could not be exercised by the automated
   tests.** `handleKey` has no repeat guard (it is the test seam); the release and
   minimum-time guard sits in the window's key-press handler and is tested through
   its own state, not through a held physical key.
7. The Assist block's AUC is out-of-fold against **all** training labels, including
   ones confirmed while a proposal was in view; only the audit report's holdout
   number is free of that.
8. No GUI for `Rebuild` or `Force`; both are `curation.Store.open` options.
9. The `catch` audit role (known non-cells shown blind) and the auto-reject
   functions in `curation.Audit` exist but the app never draws or uses them.
10. Parity gaps with the legacy tools: the QC tool's score-threshold classification,
    histogram, sorting and filtering, custom categories (imported as flags), and the
    Resolver's choice of which duplicate survives (Curator keeps the higher-scored).
11. Feature computation needs the images already read: thread workers cannot read
    TIFFs, so a labelled source that is not open gets its features in idle time.
12. The Dataset Manager's **By class** dropdown tooltip still describes QC files
    only, though the overlay reads the curation snapshot first.

---

## 10. Decisions and their reasons

- **No auto-reject.** The first design let a model reject candidates below a
  threshold, justified by blind audit tiles. An independent simulation showed a
  pooled audit cannot control losses per section (median 3%, up to 28%) or per
  experimental group (1–2% against 0.04–0.16% of cells lost between a group whose
  cells were dimmer and the controls, so it can bias a treatment comparison), and
  on a real section only 5–11% of candidates are confident non-cells, so the saving
  was small. Every candidate is now seen by a person. The model orders the review
  and proposes labels; the blind tiles measure it. The library functions remain,
  marked experimental.
- **Decisions are not stored in `*_locs.csv`.** The old QC tool matched labels by
  row position, so a re-detection silently mislabelled them, and the old Resolver
  overwrote raw `X/Y`. A separate store keyed by `CellID`, reconciled by position,
  survives re-detection (another session is changing the detector).
- **A merge is not a Bad.** A duplicate's loser is `merged`, so it can never be a
  negative example.
- **Review by exception, with guards.** One proposed label per page, one key to
  confirm. Bulk confirmation invites automation bias, so Enter needs a release and
  0.3 s on screen, and audit tiles (no proposal, explicit key) measure what bulk
  confirmation lets through.
- **Holdout and confirm-audit evidence only for accuracy figures.** Labels given
  with a proposal in view are never used to report accuracy.
- **Regions in the dataset JSON.** An exclusion region applies to every channel of
  a section.
- **Offline-first lab database.** Nothing the app writes depends on it.
- **The two legacy tools are kept, unfixed, until parity** (section 9, item 10);
  they are then to be deleted, together with the `resolve` and `qc` stages.
- **Human curation speed and rendering speed come first** (budgets in section 5),
  with a tooltip on every control (`tTooltips` fails if one lacks it).
