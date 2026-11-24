classdef Audit
%AUDIT  Blind audits and the quality report: how consistent the bulk confirmation is, how
%   accurate the assist model is on blind holdout labels, who reviewed what where (static; pure
%   data in, data out). Also holds the EXPERIMENTAL auto-reject functions, which CellCurator does
%   not use (see AUTO-REJECT below).
%
%   r   = curation.Audit.report(index, opts)            per channel kind: r.Table + r.Kinds
%   txt = curation.Audit.reportText(r)                  plain-language paragraph per kind
%   n   = curation.Audit.confirmAuditSize(halfWidth, rate, opts)   confirm-audit tiles needed
%   [a, V] = curation.Audit.aucDeLong(S, y)              AUCs of the columns of S and their covariance
%   mask = curation.Audit.exportExclusionMask(T)         rows no model may ever train on
%   mask = curation.Audit.evidenceMask(T)                random blind-labelled rows
%   E = curation.Audit.evidence(index, kind, model)      P of the random blind rows and candidates
%   E = curation.Audit.evidence(T, F, model)
%   ids = curation.Audit.sampleHoldout(index, kind, opts)
%   ids = curation.Audit.sampleConfirmAudit(T, opts)
%   ci = curation.Audit.binomialInterval(k, n, conf, method)   two-sided, [lo hi] per element
%   u  = curation.Audit.upperBound(k, n, conf, method)         one-sided upper bound
%   l  = curation.Audit.lowerBound(k, n, conf, method)         one-sided lower bound
%   EXPERIMENTAL, not used by CellCurator:
%   [tau, info] = curation.Audit.rejectThreshold(p, isGood, isBlind, sections, opts)
%   mask = curation.Audit.autoRejectMask(T, p, tau)
%   ids = curation.Audit.sampleRejectAudit(T, opts)
%   [suspend, stats] = curation.Audit.checkSuspend(nAudited, nGoodFound, opts)
%
%   =============================================================================================
%   WHAT THE BLIND TILES MEASURE
%   CellCurator shows every candidate to a person; the assist model only orders the review and
%   proposes a label per page. Blind tiles (neutral border, no proposal, an explicit key needed;
%   see curation.Queues) measure two things:
%     - the REVIEWER: confirm-audit tiles are tiles first confirmed by the page default (Enter)
%       and later shown again blind. The share whose blind label differs from the label they were
%       confirmed with measures what bulk confirmation lets through, separately for Bad-default
%       pages (cells left Bad) and Good-default pages (non-cells kept), and per band: that is the
%       measure of automation bias. Catch tiles (known non-cells shown blind) are attention
%       checks. Neither is a random sample of the candidates: they measure the reviewer only.
%     - the MODEL: holdout tiles are a random sample of the candidates (sampleHoldout), never
%       trained on, judged blind. Model accuracy (AUC, calibration) is computed from them only,
%       against the raw rescore baseline. Labels given with a proposal visible (confirmed, human)
%       are never used for any accuracy number: a model that the reviewer followed would look
%       perfect against them.
%   Rows that may never train any model (holdout, reject-audit, catch): exportExclusionMask.
%   The GUI writes a blind tile's decision with LabelSource "blind"; a catch tile's answer is
%   recorded for the report and must never overwrite its known label (a failed catch tile is
%   not a cell; curation.AssistModel.trainingMask never trains on catch tiles).
%
%   AUTO-REJECT (EXPERIMENTAL; not used by CellCurator). rejectThreshold, autoRejectMask,
%   sampleRejectAudit and checkSuspend implement rejecting candidates below a P threshold unseen,
%   justified by blind tiles. They are kept for study only. The pooled bound does not control
%   losses per section or per experimental group: an independent simulation found a median 3%
%   and up to 28% of a section's cells lost, and a 1-2% vs 0.04-0.16% difference in cells lost
%   between a group whose cells were dimmer and the controls, i.e. auto-reject can bias a
%   treatment comparison directly. Counts that go into a paper must not come from it.
%   The guarantee it would give, IF the blind rows are a random sample of the candidates and
%   each was scored by a model that never trained on it (holdout and reject-audit tiles; never
%   confirm-audit, catch or re-ask tiles): with the stated confidence at most MaxMissRate of the
%   candidates below tau are real cells (clustered or binomial bound), and an estimated (point
%   estimate, NOT a bound) at most MaxGoodLost of all real cells fall below it. Not covered:
%   cells the detector never proposed, errors in the blind labels, later changes of the model or
%   the data, and any single section or group. The clustered bound has no degrees-of-freedom
%   correction, and its design effect is 1 when no cell lies below tau (the usual case), where it
%   cannot be estimated. With no Good among them, ceil(log(0.05) / log(0.99)) = 299 blind rows
%   below the threshold are needed before a 1% bound at 95% can be met at all.
%
%   rejectThreshold(p, isGood, isBlind, sections, opts)   (EXPERIMENTAL)
%     p         N x 1 P(Good): for blind rows out-of-fold or from a model that never trained on
%               them. Rows with finite p are the population. NaN for rows that are neither.
%     isGood    N x 1: logical or double with NaN for unlabelled rows (Uncertain counts as Good)
%     isBlind   N x 1 logical: the random blind evidence (evidenceMask)
%     sections  N x 1 string (the clusters)
%     opts      MinLabels 1500, MinSections 8, MinBlind 200, MaxMissRate 0.01, MaxGoodLost 0.01,
%               Confidence 0.95, Bound "clustered" | "binomial", Weighting "poststrat" | "none"
%               (or Weights), MinBlindPerBin 10, Bootstrap 1000, Seed 1, Labelled
%     Gates: labels/sections, blind rows, at least one Good among the blind rows (else the share
%     lost cannot be estimated and tau is NaN), at least two bins. Thresholds are the lower edges
%     of bins of consecutive blind P values (>= MinBlindPerBin rows each, ties never split): never
%     above the largest blind P. tau is the largest threshold with the upper bound on
%     P(Good | P < tau) <= MaxMissRate and the estimated share of Good below tau <= MaxGoodLost.
%     info: Tau Reason Gate NumLabels NumLabelSections NumBlind NBelow GoodBelow MissRate
%     UpperBound UpperBinomial UpperClustered NEff Deff GoodLost FracRejected NRejected Curve
%     Bound Weighting Confidence MaxMissRate MaxGoodLost Guarantee
%
%   SAMPLING (deterministic given opts.Seed; rows that carry an AuditRole are never returned)
%     sampleHoldout(index, kind, opts): opts.Target 400 per kind, N (default Target minus the
%       holdout rows the kind already has), Seed 1, Strata 10. Eligible: active, not reviewed,
%       no audit role, not excluded (so never trained on). Stratified by score decile pooled
%       across sections (equal-size strata by rank; NaN score is an 11th stratum) with
%       PROPORTIONAL allocation, so the holdout is self-weighting; within a stratum rows are
%       ordered by section and drawn systematically from a random start. Returns a table
%       (SourceId, Section, SourceKey, CellID, score, Stratum; plus Folder/Base when present).
%     sampleConfirmAudit(T, opts): per source, ceil(Fraction 2%) of the rows confirmed in bulk
%       (LabelSource confirmed), counting rows already audited; uniform within the source (so the
%       pooled audit is self-weighting across sources). The size the report needs:
%       confirmAuditSize.
%     sampleRejectAudit(T, opts): EXPERIMENTAL (see its help).
%     Both return uint32 CellIDs for a one-source table; for several sources a table SourceId,
%     CellID. Each source has its own random stream (seed and source id), so the source must be
%     named: a SourceId column, Section + SourceKey, or opts.SourceId for a one-source table;
%     otherwise curation:Audit:noSourceId (a table without it gave every source the same rows).
%
%   report(index, opts): index is a curation.ProjectIndex or a table like index.table(kind)
%     with a Kind (or SourceKey) column. opts: MinHoldoutPerClass 10 (blind holdout labels of
%     each class before model accuracy is reported), Bands [0.15 0.5 0.85] (as the review
%     queue), TargetHalfWidth 0.02 and AssumedRate 0.05 (confirmAuditSize in the report),
%     Confidence 0.95. Per kind (r.Table: one row per kind, writetable-ready; r.Kinds: the same
%     plus the tables Reviewers, BySection, ConfirmByBand):
%     COUNTS  Sources Sections Candidates (active rows) Reviewed Kept Good Bad Uncertain
%       Confirmed (bulk, LabelSource confirmed) HumanDecided (one by one: human, blind, legacy)
%       Blind (of those, decided blind) AutoRejected ToReview.
%     REVIEWER CONSISTENCY (confirm audit; blind labels only)  ConfirmAuditN (judged blind, with
%       the label they were confirmed with known: PriorLabel, recovered from the journal by
%       curation.ProjectIndex), ConfirmAuditDisagree (blind label differs), ConfirmAuditRate/Lo/Hi
%       (95% Clopper-Pearson), ConfirmAuditPending (not judged blind yet), ConfirmAuditUnknown
%       (earlier label not recoverable; left out); the same split by the default they were
%       confirmed under: ConfirmGoodDefaultN/Changed/Rate/Lo/Hi and ConfirmBadDefault...;
%       ConfirmedGoodUnaudited / ConfirmedBadUnaudited (rows still carrying a bulk-confirmed
%       label) and the estimated errors among them: EstCellsLeftBad (+Lo/Hi) = Bad-default change
%       rate x ConfirmedBadUnaudited, EstNonCellsKeptGood (+Lo/Hi) likewise; ConfirmGoodDefault-
%       Needed / ConfirmBadDefaultNeeded: confirm-audit tiles judged blind that the change rate's
%       interval needs for TargetHalfWidth (at the observed rate once 30 tiles of that default
%       were judged blind, at AssumedRate before). Table
%       ConfirmByBand: Band (from the P shown when it was confirmed: PriorProposalP, else
%       ProposalP), Default, N, Changed, Rate, Lo, Hi. Catch tiles: CatchN, CatchHits (labelled
%       Bad), CatchHitRate.
%     MODEL ACCURACY (holdout; blind labels Good/Bad only)  HoldoutN, HoldoutGood, HoldoutPending,
%       HoldoutAUCModel (ModelP) and HoldoutAUCRescore (raw rescore) with 95% DeLong intervals
%       (Lo/Hi), HoldoutAUCDiff (model - rescore, paired, rows with both) with its interval,
%       HoldoutMeanP vs HoldoutObservedGood (calibration in the large), HoldoutBrier,
%       HoldoutAgree (share where the proposal, P >= 0.5, equals the blind label),
%       HoldoutModelVersions, HoldoutNote (why a number is NaN). Fewer than MinHoldoutPerClass
%       blind labels of either class -> NaN with the counts in HoldoutNote.
%     PER REVIEWER / PER SECTION  ReviewerCounts (text); table Reviewers (Reviewer, Reviewed,
%       Good, Bad, Uncertain, Confirmed, HumanDecided, Blind); table BySection (Section, Sources,
%       Candidates, Reviewed, Good, Bad, Uncertain, Confirmed, HumanDecided, Blind, ToReview,
%       HoldoutN, HoldoutPending, ConfirmAuditN, ConfirmAuditChanged, AutoRejected).
%     EXPERIMENTAL AUTO-REJECT AUDIT (blind labels only)  RejectAuditN, RejectAuditPending,
%       RejectAuditGood, RejectAuditRate/Lo/Hi, RejectAuditUpper95, EstCellsLost(Upper).
%
%   See also curation.AssistModel, curation.ProjectIndex, curation.Queues, curation.Store.

    properties (Constant)
        PERSON_SOURCES = ["human", "confirmed", "blind", "legacy-qc", "legacy-resolver"]
        KEEP_SOURCES = ["human", "confirmed", "blind", "legacy-qc"]
        % random samples of the candidates (admissible evidence); confirm-audit, catch tiles and
        % blind re-asks are chosen by label or by disagreement and measure the reviewer only
        RANDOM_ROLES = ["holdout" "reject-audit"]
        % rows no model may ever train on (blind evidence and attention checks)
        EXCLUDE_ROLES = ["holdout" "reject-audit" "catch"]
        BANDS = ["bad" "middle-low" "middle-high" "good"]
        GUARANTEE = "EXPERIMENTAL, not used by CellCurator. If the blind tiles are a random sample of the candidates and each was scored by a model that never trained on it, then with the stated confidence at most MaxMissRate of the candidates below the threshold are real cells, and an estimated (not bounded) at most MaxGoodLost of all real cells fall below it. It says nothing about any single section or experimental group (a simulation found up to 28% of a section's cells lost and a dimmer-cell group losing 1-2% against 0.04-0.16% in controls), nor about cells the detector never proposed, errors in the blind labels, or later changes of the model or the data."
    end

    %% =================================================================== threshold
    methods (Static)

        function [tau, info] = rejectThreshold(p, isGood, isBlind, sections, opts)
            %REJECTTHRESHOLD  Auto-reject threshold with its bound (see the class help).
            %   EXPERIMENTAL: not used by CellCurator. The pooled bound does not control losses
            %   per section or per experimental group (an independent simulation found a median 3%
            %   and up to 28% of a section's cells lost, and a 1-2% vs 0.04-0.16% difference
            %   between a dimmer-cell group and controls). tau is NaN with info.Reason when no
            %   blind tile is a cell (nothing bounds the share lost) and is never above the largest
            %   blind P.
            if nargin < 5 || isempty(opts), opts = struct(); end
            o = curation.Audit.fill(opts, struct('MinLabels', 1500, 'MinSections', 8, 'MinBlind', 200, ...
                'MaxMissRate', 0.01, 'MaxGoodLost', 0.01, 'Confidence', 0.95, 'Bound', "clustered", ...
                'Weighting', "poststrat", 'Weights', [], 'MinBlindPerBin', 10, 'Bootstrap', 1000, ...
                'Seed', 1, 'Labelled', []));
            p = double(p(:));
            n = numel(p);
            if islogical(isGood)
                g = double(isGood(:));
                labelled = true(n, 1);
            else
                g = double(isGood(:));
                labelled = ~isnan(g);
            end
            if ~isempty(o.Labelled), labelled = logical(o.Labelled(:)); end
            isBlind = logical(isBlind(:));
            sections = string(sections(:));
            if isscalar(sections), sections = repmat(sections, n, 1); end
            if numel(g) ~= n || numel(isBlind) ~= n || numel(sections) ~= n || numel(labelled) ~= n
                error('curation:Audit:badArgument', 'p, isGood, isBlind and sections need one entry per row.');
            end
            sections(ismissing(sections)) = "";
            conf = o.Confidence;

            info = curation.Audit.emptyInfo(o);
            info.NumLabels = nnz(labelled);
            info.NumLabelSections = numel(unique(sections(labelled)));
            ev = isBlind & labelled & isfinite(p) & ~isnan(g);
            info.NumBlind = nnz(ev);
            tau = NaN;

            % ---- gates
            reasons = strings(0, 1);
            gate = strings(0, 1);
            if info.NumLabels < o.MinLabels || info.NumLabelSections < o.MinSections
                reasons(end + 1) = sprintf("Auto-reject needs %s labels from %d sections; you have %s from %d.", ...
                    curation.Audit.fmtInt(o.MinLabels), o.MinSections, curation.Audit.fmtInt(info.NumLabels), ...
                    info.NumLabelSections);
                gate(end + 1) = "labels";
            end
            if info.NumBlind < o.MinBlind
                reasons(end + 1) = sprintf("Auto-reject needs %s blind labels; you have %s.", ...
                    curation.Audit.fmtInt(o.MinBlind), curation.Audit.fmtInt(info.NumBlind));
                gate(end + 1) = "blind";
            end
            if ~isempty(reasons)
                info.Reason = join(reasons, " ");
                info.Gate = join(gate, "+");
                return;
            end
            if ~any(g(ev) > 0)
                info.Reason = sprintf(['Auto-reject cannot estimate the share of cells it would lose: ' ...
                    'no blind tile labelled Good among the %s blind tiles.'], curation.Audit.fmtInt(info.NumBlind));
                info.Gate = "goods";
                return;
            end

            % ---- bins of the sorted blind P values (ties never split)
            pe = p(ev);
            ge = g(ev) > 0;
            se = sections(ev);
            [ps, ord] = sort(pe);
            gs = ge(ord);
            ss = se(ord);
            m = numel(ps);
            binOf = zeros(m, 1);
            b = 1; cnt = 0;
            for i = 1:m
                binOf(i) = b;
                cnt = cnt + 1;
                if cnt >= o.MinBlindPerBin && i < m && ps(i + 1) > ps(i)
                    b = b + 1;
                    cnt = 0;
                end
            end
            nb = b;
            if nb > 1 && cnt < o.MinBlindPerBin && cnt > 0
                binOf(binOf == nb) = nb - 1;     % a short last bin joins the one before
                nb = nb - 1;
            end
            if nb < 2
                info.Reason = "Auto-reject needs blind tiles spread over at least two bins of P; they all share one.";
                info.Gate = "bins";
                return;
            end
            first = accumarray(binOf, (1:m)', [nb 1], @min);
            lowEdge = ps(first);
            pop = isfinite(p);
            pp = p(pop);
            thr = lowEdge(2:end);                % threshold j keeps bins 1..j; none above the blind P
            nt = nb - 1;
            edges = [-Inf; lowEdge(2:end); Inf];
            popBin = discretize(pp, edges);
            Npop = accumarray(popBin, 1, [nb 1]);
            nBlindBin = accumarray(binOf, 1, [nb 1]);

            % ---- weights
            if ~isempty(o.Weights)
                w = double(o.Weights(:));
                if numel(w) ~= n
                    error('curation:Audit:badArgument', 'opts.Weights needs one entry per row.');
                end
                w = w(ev);
                w = w(ord);
                weighting = "given";
            elseif string(o.Weighting) == "none"
                w = ones(m, 1);
                weighting = "none";
            else
                w = Npop(binOf) ./ nBlindBin(binOf);
                weighting = "poststrat";
            end

            % ---- cumulative estimates per threshold
            Wb = accumarray(binOf, w, [nb 1]);
            Kb = accumarray(binOf, w .* gs, [nb 1]);
            W2b = accumarray(binOf, w .^ 2, [nb 1]);
            W = cumsum(Wb); Kw = cumsum(Kb); W2 = cumsum(W2b);
            nc = cumsum(nBlindBin);
            kc = cumsum(accumarray(binOf, double(gs), [nb 1]));
            mHat = Kw ./ W;
            nEff = W .^ 2 ./ W2;
            upBin = curation.Audit.betaUpper(mHat .* nEff, nEff, conf);

            % clustered: design effect from the between-section variance (linearisation)
            [~, ~, si] = unique(ss);
            C = max(si);
            Sc = cumsum(accumarray([si binOf], w .* gs, [C nb]), 2);
            Wc = cumsum(accumarray([si binOf], w, [C nb]), 2);
            A = Sc - mHat' .* Wc;
            Ct = sum(Wc > 0, 1)';
            varClu = (Ct ./ max(Ct - 1, 1)) .* sum(A .^ 2, 1)' ./ W .^ 2;
            varBin = mHat .* (1 - mHat) ./ nEff;
            deff = ones(nb, 1);
            okV = varBin > 0 & Ct >= 2;
            deff(okV) = max(1, varClu(okV) ./ varBin(okV));
            nStar = nEff ./ deff;
            upKG = curation.Audit.betaUpper(mHat .* nStar, nStar, conf);
            % cluster bootstrap over sections
            B = max(0, round(o.Bootstrap));
            upBoot = zeros(nb, 1);
            if B > 0 && C >= 2
                rs = RandStream('mt19937ar', 'Seed', o.Seed);
                draw = randi(rs, C, C, B);
                R = accumarray([repelem((1:B)', C), reshape(draw, [], 1)], 1, [B C]);
                mStar = (R * Sc) ./ (R * Wc);
                mStar(~isfinite(mStar)) = 1;
                mStar = sort(mStar, 1);
                upBoot = mStar(min(B, max(1, ceil(conf * B))), :)';
            end
            upClu = max(upKG, upBoot);
            if string(o.Bound) == "binomial"
                up = upBin;
            else
                up = upClu;
            end
            goodLost = Kw / Kw(end);
            cand = pop & isnan(g);                 % unlabelled candidates with a P
            if ~any(cand), cand = pop; end
            pc = p(cand);
            nRej = cumsum(histcounts(pc, [-Inf; thr]))';    % rows with p < each threshold
            fracRej = nRej / max(1, numel(pc));
            j1 = 1:nt;
            okT = up(j1) <= o.MaxMissRate & goodLost(j1) <= o.MaxGoodLost;

            Curve = table(thr, nc(j1), kc(j1), mHat(j1), upBin(j1), upKG(j1), upBoot(j1), upClu(j1), ...
                up(j1), nEff(j1), deff(j1), goodLost(j1), nRej, fracRej, okT, 'VariableNames', ...
                {'Threshold', 'NBelow', 'GoodBelow', 'MissRate', 'UpperBinomial', 'UpperKornGraubard', ...
                'UpperBootstrap', 'UpperClustered', 'Upper', 'NEff', 'Deff', 'GoodLost', 'NRejected', ...
                'FracRejected', 'OK'});
            info.Curve = Curve;
            info.Weighting = weighting;
            j = find(okT, 1, 'last');
            if isempty(j)
                [~, jb] = min(up(j1) + 10 * (goodLost(j1) > o.MaxGoodLost));
                need0 = ceil(log(1 - conf) / log(1 - o.MaxMissRate));
                info.Reason = sprintf(['No threshold meets the limits: at best the %g%% upper bound on cells among ' ...
                    'the rejects is %.1f%% (limit %g%%) with %s blind tiles below it (%d Good). With no Good ' ...
                    'among them, %s blind tiles below the threshold are needed.'], 100 * conf, 100 * up(jb), ...
                    100 * o.MaxMissRate, curation.Audit.fmtInt(nc(jb)), kc(jb), curation.Audit.fmtInt(need0));
                info.Gate = "bound";
                info = curation.Audit.fillAt(info, Curve, jb);
                info.Tau = NaN;
                return;
            end
            tau = thr(j);
            info = curation.Audit.fillAt(info, Curve, j);
            info.Tau = tau;
            info.Reason = "";
            info.Gate = "";
        end

        function E = evidence(src, a2, a3)
            %EVIDENCE  P of the random blind rows and the candidates, from a project index (or a
            %   table + features).
            %   E = evidence(index, kind, model): every row of index.table(kind).
            %   E = evidence(T, F, model): T a snapshot-like table WITH a RowId column
            %   ("<SourceId>|<CellID>", as ProjectIndex.table gives), F its features (NaN rows:
            %   none).
            %   E.p: rows the model trained on (RowId in model.Stats.Ids) -> their out-of-fold P;
            %   other evidence rows and the candidates (active, unreviewed, no audit role, not
            %   excluded, no person's label) -> model.predict(F); candidates without features ->
            %   their stored ModelP ONLY when their ModelVersion is model.Version; everything else
            %   NaN. E.isGood: rows a person labelled (Good, Bad or Uncertain) -> Good or Uncertain
            %   (conservative), else NaN. E.isBlind = evidenceMask(T). E.sections = T.Section.
            %   E.NoP: evidence or candidate rows left without a P (no features and no ModelP of
            %   this model). E.Warnings: what was left out and why. E.T = T.
            %   Errors: curation:Audit:noRowId (T has no RowId column: rows could not be matched
            %   to the model's training rows, and in-sample P would be used for them),
            %   curation:Audit:noModelIds (the model was fitted without opts.Ids).
            if isa(src, 'curation.ProjectIndex')
                [T, F] = src.table(a2);
            else
                T = src;
                F = a2;
            end
            model = a3;
            n = height(T);
            if ~ismember('RowId', T.Properties.VariableNames)
                error('curation:Audit:noRowId', ['Audit.evidence needs a RowId column ("<SourceId>|<CellID>", ' ...
                    'as curation.ProjectIndex.table gives): without it the rows the model trained on cannot ' ...
                    'be found and would be scored in-sample.']);
            end
            if isempty(model.Stats) || ~isfield(model.Stats, 'Ids') || isempty(model.Stats.Ids)
                error('curation:Audit:noModelIds', ['The model was fitted without opts.Ids, so the rows it ' ...
                    'trained on are unknown; refit it with Ids (curation.ProjectIndex.trainingSet gives them).']);
            end
            st = curation.Audit.textCol(T, 'State', "active", n);
            rev = curation.Audit.logicalCol(T, 'Reviewed', n);
            lab = curation.Audit.textCol(T, 'Label', "", n);
            src2 = curation.Audit.textCol(T, 'LabelSource', "", n);
            role = curation.Audit.textCol(T, 'AuditRole', "", n);
            exc = curation.Audit.logicalCol(T, 'Excluded', n);
            ev = curation.Audit.evidenceMask(T);
            cand = st == "active" & ~rev & role == "" & ~exc & ~ismember(src2, curation.Audit.PERSON_SOURCES);
            p = nan(n, 1);
            ids = string(T.RowId);
            ids(ismissing(ids)) = "";
            [trained, loc] = ismember(ids, model.Stats.Ids);
            p(trained) = model.Stats.OofP(loc(trained));
            need = (ev | cand) & ~trained;
            okF = false(n, 1);
            if ~isempty(F) && size(F, 1) == n
                okF = any(isfinite(F), 2);
                q = need & okF;
                if any(q), p(q) = model.predict(F(q, :)); end
            end
            warns = strings(0, 1);
            if ismember('ModelP', T.Properties.VariableNames)
                mp = double(T.ModelP);
                ver = curation.Audit.textCol(T, 'ModelVersion', "", n);
                q = cand & isnan(p) & isfinite(mp);
                same = ver == string(model.Version);
                p(q & same) = mp(q & same);
                if any(q & ~same)
                    warns(end + 1) = sprintf(['%d candidate(s) without features carry a ModelP of another model ' ...
                        '(or of no recorded version): not used.'], nnz(q & ~same));
                end
            end
            p(~(ev | cand)) = NaN;
            noP = (ev | cand) & isnan(p);
            if any(noP & ~okF)
                warns(end + 1) = sprintf(['%d evidence or candidate row(s) have no features (image missing?) ' ...
                    'and no ModelP of this model: left without a P.'], nnz(noP & ~okF));
            end
            isGood = nan(n, 1);
            lb = st == "active" & rev & ismember(lab, ["Good" "Bad" "Uncertain"]) ...
                & ismember(src2, curation.Audit.PERSON_SOURCES);
            isGood(lb) = double(lab(lb) == "Good" | lab(lb) == "Uncertain");
            sec = curation.Audit.textCol(T, 'Section', "", n);
            E = struct('p', p, 'isGood', isGood, 'isBlind', ev, 'sections', sec, 'T', T, ...
                'NoP', noP, 'Warnings', warns, ...
                'Note', "Uncertain counts as Good; blind rows the model trained on use out-of-fold P.");
        end

        function mask = evidenceMask(T)
            %EVIDENCEMASK  Random blind evidence: active, Reviewed, LabelSource "blind", a label,
            %   and AuditRole holdout or reject-audit. NOT confirm-audit (drawn from tiles left at
            %   their page default: selected by the label), NOT catch (known non-cells), NOT blind
            %   re-asks without a role (chosen by disagreement): those measure the reviewer only.
            n = height(T);
            mask = curation.Audit.textCol(T, 'State', "active", n) == "active" ...
                & curation.Audit.logicalCol(T, 'Reviewed', n) ...
                & curation.Audit.textCol(T, 'LabelSource', "", n) == "blind" ...
                & ismember(curation.Audit.textCol(T, 'Label', "", n), ["Good" "Bad" "Uncertain"]) ...
                & ismember(curation.Audit.textCol(T, 'AuditRole', "", n), curation.Audit.RANDOM_ROLES);
        end

        function mask = exportExclusionMask(T)
            %EXPORTEXCLUSIONMASK  Rows that must never train ANY model (the assist model, a
            %   Stage-1 detector or a Stage-2 scorer): every row with AuditRole holdout,
            %   reject-audit or catch, whatever its label. Holdout and reject-audit rows are the
            %   random blind evidence (training on them makes every accuracy number optimistic);
            %   catch tiles are attention checks whose blind answer may be wrong on purpose.
            %   Confirm-audit rows and blind re-asks may train (with their blind label).
            n = height(T);
            mask = ismember(curation.Audit.textCol(T, 'AuditRole', "", n), curation.Audit.EXCLUDE_ROLES);
        end

        function mask = autoRejectMask(T, p, tau)
            %AUTOREJECTMASK  Rows auto-reject may label Bad: active, not reviewed, no label from a
            %   person (LabelSource not human/confirmed/blind/legacy-*), Label "" or already auto
            %   Bad, no audit role, not excluded, finite p < tau. tau NaN -> none.
            %   EXPERIMENTAL: not used by CellCurator. The pooled bound behind tau does not control
            %   losses per section or per experimental group (an independent simulation found a
            %   median 3% and up to 28% of a section's cells lost, and a 1-2% vs 0.04-0.16%
            %   difference between a dimmer-cell group and controls).
            n = height(T);
            p = double(p(:));
            if numel(p) ~= n
                error('curation:Audit:badArgument', 'p needs one entry per row of T.');
            end
            lab = curation.Audit.textCol(T, 'Label', "", n);
            src = curation.Audit.textCol(T, 'LabelSource', "", n);
            mask = curation.Audit.textCol(T, 'State', "active", n) == "active" ...
                & ~curation.Audit.logicalCol(T, 'Reviewed', n) ...
                & ~ismember(src, curation.Audit.PERSON_SOURCES) ...
                & (lab == "" | (lab == "Bad" & src == "auto")) ...
                & curation.Audit.textCol(T, 'AuditRole', "", n) == "" ...
                & ~curation.Audit.logicalCol(T, 'Excluded', n) ...
                & isfinite(p) & p < tau;
            if isnan(tau), mask(:) = false; end
        end

        %% =============================================================== suspension
        function [suspend, stats] = checkSuspend(nAudited, nGoodFound, opts)
            %CHECKSUSPEND  Suspension rule of auto-reject: three states from the one-sided bounds
            %   (opts.Confidence 0.95) on the miss rate k/n among the audited rejects, against
            %   opts.SuspendAbove (0.02):
            %     "suspended"            lower bound > SuspendAbove: evidence the rate is too high
            %     "ok"                   upper bound <= SuspendAbove: evidence the rate is low enough
            %     "not-enough-evidence"  neither (also n = 0)
            %   For a fixed n it is monotone in the cells found; for fixed cells found, more audits
            %   never turn a suspension on. Each call is a fixed-n test: checking after every new
            %   audit raises the chance of a false alarm over a whole project above 5%. Only
            %   pooled: it does not control losses per section or per group (see below).
            %   stats: N K Rate Lower Upper Interval (two-sided) State MinAudited (audits needed
            %   before "ok" is possible with no cell found) SuspendAbove Confidence Text.
            %   Lifting a suspension: it belongs to the model version and tau under which the
            %   audited rejects were made; clear the auto labels (Store.setLabel(ids, "")) so the
            %   rejects return to review, and only a new decision (refit, new tau, a new audit whose
            %   counts alone are passed here) can switch auto-reject on again.
            %   EXPERIMENTAL: not used by CellCurator. The pooled audit does not control losses
            %   per section or per experimental group (an independent simulation found a median 3%
            %   and up to 28% of a section's cells lost, and a 1-2% vs 0.04-0.16% difference between
            %   a dimmer-cell group and controls). opts.MinAudited is accepted and ignored.
            if nargin < 3 || isempty(opts), opts = struct(); end
            o = curation.Audit.fill(opts, struct('SuspendAbove', 0.02, 'Confidence', 0.95, 'MinAudited', []));
            conf = o.Confidence;
            lim = o.SuspendAbove;
            minAud = ceil(log(1 - conf) / log(1 - lim));
            n = double(nAudited);
            k = double(nGoodFound);
            if ~(isscalar(n) && isscalar(k) && n >= 0 && k >= 0 && k <= n)
                error('curation:Audit:badArgument', 'nAudited and nGoodFound must be counts with 0 <= k <= n.');
            end
            up = curation.Audit.upperBound(k, n, conf);
            lo = curation.Audit.lowerBound(k, n, conf);
            ci = curation.Audit.binomialInterval(k, n, conf);
            if n > 0 && lo > lim
                state = "suspended";
            elseif n > 0 && up <= lim
                state = "ok";
            else
                state = "not-enough-evidence";
            end
            suspend = state == "suspended";
            rate = k / n;
            if n == 0, rate = NaN; end
            pc = @(x) sprintf('%.1f%%', 100 * x);
            switch state
                case "suspended"
                    txt = sprintf(['Auto-reject suspended: %d cell(s) found in %d audited rejects (%s; %g%% lower bound %s ' ...
                        'exceeds the limit %s). Its rejects go back to the review queue.'], k, n, pc(rate), 100 * conf, ...
                        pc(lo), pc(lim));
                case "ok"
                    txt = sprintf('Auto-reject audit: %d cell(s) in %d audited rejects (%s; %g%% upper bound %s, limit %s).', ...
                        k, n, pc(rate), 100 * conf, pc(up), pc(lim));
                otherwise
                    txt = sprintf(['Auto-reject audit: not enough evidence either way: %d cell(s) in %d audited rejects ' ...
                        '(%g%% bounds %s to %s around the limit %s; with no cell found %d audits are needed).'], ...
                        k, n, 100 * conf, pc(lo), pc(up), pc(lim), minAud);
            end
            stats = struct('N', n, 'K', k, 'Rate', rate, 'Lower', lo, 'Upper', up, 'Interval', ci, ...
                'State', state, 'MinAudited', minAud, 'SuspendAbove', lim, 'Confidence', conf, ...
                'Text', string(txt));
        end

        %% =============================================================== intervals
        function ci = binomialInterval(k, n, conf, method)
            %BINOMIALINTERVAL  Two-sided interval [lo hi] (one row per element) at level conf
            %   (default 0.95). method "clopper-pearson" (default; exact, conservative; accepts
            %   non-integer effective counts) or "wilson". n == 0 -> [0 1].
            if nargin < 3 || isempty(conf), conf = 0.95; end
            if nargin < 4 || isempty(method), method = "clopper-pearson"; end
            [k, n] = curation.Audit.expand(k, n);
            a = (1 - conf) / 2;
            switch lower(string(method))
                case {"clopper-pearson", "cp", "exact"}
                    lo = curation.Audit.betaLower(k, n, 1 - a);
                    hi = curation.Audit.betaUpper(k, n, 1 - a);
                case "wilson"
                    z = sqrt(2) * erfcinv(2 * a);
                    c = (k + z ^ 2 / 2) ./ (n + z ^ 2);
                    h = z ./ (n + z ^ 2) .* sqrt(k .* (n - k) ./ n + z ^ 2 / 4);
                    lo = max(0, c - h);
                    hi = min(1, c + h);
                    lo(k == 0) = 0;
                    hi(k == n) = 1;
                    lo(n == 0) = 0; hi(n == 0) = 1;
                otherwise
                    error('curation:Audit:badArgument', 'method must be "clopper-pearson" or "wilson".');
            end
            ci = [lo(:) hi(:)];
        end

        function u = upperBound(k, n, conf, method)
            %UPPERBOUND  One-sided upper confidence bound at level conf (default 0.95).
            if nargin < 3 || isempty(conf), conf = 0.95; end
            if nargin < 4 || isempty(method), method = "clopper-pearson"; end
            ci = curation.Audit.binomialInterval(k, n, 2 * conf - 1, method);
            u = reshape(ci(:, 2), size(curation.Audit.expand(k, n)));
        end

        function l = lowerBound(k, n, conf, method)
            %LOWERBOUND  One-sided lower confidence bound at level conf (default 0.95).
            if nargin < 3 || isempty(conf), conf = 0.95; end
            if nargin < 4 || isempty(method), method = "clopper-pearson"; end
            ci = curation.Audit.binomialInterval(k, n, 2 * conf - 1, method);
            l = reshape(ci(:, 1), size(curation.Audit.expand(k, n)));
        end

        function n = confirmAuditSize(halfWidth, rate, opts)
            %CONFIRMAUDITSIZE  Confirm-audit tiles judged blind that the change rate's two-sided
            %   interval needs to be at most halfWidth wide on each side: the smallest n whose
            %   interval for k = round(rate * n) of n has (hi - lo) / 2 <= halfWidth.
            %   halfWidth, rate: scalars or arrays of one size (or one of them scalar), e.g.
            %   confirmAuditSize(0.02, 0.05) = tiles for a 5% change rate known to +-2 points.
            %   opts: Confidence 0.95, Method "clopper-pearson" | "wilson", MaxN 1e6 (Inf beyond).
            %   Count the tiles per stratum you want to state (e.g. Bad-default pages alone).
            if nargin < 3 || isempty(opts), opts = struct(); end
            o = curation.Audit.fill(opts, struct('Confidence', 0.95, 'Method', "clopper-pearson", 'MaxN', 1e6));
            [h, r] = curation.Audit.expand(halfWidth, rate);
            n = inf(size(h));
            z = sqrt(2) * erfcinv(1 - o.Confidence);
            for i = 1:numel(h)
                if ~(h(i) > 0) || ~(r(i) >= 0 && r(i) <= 1), continue; end
                lo = 1;
                hiN = min(o.MaxN, ceil(max(4 * z ^ 2 * r(i) * (1 - r(i)) / h(i) ^ 2, 20 / h(i))) + 200);
                while true
                    nn = (lo:hiN)';
                    ci = curation.Audit.binomialInterval(round(r(i) * nn), nn, o.Confidence, o.Method);
                    j = find((ci(:, 2) - ci(:, 1)) / 2 <= h(i), 1);
                    if ~isempty(j)
                        n(i) = nn(j);
                        break;
                    end
                    if hiN >= o.MaxN, break; end
                    lo = hiN + 1;
                    hiN = min(o.MaxN, 4 * hiN);
                end
            end
        end

        function [a, V] = aucDeLong(S, y)
            %AUCDELONG  AUC of each column of S (N x k scores) for the classes y (N x 1 logical,
            %   true = Good) and their DeLong covariance matrix V (k x k): var(a_i) = V(i,i), and
            %   var(a_1 - a_2) = V(1,1) + V(2,2) - 2 V(1,2) for paired scores. Rows with a NaN score
            %   in any column are left out. Ties count one half. NaN when a class is missing.
            S = double(S);
            if isvector(S), S = S(:); end
            y = logical(y(:));
            ok = all(isfinite(S), 2);
            S = S(ok, :); y = y(ok);
            k = size(S, 2);
            m = nnz(y); nn = nnz(~y);
            a = nan(k, 1); V = nan(k);
            if m == 0 || nn == 0, return; end
            V10 = zeros(m, k); V01 = zeros(nn, k);
            for c = 1:k
                x = S(y, c); z = S(~y, c);
                Rall = tiedrank([x; z]);
                V10(:, c) = (Rall(1:m) - tiedrank(x)) / nn;
                V01(:, c) = 1 - (Rall(m + 1:end) - tiedrank(z)) / m;
                a(c) = mean(V10(:, c));
            end
            if m > 1 && nn > 1
                V = cov(V10) / m + cov(V01) / nn;
            end
        end

        %% =============================================================== sampling
        function out = sampleHoldout(index, kind, opts)
            %SAMPLEHOLDOUT  New holdout rows of one channel kind (see the class help).
            if nargin < 3 || isempty(opts), opts = struct(); end
            o = curation.Audit.fill(opts, struct('Target', 400, 'N', [], 'Seed', 1, 'Strata', 10));
            T = curation.Audit.kindTable(index, kind);
            n = height(T);
            role = curation.Audit.textCol(T, 'AuditRole', "", n);
            existing = nnz(role == "holdout");
            if isempty(o.N), o.N = max(0, o.Target - existing); end
            elig = find(curation.Audit.textCol(T, 'State', "active", n) == "active" ...
                & ~curation.Audit.logicalCol(T, 'Reviewed', n) & role == "" ...
                & ~curation.Audit.logicalCol(T, 'Excluded', n) ...
                & ~ismember(curation.Audit.textCol(T, 'LabelSource', "", n), curation.Audit.PERSON_SOURCES));
            M = numel(elig);
            N = min(o.N, M);
            rs = RandStream('mt19937ar', 'Seed', o.Seed);
            rk = rand(rs, M, 1);
            sc = nan(M, 1);
            if ismember('score', T.Properties.VariableNames), sc = double(T.score(elig)); end
            stratum = repmat(o.Strata + 1, M, 1);
            fin = isfinite(sc);
            Mf = nnz(fin);
            if Mf > 0
                fi = find(fin);
                [~, ord] = sortrows([sc(fin) rk(fin)]);
                pos = zeros(Mf, 1);
                pos(ord) = 1:Mf;
                stratum(fi) = ceil(pos * o.Strata / Mf);
            end
            Mh = accumarray(stratum, 1, [o.Strata + 1 1]);
            ideal = N * Mh / max(M, 1);
            nh = floor(ideal);
            frac = ideal - nh;
            left = N - sum(nh);
            if left > 0
                [~, ro] = sort(frac, 'descend');
                nh(ro(1:left)) = nh(ro(1:left)) + 1;
            end
            sec = curation.Audit.textCol(T, 'Section', "", n);
            pick = zeros(0, 1);
            for h = 1:o.Strata + 1
                if nh(h) == 0, continue; end
                rows = find(stratum == h);
                [~, ordh] = sortrows(table(sec(elig(rows)), rk(rows)));
                rows = rows(ordh);
                step = numel(rows) / nh(h);
                start = rand(rs) * step;
                k = min(numel(rows), floor(start + (0:nh(h) - 1)' * step) + 1);
                pick = [pick; rows(k)]; %#ok<AGROW>
            end
            sel = elig(pick);
            out = curation.Audit.idTable(T, sel);
            out.score = sc(pick);
            out.Stratum = stratum(pick);
        end

        function ids = sampleRejectAudit(T, opts)
            %SAMPLEREJECTAUDIT  Per source: top the reject audit up to max(Min 15, ceil(Fraction 5%
            %   of the rows auto-rejected so far)), counting rows already audited; draws the
            %   missing ones uniformly from the auto-rejected rows without a role (Label Bad,
            %   LabelSource auto). Small sources are over-sampled (at least 15 each): pooled rates
            %   must weight sources by their inclusion probability.
            %   EXPERIMENTAL: not used by CellCurator (no row carries an auto label). The pooled
            %   audit does not control losses per section or per experimental group (an
            %   independent simulation found a median 3% and up to 28% of a section's cells lost,
            %   and a 1-2% vs 0.04-0.16% difference between a dimmer-cell group and controls).
            if nargin < 2 || isempty(opts), opts = struct(); end
            o = curation.Audit.fill(opts, struct('Fraction', 0.05, 'Min', 15, 'Seed', 1, 'SourceId', ""));
            n = height(T);
            elig = curation.Audit.textCol(T, 'State', "active", n) == "active" ...
                & curation.Audit.textCol(T, 'Label', "", n) == "Bad" ...
                & curation.Audit.textCol(T, 'LabelSource', "", n) == "auto" ...
                & curation.Audit.textCol(T, 'AuditRole', "", n) == "";
            have = curation.Audit.textCol(T, 'AuditRole', "", n) == "reject-audit";
            ids = curation.Audit.samplePerSource(T, elig, have, o);
        end

        function ids = sampleConfirmAudit(T, opts)
            %SAMPLECONFIRMAUDIT  Per source: top the confirm audit up to 2% of bulk-confirmed rows.
            if nargin < 2 || isempty(opts), opts = struct(); end
            o = curation.Audit.fill(opts, struct('Fraction', 0.02, 'Min', 0, 'Seed', 1, 'SourceId', ""));
            n = height(T);
            elig = curation.Audit.textCol(T, 'State', "active", n) == "active" ...
                & curation.Audit.logicalCol(T, 'Reviewed', n) ...
                & curation.Audit.textCol(T, 'LabelSource', "", n) == "confirmed" ...
                & curation.Audit.textCol(T, 'AuditRole', "", n) == "";
            have = curation.Audit.textCol(T, 'AuditRole', "", n) == "confirm-audit";
            ids = curation.Audit.samplePerSource(T, elig, have, o);
        end

        %% =============================================================== report
        function r = report(index, opts)
            %REPORT  Quality report per channel kind (see the class help).
            if nargin < 2 || isempty(opts), opts = struct(); end
            o = curation.Audit.fill(opts, struct('MinHoldoutPerClass', 10, 'Bands', [0.15 0.5 0.85], ...
                'TargetHalfWidth', 0.02, 'AssumedRate', 0.05, 'Confidence', 0.95));
            if isa(index, 'curation.ProjectIndex')
                kinds = unique(string(index.Sources.Kind))';
                Ts = cell(1, numel(kinds));
                for i = 1:numel(kinds)
                    Ts{i} = index.table(kinds(i));
                end
            else
                T = index;
                kcol = curation.Audit.kindColumn(T);
                kinds = unique(kcol)';
                Ts = cell(1, numel(kinds));
                for i = 1:numel(kinds)
                    Ts{i} = T(kcol == kinds(i), :);
                end
            end
            rows = cell(numel(kinds), 1);
            K = struct([]);
            for i = 1:numel(kinds)
                s = curation.Audit.reportKind(Ts{i}, kinds(i), o);
                if isempty(K), K = s; else, K(i) = s; end
                rows{i} = rmfield(s, {'Reviewers', 'BySection', 'ConfirmByBand'});
            end
            if isempty(kinds)
                r = struct('Table', table(), 'Kinds', struct([]), 'Generated', string(datetime('now')));
                return;
            end
            Tab = struct2table(vertcat(rows{:}), 'AsArray', true);
            r = struct('Table', Tab, 'Kinds', K, 'Generated', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm')));
        end

        function txt = reportText(r)
            %REPORTTEXT  One plain-language paragraph per channel kind (string array).
            txt = strings(0, 1);
            f = @curation.Audit.fmtInt;
            pc = @(x) curation.Audit.fmtPct(x);
            nn = @(x, one, many) f(x) + " " + string(curation.Audit.ifThen(x == 1, one, many));
            for i = 1:numel(r.Kinds)
                s = r.Kinds(i);
                name = upper(s.Kind);
                if s.Kind == "pnn", name = "PNN (WFA)"; elseif s.Kind == "pv", name = "PV"; end
                t = string(sprintf(['%s: %s in %s (%s). A person reviewed %s ' ...
                    '(%s kept as cells; %s decided one by one, %s of them blind; %s confirmed in bulk on pages); %s to review.'], ...
                    name, nn(s.Candidates, "candidate", "candidates"), nn(s.Sources, "source", "sources"), ...
                    nn(s.Sections, "section", "sections"), f(s.Reviewed), f(s.Kept), ...
                    f(s.HumanDecided), f(s.Blind), f(s.Confirmed), nn(s.ToReview, "remains", "remain")));
                % reviewer consistency
                if s.ConfirmAuditN > 0
                    t = t + sprintf([' Reviewer consistency: of %s tiles first confirmed by default and later shown again blind, ' ...
                        '%s got a different label (%s; 95%% CI %s to %s): on Bad-default pages %s of %s (%s; CI %s to %s) ' ...
                        'were judged Good or Uncertain (cells the default had left Bad), on Good-default pages %s of %s ' ...
                        '(%s; CI %s to %s) Bad or Uncertain.'], f(s.ConfirmAuditN), f(s.ConfirmAuditDisagree), pc(s.ConfirmAuditRate), ...
                        pc(s.ConfirmAuditLo), pc(s.ConfirmAuditHi), f(s.ConfirmBadDefaultChanged), f(s.ConfirmBadDefaultN), ...
                        pc(s.ConfirmBadDefaultRate), pc(s.ConfirmBadDefaultLo), pc(s.ConfirmBadDefaultHi), ...
                        f(s.ConfirmGoodDefaultChanged), f(s.ConfirmGoodDefaultN), pc(s.ConfirmGoodDefaultRate), ...
                        pc(s.ConfirmGoodDefaultLo), pc(s.ConfirmGoodDefaultHi));
                    B = s.ConfirmByBand;
                    B = B(B.N > 0, :);
                    if ~isempty(B)
                        parts = B.Band + " " + string(B.Changed) + "/" + string(B.N);
                        t = t + " By band: " + join(parts, ", ") + ".";
                    end
                    if ~isnan(s.EstCellsLeftBad)
                        t = t + sprintf([' Among the %s tiles still labelled Bad by bulk confirmation an estimated %s ' ...
                            '(95%% CI %s to %s) are cells; among the %s still labelled Good by it, an estimated %s ' ...
                            '(CI %s to %s) are not.'], f(s.ConfirmedBadUnaudited), f(s.EstCellsLeftBad), ...
                            f(s.EstCellsLeftBadLo), f(s.EstCellsLeftBadHi), f(s.ConfirmedGoodUnaudited), ...
                            f(s.EstNonCellsKeptGood), f(s.EstNonCellsKeptGoodLo), f(s.EstNonCellsKeptGoodHi));
                    end
                    t = t + sprintf(' For +-%.0f points on each default''s change rate about %s (Bad) and %s (Good) tiles judged blind are needed.', ...
                        100 * s.TargetHalfWidth, f(s.ConfirmBadDefaultNeeded), f(s.ConfirmGoodDefaultNeeded));
                elseif s.ConfirmAuditPending > 0
                    t = t + sprintf(' Reviewer consistency: %s confirm-audit tiles wait to be shown blind.', f(s.ConfirmAuditPending));
                else
                    t = t + " Reviewer consistency cannot be measured yet: no confirmed tile has been shown again blind.";
                end
                if s.CatchN > 0
                    t = t + sprintf(' Attention checks: %s of %s known non-cells were labelled Bad (%s).', ...
                        f(s.CatchHits), f(s.CatchN), pc(s.CatchHitRate));
                end
                % model accuracy
                if ~isnan(s.HoldoutAUCModel)
                    t = t + sprintf([' Model accuracy: on %s held-out tiles judged blind (%s cells) the assist model ranks ' ...
                        'cells above non-cells with AUC %.3f (95%% CI %.3f to %.3f)'], f(s.HoldoutN), f(s.HoldoutGood), ...
                        s.HoldoutAUCModel, s.HoldoutAUCModelLo, s.HoldoutAUCModelHi);
                    if ~isnan(s.HoldoutAUCRescore)
                        t = t + sprintf(', raw rescore %.3f (CI %.3f to %.3f); difference %+.3f (CI %+.3f to %+.3f)', ...
                            s.HoldoutAUCRescore, s.HoldoutAUCRescoreLo, s.HoldoutAUCRescoreHi, s.HoldoutAUCDiff, ...
                            s.HoldoutAUCDiffLo, s.HoldoutAUCDiffHi);
                    end
                    t = t + sprintf('. Its mean P there is %s against %s cells observed; the proposal matched the blind label on %s.', ...
                        pc(s.HoldoutMeanP), pc(s.HoldoutObservedGood), pc(s.HoldoutAgree));
                else
                    t = t + " Model accuracy: " + s.HoldoutNote;
                end
                % experimental auto-reject
                if s.AutoRejected > 0 || s.RejectAuditN > 0
                    t = t + sprintf(' Experimental auto-reject (not part of CellCurator) removed %s without anyone seeing them.', ...
                        nn(s.AutoRejected, "candidate", "candidates"));
                    if s.RejectAuditN > 0
                        t = t + sprintf([' A random audit showed %s of the rejects blind: %s (%s; 95%% CI %s to %s), ' ...
                            'so an estimated %s (95%% upper bound %s) are among the unseen rejects; this says nothing ' ...
                            'about any one section or group.'], ...
                            f(s.RejectAuditN), nn(s.RejectAuditGood, "was a cell or possibly a cell", ...
                            "were cells or possibly cells"), pc(s.RejectAuditRate), pc(s.RejectAuditLo), ...
                            pc(s.RejectAuditHi), nn(round(s.EstCellsLost), "cell", "cells"), f(ceil(s.EstCellsLostUpper)));
                    else
                        t = t + " No audited reject has been labelled yet, so cells lost cannot be estimated.";
                    end
                end
                if s.ReviewerCounts ~= ""
                    t = t + " Reviewed per person: " + s.ReviewerCounts + ".";
                end
                t = t + " These are estimates from samples; the intervals treat tiles as independent and are too narrow when tiles of one section are alike.";
                txt(end + 1, 1) = string(t); %#ok<AGROW>
            end
        end
    end

    %% =================================================================== private helpers
    methods (Static, Access = private)

        function s = reportKind(T, kind, o)
            n = height(T);
            st = curation.Audit.textCol(T, 'State', "active", n);
            rev = curation.Audit.logicalCol(T, 'Reviewed', n);
            lab = curation.Audit.textCol(T, 'Label', "", n);
            src = curation.Audit.textCol(T, 'LabelSource', "", n);
            role = curation.Audit.textCol(T, 'AuditRole', "", n);
            exc = curation.Audit.logicalCol(T, 'Excluded', n);
            sec = curation.Audit.textCol(T, 'Section', "", n);
            conf = o.Confidence;
            act = st == "active";
            auto = act & src == "auto" & lab == "Bad";
            s = struct();
            s.Kind = string(kind);
            sid = curation.Audit.sourceKey(T);
            s.Sources = numel(unique(sid));
            s.Sections = numel(unique(sec));
            s.Candidates = nnz(act);
            s.Reviewed = nnz(act & rev);
            s.Kept = nnz(act & rev & lab == "Good" & ismember(src, curation.Audit.KEEP_SOURCES));
            s.Good = nnz(act & rev & lab == "Good");
            s.Bad = nnz(act & rev & lab == "Bad");
            s.Uncertain = nnz(act & rev & lab == "Uncertain");
            s.Confirmed = nnz(act & rev & src == "confirmed");
            s.HumanDecided = nnz(act & rev & ismember(src, ["human" "blind" "legacy-qc" "legacy-resolver"]));
            s.Blind = nnz(act & rev & src == "blind");
            s.AutoRejected = nnz(auto);
            s.ToReview = nnz(act & ~rev & ~auto & ~exc);

            % ---- reviewer consistency: confirm audit (blind labels only)
            caAll = act & role == "confirm-audit";
            ca = caAll & rev & src == "blind";
            s.ConfirmAuditPending = nnz(caAll & src ~= "blind");
            prior = curation.Audit.textCol(T, 'PriorLabel', "", n);
            s.ConfirmAuditUnknown = nnz(ca & prior == "");      % earlier label not recoverable
            ca = ca & prior ~= "";
            changed = ca & prior ~= lab;
            s.ConfirmAuditN = nnz(ca);
            s.ConfirmAuditDisagree = nnz(changed);
            [s.ConfirmAuditRate, s.ConfirmAuditLo, s.ConfirmAuditHi] = ...
                curation.Audit.rateCI(s.ConfirmAuditDisagree, s.ConfirmAuditN, conf);
            gd = ca & prior == "Good";
            bd = ca & prior == "Bad";
            s.ConfirmGoodDefaultN = nnz(gd);
            s.ConfirmGoodDefaultChanged = nnz(gd & changed);
            [s.ConfirmGoodDefaultRate, s.ConfirmGoodDefaultLo, s.ConfirmGoodDefaultHi] = ...
                curation.Audit.rateCI(s.ConfirmGoodDefaultChanged, s.ConfirmGoodDefaultN, conf);
            s.ConfirmBadDefaultN = nnz(bd);
            s.ConfirmBadDefaultChanged = nnz(bd & changed);
            [s.ConfirmBadDefaultRate, s.ConfirmBadDefaultLo, s.ConfirmBadDefaultHi] = ...
                curation.Audit.rateCI(s.ConfirmBadDefaultChanged, s.ConfirmBadDefaultN, conf);
            s.ConfirmedGoodUnaudited = nnz(act & rev & src == "confirmed" & lab == "Good");
            s.ConfirmedBadUnaudited = nnz(act & rev & src == "confirmed" & lab == "Bad");
            s.EstCellsLeftBad = s.ConfirmBadDefaultRate * s.ConfirmedBadUnaudited;
            s.EstCellsLeftBadLo = s.ConfirmBadDefaultLo * s.ConfirmedBadUnaudited;
            s.EstCellsLeftBadHi = s.ConfirmBadDefaultHi * s.ConfirmedBadUnaudited;
            s.EstNonCellsKeptGood = s.ConfirmGoodDefaultRate * s.ConfirmedGoodUnaudited;
            s.EstNonCellsKeptGoodLo = s.ConfirmGoodDefaultLo * s.ConfirmedGoodUnaudited;
            s.EstNonCellsKeptGoodHi = s.ConfirmGoodDefaultHi * s.ConfirmedGoodUnaudited;
            s.TargetHalfWidth = o.TargetHalfWidth;
            % planning rate: the observed one once 30 tiles of that default were judged blind
            rg = s.ConfirmGoodDefaultRate; if s.ConfirmGoodDefaultN < 30, rg = o.AssumedRate; end
            rb = s.ConfirmBadDefaultRate; if s.ConfirmBadDefaultN < 30, rb = o.AssumedRate; end
            s.ConfirmGoodDefaultNeeded = curation.Audit.confirmAuditSize(o.TargetHalfWidth, rg, struct('Confidence', conf));
            s.ConfirmBadDefaultNeeded = curation.Audit.confirmAuditSize(o.TargetHalfWidth, rb, struct('Confidence', conf));
            % by band of the page it was confirmed on
            if ismember('PriorProposalP', T.Properties.VariableNames)
                pp = double(T.PriorProposalP(:));
                if ismember('ProposalP', T.Properties.VariableNames)
                    alt = double(T.ProposalP(:));
                    pp(isnan(pp)) = alt(isnan(pp));
                end
            elseif ismember('ProposalP', T.Properties.VariableNames)
                pp = double(T.ProposalP(:));
            else
                pp = nan(n, 1);
            end
            band = curation.Audit.bandOf(pp, o.Bands);
            names = fliplr(curation.Audit.BANDS);          % good, middle-high, middle-low, bad
            defs = ["Good" "Good" "Bad" "Bad"];
            if any(ca & band == "unknown")
                names(end + 1) = "unknown";
                defs(end + 1) = "";
            end
            nbnd = numel(names);
            Nb = zeros(nbnd, 1); Cb = zeros(nbnd, 1); Rb = nan(nbnd, 1); Lb = nan(nbnd, 1); Hb = nan(nbnd, 1);
            for j = 1:nbnd
                q = ca & band == names(j);
                Nb(j) = nnz(q);
                Cb(j) = nnz(q & changed);
                [Rb(j), Lb(j), Hb(j)] = curation.Audit.rateCI(Cb(j), Nb(j), conf);
            end
            s.ConfirmByBand = table(names(:), defs(:), Nb, Cb, Rb, Lb, Hb, 'VariableNames', ...
                {'Band', 'Default', 'N', 'Changed', 'Rate', 'Lo', 'Hi'});
            % catch tiles
            ct = act & role == "catch" & rev & src == "blind";
            s.CatchN = nnz(ct);
            s.CatchHits = nnz(ct & lab == "Bad");
            s.CatchHitRate = s.CatchHits / s.CatchN;
            if s.CatchN == 0, s.CatchHitRate = NaN; end

            % ---- model accuracy: holdout, blind labels only
            hoAll = act & role == "holdout";
            ho = hoAll & rev & src == "blind" & ismember(lab, ["Good" "Bad"]);
            s.HoldoutN = nnz(ho);
            s.HoldoutGood = nnz(ho & lab == "Good");
            s.HoldoutPending = nnz(hoAll & src ~= "blind");
            yh = lab(ho) == "Good";
            mp = nan(n, 1);
            if ismember('ModelP', T.Properties.VariableNames), mp = double(T.ModelP); end
            rsc = nan(n, 1);
            if ismember('rescore', T.Properties.VariableNames), rsc = double(T.rescore); end
            mph = mp(ho); rsh = rsc(ho);
            z = sqrt(2) * erfcinv(1 - conf);
            nanF = {'HoldoutAUCModel', 'HoldoutAUCModelLo', 'HoldoutAUCModelHi', 'HoldoutAUCRescore', ...
                'HoldoutAUCRescoreLo', 'HoldoutAUCRescoreHi', 'HoldoutAUCDiff', 'HoldoutAUCDiffLo', ...
                'HoldoutAUCDiffHi', 'HoldoutMeanP', 'HoldoutObservedGood', 'HoldoutBrier', 'HoldoutAgree'};
            for j = 1:numel(nanF), s.(nanF{j}) = NaN; end
            s.HoldoutNDiff = 0;
            ver = curation.Audit.textCol(T, 'ModelVersion', "", n);
            s.HoldoutModelVersions = numel(unique(ver(ho & isfinite(mp) & ver ~= "")));
            minC = o.MinHoldoutPerClass;
            okM = isfinite(mph);
            gM = nnz(yh & okM); bM = nnz(~yh & okM);
            note = "";
            if s.HoldoutN == 0
                note = sprintf("no held-out tile has been judged blind yet (%s pending); at least %d Good and %d Bad are needed.", ...
                    curation.Audit.fmtInt(s.HoldoutPending), minC, minC);
            elseif gM < minC || bM < minC
                note = sprintf("too few blind holdout labels with a model P: %d Good and %d Bad (at least %d of each are needed); accuracy not reported.", ...
                    gM, bM, minC);
            else
                [a, V] = curation.Audit.aucDeLong(mph(okM), yh(okM));
                s.HoldoutAUCModel = a;
                s.HoldoutAUCModelLo = max(0, a - z * sqrt(V));
                s.HoldoutAUCModelHi = min(1, a + z * sqrt(V));
                s.HoldoutMeanP = mean(mph(okM));
                s.HoldoutObservedGood = mean(yh(okM));
                s.HoldoutBrier = mean((mph(okM) - yh(okM)) .^ 2);
                s.HoldoutAgree = mean((mph(okM) >= 0.5) == yh(okM));
                if s.HoldoutModelVersions > 1
                    note = sprintf("the holdout P comes from %d model versions.", s.HoldoutModelVersions);
                end
            end
            okR = isfinite(rsh);
            if nnz(yh & okR) >= minC && nnz(~yh & okR) >= minC
                [a, V] = curation.Audit.aucDeLong(rsh(okR), yh(okR));
                s.HoldoutAUCRescore = a;
                s.HoldoutAUCRescoreLo = max(0, a - z * sqrt(V));
                s.HoldoutAUCRescoreHi = min(1, a + z * sqrt(V));
            end
            okB = okM & okR;
            s.HoldoutNDiff = nnz(okB);
            if ~isnan(s.HoldoutAUCModel) && nnz(yh & okB) >= minC && nnz(~yh & okB) >= minC
                [a, V] = curation.Audit.aucDeLong([mph(okB) rsh(okB)], yh(okB));
                d = a(1) - a(2);
                se = sqrt(max(0, V(1, 1) + V(2, 2) - 2 * V(1, 2)));
                s.HoldoutAUCDiff = d;
                s.HoldoutAUCDiffLo = d - z * se;
                s.HoldoutAUCDiffHi = d + z * se;
            end
            s.HoldoutNote = string(note);

            % ---- experimental reject audit (blind labels only)
            ra = act & role == "reject-audit";
            raL = ra & rev & src == "blind" & ismember(lab, ["Good" "Bad" "Uncertain"]);
            raG = raL & (lab == "Good" | lab == "Uncertain");
            s.RejectAuditN = nnz(raL);
            s.RejectAuditPending = nnz(ra & src ~= "blind");
            s.RejectAuditGood = nnz(raG);
            [s.RejectAuditRate, s.RejectAuditLo, s.RejectAuditHi] = curation.Audit.rateCI(s.RejectAuditGood, s.RejectAuditN, conf);
            s.RejectAuditUpper95 = curation.Audit.upperBound(s.RejectAuditGood, s.RejectAuditN, 0.95);
            if s.RejectAuditN == 0, s.RejectAuditUpper95 = NaN; end
            [us, ~, si] = unique(sid);
            nAuto = accumarray(si, double(auto), [numel(us) 1]);
            nA = accumarray(si, double(raL), [numel(us) 1]);
            kA = accumarray(si, double(raG), [numel(us) 1]);
            if s.RejectAuditN > 0
                rate = kA ./ nA;
                rate(nA == 0) = s.RejectAuditRate;
                s.EstCellsLost = sum(nAuto .* rate);
                s.EstCellsLostUpper = s.RejectAuditUpper95 * s.AutoRejected;
            else
                s.EstCellsLost = NaN;
                s.EstCellsLostUpper = NaN;
            end

            % ---- reviewers
            who = curation.Audit.textCol(T, 'Reviewer', "", n);
            rr = act & rev;
            [uw, ~, wi] = unique(who(rr));
            nw = numel(uw);
            labs = lab(rr); srcs = src(rr);
            cntBy = @(x) accumarray(wi, double(x), [nw 1]);
            RT = table(uw, cntBy(true(size(labs))), cntBy(labs == "Good"), cntBy(labs == "Bad"), ...
                cntBy(labs == "Uncertain"), cntBy(srcs == "confirmed"), ...
                cntBy(ismember(srcs, ["human" "blind" "legacy-qc" "legacy-resolver"])), cntBy(srcs == "blind"), ...
                'VariableNames', {'Reviewer', 'Reviewed', 'Good', 'Bad', 'Uncertain', 'Confirmed', ...
                'HumanDecided', 'Blind'});
            RT = sortrows(RT, 'Reviewed', 'descend');
            nm = RT.Reviewer;
            nm(nm == "") = "(unknown)";
            if isempty(nm)
                s.ReviewerCounts = "";
            else
                s.ReviewerCounts = join(nm + ": " + string(RT.Reviewed), "; ");
            end
            s.Reviewers = RT;

            % ---- sections
            [ux, ~, xi] = unique(sec);
            nx = numel(ux);
            cx = @(x) accumarray(xi, double(x), [nx 1]);
            nSrc = zeros(nx, 1);
            for j = 1:nx, nSrc(j) = numel(unique(sid(xi == j))); end
            s.BySection = table(ux, nSrc, cx(act), cx(act & rev), cx(act & rev & lab == "Good"), ...
                cx(act & rev & lab == "Bad"), cx(act & rev & lab == "Uncertain"), cx(act & rev & src == "confirmed"), ...
                cx(act & rev & ismember(src, ["human" "blind" "legacy-qc" "legacy-resolver"])), cx(act & rev & src == "blind"), ...
                cx(act & ~rev & ~auto & ~exc), cx(ho), cx(hoAll & src ~= "blind"), cx(ca), cx(changed), cx(auto), ...
                'VariableNames', {'Section', 'Sources', 'Candidates', 'Reviewed', 'Good', 'Bad', 'Uncertain', ...
                'Confirmed', 'HumanDecided', 'Blind', 'ToReview', 'HoldoutN', 'HoldoutPending', ...
                'ConfirmAuditN', 'ConfirmAuditChanged', 'AutoRejected'});
        end

        function b = bandOf(p, bands)
            b = repmat("unknown", numel(p), 1);
            b(p < bands(1)) = "bad";
            b(p >= bands(1) & p < bands(2)) = "middle-low";
            b(p >= bands(2) & p < bands(3)) = "middle-high";
            b(p >= bands(3)) = "good";
        end

        function [rate, lo, hi] = rateCI(k, n, conf)
            if nargin < 3, conf = 0.95; end
            if n == 0
                rate = NaN; lo = NaN; hi = NaN;
                return;
            end
            rate = k / n;
            ci = curation.Audit.binomialInterval(k, n, conf);
            lo = ci(1); hi = ci(2);
        end

        function out = samplePerSource(T, elig, have, o)
            % Each source draws from a random stream seeded with its id, so the id must be known:
            % the SourceId column, else Section + SourceKey, else opts.SourceId (one source). A
            % channel key alone is no source id (every section has an ECM1).
            n = height(T);
            v = T.Properties.VariableNames;
            if ismember('SourceId', v) || (ismember('Section', v) && ismember('SourceKey', v))
                key = curation.Audit.sourceKey(T);
            elseif strlength(string(o.SourceId)) > 0
                key = repmat(string(o.SourceId), n, 1);
            else
                error('curation:Audit:noSourceId', ['The audit sample needs the source of each row: a ' ...
                    'SourceId column (or Section and SourceKey), or opts.SourceId for a one-source table. ' ...
                    'Without it every source would draw the same random rows.']);
            end
            us = unique(key);
            single = numel(us) <= 1;
            cid = zeros(n, 1, 'uint32');
            if ismember('CellID', T.Properties.VariableNames), cid = uint32(T.CellID); end
            sel = zeros(0, 1);
            for i = 1:numel(us)
                inS = key == us(i);
                e = find(elig & inS);
                total = numel(e) + nnz(have & inS);
                target = min(total, max(o.Min, ceil(o.Fraction * total - 1e-9)));
                need = min(numel(e), max(0, target - nnz(have & inS)));
                if need == 0, continue; end
                h = char(curation.Hash.of(us(i)));
                seed = mod(double(o.Seed) * 1000003 + hex2dec(h(1:7)), 2 ^ 32);
                rs = RandStream('mt19937ar', 'Seed', seed);
                sel = [sel; e(sort(randperm(rs, numel(e), need), 2)')]; %#ok<AGROW>
            end
            if single
                out = sort(cid(sel));
            else
                out = table(key(sel), cid(sel), 'VariableNames', {'SourceId', 'CellID'});
                out = sortrows(out, {'SourceId', 'CellID'});
            end
        end

        function key = sourceKey(T)
            n = height(T);
            v = T.Properties.VariableNames;
            if ismember('SourceId', v)
                key = string(T.SourceId);
            elseif ismember('Section', v) && ismember('SourceKey', v)
                key = string(T.Section) + "|" + string(T.SourceKey);
            elseif ismember('SourceKey', v)
                key = string(T.SourceKey);
            else
                key = repmat("", n, 1);
            end
            key(ismissing(key)) = "";
        end

        function k = kindColumn(T)
            n = height(T);
            if ismember('Kind', T.Properties.VariableNames)
                k = string(T.Kind);
            elseif ismember('SourceKey', T.Properties.VariableNames)
                sk = string(T.SourceKey);
                [u, ~, ui] = unique(sk);
                ku = strings(numel(u), 1);
                for i = 1:numel(u)
                    ku(i) = curation.Proposals.kindOf(u(i));
                end
                k = ku(ui);
            else
                k = repmat("unknown", n, 1);
            end
            k = reshape(k, [], 1);
        end

        function T = kindTable(index, kind)
            if isa(index, 'curation.ProjectIndex')
                T = index.table(kind);
            else
                T = index;
                if height(T) > 0
                    T = T(curation.Audit.kindColumn(T) == string(kind), :);
                end
            end
        end

        function out = idTable(T, rows)
            v = T.Properties.VariableNames;
            out = table();
            for c = ["SourceId", "Section", "SourceKey", "Folder", "Base", "CellID"]
                if ismember(c, v)
                    out.(c) = T.(c)(rows);
                end
            end
            if ~ismember('CellID', v), out.Row = rows(:); end
        end

        function info = fillAt(info, C, j)
            info.NBelow = C.NBelow(j);
            info.GoodBelow = C.GoodBelow(j);
            info.MissRate = C.MissRate(j);
            info.UpperBound = C.Upper(j);
            info.UpperBinomial = C.UpperBinomial(j);
            info.UpperClustered = C.UpperClustered(j);
            info.NEff = C.NEff(j);
            info.Deff = C.Deff(j);
            info.GoodLost = C.GoodLost(j);
            info.FracRejected = C.FracRejected(j);
            info.NRejected = C.NRejected(j);
        end

        function info = emptyInfo(o)
            info = struct('Tau', NaN, 'Reason', "", 'Gate', "", 'NumLabels', 0, 'NumLabelSections', 0, ...
                'NumBlind', 0, 'NBelow', NaN, 'GoodBelow', NaN, 'MissRate', NaN, 'UpperBound', NaN, ...
                'UpperBinomial', NaN, 'UpperClustered', NaN, 'NEff', NaN, 'Deff', NaN, 'GoodLost', NaN, ...
                'FracRejected', NaN, 'NRejected', NaN, 'Curve', table(), 'Bound', string(o.Bound), ...
                'Weighting', string(o.Weighting), 'Confidence', o.Confidence, 'MaxMissRate', o.MaxMissRate, ...
                'MaxGoodLost', o.MaxGoodLost, 'Guarantee', curation.Audit.GUARANTEE);
        end

        function u = betaUpper(k, n, conf)
            % Upper confidence bound for a proportion from (possibly non-integer) k of n.
            [k, n] = curation.Audit.expand(k, n);
            u = ones(size(k));
            ok = n > 0 & k < n;
            u(ok) = betaincinv(conf, k(ok) + 1, n(ok) - k(ok));
        end

        function l = betaLower(k, n, conf)
            [k, n] = curation.Audit.expand(k, n);
            l = zeros(size(k));
            ok = n > 0 & k > 0;
            l(ok) = betaincinv(1 - conf, k(ok), n(ok) - k(ok) + 1);
        end

        function [k, n] = expand(k, n)
            k = double(k); n = double(n);
            if isscalar(k) && ~isscalar(n), k = repmat(k, size(n)); end
            if isscalar(n) && ~isscalar(k), n = repmat(n, size(k)); end
        end

        function o = fill(opts, d)
            o = d;
            if isstruct(opts)
                f = fieldnames(opts);
                for i = 1:numel(f)
                    o.(f{i}) = opts.(f{i});
                end
            end
        end

        function s = fmtInt(x)
            if isnan(x), s = "?"; return; end
            if isinf(x), s = "more than a million"; return; end
            s = string(sprintf('%d', round(x)));
            c = char(s);
            neg = startsWith(c, '-');
            if neg, c = c(2:end); end
            k = numel(c);
            out = '';
            while k > 3
                out = [',' c(k - 2:k) out]; %#ok<AGROW>
                k = k - 3;
            end
            out = [c(1:k) out];
            if neg, out = ['-' out]; end
            s = string(out);
        end

        function v = ifThen(c, a, b)
            if c, v = a; else, v = b; end
        end

        function s = fmtPct(x)
            if isnan(x), s = "n/a"; return; end
            s = string(sprintf('%.1f%%', 100 * x));
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
