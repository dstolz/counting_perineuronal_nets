classdef tAssistModel < matlab.unittest.TestCase
    %TASSISTMODEL  curation.AssistModel: accuracy on a synthetic multi-animal project against the
    %   rescore / cold-start baselines, grouped folds, calibration, PAV, NaN features, label gates,
    %   save/load, determinism, the training/blind masks, the compiled forest, background fitting.
    %   The Benchmark test times fit (20,000 x 30, budget 10 s) and predict (3,000 rows, 150 ms).
    %   Run: pwsh -File tools\Run-Tests.ps1 tAssistModel [-IncludeSlow for the benchmark]

    properties
        Project     % struct array: per synthetic section F (ECM1, PV2), labels, animal, section
    end

    methods (TestClassSetup)
        function makeProject(tc)
            % 10 sections of 5 animals (2 each), both channels, features from the images.
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            P = struct('Animal', {}, 'Section', {}, 'FE', {}, 'yE', {}, 'FP', {}, 'yP', {});
            k = 0;
            for a = 1:5
                for s = 1:2
                    k = k + 1;
                    base = sprintf('SUBJ-ID-%dIHC_sec%d', 9000 + a, s);
                    [~, tr] = makeSyntheticDataset(fullfile(fx.Folder, base), 'BaseName', base, ...
                        'Seed', 100 + k, 'Variants', false);
                    pE = imread(tr.paths.tif, 1);
                    pP = imread(tr.paths.tif, 2);
                    FE = curation.Features.compute(pE, pP, tr.ECM1.locs, tr.umPerPixel);
                    FP = curation.Features.compute(pP, pE, tr.PV2.locs, tr.umPerPixel);
                    P(k).Animal = string(9000 + a);
                    P(k).Section = string(base);
                    P(k).FE = FE(tr.ECM1.det.Kind ~= "dup", :);
                    P(k).yE = tr.ECM1.det.Kind(tr.ECM1.det.Kind ~= "dup") == "tp";
                    P(k).FP = FP(tr.PV2.det.Kind ~= "dup", :);
                    P(k).yP = tr.PV2.det.Kind(tr.PV2.det.Kind ~= "dup") == "tp";
                end
            end
            tc.Project = P;
        end
    end

    methods (Static)
        function [F, y, g, p] = synth(n, K, seed)
            % Synthetic features with a KNOWN P(Good): logistic in a few columns, NaN in two.
            rs = RandStream('mt19937ar', 'Seed', seed);
            F = randn(rs, n, K);
            eta = 1.5 * F(:, 1) - 1.0 * F(:, 2) + 0.8 * F(:, 3) .* (F(:, 4) > 0) - 0.5;
            p = 1 ./ (1 + exp(-eta));
            y = rand(rs, n, 1) < p;
            F(rand(rs, n, 1) < 0.2, 2) = NaN;
            F(rand(rs, n, 1) < 0.3, 5) = NaN;
            g = "A" + string(randi(rs, 10, n, 1));
        end

        function [F, y, g, s] = stack(P, kind)
            if kind == "pnn"
                F = vertcat(P.FE); y = vertcat(P.yE);
                g = repelem([P.Animal]', arrayfun(@(q) numel(q.yE), P)');
                s = repelem([P.Section]', arrayfun(@(q) numel(q.yE), P)');
            else
                F = vertcat(P.FP); y = vertcat(P.yP);
                g = repelem([P.Animal]', arrayfun(@(q) numel(q.yP), P)');
                s = repelem([P.Section]', arrayfun(@(q) numel(q.yP), P)');
            end
        end

        function T = maskTable()
            % One row per case of the training / blind rules.
            c = { ...
                % State     Reviewed Label       Source             Excluded Role             train blind
                % (row 5, blind without a role, is a disagreement re-ask: it trains with its blind
                % label; rows 15 and 17, reject-audit and catch, never train: they are evidence /
                % attention checks, see curation.Audit.exportExclusionMask)
                "active",   true,    "Good",     "human",           false,   "",              true,  false
                "active",   true,    "Bad",      "human",           false,   "",              true,  false
                "active",   true,    "Good",     "confirmed",       false,   "",              true,  false
                "active",   true,    "Bad",      "confirmed",       false,   "",              true,  false
                "active",   true,    "Good",     "blind",           false,   "",              true,  true
                "active",   true,    "Bad",      "legacy-qc",       false,   "",              true,  false
                "active",   true,    "Bad",      "legacy-resolver", false,   "",              false, false
                "active",   false,   "Bad",      "auto",            false,   "",              false, false
                "active",   true,    "Uncertain","human",           false,   "",              false, false
                "active",   false,   "",         "",                false,   "",              false, false
                "merged",   true,    "Good",     "human",           false,   "",              false, false
                "stale",    true,    "Bad",      "human",           false,   "",              false, false
                "active",   true,    "Good",     "human",           true,    "",              false, false
                "active",   true,    "Good",     "blind",           false,   "holdout",       false, true
                "active",   true,    "Bad",      "blind",           false,   "reject-audit",  false, true
                "active",   true,    "Good",     "blind",           false,   "confirm-audit", true,  true
                "active",   true,    "Bad",      "blind",           false,   "catch",         false, true
                "active",   false,   "",         "",                false,   "holdout",       false, true
                "active",   false,   "Bad",      "auto",            false,   "reject-audit",  false, true
                "active",   false,   "Good",     "human",           false,   "",              false, false};
            T = cell2table(c, 'VariableNames', {'State', 'Reviewed', 'Label', 'LabelSource', ...
                'Excluded', 'AuditRole', 'ExpTrain', 'ExpBlind'});
            for v = ["State" "Label" "LabelSource" "AuditRole"]
                T.(v) = string(T.(v));
            end
            T.CellID = uint32((1:height(T))');
        end

        function S = simProject(seed, regime)
            %SIMPROJECT  A synthetic project of feature rows with KNOWN truth: 10 animals x 3
            %   sections x 1,500 candidates, cells ~25% (varying by section), 8 features of which
            %   some carry animal / section shifts (staining, background) and one is rescore-like.
            %   regime: "base" | "overlap" (cells and non-cells overlap more) | "shift" (strong
            %   animal and section shifts).
            if nargin < 2, regime = "base"; end
            rs = RandStream('mt19937ar', 'Seed', seed);
            nA = 10; spa = 3; nps = 1500;
            nS = nA * spa; N = nS * nps;
            mu = 2.2; sa = 0.3; ss = 0.3;
            switch regime
                case "overlap", mu = 1.3;
                case "shift", sa = 0.7; ss = 0.7;
            end
            secAnimal = repelem((1:nA)', spa);
            aEff = sa * randn(rs, nA, 1);
            sEff = ss * randn(rs, nS, 1);
            prev = 1 ./ (1 + exp(-(log(1 / 3) + 0.4 * randn(rs, nS, 1))));
            sec = repelem((1:nS)', nps);
            y = rand(rs, N, 1) < prev(sec);
            q = randn(rs, N, 1) + mu * y;
            shift = aEff(secAnimal(sec)) + sEff(sec);
            F = zeros(N, 8);
            F(:, 1) = q + shift + 0.5 * randn(rs, N, 1);       % brightness: shifted
            F(:, 2) = q + 0.8 * randn(rs, N, 1);               % rescore-like
            F(:, 3) = 0.6 * q + shift + randn(rs, N, 1);
            F(:, 4) = 0.3 * q + randn(rs, N, 1);
            F(:, 5) = shift + 0.5 * randn(rs, N, 1);           % local background level
            F(:, 6:8) = randn(rs, N, 3);
            F(rand(rs, N, 1) < 0.05, 2) = NaN;
            S = struct('F', F, 'y', y, 'section', sec, 'animal', secAnimal(sec), 'mu', mu, ...
                'NumSections', nS);
        end

        function lab = anchoredLabels(S, rows, rs)
            %ANCHOREDLABELS  A reviewer confirming pages by default: the cold-start proposal
            %   sets each tile's page default; a tile whose truth differs from its default is caught
            %   with probability 0.75 (likely bad), 0.9 (middle), 0.8 (likely good), else it keeps
            %   the default; a tile that agrees is labeled right 99.5% of the time.
            f2 = S.F(rows, 2);
            p0 = 1 ./ (1 + exp(-2 * (f2 - S.mu / 2)));
            p0(isnan(p0)) = 0.5;
            def = p0 >= 0.5;
            catchP = 0.9 * ones(numel(rows), 1);
            catchP(p0 < 0.15) = 0.75;
            catchP(p0 >= 0.85) = 0.8;
            truth = S.y(rows);
            u = rand(rs, numel(rows), 1);
            lab = def;
            exc = truth ~= def;
            lab(exc & u < catchP) = truth(exc & u < catchP);
            flip = ~exc & u > 0.995;
            lab(flip) = ~def(flip);
        end
    end

    methods (Test)
        function predictEveryRowCount(tc)
            % Finding 1: a chunk of exactly one row crashed forestChunk (a one-row C indexed with a
            % column of indices gives a row vector, which implicit expansion then made square).
            % With 200 trees a chunk is 327 rows, so N = 1, 328, 655, 982 crashed.
            [F, y, g] = tAssistModel.synth(1200, 6, 31);
            m = curation.AssistModel.fit(F, y, g, struct('CVTrees', 10, 'NumTrees', 200, 'Seed', 3));
            step = floor(2 ^ 16 / numel(m.Forest.Roots));
            tc.assertEqual(step, 327, 'rows per forestScore chunk for 200 trees');
            nMax = 3 * step + 2;
            Fq = tAssistModel.synth(nMax, 6, 32);
            Fq(1:7:end, 2) = NaN;
            [~, s] = predict(m.Ensemble, Fq);          % MATLAB's own ensemble predict
            ref = s(:, 2);
            refP = curation.AssistModel.isotonicApply(m.IsoX, m.IsoY, ref);
            bad = zeros(1, 0);
            msg = "";
            for N = 0:nMax
                try
                    r = m.predictRaw(Fq(1:N, :));
                    p = m.predict(Fq(1:N, :));
                    ok = isequal(size(r), [N 1]) && isequal(size(p), [N 1]) ...
                        && all(abs(r - ref(1:N)) <= 1e-12) && all(abs(p - refP(1:N)) <= 1e-6);
                catch ME
                    ok = false;
                    if msg == "", msg = string(ME.message); end
                end
                if ~ok, bad(end + 1) = N; end %#ok<AGROW>
            end
            tc.verifyEmpty(bad, sprintf('predict wrong or failed for N = %s (first error: %s)', ...
                mat2str(bad(1:min(end, 8))), msg));
            tc.verifyEqual(m.predict(zeros(0, 6)), zeros(0, 1), 'N = 0');
            tc.verifyEqual(m.predictRaw(Fq(1, :)), ref(1), 'AbsTol', 1e-12, 'N = 1');
        end

        function oneRowCrossValidationFold(tc)
            % Finding 1: a cross-validation fold of exactly one row (40 CV trees: chunks of 1,638).
            [F, y] = tAssistModel.synth(401, 5, 33);
            g = ["A" + string(mod((1:400)', 4)); "Z"];      % 4 animals of 100 rows + 1 of one row
            m = curation.AssistModel.fit(F, y, g, struct('NumTrees', 20, 'Seed', 2));
            tc.verifyEqual(m.Stats.Folds, 5);
            tc.verifyEqual(nnz(m.Stats.Fold == m.Stats.Fold(401)), 1, 'the one-row animal is a fold');
            tc.verifyTrue(all(isfinite(m.Stats.OofRaw)));
        end

        function predictKeepsTheOrderOfTheRawScore(tc)
            % Finding 2: flat blocks of the isotonic map gave many rows the same P, and consumers
            % then ordered them by CellID. P must keep the order of the raw score.
            [F, y, g] = tAssistModel.synth(3000, 6, 41);
            m = curation.AssistModel.fit(F, y, g, struct('CVTrees', 20, 'NumTrees', 60, 'Seed', 1));
            p = m.predict(F);
            raw = m.predictRaw(F);
            [rs, o] = sort(raw);
            ps = p(o);
            distinct = diff(rs) > 0;
            nTie = nnz(diff(ps) <= 0 & distinct);
            tc.verifyEqual(nTie, 0, sprintf(['%d neighboring pairs of rows with different raw scores ' ...
                'have the same (or reversed) P'], nTie));
            [p2, raw2] = m.predict(F);
            tc.verifyEqual(raw2, raw, '[p, raw] = predict(F)');
            tc.verifyEqual(p2, p);
            tc.verifyLessThan(max(abs(p - curation.AssistModel.isotonicApply(m.IsoX, m.IsoY, raw))), 1e-6, ...
                'the order-keeping ramp moves P by less than 1e-6');
        end

        function calibratedPNeverExactlyZeroOrOne(tc)
            % Finding 3: the lowest / highest isotonic block took its in-sample mean, often exactly
            % 0 or 1, which is overconfident for new data.
            [F, y, g] = tAssistModel.synth(4000, 6, 43);
            m = curation.AssistModel.fit(F, y, g, struct('CVTrees', 20, 'NumTrees', 60));
            ext = [-8 * ones(1, 6); 8 * ones(1, 6)];
            ext(:, 2) = -ext(:, 2);
            p = m.predict([F; ext]);
            tc.verifyGreaterThan(min(p), 0, 'P is never exactly 0');
            tc.verifyLessThan(max(p), 1, 'P is never exactly 1');
            tc.verifyGreaterThan(min(m.Stats.OofP), 0);
            tc.verifyLessThan(max(m.Stats.OofP), 1);
        end

        function syntheticProjectBeatsBaselines(tc)
            % tp -> Good, fp -> Bad, 10 sections of 5 animals; grouped by animal.
            for kind = ["pnn" "pv"]
                [F, y, g, s] = tAssistModel.stack(tc.Project, kind);
                m = curation.AssistModel.fit(F, y, g, struct('Sections', s, 'Kind', kind, 'Seed', 2));
                S = m.Stats;
                fprintf('\n[synthetic %s] n=%d (Good %d, Bad %d), %d folds by %s: model OOF AUC %.4f (on rescore rows %.4f); raw rescore %.4f; cold start %.4f; Brier %.4f; %s\n', ...
                    kind, S.N, S.NGood, S.NBad, S.Folds, S.FoldGrouping, S.AUC, S.AUCModelOnRescoreRows, ...
                    S.AUCRescore, S.AUCColdStart, S.Brier, S.CalibrationSource);
                disp(head(S.Importance, 8));
                tc.verifyEqual(S.Folds, 5);
                tc.verifyEqual(S.FoldGrouping, "groups");
                tc.verifyGreaterThan(S.AUC, 0.97, 'the image features separate cells from background');
                % the model must exceed rescore, or match it within 0.005
                tc.verifyGreaterThanOrEqual(S.AUCModelOnRescoreRows, S.AUCRescore - 0.005);
                tc.verifyGreaterThanOrEqual(S.AUC, S.AUCColdStart - 0.005);
                tc.verifyLessThan(S.Brier, 0.08);
            end
        end

        function smallLabelSetsGetAUsefulModel(tc)
            % (integration pass C, defect 3b) the default leaf size (40) with half-size bags grew
            % single-leaf trees in a cross-validation fold of fewer than ~80 rows: at the label gate
            % the out-of-fold AUC was 0.49 and P nearly constant. The default now follows the rows
            % each ensemble is grown on. 200, 400 and 2,000 labels of 10 animals, default options.
            S0 = tAssistModel.simProject(41, "base");
            rs = RandStream('mt19937ar', 'Seed', 3);
            levels = @(m) numel(unique(round(m.Stats.OofRaw, 4)));
            for n = [200 400 2000]
                rows = randperm(rs, numel(S0.y), n)';
                F = S0.F(rows, :); y = S0.y(rows); g = "A" + string(S0.animal(rows));
                m = curation.AssistModel.fit(F, y, g, struct('Seed', 1));
                S = m.Stats;
                leaf = NaN; leafCV = NaN;
                if isfield(S, 'MinLeafSize'), leaf = S.MinLeafSize; leafCV = S.MinLeafSizeCV; end
                % the old default on the same rows (an explicit MinLeafSize is taken as given)
                m40 = curation.AssistModel.fit(F, y, g, struct('Seed', 1, 'MinLeafSize', 40));
                fprintf(['\n[small label sets] n=%d (Good %d): default: OOF AUC %.3f, P sd %.3f, %d distinct ' ...
                    'out-of-fold scores, leaf %g (final) / %s (folds) | MinLeafSize 40 (the old default): AUC %.3f, ' ...
                    'P sd %.3f, %d distinct scores\n'], n, S.NGood, S.AUC, std(S.OofP), levels(m), leaf, ...
                    mat2str(leafCV), m40.Stats.AUC, std(m40.Stats.OofP), levels(m40));
                tc.verifyGreaterThan(S.AUC, 0.8, sprintf('%d labels: a useful out-of-fold AUC', n));
                tc.verifyGreaterThan(std(S.OofP), 0.15, sprintf('%d labels: P is not nearly constant', n));
                tc.verifyGreaterThan(levels(m), 50, sprintf('%d labels: the folds'' trees split (many score levels)', n));
                tc.verifyLessThanOrEqual(leaf, 40, 'the leaf size used is recorded');
                tc.verifyGreaterThanOrEqual(leaf, 5);
                if n == 200
                    % at the label gate the old default's folds barely split (bags of 80 rows, leaves
                    % of 40): measurably worse here, 0.49 on the real section that found it
                    tc.verifyGreaterThan(S.AUC, m40.Stats.AUC + 0.05, ...
                        '200 labels: the adaptive leaf size beats the old default');
                end
                if isfield(m40.Stats, 'MinLeafSize'), tc.verifyEqual(m40.Stats.MinLeafSize, 40); end
            end
        end

        function groupedFoldsNeverSplitAGroup(tc)
            [F, y, g, s] = tAssistModel.stack(tc.Project, "pnn");
            m = curation.AssistModel.fit(F, y, g, struct('Sections', s, 'CVTrees', 10, 'NumTrees', 10));
            fold = m.Stats.Fold;
            [ug, ~, gi] = unique(g);
            for i = 1:numel(ug)
                tc.verifyNumElements(unique(fold(gi == i)), 1, sprintf('animal %s split', ug(i)));
            end
            tc.verifyNumElements(unique(fold), 5);

            % fewer animals than folds -> sections, and sections are never split
            g2 = repmat("only", numel(y), 1);
            m2 = curation.AssistModel.fit(F, y, g2, struct('Sections', s, 'CVTrees', 10, 'NumTrees', 10));
            tc.verifyEqual(m2.Stats.FoldGrouping, "sections");
            tc.verifySubstring(char(m2.Stats.FoldNote), 'grouped by section');
            [us, ~, si] = unique(s);
            for i = 1:numel(us)
                tc.verifyNumElements(unique(m2.Stats.Fold(si == i)), 1);
            end

            % 3 animals, no sections -> 3 folds by animal
            g3 = "A" + string(mod((1:numel(y))', 3));
            m3 = curation.AssistModel.fit(F, y, g3, struct('CVTrees', 10, 'NumTrees', 10));
            tc.verifyEqual(m3.Stats.Folds, 3);
            tc.verifyEqual(m3.Stats.FoldGrouping, "groups");

            % nothing to group by -> stratified rows, said so
            m4 = curation.AssistModel.fit(F, y, g2, struct('CVTrees', 10, 'NumTrees', 10));
            tc.verifyEqual(m4.Stats.FoldGrouping, "rows");
            tc.verifySubstring(char(m4.Stats.FoldNote), 'NOT grouped');

            % assignGroups directly: balanced and deterministic
            key = repelem("g" + (1:12)', (1:12)');
            f1 = curation.AssistModel.assignGroups(key, 4, 7);
            f2 = curation.AssistModel.assignGroups(key, 4, 7);
            tc.verifyEqual(f1, f2);
            n = accumarray(f1, 1);
            tc.verifyLessThanOrEqual(max(n) - min(n), 12, 'greedy largest-first keeps folds balanced');
        end

        function calibrationOnKnownProbabilities(tc)
            % Fit on 12,000 rows with known P(Good); check calibration on 10,000 fresh rows.
            [F, y, g, ptrue] = tAssistModel.synth(22000, 12, 21);
            tr = 1:12000; te = 12001:22000;
            m = curation.AssistModel.fit(F(tr, :), y(tr), g(tr), struct('Seed', 4));
            tc.verifyTrue(all(diff(m.IsoX) > 0), 'knots strictly increasing in x');
            tc.verifyTrue(all(diff(m.IsoY) >= 0), 'calibration map is monotone');
            [~, o] = sort(m.Stats.OofRaw);
            tc.verifyTrue(all(diff(m.Stats.OofP(o)) >= -1e-12), 'OofP is monotone in the raw score');
            p = m.predict(F(te, :));
            R = curation.AssistModel.reliability(p, y(te), 10);
            Rt = curation.AssistModel.reliability(p, ptrue(te), 10);   % observed = TRUE probability
            fprintf('\n[calibration] fresh 10,000 rows (Observed = labels, TrueP = known probability):\n');
            disp([R table(Rt.Observed, 'VariableNames', {'TrueP'})]);
            big = R.Count >= 200;
            tc.verifyLessThanOrEqual(max(abs(Rt.MeanPredicted(big) - Rt.Observed(big))), 0.05, ...
                'mean predicted within 0.05 of the mean true probability in every bin with >= 200 rows');
            tc.verifyLessThanOrEqual(max(abs(R.MeanPredicted(big) - R.Observed(big))), 0.07, ...
                'and within 0.07 of the observed Good fraction (adds label sampling noise)');
            tc.verifyLessThan(mean(abs(p - ptrue(te))), 0.1, 'close to the true probability');
            tc.verifyLessThan(mean((p - y(te)) .^ 2), 0.19);
            Ro = m.Stats.Reliability;
            tc.verifyEqual(Ro.MeanPredicted(Ro.Count > 0), Ro.Observed(Ro.Count > 0), 'AbsTol', 1e-6, ...
                'isotonic is calibrated on the rows it was fitted on (up to the 5e-7 order ramp)');
            tc.verifyEqual(m.Stats.CalibrationSource, "all out-of-fold rows");
            tc.verifySize(m.Stats.Reliability, [10 6]);
        end

        function calibrateOnBlindRows(tc)
            [F, y, g] = tAssistModel.synth(3000, 8, 3);
            few = false(3000, 1); few(1:50) = true;
            m = curation.AssistModel.fit(F, y, g, struct('CalibrateOn', few, 'CVTrees', 20, 'NumTrees', 20));
            tc.verifySubstring(char(m.Stats.CalibrationSource), 'all out-of-fold rows (only 50');
            tc.verifyEqual(m.Stats.CalibrationRows, 3000);
            many = false(3000, 1); many(1:600) = true;
            m2 = curation.AssistModel.fit(F, y, g, struct('CalibrateOn', many, 'CVTrees', 20, 'NumTrees', 20));
            tc.verifyEqual(m2.Stats.CalibrationSource, "CalibrateOn rows");
            tc.verifySubstring(char(m2.Stats.CalibrationNote), 'random sample');
            tc.verifyEqual(m2.Stats.CalibrationRows, 600);
            [xk, yk] = curation.AssistModel.isotonicFit(m2.Stats.OofRaw(many), y(many), [], 10);
            fl = 0.5 / 601;
            tc.verifyEqual(m2.IsoX, xk);
            tc.verifyEqual(m2.IsoY, min(max(yk, fl), 1 - fl));
            % the default: every out-of-fold row
            m3 = curation.AssistModel.fit(F, y, g, struct('CVTrees', 20, 'NumTrees', 20));
            tc.verifyEqual(m3.Stats.CalibrationSource, "all out-of-fold rows");
            tc.verifyEqual(m3.Stats.CalibrationRows, 3000);
        end

        function tailPoolingUnit(tc)
            % isotonicFit(x, y, [], minTail): the extreme blocks are pooled until the lowest holds
            % minTail Good and the highest minTail Bad, only with neighbors below 0.15 / above
            % 0.85; a tail that cannot reach minTail takes the Jeffreys value. Always monotone.
            x = (1:200)';
            y = zeros(200, 1);
            y([30 70 110 125 140]) = 1;
            y(151:200) = 1;
            y([160 180 195]) = 0;
            % PAV blocks: 0 (1-29), 0.025 (30-109), 1/15 (110-139), 1/11 (140-150), 0.9 (151-160),
            % 33/35 (161-195), 1 (196-200)
            [~, y0] = curation.AssistModel.isotonicFit(x, y);
            tc.verifyEqual(y0(1), 0, 'plain PAV: the lowest block is exactly 0');
            tc.verifyEqual(y0(end), 1, 'and the highest exactly 1');
            [xk, yk] = curation.AssistModel.isotonicFit(x, y, [], 2);
            p = curation.AssistModel.isotonicApply(xk, yk, x);
            tc.verifyTrue(all(diff(p) >= 0), 'monotone');
            tc.verifyEqual(p(1:109), repmat(2 / 109, 109, 1), 'AbsTol', 1e-15, 'lowest: rows 1-109, 2 Good');
            tc.verifyEqual(p(161:200), repmat(38 / 40, 40, 1), 'AbsTol', 1e-15, 'highest: rows 161-200, 2 Bad');
            tc.verifyEqual(p(110), 1 / 15, 'AbsTol', 1e-15, 'inner blocks unchanged');
            % more events wanted than the bands hold: pooled to the band edge, then Jeffreys
            [~, yk] = curation.AssistModel.isotonicFit(x, y, [], 100);
            tc.verifyEqual(unique(yk), [5.5 / 151; 47.5 / 51], 'AbsTol', 1e-15);
            % perfectly separated classes: nothing to pool, both ends Jeffreys
            [xk, yk] = curation.AssistModel.isotonicFit(1:100, [false(60, 1); true(40, 1)], [], 10);
            tc.verifyEqual(xk, [1; 60; 61; 100]);
            tc.verifyEqual(yk, [0.5 / 61; 0.5 / 61; 40.5 / 41; 40.5 / 41], 'AbsTol', 1e-15);
        end

        function pavUnit(tc)
            pav = @curation.AssistModel.pav;
            tc.verifyEqual(pav([0.1 0.2 0.2 0.5]), [0.1; 0.2; 0.2; 0.5], 'monotone input unchanged');
            tc.verifyEqual(pav([1 3 2 4]), [1; 2.5; 2.5; 4], 'one violating pair pooled');
            tc.verifyEqual(pav([3 2 1]), [2; 2; 2], 'decreasing input pooled to its mean');
            tc.verifyEqual(pav([1 0], [3 1]), [0.75; 0.75], 'weights respected');
            tc.verifyEqual(pav([0 1 0 1 0]), [0; 0.5; 0.5; 0.5; 0.5], 'AbsTol', 1e-15);
            tc.verifyEqual(pav(5), 5);
            % ties in x are pooled before PAV
            [xk, yk] = curation.AssistModel.isotonicFit([1 1 2 2], [0 1 1 1]);
            tc.verifyEqual(xk, [1; 2]);
            tc.verifyEqual(yk, [0.5; 1]);
            % x 1 -> 0, x 2 -> 1, x 3 -> {0,1} = 0.5 (weight 2); 1 > 0.5 violates -> (1 + 2*0.5)/3
            [xk, yk] = curation.AssistModel.isotonicFit([2 1 3 3], [1 0 0 1]);
            tc.verifyEqual(xk, [1; 2; 3]);
            tc.verifyEqual(yk, [0; 2/3; 2/3], 'AbsTol', 1e-15);
            % flat runs keep only their end knots; evaluation at the data is unchanged
            x = (1:8)';
            yv = [0 0 0 1 0 1 1 1]';
            [xk, yk] = curation.AssistModel.isotonicFit(x, yv);
            tc.verifyEqual(xk, [1; 3; 4; 5; 6; 8]);
            full = curation.AssistModel.pav(yv);
            tc.verifyEqual(curation.AssistModel.isotonicApply(xk, yk, x), full);
            % interpolation, clamping, NaN
            ap = @curation.AssistModel.isotonicApply;
            tc.verifyEqual(ap([0 1], [0.2 0.8], [0.5 0.25]), [0.5; 0.35], 'AbsTol', 1e-15);
            tc.verifyEqual(ap([0 1], [0.2 0.8], [-1 2]), [0.2; 0.8], 'clamped outside the knots');
            tc.verifyTrue(isnan(ap([0 1], [0.2 0.8], NaN)));
            tc.verifyEqual(ap(0.3, 0.7, [1 2]), [0.7; 0.7], 'one knot: constant');
            tc.verifyEqual(ap([0 1], [-0.5 1.5], [0 1]), [0; 1], 'output clamped to [0, 1]');
            [xk, yk] = curation.AssistModel.isotonicFit([], []);
            tc.verifyEqual([xk yk], [0 0.5]);
        end

        function aucUnit(tc)
            a = @curation.AssistModel.auc;
            tc.verifyEqual(a([1 2 3 4], [0 0 1 1]), 1);
            tc.verifyEqual(a([4 3 2 1], [0 0 1 1]), 0);
            tc.verifyEqual(a([1 1 1 1], [0 1 0 1]), 0.5, 'ties count one half');
            tc.verifyEqual(a([1 2 NaN 3], [0 1 1 1]), 1, 'NaN scores ignored');
            tc.verifyTrue(isnan(a([1 2], [1 1])));
        end

        function nanFeaturesAccepted(tc)
            [F, y, g] = tAssistModel.synth(2000, 6, 9);
            F(:, 6) = NaN;                  % a column with no values at all
            F(1:10, :) = NaN;               % rows with no values at all
            m = curation.AssistModel.fit(F, y, g, struct('CVTrees', 20, 'NumTrees', 30));
            p = m.predict(F);
            tc.verifyTrue(all(isfinite(p)));
            tc.verifyGreaterThanOrEqual(p, 0);
            tc.verifyLessThanOrEqual(p, 1);
            tc.verifyGreaterThan(m.Stats.AUC, 0.7);
            tc.verifyEqual(m.predict(nan(3, 6)), repmat(m.predict(nan(1, 6)), 3, 1));
            tc.verifyError(@() m.predict(F(:, 1:5)), 'curation:AssistModel:badFeatures');
            tc.verifyError(@() curation.AssistModel.fit(F, true(2000, 1), g), 'curation:AssistModel:oneClass');
        end

        function enoughLabelsGates(tc)
            e = @curation.AssistModel.enoughLabels;
            tc.verifyFalse(e([true(30, 1); false(169, 1)]), '199 labels');
            tc.verifyTrue(e([true(30, 1); false(170, 1)]), '200 labels, 30 Good');
            tc.verifyFalse(e([true(29, 1); false(171, 1)]), '29 Good');
            tc.verifyFalse(e([false(29, 1); true(171, 1)]), '29 Bad');
            tc.verifyTrue(e([repmat("Good", 100, 1); repmat("Bad", 100, 1); repmat("Uncertain", 50, 1)]));
            tc.verifyFalse(e([repmat("Good", 100, 1); repmat("Bad", 99, 1); repmat("Uncertain", 50, 1)]), ...
                'Uncertain does not count');
            tc.verifyTrue(e([true(10, 1); false(20, 1)], struct('MinLabels', 30, 'MinPerClass', 10)));
            tc.verifyFalse(e(true(0, 1)));
        end

        function saveLoadRoundTrip(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [F, y, g] = tAssistModel.synth(1500, 6, 12);
            m = curation.AssistModel.fit(F, y, g, struct('CVTrees', 20, 'NumTrees', 40, 'Kind', "pv", ...
                'Ids', "S|" + string((1:1500)')));
            path = fullfile(fx.Folder, 'sub', 'assist_pv.mat');
            m.save(path);
            tc.verifyTrue(isfile(path));
            tc.verifyEmpty(dir(fullfile(fx.Folder, 'sub', '*.tmp.mat')), 'no temp file left');
            m2 = curation.AssistModel.load(path);
            tc.verifyEqual(m2.predict(F), m.predict(F), 'identical predictions');
            tc.verifyEqual(m2.predictRaw(F), m.predictRaw(F));
            tc.verifyEqual(m2.Version, m.Version);
            tc.verifyEqual(m2.Kind, "pv");
            tc.verifyEqual(m2.Stats.Ids, m.Stats.Ids);
            tc.verifyEqual(m2.Stats.AUC, m.Stats.AUC);
            bad = fullfile(fx.Folder, 'x.mat');
            q = 1; save(bad, 'q');
            tc.verifyError(@() curation.AssistModel.load(bad), 'curation:AssistModel:badFile');
        end

        function deterministicWithSeed(tc)
            [F, y, g] = tAssistModel.synth(3000, 8, 13);
            o = struct('Seed', 5, 'CVTrees', 20, 'NumTrees', 50);
            r0 = rng; rng(123);
            before = rand;
            rng(123);
            m1 = curation.AssistModel.fit(F, y, g, o);
            after = rand;
            rng(r0);
            tc.verifyEqual(after, before, 'the global random stream is left as it was');
            m2 = curation.AssistModel.fit(F, y, g, o);
            tc.verifyEqual(m2.predict(F), m1.predict(F));
            tc.verifyEqual(m2.Stats.OofP, m1.Stats.OofP);
            tc.verifyEqual(m2.Stats.Fold, m1.Stats.Fold);
            tc.verifyNotEqual(m2.Version, m1.Version, 'Version is unique per fit (time)');
            tc.verifyEqual(extractAfter(m2.Version, "-"), extractAfter(m1.Version, "-"), ...
                'same training data -> same data hash in Version');
            o.Seed = 6;
            m3 = curation.AssistModel.fit(F, y, g, o);
            tc.verifyNotEqual(m3.predictRaw(F), m1.predictRaw(F), 'another seed, another model');
        end

        function trainingAndBlindMasks(tc)
            T = tAssistModel.maskTable();
            tc.verifyEqual(curation.AssistModel.trainingMask(T), T.ExpTrain);
            tc.verifyEqual(curation.AssistModel.blindMask(T), T.ExpBlind);
            % missing columns take the snapshot defaults
            T2 = T(:, {'CellID', 'Reviewed', 'Label', 'LabelSource'});
            exp2 = T.Reviewed & ismember(T.Label, ["Good" "Bad"]) & ...
                ismember(T.LabelSource, ["human" "confirmed" "blind" "legacy-qc"]);
            tc.verifyEqual(curation.AssistModel.trainingMask(T2), exp2);
            tc.verifyEqual(curation.AssistModel.blindMask(T2), T.LabelSource == "blind");
            % string columns read back as missing are treated as ""
            T3 = T;
            T3.AuditRole(1) = missing;
            tc.verifyEqual(curation.AssistModel.trainingMask(T3), T.ExpTrain);
        end

        function compiledForestMatchesPredict(tc)
            [F, y, g] = tAssistModel.synth(2500, 7, 17);
            m = curation.AssistModel.fit(F, y, g, struct('CVTrees', 10, 'NumTrees', 60));
            Fq = F;
            Fq(1:50, 1:3) = NaN;
            [~, s] = predict(m.Ensemble, Fq);
            tc.verifyEqual(m.predictRaw(Fq), s(:, 2), 'AbsTol', 1e-12);
            tc.verifyEqual(m.predictRaw(zeros(0, 7)), zeros(0, 1));
        end

        function fitsOnBackgroundPool(tc)
            % The app refits on backgroundPool (thread workers: no Java, no figures).
            try
                pool = backgroundPool;
            catch
                pool = [];
            end
            tc.assumeNotEmpty(pool, 'no backgroundPool in this MATLAB');
            [F, y, g] = tAssistModel.synth(2000, 6, 19);
            o = struct('Seed', 8, 'CVTrees', 20, 'NumTrees', 40);
            f = parfeval(pool, @curation.AssistModel.fit, 1, F, y, g, o);
            mb = fetchOutputs(f);
            m = curation.AssistModel.fit(F, y, g, o);
            tc.verifyEqual(mb.predict(F), m.predict(F), 'background fit = foreground fit');
            tc.verifyFalse(mb.Stats.Parallel, 'no pool is started implicitly');
        end
    end

    methods (Test, TestTags = {'Slow'})
        function tailsNotOverconfidentOnFreshSections(tc)
            % Finding 3: the lowest / highest isotonic block is the minimum / maximum of running
            % means, optimistic out of sample (P exactly 0 for ~2% of fresh rows). Fit on 10
            % reviewed sections (true labels), predict the 20 others; 8 seeded projects per regime.
            % The 5% of fresh rows with the lowest (highest) raw score: observed share of cells
            % (non-cells) against the mean P (1 - P). Fixed row sets, so every calibration is
            % compared on the same rows.
            for reg = ["base" "shift"]
                acc = zeros(1, 4);
                nExact = 0; nFresh = 0;
                for seed = 1:8
                    S = tAssistModel.simProject(seed, reg);
                    rs = RandStream('mt19937ar', 'Seed', 500 + seed);
                    secs = randperm(rs, S.NumSections, 10);
                    tr = ismember(S.section, secs);
                    fr = ~tr;
                    m = curation.AssistModel.fit(S.F(tr, :), S.y(tr), string(S.animal(tr)), ...
                        struct('Sections', string(S.section(tr)), 'Seed', seed));
                    p = m.predict(S.F(fr, :));
                    raw = m.predictRaw(S.F(fr, :));
                    yF = S.y(fr);
                    nExact = nExact + nnz(p == 0 | p == 1);
                    nFresh = nFresh + numel(p);
                    [~, o] = sort(raw + 1e-12 * (1:numel(raw))');
                    k = round(0.05 * numel(raw));
                    lo = o(1:k);
                    hi = o(end - k + 1:end);
                    acc = acc + [sum(p(lo)), nnz(yF(lo)), sum(1 - p(hi)), nnz(~yF(hi))];
                end
                rLo = acc(2) / acc(1);
                rHi = acc(4) / acc(3);
                fprintf(['\n[fresh sections, %s] P exactly 0 or 1: %d of %d rows; lowest 5%%: mean P %.3f%%, ' ...
                    'cells %.3f%% (ratio %.2f); highest 5%%: mean 1-P %.3f%%, non-cells %.3f%% (ratio %.2f)\n'], ...
                    reg, nExact, nFresh, 100 * acc(1) / (nFresh * 0.05), 100 * acc(2) / (nFresh * 0.05), rLo, ...
                    100 * acc(3) / (nFresh * 0.05), 100 * acc(4) / (nFresh * 0.05), rHi);
                tc.verifyEqual(nExact, 0, sprintf('%s: %d fresh rows got P exactly 0 or 1', reg, nExact));
                tc.verifyLessThanOrEqual(rLo, 1.25, sprintf(['%s: the lowest 5%% of fresh rows hold %.2f times ' ...
                    'the cells their P promises'], reg, rLo));
                tc.verifyLessThanOrEqual(rHi, 1.25, sprintf(['%s: the highest 5%% hold %.2f times the ' ...
                    'non-cells their P promises'], reg, rHi));
            end
        end
    end

    methods (Test, TestTags = {'Benchmark'})
        function benchmarkFitPredict(tc)
            [F, y, g] = tAssistModel.synth(20000, 30, 5);
            t0 = tic;
            m = curation.AssistModel.fit(F, y, g, struct('Seed', 1));
            tFit = toc(t0);
            Fp = F(1:3000, :);
            m.predict(Fp(1:10, :));
            t = zeros(1, 5);
            for k = 1:5
                t1 = tic;
                p = m.predict(Fp);
                t(k) = toc(t1);
            end
            fprintf('\n[benchmark] AssistModel.fit: 20000 x 30, %d-fold grouped CV (%d trees/fold) + %d trees: %.0f ms (CV %.0f ms; budget 10000 ms)\n', ...
                m.Stats.Folds, m.Stats.TreesCV, m.Stats.TreesFinal, 1000 * tFit, 1000 * m.Stats.CVSeconds);
            fprintf('[benchmark] AssistModel.predict: 3000 rows: %.1f ms (median of 5; budget 150 ms)\n', 1000 * median(t));
            fprintf('[benchmark] out-of-fold AUC %.4f, Brier %.4f\n', m.Stats.AUC, m.Stats.Brier);
            tc.verifySize(p, [3000 1]);
            tc.verifyLessThanOrEqual(tFit, 10);
            tc.verifyLessThanOrEqual(1000 * median(t), 150);
        end
    end
end
