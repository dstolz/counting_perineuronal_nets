classdef RescoreRunner < handle
%RESCORERUNNER  Stage-2 scores for the cells a person added or moved, run in the background and
%   applied to the store between pages (no GUI code; CellCurator wires it).
%
%   A cell a person added or moved has no valid rescore until it is scored (its RescoreSource is
%   "": curation.Store.rescorePending). The score matters downstream: the proposals and the assist
%   model use it, and <stem>_final.csv carries it.
%
%   r = curation.RescoreRunner(opts)
%   ok = r.start(store, kind)    score store.rescorePending() with the scorer of KIND ("pnn" | "pv"):
%                                curation.Rescore.run (its image preparation runs here, in MATLAB's
%                                own thread: the model input of the page is regenerated and written;
%                                then one score.py process runs without blocking MATLAB). False (and
%                                r.Message says why) when nothing is pending, the Python environment
%                                is missing or a job is running already.
%   rep = r.apply()              the finished job's scores into its store, with setRescore (one
%                                transaction, not undoable). Rules: a cell whose position changed
%                                while the job ran (X or Y more than 0.01 px from the position it
%                                was scored at), that is gone or no longer active, is DROPPED (its
%                                score belongs to the old position; it stays pending); while the
%                                store has a batch open (a tile drag) nothing is applied and the
%                                results are kept: Deferred true, try again later. rep: Applied,
%                                Dropped, Deferred, Model, Ids (applied), Ms
%   r.cancel()
%   tf = r.isRunning(), tf = r.hasResults()
%   s = r.State                  "idle" | "running" | "ready" (results wait for apply) | "failed"
%   r.Message                    one line for the status bar (what runs, how long, what failed)
%   r.Job                        the curation.Rescore job (or what RunFcn returned)
%
%   [m, why] = curation.RescoreRunner.defaultModel(kind, repoRoot)
%       the scorer used for KIND: the newest deployed curated scorer of that kind
%       (<repo>/<kind>_curated_<yyyyMMdd>_scoring_ordinal_regression[_n] with best.pth, the most
%       recently deployed first, by curation_provenance.json or else the folder time), else the
%       shipped ordinal-regression scorer <kind>_v2_scoring_ordinal_regression. m: struct Name,
%       Path, Curated (logical); WHY: plain words for a tooltip.
%   [ok, why, cfg] = curation.RescoreRunner.pythonStatus(repoRoot)
%       whether the countpnn Python environment is here (curation.Trainer.defaultPython: the
%       environment's python.exe in the usual Miniconda/Anaconda folders; a bare "python" on the
%       PATH does not count). A cheap file check, no process is started.
%
%   OPTIONS (struct, every field optional)
%     RunFcn     @curation.Rescore.run   fn(stores, opts) -> job with State, Result, Error and
%                                        (optional) cancel(): tests inject a fake Python step
%     RepoRoot   CellToolkit.detectRepoRoot()
%     Python     CellToolkit.pythonConfig struct (default curation.Trainer.defaultPython)
%     Device     "cpu"   (score.py --device; a handful of cells score in seconds on the CPU)
%     Model      ""      a scorer for every kind (default: defaultModel(kind))
%     TolPx      0.01    the position tolerance of the drop rule
%     RunOptions struct() further fields for curation.Rescore.run (e.g. Assume, BatchSize)
%     PythonCheck []     fn(repoRoot) -> [ok, why] (tests); default pythonStatus for the real
%                        RunFcn, none for an injected one
%   [ok, why] = r.pythonReady()  what start checks first (cached)
%
%   See also curation.Rescore, curation.Store (RESCORE), CellCurator.

    properties (SetAccess = private)
        State string = "idle"
        Message string = ""
        Job = []
        Store = []
        Kind string = ""
        Model struct = struct('Name', "", 'Path', "", 'Curated', false)
        Ids uint32 = zeros(0, 1, 'uint32')
        Started = []                     % tic of the start
        PrepareMs double = NaN           % how long Rescore.run blocked MATLAB (image preparation)
        LastApply struct = struct('Applied', 0, 'Dropped', 0, 'Deferred', false, 'Model', "", ...
            'Ids', zeros(0, 1, 'uint32'), 'Ms', NaN)
        Options struct = struct()
    end

    properties (Access = private)
        PyCache = []
    end

    properties (Constant)
        SHIPPED = "%s_v2_scoring_ordinal_regression"
    end

    methods
        function r = RescoreRunner(opts)
            if nargin < 1 || isempty(opts), opts = struct(); end
            o = struct('RunFcn', @curation.Rescore.run, 'RepoRoot', "", 'Python', [], 'Device', "cpu", ...
                'Model', "", 'TolPx', 0.01, 'RunOptions', struct(), 'PythonCheck', []);
            f = fieldnames(opts);
            for i = 1:numel(f)
                if ~isfield(o, f{i})
                    error('curation:RescoreRunner:badArgument', 'Unknown option "%s".', f{i});
                end
                o.(f{i}) = opts.(f{i});
            end
            if strlength(string(o.RepoRoot)) == 0, o.RepoRoot = string(CellToolkit.detectRepoRoot()); end
            r.Options = o;
        end

        function delete(r)
            r.cancel();
        end

        function ok = start(r, store, kind)
            %START  Score the pending cells of STORE (see the class help).
            ok = false;
            if r.isRunning()
                r.Message = "A rescore is running already.";
                return
            end
            if isempty(store) || ~isvalid(store) || store.ReadOnly
                r.Message = "No writable source to rescore.";
                return
            end
            ids = store.rescorePending();
            if isempty(ids)
                r.Message = "Every cell has a score for its position.";
                return
            end
            o = r.Options;
            [pyOk, why, cfg] = r.pythonReady();
            if ~pyOk
                r.Message = why;
                return
            end
            if isempty(o.Python), o.Python = cfg; end
            if strlength(string(o.Model)) > 0
                m = struct('Name', string(o.Model), 'Path', string(o.Model), 'Curated', false);
                [~, nm] = fileparts(char(o.Model));
                m.Name = string(nm);
            else
                m = curation.RescoreRunner.defaultModel(kind, o.RepoRoot);
            end
            ro = o.RunOptions;
            ro.Ids = {ids};
            ro.Model = m.Path;
            ro.Device = o.Device;
            ro.RepoRoot = o.RepoRoot;
            ro.Python = o.Python;
            r.Store = store;
            r.Kind = string(kind);
            r.Model = m;
            r.Ids = ids;
            r.Started = tic;
            r.State = "running";
            r.LastApply = struct('Applied', 0, 'Dropped', 0, 'Deferred', false, 'Model', "", ...
                'Ids', zeros(0, 1, 'uint32'), 'Ms', NaN);
            t0 = tic;
            try
                r.Job = o.RunFcn({store}, ro);
            catch err
                r.State = "failed";
                r.Job = [];
                r.Message = "The rescore could not start: " + string(err.message);
                return
            end
            r.PrepareMs = 1000 * toc(t0);
            r.poll();
            ok = r.State ~= "failed";
        end

        function poll(r)
            %POLL  Notice the end of the job (the job's own timer runs score.py; this only reads its
            %   state). Called by apply and by the owner's idle steps.
            if r.State ~= "running" || isempty(r.Job), return; end
            st = string(r.Job.State);
            n = numel(r.Ids);
            if st == "running"
                r.Message = sprintf('Scoring %d edited %s with %s: score.py running (%.0f s).', n, ...
                    curation.RescoreRunner.cells(n), r.Model.Name, toc(r.Started));
            elseif st == "succeeded"
                r.State = "ready";
                r.Message = sprintf('Scores of %d edited %s are ready (%s).', n, curation.RescoreRunner.cells(n), r.Model.Name);
            else
                r.State = "failed";
                e = "";
                try e = string(r.Job.Error); catch, end
                if strlength(e) == 0, e = st; end
                r.Message = "The rescore failed: " + e + ". The cells stay unscored; try again.";
            end
        end

        function rep = apply(r)
            %APPLY  The scores into the store (see the class help).
            rep = struct('Applied', 0, 'Dropped', 0, 'Deferred', false, 'Model', r.Model.Name, ...
                'Ids', zeros(0, 1, 'uint32'), 'Ms', NaN);
            r.poll();
            if r.State ~= "ready", return; end
            t0 = tic;
            st = r.Store;
            R = r.Job.Result;
            if isempty(st) || ~isvalid(st) || st.ReadOnly
                rep.Dropped = height(R);
                r.finishApply(rep, t0, "The source was closed before its scores came back; they were not stored.");
                return
            end
            ids = uint32(R.CellID(:));
            have = st.get('CellID');
            known = ismember(ids, have);
            keep = known;
            if any(known)
                k = find(known);
                x = st.get('X', ids(k));
                y = st.get('Y', ids(k));
                act = st.get('State', ids(k)) == "active";
                tol = r.Options.TolPx;
                same = abs(x - double(R.X(k))) <= tol & abs(y - double(R.Y(k))) <= tol;
                keep(k) = act & same;
            end
            rep.Dropped = nnz(~keep);
            ids = ids(keep);
            vals = double(R.Rescore(keep));
            if ~isempty(ids)
                model = r.Model.Name;
                if ismember('Model', R.Properties.VariableNames) && strlength(string(R.Model(find(keep, 1)))) > 0
                    [~, nm] = fileparts(char(string(R.Model(find(keep, 1)))));
                    model = string(nm);
                end
                try
                    st.setRescore(ids, vals, model);
                catch err
                    if err.identifier == "curation:Store:inBatch"
                        rep.Deferred = true;          % a drag is open: the next idle step tries again
                        rep.Dropped = 0;
                        r.LastApply = rep;
                        return
                    end
                    r.State = "failed";
                    r.Message = "The scores could not be stored: " + string(err.message);
                    rethrow(err);
                end
                rep.Model = model;
            end
            rep.Applied = numel(ids);
            rep.Ids = ids;
            msg = sprintf('Scored %d edited %s with %s.', rep.Applied, curation.RescoreRunner.cells(rep.Applied), rep.Model);
            if rep.Dropped > 0
                msg = [msg sprintf(' %d moved while it ran and wait for the next rescore.', rep.Dropped)];
            end
            r.finishApply(rep, t0, string(msg));
        end

        function cancel(r)
            if r.State == "running" && ~isempty(r.Job)
                try r.Job.cancel(); catch, end
            end
            if r.State == "running" || r.State == "ready"
                r.State = "idle";
                r.Message = "The rescore was canceled.";
            end
            r.Job = [];
        end

        function [ok, why, cfg] = pythonReady(r)
            %PYTHONREADY  Whether score.py can run here (opts.PythonCheck, else pythonStatus; an
            %   injected RunFcn without a PythonCheck needs no Python). Cached after the first look.
            o = r.Options;
            cfg = o.Python;
            if ~isempty(o.PythonCheck)
                [ok, why] = o.PythonCheck(o.RepoRoot);
            elseif ~isempty(o.Python) || ~isequal(func2str(o.RunFcn), func2str(@curation.Rescore.run))
                ok = true; why = "";
            else
                if isempty(r.PyCache)
                    [okc, whyc, cfgc] = curation.RescoreRunner.pythonStatus(o.RepoRoot);
                    r.PyCache = struct('ok', okc, 'why', whyc, 'cfg', cfgc);
                end
                ok = r.PyCache.ok; why = r.PyCache.why; cfg = r.PyCache.cfg;
            end
            why = string(why);
        end

        function tf = isRunning(r)
            r.poll();
            tf = r.State == "running";
        end

        function tf = hasResults(r)
            r.poll();
            tf = r.State == "ready";
        end
    end

    methods (Access = private)
        function finishApply(r, rep, t0, msg)
            rep.Ms = 1000 * toc(t0);
            r.LastApply = rep;
            r.State = "idle";
            r.Message = msg;
            r.Job = [];
        end
    end

    methods (Static)
        function [m, why] = defaultModel(kind, repoRoot)
            %DEFAULTMODEL  The scorer of KIND (see the class help).
            if nargin < 2 || strlength(string(repoRoot)) == 0, repoRoot = CellToolkit.detectRepoRoot(); end
            kind = lower(string(kind));
            if ~ismember(kind, ["pnn" "pv"]), kind = "pnn"; end
            repo = char(repoRoot);
            shipped = sprintf(curation.RescoreRunner.SHIPPED, kind);
            m = struct('Name', string(shipped), 'Path', string(fullfile(repo, shipped)), 'Curated', false);
            why = sprintf('the shipped ordinal-regression scorer %s', shipped);
            d = dir(fullfile(repo, char(kind + "_curated_*_scoring_ordinal_regression*")));
            d = d([d.isdir]);
            best = ''; bestT = -Inf;
            for k = 1:numel(d)
                name = d(k).name;
                if isempty(regexp(name, ['^' char(kind) '_curated_\d{8}_scoring_ordinal_regression(_\d+)?$'], 'once'))
                    continue
                end
                folder = fullfile(d(k).folder, name);
                if ~isfile(fullfile(folder, 'best.pth')), continue; end
                t = d(k).datenum;
                p = fullfile(folder, 'curation_provenance.json');
                if isfile(p)
                    try
                        J = jsondecode(fileread(p));
                        t = datenum(datetime(J.deployed, 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss')); %#ok<DATNM>
                    catch
                    end
                end
                if t > bestT, bestT = t; best = name; end
            end
            if ~isempty(best)
                m = struct('Name', string(best), 'Path', string(fullfile(repo, best)), 'Curated', true);
                why = sprintf(['the newest scorer fine-tuned on curated labels, %s (deployed %s; the shipped ' ...
                    'one is %s)'], best, char(datetime(bestT, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd HH:mm')), ...
                    shipped);
            end
        end

        function [ok, why, cfg] = pythonStatus(repoRoot)
            %PYTHONSTATUS  Whether the countpnn environment is here (see the class help).
            if nargin < 1 || strlength(string(repoRoot)) == 0, repoRoot = CellToolkit.detectRepoRoot(); end
            cfg = curation.Trainer.defaultPython(char(repoRoot));
            exe = string(cfg.PythonExe);
            ok = isfile(exe);
            if ok
                why = "";
            else
                why = "The countpnn Python environment was not found (looked for envs\countpnn\python.exe " + ...
                    "under Miniconda or Anaconda in your user folder and C:\ProgramData), so score.py cannot " + ...
                    "run here. Install it as the repository's README says (conda create -n countpnn ...).";
            end
        end
    end

    methods (Static, Access = private)
        function s = cells(n)
            if n == 1, s = 'cell'; else, s = 'cells'; end
        end
    end
end
