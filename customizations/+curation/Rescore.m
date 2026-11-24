classdef Rescore < handle
%RESCORE  Stage-2 scores (score.py) for cells whose position a person set: added, moved, merged.
%   A detection's rescore comes from the detector run (the locs file) and is refreshed on each
%   reconcile. A cell a person added, moved or merged has none that belongs to its position.
%
%   ids = curation.Rescore.pending(store)       CellIDs that need a rescore (rule below)
%   job = curation.Rescore.run(stores, opts)    score them (asynchronous unless opts.Wait)
%   ok  = job.wait(timeoutSec)                  block until done (scripts, tests)
%   job.cancel()
%   job.Result                                  table: Store (index into stores), Key, CellID,
%                                               Rescore, X, Y, Xp, Yp, Model, Image (the scores keyed
%                                               by CellID, for the caller to apply)
%
%   PENDING RULE (State "active" rows only):
%     Origin "added" or "merged"                                    (no detector position), or
%     PosSource "human" or "snap" with X/Y more than opts.TolPx (0.01 px) from DET_X/DET_Y, or
%     DET_X/DET_Y NaN                                               (moved, or never detected).
%   Merged-away and stale rows are never pending. opts (pending): TolPx 0.01.
%
%   RUN. For each store (a curation.Store; a cell array or array of them), the rows opts.Ids (a
%   cell per store; default pending(store)) are scored on the DETECTOR's scale, exactly as
%   CellDiscovery rescores: the model input of the source's page is regenerated
%   (CellToolkit.modelInputFactsFor + modelInputFromFile from the manifest's detection facts:
%   resized to 0.645 um/px, normalised to 0-255) and the points are mapped like the detector's
%   output, Xp = X * resize, Yp = Y * resize (score.py rounds them to the crop centre). The image
%   is written as a temporary HDF5 file (score.py reads .h5 directly, same values as the scratch
%   TIFF CellDiscovery scores on); the input CSV has the columns idx (consumed as the index by
%   score.py), imgName, Xp, Yp, rescore_key. One score.py process per scoring model (all
%   images of that model in one CSV: the model loads once; score.py batches per image), run one
%   after another without blocking MATLAB.
%   Model per store: opts.Model (a model folder name under the repository or a path), else the
%   model recorded in the manifest's rescore stage for the source (so new values match the
%   source's existing ones), else <kind>_v2_scoring_ordinal_regression.
%   opts: Ids, Model, Device ("cpu"), BatchSize (256), Python (CellToolkit.pythonConfig; default
%   curation.Trainer.defaultPython), RepoRoot, Assume (model-input facts to assume, see
%   CellToolkit.modelInputFactsFor), Wait (false), Timeout (600 s, with Wait), OnDone
%   (fn(job)), KeepFiles (false), PollPeriod 0.5.
%   job also has: State (running | succeeded | failed | cancelled), Facts (per store: the facts
%   used, with what was assumed), Log (output lines), Error, WorkDir.
%
%   WRITING THE SCORES BACK: store.setRescore(Result.CellID, Result.Rescore, Result.Model) (not
%   undoable, journaled; RescoreSource names the scorer). Only for cells still at the position
%   they were scored at (Result.X/Y): a cell moved while the job ran keeps a pending score.
%   setRescore throws curation:Store:inBatch while a batch is open: apply between pages.
%   curation.RescoreRunner does all of this for CellCurator.
%
%   See also curation.Export, curation.Trainer, curation.RescoreRunner, CellToolkit.modelInputPage.

    properties (SetAccess = private)
        State string = "idle"
        Result table = table()
        Facts cell = {}
        Log string = strings(0, 1)
        Error string = ""
        WorkDir char = ''
        Options struct = struct()
    end

    properties (Access = private)
        Queue cell = {}      % per model: struct model, inCsv, outCsv, cfg, args
        Current double = 0
        Proc = []
        Reader = []
        Timer = []
        Busy logical = false
        Points table = table()
    end

    methods (Static)

        function ids = pending(store, opts)
            if nargin < 2, opts = struct(); end
            tol = 0.01;
            if isfield(opts, 'TolPx'), tol = opts.TolPx; end
            T = store.T;
            ids = curation.Rescore.pendingMask(T, tol);
            ids = T.CellID(ids);
        end

        function m = pendingMask(T, tol)
            if nargin < 2, tol = 0.01; end
            act = T.State == "active";
            noDet = isnan(T.DET_X) | isnan(T.DET_Y);
            moved = hypot(T.X - T.DET_X, T.Y - T.DET_Y) > tol;
            m = act & (ismember(T.Origin, ["added" "merged"]) | noDet | ...
                (ismember(T.PosSource, ["human" "snap"]) & moved));
        end

        function job = run(stores, opts)
            if nargin < 2, opts = struct(); end
            if ~iscell(stores), stores = arrayfun(@(x) x, stores, 'UniformOutput', false); end
            o = struct('Ids', {{}}, 'Model', "", 'Device', "cpu", 'BatchSize', 256, 'Python', [], ...
                'RepoRoot', "", 'Assume', struct(), 'Wait', false, 'Timeout', 600, 'OnDone', [], ...
                'KeepFiles', false, 'PollPeriod', 0.5);
            f = fieldnames(opts);
            for i = 1:numel(f)
                if ~isfield(o, f{i}), error('curation:Rescore:badArgument', 'Unknown option "%s".', f{i}); end
                o.(f{i}) = opts.(f{i});
            end
            repo = char(o.RepoRoot);
            if isempty(repo), repo = CellToolkit.detectRepoRoot(); end
            if isempty(o.Python), o.Python = curation.Trainer.defaultPython(repo); end
            o.RepoRoot = repo;
            job = curation.Rescore();
            job.Options = o;
            job.WorkDir = tempname(fullfile(tempdir));
            mkdir(job.WorkDir);

            % ---- the images and points
            P = {};
            byModel = containers.Map();
            for i = 1:numel(stores)
                s = stores{i};
                if iscell(o.Ids) && numel(o.Ids) >= i && ~isempty(o.Ids{i})
                    ids = o.Ids{i};
                elseif ~iscell(o.Ids) && ~isempty(o.Ids) && numel(stores) == 1
                    ids = o.Ids;
                else
                    ids = curation.Rescore.pending(s);
                end
                ids = ids(:);
                job.Facts{i} = struct();
                if isempty(ids), continue; end
                [imgFile, page, det, model, locs] = curation.Rescore.sourceOf(s, o, repo);
                resized = regexprep(locs, '_locs\.csv$', '_locs_resized.csv', 'ignorecase');
                if ~isfile(resized), resized = ''; end
                [facts, frep] = CellToolkit.modelInputFactsFor(det, imgFile, page, locs, resized, ...
                    struct('Assume', o.Assume));
                job.Facts{i} = struct('facts', facts, 'report', frep, 'image', string(imgFile), 'page', page, ...
                    'model', string(model));
                img = CellToolkit.modelInputFromFile(imgFile, page, facts);
                stem = sprintf('img%03d_%s', i, regexprep(char(s.Meta.Key), '[^A-Za-z0-9_\-]', '_'));
                curation.Export.writeH5(fullfile(job.WorkDir, [stem '.h5']), img, [], facts, false);
                rows = s.rowsOf(ids);
                X = s.T.X(rows); Y = s.T.Y(rows);
                n = numel(ids);
                key = string(i) + "|" + string(ids);
                P{end + 1} = table(repmat(i, n, 1), repmat(string(s.Meta.Key), n, 1), double(ids), X, Y, ...
                    X * facts.resize, Y * facts.resize, repmat(string(model), n, 1), repmat(string([stem '.h5']), n, 1), ...
                    key, 'VariableNames', {'Store', 'Key', 'CellID', 'X', 'Y', 'Xp', 'Yp', 'Model', 'Image', 'RescoreKey'}); %#ok<AGROW>
                if ~isKey(byModel, model), byModel(model) = {}; end
                byModel(model) = [byModel(model), {numel(P)}];
            end
            if isempty(P)
                job.Points = table();
                job.State = "succeeded";
                job.Result = curation.Rescore.emptyResult();
                job.finish();
                return;
            end
            job.Points = vertcat(P{:});

            % ---- one score.py run per model
            models = keys(byModel);
            for k = 1:numel(models)
                Pm = job.Points(job.Points.Model == string(models{k}), :);
                n = height(Pm);
                inTbl = table((0:n - 1)', Pm.Image, Pm.Xp, Pm.Yp, Pm.RescoreKey, ...
                    'VariableNames', {'idx', 'imgName', 'Xp', 'Yp', 'rescore_key'});
                inCsv = fullfile(job.WorkDir, sprintf('score_in_%d.csv', k));
                outCsv = fullfile(job.WorkDir, sprintf('score_out_%d.csv', k));
                writetable(inTbl, inCsv);
                args = CellToolkit.scoreArgs(models{k}, inCsv, struct('root', job.WorkDir, ...
                    'device', char(o.Device), 'batchSize', o.BatchSize, 'output', outCsv));
                cfg = o.Python;
                cfg.WorkingDir = repo;
                job.Queue{end + 1} = struct('model', string(models{k}), 'inCsv', inCsv, 'outCsv', outCsv, ...
                    'cfg', cfg, 'args', {args});
            end
            job.State = "running";
            job.Result = curation.Rescore.emptyResult();
            job.next();
            if job.State == "running"
                job.Timer = timer('Period', max(0.1, o.PollPeriod), 'ExecutionMode', 'fixedSpacing', ...
                    'BusyMode', 'drop', 'Name', 'curation.Rescore', 'TimerFcn', @(~, ~) job.poll());
                start(job.Timer);
            end
            if o.Wait
                job.wait(o.Timeout);
            end
        end
    end

    methods
        function poll(job)
            if job.Busy || job.State ~= "running", return; end
            job.Busy = true;
            c = onCleanup(@() job.setBusy(false));
            job.take(CellToolkit.drainReader(job.Reader));
            try
                code = double(job.Proc.exitValue());
            catch
                return;
            end
            job.take(CellToolkit.drainReader(job.Reader, true));
            q = job.Queue{job.Current};
            job.Proc = []; job.Reader = [];
            if code ~= 0 || ~isfile(q.outCsv)
                job.State = "failed";
                job.Error = sprintf("score.py failed (exit %d) for %s", code, q.model);
                job.finish();
                return;
            end
            R = readtable(q.outCsv, 'TextType', 'string', 'VariableNamingRule', 'preserve');
            [tf, loc] = ismember(job.Points.RescoreKey, string(R.rescore_key));
            Pm = job.Points(tf, :);
            Pm.Rescore = double(R.rescore(loc(tf)));
            job.Result = [job.Result; Pm(:, {'Store', 'Key', 'CellID', 'Rescore', 'X', 'Y', 'Xp', 'Yp', 'Model', 'Image'})];
            job.next();
        end

        function ok = wait(job, timeoutSec)
            if nargin < 2, timeoutSec = Inf; end
            t0 = tic;
            while job.State == "running" && toc(t0) < timeoutSec
                job.poll();
                if job.State ~= "running", break; end
                pause(0.2);
            end
            ok = job.State ~= "running";
        end

        function cancel(job)
            if job.State ~= "running", return; end
            try job.Proc.destroyForcibly(); catch, end
            job.State = "cancelled";
            job.finish();
        end

        function delete(job)
            job.stopTimer();
        end
    end

    methods (Access = private)
        function job = Rescore()
        end

        function setBusy(job, v)
            job.Busy = v;
        end

        function next(job)
            job.Current = job.Current + 1;
            if job.Current > numel(job.Queue)
                job.State = "succeeded";
                job.finish();
                return;
            end
            q = job.Queue{job.Current};
            job.Log(end + 1) = "[curation.Rescore] " + string(CellToolkit.commandString( ...
                CellToolkit.pythonCommandParts(q.cfg, q.args)));
            try
                [job.Proc, job.Reader] = CellToolkit.launchPythonAsync(q.cfg, q.args);
            catch ME
                job.State = "failed";
                job.Error = string(ME.message);
                job.finish();
            end
        end

        function take(job, lines)
            for k = 1:numel(lines)
                job.Log(end + 1, 1) = string(lines{k});
            end
        end

        function finish(job)
            job.stopTimer();
            if ~job.Options.KeepFiles && ~isempty(job.WorkDir) && isfolder(job.WorkDir)
                try rmdir(job.WorkDir, 's'); catch, end
            end
            if ~isempty(job.Options.OnDone)
                try job.Options.OnDone(job); catch, end
            end
        end

        function stopTimer(job)
            if ~isempty(job.Timer) && isvalid(job.Timer)
                stop(job.Timer);
                delete(job.Timer);
            end
            job.Timer = [];
        end
    end

    methods (Static, Access = private)
        function R = emptyResult()
            e = strings(0, 1); z = zeros(0, 1);
            R = table(z, e, z, z, z, z, z, z, e, e, 'VariableNames', ...
                {'Store', 'Key', 'CellID', 'Rescore', 'X', 'Y', 'Xp', 'Yp', 'Model', 'Image'});
        end

        function [imgFile, page, det, model, locs] = sourceOf(s, o, repo)
            % image, page, detection facts and scoring model of a store's source
            M = s.Meta;
            key = char(M.Key);
            locs = char(M.LocsFile);
            if ~isempty(locs) && ~curation.Rescore.isAbs(locs), locs = fullfile(char(M.Folder), locs); end
            mf = CellDatasetManifest.forCsv(locs);
            imgFile = '';
            try imgFile = char(mf.imageForLocs(locs)); catch, end
            if isempty(imgFile), imgFile = CellToolkit.inferImagePath(locs); end
            if isempty(imgFile) || ~isfile(imgFile)
                error('curation:Rescore:noImage', 'No image found for %s.', locs);
            end
            [~, page] = mf.channelPage(key);
            if ~isfinite(page), page = 1; end
            det = struct();
            model = '';
            src = mf.source(key);
            if isstruct(src) && isfield(src, 'stages')
                if isfield(src.stages, 'detection') && isstruct(src.stages.detection)
                    det = src.stages.detection;
                end
                if isfield(src.stages, 'rescore') && isstruct(src.stages.rescore) ...
                        && isfield(src.stages.rescore, 'model') && ~isempty(src.stages.rescore.model)
                    model = char(src.stages.rescore.model);
                end
            end
            if strlength(string(o.Model)) > 0, model = char(o.Model); end
            if isempty(model)
                model = sprintf('%s_v2_scoring_ordinal_regression', curation.Proposals.kindOf(key));
            end
            if ~curation.Rescore.isAbs(model) && isfolder(fullfile(repo, model))
                model = fullfile(repo, model);
            end
        end

        function tf = isAbs(p)
            p = char(p);
            tf = numel(p) > 1 && (p(2) == ':' || startsWith(p, '\\') || startsWith(p, '/'));
        end
    end
end
