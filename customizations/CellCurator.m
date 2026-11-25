classdef CellCurator < handle
%CELLCURATOR  Review cell detections by exception: glance at a page of crop tiles, mark the few
%   that differ from the page's proposed label, confirm the rest with one key.
%
%   app = CellCurator()                    builds the window; opens nothing by itself
%   app = CellCurator(parentDir)           the same, then app.openParent(parentDir)
%   app = CellCurator(..., Name, Value)    options:
%       Visible        'on' (default) | 'off'
%       UseSettings    true (default): read and write the persisted settings (last folder, window
%                      position, display mode, gain, gamma, zoom, last dataset and source, the
%                      map markers);
%                      false: neither (tests)
%       PrepareNext    true (default): when idle, prepare the next source that has work (its
%                      images and crops) so moving on is immediate
%       AutosaveDelay  2 (s): the store's snapshot debounce (every change is journaled at once)
%       PrepareMap     true (default): create the (hidden) map once the person pauses with a source
%                      on screen, so the first Tab only loads it
%       WarmUp         true (default): while the empty window waits (no folder given), run the
%                      code of a source opening once on a tiny dataset in a temporary folder, so the
%                      first real source opens as fast as the next ones (once per MATLAB session)
%       Assist         true (default): the assist model of the folder (curation.AssistRunner: the
%                      project read, models fitted and predictions made in the background), the blind
%                      holdout (curation.BlindTiles) and the audit report. false: proposals stay the
%                      cold start and no holdout is chosen or applied
%       ConfirmAudit   true (default): when a source's ordinary review queue becomes empty, 2% of
%                      its tiles confirmed by default (at least 5) come back as blind audit tiles
%       AssistOptions  struct passed to curation.AssistRunner (tests: RefreshSec, MinNewLabels, ...)
%       RescoreOptions struct passed to curation.RescoreRunner (tests: RunFcn, PythonCheck, Model)
%       TrainingOptions struct passed to curation.TrainingPanel (tests: ChooseFolderFcn,
%                      ChooseFileFcn, TrainerOptions, ExportOptions, PythonOk)
%       MinPageSec     0.3: a page (or close pair, or sweep field) must be on screen this long
%                      before Enter/Space from the keyboard confirms it, and the key must have
%                      been released since the last confirm (a held key repeats ~30/s)
%
%   app.openParent(parentDir, datasetBase, sourceKey)   open a folder of sections (last two
%                                         optional: which section and channel to show first)
%   app.openSource(locsCsvPath)          open one source directly (its folder is scanned too)
%   app.addCloseListener(fcn)            fcn() when the window is destroyed
%   app.close()                          save, record to the manifests, release every lock and timer
%
%   Review by exception: each page of the Review queue holds cells of one P(Good) band and has one
%   default label (Good or Bad). Untouched tiles wear a muted border in the default's color;
%   tiles you decide wear a full-strength border in their label's color; a corner badge marks a
%   flag. Click = toggle a tile to the opposite of the default (the exception), again = back to
%   untouched; right-click = Uncertain; drag = paint the same change; keys g/b/u/f/x act on the
%   tile under the pointer, else the cursor tile (or on every selected tile, Shift+click). Enter
%   (or Space) labels every untouched tile with the default (LabelSource "confirmed") in one
%   transaction and shows the next page at once. Every decision goes to the curation store
%   immediately. The context line above the gallery always says what Enter will do.
%   [?] shows every key; curation.UiText holds every word the window shows.
%
%   Audit (blind) tiles: rows whose AuditRole is holdout or confirm-audit and that were not decided
%   blind yet (curation.Queues: BLIND TILES) are mixed into the review pages, and fill pages of their
%   own ("Blind tiles"). They wear a neutral gray border, the inspector hides their scores and P, the
%   page default never applies to them, and a left click only puts the cursor on them: g, b or u (or
%   a label button; a right-click is Uncertain) decides one, with LabelSource "blind". Enter applies
%   the default to the ordinary untouched tiles and keeps the page while an audit tile on it is
%   undecided (the cursor goes to it; the context line says how many). The holdout (per channel kind,
%   chosen once per folder: .cellcuration\holdout_<kind>.csv) is applied to a source when it opens;
%   the confirm audit is drawn once per source, in the transaction of the Enter that empties its
%   ordinary queue (part of that Enter's transaction: undoing the Enter removes them with it). The
%   holdout, and a confirm audit drawn between pages, use the store's system form (not undo steps:
%   Ctrl+Z always undoes the reviewer's own last action); after an undo, a confirm-audit row whose
%   confirmed label is gone loses its role (system form). Labels of audit cells on the map are
%   written blind only one cell at a time. Writes the app makes on its own (roles, predictions,
%   scores) wait while a batch is open (a tile drag) and for IdleDelay after the last input.
%
%   Assist (left panel; curation.AssistRunner, all of it off the key path): what the proposals come
%   from (the cold start until the model's label gate, then "model N"), the model's out-of-fold AUC
%   next to the rescore baseline, and the agreement of the proposal with blind decisions. New
%   predictions are applied in idle time: the page on screen keeps its tiles and default; the pages
%   after it follow the model (ties ordered by its raw score). "Audit report..." builds
%   curation.Audit.report of the folder in the background and shows it in the Audit tab, where
%   "Save report" writes .cellcuration\audit_report_<date>.txt and .csv.
%
%   Map (Tab or v, or the Map view button): the whole section in the center, one point per cell
%   colored by its state (excluded cells dimmed; merged and stale rows not drawn), with the
%   exclusion regions and the reference ROI strip (<image stem>_roi.roi beside the image, drawn
%   only). Tools: Select [s], Add [a], Move [m], Lasso [l] (Esc: back to Select); Shift held as a
%   moved cell is dropped (or Shift+click with Add) snaps it to its center with snapToCellCentroid
%   (Shift is pressed after the press: a Shift+press selects). g/b/u/f/x act on the selected
%   points; Enter or a double-click shows the selected cell in the gallery; [.] in the gallery
%   shows the pointed-at cell on the map. A lasso offers Good/Bad/Uncertain, Exclude region [e]
%   (store.addRegion of an image-scope exclusion region; the store keeps Excluded equal to
%   "inside an exclude region" itself, in both channels; the window re-reads the regions when a
%   source comes on screen and redraws) and Merge into one [j]. The Close pairs queue steps
%   through curation.Pairs clusters of the kept cells, plus the new detections a reconcile found
%   next to reviewed cells (proposal: merge into the reviewed cell), on the map (Enter: the
%   proposal, k keep both, j merge, arrows skip/back); the Sweep queue steps through
%   MapView.sweepRects fields with the Add tool (Space next, Backspace previous; the field reached
%   is kept per source for the session). The right panel's Map tab is a small locator of the
%   section (updated only while it is showing). The points' markers (a color and a symbol per
%   state: to review, Good, Bad, Uncertain, flagged; curation.MapMarkers; default: open circles in
%   the label colors, cells to review as filled blue squares) are chosen in Markers... on the map's
%   tool bar (curation.MarkerDialog) and kept in the settings. When the Review queue is empty the center shows
%   the finish checklist; "Mark source complete [Enter]" sets Complete, writes <stem>_final.csv
%   and records the manifest; a later edit that leaves cells to review or flagged undoes it in the
%   same transaction.
%
%   Display: the crops keep each page's fixed limits (one contrast per page, never per tile); the
%   default brightness and gamma of a source come from its cells' crops (curation.DisplayDefaults:
%   99.5th percentile of the crop pixels, gamma 0.8), and [ ] ; ' (and the sliders) act relative to
%   them; [0] resets. The map and the locator use the same mapping. Even tiles [t] (a state button,
%   kept in the settings) scales each tile so its cell's center shows at the source's typical
%   cell level (curation.CropCache TileLevel: factor 1/3-3, before brightness and gamma); tiles and
%   inspector only, the map keeps the page contrast.
%
%   Rescore: cells a person added or moved have no Stage-2 score for their position. "Score
%   edited cells" (left) and the finish checklist's "Cells waiting for a score" row run
%   curation.RescoreRunner in the background (the scorer: the newest deployed curated scorer of the
%   channel kind, else the shipped ordinal one); the scores are stored between pages.
%
%   Training (left: Training..., right: the Training tab, curation.TrainingPanel): the exports for
%   the Stage-2 scorer, the Stage-1 detector and the observation table, the scorer fine-tune
%   (in its own process) and the detector command. Nothing there runs on the review keys. The tab
%   shows at once; what can be exported is counted in the background (cached per channel kind,
%   counted again after a confirmed page or a change of Complete/sweep, while the tab shows).
%
%   Keyboard guards: Enter/Space from the keyboard confirm only when released since the last
%   confirm and after MinPageSec on screen (handleKey itself, the test seam, has no such guard);
%   a key or the window losing the focus ends a drag whose button-up was missed and the held c.
%   A note belongs to the cell in the inspector when its field got the focus.
%
%   Errors never reach a dialog or escape a key press: the status bar says what happened. When
%   another session takes a source over (curation:Store:lockLost, Changed Kind "lockLost") the
%   window turns it read-only (editing controls off, their tooltips say why). A source that opens
%   read-only says why (LockInfo.Message and the open's warnings); one that cannot be opened
%   (e.g. curation:Store:snapshotMissing) leaves the previous source on screen. A save whose
%   shared JSON could not be written, and an undo/redo refused for a region conflict, are reported.
%   A reconcile at open is described in plain words (matched, new, kept cells no longer detected).
%
%   Test seams (exactly what the real callbacks call):
%     handled = app.handleKey(key, modifiers)    key as MATLAB names it ('g', 'return', 'leftarrow',
%                                                'leftbracket', ...) or the character; modifiers a
%                                                cellstr/string ('control', 'shift')
%     app.handleKeyRelease(key)
%     app.galleryClick(tileIdx, selectionType)   'normal' | 'alt' | 'extend'
%     app.hoverTile(k)                           the pointer is over tile k (0 = off the tiles)
%     app.confirmPage(), app.showQueue(name), app.nextSource(), app.previousPage(), app.nextPage(),
%     app.undo(), app.redo(), app.waitForLayout(timeout)
%     app.showCenter("map" | "gallery"), app.setMapTool(name)
%     app.mapClick(xy, selectionType)            a press and release on the map at image point XY
%                                                (the view is centered on XY first when XY is not
%                                                in view); goes through curation.MapView's events;
%                                                'extend' is a Shift+click (Add tool: snapped)
%     app.mapDrag(fromXY, toXY, modifiers)       a drag on the map (Move tool: moves the point;
%                                                MODIFIERS held at the release, "shift": snapped)
%     app.mapLasso(polygon)                      a lasso drawn along POLYGON (M x 2, image px)
%     app.mapHover(xy)                           the pointer over image point XY of the map
%     app.lassoAction(name)                      good | bad | uncertain | exclude | merge | cancel
%     app.markComplete(), app.setSweepWidth(um), app.clickLocator(xy)
%     app.waitForAssist(timeout)                 run the assist runner's idle steps until it is idle
%     app.requestReport(), app.saveReport()      the Audit report... and Save report buttons
%     app.requestRescore(), app.waitForRescore(timeout)   Rescore now / Score edited cells
%     app.showTraining()                         the Training... button (app.Training: the panel)
%     txt = app.showSubject()                    the Subject... button: what the lab database says
%                                                about the section's subject (sex, species, project,
%                                                tags, variables), in the status bar
%     d = app.openMarkerDialog()                 the Markers... button (d: the curation.MarkerDialog,
%                                                whose seams set colors and symbols, ok, cancel)
%     app.applyMarkerStyles(S, keep)             draw the map with markers S; KEEP (default true)
%                                                also saves them in the settings
%   Read-only properties: Figure, Store, Gallery, Page (Kind, Ids, P, Default, Band, Blind, Queue,
%   PageId, Number, Total, Untouched), QueueName, MapPanel, StatusText, ContextText, SourceKey, Datasets,
%   DatasetIndex, SourceIndex, Session, Sessions, DisplayMode, Gain, Gamma, Zoom, Cursor,
%   HoverTile, InspectedTile, Selection, LastTimings, CenterView, Map, Locator, MapTool,
%   MapSelection, MapTask, PairList, PairIndex, Lasso, SelectedRegion, SweepFieldUm,
%   Assist (the curation.AssistRunner, [] when off), AuditReport, Rescorer, Training, MarkerStyle
%   (the map's markers), MarkerDialog (the open markers window, [] when none), Counters
%   (LocatorUpdates: refreshes of the locator; ModelApplies: predictions applied; HoldoutApplied:
%   holdout roles set; RescoreApplies; IgnoredEnter: keyboard confirms refused by the guard;
%   OrphanRolesCleared).
%
%   Queue names: review, flagged, closePairs, vanishedGood, browseGood, browseBad,
%   browseUncertain, sweep (closePairs and sweep work on the map).
%
%   See also curation.Store, curation.GalleryView, curation.CropCache, curation.Queues,
%   curation.Proposals, curation.UiText, CellDatasetManifest.

    properties (Constant)
        QUEUES = ["review" "flagged" "closePairs" "vanishedGood" "browseGood" "browseBad" "browseUncertain" ...
            "sweep"]
        MAP_QUEUES = ["closePairs" "sweep"]
        MAP_TOOLS = ["select" "add" "move" "lasso"]
        MODES = ["target" "overlay" "companion" "side"]
        PairViewUm = 30           % half width of the view on a close pair (about 60 um across)
        ShowOnMapUm = 120         % half width of the view when a cell is shown on the map
        SweepOverlap = 0.1
        LocatorMaxPx = 800        % the locator's image is shrunk to about this long side
        SnapHalfUm = 60           % half side of the page window snapToCellCentroid works on
        CheatLinePx = 12.5        % line height of the cheat sheet (10 px Consolas), for its scroll height
        ContextOneLine = 84       % characters of the context line that fit one line at 16 px
        BarPx = 40                % height of the map's action bar row
        MaxSessions = 2
        BorderPx = 4
        CornerPx = 14             % flag badge side (px of an 80 px tile)
        Gap = 2
        ZoomSteps = [0.6 0.7 0.8 0.9 1 1.15 1.3 1.5 1.75 2 2.5]
        GainLimits = [0.25 8]
        GammaLimits = [0.3 3]
        HistoryMax = 500
        PaceWindow = 5
        IdleDelay = 0.12          % s after a change before the deferred refresh runs
        PrepareIdleSec = 2        % s without input before the next source is prepared
        PrepareChunk = 700        % cells per background crop-extraction step
        AssistStartSec = 1        % s without input before the assist runner starts (after a folder opens)
        AssistPollSec = 0.3       % s between idle steps while the assist runner has work in flight
        PaceMinPageSec = 1.5      % a page confirmed faster than this counts as this long for the pace
        PaceMaxCpm = 1000         % a pace above this is shown as "1,000+"
        TileSide = 80             % crop tile side (curation.CropCache default)
        WhyNoSource = 'no source is open yet.'
        WhyReadOnly = 'this source is open read-only because another session holds it.'
        WhyLost = 'another session took this source over; open it again to go on (your changes up to then are saved).'
        WhyMap = 'the map is showing; Tab returns to the gallery.'
        WhyOnMap = 'the map is already showing; select a cell there.'
    end

    properties (SetAccess = private)
        Figure = []
        Store = []
        Gallery = []
        Page = struct()
        QueueName string = "review"
        MapPanel = []
        ParentDir char = ''
        Datasets = []
        DatasetIndex double = 0
        SourceIndex double = 0
        SourceKey string = ""
        Session = []
        Sessions cell = {}
        DisplayMode string = "target"
        Gain double = 1
        Gamma double = 1
        EvenTiles logical = false          % [t]: each tile scaled to the source's typical cell level
        Zoom double = 1
        Cursor double = 0
        HoverTile double = 0
        InspectedTile double = 0
        Selection double = zeros(1, 0)
        HistPos double = 0
        LastTimings struct = struct('OpenSourceMs', NaN, 'StoreOpenMs', NaN, 'ImageReadMs', NaN, ...
            'CacheBuildMs', NaN, 'ConfirmMs', NaN, 'NextPrefetched', false, 'ApplyModelMs', NaN)
        Settings struct = struct()
        Options struct = struct()
        Prepared = []
        CenterView string = "gallery"      % "gallery" | "map"
        Map = []                           % the center curation.MapView (created on first use)
        Locator = []                       % the right panel's locator curation.MapView
        MapTool string = "select"
        MapSelection uint32 = zeros(0, 1, 'uint32')
        MapHover uint32 = uint32(0)
        MapTask string = ""                % "" | "pairs" | "sweep"
        PairList = []                      % curation.Pairs.find clusters of the Close pairs queue
        PairIndex double = 0
        ShiftDown logical = false          % Shift held (its key press/release; resynced at each press)
        Lasso = []                         % struct Polygon, Ids while the lasso bar is up
        SelectedRegion double = 0
        SweepFieldUm double = 600
        Assist = []                        % curation.AssistRunner of the folder ([] when Assist is off)
        AuditReport = []                   % the last report built: Report, Text, Lines, Generated
        LastRecord = []                    % what celldb.recordCuration returned last
        Rescorer = []                      % curation.RescoreRunner (made on first use)
        Training = []                      % curation.TrainingPanel of the Training tab
        MarkerStyle struct = struct()      % the map's markers (curation.MapMarkers), from the settings
        MarkerDialog = []                  % the open curation.MarkerDialog ([] when none)
        Counters struct = struct('LocatorUpdates', 0, 'MapLoads', 0, 'ModelApplies', 0, 'HoldoutApplied', 0, ...
            'RescoreApplies', 0, 'IgnoredEnter', 0, 'OrphanRolesCleared', 0)
    end

    properties (Dependent)
        StatusText
        ContextText
    end

    properties (Access = private)
        UI struct = struct()
        IdleTimer = []
        Pending struct = struct('prefetch', false, 'panels', false, 'inspector', false, 'undo', false, 'status', false, ...
            'locator', false, 'assist', false, 'maplayout', false, 'final', false, 'rescore', false)
        PendingStatus = []
        IdleArmed = []            % tic when the idle timer was started
        IdleDue double = 0        % its delay then, s
        NextPage = []
        ReviewOffset double = 1   % which page of the Review queue is on screen (PgDn/PgUp move it)
        FocusDue logical = false  % the new window has not been given the keyboard focus yet
        LivePage = []
        ListPages = []
        ListIndex double = 0
        DragAction = []
        DragBatch logical = false
        CompanionHeld logical = false
        TextFocus logical = false
        LastInputTic = []
        Opening logical = false            % a source is being opened: the idle step waits for it
        ImageCache = []
        Closing logical = false
        Closed logical = false
        MapLoadedId string = ""            % session the center map shows
        MapDataset string = ""             % folder|base of that session (a channel switch keeps the view)
        MapPending uint32 = zeros(0, 1, 'uint32')   % cells changed while the map was hidden
        MapFull logical = false            % the map needs all its points again
        MapRegionsDirty logical = false
        MapImageDirty logical = false      % display mode, brightness or gamma changed while hidden
        LocatorLoadedId string = ""
        LocatorScale double = 1            % locator image pixels per page pixel = 1 / LocatorScale
        LocatorDirty logical = true
        LocatorShown logical = false
        GalleryStale logical = false       % edits were made while the map was showing
        PairsCount double = NaN
        WarmTimer = []
        Warmed logical = false
        Notice char = ''                   % appended to the next status text (a source went back to incomplete)
        FinishCache = []                   % finishState of the store revision it was computed for
        VanishCheck logical = false        % an undo removed rows: pages may hold cells that are gone
        CreatingMap logical = false        % the map is being made (an idle step must not start another)
        CreatingLocator logical = false
        MapLaidOut logical = false         % the map has had its real size since it was made
        PendingRecord = []                 % the session whose completion waits to be recorded (celldb)
        ContextNow char = ''               % the text of the context line
        AssistAnnounced logical = false    % the status bar said the folder was read
        InAssist logical = false           % inside maybeAssist (it is not re-entered)
        ConfirmArmed logical = true        % Enter/Space released since the last confirm (key repeat)
        ItemShownTic = []                  % when the close pair or sweep field on screen was shown
        NoteCell uint32 = uint32(0)        % the cell a note being typed belongs to (0: none)
        BarLayout = []                     % a map action bar shown: the layout is finished at idle
        RescoreShown char = ''             % the rescore progress text last put in the status bar
        HoldoutDue string = strings(1, 0)  % kinds whose holdout list waits to be applied
        RescoreWanted logical = false      % Rescore now was asked: started at the next idle step
        RescoreStore = []                  % the store it was asked for
        RescoreModels struct = struct()    % per kind: the scorer (cached a few seconds)
        MarkerSaved struct = struct()      % the markers last kept (OK): what the settings store,
                                           % while MarkerStyle may show a preview of the dialog
    end

    %% ======================================================================== construction
    methods
        function obj = CellCurator(varargin)
            parentDir = '';
            args = varargin;
            if mod(numel(args), 2) == 1
                parentDir = args{1};
                args = args(2:end);
            end
            p = inputParser;
            p.FunctionName = 'CellCurator';
            p.addParameter('Visible', 'on');
            p.addParameter('UseSettings', true);
            p.addParameter('PrepareNext', true);
            p.addParameter('AutosaveDelay', 2);
            p.addParameter('WarmUp', true);
            p.addParameter('PrepareMap', true);
            p.addParameter('Assist', true);
            p.addParameter('ConfirmAudit', true);
            p.addParameter('AssistOptions', struct());
            p.addParameter('RescoreOptions', struct());
            p.addParameter('TrainingOptions', struct());
            p.addParameter('MinPageSec', 0.3);
            p.parse(args{:});
            o = p.Results;
            if islogical(o.Visible) || isnumeric(o.Visible)
                o.Visible = char(matlab.lang.OnOffSwitchState(logical(o.Visible)));
            else
                o.Visible = char(string(o.Visible));
            end
            o.UseSettings = logical(o.UseSettings);
            o.PrepareNext = logical(o.PrepareNext);
            o.WarmUp = logical(o.WarmUp);
            o.PrepareMap = logical(o.PrepareMap);
            o.Assist = logical(o.Assist);
            o.ConfirmAudit = logical(o.ConfirmAudit);
            o.AutosaveDelay = double(o.AutosaveDelay);
            o.MinPageSec = double(o.MinPageSec);
            obj.Options = o;
            t0 = tic;
            CellCurator.preloadClasses();
            obj.LastTimings.PreloadMs = 1000 * toc(t0);

            obj.Datasets = CellCurator.emptyDatasets();
            obj.ImageCache = struct('Key', {}, 'Data', {});
            obj.Settings = obj.loadSettings();
            s = obj.Settings;
            if any(CellCurator.MODES == string(s.DisplayMode)), obj.DisplayMode = string(s.DisplayMode); end
            % brightness and gamma are relative to each source's default (curation.DisplayDefaults)
            obj.Gain = CellCurator.clamp(double(s.GainRel), CellCurator.GainLimits, 1);
            obj.Gamma = CellCurator.clamp(double(s.GammaRel), CellCurator.GammaLimits, 1);
            obj.EvenTiles = isscalar(s.EvenTiles) && logical(s.EvenTiles);
            obj.Zoom =CellCurator.clamp(double(s.Zoom), CellCurator.ZoomSteps([1 end]), 1);
            obj.SweepFieldUm = CellCurator.clamp(double(s.SweepFieldUm), [100 5000], 600);
            obj.MarkerStyle = curation.MapMarkers.validate(s.MarkerStyles);
            obj.MarkerSaved = obj.MarkerStyle;
            obj.Page = CellCurator.blankPage("none");
            obj.LastInputTic = tic;

            obj.buildUI();
            obj.showNone();
            if ~isempty(parentDir)
                obj.openParent(parentDir);
                obj.focusIfDue();
            else
                obj.startWarmUp();
            end
        end

        function delete(obj)
            obj.close();
        end
    end

    %% ======================================================================== public API
    methods
        function openParent(obj, parentDir, datasetBase, sourceKey)
            %OPENPARENT  Scan PARENTDIR for sections with detections and open one source.
            if nargin < 3, datasetBase = ''; end
            if nargin < 4, sourceKey = ''; end
            if obj.Closed, return; end
            obj.stopWarmUp();
            parentDir = char(string(parentDir));
            if isempty(parentDir) || ~isfolder(parentDir)
                obj.setStatus(curation.UiText.msg('notFolder', parentDir));
                return
            end
            obj.endDrag();
            parentDir = CellCurator.absFolder(parentDir);
            if ~strcmpi(parentDir, obj.ParentDir)
                obj.closeAllSessions();
                obj.Prepared = [];
                obj.stopAssist();
            else
                obj.leaveSource();
            end
            obj.ParentDir = parentDir;
            if ~isempty(obj.Training) && isvalid(obj.Training), obj.Training.setParentDir(parentDir); end
            if obj.Options.Assist && isempty(obj.Assist)
                % made now, started at the first pause after the first page (curation.AssistRunner)
                obj.Assist = curation.AssistRunner(parentDir, obj.Options.AssistOptions);
                obj.AuditReport = [];
                obj.AssistAnnounced = false;
            end
            obj.UI.Folder.Text = CellCurator.shortPath(parentDir, 34);
            obj.UI.Folder.Tooltip = parentDir;
            obj.setStatus(curation.UiText.msg('looking', parentDir));
            drawnow limitrate;
            obj.Datasets = obj.discoverDatasets(parentDir);
            short = CellCurator.displayNames({obj.Datasets.Base}, 28);
            for k = 1:numel(obj.Datasets), obj.Datasets(k).Short = short{k}; end
            obj.relinkSessions();
            obj.refreshDatasetControls();
            if isempty(obj.Datasets)
                obj.Page = CellCurator.blankPage("none");
                if ~isempty(obj.Gallery.Cache)
                    obj.Gallery.showPage(zeros(0, 1, 'uint32'), obj.styleFor(obj.Page));
                end
                obj.showMessage("noDatasets");
                obj.updateContext();
                obj.updateUndoButtons();
                obj.updateEditEnable();
                obj.setStatus(curation.UiText.msg('noDatasets', parentDir));
                return
            end
            [di, si] = obj.pickStart(parentDir, datasetBase, sourceKey);
            obj.openSourceAt(di, si);
        end

        function openSource(obj, locsCsvPath)
            %OPENSOURCE  Open the source whose detector locs file is LOCSCSVPATH (scans its folder).
            locsCsvPath = char(string(locsCsvPath));
            if ~isfile(locsCsvPath)
                obj.setStatus(curation.UiText.msg('problem', ['No such file: ' locsCsvPath]));
                return
            end
            folder = fileparts(CellCurator.absFile(locsCsvPath));
            mf = CellDatasetManifest.forCsv(locsCsvPath);
            key = CellDatasetManifest.keyForCsv(locsCsvPath);
            if strcmpi(folder, obj.ParentDir) || CellCurator.isBelow(folder, obj.ParentDir)
                [di, si] = obj.findSource(mf.Folder, mf.Base, key);
                if di > 0
                    obj.openSourceAt(di, si);
                    return
                end
            end
            obj.openParent(folder, mf.Base, key);
        end

        function addCloseListener(obj, fcn)
            %ADDCLOSELISTENER  fcn() when the window is destroyed (after the work is saved).
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                addlistener(obj.Figure, 'ObjectBeingDestroyed', @(~, ~) fcn());
            end
        end

        function handled = handleKey(obj, key, modifiers)
            %HANDLEKEY  What the window's key handler calls (see the class help and [?]). Never
            %   throws: a failure (another session took the source, a region conflict, ...) is
            %   reported in the status bar.
            if nargin < 3, modifiers = strings(1, 0); end
            handled = false;
            if obj.Closed, return; end
            try
                handled = obj.dispatchKey(key, modifiers);
            catch ME
                handled = true;
                obj.DragBatch = false;
                obj.DragAction = [];
                obj.reportError(ME);
            end
        end

        function handleKeyRelease(obj, key)
            %HANDLEKEYRELEASE  What the window's key-release handler calls: the held c key ends; a
            %   released Enter/Space arms the next confirm (the key-repeat guard).
            if obj.Closed, return; end
            k = CellCurator.normalizeKey(key);
            if k == "shift"
                obj.ShiftDown = false;
            elseif k == "c"
                obj.holdCompanion(false);
            elseif any(k == ["return" "space"])
                obj.ConfirmArmed = true;
            end
        end

        function galleryClick(obj, tileIdx, selectionType)
            %GALLERYCLICK  A press and release on tile TILEIDX: 'normal' | 'alt' | 'extend'.
            if nargin < 3 || isempty(selectionType), selectionType = 'normal'; end
            info = struct('Tile', double(tileIdx), 'Id', uint32(0), 'SelectionType', char(selectionType), ...
                'Modifier', strings(1, 0), 'StartTile', double(tileIdx), 'Point', [NaN NaN], ...
                'Tiles', double(tileIdx));
            try
                obj.onTileClick(info);
            catch ME
                obj.DragBatch = false;
                obj.reportError(ME);
            end
            obj.onDragEnd(info);
        end
    end

    methods (Access = private)
        function handled = dispatchKey(obj, key, modifiers)
            %DISPATCHKEY  handleKey without its error guard.
            handled = false;
            mods = lower(string(modifiers));
            mods = reshape(mods, 1, []);
            ctrl = any(mods == "control" | mods == "command");
            shift = any(mods == "shift");
            key = CellCurator.normalizeKey(key);
            if any(key == ["shift" "control" "alt" "command"])
                % a modifier alone is no command and leaves a drag going: Shift held as a moved
                % cell is dropped snaps it to its center (onMapPointDrop)
                if key == "shift", obj.ShiftDown = true; end
                return
            end
            obj.LastInputTic = tic;
            obj.stopWarmUp();
            obj.endDrag();
            if obj.CompanionHeld && key ~= "c"
                obj.holdCompanion(false);       % its release was missed (the window lost the focus)
            end
            if key ~= "escape" && ~isempty(obj.Map) && isvalid(obj.Map) && obj.Map.Gesture ~= ""
                obj.Map.cancelDrag();           % a key ends a drag whose release was missed
            end
            handled = true;
            if ctrl
                switch key
                    case "z",          obj.undo();
                    case "y",          obj.redo();
                    case "s",          obj.saveNow();
                    case "rightarrow", obj.stepSource(1);
                    case "leftarrow",  obj.stepSource(-1);
                    otherwise,         handled = false;
                end
                return
            end
            if obj.CenterView == "map" && obj.mapKey(key, shift)
                return
            end
            M = @curation.UiText.msg;
            switch key
                case "g", obj.labelTiles(obj.keyTargets(), "Good");
                case "b", obj.labelTiles(obj.keyTargets(), "Bad");
                case "u", obj.labelTiles(obj.keyTargets(), "Uncertain");
                case "f", obj.flagTiles(obj.keyTargets());
                case {"x", "backspace"}, obj.clearTiles(obj.keyTargets());
                case {"return", "space"}, obj.confirmPage();
                case {"tab", "v"}, obj.toggleCenter();
                case ".", obj.showOnMap();
                case "s", obj.setMapTool("select", true);
                case "a", obj.setMapTool("add", true);
                case "m", obj.setMapTool("move", true);
                case "l", obj.setMapTool("lasso", true);
                case "e", obj.setStatus(M('keyOnMap', 'e', 'after a lasso it makes the area an exclusion region.'));
                case "j", obj.setStatus(M('keyOnMap', 'j', 'it merges the lassoed cells or a close pair.'));
                case "k", obj.setStatus(M('keyOnMap', 'k', 'it keeps both cells of a close pair.'));
                case "delete", obj.setStatus(M('keyOnMap', 'Del', 'it removes the selected exclusion region.'));
                case "leftarrow",  obj.moveCursor(0, -1);
                case "rightarrow", obj.moveCursor(0, 1);
                case "pageup",    obj.previousPage();
                case "pagedown",  obj.nextPage();
                case "uparrow",   obj.moveCursor(-1, 0);
                case "downarrow", obj.moveCursor(1, 0);
                case "n", obj.nextSource();
                case "o", obj.cycleMode();
                case "c", obj.holdCompanion(true);
                case "[", obj.setGain(obj.Gain / 1.25);
                case "]", obj.setGain(obj.Gain * 1.25);
                case ";", obj.setGamma(obj.Gamma * 1.15);
                case "'", obj.setGamma(obj.Gamma / 1.15);
                case "0", obj.resetDisplay();
                case "t", obj.setEvenTiles(~obj.EvenTiles);
                case "+", obj.stepZoom(1);
                case "-", obj.stepZoom(-1);
                case "?", obj.toggleHelp();
                case "escape", obj.escapeKey();
                otherwise, handled = false;
            end
        end
    end

    methods
        function hoverTile(obj, k)
            %HOVERTILE  The pointer is over tile K (0: it left the tiles), as the gallery reports it.
            obj.onTileHover(struct('Tile', double(k)));
        end

        function confirmPage(obj)
            %CONFIRMPAGE  Enter: label every untouched tile with the page default and show the next
            %   page (Review); on other pages move forward.
            if obj.Closed, return; end
            obj.endDrag();
            t0 = tic;
            P = obj.Page;
            switch P.Kind
                case "active"
                    if ~obj.canEdit(), return; end
                    st = obj.Store;
                    % the default goes to the untouched ORDINARY tiles: never to an audit tile
                    u = st.get('Label', P.Ids) == "" & st.get('Flag', P.Ids) == "" & ~obj.blindRole(P.Ids);
                    % the page's own audit tiles hold it (not tiles the confirm audit below draws from it)
                    pend = obj.blindPending(P.Ids) & st.get('Flag', P.Ids) == "";
                    ids = P.Ids(u);
                    dwell = 1000 * toc(P.ShownTic);
                    n = numel(ids);
                    audit = zeros(0, 1, 'uint32');
                    if n > 0
                        ctx = struct('ProposalP', P.P(u), 'Queue', P.Queue, 'PageId', P.PageId, 'DwellMs', dwell);
                        % a page that stays on screen (an audit tile is undecided) is never drawn from:
                        % its tiles would turn gray under the reviewer
                        keepOff = zeros(0, 1, 'uint32');
                        if any(pend), keepOff = P.Ids; end
                        try
                            st.beginBatch(curation.UiText.msg('txnConfirm', P.Number, CellCurator.fmtInt(n), P.Default));
                            try
                                st.setLabel(ids, P.Default, "confirmed", ctx);
                                % the source's ordinary queue ran out: its confirm audit, in this
                                % Enter's own transaction (undoing the Enter removes the roles too)
                                audit = obj.confirmAuditNow(keepOff, false);
                            catch ME
                                st.cancelBatch();
                                rethrow(ME);
                            end
                            st.endBatch();
                        catch ME
                            obj.reportError(ME);        % e.g. another session took the source
                            return
                        end
                    end
                    if n > 0
                        obj.schedule("assist");                 % the Assist block follows (coalesced)
                        if ~isempty(obj.Training), obj.Training.invalidate(); end   % (a flag only)
                    end
                    if any(pend)
                        % an audit tile is still undecided: the page stays, the cursor goes to it,
                        % and the keys go to it too (the pointer may still be over another tile)
                        if n > 0, obj.refreshTiles(find(u)); end
                        k = find(pend, 1);
                        obj.Cursor = k;
                        obj.Gallery.setCursor(k);
                        obj.InspectedTile = k;
                        obj.forgetHover();
                        obj.schedule(["inspector" "panels"]);
                        k = nnz(pend);
                        what = [CellCurator.auditText(k) ' still ' CellCurator.plural(k, 'needs', 'need')];
                        if n > 0
                            obj.setStatusLater(curation.UiText.msg('blindKeep', CellCurator.fmtInt(n), P.Default, what));
                        else
                            obj.setStatusLater(curation.UiText.msg('blindLeft', what));
                        end
                        obj.updateContext();
                        obj.LastTimings.ConfirmMs = 1000 * toc(t0);
                        return
                    end
                    if ~isempty(audit), obj.NextPage = []; end
                    sess = obj.Session;
                    sess.PagesDone = sess.PagesDone + 1;
                    sess.PaceLog(end + 1, :) = [numel(P.Ids), dwell / 1000];
                    obj.pushHistory(P);
                    next = obj.takeNextPage(P);
                    if isempty(next)
                        obj.showEmpty();
                    else
                        obj.showPageStruct(next);
                    end
                    if n > 0
                        obj.setStatusLater(curation.UiText.msg('confirmed', CellCurator.fmtInt(n), P.Default, P.Number, P.Total));
                    else
                        obj.setStatusLater(curation.UiText.msg('pageDone', P.Number, P.Total));
                    end
                case "list"
                    obj.advanceList();
                case {"history", "changed"}
                    obj.forward();
                case "empty"
                    if obj.QueueName == "review"
                        obj.finishEnter();
                    end
            end
            obj.LastTimings.ConfirmMs = 1000 * toc(t0);
        end

        function showQueue(obj, name)
            %SHOWQUEUE  Switch to queue NAME (see the class help) and show its first page.
            if obj.Closed, return; end
            name = string(name);
            hit = find(strcmpi(CellCurator.QUEUES, name), 1);
            if isempty(hit)
                obj.setStatus(curation.UiText.msg('problem', sprintf('Unknown queue "%s".', name)));
                return
            end
            name = CellCurator.QUEUES(hit);
            obj.endDrag();
            if any(name == CellCurator.MAP_QUEUES)
                if isempty(obj.Store)
                    obj.setStatus(curation.UiText.msg('mapNoSource'));
                    return
                end
                if name == "closePairs"
                    obj.startPairs();
                else
                    obj.startSweep();
                end
                return
            end
            obj.leaveMapTask();
            obj.QueueName = name;
            obj.HistPos = 0;
            obj.LivePage = [];
            obj.NextPage = [];
            obj.ReviewOffset = 1;
            obj.ListPages = [];
            obj.ListIndex = 0;
            if isempty(obj.Store)
                return
            end
            if name == "review"
                page = obj.reviewPage([], 1);
                if isempty(page)
                    obj.showEmpty();
                else
                    obj.showPageStruct(page);
                end
                return
            end
            T = CellCurator.queueTable(obj.Store);
            p = curation.Proposals.current(T, obj.SourceKey);
            opts = obj.queueOpts(T);
            if startsWith(name, "browse")
                % an audit tile waiting for its blind judgment is not browsed (its label would show)
                keep = ~(curation.BlindTiles.roleMask(T.AuditRole) & T.LabelSource ~= "blind");
                T = T(keep, :);
                p = p(keep);
                if ~isempty(opts.Raw), opts.Raw = opts.Raw(keep); end
            end
            switch name
                case "flagged",         pages = curation.Queues.flagged(T, opts);
                case "vanishedGood",    pages = curation.Queues.vanishedGood(T, opts);
                case "browseGood",      pages = curation.Queues.browse(T, p, "Good", opts);
                case "browseBad",       pages = curation.Queues.browse(T, p, "Bad", opts);
                case "browseUncertain", pages = curation.Queues.browse(T, p, "Uncertain", opts);
            end
            obj.ListPages = pages;
            if isempty(pages)
                obj.showEmpty();
            else
                obj.ListIndex = 1;
                obj.showPageStruct(obj.listPageAt(1));
            end
            nCells = 0;
            if ~isempty(pages), nCells = sum(arrayfun(@(q) numel(q.Ids), pages)); end
            obj.setStatus(curation.UiText.msg('showQueue', curation.UiText.queueLabel(name), CellCurator.fmtInt(nCells)));
        end

        function nextSource(obj)
            %NEXTSOURCE  Open the next source (channel, then section) that still has cells to review.
            if obj.Closed, return; end
            obj.endDrag();
            if isempty(obj.Datasets)
                obj.setStatus(curation.UiText.msg('ready'));
                return
            end
            [di, si] = obj.nextWorkSource();
            if di == 0
                obj.setStatus(curation.UiText.msg('allDone'));
                return
            end
            obj.openSourceAt(di, si);
        end

        function previousPage(obj)
            %PREVIOUSPAGE  PageUp: the page before this one. In the Review queue that is first the
            %   pages left unconfirmed with PageDown, then the pages confirmed in this session
            %   (still editable).
            if obj.Closed || isempty(obj.Session), return; end
            obj.endDrag();
            H = obj.Session.History;
            if obj.HistPos == 0 && obj.Page.Kind == "active" && obj.QueueName == "review" && obj.ReviewOffset > 1
                obj.ReviewOffset = obj.ReviewOffset - 1;
                page = obj.reviewPage([], 1);
                if ~isempty(page)
                    obj.showPageStruct(page);
                    obj.setStatus(curation.UiText.msg('pageShown', page.Number, page.Total));
                end
                return
            end
            if obj.HistPos == 0
                if isempty(H)
                    obj.setStatus(curation.UiText.msg('noHistory'));
                    return
                end
                obj.LivePage = obj.Page;
                obj.HistPos = numel(H);
            elseif obj.HistPos > 1
                obj.HistPos = obj.HistPos - 1;
            else
                obj.setStatus(curation.UiText.msg('firstPage'));
                return
            end
            obj.showHistory(obj.HistPos);
        end

        function nextPage(obj)
            %NEXTPAGE  PageDown: the next page, without confirming this one. A Review page left
            %   this way keeps its untouched tiles in the queue (nothing is labeled by PageDown);
            %   PageUp comes back to it.
            if obj.Closed, return; end
            obj.endDrag();
            switch obj.Page.Kind
                case {"history", "changed"}, obj.forward();
                case "list",                 obj.advanceList();
                case "active",               obj.leavePage();
            end
        end

        function undo(obj)
            %UNDO  Ctrl+Z: undo one transaction and bring its page back on screen.
            if obj.Closed, return; end
            obj.endDrag();
            if ~obj.canEdit(), return; end
            if ~obj.Store.CanUndo
                obj.setStatus(curation.UiText.msg('nothingUndo'));
                return
            end
            % audit roles the app set (holdout, a confirm audit drawn between pages) are no undo
            % steps (the store's system form): undo is always the reviewer's own last action
            obj.Session.LastChange = [];
            try
                obj.Store.undo();
                obj.clearOrphanAudit();       % a confirm-audit role whose confirmed label just went
            catch ME
                obj.reportError(ME);          % a region conflict changes nothing; a lost lock: read-only
                return
            end
            obj.afterReplay(obj.Session.LastChange, "undo");
        end

        function redo(obj)
            %REDO  Ctrl+Y: redo the last undone transaction.
            if obj.Closed, return; end
            obj.endDrag();
            if ~obj.canEdit(), return; end
            if ~obj.Store.CanRedo
                obj.setStatus(curation.UiText.msg('nothingRedo'));
                return
            end
            obj.Session.LastChange = [];
            try
                obj.Store.redo();
            catch ME
                obj.reportError(ME);
                return
            end
            obj.afterReplay(obj.Session.LastChange, "redo");
        end

        function waitForLayout(obj, timeout)
            %WAITFORLAYOUT  Wait (up to TIMEOUT s, default 15) until the window has its real size and
            %   the page fits it. A uifigure lays its grids out in the browser, seconds after creation.
            if nargin < 2, timeout = 15; end
            t0 = tic;
            last = [];
            stable = 0;
            while toc(t0) < timeout
                drawnow;
                if obj.Closed || ~isvalid(obj.Gallery.Panel), return; end
                p = getpixelposition(obj.Gallery.Panel, true);
                if isequal(p, last) && p(3) > 150 && p(4) > 150
                    stable = stable + 1;
                else
                    stable = 0;
                end
                last = p;
                if stable >= 4, break; end
                pause(0.1);
            end
            pause(0.3);
            drawnow;
            obj.onCapacityChanged();
            drawnow;
        end

        function close(obj)
            %CLOSE  Save every open source, record it to its manifest, release locks and timers,
            %   save the settings and delete the window.
            if obj.Closed || obj.Closing, return; end
            obj.Closing = true;
            try obj.endDrag(); catch, end
            obj.stopIdleTimer();
            obj.stopWarmUp();
            try obj.stopAssist(); catch, end
            try obj.closeMarkerDialog(); catch, end
            try obj.saveSettings(); catch, end
            try
                if ~isempty(obj.Rescorer) && isvalid(obj.Rescorer), delete(obj.Rescorer); end
                if ~isempty(obj.Training) && isvalid(obj.Training), delete(obj.Training); end
            catch
            end
            obj.Rescorer = [];
            obj.Training = [];
            for v = {obj.Map, obj.Locator}
                try
                    if ~isempty(v{1}) && isvalid(v{1}), delete(v{1}); end
                catch
                end
            end
            obj.Map = [];
            obj.Locator = [];
            for k = 1:numel(obj.Sessions)
                try obj.closeSession(obj.Sessions{k}); catch, end
            end
            obj.Sessions = {};
            obj.Session = [];
            obj.Store = [];
            obj.Prepared = [];
            obj.ImageCache = struct('Key', {}, 'Data', {});
            g = obj.Gallery;
            if ~isempty(g) && isvalid(g)
                try delete(g); catch, end
            end
            obj.Closed = true;
            f = obj.Figure;
            if ~isempty(f) && isvalid(f) && f.BeingDeleted == "off"
                delete(f);
            end
        end
    end

    %% ======================================================================== dependent
    methods
        function t = get.StatusText(obj)
            %   What the status bar shows, or will show at the next idle moment (key-path texts are
            %   drawn by the idle refresh).
            t = "";
            if ~isempty(obj.PendingStatus)
                t = string(obj.PendingStatus);
            elseif isfield(obj.UI, 'Status') && isvalid(obj.UI.Status)
                t = string(obj.UI.Status.Text);
            end
        end

        function t = get.ContextText(obj)
            %   The context line as shown (a long one has a line break where its head and tail meet).
            t = string(obj.ContextNow);
        end
    end

    %% ======================================================================== UI construction
    methods (Access = private)
        function buildUI(obj)
            pos = double(obj.Settings.WindowPosition);
            if numel(pos) ~= 4 || any(~isfinite(pos)) || any(pos(3:4) < 600)
                pos = [80 60 1500 900];
            end
            f = uifigure('Name', 'CellCurator', 'Position', pos, 'Visible', 'off', 'Tag', 'CellCurator');
            obj.Figure = f;
            f.CloseRequestFcn = @(~, ~) obj.close();
            f.WindowKeyPressFcn = @(~, e) obj.onWindowKeyPress(e);
            f.WindowKeyReleaseFcn = @(~, e) obj.onWindowKeyRelease(e);
            f.WindowButtonDownFcn = @(~, e) obj.onButtonDown(e);
            f.WindowButtonMotionFcn = @(~, e) obj.onMotion(e);
            f.WindowButtonUpFcn = @(~, e) obj.onButtonUp(e);
            f.WindowScrollWheelFcn = @(~, e) obj.onScroll(e);
            addlistener(f, 'ObjectBeingDestroyed', @(~, ~) obj.onFigureDestroyed());
            try
                % the window lost the focus: a release it will never see must not leave a drag
                % painting tiles, the other channel showing, or Enter disarmed
                addlistener(f, 'FigureDeactivated', @(~, ~) obj.onDeactivated());
            catch
            end

            root = uigridlayout(f, [2 1], 'RowHeight', {34, '1x'}, 'ColumnWidth', {'1x'}, ...
                'Padding', [8 6 8 6], 'RowSpacing', 6);
            obj.buildTopBar(root);
            body = uigridlayout(root, [1 3], 'ColumnWidth', {270, '1x', 320}, 'RowHeight', {'1x'}, ...
                'Padding', [0 0 0 0], 'ColumnSpacing', 8);
            body.Layout.Row = 2;
            body.Layout.Column = 1;
            obj.buildLeft(body);
            obj.buildCenter(body);
            obj.buildRight(body);
            obj.updateEditEnable();
            f.Visible = obj.Options.Visible;
            % the keyboard focus is given once the first page is up (focusIfDue): asking for it
            % here waits about 3 s for the new window's view in a fresh MATLAB session
            obj.FocusDue = true;
        end

        function buildTopBar(obj, root)
            U = @curation.UiText.label;
            tb = uigridlayout(root, [1 13], 'Padding', [0 0 0 0], 'ColumnSpacing', 6, 'RowHeight', {'1x'});
            tb.ColumnWidth = {'1x', 105, 210, 140, 115, 66, 90, 48, 90, 100, 112, 108, 76};
            tb.Layout.Row = 1;
            tb.Layout.Column = 1;
            obj.UI.Folder = uilabel(tb, 'Text', U('noFolder'), 'FontWeight', 'bold', 'Tag', 'lbl:folder');
            obj.UI.OpenFolder = uibutton(tb, 'Text', U('openFolder'), 'Tag', 'btn:openFolder', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.onOpenFolder()));
            CellToolkit.setTooltip(obj.UI.OpenFolder, curation.UiText.tip('openFolder'));
            obj.UI.Dataset = uidropdown(tb, 'Items', {U('noSection')}, 'ItemsData', {0}, 'Tag', 'dd:dataset', ...
                'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.onDatasetChosen(s.Value)));
            CellToolkit.setTooltip(obj.UI.Dataset, curation.UiText.tip('dataset'));
            obj.UI.SourceGrid = uigridlayout(tb, [1 1], 'Padding', [0 0 0 0], 'ColumnSpacing', 4, ...
                'RowHeight', {'1x'}, 'ColumnWidth', {'1x'});
            obj.UI.SourceButtons = gobjects(0);
            [items, data] = curation.UiText.modeItems();
            obj.UI.Mode = uidropdown(tb, 'Items', items, 'ItemsData', data, 'Value', char(obj.DisplayMode), ...
                'Tag', 'dd:mode', 'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.setMode(s.Value)));
            CellToolkit.setTooltip(obj.UI.Mode, curation.UiText.tip('mode'));
            uilabel(tb, 'Text', U('brightness'), 'HorizontalAlignment', 'right');
            obj.UI.Gain = uislider(tb, 'Limits', log2(CellCurator.GainLimits), 'Value', log2(obj.Gain), ...
                'MajorTicks', [], 'MinorTicks', [], 'Tag', 'sl:gain', ...
                'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.setGain(2 ^ s.Value)));
            CellToolkit.setTooltip(obj.UI.Gain, curation.UiText.tip('gain'));
            uilabel(tb, 'Text', U('gamma'), 'HorizontalAlignment', 'right');
            obj.UI.Gamma = uislider(tb, 'Limits', CellCurator.GammaLimits, 'Value', obj.Gamma, ...
                'MajorTicks', [], 'MinorTicks', [], 'Tag', 'sl:gamma', ...
                'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.setGamma(s.Value)));
            CellToolkit.setTooltip(obj.UI.Gamma, curation.UiText.tip('gamma'));
            obj.UI.EvenTiles = uibutton(tb, 'state', 'Text', U('evenTiles'), 'Tag', 'btn:evenTiles', ...
                'Value', obj.EvenTiles, 'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.setEvenTiles(s.Value)));
            CellToolkit.setTooltip(obj.UI.EvenTiles, curation.UiText.tip('evenTiles'));
            obj.UI.Undo =uibutton(tb, 'Text', U('undo'), 'Tag', 'btn:undo', 'Enable', 'off', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.undo()));
            obj.UI.Redo = uibutton(tb, 'Text', U('redo'), 'Tag', 'btn:redo', 'Enable', 'off', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.redo()));
            obj.UI.Help = uibutton(tb, 'state', 'Text', U('help'), 'Tag', 'btn:help', ...
                'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.toggleHelp(s.Value)));
            CellToolkit.setTooltip(obj.UI.Help, curation.UiText.tip('help'));
            obj.updateUndoButtons();
        end

        function buildLeft(obj, body)
            U = @curation.UiText.label;
            L = uigridlayout(body, [19 1], 'Padding', [2 2 2 2], 'RowSpacing', 4, 'ColumnWidth', {'1x'});
            L.RowHeight = {20, 176, 34, 22, 16, 10, 16, 10, 16, 10, 48, 20, 58, 30, 30, 26, 26, 22, '1x'};
            L.Layout.Row = 1;
            L.Layout.Column = 1;
            h = uilabel(L, 'Text', U('queuesHead'), 'FontWeight', 'bold');
            h.Layout.Row = 1;
            obj.UI.Queues = uilistbox(L, 'Items', CellCurator.queueItems(nan(1, numel(CellCurator.QUEUES))), ...
                'ItemsData', cellstr(CellCurator.QUEUES), 'Value', 'review', 'Tag', 'lb:queues', ...
                'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.onQueueChosen(s.Value)));
            obj.UI.Queues.Layout.Row = 2;
            CellToolkit.setTooltip(obj.UI.Queues, curation.UiText.tip('queues'));
            obj.UI.Bands = uilabel(L, 'Text', '', 'WordWrap', 'on', 'FontColor', [0.3 0.3 0.3], 'VerticalAlignment', 'top');
            obj.UI.Bands.Layout.Row = 3;
            h = uilabel(L, 'Text', U('progressHead'), 'FontWeight', 'bold');
            h.Layout.Row = 4;
            obj.UI.ProgSourceText = uilabel(L, 'Text', '', 'FontSize', 11);
            obj.UI.ProgSourceText.Layout.Row = 5;
            obj.UI.ProgSource = obj.makeBar(L, 6);
            obj.UI.ProgSectionText = uilabel(L, 'Text', '', 'FontSize', 11);
            obj.UI.ProgSectionText.Layout.Row = 7;
            obj.UI.ProgSection = obj.makeBar(L, 8);
            obj.UI.ProgFolderText = uilabel(L, 'Text', '', 'FontSize', 11);
            obj.UI.ProgFolderText.Layout.Row = 9;
            obj.UI.ProgFolder = obj.makeBar(L, 10);
            obj.UI.Pace = uilabel(L, 'Text', curation.UiText.msg('paceNone'), 'WordWrap', 'on', ...
                'FontSize', 11, 'VerticalAlignment', 'top');
            obj.UI.Pace.Layout.Row = 11;
            % the assist model: where the proposals come from, its accuracy, agreement on blind tiles
            T = @curation.UiText.tip;
            h = uilabel(L, 'Text', U('assistHead'), 'FontWeight', 'bold', 'Tag', 'lbl:assistHead');
            h.Layout.Row = 12;
            CellToolkit.setTooltip(h, [T('assistSource') ' ' T('assistAgreement')]);
            spec = {'AssistSource', 'lbl:assistSource', 'assistSource', 13
                'AssistAccuracy', 'lbl:assistAccuracy', 'assistAccuracy', 14
                'AssistAgreement', 'lbl:assistAgreement', 'assistAgreement', 15};
            for i = 1:size(spec, 1)
                a = uilabel(L, 'Text', '', 'WordWrap', 'on', 'FontSize', 11, 'VerticalAlignment', 'top', ...
                    'Tag', spec{i, 2});
                a.Layout.Row = spec{i, 4};
                CellToolkit.setTooltip(a, T(spec{i, 3}));
                obj.UI.(spec{i, 1}) = a;
            end
            bg2 = uigridlayout(L, [1 2], 'Padding', [0 0 0 0], 'ColumnSpacing', 4, 'RowHeight', {'1x'}, ...
                'ColumnWidth', {'1x', '1x'});
            bg2.Layout.Row = 16;
            obj.UI.AuditReport = uibutton(bg2, 'Text', U('auditReport'), 'Tag', 'btn:auditReport', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.requestReport()));
            CellToolkit.setTooltip(obj.UI.AuditReport, T('auditReport'));
            obj.UI.TrainingButton = uibutton(bg2, 'Text', U('training'), 'Tag', 'btn:training', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.showTraining()));
            CellToolkit.setTooltip(obj.UI.TrainingButton, T('training'));
            obj.UI.RescoreButton = uibutton(L, 'Text', U('rescoreEdited', '0'), 'Tag', 'btn:rescoreEdited', ...
                'Enable', 'off', 'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.requestRescore()));
            obj.UI.RescoreButton.Layout.Row = 17;
            CellToolkit.setTooltip(obj.UI.RescoreButton, obj.rescoreTip('rescoreEdited', CellCurator.WhyNoSource));
            h = uilabel(L, 'Text', U('sectionsHead'), 'FontWeight', 'bold');
            h.Layout.Row = 18;
            obj.UI.Sections = uilistbox(L, 'Items', {U('noSection')}, 'ItemsData', {0}, 'Value', 0, ...
                'Tag', 'lb:sections', 'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.onDatasetChosen(s.Value)));
            obj.UI.Sections.Layout.Row = 19;
            CellToolkit.setTooltip(obj.UI.Sections, curation.UiText.tip('sections'));
            obj.refreshAssistPanel();
        end

        function b = makeBar(~, parent, row)
            C = curation.UiText.colors();
            g = uigridlayout(parent, [1 2], 'Padding', [0 0 0 0], 'ColumnSpacing', 0, 'RowSpacing', 0, ...
                'RowHeight', {'1x'}, 'ColumnWidth', {'0.0001x', '1x'});
            g.Layout.Row = row;
            g.Layout.Column = 1;
            uipanel(g, 'BorderType', 'none', 'BackgroundColor', C.Good / 255);
            uipanel(g, 'BorderType', 'none', 'BackgroundColor', [0.86 0.86 0.86]);
            b = g;
        end

        function buildCenter(obj, body)
            C = curation.UiText.colors();
            bg = C.Background / 255;
            G = uigridlayout(body, [4 1], 'RowHeight', {36, '1x', 24, 22}, 'ColumnWidth', {'1x'}, ...
                'Padding', [0 0 0 0], 'RowSpacing', 4);
            G.Layout.Row = 1;
            G.Layout.Column = 2;
            obj.UI.Center = G;
            % row 1: the context line and the Gallery / Map switch
            top = uigridlayout(G, [1 2], 'ColumnWidth', {'1x', 132}, 'RowHeight', {'1x'}, ...
                'Padding', [0 0 0 0], 'ColumnSpacing', 6);
            top.Layout.Row = 1;
            top.Layout.Column = 1;
            % the context line is a text object in an axes, not a uilabel: it changes on the key path,
            % and a graphics update returns from drawnow far sooner than a UI component's text
            cpn = uipanel(top, 'BorderType', 'none', 'AutoResizeChildren', 'off', 'Tag', 'pn:context');
            cpn.Layout.Row = 1;
            cpn.Layout.Column = 1;
            obj.UI.View = uibutton(top, 'state', 'Text', curation.UiText.label('toggleView'), ...
                'Tag', 'btn:toggleView', 'FontWeight', 'bold', ...
                'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.onViewButton(s.Value)));
            obj.UI.View.Layout.Row = 1;
            obj.UI.View.Layout.Column = 2;
            CellToolkit.setTooltip(obj.UI.View, curation.UiText.tip('toggleView'));
            cax = axes(cpn, 'Units', 'pixels', 'Visible', 'off', 'XLim', [0 1], 'YLim', [0 1], ...
                'XLimMode', 'manual', 'YLimMode', 'manual', 'HitTest', 'off', 'PickableParts', 'none', ...
                'Tag', 'ax:context');
            cax.InnerPosition = [1 1 600 30];
            try cax.Toolbar = []; catch, end
            try disableDefaultInteractivity(cax); catch, end
            obj.UI.Context = text(cax, 0, 0.5, '', 'FontUnits', 'pixels', 'FontSize', 16, 'FontWeight', 'bold', ...
                'VerticalAlignment', 'middle', 'HorizontalAlignment', 'left', 'Interpreter', 'none', ...
                'Color', [0.08 0.08 0.08], 'Tag', 'lbl:context', 'HitTest', 'off', 'PickableParts', 'none');
            cpn.SizeChangedFcn = @(s, ~) CellCurator.fillPanel(s, cax);
            obj.Gallery = curation.GalleryView(G, 'Background', bg, 'CursorColor', C.Cursor / 255, ...
                'SelectionColor', C.Selection / 255, 'Zoom', obj.Zoom);
            obj.Gallery.Panel.Layout.Row = 2;
            obj.Gallery.Panel.Layout.Column = 1;
            obj.Gallery.TileClickFcn = @(~, info) obj.uiCall(@() obj.onTileClick(info), false);
            obj.Gallery.TileDragFcn = @(~, info) obj.uiCall(@() obj.onTileDrag(info), false);
            obj.Gallery.DragEndFcn = @(~, info) obj.uiCall(@() obj.onDragEnd(info), false);
            obj.Gallery.TileHoverFcn = @(~, info) obj.uiCall(@() obj.onTileHover(info), false);
            obj.Gallery.CapacityChangedFcn = @(~, ~, ~) obj.uiCall(@() obj.onCapacityChanged(), false);

            % message overlay (no folder, queue done, nothing found): same cell, on top
            mp = uipanel(G, 'BorderType', 'none', 'BackgroundColor', bg, 'Visible', 'off', 'Tag', 'pn:message');
            mp.Layout.Row = 2;
            mp.Layout.Column = 1;
            mg = uigridlayout(mp, [6 3], 'RowHeight', {'1x', 34, 'fit', 34, 34, '1x'}, ...
                'ColumnWidth', {'1x', 420, '1x'}, 'BackgroundColor', bg, 'RowSpacing', 10);
            obj.UI.MsgTitle = uilabel(mg, 'Text', '', 'FontSize', 20, 'FontWeight', 'bold', ...
                'FontColor', [0.95 0.95 0.95], 'HorizontalAlignment', 'center');
            obj.UI.MsgTitle.Layout.Row = 2; obj.UI.MsgTitle.Layout.Column = 2;
            obj.UI.MsgText = uilabel(mg, 'Text', '', 'FontSize', 14, 'WordWrap', 'on', ...
                'FontColor', [0.85 0.85 0.85], 'HorizontalAlignment', 'center');
            obj.UI.MsgText.Layout.Row = 3; obj.UI.MsgText.Layout.Column = 2;
            obj.UI.MsgOpenFolder = uibutton(mg, 'Text', curation.UiText.label('msgOpenFolder'), ...
                'Tag', 'btn:msgOpenFolder', 'FontSize', 14, ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.onOpenFolder()));
            obj.UI.MsgOpenFolder.Layout.Row = 4; obj.UI.MsgOpenFolder.Layout.Column = 2;
            CellToolkit.setTooltip(obj.UI.MsgOpenFolder, curation.UiText.tip('msgOpenFolder'));
            obj.UI.MsgNext = uibutton(mg, 'Text', curation.UiText.label('openNext'), 'Tag', 'btn:openNext', ...
                'FontSize', 14, 'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.nextSource()));
            obj.UI.MsgNext.Layout.Row = 4; obj.UI.MsgNext.Layout.Column = 2;
            CellToolkit.setTooltip(obj.UI.MsgNext, curation.UiText.tip('openNext', 'the next source'));
            obj.UI.MsgReopen = uibutton(mg, 'Text', '', 'Tag', 'btn:reopen', 'FontSize', 13, ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.openParent(obj.Settings.LastFolder)));
            obj.UI.MsgReopen.Layout.Row = 5; obj.UI.MsgReopen.Layout.Column = 2;
            CellToolkit.setTooltip(obj.UI.MsgReopen, curation.UiText.tip('reopen', '(none yet)'));
            obj.UI.Message = mp;

            obj.buildLegend(G, 3, bg);
            obj.buildFinish(G, bg);
            obj.buildMapArea(G, bg);
            % the status bar: the message of the moment, and the lab database at its right end
            sb = uigridlayout(G, [1 4], 'ColumnWidth', {'1x', 0, 0, 0}, 'RowHeight', {'1x'}, ...
                'Padding', [0 0 0 0], 'ColumnSpacing', 6, 'Tag', 'gl:status');
            sb.Layout.Row = 4; sb.Layout.Column = 1;
            obj.UI.StatusBar = sb;
            obj.UI.Status = uilabel(sb, 'Text', '', 'Tag', 'lbl:status', 'FontColor', [0.15 0.15 0.15]);
            obj.UI.Status.Layout.Row = 1; obj.UI.Status.Layout.Column = 1;
            obj.buildDatabase(sb);
        end

        function buildDatabase(obj, sb)
            %BUILDDATABASE  The lab database lamp (celldb.addLamp), a Database... button and a Subject...
            %   button at the right end of the status bar. Nothing here may change what the app writes;
            %   without the celldb package (or the client) the window works the same. The subject's
            %   tags and variables are shown only when Subject... is pressed, never by themselves: a
            %   reviewer should not see the animal's group while deciding on cells.
            obj.UI.DbLamp = [];
            obj.UI.DbButton = [];
            obj.UI.SubjectButton = [];
            if ~CellCurator.hasCelldb(), return; end
            try
                sj = uibutton(sb, 'Text', curation.UiText.label('subject'), 'Tag', 'btn:subject', ...
                    'FontSize', 11, 'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.showSubject()));
                sj.Layout.Row = 1; sj.Layout.Column = 2;
                CellToolkit.setTooltip(sj, curation.UiText.tip('subject'));
                obj.UI.SubjectButton = sj;
                b = uibutton(sb, 'Text', curation.UiText.label('database'), 'Tag', 'btn:database', ...
                    'FontSize', 11, 'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.openDatabase()));
                b.Layout.Row = 1; b.Layout.Column = 3;
                tip = curation.UiText.tip('database');
                try
                    s = string(celldb.statusText());
                    if strlength(s) > 0, tip = [tip ' ' char(s)]; end
                catch
                end
                CellToolkit.setTooltip(b, tip);
                obj.UI.DbButton = b;
                lamp = celldb.addLamp(sb, 'Row', 1, 'Column', 4, 'Parent', obj.Figure);
                obj.UI.DbLamp = lamp;
                sb.ColumnWidth = {'1x', 76, 84, 'fit'};
            catch ME
                warning('CellCurator:database', 'No lab database controls: %s', ME.message);
            end
        end

        function buildFinish(obj, G, bg)
            %BUILDFINISH  The finish-a-source checklist shown when the Review queue is empty (over the
            %   gallery, like the message panel).
            U = @curation.UiText.label;
            T = @curation.UiText.tip;
            fp = uipanel(G, 'BorderType', 'none', 'BackgroundColor', bg, 'Visible', 'off', 'Tag', 'pn:finish');
            fp.Layout.Row = 2;
            fp.Layout.Column = 1;
            fg = uigridlayout(fp, [14 3], 'RowHeight', {'1x', 34, 24, 30, 32, 32, 32, 32, 46, 46, 6, 40, 34, '1.3x'}, ...
                'ColumnWidth', {'1x', 560, '1x'}, 'BackgroundColor', bg, 'RowSpacing', 8);
            light = [0.95 0.95 0.95];
            obj.UI.FinTitle = uilabel(fg, 'Text', '', 'FontSize', 20, 'FontWeight', 'bold', ...
                'FontColor', light, 'HorizontalAlignment', 'center', 'Tag', 'lbl:finTitle');
            obj.UI.FinTitle.Layout.Row = 2; obj.UI.FinTitle.Layout.Column = 2;
            obj.UI.FinWhy = uilabel(fg, 'Text', '', 'FontSize', 13, 'FontColor', [0.8 0.8 0.8], ...
                'HorizontalAlignment', 'center', 'Tag', 'lbl:finWhy');
            obj.UI.FinWhy.Layout.Row = 3; obj.UI.FinWhy.Layout.Column = 2;
            obj.UI.FinUnreviewed = uilabel(fg, 'Text', '', 'FontSize', 14, 'FontColor', light, ...
                'Tag', 'lbl:finUnreviewed');
            obj.UI.FinUnreviewed.Layout.Row = 4; obj.UI.FinUnreviewed.Layout.Column = 2;
            spec = {
                'finishAudit',    @() obj.onFinishRow("review", 'Audit'),        5
                'finishFlagged',  @() obj.onFinishRow("flagged", 'Flagged'),     6
                'finishPairs',    @() obj.onFinishRow("closePairs", 'Pairs'),    7
                'finishVanished', @() obj.onFinishRow("vanishedGood", 'Vanished'), 8
                'finishSweep',    @() obj.onQueueChosen("sweep"),                9};
            for i = 1:size(spec, 1)
                fn = spec{i, 2};
                b = uibutton(fg, 'Text', '', 'Tag', ['btn:' spec{i, 1}], 'FontSize', 13, ...
                    'HorizontalAlignment', 'left', 'WordWrap', 'on', ...
                    'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.buttonAction(fn)));
                b.Layout.Row = spec{i, 3}; b.Layout.Column = 2;
                CellToolkit.setTooltip(b, T(spec{i, 1}));
                obj.UI.(['Fin' spec{i, 1}(7:end)]) = b;
            end
            % cells a person added or moved, waiting for their Stage-2 score (optional)
            b = uibutton(fg, 'Text', '', 'Tag', 'btn:finishRescore', 'FontSize', 13, ...
                'HorizontalAlignment', 'left', 'WordWrap', 'on', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.buttonAction(@() obj.requestRescore())));
            b.Layout.Row = 10; b.Layout.Column = 2;
            CellToolkit.setTooltip(b, obj.rescoreTip('finishRescore', ''));
            obj.UI.FinRescore = b;
            obj.UI.FinComplete = uibutton(fg, 'Text', U('finishComplete'), 'Tag', 'btn:finishComplete', ...
                'FontSize', 15, 'FontWeight', 'bold', 'BackgroundColor', [0.80 0.88 0.98], ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.buttonAction(@() obj.markComplete())));
            obj.UI.FinComplete.Layout.Row = 12; obj.UI.FinComplete.Layout.Column = 2;
            CellToolkit.setTooltip(obj.UI.FinComplete, T('finishComplete'));
            obj.UI.FinNext = uibutton(fg, 'Text', U('finishNext'), 'Tag', 'btn:finishNext', 'FontSize', 14, ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.buttonAction(@() obj.nextSource())));
            obj.UI.FinNext.Layout.Row = 13; obj.UI.FinNext.Layout.Column = 2;
            CellToolkit.setTooltip(obj.UI.FinNext, T('finishNext', 'the next source'));
            obj.UI.Finish = fp;
        end

        function buildMapArea(obj, G, bg)
            %BUILDMAPAREA  The map's place in the center (over the gallery and its legend): a tool bar,
            %   the map host (the curation.MapView and its action bars are created on first use) and
            %   the map's color legend.
            U = @curation.UiText.label;
            T = @curation.UiText.tip;
            ma = uipanel(G, 'BorderType', 'none', 'BackgroundColor', bg, 'Visible', 'off', 'Tag', 'pn:mapArea');
            ma.Layout.Row = [2 3];
            ma.Layout.Column = 1;
            mg = uigridlayout(ma, [3 1], 'RowHeight', {30, '1x', 22}, 'ColumnWidth', {'1x'}, ...
                'Padding', [0 0 0 0], 'RowSpacing', 3, 'BackgroundColor', bg);
            tb = uigridlayout(mg, [1 10], 'ColumnWidth', {86, 76, 80, 82, 6, 0, '1x', 90, 110, 4}, ...
                'RowHeight', {'1x'}, 'Padding', [4 3 4 1], 'ColumnSpacing', 4, 'BackgroundColor', bg);
            tb.Layout.Row = 1;
            tools = CellCurator.MAP_TOOLS;
            ids = ["toolSelect" "toolAdd" "toolMove" "toolLasso"];
            obj.UI.ToolButtons = gobjects(1, numel(tools));
            for i = 1:numel(tools)
                tool = tools(i);
                b = uibutton(tb, 'state', 'Text', U(ids(i)), 'Tag', char("btn:" + ids(i)), ...
                    'Value', tool == obj.MapTool, ...
                    'ValueChangedFcn', @(~, ~) obj.uiCall(@() obj.setMapTool(tool, true)));
                b.Layout.Row = 1; b.Layout.Column = i;
                CellToolkit.setTooltip(b, T(ids(i)));
                obj.UI.ToolButtons(i) = b;
            end
            obj.UI.MapInfo = uilabel(tb, 'Text', '', 'FontColor', [0.92 0.92 0.92], 'Tag', 'lbl:mapInfo', ...
                'HorizontalAlignment', 'right');
            obj.UI.MapInfo.Layout.Row = 1; obj.UI.MapInfo.Layout.Column = 7;
            obj.UI.FitMap = uibutton(tb, 'Text', U('fitMap'), 'Tag', 'btn:fitMap', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.fitMap()));
            obj.UI.FitMap.Layout.Row = 1; obj.UI.FitMap.Layout.Column = 9;
            CellToolkit.setTooltip(obj.UI.FitMap, T('fitMap'));
            obj.UI.Markers = uibutton(tb, 'Text', U('markers'), 'Tag', 'btn:markers', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.openMarkerDialog()));
            obj.UI.Markers.Layout.Row = 1; obj.UI.Markers.Layout.Column = 8;
            CellToolkit.setTooltip(obj.UI.Markers, T('markers'));
            % row 1: the action bar of the moment (0 px high when there is none), row 2: the map
            host = uigridlayout(mg, [2 1], 'RowHeight', {0, '1x'}, 'ColumnWidth', {'1x'}, ...
                'Padding', [0 0 0 0], 'RowSpacing', 0, 'BackgroundColor', bg);
            host.Layout.Row = 2;
            obj.UI.MapHost = host;
            obj.buildMapLegend(mg, 3, bg);
            obj.UI.MapArea = ma;
            obj.syncToolButtons();
        end

        function buildMapLegend(obj, mg, row, bg)
            %BUILDMAPLEGEND  One line under the map: the marker of each cell state (as the map draws
            %   it, curation.MapMarkers) and a swatch per region kind.
            items = curation.UiText.mapLegendItems(obj.MarkerStyle);
            widths = {};
            for k = 1:numel(items)
                widths = [widths, {18, 'fit'}]; %#ok<AGROW>
            end
            widths{end + 1} = '1x';
            lg = uigridlayout(mg, [1 numel(widths)], 'ColumnWidth', widths, 'RowHeight', {18}, ...
                'Padding', [6 2 6 2], 'ColumnSpacing', 4, 'BackgroundColor', bg, 'Tag', 'pn:mapLegend');
            lg.Layout.Row = row;
            lg.Layout.Column = 1;
            for k = 1:numel(items)
                it = items(k);
                c = it.Colors / 255;
                tag = sprintf('mapLegend:%s', it.Name);
                switch it.Kind
                    case "marker"
                        sw = uiimage(lg, 'ImageSource', curation.MapMarkers.swatch(it.Marker, 255 * bg, 18), ...
                            'ScaleMethod', 'none', 'Tag', tag);
                    case "ring"
                        sw = uipanel(lg, 'BorderType', 'line', 'BorderColor', c, 'BorderWidth', 2, ...
                            'BackgroundColor', bg, 'Tag', tag);
                    otherwise
                        sw = uipanel(lg, 'BorderType', 'line', 'BorderColor', c, 'BorderWidth', 1, ...
                            'BackgroundColor', bg, 'Tag', tag);
                end
                sw.Layout.Row = 1;
                sw.Layout.Column = 2 * k - 1;
                t = uilabel(lg, 'Text', it.Text, 'FontColor', [0.92 0.92 0.92], 'FontSize', 11);
                t.Layout.Row = 1;
                t.Layout.Column = 2 * k;
            end
            obj.UI.MapLegend = lg;
        end

        function refreshMapLegend(obj)
            %REFRESHMAPLEGEND  The legend's markers after the markers changed.
            if ~isfield(obj.UI, 'MapLegend') || ~isvalid(obj.UI.MapLegend), return; end
            lg = obj.UI.MapLegend;
            items = curation.UiText.mapLegendItems(obj.MarkerStyle);
            for k = find([items.Kind] == "marker")
                h = findobj(lg.Children, 'flat', 'Tag', ['mapLegend:' items(k).Name]);
                if isempty(h), continue; end
                h.ImageSource = curation.MapMarkers.swatch(items(k).Marker, 255 * lg.BackgroundColor, 18);
            end
        end

        function markerDialogDone(obj, S, accepted)
            %MARKERDIALOGDONE  The markers window closed: OK keeps S, else S is the original markers.
            obj.MarkerDialog = [];
            obj.applyMarkerStyles(S, accepted);
        end

        function closeMarkerDialog(obj)
            %CLOSEMARKERDIALOG  (closing the window) Drop the markers window without keeping its
            %   changes (the settings hold MarkerSaved).
            d = obj.MarkerDialog;
            obj.MarkerDialog = [];
            if ~isempty(d) && isvalid(d)
                d.DoneFcn = [];
                d.PreviewFcn = [];
                delete(d);
            end
        end

        function buildLegend(obj, G, row, bg)
            %BUILDLEGEND  One line under the gallery: a swatch drawn the way the tiles show each
            %   color (a colored frame, or the corner badge) and what it means.
            items = curation.UiText.legendItems();
            widths = {};
            for k = 1:numel(items)
                widths = [widths, repmat({16}, 1, size(items(k).Colors, 1)), {'fit'}]; %#ok<AGROW>
            end
            widths{end + 1} = '1x';
            lg = uigridlayout(G, [1 numel(widths)], 'ColumnWidth', widths, 'RowHeight', {16}, ...
                'Padding', [6 4 6 4], 'ColumnSpacing', 5, 'BackgroundColor', bg, 'Tag', 'pn:legend');
            lg.Layout.Row = row;
            lg.Layout.Column = 1;
            col = 0;
            for k = 1:numel(items)
                it = items(k);
                for j = 1:size(it.Colors, 1)
                    col = col + 1;
                    c = it.Colors(j, :) / 255;
                    tag = sprintf('legend:%s:%d', it.Name, j);
                    switch it.Kind
                        case "corner"
                            sw = uipanel(lg, 'BorderType', 'line', 'BorderColor', [0.35 0.35 0.35], ...
                                'BackgroundColor', bg, 'Tag', tag, 'AutoResizeChildren', 'off');
                            uipanel(sw, 'BorderType', 'none', 'BackgroundColor', c, 'Position', [8 8 7 7], ...
                                'Tag', [tag ':badge']);
                        case "outline"
                            sw = uipanel(lg, 'BorderType', 'line', 'BorderColor', c, 'BorderWidth', 2, ...
                                'BackgroundColor', bg, 'Tag', tag);
                        otherwise
                            sw = uipanel(lg, 'BorderType', 'line', 'BorderColor', c, 'BorderWidth', 3, ...
                                'BackgroundColor', bg, 'Tag', tag);
                    end
                    sw.Layout.Row = 1;
                    sw.Layout.Column = col;
                end
                col = col + 1;
                t = uilabel(lg, 'Text', it.Text, 'FontColor', [0.92 0.92 0.92], 'FontSize', 12);
                t.Layout.Row = 1;
                t.Layout.Column = col;
            end
            obj.UI.Legend = lg;
        end

        function layoutInspector(obj)
            %LAYOUTINSPECTOR  Fit the three enlarged crops into their panel (pixel-exact placement).
            ip = obj.UI.InspPanel;
            if ~isvalid(ip), return; end
            p = getpixelposition(ip);
            T = CellCurator.TileSide;
            W = 3 * T + 2 * 6;
            s = max(0.1, min(p(3) / W, p(4) / T));
            w = max(1, floor(W * s));
            h = max(1, floor(T * s));
            pos = [floor((p(3) - w) / 2) + 1, floor((p(4) - h) / 2) + 1, w, h];
            if ~isequal(obj.UI.InspAxes.InnerPosition, pos)
                obj.UI.InspAxes.InnerPosition = pos;
            end
        end

        function buildRight(obj, body)
            U = @curation.UiText.label;
            C = curation.UiText.colors();
            R = uigridlayout(body, [1 1], 'Padding', [0 0 0 0], 'RowHeight', {'1x'}, 'ColumnWidth', {'1x'});
            R.Layout.Row = 1;
            R.Layout.Column = 3;
            tg = uitabgroup(R, 'Tag', 'tg:right');
            tg.Layout.Row = 1; tg.Layout.Column = 1;
            ti = uitab(tg, 'Title', U('inspectorTab'), 'Tag', 'tab:inspector');
            CellToolkit.setTooltip(ti, curation.UiText.tip('tabInspector'));
            tm = uitab(tg, 'Title', U('mapTab'), 'Tag', 'tab:map');
            CellToolkit.setTooltip(tm, curation.UiText.tip('tabMap'));
            ta = uitab(tg, 'Title', U('auditTab'), 'Tag', 'tab:audit');
            CellToolkit.setTooltip(ta, curation.UiText.tip('tabAudit'));
            tt = uitab(tg, 'Title', U('trainingTab'), 'Tag', 'tab:training');
            CellToolkit.setTooltip(tt, curation.UiText.tip('tabTraining'));
            obj.UI.Tabs = tg;
            obj.UI.TabMap = tm;
            obj.UI.TabInspector = ti;
            obj.UI.TabAudit = ta;
            obj.UI.TabTraining = tt;
            % the Training tab (curation.TrainingPanel: exports, the scorer fine-tune, the detector
            % command; nothing of it runs on the review keys)
            o = obj.Options.TrainingOptions;
            o.KindFcn = @() obj.currentKind();
            o.LiveFcn = @() obj.liveSources();
            o.StatusFcn = @(t) obj.setStatus(t);
            if ~isfield(o, 'CacheDir') && isfield(obj.Options.AssistOptions, 'CacheDir')
                o.CacheDir = obj.Options.AssistOptions.CacheDir;
            end
            obj.Training = curation.TrainingPanel(tt, o);
            obj.Training.setLast(obj.Settings.LastStage2Export, obj.Settings.LastStage1Export);
            tg.SelectionChangedFcn = @(~, ~) obj.uiCall(@() obj.onRightTab(), false);
            % the audit report
            ga = uigridlayout(ta, [2 1], 'RowHeight', {30, '1x'}, 'ColumnWidth', {'1x'}, 'Padding', [6 6 6 6], ...
                'RowSpacing', 6);
            gt = uigridlayout(ga, [1 2], 'ColumnWidth', {'1x', 110}, 'RowHeight', {'1x'}, 'Padding', [0 0 0 0]);
            gt.Layout.Row = 1;
            obj.UI.AuditWhen = uilabel(gt, 'Text', '', 'FontSize', 11, 'Tag', 'lbl:auditWhen', 'WordWrap', 'on');
            obj.UI.SaveReport = uibutton(gt, 'Text', U('saveReport'), 'Tag', 'btn:saveReport', 'Enable', 'off', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.saveReport()));
            CellToolkit.setTooltip(obj.UI.SaveReport, curation.UiText.disabled('saveReport', ...
                curation.UiText.msg('reportNone')));
            obj.UI.AuditText = uitextarea(ga, 'Value', {U('auditEmpty')}, 'Editable', 'off', 'WordWrap', 'on', ...
                'FontSize', 12, 'Tag', 'ta:audit');
            obj.UI.AuditText.Layout.Row = 2;
            CellToolkit.setTooltip(obj.UI.AuditText, curation.UiText.tip('auditText'));

            % inspector
            gi = uigridlayout(ti, [6 1], 'RowHeight', {112, 16, 'fit', 26, 186, '1x'}, ...
                'ColumnWidth', {'1x'}, 'Padding', [6 6 6 6], 'RowSpacing', 6);
            ip = uipanel(gi, 'BorderType', 'none', 'BackgroundColor', C.Background / 255, ...
                'AutoResizeChildren', 'off', 'Tag', 'pn:inspector');
            ip.Layout.Row = 1;
            T = CellCurator.TileSide;
            gap = 6;
            W = 3 * T + 2 * gap;
            ax = axes(ip, 'Units', 'pixels', 'XLim', [0.5 W + 0.5], ...
                'YLim', [0.5 T + 0.5], 'YDir', 'reverse', 'Visible', 'off', 'XLimMode', 'manual', ...
                'YLimMode', 'manual', 'Color', 'none', 'HitTest', 'off', 'PickableParts', 'none', ...
                'Tag', 'ax:inspector');
            ax.InnerPosition = [1 1 W T];
            try ax.Toolbar = []; catch, end
            try disableDefaultInteractivity(ax); catch, end
            imgs = gobjects(1, 3);
            for i = 1:3
                x0 = (i - 1) * (T + gap);
                imgs(i) = image(ax, 'CData', zeros(T, T, 3, 'uint8'), 'XData', [1 T] + x0, 'YData', [1 T], ...
                    'HitTest', 'off', 'PickableParts', 'none');
            end
            obj.UI.InspAxes = ax;
            obj.UI.InspImg = imgs;
            obj.UI.InspPanel = ip;
            ip.SizeChangedFcn = @(~, ~) obj.layoutInspector();
            cg = uigridlayout(gi, [1 3], 'Padding', [0 0 0 0], 'ColumnSpacing', 2, 'RowHeight', {'1x'});
            cg.Layout.Row = 2;
            obj.UI.CapT = uilabel(cg, 'Text', U('captionTarget'), 'FontSize', 10, 'HorizontalAlignment', 'center');
            obj.UI.CapC = uilabel(cg, 'Text', U('captionCompanion'), 'FontSize', 10, 'HorizontalAlignment', 'center');
            obj.UI.CapO = uilabel(cg, 'Text', U('captionOverlay'), 'FontSize', 10, 'HorizontalAlignment', 'center');
            obj.UI.Fields = uilabel(gi, 'Text', U('inspectEmpty'), 'WordWrap', 'on', 'FontName', 'Consolas', ...
                'FontSize', 12, 'VerticalAlignment', 'top', 'Tag', 'lbl:fields');
            obj.UI.Fields.Layout.Row = 3;
            obj.UI.Note = uieditfield(gi, 'text', 'Placeholder', U('notePlaceholder'), 'Tag', 'ef:note', ...
                'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.onNoteChanged(s.Value)), ...
                'ValueChangingFcn', @(~, ~) obj.onNoteTyping());
            obj.UI.Note.Layout.Row = 4;
            CellToolkit.setTooltip(obj.UI.Note, curation.UiText.tip('note'));
            bg = uigridlayout(gi, [5 2], 'Padding', [0 0 0 0], 'RowSpacing', 6, 'ColumnSpacing', 6, ...
                'RowHeight', {30, 30, 30, 30, 30}, 'ColumnWidth', {'1x', '1x'});
            bg.Layout.Row = 5;
            spec = {
                'good',       @() obj.labelAction("Good"),                          C.Good / 255,      [1 1 1]
                'bad',        @() obj.labelAction("Bad"),                           C.Bad / 255,       [1 1 1]
                'uncertain',  @() obj.labelAction("Uncertain"),                     C.Uncertain / 255, [0.1 0.1 0.1]
                'flag',       @() obj.flagAction(),                                 C.Flag / 255,      [0.1 0.1 0.1]
                'clear',      @() obj.clearAction(),                                [0.94 0.94 0.94],  [0.1 0.1 0.1]
                'confirm',    @() obj.confirmPage(),                                [0.80 0.88 0.98],  [0.1 0.1 0.1]
                'prev',       @() obj.previousPage(),                               [0.94 0.94 0.94],  [0.1 0.1 0.1]
                'next',       @() obj.nextPage(),                                   [0.94 0.94 0.94],  [0.1 0.1 0.1]
                'nextSource', @() obj.nextSource(),                                 [0.94 0.94 0.94],  [0.1 0.1 0.1]};
            obj.UI.ActionButtons = gobjects(1, size(spec, 1));
            for i = 1:size(spec, 1)
                fn = spec{i, 2};
                b = uibutton(bg, 'Text', U(spec{i, 1}), 'Tag', ['btn:' spec{i, 1}], ...
                    'BackgroundColor', spec{i, 3}, 'FontColor', spec{i, 4}, 'FontWeight', 'bold', ...
                    'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.buttonAction(fn)));
                b.Layout.Row = ceil(i / 2);
                b.Layout.Column = 2 - mod(i, 2);
                CellToolkit.setTooltip(b, curation.UiText.tip(spec{i, 1}));
                obj.UI.ActionButtons(i) = b;
            end
            obj.UI.ShowOnMap = uibutton(bg, 'Text', U('showOnMap'), 'Tag', 'btn:showOnMap', ...
                'FontWeight', 'bold', 'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.buttonAction(@() obj.showOnMap(true))));
            obj.UI.ShowOnMap.Layout.Row = 5;
            obj.UI.ShowOnMap.Layout.Column = 2;
            CellToolkit.setTooltip(obj.UI.ShowOnMap, curation.UiText.tip('showOnMap'));

            % the locator (a small curation.MapView, created the first time the tab is shown)
            gm = uigridlayout(tm, [1 1], 'Padding', [0 0 0 0]);
            obj.MapPanel = uipanel(gm, 'BorderType', 'none', 'Tag', 'pn:map', 'BackgroundColor', C.Background / 255);
            gp = uigridlayout(obj.MapPanel, [2 1], 'RowHeight', {'1x', 22}, 'ColumnWidth', {'1x'}, ...
                'Padding', [0 0 0 4], 'RowSpacing', 2, 'BackgroundColor', C.Background / 255);
            obj.UI.LocatorHost = gp;
            obj.UI.LocatorHint = uilabel(gp, 'Text', U('mapPlaceholder'), 'HorizontalAlignment', 'center', ...
                'FontColor', [0.8 0.8 0.8], 'Tag', 'lbl:mapPlaceholder');
            obj.UI.LocatorHint.Layout.Row = 2;

            % cheat sheet over the inspector: a scrolling grid whose text row is as tall as the text
            cp = uipanel(R, 'Title', U('cheatTitle'), 'Visible', 'off', 'Tag', 'pn:cheat', ...
                'FontWeight', 'bold');
            cp.Layout.Row = 1; cp.Layout.Column = 1;
            cheat = curation.UiText.cheatSheet();
            nLines = numel(strsplit(cheat, newline));
            cgr = uigridlayout(cp, [2 1], 'RowHeight', {28, CellCurator.CheatLinePx * nLines + 12}, ...
                'ColumnWidth', {'1x'}, 'Padding', [8 8 8 8], 'RowSpacing', 8, 'Scrollable', 'on', ...
                'Tag', 'gl:cheat');
            obj.UI.CloseHelp = uibutton(cgr, 'Text', U('closeHelp'), 'Tag', 'btn:help', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.toggleHelp(false)));
            obj.UI.CloseHelp.Layout.Row = 1;
            CellToolkit.setTooltip(obj.UI.CloseHelp, curation.UiText.tip('closeHelp'));
            obj.UI.CheatText = uilabel(cgr, 'Text', cheat, 'FontName', 'Consolas', ...
                'FontSize', 10, 'WordWrap', 'off', 'VerticalAlignment', 'top', 'Tag', 'lbl:cheat');
            obj.UI.CheatText.Layout.Row = 2;
            obj.UI.CheatGrid = cgr;
            obj.UI.Cheat = cp;
        end
    end

    %% ======================================================================== window callbacks
    methods (Access = private)
        function uiCall(obj, fcn, refocus)
            %UICALL  Run a control callback: report a failure in the status bar (never a dialog),
            %   then give the keyboard back to the window.
            if nargin < 3, refocus = true; end
            if obj.Closed, return; end
            try
                fcn();
            catch ME
                obj.reportError(ME);
            end
            if refocus
                obj.refocus();
            end
        end

        function focusIfDue(obj)
            %FOCUSIFDUE  Give the new window the keyboard focus, once (so keys work without a click).
            if ~obj.FocusDue, return; end
            obj.FocusDue = false;
            obj.refocus();
        end

        function refocus(obj)
            obj.TextFocus = false;
            obj.NoteCell = uint32(0);
            try
                if ~isempty(obj.Figure) && isvalid(obj.Figure)
                    focus(obj.Figure);
                end
            catch
            end
        end

        function onWindowKeyPress(obj, e)
            %ONWINDOWKEYPRESS  The keyboard: the text field gets its keys; Enter/Space pass the
            %   key-repeat guard (enterAllowed) before they confirm anything; then handleKey.
            try
                mods = string(e.Modifier);
                ctrl = any(ismember(lower(mods), ["control", "command"]));
                if ~ctrl && obj.textEntryFocused()
                    return
                end
                key = CellCurator.eventKey(e);
                k = CellCurator.normalizeKey(key);
                if ~ctrl && any(k == ["return" "space"]) && ~obj.enterAllowed()
                    return
                end
                obj.handleKey(key, mods);
            catch ME
                obj.reportError(ME);
            end
        end

        function onWindowKeyRelease(obj, e)
            try
                obj.handleKeyRelease(CellCurator.eventKey(e));
            catch ME
                obj.reportError(ME);
            end
        end

        function tf = enterAllowed(obj)
            %ENTERALLOWED  An Enter/Space from the keyboard confirms only when the key was released
            %   since the last one (a held key repeats about 30 times a second) and the page (or the
            %   close pair, or the sweep field) has been on screen at least MinPageSec: a page the
            %   reviewer has not seen is never confirmed. An ignored press says so in the status bar.
            tf = true;
            shownTic = [];
            if obj.CenterView == "map"
                if any(obj.MapTask == ["pairs" "sweep"]) && isempty(obj.Lasso) && obj.SelectedRegion == 0
                    shownTic = obj.ItemShownTic;
                else
                    return                      % Enter on the map does not confirm anything else
                end
            elseif any(obj.Page.Kind == ["active" "empty"])
                if isfield(obj.Page, 'ShownTic'), shownTic = obj.Page.ShownTic; end
            else
                return
            end
            M = @curation.UiText.msg;
            if ~obj.ConfirmArmed
                tf = false;
                obj.Counters.IgnoredEnter = obj.Counters.IgnoredEnter + 1;
                obj.setStatus(M('enterHeld'));
                return
            end
            if ~isempty(shownTic) && toc(shownTic) < obj.Options.MinPageSec
                tf = false;
                obj.Counters.IgnoredEnter = obj.Counters.IgnoredEnter + 1;
                obj.setStatus(M('enterTooSoon', round(1000 * obj.Options.MinPageSec)));
                return
            end
            obj.ConfirmArmed = false;           % armed again when the key is released
        end

        function tf = textEntryFocused(obj)
            tf = obj.TextFocus;
            if tf, return; end
            try
                co = obj.Figure.CurrentObject;
                tf = ~isempty(co) && CellCurator.isTextEntry(co);
            catch
            end
        end

        function onButtonDown(obj, e)
            obj.LastInputTic = tic;
            obj.ShiftDown = false;   % Shift pressed during the drag arrives as a key press (resync: a missed release)
            hit = [];
            try hit = e.HitObject; catch, end
            if isempty(hit)
                try hit = obj.Figure.CurrentObject; catch, end
            end
            entering = ~isempty(hit) && CellCurator.isTextEntry(hit);
            if entering && isequal(hit, obj.UI.Note)
                obj.captureNoteCell();
            elseif ~entering
                obj.NoteCell = uint32(0);
            end
            obj.TextFocus = entering;
            try
                % a view gets the press only while it is showing, and only when the press is on it
                % (not on a button of an action bar over the map)
                if obj.mapShowing() && CellCurator.hitsView(hit, obj.Map) && obj.Map.onButtonDown(e)
                    return
                end
                if obj.locatorShowing() && CellCurator.hitsView(hit, obj.Locator) && obj.Locator.onButtonDown(e)
                    return
                end
                if obj.CenterView == "gallery" && ~isempty(obj.Gallery) && isvalid(obj.Gallery)
                    obj.Gallery.onButtonDown(e);
                end
            catch ME
                obj.endDrag();
                obj.reportError(ME);
            end
        end

        function onMotion(obj, e)
            try
                if obj.mapShowing() && obj.Map.onMotion(e)
                    obj.LastInputTic = tic;
                    return
                end
                if obj.locatorShowing() && obj.Locator.onMotion(e)
                    return
                end
                if obj.CenterView == "gallery" && ~isempty(obj.Gallery) && isvalid(obj.Gallery) && obj.Gallery.onMotion(e)
                    obj.LastInputTic = tic;
                end
            catch ME
                obj.reportError(ME);
            end
        end

        function onButtonUp(obj, e)
            try
                if ~isempty(obj.Map) && isvalid(obj.Map) && obj.CenterView == "map" && obj.Map.onButtonUp(e)
                    return
                end
                if ~isempty(obj.Locator) && isvalid(obj.Locator) && obj.Locator.onButtonUp(e)
                    return
                end
                if ~isempty(obj.Gallery) && isvalid(obj.Gallery)
                    obj.Gallery.onButtonUp(e);
                end
                obj.endDrag();
            catch ME
                obj.endDrag();
                obj.reportError(ME);
            end
        end

        function onScroll(obj, e)
            try
                if obj.mapShowing() && obj.Map.onScroll(e)
                    obj.LastInputTic = tic;
                    return
                end
                if obj.locatorShowing()
                    obj.Locator.onScroll(e);
                end
            catch ME
                obj.reportError(ME);
            end
        end

        function tf = mapShowing(obj)
            tf = obj.CenterView == "map" && ~isempty(obj.Map) && isvalid(obj.Map);
        end

        function tf = locatorShowing(obj)
            tf = obj.LocatorShown && ~isempty(obj.Locator) && isvalid(obj.Locator);
        end

        function onDeactivated(obj)
            %ONDEACTIVATED  Focus lost: end every gesture whose button-up or key-up may be missed.
            if obj.Closed, return; end
            try
                obj.endDrag();
                if ~isempty(obj.Map) && isvalid(obj.Map), obj.Map.cancelDrag(); end
                if ~isempty(obj.Locator) && isvalid(obj.Locator), obj.Locator.cancelDrag(); end
                obj.holdCompanion(false);
                obj.ConfirmArmed = true;
            catch ME
                obj.reportError(ME);
            end
        end

        function onFigureDestroyed(obj)
            if ~obj.Closing && ~obj.Closed
                obj.close();
            end
        end

        function onNoteTyping(obj)
            obj.captureNoteCell();
            obj.TextFocus = true;
        end

        function captureNoteCell(obj)
            %CAPTURENOTECELL  The note field got the focus (or the first key): the note belongs to the
            %   cell in the inspector NOW, whatever tile the pointer crosses while it is typed.
            if obj.NoteCell == 0
                obj.TextFocus = false;          % read the inspected cell as it is shown
                obj.NoteCell = obj.inspectedCell();
            end
        end

        function onNoteChanged(obj, value)
            id = obj.NoteCell;
            if id == 0, id = obj.inspectedCell(); end
            obj.TextFocus = false;
            obj.NoteCell = uint32(0);
            if id == 0, return; end
            if ~any(obj.Store.get('CellID') == id), return; end
            if ~obj.canEdit(), return; end
            if obj.CenterView == "map"
                ctx = struct('Queue', "map");
            else
                ctx = struct('Queue', obj.Page.Queue, 'PageId', obj.Page.PageId);
            end
            obj.Store.setNote(id, string(value), ctx);
            obj.setStatus(curation.UiText.msg('note', double(id)));
        end

        function onQueueChosen(obj, name)
            %ONQUEUECHOSEN  A queue picked from the list or the finish checklist: the gallery queues
            %   show the gallery, Close pairs and Sweep the map.
            name = string(name);
            if ~any(name == CellCurator.MAP_QUEUES) && obj.CenterView == "map"
                obj.showCenter("gallery");
            end
            obj.showQueue(name);
        end

        function onViewButton(obj, value)
            if logical(value)
                obj.showCenter("map");
            else
                obj.showCenter("gallery");
            end
            want = obj.CenterView == "map";
            if obj.UI.View.Value ~= want, obj.UI.View.Value = want; end
        end

        function onOpenFolder(obj)
            start = obj.ParentDir;
            if isempty(start), start = char(obj.Settings.LastFolder); end
            if isempty(start) || ~isfolder(start), start = pwd; end
            d = uigetdir(start, 'Choose a folder of sections to review');
            if ischar(d) && ~isempty(d)
                obj.openParent(d);
            end
        end

        function onDatasetChosen(obj, di)
            if isempty(di) || ~isnumeric(di) || di < 1 || di > numel(obj.Datasets), return; end
            if di == obj.DatasetIndex, return; end
            si = obj.firstWorkSourceIn(di);
            obj.openSourceAt(di, si);
        end

        function onSourceButton(obj, si)
            if obj.DatasetIndex < 1, return; end
            obj.openSourceAt(obj.DatasetIndex, si);
        end

        function buttonAction(obj, fn)
            obj.endDrag();
            obj.LastInputTic = tic;
            fn();
        end
    end

    %% ======================================================================== gallery events
    methods (Access = private)
        function onTileClick(obj, info)
            obj.LastInputTic = tic;
            obj.endDrag();
            k = double(info.Tile);
            st = string(info.SelectionType);
            if ~obj.isTilePage() || k < 1 || k > numel(obj.Page.Ids)
                return
            end
            switch st
                case "open"
                    return      % the second press of a double click: the first one acted
                case "extend"
                    add = ~ismember(k, obj.Selection);
                    obj.setSelected(k, add);
                    obj.DragAction = struct('Kind', "select", 'Add', add, 'Label', "", 'Count', 0);
                    return
            end
            if obj.blindPending(obj.Page.Ids(k))
                % an audit tile: a left click only puts the cursor on it; a right-click is Uncertain
                obj.Cursor = k;
                obj.Gallery.setCursor(k);
                obj.InspectedTile = k;
                obj.schedule("inspector");
                if st == "alt"
                    if obj.canEdit(), obj.labelTiles(k, "Uncertain"); end
                else
                    obj.setStatus(curation.UiText.msg('blindSelect'));
                end
                return
            end
            if ~obj.canEdit(), return; end
            target = obj.clickTarget(k, st);
            P = obj.Page;
            if target == ""
                desc = curation.UiText.msg('txnClear', 'tiles', P.Number);
            else
                desc = curation.UiText.msg('txnMark', 'tiles', target, P.Number);
            end
            obj.Store.beginBatch(desc);
            obj.DragBatch = true;
            obj.DragAction = struct('Kind', "label", 'Add', false, 'Label', target, 'Count', 0);
            obj.applyDragTile(k);
        end

        function onTileDrag(obj, info)
            obj.LastInputTic = tic;
            a = obj.DragAction;
            k = double(info.Tile);
            if isempty(a) || k < 1 || k > numel(obj.Page.Ids), return; end
            if a.Kind == "select"
                obj.setSelected(k, a.Add);
            else
                obj.applyDragTile(k);
            end
        end

        function onDragEnd(obj, ~)
            obj.endDrag();
        end

        function onTileHover(obj, info)
            k = double(info.Tile);
            obj.HoverTile = max(0, k);
            if obj.TextFocus && obj.NoteCell > 0
                return              % a note is being typed: the inspector stays on its cell
            end
            if k >= 1 && k <= numel(obj.Page.Ids) && k ~= obj.InspectedTile
                obj.InspectedTile = k;
                obj.refreshInspector();
                obj.locatorChanged();
            end
        end

        function forgetHover(obj)
            %FORGETHOVER  The keys stop going to the tile last reported under the pointer; the gallery
            %   reports the tile under the pointer again at the next real motion.
            obj.HoverTile = 0;
            try
                if ~isempty(obj.Gallery) && isvalid(obj.Gallery)
                    obj.Gallery.onMotion(struct('AxesPoint', [-1e6 -1e6]));   % "left the tiles"
                end
            catch
            end
            obj.HoverTile = 0;
        end

        function k = pointerTile(obj)
            %POINTERTILE  The tile now under the pointer (0: none), from the figure's current point:
            %   after a zoom, a display-mode change or the return from the map the tiles moved under
            %   a pointer that did not.
            k = 0;
            try
                if obj.CenterView ~= "gallery" || isempty(obj.Gallery.Layout) || ~obj.isTilePage(), return; end
                fp = double(obj.Figure.CurrentPoint(1, 1:2));
                k = double(obj.Gallery.hitTest(fp, "figure"));
                if ~(k >= 1 && k <= numel(obj.Page.Ids)), k = 0; end
            catch
                k = 0;
            end
        end

        function rehover(obj)
            %REHOVER  The tiles moved (zoom, display mode, back from the map): the keys go to the tile
            %   under the pointer now, not to the index that used to be there.
            obj.HoverTile = obj.pointerTile();
        end

        function onCapacityChanged(obj)
            if obj.Closed || isempty(obj.Session), return; end
            obj.repage();
        end

        function target = clickTarget(obj, k, st)
            %CLICKTARGET  The label a click gives tile K ("" = back to untouched).
            P = obj.Page;
            lab = obj.Store.get('Label', P.Ids(k));
            if st == "alt"
                if lab == "Uncertain", target = ""; else, target = "Uncertain"; end
                return
            end
            if P.Kind == "active"
                if lab == ""
                    target = CellCurator.opposite(P.Default);
                else
                    target = "";
                end
            else
                if lab == "Good", target = "Bad"; else, target = "Good"; end
            end
        end

        function applyDragTile(obj, k)
            a = obj.DragAction;
            P = obj.Page;
            if obj.blindPending(P.Ids(k)), return; end      % a drag never decides an audit tile
            src = "human";
            ctx = obj.tileCtx(k);
            if obj.blindRole(P.Ids(k))
                if a.Count > 0, return; end                  % nor passes over a decided one: only a click
                src = "blind";                               % re-deciding an audit tile stays blind
                ctx = rmfield(ctx, 'ProposalP');
            end
            obj.Store.setLabel(P.Ids(k), a.Label, src, ctx);
            obj.DragAction.Count = a.Count + 1;
            obj.refreshTiles(k);
            n = CellCurator.fmtInt(obj.DragAction.Count);
            if a.Label == ""
                obj.setStatusLater(curation.UiText.msg('cleared', CellCurator.tilesText(obj.DragAction.Count), P.Number, P.Total));
            else
                obj.setStatusLater(curation.UiText.msg('marked', n, a.Label, P.Number, P.Total));
            end
        end

        function endDrag(obj)
            if obj.DragBatch
                obj.DragBatch = false;
                try
                    if ~isempty(obj.Store) && isvalid(obj.Store) && ~obj.Store.ReadOnly
                        obj.checkComplete();
                        obj.Store.endBatch();
                    end
                catch ME
                    obj.reportError(ME);
                end
            end
            obj.DragAction = [];
        end

        function setSelected(obj, k, add)
            s = obj.Selection;
            if add
                s = unique([s k]);
            else
                s = s(s ~= k);
            end
            obj.Selection = s;
            obj.Gallery.setSelection(s);
            if isempty(s)
                obj.setStatus(curation.UiText.msg('selectionCleared'));
            else
                obj.setStatus(curation.UiText.msg('selection', numel(s)));
            end
        end
    end

    %% ======================================================================== tile actions
    methods (Access = private)
        function tiles = keyTargets(obj)
            %KEYTARGETS  Selection, else the tile under the pointer, else the cursor tile.
            K = numel(obj.Page.Ids);
            tiles = obj.Selection(obj.Selection >= 1 & obj.Selection <= K);
            if ~isempty(tiles), return; end
            if obj.HoverTile >= 1 && obj.HoverTile <= K
                tiles = obj.HoverTile;
            elseif obj.Cursor >= 1 && obj.Cursor <= K
                tiles = obj.Cursor;
            else
                tiles = zeros(1, 0);
            end
        end

        function tiles = buttonTargets(obj)
            %BUTTONTARGETS  Selection, else the cell in the inspector, else the cursor tile.
            K = numel(obj.Page.Ids);
            tiles = obj.Selection(obj.Selection >= 1 & obj.Selection <= K);
            if ~isempty(tiles), return; end
            if obj.InspectedTile >= 1 && obj.InspectedTile <= K
                tiles = obj.InspectedTile;
            elseif obj.Cursor >= 1 && obj.Cursor <= K
                tiles = obj.Cursor;
            else
                tiles = zeros(1, 0);
            end
        end

        function labelTiles(obj, tiles, label)
            if ~obj.isTilePage(), return; end
            if isempty(tiles)
                obj.setStatus(curation.UiText.msg('noTarget'));
                return
            end
            if ~obj.canEdit(), return; end
            P = obj.Page;
            n = numel(tiles);
            st = obj.Store;
            tiles = tiles(:)';
            b = obj.blindRole(P.Ids(tiles))';               % audit tiles: decided blind (no ProposalP)
            st.beginBatch(curation.UiText.msg('txnMark', CellCurator.cellsText(n), label, P.Number));
            try
                if any(~b)
                    st.setLabel(P.Ids(tiles(~b)), label, "human", obj.tileCtx(tiles(~b)));
                end
                if any(b)
                    st.setLabel(P.Ids(tiles(b)), label, "blind", obj.pageCtx());
                end
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.afterTileEdit(tiles);
            obj.setStatusLater(curation.UiText.msg('marked', CellCurator.fmtInt(n), label, P.Number, P.Total));
        end

        function flagTiles(obj, tiles)
            if ~obj.isTilePage(), return; end
            if isempty(tiles)
                obj.setStatus(curation.UiText.msg('noTarget'));
                return
            end
            if ~obj.canEdit(), return; end
            P = obj.Page;
            st = obj.Store;
            ids = P.Ids(tiles);
            n = numel(tiles);
            if all(st.get('Flag', ids) ~= "")
                flag = "";
                desc = curation.UiText.msg('txnUnflag', CellCurator.cellsText(n));
                done = curation.UiText.msg('unflagged', CellCurator.tilesText(n));
            else
                flag = "later";
                desc = curation.UiText.msg('txnFlag', CellCurator.cellsText(n));
                done = curation.UiText.msg('flagged', CellCurator.tilesText(n));
            end
            st.beginBatch(desc);
            try
                st.setFlag(ids, flag, obj.pageCtx());
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.afterTileEdit(tiles);
            obj.setStatusLater(done);
        end

        function clearTiles(obj, tiles)
            if ~obj.isTilePage(), return; end
            if isempty(tiles)
                obj.setStatus(curation.UiText.msg('noTarget'));
                return
            end
            if ~obj.canEdit(), return; end
            P = obj.Page;
            st = obj.Store;
            tiles = tiles(~obj.blindPending(P.Ids(tiles(:)))');   % a waiting audit tile has nothing to clear
            if isempty(tiles)
                obj.setStatus(curation.UiText.msg('blindNoClear'));
                return
            end
            ids = P.Ids(tiles);
            n = numel(tiles);
            st.beginBatch(curation.UiText.msg('txnClear', CellCurator.cellsText(n), P.Number));
            try
                st.setLabel(ids, "", "human", obj.tileCtx(tiles));
                st.setFlag(ids, "", obj.pageCtx());
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.afterTileEdit(tiles);
            obj.setStatusLater(curation.UiText.msg('cleared', CellCurator.tilesText(n), P.Number, P.Total));
        end

        function afterTileEdit(obj, tiles)
            if ~isempty(obj.Selection)
                obj.Selection = zeros(1, 0);
                obj.Gallery.setSelection([]);
            end
            obj.refreshTiles(tiles);
        end

        function ctx = tileCtx(obj, tiles)
            P = obj.Page;
            ctx = struct('ProposalP', P.P(tiles), 'Queue', P.Queue, 'PageId', P.PageId);
        end

        function ctx = pageCtx(obj)
            ctx = struct('Queue', obj.Page.Queue, 'PageId', obj.Page.PageId);
        end

        function ok = canEdit(obj)
            ok = false;
            if isempty(obj.Store) || ~isvalid(obj.Store)
                return
            end
            if obj.Store.ReadOnly
                m = "";
                try m = string(obj.Store.LockInfo.Message); catch, end
                if strlength(m) > 0
                    obj.setStatus(curation.UiText.msg('readOnly', m));
                else
                    obj.setStatus(curation.UiText.msg('readOnlyShort'));
                end
                return
            end
            ok = true;
        end

        function tf = isTilePage(obj)
            tf = any(obj.Page.Kind == ["active" "list" "history" "changed"]) && ~isempty(obj.Store);
        end

        function moveCursor(obj, dr, dc)
            %MOVECURSOR  The arrow keys: the cursor moves DR rows and DC tiles. Left and right run
            %   on into the neighboring row; nothing moves past the first or the last tile.
            K = numel(obj.Page.Ids);
            if K == 0 || ~obj.isTilePage(), return; end
            nc = max(1, obj.Gallery.Grid(2));
            if ~isempty(obj.Gallery.Layout), nc = obj.Gallery.Layout.NCols; end
            if obj.Cursor < 1
                if obj.InspectedTile >= 1 && obj.InspectedTile <= K
                    k = obj.InspectedTile;
                else
                    k = 1;
                end
            else
                k = obj.Cursor + dr * nc + dc;
                if k < 1 || k > K
                    k = obj.Cursor;
                end
            end
            obj.Cursor = k;
            obj.Gallery.setCursor(k);
            obj.InspectedTile = k;
            obj.schedule("inspector");
            obj.locatorChanged();
        end

        function escapeKey(obj)
            if obj.UI.Cheat.Visible == "on"
                obj.toggleHelp(false);
            elseif ~isempty(obj.Selection)
                obj.Selection = zeros(1, 0);
                obj.Gallery.setSelection([]);
                obj.setStatus(curation.UiText.msg('selectionCleared'));
            end
        end

        function toggleHelp(obj, tf)
            if nargin < 2
                tf = obj.UI.Cheat.Visible ~= "on";
            end
            tf = logical(tf);
            obj.UI.Cheat.Visible = matlab.lang.OnOffSwitchState(tf);
            obj.UI.Tabs.Visible = matlab.lang.OnOffSwitchState(~tf);
            obj.UI.Help.Value = tf;
            obj.onRightTab();
        end

        function saveNow(obj)
            if isempty(obj.Store), return; end
            try
                obj.Store.flush();
            catch ME
                obj.reportError(ME);    % the CSV and the journal are written; the JSON or the lock failed
                return
            end
            obj.setStatus(curation.UiText.msg('saved'));
        end
    end

    %% ======================================================================== pages
    methods (Access = private)
        function showPageStruct(obj, page)
            page.ShownTic = tic;
            page.Untouched = obj.untouchedOf(page);
            obj.Page = page;
            obj.Selection = zeros(1, 0);
            obj.Gallery.showPage(page.Ids, obj.styleFor(page));
            if obj.Cursor > numel(page.Ids)
                obj.Cursor = 0;
                obj.Gallery.setCursor(0);
            end
            obj.hideMessage();
            obj.updateContext();
            obj.schedule(["prefetch" "panels" "inspector"]);
            obj.locatorChanged();
        end

        function showHistory(obj, k)
            page = obj.Session.History(k);
            page.Kind = "history";
            obj.showPageStruct(page);
        end

        function showEmpty(obj)
            obj.Page = CellCurator.blankPage("empty");
            obj.Selection = zeros(1, 0);
            obj.Cursor = 0;
            obj.InspectedTile = 0;
            if ~isempty(obj.Gallery.Cache)
                obj.Gallery.setCursor(0);
                obj.Gallery.showPage(zeros(0, 1, 'uint32'), obj.styleFor(obj.Page));
            end
            if obj.QueueName == "review"
                obj.showFinish();
            else
                obj.showMessage("emptyQueue");
            end
            obj.updateContext();
            obj.schedule(["panels" "inspector"]);
            obj.locatorChanged();
        end

        function showNone(obj)
            obj.Page = CellCurator.blankPage("none");
            obj.showMessage("none");
            obj.updateContext();
            obj.setStatus(curation.UiText.msg('ready'));
        end

        function showMessage(obj, kind)
            M = @curation.UiText.msg;
            set([obj.UI.MsgOpenFolder obj.UI.MsgNext obj.UI.MsgReopen], 'Visible', 'off');
            switch kind
                case "none"
                    obj.UI.MsgTitle.Text = M('msgNoneTitle');
                    obj.UI.MsgText.Text = M('msgNoneText');
                    obj.UI.MsgOpenFolder.Visible = 'on';
                    last = char(obj.Settings.LastFolder);
                    if ~isempty(last) && isfolder(last)
                        [~, nm] = fileparts(last);
                        obj.UI.MsgReopen.Text = curation.UiText.label('reopen', nm);
                        CellToolkit.setTooltip(obj.UI.MsgReopen, curation.UiText.tip('reopen', last));
                        obj.UI.MsgReopen.Visible = 'on';
                    end
                case "noDatasets"
                    obj.UI.MsgTitle.Text = M('msgNoDatasetsTitle');
                    obj.UI.MsgText.Text = M('noDatasets', obj.ParentDir);
                    obj.UI.MsgOpenFolder.Visible = 'on';
                case "done"
                    obj.UI.MsgTitle.Text = M('msgDoneTitle', obj.SourceKey);
                    [di, si] = obj.nextWorkSource();
                    if di > 0
                        d = obj.Datasets(di);
                        s = d.Sources(si);
                        obj.UI.MsgText.Text = M('msgDoneNext', s.Key, d.Base, CellCurator.fmtInt(max(0, s.Total - s.Done)));
                        CellToolkit.setTooltip(obj.UI.MsgNext, curation.UiText.tip('openNext', ...
                            sprintf('%s of %s', s.Key, d.Base)));
                        obj.UI.MsgNext.Visible = 'on';
                    else
                        obj.UI.MsgText.Text = M('msgDoneAll');
                    end
                case "emptyQueue"
                    obj.UI.MsgTitle.Text = M('msgEmptyQueueTitle', curation.UiText.queueLabel(obj.QueueName));
                    obj.UI.MsgText.Text = M('msgEmptyQueueText', obj.SourceKey);
            end
            obj.UI.Message.Visible = 'on';
            if obj.UI.Finish.Visible == "on", obj.UI.Finish.Visible = 'off'; end
        end

        function hideMessage(obj)
            if obj.UI.Message.Visible == "on"
                obj.UI.Message.Visible = 'off';
            end
            if obj.UI.Finish.Visible == "on"
                obj.UI.Finish.Visible = 'off';
            end
        end

        function rerender(obj)
            if obj.Page.Kind == "none" || isempty(obj.Gallery.Cache), return; end
            obj.Gallery.showPage(obj.Page.Ids, obj.styleFor(obj.Page));
            obj.NextPage = [];
            obj.schedule(["prefetch" "inspector"]);
        end

        function refreshTiles(obj, tiles)
            obj.Gallery.updateTiles(tiles, obj.styleFor(obj.Page));
            obj.Page.Untouched = obj.untouchedOf(obj.Page);
            obj.updateContext();
            obj.schedule(["inspector" "undo"]);
        end

        function u = untouchedOf(obj, page)
            K = numel(page.Ids);
            if page.Kind ~= "active" || K == 0 || isempty(obj.Store)
                u = false(K, 1);
                return
            end
            u = obj.Store.get('Label', page.Ids) == "" & obj.Store.get('Flag', page.Ids) == "" & ...
                ~obj.blindRole(page.Ids);
        end

        function s = styleFor(obj, page)
            K = numel(page.Ids);
            C = curation.UiText.colors();
            col = NaN(K, 3);
            corner = NaN(K, 3);
            if K > 0 && ~isempty(obj.Store)
                ids = page.Ids;
                lab = obj.Store.get('Label', ids);
                src = obj.Store.get('LabelSource', ids);
                flg = obj.Store.get('Flag', ids);
                role = curation.BlindTiles.roleMask(obj.Store.get('AuditRole', ids));
                pend = role & src ~= "blind";               % an audit tile waiting for its judgment
                good = lab == "Good" & ~pend;
                bad = lab == "Bad" & ~pend;
                unc = lab == "Uncertain" & ~pend;
                col(good, :) = repmat(C.Good, nnz(good), 1);
                col(bad, :) = repmat(C.Bad, nnz(bad), 1);
                col(unc, :) = repmat(C.Uncertain, nnz(unc), 1);
                col(pend, :) = repmat(C.Blind, nnz(pend), 1);
                if page.Kind == "active" && page.Default ~= ""
                    u = lab == "" & flg == "" & ~role;
                    if page.Default == "Bad", pc = C.ProposedBad; else, pc = C.ProposedGood; end
                    col(u, :) = repmat(pc, nnz(u), 1);
                end
                f = flg ~= "";
                corner(f, :) = repmat(C.Flag, nnz(f), 1);
            end
            [g, gam] = obj.displayGG();
            s = struct('Mode', obj.effectiveMode(), 'Gain', g, 'Gamma', gam, 'TileLevel', obj.tileLevel(), ...
                'BorderRGB', col, 'BorderPx', CellCurator.BorderPx, 'CornerRGB', corner, ...
                'CornerPx', CellCurator.CornerPx, 'Gap', CellCurator.Gap, 'Background', C.Background);
        end

        function s = capStyle(obj)
            s = struct('Mode', obj.effectiveMode(), 'Gap', CellCurator.Gap);
        end

        function m = effectiveMode(obj)
            if obj.CompanionHeld
                m = "companion";
            else
                m = obj.DisplayMode;
            end
        end

        function n = pageSize(obj)
            g = obj.Gallery.Grid;
            if any(g == 0)
                [r, c] = obj.Gallery.capacity(obj.capStyle());
                g = [r c];
            end
            n = max(1, prod(g));
        end

        function [page, k, n] = reviewPage(obj, excludeIds, offset)
            %REVIEWPAGE  Page obj.ReviewOffset of the Review queue (without EXCLUDEIDS); OFFSET 1 =
            %   the page to show now, 2 = the page after it (its number assumes the current one is
            %   confirmed). K: the page taken (ReviewOffset, at most the last page), N: how many
            %   pages the queue has. With OFFSET 1, ReviewOffset is set to K.
            page = [];
            k = 1;
            n = 0;
            if isempty(obj.Store) || isempty(obj.Session), return; end
            T = CellCurator.queueTable(obj.Store);
            p = curation.Proposals.current(T, obj.SourceKey);
            opts = obj.queueOpts(T);
            if ~isempty(excludeIds)
                keep = ~ismember(T.CellID, uint32(excludeIds));
                T = T(keep, :);
                p = p(keep);
                if ~isempty(opts.Raw), opts.Raw = opts.Raw(keep); end
            end
            pages = curation.Queues.review(T, p, opts);
            n = numel(pages);
            if n == 0
                if offset == 1, obj.ReviewOffset = 1; end
                return
            end
            k = min(max(1, round(obj.ReviewOffset)), n);
            if offset == 1, obj.ReviewOffset = k; end
            done = obj.Session.PagesDone;
            page = CellCurator.fromQueuePage(pages(k), "active");
            page.Number = done + offset + k - 1;
            page.Total = done + offset - 1 + n;
        end

        function leavePage(obj)
            %LEAVEPAGE  PageDown on a Review page: show the page after it and label nothing. The
            %   page's untouched tiles stay in the queue, one page back (PageUp). A page with
            %   nothing left to decide is simply done (as Enter would say).
            P = obj.Page;
            if obj.QueueName ~= "review" || P.Kind ~= "active", return; end
            if ~any(obj.untouchedOf(P)) && ~any(obj.blindPending(P.Ids) & obj.Store.get('Flag', P.Ids) == "")
                obj.confirmPage();
                return
            end
            nx = obj.NextPage;
            obj.NextPage = [];
            if isempty(nx) || nx.For ~= P.PageId || nx.PageSize ~= obj.pageSize() || nx.From ~= obj.ReviewOffset
                [page, k] = obj.reviewPage(P.Ids, 2);
                nx = struct('Page', page, 'K', k);
            end
            if isempty(nx.Page) || nx.K < obj.ReviewOffset
                obj.setStatus(curation.UiText.msg('lastPage'));      % nothing after this page
                obj.schedule("prefetch");
                return
            end
            obj.ReviewOffset = obj.ReviewOffset + 1;
            obj.showPageStruct(nx.Page);
            obj.setStatus(curation.UiText.msg('pageLeft', P.Number));
        end

        function n = reviewPageCount(obj)
            T = CellCurator.queueTable(obj.Store);
            p = curation.Proposals.current(T, obj.SourceKey);
            n = numel(curation.Queues.review(T, p, obj.queueOpts(T)));
        end

        function opts = queueOpts(obj, T)
            %QUEUEOPTS  What curation.Queues takes: the page size, and the model's raw score of each
            %   row of T (ties in P are ordered by it; [] before the model has predicted this source).
            opts = struct('PageSize', obj.pageSize(), 'Raw', []);
            if ~isempty(obj.Assist) && ~isempty(obj.Session) && obj.Session.ModelNumber > 0
                opts.Raw = obj.Assist.rawFor(obj.Session.Id, T.CellID);
            end
        end

        function page = listPageAt(obj, k)
            page = CellCurator.fromQueuePage(obj.ListPages(k), "list");
            page.Number = k;
            page.Total = numel(obj.ListPages);
        end

        function page = takeNextPage(obj, P)
            nx = obj.NextPage;
            obj.NextPage = [];
            if ~isempty(nx) && nx.For == P.PageId && nx.PageSize == obj.pageSize() && nx.From == obj.ReviewOffset
                page = nx.Page;
                obj.ReviewOffset = nx.K;        % the last page was confirmed: the one before it
                obj.LastTimings.NextPrefetched = true;
            else
                page = obj.reviewPage([], 1);
                obj.LastTimings.NextPrefetched = false;
            end
        end

        function prefetchNext(obj)
            obj.NextPage = [];
            P = obj.Page;
            if isempty(obj.Session) || isempty(obj.Gallery.Cache), return; end
            switch P.Kind
                case "active"
                    if obj.QueueName ~= "review", return; end
                    [nx, k] = obj.reviewPage(P.Ids, 2);
                    if isempty(nx), return; end
                    obj.NextPage = struct('For', P.PageId, 'PageSize', obj.pageSize(), 'Page', nx, ...
                        'K', k, 'From', obj.ReviewOffset);
                    obj.Gallery.prefetch(nx.Ids, obj.styleFor(nx));
                case "list"
                    n = numel(obj.ListPages);
                    if n > 1
                        k = mod(obj.ListIndex, n) + 1;
                        nx = obj.listPageAt(k);
                        obj.Gallery.prefetch(nx.Ids, obj.styleFor(nx));
                    end
            end
        end

        function pushHistory(obj, P)
            sess = obj.Session;
            h = P;
            h.Origin = P.Kind;
            h.Untouched = false(numel(h.Ids), 1);
            if isempty(sess.History)
                sess.History = h;
            else
                sess.History(end + 1, 1) = h;
            end
            if numel(sess.History) > CellCurator.HistoryMax
                sess.History(1) = [];
            end
        end

        function advanceList(obj)
            n = numel(obj.ListPages);
            if n == 0
                obj.showEmpty();
                return
            end
            if obj.Page.Kind == "list"
                obj.pushHistory(obj.Page);
            end
            k = obj.ListIndex + 1;
            if k > n, k = 1; end
            obj.ListIndex = k;
            obj.showPageStruct(obj.listPageAt(k));
            obj.setStatus(curation.UiText.msg('advanced', k, n));
        end

        function forward(obj)
            H = obj.Session.History;
            if obj.HistPos > 0 && obj.HistPos < numel(H)
                obj.HistPos = obj.HistPos + 1;
                obj.showHistory(obj.HistPos);
                return
            end
            obj.HistPos = 0;
            live = obj.LivePage;
            obj.LivePage = [];
            if isempty(live) || live.Kind == "empty" || live.Kind == "none"
                obj.showQueue(obj.QueueName);
            else
                obj.showPageStruct(live);
            end
        end

        function repage(obj)
            %REPAGE  The tiles that fit changed (resize, zoom, display mode): fit the page to them.
            if isempty(obj.Session) || obj.Page.Kind == "none", return; end
            obj.endDrag();
            [r, c] = obj.Gallery.capacity(obj.capStyle());
            cap = r * c;
            obj.NextPage = [];
            P = obj.Page;
            switch P.Kind
                case "active"
                    decided = ~obj.untouchedOf(P);
                    if ~any(decided)
                        page = obj.reviewPage([], 1);
                        if isempty(page)
                            obj.showEmpty();
                        else
                            obj.showPageStruct(page);
                        end
                    else
                        if numel(P.Ids) > cap
                            P = CellCurator.cutPage(P, cap);
                        end
                        obj.showPageStruct(P);
                    end
                case "list"
                    first = P.Ids(1);
                    name = obj.QueueName;
                    obj.showQueue(name);
                    for k = 1:numel(obj.ListPages)
                        if any(obj.ListPages(k).Ids == first)
                            if k ~= obj.ListIndex
                                obj.ListIndex = k;
                                obj.showPageStruct(obj.listPageAt(k));
                            end
                            break
                        end
                    end
                otherwise
                    obj.rerender();
            end
            obj.rehover();          % the tiles moved under the pointer
        end

        function afterReplay(obj, ev, kind)
            %AFTERREPLAY  After undo/redo: show the change on screen (bring its page back). On the
            %   map the map is already in step (the Changed event); the gallery catches up when it
            %   is shown again.
            obj.NextPage = [];
            obj.pruneVanished();
            if isempty(ev)
                obj.updateContext();
                obj.schedule("panels");
                return
            end
            cs = ev.ChangeSet;
            ids = ev.CellIDs;
            isConfirm = startsWith(cs.Desc, "Confirm page");
            if kind == "undo"
                txt = curation.UiText.msg('undid', cs.Desc);
            else
                txt = curation.UiText.msg('redid', cs.Desc);
            end
            if obj.CenterView == "map"
                obj.afterMapReplay(ids);
                obj.setStatus(txt);
                obj.schedule(["panels" "inspector" "undo"]);
                return
            end
            if obj.Page.Kind == "empty" && isempty(ids)
                % a change of the source itself (complete, sweep done, kept pairs, regions) with the
                % finish checklist or an empty queue on screen: show it again as it is now
                obj.showQueue(obj.QueueName);
                obj.setStatus(txt);
                return
            end
            sess = obj.Session;
            P = obj.Page;
            onPage = ismember(P.Ids, ids);
            % an undone confirmation of an EARLIER page touches this page only through the audit
            % roles drawn with it: that earlier page comes back (below), not this one
            earlierConfirm = isConfirm && kind == "undo" && strlength(cs.PageId) > 0 && cs.PageId ~= P.PageId;
            if any(onPage) && obj.isTilePage() && ~earlierConfirm
                if kind == "redo" && isConfirm && P.Kind == "active" && ~any(obj.untouchedOf(P))
                    sess.PagesDone = sess.PagesDone + 1;
                    obj.pushHistory(P);
                    page = obj.reviewPage([], 1);
                    if isempty(page), obj.showEmpty(); else, obj.showPageStruct(page); end
                elseif kind == "undo" && isConfirm && P.Kind == "history" && obj.HistPos > 0
                    obj.makeLive(obj.HistPos);
                else
                    obj.refreshTiles(find(onPage));
                end
                obj.setStatus(txt);
                obj.schedule(["panels" "prefetch"]);
                return
            end
            H = sess.History;
            k = [];
            if ~isempty(H)
                if strlength(cs.PageId) > 0
                    k = find(arrayfun(@(h) h.PageId == cs.PageId, H), 1, 'last');
                end
                if isempty(k)
                    k = find(arrayfun(@(h) any(ismember(h.Ids, ids)), H), 1, 'last');
                end
            end
            if ~isempty(k)
                if kind == "undo" && isConfirm
                    obj.makeLive(k);
                else
                    if obj.HistPos == 0, obj.LivePage = obj.Page; end
                    obj.HistPos = k;
                    obj.showHistory(k);
                end
            elseif ~isempty(obj.LivePage) && any(ismember(obj.LivePage.Ids, ids))
                obj.HistPos = 0;
                live = obj.LivePage;
                obj.LivePage = [];
                obj.showPageStruct(live);
            elseif ~isempty(ids)
                % the change is on no page of this session: show its cells
                if obj.HistPos == 0 && obj.Page.Kind ~= "changed", obj.LivePage = obj.Page; end
                obj.HistPos = 0;
                page = CellCurator.blankPage("changed");
                keep = ismember(ids, obj.Store.get('CellID'));
                ids = ids(keep);
                ids = ids(1:min(numel(ids), obj.pageSize()));
                page.Ids = uint32(ids(:));
                T = CellCurator.queueTable(obj.Store);
                p = curation.Proposals.current(T, obj.SourceKey);
                page.P = p(obj.Store.rowsOf(page.Ids));
                page.Title = string(cs.Desc);
                page.Queue = obj.QueueName;
                page.Number = 1;
                page.Total = 1;
                obj.showPageStruct(page);
            end
            obj.setStatus(txt);
            obj.schedule(["panels" "prefetch"]);
        end

        function makeLive(obj, k)
            %MAKELIVE  History page K had its confirm undone: it is the page under review again.
            sess = obj.Session;
            h = sess.History(k);
            sess.History(k:end) = [];
            sess.PagesDone = max(0, sess.PagesDone - 1);
            if ~isempty(sess.PaceLog), sess.PaceLog(end, :) = []; end
            obj.HistPos = 0;
            obj.LivePage = [];
            page = h;
            page.Kind = "active";
            if h.Origin ~= "", page.Kind = h.Origin; end
            if page.Kind == "active" && obj.QueueName ~= "review"
                % a review page comes back (its confirm was undone from a list queue): the window is
                % in the Review queue again, so Enter and the queue list say what they do
                obj.QueueName = "review";
                obj.ListPages = [];
                obj.ListIndex = 0;
                if ~strcmp(obj.UI.Queues.Value, 'review'), obj.UI.Queues.Value = 'review'; end
            end
            page.Number = sess.PagesDone + 1;
            page.Total = sess.PagesDone + max(1, obj.reviewPageCount());
            obj.showPageStruct(page);
        end

        function updateContext(obj)
            %UPDATECONTEXT  The context line; a long one (audit tiles named, long source names) takes two
            %   lines at a smaller size, split where its head and its tail meet (nothing is clipped).
            txt = obj.contextText();
            fs = 16;
            if numel(txt) > CellCurator.ContextOneLine
                D = curation.UiText.DASH;
                k = strfind(txt, D);
                if ~isempty(k)
                    txt = [txt(1:k(1) - 1) newline strtrim(txt(k(1) + numel(D):end))];
                end
                fs = 13;
            end
            h = obj.UI.Context;
            if ~strcmp(obj.ContextNow, txt)
                obj.ContextNow = txt;
                h.String = txt;
            end
            if h.FontSize ~= fs, h.FontSize = fs; end
        end

        function txt = contextText(obj)
            M = @curation.UiText.msg;
            D = curation.UiText.DASH;
            P = obj.Page;
            if obj.CenterView == "map" && ~isempty(obj.Store)
                txt = char(obj.mapContextText());
                return
            end
            switch P.Kind
                case "none"
                    txt = M('ctxNone');
                    return
                case "active"
                    % the P range of the ORDINARY tiles: an audit tile's P is never shown
                    Po = P.P;
                    if numel(P.Blind) == numel(Po), Po = Po(~P.Blind); end
                    if P.Band == "blind" || isempty(Po)
                        head = M('ctxBlindHead', P.Number, P.Total);
                    else
                        head = M('ctxActive', curation.UiText.bandLabel(P.Band), min(Po), max(Po), P.Number, P.Total);
                    end
                    n = nnz(P.Untouched);
                    nb = 0;
                    if ~isempty(obj.Store) && ~isempty(P.Ids)
                        nb = nnz(obj.blindPending(P.Ids) & obj.Store.get('Flag', P.Ids) == "");
                    end
                    tiles = @(k) sprintf('%s %s', CellCurator.fmtInt(k), CellCurator.plural(k, 'tile', 'tiles'));
                    if ~isempty(obj.Store) && obj.Store.ReadOnly
                        tail = M('ctxReadOnly');
                    elseif n > 0 && nb > 0
                        tail = M('ctxEnterMarkBlind', CellCurator.fmtInt(n), CellCurator.plural(n, 'tile', 'tiles'), ...
                            P.Default, CellCurator.needText(nb));
                    elseif n > 0
                        tail = M('ctxEnterMark', CellCurator.fmtInt(n), CellCurator.plural(n, 'tile', 'tiles'), P.Default);
                    elseif nb > 0 && P.Band == "blind"
                        tail = M('ctxBlindOnly', tiles(nb));
                    elseif nb > 0
                        tail = M('ctxBlindLeft', CellCurator.needText(nb));
                    else
                        tail = M('ctxEnterNext');
                    end
                case "list"
                    n = numel(obj.ListPages);
                    head = M('ctxList', curation.UiText.queueLabel(obj.QueueName), obj.ListIndex, n);
                    if obj.ListIndex < n || n <= 1
                        tail = M('ctxListEnter');
                    else
                        tail = M('ctxListLast');
                    end
                case "history"
                    if P.Origin == "active"
                        what = curation.UiText.bandLabel(P.Band);
                    else
                        what = curation.UiText.queueLabel(P.Queue);
                    end
                    head = M('ctxHistory', obj.HistPos, numel(obj.Session.History), what);
                    tail = M('ctxHistoryEnter');
                case "changed"
                    head = char(P.Title);
                    tail = M('ctxHistoryEnter');
                case "empty"
                    if obj.QueueName == "review"
                        txt = obj.finishContext();
                    else
                        txt = M('ctxEmptyQueue', curation.UiText.queueLabel(obj.QueueName), obj.SourceKey);
                    end
                    return
                otherwise
                    txt = '';
                    return
            end
            txt = [char(head) D char(tail)];
        end

        function setStatus(obj, txt)
            obj.PendingStatus = [];
            txt = obj.withNotice(txt);
            if isfield(obj.UI, 'Status') && isvalid(obj.UI.Status)
                obj.UI.Status.Text = char(txt);
            end
        end

        function setStatusLater(obj, txt)
            %SETSTATUSLATER  Status text from the key path: shown by the idle refresh moments later,
            %   so a label key or Enter only redraws the tiles and the context line.
            obj.PendingStatus = char(obj.withNotice(txt));
            obj.schedule("status");
        end

        function txt = withNotice(obj, txt)
            %WITHNOTICE  TXT followed by the pending notice (e.g. "ECM1 is no longer complete").
            if ~isempty(obj.Notice)
                txt = [char(txt) ' ' obj.Notice];
                obj.Notice = '';
            end
        end

        function reportError(obj, ME)
            %REPORTERROR  An error of an action, in the status bar (never a dialog). The store's
            %   expected conditions get plain words and no stack trace: another session took the
            %   source (it turns read-only), a region conflict on undo/redo, a read-only store, a
            %   shared JSON that could not be written (the cells and the journal are saved).
            M = @curation.UiText.msg;
            known = true;
            try
                switch ME.identifier
                    case 'curation:Store:lockLost'
                        obj.onLockLost();
                    case 'curation:Store:regionConflict'
                        obj.setStatus(M('regionConflict', ME.message));
                    case 'curation:Store:readOnly'
                        obj.setStatus(M('readOnly', ME.message));
                    case {'curation:AtomicIO:jsonUnreadable', 'curation:AtomicIO:jsonBusy'}
                        obj.setStatus(M('jsonNotSaved', ME.message));
                    otherwise
                        known = false;
                        obj.setStatus(M('problem', ME.message));
                end
            catch
            end
            if ~known
                warning('CellCurator:problem', '%s', ME.getReport('extended', 'hyperlinks', 'off'));
            end
        end

        function onLockLost(obj)
            %ONLOCKLOST  Another session took this source over: the store is read-only now. Close
            %   the gestures in progress, turn the editing controls off (their tooltips say why) and
            %   say so in the status bar. The store fires Changed "lockLost" first, then the action
            %   that found out throws curation:Store:lockLost: both come here.
            st = obj.Store;
            obj.DragBatch = false;
            obj.DragAction = [];
            obj.Lasso = [];
            obj.SelectedRegion = 0;
            obj.showBar(obj.taskBar());
            if obj.MapTool ~= "select"
                obj.MapTool = "select";
                if ~isempty(obj.Map) && isvalid(obj.Map), obj.Map.Tool = "select"; end
                obj.syncToolButtons();
            end
            obj.FinishCache = [];
            obj.updateEditEnable();
            obj.updateUndoButtons();
            if obj.UI.Finish.Visible == "on", obj.refreshFinish(); end
            % the store reverted the change in progress (e.g. the tiles a drag had painted): the
            % page shows the store as it is
            try
                if obj.isTilePage()
                    obj.Page.Untouched = obj.untouchedOf(obj.Page);
                    obj.Gallery.showPage(obj.Page.Ids, obj.styleFor(obj.Page));
                    obj.NextPage = [];
                end
            catch
            end
            obj.updateContext();
            msg = "";
            if ~isempty(st) && isvalid(st), msg = string(st.LockInfo.Message); end
            obj.setStatus(curation.UiText.msg('lockLost', msg));
        end

        function why = readOnlyWhy(obj)
            %READONLYWHY  Why the open source cannot be edited, for disabled-control tooltips.
            why = CellCurator.WhyReadOnly;
            st = obj.Store;
            if isempty(st) || ~isvalid(st), why = CellCurator.WhyNoSource; return; end
            L = st.LockInfo;
            if isfield(L, 'Lost') && L.Lost
                why = CellCurator.WhyLost;
            elseif ~(isfield(L, 'Held') && L.Held) && isfield(L, 'Message') && strlength(string(L.Message)) > 0
                why = char("this source opened read-only: " + string(L.Message));
            end
        end
    end

    %% ======================================================================== display
    methods (Access = private)
        function setMode(obj, mode)
            mode = string(mode);
            if ~any(CellCurator.MODES == mode), return; end
            obj.DisplayMode = mode;
            if ~strcmp(obj.UI.Mode.Value, mode)
                obj.UI.Mode.Value = char(mode);
            end
            obj.CompanionHeld = false;
            obj.restyle(true);
            obj.rehover();                       % "side" tiles are twice as wide
            obj.mapDisplayChanged();
            obj.setStatus(curation.UiText.msg('mode', curation.UiText.modeName(mode)));
        end

        function cycleMode(obj)
            i = find(CellCurator.MODES == obj.DisplayMode, 1);
            if isempty(i), i = 0; end
            obj.setMode(CellCurator.MODES(mod(i, numel(CellCurator.MODES)) + 1));
        end

        function restyle(obj, geometryMayChange)
            if isempty(obj.Session) || obj.Page.Kind == "none", return; end
            if geometryMayChange
                old = obj.Gallery.Grid;
                [r, c] = obj.Gallery.capacity(obj.capStyle());
                if ~isequal(old, [r c])
                    obj.repage();
                    return
                end
            end
            obj.rerender();
        end

        function holdCompanion(obj, tf)
            if tf
                if obj.CompanionHeld || obj.DisplayMode == "companion", return; end
                if obj.DisplayMode == "side"
                    obj.setStatus(curation.UiText.msg('sideNoHold'));
                    return
                end
                obj.CompanionHeld = true;
                obj.rerenderVisible();
                obj.setStatus(curation.UiText.msg('companionHeld'));
            else
                if ~obj.CompanionHeld, return; end
                obj.CompanionHeld = false;
                obj.rerenderVisible();
            end
        end

        function rerenderVisible(obj)
            %RERENDERVISIBLE  Redraw what shows the tiles' look: the gallery (when on screen) and
            %   the maps (now when on screen, else when next shown).
            if obj.CenterView == "gallery"
                obj.rerender();
            else
                obj.GalleryStale = true;
            end
            obj.mapDisplayChanged();
        end

        function setGain(obj, g)
            g = CellCurator.clamp(g, CellCurator.GainLimits, 1);
            obj.Gain = g;
            v = log2(g);
            if abs(obj.UI.Gain.Value - v) > 1e-9, obj.UI.Gain.Value = v; end
            obj.rerenderVisible();
            obj.setStatus(curation.UiText.msg('gain', g));
        end

        function setGamma(obj, g)
            g = CellCurator.clamp(g, CellCurator.GammaLimits, 1);
            obj.Gamma = g;
            if abs(obj.UI.Gamma.Value - g) > 1e-9, obj.UI.Gamma.Value = g; end
            obj.rerenderVisible();
            obj.setStatus(curation.UiText.msg('gamma', g));
        end

        function resetDisplay(obj)
            %RESETDISPLAY  [0]: brightness and gamma back to the default of the source on screen.
            obj.Gain = 1;
            obj.Gamma = 1;
            if abs(obj.UI.Gain.Value) > 1e-9, obj.UI.Gain.Value = 0; end
            if abs(obj.UI.Gamma.Value - 1) > 1e-9, obj.UI.Gamma.Value = 1; end
            obj.rerenderVisible();
            [g, gam] = obj.displayGG();
            obj.setStatus(curation.UiText.msg('displayReset', obj.SourceKey, g(1), gam(1)));
        end

        function setEvenTiles(obj, tf)
            %SETEVENTILES  [t] / Even tiles: scale each tile so its cell's center is shown at the level
            %   of the source's typical cell (curation.CropCache TileLevel), or show the page contrast.
            obj.EvenTiles = logical(tf);
            if logical(obj.UI.EvenTiles.Value) ~= obj.EvenTiles, obj.UI.EvenTiles.Value = obj.EvenTiles; end
            if obj.CenterView == "gallery"
                obj.rerender();                  % (schedules the inspector)
            else
                obj.GalleryStale = true;         % the map shows points, not tiles: it keeps its look
                obj.schedule("inspector");
            end
            if obj.EvenTiles
                obj.setStatus(curation.UiText.msg('evenTilesOn'));
            else
                obj.setStatus(curation.UiText.msg('evenTilesOff'));
            end
        end

        function lv = tileLevel(obj)
            %TILELEVEL  The TileLevel of the tile style: [] when Even tiles is off, else the center
            %   level [target companion] of the source's typical cell (curation.DisplayDefaults, crop
            %   units before Gain/Gamma), so the brightness and gamma keys keep their meaning.
            lv = [];
            if ~obj.EvenTiles, return; end
            lv = [128 128];
            sess = obj.Session;
            if ~isempty(sess) && isstruct(sess.Display) && isfield(sess.Display, 'Typical')
                t = double(sess.Display.Typical);
                ok = isfinite(t) & t >= 1;
                lv(ok) = t(ok);
            end
        end

        function [g, gam] = displayGG(obj)
            %DISPLAYGG  The display gain and gamma [target companion] of the tiles and the maps: the
            %   source's default (curation.DisplayDefaults, chosen from its crops) times the
            %   brightness and gamma of the keys and sliders.
            g = [1 1];
            gam = [1 1];
            sess = obj.Session;
            if ~isempty(sess) && isstruct(sess.Display) && isfield(sess.Display, 'Gain')
                g = sess.Display.Gain;
                gam = sess.Display.Gamma;
            end
            g = g * obj.Gain;
            gam = gam * obj.Gamma;
        end

        function stepZoom(obj, dir)
            z = CellCurator.ZoomSteps;
            [~, i] = min(abs(z - obj.Zoom));
            j = min(numel(z), max(1, i + dir));
            if z(j) == obj.Zoom, return; end
            obj.Zoom = z(j);
            obj.Gallery.setZoom(obj.Zoom);   % re-pages through CapacityChangedFcn when the fit changes
            obj.rehover();                   % the tiles changed size under the pointer
            obj.setStatus(curation.UiText.msg('zoom', round(100 * obj.Zoom), obj.pageSize()));
        end
    end

    %% ======================================================================== deferred work
    methods (Access = private)
        function schedule(obj, what, delay)
            %SCHEDULE  Mark deferred work (prefetch, panels, inspector) and arm the idle timer.
            if nargin < 3, delay = CellCurator.IdleDelay; end
            for w = string(what)
                obj.Pending.(char(w)) = true;
            end
            obj.startIdleTimer(delay);
        end

        function startIdleTimer(obj, delay)
            if obj.Closed || obj.Closing, return; end
            t = obj.IdleTimer;
            if isempty(t) || ~isvalid(t)
                t = timer('Name', 'CellCurator idle', 'ExecutionMode', 'singleShot', ...
                    'ObjectVisibility', 'off', 'BusyMode', 'drop', 'TimerFcn', @(~, ~) obj.onIdle());
                obj.IdleTimer = t;
            end
            if strcmp(t.Running, 'on')
                % debounce: the deferred work runs once the input has paused for DELAY, never in
                % the middle of the next key's redraw
                stop(t);
            end
            t.StartDelay = max(0.001, round(delay, 3));
            start(t);
            obj.IdleArmed = tic;
            obj.IdleDue = t.StartDelay;
        end

        function rearmIdle(obj, delay)
            %REARMIDLE  From an idle step: run the idle step again in DELAY s, unless it is due sooner.
            t = obj.IdleTimer;
            if ~isempty(t) && isvalid(t) && strcmp(t.Running, 'on') && ~isempty(obj.IdleArmed)
                left = obj.IdleDue - toc(obj.IdleArmed);
                % still pending and due sooner: keep it (inside the timer's own callback it reads as
                % running with nothing left: that one is re-armed)
                if left > 0.005 && left <= delay, return; end
            end
            obj.startIdleTimer(delay);
        end

        function stopIdleTimer(obj)
            t = obj.IdleTimer;
            obj.IdleTimer = [];
            if ~isempty(t) && isvalid(t)
                try stop(t); catch, end
                try delete(t); catch, end
            end
        end

        function endOpening(obj)
            if isvalid(obj), obj.Opening = false; end
        end

        function onIdle(obj)
            if obj.Closed || obj.Closing || isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            if obj.Opening
                obj.rearmIdle(CellCurator.IdleDelay);     % let in by a component an open creates
                return
            end
            try
                obj.focusIfDue();
                pend = obj.Pending;
                obj.Pending = CellCurator.noPending();
                if pend.status && ~isempty(obj.PendingStatus)
                    obj.setStatus(obj.PendingStatus);
                end
                if pend.prefetch && obj.CenterView == "gallery", obj.prefetchNext(); end
                if pend.inspector, obj.refreshInspector(); end
                if pend.panels
                    obj.refreshPanels();
                elseif pend.undo
                    obj.updateUndoButtons();
                end
                if pend.locator, obj.refreshLocator(); end
                if pend.maplayout, obj.finishBarLayout(); end
                if pend.assist, obj.refreshAssistPanel(true); end
                if pend.final, obj.syncFinal(); end
                obj.maybeConfirmAudit();
                obj.maybeRecordDb();
                obj.maybeRescore();
                obj.maybeAssist();
                obj.maybePrepareMap();
                obj.maybePrepare();
            catch ME
                obj.reportError(ME);
            end
        end

        function [id, pg] = inspectedCell(obj)
            %INSPECTEDCELL  The cell the inspector shows: on the map the point under the pointer, else
            %   the (first) selected point; in the gallery the inspected tile. 0 when none.
            id = uint32(0);
            pg = NaN;
            if isempty(obj.Session) || isempty(obj.Store), return; end
            if obj.TextFocus && obj.NoteCell > 0 && any(obj.Store.get('CellID') == obj.NoteCell)
                id = obj.NoteCell;          % a note is being typed: its cell stays in the inspector
                r = obj.Store.rowsOf(id);
                pg = curation.Proposals.current(CellCurator.queueTable(obj.Store), obj.SourceKey);
                pg = pg(r);
                return
            end
            if obj.CenterView == "map"
                if obj.MapHover > 0
                    id = obj.MapHover;
                elseif ~isempty(obj.MapSelection)
                    id = obj.MapSelection(1);
                end
                if id > 0 && ~any(obj.Store.get('CellID') == id)
                    id = uint32(0);
                end
                if id > 0
                    T = CellCurator.queueTable(obj.Store);
                    r = obj.Store.rowsOf(id);
                    pg = curation.Proposals.current(T(r, :), obj.SourceKey);
                end
                return
            end
            k = obj.InspectedTile;
            P = obj.Page;
            if obj.isTilePage() && k >= 1 && k <= numel(P.Ids)
                id = P.Ids(k);
                if k <= numel(P.P), pg = P.P(k); end
            end
        end

        function refreshInspector(obj)
            imgs = obj.UI.InspImg;
            [id, pg] = obj.inspectedCell();
            if id == 0 || isempty(obj.Session.Cache) || obj.Session.Cache.rowsOf(id) == 0
                z = zeros(CellCurator.TileSide, CellCurator.TileSide, 3, 'uint8');
                for i = 1:3, imgs(i).CData = z; end
                obj.setText(obj.UI.Fields, curation.UiText.label('inspectEmpty'));
                if ~obj.TextFocus && ~isempty(obj.UI.Note.Value), obj.UI.Note.Value = ''; end
                return
            end
            c = obj.Session.Cache;
            modes = ["target" "companion" "overlay"];
            [gg, gm] = obj.displayGG();
            lv = obj.tileLevel();
            for i = 1:3
                s = struct('Mode', modes(i), 'Gain', gg, 'Gamma', gm, 'TileLevel', lv, 'BorderPx', 0);
                imgs(i).CData = c.compose(id, 1, 1, s);
            end
            st = obj.Store;
            g = @(f) st.get(f, id);
            S = curation.UiText.SEP;
            if obj.blindPending(id)
                % an audit tile: the crop, but no score, rescore, P or earlier label until it is decided
                flag = g('Flag');
                if flag == "", flag = "none"; end
                obj.setText(obj.UI.Fields, curation.UiText.msg('blindInspect', double(id), flag));
                if ~obj.TextFocus
                    note = char(g('Notes'));
                    if ~strcmp(obj.UI.Note.Value, note), obj.UI.Note.Value = note; end
                end
                return
            end
            lab = g('Label');
            if lab == "", lab = "(undecided)"; else, lab = lab + " (" + g('LabelSource') + ")"; end
            flag = g('Flag');
            if flag == "", flag = "none"; end
            extra = '';
            if g('Excluded'), extra = [extra '\nInside an exclusion region']; end
            if g('Origin') == "added", extra = [extra '\nAdded by hand']; end
            txt = sprintf(['Cell %d' S 'X %.1f' S 'Y %.1f\nscore %.3f' S 'rescore %.2f' S 'P(Good) %.2f\n' ...
                'Label: %s\nFlag: %s' extra], double(id), g('X'), g('Y'), g('score'), g('rescore'), pg, lab, flag);
            obj.setText(obj.UI.Fields, txt);
            if ~obj.TextFocus
                note = char(g('Notes'));
                if ~strcmp(obj.UI.Note.Value, note), obj.UI.Note.Value = note; end
            end
        end

        function refreshPanels(obj)
            %REFRESHPANELS  Queue counts, progress, pace, sections, undo state: after page changes.
            sess = obj.Session;
            M = @curation.UiText.msg;
            F = @CellCurator.fmtInt;
            obj.syncOpenCounts();
            if isempty(sess) || isempty(sess.Store)
                obj.refreshSections();
                obj.updateUndoButtons();
                return
            end
            st = sess.Store;
            T = CellCurator.queueTable(st);
            p = curation.Proposals.current(T, obj.SourceKey);
            S = curation.Queues.summary(T, p, obj.queueOpts(T));
            c = st.counts();
            obj.PairsCount = numel(obj.findPairs());
            pend = curation.BlindTiles.roleMask(T.AuditRole) & T.LabelSource ~= "blind";
            nb = @(lab) nnz(T.State == "active" & T.Reviewed & T.Label == lab & ~pend);
            n = [S.reviewRemaining, S.flagged, obj.PairsCount, S.vanishedGood, nb("Good"), nb("Bad"), ...
                nb("Uncertain"), NaN];
            items = CellCurator.queueItems(n, obj.sweepItemText());
            if ~isequal(obj.UI.Queues.Items, items)
                obj.UI.Queues.Items = items;
            end
            if ~strcmp(obj.UI.Queues.Value, obj.QueueName)
                obj.UI.Queues.Value = char(obj.QueueName);
            end
            if obj.UI.Finish.Visible == "on"
                obj.refreshFinish();
            end
            if S.blind > 0
                obj.setText(obj.UI.Bands, M('bandsBlind', F(S.bands.middleHigh + S.bands.middleLow), ...
                    F(S.bands.good), F(S.bands.bad), F(S.blind)));
            else
                obj.setText(obj.UI.Bands, M('bands', F(S.bands.middleHigh + S.bands.middleLow), ...
                    F(S.bands.good), F(S.bands.bad)));
            end

            % progress: this source, this section (all channels), the whole folder
            done = c.active - c.toReview;
            flagNote = '';
            if c.flagged > 0, flagNote = M('progFlagged', F(c.flagged)); end
            obj.setBar(obj.UI.ProgSource, obj.UI.ProgSourceText, done, c.active, ...
                @(a, b, pc) [M('progSource', obj.SourceKey, F(a), F(b), pc) flagNote]);
            d = obj.Datasets(obj.DatasetIndex);
            obj.setBar(obj.UI.ProgSection, obj.UI.ProgSectionText, sum([d.Sources.Done]), ...
                sum([d.Sources.Total]), @(a, b, pc) M('progSection', F(a), F(b), pc));
            [a, b] = obj.folderTotals();
            obj.setBar(obj.UI.ProgFolder, obj.UI.ProgFolderText, a, b, @(a, b, pc) M('progFolder', F(a), F(b), pc));

            % pace and time left (from the confirmed pages of this session)
            L = sess.PaceLog;
            if isempty(L)
                obj.setText(obj.UI.Pace, M('paceNone'));
            else
                L = L(max(1, end - CellCurator.PaceWindow + 1):end, :);
                [cpm, txt] = CellCurator.paceOf(L);
                left = S.reviewRemaining;
                if left == 0
                    obj.setText(obj.UI.Pace, M('paceDone', txt, size(L, 1), obj.SourceKey));
                else
                    obj.setText(obj.UI.Pace, M('pace', txt, size(L, 1), ...
                        CellCurator.durationText(left / max(cpm, eps)), obj.SourceKey));
                end
            end
            obj.refreshAssistPanel(true);
            obj.refreshRescoreControls(c.rescorePending);
            obj.refreshSections();
            obj.updateUndoButtons();
            obj.updateSourceButtons();
            obj.updateEditEnable();
            if obj.trainingShowing(), obj.Training.refresh(false); end
        end

        function tf = trainingShowing(obj)
            tf = ~isempty(obj.Training) && isvalid(obj.Training) && isfield(obj.UI, 'TabTraining') && ...
                obj.UI.Cheat.Visible == "off" && isequal(obj.UI.Tabs.SelectedTab, obj.UI.TabTraining);
        end

        function setBar(obj, bar, label, a, b, fmt)
            frac = 0;
            if b > 0, frac = min(1, max(0, a / b)); end
            w = {sprintf('%.4fx', max(frac, 1e-4)), sprintf('%.4fx', max(1 - frac, 1e-4))};
            if ~isequal(bar.ColumnWidth, w)
                bar.ColumnWidth = w;
            end
            obj.setText(label, fmt(a, b, round(100 * frac)));
        end

        function setText(~, h, txt)
            txt = char(txt);
            if ~strcmp(h.Text, txt)
                h.Text = txt;
            end
        end

        function refreshSections(obj)
            n = numel(obj.Datasets);
            if n == 0
                items = {curation.UiText.label('noSection')};
                data = {0};
            else
                items = cell(1, n);
                for k = 1:n
                    d = obj.Datasets(k);
                    tot = sum([d.Sources.Total]);
                    pc = 0;
                    if tot > 0, pc = round(100 * sum([d.Sources.Done]) / tot); end
                    done = logical([d.Sources.Complete]);
                    nm = d.Short;                                 % long real names: the list is narrow
                    if isempty(nm), nm = d.Base; end
                    if ~isempty(done) && all(done)
                        items{k} = curation.UiText.msg('sectionItemDone', nm, pc);
                    elseif any(done)
                        items{k} = curation.UiText.msg('sectionItemPart', nm, pc, ...
                            strjoin({d.Sources(done).Key}, ' '));
                    else
                        items{k} = curation.UiText.msg('sectionItem', nm, pc);
                    end
                end
                data = num2cell(1:n);
            end
            lb = obj.UI.Sections;
            if ~isequal(lb.Items, items) || ~isequal(lb.ItemsData, data)
                set(lb, 'Items', items, 'ItemsData', data);
            end
            v = obj.DatasetIndex;
            if n == 0 || v < 1, v = data{1}; end
            if ~isequal(lb.Value, v), lb.Value = v; end
        end

        function [a, b] = folderTotals(obj)
            a = 0; b = 0;
            for k = 1:numel(obj.Datasets)
                S = obj.Datasets(k).Sources;
                a = a + sum([S.Done]);
                b = b + sum([S.Total]);
            end
        end

        function syncOpenCounts(obj)
            %SYNCOPENCOUNTS  Live counts of the open sources into Datasets (for progress and "next").
            for k = 1:numel(obj.Sessions)
                obj.syncCounts(obj.Sessions{k});
            end
        end

        function syncCounts(obj, sess)
            if isempty(sess) || isempty(sess.Store) || ~isvalid(sess.Store), return; end
            [di, si] = obj.findSource(sess.Folder, sess.Base, sess.Key);
            if di == 0, return; end
            c = sess.Store.counts();
            obj.Datasets(di).Sources(si).Total = c.active;
            obj.Datasets(di).Sources(si).Done = c.active - c.toReview;
            obj.Datasets(di).Sources(si).Complete = logical(sess.Store.Meta.Complete);
        end

        function updateUndoButtons(obj)
            st = obj.Store;
            open = ~isempty(st) && isvalid(st);
            canU = open && st.CanUndo;
            canR = open && st.CanRedo;
            if ~open
                why = CellCurator.WhyNoSource;
                whyR = why;
            elseif st.ReadOnly
                why = obj.readOnlyWhy();
                whyR = why;
            else
                why = 'nothing to undo yet.';
                whyR = 'nothing to redo.';
            end
            obj.setEnable(obj.UI.Undo, canU, curation.UiText.tip('undo'), curation.UiText.disabled('undo', why));
            obj.setEnable(obj.UI.Redo, canR, curation.UiText.tip('redo'), curation.UiText.disabled('redo', whyR));
        end

        function updateEditEnable(obj)
            st = obj.Store;
            open = ~isempty(st) && isvalid(st);
            ro = ~open || st.ReadOnly;
            if ~open
                why = CellCurator.WhyNoSource;
            else
                why = obj.readOnlyWhy();
            end
            inMap = obj.CenterView == "map";
            ids = ["good" "bad" "uncertain" "flag" "clear" "confirm"];
            for b = obj.UI.ActionButtons
                act = extractAfter(string(b.Tag), "btn:");
                if inMap && any(act == ["confirm" "prev" "next"])      % page buttons: the gallery's
                    obj.setEnable(b, false, curation.UiText.tip(act), curation.UiText.disabled(act, CellCurator.WhyMap));
                elseif any(ids == act)
                    obj.setEnable(b, ~ro, curation.UiText.tip(act), curation.UiText.disabled(act, why));
                else      % navigation: needs a source, not a writable one
                    obj.setEnable(b, open, curation.UiText.tip(act), ...
                        curation.UiText.disabled(act, CellCurator.WhyNoSource));
                end
            end
            obj.setEnable(obj.UI.Note, ~ro, curation.UiText.tip('note'), curation.UiText.disabled('note', why));
            % the map: Select needs a source; the editing tools a writable one
            T = @curation.UiText.tip;
            Dz = @curation.UiText.disabled;
            obj.setEnable(obj.UI.View, open, T('toggleView'), Dz('toggleView', CellCurator.WhyNoSource));
            if ~open
                whyShow = CellCurator.WhyNoSource;
            else
                whyShow = CellCurator.WhyOnMap;
            end
            obj.setEnable(obj.UI.ShowOnMap, open && ~inMap, T('showOnMap'), Dz('showOnMap', whyShow));
            names = ["toolSelect" "toolAdd" "toolMove" "toolLasso"];
            for i = 1:numel(names)
                on = open && (i == 1 || ~ro);
                obj.setEnable(obj.UI.ToolButtons(i), on, T(names(i)), Dz(names(i), why));
            end
            obj.setEnable(obj.UI.FitMap, open, T('fitMap'), Dz('fitMap', CellCurator.WhyNoSource));
        end

        function setEnable(~, h, on, tipOn, tipOff)
            want = matlab.lang.OnOffSwitchState(on);
            if h.Enable ~= want, h.Enable = want; end
            if on, t = tipOn; else, t = tipOff; end
            if ~strcmp(h.Tooltip, t), CellToolkit.setTooltip(h, t); end
        end

        function refreshDatasetControls(obj)
            n = numel(obj.Datasets);
            dd = obj.UI.Dataset;
            if n == 0
                set(dd, 'Items', {curation.UiText.label('noSection')}, 'ItemsData', {0}, 'Value', 0);
            else
                names = {obj.Datasets.Short};
                set(dd, 'Items', names, 'ItemsData', num2cell(1:n), 'Value', 1);
            end
            obj.refreshSections();
        end

        function rebuildSourceButtons(obj)
            old = obj.UI.SourceButtons;
            obj.UI.SourceButtons = gobjects(0);
            for k = 1:numel(old)
                if isvalid(old(k)), delete(old(k)); end
            end
            if obj.DatasetIndex < 1, return; end
            S = obj.Datasets(obj.DatasetIndex).Sources;
            n = numel(S);
            obj.UI.SourceGrid.ColumnWidth = repmat({'1x'}, 1, max(1, n));
            bs = gobjects(1, n);
            for i = 1:n
                bs(i) = uibutton(obj.UI.SourceGrid, 'Text', S(i).Key, 'Tag', ['src:' S(i).Key], ...
                    'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.onSourceButton(i)));
                bs(i).Layout.Row = 1;
                bs(i).Layout.Column = i;
            end
            obj.UI.SourceButtons = bs;
            obj.updateSourceButtons();
        end

        function updateSourceButtons(obj)
            bs = obj.UI.SourceButtons;
            if isempty(bs) || obj.DatasetIndex < 1, return; end
            S = obj.Datasets(obj.DatasetIndex).Sources;
            for i = 1:min(numel(bs), numel(S))
                b = bs(i);
                if ~isvalid(b), continue; end
                left = curation.UiText.msg('sourceLeft', CellCurator.fmtInt(max(0, S(i).Total - S(i).Done)));
                pg = num2str(S(i).Page);
                active = i == obj.SourceIndex;
                if active
                    t = curation.UiText.tip('sourceActive', S(i).Key, pg, left);
                    bgc = [0.80 0.88 0.98]; fw = 'bold';
                else
                    t = curation.UiText.tip('source', S(i).Key, pg, left);
                    bgc = [0.96 0.96 0.96]; fw = 'normal';
                end
                if ~strcmp(b.Tooltip, t), CellToolkit.setTooltip(b, t); end
                if ~isequal(b.BackgroundColor, bgc), b.BackgroundColor = bgc; end
                if ~strcmp(b.FontWeight, fw), b.FontWeight = fw; end
                txt = S(i).Key;
                if S(i).Complete, txt = [txt ' ' curation.UiText.CHECK]; end
                if ~strcmp(b.Text, txt), b.Text = txt; end
            end
        end
    end

    %% ======================================================================== assist model, audit tiles, report
    methods
        function requestReport(obj)
            %REQUESTREPORT  The Audit report... button: build curation.Audit.report of the folder off
            %   the key path; it appears in the Audit tab when ready.
            if obj.Closed, return; end
            M = @curation.UiText.msg;
            r = obj.Assist;
            if isempty(r)
                obj.setStatus(M('assistOff'));
                return
            end
            if r.IndexState == "none", r.start(); end
            r.requestReport();
            obj.setStatus(M('reportBuilding'));
            obj.rearmIdle(CellCurator.AssistPollSec);
        end

        function files = saveReport(obj)
            %SAVEREPORT  The Save report button: .cellcuration\audit_report_<yyyymmdd_HHMMSS>.txt (the
            %   text) and .csv (one row per channel kind), plus _sections.csv and _bands.csv (the
            %   per-section and per-band tables). FILES: the paths written.
            files = strings(0, 1);
            if obj.Closed, return; end
            M = @curation.UiText.msg;
            R = obj.AuditReport;
            if isempty(R) || ~isstruct(R) || isempty(R.Report)
                obj.setStatus(M('reportNone'));
                return
            end
            try
                folder = fullfile(obj.ParentDir, '.cellcuration');
                if ~isfolder(folder), mkdir(folder); end
                base = ['audit_report_' char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))];
                txt = fullfile(folder, [base '.txt']);
                lines = ["Audit report of " + string(obj.ParentDir); "Built " + string(R.Generated); ""];
                for k = 1:numel(R.Text)
                    lines = [lines; R.Text(k); ""]; %#ok<AGROW>
                end
                fid = fopen(txt, 'w', 'n', 'UTF-8');
                if fid < 0, error('CellCurator:report', 'Cannot write %s.', txt); end
                fprintf(fid, '%s\n', lines);
                fclose(fid);
                files(end + 1, 1) = string(txt);
                csv = fullfile(folder, [base '.csv']);
                writetable(R.Report.Table, csv);
                files(end + 1, 1) = string(csv);
                K = R.Report.Kinds;
                for part = ["BySection" "ConfirmByBand"]
                    parts = {};
                    for i = 1:numel(K)
                        T = K(i).(part);
                        if isempty(T) || height(T) == 0, continue; end
                        T = [table(repmat(string(K(i).Kind), height(T), 1), 'VariableNames', {'Kind'}) T]; %#ok<AGROW>
                        parts{end + 1} = T; %#ok<AGROW>
                    end
                    if isempty(parts), continue; end
                    suffix = '_sections';
                    if part == "ConfirmByBand", suffix = '_bands'; end
                    p = fullfile(folder, [base suffix '.csv']);
                    writetable(vertcat(parts{:}), p);
                    files(end + 1, 1) = string(p);
                end
            catch ME
                obj.reportError(ME);
                return
            end
            obj.setStatus(M('reportSaved', folder, [base '.txt'], [base '.csv']));
        end

        function waitForAssist(obj, timeout)
            %WAITFORASSIST  (tests) Run the assist runner's idle steps until it has nothing in flight
            %   and every open source was handed to it (up to TIMEOUT s, default 120).
            if nargin < 2, timeout = 120; end
            r = obj.Assist;
            if isempty(r) || obj.Closed, return; end
            if r.IndexState == "none", r.start(); end
            t0 = tic;
            while toc(t0) < timeout && ~obj.Closed
                obj.maybeAssist(true);
                drawnow;
                waiting = ~isempty(obj.HoldoutDue);     % a holdout list waits for a quiet moment
                for k = 1:numel(obj.Sessions)
                    s = obj.Sessions{k};
                    waiting = waiting || (~s.Registered && ~isempty(s.PageT)) || ~r.isSettled(s.Id);
                end
                if ~r.isBusy() && ~waiting && r.secondsToNextStep(Inf) > 0, break; end
                pause(0.1);
            end
            obj.maybeAssist(true);
            drawnow;
        end

        function requestRescore(obj)
            %REQUESTRESCORE  Rescore now (finish checklist) / Score edited cells (left panel): the
            %   cells of the source on screen that a person added or moved (store.rescorePending)
            %   get their Stage-2 score with curation.RescoreRunner: the image is prepared at the
            %   next idle moment, score.py runs in the background, the scores are stored between
            %   pages (never inside a tile drag; a cell moved meanwhile keeps waiting).
            if obj.Closed, return; end
            M = @curation.UiText.msg;
            st = obj.Store;
            if isempty(st) || ~isvalid(st)
                obj.setStatus(M('mapNoSource'));
                return
            end
            if st.ReadOnly
                obj.setStatus(M('rescoreReadOnly'));
                return
            end
            r = obj.rescorer();
            if r.isRunning() || obj.RescoreWanted
                obj.setStatus(M('rescoreBusy'));
                return
            end
            [ok, why] = r.pythonReady();
            if ~ok
                obj.setStatus(M('rescoreNoPython', why));
                return
            end
            n = numel(st.rescorePending());
            if n == 0
                obj.setStatus(M('rescoreNone', obj.SourceKey));
                return
            end
            m = obj.rescoreModel(obj.Session.Kind);
            obj.RescoreWanted = true;
            obj.RescoreStore = st;
            txt = M('rescoreStart', CellCurator.fmtInt(n), CellCurator.plural(n, 'cell', 'cells'), m.Name);
            obj.setStatus(txt);
            obj.RescoreShown = txt;
            obj.refreshRescoreControls();
            obj.schedule("rescore", 0.05);
        end

        function waitForRescore(obj, timeout)
            %WAITFORRESCORE  (tests) Run the rescore's idle steps until its scores are stored (or it
            %   failed), up to TIMEOUT s (default 120).
            if nargin < 2, timeout = 120; end
            t0 = tic;
            while toc(t0) < timeout && ~obj.Closed
                obj.maybeRescore();
                drawnow;
                r = obj.Rescorer;
                if ~obj.RescoreWanted && (isempty(r) || any(r.State == ["idle" "failed"])), break; end
                pause(0.1);
            end
            drawnow;
        end

        function showTraining(obj)
            %SHOWTRAINING  The Training... button: the Training tab on the right, its counts brought up
            %   to date (no export, no training starts here).
            if obj.Closed, return; end
            t0 = tic;
            if obj.UI.Cheat.Visible == "on", obj.toggleHelp(false); end
            obj.UI.Tabs.SelectedTab = obj.UI.TabTraining;
            obj.onRightTab();
            obj.LastTimings.TrainingTabMs = 1000 * toc(t0);
        end
    end

    methods (Access = private)
        function r = rescorer(obj)
            if isempty(obj.Rescorer) || ~isvalid(obj.Rescorer)
                obj.Rescorer = curation.RescoreRunner(obj.Options.RescoreOptions);
            end
            r = obj.Rescorer;
        end

        function m = rescoreModel(obj, kind)
            %RESCOREMODEL  The scorer the rescore uses for KIND (curation.RescoreRunner.defaultModel;
            %   looked up at most every 10 s: a fine-tune may deploy a new one).
            kind = string(kind);
            if ~ismember(kind, ["pnn" "pv"]), kind = "pnn"; end
            C = obj.RescoreModels;
            if isfield(C, char(kind)) && toc(C.(char(kind)).Tic) < 10
                m = C.(char(kind)).M;
                return
            end
            o = obj.Options.RescoreOptions;
            if isfield(o, 'Model') && strlength(string(o.Model)) > 0
                [~, nm] = fileparts(char(o.Model));
                m = struct('Name', string(nm), 'Path', string(o.Model), 'Curated', false);
                why = "the scorer this window was given (" + string(nm) + ")";
            else
                repo = "";
                if isfield(o, 'RepoRoot'), repo = string(o.RepoRoot); end
                [m, why] = curation.RescoreRunner.defaultModel(kind, repo);
            end
            m.Why = string(why);
            C.(char(kind)) = struct('M', m, 'Tic', tic);
            obj.RescoreModels = C;
        end

        function t = rescoreTip(obj, id, why)
            %RESCORETIP  The tooltip of a rescore control: what it does, the scorer it uses, why it is
            %   off (WHY, '' when on).
            kind = "pnn";
            if ~isempty(obj.Session), kind = obj.Session.Kind; end
            m = obj.rescoreModel(kind);
            py = '';
            if ~isempty(obj.Rescorer) && isvalid(obj.Rescorer)
                [ok, w] = obj.Rescorer.pythonReady();
                if ~ok, py = char(w); end
            end
            t = curation.UiText.tip(id, char(m.Why), py);
            if ~isempty(why)
                t = [t ' ' char(8212) ' unavailable now: ' char(why)];
            end
        end

        function refreshRescoreControls(obj, n)
            %REFRESHRESCORECONTROLS  The left panel's Score edited cells button and the finish row:
            %   how many cells wait for a score, whether a rescore runs, why they are off.
            M = @curation.UiText.msg;
            U = @curation.UiText.label;
            st = obj.Store;
            open = ~isempty(st) && isvalid(st);
            if nargin < 2
                n = 0;
                if open, n = numel(st.rescorePending()); end
            end
            obj.rescorer();
            running = obj.RescoreWanted || obj.Rescorer.isRunning() || obj.Rescorer.hasResults();
            [pyOk, pyWhy] = obj.Rescorer.pythonReady();
            why = '';
            if ~open
                why = CellCurator.WhyNoSource;
            elseif st.ReadOnly
                why = obj.readOnlyWhy();
            elseif running
                why = 'a rescore is running (the status bar shows it).';
            elseif n == 0
                why = 'every cell has a score for its position.';
            elseif ~pyOk
                why = char(pyWhy);
            end
            b = obj.UI.RescoreButton;
            if running
                txt = U('rescoreRunning');
            else
                txt = U('rescoreEdited', CellCurator.fmtInt(n));
            end
            obj.setText(b, txt);
            obj.setEnable(b, isempty(why), obj.rescoreTip('rescoreEdited', ''), obj.rescoreTip('rescoreEdited', why));
            % the finish checklist's row (optional: it never blocks completing)
            f = obj.UI.FinRescore;
            if n == 0
                txt = M('finDone', M('finRescore', M('finOk')));
                bgc = [0.17 0.30 0.23]; fc = [0.86 0.96 0.89];
            elseif running
                txt = M('finRescoreBusy', M('finRescore', CellCurator.fmtInt(n)));
                bgc = [0.96 0.96 0.96]; fc = [0.10 0.10 0.10];
            else
                txt = M('finRescore', M('finOpen', CellCurator.fmtInt(n), M('finActRescore')));
                bgc = [0.96 0.96 0.96]; fc = [0.10 0.10 0.10];
            end
            obj.setText(f, txt);
            tip = obj.rescoreTip('finishRescore', why);
            obj.setEnable(f, true, tip, tip);           % readable in every state; a click says why
            if ~isequal(f.BackgroundColor, bgc), f.BackgroundColor = bgc; end
            if ~isequal(f.FontColor, fc), f.FontColor = fc; end
        end

        function maybeRescore(obj)
            %MAYBERESCORE  An idle step of the rescore: start it (the image preparation blocks for a
            %   moment, after the click, never on a key), follow score.py, and store the scores
            %   between pages (backgroundWriteOk; a drag defers them). Progress goes to the status
            %   bar unless something else was said there since.
            r = obj.Rescorer;
            if isempty(r) || ~isvalid(r), return; end
            M = @curation.UiText.msg;
            if obj.RescoreWanted
                obj.RescoreWanted = false;
                st = obj.RescoreStore;
                obj.RescoreStore = [];
                kind = "pnn";
                sess = obj.sessionOfStore(st);
                if ~isempty(sess), kind = sess.Kind; end
                if ~isempty(st) && isvalid(st)
                    t0 = tic;
                    ok = r.start(st, kind);
                    obj.LastTimings.RescorePrepareMs = 1000 * toc(t0);
                    if ~ok
                        obj.setStatus(r.Message);
                        obj.refreshRescoreControls();
                        return
                    end
                end
            end
            switch r.State
                case "running"
                    r.poll();
                    if r.State == "running"
                        obj.rescoreProgress(r.Message);
                        obj.rearmIdle(0.5);
                        return
                    end
            end
            if r.State == "ready"
                if ~obj.backgroundWriteOk() && ~isempty(obj.Store) && isequal(r.Store, obj.Store)
                    if obj.Store.InBatch || obj.DragBatch, obj.rescoreProgress(M('rescoreDeferred')); end
                    obj.rearmIdle(0.3);
                    return
                end
                t0 = tic;
                rep = r.apply();
                if rep.Deferred
                    obj.rescoreProgress(M('rescoreDeferred'));
                    obj.rearmIdle(0.3);
                    return
                end
                obj.NextPage = [];
                obj.FinishCache = [];
                if obj.UI.Finish.Visible == "on", obj.refreshFinish(); end
                obj.refreshRescoreControls();
                obj.LastTimings.ApplyRescoreMs = 1000 * toc(t0);
                obj.Counters.RescoreApplies = obj.Counters.RescoreApplies + 1;
                obj.setStatus(r.Message);
                obj.RescoreShown = '';
                obj.schedule(["prefetch" "panels"]);
            elseif r.State == "failed"
                obj.setStatus(r.Message);
                obj.RescoreShown = '';
                r.cancel();
                obj.refreshRescoreControls();
            end
        end

        function rescoreProgress(obj, txt)
            %RESCOREPROGRESS  Rescore progress in the status bar, unless another message replaced the
            %   last progress line meanwhile (a label's message is not overwritten).
            txt = char(txt);
            cur = char(obj.StatusText);
            if isempty(obj.RescoreShown) || strcmp(cur, obj.RescoreShown)
                if ~strcmp(cur, txt), obj.setStatus(txt); end
                obj.RescoreShown = txt;
            end
        end

        function sess = sessionOfStore(obj, st)
            sess = [];
            for k = 1:numel(obj.Sessions)
                if ~isempty(obj.Sessions{k}.Store) && isequal(obj.Sessions{k}.Store, st)
                    sess = obj.Sessions{k};
                    return
                end
            end
        end


        function k = currentKind(obj)
            k = "pnn";
            if ~isempty(obj.Session), k = obj.Session.Kind; end
        end

        function L = liveSources(obj)
            %LIVESOURCES  (the Training tab, at an idle moment) The open sources as their stores hold
            %   them now: what the tab recounts from memory after a confirmed page or a completion.
            L = struct('SourceId', {}, 'Cols', {}, 'Complete', {}, 'SweepDone', {});
            if obj.Closed || obj.Closing, return; end
            names = ["State" "Reviewed" "LabelSource" "Label" "Excluded" "Flag" "AuditRole"];
            for k = 1:numel(obj.Sessions)
                s = obj.Sessions{k};
                st = s.Store;
                if isempty(st) || ~isvalid(st), continue; end
                C = struct();
                for f = names
                    C.(f) = st.get(f);
                end
                L(end + 1) = struct('SourceId', string(s.SourceId), 'Cols', C, ... %#ok<AGROW>
                    'Complete', logical(st.Meta.Complete), 'SweepDone', logical(st.Meta.SweepDone));
            end
        end

        function maybeAssist(obj, force)
            %MAYBEASSIST  An idle step of the assist runner: collect what finished (the project read,
            %   holdout lists, fits, predictions, a report) and apply it between pages: holdout roles
            %   and new predictions go to the stores (the page on screen keeps its tiles and default;
            %   the prefetched next page is dropped so the pages after it follow the model).
            if nargin < 2, force = false; end
            r = obj.Assist;
            if isempty(r) || obj.Closed || obj.Closing, return; end
            if obj.InAssist
                % re-entered (a background call let a timer run): the outer step goes on
                obj.rearmIdle(CellCurator.AssistPollSec);
                return
            end
            obj.InAssist = true;
            c = onCleanup(@() obj.leaveAssist());
            idle = toc(obj.LastInputTic);
            if r.IndexState == "none"
                if isempty(obj.Session), return; end
                if idle < CellCurator.AssistStartSec && ~force
                    obj.rearmIdle(CellCurator.AssistStartSec - idle + 0.05);
                    return
                end
                r.start();
            end
            if obj.DragBatch && ~force
                obj.rearmIdle(CellCurator.AssistPollSec);
                return
            end
            stepIdle = idle;
            if force, stepIdle = Inf; end           % (tests) as if the person had paused long enough
            ev = r.step(stepIdle);
            obj.registerSessions();
            msg = "";
            if ev.Index && ~obj.AssistAnnounced && ~isempty(r.Index)
                obj.AssistAnnounced = true;          % once per folder: the project was read in the background
                msg = string(curation.UiText.msg('assistRead', height(r.Index.Sources)));
            end
            obj.HoldoutDue = unique([obj.HoldoutDue, ev.Holdout]);
            % the app's own writes wait while the reviewer has a batch open and just after input
            if obj.backgroundWriteOk()
                if ~isempty(obj.HoldoutDue)
                    due = obj.HoldoutDue;
                    obj.HoldoutDue = strings(1, 0);
                    for k = 1:numel(obj.Sessions)
                        s = obj.Sessions{k};
                        if ~any(due == s.Kind), continue; end
                        if s == obj.Session
                            note = obj.applyHoldoutTo(s, obj.Page.Ids);   % never on the page on screen
                            if strlength(note) > 0, msg = strtrim(msg + " " + note); end
                        else
                            obj.applyHoldoutTo(s);
                        end
                    end
                end
                for k = 1:numel(obj.Sessions)
                    obj.applyPredictions(obj.Sessions{k});
                end
            else
                obj.rearmIdle(CellCurator.AssistPollSec);
            end
            if ev.Report, obj.showReport(); end
            if strlength(msg) > 0, obj.setStatus(msg); end
            if ev.Index || ~isempty(ev.Fitted) || ~isempty(ev.Predictions) || ~isempty(ev.Holdout)
                obj.refreshAssistPanel();
            end
            if r.isBusy() || ev.Busy
                obj.rearmIdle(CellCurator.AssistPollSec);
            else
                wait = r.secondsToNextStep(idle);
                if isfinite(wait), obj.rearmIdle(max(CellCurator.AssistPollSec, wait)); end
            end
        end

        function leaveAssist(obj)
            if isvalid(obj), obj.InAssist = false; end
        end

        function stopAssist(obj)
            r = obj.Assist;
            obj.Assist = [];
            if ~isempty(r) && isvalid(r)
                try r.close(); catch, end
                try delete(r); catch, end
            end
        end

        function registerSessions(obj)
            %REGISTERSESSIONS  Hand the open sources (their rows and pages, already in memory) to the
            %   runner: their features and predictions are computed in the background. The source on
            %   screen first; one source per idle step (the pages are copied to the worker).
            r = obj.Assist;
            if isempty(r) || r.IndexState == "none", return; end
            order = 1:numel(obj.Sessions);
            for k = order
                s = obj.Sessions{k};
                if s.Registered || isempty(s.Store) || ~isvalid(s.Store) || isempty(s.PageT), continue; end
                if isempty(s.ImagePath) || ~isfile(s.ImagePath), s.Registered = true; continue; end
                st = s.Store;
                rows = table(st.get('CellID'), st.get('X'), st.get('Y'), st.get('score'), st.get('rescore'), ...
                    st.get('InLocs'), 'VariableNames', {'CellID', 'X', 'Y', 'score', 'rescore', 'InLocs'});
                ok = all(isfinite([rows.X rows.Y]), 2);
                info = struct('SourceId', s.SourceId, 'Kind', s.Kind, 'Rows', rows(ok, :), 'PageT', s.PageT, ...
                    'PageC', s.PageC, 'Um', CellCurator.umOf(st));
                r.register(s.Id, info);
                s.Registered = true;
                return
            end
        end

        function applyPredictions(obj, sess)
            %APPLYPREDICTIONS  New predictions of SESS's source into its store (setModel: not undoable,
            %   not journaled). The page on screen is not touched; the next page is computed again.
            r = obj.Assist;
            if isempty(r) || isempty(sess) || isempty(sess.Store) || ~isvalid(sess.Store) || sess.Store.ReadOnly
                return
            end
            [ok, P] = r.takePredictions(sess.Id);
            if ~ok, return; end
            t0 = tic;
            st = sess.Store;
            keep = ismember(P.Ids, st.get('CellID'));
            if any(keep)
                st.setModel(P.Ids(keep), P.P(keep), P.Version);
            end
            num = max(1, r.summary(sess.Kind).Number);
            sess.ModelNumber = num;
            if sess == obj.Session
                obj.NextPage = [];
                obj.schedule(["prefetch" "panels"]);
                obj.setStatus(curation.UiText.msg('modelApplied', num));
            end
            obj.LastTimings.ApplyModelMs = 1000 * toc(t0);
            obj.Counters.ModelApplies = obj.Counters.ModelApplies + 1;
        end

        function note = applyHoldoutTo(obj, sess, notIds)
            %APPLYHOLDOUTTO  The holdout rows of SESS's source get the role "holdout" (idempotent;
            %   listed rows that no longer exist, or were reviewed since, are skipped and counted).
            %   NOTIDS (the tiles on screen) are left as they are: the page on screen never changes.
            if nargin < 3, notIds = zeros(0, 1, 'uint32'); end
            note = "";
            r = obj.Assist;
            if isempty(r) || isempty(sess) || isempty(sess.Store) || ~isvalid(sess.Store) || sess.Store.ReadOnly
                return
            end
            L = r.holdout(sess.Kind);
            if isempty(L), return; end
            if ~isempty(notIds)
                L = L(~ismember(L.CellID, uint32(notIds)) | lower(L.SourceId) ~= lower(sess.SourceId), :);
            end
            try
                rep = curation.BlindTiles.applyHoldout(sess.Store, sess.SourceId, L);
            catch ME
                obj.reportError(ME);
                return
            end
            if rep.Applied == 0 && rep.Gone == 0, return; end
            obj.Counters.HoldoutApplied = obj.Counters.HoldoutApplied + rep.Applied;
            gone = '';
            if rep.Gone > 0, gone = curation.UiText.msg('holdoutGone', CellCurator.fmtInt(rep.Gone)); end
            note = string(curation.UiText.msg('holdoutApplied', CellCurator.auditText(rep.Applied), gone));
            if sess == obj.Session && rep.Applied > 0
                obj.NextPage = [];
                obj.schedule(["prefetch" "panels"]);
            end
        end

        function showReport(obj)
            %SHOWREPORT  A report built by the runner: into the Audit tab, which comes to the front.
            [ok, R] = obj.Assist.takeReport();
            if ~ok, return; end
            obj.AuditReport = R;
            v = reshape([R.Text(:)'; strings(1, numel(R.Text))], [], 1);
            obj.UI.AuditText.Value = cellstr(v);
            [~, nm] = fileparts(obj.ParentDir);
            obj.setText(obj.UI.AuditWhen, curation.UiText.msg('reportGenerated', nm, R.Generated));
            canSave = isstruct(R) && ~isempty(R.Report);
            obj.setEnable(obj.UI.SaveReport, canSave, curation.UiText.tip('saveReport'), ...
                curation.UiText.disabled('saveReport', curation.UiText.msg('reportNone')));
            if obj.UI.Cheat.Visible == "on", obj.toggleHelp(false); end
            obj.showRightTab("audit");
            obj.setStatus(curation.UiText.msg('reportReady'));
        end

        function refreshAssistPanel(obj, live)
            %REFRESHASSISTPANEL  The Assist block: what the proposals come from, the model's accuracy
            %   against the rescore baseline, the agreement on blind (audit) decisions. LIVE (after a
            %   confirmed page, deferred and coalesced): the label counts of the sources open here
            %   are taken from their stores now, not from the folder's last read (up to RefreshSec old).
            if nargin < 2, live = false; end
            if ~isfield(obj.UI, 'AssistSource') || ~isvalid(obj.UI.AssistSource), return; end
            M = @curation.UiText.msg;
            F = @CellCurator.fmtInt;
            r = obj.Assist;
            if isempty(r)
                src = M('assistOff');
                acc = M('assistAucNone');
                agr = M('assistAgreeFew', 0);
            else
                kind = "pnn";
                if strlength(obj.SourceKey) > 0, kind = curation.Proposals.kindOf(obj.SourceKey); end
                if live
                    s = r.summary(kind, obj.liveLabelCounts(kind));
                else
                    s = r.summary(kind);
                end
                if s.Mode == "model"
                    refit = '';
                    if s.Refitting, refit = M('assistRefitting'); end
                    src = M('assistModel', s.Number, F(s.NTrain), ...
                        [F(s.NSections) ' ' CellCurator.plural(s.NSections, 'section', 'sections')], ...
                        [F(s.NAnimals) ' ' CellCurator.plural(s.NAnimals, 'animal', 'animals')], refit);
                    if isfinite(s.AUCRescore)
                        acc = M('assistAuc', s.AUC, s.AUCRescore);
                    else
                        acc = M('assistAucNoBase', s.AUC);
                    end
                elseif any(s.IndexState == ["none" "reading"])
                    src = M('assistReading');
                    acc = M('assistAucNone');
                else
                    src = M('assistCold', s.MinLabels, s.MinPerClass, F(s.Labels), F(s.Good), F(s.Bad));
                    if s.Refitting, src = [src M('assistRefitting')]; end
                    acc = M('assistAucNone');
                end
                if s.BlindN < 30
                    agr = M('assistAgreeFew', s.BlindN);
                else
                    agr = M('assistAgree', F(s.BlindN), round(100 * s.BlindMatch / s.BlindN));
                end
            end
            obj.setText(obj.UI.AssistSource, src);
            obj.setText(obj.UI.AssistAccuracy, acc);
            obj.setText(obj.UI.AssistAgreement, agr);
        end

        function L = liveLabelCounts(obj, kind)
            %LIVELABELCOUNTS  Training labels (curation.AssistModel.trainingMask) of the open sources
            %   of KIND, from their stores: SourceId, NTrain, NGood, NBad.
            L = struct('SourceId', {}, 'NTrain', {}, 'NGood', {}, 'NBad', {});
            for k = 1:numel(obj.Sessions)
                s = obj.Sessions{k};
                if s.Kind ~= kind || isempty(s.Store) || ~isvalid(s.Store), continue; end
                T = s.Store.T;
                m = curation.AssistModel.trainingMask(T);
                g = m & T.Label == "Good";
                L(end + 1) = struct('SourceId', s.SourceId, 'NTrain', nnz(m), 'NGood', nnz(g), ...
                    'NBad', nnz(m & ~g)); %#ok<AGROW>
            end
        end

        function ids = confirmAuditNow(obj, notIds, system)
            %CONFIRMAUDITNOW  When the ordinary review queue of the source on screen has just run out:
            %   draw its confirm audit (curation.BlindTiles, once per source) and give those rows the
            %   role confirm-audit, never to NOTIDS (the page on screen). SYSTEM false: inside the
            %   Enter's batch (one undo step with the confirmation: undoing the Enter removes the
            %   roles with it); true: on its own from an idle step, with the store's system form (no
            %   undo step). The cheap test (any ordinary row left) runs first.
            ids = zeros(0, 1, 'uint32');
            if nargin < 2, notIds = zeros(0, 1, 'uint32'); end
            if nargin < 3, system = true; end
            if ~obj.Options.ConfirmAudit || isempty(obj.Session) || isempty(obj.Store), return; end
            st = obj.Store;
            if st.ReadOnly || logical(st.Meta.Complete), return; end
            left = st.get('State') == "active" & ~st.get('Reviewed') & ~st.get('Excluded') & ...
                st.get('Label') == "" & st.get('Flag') == "" & st.get('AuditRole') == "";
            if any(left), return; end
            T = CellCurator.queueTable(st);
            if ~curation.BlindTiles.needsConfirmAudit(T, false), return; end
            ids = curation.BlindTiles.confirmAuditIds(T, obj.Session.SourceId);
            ids = ids(~ismember(ids, uint32(notIds)));
            if isempty(ids), return; end
            st.setAuditRole(ids, "confirm-audit", struct('Queue', "audit", 'System', logical(system)));
            obj.Notice = curation.UiText.msg('confirmAudit', obj.SourceKey, CellCurator.tilesText(numel(ids)));
        end

        function n = clearOrphanAudit(obj)
            %CLEARORPHANAUDIT  After an undo (and when a source opens): a confirm-audit row whose
            %   confirmed label is gone (curation.BlindTiles.orphanConfirmAudit) loses its role, with
            %   the store's system form, so it is never shown as an audit tile of a confirmation the
            %   reviewer took back. Roles drawn in the Enter's own transaction go with its undo.
            n = 0;
            st = obj.Store;
            if isempty(st) || ~isvalid(st) || st.ReadOnly || st.InBatch, return; end
            ids = curation.BlindTiles.orphanConfirmAudit(CellCurator.queueTable(st));
            if isempty(ids), return; end
            st.setAuditRole(ids, "", struct('Queue', "audit", 'System', true));
            n = numel(ids);
            obj.Counters.OrphanRolesCleared = obj.Counters.OrphanRolesCleared + n;
        end

        function tf = backgroundWriteOk(obj)
            %BACKGROUNDWRITEOK  A write the app makes on its own (holdout and confirm-audit roles,
            %   predictions, scores) waits while the reviewer has a batch open (a tile drag) and for
            %   IdleDelay after the last input, so it never joins or interrupts the reviewer's action.
            st = obj.Store;
            tf = ~isempty(st) && isvalid(st) && ~st.ReadOnly && ~st.InBatch && ~obj.DragBatch && ...
                toc(obj.LastInputTic) >= CellCurator.IdleDelay;
        end

        function maybeConfirmAudit(obj)
            %MAYBECONFIRMAUDIT  An idle step: the ordinary queue ran out without an Enter (labels on the
            %   map, the Flagged queue, a source opened with nothing left): draw the confirm audit now.
            if ~obj.Options.ConfirmAudit || isempty(obj.Session) || isempty(obj.Store), return; end
            st = obj.Store;
            if st.ReadOnly || logical(st.Meta.Complete), return; end
            left = st.get('State') == "active" & ~st.get('Reviewed') & ~st.get('Excluded') & ...
                st.get('Label') == "" & st.get('Flag') == "" & st.get('AuditRole') == "";
            if any(left) || any(st.get('AuditRole') == "confirm-audit"), return; end   % nothing to draw
            if ~obj.backgroundWriteOk()
                obj.rearmIdle(0.3);      % a drag (or a key just now): draw at the next quiet moment
                return
            end
            try
                ids = obj.confirmAuditNow(obj.Page.Ids, true);  % never a tile of the page on screen
            catch ME
                obj.reportError(ME);
                return
            end
            if isempty(ids), return; end
            obj.FinishCache = [];
            obj.NextPage = [];
            if obj.Page.Kind == "empty" && obj.QueueName == "review" && obj.CenterView == "gallery"
                obj.showFinish();
            end
            obj.updateContext();
            obj.schedule("panels");
            obj.setStatus('');
        end

        function tf = blindRole(obj, ids)
            %BLINDROLE  Cells IDS (column) whose audit role makes them blind (decided or not).
            tf = curation.BlindTiles.roleMask(obj.Store.get('AuditRole', ids));
        end

        function tf = blindPending(obj, ids)
            %BLINDPENDING  Cells IDS (column) that are audit tiles waiting for their blind judgment.
            tf = obj.blindRole(ids) & obj.Store.get('LabelSource', ids) ~= "blind";
        end

        function onFinishRow(obj, queue, field)
            F = obj.finishState();
            if F.(field) == 0
                obj.setStatus(curation.UiText.msg('finNothingHere'));
                return
            end
            obj.onQueueChosen(queue);
        end

        function openDatabase(obj)
            %OPENDATABASE  The Database... button: the lab database's window (celldb.openWindow);
            %   without the client, the reason goes to the status bar (no dialog in the review flow).
            try
                [ok, why] = celldb.available();
                if ~ok
                    obj.setStatus(curation.UiText.msg('dbMissing', char(string(why))));
                    return
                end
                celldb.openWindow('Parent', obj.Figure);
            catch ME
                obj.reportError(ME);
            end
        end

        function maybeRecordDb(obj)
            %MAYBERECORDDB  After Mark source complete wrote _final.csv: the lab database record
            %   (celldb.recordCuration: a provenance sidecar, and an event when this computer keeps
            %   records), off the key path. It never changes what the app writes.
            sess = obj.PendingRecord;
            if isempty(sess), return; end
            obj.PendingRecord = [];
            if isempty(sess.Store) || ~isvalid(sess.Store) || ~CellCurator.hasCelldb()
                return
            end
            try
                rec = celldb.recordCuration(sess.Store);
                obj.LastRecord = rec;
                if strlength(string(rec.reason)) > 0
                    obj.setStatus(sprintf('%s %s', char(obj.StatusText), char(string(rec.reason))));
                end
            catch ME
                obj.reportError(ME);
            end
        end
    end

    %% ======================================================================== lab database: the subject
    methods
        function txt = showSubject(obj)
            %SHOWSUBJECT  The Subject... button: what the lab database says about the subject of the
            %   open section (its sex, species and project, its tags and its variables), from this
            %   computer's cache (celldb.subjectInfo; never the server), written to the status bar and
            %   returned. Shown only on request: review stays blind to the animal's group otherwise.
            M = @curation.UiText.msg;
            txt = '';
            try
                id = "";
                if ~isempty(obj.Store) && isvalid(obj.Store)
                    for stem = [string(obj.Store.Meta.ManifestBase), string(obj.Store.Meta.Stem)]
                        sec = celldb.parseSectionName(stem);
                        if strlength(sec.SubjectID) > 0, id = string(sec.SubjectID); break; end
                    end
                    if id == "", txt = M('subjectNoName'); end
                else
                    txt = M('subjectNoSource');
                end
                if id ~= ""
                    I = celldb.subjectInfo(id);
                    if ~I.asked
                        [ok, why] = celldb.available();
                        if ok
                            txt = M('subjectNotAsked', char(id));
                        else
                            txt = M('subjectNoClient', char(id), char(string(why)));
                        end
                    elseif ~I.known
                        txt = M('subjectAbsent', char(id));
                    else
                        said = char(I.text);
                        if strlength(I.tags) > 0
                            said = [said '. ' M('subjectTags', char(I.tags))];
                        end
                        if strlength(I.variables) > 0
                            said = [said '. ' M('subjectVariables', char(I.variables))];
                        end
                        if I.facts_read && strlength(I.tags) == 0 && strlength(I.variables) == 0
                            said = [said '. ' M('subjectNoFacts')];
                        end
                        txt = M('subjectKnown', char(id), said);
                    end
                end
                obj.setStatus(txt);
            catch ME
                obj.reportError(ME);
            end
        end
    end

    %% ======================================================================== sources
    methods (Access = private)
        function D = discoverDatasets(obj, parentDir)
            D = CellCurator.emptyDatasets();
            try
                mfs = CellDatasetManifest.discover(parentDir, struct('WriteManifest', false));
            catch ME
                obj.reportError(ME);
                return
            end
            for k = 1:numel(mfs)
                mf = mfs(k);
                try
                    d = mf.toDatasetStruct(parentDir);
                catch
                    continue
                end
                src = d.Sources;
                if isempty(src), continue; end
                det = [src.Detected];
                if ~any(det), continue; end
                src = src(det);
                S = struct('Key', {}, 'Channel', {}, 'Page', {}, 'LocsPath', {}, 'Total', {}, 'Done', {}, 'Complete', {});
                for j = 1:numel(src)
                    s = src(j);
                    total = double(s.NumDetections);
                    done = 0;
                    if s.CurTotal > 0
                        total = double(s.CurTotal);
                        done = min(total, double(s.CurReviewed));   % every cell is seen by a person
                    end
                    S(end + 1) = struct('Key', char(s.Key), 'Channel', char(s.Channel), 'Page', double(s.Page), ... %#ok<AGROW>
                        'LocsPath', char(s.CsvPath), 'Total', total, 'Done', done, 'Complete', logical(s.CurComplete));
                end
                D(end + 1) = struct('Base', char(d.Base), 'Folder', char(d.Folder), 'DatasetID', char(d.DatasetID), ... %#ok<AGROW>
                    'Mf', mf, 'PageCount', double(d.PageCount), 'Sources', S, 'Short', '');
            end
        end

        function relinkSessions(obj)
            for k = 1:numel(obj.Sessions)
                s = obj.Sessions{k};
                [s.DatasetIndex, s.SourceIndex] = obj.findSource(s.Folder, s.Base, s.Key);
            end
        end

        function [di, si] = findSource(obj, folder, base, key)
            di = 0; si = 0;
            for k = 1:numel(obj.Datasets)
                d = obj.Datasets(k);
                if strcmpi(d.Folder, folder) && strcmpi(d.Base, base)
                    j = find(strcmpi({d.Sources.Key}, key), 1);
                    if ~isempty(j)
                        di = k; si = j;
                        return
                    end
                end
            end
        end

        function [di, si] = pickStart(obj, parentDir, datasetBase, sourceKey)
            di = 0;
            n = numel(obj.Datasets);
            if ~isempty(datasetBase)
                b = char(datasetBase);
                for k = 1:n
                    d = obj.Datasets(k);
                    if strcmpi(d.Base, b) || strcmpi(d.DatasetID, b)
                        di = k; break
                    end
                end
            end
            s = obj.Settings;
            fromSettings = obj.Options.UseSettings && strcmpi(char(s.LastFolder), parentDir);
            if di == 0 && fromSettings && ~isempty(s.LastDataset)
                di = find(strcmpi({obj.Datasets.Base}, char(s.LastDataset)), 1);
                if isempty(di), di = 0; end
            end
            if di == 0
                for k = 1:n
                    if obj.firstWorkSourceIn(k, true) > 0
                        di = k; break
                    end
                end
            end
            if di == 0, di = 1; end
            si = 0;
            keys = {obj.Datasets(di).Sources.Key};
            if ~isempty(sourceKey)
                si = find(strcmpi(keys, char(sourceKey)), 1);
            end
            if (isempty(si) || si == 0) && fromSettings && strcmpi(obj.Datasets(di).Base, char(s.LastDataset)) ...
                    && ~isempty(s.LastSource)
                si = find(strcmpi(keys, char(s.LastSource)), 1);
            end
            if isempty(si) || si == 0
                si = obj.firstWorkSourceIn(di);
            end
        end

        function si = firstWorkSourceIn(obj, di, strict)
            if nargin < 3, strict = false; end
            S = obj.Datasets(di).Sources;
            si = find([S.Total] - [S.Done] > 0, 1);
            if isempty(si)
                if strict, si = 0; else, si = 1; end
            end
        end

        function [di, si] = nextWorkSource(obj)
            %NEXTWORKSOURCE  The next source after the one on screen that still has cells to review.
            di = 0; si = 0;
            list = obj.flatSources();
            if isempty(list), return; end
            obj.syncOpenCounts();
            cur = find(list(:, 1) == obj.DatasetIndex & list(:, 2) == obj.SourceIndex, 1);
            if isempty(cur), cur = 0; end
            n = size(list, 1);
            for step = 1:n - (cur > 0)
                j = mod(cur + step - 1, n) + 1;
                s = obj.Datasets(list(j, 1)).Sources(list(j, 2));
                if s.Total - s.Done > 0
                    di = list(j, 1); si = list(j, 2);
                    return
                end
            end
        end

        function list = flatSources(obj)
            list = zeros(0, 2);
            for k = 1:numel(obj.Datasets)
                m = numel(obj.Datasets(k).Sources);
                list = [list; repmat(k, m, 1), (1:m)']; %#ok<AGROW>
            end
        end

        function stepSource(obj, dir)
            list = obj.flatSources();
            if isempty(list), return; end
            cur = find(list(:, 1) == obj.DatasetIndex & list(:, 2) == obj.SourceIndex, 1);
            if isempty(cur), cur = 0; end
            j = cur + dir;
            if j < 1
                obj.setStatus(curation.UiText.msg('firstSource'));
                return
            elseif j > size(list, 1)
                obj.setStatus(curation.UiText.msg('lastSource'));
                return
            end
            obj.openSourceAt(list(j, 1), list(j, 2));
        end

        function ok = openSourceAt(obj, di, si)
            ok = false;
            obj.endDrag();
            d = obj.Datasets(di);
            s = d.Sources(si);
            id = CellCurator.sessionId(d.Folder, d.Base, s.Key);
            t0 = tic;
            % an open is input: the idle work (creating the map, preparing the next source, the
            % panels) must not run inside it when a component created here lets a timer callback in
            obj.LastInputTic = tic;
            obj.Opening = true;
            opening = onCleanup(@() obj.endOpening()); %#ok<NASGU>
            if ~isempty(obj.Session) && obj.Session.Id == id
                obj.DatasetIndex = di;
                obj.SourceIndex = si;
                obj.rebuildSourceButtons();
                if ~isequal(obj.UI.Dataset.Value, di), obj.UI.Dataset.Value = di; end
                obj.showQueue("review");
                ok = true;
                return
            end
            obj.leaveSource();
            sess = obj.findSession(id);
            isNew = isempty(sess);
            if isempty(sess)
                obj.setStatus(curation.UiText.msg('opening', s.Key, d.Base));
                drawnow limitrate;
                [sess, err] = obj.createSession(di, si);
                if isempty(sess)
                    if isempty(obj.Session)
                        obj.Page = CellCurator.blankPage("none");
                        if ~isempty(obj.Gallery.Cache)
                            obj.Gallery.showPage(zeros(0, 1, 'uint32'), obj.styleFor(obj.Page));
                        end
                        obj.showMessage("none");
                        obj.updateContext();
                    end
                    obj.setStatus(curation.UiText.msg('openFailed', s.Key, d.Base, err));
                    return
                end
            end
            sess.DatasetIndex = di;
            sess.SourceIndex = si;
            others = obj.Sessions(~cellfun(@(x) x == sess, obj.Sessions));
            obj.Sessions = [{sess}, others];
            while numel(obj.Sessions) > CellCurator.MaxSessions
                old = obj.Sessions{end};
                obj.Sessions(end) = [];
                obj.closeSession(old);
            end
            datasetChanged = di ~= obj.DatasetIndex;
            obj.Session = sess;
            obj.Store = sess.Store;
            obj.DatasetIndex = di;
            obj.SourceIndex = si;
            obj.SourceKey = string(s.Key);
            obj.Gallery.setCache(sess.Cache);
            obj.HistPos = 0;
            obj.LivePage = [];
            obj.ReviewOffset = 1;
            obj.Selection = zeros(1, 0);
            obj.Gallery.setSelection([]);
            obj.Cursor = 0;
            obj.Gallery.setCursor(0);
            obj.InspectedTile = 0;
            obj.HoverTile = 0;
            obj.CompanionHeld = false;
            obj.resetMapState();
            tStep = tic;
            regionMsg = obj.applyRegionsOnOpen();
            obj.LastTimings.OpenRegionsMs = 1000 * toc(tStep);
            tStep = tic;
            holdoutMsg = "";
            if isNew
                try
                    obj.clearOrphanAudit();                 % (a crash between an undo and its clean-up)
                catch ME
                    obj.reportError(ME);
                end
                holdoutMsg = obj.applyHoldoutTo(sess);      % before the first page: it may hold some
                if logical(sess.Store.Meta.Complete)
                    sess.FinalSig = CellCurator.keptSignature(sess.Store);
                end
            end
            obj.LastTimings.OpenRolesMs = 1000 * toc(tStep);
            if datasetChanged || isempty(obj.UI.SourceButtons)
                obj.rebuildSourceButtons();
            end
            if ~isequal(obj.UI.Dataset.Value, di), obj.UI.Dataset.Value = di; end
            CellToolkit.setTooltip(obj.UI.Dataset, [curation.UiText.tip('dataset') ' On screen: ' d.Base]);
            obj.updateSourceButtons();
            obj.Figure.Name = sprintf('CellCurator %s %s %s %s', char(8212), d.Base, char(183), s.Key);
            obj.UI.CapT.Text = sprintf('%s (reviewed)', s.Key);
            if isempty(sess.CompanionKey)
                obj.UI.CapC.Text = 'no other channel';
            else
                obj.UI.CapC.Text = sess.CompanionKey;
            end
            obj.UI.CapO.Text = sprintf('Overlay (%s green)', s.Key);
            tStep = tic;
            obj.showQueue("review");
            obj.LastTimings.OpenPageMs = 1000 * toc(tStep);
            if obj.CenterView == "map"
                obj.loadMap();
                obj.updateContext();
            end
            obj.locatorChanged();
            c = sess.Store.counts();
            txt = curation.UiText.msg('opened', s.Key, d.Base, CellCurator.fmtInt(c.active), CellCurator.fmtInt(c.toReview));
            if sess.Store.ReadOnly
                why = CellCurator.readOnlyReason(sess.Store);
                if strlength(why) > 0
                    txt = curation.UiText.msg('openedReadOnly', s.Key, d.Base, why);
                else
                    txt = curation.UiText.msg('readOnlyShort');
                end
            else
                if strlength(sess.ReconcileText) > 0 && isempty(sess.History) && sess.PagesDone == 0
                    txt = [txt ' ' char(sess.ReconcileText)];
                end
                if strlength(regionMsg) > 0
                    txt = [txt ' ' char(regionMsg)];
                end
                if strlength(holdoutMsg) > 0
                    txt = [txt ' ' char(holdoutMsg)];
                end
                if ~isempty(sess.Messages)
                    txt = [txt ' ' char(sess.Messages(1))];
                end
            end
            obj.setStatus(txt);
            obj.LastTimings.OpenSourceMs = 1000 * toc(t0);
            obj.LastInputTic = tic;            % background work waits for the next pause
            obj.updateUndoButtons();
            obj.updateEditEnable();
            if isNew
                obj.schedule(["panels" "prefetch" "final"]);   % _final.csv exactly while complete
            else
                obj.schedule(["panels" "prefetch"]);
            end
            ok = true;
        end

        function [sess, err] = createSession(obj, di, si)
            sess = [];
            err = '';
            d = obj.Datasets(di);
            s = d.Sources(si);
            id = CellCurator.sessionId(d.Folder, d.Base, s.Key);
            t0 = tic;
            try
                st = curation.Store.open(d.Mf, s.Key, struct('AutosaveDelay', obj.Options.AutosaveDelay));
            catch ME
                err = ME.message;
                return
            end
            sess = curation.CuratorSession();
            sess.Id = id;
            sess.Folder = d.Folder;
            sess.Base = d.Base;
            sess.Key = s.Key;
            sess.DatasetIndex = di;
            sess.SourceIndex = si;
            sess.Mf = d.Mf;
            sess.Store = st;
            sess.SourceId = curation.BlindTiles.sourceId(obj.ParentDir, d.Folder, d.Base, s.Key);
            sess.Kind = curation.Proposals.kindOf(s.Key);
            obj.LastTimings.StoreOpenMs = 1000 * toc(t0);
            locs = char(st.Meta.LocsFile);
            if isempty(locs), locs = s.LocsPath; end
            [img, pg, cp, ck] = obj.sourceImage(di, si, locs);
            sess.ImagePath = img;
            sess.TargetPage = pg;
            sess.CompanionPage = cp;
            sess.CompanionKey = ck;
            msgs = strings(0, 1);
            try msgs = string(st.LastReconcile.warnings(:)); catch, end
            P = obj.Prepared;
            obj.LastTimings.ImageReadMs = 0;
            obj.LastTimings.CacheBuildMs = 0;
            try
                if ~isempty(P) && P.Id == id && P.Done
                    cache = P.Cache;
                    CellCurator.syncCache(cache, st);
                    [pageT, pageC] = obj.sourcePages(img, pg, cp, st);
                else
                    [cache, m, pageT, pageC] = obj.buildCache(img, pg, cp, st);
                    msgs = [msgs; m];
                end
            catch ME
                sess.close();
                sess = [];
                err = ME.message;
                return
            end
            if ~isempty(P) && P.Id == id
                obj.Prepared = [];
            end
            sess.Cache = cache;
            tD = tic;
            sess.Display = CellCurator.displayDefaults(cache, st, s.Key);   % the default display
            obj.LastTimings.DisplayDefaultsMs = 1000 * toc(tD);
            sess.PageT = pageT;
            sess.PageC = pageC;
            [sess.Reference, m] = CellCurator.loadReference(img);
            msgs = [m; msgs];
            % a reconcile at open: say what it did in plain words (its technical note on near-kept
            % detections is replaced by that), and keep its near-kept pairs for Close pairs
            [sess.ReconcileText, sess.NearKept] = CellCurator.reconcileSummary(st.LastReconcile);
            if strlength(sess.ReconcileText) > 0
                msgs = msgs(~contains(msgs, "nearKeptIds"));
            end
            sess.Messages = msgs;
            sess.Listener = listener(st, 'Changed', @(~, e) obj.onStoreChanged(sess, e));
        end

        function [pageT, pageC] = sourcePages(obj, img, pg, cp, st)
            %SOURCEPAGES  The target and companion pages of a source (from the small page cache when
            %   the source was prepared in the background), as buildCache uses them.
            pageT = [];
            pageC = [];
            if ~isempty(img) && isfile(img)
                pageT = obj.readPage(img, pg);
            end
            if isempty(pageT)
                sz = double(st.Meta.ImageSize);
                if numel(sz) ~= 2 || any(~isfinite(sz)) || any(sz < 1), sz = [64 64]; end
                pageT = zeros(sz, 'uint8');
                return
            end
            if ndims(pageT) > 2, pageT = pageT(:, :, 1); end
            if isfinite(cp)
                pageC = obj.readPage(img, cp);
                if ndims(pageC) > 2, pageC = pageC(:, :, 1); end
                if ~isequal(size(pageC), size(pageT)), pageC = []; end
            end
        end

        function [img, pg, cp, ck] = sourceImage(obj, di, si, locs)
            d = obj.Datasets(di);
            s = d.Sources(si);
            img = '';
            try img = char(d.Mf.imageForLocs(locs)); catch, end
            pg = s.Page;
            if ~isfinite(pg) || pg < 1, pg = 1; end
            cp = NaN;
            ck = '';
            for j = 1:numel(d.Sources)
                q = d.Sources(j);
                if j ~= si && isfinite(q.Page) && q.Page ~= pg
                    cp = q.Page;
                    ck = q.Key;
                    break
                end
            end
            if isnan(cp) && ~isempty(img) && isfile(img)
                n = d.PageCount;
                if ~(n > 0)
                    try n = CellToolkit.countPages(img); catch, n = 1; end
                end
                if n >= 2
                    cp = find((1:n) ~= pg, 1);
                    ck = sprintf('page %d', cp);
                end
            end
        end

        function [cache, msgs, pageT, pageC] = buildCache(obj, img, pg, cp, st)
            msgs = strings(0, 1);
            pageT = [];
            pageC = [];
            t0 = tic;
            if ~isempty(img) && isfile(img)
                pageT = obj.readPage(img, pg);
            end
            if isempty(pageT)
                sz = double(st.Meta.ImageSize);
                if numel(sz) ~= 2 || any(~isfinite(sz)) || any(sz < 1), sz = [64 64]; end
                pageT = zeros(sz, 'uint8');
                msgs(end + 1, 1) = curation.UiText.msg('missingImage', st.Meta.Key, img);
            elseif isfinite(cp)
                pageC = obj.readPage(img, cp);
            end
            if ndims(pageT) > 2, pageT = pageT(:, :, 1); end
            if ~isempty(pageC)
                if ndims(pageC) > 2, pageC = pageC(:, :, 1); end
                if ~isequal(size(pageC), size(pageT)), pageC = []; end
            end
            obj.LastTimings.ImageReadMs = 1000 * toc(t0);
            t0 = tic;
            [ids, xy] = CellCurator.cacheCells(st);
            cache = curation.CropCache.build(pageT, pageC, ids, xy, CellCurator.umOf(st));
            obj.LastTimings.CacheBuildMs = 1000 * toc(t0);
        end

        function img = readPage(obj, path, page)
            %READPAGE  One TIFF page, from a small cache of the last pages read (both sources of a
            %   section share their image).
            key = lower(string(path)) + "#" + page;
            C = obj.ImageCache;
            for k = 1:numel(C)
                if C(k).Key == key
                    img = C(k).Data;
                    obj.ImageCache = [C(k), C([1:k - 1, k + 1:end])];
                    return
                end
            end
            img = [];
            try
                img = imread(char(path), page);
            catch
                try
                    if page == 1, img = imread(char(path)); end
                catch
                end
            end
            if isempty(img), return; end
            obj.ImageCache = [struct('Key', key, 'Data', img), C];
            if numel(obj.ImageCache) > 4
                obj.ImageCache = obj.ImageCache(1:4);
            end
        end

        function sess = findSession(obj, id)
            sess = [];
            for k = 1:numel(obj.Sessions)
                if obj.Sessions{k}.Id == id
                    sess = obj.Sessions{k};
                    return
                end
            end
        end

        function leaveSource(obj)
            %LEAVESOURCE  The source on screen is switched away from: save it, record it to its
            %   manifest, save the settings. It stays open in memory (see MaxSessions).
            if isempty(obj.Session), return; end
            obj.endDrag();
            sess = obj.Session;
            try
                sess.Store.flush();
            catch ME
                obj.reportError(ME);
            end
            obj.recordSession(sess);
            obj.saveSettings();
        end

        function recordSession(obj, sess)
            if isempty(sess) || isempty(sess.Store) || ~isvalid(sess.Store), return; end
            obj.syncCounts(sess);
            st = sess.Store;
            if st.ReadOnly, return; end
            try
                f = st.counts();
                f.complete = logical(st.Meta.Complete);
                f.tool = 'CellCurator';
                sess.Mf.recordCuration(sess.Key, st.Paths.csv, f);
                sess.Mf.save();
            catch ME
                obj.reportError(ME);
            end
        end

        function closeSession(obj, sess)
            if isempty(sess), return; end
            if ~isempty(obj.Assist), obj.Assist.unregister(sess.Id); end
            sess.close(@(s) obj.recordSession(s));
            delete(sess);
        end

        function closeAllSessions(obj)
            if ~isempty(obj.Session)
                obj.endDrag();
                obj.saveSettings();
            end
            for k = 1:numel(obj.Sessions)
                try obj.closeSession(obj.Sessions{k}); catch ME, obj.reportError(ME); end
            end
            obj.Sessions = {};
            obj.Session = [];
            obj.Store = [];
            obj.DatasetIndex = 0;
            obj.SourceIndex = 0;
            obj.SourceKey = "";
        end

        %% ---- creating the map in the background
        function maybePrepareMap(obj)
            %MAYBEPREPAREMAP  Create the center map (hidden) once the person has paused for
            %   PrepareIdleSec with a source on screen, so the first Tab does not wait for it.
            if obj.Closed || ~obj.Options.PrepareMap || isempty(obj.Session) || obj.CreatingMap || ...
                    (~isempty(obj.Map) && isvalid(obj.Map))
                return
            end
            idle = toc(obj.LastInputTic);
            if idle < CellCurator.PrepareIdleSec
                obj.rearmIdle(CellCurator.PrepareIdleSec - idle + 0.05);
                return
            end
            obj.ensureMap();
        end

        %% ---- preparing the next source in the background
        function maybePrepare(obj)
            if ~obj.Options.PrepareNext || isempty(obj.Session), return; end
            P = obj.ensurePrepared();
            if isempty(P) || P.Done || P.Failed, return; end
            idle = toc(obj.LastInputTic);
            if idle < CellCurator.PrepareIdleSec
                obj.rearmIdle(CellCurator.PrepareIdleSec - idle + 0.05);
                return
            end
            obj.prepareStep();
            P = obj.Prepared;
            if ~isempty(P) && ~P.Done && ~P.Failed
                obj.rearmIdle(0.05);
            end
        end

        function P = ensurePrepared(obj)
            P = [];
            [di, si] = obj.nextWorkSource();
            if di == 0
                obj.Prepared = [];
                return
            end
            d = obj.Datasets(di);
            id = CellCurator.sessionId(d.Folder, d.Base, d.Sources(si).Key);
            if ~isempty(obj.findSession(id))
                return
            end
            P = obj.Prepared;
            if isempty(P) || P.Id ~= id
                P = struct('Id', id, 'Di', di, 'Si', si, 'Step', 0, 'Img', '', 'Pg', 1, 'Cp', NaN, ...
                    'PageT', [], 'PageC', [], 'Ids', [], 'XY', [], 'Um', 1, 'Cache', [], 'Next', 1, ...
                    'Done', false, 'Failed', false);
                obj.Prepared = P;
            end
        end

        function prepareStep(obj)
            %PREPARESTEP  One bounded step of preparing the next source: read its image pages, list
            %   its cells (read-only store, no lock), extract its crops in chunks.
            P = obj.Prepared;
            d = obj.Datasets(P.Di);
            s = d.Sources(P.Si);
            try
                switch P.Step
                    case 0
                        [P.Img, P.Pg, P.Cp] = obj.sourceImage(P.Di, P.Si, s.LocsPath);
                        if isempty(P.Img) || ~isfile(P.Img), P.Failed = true; end
                        if ~P.Failed
                            P.PageT = obj.readPage(P.Img, P.Pg);
                            if isempty(P.PageT), P.Failed = true; end
                            if ndims(P.PageT) > 2, P.PageT = P.PageT(:, :, 1); end
                        end
                    case 1
                        if isfinite(P.Cp)
                            P.PageC = obj.readPage(P.Img, P.Cp);
                            if ndims(P.PageC) > 2, P.PageC = P.PageC(:, :, 1); end
                            if ~isequal(size(P.PageC), size(P.PageT)), P.PageC = []; end
                        end
                    case 2
                        st = curation.Store.open(d.Mf, s.Key, struct('ReadOnly', true, 'AutosaveDelay', 0));
                        [P.Ids, P.XY] = CellCurator.cacheCells(st);
                        P.Um = CellCurator.umOf(st);
                        st.close();
                        delete(st);
                    otherwise
                        n = numel(P.Ids);
                        r = P.Next:min(n, P.Next + CellCurator.PrepareChunk - 1);
                        if isempty(P.Cache)
                            P.Cache = curation.CropCache.build(P.PageT, P.PageC, P.Ids(r), P.XY(r, :), P.Um);
                        elseif ~isempty(r)
                            P.Cache.add(P.Ids(r), P.XY(r, :));
                        end
                        P.Next = P.Next + numel(r);
                        if P.Next > n
                            P.Done = true;
                            P.PageT = []; P.PageC = []; P.Ids = []; P.XY = [];
                        end
                end
                P.Step = P.Step + 1;
            catch
                P.Failed = true;
            end
            obj.Prepared = P;
        end

        %% ---- settings
        function S = loadSettings(obj)
            S = CellCurator.defaultSettings();
            if obj.Options.UseSettings
                try
                    S = CellToolkit.loadSettingsStruct('CellCurator', 'Settings', S);
                catch
                end
            end
        end

        function saveSettings(obj)
            if ~obj.Options.UseSettings || isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            S = obj.Settings;
            S.WindowPosition = obj.Figure.Position;
            S.DisplayMode = char(obj.DisplayMode);
            S.GainRel = obj.Gain;
            S.GammaRel = obj.Gamma;
            S.EvenTiles = obj.EvenTiles;
            if ~isempty(obj.Training) && isvalid(obj.Training)
                S.LastStage2Export = obj.Training.LastStage2;
                S.LastStage1Export = obj.Training.LastStage1;
            end
            S.Zoom = obj.Zoom;
            if isfield(S, 'SnapOn'), S = rmfield(S, 'SnapOn'); end   % the old checkbox (Shift snaps now)
            S.SweepFieldUm = obj.SweepFieldUm;
            S.MarkerStyles = obj.MarkerSaved;
            if ~isempty(obj.ParentDir), S.LastFolder = obj.ParentDir; end
            if obj.DatasetIndex >= 1 && obj.DatasetIndex <= numel(obj.Datasets)
                S.LastDataset = obj.Datasets(obj.DatasetIndex).Base;
                S.LastSource = char(obj.SourceKey);
            end
            obj.Settings = S;
            try
                CellToolkit.saveSettingsStruct('CellCurator', 'Settings', S);
            catch
            end
        end
    end

    %% ======================================================================== map: public seams
    methods
        function d = openMarkerDialog(obj)
            %OPENMARKERDIALOG  The Markers... button: the map markers window (curation.MarkerDialog;
            %   the open one is brought to the front). Its changes show on the map and the locator
            %   at once; OK keeps them in the settings, Cancel goes back.
            d = obj.MarkerDialog;
            if ~isempty(d) && isvalid(d)
                figure(d.Figure);
                return
            end
            d = curation.MarkerDialog(obj.MarkerStyle, 'Near', obj.Figure, 'Visible', obj.Options.Visible, ...
                'PreviewFcn', @(S) obj.uiCall(@() obj.applyMarkerStyles(S, false), false), ...
                'DoneFcn', @(S, ok) obj.uiCall(@() obj.markerDialogDone(S, ok)));
            obj.MarkerDialog = d;
        end

        function applyMarkerStyles(obj, S, keep)
            %APPLYMARKERSTYLES  Draw the map, the locator and the map legend with markers S
            %   (curation.MapMarkers). KEEP (default true): also remember them in the settings.
            if nargin < 3, keep = true; end
            S = curation.MapMarkers.validate(S);
            obj.MarkerStyle = S;
            styles = curation.MapMarkers.layerStyles(S);
            m = obj.Map;
            if ~isempty(m) && isvalid(m)
                m.setMarkerStyles(styles);
                if ~isempty(obj.Session) && obj.MapLoadedId == obj.Session.Id && ~isempty(m.Ids)
                    ids = m.Ids(ismember(m.Ids, obj.Store.get('CellID')));
                    if ~isempty(ids)
                        [rgb, layer] = obj.cellMarkers(ids);
                        m.updatePoints(ids, rgb, layer);
                    end
                end
            end
            L = obj.Locator;
            if ~isempty(L) && isvalid(L)
                L.setMarkerStyles(styles);
                obj.locatorChanged();
            end
            obj.refreshMapLegend();
            if keep
                obj.MarkerSaved = S;
                obj.saveSettings();
            end
        end

        function showCenter(obj, view)
            %SHOWCENTER  "map": the map of the section in the center; "gallery": the tiles.
            if obj.Closed, return; end
            if string(view) == "map"
                obj.showMapView();
            else
                obj.showGalleryView();
            end
        end

        function setMapTool(obj, tool, showMap)
            %SETMAPTOOL  The map tool: "select" | "add" | "move" | "lasso". SHOWMAP (keys, buttons):
            %   show the map too.
            if nargin < 3, showMap = false; end
            if obj.Closed, return; end
            tool = lower(string(tool));
            if ~any(CellCurator.MAP_TOOLS == tool), return; end
            M = @curation.UiText.msg;
            if tool ~= "select" && (isempty(obj.Store) || obj.Store.ReadOnly)
                if isempty(obj.Store)
                    obj.setStatus(M('mapNoSource'));
                else
                    obj.setStatus(M('toolReadOnly'));
                end
                obj.syncToolButtons();
                return
            end
            if showMap && obj.CenterView ~= "map"
                obj.showCenter("map");
                if obj.CenterView ~= "map"
                    obj.syncToolButtons();
                    return
                end
            end
            if tool ~= "lasso", obj.cancelLasso(false); end
            if tool ~= "select", obj.deselectRegion(false); end
            obj.MapTool = tool;
            if ~isempty(obj.Map) && isvalid(obj.Map), obj.Map.Tool = tool; end
            obj.syncToolButtons();
            if showMap
                obj.setStatus(M(char("tool" + upper(extractBefore(tool, 2)) + extractAfter(tool, 1) + "On")));
            end
            obj.updateContext();
        end

        function mapClick(obj, xy, selectionType)
            %MAPCLICK  A press and release at image point XY of the map ('normal' | 'alt' | 'extend'
            %   (Shift+click) | 'open' (double click)), through curation.MapView's own handlers.
            if nargin < 3 || isempty(selectionType), selectionType = 'normal'; end
            if obj.CenterView ~= "map", obj.showCenter("map"); end
            if ~obj.mapShowing(), return; end
            xy = double(xy(1, 1:2));
            obj.Map.refreshLayout();
            obj.ensureInView(xy);
            m = obj.Map;
            st = char(selectionType);
            mods = strings(1, 0);
            if strcmp(st, 'extend'), mods = "shift"; end
            if strcmp(st, 'open')       % a double click: the first press arrives as a normal one
                m.onButtonDown(struct('AxesPoint', xy, 'SelectionType', 'normal', 'Modifier', mods));
                m.onButtonUp(struct('AxesPoint', xy));
            end
            m.onButtonDown(struct('AxesPoint', xy, 'SelectionType', st, 'Modifier', mods));
            if obj.mapShowing()
                m.onButtonUp(struct('AxesPoint', xy));
            end
        end

        function mapDrag(obj, fromXY, toXY, modifiers)
            %MAPDRAG  Press at FROMXY, move to TOXY, release with MODIFIERS held (Move tool: moves
            %   the point there; "shift" snaps it to its center).
            if nargin < 4, modifiers = strings(1, 0); end
            if obj.CenterView ~= "map", obj.showCenter("map"); end
            if ~obj.mapShowing(), return; end
            fromXY = double(fromXY(1, 1:2));
            toXY = double(toXY(1, 1:2));
            obj.Map.refreshLayout();
            obj.ensureInView([fromXY; toXY]);
            m = obj.Map;
            m.onButtonDown(struct('AxesPoint', fromXY, 'SelectionType', 'normal'));
            for t = [0.34 0.67 1]
                m.onMotion(struct('AxesPoint', fromXY + t * (toXY - fromXY)));
            end
            m.onButtonUp(struct('AxesPoint', toXY, 'Modifier', string(modifiers)));
        end

        function mapLasso(obj, poly)
            %MAPLASSO  A lasso drawn along POLY (M x 2 image px) with the Lasso tool.
            if obj.CenterView ~= "map", obj.showCenter("map"); end
            if ~obj.mapShowing(), return; end
            obj.setMapTool("lasso");
            if obj.MapTool ~= "lasso", return; end
            poly = double(poly);
            obj.Map.refreshLayout();
            obj.ensureInView(poly);
            m = obj.Map;
            m.onButtonDown(struct('AxesPoint', poly(1, :), 'SelectionType', 'normal'));
            for k = 2:size(poly, 1)
                m.onMotion(struct('AxesPoint', poly(k, :)));
            end
            m.onButtonUp(struct('AxesPoint', poly(end, :)));
        end

        function mapHover(obj, xy)
            %MAPHOVER  The pointer over image point XY of the map (0 0: off the map).
            if ~obj.mapShowing(), return; end
            obj.Map.onMotion(struct('AxesPoint', double(xy(1, 1:2))));
        end

        function lassoAction(obj, name)
            %LASSOACTION  What the lasso bar does: good | bad | uncertain | exclude | merge | cancel.
            if obj.Closed || isempty(obj.Lasso), return; end
            switch lower(string(name))
                case "good",      obj.lassoLabel("Good");
                case "bad",       obj.lassoLabel("Bad");
                case "uncertain", obj.lassoLabel("Uncertain");
                case "exclude",   obj.lassoExclude();
                case "merge",     obj.lassoMerge();
                otherwise,        obj.cancelLasso(true);
            end
        end

        function markComplete(obj)
            %MARKCOMPLETE  Mark the source on screen complete (when nothing is left to review, flagged
            %   or in close pairs): Complete true, <stem>_final.csv written, the manifest recorded.
            if obj.Closed, return; end
            M = @curation.UiText.msg;
            if isempty(obj.Store)
                obj.setStatus(M('mapNoSource'));
                return
            end
            if ~obj.canEdit(), return; end
            F = obj.finishState();
            if F.Complete
                obj.setStatus(M('alreadyComplete', obj.SourceKey));
                return
            end
            if ~F.Can
                obj.setStatus(M('cannotComplete', strjoin(F.Open, ', ')));
                return
            end
            st = obj.Store;
            path = st.Paths.final;
            [~, nm, ex] = fileparts(path);
            % the final list first: Complete is set only when it was written
            try
                st.exportFinal(path);
            catch ME
                obj.setStatus(M('finalNotWritten', obj.SourceKey, [nm ex], ME.message));
                return
            end
            try
                st.setComplete(true);
            catch ME
                CellCurator.retireFinal(path);       % not complete after all: the file must not look current
                obj.reportError(ME);
                return
            end
            obj.Session.FinalSig = CellCurator.keptSignature(st);
            try
                st.flush();
            catch ME
                obj.reportError(ME);                 % the journal holds Complete; the JSON follows later
            end
            obj.recordSession(obj.Session);
            obj.FinishCache = [];
            if obj.Page.Kind == "empty" && obj.QueueName == "review"
                obj.showFinish();
            end
            obj.updateContext();
            obj.refreshPanels();
            obj.setStatus(M('completed', obj.SourceKey, CellCurator.fmtInt(F.Kept), [nm ex]));
            obj.PendingRecord = obj.Session;          % the lab database record, at the next idle step
            obj.schedule("status");
        end

        function setSweepWidth(obj, um)
            %SETSWEEPWIDTH  Width of a missed-cell sweep field in micrometers (a setting).
            um = CellCurator.clamp(double(um), [100 5000], obj.SweepFieldUm);
            obj.SweepFieldUm = um;
            if isfield(obj.UI, 'SweepWidth') && isvalid(obj.UI.SweepWidth) && obj.UI.SweepWidth.Value ~= um
                obj.UI.SweepWidth.Value = um;
            end
            if obj.MapTask ~= "sweep" || ~obj.mapShowing(), return; end
            c = obj.Map.Center;
            rects = obj.Map.sweepRects(um, CellCurator.SweepOverlap);
            inside = c(1) >= rects(:, 1) & c(1) <= rects(:, 2) & c(2) >= rects(:, 3) & c(2) <= rects(:, 4);
            k = find(inside, 1);
            if isempty(k), k = 1; end
            obj.showSweepField(k);
            obj.setStatus(curation.UiText.msg('sweepWidthSet', round(um), size(rects, 1)));
        end

        function showRightTab(obj, name)
            %SHOWRIGHTTAB  "inspector" | "map" | "audit": the tab of the right panel (as a click on it).
            if string(name) == "map"
                obj.UI.Tabs.SelectedTab = obj.UI.TabMap;
            elseif string(name) == "audit"
                obj.UI.Tabs.SelectedTab = obj.UI.TabAudit;
            elseif string(name) == "training"
                obj.UI.Tabs.SelectedTab = obj.UI.TabTraining;
            else
                obj.UI.Tabs.SelectedTab = obj.UI.TabInspector;
            end
            obj.onRightTab();
        end

        function clickLocator(obj, xy)
            %CLICKLOCATOR  A click on the locator at page point XY (full-resolution image pixels).
            if ~obj.locatorShowing(), return; end
            f = obj.LocatorScale;
            p = (double(xy(1, 1:2)) + (f - 1) / 2) / f;
            obj.Locator.onButtonDown(struct('AxesPoint', p, 'SelectionType', 'normal'));
            if obj.locatorShowing()
                obj.Locator.onButtonUp(struct('AxesPoint', p));
            end
        end
    end

    %% ======================================================================== map: view
    methods (Access = private)
        function showMapView(obj)
            if isempty(obj.Session) || isempty(obj.Store)
                obj.setStatus(curation.UiText.msg('mapNoSource'));
                obj.syncViewButton();
                return
            end
            obj.endDrag();
            if obj.CenterView ~= "map"
                obj.UI.MapArea.Visible = 'on';
                obj.Gallery.Panel.Visible = 'off';
                obj.CenterView = "map";
            end
            t0 = tic;
            obj.ensureMap();
            if isempty(obj.Map) || ~isvalid(obj.Map)
                return                 % being created (by the idle step this call interrupted)
            end
            if ~obj.MapLaidOut
                obj.settleMapLayout();
            end
            obj.LastTimings.MapEnsureMs = 1000 * toc(t0);
            t1 = tic;
            obj.loadMap();
            obj.Map.refreshLayout();
            obj.LastTimings.MapLoadMs = 1000 * toc(t1);
            obj.syncViewButton();
            obj.updateEditEnable();
            obj.updateContext();
            obj.schedule(["inspector" "undo"]);
            obj.locatorChanged();
        end

        function showGalleryView(obj)
            if obj.CenterView == "gallery"
                obj.syncViewButton();
                return
            end
            if ~isempty(obj.Map) && isvalid(obj.Map), obj.Map.cancelDrag(); end
            obj.cancelLasso(false);
            obj.deselectRegion(false);
            wasTask = any(obj.QueueName == CellCurator.MAP_QUEUES);
            left = '';
            if obj.MapTask == "pairs"
                left = curation.UiText.msg('leftPairs');
            elseif obj.MapTask == "sweep" && ~isempty(obj.Map) && obj.Map.SweepIndex > 0
                left = curation.UiText.msg('leftSweep', obj.Map.SweepIndex, size(obj.Map.SweepRects, 1));
            end
            obj.leaveMapTask();
            obj.Gallery.Panel.Visible = 'on';
            obj.UI.MapArea.Visible = 'off';
            obj.CenterView = "gallery";
            obj.MapHover = uint32(0);
            if ~isempty(obj.Map) && isvalid(obj.Map), obj.Map.setHover(0); end   % no stale ring next time
            obj.syncViewButton();
            if wasTask
                obj.GalleryStale = false;
                obj.showQueue("review");
                if ~isempty(left), obj.setStatus(left); end
            elseif obj.GalleryStale
                obj.GalleryStale = false;
                obj.pruneVanished(true);
                if obj.Page.Kind == "empty"
                    obj.showQueue(obj.QueueName);
                elseif obj.Page.Kind ~= "none"
                    obj.Page.Untouched = obj.untouchedOf(obj.Page);
                    obj.rerender();
                end
            end
            obj.rehover();                % keys go to the tile under the pointer now, if any
            obj.updateEditEnable();
            obj.updateContext();
            obj.schedule(["inspector" "prefetch"]);
            obj.locatorChanged();
        end

        function toggleCenter(obj)
            if obj.CenterView == "map"
                obj.showCenter("gallery");
            else
                obj.showCenter("map");
            end
        end

        function syncViewButton(obj)
            want = obj.CenterView == "map";
            if obj.UI.View.Value ~= want, obj.UI.View.Value = want; end
        end

        function syncToolButtons(obj)
            %SYNCTOOLBUTTONS  The active tool's button pressed, colored and bold.
            for i = 1:numel(obj.UI.ToolButtons)
                want = CellCurator.MAP_TOOLS(i) == obj.MapTool;
                b = obj.UI.ToolButtons(i);
                if b.Value ~= want, b.Value = want; end
                if want
                    bgc = [0.56 0.76 0.94]; fw = 'bold';
                else
                    bgc = [0.96 0.96 0.96]; fw = 'normal';
                end
                if ~isequal(b.BackgroundColor, bgc), b.BackgroundColor = bgc; end
                if ~strcmp(b.FontWeight, fw), b.FontWeight = fw; end
            end
        end

        function ensureMap(obj)
            %ENSUREMAP  Create the center map (and its action bars, over it): at the first idle moment
            %   after a source is on screen, else on first use.
            if (~isempty(obj.Map) && isvalid(obj.Map)) || obj.CreatingMap, return; end
            obj.CreatingMap = true;     % an idle step must not start a second one meanwhile
            try
                obj.createMap();
            catch ME
                obj.CreatingMap = false;
                rethrow(ME);
            end
            obj.CreatingMap = false;
            obj.MapLaidOut = false;
            if obj.CenterView == "map"
                % made on demand, or shown while it was being made: settle its size, load it
                obj.settleMapLayout();
                obj.loadMap();
                obj.updateContext();
            end
        end

        function settleMapLayout(obj)
            %SETTLEMAPLAYOUT  The first show of a map made while hidden: wait until the browser has
            %   laid its panel out, so the whole section is drawn at its real size at once (the view
            %   would also correct itself moments later: curation.MapView re-reads its size when a
            %   container is shown and at every press).
            m = obj.Map;
            last = [];
            stable = 0;
            for i = 1:40           % the browser lays the panel out: wait for a real, steady size
                drawnow;
                p = getpixelposition(m.Panel, true);
                if isequal(p, last) && p(3) > 100 && p(4) > 100
                    stable = stable + 1;
                else
                    stable = 0;
                end
                last = p;
                if stable >= 2, break; end
                pause(0.01);
            end
            m.refreshLayout();
            obj.MapLaidOut = true;
        end

        function createMap(obj)
            t0 = tic;
            C = curation.UiText.colors();
            m = curation.MapView(obj.UI.MapHost, 'Background', C.Background / 255, ...
                'SelectionColor', C.Selection / 255, 'ExcludeColor', C.Exclude / 255, ...
                'ReferenceColor', C.Reference / 255, 'MarkerPx', 10);
            m.setMarkerStyles(curation.MapMarkers.layerStyles(obj.MarkerStyle));
            m.Panel.Layout.Row = 2;
            m.Panel.Layout.Column = 1;
            m.Tool = obj.MapTool;
            m.PointClickFcn = @(~, info) obj.uiCall(@() obj.onMapPointClick(info), false);
            m.EmptyClickFcn = @(~, info) obj.uiCall(@() obj.onMapEmptyClick(info), false);
            m.PointDropFcn = @(~, info) obj.uiCall(@() obj.onMapPointDrop(info), false);
            m.LassoDoneFcn = @(~, info) obj.uiCall(@() obj.onMapLasso(info), false);
            m.HoverFcn = @(~, info) obj.uiCall(@() obj.onMapHover(info), false);
            obj.Map = m;
            obj.MapLoadedId = "";
            tb = tic;
            obj.buildMapBars();
            obj.LastTimings.MapBarsMs = 1000 * toc(tb);
            drawnow;          % lay the new panel out: the view's geometry needs its real size
            obj.LastTimings.MapCreateMs = 1000 * toc(t0);
        end

        function buildMapBars(obj)
            %BUILDMAPBARS  The non-modal action bars above the map (lasso, region, close pairs,
            %   sweep); one shows at a time, in a row of its own, so it never hides part of the map.
            U = @curation.UiText.label;
            C = curation.UiText.colors();
            light = [0.95 0.95 0.95];
            dark = [0.1 0.1 0.1];
            gray = [0.94 0.94 0.94];
            % lasso
            [p, g] = obj.newActionBar('pn:lassoBar', {'fit', 82, 82, 104, 138, 140, 102, '1x'});
            obj.UI.LassoText = obj.barLabel(g, 'lbl:lassoBar');
            obj.UI.LassoGood = obj.barButton(g, 2, 'lassoGood', @() obj.lassoAction("good"), C.Good / 255, [1 1 1]);
            obj.UI.LassoBad = obj.barButton(g, 3, 'lassoBad', @() obj.lassoAction("bad"), C.Bad / 255, [1 1 1]);
            obj.UI.LassoUnc = obj.barButton(g, 4, 'lassoUncertain', @() obj.lassoAction("uncertain"), C.Uncertain / 255, dark);
            obj.UI.LassoExclude = obj.barButton(g, 5, 'lassoExclude', @() obj.lassoAction("exclude"), C.Exclude / 255, dark);
            obj.UI.LassoMerge = obj.barButton(g, 6, 'lassoMerge', @() obj.lassoAction("merge"), gray, dark);
            obj.barButton(g, 7, 'lassoCancel', @() obj.lassoAction("cancel"), gray, dark);
            obj.UI.LassoBar = p;
            % exclusion region
            [p, g] = obj.newActionBar('pn:regionBar', {'fit', 160, 110, '1x'});
            obj.UI.RegionText = obj.barLabel(g, 'lbl:regionBar');
            obj.barButton(g, 2, 'regionRemove', @() obj.removeSelectedRegion(), C.Exclude / 255, dark);
            obj.barButton(g, 3, 'regionKeep', @() obj.deselectRegion(true), gray, dark);
            obj.UI.RegionBar = p;
            % close pairs
            [p, g] = obj.newActionBar('pn:pairBar', {'fit', 300, 130, 90, 90, '1x'});
            obj.UI.PairText = obj.barLabel(g, 'lbl:pairBar');
            obj.UI.PairAccept = obj.barButton(g, 2, 'pairAcceptMerge', @() obj.pairAccept(), [0.80 0.88 0.98], dark);
            obj.UI.PairAccept.Tag = 'btn:pairAccept';
            obj.UI.PairOther = obj.barButton(g, 3, 'pairOtherKeep', @() obj.pairOther(), gray, dark);
            obj.UI.PairOther.Tag = 'btn:pairOther';
            obj.barButton(g, 4, 'pairSkip', @() obj.pairStep(1), gray, dark);
            obj.barButton(g, 5, 'pairBack', @() obj.pairStep(-1), gray, dark);
            obj.UI.PairBar = p;
            % missed-cell sweep
            [p, g] = obj.newActionBar('pn:sweepBar', {'fit', 140, 140, 'fit', 70, '1x'});
            obj.UI.SweepText = obj.barLabel(g, 'lbl:sweepBar');
            obj.barButton(g, 2, 'sweepPrev', @() obj.sweepStep(-1), gray, dark);
            obj.barButton(g, 3, 'sweepNext', @() obj.sweepStep(1), [0.80 0.88 0.98], dark);
            t = uilabel(g, 'Text', U('sweepWidth'), 'FontColor', light, 'HorizontalAlignment', 'right');
            t.Layout.Row = 1; t.Layout.Column = 4;
            obj.UI.SweepWidth = uieditfield(g, 'numeric', 'Limits', [100 5000], 'Value', obj.SweepFieldUm, ...
                'ValueDisplayFormat', '%.0f', 'Tag', 'ef:sweepWidth', 'RoundFractionalValues', 'on', ...
                'ValueChangedFcn', @(s, ~) obj.uiCall(@() obj.setSweepWidth(s.Value)));
            obj.UI.SweepWidth.Layout.Row = 1; obj.UI.SweepWidth.Layout.Column = 5;
            CellToolkit.setTooltip(obj.UI.SweepWidth, curation.UiText.tip('sweepWidth'));
            obj.UI.SweepBar = p;
        end

        function [p, g] = newActionBar(obj, tag, widths)
            p = uipanel(obj.UI.MapHost, 'BorderType', 'none', 'BackgroundColor', [0.2 0.2 0.2], ...
                'Visible', 'off', 'Tag', tag);
            p.Layout.Row = 1;
            p.Layout.Column = 1;
            g = uigridlayout(p, [1 numel(widths)], 'ColumnWidth', widths, 'RowHeight', {'1x'}, ...
                'Padding', [8 5 8 5], 'ColumnSpacing', 6, 'BackgroundColor', [0.2 0.2 0.2]);
        end

        function h = barLabel(~, g, tag)
            h = uilabel(g, 'Text', '', 'FontColor', [0.95 0.95 0.95], 'FontWeight', 'bold', 'Tag', tag);
            h.Layout.Row = 1;
            h.Layout.Column = 1;
        end

        function b = barButton(obj, g, col, id, fn, bgc, fc)
            b = uibutton(g, 'Text', curation.UiText.label(id), 'Tag', ['btn:' id], 'BackgroundColor', bgc, ...
                'FontColor', fc, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~, ~) obj.uiCall(@() obj.buttonAction(fn)));
            b.Layout.Row = 1;
            b.Layout.Column = col;
            CellToolkit.setTooltip(b, curation.UiText.tip(id));
        end

        function showBar(obj, name)
            %SHOWBAR  Show action bar NAME ("lasso" | "region" | "pair" | "sweep"); "" hides them all.
            if ~isfield(obj.UI, 'LassoBar'), return; end
            bars = {obj.UI.LassoBar, obj.UI.RegionBar, obj.UI.PairBar, obj.UI.SweepBar};
            names = ["lasso" "region" "pair" "sweep"];
            for i = 1:numel(bars)
                want = matlab.lang.OnOffSwitchState(names(i) == string(name));
                if bars{i}.Visible ~= want, bars{i}.Visible = want; end
            end
            obj.setBarRow(CellCurator.BarPx * (string(name) ~= ""));
        end

        function setBarRow(obj, h)
            %SETBARROW  The action-bar row's height: the map gets the rest. No drawnow here (this
            %   runs on the key path): the new layout is finished at the next idle step
            %   (finishBarLayout), which lets the view take its new size and keeps the part of the
            %   section on screen where it was (the map's top edge moves by the bar's height).
            host = obj.UI.MapHost;
            if isequal(host.RowHeight{1}, h), return; end
            m = obj.Map;
            if obj.mapShowing() && ~isempty(m.Panel) && isvalid(m.Panel) && isempty(obj.BarLayout)
                obj.BarLayout = struct('WasFit', m.IsFit, 'P0', getpixelposition(m.Panel, true), 'Tic', tic);
            end
            host.RowHeight = {h, '1x'};
            if ~isempty(obj.BarLayout), obj.schedule("maplayout", 0.02); end
        end

        function finishBarLayout(obj)
            %FINISHBARLAYOUT  (idle) The map after an action bar came or went: its real size, and the
            %   view shifted so the section stays where it was on screen.
            L = obj.BarLayout;
            m = obj.Map;
            if isempty(L) || ~obj.mapShowing() || isempty(m.Panel) || ~isvalid(m.Panel)
                obj.BarLayout = [];
                return
            end
            p = getpixelposition(m.Panel, true);
            if p(4) == L.P0(4) && toc(L.Tic) < 0.6
                obj.schedule("maplayout", 0.03);        % the browser has not laid it out yet
                return
            end
            obj.BarLayout = [];
            m.refreshLayout();
            if ~L.WasFit && p(4) ~= L.P0(4)
                m.panBy(0, -(p(4) - L.P0(4)) / 2);
            end
        end

        function loadMap(obj)
            %LOADMAP  Bring the center map in step with the source on screen: everything when it
            %   shows another source, else only what changed while it was hidden.
            m = obj.Map;
            sess = obj.Session;
            if isempty(m) || ~isvalid(m) || isempty(sess) || isempty(sess.Store), return; end
            if obj.MapLoadedId ~= sess.Id
                ds = lower(string(sess.Folder) + "|" + string(sess.Base));
                keep = obj.MapDataset == ds && isequal(size(sess.PageT), m.ImageSize);
                m.setImage(sess.PageT, sess.PageC, sess.Cache.Limits, CellCurator.umOf(sess.Store), 'KeepView', keep);
                obj.applyMapDisplay(m);
                obj.MapLoadedId = sess.Id;
                obj.MapDataset = ds;
                obj.MapPending = zeros(0, 1, 'uint32');
                obj.MapFull = false;
                obj.MapImageDirty = false;
                obj.MapRegionsDirty = false;
                obj.loadMapPoints();
                obj.drawMapRegions();
                m.Tool = obj.MapTool;
                obj.Counters.MapLoads = obj.Counters.MapLoads + 1;
            else
                obj.flushMap();
            end
        end

        function loadMapPoints(obj)
            st = obj.Store;
            ids = st.get('CellID');
            xy = [st.get('X'), st.get('Y')];
            ok = st.get('State') == "active" & all(isfinite(xy), 2);
            [rgb, layer] = obj.cellMarkers();
            obj.Map.setPoints(ids(ok), xy(ok, :), rgb(ok, :), layer(ok));
            obj.MapSelection = obj.MapSelection(ismember(obj.MapSelection, ids(ok)));
            if ~isempty(obj.MapSelection), obj.Map.setSelection(obj.MapSelection); end
        end

        function flushMap(obj)
            %FLUSHMAP  Apply what changed since the map was last drawn (affected cells only).
            m = obj.Map;
            if isempty(m) || ~isvalid(m) || isempty(obj.Session) || obj.MapLoadedId ~= obj.Session.Id, return; end
            if obj.MapFull
                obj.MapFull = false;
                obj.MapPending = zeros(0, 1, 'uint32');
                obj.loadMapPoints();
            elseif ~isempty(obj.MapPending)
                ids = obj.MapPending;
                obj.MapPending = zeros(0, 1, 'uint32');
                obj.syncMapIds(ids);
            end
            if obj.MapRegionsDirty
                obj.MapRegionsDirty = false;
                obj.drawMapRegions();
            end
            if obj.MapImageDirty
                obj.MapImageDirty = false;
                obj.applyMapDisplay(m);
            end
        end

        function syncMapIds(obj, ids)
            %SYNCMAPIDS  Make points IDS of the map match the store: added, removed (merged, stale,
            %   gone with an undo), moved and recolored as needed.
            m = obj.Map;
            st = obj.Store;
            ids = unique(uint32(ids(:)));
            if isempty(ids), return; end
            present = ismember(ids, st.get('CellID'));
            draw = false(numel(ids), 1);
            xy = NaN(numel(ids), 2);
            if any(present)
                e = ids(present);
                xy(present, :) = [st.get('X', e), st.get('Y', e)];
                draw(present) = st.get('State', e) == "active" & all(isfinite(xy(present, :)), 2);
            end
            on = m.rowsOf(ids) > 0;
            gone = ids(on & ~draw);
            if ~isempty(gone), m.removePoints(gone); end
            fresh = ~on & draw;
            if any(fresh)
                [rgb, layer] = obj.cellMarkers(ids(fresh));
                m.addPoints(ids(fresh), xy(fresh, :), rgb, layer);
            end
            keep = on & draw;
            if any(keep)
                k = ids(keep);
                kxy = xy(keep, :);
                rows = m.rowsOf(k);
                moved = any(abs(m.XY(rows, :) - kxy) > 1e-6, 2);
                if any(moved), m.movePoints(k(moved), kxy(moved, :)); end
                [rgb, layer] = obj.cellMarkers(k);
                m.updatePoints(k, rgb, layer);
            end
            if ~isempty(obj.MapSelection)
                obj.MapSelection = obj.MapSelection(m.rowsOf(obj.MapSelection) > 0);
            end
        end

        function [rgb, layer] = cellMarkers(obj, ids)
            %CELLMARKERS  Color (0-255) and marker layer of the map points of cells IDS (default:
            %   every row of the store), from their state and the reviewer's markers.
            st = obj.Store;
            if nargin < 2
                a = {};
            else
                a = {ids};
            end
            [rgb, cls] = curation.MapMarkers.forCells(obj.MarkerStyle, st.get('Label', a{:}), ...
                st.get('LabelSource', a{:}), st.get('Flag', a{:}), st.get('Excluded', a{:}), st.get('AuditRole', a{:}));
            [~, layerOf] = curation.MapMarkers.layerStyles(obj.MarkerStyle);
            layer = layerOf(cls);
            layer = layer(:);
        end

        function applyMapDisplay(obj, v)
            %APPLYMAPDISPLAY  The gallery's display mode, brightness and gamma on map view V (side by
            %   side shows the overlay on a map).
            mode = obj.effectiveMode();
            if mode == "side", mode = "overlay"; end
            [g, gam] = obj.displayGG();          % the same mapping as the tiles
            v.setDisplay(mode, g, gam);          % one image refresh
        end

        function mapDisplayChanged(obj)
            if obj.mapShowing() && ~isempty(obj.Session) && obj.MapLoadedId == obj.Session.Id
                obj.applyMapDisplay(obj.Map);
            elseif ~isempty(obj.Map)
                obj.MapImageDirty = true;
            end
            obj.locatorChanged();
        end

        function drawMapRegions(obj)
            if isempty(obj.Map) || ~isvalid(obj.Map) || isempty(obj.Store), return; end
            obj.Map.setRegions(obj.regionList(1));
        end

        function R = regionList(obj, f)
            %REGIONLIST  What the map draws: the dataset's regions that apply to this source, the
            %   reference ROI, and the lasso or the selected region as an outline. F: page pixels per
            %   view pixel (1 for the center map; the locator's shrink factor).
            R = struct('xy', {}, 'kind', {}, 'id', {});
            st = obj.Store;
            if isempty(st), return; end
            key = obj.SourceKey;
            S = st.regions();
            for i = 1:numel(S)
                r = S(i);
                if any(string(r.kind) == ["exclude" "analysis" "reference"]) && ...
                        (string(r.scope) == "image" || string(r.scope) == key) && size(r.xy, 1) >= 3
                    R(end + 1) = struct('xy', r.xy, 'kind', string(r.kind), 'id', r.id); %#ok<AGROW>
                end
            end
            ref = [];
            if ~isempty(obj.Session), ref = obj.Session.Reference; end
            for i = 1:numel(ref)
                R(end + 1) = struct('xy', ref(i).xy, 'kind', "reference", 'id', 0); %#ok<AGROW>
            end
            if f == 1
                if ~isempty(obj.Lasso) && size(obj.Lasso.Polygon, 1) >= 3
                    R(end + 1) = struct('xy', obj.Lasso.Polygon, 'kind', "analysis", 'id', -1);
                elseif obj.SelectedRegion > 0
                    k = find(arrayfun(@(r) r.id == obj.SelectedRegion, S), 1);
                    if ~isempty(k)
                        R(end + 1) = struct('xy', S(k).xy, 'kind', "analysis", 'id', -1);
                    end
                end
            else
                for i = 1:numel(R)
                    R(i).xy = (R(i).xy + (f - 1) / 2) / f;
                end
            end
        end

        function ensureInView(obj, xy)
            %ENSUREINVIEW  Center the map on XY (rows) when any of it is outside the view.
            r = obj.Map.viewRect();
            mx = 0.05 * (r(2) - r(1));
            my = 0.05 * (r(4) - r(3));
            out = xy(:, 1) < r(1) + mx | xy(:, 1) > r(2) - mx | xy(:, 2) < r(3) + my | xy(:, 2) > r(4) - my;
            if ~any(out), return; end
            lo = min(xy, [], 1);
            hi = max(xy, [], 1);
            if size(xy, 1) == 1 || all(hi - lo < 0.5 * [r(2) - r(1), r(4) - r(3)])
                obj.Map.centerOn((lo + hi) / 2);
            else
                pad = 0.25 * max(hi - lo);
                obj.Map.setViewRect([lo(1) - pad, hi(1) + pad, lo(2) - pad, hi(2) + pad]);
            end
        end

        function fitMap(obj)
            if obj.CenterView ~= "map", obj.showCenter("map"); end
            if obj.mapShowing(), obj.Map.fit(); end
        end

        function showMapAt(obj, xy)
            obj.showCenter("map");
            if ~obj.mapShowing(), return; end
            if obj.Map.IsFit
                obj.Map.centerOn(xy, 2 * CellCurator.ShowOnMapUm);
            else
                obj.Map.centerOn(xy);
            end
        end

        function panMap(obj, dx, dy)
            %PANMAP  Arrow keys: move the view a quarter of the map in direction [dx dy] (dy > 0 up).
            if ~obj.mapShowing(), return; end
            p = getpixelposition(obj.Map.Panel, true);
            obj.Map.panBy(-dx * p(3) / 4, -dy * p(4) / 4);
        end

        function zoomMap(obj, factor)
            if obj.mapShowing(), obj.Map.zoomBy(factor); end
        end

        function resetMapState(obj)
            %RESETMAPSTATE  Another source opens: no selection, lasso, region or task carries over.
            obj.MapSelection = zeros(0, 1, 'uint32');
            obj.MapHover = uint32(0);
            obj.cancelLasso(false);
            obj.deselectRegion(false);
            obj.leaveMapTask();
            if ~isempty(obj.Map) && isvalid(obj.Map)
                obj.Map.cancelDrag();
                obj.Map.setSelection([]);
                obj.Map.setHover(0);
            end
        end

        function leaveMapTask(obj)
            %LEAVEMAPTASK  End the Close pairs or Sweep task (the map stays on screen).
            if obj.MapTask == "", return; end
            if ~isempty(obj.Map) && isvalid(obj.Map)
                if obj.MapTask == "sweep", obj.Map.showSweepRect(0); end
                if obj.MapTask == "pairs"
                    obj.MapSelection = zeros(0, 1, 'uint32');
                    obj.Map.setSelection([]);
                    obj.Map.setMarks([]);
                end
            end
            obj.MapTask = "";
            obj.PairList = [];
            obj.showBar("");
            if isfield(obj.UI, 'MapInfo') && ~isempty(obj.UI.MapInfo.Text), obj.UI.MapInfo.Text = ''; end
        end

        function txt = mapContextText(obj)
            %MAPCONTEXTTEXT  The context line while the map shows: what Enter (or the next action)
            %   does now.
            M = @curation.UiText.msg;
            F = @CellCurator.fmtInt;
            st = obj.Store;
            if ~isempty(st) && st.ReadOnly && isempty(obj.MapSelection)
                txt = M('ctxMap', obj.SourceKey, F(st.counts().active), M('ctxReadOnly'));
                return
            end
            if ~isempty(obj.Lasso)
                txt = M('ctxLasso', CellCurator.cellsText(numel(obj.Lasso.Ids)));
                return
            end
            if obj.SelectedRegion > 0
                txt = M('ctxRegion', obj.SelectedRegion, CellCurator.cellsText(obj.cellsInRegion(obj.SelectedRegion)));
                return
            end
            switch obj.MapTask
                case "pairs"
                    n = numel(obj.PairList);
                    if n == 0
                        txt = M('ctxPairsNone', obj.SourceKey);
                    else
                        c = obj.PairList(obj.PairIndex);
                        txt = M('ctxPair', c.Title, obj.PairIndex, n, obj.pairEnterText(c));
                    end
                    return
                case "sweep"
                    n = size(obj.Map.SweepRects, 1);
                    k = obj.Map.SweepIndex;
                    if k >= n
                        txt = M('ctxSweepLast', k, n);
                    else
                        txt = M('ctxSweep', k, n);
                    end
                    return
            end
            sel = obj.MapSelection;
            if isscalar(sel)
                if obj.blindPending(sel)
                    txt = M('ctxMapAudit', double(sel));     % never the label it was confirmed with
                    return
                end
                lab = st.get('Label', sel);
                if lab == "", lab = "not reviewed"; end
                txt = M('ctxMapOne', double(sel), lab);
                return
            elseif numel(sel) > 1
                txt = M('ctxMapMany', CellCurator.cellsText(numel(sel)));
                return
            end
            switch obj.MapTool
                case "add",   tail = M('ctxMapAdd');
                case "move",  tail = M('ctxMapMove');
                case "lasso", tail = M('ctxMapLasso');
                otherwise,    tail = M('ctxMapSelect');
            end
            txt = M('ctxMap', obj.SourceKey, F(st.counts().active), tail);
        end
    end

    %% ======================================================================== warm-up
    methods (Access = private)
        function startWarmUp(obj)
            %STARTWARMUP  While the empty window waits for a folder, run the code a first source
            %   opening needs once on a tiny dataset in a temporary folder (store, crops, queues,
            %   gallery page), so the first real source opens about as fast as the next ones. Once per
            %   MATLAB session; canceled by any input.
            if ~obj.Options.WarmUp || CellCurator.warmedFlag(), return; end
            obj.stopWarmUp();
            t = timer('Name', 'CellCurator warm-up', 'ExecutionMode', 'singleShot', 'StartDelay', 0.3, ...
                'ObjectVisibility', 'off', 'TimerFcn', @(~, ~) obj.warmUp());
            obj.WarmTimer = t;
            start(t);
        end

        function stopWarmUp(obj)
            t = obj.WarmTimer;
            obj.WarmTimer = [];
            if ~isempty(t) && isvalid(t)
                try stop(t); catch, end
                try delete(t); catch, end
            end
        end

        function warmUp(obj)
            obj.stopWarmUp();
            if obj.Closed || obj.Closing || ~isempty(obj.Session) || CellCurator.warmedFlag(), return; end
            t0 = tic;
            d = tempname;
            try
                mkdir(d);
                [ids, xy, tif, csv] = CellCurator.writeWarmDataset(d);
                % the store: manifest, locs, lock, snapshot, journal, a change and its undo
                mfs = CellDatasetManifest.discover(d, struct('WriteManifest', false));
                for k = 1:numel(mfs), mfs(k).toDatasetStruct(d); end
                mf = CellDatasetManifest.forCsv(csv);
                st = curation.Store.open(mf, 'ECM1', struct('AutosaveDelay', 0, 'Reviewer', "warm-up"));
                st.setLabel(ids(1:3), "Good", "human", struct('Queue', "review", 'PageId', "warm"));
                st.counts();
                st.keptMask();
                st.undo();
                T = CellCurator.queueTable(st);
                p = curation.Proposals.current(T, "ECM1");
                curation.Queues.review(T, p, struct('PageSize', 12));
                curation.Queues.summary(T, p, struct('PageSize', 12));
                curation.Queues.flagged(T, struct('PageSize', 12));
                curation.Queues.browse(T, p, "Good", struct('PageSize', 12));
                curation.Pairs.find(st.kept(), 1);
                curation.Regions.excluded(st.regions(), xy, "ECM1");
                st.flush();
                st.close();
                delete(st);
                % the crops and a gallery page (the gallery is under the empty-state panel)
                pageT = imread(tif, 1);
                pageC = imread(tif, 2);
                c = curation.CropCache.build(pageT, pageC, ids, xy, 1);
                page = struct('Kind', "active", 'Ids', ids(1:12), 'Default', "Good");
                style = obj.styleFor(CellCurator.blankPage("none"));
                style.BorderRGB = NaN(12, 3);
                style.CornerRGB = NaN(12, 3);
                % a source's default display is not the identity look-up table (DisplayDefaults):
                % its first use loads the table code (intlut) here, not on the first real page
                style.Gamma = 0.8;
                c.compose(page.Ids, 3, 4, style);
                curation.DisplayDefaults.fromCache(c, struct());
                if isempty(obj.Gallery.Cache) && ~obj.Closed
                    obj.Gallery.setCache(c);
                    obj.Gallery.showPage(page.Ids, style);
                    style.BorderRGB = NaN(0, 3);
                    style.CornerRGB = NaN(0, 3);
                    obj.Gallery.showPage(zeros(0, 1, 'uint32'), style);
                end
                CellCurator.warmedFlag(true);
            catch ME
                warning('CellCurator:warmUp', 'Warm-up skipped: %s', ME.message);
            end
            if obj.Options.Assist && ~obj.Closed
                try
                    % the assist model's background pool starts once per MATLAB session (~1 s)
                    parfeval(backgroundPool, @() 1, 1);
                catch
                end
            end
            try rmdir(d, 's'); catch, end
            obj.LastTimings.WarmUpMs = 1000 * toc(t0);
        end
    end

    methods (Static, Access = private)
        function tf = warmedFlag(set)
            %WARMEDFLAG  Whether the warm-up has run in this MATLAB session (SET true records it).
            persistent done
            if isempty(done), done = false; end
            if nargin > 0, done = logical(set); end
            tf = done;
        end

        function [ids, xy, tif, csv] = writeWarmDataset(d)
            %WRITEWARMDATASET  A tiny two-page float32 TIFF and a locs CSV (deterministic content).
            n = 24;
            k = (0:n - 1)';
            xy = [12 + mod(k, 6) * 8, 12 + floor(k / 6) * 9];
            [X, Y] = meshgrid(1:64, 1:64);
            pg = zeros(64, 64, 'single');
            for i = 1:n
                pg = pg + single(exp(-((X - xy(i, 1)).^2 + (Y - xy(i, 2)).^2) / 8));
            end
            tif = fullfile(d, 'WARM-0001_sec1_proj.tif');
            modes = {'w', 'a'};
            for p = 1:2
                t = Tiff(tif, modes{p});
                tag = struct('ImageLength', 64, 'ImageWidth', 64, 'Photometric', Tiff.Photometric.MinIsBlack, ...
                    'BitsPerSample', 32, 'SamplesPerPixel', 1, 'SampleFormat', Tiff.SampleFormat.IEEEFP, ...
                    'PlanarConfiguration', Tiff.PlanarConfiguration.Chunky, 'Compression', Tiff.Compression.None);
                t.setTag(tag);
                t.write(pg * p);
                t.close();
            end
            s = round(linspace(0.2, 0.95, n)' * 1e3) / 1e3;
            L = table(xy(:, 1), xy(:, 2), zeros(n, 1), s, repmat("WARM-0001_sec1_proj_ECM1", n, 1), ...
                zeros(n, 1), 4 * s - 2, 'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
            csv = fullfile(d, 'WARM-0001_sec1_proj_ECM1_locs.csv');
            writetable(L, csv);
            ids = uint32((1:n)');
        end
    end

    %% ======================================================================== store events
    methods (Access = private)
        function onStoreChanged(obj, sess, e)
            %ONSTORECHANGED  The store's Changed event: keep the crop cache, the map (affected cells
            %   only; queued while it is hidden) and the locator (marked; refreshed only while it
            %   shows) in step. Every edit, undo and redo arrives here.
            if any(string(e.Kind) == ["do" "undo" "redo"]), sess.LastChange = e; end
            kind = string(e.Kind);
            if ~isempty(obj.Assist) && any(kind == ["do" "undo" "redo" "audit"]) && ...
                    (isempty(e.Fields) || any(e.Fields == "Label" | e.Fields == "AuditRole" | e.Fields == "+row"))
                obj.Assist.noteLabels();         % the project is read again within RefreshSec
            end
            if any(e.Fields == "Complete")
                obj.schedule("final");           % _final.csv follows Complete (syncFinal)
            end
            if any(e.Fields == "Complete" | e.Fields == "SweepDone") && ~isempty(obj.Training) && isvalid(obj.Training)
                obj.Training.invalidate();       % what the detector export takes changed
                obj.schedule("panels");          % (the tab, when it shows, asks for a recount)
            end
            if obj.Closed || isempty(obj.Session) || sess ~= obj.Session, return; end
            try
                if kind == "model", return; end
                if any(kind == ["rescore" "audit"])
                    % proposals use rescore, pages hold audit roles: the prefetched next page is stale
                    obj.NextPage = [];
                    obj.FinishCache = [];
                    obj.schedule(["prefetch" "panels"]);
                end
                if kind == "lockLost"
                    obj.MapFull = obj.MapLoadedId == sess.Id;    % the change in progress was reverted
                    if obj.CenterView == "map", obj.flushMap(); end
                    obj.onLockLost();
                    return
                end
                ids = e.CellIDs;
                f = e.Fields;
                if any(f == "Regions") || kind == "regions"
                    obj.MapRegionsDirty = true;
                end
                if any(f == "+row" | f == "X" | f == "Y")
                    obj.syncCacheIds(sess, ids);
                end
                if any(f == "+row") && kind == "undo"
                    obj.VanishCheck = true;          % an added cell is gone again
                end
                if obj.MapLoadedId == sess.Id
                    if isempty(ids)
                        if e.FullRefresh && kind ~= "regions", obj.MapFull = true; end
                    else
                        obj.MapPending = [obj.MapPending; ids(:)];
                    end
                    if obj.CenterView == "map"
                        obj.flushMap();
                    end
                end
                if obj.CenterView == "map"
                    obj.GalleryStale = true;
                end
                obj.locatorChanged();
            catch ME
                obj.reportError(ME);
            end
        end

        function syncCacheIds(~, sess, ids)
            %SYNCCACHEIDS  Crop cache in step for cells IDS: added, moved, gone with an undo.
            c = sess.Cache;
            st = sess.Store;
            if isempty(c) || isempty(ids), return; end
            ids = unique(uint32(ids(:)));
            present = ismember(ids, st.get('CellID'));
            gone = ids(~present);
            if ~isempty(gone), c.remove(gone); end
            e = ids(present);
            if isempty(e), return; end
            xy = [st.get('X', e), st.get('Y', e)];
            ok = all(isfinite(xy), 2);
            e = e(ok);
            xy = xy(ok, :);
            rows = c.rowsOf(e);
            miss = rows == 0;
            if any(miss), c.add(e(miss), xy(miss, :)); end
            have = find(~miss);
            if ~isempty(have)
                moved = any(abs(c.XY(rows(have), :) - xy(have, :)) > 1e-6, 2);
                if any(moved), c.update(e(have(moved)), xy(have(moved), :)); end
            end
        end
    end

    %% ======================================================================== map: events and edits
    methods (Access = private)
        function handled = mapKey(obj, key, ~)
            %MAPKEY  Keys while the map shows; false: the general handler takes the key (display,
            %   help, next source, ...).
            handled = true;
            M = @curation.UiText.msg;
            hasLasso = ~isempty(obj.Lasso);
            task = obj.MapTask;
            switch key
                case "escape", obj.mapEscape();
                case "g", obj.mapLabelKey("Good");
                case "b", obj.mapLabelKey("Bad");
                case "u", obj.mapLabelKey("Uncertain");
                case "f", obj.flagMap(obj.mapTargets());
                case "x", obj.clearMap(obj.mapTargets());
                case "backspace"
                    if task == "sweep", obj.sweepStep(-1); else, obj.clearMap(obj.mapTargets()); end
                case {"return", "space"}, obj.mapEnter();
                case {"leftarrow", "pageup"}
                    if task == "pairs"
                        obj.pairStep(-1);
                    elseif task == "sweep"
                        obj.sweepStep(-1);
                    else
                        obj.panMap(-1, 0);
                    end
                case {"rightarrow", "pagedown"}
                    if task == "pairs"
                        obj.pairStep(1);
                    elseif task == "sweep"
                        obj.sweepStep(1);
                    else
                        obj.panMap(1, 0);
                    end
                case "uparrow",   obj.panMap(0, 1);
                case "downarrow", obj.panMap(0, -1);
                case "e"
                    if hasLasso
                        obj.lassoExclude();
                    else
                        obj.setStatus(M('keyNotNow', 'e', 'Draw a lasso first (Lasso tool [l]); then e makes the area an exclusion region.'));
                    end
                case "j"
                    if hasLasso
                        obj.lassoMerge();
                    elseif task == "pairs"
                        obj.pairMerge();
                    else
                        obj.setStatus(M('keyNotNow', 'j', 'merges the cells of a lasso or a close pair (Close pairs queue).'));
                    end
                case "k"
                    if task == "pairs"
                        obj.pairKeepBoth();
                    else
                        obj.setStatus(M('keyNotNow', 'k', 'keeps both cells of a close pair (Close pairs queue).'));
                    end
                case "delete"
                    if obj.SelectedRegion > 0
                        obj.removeSelectedRegion();
                    else
                        obj.setStatus(M('keyNotNow', 'Del', 'removes an exclusion region: click inside one with the Select tool first.'));
                    end
                case "+", obj.zoomMap(1.5);
                case "-", obj.zoomMap(1 / 1.5);
                case {"tab", "v"}, obj.toggleCenter();
                case ".", obj.setStatus(M('onMapAlready'));
                case "s", obj.setMapTool("select");
                case "a", obj.setMapTool("add");
                case "m", obj.setMapTool("move");
                case "l", obj.setMapTool("lasso");
                otherwise, handled = false;
            end
        end

        function mapEscape(obj)
            if ~isempty(obj.Map) && isvalid(obj.Map) && obj.Map.cancelDrag()
                return
            end
            if ~isempty(obj.Lasso)
                obj.cancelLasso(true);
            elseif obj.SelectedRegion > 0
                obj.deselectRegion(true);
            elseif obj.UI.Cheat.Visible == "on"
                obj.toggleHelp(false);
            elseif obj.MapTool ~= "select"
                obj.setMapTool("select");
                obj.setStatus(curation.UiText.msg('toolSelectOn'));
            elseif ~isempty(obj.MapSelection)
                obj.setMapSelection([]);          % (Close pairs: the pair stays marked)
                obj.setStatus(curation.UiText.msg('selectionCleared'));
            end
        end

        function mapEnter(obj)
            M = @curation.UiText.msg;
            if ~isempty(obj.Lasso)
                obj.setStatus(M('keyNotNow', 'Enter', 'Choose what happens to the lassoed cells: g, b, u, e, j, or Esc.'));
            elseif obj.SelectedRegion > 0
                obj.setStatus(M('keyNotNow', 'Enter', 'Del removes the selected region; Esc keeps it.'));
            elseif obj.MapTask == "pairs"
                obj.pairAccept();
            elseif obj.MapTask == "sweep"
                obj.sweepStep(1);
            elseif ~isempty(obj.MapSelection)
                obj.showInGallery(obj.MapSelection(1));
            else
                obj.setStatus(obj.noMapTargetText());
            end
        end

        function ids = mapTargets(obj)
            %MAPTARGETS  The selected points, else the point under the pointer. In Close pairs the
            %   point under the pointer first (the pair's two cells are marked, not selected), else
            %   the one cell clicked.
            if obj.MapTask == "pairs"
                if obj.MapHover > 0
                    ids = obj.MapHover;
                else
                    ids = obj.MapSelection;
                end
                return
            end
            ids = obj.MapSelection;
            if isempty(ids) && obj.MapHover > 0
                ids = obj.MapHover;
            end
        end

        function s = noMapTargetText(obj)
            if obj.MapTask == "pairs"
                s = curation.UiText.msg('pairNoTarget');
            else
                s = curation.UiText.msg('mapNoTarget');
            end
        end

        function setMapSelection(obj, ids)
            ids = uint32(ids(:));
            obj.MapSelection = ids;
            if ~isempty(obj.Map) && isvalid(obj.Map)
                obj.Map.setSelection(ids);
            end
            obj.updateContext();
            obj.schedule("inspector");
            obj.locatorChanged();
        end

        function onMapPointClick(obj, info)
            obj.LastInputTic = tic;
            id = uint32(info.Id);
            st = string(info.SelectionType);
            if st == "open"
                obj.showInGallery(id);
                return
            end
            if ~isempty(obj.Lasso), obj.cancelLasso(true); end
            if obj.SelectedRegion > 0, obj.deselectRegion(true); end
            % (Close pairs: a click on a cell of the pair selects that cell alone; the pair keeps
            % its marks, so the keys act on the one cell clicked)
            if st == "extend" || any(string(info.Modifier) == "shift")
                sel = obj.MapSelection;
                if any(sel == id)
                    sel = sel(sel ~= id);
                else
                    sel = [sel; id];
                end
                obj.setMapSelection(sel);
            else
                obj.setMapSelection(id);
            end
        end

        function onMapEmptyClick(obj, info)
            obj.LastInputTic = tic;
            st = string(info.SelectionType);
            shift = st == "extend" && any(lower(string(info.Modifier)) == "shift");
            if st ~= "normal" && ~(shift && string(info.Tool) == "add"), return; end
            if ~isempty(obj.Lasso)
                obj.cancelLasso(true);
                return
            end
            switch string(info.Tool)
                case "add"
                    obj.addCellAt(info.XY, shift);          % Shift+click: snapped to its center
                case "select"
                    id = obj.regionAt(info.XY);
                    if id > 0
                        obj.selectRegion(id);
                    else
                        if obj.SelectedRegion > 0, obj.deselectRegion(true); end
                        if ~isempty(obj.MapSelection), obj.setMapSelection([]); end
                    end
                otherwise
                    if ~isempty(obj.MapSelection), obj.setMapSelection([]); end
            end
        end

        function onMapHover(obj, info)
            id = uint32(info.Id);
            if id == obj.MapHover, return; end
            obj.MapHover = id;
            obj.schedule("inspector");
            obj.locatorChanged();
        end

        function onMapPointDrop(obj, info)
            obj.LastInputTic = tic;
            id = uint32(info.Id);
            if ~obj.canEdit()
                obj.Map.movePoints(id, info.FromXY);
                return
            end
            % Shift held as the button is released snaps the drop to the cell's center
            snap = obj.ShiftDown;
            if isfield(info, 'Modifier'), snap = snap || any(lower(string(info.Modifier)) == "shift"); end
            [xy, posSrc, shift] = obj.refinePosition(info.ToXY, snap);
            st = obj.Store;
            st.beginBatch(curation.UiText.msg('txnMove', double(id)));
            try
                st.moveCell(id, xy, posSrc, struct('Queue', "map"));   % Excluded follows (store)
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                if isvalid(obj.Map) && obj.Map.rowsOf(id) > 0
                    obj.Map.movePoints(id, [st.get('X', id), st.get('Y', id)]);
                end
                rethrow(ME);
            end
            st.endBatch();
            obj.setMapSelection(id);
            d = hypot(xy(1) - info.FromXY(1), xy(2) - info.FromXY(2));
            obj.afterMapEdit(curation.UiText.msg('moved', double(id), d, obj.snapText(posSrc, shift)));
        end

        function addCellAt(obj, xy, snap)
            %ADDCELLAT  The Add tool: a new cell (Good, human, reviewed) at XY, snapped to its center
            %   when SNAP (a Shift+click); inside an exclusion region the store excludes it at once.
            if nargin < 3, snap = false; end
            if ~obj.canEdit(), return; end
            [xy, posSrc, shift] = obj.refinePosition(xy, snap);
            st = obj.Store;
            st.beginBatch(curation.UiText.msg('txnAdd', xy(1), xy(2)));
            try
                id = st.addCell(xy, struct('PosSource', posSrc, 'Queue', "map"));
                obj.checkComplete();                 % a new kept cell: no longer complete
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.setMapSelection(id);
            obj.afterMapEdit(curation.UiText.msg('added', double(id), xy(1), xy(2), obj.snapText(posSrc, shift)));
        end

        function [p, posSrc, shift] = refinePosition(obj, xy, snap)
            %REFINEPOSITION  XY refined with snapToCellCentroid when SNAP (Shift held; on a window of
            %   the target page around XY; CellType oval for nets, round for PV). POSSRC "snap" when
            %   the snap moved it, else "human"; SHIFT the distance moved (NaN: no snap asked).
            p = double(xy(1, 1:2));
            posSrc = "human";
            shift = NaN;
            sess = obj.Session;
            if ~snap || isempty(sess) || isempty(sess.PageT), return; end
            um = CellCurator.umOf(obj.Store);
            page = sess.PageT;
            [H, W] = size(page);
            half = max(16, ceil(CellCurator.SnapHalfUm / um));
            c = round(p);
            r1 = max(1, c(2) - half); r2 = min(H, c(2) + half);
            c1 = max(1, c(1) - half); c2 = min(W, c(1) + half);
            if r2 - r1 < 8 || c2 - c1 < 8, return; end
            switch curation.Proposals.kindOf(obj.SourceKey)
                case "pnn", ct = "oval";
                case "pv",  ct = "round";
                otherwise,  ct = "auto";
            end
            shift = 0;
            try
                [q, info] = snapToCellCentroid(page(r1:r2, c1:c2), p - [c1 - 1, r1 - 1], ...
                    'CellType', ct, 'PixelSize', um);
                if info.Snapped(1) && all(isfinite(q(1, :)))
                    p = q(1, :) + [c1 - 1, r1 - 1];
                    posSrc = "snap";
                    shift = info.Shift(1);
                end
            catch ME
                obj.reportError(ME);
            end
        end

        function s = snapText(~, posSrc, shift)
            s = '';
            if isnan(shift), return; end
            if posSrc == "snap"
                s = curation.UiText.msg('snapped', shift);
            else
                s = curation.UiText.msg('snapNone');
            end
        end

        function afterMapEdit(obj, statusText)
            obj.updateContext();
            obj.setStatusLater(statusText);
            obj.schedule(["inspector" "undo" "panels"]);
        end

        function mapLabelKey(obj, label)
            if ~isempty(obj.Lasso)
                obj.lassoLabel(label);
            else
                obj.labelMap(obj.mapTargets(), label);
            end
        end

        function labelMap(obj, ids, label)
            M = @curation.UiText.msg;
            if isempty(ids)
                obj.setStatus(obj.noMapTargetText());
                return
            end
            if ~obj.canEdit(), return; end
            st = obj.Store;
            ids = uint32(ids(:));
            b = obj.blindRole(ids);
            skipped = '';
            if isscalar(ids)
                src = "human";
                if b, src = "blind"; end              % one audit cell, judged on its own: blind
            else
                src = "human";                        % audit cells are labeled one at a time
                if any(b), skipped = M('blindSkipped', CellCurator.cellsText(nnz(b))); end
                ids = ids(~b);
                if isempty(ids)
                    obj.setStatus(M('mapMarked', '0', label) + string(skipped));
                    return
                end
            end
            n = numel(ids);
            st.beginBatch(M('txnMarkMap', CellCurator.cellsText(n), label));
            try
                st.setLabel(ids, label, src, struct('Queue', "map"));
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.afterMapEdit([M('mapMarked', CellCurator.fmtInt(n), label) skipped]);
        end

        function flagMap(obj, ids)
            M = @curation.UiText.msg;
            if isempty(ids)
                obj.setStatus(obj.noMapTargetText());
                return
            end
            if ~obj.canEdit(), return; end
            st = obj.Store;
            n = numel(ids);
            if all(st.get('Flag', ids) ~= "")
                flag = "";
                desc = M('txnUnflag', CellCurator.cellsText(n));
                done = M('mapUnflagged', CellCurator.cellsText(n));
            else
                flag = "later";
                desc = M('txnFlag', CellCurator.cellsText(n));
                done = M('mapFlagged', CellCurator.cellsText(n));
            end
            st.beginBatch(desc);
            try
                st.setFlag(ids, flag, struct('Queue', "map"));
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.afterMapEdit(done);
        end

        function clearMap(obj, ids)
            M = @curation.UiText.msg;
            if isempty(ids)
                obj.setStatus(obj.noMapTargetText());
                return
            end
            if ~obj.canEdit(), return; end
            st = obj.Store;
            ids = uint32(ids(:));
            ids = ids(~obj.blindPending(ids));        % a waiting audit cell has nothing to clear
            if isempty(ids)
                obj.setStatus(M('blindNoClear'));
                return
            end
            n = numel(ids);
            st.beginBatch(M('txnClearMap', CellCurator.cellsText(n)));
            try
                st.setLabel(ids, "", "human", struct('Queue', "map"));
                st.setFlag(ids, "", struct('Queue', "map"));
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.afterMapEdit(M('mapCleared', CellCurator.cellsText(n)));
        end

        function labelAction(obj, label)
            %LABELACTION  The Good / Bad / Uncertain buttons: the selected map points on the map, the
            %   selected (else inspected) tiles in the gallery.
            if obj.CenterView == "map"
                obj.labelMap(obj.mapTargets(), label);
            else
                obj.labelTiles(obj.buttonTargets(), label);
            end
        end

        function flagAction(obj)
            if obj.CenterView == "map"
                obj.flagMap(obj.mapTargets());
            else
                obj.flagTiles(obj.buttonTargets());
            end
        end

        function clearAction(obj)
            if obj.CenterView == "map"
                obj.clearMap(obj.mapTargets());
            else
                obj.clearTiles(obj.buttonTargets());
            end
        end

        function showOnMap(obj, fromButton)
            %SHOWONMAP  [.] or the Show on map button: the pointed-at (or cursor, or inspected) cell
            %   on the map, centered and selected.
            if nargin < 2, fromButton = false; end
            M = @curation.UiText.msg;
            if isempty(obj.Store)
                obj.setStatus(M('mapNoSource'));
                return
            end
            K = numel(obj.Page.Ids);
            ks = [obj.HoverTile, obj.Cursor, obj.InspectedTile];
            if fromButton, ks = [obj.InspectedTile, obj.Cursor, obj.HoverTile]; end
            k = ks(find(ks >= 1 & ks <= K, 1));
            if isempty(k) || ~obj.isTilePage()
                obj.setStatus(M('noTarget'));
                return
            end
            id = obj.Page.Ids(k);
            obj.showCenter("map");
            if ~obj.mapShowing(), return; end
            xy = [obj.Store.get('X', id), obj.Store.get('Y', id)];
            obj.Map.centerOn(xy, CellCurator.ShowOnMapUm);
            obj.setMapSelection(id);
        end

        function showInGallery(obj, id)
            %SHOWINGALLERY  Enter or a double-click on the map: the gallery page that holds cell ID
            %   (its queue chosen from the cell's state), with the cursor on it.
            id = uint32(id);
            st = obj.Store;
            if isempty(st) || ~any(st.get('CellID') == id), return; end
            [queue, why] = obj.queueOf(id);
            if queue == ""
                obj.setStatus(curation.UiText.msg('noGalleryPage', double(id), why));
                return
            end
            obj.showCenter("gallery");
            k = [];
            if obj.isTilePage() && obj.QueueName == queue
                k = find(obj.Page.Ids == id, 1);
            end
            if isempty(k)
                obj.showPageWith(queue, id);
                k = find(obj.Page.Ids == id, 1);
            end
            if ~isempty(k)
                obj.Cursor = k;
                obj.Gallery.setCursor(k);
                obj.InspectedTile = k;
                obj.schedule("inspector");
            end
        end

        function [queue, why] = queueOf(obj, id)
            %QUEUEOF  The gallery queue that shows cell ID, or "" and why there is none.
            st = obj.Store;
            queue = "";
            why = "";
            g = @(f) st.get(f, id);
            if g('State') ~= "active"
                why = "it is " + g('State');
            elseif g('Excluded')
                why = "it is inside an exclusion region";
            elseif g('Flag') ~= ""
                queue = "flagged";
            elseif obj.blindPending(id)
                queue = "review";                    % an audit tile waits on a review page
            elseif g('Reviewed') && any(g('Label') == ["Good" "Bad" "Uncertain"])
                queue = "browse" + g('Label');
            elseif g('Label') == ""
                queue = "review";
            else
                why = "it is labeled but not reviewed";
            end
        end

        function showPageWith(obj, queue, id)
            obj.showQueue(queue);
            if any(obj.Page.Ids == id), return; end
            if queue == "review"
                T = CellCurator.queueTable(obj.Store);
                p = curation.Proposals.current(T, obj.SourceKey);
                pages = curation.Queues.review(T, p, obj.queueOpts(T));
                j = find(arrayfun(@(q) any(q.Ids == id), pages), 1);
                if isempty(j), return; end
                page = CellCurator.fromQueuePage(pages(j), "active");
                done = obj.Session.PagesDone;
                page.Number = done + j;
                page.Total = done + numel(pages);
                obj.showPageStruct(page);
            else
                j = find(arrayfun(@(q) any(q.Ids == id), obj.ListPages), 1);
                if ~isempty(j) && j ~= obj.ListIndex
                    obj.ListIndex = j;
                    obj.showPageStruct(obj.listPageAt(j));
                end
            end
        end

        function afterMapReplay(obj, ids)
            %AFTERMAPREPLAY  Undo or redo while the map shows: the map is in step already; the task
            %   on screen (lasso, region, close pairs) follows.
            obj.cancelLasso(false);
            if obj.SelectedRegion > 0 && ~any(arrayfun(@(r) r.id == obj.SelectedRegion, obj.Store.regions()))
                obj.deselectRegion(false);
            end
            obj.drawMapRegions();
            if obj.MapTask == "pairs"
                obj.PairList = obj.findPairs();
                k = [];
                if ~isempty(ids) && ~isempty(obj.PairList)
                    k = find(arrayfun(@(c) any(ismember(c.Ids, ids)), obj.PairList), 1);
                end
                if isempty(k), k = min(max(1, obj.PairIndex), numel(obj.PairList)); end
                obj.showPair(k);
            end
            obj.GalleryStale = true;
            obj.updateContext();
        end
    end

    %% ======================================================================== lasso and regions
    methods (Access = private)
        function onMapLasso(obj, info)
            obj.LastInputTic = tic;
            if ~obj.canEdit(), return; end
            ids = uint32(info.Ids(:));
            obj.deselectRegion(false);
            obj.Lasso = struct('Polygon', double(info.Polygon), 'Ids', ids);
            n = numel(ids);
            obj.UI.LassoText.Text = sprintf('%s:', CellCurator.cellsText(n));
            on = matlab.lang.OnOffSwitchState(n >= 1);
            set([obj.UI.LassoGood obj.UI.LassoBad obj.UI.LassoUnc], 'Enable', on);
            obj.UI.LassoMerge.Enable = matlab.lang.OnOffSwitchState(n >= 2);
            obj.showBar("lasso");
            obj.setMapSelection(ids);
            obj.drawMapRegions();
            if n == 0
                obj.setStatus(curation.UiText.msg('lassoEmpty'));
            end
        end

        function cancelLasso(obj, redraw)
            %CANCELLASSO  Every state change first (lasso, selection), the bar's relayout last (it
            %   waits for nothing on the key path: setBarRow finishes the layout at idle), so a key
            %   processed meanwhile never acts on the lasso's cells.
            if isempty(obj.Lasso), return; end
            obj.Lasso = [];
            if redraw
                obj.setMapSelection([]);
                obj.drawMapRegions();
                obj.updateContext();
            end
            obj.showBar(obj.taskBar());
        end

        function name = taskBar(obj)
            %TASKBAR  The bar that belongs to the task on screen (when no lasso or region is up).
            switch obj.MapTask
                case "pairs", name = "pair";
                case "sweep", name = "sweep";
                otherwise,    name = "";
            end
        end

        function lassoLabel(obj, label)
            ids = obj.Lasso.Ids;
            if isempty(ids)
                obj.setStatus(curation.UiText.msg('lassoEmpty'));
                return
            end
            if ~obj.canEdit(), return; end
            st = obj.Store;
            b = obj.blindRole(ids);                  % audit cells are labeled one at a time
            skipped = '';
            if any(b), skipped = curation.UiText.msg('blindSkipped', CellCurator.cellsText(nnz(b))); end
            ids = ids(~b);
            if isempty(ids)
                obj.cancelLasso(true);
                obj.setStatus([curation.UiText.msg('lassoMarked', '0', label) skipped]);
                return
            end
            n = numel(ids);
            st.beginBatch(curation.UiText.msg('txnLasso', CellCurator.cellsText(n), label));
            try
                st.setLabel(ids, label, "human", struct('Queue', "map"));
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.cancelLasso(true);
            obj.afterMapEdit([curation.UiText.msg('lassoMarked', CellCurator.fmtInt(n), label) skipped]);
        end

        function lassoExclude(obj)
            %LASSOEXCLUDE  The lassoed area becomes an exclusion region (scope image: every channel of
            %   the section) and the cells inside are excluded: one transaction.
            if ~obj.canEdit(), return; end
            st = obj.Store;
            poly = obj.Lasso.Polygon;
            nIn = nnz(obj.insidePolygon(poly));
            before = st.get('Excluded');
            st.beginBatch(curation.UiText.msg('txnExclude', CellCurator.cellsText(nIn)));
            try
                r = curation.Regions.make("exclude", poly, struct('scope', "image", ...
                    'note', "Drawn in CellCurator on " + obj.SourceKey));
                % the store excludes the cells inside itself, in the same undo step
                id = st.addRegion(r, struct('Queue', "map"));
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            nOn = nnz(st.get('Excluded') & ~before & st.get('State') == "active");
            obj.cancelLasso(true);
            obj.afterMapEdit(curation.UiText.msg('excludedRegion', id, CellCurator.cellsText(nOn)));
        end

        function lassoMerge(obj)
            ids = obj.Lasso.Ids;
            if numel(ids) < 2
                obj.setStatus(curation.UiText.msg('mergeNeedsTwo'));
                return
            end
            if ~obj.canEdit(), return; end
            keeper = obj.keeperOf(ids);
            obj.mergeInto(ids, keeper);
            obj.cancelLasso(true);
        end

        function mergeInto(obj, ids, keeper)
            st = obj.Store;
            n = numel(ids) - 1;
            st.beginBatch(curation.UiText.msg('txnMerge', CellCurator.cellsText(n), double(keeper)));
            try
                st.mergeCells(ids, keeper, [], struct('Queue', "map"));
                obj.checkComplete();                 % the kept cells changed
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.setMapSelection(keeper);
            obj.afterMapEdit(curation.UiText.msg('mergedCells', CellCurator.cellsText(n), double(keeper)));
        end

        function keeper = keeperOf(obj, ids)
            %KEEPEROF  The cell a merge keeps: highest rescore, then highest score, then lowest id.
            st = obj.Store;
            r = st.get('rescore', ids);
            s = st.get('score', ids);
            r(~isfinite(r)) = -Inf;
            s(~isfinite(s)) = -Inf;
            K = sortrows([-r, -s, double(ids(:))]);
            keeper = uint32(K(1, 3));
        end

        function tf = insidePolygon(obj, poly)
            st = obj.Store;
            xy = [st.get('X'), st.get('Y')];
            tf = st.get('State') == "active" & inpolygon(xy(:, 1), xy(:, 2), poly(:, 1), poly(:, 2));
        end

        function msg = applyRegionsOnOpen(obj)
            %APPLYREGIONSONOPEN  A source comes on screen: re-read the regions (the other channel may
            %   have drawn one; the store brings Excluded in line itself), say what changed, and undo
            %   Complete if work appeared (a
            %   re-detection). One transaction; returns a note for the status bar ("" when nothing
            %   changed).
            msg = "";
            st = obj.Store;
            if isempty(st), return; end
            % the store keeps Excluded == "inside an exclude region" itself (at its open and when
            % it re-reads the regions); a source opened earlier re-reads them now
            act = st.get('State') == "active";
            before = st.get('Excluded');
            try
                st.reloadRegions();
            catch ME
                obj.reportError(ME);
            end
            after = st.get('Excluded');
            nOn = nnz(act & after & ~before);
            nOff = nnz(act & before & ~after);
            if nOn + nOff > 0
                msg = string(curation.UiText.msg('regionsApplied', obj.SourceKey, ...
                    CellCurator.cellsText(nOn), CellCurator.cellsText(nOff)));
            elseif nnz(act & after) > 0 && isempty(obj.Session.History) && obj.Session.PagesDone == 0
                msg = string(curation.UiText.msg('regionsAtOpen', CellCurator.cellsText(nnz(act & after)), ...
                    obj.SourceKey));
            end
            if st.ReadOnly, return; end
            % a re-detection may have brought new cells to review: a complete source is not
            st.beginBatch(curation.UiText.msg('txnNotComplete'));
            try
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                obj.reportError(ME);
                return
            end
            st.endBatch();
            if ~isempty(obj.Notice)
                msg = strtrim(msg + " " + string(obj.Notice));
                obj.Notice = '';
            end
        end

        function id = regionAt(obj, xy)
            %REGIONAT  The exclusion region (applying to this source) under image point XY, 0 if none.
            id = 0;
            R = obj.Store.regions();
            for i = numel(R):-1:1
                r = R(i);
                if string(r.kind) == "exclude" && (string(r.scope) == "image" || string(r.scope) == obj.SourceKey) ...
                        && size(r.xy, 1) >= 3 && inpolygon(xy(1), xy(2), r.xy(:, 1), r.xy(:, 2))
                    id = r.id;
                    return
                end
            end
        end

        function n = cellsInRegion(obj, id)
            n = 0;
            R = obj.Store.regions();
            k = find(arrayfun(@(r) r.id == id, R), 1);
            if isempty(k), return; end
            n = nnz(obj.insidePolygon(R(k).xy));
        end

        function selectRegion(obj, id)
            obj.SelectedRegion = id;
            if ~isempty(obj.MapSelection), obj.setMapSelection([]); end
            R = obj.Store.regions();
            r = R(find(arrayfun(@(q) q.id == id, R), 1));
            a = curation.Regions.areaUm2(r, CellCurator.umOf(obj.Store)) / 1e6;
            obj.UI.RegionText.Text = sprintf('Exclusion region %d %s %s inside %s %.3f mm%s', id, ...
                char(183), CellCurator.cellsText(obj.cellsInRegion(id)), char(183), a, char(178));
            obj.showBar("region");
            obj.drawMapRegions();
            obj.updateContext();
            obj.setStatus(curation.UiText.msg('regionSelected', id));
        end

        function deselectRegion(obj, redraw)
            if obj.SelectedRegion == 0, return; end
            obj.SelectedRegion = 0;
            obj.showBar(obj.taskBar());
            if redraw
                obj.drawMapRegions();
                obj.updateContext();
            end
        end

        function removeSelectedRegion(obj)
            %REMOVESELECTEDREGION  Del: remove the selected exclusion region and include its cells
            %   again (unless another region covers them): one transaction.
            id = obj.SelectedRegion;
            if id == 0 || ~obj.canEdit(), return; end
            st = obj.Store;
            before = st.get('Excluded');
            st.beginBatch(curation.UiText.msg('txnRemoveRegion', id));
            try
                st.removeRegion(id, struct('Queue', "map"));    % the store includes its cells again
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            nOff = nnz(before & ~st.get('Excluded') & st.get('State') == "active");
            obj.deselectRegion(true);
            obj.afterMapEdit(curation.UiText.msg('regionRemoved', id, CellCurator.cellsText(nOff)));
        end
    end

    %% ======================================================================== close pairs and sweep
    methods (Access = private)
        function C = findPairs(obj)
            %FINDPAIRS  Close-pair clusters of the kept cells (pairs judged separate left out).
            C = [];
            st = obj.Store;
            if isempty(st), return; end
            m = st.keptMask();
            T = table(st.get('CellID'), st.get('X'), st.get('Y'), st.get('score'), st.get('rescore'), ...
                st.get('State'), st.get('Label'), st.get('Reviewed'), st.get('Excluded'), ...
                'VariableNames', {'CellID', 'X', 'Y', 'score', 'rescore', 'State', 'Label', 'Reviewed', 'Excluded'});
            P = curation.Pairs.find(T(m, :), CellCurator.umOf(st), struct('KeptPairs', st.Meta.KeptPairs));
            tmpl = struct('Ids', zeros(0, 1, 'uint32'), 'XY', zeros(0, 2), 'Centroid', [NaN NaN], ...
                'MinDistUm', NaN, 'MaxDistUm', NaN, 'Proposal', "keepBoth", 'KeeperId', uint32(0), ...
                'Edges', zeros(0, 2, 'uint32'), 'Title', "", 'Kind', "close");
            C = repmat(tmpl, numel(P), 1);
            names = fieldnames(P);
            for k = 1:numel(P)
                for f = 1:numel(names), C(k).(names{f}) = P(k).(names{f}); end
            end
            C = [obj.nearKeptPairs(tmpl, C, m); C];
        end

        function E = nearKeptPairs(obj, tmpl, C, kept)
            %NEARKEPTPAIRS  The reconcile's new detections that lie next to a reviewed, kept cell and
            %   are still unreviewed: a close pair each, proposal "merge into the reviewed cell" (the
            %   kept-cell clusters of curation.Pairs cannot hold an unreviewed newcomer).
            E = repmat(tmpl, 0, 1);
            sess = obj.Session;
            if isempty(sess) || isempty(sess.NearKept), return; end
            st = obj.Store;
            ids = st.get('CellID');
            act = st.get('State') == "active" & ~st.get('Excluded');
            rev = st.get('Reviewed');
            X = st.get('X');
            Y = st.get('Y');
            K = st.Meta.KeptPairs;
            um = CellCurator.umOf(st);
            for r = 1:size(sess.NearKept, 1)
                a = sess.NearKept(r, 1);
                b = sess.NearKept(r, 2);
                ra = find(ids == a, 1);
                rb = find(ids == b, 1);
                if isempty(ra) || isempty(rb) || ~act(ra) || rev(ra) || ~kept(rb), continue; end
                pr = sort(uint32([a b]));
                if ~isempty(K) && ismember(pr, K, 'rows'), continue; end
                if any(arrayfun(@(q) all(ismember(pr, q.Ids)), C)), continue; end
                if pr(1) == a, rows = [ra; rb]; else, rows = [rb; ra]; end
                xy = [X(rows), Y(rows)];
                d = hypot(xy(1, 1) - xy(2, 1), xy(1, 2) - xy(2, 2)) * um;
                s = tmpl;
                s.Ids = pr(:);
                s.XY = xy;
                s.Centroid = mean(xy, 1);
                s.MinDistUm = d;
                s.MaxDistUm = d;
                s.Proposal = "merge";
                s.KeeperId = uint32(b);
                s.Edges = pr;
                s.Title = string(curation.UiText.msg('nearKeptTitle', d, double(b)));
                s.Kind = "nearKept";
                E(end + 1, 1) = s; %#ok<AGROW>
            end
        end

        function startPairs(obj)
            obj.leaveMapTask();
            obj.showCenter("map");
            if ~obj.mapShowing(), return; end
            obj.cancelLasso(false);
            obj.deselectRegion(false);
            obj.setMapTool("select");
            obj.QueueName = "closePairs";
            obj.MapTask = "pairs";
            obj.PairList = obj.findPairs();
            obj.PairIndex = 1;
            obj.showPair(1);
            if ~strcmp(obj.UI.Queues.Value, obj.QueueName), obj.UI.Queues.Value = char(obj.QueueName); end
            n = numel(obj.PairList);
            if n > 0
                obj.setStatus(curation.UiText.msg('showPairs', sprintf('%s %s', CellCurator.fmtInt(n), ...
                    CellCurator.plural(n, 'pair', 'pairs'))));
            end
            obj.schedule("panels");
        end

        function c = currentPair(obj)
            c = [];
            if obj.MapTask == "pairs" && obj.PairIndex >= 1 && obj.PairIndex <= numel(obj.PairList)
                c = obj.PairList(obj.PairIndex);
            end
        end

        function showPair(obj, k)
            %SHOWPAIR  Close pair K on the map: zoomed to about 60 um, its cells ringed, the bar
            %   offering the proposal first.
            n = numel(obj.PairList);
            if n == 0
                obj.PairIndex = 0;
                obj.showBar("");
                obj.Map.setMarks([]);
                obj.setMapSelection([]);
                obj.UI.MapInfo.Text = '';
                obj.setStatus(curation.UiText.msg('pairsNone', obj.SourceKey));
                obj.updateContext();
                return
            end
            k = min(max(1, k), n);
            obj.PairIndex = k;
            c = obj.PairList(k);
            obj.showBar("pair");                  % first: the view fits the map below the bar
            obj.Map.centerOn(c.Centroid, CellCurator.PairViewUm);
            if c.Kind == "nearKept"
                a = 'pairAcceptMergeReviewed'; o = 'pairOtherKeep';
            elseif c.Proposal == "merge"
                a = 'pairAcceptMerge'; o = 'pairOtherKeep';
            else
                a = 'pairAcceptKeep'; o = 'pairOtherMerge';
            end
            U = @curation.UiText.label;
            T = @curation.UiText.tip;
            if ~strcmp(obj.UI.PairAccept.Text, U(a))
                obj.UI.PairAccept.Text = U(a);
                CellToolkit.setTooltip(obj.UI.PairAccept, T(a));
                obj.UI.PairOther.Text = U(o);
                CellToolkit.setTooltip(obj.UI.PairOther, T(o));
            end
            txt = sprintf('Pair %d of %d', k, n);
            if ~strcmp(obj.UI.PairText.Text, txt), obj.UI.PairText.Text = txt; end
            % the pair's cells are marked, not selected: g/b/u/f/x act on the cell under the pointer
            % (or one clicked), never on both at once
            obj.Map.setMarks(c.Ids);
            obj.setMapSelection([]);
            obj.ItemShownTic = tic;
        end

        function s = pairEnterText(obj, c)
            M = @curation.UiText.msg;
            if c.Kind == "nearKept"
                s = M('ctxPairMergeReviewed', double(c.KeeperId));
            elseif c.Proposal == "merge"
                r = obj.Store.get('rescore', c.KeeperId);
                if isfinite(r), rs = sprintf('%.1f', r); else, rs = 'none'; end
                s = M('ctxPairMerge', double(c.KeeperId), rs);
            else
                s = M('ctxPairKeep');
            end
        end

        function pairAccept(obj)
            c = obj.currentPair();
            if isempty(c), return; end
            if c.Proposal == "merge"
                obj.pairMerge();
            else
                obj.pairKeepBoth();
            end
        end

        function pairOther(obj)
            c = obj.currentPair();
            if isempty(c), return; end
            if c.Proposal == "merge"
                obj.pairKeepBoth();
            else
                obj.pairMerge();
            end
        end

        function pairMerge(obj)
            c = obj.currentPair();
            if isempty(c) || ~obj.canEdit(), return; end
            st = obj.Store;
            n = numel(c.Ids) - 1;
            st.beginBatch(curation.UiText.msg('txnMerge', CellCurator.cellsText(n), double(c.KeeperId)));
            try
                st.mergeCells(c.Ids, c.KeeperId, [], struct('Queue', "closePairs"));
                obj.checkComplete();
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.afterPairAction(curation.UiText.msg('pairMerged', CellCurator.cellsText(n), double(c.KeeperId)));
        end

        function pairKeepBoth(obj)
            c = obj.currentPair();
            if isempty(c) || ~obj.canEdit(), return; end
            st = obj.Store;
            ids = strjoin(string(c.Ids'), ", ");
            st.beginBatch(curation.UiText.msg('txnPairKeep', ids));
            try
                st.keepBoth(c.Edges, struct('Queue', "closePairs"));
            catch ME
                st.cancelBatch();
                rethrow(ME);
            end
            st.endBatch();
            obj.afterPairAction(curation.UiText.msg('pairKept', ids));
        end

        function afterPairAction(obj, statusText)
            k = obj.PairIndex;
            obj.PairList = obj.findPairs();
            obj.showPair(k);
            obj.afterMapEdit(statusText);
        end

        function pairStep(obj, d)
            n = numel(obj.PairList);
            if n == 0, return; end
            k = obj.PairIndex + d;
            if k > n
                k = 1;
                obj.setStatus(curation.UiText.msg('pairWrap'));
            elseif k < 1
                obj.setStatus(curation.UiText.msg('pairFirst'));
                return
            end
            obj.showPair(k);
            obj.updateContext();
        end

        function startSweep(obj)
            %STARTSWEEP  The missed-cell sweep: the map steps through fields of SweepFieldUm with the
            %   Add tool; it resumes at the field reached in this source.
            obj.leaveMapTask();
            wasShowing = obj.mapShowing();
            obj.showCenter("map");
            if ~obj.mapShowing(), return; end
            if ~wasShowing, drawnow; end          % sweepRects needs the map's real size
            obj.cancelLasso(false);
            obj.deselectRegion(false);
            obj.QueueName = "sweep";
            obj.MapTask = "sweep";
            obj.showBar("sweep");                 % first: the fields fit the map below the bar
            rects = obj.Map.sweepRects(obj.SweepFieldUm, CellCurator.SweepOverlap);
            n = size(rects, 1);
            k = obj.Session.SweepField;
            M = @curation.UiText.msg;
            if k >= 1 && k <= n
                msg = M('sweepResume', k, n);
            else
                k = 1;
                msg = M('sweepStart', n, round(obj.SweepFieldUm));
            end
            if ~obj.Store.ReadOnly, obj.setMapTool("add"); end
            obj.setMapSelection([]);
            if isfield(obj.UI, 'SweepWidth') && obj.UI.SweepWidth.Value ~= obj.SweepFieldUm
                obj.UI.SweepWidth.Value = obj.SweepFieldUm;
            end
            obj.showSweepField(k);
            if ~strcmp(obj.UI.Queues.Value, obj.QueueName), obj.UI.Queues.Value = char(obj.QueueName); end
            obj.setStatus(msg);
        end

        function showSweepField(obj, k)
            n = size(obj.Map.SweepRects, 1);
            obj.Map.showSweepRect(k);
            obj.Session.SweepField = k;
            obj.ItemShownTic = tic;              % Enter's key-repeat guard counts from here
            txt = sprintf('Field %d of %d', k, n);
            if ~strcmp(obj.UI.SweepText.Text, txt), obj.UI.SweepText.Text = txt; end
            obj.updateContext();
        end

        function sweepStep(obj, d)
            if obj.MapTask ~= "sweep", return; end
            n = size(obj.Map.SweepRects, 1);
            k = obj.Map.SweepIndex + d;
            if k > n
                obj.finishSweep();
            elseif k < 1
                obj.setStatus(curation.UiText.msg('sweepFirst'));
            else
                obj.showSweepField(k);
            end
        end

        function finishSweep(obj)
            n = size(obj.Map.SweepRects, 1);
            if ~obj.Store.ReadOnly
                obj.Store.setSweepDone(true);
            end
            obj.Session.SweepField = 0;
            obj.leaveMapTask();
            obj.showCenter("gallery");
            obj.showQueue("review");
            obj.setStatus(curation.UiText.msg('sweepDone', n, obj.SourceKey));
        end

        function s = sweepItemText(obj)
            s = '';
            st = obj.Store;
            if isempty(st) || isempty(obj.Session), return; end
            M = @curation.UiText.msg;
            if obj.MapTask == "sweep" && ~isempty(obj.Map)
                s = M('sweepAt', obj.Map.SweepIndex);
            elseif logical(st.Meta.SweepDone)
                s = M('sweepDoneItem');
            elseif obj.Session.SweepField > 0
                s = M('sweepAt', obj.Session.SweepField);
            else
                s = M('sweepOptional');
            end
        end
    end

    %% ======================================================================== finishing a source
    methods (Access = private)
        function F = finishState(obj)
            %FINISHSTATE  What the finish checklist shows (cached per store revision): ToReview,
            %   Flagged, Pairs, Vanished, SweepDone, Complete, Kept, Open (what still blocks
            %   completing, as text), Can (it can be completed now).
            st = obj.Store;
            key = obj.Session.Id + "#" + st.Meta.Revision;
            if ~isempty(obj.FinishCache) && obj.FinishCache.Key == key
                F = obj.FinishCache.F;
                return
            end
            M = @curation.UiText.msg;
            c = st.counts();
            [nRev, nFlag, nAudit] = obj.openCounts();
            F = struct();
            F.ToReview = nRev;
            F.Audit = nAudit;
            F.Flagged = nFlag;
            F.Pairs = numel(obj.findPairs());
            F.Vanished = c.vanishedGood;
            F.SweepDone = logical(st.Meta.SweepDone);
            F.Complete = logical(st.Meta.Complete);
            F.Kept = c.kept;
            F.Rescore = 0;                       % optional: never blocks completing
            if isfield(c, 'rescorePending'), F.Rescore = c.rescorePending; end
            open = strings(1, 0);
            if nRev > 0, open(end + 1) = M('partToReview', CellCurator.cellsText(nRev)); end
            if nAudit > 0, open(end + 1) = M('partAudit', CellCurator.auditText(nAudit)); end
            if nFlag > 0, open(end + 1) = M('partFlagged', CellCurator.fmtInt(nFlag)); end
            if F.Pairs > 0
                open(end + 1) = M('partPairs', CellCurator.fmtInt(F.Pairs), CellCurator.plural(F.Pairs, 'pair', 'pairs'));
            end
            F.Open = open;
            F.Can = isempty(open) && ~F.Complete;
            obj.FinishCache = struct('Key', key, 'F', F);
        end

        function [nRev, nFlag, nAudit] = openCounts(obj)
            %OPENCOUNTS  Ordinary cells the Review queue still holds, flagged cells, and audit tiles
            %   waiting for their blind judgment (active, not excluded).
            st = obj.Store;
            act = st.get('State') == "active" & ~st.get('Excluded');
            flg = st.get('Flag') ~= "";
            role = st.get('AuditRole');
            nRev = nnz(act & ~st.get('Reviewed') & st.get('Label') == "" & ~flg & role == "");
            nFlag = nnz(act & flg);
            nAudit = nnz(act & ~flg & curation.BlindTiles.roleMask(role) & st.get('LabelSource') ~= "blind");
        end

        function checkComplete(obj)
            %CHECKCOMPLETE  Inside an open batch: a complete source with cells to review or flagged
            %   again goes back to incomplete in the same transaction (one undo step).
            try
                st = obj.Store;
                if isempty(st) || st.ReadOnly || ~logical(st.Meta.Complete), return; end
                [nRev, nFlag, nAudit] = obj.openCounts();
                M = @curation.UiText.msg;
                if nRev + nFlag + nAudit == 0
                    % the kept cells changed (a label, an added, moved or merged cell, a region):
                    % _final.csv no longer says what the source holds, so it is no longer complete
                    sig = obj.Session.FinalSig;
                    if strlength(sig) > 0 && sig ~= CellCurator.keptSignature(st)
                        st.setComplete(false);
                        obj.Notice = M('notCompleteKept', obj.SourceKey);
                    end
                    return
                end
                st.setComplete(false);
                parts = strings(1, 0);
                if nRev > 0, parts(end + 1) = M('partToReview', CellCurator.cellsText(nRev)); end
                if nAudit > 0, parts(end + 1) = M('partAudit', CellCurator.auditText(nAudit)); end
                if nFlag > 0, parts(end + 1) = M('partFlagged', CellCurator.fmtInt(nFlag)); end
                obj.Notice = M('notComplete', obj.SourceKey, char(strjoin(parts, ', ')));
            catch ME
                obj.reportError(ME);
            end
        end

        function syncFinal(obj)
            %SYNCFINAL  (idle, after Complete changed) <stem>_final.csv exists exactly while the source
            %   is complete: an undo that brings Complete back writes it again (the kept cells are
            %   again those it was completed with); Complete cleared or undone renames it
            %   <stem>_final.stale.csv, so it never looks current.
            st = obj.Store;
            sess = obj.Session;
            if isempty(st) || ~isvalid(st) || st.ReadOnly || isempty(sess), return; end
            p = char(st.Paths.final);
            if isempty(p), return; end
            if logical(st.Meta.Complete)
                if ~isfile(p)
                    try
                        st.exportFinal(p);
                    catch ME
                        obj.reportError(ME);
                        return
                    end
                end
                sess.FinalSig = CellCurator.keptSignature(st);
            elseif isfile(p)
                q = CellCurator.retireFinal(p);
                sess.FinalSig = "";
                if ~isempty(q)
                    [~, nm, ex] = fileparts(q);
                    obj.Notice = curation.UiText.msg('finalStaled', obj.SourceKey, [nm ex]);
                    obj.setStatus(obj.StatusText);
                end
            end
        end

        function showFinish(obj)
            if obj.UI.Message.Visible == "on", obj.UI.Message.Visible = 'off'; end
            obj.refreshFinish();
            if obj.UI.Finish.Visible ~= "on", obj.UI.Finish.Visible = 'on'; end
        end

        function refreshFinish(obj)
            %REFRESHFINISH  The checklist's texts, enabled buttons and tooltips.
            if isempty(obj.Store) || isempty(obj.Session), return; end
            M = @curation.UiText.msg;
            T = @curation.UiText.tip;
            Dz = @curation.UiText.disabled;
            Fm = @CellCurator.fmtInt;
            F = obj.finishState();
            key = obj.SourceKey;
            if F.Complete
                obj.setText(obj.UI.FinTitle, M('finTitleDone', key));
                [~, nm, ex] = fileparts(obj.Store.Paths.final);
                obj.setText(obj.UI.FinWhy, M('finWhyDone', Fm(F.Kept), [nm ex]));
            else
                obj.setText(obj.UI.FinTitle, M('finTitle', key));
                if F.Can
                    obj.setText(obj.UI.FinWhy, M('finWhyReady'));
                else
                    obj.setText(obj.UI.FinWhy, M('finWhyTodo', char(strjoin(F.Open, ', '))));
                end
            end
            if F.ToReview == 0
                obj.setText(obj.UI.FinUnreviewed, M('finUnreviewed', M('finOk')));
            else
                obj.setText(obj.UI.FinUnreviewed, M('finUnreviewed', Fm(F.ToReview)));
            end
            items = {obj.UI.FinAudit, 'finishAudit', 'finAudit', F.Audit, 'finActAudit'
                obj.UI.FinFlagged, 'finishFlagged', 'finFlagged', F.Flagged, 'finActFlagged'
                obj.UI.FinPairs, 'finishPairs', 'finPairs', F.Pairs, 'finActPairs'
                obj.UI.FinVanished, 'finishVanished', 'finVanished', F.Vanished, 'finActVanished'};
            for i = 1:size(items, 1)
                [b, id, fmt, n, act] = items{i, :};
                if n == 0
                    % satisfied: clearly readable and visibly done (a disabled button grays its text)
                    txt = M('finDone', M(fmt, M('finOk')));
                    tip = M('finDoneTip', T(id));
                    bgc = [0.17 0.30 0.23]; fc = [0.86 0.96 0.89];
                else
                    txt = M(fmt, M('finOpen', Fm(n), M(act)));
                    tip = T(id);
                    bgc = [0.96 0.96 0.96]; fc = [0.10 0.10 0.10];
                end
                obj.setText(b, txt);
                obj.setEnable(b, true, tip, tip);
                if ~isequal(b.BackgroundColor, bgc), b.BackgroundColor = bgc; end
                if ~isequal(b.FontColor, fc), b.FontColor = fc; end
            end
            if F.SweepDone
                obj.setText(obj.UI.FinSweep, M('finSweepDone'));
            elseif obj.Session.SweepField > 0
                n = max(obj.Session.SweepField, 1);
                total = n;
                if ~isempty(obj.Map) && isvalid(obj.Map), total = max(n, size(obj.Map.SweepRects, 1)); end
                obj.setText(obj.UI.FinSweep, M('finSweepPart', n, total));
            else
                obj.setText(obj.UI.FinSweep, M('finSweepNot'));
            end
            obj.setEnable(obj.UI.FinSweep, true, T('finishSweep'), T('finishSweep'));
            obj.refreshRescoreControls(F.Rescore);
            % the button stays readable in every state (a disabled button on the dark panel is not):
            % complete = the done color; blocked = what comes first, and a click says so
            b = obj.UI.FinComplete;
            if F.Complete
                obj.setText(b, M('finCompleted'));
                tip = Dz('finishComplete', M('finAlready'));
                obj.setEnable(b, true, tip, tip);
                bgc = [0.17 0.30 0.23]; fc = [0.86 0.96 0.89];
            elseif obj.Store.ReadOnly
                obj.setText(b, curation.UiText.label('finishComplete'));
                obj.setEnable(b, false, T('finishComplete'), Dz('finishComplete', obj.readOnlyWhy()));
                bgc = [0.80 0.88 0.98]; fc = [0.10 0.10 0.10];
            elseif F.Can
                obj.setText(b, curation.UiText.label('finishComplete'));
                obj.setEnable(b, true, T('finishComplete'), T('finishComplete'));
                bgc = [0.80 0.88 0.98]; fc = [0.10 0.10 0.10];
            else
                obj.setText(b, M('finCompleteFirst', curation.UiText.label('finishComplete'), char(strjoin(F.Open, ', '))));
                tip = Dz('finishComplete', M('finWhyOpen', char(strjoin(F.Open, ', '))));
                obj.setEnable(b, true, tip, tip);
                bgc = [0.30 0.30 0.33]; fc = [0.88 0.88 0.88];
            end
            if ~isequal(b.BackgroundColor, bgc), b.BackgroundColor = bgc; end
            if ~isequal(b.FontColor, fc), b.FontColor = fc; end
            [di, si] = obj.nextWorkSource();
            if di > 0
                d = obj.Datasets(di);
                t = T('finishNext', sprintf('%s of %s', d.Sources(si).Key, d.Base));
                if ~strcmp(obj.UI.FinNext.Tooltip, t), CellToolkit.setTooltip(obj.UI.FinNext, t); end
                if obj.UI.FinNext.Visible ~= "on", obj.UI.FinNext.Visible = 'on'; end
            elseif obj.UI.FinNext.Visible == "on"
                obj.UI.FinNext.Visible = 'off';
            end
        end

        function txt = finishContext(obj)
            M = @curation.UiText.msg;
            F = obj.finishState();
            [di, si] = obj.nextWorkSource();
            key = obj.SourceKey;
            if di > 0
                nxt = obj.Datasets(di).Sources(si).Key;
                if di ~= obj.DatasetIndex
                    nxt = M('nextOf', nxt, obj.Datasets(di).Base);    % another section: name it
                end
            end
            open = char(strjoin(F.Open, ', '));
            if isempty(open), open = 'nothing'; end
            if F.Audit > 0 && ~F.Complete
                txt = M('ctxFinishAudit', key, CellCurator.auditText(F.Audit));
            elseif F.Complete
                if di > 0
                    txt = M('ctxFinishDone', key, nxt);
                else
                    txt = M('ctxFinishDoneAll', key);
                end
            elseif F.Can && ~obj.Store.ReadOnly
                txt = M('ctxFinishReady', key);
            elseif di > 0
                txt = M('ctxFinishOpen', key, open, nxt);
            else
                txt = M('ctxFinishOpenLast', key, open);
            end
        end

        function finishEnter(obj)
            %FINISHENTER  Enter on the finish checklist: complete the source when it can be, else
            %   open the next source.
            F = obj.finishState();
            if F.Audit > 0
                obj.showQueue("review");             % the audit tiles first: they block completing
            elseif F.Can && ~obj.Store.ReadOnly
                obj.markComplete();
            else
                obj.nextSource();
            end
        end

        function pruneVanished(obj, force)
            %PRUNEVANISHED  An undo removed rows (an added cell): drop them from every page held.
            if nargin < 2, force = false; end
            if ~(obj.VanishCheck || force) || isempty(obj.Store), return; end
            obj.VanishCheck = false;
            have = obj.Store.get('CellID');
            sess = obj.Session;
            if ~isempty(sess) && ~isempty(sess.History)
                H = sess.History;
                keepH = true(numel(H), 1);
                for k = 1:numel(H)
                    m = ismember(H(k).Ids, have);
                    if ~all(m)
                        H(k) = CellCurator.keepTiles(H(k), m);
                        keepH(k) = ~isempty(H(k).Ids);
                    end
                end
                sess.History = H(keepH);
            end
            if ~isempty(obj.LivePage)
                obj.LivePage = CellCurator.keepTiles(obj.LivePage, ismember(obj.LivePage.Ids, have));
            end
            for k = numel(obj.ListPages):-1:1
                m = ismember(obj.ListPages(k).Ids, have);
                if ~all(m)
                    q = obj.ListPages(k);
                    q.Ids = q.Ids(m);
                    q.P = q.P(m);
                    if isfield(q, 'Blind'), q.Blind = q.Blind(m); end
                    obj.ListPages(k) = q;
                end
            end
            obj.NextPage = [];
            P = obj.Page;
            m = ismember(P.Ids, have);
            if ~all(m)
                P = CellCurator.keepTiles(P, m);
                if isempty(P.Ids)
                    obj.showQueue(obj.QueueName);
                else
                    obj.showPageStruct(P);
                end
            end
        end
    end

    %% ======================================================================== the locator
    methods (Access = private)
        function onRightTab(obj)
            %ONRIGHTTAB  The right panel's tab (or the cheat sheet over it) changed: the locator is
            %   updated only while it shows.
            shown = obj.UI.Cheat.Visible == "off" && isequal(obj.UI.Tabs.SelectedTab, obj.UI.TabMap);
            obj.LocatorShown = shown;
            if shown
                obj.refreshLocator();
            end
            if obj.trainingShowing()
                obj.Training.shown();            % its counts at once; a count of the folder in the
            end                                  % background when there is none (or it is old)
        end

        function locatorChanged(obj)
            %LOCATORCHANGED  Something the locator shows changed: refresh it at the next idle moment
            %   when it is showing; otherwise only remember it (no work at all).
            if obj.LocatorShown
                obj.schedule("locator");
            else
                obj.LocatorDirty = true;
            end
        end

        function ensureLocator(obj)
            if (~isempty(obj.Locator) && isvalid(obj.Locator)) || obj.CreatingLocator, return; end
            obj.CreatingLocator = true;
            try
                obj.createLocator();
            catch ME
                obj.CreatingLocator = false;
                rethrow(ME);
            end
            obj.CreatingLocator = false;
        end

        function createLocator(obj)
            C = curation.UiText.colors();
            L = curation.MapView(obj.UI.LocatorHost, 'Background', C.Background / 255, 'MarkerPx', 6, ...
                'MarkerLineWidth', 1, 'SelectionColor', C.Cursor / 255, 'ExcludeColor', C.Exclude / 255, ...
                'ReferenceColor', C.Reference / 255);
            L.setMarkerStyles(curation.MapMarkers.layerStyles(obj.MarkerStyle));
            L.Panel.Layout.Row = 1;
            L.Panel.Layout.Column = 1;
            L.PointClickFcn = @(~, info) obj.uiCall(@() obj.onLocatorClick(info), false);
            L.EmptyClickFcn = @(~, info) obj.uiCall(@() obj.onLocatorClick(info), false);
            obj.Locator = L;
            obj.LocatorLoadedId = "";
            obj.UI.LocatorHint.Text = curation.UiText.label('locatorHint');
            drawnow;
        end

        function refreshLocator(obj)
            %REFRESHLOCATOR  The locator shows the section of the source on screen, the cells of the
            %   page (or the map selection) in color, the others dimmed, the focus cell ringed.
            if ~obj.LocatorShown || isempty(obj.Session) || isempty(obj.Store), return; end
            obj.ensureLocator();
            L = obj.Locator;
            if isempty(L) || ~isvalid(L), return; end     % being created (this call interrupted it)
            sess = obj.Session;
            st = obj.Store;
            if obj.LocatorLoadedId ~= sess.Id
                [small, f] = CellCurator.shrinkPage(sess.PageT, CellCurator.LocatorMaxPx);
                smallC = [];
                if ~isempty(sess.PageC), smallC = CellCurator.shrinkPage(sess.PageC, CellCurator.LocatorMaxPx); end
                if ~isequal(size(smallC), size(small)), smallC = []; end
                L.setImage(small, smallC, sess.Cache.Limits, CellCurator.umOf(st) * f);
                obj.LocatorScale = f;
                obj.LocatorLoadedId = sess.Id;
            end
            obj.applyMapDisplay(L);
            f = obj.LocatorScale;
            ids = st.get('CellID');
            xy = [st.get('X'), st.get('Y')];
            ok = st.get('State') == "active" & all(isfinite(xy), 2);
            [rgb, layer] = obj.cellMarkers();
            ids = ids(ok);
            xy = xy(ok, :);
            rgb = rgb(ok, :);
            layer = layer(ok);
            if obj.CenterView == "map"
                focusSet = obj.MapSelection;
            elseif obj.isTilePage()
                focusSet = obj.Page.Ids;
            else
                focusSet = zeros(0, 1, 'uint32');
            end
            if ~isempty(focusSet)
                C = curation.UiText.colors();
                dim = ~ismember(ids, focusSet);
                rgb(dim, :) = round(C.DimFactor * rgb(dim, :) + (1 - C.DimFactor) * C.Background);
            end
            L.setPoints(ids, (xy + (f - 1) / 2) / f, rgb, layer);
            L.setRegions(obj.regionList(f));
            L.setSelection(obj.locatorFocus());
            obj.LocatorDirty = false;
            obj.Counters.LocatorUpdates = obj.Counters.LocatorUpdates + 1;
        end

        function id = locatorFocus(obj)
            id = zeros(0, 1, 'uint32');
            if obj.CenterView == "map"
                if obj.MapHover > 0
                    id = obj.MapHover;
                elseif ~isempty(obj.MapSelection)
                    id = obj.MapSelection(1);
                end
                return
            end
            K = numel(obj.Page.Ids);
            ks = [obj.HoverTile, obj.Cursor, obj.InspectedTile];
            k = ks(find(ks >= 1 & ks <= K, 1));
            if ~isempty(k) && obj.isTilePage()
                id = obj.Page.Ids(k);
            end
        end

        function onLocatorClick(obj, info)
            f = obj.LocatorScale;
            xy = f * double(info.XY) - (f - 1) / 2;
            obj.showMapAt(xy);
        end
    end

    %% ======================================================================== helpers
    methods (Static, Access = private)
        function d = displayDefaults(cache, st, key)
            %DISPLAYDEFAULTS  The default display of a source (curation.DisplayDefaults): its typical
            %   cell is a middle-band candidate (the cells a reviewer must judge most carefully).
            ids = [];
            try
                T = CellCurator.queueTable(st);
                p = curation.Proposals.current(T, key);
                ids = T.CellID(T.State == "active" & p > 0.15 & p < 0.85);
            catch
            end
            d = curation.DisplayDefaults.fromCache(cache, struct('Ids', ids));
        end

        function s = keptSignature(st)
            %KEPTSIGNATURE  What _final.csv holds: the kept cells and their positions (a hash).
            m = st.keptMask();
            ids = st.get('CellID');
            x = st.get('X');
            y = st.get('Y');
            s = string(curation.Hash.of(double(ids(m)), round(x(m) * 100) / 100, round(y(m) * 100) / 100));
        end

        function q = retireFinal(p)
            %RETIREFINAL  Rename a final list that no longer describes its source:
            %   <stem>_final.csv -> <stem>_final.stale.csv (an older one is replaced). '' on failure.
            q = '';
            p = char(p);
            if ~isfile(p), return; end
            [d, nm, ex] = fileparts(p);
            q = fullfile(d, [nm '.stale' ex]);
            try
                movefile(p, q, 'f');
            catch
                q = '';
            end
        end

        function [small, f] = shrinkPage(page, maxPx)
            %SHRINKPAGE  PAGE shrunk by an integer factor F so its long side is about MAXPX (imresize:
            %   page pixel u maps to (u + (F-1)/2) / F).
            f = max(1, ceil(max(size(page)) / maxPx));
            if f == 1
                small = page;
            else
                small = imresize(page, 1 / f);
            end
        end

        function [R, msg] = loadReference(img)
            %LOADREFERENCE  The reference ROI beside the image (<stem>_roi.roi, an ImageJ ROI such as
            %   a wide line = a strip), drawn on the map only. [] when there is none; MSG says why a
            %   file could not be used.
            R = [];
            msg = strings(0, 1);
            if isempty(img), return; end
            [f, stem] = fileparts(char(img));
            p = fullfile(f, [stem '_roi.roi']);
            if ~isfile(p), return; end
            try
                R = curation.Regions.importImageJRoi(p, struct('kind', "reference"));
            catch ME
                R = [];
                msg = string(curation.UiText.msg('roiFailed', [stem '_roi.roi'], ME.message));
            end
        end

        function [txt, nearKept] = reconcileSummary(rep)
            %RECONCILESUMMARY  What a reconcile at open did, in plain words ("" when none ran), and
            %   its near-kept pairs [new CellID, reviewed CellID].
            txt = "";
            nearKept = zeros(0, 2, 'uint32');
            if ~isstruct(rep) || ~isfield(rep, 'Ran') || ~rep.Ran, return; end
            M = @curation.UiText.msg;
            F = @CellCurator.fmtInt;
            g = @(f) CellCurator.repField(rep, f);
            parts = string(M('reconMatched', F(g('nExact') + g('nNear'))));
            parts(end + 1) = M('reconNew', F(g('nAppended')));
            if g('nVanishedGood') > 0
                parts(end + 1) = M('reconKeptGone', F(g('nVanishedGood')), ...
                    CellCurator.plural(g('nVanishedGood'), 'cell', 'cells'));
            end
            if g('nStale') > 0
                parts(end + 1) = M('reconStale', F(g('nStale')));
            end
            if isfield(rep, 'nearKeptIds') && ~isempty(rep.nearKeptIds)
                nearKept = uint32(reshape(rep.nearKeptIds, [], 2));
                n = size(nearKept, 1);
                parts(end + 1) = M('reconNearKept', F(n), CellCurator.plural(n, 'detection', 'detections'));
            end
            txt = string(M('reconciled', char(strjoin(parts, ", "))));
        end

        function v = repField(rep, f)
            v = 0;
            if isfield(rep, f) && isnumeric(rep.(f)) && ~isempty(rep.(f)), v = double(rep.(f)(1)); end
        end

        function why = readOnlyReason(st)
            %READONLYREASON  Why a store opened read-only: its lock note and the open's warnings.
            parts = strings(0, 1);
            try
                m = string(st.LockInfo.Message);
                if strlength(m) > 0, parts(end + 1, 1) = m; end
            catch
            end
            try
                w = string(st.LastReconcile.warnings(:));
                parts = [parts; w(strlength(w) > 0)];
            catch
            end
            parts = unique(parts, 'stable');
            why = strjoin(parts, " ");
        end

        function tf = hitsView(hit, v)
            %HITSVIEW  A press whose hit object is map view V (its axes or panel), or a test struct.
            tf = false;
            if isempty(v) || ~isvalid(v), return; end
            if isempty(hit), tf = true; return; end
            try
                tf = isequal(hit, v.Axes) || isequal(hit, v.Panel) || isequal(ancestor(hit, 'axes'), v.Axes);
            catch
                tf = false;
            end
        end

        function P = keepTiles(P, m)
            %KEEPTILES  Page P with only the tiles M (logical per tile).
            P.Ids = P.Ids(m);
            if numel(P.P) == numel(m), P.P = P.P(m); end
            if numel(P.Untouched) == numel(m), P.Untouched = P.Untouched(m); end
            if isfield(P, 'Blind') && numel(P.Blind) == numel(m), P.Blind = P.Blind(m); end
        end

        function fillPanel(panel, ax)
            %FILLPANEL  Size an axes (pixel units) to its panel.
            try
                p = getpixelposition(panel);
                pos = [1 1 max(1, p(3)) max(1, p(4))];
                if ~isequal(ax.InnerPosition, pos), ax.InnerPosition = pos; end
            catch
            end
        end

        function p = noPending()
            p = struct('prefetch', false, 'panels', false, 'inspector', false, 'undo', false, 'status', false, ...
                'locator', false, 'assist', false, 'maplayout', false, 'final', false, 'rescore', false);
        end

        function s = shortPath(p, n)
            %SHORTPATH  The last two folder names of a path ("…\Animal1\sec3"), at most N characters.
            p = char(p);
            [up, name] = fileparts(p);
            [~, parent] = fileparts(up);
            s = name;
            if ~isempty(parent), s = [char(8230) filesep parent filesep name]; end
            if numel(s) > n
                s = [char(8230) s(end - n + 2:end)];
            end
            if numel(p) <= numel(s), s = p; end
        end

        function T = queueTable(st)
            %QUEUETABLE  The columns curation.Queues and curation.Proposals read, from the store.
            T = table(st.get('CellID'), st.get('State'), st.get('Reviewed'), st.get('Excluded'), ...
                st.get('Label'), st.get('Flag'), st.get('LabelSource'), st.get('InLocs'), ...
                st.get('Origin'), st.get('score'), st.get('rescore'), st.get('ModelP'), st.get('AuditRole'), ...
                'VariableNames', {'CellID', 'State', 'Reviewed', 'Excluded', 'Label', 'Flag', ...
                'LabelSource', 'InLocs', 'Origin', 'score', 'rescore', 'ModelP', 'AuditRole'});
        end

        function [ids, xy] = cacheCells(st)
            ids = st.get('CellID');
            xy = [st.get('X'), st.get('Y')];
            ok = all(isfinite(xy), 2);
            ids = ids(ok);
            xy = xy(ok, :);
        end

        function syncCache(cache, st)
            %SYNCCACHE  Make a cache prepared from a read-only view match the opened store.
            [ids, xy] = CellCurator.cacheCells(st);
            rows = cache.rowsOf(ids);
            miss = rows == 0;
            if any(miss)
                cache.add(ids(miss), xy(miss, :));
            end
            have = find(~miss);
            if ~isempty(have)
                moved = any(abs(cache.XY(rows(have), :) - xy(have, :)) > 1e-6, 2);
                if any(moved)
                    cache.update(ids(have(moved)), xy(have(moved), :));
                end
            end
        end

        function um = umOf(st)
            um = double(st.Meta.UmPerPixel);
            if ~(isscalar(um) && isfinite(um) && um > 0)
                um = curation.Store.DEFAULT_UM_PER_PIXEL;
            end
        end

        function p = blankPage(kind)
            p = struct('Kind', string(kind), 'Ids', zeros(0, 1, 'uint32'), 'P', zeros(0, 1), ...
                'Default', "", 'Band', "", 'Blind', false(0, 1), 'Title', "", 'Queue', "", 'PageId', "", ...
                'Number', 0, 'Total', 0, 'Untouched', false(0, 1), 'ShownTic', tic, 'Origin', "");
        end

        function p = fromQueuePage(q, kind)
            p = CellCurator.blankPage(kind);
            p.Ids = uint32(q.Ids(:));
            p.P = double(q.P(:));
            p.Blind = false(numel(p.Ids), 1);
            if isfield(q, 'Blind') && numel(q.Blind) == numel(p.Ids), p.Blind = logical(q.Blind(:)); end
            p.Default = string(q.Default);
            p.Band = string(q.Band);
            p.Title = string(q.Title);
            p.Queue = string(q.Queue);
            p.PageId = string(q.PageId);
            p.Untouched = false(numel(p.Ids), 1);
        end

        function P = cutPage(P, cap)
            P.Ids = P.Ids(1:cap);
            P.P = P.P(1:cap);
            if numel(P.Blind) >= cap, P.Blind = P.Blind(1:cap); end
            P.Untouched = P.Untouched(1:min(cap, numel(P.Untouched)));
            P.PageId = P.PageId + "-" + cap;
        end

        function D = emptyDatasets()
            D = struct('Base', {}, 'Folder', {}, 'DatasetID', {}, 'Mf', {}, 'PageCount', {}, 'Sources', {}, 'Short', {});
        end

        function S = defaultSettings()
            S = struct('LastFolder', '', 'WindowPosition', [80 60 1500 900], 'DisplayMode', 'target', ...
                'GainRel', 1, 'GammaRel', 1, 'EvenTiles', false, 'Zoom', 1, 'LastDataset', '', 'LastSource', '', ...
                'SweepFieldUm', 600, 'LastStage2Export', '', 'LastStage1Export', '', ...
                'MarkerStyles', curation.MapMarkers.defaults());
        end

        function id = sessionId(folder, base, key)
            id = lower(string(folder) + "|" + string(base) + "|" + string(key));
        end

        function items = queueItems(n, sweepText)
            %QUEUEITEMS  Queue list texts with the remaining counts N (NaN: not known yet); the
            %   Sweep entry shows SWEEPTEXT ("optional", "done", "at field 7") when given.
            if nargin < 2, sweepText = ''; end
            F = @CellCurator.fmtInt;
            items = cell(1, numel(CellCurator.QUEUES));
            for k = 1:numel(CellCurator.QUEUES)
                name = CellCurator.QUEUES(k);
                if name == "sweep"
                    if isempty(sweepText)
                        items{k} = curation.UiText.queueLabel(name);
                    else
                        items{k} = curation.UiText.msg('sweepItem', sweepText);
                    end
                elseif isnan(n(k))
                    items{k} = curation.UiText.queueLabel(name);
                elseif name == "review"
                    items{k} = curation.UiText.msg('reviewItem', F(n(k)));
                else
                    items{k} = curation.UiText.msg('queueItem', curation.UiText.queueLabel(name), F(n(k)));
                end
            end
        end

        function k = eventKey(e)
            %EVENTKEY  The key of a key event; the typed character for punctuation keys, so that
            %   layouts that put [ ] ; ' + - ? elsewhere still work.
            k = string(e.Key);
            ch = "";
            try ch = string(e.Character); catch, end
            if strlength(ch) == 1 && any(ch == ["[" "]" ";" "'" "+" "-" "?" "=" "/" "."])
                k = ch;
            end
        end

        function tf = isTextEntry(h)
            tf = false;
            try
                c = string(class(h));
                tf = contains(c, "EditField") || contains(c, "TextArea") || contains(c, "Spinner");
            catch
            end
        end

        function f = absFolder(p)
            f = char(p);
            try
                d = dir(f);
                if ~isempty(d), f = d(1).folder; end
            catch
            end
        end

        function f = absFile(p)
            f = char(p);
            try
                d = dir(f);
                if ~isempty(d), f = fullfile(d(1).folder, d(1).name); end
            catch
            end
        end

        function tf = isBelow(folder, parent)
            tf = ~isempty(parent) && strncmpi([char(folder) filesep], [char(parent) filesep], numel(parent) + 1);
        end
    end

    methods (Static)
        function k = normalizeKey(key)
            %NORMALIZEKEY  Canonical key name: MATLAB key names and characters both map to the names
            %   of curation.UiText.keymap ("return", "leftarrow", "[", "+", "?", ...).
            k = string(key);
            if strlength(k) == 1
                if any(k == ["=" "+"]), k = "+"; return; end
                if k == "/", k = "?"; return; end
                if any(k == ["[" "]" ";" "'" "-" "?"]), return; end
                k = lower(k);
                return
            end
            k = lower(k);
            switch k
                case "enter",                         k = "return";
                case "leftbracket",                   k = "[";
                case "rightbracket",                  k = "]";
                case "semicolon",                     k = ";";
                case {"quote", "apostrophe"},         k = "'";
                case {"equal", "add", "plus"},        k = "+";
                case {"hyphen", "subtract", "minus"}, k = "-";
                case {"slash", "questionmark"},       k = "?";
                case "esc",                           k = "escape";
                case "left",                          k = "leftarrow";
                case "right",                         k = "rightarrow";
                case "up",                            k = "uparrow";
                case "down",                          k = "downarrow";
                case "pgup",                          k = "pageup";
                case "pgdn",                          k = "pagedown";
                case {"period", "decimal", "fullstop"}, k = ".";
                case "del",                           k = "delete";
                case {"numpad0", "zero"},             k = "0";
            end
        end

        function s = fmtInt(n)
            %FMTINT  Integer with thousands separators: 1234 -> "1,234".
            s = regexprep(sprintf('%d', round(double(n))), '(\d)(?=(\d{3})+$)', '$1,');
        end
    end

    methods (Static, Access = private)
        function s = plural(n, one, many)
            if n == 1, s = one; else, s = many; end
        end

        function s = auditText(n)
            %AUDITTEXT  "3 audit tiles (gray border)".
            s = curation.UiText.msg('auditTiles', CellCurator.fmtInt(n), CellCurator.plural(n, 'tile', 'tiles'));
        end

        function s = needText(n)
            %NEEDTEXT  "1 audit tile (gray border) needs" / "3 audit tiles (gray border) need".
            s = [CellCurator.auditText(n) ' ' CellCurator.plural(n, 'needs', 'need')];
        end

        function tf = hasCelldb()
            %HASCELLDB  The lab database gateway (customizations\+celldb) is on the path.
            persistent have
            if isempty(have), have = ~isempty(which('celldb.addLamp')) && ~isempty(which('celldb.recordCuration')); end
            tf = have;
        end

        function out = displayNames(bases, n)
            %DISPLAYNAMES  Names that tell the sections apart in a narrow list: "_proj" dropped, and
            %   when the names have the same "_"-separated tokens, the tokens every name shares are left
            %   out ("SUBJ-ID-1127IHC_1A_L_260511" for "SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_
            %   260511_1"); the first token (the animal) is always kept. What is still longer than N
            %   characters is elided in the middle (shortName).
            names = regexprep(cellstr(bases), '_proj$', '');
            out = names;
            if numel(names) >= 2
                toks = cellfun(@(s) strsplit(s, '_'), names, 'UniformOutput', false);
                m = cellfun(@numel, toks);
                for c = unique(m)
                    g = find(m == c);
                    if numel(g) < 2, continue; end
                    T = vertcat(toks{g});
                    same = all(strcmp(T, repmat(T(1, :), size(T, 1), 1)), 1);
                    same(1) = false;
                    for i = 1:numel(g)
                        out{g(i)} = strjoin(T(i, ~same), '_');
                    end
                end
            end
            for i = 1:numel(out)
                out{i} = CellCurator.shortName(out{i}, n);
            end
        end

        function s = shortName(base, n)
            %SHORTNAME  A section name that fits a list of about N characters: "_proj" dropped; a longer
            %   one keeps its animal (SUBJ-ID-<n>) and its end (slide, side, stain, date), the common
            %   middle elided ("SUBJ-ID-1127…1A_L_WFA-PV_Z3_260511_1"). Tooltips carry the full name.
            s = regexprep(char(base), '_proj$', '');
            if numel(s) <= n, return; end
            head = regexp(s, '^SUBJ-ID-\d+', 'match', 'once');
            if isempty(head), head = s(1:min(8, numel(s))); end
            keep = max(4, n - numel(head) - 1);
            s = [head char(8230) s(end - keep + 1:end)];
        end

        function [cpm, txt] = paceOf(L)
            %PACEOF  Cells per minute of the pages in L ([tiles seconds] per page). A page confirmed
            %   faster than PaceMinPageSec counts as that long (nobody reviews 126 tiles in a blink,
            %   so a burst of quick Enters must not promise an absurd pace); above PaceMaxCpm the text
            %   says "1,000+" and the time left is estimated at PaceMaxCpm.
            secs = max(L(:, 2), CellCurator.PaceMinPageSec);
            cpm = sum(L(:, 1)) / max(sum(secs), eps) * 60;
            if cpm >= CellCurator.PaceMaxCpm
                cpm = CellCurator.PaceMaxCpm;
                txt = curation.UiText.msg('paceCapped');
            else
                txt = CellCurator.fmtInt(cpm);
            end
        end

        function preloadClasses()
            %PRELOADCLASSES  Load the classes the idle and map timers use before any timer runs:
            %   MATLAB processes timer callbacks while it loads a class, and a class used by a callback
            %   while it is still being loaded fails ("... used in its own class definition").
            persistent done
            if ~isempty(done), return; end
            curation.MapView.preload();
            for c = ["curation.Store" "curation.GalleryView" "curation.CropCache" "curation.Queues" ...
                    "curation.Proposals" "curation.Pairs" "curation.Regions" "curation.UiText" ...
                    "curation.BlindTiles" "curation.AssistRunner" "curation.CuratorSession" "curation.Audit" ...
                    "curation.ChangeEventData" "curation.ChangeSet" "curation.DisplayDefaults" ...
                    "curation.RescoreRunner" "curation.TrainingPanel" "curation.MapMarkers"]
                try meta.class.fromName(char(c)); catch, end
            end
            done = true;
        end

        function s = tilesText(n)
            s = sprintf('%s %s', CellCurator.fmtInt(n), CellCurator.plural(n, 'tile', 'tiles'));
        end

        function s = cellsText(n)
            s = sprintf('%s %s', CellCurator.fmtInt(n), CellCurator.plural(n, 'cell', 'cells'));
        end

        function s = opposite(label)
            if string(label) == "Good", s = "Bad"; else, s = "Good"; end
        end

        function v = clamp(v, lim, fallback)
            if ~(isscalar(v) && isfinite(v)), v = fallback; end
            v = min(max(v, lim(1)), lim(2));
        end

        function s = durationText(minutes)
            if ~isfinite(minutes), s = '?'; return; end
            m = round(minutes);
            if m < 1
                s = 'under a minute';
            elseif m < 60
                s = sprintf('about %d min', m);
            else
                s = sprintf('about %d h %02d min', floor(m / 60), mod(m, 60));
            end
        end
    end
end
