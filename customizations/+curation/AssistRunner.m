classdef AssistRunner < handle
%ASSISTRUNNER  The assist model of a project folder, run off the key path (no GUI code). It reads
%   the project (curation.ProjectIndex), keeps one curation.AssistModel per channel kind, refits it
%   in the background as labels accumulate, computes the features of the sources on screen and
%   their predictions, chooses the holdout (curation.BlindTiles) and builds the audit report. The
%   owner (CellCurator) calls step() from its idle timer and applies what comes back between pages.
%
%   r = curation.AssistRunner(parentDir, opts)
%   r.start()                          read the project and load the saved models (background)
%   ev = r.step(idleSec)               collect finished work and start what is warranted; never
%                                      throws. ev: Index (the project was read), Holdout (kinds whose
%                                      holdout list is ready), Predictions (owner ids with new
%                                      predictions), Fitted (kinds refitted), Report (a report is
%                                      ready), Busy (work in flight), Status (one line or "")
%   r.register(id, info)               a source on screen (owner id, e.g. CellCurator's session id):
%                                      info SourceId, Kind, Rows (table CellID, X, Y, score, rescore,
%                                      InLocs: the store's rows), PageT, PageC ([] = none), Um. Its
%                                      features are computed in the background (or read from the
%                                      runner's cache), then predicted with the model of its kind
%                                      Each registration gets a token: a feature or prediction job
%                                      of an earlier registration of the same id (closed and opened
%                                      again with other rows) is dropped, and results whose CellIDs
%                                      or length do not match the rows are refused
%   r.unregister(id)
%   r.noteLabels()                     labels changed: the project is read again within RefreshSec
%   [ok, P] = r.takePredictions(id)    new predictions of a registered source: P.Ids, P.P, P.Raw,
%                                      P.Version (ok false when nothing new)
%   raw = r.rawFor(id, ids)            the model's raw score of IDS (NaN where none): opts.Raw of
%                                      curation.Queues
%   s = r.summary(kind)                what the window's Assist block shows (see SUMMARY)
%   L = r.holdout(kind)                the holdout list of KIND (curation.BlindTiles.readHoldout form)
%   r.requestReport()                  build curation.Audit.report of the project (background)
%   [ok, R] = r.takeReport()           R: Report (curation.Audit.report), Text (string array: one
%                                      paragraph per kind plus the audit-size lines), Lines (the
%                                      audit-size lines alone), Generated
%   tf = r.isBusy()
%   r.close()                          cancel what runs
%
%   OPTIONS (struct, every field optional)
%     Background true       work on backgroundPool (thread workers; parfeval, never a parpool),
%                           one job at a time (the others queue), so the window keeps its cores.
%                           false, or no background pool: each job runs inside step() (blocking;
%                           tests and the fallback)
%     MinNewLabels 150      training labels new since the last fit before a refit starts
%     RefreshSec 15         the project is read again at most this often while labels change
%     MissingFeatIdleSec 3  idle seconds before the features of a labeled source that is not on
%                           screen are computed (its image pages are read here: ~0.3 s blocking)
%     HoldoutTarget 400, HoldoutFraction 0.05   (curation.BlindTiles.holdoutSize)
%     Holdout true          choose the holdout lists when there are none
%     FitOptions struct()   passed to curation.AssistModel.fit (Seed 1, Kind, Sections, Ids are set)
%     CacheDir              the project index's feature cache (default: ProjectIndex's), and the
%                           runner's own feature files (assistfeat_<hash>.mat) in the same folder
%
%   FEATURES. Thread workers cannot read TIFF files (imread is not supported there), so the index,
%   read in the background, has no image features of its own. The runner computes the features of
%   each source on screen from the pages the window already holds (curation.Features.compute in
%   the background) and keeps them in assistfeat_<hash of SourceId>.mat; a labeled source that is
%   not on screen gets its features in idle time (its pages are read here). The fit joins them to
%   the index's training rows by CellID (positions within 0.01 px; a moved cell is left out until
%   its source is opened again).
%
%   MODELS. One per kind, saved at curation.ProjectIndex.modelPath(parentDir, kind) with a sidecar
%   assist_<kind>.json (number, labels, sections, animals, AUCs, time). A fit starts when
%   curation.AssistModel.enoughLabels holds for the labeled rows with features and at least
%   MinNewLabels of them are new since the last fit (one fit in flight per kind; another starts when
%   it ends if still warranted). Groups are animals (grouped cross-validation), Ids the RowIds.
%
%   SUMMARY s = r.summary(kind): Kind, Mode ("cold" | "model"), Labels, Good, Bad (training labels
%   of the project), MinLabels 200, MinPerClass 30, Number, NTrain, NSections, NAnimals (of the
%   model), AUC (out of fold), AUCRescore (the rescore baseline on the same rows), Refitting,
%   BlindN (labels decided blind, Good or Bad), BlindMatch (of those, where the proposal, P >= 0.5,
%   equaled the decision; P = ModelP, else the cold start), IndexState ("none" | "reading" |
%   "ready" | "failed"), Note.
%
%   See also curation.AssistModel, curation.ProjectIndex, curation.Features, curation.BlindTiles,
%   curation.Audit.

    properties (Constant)
        FEAT_FORMAT = "assistfeat/1"
    end

    properties (SetAccess = private)
        ParentDir char = ''
        CacheDir char = ''
        Options struct = struct()
        Index = []                      % the latest curation.ProjectIndex (a copy from the background)
        IndexState string = "none"      % none | reading | ready | failed
        IndexNote string = ""
        Kinds struct = struct([])       % per channel kind (see newKind)
        Sources struct = struct([])     % registered sources (see emptySources)
        Counters struct = struct('IndexReads', 0, 'Fits', 0, 'FeatureJobs', 0, 'Predictions', 0, ...
            'Reports', 0, 'Failures', 0)
        Background logical = false
        LastError string = ""
        FitLog string = strings(1, 0)   % one line per fit started: kind, number, labels with features
    end

    properties (Access = private)
        Pool = []
        Jobs struct = struct([])
        Dirty logical = false
        LastRead = []
        Report = []
        ReportWanted logical = false
        Missing struct = struct('SourceId', {}, 'Kind', {}, 'Image', {}, 'Page', {}, 'CompanionPage', {}, ...
            'Um', {}, 'Rows', {})
        Closed logical = false
        Stepping logical = false        % inside step (it is not re-entered)
        TokenSeq double = 0             % registrations so far: each source's jobs carry its token
    end

    %% ------------------------------------------------------------------ construction
    methods
        function r = AssistRunner(parentDir, opts)
            if nargin < 2 || isempty(opts), opts = struct(); end
            o = struct('Background', true, 'MinNewLabels', 150, 'RefreshSec', 15, 'MissingFeatIdleSec', 3, ...
                'HoldoutTarget', curation.BlindTiles.HOLDOUT_TARGET, ...
                'HoldoutFraction', curation.BlindTiles.HOLDOUT_FRACTION, 'Holdout', true, ...
                'FitOptions', struct(), 'CacheDir', '');
            f = fieldnames(opts);
            for i = 1:numel(f), o.(f{i}) = opts.(f{i}); end
            r.ParentDir = char(parentDir);
            r.Kinds = curation.AssistRunner.emptyKinds();
            r.Sources = curation.AssistRunner.emptySources();
            r.Jobs = curation.AssistRunner.emptyJobs();
            if isempty(o.CacheDir)
                root = getenv('LOCALAPPDATA');
                if isempty(root), root = tempdir; end
                o.CacheDir = fullfile(root, 'counting_perineuronal_nets', 'cache', ...
                    char(curation.Hash.of(lower(string(r.ParentDir)))));
            end
            r.CacheDir = char(o.CacheDir);
            r.Options = o;
            r.Background = logical(o.Background);     % the pool itself is taken in start()
        end

        function delete(r)
            r.close();
        end

        function close(r)
            if r.Closed, return; end
            r.Closed = true;
            for k = 1:numel(r.Jobs)
                f = r.Jobs(k).Future;
                if ~isempty(f) && ~r.Jobs(k).Queued
                    try cancel(f); catch, end
                end
            end
            r.Jobs = curation.AssistRunner.emptyJobs();
        end
    end

    %% ------------------------------------------------------------------ public API
    methods
        function start(r)
            %START  Read the project (background) and load the saved models when it is read.
            if r.Closed || r.IndexState == "reading", return; end
            if ~isfolder(r.CacheDir)
                try mkdir(r.CacheDir); catch, end
            end
            if r.Background && isempty(r.Pool)
                try
                    r.Pool = backgroundPool;          % started once per MATLAB session (~1 s the first time)
                catch err
                    r.Background = false;
                    r.LastError = "No background pool (" + string(err.message) + "): work runs between key presses.";
                end
            end
            r.IndexState = "reading";
            r.LastRead = tic;
            r.Dirty = false;
            r.submit("index", "", @curation.AssistRunner.indexJob, 2, {r.ParentDir, r.CacheDir, [], r.CacheDir, ~r.Background});
        end

        function ev = step(r, idleSec)
            %STEP  Collect finished work, start what is warranted (see the class help). Never throws.
            if nargin < 2, idleSec = 0; end
            ev = struct('Index', false, 'Holdout', strings(1, 0), 'Predictions', strings(1, 0), ...
                'Fitted', strings(1, 0), 'Report', false, 'Busy', false, 'Status', "");
            if r.Closed, return; end
            if r.Stepping
                % re-entered: fetching a result (or starting a job) lets MATLAB run callbacks, and the
                % owner's idle timer may call step again; the outer step does the work
                ev.Busy = true;
                return
            end
            r.Stepping = true;
            try
                ev = r.collect(ev);
                r.plan(idleSec);
            catch err
                r.LastError = string(err.message);
                r.Counters.Failures = r.Counters.Failures + 1;
            end
            r.Stepping = false;
            ev.Busy = r.isBusy();
        end

        function register(r, id, info)
            %REGISTER  A source on screen (see the class help); its features and predictions follow.
            id = string(id);
            k = r.sourceIndex(id);
            if k == 0
                k = numel(r.Sources) + 1;
                r.Sources(k).Id = id;
            end
            S = r.Sources(k);
            S.Id = id;
            S.SourceId = string(info.SourceId);
            S.Kind = string(info.Kind);
            S.Rows = info.Rows;
            S.FeatState = "computing";
            S.CellID = uint32(info.Rows.CellID(:));
            S.F = [];
            S.P = [];
            S.Raw = [];
            S.Version = "";
            S.Pending = false;
            S.Predicting = false;
            r.TokenSeq = r.TokenSeq + 1;
            S.Token = r.TokenSeq;             % jobs of an earlier registration of this id are dropped
            r.Sources(k) = S;
            path = r.featPath(S.SourceId);
            r.submit("feat", id, @curation.AssistRunner.featJob, 1, ...
                {info.PageT, info.PageC, info.Rows, double(info.Um), path, S.SourceId}, "", S.Token);
            r.Counters.FeatureJobs = r.Counters.FeatureJobs + 1;
        end

        function unregister(r, id)
            k = r.sourceIndex(string(id));
            if k > 0, r.Sources(k) = []; end
        end

        function noteLabels(r)
            r.Dirty = true;
        end

        function [ok, P] = takePredictions(r, id)
            ok = false;
            P = struct('Ids', zeros(0, 1, 'uint32'), 'P', zeros(0, 1), 'Raw', zeros(0, 1), 'Version', "");
            k = r.sourceIndex(string(id));
            if k == 0 || ~r.Sources(k).Pending, return; end
            S = r.Sources(k);
            P = struct('Ids', S.CellID, 'P', S.P, 'Raw', S.Raw, 'Version', S.Version);
            r.Sources(k).Pending = false;
            ok = true;
        end

        function raw = rawFor(r, id, ids)
            ids = uint32(ids(:));
            raw = nan(numel(ids), 1);
            k = r.sourceIndex(string(id));
            if k == 0 || isempty(r.Sources(k).Raw), return; end
            [tf, loc] = ismember(ids, r.Sources(k).CellID);
            raw(tf) = r.Sources(k).Raw(loc(tf));
        end

        function s = summary(r, kind, live)
            %SUMMARY  See SUMMARY in the class help. LIVE (optional): struct array SourceId, NTrain,
            %   NGood, NBad of sources whose labels the caller holds now (the window's open stores):
            %   they replace those sources' counts of the last read, so the counts follow every
            %   confirmed page instead of lagging by up to RefreshSec.
            kind = string(kind);
            s = struct('Kind', kind, 'Mode', "cold", 'Labels', 0, 'Good', 0, 'Bad', 0, 'MinLabels', 200, ...
                'MinPerClass', 30, 'Number', 0, 'NTrain', 0, 'NSections', 0, 'NAnimals', 0, 'AUC', NaN, ...
                'AUCRescore', NaN, 'Refitting', false, 'BlindN', 0, 'BlindMatch', 0, ...
                'IndexState', r.IndexState, 'Note', r.IndexNote);
            j = r.kindIndex(kind);
            if j == 0, return; end
            K = r.Kinds(j);
            s.Labels = K.Labels.NTrain;
            s.Good = K.Labels.NGood;
            s.Bad = K.Labels.NBad;
            if nargin >= 3 && ~isempty(live)
                P = K.PerSource;
                for i = 1:numel(live)
                    q = live(i);
                    hit = [];
                    if ~isempty(P), hit = find(lower(P.SourceId) == lower(string(q.SourceId)), 1); end
                    if ~isempty(hit)
                        s.Labels = s.Labels - P.NTrain(hit);
                        s.Good = s.Good - P.NGood(hit);
                        s.Bad = s.Bad - P.NBad(hit);
                    end
                    s.Labels = s.Labels + q.NTrain;
                    s.Good = s.Good + q.NGood;
                    s.Bad = s.Bad + q.NBad;
                end
            end
            s.BlindN = K.Blind.N;
            s.BlindMatch = K.Blind.Match;
            s.Refitting = K.Fitting;
            if K.Note ~= "", s.Note = K.Note; end
            if ~isempty(K.Model)
                s.Mode = "model";
                I = K.Info;
                s.Number = I.number;
                s.NTrain = I.nTrain;
                s.NSections = I.nSections;
                s.NAnimals = I.nAnimals;
                s.AUC = I.auc;
                s.AUCRescore = I.aucRescore;
            end
        end

        function L = holdout(r, kind)
            j = r.kindIndex(string(kind));
            if j == 0 || isempty(r.Kinds(j).Holdout)
                L = [];
            else
                L = r.Kinds(j).Holdout;
            end
        end

        function requestReport(r)
            if r.Closed, return; end
            if r.hasJob("report"), return; end
            r.ReportWanted = true;
            r.Report = [];
            if r.IndexState == "ready" || r.IndexState == "failed"
                r.startReport();
            end
        end

        function [ok, R] = takeReport(r)
            ok = ~isempty(r.Report);
            R = r.Report;
            r.Report = [];
        end

        function tf = isBusy(r)
            tf = ~isempty(r.Jobs) || r.ReportWanted;
        end

        function s = jobSummary(r)
            %JOBSUMMARY  The work in flight, one "type key state" per job (diagnostics).
            s = strings(1, numel(r.Jobs));
            for k = 1:numel(r.Jobs)
                st = "done";
                if r.Jobs(k).Queued
                    st = "queued";
                elseif ~r.Jobs(k).Done
                    st = string(r.Jobs(k).Future.State);
                end
                s(k) = r.Jobs(k).Type + " " + r.Jobs(k).Key + " " + st;
            end
        end

        function tf = isSettled(r, id)
            %ISSETTLED  Registered source ID has its features, and predictions of the current model of
            %   its kind (when there is one) that have been taken (tests wait for this).
            k = r.sourceIndex(string(id));
            tf = true;
            if k == 0, return; end
            S = r.Sources(k);
            if S.FeatState == "computing" || S.Pending || S.Predicting
                tf = false;
            elseif S.FeatState == "ready" && r.hasModel(S.Kind)
                tf = S.Version == r.versionOf(S.Kind);
            end
        end

        function s = secondsToNextStep(r, idleSec)
            %SECONDSTONEXTSTEP  When step() next has something to start while nothing is in flight:
            %   the project read again after labels changed (RefreshSec), or the features of a
            %   labeled source that is not on screen (MissingFeatIdleSec of idle). Inf: nothing.
            if nargin < 2, idleSec = 0; end
            s = Inf;
            if r.Closed || r.IndexState ~= "ready", return; end
            if r.Dirty, s = max(0, r.Options.RefreshSec - toc(r.LastRead)); end
            if ~isempty(r.Missing), s = min(s, max(0, r.Options.MissingFeatIdleSec - idleSec)); end
        end

        function tf = hasModel(r, kind)
            j = r.kindIndex(string(kind));
            tf = j > 0 && ~isempty(r.Kinds(j).Model);
        end

        function m = model(r, kind)
            m = [];
            j = r.kindIndex(string(kind));
            if j > 0, m = r.Kinds(j).Model; end
        end
    end

    %% ------------------------------------------------------------------ the work loop
    methods (Access = private)
        function ev = collect(r, ev)
            k = 1;
            while k <= numel(r.Jobs)
                J = r.Jobs(k);
                if J.Queued
                    k = k + 1;
                    continue
                end
                if ~J.Done
                    f = J.Future;
                    state = string(f.State);
                    if ~any(state == ["finished" "failed" "unavailable"])
                        k = k + 1;
                        continue
                    end
                end
                r.Jobs(k) = [];                  % taken before anything can run in between
                if ~J.Done
                    J.Err = f.Error;
                    if isempty(J.Err) && state ~= "finished"
                        J.Err = MException('curation:AssistRunner:jobLost', 'The background job ended as "%s".', state);
                    end
                    if isempty(J.Err)
                        try
                            J.Out = cell(1, f.NumOutputArguments);
                            [J.Out{:}] = fetchOutputs(f);
                        catch err
                            J.Err = err;
                        end
                    end
                end
                ev = r.finish(J, ev);
            end
            r.startQueued();
        end

        function ev = finish(r, J, ev)
            if ~isempty(J.Err)
                r.Counters.Failures = r.Counters.Failures + 1;
                msg = string(J.Err.message);
                r.LastError = J.Type + ": " + msg;
            end
            switch J.Type
                case "index"
                    if isempty(J.Err)
                        r.Index = J.Out{1};
                        r.takeStats(J.Out{2});
                        r.IndexState = "ready";
                        r.IndexNote = "";
                        r.Counters.IndexReads = r.Counters.IndexReads + 1;
                        ev.Index = true;
                        ev.Holdout = [ev.Holdout r.afterIndex()];
                    elseif isempty(r.Index)
                        r.IndexState = "failed";
                        r.IndexNote = "The project could not be read: " + string(J.Err.message);
                    end
                case "load"
                    j = r.kindIndex(J.Key);
                    if j == 0, return; end
                    r.Kinds(j).Loading = false;
                    if isempty(J.Err) && ~isempty(J.Out{1}) && isempty(r.Kinds(j).Model)
                        r.Kinds(j).Model = J.Out{1};
                        r.Kinds(j).Info = J.Out{2};
                        r.Kinds(j).NTrainAtFit = J.Out{2}.nTrain;
                        r.predictAll(J.Key);
                    end
                case "fit"
                    j = r.kindIndex(J.Key);
                    if j == 0, return; end
                    r.Kinds(j).Fitting = false;
                    if isempty(J.Err)
                        r.Kinds(j).Model = J.Out{1};
                        r.Kinds(j).Info = J.Out{2};
                        r.Kinds(j).NTrainAtFit = J.Out{2}.nTrain;
                        r.Kinds(j).Note = "";
                        r.Counters.Fits = r.Counters.Fits + 1;
                        ev.Fitted(end + 1) = J.Key;
                        r.predictAll(J.Key);
                    else
                        r.Kinds(j).Note = "The last refit failed: " + string(J.Err.message);
                        r.Kinds(j).NTrainAtFit = r.Kinds(j).Labels.NFeat;   % do not retry at once
                    end
                case "feat"
                    s = r.sourceIndex(J.Key);
                    if s == 0, return; end
                    if J.Token ~= r.Sources(s).Token
                        return            % computed for an earlier registration (other rows): dropped
                    end
                    if isempty(J.Err) && ~isequal(uint32(J.Out{1}.CellID(:)), r.Sources(s).CellID(:))
                        J.Err = MException('curation:AssistRunner:rowsChanged', 'The features are of other rows.');
                    end
                    if isempty(J.Err)
                        out = J.Out{1};
                        r.Sources(s).F = out.F;
                        r.Sources(s).FeatState = "ready";
                        r.Dirty = true;                 % its labels can train now
                        r.predict(s);
                    else
                        r.Sources(s).FeatState = "failed";
                    end
                case "missing"
                    r.Dirty = true;
                case "predict"
                    s = r.sourceIndex(J.Key);
                    if s == 0, return; end
                    if J.Token ~= r.Sources(s).Token
                        return            % predicted for an earlier registration: its P belongs to other rows
                    end
                    r.Sources(s).Predicting = false;
                    if isempty(J.Err) && numel(J.Out{1}) ~= numel(r.Sources(s).CellID)
                        J.Err = MException('curation:AssistRunner:rowsChanged', 'The predictions are of other rows.');
                    end
                    if isempty(J.Err) && J.Version == r.versionOf(r.Sources(s).Kind)
                        r.Sources(s).P = J.Out{1};
                        r.Sources(s).Raw = J.Out{2};
                        r.Sources(s).Version = J.Version;
                        r.Sources(s).Pending = true;
                        r.Counters.Predictions = r.Counters.Predictions + 1;
                        ev.Predictions(end + 1) = J.Key;
                    elseif isempty(J.Err)
                        r.predict(s);                   % a newer model arrived meanwhile
                    else
                        r.Sources(s).Version = J.Version;   % failed (LastError says why): not retried
                    end
                case "holdout"
                    j = r.kindIndex(J.Key);
                    if j == 0, return; end
                    if isempty(J.Err)
                        try
                            L = curation.BlindTiles.writeHoldout(r.ParentDir, J.Key, J.Out{1});
                            r.Kinds(j).Holdout = L;
                            r.Kinds(j).HoldoutState = "ready";
                            ev.Holdout(end + 1) = J.Key;
                        catch err
                            r.Kinds(j).HoldoutState = "failed";
                            r.Kinds(j).Note = "The holdout list could not be written: " + string(err.message);
                        end
                    else
                        r.Kinds(j).HoldoutState = "failed";
                    end
                case "report"
                    if isempty(J.Err)
                        r.Report = J.Out{1};
                        if ~isempty(J.Out{2}), r.Index = J.Out{2}; end
                    else
                        r.Report = struct('Report', [], 'Text', "The report could not be built: " + ...
                            string(J.Err.message), 'Lines', strings(0, 1), 'Generated', string(datetime('now')));
                    end
                    r.Counters.Reports = r.Counters.Reports + 1;
                    ev.Report = true;
            end
        end

        function plan(r, idleSec)
            % read the project again when labels changed (rate-limited)
            busyIndex = r.hasJob("index");
            if r.IndexState == "ready" && r.Dirty && ~busyIndex && toc(r.LastRead) >= r.Options.RefreshSec
                r.Dirty = false;
                r.LastRead = tic;
                r.submit("index", "", @curation.AssistRunner.indexJob, 2, {r.ParentDir, r.CacheDir, r.Index, r.CacheDir, ~r.Background});
            end
            if r.ReportWanted && (r.IndexState == "ready" || r.IndexState == "failed") && ...
                    ~r.hasJob("report")
                r.startReport();
            end
            if r.IndexState ~= "ready", return; end
            % fits
            for j = 1:numel(r.Kinds)
                K = r.Kinds(j);
                if K.Fitting || K.Loading, continue; end
                L = K.Labels;
                enough = curation.AssistModel.enoughLabels([true(L.NFeatGood, 1); false(L.NFeatBad, 1)]);
                if ~enough, continue; end
                if isempty(K.Model) || L.NFeat - K.NTrainAtFit >= r.Options.MinNewLabels
                    r.startFit(j);
                end
            end
            % features of a labeled source that is not on screen (its pages are read here)
            if idleSec >= r.Options.MissingFeatIdleSec && ~isempty(r.Missing) && ...
                    ~r.hasJob(["missing" "feat"])
                M = r.Missing(1);
                r.Missing(1) = [];
                try
                    if ~(isfinite(M.Um) && M.Um > 0)
                        M.Um = CellToolkit.tiffPixelSizeUm(char(M.Image), M.Page);
                    end
                    if ~(isfinite(M.Um) && M.Um > 0), M.Um = curation.Store.DEFAULT_UM_PER_PIXEL; end
                    pT = imread(char(M.Image), M.Page);
                    pC = [];
                    if isfinite(M.CompanionPage)
                        pC = imread(char(M.Image), M.CompanionPage);
                        if ~isequal(size(pC), size(pT)), pC = []; end
                    end
                    r.submit("missing", M.SourceId, @curation.AssistRunner.featJob, 1, ...
                        {pT, pC, M.Rows, M.Um, r.featPath(M.SourceId), M.SourceId});
                catch
                end
            end
        end

        function ready = afterIndex(r)
            % models to load, holdout lists to read or choose; READY: kinds whose holdout list was
            % read from its file now
            ready = strings(1, 0);
            for j = 1:numel(r.Kinds)
                K = r.Kinds(j);
                if isempty(K.Model) && ~K.Loading && ~K.Fitting && ~K.Tried
                    r.Kinds(j).Tried = true;
                    p = curation.ProjectIndex.modelPath(r.ParentDir, K.Name);
                    if isfile(p)
                        r.Kinds(j).Loading = true;
                        r.submit("load", K.Name, @curation.AssistRunner.loadJob, 2, {p, r.infoPath(K.Name)});
                    end
                end
                if r.Options.Holdout && K.HoldoutState == "none"
                    L = curation.BlindTiles.readHoldout(r.ParentDir, K.Name);
                    if height(L) > 0
                        r.Kinds(j).Holdout = L;
                        r.Kinds(j).HoldoutState = "ready";
                        ready(end + 1) = K.Name; %#ok<AGROW>
                    elseif K.Candidates > 0
                        r.Kinds(j).HoldoutState = "sampling";
                        o = struct('Target', r.Options.HoldoutTarget, 'MaxFraction', r.Options.HoldoutFraction);
                        r.submit("holdout", K.Name, @curation.AssistRunner.holdoutJob, 1, {r.Index, K.Name, o});
                    end
                end
            end
        end

        function takeStats(r, S)
            for i = 1:numel(S.Kinds)
                s = S.Kinds(i);
                j = r.kindIndex(s.Name);
                if j == 0
                    j = numel(r.Kinds) + 1;
                    r.Kinds(j) = curation.AssistRunner.newKind(s.Name);
                end
                r.Kinds(j).Labels = s.Labels;
                r.Kinds(j).Blind = s.Blind;
                r.Kinds(j).Candidates = s.Candidates;
                r.Kinds(j).PerSource = s.PerSource;
            end
            % labeled sources without features that are not on screen
            have = strings(1, 0);
            if ~isempty(r.Sources), have = [r.Sources.SourceId]; end
            M = S.Missing;
            if ~isempty(M)
                M = M(~ismember(lower([M.SourceId]), lower(have)));
            end
            r.Missing = M;
        end

        function startFit(r, j)
            K = r.Kinds(j);
            number = 1;
            if ~isempty(K.Info) && isfield(K.Info, 'number'), number = K.Info.number + 1; end
            r.Kinds(j).Fitting = true;
            r.FitLog(end + 1) = sprintf('%s #%d: %d labels with features (%d at the last fit)', K.Name, number, ...
                K.Labels.NFeat, K.NTrainAtFit);
            r.submit("fit", K.Name, @curation.AssistRunner.fitJob, 2, {r.Index, K.Name, r.CacheDir, ...
                curation.ProjectIndex.modelPath(r.ParentDir, K.Name), r.infoPath(K.Name), number, r.Options.FitOptions});
        end

        function startReport(r)
            r.ReportWanted = false;
            r.submit("report", "", @curation.AssistRunner.reportJob, 2, {r.Index, r.ParentDir, r.CacheDir, ~r.Background});
        end

        function predictAll(r, kind)
            for s = 1:numel(r.Sources)
                if r.Sources(s).Kind == kind, r.predict(s); end
            end
        end

        function predict(r, s)
            S = r.Sources(s);
            m = r.model(S.Kind);
            if isempty(m) || S.FeatState ~= "ready" || isempty(S.F) || S.Predicting, return; end
            r.Sources(s).Predicting = true;
            r.submit("predict", S.Id, @curation.AssistRunner.predictJob, 2, {m, S.F}, m.Version, S.Token);
        end

        function v = versionOf(r, kind)
            v = "";
            m = r.model(kind);
            if ~isempty(m), v = m.Version; end
        end

        function submit(r, type, key, fcn, nout, args, version, token)
            %SUBMIT  Queue a job. In the background ONE job runs at a time (one worker busy: the other
            %   cores stay free for the window); without it the job runs here, now.
            if nargin < 7, version = ""; end
            if nargin < 8, token = 0; end
            J = struct('Type', string(type), 'Key', string(key), 'Future', [], 'Done', false, 'Out', {{}}, ...
                'Err', [], 'Version', string(version), 'Queued', false, 'Fcn', fcn, 'NOut', nout, 'Args', {args}, ...
                'Token', token);
            if r.Background
                J.Queued = true;
                r.Jobs(end + 1) = J;
                r.startQueued();
                return
            end
            r.runHere(J);
        end

        function startQueued(r)
            %STARTQUEUED  Start the oldest queued job when none is running.
            running = false;
            first = 0;
            for k = 1:numel(r.Jobs)
                if r.Jobs(k).Done, continue; end
                if r.Jobs(k).Queued
                    if first == 0, first = k; end
                else
                    running = true;
                end
            end
            if running || first == 0, return; end
            J = r.Jobs(first);
            try
                f = parfeval(r.Pool, J.Fcn, J.NOut, J.Args{:});
                r.Jobs(first).Future = f;
                r.Jobs(first).Queued = false;
                r.Jobs(first).Args = {};
            catch err
                r.LastError = "Background work failed to start (" + string(err.message) + "); running here.";
                r.Background = false;
                r.Jobs(first) = [];
                r.runHere(J);
            end
        end

        function runHere(r, J)
            J.Done = true;
            J.Queued = false;
            J.Out = cell(1, J.NOut);
            try
                [J.Out{:}] = J.Fcn(J.Args{:});
            catch err
                J.Err = err;
            end
            J.Args = {};
            r.Jobs(end + 1) = J;
        end

        function k = sourceIndex(r, id)
            k = 0;
            if isempty(r.Sources), return; end
            hit = find([r.Sources.Id] == string(id), 1);
            if ~isempty(hit), k = hit; end
        end

        function j = kindIndex(r, kind)
            j = 0;
            if isempty(r.Kinds), return; end
            hit = find([r.Kinds.Name] == string(kind), 1);
            if ~isempty(hit), j = hit; end
        end

        function tf = hasJob(r, types)
            tf = false;
            for k = 1:numel(r.Jobs)
                if any(r.Jobs(k).Type == types), tf = true; return; end
            end
        end

        function p = featPath(r, sid)
            p = curation.AssistRunner.featFile(r.CacheDir, sid);
        end

        function p = infoPath(r, kind)
            p = fullfile(r.ParentDir, '.cellcuration', ['assist_' char(kind) '.json']);
        end
    end

    %% ------------------------------------------------------------------ jobs (run on a worker)
    methods (Static)
        function p = featFile(cacheDir, sid)
            p = fullfile(char(cacheDir), ['assistfeat_' char(curation.Hash.of(lower(string(sid)))) '.mat']);
        end

        function [idx, S] = indexJob(parentDir, cacheDir, idx, featDir, readImages)
            %INDEXJOB  Read the project (build, or refresh a copy) and count what the runner needs.
            %   On the background pool READIMAGES is false (thread workers cannot read TIFF files:
            %   curation.ProjectIndex BACKGROUND); the features then come from the runner's own
            %   jobs (FEATURES in the class help).
            if nargin < 5, readImages = true; end
            if isempty(idx)
                idx = curation.ProjectIndex.build(parentDir, struct('CacheDir', cacheDir, 'ReadImages', readImages));
            else
                idx.refresh();
            end
            S = curation.AssistRunner.kindStats(idx, featDir);
        end

        function S = kindStats(idx, featDir)
            kinds = unique(string(idx.Sources.Kind))';
            K = struct('Name', {}, 'Labels', {}, 'Blind', {}, 'Candidates', {}, 'PerSource', {});
            Mi = struct('SourceId', {}, 'Kind', {}, 'Image', {}, 'Page', {}, 'CompanionPage', {}, 'Um', {}, 'Rows', {});
            for kind = kinds
                T = idx.table(kind);
                n = height(T);
                m = curation.AssistModel.trainingMask(T);
                good = T.Label == "Good";
                sids = unique(T.SourceId(m));
                hasF = false(n, 1);
                for s = reshape(sids, 1, [])
                    if isfile(curation.AssistRunner.featFile(featDir, s))
                        hasF = hasF | T.SourceId == s;
                    else
                        i = find(idx.Sources.SourceId == s, 1);
                        if ~isempty(i) && idx.Sources.ImageFile(i) ~= ""
                            R = T(T.SourceId == s, {'CellID', 'X', 'Y', 'score', 'rescore', 'InLocs'});
                            um = idx.Sources.UmPerPx(i);
                            if ~(isfinite(um) && um > 0) || idx.Sources.UmSource(i) == "default", um = NaN; end
                            Mi(end + 1) = struct('SourceId', s, 'Kind', kind, 'Image', idx.Sources.ImageFile(i), ... %#ok<AGROW>
                                'Page', idx.Sources.Page(i), 'CompanionPage', idx.Sources.CompanionPage(i), ...
                                'Um', um, 'Rows', R);
                        end
                    end
                end
                L = struct('NTrain', nnz(m), 'NGood', nnz(m & good), 'NBad', nnz(m & ~good), ...
                    'NFeat', nnz(m & hasF), 'NFeatGood', nnz(m & hasF & good), 'NFeatBad', nnz(m & hasF & ~good));
                b = T.State == "active" & T.LabelSource == "blind" & ismember(T.Label, ["Good" "Bad"]);
                key = "";
                if kind == "pnn", key = "PNN"; elseif kind == "pv", key = "PV"; end
                P = curation.Proposals.coldStart(T(b, :), key);
                mp = double(T.ModelP(b));
                P(isfinite(mp)) = mp(isfinite(mp));
                match = (P >= 0.5) == (T.Label(b) == "Good");
                B = struct('N', nnz(b), 'Match', nnz(match));
                [us, ~, ui] = unique(T.SourceId);
                PS = table(us, accumarray(ui, double(m), [numel(us) 1]), ...
                    accumarray(ui, double(m & good), [numel(us) 1]), accumarray(ui, double(m & ~good), [numel(us) 1]), ...
                    'VariableNames', {'SourceId', 'NTrain', 'NGood', 'NBad'});
                K(end + 1) = struct('Name', kind, 'Labels', L, 'Blind', B, ... %#ok<AGROW>
                    'Candidates', nnz(T.State == "active" & ~T.Excluded), 'PerSource', PS);
            end
            S = struct('Kinds', K, 'Missing', Mi);
        end

        function L = holdoutJob(idx, kind, opts)
            L = curation.BlindTiles.sampleHoldout(idx, kind, opts);
        end

        function [m, info] = loadJob(path, infoPath)
            m = curation.AssistModel.load(path);
            info = curation.AssistRunner.readInfo(infoPath, m);
        end

        function out = featJob(pageT, pageC, rows, um, path, sid)
            %FEATJOB  Features of ROWS: the runner's file when it matches the rows, else computed and
            %   written.
            ids = uint32(rows.CellID(:));
            x = double(rows.X(:));
            y = double(rows.Y(:));
            if isfile(path)
                try
                    C = load(path);
                    if isfield(C, 'Format') && string(C.Format) == curation.AssistRunner.FEAT_FORMAT && ...
                            string(C.Version) == curation.Features.VERSION && isequal(uint32(C.CellID(:)), ids) && ...
                            all(abs(C.X(:) - x) < 1e-6) && all(abs(C.Y(:) - y) < 1e-6) && abs(C.Um - um) < 1e-9
                        out = struct('CellID', ids, 'X', x, 'Y', y, 'F', C.F);
                        return
                    end
                catch
                end
            end
            if ~(isfinite(um) && um > 0)
                error('curation:AssistRunner:noScale', 'No pixel size for %s.', sid);
            end
            F = curation.Features.compute(pageT, pageC, rows, um, struct('NeighborMask', logical(rows.InLocs(:))));
            C = struct('Format', curation.AssistRunner.FEAT_FORMAT, 'SourceId', string(sid), 'CellID', ids, ...
                'X', x, 'Y', y, 'F', F, 'Names', curation.Features.names(), 'Version', curation.Features.VERSION, ...
                'Um', um);
            try
                folder = fileparts(path);
                if ~isfolder(folder), mkdir(folder); end
                [~, tok] = fileparts(tempname);
                tmp = [char(path) '.' tok '.tmp.mat'];
                save(tmp, '-struct', 'C', '-v7');
                movefile(tmp, path, 'f');
            catch
            end
            out = struct('CellID', ids, 'X', x, 'Y', y, 'F', F);
        end

        function [p, raw] = predictJob(m, F)
            [p, raw] = m.predict(F);
        end

        function [m, info] = fitJob(idx, kind, featDir, modelPath, infoPath, number, fitOpts)
            %FITJOB  The training set of KIND (index rows + the runner's features), the fit, the files.
            [F, y, g, sec, ids] = curation.AssistRunner.trainingSet(idx, kind, featDir);
            if ~curation.AssistModel.enoughLabels(y)
                error('curation:AssistRunner:notEnough', 'Not enough labels with features to fit (%d).', numel(y));
            end
            o = fitOpts;
            if ~isfield(o, 'Seed'), o.Seed = 1; end
            o.Kind = kind;            % (the leaf size adapts to the rows inside AssistModel.fit)
            o.Sections = sec;
            o.Ids = ids;
            m = curation.AssistModel.fit(F, y, g, o);
            m.save(modelPath);
            info = struct('number', number, 'nTrain', numel(y), 'nGood', nnz(y), 'nBad', nnz(~y), ...
                'nSections', numel(unique(sec)), 'nAnimals', numel(unique(g)), 'auc', m.Stats.AUC, ...
                'aucRescore', m.Stats.AUCRescore, 'time', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
                'version', char(m.Version), 'kind', char(kind));
            try
                folder = fileparts(infoPath);
                if ~isfolder(folder), mkdir(folder); end
                fid = fopen(infoPath, 'w', 'n', 'UTF-8');
                fprintf(fid, '%s', jsonencode(info, 'PrettyPrint', true));
                fclose(fid);
            catch
            end
        end

        function [F, y, groups, sections, ids] = trainingSet(idx, kind, featDir)
            %TRAININGSET  Labeled rows of KIND (curation.AssistModel.trainingMask) that have features:
            %   the index's own where it has them, else the runner's (by CellID, X/Y within 0.01 px).
            K = numel(curation.Features.names());
            [T, Fi] = idx.table(kind);
            rows = find(curation.AssistModel.trainingMask(T));
            F = nan(numel(rows), K);
            have = false(numel(rows), 1);
            if ~isempty(Fi)
                fi = Fi(rows, :);
                ok = any(isfinite(fi), 2);
                F(ok, :) = fi(ok, :);
                have(ok) = true;
            end
            sid = T.SourceId(rows);
            for s = reshape(unique(sid(~have)), 1, [])
                p = curation.AssistRunner.featFile(featDir, s);
                if ~isfile(p), continue; end
                try
                    C = load(p);
                catch
                    continue
                end
                q = find(sid == s & ~have);
                [tf, loc] = ismember(uint32(T.CellID(rows(q))), uint32(C.CellID(:)));
                near = false(numel(q), 1);
                near(tf) = abs(C.X(loc(tf)) - T.X(rows(q(tf)))) < 0.01 & abs(C.Y(loc(tf)) - T.Y(rows(q(tf)))) < 0.01;
                F(q(near), :) = C.F(loc(near), :);
                have(q(near)) = true;
            end
            rows = rows(have);
            F = F(have, :);
            y = T.Label(rows) == "Good";
            groups = T.Animal(rows);
            sections = T.Section(rows);
            ids = T.RowId(rows);
        end

        function [R, idx] = reportJob(idx, parentDir, cacheDir, readImages)
            %REPORTJOB  The audit report of the project (read again first) and its text.
            if nargin < 4, readImages = true; end
            if isempty(idx)
                idx = curation.ProjectIndex.build(parentDir, struct('CacheDir', cacheDir, 'ReadImages', readImages));
            else
                idx.refresh();
            end
            rep = curation.Audit.report(idx);
            txt = curation.Audit.reportText(rep);
            lines = strings(0, 1);
            for i = 1:numel(rep.Kinds)
                s = rep.Kinds(i);
                name = upper(s.Kind);
                if s.Kind == "pnn", name = "PNN (WFA)"; elseif s.Kind == "pv", name = "PV"; end
                if s.ConfirmAuditN >= 30 && isfinite(s.ConfirmAuditRate)
                    rate = s.ConfirmAuditRate;
                    basis = sprintf('at the %.1f%% observed so far', 100 * rate);
                else
                    rate = 0.05;
                    basis = 'assuming a 5% rate until 30 tiles are judged';
                end
                need = curation.Audit.confirmAuditSize(0.01, rate);
                more = max(0, need - s.ConfirmAuditN);
                lines(end + 1, 1) = string(sprintf(['%s: to state how often a tile confirmed by default changes ' ...
                    'when judged blind to within +-1 point (95%% CI), about %s confirm-audit tiles must be judged ' ...
                    '(%s): %s more than the %s judged so far.'], name, curation.AssistRunner.fmt(need), basis, ...
                    curation.AssistRunner.fmt(more), curation.AssistRunner.fmt(s.ConfirmAuditN))); %#ok<AGROW>
            end
            R = struct('Report', rep, 'Text', [txt(:); lines], 'Lines', lines, 'Generated', string(rep.Generated));
        end

        function info = readInfo(path, m)
            info = struct('number', 1, 'nTrain', 0, 'nGood', 0, 'nBad', 0, 'nSections', 0, 'nAnimals', 0, ...
                'auc', NaN, 'aucRescore', NaN, 'time', '', 'version', '', 'kind', '');
            if nargin >= 2 && ~isempty(m)
                S = m.Stats;
                info.nTrain = S.N;
                info.nGood = S.NGood;
                info.nBad = S.NBad;
                info.nSections = S.NSections;
                info.nAnimals = S.NGroups;
                info.auc = S.AUC;
                info.aucRescore = S.AUCRescore;
                info.version = char(m.Version);
            end
            if isfile(path)
                try
                    J = jsondecode(fileread(path));
                    for f = fieldnames(J)'
                        if isfield(info, f{1}) && ~isempty(J.(f{1})), info.(f{1}) = J.(f{1}); end
                    end
                    if isempty(info.auc), info.auc = NaN; end
                    if isempty(info.aucRescore), info.aucRescore = NaN; end
                catch
                end
            end
        end
    end

    methods (Static, Access = private)
        function s = fmt(n)
            if ~isfinite(n), s = 'many'; return; end
            s = regexprep(sprintf('%d', round(double(n))), '(\d)(?=(\d{3})+$)', '$1,');
        end

        function K = emptyKinds()
            K = struct('Name', {}, 'Model', {}, 'Info', {}, 'Loading', {}, 'Fitting', {}, 'Tried', {}, ...
                'NTrainAtFit', {}, 'Labels', {}, 'Blind', {}, 'Candidates', {}, 'Holdout', {}, ...
                'HoldoutState', {}, 'Note', {}, 'PerSource', {});
        end

        function K = newKind(name)
            K = struct('Name', string(name), 'Model', [], 'Info', [], 'Loading', false, 'Fitting', false, ...
                'Tried', false, 'NTrainAtFit', 0, ...
                'Labels', struct('NTrain', 0, 'NGood', 0, 'NBad', 0, 'NFeat', 0, 'NFeatGood', 0, 'NFeatBad', 0), ...
                'Blind', struct('N', 0, 'Match', 0), 'Candidates', 0, 'Holdout', [], 'HoldoutState', "none", 'Note', "", ...
                'PerSource', table());
        end

        function S = emptySources()
            S = struct('Id', {}, 'SourceId', {}, 'Kind', {}, 'Rows', {}, 'FeatState', {}, 'CellID', {}, ...
                'F', {}, 'P', {}, 'Raw', {}, 'Version', {}, 'Pending', {}, 'Predicting', {}, 'Token', {});
        end

        function J = emptyJobs()
            J = struct('Type', {}, 'Key', {}, 'Future', {}, 'Done', {}, 'Out', {}, 'Err', {}, 'Version', {}, ...
                'Queued', {}, 'Fcn', {}, 'NOut', {}, 'Args', {}, 'Token', {});
        end
    end
end
