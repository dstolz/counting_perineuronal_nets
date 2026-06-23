classdef CellNeighborResolverApp < handle
% CellNeighborResolverApp  GUI for reviewing and resolving nearby cell detections.
%   app = CellNeighborResolverApp() opens the GUI.  Load a *_locs.csv file,
%   set a pixel-distance threshold, click "Find Neighbors" to detect pairs,
%   then resolve each pair using the action buttons or keyboard shortcuts.
%   Results are saved back to the original CSV file in place.
%
%   Tick "Resized" in the scan toolbar to scan for *_locs_resized.csv files
%   (resized-image coordinates) instead of the standard *_locs.csv.
%
%   The "Rescore…" toolbar button runs a Stage-2 scoring model (rescore.py,
%   in the countpnn conda env) over the curated detections of the included
%   dataset(s). Pick the scoring model and device in the dialog; only live
%   (kept) points are scored and the [0-1] quality estimate is written back
%   to each CSV's "rescore" column.
%
%   Keyboard shortcuts (when a text field is not focused):
%     a         Keep A (delete B)
%     b         Keep B (delete A)
%     k / Space Keep Both
%     m         Arm merge — then click tissue plot to place merged cell
%     s         Skip pair
%     Ctrl+Z    Undo
%     Ctrl+S    Save
%     Left/j    Previous pair
%     Right/l   Next pair
%     f         Fit / reset the tissue view to the full image
%     Escape    Cancel armed merge
%
%   Mouse navigation (tissue plot):
%     Scroll wheel              Zoom in/out centred on the cursor
%     Middle-drag / Shift-drag  Pan the image
%     Right-click menu          Reset view (fit image)

    % ------------------------------------------------------------------
    properties (Constant, Access = private)
        SettingsGroup     = 'CellNeighborResolverApp'
        SettingsPrefKey   = 'Settings'
        AppVersion        = '1.0'
        MaxUndoDepth      = 200
        DEFAULT_REGEX_LOCS         = '(?i)_locs\.csv$'
        DEFAULT_REGEX_LOCS_RESIZED = '(?i)_locs_resized\.csv$'
        DEFAULT_CONDA_ENV          = 'countpnn'
        STATUS_UNRESOLVED = "Unresolved"
        STATUS_KEEP_A     = "Keep A"
        STATUS_KEEP_B     = "Keep B"
        STATUS_KEEP_BOTH  = "Keep Both"
        STATUS_MERGED     = "Merged"
        STATUS_SKIPPED    = "Skipped"
    end

    % ------------------------------------------------------------------
    properties (Access = private)
        % --- Settings & scan state ---
        Settings   struct  = struct()
        ParentDirectory string = ""

        % --- Rescoring (Stage 2) ---
        RepoRoot      string = ""    % repo root (folder containing rescore.py)
        ScoringModels cell   = {}     % discovered scoring-model run folders (best.pth, non-fasterrcnn)
        AllAbsFiles cell   = {}
        FileReviewState logical = []   % per-AllAbsFiles flag: CSV carries saved resolver annotations

        % --- Active file state ---
        ActiveCsvPath    string  = ""
        ActiveImagePath  string  = ""
        ActiveTiffInfo           = []
        ActiveImagePages struct  = struct()
        ActiveLocTable   table   = table()
        ActiveDisplayPage double = 1
        ActiveCsvPage    double = NaN     % TIFF page this CSV's detections belong to (NaN = unencoded)
        CsvSpansMultiplePages logical = false   % combined CSV referencing >1 page => allow page navigation
        Dirty            logical = false

        % --- Neighbor / pair state ---
        NeighborPairs       double = zeros(0, 3)   % [rowA rowB distance]
        PairStatus          string = strings(0, 1)
        FilteredPairIndices double = []
        SelectedPairIndex   double = NaN
        PairTableData       cell   = {}             % cached uitable data

        % --- Undo ---
        UndoStack cell = {}

        % --- Action state ---
        MergeArmed          logical = false
        DeletePointArmed    logical = false
        RelocatePointArmed  logical = false
        RelocateSelectedRow double  = NaN    % row in ActiveLocTable picked for relocation
        AddPointArmed       logical = false

        % --- UI: top-level ---
        UIFigure
        RootGrid
        TopToolbarGrid
        MainGrid
        StatusLabel

        % --- UI: toolbar row 1 (scan) ---
        ParentDirEdit
        BrowseButton
        RegexEdit
        ScanButton
        ResizedCsvCheckBox
        FileCountLabel

        % --- UI: toolbar row 2 (neighbor settings) ---
        DistanceSpinner
        FindNeighborsButton
        PairCountLabel
        AutoAdvanceCheckBox
        AutoSaveCheckBox
        SaveButton
        NextPageButton
        RescoreButton
        ShowPointsCheckBox

        % --- UI: left panel ---
        LeftPanel
        FileTable
        FileInclude         logical = []   % per-AllAbsFiles flag: include dataset in processing
        FileObsCount        double  = []   % per-AllAbsFiles total observation count
        FileNeighborCount   double  = []   % per-AllAbsFiles resolved neighbor-pair count
        FileUnreviewedCount double  = []   % per-AllAbsFiles unreviewed observation count
        ActiveFileRow       double  = NaN  % row index of the currently-active file in FileTable
        DatasetProgressLabel
        DatasetProgressTrack    % grey track panel
        DatasetProgressFill     % green fill panel, sized manually within the track
        DatasetProgressFraction double = 0   % 0..1 reviewed fraction (drives the fill width)
        TrackPixelW double = 0   % pixel width captured in SizeChangedFcn (0 = not yet laid out)
        TrackPixelH double = 0   % pixel height captured in SizeChangedFcn
        FilterDropDown
        PairProgressLabel
        PairTable
        PreviousPairButton
        NextPairButton

        % --- UI: overview (left panel, bottom) ---
        OverviewLabel
        OverviewAxes
        OverviewImageHandle = []
        OverviewRectHandle  = []

        % --- UI: center panel ---
        CenterPanel
        TiffPageSpinner
        PairDetailLabel
        TissueAxes
        TissueImageHandle   = []
        TissueAllPointsHandle = []
        TissueNeighborPointsHandle = []
        TissuePointAHandle  = []
        TissuePointBHandle  = []
        TissueContextMenu   = []

        % --- Image navigation (zoom / pan) state ---
        TissueHomeXLim      double  = []          % full-image X limits ("home")
        TissueHomeYLim      double  = []          % full-image Y limits ("home")
        PanActive           logical = false       % true while a middle-drag pan is in progress
        PanStartData        double  = [NaN NaN]   % data coord grabbed at pan start

        % --- UI: right panel ---
        RightPanel
        KeepAButton
        KeepBButton
        KeepBothButton
        MergeButton
        DeletePointButton
        RelocatePointButton
        AddPointButton
        SkipButton
        UndoButton
        TissueRelocateHandle
    end

    % ==================================================================
    methods (Access = public)

        function app = CellNeighborResolverApp()
            app.loadSettings();
            app.RepoRoot = string(CellToolkit.detectRepoRoot('rescore.py'));
            app.discoverScoringModels();
            app.buildUI();
            app.applySettingsToUI();

            if strlength(app.Settings.LastParentDirectory) > 0 && ...
                    isfolder(app.Settings.LastParentDirectory)
                app.ParentDirEdit.Value = char(app.Settings.LastParentDirectory);
                app.doScan();
            else
                app.updateStatus("Select a parent directory and press Scan.");
            end
        end

    end

    % ==================================================================
    methods (Access = private)

        % --------------------------------------------------------------
        % UI CONSTRUCTION
        % --------------------------------------------------------------

        function buildUI(app)
            pos = app.Settings.WindowPosition;
            if numel(pos) ~= 4 || any(~isfinite(pos))
                pos = [100 100 1400 820];
            end

            app.UIFigure = uifigure("Name", "Cell Neighbor Resolver", "Position", pos);
            app.UIFigure.WindowKeyPressFcn  = @(s,e) app.handleKeyPress(s, e);
            app.UIFigure.CloseRequestFcn    = @(s,e) app.handleCloseRequest(s, e);
            app.UIFigure.WindowScrollWheelFcn = @(s,e) app.onScrollWheel(s, e);

            % Root: toolbar | main | status
            app.RootGrid = uigridlayout(app.UIFigure, [3 1]);
            app.RootGrid.RowHeight    = {74, '1x', 24};
            app.RootGrid.ColumnWidth  = {'1x'};
            app.RootGrid.Padding      = [8 8 8 8];
            app.RootGrid.RowSpacing   = 6;

            app.buildToolbar();
            app.buildMainPanels();

            app.StatusLabel = uilabel(app.RootGrid, "Text", "Ready", "FontWeight", "bold");
            app.StatusLabel.Layout.Row = 3;
            app.StatusLabel.Layout.Column = 1;
            CellToolkit.setTooltip(app.StatusLabel, "Current app status: scan results, load progress, action confirmations, and error messages.");
        end

        function buildToolbar(app)
            app.TopToolbarGrid = uigridlayout(app.RootGrid, [2 9]);
            app.TopToolbarGrid.Layout.Row = 1;
            app.TopToolbarGrid.Layout.Column = 1;
            app.TopToolbarGrid.RowHeight   = {28, 28};
            app.TopToolbarGrid.ColumnWidth = {30, '2x', 70, 45, '1x', 70, '1x', 110, 100, 70, 130};
            app.TopToolbarGrid.ColumnSpacing = 5;
            app.TopToolbarGrid.Padding = [0 4 0 4];

            % Row 1: directory scan
            lbl = uilabel(app.TopToolbarGrid, "Text", "Dir", "HorizontalAlignment", "right");
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;

            app.ParentDirEdit = uieditfield(app.TopToolbarGrid, "text", ...
                "ValueChangedFcn", @(s,e) app.onParentDirEdited(s, e));
            app.ParentDirEdit.Layout.Row = 1; app.ParentDirEdit.Layout.Column = 2;
            CellToolkit.setTooltip(app.ParentDirEdit, "Parent folder to search recursively for localization CSV files. Defaults to last used folder.");

            app.BrowseButton = uibutton(app.TopToolbarGrid, "push", "Text", "Browse", ...
                "ButtonPushedFcn", @(s,e) app.chooseParentDirectory());
            app.BrowseButton.Layout.Row = 1; app.BrowseButton.Layout.Column = 3;
            CellToolkit.setTooltip(app.BrowseButton, "Open a folder picker to choose the parent directory, then scan automatically.");

            lbl2 = uilabel(app.TopToolbarGrid, "Text", "Filter", "HorizontalAlignment", "right");
            lbl2.Layout.Row = 1; lbl2.Layout.Column = 4;

            app.RegexEdit = uieditfield(app.TopToolbarGrid, "text", "Value", char(app.Settings.FileRegex));
            app.RegexEdit.Layout.Row = 1; app.RegexEdit.Layout.Column = 5;
            CellToolkit.setTooltip(app.RegexEdit, "Case-insensitive regular expression applied to file basenames during scan. Default: (?i)_locs\.csv$");

            app.ScanButton = uibutton(app.TopToolbarGrid, "push", "Text", "Scan", ...
                "ButtonPushedFcn", @(s,e) app.doScan());
            app.ScanButton.Layout.Row = 1; app.ScanButton.Layout.Column = 6;
            CellToolkit.setTooltip(app.ScanButton, "Recursively scan the parent directory for CSV files matching the filter pattern and populate the file list.");

            app.ResizedCsvCheckBox = uicheckbox(app.TopToolbarGrid, "Text", "Resized", ...
                "Value", app.Settings.UseResizedCsv, ...
                "ValueChangedFcn", @(s,e) app.onResizedCsvToggled());
            app.ResizedCsvCheckBox.Layout.Row = 1; app.ResizedCsvCheckBox.Layout.Column = 7;
            CellToolkit.setTooltip(app.ResizedCsvCheckBox, "Scan for resized-coordinate localization files (*_locs_resized.csv) instead of the standard *_locs.csv. Toggling overwrites the Filter pattern and re-scans.");

            app.FileCountLabel = uilabel(app.TopToolbarGrid, "Text", "No files scanned");
            app.FileCountLabel.Layout.Row = 1; app.FileCountLabel.Layout.Column = [8 10];
            CellToolkit.setTooltip(app.FileCountLabel, "Number of CSV files found by the most recent scan.");

            app.RescoreButton = uibutton(app.TopToolbarGrid, "push", "Text", "Rescore…", ...
                "ButtonPushedFcn", @(s,e) app.onRescoreButtonPushed());
            app.RescoreButton.Layout.Row = 1; app.RescoreButton.Layout.Column = 11;
            CellToolkit.setTooltip(app.RescoreButton, "Run a Stage-2 scoring model (in the countpnn conda env) on the curated detections of the included dataset(s), writing/updating the 'rescore' column in each CSV.");

            % Row 2: neighbor settings
            lbl3 = uilabel(app.TopToolbarGrid, "Text", "Dist (px)", "HorizontalAlignment", "right");
            lbl3.Layout.Row = 2; lbl3.Layout.Column = [1 2];

            app.DistanceSpinner = uispinner(app.TopToolbarGrid, ...
                "Limits", [1 500], "Value", app.Settings.NeighborDistance, ...
                "RoundFractionalValues", "on");
            app.DistanceSpinner.Layout.Row = 2; app.DistanceSpinner.Layout.Column = 3;
            CellToolkit.setTooltip(app.DistanceSpinner, "Maximum Euclidean distance in pixels between two detections for them to be considered neighbors. Default: 10.");

            app.FindNeighborsButton = uibutton(app.TopToolbarGrid, "push", ...
                "Text", "Find Neighbors", ...
                "ButtonPushedFcn", @(s,e) app.onFindNeighborsButtonPushed());
            app.FindNeighborsButton.Layout.Row = 2; app.FindNeighborsButton.Layout.Column = 4;
            CellToolkit.setTooltip(app.FindNeighborsButton, "Run neighbor search on the loaded CSV using the distance threshold and populate the pair list.");

            app.PairCountLabel = uilabel(app.TopToolbarGrid, "Text", "No pairs found");
            app.PairCountLabel.Layout.Row = 2; app.PairCountLabel.Layout.Column = [5 7];
            CellToolkit.setTooltip(app.PairCountLabel, "Total number of unique neighbor pairs found in the current CSV.");

            app.AutoAdvanceCheckBox = uicheckbox(app.TopToolbarGrid, "Text", "Auto-advance", ...
                "Value", app.Settings.AutoAdvance);
            app.AutoAdvanceCheckBox.Layout.Row = 2; app.AutoAdvanceCheckBox.Layout.Column = 8;
            CellToolkit.setTooltip(app.AutoAdvanceCheckBox, "Automatically move to the next unresolved pair after each resolution action. Default: on.");

            app.AutoSaveCheckBox = uicheckbox(app.TopToolbarGrid, "Text", "Auto-save", ...
                "Value", app.Settings.AutoSave);
            app.AutoSaveCheckBox.Layout.Row = 2; app.AutoSaveCheckBox.Layout.Column = 9;
            CellToolkit.setTooltip(app.AutoSaveCheckBox, "Automatically save the CSV back to the original file after each resolution action. Default: on.");

            app.SaveButton = uibutton(app.TopToolbarGrid, "push", "Text", "Save [Ctrl+S]", ...
                "ButtonPushedFcn", @(s,e) app.saveResolved());
            app.SaveButton.Layout.Row = 2; app.SaveButton.Layout.Column = 10;
            CellToolkit.setTooltip(app.SaveButton, "Save changes back to the original CSV file, overwriting it in place. Shortcut: Ctrl+S.");

            app.NextPageButton = uibutton(app.TopToolbarGrid, "push", ...
                "Text", "Next Page/File  [Tab]", ...
                "ButtonPushedFcn", @(s,e) app.advanceToNextPage());
            app.NextPageButton.Layout.Row = 2; app.NextPageButton.Layout.Column = 11;
            CellToolkit.setTooltip(app.NextPageButton, "Advance to the next TIFF page (if the current TIFF has more pages) or to the next file in the list. Shortcut: Tab.");
        end

        function buildMainPanels(app)
            app.MainGrid = uigridlayout(app.RootGrid, [1 3]);
            app.MainGrid.Layout.Row = 2;
            app.MainGrid.Layout.Column = 1;
            app.MainGrid.ColumnWidth  = {600, '1x', 375};
            app.MainGrid.RowHeight    = {'1x'};
            app.MainGrid.ColumnSpacing = 6;
            app.MainGrid.Padding = [0 0 0 0];

            app.buildLeftPanel();
            app.buildCenterPanel();
            app.buildRightPanel();
        end

        function buildLeftPanel(app)
            app.LeftPanel = uipanel(app.MainGrid, "Title", "CSV Files & Neighbor Pairs");
            app.LeftPanel.Layout.Row = 1; app.LeftPanel.Layout.Column = 1;

            g = uigridlayout(app.LeftPanel, [5 1]);
            g.RowHeight = {'0.6x', 38, 28, '0.4x', 28};
            g.ColumnWidth = {'1x'};
            g.Padding = [4 4 4 4];
            g.RowSpacing = 4;

            app.FileTable = uitable(g, ...
                "ColumnName",     {'Filename', '# Obs', 'Neighbors', 'Unreviewed', 'Include'}, ...
                "ColumnWidth",    {180, 50, 68, 68, 52}, ...
                "ColumnEditable", [false false false false true], ...
                "ColumnFormat",   {'char', 'numeric', 'numeric', 'numeric', 'logical'}, ...
                "CellSelectionCallback", @(s,e) app.onFileTableCellSelected(s, e), ...
                "CellEditCallback",      @(s,e) app.onFileTableCellEdited(s, e));
            app.FileTable.Layout.Row = 1; app.FileTable.Layout.Column = 1;
            CellToolkit.setTooltip(app.FileTable, "CSV files found by the last scan. Click a row to load that file. 'Include' checkbox marks datasets for downstream processing (default: checked).");

            % Overall progress across every scanned dataset: a label over a
            % two-segment bar (green = reviewed, grey = remaining).
            progGrid = uigridlayout(g, [2 1]);
            progGrid.Layout.Row = 2; progGrid.Layout.Column = 1;
            progGrid.RowHeight = {18, 12};
            progGrid.ColumnWidth = {'1x'};
            progGrid.RowSpacing = 2;
            progGrid.Padding = [0 2 0 2];

            app.DatasetProgressLabel = uilabel(progGrid, "Text", "Datasets reviewed: 0 / 0", ...
                "FontSize", 11);
            app.DatasetProgressLabel.Layout.Row = 1; app.DatasetProgressLabel.Layout.Column = 1;
            CellToolkit.setTooltip(app.DatasetProgressLabel, "How many scanned CSV files have been curated through this app (their saved file carries NeighborResolved annotations) out of all files found by the last scan.");

            % The grey track holds a green fill panel sized manually in pixels.
            % (uigridlayout column weights do NOT size a sub-bar reliably.)
            app.DatasetProgressTrack = uipanel(progGrid, ...
                "BorderType", "none", "BackgroundColor", [0.85 0.85 0.85], ...
                "AutoResizeChildren", "off");
            app.DatasetProgressTrack.Layout.Row = 2; app.DatasetProgressTrack.Layout.Column = 1;

            app.DatasetProgressFill = uipanel(app.DatasetProgressTrack, ...
                "BorderType", "none", "BackgroundColor", [0.2 0.7 0.3], ...
                "Units", "pixels", "Position", [1 1 1 1], "Visible", "off");

            % Re-fit the fill whenever the track resizes (window resize / layout).
            % The handler caches the pixel size so layoutDatasetProgressFill can
            % use it even when called outside of SizeChangedFcn (e.g. after scan).
            app.DatasetProgressTrack.SizeChangedFcn = @(s,e) app.onDatasetProgressTrackResized(s);

            filterRow = uigridlayout(g, [1 2]);
            filterRow.Layout.Row = 3; filterRow.Layout.Column = 1;
            filterRow.ColumnWidth = {'1x', '1x'};
            filterRow.Padding = [0 0 0 0];

            app.FilterDropDown = uidropdown(filterRow, ...
                "Items", ["Show all", "Unresolved only", "Resolved only"], ...
                "Value", char(app.Settings.FilterMode), ...
                "ValueChangedFcn", @(s,e) app.onFilterChanged());
            app.FilterDropDown.Layout.Row = 1; app.FilterDropDown.Layout.Column = 1;
            CellToolkit.setTooltip(app.FilterDropDown, "Filter which pairs are shown in the pair table. Does not change resolution status. Default: Show all.");

            app.PairProgressLabel = uilabel(filterRow, "Text", "0 resolved / 0 total", ...
                "HorizontalAlignment", "right");
            app.PairProgressLabel.Layout.Row = 1; app.PairProgressLabel.Layout.Column = 2;
            CellToolkit.setTooltip(app.PairProgressLabel, "Number of pairs that have been given any resolution status out of the total pairs found.");

            app.PairTable = uitable(g, ...
                "Data", {}, ...
                "ColumnName", {'#', 'Row A', 'Row B', 'Dist (px)', 'Status'}, ...
                "ColumnWidth", {30, 60, 60, 68, '1x'}, ...
                "ColumnEditable", false(1,5), ...
                "CellSelectionCallback", @(s,e) app.onPairTableSelected(s, e));
            app.PairTable.Layout.Row = 4; app.PairTable.Layout.Column = 1;
            CellToolkit.setTooltip(app.PairTable, "Neighbor pairs visible under the current filter. # = display index; Row A/B = source CSV row numbers; Dist = Euclidean distance in pixels; Status = current resolution. Click a row to select that pair.");

            navGrid = uigridlayout(g, [1 2]);
            navGrid.Layout.Row = 5; navGrid.Layout.Column = 1;
            navGrid.ColumnWidth = {'1x', '1x'};
            navGrid.Padding = [0 0 0 0];

            app.PreviousPairButton = uibutton(navGrid, "push", "Text", "< Prev [j/←]", ...
                "ButtonPushedFcn", @(s,e) app.navigatePairs(-1));
            app.PreviousPairButton.Layout.Row = 1; app.PreviousPairButton.Layout.Column = 1;
            CellToolkit.setTooltip(app.PreviousPairButton, "Select the previous pair in the filtered list. Shortcuts: j or left arrow.");

            app.NextPairButton = uibutton(navGrid, "push", "Text", "Next [l/→] >", ...
                "ButtonPushedFcn", @(s,e) app.navigatePairs(+1));
            app.NextPairButton.Layout.Row = 1; app.NextPairButton.Layout.Column = 2;
            CellToolkit.setTooltip(app.NextPairButton, "Select the next pair in the filtered list. Shortcuts: l or right arrow.");

        end

        function buildCenterPanel(app)
            app.CenterPanel = uipanel(app.MainGrid, "Title", "Tissue Plot");
            app.CenterPanel.Layout.Row = 1; app.CenterPanel.Layout.Column = 2;

            g = uigridlayout(app.CenterPanel, [2 1]);
            g.RowHeight = {28, '1x'};
            g.ColumnWidth = {'1x'};
            g.Padding = [4 4 4 4];
            g.RowSpacing = 4;

            topRow = uigridlayout(g, [1 5]);
            topRow.Layout.Row = 1; topRow.Layout.Column = 1;
            topRow.ColumnWidth = {38, 60, 16, '1x', 100};
            topRow.Padding = [0 0 0 0];

            lbl = uilabel(topRow, "Text", "Page", "HorizontalAlignment", "right");
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;

            app.TiffPageSpinner = uispinner(topRow, "Limits", [1 1], "Value", 1, ...
                "RoundFractionalValues", "on", "Enable", "off", ...
                "ValueChangedFcn", @(s,e) app.onTiffPageChanged());
            app.TiffPageSpinner.Layout.Row = 1; app.TiffPageSpinner.Layout.Column = 2;
            CellToolkit.setTooltip(app.TiffPageSpinner, "TIFF page (channel) shown in the tissue plot. Pinned to the page the loaded CSV's detections came from (disabled), so detections are never overlaid on the wrong channel. Editable only for a combined CSV that spans multiple pages.");

            spacer = uilabel(topRow, "Text", "");
            spacer.Layout.Row = 1; spacer.Layout.Column = 3;

            app.PairDetailLabel = uilabel(topRow, "Text", "No pair selected");
            app.PairDetailLabel.Layout.Row = 1; app.PairDetailLabel.Layout.Column = 4;
            CellToolkit.setTooltip(app.PairDetailLabel, "Row numbers, pixel coordinates, distance, and current resolution status of the selected pair.");

            app.ShowPointsCheckBox = uicheckbox(topRow, "Text", "Show points", "Value", true, ...
                "ValueChangedFcn", @(s,e) app.onShowPointsChanged());
            app.ShowPointsCheckBox.Layout.Row = 1; app.ShowPointsCheckBox.Layout.Column = 5;
            CellToolkit.setTooltip(app.ShowPointsCheckBox, "Toggle visibility of all detection markers on the tissue plot. Shortcut: p");

            app.TissueAxes = uiaxes(g);
            app.TissueAxes.Layout.Row = 2; app.TissueAxes.Layout.Column = 1;
            app.TissueAxes.XTick = [];
            app.TissueAxes.YTick = [];
            app.TissueAxes.Toolbar.Visible = "off";
            app.TissueAxes.Box = "on";
            disableDefaultInteractivity(app.TissueAxes);
            CellToolkit.setTooltip(app.TissueAxes, "Full-image view of all detections. Magenta circle = not in any pair. Orange square = in an unresolved pair. Green square = resolved/kept. Blue square = merged. Active reviewed pair: Green filled circle = point A, Blue filled square = point B. Click a point to select its pair. Scroll wheel zooms at the cursor; middle-drag (or Shift-drag) pans; press f or use the right-click menu to reset the view. Right-click for merge and freehand-ROI options.");
        end

        function buildRightPanel(app)
            app.RightPanel = uipanel(app.MainGrid, "Title", "Resolution Actions");
            app.RightPanel.Layout.Row = 1; app.RightPanel.Layout.Column = 3;

            % 2-column grid: primary resolution actions span both columns,
            % secondary actions pair up side-by-side to save vertical space.
            g = uigridlayout(app.RightPanel, [8 2]);
            g.RowHeight = {54, 54, 54, 44, 44, 90, 16, '1x'};
            g.ColumnWidth = {'1x', '1x'};
            g.Padding = [6 6 6 6];
            g.RowSpacing = 5;
            g.ColumnSpacing = 5;

            % Row 1: Keep A | Keep B (side by side, equal prominence)
            app.KeepAButton = uibutton(g, "push", ...
                "Text", "Keep A  [a]", ...
                "BackgroundColor", [0.25 0.75 0.35], ...
                "FontColor", [1 1 1], ...
                "FontWeight", "bold", ...
                "ButtonPushedFcn", @(s,e) app.doKeepA());
            app.KeepAButton.Layout.Row = 1; app.KeepAButton.Layout.Column = 1;
            CellToolkit.setTooltip(app.KeepAButton, "Keep detection A, delete B. Shortcut: a");

            app.KeepBButton = uibutton(g, "push", ...
                "Text", "Keep B  [b]", ...
                "BackgroundColor", [0.2 0.55 0.85], ...
                "FontColor", [1 1 1], ...
                "FontWeight", "bold", ...
                "ButtonPushedFcn", @(s,e) app.doKeepB());
            app.KeepBButton.Layout.Row = 1; app.KeepBButton.Layout.Column = 2;
            CellToolkit.setTooltip(app.KeepBButton, "Keep detection B, delete A. Shortcut: b");

            % Row 2: Keep Both (full width)
            app.KeepBothButton = uibutton(g, "push", ...
                "Text", "Keep Both  [k / Space]", ...
                "BackgroundColor", [0.5 0.5 0.5], ...
                "FontColor", [1 1 1], ...
                "FontWeight", "bold", ...
                "ButtonPushedFcn", @(s,e) app.doKeepBoth());
            app.KeepBothButton.Layout.Row = 2; app.KeepBothButton.Layout.Column = [1 2];
            CellToolkit.setTooltip(app.KeepBothButton, "Keep both detections, mark pair resolved. Shortcut: k or Space");

            % Row 3: Merge | Skip
            app.MergeButton = uibutton(g, "push", ...
                "Text", "Merge  [m]", ...
                "ButtonPushedFcn", @(s,e) app.armMerge());
            app.MergeButton.Layout.Row = 3; app.MergeButton.Layout.Column = 1;
            CellToolkit.setTooltip(app.MergeButton, "Delete both; click tissue plot to place merged cell at new location. Shortcut: m");

            app.SkipButton = uibutton(g, "push", ...
                "Text", "Skip  [s]", ...
                "ButtonPushedFcn", @(s,e) app.doSkip());
            app.SkipButton.Layout.Row = 3; app.SkipButton.Layout.Column = 2;
            CellToolkit.setTooltip(app.SkipButton, "Defer this pair for later. Shortcut: s");

            % Row 4: Delete Point | Relocate Point
            app.DeletePointButton = uibutton(g, "push", ...
                "Text", "Delete  [d]", ...
                "ButtonPushedFcn", @(s,e) app.armDeletePoint());
            app.DeletePointButton.Layout.Row = 4; app.DeletePointButton.Layout.Column = 1;
            CellToolkit.setTooltip(app.DeletePointButton, "Arm point-deletion mode, then click any detection on the tissue plot to delete it. Affects all pairs containing that point. Shortcut: d. Press Esc to cancel.");

            app.RelocatePointButton = uibutton(g, "push", ...
                "Text", "Relocate  [r]", ...
                "ButtonPushedFcn", @(s,e) app.armRelocatePoint());
            app.RelocatePointButton.Layout.Row = 4; app.RelocatePointButton.Layout.Column = 2;
            CellToolkit.setTooltip(app.RelocatePointButton, "Arm relocation mode: first click selects a detection (highlighted in yellow), second click moves it to the new position. Undoable. Shortcut: r. Press Esc to cancel.");

            % Row 5: Add Point | Undo
            app.AddPointButton = uibutton(g, "push", ...
                "Text", "Add Point  [n]", ...
                "ButtonPushedFcn", @(s,e) app.armAddPoint());
            app.AddPointButton.Layout.Row = 5; app.AddPointButton.Layout.Column = 1;
            CellToolkit.setTooltip(app.AddPointButton, "Arm add-point mode, then click anywhere on the tissue plot to insert a new detection. The point inherits column values from the nearest existing row. Undoable. Shortcut: n. Press Esc to cancel.");

            app.UndoButton = uibutton(g, "push", ...
                "Text", "Undo  [Ctrl+Z]", ...
                "ButtonPushedFcn", @(s,e) app.undoLast());
            app.UndoButton.Layout.Row = 5; app.UndoButton.Layout.Column = 2;
            CellToolkit.setTooltip(app.UndoButton, "Undo the last resolution action. Shortcut: Ctrl+Z");

            % Row 6: pair detail label (fixed height, spans both columns)
            app.PairDetailLabel = uilabel(g, "Text", "No pair selected", ...
                "WordWrap", "on", "VerticalAlignment", "top");
            app.PairDetailLabel.Layout.Row = 6; app.PairDetailLabel.Layout.Column = [1 2];
            CellToolkit.setTooltip(app.PairDetailLabel, "Pair identifier, pixel distance, X/Y coordinates of both detections, and current resolution status.");

            % Row 7-8: Overview thumbnail (moved here from left panel)
            app.OverviewLabel = uilabel(g, "Text", "Overview (click to navigate)", ...
                "FontSize", 11, "FontColor", [0.4 0.4 0.4]);
            app.OverviewLabel.Layout.Row = 7; app.OverviewLabel.Layout.Column = [1 2];

            app.OverviewAxes = uiaxes(g);
            app.OverviewAxes.Layout.Row = 8; app.OverviewAxes.Layout.Column = [1 2];
            app.OverviewAxes.XTick = [];
            app.OverviewAxes.YTick = [];
            app.OverviewAxes.Toolbar.Visible = "off";
            app.OverviewAxes.Box = "on";
            disableDefaultInteractivity(app.OverviewAxes);
            CellToolkit.setTooltip(app.OverviewAxes, "Whole-page overview. The red rectangle shows the region visible in the center tissue plot and tracks zoom/pan. Click anywhere to recenter the tissue plot on that spot.");
        end

        % --------------------------------------------------------------
        % SETTINGS
        % --------------------------------------------------------------

        function defaults = defaultSettings(app)
            defaults.SettingsVersion     = 1;
            defaults.SettingsSavedAt     = 0;
            defaults.LastParentDirectory = "";
            defaults.FileRegex           = app.DEFAULT_REGEX_LOCS;
            defaults.UseResizedCsv       = false;
            defaults.NeighborDistance    = 10;
            defaults.TiffPageIndex       = 1;
            defaults.AutoAdvance         = true;
            defaults.AutoSave            = true;
            defaults.FilterMode          = "Show all";
            defaults.WindowPosition      = [100 100 1400 820];
            defaults.LastActiveCsvPath   = "";

            % --- Rescoring (Stage 2) ---
            defaults.CondaExe            = string(CellToolkit.detectConda());
            defaults.CondaEnv            = string(app.DEFAULT_CONDA_ENV);
            defaults.PythonExe           = "python";
            defaults.RescoreDevice       = "cpu";
            defaults.RescoreBatchSize    = 1;
            defaults.RescoreScope        = "Included files";
            defaults.LastScoringModel    = "";
        end

        function loadSettings(app)
            app.Settings = CellToolkit.loadSettingsStruct(app.SettingsGroup, ...
                app.SettingsPrefKey, app.defaultSettings(), app.settingsMatPath());
        end

        function saveSettings(app)
            app.readSettingsFromUI();
            app.Settings.SettingsSavedAt = posixtime(datetime('now'));
            CellToolkit.saveSettingsStruct(app.SettingsGroup, ...
                app.SettingsPrefKey, app.Settings, app.settingsMatPath());
        end

        function readSettingsFromUI(app)
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                app.Settings.WindowPosition = app.UIFigure.Position;
            end
            if ~isempty(app.ParentDirEdit) && isvalid(app.ParentDirEdit)
                app.Settings.LastParentDirectory = string(app.ParentDirEdit.Value);
            end
            if ~isempty(app.RegexEdit) && isvalid(app.RegexEdit)
                app.Settings.FileRegex = string(app.RegexEdit.Value);
            end
            if ~isempty(app.ResizedCsvCheckBox) && isvalid(app.ResizedCsvCheckBox)
                app.Settings.UseResizedCsv = app.ResizedCsvCheckBox.Value;
            end
            if ~isempty(app.DistanceSpinner) && isvalid(app.DistanceSpinner)
                app.Settings.NeighborDistance = app.DistanceSpinner.Value;
            end
            if ~isempty(app.AutoAdvanceCheckBox) && isvalid(app.AutoAdvanceCheckBox)
                app.Settings.AutoAdvance = app.AutoAdvanceCheckBox.Value;
            end
            if ~isempty(app.AutoSaveCheckBox) && isvalid(app.AutoSaveCheckBox)
                app.Settings.AutoSave = app.AutoSaveCheckBox.Value;
            end
            if ~isempty(app.FilterDropDown) && isvalid(app.FilterDropDown)
                app.Settings.FilterMode = string(app.FilterDropDown.Value);
            end
            if ~isempty(app.TiffPageSpinner) && isvalid(app.TiffPageSpinner)
                app.Settings.TiffPageIndex = app.TiffPageSpinner.Value;
            end
        end

        function applySettingsToUI(app)
            if strlength(app.Settings.LastParentDirectory) > 0
                app.ParentDirEdit.Value = char(app.Settings.LastParentDirectory);
            end
            app.RegexEdit.Value = char(app.Settings.FileRegex);
            app.ResizedCsvCheckBox.Value = app.Settings.UseResizedCsv;
            app.DistanceSpinner.Value = app.Settings.NeighborDistance;
            app.AutoAdvanceCheckBox.Value = app.Settings.AutoAdvance;
            app.AutoSaveCheckBox.Value = app.Settings.AutoSave;
            CellToolkit.setDropDownValue(app.FilterDropDown, app.Settings.FilterMode);
        end

        function p = settingsMatPath(~)
            p = fullfile(prefdir, 'CellNeighborResolverApp_Settings.mat');
        end

        % --------------------------------------------------------------
        % FILE SCAN
        % --------------------------------------------------------------

        function chooseParentDirectory(app)
            startDir = char(app.ParentDirectory);
            if strlength(startDir) == 0 || ~isfolder(startDir)
                startDir = char(pwd);
            end
            selected = uigetdir(startDir, 'Select parent directory containing CSV files');
            if isequal(selected, 0)
                return
            end
            app.ParentDirectory = string(selected);
            app.ParentDirEdit.Value = char(app.ParentDirectory);
            app.Settings.LastParentDirectory = app.ParentDirectory;
            app.saveSettings();
            app.doScan();
        end

        function onParentDirEdited(app, src, ~)
            app.ParentDirectory = string(strtrim(src.Value));
            app.Settings.LastParentDirectory = app.ParentDirectory;
        end

        function onResizedCsvToggled(app)
            % Switch the scan filter between standard and resized CSVs, then
            % re-scan. The Filter pattern stays editable for power users.
            if app.ResizedCsvCheckBox.Value
                app.RegexEdit.Value = char(app.DEFAULT_REGEX_LOCS_RESIZED);
            else
                app.RegexEdit.Value = char(app.DEFAULT_REGEX_LOCS);
            end
            app.saveSettings();
            app.doScan();
        end

        function doScan(app)
            parentDir = string(strtrim(app.ParentDirEdit.Value));
            if strlength(parentDir) == 0 || ~isfolder(parentDir)
                app.updateStatus("Parent directory does not exist.");
                return
            end
            app.ParentDirectory = parentDir;
            app.Settings.LastParentDirectory = parentDir;

            pattern = char(strtrim(app.RegexEdit.Value));
            try
                matched = CellToolkit.scanFiles(char(parentDir), pattern);
            catch scanErr
                app.updateStatus("Scan failed while listing files: " + string(scanErr.message));
                return
            end

            app.AllAbsFiles = matched;
            n = numel(matched);

            if n == 0
                app.FileReviewState     = false(0, 1);
                app.FileObsCount        = zeros(0, 1);
                app.FileNeighborCount   = zeros(0, 1);
                app.FileUnreviewedCount = zeros(0, 1);
                app.FileInclude         = true(0, 1);
                app.ActiveFileRow       = NaN;
                app.FileTable.Data = {};
                app.FileCountLabel.Text = 'No files found';
                app.FileCountLabel.FontColor = [0.8 0.2 0.2];
                app.updateDatasetProgress();
                app.updateStatus("No CSV files matched the filter pattern.");
                return
            end

            % Classify each file: review state, obs count, unreviewed count.
            app.analyzeFileReviewStates();
            app.ActiveFileRow = NaN;
            app.refreshFileTable();
            app.FileCountLabel.Text = sprintf('%d file(s) found', n);
            app.FileCountLabel.FontColor = [0.1 0.5 0.1];
            app.updateDatasetProgress();
            app.updateStatus(sprintf('Scan complete: %d file(s) found, %d already reviewed.', ...
                n, sum(app.FileReviewState)));

            % Restore last active file. Guard the load so a problem opening the
            % previously-active file can never abort the scan (the file list is
            % already populated above and must stay usable).
            if strlength(app.Settings.LastActiveCsvPath) > 0
                for k = 1:n
                    if strcmp(matched{k}, char(app.Settings.LastActiveCsvPath))
                        app.selectFileTableRow(k);
                        try
                            app.loadCsvFile(string(matched{k}));
                        catch loadErr
                            app.updateStatus("Could not restore last file: " + ...
                                string(loadErr.message));
                        end
                        return
                    end
                end
            end
        end

        function onFileTableCellSelected(app, ~, event)
            if isempty(event.Indices), return; end
            row = event.Indices(1, 1);
            if row < 1 || row > numel(app.AllAbsFiles), return; end
            if ~isnan(app.ActiveFileRow) && row == app.ActiveFileRow, return; end
            app.selectFileTableRow(row);
            app.loadCsvFile(string(app.AllAbsFiles{row}));
        end

        function onFileTableCellEdited(app, ~, event)
            if isempty(event.Indices), return; end
            row = event.Indices(1);
            col = event.Indices(2);
            if col == 5 && row >= 1 && row <= numel(app.FileInclude)
                app.FileInclude(row) = logical(event.NewData);
            end
        end

        % --------------------------------------------------------------
        % DATASET REVIEW PROGRESS
        % --------------------------------------------------------------

        function analyzeFileReviewStates(app)
            n = numel(app.AllAbsFiles);
            app.FileReviewState     = false(n, 1);
            app.FileObsCount        = zeros(n, 1);
            app.FileNeighborCount   = zeros(n, 1);
            app.FileUnreviewedCount = zeros(n, 1);
            app.FileInclude         = true(n, 1);
            for k = 1:n
                [app.FileReviewState(k), app.FileObsCount(k), app.FileUnreviewedCount(k), app.FileNeighborCount(k)] = ...
                    app.analyzeOneFile(app.AllAbsFiles{k});
            end
        end

        function [hasReview, nObs, nUnreviewed, nNeighbors] = analyzeOneFile(~, csvPath)
            % Read CSV header + rows cheaply to determine review state and counts.
            % nNeighbors  = distinct non-empty NeighborPairID values (all pairs).
            % nUnreviewed = distinct NeighborPairIDs where NeighborResolved is not
            %               true (skipped / unresolved pairs).
            hasReview = false; nObs = 0; nUnreviewed = 0; nNeighbors = 0;
            fid = fopen(char(csvPath), 'r');
            if fid < 0, return; end
            closer = onCleanup(@() fclose(fid));
            headerLine = fgetl(fid);
            if ~ischar(headerLine), return; end
            hasReview = contains(headerLine, 'NeighborResolved');
            headers = regexp(headerLine, ',', 'split');
            reviewedColIdx = find(strcmpi(strtrim(headers), 'NeighborResolved'), 1);
            pairIdColIdx   = find(strcmpi(strtrim(headers), 'NeighborPairID'),   1);
            pairIdsAll   = {};
            pairIdsUnrev = {};
            while true
                line = fgetl(fid);
                if ~ischar(line), break; end
                if isempty(strtrim(line)), continue; end
                nObs = nObs + 1;
                if isempty(pairIdColIdx), continue; end
                fields = regexp(line, ',', 'split');
                if pairIdColIdx > numel(fields), continue; end
                pid = strtrim(fields{pairIdColIdx});
                if isempty(pid), continue; end
                pairIdsAll{end+1} = pid; %#ok<AGROW>
                isResolved = ~isempty(reviewedColIdx) && ...
                             reviewedColIdx <= numel(fields) && ...
                             (strcmpi(strtrim(fields{reviewedColIdx}), 'true') || ...
                              strcmp(strtrim(fields{reviewedColIdx}), '1'));
                if ~isResolved
                    pairIdsUnrev{end+1} = pid; %#ok<AGROW>
                end
            end
            nNeighbors  = numel(unique(pairIdsAll));
            nUnreviewed = numel(unique(pairIdsUnrev));
        end

        function refreshFileTable(app)
            if isempty(app.AllAbsFiles)
                if ~isempty(app.FileTable) && isvalid(app.FileTable)
                    app.FileTable.Data = {};
                end
                return
            end
            n = numel(app.AllAbsFiles);
            data = cell(n, 5);
            for k = 1:n
                [~, fname, fext] = fileparts(app.AllAbsFiles{k});
                data{k, 1} = [fname fext];
                data{k, 2} = app.FileObsCount(k);
                data{k, 3} = app.FileNeighborCount(k);
                data{k, 4} = app.FileUnreviewedCount(k);
                data{k, 5} = app.FileInclude(k);
            end
            app.FileTable.Data = data;
            if ~isnan(app.ActiveFileRow) && app.ActiveFileRow >= 1 && app.ActiveFileRow <= n
                app.FileTable.Selection = [app.ActiveFileRow, 1];
            end
        end

        function selectFileTableRow(app, idx)
            app.ActiveFileRow = idx;
            if ~isempty(app.FileTable) && isvalid(app.FileTable) && ...
                    idx >= 1 && idx <= numel(app.AllAbsFiles)
                app.FileTable.Selection = [idx, 1];
            end
        end

        function updateDatasetProgress(app)
            n = numel(app.AllAbsFiles);
            nReviewed = sum(app.FileReviewState);
            if n == 0
                app.DatasetProgressLabel.Text = 'Datasets reviewed: 0 / 0';
                app.DatasetProgressFraction = 0;
            else
                app.DatasetProgressFraction = nReviewed / n;
                app.DatasetProgressLabel.Text = sprintf( ...
                    'Datasets reviewed: %d / %d  (%.0f%%)', nReviewed, n, ...
                    100 * app.DatasetProgressFraction);
            end
            app.layoutDatasetProgressFill();
        end

        function onDatasetProgressTrackResized(app, src)
            % Cache the track's rendered pixel size and update the fill.
            % getpixelposition is only reliable when called here (from SizeChangedFcn).
            pp = getpixelposition(src, false);
            app.TrackPixelW = pp(3);
            app.TrackPixelH = pp(4);
            app.layoutDatasetProgressFill();
        end

        function layoutDatasetProgressFill(app)
            % Size the green fill panel to the reviewed fraction of the track,
            % in pixels. Uses dimensions cached by onDatasetProgressTrackResized.
            if isempty(app.DatasetProgressFill) || ~isvalid(app.DatasetProgressFill)
                return
            end
            w = app.TrackPixelW;
            h = app.TrackPixelH;
            if w <= 0 || h <= 0
                return  % layout not yet rendered; SizeChangedFcn will call us again
            end
            frac = max(0, min(1, app.DatasetProgressFraction));
            fillW = round(w * frac);
            if fillW <= 0
                app.DatasetProgressFill.Visible = 'off';
            else
                app.DatasetProgressFill.Position = [1 1 fillW h];
                app.DatasetProgressFill.Visible = 'on';
            end
        end

        function idx = activeFileIndex(app)
            idx = 0;
            for k = 1:numel(app.AllAbsFiles)
                if strcmp(app.AllAbsFiles{k}, char(app.ActiveCsvPath))
                    idx = k;
                    return
                end
            end
        end

        function markActiveFileReviewed(app)
            % Once the active file has been saved it carries resolver
            % annotations; refresh the table row and progress bar.
            idx = app.activeFileIndex();
            if idx == 0, return; end
            if numel(app.FileReviewState) >= idx
                app.FileReviewState(idx) = true;
            end
            if idx <= numel(app.AllAbsFiles)
                [~, app.FileObsCount(idx), app.FileUnreviewedCount(idx), app.FileNeighborCount(idx)] = ...
                    app.analyzeOneFile(app.AllAbsFiles{idx});
            end
            app.refreshFileTable();
            app.updateDatasetProgress();
        end

        % --------------------------------------------------------------
        % CSV LOADING
        % --------------------------------------------------------------

        function loadCsvFile(app, csvPath)
            app.saveIfDirty();

            % Reset state
            app.ActiveCsvPath = csvPath;
            app.ActiveImagePath = "";
            app.ActiveTiffInfo = [];
            app.ActiveImagePages = struct();
            app.ActiveLocTable = table();
            app.ActiveDisplayPage = 1;
            app.ActiveCsvPage = NaN;
            app.CsvSpansMultiplePages = false;
            app.NeighborPairs = zeros(0, 3);
            app.PairStatus = strings(0, 1);
            app.FilteredPairIndices = [];
            app.SelectedPairIndex = NaN;
            app.PairTableData = {};
            app.UndoStack = {};
            app.Dirty = false;
            app.cancelMerge();

            % Clear tissue plot
            cla(app.TissueAxes);
            app.TissueImageHandle = [];
            app.TissueAllPointsHandle = [];
            app.TissueNeighborPointsHandle = [];
            app.TissuePointAHandle = [];
            app.TissuePointBHandle = [];

            % Read CSV
            try
                tbl = readtable(char(csvPath), 'TextType', 'string', 'VariableNamingRule', 'preserve');
            catch ME
                app.updateStatus("Could not read CSV: " + string(ME.message));
                return
            end

            % Validate X/Y
            names = string(tbl.Properties.VariableNames);
            if ~all(ismember(["X", "Y"], names))
                app.updateStatus("CSV is missing required X and/or Y columns.");
                return
            end
            for col = ["X", "Y"]
                v = tbl.(char(col));
                if isnumeric(v)
                    tbl.(char(col)) = double(v);
                elseif iscellstr(v) || isstring(v) || iscategorical(v)
                    tbl.(char(col)) = str2double(string(v));
                else
                    app.updateStatus(col + " column is not numeric.");
                    return
                end
                if any(isnan(tbl.(char(col))))
                    app.updateStatus(col + " column contains NaN values.");
                    return
                end
            end

            % Add runtime columns
            n = height(tbl);
            tbl.CURATED_Deleted     = false(n, 1);
            tbl.CURATED_MergedRow   = false(n, 1);
            tbl.CURATED_OriginalRow = (1:n)';
            tbl.CURATED_OrigX       = double(tbl.X);   % snapshot of X at load time
            tbl.CURATED_OrigY       = double(tbl.Y);   % snapshot of Y at load time

            % Restore curation state from a previously-saved file. The saver
            % keeps every original row (raw X/Y preserved) but blanks the
            % effective coordinate (CURATED_X/CURATED_Y) of any row that was
            % deleted or merged away. Treat a blanked CURATED_X as a deletion
            % so resolved partners do not resurface as live detections.
            if ismember('CURATED_X', tbl.Properties.VariableNames)
                cx = tbl.CURATED_X;
                if ~isnumeric(cx), cx = str2double(string(cx)); end
                if numel(cx) == n
                    tbl.CURATED_Deleted = isnan(cx);
                end
            end

            app.ActiveLocTable = tbl;

            % Determine which TIFF page(s) this CSV addresses. Per-page CSVs
            % (the CellDiscovery convention) reference exactly one page and the
            % view is locked to it, so detections are never drawn over another
            % channel. A combined CSV that references several pages keeps page
            % navigation enabled.
            encPages = app.encodedPagesInTable();
            if isempty(encPages)
                app.ActiveCsvPage = CellToolkit.pageFromCsvName(csvPath);
                app.CsvSpansMultiplePages = false;
            elseif isscalar(encPages)
                app.ActiveCsvPage = encPages;
                app.CsvSpansMultiplePages = false;
            else
                app.ActiveCsvPage = min(encPages);
                app.CsvSpansMultiplePages = true;
            end

            % Find companion image
            app.ActiveImagePath = CellToolkit.inferImagePath(csvPath);
            if strlength(app.ActiveImagePath) > 0 && isfile(app.ActiveImagePath)
                try
                    app.ActiveTiffInfo = imfinfo(char(app.ActiveImagePath));
                    np = numel(app.ActiveTiffInfo);

                    % Pick the page to show. A per-page CSV is pinned to the page
                    % its detections came from; only a combined CSV (spanning
                    % multiple pages) leaves the spinner editable.
                    if np <= 1 || isnan(app.ActiveCsvPage)
                        pg = 1;
                    else
                        pg = app.ActiveCsvPage;
                    end
                    if pg > np
                        app.updateStatus(sprintf( ...
                            'CSV references page %d but image has %d page(s); showing page %d.', ...
                            pg, np, np));
                        pg = np;
                    end
                    pg = max(pg, 1);

                    % Set Value first so changing Limits never excludes it.
                    app.TiffPageSpinner.Value = 1;
                    app.TiffPageSpinner.Limits = [1 np];
                    app.TiffPageSpinner.Value = pg;
                    if app.CsvSpansMultiplePages && np > 1
                        app.TiffPageSpinner.Enable = "on";
                    else
                        app.TiffPageSpinner.Enable = "off";   % locked to the CSV's page
                    end
                    app.ActiveDisplayPage = pg;
                catch
                    app.ActiveTiffInfo = [];
                    app.ActiveImagePath = "";
                    app.TiffPageSpinner.Value = 1;
                    app.TiffPageSpinner.Limits = [1 1];
                    app.TiffPageSpinner.Enable = "off";
                    app.ActiveDisplayPage = 1;
                end
            else
                app.ActiveImagePath = "";
                app.TiffPageSpinner.Value = 1;
                app.TiffPageSpinner.Limits = [1 1];
                app.TiffPageSpinner.Enable = "off";
                if isnan(app.ActiveCsvPage)
                    app.ActiveDisplayPage = 1;
                else
                    app.ActiveDisplayPage = app.ActiveCsvPage;
                end
            end

            app.Settings.LastActiveCsvPath = csvPath;
            app.saveSettings();

            app.updatePairTable();
            app.updatePairProgressLabel();
            app.updatePairCountLabel();
            app.updatePairDetailLabel();
            app.renderTissuePlot();
            app.updateNextPageButtonLabel();

            if strlength(app.ActiveImagePath) > 0
                [~, imgName, imgExt] = fileparts(char(app.ActiveImagePath));
                imgNote = sprintf(' | Image: %s', [imgName imgExt]);
            else
                imgNote = ' | No companion image found (scatter only)';
            end

            % Auto-find neighbors at the current distance threshold so a
            % reopened file immediately shows its (restored) pair statuses
            % without a manual "Find Neighbors" click. This must never break
            % the load (or the startup scan that restores the last file): on
            % any failure the file still loads with an empty pair list and the
            % user can click Find Neighbors to surface the underlying error.
            try
                app.findNeighborsForActiveFile();
                app.SelectedPairIndex = NaN;
                firstIdx = app.findNextUnresolvedPair(0);
                if ~isnan(firstIdx)
                    app.selectPair(firstIdx);
                else
                    app.updatePairDetailLabel();
                end
                autoFindNote = sprintf(' | %d pair(s)', size(app.NeighborPairs, 1));
            catch findErr
                app.NeighborPairs = zeros(0, 3);
                app.PairStatus = strings(0, 1);
                app.FilteredPairIndices = [];
                app.SelectedPairIndex = NaN;
                app.updatePairTable();
                app.updatePairCountLabel();
                app.updatePairDetailLabel();
                autoFindNote = sprintf(' | auto-find skipped (%s)', findErr.message);
            end

            app.updateStatus(sprintf('Loaded %d detections from %s%s%s', n, ...
                char(CellToolkit.makeRelativePath(char(csvPath), char(app.ParentDirectory))), ...
                imgNote, autoFindNote));
        end

        function img = getImagePage(app, pageIndex)
            img = [];
            if isempty(app.ActiveTiffInfo) || strlength(app.ActiveImagePath) == 0
                return
            end
            pageIndex = max(1, min(pageIndex, numel(app.ActiveTiffInfo)));
            [img, app.ActiveImagePages] = CellToolkit.readImagePageCached( ...
                char(app.ActiveImagePath), pageIndex, app.ActiveImagePages);
        end

        % --------------------------------------------------------------
        % NEIGHBOR PAIR FINDING
        % --------------------------------------------------------------

        function findNeighborsForActiveFile(app)
            % Build neighbor pairs for the active file at the current distance
            % threshold and refresh the pair table / tissue plot. Does NOT
            % change the selected pair or emit a status message — callers own
            % selection and messaging. This is the single chokepoint shared by
            % the Find Neighbors button, auto-find on load, and dataset
            % navigation, so behaviour (incl. saved-status restoration) stays
            % consistent.
            distance = app.DistanceSpinner.Value;
            liveMask = app.currentPageMask();
            liveRows = find(liveMask);
            if numel(liveRows) >= 2
                liveTable = app.ActiveLocTable(liveRows, :);
                app.buildNeighborPairs(liveTable, distance, liveRows);
            else
                app.NeighborPairs = zeros(0, 3);
                app.PairStatus = strings(0, 1);
            end
            app.applyPairFilter();
            app.renderTissuePlot();
            app.updatePairCountLabel();
        end

        function onFindNeighborsButtonPushed(app)
            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                uialert(app.UIFigure, 'Load a CSV file first.', 'No data');
                return
            end

            app.updateStatus("Finding neighbor pairs...");
            drawnow

            app.findNeighborsForActiveFile();

            % Select first unresolved pair
            app.SelectedPairIndex = NaN;
            firstIdx = app.findNextUnresolvedPair(0);
            if ~isnan(firstIdx)
                app.selectPair(firstIdx);
            else
                app.updatePairDetailLabel();
            end

            n = size(app.NeighborPairs, 1);
            app.updateStatus(sprintf('Found %d neighbor pair(s) within %g px.', ...
                n, app.DistanceSpinner.Value));
        end

        function buildNeighborPairs(app, liveTable, distance, liveRows)
            neighbors = findCellNeighbors(liveTable, distance);
            nLive = height(liveTable);
            pairs = {};
            for i = 1:nLive
                js = neighbors{i}(neighbors{i} > i);
                if ~isempty(js)
                    xi = liveTable.X(i);
                    yi = liveTable.Y(i);
                    xj = liveTable.X(js)';
                    yj = liveTable.Y(js)';
                    dists = hypot(xj - xi, yj - yi);
                    % Map back to absolute row numbers in ActiveLocTable
                    absA = repmat(liveRows(i), numel(js), 1);
                    absB = liveRows(js(:));
                    pairs{end+1} = [absA, absB, dists(:)]; %#ok<AGROW>
                end
            end
            if isempty(pairs)
                app.NeighborPairs = zeros(0, 3);
            else
                app.NeighborPairs = vertcat(pairs{:});
            end
            app.PairStatus = repmat(app.STATUS_UNRESOLVED, size(app.NeighborPairs, 1), 1);
            app.restoreSavedPairStatuses();
        end

        function restoreSavedPairStatuses(app)
            % After (re)building neighbor pairs, restore the resolution status
            % of any pair that was resolved in a previous session and saved to
            % the CSV. A re-found pair is matched when both of its rows carry
            % the same non-empty NeighborPairID; its status is taken from the
            % saved NeighborResolvedStatus column. This makes auto-saved
            % resolutions persist across app restarts instead of all reverting
            % to "Unresolved".
            if isempty(app.ActiveLocTable) || size(app.NeighborPairs, 1) == 0
                return
            end
            names = app.ActiveLocTable.Properties.VariableNames;
            if ~all(ismember({'NeighborResolvedStatus', 'NeighborPairID'}, names))
                return
            end
            statusCol = string(app.ActiveLocTable.NeighborResolvedStatus);
            pairIdCol = string(app.ActiveLocTable.NeighborPairID);
            nRows = height(app.ActiveLocTable);
            for p = 1:size(app.NeighborPairs, 1)
                rA = app.NeighborPairs(p, 1);
                rB = app.NeighborPairs(p, 2);
                if rA < 1 || rA > nRows || rB < 1 || rB > nRows
                    continue
                end
                idA = pairIdCol(rA);
                idB = pairIdCol(rB);
                if strlength(idA) > 0 && idA == idB
                    st = statusCol(rA);
                    if strlength(st) > 0
                        app.PairStatus(p) = st;
                    end
                end
            end
        end

        function applyPairFilter(app)
            n = size(app.NeighborPairs, 1);
            if n == 0
                app.FilteredPairIndices = [];
                app.updatePairTable();
                app.updatePairProgressLabel();
                return
            end

            filterVal = string(app.FilterDropDown.Value);
            switch filterVal
                case "Unresolved only"
                    mask = app.PairStatus == app.STATUS_UNRESOLVED;
                case "Resolved only"
                    mask = app.PairStatus ~= app.STATUS_UNRESOLVED;
                otherwise
                    mask = true(n, 1);
            end
            app.FilteredPairIndices = find(mask);
            app.updatePairTable();
            app.updatePairProgressLabel();
        end

        function onFilterChanged(app)
            app.applyPairFilter();
            % Try to keep current pair selected
            if ~isnan(app.SelectedPairIndex)
                pos = find(app.FilteredPairIndices == app.SelectedPairIndex, 1);
                if isempty(pos)
                    app.SelectedPairIndex = NaN;
                    app.updateTissueHighlights();
                    app.updatePairDetailLabel();
                end
            end
        end

        % --------------------------------------------------------------
        % PAIR TABLE & NAVIGATION
        % --------------------------------------------------------------

        function updatePairTable(app)
            nFiltered = numel(app.FilteredPairIndices);
            data = cell(nFiltered, 5);
            for k = 1:nFiltered
                pi = app.FilteredPairIndices(k);
                data{k, 1} = k;
                data{k, 2} = app.NeighborPairs(pi, 1);
                data{k, 3} = app.NeighborPairs(pi, 2);
                data{k, 4} = round(app.NeighborPairs(pi, 3), 1);
                data{k, 5} = char(app.PairStatus(pi));
            end
            app.PairTableData = data;
            app.PairTable.Data = data;
        end

        function updatePairProgressLabel(app)
            n = size(app.NeighborPairs, 1);
            if n == 0
                app.PairProgressLabel.Text = '0 resolved / 0 total';
                return
            end
            nResolved = sum(app.PairStatus ~= app.STATUS_UNRESOLVED);
            app.PairProgressLabel.Text = sprintf('%d resolved / %d total', nResolved, n);
        end

        function updatePairCountLabel(app)
            n = size(app.NeighborPairs, 1);
            if n == 0
                app.PairCountLabel.Text = 'No pairs found';
            else
                app.PairCountLabel.Text = sprintf('%d pair(s) found', n);
            end
        end

        function updatePairDetailLabel(app)
            if isnan(app.SelectedPairIndex) || app.SelectedPairIndex < 1 || ...
                    app.SelectedPairIndex > size(app.NeighborPairs, 1)
                app.PairDetailLabel.Text = 'No pair selected';
                return
            end
            rowA = app.NeighborPairs(app.SelectedPairIndex, 1);
            rowB = app.NeighborPairs(app.SelectedPairIndex, 2);
            dist = app.NeighborPairs(app.SelectedPairIndex, 3);
            status = char(app.PairStatus(app.SelectedPairIndex));

            xA = app.ActiveLocTable.X(rowA);
            yA = app.ActiveLocTable.Y(rowA);
            xB = app.ActiveLocTable.X(rowB);
            yB = app.ActiveLocTable.Y(rowB);

            txt = sprintf('Pair %d-%d  |  Dist: %.1f px\nA: row %d  (%.1f, %.1f)\nB: row %d  (%.1f, %.1f)\nStatus: %s', ...
                rowA, rowB, dist, rowA, xA, yA, rowB, xB, yB, status);
            app.PairDetailLabel.Text = txt;
        end

        function onPairTableSelected(app, ~, event)
            if isempty(event.Indices)
                return
            end
            displayRow = event.Indices(1, 1);
            if displayRow < 1 || displayRow > numel(app.FilteredPairIndices)
                return
            end
            app.selectPair(app.FilteredPairIndices(displayRow));
        end

        function selectPair(app, pairIndex)
            if pairIndex < 1 || pairIndex > size(app.NeighborPairs, 1)
                return
            end
            app.SelectedPairIndex = pairIndex;
            app.updateTissueHighlights();
            app.updatePairDetailLabel();
            app.zoomToActivePair();

            % Highlight table row
            pos = find(app.FilteredPairIndices == pairIndex, 1);
            if ~isempty(pos) && ~isempty(app.PairTableData)
                app.PairTable.Selection = [pos, 1];
            end
        end

        function zoomToActivePair(app)
            if isnan(app.SelectedPairIndex) || ~isvalid(app.TissueAxes)
                return
            end
            rowA = app.NeighborPairs(app.SelectedPairIndex, 1);
            rowB = app.NeighborPairs(app.SelectedPairIndex, 2);
            xA = double(app.ActiveLocTable.X(rowA));
            yA = double(app.ActiveLocTable.Y(rowA));
            xB = double(app.ActiveLocTable.X(rowB));
            yB = double(app.ActiveLocTable.Y(rowB));

            % Pad so both points are comfortably visible; minimum view of 60 px
            pad = max(80, app.NeighborPairs(app.SelectedPairIndex, 3) * 8);
            cx = (xA + xB) / 2;
            cy = (yA + yB) / 2;

            app.TissueAxes.XLim = [cx - pad, cx + pad];
            app.TissueAxes.YLim = [cy - pad, cy + pad];
            app.updateOverviewRect();
        end

        function navigatePairs(app, direction)
            if isempty(app.FilteredPairIndices)
                app.crossToAdjacentDataset(direction);
                return
            end
            if isnan(app.SelectedPairIndex)
                newPos = 1;
            else
                curPos = find(app.FilteredPairIndices == app.SelectedPairIndex, 1);
                if isempty(curPos)
                    newPos = 1;
                else
                    newPos = curPos + direction;
                    if newPos < 1
                        app.crossToAdjacentDataset(-1);
                        return
                    elseif newPos > numel(app.FilteredPairIndices)
                        app.crossToAdjacentDataset(+1);
                        return
                    end
                end
            end
            app.selectPair(app.FilteredPairIndices(newPos));
        end

        function crossToAdjacentDataset(app, direction)
            currentIdx = app.activeFileIndex();
            if currentIdx == 0
                return
            end
            targetIdx = currentIdx + direction;
            if targetIdx < 1
                app.updateStatus("Already at the first observation of the first dataset.");
                return
            end
            if targetIdx > numel(app.AllAbsFiles)
                app.updateStatus("Already at the last observation of the last dataset.");
                return
            end
            app.loadDatasetAndNavigate(targetIdx, direction == -1);
        end

        function loadDatasetAndNavigate(app, fileIndex, goToLast)
            nextPath = string(app.AllAbsFiles{fileIndex});
            app.selectFileTableRow(fileIndex);
            app.loadCsvFile(nextPath);   % auto-finds neighbors

            nPairs = numel(app.FilteredPairIndices);
            relPath = char(CellToolkit.makeRelativePath(char(nextPath), char(app.ParentDirectory)));

            if nPairs == 0
                app.updateStatus(sprintf('Loaded %s — no pairs found.', relPath));
                return
            end

            if goToLast
                pairIdx = app.FilteredPairIndices(end);
            else
                pairIdx = app.FilteredPairIndices(1);
            end

            app.updateStatus(sprintf('Crossed to %s — %d pair(s) found.', relPath, ...
                size(app.NeighborPairs, 1)));
            app.selectPair(pairIdx);
        end

        function pairIdx = findNextUnresolvedPair(app, afterPosition)
            pairIdx = NaN;
            if isempty(app.FilteredPairIndices)
                return
            end
            n = numel(app.FilteredPairIndices);
            % Search from afterPosition+1 to end, then wrap
            searchOrder = [afterPosition+1:n, 1:afterPosition];
            for k = searchOrder
                pi = app.FilteredPairIndices(k);
                if app.PairStatus(pi) == app.STATUS_UNRESOLVED
                    pairIdx = pi;
                    return
                end
            end
        end

        function advanceToNextUnresolved(app)
            if isnan(app.SelectedPairIndex)
                curPos = 0;
            else
                curPos = find(app.FilteredPairIndices == app.SelectedPairIndex, 1);
                if isempty(curPos)
                    curPos = 0;
                end
            end
            nextIdx = app.findNextUnresolvedPair(curPos);
            if ~isnan(nextIdx)
                app.selectPair(nextIdx);
            else
                % All pairs resolved on this page/file — advance
                app.updateStatus("All pairs resolved. Advancing...");
                drawnow
                app.advanceToNextPage();
            end
        end

        function loadNextFileAndFindNeighbors(app)
            if isempty(app.AllAbsFiles)
                app.updateStatus("All pairs resolved. No more files in list.");
                return
            end

            % Find index of current file in AllAbsFiles
            currentIdx = 0;
            for k = 1:numel(app.AllAbsFiles)
                if strcmp(app.AllAbsFiles{k}, char(app.ActiveCsvPath))
                    currentIdx = k;
                    break
                end
            end

            % Walk forward through remaining files until we find one with pairs
            for nextIdx = currentIdx + 1 : numel(app.AllAbsFiles)
                nextPath = string(app.AllAbsFiles{nextIdx});

                app.selectFileTableRow(nextIdx);
                app.loadCsvFile(nextPath);   % auto-finds neighbors

                % Check if this file has any unresolved pairs
                firstUnresolved = app.findNextUnresolvedPair(0);
                if ~isnan(firstUnresolved)
                    n = size(app.NeighborPairs, 1);
                    app.updateStatus(sprintf('Advanced to %s — %d pair(s) found.', ...
                        char(CellToolkit.makeRelativePath(char(nextPath), char(app.ParentDirectory))), n));
                    app.selectPair(firstUnresolved);
                    return
                end
                % No pairs in this file — continue to the next one
            end

            app.updateStatus("All pairs resolved across all files in list.");
        end

        % --------------------------------------------------------------
        % TISSUE PLOT
        % --------------------------------------------------------------

        function renderTissuePlot(app)
            cla(app.TissueAxes);
            app.TissueImageHandle = [];
            app.TissueAllPointsHandle = [];
            app.TissueNeighborPointsHandle = [];
            app.TissuePointAHandle = [];
            app.TissuePointBHandle = [];

            img = app.getImagePage(app.ActiveDisplayPage);

            if isempty(img)
                % No image — show scatter on blank axes with a note
                axis(app.TissueAxes, 'on');
                if strlength(app.ActiveImagePath) == 0
                    title(app.TissueAxes, 'No companion image found — scatter only', ...
                        'Interpreter', 'none', 'FontSize', 9, 'Color', [0.6 0.6 0.6]);
                else
                    title(app.TissueAxes, 'Image could not be loaded', ...
                        'Interpreter', 'none', 'FontSize', 9, 'Color', [0.8 0.3 0.3]);
                end
            else
                hImg = imshow(img, [], 'Parent', app.TissueAxes);
                app.TissueImageHandle = hImg;
                hImg.HitTest = 'on';
                hImg.PickableParts = 'all';
                hImg.ButtonDownFcn = @(s,e) app.onTissueClicked(s, e);
                axis(app.TissueAxes, 'image');
                [~, imgName, imgExt] = fileparts(char(app.ActiveImagePath));
                np = numel(app.ActiveTiffInfo);
                if np > 1
                    titleTxt = sprintf('%s%s  [page %d/%d]', imgName, imgExt, ...
                        app.ActiveDisplayPage, np);
                else
                    titleTxt = [imgName imgExt];
                end
                title(app.TissueAxes, titleTxt, 'Interpreter', 'none', 'FontSize', 8);
            end

            app.TissueAxes.HitTest = 'on';
            app.TissueAxes.PickableParts = 'all';
            app.TissueAxes.ButtonDownFcn = @(s,e) app.onTissueClicked(s, e);

            hold(app.TissueAxes, 'on');
            app.drawTissueAllPoints();
            app.updateTissueHighlights();
            hold(app.TissueAxes, 'off');

            % Snapshot the full-image extent so zoom/pan can clamp against it
            app.TissueHomeXLim = app.TissueAxes.XLim;
            app.TissueHomeYLim = app.TissueAxes.YLim;

            app.installTissueContextMenu();
            app.renderOverview();
        end

        % --------------------------------------------------------------
        % OVERVIEW THUMBNAIL (whole-page navigator)
        % --------------------------------------------------------------

        function renderOverview(app)
            ax = app.OverviewAxes;
            if isempty(ax) || ~isvalid(ax)
                return
            end
            cla(ax);
            app.OverviewImageHandle = [];
            app.OverviewRectHandle  = [];

            img = app.getImagePage(app.ActiveDisplayPage);

            if isempty(img)
                % No companion image — show a faint scatter of the live points
                % so the navigator still has spatial context.
                liveMask = app.currentPageMask();
                liveIdx = find(liveMask);
                if ~isempty(liveIdx)
                    x = double(app.ActiveLocTable.X(liveIdx));
                    y = double(app.ActiveLocTable.Y(liveIdx));
                    scatter(ax, x, y, 4, [0.2 0.6 1.0], 'filled', ...
                        'HitTest', 'off', 'PickableParts', 'none');
                    axis(ax, 'image');
                    set(ax, 'YDir', 'reverse');
                    if ~isempty(app.TissueHomeXLim) && ~isempty(app.TissueHomeYLim)
                        ax.XLim = app.TissueHomeXLim;
                        ax.YLim = app.TissueHomeYLim;
                    end
                end
            else
                h = imshow(img, [], 'Parent', ax);
                app.OverviewImageHandle = h;
                h.HitTest = 'on';
                h.PickableParts = 'all';
                h.ButtonDownFcn = @(s,e) app.onOverviewClicked();
                axis(ax, 'image');
            end

            ax.XTick = [];
            ax.YTick = [];
            ax.HitTest = 'on';
            ax.PickableParts = 'all';
            ax.ButtonDownFcn = @(s,e) app.onOverviewClicked();

            app.updateOverviewRect();
        end

        function updateOverviewRect(app)
            % Draw/move the red rectangle marking the tissue-plot view extent.
            if isempty(app.OverviewAxes) || ~isvalid(app.OverviewAxes) || ...
                    isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end
            xl = app.TissueAxes.XLim;
            yl = app.TissueAxes.YLim;
            if numel(xl) ~= 2 || numel(yl) ~= 2 || any(~isfinite([xl yl]))
                return
            end
            pos = [xl(1), yl(1), max(diff(xl), eps), max(diff(yl), eps)];
            if isempty(app.OverviewRectHandle) || ~isvalid(app.OverviewRectHandle)
                app.OverviewRectHandle = rectangle(app.OverviewAxes, ...
                    'Position', pos, ...
                    'EdgeColor', [1 0.15 0.15], ...
                    'LineWidth', 1.5, ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none');
            else
                app.OverviewRectHandle.Position = pos;
            end
        end

        function onOverviewClicked(app)
            ax = app.OverviewAxes;
            if isempty(ax) || ~isvalid(ax)
                return
            end
            cp = ax.CurrentPoint;
            cx = cp(1, 1);
            cy = cp(1, 2);
            if ~isfinite(cx) || ~isfinite(cy)
                return
            end
            app.centerTissueViewOn(cx, cy);
        end

        function centerTissueViewOn(app, cx, cy)
            % Recenter the tissue plot on (cx, cy) keeping the current zoom span,
            % clamped to the full-image extent, then refresh the overview rect.
            ax = app.TissueAxes;
            if isempty(ax) || ~isvalid(ax)
                return
            end
            wx = diff(ax.XLim);
            wy = diff(ax.YLim);
            if ~(wx > 0) || ~(wy > 0)
                return
            end
            newXl = [cx - wx/2, cx + wx/2];
            newYl = [cy - wy/2, cy + wy/2];
            [newXl, newYl] = app.clampToHome(newXl, newYl);
            ax.XLim = newXl;
            ax.YLim = newYl;
            app.updateOverviewRect();
        end

        function drawTissueAllPoints(app)
            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                return
            end

            % Only show live (non-deleted) rows
            liveMask = app.currentPageMask();
            liveIdx = find(liveMask);
            if isempty(liveIdx)
                return
            end

            % Partition into neighbor rows (in any pair) and non-neighbor rows
            nPairs = size(app.NeighborPairs, 1);
            inPairRows = false(height(app.ActiveLocTable), 1);
            for p = 1:nPairs
                inPairRows(app.NeighborPairs(p, 1)) = true;
                inPairRows(app.NeighborPairs(p, 2)) = true;
            end
            neighborMask   = inPairRows(liveIdx);
            neighborIdx    = liveIdx(neighborMask);
            nonNeighborIdx = liveIdx(~neighborMask);

            vis = true;
            if ~isempty(app.ShowPointsCheckBox) && isvalid(app.ShowPointsCheckBox)
                vis = app.ShowPointsCheckBox.Value;
            end

            % Non-neighbor points: small filled circles, magenta
            if ~isempty(nonNeighborIdx)
                xn = double(app.ActiveLocTable.X(nonNeighborIdx));
                yn = double(app.ActiveLocTable.Y(nonNeighborIdx));
                h = scatter(app.TissueAxes, xn, yn, 18, [1.0 0.25 0.75], 'filled', ...
                    'MarkerFaceAlpha', 0.8, ...
                    'MarkerEdgeColor', 'flat', ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none');
                h.Annotation.LegendInformation.IconDisplayStyle = 'off';
                h.Visible = vis;
                app.TissueAllPointsHandle = h;
            end

            % Neighbor points: filled orange squares, colored by resolution status
            if ~isempty(neighborIdx)
                xp = double(app.ActiveLocTable.X(neighborIdx));
                yp = double(app.ActiveLocTable.Y(neighborIdx));
                colors = app.pointColorsForRows(neighborIdx);
                h2 = scatter(app.TissueAxes, xp, yp, 22, colors, 's', 'filled', ...
                    'MarkerFaceAlpha', 0.85, ...
                    'MarkerEdgeColor', 'flat', ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none');
                h2.Annotation.LegendInformation.IconDisplayStyle = 'off';
                h2.Visible = vis;
                app.TissueNeighborPointsHandle = h2;
            end
        end

        function updateTissueAllPoints(app)
            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                return
            end

            % Delete both handles and rebuild — neighbor membership may have
            % changed, requiring different marker shapes for some rows.
            if ~isempty(app.TissueAllPointsHandle) && isvalid(app.TissueAllPointsHandle)
                delete(app.TissueAllPointsHandle);
            end
            app.TissueAllPointsHandle = [];
            if ~isempty(app.TissueNeighborPointsHandle) && isvalid(app.TissueNeighborPointsHandle)
                delete(app.TissueNeighborPointsHandle);
            end
            app.TissueNeighborPointsHandle = [];

            hold(app.TissueAxes, 'on');
            app.drawTissueAllPoints();
            hold(app.TissueAxes, 'off');
        end

        function colors = pointColorsForRows(app, rowIndices)
            n = numel(rowIndices);
            colors = zeros(n, 3);

            % Build a set of which rows are "in a pair" for quick lookup
            nPairs = size(app.NeighborPairs, 1);
            inPairRows = false(height(app.ActiveLocTable), 1);
            for p = 1:nPairs
                inPairRows(app.NeighborPairs(p, 1)) = true;
                inPairRows(app.NeighborPairs(p, 2)) = true;
            end

            for k = 1:n
                r = rowIndices(k);
                if app.ActiveLocTable.CURATED_MergedRow(r)
                    colors(k, :) = [0.4 0.7 1.0];     % light blue: merged
                elseif nPairs > 0 && r <= numel(inPairRows) && inPairRows(r)
                    % Find the pair status for this row
                    pIdx = find(app.NeighborPairs(:,1) == r | app.NeighborPairs(:,2) == r, 1);
                    if ~isempty(pIdx) && app.PairStatus(pIdx) ~= app.STATUS_UNRESOLVED
                        colors(k, :) = [0.3 0.8 0.3]; % green: resolved/kept
                    else
                        colors(k, :) = [1.0 0.65 0.0]; % orange: in unresolved pair
                    end
                else
                    colors(k, :) = [1.0 0.25 0.75]; % magenta: not in any pair
                end
            end
        end

        function updateTissueHighlights(app)
            % Remove old highlight handles
            if ~isempty(app.TissuePointAHandle) && isvalid(app.TissuePointAHandle)
                delete(app.TissuePointAHandle);
            end
            if ~isempty(app.TissuePointBHandle) && isvalid(app.TissuePointBHandle)
                delete(app.TissuePointBHandle);
            end
            app.TissuePointAHandle = [];
            app.TissuePointBHandle = [];

            if isnan(app.SelectedPairIndex) || app.SelectedPairIndex < 1 || ...
                    app.SelectedPairIndex > size(app.NeighborPairs, 1)
                return
            end

            rowA = app.NeighborPairs(app.SelectedPairIndex, 1);
            rowB = app.NeighborPairs(app.SelectedPairIndex, 2);

            holdState = ishold(app.TissueAxes);
            hold(app.TissueAxes, 'on');

            xA = double(app.ActiveLocTable.X(rowA));
            yA = double(app.ActiveLocTable.Y(rowA));
            if ~app.ActiveLocTable.CURATED_Deleted(rowA)
                app.TissuePointAHandle = scatter(app.TissueAxes, xA, yA, 150, ...
                    'o', 'filled', ...
                    'MarkerFaceColor', [0.25 0.75 0.35], ...
                    'MarkerEdgeColor', [0.1 0.4 0.15], ...
                    'LineWidth', 1.5, ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none', ...
                    'DisplayName', sprintf('A (row %d)', rowA));
            end

            xB = double(app.ActiveLocTable.X(rowB));
            yB = double(app.ActiveLocTable.Y(rowB));
            if ~app.ActiveLocTable.CURATED_Deleted(rowB)
                app.TissuePointBHandle = scatter(app.TissueAxes, xB, yB, 150, ...
                    's', 'filled', ...
                    'MarkerFaceColor', [0.2 0.55 0.85], ...
                    'MarkerEdgeColor', [0.1 0.25 0.5], ...
                    'LineWidth', 1.5, ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none', ...
                    'DisplayName', sprintf('B (row %d)', rowB));
            end

            if ~holdState
                hold(app.TissueAxes, 'off');
            end

            % Respect show/hide toggle for new handles
            if ~isempty(app.ShowPointsCheckBox) && isvalid(app.ShowPointsCheckBox) ...
                    && ~app.ShowPointsCheckBox.Value
                if ~isempty(app.TissuePointAHandle) && isvalid(app.TissuePointAHandle)
                    app.TissuePointAHandle.Visible = 'off';
                end
                if ~isempty(app.TissuePointBHandle) && isvalid(app.TissuePointBHandle)
                    app.TissuePointBHandle.Visible = 'off';
                end
            end
        end

        function onTissueClicked(app, ~, ~)
            % Middle-button (or Shift+click) starts a pan drag. Handle it first
            % so it never triggers point selection or an armed action.
            if strcmp(app.figureSelectionType(), 'extend')
                app.beginPan();
                return
            end

            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                return
            end

            point = app.TissueAxes.CurrentPoint;
            xClick = point(1, 1);
            yClick = point(1, 2);

            if app.MergeArmed
                app.executeMerge(xClick, yClick);
                return
            end

            if app.DeletePointArmed
                app.executeDeletePoint(xClick, yClick);
                return
            end

            if app.RelocatePointArmed
                app.executeRelocateClick(xClick, yClick);
                return
            end

            if app.AddPointArmed
                app.executeAddPoint(xClick, yClick);
                return
            end

            % Find nearest live detection
            liveMask = app.currentPageMask();
            x = double(app.ActiveLocTable.X);
            y = double(app.ActiveLocTable.Y);
            x(~liveMask) = Inf;
            y(~liveMask) = Inf;

            dx = x - xClick;
            dy = y - yClick;
            d2 = dx.^2 + dy.^2;
            [minD2, rowIdx] = min(d2);

            if ~isfinite(minD2)
                return
            end

            % Click tolerance: 0.5% of image diagonal or min 10 px
            if ~isempty(app.ActiveTiffInfo) && numel(app.ActiveTiffInfo) >= app.ActiveDisplayPage
                W = double(app.ActiveTiffInfo(app.ActiveDisplayPage).Width);
                H = double(app.ActiveTiffInfo(app.ActiveDisplayPage).Height);
                tol = max(10, 0.005 * hypot(W, H));
            else
                tol = 20;
            end

            if sqrt(minD2) > tol
                return
            end

            % Find a pair containing this row and select it
            pIdx = find(app.NeighborPairs(:,1) == rowIdx | app.NeighborPairs(:,2) == rowIdx, 1, 'first');
            if ~isempty(pIdx)
                app.selectPair(pIdx);
            end
        end

        % --------------------------------------------------------------
        % IMAGE NAVIGATION (zoom / pan)
        % --------------------------------------------------------------

        function onScrollWheel(app, ~, event)
            % Zoom the tissue plot in/out, keeping the point under the cursor
            % fixed. Only acts when the pointer is over the tissue axes.
            if ~app.pointerOverTissueAxes()
                return
            end
            ax = app.TissueAxes;
            if isempty(ax) || ~isvalid(ax)
                return
            end

            cp = ax.CurrentPoint;
            cx = cp(1, 1);
            cy = cp(1, 2);
            if ~isfinite(cx) || ~isfinite(cy)
                return
            end

            % Scroll up (negative count) zooms in; scroll down zooms out.
            if event.VerticalScrollCount < 0
                factor = 1 / 1.25;
            elseif event.VerticalScrollCount > 0
                factor = 1.25;
            else
                return
            end

            xl = ax.XLim;
            yl = ax.YLim;
            newXl = cx + (xl - cx) * factor;
            newYl = cy + (yl - cy) * factor;

            minSpan = 8;   % px — don't zoom in past a handful of pixels
            if factor > 1
                % Zooming out: snap back to the full image once we reach it
                if isempty(app.TissueHomeXLim) || diff(newXl) >= diff(app.TissueHomeXLim)
                    app.resetTissueView();
                    return
                end
            elseif diff(newXl) < minSpan
                return
            end

            [newXl, newYl] = app.clampToHome(newXl, newYl);
            if newXl(2) > newXl(1) && newYl(2) > newYl(1)
                ax.XLim = newXl;
                ax.YLim = newYl;
                app.updateOverviewRect();
            end
        end

        function beginPan(app)
            % Start a middle-button (or Shift+click) drag pan. The data point
            % grabbed at button-down stays under the cursor as it moves.
            ax = app.TissueAxes;
            if isempty(ax) || ~isvalid(ax)
                return
            end
            app.PanActive    = true;
            cp = ax.CurrentPoint;
            app.PanStartData = cp(1, 1:2);
            app.UIFigure.WindowButtonMotionFcn = @(s,e) app.doPanMotion();
            app.UIFigure.WindowButtonUpFcn     = @(s,e) app.endPan();
            try
                app.UIFigure.Pointer = 'hand';
            catch
            end
        end

        function doPanMotion(app)
            if ~app.PanActive || isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end
            ax = app.TissueAxes;
            cp = ax.CurrentPoint;
            delta = cp(1, 1:2) - app.PanStartData;   % PanStartData stays fixed
            if any(~isfinite(delta))
                return
            end
            xl = ax.XLim - delta(1);
            yl = ax.YLim - delta(2);
            [xl, yl] = app.clampToHome(xl, yl);
            ax.XLim = xl;
            ax.YLim = yl;
            app.updateOverviewRect();
        end

        function endPan(app)
            app.PanActive = false;
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                app.UIFigure.WindowButtonMotionFcn = '';
                app.UIFigure.WindowButtonUpFcn     = '';
                try
                    app.UIFigure.Pointer = 'arrow';
                catch
                end
            end
        end

        function resetTissueView(app)
            % Restore the full-image ("home") view.
            if isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end
            if ~isempty(app.TissueHomeXLim) && ~isempty(app.TissueHomeYLim)
                app.TissueAxes.XLim = app.TissueHomeXLim;
                app.TissueAxes.YLim = app.TissueHomeYLim;
                app.updateOverviewRect();
                app.updateStatus("View reset to full image.");
            end
        end

        function [xl, yl] = clampToHome(app, xl, yl)
            % Keep limits inside the full-image extent (shift, don't shrink).
            if ~isempty(app.TissueHomeXLim) && numel(app.TissueHomeXLim) == 2
                xl = app.clampOneAxis(xl, app.TissueHomeXLim);
            end
            if ~isempty(app.TissueHomeYLim) && numel(app.TissueHomeYLim) == 2
                yl = app.clampOneAxis(yl, app.TissueHomeYLim);
            end
        end

        function lim = clampOneAxis(~, lim, home)
            span = diff(lim);
            if span >= diff(home)
                lim = home;                       % view at least as wide as home → snap
            elseif lim(1) < home(1)
                lim = home(1) + [0, span];        % slid past the low edge
            elseif lim(2) > home(2)
                lim = home(2) - [span, 0];        % slid past the high edge
            end
        end

        function tf = pointerOverTissueAxes(app)
            tf = false;
            if isempty(app.TissueAxes) || ~isvalid(app.TissueAxes) || ...
                    isempty(app.UIFigure) || ~isvalid(app.UIFigure)
                return
            end
            try
                p  = app.UIFigure.CurrentPoint;             % [x y] px from fig lower-left
                ap = getpixelposition(app.TissueAxes, true); % [x y w h] px in figure
            catch
                return
            end
            tf = p(1) >= ap(1) && p(1) <= ap(1) + ap(3) && ...
                 p(2) >= ap(2) && p(2) <= ap(2) + ap(4);
        end

        function selType = figureSelectionType(app)
            selType = 'normal';
            try
                selType = app.UIFigure.SelectionType;
            catch
            end
        end

        function installTissueContextMenu(app)
            if isempty(app.TissueFigure()) || ~isvalid(app.TissueAxes)
                return
            end

            % Context menus on uiaxes need the parent figure
            parentFig = ancestor(app.TissueAxes, 'figure');
            if isempty(parentFig)
                return
            end

            cm = uicontextmenu(parentFig);

            uimenu(cm, 'Text', 'Merge selected pair — click to place', ...
                'MenuSelectedFcn', @(s,e) app.armMerge());

            uimenu(cm, 'Text', 'Skip all pairs in freehand ROI', ...
                'MenuSelectedFcn', @(s,e) app.skipPairsInFreehandROI());

            uimenu(cm, 'Text', 'Reset view (fit image)  [f]', ...
                'Separator', 'on', ...
                'MenuSelectedFcn', @(s,e) app.resetTissueView());

            app.TissueContextMenu = cm;
            if isprop(app.TissueAxes, 'ContextMenu')
                app.TissueAxes.ContextMenu = cm;
            end
            if ~isempty(app.TissueImageHandle) && isvalid(app.TissueImageHandle)
                if isprop(app.TissueImageHandle, 'ContextMenu')
                    app.TissueImageHandle.ContextMenu = cm;
                end
            end
        end

        function fig = TissueFigure(app)
            % Returns the figure containing TissueAxes (the main UIFigure)
            fig = app.UIFigure;
        end

        function skipPairsInFreehandROI(app)
            if isempty(app.NeighborPairs) || size(app.NeighborPairs, 1) == 0
                return
            end
            if ~isvalid(app.TissueAxes)
                return
            end
            if exist('drawfreehand', 'file') ~= 2
                uialert(app.UIFigure, 'drawfreehand requires the Image Processing Toolbox.', ...
                    'Toolbox required');
                return
            end

            figure(ancestor(app.TissueAxes, 'figure'));
            roi = drawfreehand(app.TissueAxes, 'Color', [1 1 0], 'LineWidth', 1.5, 'FaceAlpha', 0.05);

            if isempty(roi) || ~isvalid(roi) || isempty(roi.Position) || size(roi.Position, 1) < 3
                if ~isempty(roi) && isvalid(roi), delete(roi); end
                return
            end

            px = roi.Position(:,1);
            py = roi.Position(:,2);
            delete(roi);

            x = double(app.ActiveLocTable.X);
            y = double(app.ActiveLocTable.Y);

            nChanged = 0;
            for p = 1:size(app.NeighborPairs, 1)
                if app.PairStatus(p) ~= app.STATUS_UNRESOLVED
                    continue
                end
                rA = app.NeighborPairs(p, 1);
                rB = app.NeighborPairs(p, 2);
                if inpolygon(x(rA), y(rA), px, py) && inpolygon(x(rB), y(rB), px, py)
                    app.PairStatus(p) = app.STATUS_SKIPPED;
                    nChanged = nChanged + 1;
                end
            end

            if nChanged > 0
                app.Dirty = true;
                app.applyPairFilter();
                app.updateTissueAllPoints();
                app.updatePairProgressLabel();
                app.updateStatus(sprintf('Skipped %d pair(s) within ROI.', nChanged));
            else
                app.updateStatus("No unresolved pairs found within the drawn ROI.");
            end
        end

        function mask = currentPageMask(app)
            % Returns a logical mask over ActiveLocTable rows that are:
            %   (a) not deleted, AND
            %   (b) belong to the page currently displayed.
            % The page each row belongs to is encoded in its imgName as the
            % trailing digits of the per-page suffix (e.g. "<stem>_PNN1" -> page
            % 1, "<stem>_page2" -> page 2). Rows whose imgName encodes no page
            % are treated as page 1. This keeps one channel's detections from
            % ever being drawn over another channel's image.
            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                mask = logical([]);
                return
            end
            mask = ~app.ActiveLocTable.CURATED_Deleted;

            names = string(app.ActiveLocTable.Properties.VariableNames);
            if ~ismember("imgName", names)
                return
            end
            ids = cellstr(string(app.ActiveLocTable.imgName));
            rowPages = nan(numel(ids), 1);
            for k = 1:numel(ids)
                rowPages(k) = CellToolkit.pageFromIdentity(ids{k});
            end
            if all(isnan(rowPages))
                return   % no page encoded anywhere — single-page CSV, show all
            end
            rowPages(isnan(rowPages)) = 1;   % unencoded rows belong to page 1
            mask = mask & (rowPages == app.ActiveDisplayPage);
        end

        function pages = encodedPagesInTable(app)
            % Distinct TIFF pages referenced by the loaded table's imgName
            % column (empty when the column is absent or encodes no pages).
            pages = [];
            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                return
            end
            names = string(app.ActiveLocTable.Properties.VariableNames);
            if ~ismember("imgName", names)
                return
            end
            ids = cellstr(string(app.ActiveLocTable.imgName));
            p = nan(numel(ids), 1);
            for k = 1:numel(ids)
                p(k) = CellToolkit.pageFromIdentity(ids{k});
            end
            pages = unique(p(~isnan(p)));
        end

        function onTiffPageChanged(app)
            app.ActiveDisplayPage = app.TiffPageSpinner.Value;
            app.Settings.TiffPageIndex = app.ActiveDisplayPage;
            % Re-run neighbor search for the new page's rows, then re-render
            app.onFindNeighborsButtonPushed();
            app.updateNextPageButtonLabel();
        end

        function updateNextPageButtonLabel(app)
            if isempty(app.NextPageButton) || ~isvalid(app.NextPageButton)
                return
            end
            hasMorePages = app.CsvSpansMultiplePages && ...
                ~isempty(app.ActiveTiffInfo) && ...
                numel(app.ActiveTiffInfo) > 1 && ...
                app.ActiveDisplayPage < numel(app.ActiveTiffInfo);
            if hasMorePages
                app.NextPageButton.Text = sprintf('Next Page (%d→%d)  [Tab]', ...
                    app.ActiveDisplayPage, app.ActiveDisplayPage + 1);
            else
                app.NextPageButton.Text = 'Next File  [Tab]';
            end
        end

        function advanceToNextPage(app)
            % Advance to the next TIFF page only for a combined CSV that spans
            % multiple pages. Per-page CSVs are pinned to their own page, so
            % advance straight to the next file instead (avoids overlaying one
            % channel's detections on another channel's image).
            if app.CsvSpansMultiplePages && ~isempty(app.ActiveTiffInfo) && ...
                    numel(app.ActiveTiffInfo) > 1
                nextPage = app.ActiveDisplayPage + 1;
                if nextPage <= numel(app.ActiveTiffInfo)
                    app.TiffPageSpinner.Value = nextPage;
                    app.onTiffPageChanged();
                    return
                end
            end
            % No more pages (or page is locked to this CSV) — advance to next file
            app.loadNextFileAndFindNeighbors();
        end

        % --------------------------------------------------------------
        % RESOLUTION ACTIONS
        % --------------------------------------------------------------

        function [rowA, rowB, ok] = activePairRows(app)
            rowA = NaN; rowB = NaN; ok = false;
            if isnan(app.SelectedPairIndex) || app.SelectedPairIndex < 1 || ...
                    app.SelectedPairIndex > size(app.NeighborPairs, 1)
                return
            end
            rowA = app.NeighborPairs(app.SelectedPairIndex, 1);
            rowB = app.NeighborPairs(app.SelectedPairIndex, 2);
            ok = true;
        end

        function doKeepA(app)
            [rowA, rowB, ok] = app.activePairRows();
            if ~ok, return; end
            app.pushUndo(rowA, rowB, NaN);
            app.ActiveLocTable.CURATED_Deleted(rowB) = true;
            app.PairStatus(app.SelectedPairIndex) = app.STATUS_KEEP_A;
            app.Dirty = true;
            app.afterAction(true);
        end

        function doKeepB(app)
            [rowA, rowB, ok] = app.activePairRows();
            if ~ok, return; end
            app.pushUndo(rowA, rowB, NaN);
            app.ActiveLocTable.CURATED_Deleted(rowA) = true;
            app.PairStatus(app.SelectedPairIndex) = app.STATUS_KEEP_B;
            app.Dirty = true;
            app.afterAction(true);
        end

        function doKeepBoth(app)
            [rowA, rowB, ok] = app.activePairRows();
            if ~ok, return; end
            app.pushUndo(rowA, rowB, NaN);
            app.PairStatus(app.SelectedPairIndex) = app.STATUS_KEEP_BOTH;
            app.Dirty = true;
            app.afterAction(true);
        end

        function doSkip(app)
            [rowA, rowB, ok] = app.activePairRows();
            if ~ok, return; end
            app.pushUndo(rowA, rowB, NaN);
            app.PairStatus(app.SelectedPairIndex) = app.STATUS_SKIPPED;
            app.Dirty = true;
            app.afterAction(false);
        end

        function onShowPointsChanged(app)
            vis = "on";
            if ~app.ShowPointsCheckBox.Value
                vis = "off";
            end
            if ~isempty(app.TissueAllPointsHandle) && isvalid(app.TissueAllPointsHandle)
                app.TissueAllPointsHandle.Visible = vis;
            end
            if ~isempty(app.TissueNeighborPointsHandle) && isvalid(app.TissueNeighborPointsHandle)
                app.TissueNeighborPointsHandle.Visible = vis;
            end
            if ~isempty(app.TissuePointAHandle) && isvalid(app.TissuePointAHandle)
                app.TissuePointAHandle.Visible = vis;
            end
            if ~isempty(app.TissuePointBHandle) && isvalid(app.TissuePointBHandle)
                app.TissuePointBHandle.Visible = vis;
            end
        end

        function armDeletePoint(app)
            app.cancelMerge();
            app.cancelRelocatePoint();
            app.cancelAddPoint();
            app.DeletePointArmed = true;
            app.DeletePointButton.BackgroundColor = [0.85 0.2 0.2];
            app.DeletePointButton.FontColor = [1 1 1];
            app.DeletePointButton.Text = 'Click a point to delete it  [Esc cancels]';
            app.updateStatus("DELETE POINT ARMED — click any detection to remove it. Press Esc to cancel.");
        end

        function cancelDeletePoint(app)
            app.DeletePointArmed = false;
            if ~isempty(app.DeletePointButton) && isvalid(app.DeletePointButton)
                app.DeletePointButton.BackgroundColor = [0.96 0.96 0.96];
                app.DeletePointButton.FontColor = [0 0 0];
                app.DeletePointButton.Text = 'Delete Point — click to remove  [d]';
            end
        end

        function executeDeletePoint(app, xClick, yClick)
            app.cancelDeletePoint();

            liveMask = app.currentPageMask();
            x = double(app.ActiveLocTable.X);
            y = double(app.ActiveLocTable.Y);
            x(~liveMask) = Inf;
            y(~liveMask) = Inf;

            dx = x - xClick;
            dy = y - yClick;
            [minD2, rowIdx] = min(dx.^2 + dy.^2);

            if ~isfinite(minD2)
                app.updateStatus("No live point found near click.");
                return
            end

            if ~isempty(app.ActiveTiffInfo) && numel(app.ActiveTiffInfo) >= app.ActiveDisplayPage
                W = double(app.ActiveTiffInfo(app.ActiveDisplayPage).Width);
                H = double(app.ActiveTiffInfo(app.ActiveDisplayPage).Height);
                tol = max(10, 0.005 * hypot(W, H));
            else
                tol = 20;
            end

            if sqrt(minD2) > tol
                app.updateStatus("No point within click tolerance — try clicking closer.");
                return
            end

            % Push undo — affected pairs are all pairs containing rowIdx
            affectedPairs = find(app.NeighborPairs(:,1) == rowIdx | app.NeighborPairs(:,2) == rowIdx);
            app.pushUndo(rowIdx, NaN, NaN);

            % Mark deleted
            app.ActiveLocTable.CURATED_Deleted(rowIdx) = true;
            app.Dirty = true;

            % Mark all pairs containing this point as Keep A or Keep B
            for p = affectedPairs(:)'
                if app.PairStatus(p) == app.STATUS_UNRESOLVED
                    if app.NeighborPairs(p, 1) == rowIdx
                        app.PairStatus(p) = app.STATUS_KEEP_B;
                    else
                        app.PairStatus(p) = app.STATUS_KEEP_A;
                    end
                end
            end

            app.afterAction();
            app.updateStatus(sprintf('Deleted point row %d at (%.1f, %.1f).', rowIdx, x(rowIdx), y(rowIdx)));
        end

        function armAddPoint(app)
            app.cancelMerge();
            app.cancelDeletePoint();
            app.cancelRelocatePoint();
            app.AddPointArmed = true;
            app.AddPointButton.BackgroundColor = [0.2 0.6 0.3];
            app.AddPointButton.FontColor = [1 1 1];
            app.AddPointButton.Text = 'Click to place new point  [Esc cancels]';
            app.updateStatus("ADD POINT ARMED — click anywhere on the tissue plot to insert a new detection. Press Esc to cancel.");
        end

        function cancelAddPoint(app)
            app.AddPointArmed = false;
            if ~isempty(app.AddPointButton) && isvalid(app.AddPointButton)
                app.AddPointButton.BackgroundColor = [0.96 0.96 0.96];
                app.AddPointButton.FontColor = [0 0 0];
                app.AddPointButton.Text = 'Add Point — click  [n]';
            end
        end

        function executeAddPoint(app, xClick, yClick)
            app.cancelAddPoint();

            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                app.updateStatus("No CSV loaded — cannot add a point.");
                return
            end

            % Build new row: copy nearest live row as a template for non-X/Y columns
            liveMask = app.currentPageMask();
            liveIdx  = find(liveMask);
            if ~isempty(liveIdx)
                x = double(app.ActiveLocTable.X(liveIdx));
                y = double(app.ActiveLocTable.Y(liveIdx));
                [~, nearest] = min((x - xClick).^2 + (y - yClick).^2);
                templateRow = liveIdx(nearest);
            else
                templateRow = 1;
            end

            newRow = app.ActiveLocTable(templateRow, :);
            newRow.X              = xClick;
            newRow.Y              = yClick;
            newRow.CURATED_Deleted     = false;
            newRow.CURATED_MergedRow   = false;
            newRow.CURATED_OriginalRow = NaN;     % marks as manually added
            newRow.CURATED_OrigX       = xClick;
            newRow.CURATED_OrigY       = yClick;

            newRowIdx = height(app.ActiveLocTable) + 1;
            app.pushUndoAddPoint(newRowIdx);

            app.ActiveLocTable = [app.ActiveLocTable; newRow];
            app.Dirty = true;

            app.updateTissueAllPoints();
            app.updateStatus(sprintf('Added new point (row %d) at (%.1f, %.1f).', newRowIdx, xClick, yClick));
        end

        function armRelocatePoint(app)
            app.cancelMerge();
            app.cancelDeletePoint();
            app.cancelAddPoint();
            app.RelocatePointArmed  = true;
            app.RelocateSelectedRow = NaN;
            app.RelocatePointButton.BackgroundColor = [0.85 0.6 0.0];
            app.RelocatePointButton.FontColor = [1 1 1];
            app.RelocatePointButton.Text = 'Click a point to select it  [Esc cancels]';
            app.updateStatus("RELOCATE ARMED — click a detection to select it, then click a new position to move it. Press Esc to cancel.");
        end

        function cancelRelocatePoint(app)
            app.RelocatePointArmed  = false;
            app.RelocateSelectedRow = NaN;
            % Remove highlight scatter
            if ~isempty(app.TissueRelocateHandle) && isvalid(app.TissueRelocateHandle)
                delete(app.TissueRelocateHandle);
            end
            app.TissueRelocateHandle = [];
            if ~isempty(app.RelocatePointButton) && isvalid(app.RelocatePointButton)
                app.RelocatePointButton.BackgroundColor = [0.96 0.96 0.96];
                app.RelocatePointButton.FontColor = [0 0 0];
                app.RelocatePointButton.Text = 'Relocate Point — click  [r]';
            end
        end

        function executeRelocateClick(app, xClick, yClick)
            liveMask = app.currentPageMask();
            x = double(app.ActiveLocTable.X);
            y = double(app.ActiveLocTable.Y);

            if ~isempty(app.ActiveTiffInfo) && numel(app.ActiveTiffInfo) >= app.ActiveDisplayPage
                W = double(app.ActiveTiffInfo(app.ActiveDisplayPage).Width);
                H = double(app.ActiveTiffInfo(app.ActiveDisplayPage).Height);
                tol = max(10, 0.005 * hypot(W, H));
            else
                tol = 20;
            end

            if isnan(app.RelocateSelectedRow)
                % First click — pick a point
                xLive = x; yLive = y;
                xLive(~liveMask) = Inf; yLive(~liveMask) = Inf;
                [minD2, rowIdx] = min((xLive - xClick).^2 + (yLive - yClick).^2);
                if ~isfinite(minD2) || sqrt(minD2) > tol
                    app.updateStatus("No point within click tolerance — try clicking closer.");
                    return
                end
                app.RelocateSelectedRow = rowIdx;

                % Highlight selected point with a large yellow diamond
                hold(app.TissueAxes, 'on');
                if ~isempty(app.TissueRelocateHandle) && isvalid(app.TissueRelocateHandle)
                    delete(app.TissueRelocateHandle);
                end
                app.TissueRelocateHandle = scatter(app.TissueAxes, x(rowIdx), y(rowIdx), 200, ...
                    'd', 'filled', ...
                    'MarkerFaceColor', [1 0.9 0.1], ...
                    'MarkerEdgeColor', [0.6 0.5 0], ...
                    'LineWidth', 2, ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none');
                hold(app.TissueAxes, 'off');

                app.RelocatePointButton.Text = 'Click new position to move  [Esc cancels]';
                app.updateStatus(sprintf('Row %d selected (%.1f, %.1f) — click the new position to relocate it.', ...
                    rowIdx, x(rowIdx), y(rowIdx)));
            else
                % Second click — move the point
                rowIdx = app.RelocateSelectedRow;
                oldX = x(rowIdx);
                oldY = y(rowIdx);

                app.pushUndoRelocation(rowIdx, oldX, oldY);

                app.ActiveLocTable.X(rowIdx) = xClick;
                app.ActiveLocTable.Y(rowIdx) = yClick;
                app.Dirty = true;

                app.cancelRelocatePoint();
                app.updateTissueAllPoints();
                app.updateTissueHighlights();
                app.updateStatus(sprintf('Moved row %d from (%.1f, %.1f) to (%.1f, %.1f).', ...
                    rowIdx, oldX, oldY, xClick, yClick));
            end
        end

        function armMerge(app)
            [~, ~, ok] = app.activePairRows();
            if ~ok
                uialert(app.UIFigure, 'Select a neighbor pair first.', 'No pair selected');
                return
            end
            app.cancelDeletePoint();
            app.cancelRelocatePoint();
            app.cancelAddPoint();
            app.MergeArmed = true;
            app.MergeButton.BackgroundColor = [1 0.65 0];
            app.MergeButton.FontColor = [0 0 0];
            app.MergeButton.Text = 'Click tissue plot to place... [Esc cancels]';
            app.updateStatus("MERGE ARMED — click on the tissue plot to place the merged cell. Press Esc to cancel.");
        end

        function cancelMerge(app)
            app.MergeArmed = false;
            if ~isempty(app.MergeButton) && isvalid(app.MergeButton)
                app.MergeButton.BackgroundColor = [0.96 0.96 0.96];
                app.MergeButton.FontColor = [0 0 0];
                app.MergeButton.Text = 'Merge — click to place  [m]';
            end
        end

        function executeMerge(app, xNew, yNew)
            [rowA, rowB, ok] = app.activePairRows();
            if ~ok
                app.cancelMerge();
                return
            end

            app.pushUndo(rowA, rowB, height(app.ActiveLocTable) + 1);

            % Build merged row from rowA as template
            newRow = app.ActiveLocTable(rowA, :);
            newRow.X = xNew;
            newRow.Y = yNew;

            % Average score/rescore if present
            names = string(app.ActiveLocTable.Properties.VariableNames);
            for colName = ["score", "rescore"]
                idx = find(strcmpi(names, colName), 1);
                if ~isempty(idx)
                    vA = double(app.ActiveLocTable.(char(names(idx)))(rowA));
                    vB = double(app.ActiveLocTable.(char(names(idx)))(rowB));
                    newRow.(char(names(idx))) = mean([vA, vB], 'omitnan');
                end
            end

            newRow.CURATED_Deleted    = false;
            newRow.CURATED_MergedRow  = true;
            newRow.CURATED_OriginalRow = NaN;

            app.ActiveLocTable = [app.ActiveLocTable; newRow];
            app.ActiveLocTable.CURATED_Deleted(rowA) = true;
            app.ActiveLocTable.CURATED_Deleted(rowB) = true;

            app.PairStatus(app.SelectedPairIndex) = app.STATUS_MERGED;
            app.Dirty = true;
            app.cancelMerge();
            app.afterAction();
            app.updateStatus(sprintf('Merged pair %d-%d at (%.1f, %.1f).', rowA, rowB, xNew, yNew));
        end

        function afterAction(app, doAdvance)
            if nargin < 2, doAdvance = false; end
            app.updateTissueAllPoints();
            app.updateTissueHighlights();
            app.updatePairTable();
            app.updatePairProgressLabel();
            app.updatePairDetailLabel();

            if app.AutoSaveCheckBox.Value
                app.saveResolved();
            end

            if doAdvance && app.AutoAdvanceCheckBox.Value
                app.advanceToNextUnresolved();
            end
        end

        % --------------------------------------------------------------
        % UNDO
        % --------------------------------------------------------------

        function pushUndo(app, rowA, rowB, mergedRowIdx)
            state.Kind         = 'action';
            state.PairIndex    = app.SelectedPairIndex;
            if ~isnan(app.SelectedPairIndex) && app.SelectedPairIndex >= 1 && ...
                    app.SelectedPairIndex <= numel(app.PairStatus)
                state.PairStatus = app.PairStatus(app.SelectedPairIndex);
            else
                state.PairStatus = [];
            end
            state.RowA         = rowA;
            state.RowB         = rowB;
            state.DeletedA     = app.ActiveLocTable.CURATED_Deleted(rowA);
            state.DeletedB     = isnan(rowB) || app.ActiveLocTable.CURATED_Deleted(rowB);
            state.MergedRowIdx = mergedRowIdx;
            state.TableHeight  = height(app.ActiveLocTable);

            app.UndoStack{end+1} = state;
            if numel(app.UndoStack) > app.MaxUndoDepth
                app.UndoStack(1) = [];
            end
        end

        function pushUndoAddPoint(app, newRowIdx)
            state.Kind      = 'addpoint';
            state.RowIdx    = newRowIdx;
            app.UndoStack{end+1} = state;
            if numel(app.UndoStack) > app.MaxUndoDepth
                app.UndoStack(1) = [];
            end
        end

        function pushUndoRelocation(app, rowIdx, oldX, oldY)
            state.Kind   = 'relocate';
            state.RowIdx = rowIdx;
            state.OldX   = oldX;
            state.OldY   = oldY;

            app.UndoStack{end+1} = state;
            if numel(app.UndoStack) > app.MaxUndoDepth
                app.UndoStack(1) = [];
            end
        end

        function undoLast(app)
            if isempty(app.UndoStack)
                app.updateStatus("Nothing to undo.");
                return
            end

            state = app.UndoStack{end};
            app.UndoStack(end) = [];

            if strcmp(state.Kind, 'addpoint')
                % Remove the appended row
                if state.RowIdx <= height(app.ActiveLocTable)
                    app.ActiveLocTable(state.RowIdx:end, :) = [];
                end
                app.Dirty = true;
                app.updateTissueAllPoints();
                app.updateTissueHighlights();
                app.updateStatus("Undo: removed added point.");
                return
            end

            if strcmp(state.Kind, 'relocate')
                % Restore X/Y coordinates
                if state.RowIdx >= 1 && state.RowIdx <= height(app.ActiveLocTable)
                    app.ActiveLocTable.X(state.RowIdx) = state.OldX;
                    app.ActiveLocTable.Y(state.RowIdx) = state.OldY;
                end
                app.Dirty = true;
                app.updateTissueAllPoints();
                app.updateTissueHighlights();
                app.updateStatus(sprintf('Undo: restored row %d to (%.1f, %.1f).', ...
                    state.RowIdx, state.OldX, state.OldY));
                return
            end

            % Kind == 'action'
            % Restore pair status
            if state.PairIndex >= 1 && state.PairIndex <= numel(app.PairStatus)
                app.PairStatus(state.PairIndex) = state.PairStatus;
            end

            % Restore deleted flags
            if state.RowA >= 1 && state.RowA <= height(app.ActiveLocTable)
                app.ActiveLocTable.CURATED_Deleted(state.RowA) = state.DeletedA;
            end
            if ~isnan(state.RowB) && state.RowB >= 1 && state.RowB <= height(app.ActiveLocTable)
                app.ActiveLocTable.CURATED_Deleted(state.RowB) = state.DeletedB;
            end

            % Remove merged row if it was added
            if ~isnan(state.MergedRowIdx) && state.TableHeight < height(app.ActiveLocTable)
                app.ActiveLocTable(state.MergedRowIdx:end, :) = [];
            end

            app.SelectedPairIndex = state.PairIndex;
            app.Dirty = true;

            app.updateTissueAllPoints();
            app.updateTissueHighlights();
            app.updatePairTable();
            app.updatePairProgressLabel();
            app.updatePairDetailLabel();
            app.updateStatus("Undo complete.");
        end

        % --------------------------------------------------------------
        % SAVE
        % --------------------------------------------------------------

        function saveResolved(app)
            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                app.updateStatus("Nothing to save — no CSV loaded.");
                return
            end
            if strlength(app.ActiveCsvPath) == 0
                app.updateStatus("No source CSV path known — cannot save.");
                return
            end

            resolvedPath = app.ActiveCsvPath;

            % ---- Build output table ----
            % Strategy: keep ALL original rows (rows where CURATED_MergedRow == false).
            % Append one row per Merged pair for the new merged point.
            % Output columns CURATED_X, CURATED_Y carry the "effective" coordinates:
            %   - original unmodified row  → CURATED_X = current X (may differ if relocated)
            %   - deleted row              → CURATED_X = NaN, CURATED_Y = NaN
            %   - merged-origin row        → CURATED_X = NaN, CURATED_Y = NaN
            %   - merged-result row        → CURATED_X = merged X, CURATED_Y = merged Y

            origMask = ~app.ActiveLocTable.CURATED_MergedRow;
            outTbl = app.ActiveLocTable(origMask, :);

            nOrig = height(outTbl);

            % Strip all runtime columns — we will build CURATED_X/CURATED_Y fresh
            runtimeCols = {'CURATED_Deleted','CURATED_MergedRow','CURATED_OriginalRow','CURATED_OrigX','CURATED_OrigY'};
            for k = 1:numel(runtimeCols)
                if ismember(runtimeCols{k}, outTbl.Properties.VariableNames)
                    outTbl.(runtimeCols{k}) = [];
                end
            end

            % CURATED_X / CURATED_Y: start as current X/Y, then blank deleted rows
            outTbl.CURATED_X = double(outTbl.X);
            outTbl.CURATED_Y = double(outTbl.Y);

            % Annotation columns
            outTbl.NeighborResolved       = false(nOrig, 1);
            outTbl.NeighborResolvedStatus = strings(nOrig, 1);
            outTbl.NeighborPairID         = strings(nOrig, 1);

            % Map from original row number → output table row index
            origRowNums = app.ActiveLocTable.CURATED_OriginalRow(origMask);

            for p = 1:size(app.NeighborPairs, 1)
                st = app.PairStatus(p);
                rA = app.NeighborPairs(p, 1);
                rB = app.NeighborPairs(p, 2);
                pairLabel = string(rA) + "-" + string(rB);

                idxA = find(origRowNums == rA, 1);
                idxB = find(origRowNums == rB, 1);

                % Always write pair ID and status so the file can report total
                % and unreviewed pair counts without re-running detection.
                for idx = [idxA, idxB]
                    if ~isempty(idx)
                        outTbl.NeighborPairID(idx)         = pairLabel;
                        outTbl.NeighborResolvedStatus(idx) = st;
                    end
                end

                if st == app.STATUS_UNRESOLVED || st == app.STATUS_SKIPPED
                    continue
                end

                % Mark resolved rows
                for idx = [idxA, idxB]
                    if ~isempty(idx)
                        outTbl.NeighborResolved(idx) = true;
                    end
                end

                if st == app.STATUS_KEEP_A
                    % B is deleted
                    if ~isempty(idxB)
                        outTbl.CURATED_X(idxB) = NaN;
                        outTbl.CURATED_Y(idxB) = NaN;
                    end
                elseif st == app.STATUS_KEEP_B
                    % A is deleted
                    if ~isempty(idxA)
                        outTbl.CURATED_X(idxA) = NaN;
                        outTbl.CURATED_Y(idxA) = NaN;
                    end
                elseif st == app.STATUS_MERGED
                    % Both originals are nulled; find the appended merged row
                    if ~isempty(idxA), outTbl.CURATED_X(idxA) = NaN; outTbl.CURATED_Y(idxA) = NaN; end
                    if ~isempty(idxB), outTbl.CURATED_X(idxB) = NaN; outTbl.CURATED_Y(idxB) = NaN; end

                    % Find the merged-result row in ActiveLocTable (CURATED_MergedRow == true)
                    % that was appended for this pair. We use order of appending:
                    % match by proximity — merged rows untagged so far
                    mergedRows = find(app.ActiveLocTable.CURATED_MergedRow);
                    % Pick the first merged row whose X/Y is not already in outTbl
                    for mri = mergedRows(:)'
                        mX = double(app.ActiveLocTable.X(mri));
                        mY = double(app.ActiveLocTable.Y(mri));
                        % Append a new output row copied from rowA template
                        if ~isempty(idxA)
                            newRow = outTbl(idxA, :);
                        else
                            newRow = outTbl(1, :);
                        end
                        newRow.X = mX; newRow.Y = mY;
                        newRow.CURATED_X = mX; newRow.CURATED_Y = mY;
                        newRow.NeighborResolved       = true;
                        newRow.NeighborResolvedStatus = st;
                        newRow.NeighborPairID         = pairLabel;
                        outTbl = [outTbl; newRow]; %#ok<AGROW>
                        break
                    end
                end
            end

            % Null CURATED_X/CURATED_Y for any deleted row not already nulled (e.g. standalone deletes)
            for r = 1:nOrig
                origR = origRowNums(r);
                if ~isnan(origR) && origR >= 1 && origR <= height(app.ActiveLocTable)
                    if app.ActiveLocTable.CURATED_Deleted(origR) && ~isnan(outTbl.CURATED_X(r))
                        outTbl.CURATED_X(r) = NaN;
                        outTbl.CURATED_Y(r) = NaN;
                    end
                end
            end

            nOut = height(outTbl);

            % Atomic write
            tmpPath = char(string(resolvedPath) + ".tmp_" + ...
                string(char(java.util.UUID.randomUUID())) + ".csv");
            try
                writetable(outTbl, tmpPath);
            catch ME
                app.updateStatus("Save failed: " + string(ME.message));
                if isfile(tmpPath), delete(tmpPath); end
                return
            end

            if isfile(char(resolvedPath))
                delete(char(resolvedPath));
            end
            movefile(tmpPath, char(resolvedPath), 'f');

            app.Dirty = false;
            app.markActiveFileReviewed();
            app.updateStatus(sprintf('Saved %d rows → %s', nOut, ...
                char(CellToolkit.makeRelativePath(char(app.ActiveCsvPath), char(app.ParentDirectory)))));
        end

        function saveIfDirty(app)
            if app.Dirty && ~isempty(app.ActiveLocTable) && height(app.ActiveLocTable) > 0
                choice = uiconfirm(app.UIFigure, ...
                    'Save changes back to the original CSV before switching?', ...
                    'Unsaved Changes', ...
                    'Options', {'Save', 'Discard', 'Cancel'}, ...
                    'DefaultOption', 'Save', ...
                    'CancelOption', 'Cancel');
                if strcmp(choice, 'Save')
                    app.saveResolved();
                elseif strcmp(choice, 'Cancel')
                    error('CellNeighborResolverApp:Cancelled', 'User cancelled transition.');
                end
            end
        end

        % --------------------------------------------------------------
        % KEYBOARD
        % --------------------------------------------------------------

        function handleKeyPress(app, ~, event)
            key = string(event.Key);
            mods = string(event.Modifier);
            isCtrl = any(mods == "control");

            % Disarm escape
            if key == "escape"
                if app.MergeArmed
                    app.cancelMerge();
                    app.updateStatus("Merge cancelled.");
                elseif app.DeletePointArmed
                    app.cancelDeletePoint();
                    app.updateStatus("Delete point cancelled.");
                elseif app.RelocatePointArmed
                    app.cancelRelocatePoint();
                    app.updateStatus("Relocate cancelled.");
                elseif app.AddPointArmed
                    app.cancelAddPoint();
                    app.updateStatus("Add point cancelled.");
                end
                return
            end

            % Ctrl combos
            if isCtrl
                switch key
                    case "z"
                        app.undoLast();
                    case "s"
                        app.saveResolved();
                end
                return
            end

            % Don't handle plain keys when a text field has focus
            if app.currentObjectIsTextEntry()
                return
            end

            switch key
                case "a"
                    app.doKeepA();
                case "b"
                    app.doKeepB();
                case {"k", "space"}
                    app.doKeepBoth();
                case "m"
                    app.armMerge();
                case "d"
                    app.armDeletePoint();
                case "r"
                    app.armRelocatePoint();
                case "n"
                    app.armAddPoint();
                case "p"
                    app.ShowPointsCheckBox.Value = ~app.ShowPointsCheckBox.Value;
                    app.onShowPointsChanged();
                case "f"
                    app.resetTissueView();
                case "s"
                    app.doSkip();
                case "tab"
                    app.advanceToNextPage();
                case {"j", "leftarrow"}
                    app.navigatePairs(-1);
                case {"l", "rightarrow"}
                    app.navigatePairs(+1);
            end
        end

        function result = currentObjectIsTextEntry(app)
            result = false;
            try
                obj = app.UIFigure.CurrentObject;
                if isempty(obj) || ~isvalid(obj)
                    return
                end
                className = class(obj);
                result = contains(className, {'EditField', 'TextArea', 'Spinner'}, 'IgnoreCase', true);
            catch
            end
        end

        % --------------------------------------------------------------
        % WINDOW LIFECYCLE
        % --------------------------------------------------------------

        function handleCloseRequest(app, ~, ~)
            try
                app.saveIfDirty();
            catch ME
                if ~strcmp(ME.identifier, 'CellNeighborResolverApp:Cancelled')
                    % Unexpected error — log but don't block close
                end
            end
            app.saveSettings();
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                delete(app.UIFigure);
            end
        end

        % --------------------------------------------------------------
        % STATUS
        % --------------------------------------------------------------

        function updateStatus(app, msg)
            if ~isempty(app.StatusLabel) && isvalid(app.StatusLabel)
                app.StatusLabel.Text = char(string(msg));
            end
        end

        % --------------------------------------------------------------
        % RESCORING (Stage 2)
        % --------------------------------------------------------------
        %
        % After curation, run a Stage-2 scoring model (rescore.py) in the
        % countpnn conda env over the curated detections of one or more
        % datasets. Only live points (CURATED_X/Y not blanked, or X/Y when a
        % CSV has no curation columns) are scored; the model's [0-1] quality
        % estimate is written back to each CSV's 'rescore' column.

        function discoverScoringModels(app)
            % Stage-2 scoring models rescore.py can load: run folders under the
            % repo root that contain best.pth and are not detection models.
            [~, app.ScoringModels] = CellToolkit.discoverModels(char(app.RepoRoot));
        end

        function onRescoreButtonPushed(app)
            app.discoverScoringModels();   % refresh in case models were added
            if isempty(app.ScoringModels)
                uialert(app.UIFigure, sprintf(['No scoring models found in:\n%s\n\n' ...
                    'A scoring model is a run folder containing best.pth whose name does ' ...
                    'not contain "fasterrcnn" (e.g. pnn_v2_scoring_rank_learning).'], ...
                    char(app.RepoRoot)), 'No scoring models');
                return
            end
            if isempty(app.AllAbsFiles)
                uialert(app.UIFigure, 'Scan a directory for CSV files first.', 'Nothing to rescore');
                return
            end
            cfg = app.showRescoreDialog();
            if isempty(cfg)
                return   % cancelled
            end
            app.runRescore(cfg);
        end

        function cfg = showRescoreDialog(app)
            % Modal configuration dialog. Returns a config struct, or [] if the
            % user cancels.
            cfg = [];
            S = app.Settings;

            dlg = uifigure('Name', 'Rescore Curated Detections', ...
                'Position', [100 100 470 330], 'WindowStyle', 'modal');
            try
                mp = app.UIFigure.Position;
                dlg.Position(1:2) = [mp(1) + (mp(3)-470)/2, mp(2) + (mp(4)-330)/2];
            catch
            end

            g = uigridlayout(dlg, [8 3]);
            g.RowHeight   = {26, 26, 26, 26, 26, 26, '1x', 32};
            g.ColumnWidth = {105, '1x', 70};
            g.Padding     = [12 12 12 12];
            g.RowSpacing  = 6;
            g.ColumnSpacing = 6;

            % Row 1: scoring model
            lblM = uilabel(g, 'Text', 'Scoring model:', 'HorizontalAlignment', 'right');
            lblM.Layout.Row = 1; lblM.Layout.Column = 1;
            ddModel = uidropdown(g, 'Items', app.ScoringModels);
            ddModel.Layout.Row = 1; ddModel.Layout.Column = [2 3];
            if any(strcmp(app.ScoringModels, char(S.LastScoringModel)))
                ddModel.Value = char(S.LastScoringModel);
            end

            % Row 2: scope
            lblS = uilabel(g, 'Text', 'Apply to:', 'HorizontalAlignment', 'right');
            lblS.Layout.Row = 2; lblS.Layout.Column = 1;
            ddScope = uidropdown(g, 'Items', ...
                {'Included files', 'Active file only', 'All scanned files'});
            ddScope.Layout.Row = 2; ddScope.Layout.Column = [2 3];
            CellToolkit.setDropDownValue(ddScope, char(S.RescoreScope));

            % Row 3: device
            lblD = uilabel(g, 'Text', 'Device:', 'HorizontalAlignment', 'right');
            lblD.Layout.Row = 3; lblD.Layout.Column = 1;
            edDevice = uieditfield(g, 'text', 'Value', char(S.RescoreDevice));
            edDevice.Layout.Row = 3; edDevice.Layout.Column = [2 3];
            edDevice.Tooltip = "Torch device, e.g. cpu, cuda:0";

            % Row 4: batch size
            lblB = uilabel(g, 'Text', 'Batch size:', 'HorizontalAlignment', 'right');
            lblB.Layout.Row = 4; lblB.Layout.Column = 1;
            spBatch = uispinner(g, 'Limits', [1 4096], 'RoundFractionalValues', 'on', ...
                'Value', max(1, double(S.RescoreBatchSize)));
            spBatch.Layout.Row = 4; spBatch.Layout.Column = [2 3];

            % Row 5: conda env
            lblE = uilabel(g, 'Text', 'Conda env:', 'HorizontalAlignment', 'right');
            lblE.Layout.Row = 5; lblE.Layout.Column = 1;
            edEnv = uieditfield(g, 'text', 'Value', char(S.CondaEnv));
            edEnv.Layout.Row = 5; edEnv.Layout.Column = [2 3];
            edEnv.Tooltip = "Conda environment to run rescore.py in. Leave blank to call Python directly.";

            % Row 6: conda exe + browse
            lblC = uilabel(g, 'Text', 'conda.exe:', 'HorizontalAlignment', 'right');
            lblC.Layout.Row = 6; lblC.Layout.Column = 1;
            edConda = uieditfield(g, 'text', 'Value', char(S.CondaExe));
            edConda.Layout.Row = 6; edConda.Layout.Column = 2;
            edConda.Tooltip = "Full path to conda.exe / conda.bat (auto-detected). Used only when a conda env is set.";
            btnBrowse = uibutton(g, 'push', 'Text', 'Browse', ...
                'ButtonPushedFcn', @(s,e) onBrowseConda());
            btnBrowse.Layout.Row = 6; btnBrowse.Layout.Column = 3;

            % Row 7: info
            info = uilabel(g, 'Text', sprintf(['Runs rescore.py per dataset in the conda env. ' ...
                'Only curated live points are scored; results are written to each ' ...
                'CSV''s "rescore" column. Repo: %s'], char(app.RepoRoot)), ...
                'WordWrap', 'on', 'FontColor', [0.4 0.4 0.4], 'VerticalAlignment', 'top');
            info.Layout.Row = 7; info.Layout.Column = [1 3];

            % Row 8: Run / Cancel
            btnGrid = uigridlayout(g, [1 3]);
            btnGrid.Layout.Row = 8; btnGrid.Layout.Column = [1 3];
            btnGrid.ColumnWidth = {'1x', 100, 100};
            btnGrid.Padding = [0 0 0 0];
            uilabel(btnGrid, 'Text', '');
            btnRun = uibutton(btnGrid, 'push', 'Text', 'Rescore', ...
                'BackgroundColor', [0.25 0.6 0.35], 'FontColor', [1 1 1], ...
                'FontWeight', 'bold', 'ButtonPushedFcn', @(s,e) onRun());
            btnRun.Layout.Column = 2;
            btnCancel = uibutton(btnGrid, 'push', 'Text', 'Cancel', ...
                'ButtonPushedFcn', @(s,e) onCancel());
            btnCancel.Layout.Column = 3;

            uiwait(dlg);
            return

            function onBrowseConda()
                [f, p] = uigetfile({'*.exe;*.bat', 'conda executable (*.exe, *.bat)'; ...
                    '*', 'All Files (*)'}, 'Select conda executable');
                if isequal(f, 0), return; end
                edConda.Value = fullfile(p, f);
                figure(dlg);   % restore modal focus
            end

            function onRun()
                cfg = struct();
                cfg.model      = string(ddModel.Value);
                cfg.scope      = string(ddScope.Value);
                cfg.device     = string(strtrim(edDevice.Value));
                cfg.batchSize  = spBatch.Value;
                cfg.condaEnv   = string(strtrim(edEnv.Value));
                cfg.condaExe   = string(strtrim(edConda.Value));
                cfg.pythonExe  = string(app.Settings.PythonExe);
                if strlength(cfg.pythonExe) == 0, cfg.pythonExe = "python"; end

                % Persist choices
                app.Settings.LastScoringModel = cfg.model;
                app.Settings.RescoreScope     = cfg.scope;
                app.Settings.RescoreDevice    = cfg.device;
                app.Settings.RescoreBatchSize = cfg.batchSize;
                app.Settings.CondaEnv         = cfg.condaEnv;
                app.Settings.CondaExe         = cfg.condaExe;
                app.saveSettings();

                uiresume(dlg);
                delete(dlg);
            end

            function onCancel()
                cfg = [];
                uiresume(dlg);
                delete(dlg);
            end
        end

        function runRescore(app, cfg)
            % Resolve the set of target CSV files, then rescore each in turn.
            switch char(cfg.scope)
                case 'Active file only'
                    if strlength(app.ActiveCsvPath) == 0
                        uialert(app.UIFigure, 'No active file is loaded.', 'Nothing to rescore');
                        return
                    end
                    if app.Dirty, app.saveResolved(); end
                    targets = {char(app.ActiveCsvPath)};
                case 'All scanned files'
                    if app.Dirty && strlength(app.ActiveCsvPath) > 0, app.saveResolved(); end
                    targets = app.AllAbsFiles;
                otherwise   % 'Included files'
                    if app.Dirty && strlength(app.ActiveCsvPath) > 0, app.saveResolved(); end
                    inc = app.FileInclude;
                    if numel(inc) ~= numel(app.AllAbsFiles)
                        inc = true(numel(app.AllAbsFiles), 1);
                    end
                    targets = app.AllAbsFiles(logical(inc));
            end
            if isempty(targets)
                uialert(app.UIFigure, 'No target files selected for rescoring.', 'Nothing to rescore');
                return
            end

            % Verify the Python environment once before looping.
            app.updateStatus("Checking Python environment for rescoring...");
            drawnow
            [ok, envMsg] = app.testRescoreEnv(cfg);
            if ~ok
                uialert(app.UIFigure, envMsg, 'Python environment not ready');
                app.updateStatus("Rescoring aborted: Python environment not ready.");
                return
            end

            n = numel(targets);
            dlg = uiprogressdlg(app.UIFigure, 'Title', 'Rescoring datasets', ...
                'Message', sprintf('Starting... (0/%d)', n), ...
                'Cancelable', 'on', 'Value', 0);
            guard = onCleanup(@() app.closeProgress(dlg));

            nOk = 0; nSkip = 0; nErr = 0;
            for i = 1:n
                if dlg.CancelRequested
                    break
                end
                csvPath = targets{i};
                [~, nm, ex] = fileparts(csvPath);
                dlg.Value   = (i - 1) / n;
                dlg.Message = sprintf('(%d/%d) %s', i, n, [nm ex]);
                drawnow

                try
                    st = app.rescoreOneFile(csvPath, cfg);
                catch ME
                    st = "error: " + string(ME.message);
                end

                if startsWith(st, "ok")
                    nOk = nOk + 1;
                elseif startsWith(st, "skip")
                    nSkip = nSkip + 1;
                else
                    nErr = nErr + 1;
                end
                fprintf('[RESCORE] (%d/%d) %s -> %s\n', i, n, [nm ex], char(st));
            end

            clear guard   % closes the progress dialog

            app.updateStatus(sprintf('Rescore complete: %d scored, %d skipped, %d error(s).', ...
                nOk, nSkip, nErr));

            % Reload the active file so its refreshed 'rescore' column is reflected.
            if strlength(app.ActiveCsvPath) > 0 && isfile(char(app.ActiveCsvPath))
                try
                    app.loadCsvFile(app.ActiveCsvPath);
                catch
                end
            end
        end

        function st = rescoreOneFile(app, csvPath, cfg)
            % Rescore a single curated CSV in place. Returns a short status
            % string beginning with "ok", "skip", or "error".
            csvPath = string(csvPath);

            T  = readtable(char(csvPath), 'VariableNamingRule', 'preserve');
            vn = string(T.Properties.VariableNames);
            n  = height(T);
            if ~all(ismember(["X", "Y"], vn))
                st = "skip: CSV missing X/Y columns";
                return
            end

            % Determine live points and their effective coordinates.
            if all(ismember(["CURATED_X", "CURATED_Y"], vn))
                cx = T.CURATED_X; cy = T.CURATED_Y;
                if ~isnumeric(cx), cx = str2double(string(cx)); end
                if ~isnumeric(cy), cy = str2double(string(cy)); end
                ex = cx; ey = cy;
            else
                ex = T.X; ey = T.Y;
                if ~isnumeric(ex), ex = str2double(string(ex)); end
                if ~isnumeric(ey), ey = str2double(string(ey)); end
            end
            live = ~isnan(ex) & ~isnan(ey);
            keys = find(live);
            if isempty(keys)
                st = "skip: no live points";
                return
            end

            % Reject combined CSVs that span multiple TIFF pages: rescoring
            % crops patches from a single extracted page, so a multi-page CSV
            % cannot be handled here (curate per-page CSVs instead).
            pg = NaN;
            if ismember("imgName", vn)
                ids = cellstr(string(T.imgName));
                pp = nan(numel(ids), 1);
                for k = 1:numel(ids)
                    pp(k) = CellToolkit.pageFromIdentity(ids{k});
                end
                encPages = unique(pp(~isnan(pp)));
                if numel(encPages) > 1
                    st = "skip: combined multi-page CSV";
                    return
                elseif isscalar(encPages)
                    pg = encPages;
                end
            end
            if isnan(pg)
                pg = CellToolkit.pageFromCsvName(csvPath);
                if isnan(pg), pg = 1; end
            end

            % Locate the companion image and extract the relevant page.
            imgPath = CellToolkit.inferImagePath(csvPath);
            if strlength(imgPath) == 0 || ~isfile(imgPath)
                st = "skip: no companion image";
                return
            end
            try
                info = imfinfo(char(imgPath));
                pg   = max(1, min(pg, numel(info)));
                img  = imread(char(imgPath), pg);
            catch ME
                st = "error: could not read image (" + string(ME.message) + ")";
                return
            end

            tmpImg   = [tempname '.tif'];
            tmpInCsv = [tempname '.csv'];
            tmpOut   = [tempname '.csv'];
            cleanTmp = onCleanup(@() CellToolkit.deleteFiles({tmpImg, tmpInCsv, tmpOut}));

            try
                imwrite(img, tmpImg);
            catch ME
                st = "error: could not write temp image (" + string(ME.message) + ")";
                return
            end

            % Write the rescore input: live X/Y plus a stable key for merge-back.
            inTbl = table();
            inTbl.X           = double(ex(live));
            inTbl.Y           = double(ey(live));
            inTbl.rescore_key = keys;
            writetable(inTbl, tmpInCsv);

            % Build and run the rescore.py command in the configured env.
            [status, out] = app.runRescoreProcess(cfg, tmpInCsv, tmpImg, tmpOut);
            if status ~= 0 || ~isfile(tmpOut)
                fprintf(2, '[RESCORE] rescore.py output:\n%s\n', out);
                st = "error: rescore.py failed (exit " + string(status) + ")";
                return
            end

            % Merge the model scores back into the full table by key.
            R   = readtable(tmpOut, 'VariableNamingRule', 'preserve');
            rvn = string(R.Properties.VariableNames);
            if ~all(ismember(["rescore_key", "rescore"], rvn))
                st = "error: rescore output missing expected columns";
                return
            end
            rk = R.rescore_key; if ~isnumeric(rk), rk = str2double(string(rk)); end
            rv = R.rescore;     if ~isnumeric(rv), rv = str2double(string(rv)); end
            newScore = nan(n, 1);
            for k = 1:numel(rk)
                if rk(k) >= 1 && rk(k) <= n
                    newScore(rk(k)) = rv(k);
                end
            end
            T.rescore = newScore;

            % Atomic write back to the original CSV.
            tmpWrite = char(csvPath + ".tmp_" + ...
                string(char(java.util.UUID.randomUUID())) + ".csv");
            try
                writetable(T, tmpWrite);
            catch ME
                if isfile(tmpWrite), delete(tmpWrite); end
                st = "error: could not write CSV (" + string(ME.message) + ")";
                return
            end
            if isfile(char(csvPath)), delete(char(csvPath)); end
            movefile(tmpWrite, char(csvPath), 'f');

            st = "ok: " + string(numel(keys)) + " point(s)";
        end

        function [status, out] = runRescoreProcess(app, cfg, tmpInCsv, tmpImg, tmpOut)
            % Assemble and run the rescore.py command (optionally wrapped in
            % 'conda run'), with the repo root as the working directory so the
            % script and model-folder name resolve relative to it.
            pcfg = app.pythonConfigFromRescoreCfg(cfg);
            args = CellToolkit.rescoreArgs(char(cfg.model), tmpInCsv, struct( ...
                'image',     tmpImg, ...
                'device',    char(cfg.device), ...
                'batchSize', cfg.batchSize, ...
                'output',    tmpOut));
            cmd = CellToolkit.commandString(CellToolkit.pythonCommandParts(pcfg, args));
            fprintf('[RESCORE] CMD: %s\n', cmd);
            [status, out] = CellToolkit.runPython(pcfg, args);
        end

        function [ok, msg] = testRescoreEnv(app, cfg)
            % Quick synchronous check that hydra + torch import in the env.
            pcfg = app.pythonConfigFromRescoreCfg(cfg);
            [ok, msg] = CellToolkit.testPythonEnv(pcfg, {'hydra', 'torch'});
        end

        function pcfg = pythonConfigFromRescoreCfg(app, cfg)
            % Translate the rescore-dialog cfg into a CellToolkit python config,
            % running with the repo root as the working directory.
            pcfg = CellToolkit.pythonConfig( ...
                'PythonExe',  char(cfg.pythonExe), ...
                'CondaExe',   char(cfg.condaExe), ...
                'CondaEnv',   char(cfg.condaEnv), ...
                'WorkingDir', char(app.RepoRoot));
        end

        function closeProgress(~, dlg)
            if ~isempty(dlg) && isvalid(dlg)
                close(dlg);
            end
        end

    end

end
