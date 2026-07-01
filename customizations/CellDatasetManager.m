classdef CellDatasetManager < handle
% CELLDATASETMANAGER  Discover cell datasets and track their pipeline status.
%   A "dataset" is one source image (a TIFF, possibly multi-page) together
%   with every file the Cell* tools derive from it:
%       <base>.tif / <base>_proj.tif / <base>_resized.tif   (images)
%       <base>[_<channel><page>]_locs.csv                        (detections)
%       <base>[_<channel><page>]_locs_resized.csv                (resized coords)
%       <base>[_<channel><page>]_locs_QC.csv                     (QC review)
%   Each distinct (channel,page) localization stream is a "source" within the
%   dataset, so a two-page PNN/PV TIFF yields two sources under one dataset.
%
%   The "_locs" suffix above is the default; it is user-configurable (dashboard
%   "Locs suffix" field, persisted) so other naming conventions can be scanned.
%   See DEFAULT_LOCS_TOKEN / locsToken() and the scan() .LocsToken option.
%
%   The class works in two ways.
%
%   1) Headless API (callable from any function or script) ---------------
%
%       % Struct array, one element per dataset, with full per-source status:
%       datasets = CellDatasetManager.scan(parentDir);
%
%       % Flat one-row-per-dataset summary table (handy for tables/printing):
%       T = CellDatasetManager.statusTable(parentDir);
%
%   2) Dashboard GUI ----------------------------------------------------
%
%       CellDatasetManager;                 % open empty, browse + scan
%       CellDatasetManager(parentDir);      % open and scan parentDir
%
%   The GUI lists every dataset with its pipeline progress (Detected ->
%   Resolved -> Rescored -> Reviewed), shows a per-source breakdown for the
%   selected dataset, and launches CellDiscovery / CellNeighborResolution /
%   CellQualityControl pointed straight at that dataset's folder. The TIFF
%   preview panel can overlay each source's detected cell centres ("Cell
%   locations"), coloured either by a bright per-source tint or by each cell's
%   latest Stage-2 rescore [0-1] (turbo ramp; unscored cells grey).
%
%   Manifest files ------------------------------------------------------
%   The manifest itself lives in its own class, CellDatasetManifest, which is
%   the authoritative record of which files belong to a dataset and which
%   localization CSV is the active analysis file for each source (schema
%   "celldataset/2.0", sidecar "<base>.celldataset.json"). This dashboard is a
%   thin consumer: scan() delegates discovery + reconciliation to
%   CellDatasetManifest.discover() and projects each manifest onto the dataset
%   struct shown here. The "Set active locs..." button is the user-facing way to
%   re-point a source's active analysis file (CellDatasetManifest.setActiveLocs).
%   The Cell* GUIs record their own work directly through CellDatasetManifest.

    %% ===================================================================
    %  Constants
    %  ===================================================================
    properties (Constant)
        % Scale-bar fallback when a TIFF carries no physical resolution tag.
        % Matches the original training resolution noted in CLAUDE.md.
        DEFAULT_UM_PER_PIXEL = 0.645
    end

    %% ===================================================================
    %  GUI state (only used by the dashboard)
    %  ===================================================================
    properties (Access = private)
        ParentDirectory char = ''
        Datasets struct = struct([])
        SelectedDatasetIndex double = 0
        SelectedDatasetIndices double = []
        SelectedSourceRow double = 0

        UIFigure
        ParentDirEdit
        LocsTokenEdit
        BrowseButton
        ScanButton
        StatusLabel
        DatasetTable
        SourceTable
        DetailLabel
        DiscoveryButton
        ResolverButton
        QCButton
        OpenFolderButton
        OpenManifestButton
        SetActiveLocsButton
        SetActiveImageButton
        InitialScanTimer = []

        PagePanel
        PageContent
        PageViewDropDown
        ShowLocationsCheckBox
        LocationColorDropDown
        ShowLocations logical = false
        LocationColorMode char = 'Uniform'
        PreviewImagePath char = ''
        StatLabels struct = struct([])
    end

    %% ===================================================================
    %  Construction / GUI entry
    %  ===================================================================
    methods
        function obj = CellDatasetManager(parentDir)
            % Open the dashboard. Optionally pass a parent directory; the first
            % scan is DEFERRED to a one-shot timer (scheduleInitialScan) so the
            % constructor returns and the uifigure finishes rendering before any
            % heavy file scanning runs. Scanning a folder synchronously inside
            % the constructor wedged the figure infrastructure on large trees.
            obj.buildUI();
            obj.loadPreferences();
            if nargin >= 1 && ~isempty(parentDir) && isfolder(char(parentDir))
                obj.ParentDirEdit.Value = char(parentDir);
                obj.ParentDirectory    = char(parentDir);
                obj.StatusLabel.Text   = 'Opening... the initial scan will start in a moment.';
                obj.scheduleInitialScan();
            end
        end
    end

    %% ===================================================================
    %  Headless API  (no GUI required)
    %  ===================================================================
    methods (Static)

        function datasets = scan(parentDir, opts)
            % Discover every dataset under parentDir and return a struct array
            % describing each one and its per-source pipeline status. This is a
            % thin projection over CellDatasetManifest.discover(): the manifest
            % class owns discovery, the schema, file resolution and the active
            % analysis-file pointer; here we just map each manifest to the
            % dashboard's dataset struct (with the live manifest object attached
            % as .ManifestObj so the dashboard can edit the active pointer).
            %
            %   opts (optional struct):
            %     .WriteManifest (default true)  write reconciled manifests back
            %     .Probe         (default true)  read CSV contents for counts /
            %                                     column presence and image page
            %                                     counts; false = file-existence
            %                                     only (fast)
            %     .LocsToken     (default = CellDatasetManifest.locsToken())
            arguments
                parentDir
                opts struct = struct()
            end
            datasets = struct([]);
            mfs = CellDatasetManifest.discover(parentDir, opts);
            if isempty(mfs)
                return;
            end
            built = cell(numel(mfs), 1);
            for k = 1:numel(mfs)
                built{k} = mfs(k).toDatasetStruct(parentDir);
            end
            datasets = [built{:}];

            % Stable order: by dataset id (relative path).
            [~, order] = sort(lower({datasets.DatasetID}));
            datasets = datasets(order);
        end

        function T = statusTable(parentDir, opts)
            % One-row-per-dataset summary table. Same discovery as scan().
            arguments
                parentDir
                opts struct = struct()
            end
            datasets = CellDatasetManager.scan(parentDir, opts);
            n = numel(datasets);
            DatasetID = strings(n, 1);
            Folder    = strings(n, 1);
            Pages     = zeros(n, 1);
            Sources   = zeros(n, 1);
            Detected  = strings(n, 1);
            Resolved  = strings(n, 1);
            Rescored  = strings(n, 1);
            Reviewed  = strings(n, 1);
            Detections = zeros(n, 1);
            Status    = strings(n, 1);
            for k = 1:n
                d = datasets(k);
                DatasetID(k)  = string(d.DatasetID);
                Folder(k)     = string(d.Folder);
                Pages(k)      = d.PageCount;
                ns            = numel(d.Sources);
                Sources(k)    = ns;
                Detected(k)   = CellDatasetManager.frac(d.Sources, 'detection');
                Resolved(k)   = CellDatasetManager.frac(d.Sources, 'resolve');
                Rescored(k)   = CellDatasetManager.frac(d.Sources, 'rescore');
                Reviewed(k)   = CellDatasetManager.frac(d.Sources, 'qc');
                Detections(k) = d.TotalDetections;
                Status(k)     = string(d.Status);
            end
            T = table(DatasetID, Folder, Pages, Sources, Detections, ...
                Detected, Resolved, Rescored, Reviewed, Status);
        end

    end

    %% ===================================================================
    %  Small data helpers
    %  ===================================================================
    methods (Static, Access = private)

        function txt = frac(sources, stage)
            % "k/n" of sources past a stage, for the summary table.
            n = numel(sources);
            switch stage
                case 'detection', flags = [sources.Detected];
                case 'resolve',   flags = [sources.Resolved];
                case 'rescore',   flags = [sources.Rescored];
                case 'qc',        flags = [sources.Reviewed];
                otherwise,        flags = false(1, n);
            end
            txt = sprintf('%d/%d', sum(flags), n);
        end

    end

    %% ===================================================================
    %  Dashboard GUI
    %  ===================================================================
    methods (Access = private)

        function buildUI(obj)
            obj.UIFigure = uifigure('Name', 'Cell Dataset Manager', ...
                'Position', [80 80 1760 720]);
            obj.UIFigure.CloseRequestFcn = @(s,e) obj.onClosing();
            obj.UIFigure.DeleteFcn = @(s,e) obj.savePreferences();
            root = uigridlayout(obj.UIFigure, [3 1]);
            root.RowHeight = {'fit', '1x', 'fit'};
            root.ColumnWidth = {'1x'};

            % --- Toolbar ---------------------------------------------------
            tb = uigridlayout(root, [1 7]);
            tb.Layout.Row = 1;
            tb.ColumnWidth = {'fit', '1x', 'fit', 'fit', 'fit', 'fit', 120};
            tb.Padding = [4 4 4 4];

            uilabel(tb, 'Text', 'Parent directory:', 'HorizontalAlignment', 'right');
            obj.ParentDirEdit = uieditfield(tb, 'text', ...
                'ValueChangedFcn', @(s,e) obj.onScan());
            obj.BrowseButton = uibutton(tb, 'Text', 'Browse...', ...
                'ButtonPushedFcn', @(s,e) obj.onBrowse());
            obj.ScanButton = uibutton(tb, 'Text', 'Scan', ...
                'ButtonPushedFcn', @(s,e) obj.onScan());
            CellToolkit.setTooltip(obj.ScanButton, ...
                'Recursively find datasets and refresh their pipeline status.');
            obj.OpenFolderButton = uibutton(tb, 'Text', 'Open folder', ...
                'ButtonPushedFcn', @(s,e) obj.onOpenFolder());

            uilabel(tb, 'Text', 'Locs suffix:', 'HorizontalAlignment', 'right');
            obj.LocsTokenEdit = uieditfield(tb, 'text', ...
                'Value', CellDatasetManifest.locsToken(), ...
                'ValueChangedFcn', @(s,e) obj.onLocsTokenChanged());
            CellToolkit.setTooltip(obj.LocsTokenEdit, ...
                ['Filename suffix that marks a localization CSV (default ' ...
                 '"_locs"). The stem before it gives the dataset base and ' ...
                 'optional <channel><page>; a trailing "_resized" still ' ...
                 'denotes resized coordinates. Changing it re-scans and ' ...
                 'updates all dataset summaries and stats.']);

            % --- Content split: left (datasets + detail) | right (pages) -
            contentSplit = uigridlayout(root, [1 2]);
            contentSplit.Layout.Row = 2;
            contentSplit.ColumnWidth = {'1x', 560};
            contentSplit.ColumnSpacing = 6;
            contentSplit.Padding = [4 0 4 0];

            % Left column: datasets (top) + selected-dataset detail (bottom).
            main = uigridlayout(contentSplit, [2 1]);
            main.Layout.Column = 1;
            main.RowHeight = {'3x', 250};
            main.Padding = [0 0 0 0];

            leftPanel = uipanel(main, 'Title', 'Datasets');
            lg = uigridlayout(leftPanel, [2 1]);
            lg.RowHeight = {'fit', '1x'};
            lg.RowSpacing = 6;

            % Cumulative progress across all discovered datasets.
            obj.buildSummaryBar(lg);

            obj.DatasetTable = uitable(lg, ...
                'ColumnName', {'Name', 'Pages', 'Sources', 'Detections', ...
                               'Detection', 'Nbr resolution', 'Rescoring', 'QC review', 'Status'}, ...
                'ColumnEditable', false(1, 9), ...
                'ColumnSortable', true(1, 9), ...
                'CellSelectionCallback', @(s,e) obj.onDatasetSelected(e));
            obj.DatasetTable.Layout.Row = 2;
            try
                obj.DatasetTable.ColumnRearrangeable = true;
            catch
            end

            detailPanel = uipanel(main, 'Title', 'Selected dataset');
            rg = uigridlayout(detailPanel, [3 1]);
            rg.RowHeight = {'fit', '1x', 'fit'};

            obj.DetailLabel = uilabel(rg, 'Text', 'Select a dataset.', ...
                'VerticalAlignment', 'top', 'WordWrap', 'on');
            obj.DetailLabel.Layout.Row = 1;

            obj.SourceTable = uitable(rg, ...
                'ColumnName', {'Source', 'Page', 'Detections', 'Resized', ...
                               'Resolved', 'Rescored', 'QC', 'Good', 'Bad'}, ...
                'ColumnEditable', false(1, 9), ...
                'ColumnSortable', true(1, 9), ...
                'CellSelectionCallback', @(s,e) obj.onSourceSelected(e));
            try
                obj.SourceTable.ColumnRearrangeable = true;
            catch
            end
            obj.SourceTable.Layout.Row = 2;

            launch = uigridlayout(rg, [1 6]);
            launch.Layout.Row = 3;
            obj.DiscoveryButton = uibutton(launch, 'Text', 'Detect cells...', ...
                'ButtonPushedFcn', @(s,e) obj.onLaunchDiscovery());
            CellToolkit.setTooltip(obj.DiscoveryButton, ...
                ['Open CellDiscovery pointed at the selected dataset''s folder, ' ...
                 'or the parent directory when none is selected.']);
            obj.ResolverButton = uibutton(launch, 'Text', 'Resolve neighbors...', ...
                'ButtonPushedFcn', @(s,e) obj.onLaunchResolver());
            CellToolkit.setTooltip(obj.ResolverButton, ...
                ['Open CellNeighborResolution on the selected dataset''s folder ' ...
                 '(loads the selected source), or the parent directory when none is selected.']);
            obj.QCButton = uibutton(launch, 'Text', 'QC review...', ...
                'ButtonPushedFcn', @(s,e) obj.onLaunchQC());
            CellToolkit.setTooltip(obj.QCButton, ...
                ['Open CellQualityControl on the selected dataset''s folder, ' ...
                 'or the parent directory when none is selected.']);
            obj.SetActiveLocsButton = uibutton(launch, 'Text', 'Set active locs...', ...
                'ButtonPushedFcn', @(s,e) obj.onSetActiveLocs(), 'Enable', false);
            CellToolkit.setTooltip(obj.SetActiveLocsButton, ...
                ['Choose which localization CSV is the active analysis file for the ' ...
                 'selected source. Every Cell* tool reads/writes the file recorded ' ...
                 'here (CellDatasetManifest.activeLocs).']);
            obj.SetActiveImageButton = uibutton(launch, 'Text', 'Set active image...', ...
                'ButtonPushedFcn', @(s,e) obj.onSetActiveImage(), 'Enable', false);
            CellToolkit.setTooltip(obj.SetActiveImageButton, ...
                ['Choose which image file is the active analysis image for the ' ...
                 'selected dataset. Disambiguates multi-variant datasets (raw, ' ...
                 'projection, resized) and is recorded in the manifest so every ' ...
                 'Cell* tool opens the same image (CellDatasetManifest.activeImage).']);
            obj.OpenManifestButton = uibutton(launch, 'Text', 'Open manifest', ...
                'ButtonPushedFcn', @(s,e) obj.onOpenManifest(), 'Enable', false);

            % --- Right column: TIFF page preview ---------------------------
            obj.PagePanel = uipanel(contentSplit, 'Title', 'TIFF pages');
            obj.PagePanel.Layout.Column = 2;
            pageGrid = uigridlayout(obj.PagePanel, [2 1]);
            pageGrid.RowHeight = {'fit', '1x'};
            pageGrid.RowSpacing = 4;
            pageGrid.Padding = [4 4 4 4];

            pageToolbar = uigridlayout(pageGrid, [1 5]);
            pageToolbar.Layout.Row = 1;
            pageToolbar.ColumnWidth = {'fit', 'fit', 'fit', 'fit', 'fit'};
            pageToolbar.ColumnSpacing = 6;
            pageToolbar.Padding = [0 0 0 0];
            uilabel(pageToolbar, 'Text', 'View:', 'HorizontalAlignment', 'right');
            obj.PageViewDropDown = uidropdown(pageToolbar, ...
                'Items', {'Individual pages', 'Colorized composite'}, ...
                'Value', 'Individual pages', ...
                'ValueChangedFcn', @(s,e) obj.onPageViewChanged());
            CellToolkit.setTooltip(obj.PageViewDropDown, ...
                ['Individual pages: every TIFF page as its own gray tile.  ' ...
                 'Colorized composite: pages tinted distinct colors and merged ' ...
                 'into one RGB image.']);
            obj.ShowLocationsCheckBox = uicheckbox(pageToolbar, ...
                'Text', 'Cell locations', 'Value', false, ...
                'ValueChangedFcn', @(s,e) obj.onOverlayOptionChanged());
            CellToolkit.setTooltip(obj.ShowLocationsCheckBox, ...
                ['Overlay detected cell centres (from each source''s locs CSV) ' ...
                 'as bright open circles. Individual pages show only that ' ...
                 'page''s source; the composite shows every source.']);
            uilabel(pageToolbar, 'Text', 'Colour:', 'HorizontalAlignment', 'right');
            obj.LocationColorDropDown = uidropdown(pageToolbar, ...
                'Items', {'Uniform', 'By page', 'By rescore', 'By class'}, 'Value', 'Uniform', ...
                'Enable', 'off', ...
                'ValueChangedFcn', @(s,e) obj.onOverlayOptionChanged());
            CellToolkit.setTooltip(obj.LocationColorDropDown, ...
                ['Uniform: one bright colour per source.  By page: all sources ' ...
                 'on the same TIFF page share one colour (matching the composite ' ...
                 'tints).  By rescore: colour each cell by its latest Stage-2 ' ...
                 'rescore [0-1] on a turbo ramp (unscored cells in grey). Falls ' ...
                 'back to uniform for sources with no rescore column.  By class: ' ...
                 'colour each cell by its integer class label; a legend shows each class.']);

            obj.PageContent = uipanel(pageGrid, 'BorderType', 'none');
            obj.PageContent.Layout.Row = 2;

            obj.refreshPagePreview();   % render the initial "select a dataset" hint

            % --- Status bar ------------------------------------------------
            obj.StatusLabel = uilabel(root, 'Text', 'Ready.', ...
                'HorizontalAlignment', 'left');
            obj.StatusLabel.Layout.Row = 3;
        end

        function buildSummaryBar(obj, parent)
            % A row of cumulative "stat cards" summarising progress across all
            % discovered datasets. Values are filled in by refreshSummary().
            statBar = uigridlayout(parent, [1 7]);
            statBar.Layout.Row = 1;
            statBar.RowHeight = {'fit'};   % so the 'fit' parent row sizes to the cards
            statBar.Padding = [4 2 4 2];
            statBar.ColumnSpacing = 8;
            obj.StatLabels = struct( ...
                'Datasets',   CellDatasetManager.makeStat(statBar, 'Datasets'), ...
                'Sources',    CellDatasetManager.makeStat(statBar, 'Sources'), ...
                'Detections', CellDatasetManager.makeStat(statBar, 'Detections'), ...
                'Detected',   CellDatasetManager.makeStat(statBar, 'Detected'), ...
                'Resolved',   CellDatasetManager.makeStat(statBar, 'Resolved'), ...
                'Rescored',   CellDatasetManager.makeStat(statBar, 'Rescored'), ...
                'Reviewed',   CellDatasetManager.makeStat(statBar, 'Reviewed'));
        end

        function onBrowse(obj)
            start = obj.ParentDirEdit.Value;
            if ~isfolder(start), start = pwd; end
            d = uigetdir(start, 'Select parent directory');
            if isequal(d, 0), return; end
            obj.ParentDirEdit.Value = d;
            obj.onScan();
        end

        function onScan(obj)
            parentDir = strtrim(obj.ParentDirEdit.Value);
            if isempty(parentDir) || ~isfolder(parentDir)
                obj.StatusLabel.Text = 'Enter a valid parent directory.';
                return;
            end
            obj.ParentDirectory = parentDir;
            obj.rescan(false);
        end

        function onLocsTokenChanged(obj)
            % Persist the localization-CSV suffix and re-derive every dataset
            % summary/stat from it. Blank input restores the default token.
            tok = strtrim(char(obj.LocsTokenEdit.Value));
            if isempty(tok)
                tok = CellDatasetManifest.DEFAULT_LOCS_TOKEN;
            end
            obj.LocsTokenEdit.Value = tok;
            try
                setpref('CellDatasetManager', 'locsToken', tok);
            catch
            end
            % rescan() reads the token via fillOpts -> locsToken(); preserve
            % the selected dataset where the new token still discovers it.
            obj.rescan(true);
        end

        function rescan(obj, preserveSelection)
            % Re-scan obj.ParentDirectory and refresh the dashboard. Used by
            % the Scan button (preserveSelection=false, clears selection) and
            % by the auto-refresh that fires when a launched Cell* GUI closes
            % (preserveSelection=true, so the dataset the user was working on
            % stays selected after its stage status is re-derived from files).
            if nargin < 2, preserveSelection = false; end
            parentDir = obj.ParentDirectory;
            if isempty(parentDir) || ~isfolder(parentDir)
                obj.StatusLabel.Text = 'Enter a valid parent directory.';
                return;
            end

            prevID = '';
            if preserveSelection
                d = obj.selectedDataset();
                if ~isempty(d), prevID = char(d.DatasetID); end
            end

            obj.StatusLabel.Text = 'Scanning...';
            dlg = obj.openScanProgressDlg();
            progFn = @(k, n, base) obj.onScanProgress(dlg, k, n, base);
            try
                obj.Datasets = CellDatasetManager.scan(parentDir, ...
                    struct('Progress', progFn));
            catch ME
                obj.closeScanProgressDlg(dlg);
                if strcmp(ME.identifier, 'CellDatasetManager:scanCancelled')
                    obj.StatusLabel.Text = 'Scan cancelled.';
                else
                    obj.StatusLabel.Text = ['Scan failed: ' ME.message];
                end
                return;
            end
            obj.closeScanProgressDlg(dlg);

            obj.SelectedDatasetIndex = 0;
            if ~isempty(prevID)
                for k = 1:numel(obj.Datasets)
                    if strcmp(char(obj.Datasets(k).DatasetID), prevID)
                        obj.SelectedDatasetIndex = k;
                        break;
                    end
                end
            end
            obj.refreshDatasetTable();
            obj.refreshSummary();
            obj.refreshDetail();
            obj.syncDatasetTableSelection();
            obj.StatusLabel.Text = sprintf('%d dataset(s) under %s', ...
                numel(obj.Datasets), parentDir);
        end

        function scheduleInitialScan(obj)
            % Defer the first scan to a one-shot timer so the constructor
            % returns and the uifigure finishes rendering (and becomes
            % interactive) before any heavy file scanning runs.
            try
                obj.cleanupInitialScanTimer();
                obj.InitialScanTimer = timer( ...
                    'StartDelay', 0.25, 'ExecutionMode', 'singleShot', ...
                    'TimerFcn', @(~,~) obj.runDeferredScan());
                start(obj.InitialScanTimer);
            catch
                % Timers unavailable: fall back to an immediate scan.
                obj.onScan();
            end
        end

        function runDeferredScan(obj)
            % One-shot timer target: run the initial scan once the window is up.
            obj.cleanupInitialScanTimer();
            if ~isempty(obj.UIFigure) && isvalid(obj.UIFigure)
                obj.onScan();
            end
        end

        function cleanupInitialScanTimer(obj)
            t = obj.InitialScanTimer;
            obj.InitialScanTimer = [];
            if ~isempty(t) && isa(t, 'timer') && isvalid(t)
                try
                    stop(t);
                    delete(t);
                catch
                end
            end
        end

        function dlg = openScanProgressDlg(obj)
            % A cancelable progress dialog for the scan. Returns [] if one
            % cannot be created (e.g. the figure is not ready), in which case
            % the scan still runs without visible progress.
            try
                dlg = uiprogressdlg(obj.UIFigure, 'Title', 'Scanning datasets', ...
                    'Message', 'Finding datasets...', 'Indeterminate', 'on', ...
                    'Cancelable', 'on');
            catch
                dlg = [];
            end
        end

        function onScanProgress(~, dlg, k, n, base)
            % Progress callback passed to CellDatasetManifest.discover. Updates
            % the dialog and throws to cancel when the user clicks Cancel.
            if isempty(dlg) || ~isvalid(dlg)
                return;
            end
            if dlg.CancelRequested
                error('CellDatasetManager:scanCancelled', 'Scan cancelled by user.');
            end
            dlg.Indeterminate = 'off';
            if n > 0
                dlg.Value = max(0, min(1, k / n));
            end
            [~, shortName] = fileparts(char(base));
            dlg.Message = sprintf('Scanning %d of %d:  %s', k, n, shortName);
            drawnow limitrate;
        end

        function closeScanProgressDlg(~, dlg)
            if ~isempty(dlg) && isvalid(dlg)
                try
                    close(dlg);
                catch
                end
            end
        end

        function syncDatasetTableSelection(obj)
            % Reflect SelectedDatasetIndex in the dataset table's row
            % highlight after a programmatic re-scan. Guarded: programmatic
            % uitable selection is not supported in every MATLAB release.
            try
                if obj.SelectedDatasetIndex >= 1
                    obj.DatasetTable.Selection = obj.SelectedDatasetIndex;
                else
                    obj.DatasetTable.Selection = [];
                end
            catch
            end
        end

        function attachRefreshOnClose(obj, app)
            % Re-scan the dashboard when a launched Cell* GUI window closes,
            % so stage status (detection / resolution / rescoring / QC)
            % reflects the work just done without a manual re-scan. The
            % launched app attaches the listener to its own (private) figure
            % via addCloseListener, so its encapsulation and existing
            % close/cleanup callbacks are left untouched.
            try
                if ~isempty(app) && ismethod(app, 'addCloseListener')
                    app.addCloseListener(@() obj.onLaunchedAppClosed());
                end
            catch
            end
        end

        function onLaunchedAppClosed(obj)
            % Listener target for a launched Cell* GUI closing.
            if ~isempty(obj.UIFigure) && isvalid(obj.UIFigure)
                obj.rescan(true);
            end
        end

        function refreshDatasetTable(obj)
            n = numel(obj.Datasets);
            data = cell(n, 9);
            for k = 1:n
                d = obj.Datasets(k);
                data{k, 1} = d.Base;
                data{k, 2} = d.PageCount;
                data{k, 3} = numel(d.Sources);
                data{k, 4} = d.TotalDetections;
                data{k, 5} = char(CellDatasetManager.frac(d.Sources, 'detection'));
                data{k, 6} = char(CellDatasetManager.frac(d.Sources, 'resolve'));
                data{k, 7} = char(CellDatasetManager.frac(d.Sources, 'rescore'));
                data{k, 8} = char(CellDatasetManager.frac(d.Sources, 'qc'));
                data{k, 9} = d.Status;
            end
            obj.DatasetTable.Data = data;
        end

        function refreshSummary(obj)
            % Recompute cumulative progress across all datasets and update the
            % stat cards. Sources are the unit for the stage fractions, matching
            % the per-dataset "k/n" columns in the table.
            if isempty(obj.StatLabels) || isempty(fieldnames(obj.StatLabels))
                return;
            end
            ds = obj.Datasets;
            nDatasets = numel(ds);
            nSources = 0; nDet = 0; nRes = 0; nResc = 0; nRev = 0;
            nDetections = 0;
            for k = 1:nDatasets
                s = ds(k).Sources;
                ns = numel(s);
                nSources = nSources + ns;
                nDetections = nDetections + ds(k).TotalDetections;
                if ns > 0
                    nDet  = nDet  + sum([s.Detected]);
                    nRes  = nRes  + sum([s.Resolved]);
                    nResc = nResc + sum([s.Rescored]);
                    nRev  = nRev  + sum([s.Reviewed]);
                end
            end
            obj.StatLabels.Datasets.Text   = sprintf('%d', nDatasets);
            obj.StatLabels.Sources.Text    = sprintf('%d', nSources);
            obj.StatLabels.Detections.Text = CellDatasetManager.thousands(nDetections);
            obj.StatLabels.Detected.Text   = sprintf('%d/%d', nDet, nSources);
            obj.StatLabels.Resolved.Text   = sprintf('%d/%d', nRes, nSources);
            obj.StatLabels.Rescored.Text   = sprintf('%d/%d', nResc, nSources);
            obj.StatLabels.Reviewed.Text   = sprintf('%d/%d', nRev, nSources);
        end

        function onDatasetSelected(obj, e)
            if isempty(e.Indices)
                return;
            end
            obj.SelectedDatasetIndex = e.Indices(1, 1);
            obj.SelectedSourceRow = 0;
            obj.refreshDetail();
        end

        function onSourceSelected(obj, e)
            if isempty(e.Indices)
                return;
            end
            obj.SelectedSourceRow = e.Indices(1, 1);
        end

        function refreshDetail(obj)
            idx = obj.SelectedDatasetIndex;
            hasSel = idx >= 1 && idx <= numel(obj.Datasets);
            obj.setLaunchEnabled(hasSel);
            obj.refreshPagePreview();
            if ~hasSel
                obj.DetailLabel.Text = 'Select a dataset.';
                obj.SourceTable.Data = {};
                return;
            end
            d = obj.Datasets(idx);

            imgTxt = 'image: (none)';
            if ~isempty(d.ActiveImage)
                imgTxt = ['image: ' d.ActiveImage];
            elseif ~isempty(d.ImagePath)
                imgTxt = ['image: ' d.ImagePath];
            end
            manTxt = 'manifest: (not yet written)';
            if isfile(d.ManifestPath)
                manTxt = ['manifest: ' d.ManifestPath];
            end
            obj.DetailLabel.Text = sprintf('%s\n%s\n%s\nStatus: %s', ...
                d.Base, imgTxt, manTxt, d.Status);

            ns = numel(d.Sources);
            data = cell(ns, 9);
            for i = 1:ns
                s = d.Sources(i);
                data{i, 1} = char(CellDatasetManager.sourceLabel(s));
                data{i, 2} = CellDatasetManager.pageText(s.Page);
                data{i, 3} = s.NumDetections;
                data{i, 4} = CellDatasetManager.yn(s.HasResized);
                data{i, 5} = CellDatasetManager.yn(s.Resolved);
                data{i, 6} = CellDatasetManager.yn(s.Rescored);
                data{i, 7} = CellDatasetManager.ynCount(s.Reviewed, s.QcReviewed);
                data{i, 8} = s.QcGood;
                data{i, 9} = s.QcBad;
            end
            obj.SourceTable.Data = data;
        end

        function refreshPagePreview(obj)
            % Preview the selected dataset's image in the right column, either
            % as one gray tile per page or as a single colorized composite of
            % all pages (controlled by the 'View' dropdown). The image path is
            % cached so re-clicking the same dataset does not re-read the TIFF.
            if isempty(obj.PageContent) || ~isvalid(obj.PageContent)
                return;
            end
            d = obj.selectedDataset();
            imgPath = '';
            if ~isempty(d)
                if ~isempty(d.ActiveImage) && isfile(d.ActiveImage)
                    imgPath = d.ActiveImage;
                else
                    imgPath = d.ImagePath;
                end
            end

            % Nothing to render: show a hint (cheap, always refreshed).
            if isempty(imgPath) || ~isfile(imgPath)
                obj.PreviewImagePath = '';
                delete(obj.PageContent.Children);
                obj.PagePanel.Title = 'TIFF pages';
                msg = CellToolkit.ternary(isempty(d), ...
                    'Select a dataset to preview its TIFF pages.', ...
                    'No image file for this dataset.');
                uilabel(obj.PageContent, 'Text', msg, ...
                    'HorizontalAlignment', 'center', ...
                    'VerticalAlignment', 'center', 'WordWrap', 'on');
                return;
            end

            % Same image already displayed in the current mode: keep it.
            % (Switching modes invalidates this via onPageViewChanged.)
            if strcmp(imgPath, obj.PreviewImagePath)
                return;
            end
            obj.PreviewImagePath = imgPath;

            delete(obj.PageContent.Children);
            [~, nm, ext] = fileparts(imgPath);
            composite = strcmp(obj.PageViewDropDown.Value, 'Colorized composite');
            set(obj.UIFigure, 'Pointer', 'watch'); drawnow;
            try
                nPages = CellToolkit.countPages(imgPath);
                pixUm  = CellDatasetManager.pixelSizeUm(imgPath);
                t = tiledlayout(obj.PageContent, 'flow', ...
                    'Padding', 'compact', 'TileSpacing', 'compact');
                if composite
                    ax = nexttile(t);
                    obj.drawCompositeInto(ax, imgPath, nPages, pixUm, 1024, true);
                    modeTxt = 'composite';
                else
                    for k = 1:nPages
                        ax = nexttile(t);
                        obj.drawPageInto(ax, imgPath, k, nPages, pixUm, 1024, true);
                    end
                    modeTxt = sprintf('%d page(s)', nPages);
                end
                obj.PagePanel.Title = sprintf('TIFF pages - %s%s (%s)', ...
                    nm, ext, modeTxt);
            catch ME
                delete(obj.PageContent.Children);
                uilabel(obj.PageContent, 'Text', ...
                    ['Could not display pages: ' ME.message], ...
                    'HorizontalAlignment', 'center', ...
                    'VerticalAlignment', 'center', 'WordWrap', 'on');
            end
            set(obj.UIFigure, 'Pointer', 'arrow');
        end

        function onPageViewChanged(obj)
            % Toggle between individual pages and colorized composite. The
            % image is unchanged, so invalidate the path cache to force a redraw.
            obj.PreviewImagePath = '';
            obj.refreshPagePreview();
        end

        function onOverlayOptionChanged(obj)
            % React to the "Cell locations" checkbox / colour dropdown. The
            % image is unchanged, so invalidate the path cache to force a redraw
            % that adds, removes, or recolours the location overlay.
            obj.ShowLocations     = logical(obj.ShowLocationsCheckBox.Value);
            obj.LocationColorMode = char(obj.LocationColorDropDown.Value);
            if ~isempty(obj.LocationColorDropDown) && isvalid(obj.LocationColorDropDown)
                obj.LocationColorDropDown.Enable = ...
                    CellToolkit.ternary(obj.ShowLocations, 'on', 'off');
            end
            obj.PreviewImagePath = '';
            obj.refreshPagePreview();
        end

        function drawPageInto(obj, ax, imgPath, page, nPages, pixUm, maxDim, interactive)
            % Draw one TIFF page (gray colormap) into ax, with a scale bar. When
            % interactive, clicking opens the page full-size in its own figure.
            [img, dispUm] = CellDatasetManager.loadPageForDisplay( ...
                imgPath, page, nPages, pixUm, maxDim);
            if isempty(img)
                title(ax, sprintf('Page %d (unreadable)', page));
                axis(ax, 'off');
                return;
            end
            if size(img, 3) == 1
                h = imagesc(ax, img);
                colormap(ax, gray);
            else
                if ~isa(img, 'uint8')
                    img = im2double(img);
                end
                h = image(ax, img);
            end
            axis(ax, 'image');
            ax.XTick = [];
            ax.YTick = [];
            ax.Box = 'on';
            title(ax, sprintf('Page %d', page), 'FontWeight', 'normal');
            obj.overlayLocations(ax, page, false, ...
                CellDatasetManager.dispScale(pixUm, dispUm));
            CellDatasetManager.drawScaleBar(ax, dispUm);
            if interactive
                cb = @(s,e) obj.openImageFigure(imgPath, page, nPages, false, pixUm);
                h.ButtonDownFcn = cb;
                ax.ButtonDownFcn = cb;
                CellToolkit.setTooltip(ax, 'Click to open this page in its own window.');
            end
        end

        function drawCompositeInto(obj, ax, imgPath, nPages, pixUm, maxDim, interactive)
            % Draw the colorized composite of all pages into ax, with a page
            % colour key and a scale bar. When interactive, clicking opens the
            % composite full-size in its own figure.
            [rgb, used, dispUm, colors] = CellDatasetManager.buildComposite( ...
                imgPath, nPages, pixUm, maxDim);
            if isempty(rgb)
                title(ax, 'Composite (no readable pages)');
                axis(ax, 'off');
                return;
            end
            h = image(ax, rgb);
            axis(ax, 'image');
            ax.XTick = [];
            ax.YTick = [];
            ax.Box = 'on';
            title(ax, sprintf('Colorized composite (%d page(s))', nPages), ...
                'FontWeight', 'normal');
            idx = find(used);
            for j = 1:numel(idx)
                p = idx(j);
                text(ax, 0.015, 0.985 - (j-1)*0.06, sprintf('Page %d', p), ...
                    'Units', 'normalized', 'Color', colors(p, :), ...
                    'FontWeight', 'bold', 'VerticalAlignment', 'top', ...
                    'BackgroundColor', [0 0 0], 'Margin', 1, 'HitTest', 'off');
            end
            obj.overlayLocations(ax, 1, true, ...
                CellDatasetManager.dispScale(pixUm, dispUm));
            CellDatasetManager.drawScaleBar(ax, dispUm);
            if interactive
                cb = @(s,e) obj.openImageFigure(imgPath, 1, nPages, true, pixUm);
                h.ButtonDownFcn = cb;
                ax.ButtonDownFcn = cb;
                CellToolkit.setTooltip(ax, 'Click to open the composite in its own window.');
            end
        end

        function openImageFigure(obj, imgPath, page, nPages, isComposite, pixUm)
            % Open the clicked image full-size in its own classic figure (with
            % zoom/pan toolbars), redrawing at a higher resolution cap.
            [~, nm, ext] = fileparts(imgPath);
            if isComposite
                figName = sprintf('%s%s - colorized composite', nm, ext);
            else
                figName = sprintf('%s%s - page %d/%d', nm, ext, page, nPages);
            end
            f = figure('Name', figName, 'NumberTitle', 'off');
            ax = axes('Parent', f);
            set(f, 'Pointer', 'watch'); drawnow;
            try
                if isComposite
                    obj.drawCompositeInto(ax, imgPath, nPages, pixUm, 2048, false);
                else
                    obj.drawPageInto(ax, imgPath, page, nPages, pixUm, 4096, false);
                end
            catch ME
                title(ax, ['Could not open image: ' ME.message]);
            end
            set(f, 'Pointer', 'arrow');
        end

        function overlayLocations(obj, ax, page, isComposite, scale)
            % Overlay detected cell centres on a preview axes. In composite mode
            % every source is drawn; otherwise only the source(s) belonging to
            % `page`. `scale` maps full-resolution CSV coordinates onto the
            % displayed (subsampled) image: displayed = full * scale. Colour is
            % a single bright tint per source ('Uniform'), each cell's latest
            % Stage-2 rescore on a turbo ramp ('By rescore'), or each cell's
            % integer class label ('By class'; legend shows each class).
            if ~obj.ShowLocations
                return;
            end
            d = obj.selectedDataset();
            if isempty(d) || isempty(d.Sources)
                return;
            end
            if isempty(scale) || ~isfinite(scale) || scale <= 0
                scale = 1;
            end
            if isComposite
                srcs = d.Sources;
            else
                srcs = CellDatasetManager.sourcesForPage(d, page);
            end
            if isempty(srcs)
                return;
            end

            byRescore = strcmpi(obj.LocationColorMode, 'By rescore');
            byClass   = strcmpi(obj.LocationColorMode, 'By class');
            byPage    = strcmpi(obj.LocationColorMode, 'By page');
            palette   = CellDatasetManager.locationColors();
            wasHeld   = ishold(ax);
            hold(ax, 'on');
            anyRescore    = false;
            legendHandles = gobjects(0);
            legendLabels  = {};

            % Pre-compute page colour palette when in By page mode.
            pageClrs = [];
            if byPage
                nPages   = max(1, d.PageCount);
                pageClrs = CellDatasetManager.pageColors(nPages);
            end

            % For by-class: pre-read all sources to build a consistent class
            % palette before drawing (same class -> same colour across sources).
            allPts = cell(numel(srcs), 1);
            if byClass
                allClassIdx = [];
                for i = 1:numel(srcs)
                    csv = CellDatasetManager.overlayCsvFor(d, srcs(i));
                    allPts{i} = CellDatasetManager.readLocPoints(csv);
                    if allPts{i}.hasClass
                        allClassIdx = [allClassIdx; allPts{i}.classIdx(:)]; %#ok<AGROW>
                    end
                end
                uniqueClasses = unique(allClassIdx);
                classPalette  = CellDatasetManager.classColors(numel(uniqueClasses));
            end

            for i = 1:numel(srcs)
                s   = srcs(i);
                if byClass
                    pts = allPts{i};
                else
                    csv = CellDatasetManager.overlayCsvFor(d, s);
                    pts = CellDatasetManager.readLocPoints(csv);
                end
                if isempty(pts.x)
                    continue;
                end
                x = pts.x * scale;
                y = pts.y * scale;
                if byClass && pts.hasClass
                    for ci = 1:numel(uniqueClasses)
                        cls  = uniqueClasses(ci);
                        mask = pts.classIdx == cls;
                        if ~any(mask), continue; end
                        c    = classPalette(ci, :);
                        h    = scatter(ax, x(mask), y(mask), 16, c, '.', ...
                            'HitTest', 'off', 'PickableParts', 'none');
                        lbl  = sprintf('class %d', cls);
                        if ~any(strcmp(legendLabels, lbl))
                            legendHandles(end + 1) = h; %#ok<AGROW>
                            legendLabels{end + 1}  = lbl; %#ok<AGROW>
                        end
                    end
                elseif byClass
                    % CSV has no class column: fall back to uniform tint
                    c = palette(mod(i - 1, size(palette, 1)) + 1, :);
                    scatter(ax, x, y, 16, c, '.', ...
                        'HitTest', 'off', 'PickableParts', 'none');
                elseif byRescore && pts.hasRescore
                    rgb = CellDatasetManager.rescoreColors(pts.rescore);
                    scatter(ax, x, y, 16, rgb, '.', ...
                        'HitTest', 'off', 'PickableParts', 'none');
                    anyRescore = true;
                elseif byPage
                    pageNum = CellDatasetManager.pageVal(s.Page);
                    np = size(pageClrs, 1);
                    if isfinite(pageNum) && pageNum >= 1 && pageNum <= np
                        c = pageClrs(pageNum, :);
                    else
                        c = palette(1, :);
                        pageNum = NaN;
                    end
                    h   = scatter(ax, x, y, 16, c, '.', ...
                        'HitTest', 'off', 'PickableParts', 'none');
                    lbl = sprintf('Page %d', pageNum);
                    if isfinite(pageNum) && ~any(strcmp(legendLabels, lbl))
                        legendHandles(end + 1) = h; %#ok<AGROW>
                        legendLabels{end + 1}  = lbl; %#ok<AGROW>
                    end
                else
                    c = palette(mod(i - 1, size(palette, 1)) + 1, :);
                    h = scatter(ax, x, y, 16, c, '.', ...
                        'HitTest', 'off', 'PickableParts', 'none');
                    if numel(srcs) > 1
                        legendHandles(end + 1) = h; %#ok<AGROW>
                        legendLabels{end + 1}  = char(CellDatasetManager.sourceLabel(s)); %#ok<AGROW>
                    end
                end
            end

            if byRescore && anyRescore
                CellDatasetManager.drawRescoreColorbar(ax);
            elseif ~isempty(legendHandles)
                lg = legend(ax, legendHandles, legendLabels, ...
                    'Location', 'northeast', 'Interpreter', 'none', ...
                    'TextColor', 'w', 'Color', [0 0 0], 'FontSize', 8);
                lg.Box = 'off';
            end

            if ~wasHeld
                hold(ax, 'off');
            end
        end

        function setLaunchEnabled(obj, tf)
            % The GUI-launch buttons (Detect/Resolve/QC) are always enabled and
            % fall back to the parent directory when no dataset is selected.
            % "Open manifest", "Set active locs", and "Set active image" need a
            % selected dataset.
            en = CellToolkit.ternary(tf, 'on', 'off');
            if ~isempty(obj.OpenManifestButton) && isvalid(obj.OpenManifestButton)
                obj.OpenManifestButton.Enable = en;
            end
            if ~isempty(obj.SetActiveLocsButton) && isvalid(obj.SetActiveLocsButton)
                obj.SetActiveLocsButton.Enable = en;
            end
            if ~isempty(obj.SetActiveImageButton) && isvalid(obj.SetActiveImageButton)
                obj.SetActiveImageButton.Enable = en;
            end
        end

        function onSetActiveLocs(obj)
            % Re-point which localization CSV is the active analysis file for a
            % source (the user-facing override). Writes through the dataset's
            % live CellDatasetManifest so every other tool honors the choice.
            d = obj.selectedDataset();
            if isempty(d), return; end
            if ~isfield(d, 'ManifestObj') || isempty(d.ManifestObj) || ~isvalid(d.ManifestObj)
                uialert(obj.UIFigure, 'No manifest is available for this dataset.', ...
                    'Active locs');
                return;
            end
            srcs = d.Sources;
            if isempty(srcs)
                uialert(obj.UIFigure, ...
                    'This dataset has no localization sources yet.', 'Active locs');
                return;
            end

            % Choose the source: the selected source row, the only source, or
            % ask when several exist and none is selected.
            row = obj.SelectedSourceRow;
            if isempty(row) || row < 1 || row > numel(srcs)
                if isscalar(srcs)
                    row = 1;
                else
                    labels = arrayfun(@(s) char(CellDatasetManager.sourceLabel(s)), ...
                        srcs, 'UniformOutput', false);
                    [row, ok] = listdlg('PromptString', 'Select a source:', ...
                        'SelectionMode', 'single', 'ListString', labels, ...
                        'Name', 'Active locs', 'ListSize', [260 160]);
                    if ~ok, return; end
                end
            end
            s   = srcs(row);
            mf  = d.ManifestObj;
            key = s.Key;

            % Candidate analysis files for this source: the full-resolution and
            % resized CSVs that exist, plus a browse option for anything else.
            cands = {};
            for p = {s.CsvPath, s.CsvResizedPath}
                if ~isempty(p{1}) && isfile(p{1}) && ~any(strcmpi(cands, p{1}))
                    cands{end+1} = p{1}; %#ok<AGROW>
                end
            end
            browseLabel = 'Browse for another file...';
            curActive = mf.activeLocs(key);
            items = cell(numel(cands) + 1, 1);
            for i = 1:numel(cands)
                [~, nm, ext] = fileparts(cands{i});
                tag = '';
                if strcmpi(cands{i}, curActive), tag = '   (current)'; end
                items{i} = [nm ext tag];
            end
            items{end} = browseLabel;

            [sel, ok] = listdlg('PromptString', ...
                sprintf('Active analysis CSV for %s:', char(CellDatasetManager.sourceLabel(s))), ...
                'SelectionMode', 'single', 'ListString', items, ...
                'Name', 'Active locs', 'ListSize', [460 200]);
            if ~ok, return; end

            if sel <= numel(cands)
                chosen = cands{sel};
            else
                [fn, fp] = uigetfile({'*.csv', 'Localization CSV (*.csv)'}, ...
                    'Select the active analysis CSV', d.Folder);
                if isequal(fn, 0), return; end
                chosen = fullfile(fp, fn);
            end

            mf.setActiveLocs(key, chosen);
            if mf.save()
                obj.StatusLabel.Text = sprintf('Active locs for %s -> %s', ...
                    key, chosen);
            else
                obj.StatusLabel.Text = 'Could not write the manifest.';
            end
            obj.rescan(true);
        end

        function onSetActiveImage(obj)
            % Re-point which image file is the active analysis image for the
            % selected dataset. Writes through the live CellDatasetManifest so
            % every Cell* tool opens the same image.
            d = obj.selectedDataset();
            if isempty(d), return; end
            if ~isfield(d, 'ManifestObj') || isempty(d.ManifestObj) || ~isvalid(d.ManifestObj)
                uialert(obj.UIFigure, 'No manifest is available for this dataset.', ...
                    'Active image');
                return;
            end
            mf = d.ManifestObj;

            % Candidate images: all known variants that exist on disk.
            candPaths = {d.RawImage, d.ProjImage, d.PreprocImage};
            candLabels = {'Raw image', 'Projection image', 'Preprocessed/resized image'};
            cands = {};
            labels = {};
            for i = 1:numel(candPaths)
                p = candPaths{i};
                if ~isempty(p) && isfile(p) && ~any(strcmpi(cands, p))
                    cands{end+1} = p; %#ok<AGROW>
                    [~, nm, ext] = fileparts(p);
                    tag = '';
                    if strcmpi(p, d.ActiveImage), tag = '   (current)'; end
                    labels{end+1} = sprintf('%s: %s%s%s', candLabels{i}, nm, ext, tag); %#ok<AGROW>
                end
            end
            browseLabel = 'Browse for another file...';
            labels{end+1} = browseLabel;

            [sel, ok] = listdlg('PromptString', ...
                sprintf('Active analysis image for dataset "%s":', d.Base), ...
                'SelectionMode', 'single', 'ListString', labels, ...
                'Name', 'Active image', 'ListSize', [500 200]);
            if ~ok, return; end

            if sel <= numel(cands)
                chosen = cands{sel};
            else
                [fn, fp] = uigetfile( ...
                    {'*.tif;*.tiff', 'TIFF image (*.tif, *.tiff)'}, ...
                    'Select the active analysis image', d.Folder);
                if isequal(fn, 0), return; end
                chosen = fullfile(fp, fn);
            end

            mf.setActiveImage(chosen);
            if mf.save()
                obj.StatusLabel.Text = sprintf('Active image for "%s" -> %s', ...
                    d.Base, chosen);
            else
                obj.StatusLabel.Text = 'Could not write the manifest.';
            end
            obj.rescan(true);
        end

        function d = selectedDataset(obj)
            d = [];
            idx = obj.SelectedDatasetIndex;
            if idx >= 1 && idx <= numel(obj.Datasets)
                d = obj.Datasets(idx);
            end
        end

        function onOpenFolder(obj)
            d = obj.selectedDataset();
            if isempty(d)
                if ~isempty(obj.ParentDirectory)
                    CellToolkit.openFolderInSystemBrowser(obj.ParentDirectory);
                end
                return;
            end
            CellToolkit.openFolderInSystemBrowser(d.Folder);
        end

        function onOpenManifest(obj)
            d = obj.selectedDataset();
            if isempty(d), return; end
            if ~isfile(d.ManifestPath)
                uialert(obj.UIFigure, 'No manifest has been written for this dataset yet.', ...
                    'Manifest');
                return;
            end
            try
                open(d.ManifestPath);
            catch
                CellToolkit.openFolderInSystemBrowser(d.Folder);
            end
        end

        function folder = launchFolder(obj)
            % Folder to point a launched GUI at: the selected dataset's folder,
            % else the scanned parent directory. '' when neither is available.
            d = obj.selectedDataset();
            if ~isempty(d)
                folder = d.Folder;
            else
                folder = obj.ParentDirectory;
            end
        end

        function onLaunchDiscovery(obj)
            folder = obj.launchFolder();
            if isempty(folder) || ~isfolder(folder)
                obj.StatusLabel.Text = 'Select a dataset or set a parent directory first.';
                return;
            end
            try
                app = CellDiscovery();
                app.setSearchDir(folder, true);
                obj.attachRefreshOnClose(app);
            catch ME
                uialert(obj.UIFigure, ME.message, 'Could not open CellDiscovery');
            end
        end

        function onLaunchResolver(obj)
            folder = obj.launchFolder();
            if isempty(folder) || ~isfolder(folder)
                obj.StatusLabel.Text = 'Select a dataset or set a parent directory first.';
                return;
            end
            d = obj.selectedDataset();
            csv = '';
            if ~isempty(d)
                csv = obj.firstSourceCsv(d);
            end
            try
                app = CellNeighborResolution();
                app.openParent(folder, csv);
                obj.attachRefreshOnClose(app);
            catch ME
                uialert(obj.UIFigure, ME.message, 'Could not open CellNeighborResolution');
            end
        end

        function onLaunchQC(obj)
            folder = obj.launchFolder();
            if isempty(folder) || ~isfolder(folder)
                obj.StatusLabel.Text = 'Select a dataset or set a parent directory first.';
                return;
            end
            % The QC app scans this folder and identifies a dataset by its
            % image path relative to the folder. It scans projection images by
            % default (resized in Resized mode), so pass that image's name
            % to open focused on this dataset. Best effort: a non-match simply
            % leaves the QC app on its first dataset. With no dataset selected we
            % pass an empty id and let the QC app open on its first dataset.
            dsId = '';
            d = obj.selectedDataset();
            if ~isempty(d)
                img = '';
                for cand = {d.ProjImage, d.PreprocImage, d.RawImage}
                    if ~isempty(cand{1})
                        img = cand{1};
                        break;
                    end
                end
                if ~isempty(img)
                    dsId = CellToolkit.makeRelativePath(img, d.Folder);
                end
            end
            try
                app = CellQualityControl();
                app.openParent(folder, dsId);
                obj.attachRefreshOnClose(app);
            catch ME
                uialert(obj.UIFigure, ME.message, 'Could not open CellQualityControl');
            end
        end

        function csv = firstSourceCsv(obj, d)
            % CSV path of the currently selected source row, else the first
            % source with a plain locs CSV.
            csv = '';
            row = obj.SelectedSourceRow;
            if ~isempty(row) && row >= 1 && row <= numel(d.Sources)
                csv = d.Sources(row).CsvPath;
            end
            if isempty(csv)
                for i = 1:numel(d.Sources)
                    if ~isempty(d.Sources(i).CsvPath)
                        csv = d.Sources(i).CsvPath; break;
                    end
                end
            end
        end

        function loadPreferences(obj)
            % Load saved GUI preferences (figure position, page view mode, parent dir).
            group = 'CellDatasetManager';

            % Restore figure position and size
            if ispref(group, 'figurePosition')
                try
                    pos = getpref(group, 'figurePosition');
                    if isvector(pos) && numel(pos) == 4 && all(isfinite(pos)) && all(pos > 0)
                        obj.UIFigure.Position = pos;
                    end
                catch
                end
            end

            % Restore parent directory
            if ispref(group, 'parentDirectory')
                try
                    parentDir = char(getpref(group, 'parentDirectory'));
                    if strlength(parentDir) > 0 && isfolder(parentDir)
                        obj.ParentDirEdit.Value = parentDir;
                    end
                catch
                end
            end

            % Restore localization-CSV suffix
            if ~isempty(obj.LocsTokenEdit) && isvalid(obj.LocsTokenEdit)
                obj.LocsTokenEdit.Value = CellDatasetManifest.locsToken();
            end

            % Restore page view mode
            if ispref(group, 'pageViewMode')
                try
                    mode = char(getpref(group, 'pageViewMode'));
                    items = obj.PageViewDropDown.Items;
                    if any(strcmp(items, mode))
                        obj.PageViewDropDown.Value = mode;
                    end
                catch
                end
            end

            % Restore location-overlay options
            if ispref(group, 'showLocations')
                try
                    obj.ShowLocations = logical(getpref(group, 'showLocations'));
                catch
                end
            end
            if ispref(group, 'locationColorMode')
                try
                    mode = char(getpref(group, 'locationColorMode'));
                    if any(strcmp(obj.LocationColorDropDown.Items, mode))
                        obj.LocationColorMode = mode;
                    end
                catch
                end
            end
            if ~isempty(obj.ShowLocationsCheckBox) && isvalid(obj.ShowLocationsCheckBox)
                obj.ShowLocationsCheckBox.Value = obj.ShowLocations;
            end
            if ~isempty(obj.LocationColorDropDown) && isvalid(obj.LocationColorDropDown)
                obj.LocationColorDropDown.Value  = obj.LocationColorMode;
                obj.LocationColorDropDown.Enable = ...
                    CellToolkit.ternary(obj.ShowLocations, 'on', 'off');
            end
        end

        function savePreferences(obj)
            % Save GUI preferences (figure position, parent directory, page view mode).
            group = 'CellDatasetManager';
            try
                setpref(group, 'figurePosition', obj.UIFigure.Position);
            catch
            end
            try
                setpref(group, 'parentDirectory', char(obj.ParentDirEdit.Value));
            catch
            end
            try
                setpref(group, 'pageViewMode', char(obj.PageViewDropDown.Value));
            catch
            end
            try
                setpref(group, 'showLocations', logical(obj.ShowLocations));
                setpref(group, 'locationColorMode', char(obj.LocationColorMode));
            catch
            end
            try
                if ~isempty(obj.LocsTokenEdit) && isvalid(obj.LocsTokenEdit)
                    tok = strtrim(char(obj.LocsTokenEdit.Value));
                    if isempty(tok), tok = CellDatasetManifest.DEFAULT_LOCS_TOKEN; end
                    setpref(group, 'locsToken', tok);
                end
            catch
            end
        end

        function onClosing(obj)
            % Called when the figure is closing. Save preferences and delete.
            obj.cleanupInitialScanTimer();
            obj.savePreferences();
            delete(obj.UIFigure);
        end

        function delete(obj)
            % Destructor: ensure the deferred-scan timer and figure are gone.
            obj.cleanupInitialScanTimer();
            if ~isempty(obj.UIFigure) && isvalid(obj.UIFigure)
                try
                    delete(obj.UIFigure);
                catch
                end
            end
        end

    end

    methods (Static, Access = private)
        function lbl = makeStat(parent, caption)
            % One "stat card": a bold value over a small grey caption. Returns
            % the value label so refreshSummary() can update its text.
            cellGrid = uigridlayout(parent, [2 1]);
            cellGrid.RowHeight = {'fit', 'fit'};
            cellGrid.RowSpacing = 0;
            cellGrid.Padding = [0 0 0 0];
            lbl = uilabel(cellGrid, 'Text', '-', 'FontSize', 16, ...
                'FontWeight', 'bold', 'HorizontalAlignment', 'center');
            uilabel(cellGrid, 'Text', caption, 'FontSize', 10, ...
                'FontColor', [0.4 0.4 0.4], 'HorizontalAlignment', 'center');
        end

        function s = thousands(n)
            % Integer with thousands separators (e.g. 15432 -> "15,432").
            s = sprintf('%d', round(n));
            try
                s = regexprep(s, '\d{1,3}(?=(\d{3})+$)', '$0,');
            catch
            end
        end

        function um = pixelSizeUm(imgPath)
            % Micrometres-per-pixel from a TIFF's resolution tags, falling back
            % to DEFAULT_UM_PER_PIXEL when the file carries no physical scale.
            um = CellDatasetManager.DEFAULT_UM_PER_PIXEL;
            try
                info = imfinfo(char(imgPath));
                info = info(1);
                if isfield(info, 'XResolution') && ~isempty(info.XResolution) ...
                        && isfield(info, 'ResolutionUnit')
                    xr = double(info.XResolution);
                    if xr > 0
                        switch lower(char(string(info.ResolutionUnit)))
                            case 'centimeter'
                                um = 10000 / xr;   % 1e4 um per cm
                            case 'inch'
                                um = 25400 / xr;   % 25400 um per inch
                        end
                    end
                end
            catch
            end
        end

        function [img, dispUm] = loadPageForDisplay(imgPath, page, nPages, pixUm, maxDim)
            % Read a page and subsample it to <= maxDim on its longest side.
            % dispUm is the micrometres-per-pixel of the returned (subsampled)
            % image, so a scale bar drawn on it stays correct.
            dispUm = pixUm;
            try
                img = CellToolkit.readPage(imgPath, page, nPages);
            catch
                img = [];
            end
            if isempty(img)
                return;
            end
            mx = max(size(img, 1), size(img, 2));
            if mx > maxDim
                step = ceil(mx / maxDim);
                img = img(1:step:end, 1:step:end, :);
                dispUm = pixUm * step;
            end
        end

        function [rgb, used, dispUm, colors] = buildComposite(imgPath, nPages, pixUm, maxDim)
            % Merge every page into one additive-colour RGB image (each page
            % min-max stretched, mismatched sizes resized to the first, longest
            % side bounded to maxDim). Returns which pages contributed, the
            % displayed micrometres-per-pixel, and the per-page colours.
            colors = CellDatasetManager.pageColors(nPages);
            rgb = [];
            used = false(nPages, 1);
            dispUm = pixUm;
            targetSize = [];
            for p = 1:nPages
                try
                    g = CellToolkit.readPage(imgPath, p, nPages);
                catch
                    continue;
                end
                if isempty(g)
                    continue;
                end
                if size(g, 3) > 1
                    g = mean(double(g), 3);   % collapse a colour page to gray
                else
                    g = double(g);
                end
                lo = min(g(:)); hi = max(g(:));
                if hi > lo
                    g = (g - lo) / (hi - lo);
                else
                    g = zeros(size(g));
                end
                if isempty(targetSize)
                    origMax = max(size(g));
                    if origMax > maxDim
                        g = imresize(g, maxDim / origMax);
                    end
                    targetSize = size(g);
                    dispUm = pixUm * (origMax / max(targetSize));
                    rgb = zeros(targetSize(1), targetSize(2), 3);
                elseif ~isequal(size(g), targetSize)
                    g = imresize(g, targetSize);
                end
                c = colors(p, :);
                rgb(:,:,1) = rgb(:,:,1) + g * c(1);
                rgb(:,:,2) = rgb(:,:,2) + g * c(2);
                rgb(:,:,3) = rgb(:,:,3) + g * c(3);
                used(p) = true;
            end
            if ~isempty(rgb)
                rgb = min(max(rgb, 0), 1);
            end
        end

        function drawScaleBar(ax, umPerPixel)
            % Draw a scale bar in the bottom-right of ax, sized to a "nice" round
            % length, given the micrometres-per-pixel of the displayed image.
            % No-op when the scale is unknown or the image is too small.
            if isempty(umPerPixel) || ~isfinite(umPerPixel) || umPerPixel <= 0
                return;
            end
            xl = xlim(ax); yl = ylim(ax);
            W = diff(xl); H = diff(yl);
            if W <= 0 || H <= 0
                return;
            end
            barUm = CellDatasetManager.niceNumber(0.25 * W * umPerPixel);
            barPx = barUm / umPerPixel;
            if barPx > 0.9 * W
                return;   % even the smallest nice bar is too wide
            end
            margX = 0.05 * W; margY = 0.07 * H;
            x2 = xl(2) - margX;
            x1 = x2 - barPx;
            yB = yl(2) - margY;                 % near the bottom (image YDir is reverse)
            thick = max(0.02 * H, 1);
            rectangle(ax, 'Position', [x1, yB - thick, barPx, thick], ...
                'FaceColor', 'w', 'EdgeColor', 'k', 'LineWidth', 0.5, 'HitTest', 'off');
            text(ax, (x1 + x2) / 2, yB - thick - 0.01 * H, sprintf('%g \\mum', barUm), ...
                'Interpreter', 'tex', 'Color', 'w', ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
                'FontWeight', 'bold', 'FontSize', 9, ...
                'BackgroundColor', [0 0 0], 'Margin', 1, 'HitTest', 'off');
        end

        function v = niceNumber(target)
            % Largest of {1,2,5} x 10^k that is <= target (>= 1 unit minimum).
            if ~isfinite(target) || target <= 0
                v = 1;
                return;
            end
            p = 10 ^ floor(log10(target));
            f = target / p;
            if f >= 5
                m = 5;
            elseif f >= 2
                m = 2;
            else
                m = 1;
            end
            v = m * p;
        end

        function s = dispScale(pixUm, dispUm)
            % Factor mapping full-resolution image coordinates onto the
            % displayed (subsampled) image. The preview subsamples a page by an
            % integer step with dispUm = pixUm * step, so display = full / step
            % = full * (pixUm / dispUm). Defaults to 1 when the scale is unknown.
            s = 1;
            if ~isempty(pixUm) && ~isempty(dispUm) && isfinite(pixUm) ...
                    && isfinite(dispUm) && pixUm > 0 && dispUm > 0
                s = pixUm / dispUm;
            end
        end

        function srcs = sourcesForPage(d, page)
            % Sources whose TIFF page matches `page`. Falls back to page-less
            % ("default") sources when viewing page 1 of a single-page TIFF.
            srcs = d.Sources;
            if isempty(srcs)
                return;
            end
            pages = arrayfun(@(s) CellDatasetManager.pageVal(s.Page), srcs);
            mask  = pages == page;
            if ~any(mask) && page == 1
                mask = ~isfinite(pages);
            end
            srcs = srcs(mask);
        end

        function p = pageVal(page)
            % Numeric page value, NaN when absent.
            if isempty(page)
                p = NaN;
            else
                p = double(page);
            end
        end

        function csv = overlayCsvFor(d, s)
            % CSV whose coordinate space matches the displayed representative
            % image: the resized CSV when the resized image is being shown
            % and a resized file exists, otherwise the plain detection CSV
            % (which is what s.CsvPath already prefers).
            csv = s.CsvPath;
            if ~isempty(d.PreprocImage) && ~isempty(s.CsvResizedPath) ...
                    && strcmpi(d.ImagePath, d.PreprocImage)
                csv = s.CsvResizedPath;
            end
        end

        function pts = readLocPoints(csvPath)
            % Read cell centres from a localization CSV. Returns a struct with
            % column vectors x, y (NaN rows dropped), the matching rescore (when
            % present), hasRescore, the integer class index (when present), and
            % hasClass. Accepts X/Y or the resized Xp/Yp naming.
            pts = struct('x', [], 'y', [], 'rescore', [], 'hasRescore', false, ...
                         'classIdx', [], 'hasClass', false);
            csvPath = char(csvPath);
            if isempty(csvPath) || ~isfile(csvPath)
                return;
            end
            try
                tbl = readtable(csvPath, 'TextType', 'string', ...
                    'VariableNamingRule', 'preserve');
            catch
                return;
            end
            names = string(tbl.Properties.VariableNames);
            [x, okx] = CellDatasetManager.pickColumn(tbl, names, {'X', 'Xp'});
            [y, oky] = CellDatasetManager.pickColumn(tbl, names, {'Y', 'Yp'});
            if ~okx || ~oky
                return;
            end
            keep = isfinite(x) & isfinite(y);
            pts.x = x(keep);
            pts.y = y(keep);
            [r, okr] = CellDatasetManager.pickColumn(tbl, names, {'rescore'});
            if okr
                pts.hasRescore = true;
                pts.rescore    = r(keep);
            end
            [cl, okcl] = CellDatasetManager.pickColumn(tbl, names, {'class'});
            if okcl
                pts.hasClass  = true;
                pts.classIdx  = round(cl(keep));
            end
        end

        function [v, ok] = pickColumn(tbl, names, candidates)
            % First matching column (case-insensitive) as a double column
            % vector. ok is false when none of the candidate names is present.
            v = []; ok = false;
            for c = 1:numel(candidates)
                idx = find(strcmpi(names, candidates{c}), 1);
                if isempty(idx)
                    continue;
                end
                col = tbl.(char(names(idx)));
                if isnumeric(col) || islogical(col)
                    v = double(col(:));
                else
                    v = str2double(string(col(:)));
                end
                ok = true;
                return;
            end
        end

        function colors = locationColors()
            % Bright, high-visibility tints for location markers, ordered so the
            % common single-source case gets cyan (very readable on grayscale
            % pages and against the magenta/green composite tints).
            colors = [ ...
                0.00 1.00 1.00;   % cyan
                1.00 1.00 0.00;   % yellow
                1.00 0.30 1.00;   % pink
                0.20 1.00 0.20;   % bright green
                1.00 0.55 0.00;   % orange
                1.00 1.00 1.00];  % white
        end

        function colors = classColors(n)
            % Distinct colours for cell class labels. Ordered so class 0 gets
            % a warm orange and class 1 a cool sky-blue, which matches the
            % typical PNN (0) / PV (1) pairing used in this lab.
            base = [ ...
                1.00 0.55 0.10;   % orange  (class 0)
                0.20 0.75 1.00;   % sky blue (class 1)
                0.50 1.00 0.30;   % lime green
                0.90 0.30 0.90;   % violet
                1.00 0.85 0.10;   % gold
                0.30 1.00 0.85;   % teal
                1.00 0.40 0.50;   % rose
                0.80 0.80 0.80];  % light grey
            if n <= size(base, 1)
                colors = base(1:n, :);
            else
                colors = hsv(n);
            end
        end

        function cmap = rescoreColormap()
            % Colormap for rescore [0-1]: turbo when available, else jet.
            try
                cmap = turbo(256);
            catch
                cmap = jet(256);
            end
        end

        function rgb = rescoreColors(vals)
            % Per-point RGB for rescore values in [0-1] (clamped). Unscored
            % (non-finite) cells are drawn neutral grey so they read as
            % "not yet rescored" rather than low quality.
            cmap = CellDatasetManager.rescoreColormap();
            n    = size(cmap, 1);
            v    = double(vals(:));
            rgb  = repmat([0.6 0.6 0.6], numel(v), 1);
            fin  = isfinite(v);
            vv   = min(max(v(fin), 0), 1);
            idx  = round(vv * (n - 1)) + 1;
            rgb(fin, :) = cmap(idx, :);
        end

        function drawRescoreColorbar(ax)
            % Compact vertical rescore key (0 bottom -> 1 top) in data
            % coordinates at the top-right, clear of the bottom-right scale bar.
            % Mirrors drawScaleBar's HitTest-off, dark-backed styling.
            xl = xlim(ax); yl = ylim(ax);
            W = diff(xl); H = diff(yl);
            if W <= 0 || H <= 0
                return;
            end
            cmap = CellDatasetManager.rescoreColormap();
            nSeg = 64;
            rows = round(linspace(1, size(cmap, 1), nSeg));
            barCols = cmap(rows, :);
            barW = 0.025 * W;
            barH = 0.32 * H;
            margX = 0.04 * W; margY = 0.07 * H;
            x1 = xl(2) - margX - barW;
            yTop = yl(1) + margY;          % image YDir is reverse: yl(1) is top
            segH = barH / nSeg;
            for k = 1:nSeg
                c  = barCols(nSeg - k + 1, :);   % high rescore at the top
                yk = yTop + (k - 1) * segH;
                rectangle(ax, 'Position', [x1, yk, barW, segH + 0.5], ...
                    'FaceColor', c, 'EdgeColor', 'none', 'HitTest', 'off');
            end
            rectangle(ax, 'Position', [x1, yTop, barW, barH], ...
                'FaceColor', 'none', 'EdgeColor', 'w', 'LineWidth', 0.5, ...
                'HitTest', 'off');
            ticks = {'1', '0.5', '0'};
            fracs = [0, 0.5, 1];
            for k = 1:numel(ticks)
                yk = yTop + fracs(k) * barH;
                text(ax, x1 - 0.005 * W, yk, ticks{k}, 'Color', 'w', ...
                    'HorizontalAlignment', 'right', 'VerticalAlignment', 'middle', ...
                    'FontSize', 8, 'FontWeight', 'bold', ...
                    'BackgroundColor', [0 0 0], 'Margin', 1, 'HitTest', 'off');
            end
            text(ax, x1 + barW / 2, yTop - 0.015 * H, 'rescore', 'Color', 'w', ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
                'FontSize', 8, 'FontWeight', 'bold', ...
                'BackgroundColor', [0 0 0], 'Margin', 1, 'HitTest', 'off');
        end

        function colors = pageColors(n)
            % Distinct additive tints per page: white for a single page,
            % magenta/green for two, RGB for three, a six-colour set beyond,
            % then evenly spaced HSV hues for many-page stacks.
            switch n
                case 1
                    colors = [1 1 1];
                case 2
                    colors = [1 0 1; 0 1 0];
                otherwise
                    base = [1 0 0; 0 1 0; 0 0 1; 1 1 0; 1 0 1; 0 1 1];
                    if n <= size(base, 1)
                        colors = base(1:n, :);
                    else
                        colors = hsv(n);
                    end
            end
        end

        function t = yn(tf)
            t = CellToolkit.ternary(logical(tf), 'Yes', '-');
        end
        function t = ynCount(tf, n)
            if tf
                t = sprintf('Yes (%d)', n);
            else
                t = '-';
            end
        end
        function t = pageText(page)
            if isempty(page) || isnan(page)
                t = '-';
            else
                t = page;
            end
        end
        function s = sourceLabel(src)
            if ~isempty(src.Channel)
                s = src.Key;
            elseif isempty(src.Key) || strcmp(src.Key, 'default')
                s = 'default';
            else
                s = src.Key;
            end
        end
    end

end
