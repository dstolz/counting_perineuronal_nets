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
    %     - Full predict.py argument exposure (device, batch-size, threshold)
    %     - Real-time stdout/stderr streaming to the MATLAB Command Window
    %     - Stop button that kills the active Python subprocess
    %     - Per-file CSV output placed next to the source image:
    %         <image_stem>[_page<k>]_locs.csv
    %       When resizing is used, a second CSV in resized-image coordinates
    %       is also written: <image_stem>[_page<k>]_locs_resized.csv
    %     - Result figure with colormap, auto-contrast, scatter overlay,
    %       stats annotation; figure is reused across files. The raw page or
    %       the preprocessed image may be shown (user-selectable).
    %     - Optional PNG export of the annotated result
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
        hDisplayPreprocChk      % show preprocessed image instead of raw page
        hLSMOptionsBtn          % edit advanced bidirectional LSM correction options
        hSaveLsmTif             % save final preprocessed image as TIF alongside CSV
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
        tmpDir        = ''      % scratch dir for preprocessed page images
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

            obj.repoRoot = CellDiscovery.detectRepoRoot();
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
                'condaExe',        CellDiscovery.detectConda(), ...
                'condaEnv',        '', ...
                'device',          'cpu', ...
                'batchSize',       '1', ...
                'threshold',       '', ...
                'overwrite',       0, ...
                'colormapIdx',     1, ...
                'autoContrast',    true, ...
                'savePng',         false, ...
                'saveLsmTif',      false, ...
                'dotColorIdx',     1, ...
                'dotSize',         '5', ...
                'displayPreproc',  false, ...
                'lsmOptions',      CellDiscovery.defaultLSMOptions(), ...
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
            d       = dir(obj.repoRoot);
            subdirs = {d([d.isdir]).name};
            subdirs = subdirs(~ismember(subdirs, {'.', '..'}));

            obj.detModels     = {};
            obj.rescoreModels = {};
            for k = 1:numel(subdirs)
                if exist(fullfile(obj.repoRoot, subdirs{k}, 'best.pth'), 'file')
                    if ~isempty(regexpi(subdirs{k}, 'fasterrcnn', 'once'))
                        obj.detModels{end+1} = subdirs{k};
                    else
                        obj.rescoreModels{end+1} = subdirs{k}; 
                    end
                end
            end
            obj.detModels     = sort(obj.detModels);
            obj.rescoreModels = sort(obj.rescoreModels);
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

            lbl = uilabel(gMP, ...
                'Text', 'Map a detection (and optional rescore) model to each TIFF page.', ...
                'HorizontalAlignment', 'left', 'FontColor', [0.45 0.45 0.45], 'FontSize', 11);
            lbl.Layout.Row = 1; lbl.Layout.Column = [6 8];

            % --- Row 2: preprocessing controls ---
            obj.hDisplayPreprocChk = uicheckbox(gMP, ...
                'Text', 'Show preprocessed image in results (default: raw page)', ...
                'Value', logical(obj.P.displayPreproc), 'Tag', 'displayPreprocChk', ...
                'Tooltip', ['When on, the result figure/PNG show the preprocessed image the model saw ' ...
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
                'ColumnName',    {'Page','Suffix', 'Detection Model', 'Rescore Model', 'Correct LSM', 'Bg radius', 'Resize x'}, ...
                'ColumnFormat',  {'numeric', 'char', detChoices, rescoreChoices, 'logical', 'numeric', 'numeric'}, ...
                'ColumnEditable', [true true true true true true true], ...
                'ColumnWidth',   {50, 70, 220, 300, 80, 80, 70}, ...
                'RowName',       {}, ...
                'Tag',           'pageTable', ...
                'CellEditCallback',      @obj.onPageTableEdit, ...
                'CellSelectionCallback', @obj.onPageTableSelect);
            obj.hPageTable.Layout.Row = 3; obj.hPageTable.Layout.Column = [1 8];
            obj.updateLSMOptionsButton();

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
            gDisp = uigridlayout(pDisp, [4 8]);
            gDisp.Padding       = [6 6 6 6];
            gDisp.RowSpacing    = 4;
            gDisp.ColumnSpacing = 4;
            gDisp.RowHeight     = {22, 22, 20};
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
                'Text', 'Save final preprocessed image as TIF alongside each result CSV', ...
                'Value', logical(obj.P.saveLsmTif), 'Tag', 'saveLsmTif', ...
                'Tooltip', ['Exports  <stem>_preprocessed.tif  in the image subdirectory. ' ...
                'Saves the image after LSM correction, background subtraction, and resize — ' ...
                'the exact image the detection model received.'], ...
                'ValueChangedFcn', @obj.onSaveLsmTifChange);
            obj.hSaveLsmTif.Layout.Row = 3; obj.hSaveLsmTif.Layout.Column = [1 8];

            lbl = uilabel(gDisp, ...
                'Text', 'Display: raw page (or preprocessed image, see above) with detections overlaid; window is reused across pages', ...
                'HorizontalAlignment', 'left', 'FontColor', [0.45 0.45 0.45], 'FontSize', 11);
            lbl.Layout.Row = 4; lbl.Layout.Column = [1 8];

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

            allFiles = CellDiscovery.recDir(rootDir);

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
                relFiles = cellfun(@(f) CellDiscovery.makeRelPath(f, rootDir), ...
                    allFiles, 'UniformOutput', false);
            else
                relFiles = {};
            end
            obj.hFileList.Items = relFiles;
            obj.allAbsFiles = allFiles;
            obj.hFileCountLabel.Text      = sprintf('%d file%s found', n, CellDiscovery.ternary(n == 1, '', 's'));
            obj.hFileCountLabel.FontColor = CellDiscovery.ternary(n > 0, [0.1 0.45 0.1], [0.6 0.4 0]);
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
            obj.doSearch();
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

        function envStatus = onTestEnv(obj, ~, ~)
            % Run a quick synchronous check that Python + required modules are importable.
            pyExe    = strtrim(obj.hPyEdit.Value);
            condaExe = strtrim(obj.hCondaExeEdit.Value);
            condaEnv = strtrim(obj.hCondaEdit.Value);


            obj.hProgressLabel.Text = 'Checking Python environment ...';
            drawnow;
            fprintf('[CHECK] Verifying Python environment ...\n');

            testCode = "import hydra, torch; print('OK')";
            if ~isempty(condaEnv)
                if isempty(condaExe)
                    errordlg(['Conda env name is set but the conda executable path is empty.' newline ...
                        'Browse for conda.exe / conda.bat in the Python Environment panel.'], ...
                        'conda not configured');
                    return;
                end
                testCmd = sprintf('"%s" run --no-capture-output -n %s %s -c "%s"', ...
                    condaExe, condaEnv, pyExe, testCode);
            else
                testCmd = sprintf('"%s" -c "%s"', pyExe, testCode);
            end
            [envStatus, envOut] = system(testCmd);
            envOut = strtrim(envOut);
            if envStatus == 0
                fprintf('[TEST] PASS: %s\n', envOut);
                obj.hProgressLabel.Text = ['Environment OK: ' envOut];
            else
                fprintf('[TEST] FAIL (exit %d):\n%s\n', envStatus, envOut);
                obj.hProgressLabel.Text = sprintf('Environment test FAILED (exit %d) — see Command Window', envStatus);
            end


            if envStatus ~= 0 || ~contains(envOut, 'OK')
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
                return;
            end
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
                pages    = cellfun(@(x) CellDiscovery.parseNum(x, 0), data(:,1));
                nextPage = max(pages) + 1;
            end
            defDet = detChoices{min(2, numel(detChoices))};   % first real model if any, else (skip)
            newRow = {nextPage, sprintf('page%d',nextPage), defDet, obj.NONE_LABEL, false, 0, 1};
            obj.hPageTable.Data = [data; newRow];
            obj.P.pageMapData   = obj.hPageTable.Data;
            obj.updateLSMOptionsButton();
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
            obj.savePrefs();
        end

        function onPageTableEdit(obj, ~, ~)
            obj.P.pageMapData = obj.hPageTable.Data;
            obj.updateLSMOptionsButton();
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
                    useLSM = useLSM || CellDiscovery.parseLogical(data{r,5}, false);
                end
            end
            if useLSM
                obj.hLSMOptionsBtn.Enable = 'on';
            else
                obj.hLSMOptionsBtn.Enable = 'off';
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
            pyExe    = strtrim(obj.hPyEdit.Value);

            if isempty(pyExe)
                errordlg('Please specify a Python executable.', 'Missing Input');
                return;
            end

            if isempty(obj.detModels)
                errordlg( ...
                    'No detection model found in the repository root (no subdirectory with best.pth).', ...
                    'No Model');
                return;
            end

            allFiles = obj.allAbsFiles;   % absolute paths set by doSearch
            if isempty(allFiles)
                errordlg('No files to process. Use Search to locate image files first.', 'No Files');
                return;
            end

            % --- Pre-flight: verify that hydra and torch are importable ---
            envStatus = obj.onTestEnv;
            if envStatus ~= 0, return; end

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
                return;
            end

            % Scratch directory for preprocessed page images.
            obj.tmpDir = fullfile(tempdir, 'CellDiscovery');
            if ~isfolder(obj.tmpDir)
                try mkdir(obj.tmpDir); catch, end
            end

            obj.jobQueue      = jobs;
            obj.fileIdx       = 1;
            obj.stopRequested = false;
            obj.jProcess      = [];
            obj.jReader       = [];

            obj.setUIEnable(false);
            obj.hStopBtn.Enable = true;

            total = numel(jobs);
            obj.hProgressLabel.Text = sprintf('Starting — %d job(s) queued ...', total);
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
                nPages = CellDiscovery.countPages(f);

                for r = 1:size(mapData, 1)
                    pg   = CellDiscovery.parseNum(mapData{r,1}, 0);
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

                    correctLSM = CellDiscovery.parseLogical(mapData{r,5}, false);
                    bg = CellDiscovery.parseNum(mapData{r,6}, 0);
                    rz = CellDiscovery.parseNum(mapData{r,7}, 1);
                    if rz <= 0, rz = 1; end
                    jobs{end+1} = CellDiscovery.makeJob( ...
                        f, fdir, stem, ext, mapData{r,2}, pg, nPages, true, detM, rescM, correctLSM, bg, rz, obj.P.lsmOptions); %#ok<AGROW>
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
                try
                    while obj.jReader.ready()
                        line = obj.jReader.readLine();
                        if isequal(line, []), break; end
                        lineStr = char(line);
                        if ~isempty(lineStr)
                            fprintf('  %s\n', lineStr);
                        end
                    end
                catch
                end

                done     = false;
                exitCode = 0;
                try
                    exitCode = obj.jProcess.exitValue();
                    done     = true;
                catch
                    % Process still running — return and wait for next tick
                end

                if done
                    try
                        line = obj.jReader.readLine();
                        while ~isequal(line, [])
                            lineStr = char(line);
                            if ~isempty(lineStr)
                                fprintf('  %s\n', lineStr);
                            end
                            line = obj.jReader.readLine();
                        end
                    catch
                    end

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

                    CellDiscovery.deleteFileQuiet(job.tmpImg);   % drop scratch page image
                    CellDiscovery.deleteFileQuiet(job.tmpCsv);

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

            % --- Read + preprocess the requested page into a scratch image ---
            try
                img = CellDiscovery.readPage(job.imgFile, job.page, job.nPages);
                img = CellDiscovery.applyPreprocess(img, job.correctLSM, job.lsmOptions, job.bgRadius, job.resize);
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

            pyExe      = strtrim(obj.hPyEdit.Value);
            condaEnv   = strtrim(obj.hCondaEdit.Value);
            device     = strtrim(obj.hDeviceEdit.Value);
            batchSize  = strtrim(obj.hBatchEdit.Value);
            threshold  = strtrim(obj.hThrEdit.Value);

            % Core predict.py arguments (paths may contain spaces — ProcessBuilder
            % passes each element as a separate argument, so no quoting is needed).
            % predict.py runs on the preprocessed scratch image; coordinates are
            % mapped back to original-image space in postProcess.
            predictArgs = {pyExe, 'predict.py', job.detModel, job.tmpImg, ...
                '--output',     job.tmpCsv, ...
                '--device',     device, ...
                '--batch-size', batchSize};

            if ~isempty(threshold) && ~isnan(str2double(threshold))
                predictArgs = [predictArgs, {'--threshold', threshold}];
            end

            if ~isempty(job.rescoreModel)
                predictArgs = [predictArgs, {'--rescore', job.rescoreModel}];
            end

            condaExe   = strtrim(obj.hCondaExeEdit.Value);

            % Prepend 'conda run' when a named env is specified.
            % --no-capture-output is required for real-time stdout streaming.
            % Use the full path to conda.exe so MATLAB's PATH doesn't matter.
            if ~isempty(condaEnv)
                cmdParts = [{condaExe, 'run', '--no-capture-output', '-n', condaEnv}, predictArgs];
            else
                cmdParts = predictArgs;
            end

            fprintf('[RUN ] (%d/%d) %s\n', obj.fileIdx, total, job.label);
            fprintf('  CMD: %s\n', strjoin(CellDiscovery.quotedArgs(cmdParts), ' '));

            try
                n    = numel(cmdParts);
                jCmd = javaArray('java.lang.String', n);
                for k = 1:n
                    jCmd(k) = java.lang.String(cmdParts{k});
                end
                pb = java.lang.ProcessBuilder(jCmd);
                pb.directory(java.io.File(obj.repoRoot));
                pb.redirectErrorStream(true);
                proc   = pb.start();
                reader = java.io.BufferedReader( ...
                    java.io.InputStreamReader(proc.getInputStream()));
                obj.jProcess = proc;
                obj.jReader  = reader;
            catch ME
                fprintf(2,'[ERROR] Could not start process: %s\n', ME.message);
                obj.fileIdx = obj.fileIdx + 1;
            end
        end


        %% Per-file post-processing: display + optional PNG export


        function postProcess(obj, job)
            % Read predict.py output (in preprocessed/resized coordinates),
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

            % --- Optionally save the preprocessed image as TIF ---
            if obj.hSaveLsmTif.Value
                tifFile = fullfile(imgDir, [job.base '_preprocessed.tif']);
                try
                    preprocImg = imread(job.tmpImg);
                    CellDiscovery.writeScratchTiff(preprocImg, tifFile);
                    fprintf('[TIF ] Saved: %s\n', tifFile);
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
                    img = imread(job.tmpImg);   % preprocessed (resized) image
                    if hasX && hasY, plotsX = locs.X;     plotsY = locs.Y;     end
                else
                    img = CellDiscovery.readPage(job.imgFile, job.page, job.nPages);
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
                    CellDiscovery.deleteFileQuiet(inflight.tmpImg);
                    CellDiscovery.deleteFileQuiet(inflight.tmpCsv);
                end
            end

            if ~isempty(obj.timerObj) && isvalid(obj.timerObj)
                stop(obj.timerObj);
                delete(obj.timerObj);
            end
            obj.timerObj = [];

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
                obj.hDisplayPreprocChk, obj.hLSMOptionsBtn, obj.hPageTable, ...
                obj.hFileList,    obj.hStartBtn};
            for k = 1:numel(ctrls)
                try ctrls{k}.Enable = state; catch, end
            end
            if isequal(state, true) || isequal(state, 'on')
                obj.updateLSMOptionsButton();
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

        function condaExe = detectConda()
            % Auto-detect the conda executable on Windows from common install
            % locations. Returns 'conda' (bare name) if nothing is found, which
            % works when the user has conda on their PATH.
            candidates = { ...
                fullfile(getenv('USERPROFILE'), 'miniconda3',  'Scripts', 'conda.exe'), ...
                fullfile(getenv('USERPROFILE'), 'miniconda3',  'condabin', 'conda.bat'), ...
                fullfile(getenv('USERPROFILE'), 'anaconda3',   'Scripts', 'conda.exe'), ...
                fullfile(getenv('USERPROFILE'), 'anaconda3',   'condabin', 'conda.bat'), ...
                fullfile(getenv('LOCALAPPDATA'), 'miniconda3', 'Scripts', 'conda.exe'), ...
                fullfile(getenv('LOCALAPPDATA'), 'miniconda3', 'condabin', 'conda.bat'), ...
                fullfile(getenv('LOCALAPPDATA'), 'anaconda3',  'Scripts', 'conda.exe'), ...
                fullfile(getenv('LOCALAPPDATA'), 'anaconda3',  'condabin', 'conda.bat'), ...
                'C:\ProgramData\miniconda3\Scripts\conda.exe', ...
                'C:\ProgramData\miniconda3\condabin\conda.bat', ...
                'C:\ProgramData\anaconda3\Scripts\conda.exe', ...
                'C:\ProgramData\anaconda3\condabin\conda.bat' ...
                };
            for k = 1:numel(candidates)
                if exist(candidates{k}, 'file')
                    condaExe = candidates{k};
                    return;
                end
            end
            condaExe = '';   % not found; leave blank so user browses
        end

        function job = makeJob(f, fdir, stem, ext, suffix, pg, nPages, multiPage, detM, rescM, correctLSM, bg, rz, lsmOptions)
            % Assemble a single processing-job struct. Output filenames use a
            % per-page suffix only for genuine multi-page jobs.
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
            job.bgRadius     = bg;        % 0 = no background subtraction
            job.resize       = rz;        % 1 = no resizing
            job.outCsvOrig   = fullfile(fdir, [base '_locs.csv']);
            if rz ~= 1
                job.outCsvResized = fullfile(fdir, [base '_locs_resized.csv']);
            else
                job.outCsvResized = '';
            end
            job.tmpImg = '';   % scratch page image (set at launch)
            job.tmpCsv = '';   % predict.py raw output (set at launch)
            job.label  = label;
        end

        function v = parseNum(x, dflt)
            % Robustly coerce a table cell / edit-field value to a scalar double.
            if isnumeric(x)
                if isempty(x) || ~isscalar(x) || isnan(x), v = dflt; else, v = double(x); end
                return;
            end
            v = str2double(strtrim(char(x)));
            if isnan(v), v = dflt; end
        end

        function tf = parseLogical(x, dflt)
            % Robustly coerce table values to scalar logical.
            if islogical(x)
                tf = isscalar(x) && x;
                return;
            end
            if isnumeric(x)
                tf = isscalar(x) && x ~= 0 && ~isnan(x);
                return;
            end
            if isstring(x) || ischar(x)
                v = lower(strtrim(char(x)));
                if ismember(v, {'true','t','yes','y','on','1'})
                    tf = true;
                    return;
                elseif ismember(v, {'false','f','no','n','off','0',''})
                    tf = false;
                    return;
                end
            end
            tf = logical(dflt);
        end

        function n = countPages(f)
            % Number of pages/frames in an image file (1 for non-multi-image formats).
            try
                n = numel(imfinfo(f));
            catch
                n = 1;
            end
        end

        function img = readPage(f, page, nPages)
            % Read a specific page. For single-image formats, omit the index
            % (some formats reject a frame index argument).
            if nPages <= 1
                img = imread(f);
            else
                img = imread(f, page);
            end
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
                img = imresize(img, resizeFactor);
            end
        end

        function deleteFileQuiet(p)
            % Delete a file if it exists, ignoring any error.
            if ~isempty(p) && exist(p, 'file')
                try delete(p); catch, end
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
            data = {1, '', '(none)', '(none)', false, 0, 1};
        end

        function data = sanitizePageMap(data, detChoices, rescoreChoices)
            % Validate/repair saved page-map table data against the currently
            % available model lists, so a stale or malformed pref never breaks
            % the uitable (whose dropdown columns require valid members).
            if isempty(data) || ~iscell(data)
                data = CellDiscovery.defaultPageMap();
            elseif size(data, 2) == 6
                data = [data(:,1:4), repmat({false}, size(data,1), 1), data(:,5:6)];
            elseif size(data, 2) ~= 7
                data = CellDiscovery.defaultPageMap();
            end
            detFallback = detChoices{min(2, numel(detChoices))};   % first real model if any
            for r = 1:size(data, 1)
                % Page index
                p = CellDiscovery.parseNum(data{r,1}, 1);
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
                data{r,5} = CellDiscovery.parseLogical(data{r,5}, false);
                % Background radius (>= 0)
                b = CellDiscovery.parseNum(data{r,6}, 0);
                if b < 0, b = 0; end
                data{r,6} = b;
                % Resize factor (> 0)
                z = CellDiscovery.parseNum(data{r,7}, 1);
                if z <= 0, z = 1; end
                data{r,7} = z;
            end
        end

        function root = detectRepoRoot()
            % Locate the repo root (the directory containing predict.py).
            % Searches the class file's own directory, then one level up,
            % so the class works whether it lives at the repo root or in a
            % subdirectory such as customizations/.
            classFile = which('CellDiscovery');
            if isempty(classFile)
                root = pwd;
                return;
            end
            classDir = fileparts(classFile);
            if exist(fullfile(classDir, 'predict.py'), 'file')
                root = classDir;                        % class is at repo root
            else
                parent = fileparts(classDir);
                if exist(fullfile(parent, 'predict.py'), 'file')
                    root = parent;                      % class is one level down
                else
                    root = classDir;                    % fallback
                end
            end
        end

        function files = recDir(rootDir)
            % Recursively list all files under rootDir.
            % Returns an Nx1 cell array of absolute paths.
            files = {};
            d = dir(rootDir);
            for k = 1:numel(d)
                if d(k).isdir
                    if ~ismember(d(k).name, {'.', '..'})
                        sub   = CellDiscovery.recDir(fullfile(rootDir, d(k).name));
                        files = [files; sub]; %#ok<AGROW>
                    end
                else
                    files{end+1, 1} = fullfile(rootDir, d(k).name); %#ok<AGROW>
                end
            end
        end

        function result = ternary(cond, ifTrue, ifFalse)
            if cond
                result = ifTrue;
            else
                result = ifFalse;
            end
        end

        function writeScratchTiff(img, path)
            % Write a scratch TIFF that accepts any numeric pixel class.
            % imwrite() rejects single-precision (float32) data for TIFF — the
            % Tiff low-level class is used instead so float32, uint8, uint16,
            % int16, and uint32 source images are all handled correctly.
            if isa(img, 'double')
                img = single(img);   % Tiff supports float32; float64 is exotic
            end
            t = Tiff(path, 'w');
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

        function parts = quotedArgs(cmdParts)
            % Return cmdParts with any element containing a space wrapped in
            % double-quotes. Used only for the CMD: log line — ProcessBuilder
            % does NOT need quoting (each element is a separate argument).
            parts = cellfun(@(x) CellDiscovery.quoteIfSpaced(x), ...
                cmdParts, 'UniformOutput', false);
        end

        function s = quoteIfSpaced(s)
            if ~isempty(s) && any(s == ' ')
                s = ['"' s '"'];
            end
        end

        function rel = makeRelPath(absPath, rootDir)
            % Return absPath relative to rootDir (case-insensitive on Windows).
            % Falls back to absPath if absPath does not start with rootDir.
            if isempty(rootDir)
                rel = absPath;
                return;
            end
            % Normalise: ensure rootDir ends with a separator
            if rootDir(end) ~= filesep
                rootDir = [rootDir filesep];
            end
            n = length(rootDir);
            if strncmpi(absPath, rootDir, n)
                rel = absPath(n+1:end);
            else
                rel = absPath;
            end
        end

    end  % static methods

end  % classdef CellDiscovery