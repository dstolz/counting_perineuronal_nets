# TO DO

## Tasks

Instructions: Review the following tasks and implement them in the most efficient order. You may find it helpful to break down larger tasks into smaller sub-tasks or combine related tasks. After completing each task, mark it as done and update the status of the project accordingly. Clear your memory of completed tasks to maintain focus on the remaining items.

When a task is completed, mark it as done by replacing the `[ ]` with `[x]`. If a task is not applicable or cannot be completed, mark it as not applicable by replacing the `[ ]` with `[-]`. Move the completed task to the "Completed tasks" section below. Always include a brief description of the changes made in the "Completed tasks" section with a completion timestamp.

- [ ] `CellQualityControl` gui: There is something off when modifying a cell. When I select the second page ofa  file, changes are applied to the next cell in the list. Discover why this is happening and fix it.
- [ ] `CellQualityControl` gui: Add keyboard shortcuts for the following actions and update button text to reflect the shortcut: 
  - [ ] classify by score/rescore threshold
  - [ ] Plot score/rescore histogram
  - [ ] plot full image qc map
  - [ ] update coordinate by click
- [ ] `CellQualityControl` gui: reuse open plots for histogram and full image qc map instead of opening a new plot each time. If using a modifier key (`ctrl+action`), then open a new plot instead of reusing the existing one.
- [ ] `CellQualityControl` gui: Replace the "Source" dropdown with a tabbed interface to select the source file. This will allow for easier navigation between different sources and improve the user experience. The tab should encapsulate the "Current block" panel only.



## Completed tasks

- [x] Add option to tif viewer in `CellDatasetManager` gui to plot scatter points at locations by cell class.
- [x] Add option to tif viewer in `CellDatasetManager` gui to plot scatter points at locations with just a single color per page.