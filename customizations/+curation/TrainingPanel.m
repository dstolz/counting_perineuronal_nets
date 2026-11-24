classdef TrainingPanel < handle
%TRAININGPANEL  The Training tab of CellCurator: what the curated labels can train now, the three
%   exports (curation.Export), the Stage-2 fine-tune (curation.Trainer) and the Stage-1 command.
%   No review-flow code: the window gives it a tab and a few functions, and every action here runs
%   on an explicit button, never on the review keys. A fine-tune runs in its own process (Python);
%   review goes on meanwhile.
%
%   p = curation.TrainingPanel(tab, opts)      builds the controls inside uitab TAB
%   p.shown()                                  the tab came to the front: the counts of the kind on
%                                              screen at once ("Counting what can be exported..."
%                                              before the folder's first count, which it asks for;
%                                              again when the last one is MaxAgeSec old)
%   p.refresh(force)                           the counts shown brought up to date from the open
%                                              sources (cheap; the window's idle step); FORCE
%                                              (default true) also asks for a full recount
%   p.invalidate()                             an open source changed what it gives (a confirmed
%                                              page, a completion, a sweep): only a flag, for the
%                                              next refresh
%   tf = p.isCounting(), ok = p.waitForCounts(timeoutSec)   (tests) a full count runs or is wanted
%   r = p.exportStage2(folder)                 Export scorer training set (FOLDER: '' asks with
%   r = p.exportStage1(folder)                 uigetdir, through opts.ChooseFolderFcn)
%   r = p.exportObservations(file)             '' asks with uiputfile (opts.ChooseFileFcn)
%   ok = p.fineTune()                          curation.Trainer.start on the last Stage-2 export
%   cmd = p.copyStage1Command()                the train.py command of the last Stage-1 export, on
%                                              the clipboard and in the tab
%   ok = p.waitForTraining(timeoutSec)         (tests) until the fine-tune has ended
%   p.LastStage2, p.LastStage1, p.LastObservations   folders/file of the last exports (the window
%                                              persists the folders)
%   p.Trainer                                  the curation.Trainer of the last fine-tune
%   p.Summary                                  what refresh counted (struct; see below)
%
%   COUNTING. A full count reads the folder's saved curation files (a rows-only
%   curation.ProjectIndex: no image, no feature) and gives one row per source and both channel
%   kinds (p.Partials: what each source gives to the exports). It runs as TrainingPanel.countJob
%   on the background pool (thread workers), started by the panel's own timer, never inside a click
%   or a key: the tab shows at once. It runs once per folder (at the tab's first showing; again on
%   a showing when MaxAgeSec old, or refresh(true)); one at a time, a request meanwhile coalesced.
%   A full count on a thread worker slows MATLAB's own thread while it runs (keys measured 2-4x
%   slower), so it never follows the review: after a confirmed page or a completion only the
%   rows of the open sources are recounted, from their stores in memory (LiveFcn), at the next
%   refresh (milliseconds; no file, no worker). Without a background pool (Background false, or
%   none available) the full count runs in the timer's callback instead, between key presses.
%
%   OPTIONS (struct, every field optional)
%     ParentDir        the folder of sections
%     KindFcn          fn() -> "pnn" | "pv": the channel kind on screen (default "pnn")
%     LiveFcn          fn() -> struct array SourceId, Cols (struct of the store's columns State,
%                      Reviewed, LabelSource, Label, Excluded, Flag, AuditRole), Complete,
%                      SweepDone: the open sources (CellCurator: its sessions)
%     Background       true: count on backgroundPool (see COUNTING); false: in the timer callback
%     MaxAgeSec        300: a showing of the tab recounts the folder when the last count is older
%     StatusFcn        fn(text): the window's status bar
%     ChooseFolderFcn  fn(start, title) -> folder or 0 (default uigetdir)
%     ChooseFileFcn    fn(filter, title, default) -> [file, path] (default uiputfile)
%     TrainerOptions   struct for curation.Trainer.start (Device, Epochs, RepoRoot, DeployRoot,
%                      Python, ...); OnLine/OnDone are the panel's
%     ExportOptions    struct merged into every curation.Export call (e.g. MinPerClass, Assume)
%     CacheDir         feature cache folder for the index read here
%     RepoRoot         CellToolkit.detectRepoRoot()
%     PythonOk         [] (look: curation.RescoreRunner.pythonStatus) | true | false
%
%   SUMMARY (p.Summary, per channel kind on screen): Kind, Good, Uncertain, Bad (labels a person
%   decided that the scorer export takes: active, reviewed, a person's label source, not
%   excluded, not audit evidence, not flagged), Sections, Animals (with such labels), Sources,
%   Complete (sources marked complete), Swept (complete AND swept: what the detector export
%   takes), Stage2Ok / Stage2Why, Stage1Ok / Stage1Why; HasCounts (false until the folder's first
%   count), Counting (a full count is running or wanted), CountSec (the last full count's own
%   time), SourcesRead. A preview: the export applies its own rules (e.g. the exclusion regions,
%   the model image's border) and reports what it left out.
%   p.LastRefreshMs (shown/refresh: the caller's cost), p.LastCountWallMs (request -> counts shown),
%   p.LastLiveMs (the open sources recounted), p.CountsStarted (full counts started).
%
%   See also curation.Export, curation.Trainer, curation.RescoreRunner, CellCurator.

    properties (SetAccess = private)
        Tab = []
        Grid = []
        UI struct = struct()
        Options struct = struct()
        Summary struct = struct()
        LastStage2 char = ''
        LastStage1 char = ''
        LastObservations char = ''
        LastReport = []
        Trainer = []
        TrainingNote string = ""
        LastCommand string = ""         % the detector command last built (also on the clipboard)
        LastRefreshMs double = NaN
        LastCountWallMs double = NaN    % a full count: requested -> its counts shown
        LastLiveMs double = NaN         % the open sources recounted from memory
        CountsStarted double = 0        % full counts started (tests: never on the caller's path)
        Partials = []                   % table: one row per source of the folder (COUNTING)
    end

    properties (Access = private)
        Timer = []
        CountTimer = []                 % starts and collects the full counts (COUNTING)
        Job = []                        % the running count: struct Future/Tic0/Result
        Wanted logical = false          % a full count is wanted
        WantedTic = []
        CountedTic = []                 % when the last full count was started
        CountSec double = NaN
        Gen double = 0                  % invalidate() count
        LiveGen double = -1             % Gen of the last recount of the open sources
        Pool = []
        LogShown double = -1
        PyOk = []
        PyWhy string = ""
    end

    properties (Constant)
        MinAnimals = 2
    end

    methods
        function p = TrainingPanel(tab, opts)
            if nargin < 2 || isempty(opts), opts = struct(); end
            o = struct('ParentDir', '', 'KindFcn', @() "pnn", 'LiveFcn', @() [], 'Background', true, ...
                'MaxAgeSec', 300, 'StatusFcn', @(t) [], ...
                'ChooseFolderFcn', @(s, t) uigetdir(s, t), 'ChooseFileFcn', @(f, t, d) uiputfile(f, t, d), ...
                'TrainerOptions', struct(), 'ExportOptions', struct(), 'CacheDir', '', 'RepoRoot', '', ...
                'PythonOk', []);
            f = fieldnames(opts);
            for i = 1:numel(f)
                if ~isfield(o, f{i})
                    error('curation:TrainingPanel:badArgument', 'Unknown option "%s".', f{i});
                end
                o.(f{i}) = opts.(f{i});
            end
            if isempty(o.RepoRoot), o.RepoRoot = CellToolkit.detectRepoRoot(); end
            p.Options = o;
            p.Tab = tab;
            p.build();
            p.Summary = p.emptySummary("pnn");
            p.show();                                    % (the first showing only changes texts)
            p.countTimer();
        end

        function delete(p)
            p.stopTimer();
            p.stopCounting(true);
        end

        function setParentDir(p, d)
            %SETPARENTDIR  Another folder: the counts of the last one are dropped (a count of it that
            %   is still running is cancelled).
            p.stopCounting();
            p.Options.ParentDir = char(d);
            p.Partials = [];
            p.CountedTic = [];
            p.Gen = p.Gen + 1;
        end

        function invalidate(p)
            %INVALIDATE  An open source changed what it gives: its rows are recounted from memory at
            %   the next refresh. Nothing else: this runs on the review path.
            p.Gen = p.Gen + 1;
        end

        function shown(p)
            %SHOWN  The tab came to the front: its counts at once; a full count asked for when there
            %   is none of this folder yet or the last one is older than MaxAgeSec.
            p.refresh(false);
            old = ~isempty(p.CountedTic) && toc(p.CountedTic) > p.Options.MaxAgeSec;
            if ~isempty(p.Options.ParentDir) && old && ~p.counting()
                p.requestCount();
                p.Summary.Counting = true;
                p.show();
            end
        end

        function tf = isCounting(p)
            %ISCOUNTING  A count is running or wanted.
            tf = p.counting();
        end

        function ok = waitForCounts(p, timeoutSec)
            %WAITFORCOUNTS  (tests) Wait until no count is running or wanted; false on timeout.
            if nargin < 2, timeoutSec = 60; end
            t0 = tic;
            ok = false;
            while toc(t0) < timeoutSec
                drawnow;
                if ~p.counting(), ok = true; return; end
                pause(0.05);
            end
        end

        function setLast(p, stage2, stage1)
            %SETLAST  The export folders remembered from an earlier session (when they still exist).
            if nargin >= 2 && ~isempty(stage2) && isfile(fullfile(char(stage2), curation.Export.REPORT))
                p.LastStage2 = char(stage2);
            end
            if nargin >= 3 && ~isempty(stage1) && isfile(fullfile(char(stage1), curation.Export.REPORT))
                p.LastStage1 = char(stage1);
            end
            p.updateEnable();
        end

        function refresh(p, force)
            %REFRESH  The counts of the kind on screen brought up to date: the open sources' rows
            %   recounted from memory after an invalidate(), the folder's first full count asked
            %   for (never run here: COUNTING); FORCE (default true) asks for a full recount.
            if nargin < 2, force = true; end
            t0 = tic;
            kind = p.kindNow();
            if isempty(p.Options.ParentDir)
                S = p.emptySummary(kind);
                S.Note = "No folder is open.";
                p.Summary = S;
                p.show();
                p.LastRefreshMs = 1000 * toc(t0);
                return
            end
            if force || (isempty(p.Partials) && ~p.counting())
                p.requestCount();
            end
            if ~isempty(p.Partials) && p.LiveGen ~= p.Gen
                p.applyLive();
            end
            p.Summary = p.summaryOf(kind);
            p.show();
            p.LastRefreshMs = 1000 * toc(t0);
        end

        function r = exportStage2(p, folder)
            %EXPORTSTAGE2  The scorer training set of the kind on screen (curation.Export.stage2).
            if nargin < 2, folder = ''; end
            r = p.runExport("stage2", folder);
        end

        function r = exportStage1(p, folder)
            %EXPORTSTAGE1  The detector training set (complete, swept sections only).
            if nargin < 2, folder = ''; end
            r = p.runExport("stage1", folder);
        end

        function r = exportObservations(p, file)
            %EXPORTOBSERVATIONS  Every reviewed cell of the kind, in the legacy QC observation schema.
            if nargin < 2, file = ''; end
            r = [];
            kind = p.Summary.Kind;
            if isempty(file)
                start = fullfile(p.startFolder(), sprintf('observations_%s_%s.csv', kind, ...
                    char(datetime('now', 'Format', 'yyyyMMdd'))));
                [fn, fp] = p.Options.ChooseFileFcn('*.csv', 'Save the observation table', start);
                if isequal(fn, 0), p.status("No observation table written (no file chosen)."); return; end
                file = fullfile(fp, fn);
            end
            file = char(file);
            p.status(sprintf('Writing the observation table %s%s', file, char(8230)));
            drawnow limitrate;
            try
                idx = p.freshIndex();
                o = p.Options.ExportOptions;
                o.Kind = kind;
                o.Overwrite = true;
                o = p.only(o, ["Kind" "Sections" "CropSize" "Overwrite"]);
                r = curation.Export.observations(idx, file, o);
                p.LastObservations = file;
                [folder, name] = fileparts(file);
                p.showSummaryFile(fullfile(folder, [name '_export_summary.txt']), r);
                p.status(sprintf('Wrote the observation table %s.', file));
            catch err
                p.showError("The observation table could not be written", err, '');
            end
        end

        function ok = fineTune(p)
            %FINETUNE  curation.Trainer.start on the last Stage-2 export (returns at once).
            ok = false;
            if isempty(p.LastStage2)
                p.status("Fine-tune needs a scorer training set: export one first (Export scorer training set...).");
                return
            end
            if ~isempty(p.Trainer) && isvalid(p.Trainer) && p.Trainer.State == "running"
                p.status("A fine-tune is running already.");
                return
            end
            if ~p.pythonOk()
                p.status(p.PyWhy);
                return
            end
            o = p.Options.TrainerOptions;
            o.OnDone = @(t) p.onTrainerDone(t);
            p.TrainingNote = "";
            try
                t = curation.Trainer.start(p.LastStage2, o);
            catch err
                p.showError("The fine-tune could not start", err, '');
                return
            end
            p.Trainer = t;
            p.LogShown = -1;
            if t.State == "failed"
                p.TrainingNote = "Could not start: " + t.Error;
                p.status("The fine-tune could not start: " + t.Error);
            else
                ok = true;
                p.status(sprintf(['Fine-tuning the %s scorer on %s in the background (log: %s). Review ' ...
                    'can go on.'], upper(t.Command.Kind), p.LastStage2, t.LogFile));
                p.startTimer();
            end
            p.showTrainer();
            p.updateEnable();
        end

        function cmd = copyStage1Command(p)
            %COPYSTAGE1COMMAND  The detector fine-tune command (curation.Trainer.stage1Command) of the
            %   last Stage-1 export: on the clipboard and in the tab. Stage 1 runs for hours to days,
            %   so a person starts it in a terminal.
            cmd = [];
            if isempty(p.LastStage1)
                p.status("Export a detector training set first: the command trains on it.");
                return
            end
            o = p.only(p.Options.TrainerOptions, ["Kind" "Pretrained" "Epochs" "Device" "RunDir" "Python" "RepoRoot" "Extra"]);
            try
                cmd = curation.Trainer.stage1Command(p.LastStage1, o);
            catch err
                p.showError("The detector command could not be built", err, '');
                return
            end
            txt = string(cmd.Line);
            copied = false;
            try
                clipboard('copy', char(txt));
                copied = strcmp(clipboard('paste'), char(txt));    % (not on every desktop)
            catch
            end
            p.LastCommand = txt;
            p.UI.Command.Value = cellstr(["cd /d """ + string(cmd.WorkingDir) + """"; txt]);
            if copied
                p.status(sprintf('Copied the detector training command; paste it into a terminal opened at %s.', cmd.WorkingDir));
            else
                p.status('The clipboard is not available here: copy the command from the Training tab.');
            end
        end

        function ok = waitForTraining(p, timeoutSec)
            if nargin < 2, timeoutSec = 600; end
            ok = true;
            t = p.Trainer;
            if isempty(t) || ~isvalid(t), return; end
            ok = t.wait(timeoutSec);
            p.pollTrainer();
        end

        function pollTrainer(p)
            %POLLTRAINER  The log tail and the state, while the tab shows (the timer calls it).
            t = p.Trainer;
            if isempty(t) || ~isvalid(t), p.stopTimer(); return; end
            if t.State ~= "running", p.stopTimer(); end
            if ~p.showing() && t.State == "running", return; end
            p.showTrainer();
        end
    end

    %% ---------------------------------------------------------------------------------- building
    methods (Access = private)
        function build(p)
            U = @curation.UiText.label;
            T = @curation.UiText.tip;
            g = uigridlayout(p.Tab, [14 1], 'Padding', [6 6 6 6], 'RowSpacing', 5, 'ColumnWidth', {'1x'}, ...
                'Scrollable', 'on', 'Tag', 'gl:training');
            g.RowHeight = {20, 'fit', 28, 28, 28, 18, 150, 20, 'fit', 28, 'fit', 120, 28, 52};
            p.Grid = g;
            h = uilabel(g, 'Text', U('trainHead'), 'FontWeight', 'bold', 'Tag', 'lbl:trainHead');
            h.Layout.Row = 1;
            p.UI.Head = h;
            s = uilabel(g, 'Text', '', 'WordWrap', 'on', 'FontSize', 11, 'VerticalAlignment', 'top', ...
                'Tag', 'lbl:trainCounts');
            s.Layout.Row = 2;
            CellToolkit.setTooltip(s, T('trainCounts'));
            p.UI.Counts = s;
            spec = {'Export2', 'trainExport2', @() p.exportStage2(''), 3
                'Export1', 'trainExport1', @() p.exportStage1(''), 4
                'ExportObs', 'trainExportObs', @() p.exportObservations(''), 5};
            for i = 1:size(spec, 1)
                fn = spec{i, 3};
                b = uibutton(g, 'Text', U(spec{i, 2}), 'Tag', ['btn:' spec{i, 2}], ...
                    'ButtonPushedFcn', @(~, ~) p.guard(fn));
                b.Layout.Row = spec{i, 4};
                CellToolkit.setTooltip(b, T(spec{i, 2}));
                p.UI.(spec{i, 1}) = b;
            end
            l = uilabel(g, 'Text', U('trainLastExport'), 'FontSize', 11, 'FontWeight', 'bold');
            l.Layout.Row = 6;
            a = uitextarea(g, 'Value', {U('trainNoExport')}, 'Editable', 'off', 'WordWrap', 'off', ...
                'FontName', 'Consolas', 'FontSize', 10, 'Tag', 'ta:trainSummary');
            a.Layout.Row = 7;
            CellToolkit.setTooltip(a, T('trainSummary'));
            p.UI.SummaryText = a;
            h = uilabel(g, 'Text', U('trainFineHead'), 'FontWeight', 'bold');
            h.Layout.Row = 8;
            n = uilabel(g, 'Text', curation.UiText.msg('trainMeaning'), 'WordWrap', 'on', 'FontSize', 11, ...
                'FontColor', [0.45 0.18 0.0], 'VerticalAlignment', 'top', 'Tag', 'lbl:trainMeaning');
            n.Layout.Row = 9;
            p.UI.Meaning = n;
            b = uibutton(g, 'Text', U('trainFineTune'), 'Tag', 'btn:trainFineTune', 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~, ~) p.guard(@() p.fineTune()));
            b.Layout.Row = 10;
            CellToolkit.setTooltip(b, T('trainFineTune'));
            p.UI.FineTune = b;
            st = uilabel(g, 'Text', curation.UiText.msg('trainIdle'), 'WordWrap', 'on', 'FontSize', 11, ...
                'VerticalAlignment', 'top', 'Tag', 'lbl:trainState');
            st.Layout.Row = 11;
            CellToolkit.setTooltip(st, T('trainState'));
            p.UI.State = st;
            lg = uitextarea(g, 'Value', {''}, 'Editable', 'off', 'WordWrap', 'off', 'FontName', 'Consolas', ...
                'FontSize', 9, 'Tag', 'ta:trainLog');
            lg.Layout.Row = 12;
            CellToolkit.setTooltip(lg, T('trainLog'));
            p.UI.Log = lg;
            b = uibutton(g, 'Text', U('trainCopyCmd'), 'Tag', 'btn:trainCopyCmd', ...
                'ButtonPushedFcn', @(~, ~) p.guard(@() p.copyStage1Command()));
            b.Layout.Row = 13;
            CellToolkit.setTooltip(b, T('trainCopyCmd'));
            p.UI.CopyCmd = b;
            c = uitextarea(g, 'Value', {''}, 'Editable', 'off', 'WordWrap', 'on', 'FontName', 'Consolas', ...
                'FontSize', 9, 'Tag', 'ta:trainCommand');
            c.Layout.Row = 14;
            CellToolkit.setTooltip(c, T('trainCommand'));
            p.UI.Command = c;
        end

        function guard(p, fn)
            %GUARD  A button callback: a failure goes to the status bar, never to a dialog.
            try
                fn();
            catch err
                p.showError("Problem", err, '');
            end
            p.updateEnable();
        end
    end

    %% ---------------------------------------------------------------------------------- counting
    methods (Access = private)
        function S = emptySummary(~, kind)
            S = curation.TrainingPanel.blankSummary(kind);
        end

        function k = kindNow(p)
            k = "pnn";
            try k = string(p.Options.KindFcn()); catch, end
            if ~isscalar(k) || ~ismember(k, ["pnn" "pv"]), k = "pnn"; end
        end

        function S = summaryOf(p, kind)
            %SUMMARYOF  The counts of KIND from the per-source rows (placeholder before the first).
            if isempty(p.Partials)
                S = p.emptySummary(kind);
            else
                S = curation.TrainingPanel.aggregate(p.Partials, kind);
                S.CountSec = p.CountSec;
                S.SourcesRead = height(p.Partials);
            end
            S.Counting = p.counting();
        end

        function applyLive(p)
            %APPLYLIVE  The open sources' rows recounted from their stores in memory.
            t0 = tic;
            p.LiveGen = p.Gen;
            L = [];
            try L = p.Options.LiveFcn(); catch, end
            P = p.Partials;
            sid = lower(P.SourceId);
            for i = 1:numel(L)
                j = find(sid == lower(string(L(i).SourceId)), 1);
                if isempty(j), continue; end
                q = curation.TrainingPanel.partialOf(L(i).Cols);
                P.Good(j) = q.Good;
                P.Uncertain(j) = q.Uncertain;
                P.Bad(j) = q.Bad;
                P.AnyM(j) = q.AnyM;
                P.AnyGB(j) = q.AnyGB;
                P.Complete(j) = logical(L(i).Complete);
                P.Swept(j) = logical(L(i).Complete) && logical(L(i).SweepDone);
            end
            p.Partials = P;
            p.LastLiveMs = 1000 * toc(t0);
        end

        function tf = counting(p)
            tf = ~isempty(p.Job) || p.Wanted;
        end

        function requestCount(p)
            %REQUESTCOUNT  Ask for a full count: the count timer starts it (one at a time; a
            %   request while one runs is kept as the next).
            if ~p.Wanted, p.WantedTic = tic; end
            p.Wanted = true;
            t = p.countTimer();
            if ~strcmp(t.Running, 'on'), start(t); end
        end

        function t = countTimer(p)
            %COUNTTIMER  The timer that starts and collects the full counts (made with the panel, so
            %   a click only starts it). Its first step comes 0.25 s after the request: the click's
            %   own redraw is done by then (the first count may start the background pool, ~1 s).
            t = p.CountTimer;
            if isempty(t) || ~isvalid(t)
                t = timer('Name', 'TrainingPanel count', 'ExecutionMode', 'fixedSpacing', 'Period', 0.15, ...
                    'StartDelay', 0.25, 'BusyMode', 'drop', 'ObjectVisibility', 'off', ...
                    'TimerFcn', @(~, ~) p.safeCountStep());
                p.CountTimer = t;
            end
        end

        function safeCountStep(p)
            try
                if isvalid(p), p.countStep(); end
            catch err
                try
                    p.Job = [];
                    p.Wanted = false;
                    p.stopCountTimer();
                    S = p.Summary;
                    S.Counting = false;
                    S.Note = "The counts could not be read (" + string(err.message) + ").";
                    p.Summary = S;
                    p.show();
                catch
                end
            end
        end

        function countStep(p)
            %COUNTSTEP  (the count timer) Collect a finished count and show it; start a wanted one.
            J = p.Job;
            if ~isempty(J)
                if ~isempty(J.Future)
                    if ~any(strcmp(J.Future.State, {'finished', 'failed', 'unavailable'})), return; end
                    p.Job = [];
                    if ~isempty(J.Future.Error), rethrow(J.Future.Error); end
                    R = fetchOutputs(J.Future);
                else
                    p.Job = [];
                    R = J.Result;
                end
                p.Partials = R.Partials;
                p.CountSec = R.CountSec;
                p.applyLive();                       % the open sources: from memory (newer than files)
                p.Summary = p.summaryOf(p.kindNow());
                p.show();
                p.LastCountWallMs = 1000 * toc(J.Tic0);
            end
            if isempty(p.Job) && p.Wanted
                t0 = p.WantedTic;
                p.Wanted = false;
                p.WantedTic = [];
                p.startJob(t0);
            end
            if isempty(p.Job) && ~p.Wanted, p.stopCountTimer(); end
        end

        function startJob(p, t0)
            if isempty(t0), t0 = tic; end
            J = struct('Future', [], 'Tic0', t0, 'Result', []);
            pd = p.Options.ParentDir;
            cd = p.Options.CacheDir;
            if p.Options.Background && isempty(p.Pool)
                try
                    p.Pool = backgroundPool;             % (~1 s the first time in a MATLAB session)
                catch
                    p.Options.Background = false;
                end
            end
            if p.Options.Background
                try
                    J.Future = parfeval(p.Pool, @curation.TrainingPanel.countJob, 1, pd, cd);
                catch
                    p.Options.Background = false;
                end
            end
            p.CountsStarted = p.CountsStarted + 1;
            p.CountedTic = tic;
            if isempty(J.Future)
                J.Result = curation.TrainingPanel.countJob(pd, cd);   % no pool: here, between keys
            end
            p.Job = J;
        end

        function stopCountTimer(p)
            t = p.CountTimer;
            if ~isempty(t) && isvalid(t) && strcmp(t.Running, 'on')
                try stop(t); catch, end
            end
        end

        function stopCounting(p, deleteTimer)
            %STOPCOUNTING  Drop the running and the wanted count (the timer is kept for the next,
            %   unless DELETETIMER: the panel goes).
            if nargin < 2, deleteTimer = false; end
            J = p.Job;
            p.Job = [];
            p.Wanted = false;
            if ~isempty(J) && ~isempty(J.Future)
                try cancel(J.Future); catch, end
            end
            t = p.CountTimer;
            if ~isempty(t) && isvalid(t)
                try stop(t); catch, end
                if deleteTimer
                    try delete(t); catch, end
                    p.CountTimer = [];
                end
            end
        end
    end

    methods (Static, Hidden)
        function R = countJob(parentDir, cacheDir)
            %COUNTJOB  (background pool) What every source below PARENTDIR gives to the exports, from
            %   its saved curation files: a rows-only project read (no image, no feature).
            t0 = tic;
            o = struct('ReadImages', false, 'Features', false);
            if ~isempty(cacheDir), o.CacheDir = char(cacheDir); end
            idx = curation.ProjectIndex.build(parentDir, o);
            R = struct('Partials', curation.TrainingPanel.partials(idx), 'CountSec', toc(t0));
        end

        function P = partials(idx)
            %PARTIALS  One row per source: SourceId, Kind, Section, Animal, Good, Uncertain, Bad (the
            %   labels the scorer export takes), AnyM (any of them), AnyGB (any Good or Bad),
            %   Complete, Swept (complete and swept for missed cells).
            src = idx.Sources;
            n = height(src);
            z = zeros(n, 1);
            f = false(n, 1);
            P = table(string(src.SourceId), string(src.Kind), string(src.Section), string(src.Animal), ...
                z, z, z, f, f, f, f, 'VariableNames', {'SourceId', 'Kind', 'Section', 'Animal', 'Good', ...
                'Uncertain', 'Bad', 'AnyM', 'AnyGB', 'Complete', 'Swept'});
            for kind = reshape(unique(P.Kind), 1, [])
                T = idx.table(kind);
                if height(T) == 0, continue; end
                m = curation.TrainingPanel.trainMask(T);
                [~, loc] = ismember(T.SourceId, P.SourceId);
                ok = loc > 0;
                add = @(v) accumarray(loc(ok & v), 1, [n 1]);
                P.Good = P.Good + add(m & T.Label == "Good");
                P.Uncertain = P.Uncertain + add(m & T.Label == "Uncertain");
                P.Bad = P.Bad + add(m & T.Label == "Bad");
            end
            P.AnyM = P.Good + P.Uncertain + P.Bad > 0;
            P.AnyGB = P.Good + P.Bad > 0;
            J = containers.Map('KeyType', 'char', 'ValueType', 'any');     % a section's file, once
            for i = 1:n
                rec = curation.TrainingPanel.record(J, char(src.CurationJson(i)), char(src.Key(i)));
                c = curation.TrainingPanel.flag(rec, 'complete');
                P.Complete(i) = c;
                P.Swept(i) = c && curation.TrainingPanel.flag(rec, 'sweepDone');
            end
        end

        function q = partialOf(C)
            %PARTIALOF  What one source's rows give (C: a table or a struct of its columns).
            m = curation.TrainingPanel.trainMask(C);
            q = struct('Good', nnz(m & C.Label == "Good"), 'Uncertain', nnz(m & C.Label == "Uncertain"), ...
                'Bad', nnz(m & C.Label == "Bad"));
            q.AnyM = q.Good + q.Uncertain + q.Bad > 0;
            q.AnyGB = q.Good + q.Bad > 0;
        end

        function m = trainMask(C)
            %TRAINMASK  The rows the scorer export takes: active, reviewed, a person's label source,
            %   a label, not excluded, not audit evidence (curation.Audit.EXCLUDE_ROLES), not flagged.
            m = C.State == "active" & logical(C.Reviewed) & ismember(C.LabelSource, curation.Store.KEEP_SOURCES) & ...
                ismember(C.Label, ["Good" "Bad" "Uncertain"]) & ~logical(C.Excluded) & ...
                ~ismember(C.AuditRole, curation.Audit.EXCLUDE_ROLES) & C.Flag == "";
        end

        function S = aggregate(P, kind)
            %AGGREGATE  The summary of KIND from the per-source rows.
            S = curation.TrainingPanel.blankSummary(kind);
            S.HasCounts = true;
            P = P(P.Kind == kind, :);
            S.Sources = height(P);
            S.Good = sum(P.Good);
            S.Uncertain = sum(P.Uncertain);
            S.Bad = sum(P.Bad);
            S.Sections = numel(unique(P.Section(P.AnyM)));
            S.Animals = numel(unique(P.Animal(P.AnyGB)));
            S.Complete = nnz(P.Complete);
            S.Swept = nnz(P.Swept);
            M = @curation.UiText.msg;
            if S.Good + S.Bad == 0
                S.Stage2Why = M('trainNo2Labels');
            elseif S.Animals < curation.TrainingPanel.MinAnimals
                S.Stage2Why = M('trainNo2Animals', S.Animals);
            else
                S.Stage2Ok = true;
                S.Stage2Why = "";
            end
            if S.Swept > 0
                S.Stage1Ok = true;
                S.Stage1Why = "";
            elseif S.Complete > 0
                S.Stage1Why = M('trainNo1Sweep', S.Complete);
            else
                S.Stage1Why = M('trainNo1Complete');
            end
        end

        function S = blankSummary(kind)
            S = struct('Kind', string(kind), 'Good', 0, 'Uncertain', 0, 'Bad', 0, 'Sections', 0, ...
                'Animals', 0, 'Sources', 0, 'Complete', 0, 'Swept', 0, 'Stage2Ok', false, ...
                'Stage2Why', "no labels yet", 'Stage1Ok', false, 'Stage1Why', "no source is complete and swept", ...
                'Note', "", 'HasCounts', false, 'Counting', false, 'CountSec', NaN, 'SourcesRead', 0);
        end

        function rec = record(cache, json, key)
            rec = struct();
            if isempty(json) || ~isfile(json), return; end
            k = lower(json);
            if isKey(cache, k)
                J = cache(k);
            else
                try
                    J = jsondecode(fileread(json));
                catch
                    J = struct();
                end
                cache(k) = J; %#ok<NASGU> (a handle: the caller's map)
            end
            if isfield(J, 'sources') && isstruct(J.sources)
                f = matlab.lang.makeValidName(key);
                if isfield(J.sources, key), rec = J.sources.(key);
                elseif isfield(J.sources, f), rec = J.sources.(f);
                end
            end
        end

        function tf = flag(rec, name)
            tf = false;
            if isstruct(rec) && isfield(rec, name)
                v = rec.(name);
                tf = (islogical(v) || isnumeric(v)) && isscalar(v) && logical(v);
            end
        end
    end

    %% ---------------------------------------------------------------------------------- showing
    methods (Access = private)
        function show(p)
            M = @curation.UiText.msg;
            S = p.Summary;
            F = @(n) regexprep(sprintf('%d', round(n)), '(\d)(?=(\d{3})+$)', '$1,');
            name = "PNN (WFA)";
            if S.Kind == "pv", name = "PV"; end
            p.UI.Head.Text = char(curation.UiText.label('trainHead') + ": " + name);
            if ~S.HasCounts
                if S.Counting, txt = M('trainCounting'); else, txt = ''; end
            else
                txt = M('trainCountsText', F(S.Good), F(S.Uncertain), F(S.Bad), S.Sections, S.Animals, ...
                    S.Swept, S.Sources, S.Complete);
                if S.Counting, txt = [txt ' ' M('trainUpdating')]; end
            end
            if strlength(S.Note) > 0, txt = strtrim([char(S.Note) ' ' txt]); end
            p.setText(p.UI.Counts, txt);
            p.updateEnable();
        end

        function updateEnable(p)
            T = @curation.UiText.tip;
            Dz = @curation.UiText.disabled;
            S = p.Summary;
            if isempty(fieldnames(S)), return; end
            if ~S.HasCounts
                % before the first count of the kind: what an export would take is not known yet
                if S.Counting
                    why = curation.UiText.msg('trainCountingWhy');
                elseif strlength(S.Note) > 0
                    why = char(S.Note);
                else
                    why = 'the counts are not read yet: open the Training tab.';
                end
                p.setEnable(p.UI.Export2, false, '', Dz('trainExport2', why));
                p.setEnable(p.UI.Export1, false, '', Dz('trainExport1', why));
                p.setEnable(p.UI.ExportObs, false, '', Dz('trainExportObs', why));
            else
                p.setEnable(p.UI.Export2, S.Stage2Ok, T('trainExport2'), Dz('trainExport2', S.Stage2Why));
                p.setEnable(p.UI.Export1, S.Stage1Ok, T('trainExport1'), Dz('trainExport1', S.Stage1Why));
                obsOk = S.Good + S.Bad + S.Uncertain > 0;
                p.setEnable(p.UI.ExportObs, obsOk, T('trainExportObs'), Dz('trainExportObs', 'no reviewed cell yet.'));
            end
            running = ~isempty(p.Trainer) && isvalid(p.Trainer) && p.Trainer.State == "running";
            if running
                why = 'a fine-tune is running (its state and log are below).';
            elseif isempty(p.LastStage2)
                why = 'export a scorer training set first: the fine-tune trains on the last one.';
            elseif ~p.pythonOk()
                why = char(p.PyWhy);
            else
                why = '';
            end
            tipFt = T('trainFineTune', p.lastName(p.LastStage2));
            p.setEnable(p.UI.FineTune, isempty(why), tipFt, [tipFt ' ' char(8212) ' unavailable now: ' why]);
            if isempty(p.LastStage1)
                p.setEnable(p.UI.CopyCmd, false, '', Dz('trainCopyCmd', 'export a detector training set first: the command trains on it.'));
            else
                p.setEnable(p.UI.CopyCmd, true, T('trainCopyCmd'), '');
            end
        end

        function showTrainer(p)
            t = p.Trainer;
            M = @curation.UiText.msg;
            if isempty(t) || ~isvalid(t)
                p.setText(p.UI.State, M('trainIdle'));
                return
            end
            switch t.State
                case "running"
                    txt = M('trainRunning', upper(t.Command.Kind), t.ExportRoot, t.LogFile);
                case "succeeded"
                    if strlength(string(t.DeployedTo)) > 0
                        txt = M('trainDone', t.DeployedTo);
                    else
                        txt = M('trainDoneNoDeploy', t.RunDir, t.Error);
                    end
                case "failed"
                    txt = M('trainFailed', t.Error, t.LogFile);
                case "cancelled"
                    txt = M('trainCancelled');
                otherwise
                    txt = M('trainIdle');
            end
            if strlength(p.TrainingNote) > 0, txt = [txt ' ' char(p.TrainingNote)]; end
            p.setText(p.UI.State, txt);
            n = numel(t.Lines);
            if n ~= p.LogShown
                L = t.Lines(max(1, n - 60):n);
                if isempty(L), L = ""; end
                p.UI.Log.Value = cellstr(L);
                try scroll(p.UI.Log, 'bottom'); catch, end
                p.LogShown = n;
            end
        end

        function showSummaryFile(p, file, r)
            lines = strings(0, 1);
            if isfile(file)
                try lines = splitlines(string(fileread(file))); catch, end
            end
            if isempty(lines) && ~isempty(r)
                lines = "Status: " + string(r.Status);
            end
            p.UI.SummaryText.Value = cellstr(lines);
        end

        function showError(p, what, err, folder)
            msg = string(what) + ": " + string(err.message);
            p.status(msg);
            lines = msg;
            if ~isempty(folder) && isfile(fullfile(folder, curation.Export.SUMMARY))
                lines = [lines; ""; splitlines(string(fileread(fullfile(folder, curation.Export.SUMMARY))))];
            end
            p.UI.SummaryText.Value = cellstr(lines);
        end

        function setText(~, h, txt)
            txt = char(txt);
            if ~strcmp(h.Text, txt), h.Text = txt; end
        end

        function setEnable(~, h, on, tipOn, tipOff)
            want = matlab.lang.OnOffSwitchState(on);
            if h.Enable ~= want, h.Enable = want; end
            if on, t = tipOn; else, t = tipOff; end
            if ~strcmp(h.Tooltip, t), CellToolkit.setTooltip(h, t); end
        end

        function tf = showing(p)
            tf = false;
            try
                tg = p.Tab.Parent;
                tf = isequal(tg.SelectedTab, p.Tab) && strcmp(char(tg.Visible), 'on');
            catch
            end
        end

        function status(p, txt)
            try p.Options.StatusFcn(char(txt)); catch, end
        end
    end

    %% ---------------------------------------------------------------------------------- work
    methods (Access = private)
        function r = runExport(p, stage, folder)
            r = [];
            S = p.Summary;
            kind = S.Kind;
            M = @curation.UiText.msg;
            if stage == "stage2", what = "scorer"; else, what = "detector"; end
            if isempty(folder)
                folder = p.Options.ChooseFolderFcn(p.startFolder(), ...
                    sprintf('Choose an empty folder for the %s training set (%s)', what, upper(kind)));
                if isequal(folder, 0) || isempty(folder)
                    p.status(sprintf('No %s training set written (no folder chosen).', what));
                    return
                end
            end
            folder = char(folder);
            p.status(M('trainExporting', what, upper(kind), folder));
            drawnow limitrate;
            t0 = tic;
            try
                idx = p.freshIndex();
                o = p.Options.ExportOptions;
                o.Kind = kind;
                if stage == "stage2"
                    o = p.only(o, ["Kind" "Sections" "UncertainLevel" "MinPerClass" "ValidationFraction" ...
                        "SplitSeed" "ValidationAnimals" "AllowSameValidation" "IncludeFlagged" "Overwrite" "Assume" "Python"]);
                    r = curation.Export.stage2(idx, folder, o);
                    p.LastStage2 = folder;
                else
                    o = p.only(o, ["Kind" "Sections" "UncertainIsCell" "IgnoreRadiusUm" "PatchSize" "Overwrite" ...
                        "Assume" "Python"]);
                    r = curation.Export.stage1(idx, folder, o);
                    p.LastStage1 = folder;
                end
                p.LastReport = r;
                p.showSummaryFile(fullfile(folder, curation.Export.SUMMARY), r);
                n = sum([r.Counts.Total]);
                p.status(M('trainExported', what, upper(kind), folder, round(toc(t0))) + ...
                    sprintf(" (%d rows, %d images)", n, height(r.Images)));
            catch err
                p.showError(sprintf('The %s training set was not written', what), err, folder);
            end
            p.updateEnable();
        end

        function idx = freshIndex(p)
            %FRESHINDEX  The folder read now (the curation files only: no image is read, so it takes
            %   about as long as reading the snapshots).
            o = struct('ReadImages', false);
            if ~isempty(p.Options.CacheDir), o.CacheDir = p.Options.CacheDir; end
            idx = curation.ProjectIndex.build(p.Options.ParentDir, o);
        end

        function d = startFolder(p)
            d = '';
            for c = {p.LastStage2, p.LastStage1}
                if ~isempty(c{1}), d = fileparts(c{1}); break; end
            end
            if isempty(d) || ~isfolder(d), d = p.Options.ParentDir; end
            if isempty(d) || ~isfolder(d), d = pwd; end
        end

        function onTrainerDone(p, t)
            if ~isvalid(p), return; end
            M = @curation.UiText.msg;
            if t.State == "succeeded" && strlength(string(t.DeployedTo)) > 0
                p.status(M('trainDone', t.DeployedTo));
            elseif t.State == "failed"
                p.status(M('trainFailed', t.Error, t.LogFile));
            end
            try p.showTrainer(); catch, end
            try p.updateEnable(); catch, end
        end

        function tf = pythonOk(p)
            if ~isempty(p.Options.PythonOk)
                tf = logical(p.Options.PythonOk);
                if ~tf, p.PyWhy = "The countpnn Python environment is not available here."; end
                return
            end
            if isfield(p.Options.TrainerOptions, 'Python') && ~isempty(p.Options.TrainerOptions.Python)
                tf = true;
                return
            end
            if isempty(p.PyOk)
                [p.PyOk, p.PyWhy] = curation.RescoreRunner.pythonStatus(p.Options.RepoRoot);
            end
            tf = p.PyOk;
        end

        function startTimer(p)
            p.stopTimer();
            p.Timer = timer('Name', 'TrainingPanel poll', 'Period', 1, 'ExecutionMode', 'fixedSpacing', ...
                'BusyMode', 'drop', 'ObjectVisibility', 'off', 'TimerFcn', @(~, ~) p.safePoll());
            start(p.Timer);
        end

        function safePoll(p)
            try
                if isvalid(p), p.pollTrainer(); end
            catch
            end
        end

        function stopTimer(p)
            t = p.Timer;
            p.Timer = [];
            if ~isempty(t) && isvalid(t)
                try stop(t); catch, end
                try delete(t); catch, end
            end
        end
    end

    methods (Static, Access = private)
        function o = only(o, names)
            f = fieldnames(o);
            for i = 1:numel(f)
                if ~any(names == string(f{i})), o = rmfield(o, f{i}); end
            end
        end

        function s = lastName(folder)
            if isempty(folder)
                s = 'none yet';
            else
                s = char(folder);
            end
        end
    end
end
