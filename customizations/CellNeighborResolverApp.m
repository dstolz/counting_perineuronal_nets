classdef CellNeighborResolverApp < handle
% CellNeighborResolverApp  GUI for reviewing and resolving nearby cell detections.
%   app = CellNeighborResolverApp() opens the GUI.  Load a *_locs.csv file,
%   set a pixel-distance threshold, click "Find Neighbors" to detect pairs,
%   then resolve each pair using the action buttons or keyboard shortcuts.
%   Results are saved back to the original CSV file in place.
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
%     Escape    Cancel armed merge

    % ------------------------------------------------------------------
    properties (Constant, Access = private)
        SettingsGroup     = 'CellNeighborResolverApp'
        SettingsPrefKey   = 'Settings'
        AppVersion        = '1.0'
        MaxUndoDepth      = 200
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
        AllAbsFiles cell   = {}

        % --- Active file state ---
        ActiveCsvPath    string  = ""
        ActiveImagePath  string  = ""
        ActiveTiffInfo           = []
        ActiveImagePages struct  = struct()
        ActiveLocTable   table   = table()
        ActiveDisplayPage double = 1
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
        FileCountLabel

        % --- UI: toolbar row 2 (neighbor settings) ---
        DistanceSpinner
        FindNeighborsButton
        PairCountLabel
        AutoAdvanceCheckBox
        AutoSaveCheckBox
        SaveButton
        ShowPointsCheckBox

        % --- UI: left panel ---
        LeftPanel
        FileListBox
        FilterDropDown
        PairProgressLabel
        PairTable
        PreviousPairButton
        NextPairButton

        % --- UI: center panel ---
        CenterPanel
        TiffPageSpinner
        PairDetailLabel
        TissueAxes
        TissueImageHandle   = []
        TissueAllPointsHandle = []
        TissuePointAHandle  = []
        TissuePointBHandle  = []
        TissueContextMenu   = []

        % --- UI: right panel ---
        RightPanel
        KeepAButton
        KeepBButton
        KeepBothButton
        MergeButton
        DeletePointButton
        RelocatePointButton
        SkipButton
        UndoButton
        TissueRelocateHandle
    end

    % ==================================================================
    methods (Access = public)

        function app = CellNeighborResolverApp()
            app.loadSettings();
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
            app.setTooltip(app.StatusLabel, "Current app status: scan results, load progress, action confirmations, and error messages.");
        end

        function buildToolbar(app)
            app.TopToolbarGrid = uigridlayout(app.RootGrid, [2 9]);
            app.TopToolbarGrid.Layout.Row = 1;
            app.TopToolbarGrid.Layout.Column = 1;
            app.TopToolbarGrid.RowHeight   = {28, 28};
            app.TopToolbarGrid.ColumnWidth = {30, '2x', 70, 45, '1x', 70, '1x', 110, 100, 70};
            app.TopToolbarGrid.ColumnSpacing = 5;
            app.TopToolbarGrid.Padding = [0 4 0 4];

            % Row 1: directory scan
            lbl = uilabel(app.TopToolbarGrid, "Text", "Dir", "HorizontalAlignment", "right");
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;

            app.ParentDirEdit = uieditfield(app.TopToolbarGrid, "text", ...
                "ValueChangedFcn", @(s,e) app.onParentDirEdited(s, e));
            app.ParentDirEdit.Layout.Row = 1; app.ParentDirEdit.Layout.Column = 2;
            app.setTooltip(app.ParentDirEdit, "Parent folder to search recursively for localization CSV files. Defaults to last used folder.");

            app.BrowseButton = uibutton(app.TopToolbarGrid, "push", "Text", "Browse", ...
                "ButtonPushedFcn", @(s,e) app.chooseParentDirectory());
            app.BrowseButton.Layout.Row = 1; app.BrowseButton.Layout.Column = 3;
            app.setTooltip(app.BrowseButton, "Open a folder picker to choose the parent directory, then scan automatically.");

            lbl2 = uilabel(app.TopToolbarGrid, "Text", "Filter", "HorizontalAlignment", "right");
            lbl2.Layout.Row = 1; lbl2.Layout.Column = 4;

            app.RegexEdit = uieditfield(app.TopToolbarGrid, "text", "Value", char(app.Settings.FileRegex));
            app.RegexEdit.Layout.Row = 1; app.RegexEdit.Layout.Column = 5;
            app.setTooltip(app.RegexEdit, "Case-insensitive regular expression applied to file basenames during scan. Default: (?i)_locs\.csv$");

            app.ScanButton = uibutton(app.TopToolbarGrid, "push", "Text", "Scan", ...
                "ButtonPushedFcn", @(s,e) app.doScan());
            app.ScanButton.Layout.Row = 1; app.ScanButton.Layout.Column = 6;
            app.setTooltip(app.ScanButton, "Recursively scan the parent directory for CSV files matching the filter pattern and populate the file list.");

            app.FileCountLabel = uilabel(app.TopToolbarGrid, "Text", "No files scanned");
            app.FileCountLabel.Layout.Row = 1; app.FileCountLabel.Layout.Column = [7 10];
            app.setTooltip(app.FileCountLabel, "Number of CSV files found by the most recent scan.");

            % Row 2: neighbor settings
            lbl3 = uilabel(app.TopToolbarGrid, "Text", "Dist (px)", "HorizontalAlignment", "right");
            lbl3.Layout.Row = 2; lbl3.Layout.Column = [1 2];

            app.DistanceSpinner = uispinner(app.TopToolbarGrid, ...
                "Limits", [1 500], "Value", app.Settings.NeighborDistance, ...
                "RoundFractionalValues", "on");
            app.DistanceSpinner.Layout.Row = 2; app.DistanceSpinner.Layout.Column = 3;
            app.setTooltip(app.DistanceSpinner, "Maximum Euclidean distance in pixels between two detections for them to be considered neighbors. Default: 10.");

            app.FindNeighborsButton = uibutton(app.TopToolbarGrid, "push", ...
                "Text", "Find Neighbors", ...
                "ButtonPushedFcn", @(s,e) app.onFindNeighborsButtonPushed());
            app.FindNeighborsButton.Layout.Row = 2; app.FindNeighborsButton.Layout.Column = 4;
            app.setTooltip(app.FindNeighborsButton, "Run neighbor search on the loaded CSV using the distance threshold and populate the pair list.");

            app.PairCountLabel = uilabel(app.TopToolbarGrid, "Text", "No pairs found");
            app.PairCountLabel.Layout.Row = 2; app.PairCountLabel.Layout.Column = [5 7];
            app.setTooltip(app.PairCountLabel, "Total number of unique neighbor pairs found in the current CSV.");

            app.AutoAdvanceCheckBox = uicheckbox(app.TopToolbarGrid, "Text", "Auto-advance", ...
                "Value", app.Settings.AutoAdvance);
            app.AutoAdvanceCheckBox.Layout.Row = 2; app.AutoAdvanceCheckBox.Layout.Column = 8;
            app.setTooltip(app.AutoAdvanceCheckBox, "Automatically move to the next unresolved pair after each resolution action. Default: on.");

            app.AutoSaveCheckBox = uicheckbox(app.TopToolbarGrid, "Text", "Auto-save", ...
                "Value", app.Settings.AutoSave);
            app.AutoSaveCheckBox.Layout.Row = 2; app.AutoSaveCheckBox.Layout.Column = 9;
            app.setTooltip(app.AutoSaveCheckBox, "Automatically save the CSV back to the original file after each resolution action. Default: on.");

            app.SaveButton = uibutton(app.TopToolbarGrid, "push", "Text", "Save [Ctrl+S]", ...
                "ButtonPushedFcn", @(s,e) app.saveResolved());
            app.SaveButton.Layout.Row = 2; app.SaveButton.Layout.Column = 10;
            app.setTooltip(app.SaveButton, "Save changes back to the original CSV file, overwriting it in place. Shortcut: Ctrl+S.");
        end

        function buildMainPanels(app)
            app.MainGrid = uigridlayout(app.RootGrid, [1 3]);
            app.MainGrid.Layout.Row = 2;
            app.MainGrid.Layout.Column = 1;
            app.MainGrid.ColumnWidth  = {320, '1x', 240};
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

            g = uigridlayout(app.LeftPanel, [4 1]);
            g.RowHeight = {160, 28, '1x', 28};
            g.ColumnWidth = {'1x'};
            g.Padding = [4 4 4 4];
            g.RowSpacing = 4;

            app.FileListBox = uilistbox(g, "Items", {}, ...
                "ValueChangedFcn", @(s,e) app.onFileListSelectionChanged(s, e));
            app.FileListBox.Layout.Row = 1; app.FileListBox.Layout.Column = 1;
            app.setTooltip(app.FileListBox, "CSV files found by the last scan, shown as paths relative to the parent directory. Click a file to load it.");

            filterRow = uigridlayout(g, [1 2]);
            filterRow.Layout.Row = 2; filterRow.Layout.Column = 1;
            filterRow.ColumnWidth = {'1x', '1x'};
            filterRow.Padding = [0 0 0 0];

            app.FilterDropDown = uidropdown(filterRow, ...
                "Items", ["Show all", "Unresolved only", "Resolved only"], ...
                "Value", char(app.Settings.FilterMode), ...
                "ValueChangedFcn", @(s,e) app.onFilterChanged());
            app.FilterDropDown.Layout.Row = 1; app.FilterDropDown.Layout.Column = 1;
            app.setTooltip(app.FilterDropDown, "Filter which pairs are shown in the pair table. Does not change resolution status. Default: Show all.");

            app.PairProgressLabel = uilabel(filterRow, "Text", "0 resolved / 0 total", ...
                "HorizontalAlignment", "right");
            app.PairProgressLabel.Layout.Row = 1; app.PairProgressLabel.Layout.Column = 2;
            app.setTooltip(app.PairProgressLabel, "Number of pairs that have been given any resolution status out of the total pairs found.");

            app.PairTable = uitable(g, ...
                "Data", {}, ...
                "ColumnName", {'#', 'Row A', 'Row B', 'Dist (px)', 'Status'}, ...
                "ColumnWidth", {30, 54, 54, 62, 80}, ...
                "ColumnEditable", false(1,5), ...
                "CellSelectionCallback", @(s,e) app.onPairTableSelected(s, e));
            app.PairTable.Layout.Row = 3; app.PairTable.Layout.Column = 1;
            app.setTooltip(app.PairTable, "Neighbor pairs visible under the current filter. # = display index; Row A/B = source CSV row numbers; Dist = Euclidean distance in pixels; Status = current resolution. Click a row to select that pair.");

            navGrid = uigridlayout(g, [1 2]);
            navGrid.Layout.Row = 4; navGrid.Layout.Column = 1;
            navGrid.ColumnWidth = {'1x', '1x'};
            navGrid.Padding = [0 0 0 0];

            app.PreviousPairButton = uibutton(navGrid, "push", "Text", "< Prev [j/←]", ...
                "ButtonPushedFcn", @(s,e) app.navigatePairs(-1));
            app.PreviousPairButton.Layout.Row = 1; app.PreviousPairButton.Layout.Column = 1;
            app.setTooltip(app.PreviousPairButton, "Select the previous pair in the filtered list. Shortcuts: j or left arrow.");

            app.NextPairButton = uibutton(navGrid, "push", "Text", "Next [l/→] >", ...
                "ButtonPushedFcn", @(s,e) app.navigatePairs(+1));
            app.NextPairButton.Layout.Row = 1; app.NextPairButton.Layout.Column = 2;
            app.setTooltip(app.NextPairButton, "Select the next pair in the filtered list. Shortcuts: l or right arrow.");
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
            app.setTooltip(app.TiffPageSpinner, "TIFF page (channel) to display in the tissue plot. Enabled only when a companion image is found. Range: 1 to number of pages in the TIFF.");

            spacer = uilabel(topRow, "Text", "");
            spacer.Layout.Row = 1; spacer.Layout.Column = 3;

            app.PairDetailLabel = uilabel(topRow, "Text", "No pair selected");
            app.PairDetailLabel.Layout.Row = 1; app.PairDetailLabel.Layout.Column = 4;
            app.setTooltip(app.PairDetailLabel, "Row numbers, pixel coordinates, distance, and current resolution status of the selected pair.");

            app.ShowPointsCheckBox = uicheckbox(topRow, "Text", "Show points", "Value", true, ...
                "ValueChangedFcn", @(s,e) app.onShowPointsChanged());
            app.ShowPointsCheckBox.Layout.Row = 1; app.ShowPointsCheckBox.Layout.Column = 5;
            app.setTooltip(app.ShowPointsCheckBox, "Toggle visibility of all detection markers on the tissue plot. Shortcut: p");

            app.TissueAxes = uiaxes(g);
            app.TissueAxes.Layout.Row = 2; app.TissueAxes.Layout.Column = 1;
            app.TissueAxes.XTick = [];
            app.TissueAxes.YTick = [];
            app.TissueAxes.Toolbar.Visible = "off";
            app.TissueAxes.Box = "on";
            disableDefaultInteractivity(app.TissueAxes);
            app.setTooltip(app.TissueAxes, "Full-image view of all detections. Gray = not in any pair. Orange = in an unresolved pair. Green = resolved/kept. Blue = merged. Cyan circle = pair point A. Yellow square = pair point B. Click a point to select its pair. Right-click for merge and freehand-ROI options.");
        end

        function buildRightPanel(app)
            app.RightPanel = uipanel(app.MainGrid, "Title", "Resolution Actions");
            app.RightPanel.Layout.Row = 1; app.RightPanel.Layout.Column = 3;

            g = uigridlayout(app.RightPanel, [10 1]);
            g.RowHeight = {48, 48, 48, 48, 48, 48, 48, 48, 8, '1x'};
            g.ColumnWidth = {'1x'};
            g.Padding = [6 6 6 6];
            g.RowSpacing = 4;

            app.KeepAButton = uibutton(g, "push", ...
                "Text", "Keep A  [a]", ...
                "BackgroundColor", [0.25 0.75 0.35], ...
                "FontColor", [1 1 1], ...
                "FontWeight", "bold", ...
                "ButtonPushedFcn", @(s,e) app.doKeepA());
            app.KeepAButton.Layout.Row = 1; app.KeepAButton.Layout.Column = 1;
            app.setTooltip(app.KeepAButton, "Keep detection A, delete B. Shortcut: a");

            app.KeepBButton = uibutton(g, "push", ...
                "Text", "Keep B  [b]", ...
                "BackgroundColor", [0.2 0.55 0.85], ...
                "FontColor", [1 1 1], ...
                "FontWeight", "bold", ...
                "ButtonPushedFcn", @(s,e) app.doKeepB());
            app.KeepBButton.Layout.Row = 2; app.KeepBButton.Layout.Column = 1;
            app.setTooltip(app.KeepBButton, "Keep detection B, delete A. Shortcut: b");

            app.KeepBothButton = uibutton(g, "push", ...
                "Text", "Keep Both  [k / Space]", ...
                "BackgroundColor", [0.5 0.5 0.5], ...
                "FontColor", [1 1 1], ...
                "FontWeight", "bold", ...
                "ButtonPushedFcn", @(s,e) app.doKeepBoth());
            app.KeepBothButton.Layout.Row = 3; app.KeepBothButton.Layout.Column = 1;
            app.setTooltip(app.KeepBothButton, "Keep both detections, mark pair resolved. Shortcut: k or Space");

            app.MergeButton = uibutton(g, "push", ...
                "Text", "Merge — click to place  [m]", ...
                "ButtonPushedFcn", @(s,e) app.armMerge());
            app.MergeButton.Layout.Row = 4; app.MergeButton.Layout.Column = 1;
            app.setTooltip(app.MergeButton, "Delete both; click tissue plot to place merged cell at new location. Shortcut: m");

            app.SkipButton = uibutton(g, "push", ...
                "Text", "Skip  [s]", ...
                "ButtonPushedFcn", @(s,e) app.doSkip());
            app.SkipButton.Layout.Row = 5; app.SkipButton.Layout.Column = 1;
            app.setTooltip(app.SkipButton, "Defer this pair for later. Shortcut: s");

            app.DeletePointButton = uibutton(g, "push", ...
                "Text", "Delete Point — click  [d]", ...
                "ButtonPushedFcn", @(s,e) app.armDeletePoint());
            app.DeletePointButton.Layout.Row = 6; app.DeletePointButton.Layout.Column = 1;
            app.setTooltip(app.DeletePointButton, "Arm point-deletion mode, then click any detection on the tissue plot to delete it. Affects all pairs containing that point. Shortcut: d. Press Esc to cancel.");

            app.RelocatePointButton = uibutton(g, "push", ...
                "Text", "Relocate Point — click  [r]", ...
                "ButtonPushedFcn", @(s,e) app.armRelocatePoint());
            app.RelocatePointButton.Layout.Row = 7; app.RelocatePointButton.Layout.Column = 1;
            app.setTooltip(app.RelocatePointButton, "Arm relocation mode: first click selects a detection (highlighted in yellow), second click moves it to the new position. Undoable. Shortcut: r. Press Esc to cancel.");

            app.UndoButton = uibutton(g, "push", ...
                "Text", "Undo  [Ctrl+Z]", ...
                "ButtonPushedFcn", @(s,e) app.undoLast());
            app.UndoButton.Layout.Row = 8; app.UndoButton.Layout.Column = 1;
            app.setTooltip(app.UndoButton, "Undo the last resolution action. Shortcut: Ctrl+Z");

            % spacer row 9 is empty
            app.PairDetailLabel = uilabel(g, "Text", "No pair selected", ...
                "WordWrap", "on", "VerticalAlignment", "top");
            app.PairDetailLabel.Layout.Row = 10; app.PairDetailLabel.Layout.Column = 1;
            app.setTooltip(app.PairDetailLabel, "Pair identifier, pixel distance, X/Y coordinates of both detections, and current resolution status.");
        end

        function setTooltip(~, component, txt)
            if ~isempty(component) && isvalid(component) && isprop(component, 'Tooltip')
                component.Tooltip = char(txt);
            end
        end

        % --------------------------------------------------------------
        % SETTINGS
        % --------------------------------------------------------------

        function defaults = defaultSettings(~)
            defaults.SettingsVersion     = 1;
            defaults.SettingsSavedAt     = 0;
            defaults.LastParentDirectory = "";
            defaults.FileRegex           = '(?i)_locs\.csv$';
            defaults.NeighborDistance    = 10;
            defaults.TiffPageIndex       = 1;
            defaults.AutoAdvance         = true;
            defaults.AutoSave            = true;
            defaults.FilterMode          = "Show all";
            defaults.WindowPosition      = [100 100 1400 820];
            defaults.LastActiveCsvPath   = "";
        end

        function loadSettings(app)
            defaults = app.defaultSettings();
            stored = [];

            % Try MATLAB preferences first
            if ispref(app.SettingsGroup, app.SettingsPrefKey)
                try
                    stored = getpref(app.SettingsGroup, app.SettingsPrefKey);
                catch
                end
            end

            % Fallback: MAT file
            matPath = app.settingsMatPath();
            if isempty(stored) && isfile(matPath)
                try
                    s = load(char(matPath), 'settings');
                    if isfield(s, 'settings')
                        stored = s.settings;
                    end
                catch
                end
            end

            if isempty(stored)
                app.Settings = defaults;
            else
                app.Settings = app.mergeSettings(defaults, stored);
            end
        end

        function saveSettings(app)
            app.readSettingsFromUI();
            app.Settings.SettingsSavedAt = posixtime(datetime('now'));
            matPath = app.settingsMatPath();
            settings = app.Settings; %#ok<NASGU>
            try
                save(char(matPath), 'settings');
            catch
            end
            try
                setpref(app.SettingsGroup, app.SettingsPrefKey, app.Settings);
            catch
            end
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

        function merged = mergeSettings(~, defaults, stored)
            merged = defaults;
            if ~isstruct(stored)
                return
            end
            fields = fieldnames(stored);
            for k = 1:numel(fields)
                f = fields{k};
                if isfield(defaults, f)
                    merged.(f) = stored.(f);
                end
            end
        end

        function applySettingsToUI(app)
            if strlength(app.Settings.LastParentDirectory) > 0
                app.ParentDirEdit.Value = char(app.Settings.LastParentDirectory);
            end
            app.RegexEdit.Value = char(app.Settings.FileRegex);
            app.DistanceSpinner.Value = app.Settings.NeighborDistance;
            app.AutoAdvanceCheckBox.Value = app.Settings.AutoAdvance;
            app.AutoSaveCheckBox.Value = app.Settings.AutoSave;
            app.setDropDownValue(app.FilterDropDown, app.Settings.FilterMode);
        end

        function setDropDownValue(~, dd, value)
            items = string(dd.Items);
            value = string(value);
            if any(items == value)
                dd.Value = char(value);
            elseif ~isempty(items)
                dd.Value = char(items(1));
            end
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

        function doScan(app)
            parentDir = string(strtrim(app.ParentDirEdit.Value));
            if strlength(parentDir) == 0 || ~isfolder(parentDir)
                app.updateStatus("Parent directory does not exist.");
                return
            end
            app.ParentDirectory = parentDir;
            app.Settings.LastParentDirectory = parentDir;

            pattern = char(strtrim(app.RegexEdit.Value));
            allFiles = app.recDir(char(parentDir));

            matched = {};
            for k = 1:numel(allFiles)
                [~, name, ext] = fileparts(allFiles{k});
                basename = [name, ext];
                try
                    if ~isempty(regexpi(basename, pattern, 'once'))
                        matched{end+1} = allFiles{k}; %#ok<AGROW>
                    end
                catch
                end
            end

            app.AllAbsFiles = matched;
            n = numel(matched);

            if n == 0
                app.FileListBox.Items = {};
                app.FileCountLabel.Text = 'No files found';
                app.FileCountLabel.FontColor = [0.8 0.2 0.2];
                app.updateStatus("No CSV files matched the filter pattern.");
                return
            end

            relPaths = cell(n, 1);
            for k = 1:n
                relPaths{k} = char(app.makeRelativePath(matched{k}, char(parentDir)));
            end
            app.FileListBox.Items = relPaths;
            app.FileCountLabel.Text = sprintf('%d file(s) found', n);
            app.FileCountLabel.FontColor = [0.1 0.5 0.1];
            app.updateStatus(sprintf('Scan complete: %d file(s) found.', n));

            % Restore last active file
            if strlength(app.Settings.LastActiveCsvPath) > 0
                for k = 1:n
                    if strcmp(matched{k}, char(app.Settings.LastActiveCsvPath))
                        app.FileListBox.Value = relPaths{k};
                        app.loadCsvFile(string(matched{k}));
                        return
                    end
                end
            end
        end

        function onFileListSelectionChanged(app, src, ~)
            val = src.Value;
            if isempty(val)
                return
            end
            relPath = string(val);
            for k = 1:numel(app.AllAbsFiles)
                if strcmp(app.makeRelativePath(app.AllAbsFiles{k}, char(app.ParentDirectory)), char(relPath))
                    app.loadCsvFile(string(app.AllAbsFiles{k}));
                    return
                end
            end
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
            tbl.NR_Deleted     = false(n, 1);
            tbl.NR_MergedRow   = false(n, 1);
            tbl.NR_OriginalRow = (1:n)';
            tbl.NR_OrigX       = double(tbl.X);   % snapshot of X at load time
            tbl.NR_OrigY       = double(tbl.Y);   % snapshot of Y at load time

            app.ActiveLocTable = tbl;

            % Find companion image
            app.ActiveImagePath = app.inferImagePath(csvPath);
            if strlength(app.ActiveImagePath) > 0 && isfile(app.ActiveImagePath)
                try
                    app.ActiveTiffInfo = imfinfo(char(app.ActiveImagePath));
                    np = numel(app.ActiveTiffInfo);
                    app.TiffPageSpinner.Limits = [1 np];
                    app.TiffPageSpinner.Enable = "on";
                    pg = min(max(app.Settings.TiffPageIndex, 1), np);
                    app.TiffPageSpinner.Value = pg;
                    app.ActiveDisplayPage = pg;
                catch
                    app.ActiveTiffInfo = [];
                    app.ActiveImagePath = "";
                    app.TiffPageSpinner.Limits = [1 1];
                    app.TiffPageSpinner.Enable = "off";
                end
            else
                app.ActiveImagePath = "";
                app.TiffPageSpinner.Limits = [1 1];
                app.TiffPageSpinner.Enable = "off";
            end

            app.Settings.LastActiveCsvPath = csvPath;
            app.saveSettings();

            app.updatePairTable();
            app.updatePairProgressLabel();
            app.updatePairCountLabel();
            app.updatePairDetailLabel();
            app.renderTissuePlot();

            if strlength(app.ActiveImagePath) > 0
                [~, imgName, imgExt] = fileparts(char(app.ActiveImagePath));
                imgNote = sprintf(' | Image: %s', [imgName imgExt]);
            else
                imgNote = ' | No companion image found (scatter only)';
            end
            app.updateStatus(sprintf('Loaded %d detections from %s%s', n, ...
                char(app.makeRelativePath(char(csvPath), char(app.ParentDirectory))), imgNote));
        end

        function imagePath = inferImagePath(~, csvPath)
            % Match the CellDiscovery convention: the TIFF has the same name
            % as the CSV stem minus the channel suffix and _locs tag.
            % E.g. "img_PNN1_locs.csv" -> "img.tif"
            %      "img_locs.csv"       -> "img.tif"
            %      "img_locs_resized.csv" -> "img.tif"
            imagePath = "";
            [folder, name, ~] = fileparts(char(csvPath));

            % Build a list of stems to try, from most- to least-specific:
            %   1. Strip _<anySuffix>_locs(_resized)?   (e.g. _PNN1_locs)
            %   2. Strip _locs(_resized)?                (simple case)
            stems = {};
            s1 = regexprep(name, '_[^_]+_locs(_resized)?$', '', 'ignorecase');
            if ~strcmp(s1, name), stems{end+1} = s1; end
            s2 = regexprep(name, '_locs(_resized)?$', '', 'ignorecase');
            if ~strcmp(s2, name), stems{end+1} = s2; end
            % Also try the bare name in case there is no recognised suffix
            stems{end+1} = name;

            exts = {'.tif', '.tiff'};
            % Prefer preprocessed variant; fall back to projection, then plain
            suffixes = {'_preprocessed', '_proj', ''};

            for si = 1:numel(stems)
                for pi = 1:numel(suffixes)
                    for ei = 1:numel(exts)
                        candidate = fullfile(folder, [stems{si}, suffixes{pi}, exts{ei}]);
                        if isfile(candidate)
                            imagePath = string(candidate);
                            return
                        end
                    end
                end
            end
        end

        function img = getImagePage(app, pageIndex)
            img = [];
            if isempty(app.ActiveTiffInfo) || strlength(app.ActiveImagePath) == 0
                return
            end
            pageIndex = max(1, min(pageIndex, numel(app.ActiveTiffInfo)));
            fieldName = sprintf('page%d', pageIndex);
            if isfield(app.ActiveImagePages, fieldName)
                img = app.ActiveImagePages.(fieldName);
                return
            end
            try
                img = imread(char(app.ActiveImagePath), pageIndex);
                app.ActiveImagePages.(fieldName) = img;
            catch
                img = [];
            end
        end

        % --------------------------------------------------------------
        % NEIGHBOR PAIR FINDING
        % --------------------------------------------------------------

        function onFindNeighborsButtonPushed(app)
            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                uialert(app.UIFigure, 'Load a CSV file first.', 'No data');
                return
            end

            app.updateStatus("Finding neighbor pairs...");
            drawnow

            distance = app.DistanceSpinner.Value;
            liveMask = ~app.ActiveLocTable.NR_Deleted;
            liveRows = find(liveMask);

            if numel(liveRows) < 2
                app.NeighborPairs = zeros(0, 3);
                app.PairStatus = strings(0, 1);
                app.FilteredPairIndices = [];
                app.SelectedPairIndex = NaN;
                app.PairTableData = {};
                app.updatePairTable();
                app.updatePairProgressLabel();
                app.updatePairCountLabel();
                app.renderTissuePlot();
                app.updateStatus("Fewer than 2 live detections — no pairs to find.");
                return
            end

            liveTable = app.ActiveLocTable(liveRows, :);
            app.buildNeighborPairs(liveTable, distance, liveRows);

            app.applyPairFilter();
            app.renderTissuePlot();
            app.updatePairCountLabel();

            % Select first unresolved pair
            app.SelectedPairIndex = NaN;
            firstIdx = app.findNextUnresolvedPair(0);
            if ~isnan(firstIdx)
                app.selectPair(firstIdx);
            else
                app.updatePairDetailLabel();
            end

            n = size(app.NeighborPairs, 1);
            app.updateStatus(sprintf('Found %d neighbor pair(s) within %g px.', n, distance));
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
        end

        function navigatePairs(app, direction)
            if isempty(app.FilteredPairIndices)
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
                    newPos = max(1, min(newPos, numel(app.FilteredPairIndices)));
                end
            end
            app.selectPair(app.FilteredPairIndices(newPos));
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
                % All pairs in this file are resolved — move to next file
                app.updateStatus("All pairs resolved. Loading next file...");
                drawnow
                app.loadNextFileAndFindNeighbors();
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

                app.FileListBox.Value = app.FileListBox.Items{nextIdx};
                app.loadCsvFile(nextPath);

                % Find neighbors using current distance setting
                distance = app.DistanceSpinner.Value;
                liveMask = ~app.ActiveLocTable.NR_Deleted;
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

                % Check if this file has any unresolved pairs
                firstUnresolved = app.findNextUnresolvedPair(0);
                if ~isnan(firstUnresolved)
                    n = size(app.NeighborPairs, 1);
                    app.updateStatus(sprintf('Advanced to %s — %d pair(s) found.', ...
                        char(app.makeRelativePath(char(nextPath), char(app.ParentDirectory))), n));
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
                title(app.TissueAxes, [imgName imgExt], 'Interpreter', 'none', 'FontSize', 8);
            end

            app.TissueAxes.HitTest = 'on';
            app.TissueAxes.PickableParts = 'all';
            app.TissueAxes.ButtonDownFcn = @(s,e) app.onTissueClicked(s, e);

            hold(app.TissueAxes, 'on');
            app.drawTissueAllPoints();
            app.updateTissueHighlights();
            hold(app.TissueAxes, 'off');

            app.installTissueContextMenu();
        end

        function drawTissueAllPoints(app)
            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                return
            end

            % Only show live (non-deleted) rows
            liveMask = ~app.ActiveLocTable.NR_Deleted;
            liveIdx = find(liveMask);
            if isempty(liveIdx)
                return
            end

            x = double(app.ActiveLocTable.X(liveIdx));
            y = double(app.ActiveLocTable.Y(liveIdx));
            colors = app.pointColorsForRows(liveIdx);

            h = scatter(app.TissueAxes, x, y, 18, colors, 'filled', ...
                'MarkerFaceAlpha', 0.8, ...
                'MarkerEdgeColor', 'flat', ...
                'HitTest', 'off', ...
                'PickableParts', 'none');
            h.Annotation.LegendInformation.IconDisplayStyle = 'off';
            app.TissueAllPointsHandle = h;
            if ~isempty(app.ShowPointsCheckBox) && isvalid(app.ShowPointsCheckBox)
                h.Visible = app.ShowPointsCheckBox.Value;
            end
        end

        function updateTissueAllPoints(app)
            if isempty(app.ActiveLocTable) || height(app.ActiveLocTable) == 0
                return
            end
            % If the scatter handle doesn't exist or is invalid, rebuild fully
            if isempty(app.TissueAllPointsHandle) || ~isvalid(app.TissueAllPointsHandle)
                hold(app.TissueAxes, 'on');
                app.drawTissueAllPoints();
                hold(app.TissueAxes, 'off');
                return
            end

            liveMask = ~app.ActiveLocTable.NR_Deleted;
            liveIdx = find(liveMask);
            if isempty(liveIdx)
                delete(app.TissueAllPointsHandle);
                app.TissueAllPointsHandle = [];
                return
            end

            x = double(app.ActiveLocTable.X(liveIdx));
            y = double(app.ActiveLocTable.Y(liveIdx));
            colors = app.pointColorsForRows(liveIdx);

            app.TissueAllPointsHandle.XData = x;
            app.TissueAllPointsHandle.YData = y;
            app.TissueAllPointsHandle.CData = colors;
            if ~isempty(app.ShowPointsCheckBox) && isvalid(app.ShowPointsCheckBox)
                app.TissueAllPointsHandle.Visible = app.ShowPointsCheckBox.Value;
            end
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
                if app.ActiveLocTable.NR_MergedRow(r)
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
                    colors(k, :) = [0.55 0.55 0.55]; % gray: not in any pair
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
            app.TissuePointAHandle = scatter(app.TissueAxes, xA, yA, 150, ...
                'o', 'filled', ...
                'MarkerFaceColor', [0.25 0.75 0.35], ...
                'MarkerEdgeColor', [0.1 0.4 0.15], ...
                'LineWidth', 1.5, ...
                'HitTest', 'off', ...
                'PickableParts', 'none', ...
                'DisplayName', sprintf('A (row %d)', rowA));

            xB = double(app.ActiveLocTable.X(rowB));
            yB = double(app.ActiveLocTable.Y(rowB));
            app.TissuePointBHandle = scatter(app.TissueAxes, xB, yB, 150, ...
                's', 'filled', ...
                'MarkerFaceColor', [0.2 0.55 0.85], ...
                'MarkerEdgeColor', [0.1 0.25 0.5], ...
                'LineWidth', 1.5, ...
                'HitTest', 'off', ...
                'PickableParts', 'none', ...
                'DisplayName', sprintf('B (row %d)', rowB));

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

            % Find nearest live detection
            liveMask = ~app.ActiveLocTable.NR_Deleted;
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

        function onTiffPageChanged(app)
            app.ActiveDisplayPage = app.TiffPageSpinner.Value;
            app.Settings.TiffPageIndex = app.ActiveDisplayPage;
            app.renderTissuePlot();
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
            app.ActiveLocTable.NR_Deleted(rowB) = true;
            app.PairStatus(app.SelectedPairIndex) = app.STATUS_KEEP_A;
            app.Dirty = true;
            app.afterAction();
        end

        function doKeepB(app)
            [rowA, rowB, ok] = app.activePairRows();
            if ~ok, return; end
            app.pushUndo(rowA, rowB, NaN);
            app.ActiveLocTable.NR_Deleted(rowA) = true;
            app.PairStatus(app.SelectedPairIndex) = app.STATUS_KEEP_B;
            app.Dirty = true;
            app.afterAction();
        end

        function doKeepBoth(app)
            [rowA, rowB, ok] = app.activePairRows();
            if ~ok, return; end
            app.pushUndo(rowA, rowB, NaN);
            app.PairStatus(app.SelectedPairIndex) = app.STATUS_KEEP_BOTH;
            app.Dirty = true;
            app.afterAction();
        end

        function doSkip(app)
            [rowA, rowB, ok] = app.activePairRows();
            if ~ok, return; end
            app.pushUndo(rowA, rowB, NaN);
            app.PairStatus(app.SelectedPairIndex) = app.STATUS_SKIPPED;
            app.Dirty = true;
            app.afterAction();
        end

        function onShowPointsChanged(app)
            vis = "on";
            if ~app.ShowPointsCheckBox.Value
                vis = "off";
            end
            if ~isempty(app.TissueAllPointsHandle) && isvalid(app.TissueAllPointsHandle)
                app.TissueAllPointsHandle.Visible = vis;
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

            liveMask = ~app.ActiveLocTable.NR_Deleted;
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
            app.ActiveLocTable.NR_Deleted(rowIdx) = true;
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

        function armRelocatePoint(app)
            app.cancelMerge();
            app.cancelDeletePoint();
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
            liveMask = ~app.ActiveLocTable.NR_Deleted;
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

            newRow.NR_Deleted    = false;
            newRow.NR_MergedRow  = true;
            newRow.NR_OriginalRow = NaN;

            app.ActiveLocTable = [app.ActiveLocTable; newRow];
            app.ActiveLocTable.NR_Deleted(rowA) = true;
            app.ActiveLocTable.NR_Deleted(rowB) = true;

            app.PairStatus(app.SelectedPairIndex) = app.STATUS_MERGED;
            app.Dirty = true;
            app.cancelMerge();
            app.afterAction();
            app.updateStatus(sprintf('Merged pair %d-%d at (%.1f, %.1f).', rowA, rowB, xNew, yNew));
        end

        function afterAction(app)
            app.updateTissueAllPoints();
            app.updateTissueHighlights();
            app.updatePairTable();
            app.updatePairProgressLabel();
            app.updatePairDetailLabel();

            if app.AutoSaveCheckBox.Value
                app.saveResolved();
            end

            if app.AutoAdvanceCheckBox.Value
                app.advanceToNextUnresolved();
            end
        end

        % --------------------------------------------------------------
        % UNDO
        % --------------------------------------------------------------

        function pushUndo(app, rowA, rowB, mergedRowIdx)
            state.Kind         = 'action';
            state.PairIndex    = app.SelectedPairIndex;
            state.PairStatus   = app.PairStatus(app.SelectedPairIndex);
            state.RowA         = rowA;
            state.RowB         = rowB;
            state.DeletedA     = app.ActiveLocTable.NR_Deleted(rowA);
            state.DeletedB     = isnan(rowB) || app.ActiveLocTable.NR_Deleted(rowB);
            state.MergedRowIdx = mergedRowIdx;
            state.TableHeight  = height(app.ActiveLocTable);

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
                app.ActiveLocTable.NR_Deleted(state.RowA) = state.DeletedA;
            end
            if ~isnan(state.RowB) && state.RowB >= 1 && state.RowB <= height(app.ActiveLocTable)
                app.ActiveLocTable.NR_Deleted(state.RowB) = state.DeletedB;
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
            % Strategy: keep ALL original rows (rows where NR_MergedRow == false).
            % Append one row per Merged pair for the new merged point.
            % Output columns NR_X, NR_Y carry the "effective" coordinates:
            %   - original unmodified row  → NR_X = current X (may differ if relocated)
            %   - deleted row              → NR_X = NaN, NR_Y = NaN
            %   - merged-origin row        → NR_X = NaN, NR_Y = NaN
            %   - merged-result row        → NR_X = merged X, NR_Y = merged Y

            origMask = ~app.ActiveLocTable.NR_MergedRow;
            outTbl = app.ActiveLocTable(origMask, :);

            nOrig = height(outTbl);

            % Strip all runtime columns — we will build NR_X/NR_Y fresh
            runtimeCols = {'NR_Deleted','NR_MergedRow','NR_OriginalRow','NR_OrigX','NR_OrigY'};
            for k = 1:numel(runtimeCols)
                if ismember(runtimeCols{k}, outTbl.Properties.VariableNames)
                    outTbl.(runtimeCols{k}) = [];
                end
            end

            % NR_X / NR_Y: start as current X/Y, then blank deleted rows
            outTbl.NR_X = double(outTbl.X);
            outTbl.NR_Y = double(outTbl.Y);

            % Annotation columns
            outTbl.NeighborResolved       = false(nOrig, 1);
            outTbl.NeighborResolvedStatus = strings(nOrig, 1);
            outTbl.NeighborPairID         = strings(nOrig, 1);

            % Map from original row number → output table row index
            origRowNums = app.ActiveLocTable.NR_OriginalRow(origMask);

            for p = 1:size(app.NeighborPairs, 1)
                st = app.PairStatus(p);
                rA = app.NeighborPairs(p, 1);
                rB = app.NeighborPairs(p, 2);
                pairLabel = string(rA) + "-" + string(rB);

                idxA = find(origRowNums == rA, 1);
                idxB = find(origRowNums == rB, 1);

                if st == app.STATUS_UNRESOLVED || st == app.STATUS_SKIPPED
                    continue
                end

                % Annotate both original rows
                for idx = [idxA, idxB]
                    if ~isempty(idx)
                        outTbl.NeighborResolved(idx)       = true;
                        outTbl.NeighborResolvedStatus(idx) = st;
                        outTbl.NeighborPairID(idx)         = pairLabel;
                    end
                end

                if st == app.STATUS_KEEP_A
                    % B is deleted
                    if ~isempty(idxB)
                        outTbl.NR_X(idxB) = NaN;
                        outTbl.NR_Y(idxB) = NaN;
                    end
                elseif st == app.STATUS_KEEP_B
                    % A is deleted
                    if ~isempty(idxA)
                        outTbl.NR_X(idxA) = NaN;
                        outTbl.NR_Y(idxA) = NaN;
                    end
                elseif st == app.STATUS_MERGED
                    % Both originals are nulled; find the appended merged row
                    if ~isempty(idxA), outTbl.NR_X(idxA) = NaN; outTbl.NR_Y(idxA) = NaN; end
                    if ~isempty(idxB), outTbl.NR_X(idxB) = NaN; outTbl.NR_Y(idxB) = NaN; end

                    % Find the merged-result row in ActiveLocTable (NR_MergedRow == true)
                    % that was appended for this pair. We use order of appending:
                    % match by proximity — merged rows untagged so far
                    mergedRows = find(app.ActiveLocTable.NR_MergedRow);
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
                        newRow.NR_X = mX; newRow.NR_Y = mY;
                        newRow.NeighborResolved       = true;
                        newRow.NeighborResolvedStatus = st;
                        newRow.NeighborPairID         = pairLabel;
                        outTbl = [outTbl; newRow]; %#ok<AGROW>
                        break
                    end
                end
            end

            % Null NR_X/NR_Y for any deleted row not already nulled (e.g. standalone deletes)
            for r = 1:nOrig
                origR = origRowNums(r);
                if ~isnan(origR) && origR >= 1 && origR <= height(app.ActiveLocTable)
                    if app.ActiveLocTable.NR_Deleted(origR) && ~isnan(outTbl.NR_X(r))
                        outTbl.NR_X(r) = NaN;
                        outTbl.NR_Y(r) = NaN;
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
            app.updateStatus(sprintf('Saved %d rows → %s', nOut, ...
                char(app.makeRelativePath(char(app.ActiveCsvPath), char(app.ParentDirectory)))));
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
                case "p"
                    app.ShowPointsCheckBox.Value = ~app.ShowPointsCheckBox.Value;
                    app.onShowPointsChanged();
                case "s"
                    app.doSkip();
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

    end

    % ==================================================================
    methods (Static, Access = private)

        function allFiles = recDir(rootDir)
            allFiles = {};
            items = dir(rootDir);
            for k = 1:numel(items)
                if strcmp(items(k).name, '.') || strcmp(items(k).name, '..')
                    continue
                end
                fullPath = fullfile(items(k).folder, items(k).name);
                if items(k).isdir
                    sub = CellNeighborResolverApp.recDir(fullPath);
                    allFiles = [allFiles, sub]; %#ok<AGROW>
                else
                    allFiles{end+1} = fullPath; %#ok<AGROW>
                end
            end
        end

        function rel = makeRelativePath(absPath, rootDir)
            % Normalize separators
            absPath = strrep(absPath, '\', '/');
            rootDir = strrep(rootDir, '\', '/');
            if isempty(rootDir) || rootDir(end) ~= '/'
                rootDir = [rootDir '/'];
            end
            if strncmpi(absPath, rootDir, numel(rootDir))
                rel = absPath(numel(rootDir)+1:end);
            else
                rel = absPath;
            end
        end

    end

end
