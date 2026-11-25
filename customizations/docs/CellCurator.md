# Cell Curator — Reviewing and Correcting Detections

[← Back to the User Guide home](Home.md)

**Cell Curator** is where you check the cells that Cell Discovery found. You look
at a screenful of small image crops at a time, mark the few that are wrong, and
press Enter to confirm the rest. You can also add cells the detector missed, move
badly centered ones, merge duplicates and cut out damaged parts of a section. When
a channel of a section is finished, the app writes the final list of kept cells.

It replaces two older tools, the Cell Neighbor Resolver and Cell Localization
QC, which have been removed; Curator imports what they saved (see
[Coming from the old tools](#coming-from-the-old-tools)). It comes after
[Cell Discovery](CellDiscovery.md), which writes the
`*_locs.csv` files it reads, and you normally start it from the
[Cell Dataset Manager](CellDatasetManager.md).

**The app never rejects a detection without a person seeing it.** A model helps
by putting the cells in a useful order and proposing a label for each page, but
every cell on every page is on screen when you press Enter, and nothing is
removed on the model's say-so.

Contents: [Getting started](#getting-started) ·
[Reviewing a page](#reviewing-a-page) · [Audit tiles](#audit-tiles-gray-border) ·
[Order of review and the assist model](#order-of-review-and-the-assist-model) ·
[The map](#the-map) · [Finishing a source](#finishing-a-source) ·
[The audit report](#the-audit-report) ·
[Training tab](#training-tab-and-score-edited-cells) ·
[Lab database](#the-lab-database-lamp) · [Keys](#all-keys) ·
[If something looks wrong](#if-something-looks-wrong) ·
[Coming from the old tools](#coming-from-the-old-tools)

---

## Getting started

### Opening it

From the Dataset Manager, select a dataset (and, if you like, one of its source
rows) and press **Curate…**. Curator opens on the Manager's parent folder, so you
can carry on from one section to the next, and shows the dataset and source you
selected.

From MATLAB:

```matlab
addpath('customizations')
CellCurator                        % empty window: press "Open folder…"
CellCurator('D:\HISTOLOGY')        % open on a folder of sections
```

"Open folder…" lists every section below the folder that has detections. Curator
remembers the last folder, window position, display settings, the map's
[markers](#markers) and the last section and channel, and "Reopen" on the start
screen takes you back to them.

### What the window shows

The window has three columns, a bar across the top and a status bar at the
bottom.

**Top bar.** *Open folder…*, a section dropdown, one button per channel of the
section (for example `ECM1` for the WFA/PNN channel and `PV2`), a display
dropdown (*Target*, *Overlay*, *Companion*, *Side by side*), *Brightness* and
*Gamma* sliders, *Undo [Ctrl+Z]*, *Redo [Ctrl+Y]* and *Keys [?]*.

**Left column.**

- **Queues** — what you can review, each with the number of cells in it:
  *Review* (cells nobody has decided yet), *Flagged*, *Close pairs*,
  *Vanished good*, *Browse Good*, *Browse Bad*, *Browse Uncertain* and *Sweep
  for missed cells (optional)*. Below the list, "Left by band" says how many
  cells remain in each part of the Review queue.
- **Progress** — three bars: the channel you are on, the whole section (all
  channels) and the whole folder, then your pace in cells per minute and the
  time left, worked out from your last few pages.
- **Assist** — three lines about the model, see
  [below](#the-assist-block).
- **Audit report…**, **Training…** and **Score edited cells (n)** buttons.
- **Sections** — every section in the folder with the share of its cells
  reviewed; a check mark means a channel is complete. Click one to open it.

**Center.** In the gallery view, a line at the top says exactly what Enter will
do, for example:

> Middle, leaning good · P 0.79–0.85 · page 1 of 16
> Enter: mark the 77 untouched tiles Good, and 13 audit tiles (gray border) need g, b or u

Under it is the page of tiles, and under that a color legend. The *Map view
[Tab]* button at the top right switches the center to the map of the whole
section.

**Right column.** Four tabs:

- **Inspector** — the cell under the pointer (or the cursor), enlarged three
  ways (the channel under review, the other channel, and an overlay), with its
  `score`, `rescore`, P(Good), label and flag; a one-line note field (type, then
  Enter to save); and buttons *Good [g]*, *Bad [b]*, *Uncertain [u]*, *Flag [f]*,
  *Clear [x]*, *Confirm page [Enter]*, *Previous page [PgUp]*, *Next page [PgDn]*, *Next source [n]*
  and *Show on map [.]*.
- **Map** — a small locator of the section. Click a place to show it on the big
  map.
- **Audit** — the [audit report](#the-audit-report).
- **Training** — [exports and fine-tuning](#training-tab-and-score-edited-cells).

**Status bar.** The message of the moment (what you just did, or what went
wrong), then a *Database…* button and the [database lamp](#the-lab-database-lamp)
at the right end. Errors never open a dialog; they appear here.

Hover over any control for a tooltip that says what it does, its key, and, when
it is grayed out, why.

---

## Reviewing a page

### What a page is

Cells are cut into pages of crop tiles (126 on the sections we measured; the
number depends on the window size and on the tile zoom, `+` and `-`). All the cells on
one page have the same **proposed label**, Good or Bad. A real source has roughly
1,200–2,000 detections, which is about 11–17 pages.

Each tile is a crop 44 µm across. Its border tells you its state (the legend
under the gallery uses these words):

| Border | Meaning |
|--------|---------|
| Muted green or muted brown | **proposed (Enter applies it)**: you have not touched this tile; Enter will give it the page's proposed label |
| Full green | **Good** |
| Full orange | **Bad** |
| Yellow | **Uncertain** |
| Gray | **audit tile: g, b or u** — no proposal; you must decide it ([below](#audit-tiles-gray-border)) |
| Pink corner badge | **flagged for later** |
| White outline | **cursor** |
| Light-blue outline | **selected** |

### Mark the exceptions, then press Enter

You only touch the tiles that differ from the page's proposal.

| To do this | Do this |
|------------|---------|
| Make a tile the exception (the opposite of the proposal) | Left-click it. Click again to make it untouched |
| Mark a tile Uncertain | Right-click it. Right-click again to make it untouched |
| Change many tiles the same way | Hold the button and drag across them |
| Select several tiles | Shift+click; then `g`, `b`, `u`, `f` or `x` act on all of them (`Esc` clears the selection) |
| Label explicitly with the keyboard | `g` Good, `b` Bad, `u` Uncertain on the tile under the pointer, else the cursor tile |
| Move the cursor | `↑` `↓` `←` `→` |
| Clear a label and flag | `x` or Backspace |
| Flag a cell for later | `f` (press again to remove the flag) |
| Add a note | Point at the cell, type in the Inspector's note field, press Enter |

Then press **Enter** (or Space, or the *Confirm page* button). Every untouched
tile gets the proposed label, the page is saved, and the next page appears. The
status bar says what happened, for example "Marked 118 Good · page 3 of 16
confirmed".

A flagged cell leaves the review pages and waits in the *Flagged* queue; it needs
a label before the source can be completed.

### Why Enter needs a key release and a moment on screen

A key that is held down repeats about 30 times a second. If Enter simply
repeated, one long press could confirm many pages you never looked at. So, from
the keyboard:

- **Enter and Space must be released between pages.** A held key is ignored, and
  the status bar says "Enter ignored: release it first. A held Enter repeats, so
  each page needs its own press."
- **A page must have been on screen for at least 0.3 s.** Pressing Enter sooner
  is ignored with "Enter ignored: the page has been on screen for less than
  300 ms. Look at it, then press Enter again."

(From the code: the guard is on the keyboard; the *Confirm page* button is not
guarded.)

### Undo, redo and going back

- `Ctrl+Z` undoes your last action and brings the page it was made on back on
  screen; `Ctrl+Y` redoes it. One Enter, one drag, one lasso or one merge is one
  step. There are up to 1,000 steps.
- `PgDn` (or *Next page*) shows the next page without confirming the one you
  leave: nothing is labeled, and its untouched tiles stay in the queue. `PgUp`
  (or *Previous page*) goes back to it. Only Enter confirms a page, and only the
  page on screen. On the last page `PgDn` says so; when you confirm the last
  page, the pages you left behind come up again.
- `PgUp` on the first page still to review shows the pages you confirmed in this
  session. You can still change their labels: on such a page a click switches a
  cell between Good and Bad. `PgDn` or Enter take you forward again.
- The arrow keys move the cursor from tile to tile and never turn the page.
- *Browse Good*, *Browse Bad* and *Browse Uncertain* list the cells you have
  already labeled so you can check them again.

### Display keys

| Key | What it does |
|-----|--------------|
| `o` | Cycle the display: target, overlay (reviewed channel green, other channel magenta), companion, side by side |
| `c` (hold) | Show the other channel while the key is held |
| `[` `]` | Darker, brighter |
| `;` `'` | Darker, brighter mid-tones (gamma) |
| `0` | **Reset** brightness and gamma to the default of this source |
| `+` `-` | Larger tiles (fewer per page), smaller tiles (more per page) |

Each source starts with a brightness and gamma worked out from its own cells'
crops, so dim cells are visible. The keys and sliders work relative to that
default; `0` returns to it. Every tile of a page shares one contrast (never one
per tile), so brightness differences between tiles are real.

---

## Audit tiles (gray border)

A few tiles on your pages have a **gray border and no proposal**. They are audit
tiles. They exist so the app can measure two things: how reliable bulk
confirmation is, and how accurate the assist model is.

- You must decide each one with an explicit `g`, `b` or `u` (or a label button; a
  right-click is Uncertain). A left-click only puts the cursor on it. Enter never
  labels an audit tile.
- **The page waits for them.** When you press Enter, the ordinary untouched tiles
  are labeled, but a page that still holds an undecided audit tile stays on
  screen, the cursor jumps to the tile, and the status bar says how many are left.
  A source cannot be completed while audit tiles are undecided.
- The Inspector hides an audit tile's scores and P(Good) until you have decided
  it, so your answer is your own.
- There are two kinds. The **holdout** is a random sample of cells nobody has
  seen, chosen once per folder and channel kind (the smaller of 400 or 5% of the
  candidates) and never used to train the model. The **confirm audit** is about 2%
  of the tiles you confirmed by default (at least 5), shown again blind when a
  source's ordinary queue is empty.
- **Nothing about them is hidden from the saved data.** An audit tile you judge
  is labeled like any other cell (`LabelSource` is `blind`); a Good one is a kept
  cell. The cell's audit role, the label it first had, and the proposal it had are
  all recorded in the curation files, and the audit report uses exactly that
  record.

---

## Order of review and the assist model

### The order

The Review queue is cut into pages of cells that share a band of P(Good), the
proposal's probability that the cell is a real cell:

1. **Middle band first** — "Middle, leaning good" (P 0.5–0.85, default Good),
   then "Middle, leaning bad" (P 0.15–0.5, default Bad). These are the pages
   where the proposal is least certain, so you meet them while you are fresh.
2. **Likely good** (P above 0.85, default Good).
3. **Likely bad** (P below 0.15, default Bad).

Inside a band, pages are sorted by P. Leaning-good and likely-good pages run from
high P down; leaning-bad and likely-bad pages run from low P up. The page title
shows the band and the range of P on that page.

### What the assist model does and does not do

- **Before the model exists**, P comes from the Stage-2 `rescore` already in your
  `*_locs.csv` files (the "cold start"). The model takes over once the project has
  **200 labels with at least 30 of each class**, and is refitted in the
  background after every 150 new labels.
- **It reorders and proposes. It never decides.** It never labels, rejects or
  removes a cell. A refit never changes the page on screen; it changes the order
  and proposals of the pages after it.
- One model is kept per channel kind (WFA/PNN and PV), trained on your labels
  from the whole folder, with animals held out when it is cross-checked.

### The Assist block

The three lines under "Assist" on the left:

1. **Where the proposals come from.** "Proposals: rescore (cold start) · the
   model starts at 200 labels with 30 of each class; you have 404 (239 Good, 165
   Bad)", or "Proposals: model 1 · trained on 752 labels from 1 section of 1
   animal".
2. **Model accuracy.** "Model AUC 0.99 (out of fold) vs rescore alone 0.99":
   how well the model ranks cells above non-cells on labels it was not trained on
   (1 = always, 0.5 = chance), next to the same figure for the raw rescore. This
   is measured against all your labels, including ones you gave by confirming a
   proposal, so it can flatter the model; the honest figure is the holdout
   number in the [audit report](#the-audit-report).
3. **Agreement on audit tiles.** "Judged blind: 61 tiles; the proposal matched
   your decision on 72%." Only tiles you decided without a proposal count. Until
   30 are judged it reads "not enough audit tiles yet (8 of 30 judged blind)".

---

## The map

Press `Tab` or `v` (or *Map view [Tab]*) to show the whole section: one marker per
cell, its color and symbol set by the cell's state, over the section image. Your labels, zoom and page
stay where they were; `Tab` returns to the gallery.

The legend under the map: Good, Bad, Uncertain, *to review*, *flagged*,
*excluded (dim)*, *selected*, *exclusion region* and *reference strip*. By
default, cells still to review are **filled blue squares**, and labeled and
flagged cells are open circles in their label's color (the cell stays visible
inside the ring).

### Markers

*Markers…* on the map's tool bar opens a small window with one row per cell
state (to review, Good, Bad, Uncertain, flagged): a **color**, a **symbol**
(circle, square, diamond, four triangles, two stars, plus, cross, asterisk),
**Filled** (a solid marker with a thin dark edge; off: only the outline, so the
cell under it stays visible; plus, cross and asterisk have no face to fill) and a
preview. Every change shows on the map, the locator and the legend at once. **OK**
(Enter) keeps the markers and remembers them for the next session; **Cancel**
(Esc, or closing the window) goes back to the markers you had; **Defaults** puts
every row back to the defaults above (OK keeps them). Excluded cells keep their
state's marker, dimmed. The markers apply to the map only; the tiles' border
colors do not change.

The wheel zooms about the pointer, dragging pans, and *Whole section* shows
everything. In the gallery, `.` shows the cell under the pointer (else the
cursor) on the map, selected; on the map, Enter or a double-click shows the
selected cell in the gallery.

### Tools

| Tool | Key | What it does |
|------|-----|--------------|
| **Select** | `s` | Click a cell to select it (Shift+click adds); drag to pan. Click inside an exclusion region to select the region. `g` `b` `u` `f` `x` act on the selected cells |
| **Add** | `a` | Click where the detector missed a cell; a Good cell is added there. A click on an existing cell selects it instead |
| **Move** | `m` | Drag a cell to where it belongs; its tiles are cut again at the new place |
| **Lasso** | `l` | Draw around cells, then use the bar that appears |

`Esc` returns to Select from any other tool.

**Snap to center** (a checkbox in the map's tool bar): a cell you add or move
lands on the center of the stained structure nearby (the hole of a net, the body
of a PV cell), found with `snapToCellCentroid`. If it finds no structure, the
cell goes where you clicked and the status bar says so. Off: exactly where you
click.

Cells you add or move have no Stage-2 score for their new position until you
[score them](#training-tab-and-score-edited-cells).

### The lasso

After you draw around some cells, a bar offers:

| Action | Key | Effect |
|--------|-----|--------|
| Good / Bad / Uncertain | `g` `b` `u` | Label every lassoed cell (one undo step) |
| **Exclude region** | `e` | The lassoed area becomes an exclusion region |
| **Merge into one** | `j` | The lassoed cells are one cell detected several times; the highest-scored is kept, the others are marked merged into it |
| Cancel | `Esc` | Forget the lasso |

### Exclusion regions

An exclusion region marks tissue you do not want counted, such as a fold or a
damaged edge. It applies to **every channel of the section**, not only the one
on screen. Cells inside it leave the review, the counts and the final list; their
labels are kept, so deleting the region brings them back, in every channel. Click
inside a region to select it, then `Del` removes it (`Esc` keeps it). `Ctrl+Z`
undoes an added or removed region.

### The reference strip

If an ImageJ ROI file named `<image name>_roi.roi` sits next to the section
image (a rectangle, a polygon, or a wide line, which becomes a strip), it is
drawn as a **dashed outline** on the map. It is for orientation only: it does not
exclude, count or restrict anything. If the file cannot be read, the status bar
says so.

### Close pairs

The *Close pairs* queue shows kept cells that lie so close (within 16.6 µm) that
they may be one cell found twice, one pair at a time on the map. A bar offers:

| Button | Key | Effect |
|--------|-----|--------|
| Merge, keep the higher-scored cell / Keep both | Enter | The proposal: merge when the cells are under about 8 µm apart, otherwise keep both |
| Merge | `j` | One cell detected twice: keep the higher-scored one, mark the other merged |
| Keep both | `k` | Two cells; the pair is not proposed again |
| Skip, Back | `→` `←` | Decide later; previous pair |

A cell merged this way is not labeled Bad, so it never counts as a "not a
cell" example anywhere. After a re-detection, new detections right next to a cell
you already reviewed also appear here, with "merge into the reviewed cell" as the
proposal.

### The missed-cell sweep (optional)

*Sweep for missed cells* steps over the whole section in fields (600 µm wide by
default; change it in the *Field width* box) with the Add tool active. Click each
cell the detector missed, then `Space` for the next field; `Backspace` or `←`
goes back. The sweep is **optional**. It is needed only if the section will be
used to train the detector, because the detector learns that everything you did
not mark is background, so a section with unmarked cells would teach it to ignore
them. Where the sweep stopped is remembered for the session.

---

## Finishing a source

When the Review queue is empty, the center shows a **checklist**:

| Row | Meaning |
|-----|---------|
| Cells to review | Undecided cells; must be 0 |
| Audit tiles to judge | Audit tiles waiting for g, b or u; must be 0 |
| Flagged for later | Cells you flagged; each needs a label; must be 0 |
| Close pairs | Pairs still to resolve; must be 0 |
| Vanished good | Kept cells whose detection disappeared after a re-detection. Look at them; not required for completing |
| Sweep for missed cells | Optional; only for sections used to train the detector |
| Cells waiting for a score | Added or moved cells without a Stage-2 score. *Rescore now* is optional |

Most rows are buttons that take you to the cells they count. When the first four
are all 0 the button *Mark source complete [Enter]* is active. Enter on the
checklist completes the source when it can be; if audit tiles are left it shows
them; otherwise it opens the next source.

**Marking a source complete** writes `<name>_final.csv`, the final list of kept
cells, records the source as finished in the dataset manifest (the Dataset Manager then
shows it as complete, and the dataset as *Curated* when every source is), and, if the lab database is set up, a provenance record.
If the list cannot be written, the source stays incomplete and the status bar
says why.

### `_final.csv`

It holds one row per **kept cell**: `X`, `Y`, `class`, `score`, `imgName`, `thr`,
`rescore` and `CellID`. A cell is kept when it is active, labeled Good by a
person (by hand, by confirming a page, by an audit tile, or by an imported legacy
QC label), and not inside an exclusion region. Uncertain cells are not in it.
Merged-away cells and cells inside exclusion regions are not in it. `X` and `Y`
are full-resolution pixels. The detector's `*_locs.csv` is never changed.

### Editing afterward

Changing anything that changes the kept cells (a label, an added, moved or merged
cell, a region), or leaving cells to review or flagged, **un-completes** the
source. Its `_final.csv` is renamed `<name>_final.stale.csv` so it can never be
mistaken for current, and the status bar says so. Mark the source complete again
to write a new one. `Ctrl+Z` undoes the completion itself.

`n` opens the next source that still has cells to review; `Ctrl+→` and `Ctrl+←`
step through all sources.

---

## The audit report

*Audit report…* (left) builds a report on the whole folder in the background. It
appears in the **Audit** tab, one paragraph per channel kind, and *Save report*
writes it to `.cellcuration\audit_report_<date>.txt` (with `.csv` tables) in the
folder of sections. All figures are estimates from samples, and the intervals
treat tiles as independent, so they are too narrow when tiles of one section look
alike.

| What it says | What it tells you |
|--------------|-------------------|
| Candidates, reviewed, kept; decided one by one vs confirmed in bulk; to review | How far you are and how much rests on bulk confirmation |
| **Reviewer consistency**: of N tiles first confirmed by default and later shown blind, X got a different label (rate, 95% interval) | How often bulk confirmation let through something you would have decided differently when looking at it alone |
| The same split by **Bad-default pages** (cells left Bad) and **Good-default pages** (non-cells kept), and by band | Which kind of page you are less reliable on |
| "Among the tiles still labeled Bad by bulk confirmation an estimated … are cells; among those still labeled Good, an estimated … are not" | A rough count of residual errors: the rate above times the number of bulk-confirmed labels |
| "For ±2 points about … tiles judged blind are needed" | How many more audit tiles would narrow the intervals |
| **Model accuracy**: on N held-out tiles judged blind, the model ranks cells above non-cells with AUC … against the raw rescore … | How good the model really is, on tiles chosen at random, never trained on and judged without a proposal. Shown only once at least 10 of each class were judged blind |
| Mean P there against cells observed; proposal matched the blind label on … % | Whether the model's probabilities are honest |
| Reviewed per person | Who did how much |

What you **can** claim: the measured rates and AUC, with their intervals, for the
sample audited. What you **cannot** claim: that any single section or group has
that error rate; that cells the detector never proposed are covered (only the
sweep addresses those); or anything about labels given while a proposal was
visible, which are never used for accuracy figures, because a reviewer who follows
the proposal would make the model look perfect.

---

## Training tab and Score edited cells

### Score edited cells

Cells you added, moved or merged have no Stage-2 score for their position. **Score
edited cells (n)** (left) and the checklist's *Rescore now* score them in the
background with `score.py`; review goes on, and the scores are stored between
pages. It uses the newest fine-tuned scorer for that channel kind if there is
one, otherwise the shipped one, and needs the `countpnn` Python environment.
Scoring is optional (it does not block completing), but the score feeds the
proposals and the assist model, and `_final.csv` carries it.

### The Training tab

It shows what your labels can train for the channel on screen, then:

| Button | What it does |
|--------|--------------|
| **Export scorer training set…** | Asks for an empty folder and writes the Stage-2 training data (train and validation split by animal, the model's input image of each source regenerated) and a plain-text summary. The window waits while it writes |
| **Export detector training set…** | The same for the Stage-1 detector. Only sources marked **complete and swept for missed cells** are written. Exclusion regions are painted out |
| **Export observation table…** | Every reviewed cell of this channel kind in one CSV in the old QC observation format |
| **Fine-tune scorer** | Runs `train_score.py` in its own process on the last scorer export, starting from the shipped scorer; review goes on. On success a new model folder is deployed in the repository and *Score edited cells* uses it |
| **Copy detector training command** | Puts the `train.py` command for the last detector export on the clipboard and shows it. It runs for hours to days, so you start it yourself in a terminal |

The summary box lists what was exported and what was left out and why, which
preprocessing facts were recorded and which assumed, and the training command
lines.

**Warning.** A fine-tuned scorer changes the meaning of `rescore`. Cells scored
with it carry its scale, not the shipped scorer's (the files record which scorer
scored each cell). Existing detections keep their old scores until they are
rescored, and the cold-start proposals assume the shipped scorer's scale. Do not
mix the two scales in one analysis without checking which scorer produced which
value.

---

## The lab database lamp

At the right end of the status bar are a *Subject…* button, a *Database…* button
(opens the lab database window: its server, your login and what waits to be
sent) and a lamp.

*Subject…* writes to the status bar what the lab database says about the animal
the open section is of: its sex, species and project, its tags (`cohort:a`,
`pilot`) and its variables (`Age at perfusion = 92 d`). It is shown only when
you press the button, on purpose: while you decide on cells you should not see
which group the animal belongs to. The answers are the ones this computer last
read (**Check subjects** in the Dataset Manager); the button never asks the
server.

The lamp:

| Lamp | Meaning |
|------|---------|
| Database: not installed (gray) | The lab database client is not on this computer, or is too old, or is switched off. Curator works the same; a record of each completed source is kept beside its files |
| Database: off (gray) | The client is here but turned off on this computer |
| Database: connected (green) | The server answered |
| Database: offline (orange) | The server is out of reach; what you record waits here and is sent when it answers |
| Database: attention (red) | Something on this computer needs fixing; open the window |
| … "· 3 to send" / "· 2 need you" | Records waiting in the outbox, or held or failed ones that need a person |

**Nothing waits on the database.** Everything Curator computes and writes is the
same with the client absent, off, unreachable or connected. When you mark a source
complete, Curator writes a provenance record in a `.provenance` folder beside the
files (whatever the lamp says) and, if this computer keeps records for the
database, queues one event for it.

**The server is not live yet**, so records only wait. Some will stay held until
the database side is ready: a record whose subject the database does not know
(the subject comes from the `SUBJ-ID-<n>` in the section's file name), and files
under a storage root that is not mapped. A record held this way is kept, not
lost. Nothing has been tested against a real server.

---

## All keys

Generated from `curation.UiText.keymap()`. The same list is on screen under
*Keys [?]*.

### Review

| Key | What it does |
|-----|--------------|
| `g` | Label the tile Good (the tile under the pointer, else the cursor; or every selected tile). On the map: the selected cells |
| `b` | Label the tile Bad |
| `u` | Label the tile Uncertain |
| `f` | Flag the tile for later, or remove its flag |
| `x` | Clear the tile's label and flag (back to untouched) |
| `Backspace` | Same as `x` (in a sweep: the previous field) |
| `Enter` | Confirm the page: untouched tiles get the proposed label; next page. On the map: what the line above the map says |
| `Space` | Same as Enter |

### Navigation

| Key | What it does |
|-----|--------------|
| `PgUp` | Previous page (still editable). Map: previous pair or field |
| `PgDn` | Next page without confirming: untouched tiles stay in the queue. Map: skip the pair, next field |
| `←` | Move the cursor one tile left (map: previous pair or field, else pan) |
| `→` | Move the cursor one tile right (map: skip the pair, next field, else pan) |
| `↑` `↓` | Move the cursor up or down one row (map: pan) |
| `n` | Open the next source that still has cells to review |
| `Ctrl+→` | Next source in the folder (channel, then section) |
| `Ctrl+←` | Previous source in the folder |
| `Tab` | Switch between the gallery and the map of the section |
| `v` | Same as `Tab` |
| `.` | Show the pointed-at (or cursor) cell on the map, selected |

### Display

| Key | What it does |
|-----|--------------|
| `o` | Cycle the display: target, overlay, companion, side by side |
| `c` (hold) | Show the other channel while the key is held |
| `[` | Darker tiles |
| `]` | Brighter tiles |
| `;` | Darker mid-tones (gamma up) |
| `'` | Brighter mid-tones (gamma down) |
| `0` | Brightness and gamma back to the default of this source (chosen from its cells' crops) |
| `+` | Larger tiles (fewer per page); map: zoom in |
| `-` | Smaller tiles (more per page); map: zoom out |

### Map

| Key | What it does |
|-----|--------------|
| `s` | Select tool (click a cell; Shift+click adds; drag pans) |
| `a` | Add tool (click where a cell was missed) |
| `m` | Move tool (drag a cell to its place) |
| `l` | Lasso tool (draw around cells) |
| `e` | After a lasso: make the area an exclusion region |
| `j` | Merge: the lassoed cells into one, or the close pair on screen (the higher-scored cell is kept) |
| `k` | Close pairs: keep both cells (two cells) |
| `Del` | Remove the selected exclusion region |

### Other

| Key | What it does |
|-----|--------------|
| `Ctrl+Z` | Undo the last change; its page comes back on screen |
| `Ctrl+Y` | Redo the change just undone |
| `Ctrl+S` | Save now (every change is also saved as you go) |
| `?` | Show or hide the list of keys |
| `Esc` | Clear the selection; hide the list of keys. Map: cancel, back to the Select tool |

### Mouse

| On the gallery | Effect |
|----------------|--------|
| Click | Make the tile the exception; click again: untouched |
| Right-click | Uncertain; again: untouched |
| Drag | The same change on every tile you pass |
| Shift+click | Select tiles; keys then act on all of them |
| Point | Shows the cell enlarged in the Inspector |

| On the map | Effect |
|------------|--------|
| Wheel | Zoom about the pointer |
| Drag | Pan (Select and Add tools) |
| Click | Select a cell; Shift+click adds to the selection; on empty space inside an exclusion region: select the region |
| Double-click | Show the cell in the gallery |
| Add tool | Click where a cell was missed |
| Move tool | Drag a cell to its place |
| Lasso tool | Draw around cells; a bar offers label, exclude and merge |

Keys are ignored while you are typing in the note field.

---

## If something looks wrong

### The source opens read-only

The status bar says "Opened ECM1 of <section> read-only: <reason>" and the
editing controls are grayed out (their tooltips say why). Nothing is written. The
reasons:

| Reason in the status bar | What to do |
|--------------------------|------------|
| "Opened read-only: <user> on <host> (pid N) has had this source open since <time>." Another session holds it | See [below](#another-session-holds-this-source) |
| "…another process took the lock at the same moment" | Close the other window or session, then open the source again |
| The shared record `<base>.curation.json` cannot be read (the message names the file) | The file may be open in another program or still syncing: wait a moment and open again. It is never rebuilt from nothing; if it is damaged, restore it from a backup |
| "…the snapshot … matches neither the record … nor any snapshot recorded in the journal" | The snapshot was edited by hand or restored from a different copy. Restore the matching files from a backup, or start over with `Rebuild` (below) |
| "…the journal … holds a change … that does not fit the snapshot" | The same: restore the files from a backup, or `Rebuild` |
| "The new locs table has no detections, but N stored rows are matched…" | The detector's `*_locs.csv` is empty. Check the file |
| "Only N of the M stored detections matched the new locs…: a different image, page or coordinate space?" | The `*_locs.csv` is for a different image or page. Check you are pointing at the right file |

If the detector locs file is missing, the stored curation is shown without
reconciling, with a warning.

**Another session lost the lock while you worked.** If another session takes the
source over, the status bar says "Another session took this source over; it is
read-only here now." Everything you did up to then is saved; open the source again
to go on.

### Another session holds this source

Only one window at a time can edit a source; it is guarded by
`<stem>_curation.lock` next to the curation files. If the other session is a
window you forgot, close it. A lock left by a crashed MATLAB on **this**
computer is taken over automatically once that process is gone. A lock left by
another computer is always respected; if you are sure nobody has the source open
there, delete the `.lock` file (from the code; this has not been tried on the
NAS).

### "The curation snapshot … is missing"

The status bar says "Could not open ECM1 of <section>: The curation snapshot … is
missing, but … hold curation work on source ECM1…" and the previous source stays on
screen. The snapshot `<stem>_curation.csv` was deleted or moved, and the app will
not guess which decisions belong to which cell. Either **restore the file** from a
backup, or start a new, empty store with **`Rebuild`**, which renames the old
snapshot, journal and record to `…archived-<timestamp>…` (nothing is deleted).
There is no button for it; from the MATLAB Command Window:

```matlab
st = curation.Store.openCsv('D:\HISTOLOGY\animal\section_proj_ECM1_locs.csv', ...
                            struct('Rebuild', true));
st.close();
```

### After a re-detection

If the detector's `*_locs.csv` changes (you re-ran Cell Discovery, or a different
detector produced it), your decisions are **kept and re-attached by position**.
When you open the source, the status bar reports it, for example:

> Detections changed since last time: 1,190 matched, 41 new, 3 kept cells no
> longer detected (they stay kept; see Vanished good), 7 unreviewed no longer
> detected, 2 new detections right next to reviewed cells (see Close pairs).

- **Matched** — within 8 µm, one to one. Labels, flags, notes and positions you
  set stay; `score` and `rescore` are refreshed from the new file.
- **New** — arrive unreviewed.
- **Vanished good** — kept cells whose detection disappeared. They **stay kept**
  and wait in the *Vanished good* queue for you to look at.
- **No longer detected, unreviewed** — dropped from the review (and removed for
  good the next time the locs file changes).
- **Near-kept pairs** — a new detection within 8 µm of a reviewed cell that
  already matched another detection. It is appended and shown in *Close pairs*,
  proposed as "merge into the reviewed cell".

Cells you added by hand, moved by hand or merged are never dropped.

### Where the files are

Next to the detector's locs file (stem, for example, `SUBJ-…_proj_ECM1`):

| File | What it is |
|------|-----------|
| `<stem>_curation.csv` | Snapshot: one row per candidate, with your decisions |
| `<stem>_curation.journal.csv` | Append-only log of every change |
| `<stem>_curation.lock` | Present while a window has the source open |
| `<stem>_final.csv` | Kept cells, written by *Mark source complete* |
| `<stem>_final.stale.csv` | A final list that no longer matches (see above) |
| `<base>.curation.json` | Shared by all channels of the section: exclusion regions and per-source counts |
| `.provenance\*.json` | Lab database records, beside the outputs |

In the folder you opened: `.cellcuration\` (the holdout list, the saved models,
saved audit reports). Cached features go under `%LOCALAPPDATA%`, never into your
data folder.

**The detector's `*_locs.csv` is never modified by Curator.** It is read-only
input. Everything you decide lives in the files above.

### Crash safety

Every change is appended to the journal the moment you make it, and the snapshot
is written a couple of seconds after you stop (and when you switch source or
close). Files are written to a temporary name and swapped in, so a crash never
leaves a half-written file. When a source opens, any journal entries newer than
the snapshot are replayed, so a crash loses nothing. If the last journal line was
cut off by the crash, it is skipped with a warning.

---

## Coming from the old tools

The Cell Neighbor Resolver and Cell Localization QC have been removed. The first
time Curator opens a source, it **imports once** what they saved. It never
changes or deletes the old files.

- **`_QC.csv` labels** are matched to cells by the QC file's own X/Y position (not
  by row number) and become labels of source `legacy-qc`: Good, Bad and Uncertain
  as given; a Good one counts as a kept cell. QC notes are kept. *Ignore* and any
  custom category become a **flag** with a note naming the old category.
- **Neighbor Resolver edits** (`CURATED_X/Y` and the pair columns in the locs
  file) become merges, moves and added cells. **A duplicate's loser becomes
  "merged", not Bad.** A point deleted with no nearby partner becomes Bad, with a
  note saying it came from the resolver; neither merged cells nor resolver-deleted
  points are used to train a model. "Keep both" pairs are remembered.

| Old feature | Now |
|-------------|-----|
| Resolver: find close pairs | *Close pairs* queue (on the map) |
| Resolver: Keep A / Keep B / Merge | **Merge** keeps the higher-scored cell and marks the other merged. To keep the other one, move or label it as you need |
| Resolver: Keep Both | `k` / *Keep both* |
| Resolver: add or move a point | *Add* and *Move* tools, with *Snap to center* |
| Resolver: delete a point | Label it Bad, or merge it |
| Resolver: rescore | *Score edited cells* |
| QC: Good / Bad / Uncertain (`g` `b` `u`) | The same keys |
| QC: Ignore, custom categories | Flag (`f`) with a note |
| QC: notes | The note field in the Inspector |
| QC: full-image map (`v`) | The map (`Tab` or `v`) |
| QC: update a coordinate (`r`) | The *Move* tool |
| QC: observation export | *Export observation table…* |
| QC: sort, filter, score threshold (`t`), histogram (`h`) | No equivalent yet: pages are ordered by the assist model |
| Resolver and QC: *Undo* | `Ctrl+Z`, `Ctrl+Y`, with 1,000 steps |

---

[← Back to the User Guide home](Home.md) ·
Maintainers: [Cell Curation Reference](CellCuration-Reference.md)
