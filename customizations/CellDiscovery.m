classdef CellDiscovery < handle
    % CELLDISCOVERY   Batch GUI for PNN/PV cell detection via predict.py.
    %   Open the GUI:
    %       CellDiscovery()          % open window (object managed internally)
    %       app = CellDiscovery();   % optionally retain the object handle
    %       CellDiscovery(folder)    % open on a folder (it replaces the saved one)
    %
    %   Features:
    %     - Recursive directory search with regex file filter. The tool's own
    %       <stem>_resized.tif files are hidden from the list (the count label
    %       says how many); files whose mapped pages all have a result CSV are
    %       check-marked and counted as done.
    %     - Detection model + optional rescoring model (Stage 2) selection,
    %       per page in the page map
    %     - Multi-page TIFF support: process pages separately, with a
    %       per-page model mapping (e.g. page 1 = PNN model, page 2 = PV
    %       model). Single-page files use page 1's mapping row. A page may
    %       appear in only one row: Start refuses a map that names a page twice.
    %     - Optional image preprocessing applied before detection:
    %       morphological background subtraction (disk radius) and resize;
    %       optional bidirectional LSM artifact correction can also be run
    %       before detection, configured per page.
    %     - Pixel size: "Resize x" = 0 (the default) computes the factor from
    %       the TIFF pixel-size calibration so the detector sees the training
    %       pixel size (0.645 um/px); a manual factor that leaves the input
    %       more than 15% off it is reported with a [WARN] line.
    %     - Intensity: the "Normalize" column (on by default) stretches the
    %       detector input so its 1st-99.9th percentiles span the 8-bit range
    %       the models were trained on. It affects only what the detector and
    %       scoring models see, never the source image or the saved TIF.
    %     - Optional post-processing applied after detection: snapToCellCentroid
    %       localization refinement, enabled per page (Snap column) with its own
    %       per-page parameters (Snap options... dialog). Adds non-destructive
    %       SNAP_X/SNAP_Y/SNAP_Shift/SNAP_Snapped columns to the result CSV and,
    %       when requested, overwrites X/Y with the snapped coordinates.
    %     - The detector input (LSM -> background -> resize -> normalisation,
    %       in the scratch TIFF's class) is built by CellToolkit.modelInputPage,
    %       and everything needed to rebuild it exactly (resize factor and mode,
    %       background radius, LSM correction with its page set and options,
    %       normalisation percentiles/target/limits) is recorded in the
    %       manifest's detection stage (detectionFacts), so curation exports
    %       and rescoring regenerate the same image (CellToolkit.modelInputFromFile).
    %     - Pipeline order per page: detection (predict.py) -> snap
    %       (snapToCellCentroid) -> Stage-2 rescoring (score.py). Rescoring runs
    %       after snap so the scoring model crops patches centred on the snapped
    %       (refined) cell locations; the score lands in the 'rescore' column.
    %       Rescoring is its own streamed stage, like detection.
    %     - Full predict.py argument exposure (device, batch-size, threshold).
    %       Start checks these three fields before anything runs, and checks the
    %       Python environment once per environment (Python / conda executable
    %       and conda env), reporting whether a GPU is available: a cuda device
    %       without one is refused, a cpu device with one gets a hint.
    %     - Real-time stdout/stderr streaming to the MATLAB Command Window
    %     - Stop button: the first click finishes the page in flight (all its
    %       stages) and ends the batch; the button then reads "Abort now", which
    %       kills the Python subprocess and discards that page (no CSV, manifest
    %       entry or TIF is written for it)
    %     - The batch ends with a done / skipped / failed summary in the progress
    %       label (red when a page failed); the Command Window names the failed
    %       pages and the warnings
    %     - Closing the window while a batch runs asks first
    %     - Per-file CSV output placed next to the source image:
    %         <image_stem>_<suffix><page>_locs.csv
    %       (the suffix is the page-map Suffix, letters only, default 'page', so
    %       <image_stem>_page1_locs.csv). When resizing is used, a second CSV in
    %       resized-image coordinates is also written:
    %         <image_stem>_<suffix><page>_locs_resized.csv
    %       The optional resized TIF is one per image file, <image_stem>_resized.tif,
    %       holding every page.
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
    %     - MATLAB with uifigure support (the window is built from uifigure
    %       components; tested on R2025a)
    %     - Python with predict.py dependencies installed
    %     - predict.py must be locatable: either in the same folder as this
    %       file or one level up (e.g. when this file is in a subdirectory)
    %
    %   NOTE: If this file lives in a subdirectory of the repo (e.g.
    %   customizations/), add that subdirectory to the MATLAB path:
    %       addpath('customizations')
    %
    %   Test seams (Hidden; exactly what the controls call; tDiscoveryBatch):
    %     app.configure(Name, Value, ...)  set controls as a person would: PythonExe,
    %                                      CondaExe, CondaEnv, Device, BatchSize,
    %                                      Threshold (text), Overwrite, SavePng, SaveTif,
    %                                      Diagnostic (logical), PageMap (9-column cell)
    %     app.start()                      the Start Batch button
    %     app.requestStop()                the Stop button and the diagnostic window's
    %                                      Stop batch: the first call stops after the
    %                                      page in flight, the next (Abort now) kills
    %                                      its subprocess and discards that page
    %     app.isRunning()                  a batch runs (its timer exists)
    %     app.batchState()                 struct: Running, Stage ('' | 'detect' |
    %                                      'score' | 'finish'), Job, Total, Progress,
    %                                      ProgressColor, StopText, StopEnabled,
    %                                      StopTooltip, PythonRuns (processes this
    %                                      window started), ScratchDir (the last run's)
    %     app.lastTally()                  the counts of the last run (newTally,
    %                                      tallySummary)
    %     app.stageLog()                   the stages of each job of the last run:
    %                                      table Job, Label, Event, Tick (timer tick),
    %                                      Seconds (since Start)
    %     app.ConfirmCloseFcn              Hidden property: f(figure) -> true (stop the
    %                                      batch and close) | false (keep it running);
    %                                      asked when the window is closed mid-batch
    %                                      (tDiscoveryGui replaces it to answer without
    %                                      a dialog)
    %   Static Hidden (tDiscovery, tModelInput): the pure helpers (page-map and
    %   field checks, output names, the done marks, the tally words, ...) and the
    %   ...ForTest / detectorInputForFile / detectionFactsFor wrappers at the end
    %   of the file. The constructor options 'PrefGroup' and 'Search' (false =
    %   no search on opening) let a test build a window of its own.

    %% ---- Constants -------------------------------------------------------
    properties (Constant, Access = private)
        COLORMAPS  = {'gray','hot','jet','parula','turbo','bone','copper','pink','hsv'}
        DOT_COLORS = {'parula','hot','jet','turbo','hsv','pink','white','yellow','red','cyan','magenta','green','blue','black'}
        PREF_GROUP = 'PNNBatchGUI'
        SKIP_LABEL = '(skip)'    % page-map detection model sentinel: do not process page
        NONE_LABEL = '(none)'    % page-map rescore model sentinel: no rescoring
        % Default page-map suffix. Outputs are <stem>_<suffix><page>_locs.csv and
        % CellToolkit.pageFromIdentity reads the page back from _<letters><page>,
        % so the suffix must be letters only and carry no page number itself.
        DEFAULT_SUFFIX = 'page'

        % Pixel size the pretrained models were trained at. "Resize x" = 0
        % (auto) rescales each page to it from the TIFF calibration; a manual
        % factor that leaves the detector input further than PIXEL_SIZE_TOL
        % (fractional) from it raises a warning.
        TRAIN_UM_PER_PIXEL = 0.645
        PIXEL_SIZE_TOL     = 0.15

        % Intensity normalisation of the detector input ("Normalize" column):
        % these percentiles of the preprocessed page map to [0 NORM_TARGET].
        % predict.py divides by 255, so 255 puts the page on the 8-bit scale
        % the models were trained on.
        NORM_PERCENTILES = [1 99.9]
        NORM_TARGET      = 255

        % Progress label colour, and the one of a run in which a page failed.
        LABEL_COLOR      = [0 0 0]
        LABEL_FAIL_COLOR = [0.75 0 0]

        % The Stop button's two faces (setStopButton).
        STOP_TIP  = ['Stop the batch after the page in flight has finished all its stages ' ...
            '(detection, snap, rescoring, outputs). Click again to abort that page.']
        ABORT_TIP = ['Abort now: kill the running Python process, discard the page in flight ' ...
            '(no CSV, manifest entry or TIF is written for it) and end the batch.']
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
        hPageTable              % editable page -> model / preprocessing mapping
        hAddPageBtn
        hDelPageBtn
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
        prefGroup = CellDiscovery.PREF_GROUP   % setpref group of obj.P (constructor option 'PrefGroup')

        % --- Batch state ---
        timerObj      = []
        jProcess      = []
        jReader       = []
        stopRequested = false
        abortRequested = false  % second Stop click (Abort now): kill the subprocess, discard the page in flight
        fileIdx       = 1
        jobQueue      = {}      % cell array of job structs (see buildJobs)
        allAbsFiles   = {}      % absolute paths from last search (listbox shows relative)
        tmpDir        = ''      % this run's scratch folder (tempname under tempdir\CellDiscovery), removed when the batch ends
        preprocCache  = []      % per-file cache of preprocessed pages: resized (detector input) + source-resolution (snap input); see ensurePreprocCache
        inFlight      = []      % the page in flight: its job, stage ('detect' | 'score' | 'finish') and tables; see timerTick
        pageWarnings  = {}      % warnings of the page in flight; they reach the tally when it completes
        tally         = []      % the counts of the run (newTally); kept after it (lastTally)
        stageEvents   = struct('Job', {}, 'Label', {}, 'Event', {}, 'Tick', {}, 'Seconds', {})   % stageLog
        tickCount     = 0       % timer ticks of the run
        runClock      = []      % tic of Start
        pythonRuns    = 0       % Python processes this window started (env checks, predict.py, score.py)
        envPassed     = []      % the last passed environment check: struct key (envKey), cuda (true | false | NaN); [] = none (Start re-checks)
        dirListing    = {}      % the *_locs.csv files of the last search's directory listing (the "done" marks look in it)
        searchRoot    = ''      % folder of the last search (the file list shows paths relative to it)
        nHidden       = 0       % *_resized.tif files the last search hid
    end

    properties (Hidden)
        % Asked when the window is closed while a batch runs: f(figure) returns
        % true to stop the batch and close, false to keep it running. A test
        % replaces it to answer without a dialog.
        ConfirmCloseFcn = @CellDiscovery.askCloseWhileRunning
    end

    %% ---- Public interface ------------------------------------------------
    methods (Access = public)

        function obj = CellDiscovery(varargin)
            % Constructor — builds the GUI (or raises an existing window).
            %   obj = CellDiscovery()
            %   obj = CellDiscovery(folder)
            %   obj = CellDiscovery(folder, Name, Value, ...)   or   CellDiscovery(Name, Value, ...)
            %
            %   folder  folder to search; replaces the saved parent directory
            %           and is saved as the new one. Default: the saved one.
            %   Options
            %     'PrefGroup'  setpref group the settings are read from and
            %                  saved to (default 'PNNBatchGUI'); tests use
            %                  their own so they never touch yours.
            %     'Search'     false = do not search for files on opening
            %                  (default true).
            %
            %   Call without capturing output — the GUI manages its own lifetime:
            %       CellDiscovery()          % recommended
            %       app = CellDiscovery();   % optional, for programmatic access
            %   When the window is already open it is raised (and, given a
            %   folder, pointed at it, as setSearchDir does); the returned
            %   handle then has no figure of its own.
            %
            %   If callbacks stop working after editing this file, run:
            %       clear classes; CellDiscovery()
            [folder, opts] = CellDiscovery.parseConstructorArgs(varargin{:});

            % Re-use existing window if already open
            hExist = findobj(0, 'Tag', 'PNNBatchGUIMain');
            if ~isempty(hExist)
                if isempty(folder)
                    figure(hExist(1));
                else
                    obj.setSearchDir(folder, opts.Search);   % resolves the live object
                end
                return;
            end

            obj.prefGroup = opts.PrefGroup;
            obj.repoRoot = CellToolkit.detectRepoRoot();
            obj.discoverModels();
            obj.loadPrefs();
            if ~isempty(folder)
                obj.P.parentDir = folder;
            end
            obj.buildGUI();  % stores obj in figure appdata — prevents GC
            if ~isempty(folder)
                obj.savePrefs();   % the folder given is the new saved parent directory
            end
            if opts.Search
                obj.doSearch();
            end
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
            % CellDiscovery(folder) does this when the window is already open.
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
                if ispref(obj.prefGroup, f)
                    obj.P.(f) = getpref(obj.prefGroup, f);
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

            CellDiscovery.writePrefs(obj.prefGroup, obj.P);
        end

        function discoverModels(obj)
            % Scan repo root for subdirs containing best.pth; split by type.
            % Names containing 'fasterrcnn' -> detection; all others -> rescore.
            [obj.detModels, obj.rescoreModels] = CellToolkit.discoverModels(obj.repoRoot);
        end


        %% GUI construction


        function buildGUI(obj)
            % ---- Figure --------------------------------------------------
            scr = get(groot, 'ScreenSize');   % primary screen [1 1 width height]
            obj.hFig = uifigure( ...
                'Name',            'PNN / PV Batch Detector', ...
                'Position',        CellDiscovery.windowPosition(scr(3:4)), ...
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

            btn = uibutton(gDir, 'Text', 'Browse...', 'Tag', 'browseDirBtn', ...
                'Tooltip', 'Pick the parent folder to search for images in a folder dialog; the search then runs at once.', ...
                'ButtonPushedFcn', @obj.onBrowseDir);
            btn.Layout.Row = 1; btn.Layout.Column = 3;

            obj.hFileCountLabel = uilabel(gDir, 'Text', '0 files found', 'Tag', 'fileCountLabel', ...
                'HorizontalAlignment', 'left', 'FontColor', [0.2 0.5 0.2]);
            obj.hFileCountLabel.Layout.Row = 1; obj.hFileCountLabel.Layout.Column = 4;

            lbl = uilabel(gDir, 'Text', 'File filter (regex):', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;

            obj.hRegexEdit = uieditfield(gDir, 'text', ...
                'Value', obj.P.fileRegex, 'Tag', 'regexEdit', ...
                'Tooltip', 'Regular expression matched against the filename only (not full path)', ...
                'ValueChangedFcn', @obj.onRegexEdit);
            obj.hRegexEdit.Layout.Row = 2; obj.hRegexEdit.Layout.Column = 2;

            btn = uibutton(gDir, 'Text', 'Search', 'Tag', 'searchBtn', ...
                'Tooltip', 'Search the parent folder again with the file filter. Use it after files were added, removed or detected outside this window.', ...
                'ButtonPushedFcn', @obj.onSearch);
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
            btn = uibutton(gPy, 'Text', 'Browse...', 'Tag', 'browsePythonBtn', ...
                'Tooltip', 'Pick the Python executable (python.exe) in a file dialog.', ...
                'ButtonPushedFcn', @obj.onBrowsePython);
            btn.Layout.Row = 1; btn.Layout.Column = 3;

            lbl = uilabel(gPy, 'Text', 'conda executable:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 2; lbl.Layout.Column = 1;
            obj.hCondaExeEdit = uieditfield(gPy, 'text', ...
                'Value', obj.P.condaExe, 'Tag', 'condaExeEdit', ...
                'Tooltip', 'Full path to conda.exe (auto-detected). Used only when a Conda env name is set below.', ...
                'ValueChangedFcn', @obj.onCondaExeEdit);
            obj.hCondaExeEdit.Layout.Row = 2; obj.hCondaExeEdit.Layout.Column = 2;
            btn = uibutton(gPy, 'Text', 'Browse...', 'Tag', 'browseCondaBtn', ...
                'Tooltip', 'Pick the conda executable (conda.exe or conda.bat) in a file dialog.', ...
                'ButtonPushedFcn', @obj.onBrowseCondaExe);
            btn.Layout.Row = 2; btn.Layout.Column = 3;

            lbl = uilabel(gPy, 'Text', 'Conda env name:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 3; lbl.Layout.Column = 1;
            obj.hCondaEdit = uieditfield(gPy, 'text', ...
                'Value', obj.P.condaEnv, 'Tag', 'condaEdit', ...
                'Tooltip', 'Optional conda env name (e.g. countpnn). Leave blank to invoke the Python executable directly.', ...
                'ValueChangedFcn', @obj.onCondaEdit);
            obj.hCondaEdit.Layout.Row = 3; obj.hCondaEdit.Layout.Column = 2;
            obj.hTestEnvBtn = uibutton(gPy, 'Text', 'Test env', 'Tag', 'testEnvBtn', ...
                'Tooltip', 'Quick check that Python + hydra + torch are importable; it also says whether a GPU (CUDA) is available. Start Batch repeats it only when these three fields changed.', ...
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
            midGrid.ColumnWidth   = {'1x'};

            %% pFiles
            pFiles = uipanel(midGrid, 'Title', 'Files to Process  (Ctrl+click to select a subset)');
            pFiles.Layout.Column = 1;
            gFiles = uigridlayout(pFiles, [1 1]);
            gFiles.Padding = [4 4 4 4];
            obj.hFileList = uilistbox(gFiles, 'Items', {}, ...
                'Multiselect', 'on', 'Tag', 'fileList', 'FontSize', 11, ...
                'Tooltip', ['The image files found by the search; a check mark means every page-map row ' ...
                'already has its result CSV. Select nothing (or everything) to process all of them, ' ...
                'or Ctrl+click / Shift+click to process only some.'], ...
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

            % --- Row 1: Snap / LSM options and add/remove page ---
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
                'ColumnName',    {'Page','Suffix', 'Detection Model', 'Rescore Model', 'LSM', 'Bg radius', 'Resize x (0=auto)', 'Snap', 'Normalize'}, ...
                'ColumnFormat',  {'numeric', 'char', detChoices, rescoreChoices, 'logical', 'numeric', 'numeric', 'logical', 'logical'}, ...
                'ColumnEditable', [true true true true true true true true true], ...
                'ColumnWidth',   {50, 70, 220, 280, 60, 80, 130, 60, 80}, ...
                'RowName',       {}, ...
                'Tag',           'pageTable', ...
                'Tooltip',       sprintf([ ...
                'One row per TIFF page to process (rows without a detection model are skipped).\n' ...
                'Page: the page number in the TIFF (1 = first).\n' ...
                'Suffix: names the result file <stem>_<suffix><page>_locs.csv; use letters only (e.g. page).\n' ...
                'Detection Model: the detector run on this page; (skip) leaves the page out.\n' ...
                'Rescore Model: the scorer that rates each detection afterwards; (none) = no rescoring.\n' ...
                'LSM: correct the bidirectional LSM scanner artifact first (options: LSM options...).\n' ...
                'Bg radius: radius in pixels of the background subtraction; 0 = off.\n' ...
                'Resize x: factor applied to the page before detection. 0 = auto: computed from the ' ...
                'TIFF pixel-size calibration so the detector sees %g um/px (the training pixel size).\n' ...
                'Snap: move each detection to its refined cell centre afterwards (options: Snap options...).\n' ...
                'Normalize: stretch the detector input so its %g-%g percentiles span the 8-bit range the models ' ...
                'were trained on (does not alter the saved resized TIF or the source image).'], ...
                obj.TRAIN_UM_PER_PIXEL, obj.NORM_PERCENTILES(1), obj.NORM_PERCENTILES(2)), ...
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
                'Tooltip', ['Compute device for detection and rescoring: cpu, mps, cuda or cuda:<n> (e.g. cuda:0). ' ...
                'Checked when you click Start Batch; a cuda device is refused when the environment has no GPU.'], ...
                'ValueChangedFcn', @obj.onDeviceEdit);
            obj.hDeviceEdit.Layout.Row = 1; obj.hDeviceEdit.Layout.Column = 2;

            lbl = uilabel(gPred, 'Text', 'Batch size:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 3;
            obj.hBatchEdit = uieditfield(gPred, 'text', ...
                'Value', obj.P.batchSize, 'Tag', 'batchEdit', ...
                'Tooltip', 'Number of 640x640 patches detected in parallel (--batch-size): a positive whole number.', ...
                'ValueChangedFcn', @obj.onBatchEdit);
            obj.hBatchEdit.Layout.Row = 1; obj.hBatchEdit.Layout.Column = 4;

            lbl = uilabel(gPred, 'Text', 'Threshold:', 'HorizontalAlignment', 'left');
            lbl.Layout.Row = 1; lbl.Layout.Column = 5;
            obj.hThrEdit = uieditfield(gPred, 'text', ...
                'Value', obj.P.threshold, 'Tag', 'thrEdit', ...
                'Tooltip', 'Detection threshold, a number from 0 to 1 (--threshold); leave blank to use the default stored with the model.', ...
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
                'Text', 'Output per file:  <image_stem>_<suffix><page>_locs.csv  placed in the image''s own subdirectory', ...
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
                'Tooltip', ['Colour of the detection dots in the result figure and PNG. A colormap name ' ...
                '(parula, hot, ...) colours the dots by their rank in the score; a plain colour paints all dots alike.'], ...
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
                'the image the detection model received, before any intensity normalisation ' ...
                '(source intensities are kept for downstream measurements).'], ...
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
                'Tooltip', ['Run detection (and rescoring, where a rescore model is mapped) on the selected files, ' ...
                'page by page, with the settings above. The fields are checked first, then the Python environment.'], ...
                'ButtonPushedFcn', @obj.onStart);
            obj.hStartBtn.Layout.Row = 1; obj.hStartBtn.Layout.Column = 1;

            obj.hStopBtn = uibutton(gRun, 'Text', 'Stop', ...
                'FontSize', 11, 'FontWeight', 'bold', ...
                'FontColor', [0.60 0.05 0.05], 'Enable', false, 'Tag', 'stopBtn', ...
                'Tooltip', CellDiscovery.STOP_TIP, ...
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
                obj.setFileList({}, {});
                obj.allAbsFiles = {};
                return;
            end

            obj.hFileCountLabel.Text      = 'Searching...';
            obj.hFileCountLabel.FontColor = [0.6 0.4 0];
            drawnow;

            allFiles = CellToolkit.recDir(rootDir);
            % The result CSVs found in this listing decide which files show as
            % done (filesDone), before the regex narrows the list to the images.
            obj.dirListing = CellDiscovery.resultCsvsOf(allFiles);

            if ~isempty(regexStr) && ~isempty(allFiles)
                try
                    [~, names, exts] = cellfun(@fileparts, allFiles, 'UniformOutput', false);
                    basenames = strcat(names, exts);
                    keep      = ~cellfun(@isempty, regexpi(basenames, regexStr, 'once'));
                    allFiles  = allFiles(keep);
                catch ME
                    obj.hFileCountLabel.Text      = ['Regex error: ' ME.message];
                    obj.hFileCountLabel.FontColor = [0.7 0 0];
                    obj.setFileList({}, {});
                    obj.allAbsFiles = {};
                    return;
                end
            end
            % The tool's own *_resized.tif outputs are not inputs: detecting on
            % one writes a second set of results into the same dataset.
            [allFiles, nHidden] = CellDiscovery.hideDerivedImages(allFiles);

            obj.allAbsFiles = allFiles;
            obj.searchRoot  = rootDir;
            obj.nHidden     = nHidden;
            obj.refreshFileMarks();
        end

        function refreshFileMarks(obj)
            % Redraw the file list and its count label from the last search: a
            % file is marked done when every active page-map row has its result
            % CSV in the search's directory listing (filesDone; no disk access).
            % The user's selection stays. Called after a search, when the page
            % map changes and when a batch ends.
            if isempty(obj.hFig) || ~isvalid(obj.hFig), return; end
            files = obj.allAbsFiles;
            n = numel(files);
            if n > 0
                done = CellDiscovery.filesDone(files, obj.hPageTable.Data, obj.dirListing);
                labels = cellfun(@(f) CellToolkit.makeRelativePath(f, obj.searchRoot), ...
                    files, 'UniformOutput', false);
                labels = CellDiscovery.fileLabels(labels, done);
            else
                done = false(0, 1);
                labels = {};
            end
            obj.setFileList(labels, files);
            obj.hFileCountLabel.Text      = CellDiscovery.fileCountText(n, obj.nHidden, nnz(done));
            obj.hFileCountLabel.FontColor = CellToolkit.ternary(n > 0, [0.1 0.45 0.1], [0.6 0.4 0]);
        end

        function setFileList(obj, labels, paths)
            % Put LABELS in the file list with the absolute PATHS as their
            % values (ItemsData), keeping the selected paths that are still there.
            keep = obj.hFileList.Value;
            if ischar(keep) || isstring(keep), keep = cellstr(keep); end
            if ~iscell(keep), keep = {}; end
            obj.hFileList.ItemsData = {};
            obj.hFileList.Items     = labels(:)';
            obj.hFileList.ItemsData = paths(:)';
            keep = keep(ismember(keep, paths));
            obj.hFileList.Value = keep;   % none selected = all files (onStart); a new list would select its first item
        end

        function markQueuedDone(obj)
            % At the end of a batch: the result CSVs of the files it queued now
            % exist (isfile on those only), so the listing learns them and the
            % list shows the files done.
            try
                files = {};
                for k = 1:numel(obj.jobQueue)
                    files{end+1, 1} = obj.jobQueue{k}.imgFile; %#ok<AGROW>
                end
                files = unique(files);
                want = CellDiscovery.wantedCsvs(files, obj.hPageTable.Data);
                have = want(isfile(want));
                obj.dirListing = unique([obj.dirListing(:); have(:)]);
            catch
            end
            obj.refreshFileMarks();
        end


        %% Callbacks: directory & search


        function onClose(obj, src, ~)
            % Closing the window mid-batch stops and discards the page in
            % flight, so a running batch asks first (ConfirmCloseFcn). A
            % window with no batch closes without asking.
            if obj.isRunning()
                try
                    close = logical(obj.ConfirmCloseFcn(obj.hFig));
                catch
                    close = false;   % cannot ask: keep the batch running
                end
                if ~close, return; end
            end
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

        function [envStatus, cuda] = onTestEnv(obj, ~, ~)
            % Run a quick synchronous check that Python + required modules are
            % importable (the Test env button; always runs). Returns 0 on
            % success, nonzero on failure, and whether CUDA is available (true |
            % false | NaN = unknown). A pass is remembered (envPassed) for the
            % same Python / conda executable and conda env: Start skips its
            % pre-flight while they are unchanged.
            pyExe    = strtrim(obj.hPyEdit.Value);
            condaExe = strtrim(obj.hCondaExeEdit.Value);
            condaEnv = strtrim(obj.hCondaEdit.Value);
            cuda = NaN;
            obj.envPassed = [];

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

            obj.pythonRuns = obj.pythonRuns + 1;
            [ok, ~, envOut, cuda] = CellToolkit.testPythonEnv(obj.pythonCfg(), {'hydra', 'torch'});
            set(obj.hFig, 'Pointer', 'arrow');
            drawnow;
            envOut = strtrim(envOut);
            if ok
                txt = CellDiscovery.envStatusText(cuda);
                fprintf('[TEST] PASS: %s\n', txt);
                obj.hProgressLabel.Text = txt;
                obj.envPassed = struct('key', CellDiscovery.envKey(pyExe, condaExe, condaEnv), 'cuda', cuda);
                envStatus = 0;
                return;
            end
            cuda = NaN;

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


        %% Callbacks: multi-page & preprocessing


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
            % Suffix 'page': the output is <stem>_page<k>_locs.csv (the page
            % number is appended to the suffix).
            newRow = {nextPage, CellDiscovery.DEFAULT_SUFFIX, defDet, obj.NONE_LABEL, false, 0, 0, false, true};
            obj.hPageTable.Data = [data; newRow];
            obj.P.pageMapData   = obj.hPageTable.Data;
            obj.updateLSMOptionsButton();
            obj.updateSnapOptionsButton();
            obj.savePrefs();
            obj.refreshFileMarks();
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
            obj.refreshFileMarks();
        end

        function onPageTableEdit(obj, ~, ~)
            obj.P.pageMapData = obj.hPageTable.Data;
            obj.updateLSMOptionsButton();
            obj.updateSnapOptionsButton();
            obj.savePrefs();
            obj.refreshFileMarks();
        end

        function onPageTableSelect(obj, ~, evt)
            if ~isempty(evt.Indices)
                obj.pageTableSelRow = evt.Indices(1, 1);
            end
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
                'Tooltip', 'Close this window and keep the LSM correction options as they were.', ...
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
                'Tooltip', 'Close this window and keep the snap parameters as they were.', ...
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
            obj.hProgressLabel.FontColor = CellDiscovery.LABEL_COLOR;   % red was the last run's
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

            % --- Page map: refuse duplicate pages, warn about suffixes ---
            [mapErrs, mapWarns] = CellDiscovery.checkPageMap(obj.hPageTable.Data);
            for k = 1:numel(mapWarns)
                fprintf(2, '[WARN] %s\n', mapWarns{k});
            end
            if ~isempty(mapErrs)
                fprintf(2, '[ERROR] %s\n', mapErrs{:});
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                uialert(obj.hFig, strjoin(mapErrs, newline), 'Page map: duplicate pages');
                return;
            end

            % --- Free-text fields: refuse a value predict.py would fail on, once,
            %     before any Python starts ---
            fieldErrs = CellDiscovery.checkFields(obj.hDeviceEdit.Value, obj.hBatchEdit.Value, obj.hThrEdit.Value);
            if ~isempty(fieldErrs)
                fprintf(2, '[ERROR] %s\n', fieldErrs{:});
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                uialert(obj.hFig, strjoin(fieldErrs, newline), 'Check the predict.py options');
                return;
            end

            selVals = obj.hFileList.Value;   % absolute paths (ItemsData); none selected = all
            if ischar(selVals), selVals = {selVals}; end
            if isempty(selVals) || numel(selVals) == numel(allFiles)
                queue = allFiles;
            else
                queue = allFiles(ismember(allFiles, selVals));
            end

            % --- Nothing to do: said without starting Python. In Ignore mode the
            %     pages whose result CSV exists are counted as skipped (pendingRows
            %     goes by file names only, so no TIFF is opened either). ---
            [todo, nDone] = CellDiscovery.pendingRows(queue, obj.hPageTable.Data, logical(obj.hOverwriteRad.Value));
            if all(cellfun(@isempty, todo))
                if nDone > 0
                    fprintf('[SKIP] %d page job(s) left out: result CSV exists (Ignore mode)\n', nDone);
                end
                obj.nothingToDo(nDone, 'no page-map row has a detection model.');
                return;
            end

            % Disable UI immediately before any blocking operations
            obj.setUIEnable(false);
            obj.hStopBtn.Enable = false;
            drawnow;

            % --- Pre-flight: verify that hydra and torch are importable (and
            %     whether CUDA is there). A passed check is reused while the
            %     Python / conda executable and the conda env are unchanged. ---
            key = CellDiscovery.envKey(strtrim(obj.hPyEdit.Value), strtrim(obj.hCondaExeEdit.Value), ...
                strtrim(obj.hCondaEdit.Value));
            if ~isempty(obj.envPassed) && strcmp(obj.envPassed.key, key)
                cuda = obj.envPassed.cuda;
                fprintf('[CHECK] Python environment unchanged since its last passed check; not repeated (Test env repeats it).\n');
            else
                [envStatus, cuda] = obj.onTestEnv;
                if envStatus ~= 0
                    obj.setUIEnable(true);
                    obj.hStopBtn.Enable = false;
                    set(obj.hFig, 'Pointer', 'arrow');
                    drawnow;
                    return;
                end
            end
            [gpuAction, gpuMsg] = CellDiscovery.gpuCheck(obj.hDeviceEdit.Value, cuda);
            if strcmp(gpuAction, 'block')
                fprintf(2, '[ERROR] %s\n', gpuMsg);
                obj.setUIEnable(true);
                obj.hStopBtn.Enable = false;
                obj.hProgressLabel.Text = 'Device not available (see the message).';
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                uialert(obj.hFig, gpuMsg, 'Device not available');
                return;
            elseif strcmp(gpuAction, 'hint')
                fprintf('[HINT] %s\n', gpuMsg);
            end

            % --- Expand the selected files into a queue of per-page jobs ---
            obj.hProgressLabel.Text = 'Building job list ...';
            drawnow;
            [jobs, nDone] = obj.buildJobs(queue);
            if isempty(jobs)
                obj.setUIEnable(true);
                obj.nothingToDo(nDone, 'no mapped page exists in the selected files (see the [SKIP] lines).');
                return;
            end

            % Scratch folder of this run, removed with its contents when the batch
            % ends (batchCleanup), on an internal error and when the window closes
            % (cleanup). Its unique name also finds the run's processes (killProcess).
            obj.tmpDir = tempname(fullfile(tempdir, 'CellDiscovery'));
            [made, msg] = mkdir(obj.tmpDir);
            if ~made
                fprintf(2, '[ERROR] Could not create the scratch folder %s: %s\n', obj.tmpDir, msg);
                obj.setUIEnable(true);
                obj.hStopBtn.Enable = false;
                obj.hProgressLabel.Text = 'Could not create the scratch folder (see the Command Window).';
                obj.hProgressLabel.FontColor = CellDiscovery.LABEL_FAIL_COLOR;
                set(obj.hFig, 'Pointer', 'arrow');
                drawnow;
                return;
            end

            obj.jobQueue      = jobs;
            obj.fileIdx       = 1;
            obj.stopRequested = false;
            obj.abortRequested = false;
            obj.jProcess      = [];
            obj.jReader       = [];
            obj.preprocCache  = [];   % per-file preprocessing cache (lazy-filled)
            obj.inFlight      = [];
            obj.pageWarnings  = {};
            obj.tally         = CellDiscovery.newTally(numel(jobs), nDone);
            obj.stageEvents   = obj.stageEvents([]);
            obj.tickCount     = 0;
            obj.runClock      = tic;

            obj.setUIEnable(false);
            obj.setStopButton('stop');
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
            % The Stop / Abort now button (requestStop).
            obj.requestStop();
        end

        function nothingToDo(obj, nDone, why)
            % End a Start that found no job: its tally (the pages skipped because
            % their result exists) and the progress label say so.
            obj.tally = CellDiscovery.newTally(0, nDone);
            obj.tally.state = 'complete';
            obj.stageEvents = obj.stageEvents([]);
            if nDone > 0
                obj.hProgressLabel.Text = sprintf(['Nothing to do: all %d page job(s) already ' ...
                    'have results (Ignore mode). Choose Overwrite to redo them.'], nDone);
            else
                obj.hProgressLabel.Text = ['Nothing to do: ' why];
            end
            obj.hStartBtn.Enable = true;
            obj.hStopBtn.Enable  = false;
            set(obj.hFig, 'Pointer', 'arrow');
            drawnow;
        end

        function setStopButton(obj, state)
            % The Stop button's two faces: 'stop' (stop after the page in flight)
            % and 'abort' (Abort now: discard it), each with its tooltip.
            if strcmp(state, 'abort')
                obj.hStopBtn.Text    = 'Abort now';
                obj.hStopBtn.Tooltip = CellDiscovery.ABORT_TIP;
            else
                obj.hStopBtn.Text    = 'Stop';
                obj.hStopBtn.Tooltip = CellDiscovery.STOP_TIP;
            end
        end

        function showProgress(obj, txt)
            % Set the progress label; while a stop is pending it says so too.
            if obj.stopRequested
                txt = [txt '   (stop requested: the batch ends after this page)'];
            end
            obj.hProgressLabel.Text = txt;
        end

        function resumeDiagnosticPause(~)
            % Let a diagnostic pause go on, so a Stop or Abort click can end the
            % batch (the window stays open; uiresume of a figure that is not
            % waiting does nothing).
            h = findall(0, 'Type', 'figure', 'Tag', 'PNNDiagFig');
            if ~isempty(h)
                uiresume(h(1));
            end
        end


        %% Job-list construction


        function [jobs, nDone] = buildJobs(obj, files)
            % Expand a list of image files into a list of per-page jobs based on
            % the current per-page / preprocessing settings. Each job is one
            % (file, page) unit run through predict.py independently.
            % In Ignore mode the rows whose output CSV already exists are left
            % out first, from the file names alone (pendingRows), so a file
            % whose pages are all done is never opened; nDone counts them.
            jobs = {};

            mapData = obj.hPageTable.Data;
            [todo, nDone] = CellDiscovery.pendingRows(files, mapData, logical(obj.hOverwriteRad.Value));
            if nDone > 0
                fprintf('[SKIP] %d page job(s) left out: result CSV exists (Ignore mode)\n', nDone);
            end

            for i = 1:numel(files)
                if isempty(todo{i}), continue; end
                f = files{i};
                [fdir, stem] = fileparts(f);
                if isempty(fdir), fdir = pwd; end
                nPages = CellToolkit.countPages(f);

                for r = todo{i}
                    pg   = CellToolkit.parseNum(mapData{r,1}, 0);
                    detM = mapData{r,3};
                    if pg > nPages
                        % Single-page files therefore only ever match page 1.
                        fprintf('[SKIP] %s has %d page(s); skipping mapped page %d\n', ...
                            stem, nPages, pg);
                        continue;
                    end
                    rescM = mapData{r,4};
                    if ~ischar(rescM) || strcmp(rescM, obj.NONE_LABEL), rescM = ''; end

                    snapOpts = obj.resolveSnapOptionsForPage(pg);
                    job = CellDiscovery.jobForRow(f, fdir, stem, nPages, mapData(r,:), ...
                        detM, rescM, obj.P.lsmOptions, snapOpts);
                    CellDiscovery.reportScale(job, job.resizeMode);
                    jobs{end+1} = job; %#ok<AGROW>
                end
            end
        end


        %% Timer callback (main batch processing loop)


        function timerCallback(obj)
            % The timer's TimerFcn: one tick of the batch. An error escaping a
            % tick would stop the timer and leave the window locked, so it ends
            % the batch here instead (stopOnInternalError).
            try
                obj.timerTick();
            catch ME
                obj.stopOnInternalError(ME);
            end
        end

        function stopOnInternalError(obj, ME)
            % Report an error that escaped a timer tick (with its stack) and end
            % the batch: timer stopped, subprocess killed, window unlocked.
            fprintf(2, '[ERROR] The batch stopped on an internal error:\n%s\n', ...
                getReport(ME, 'extended', 'hyperlinks', 'off'));
            where = '';
            if obj.fileIdx >= 1 && obj.fileIdx <= numel(obj.jobQueue)
                where = sprintf(' at job %d / %d', obj.fileIdx, numel(obj.jobQueue));
            end
            try
                % The job it happened in failed (nothing more is written for it).
                obj.tally.error = ME.message;
                obj.killProcess();
                if obj.fileIdx >= 1 && obj.fileIdx <= numel(obj.jobQueue)
                    obj.failJob(obj.jobQueue{obj.fileIdx}, ['internal error: ' ME.message]);
                end
            catch
            end
            try
                obj.batchCleanup();
            catch ME2
                fprintf(2, '[ERROR] Cleaning up after it failed too: %s\n', ME2.message);
                obj.cleanup();   % at least stop the timer and the subprocess, remove the scratch folder
            end
            if ~isempty(obj.hFig) && isvalid(obj.hFig)
                obj.hProgressLabel.Text = sprintf( ...
                    'Batch stopped on an internal error%s: %s (details in the Command Window)', ...
                    where, ME.message);
                obj.hProgressLabel.FontColor = CellDiscovery.LABEL_FAIL_COLOR;
            end
        end

        function timerTick(obj)
            % One tick of the batch. A page goes through these stages:
            %   detect   predict.py runs on its scratch detector input; the ticks
            %            stream its output until it exits (Case B)
            %   after detection (detectionExited -> afterDetection, in the tick
            %            that sees predict.py exit): read its CSV, build the
            %            original-space table, snap
            %   score    when the page has a scoring model and detections:
            %            score.py runs as a second asynchronous stage, streamed by
            %            the ticks like predict.py (launchScoring, scoringExited)
            %   finish   write the CSVs, the manifest entry, the resized TIF, the
            %            figure / PNG, the diagnostic pause, then the next job
            %            (finishJob)
            % Between ticks a page in flight always has a process running
            % (inFlight and jProcess are set together), so a Stop click lets the
            % page finish all its stages and Abort now (abortInFlight) can kill
            % the process and discard the page. stageLog records the stages.
            if isempty(obj.hFig) || ~isvalid(obj.hFig), return; end
            obj.tickCount = obj.tickCount + 1;

            total = numel(obj.jobQueue);

            %% Abort now: kill the subprocess, discard the page in flight, end
            if obj.abortRequested
                obj.abortInFlight();
                obj.batchCleanup();
                return;
            end

            %% Case A: stop requested, no page in flight — clean up
            if obj.stopRequested && isempty(obj.inFlight)
                fprintf('[STOP] Batch stopped by user after %d / %d job(s).\n', ...
                    max(obj.fileIdx - 1, 0), total);
                obj.batchCleanup();
                return;
            end

            %% Case B: a subprocess runs (detection or scoring) — drain stdout, check for completion
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
                if ~done, return; end

                % Block-drain anything still buffered after exit.
                CellDiscovery.echoLines(CellToolkit.drainReader(obj.jReader, true));
                obj.jProcess = [];
                obj.jReader  = [];
                if ~isempty(obj.inFlight) && strcmp(obj.inFlight.stage, 'score')
                    obj.scoringExited(exitCode);
                else
                    obj.detectionExited(exitCode);
                end
                return;
            end

            %% Case C: no active process — launch the next job
            if obj.fileIdx > total
                obj.batchCleanup();   % prints the run's summary
                return;
            end

            job = obj.jobQueue{obj.fileIdx};

            overwrite = obj.hOverwriteRad.Value;
            if exist(job.outCsvOrig, 'file') && ~overwrite
                fprintf('[SKIP] (%d/%d) result exists, Ignore mode: %s\n', ...
                    obj.fileIdx, total, job.label);
                obj.hProgressLabel.Text = sprintf('Skipped %d / %d  (result exists)', obj.fileIdx, total);
                obj.tally.skipped = obj.tally.skipped + 1;
                obj.logStage(job, 'skip');
                obj.fileIdx = obj.fileIdx + 1;
                return;
            end

            obj.hProgressLabel.Text = sprintf('Processing %d / %d:  %s', obj.fileIdx, total, job.label);
            drawnow;
            if obj.stopRequested || obj.abortRequested
                return;   % clicked during the drawnow: the next tick ends the batch, this job not run
            end
            obj.pageWarnings = {};

            % --- Preprocess the whole file once (joint LSM), grab this page ---
            % Preprocessing is centralised: the entire channel stack is corrected
            % together (so LSM registration uses every channel) and cached, then
            % reused for every page's detection and for the output TIF.
            %
            % Intensity normalisation is applied here, to the detector-input
            % scratch image only (which Stage-2 rescoring also crops from). The
            % cached pages — and so the saved resized TIF and the snap input —
            % keep their source intensities for downstream measurements.
            try
                obj.ensurePreprocCache(job.imgFile, job.nPages);
                job.lsmPages = obj.preprocCache.lsmIdx;   % pages LSM-corrected together (recorded)
                [img, lims] = CellDiscovery.detectorInputPage(obj.preprocCache.pages{job.page}, job.normalize);
                if job.normalize
                    job.normLimits = lims;
                    if any(isnan(job.normLimits(:)))
                        fprintf(2, '[WARN] %s: no intensity spread to normalise; page used as is.\n', job.label);
                    else
                        fprintf('[NORM] %s: p%g = %.4g -> 0, p%g = %.4g -> %g\n', job.label, ...
                            obj.NORM_PERCENTILES(1), job.normLimits(1,1), ...
                            obj.NORM_PERCENTILES(2), job.normLimits(1,2), obj.NORM_TARGET);
                    end
                end
            catch ME
                fprintf(2,'[ERROR] (%d/%d) could not read/preprocess %s: %s\n', ...
                    obj.fileIdx, total, job.label, ME.message);
                obj.failJob(job, ['could not read or preprocess the page: ' ME.message]);
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
                obj.failJob(job, ['could not write the scratch image: ' ME.message]);
                return;
            end
            obj.jobQueue{obj.fileIdx} = job;   % persist tmp paths for Case B

            device     = strtrim(obj.hDeviceEdit.Value);
            batchSize  = strtrim(obj.hBatchEdit.Value);
            threshold  = strtrim(obj.hThrEdit.Value);

            % Core predict.py arguments. predict.py runs on the resized
            % scratch image; coordinates are mapped back to original-image space
            % in afterDetection. A blank/NaN threshold is omitted by
            % CellToolkit.predictArgs. Paths may contain spaces —
            % launchPythonAsync passes each token as a separate argument, so no
            % quoting is needed (conda-run wrapping is applied by the toolkit).
            %
            % Detection ONLY: Stage-2 rescoring (job.rescoreModel) is a stage of
            % its own after snapToCellCentroid refinement (launchScoring),
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
                obj.failJob(job, ['predict.py could not start: ' ME.message]);
                return;
            end
            obj.pythonRuns = obj.pythonRuns + 1;
            obj.inFlight = struct('stage', 'detect', 'job', job, ...
                'locs', [], 'locsOrig', [], 'f', job.resize, 'nDets', 0, ...
                'hasX', false, 'hasY', false, 'hasRescore', false, ...
                'diagFromX', [], 'diagFromY', [], ...
                'scoreIn', '', 'scoreOut', '', 'scoreRows', 0, 'csvWritten', false);
            obj.logStage(job, 'detect-launch');
        end


        %% Stages of the page in flight (see timerTick)


        function detectionExited(obj, exitCode)
            % predict.py of the page in flight exited: fail the page on a non-zero
            % exit, else run "after detection" and either wait for score.py or
            % finish the page now.
            job   = obj.inFlight.job;
            total = numel(obj.jobQueue);
            obj.logStage(job, 'detect-exit');
            if exitCode ~= 0
                fprintf(2,'[FAIL] (%d/%d) exit code=%d  %s\n', ...
                    obj.fileIdx, total, exitCode, job.label);
                obj.failJob(job, sprintf('predict.py exited with code %d', exitCode));
                obj.endOfPage();
                return;
            end
            fprintf('[DONE] (%d/%d) %s\n', obj.fileIdx, total, job.label);
            try
                next = obj.afterDetection();
            catch ME
                % nothing is written for the page yet
                fprintf(2, '[FAIL] (%d/%d) %s: %s\n', obj.fileIdx, total, job.label, ME.message);
                obj.failJob(job, ME.message);
                obj.endOfPage();
                return;
            end
            if strcmp(next, 'score')
                return;   % the next ticks stream score.py until it exits (scoringExited)
            end
            obj.finishJob();
        end

        function next = afterDetection(obj)
            % Stage "after detection" of the page in flight: read predict.py's
            % output (in resized coordinates), stamp the imgName column, build the
            % original-space copy and snap it. Then, when the page has a scoring
            % model and detections, launch Stage-2 rescoring (next = 'score': the
            % timer waits for score.py), else next = 'finish'. Throws when the page
            % has no usable result (the caller fails the page).
            job = obj.inFlight.job;

            if ~exist(job.tmpCsv, 'file')
                error('CellDiscovery:noDetections', 'predict.py wrote no output CSV (%s)', job.tmpCsv);
            end
            try
                locs = readtable(job.tmpCsv);
            catch ME
                error('CellDiscovery:badDetections', 'could not read predict.py''s CSV %s: %s', ...
                    job.tmpCsv, ME.message);
            end
            nDets = height(locs);

            hasX = ismember('X', locs.Properties.VariableNames);
            hasY = ismember('Y', locs.Properties.VariableNames);
            hasRescore = ismember('rescore',locs.Properties.VariableNames);

            % Stamp the imgName column with the original (per-page) identity.
            if ismember('imgName', locs.Properties.VariableNames)
                locs.imgName = repmat({job.imgName}, nDets, 1);
            end

            % --- Build the original-space copy (locs stays in resized space) ---
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
                    obj.warnPage(['snap failed: ' ME.message]);
                end
            end

            obj.inFlight.locs       = locs;
            obj.inFlight.locsOrig   = locsOrig;
            obj.inFlight.f          = f;
            obj.inFlight.nDets      = nDets;
            obj.inFlight.hasX       = hasX;
            obj.inFlight.hasY       = hasY;
            obj.inFlight.hasRescore = hasRescore;
            obj.inFlight.diagFromX  = diagFromX;
            obj.inFlight.diagFromY  = diagFromY;
            obj.logStage(job, 'after-detection');

            % --- Stage-2 rescoring (score.py), AFTER detection + snap ----------
            % Out of the predict.py call so the scoring model crops its 64x64
            % patches around the snapped (refined) cell centres, and a stage of
            % its own: score.py runs asynchronously, streamed by the timer like
            % predict.py, so MATLAB stays free and Stop / Abort now act on it.
            % Best effort: a scoring failure never blocks the CSV write.
            next = 'finish';
            if isfield(job, 'rescoreModel') && ~isempty(job.rescoreModel) ...
                    && nDets > 0 && hasX && hasY
                try
                    if obj.launchScoring()
                        next = 'score';
                    end
                catch ME
                    fprintf('[WARN] Rescore failed for %s: %s\n', job.label, ME.message);
                    obj.warnPage(['rescoring failed: ' ME.message]);
                end
            end
        end

        function started = launchScoring(obj)
            % Start Stage-2 rescoring (score.py) of the page in flight, after
            % detection and snap; false when there is nothing to score.
            %
            % Scoring crops 64x64 patches from the resized detector-input
            % scratch image (job.tmpImg) at the training pixel size, so the
            % (snapped) original-image coordinates are mapped back into resized
            % space (* the resize factor f). When snap ran, SNAP_X/SNAP_Y carry
            % the refined centres (snapped points moved, unsnapped points keep
            % their original location), so the model sees crops centred on the
            % best available cell location regardless of the ApplyToXY setting.
            started  = false;
            job      = obj.inFlight.job;
            locsOrig = obj.inFlight.locsOrig;
            f        = obj.inFlight.f;
            if exist(job.tmpImg, 'file') ~= 2
                fprintf('[WARN] Scratch image missing; skipping rescore for %s.\n', job.label);
                obj.warnPage('rescoring skipped: the scratch image is missing');
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
            % score can be merged back onto the right rows afterwards
            % (readScores).
            [~, imgStem, imgExt] = fileparts(job.tmpImg);
            nLive = numel(keys);
            inTbl = table();
            inTbl.idx         = (0:nLive-1)';
            inTbl.imgName     = repmat(string([imgStem imgExt]), nLive, 1);
            inTbl.Xp          = double(ex(live)) * f;   % original -> resized space
            inTbl.Yp          = double(ey(live)) * f;
            inTbl.rescore_key = keys;

            obj.inFlight.scoreIn   = fullfile(obj.tmpDir, [imgStem '_scorein.csv']);
            obj.inFlight.scoreOut  = fullfile(obj.tmpDir, [imgStem '_scoreout.csv']);
            obj.inFlight.scoreRows = height(locsOrig);
            writetable(inTbl, obj.inFlight.scoreIn);

            % No --batch-size: the Batch size field is the detector's (640x640
            % patches, default 1); score.py's own default (512 crops per batch)
            % applies, as in curation.Rescore.
            args = CellToolkit.scoreArgs(char(job.rescoreModel), obj.inFlight.scoreIn, struct( ...
                'root',      obj.tmpDir, ...
                'device',    strtrim(obj.hDeviceEdit.Value), ...
                'output',    obj.inFlight.scoreOut));
            cfg = obj.pythonCfg();
            fprintf('[SCORE] %s\n  CMD: %s\n', job.label, ...
                CellToolkit.commandString(CellToolkit.pythonCommandParts(cfg, args)));
            [obj.jProcess, obj.jReader] = CellToolkit.launchPythonAsync(cfg, args);
            obj.inFlight.stage = 'score';
            obj.pythonRuns = obj.pythonRuns + 1;
            obj.logStage(job, 'score-launch');
            obj.showProgress(sprintf('Scoring %d / %d:  %s', obj.fileIdx, numel(obj.jobQueue), job.label));
            started = true;
        end

        function scoringExited(obj, exitCode)
            % score.py of the page in flight exited: merge its scores (a failure is
            % a warning, never a failed page) and finish the page.
            job = obj.inFlight.job;
            obj.logStage(job, 'score-exit');
            try
                rv = obj.readScores(exitCode);
            catch ME
                rv = [];
                fprintf(2, '[WARN] Rescore failed for %s: %s\n', job.label, ME.message);
                obj.warnPage(['rescoring failed: ' ME.message]);
            end
            if ~isempty(rv)
                obj.inFlight.locsOrig.rescore = rv;
                obj.inFlight.locs.rescore     = rv;
                obj.inFlight.hasRescore       = true;
            end
            CellToolkit.deleteFiles({obj.inFlight.scoreIn, obj.inFlight.scoreOut});
            obj.finishJob();
        end

        function rv = readScores(obj, exitCode)
            % The rescore vector of the page in flight from score.py's output: N x 1,
            % aligned to its rows by rescore_key (NaN where a row has none), or []
            % when score.py failed or its output is unusable (warned).
            rv  = [];
            job = obj.inFlight.job;
            out = obj.inFlight.scoreOut;
            n   = obj.inFlight.scoreRows;
            if exitCode ~= 0 || exist(out, 'file') ~= 2
                fprintf(2, '[WARN] Rescore failed for %s (exit %d; its output is above).\n', ...
                    job.label, exitCode);
                if exitCode ~= 0
                    obj.warnPage(sprintf('rescoring failed: score.py exited with code %d', exitCode));
                else
                    obj.warnPage('rescoring failed: score.py wrote no output');
                end
                return;
            end

            R   = readtable(out, 'VariableNamingRule', 'preserve');
            rvn = string(R.Properties.VariableNames);
            if ~all(ismember(["rescore_key","rescore"], rvn))
                fprintf(2, '[WARN] Rescore output missing expected columns for %s.\n', job.label);
                obj.warnPage('rescoring failed: its output has no rescore_key / rescore columns');
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

        function finishJob(obj)
            % Stage "finish" of the page in flight (finishOutputs), then the next
            % job. The page counts as done once its result CSV is written: an
            % error before that fails it, one after it is a warning.
            job = obj.inFlight.job;
            obj.inFlight.stage = 'finish';
            try
                obj.finishOutputs();
            catch ME
                if ~obj.inFlight.csvWritten
                    fprintf(2, '[FAIL] (%d/%d) %s: %s\n', obj.fileIdx, numel(obj.jobQueue), ...
                        job.label, ME.message);
                    obj.failJob(job, ME.message);
                    obj.endOfPage();
                    return;
                end
                fprintf(2,'[WARN] post-processing failed for %s: %s\n', job.label, ME.message);
                obj.warnPage(['post-processing failed after the CSV was written: ' ME.message]);
            end
            obj.doneJob(job);
            obj.endOfPage();
        end


        %% Per-page outputs: CSVs, manifest, TIF, display + optional PNG export


        function finishOutputs(obj)
            % The outputs of the page in flight (stage "finish"): write its
            % CSV(s) (original space, and resized space when resized), record it
            % in the dataset manifest, save the resized TIF, render/optionally
            % export the result figure, and pause for the diagnostic view. Sets
            % inFlight.csvWritten once the result CSV is written; throws when it
            % cannot be (the page fails). Other problems are page warnings.
            p          = obj.inFlight;
            job        = p.job;
            locs       = p.locs;        % resized (detector) coordinates
            locsOrig   = p.locsOrig;    % original-image coordinates (+ SNAP_* columns)
            f          = p.f;
            nDets      = p.nDets;
            hasX       = p.hasX;
            hasY       = p.hasY;
            hasRescore = p.hasRescore;
            diagFromX  = p.diagFromX;
            diagFromY  = p.diagFromY;
            imgDir     = job.imgDir;

            try
                writetable(locsOrig, job.outCsvOrig);
            catch ME
                error('CellDiscovery:csvNotWritten', 'could not write %s: %s', job.outCsvOrig, ME.message);
            end
            obj.inFlight.csvWritten = true;
            fprintf('[CSV ] Saved: %s\n', job.outCsvOrig);
            if f ~= 1 && ~isempty(job.outCsvResized)
                try
                    writetable(locs, job.outCsvResized);   % resized-image coordinates
                    fprintf('[CSV ] Saved: %s\n', job.outCsvResized);
                catch ME
                    fprintf('[WARN] Could not write %s: %s\n', job.outCsvResized, ME.message);
                    obj.warnPage(['the resized-coordinate CSV was not written: ' ME.message]);
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
                info = CellDiscovery.detectionFacts(job);   % everything needed to regenerate the model input
                info.image = job.imgFile;
                info.page  = job.page;
                info.locs  = job.outCsvOrig;
                info.tool  = 'CellDiscovery';
                info.model = job.detModel;
                info.count = nDets;
                mf.recordDetection(key, info);
                if f ~= 1 && ~isempty(job.outCsvResized)
                    mf.recordResized(key, job.outCsvResized, job.outTif);
                end
                if ~isempty(job.rescoreModel) && hasRescore
                    mf.recordRescore(key, struct('tool', 'CellDiscovery', ...
                        'model', job.rescoreModel));
                end
                if ~mf.save()   % save never throws; it returns false
                    error('CellDiscovery:manifestNotSaved', 'the manifest file could not be written');
                end
            catch ME
                fprintf(2, '[WARN] %s: the detection was not recorded in the dataset manifest: %s\n', ...
                    job.label, ME.message);
                obj.warnPage(['not recorded in the dataset manifest: ' ME.message]);
            end

            % --- Optionally save the resized image as TIF ---
            % Written once per source file in a run, by the first of its jobs
            % that completes (so a skipped or failed first page does not lose
            % it); in Ignore mode an existing TIF is kept (resizedTifDue). The
            % per-file preprocessing cache remembers it. All pages of the
            % source file are resized using the page-map settings for each page
            % (falling back to no-op for unmapped pages) so the output TIF has
            % the same number of pages as the input TIF.
            if obj.hSaveLsmTif.Value
                try
                    obj.ensurePreprocCache(job.imgFile, job.nPages);
                    if CellDiscovery.resizedTifDue(true, obj.preprocCache.tifWritten, ...
                            obj.hOverwriteRad.Value, isfile(job.outTif))
                        obj.preprocCache.tifWritten = true;   % once per file, even if the write fails
                        obj.writeFullPreprocTif(job);
                    end
                catch ME
                    fprintf('[WARN] TIF save failed for %s: %s\n', job.label, ME.message);
                    obj.warnPage(['resized TIF not saved: ' ME.message]);
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
                obj.warnPage(['result figure not drawn (no PNG, no diagnostic pause): ' ME.message]);
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
                hResFig = hResFig(1);   % redrawn by handle: never raised, so it does not take the focus
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
                    obj.warnPage('PNG not saved');
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

            % A normalised detector input exists only as the scratch image; the
            % cached page is the same image before intensity normalisation.
            detImg = [];
            if isfield(job, 'normalize') && job.normalize
                try detImg = imread(job.tmpImg); catch, end
            end
            if isempty(detImg) && ~isempty(obj.preprocCache) && isfield(obj.preprocCache, 'pages') ...
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
                'TooltipString', 'Close this view and go on with the next page of the batch.', ...
                'String', 'Continue', 'Callback', @(~,~) uiresume(hDiag));
            uicontrol(hDiag, 'Style', 'pushbutton', 'Units', 'normalized', ...
                'Position', [0.79 0.02 0.18 0.07], 'ForegroundColor', [0.6 0 0], ...
                'TooltipString', 'End the batch here (the page shown is already finished and kept).', ...
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
                % The main window's stop request, so its button shows Abort now.
                % The page shown is finished already, so this never aborts.
                fprintf('[STOP] Stop requested from diagnostic window.\n');
                if ~obj.stopRequested
                    obj.requestStop();
                end
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
                obj.warnPage('snap skipped: snapToCellCentroid.m is not on the MATLAB path');
                return;
            end
            if ~all(ismember({'X','Y'}, T.Properties.VariableNames)) || height(T) == 0
                return;
            end

            opts    = CellDiscovery.sanitizeSnapOptions(job.snapOptions);
            args    = CellDiscovery.snapOptionsToNameValue(opts);
            applyXY = CellToolkit.parseLogical(opts.ApplyToXY, false);

            % Snap sizes its windows as CellDiameter / PixelSize on the
            % source-resolution page, so PixelSize must be the SOURCE pixel
            % size, not the training one. 'auto' (the default) supplies it from
            % the TIFF calibration (or, without one, from the resize factor).
            iPx = find(strcmp(args(1:2:end), 'PixelSize'), 1);
            if isempty(iPx)
                args = [args, {'PixelSize', job.srcPixelSize}];
            elseif isnumeric(args{2*iPx}) && isscalar(args{2*iPx}) ...
                    && abs(args{2*iPx} / job.srcPixelSize - 1) > CellDiscovery.PIXEL_SIZE_TOL
                fprintf(2, ['[WARN] %s: Snap PixelSize is set to %g um/px but the page snap runs on is ' ...
                    '%.4g um/px; set PixelSize to ''auto'' in Snap options unless this is intended.\n'], ...
                    job.label, args{2*iPx}, job.srcPixelSize);
            end

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

        function ensurePreprocCache(obj, imgFile, nPages)
            % Preprocess every page of imgFile exactly once and cache the result
            % on obj.preprocCache, keyed by file path. Both the per-page
            % detection scratch images and the optional output TIF draw from this
            % single cache, so the model and the saved TIF share the same
            % geometry and preprocessing (the scratch image alone is then
            % intensity-normalised when the page's Normalize box is ticked), and
            % the expensive joint-channel LSM correction runs once.
            if ~isempty(obj.preprocCache) && isfield(obj.preprocCache, 'imgFile') ...
                    && strcmp(obj.preprocCache.imgFile, imgFile)
                return;   % cache already valid for this file
            end
            mapData                   = obj.hPageTable.Data;
            [pages, rzArr, pagesFull, lsmIdx] = CellDiscovery.preprocessAllPages(imgFile, nPages, mapData, obj.P.lsmOptions);
            % tifWritten: this file's *_resized.tif has been written (or its
            % write attempted) in this run; see finishOutputs / resizedTifDue.
            obj.preprocCache = struct('imgFile', imgFile, 'pages', {pages}, ...
                'rzArr', rzArr, 'pagesFull', {pagesFull}, 'lsmIdx', lsmIdx, ...
                'tifWritten', false);
        end

        function writeFullPreprocTif(obj, job)
            % Write a multi-page resized TIF whose page count matches the
            % source file, using the already-computed per-file cache so the saved
            % image is what the detection model received, before the optional
            % intensity normalisation of the detector input.
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
            % End the batch: kill a subprocess still running, stop the timer,
            % remove the run's scratch folder, print the run's summary (failed
            % pages and warnings by name) and put its counts in the progress
            % label (red when a page failed), unlock the window.
            if isempty(obj.hFig) || ~isvalid(obj.hFig), return; end

            obj.killProcess();
            if ~isempty(obj.inFlight)   % only after an internal error
                obj.dropInFlight(obj.inFlight.job);
            end

            if ~isempty(obj.timerObj) && isvalid(obj.timerObj)
                stop(obj.timerObj);
                delete(obj.timerObj);
            end
            obj.timerObj = [];
            obj.preprocCache = [];   % release cached resized pages
            obj.removeScratchDir();

            % The run's tally: counts in the label, names in the Command Window.
            t = obj.tally;
            if isempty(t)
                t = CellDiscovery.newTally(numel(obj.jobQueue), 0);
            end
            t.notRun = max(numel(obj.jobQueue) - obj.fileIdx + 1, 0);
            if ~isempty(t.error)
                t.state = 'error';
            elseif ~isempty(t.aborted)
                t.state = 'aborted';
            elseif obj.stopRequested || obj.abortRequested
                t.state = 'stopped';
            else
                t.state = 'complete';
            end
            obj.tally = t;
            [label, lines, failed] = CellDiscovery.tallySummary(t);
            fprintf('%s\n', lines{:});
            obj.hProgressLabel.Text = label;
            if failed
                obj.hProgressLabel.FontColor = CellDiscovery.LABEL_FAIL_COLOR;
            else
                obj.hProgressLabel.FontColor = CellDiscovery.LABEL_COLOR;
            end

            obj.setUIEnable(true);
            obj.setStopButton('stop');
            obj.hStopBtn.Enable  = false;
            obj.hStartBtn.Enable = true;
            set(obj.hFig, 'Pointer', 'arrow');
            obj.markQueuedDone();   % the files this run finished show as done
            drawnow;

        end


        %% The page in flight: its end, the tally, the stage log


        function failJob(obj, job, reason)
            % Count the job at fileIdx as failed (label + reason), drop its scratch
            % files and move on to the next job.
            obj.tally.failed(end+1, 1) = struct('label', job.label, 'reason', reason);
            obj.logStage(job, 'fail');
            obj.dropInFlight(job);
            obj.fileIdx = obj.fileIdx + 1;
        end

        function doneJob(obj, job)
            % Count the page in flight as done, with the warnings it collected;
            % drop its scratch files and move on to the next job.
            obj.tally.done = obj.tally.done + 1;
            for k = 1:numel(obj.pageWarnings)
                obj.tally.warnings(end+1, 1) = struct('label', job.label, 'reason', obj.pageWarnings{k});
            end
            obj.logStage(job, 'finish');
            obj.dropInFlight(job);
            obj.fileIdx = obj.fileIdx + 1;
        end

        function endOfPage(obj)
            % After the page in flight ended (done or failed): a Stop (or an Abort
            % clicked while it finished) ends the batch here.
            if obj.stopRequested || obj.abortRequested
                fprintf('[STOP] Batch stopped by user.\n');
                obj.batchCleanup();
            end
        end

        function abortInFlight(obj)
            % Abort now: kill the running subprocess and discard the page in
            % flight with its scratch files. Nothing of it is written: its CSVs,
            % manifest entry and TIF come only in its finish stage.
            obj.killProcess();
            if isempty(obj.inFlight), return; end
            job = obj.inFlight.job;
            fprintf('[STOP] Aborted %s: the page is discarded, nothing was written for it.\n', job.label);
            obj.tally.aborted = job.label;
            obj.logStage(job, 'abort');
            obj.dropInFlight(job);
            obj.fileIdx = obj.fileIdx + 1;
        end

        function dropInFlight(obj, job)
            % Delete the scratch files of JOB (its detector input, predict.py's CSV
            % and score.py's input and output) and forget the page in flight.
            files = {job.tmpImg, job.tmpCsv};
            if ~isempty(obj.inFlight)
                files = [files, {obj.inFlight.scoreIn, obj.inFlight.scoreOut}];
            end
            CellToolkit.deleteFiles(files);
            obj.inFlight = [];
            obj.pageWarnings = {};
        end

        function warnPage(obj, reason)
            % A problem of the page in flight that does not fail it (snap,
            % rescoring, manifest, TIF, PNG); it reaches the tally if the page
            % completes (doneJob).
            obj.pageWarnings{end+1} = reason;
        end

        function logStage(obj, job, event)
            % Append an event of the job at fileIdx to the run's stage log
            % (stageLog): the timer tick it happened in and the seconds since Start.
            secs = NaN;
            if ~isempty(obj.runClock), secs = toc(obj.runClock); end
            obj.stageEvents(end+1, 1) = struct('Job', obj.fileIdx, 'Label', string(job.label), ...
                'Event', string(event), 'Tick', obj.tickCount, 'Seconds', secs);
        end

        function killProcess(obj)
            % Kill the running subprocess, if any, with the processes it started:
            % with a conda env it is conda.exe, and predict.py / score.py run in a
            % child that destroyForcibly does not take down. Every process of the
            % run has the run's scratch folder on its command line, so the rest
            % are found by its unique name (killByCommandLine).
            if isempty(obj.jProcess), return; end
            try
                obj.jProcess.destroyForcibly();
                obj.jProcess.waitFor(5, java.util.concurrent.TimeUnit.SECONDS);
            catch
            end
            try obj.jReader.close(); catch, end
            obj.jProcess = [];
            obj.jReader  = [];
            [~, runName] = fileparts(obj.tmpDir);
            CellDiscovery.killByCommandLine(runName);
            fprintf('[STOP] Subprocess terminated.\n');
        end

        function removeScratchDir(obj)
            % Remove this run's scratch folder with its contents (tmpDir keeps
            % its name, for batchState).
            d = obj.tmpDir;
            if isempty(d) || ~isfolder(d), return; end
            [ok, msg] = rmdir(d, 's');
            if ~ok
                fprintf(2, '[WARN] Could not remove the scratch folder %s: %s\n', d, msg);
            end
        end


        %% Enable / disable all interactive controls


        function setUIEnable(obj, state)
            ctrls = { ...
                obj.hDirEdit,     obj.hRegexEdit,    obj.hPyEdit, ...
                obj.hCondaExeEdit, obj.hCondaEdit,   obj.hTestEnvBtn, ...
                obj.hDeviceEdit,  obj.hBatchEdit,    obj.hThrEdit, ...
                obj.hIgnoreRad,   obj.hOverwriteRad, ...
                obj.hColormapPop, obj.hAutoContrast,  obj.hSavePng, obj.hSaveLsmTif, ...
                obj.hDotColorPop, obj.hDotSizeEdit, ...
                obj.hAddPageBtn,  obj.hDelPageBtn, ...
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


        %% Internal cleanup (timer, process, scratch folder; no figure delete)


        function cleanup(obj)
            if ~isempty(obj.timerObj) && isvalid(obj.timerObj)
                stop(obj.timerObj);
                delete(obj.timerObj);
                obj.timerObj = [];
            end
            obj.killProcess();
            obj.inFlight = [];
            obj.removeScratchDir();
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

        function job = jobForRow(f, fdir, stem, nPages, row, detM, rescM, lsmOptions, snapOpts)
            % The job of one page-map row (a 1 x 9 cell, older 8-column rows
            % accepted) for image f: the preprocessing settings of the row, the
            % resolved resize factor and pixel size. buildJobs calls it per row.
            pg = CellToolkit.parseNum(row{1}, 0);
            correctLSM = CellToolkit.parseLogical(row{5}, false);
            bg = CellToolkit.parseNum(row{6}, 0);
            [rz, srcUm, rzMode] = CellDiscovery.resolveResize( ...
                f, pg, CellToolkit.parseNum(row{7}, 1));
            snapOn = false;
            if numel(row) >= 8
                snapOn = CellToolkit.parseLogical(row{8}, false);
            end
            normOn = true;
            if numel(row) >= 9
                normOn = CellToolkit.parseLogical(row{9}, true);
            end
            job = CellDiscovery.makeJob( ...
                f, fdir, stem, row{2}, pg, nPages, detM, rescM, correctLSM, bg, rz, lsmOptions, snapOn, snapOpts);
            job.normalize = normOn;
            job.resizeMode = rzMode;    % 'auto' | 'manual' | 'uncalibrated' (recorded with the detection)
            job.calibratedUm = srcUm;   % NaN when the TIFF has no usable calibration
            if isfinite(srcUm)
                job.srcPixelSize = srcUm;
            else
                % No calibration: the resize factor is the user's
                % statement of the source pixel size.
                job.srcPixelSize = CellDiscovery.TRAIN_UM_PER_PIXEL * rz;
            end
        end

        function job = makeJob(f, fdir, stem, suffix, pg, nPages, detM, rescM, correctLSM, bg, rz, lsmOptions, snapEnable, snapOptions)
            % Assemble a single processing-job struct. Every job is one page of
            % a file: <stem>_<suffix><page>_locs.csv.
            if nargin < 13, snapEnable = false; end
            if nargin < 14, snapOptions = CellDiscovery.defaultSnapOptions(); end
            [outCsv, base] = CellDiscovery.outputCsvPath(fdir, stem, suffix, pg);
            imgName = base;                              % identity in CSV
            label   = sprintf('%s  (page %d/%d)', stem, pg, nPages);

            job = struct();
            job.imgFile      = f;
            job.imgDir       = fdir;
            job.stem         = stem;
            job.base         = base;
            job.imgName      = imgName;
            job.page         = pg;
            job.nPages       = nPages;
            job.detModel     = detM;
            job.rescoreModel = rescM;     % '' = no rescoring
            job.correctLSM   = logical(correctLSM);  % true = correct bidirectional LSM artifact
            job.lsmOptions   = CellDiscovery.sanitizeLSMOptions(lsmOptions);
            job.snapEnable   = logical(snapEnable);  % true = run snapToCellCentroid post-processing
            job.snapOptions  = CellDiscovery.sanitizeSnapOptions(snapOptions);
            job.bgRadius     = bg;        % 0 = no background subtraction
            job.resize       = rz;        % 1 = no resizing (resolved factor; see resolveResize)
            job.resizeMode   = '';        % set by jobForRow: 'auto' | 'manual' | 'uncalibrated'
            job.lsmPages     = [];        % set at launch: pages LSM-corrected together with this one
            job.normalize    = false;     % set by jobForRow: normalise detector-input intensity
            job.normLimits   = [];        % [lo hi] source intensities mapped to [0 NORM_TARGET] (set at launch)
            job.calibratedUm = NaN;       % set by jobForRow: source um/px from the TIFF calibration (NaN = none)
            job.srcPixelSize = CellDiscovery.TRAIN_UM_PER_PIXEL * rz;   % best estimate of the source um/px
            job.outCsvOrig   = outCsv;
            job.outTif       = fullfile(fdir, [stem '_resized.tif']);   % shared across pages
            if rz ~= 1
                job.outCsvResized = fullfile(fdir, [base '_locs_resized.csv']);
            else
                job.outCsvResized = '';
            end
            job.tmpImg    = '';   % scratch page image (set at launch)
            job.tmpCsv    = '';   % predict.py raw output (set at launch)
            job.label     = label;
        end

        function [rz, srcUm, mode] = resolveResize(imgFile, page, tableRz)
            % Resolve a page's resize factor from its page-map "Resize x" value.
            %   tableRz > 0 : manual factor, used as given        (mode 'manual')
            %   otherwise   : auto — the factor that brings the page to the
            %                 training pixel size, from the TIFF calibration
            %                 (mode 'auto'); x1 if the file has no usable
            %                 calibration                          (mode 'uncalibrated')
            % srcUm is the calibrated source pixel size in um (NaN if none).
            % Both buildJobs and preprocessAllPages resolve through here, so the
            % job's factor always matches the pixels the detector receives.
            srcUm = CellToolkit.tiffPixelSizeUm(imgFile, page);
            if tableRz > 0
                rz = tableRz;  mode = 'manual';
            elseif isfinite(srcUm)
                rz = round(srcUm / CellDiscovery.TRAIN_UM_PER_PIXEL, 4);
                if abs(rz - 1) < 0.01, rz = 1; end   % already at the training pixel size
                mode = 'auto';
            else
                rz = 1;  mode = 'uncalibrated';
            end
        end

        function reportScale(job, mode)
            % Log a job's pixel-size handling and warn when the detector input
            % will be off the training pixel size.
            train = CellDiscovery.TRAIN_UM_PER_PIXEL;
            switch mode
                case 'auto'
                    fprintf('[SCALE] %s: %.4g um/px (TIFF calibration) -> resize x%.4g (auto) -> %.3g um/px\n', ...
                        job.label, job.calibratedUm, job.resize, job.calibratedUm / job.resize);
                case 'uncalibrated'
                    fprintf(2, ['[WARN] %s: no usable pixel-size calibration in the TIFF, so auto resize cannot be ' ...
                        'computed and the page is used unresized. If it is not %g um/px, enter Resize x = ' ...
                        '(source um/px) / %g.\n'], job.label, train, train);
                otherwise   % manual
                    if isfinite(job.calibratedUm)
                        eff = job.calibratedUm / job.resize;
                        fprintf('[SCALE] %s: %.4g um/px (TIFF calibration) -> resize x%.4g (manual) -> %.3g um/px\n', ...
                            job.label, job.calibratedUm, job.resize, eff);
                        if abs(eff / train - 1) > CellDiscovery.PIXEL_SIZE_TOL
                            fprintf(2, ['[WARN] %s: the detector will see %.3g um/px but the models were trained at ' ...
                                '%g um/px. Set Resize x to 0 (auto = x%.4g) unless this is intended.\n'], ...
                                job.label, eff, train, job.calibratedUm / train);
                        end
                    else
                        fprintf('[SCALE] %s: resize x%.4g (manual; TIFF has no pixel-size calibration)\n', ...
                            job.label, job.resize);
                    end
            end
        end

        function [img, lims] = detectorInputPage(page, normalize)
            % The detector-input image of a cached page (LSM, background and resize
            % already applied by preprocessAllPages): intensity-normalised when the
            % page's Normalize box is ticked, in the class the scratch TIFF stores.
            % CellToolkit.modelInputPage does both, so the curation exports and
            % rescoring regenerate exactly this image. lims = the [lo hi] used
            % ([] when not normalised).
            [img, info] = CellToolkit.modelInputPage(page, struct('normalized', normalize, ...
                'normPercentiles', CellDiscovery.NORM_PERCENTILES, 'normTarget', CellDiscovery.NORM_TARGET));
            lims = info.normLimits;
        end

        function facts = detectionFacts(job)
            % The model-input facts of a job, recorded in the manifest's detection
            % stage so the exact detector input can be regenerated later
            % (CellToolkit.modelInputFactsFor / modelInputFromFile; see
            % CellToolkit's "Model input" section for the meaning of each field).
            facts = struct('resize', job.resize, 'resizeMode', job.resizeMode, ...
                'bgRadius', job.bgRadius, 'correctLSM', logical(job.correctLSM), ...
                'normalized', logical(job.normalize), 'normLimits', job.normLimits);
            if isfield(job, 'calibratedUm') && isfinite(job.calibratedUm)
                facts.srcUmPerPixel = job.calibratedUm;
            end
            if job.normalize
                facts.normPercentiles = CellDiscovery.NORM_PERCENTILES;
                facts.normTarget      = CellDiscovery.NORM_TARGET;
            end
            if job.correctLSM
                facts.lsmPages = job.lsmPages;
                % the options in their stored text form (JSON keeps text exactly;
                % numeric arrays would come back as columns)
                opts = CellDiscovery.sanitizeLSMOptions(job.lsmOptions);
                names = fieldnames(opts);
                for k = 1:numel(names)
                    opts.(names{k}) = CellDiscovery.lsmOptionValueToText(opts.(names{k}));
                end
                facts.lsmOptions = opts;
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

        function args = lsmOptionsToNameValue(opts)
            % Name-value cell for correctBidirectionalLSMArtifact from the persisted
            % options (sanitised: every supported option, defaults filled in).
            % The parsing is CellToolkit's, shared with modelInputFromFile.
            args = CellToolkit.lsmNameValue(CellDiscovery.sanitizeLSMOptions(opts));
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
            % Columns: Page, Suffix, Detection model, Rescore model, LSM,
            % Bg radius, Resize x (0 = auto from TIFF calibration), Snap, Normalize.
            data = {1, CellDiscovery.DEFAULT_SUFFIX, '(none)', '(none)', false, 0, 0, false, true};
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
            elseif size(data, 2) ~= 8 && size(data, 2) ~= 9
                data = CellDiscovery.defaultPageMap();
            end
            if size(data, 2) == 8
                % Pre-Normalize layout: append the Normalize column (on).
                data = [data, repmat({true}, size(data,1), 1)];
            end
            detFallback = detChoices{min(2, numel(detChoices))};   % first real model if any
            for r = 1:size(data, 1)
                % Page index
                p = CellToolkit.parseNum(data{r,1}, 1);
                if p < 1, p = 1; end
                data{r,1} = round(p);
                % Suffix. A char suffix is kept as saved (existing results are
                % named after it); anything else becomes the default 'page'.
                s = data{r,2};
                if isstring(s) && isscalar(s) && ~ismissing(s), s = char(s); end
                if ~ischar(s), s = CellDiscovery.DEFAULT_SUFFIX; end
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
                % Resize factor (> 0), or 0 = auto from the TIFF calibration
                z = CellToolkit.parseNum(data{r,7}, 1);
                if ~(z > 0), z = 0; end
                data{r,7} = z;
                % Snap (snapToCellCentroid post-processing)
                data{r,8} = CellToolkit.parseLogical(data{r,8}, false);
                % Normalize (intensity normalisation of the detector input)
                data{r,9} = CellToolkit.parseLogical(data{r,9}, true);
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
                'PixelSize',             'num',  {},                                                       'auto',   'Microns per pixel of the SOURCE page snap runs on. auto = from the TIFF calibration (or 0.645 x the resize factor when the file has none).'
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

        function [pages, rzArr, pagesFull, lsmIdx] = preprocessAllPages(imgFile, nPages, mapData, lsmOptions)
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
            % lsmIdx lists the pages corrected together (recorded with each
            % detection as lsmPages).
            %
            % The steps are CellToolkit's (lsmCorrectPages, modelInputPage), so
            % the curation exports and rescoring can regenerate exactly the
            % detector input from the facts recorded in the manifest.

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
                    rzArr(pg)   = CellDiscovery.resolveResize( ...
                        imgFile, pg, CellToolkit.parseNum(mapData{r,7}, 1));
                end
            end

            % Joint-channel LSM correction (once for all LSM-requested pages).
            % Only pages that have wantLSM=true are corrected; others stay raw.
            % CellToolkit.lsmCorrectPages stacks them (when same-size, single-
            % channel and more than one) and corrects them in one call.
            lsmIdx = find(wantLSM);   % indices of pages that want LSM
            corrPages = rawPages;     % start as copy; overwrite LSM pages below
            if ~isempty(lsmIdx)
                corrPages(lsmIdx) = CellToolkit.lsmCorrectPages(rawPages(lsmIdx), ...
                    CellDiscovery.lsmOptionsToNameValue(lsmOptions));
            end

            % Per-page background subtraction (LSM already applied above), then
            % resize, by CellToolkit.modelInputPage without its intensity step
            % (the detector input is normalised at launch, detectorInputPage).
            % pagesFull holds the bg-subtracted page at source resolution (snap
            % input); pages the resized one (detector input before normalisation,
            % and what the optional *_resized.tif saves).
            pages     = cell(1, nPages);
            pagesFull = cell(1, nPages);
            for pg = 1:nPages
                [~, pinfo] = CellToolkit.modelInputPage(corrPages{pg}, ...
                    struct('bgRadius', bgArr(pg), 'resize', rzArr(pg)));
                pagesFull{pg} = pinfo.full;
                pages{pg}     = pinfo.resized;
            end
        end

        function writeScratchTiff(img, path)
            % Write a single-page scratch TIFF.  The Tiff low-level class is used
            % instead of imwrite() so float32, uint8, uint16, int16, and uint32
            % source images are all handled correctly.  The file is always a
            % single-page overwrite.
            % double -> single (Tiff supports float32; float64 is exotic), and any
            % other unsupported class -> uint8: CellToolkit.modelInputClass, the
            % class the models read (shared with modelInputPage).
            img = CellToolkit.modelInputClass(img);
            t = Tiff(path, 'w');
            closeTiff = onCleanup(@() t.close());   % also when a write fails: no file left locked
            img = CellDiscovery.setPageTags(t, img, Tiff.Photometric.MinIsBlack);
            t.write(img);
            clear closeTiff   % closes the file
        end

        function img = setPageTags(t, img, phot)
            % The tags both TIFF writers share, set on the open handle t for the
            % current page: size, photometric interpretation, bits per sample and
            % sample format from the class of img (any class other than single,
            % uint16, int16 and uint32 is converted to uint8, and returned),
            % chunky planes, no compression.
            nCh = size(img, 3);
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
        end

        function n = killByCommandLine(marker)
            % Kill the processes (never MATLAB itself) whose command line contains
            % MARKER (letters, digits and underscores only), through WMI. Windows
            % only and best effort; returns how many were killed.
            n = 0;
            if ~ispc || isempty(marker) || isempty(regexp(marker, '^\w+$', 'once')), return; end
            try
                NET.addAssembly('System.Management');
                % In a LIKE pattern an underscore matches any one character: [_] is a literal one.
                q = sprintf('SELECT ProcessId FROM Win32_Process WHERE CommandLine LIKE ''%%%s%%''', ...
                    strrep(marker, '_', '[_]'));
                en = System.Management.ManagementObjectSearcher(q).Get().GetEnumerator();
                me = feature('getpid');
                while en.MoveNext()
                    pid = double(en.Current.GetPropertyValue('ProcessId'));
                    if pid == me, continue; end
                    try
                        p = System.Diagnostics.Process.GetProcessById(int32(pid));
                        p.Kill();
                        p.WaitForExit(int32(3000));
                        n = n + 1;
                    catch
                    end
                end
            catch
            end
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
            img = CellDiscovery.setPageTags(t, img, phot);

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
            if isfield(job, 'normalize') && job.normalize
                parts{end+1} = 'normalised';
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


    %% ---- Pure helpers (also the test seams of tDiscovery) ------------------
    methods (Static, Hidden)

        function [folder, opts] = parseConstructorArgs(varargin)
            % The constructor's arguments: CellDiscovery(folder, Name, Value, ...)
            % or CellDiscovery(Name, Value, ...). An odd number of arguments
            % starts with the folder ('' = none). Options: PrefGroup (setpref
            % group, a valid MATLAB name), Search (logical).
            folder = '';
            args = varargin;
            if mod(numel(args), 2) == 1
                folder = args{1};
                args = args(2:end);
                if ~(ischar(folder) || (isstring(folder) && isscalar(folder)))
                    error('CellDiscovery:badFolder', 'CellDiscovery(folder, ...): the folder must be text.');
                end
                folder = strtrim(char(folder));
            end
            isText = @(x) ischar(x) || (isstring(x) && isscalar(x));
            p = inputParser;
            p.FunctionName = 'CellDiscovery';
            p.addParameter('PrefGroup', CellDiscovery.PREF_GROUP, @(x) isText(x) && isvarname(char(x)));
            p.addParameter('Search', true, @(x) (islogical(x) || isnumeric(x)) && isscalar(x));
            p.parse(args{:});
            opts = p.Results;
            opts.PrefGroup = char(opts.PrefGroup);
            opts.Search = logical(opts.Search);
        end

        function writePrefs(group, P)
            % Save every field of the struct P as a preference of GROUP in one
            % setpref call (each call rewrites the preferences file).
            setpref(group, fieldnames(P), struct2cell(P));
        end

        function [files, nHidden] = hideDerivedImages(files)
            % Drop the tool's own outputs, <stem>_resized.tif / .tiff (any case),
            % from a list of file paths; nHidden = how many were dropped.
            nHidden = 0;
            if isempty(files), return; end
            derived = ~cellfun(@isempty, regexpi(files, '_resized\.tiff?$', 'once'));
            nHidden = nnz(derived);
            files = files(~derived);
        end

        function txt = fileCountText(n, nHidden, nDone)
            % The file-count label of a search: "12 files found (3 *_resized.tif
            % hidden)"; given NDONE (files whose pages all have results), also
            % "132 files found · 97 done (3 *_resized.tif hidden)".
            txt = sprintf('%d file%s found', n, CellToolkit.ternary(n == 1, '', 's'));
            if nargin >= 3 && n > 0
                txt = sprintf('%s %c %d done', txt, char(183), nDone);   % middle dot
            end
            if nHidden > 0
                txt = sprintf('%s (%d *_resized.tif hidden)', txt, nHidden);
            end
        end

        function pos = windowPosition(screenSize)
            % The main window's [x y width height] on a screen of SCREENSIZE =
            % [width height] pixels: the designed 1300 x 1010, cut to leave room
            % for the taskbar below and the title bar above, and centred.
            designW = 1300; designH = 1010;
            taskbar = 48; titleBar = 40; slack = 8;
            w = screenSize(1); h = screenSize(2);
            usableH = h - taskbar - titleBar - slack;
            W = min(designW, max(w - 40, 320));
            H = min(designH, max(usableH, 300));
            x = 1 + floor((w - W) / 2);
            y = 1 + taskbar + floor((usableH - H) / 2);
            pos = [x y W H];
        end

        function csvs = resultCsvsOf(files)
            % The *_locs.csv files of a directory listing (a cellstr of paths):
            % all the "done" marks need of it.
            files = files(:);
            if isempty(files), csvs = {}; return; end
            csvs = files(endsWith(files, '_locs.csv', 'IgnoreCase', true));
        end

        function want = wantedCsvs(files, mapData)
            % The result CSVs (outputCsvPath) of each file (rows) for each active
            % page-map row (columns): a numel(files) x nActiveRows cellstr.
            rows = [];
            for r = 1:size(mapData, 1)
                if CellDiscovery.isActiveRow(mapData(r, :)), rows(end+1) = r; end %#ok<AGROW>
            end
            want = cell(numel(files), numel(rows));
            for i = 1:numel(files)
                [fdir, stem] = fileparts(files{i});
                if isempty(fdir), fdir = pwd; end
                for k = 1:numel(rows)
                    row = mapData(rows(k), :);
                    want{i, k} = CellDiscovery.outputCsvPath(fdir, stem, row{2}, CellToolkit.parseNum(row{1}, 0));
                end
            end
        end

        function done = filesDone(files, mapData, listing)
            % Which FILES are detected already: done(i) is true when the file has
            % at least one active page-map row and every one of them has its
            % result CSV (wantedCsvs) among the paths of LISTING (a cellstr: the
            % search's directory listing). No disk access; file names compare
            % without regard to case on Windows.
            files = files(:);
            done = false(numel(files), 1);
            want = CellDiscovery.wantedCsvs(files, mapData);
            if isempty(files) || isempty(want), return; end
            have = listing(:);
            if ispc
                want = lower(want); have = lower(have);
            end
            found = reshape(ismember(want(:), have), size(want));
            done = all(found, 2);
        end

        function labels = fileLabels(relPaths, done)
            % The file list's labels: the relative paths, a check mark in front of
            % the files that are done (the others are indented to line up).
            labels = relPaths;
            for k = 1:numel(labels)
                labels{k} = [CellToolkit.ternary(done(k), [char(10003) ' '], '   ') relPaths{k}];
            end
        end

        function errs = checkFields(device, batchSize, threshold)
            % Problems of the free-text predict.py fields (cellstr, empty when
            % all are fine): Device cpu | mps | cuda | cuda:<n> (case and
            % surrounding blanks ignored), Batch size a positive whole number,
            % Threshold blank or a number from 0 to 1.
            errs = {};
            device = strtrim(char(string(device)));
            if isempty(regexpi(device, '^(cpu|mps|cuda(:\d+)?)$', 'once'))
                errs{end+1} = sprintf('Device ''%s'' is not valid. Accepted: cpu, mps, cuda or cuda:<n> (e.g. cuda:0).', device);
            end
            b = strtrim(char(string(batchSize)));
            if isempty(regexp(b, '^\d+$', 'once')) || str2double(b) < 1
                errs{end+1} = sprintf('Batch size ''%s'' is not valid. Accepted: a positive whole number (e.g. 1).', b);
            end
            t = strtrim(char(string(threshold)));
            if ~isempty(t)
                v = str2double(t);
                if ~isfinite(v) || v < 0 || v > 1
                    errs{end+1} = sprintf('Threshold ''%s'' is not valid. Accepted: a number from 0 to 1, or blank for the model''s default.', t);
                end
            end
        end

        function [action, msg] = gpuCheck(device, cudaAvailable)
            % What Start does about the Device given whether CUDA is available
            % (true | false | NaN = unknown): 'block' (a cuda device and no CUDA),
            % 'hint' (cpu although a GPU is available; does not block) or 'ok'.
            action = 'ok'; msg = '';
            device = lower(strtrim(char(string(device))));
            if isnan(cudaAvailable), return; end
            if startsWith(device, 'cuda') && ~cudaAvailable
                action = 'block';
                msg = sprintf(['Device is ''%s'' but PyTorch in this Python environment reports no CUDA GPU. ' ...
                    'Set Device to cpu, or choose an environment with a CUDA build of PyTorch.'], device);
            elseif strcmp(device, 'cpu') && cudaAvailable
                action = 'hint';
                msg = 'A GPU (CUDA) is available in this environment but Device is cpu; set Device to cuda:0 to detect faster.';
            end
        end

        function key = envKey(pythonExe, condaExe, condaEnv)
            % What a passed environment check holds for: the Python executable,
            % the conda executable and the conda env (trimmed).
            key = strjoin({strtrim(char(string(pythonExe))), strtrim(char(string(condaExe))), ...
                strtrim(char(string(condaEnv)))}, '|');
        end

        function txt = envStatusText(cudaAvailable)
            % The words of a passed environment check, e.g. "Environment OK, GPU available" (joined by a middle dot).
            dot = char(183);   % middle dot
            if isnan(cudaAvailable)
                txt = 'Environment OK';
            elseif cudaAvailable
                txt = ['Environment OK ' dot ' GPU available'];
            else
                txt = ['Environment OK ' dot ' no GPU (CUDA not available)'];
            end
        end

        function close = askCloseWhileRunning(fig)
            % The default ConfirmCloseFcn: ask whether to stop the running batch
            % and close the window (true) or keep it running (false, the default).
            stopText = 'Stop the batch and close';
            keepText = 'Keep it running';
            sel = uiconfirm(fig, ['A batch is running. Closing the window stops it now and discards the page ' ...
                'in flight (pages already finished are kept).'], 'Close while running?', ...
                'Options', {stopText, keepText}, 'DefaultOption', keepText, 'CancelOption', keepText, ...
                'Icon', 'warning');
            close = strcmp(sel, stopText);
        end

        function tf = isActiveRow(row)
            % A page-map row (1 x 9 cell) the batch runs: page >= 1 and a
            % detection model assigned (not empty, not the (skip) label).
            pg = CellToolkit.parseNum(row{1}, 0);
            detM = row{3};
            tf = pg >= 1 && ischar(detM) && ~isempty(detM) && ~strcmp(detM, CellDiscovery.SKIP_LABEL);
        end

        function [errs, warns] = checkPageMap(mapData)
            % Problems of a page map that Start checks (cellstr messages).
            % errs:  a page in more than one active row (isActiveRow), or whose
            %        last row is inactive while an earlier one is active.
            %        preprocessAllPages preprocesses each page with the LAST row
            %        that names it (active or not), while every job maps its
            %        detections back with its own row's resize factor, so the
            %        coordinates would be wrong. An inactive row above the
            %        active one is harmless.
            % warns: an active row whose suffix is empty or not letters only. The
            %        output is <stem>_<suffix><page>_locs.csv and
            %        CellToolkit.pageFromIdentity reads the page from
            %        _<letters><page>, so such a name loses or changes the page.
            errs = {}; warns = {};
            if isempty(mapData) || ~iscell(mapData), return; end
            n = size(mapData, 1);
            pages = zeros(n, 1);
            active = false(n, 1);
            for r = 1:n
                pages(r) = round(CellToolkit.parseNum(mapData{r,1}, 0));
                active(r) = CellDiscovery.isActiveRow(mapData(r, :));
            end
            for pg = unique(pages(active))'
                rows = find(pages == pg);
                if nnz(active(rows)) > 1 || ~active(rows(end))
                    errs{end+1} = sprintf(['Page %d is in rows %s. The page is preprocessed with the ' ...
                        'settings of the last of them (row %d), but each active row maps its detections ' ...
                        'back with its own resize factor, so the coordinates would be wrong. Keep one ' ...
                        'row for page %d.'], pg, char(strjoin(string(rows'), ', ')), rows(end), pg); %#ok<AGROW>
                end
            end
            for r = find(active)'
                sfx = mapData{r,2};
                if isstring(sfx) && isscalar(sfx), sfx = char(sfx); end
                if ~ischar(sfx), sfx = ''; end
                if ~isempty(regexp(sfx, '^[A-Za-z]+$', 'once')), continue; end
                pg = pages(r);
                name = sprintf('<stem>_%s%d_locs.csv', sfx, pg);
                readAs = CellToolkit.pageFromIdentity(sprintf('x_%s%d', sfx, pg));
                if isnan(readAs)
                    effect = 'has no page number the other Cell* tools can read';
                elseif readAs ~= pg
                    effect = sprintf('is read as page %d', readAs);
                else
                    effect = 'does not follow the <stem>_<letters><page> naming convention';
                end
                if isempty(sfx)
                    what = 'the suffix is empty';
                else
                    what = sprintf('suffix ''%s'' is not letters only', sfx);
                end
                warns{end+1} = sprintf('Page-map row %d (page %d): %s, so the result %s %s. Use letters only, e.g. ''%s''.', ...
                    r, pg, what, name, effect, CellDiscovery.DEFAULT_SUFFIX); %#ok<AGROW>
            end
        end

        function [csv, base] = outputCsvPath(fdir, stem, suffix, page)
            % The detection CSV of one page-map row for the image <fdir>\<stem>.*:
            % base = <stem>_<suffix><page> (the per-page identity) and
            % csv = <fdir>\<base>_locs.csv. makeJob and pendingRows (the Ignore-
            % mode pre-filter) both name it here, so they cannot drift apart.
            base = sprintf('%s_%s%d', stem, suffix, page);
            csv  = fullfile(fdir, [base '_locs.csv']);
        end

        function [todo, nDone] = pendingRows(files, mapData, overwrite)
            % The page-map rows to run for each file: todo{i} = the indices (a
            % row vector) of the active rows (isActiveRow) of mapData, without,
            % unless OVERWRITE, those whose output CSV (outputCsvPath) already
            % exists. nDone = the rows left out that way. Only file names are
            % looked at, so a TIFF whose pages are all done is never opened.
            nRows = size(mapData, 1);
            active = false(1, nRows);
            for r = 1:nRows
                active(r) = CellDiscovery.isActiveRow(mapData(r, :));
            end
            active = reshape(find(active), 1, []);   % a row, so buildJobs can loop over it
            todo = cell(size(files));
            nDone = 0;
            for i = 1:numel(files)
                rows = active;
                if ~overwrite && ~isempty(rows)
                    [fdir, stem] = fileparts(files{i});
                    if isempty(fdir), fdir = pwd; end
                    done = false(size(rows));
                    for k = 1:numel(rows)
                        row = mapData(rows(k), :);
                        done(k) = isfile(CellDiscovery.outputCsvPath(fdir, stem, row{2}, ...
                            CellToolkit.parseNum(row{1}, 0)));
                    end
                    nDone = nDone + nnz(done);
                    rows(done) = [];   % stays 1 x n (indexing a scalar would give 0 x 0)
                end
                todo{i} = rows;
            end
        end

        function tf = resizedTifDue(saveTif, writtenThisRun, overwrite, tifExists)
            % Whether a completed job writes its file's <stem>_resized.tif: the
            % Save-TIF box is on, it has not been written for this file in this
            % run, and the mode is Overwrite or the TIF does not exist yet.
            tf = logical(saveTif) && ~logical(writtenThisRun) && (logical(overwrite) || ~logical(tifExists));
        end

        function t = newTally(queued, skipped)
            % The counts of a run, filled in as its pages end (tallySummary words
            % them):
            %   queued    jobs in the run's queue
            %   done      pages whose result CSV was written
            %   skipped   pages left out because their result exists (Ignore mode)
            %   failed    struct array label, reason: pages without a result
            %   warnings  struct array label, reason: problems of done pages (snap,
            %             rescoring, manifest, TIF, PNG)
            %   aborted   label of the page discarded by Abort now ('' = none)
            %   notRun    queued jobs never started (a stop, an abort, an error)
            %   state     'complete' | 'stopped' | 'aborted' | 'error' (set at the end)
            %   error     message of the internal error that ended the run ('' = none)
            t = struct('queued', queued, 'done', 0, 'skipped', skipped, ...
                'failed', struct('label', {}, 'reason', {}), ...
                'warnings', struct('label', {}, 'reason', {}), ...
                'aborted', '', 'notRun', 0, 'state', '', 'error', '');
        end

        function [label, lines, failed] = tallySummary(t)
            % The words of a run's tally (newTally): LABEL for the progress label,
            % e.g. 'Complete: 38 done, 4 skipped, 2 failed (see the Command Window)';
            % LINES (cellstr) for the Command Window, naming each failed page and
            % each warning with its reason; FAILED = a page failed or an internal
            % error ended the run (the label is then red).
            nF = numel(t.failed);
            nW = numel(t.warnings);
            aborted = ~isempty(t.aborted);
            failed = nF > 0 || strcmp(t.state, 'error');
            switch t.state
                case 'stopped', head = 'Stopped';
                case 'aborted', head = 'Aborted';
                case 'error',   head = 'Stopped on an internal error';
                otherwise,      head = 'Complete';
            end
            counts = sprintf('%d done, %d skipped, %d failed', t.done, t.skipped, nF);
            if aborted
                counts = [counts ', 1 aborted'];
            end
            if t.notRun > 0
                counts = sprintf('%s, %d not run', counts, t.notRun);
            end
            if nW > 0
                counts = sprintf('%s, %d warning%s', counts, nW, CellToolkit.ternary(nW == 1, '', 's'));
            end
            label = sprintf('%s: %s', head, counts);
            if nF > 0 || nW > 0 || aborted
                label = [label ' (see the Command Window)'];
            end

            lines = {sprintf('=== PNN Batch GUI: %s: %s ===', lower(head), counts)};
            if nF > 0
                lines{end+1} = sprintf('Failed pages (%d):', nF);
                for k = 1:nF
                    lines{end+1} = sprintf('  %s: %s', t.failed(k).label, t.failed(k).reason); %#ok<AGROW>
                end
            end
            if aborted
                lines{end+1} = sprintf('Aborted page (discarded, nothing written for it): %s', t.aborted);
            end
            if nW > 0
                lines{end+1} = sprintf('Warnings on completed pages (%d):', nW);
                for k = 1:nW
                    lines{end+1} = sprintf('  %s: %s', t.warnings(k).label, t.warnings(k).reason); %#ok<AGROW>
                end
            end
            lines{end+1} = '';
        end
    end


    %% ---- Test seams of a batch in the window (tDiscoveryBatch; see the class help) ----
    methods (Hidden)

        function configure(obj, varargin)
            % Set controls of the window as a person would, by name: PythonExe,
            % CondaExe, CondaEnv, Device, BatchSize, Threshold (text), Overwrite,
            % SavePng, SaveTif, Diagnostic (logical), PageMap (a 9-column cell,
            % sanitised against the models found). Saves the settings to this
            % window's preference group.
            p = inputParser;
            p.FunctionName = 'CellDiscovery.configure';
            names = {'PythonExe', 'CondaExe', 'CondaEnv', 'Device', 'BatchSize', 'Threshold', ...
                'Overwrite', 'SavePng', 'SaveTif', 'Diagnostic', 'PageMap'};
            for k = 1:numel(names)
                p.addParameter(names{k}, []);
            end
            p.parse(varargin{:});
            given = setdiff(names, p.UsingDefaults);
            r = p.Results;
            edits = struct('PythonExe', obj.hPyEdit, 'CondaExe', obj.hCondaExeEdit, ...
                'CondaEnv', obj.hCondaEdit, 'Device', obj.hDeviceEdit, ...
                'BatchSize', obj.hBatchEdit, 'Threshold', obj.hThrEdit);
            boxes = struct('SavePng', obj.hSavePng, 'SaveTif', obj.hSaveLsmTif, ...
                'Diagnostic', obj.hDiagnosticChk);
            for k = 1:numel(given)
                nm = given{k};
                if isfield(edits, nm)
                    edits.(nm).Value = char(string(r.(nm)));
                elseif isfield(boxes, nm)
                    boxes.(nm).Value = logical(r.(nm));
                elseif strcmp(nm, 'Overwrite')
                    if logical(r.Overwrite)   % radio buttons: select one, the group deselects the other
                        obj.hOverwriteRad.Value = true;
                    else
                        obj.hIgnoreRad.Value = true;
                    end
                elseif strcmp(nm, 'PageMap')
                    obj.hPageTable.Data = CellDiscovery.sanitizePageMap(r.PageMap, ...
                        CellDiscovery.detChoiceList(obj.detModels, obj.SKIP_LABEL), ...
                        [{obj.NONE_LABEL}, obj.rescoreModels]);
                    obj.updateLSMOptionsButton();
                    obj.updateSnapOptionsButton();
                    obj.refreshFileMarks();
                end
            end
            obj.savePrefs();
        end

        function start(obj)
            % What the Start Batch button does (onStart).
            obj.onStart();
        end

        function requestStop(obj)
            % The Stop button (and the diagnostic window's Stop batch). The first
            % request stops the batch after the page in flight has finished all its
            % stages; the button then reads Abort now. The next request aborts:
            % the subprocess is killed at once and the next tick discards the page
            % in flight (abortInFlight) and ends the batch.
            if ~obj.isRunning() || obj.abortRequested, return; end
            if ~obj.stopRequested
                obj.stopRequested = true;
                obj.setStopButton('abort');
                obj.hProgressLabel.Text = 'Stop requested — finishing the current page ... (Abort now discards it)';
                fprintf('[STOP] Stop requested.\n');
            else
                obj.abortRequested = true;
                obj.hStopBtn.Enable = false;
                obj.hProgressLabel.Text = 'Aborting ...';
                fprintf('[STOP] Abort requested.\n');
                if ~isempty(obj.jProcess)
                    try obj.jProcess.destroyForcibly(); catch, end   % at once; killProcess finishes it
                end
            end
            obj.resumeDiagnosticPause();
        end

        function tf = isRunning(obj)
            % A batch runs (its timer exists).
            tf = ~isempty(obj.timerObj) && isvalid(obj.timerObj);
        end

        function s = batchState(obj)
            % Where the batch is (see the class help).
            stage = '';
            if ~isempty(obj.inFlight), stage = obj.inFlight.stage; end
            s = struct('Running', obj.isRunning(), 'Stage', stage, 'Job', obj.fileIdx, ...
                'Total', numel(obj.jobQueue), 'Progress', obj.hProgressLabel.Text, ...
                'ProgressColor', obj.hProgressLabel.FontColor, 'StopText', obj.hStopBtn.Text, ...
                'StopEnabled', logical(obj.hStopBtn.Enable), 'StopTooltip', obj.hStopBtn.Tooltip, ...
                'PythonRuns', obj.pythonRuns, 'ScratchDir', obj.tmpDir);
        end

        function t = lastTally(obj)
            % The counts of the last run (newTally; [] before the first Start).
            t = obj.tally;
        end

        function T = stageLog(obj)
            % The stages each job of the last run went through, in order: table
            % Job (queue index), Label, Event (detect-launch, detect-exit,
            % after-detection, score-launch, score-exit, finish; or skip, fail,
            % abort), Tick (the timer tick it happened in), Seconds (since Start).
            e = obj.stageEvents;
            T = table(reshape([e.Job], [], 1), reshape([e.Label], [], 1), reshape([e.Event], [], 1), ...
                reshape([e.Tick], [], 1), reshape([e.Seconds], [], 1), ...
                'VariableNames', {'Job', 'Label', 'Event', 'Tick', 'Seconds'});
        end
    end


    %% ---- Test seams (tModelInput, tDiscovery) -------------------------------
    methods (Static, Hidden)

        function [img, lims, lsmIdx] = detectorInputForFile(imgFile, page, mapData, lsmOptions, normalize)
            % The detector input the batch builds for page PAGE of imgFile with
            % this page map and LSM options, by the code the batch runs:
            % preprocessAllPages, detectorInputPage, then the scratch TIFF's class.
            nPages = CellToolkit.countPages(imgFile);
            [pages, ~, ~, lsmIdx] = CellDiscovery.preprocessAllPages(imgFile, nPages, mapData, lsmOptions);
            [img, lims] = CellDiscovery.detectorInputPage(pages{page}, normalize);
            img = CellToolkit.modelInputClass(img);
        end

        function facts = detectionFactsFor(imgFile, row, lsmOptions, lsmIdx, normLimits)
            % The facts finishOutputs records for page-map row ROW of imgFile, the
            % LSM page set lsmIdx and the normalisation limits used.
            [fdir, stem] = fileparts(char(imgFile));
            job = CellDiscovery.jobForRow(char(imgFile), fdir, stem, CellToolkit.countPages(imgFile), ...
                row, 'model', '', lsmOptions, CellDiscovery.defaultSnapOptions());
            job.lsmPages = lsmIdx;
            if job.normalize, job.normLimits = normLimits; end
            facts = CellDiscovery.detectionFacts(job);
        end

        function opts = defaultLSMOptionsForTest()
            opts = CellDiscovery.defaultLSMOptions();
        end

        function data = defaultPageMapForTest()
            data = CellDiscovery.defaultPageMap();
        end

        function data = sanitizePageMapForTest(data, detChoices, rescoreChoices)
            data = CellDiscovery.sanitizePageMap(data, detChoices, rescoreChoices);
        end

        function job = jobForRowForTest(imgFile, row)
            % The job buildJobs makes for page-map row ROW of imgFile (the
            % row's detection model; no rescoring; default LSM/snap options).
            [fdir, stem] = fileparts(char(imgFile));
            job = CellDiscovery.jobForRow(char(imgFile), fdir, stem, CellToolkit.countPages(imgFile), ...
                row, row{3}, '', CellDiscovery.defaultLSMOptions(), CellDiscovery.defaultSnapOptions());
        end

        function desc = sanitizeImageDescriptionForTest(desc)
            desc = CellDiscovery.sanitizeImageDescription(desc);
        end

        function [val, skip] = parseSnapOptionValueForTest(v)
            [val, skip] = CellDiscovery.parseSnapOptionValue(v);
        end
    end

end  % classdef CellDiscovery