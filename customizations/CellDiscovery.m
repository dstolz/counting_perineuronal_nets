classdef CellDiscovery < handle
    % CELLDISCOVERY   Batch GUI for PNN/PV cell detection via predict.py.
    %   Open the GUI:
    %       CellDiscovery()          % open window (object managed internally)
    %       app = CellDiscovery();   % optionally retain the object handle
    %
    %   Features:
    %     - Recursive directory search with regex file filter
    %     - Detection model + optional rescoring model (Stage 2) selection
    %     - Multi-page TIFF support: process pages separately, with a
    %       per-page model mapping (e.g. page 1 = PNN model, page 2 = PV
    %       model). Single-page files use page 1's mapping row.
    %     - Optional image preprocessing applied before detection:
    %       morphological background subtraction (disk radius) and resize;
    %       optional bidirectional LSM artifact correction can also be run
    %       before detection, configured per page.
    %     - Optional post-processing applied after detection: snapToCellCentroid
    %       localization refinement, enabled per page (Snap column) with its own
    %       per-page parameters (Snap options... dialog). Adds non-destructive
    %       SNAP_X/SNAP_Y/SNAP_Shift/SNAP_Snapped columns to the result CSV and,
    %       when requested, overwrites X/Y with the snapped coordinates.
    %     - Pipeline order per page: detection (predict.py) -> snap
    %       (snapToCellCentroid) -> Stage-2 rescoring (score.py). Rescoring runs
    %       after snap so the scoring model crops patches centred on the snapped
    %       (refined) cell locations; the score lands in the 'rescore' column.
    %     - Full predict.py argument exposure (device, batch-size, threshold)
    %     - Real-time stdout/stderr streaming to the MATLAB Command Window
    %     - Stop button that kills the active Python subprocess
    %     - Per-file CSV output placed next to the source image:
    %         <image_stem>[_page<k>]_locs.csv
    %       When resizing is used, a second CSV in resized-image coordinates
    %       is also written: <image_stem>[_page<k>]_locs_resized.csv
    %     - Result figure with colormap, auto-contrast, scatter overlay,
    %       stats annotation; figure is reused across files. The raw page or
    %       the resized image may be shown (user-selectable).
    %     - Optional PNG export of the annotated result
    %     - Optional diagnostic mode: pauses after each page and opens a window
    %       showing the raw page, the preprocessed image the detector saw
    %       (LSM/background/resize), and — when Snap is enabled — the snap-input
    %       image with arrows from each original detection to its snapped point.
    %       Continue/Stop buttons resume or end the batch.
    %     - Ignore or Overwrite existing results
    %     - All user preferences persisted across MATLAB sessions
    %
    %   Requirements:
    %     - MATLAB R2014b+ with Java enabled (default)
    %     - Python with predict.py dependencies installed
    %     - predict.py must be locatable: either in the same folder as this
    %       file or one level up (e.g. when this file is in a subdirectory)
    %
    %   NOTE: If this file lives in a subdirectory of the repo (e.g.
    %   customizations/), add that subdirectory to the MATLAB path:
    %       addpath('customizations')

    %% ---- Constants -------------------------------------------------------
    properties (Constant, Access = private)
        COLORMAPS  = {'gray','hot','jet','parula','turbo','bone','copper','pink','hsv'}
        %DOT_COLORS = {'yellow','red','cyan','magenta','green','blue','white','black'}
        DOT_COLORS = {'parula','hot','jet','turbo','hsv','pink','white','yellow','red','cyan','magenta','green','blue','black'}
        PREF_GROUP = 'PNNBatchGUI'
        SKIP_LABEL = '(skip)'    % page-map detection model sentinel: do not process page
        NONE_LABEL = '(none)'    % page-map rescore model sentinel: no rescoring
    end

    %% ---- Instance properties ---------------------------------------------
    properties (Access = private)
        % --- GUI handles ---
        hFig
        hDirEdit
        hRegexEdit
        hFileCountLabel
        hFileList
        hPyEdit
        hDetList
        hUseRescore
        hRescoreLabel
        hRescoreList
        hDeviceEdit
        hBatchEdit
        hThrEdit
        hIgnoreRad
        hOverwriteRad
        hColormapPop
        hAutoContrast
        hSavePng
        hDiagnosticChk
        hDotColorPop
        hDotSizeEdit
        hStartBtn
        hStopBtn
        hProgressLabel
        hCondaExeEdit
        hCondaEdit
        hTestEnvBtn

        % --- Multi-page & preprocessing handles ---
        hPerPageChk             % enable per-page (multi-page TIFF) processing
        hPageTable              % editable page -> model / preprocessing mapping
        hAddPageBtn
        hDelPageBtn
        hPreprocGlobalChk       % use one set of preprocessing settings for all pages
        hGlobalBgEdit           % global background-subtraction radius
        hGlobalResizeEdit       % global resize factor
        hDisplayPreprocChk      % show resized image instead of raw page
        hLSMOptionsBtn          % edit advanced bidirectional LSM correction options
        hSnapOptionsBtn         % edit per-page snapToCellCentroid post-processing options
        hSaveLsmTif             % save final resized image as TIF alongside CSV
        pageTableSelRow = []    % last-selected page-table row (for Remove)

        % --- App state ---
        repoRoot
        detModels
        rescoreModels
        P                       % preferences struct (always accessed as obj.P)

        % --- Batch state ---
        timerObj      = []
        jProcess      = []
        jReader       = []
        stopRequested = false
        fileIdx       = 1
        jobQueue      = {}      % cell array of job structs (see buildJobs)
        allAbsFiles   = {}      % absolute paths from last search (listbox shows relative)
        tmpDir        = ''      % scratch dir for resized page images
        preprocCache  = []      % per-file cache of preprocessed pages: resized (detector input) + source-resolution (snap input); see ensurePreprocCache
    end

    %% ---- Public interface ------------------------------------------------
    methods (Access = public)

        function obj = CellDiscovery()
            % Constructor — builds the GUI (or raises an existing window).
            %   obj = CellDiscovery()
            %
            %   Call without capturing output — the GUI manages its own lifetime:
            %       CellDiscovery()          % recommended
            %       app = CellDiscovery();   % optional, for programmatic access
            %
            %   If callbacks stop working after editing this file, run:
            %       clear classes; CellDiscovery()

            % Re-use existing window if already open
            hExist = findobj(0, 'Tag', 'PNNBatchGUIMain');
            if ~isempty(hExist)
                figure(hExist(1));
                return;
            end

            obj.repoRoot = CellToolkit.detectRepoRoot();
            obj.discoverModels();
            obj.loadPrefs();
            obj.buildGUI();  % stores obj in figure appdata — prevents GC
            obj.doSearch();
        end

        function delete(obj)
            % Destructor — stop timer, kill subprocess, close figure.
            obj.cleanup();
            if ~isempty(obj.hFig) && isvalid(obj.hFig)
                delete(obj.hFig);
            end
        end

        function setSearchDir(obj, folder, doSearchNow)
            % Point the GUI at a folder and (optionally) run the file search.
            %   app = CellDiscovery();  app.setSearchDir(folder)
            % Used by CellDatasetManager to open detection on a chosen dataset.
            % Resolves the live GUI object even when the constructor re-used an
            % already-open window (in which case this handle has no figure).
            if nargin < 3, doSearchNow = true; end
            target = obj;
            if isempty(target.hFig) || ~isvalid(target.hFig)
                h = findobj(0, 'Tag', 'PNNBatchGUIMain');
                if ~isempty(h) && isappdata(h(1), 'PNNBatchGUIObj')
                    target = getappdata(h(1), 'PNNBatchGUIObj');
                end
            end
            if isempty(target.hFig) || ~isvalid(target.hFig)
                return;
            end
            target.hDirEdit.Value = char(folder);
            target.P.parentDir    = char(folder);
            target.savePrefs();
            if doSearchNow
                target.doSearch();
            end
            figure(target.hFig);
        end

        function addCloseListener(obj, fcn)
            % Register a callback to fire when this app's window is
            % destroyed. Used by CellDatasetManager to re-scan its dashboard
            % once detection is done. Resolves the live GUI object (the
            % constructor may have re-used an already-open window, in which
            % case this handle has no figure).
            target = obj;
            if isempty(target.hFig) || ~isvalid(target.hFig)
                h = findobj(0, 'Tag', 'PNNBatchGUIMain');
                if ~isempty(h) && isappdata(h(1), 'PNNBatchGUIObj')
                    target = getappdata(h(1), 'PNNBatchGUIObj');
                end
            end
            if ~isempty(target.hFig) && isvalid(target.hFig)
                addlistener(target.hFig, 'ObjectBeingDestroyed', ...
                    @(~,~) fcn());
            end
        end

    end  % public methods

    %% ---- Private methods -------------------------------------------------
    methods (Access = private)


        %% App setup


        function loadPrefs(obj)
            % Build defaults struct, then override with any saved preferences.
            defaults = struct( ...
                'parentDir',       obj.repoRoot, ...
                'fileRegex',       '(?i)\.tif$', ...
                'pythonExe',       'python', ...
                'condaExe',        CellToolkit.detectConda(), ...
                'condaEnv',        '', ...
                'device',          'cpu', ...
                'batchSize',       '1', ...
                'threshold',       '', ...
                'overwrite',       0, ...
                'colormapIdx',     1, ...
                'autoContrast',    true, ...
                'savePng',         false, ...
                'saveLsmTif',      false, ...
                'diagnosticMode',  false, ...
                'dotColorIdx',     1, ...
                'dotSize',         '5', ...
                'displayPreproc',  false, ...
                'lsmOptions',      CellDiscovery.defaultLSMOptions(), ...
                'snapOptions',     struct(), ...
                'pageMapData',     {CellDiscovery.defaultPageMap()} ...
                );
            obj.P = defaults;
            flds = fieldnames(defaults);
            for k = 1:numel(flds)
                f = flds{k};
                if ispref(obj.PREF_GROUP, f)
                    obj.P.(f) = getpref(obj.PREF_GROUP, f);
                end
            end
        end

        function savePrefs(obj)
            % Read current control values and persist all preferences.
            if isempty(obj.hFig) || ~isvalid(obj.hFig), return; end
            obj.P.parentDir       = obj.hDirEdit.Value;
            obj.P.fileRegex       = obj.hRegexEdit.Value;
            obj.P.pythonExe       = obj.hPyEdit.Value;
            obj.P.condaExe        = obj.hCondaExeEdit.Value;
            obj.P.condaEnv        = obj.hCondaEdit.Value;
            obj.P.device          = obj.hDeviceEdit.Value;
            obj.P.batchSize       = obj.hBatchEdit.Value;
            obj.P.threshold       = obj.hThrEdit.Value;
            obj.P.overwrite       = obj.hOverwriteRad.Value;
            obj.P.colormapIdx     = find(strcmp(obj.hColormapPop.Items, obj.hColormapPop.Value), 1);
            obj.P.autoContrast    = obj.hAutoContrast.Value;
            obj.P.savePng         = obj.hSavePng.Value;
            obj.P.saveLsmTif      = obj.hSaveLsmTif.Value;
            obj.P.diagnosticMode  = obj.hDiagnosticChk.Value;
            obj.P.dotColorIdx     = find(strcmp(obj.hDotColorPop.Items, obj.hDotColorPop.Value), 1);
            obj.P.dotSize         = obj.hDotSizeEdit.Value;
            obj.P.displayPreproc  = obj.hDisplayPreprocChk.Value;
            obj.P.lsmOptions      = CellDiscovery.sanitizeLSMOptions(obj.P.lsmOptions);
            obj.P.pageMapData     = obj.hPageTable.Data;

            flds = fieldnames(obj.P);
            for k = 1:numel(flds)
                setpref(obj.PREF_GROUP, flds{k}, obj.P.(flds{k}));
            end
        end

        function discoverModels(obj)
            % Scan repo root for subdirs containing best.pth; split by type.
            % Names containing 'fasterrcnn' -> detection; all others -> rescore.
            [obj.detModels, obj.rescoreModels] = CellToolkit.discoverModels(obj.repoRoot);
        end


        %% GUI construction


        function buildGUI(obj)
            % ---- Figure --------------------------------------------------
            obj.hFig = uifigure( ...
                'Name',            'PNN / PV Batch Detector', ...
                'Position',        [60 30 1300 1010], ...
                'CloseRequestFcn', @obj.onClose, ...
                'Tag',             'PNNBatchGUIMain', ...
                'Resize',          'on', ...
                'AutoResizeChildren', 'off');
            setappdata(obj.hFig, 'PNNBatchGUIObj', obj);

            % ---- Root grid: 6 rows (top→bottom) + padding ---------------
            rootGrid = uigridlayout(obj.hFig, [6 1]);
            rootGrid.Padding    = [8 8 8 8];
            rootGrid.RowSpacing = 6;
            rootGrid.RowHeight  = {140, '1x', 170, 130, 140, 50};

            %% ---- Row 1 — Directory & Python ----------------------------
            topGrid = uigridlayout(rootGrid, [1 2]);
            topGrid.Layout.Row    = 1;
            topGrid.Padding       = [0 0 0 0];
            topGrid.ColumnSpacing = 6;
            topGrid.ColumnWidth   = {'3x', '2x'};

            %% pDir
            pDir = uipanel(topGrid, 'Title', 'Directory & File Search');
            pDir.Layout.Column = 1;
            gDir = uigridlayout(pDir, [2 4]);
            gDir.Padding       = [6 6 6 6];
            gDir.RowSpacing    = 4;
            gDir.ColumnSpacing = 4;
            gDir.RowHeight     = {22, 22};
            gDir.ColumnWidth   = {'fit', '1x', 90, 'fit'};

            lbl = uilabel(gDir, 'Text', 'Parent directory:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;

            obj.hDirEdit = uieditfield(gDir, 'text', ...
                'Value', obj.P.parentDir, 'Tag', 'dirEdit', ...
                'Tooltip', 'Root folder searched recursively for image files', ...
                'ValueChangedFcn', @obj.onDirEdit);
            obj.hDirEdit.Layout.Row = 1; obj.hDirEdit.Layout.Column = 2;

            btn = uibutton(gDir, 'Text', 'Browse...', 'ButtonPushedFcn', @obj.onBrowseDir);
            btn.Layout.Row = 1; btn.Layout.Column = 3;

            obj.hFileCountLabel = uilabel(gDir, 'Text', '0 files found', ...
                'HorizontalAlignment', 'left', 'FontColor', [0.2 0.5 0.2]);
            obj.hFileCountLabel.Layout.Row = 1; obj.hFileCountLabel.Layout.Column = 4;

            lbl = uilabel(gDir, 'Text', 'File filter (regex):', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;

            obj.hRegexEdit = uieditfield(gDir, 'text', ...
                'Value', obj.P.fileRegex, 'Tag', 'regexEdit', ...
                'Tooltip', 'Regular expression matched against the filename only (not full path)', ...
                'ValueChangedFcn', @obj.onRegexEdit);
            obj.hRegexEdit.Layout.Row = 2; obj.hRegexEdit.Layout.Column = 2;

            btn = uibutton(gDir, 'Text', 'Search', 'ButtonPushedFcn', @obj.onSearch);
            btn.Layout.Row = 2; btn.Layout.Column = 3;

            %% pPy
            pPy = uipanel(topGrid, 'Title', 'Python Environment');
            pPy.Layout.Column = 2;
            gPy = uigridlayout(pPy, [4 3]);
            gPy.Padding       = [6 6 6 6];
            gPy.RowSpacing    = 4;
            gPy.ColumnSpacing = 4;
            gPy.RowHeight     = {22, 22, 22, 22};
            gPy.ColumnWidth   = {'fit', '1x', 90};

            lbl = uilabel(gPy, 'Text', 'Python executable:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;
            obj.hPyEdit = uieditfield(gPy, 'text', ...
                'Value', obj.P.pythonExe, 'Tag', 'pyEdit', ...
                'Tooltip', 'Full path to python.exe, or just "python" if on PATH. When a Conda env is set, this is the python used inside that env.', ...
                'ValueChangedFcn', @obj.onPyEdit);
            obj.hPyEdit.Layout.Row = 1; obj.hPyEdit.Layout.Column = 2;
            btn = uibutton(gPy, 'Text', 'Browse...', 'ButtonPushedFcn', @obj.onBrowsePython);
            btn.Layout.Row = 1; btn.Layout.Column = 3;

            lbl = uilabel(gPy, 'Text', 'conda executable:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;
            obj.hCondaExeEdit = uieditfield(gPy, 'text', ...
                'Value', obj.P.condaExe, 'Tag', 'condaExeEdit', ...
                'Tooltip', 'Full path to conda.exe (auto-detected). Used only when a Conda env name is set below.', ...
                'ValueChangedFcn', @obj.onCondaExeEdit);
            obj.hCondaExeEdit.Layout.Row = 2; obj.hCondaExeEdit.Layout.Column = 2;
            btn = uibutton(gPy, 'Text', 'Browse...', 'ButtonPushedFcn', @obj.onBrowseCondaExe);
            btn.Layout.Row = 2; btn.Layout.Column = 3;

            lbl = uilabel(gPy, 'Text', 'Conda env name:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 3; lbl.Layout.Column = 1;
            obj.hCondaEdit = uieditfield(gPy, 'text', ...
                'Value', obj.P.condaEnv, 'Tag', 'condaEdit', ...
                'Tooltip', 'Optional conda env name (e.g. countpnn). Leave blank to invoke the Python executable directly.', ...
                'ValueChangedFcn', @obj.onCondaEdit);
            obj.hCondaEdit.Layout.Row = 3; obj.hCondaEdit.Layout.Column = 2;
            obj.hTestEnvBtn = uibutton(gPy, 'Text', 'Test env', 'Tag', 'testEnvBtn', ...
                'Tooltip', 'Quick check that Python + hydra + torch are importable', ...
                'ButtonPushedFcn', @obj.onTestEnv);
            obj.hTestEnvBtn.Layout.Row = 3; obj.hTestEnvBtn.Layout.Column = 3;

            lbl = uilabel(gPy, 'Text', 'Repo root:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 4; lbl.Layout.Column = 1;
            lbl2 = uilabel(gPy, 'Text', obj.repoRoot, ...
                'HorizontalAlignment', 'left', 'FontColor', [0.5 0.5 0.5], 'FontSize', 11);
            lbl2.Layout.Row = 4; lbl2.Layout.Column = [2 3];

            %% ---- Row 2 — Files + Models --------------------------------
            midGrid = uigridlayout(rootGrid, [1 1]);
            midGrid.Layout.Row    = 2;
            midGrid.Padding       = [0 0 0 0];
            midGrid.ColumnSpacing = 6;
            midGrid.ColumnWidth   = {'1x', 200};

            %% pFiles
            pFiles = uipanel(midGrid, 'Title', 'Files to Process  (Ctrl+click to select a subset)');
            pFiles.Layout.Column = 1;
            gFiles = uigridlayout(pFiles, [1 1]);
            gFiles.Padding = [4 4 4 4];
            obj.hFileList = uilistbox(gFiles, 'Items', {}, ...
                'Multiselect', 'on', 'Tag', 'fileList', 'FontSize', 11, ...
                'ValueChangedFcn', @(~,~) []);

            %% ---- Row 3 — Multi-page & Preprocessing --------------------
            pMP = uipanel(rootGrid, 'Title', 'Multi-page (per-page models) & Preprocessing');
            pMP.Layout.Row = 3;
            gMP = uigridlayout(pMP, [3 8]);
            gMP.Padding       = [6 6 6 6];
            gMP.RowSpacing    = 4;
            gMP.ColumnSpacing = 4;
            gMP.RowHeight     = {24, 24, '1x'};
            gMP.ColumnWidth   = {230, 90, 80, 70, 80, 70, 'fit', '1x'};

            % --- Row 1: per-page enable + add/remove ---
            obj.hAddPageBtn = uibutton(gMP, 'Text', 'Add page', ...
                'Tooltip', 'Add a page-mapping row', ...
                'ButtonPushedFcn', @obj.onAddPageRow);
            obj.hAddPageBtn.Layout.Row = 1; obj.hAddPageBtn.Layout.Column = 3;

            obj.hDelPageBtn = uibutton(gMP, 'Text', 'Remove page', ...
                'Tooltip', 'Remove the selected row (or the last row if none selected)', ...
                'ButtonPushedFcn', @obj.onDelPageRow);
            obj.hDelPageBtn.Layout.Row = 1; obj.hDelPageBtn.Layout.Column = [4 5];

            obj.hLSMOptionsBtn = uibutton(gMP, 'push', ...
                'Text', 'LSM options...', ...
                'Tooltip', ['Edit advanced name-value parameters passed to correctBidirectionalLSMArtifact. ' ...
                'The button is enabled when at least one page row has Correct LSM checked.'], ...
                'ButtonPushedFcn', @obj.onLSMOptionsButton);
            obj.hLSMOptionsBtn.Layout.Row = 1; obj.hLSMOptionsBtn.Layout.Column = 2;

            obj.hSnapOptionsBtn = uibutton(gMP, 'push', ...
                'Text', 'Snap options...', ...
                'Tooltip', ['Edit per-page parameters for the snapToCellCentroid post-processing step ' ...
                '(localization refinement). The button is enabled when at least one page row has Snap checked.'], ...
                'ButtonPushedFcn', @obj.onSnapOptionsButton);
            obj.hSnapOptionsBtn.Layout.Row = 1; obj.hSnapOptionsBtn.Layout.Column = 1;

            lbl = uilabel(gMP, ...
                'Text', 'Map a detection (and optional rescore) model to each TIFF page.', ...
                'HorizontalAlignment', 'left', 'FontColor', [0.45 0.45 0.45], 'FontSize', 11);
            lbl.Layout.Row = 1; lbl.Layout.Column = [6 8];

            % --- Row 2: preprocessing controls ---
            lbl = uilabel(gMP, ...
                'Text', ['Snap: post-process each result to cell-mass centroids (snapToCellCentroid). ' ...
                'Tick Snap per page; tune per-page parameters via "Snap options...".'], ...
                'HorizontalAlignment', 'left', 'FontColor', [0.45 0.45 0.45], 'FontSize', 11);
            lbl.Layout.Row = 2; lbl.Layout.Column = [1 6];

            obj.hDisplayPreprocChk = uicheckbox(gMP, ...
                'Text', 'Show resized image in results (default: raw page)', ...
                'Value', logical(obj.P.displayPreproc), 'Tag', 'displayPreprocChk', ...
                'Tooltip', ['When on, the result figure/PNG show the resized image the model saw ' ...
                '(background-subtracted / resized). When off, the raw page is shown with ' ...
                'detections mapped onto it.'], ...
                'ValueChangedFcn', @obj.onDisplayPreprocChange);
            obj.hDisplayPreprocChk.Layout.Row = 2; obj.hDisplayPreprocChk.Layout.Column = [7 8];

            % --- Row 3: page-mapping table ---
            detChoices     = CellDiscovery.detChoiceList(obj.detModels, obj.SKIP_LABEL);
            rescoreChoices = [{obj.NONE_LABEL}, obj.rescoreModels];
            tableData      = CellDiscovery.sanitizePageMap(obj.P.pageMapData, detChoices, rescoreChoices);

            obj.hPageTable = uitable(gMP, ...
                'Data',          tableData, ...
                'ColumnName',    {'Page','Suffix', 'Detection Model', 'Rescore Model', 'LSM', 'Bg radius', 'Resize x', 'Snap'}, ...
                'ColumnFormat',  {'numeric', 'char', detChoices, rescoreChoices, 'logical', 'numeric', 'numeric', 'logical'}, ...
                'ColumnEditable', [true true true true true true true true], ...
                'ColumnWidth',   {50, 70, 220, 300, 80, 80, 70, 60}, ...
                'RowName',       {}, ...
                'Tag',           'pageTable', ...
                'CellEditCallback',      @obj.onPageTableEdit, ...
                'CellSelectionCallback', @obj.onPageTableSelect);
            obj.hPageTable.Layout.Row = 3; obj.hPageTable.Layout.Column = [1 8];
            obj.updateLSMOptionsButton();
            obj.updateSnapOptionsButton();

            %% ---- Row 4 — predict.py Options ----------------------------
            pPred = uipanel(rootGrid, 'Title', 'predict.py Options');
            pPred.Layout.Row = 4;
            gPred = uigridlayout(pPred, [3 8]);
            gPred.Padding       = [6 6 6 6];
            gPred.RowSpacing    = 4;
            gPred.ColumnSpacing = 4;
            gPred.RowHeight     = {22, 22, 20};
            gPred.ColumnWidth   = {'fit', 110, 'fit', 60, 'fit', 70, 'fit', '1x'};

            lbl = uilabel(gPred, 'Text', 'Device:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;
            obj.hDeviceEdit = uieditfield(gPred, 'text', ...
                'Value', obj.P.device, 'Tag', 'deviceEdit', ...
                'Tooltip', 'Compute device (e.g. cpu | cuda:0)', ...
                'ValueChangedFcn', @obj.onDeviceEdit);
            obj.hDeviceEdit.Layout.Row = 1; obj.hDeviceEdit.Layout.Column = 2;

            lbl = uilabel(gPred, 'Text', 'Batch size:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 3;
            obj.hBatchEdit = uieditfield(gPred, 'text', ...
                'Value', obj.P.batchSize, 'Tag', 'batchEdit', ...
                'Tooltip', 'Number of 640x640 patches in parallel (--batch-size)', ...
                'ValueChangedFcn', @obj.onBatchEdit);
            obj.hBatchEdit.Layout.Row = 1; obj.hBatchEdit.Layout.Column = 4;

            lbl = uilabel(gPred, 'Text', 'Threshold:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 5;
            obj.hThrEdit = uieditfield(gPred, 'text', ...
                'Value', obj.P.threshold, 'Tag', 'thrEdit', ...
                'Tooltip', 'Detection threshold 0-1; leave blank for checkpoint default (--threshold)', ...
                'ValueChangedFcn', @obj.onThrEdit);
            obj.hThrEdit.Layout.Row = 1; obj.hThrEdit.Layout.Column = 6;
            lbl = uilabel(gPred, 'Text', '(blank = auto)', ...
                'HorizontalAlignment', 'left', 'FontColor', [0.5 0.5 0.5], 'FontSize', 11);
            lbl.Layout.Row = 1; lbl.Layout.Column = 7;

            % Existing results — radio-button group
            % uiradiobutton requires uibuttongroup as direct parent (no nested grid).
            lbl = uilabel(gPred, 'Text', 'Existing results:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;
            bgOW = uibuttongroup(gPred, 'BorderType', 'none', ...
                'SelectionChangedFcn', @obj.onOverwriteChange);
            bgOW.Layout.Row = 2; bgOW.Layout.Column = [2 8];
            obj.hIgnoreRad = uiradiobutton(bgOW, ...
                'Text', 'Ignore (skip)', 'Tag', 'ignoreRad', ...
                'Tooltip', 'Skip any file whose output CSV already exists', ...
                'Value', ~obj.P.overwrite, ...
                'Position', [0 2 130 22]);
            obj.hOverwriteRad = uiradiobutton(bgOW, ...
                'Text', 'Overwrite', 'Tag', 'overwriteRad', ...
                'Tooltip', 'Re-process and replace existing output CSVs', ...
                'Value', logical(obj.P.overwrite), ...
                'Position', [140 2 110 22]);

            lbl = uilabel(gPred, ...
                'Text', 'Output per file:  <image_stem>[_page<k>]_locs.csv  placed in the image''s own subdirectory', ...
                'HorizontalAlignment', 'left', 'FontColor', [0.45 0.45 0.45], 'FontSize', 11);
            lbl.Layout.Row = 3; lbl.Layout.Column = [1 8];

            %% ---- Row 5 — Display & Export ------------------------------
            pDisp = uipanel(rootGrid, 'Title', 'Display & Export Options');
            pDisp.Layout.Row = 5;
            gDisp = uigridlayout(pDisp, [5 8]);
            gDisp.Padding       = [6 6 6 6];
            gDisp.RowSpacing    = 4;
            gDisp.ColumnSpacing = 4;
            gDisp.RowHeight     = {22, 22, 20, 22};
            gDisp.ColumnWidth   = {'fit', 110, 'fit', 180, 'fit', 100, 'fit', 70};

            lbl = uilabel(gDisp, 'Text', 'Colormap:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 1;
            obj.hColormapPop = uidropdown(gDisp, ...
                'Items', obj.COLORMAPS, ...
                'Value', obj.COLORMAPS{min(obj.P.colormapIdx, numel(obj.COLORMAPS))}, ...
                'Tag', 'colormapPop', ...
                'Tooltip', 'Colormap applied to single-channel (grayscale) images', ...
                'ValueChangedFcn', @obj.onColormapChange);
            obj.hColormapPop.Layout.Row = 1; obj.hColormapPop.Layout.Column = 2;

            obj.hAutoContrast = uicheckbox(gDisp, ...
                'Text', 'Auto contrast  (imadjust)', ...
                'Value', logical(obj.P.autoContrast), 'Tag', 'autoContrast', ...
                'Tooltip', 'Apply imadjust() histogram stretch before display and PNG export', ...
                'ValueChangedFcn', @obj.onAutoContrastChange);
            obj.hAutoContrast.Layout.Row = 1; obj.hAutoContrast.Layout.Column = [3 4];

            lbl = uilabel(gDisp, 'Text', 'Dot color:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 5;
            obj.hDotColorPop = uidropdown(gDisp, ...
                'Items', obj.DOT_COLORS, ...
                'Value', obj.DOT_COLORS{min(obj.P.dotColorIdx, numel(obj.DOT_COLORS))}, ...
                'Tag', 'dotColorPop', ...
                'ValueChangedFcn', @obj.onDotColorChange);
            obj.hDotColorPop.Layout.Row = 1; obj.hDotColorPop.Layout.Column = 6;

            lbl = uilabel(gDisp, 'Text', 'Dot size:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 7;
            obj.hDotSizeEdit = uieditfield(gDisp, 'text', ...
                'Value', obj.P.dotSize, 'Tag', 'dotSizeEdit', ...
                'Tooltip', 'Scatter marker area in points^2 (scatter SizeData)', ...
                'ValueChangedFcn', @obj.onDotSizeChange);
            obj.hDotSizeEdit.Layout.Row = 1; obj.hDotSizeEdit.Layout.Column = 8;

            obj.hSavePng = uicheckbox(gDisp, ...
                'Text', 'Save annotated PNG alongside each result CSV', ...
                'Value', logical(obj.P.savePng), 'Tag', 'savePng', ...
                'Tooltip', 'Exports  <stem>_locs.png  in the image subdirectory', ...
                'ValueChangedFcn', @obj.onSavePngChange);
            obj.hSavePng.Layout.Row = 2; obj.hSavePng.Layout.Column = [1 8];

            obj.hSaveLsmTif = uicheckbox(gDisp, ...
                'Text', 'Save final resized image as TIF alongside each result CSV', ...
                'Value', logical(obj.P.saveLsmTif), 'Tag', 'saveLsmTif', ...
                'Tooltip', ['Exports  <stem>_resized.tif  in the image subdirectory. ' ...
                'Saves the image after LSM correction, background subtraction, and resize — ' ...
                'the exact image the detection model received.'], ...
                'ValueChangedFcn', @obj.onSaveLsmTifChange);
            obj.hSaveLsmTif.Layout.Row = 3; obj.hSaveLsmTif.Layout.Column = [1 8];

            obj.hDiagnosticChk = uicheckbox(gDisp, ...
                'Text', 'Diagnostic mode (pause after each page; show processing / snap images)', ...
                'Value', logical(obj.P.diagnosticMode), 'Tag', 'diagnosticChk', ...
                'Tooltip', ['When on, the batch pauses after each page and opens a diagnostic window ' ...
                'showing the raw page, the preprocessed image the detector saw (LSM / background / ' ...
                'resize), and — when Snap is enabled — the snap-input image with arrows from each ' ...
                'original detection to its snapped location. Click Continue to proceed or Stop batch ' ...
                'to end. May be toggled during a run to start/stop pausing.'], ...
                'ValueChangedFcn', @obj.onDiagnosticChange);
            obj.hDiagnosticChk.Layout.Row = 4; obj.hDiagnosticChk.Layout.Column = [1 8];

            lbl = uilabel(gDisp, ...
                'Text', 'Display: raw page (or resized image, see above) with detections overlaid; window is reused across pages', ...
                'HorizontalAlignment', 'left', 'FontColor', [0.45 0.45 0.45], 'FontSize', 11);
            lbl.Layout.Row = 5; lbl.Layout.Column = [1 8];

            %% ---- Row 6 — Run Controls ----------------------------------
            pRun = uipanel(rootGrid, 'BorderType', 'line');
            pRun.Layout.Row = 6;
            gRun = uigridlayout(pRun, [1 3]);
            gRun.Padding       = [6 6 6 6];
            gRun.ColumnSpacing = 6;
            gRun.ColumnWidth   = {148, 110, '1x'};
            gRun.RowHeight     = {'1x'};

            obj.hStartBtn = uibutton(gRun, 'Text', 'Start Batch', ...
                'FontSize', 11, 'FontWeight', 'bold', ...
                'FontColor', [0.05 0.42 0.05], 'Tag', 'startBtn', ...
                'ButtonPushedFcn', @obj.onStart);
            obj.hStartBtn.Layout.Row = 1; obj.hStartBtn.Layout.Column = 1;

            obj.hStopBtn = uibutton(gRun, 'Text', 'Stop', ...
                'FontSize', 11, 'FontWeight', 'bold', ...
                'FontColor', [0.60 0.05 0.05], 'Enable', false, 'Tag', 'stopBtn', ...
                'ButtonPushedFcn', @obj.onStop);
            obj.hStopBtn.Layout.Row = 1; obj.hStopBtn.Layout.Column = 2;

            obj.hProgressLabel = uilabel(gRun, 'Text', 'Ready.', ...
                'HorizontalAlignment', 'left', 'FontSize', 12);
            obj.hProgressLabel.Layout.Row = 1; obj.hProgressLabel.Layout.Column = 3;
        end


        %% File search


        function doSearch(obj)
            rootDir  = strtrim(obj.hDirEdit.Value);
            regexStr = strtrim(obj.hRegexEdit.Value);

            if ~isfolder(rootDir)
                obj.hFileCountLabel.Text      = 'Invalid directory';
                obj.hFileCountLabel.FontColor = [0.7 0 0];
                obj.hFileList.Items = {};
                obj.allAbsFiles = {};
                return;
            end

            obj.hFileCountLabel.Text      = 'Searching...';
            obj.hFileCountLabel.FontColor = [0.6 0.4 0];
            drawnow;

            allFiles = CellToolkit.recDir(rootDir);

            if ~isempty(regexStr) && ~isempty(allFiles)
                try
                    [~, names, exts] = cellfun(@fileparts, allFiles, 'UniformOutput', false);
                    basenames = strcat(names, exts);
                    keep      = ~cellfun(@isempty, regexpi(basenames, regexStr, 'once'));
                    allFiles  = allFiles(keep);
                catch ME
                    obj.hFileCountLabel.Text      = ['Regex error: ' ME.message];
                    obj.hFileCountLabel.FontColor = [0.7 0 0];
                    obj.hFileList.Items = {};
                    obj.allAbsFiles = {};
                    return;
                end
            end

            n = numel(allFiles);
            if n > 0
                relFiles = cellfun(@(f) CellToolkit.makeRelativePath(f, rootDir), ...
                    allFiles, 'UniformOutput', false);
            else
                relFiles = {};
            end
            obj.hFileList.Items = relFiles;
            obj.allAbsFiles = allFiles;
            obj.hFileCountLabel.Text      = sprintf('%d file%s found', n, CellToolkit.ternary(n == 1, '', 's'));
            obj.hFileCountLabel.FontColor = CellToolkit.ternary(n > 0, [0.1 0.45 0.1], [0.6 0.4 0]);
        end


        %% Callbacks: directory & search


        function onClose(obj, src, ~)
            obj.cleanup();
            obj.savePrefs();
            if isvalid(src)
                src.CloseRequestFcn = '';
                rmappdata(src, 'PNNBatchGUIObj');
                delete(src);
            end
            obj.hFig = [];   % prevent destructor from double-deleting
        end

        function onDirEdit(obj, src, ~)
            obj.P.parentDir = src.Value;
            obj.savePrefs();
        end

        function onRegexEdit(obj, src, ~)
            obj.P.fileRegex = src.Value;
            obj.savePrefs();
            obj.doSearch();
        end

        function onBrowseDir(obj, ~, ~)
            startDir = obj.hDirEdit.Value;
            if ~isfolder(startDir), startDir = obj.repoRoot; end
            d = uigetdir(startDir, 'Select parent directory');
            if isequal(d, 0), return; end
            obj.hDirEdit.Value = d;
            obj.P.parentDir = d;
            obj.savePrefs();
            obj.doSearch();
        end

        function onSearch(obj, ~, ~)
            set(obj.hFig, 'Pointer', 'watch');
            drawnow;
            obj.doSearch();
            set(obj.hFig, 'Pointer', 'arrow');
            drawnow;
        end


        %% Callbacks: Python environment


        function onPyEdit(obj, src, ~)
            obj.P.pythonExe = src.Value;
            obj.savePrefs();
        end

        function onBrowsePython(obj, ~, ~)
            [f, p] = uigetfile( ...
                {'*.exe', 'Python Executable (*.exe)'; '*', 'All Files (*)'}, ...
                'Select Python Executable');
            if isequal(f, 0), return; end
            pyPath = fullfile(p, f);
            obj.hPyEdit.Value = pyPath;
            obj.P.pythonExe = pyPath;
            obj.savePrefs();
        end

        function onCondaExeEdit(obj, src, ~)
            obj.P.condaExe = src.Value;
            obj.savePrefs();
        end

        function onBrowseCondaExe(obj, ~, ~)
            [f, p] = uigetfile( ...
                {'*.exe;*.bat', 'conda executable (*.exe, *.bat)'; '*', 'All Files (*)'}, ...
                'Select conda executable');
            if isequal(f, 0), return; end
            condaPath = fullfile(p, f);
            obj.hCondaExeEdit.Value = condaPath;
            obj.P.condaExe = condaPath;
            obj.savePrefs();
        end

        function onCondaEdit(obj, src, ~)
            obj.P.condaEnv = src.Value;
            obj.savePrefs();
        end

        function cfg = pythonCfg(obj)
            % Build a CellToolkit Python-invocation config from the current
            % Python Environment controls (interpreter, conda exe/env) with the
            % repo root as the working directory.
            cfg = CellToolkit.pythonConfig( ...
                'PythonExe',  strtrim(obj.hPyEdit.Value), ...
                'CondaExe',   strtrim(obj.hCondaExeEdit.Value), ...
                'CondaEnv',   strtrim(obj.hCondaEdit.Value), ...
                'WorkingDir', obj.repoRoot);
        end

        function envStatus = onTestEnv(obj, ~, ~)
            % Run a quick synchronous check that Python + required modules are
            % importable. Returns 0 on success, nonzero on failure.
            pyExe    = strtrim(obj.hPyEdit.Value);
            condaExe = strtrim(obj.hCondaExeEdit.Value);
            condaEnv = strtrim(obj.hCondaEdit.Value);

            obj.hProgressLabel.Text = 'Checking Python environment ...';
            set(obj.hFig, 'Pointer', 'watch');
            drawnow;
            fprintf('[CHECK] Verifying Python environment ...\n');

            if ~isempty(condaEnv) && isempty(condaExe)
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                errordlg(['Conda env name is set but the conda executable path is empty.' newline ...
                    'Browse for conda.exe / conda.bat in the Python Environment panel.'], ...
                    'conda not configured');
                envStatus = 1;
                return;
            end

            [ok, ~, envOut] = CellToolkit.testPythonEnv(obj.pythonCfg(), {'hydra', 'torch'});
            set(obj.hFig, 'Pointer', 'arrow');
            drawnow;
            envOut = strtrim(envOut);
            if ok
                fprintf('[TEST] PASS: %s\n', envOut);
                obj.hProgressLabel.Text = ['Environment OK: ' envOut];
                envStatus = 0;
                return;
            end

            fprintf('[TEST] FAIL:\n%s\n', envOut);
            % Build a helpful diagnostic message
            if isempty(condaEnv)
                hint = sprintf( ...
                    ['Python executable "%s" cannot import hydra or torch.\n\n' ...
                    'Fix options:\n' ...
                    '  1. Enter your conda environment name in the\n' ...
                    '     "Conda env name" field (e.g.  countpnn)\n' ...
                    '     and leave Python executable as  python\n\n' ...
                    '  2. Set Python executable to the full path of\n' ...
                    '     your conda env''s python.exe, e.g.:\n' ...
                    '     C:\\...\\conda\\envs\\countpnn\\python.exe\n\n' ...
                    'Use the "Test env" button to verify your settings.\n\n' ...
                    'Error output:\n%s'], pyExe, envOut);
            else
                hint = sprintf( ...
                    ['conda env "%s" cannot import hydra or torch.\n\n' ...
                    'Check that:\n' ...
                    '  - The environment name is spelled correctly\n' ...
                    '  - The conda executable path is correct\n' ...
                    '  - The environment has the repo dependencies:\n' ...
                    '      conda activate %s\n' ...
                    '      pip install -r requirements.txt\n\n' ...
                    'Use the "Test env" button to verify your settings.\n\n' ...
                    'Error output:\n%s'], condaEnv, condaEnv, envOut);
            end
            obj.hProgressLabel.Text = 'Environment check failed — see error dialog.';
            errordlg(hint, 'Python Environment Error');
            envStatus = 1;
        end


        %% Callbacks: model selection


        function onDetModelChange(obj, src, ~)
            obj.P.detModelIdx = find(strcmp(src.Items, src.Value), 1);
            obj.savePrefs();
        end

        function onRescoreModelChange(obj, src, ~)
            obj.P.rescoreModelIdx = find(strcmp(src.Items, src.Value), 1);
            obj.savePrefs();
        end

        function onUseRescoreChange(obj, src, ~)
            v = src.Value;
            obj.P.useRescore = v;
            obj.hRescoreList.Enable  = v;
            obj.hRescoreLabel.Enable = v;
            obj.savePrefs();
        end


        %% Callbacks: multi-page & preprocessing


        function onPerPageChange(obj, src, ~)
            obj.P.perPageEnable = src.Value;
            obj.savePrefs();
        end

        function onAddPageRow(obj, ~, ~)
            data = obj.hPageTable.Data;
            detChoices     = CellDiscovery.detChoiceList(obj.detModels, obj.SKIP_LABEL);

            % New row defaults: next page index, first available detection model.
            if isempty(data)
                nextPage = 1;
            else
                pages    = cellfun(@(x) CellToolkit.parseNum(x, 0), data(:,1));
                nextPage = max(pages) + 1;
            end
            defDet = detChoices{min(2, numel(detChoices))};   % first real model if any, else (skip)
            newRow = {nextPage, sprintf('page%d',nextPage), defDet, obj.NONE_LABEL, false, 0, 1, false};
            obj.hPageTable.Data = [data; newRow];
            obj.P.pageMapData   = obj.hPageTable.Data;
            obj.updateLSMOptionsButton();
            obj.updateSnapOptionsButton();
            obj.savePrefs();
        end

        function onDelPageRow(obj, ~, ~)
            data = obj.hPageTable.Data;
            if isempty(data), return; end
            if ~isempty(obj.pageTableSelRow) && obj.pageTableSelRow >= 1 ...
                    && obj.pageTableSelRow <= size(data, 1)
                data(obj.pageTableSelRow, :) = [];
            else
                data(end, :) = [];   % no selection -> drop last row
            end
            obj.pageTableSelRow = [];
            obj.hPageTable.Data  = data;
            obj.P.pageMapData    = data;
            obj.updateLSMOptionsButton();
            obj.updateSnapOptionsButton();
            obj.savePrefs();
        end

        function onPageTableEdit(obj, ~, ~)
            obj.P.pageMapData = obj.hPageTable.Data;
            obj.updateLSMOptionsButton();
            obj.updateSnapOptionsButton();
            obj.savePrefs();
        end

        function onPageTableSelect(obj, ~, evt)
            if ~isempty(evt.Indices)
                obj.pageTableSelRow = evt.Indices(1, 1);
            end
        end


        function onGlobalBgChange(obj, src, ~)
            obj.P.globalBgRadius = src.Value;
            obj.savePrefs();
        end

        function onGlobalResizeChange(obj, src, ~)
            obj.P.globalResize = src.Value;
            obj.savePrefs();
        end

        function onDisplayPreprocChange(obj, src, ~)
            obj.P.displayPreproc = src.Value;
            obj.savePrefs();
        end




        function updateLSMOptionsButton(obj)
            % Enable the advanced LSM-options button only when at least one
            % page row is configured to run bidirectional LSM correction.
            if isempty(obj.hLSMOptionsBtn) || ~isvalid(obj.hLSMOptionsBtn)
                return;
            end
            data = obj.hPageTable.Data;
            useLSM = false;
            if iscell(data) && size(data, 2) >= 5
                for r = 1:size(data, 1)
                    useLSM = useLSM || CellToolkit.parseLogical(data{r,5}, false);
                end
            end
            if useLSM
                obj.hLSMOptionsBtn.Enable = 'on';
            else
                obj.hLSMOptionsBtn.Enable = 'off';
            end
        end

        function updateSnapOptionsButton(obj)
            % Enable the snap-options button only when at least one page row is
            % configured to run snapToCellCentroid post-processing (Snap column).
            if isempty(obj.hSnapOptionsBtn) || ~isvalid(obj.hSnapOptionsBtn)
                return;
            end
            data = obj.hPageTable.Data;
            useSnap = false;
            if iscell(data) && size(data, 2) >= 8
                for r = 1:size(data, 1)
                    useSnap = useSnap || CellToolkit.parseLogical(data{r,8}, false);
                end
            end
            if useSnap
                obj.hSnapOptionsBtn.Enable = 'on';
            else
                obj.hSnapOptionsBtn.Enable = 'off';
            end
        end

        function onLSMOptionsButton(obj, ~, ~)
            % Modal editor for the name-value parameters passed to
            % correctBidirectionalLSMArtifact.
            obj.P.lsmOptions = CellDiscovery.sanitizeLSMOptions(obj.P.lsmOptions);
            opts = obj.P.lsmOptions;
            names = fieldnames(opts);

            dlg = uifigure('Name', 'Bidirectional LSM correction options', ...
                'WindowStyle', 'modal', 'Position', [100 100 720 500]);
            g = uigridlayout(dlg, [numel(names)+2, 3]);
            g.Padding = [10 10 10 10];
            g.RowSpacing = 6;
            g.ColumnSpacing = 8;
            g.ColumnWidth = {160, '1x', 90};
            g.RowHeight = [repmat({26}, 1, numel(names)+1), {34}];

            hdr1 = uilabel(g, 'Text', 'Parameter', 'FontWeight', 'bold');
            hdr1.Layout.Row = 1; hdr1.Layout.Column = 1;
            hdr2 = uilabel(g, 'Text', 'Value', 'FontWeight', 'bold');
            hdr2.Layout.Row = 1; hdr2.Layout.Column = 2;
            hdr3 = uilabel(g, 'Text', 'Default', 'FontWeight', 'bold');
            hdr3.Layout.Row = 1; hdr3.Layout.Column = 3;

            edits = struct();
            defaults = CellDiscovery.defaultLSMOptions();
            for k = 1:numel(names)
                nm = names{k};
                tip = CellDiscovery.lsmOptionTooltip(nm, defaults.(nm));

                lab = uilabel(g, 'Text', nm, 'Tooltip', tip, 'HorizontalAlignment', 'right');
                lab.Layout.Row = k + 1; lab.Layout.Column = 1;

                edits.(nm) = uieditfield(g, 'text', ...
                    'Value', CellDiscovery.lsmOptionValueToText(opts.(nm)), ...
                    'Tooltip', tip);
                edits.(nm).Layout.Row = k + 1; edits.(nm).Layout.Column = 2;

                defLab = uilabel(g, 'Text', CellDiscovery.lsmOptionValueToText(defaults.(nm)), ...
                    'Tooltip', tip, 'FontColor', [0.45 0.45 0.45]);
                defLab.Layout.Row = k + 1; defLab.Layout.Column = 3;
            end

            btnGrid = uigridlayout(g, [1 3]);
            btnGrid.Padding = [0 0 0 0];
            btnGrid.ColumnWidth = {'1x', 100, 100};
            btnGrid.Layout.Row = numel(names) + 2; btnGrid.Layout.Column = [1 3];

            resetBtn = uibutton(btnGrid, 'push', 'Text', 'Reset defaults', ...
                'Tooltip', 'Restore all correctBidirectionalLSMArtifact parameters to default values.', ...
                'ButtonPushedFcn', @resetOptions);
            resetBtn.Layout.Row = 1; resetBtn.Layout.Column = 1;

            cancelBtn = uibutton(btnGrid, 'push', 'Text', 'Cancel', ...
                'ButtonPushedFcn', @(~,~) delete(dlg));
            cancelBtn.Layout.Row = 1; cancelBtn.Layout.Column = 2;

            okBtn = uibutton(btnGrid, 'push', 'Text', 'OK', ...
                'Tooltip', 'Save these LSM correction options and use them for every page with Correct LSM checked.', ...
                'ButtonPushedFcn', @saveOptions);
            okBtn.Layout.Row = 1; okBtn.Layout.Column = 3;

            function resetOptions(~, ~)
                dflt = CellDiscovery.defaultLSMOptions();
                for q = 1:numel(names)
                    edits.(names{q}).Value = CellDiscovery.lsmOptionValueToText(dflt.(names{q}));
                end
            end

            function saveOptions(~, ~)
                newOpts = struct();
                for q = 1:numel(names)
                    newOpts.(names{q}) = edits.(names{q}).Value;
                end
                obj.P.lsmOptions = CellDiscovery.sanitizeLSMOptions(newOpts);
                obj.savePrefs();
                delete(dlg);
            end
        end

        function onSnapOptionsButton(obj, ~, ~)
            % Modal, per-page editor for the snapToCellCentroid post-processing
            % parameters. A page selector at the top lets each TIFF page (as
            % listed in the page-mapping table) carry its own snap settings, so
            % e.g. a PNN page can use the "oval" preset while a PV page uses
            % "round". Settings are stored per page number in obj.P.snapOptions.
            spec  = CellDiscovery.snapOptionSpec();
            nOpt  = size(spec, 1);

            % Distinct page numbers present in the page-mapping table.
            data  = obj.hPageTable.Data;
            pages = [];
            suffByPage = containers.Map('KeyType', 'double', 'ValueType', 'char');
            if iscell(data)
                for r = 1:size(data, 1)
                    pg = round(CellToolkit.parseNum(data{r,1}, 0));
                    if pg >= 1 && ~ismember(pg, pages)
                        pages(end+1) = pg; %#ok<AGROW>
                        sfx = '';
                        if size(data, 2) >= 2 && ischar(data{r,2}), sfx = data{r,2}; end
                        suffByPage(pg) = sfx;
                    end
                end
            end
            if isempty(pages), pages = 1; suffByPage(1) = ''; end
            pages = sort(pages);

            % Working copy of each page's options (defaults filled in).
            work = struct();
            for pg = pages
                work.(sprintf('page%d', pg)) = obj.resolveSnapOptionsForPage(pg);
            end
            curPage = pages(1);

            pageItems = arrayfun(@(pg) ...
                CellDiscovery.snapPageLabel(pg, suffByPage(pg)), pages, ...
                'UniformOutput', false);

            % Height tracks the option count so every row + the button strip
            % stays visible as options are added.
            dlgH = 32 * (nOpt + 2) + 34 + 40;
            dlg = uifigure('Name', 'snapToCellCentroid post-processing options', ...
                'WindowStyle', 'modal', 'Position', [100 100 640 dlgH]);
            g = uigridlayout(dlg, [nOpt+3, 3]);
            g.Padding = [10 10 10 10];
            g.RowSpacing = 6;
            g.ColumnSpacing = 8;
            g.ColumnWidth = {180, '1x', 150};
            g.RowHeight = [{26}, repmat({26}, 1, nOpt+1), {34}];

            pgLab = uilabel(g, 'Text', 'Configure page:', 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'right');
            pgLab.Layout.Row = 1; pgLab.Layout.Column = 1;
            pgDrop = uidropdown(g, 'Items', pageItems, 'Value', pageItems{1}, ...
                'Tooltip', 'Pick which TIFF page these snap parameters apply to.', ...
                'ValueChangedFcn', @onPageChange);
            pgDrop.Layout.Row = 1; pgDrop.Layout.Column = [2 3];

            hdr1 = uilabel(g, 'Text', 'Parameter', 'FontWeight', 'bold');
            hdr1.Layout.Row = 2; hdr1.Layout.Column = 1;
            hdr2 = uilabel(g, 'Text', 'Value', 'FontWeight', 'bold');
            hdr2.Layout.Row = 2; hdr2.Layout.Column = 2;
            hdr3 = uilabel(g, 'Text', 'Default', 'FontWeight', 'bold');
            hdr3.Layout.Row = 2; hdr3.Layout.Column = 3;

            w = struct();
            for k = 1:nOpt
                nm   = spec{k,1};
                kind = spec{k,2};
                tip  = spec{k,5};
                lab = uilabel(g, 'Text', nm, 'Tooltip', tip, 'HorizontalAlignment', 'right');
                lab.Layout.Row = k + 2; lab.Layout.Column = 1;
                switch kind
                    case 'enum'
                        w.(nm) = uidropdown(g, 'Items', spec{k,3}, 'Tooltip', tip);
                    case 'bool'
                        w.(nm) = uicheckbox(g, 'Text', '', 'Tooltip', tip);
                    otherwise   % 'num' / 'text' — free text ('auto' = use preset)
                        w.(nm) = uieditfield(g, 'text', 'Tooltip', tip);
                end
                w.(nm).Layout.Row = k + 2; w.(nm).Layout.Column = 2;
                defLab = uilabel(g, 'Text', CellDiscovery.lsmOptionValueToText(spec{k,4}), ...
                    'Tooltip', tip, 'FontColor', [0.45 0.45 0.45]);
                defLab.Layout.Row = k + 2; defLab.Layout.Column = 3;
            end

            btnGrid = uigridlayout(g, [1 3]);
            btnGrid.Padding = [0 0 0 0];
            btnGrid.ColumnWidth = {'1x', 100, 100};
            btnGrid.Layout.Row = nOpt + 3; btnGrid.Layout.Column = [1 3];

            resetBtn = uibutton(btnGrid, 'push', 'Text', 'Reset page', ...
                'Tooltip', 'Restore this page''s snap parameters to default values.', ...
                'ButtonPushedFcn', @resetOptions);
            resetBtn.Layout.Row = 1; resetBtn.Layout.Column = 1;
            cancelBtn = uibutton(btnGrid, 'push', 'Text', 'Cancel', ...
                'ButtonPushedFcn', @(~,~) delete(dlg));
            cancelBtn.Layout.Row = 1; cancelBtn.Layout.Column = 2;
            okBtn = uibutton(btnGrid, 'push', 'Text', 'OK', ...
                'Tooltip', 'Save snap parameters for every page and close.', ...
                'ButtonPushedFcn', @saveAll);
            okBtn.Layout.Row = 1; okBtn.Layout.Column = 3;

            loadWidgets(work.(sprintf('page%d', curPage)));

            function s = readWidgets()
                s = struct();
                for q = 1:nOpt
                    nmq = spec{q,1};
                    switch spec{q,2}
                        case 'enum'
                            s.(nmq) = char(w.(nmq).Value);
                        case 'bool'
                            s.(nmq) = CellToolkit.ternary(w.(nmq).Value, 'true', 'false');
                        otherwise
                            s.(nmq) = strtrim(w.(nmq).Value);
                    end
                end
            end

            function loadWidgets(s)
                s = CellDiscovery.sanitizeSnapOptions(s);
                for q = 1:nOpt
                    nmq = spec{q,1};
                    val = s.(nmq);
                    switch spec{q,2}
                        case 'enum'
                            CellToolkit.setDropDownValue(w.(nmq), val);
                        case 'bool'
                            w.(nmq).Value = CellToolkit.parseLogical(val, false);
                        otherwise
                            w.(nmq).Value = CellDiscovery.lsmOptionValueToText(val);
                    end
                end
            end

            function onPageChange(src, ~)
                work.(sprintf('page%d', curPage)) = readWidgets();   % stash current
                idx = find(strcmp(pageItems, src.Value), 1);
                if isempty(idx), idx = 1; end
                curPage = pages(idx);
                loadWidgets(work.(sprintf('page%d', curPage)));
            end

            function resetOptions(~, ~)
                loadWidgets(CellDiscovery.defaultSnapOptions());
            end

            function saveAll(~, ~)
                work.(sprintf('page%d', curPage)) = readWidgets();   % stash current
                newOpts = struct();
                for q = 1:numel(pages)
                    key = sprintf('page%d', pages(q));
                    newOpts.(key) = CellDiscovery.sanitizeSnapOptions(work.(key));
                end
                obj.P.snapOptions = newOpts;
                obj.savePrefs();
                delete(dlg);
            end
        end


        %% Callbacks: predict.py options


        function onDeviceEdit(obj, src, ~)
            obj.P.device = src.Value;
            obj.savePrefs();
        end

        function onBatchEdit(obj, src, ~)
            obj.P.batchSize = src.Value;
            obj.savePrefs();
        end

        function onThrEdit(obj, src, ~)
            obj.P.threshold = src.Value;
            obj.savePrefs();
        end

        function onOverwriteChange(obj, ~, evt)
            % evt.NewValue is the selected uiradiobutton
            isOW = strcmp(evt.NewValue.Tag, 'overwriteRad');
            obj.P.overwrite = isOW;
            obj.savePrefs();
        end


        %% Callbacks: display & export options


        function onColormapChange(obj, src, ~)
            obj.P.colormapIdx = find(strcmp(src.Items, src.Value), 1);
            obj.savePrefs();
        end

        function onAutoContrastChange(obj, src, ~)
            obj.P.autoContrast = src.Value;
            obj.savePrefs();
        end

        function onSavePngChange(obj, src, ~)
            obj.P.savePng = src.Value;
            obj.savePrefs();
        end

        function onSaveLsmTifChange(obj, src, ~)
            obj.P.saveLsmTif = src.Value;
            obj.savePrefs();
        end

        function onDiagnosticChange(obj, src, ~)
            obj.P.diagnosticMode = src.Value;
            obj.savePrefs();
        end

        function onDotColorChange(obj, src, ~)
            obj.P.dotColorIdx = find(strcmp(src.Items, src.Value), 1);
            obj.savePrefs();
        end

        function onDotSizeChange(obj, src, ~)
            obj.P.dotSize = src.Value;
            obj.savePrefs();
        end


        %% Start / Stop


        function onStart(obj, ~, ~)
            set(obj.hFig, 'Pointer', 'watch');
            drawnow;
            pyExe    = strtrim(obj.hPyEdit.Value);

            if isempty(pyExe)
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                errordlg('Please specify a Python executable.', 'Missing Input');
                return;
            end

            if isempty(obj.detModels)
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                errordlg( ...
                    'No detection model found in the repository root (no subdirectory with best.pth).', ...
                    'No Model');
                return;
            end

            allFiles = obj.allAbsFiles;   % absolute paths set by doSearch
            if isempty(allFiles)
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                errordlg('No files to process. Use Search to locate image files first.', 'No Files');
                return;
            end

            % Disable UI immediately before any blocking operations
            obj.setUIEnable(false);
            obj.hStopBtn.Enable = false;
            drawnow;

            % --- Pre-flight: verify that hydra and torch are importable ---
            envStatus = obj.onTestEnv;
            if envStatus ~= 0
                obj.setUIEnable(true);
                obj.hStopBtn.Enable = false;
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                return;
            end

            % -----------------------------------------------------------

            selVals = obj.hFileList.Value;
            if isempty(selVals) || numel(selVals) == numel(allFiles)
                queue = allFiles;
            else
                selInd = ismember(obj.hFileList.Items, selVals);
                queue  = allFiles(selInd);
            end

            % --- Expand the selected files into a queue of per-page jobs ---
            obj.hProgressLabel.Text = 'Building job list ...';
            drawnow;
            jobs = obj.buildJobs(queue);
            if isempty(jobs)
                obj.setUIEnable(true);
                obj.hStartBtn.Enable = true;
                obj.hStopBtn.Enable  = false;
                obj.hProgressLabel.Text = 'Ready.';
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                return;
            end

            % Scratch directory for resized page images.
            obj.tmpDir = fullfile(tempdir, 'CellDiscovery');
            if ~isfolder(obj.tmpDir)
                try mkdir(obj.tmpDir); catch, end
            end

            obj.jobQueue      = jobs;
            obj.fileIdx       = 1;
            obj.stopRequested = false;
            obj.jProcess      = [];
            obj.jReader       = [];
            obj.preprocCache  = [];   % per-file preprocessing cache (lazy-filled)

            obj.setUIEnable(false);
            obj.hStopBtn.Enable = true;

            total = numel(jobs);
            obj.hProgressLabel.Text = sprintf('Starting — %d job(s) queued ...', total);
            set(obj.hFig, 'Pointer', 'watch');
            drawnow;

            fprintf('\n=== PNN Batch GUI: starting %d job(s) over %d file(s) ===\n', ...
                total, numel(queue));

            t = timer( ...
                'Period',        0.25, ...
                'ExecutionMode', 'fixedRate', ...
                'BusyMode',      'drop', ...
                'Tag',           'PNNBatchTimer', ...
                'TimerFcn',      @(~,~) obj.timerCallback());
            obj.timerObj = t;
            start(t);
        end

        function onStop(obj, ~, ~)
            obj.stopRequested = true;
            obj.hStopBtn.Enable = false;
            obj.hProgressLabel.Text = 'Stop requested — finishing current subprocess ...';
            fprintf('[STOP] Stop requested.\n');
        end


        %% Job-list construction


        function jobs = buildJobs(obj, files)
            % Expand a list of image files into a list of per-page jobs based on
            % the current per-page / preprocessing settings. Each job is one
            % (file, page) unit run through predict.py independently.
            jobs = {};

            mapData = obj.hPageTable.Data;   % only used in per-page mode

            for i = 1:numel(files)
                f = files{i};
                [fdir, stem, ext] = fileparts(f);
                if isempty(fdir), fdir = pwd; end
                nPages = CellToolkit.countPages(f);

                firstPageForFile = true;   % first accepted page row for this source file
                for r = 1:size(mapData, 1)
                    pg   = CellToolkit.parseNum(mapData{r,1}, 0);
                    detM = mapData{r,3};
                    if pg < 1, continue; end
                    if ~ischar(detM) || strcmp(detM, obj.SKIP_LABEL) || isempty(detM)
                        continue;   % page not assigned a detection model
                    end
                    if pg > nPages
                        % Single-page files therefore only ever match page 1.
                        fprintf('[SKIP] %s has %d page(s); skipping mapped page %d\n', ...
                            stem, nPages, pg);
                        continue;
                    end
                    rescM = mapData{r,4};
                    if ~ischar(rescM) || strcmp(rescM, obj.NONE_LABEL), rescM = ''; end

                    correctLSM = CellToolkit.parseLogical(mapData{r,5}, false);
                    bg = CellToolkit.parseNum(mapData{r,6}, 0);
                    rz = CellToolkit.parseNum(mapData{r,7}, 1);
                    if rz <= 0, rz = 1; end
                    snapOn = false;
                    if size(mapData, 2) >= 8
                        snapOn = CellToolkit.parseLogical(mapData{r,8}, false);
                    end
                    snapOpts = obj.resolveSnapOptionsForPage(pg);
                    job = CellDiscovery.makeJob( ...
                        f, fdir, stem, ext, mapData{r,2}, pg, nPages, true, detM, rescM, correctLSM, bg, rz, obj.P.lsmOptions, snapOn, snapOpts);
                    job.firstPage = firstPageForFile;
                    jobs{end+1} = job; %#ok<AGROW>
                    firstPageForFile = false;
                end
            end
        end


        %% Timer callback (main batch processing loop)


        function timerCallback(obj)
            if isempty(obj.hFig) || ~isvalid(obj.hFig), return; end

            total = numel(obj.jobQueue);

            %% Case A: stop requested, no active process — clean up
            if obj.stopRequested && isempty(obj.jProcess)
                fprintf('[STOP] Batch stopped by user after %d / %d job(s).\n', ...
                    max(obj.fileIdx - 1, 0), total);
                obj.batchCleanup();
                return;
            end

            %% Case B: active process — drain stdout, check for completion
            if ~isempty(obj.jProcess)
                CellDiscovery.echoLines(CellToolkit.drainReader(obj.jReader));

                done     = false;
                exitCode = 0;
                try
                    exitCode = obj.jProcess.exitValue();
                    done     = true;
                catch
                    % Process still running — return and wait for next tick
                end

                if done
                    % Block-drain anything still buffered after exit.
                    CellDiscovery.echoLines(CellToolkit.drainReader(obj.jReader, true));

                    job = obj.jobQueue{obj.fileIdx};
                    if exitCode == 0
                        fprintf('[DONE] (%d/%d) %s\n', obj.fileIdx, total, job.label);
                        try
                            obj.postProcess(job);
                        catch ME
                            fprintf(2,'[WARN] post-processing failed for %s: %s\n', ...
                                job.label, ME.message);
                        end
                    else
                        fprintf(2,'[FAIL] (%d/%d) exit code=%d  %s\n', ...
                            obj.fileIdx, total, exitCode, job.label);
                    end

                    CellToolkit.deleteFiles(job.tmpImg);   % drop scratch page image
                    CellToolkit.deleteFiles(job.tmpCsv);

                    obj.jProcess = [];
                    obj.jReader  = [];
                    obj.fileIdx  = obj.fileIdx + 1;

                    if obj.stopRequested
                        fprintf('[STOP] Batch stopped by user.\n');
                        obj.batchCleanup();
                    end
                end
                return;
            end

            %% Case C: no active process — launch the next job
            if obj.fileIdx > total
                fprintf('=== PNN Batch GUI: all %d job(s) complete ===\n\n', total);
                obj.batchCleanup();
                return;
            end

            job = obj.jobQueue{obj.fileIdx};

            overwrite = obj.hOverwriteRad.Value;
            if exist(job.outCsvOrig, 'file') && ~overwrite
                fprintf('[SKIP] (%d/%d) result exists, Ignore mode: %s\n', ...
                    obj.fileIdx, total, job.label);
                obj.hProgressLabel.Text = sprintf('Skipped %d / %d  (result exists)', obj.fileIdx, total);
                obj.fileIdx = obj.fileIdx + 1;
                return;
            end

            obj.hProgressLabel.Text = sprintf('Processing %d / %d:  %s', obj.fileIdx, total, job.label);
            drawnow;

            % --- Preprocess the whole file once (joint LSM), grab this page ---
            % Preprocessing is centralised: the entire channel stack is corrected
            % together (so LSM registration uses every channel) and cached, then
            % reused for every page's detection and for the output TIF.
            try
                obj.ensurePreprocCache(job.imgFile, job.nPages);
                img = obj.preprocCache.pages{job.page};
            catch ME
                fprintf(2,'[ERROR] (%d/%d) could not read/preprocess %s: %s\n', ...
                    obj.fileIdx, total, job.label, ME.message);
                obj.fileIdx = obj.fileIdx + 1;
                return;
            end

            tmpStem      = sprintf('job%04d_%s_p%d', obj.fileIdx, job.stem, job.page);
            tmpStem      = regexprep(tmpStem, '[^\w.-]', '_');   % filesystem-safe
            job.tmpImg   = fullfile(obj.tmpDir, [tmpStem '.tif']);
            job.tmpCsv   = fullfile(obj.tmpDir, [tmpStem '_loc.csv']);
            try
                CellDiscovery.writeScratchTiff(img, job.tmpImg);
            catch ME
                fprintf(2,'[ERROR] (%d/%d) could not write scratch image: %s\n', ...
                    obj.fileIdx, total, ME.message);
                obj.fileIdx = obj.fileIdx + 1;
                return;
            end
            obj.jobQueue{obj.fileIdx} = job;   % persist tmp paths for Case B

            device     = strtrim(obj.hDeviceEdit.Value);
            batchSize  = strtrim(obj.hBatchEdit.Value);
            threshold  = strtrim(obj.hThrEdit.Value);

            % Core predict.py arguments. predict.py runs on the resized
            % scratch image; coordinates are mapped back to original-image space
            % in postProcess. A blank/NaN threshold is omitted by
            % CellToolkit.predictArgs. Paths may contain spaces —
            % launchPythonAsync passes each token as a separate argument, so no
            % quoting is needed (conda-run wrapping is applied by the toolkit).
            %
            % Detection ONLY: Stage-2 rescoring (job.rescoreModel) is deferred
            % to postProcess so it runs AFTER snapToCellCentroid refinement,
            % letting the scoring model crop patches centred on the snapped
            % cell locations rather than the raw detected ones.
            predOpts = struct( ...
                'output',       job.tmpCsv, ...
                'device',       device, ...
                'batchSize',    batchSize, ...
                'threshold',    threshold);
            args = CellToolkit.predictArgs(job.detModel, job.tmpImg, predOpts);
            cfg  = obj.pythonCfg();

            fprintf('[RUN ] (%d/%d) %s\n', obj.fileIdx, total, job.label);
            fprintf('  CMD: %s\n', ...
                CellToolkit.commandString(CellToolkit.pythonCommandParts(cfg, args)));

            try
                [obj.jProcess, obj.jReader] = CellToolkit.launchPythonAsync(cfg, args);
            catch ME
                fprintf(2,'[ERROR] Could not start process: %s\n', ME.message);
                obj.fileIdx = obj.fileIdx + 1;
            end
        end


        %% Per-file post-processing: display + optional PNG export


        function postProcess(obj, job)
            % Read predict.py output (in resized/resized coordinates),
            % map detections back to original-image space, write the final
            % CSV(s), and render/optionally export the result figure.
            imgDir = job.imgDir;

            if ~exist(job.tmpCsv, 'file')
                fprintf('[WARN] Output CSV not found: %s\n', job.tmpCsv);
                return;
            end

            try
                locs = readtable(job.tmpCsv);
            catch ME
                fprintf('[WARN] Could not read CSV %s: %s\n', job.tmpCsv, ME.message);
                return;
            end
            nDets = height(locs);

            hasX = ismember('X', locs.Properties.VariableNames);
            hasY = ismember('Y', locs.Properties.VariableNames);
            hasRescore = ismember('rescore',locs.Properties.VariableNames);

            % Stamp the imgName column with the original (per-page) identity.
            if ismember('imgName', locs.Properties.VariableNames)
                locs.imgName = repmat({job.imgName}, nDets, 1);
            end

            % --- Build original-space + resized-space copies and write them ---
            f = job.resize;
            locsOrig = locs;
            if f ~= 1
                if hasX, locsOrig.X = locs.X / f; end
                if hasY, locsOrig.Y = locs.Y / f; end
            end

            % --- Optional localization refinement (snapToCellCentroid) ---------
            % Runs in original-image space on the preprocessed source-resolution
            % page (the same joint-LSM + background-subtracted pixels the
            % detector saw, minus the resize). Adds non-destructive
            % SNAP_X/Y/Shift/Snapped columns and, when configured, overwrites
            % X/Y with the snapped coordinates. Best effort: a snap failure
            % never blocks writing the detection CSV.
            %
            % Snapshot the pre-snap detection coordinates (original-image space)
            % so the diagnostic view can draw arrows from each original point to
            % its snapped location even when ApplyToXY overwrites X/Y below.
            diagFromX = []; diagFromY = [];
            if hasX && hasY
                diagFromX = locsOrig.X;
                diagFromY = locsOrig.Y;
            end
            if isfield(job, 'snapEnable') && job.snapEnable && nDets > 0 && hasX && hasY
                try
                    locsOrig = obj.applySnap(job, locsOrig);
                catch ME
                    fprintf('[WARN] Snap failed for %s: %s\n', job.label, ME.message);
                end
            end

            % --- Stage-2 rescoring (score.py), AFTER detection + snap ----------
            % Deferred out of the predict.py call so the scoring model crops its
            % 64x64 patches around the snapped (refined) cell centres. Scoring
            % runs on the resized detector-input scratch image at the training
            % pixel size, so applyRescore maps the snapped original-space
            % coordinates back into resized space. The computed scores populate
            % the 'rescore' column on both the original- and resized-coordinate
            % tables. Best effort: a scoring failure never blocks the CSV write.
            if isfield(job, 'rescoreModel') && ~isempty(job.rescoreModel) ...
                    && nDets > 0 && hasX && hasY
                try
                    rv = obj.applyRescore(job, locsOrig, f);
                catch ME
                    rv = [];
                    fprintf('[WARN] Rescore failed for %s: %s\n', job.label, ME.message);
                end
                if ~isempty(rv)
                    locsOrig.rescore = rv;
                    locs.rescore     = rv;
                    hasRescore       = true;
                end
            end

            try
                writetable(locsOrig, job.outCsvOrig);
                fprintf('[CSV ] Saved: %s\n', job.outCsvOrig);
            catch ME
                fprintf('[WARN] Could not write %s: %s\n', job.outCsvOrig, ME.message);
            end
            if f ~= 1 && ~isempty(job.outCsvResized)
                try
                    writetable(locs, job.outCsvResized);   % resized-image coordinates
                    fprintf('[CSV ] Saved: %s\n', job.outCsvResized);
                catch ME
                    fprintf('[WARN] Could not write %s: %s\n', job.outCsvResized, ME.message);
                end
            end

            % --- Record the detection (and any rescoring) in the dataset
            %     manifest (CellDatasetManifest) so the active analysis file,
            %     analyzed image/pages and provenance are the authoritative
            %     record every other Cell* tool reads. Best effort: never let
            %     manifest bookkeeping disrupt a batch run. ---
            try
                mf  = CellDatasetManifest.forImage(job.imgFile);
                key = CellDatasetManifest.keyForCsv(job.outCsvOrig);
                mf.recordDetection(key, struct('image', job.imgFile, ...
                    'page', job.page, 'locs', job.outCsvOrig, ...
                    'tool', 'CellDiscovery', 'model', job.detModel, 'count', nDets));
                if f ~= 1 && ~isempty(job.outCsvResized)
                    mf.recordResized(key, job.outCsvResized, job.outTif);
                end
                if ~isempty(job.rescoreModel) && hasRescore
                    mf.recordRescore(key, struct('tool', 'CellDiscovery', ...
                        'model', job.rescoreModel));
                end
                mf.save();
            catch
            end

            % --- Optionally save the resized image as TIF ---
            % Written once per source file (on the first job for that file).
            % All pages of the source file are resized using the page-map
            % settings for each page (falling back to no-op for unmapped pages)
            % so the output TIF has the same number of pages as the input TIF.
            if obj.hSaveLsmTif.Value && job.firstPage
                try
                    obj.writeFullPreprocTif(job);
                catch ME
                    fprintf('[WARN] TIF save failed for %s: %s\n', job.label, ME.message);
                end
            end

            cmapName     = obj.hColormapPop.Value;
            autoContrast = obj.hAutoContrast.Value;
            savePng      = obj.hSavePng.Value;
            dotColor     = obj.hDotColorPop.Value;
            dotSz        = str2double(obj.hDotSizeEdit.Value);
            if isnan(dotSz) || dotSz <= 0, dotSz = 15; end

            % --- Choose which image + coordinates to display ---
            showPreproc = obj.hDisplayPreprocChk.Value;
            plotsX = []; plotsY = [];
            try
                if showPreproc
                    img = imread(job.tmpImg);   % resized (resized) image
                    if hasX && hasY, plotsX = locs.X;     plotsY = locs.Y;     end
                else
                    img = CellToolkit.readPage(job.imgFile, job.page, job.nPages);
                    if hasX && hasY, plotsX = locsOrig.X; plotsY = locsOrig.Y; end
                end
            catch ME
                fprintf('[WARN] Could not load display image for %s: %s\n', job.label, ME.message);
                return;
            end

            if autoContrast
                if size(img, 3) == 1
                    img = imadjust(img);
                else
                    for c = 1:size(img, 3)
                        img(:,:,c) = imadjust(img(:,:,c));
                    end
                end
            end

            hResFig = findobj(0, 'Tag', 'PNNResultFig');
            if isempty(hResFig)
                hResFig = figure( ...
                    'Tag',         'PNNResultFig', ...
                    'Name',        'Detection Results', ...
                    'NumberTitle', 'off', ...
                    'Position',    [1340 80 900 720]);
            else
                hResFig = hResFig(1);
                figure(hResFig);
                clf(hResFig);
            end

            ax = axes('Parent', hResFig);
            imshow(img, [], 'Parent', ax);

            if size(img, 3) == 1
                try
                    colormap(ax, cmapName);
                catch
                    colormap(ax, 'gray');
                end
            end

            if hasRescore
                dotScore = locs.rescore;
            else
                dotScore = locs.score;
            end

            try
                dotCM = feval(dotColor,length(dotScore));
                [~,i] = sort(dotScore,'ascend');
                plotsX = plotsX(i);
                plotsY = plotsY(i);
            catch
                dotCM = dotColor;
            end

            hold(ax, 'on');
            if nDets > 0 && hasX && hasY
                scatter(ax, plotsX, plotsY, dotSz, dotCM, 'filled', ...
                    'MarkerFaceAlpha', 1, 'MarkerEdgeColor', 'none');
            end

            title(ax, strrep(job.label, '_', '\_'), ...
                'Interpreter', 'tex', 'FontSize', 10, 'FontWeight', 'bold');

            hasScore   = ismember('score',   locs.Properties.VariableNames);
            hasRescore = ismember('rescore', locs.Properties.VariableNames);
            if nDets > 0 && hasScore
                meanScore = mean(locs.score, 'omitnan');
                if hasRescore
                    meanRescore = mean(locs.rescore, 'omitnan');
                    statsStr = sprintf('N = %d  |  score = %.3f  |  rescore = %.3f', ...
                        nDets, meanScore, meanRescore);
                else
                    statsStr = sprintf('N = %d  |  mean score = %.3f', nDets, meanScore);
                end
            else
                statsStr = sprintf('N = %d', nDets);
            end

            text(ax, 0.01, 0.98, statsStr, ...
                'Units',               'normalized', ...
                'VerticalAlignment',   'top', ...
                'HorizontalAlignment', 'left', ...
                'FontSize',            10, ...
                'FontWeight',          'bold', ...
                'Color',               [1 1 0], ...
                'BackgroundColor',     [0 0 0], ...
                'Interpreter',         'none');
            hold(ax, 'off');
            drawnow;

            if savePng
                pngFile = fullfile(imgDir, [job.base '_locs.png']);
                saved   = false;
                if exist('exportgraphics', 'file')
                    try
                        exportgraphics(ax, pngFile, 'Resolution', 300);
                        saved = true;
                    catch
                    end
                end
                if ~saved
                    try
                        print(hResFig, pngFile, '-dpng', '-r300');
                        saved = true;
                    catch
                    end
                end
                if saved
                    fprintf('[PNG ] Saved: %s\n', pngFile);
                else
                    fprintf('[WARN] PNG save failed for: %s\n', job.label);
                end
            end

            % --- Optional diagnostic pause -------------------------------------
            % When Diagnostic mode is enabled, open a window showing the images
            % this page passed through (raw page, the preprocessed detector
            % input, and — when snap ran — the snap-input image with
            % original->snapped arrows) and block the batch until the user
            % continues or stops. Read live so the checkbox can be toggled
            % mid-run. Best effort — a diagnostic failure never disrupts the run.
            if ~isempty(obj.hDiagnosticChk) && isvalid(obj.hDiagnosticChk) ...
                    && obj.hDiagnosticChk.Value
                try
                    obj.diagnosticPause(job, locs, locsOrig, diagFromX, diagFromY);
                catch ME
                    fprintf('[WARN] Diagnostic display failed for %s: %s\n', ...
                        job.label, ME.message);
                end
            end
        end


        function diagnosticPause(obj, job, locs, locsOrig, diagFromX, diagFromY)
            % DIAGNOSTICPAUSE  Show the images this page passed through and block
            % the batch until the user continues or stops.
            %
            % Opens (and reuses) a diagnostic window with one axes per relevant
            % image:
            %   * Raw page        — the unprocessed input page
            %   * Detector input  — raw after LSM / background / resize (the
            %                       pixels predict.py saw), with detections
            %                       overlaid
            %   * Snap input      — (only when Snap ran) the source-resolution
            %                       preprocessed page snap operated on, with an
            %                       arrow from each original detection to its
            %                       snapped location
            %
            % Execution blocks in uiwait until the user clicks Continue (resume
            % the batch), Stop batch (request a stop, then resume so the timer
            % can wind down), or closes the window (treated as Continue).
            %
            %   locs        detections in resized (detector) coordinates
            %   locsOrig    detections in original-image coordinates, carrying any
            %               SNAP_* columns added by applySnap
            %   diagFromX/Y pre-snap detection coordinates (original space)

            % --- Gather the images used for processing / postprocessing ---
            raw = [];
            try raw = CellToolkit.readPage(job.imgFile, job.page, job.nPages); catch, end

            detImg = [];
            if ~isempty(obj.preprocCache) && isfield(obj.preprocCache, 'pages') ...
                    && job.page >= 1 && job.page <= numel(obj.preprocCache.pages)
                detImg = obj.preprocCache.pages{job.page};
            end
            if isempty(detImg)
                try detImg = imread(job.tmpImg); catch, end
            end

            snapRan = isfield(job, 'snapEnable') && job.snapEnable ...
                && ismember('SNAP_X', locsOrig.Properties.VariableNames);
            snapImg = [];
            if snapRan
                if ~isempty(obj.preprocCache) && isfield(obj.preprocCache, 'pagesFull') ...
                        && job.page >= 1 && job.page <= numel(obj.preprocCache.pagesFull)
                    snapImg = obj.preprocCache.pagesFull{job.page};
                end
                if isempty(snapImg), snapImg = raw; end
            end

            % --- Build / refresh the diagnostic figure ---
            hDiag = findobj(0, 'Tag', 'PNNDiagFig');
            if isempty(hDiag)
                hDiag = figure('Tag', 'PNNDiagFig', 'Name', 'Processing diagnostic', ...
                    'NumberTitle', 'off', 'Color', 'w', 'Position', [120 90 1180 760]);
            else
                hDiag = hDiag(1);
                figure(hDiag);
                clf(hDiag);
            end

            nPanels  = 2 + double(snapRan);
            cmapName = obj.hColormapPop.Value;

            uicontrol(hDiag, 'Style', 'text', 'Units', 'normalized', ...
                'Position', [0 0.94 1 0.05], 'BackgroundColor', 'w', ...
                'FontWeight', 'bold', 'FontSize', 12, 'String', job.label);

            % One row of equal-width axes, leaving the bottom strip for controls.
            margin = 0.035; gap = 0.03; aBottom = 0.14; aHeight = 0.76;
            aWidth = (1 - 2*margin - (nPanels-1)*gap) / nPanels;
            axPos  = @(k) [margin + (k-1)*(aWidth+gap), aBottom, aWidth, aHeight];

            % Panel 1 — raw page
            ax1 = axes('Parent', hDiag, 'Position', axPos(1));
            CellDiscovery.showDiagImage(ax1, raw, cmapName);
            title(ax1, 'Raw page', 'Interpreter', 'none');

            % Panel 2 — preprocessed image the detector saw
            ax2 = axes('Parent', hDiag, 'Position', axPos(2));
            CellDiscovery.showDiagImage(ax2, detImg, cmapName);
            title(ax2, sprintf('Detector input  (%s)', CellDiscovery.preprocSummary(job)), ...
                'Interpreter', 'none');
            if all(ismember({'X','Y'}, locs.Properties.VariableNames)) && height(locs) > 0
                hold(ax2, 'on');
                plot(ax2, locs.X, locs.Y, 'o', 'MarkerEdgeColor', [1 1 0], ...
                    'MarkerSize', 4, 'LineWidth', 0.5);
                hold(ax2, 'off');
            end

            % Panel 3 — snap input with original -> snapped arrows
            if snapRan
                nSnapped = 0;
                if ismember('SNAP_Snapped', locsOrig.Properties.VariableNames)
                    nSnapped = sum(logical(locsOrig.SNAP_Snapped));
                end
                ax3 = axes('Parent', hDiag, 'Position', axPos(3));
                CellDiscovery.showDiagImage(ax3, snapImg, cmapName);
                title(ax3, sprintf('Snap input (source res):  %d snapped, original \\rightarrow new', ...
                    nSnapped), 'Interpreter', 'tex');
                CellDiscovery.drawSnapArrows(ax3, diagFromX, diagFromY, locsOrig);
            end

            % --- Pause controls ---
            uicontrol(hDiag, 'Style', 'text', 'Units', 'normalized', ...
                'Position', [0.035 0.005 0.5 0.085], 'BackgroundColor', 'w', ...
                'HorizontalAlignment', 'left', 'FontSize', 9, ...
                'String', sprintf(['Diagnostic pause (page %d/%d).  Review the images, then ' ...
                'Continue or Stop.  Untick "Diagnostic mode" in the main window to stop pausing.'], ...
                job.page, job.nPages));
            uicontrol(hDiag, 'Style', 'pushbutton', 'Units', 'normalized', ...
                'Position', [0.59 0.02 0.18 0.07], 'FontWeight', 'bold', ...
                'String', 'Continue', 'Callback', @(~,~) uiresume(hDiag));
            uicontrol(hDiag, 'Style', 'pushbutton', 'Units', 'normalized', ...
                'Position', [0.79 0.02 0.18 0.07], 'ForegroundColor', [0.6 0 0], ...
                'String', 'Stop batch', 'Callback', @onStopDiag);
            % While paused, closing the window just continues (don't destroy the
            % reusable figure); restore normal close behaviour afterwards.
            hDiag.CloseRequestFcn = @(~,~) uiresume(hDiag);
            drawnow;
            uiwait(hDiag);
            if isvalid(hDiag)
                hDiag.CloseRequestFcn = 'closereq';
            end

            function onStopDiag(~, ~)
                obj.stopRequested = true;
                fprintf('[STOP] Stop requested from diagnostic window.\n');
                if isvalid(hDiag), uiresume(hDiag); end
            end
        end


        function s = resolveSnapOptionsForPage(obj, pageNum)
            % Resolve the stored snapToCellCentroid options for a page number,
            % falling back to defaults for any page that has not been configured.
            s   = CellDiscovery.defaultSnapOptions();
            key = sprintf('page%d', round(pageNum));
            if isstruct(obj.P.snapOptions) && isfield(obj.P.snapOptions, key) ...
                    && isstruct(obj.P.snapOptions.(key))
                s = CellDiscovery.sanitizeSnapOptions(obj.P.snapOptions.(key));
            end
        end

        function T = applySnap(obj, job, T)
            % Run snapToCellCentroid on a localization table (original-image
            % coordinates), returning the table with SNAP_X/Y/Shift/Snapped
            % columns added. When the page's ApplyToXY option is set, the
            % snapped coordinates overwrite X/Y for the points that moved.
            %
            % Snap operates on the preprocessed page at SOURCE resolution
            % (joint-LSM + background subtraction, no resize) — the same pixels
            % the detector saw apart from the resampling. Using the source
            % resolution keeps the table's coordinates and the snap PixelSize in
            % original-image space, so no resize remapping is needed.
            if exist('snapToCellCentroid', 'file') ~= 2
                fprintf('[WARN] snapToCellCentroid.m is not on the MATLAB path; skipping snap for %s.\n', job.label);
                return;
            end
            if ~all(ismember({'X','Y'}, T.Properties.VariableNames)) || height(T) == 0
                return;
            end

            opts    = CellDiscovery.sanitizeSnapOptions(job.snapOptions);
            args    = CellDiscovery.snapOptionsToNameValue(opts);
            applyXY = CellToolkit.parseLogical(opts.ApplyToXY, false);

            % Pull the preprocessed source-resolution page from the per-file
            % cache (recomputed only if the cache is not for this file). Fall
            % back to the raw page if, for any reason, the cache lacks it.
            snapImg = [];
            try
                obj.ensurePreprocCache(job.imgFile, job.nPages);
                if isfield(obj.preprocCache, 'pagesFull') ...
                        && job.page >= 1 && job.page <= numel(obj.preprocCache.pagesFull)
                    snapImg = obj.preprocCache.pagesFull{job.page};
                end
            catch
            end
            if isempty(snapImg)
                snapImg = CellToolkit.readPage(job.imgFile, job.page, job.nPages);
            end
            [T, info] = snapToCellCentroid(snapImg, T, args{:});

            if applyXY && ismember('SNAP_Snapped', T.Properties.VariableNames)
                sn = logical(T.SNAP_Snapped);
                if any(sn)
                    T.X(sn) = T.SNAP_X(sn);
                    T.Y(sn) = T.SNAP_Y(sn);
                end
            end

            applyTxt = CellToolkit.ternary(applyXY, ' (applied to X/Y)', ' (columns only)');
            fprintf('[SNAP] %s: %d / %d point(s) snapped%s\n', ...
                job.label, info.NumSnapped, info.NumPoints, applyTxt);
        end

        function rv = applyRescore(obj, job, locsOrig, f)
            % Run Stage-2 rescoring (score.py) AFTER detection and snap.
            % Returns an N-by-1 rescore vector aligned to locsOrig's rows, or []
            % on skip/failure (best effort: never blocks writing the CSV).
            %
            % Scoring crops 64x64 patches from the resized detector-input
            % scratch image (job.tmpImg) at the training pixel size, so the
            % (snapped) original-image coordinates are mapped back into resized
            % space (* the resize factor f). When snap ran, SNAP_X/SNAP_Y carry
            % the refined centres (snapped points moved, unsnapped points keep
            % their original location), so the model sees crops centred on the
            % best available cell location regardless of the ApplyToXY setting.
            rv = [];
            n  = height(locsOrig);
            if isempty(job.rescoreModel) || n == 0, return; end
            if exist(job.tmpImg, 'file') ~= 2
                fprintf('[WARN] Scratch image missing; skipping rescore for %s.\n', job.label);
                return;
            end

            % Effective scoring centres in original-image space.
            vn = locsOrig.Properties.VariableNames;
            if all(ismember({'SNAP_X','SNAP_Y'}, vn))
                ex = locsOrig.SNAP_X; ey = locsOrig.SNAP_Y;
            else
                ex = locsOrig.X;      ey = locsOrig.Y;
            end
            if ~isnumeric(ex), ex = str2double(string(ex)); end
            if ~isnumeric(ey), ey = str2double(string(ey)); end
            live = ~isnan(ex) & ~isnan(ey);
            keys = find(live);
            if isempty(keys), return; end

            % Write the score.py input. score.py consumes the first column as
            % the DataFrame index, derives integer crop centres from Yp/Xp, and
            % resolves imgName against --root. rescore_key rides through so the
            % score can be merged back onto the right rows afterwards.
            [~, imgStem, imgExt] = fileparts(job.tmpImg);
            nLive = numel(keys);
            inTbl = table();
            inTbl.idx         = (0:nLive-1)';
            inTbl.imgName     = repmat(string([imgStem imgExt]), nLive, 1);
            inTbl.Xp          = double(ex(live)) * f;   % original -> resized space
            inTbl.Yp          = double(ey(live)) * f;
            inTbl.rescore_key = keys;

            tmpInCsv = fullfile(obj.tmpDir, [imgStem '_scorein.csv']);
            tmpOut   = fullfile(obj.tmpDir, [imgStem '_scoreout.csv']);
            cleanup  = onCleanup(@() CellToolkit.deleteFiles({tmpInCsv, tmpOut})); %#ok<NASGU>
            writetable(inTbl, tmpInCsv);

            args = CellToolkit.scoreArgs(char(job.rescoreModel), tmpInCsv, struct( ...
                'root',      obj.tmpDir, ...
                'device',    strtrim(obj.hDeviceEdit.Value), ...
                'batchSize', strtrim(obj.hBatchEdit.Value), ...
                'output',    tmpOut));
            cfg = obj.pythonCfg();
            fprintf('[SCORE] %s\n  CMD: %s\n', job.label, ...
                CellToolkit.commandString(CellToolkit.pythonCommandParts(cfg, args)));
            [status, out] = CellToolkit.runPython(cfg, args);
            if status ~= 0 || exist(tmpOut, 'file') ~= 2
                fprintf(2, '[WARN] Rescore failed for %s (exit %d):\n%s\n', ...
                    job.label, status, out);
                return;
            end

            R   = readtable(tmpOut, 'VariableNamingRule', 'preserve');
            rvn = string(R.Properties.VariableNames);
            if ~all(ismember(["rescore_key","rescore"], rvn))
                fprintf(2, '[WARN] Rescore output missing expected columns for %s.\n', job.label);
                return;
            end
            rk = R.rescore_key; if ~isnumeric(rk), rk = str2double(string(rk)); end
            rs = R.rescore;     if ~isnumeric(rs), rs = str2double(string(rs)); end
            rv = nan(n, 1);
            ok = rk >= 1 & rk <= n;
            rv(rk(ok)) = rs(ok);
            fprintf('[SCORE] %s: rescored %d / %d point(s)\n', ...
                job.label, sum(~isnan(rv)), n);
        end

        function ensurePreprocCache(obj, imgFile, nPages)
            % Preprocess every page of imgFile exactly once and cache the result
            % on obj.preprocCache, keyed by file path. Both the per-page
            % detection scratch images and the optional output TIF draw from this
            % single cache, so the model and the saved TIF always see identical
            % pixels, and the expensive joint-channel LSM correction runs once.
            if ~isempty(obj.preprocCache) && isfield(obj.preprocCache, 'imgFile') ...
                    && strcmp(obj.preprocCache.imgFile, imgFile)
                return;   % cache already valid for this file
            end
            mapData                   = obj.hPageTable.Data;
            [pages, rzArr, pagesFull] = CellDiscovery.preprocessAllPages(imgFile, nPages, mapData, obj.P.lsmOptions);
            obj.preprocCache = struct('imgFile', imgFile, 'pages', {pages}, ...
                'rzArr', rzArr, 'pagesFull', {pagesFull});
        end

        function writeFullPreprocTif(obj, job)
            % Write a multi-page resized TIF whose page count matches the
            % source file, using the already-computed per-file cache so the saved
            % image is byte-identical to what the detection model received.
            obj.ensurePreprocCache(job.imgFile, job.nPages);
            pages  = obj.preprocCache.pages;
            rzArr  = obj.preprocCache.rzArr;
            nPages = numel(pages);

            fprintf('[TIF ] Writing %d-page resized TIF: %s\n', nPages, job.outTif);

            % All pages are written in a SINGLE Tiff session: open once, write
            % page 1, then writeDirectory() + write for each subsequent page,
            % then close. Re-opening the file per page (Tiff(...,'a')) is what
            % previously injected a corrupt empty IFD that truncated the stack
            % when read by ImageJ.
            t = Tiff(job.outTif, 'w');
            try
                for pg = 1:nPages
                    % Carry the source page's spatial calibration forward,
                    % scaling pixels-per-unit by the resize factor so the
                    % resized image reports the correct physical pixel size.
                    res = CellDiscovery.readPageResInfo(job.imgFile, pg);

                    if pg > 1
                        t.writeDirectory();   % start a new IFD in the same file
                    end
                    CellDiscovery.writeTiffPage(t, pages{pg}, res, rzArr(pg));
                end
                t.close();
            catch ME
                try t.close(); catch, end
                rethrow(ME);
            end
            fprintf('[TIF ] Saved: %s\n', job.outTif);
        end


        %% Batch cleanup: stop timer, kill process, re-enable UI


        function batchCleanup(obj)
            if isempty(obj.hFig) || ~isvalid(obj.hFig), return; end

            if ~isempty(obj.jProcess)
                try
                    obj.jProcess.destroyForcibly();
                    fprintf('[STOP] Subprocess terminated.\n');
                catch
                end
                obj.jProcess = [];
                obj.jReader  = [];
                % Remove scratch files for the job that was in flight.
                if obj.fileIdx >= 1 && obj.fileIdx <= numel(obj.jobQueue)
                    inflight = obj.jobQueue{obj.fileIdx};
                    CellToolkit.deleteFiles(inflight.tmpImg);
                    CellToolkit.deleteFiles(inflight.tmpCsv);
                end
            end

            if ~isempty(obj.timerObj) && isvalid(obj.timerObj)
                stop(obj.timerObj);
                delete(obj.timerObj);
            end
            obj.timerObj = [];
            obj.preprocCache = [];   % release cached resized pages

            if obj.stopRequested
                msg = sprintf('Stopped by user  (%d / %d job(s) processed).', ...
                    max(obj.fileIdx - 1, 0), numel(obj.jobQueue));
            else
                msg = sprintf('Complete — %d job(s) processed.', numel(obj.jobQueue));
            end
            obj.hProgressLabel.Text = msg;

            obj.setUIEnable(true);
            obj.hStopBtn.Enable  = false;
            obj.hStartBtn.Enable = true;
            set(obj.hFig, 'Pointer', 'arrow');
            drawnow;

        end


        %% Enable / disable all interactive controls


        function setUIEnable(obj, state)
            ctrls = { ...
                obj.hDirEdit,     obj.hRegexEdit,    obj.hPyEdit, ...
                obj.hCondaExeEdit, obj.hCondaEdit,   obj.hTestEnvBtn, ...
                obj.hDetList,     obj.hUseRescore,   obj.hRescoreList, ...
                obj.hDeviceEdit,  obj.hBatchEdit,    obj.hThrEdit, ...
                obj.hIgnoreRad,   obj.hOverwriteRad, ...
                obj.hColormapPop, obj.hAutoContrast,  obj.hSavePng, obj.hSaveLsmTif, ...
                obj.hDotColorPop, obj.hDotSizeEdit, ...
                obj.hPerPageChk,  obj.hAddPageBtn,   obj.hDelPageBtn, ...
                obj.hPreprocGlobalChk, obj.hGlobalBgEdit, obj.hGlobalResizeEdit, ...
                obj.hDisplayPreprocChk, obj.hLSMOptionsBtn, obj.hSnapOptionsBtn, obj.hPageTable, ...
                obj.hFileList,    obj.hStartBtn};
            for k = 1:numel(ctrls)
                try ctrls{k}.Enable = state; catch, end
            end
            if isequal(state, true) || isequal(state, 'on')
                obj.updateLSMOptionsButton();
                obj.updateSnapOptionsButton();
            end
        end


        %% Internal cleanup (timer + process only; no figure delete)


        function cleanup(obj)
            if ~isempty(obj.timerObj) && isvalid(obj.timerObj)
                stop(obj.timerObj);
                delete(obj.timerObj);
                obj.timerObj = [];
            end
            if ~isempty(obj.jProcess)
                try obj.jProcess.destroyForcibly(); catch, end
                obj.jProcess = [];
                obj.jReader  = [];
            end
        end

    end  % private methods

    %% ---- Static private helpers -----------------------------------------
    methods (Static, Access = private)

        function echoLines(lines)
            % Print each non-empty line drained from a subprocess reader to the
            % Command Window, matching the streaming format used for live output.
            for k = 1:numel(lines)
                if ~isempty(lines{k})
                    fprintf('  %s\n', lines{k});
                end
            end
        end

        function job = makeJob(f, fdir, stem, ext, suffix, pg, nPages, multiPage, detM, rescM, correctLSM, bg, rz, lsmOptions, snapEnable, snapOptions)
            % Assemble a single processing-job struct. Output filenames use a
            % per-page suffix only for genuine multi-page jobs.
            if nargin < 15, snapEnable = false; end
            if nargin < 16, snapOptions = CellDiscovery.defaultSnapOptions(); end
            if multiPage
                base    = sprintf('%s_%s%d', stem, suffix, pg);
                imgName = base;                              % identity in CSV
                label   = sprintf('%s  (page %d/%d)', stem, pg, nPages);
            else
                base    = stem;
                imgName = [stem ext];
                label   = stem;
            end

            job = struct();
            job.imgFile      = f;
            job.imgDir       = fdir;
            job.stem         = stem;
            job.base         = base;
            job.imgName      = imgName;
            job.page         = pg;
            job.nPages       = nPages;
            job.multiPage    = multiPage;
            job.detModel     = detM;
            job.rescoreModel = rescM;     % '' = no rescoring
            job.correctLSM   = logical(correctLSM);  % true = correct bidirectional LSM artifact
            job.lsmOptions   = CellDiscovery.sanitizeLSMOptions(lsmOptions);
            job.snapEnable   = logical(snapEnable);  % true = run snapToCellCentroid post-processing
            job.snapOptions  = CellDiscovery.sanitizeSnapOptions(snapOptions);
            job.bgRadius     = bg;        % 0 = no background subtraction
            job.resize       = rz;        % 1 = no resizing
            job.outCsvOrig   = fullfile(fdir, [base '_locs.csv']);
            job.outTif       = fullfile(fdir, [stem '_resized.tif']);   % shared across pages
            if rz ~= 1
                job.outCsvResized = fullfile(fdir, [base '_locs_resized.csv']);
            else
                job.outCsvResized = '';
            end
            job.tmpImg    = '';   % scratch page image (set at launch)
            job.tmpCsv    = '';   % predict.py raw output (set at launch)
            job.label     = label;
            job.firstPage = false;   % set by buildJobs: true for the first page of each source file
        end

        function img = applyPreprocess(img, correctLSM, lsmOptions, bgRadius, resizeFactor)
            % Optional preprocessing applied before detection:
            %   - bidirectional LSM line artifact correction
            %   - morphological background subtraction (imtophat, disk strel)
            %   - resize by a scalar factor
            % LSM correction runs first, then background subtraction at full
            % resolution, then resizing.
            if correctLSM
                if exist('correctBidirectionalLSMArtifact', 'file') ~= 2
                    error('correctBidirectionalLSMArtifact.m must be on the MATLAB path to use Correct LSM.');
                end
                img = CellDiscovery.callCorrectBidirectionalLSMArtifact(img, lsmOptions);
            end
            if bgRadius > 0
                se = strel('disk', round(bgRadius));
                if size(img, 3) == 1
                    img = imtophat(img, se);
                else
                    for c = 1:size(img, 3)
                        img(:,:,c) = imtophat(img(:,:,c), se);
                    end
                end
            end
            if resizeFactor > 0 && resizeFactor ~= 1
                img = imresize(img, resizeFactor, 'lanczos3', 'Antialiasing', true, 'Colormap', 'original', 'Dither', false);
            end
        end

        function lst = detChoiceList(detModels, skipLabel)
            % Dropdown choices for the page-map detection-model column.
            if isempty(detModels)
                lst = {skipLabel};
            else
                lst = [{skipLabel}, detModels];
            end
        end


        function opts = defaultLSMOptions()
            % Defaults for correctBidirectionalLSMArtifact name-value options.
            opts = struct( ...
                'ReverseRows', '"even"', ...
                'MaxDisplacement', '8', ...
                'NumIterations', '15', ...
                'PyramidDownsample', '[4 2 1]', ...
                'SmoothSigma', '4', ...
                'StepSize', '0.75', ...
                'UseAllChannels', 'true', ...
                'RegistrationChannel', '1', ...
                'ApplyGuidedFilter', 'false', ...
                'GuidedNeighborhoodSize', '[5 5]', ...
                'GuidedDegreeOfSmoothing', '0.01', ...
                'FillValue', 'NaN' ...
                );
        end

        function opts = sanitizeLSMOptions(opts)
            % Keep stored LSM options restricted to supported correction inputs.
            dflt = CellDiscovery.defaultLSMOptions();
            if ~isstruct(opts)
                opts = dflt;
                return;
            end
            names = fieldnames(dflt);
            clean = struct();
            for k = 1:numel(names)
                nm = names{k};
                if isfield(opts, nm) && ~isempty(opts.(nm))
                    clean.(nm) = opts.(nm);
                else
                    clean.(nm) = dflt.(nm);
                end
            end
            opts = clean;
        end

        function img = callCorrectBidirectionalLSMArtifact(img, opts)
            % Call correctBidirectionalLSMArtifact with persisted name-value
            % options.
            args = CellDiscovery.lsmOptionsToNameValue(opts);
            if isempty(args)
                img = correctBidirectionalLSMArtifact(img);
            else
                img = correctBidirectionalLSMArtifact(img, args{:});
            end
        end

        function args = lsmOptionsToNameValue(opts)
            opts = CellDiscovery.sanitizeLSMOptions(opts);
            names = fieldnames(opts);
            args = cell(1, 2*numel(names));
            for k = 1:numel(names)
                args{2*k-1} = names{k};
                args{2*k} = CellDiscovery.parseLSMOptionValue(opts.(names{k}));
            end
        end

        function v = parseLSMOptionValue(v)
            if isnumeric(v) || islogical(v)
                return;
            end
            if isstring(v)
                v = char(v);
            end
            if ~ischar(v)
                return;
            end
            txt = strtrim(v);
            low = lower(txt);
            if any(strcmp(low, {'true','false'}))
                v = strcmp(low, 'true');
                return;
            end
            num = str2num(txt); %#ok<ST2NM>
            if ~isempty(num)
                v = num;
                return;
            end
            if startsWith(txt, '"') && endsWith(txt, '"') && strlength(string(txt)) >= 2
                v = extractBetween(string(txt), 2, strlength(string(txt))-1);
                v = char(v);
            end
        end

        function txt = lsmOptionValueToText(v)
            if isnumeric(v) || islogical(v)
                txt = mat2str(v);
            elseif isstring(v)
                txt = char(v);
            elseif ischar(v)
                txt = v;
            else
                txt = char(string(v));
            end
        end

        function tip = lsmOptionTooltip(name, defaultValue)
            dflt = CellDiscovery.lsmOptionValueToText(defaultValue);
            switch lower(name)
                case 'reverserows'
                    desc = 'Rows scanned in the reverse direction and corrected. Use "even" or "odd".';
                case 'maxdisplacement'
                    desc = 'Maximum horizontal displacement in pixels.';
                case 'numiterations'
                    desc = 'Number of iterations per pyramid level.';
                case 'pyramiddownsample'
                    desc = 'Horizontal downsample factors, coarse to fine.';
                case 'smoothsigma'
                    desc = 'Gaussian smoothing sigma, in pixels, applied to the 1-D displacement after each update.';
                case 'stepsize'
                    desc = 'Update step size.';
                case 'useallchannels'
                    desc = 'If true, all channels drive registration. If false, only RegistrationChannel is used.';
                case 'registrationchannel'
                    desc = 'Channel used if UseAllChannels is false.';
                case 'applyguidedfilter'
                    desc = 'If true, apply imguidedfilter after geometric correction.';
                case 'guidedneighborhoodsize'
                    desc = 'Neighborhood size for imguidedfilter.';
                case 'guideddegreeofsmoothing'
                    desc = 'DegreeOfSmoothing for imguidedfilter.';
                case 'fillvalue'
                    desc = 'Value used outside image bounds during row warping. NaN triggers nearest-edge extrapolation.';
                otherwise
                    desc = sprintf('Name-value option passed to correctBidirectionalLSMArtifact: %s.', name);
            end
            tip = sprintf('%s Default: %s', desc, dflt);
        end

        function data = defaultPageMap()
            % One default page-map row. The empty detection-model cell is coerced
            % to the first real model by sanitizePageMap once models are known.
            data = {1, '', '(none)', '(none)', false, 0, 1, false};
        end

        function data = sanitizePageMap(data, detChoices, rescoreChoices)
            % Validate/repair saved page-map table data against the currently
            % available model lists, so a stale or malformed pref never breaks
            % the uitable (whose dropdown columns require valid members).
            if isempty(data) || ~iscell(data)
                data = CellDiscovery.defaultPageMap();
            elseif size(data, 2) == 6
                % Legacy (pre-LSM, pre-Snap): insert Correct LSM after Rescore
                % model, then append Snap.
                data = [data(:,1:4), repmat({false}, size(data,1), 1), data(:,5:6), ...
                        repmat({false}, size(data,1), 1)];
            elseif size(data, 2) == 7
                % Pre-Snap layout: append the Snap column.
                data = [data, repmat({false}, size(data,1), 1)];
            elseif size(data, 2) ~= 8
                data = CellDiscovery.defaultPageMap();
            end
            detFallback = detChoices{min(2, numel(detChoices))};   % first real model if any
            for r = 1:size(data, 1)
                % Page index
                p = CellToolkit.parseNum(data{r,1}, 1);
                if p < 1, p = 1; end
                data{r,1} = round(p);
                % Detection model (must be a valid dropdown member)
                % Suffix
                s = data{r,2};
                if ~ischar(s), s = sprintf('page%d',r); end
                data{r,2} = s;
                % Detection model (must be a valid dropdown member)
                v = data{r,3};
                if ~ischar(v) || ~ismember(v, detChoices), data{r,3} = detFallback; end
                % Rescore model
                v = data{r,4};
                if ~ischar(v) || ~ismember(v, rescoreChoices), data{r,4} = rescoreChoices{1}; end
                % Correct bidirectional LSM artifact
                data{r,5} = CellToolkit.parseLogical(data{r,5}, false);
                % Background radius (>= 0)
                b = CellToolkit.parseNum(data{r,6}, 0);
                if b < 0, b = 0; end
                data{r,6} = b;
                % Resize factor (> 0)
                z = CellToolkit.parseNum(data{r,7}, 1);
                if z <= 0, z = 1; end
                data{r,7} = z;
                % Snap (snapToCellCentroid post-processing)
                data{r,8} = CellToolkit.parseLogical(data{r,8}, false);
            end
        end

        function spec = snapOptionSpec()
            % Per-page snapToCellCentroid options exposed in the Snap dialog.
            % Columns: {name, kind, choices, default, tooltip}. 'kind' drives the
            % editor widget ('enum' dropdown, 'num'/'text' edit field, 'bool'
            % checkbox). Numeric/text values of 'auto' (or blank) fall back to
            % snapToCellCentroid's own cell-size presets. ApplyToXY is consumed
            % by CellDiscovery, not passed to snapToCellCentroid.
            spec = {
                'CellType',              'enum', {'auto','round','oval'},                                  'auto',   'Cell-shape preset: round (PV somata), oval (ring-like PNNs), or auto (balanced).'
                'Method',                'enum', {'auto','weighted-centroid','mean-shift','radial-symmetry'}, 'auto', 'auto picks from CellType (oval => radial-symmetry). radial-symmetry finds the centre of an open/ring-like net; weighted-centroid suits solid somata; mean-shift is threshold-free but lands on the bright wall.'
                'PixelSize',             'num',  {},                                                       '0.645',  'Microns per pixel (training resolution is 0.645).'
                'CellDiameter',          'num',  {},                                                       '18',     'Expected cell diameter in microns.'
                'BackgroundSubtraction', 'enum', {'tophat','gaussian','none'},                             'tophat', 'Global background removal before snapping.'
                'ThresholdMethod',       'enum', {'otsu','adaptive','relative'},                           'otsu',   'Per-window foreground threshold (weighted-centroid only).'
                'ThresholdScale',        'num',  {},                                                       '1.0',    'Multiplier on the Otsu threshold; <1 grows blobs, >1 shrinks them (weighted-centroid only).'
                'RingRadius',            'num',  {},                                                       'auto',   'Expected net ring radius in px, centre-to-wall (radial-symmetry). auto = ~half the cell diameter.'
                'RingRadiusTolerance',   'num',  {},                                                       'auto',   'Fractional ring-radius band voted over (radial-symmetry). auto = preset.'
                'DarkCenter',            'bool', {},                                                       'true',   'Bias the snap toward dark ring centres (radial-symmetry); on for PNN holes.'
                'SearchRadius',          'num',  {},                                                       'auto',   'Max distance (px) from a detection to an eligible centre. auto = from cell size.'
                'MaxShift',              'num',  {},                                                       'auto',   'Max distance (px) a detection may move. auto = SearchRadius.'
                'OverMaxShiftAction',    'enum', {'reject','clamp','keep'},                                'reject', 'What to do when the snap exceeds MaxShift.'
                'ApplyToXY',             'bool', {},                                                       'false',  'Overwrite X/Y with the snapped coordinates (SNAP_* columns are always added regardless).'
                };
        end

        function opts = defaultSnapOptions()
            % Default per-page snap options struct (string-valued, from the spec).
            spec = CellDiscovery.snapOptionSpec();
            opts = struct();
            for k = 1:size(spec, 1)
                opts.(spec{k,1}) = spec{k,4};
            end
        end

        function opts = sanitizeSnapOptions(opts)
            % Restrict a stored snap-options struct to the supported fields,
            % filling any missing/empty field from the defaults.
            dflt = CellDiscovery.defaultSnapOptions();
            if ~isstruct(opts)
                opts = dflt;
                return;
            end
            names = fieldnames(dflt);
            clean = struct();
            for k = 1:numel(names)
                nm = names{k};
                if isfield(opts, nm) && ~isempty(opts.(nm))
                    clean.(nm) = opts.(nm);
                else
                    clean.(nm) = dflt.(nm);
                end
            end
            opts = clean;
        end

        function args = snapOptionsToNameValue(opts)
            % Convert a snap-options struct into a name-value cell for
            % snapToCellCentroid. ApplyToXY is omitted (CellDiscovery handles it);
            % 'auto'/blank values are dropped so the function uses its presets.
            opts  = CellDiscovery.sanitizeSnapOptions(opts);
            spec  = CellDiscovery.snapOptionSpec();
            args  = {};
            for k = 1:size(spec, 1)
                nm = spec{k,1};
                if strcmp(nm, 'ApplyToXY'), continue; end
                [val, skip] = CellDiscovery.parseSnapOptionValue(opts.(nm));
                if skip, continue; end
                args = [args, {nm, val}]; %#ok<AGROW>
            end
        end

        function [val, skip] = parseSnapOptionValue(v)
            % Coerce a stored string option value to the type snapToCellCentroid
            % expects. 'auto' / '' signals "use the preset" (skip = true).
            val = []; skip = false;
            if isnumeric(v) || islogical(v)
                val = v; return;
            end
            if isstring(v), v = char(v); end
            if ~ischar(v)
                skip = true; return;
            end
            txt = strtrim(v);
            if isempty(txt) || strcmpi(txt, 'auto')
                skip = true; return;
            end
            low = lower(txt);
            if any(strcmp(low, {'true','false'}))
                val = strcmp(low, 'true'); return;
            end
            num = str2double(txt);
            if ~isnan(num)
                val = num; return;
            end
            num = str2num(txt); %#ok<ST2NM>
            if ~isempty(num)
                val = num; return;
            end
            val = txt;   % string-valued option (e.g. 'tophat', 'round', 'reject')
        end

        function lbl = snapPageLabel(pageNum, suffix)
            % Human-readable page-selector label for the Snap options dialog.
            if nargin >= 2 && ischar(suffix) && ~isempty(strtrim(suffix))
                lbl = sprintf('Page %d  (%s)', round(pageNum), strtrim(suffix));
            else
                lbl = sprintf('Page %d', round(pageNum));
            end
        end

        function [pages, rzArr, pagesFull] = preprocessAllPages(imgFile, nPages, mapData, lsmOptions)
            % Preprocess every page of a source file and return the finished
            % per-page images plus their resize factors.
            %
            % Two image sets are returned per page:
            %   pages     - joint-LSM + background-subtracted + RESIZED. This is
            %               exactly the input the detection model receives.
            %   pagesFull - the same preprocessing WITHOUT the final resize, i.e.
            %               at the source resolution. Snap (snapToCellCentroid)
            %               uses this so it sees the same pixels the detector did
            %               while keeping coordinates and PixelSize in
            %               original-image space (no resize remapping).
            %
            % LSM bidirectional correction is driven by ALL channels jointly
            % (correctBidirectionalLSMArtifact, UseAllChannels). Correcting each
            % page (single channel) in isolation makes the displacement field
            % unreliable wherever that one channel is dim, producing edge
            % artifacts (e.g. a dim green channel). So when any page requests LSM
            % correction, all same-size single-channel pages are stacked and
            % corrected together in one call — matching a full-stack manual run.
            % Background subtraction and resize are then applied per page (they
            % are channel-independent). Pages not listed in the map pass through
            % unmodified so the page count always matches the source file.

            % Build a lookup: page number -> row index in mapData.
            pageToRow = containers.Map('KeyType', 'int32', 'ValueType', 'int32');
            for r = 1:size(mapData, 1)
                pg = int32(CellToolkit.parseNum(mapData{r,1}, 0));
                if pg >= 1
                    pageToRow(pg) = int32(r);
                end
            end

            % Read all pages and resolve each page's preprocessing settings.
            rawPages = cell(1, nPages);
            wantLSM  = false(1, nPages);
            bgArr    = zeros(1, nPages);
            rzArr    = ones(1, nPages);
            for pg = 1:nPages
                rawPages{pg} = CellToolkit.readPage(imgFile, pg, nPages);
                if isKey(pageToRow, int32(pg))
                    r           = pageToRow(int32(pg));
                    wantLSM(pg) = CellToolkit.parseLogical(mapData{r,5}, false);
                    bgArr(pg)   = CellToolkit.parseNum(mapData{r,6}, 0);
                    rz          = CellToolkit.parseNum(mapData{r,7}, 1);
                    if rz <= 0, rz = 1; end
                    rzArr(pg)   = rz;
                end
            end

            % Joint-channel LSM correction (once for all LSM-requested pages).
            % Only pages that have wantLSM=true are corrected; others stay raw.
            % Stack only the LSM-requested pages so non-LSM pages are not
            % affected, then redistribute the corrected slices back by index.
            lsmIdx = find(wantLSM);   % indices of pages that want LSM
            corrPages = rawPages;     % start as copy; overwrite LSM pages below
            if ~isempty(lsmIdx)
                if exist('correctBidirectionalLSMArtifact', 'file') ~= 2
                    error('correctBidirectionalLSMArtifact.m must be on the MATLAB path to use Correct LSM.');
                end
                lsmRaws   = rawPages(lsmIdx);
                sameSize  = all(cellfun(@(im) isequal(size(im), size(lsmRaws{1})), lsmRaws));
                allSingle = all(cellfun(@(im) size(im, 3) == 1, lsmRaws));
                if numel(lsmIdx) > 1 && sameSize && allSingle
                    stack  = cat(3, lsmRaws{:});   % H x W x numel(lsmIdx) stack
                    Jstack = CellDiscovery.callCorrectBidirectionalLSMArtifact(stack, lsmOptions);
                    for k = 1:numel(lsmIdx)
                        corrPages{lsmIdx(k)} = Jstack(:,:,k);
                    end
                else
                    for k = 1:numel(lsmIdx)
                        corrPages{lsmIdx(k)} = CellDiscovery.callCorrectBidirectionalLSMArtifact(lsmRaws{k}, lsmOptions);
                    end
                end
            end

            % Per-page background subtraction (LSM already applied above), then
            % resize. pagesFull holds the bg-subtracted page at source
            % resolution; pages resizes it. Splitting the single applyPreprocess
            % call into "bg, then resize" yields pixels identical to the previous
            % combined call (order is unchanged: bg first, resize second) while
            % exposing the pre-resize image for snap.
            pages     = cell(1, nPages);
            pagesFull = cell(1, nPages);
            for pg = 1:nPages
                full          = CellDiscovery.applyPreprocess(corrPages{pg}, false, lsmOptions, bgArr(pg), 1);
                pagesFull{pg} = full;
                if rzArr(pg) > 0 && rzArr(pg) ~= 1
                    pages{pg} = CellDiscovery.applyPreprocess(full, false, lsmOptions, 0, rzArr(pg));
                else
                    pages{pg} = full;
                end
            end
        end

        function writeScratchTiff(img, path, createNew)
            % Write a single-page scratch TIFF.  The Tiff low-level class is used
            % instead of imwrite() so float32, uint8, uint16, int16, and uint32
            % source images are all handled correctly.  createNew is unused here
            % (scratch files are always single-page overwrites) but accepted so
            % callers with three arguments don't error.
            if isa(img, 'double')
                img = single(img);   % Tiff supports float32; float64 is exotic
            end
            t = Tiff(path, 'w');
            nCh = size(img, 3);

            phot = Tiff.Photometric.MinIsBlack; % assume this is always the case
            
            switch class(img)
                case 'single'
                    bps = 32;  sf = Tiff.SampleFormat.IEEEFP;
                case 'uint16'
                    bps = 16;  sf = Tiff.SampleFormat.UInt;
                case 'int16'
                    bps = 16;  sf = Tiff.SampleFormat.Int;
                case 'uint32'
                    bps = 32;  sf = Tiff.SampleFormat.UInt;
                otherwise   % uint8, logical, etc.
                    img = uint8(img);
                    bps = 8;   sf = Tiff.SampleFormat.UInt;
            end
            t.setTag('ImageLength',         size(img, 1));
            t.setTag('ImageWidth',          size(img, 2));
            t.setTag('Photometric',         phot);   % must precede SamplesPerPixel
            t.setTag('BitsPerSample',       bps);    % must precede SamplesPerPixel
            t.setTag('SamplesPerPixel',     nCh);
            t.setTag('SampleFormat',        sf);
            t.setTag('PlanarConfiguration', Tiff.PlanarConfiguration.Chunky);
            t.setTag('Compression',         Tiff.Compression.None);
            t.write(img);
            t.close();
        end

        function res = readPageResInfo(file, page)
            % Read a source page's spatial calibration so it can be propagated
            % to the resized output. Returns a struct with:
            %   hasRes  - true if XResolution/YResolution were present
            %   xres    - X resolution (pixels per ResolutionUnit), double
            %   yres    - Y resolution, double
            %   unit    - numeric ResolutionUnit Tiff code (1/2/3), [] if absent
            %   desc    - ImageDescription char (carries ImageJ unit=micron etc.)
            % All fields default to empty/false when the source has no tags.
            res = struct('hasRes', false, 'xres', [], 'yres', [], 'unit', [], 'desc', '');
            t = [];
            % Suppress libtiff warnings about unrecognised private tags (e.g.
            % ImageJ's IJMetadata tags 50838/50839) — they are harmless.
            warnState = warning('off', 'all');
            try
                t = Tiff(file, 'r');
                warning(warnState);
                if page > 1
                    t.setDirectory(page);   % Tiff directories are 1-based
                end
                try
                    res.xres   = double(t.getTag('XResolution'));
                    res.yres   = double(t.getTag('YResolution'));
                    res.hasRes = true;
                catch
                end
                try res.unit = t.getTag('ResolutionUnit'); catch, end
                try res.desc = t.getTag('ImageDescription'); catch, end
            catch
                warning(warnState);
            end
            if ~isempty(t)
                try t.close(); catch, end
            end
        end

        function writeTiffPage(t, img, res, rz)
            % Write one page (current IFD) into an already-open Tiff handle t.
            % res is from readPageResInfo; rz is the resize factor applied to
            % this page (pixels-per-unit scales by rz so the physical pixel
            % size of the resized image is reported correctly).
            if isa(img, 'double')
                img = single(img);
            end
            nCh = size(img, 3);
            if nCh == 3
                phot = Tiff.Photometric.RGB;
            else
                phot = Tiff.Photometric.MinIsBlack;
            end
            switch class(img)
                case 'single'
                    bps = 32;  sf = Tiff.SampleFormat.IEEEFP;
                case 'uint16'
                    bps = 16;  sf = Tiff.SampleFormat.UInt;
                case 'int16'
                    bps = 16;  sf = Tiff.SampleFormat.Int;
                case 'uint32'
                    bps = 32;  sf = Tiff.SampleFormat.UInt;
                otherwise
                    img = uint8(img);
                    bps = 8;   sf = Tiff.SampleFormat.UInt;
            end
            t.setTag('ImageLength',         size(img, 1));
            t.setTag('ImageWidth',          size(img, 2));
            t.setTag('Photometric',         phot);   % must precede SamplesPerPixel
            t.setTag('BitsPerSample',       bps);    % must precede SamplesPerPixel
            t.setTag('SamplesPerPixel',     nCh);
            t.setTag('SampleFormat',        sf);
            t.setTag('PlanarConfiguration', Tiff.PlanarConfiguration.Chunky);
            t.setTag('Compression',         Tiff.Compression.None);

            % Spatial calibration carried from the source page (scaled by resize)
            if nargin >= 3 && isstruct(res)
                if nargin < 4 || isempty(rz) || rz <= 0, rz = 1; end
                if res.hasRes
                    t.setTag('XResolution', res.xres * rz);
                    t.setTag('YResolution', res.yres * rz);
                    if ~isempty(res.unit)
                        t.setTag('ResolutionUnit', res.unit);
                    end
                end
                cleanDesc = CellDiscovery.sanitizeImageDescription(res.desc);
                if ~isempty(cleanDesc)
                    t.setTag('ImageDescription', cleanDesc);
                end
            end

            t.write(img);
        end

        function desc = sanitizeImageDescription(desc)
            % Strip ImageJ multi-image *stack-layout* fields from an
            % ImageDescription before it is written onto a re-encoded TIFF.
            %
            % ImageJ writes a stack header on the first page, e.g.:
            %   ImageJ=1.53k\nimages=2\nchannels=2\nslices=1\nhyperstack=true\n
            %   unit=micron\nspacing=1.0
            % The "images=N" field tells ImageJ/Fiji that the N pages are stored
            % CONTIGUOUSLY right after the first IFD, so it derives page 2+ as
            % offset0 + k*sliceBytes and ignores the per-page IFDs. MATLAB's Tiff
            % writer stores each page in its OWN IFD (non-contiguous), so carrying
            % that header makes ImageJ read page 2+ from a byte offset that is off
            % by the size of the intervening IFD — the page appears shifted to the
            % right. (MATLAB's own imread honours the IFDs and is unaffected,
            % which is why the corruption only shows in ImageJ.)
            %
            % We drop the stack-layout fields while keeping calibration lines
            % (unit, spacing, ...) so physical units survive. Non-ImageJ
            % descriptions are returned unchanged.
            if isempty(desc), desc = ''; return; end
            if isstring(desc), desc = char(desc); end
            if ~ischar(desc) || ~contains(desc, 'ImageJ='), return; end
            lines = regexp(desc, '\r?\n', 'split');
            drop  = {'images', 'channels', 'slices', 'frames', 'hyperstack', 'mode', 'loop'};
            keep  = true(1, numel(lines));
            for k = 1:numel(lines)
                ln = strtrim(lower(lines{k}));
                for d = 1:numel(drop)
                    if startsWith(ln, [drop{d} '='])
                        keep(k) = false;
                        break;
                    end
                end
            end
            desc = strjoin(lines(keep), newline);
        end


        %% Diagnostic-view helpers


        function showDiagImage(ax, img, cmapName)
            % Display a (possibly multi-channel) diagnostic image with a robust
            % 1-99 percentile contrast stretch so dim fluorescence is visible.
            if isempty(img)
                axis(ax, 'off');
                text(ax, 0.5, 0.5, '(image unavailable)', 'Units', 'normalized', ...
                    'HorizontalAlignment', 'center', 'Color', [0.5 0.5 0.5]);
                return;
            end
            if size(img, 3) == 1
                [lo, hi] = CellDiscovery.robustRange(img);
                imshow(img, [lo hi], 'Parent', ax);
                try colormap(ax, cmapName); catch, colormap(ax, 'gray'); end
            else
                imshow(CellDiscovery.normalizeRGBForDisplay(img), 'Parent', ax);
            end
        end

        function [lo, hi] = robustRange(img)
            % 1st/99th percentile of the finite pixels (no Statistics Toolbox
            % dependency), used as a display range for the diagnostic view.
            v = double(img(:));
            v = v(isfinite(v));
            if isempty(v)
                lo = 0; hi = 1; return;
            end
            sv = sort(v);
            lo = sv(max(1, round(0.01 * numel(sv))));
            hi = sv(max(1, round(0.99 * numel(sv))));
            if hi <= lo, hi = lo + 1; end
        end

        function rgb = normalizeRGBForDisplay(img)
            % Per-channel robust normalization of a multi-channel image to [0,1].
            rgb = zeros(size(img));
            for c = 1:size(img, 3)
                ch = double(img(:,:,c));
                [lo, hi] = CellDiscovery.robustRange(ch);
                rgb(:,:,c) = min(max((ch - lo) / (hi - lo), 0), 1);
            end
        end

        function s = preprocSummary(job)
            % One-line summary of the preprocessing steps applied to a job's
            % page, used as the Detector-input panel subtitle.
            parts = {};
            if isfield(job, 'correctLSM') && job.correctLSM
                parts{end+1} = 'LSM';
            end
            if isfield(job, 'bgRadius') && job.bgRadius > 0
                parts{end+1} = sprintf('bg=%g', job.bgRadius);
            end
            if isfield(job, 'resize') && job.resize ~= 1
                parts{end+1} = sprintf('resize=%g', job.resize);
            end
            if isempty(parts)
                s = 'no preprocessing';
            else
                s = strjoin(parts, ', ');
            end
        end

        function drawSnapArrows(ax, fromX, fromY, T)
            % Overlay snapToCellCentroid movement on the snap-input axes: an
            % arrow from each original detection to its snapped location, with
            % original points in red, snapped points in green, and unmoved
            % points in grey.
            vn = T.Properties.VariableNames;
            if isempty(fromX) || ~all(ismember({'SNAP_X','SNAP_Y'}, vn))
                return;
            end
            fromX = double(fromX(:));
            fromY = double(fromY(:));
            toX   = double(T.SNAP_X);
            toY   = double(T.SNAP_Y);
            if ismember('SNAP_Snapped', vn)
                moved = logical(T.SNAP_Snapped);
            else
                moved = (toX ~= fromX) | (toY ~= fromY);
            end
            n = min([numel(fromX), numel(toX), numel(moved)]);
            if n == 0, return; end
            fromX = fromX(1:n); fromY = fromY(1:n);
            toX = toX(1:n); toY = toY(1:n); moved = logical(moved(1:n));

            hold(ax, 'on');
            if any(~moved)
                plot(ax, fromX(~moved), fromY(~moved), 'o', ...
                    'MarkerEdgeColor', [0.6 0.6 0.6], 'MarkerSize', 5);
            end
            if any(moved)
                quiver(ax, fromX(moved), fromY(moved), ...
                    toX(moved) - fromX(moved), toY(moved) - fromY(moved), 0, ...
                    'Color', [1 0.3 0.3], 'LineWidth', 1, 'MaxHeadSize', 0.6, ...
                    'AutoScale', 'off');
                plot(ax, fromX(moved), fromY(moved), 'o', ...
                    'MarkerEdgeColor', [1 0.2 0.2], 'MarkerSize', 5, 'LineWidth', 1);
                plot(ax, toX(moved), toY(moved), 'o', ...
                    'MarkerFaceColor', [0.2 1 0.2], 'MarkerEdgeColor', 'none', ...
                    'MarkerSize', 5);
            end
            hold(ax, 'off');
        end

    end  % static methods

end  % classdef CellDiscovery