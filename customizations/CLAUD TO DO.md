# TO DO

## Tasks

Instructions: Review the following tasks and implement them in the most efficient order. You may find it helpful to break down larger tasks into smaller sub-tasks or combine related tasks. After completing each task, mark it as done and update the status of the project accordingly. Clear your memory of completed tasks to maintain focus on the remaining items.

When a task is completed, mark it as done by replacing the `[ ]` with `[x]`. If a task is not applicable or cannot be completed, mark it as not applicable by replacing the `[ ]` with `[-]`. Move the completed task to the "Completed tasks" section below. Always include a brief description of the changes made in the "Completed tasks" section with a completion timestamp.

## Completed tasks

- [x] Add option to tif viewer in `CellDatasetManager` gui to plot scatter points at locations by cell class.
- [x] Add option to tif viewer in `CellDatasetManager` gui to plot scatter points at locations with just a single color per page.
- [x] `CellQualityControl` gui: Fixed a cell-classification bug where, under certain filter modes (e.g. "Show unreviewed only"), classifying a cell could silently reselect a different row than the one visually highlighted, causing a subsequent action to land on "the next cell in the list". Root cause was two compounding defects in the classify-then-reselect pipeline: `classifySelectedCell` read `app.SelectedGlobalRow` *after* `applyFilter` had already reset it to `NaN` (now captures the row before calling `applyFilter`), and `selectPositionInFilteredOrder`'s same-block fast path skipped re-rendering the montage even when filtering had changed which rows belonged in that block (now compares the cached visible rows against the freshly filtered set and forces a full re-render when they differ). (2026-07-01)
- [x] `CellQualityControl` gui: Added keyboard shortcuts `t` (classify by score/rescore threshold), `h` (plot score/rescore histogram), `v` (plot full image QC map), and `r` (update coordinate by click), plus `Ctrl+h`/`Ctrl+v` to force a new plot window (see next item). Button text now shows each shortcut, e.g. "Plot score/rescore histogram... [h]". (2026-07-01)
- [x] `CellQualityControl` gui: Histogram and full-image QC map plots now reuse their existing figure window instead of opening a new one each time; holding `Ctrl` while pressing `h`/`v` opens a new window instead (button clicks always reuse, since App Designer button callbacks can't see modifier-key state). (2026-07-01)
- [x] `CellQualityControl` gui: Replaced the "Source" dropdown with a tab strip (one tab per channel/page source) that wraps only the "Current block" panel; switching tabs loads that source the same way the dropdown used to. Dataset/Datasets and Selected-detection panels are unaffected. (2026-07-01)
