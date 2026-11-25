classdef CellDatasetManager < handle
% CELLDATASETMANAGER  Find every cell dataset below a folder and show how far each one is.
%   A "dataset" is one source image (a TIFF, possibly multi-page) together
%   with every file the Cell* tools derive from it:
%       <base>.tif                                   (the image detection ran on)
%       <base>[_<channel><page>]_locs.csv            (detections)
%       <base>[_<channel><page>]_locs_resized.csv    (resized coordinates)
%       <stem>_curation.csv, <stem>_final.csv, ...   (Cell Curator, curation.Store)
%       <base>[_<channel><page>]_locs_QC.csv         (legacy QC review, still read)
%   Each (channel,page) localization stream is a "source" within the dataset,
%   so a two-page WFA/PV TIFF is one dataset with two sources. Which files
%   make a dataset is decided by CellDatasetManifest ("The base of a
%   dataset" in its help): a section stored as <x>_proj.tif beside
%   <x>_proj_ECM1_locs.csv is ONE dataset, base <x>_proj.
%
%   The "_locs" suffix is the default; it is configurable (the window's
%   "Locs suffix" field, persisted; scan's .LocsToken option).
%
%   1) Headless API ------------------------------------------------------
%
%       datasets = CellDatasetManager.scan(parentDir);         % struct array, one per dataset
%       T = CellDatasetManager.statusTable(parentDir);         % one row per dataset
%       S = CellDatasetManager.sourceTable(parentDir);         % one row per source: the report
%       p = CellDatasetManager.progressOf(datasets(k));        % counts and the stage of one dataset
%
%   scan adds to what CellDatasetManifest.discover knows:
%       .Section, .SubjectID, .SectionLabel   the section its file name says it is
%                                    (celldb.parseSectionName; '' when the name does not fit)
%       .SubjectAsked/.SubjectKnown/.SubjectText   what the lab database last said about that
%                                    subject (celldb.subjectInfo: this computer's cache, never
%                                    the network)
%       .SubjectTags, .SubjectVariables   the subject's tags there ('cohort:a pilot', as a tag
%                                    filter is typed) and its variable values ('Age at perfusion
%                                    = 92 d; housing = pair'); .SubjectFactsRead says they were
%                                    read at some time ('' is then "none", not "never asked")
%       .Sources(i).Db               where the source's lab database record is
%                                    (celldb.sourceRecords: none, kept here, waiting, sent, ...)
%       .Database                    those states in a few words, for the dataset
%   Only files are read for these; opts.Database = false leaves them blank.
%
%   2) The window --------------------------------------------------------
%
%       CellDatasetManager;                 % open empty, then Browse + Scan
%       app = CellDatasetManager(parentDir);% open and scan parentDir
%
%   One row per dataset: subject and section (from the file name), sources,
%   detections, how many sources are rescored, the share of cells a person
%   has reviewed, sources marked complete in Cell Curator, kept cells, a
%   status and the state of its lab database records. Find and Show narrow
%   the list; Next to curate selects the next dataset that is not finished;
%   Enter or a double-click opens the selected dataset in Cell Curator (Cell
%   Discovery when it has no detections yet); Analyze... opens Cell Analysis
%   on the scanned folder. Export report writes one row
%   per source to a CSV. The preview on the right shows the TIFF pages or a
%   color composite, optionally with the cell locations as filled circles
%   (pages and location files are cached, so going back to a dataset is
%   immediate). Scroll zooms at the pointer, a drag pans (the pages move
%   together), a double-click opens a tile in its own window.
%
%   The lab database (CarasLabDB) ---------------------------------------
%   The status bar holds the database lamp and a Database... button (the
%   window every lab toolbox shares), Check subjects (asks the database
%   which of the subjects named by the file names it has: a record of a
%   subject it does not have waits in the outbox for a person) and Queue
%   records (celldb.backfill: puts the records kept beside the files into
%   the outbox). The Database column follows the outbox while records are
%   sent. Everything goes through the celldb package; without the client the
%   window works the same and says what is missing. Nothing the manager
%   writes depends on the database.
%
%   Seams for tests and scripts (the window's own actions, no dialogs) -----
%       app.scanFolder(parentDir)            scan now and show the result
%       app.setFilter(text, show)            the Find text and the Show item
%       app.setTagFilter(expr)               the Tags filter: 'cohort:a -qc:fail topic:*'
%       tf = app.selectDataset(which)        index in Datasets, or a base / dataset id
%       tf = app.selectSource(key)           a source of the selected dataset
%       d = app.selectedDataset(), s = app.selectedSource()
%       tf = app.nextToCurate()              the Next to curate button
%       app.openSelected()                   Enter / double-click
%       app.launch('curator' | 'discovery' | 'analysis')   the Curate... / Detect cells... /
%                                            Analyze... buttons
%       file = app.exportReport(file)        the Export report... button, without the dialog
%       r = app.checkSubjects(), r = app.queueRecords(), app.openDatabase(), app.refreshDatabase()
%       app.handleKey(key, modifiers)        what the window's key handler calls
%       app.waitForIdle()                    run what is deferred (the preview) now
%       app.zoomPreview(tile, notches, xy)   the wheel over a preview tile (notches < 0 zooms in)
%       app.fitPreview(), L = app.previewLimits(tile)   the whole image; [x1 x2 y1 y2] shown
%     The preview's mouse handlers (the figure's WindowScrollWheelFcn and
%     WindowButtonDown/Motion/UpFcn) also take a struct with Tile and
%     AxesPoint (and VerticalScrollCount / SelectionType) in place of the
%     event: scroll zooms about the pointer, a drag pans, a double-click
%     opens the tile in its own window.
%       app.addCloseListener(fcn)
%   Properties to read: Figure, ParentDirectory, Datasets, View (table row ->
%   index in Datasets), SelectedDatasetIndex, SelectedSourceRow, StatusText,
%   LastLaunch. LaunchFcn, when set, is called instead of opening a tool.
%
%   Manifest files ------------------------------------------------------
%   The manifest lives in its own class, CellDatasetManifest (schema
%   "celldataset/2.0", sidecar "<base>.celldataset.json"). This window is a
%   consumer: scan() delegates discovery and reconciliation to
%   CellDatasetManifest.discover() and projects each manifest onto the
%   dataset struct shown here. "Set active locs..." and "Set active image..."
%   re-point a source's analysis file and a dataset's image.
%
%   See also CELLDATASETMANIFEST, CELLCURATOR, CELLDISCOVERY, CELLDB.SOURCERECORDS.

    %% ===================================================================
    %  Constants
    %  ===================================================================
    properties (Constant)
        % Scale-bar fallback when a TIFF carries no physical resolution tag.
        % Matches the original training resolution noted in CLAUDE.md.
        DEFAULT_UM_PER_PIXEL = 0.645
        % The Show drop-down: which datasets the table lists.
        SHOW_ITEMS = {'All datasets', 'To detect', 'To curate', 'In curation', 'Curated', 'Database: not sent'}
        DATASET_COLUMNS = {'Subject', 'Section', 'Name', 'Sources', 'Detections', 'Rescored', ...
            'Reviewed %', 'Curated', 'Kept', 'Status', 'Database', 'Tags'}
        SOURCE_COLUMNS = {'Source', 'Page', 'Detections', 'Rescored', 'Reviewed', 'Good', 'Bad', ...
            'Kept', 'Complete', 'Database', 'Legacy'}
        % Pages, composites and location files kept in memory for the preview:
        % at most this many, and at most this many megabytes.
        CACHE_ENTRIES = 48
        CACHE_MB = 256
        % Ground of the selected source's row (drawn by the window itself).
        SELECTED_ROW_COLOR = [0.82 0.89 0.98]
        % A scan shorter than this many seconds shows no progress dialog.
        SCAN_DIALOG_AFTER = 0.7
        % The preview: one wheel notch zooms by this factor about the pointer;
        % the closest view spans this many displayed pixels.
        PREVIEW_ZOOM_STEP = 1.25
        PREVIEW_MIN_SPAN = 24
        % Area (points^2) of the filled circle drawn at each cell location.
        LOCATION_MARKER_SIZE = 12
    end

    %% ===================================================================
    %  State others may read
    %  ===================================================================
    properties (SetAccess = private)
        Figure
        ParentDirectory char = ''
        Datasets struct = struct([])
        View double = zeros(1, 0)          % dataset table row -> index into Datasets
        SelectedDatasetIndex double = 0    % index into Datasets (0 = none)
        SelectedSourceRow double = 0       % row of the source table (0 = none)
        StatusText char = ''
        LastLaunch struct = struct('Tool', '', 'Folder', '', 'Base', '', 'Key', '')
    end

    properties
        % function_handle called with LastLaunch instead of opening a tool (tests), or [].
        LaunchFcn = []
    end

    %% ===================================================================
    %  GUI state
    %  ===================================================================
    properties (Access = private)
        UseSettings logical = true
        FilterText char = ''
        FilterShow char = 'All datasets'
        FilterTags char = ''               % the Tags filter (the lab database's grammar)
        TagNote char = ''                  % what celldb.tagFilter said about it last

        ParentDirEdit
        LocsTokenEdit
        BrowseButton
        ScanButton
        StatusLabel
        FindEdit
        TagsEdit
        ShowDropDown
        NextButton
        ExportButton
        DatasetTable
        SourceTable
        DetailLabel
        DiscoveryButton
        CuratorButton
        AnalysisButton
        OpenFolderButton
        OpenManifestButton
        SetActiveLocsButton
        SetActiveImageButton
        CheckSubjectsButton
        QueueButton
        DatabaseButton
        DbLamp = []
        DbListeners = {}
        DbRefreshedAt = 0                  % tic value of the last Database column refresh
        ScanProgress = []                  % the running scan's progress dialog and times
        LaunchEnabled = []                 % what setLaunchEnabled last set ([] = nothing yet)
        Timers struct = struct()           % name -> one-shot timer (defer)
        Pending struct = struct()          % name -> what that timer will run

        PagePanel
        PageContent
        PageViewDropDown
        ShowLocationsCheckBox
        LocationColorDropDown
        ShowLocations logical = false
        LocationColorMode char = 'Uniform'
        PreviewImagePath char = ''
        % One element per preview tile: its axes, the limits of the whole
        % image (Full = [x1 x2 y1 y2]), the um per displayed pixel, the
        % scale bar and rescore key drawn in data units (Decor, moved or
        % redrawn with the view), its context menu and what opens it.
        Tiles struct = struct('Axes', {}, 'Full', {}, 'UmPerPx', {}, ...
            'HasKey', {}, 'Decor', {}, 'Menu', {}, 'OpenFcn', {})
        PreviewDrag = []                   % a pan in progress: Tile, P0, L0
        StatLabels struct = struct([])
    end

    %% ===================================================================
    %  Construction
    %  ===================================================================
    methods
        function obj = CellDatasetManager(parentDir, opts)
            % Open the window. With a parent directory the first scan is
            % deferred by default, so the constructor returns and the window
            % is drawn before any file is read.
            %   CellDatasetManager(parentDir, 'Scan', 'now')        scan before returning
            %   CellDatasetManager(parentDir, 'Scan', 'none')       only fill the field
            %   CellDatasetManager(..., 'UseSettings', false)       neither read nor write the
            %                                                       saved window settings (tests)
            arguments
                parentDir {mustBeText} = ''
                opts.UseSettings (1,1) logical = true
                opts.Scan {mustBeMember(opts.Scan, {'deferred', 'now', 'none'})} = 'deferred'
            end
            obj.UseSettings = opts.UseSettings;
            obj.buildUI();
            obj.loadPreferences();
            obj.updateDatabaseControls();
            parentDir = char(parentDir);
            if ~isempty(parentDir) && isfolder(parentDir)
                obj.ParentDirEdit.Value = parentDir;
                obj.ParentDirectory     = parentDir;
                switch char(opts.Scan)
                    case 'now'
                        obj.rescan(false);
                    case 'deferred'
                        obj.setStatus('Opening... the first scan starts in a moment.');
                        obj.defer('scan', 0.25, @() obj.onScan());
                end
            end
        end

        function delete(obj)
            % Destructor: the timers, the database listeners and the figure go.
            obj.cancelAllDeferred();
            obj.dropDatabaseListeners();
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                try
                    delete(obj.Figure);
                catch
                end
            end
        end
    end

    %% ===================================================================
    %  Headless API  (no GUI required)
    %  ===================================================================
    methods (Static)

        function datasets = scan(parentDir, opts)
            % Every dataset under parentDir as a struct array with its
            % per-source pipeline status: a projection of
            % CellDatasetManifest.discover() (the manifest class owns
            % discovery, the schema, file resolution and the active pointer;
            % the live manifest object is attached as .ManifestObj), plus the
            % section the file name names and the state of the lab database
            % records (see the class help).
            %
            %   opts (optional struct):
            %     .WriteManifest (default true)  write reconciled manifests back
            %     .Probe         (default true)  read CSV contents for counts /
            %                                     column presence and image page
            %                                     counts; false = file-existence
            %                                     only (fast)
            %     .LocsToken     (default = CellDatasetManifest.locsToken())
            %     .Database      (default true)  look for the lab database
            %                                     records and the cached subjects
            %     .Progress      function (k, n, base) called per dataset; it
            %                                     may throw to cancel
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

            withDb = ~isfield(opts, 'Database') || isempty(opts.Database) || logical(opts.Database);
            datasets = CellDatasetManager.annotate(datasets, withDb);
        end

        function T = statusTable(parentDir, opts)
            % One row per dataset. Same discovery as scan(); parentDir may
            % also be the struct array scan() returned.
            arguments
                parentDir
                opts struct = struct()
            end
            datasets = CellDatasetManager.datasetsOf(parentDir, opts);
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
            Subject   = strings(n, 1);
            Curated   = strings(n, 1);
            CellsReviewed = zeros(n, 1);
            Kept      = zeros(n, 1);
            Database  = strings(n, 1);
            SubjectTags      = strings(n, 1);
            SubjectVariables = strings(n, 1);
            for k = 1:n
                d = datasets(k);
                p = CellDatasetManager.progressOf(d);
                SubjectTags(k)      = string(d.SubjectTags);
                SubjectVariables(k) = string(d.SubjectVariables);
                DatasetID(k)  = string(d.DatasetID);
                Folder(k)     = string(d.Folder);
                Pages(k)      = d.PageCount;
                Sources(k)    = p.Sources;
                Detected(k)   = CellDatasetManager.frac(d.Sources, 'detection');
                Resolved(k)   = CellDatasetManager.frac(d.Sources, 'resolve');
                Rescored(k)   = CellDatasetManager.frac(d.Sources, 'rescore');
                Reviewed(k)   = CellDatasetManager.frac(d.Sources, 'qc');
                Detections(k) = d.TotalDetections;
                Status(k)     = string(d.Status);
                Subject(k)    = string(d.SubjectID);
                Curated(k)    = CellDatasetManager.frac(d.Sources, 'complete');
                CellsReviewed(k) = p.Reviewed;
                Kept(k)       = p.Kept;
                Database(k)   = string(d.Database);
            end
            T = table(DatasetID, Folder, Pages, Sources, Detections, ...
                Detected, Resolved, Rescored, Reviewed, Status, ...
                Subject, Curated, CellsReviewed, Kept, Database, SubjectTags, SubjectVariables);
        end

        function T = sourceTable(parentDir, opts)
            % One row per source: the progress report the window exports.
            %   T = CellDatasetManager.sourceTable(parentDir)
            %   T = CellDatasetManager.sourceTable(datasets)   % what scan() returned
            % Columns: Subject, Section, Hemisphere, Stain, Dataset, Source,
            % Page, Detections, Rescored, Reviewed, Good, Bad, Uncertain, Kept,
            % Complete, Status (of the dataset), Database, DatabaseRecordedAt,
            % FinalCsv (the kept cells of a completed source, '' when not
            % written), Folder, and SubjectTags and SubjectVariables (the lab
            % database's tags and variable values of the subject, as this
            % computer's cache has them). The counts are Cell Curator's when the
            % source has a curation record, else those of a legacy QC file
            % (Kept is 0 then: nothing is kept before a person confirms it in
            % Cell Curator).
            arguments
                parentDir
                opts struct = struct()
            end
            datasets = CellDatasetManager.datasetsOf(parentDir, opts);
            rows = {};
            for k = 1:numel(datasets)
                d = datasets(k);
                for i = 1:numel(d.Sources)
                    s = d.Sources(i);
                    c = CellDatasetManager.sourceCounts(s);
                    db = CellDatasetManager.dbOf(s);
                    finalCsv = '';
                    if ~isempty(s.CurationPath)
                        cand = regexprep(s.CurationPath, '_curation\.csv$', '_final.csv');
                        if ~strcmp(cand, s.CurationPath) && isfile(cand)
                            finalCsv = cand;
                        end
                    end
                    rows(end+1, :) = {string(d.SubjectID), string(d.Section.SectionID), ...
                        string(d.Section.Hemisphere), string(d.Section.Stain), string(d.Base), ...
                        string(CellDatasetManager.sourceLabel(s)), CellDatasetManager.pageVal(s.Page), ...
                        s.NumDetections, logical(s.Rescored), c.Reviewed, c.Good, c.Bad, c.Uncertain, ...
                        c.Kept, logical(s.CurComplete), string(d.Status), string(db.text), ...
                        string(db.recordedAt), string(finalCsv), string(d.Folder), ...
                        string(d.SubjectTags), string(d.SubjectVariables)}; %#ok<AGROW>
                end
            end
            names = {'Subject', 'Section', 'Hemisphere', 'Stain', 'Dataset', 'Source', 'Page', ...
                'Detections', 'Rescored', 'Reviewed', 'Good', 'Bad', 'Uncertain', 'Kept', ...
                'Complete', 'Status', 'Database', 'DatabaseRecordedAt', 'FinalCsv', 'Folder', ...
                'SubjectTags', 'SubjectVariables'};
            if isempty(rows)
                T = table('Size', [0 numel(names)], 'VariableNames', names, 'VariableTypes', ...
                    {'string', 'string', 'string', 'string', 'string', 'string', 'double', 'double', ...
                     'logical', 'double', 'double', 'double', 'double', 'double', 'logical', 'string', ...
                     'string', 'string', 'string', 'string', 'string', 'string'});
            else
                T = cell2table(rows, 'VariableNames', names);
            end
        end

        function p = progressOf(d)
            % Counts and the stage of one dataset (an element of what scan()
            % returns):
            %   Sources, Detected, Rescored, Started, Complete   numbers of sources
            %   Cells, Reviewed, Kept     cells over all sources (see sourceCounts)
            %   Pct                       whole percent of Cells reviewed (0 without cells)
            %   Stage   'detect'    no detections yet
            %           'curate'    detected, no cell reviewed
            %           'curating'  some cells reviewed or a source complete
            %           'curated'   every source marked complete in Cell Curator
            s = d.Sources;
            p = struct('Sources', numel(s), 'Detected', 0, 'Rescored', 0, 'Started', 0, ...
                'Complete', 0, 'Cells', 0, 'Reviewed', 0, 'Kept', 0, 'Pct', 0, 'Stage', 'detect');
            for i = 1:numel(s)
                c = CellDatasetManager.sourceCounts(s(i));
                p.Detected = p.Detected + double(s(i).Detected);
                p.Rescored = p.Rescored + double(s(i).Rescored);
                p.Started  = p.Started + double(s(i).Curated || s(i).Reviewed);
                p.Complete = p.Complete + double(s(i).CurComplete);
                p.Cells    = p.Cells + c.Cells;
                p.Reviewed = p.Reviewed + c.Reviewed;
                p.Kept     = p.Kept + c.Kept;
            end
            if p.Cells > 0
                p.Pct = floor(100 * p.Reviewed / p.Cells);
            end
            if p.Detected == 0
                p.Stage = 'detect';
            elseif p.Complete == p.Sources
                p.Stage = 'curated';
            elseif p.Started > 0
                p.Stage = 'curating';
            else
                p.Stage = 'curate';
            end
        end

    end

    %% ===================================================================
    %  Small data helpers
    %  ===================================================================
    methods (Static, Access = private)

        function datasets = datasetsOf(arg, opts)
            % The datasets ARG stands for: a scan() result, or a folder to scan.
            if isstruct(arg)
                datasets = arg;
            else
                datasets = CellDatasetManager.scan(arg, opts);
            end
        end

        function txt = frac(sources, stage)
            % "k/n" of sources past a stage, for the summary table.
            n = numel(sources);
            if n == 0
                txt = '0/0';
                return;
            end
            switch stage
                case 'detection', flags = [sources.Detected];
                case 'resolve',   flags = [sources.Resolved];
                case 'rescore',   flags = [sources.Rescored];
                case 'qc',        flags = [sources.Reviewed] | [sources.Curated];
                case 'complete',  flags = [sources.CurComplete];
                otherwise,        flags = false(1, n);
            end
            txt = sprintf('%d/%d', sum(flags), n);
        end

        function c = sourceCounts(s)
            % Cells of one source and what a person decided about them: Cell
            % Curator's counts when it has a curation record, else a legacy QC
            % file's (nothing is Kept then).
            if s.CurFound
                c = struct('Cells', s.CurTotal, 'Reviewed', s.CurReviewed, 'Good', s.CurGood, ...
                    'Bad', s.CurBad, 'Uncertain', s.CurUncertain, 'Kept', s.CurKept);
                if c.Cells == 0
                    c.Cells = s.NumDetections;
                end
            else
                c = struct('Cells', s.NumDetections, 'Reviewed', s.QcReviewed, 'Good', s.QcGood, ...
                    'Bad', s.QcBad, 'Uncertain', s.QcUncertain, 'Kept', 0);
            end
            c.Reviewed = min(c.Reviewed, max(c.Cells, 0));
        end

        function tf = hasCelldb()
            % The celldb package (the only code that touches the lab database client) is here.
            persistent have
            if isempty(have)
                have = ~isempty(which('celldb.sourceRecords')) && ~isempty(which('celldb.addLamp'));
            end
            tf = have;
        end

        function db = blankDb()
            % The lab database record of a source nothing is known about.
            db = struct('state', "none", 'current', false, 'text', "", 'detail', "", ...
                'note', "", 'runId', "", 'file', "", 'recordedAt', "", 'subjectId', "");
        end

        function db = dbOf(s)
            % A source's lab database record (blank when scan() left it out).
            if isfield(s, 'Db') && isstruct(s.Db) && isscalar(s.Db)
                db = s.Db;
            else
                db = CellDatasetManager.blankDb();
            end
        end

        function sec = sectionOf(base)
            % The section a dataset's base names (celldb.parseSectionName); every
            % field '' and ok false when the name does not fit or celldb is not here.
            sec = struct('ok', false, 'SubjectID', "", 'SubjectNumber', "", 'SampleID', "", ...
                'Protocol', "", 'Series', "", 'SectionID', "", 'Hemisphere', "", 'Stain', "", ...
                'ZPlane', "", 'DateCode', "", 'ImageNumber', "", 'Variant', "", 'ImageKey', "");
            if CellDatasetManager.hasCelldb()
                try
                    sec = celldb.parseSectionName(string(base));
                catch
                end
            end
        end

        function datasets = annotate(datasets, withDb)
            % Add to each dataset the section its name says it is, what the lab
            % database last said about its subject, and where each source's
            % lab database record is. Files only: nothing waits for a server.
            n = numel(datasets);
            files = strings(0, 1);
            for k = 1:n
                sec = CellDatasetManager.sectionOf(datasets(k).Base);
                datasets(k).Section      = sec;
                datasets(k).SubjectID    = char(sec.SubjectID);
                datasets(k).SectionLabel = char(strtrim(sec.SectionID + " " + sec.Hemisphere));
                datasets(k).SubjectAsked = false;
                datasets(k).SubjectKnown = false;
                datasets(k).SubjectText  = '';
                datasets(k).SubjectTags  = '';
                datasets(k).SubjectVariables = '';
                datasets(k).SubjectFactsRead = false;
                datasets(k).Database     = '';
                for i = 1:numel(datasets(k).Sources)
                    files(end+1, 1) = string(datasets(k).Sources(i).CurationPath); %#ok<AGROW>
                end
            end
            recs = repmat(CellDatasetManager.blankDb(), numel(files), 1);
            if withDb && CellDatasetManager.hasCelldb()
                try
                    recs = celldb.sourceRecords(files);
                catch
                end
            end
            j = 0;
            for k = 1:n
                for i = 1:numel(datasets(k).Sources)
                    j = j + 1;
                    datasets(k).Sources(i).Db = recs(j);
                end
                datasets(k).Database = CellDatasetManager.databaseText(datasets(k).Sources);
            end
            if withDb
                datasets = CellDatasetManager.annotateSubjects(datasets);
            end
        end

        function datasets = annotateSubjects(datasets)
            % What this computer's cache of the lab database says about each
            % dataset's subject (celldb.subjectInfo; never the network).
            if isempty(datasets) || ~CellDatasetManager.hasCelldb()
                return;
            end
            ids = string({datasets.SubjectID});
            uniq = unique(ids(strlength(ids) > 0));
            if isempty(uniq)
                return;
            end
            try
                T = celldb.subjectInfo(uniq);
            catch
                return;
            end
            for k = 1:numel(datasets)
                r = find(T.subject_id == ids(k), 1);
                if isempty(r)
                    continue;
                end
                datasets(k).SubjectAsked = T.asked(r);
                datasets(k).SubjectKnown = T.known(r);
                datasets(k).SubjectText  = char(T.text(r));
                datasets(k).SubjectTags  = char(T.tags(r));
                datasets(k).SubjectVariables = char(T.variables(r));
                datasets(k).SubjectFactsRead = logical(T.facts_read(r));
            end
        end

        function txt = databaseText(sources)
            % The states of a dataset's lab database records in a few words,
            % the one that needs a person first: "1 needs you, 1 sent".
            txt = '';
            if isempty(sources)
                return;
            end
            states = strings(1, numel(sources));
            stale = false;
            for i = 1:numel(sources)
                db = CellDatasetManager.dbOf(sources(i));
                states(i) = db.state;
                stale = stale || (db.state ~= "none" && ~db.current);
            end
            order = ["held", "failed", "queued", "local", "sent", "discarded"];
            words = ["need you", "refused", "waiting", "kept here", "sent", "discarded"];
            parts = strings(1, 0);
            for j = 1:numel(order)
                c = nnz(states == order(j));
                if c > 0
                    w = words(j);
                    if order(j) == "held" && c == 1, w = "needs you"; end
                    parts(end+1) = sprintf("%d %s", c, w); %#ok<AGROW>
                end
            end
            txt = char(strjoin(parts, ", "));
            if stale && ~isempty(txt)
                txt = [txt ' (changed since)'];
            end
        end

        function tf = notSent(d)
            % True when a source of D is marked complete and its current state
            % has not been sent to the lab database from this computer.
            tf = false;
            for i = 1:numel(d.Sources)
                s = d.Sources(i);
                db = CellDatasetManager.dbOf(s);
                if s.CurComplete && ~(db.state == "sent" && db.current)
                    tf = true;
                    return;
                end
            end
        end

        function v = cached(key, producer)
            % A small most-recently-used cache for what the preview reads
            % (pages, composites, location files): KEY names the file, what was
            % asked of it and the file's time and size, so a changed file is read
            % again. PRODUCER makes the value when it is not here. Bounded by
            % CACHE_ENTRIES and CACHE_MB; a value larger than a quarter of
            % CACHE_MB (a page opened at full size) is not kept.
            persistent store order sizes
            if isempty(store)
                store = containers.Map('KeyType', 'char', 'ValueType', 'any');
                sizes = containers.Map('KeyType', 'char', 'ValueType', 'double');
                order = {};
            end
            if strcmp(key, '#clear')
                store = containers.Map('KeyType', 'char', 'ValueType', 'any');
                sizes = containers.Map('KeyType', 'char', 'ValueType', 'double');
                order = {};
                v = [];
                return;
            end
            if isKey(store, key)
                v = store(key);
                order(strcmp(order, key)) = [];
                order{end+1} = key;
                return;
            end
            v = producer();
            info = whos('v');
            mb = info.bytes / 2^20;
            if mb > CellDatasetManager.CACHE_MB / 4
                return;
            end
            store(key) = v;
            sizes(key) = mb;
            order{end+1} = key;
            while numel(order) > CellDatasetManager.CACHE_ENTRIES || ...
                    (numel(order) > 1 && sum(cell2mat(values(sizes))) > CellDatasetManager.CACHE_MB)
                remove(store, order{1});
                remove(sizes, order{1});
                order(1) = [];
            end
        end

        function key = fileKey(path, what)
            % Cache key of something read from PATH: its name, WHAT was asked,
            % its modification time and its size.
            path = char(path);
            d = [];
            if ~isempty(path)
                d = dir(path);
            end
            if isempty(d)
                key = sprintf('%s|%s|missing', path, what);
            else
                key = sprintf('%s|%s|%.9f|%d', path, what, d(1).datenum, d(1).bytes);
            end
        end

    end

    methods (Static, Hidden)
        function clearCache()
            % Forget every cached page, composite and location file (tests).
            CellDatasetManager.cached('#clear', []);
        end
    end

    %% ===================================================================
    %  Seams: the window's actions, callable from tests and scripts
    %  ===================================================================
    methods

        function scanFolder(obj, parentDir)
            % Scan parentDir now and show the result (the Scan button with the
            % field already filled). The selection is cleared.
            parentDir = char(parentDir);
            obj.ParentDirEdit.Value = parentDir;
            obj.onScan();
        end

        function setFilter(obj, text, show)
            % The Find text and, optionally, the Show item: which datasets the
            % table lists. Every word of TEXT must be in the dataset's name,
            % subject, section, path below the parent directory or status.
            if nargin >= 3 && ~isempty(show)
                show = char(show);
                if ~any(strcmp(obj.SHOW_ITEMS, show))
                    error('CellDatasetManager:show', 'Show must be one of: %s.', ...
                        strjoin(obj.SHOW_ITEMS, ', '));
                end
                obj.FilterShow = show;
                obj.ShowDropDown.Value = show;
            end
            obj.FilterText = strtrim(char(text));
            obj.FindEdit.Value = obj.FilterText;
            obj.applyFilter();
        end

        function setTagFilter(obj, expr)
            % The Tags filter: list only the datasets whose subject passes this
            % filter of lab database tags (celldb.tagFilter): tags separated by
            % spaces that must all hold, "-" before one the subject must not
            % have, "namespace:*" for any tag of a namespace, a bare word for a
            % bare tag. '' lists all. A dataset without a subject, and one whose
            % subject was never checked, is not listed while a filter is set.
            obj.FilterTags = strtrim(char(expr));
            obj.TagsEdit.Value = obj.FilterTags;
            obj.applyFilter();
        end

        function tf = selectDataset(obj, which)
            % Select a dataset: its index in Datasets, or its base or dataset
            % id (text). A dataset the filter hides is shown by clearing the
            % filter. False when there is no such dataset.
            tf = false;
            idx = 0;
            if isnumeric(which)
                if isscalar(which) && which >= 1 && which <= numel(obj.Datasets)
                    idx = double(which);
                end
            else
                which = char(which);
                for k = 1:numel(obj.Datasets)
                    if strcmpi(obj.Datasets(k).Base, which) || strcmpi(obj.Datasets(k).DatasetID, which)
                        idx = k;
                        break;
                    end
                end
            end
            if idx == 0
                return;
            end
            if ~any(obj.View == idx)
                obj.FilterText = '';
                obj.FilterTags = '';
                obj.TagsEdit.Value = '';
                obj.FilterShow = obj.SHOW_ITEMS{1};
                obj.FindEdit.Value = '';
                obj.ShowDropDown.Value = obj.FilterShow;
                obj.SelectedDatasetIndex = idx;
                obj.applyFilter();
            end
            obj.SelectedDatasetIndex = idx;
            obj.SelectedSourceRow = 0;
            obj.syncDatasetTableSelection();
            obj.refreshDetail();
            tf = true;
        end

        function tf = selectSource(obj, key)
            % Select a source of the selected dataset by its key ('ECM1') or row.
            tf = false;
            d = obj.selectedDataset();
            if isempty(d) || isempty(d.Sources)
                return;
            end
            if isnumeric(key)
                row = double(key);
            else
                row = find(strcmpi({d.Sources.Key}, char(key)), 1);
            end
            if isempty(row) || row < 1 || row > numel(d.Sources)
                return;
            end
            obj.SelectedSourceRow = row;
            obj.showSourceSelection();
            tf = true;
        end

        function d = selectedDataset(obj)
            d = [];
            idx = obj.SelectedDatasetIndex;
            if idx >= 1 && idx <= numel(obj.Datasets)
                d = obj.Datasets(idx);
            end
        end

        function s = selectedSource(obj)
            % The selected source of the selected dataset, [] when none is.
            s = [];
            d = obj.selectedDataset();
            row = obj.SelectedSourceRow;
            if ~isempty(d) && ~isempty(row) && row >= 1 && row <= numel(d.Sources)
                s = d.Sources(row);
            end
        end

        function tf = nextToCurate(obj)
            % Select the next listed dataset, after the selected one and
            % wrapping round, that has detections and is not marked complete,
            % and in it the first source that is not complete. False (and a
            % line in the status bar) when the list has none.
            tf = false;
            v = obj.View;
            if isempty(v)
                obj.setStatus('Nothing to curate: no dataset is listed.');
                return;
            end
            start = find(v == obj.SelectedDatasetIndex, 1);
            if isempty(start), start = 0; end
            rows = [start+1:numel(v), 1:start];
            for r = rows
                d = obj.Datasets(v(r));
                p = CellDatasetManager.progressOf(d);
                if ~any(strcmp(p.Stage, {'curate', 'curating'}))
                    continue;
                end
                obj.selectDataset(v(r));
                unfinished = find(~[d.Sources.CurComplete] & [d.Sources.Detected], 1);
                if ~isempty(unfinished)
                    obj.selectSource(unfinished);
                end
                obj.setStatus(sprintf('%s: %d of %d cells reviewed. Enter (or Curate...) opens it.', ...
                    d.Base, p.Reviewed, p.Cells));
                tf = true;
                return;
            end
            obj.setStatus('Nothing left to curate in this list: every listed dataset with detections is marked complete.');
        end

        function openSelected(obj)
            % Enter or a double-click on a dataset: Cell Curator when it has
            % detections, Cell Discovery when it has none yet.
            d = obj.selectedDataset();
            if isempty(d)
                obj.setStatus('Select a dataset first.');
                return;
            end
            p = CellDatasetManager.progressOf(d);
            if p.Detected > 0
                obj.launch('curator');
            else
                obj.launch('discovery');
            end
        end

        function launch(obj, tool)
            % Open a tool on the selection: 'curator' (Cell Curator on the
            % scanned parent directory, showing the selected dataset and
            % source, so review can go on to the next dataset), 'discovery'
            % (Cell Discovery on the selected dataset's folder, or the parent
            % directory when none is selected) or 'analysis' (Cell Analysis on
            % the parent directory). LastLaunch says what was asked;
            % LaunchFcn, when set, is called with it instead of opening the tool.
            tool = lower(char(tool));
            d = obj.selectedDataset();
            req = struct('Tool', tool, 'Folder', '', 'Base', '', 'Key', '');
            switch tool
                case 'curator'
                    req.Folder = obj.ParentDirectory;
                    if isempty(req.Folder) || ~isfolder(req.Folder)
                        req.Folder = obj.launchFolder();
                    end
                    if ~isempty(d)
                        req.Base = d.Base;
                        s = obj.selectedSource();
                        if ~isempty(s), req.Key = s.Key; end
                    end
                case 'discovery'
                    req.Folder = obj.launchFolder();
                case 'analysis'
                    req.Folder = obj.ParentDirectory;
                    if isempty(req.Folder) || ~isfolder(req.Folder)
                        req.Folder = obj.launchFolder();
                    end
                    if ~isempty(d), req.Base = d.Base; end
                otherwise
                    error('CellDatasetManager:tool', 'Unknown tool "%s".', tool);
            end
            if isempty(req.Folder) || ~isfolder(req.Folder)
                obj.setStatus('Select a dataset or set a parent directory first.');
                return;
            end
            obj.LastLaunch = req;
            if ~isempty(obj.LaunchFcn)
                obj.LaunchFcn(req);
                return;
            end
            try
                if strcmp(tool, 'curator')
                    app = CellCurator();
                    app.openParent(req.Folder, req.Base, req.Key);
                    name = 'Cell Curator';
                elseif strcmp(tool, 'analysis')
                    app = CellAnalysis(req.Folder, 'Scan', 'now');
                    if ~isempty(req.Base), app.selectSection(req.Base); end
                    obj.setStatus(sprintf('Cell Analysis opened on %s.', req.Folder));
                    return;
                else
                    app = CellDiscovery(req.Folder);   % searches the folder once
                    name = 'Cell Discovery';
                end
                obj.attachRefreshOnClose(app);
                obj.setStatus(sprintf('%s opened on %s. This list is refreshed when it closes.', ...
                    name, req.Folder));
            catch ME
                uialert(obj.Figure, ME.message, 'Could not open the tool');
            end
        end

        function file = exportReport(obj, file)
            % Write the report (CellDatasetManager.sourceTable: one row per
            % source of every dataset found, whatever the filter shows) to the
            % CSV FILE. Without FILE a dialog asks where. Returns the file
            % written, '' when nothing was.
            if nargin < 2 || isempty(file)
                start = obj.ParentDirectory;
                if isempty(start) || ~isfolder(start), start = pwd; end
                [fn, fp] = uiputfile({'*.csv', 'CSV table (*.csv)'}, 'Export the report', ...
                    fullfile(start, ['cell_datasets_' char(datetime('now', 'Format', 'yyyyMMdd')) '.csv']));
                if isequal(fn, 0)
                    file = '';
                    return;
                end
                file = fullfile(fp, fn);
            end
            file = char(file);
            if isempty(obj.Datasets)
                obj.setStatus('Nothing to export: scan a parent directory first.');
                file = '';
                return;
            end
            try
                T = CellDatasetManager.sourceTable(obj.Datasets);
                writetable(T, file);
                obj.setStatus(sprintf('Report written: %d source(s) of %d dataset(s) -> %s', ...
                    height(T), numel(obj.Datasets), file));
            catch ME
                obj.setStatus(['The report was not written: ' ME.message]);
                file = '';
            end
        end

        function refreshDatabase(obj, outboxOnly)
            % Look again for the lab database records of every source and show
            % them. With outboxOnly (true) the records are not read again: only
            % this computer's outbox is asked where each one is, which is what
            % changes while records are sent.
            if nargin < 2, outboxOnly = false; end
            obj.DbRefreshedAt = tic;
            if isempty(obj.Datasets) || ~CellDatasetManager.hasCelldb()
                obj.updateDatabaseControls();
                return;
            end
            try
                files = strings(0, 1);
                prev = repmat(CellDatasetManager.blankDb(), 0, 1);
                for k = 1:numel(obj.Datasets)
                    for i = 1:numel(obj.Datasets(k).Sources)
                        files(end+1, 1) = string(obj.Datasets(k).Sources(i).CurationPath); %#ok<AGROW>
                        prev(end+1, 1) = CellDatasetManager.dbOf(obj.Datasets(k).Sources(i)); %#ok<AGROW>
                    end
                end
                if outboxOnly
                    recs = celldb.sourceRecords(files, 'Previous', prev);
                else
                    recs = celldb.sourceRecords(files);
                end
                j = 0;
                for k = 1:numel(obj.Datasets)
                    for i = 1:numel(obj.Datasets(k).Sources)
                        j = j + 1;
                        obj.Datasets(k).Sources(i).Db = recs(j);
                    end
                    obj.Datasets(k).Database = CellDatasetManager.databaseText(obj.Datasets(k).Sources);
                end
                if ~outboxOnly
                    obj.Datasets = CellDatasetManager.annotateSubjects(obj.Datasets);
                end
            catch ME
                obj.setStatus(['The lab database records could not be read: ' ME.message]);
            end
            if strcmp(obj.FilterShow, 'Database: not sent') || (~outboxOnly && ~isempty(obj.FilterTags))
                obj.applyFilter();
            else
                obj.refreshDatasetTable();
                obj.syncDatasetTableSelection();
            end
            obj.refreshSummary();
            obj.refreshSourceTable();
            obj.refreshDetailText();
            obj.updateDatabaseControls();
        end

        function r = checkSubjects(obj)
            % The Check subjects button: ask the lab database which of the
            % subjects the file names here name it has, and for their tags and
            % variables (celldb.refreshSubjects, a few seconds at most), and
            % show the answers.
            r = struct('ok', false, 'asked', 0, 'missing', strings(0, 1), 'message', "", 'tagsRead', false);
            if ~CellDatasetManager.hasCelldb()
                return;
            end
            ids = strings(0, 1);
            if ~isempty(obj.Datasets)
                ids = string({obj.Datasets.SubjectID})';
                ids = unique(ids(strlength(ids) > 0));
            end
            dlg = [];
            try
                dlg = uiprogressdlg(obj.Figure, 'Title', 'Lab database', 'Indeterminate', 'on', ...
                    'Message', sprintf('Asking the lab database about %d subject(s)...', numel(ids)));
            catch
            end
            try
                r = celldb.refreshSubjects(ids);
            catch ME
                r.message = "Subjects not checked: " + string(ME.message);
            end
            obj.closeProgressDlg(dlg);
            obj.refreshDatabase(false);
            obj.setStatus(char(r.message));
        end

        function r = queueRecords(obj)
            % The Queue records button: put the provenance records kept beside
            % the files below the parent directory, and not yet in this
            % computer's outbox, into it (celldb.backfill).
            r = struct('found', 0, 'queued', 0, 'already', 0, 'failed', 0, ...
                'problems', strings(0, 1), 'message', "");
            if ~CellDatasetManager.hasCelldb()
                return;
            end
            if isempty(obj.ParentDirectory) || ~isfolder(obj.ParentDirectory)
                obj.setStatus('Scan a parent directory first.');
                return;
            end
            set(obj.Figure, 'Pointer', 'watch'); drawnow;
            try
                r = celldb.backfill(string(obj.ParentDirectory));
            catch ME
                r.message = "The records were not queued: " + string(ME.message);
            end
            set(obj.Figure, 'Pointer', 'arrow');
            obj.refreshDatabase(false);
            obj.setStatus(char(r.message));
        end

        function openDatabase(obj)
            % The Database... button: the lab database's window (celldb.openWindow).
            % Without the client the reason goes to the status bar.
            if ~CellDatasetManager.hasCelldb()
                return;
            end
            try
                [ok, why] = celldb.available();
                if ~ok
                    obj.setStatus(char("No Database window: " + string(why)));
                    return;
                end
                celldb.openWindow('Parent', obj.Figure);
            catch ME
                obj.setStatus(['The Database window could not be opened: ' ME.message]);
            end
        end

        function handled = handleKey(obj, key, modifiers)
            % What the window's key handler calls. F5 scans again; Ctrl+F puts
            % the cursor in Find and Ctrl+T in Tags; Ctrl+E selects the next dataset to curate;
            % Enter opens the selected dataset (not while a text field has the
            % focus: there it ends the edit).
            if nargin < 3, modifiers = {}; end
            modifiers = cellstr(string(modifiers));
            ctrl = any(strcmp(modifiers, 'control'));
            handled = true;
            switch lower(char(key))
                case 'f5'
                    obj.onScan();
                case 'f'
                    if ~ctrl, handled = false; return; end
                    try
                        focus(obj.FindEdit);
                    catch
                    end
                case 't'
                    if ~ctrl, handled = false; return; end
                    try
                        focus(obj.TagsEdit);
                    catch
                    end
                case 'e'
                    if ~ctrl, handled = false; return; end
                    obj.nextToCurate();
                case 'return'
                    obj.openSelected();
                otherwise
                    handled = false;
            end
        end

        function waitForIdle(obj)
            % Run now what is deferred (the first scan, the preview, a Database
            % column refresh) and draw. For tests and scripts.
            drawnow;                          % what was just set reaches the window first
            names = fieldnames(obj.Pending);
            for i = 1:numel(names)
                fcn = [];
                if isfield(obj.Pending, names{i}), fcn = obj.Pending.(names{i}); end
                obj.cancelDeferred(names{i});
                if ~isempty(fcn)
                    fcn();
                end
            end
            drawnow;
        end

        function zoomPreview(obj, tile, notches, xy)
            % Zoom preview tile `tile` by PREVIEW_ZOOM_STEP^notches about the
            % image point xy (the view's center when omitted): notches < 0
            % zooms in, as the wheel turned up does. The view stays inside
            % the image and spans no less than PREVIEW_MIN_SPAN pixels.
            if tile < 1 || tile > numel(obj.Tiles), return; end
            L = obj.previewLimits(tile);
            if nargin < 4 || isempty(xy)
                xy = [mean(L(1:2)) mean(L(3:4))];
            end
            F = obj.Tiles(tile).Full;
            fullSpan = [diff(F(1:2)) diff(F(3:4))];
            r0 = diff(L(1:2)) / fullSpan(1);       % the share of the image shown
            rMin = min(1, CellDatasetManager.PREVIEW_MIN_SPAN / min(fullSpan));
            r = min(max(r0 * CellDatasetManager.PREVIEW_ZOOM_STEP ^ notches, rMin), 1);
            if abs(r - r0) < 1e-12, return; end
            s = r / r0;
            xl = xy(1) - (xy(1) - L(1)) * s + [0 diff(L(1:2)) * s];
            yl = xy(2) - (xy(2) - L(3)) * s + [0 diff(L(3:4)) * s];
            obj.setPreviewView(tile, xl, yl);
        end

        function fitPreview(obj)
            % Show the whole image in every preview tile.
            for k = 1:numel(obj.Tiles)
                F = obj.Tiles(k).Full;
                obj.setPreviewView(k, F(1:2), F(3:4));
            end
        end

        function L = previewLimits(obj, tile)
            % [x1 x2 y1 y2] of what preview tile `tile` shows ([] when none).
            L = [];
            if tile >= 1 && tile <= numel(obj.Tiles) && isvalid(obj.Tiles(tile).Axes)
                ax = obj.Tiles(tile).Axes;
                L = [ax.XLim ax.YLim];
            end
        end

        function addCloseListener(obj, fcn)
            % fcn() when the window is destroyed.
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                addlistener(obj.Figure, 'ObjectBeingDestroyed', @(~, ~) fcn());
            end
        end

    end

    %% ===================================================================
    %  Dashboard GUI
    %  ===================================================================
    methods (Access = private)

        function buildUI(obj)
            obj.Figure = uifigure('Name', 'Cell Dataset Manager', ...
                'Position', [80 80 1760 760]);
            obj.Figure.CloseRequestFcn = @(s,e) obj.onClosing();
            obj.Figure.DeleteFcn = @(s,e) obj.savePreferences();
            obj.Figure.WindowKeyPressFcn = @(s,e) obj.onKey(e);
            % The preview's mouse: wheel zoom about the pointer, drag to pan.
            obj.Figure.WindowScrollWheelFcn  = @(s,e) obj.onPreviewScroll(e);
            obj.Figure.WindowButtonDownFcn   = @(s,e) obj.onPreviewPress(e);
            obj.Figure.WindowButtonMotionFcn = @(s,e) obj.onPreviewMotion(e);
            obj.Figure.WindowButtonUpFcn     = @(s,e) obj.onPreviewRelease(e);
            root = uigridlayout(obj.Figure, [3 1]);
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
            CellToolkit.setTooltip(obj.ParentDirEdit, ...
                ['Parent directory to search for datasets (every folder below it ' ...
                 'is scanned). Press Enter to scan.']);
            obj.BrowseButton = uibutton(tb, 'Text', 'Browse...', ...
                'ButtonPushedFcn', @(s,e) obj.onBrowse());
            CellToolkit.setTooltip(obj.BrowseButton, ...
                'Choose the parent directory to search for datasets, then scan it.');
            obj.ScanButton = uibutton(tb, 'Text', 'Scan [F5]', ...
                'ButtonPushedFcn', @(s,e) obj.onScan());
            CellToolkit.setTooltip(obj.ScanButton, ...
                ['Find every dataset below the parent directory again and re-read ' ...
                 'how far each one is (F5). The list is also refreshed when a tool ' ...
                 'opened from here closes.']);
            obj.OpenFolderButton = uibutton(tb, 'Text', 'Open folder', ...
                'ButtonPushedFcn', @(s,e) obj.onOpenFolder());
            CellToolkit.setTooltip(obj.OpenFolderButton, ...
                ['Show the selected dataset''s folder in the file browser, or the ' ...
                 'parent directory when no dataset is selected.']);

            uilabel(tb, 'Text', 'Locs suffix:', 'HorizontalAlignment', 'right');
            obj.LocsTokenEdit = uieditfield(tb, 'text', ...
                'Value', CellDatasetManifest.locsToken(), ...
                'ValueChangedFcn', @(s,e) obj.onLocsTokenChanged());
            CellToolkit.setTooltip(obj.LocsTokenEdit, ...
                ['Filename suffix that marks a localization CSV (default ' ...
                 '"_locs"). The stem before it gives the dataset base and ' ...
                 'optional <channel><page>; a trailing "_resized" still ' ...
                 'denotes resized coordinates. Changing it scans again.']);

            % --- Content split: left (datasets + detail) | right (pages) -
            contentSplit = uigridlayout(root, [1 2]);
            contentSplit.Layout.Row = 2;
            contentSplit.ColumnWidth = {'1x', 500};
            contentSplit.ColumnSpacing = 6;
            contentSplit.Padding = [4 0 4 0];

            % Left column: datasets (top) + selected-dataset detail (bottom).
            main = uigridlayout(contentSplit, [2 1]);
            main.Layout.Column = 1;
            main.RowHeight = {'1x', 290};
            main.Padding = [0 0 0 0];

            leftPanel = uipanel(main, 'Title', 'Datasets');
            lg = uigridlayout(leftPanel, [3 1]);
            lg.RowHeight = {'fit', 'fit', '1x'};
            lg.RowSpacing = 6;

            % Cumulative progress across all discovered datasets.
            obj.buildSummaryBar(lg);
            obj.buildFilterBar(lg);

            obj.DatasetTable = uitable(lg, ...
                'ColumnName', obj.DATASET_COLUMNS, ...
                'ColumnEditable', false(1, numel(obj.DATASET_COLUMNS)), ...
                'ColumnSortable', true(1, numel(obj.DATASET_COLUMNS)), ...
                'ColumnWidth', {100, 76, '1x', 80, 96, 88, 102, 78, 60, 108, 136, 150}, ...
                'RowName', {}, 'SelectionType', 'row', 'Multiselect', 'off', ...
                'SelectionChangedFcn', @(s,e) obj.onDatasetSelected(e), ...
                'DoubleClickedFcn', @(s,e) obj.onDatasetDoubleClicked(e), ...
                'KeyPressFcn', @(s,e) obj.onTableKey(e));
            obj.DatasetTable.Layout.Row = 3;
            CellToolkit.setTooltip(obj.DatasetTable, ...
                ['One row per dataset. Subject and Section come from the file name. ' ...
                 'Rescored: sources with Stage-2 scores. Reviewed %: share of the cells ' ...
                 'a person has decided. Curated: sources marked complete in Cell Curator. ' ...
                 'Kept: cells labeled Good, reviewed and outside every exclusion region. ' ...
                 'Database: where the lab database records of the completed sources are. ' ...
                 'Tags: the tags of the subject in the lab database (as Check subjects ' ...
                 'last read them; the Tags field above filters by them, and the detail ' ...
                 'of a selected dataset lists its variables too). ' ...
                 'A subject in red is not in the lab database. Click a header to sort; ' ...
                 'Enter or a double-click opens the dataset in Cell Curator (Cell ' ...
                 'Discovery when it has no detections yet).']);

            detailPanel = uipanel(main, 'Title', 'Selected dataset');
            rg = uigridlayout(detailPanel, [3 1]);
            rg.RowHeight = {'fit', '1x', 'fit'};

            obj.DetailLabel = uilabel(rg, 'Text', 'Select a dataset.', ...
                'VerticalAlignment', 'top', 'WordWrap', 'on');
            obj.DetailLabel.Layout.Row = 1;

            obj.SourceTable = uitable(rg, ...
                'ColumnName', obj.SOURCE_COLUMNS, ...
                'ColumnEditable', false(1, numel(obj.SOURCE_COLUMNS)), ...
                'ColumnSortable', false(1, numel(obj.SOURCE_COLUMNS)), ...
                'ColumnWidth', {70, 44, 78, 66, 70, 56, 56, 56, 70, '1x', 150}, ...
                'RowName', {}, 'SelectionType', 'row', 'Multiselect', 'off', ...
                'SelectionChangedFcn', @(s,e) obj.onSourceSelected(e), ...
                'DoubleClickedFcn', @(s,e) obj.onSourceDoubleClicked(e));
            obj.SourceTable.Layout.Row = 2;
            CellToolkit.setTooltip(obj.SourceTable, ...
                ['One row per source (channel and page) of the selected dataset. ' ...
                 'Reviewed, Good, Bad and Kept are Cell Curator''s counts, or those ' ...
                 'of a legacy QC file when the source was never opened there (nothing ' ...
                 'is Kept then). Complete: marked complete in Cell Curator, which ' ...
                 'writes <stem>_final.csv. Database: where the lab database record of ' ...
                 'that completion is. Legacy: what the removed QC and Neighbor ' ...
                 'Resolver tools left (imported by Cell Curator the first time it ' ...
                 'opens the source). Select a row to open that source with Curate...; ' ...
                 'a double-click opens it.']);

            launch = uigridlayout(rg, [1 6]);
            launch.Layout.Row = 3;
            obj.DiscoveryButton = uibutton(launch, 'Text', 'Detect cells...', ...
                'ButtonPushedFcn', @(s,e) obj.launch('discovery'));
            CellToolkit.setTooltip(obj.DiscoveryButton, ...
                ['Open Cell Discovery pointed at the selected dataset''s folder, ' ...
                 'or the parent directory when none is selected.']);
            obj.CuratorButton = uibutton(launch, 'Text', 'Curate... [Enter]', ...
                'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(s,e) obj.launch('curator'));
            CellToolkit.setTooltip(obj.CuratorButton, ...
                ['Open Cell Curator to review detections: mark cells Good or Bad a ' ...
                 'screenful at a time, merge duplicates, add missed cells and move ' ...
                 'mis-centered ones. Opens on the selected dataset and source, and ' ...
                 'can continue through every dataset below the parent directory. ' ...
                 'Imports old *_QC.csv labels and Neighbor Resolver edits the first ' ...
                 'time it opens a source. Enter in the dataset list does the same.']);
            obj.AnalysisButton = uibutton(launch, 'Text', 'Analyze...', ...
                'ButtonPushedFcn', @(s,e) obj.launch('analysis'));
            CellToolkit.setTooltip(obj.AnalysisButton, ...
                ['Open Cell Analysis on the parent directory: measure every cell (distance ' ...
                 'from the brain surface, luminance, morphology, the shape of the nets) ' ...
                 'and plot the distributions within a section and across sections, ' ...
                 'grouped by subject, by what the lab database knows, or by your own groups.']);
            obj.SetActiveLocsButton = uibutton(launch, 'Text', 'Set active locs...', ...
                'ButtonPushedFcn', @(s,e) obj.onSetActiveLocs(), 'Enable', false);
            obj.SetActiveImageButton = uibutton(launch, 'Text', 'Set active image...', ...
                'ButtonPushedFcn', @(s,e) obj.onSetActiveImage(), 'Enable', false);
            obj.OpenManifestButton = uibutton(launch, 'Text', 'Open manifest', ...
                'ButtonPushedFcn', @(s,e) obj.onOpenManifest(), 'Enable', false);
            obj.setLaunchEnabled(false);

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
                ['Overlay detected cell centers (from each source''s locs CSV) ' ...
                 'as filled circles. Individual pages show only that ' ...
                 'page''s source; the composite shows every source.']);
            uilabel(pageToolbar, 'Text', 'Color:', 'HorizontalAlignment', 'right');
            obj.LocationColorDropDown = uidropdown(pageToolbar, ...
                'Items', {'Uniform', 'By page', 'By rescore', 'By class'}, 'Value', 'Uniform', ...
                'Enable', 'off', ...
                'ValueChangedFcn', @(s,e) obj.onOverlayOptionChanged());
            obj.setLocationColorTooltip();

            obj.PageContent = uipanel(pageGrid, 'BorderType', 'none');
            obj.PageContent.Layout.Row = 2;
            CellToolkit.setTooltip(obj.PageContent, ...
                ['Scroll to zoom in or out at the pointer; drag to pan. The pages ' ...
                 'zoom together. Double-click a page to open it in its own window; ' ...
                 'right-click to fit the whole image.']);

            obj.refreshPagePreview();   % render the initial "select a dataset" hint

            % --- Status bar ------------------------------------------------
            sb = uigridlayout(root, [1 5]);
            sb.Layout.Row = 3;
            sb.ColumnWidth = {'1x', 'fit', 'fit', 'fit', 'fit'};
            sb.Padding = [4 2 4 4];
            sb.ColumnSpacing = 6;
            obj.StatusLabel = uilabel(sb, 'Text', 'Ready.', ...
                'HorizontalAlignment', 'left');
            obj.StatusLabel.Layout.Column = 1;
            obj.StatusText = 'Ready.';
            obj.buildDatabase(sb);
        end

        function buildSummaryBar(obj, parent)
            % A row of "stat cards" over all discovered datasets (whatever the
            % filter shows). Values are filled in by refreshSummary().
            statBar = uigridlayout(parent, [1 8]);
            statBar.Layout.Row = 1;
            statBar.RowHeight = {'fit'};   % so the 'fit' parent row sizes to the cards
            statBar.Padding = [4 2 4 2];
            statBar.ColumnSpacing = 8;
            mk = @CellDatasetManager.makeStat;
            obj.StatLabels = struct( ...
                'Datasets',   mk(statBar, 'Datasets', 'Datasets found below the parent directory.'), ...
                'ToDetect',   mk(statBar, 'To detect', 'Datasets with an image and no detections yet (Detect cells...).'), ...
                'Sources',    mk(statBar, 'Sources', 'Sources (channel and page) with detections, over all datasets.'), ...
                'Detections', mk(statBar, 'Detections', 'Detections over all sources.'), ...
                'Reviewed',   mk(statBar, 'Cells reviewed', 'Share of all cells a person has decided (Cell Curator, or a legacy QC file).'), ...
                'Curated',    mk(statBar, 'Sources curated', 'Sources marked complete in Cell Curator, of all sources.'), ...
                'Kept',       mk(statBar, 'Cells kept', 'Kept cells over all sources: labeled Good by a person, reviewed, outside every exclusion region.'), ...
                'Database',   mk(statBar, 'In database', 'Completed sources whose current state was sent to the lab database from this computer, of all completed sources.'));
        end

        function buildFilterBar(obj, parent)
            % Find + Show narrow the list; Next to curate and Export report act on it.
            fb = uigridlayout(parent, [1 8]);
            fb.Layout.Row = 2;
            fb.ColumnWidth = {'fit', '1x', 'fit', 170, 'fit', 150, 'fit', 'fit'};
            fb.Padding = [4 0 4 0];
            fb.ColumnSpacing = 6;
            uilabel(fb, 'Text', 'Find:', 'HorizontalAlignment', 'right');
            obj.FindEdit = uieditfield(fb, 'text', ...
                'ValueChangingFcn', @(s,e) obj.onFindChanging(e), ...
                'ValueChangedFcn', @(s,e) obj.onFindChanged());
            try
                obj.FindEdit.Placeholder = 'name, subject, section, folder or status  [Ctrl+F]';
            catch
            end
            CellToolkit.setTooltip(obj.FindEdit, ...
                ['List only the datasets that contain every word typed here in their ' ...
                 'name, subject, section, folder below the parent directory, status, or ' ...
                 'in the lab database tags and variables of their subject ' ...
                 '(Ctrl+F puts the cursor here). Empty lists all.']);
            uilabel(fb, 'Text', 'Tags:', 'HorizontalAlignment', 'right');
            obj.TagsEdit = uieditfield(fb, 'text', 'Tag', 'edit:tags', ...
                'ValueChangedFcn', @(s,e) obj.setTagFilter(s.Value));
            try
                obj.TagsEdit.Placeholder = 'cohort:a -qc:fail  [Ctrl+T]';
            catch
            end
            CellToolkit.setTooltip(obj.TagsEdit, ...
                ['List only the datasets whose subject carries these lab database tags; ' ...
                 'press Enter (Ctrl+T puts the cursor here). Tags separated by spaces ' ...
                 'must all hold; a leading "-" means "does not have"; "cohort:*" means ' ...
                 'any tag of that namespace; a bare word is a bare tag. Example: ' ...
                 'cohort:a -qc:fail. The tags are the ones Check subjects last read: a ' ...
                 'dataset whose subject was never checked, or whose name names no ' ...
                 'subject, is not listed while a filter is set. The status line says ' ...
                 'when no subject here carries a tag you typed.']);
            uilabel(fb, 'Text', 'Show:', 'HorizontalAlignment', 'right');
            obj.ShowDropDown = uidropdown(fb, 'Items', obj.SHOW_ITEMS, ...
                'Value', obj.SHOW_ITEMS{1}, ...
                'ValueChangedFcn', @(s,e) obj.onShowChanged());
            CellToolkit.setTooltip(obj.ShowDropDown, ...
                ['Which datasets to list.  To detect: an image and no detections ' ...
                 'yet.  To curate: detected, no cell reviewed.  In curation: some ' ...
                 'cells reviewed, not every source complete.  Curated: every source ' ...
                 'marked complete.  Database: not sent: a completed source whose ' ...
                 'current state was not sent to the lab database from this computer.']);
            obj.NextButton = uibutton(fb, 'Text', 'Next to curate [Ctrl+E]', ...
                'ButtonPushedFcn', @(s,e) obj.nextToCurate());
            CellToolkit.setTooltip(obj.NextButton, ...
                ['Select the next listed dataset that has detections and is not ' ...
                 'marked complete, and its first unfinished source (Ctrl+E). Then ' ...
                 'Enter opens it in Cell Curator.']);
            obj.ExportButton = uibutton(fb, 'Text', 'Export report...', ...
                'ButtonPushedFcn', @(s,e) obj.exportReport());
            CellToolkit.setTooltip(obj.ExportButton, ...
                ['Write a CSV with one row per source of every dataset found: subject, ' ...
                 'section, detections, reviewed, Good, Bad, kept, complete, the lab ' ...
                 'database state and the final CSV of each completed source.']);
        end

        function buildDatabase(obj, sb)
            % The lab database at the right end of the status bar: Check
            % subjects, Queue records, Database... and the lamp (celldb.addLamp).
            % Without the celldb package there is none of it; without the
            % client the buttons say what is missing. Nothing here may change
            % what the manager writes.
            if ~CellDatasetManager.hasCelldb()
                return;
            end
            try
                obj.CheckSubjectsButton = uibutton(sb, 'Text', 'Check subjects', 'FontSize', 11, ...
                    'Tag', 'btn:checkSubjects', 'ButtonPushedFcn', @(s,e) obj.checkSubjects());
                obj.CheckSubjectsButton.Layout.Column = 2;
                obj.QueueButton = uibutton(sb, 'Text', 'Queue records', 'FontSize', 11, ...
                    'Tag', 'btn:queueRecords', 'ButtonPushedFcn', @(s,e) obj.queueRecords());
                obj.QueueButton.Layout.Column = 3;
                obj.DatabaseButton = uibutton(sb, 'Text', 'Database...', 'FontSize', 11, ...
                    'Tag', 'btn:database', 'ButtonPushedFcn', @(s,e) obj.openDatabase());
                obj.DatabaseButton.Layout.Column = 4;
                obj.DbLamp = celldb.addLamp(sb, 'Row', 1, 'Column', 5, 'Parent', obj.Figure);
                obj.DbListeners = celldb.listen(@() obj.onDatabaseChanged());
            catch ME
                warning('CellDatasetManager:database', 'No lab database controls: %s', ME.message);
            end
        end

        function updateDatabaseControls(obj)
            % Enable the lab database buttons for what can be done now, and say
            % in each tooltip why one cannot.
            if isempty(obj.DatabaseButton) || ~isvalid(obj.DatabaseButton)
                return;
            end
            ok = false; why = ""; capturing = false; state = "";
            try
                [ok, why] = celldb.available();
                capturing = ok && celldb.capturing();
                state = string(celldb.statusText());
            catch
            end
            nSubjects = 0; nLocal = 0;
            if ~isempty(obj.Datasets)
                ids = string({obj.Datasets.SubjectID});
                nSubjects = numel(unique(ids(strlength(ids) > 0)));
                for k = 1:numel(obj.Datasets)
                    for i = 1:numel(obj.Datasets(k).Sources)
                        nLocal = nLocal + double(CellDatasetManager.dbOf(obj.Datasets(k).Sources(i)).state == "local");
                    end
                end
            end
            off = "";
            if ~ok
                off = " Not available: " + why;
            elseif ~capturing
                off = " Not available: the lab database is turned off on this computer (Database... turns it on).";
            end

            tip = "Ask the lab database which of the subjects named by the file names here it has, and for " + ...
                "their tags and variables (a few seconds at most). A record of a subject it does not have " + ...
                "waits in the outbox until the subject is added or assigned; such a subject is shown in red. " + ...
                "The tags fill the Tags column and are what the Tags field filters by; Cell Analysis groups " + ...
                "and plots by the tags and variables.";
            en = ok && capturing && nSubjects > 0;
            if off ~= ""
                tip = tip + off;
            elseif nSubjects == 0
                tip = tip + " Nothing to check: no file name in the list names a SUBJ-ID.";
            end
            obj.CheckSubjectsButton.Enable = CellToolkit.ternary(en, 'on', 'off');
            CellToolkit.setTooltip(obj.CheckSubjectsButton, tip);

            tip = "Put the lab database records that are kept beside the files below the parent directory, " + ...
                "and are not in this computer's outbox, into it (records made while the database was " + ...
                "turned off or the client was not installed, or on another computer). A record is never " + ...
                "written twice by the database.";
            en = ok && capturing && nLocal > 0;
            if off ~= ""
                tip = tip + off;
            elseif nLocal == 0
                tip = tip + " Nothing to queue: no record in the list is outside the outbox.";
            else
                tip = tip + sprintf(" %d record(s) in the list are not queued.", nLocal);
            end
            obj.QueueButton.Enable = CellToolkit.ternary(en, 'on', 'off');
            CellToolkit.setTooltip(obj.QueueButton, tip);

            tip = "Open the lab database's window: the server, your login, the storage roots mapped on " + ...
                "this computer and the outbox of records waiting to be sent.";
            if strlength(state) > 0
                tip = tip + " " + state;
            end
            CellToolkit.setTooltip(obj.DatabaseButton, tip);
        end

        function onDatabaseChanged(obj)
            % The lab database's state or the outbox changed (celldb.listen):
            % show where the records are now. Asked of the outbox only, and not
            % more than once a second while records are being sent.
            if isempty(obj.Figure) || ~isvalid(obj.Figure)
                return;
            end
            recent = ~isequal(obj.DbRefreshedAt, 0) && toc(obj.DbRefreshedAt) < 1;
            if recent
                obj.defer('database', 1, @() obj.refreshDatabase(true));
            else
                obj.refreshDatabase(true);
            end
        end

        function dropDatabaseListeners(obj)
            L = obj.DbListeners;
            obj.DbListeners = {};
            for i = 1:numel(L)
                try
                    delete(L{i});
                catch
                end
            end
        end

        % ------------------------------------------------------------ deferral

        function defer(obj, name, delay, fcn)
            % Run fcn() once, DELAY seconds from now, replacing what was
            % deferred under the same NAME (so a burst of requests runs once).
            obj.cancelDeferred(name);
            obj.Pending.(name) = fcn;
            try
                t = timer('StartDelay', delay, 'ExecutionMode', 'singleShot', ...
                    'Name', ['CellDatasetManager.' name], ...
                    'TimerFcn', @(~,~) obj.runDeferred(name));
                obj.Timers.(name) = t;
                start(t);
            catch
                % Timers unavailable: run it now.
                obj.runDeferred(name);
            end
        end

        function runDeferred(obj, name)
            if ~isvalid(obj) || ~isfield(obj.Pending, name)
                return;
            end
            fcn = obj.Pending.(name);
            obj.cancelDeferred(name);
            if isempty(obj.Figure) || ~isvalid(obj.Figure)
                return;
            end
            try
                fcn();
            catch ME
                obj.setStatus(['Could not finish: ' ME.message]);
            end
        end

        function cancelDeferred(obj, name)
            if isfield(obj.Pending, name)
                obj.Pending = rmfield(obj.Pending, name);
            end
            if isfield(obj.Timers, name)
                t = obj.Timers.(name);
                obj.Timers = rmfield(obj.Timers, name);
                if ~isempty(t) && isa(t, 'timer') && isvalid(t)
                    try
                        stop(t);
                        delete(t);
                    catch
                    end
                end
            end
        end

        function cancelAllDeferred(obj)
            names = fieldnames(obj.Timers);
            for i = 1:numel(names)
                obj.cancelDeferred(names{i});
            end
            obj.Pending = struct();
        end

        % ------------------------------------------------------------ scanning

        function setStatus(obj, txt)
            obj.StatusText = char(txt);
            if ~isempty(obj.StatusLabel) && isvalid(obj.StatusLabel)
                obj.StatusLabel.Text = obj.StatusText;
            end
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
                obj.setStatus('Enter a valid parent directory.');
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
            % Re-scan obj.ParentDirectory and refresh the window. Used by
            % the Scan button (preserveSelection=false, clears selection) and
            % by the refresh when a launched Cell* GUI closes
            % (preserveSelection=true, so the dataset and source the user was
            % working on stay selected after their status is read again).
            if nargin < 2, preserveSelection = false; end
            obj.cancelDeferred('scan');
            parentDir = obj.ParentDirectory;
            if isempty(parentDir) || ~isfolder(parentDir)
                obj.setStatus('Enter a valid parent directory.');
                return;
            end

            prevID = ''; prevKey = '';
            if preserveSelection
                d = obj.selectedDataset();
                if ~isempty(d), prevID = char(d.DatasetID); end
                s = obj.selectedSource();
                if ~isempty(s), prevKey = char(s.Key); end
            end

            obj.setStatus('Scanning...');
            set(obj.Figure, 'Pointer', 'watch');
            drawnow;
            t0 = tic;
            obj.ScanProgress = struct('Dialog', [], 'Started', t0, 'Shown', 0);
            progFn = @(k, n, base) obj.onScanProgress(k, n, base);
            try
                found = CellDatasetManager.scan(parentDir, struct('Progress', progFn));
            catch ME
                obj.endScanProgress();
                if strcmp(ME.identifier, 'CellDatasetManager:scanCanceled')
                    obj.setStatus('Scan canceled: the list is as it was.');
                else
                    obj.setStatus(['Scan failed: ' ME.message]);
                end
                return;
            end
            obj.endScanProgress();
            obj.Datasets = found;

            obj.SelectedDatasetIndex = 0;
            obj.SelectedSourceRow = 0;
            if ~isempty(prevID)
                for k = 1:numel(obj.Datasets)
                    if strcmp(char(obj.Datasets(k).DatasetID), prevID)
                        obj.SelectedDatasetIndex = k;
                        break;
                    end
                end
            end
            obj.PreviewImagePath = '';   % the overlay may show what just changed
            obj.refreshSummary();
            obj.applyFilter();
            if obj.SelectedDatasetIndex > 0 && ~isempty(prevKey)
                obj.selectSource(prevKey);
            end
            obj.updateDatabaseControls();
            obj.setStatus(sprintf('%d dataset(s) under %s, %d listed (%.1f s).', ...
                numel(obj.Datasets), parentDir, numel(obj.View), toc(t0)));
        end

        function onScanProgress(obj, k, n, base)
            % Progress callback passed to CellDatasetManifest.discover (once per
            % dataset). A scan that is done within SCAN_DIALOG_AFTER seconds
            % shows no dialog at all (creating and updating one costs more than
            % a short scan); a longer one gets a cancelable progress dialog,
            % updated a few times a second. Throws to cancel when the user
            % clicks Cancel.
            P = obj.ScanProgress;
            if isempty(P) || ~isstruct(P)
                return;
            end
            elapsed = toc(P.Started);
            if isempty(P.Dialog)
                if elapsed < obj.SCAN_DIALOG_AFTER
                    return;
                end
                try
                    P.Dialog = uiprogressdlg(obj.Figure, 'Title', 'Scanning datasets', ...
                        'Message', 'Finding datasets...', 'Cancelable', 'on');
                catch
                    P.Dialog = [];
                    P.Started = tic;        % no dialog can be made: try again later
                    obj.ScanProgress = P;
                    return;
                end
            elseif ~isvalid(P.Dialog)
                return;
            elseif P.Dialog.CancelRequested
                error('CellDatasetManager:scanCanceled', 'Scan canceled by user.');
            elseif elapsed - P.Shown < 0.25
                return;
            end
            P.Shown = elapsed;
            obj.ScanProgress = P;
            if n > 0
                P.Dialog.Value = max(0, min(1, k / n));
            end
            [~, shortName] = fileparts(char(base));
            P.Dialog.Message = sprintf('Scanning %d of %d:  %s', k, n, shortName);
            drawnow limitrate;
        end

        function endScanProgress(obj)
            P = obj.ScanProgress;
            obj.ScanProgress = [];
            if isstruct(P)
                obj.closeProgressDlg(P.Dialog);
            end
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                set(obj.Figure, 'Pointer', 'arrow');
            end
        end

        function closeProgressDlg(~, dlg)
            if ~isempty(dlg) && isvalid(dlg)
                try
                    close(dlg);
                catch
                end
            end
        end

        function attachRefreshOnClose(obj, app)
            % Re-scan when a launched Cell* GUI window closes, so the status
            % shows the work just done without a manual re-scan. The launched
            % app attaches the listener to its own (private) figure via
            % addCloseListener, so its encapsulation and existing
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
            if isvalid(obj) && ~isempty(obj.Figure) && isvalid(obj.Figure)
                obj.rescan(true);
            end
        end

        % ------------------------------------------------------------ the list

        function onFindChanging(obj, e)
            % Filter while typing.
            obj.FilterText = strtrim(char(e.Value));
            obj.applyFilter();
        end

        function onFindChanged(obj)
            obj.FilterText = strtrim(char(obj.FindEdit.Value));
            obj.applyFilter();
        end

        function onShowChanged(obj)
            obj.FilterShow = char(obj.ShowDropDown.Value);
            obj.applyFilter();
        end

        function applyFilter(obj)
            % Recompute which datasets are listed (View) from the Find text and
            % the Show item, keep the selection when it is still listed, and
            % redraw the table and the detail.
            n = numel(obj.Datasets);
            keep = true(1, n);
            words = lower(strsplit(strtrim(obj.FilterText)));
            words = words(~cellfun(@isempty, words));
            obj.TagNote = '';
            if ~isempty(obj.FilterTags) && n > 0
                try
                    [byTag, note] = celldb.tagFilter(string({obj.Datasets.SubjectID})', obj.FilterTags);
                    keep = reshape(logical(byTag), 1, []);
                    obj.TagNote = char(note);
                catch ME
                    keep(:) = false;
                    obj.TagNote = ['The tag filter shows nothing: ' ME.message];
                end
            end
            for k = 1:n
                d = obj.Datasets(k);
                p = CellDatasetManager.progressOf(d);
                switch obj.FilterShow
                    case 'To detect',          keep(k) = keep(k) && strcmp(p.Stage, 'detect');
                    case 'To curate',          keep(k) = keep(k) && strcmp(p.Stage, 'curate');
                    case 'In curation',        keep(k) = keep(k) && strcmp(p.Stage, 'curating');
                    case 'Curated',            keep(k) = keep(k) && strcmp(p.Stage, 'curated');
                    case 'Database: not sent', keep(k) = keep(k) && CellDatasetManager.notSent(d);
                end
                if keep(k) && ~isempty(words)
                    hay = lower(strjoin({d.Base, d.SubjectID, d.SectionLabel, d.DatasetID, d.Status, ...
                        d.SubjectTags, d.SubjectVariables}, ' '));
                    keep(k) = all(cellfun(@(w) contains(hay, w), words));
                end
            end
            obj.View = find(keep);
            if ~any(obj.View == obj.SelectedDatasetIndex)
                obj.SelectedDatasetIndex = 0;
                obj.SelectedSourceRow = 0;
            end
            obj.refreshDatasetTable();
            obj.syncDatasetTableSelection();
            obj.refreshDetail();
            if n > 0 && numel(obj.View) < n
                obj.setStatus(strtrim(sprintf('%d of %d dataset(s) listed. %s', numel(obj.View), n, obj.TagNote)));
            elseif n > 0
                obj.setStatus(strtrim(sprintf('%d dataset(s) listed. %s', n, obj.TagNote)));
            end
        end

        function refreshDatasetTable(obj)
            v = obj.View;
            n = numel(v);
            data = cell(n, numel(obj.DATASET_COLUMNS));
            for r = 1:n
                d = obj.Datasets(v(r));
                p = CellDatasetManager.progressOf(d);
                data(r, :) = {d.SubjectID, d.SectionLabel, d.Base, p.Sources, d.TotalDetections, ...
                    CellDatasetManager.frac(d.Sources, 'rescore'), p.Pct, ...
                    CellDatasetManager.frac(d.Sources, 'complete'), p.Kept, d.Status, d.Database, ...
                    d.SubjectTags};
            end
            obj.DatasetTable.Data = data;
            obj.styleDatasetTable();
        end

        function styleDatasetTable(obj)
            % Color the Status and Database cells by state, and a subject the
            % lab database does not have in red.
            tbl = obj.DatasetTable;
            try
                removeStyle(tbl);
            catch
            end
            v = obj.View;
            if isempty(v)
                return;
            end
            green = [0.10 0.50 0.20]; blue = [0.05 0.35 0.75]; gray = [0.45 0.45 0.45];
            orange = [0.75 0.45 0.00]; red = [0.75 0.10 0.10];
            statusCol = find(strcmp(obj.DATASET_COLUMNS, 'Status'));
            dbCol     = find(strcmp(obj.DATASET_COLUMNS, 'Database'));
            subjCol   = find(strcmp(obj.DATASET_COLUMNS, 'Subject'));
            stage = cell(1, numel(v)); db = strings(1, numel(v)); noSubj = false(1, numel(v));
            for r = 1:numel(v)
                d = obj.Datasets(v(r));
                p = CellDatasetManager.progressOf(d);
                stage{r} = p.Stage;
                db(r) = CellDatasetManager.worstDbState(d.Sources);
                noSubj(r) = d.SubjectAsked && ~d.SubjectKnown;
            end
            paint = @(rows, col, color, weight) CellDatasetManager.paintCells(tbl, rows, col, color, weight);
            paint(strcmp(stage, 'curated'),  statusCol, green, 'bold');
            paint(strcmp(stage, 'curating'), statusCol, blue, 'normal');
            paint(strcmp(stage, 'detect'),   statusCol, gray, 'normal');
            paint(db == "sent",              dbCol, green, 'normal');
            paint(db == "queued",            dbCol, orange, 'normal');
            paint(db == "local" | db == "discarded", dbCol, gray, 'normal');
            paint(db == "held" | db == "failed", dbCol, red, 'bold');
            paint(noSubj,                    subjCol, red, 'bold');
        end

        function refreshSummary(obj)
            % The stat cards: totals over all datasets, whatever the filter shows.
            if isempty(obj.StatLabels) || isempty(fieldnames(obj.StatLabels))
                return;
            end
            ds = obj.Datasets;
            nSources = 0; nComplete = 0; nDetections = 0; nCells = 0; nReviewed = 0; nKept = 0;
            nToDetect = 0; nSent = 0;
            for k = 1:numel(ds)
                p = CellDatasetManager.progressOf(ds(k));
                nSources = nSources + p.Sources;
                nComplete = nComplete + p.Complete;
                nDetections = nDetections + ds(k).TotalDetections;
                nCells = nCells + p.Cells;
                nReviewed = nReviewed + p.Reviewed;
                nKept = nKept + p.Kept;
                nToDetect = nToDetect + double(strcmp(p.Stage, 'detect'));
                for i = 1:numel(ds(k).Sources)
                    db = CellDatasetManager.dbOf(ds(k).Sources(i));
                    nSent = nSent + double(ds(k).Sources(i).CurComplete && db.state == "sent" && db.current);
                end
            end
            pct = 0;
            if nCells > 0, pct = floor(100 * nReviewed / nCells); end
            L = obj.StatLabels;
            L.Datasets.Text   = sprintf('%d', numel(ds));
            L.ToDetect.Text   = sprintf('%d', nToDetect);
            L.Sources.Text    = sprintf('%d', nSources);
            L.Detections.Text = CellDatasetManager.thousands(nDetections);
            L.Reviewed.Text   = sprintf('%d%%', pct);
            L.Curated.Text    = sprintf('%d/%d', nComplete, nSources);
            L.Kept.Text       = CellDatasetManager.thousands(nKept);
            L.Database.Text   = sprintf('%d/%d', nSent, nComplete);
        end

        function syncDatasetTableSelection(obj)
            % Show SelectedDatasetIndex as the table's selected row.
            try
                row = find(obj.View == obj.SelectedDatasetIndex, 1);
                if isempty(row)
                    obj.DatasetTable.Selection = [];
                else
                    obj.DatasetTable.Selection = row;
                    scroll(obj.DatasetTable, 'row', row);
                end
            catch
            end
        end

        function onDatasetSelected(obj, e)
            row = [];
            try
                row = e.Selection;
            catch
            end
            if isempty(row)
                return;
            end
            row = row(1);
            if row < 1 || row > numel(obj.View)
                return;
            end
            obj.SelectedDatasetIndex = obj.View(row);
            obj.SelectedSourceRow = 0;
            obj.refreshDetail();
        end

        function onDatasetDoubleClicked(obj, e)
            row = CellDatasetManager.clickedRow(e);
            if isempty(row) || row < 1 || row > numel(obj.View)
                return;
            end
            if obj.SelectedDatasetIndex ~= obj.View(row)
                obj.SelectedDatasetIndex = obj.View(row);
                obj.SelectedSourceRow = 0;
                obj.refreshDetail();
            end
            obj.openSelected();
        end

        function onSourceSelected(obj, e)
            row = [];
            try
                row = e.Selection;
            catch
            end
            if isempty(row)
                return;
            end
            obj.SelectedSourceRow = row(1);
            obj.styleSourceTable();
        end

        function onSourceDoubleClicked(obj, e)
            row = CellDatasetManager.clickedRow(e);
            d = obj.selectedDataset();
            if isempty(row) || isempty(d) || row < 1 || row > numel(d.Sources)
                return;
            end
            obj.SelectedSourceRow = row;
            obj.launch('curator');
        end

        function onKey(obj, e)
            % The window's keys (see handleKey). Enter is left to the table's
            % own handler, so that Enter in a text field only ends the edit.
            try
                if strcmp(e.Key, 'return')
                    return;
                end
                obj.handleKey(e.Key, e.Modifier);
            catch
            end
        end

        function onTableKey(obj, e)
            try
                if strcmp(e.Key, 'return')
                    obj.openSelected();
                end
            catch
            end
        end

        % ------------------------------------------------------------ the detail

        function refreshDetail(obj)
            % The selected dataset changed: its text, its sources, the buttons
            % that need one, and (a moment later, so that moving through the
            % list stays quick) its preview.
            idx = obj.SelectedDatasetIndex;
            hasSel = idx >= 1 && idx <= numel(obj.Datasets);
            obj.setLaunchEnabled(hasSel);
            obj.refreshDetailText();
            obj.refreshSourceTable();
            if hasSel
                obj.defer('preview', 0.12, @() obj.refreshPagePreview());
            else
                obj.cancelDeferred('preview');
                obj.refreshPagePreview();
            end
        end

        function refreshDetailText(obj)
            d = obj.selectedDataset();
            if isempty(d)
                obj.DetailLabel.Text = 'Select a dataset.';
                return;
            end
            p = CellDatasetManager.progressOf(d);
            lines = {d.Base};

            sec = d.Section;
            if sec.ok
                hemi = char(sec.Hemisphere);
                switch upper(hemi)
                    case 'L', hemi = 'left hemisphere';
                    case 'R', hemi = 'right hemisphere';
                    otherwise, hemi = ['hemisphere ' hemi];
                end
                if ~isempty(d.SubjectText)
                    who = sprintf('%s (lab database: %s)', d.SubjectID, d.SubjectText);
                elseif d.SubjectAsked
                    who = sprintf('%s (in the lab database)', d.SubjectID);
                elseif ~isempty(obj.CheckSubjectsButton)
                    who = sprintf('%s (not checked against the lab database: Check subjects)', d.SubjectID);
                else
                    who = d.SubjectID;
                end
                lines{end+1} = sprintf('Subject %s, section %s, %s, stain %s, plane %s, imaged %s', ...
                    who, char(sec.SectionID), hemi, char(sec.Stain), char(sec.ZPlane), char(sec.DateCode));
                if ~isempty(d.SubjectTags)
                    lines{end+1} = ['Tags (lab database): ' d.SubjectTags];
                end
                if ~isempty(d.SubjectVariables)
                    lines{end+1} = ['Variables (lab database): ' d.SubjectVariables];
                end
                if d.SubjectKnown && d.SubjectFactsRead && isempty(d.SubjectTags) && isempty(d.SubjectVariables)
                    lines{end+1} = 'No tags or variables on this subject in the lab database.';
                end
            end

            img = d.ActiveImage;
            if isempty(img), img = d.ImagePath; end
            if isempty(img)
                imgTxt = 'Image: (none)';
            else
                [~, nm, ext] = fileparts(img);
                imgTxt = sprintf('Image: %s%s', nm, ext);
                if d.PageCount > 0
                    imgTxt = sprintf('%s (%d page(s))', imgTxt, d.PageCount);
                end
            end
            lines{end+1} = imgTxt;
            lines{end+1} = sprintf('Folder: %s', d.Folder);

            st = sprintf('Status: %s', d.Status);
            if p.Cells > 0
                st = sprintf('%s. %s of %s cells reviewed (%d%%), %s kept, %d of %d source(s) complete', ...
                    st, CellDatasetManager.thousands(p.Reviewed), CellDatasetManager.thousands(p.Cells), ...
                    p.Pct, CellDatasetManager.thousands(p.Kept), p.Complete, p.Sources);
            end
            if ~isfile(d.ManifestPath)
                st = [st '. Manifest not written yet'];
            end
            lines{end+1} = [st '.'];
            obj.DetailLabel.Text = strjoin(lines, newline);
        end

        function refreshSourceTable(obj)
            d = obj.selectedDataset();
            if isempty(d)
                obj.SourceTable.Data = {};
                return;
            end
            ns = numel(d.Sources);
            data = cell(ns, numel(obj.SOURCE_COLUMNS));
            for i = 1:ns
                s = d.Sources(i);
                c = CellDatasetManager.sourceCounts(s);
                db = CellDatasetManager.dbOf(s);
                legacy = {};
                if s.Reviewed, legacy{end+1} = sprintf('QC file (%d reviewed)', s.QcReviewed); end %#ok<AGROW>
                if s.Resolved, legacy{end+1} = 'resolved'; end %#ok<AGROW>
                if isempty(legacy), legacy = {'-'}; end
                dbText = char(db.text);
                if isempty(dbText)
                    dbText = CellToolkit.ternary(s.CurComplete, 'not recorded', '-');
                elseif strlength(db.note) > 0
                    dbText = sprintf('%s: %s', dbText, char(db.note));   % why it waits for a person
                end
                data(i, :) = {char(CellDatasetManager.sourceLabel(s)), CellDatasetManager.pageText(s.Page), ...
                    s.NumDetections, CellDatasetManager.yn(s.Rescored), c.Reviewed, c.Good, c.Bad, ...
                    c.Kept, CellDatasetManager.yn(s.CurComplete), dbText, strjoin(legacy, ', ')};
            end
            obj.SourceTable.Data = data;
            obj.showSourceSelection();
        end

        function showSourceSelection(obj)
            % Make the selected source the table's selected row, and paint the
            % table (styleSourceTable marks that row itself: the table keeps a
            % selection set from code but does not always draw it, for one the
            % first time its rows are filled).
            if isempty(obj.SourceTable) || ~isvalid(obj.SourceTable)
                return;
            end
            row = obj.SelectedSourceRow;
            try
                if ~isempty(row) && row >= 1 && row <= size(obj.SourceTable.Data, 1)
                    obj.SourceTable.Selection = row;
                else
                    obj.SourceTable.Selection = [];
                end
            catch
            end
            obj.styleSourceTable();
        end

        function styleSourceTable(obj)
            % The source table's colors: the Database cell by the state of the
            % record, and the selected source's row on a light blue ground.
            d = obj.selectedDataset();
            try
                removeStyle(obj.SourceTable);
                if isempty(d)
                    return;
                end
                ns = min(numel(d.Sources), size(obj.SourceTable.Data, 1));
                dbCol = find(strcmp(obj.SOURCE_COLUMNS, 'Database'));
                for i = 1:ns
                    st = CellDatasetManager.dbOf(d.Sources(i)).state;
                    switch st
                        case "sent",             color = [0.10 0.50 0.20];
                        case "queued",           color = [0.75 0.45 0.00];
                        case {"held", "failed"}, color = [0.75 0.10 0.10];
                        otherwise,               color = [0.45 0.45 0.45];
                    end
                    CellDatasetManager.paintCells(obj.SourceTable, i, dbCol, color, 'normal');
                end
                row = obj.SelectedSourceRow;
                if ~isempty(row) && row >= 1 && row <= ns
                    addStyle(obj.SourceTable, uistyle('BackgroundColor', obj.SELECTED_ROW_COLOR), 'row', row);
                end
            catch
            end
        end

        function setLocationColorTooltip(obj)
            CellToolkit.setTooltip(obj.LocationColorDropDown, ...
                ['Uniform: one bright color per source.  By page: all sources ' ...
                 'on the same TIFF page share one color (matching the composite ' ...
                 'tints).  By rescore: color each cell by its latest Stage-2 ' ...
                 'rescore [0-1] on a turbo ramp (unscored cells in gray). Falls ' ...
                 'back to uniform for sources with no rescore column.  By class: ' ...
                 'color each cell by its label (Good, Bad, Uncertain; unreviewed ' ...
                 'cells in gray). Labels come from the source''s Cell Curator ' ...
                 'store when it has one, otherwise from its legacy QC file. Falls ' ...
                 'back to uniform for sources with neither. A legend shows each ' ...
                 'class. Check Cell locations to choose.']);
        end

        % ------------------------------------------------------------ the preview

        function refreshPagePreview(obj)
            % Preview the selected dataset's image in the right column, either
            % as one gray tile per page or as a single colorized composite of
            % all pages (the 'View' dropdown). Pages, composites and location
            % files come from a cache (CellDatasetManager.cached), so a dataset
            % seen before is drawn without reading its TIFF again; the path of
            % the image on screen is remembered so the same dataset is not
            % drawn twice.
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
                obj.clearPreview();
                obj.PagePanel.Title = 'TIFF pages';
                msg = CellToolkit.ternary(isempty(d), ...
                    'Select a dataset to preview its TIFF pages.', ...
                    'No image file for this dataset.');
                obj.previewMessage(msg);
                return;
            end

            % Same image already displayed in the current mode: keep it.
            % (Switching modes or overlay options, and a re-scan, clear this.)
            if strcmp(imgPath, obj.PreviewImagePath)
                return;
            end
            obj.PreviewImagePath = imgPath;

            obj.clearPreview();
            [~, nm, ext] = fileparts(imgPath);
            composite = strcmp(obj.PageViewDropDown.Value, 'Colorized composite');
            set(obj.Figure, 'Pointer', 'watch');
            try
                nPages = CellDatasetManager.pageCountOf(imgPath);
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
                obj.clearPreview();
                obj.previewMessage(['Could not display pages: ' ME.message]);
            end
            set(obj.Figure, 'Pointer', 'arrow');
        end

        function clearPreview(obj)
            % Empty the preview panel and forget its tiles (and their menus,
            % which belong to the figure).
            obj.PreviewDrag = [];
            for k = 1:numel(obj.Tiles)
                if ~isempty(obj.Tiles(k).Menu) && isvalid(obj.Tiles(k).Menu)
                    delete(obj.Tiles(k).Menu);
                end
            end
            obj.Tiles = obj.Tiles([]);
            delete(obj.PageContent.Children);
        end

        function previewMessage(obj, msg)
            % A line of text in the middle of the (empty) preview panel.
            g = uigridlayout(obj.PageContent, [1 1]);
            g.Padding = [20 20 20 20];
            uilabel(g, 'Text', msg, 'HorizontalAlignment', 'center', ...
                'VerticalAlignment', 'center', 'WordWrap', 'on', ...
                'FontColor', [0.4 0.4 0.4]);
        end

        function redrawPreview(obj)
            % Draw the preview again now (an option changed; the image did not).
            obj.cancelDeferred('preview');
            obj.PreviewImagePath = '';
            obj.refreshPagePreview();
        end

        function onPageViewChanged(obj)
            % Toggle between individual pages and colorized composite.
            obj.redrawPreview();
        end

        function onOverlayOptionChanged(obj)
            % React to the "Cell locations" checkbox / color dropdown: add,
            % remove or recolor the location overlay.
            obj.ShowLocations     = logical(obj.ShowLocationsCheckBox.Value);
            obj.LocationColorMode = char(obj.LocationColorDropDown.Value);
            if ~isempty(obj.LocationColorDropDown) && isvalid(obj.LocationColorDropDown)
                obj.LocationColorDropDown.Enable = ...
                    CellToolkit.ternary(obj.ShowLocations, 'on', 'off');
            end
            obj.redrawPreview();
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
            keyH = obj.overlayLocations(ax, page, false, ...
                CellDatasetManager.dispScale(pixUm, dispUm));
            barH = CellDatasetManager.drawScaleBar(ax, dispUm);
            if interactive
                obj.registerTile(ax, h, dispUm, keyH, barH, ...
                    @() obj.openImageFigure(imgPath, page, nPages, false, pixUm));
            end
        end

        function drawCompositeInto(obj, ax, imgPath, nPages, pixUm, maxDim, interactive)
            % Draw the colorized composite of all pages into ax, with a page
            % color key and a scale bar. When interactive, clicking opens the
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
            keyH = obj.overlayLocations(ax, 1, true, ...
                CellDatasetManager.dispScale(pixUm, dispUm));
            barH = CellDatasetManager.drawScaleBar(ax, dispUm);
            if interactive
                obj.registerTile(ax, h, dispUm, keyH, barH, ...
                    @() obj.openImageFigure(imgPath, 1, nPages, true, pixUm));
            end
        end

        % ------------------------------------------------------------ preview zoom and pan

        function registerTile(obj, ax, img, dispUm, keyH, barH, openFcn)
            % Make a preview tile answer the window's mouse (onPreview*): no
            % axes toolbar or built-in interactions, the image passes clicks
            % to its axes, and a right-click menu fits or opens the image.
            try ax.Toolbar = []; catch, end
            try disableDefaultInteractivity(ax); catch, end
            try ax.Interactions = []; catch, end
            img.HitTest = 'off';
            cm = uicontextmenu(obj.Figure);
            uimenu(cm, 'Text', 'Fit whole image', ...
                'MenuSelectedFcn', @(~, ~) obj.fitPreview());
            uimenu(cm, 'Text', 'Open in its own window', ...
                'MenuSelectedFcn', @(~, ~) openFcn());
            ax.ContextMenu = cm;
            k = numel(obj.Tiles) + 1;
            obj.Tiles(k).Axes    = ax;
            obj.Tiles(k).Full    = [ax.XLim ax.YLim];
            obj.Tiles(k).UmPerPx = dispUm;
            obj.Tiles(k).HasKey  = ~isempty(keyH);
            obj.Tiles(k).Decor   = [keyH(:); barH(:)];
            obj.Tiles(k).Menu    = cm;
            obj.Tiles(k).OpenFcn = openFcn;
        end

        function [k, p] = tileAt(obj, e)
            % The preview tile under the pointer and the image point there
            % (k = 0 when the pointer is not over an image). A test passes
            % the event as a struct with Tile and AxesPoint.
            k = 0;
            p = [NaN NaN];
            if isstruct(e) && isfield(e, 'Tile')
                if e.Tile >= 1 && e.Tile <= numel(obj.Tiles)
                    k = e.Tile;
                    p = double(e.AxesPoint(1, 1:2));
                end
                return;
            end
            if isempty(obj.Tiles) || ~isvalid(obj.PageContent)
                return;
            end
            fp = obj.Figure.CurrentPoint;
            pp = getpixelposition(obj.PageContent, true);
            if fp(1) < pp(1) || fp(1) > pp(1) + pp(3) || ...
                    fp(2) < pp(2) || fp(2) > pp(2) + pp(4)
                return;   % elsewhere in the window (the tables scroll on their own)
            end
            for i = 1:numel(obj.Tiles)
                ax = obj.Tiles(i).Axes;
                if ~isvalid(ax), continue; end
                cp = ax.CurrentPoint(1, 1:2);
                if cp(1) >= ax.XLim(1) && cp(1) <= ax.XLim(2) && ...
                        cp(2) >= ax.YLim(1) && cp(2) <= ax.YLim(2)
                    k = i;
                    p = cp;
                    return;
                end
            end
        end

        function onPreviewScroll(obj, e)
            % The wheel over a preview tile zooms about the pointer (wheel up
            % zooms in).
            try
                [k, p] = obj.tileAt(e);
                if k == 0, return; end
                n = double(e.VerticalScrollCount);
                if n == 0 || ~isfinite(n), return; end
                obj.zoomPreview(k, n, p);
                if ~isempty(obj.PreviewDrag) && obj.PreviewDrag.Tile == k
                    % a pan goes on from the new view
                    obj.PreviewDrag.P0 = p;
                    obj.PreviewDrag.L0 = obj.previewLimits(k);
                end
            catch
            end
        end

        function onPreviewPress(obj, e)
            % A press on a preview tile starts a pan; a double-click opens
            % the tile in its own window (a right-click shows its menu).
            try
                obj.PreviewDrag = [];
                [k, p] = obj.tileAt(e);
                if k == 0, return; end
                if isstruct(e) && isfield(e, 'SelectionType')
                    st = char(e.SelectionType);
                else
                    st = obj.Figure.SelectionType;
                end
                switch st
                    case 'normal'
                        obj.PreviewDrag = struct('Tile', k, 'P0', p, ...
                            'L0', obj.previewLimits(k));
                    case 'open'
                        fcn = obj.Tiles(k).OpenFcn;
                        if ~isempty(fcn), fcn(); end
                end
            catch
            end
        end

        function onPreviewMotion(obj, e)
            % During a pan, keep the image point pressed under the pointer.
            D = obj.PreviewDrag;
            if isempty(D), return; end
            try
                k = D.Tile;
                if k > numel(obj.Tiles) || ~isvalid(obj.Tiles(k).Axes)
                    obj.PreviewDrag = [];
                    return;
                end
                if isstruct(e) && isfield(e, 'AxesPoint')
                    cp = double(e.AxesPoint(1, 1:2));
                else
                    cp = obj.Tiles(k).Axes.CurrentPoint(1, 1:2);
                end
                L = obj.previewLimits(k);
                % the pointer in the view the pan started from (same span)
                cp0 = cp - [L(1) - D.L0(1), L(3) - D.L0(3)];
                d = cp0 - D.P0;
                if ~any(d), return; end
                set(obj.Figure, 'Pointer', 'fleur');
                obj.setPreviewView(k, D.L0(1:2) - d(1), D.L0(3:4) - d(2));
                drawnow limitrate;
            catch
                obj.PreviewDrag = [];
            end
        end

        function onPreviewRelease(obj, ~)
            if isempty(obj.PreviewDrag), return; end
            obj.PreviewDrag = [];
            try
                set(obj.Figure, 'Pointer', 'arrow');
            catch
            end
        end

        function setPreviewView(obj, k, xl, yl)
            % Show limits xl, yl in tile k, kept inside the image, and the
            % same view in every tile of the same image size (the pages of
            % a TIFF zoom together). The scale bar and the rescore key move
            % with a pan and are drawn again after a zoom.
            F = obj.Tiles(k).Full;
            xl = CellDatasetManager.clampSpan(xl, F(1:2));
            yl = CellDatasetManager.clampSpan(yl, F(3:4));
            for i = 1:numel(obj.Tiles)
                T = obj.Tiles(i);
                if ~isequal(T.Full, F) || ~isvalid(T.Axes), continue; end
                ax = T.Axes;
                old = [ax.XLim ax.YLim];
                if isequal(old, [xl yl]), continue; end
                set(ax, 'XLim', xl, 'YLim', yl);
                if abs(diff(xl) - diff(old(1:2))) < 1e-9 * diff(F(1:2)) && ...
                        abs(diff(yl) - diff(old(3:4))) < 1e-9 * diff(F(3:4))
                    CellDatasetManager.shiftDecor(T.Decor, [xl(1) - old(1), yl(1) - old(3)]);
                else
                    delete(T.Decor(isgraphics(T.Decor)));
                    dec = CellDatasetManager.drawScaleBar(ax, T.UmPerPx);
                    if T.HasKey
                        dec = [CellDatasetManager.drawRescoreColorbar(ax); dec]; %#ok<AGROW>
                    end
                    obj.Tiles(i).Decor = dec;
                end
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

        function keyH = overlayLocations(obj, ax, page, isComposite, scale)
            % Overlay detected cell centers on a preview axes. In composite mode
            % every source is drawn; otherwise only the source(s) belonging to
            % `page`. `scale` maps full-resolution CSV coordinates onto the
            % displayed (subsampled) image: displayed = full * scale. Color is
            % a single bright tint per source ('Uniform'), each cell's latest
            % Stage-2 rescore on a turbo ramp ('By rescore'), or each cell's
            % QC classification read from that source's QC file ('By class';
            % legend shows each class, unreviewed cells in gray). Each cell is
            % a filled circle. keyH: the rescore key, drawn in data units
            % (empty when there is none).
            keyH = gobjects(0, 1);
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

            % Pre-compute page color palette when in By page mode.
            pageClrs = [];
            if byPage
                nPages   = max(1, d.PageCount);
                pageClrs = CellDatasetManager.pageColors(nPages);
            end

            % For by-class: pre-read every source's QC file (class labels
            % live there, not in the detection/rescore CSV) to build a
            % consistent label palette before drawing (same label -> same
            % color across sources). "Unreviewed" is always drawn gray and
            % listed last, matching the neutral-gray convention used for
            % unscored cells in 'By rescore'.
            allPts = cell(numel(srcs), 1);
            if byClass
                allLabels = strings(0, 1);
                for i = 1:numel(srcs)
                    allPts{i} = CellDatasetManager.readClassPoints(srcs(i));
                    if allPts{i}.hasClass
                        allLabels = [allLabels; allPts{i}.label(:)]; %#ok<AGROW>
                    end
                end
                uniqueClasses = unique(allLabels);
                uniqueClasses = [uniqueClasses(uniqueClasses ~= "Unreviewed"); ...
                                  uniqueClasses(uniqueClasses == "Unreviewed")];
                classPalette  = CellDatasetManager.classColors( ...
                    sum(uniqueClasses ~= "Unreviewed"));
            end

            for i = 1:numel(srcs)
                s     = srcs(i);
                qcPts = struct('hasClass', false);
                if byClass
                    qcPts = allPts{i};
                end
                if byClass && qcPts.hasClass
                    pts = qcPts;
                else
                    csv = CellDatasetManager.overlayCsvFor(d, s);
                    pts = CellDatasetManager.readLocPoints(csv);
                end
                if isempty(pts.x)
                    continue;
                end
                x = pts.x * scale;
                y = pts.y * scale;
                if byClass && qcPts.hasClass
                    for ci = 1:numel(uniqueClasses)
                        lbl  = uniqueClasses(ci);
                        mask = pts.label == lbl;
                        if ~any(mask), continue; end
                        if lbl == "Unreviewed"
                            c = [0.6 0.6 0.6];
                        else
                            c = classPalette(ci, :);
                        end
                        h = CellDatasetManager.plotLocations(ax, x(mask), y(mask), c);
                        lblChar = char(lbl);
                        if ~any(strcmp(legendLabels, lblChar))
                            legendHandles(end + 1) = h; %#ok<AGROW>
                            legendLabels{end + 1}  = lblChar; %#ok<AGROW>
                        end
                    end
                elseif byClass
                    % No QC file yet for this source: fall back to uniform tint
                    c = palette(mod(i - 1, size(palette, 1)) + 1, :);
                    CellDatasetManager.plotLocations(ax, x, y, c);
                elseif byRescore && pts.hasRescore
                    rgb = CellDatasetManager.rescoreColors(pts.rescore);
                    CellDatasetManager.plotLocations(ax, x, y, rgb);
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
                    h   = CellDatasetManager.plotLocations(ax, x, y, c);
                    lbl = sprintf('Page %d', pageNum);
                    if isfinite(pageNum) && ~any(strcmp(legendLabels, lbl))
                        legendHandles(end + 1) = h; %#ok<AGROW>
                        legendLabels{end + 1}  = lbl; %#ok<AGROW>
                    end
                else
                    c = palette(mod(i - 1, size(palette, 1)) + 1, :);
                    h = CellDatasetManager.plotLocations(ax, x, y, c);
                    if numel(srcs) > 1
                        legendHandles(end + 1) = h; %#ok<AGROW>
                        legendLabels{end + 1}  = char(CellDatasetManager.sourceLabel(s)); %#ok<AGROW>
                    end
                end
            end

            if byRescore && anyRescore
                keyH = CellDatasetManager.drawRescoreColorbar(ax);
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

        % ------------------------------------------------------------ selected-dataset actions

        function setLaunchEnabled(obj, tf)
            % Detect and Curate are always enabled (they fall back to the
            % parent directory when no dataset is selected). "Open manifest",
            % "Set active locs" and "Set active image" need a selected dataset;
            % their tooltips say so while they are disabled.
            tf = logical(tf);
            if isequal(obj.LaunchEnabled, tf)
                return;                       % as it is: nothing to send to the window
            end
            obj.LaunchEnabled = tf;
            en = CellToolkit.ternary(tf, 'on', 'off');
            need = CellToolkit.ternary(tf, '', ' Disabled: select a dataset first.');
            if ~isempty(obj.OpenManifestButton) && isvalid(obj.OpenManifestButton)
                obj.OpenManifestButton.Enable = en;
                CellToolkit.setTooltip(obj.OpenManifestButton, ...
                    ['Open the selected dataset''s manifest file (<base>.celldataset.json), ' ...
                     'which records its files and which pipeline stages have run.' need]);
            end
            if ~isempty(obj.SetActiveLocsButton) && isvalid(obj.SetActiveLocsButton)
                obj.SetActiveLocsButton.Enable = en;
                CellToolkit.setTooltip(obj.SetActiveLocsButton, ...
                    ['Choose which localization CSV is the active analysis file for the ' ...
                     'selected source. Cell Discovery, the exports and this window read the ' ...
                     'file recorded here (CellDatasetManifest.activeLocs); Cell Curator ' ...
                     'always reads the detector''s own _locs file.' need]);
            end
            if ~isempty(obj.SetActiveImageButton) && isvalid(obj.SetActiveImageButton)
                obj.SetActiveImageButton.Enable = en;
                CellToolkit.setTooltip(obj.SetActiveImageButton, ...
                    ['Choose which image file is the active analysis image for the ' ...
                     'selected dataset. Disambiguates multi-variant datasets (raw, ' ...
                     'projection, resized) and is recorded in the manifest so every ' ...
                     'Cell* tool opens the same image (CellDatasetManifest.activeImage).' need]);
            end
        end

        function onSetActiveLocs(obj)
            % Re-point which localization CSV is the active analysis file for a
            % source (the user-facing override). Writes through the dataset's
            % live CellDatasetManifest so every other tool honors the choice.
            d = obj.selectedDataset();
            if isempty(d), return; end
            if ~isfield(d, 'ManifestObj') || isempty(d.ManifestObj) || ~isvalid(d.ManifestObj)
                uialert(obj.Figure, 'No manifest is available for this dataset.', ...
                    'Active locs');
                return;
            end
            srcs = d.Sources;
            if isempty(srcs)
                uialert(obj.Figure, ...
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
                obj.setStatus(sprintf('Active locs for %s -> %s', ...
                    key, chosen));
            else
                obj.setStatus('Could not write the manifest.');
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
                uialert(obj.Figure, 'No manifest is available for this dataset.', ...
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
                obj.setStatus(sprintf('Active image for "%s" -> %s', ...
                    d.Base, chosen));
            else
                obj.setStatus('Could not write the manifest.');
            end
            obj.rescan(true);
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
                uialert(obj.Figure, 'No manifest has been written for this dataset yet.', ...
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

        % ------------------------------------------------------------ settings

        function loadPreferences(obj)
            % Load the saved window settings (figure position, parent
            % directory, filter, page view mode, overlay options). The
            % localization-CSV suffix is CellDatasetManifest's, shared by all
            % the Cell* tools, and is shown whatever UseSettings says.
            group = 'CellDatasetManager';
            if ~isempty(obj.LocsTokenEdit) && isvalid(obj.LocsTokenEdit)
                obj.LocsTokenEdit.Value = CellDatasetManifest.locsToken();
            end
            if ~obj.UseSettings
                return;
            end

            % Restore figure position and size
            if ispref(group, 'figurePosition')
                try
                    pos = getpref(group, 'figurePosition');
                    if isvector(pos) && numel(pos) == 4 && all(isfinite(pos)) && all(pos > 0)
                        obj.Figure.Position = pos;
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

            % Restore the Show item (the Find text starts empty)
            if ispref(group, 'filterShow')
                try
                    show = char(getpref(group, 'filterShow'));
                    if any(strcmp(obj.SHOW_ITEMS, show))
                        obj.FilterShow = show;
                        obj.ShowDropDown.Value = show;
                    end
                catch
                end
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
            % Save the window settings (see loadPreferences).
            if ~obj.UseSettings
                return;
            end
            group = 'CellDatasetManager';
            try
                setpref(group, 'figurePosition', obj.Figure.Position);
            catch
            end
            try
                setpref(group, 'parentDirectory', char(obj.ParentDirEdit.Value));
            catch
            end
            try
                setpref(group, 'filterShow', char(obj.FilterShow));
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
            % The window is closing: stop what is deferred, stop listening to
            % the lab database, save the settings and delete the figure.
            obj.cancelAllDeferred();
            obj.dropDatabaseListeners();
            obj.savePreferences();
            delete(obj.Figure);
        end

    end

    methods (Static, Access = private)

        function lbl = makeStat(parent, caption, tip)
            % One "stat card": a bold value over a small gray caption. Returns
            % the value label so refreshSummary() can update its text.
            cellGrid = uigridlayout(parent, [2 1]);
            cellGrid.RowHeight = {'fit', 'fit'};
            cellGrid.RowSpacing = 0;
            cellGrid.Padding = [0 0 0 0];
            lbl = uilabel(cellGrid, 'Text', '-', 'FontSize', 16, ...
                'FontWeight', 'bold', 'HorizontalAlignment', 'center', 'Tooltip', tip);
            uilabel(cellGrid, 'Text', caption, 'FontSize', 10, ...
                'FontColor', [0.4 0.4 0.4], 'HorizontalAlignment', 'center', 'Tooltip', tip);
        end

        function paintCells(tbl, rows, col, color, weight)
            % Font color and weight of the cells (ROWS, COL) of a uitable; ROWS
            % are indices or a logical mask.
            if islogical(rows)
                rows = find(rows);
            end
            if isempty(rows) || isempty(col)
                return;
            end
            rows = rows(:);
            addStyle(tbl, uistyle('FontColor', color, 'FontWeight', weight), ...
                'cell', [rows, repmat(col, numel(rows), 1)]);
        end

        function st = worstDbState(sources)
            % The lab database state of a dataset that most needs a person:
            % held or failed, then queued, local, sent, discarded; "none" when
            % no source has a record.
            st = "none";
            order = ["held", "failed", "queued", "local", "sent", "discarded"];
            states = strings(1, numel(sources));
            for i = 1:numel(sources)
                states(i) = CellDatasetManager.dbOf(sources(i)).state;
            end
            for o = order
                if any(states == o)
                    st = o;
                    return;
                end
            end
        end

        function row = clickedRow(e)
            % The data row of a table double-click ([] for a header or blank space).
            row = [];
            try
                row = e.InteractionInformation.Row;
            catch
            end
            if ~isempty(row)
                row = row(1);
            end
        end

        function n = pageCountOf(imgPath)
            % Number of pages of a TIFF (cached: imfinfo is the costly call).
            n = CellDatasetManager.cached(CellDatasetManager.fileKey(imgPath, 'pages'), ...
                @() CellToolkit.countPages(imgPath));
        end

        function um = pixelSizeUm(imgPath)
            % Micrometers-per-pixel from a TIFF's resolution tags (cached),
            % falling back to DEFAULT_UM_PER_PIXEL when the file carries no
            % physical scale. Reads ImageJ ("unit=micron") as well as plain
            % TIFF calibration.
            um = CellDatasetManager.cached(CellDatasetManager.fileKey(imgPath, 'um'), ...
                @() CellToolkit.tiffPixelSizeUm(imgPath, 1));
            if ~isfinite(um)
                um = CellDatasetManager.DEFAULT_UM_PER_PIXEL;
            end
        end

        function [img, dispUm] = loadPageForDisplay(imgPath, page, nPages, pixUm, maxDim)
            % A page subsampled to <= maxDim on its longest side, from the
            % cache when this file's page was shown before.
            v = CellDatasetManager.cached( ...
                CellDatasetManager.fileKey(imgPath, sprintf('page%d/%d@%d@%g', page, nPages, maxDim, pixUm)), ...
                @() CellDatasetManager.packPage(imgPath, page, nPages, pixUm, maxDim));
            img = v.img;
            dispUm = v.dispUm;
        end

        function v = packPage(imgPath, page, nPages, pixUm, maxDim)
            [v.img, v.dispUm] = CellDatasetManager.loadPageUncached(imgPath, page, nPages, pixUm, maxDim);
        end

        function [rgb, used, dispUm, colors] = buildComposite(imgPath, nPages, pixUm, maxDim)
            % The color composite of every page, from the cache when this
            % file's composite was shown before.
            v = CellDatasetManager.cached( ...
                CellDatasetManager.fileKey(imgPath, sprintf('composite%d@%d@%g', nPages, maxDim, pixUm)), ...
                @() CellDatasetManager.packComposite(imgPath, nPages, pixUm, maxDim));
            rgb = v.rgb; used = v.used; dispUm = v.dispUm; colors = v.colors;
        end

        function v = packComposite(imgPath, nPages, pixUm, maxDim)
            [v.rgb, v.used, v.dispUm, v.colors] = ...
                CellDatasetManager.buildCompositeUncached(imgPath, nPages, pixUm, maxDim);
            if ~isempty(v.rgb)
                v.rgb = im2uint8(v.rgb);   % an eighth of the memory, the same picture
            end
        end

        function pts = readLocPoints(csvPath)
            % Cell centers (and rescores) of a localization CSV, from the cache
            % while the file is unchanged.
            csvPath = char(csvPath);
            pts = CellDatasetManager.cached(CellDatasetManager.fileKey(csvPath, 'locs'), ...
                @() CellDatasetManager.readLocPointsUncached(csvPath));
        end

        function pts = readCurationPoints(curationCsv)
            % Cell centers and labels of a Cell Curator snapshot, from the cache
            % while the file is unchanged.
            curationCsv = char(curationCsv);
            pts = CellDatasetManager.cached(CellDatasetManager.fileKey(curationCsv, 'curation'), ...
                @() CellDatasetManager.readCurationPointsUncached(curationCsv));
        end

        function pts = readQcPoints(qcPath)
            % Cell centers and labels of a legacy QC file, from the cache while
            % the file is unchanged.
            qcPath = char(qcPath);
            pts = CellDatasetManager.cached(CellDatasetManager.fileKey(qcPath, 'qc'), ...
                @() CellDatasetManager.readQcPointsUncached(qcPath));
        end

        function s = thousands(n)
            % Integer with thousands separators (e.g. 15432 -> "15,432").
            s = sprintf('%d', round(n));
            try
                s = regexprep(s, '\d{1,3}(?=(\d{3})+$)', '$0,');
            catch
            end
        end

        function [img, dispUm] = loadPageUncached(imgPath, page, nPages, pixUm, maxDim)
            % Read a page and subsample it to <= maxDim on its longest side.
            % dispUm is the micrometers-per-pixel of the returned (subsampled)
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

        function [rgb, used, dispUm, colors] = buildCompositeUncached(imgPath, nPages, pixUm, maxDim)
            % Merge every page into one additive-color RGB image (each page
            % min-max stretched, mismatched sizes resized to the first, longest
            % side bounded to maxDim). Returns which pages contributed, the
            % displayed micrometers-per-pixel, and the per-page colors.
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
                    g = mean(double(g), 3);   % collapse a color page to gray
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

        function h = plotLocations(ax, x, y, c)
            % Cell locations as filled circles of one color (c 1x3) or one
            % color per cell (c Nx3); they never take a click.
            h = scatter(ax, x, y, CellDatasetManager.LOCATION_MARKER_SIZE, c, ...
                'o', 'filled', 'HitTest', 'off', 'PickableParts', 'none');
        end

        function lim = clampSpan(lim, full)
            % Limits `lim` moved to lie inside `full`; the whole of `full` when
            % lim is as wide or wider.
            span = diff(lim);
            if ~all(isfinite(lim)) || span >= diff(full) || span <= 0
                lim = full;
            elseif lim(1) < full(1)
                lim = full(1) + [0 span];
            elseif lim(2) > full(2)
                lim = full(2) - [span 0];
            end
        end

        function shiftDecor(h, d)
            % Move what drawScaleBar / drawRescoreColorbar drew by d = [dx dy]
            % data units (a pan: the view moved, its span did not).
            for i = 1:numel(h)
                if ~isgraphics(h(i)), continue; end
                pos = h(i).Position;
                pos(1:2) = pos(1:2) + d;
                h(i).Position = pos;
            end
        end

        function h = drawScaleBar(ax, umPerPixel)
            % Draw a scale bar in the bottom-right of ax, sized to a "nice" round
            % length, given the micrometers-per-pixel of the displayed image.
            % No-op when the scale is unknown or the image is too small.
            % h: what was drawn (to move or redraw with the view).
            h = gobjects(0, 1);
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
            h(1, 1) = rectangle(ax, 'Position', [x1, yB - thick, barPx, thick], ...
                'FaceColor', 'w', 'EdgeColor', 'k', 'LineWidth', 0.5, 'HitTest', 'off');
            h(2, 1) = text(ax, (x1 + x2) / 2, yB - thick - 0.01 * H, sprintf('%g \\mum', barUm), ...
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

        function pts = readLocPointsUncached(csvPath)
            % Read cell centers from a localization CSV. Returns a struct with
            % column vectors x, y (NaN rows dropped) and the matching rescore
            % (when present) plus hasRescore. Accepts X/Y or the resized
            % Xp/Yp naming.
            pts = struct('x', [], 'y', [], 'rescore', [], 'hasRescore', false);
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
        end

        function pts = readClassPoints(src)
            % Class-labeled points of a source for the "By class" overlay:
            % the CellCurator curation store when the source has one, else the
            % legacy *_QC.csv.
            pts = struct('x', [], 'y', [], 'label', strings(0, 1), 'hasClass', false);
            if isfield(src, 'CurationPath')
                pts = CellDatasetManager.readCurationPoints(src.CurationPath);
            end
            if ~pts.hasClass
                pts = CellDatasetManager.readQcPoints(src.QcPath);
            end
        end

        function pts = readCurationPointsUncached(curationCsv)
            % Read cell centers and labels from a CellCurator store snapshot
            % ("<stem>_curation.csv", written by curation.Store). Only active
            % rows are returned (merged duplicates and stale rows are not
            % cells). Unlabeled rows read as "Unreviewed"; rows the assist
            % model rejected without review read as "Auto-rejected". Same
            % output shape as readQcPoints.
            pts = struct('x', [], 'y', [], 'label', strings(0, 1), 'hasClass', false);
            curationCsv = char(curationCsv);
            if isempty(curationCsv) || ~isfile(curationCsv)
                return;
            end
            try
                tbl = readtable(curationCsv, 'TextType', 'string', ...
                    'VariableNamingRule', 'preserve');
            catch
                return;
            end
            names = string(tbl.Properties.VariableNames);
            if ~all(ismember(["X", "Y", "Label"], names)) || height(tbl) == 0
                return;
            end
            % An all-empty text column is read as NaN doubles: normalize.
            txt = @(v) fillmissing(string(v), 'constant', "");
            x = double(tbl.X);
            y = double(tbl.Y);
            label = txt(tbl.Label);
            keep = isfinite(x) & isfinite(y);
            if ismember("State", names)
                keep = keep & txt(tbl.State) == "active";
            end
            if ismember("LabelSource", names)
                label(label == "Bad" & txt(tbl.LabelSource) == "auto") = "Auto-rejected";
            end
            label(strlength(label) == 0) = "Unreviewed";
            pts.x        = x(keep);
            pts.y        = y(keep);
            pts.label    = label(keep);
            pts.hasClass = true;
        end

        function pts = readQcPointsUncached(qcPath)
            % Read cell centers and QC classification labels from a
            % *_QC.csv (written by the removed CellQualityControl app). QC labels live in
            % that separate file, not in the detection/rescore CSV that
            % CsvPath points to, so this reads QcPath directly rather than
            % going through readLocPoints/overlayCsvFor. Returns column
            % vectors x, y (NaN rows dropped), label (string per point;
            % unreviewed rows read as "Unreviewed"), and hasClass (true
            % when the file exists and has a QCLabel column).
            pts = struct('x', [], 'y', [], 'label', strings(0, 1), 'hasClass', false);
            qcPath = char(qcPath);
            if isempty(qcPath) || ~isfile(qcPath)
                return;
            end
            try
                tbl = readtable(qcPath, 'TextType', 'string', ...
                    'VariableNamingRule', 'preserve');
            catch
                return;
            end
            names = string(tbl.Properties.VariableNames);
            [x, okx] = CellDatasetManager.pickColumn(tbl, names, {'X', 'Xp'});
            [y, oky] = CellDatasetManager.pickColumn(tbl, names, {'Y', 'Yp'});
            if ~okx || ~oky || ~ismember("QCLabel", names)
                return;
            end
            keep  = isfinite(x) & isfinite(y);
            label = string(tbl.QCLabel(keep));
            label(ismissing(label) | strlength(label) == 0) = "Unreviewed";
            pts.x        = x(keep);
            pts.y        = y(keep);
            pts.label    = label;
            pts.hasClass = true;
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
            % Distinct colors for cell class labels. Ordered so class 0 gets
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
                0.80 0.80 0.80];  % light gray
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
            % (non-finite) cells are drawn neutral gray so they read as
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

        function h = drawRescoreColorbar(ax)
            % Compact vertical rescore key (0 bottom -> 1 top) in data
            % coordinates at the top-right, clear of the bottom-right scale bar.
            % Mirrors drawScaleBar's HitTest-off, dark-backed styling.
            % h: what was drawn (to move or redraw with the view).
            h = gobjects(0, 1);
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
                h(end + 1, 1) = rectangle(ax, 'Position', [x1, yk, barW, segH + 0.5], ...
                    'FaceColor', c, 'EdgeColor', 'none', 'HitTest', 'off');
            end
            h(end + 1, 1) = rectangle(ax, 'Position', [x1, yTop, barW, barH], ...
                'FaceColor', 'none', 'EdgeColor', 'w', 'LineWidth', 0.5, ...
                'HitTest', 'off');
            ticks = {'1', '0.5', '0'};
            fracs = [0, 0.5, 1];
            for k = 1:numel(ticks)
                yk = yTop + fracs(k) * barH;
                h(end + 1, 1) = text(ax, x1 - 0.005 * W, yk, ticks{k}, 'Color', 'w', ...
                    'HorizontalAlignment', 'right', 'VerticalAlignment', 'middle', ...
                    'FontSize', 8, 'FontWeight', 'bold', ...
                    'BackgroundColor', [0 0 0], 'Margin', 1, 'HitTest', 'off');
            end
            h(end + 1, 1) = text(ax, x1 + barW / 2, yTop - 0.015 * H, 'rescore', 'Color', 'w', ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
                'FontSize', 8, 'FontWeight', 'bold', ...
                'BackgroundColor', [0 0 0], 'Margin', 1, 'HitTest', 'off');
        end

        function colors = pageColors(n)
            % Distinct additive tints per page: white for a single page,
            % magenta/green for two, RGB for three, a six-color set beyond,
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
