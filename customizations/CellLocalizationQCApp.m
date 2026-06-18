classdef CellLocalizationQCApp < handle
% CellLocalizationQCApp Manual QC GUI for cell localization CSV files.
%   app = CellLocalizationQCApp launches a programmatic MATLAB GUI for
%   reviewing localized cell detections from multipage TIFF images and
%   associated *_locs.csv files. Review labels are saved to separate *_QC.csv
%   files and are merged back by QCSourceRow when a source is reloaded.

    properties (Constant, Access = private)
        SettingsGroup = 'CellLocalizationQCApp'
        SettingsPrefKey = 'Settings'
        SettingsAppDataKey = 'CellLocalizationQCAppSettings'
        QCVersion = '1.0'
    end

    properties (Access = private)
        Settings
        Categories
        ParentDirectory string = ""
        DatasetList
        SourceListByDataset cell = {}
        ActiveDatasetIndex double = 0
        ActiveSourceIndex double = 0
        ActiveSource struct = struct()
        ActiveTiffInfo = []
        ActiveImagePages struct = struct()
        ActiveContrastLimits struct = struct()
        ActiveLocalizationTable
        ActiveReviewTable
        DisplayOrder double = []
        FilteredOrder double = []
        BlockStartIndex double = 1
        SelectedVisibleIndex double = 1
        SelectedVisibleIndices double = []
        SelectedGlobalRow double = NaN
        Dirty logical = false
        UndoStack cell = {}
        ClassificationsSinceSave double = 0
        LastAutosaveTime datetime = NaT

        UIFigure
        RootGrid
        ToolbarGrid
        MainGrid
        LeftPanel
        CenterPanel
        RightPanel
        DatasetTable
        DatasetActiveRowStyle
        ParentDirEdit
        BrowseButton
        ScanButton
        OpenDatasetFolderButton
        SourceDropDown
        CellsPerBlockSpinner
        CropWidthSpinner
        CropHeightSpinner
        LinkedSquareCheckBox
        Sort1DropDown
        Sort1DirectionDropDown
        Sort2DropDown
        Sort2DirectionDropDown
        FilterDropDown
        DisplayModeDropDown
        ContrastModeDropDown
        MarkerCheckBox
        AutoAdvanceCheckBox
        SaveButton
        SettingsButton
        TileSummaryLabel
        BlockNavigationGrid
        PreviousBlockButton
        NextBlockButton
        BlockDropDown
        TileGrid
        MontageAxes
        MontageImage
        MontageVisibleRows double = []
        MontageTileBounds double = zeros(0, 4)
        MontageMarkerPositions cell = {}
        HeldClassIndex double = NaN
        HeldClassKey string = ""
        HeldClassUsedForClick logical = false
        DetailAxes
        DetailLabel
        CategoryButtonGrid
        CategoryButtons cell = {}
        ThresholdClassifyButton
        HistogramButton
        TissuePlotButton
        RecenterButton
        RecenterMode logical = false
        TissueFigure = []
        TissueAxes = []
        TissueImage = []
        TissueClassPointHandle = []
        TissueClassPointRows double = []
        TissueSelectionHandle = []
        TissueContextMenu = []
        NotesEdit
        MetadataTable
        StatusLabel
    end

    methods
        function app = CellLocalizationQCApp()
            app.DatasetList = app.emptyDatasetTable();
            app.ActiveLocalizationTable = table();
            app.ActiveReviewTable = table();
            app.loadSettings();
            app.Categories = app.sanitizeCategories(app.Settings.Categories);
            app.ParentDirectory = string(app.Settings.LastParentDirectory);
            app.buildUI();
            app.applySettingsToUI();
            app.rebuildCategoryButtons();

            if strlength(app.ParentDirectory) > 0 && isfolder(app.ParentDirectory)
                app.ParentDirEdit.Value = char(app.ParentDirectory);
                app.scanParentDirectory(true);
            else
                app.updateStatus("Select a parent directory and press Scan.");
            end
        end
    end

    methods (Access = private)
        function buildUI(app)
            position = app.Settings.WindowPosition;
            if numel(position) ~= 4 || any(~isfinite(position))
                position = [100 100 1500 850];
            end

            app.UIFigure = uifigure("Name", "Cell Localization QC", "Position", position);
            if isprop(app.UIFigure, 'WindowKeyPressFcn')
                app.UIFigure.WindowKeyPressFcn = @(src, event) app.handleKeyPress(src, event);
            else
                app.UIFigure.KeyPressFcn = @(src, event) app.handleKeyPress(src, event);
            end
            if isprop(app.UIFigure, 'WindowKeyReleaseFcn')
                app.UIFigure.WindowKeyReleaseFcn = @(src, event) app.handleKeyRelease(src, event);
            else
                app.UIFigure.KeyReleaseFcn = @(src, event) app.handleKeyRelease(src, event);
            end
            app.UIFigure.CloseRequestFcn = @(src, event) app.handleCloseRequest(src, event);

            exportMenu = uimenu(app.UIFigure, "Text", "Export");
            uimenu(exportMenu, "Text", "Export observation CSV...", ...
                "MenuSelectedFcn", @(src, event) app.exportObservationCsvDialog());

            app.RootGrid = uigridlayout(app.UIFigure, [3 1]);
            app.RootGrid.RowHeight = {76, '1x', 26};
            app.RootGrid.ColumnWidth = {'1x'};
            app.RootGrid.Padding = [8 8 8 8];
            app.RootGrid.RowSpacing = 6;

            app.ToolbarGrid = uigridlayout(app.RootGrid, [2 18]);
            app.ToolbarGrid.RowHeight = {24, 28};
            app.ToolbarGrid.ColumnWidth = {70, '2x', 68, 54, 92, 58, 74, 74, 74, 54, 70, '1x', 86, '1x', 86, 58, 72, 88};
            app.ToolbarGrid.ColumnSpacing = 5;
            app.ToolbarGrid.Padding = [0 0 0 0];

            app.addToolbarLabel("Parent", 1, 1);
            app.ParentDirEdit = uieditfield(app.ToolbarGrid, "text", "ValueChangedFcn", @(src, event) app.onParentDirEdited(src, event));
            app.ParentDirEdit.Layout.Row = 1;
            app.ParentDirEdit.Layout.Column = 2;

            app.BrowseButton = uibutton(app.ToolbarGrid, "push", "Text", "Browse", "ButtonPushedFcn", @(src, event) app.chooseParentDirectory());
            app.BrowseButton.Layout.Row = 1;
            app.BrowseButton.Layout.Column = 3;

            app.ScanButton = uibutton(app.ToolbarGrid, "push", "Text", "Scan", "ButtonPushedFcn", @app.onScanButtonPushed);
            app.ScanButton.Layout.Row = 1;
            app.ScanButton.Layout.Column = 4;

            app.OpenDatasetFolderButton = uibutton(app.ToolbarGrid, "push", ...
                "Text", "Open Folder", ...
                "ButtonPushedFcn", @(src, event) app.openActiveDatasetFolder());
            app.OpenDatasetFolderButton.Layout.Row = 1;
            app.OpenDatasetFolderButton.Layout.Column = 5;

            app.addToolbarLabel("Source", 1, 6);
            app.SourceDropDown = uidropdown(app.ToolbarGrid, "Items", ["No source"], "ValueChangedFcn", @(src, event) app.onSourceChanged(src, event));
            app.SourceDropDown.Layout.Row = 1;
            app.SourceDropDown.Layout.Column = [7 9];

            app.addToolbarLabel("Display", 1, 10);
            app.DisplayModeDropDown = uidropdown(app.ToolbarGrid, ...
                "Items", ["Target channel only", "Companion channel only", "Side-by-side channel view", "False-color overlay"], ...
                "ValueChangedFcn", @(src, event) app.onDisplaySettingsChanged());
            app.DisplayModeDropDown.Layout.Row = 1;
            app.DisplayModeDropDown.Layout.Column = [11 12];

            app.ContrastModeDropDown = uidropdown(app.ToolbarGrid, ...
                "Items", ["Auto per crop", "Auto per channel / dataset", "Manual min-max", "Percentile stretch"], ...
                "ValueChangedFcn", @(src, event) app.onDisplaySettingsChanged());
            app.ContrastModeDropDown.Layout.Row = 1;
            app.ContrastModeDropDown.Layout.Column = [13 14];

            app.SettingsButton = uibutton(app.ToolbarGrid, "push", "Text", "Settings", "ButtonPushedFcn", @(src, event) app.openSettingsDialog());
            app.SettingsButton.Layout.Row = 1;
            app.SettingsButton.Layout.Column = 15;

            app.SaveButton = uibutton(app.ToolbarGrid, "push", "Text", "Save", "ButtonPushedFcn", @(src, event) app.saveCurrentQC());
            app.SaveButton.Layout.Row = 1;
            app.SaveButton.Layout.Column = 16;

            app.addToolbarLabel("Cells/block", 2, 3);
            app.CellsPerBlockSpinner = uispinner(app.ToolbarGrid, "Limits", [1 200], "RoundFractionalValues", "on", "ValueChangedFcn", @(src, event) app.onBlockSettingsChanged());
            app.CellsPerBlockSpinner.Layout.Row = 2;
            app.CellsPerBlockSpinner.Layout.Column = 4;

            app.addToolbarLabel("Crop W", 2, 5);
            app.CropWidthSpinner = uispinner(app.ToolbarGrid, "Limits", [8 2048], "RoundFractionalValues", "on", "ValueChangedFcn", @(src, event) app.onCropSettingsChanged(true));
            app.CropWidthSpinner.Layout.Row = 2;
            app.CropWidthSpinner.Layout.Column = 6;

            app.addToolbarLabel("Crop H", 2, 7);
            app.CropHeightSpinner = uispinner(app.ToolbarGrid, "Limits", [8 2048], "RoundFractionalValues", "on", "ValueChangedFcn", @(src, event) app.onCropSettingsChanged(false));
            app.CropHeightSpinner.Layout.Row = 2;
            app.CropHeightSpinner.Layout.Column = 8;

            app.LinkedSquareCheckBox = uicheckbox(app.ToolbarGrid, "Text", "Square", "ValueChangedFcn", @(src, event) app.onCropSettingsChanged(true));
            app.LinkedSquareCheckBox.Layout.Row = 2;
            app.LinkedSquareCheckBox.Layout.Column = 9;

            app.MarkerCheckBox = uicheckbox(app.ToolbarGrid, "Text", "Marker", "ValueChangedFcn", @(src, event) app.onDisplaySettingsChanged());
            app.MarkerCheckBox.Layout.Row = 2;
            app.MarkerCheckBox.Layout.Column = 10;

            app.addToolbarLabel("Sort", 2, 11);
            app.Sort1DropDown = uidropdown(app.ToolbarGrid, "Items", ["Original row order"], "ValueChangedFcn", @(src, event) app.onSortOrFilterChanged());
            app.Sort1DropDown.Layout.Row = 2;
            app.Sort1DropDown.Layout.Column = 12;

            app.Sort1DirectionDropDown = uidropdown(app.ToolbarGrid, "Items", ["Ascending", "Descending"], "ValueChangedFcn", @(src, event) app.onSortOrFilterChanged());
            app.Sort1DirectionDropDown.Layout.Row = 2;
            app.Sort1DirectionDropDown.Layout.Column = 13;

            app.Sort2DropDown = uidropdown(app.ToolbarGrid, "Items", ["None"], "ValueChangedFcn", @(src, event) app.onSortOrFilterChanged());
            app.Sort2DropDown.Layout.Row = 2;
            app.Sort2DropDown.Layout.Column = 14;

            app.Sort2DirectionDropDown = uidropdown(app.ToolbarGrid, "Items", ["Ascending", "Descending"], "ValueChangedFcn", @(src, event) app.onSortOrFilterChanged());
            app.Sort2DirectionDropDown.Layout.Row = 2;
            app.Sort2DirectionDropDown.Layout.Column = 15;

            app.FilterDropDown = uidropdown(app.ToolbarGrid, "Items", ["Show all", "Show unreviewed only", "Show reviewed only", "Good only", "Bad only", "Uncertain only"], "ValueChangedFcn", @(src, event) app.onSortOrFilterChanged());
            app.FilterDropDown.Layout.Row = 2;
            app.FilterDropDown.Layout.Column = 16;

            app.AutoAdvanceCheckBox = uicheckbox(app.ToolbarGrid, "Text", "Auto advance", "ValueChangedFcn", @(src, event) app.onDisplaySettingsChanged());
            app.AutoAdvanceCheckBox.Layout.Row = 2;
            app.AutoAdvanceCheckBox.Layout.Column = [17 18];

            app.MainGrid = uigridlayout(app.RootGrid, [1 3]);
            app.MainGrid.ColumnWidth = {360, '1x', 330};
            app.MainGrid.RowHeight = {'1x'};
            app.MainGrid.ColumnSpacing = 8;
            app.MainGrid.Padding = [0 0 0 0];

            app.LeftPanel = uipanel(app.MainGrid, "Title", "Datasets");
            leftGrid = uigridlayout(app.LeftPanel, [1 1]);
            leftGrid.Padding = [4 4 4 4];
            app.DatasetTable = uitable(leftGrid, "Data", app.datasetDisplayTable(), "CellSelectionCallback", @(src, event) app.onDatasetTableSelected(src, event));
            app.DatasetTable.ColumnName = {'Name', 'Channels', 'Total', 'Reviewed', 'Unreviewed', 'Good', 'Bad', 'Uncertain', 'Status'};
            app.DatasetActiveRowStyle = uistyle( ...
                "BackgroundColor", [0.82 0.91 1.00], ...
                "FontWeight", "bold");

            app.CenterPanel = uipanel(app.MainGrid, "Title", "Current block");
            centerGrid = uigridlayout(app.CenterPanel, [2 1]);
            centerGrid.RowHeight = {28, '1x'};
            centerGrid.ColumnWidth = {'1x'};
            centerGrid.Padding = [4 4 4 4];

            app.BlockNavigationGrid = uigridlayout(centerGrid, [1 4]);
            app.BlockNavigationGrid.RowHeight = {'1x'};
            app.BlockNavigationGrid.ColumnWidth = {'1x', 78, 130, 78};
            app.BlockNavigationGrid.ColumnSpacing = 4;
            app.BlockNavigationGrid.Padding = [0 0 0 0];

            app.TileSummaryLabel = uilabel(app.BlockNavigationGrid, "Text", "No source loaded", "FontWeight", "bold");
            app.TileSummaryLabel.Layout.Row = 1;
            app.TileSummaryLabel.Layout.Column = 1;

            app.PreviousBlockButton = uibutton(app.BlockNavigationGrid, "push", ...
                "Text", "< Block", ...
                "ButtonPushedFcn", @(src, event) app.goToPreviousBlock());
            app.PreviousBlockButton.Layout.Row = 1;
            app.PreviousBlockButton.Layout.Column = 2;

            app.BlockDropDown = uidropdown(app.BlockNavigationGrid, ...
                "Items", {'Block 1'}, ...
                "Value", 'Block 1', ...
                "ValueChangedFcn", @(src, event) app.onBlockDropDownChanged(src, event));
            app.BlockDropDown.Layout.Row = 1;
            app.BlockDropDown.Layout.Column = 3;

            app.NextBlockButton = uibutton(app.BlockNavigationGrid, "push", ...
                "Text", "Block >", ...
                "ButtonPushedFcn", @(src, event) app.goToNextBlock());
            app.NextBlockButton.Layout.Row = 1;
            app.NextBlockButton.Layout.Column = 4;

            app.TileGrid = uigridlayout(centerGrid, [1 1]);
            app.TileGrid.Padding = [2 2 2 2];
            app.TileGrid.RowSpacing = 0;
            app.TileGrid.ColumnSpacing = 0;
            app.TileGrid.BackgroundColor = 'k';

            app.MontageAxes = uiaxes(app.TileGrid);
            app.MontageAxes.Layout.Row = 1;
            app.MontageAxes.Layout.Column = 1;
            app.MontageAxes.XTick = [];
            app.MontageAxes.YTick = [];
            app.MontageAxes.Toolbar.Visible = "off";
            app.MontageAxes.Box = "on";
            app.MontageAxes.HitTest = "on";
            app.MontageAxes.PickableParts = "all";
            app.MontageAxes.ButtonDownFcn = @(src, event) app.onMontageClicked(src, event);
            disableDefaultInteractivity(app.MontageAxes);

            app.RightPanel = uipanel(app.MainGrid, "Title", "Selected detection");
            rightGrid = uigridlayout(app.RightPanel, [12 1]);
            rightGrid.RowHeight = {230, 38, 48, 30, 30, 30, 30, 24, 32, 24, '1x', 24};
            rightGrid.ColumnWidth = {'1x'};
            rightGrid.Padding = [4 4 4 4];

            app.DetailAxes = uiaxes(rightGrid);
            app.DetailAxes.XTick = [];
            app.DetailAxes.YTick = [];
            app.DetailAxes.Toolbar.Visible = "off";
            disableDefaultInteractivity(app.DetailAxes);

            app.DetailLabel = uilabel(rightGrid, "Text", "No detection selected", "FontWeight", "bold");

            app.CategoryButtonGrid = uigridlayout(rightGrid, [1 3]);
            app.CategoryButtonGrid.Padding = [0 0 0 0];
            app.CategoryButtonGrid.ColumnSpacing = 4;

            app.ThresholdClassifyButton = uibutton(rightGrid, "push", ...
                "Text", "Classify by score/rescore threshold...", ...
                "ButtonPushedFcn", @(src, event) app.openThresholdClassificationDialog());

            app.HistogramButton = uibutton(rightGrid, "push", ...
                "Text", "Plot score/rescore histogram...", ...
                "ButtonPushedFcn", @(src, event) app.openHistogramDialog());

            app.TissuePlotButton = uibutton(rightGrid, "push", ...
                "Text", "Plot full image QC map...", ...
                "ButtonPushedFcn", @(src, event) app.openTissuePlot());

            app.RecenterButton = uibutton(rightGrid, "push", ...
                "Text", "Update coordinate by click...", ...
                "ButtonPushedFcn", @(src, event) app.armCoordinateUpdate());

            uilabel(rightGrid, "Text", "Notes");
            app.NotesEdit = uieditfield(rightGrid, "text", "ValueChangedFcn", @(src, event) app.onNotesChanged(src, event));

            uilabel(rightGrid, "Text", "Original CSV metadata");
            app.MetadataTable = uitable(rightGrid, "Data", table(string.empty(0,1), string.empty(0,1), 'VariableNames', {'Field', 'Value'}));
            app.MetadataTable.ColumnName = {'Field', 'Value'};

            app.StatusLabel = uilabel(app.RootGrid, "Text", "Ready", "FontWeight", "bold");

            app.applyMainTooltips();
            app.bindKeyboardCallbacks();
        end

        function label = addToolbarLabel(app, text, row, col)
            arguments
                app
                text (1,1) string
                row (1,1) double
                col (1,1) double
            end

            label = uilabel(app.ToolbarGrid, "Text", text, "HorizontalAlignment", "right");
            label.Layout.Row = row;
            label.Layout.Column = col;
        end

        function setTooltip(app, component, tooltipText)
            arguments
                app
                component
                tooltipText (1,1) string
            end

            if isempty(component)
                return
            end

            component = component(:);
            for k = 1:numel(component)
                if isvalid(component(k)) && isprop(component(k), 'Tooltip')
                    component(k).Tooltip = char(tooltipText);
                end
            end
        end

        function applyMainTooltips(app)
            app.setTooltip(app.ParentDirEdit, "Parent folder scanned recursively for image/localization datasets. Default: last used folder.");
            app.setTooltip(app.BrowseButton, "Choose the parent folder containing nested datasets.");
            app.setTooltip(app.ScanButton, "Scan parent folder for *_proj.tif images and *_locs.csv localization files.");
            app.setTooltip(app.OpenDatasetFolderButton, "Open the folder containing the currently loaded dataset in the system file browser.");
            app.setTooltip(app.SourceDropDown, "Select the active localization CSV/channel for review. Default: first valid source.");
            app.setTooltip(app.DisplayModeDropDown, "Choose crop display channel mode. Default: Target channel only.");
            app.setTooltip(app.ContrastModeDropDown, "Choose display-only contrast scaling. Default: Auto per crop.");
            app.setTooltip(app.SettingsButton, "Open persistent app settings for file patterns, channels, categories, autosave, and markers.");
            app.setTooltip(app.SaveButton, "Save the active review table to a separate *_QC.csv file. Shortcut: Ctrl+S or s.");
            app.setTooltip(app.CellsPerBlockSpinner, "Number of detections displayed in each montage block. Default: 20.");
            app.setTooltip(app.CropWidthSpinner, "Crop width in pixels around each detection. Default: 64.");
            app.setTooltip(app.CropHeightSpinner, "Crop height in pixels around each detection. Default: 64.");
            app.setTooltip(app.LinkedSquareCheckBox, "Keep crop width and height equal. Default: on.");
            app.setTooltip(app.MarkerCheckBox, "Show or hide the localization marker in crop views. Default: on.");
            app.setTooltip(app.Sort1DropDown, "Primary sort column for the active source. Default: Original row order.");
            app.setTooltip(app.Sort1DirectionDropDown, "Primary sort direction. Default: Ascending.");
            app.setTooltip(app.Sort2DropDown, "Optional secondary sort column. Default: None.");
            app.setTooltip(app.Sort2DirectionDropDown, "Secondary sort direction. Default: Ascending.");
            app.setTooltip(app.FilterDropDown, "Limit displayed detections without deleting rows. Default: Show all.");
            app.setTooltip(app.AutoAdvanceCheckBox, "After single-cell classification, move to the next unreviewed visible cell. Default: on.");
            app.setTooltip(app.DatasetTable, "Select a dataset to load. The current dataset row is highlighted.");
            app.setTooltip(app.PreviousBlockButton, "Display previous montage block. Shortcuts: q or p.");
            app.setTooltip(app.BlockDropDown, "Jump directly to a montage block in the current filtered order.");
            app.setTooltip(app.NextBlockButton, "Display next montage block. Shortcuts: w or n.");
            app.setTooltip(app.MontageAxes, "Click a crop to select it. Hold a class key while clicking to classify that cell.");
            app.setTooltip(app.DetailAxes, "Large crop view for the selected detection.");
            app.setTooltip(app.DetailLabel, "Selected detection identity, channel, coordinates, and current QC label.");
            app.setTooltip(app.ThresholdClassifyButton, "Classify cells by score/rescore threshold using Above, Below, or Between.");
            app.setTooltip(app.HistogramButton, "Plot score/rescore histograms overlaid by QC class colors.");
            app.setTooltip(app.TissuePlotButton, "Open full-image QC map with class-colored points and ROI classification tools.");
            app.setTooltip(app.RecenterButton, "Arm the selected detection crop so the next click replaces this observation's X/Y after confirmation.");
            app.setTooltip(app.NotesEdit, "Optional notes for the selected detection; saved in QCNotes.");
            app.setTooltip(app.MetadataTable, "Original localization metadata for the selected source row.");
            app.setTooltip(app.StatusLabel, "Current dataset/source progress, save state, and warnings.");
        end

        function applySettingsToUI(app)
            if strlength(app.Settings.LastParentDirectory) > 0
                app.ParentDirEdit.Value = char(app.Settings.LastParentDirectory);
            end
            app.CellsPerBlockSpinner.Value = app.Settings.CellsPerBlock;
            app.CropWidthSpinner.Value = app.Settings.CropWidth;
            app.CropHeightSpinner.Value = app.Settings.CropHeight;
            app.LinkedSquareCheckBox.Value = app.Settings.LinkedSquareCropMode;
            app.MarkerCheckBox.Value = app.Settings.MarkerVisible;
            app.AutoAdvanceCheckBox.Value = app.Settings.AutoAdvanceAfterClassification;
            app.setDropDownValue(app.DisplayModeDropDown, app.Settings.DisplayMode);
            app.setDropDownValue(app.ContrastModeDropDown, app.Settings.ContrastMode);
            app.setDropDownValue(app.Sort1DropDown, app.Settings.SortColumn);
            app.setDropDownValue(app.Sort1DirectionDropDown, app.Settings.SortDirection);
            app.setDropDownValue(app.Sort2DropDown, app.Settings.SecondarySortColumn);
            app.setDropDownValue(app.Sort2DirectionDropDown, app.Settings.SecondarySortDirection);
            app.setDropDownValue(app.FilterDropDown, app.Settings.FilterMode);
        end

        function setDropDownValue(app, dropDown, value)
            arguments
                app
                dropDown
                value
            end

            items = string(dropDown.Items);
            value = string(value);
            if any(items == value)
                dropDown.Value = char(value);
            elseif ~isempty(items)
                dropDown.Value = char(items(1));
            end
        end

        function rebuildCategoryButtons(app)
            delete(app.CategoryButtonGrid.Children);
            n = numel(app.Categories);
            if n < 1
                n = 1;
            end
            app.CategoryButtonGrid.ColumnWidth = repmat({'1x'}, 1, n);
            app.CategoryButtons = cell(1, n);

            for k = 1:numel(app.Categories)
                cat = app.Categories(k);
                label = sprintf('%s [%s/%d]', char(string(cat.Name)), char(string(cat.Shortcut)), k);
                buttonColor = app.categoryEdgeColor(string(cat.Name));
                app.CategoryButtons{k} = uibutton(app.CategoryButtonGrid, "push", ...
                    "Text", label, ...
                    "BackgroundColor", buttonColor, ...
                    "FontColor", app.readableTextColor(buttonColor), ...
                    "ButtonPushedFcn", @(src, event) app.classifySelectedCellByIndex(k));
                app.CategoryButtons{k}.Layout.Row = 1;
                app.CategoryButtons{k}.Layout.Column = k;
                app.setTooltip(app.CategoryButtons{k}, sprintf('Classify selected detection as %s. Shortcut: %s or %d.', char(string(cat.Name)), char(string(cat.Shortcut)), k));
            end
            app.bindKeyboardCallbacks();
        end


        function openTissuePlot(app)
            if isempty(app.ActiveReviewTable) || height(app.ActiveReviewTable) == 0
                uialert(app.UIFigure, 'No active localization source is loaded.', 'No data');
                return
            end

            imagePage = app.getImagePage(double(app.ActiveSource.PageIndex));
            if isempty(imagePage)
                uialert(app.UIFigure, 'Could not load the active TIFF page.', 'Image unavailable');
                return
            end

            app.TissueFigure = figure('Name', 'Cell QC map', 'NumberTitle', 'off', ...
                'WindowKeyPressFcn', @(src, event) app.handleKeyPress(src, event), ...
                'WindowKeyReleaseFcn', @(src, event) app.handleKeyRelease(src, event));
            app.TissueAxes = axes('Parent', app.TissueFigure);
            app.TissueAxes.ButtonDownFcn = @(src, event) app.onTissuePlotClicked(src, event);
            app.installTissuePlotContextMenu();
            app.renderTissuePlot(imagePage);
        end

        function renderTissuePlot(app, imagePage)
            if isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end

            cla(app.TissueAxes)
            if ndims(imagePage) == 3
                imageForDisplay = imagePage;
                range = [];
            else
                imageForDisplay = imagePage;
                range = app.displayRangeForCrop(imagePage, double(app.ActiveSource.PageIndex));
            end

            if isempty(range)
                hImage = imshow(imageForDisplay, [], 'Parent', app.TissueAxes);
            else
                hImage = imshow(imageForDisplay, range, 'Parent', app.TissueAxes);
            end
            app.TissueImage = hImage;
            hImage.HitTest = 'on';
            hImage.PickableParts = 'all';
            hImage.ButtonDownFcn = @(src, event) app.onTissuePlotClicked(src, event);
            app.TissueAxes.ButtonDownFcn = @(src, event) app.onTissuePlotClicked(src, event);
            if ~isempty(app.TissueContextMenu) && isvalid(app.TissueContextMenu)
                app.attachContextMenu(hImage, app.TissueContextMenu);
                app.attachContextMenu(app.TissueAxes, app.TissueContextMenu);
            end

            hold(app.TissueAxes, 'on')
            app.drawTissueClassPoints();
            app.updateTissuePlotSelection();
            hold(app.TissueAxes, 'off')
            axis(app.TissueAxes, 'image')
            title(app.TissueAxes, sprintf('%s | %s page %d', ...
                char(app.DatasetList.Name(app.ActiveDatasetIndex)), ...
                char(app.safeText(app.ActiveSource.ChannelName, "")), ...
                double(app.ActiveSource.PageIndex)), 'Interpreter', 'none')
        end

        function installTissuePlotContextMenu(app)
            if isempty(app.TissueFigure) || ~isvalid(app.TissueFigure)
                return
            end

            cm = uicontextmenu(app.TissueFigure);
            uimenu(cm, 'Text', 'Draw freehand ROI and select cells', ...
                'Callback', @(src, event) app.selectTissueFreehandROI());

            classMenu = uimenu(cm, 'Text', 'Draw freehand ROI and classify as');
            for k = 1:numel(app.Categories)
                label = char(string(app.Categories(k).Name));
                uimenu(classMenu, 'Text', label, ...
                    'Callback', @(src, event) app.classifyTissueFreehandROI(k));
            end

            app.TissueContextMenu = cm;
            app.attachContextMenu(app.TissueFigure, cm);
            if ~isempty(app.TissueAxes) && isvalid(app.TissueAxes)
                app.attachContextMenu(app.TissueAxes, cm);
            end
        end

        function attachContextMenu(app, graphicsObject, contextMenu)
            arguments
                app
                graphicsObject
                contextMenu
            end

            if isempty(graphicsObject) || isempty(contextMenu)
                return
            end
            if ~isvalid(graphicsObject) || ~isvalid(contextMenu)
                return
            end

            if isprop(graphicsObject, 'ContextMenu')
                graphicsObject.ContextMenu = contextMenu;
            elseif isprop(graphicsObject, 'UIContextMenu')
                graphicsObject.UIContextMenu = contextMenu;
            end
        end

        function selectTissueFreehandROI(app)
            rows = app.drawTissueFreehandROIRows();
            if isempty(rows)
                return
            end

            app.selectGlobalRow(rows(1));
            app.updateStatus("Selected " + string(numel(rows)) + " cells from freehand ROI. Use the classify-as context menu to label the group.");
        end

        function classifyTissueFreehandROI(app, categoryIndex)
            arguments
                app
                categoryIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            if categoryIndex > numel(app.Categories)
                return
            end

            rows = app.drawTissueFreehandROIRows();
            if isempty(rows)
                return
            end

            app.classifyRows(rows, categoryIndex);
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.showCurrentBlock();
            app.updateProgress();
            app.updateStatus("Classified " + string(numel(rows)) + " ROI-selected cells as " + string(app.Categories(categoryIndex).Name) + ".");
        end

        function rows = drawTissueFreehandROIRows(app)
            rows = [];
            if isempty(app.ActiveReviewTable) || height(app.ActiveReviewTable) == 0
                return
            end
            if isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end
            if exist('drawfreehand', 'file') ~= 2
                warndlg('drawfreehand requires Image Processing Toolbox.', 'Freehand ROI unavailable');
                return
            end

            figure(app.TissueFigure)
            axes(app.TissueAxes)
            roi = drawfreehand(app.TissueAxes, ...
                'Color', [1 1 0], ...
                'LineWidth', 1.5, ...
                'FaceAlpha', 0.05);

            if isempty(roi) || ~isvalid(roi) || isempty(roi.Position) || size(roi.Position, 1) < 3
                if ~isempty(roi) && isvalid(roi)
                    delete(roi)
                end
                return
            end

            position = roi.Position;
            x = double(app.ActiveReviewTable.X);
            y = double(app.ActiveReviewTable.Y);
            keep = isfinite(x) & isfinite(y);
            inside = false(size(x));
            inside(keep) = inpolygon(x(keep), y(keep), position(:, 1), position(:, 2));
            rows = find(inside);

            if isempty(rows)
                delete(roi)
                app.updateStatus("Freehand ROI contained no localization points.");
                return
            end

            delete(roi)
        end

        function drawTissueClassPoints(app)
            if isempty(app.TissueAxes) || ~isvalid(app.TissueAxes) || isempty(app.ActiveReviewTable)
                return
            end

            x = double(app.ActiveReviewTable.X);
            y = double(app.ActiveReviewTable.Y);
            rows = find(isfinite(x) & isfinite(y));
            app.TissueClassPointHandle = [];
            app.TissueClassPointRows = rows(:);
            if isempty(rows)
                return
            end

            colors = app.tissuePointColorsForRows(rows);
            h = scatter(app.TissueAxes, x(rows), y(rows), 18, colors, 'filled', ...
                'MarkerFaceAlpha', 0.75, ...
                'MarkerEdgeColor', 'flat', ...
                'HitTest', 'off', ...
                'PickableParts', 'none', ...
                'DisplayName', 'Cells');
            h.Annotation.LegendInformation.IconDisplayStyle = 'off';
            app.TissueClassPointHandle = h;
            app.drawTissueClassLegend();
        end

        function drawTissueClassLegend(app)
            if isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end

            classLabels = app.reviewLabelsForHistogram();
            legendHandles = gobjects(0);
            for k = 1:numel(classLabels)
                label = classLabels(k);
                color = app.categoryEdgeColor(label);
                h = scatter(app.TissueAxes, NaN, NaN, 18, color, 'filled', ...
                    'MarkerFaceAlpha', 0.75, ...
                    'MarkerEdgeColor', color, ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none', ...
                    'DisplayName', char(label));
                legendHandles(end + 1) = h; %#ok<AGROW>
            end

            if ~isempty(legendHandles)
                legend(app.TissueAxes, legendHandles, 'Location', 'bestoutside', 'Interpreter', 'none')
            end
        end

        function updateTissuePlotClasses(app, rows)
            arguments
                app
                rows double = []
            end

            if isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end
            if isempty(app.TissueClassPointHandle) || ~isvalid(app.TissueClassPointHandle)
                return
            end
            if isempty(app.TissueClassPointRows)
                return
            end

            if isempty(rows)
                rows = app.TissueClassPointRows;
            else
                rows = unique(rows(:));
            end

            [isPlotted, plottedIdx] = ismember(rows, app.TissueClassPointRows);
            rows = rows(isPlotted);
            plottedIdx = plottedIdx(isPlotted);
            if isempty(rows)
                return
            end

            colors = app.tissuePointColorsForRows(rows);
            cData = app.TissueClassPointHandle.CData;
            cData(plottedIdx, :) = colors;
            app.TissueClassPointHandle.CData = cData;
        end

        function colors = tissuePointColorsForRows(app, rows)
            arguments
                app
                rows double
            end

            rows = rows(:);
            colors = zeros(numel(rows), 3);
            labels = string(app.ActiveReviewTable.QCLabel(rows));
            labels(ismissing(labels)) = "";
            labels(strlength(labels) == 0) = "Unreviewed";
            for k = 1:numel(rows)
                colors(k, :) = app.categoryEdgeColor(labels(k));
            end
        end

        function updateTissuePlotSelection(app)
            if isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end

            if ~isempty(app.TissueSelectionHandle) && isvalid(app.TissueSelectionHandle)
                delete(app.TissueSelectionHandle)
            end
            app.TissueSelectionHandle = [];

            rows = app.selectedRowsInCurrentBlock();
            rows = rows(rows >= 1 & rows <= height(app.ActiveReviewTable));
            if isempty(rows)
                return
            end

            x = double(app.ActiveReviewTable.X(rows));
            y = double(app.ActiveReviewTable.Y(rows));
            keep = isfinite(x) & isfinite(y);
            if ~any(keep)
                return
            end

            holdState = ishold(app.TissueAxes);
            hold(app.TissueAxes, 'on')
            app.TissueSelectionHandle = scatter(app.TissueAxes, x(keep), y(keep), 95, ...
                'o', 'MarkerFaceColor', 'none', 'MarkerEdgeColor', [1 1 1], ...
                'LineWidth', 1.8, 'HitTest', 'off', 'PickableParts', 'none', ...
                'DisplayName', 'Selected');
            if ~holdState
                hold(app.TissueAxes, 'off')
            end
        end

        function onTissuePlotClicked(app, src, event)
            arguments
                app
                src = []
                event = []
            end

            if isempty(app.ActiveReviewTable) || isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end
            point = app.TissueAxes.CurrentPoint;
            xClick = point(1, 1);
            yClick = point(1, 2);
            x = double(app.ActiveReviewTable.X);
            y = double(app.ActiveReviewTable.Y);
            keep = isfinite(x) & isfinite(y);
            if ~any(keep)
                return
            end

            dx = x - xClick;
            dy = y - yClick;
            d2 = dx.^2 + dy.^2;
            d2(~keep) = Inf;
            [minD2, rowIdx] = min(d2);
            if ~isfinite(minD2)
                return
            end

            imageWidth = double(app.ActiveTiffInfo(double(app.ActiveSource.PageIndex)).Width);
            imageHeight = double(app.ActiveTiffInfo(double(app.ActiveSource.PageIndex)).Height);
            maxClickDistance = max(5, 0.01 * hypot(imageWidth, imageHeight));
            if sqrt(minD2) > maxClickDistance
                return
            end

            if ~isnan(app.HeldClassIndex)
                app.classifyRows(rowIdx, app.HeldClassIndex);
                app.HeldClassUsedForClick = true;
                app.buildDisplayOrder();
                app.applyFilter(false);
                app.selectGlobalRow(rowIdx);
                app.updateProgress();
                app.updateStatus("Classified tissue-map cell as " + string(app.Categories(app.HeldClassIndex).Name) + ".");
                return
            end

            app.selectGlobalRow(rowIdx);
        end

        function selectGlobalRow(app, rowIdx)
            arguments
                app
                rowIdx (1,1) double {mustBeInteger, mustBePositive}
            end

            if isempty(app.FilteredOrder) || rowIdx > height(app.ActiveReviewTable)
                return
            end

            position = find(app.FilteredOrder == rowIdx, 1, 'first');
            if isempty(position)
                app.FilterDropDown.Value = 'Show all';
                app.Settings.FilterMode = "Show all";
                app.buildDisplayOrder();
                app.applyFilter(false);
                position = find(app.FilteredOrder == rowIdx, 1, 'first');
            end
            if isempty(position)
                return
            end

            app.BlockStartIndex = floor((position - 1) / app.Settings.CellsPerBlock) * app.Settings.CellsPerBlock + 1;
            app.SelectedVisibleIndex = position - app.BlockStartIndex + 1;
            app.SelectedVisibleIndices = app.SelectedVisibleIndex;
            app.SelectedGlobalRow = rowIdx;
            app.showCurrentBlock();
        end

        function openHistogramDialog(app)
            if isempty(app.ActiveReviewTable) || height(app.ActiveReviewTable) == 0
                uialert(app.UIFigure, 'Load a localization source before plotting a histogram.', 'No active source');
                return
            end

            columns = app.scoreHistogramColumns();
            if isempty(columns)
                uialert(app.UIFigure, 'The active source has no numeric score or rescore column.', 'No score column');
                return
            end

            defaultColumn = app.pickDefaultHistogramColumn(columns);
            if numel(columns) == 1
                app.plotClassificationHistogram(defaultColumn);
                return
            end

            dlg = uifigure('Name', 'Plot score histogram', 'Position', [400 400 360 145], 'WindowStyle', 'modal');
            grid = uigridlayout(dlg, [3 2]);
            grid.RowHeight = {28, '1x', 34};
            grid.ColumnWidth = {90, '1x'};
            grid.Padding = [12 12 12 12];
            grid.RowSpacing = 8;
            grid.ColumnSpacing = 8;

            uilabel(grid, 'Text', 'Column', 'HorizontalAlignment', 'right');
            columnDropDown = uidropdown(grid, 'Items', columns, 'Value', char(defaultColumn));
            app.setTooltip(columnDropDown, "Numeric score column to histogram. Default: rescore if present, otherwise score.");

            helpText = uilabel(grid, 'Text', 'Histograms are overlaid by current QC class using the same class colors as the montage borders.');
            helpText.Layout.Column = [1 2];

            buttonGrid = uigridlayout(grid, [1 3]);
            buttonGrid.Layout.Column = [1 2];
            buttonGrid.ColumnWidth = {'1x', 90, 90};
            buttonGrid.Padding = [0 0 0 0];
            uilabel(buttonGrid, 'Text', '');
            plotButton = uibutton(buttonGrid, 'push', 'Text', 'Plot', 'ButtonPushedFcn', @(src, event) app.applyHistogramDialog(dlg));
            cancelButton = uibutton(buttonGrid, 'push', 'Text', 'Cancel', 'ButtonPushedFcn', @(src, event) delete(dlg));
            app.setTooltip(plotButton, "Create class-colored overlaid histogram in a new MATLAB figure.");
            app.setTooltip(cancelButton, "Close without plotting.");

            controls = struct();
            controls.ColumnDropDown = columnDropDown;
            dlg.UserData = controls;
        end

        function applyHistogramDialog(app, dlg)
            if isempty(app.ActiveReviewTable) || height(app.ActiveReviewTable) == 0 || ~isvalid(dlg)
                return
            end

            controls = dlg.UserData;
            columnName = string(controls.ColumnDropDown.Value);
            app.plotClassificationHistogram(columnName);
            delete(dlg);
        end

        function plotClassificationHistogram(app, columnName)
            arguments
                app
                columnName (1,1) string
            end

            if isempty(app.ActiveReviewTable) || height(app.ActiveReviewTable) == 0
                uialert(app.UIFigure, 'Load a localization source before plotting a histogram.', 'No active source');
                return
            end
            if ~ismember(columnName, string(app.ActiveReviewTable.Properties.VariableNames))
                uialert(app.UIFigure, 'Selected histogram column is no longer available.', 'Invalid column');
                return
            end

            values = app.ActiveReviewTable.(char(columnName));
            if ~isnumeric(values) && ~islogical(values)
                uialert(app.UIFigure, 'Selected histogram column is not numeric.', 'Invalid column');
                return
            end
            values = double(values(:));
            finiteMask = isfinite(values);
            if ~any(finiteMask)
                uialert(app.UIFigure, 'Selected column has no finite numeric values.', 'No finite values');
                return
            end

            app.Settings.HistogramColumn = columnName;
            app.saveSettings();

            finiteValues = values(finiteMask);
            lo = min(finiteValues);
            hi = max(finiteValues);
            if lo == hi
                pad = max(abs(lo) * 0.05, 0.5);
                lo = lo - pad;
                hi = hi + pad;
            end
            edges = linspace(lo, hi, 41);

            figName = char(columnName + " histogram by QC class");
            fig = figure('Name', figName, 'NumberTitle', 'off');
            ax = axes('Parent', fig);
            hold(ax, 'on')

            labels = app.reviewLabelsForHistogram();
            plottedLabels = strings(1, 0);
            for k = 1:numel(labels)
                label = labels(k);
                labelMask = app.histogramLabelMask(label) & finiteMask;
                if ~any(labelMask)
                    continue
                end

                histogram(ax, values(labelMask), ...
                    'BinEdges', edges, ...
                    'DisplayStyle', 'stairs', ...
                    'LineWidth', 2, ...
                    'EdgeColor', app.categoryEdgeColor(label));
                plottedLabels(end + 1) = label; %#ok<AGROW>
            end

            hold(ax, 'off')
            xlabel(ax, char(columnName), 'Interpreter', 'none')
            ylabel(ax, 'Count')
            title(ax, app.histogramTitle(columnName), 'Interpreter', 'none')
            grid(ax, 'on')
            if ~isempty(plottedLabels)
                legend(ax, cellstr(plottedLabels), 'Interpreter', 'none', 'Location', 'best')
            end
        end

        function columns = scoreHistogramColumns(app)
            if isempty(app.ActiveReviewTable)
                columns = strings(1, 0);
                return
            end

            names = string(app.ActiveReviewTable.Properties.VariableNames);
            preferred = ["rescore", "score"];
            columns = strings(1, 0);
            for k = 1:numel(preferred)
                idx = find(strcmpi(names, preferred(k)), 1, 'first');
                if isempty(idx)
                    continue
                end
                values = app.ActiveReviewTable.(char(names(idx)));
                if isnumeric(values) || islogical(values)
                    columns(end + 1) = names(idx); %#ok<AGROW>
                end
            end
        end

        function column = pickDefaultHistogramColumn(app, columns)
            column = columns(1);
            if isfield(app.Settings, 'HistogramColumn')
                savedColumn = string(app.Settings.HistogramColumn);
                idx = find(columns == savedColumn, 1, 'first');
                if ~isempty(idx)
                    column = columns(idx);
                end
            end
        end

        function labels = reviewLabelsForHistogram(app)
            labels = "Unreviewed";
            for k = 1:numel(app.Categories)
                labels(end + 1) = string(app.Categories(k).Name); %#ok<AGROW>
            end

            if isempty(app.ActiveReviewTable) || ~ismember("QCLabel", string(app.ActiveReviewTable.Properties.VariableNames))
                return
            end

            tableLabels = string(app.ActiveReviewTable.QCLabel);
            tableLabels(ismissing(tableLabels)) = "";
            tableLabels = unique(tableLabels(strlength(tableLabels) > 0), 'stable');
            for k = 1:numel(tableLabels)
                if ~ismember(tableLabels(k), labels)
                    labels(end + 1) = tableLabels(k); %#ok<AGROW>
                end
            end
        end

        function mask = histogramLabelMask(app, label)
            labels = string(app.ActiveReviewTable.QCLabel);
            labels(ismissing(labels)) = "";
            if label == "Unreviewed"
                mask = strlength(labels) == 0;
            else
                mask = labels == label;
            end
        end

        function titleText = histogramTitle(app, columnName)
            sourceText = "";
            if ~isempty(app.ActiveSource) && isfield(app.ActiveSource, 'ChannelName')
                sourceText = app.safeText(app.ActiveSource.ChannelName, "");
            end
            if strlength(sourceText) > 0
                titleText = columnName + " by QC class - " + sourceText;
            else
                titleText = columnName + " by QC class";
            end
        end

        function openThresholdClassificationDialog(app)
            if isempty(app.ActiveReviewTable) || height(app.ActiveReviewTable) == 0
                uialert(app.UIFigure, 'Load a localization source before threshold classification.', 'No active source');
                return
            end

            numericColumns = app.numericLocalizationColumns();
            if isempty(numericColumns)
                uialert(app.UIFigure, 'The active source has no numeric localization columns available for threshold classification.', 'No numeric columns');
                return
            end

            defaultColumn = app.pickDefaultThresholdColumn(numericColumns);
            defaultClass = string(app.Categories(1).Name);
            if isfield(app.Settings, 'ThresholdClass') && any(string({app.Categories.Name}) == string(app.Settings.ThresholdClass))
                defaultClass = string(app.Settings.ThresholdClass);
            end

            dlg = uifigure('Name', 'Classify by threshold', 'Position', [350 350 460 300], 'WindowStyle', 'modal');
            grid = uigridlayout(dlg, [8 2]);
            grid.RowHeight = {28, 28, 28, 28, 28, 28, '1x', 34};
            grid.ColumnWidth = {145, '1x'};
            grid.Padding = [12 12 12 12];
            grid.RowSpacing = 8;
            grid.ColumnSpacing = 8;

            uilabel(grid, 'Text', 'Column', 'HorizontalAlignment', 'right');
            columnDropDown = uidropdown(grid, 'Items', numericColumns, 'Value', char(defaultColumn));
            app.setTooltip(columnDropDown, "Numeric column used for threshold classification. Default: rescore if present.");

            uilabel(grid, 'Text', 'Condition', 'HorizontalAlignment', 'right');
            conditionDropDown = uidropdown(grid, 'Items', ["Above", "Below", "Between"], 'Value', char(app.validThresholdMode()));
            app.setTooltip(conditionDropDown, "Threshold rule: above lower, below lower, or inclusive between lower and upper.");

            uilabel(grid, 'Text', 'Threshold', 'HorizontalAlignment', 'right');
            lowerEdit = uieditfield(grid, 'numeric', 'Value', app.validThresholdLower());
            app.setTooltip(lowerEdit, "Lower threshold value. Default: last used value.");

            uilabel(grid, 'Text', 'Upper threshold', 'HorizontalAlignment', 'right');
            upperEdit = uieditfield(grid, 'numeric', 'Value', app.validThresholdUpper());
            app.setTooltip(upperEdit, "Upper threshold for Between mode. Default: last used value.");

            uilabel(grid, 'Text', 'Class', 'HorizontalAlignment', 'right');
            classDropDown = uidropdown(grid, 'Items', string({app.Categories.Name}), 'Value', char(defaultClass));
            app.setTooltip(classDropDown, "QC class assigned to matching cells. Default: last used class.");

            uilabel(grid, 'Text', 'Scope', 'HorizontalAlignment', 'right');
            scopeDropDown = uidropdown(grid, 'Items', ["All cells in active source", "Current filtered cells"], 'Value', char(app.validThresholdScope()));
            app.setTooltip(scopeDropDown, "Apply to all active-source rows or only rows passing the current filter.");

            helpText = uilabel(grid, 'Text', 'Above/below use Threshold. Between is inclusive and uses Threshold through Upper threshold. NaN values are ignored.');
            helpText.Layout.Column = [1 2];

            buttonGrid = uigridlayout(grid, [1 3]);
            buttonGrid.Layout.Column = [1 2];
            buttonGrid.ColumnWidth = {'1x', 90, 90};
            buttonGrid.Padding = [0 0 0 0];
            uilabel(buttonGrid, 'Text', '');
            applyButton = uibutton(buttonGrid, 'push', 'Text', 'Apply', 'ButtonPushedFcn', @(src, event) app.applyThresholdClassificationDialog(dlg));
            cancelButton = uibutton(buttonGrid, 'push', 'Text', 'Cancel', 'ButtonPushedFcn', @(src, event) delete(dlg));
            app.setTooltip(applyButton, "Classify all cells matching the threshold rule and save through normal QC workflow.");
            app.setTooltip(cancelButton, "Close without changing classifications.");

            controls = struct();
            controls.ColumnDropDown = columnDropDown;
            controls.ConditionDropDown = conditionDropDown;
            controls.LowerEdit = lowerEdit;
            controls.UpperEdit = upperEdit;
            controls.ClassDropDown = classDropDown;
            controls.ScopeDropDown = scopeDropDown;
            dlg.UserData = controls;
        end

        function applyThresholdClassificationDialog(app, dlg)
            if isempty(app.ActiveReviewTable) || height(app.ActiveReviewTable) == 0 || ~isvalid(dlg)
                return
            end

            controls = dlg.UserData;
            columnName = string(controls.ColumnDropDown.Value);
            condition = string(controls.ConditionDropDown.Value);
            lowerThreshold = double(controls.LowerEdit.Value);
            upperThreshold = double(controls.UpperEdit.Value);
            className = string(controls.ClassDropDown.Value);
            scope = string(controls.ScopeDropDown.Value);

            if ~ismember(columnName, string(app.ActiveReviewTable.Properties.VariableNames))
                uialert(dlg, 'Selected column is no longer available.', 'Invalid column');
                return
            end
            if ~isfinite(lowerThreshold)
                uialert(dlg, 'Threshold must be finite.', 'Invalid threshold');
                return
            end
            if condition == "Between" && ~isfinite(upperThreshold)
                uialert(dlg, 'Upper threshold must be finite for Between.', 'Invalid threshold');
                return
            end

            categoryIndex = find(string({app.Categories.Name}) == className, 1, 'first');
            if isempty(categoryIndex)
                uialert(dlg, 'Selected class is no longer available.', 'Invalid class');
                return
            end

            values = app.ActiveReviewTable.(char(columnName));
            if ~isnumeric(values) && ~islogical(values)
                uialert(dlg, 'Selected column is not numeric.', 'Invalid column');
                return
            end
            values = double(values);

            candidateRows = (1:height(app.ActiveReviewTable))';
            if scope == "Current filtered cells"
                candidateRows = app.FilteredOrder(:);
            end
            candidateRows = candidateRows(candidateRows >= 1 & candidateRows <= height(app.ActiveReviewTable));
            if isempty(candidateRows)
                uialert(dlg, 'No rows are available in the selected scope.', 'No rows');
                return
            end

            scopedValues = values(candidateRows);
            switch condition
                case "Above"
                    matched = candidateRows(isfinite(scopedValues) & scopedValues > lowerThreshold);
                case "Below"
                    matched = candidateRows(isfinite(scopedValues) & scopedValues < lowerThreshold);
                case "Between"
                    lo = min(lowerThreshold, upperThreshold);
                    hi = max(lowerThreshold, upperThreshold);
                    matched = candidateRows(isfinite(scopedValues) & scopedValues >= lo & scopedValues <= hi);
                otherwise
                    matched = [];
            end

            app.Settings.ThresholdColumn = columnName;
            app.Settings.ThresholdMode = condition;
            app.Settings.ThresholdLower = lowerThreshold;
            app.Settings.ThresholdUpper = upperThreshold;
            app.Settings.ThresholdClass = className;
            app.Settings.ThresholdScope = scope;
            app.saveSettings();

            if isempty(matched)
                app.updateStatus("No cells matched threshold rule.");
                delete(dlg);
                return
            end

            oldBlockStart = app.BlockStartIndex;
            oldSelectedVisibleIndex = app.SelectedVisibleIndex;
            app.classifyRows(matched, categoryIndex);
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.BlockStartIndex = app.clampBlockStart(oldBlockStart);
            blockEnd = min(app.BlockStartIndex + app.Settings.CellsPerBlock - 1, numel(app.FilteredOrder));
            visibleCount = max(blockEnd - app.BlockStartIndex + 1, 0);
            if visibleCount > 0
                app.SelectedVisibleIndex = min(max(oldSelectedVisibleIndex, 1), visibleCount);
                app.SelectedVisibleIndices = app.SelectedVisibleIndex;
            else
                app.SelectedVisibleIndex = 1;
                app.SelectedVisibleIndices = [];
            end
            app.showCurrentBlock();
            app.updateProgress();
            app.updateStatus("Threshold classified " + string(numel(matched)) + " cells as " + className + ".");
            delete(dlg);
        end

        function columns = numericLocalizationColumns(app)
            if isempty(app.ActiveReviewTable)
                columns = strings(1, 0);
                return
            end
            names = string(app.ActiveReviewTable.Properties.VariableNames);
            keep = false(size(names));
            for k = 1:numel(names)
                if startsWith(names(k), "QC")
                    continue
                end
                values = app.ActiveReviewTable.(char(names(k)));
                keep(k) = isnumeric(values) || islogical(values);
            end
            columns = names(keep);
            preferred = ["rescore", "score"];
            ordered = strings(1, 0);
            for k = 1:numel(preferred)
                idx = find(strcmpi(columns, preferred(k)), 1, 'first');
                if ~isempty(idx)
                    ordered(end + 1) = columns(idx); %#ok<AGROW>
                    columns(idx) = [];
                end
            end
            columns = [ordered, columns];
        end

        function column = pickDefaultThresholdColumn(app, columns)
            column = columns(1);
            if isfield(app.Settings, 'ThresholdColumn')
                savedColumn = string(app.Settings.ThresholdColumn);
                idx = find(columns == savedColumn, 1, 'first');
                if ~isempty(idx)
                    column = columns(idx);
                end
            end
        end

        function mode = validThresholdMode(app)
            mode = "Above";
            if isfield(app.Settings, 'ThresholdMode')
                savedMode = string(app.Settings.ThresholdMode);
                if any(savedMode == ["Above", "Below", "Between"])
                    mode = savedMode;
                end
            end
        end

        function value = validThresholdLower(app)
            value = 0;
            if isfield(app.Settings, 'ThresholdLower') && isnumeric(app.Settings.ThresholdLower) && isscalar(app.Settings.ThresholdLower) && isfinite(app.Settings.ThresholdLower)
                value = double(app.Settings.ThresholdLower);
            end
        end

        function value = validThresholdUpper(app)
            value = 1;
            if isfield(app.Settings, 'ThresholdUpper') && isnumeric(app.Settings.ThresholdUpper) && isscalar(app.Settings.ThresholdUpper) && isfinite(app.Settings.ThresholdUpper)
                value = double(app.Settings.ThresholdUpper);
            end
        end

        function scope = validThresholdScope(app)
            scope = "All cells in active source";
            if isfield(app.Settings, 'ThresholdScope')
                savedScope = string(app.Settings.ThresholdScope);
                if any(savedScope == ["All cells in active source", "Current filtered cells"])
                    scope = savedScope;
                end
            end
        end

        function onScanButtonPushed(app, src, event)
            arguments
                app
                src
                event
            end

            app.scanParentDirectory(true);
        end

        function openActiveDatasetFolder(app)
            arguments
                app
            end

            if app.ActiveDatasetIndex < 1 || isempty(app.DatasetList) || app.ActiveDatasetIndex > height(app.DatasetList)
                uialert(app.UIFigure, "No dataset is currently loaded.", "Open Folder");
                return
            end

            folderPath = string(app.DatasetList.Folder(app.ActiveDatasetIndex));
            if strlength(folderPath) == 0 || ~isfolder(folderPath)
                uialert(app.UIFigure, "The current dataset folder could not be found.", "Open Folder");
                return
            end

            app.openFolderInSystemBrowser(folderPath);
        end

        function chooseParentDirectory(app)
            startDir = app.ParentDirectory;
            if strlength(startDir) == 0 || ~isfolder(startDir)
                startDir = string(pwd);
            end
            selected = uigetdir(char(startDir), 'Select parent directory containing image datasets');
            if isequal(selected, 0)
                return
            end
            app.ParentDirectory = string(selected);
            app.ParentDirEdit.Value = char(app.ParentDirectory);
            app.Settings.LastParentDirectory = app.ParentDirectory;
            app.saveSettings();
            app.scanParentDirectory(true);
        end

        function onParentDirEdited(app, src, event)
            arguments
                app
                src
                event
            end

            app.ParentDirectory = string(strtrim(src.Value));
            app.Settings.LastParentDirectory = app.ParentDirectory;
            app.saveSettings();
        end

        function scanParentDirectory(app, loadLast)
            arguments
                app
                loadLast (1,1) logical = true
            end

            app.readSettingsFromUI();
            parentDir = string(strtrim(app.ParentDirEdit.Value));
            if strlength(parentDir) == 0 || ~isfolder(parentDir)
                app.updateStatus("Parent directory does not exist.");
                uialert(app.UIFigure, 'Parent directory does not exist.', 'Invalid parent directory');
                return
            end

            app.saveIfDirtyForTransition();
            app.ParentDirectory = parentDir;
            app.Settings.LastParentDirectory = parentDir;
            app.saveSettings();
            app.updateStatus("Scanning for image datasets...");
            drawnow

            app.DatasetList = app.emptyDatasetTable();
            app.SourceListByDataset = {};
            app.ActiveDatasetIndex = 0;
            app.ActiveSourceIndex = 0;
            app.ActiveSource = struct();
            app.ActiveLocalizationTable = table();
            app.ActiveReviewTable = table();
            app.ActiveImagePages = struct();
            app.ActiveTiffInfo = [];

            imagePattern = char(app.Settings.ImagePattern);
            imageFiles = dir(fullfile(char(parentDir), '**', imagePattern));

            for k = 1:numel(imageFiles)
                imagePath = string(fullfile(imageFiles(k).folder, imageFiles(k).name));
                [~, imageBase, ~] = fileparts(imageFiles(k).name);
                datasetID = app.makeRelativePath(imagePath, parentDir);

                [tiffInfo, imageStatus] = app.inspectTiff(imagePath);
                pageCount = numel(tiffInfo);
                sources = app.emptySourceStruct();

                csvFiles = dir(fullfile(imageFiles(k).folder, char(app.Settings.LocalizationPattern)));
                csvFiles = csvFiles(startsWith(string({csvFiles.name}), string(imageBase)));

                for j = 1:numel(csvFiles)
                    csvPath = string(fullfile(csvFiles(j).folder, csvFiles(j).name));
                    [channelName, pageIndex] = app.parseLocalizationFilename(csvFiles(j).name, imageBase);
                    if isnan(pageIndex)
                        pageIndex = app.pageForChannel(channelName);
                    end
                    if isnan(pageIndex)
                        pageIndex = 1;
                    end

                    [numRows, hasRequiredColumns, csvStatus] = app.inspectLocalizationCsv(csvPath);
                    sourceStatus = csvStatus;
                    if pageCount > 0 && pageIndex > pageCount
                        sourceStatus = app.appendStatus(sourceStatus, sprintf('TIFF has %d page(s), requested page %d', pageCount, pageIndex));
                    end
                    if strlength(sourceStatus) == 0
                        sourceStatus = "Ready";
                    end

                    qcPath = app.qcPathForCsv(csvPath);
                    counts = app.readQCCounts(qcPath);
                    source = struct( ...
                        'DatasetID', string(datasetID), ...
                        'ImagePath', string(imagePath), ...
                        'CsvPath', string(csvPath), ...
                        'QCPath', string(qcPath), ...
                        'ChannelName', string(channelName), ...
                        'PageIndex', double(pageIndex), ...
                        'NumRows', double(numRows), ...
                        'HasRequiredColumns', logical(hasRequiredColumns), ...
                        'Status', string(sourceStatus), ...
                        'Reviewed', double(counts.Reviewed), ...
                        'Good', double(counts.Good), ...
                        'Bad', double(counts.Bad), ...
                        'Uncertain', double(counts.Uncertain), ...
                        'LastReviewedTime', counts.LastReviewedTime);
                    sources(end + 1, 1) = source;
                end

                if isempty(sources)
                    datasetStatus = app.appendStatus(imageStatus, "No localization CSV files found");
                else
                    sourceStatuses = strings(numel(sources), 1);
                    for statusIndex = 1:numel(sources)
                        sourceStatuses(statusIndex) = string(sources(statusIndex).Status);
                    end
                    if any(sourceStatuses ~= "Ready")
                        datasetStatus = app.appendStatus(imageStatus, "One or more sources need attention");
                    else
                        datasetStatus = app.appendStatus(imageStatus, "Ready");
                    end
                end

                totalDetections = sum([sources.NumRows]);
                reviewed = sum([sources.Reviewed]);
                good = sum([sources.Good]);
                bad = sum([sources.Bad]);
                uncertain = sum([sources.Uncertain]);
                channels = app.joinSourceChannels(sources);
                lastReviewed = app.maxSourceTime(sources);

                newRow = table(string(datasetID), string(imageBase), string(imageFiles(k).folder), string(imagePath), channels, ...
                    double(numel(sources)), double(totalDetections), double(reviewed), double(max(totalDetections - reviewed, 0)), ...
                    double(good), double(bad), double(uncertain), string(datasetStatus), lastReviewed, ...
                    'VariableNames', app.datasetVariableNames());

                app.DatasetList = [app.DatasetList; newRow]; %#ok<AGROW>
                app.SourceListByDataset{height(app.DatasetList), 1} = sources;
            end

            app.updateDatasetTable();
            app.refreshSourceDropDown();

            if height(app.DatasetList) == 0
                app.updateStatus("No image files matched " + string(app.Settings.ImagePattern) + ".");
                return
            end

            indexToLoad = 1;
            if loadLast && strlength(app.Settings.LastActiveDataset) > 0
                found = find(app.DatasetList.DatasetID == string(app.Settings.LastActiveDataset), 1, 'first');
                if ~isempty(found)
                    indexToLoad = found;
                end
            end
            app.loadDataset(indexToLoad);
            app.updateStatus(sprintf('Scan complete: %d dataset(s).', height(app.DatasetList)));
        end

        function [tiffInfo, status] = inspectTiff(app, imagePath)
            arguments
                app
                imagePath (1,1) string
            end

            tiffInfo = [];
            status = "";
            if ~isfile(imagePath)
                status = "Image file missing";
                return
            end
            try
                tiffInfo = imfinfo(char(imagePath));
            catch ME
                status = "TIFF read error: " + string(ME.message);
            end
        end

        function [numRows, hasRequiredColumns, status] = inspectLocalizationCsv(app, csvPath)
            arguments
                app
                csvPath (1,1) string
            end

            numRows = 0;
            hasRequiredColumns = false;
            status = "";
            if ~isfile(csvPath)
                status = "CSV file missing";
                return
            end

            try
                tbl = readtable(char(csvPath), 'TextType', 'string', 'VariableNamingRule', 'preserve');
            catch ME
                status = "CSV read error: " + string(ME.message);
                return
            end

            numRows = height(tbl);
            names = string(tbl.Properties.VariableNames);
            hasRequiredColumns = all(ismember(["X", "Y"], names));
            if ~hasRequiredColumns
                status = "Missing required X/Y columns";
                return
            end

            [~, xyStatus] = app.ensureNumericXY(tbl);
            if strlength(xyStatus) > 0
                status = xyStatus;
            end
        end

        function [channelName, pageIndex] = parseLocalizationFilename(app, csvName, imageBase)
            arguments
                app
                csvName
                imageBase
            end

            [~, csvBase, ~] = fileparts(csvName);
            pattern = ['^' regexptranslate('escape', char(imageBase)) '_(?<suffix>.+)_locs$'];
            match = regexp(char(csvBase), pattern, 'names', 'once');
            channelName = "Source";
            pageIndex = NaN;
            if isempty(match)
                return
            end

            suffix = string(match.suffix);
            token = regexp(char(suffix), '^(?<channel>[A-Za-z_]+?)(?<page>\d+)$', 'names', 'once');
            if isempty(token)
                channelName = suffix;
                return
            end

            channelName = string(token.channel);
            pageIndex = str2double(token.page);
        end

        function pageIndex = pageForChannel(app, channelName)
            arguments
                app
                channelName
            end

            pageIndex = NaN;
            channelName = string(channelName);
            map = app.Settings.ChannelMap;
            for k = 1:numel(map)
                if strcmpi(string(map(k).Channel), channelName)
                    pageIndex = double(map(k).PageIndex);
                    return
                end
            end
        end

        function loadDataset(app, datasetIndex)
            arguments
                app
                datasetIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            if datasetIndex > height(app.DatasetList)
                return
            end

            app.saveIfDirtyForTransition();
            app.ActiveDatasetIndex = datasetIndex;
            app.updateDatasetTable();
            app.ActiveSourceIndex = 0;
            app.ActiveSource = struct();
            app.ActiveLocalizationTable = table();
            app.ActiveReviewTable = table();
            app.ActiveImagePages = struct();
            app.ActiveContrastLimits = struct();
            app.ActiveTiffInfo = [];
            app.DisplayOrder = [];
            app.FilteredOrder = [];
            app.BlockStartIndex = 1;
            app.SelectedVisibleIndex = 1;
            app.SelectedVisibleIndices = [];
            app.SelectedGlobalRow = NaN;
            app.Dirty = false;
            app.UndoStack = {};
            app.ClassificationsSinceSave = 0;

            imagePath = app.DatasetList.ImagePath(datasetIndex);
            [app.ActiveTiffInfo, status] = app.inspectTiff(imagePath);
            if strlength(status) > 0
                app.updateStatus(status);
            end

            app.Settings.LastActiveDataset = app.DatasetList.DatasetID(datasetIndex);
            app.saveSettings();
            app.refreshSourceDropDown();

            sources = app.SourceListByDataset{datasetIndex};
            if isempty(sources)
                app.clearTiles("No localization sources found for this dataset.");
                app.updateSelectedCellDetail();
                return
            end

            sourceIndex = 1;
            if strlength(app.Settings.LastActiveLocalizationSource) > 0
                sourceIDs = strings(numel(sources), 1);
                for k = 1:numel(sources)
                    sourceIDs(k) = app.sourceIdentity(sources(k));
                end
                found = find(sourceIDs == string(app.Settings.LastActiveLocalizationSource), 1, 'first');
                if ~isempty(found)
                    sourceIndex = found;
                end
            end

            app.SourceDropDown.Value = sourceIndex;
            app.loadLocalizationSource(sourceIndex);
        end

        function refreshSourceDropDown(app)
            if app.ActiveDatasetIndex < 1 || app.ActiveDatasetIndex > numel(app.SourceListByDataset)
                app.SourceDropDown.Items = ["No source"];
                app.SourceDropDown.ItemsData = 1;
                app.SourceDropDown.Value = 1;
                return
            end

            sources = app.SourceListByDataset{app.ActiveDatasetIndex};
            if isempty(sources)
                app.SourceDropDown.Items = ["No source"];
                app.SourceDropDown.ItemsData = 1;
                app.SourceDropDown.Value = 1;
                return
            end

            items = cell(numel(sources), 1);
            for k = 1:numel(sources)
                items{k} = sprintf('%s page %d (%d rows)', char(string(sources(k).ChannelName)), sources(k).PageIndex, sources(k).NumRows);
            end
            app.SourceDropDown.Items = items;
            app.SourceDropDown.ItemsData = 1:numel(sources);
            app.SourceDropDown.Value = 1;
        end

        function onSourceChanged(app, src, event)
            arguments
                app
                src
                event
            end

            if app.ActiveDatasetIndex < 1 || isempty(app.SourceListByDataset)
                return
            end
            value = src.Value;
            if isempty(value) || ~isnumeric(value)
                return
            end
            app.loadLocalizationSource(double(value));
        end

        function loadLocalizationSource(app, sourceIndex)
            arguments
                app
                sourceIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            if app.ActiveDatasetIndex < 1 || app.ActiveDatasetIndex > numel(app.SourceListByDataset)
                return
            end

            sources = app.SourceListByDataset{app.ActiveDatasetIndex};
            if sourceIndex > numel(sources)
                return
            end

            app.saveIfDirtyForTransition();
            source = sources(sourceIndex);
            app.ActiveSourceIndex = sourceIndex;
            app.ActiveSource = source;
            app.ActiveLocalizationTable = table();
            app.ActiveReviewTable = table();
            app.ActiveImagePages = struct();
            app.ActiveContrastLimits = struct();
            app.DisplayOrder = [];
            app.FilteredOrder = [];
            app.BlockStartIndex = 1;
            app.SelectedVisibleIndex = 1;
            app.SelectedVisibleIndices = [];
            app.SelectedGlobalRow = NaN;
            app.Dirty = false;
            app.UndoStack = {};
            app.ClassificationsSinceSave = 0;

            app.Settings.LastActiveLocalizationSource = app.sourceIdentity(source);
            app.saveSettings();

            if strlength(source.Status) > 0 && source.Status ~= "Ready"
                app.updateStatus("Source warning: " + string(source.Status));
            end

            if isempty(app.ActiveTiffInfo)
                [app.ActiveTiffInfo, status] = app.inspectTiff(source.ImagePath);
                if strlength(status) > 0
                    app.clearTiles(status);
                    app.updateSelectedCellDetail();
                    return
                end
            end

            if source.PageIndex > numel(app.ActiveTiffInfo)
                msg = sprintf('Invalid source: requested page %d, TIFF has %d page(s).', source.PageIndex, numel(app.ActiveTiffInfo));
                app.clearTiles(msg);
                app.updateStatus(msg);
                app.updateSelectedCellDetail();
                return
            end

            try
                locTbl = readtable(char(source.CsvPath), 'TextType', 'string', 'VariableNamingRule', 'preserve');
            catch ME
                msg = "Could not read localization CSV: " + string(ME.message);
                app.clearTiles(msg);
                app.updateStatus(msg);
                app.updateSelectedCellDetail();
                return
            end

            [locTbl, xyStatus] = app.ensureNumericXY(locTbl);
            if strlength(xyStatus) > 0
                app.clearTiles(xyStatus);
                app.updateStatus(xyStatus);
                app.updateSelectedCellDetail();
                return
            end

            app.ActiveLocalizationTable = locTbl;
            app.ActiveReviewTable = app.loadOrCreateReviewTable(locTbl, source);
            app.refreshActiveSourceProgress();
            app.updateDatasetTable();
            app.refreshSortAndFilterControls();
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.restoreLastBlock();
            app.showCurrentBlock();
            app.updateSelectedCellDetail();
            if ~isempty(app.TissueAxes) && isvalid(app.TissueAxes)
                imagePage = app.getImagePage(double(app.ActiveSource.PageIndex));
                if ~isempty(imagePage)
                    app.renderTissuePlot(imagePage);
                end
            end
            app.updateProgress();
        end

        function [tbl, status] = ensureNumericXY(app, tbl)
            arguments
                app
                tbl table
            end

            status = "";
            names = string(tbl.Properties.VariableNames);
            if ~all(ismember(["X", "Y"], names))
                status = "Localization CSV must contain X and Y columns.";
                return
            end

            for name = ["X", "Y"]
                value = tbl.(char(name));
                if isnumeric(value)
                    numericValue = double(value);
                elseif iscellstr(value) || isstring(value) || iscategorical(value)
                    numericValue = str2double(string(value));
                else
                    status = name + " column must be numeric or convertible to numeric.";
                    return
                end
                if any(isnan(numericValue))
                    status = name + " column contains nonnumeric or NaN values.";
                    return
                end
                tbl.(char(name)) = numericValue;
            end
        end

        function reviewTbl = loadOrCreateReviewTable(app, locTbl, source)
            arguments
                app
                locTbl table
                source struct
            end

            reviewTbl = locTbl;
            reviewTbl = app.removeExistingQCColumns(reviewTbl);
            n = height(reviewTbl);

            reviewTbl.QCLabel = strings(n, 1);
            reviewTbl.QCCode = NaN(n, 1);
            reviewTbl.QCReviewed = false(n, 1);
            reviewTbl.QCReviewer = strings(n, 1);
            reviewTbl.QCTimestamp = NaT(n, 1);
            reviewTbl.QCNotes = strings(n, 1);
            reviewTbl.QCCropWidth = repmat(double(app.Settings.CropWidth), n, 1);
            reviewTbl.QCCropHeight = repmat(double(app.Settings.CropHeight), n, 1);
            reviewTbl.QCDatasetID = repmat(string(source.DatasetID), n, 1);
            reviewTbl.QCChannel = repmat(string(source.ChannelName), n, 1);
            reviewTbl.QCSourceCsv = repmat(string(source.CsvPath), n, 1);
            reviewTbl.QCSourceRow = (1:n)';
            reviewTbl.QCImagePath = repmat(string(source.ImagePath), n, 1);
            reviewTbl.QCVersion = repmat(string(app.QCVersion), n, 1);
            reviewTbl.QCUniqueID = app.makeUniqueIDs(source, n);
            reviewTbl.QCOutOfBounds = false(n, 1);
            reviewTbl.QCIncludesImageBorder = false(n, 1);
            reviewTbl.QCWarning = strings(n, 1);

            reviewTbl = app.mergeExistingQC(reviewTbl, source);
            reviewTbl = app.markOutOfBounds(reviewTbl, source);
        end

        function tbl = removeExistingQCColumns(app, tbl)
            arguments
                app
                tbl table
            end

            qcColumns = app.qcColumnNames();
            names = string(tbl.Properties.VariableNames);
            removeMask = ismember(names, qcColumns);
            tbl(:, names(removeMask)) = [];
        end

        function ids = makeUniqueIDs(app, source, n)
            arguments
                app
                source struct
                n (1,1) double
            end

            sourceRel = app.makeRelativePath(source.CsvPath, app.ParentDirectory);
            ids = strings(n, 1);
            for k = 1:n
                ids(k) = string(source.DatasetID) + "|" + string(source.ChannelName) + "|" + sourceRel + "|" + string(k);
            end
        end

        function reviewTbl = markOutOfBounds(app, reviewTbl, source)
            arguments
                app
                reviewTbl table
                source struct
            end

            if isempty(app.ActiveTiffInfo) || source.PageIndex > numel(app.ActiveTiffInfo)
                return
            end

            imageWidth = double(app.ActiveTiffInfo(source.PageIndex).Width);
            imageHeight = double(app.ActiveTiffInfo(source.PageIndex).Height);
            x = double(reviewTbl.X);
            y = double(reviewTbl.Y);
            out = x < 1 | x > imageWidth | y < 1 | y > imageHeight;
            border = app.cropIncludesImageBorder(x, y, imageWidth, imageHeight);

            reviewTbl.QCOutOfBounds = out;
            if ~ismember("QCWarning", string(reviewTbl.Properties.VariableNames))
                reviewTbl.QCWarning = strings(height(reviewTbl), 1);
            else
                reviewTbl.QCWarning(:) = "";
            end
            if ~ismember("QCIncludesImageBorder", string(reviewTbl.Properties.VariableNames))
                reviewTbl.QCIncludesImageBorder = false(height(reviewTbl), 1);
            end
            reviewTbl.QCIncludesImageBorder = border;
            reviewTbl.QCWarning(out) = "X/Y outside target image bounds";
            reviewTbl.QCWarning(~out & border) = "Crop includes image border";
        end

        function border = cropIncludesImageBorder(app, x, y, imageWidth, imageHeight)
            arguments
                app
                x double
                y double
                imageWidth (1,1) double
                imageHeight (1,1) double
            end

            cropWidth = max(1, round(double(app.Settings.CropWidth)));
            cropHeight = max(1, round(double(app.Settings.CropHeight)));
            centerCol = round(x);
            centerRow = round(y);
            colStart = centerCol - floor(cropWidth / 2);
            rowStart = centerRow - floor(cropHeight / 2);
            colEnd = colStart + cropWidth - 1;
            rowEnd = rowStart + cropHeight - 1;
            border = colStart <= 1 | rowStart <= 1 | colEnd >= imageWidth | rowEnd >= imageHeight;
        end

        function updateActiveBorderFlags(app)
            if isempty(app.ActiveReviewTable) || isempty(app.ActiveSource) || ~isfield(app.ActiveSource, 'PageIndex')
                return
            end

            app.ActiveReviewTable = app.markOutOfBounds(app.ActiveReviewTable, app.ActiveSource);
        end

        function reviewTbl = mergeExistingQC(app, reviewTbl, source)
            arguments
                app
                reviewTbl table
                source struct
            end

            qcPath = app.qcPathForCsv(source.CsvPath);
            if ~isfile(qcPath)
                return
            end

            try
                oldTbl = readtable(char(qcPath), 'TextType', 'string', 'VariableNamingRule', 'preserve');
            catch ME
                app.updateStatus("Existing QC file could not be read: " + string(ME.message));
                return
            end

            oldNames = string(oldTbl.Properties.VariableNames);
            if ~ismember("QCSourceRow", oldNames)
                rowCount = min(height(reviewTbl), height(oldTbl));
                targetRows = (1:rowCount)';
                sourceRows = (1:rowCount)';
            else
                [matched, sourceRows] = ismember(reviewTbl.QCSourceRow, oldTbl.QCSourceRow);
                targetRows = find(matched);
                sourceRows = sourceRows(matched);
            end

            qcColumns = app.qcColumnNames();
            for k = 1:numel(qcColumns)
                col = qcColumns(k);
                if ismember(col, oldNames) && ismember(col, string(reviewTbl.Properties.VariableNames))
                    reviewTbl = app.copyQCColumn(reviewTbl, oldTbl, col, targetRows, sourceRows);
                end
            end
        end

        function reviewTbl = copyQCColumn(app, reviewTbl, oldTbl, col, targetRows, sourceRows)
            arguments
                app
                reviewTbl table
                oldTbl table
                col (1,1) string
                targetRows double
                sourceRows double
            end

            if isempty(targetRows)
                return
            end

            oldValue = oldTbl.(char(col));
            switch col
                case ["QCLabel", "QCReviewer", "QCNotes", "QCDatasetID", "QCChannel", "QCSourceCsv", "QCImagePath", "QCVersion", "QCUniqueID", "QCWarning"]
                    reviewTbl.(char(col))(targetRows) = string(oldValue(sourceRows));
                case ["QCReviewed", "QCOutOfBounds", "QCIncludesImageBorder"]
                    reviewTbl.(char(col))(targetRows) = app.toLogical(oldValue(sourceRows));
                case ["QCCode", "QCCropWidth", "QCCropHeight", "QCSourceRow"]
                    reviewTbl.(char(col))(targetRows) = double(oldValue(sourceRows));
                case "QCTimestamp"
                    reviewTbl.(char(col))(targetRows) = app.toDatetime(oldValue(sourceRows));
                otherwise
                    reviewTbl.(char(col))(targetRows) = oldValue(sourceRows);
            end
        end

        function refreshSortAndFilterControls(app)
            synthetic = ["Original row order", "Spatial: top-to-bottom, left-to-right", "Spatial: left-to-right, top-to-bottom", "Unreviewed first", "Reviewed first", "QC label"];
            vars = string(app.ActiveReviewTable.Properties.VariableNames);
            vars = vars(~startsWith(vars, "QC"));
            sortItems = [synthetic, vars];
            secondaryItems = ["None", sortItems];

            app.Sort1DropDown.Items = cellstr(sortItems);
            app.Sort2DropDown.Items = cellstr(secondaryItems);
            app.setDropDownValue(app.Sort1DropDown, app.Settings.SortColumn);
            app.setDropDownValue(app.Sort1DirectionDropDown, app.Settings.SortDirection);
            app.setDropDownValue(app.Sort2DropDown, app.Settings.SecondarySortColumn);
            app.setDropDownValue(app.Sort2DirectionDropDown, app.Settings.SecondarySortDirection);

            filterItems = ["Show all", "Show unreviewed only", "Show reviewed only"];
            for k = 1:numel(app.Categories)
                filterItems(end + 1) = string(app.Categories(k).Name) + " only"; %#ok<AGROW>
            end
            app.FilterDropDown.Items = cellstr(filterItems);
            app.setDropDownValue(app.FilterDropDown, app.Settings.FilterMode);
        end

        function buildDisplayOrder(app)
            if isempty(app.ActiveReviewTable)
                app.DisplayOrder = [];
                return
            end

            n = height(app.ActiveReviewTable);
            order = (1:n)';
            secondary = string(app.Sort2DropDown.Value);
            primary = string(app.Sort1DropDown.Value);
            secondaryDirection = string(app.Sort2DirectionDropDown.Value);
            primaryDirection = string(app.Sort1DirectionDropDown.Value);

            if secondary ~= "None"
                order = app.sortOrderBySpec(order, secondary, secondaryDirection);
            end
            if primary ~= "None"
                order = app.sortOrderBySpec(order, primary, primaryDirection);
            end
            app.DisplayOrder = order;
        end

        function order = sortOrderBySpec(app, order, spec, direction)
            arguments
                app
                order double
                spec (1,1) string
                direction (1,1) string
            end

            direction = app.matlabSortDirection(direction);
            switch spec
                case "Original row order"
                    keyTbl = table(app.ActiveReviewTable.QCSourceRow(order), 'VariableNames', {'A'});
                    order = app.applySortRows(order, keyTbl, {'A'}, direction);
                case "Spatial: top-to-bottom, left-to-right"
                    keyTbl = table(app.ActiveReviewTable.Y(order), app.ActiveReviewTable.X(order), 'VariableNames', {'A', 'B'});
                    order = app.applySortRows(order, keyTbl, {'A', 'B'}, direction);
                case "Spatial: left-to-right, top-to-bottom"
                    keyTbl = table(app.ActiveReviewTable.X(order), app.ActiveReviewTable.Y(order), 'VariableNames', {'A', 'B'});
                    order = app.applySortRows(order, keyTbl, {'A', 'B'}, direction);
                case "Unreviewed first"
                    keyTbl = table(app.ActiveReviewTable.QCReviewed(order), 'VariableNames', {'A'});
                    order = app.applySortRows(order, keyTbl, {'A'}, direction);
                case "Reviewed first"
                    keyTbl = table(~app.ActiveReviewTable.QCReviewed(order), 'VariableNames', {'A'});
                    order = app.applySortRows(order, keyTbl, {'A'}, direction);
                case "QC label"
                    keyTbl = table(string(app.ActiveReviewTable.QCLabel(order)), 'VariableNames', {'A'});
                    order = app.applySortRows(order, keyTbl, {'A'}, direction);
                otherwise
                    vars = string(app.ActiveReviewTable.Properties.VariableNames);
                    if ~ismember(spec, vars)
                        return
                    end
                    key = app.ActiveReviewTable.(char(spec));
                    keyTbl = table(app.normalizeSortKey(key(order)), 'VariableNames', {'A'});
                    order = app.applySortRows(order, keyTbl, {'A'}, direction);
            end
        end

        function order = applySortRows(app, order, keyTbl, vars, direction)
            arguments
                app
                order double
                keyTbl table
                vars cell
                direction char
            end

            try
                [~, idx] = sortrows(keyTbl, vars, direction, 'MissingPlacement', 'last');
            catch
                [~, idx] = sortrows(keyTbl, vars, direction);
            end
            order = order(idx);
        end

        function key = normalizeSortKey(app, key)
            arguments
                app
                key
            end

            if isnumeric(key) || islogical(key) || isdatetime(key) || isduration(key) || iscategorical(key) || isstring(key)
                return
            end
            if iscellstr(key)
                key = string(key);
                return
            end
            if iscell(key)
                key = string(key);
                return
            end
            key = string(key);
        end

        function direction = matlabSortDirection(app, directionLabel)
            arguments
                app
                directionLabel (1,1) string
            end

            if directionLabel == "Descending"
                direction = 'descend';
            else
                direction = 'ascend';
            end
        end

        function applyFilter(app, resetBlock)
            arguments
                app
                resetBlock (1,1) logical = true
            end

            if isempty(app.ActiveReviewTable) || isempty(app.DisplayOrder)
                app.FilteredOrder = [];
                return
            end

            filterMode = string(app.FilterDropDown.Value);
            rows = app.DisplayOrder;
            mask = true(numel(rows), 1);

            switch filterMode
                case "Show unreviewed only"
                    mask = ~app.ActiveReviewTable.QCReviewed(rows);
                case "Show reviewed only"
                    mask = app.ActiveReviewTable.QCReviewed(rows);
                otherwise
                    for k = 1:numel(app.Categories)
                        label = string(app.Categories(k).Name) + " only";
                        if filterMode == label
                            mask = string(app.ActiveReviewTable.QCLabel(rows)) == string(app.Categories(k).Name);
                            break
                        end
                    end
            end

            if app.Settings.IgnoreBorderObservations && ismember("QCIncludesImageBorder", string(app.ActiveReviewTable.Properties.VariableNames))
                mask = mask & ~app.ActiveReviewTable.QCIncludesImageBorder(rows);
            end

            app.FilteredOrder = rows(mask);
            if resetBlock
                app.BlockStartIndex = 1;
            else
                app.BlockStartIndex = app.clampBlockStart(app.BlockStartIndex);
            end
            app.SelectedVisibleIndex = 1;
            app.SelectedVisibleIndices = [];
            app.SelectedGlobalRow = NaN;
        end

        function blockStart = clampBlockStart(app, blockStart)
            arguments
                app
                blockStart (1,1) double
            end

            n = numel(app.FilteredOrder);
            if n == 0
                blockStart = 1;
                return
            end
            maxStart = floor((n - 1) / app.Settings.CellsPerBlock) * app.Settings.CellsPerBlock + 1;
            blockStart = max(1, min(blockStart, maxStart));
        end

        function restoreLastBlock(app)
            if app.Settings.LastActiveDataset ~= app.DatasetList.DatasetID(app.ActiveDatasetIndex)
                app.BlockStartIndex = 1;
                return
            end
            if app.Settings.LastActiveLocalizationSource ~= app.sourceIdentity(app.ActiveSource)
                app.BlockStartIndex = 1;
                return
            end
            blockIndex = max(1, double(app.Settings.LastBlockIndex));
            app.BlockStartIndex = (blockIndex - 1) * app.Settings.CellsPerBlock + 1;
            app.BlockStartIndex = app.clampBlockStart(app.BlockStartIndex);
        end

        function showCurrentBlock(app)
            app.SelectedGlobalRow = NaN;

            if isempty(app.ActiveReviewTable) || isempty(app.FilteredOrder)
                app.clearTiles("No detections match the current source/filter.");
                return
            end

            app.BlockStartIndex = app.clampBlockStart(app.BlockStartIndex);
            nTotal = numel(app.FilteredOrder);
            blockEnd = min(app.BlockStartIndex + app.Settings.CellsPerBlock - 1, nTotal);
            visibleRows = app.FilteredOrder(app.BlockStartIndex:blockEnd);
            nVisible = numel(visibleRows);

            panelAspect = app.currentMontagePanelAspect();
            tileAspect = max(1, double(app.Settings.CropWidth)) / max(1, double(app.Settings.CropHeight));
            nCols = ceil(sqrt(double(nVisible) * panelAspect / tileAspect));
            nCols = min(max(1, nCols), nVisible);
            nRows = ceil(double(nVisible) / nCols);
            if nRows < 1
                nRows = 1;
            end

            if isempty(app.SelectedVisibleIndices)
                app.SelectedVisibleIndex = min(max(1, app.SelectedVisibleIndex), nVisible);
                app.SelectedVisibleIndices = app.SelectedVisibleIndex;
            else
                app.SelectedVisibleIndices = app.SelectedVisibleIndices(app.SelectedVisibleIndices >= 1 & app.SelectedVisibleIndices <= nVisible);
                if isempty(app.SelectedVisibleIndices)
                    app.SelectedVisibleIndices = 1;
                end
                app.SelectedVisibleIndex = app.SelectedVisibleIndices(1);
            end
            app.SelectedGlobalRow = visibleRows(app.SelectedVisibleIndex);

            app.renderMontageBlock(visibleRows, nRows, nCols);

            blockIndex = ceil(app.BlockStartIndex / app.Settings.CellsPerBlock);
            numBlocks = max(1, ceil(nTotal / app.Settings.CellsPerBlock));
            app.TileSummaryLabel.Text = sprintf(['Block %d/%d, rows %d-%d of %d | click selects | ', ...
                'hold 1-9/g/b/u and click labels that tile | Shift/Ctrl+class labels all visible'], ...
                blockIndex, numBlocks, app.BlockStartIndex, blockEnd, nTotal);
            app.updateBlockNavigationControls(blockIndex, numBlocks);
            app.Settings.LastBlockIndex = blockIndex;
            app.saveSettings();
            app.updateSelectedCellDetail();
            app.updateTissuePlotSelection();
            app.updateProgress();
        end

        function clearTiles(app, message)
            arguments
                app
                message (1,1) string
            end

            app.MontageVisibleRows = [];
            app.MontageTileBounds = zeros(0, 4);
            app.MontageMarkerPositions = {};
            app.MontageImage = [];

            if ~isempty(app.MontageAxes) && isvalid(app.MontageAxes)
                cla(app.MontageAxes)
                text(app.MontageAxes, 0.5, 0.5, message, ...
                    'Units', 'normalized', ...
                    'HorizontalAlignment', 'center', ...
                    'FontWeight', 'bold', ...
                    'Interpreter', 'none', ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none');
                app.MontageAxes.XTick = [];
                app.MontageAxes.YTick = [];
            end
            app.TileSummaryLabel.Text = char(message);
            app.updateBlockNavigationControls(1, 1);
        end

        function renderMontageBlock(app, visibleRows, nRows, nCols)
            arguments
                app
                visibleRows double
                nRows (1,1) double {mustBeInteger, mustBePositive}
                nCols (1,1) double {mustBeInteger, mustBePositive}
            end

            nVisible = numel(visibleRows);
            app.MontageVisibleRows = visibleRows(:);
            app.MontageTileBounds = zeros(nVisible, 4);
            app.MontageMarkerPositions = cell(nVisible, 1);

            if nVisible == 0
                app.clearTiles("No detections match the current source/filter.");
                return
            end

            cropImages = cell(nVisible, 1);
            cropMarkers = cell(nVisible, 1);
            tileCropHeight = max(1, round(double(app.Settings.CropHeight)));
            tileCropWidth = max(1, round(double(app.Settings.CropWidth)));

            for k = 1:nVisible
                rowIdx = visibleRows(k);
                crop = app.composeCropDisplay(rowIdx);
                cropMarkers{k} = zeros(0, 2);
                if crop.IsValid
                    imageForTile = app.cropImageForMontage(crop);
                    cropImages{k} = imageForTile;
                    cropMarkers{k} = crop.Markers;
                    tileCropHeight = max(tileCropHeight, size(imageForTile, 1));
                    tileCropWidth = max(tileCropWidth, size(imageForTile, 2));
                else
                    cropImages{k} = [];
                end
            end

            gap = 6;
            tileHeight = tileCropHeight;
            tileWidth = tileCropWidth;
            montageHeight = nRows * tileHeight + (nRows - 1) * gap;
            montageWidth = nCols * tileWidth + (nCols - 1) * gap;
            montageImage = 0.08 * ones(montageHeight, montageWidth, 3);

            for k = 1:nVisible
                rowNumber = ceil(double(k) / double(nCols));
                colNumber = k - (rowNumber - 1) * nCols;
                x0 = (colNumber - 1) * (tileWidth + gap) + 1;
                y0 = (rowNumber - 1) * (tileHeight + gap) + 1;
                app.MontageTileBounds(k, :) = [x0, y0, tileWidth, tileHeight];

                montageImage(y0:(y0 + tileHeight - 1), x0:(x0 + tileWidth - 1), :) = 0.15;
                cropAreaRows = y0:(y0 + tileCropHeight - 1);
                cropAreaCols = x0:(x0 + tileCropWidth - 1);
                if isempty(cropImages{k})
                    montageImage(cropAreaRows, cropAreaCols, :) = 0.22;
                else
                    paddedImage = app.padMontageImage(cropImages{k}, [tileCropHeight, tileCropWidth]);
                    montageImage(cropAreaRows, cropAreaCols, :) = paddedImage;
                end

                if ~isempty(cropMarkers{k})
                    app.MontageMarkerPositions{k} = cropMarkers{k} + [x0 - 1, y0 - 1];
                else
                    app.MontageMarkerPositions{k} = zeros(0, 2);
                end
            end

            cla(app.MontageAxes)
            app.MontageImage = image(app.MontageAxes, montageImage);
            app.MontageImage.HitTest = 'on';
            app.MontageImage.PickableParts = 'all';
            app.MontageImage.ButtonDownFcn = @(src, event) app.onMontageClicked(src, event);
            app.MontageAxes.ButtonDownFcn = @(src, event) app.onMontageClicked(src, event);
            app.MontageAxes.HitTest = 'on';
            app.MontageAxes.PickableParts = 'all';
            app.MontageAxes.YDir = 'reverse';
            app.MontageAxes.XLim = [0.5, montageWidth + 0.5];
            app.MontageAxes.YLim = [0.5, montageHeight + 0.5];
            axis(app.MontageAxes, 'image')
            app.MontageAxes.XTick = [];
            app.MontageAxes.YTick = [];
            hold(app.MontageAxes, 'on')
            app.drawMontageAnnotations();
            hold(app.MontageAxes, 'off')
        end

        function panelAspect = currentMontagePanelAspect(app)
            arguments
                app
            end

            panelAspect = 1.6;
            if ~isempty(app.TileGrid) && isvalid(app.TileGrid)
                pos = app.TileGrid.Position;
                if numel(pos) >= 4 && all(isfinite(pos(3:4))) && pos(3) > 0 && pos(4) > 0
                    panelAspect = max(0.5, min(6.0, double(pos(3)) / double(pos(4))));
                end
            end
        end

        function fontColor = readableTextColor(app, backgroundColor)
            arguments
                app
                backgroundColor (1,3) double
            end

            backgroundColor = min(max(backgroundColor, 0), 1);
            luminance = 0.2126 * backgroundColor(1) + 0.7152 * backgroundColor(2) + 0.0722 * backgroundColor(3);
            if luminance < 0.55
                fontColor = [1 1 1];
            else
                fontColor = [0 0 0];
            end
        end

        function imageOut = cropImageForMontage(app, crop)
            arguments
                app
                crop struct
            end

            if isempty(crop.Image)
                imageOut = zeros(1, 1, 3);
                return
            end

            if ndims(crop.Image) == 3
                imageOut = double(crop.Image);
                finiteValues = imageOut(isfinite(imageOut));
                if isempty(finiteValues)
                    imageOut = zeros(size(imageOut));
                elseif min(finiteValues) < 0 || max(finiteValues) > 1
                    if isinteger(crop.Image)
                        imageOut = im2double(crop.Image);
                    else
                        imageOut = app.scaleToUnit(imageOut, []);
                    end
                end
                imageOut = min(max(imageOut, 0), 1);
                if size(imageOut, 3) == 1
                    imageOut = repmat(imageOut, 1, 1, 3);
                elseif size(imageOut, 3) > 3
                    imageOut = imageOut(:, :, 1:3);
                end
            else
                imageOut = app.scaleToUnit(crop.Image, crop.Range);
                imageOut = repmat(imageOut, 1, 1, 3);
            end
        end

        function out = padMontageImage(app, in, targetSize)
            arguments
                app
                in double
                targetSize (1,2) double {mustBeInteger, mustBePositive}
            end

            if ismatrix(in)
                in = repmat(in, 1, 1, 3);
            end
            out = zeros(targetSize(1), targetSize(2), 3);
            copyHeight = min(size(in, 1), targetSize(1));
            copyWidth = min(size(in, 2), targetSize(2));
            out(1:copyHeight, 1:copyWidth, :) = in(1:copyHeight, 1:copyWidth, 1:3);
        end

        function drawMontageAnnotations(app)
            if isempty(app.MontageVisibleRows) || isempty(app.MontageTileBounds)
                return
            end
            
            


            for k = 1:numel(app.MontageVisibleRows)
                rowIdx = app.MontageVisibleRows(k);
                bounds = app.MontageTileBounds(k, :);
                label = string(app.ActiveReviewTable.QCLabel(rowIdx));
                if strlength(label) == 0
                    label = "Unreviewed";
                end



                if ismember(k, app.SelectedVisibleIndices)
                    rectangle('Parent', app.MontageAxes, ...
                        'Position', [bounds(1), bounds(2), bounds(3), bounds(4)]+[-2 -2 4 4], ...
                        'EdgeColor', 'cyan', ...
                        'LineWidth', 7, ...
                        'HitTest', 'off', ...
                        'PickableParts', 'none');
                end
                
                edgeColor = app.categoryEdgeColor(label);
                lineWidth = 2;
                rectangle('Parent', app.MontageAxes, ...
                    'Position', [bounds(1) - 0.5, bounds(2) - 0.5, bounds(3), bounds(4)], ...
                    'EdgeColor', edgeColor, ...
                    'LineWidth', lineWidth, ...
                    'HitTest', 'off', ...
                    'PickableParts', 'none');


                if app.Settings.MarkerVisible && k <= numel(app.MontageMarkerPositions) && ~isempty(app.MontageMarkerPositions{k})
                    app.plotMarkers(app.MontageAxes, app.MontageMarkerPositions{k});
                end

                % Per-tile text is intentionally omitted for speed and readability.
                % QC state is encoded by the tile border color.
            end
        end

        function refreshMontageAnnotations(app)
            if isempty(app.MontageAxes) || ~isvalid(app.MontageAxes)
                return
            end
            children = app.MontageAxes.Children;
            for k = 1:numel(children)
                if isempty(app.MontageImage) || ~isvalid(app.MontageImage) || children(k) ~= app.MontageImage
                    delete(children(k));
                end
            end
            hold(app.MontageAxes, 'on')
            app.drawMontageAnnotations();
            hold(app.MontageAxes, 'off')
        end

        function color = categoryEdgeColor(app, label)
            arguments
                app
                label (1,1) string
            end

            color = [0.70 0.70 0.70];
            if label == "Unreviewed"
                return
            end
            for k = 1:numel(app.Categories)
                if label == string(app.Categories(k).Name) && isfield(app.Categories(k), 'Color')
                    baseColor = app.Categories(k).Color;
                    if isnumeric(baseColor) && numel(baseColor) == 3
                        color = double(baseColor(:))';
                    end
                    return
                end
            end
        end

        function onMontageClicked(app, src, event)
            arguments
                app
                src = []
                event = []
            end

            if isempty(app.MontageTileBounds) || isempty(app.MontageVisibleRows)
                return
            end

            point = app.MontageAxes.CurrentPoint;
            tileIndex = app.tileIndexFromMontagePoint(point(1, 1), point(1, 2));
            if isempty(tileIndex)
                return
            end

            categoryIndex = app.activeHeldClassIndex();
            modifiers = app.eventModifiers(event);

            if ~isempty(categoryIndex)
                nVisible = app.currentVisibleTileCount();
                if tileIndex > nVisible
                    return
                end
                app.SelectedVisibleIndex = tileIndex;
                app.SelectedVisibleIndices = tileIndex;
                app.SelectedGlobalRow = app.FilteredOrder(app.BlockStartIndex + tileIndex - 1);
                app.HeldClassUsedForClick = true;
                app.classifySelectedCellByIndex(categoryIndex);
                return
            end

            if any(modifiers == "shift")
                app.toggleVisibleTileSelection(tileIndex);
            else
                app.setSelectedVisibleTile(tileIndex);
            end
        end

        function tileIndex = tileIndexFromMontagePoint(app, x, y)
            arguments
                app
                x (1,1) double
                y (1,1) double
            end

            tileIndex = [];
            bounds = app.MontageTileBounds;
            for k = 1:size(bounds, 1)
                xMin = bounds(k, 1) - 0.5;
                yMin = bounds(k, 2) - 0.5;
                xMax = bounds(k, 1) + bounds(k, 3) - 0.5;
                yMax = bounds(k, 2) + bounds(k, 4) - 0.5;
                if x >= xMin && x <= xMax && y >= yMin && y <= yMax
                    tileIndex = k;
                    return
                end
            end
        end

        function nVisible = currentVisibleTileCount(app)
            if isempty(app.FilteredOrder)
                nVisible = 0;
                return
            end
            nVisible = min(app.Settings.CellsPerBlock, numel(app.FilteredOrder) - app.BlockStartIndex + 1);
            nVisible = max(0, nVisible);
        end

        function setSelectedVisibleTile(app, tileIndex)
            arguments
                app
                tileIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            nVisible = app.currentVisibleTileCount();
            if tileIndex > nVisible
                return
            end
            app.SelectedVisibleIndex = tileIndex;
            app.SelectedVisibleIndices = tileIndex;
            app.SelectedGlobalRow = app.FilteredOrder(app.BlockStartIndex + tileIndex - 1);
            app.refreshMontageAnnotations();
            app.updateSelectedCellDetail();
            app.updateTissuePlotSelection();
            app.updateProgress();
        end

        function toggleVisibleTileSelection(app, tileIndex)
            arguments
                app
                tileIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            nVisible = app.currentVisibleTileCount();
            if tileIndex > nVisible
                return
            end
            if ismember(tileIndex, app.SelectedVisibleIndices)
                app.SelectedVisibleIndices(app.SelectedVisibleIndices == tileIndex) = [];
            else
                app.SelectedVisibleIndices(end + 1) = tileIndex;
            end
            if isempty(app.SelectedVisibleIndices)
                app.SelectedVisibleIndices = tileIndex;
            end
            app.SelectedVisibleIndices = unique(app.SelectedVisibleIndices, 'stable');
            app.SelectedVisibleIndex = app.SelectedVisibleIndices(1);
            app.SelectedGlobalRow = app.FilteredOrder(app.BlockStartIndex + app.SelectedVisibleIndex - 1);
            app.refreshMontageAnnotations();
            app.updateSelectedCellDetail();
            app.updateTissuePlotSelection();
            app.updateProgress();
        end

        function modifiers = eventModifiers(app, event)
            arguments
                app
                event = []
            end

            modifiers = strings(0, 1);
            if isempty(event)
                return
            end
            if isprop(event, 'Modifier')
                modifiers = lower(string(event.Modifier));
            end
        end

        function categoryIndex = activeHeldClassIndex(app)
            categoryIndex = [];
            if ~isnan(app.HeldClassIndex) && app.HeldClassIndex >= 1 && app.HeldClassIndex <= numel(app.Categories)
                categoryIndex = app.HeldClassIndex;
            end
        end

        function color = tileBackgroundColor(app, tileIndex, rowIdx)
            arguments
                app
                tileIndex (1,1) double
                rowIdx (1,1) double
            end

            if ismember(tileIndex, app.SelectedVisibleIndices)
                color = [0.82 0.90 1.00];
                return
            end

            label = string(app.ActiveReviewTable.QCLabel(rowIdx));
            color = [0.96 0.96 0.96];
            for k = 1:numel(app.Categories)
                if label == string(app.Categories(k).Name) && isfield(app.Categories(k), 'Color')
                    baseColor = app.Categories(k).Color;
                    if isnumeric(baseColor) && numel(baseColor) == 3
                        color = 0.70 * [1 1 1] + 0.30 * double(baseColor(:))';
                    end
                    return
                end
            end
        end

        function textOut = tileMetadataText(app, rowIdx)
            arguments
                app
                rowIdx (1,1) double
            end

            x = app.ActiveReviewTable.X(rowIdx);
            y = app.ActiveReviewTable.Y(rowIdx);
            sourceRow = app.ActiveReviewTable.QCSourceRow(rowIdx);
            parts = ["row " + string(sourceRow), string(app.ActiveSource.ChannelName), "X=" + string(round(x, 2)), "Y=" + string(round(y, 2))];
            names = string(app.ActiveReviewTable.Properties.VariableNames);
            for varName = ["score", "rescore"]
                if ismember(varName, names)
                    parts(end + 1) = varName + "=" + app.scalarToString(app.ActiveReviewTable.(char(varName))(rowIdx)); %#ok<AGROW>
                end
            end
            sortName = string(app.Sort1DropDown.Value);
            if ismember(sortName, names) && ~ismember(sortName, ["X", "Y", "score", "rescore"])
                parts(end + 1) = sortName + "=" + app.scalarToString(app.ActiveReviewTable.(char(sortName))(rowIdx)); %#ok<AGROW>
            end
            textOut = strjoin(parts, " | ");
        end

        function textOut = tileQCText(app, rowIdx)
            arguments
                app
                rowIdx (1,1) double
            end

            label = app.safeText(app.ActiveReviewTable.QCLabel(rowIdx), "Unreviewed");
            textOut = label;
            if app.ActiveReviewTable.QCOutOfBounds(rowIdx)
                textOut = textOut + " | out-of-bounds";
            end
        end

        function crop = composeCropDisplay(app, rowIdx)
            arguments
                app
                rowIdx (1,1) double
            end

            crop = struct('Image', [], 'Range', [], 'Markers', zeros(0, 2), 'IsValid', false, 'Message', "");
            mode = string(app.Settings.DisplayMode);
            targetPage = double(app.ActiveSource.PageIndex);
            companionPage = app.companionPageIndex(targetPage);

            switch mode
                case "Companion channel only"
                    pageToShow = companionPage;
                    if isnan(pageToShow)
                        pageToShow = targetPage;
                    end
                    crop = app.extractCrop(rowIdx, pageToShow);
                case "Side-by-side channel view"
                    cropA = app.extractCrop(rowIdx, targetPage);
                    cropB = app.extractCrop(rowIdx, companionPage);
                    if ~cropA.IsValid || ~cropB.IsValid
                        crop = cropA;
                        return
                    end
                    imgA = app.scaleToUnit(cropA.Image, cropA.Range);
                    imgB = app.scaleToUnit(cropB.Image, cropB.Range);
                    [imgA, imgB] = app.padToSameHeight(imgA, imgB);
                    gap = ones(size(imgA, 1), 4);
                    crop.Image = [imgA, gap, imgB];
                    crop.Range = [];
                    crop.Markers = [cropA.Markers; cropB.Markers + [size(imgA, 2) + 4, 0]];
                    crop.IsValid = true;
                case "False-color overlay"
                    cropA = app.extractCrop(rowIdx, targetPage);
                    cropB = app.extractCrop(rowIdx, companionPage);
                    if ~cropA.IsValid || ~cropB.IsValid
                        crop = cropA;
                        return
                    end
                    imgA = app.scaleToUnit(cropA.Image, cropA.Range);
                    imgB = app.scaleToUnit(cropB.Image, cropB.Range);
                    [imgA, imgB] = app.padToSameSize(imgA, imgB);
                    rgb = zeros(size(imgA, 1), size(imgA, 2), 3);
                    rgb(:, :, 1) = imgB;
                    rgb(:, :, 2) = imgA;
                    crop.Image = rgb;
                    crop.Range = [];
                    crop.Markers = cropA.Markers;
                    crop.IsValid = true;
                otherwise
                    crop = app.extractCrop(rowIdx, targetPage);
            end
        end

        function pageIndex = companionPageIndex(app, targetPage)
            arguments
                app
                targetPage (1,1) double
            end

            pageIndex = NaN;
            if app.ActiveDatasetIndex < 1 || app.ActiveDatasetIndex > numel(app.SourceListByDataset)
                return
            end
            sources = app.SourceListByDataset{app.ActiveDatasetIndex};
            for k = 1:numel(sources)
                if sources(k).PageIndex ~= targetPage && sources(k).PageIndex <= numel(app.ActiveTiffInfo)
                    pageIndex = sources(k).PageIndex;
                    return
                end
            end

            map = app.Settings.ChannelMap;
            for k = 1:numel(map)
                candidate = double(map(k).PageIndex);
                if candidate ~= targetPage && candidate <= numel(app.ActiveTiffInfo)
                    pageIndex = candidate;
                    return
                end
            end
        end

        function crop = extractCrop(app, rowIdx, pageIndex)
            arguments
                app
                rowIdx (1,1) double
                pageIndex (1,1) double
            end

            crop = struct('Image', [], 'Range', [], 'Markers', zeros(0, 2), 'IsValid', false, 'Message', "No crop");
            if isnan(pageIndex) || pageIndex < 1 || isempty(app.ActiveTiffInfo) || pageIndex > numel(app.ActiveTiffInfo)
                crop.Message = "Image page unavailable";
                return
            end

            imagePage = app.getImagePage(pageIndex);
            if isempty(imagePage)
                crop.Message = "Image page could not be loaded";
                return
            end

            x = double(app.ActiveReviewTable.X(rowIdx));
            y = double(app.ActiveReviewTable.Y(rowIdx));
            width = double(app.Settings.CropWidth);
            height = double(app.Settings.CropHeight);
            [cropImage, marker, isValid, message] = app.extractCropFromImage(imagePage, x, y, width, height);

            crop.Image = cropImage;
            crop.Range = app.displayRangeForCrop(cropImage, pageIndex);
            crop.Markers = marker;
            crop.IsValid = isValid;
            crop.Message = message;
        end

        function imagePage = getImagePage(app, pageIndex)
            arguments
                app
                pageIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            imagePage = [];
            if app.ActiveDatasetIndex < 1 || app.ActiveDatasetIndex > height(app.DatasetList)
                return
            end
            if pageIndex > numel(app.ActiveTiffInfo)
                return
            end

            field = sprintf('p%d', pageIndex);
            if ~isfield(app.ActiveImagePages, field)
                imagePath = app.DatasetList.ImagePath(app.ActiveDatasetIndex);
                preprocessedPath = app.preprocessedPathForImage(imagePath);
                if isfile(preprocessedPath)
                    loadPath = preprocessedPath;
                    loadPage = pageIndex;
                    try
                        prepInfo = imfinfo(char(preprocessedPath));
                        if pageIndex > numel(prepInfo)
                            loadPage = 1;
                        end
                    catch
                    end
                else
                    loadPath = imagePath;
                    loadPage = pageIndex;
                end
                try
                    app.ActiveImagePages.(field) = imread(char(loadPath), loadPage);
                catch ME
                    app.updateStatus("imread failed: " + string(ME.message));
                    return
                end
            end
            imagePage = app.ActiveImagePages.(field);
        end

        function preprocessedPath = preprocessedPathForImage(app, imagePath)
            arguments
                app
                imagePath (1,1) string
            end

            [folder, stem, ~] = fileparts(char(imagePath));
            preprocessedPath = string(fullfile(folder, [stem '_preprocessed.tif']));
        end

        function [cropImage, marker, isValid, message] = extractCropFromImage(app, imagePage, x, y, width, height)
            arguments
                app
                imagePage
                x (1,1) double
                y (1,1) double
                width (1,1) double
                height (1,1) double
            end

            message = "";
            isValid = false;
            marker = zeros(0, 2);
            cropImage = [];

            if ~isfinite(x) || ~isfinite(y)
                message = "Invalid X/Y";
                return
            end

            nRows = size(imagePage, 1);
            nCols = size(imagePage, 2);
            centerCol = round(x);
            centerRow = round(y);
            width = max(1, round(width));
            height = max(1, round(height));

            colStart = centerCol - floor(width / 2);
            rowStart = centerRow - floor(height / 2);
            colEnd = colStart + width - 1;
            rowEnd = rowStart + height - 1;

            clippedColStart = max(1, colStart);
            clippedRowStart = max(1, rowStart);
            clippedColEnd = min(nCols, colEnd);
            clippedRowEnd = min(nRows, rowEnd);

            if clippedColStart > clippedColEnd || clippedRowStart > clippedRowEnd
                message = "Crop outside image";
                return
            end

            cropImage = imagePage(clippedRowStart:clippedRowEnd, clippedColStart:clippedColEnd, :);
            markerX = x - clippedColStart + 1;
            markerY = y - clippedRowStart + 1;
            marker = [markerX, markerY];
            isValid = true;
        end

        function range = displayRangeForCrop(app, cropImage, pageIndex)
            arguments
                app
                cropImage
                pageIndex (1,1) double
            end

            range = [];
            if isempty(cropImage) || ndims(cropImage) == 3
                return
            end
            mode = string(app.Settings.ContrastMode);
            switch mode
                case "Auto per channel / dataset"
                    range = app.getPageContrastRange(pageIndex);
                case "Manual min-max"
                    limits = double(app.Settings.ManualContrastLimits);
                    if numel(limits) == 2 && all(isfinite(limits)) && limits(2) > limits(1)
                        range = limits;
                    end
                case "Percentile stretch"
                    range = app.percentileRange(cropImage, [1 99]);
                otherwise
                    range = [];
            end
        end

        function range = getPageContrastRange(app, pageIndex)
            arguments
                app
                pageIndex (1,1) double
            end

            field = sprintf('p%d', pageIndex);
            if isfield(app.ActiveContrastLimits, field)
                range = app.ActiveContrastLimits.(field);
                return
            end
            imagePage = app.getImagePage(pageIndex);
            range = app.percentileRange(imagePage, [1 99]);
            app.ActiveContrastLimits.(field) = range;
        end

        function range = percentileRange(app, imageData, percentiles)
            arguments
                app
                imageData
                percentiles (1,2) double
            end

            values = double(imageData(:));
            values = values(isfinite(values));
            if isempty(values)
                range = [];
                return
            end
            maxSamples = 2000000;
            if numel(values) > maxSamples
                sampleIndex = round(linspace(1, numel(values), maxSamples));
                values = values(sampleIndex);
            end
            range = prctile(values, percentiles);
            if ~all(isfinite(range)) || range(2) <= range(1)
                range = double([min(values), max(values)]);
            end
            if range(2) <= range(1)
                range = [];
            end
        end

        function imageOut = scaleToUnit(app, imageIn, range)
            arguments
                app
                imageIn
                range double = []
            end

            imageOut = double(imageIn);
            if isempty(range)
                finiteValues = imageOut(isfinite(imageOut));
                if isempty(finiteValues)
                    imageOut = zeros(size(imageOut));
                    return
                end
                range = [min(finiteValues), max(finiteValues)];
            end
            if numel(range) ~= 2 || range(2) <= range(1)
                imageOut = zeros(size(imageOut));
                return
            end
            imageOut = (imageOut - range(1)) ./ (range(2) - range(1));
            imageOut = min(max(imageOut, 0), 1);
        end

        function [a, b] = padToSameHeight(app, a, b)
            arguments
                app
                a double
                b double
            end

            targetHeight = max(size(a, 1), size(b, 1));
            a = app.padArrayToSize(a, [targetHeight, size(a, 2)]);
            b = app.padArrayToSize(b, [targetHeight, size(b, 2)]);
        end

        function [a, b] = padToSameSize(app, a, b)
            arguments
                app
                a double
                b double
            end

            targetHeight = max(size(a, 1), size(b, 1));
            targetWidth = max(size(a, 2), size(b, 2));
            a = app.padArrayToSize(a, [targetHeight, targetWidth]);
            b = app.padArrayToSize(b, [targetHeight, targetWidth]);
        end

        function out = padArrayToSize(app, in, targetSize)
            arguments
                app
                in double
                targetSize (1,2) double
            end

            out = zeros(targetSize(1), targetSize(2));
            out(1:size(in, 1), 1:size(in, 2)) = in;
        end

        function plotMarkers(app, ax, markers)
            arguments
                app
                ax
                markers double
            end

            if isempty(markers)
                return
            end
            markerSize = max(3, double(app.Settings.MarkerSize));
            switch string(app.Settings.MarkerStyle)
                case "circle"
                    hMarker = plot(ax, markers(:, 1), markers(:, 2), 'ro', 'MarkerSize', markerSize, 'LineWidth', 1.2);
                otherwise
                    hMarker = plot(ax, markers(:, 1), markers(:, 2), 'r+', 'MarkerSize', markerSize, 'LineWidth', 1.2);
            end
            hMarker.HitTest = 'off';
            hMarker.PickableParts = 'none';
        end

        function selectVisibleTile(app, tileIndex)
            arguments
                app
                tileIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            app.setSelectedVisibleTile(tileIndex);
        end

        function armCoordinateUpdate(app)
            if isempty(app.ActiveReviewTable) || isnan(app.SelectedGlobalRow)
                uialert(app.UIFigure, 'Select a detection before updating its coordinate.', 'No detection selected');
                return
            end

            app.RecenterMode = true;
            app.updateStatus("Click the selected-detection crop at the new cell center. The coordinate will be confirmed before it is changed.");
        end

        function onSelectedDetectionImageClicked(app, ax)
            arguments
                app
                ax
            end

            if app.RecenterMode
                app.updateSelectedCoordinateFromClick(ax);
            else
                app.showSelectedCropFigure();
            end
        end

        function updateSelectedCoordinateFromClick(app, ax)
            arguments
                app
                ax
            end

            if isempty(app.ActiveReviewTable) || isnan(app.SelectedGlobalRow)
                app.RecenterMode = false;
                return
            end

            rowIdx = app.SelectedGlobalRow;
            point = ax.CurrentPoint;
            displayX = point(1, 1);
            displayY = point(1, 2);
            [newX, newY, isValid, message] = app.originalCoordinateFromCropClick(rowIdx, displayX, displayY);
            if ~isValid
                app.updateStatus(message);
                return
            end

            oldX = double(app.ActiveReviewTable.X(rowIdx));
            oldY = double(app.ActiveReviewTable.Y(rowIdx));
            prompt = sprintf(['Replace coordinate for source row %d?\n\n' ...
                'Old: X %.2f, Y %.2f\n' ...
                'New: X %.2f, Y %.2f'], ...
                app.ActiveReviewTable.QCSourceRow(rowIdx), oldX, oldY, newX, newY);
            selection = uiconfirm(app.UIFigure, prompt, 'Confirm coordinate update', ...
                'Options', {'Update', 'Cancel'}, ...
                'DefaultOption', 'Update', ...
                'CancelOption', 'Cancel');
            if string(selection) ~= "Update"
                app.RecenterMode = false;
                app.updateStatus("Coordinate update canceled.");
                return
            end

            app.pushUndo(rowIdx);
            app.ActiveReviewTable.X(rowIdx) = newX;
            app.ActiveReviewTable.Y(rowIdx) = newY;
            sourceRow = app.ActiveReviewTable.QCSourceRow(rowIdx);
            if sourceRow >= 1 && sourceRow <= height(app.ActiveLocalizationTable)
                names = string(app.ActiveLocalizationTable.Properties.VariableNames);
                if ismember("X", names)
                    app.ActiveLocalizationTable.X(sourceRow) = newX;
                end
                if ismember("Y", names)
                    app.ActiveLocalizationTable.Y(sourceRow) = newY;
                end
            end

            app.ActiveReviewTable.QCCropWidth(rowIdx) = double(app.Settings.CropWidth);
            app.ActiveReviewTable.QCCropHeight(rowIdx) = double(app.Settings.CropHeight);
            app.Dirty = true;
            app.RecenterMode = false;
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.selectGlobalRow(rowIdx);
            app.refreshActiveSourceProgress();
            app.updateDatasetTable();
            app.refreshTissuePlotAfterCoordinateUpdate();
            app.updateProgress();
            app.updateStatus(sprintf('Updated source row %d coordinate to X %.2f, Y %.2f.', sourceRow, newX, newY));
        end

        function [newX, newY, isValid, message] = originalCoordinateFromCropClick(app, rowIdx, displayX, displayY)
            arguments
                app
                rowIdx (1,1) double
                displayX (1,1) double
                displayY (1,1) double
            end

            newX = NaN;
            newY = NaN;
            isValid = false;
            message = "Click was outside the selected detection crop.";

            targetPage = double(app.ActiveSource.PageIndex);
            [colStart, rowStart, cropWidth, cropHeight, geometryValid] = app.cropGeometryForRow(rowIdx, targetPage);
            if ~geometryValid
                message = "Selected detection crop is unavailable.";
                return
            end

            localX = displayX;
            localY = displayY;
            mode = string(app.Settings.DisplayMode);
            if mode == "Side-by-side channel view"
                gap = 4;
                if displayX >= 1 && displayX <= cropWidth
                    localX = displayX;
                elseif displayX > cropWidth + gap && displayX <= cropWidth + gap + cropWidth
                    localX = displayX - cropWidth - gap;
                else
                    message = "Click the target or companion crop, not the side-by-side gap.";
                    return
                end
            end

            if localX < 0.5 || localX > cropWidth + 0.5 || localY < 0.5 || localY > cropHeight + 0.5
                return
            end

            newX = colStart + localX - 1;
            newY = rowStart + localY - 1;
            imageWidth = double(app.ActiveTiffInfo(targetPage).Width);
            imageHeight = double(app.ActiveTiffInfo(targetPage).Height);
            newX = min(max(newX, 1), imageWidth);
            newY = min(max(newY, 1), imageHeight);
            isValid = true;
            message = "";
        end

        function [colStart, rowStart, cropWidth, cropHeight, isValid] = cropGeometryForRow(app, rowIdx, pageIndex)
            arguments
                app
                rowIdx (1,1) double
                pageIndex (1,1) double
            end

            colStart = NaN;
            rowStart = NaN;
            cropWidth = NaN;
            cropHeight = NaN;
            isValid = false;
            if isnan(pageIndex) || pageIndex < 1 || isempty(app.ActiveTiffInfo) || pageIndex > numel(app.ActiveTiffInfo)
                return
            end

            x = double(app.ActiveReviewTable.X(rowIdx));
            y = double(app.ActiveReviewTable.Y(rowIdx));
            if ~isfinite(x) || ~isfinite(y)
                return
            end

            imageWidth = double(app.ActiveTiffInfo(pageIndex).Width);
            imageHeight = double(app.ActiveTiffInfo(pageIndex).Height);
            width = max(1, round(double(app.Settings.CropWidth)));
            height = max(1, round(double(app.Settings.CropHeight)));
            centerCol = round(x);
            centerRow = round(y);
            requestedColStart = centerCol - floor(width / 2);
            requestedRowStart = centerRow - floor(height / 2);
            requestedColEnd = requestedColStart + width - 1;
            requestedRowEnd = requestedRowStart + height - 1;

            colStart = max(1, requestedColStart);
            rowStart = max(1, requestedRowStart);
            colEnd = min(imageWidth, requestedColEnd);
            rowEnd = min(imageHeight, requestedRowEnd);
            if colStart > colEnd || rowStart > rowEnd
                return
            end

            cropWidth = colEnd - colStart + 1;
            cropHeight = rowEnd - rowStart + 1;
            isValid = true;
        end

        function refreshTissuePlotAfterCoordinateUpdate(app)
            if isempty(app.TissueAxes) || ~isvalid(app.TissueAxes)
                return
            end
            if ~isempty(app.TissueClassPointHandle) && isvalid(app.TissueClassPointHandle)
                x = double(app.ActiveReviewTable.X(app.TissueClassPointRows));
                y = double(app.ActiveReviewTable.Y(app.TissueClassPointRows));
                app.TissueClassPointHandle.XData = x;
                app.TissueClassPointHandle.YData = y;
            end
            app.updateTissuePlotSelection();
        end

        function syncActiveLocalizationCoordinates(app, rows)
            arguments
                app
                rows double
            end

            if isempty(app.ActiveLocalizationTable) || isempty(rows)
                return
            end
            names = string(app.ActiveLocalizationTable.Properties.VariableNames);
            hasX = ismember("X", names);
            hasY = ismember("Y", names);
            if ~hasX && ~hasY
                return
            end

            rows = rows(:);
            rows = rows(rows >= 1 & rows <= height(app.ActiveReviewTable));
            for k = 1:numel(rows)
                sourceRow = app.ActiveReviewTable.QCSourceRow(rows(k));
                if sourceRow < 1 || sourceRow > height(app.ActiveLocalizationTable)
                    continue
                end
                if hasX
                    app.ActiveLocalizationTable.X(sourceRow) = app.ActiveReviewTable.X(rows(k));
                end
                if hasY
                    app.ActiveLocalizationTable.Y(sourceRow) = app.ActiveReviewTable.Y(rows(k));
                end
            end
        end

        function updateSelectedCellDetail(app)
            if isempty(app.ActiveReviewTable) || isnan(app.SelectedGlobalRow) || app.SelectedGlobalRow < 1 || app.SelectedGlobalRow > height(app.ActiveReviewTable)
                cla(app.DetailAxes)
                app.DetailLabel.Text = "No detection selected";
                app.NotesEdit.Value = '';
                app.MetadataTable.Data = table(string.empty(0,1), string.empty(0,1), 'VariableNames', {'Field', 'Value'});
                return
            end

            rowIdx = app.SelectedGlobalRow;
            crop = app.composeCropDisplay(rowIdx);
            cla(app.DetailAxes)
            if crop.IsValid
                if ndims(crop.Image) == 3
                    hImage = imshow(crop.Image, 'Parent', app.DetailAxes);
                elseif isempty(crop.Range)
                    hImage = imshow(crop.Image, [], 'Parent', app.DetailAxes);
                else
                    hImage = imshow(crop.Image, crop.Range, 'Parent', app.DetailAxes);
                end
                hImage.HitTest = 'on';
                hImage.PickableParts = 'all';
                hImage.ButtonDownFcn = @(src, event) app.onSelectedDetectionImageClicked(app.DetailAxes);
                app.DetailAxes.ButtonDownFcn = @(src, event) app.onSelectedDetectionImageClicked(app.DetailAxes);
                app.DetailAxes.HitTest = 'on';
                app.DetailAxes.PickableParts = 'all';
                hold(app.DetailAxes, 'on')
                if app.Settings.MarkerVisible && ~isempty(crop.Markers)
                    app.plotMarkers(app.DetailAxes, crop.Markers);
                end
                hold(app.DetailAxes, 'off')
                axis(app.DetailAxes, 'image')
            else
                text(app.DetailAxes, 0.5, 0.5, crop.Message, 'Units', 'normalized', 'HorizontalAlignment', 'center');
            end
            app.DetailAxes.XTick = [];
            app.DetailAxes.YTick = [];

            label = app.safeText(app.ActiveReviewTable.QCLabel(rowIdx), "Unreviewed");
            channelName = app.safeText(app.ActiveSource.ChannelName, "");
            app.DetailLabel.Text = sprintf('Source row %d | %s | X %.2f Y %.2f | %s', ...
                app.ActiveReviewTable.QCSourceRow(rowIdx), char(channelName), app.ActiveReviewTable.X(rowIdx), app.ActiveReviewTable.Y(rowIdx), char(label));
            app.NotesEdit.Value = char(app.safeText(app.ActiveReviewTable.QCNotes(rowIdx), ""));
            app.MetadataTable.Data = app.metadataTableForRow(rowIdx);
        end

        function metaTbl = metadataTableForRow(app, rowIdx)
            arguments
                app
                rowIdx (1,1) double
            end

            vars = string(app.ActiveLocalizationTable.Properties.VariableNames)';
            values = strings(numel(vars), 1);
            for k = 1:numel(vars)
                value = app.ActiveLocalizationTable.(char(vars(k)))(rowIdx);
                values(k) = app.scalarToString(value);
            end
            qcVars = ["QCLabel", "QCCode", "QCReviewed", "QCTimestamp", "QCOutOfBounds", "QCIncludesImageBorder", "QCWarning"]';
            qcValues = strings(numel(qcVars), 1);
            for k = 1:numel(qcVars)
                qcValues(k) = app.scalarToString(app.ActiveReviewTable.(char(qcVars(k)))(rowIdx));
            end
            metaTbl = table([vars; qcVars], [values; qcValues], 'VariableNames', {'Field', 'Value'});
        end

        function out = scalarToString(app, value)
            arguments
                app
                value
            end

            if istable(value)
                value = value{1, 1};
            end
            if iscell(value)
                value = value{1};
            end
            if isstring(value)
                if isempty(value) || ismissing(value(1))
                    out = "";
                else
                    out = string(value(1));
                end
            elseif ischar(value)
                out = string(value);
            elseif isnumeric(value) || islogical(value)
                if isempty(value)
                    out = "";
                elseif isscalar(value)
                    out = string(value);
                else
                    out = "[" + strjoin(string(value(:)'), ",") + "]";
                end
            elseif isdatetime(value)
                if ismissing(value)
                    out = "";
                else
                    out = string(value(1));
                end
            elseif iscategorical(value)
                if isempty(value) || ismissing(value(1))
                    out = "";
                else
                    out = string(value(1));
                end
            else
                out = string(value);
                if isempty(out) || ismissing(out(1))
                    out = "";
                else
                    out = out(1);
                end
            end
        end

        function state = onOff(app, tf)
            arguments
                app
                tf (1,1) logical
            end

            if tf
                state = 'on';
            else
                state = 'off';
            end
        end

        function out = safeText(app, value, defaultText)
            arguments
                app
                value
                defaultText string = ""
            end

            out = app.scalarToString(value);
            if isempty(out) || ismissing(out(1)) || strlength(out(1)) == 0
                out = defaultText;
            else
                out = out(1);
            end
        end

        function classifySelectedCellByIndex(app, categoryIndex)
            arguments
                app
                categoryIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            if categoryIndex > numel(app.Categories)
                return
            end
            if numel(app.SelectedVisibleIndices) > 1
                app.classifyVisibleCells(categoryIndex);
            else
                app.classifySelectedCell(categoryIndex);
            end
        end

        function classifySelectedCell(app, categoryIndex)
            arguments
                app
                categoryIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            if isempty(app.ActiveReviewTable) || isnan(app.SelectedGlobalRow)
                return
            end
            oldPosition = app.BlockStartIndex + app.SelectedVisibleIndex - 1;
            app.classifyRows(app.SelectedGlobalRow, categoryIndex);
            app.buildDisplayOrder();
            app.applyFilter(false);
            if app.Settings.AutoAdvanceAfterClassification
                app.selectNextUnreviewedFromPosition(oldPosition);
            else
                app.selectRowIfVisible(app.SelectedGlobalRow, oldPosition);
            end
            app.updateProgress();
        end

        function classifyVisibleCells(app, categoryIndex)
            arguments
                app
                categoryIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            if isempty(app.ActiveReviewTable) || isempty(app.FilteredOrder) || isempty(app.SelectedVisibleIndices)
                return
            end

            visiblePositions = app.BlockStartIndex + app.SelectedVisibleIndices - 1;
            visiblePositions = visiblePositions(visiblePositions >= 1 & visiblePositions <= numel(app.FilteredOrder));
            if isempty(visiblePositions)
                return
            end
            rows = app.FilteredOrder(visiblePositions);


            oldPosition = app.BlockStartIndex + min(app.SelectedVisibleIndices) - 1;
            app.classifyRows(rows, categoryIndex);
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.selectNextUnreviewedFromPosition(oldPosition);
            app.updateProgress();
        end

        function classifyAllVisibleCells(app, categoryIndex)
            arguments
                app
                categoryIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            if isempty(app.ActiveReviewTable) || isempty(app.FilteredOrder) || categoryIndex > numel(app.Categories)
                return
            end

            blockEnd = min(app.BlockStartIndex + app.Settings.CellsPerBlock - 1, numel(app.FilteredOrder));
            rows = app.FilteredOrder(app.BlockStartIndex:blockEnd);
            if isempty(rows)
                return
            end


            oldBlockStart = app.BlockStartIndex;
            oldSelectedVisibleIndex = app.SelectedVisibleIndex;
            app.classifyRows(rows, categoryIndex);
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.BlockStartIndex = app.clampBlockStart(oldBlockStart);
            blockEnd = min(app.BlockStartIndex + app.Settings.CellsPerBlock - 1, numel(app.FilteredOrder));
            visibleCount = max(blockEnd - app.BlockStartIndex + 1, 0);
            if visibleCount > 0
                app.SelectedVisibleIndex = min(max(oldSelectedVisibleIndex, 1), visibleCount);
                app.SelectedVisibleIndices = app.SelectedVisibleIndex;
            else
                app.SelectedVisibleIndex = 1;
                app.SelectedVisibleIndices = [];
            end
            app.showCurrentBlock();
            app.updateProgress();
        end

        function classifyRows(app, rows, categoryIndex)
            arguments
                app
                rows double
                categoryIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            rows = unique(rows(:));
            rows = rows(rows >= 1 & rows <= height(app.ActiveReviewTable));
            if isempty(rows) || categoryIndex > numel(app.Categories)
                return
            end

            app.pushUndo(rows);
            category = app.Categories(categoryIndex);
            app.ActiveReviewTable.QCLabel(rows) = string(category.Name);
            app.ActiveReviewTable.QCCode(rows) = double(category.Code);
            app.ActiveReviewTable.QCReviewed(rows) = true;
            app.ActiveReviewTable.QCReviewer(rows) = string(app.Settings.ReviewerName);
            app.ActiveReviewTable.QCTimestamp(rows) = datetime('now');
            app.ActiveReviewTable.QCCropWidth(rows) = double(app.Settings.CropWidth);
            app.ActiveReviewTable.QCCropHeight(rows) = double(app.Settings.CropHeight);
            app.Dirty = true;
            app.ClassificationsSinceSave = app.ClassificationsSinceSave + numel(rows);
            app.refreshActiveSourceProgress();
            app.updateDatasetTable();
            app.updateTissuePlotClasses(rows);
            app.updateTissuePlotSelection();

            if app.Settings.AutosaveEnabled && app.ClassificationsSinceSave >= app.Settings.AutosaveFrequency
                app.saveCurrentQC();
            end
        end

        function clearSelectedClassification(app)
            if isempty(app.ActiveReviewTable) || isnan(app.SelectedGlobalRow)
                return
            end
            rows = app.selectedRowsInCurrentBlock();
            app.pushUndo(rows);
            app.ActiveReviewTable.QCLabel(rows) = "";
            app.ActiveReviewTable.QCCode(rows) = NaN;
            app.ActiveReviewTable.QCReviewed(rows) = false;
            app.ActiveReviewTable.QCReviewer(rows) = "";
            app.ActiveReviewTable.QCTimestamp(rows) = NaT;
            app.Dirty = true;
            app.refreshActiveSourceProgress();
            app.updateDatasetTable();
            app.updateTissuePlotClasses(rows);
            app.updateTissuePlotSelection();
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.showCurrentBlock();
            app.updateProgress();
        end

        function rows = selectedRowsInCurrentBlock(app)
            if isempty(app.FilteredOrder) || isempty(app.SelectedVisibleIndices)
                rows = [];
                return
            end
            positions = app.BlockStartIndex + app.SelectedVisibleIndices - 1;
            positions = positions(positions >= 1 & positions <= numel(app.FilteredOrder));
            rows = app.FilteredOrder(positions);
        end

        function pushUndo(app, rows)
            arguments
                app
                rows double
            end

            rows = rows(:);
            state = struct();
            state.Rows = rows;
            state.X = app.ActiveReviewTable.X(rows);
            state.Y = app.ActiveReviewTable.Y(rows);
            state.QCLabel = app.ActiveReviewTable.QCLabel(rows);
            state.QCCode = app.ActiveReviewTable.QCCode(rows);
            state.QCReviewed = app.ActiveReviewTable.QCReviewed(rows);
            state.QCReviewer = app.ActiveReviewTable.QCReviewer(rows);
            state.QCTimestamp = app.ActiveReviewTable.QCTimestamp(rows);
            state.QCNotes = app.ActiveReviewTable.QCNotes(rows);
            state.QCCropWidth = app.ActiveReviewTable.QCCropWidth(rows);
            state.QCCropHeight = app.ActiveReviewTable.QCCropHeight(rows);
            app.UndoStack{end + 1} = state;
            if numel(app.UndoStack) > 200
                app.UndoStack = app.UndoStack(end - 199:end);
            end
        end

        function undoLastClassification(app)
            if isempty(app.UndoStack) || isempty(app.ActiveReviewTable)
                return
            end
            state = app.UndoStack{end};
            app.UndoStack(end) = [];
            rows = state.Rows;
            rows = rows(rows >= 1 & rows <= height(app.ActiveReviewTable));
            if isfield(state, 'X')
                app.ActiveReviewTable.X(rows) = state.X;
            end
            if isfield(state, 'Y')
                app.ActiveReviewTable.Y(rows) = state.Y;
            end
            app.ActiveReviewTable.QCLabel(rows) = state.QCLabel;
            app.ActiveReviewTable.QCCode(rows) = state.QCCode;
            app.ActiveReviewTable.QCReviewed(rows) = state.QCReviewed;
            app.ActiveReviewTable.QCReviewer(rows) = state.QCReviewer;
            app.ActiveReviewTable.QCTimestamp(rows) = state.QCTimestamp;
            app.ActiveReviewTable.QCNotes(rows) = state.QCNotes;
            app.ActiveReviewTable.QCCropWidth(rows) = state.QCCropWidth;
            app.ActiveReviewTable.QCCropHeight(rows) = state.QCCropHeight;
            app.syncActiveLocalizationCoordinates(rows);
            app.Dirty = true;
            app.refreshActiveSourceProgress();
            app.updateDatasetTable();
            app.updateTissuePlotClasses(rows);
            app.updateTissuePlotSelection();
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.selectRowIfVisible(rows(1), app.BlockStartIndex);
            app.updateProgress();
        end

        function onNotesChanged(app, src, event)
            arguments
                app
                src
                event
            end

            if isempty(app.ActiveReviewTable) || isnan(app.SelectedGlobalRow)
                return
            end
            row = app.SelectedGlobalRow;
            app.pushUndo(row);
            app.ActiveReviewTable.QCNotes(row) = string(src.Value);
            app.Dirty = true;
            if app.Settings.AutosaveEnabled
                app.saveCurrentQC();
            end
            app.refreshMontageAnnotations();
        end

        function selectNextUnreviewedFromPosition(app, oldPosition)
            arguments
                app
                oldPosition (1,1) double
            end

            if isempty(app.FilteredOrder)
                app.showCurrentBlock();
                return
            end
            reviewed = app.ActiveReviewTable.QCReviewed(app.FilteredOrder);
            unreviewedPositions = find(~reviewed);
            if isempty(unreviewedPositions)
                app.selectPositionInFilteredOrder(min(max(1, oldPosition), numel(app.FilteredOrder)));
                return
            end
            next = unreviewedPositions(find(unreviewedPositions >= oldPosition, 1, 'first'));
            if isempty(next)
                if app.Settings.AutoNextBlockBehavior
                    next = unreviewedPositions(1);
                else
                    next = min(max(1, oldPosition), numel(app.FilteredOrder));
                end
            end
            app.selectPositionInFilteredOrder(next);
        end

        function selectRowIfVisible(app, rowIdx, fallbackPosition)
            arguments
                app
                rowIdx (1,1) double
                fallbackPosition (1,1) double
            end

            pos = find(app.FilteredOrder == rowIdx, 1, 'first');
            if isempty(pos)
                pos = min(max(1, fallbackPosition), max(1, numel(app.FilteredOrder)));
            end
            app.selectPositionInFilteredOrder(pos);
        end

        function selectPositionInFilteredOrder(app, pos)
            arguments
                app
                pos (1,1) double
            end

            if isempty(app.FilteredOrder)
                app.showCurrentBlock();
                return
            end
            pos = min(max(1, round(pos)), numel(app.FilteredOrder));
            oldBlockStart = app.BlockStartIndex;
            app.BlockStartIndex = floor((pos - 1) / app.Settings.CellsPerBlock) * app.Settings.CellsPerBlock + 1;
            app.SelectedVisibleIndex = pos - app.BlockStartIndex + 1;
            app.SelectedVisibleIndices = app.SelectedVisibleIndex;
            app.SelectedGlobalRow = app.FilteredOrder(pos);

            if app.BlockStartIndex == oldBlockStart && ~isempty(app.MontageVisibleRows)
                app.refreshMontageAnnotations();
                app.updateSelectedCellDetail();
                app.updateProgress();
            else
                app.showCurrentBlock();
            end
        end

        function goToNextCell(app)
            if isempty(app.FilteredOrder)
                return
            end
            currentPos = app.BlockStartIndex + app.SelectedVisibleIndex - 1;
            app.selectPositionInFilteredOrder(min(currentPos + 1, numel(app.FilteredOrder)));
        end

        function goToPreviousCell(app)
            if isempty(app.FilteredOrder)
                return
            end
            currentPos = app.BlockStartIndex + app.SelectedVisibleIndex - 1;
            app.selectPositionInFilteredOrder(max(currentPos - 1, 1));
        end

        function goToNextBlock(app)
            if isempty(app.FilteredOrder)
                return
            end
            app.saveIfDirtyForTransition();
            app.BlockStartIndex = app.clampBlockStart(app.BlockStartIndex + app.Settings.CellsPerBlock);
            app.SelectedVisibleIndex = 1;
            app.SelectedVisibleIndices = 1;
            app.showCurrentBlock();
        end

        function goToPreviousBlock(app)
            if isempty(app.FilteredOrder)
                return
            end
            app.saveIfDirtyForTransition();
            app.BlockStartIndex = app.clampBlockStart(app.BlockStartIndex - app.Settings.CellsPerBlock);
            app.SelectedVisibleIndex = 1;
            app.SelectedVisibleIndices = 1;
            app.showCurrentBlock();
        end

        function goToBlock(app, blockIndex)
            arguments
                app
                blockIndex (1,1) double {mustBeInteger, mustBePositive}
            end

            if isempty(app.FilteredOrder)
                return
            end

            app.saveIfDirtyForTransition();
            app.BlockStartIndex = (blockIndex - 1) * app.Settings.CellsPerBlock + 1;
            app.BlockStartIndex = app.clampBlockStart(app.BlockStartIndex);
            app.SelectedVisibleIndex = 1;
            app.SelectedVisibleIndices = 1;
            app.showCurrentBlock();
        end

        function onBlockDropDownChanged(app, src, event)
            arguments
                app
                src
                event
            end

            value = string(src.Value);
            tokens = regexp(char(value), '^Block\s+(\d+)', 'tokens', 'once');
            if isempty(tokens)
                return
            end

            blockIndex = str2double(tokens{1});
            if isfinite(blockIndex) && blockIndex >= 1
                app.goToBlock(round(blockIndex));
            end
        end

        function updateBlockNavigationControls(app, blockIndex, numBlocks)
            arguments
                app
                blockIndex (1,1) double {mustBeInteger, mustBePositive}
                numBlocks (1,1) double {mustBeInteger, mustBePositive}
            end

            if isempty(app.BlockDropDown) || ~isvalid(app.BlockDropDown)
                return
            end

            numBlocks = max(1, numBlocks);
            blockIndex = min(max(1, blockIndex), numBlocks);
            items = compose('Block %d', 1:numBlocks);
            app.BlockDropDown.Items = cellstr(items);
            app.BlockDropDown.Value = char(items(blockIndex));

            if ~isempty(app.PreviousBlockButton) && isvalid(app.PreviousBlockButton)
                app.PreviousBlockButton.Enable = app.onOff(blockIndex > 1);
            end
            if ~isempty(app.NextBlockButton) && isvalid(app.NextBlockButton)
                app.NextBlockButton.Enable = app.onOff(blockIndex < numBlocks);
            end
        end

        function goToNextUnreviewed(app)
            if isempty(app.FilteredOrder)
                return
            end
            currentPos = app.BlockStartIndex + app.SelectedVisibleIndex;
            app.selectNextUnreviewedFromPosition(currentPos);
        end

        function goToNextDatasetOrSource(app)
            if app.ActiveDatasetIndex < 1
                return
            end
            sources = app.SourceListByDataset{app.ActiveDatasetIndex};
            if app.ActiveSourceIndex < numel(sources)
                app.SourceDropDown.Value = app.ActiveSourceIndex + 1;
                app.loadLocalizationSource(app.ActiveSourceIndex + 1);
            elseif app.ActiveDatasetIndex < height(app.DatasetList)
                app.loadDataset(app.ActiveDatasetIndex + 1);
            end
        end

        function goToPreviousDatasetOrSource(app)
            if app.ActiveDatasetIndex < 1
                return
            end
            if app.ActiveSourceIndex > 1
                app.SourceDropDown.Value = app.ActiveSourceIndex - 1;
                app.loadLocalizationSource(app.ActiveSourceIndex - 1);
            elseif app.ActiveDatasetIndex > 1
                app.loadDataset(app.ActiveDatasetIndex - 1);
            end
        end

        function selectAllVisibleCells(app)
            if isempty(app.FilteredOrder)
                return
            end
            nVisible = app.currentVisibleTileCount();
            if nVisible < 1
                return
            end
            app.SelectedVisibleIndices = 1:nVisible;
            app.SelectedVisibleIndex = 1;
            app.SelectedGlobalRow = app.FilteredOrder(app.BlockStartIndex);
            app.refreshMontageAnnotations();
            app.updateSelectedCellDetail();
            app.updateProgress();
        end


        function exportObservationCsvDialog(app)
            if isempty(app.DatasetList) || height(app.DatasetList) == 0 || isempty(app.SourceListByDataset)
                uialert(app.UIFigure, 'No scanned datasets are available to export.', 'No data');
                return
            end

            if app.Dirty
                app.saveCurrentQC();
            end

            choice = uiconfirm(app.UIFigure, ...
                'Include observations without a QC classification?', ...
                'Export observation CSV', ...
                'Options', {'Include unclassified', 'Classified only', 'Cancel'}, ...
                'DefaultOption', 1, ...
                'CancelOption', 3);
            if strcmp(choice, 'Cancel')
                return
            end
            includeUnclassified = strcmp(choice, 'Include unclassified');

            defaultName = sprintf('CellLocalizationQC_observations_%s.csv', datestr(now, 'yyyymmdd_HHMMSS'));
            if strlength(app.ParentDirectory) > 0 && isfolder(app.ParentDirectory)
                defaultPath = fullfile(char(app.ParentDirectory), defaultName);
            else
                defaultPath = defaultName;
            end

            [fileName, folderName] = uiputfile({'*.csv', 'CSV files (*.csv)'}, ...
                'Export observation CSV', defaultPath);
            if isequal(fileName, 0) || isequal(folderName, 0)
                return
            end

            outPath = fullfile(folderName, fileName);
            try
                exportTbl = app.buildObservationExportTable(includeUnclassified);
                writetable(exportTbl, outPath);
            catch ME
                uialert(app.UIFigure, ME.message, 'Observation export failed');
                app.updateStatus("Observation export failed: " + string(ME.message));
                return
            end

            app.updateStatus(sprintf('Exported %d observation(s): %s', height(exportTbl), outPath));
            uialert(app.UIFigure, sprintf('Exported %d observation(s).', height(exportTbl)), 'Observation export complete');
        end

        function exportTbl = buildObservationExportTable(app, includeUnclassified)
            arguments
                app
                includeUnclassified (1,1) logical
            end

            pieces = cell(0, 1);
            skipped = strings(0, 1);

            for datasetIndex = 1:numel(app.SourceListByDataset)
                sources = app.SourceListByDataset{datasetIndex};
                for sourceIndex = 1:numel(sources)
                    source = sources(sourceIndex);
                    try
                        sourceTbl = app.observationExportTableForSource(source, includeUnclassified);
                    catch ME
                        skipped(end + 1, 1) = sprintf('%s: %s', char(app.sourceIdentity(source)), ME.message); %#ok<AGROW>
                        continue
                    end

                    if ~isempty(sourceTbl) && height(sourceTbl) > 0
                        pieces{end + 1, 1} = sourceTbl; %#ok<AGROW>
                    end
                end
            end

            if isempty(pieces)
                exportTbl = app.emptyObservationExportTable();
            else
                exportTbl = vertcat(pieces{:});
            end

            if ~isempty(skipped)
                app.updateStatus(sprintf('Observation export skipped %d source(s).', numel(skipped)));
            end
        end

        function outTbl = observationExportTableForSource(app, source, includeUnclassified)
            arguments
                app
                source struct
                includeUnclassified (1,1) logical
            end

            qcPath = app.qcPathForCsv(source.CsvPath);
            useQC = isfile(qcPath);
            if useQC
                tbl = readtable(char(qcPath), 'TextType', 'string', 'VariableNamingRule', 'preserve');
            else
                if ~includeUnclassified
                    outTbl = app.emptyObservationExportTable();
                    return
                end
                tbl = readtable(char(source.CsvPath), 'TextType', 'string', 'VariableNamingRule', 'preserve');
            end

            n = height(tbl);
            if n == 0
                outTbl = app.emptyObservationExportTable();
                return
            end

            x = app.tableNumericColumn(tbl, "X", NaN);
            y = app.tableNumericColumn(tbl, "Y", NaN);
            score = app.tableNumericColumn(tbl, "score", NaN);
            rescore = app.tableNumericColumn(tbl, "rescore", NaN);
            cropHeight = app.tableNumericColumn(tbl, "QCCropHeight", double(app.Settings.CropHeight));
            cropWidth = app.tableNumericColumn(tbl, "QCCropWidth", double(app.Settings.CropWidth));

            labels = app.tableStringColumn(tbl, "QCLabel", "");
            labels = strtrim(labels);
            isClassified = ~ismissing(labels) & strlength(labels) > 0;
            if includeUnclassified
                labels(~isClassified) = "Unclassified";
                keep = true(n, 1);
            else
                keep = isClassified;
            end

            imagePath = repmat(string(source.ImagePath), n, 1);
            pageNumber = repmat(double(source.PageIndex), n, 1);
            pageAlias = repmat(string(source.ChannelName), n, 1);

            observationId = app.observationMd5Ids(imagePath, pageAlias, x, y);

            outTbl = table(observationId(keep), imagePath(keep), pageNumber(keep), pageAlias(keep), ...
                x(keep), y(keep), score(keep), rescore(keep), ...
                cropHeight(keep), cropWidth(keep), labels(keep), ...
                'VariableNames', {'ObservationID', 'ImagePath', 'TiffPageNumber', 'PageAlias', 'X', 'Y', ...
                'Score', 'Rescore', 'CropHeight', 'CropWidth', 'Classification'});
        end

        function ids = observationMd5Ids(app, imagePath, pageAlias, x, y)
            arguments
                app
                imagePath (:,1) string
                pageAlias (:,1) string
                x (:,1) double
                y (:,1) double
            end

            n = numel(imagePath);
            ids = strings(n, 1);
            for row = 1:n
                key = sprintf('%s|%s|%.15g|%.15g', ...
                    char(imagePath(row)), char(pageAlias(row)), x(row), y(row));
                ids(row) = app.md5String(key);
            end
        end

        function hashText = md5String(app, inputText)
            arguments
                app
                inputText (1,:) char
            end

            digest = java.security.MessageDigest.getInstance('MD5');
            rawHash = digest.digest(uint8(inputText));
            hashBytes = typecast(rawHash, 'uint8');
            hashText = string(lower(sprintf('%02x', hashBytes)));
        end

        function tbl = emptyObservationExportTable(app)
            arguments
                app
            end

            tbl = table(string.empty(0,1), string.empty(0,1), zeros(0,1), string.empty(0,1), ...
                zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
                zeros(0,1), zeros(0,1), string.empty(0,1), ...
                'VariableNames', {'ObservationID', 'ImagePath', 'TiffPageNumber', 'PageAlias', 'X', 'Y', ...
                'Score', 'Rescore', 'CropHeight', 'CropWidth', 'Classification'});
        end

        function values = tableNumericColumn(app, tbl, requestedName, defaultValue)
            arguments
                app
                tbl table
                requestedName (1,1) string
                defaultValue (1,1) double = NaN
            end

            n = height(tbl);
            values = repmat(defaultValue, n, 1);
            varName = app.findTableVariable(tbl, requestedName);
            if strlength(varName) == 0
                return
            end

            raw = tbl.(char(varName));
            if isnumeric(raw) || islogical(raw)
                values = double(raw(:));
            elseif isstring(raw) || iscellstr(raw) || iscategorical(raw)
                values = str2double(string(raw(:)));
            elseif iscell(raw)
                values = str2double(string(raw(:)));
            else
                values = repmat(defaultValue, n, 1);
            end

            if numel(values) ~= n
                values = values(:);
                if numel(values) < n
                    values(end + 1:n, 1) = defaultValue;
                elseif numel(values) > n
                    values = values(1:n);
                end
            end
        end

        function values = tableStringColumn(app, tbl, requestedName, defaultValue)
            arguments
                app
                tbl table
                requestedName (1,1) string
                defaultValue (1,1) string = ""
            end

            n = height(tbl);
            values = repmat(defaultValue, n, 1);
            varName = app.findTableVariable(tbl, requestedName);
            if strlength(varName) == 0
                return
            end

            raw = tbl.(char(varName));
            values = string(raw(:));
            if numel(values) ~= n
                values = values(:);
                if numel(values) < n
                    values(end + 1:n, 1) = defaultValue;
                elseif numel(values) > n
                    values = values(1:n);
                end
            end
            values(ismissing(values)) = defaultValue;
        end

        function varName = findTableVariable(app, tbl, requestedName)
            arguments
                app
                tbl table
                requestedName (1,1) string
            end

            names = string(tbl.Properties.VariableNames);
            idx = find(names == requestedName, 1, 'first');
            if isempty(idx)
                idx = find(strcmpi(cellstr(names), char(requestedName)), 1, 'first');
            end
            if isempty(idx)
                varName = "";
            else
                varName = names(idx);
            end
        end

        function saveCurrentQC(app)
            if isempty(app.ActiveReviewTable) || isempty(app.ActiveSource) || ~isfield(app.ActiveSource, 'CsvPath')
                return
            end
            qcPath = app.qcPathForCsv(app.ActiveSource.CsvPath);
            folder = string(fileparts(char(qcPath)));
            if ~isfolder(folder)
                uialert(app.UIFigure, 'QC output folder does not exist.', 'Save failed');
                return
            end

            tempPath = string(qcPath) + ".tmp_" + string(char(java.util.UUID.randomUUID)) + ".csv";
            try
                writetable(app.ActiveReviewTable, char(tempPath));
                if ~isfile(tempPath)
                    error('CellLocalizationQCApp:SaveFailed', 'Temporary QC file was not created.');
                end
                if isfile(qcPath)
                    delete(qcPath);
                end
                movefile(char(tempPath), char(qcPath), 'f');
            catch ME
                if isfile(tempPath)
                    delete(tempPath);
                end
                uialert(app.UIFigure, ME.message, 'QC save failed');
                app.updateStatus("Save failed: " + string(ME.message));
                return
            end

            app.Dirty = false;
            app.ClassificationsSinceSave = 0;
            app.LastAutosaveTime = datetime('now');
            app.refreshActiveSourceProgress();
            app.updateDatasetTable();
            app.updateProgress();
            app.updateStatus("Saved QC file: " + string(qcPath));
        end

        function saveIfDirtyForTransition(app)
            if app.Dirty && app.Settings.AutosaveEnabled
                app.saveCurrentQC();
            end
        end

        function onDatasetTableSelected(app, src, event)
            arguments
                app
                src
                event
            end

            if isempty(event.Indices)
                return
            end
            row = event.Indices(1);
            if row >= 1 && row <= height(app.DatasetList)
                app.loadDataset(row);
            end
        end

        function onBlockSettingsChanged(app)
            app.readSettingsFromUI();
            app.saveSettings();
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.showCurrentBlock();
        end

        function onCropSettingsChanged(app, widthChanged)
            arguments
                app
                widthChanged (1,1) logical
            end

            if app.LinkedSquareCheckBox.Value
                if widthChanged
                    app.CropHeightSpinner.Value = app.CropWidthSpinner.Value;
                else
                    app.CropWidthSpinner.Value = app.CropHeightSpinner.Value;
                end
            end
            app.readSettingsFromUI();
            app.updateActiveBorderFlags();
            app.saveSettings();
            app.buildDisplayOrder();
            app.applyFilter(false);
            app.showCurrentBlock();
        end

        function onSortOrFilterChanged(app)
            app.readSettingsFromUI();
            app.saveSettings();
            app.buildDisplayOrder();
            app.applyFilter(true);
            app.showCurrentBlock();
        end

        function onDisplaySettingsChanged(app)
            app.readSettingsFromUI();
            app.saveSettings();
            app.showCurrentBlock();
        end

        function openSettingsDialog(app)
            dlg = uifigure("Name", "Cell Localization QC Settings", "Position", [250 250 720 560]);
            mainGrid = uigridlayout(dlg, [2 1]);
            mainGrid.RowHeight = {'1x', 34};
            mainGrid.ColumnWidth = {'1x'};
            mainGrid.Padding = [8 8 8 8];

            tabs = uitabgroup(mainGrid);

            projectTab = uitab(tabs, "Title", "Project");
            projectGrid = uigridlayout(projectTab, [5 2]);
            projectGrid.RowHeight = {28, 28, 28, '1x', 24};
            projectGrid.ColumnWidth = {150, '1x'};
            projectGrid.Padding = [8 8 8 8];
            uilabel(projectGrid, "Text", "Image pattern", "HorizontalAlignment", "right");
            controls.ImagePatternEdit = uieditfield(projectGrid, "text", "Value", char(string(app.Settings.ImagePattern)));
            uilabel(projectGrid, "Text", "Localization pattern", "HorizontalAlignment", "right");
            controls.LocalizationPatternEdit = uieditfield(projectGrid, "text", "Value", char(string(app.Settings.LocalizationPattern)));
            uilabel(projectGrid, "Text", "Reviewer name", "HorizontalAlignment", "right");
            controls.ReviewerEdit = uieditfield(projectGrid, "text", "Value", char(string(app.Settings.ReviewerName)));
            uilabel(projectGrid, "Text", "Channel to TIFF page", "HorizontalAlignment", "right", "VerticalAlignment", "top");
            map = app.Settings.ChannelMap;
            channelData = table(string({map.Channel})', double([map.PageIndex])', 'VariableNames', {'Channel', 'PageIndex'});
            controls.ChannelTable = uitable(projectGrid, "Data", channelData, "ColumnEditable", [true true]);
            uilabel(projectGrid, "Text", "Add rows directly in the table if needed.");

            categoriesTab = uitab(tabs, "Title", "Categories");
            categoriesGrid = uigridlayout(categoriesTab, [2 1]);
            categoriesGrid.RowHeight = {'1x', 24};
            categoriesGrid.Padding = [8 8 8 8];
            catNames = strings(numel(app.Categories), 1);
            catCodes = zeros(numel(app.Categories), 1);
            catShortcuts = strings(numel(app.Categories), 1);
            for k = 1:numel(app.Categories)
                catNames(k) = string(app.Categories(k).Name);
                catCodes(k) = double(app.Categories(k).Code);
                catShortcuts(k) = string(app.Categories(k).Shortcut);
            end
            categoryData = table(catNames, catCodes, catShortcuts, 'VariableNames', {'Name', 'Code', 'Shortcut'});
            controls.CategoryTable = uitable(categoriesGrid, "Data", categoryData, "ColumnEditable", [true true true]);
            uilabel(categoriesGrid, "Text", "Numeric shortcuts 1-9 are always mapped to category order.");

            reviewTab = uitab(tabs, "Title", "Review");
            reviewGrid = uigridlayout(reviewTab, [7 2]);
            reviewGrid.RowHeight = {28, 28, 28, 28, 28, 28, '1x'};
            reviewGrid.ColumnWidth = {170, '1x'};
            reviewGrid.Padding = [8 8 8 8];
            uilabel(reviewGrid, "Text", "Autosave enabled", "HorizontalAlignment", "right");
            controls.AutosaveCheckBox = uicheckbox(reviewGrid, "Text", "", "Value", logical(app.Settings.AutosaveEnabled));
            uilabel(reviewGrid, "Text", "Autosave frequency", "HorizontalAlignment", "right");
            controls.AutosaveFrequencySpinner = uispinner(reviewGrid, "Limits", [1 1000], "RoundFractionalValues", "on", "Value", double(app.Settings.AutosaveFrequency));
            uilabel(reviewGrid, "Text", "Ignore border crops", "HorizontalAlignment", "right");
            controls.IgnoreBorderCheckBox = uicheckbox(reviewGrid, "Text", "", "Value", logical(app.Settings.IgnoreBorderObservations));
            uilabel(reviewGrid, "Text", "Marker style", "HorizontalAlignment", "right");
            controls.MarkerStyleDropDown = uidropdown(reviewGrid, "Items", ["crosshair", "circle"], "Value", char(string(app.Settings.MarkerStyle)));
            uilabel(reviewGrid, "Text", "Marker size", "HorizontalAlignment", "right");
            controls.MarkerSizeSpinner = uispinner(reviewGrid, "Limits", [3 50], "RoundFractionalValues", "on", "Value", double(app.Settings.MarkerSize));
            uilabel(reviewGrid, "Text", "Manual contrast min/max", "HorizontalAlignment", "right");
            contrastGrid = uigridlayout(reviewGrid, [1 2]);
            contrastGrid.Padding = [0 0 0 0];
            limits = double(app.Settings.ManualContrastLimits);
            if numel(limits) == 2 && all(isfinite(limits)) && limits(2) > limits(1)
                manualLimitText = compose("%g", limits);
            else
                manualLimitText = ["", ""];
            end
            controls.ManualMinEdit = uieditfield(contrastGrid, "text", "Value", char(manualLimitText(1)));
            controls.ManualMaxEdit = uieditfield(contrastGrid, "text", "Value", char(manualLimitText(2)));

            app.setTooltip(controls.ImagePatternEdit, "Image filename pattern for recursive scan. Default: *_proj.tif.");
            app.setTooltip(controls.LocalizationPatternEdit, "Localization CSV pattern for recursive scan. Default: *_locs.csv.");
            app.setTooltip(controls.ReviewerEdit, "Reviewer name stored in QCReviewer when cells are classified.");
            app.setTooltip(controls.ChannelTable, "Editable channel-to-TIFF-page mapping, for example ECM=1 and PV=2.");
            app.setTooltip(controls.CategoryTable, "Editable QC categories, numeric codes, and key shortcuts.");
            app.setTooltip(controls.AutosaveCheckBox, "Enable automatic QC CSV saving after classifications. Default: on.");
            app.setTooltip(controls.AutosaveFrequencySpinner, "Number of classifications between autosaves. Default: 1.");
            app.setTooltip(controls.IgnoreBorderCheckBox, "Exclude observations whose crop would touch or extend past an image border. Default: on.");
            app.setTooltip(controls.MarkerStyleDropDown, "Localization marker style shown in crop views. Default: crosshair.");
            app.setTooltip(controls.MarkerSizeSpinner, "Localization marker size in pixels. Default: 7.");
            app.setTooltip(controls.ManualMinEdit, "Manual display contrast minimum used only in Manual min-max mode.");
            app.setTooltip(controls.ManualMaxEdit, "Manual display contrast maximum used only in Manual min-max mode.");

            buttonGrid = uigridlayout(mainGrid, [1 3]);
            buttonGrid.ColumnWidth = {'1x', 90, 90};
            buttonGrid.Padding = [0 0 0 0];
            uilabel(buttonGrid, "Text", "Settings are persisted with setpref and a MAT file in prefdir.");
            applyButton = uibutton(buttonGrid, "push", "Text", "Apply", "ButtonPushedFcn", @(src, event) app.applySettingsDialog(dlg));
            cancelButton = uibutton(buttonGrid, "push", "Text", "Cancel", "ButtonPushedFcn", @(src, event) delete(dlg));
            app.setTooltip(applyButton, "Apply settings, persist them, and refresh the active source where needed.");
            app.setTooltip(cancelButton, "Close without applying settings changes.");

            setappdata(dlg, 'Controls', controls);
        end

        function applySettingsDialog(app, dlg)
            arguments
                app
                dlg
            end

            if isempty(dlg) || ~isvalid(dlg) || ~isappdata(dlg, 'Controls')
                return
            end
            controls = getappdata(dlg, 'Controls');

            [channelMap, channelStatus] = app.tableDataToChannelMap(controls.ChannelTable.Data);
            if strlength(channelStatus) > 0
                uialert(dlg, char(channelStatus), 'Invalid channel map');
                return
            end

            [categories, categoryStatus] = app.tableDataToCategories(controls.CategoryTable.Data);
            if strlength(categoryStatus) > 0
                uialert(dlg, char(categoryStatus), 'Invalid categories');
                return
            end

            imagePattern = string(strtrim(controls.ImagePatternEdit.Value));
            localizationPattern = string(strtrim(controls.LocalizationPatternEdit.Value));
            if strlength(imagePattern) == 0 || strlength(localizationPattern) == 0
                uialert(dlg, 'Image and localization patterns must be nonempty.', 'Invalid patterns');
                return
            end

            app.Settings.ImagePattern = imagePattern;
            app.Settings.LocalizationPattern = localizationPattern;
            app.Settings.ReviewerName = string(strtrim(controls.ReviewerEdit.Value));
            app.Settings.ChannelMap = channelMap;
            app.Settings.Categories = categories;
            app.Settings.AutosaveEnabled = logical(controls.AutosaveCheckBox.Value);
            app.Settings.AutosaveFrequency = max(1, round(controls.AutosaveFrequencySpinner.Value));
            app.Settings.IgnoreBorderObservations = logical(controls.IgnoreBorderCheckBox.Value);
            app.Settings.MarkerStyle = string(controls.MarkerStyleDropDown.Value);
            app.Settings.MarkerSize = max(3, round(controls.MarkerSizeSpinner.Value));

            manualMinText = strtrim(string(controls.ManualMinEdit.Value));
            manualMaxText = strtrim(string(controls.ManualMaxEdit.Value));
            if strlength(manualMinText) == 0 && strlength(manualMaxText) == 0
                app.Settings.ManualContrastLimits = [NaN NaN];
            else
                manualMin = str2double(manualMinText);
                manualMax = str2double(manualMaxText);
                if ~isfinite(manualMin) || ~isfinite(manualMax) || manualMax <= manualMin
                    uialert(dlg, 'Manual contrast limits must be blank or finite numeric values with max greater than min.', 'Invalid manual contrast');
                    return
                end
                app.Settings.ManualContrastLimits = [manualMin, manualMax];
            end
            app.Categories = app.sanitizeCategories(app.Settings.Categories);
            app.Settings.Categories = app.Categories;
            app.saveSettings();
            app.applySettingsToUI();
            app.rebuildCategoryButtons();

            if ~isempty(app.ActiveReviewTable)
                app.updateActiveBorderFlags();
                app.refreshSortAndFilterControls();
                app.buildDisplayOrder();
                app.applyFilter(false);
                app.showCurrentBlock();
            end
            delete(dlg);
            app.updateStatus("Settings updated.");
        end

        function [channelMap, status] = tableDataToChannelMap(app, data)
            arguments
                app
                data
            end

            status = "";
            channelMap = app.Settings.ChannelMap;
            if istable(data)
                if ~all(ismember(["Channel", "PageIndex"], string(data.Properties.VariableNames)))
                    status = "Channel table must contain Channel and PageIndex columns.";
                    return
                end
                channels = string(data.Channel);
                if isnumeric(data.PageIndex)
                    pages = double(data.PageIndex);
                else
                    pages = str2double(string(data.PageIndex));
                end
            elseif iscell(data)
                channels = string(data(:, 1));
                pages = str2double(string(data(:, 2)));
            else
                status = "Channel table data is not readable.";
                return
            end

            nonemptyChannels = strlength(strtrim(channels)) > 0;
            if any(nonemptyChannels & (~isfinite(pages) | pages < 1))
                status = "Mapped channels must have positive numeric page indices.";
                return
            end
            valid = nonemptyChannels & isfinite(pages) & pages >= 1;
            channels = strtrim(channels(valid));
            pages = round(pages(valid));
            if isempty(channels)
                status = "At least one channel mapping is required.";
                return
            end
            if numel(unique(lower(channels))) ~= numel(channels)
                status = "Channel names must be unique.";
                return
            end
            channelMap = repmat(struct('Channel', '', 'PageIndex', 1), numel(channels), 1);
            for k = 1:numel(channels)
                channelMap(k).Channel = char(channels(k));
                channelMap(k).PageIndex = pages(k);
            end
        end

        function [categories, status] = tableDataToCategories(app, data)
            arguments
                app
                data
            end

            status = "";
            categories = app.Categories;
            if istable(data)
                if ~all(ismember(["Name", "Code", "Shortcut"], string(data.Properties.VariableNames)))
                    status = "Category table must contain Name, Code, and Shortcut columns.";
                    return
                end
                names = strtrim(string(data.Name));
                if isnumeric(data.Code)
                    codes = double(data.Code);
                else
                    codes = str2double(string(data.Code));
                end
                shortcuts = strtrim(string(data.Shortcut));
            elseif iscell(data)
                names = strtrim(string(data(:, 1)));
                codes = str2double(string(data(:, 2)));
                shortcuts = strtrim(string(data(:, 3)));
            else
                status = "Category table data is not readable.";
                return
            end

            valid = strlength(names) > 0;
            names = names(valid);
            codes = codes(valid);
            shortcuts = shortcuts(valid);
            if isempty(names)
                status = "At least one category is required.";
                return
            end
            if any(~isfinite(codes))
                status = "Category codes must be numeric.";
                return
            end
            if numel(unique(lower(names))) ~= numel(names)
                status = "Category names must be unique.";
                return
            end
            if any(strlength(shortcuts) == 0)
                status = "Every category must have a shortcut.";
                return
            end
            if numel(unique(lower(shortcuts))) ~= numel(shortcuts)
                status = "Category shortcuts must be unique.";
                return
            end

            categories = repmat(struct('Name', '', 'Code', 1, 'Shortcut', '', 'Color', [0.5 0.5 0.5]), numel(names), 1);
            for k = 1:numel(names)
                categories(k).Name = char(names(k));
                categories(k).Code = codes(k);
                categories(k).Shortcut = char(shortcuts(k));
                categories(k).Color = app.categoryColorForName(names(k), k);
            end
        end

        function color = categoryColorForName(app, name, index)
            arguments
                app
                name (1,1) string
                index (1,1) double
            end

            color = [0.5 0.5 0.5];
            for k = 1:numel(app.Categories)
                if strcmpi(char(name), char(string(app.Categories(k).Name))) && isfield(app.Categories(k), 'Color')
                    oldColor = app.Categories(k).Color;
                    if isnumeric(oldColor) && numel(oldColor) == 3
                        color = double(oldColor(:))';
                    end
                    return
                end
            end
            defaults = app.defaultSettings();
            if index <= numel(defaults.Categories)
                color = defaults.Categories(index).Color;
            end
        end

        function bindKeyboardCallbacks(app)
            if isempty(app.UIFigure) || ~isvalid(app.UIFigure)
                return
            end
            app.bindKeyboardCallbacksRecursive(app.UIFigure);
        end

        function bindKeyboardCallbacksRecursive(app, component)
            if isempty(component)
                return
            end
            try
                if ~isvalid(component)
                    return
                end
            catch
                return
            end

            hasWindowKeyPress = isprop(component, 'WindowKeyPressFcn');
            hasWindowKeyRelease = isprop(component, 'WindowKeyReleaseFcn');

            if hasWindowKeyPress
                component.WindowKeyPressFcn = @(src, event) app.handleKeyPress(src, event);
            elseif isprop(component, 'KeyPressFcn') && ~app.isTextEntryComponent(component)
                component.KeyPressFcn = @(src, event) app.handleKeyPress(src, event);
            end

            if hasWindowKeyRelease
                component.WindowKeyReleaseFcn = @(src, event) app.handleKeyRelease(src, event);
            elseif isprop(component, 'KeyReleaseFcn') && ~app.isTextEntryComponent(component)
                component.KeyReleaseFcn = @(src, event) app.handleKeyRelease(src, event);
            end

            if isprop(component, 'Children')
                children = component.Children;
                for k = 1:numel(children)
                    app.bindKeyboardCallbacksRecursive(children(k));
                end
            end
        end

        function tf = isTextEntryComponent(app, component)
            arguments
                app
                component
            end

            className = string(class(component));
            tf = contains(className, 'EditField') || contains(className, 'TextArea');
        end

        function tf = currentFocusIsTextEntry(app)
            tf = false;
            if isempty(app.UIFigure) || ~isvalid(app.UIFigure) || ~isprop(app.UIFigure, 'CurrentObject')
                return
            end

            currentObject = app.UIFigure.CurrentObject;
            if isempty(currentObject)
                return
            end
            tf = app.isTextEntryComponent(currentObject);
        end

        function handleKeyPress(app, src, event)
            arguments
                app
                src
                event
            end

            key = lower(string(event.Key));
            modifiers = lower(string(event.Modifier));
            hasCtrl = any(modifiers == "control") || any(modifiers == "command");
            hasShift = any(modifiers == "shift");

            if ~hasCtrl && app.currentFocusIsTextEntry()
                return
            end

            if hasCtrl && (key == "slash" || key == "/" || key == "questionmark" || key == "?")
                app.showKeyboardShortcutsDialog();
                return
            elseif hasCtrl && (key == "rightarrow" || key == "right")
                app.goToNextDatasetOrSource();
                return
            elseif hasCtrl && (key == "leftarrow" || key == "left")
                app.goToPreviousDatasetOrSource();
                return
            elseif hasCtrl && key == "s"
                app.saveCurrentQC();
                return
            elseif hasCtrl && key == "z"
                app.undoLastClassification();
                return
            end

            if ~hasCtrl && ~hasShift && any(key == ["w", "n"])
                app.goToNextBlock();
                return
            elseif ~hasCtrl && ~hasShift && any(key == ["q", "p"])
                app.goToPreviousBlock();
                return
            end

            idx = app.categoryIndexFromKey(key);
            if ~isempty(idx)
                if hasCtrl || hasShift
                    app.classifyAllVisibleCells(idx);
                else
                    if isnan(app.HeldClassIndex) || app.HeldClassKey ~= key
                        app.HeldClassUsedForClick = false;
                    end
                    app.HeldClassIndex = idx;
                    app.HeldClassKey = key;
                    app.updateStatus("Hold " + key + " and click montage tiles to label as " + string(app.Categories(idx).Name) + ". Release to label the selected tile.");
                end
                return
            end

            switch key
                case ["rightarrow", "right", "tab"]
                    if hasShift
                        app.goToPreviousCell();
                    else
                        app.goToNextCell();
                    end
                case ["leftarrow", "left"]
                    app.goToPreviousCell();
                case ["w", "n"]
                    app.goToNextBlock();
                case ["q", "p"]
                    app.goToPreviousBlock();
                case "space"
                    app.goToNextUnreviewed();
                case "home"
                    app.selectPositionInFilteredOrder(1);
                case "end"
                    app.selectPositionInFilteredOrder(numel(app.FilteredOrder));
                case ["backspace", "delete"]
                    app.clearSelectedClassification();
                case "z"
                    app.undoLastClassification();
                case "s"
                    app.saveCurrentQC();
                case "m"
                    app.MarkerCheckBox.Value = ~app.MarkerCheckBox.Value;
                    app.onDisplaySettingsChanged();
                case "o"
                    app.cycleDisplayMode();
                case "a"
                    app.selectAllVisibleCells();
                case "f"
                    app.showSelectedCropFigure();
            end
        end

        function handleKeyRelease(app, src, event)
            arguments
                app
                src
                event
            end

            key = lower(string(event.Key));
            idx = app.categoryIndexFromKey(key);
            if isempty(idx)
                return
            end
            if isnan(app.HeldClassIndex) || app.HeldClassKey ~= key
                return
            end

            usedForClick = app.HeldClassUsedForClick;
            app.HeldClassIndex = NaN;
            app.HeldClassKey = "";
            app.HeldClassUsedForClick = false;

            if ~usedForClick
                app.classifySelectedCellByIndex(idx);
            end
        end

        function showKeyboardShortcutsDialog(app)
            arguments
                app
            end

            categoryLines = strings(max(numel(app.Categories), 1), 1);
            if isempty(app.Categories)
                categoryLines = "No categories are configured.";
            else
                for k = 1:numel(app.Categories)
                    keyText = string(k);
                    shortcut = string(app.Categories(k).Shortcut);
                    if strlength(shortcut) > 0 && shortcut ~= keyText
                        keyText = keyText + " or " + shortcut;
                    end
                    categoryLines(k) = keyText + " = classify selected cell as " + string(app.Categories(k).Name);
                end
            end

            msg = [
                "Keyboard shortcuts"
                ""
                "Help"
                "Ctrl+/ or Ctrl+? = show this dialog"
                ""
                "Classification"
                categoryLines
                "Hold class key + click montage tile or Cell QC map point = classify clicked cell"
                "Shift + class key or Ctrl + class key = classify all visible cells"
                "Backspace or Delete = clear selected classification"
                "z or Ctrl+Z = undo last classification"
                "a = select all visible cells"
                ""
                "Navigation"
                "RightArrow or Tab = next visible cell"
                "LeftArrow or Shift+Tab = previous visible cell"
                "Space = next unreviewed cell"
                "w or n = next block"
                "q or p = previous block"
                "Home = first cell in current order"
                "End = last cell in current order"
                "Ctrl+RightArrow = next dataset or localization source"
                "Ctrl+LeftArrow = previous dataset or localization source"
                ""
                "Display and saving"
                "s or Ctrl+S = save current QC table"
                "m = toggle marker visibility"
                "o = cycle display mode"
                "f = show selected crop in a separate figure"
                ""
                "Mouse"
                "Click tile = select cell"
                "Shift+click tile = toggle multi-selection"
                "Click Cell QC map point = select cell and jump main GUI to its block"
                ];

            uialert(app.UIFigure, strjoin(msg, newline), "Keyboard Shortcuts", "Icon", "info");
        end

        function idx = categoryIndexFromKey(app, key)
            arguments
                app
                key (1,1) string
            end

            idx = [];
            if strlength(key) == 1 && ~isnan(str2double(key))
                candidate = str2double(key);
                if candidate >= 1 && candidate <= min(9, numel(app.Categories))
                    idx = candidate;
                    return
                end
            end

            for k = 1:numel(app.Categories)
                if strcmpi(char(key), char(string(app.Categories(k).Shortcut)))
                    idx = k;
                    return
                end
            end
        end

        function cycleDisplayMode(app)
            items = string(app.DisplayModeDropDown.Items);
            current = find(items == string(app.DisplayModeDropDown.Value), 1, 'first');
            if isempty(current)
                current = 1;
            end
            next = current + 1;
            if next > numel(items)
                next = 1;
            end
            app.DisplayModeDropDown.Value = char(items(next));
            app.onDisplaySettingsChanged();
        end

        function showSelectedCropFigure(app)
            if isempty(app.ActiveReviewTable) || isnan(app.SelectedGlobalRow)
                return
            end
            crop = app.composeCropDisplay(app.SelectedGlobalRow);
            fig = uifigure("Name", "Selected detection crop", "Position", [200 200 650 650]);
            grid = uigridlayout(fig, [2 1]);
            grid.RowHeight = {30, '1x'};
            uibutton(grid, "push", ...
                "Text", "Update coordinate by next click", ...
                "ButtonPushedFcn", @(src, event) app.armCoordinateUpdate());
            ax = uiaxes(grid);
            ax.Toolbar.Visible = "off";
            disableDefaultInteractivity(ax);
            if crop.IsValid
                if ndims(crop.Image) == 3
                    hImage = imshow(crop.Image, 'Parent', ax);
                elseif isempty(crop.Range)
                    hImage = imshow(crop.Image, [], 'Parent', ax);
                else
                    hImage = imshow(crop.Image, crop.Range, 'Parent', ax);
                end
                hImage.HitTest = 'on';
                hImage.PickableParts = 'all';
                hImage.ButtonDownFcn = @(src, event) app.onSelectedDetectionImageClicked(ax);
                ax.ButtonDownFcn = @(src, event) app.onSelectedDetectionImageClicked(ax);
                ax.HitTest = 'on';
                ax.PickableParts = 'all';
                hold(ax, 'on')
                if app.Settings.MarkerVisible && ~isempty(crop.Markers)
                    app.plotMarkers(ax, crop.Markers);
                end
                hold(ax, 'off')
                axis(ax, 'image')
            else
                text(ax, 0.5, 0.5, crop.Message, 'Units', 'normalized', 'HorizontalAlignment', 'center');
            end
            ax.XTick = [];
            ax.YTick = [];
        end

        function updateProgress(app)
            if isempty(app.ActiveReviewTable)
                app.updateStatus("No source loaded.");
                return
            end
            reviewed = sum(app.ActiveReviewTable.QCReviewed);
            total = height(app.ActiveReviewTable);
            dirtyText = "saved";
            if app.Dirty
                dirtyText = "dirty";
            end
            autosaveText = "never";
            if ~isnat(app.LastAutosaveTime)
                autosaveText = string(app.LastAutosaveTime);
            end
            msg = sprintf('Dataset %d/%d | %s | source %d | reviewed %d/%d | %s | last save %s', ...
                app.ActiveDatasetIndex, height(app.DatasetList), char(string(app.ActiveSource.ChannelName)), app.ActiveSourceIndex, reviewed, total, char(dirtyText), char(autosaveText));
            app.StatusLabel.Text = msg;
        end

        function updateStatus(app, message)
            arguments
                app
                message
            end

            if ~isempty(app.StatusLabel) && isvalid(app.StatusLabel)
                app.StatusLabel.Text = char(string(message));
            end
        end

        function handleCloseRequest(app, src, event)
            arguments
                app
                src
                event
            end

            if app.Dirty
                app.saveCurrentQC();
            end
            app.readSettingsFromUI();
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                app.Settings.WindowPosition = app.UIFigure.Position;
            end
            app.saveSettings();
            delete(app.UIFigure);
        end

        function refreshActiveSourceProgress(app)
            if isempty(app.ActiveReviewTable) || app.ActiveDatasetIndex < 1 || app.ActiveSourceIndex < 1
                return
            end
            sources = app.SourceListByDataset{app.ActiveDatasetIndex};
            source = sources(app.ActiveSourceIndex);
            source.NumRows = height(app.ActiveReviewTable);
            source.Reviewed = sum(app.ActiveReviewTable.QCReviewed);
            source.Good = sum(string(app.ActiveReviewTable.QCLabel) == "Good");
            source.Bad = sum(string(app.ActiveReviewTable.QCLabel) == "Bad");
            source.Uncertain = sum(string(app.ActiveReviewTable.QCLabel) == "Uncertain");
            if any(~isnat(app.ActiveReviewTable.QCTimestamp))
                source.LastReviewedTime = max(app.ActiveReviewTable.QCTimestamp(~isnat(app.ActiveReviewTable.QCTimestamp)));
            end
            sources(app.ActiveSourceIndex) = source;
            app.SourceListByDataset{app.ActiveDatasetIndex} = sources;
            app.ActiveSource = source;

            totalDetections = sum([sources.NumRows]);
            reviewed = sum([sources.Reviewed]);
            app.DatasetList.TotalDetections(app.ActiveDatasetIndex) = totalDetections;
            app.DatasetList.Reviewed(app.ActiveDatasetIndex) = reviewed;
            app.DatasetList.Unreviewed(app.ActiveDatasetIndex) = max(totalDetections - reviewed, 0);
            app.DatasetList.Good(app.ActiveDatasetIndex) = sum([sources.Good]);
            app.DatasetList.Bad(app.ActiveDatasetIndex) = sum([sources.Bad]);
            app.DatasetList.Uncertain(app.ActiveDatasetIndex) = sum([sources.Uncertain]);
            app.DatasetList.LastReviewedTime(app.ActiveDatasetIndex) = app.maxSourceTime(sources);
        end

        function updateDatasetTable(app)
            if isempty(app.DatasetTable) || ~isvalid(app.DatasetTable)
                return
            end

            app.DatasetTable.Data = app.datasetDisplayTable();
            app.applyDatasetTableActiveRowStyle();
        end

        function applyDatasetTableActiveRowStyle(app)
            if isempty(app.DatasetTable) || ~isvalid(app.DatasetTable)
                return
            end

            removeStyle(app.DatasetTable);
            if app.ActiveDatasetIndex < 1 || app.ActiveDatasetIndex > height(app.DatasetList)
                return
            end

            addStyle(app.DatasetTable, app.DatasetActiveRowStyle, "row", app.ActiveDatasetIndex);
        end

        function displayTbl = datasetDisplayTable(app)
            if isempty(app.DatasetList) || height(app.DatasetList) == 0
                displayTbl = table(string.empty(0,1), string.empty(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), string.empty(0,1), ...
                    'VariableNames', {'Name', 'Channels', 'Total', 'Reviewed', 'Unreviewed', 'Good', 'Bad', 'Uncertain', 'Status'});
                return
            end
            displayTbl = table(app.DatasetList.Name, app.DatasetList.Channels, app.DatasetList.TotalDetections, app.DatasetList.Reviewed, app.DatasetList.Unreviewed, ...
                app.DatasetList.Good, app.DatasetList.Bad, app.DatasetList.Uncertain, app.DatasetList.Status, ...
                'VariableNames', {'Name', 'Channels', 'Total', 'Reviewed', 'Unreviewed', 'Good', 'Bad', 'Uncertain', 'Status'});
        end

        function loadSettings(app)
            defaults = app.defaultSettings();
            prefSettings = struct();
            matSettings = struct();
            havePref = false;
            haveMat = false;

            if ispref(app.SettingsGroup, app.SettingsPrefKey)
                stored = getpref(app.SettingsGroup, app.SettingsPrefKey);
                if isstruct(stored)
                    prefSettings = app.mergeSettings(defaults, stored);
                    havePref = true;
                end
            end

            matPath = app.settingsMatPath();
            if isfile(matPath)
                data = load(matPath, 'settings');
                if isfield(data, 'settings') && isstruct(data.settings)
                    matSettings = app.mergeSettings(defaults, data.settings);
                    haveMat = true;
                end
            end

            if havePref && haveMat
                if app.settingsSavedAt(matSettings) > app.settingsSavedAt(prefSettings)
                    settings = matSettings;
                else
                    settings = prefSettings;
                end
            elseif havePref
                settings = prefSettings;
            elseif haveMat
                settings = matSettings;
            else
                settings = defaults;
            end

            settings = app.mergeSettings(defaults, settings);
            settings.Categories = app.sanitizeCategories(settings.Categories);
            app.Settings = settings;
            setappdata(0, app.SettingsAppDataKey, app.Settings);
        end

        function saveSettings(app)
            if isempty(app.Settings)
                return
            end

            app.Settings.SettingsSavedAt = now;
            setappdata(0, app.SettingsAppDataKey, app.Settings);
            settings = app.Settings; %#ok<NASGU>

            try
                save(app.settingsMatPath(), 'settings');
            catch ME
                warning('CellLocalizationQCApp:SettingsMatSaveFailed', 'Settings MAT file was not saved: %s', ME.message);
            end

            try
                setpref(app.SettingsGroup, app.SettingsPrefKey, app.Settings);
            catch ME
                warning('CellLocalizationQCApp:SettingsPrefSaveFailed', 'MAT settings were saved, but MATLAB preferences were not saved: %s', ME.message);
            end
        end

        function savedAt = settingsSavedAt(app, settings)
            arguments
                app
                settings struct
            end

            savedAt = 0;
            if isfield(settings, 'SettingsSavedAt') && isnumeric(settings.SettingsSavedAt) && isscalar(settings.SettingsSavedAt) && isfinite(settings.SettingsSavedAt)
                savedAt = double(settings.SettingsSavedAt);
            end
        end

        function readSettingsFromUI(app)
            if isempty(app.UIFigure) || ~isvalid(app.UIFigure)
                return
            end
            app.Settings.LastParentDirectory = string(strtrim(app.ParentDirEdit.Value));
            app.Settings.CropWidth = round(app.CropWidthSpinner.Value);
            app.Settings.CropHeight = round(app.CropHeightSpinner.Value);
            app.Settings.LinkedSquareCropMode = logical(app.LinkedSquareCheckBox.Value);
            app.Settings.CellsPerBlock = round(app.CellsPerBlockSpinner.Value);
            app.Settings.SortColumn = string(app.Sort1DropDown.Value);
            app.Settings.SortDirection = string(app.Sort1DirectionDropDown.Value);
            app.Settings.SecondarySortColumn = string(app.Sort2DropDown.Value);
            app.Settings.SecondarySortDirection = string(app.Sort2DirectionDropDown.Value);
            app.Settings.FilterMode = string(app.FilterDropDown.Value);
            app.Settings.DisplayMode = string(app.DisplayModeDropDown.Value);
            app.Settings.ContrastMode = string(app.ContrastModeDropDown.Value);
            app.Settings.MarkerVisible = logical(app.MarkerCheckBox.Value);
            app.Settings.AutoAdvanceAfterClassification = logical(app.AutoAdvanceCheckBox.Value);
            app.Settings.Categories = app.Categories;
            if app.ActiveDatasetIndex >= 1 && app.ActiveDatasetIndex <= height(app.DatasetList)
                app.Settings.LastActiveDataset = app.DatasetList.DatasetID(app.ActiveDatasetIndex);
            end
            if ~isempty(app.ActiveSource) && isfield(app.ActiveSource, 'CsvPath')
                app.Settings.LastActiveLocalizationSource = app.sourceIdentity(app.ActiveSource);
            end
            if ~isempty(app.FilteredOrder)
                app.Settings.LastBlockIndex = max(1, ceil(app.BlockStartIndex / app.Settings.CellsPerBlock));
            end
            app.Settings.WindowPosition = app.UIFigure.Position;
        end

        function defaults = defaultSettings(app)
            arguments
                app
            end

            defaults = struct();
            defaults.SettingsVersion = 2;
            defaults.SettingsSavedAt = 0;
            defaults.LastParentDirectory = "";
            defaults.ImagePattern = "*_proj.tif";
            defaults.LocalizationPattern = "*_locs.csv";
            defaults.ChannelMap = struct('Channel', {'ECM', 'PV'}, 'PageIndex', {1, 2});
            defaults.DefaultActiveChannel = "ECM";
            defaults.Categories = struct( ...
                'Name', {'Good', 'Bad', 'Uncertain', 'Ignore'}, ...
                'Code', {1, 2, 3, 4}, ...
                'Shortcut', {'g', 'b', 'u', 'i'}, ...
                'Color', {[0.20 0.65 0.20], [0.80 0.20 0.20], [0.75 0.55 0.15], [0.45 0.45 0.45]});
            defaults.CropWidth = 64;
            defaults.CropHeight = 64;
            defaults.LinkedSquareCropMode = true;
            defaults.CellsPerBlock = 20;
            defaults.SortColumn = "Original row order";
            defaults.SortDirection = "Ascending";
            defaults.SecondarySortColumn = "None";
            defaults.SecondarySortDirection = "Ascending";
            defaults.FilterMode = "Show all";
            defaults.DisplayMode = "Target channel only";
            defaults.ContrastMode = "Auto per crop";
            defaults.ManualContrastLimits = [NaN NaN];
            defaults.MarkerVisible = true;
            defaults.MarkerStyle = "crosshair";
            defaults.MarkerSize = 9;
            defaults.AutosaveEnabled = true;
            defaults.AutosaveFrequency = 1;
            defaults.IgnoreBorderObservations = true;
            defaults.ReviewerName = "";
            defaults.LastActiveDataset = "";
            defaults.LastActiveLocalizationSource = "";
            defaults.LastBlockIndex = 1;
            defaults.AutoAdvanceAfterClassification = true;
            defaults.AutoNextBlockBehavior = true;
            defaults.BulkClassificationRequiresConfirmation = false;
            defaults.ThresholdColumn = "rescore";
            defaults.ThresholdMode = "Above";
            defaults.ThresholdLower = 0;
            defaults.ThresholdUpper = 1;
            defaults.ThresholdClass = "Good";
            defaults.ThresholdScope = "All cells in active source";
            defaults.HistogramColumn = "rescore";
            defaults.WindowPosition = [100 100 1500 850];
        end

        function settings = mergeSettings(app, defaults, stored)
            arguments
                app
                defaults struct
                stored struct
            end

            settings = defaults;
            fields = fieldnames(stored);
            for k = 1:numel(fields)
                field = fields{k};
                if isfield(defaults, field)
                    if isstruct(defaults.(field)) && isstruct(stored.(field)) && isscalar(defaults.(field)) && isscalar(stored.(field))
                        settings.(field) = app.mergeSettings(defaults.(field), stored.(field));
                    else
                        settings.(field) = stored.(field);
                    end
                end
            end
        end

        function categories = sanitizeCategories(app, categories)
            arguments
                app
                categories struct
            end

            defaults = app.defaultSettings();
            if isempty(categories) || ~isstruct(categories)
                categories = defaults.Categories;
                return
            end

            requiredFields = {'Name', 'Code', 'Shortcut', 'Color'};
            for k = 1:numel(requiredFields)
                if ~isfield(categories, requiredFields{k})
                    categories = defaults.Categories;
                    return
                end
            end

            names = strings(numel(categories), 1);
            for k = 1:numel(categories)
                names(k) = strtrim(string(categories(k).Name));
            end
            valid = strlength(names) > 0;
            categories = categories(valid);
            names = names(valid);
            if isempty(categories) || numel(unique(lower(names))) ~= numel(names)
                categories = defaults.Categories;
                return
            end

            for k = 1:numel(categories)
                categories(k).Name = char(string(categories(k).Name));
                if isempty(categories(k).Code) || ~isnumeric(categories(k).Code)
                    categories(k).Code = k;
                end
                if strlength(string(categories(k).Shortcut)) == 0
                    categories(k).Shortcut = char(string(k));
                end
                if isempty(categories(k).Color) || ~isnumeric(categories(k).Color) || numel(categories(k).Color) ~= 3
                    categories(k).Color = [0.5 0.5 0.5];
                end
            end

            categories = app.ensureIgnoreCategory(categories);
        end

        function categories = ensureIgnoreCategory(app, categories)
            arguments
                app
                categories struct
            end

            names = string({categories.Name});
            names(ismissing(names)) = "";
            ignoreIdx = find(strcmpi(names, "Ignore"), 1, 'first');
            if ~isempty(ignoreIdx)
                categories(ignoreIdx).Name = 'Ignore';
                if isempty(categories(ignoreIdx).Code) || ~isnumeric(categories(ignoreIdx).Code) || ~isfinite(double(categories(ignoreIdx).Code))
                    categories(ignoreIdx).Code = app.nextCategoryCode(categories);
                end
                if strlength(string(categories(ignoreIdx).Shortcut)) == 0
                    categories(ignoreIdx).Shortcut = app.firstAvailableShortcut(categories, ignoreIdx);
                end
                if isempty(categories(ignoreIdx).Color) || ~isnumeric(categories(ignoreIdx).Color) || numel(categories(ignoreIdx).Color) ~= 3
                    categories(ignoreIdx).Color = [0.45 0.45 0.45];
                end
                return
            end

            ignoreCategory = struct( ...
                'Name', 'Ignore', ...
                'Code', app.nextCategoryCode(categories), ...
                'Shortcut', app.firstAvailableShortcut(categories, []), ...
                'Color', [0.45 0.45 0.45]);
            categories(end + 1) = ignoreCategory;
        end

        function code = nextCategoryCode(app, categories)
            arguments
                app
                categories struct
            end

            codes = zeros(numel(categories), 1);
            for k = 1:numel(categories)
                if isfield(categories, 'Code') && ~isempty(categories(k).Code) && isnumeric(categories(k).Code) && isfinite(double(categories(k).Code))
                    codes(k) = double(categories(k).Code);
                end
            end
            code = max([codes; 0]) + 1;
        end

        function shortcut = firstAvailableShortcut(app, categories, selfIndex)
            arguments
                app
                categories struct
                selfIndex = []
            end

            used = strings(0, 1);
            for k = 1:numel(categories)
                if ~isempty(selfIndex) && k == selfIndex
                    continue
                end
                if isfield(categories, 'Shortcut')
                    value = lower(strtrim(string(categories(k).Shortcut)));
                    if strlength(value) > 0
                        used(end + 1) = value; %#ok<AGROW>
                    end
                end
            end

            candidates = ["i", "0", "x", "semicolon"];
            shortcut = 'i';
            for k = 1:numel(candidates)
                if ~any(used == candidates(k))
                    shortcut = char(candidates(k));
                    return
                end
            end
        end

        function openFolderInSystemBrowser(app, folderPath)
            arguments
                app
                folderPath {mustBeTextScalar}
            end

            folderPath = char(string(folderPath));
            if ispc
                winopen(folderPath);
            elseif ismac
                system(sprintf('open "%s"', folderPath));
            else
                system(sprintf('xdg-open "%s" >/dev/null 2>&1 &', folderPath));
            end
        end

        function matPath = settingsMatPath(app)
            arguments
                app
            end

            matPath = fullfile(prefdir, 'CellLocalizationQCApp_Settings.mat');
        end

        function names = datasetVariableNames(app)
            arguments
                app
            end

            names = {'DatasetID', 'Name', 'Folder', 'ImagePath', 'Channels', 'NumSources', 'TotalDetections', 'Reviewed', 'Unreviewed', 'Good', 'Bad', 'Uncertain', 'Status', 'LastReviewedTime'};
        end

        function tbl = emptyDatasetTable(app)
            arguments
                app
            end

            tbl = table(string.empty(0,1), string.empty(0,1), string.empty(0,1), string.empty(0,1), string.empty(0,1), ...
                zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), string.empty(0,1), NaT(0,1), ...
                'VariableNames', app.datasetVariableNames());
        end

        function sources = emptySourceStruct(app)
            arguments
                app
            end

            sources = struct('DatasetID', {}, 'ImagePath', {}, 'CsvPath', {}, 'QCPath', {}, 'ChannelName', {}, 'PageIndex', {}, 'NumRows', {}, ...
                'HasRequiredColumns', {}, 'Status', {}, 'Reviewed', {}, 'Good', {}, 'Bad', {}, 'Uncertain', {}, 'LastReviewedTime', {});
        end

        function names = qcColumnNames(app)
            arguments
                app
            end

            names = ["QCLabel", "QCCode", "QCReviewed", "QCReviewer", "QCTimestamp", "QCNotes", "QCCropWidth", "QCCropHeight", ...
                "QCDatasetID", "QCChannel", "QCSourceCsv", "QCSourceRow", "QCImagePath", "QCVersion", "QCUniqueID", "QCOutOfBounds", "QCIncludesImageBorder", "QCWarning"];
        end

        function qcPath = qcPathForCsv(app, csvPath)
            arguments
                app
                csvPath
            end

            [folder, baseName, ~] = fileparts(char(csvPath));
            qcPath = string(fullfile(folder, [baseName '_QC.csv']));
        end

        function counts = readQCCounts(app, qcPath)
            arguments
                app
                qcPath
            end

            counts = struct('Reviewed', 0, 'Good', 0, 'Bad', 0, 'Uncertain', 0, 'LastReviewedTime', NaT);
            if ~isfile(qcPath)
                return
            end

            try
                tbl = readtable(char(qcPath), 'TextType', 'string', 'VariableNamingRule', 'preserve');
            catch
                return
            end
            names = string(tbl.Properties.VariableNames);
            if ismember("QCReviewed", names)
                reviewed = app.toLogical(tbl.QCReviewed);
            elseif ismember("QCLabel", names)
                reviewed = strlength(string(tbl.QCLabel)) > 0;
            else
                reviewed = false(height(tbl), 1);
            end
            counts.Reviewed = sum(reviewed);
            if ismember("QCLabel", names)
                labels = string(tbl.QCLabel);
                counts.Good = sum(labels == "Good");
                counts.Bad = sum(labels == "Bad");
                counts.Uncertain = sum(labels == "Uncertain");
            end
            if ismember("QCTimestamp", names)
                t = app.toDatetime(tbl.QCTimestamp);
                t = t(~isnat(t));
                if ~isempty(t)
                    counts.LastReviewedTime = max(t);
                end
            end
        end

        function values = toLogical(app, values)
            arguments
                app
                values
            end

            if islogical(values)
                return
            end
            if isnumeric(values)
                values = values ~= 0;
                return
            end
            values = lower(string(values));
            values = values == "true" | values == "1" | values == "yes";
        end

        function values = toDatetime(app, values)
            arguments
                app
                values
            end

            if isdatetime(values)
                return
            end
            str = string(values);
            values = NaT(size(str));
            valid = strlength(str) > 0 & ~ismissing(str);
            if ~any(valid)
                return
            end

            validStrings = str(valid);
            try
                parsed = datetime(validStrings, 'Format', 'default');
            catch
                parsed = NaT(size(validStrings));
                for k = 1:numel(validStrings)
                    try
                        parsed(k) = datetime(validStrings(k), 'Format', 'default');
                    catch
                        parsed(k) = NaT;
                    end
                end
            end
            values(valid) = parsed;
        end

        function rel = makeRelativePath(app, fullPath, parentDir)
            arguments
                app
                fullPath
                parentDir
            end

            fullPath = string(fullPath);
            parentDir = string(parentDir);
            rel = fullPath;
            if strlength(parentDir) == 0
                return
            end
            parentWithSep = parentDir;
            if ~endsWith(parentWithSep, filesep)
                parentWithSep = parentWithSep + filesep;
            end
            if startsWith(fullPath, parentWithSep, 'IgnoreCase', true)
                rel = extractAfter(fullPath, strlength(parentWithSep));
            end
        end

        function id = sourceIdentity(app, source)
            arguments
                app
                source struct
            end

            id = app.makeRelativePath(source.CsvPath, app.ParentDirectory);
        end

        function status = appendStatus(app, a, b)
            arguments
                app
                a
                b
            end

            a = string(a);
            b = string(b);
            if strlength(a) == 0
                status = b;
            elseif strlength(b) == 0
                status = a;
            else
                status = a + "; " + b;
            end
        end

        function text = joinSourceChannels(app, sources)
            arguments
                app
                sources struct
            end

            if isempty(sources)
                text = "";
                return
            end
            parts = strings(numel(sources), 1);
            for k = 1:numel(sources)
                parts(k) = string(sources(k).ChannelName) + string(sources(k).PageIndex);
            end
            text = strjoin(parts, ", ");
        end

        function t = maxSourceTime(app, sources)
            arguments
                app
                sources struct
            end

            t = NaT;
            if isempty(sources)
                return
            end
            times = NaT(numel(sources), 1);
            for k = 1:numel(sources)
                times(k) = sources(k).LastReviewedTime;
            end
            times = times(~isnat(times));
            if ~isempty(times)
                t = max(times);
            end
        end
    end
end
