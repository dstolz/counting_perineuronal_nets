classdef AssistModel
%ASSISTMODEL  Calibrated P(Good) for cell candidates: bagged trees + grouped cross-validation +
%   isotonic calibration. One model per channel kind ("pnn" / "pv"), trained on every human label
%   of the project; it orders the review and pre-fills proposals once enough labels exist.
%
%   ok = curation.AssistModel.enoughLabels(y, opts)     >= 200 labels and >= 30 of each class
%   m  = curation.AssistModel.fit(F, y, groups, opts)   F: N x K features (curation.Features),
%                                                       y: logical (true = Good), groups: string
%                                                       per row (animal id) for grouped CV
%   [p, raw] = m.predict(F)    calibrated P(Good), N x 1 in (0,1), and the raw score; p keeps the
%                              ORDER of raw (strictly increasing in it, see CALIBRATION)
%   r  = m.predictRaw(F)       the ensemble's uncalibrated score for class Good
%   m.save(path); m = curation.AssistModel.load(path)
%
%   TRAINING-LABEL POLICY (the one place it is defined)
%   mask = curation.AssistModel.trainingMask(T)   rows of a curation snapshot table that train it:
%       State "active", Reviewed, Label Good or Bad, LabelSource in {human, confirmed, blind,
%       legacy-qc}, not Excluded, AuditRole not holdout / reject-audit / catch
%       (curation.Audit.exportExclusionMask: the blind evidence and the attention checks, whose
%       answer may be wrong on purpose and must never become a Good example). Uncertain, auto
%       (never a person), legacy-resolver (duplicate decisions, not "not a cell") and
%       merged/stale rows are never used. Confirm-audit rows and blind re-asks without a role
%       (disagreements re-asked blind) DO train, with their blind label: each is one of the
%       labelled rows, re-labelled; leaving them out would remove exactly the rows where the model
%       and the first label disagreed and make the model and its calibration overconfident
%       (measured: with 3% of rows re-asked, fresh rows with P < 0.05 held 4.5% cells against a
%       mean P of 0.25% when they were left out, 2.4% against 1.5% when kept).
%   mask = curation.AssistModel.blindMask(T)      LabelSource "blind" or AuditRole in {holdout,
%       reject-audit, confirm-audit, catch}: tiles shown without a proposal. A description, NOT
%       a calibration set (see CalibrateOn).
%   Missing columns take the snapshot defaults (State active, Reviewed false, text "").
%
%   FIT OPTIONS (struct, every field optional)
%     Seed 1              reproducible: same data + seed -> identical model and predictions
%                         (the global random stream is restored afterwards)
%     NumTrees 200        trees of the final model
%     CVTrees 40          trees per cross-validation model (fewer than the final model to keep
%                         the fit within seconds; the out-of-fold scores then have coarser steps
%                         but the same expectation as the final model's)
%     Folds 5             K of the grouped K-fold cross-validation
%     MinLeafSize []      [] (default): adapts to the rows each ensemble is grown on, one fiftieth
%                         of a bag (FResample x rows), between 5 and 40: 5 at the 200-label gate
%                         (folds of ~160 rows), 16-20 at 2,000 labels, 40 from ~4,000 on. A fixed
%                         40 let no tree of a small fold split (out-of-fold AUC 0.49, P nearly
%                         constant at the label gate). A number is used as given. Stats.MinLeafSize
%                         and Stats.MinLeafSizeCV (per fold) say what was used.
%     NumVariablesToSample ceil(sqrt(K)), NumBins 32 (histogram split search;
%                         [] = exact splits), FResample 0.5 (each tree grows on a bootstrap
%                         sample half the size of the data), Reproducible true. Measured on
%                         20,000 x 30: same out-of-fold AUC as MinLeafSize 5 / exact splits /
%                         full-size bags, at about a sixth of the time.
%     Sections []         section per row: folds fall back to sections when there are fewer
%                         animal groups than folds (Stats.FoldGrouping/FoldNote say so)
%     CalibrateOn []      logical mask that NARROWS the rows the isotonic map is fitted on (default
%                         [] = every out-of-fold row, which is right in almost every case). Pass a
%                         mask only for rows that are a random sample of the candidates the model
%                         will score, chosen without looking at their labels, the model or the
%                         reviewer's decision. Audit, catch and re-ask rows are NOT such a sample
%                         (they are chosen by label or disagreement): calibrating on them made
%                         58-68% of all candidates P exactly 0. Fewer than MinCalibration (100)
%                         rows in the mask, or one class only -> all out-of-fold rows, with the
%                         reason in Stats.CalibrationSource / Stats.CalibrationNote.
%     MinTailEvents 10    the lowest isotonic block must hold at least this many Good rows and
%                         the highest at least this many Bad rows (adjacent blocks are pooled until
%                         they do, within the 0.15 / 0.85 bands; see CALIBRATION)
%     FeatureNames        default curation.Features.names() when K matches
%     Kind ""             "pnn" | "pv" (for the cold-start baseline's cutpoint)
%     Ids []              string id per row (e.g. "<SourceId>|<CellID>"): kept in Stats.Ids and
%                         hashed into Version
%     UseParallel "auto"  parallel tree growing ONLY when a parallel pool is already open (never
%                         starts one); true/false to force
%
%   MODEL. fitcensemble(Method "Bag") of classification trees, class prior "uniform" (the class
%   imbalance is handled by the prior; calibration maps the scores back to real frequencies).
%   Missing values (NaN features, e.g. rescore or companion features) use the trees' native
%   handling: a NaN row is not routed by a split on that feature and takes that node's class
%   probabilities (no surrogate splits: they cost too much time).
%   predict does not call the ensemble's predict (which loops over the trees with a fixed cost
%   per tree): the trees are compiled once into flat node arrays (compileForest) and every row
%   and tree is routed together, one level per step, in chunks of ~65,000 (row, tree) pairs,
%   comparing integer codes of the features against the forest's own sorted cut points
%   (forestScore). The result equals the ensemble's predict up to summation order (~1e-15).
%
%   CALIBRATION. Folds are grouped: all rows of one animal (group) fall in one fold, so a model
%   is always scored on animals it did not see. Out-of-fold raw scores of every training row ->
%   isotonic regression (pool-adjacent-violators, curation.AssistModel.isotonicFit) -> a
%   monotone map, linear between knots and clamped outside them, applied to the final model's
%   raw scores. TAILS: the lowest PAV block is the minimum of running means, so its in-sample
%   value is optimistic for new data (often exactly 0; the highest often exactly 1). The extreme
%   blocks are therefore pooled with their neighbours until the lowest holds MinTailEvents (10)
%   Good rows and the highest 10 Bad rows, pooling only neighbours below 0.15 / above 0.85 (the
%   review queue's likely-bad / likely-good bands: no row changes band through it, and perfectly
%   separated classes are never merged); an extreme block left with fewer events takes the
%   Jeffreys estimate (k + 0.5) / (n + 1), and the map is kept inside [0.5/(N+1), 1 - 0.5/(N+1)].
%   Measured on fresh simulated sections (tAssistModel/tailsNotOverconfidentOnFreshSections; 8
%   projects, fit on 10 sections, 20 fresh; observed / mean predicted in the 5% of fresh rows with
%   the lowest raw score): plain PAV 1.61 (base) and 1.81 (strong section shifts), with 2.1-2.3%
%   of fresh rows at P exactly 0; pooled to 10 events 0.54 and 0.46, none at 0 or 1, and a lower
%   log-loss than plain PAV in all six regimes tried. ORDER: predict adds 1e-6 * (raw - 0.5) to
%   the map, so P is strictly increasing in the raw score (rows in one flat block are ordered by
%   it, never by CellID) and moves by less than 5e-7.
%
%   STATS (m.Stats)
%     N NGood NBad NGroups NSections Folds FoldGrouping FoldNote Fold (fold of each row)
%     OofRaw OofP (calibrated out-of-fold P of every training row) AUC (out-of-fold raw scores)
%     AUCCalibrated Brier Reliability (table: Bin Lo Hi MeanPredicted Observed Count)
%     Importance (table Name Importance) FitSeconds CVSeconds CalibrationSource CalibrationNote
%     CalibrationRows MinTailEvents
%     Version AUCRescore NRescore AUCModelOnRescoreRows AUCColdStart BeatsRescore
%     BeatsColdStart TreesFinal TreesCV MinLeafSize MinLeafSizeCV Parallel Seed Kind Ids
%   The baselines are scored on the same rows: raw rescore (rows where it is finite) and
%   curation.Proposals.coldStart (all rows).
%
%   See also curation.Features, curation.ProjectIndex, curation.Audit, curation.Proposals.

    properties (Constant)
        FORMAT = "assistmodel/1"
        KEEP_SOURCES = ["human", "confirmed", "blind", "legacy-qc"]
        BLIND_ROLES = ["holdout", "reject-audit", "confirm-audit", "catch"]
        NO_TRAIN_ROLES = ["holdout", "reject-audit", "catch"]   % = curation.Audit.EXCLUDE_ROLES
        ORDER_RAMP = 1e-6       % P = map(raw) + ORDER_RAMP * (raw - 0.5): strictly increasing
        TAIL_BANDS = [0.15 0.85]   % tail pooling stays below / above these (the queue's bands)
    end

    properties (SetAccess = private)
        Ensemble = []                 % compact bagged ensemble, classes [false true]
        Forest struct = struct()      % the same trees as flat arrays (compileForest), used by predict
        IsoX (:, 1) double = 0        % isotonic map knots: raw score ...
        IsoY (:, 1) double = 0.5      % ... -> calibrated P(Good)
        FeatureNames (1, :) string = strings(1, 0)
        Kind (1, 1) string = ""
        Version (1, 1) string = ""
        Stats struct = struct()
        Options struct = struct()
    end

    %% ------------------------------------------------------------------ prediction / io
    methods
        function [p, raw] = predict(m, F)
            %PREDICT  Calibrated P(Good) of each row of F (N x K), N x 1 in (0, 1), and the raw
            %   score (predictRaw). P is strictly increasing in raw (class help: CALIBRATION).
            raw = m.predictRaw(F);
            p = curation.AssistModel.calibrated(m.IsoX, m.IsoY, raw);
        end

        function r = predictRaw(m, F)
            %PREDICTRAW  The ensemble's (uncalibrated) score for Good, N x 1.
            F = double(F);
            if size(F, 2) ~= numel(m.FeatureNames)
                error('curation:AssistModel:badFeatures', 'F has %d columns; the model needs %d.', ...
                    size(F, 2), numel(m.FeatureNames));
            end
            if isempty(F)
                r = zeros(0, 1);
                return;
            end
            r = curation.AssistModel.forestScore(m.Forest, F);
        end

        function save(m, path)
            %SAVE  Write the model to a .mat file (atomically: temp file + rename).
            path = char(path);
            folder = fileparts(path);
            if ~isempty(folder) && ~isfolder(folder), mkdir(folder); end
            S = struct('Format', m.FORMAT, 'Ensemble', m.Ensemble, 'Forest', m.Forest, ...
                'IsoX', m.IsoX, 'IsoY', m.IsoY, ...
                'FeatureNames', m.FeatureNames, 'Kind', m.Kind, 'Version', m.Version, ...
                'Stats', m.Stats, 'Options', m.Options);
            [~, tok] = fileparts(tempname);
            tmp = [path '.' tok '.tmp.mat'];
            save(tmp, '-struct', 'S', '-v7');
            movefile(tmp, path, 'f');
        end
    end

    methods (Access = private)
        function m = AssistModel()
        end
    end

    %% ------------------------------------------------------------------ fit
    methods (Static)

        function m = load(path)
            %LOAD  Read a model written by save.
            S = load(char(path));
            if ~isfield(S, 'Format') || string(S.Format) ~= curation.AssistModel.FORMAT
                error('curation:AssistModel:badFile', '%s is not an assist model file.', char(path));
            end
            m = curation.AssistModel();
            m.Ensemble = S.Ensemble;
            m.Forest = S.Forest;
            if ~isfield(m.Forest, 'CutCode') && ~isempty(m.Ensemble)
                m.Forest = curation.AssistModel.compileForest(m.Ensemble);
            end
            m.IsoX = S.IsoX;
            m.IsoY = S.IsoY;
            m.FeatureNames = S.FeatureNames;
            m.Kind = S.Kind;
            m.Version = S.Version;
            m.Stats = S.Stats;
            m.Options = S.Options;
        end

        function ok = enoughLabels(y, opts)
            %ENOUGHLABELS  At least opts.MinLabels (200) labels and opts.MinPerClass (30) of each.
            %   y: logical (true = Good) or Label strings ("Good"/"Bad"; others ignored).
            if nargin < 2, opts = struct(); end
            minN = curation.AssistModel.optOr(opts, 'MinLabels', 200);
            minC = curation.AssistModel.optOr(opts, 'MinPerClass', 30);
            if isstring(y) || iscellstr(y) || ischar(y)
                y = string(y);
                g = nnz(y == "Good");
                b = nnz(y == "Bad");
            else
                y = y(:);
                if ~islogical(y), y = y(~isnan(double(y))) ~= 0; end
                g = nnz(y);
                b = nnz(~y);
            end
            ok = (g + b) >= minN && g >= minC && b >= minC;
        end

        function m = fit(F, y, groups, opts)
            %FIT  Fit the ensemble, the grouped cross-validation and the calibration (see help).
            if nargin < 4 || isempty(opts), opts = struct(); end
            t0 = tic;
            o = curation.AssistModel.fillOpts(opts, size(F, 2));
            F = double(F);
            y = logical(y(:));
            n = size(F, 1);
            K = size(F, 2);
            if numel(y) ~= n
                error('curation:AssistModel:badArgument', 'y needs one entry per row of F.');
            end
            if isempty(groups), groups = strings(n, 1); end
            groups = string(groups(:));
            if isscalar(groups), groups = repmat(groups, n, 1); end
            if numel(groups) ~= n
                error('curation:AssistModel:badArgument', 'groups needs one entry per row of F.');
            end
            groups(ismissing(groups)) = "";
            if nnz(y) == 0 || nnz(~y) == 0
                error('curation:AssistModel:oneClass', 'Both Good and Bad labels are needed to fit.');
            end
            sections = o.Sections;
            if ~isempty(sections)
                sections = string(sections(:));
                if numel(sections) ~= n
                    error('curation:AssistModel:badArgument', 'opts.Sections needs one entry per row.');
                end
                sections(ismissing(sections)) = "";
            end
            names = o.FeatureNames;
            if isempty(names) || numel(names) ~= K
                if K == numel(curation.Features.names())
                    names = curation.Features.names();
                else
                    names = "f" + (1:K);
                end
            end
            usePar = curation.AssistModel.parallelWanted(o.UseParallel);

            % ---- grouped folds and out-of-fold scores
            [fold, fi] = curation.AssistModel.makeFolds(y, groups, sections, o.Folds, o.Seed);
            tcv = tic;
            oofRaw = nan(n, 1);
            leafCV = nan(1, fi.K);
            for k = 1:fi.K
                tr = fold ~= k;
                te = fold == k;
                if ~any(te), continue; end
                leafCV(k) = curation.AssistModel.leafSize(nnz(tr), o);
                if nnz(y(tr)) == 0 || nnz(~y(tr)) == 0
                    oofRaw(te) = mean(y(tr));
                    continue;
                end
                ens = curation.AssistModel.trainEnsemble(F(tr, :), y(tr), o.CVTrees, o, o.Seed + k, usePar);
                oofRaw(te) = curation.AssistModel.forestScore(curation.AssistModel.compileForest(ens), F(te, :));
            end
            cvSeconds = toc(tcv);

            % ---- final model
            ens = curation.AssistModel.trainEnsemble(F, y, o.NumTrees, o, o.Seed, usePar);
            forest = curation.AssistModel.compileForest(ens);

            % ---- calibration (every out-of-fold row unless CalibrateOn narrows it)
            cal = true(n, 1);
            calSrc = "all out-of-fold rows";
            calNote = "";
            if ~isempty(o.CalibrateOn)
                cm = logical(o.CalibrateOn(:));
                if numel(cm) ~= n
                    error('curation:AssistModel:badArgument', 'opts.CalibrateOn needs one entry per row.');
                end
                if all(cm)
                    calNote = "CalibrateOn selected every row.";
                elseif nnz(cm) >= o.MinCalibration && any(y(cm)) && any(~y(cm))
                    cal = cm;
                    calSrc = "CalibrateOn rows";
                    calNote = sprintf(['Calibrated on the %d CalibrateOn rows only: valid only if they are a ' ...
                        'random sample of the candidates (never audit, catch or re-ask rows).'], nnz(cm));
                else
                    calSrc = sprintf("all out-of-fold rows (only %d calibration rows given; %d with both classes needed)", ...
                        nnz(cm), o.MinCalibration);
                    calNote = "CalibrateOn rejected: " + calSrc;
                end
            end
            [ix, iy] = curation.AssistModel.isotonicFit(oofRaw(cal), y(cal), [], o.MinTailEvents);
            fl = 0.5 / (nnz(cal) + 1);
            iy = min(max(iy, fl), 1 - fl);
            oofP = curation.AssistModel.calibrated(ix, iy, oofRaw);

            m = curation.AssistModel();
            m.Ensemble = ens;
            m.Forest = forest;
            m.IsoX = ix;
            m.IsoY = iy;
            m.FeatureNames = names;
            m.Kind = string(o.Kind);
            o.CalibrateOn = [];          % do not keep per-row data in Options
            o.Sections = [];
            o.Ids = [];
            m.Options = o;

            % ---- statistics
            S = struct();
            S.N = n;
            S.NGood = nnz(y);
            S.NBad = nnz(~y);
            S.NGroups = numel(unique(groups));
            if isempty(sections), S.NSections = NaN; else, S.NSections = numel(unique(sections)); end
            S.Folds = fi.K;
            S.FoldGrouping = fi.Grouping;
            S.FoldNote = fi.Note;
            S.Fold = fold;
            S.OofRaw = oofRaw;
            S.OofP = oofP;
            S.AUC = curation.AssistModel.auc(oofRaw, y);
            S.AUCCalibrated = curation.AssistModel.auc(oofP, y);
            S.Brier = mean((oofP - y) .^ 2);
            S.Reliability = curation.AssistModel.reliability(oofP, y, 10);
            S.Importance = curation.AssistModel.importance(ens, names);
            S.CalibrationSource = string(calSrc);
            S.CalibrationNote = string(calNote);
            S.CalibrationRows = nnz(cal);
            S.MinTailEvents = o.MinTailEvents;
            % baselines on the same rows
            ir = find(names == "rescore", 1);
            is = find(names == "score", 1);
            resc = nan(n, 1); sc = nan(n, 1);
            if ~isempty(ir), resc = F(:, ir); end
            if ~isempty(is), sc = F(:, is); end
            okR = isfinite(resc);
            S.NRescore = nnz(okR);
            S.AUCRescore = curation.AssistModel.auc(resc(okR), y(okR));
            S.AUCModelOnRescoreRows = curation.AssistModel.auc(oofRaw(okR), y(okR));
            cs = curation.Proposals.coldStart(table(resc, sc, 'VariableNames', {'rescore', 'score'}), ...
                curation.AssistModel.kindKey(o.Kind));
            S.AUCColdStart = curation.AssistModel.auc(cs, y);
            S.BeatsRescore = S.AUCModelOnRescoreRows >= S.AUCRescore;
            S.BeatsColdStart = S.AUC >= S.AUCColdStart;
            S.TreesFinal = o.NumTrees;
            S.TreesCV = o.CVTrees;
            S.MinLeafSize = curation.AssistModel.leafSize(n, o);
            S.MinLeafSizeCV = leafCV;
            S.Parallel = usePar;
            S.Seed = o.Seed;
            S.Kind = string(o.Kind);
            if isempty(opts) || ~isfield(opts, 'Ids') || isempty(opts.Ids)
                S.Ids = strings(0, 1);
                idHash = curation.Hash.of(F, y);
            else
                S.Ids = string(opts.Ids(:));
                idHash = curation.Hash.of(S.Ids, y);
            end
            S.CVSeconds = cvSeconds;
            S.FitSeconds = toc(t0);
            S.Version = string(datetime('now', 'Format', 'yyyyMMdd''T''HHmmssSSS')) + "-" + extractBefore(idHash, 9);
            m.Version = S.Version;
            m.Stats = S;
        end

        %% -------------------------------------------------------------- label policy
        function mask = trainingMask(T)
            %TRAININGMASK  Rows that train the model (see the class help: TRAINING-LABEL POLICY).
            n = height(T);
            st = curation.AssistModel.textCol(T, 'State', "active", n);
            rev = curation.AssistModel.logicalCol(T, 'Reviewed', n);
            lab = curation.AssistModel.textCol(T, 'Label', "", n);
            src = curation.AssistModel.textCol(T, 'LabelSource', "", n);
            exc = curation.AssistModel.logicalCol(T, 'Excluded', n);
            role = curation.AssistModel.textCol(T, 'AuditRole', "", n);
            mask = st == "active" & rev & (lab == "Good" | lab == "Bad") ...
                & ismember(src, curation.AssistModel.KEEP_SOURCES) & ~exc ...
                & ~ismember(role, curation.AssistModel.NO_TRAIN_ROLES);
        end

        function mask = blindMask(T)
            %BLINDMASK  LabelSource "blind" or AuditRole holdout/reject-audit/confirm-audit/catch.
            n = height(T);
            src = curation.AssistModel.textCol(T, 'LabelSource', "", n);
            role = curation.AssistModel.textCol(T, 'AuditRole', "", n);
            mask = src == "blind" | ismember(role, curation.AssistModel.BLIND_ROLES);
        end

        %% -------------------------------------------------------------- isotonic regression
        function yhat = pav(y, w)
            %PAV  Pool-adjacent-violators: the non-decreasing sequence closest to y in weighted
            %   least squares (y already ordered by x; w default 1). Ties in y stay separate.
            y = double(y(:));
            n = numel(y);
            if nargin < 2 || isempty(w), w = ones(n, 1); end
            w = double(w(:));
            val = zeros(n, 1); wt = zeros(n, 1); len = zeros(n, 1);
            top = 0;
            for i = 1:n
                top = top + 1;
                val(top) = y(i); wt(top) = w(i); len(top) = 1;
                while top > 1 && val(top - 1) > val(top)
                    nw = wt(top - 1) + wt(top);
                    val(top - 1) = (val(top - 1) * wt(top - 1) + val(top) * wt(top)) / nw;
                    wt(top - 1) = nw;
                    len(top - 1) = len(top - 1) + len(top);
                    top = top - 1;
                end
            end
            yhat = reshape(repelem(val(1:top), len(1:top)), [], 1);
        end

        function [xk, yk] = isotonicFit(x, y, w, minTail)
            %ISOTONICFIT  Knots of the isotonic regression of y (0/1 or any value) on x.
            %   Rows with equal x are pooled first (weighted mean), then PAV; interior knots of
            %   flat runs are dropped (only each run's first and last x are kept). Non-finite x
            %   rows are ignored. No usable rows -> one knot (0, 0.5).
            %   minTail (default 0 = plain PAV): the lowest block is pooled with the next until
            %   it holds a weighted sum of y of at least minTail (Good rows), the highest until it
            %   holds at least minTail of (1 - y) (Bad rows); pooling two adjacent PAV blocks
            %   keeps the map monotone.
            x = double(x(:));
            y = double(y(:));
            if nargin < 3 || isempty(w), w = ones(size(x)); end
            if nargin < 4 || isempty(minTail), minTail = 0; end
            w = double(w(:));
            ok = isfinite(x) & isfinite(y) & w > 0;
            x = x(ok); y = y(ok); w = w(ok);
            if isempty(x)
                xk = 0; yk = 0.5;
                return;
            end
            [ux, ~, g] = unique(x);
            ww = accumarray(g, w);
            yy = accumarray(g, y .* w) ./ ww;
            yh = curation.AssistModel.pav(yy, ww);
            if minTail > 0 && numel(ux) > 1
                yh = curation.AssistModel.poolTails(yh, yy, ww, minTail);
            end
            nk = numel(ux);
            keep = true(nk, 1);
            if nk > 2
                same = yh(2:end - 1) == yh(1:end - 2) & yh(2:end - 1) == yh(3:end);
                keep(2:end - 1) = ~same;
            end
            xk = ux(keep);
            yk = yh(keep);
        end

        function p = calibrated(xk, yk, raw)
            %CALIBRATED  The isotonic map plus the order-keeping ramp (class help: CALIBRATION),
            %   kept in [0, 1]: what predict returns for raw scores RAW.
            raw = double(raw(:));
            p = curation.AssistModel.isotonicApply(xk, yk, raw) + curation.AssistModel.ORDER_RAMP * (raw - 0.5);
            p = min(max(p, 0), 1);
        end

        function yh = poolTails(yh, yy, ww, minTail)
            %POOLTAILS  Pool the extreme PAV blocks (runs of equal yh): the lowest with the next
            %   while it holds sum(w * y) < minTail (Good rows) and the next block's value is below
            %   TAIL_BANDS(1) (0.15); the highest with the one before while it holds
            %   sum(w * (1 - y)) < minTail (Bad rows) and that block's value is above TAIL_BANDS(2)
            %   (0.85). So the tail fix stays inside the likely-bad / likely-good bands of the review
            %   queue and never merges across a sharp boundary (perfectly separated classes). An
            %   extreme block left with fewer than minTail events takes the Jeffreys estimate
            %   (k + 0.5) / (n + 1) instead of its raw mean, never exactly 0 or 1. Both keep the
            %   map monotone.
            n = numel(yh);
            brk = [true; diff(yh) ~= 0];
            bid = cumsum(brk);
            nb = bid(end);
            bw = accumarray(bid, ww, [nb 1]);
            bs = accumarray(bid, yy .* ww, [nb 1]);
            lo = 1;
            lim = curation.AssistModel.TAIL_BANDS;
            while lo < nb && bs(lo) < minTail
                if bs(lo + 1) / bw(lo + 1) >= lim(1), break; end
                bw(lo + 1) = bw(lo + 1) + bw(lo);
                bs(lo + 1) = bs(lo + 1) + bs(lo);
                bid(bid == lo) = lo + 1;
                lo = lo + 1;
            end
            hi = nb;
            while hi > lo && (bw(hi) - bs(hi)) < minTail
                if bs(hi - 1) / bw(hi - 1) <= lim(2), break; end
                bw(hi - 1) = bw(hi - 1) + bw(hi);
                bs(hi - 1) = bs(hi - 1) + bs(hi);
                bid(bid == hi) = hi - 1;
                hi = hi - 1;
            end
            v = bs ./ bw;
            if bs(lo) < minTail
                v(lo) = (bs(lo) + 0.5) / (bw(lo) + 1);
            end
            if hi ~= lo && (bw(hi) - bs(hi)) < minTail
                v(hi) = (bs(hi) + 0.5) / (bw(hi) + 1);
            end
            yh = reshape(v(bid), n, 1);
        end

        function p = isotonicApply(xk, yk, x)
            %ISOTONICAPPLY  Evaluate the isotonic map: linear between knots, clamped to the first
            %   / last knot's value outside them, and to [0, 1]. NaN x -> NaN.
            x = double(x(:));
            xk = double(xk(:));
            yk = double(yk(:));
            if isscalar(xk)
                p = repmat(yk, size(x));
            else
                xc = min(max(x, xk(1)), xk(end));
                p = interp1(xk, yk, xc, 'linear');
            end
            p = min(max(p, 0), 1);
            p(isnan(x)) = NaN;
        end

        %% -------------------------------------------------------------- metrics
        function a = auc(score, y)
            %AUC  Area under the ROC curve (Mann-Whitney, ties count one half). NaN rows ignored;
            %   NaN when either class is absent.
            score = double(score(:));
            yd = double(y(:));
            ok = isfinite(score) & ~isnan(yd);
            s = score(ok);
            yy = yd(ok) ~= 0;
            nP = nnz(yy);
            nN = nnz(~yy);
            if nP == 0 || nN == 0
                a = NaN;
                return;
            end
            r = tiedrank(s);
            a = (sum(r(yy)) - nP * (nP + 1) / 2) / (nP * nN);
        end

        function R = reliability(p, y, nBins)
            %RELIABILITY  Table Bin, Lo, Hi, MeanPredicted, Observed, Count over equal-width bins.
            if nargin < 3, nBins = 10; end
            p = double(p(:));
            y = double(y(:));
            ok = isfinite(p) & ~isnan(y);
            p = p(ok); y = y(ok);
            b = min(floor(p * nBins) + 1, nBins);
            b = max(b, 1);
            Count = accumarray(b, 1, [nBins 1]);
            MeanPredicted = accumarray(b, p, [nBins 1]) ./ Count;
            Observed = accumarray(b, y, [nBins 1]) ./ Count;
            Bin = (1:nBins)';
            Lo = (Bin - 1) / nBins;
            Hi = Bin / nBins;
            R = table(Bin, Lo, Hi, MeanPredicted, Observed, Count);
        end

        function [fold, info] = makeFolds(y, groups, sections, K, seed)
            %MAKEFOLDS  Fold index per row. Rows of one group always share a fold.
            %   Groups (animals) when there are at least K of them; else sections (when given and
            %   at least K); else the larger of the two with K reduced to its count (>= 2); else
            %   stratified random folds of rows. info: K, Grouping, Note.
            n = numel(y);
            groups = string(groups(:));
            nG = numel(unique(groups));
            nS = 0;
            if nargin >= 3 && ~isempty(sections)
                sections = string(sections(:));
                nS = numel(unique(sections));
            end
            info = struct('K', K, 'Grouping', "groups", 'Note', "");
            if nG >= K
                key = groups;
                info.Note = sprintf("%d folds grouped by animal (%d animals).", K, nG);
            elseif nS >= K
                key = sections;
                info.Grouping = "sections";
                info.Note = sprintf("Only %d animal(s) for %d folds: folds grouped by section (%d sections) instead.", nG, K, nS);
            elseif max(nG, nS) >= 2
                if nS > nG
                    key = sections;
                    info.Grouping = "sections";
                    info.K = nS;
                    info.Note = sprintf("Only %d animal(s) and %d section(s): %d folds grouped by section.", nG, nS, nS);
                else
                    key = groups;
                    info.K = nG;
                    info.Note = sprintf("Only %d animal(s): %d folds grouped by animal.", nG, nG);
                end
            else
                info.Grouping = "rows";
                info.Note = sprintf("Only one animal and one section: %d stratified folds of rows (NOT grouped; the out-of-fold scores are optimistic).", K);
                rs = RandStream('mt19937ar', 'Seed', seed);
                fold = zeros(n, 1);
                for cls = [false true]
                    idx = find(logical(y(:)) == cls);
                    idx = idx(randperm(rs, numel(idx)));
                    fold(idx) = mod(0:numel(idx) - 1, K)' + 1;
                end
                return;
            end
            fold = curation.AssistModel.assignGroups(key, info.K, seed);
        end

        function Z = compileForest(ens)
            %COMPILEFOREST  The trees of a bagged ensemble as flat node arrays, for forestScore.
            %   Z: Roots (T x 1), IsBranch, CutVar, Cut, Left, Right, Prob (P(Good) of every node).
            tr = ens.Trained;
            nT = numel(tr);
            cnt = cellfun(@(t) size(t.Children, 1), tr(:));
            offs = [0; cumsum(cnt)];
            P = offs(end);
            Z = struct('Roots', offs(1:end - 1) + 1, 'IsBranch', false(P, 1), 'CutVar', zeros(P, 1), ...
                'Cut', nan(P, 1), 'Left', zeros(P, 1), 'Right', zeros(P, 1), 'Prob', zeros(P, 1));
            col = find(logical(ens.ClassNames) == true, 1);
            for t = 1:nT
                idx = offs(t) + (1:cnt(t))';
                b = tr{t}.IsBranchNode(:);
                ch = tr{t}.Children;
                Z.IsBranch(idx) = b;
                cv = double(tr{t}.CutPredictorIndex(:));
                cv(~b) = 1;
                Z.CutVar(idx) = cv;
                Z.Cut(idx) = tr{t}.CutPoint(:);
                Z.Left(idx(b)) = ch(b, 1) + offs(t);
                Z.Right(idx(b)) = ch(b, 2) + offs(t);
                Z.Prob(idx) = tr{t}.ClassProbability(:, col);
            end
            % child(2n-1) = left, child(2n) = right; ChildLeaf says whether that child is a leaf
            Z.Child = uint32(reshape([Z.Left Z.Right]', 2 * P, 1));
            Z.ChildLeaf = false(2 * P, 1);
            hasC = Z.Child > 0;
            Z.ChildLeaf(hasC) = ~Z.IsBranch(Z.Child(hasC));
            % integer codes: per feature, the sorted cut points of the whole forest; a value x
            % gets code 1 + #(cuts <= x) (0 for NaN), a node with the j-th cut gets j + 1, and
            % x < cut  <=>  code(x) < CutCode(node), exactly
            K = numel(ens.PredictorNames);
            Z.FeatCuts = cell(1, K);
            Z.CutCode = zeros(P, 1);
            for f = 1:K
                at = Z.IsBranch & Z.CutVar == f;
                cuts = unique(Z.Cut(at));
                Z.FeatCuts{f} = cuts;
                [~, j] = ismember(Z.Cut(at), cuts);
                Z.CutCode(at) = j + 1;
            end
            if max([Z.CutCode; cellfun(@numel, Z.FeatCuts)' + 1]) < 65535
                Z.CutCode = uint16(Z.CutCode);
            else
                Z.CutCode = uint32(Z.CutCode);
            end
        end

        function C = featureCodes(Z, F)
            %FEATURECODES  Integer code of every value of F against the forest's cut points.
            [N, K] = size(F);
            C = zeros(N, K, 'like', Z.CutCode);
            for f = 1:K
                b = discretize(F(:, f), [-Inf; Z.FeatCuts{f}(:); Inf]);
                b(isnan(b)) = 0;                    % NaN
                C(:, f) = b;
            end
        end

        function s = forestScore(Z, F, chunkEntries)
            %FORESTSCORE  Mean over trees of P(Good) at the node each row reaches: all rows and
            %   trees are routed together, one tree level per step (x < cut -> left, x >= cut ->
            %   right, NaN stops at that node and takes its probability, as the trees' predict).
            %   Rows go in chunks of about chunkEntries (row, tree) pairs (default 2^16), so the
            %   per-level temporaries stay in the processor cache.
            if nargin < 3 || isempty(chunkEntries), chunkEntries = 2 ^ 16; end
            N = size(F, 1);
            if N == 0
                s = zeros(0, 1);
                return;
            end
            nT = numel(Z.Roots);
            C = curation.AssistModel.featureCodes(Z, F);
            step = max(1, floor(chunkEntries / nT));
            if step >= N
                s = curation.AssistModel.forestChunk(Z, C);
                return;
            end
            s = zeros(N, 1);
            for r0 = 1:step:N
                r = r0:min(N, r0 + step - 1);
                s(r) = curation.AssistModel.forestChunk(Z, C(r, :));
            end
        end

        function s = forestChunk(Z, C)
            %FORESTCHUNK  forestScore for one chunk of rows, from their feature codes C.
            N = size(C, 1);
            C = C(:);       % linear: C(row + colOff) is a column whatever N (a one-row C indexed
                            % with a column gave a row vector, which implicit expansion then made
                            % N x N: the one-row-chunk crash)
            nT = numel(Z.Roots);
            % uint32 node and row indices, 2-byte codes: little memory traffic per level
            child = Z.Child;
            childLeaf = Z.ChildLeaf;
            colOff = uint32((Z.CutVar - 1) * N);
            prob = Z.Prob;
            cut = Z.CutCode;
            s = zeros(N, 1);
            rootLeaf = ~Z.IsBranch(Z.Roots);
            if any(rootLeaf)
                s = s + sum(prob(Z.Roots(rootLeaf)));
            end
            roots = uint32(Z.Roots(~rootLeaf));
            % entries (row, tree) still travelling: row and current node
            nd = reshape(repmat(roots', N, 1), [], 1);
            row = repmat(uint32(1:N)', numel(roots), 1);
            while ~isempty(nd)
                v = C(row + colOff(nd));
                k = 2 * nd - uint32(v < cut(nd));
                stopL = childLeaf(k);
                nd2 = child(k);
                isn = v == 0;                           % NaN stops at the current node
                anyN = any(isn);
                if anyN
                    stopL(isn) = false;
                    s = s + accumarray(double(row(isn)), prob(nd(isn)), [N 1]);
                end
                anyL = any(stopL);
                if anyL
                    s = s + accumarray(double(row(stopL)), prob(nd2(stopL)), [N 1]);
                end
                if anyN || anyL
                    keep = ~(stopL | isn);
                    nd = nd2(keep);
                    row = row(keep);
                else
                    nd = nd2;
                end
            end
            s = s / nT;
        end

        function fold = assignGroups(key, K, seed)
            %ASSIGNGROUPS  Groups to K folds: groups shuffled (seeded), then largest first to the
            %   fold with the fewest rows so far (balanced sizes; a group is never split).
            [ug, ~, gi] = unique(string(key(:)));
            cnt = accumarray(gi, 1);
            rs = RandStream('mt19937ar', 'Seed', seed);
            perm = randperm(rs, numel(ug));
            [~, o] = sort(cnt(perm), 'descend');
            order = perm(o);
            rowsIn = zeros(K, 1);
            gf = zeros(numel(ug), 1);
            for g = order(:)'
                [~, k] = min(rowsIn);
                gf(g) = k;
                rowsIn(k) = rowsIn(k) + cnt(g);
            end
            fold = gf(gi);
        end
    end

    %% ------------------------------------------------------------------ helpers
    methods (Static, Access = private)

        function o = fillOpts(opts, K)
            d = struct('Seed', 1, 'NumTrees', 200, 'CVTrees', 40, 'Folds', 5, 'MinLeafSize', [], ...
                'NumVariablesToSample', max(1, ceil(sqrt(K))), 'NumBins', 32, 'FResample', 0.5, ...
                'Reproducible', true, 'Sections', [], ...
                'CalibrateOn', [], 'MinCalibration', 100, 'MinTailEvents', 10, 'FeatureNames', strings(1, 0), ...
                'Kind', "", 'Ids', [], 'UseParallel', "auto");
            o = d;
            if isstruct(opts)
                f = fieldnames(opts);
                for i = 1:numel(f)
                    o.(f{i}) = opts.(f{i});
                end
            end
            o.FeatureNames = string(o.FeatureNames);
            o.Kind = string(o.Kind);
        end

        function v = optOr(s, name, d)
            v = d;
            if isstruct(s) && isfield(s, name) && ~isempty(s.(name)), v = s.(name); end
        end

        function tf = parallelWanted(u)
            if islogical(u) || isnumeric(u)
                tf = logical(u);
                return;
            end
            try
                tf = ~isempty(gcp('nocreate'));
            catch
                tf = false;
            end
        end

        function leaf = leafSize(n, o)
            %LEAFSIZE  The trees' minimum leaf size for an ensemble grown on N rows: opts.MinLeafSize
            %   when given; else one fiftieth of the rows each tree grows on (FResample * N), between
            %   5 and 40. A fixed 40 on half-size bags let no tree of a fold with fewer than ~160
            %   rows split (out-of-fold AUC 0.49 and P nearly constant at the 200-label gate).
            if ~isempty(o.MinLeafSize) && isfinite(o.MinLeafSize)
                leaf = double(o.MinLeafSize);
                return
            end
            bag = max(1, double(o.FResample) * n);
            leaf = min(40, max(5, round(bag / 50)));
        end

        function ens = trainEnsemble(F, y, nTrees, o, seed, usePar)
            t = templateTree('MinLeafSize', curation.AssistModel.leafSize(size(F, 1), o), ...
                'NumVariablesToSample', min(o.NumVariablesToSample, size(F, 2)), ...
                'Reproducible', logical(o.Reproducible));
            args = {'Method', 'Bag', 'NumLearningCycles', nTrees, 'Learners', t, ...
                'Prior', 'uniform', 'ClassNames', [false; true], 'FResample', o.FResample};
            if ~isempty(o.NumBins)
                args = [args, {'NumBins', o.NumBins}];
            end
            if usePar
                st = statset('UseParallel', true, 'UseSubstreams', true, ...
                    'Streams', RandStream('mlfg6331_64', 'Seed', seed));
                args = [args, {'Options', st}];
                ens = compact(fitcensemble(F, y, args{:}));
            else
                old = rng();
                restore = onCleanup(@() rng(old));
                rng(seed, 'twister');
                ens = compact(fitcensemble(F, y, args{:}));
            end
        end

        function r = rawScore(ens, F)
            % Score for Good by MATLAB's predict (reference for curation.AssistModel.forestScore).
            [~, sc] = predict(ens, F);
            r = sc(:, 2);
        end

        function T = importance(ens, names)
            try
                imp = predictorImportance(ens);
                imp = imp(:);
                s = sum(imp);
                if s > 0, imp = imp / s; end
            catch
                imp = nan(numel(names), 1);
            end
            T = table(names(:), imp, 'VariableNames', {'Name', 'Importance'});
            T = sortrows(T, 'Importance', 'descend');
        end

        function key = kindKey(kind)
            switch lower(string(kind))
                case "pnn", key = "PNN1";
                case "pv",  key = "PV1";
                otherwise,  key = "unknown";
            end
        end

        function v = textCol(T, name, d, n)
            if ismember(name, T.Properties.VariableNames)
                v = string(T.(name)(:));
                v(ismissing(v)) = "";
            else
                v = repmat(string(d), n, 1);
            end
        end

        function v = logicalCol(T, name, n)
            if ismember(name, T.Properties.VariableNames)
                x = T.(name)(:);
                if islogical(x)
                    v = x;
                elseif isnumeric(x)
                    v = x ~= 0 & ~isnan(x);
                else
                    s = lower(strtrim(string(x)));
                    v = s == "1" | s == "true";
                end
            else
                v = false(n, 1);
            end
        end
    end
end
