# Cell Neighbor Resolver — Resolving Duplicate Detections

[← Back to the User Guide home](Home.md)

The automatic detector sometimes marks the **same cell twice**, or places two
detections so close that they're really one cell. The **Cell Neighbor Resolver**
finds these close pairs and lets you decide, one pair at a time, whether to keep
one detection, keep both, or merge them into a single point. It is the
**second** tool in the workflow.

Open it from the MATLAB Command Window:

```matlab
CellNeighborResolverApp
```

---

## What it does

- Scans a folder for `*_locs.csv` files produced by
  [Cell Discovery](CellDiscovery.md).
- For a file you select, finds every pair of detections that sit within a
  pixel-distance you choose ("neighbors").
- Displays the image with the pair highlighted so you can judge them.
- Lets you resolve each pair — Keep A, Keep B, Keep Both, Merge, or Skip.
- Saves your decisions **back into the original `*_locs.csv`** (with Undo
  support), adding curated coordinate columns rather than destroying data.
- Can optionally re-grade the curated detections with a Stage-2 scoring model.

---

## Quick start

1. **Scan a folder.** Enter or **Browse** to the folder containing your
   `*_locs.csv` files, then click **Scan**. Matching files appear in the file
   table on the left.

2. **Pick a file.** Click a file in the table to load its image and detections.

3. **Set the distance and find neighbors.** Set the **distance threshold** (in
   pixels) — the maximum gap between two detections for them to count as a pair —
   then click **Find Neighbors**. The number of pairs found is shown.

4. **Resolve each pair.** Step through the pairs. For each, choose an action
   using the buttons or [keyboard shortcuts](#keyboard-shortcuts). The view
   centers on the current pair.

5. **Save.** Click **Save** (or enable **Auto-save**) to write your decisions
   back to the CSV.

---

## The window, panel by panel

### Top toolbar — scanning and settings

- **Parent / Browse / Scan** — Choose and scan the folder of localization files.
- **Resized** — Tick to scan for `*_locs_resized.csv` files (resized-image
  coordinates) instead of the standard `*_locs.csv`. Use this if you detected
  with resizing turned on in Cell Discovery.
- **Distance** (spinner) — The pixel distance threshold. Two detections closer
  than this become a neighbor pair to review. Larger values flag more pairs.
- **Find Neighbors** — Computes the pairs for the active file.
- **Auto advance** — After you resolve a pair, automatically jump to the next
  unresolved one.
- **Auto-save** — Save to disk automatically after each decision.
- **Save** — Write decisions to the CSV now.
- **Rescore…** — Run a Stage-2 scoring model over the curated points (see
  [Rescoring](#rescoring-optional)).
- **Show points** — Toggle the overlay of all detection points on the image.

### Left panel — files and pairs

- **File table** — Every scanned file, with its observation count, resolved
  neighbor count, and how many detections are still unreviewed. An **Include**
  tick controls which files batch operations (like Rescore) apply to.
- **Dataset progress** — A bar showing how much of the active file you've
  reviewed.
- **Filter** — Limit the pair list (e.g. show only unresolved pairs).
- **Pair table** — The neighbor pairs for the active file, with their status.
  Click a pair to jump to it. **Previous/Next** buttons step through them.

### Center panel — the image

- **Tissue plot** — The microscopy image with the current pair's two points
  (**A** and **B**) highlighted, plus the other detections.
- **Page spinner** — For multi-page or combined CSVs, choose which TIFF page is
  shown.
- **Pair detail label** — Identifies the current pair and its distance.

Navigate the image directly with the mouse — see
[Mouse navigation](#mouse-navigation).

---

## Resolving a pair

For each highlighted pair you choose one of:

| Action | Effect |
|--------|--------|
| **Keep A** | Keep detection A; delete B. (They were the same cell.) |
| **Keep B** | Keep detection B; delete A. |
| **Keep Both** | Both are real, separate cells — keep them. |
| **Merge** | Replace both with a single new point. After choosing Merge, **click on the image** to place the merged cell. |
| **Skip** | Leave the pair undecided for now. |

Your decisions don't erase the original X/Y. The tool records curated
coordinates (and which points were removed/merged) so downstream tools can show
either the original or the curated result. **Undo** (Ctrl+Z) reverses your last
action.

---

## Keyboard shortcuts

These work whenever a text field is **not** focused.

| Key | Action |
|-----|--------|
| `a` | Keep A (delete B) |
| `b` | Keep B (delete A) |
| `k` or `Space` | Keep Both |
| `m` | Arm **merge** — then click the image to place the merged cell |
| `s` | Skip pair |
| `Ctrl+Z` | Undo |
| `Ctrl+S` | Save |
| `Left` / `j` | Previous pair |
| `Right` / `l` | Next pair |
| `f` | Fit / reset the image view to the whole image |
| `Escape` | Cancel an armed merge |

---

## Mouse navigation

In the tissue plot:

- **Scroll wheel** — Zoom in/out, centered on the cursor.
- **Middle-drag** or **Shift-drag** — Pan the image.
- **Right-click → Reset view** — Return to the full-image view (same as `f`).

---

## Rescoring (optional)

The **Rescore…** button runs a Stage-2 scoring model over the **curated** (kept)
detections of the included file(s). In the dialog you pick:

- the **scoring model**, and
- the **compute device** (e.g. `cpu` or `cuda:0`).

Only live (kept) points are scored. The model writes a `0–1` quality estimate
into each CSV's `rescore` column, which the
[Cell Localization QC](CellLocalizationQCApp.md) tool can then use for sorting,
filtering, and threshold classification.

This requires the same Python environment as Cell Discovery (the `countpnn`
conda env by default).

---

## Output

Your decisions are saved **in place** to the same `*_locs.csv` (or
`*_locs_resized.csv`) file you loaded — adding curated coordinate columns and
the optional `rescore` column. Because edits happen in place:

- Use **Undo** freely while reviewing.
- The file only changes on **Save** (or when **Auto-save** is on).

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| **No files found on Scan** | Check the folder and that it contains `*_locs.csv` files. If you used resizing, tick **Resized**. |
| **No pairs found** | Increase the **distance** threshold, or there genuinely are no close detections. |
| **Image won't display** | The matching image/TIFF for the CSV couldn't be found next to it, or the page index is out of range. |
| **Rescore fails** | Check your Python environment (conda env `countpnn`, with project requirements). See [Cell Discovery → Python environment](CellDiscovery.md#python-environment). |
| **Buttons stopped responding after a code update** | Run `clear classes; CellNeighborResolverApp` in MATLAB. |

---

[← Cell Discovery](CellDiscovery.md) ·
[Back to home](Home.md) ·
Next: [Cell Localization QC →](CellLocalizationQCApp.md)
