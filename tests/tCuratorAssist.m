classdef tCuratorAssist < matlab.unittest.TestCase
    %tCuratorAssist  The assist model in CellCurator, through its seams and the store, on a project of
    %   synthetic sections of different animals: cold-start proposals until the label gate, then a
    %   model fitted in the background whose predictions never change the page on screen but do change
    %   the ORDER of the pages after it; a refit after 150 new labels; the agreement meter counts blind
    %   decisions only; the Audit report tab and its saved files. Benchmark (tag): label-key latency
    %   while a background fit runs, and the time to apply new predictions to a 2,000-row source.
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorAssist   (+ -IncludeSlow: benchmark)

    properties (Constant)
        Budget = struct('KeyWhileFit', 30, 'Apply', 50)
    end

    properties
        Root
        Proj
        Truth
        Cache
    end

    methods (TestMethodSetup)
        function makeProject(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fx.Folder;
            tc.Cache = fullfile(fx.Folder, 'cache');
        end
    end

    methods
        function makeSections(tc, n, varargin)
            tc.Proj = fullfile(tc.Root, 'proj');
            tc.Truth = cell(1, n);
            for i = 1:n
                [~, tc.Truth{i}] = makeSyntheticDataset(fullfile(tc.Proj, sprintf('SUBJ-ID-900%d', i)), ...
                    'BaseName', sprintf("SUBJ-ID-900%dIHC_sec1", i), 'Seed', i, 'Variants', false, varargin{:});
            end
        end

        function labelSection(tc, i, n)
            %labelSection  N labels by the fixture's truth on section I's ECM1 (headless, before the app).
            locs = fullfile(tc.Proj, sprintf('SUBJ-ID-900%d', i), sprintf('SUBJ-ID-900%dIHC_sec1_proj_ECM1_locs.csv', i));
            st = curation.Store.open(CellDatasetManifest.forCsv(locs), 'ECM1', struct('AutosaveDelay', 0));
            det = tc.Truth{i}.ECM1.det;
            ids = st.get('CellID');
            n = min(n, numel(ids));
            good = det.Kind(1:n) == "tp";
            st.setLabel(ids(good), "Good", "human");
            st.setLabel(ids(~good), "Bad", "human");
            st.flush();
            st.close();
            delete(st);
        end

        function app = openApp(tc, varargin)
            o = struct('RefreshSec', 0, 'MinNewLabels', 150, 'Holdout', false, 'MissingFeatIdleSec', 0, ...
                'CacheDir', tc.Cache);
            for k = 1:2:numel(varargin), o.(varargin{k}) = varargin{k + 1}; end
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', true, 'ConfirmAudit', false, ...
                'AssistOptions', o);
            tc.addTeardown(@() tCuratorAssist.closeApp(app));
            app.openParent(tc.Proj, '', 'ECM1');
            app.waitForLayout();
            tc.assertEqual(app.Page.Kind, "active", app.StatusText);
            tc.assertTrue(contains(app.Session.SourceId, "9001"), 'section 1 first');
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function t = text(app, tag)
            t = string(findall(app.Figure, 'Tag', tag).Text);
        end

        function T = table(st)
            T = table(st.get('CellID'), st.get('State'), st.get('Reviewed'), st.get('Excluded'), ...
                st.get('Label'), st.get('Flag'), st.get('LabelSource'), st.get('InLocs'), ...
                st.get('Origin'), st.get('score'), st.get('rescore'), st.get('ModelP'), st.get('AuditRole'), ...
                'VariableNames', {'CellID', 'State', 'Reviewed', 'Excluded', 'Label', 'Flag', ...
                'LabelSource', 'InLocs', 'Origin', 'score', 'rescore', 'ModelP', 'AuditRole'});
        end

        function v = p90(x)
            x = sort(x(:));
            v = x(max(1, ceil(0.9 * numel(x))));
        end
    end

    methods (Test)
        function modelSwitchesOnRefitsAndReordersLaterPages(tc)
            tc.makeSections(2, 'NumCells', [300 180]);
            tc.labelSection(2, 150);
            app = tc.openApp();
            r = app.Assist;
            app.waitForAssist();
            tc.verifyTrue(r.Background, 'the work runs on backgroundPool');
            s = r.summary("pnn");
            tc.verifyEqual(s.Mode, "cold", 'below the label gate: the cold start');
            tc.verifyEqual(s.Labels, 150);
            src = tCuratorAssist.text(app, 'lbl:assistSource');
            tc.verifySubstring(src, 'rescore (cold start)');
            tc.verifySubstring(src, 'the model starts at 200 labels with 30 of each class; you have 150');
            tc.verifyTrue(all(isnan(app.Store.get('ModelP'))), 'no model predictions yet');
            % one confirmed page passes the gate: the model is fitted in the background
            app.handleKey('return', {});
            P = app.Page;
            shown = app.Gallery.Ids;
            app.waitForAssist();
            tc.assertTrue(r.hasModel("pnn"), r.LastError);
            S1 = r.Sources(1);
            fprintf(['[assist] registered %d; sources %s; feat %s; predicting %d pending %d version "%s" (model "%s"); ' ...
                'jobs: %s; last error "%s"; fits %s\n'], app.Session.Registered, ...
                strjoin([r.Sources.Id], ','), strjoin([r.Sources.FeatState], ','), S1.Predicting, S1.Pending, S1.Version, ...
                r.model("pnn").Version, strjoin(r.jobSummary(), ' | '), r.LastError, strjoin(r.FitLog, ' | '));
            tc.verifyGreaterThanOrEqual(app.Counters.ModelApplies, 1, 'predictions applied');
            % the page on screen is untouched
            tc.verifyEqual(app.Page.PageId, P.PageId, 'the page on screen never changes');
            tc.verifyEqual(app.Page.Ids, P.Ids);
            tc.verifyEqual(app.Page.P, P.P, 'its proposals stay as shown');
            tc.verifyEqual(app.Page.Default, P.Default);
            tc.verifyEqual(app.Gallery.Ids, shown);
            st = app.Store;
            un = st.get('Label') == "" & st.get('State') == "active";
            mp = st.get('ModelP');
            tc.verifyTrue(all(isfinite(mp(un))), 'every undecided cell has a model P');
            tc.verifyEqual(unique(st.get('ModelVersion')), r.model("pnn").Version);
            s = r.summary("pnn");
            src = tCuratorAssist.text(app, 'lbl:assistSource');
            tc.verifySubstring(src, sprintf('model 1 %s trained on %s labels from 2 sections of 2 animals', ...
                char(183), CellCurator.fmtInt(s.NTrain)));
            tc.verifySubstring(tCuratorAssist.text(app, 'lbl:assistAccuracy'), 'out of fold');
            % the ORDER of the next page follows the model, not the cold start
            T = tCuratorAssist.table(st);
            keep = ~ismember(T.CellID, P.Ids);
            T = T(keep, :);
            ps = prod(app.Gallery.Grid);
            raw = r.rawFor(app.Session.Id, T.CellID);
            pm = curation.Queues.review(T, curation.Proposals.current(T, "ECM1"), struct('PageSize', ps, 'Raw', raw));
            Tc = T;
            Tc.ModelP(:) = NaN;
            pc = curation.Queues.review(Tc, curation.Proposals.coldStart(Tc, "ECM1"), struct('PageSize', ps));
            tc.assumeFalse(isequal(pm(1).Ids, pc(1).Ids), 'the model orders differently from the cold start here');
            app.handleKey('return', {});
            tc.verifyEqual(app.Page.Ids, pm(1).Ids, 'the next page is the model''s first page');
            tc.verifyNotEqual(app.Page.Ids, pc(1).Ids, 'not the cold start''s');
            % 150 new labels: a refit in the background, model 2
            nRev0 = nnz(st.get('Reviewed'));
            for k = 1:20
                if nnz(st.get('Reviewed')) - nRev0 >= 160 || app.Page.Kind ~= "active", break; end
                app.handleKey('return', {});
            end
            tc.assumeGreaterThanOrEqual(nnz(st.get('Reviewed')) - nRev0, 150, 'enough cells left for 150 new labels');
            app.waitForAssist();
            s2 = r.summary("pnn");
            fprintf('[assist] fits: %s\n', strjoin(r.FitLog, ' | '));
            tc.verifyEqual(s2.Number, 2, 'refitted after 150 new labels');
            tc.verifyEqual(r.Counters.Fits, 2, strjoin(r.FitLog, ' | '));
            tc.verifyTrue(isfile(curation.ProjectIndex.modelPath(tc.Proj, "pnn")), 'the model is kept with the data');
        end

        function agreementMeterUsesBlindLabelsOnly(tc)
            tc.makeSections(1);
            app = tc.openApp();
            app.waitForAssist();
            tc.verifySubstring(tCuratorAssist.text(app, 'lbl:assistAgreement'), 'not enough audit tiles yet (0 of 30');
            st = app.Store;
            ids = st.get('CellID');
            n = numel(ids);
            st.setLabel(ids(n - 79:n - 40), "Good", "human");           % with a proposal in view: never counted
            st.setAuditRole(ids(n - 39:n), "holdout");
            st.setLabel(ids(n - 39:n - 5), "Good", "blind");
            st.flush();
            app.waitForAssist();
            T = tCuratorAssist.table(st);
            b = T.LabelSource == "blind";
            p = curation.Proposals.current(T(b, :), "ECM1");
            agr = tCuratorAssist.text(app, 'lbl:assistAgreement');
            tc.verifySubstring(agr, 'Judged blind: 35 tiles');
            tc.verifySubstring(agr, sprintf('matched your decision on %d%%', round(100 * nnz(p >= 0.5) / 35)));
        end

        function auditReportTabAndSavedFiles(tc)
            tc.makeSections(1);
            app = tc.openApp();
            st = app.Store;
            ids = st.get('CellID');
            st.setLabel(ids(1:60), "Good", "confirmed");
            st.setAuditRole(ids(1:6), "confirm-audit");
            st.setLabel(ids(1:2), "Bad", "blind");
            st.setLabel(ids(3:6), "Good", "blind");
            st.flush();
            save = findall(app.Figure, 'Tag', 'btn:saveReport');
            tc.verifyFalse(logical(save.Enable), 'nothing to save yet');
            tc.verifySubstring(save.Tooltip, 'unavailable now');
            app.requestReport();
            tc.verifySubstring(char(app.StatusText), 'Building the audit report');
            app.waitForAssist();
            tc.assertNotEmpty(app.AuditReport);
            tg = findall(app.Figure, 'Tag', 'tg:right');
            tc.verifyEqual(string(tg.SelectedTab.Tag), "tab:audit", 'the Audit tab comes to the front');
            txt = strjoin(string(findall(app.Figure, 'Tag', 'ta:audit').Value), newline);
            tc.verifySubstring(txt, 'PNN (WFA)');
            tc.verifySubstring(txt, 'of 6 tiles first confirmed by default and later shown again blind, 2 got a different label');
            tc.verifySubstring(txt, '+-1 point');
            tc.verifyTrue(logical(save.Enable));
            files = app.saveReport();
            tc.verifyNumElements(files, 4, '.txt, .csv, _sections.csv, _bands.csv');
            for f = files'
                tc.verifyTrue(isfile(f), f);
                tc.verifySubstring(f, fullfile(tc.Proj, '.cellcuration', 'audit_report_'));
            end
            tc.verifySubstring(fileread(files(1)), 'PNN (WFA)');
            T = readtable(files(2), 'TextType', 'string');
            tc.verifyEqual(T.ConfirmAuditN(T.Kind == "pnn"), 6, 'one row per channel kind');
            tc.verifySubstring(char(app.StatusText), 'Audit report saved');
        end

        function assistBlockFollowsEachConfirmedPage(tc)
            % (pass C, item 6) the Assist block's label count follows a confirmed page at the next idle
            % moment, not the folder's next read (RefreshSec, here 10 minutes)
            tc.makeSections(1);
            app = tc.openApp('RefreshSec', 600);
            app.waitForAssist();
            before = tCuratorAssist.text(app, 'lbl:assistSource');
            n0 = str2double(regexp(before, 'you have (\d+)', 'tokens', 'once'));
            tc.assertTrue(isfinite(n0), before);
            P = app.Page;
            app.handleKey('return', {});
            pause(0.5); drawnow;
            after = tCuratorAssist.text(app, 'lbl:assistSource');
            n1 = str2double(regexp(after, 'you have (\d+)', 'tokens', 'once'));
            fprintf('[assist] %s -> %s\n', before, after);
            tc.verifyEqual(n1, n0 + numel(P.Ids), 'the confirmed page counts at once');
        end
    end

    methods (Test, TestTags = {'Benchmark'})
        function benchmarkKeysWhileFittingAndApplying(tc)
            % a real-size source (~2,000 rows of ECM1) and a second, fully labelled section: every label
            % change refits (MinNewLabels 1), so a fit is in flight while the keys are timed
            t0 = tic;
            tc.makeSections(2, 'ImageSize', [3277 2355], 'NumCells', [1250 1250]);
            tc.labelSection(2, 5000);
            fprintf('\n[assist-perf] fixture: 2 real-size sections written and section 2 labelled in %.1f s\n', toc(t0));
            app = tc.openApp('MinNewLabels', 1);
            r = app.Assist;
            n0 = app.Store.counts().total;
            fprintf('[assist-perf] ECM1 of section 1: %d rows; page %d tiles\n', n0, numel(app.Page.Ids));
            t0 = tic;
            app.waitForAssist(300);
            fprintf('[assist-perf] project read, features, first fit and predictions: %.1f s (fits %d)\n', toc(t0), r.Counters.Fits);
            tc.assertTrue(r.hasModel("pnn"), r.LastError);
            % keys without a fit in flight (reference)
            [tIdle, ~] = tCuratorAssist.keySeries(app, 20, 3, @() true);
            % keys while a fit runs in the background
            fitting = @() r.summary("pnn").Refitting;
            tKeys = [];
            applies = [];
            tEnd = tic;
            while numel(tKeys) < 30 && toc(tEnd) < 300
                app.Store.setLabel(app.Store.get('CellID', 1), "Good", "human");   % a new label: a refit
                app.Store.setLabel(app.Store.get('CellID', 1), "", "human");
                app.Store.setLabel(app.Store.get('CellID', 2), "Bad", "human");
                for k = 1:40                                   % the idle steps start the refit
                    pause(0.1);
                    drawnow;
                    if fitting(), break; end
                end
                if ~fitting(), continue; end
                % keys in quick succession: a fit of these label counts takes well under a second
                % (pass C, the adaptive leaf size), so a key every 0.25 s caught one or two of them
                [t, ok] = tCuratorAssist.keySeries(app, 10, 0, fitting, 0.05);
                tKeys = [tKeys; t(ok)]; %#ok<AGROW>
                c0 = app.Counters.ModelApplies;
                for k = 1:100
                    pause(0.1);
                    drawnow;
                    if app.Counters.ModelApplies > c0, break; end
                end
                if app.Counters.ModelApplies > c0
                    applies(end + 1, 1) = app.LastTimings.ApplyModelMs; %#ok<AGROW>
                end
            end
            fprintf('[assist-perf] fits run: %d; predictions applied: %d\n', r.Counters.Fits, app.Counters.ModelApplies);
            fprintf('\n[assist-perf] ============ CellCurator assist budgets (ms) ============\n');
            fprintf('[assist-perf] %-52s %8s %8s %8s %8s\n', 'action', 'median', 'p90', 'max', 'budget');
            fprintf('[assist-perf] %-52s %8.1f %8.1f %8.1f %8s  (n=%d)\n', 'label key -> border, no fit running', ...
                median(tIdle), tCuratorAssist.p90(tIdle), max(tIdle), '-', numel(tIdle));
            fprintf('[assist-perf] %-52s %8.1f %8.1f %8.1f %8.0f  (n=%d)\n', 'label key -> border, a fit running in the background', ...
                median(tKeys), tCuratorAssist.p90(tKeys), max(tKeys), tc.Budget.KeyWhileFit, numel(tKeys));
            fprintf('[assist-perf] %-52s %8.1f %8.1f %8.1f %8.0f  (n=%d, %d rows)\n', 'apply new predictions (between pages)', ...
                median(applies), tCuratorAssist.p90(applies), max(applies), tc.Budget.Apply, numel(applies), n0);
            fprintf('[assist-perf] ======================================================\n');
            tc.assertGreaterThanOrEqual(numel(tKeys), 10, 'keys were timed while a fit ran');
            tc.verifyLessThanOrEqual(median(tKeys), tc.Budget.KeyWhileFit, ...
                sprintf('label key while fitting: median %.1f ms', median(tKeys)));
            tc.assertNotEmpty(applies);
            tc.verifyLessThanOrEqual(median(applies), tc.Budget.Apply, ...
                sprintf('applying predictions: median %.1f ms', median(applies)));
        end
    end

    methods (Static)
        function [t, ok] = keySeries(app, n, w, condition, settle)
            %keySeries  N label keys (after W warm-up keys) on ordinary tiles of the page: ms from the
            %   call until drawnow returned; OK: CONDITION() held before and after the key. SETTLE s
            %   (default 0.2) between the hover and the key.
            if nargin < 5, settle = 0.2; end
            K = numel(app.Page.Ids);
            t = zeros(n + w, 1);
            ok = false(n + w, 1);
            blind = app.Page.Blind;
            if numel(blind) ~= K, blind = false(K, 1); end
            tiles = find(~blind);
            for i = 1:n + w
                k = tiles(mod(7 * i, numel(tiles)) + 1);
                app.hoverTile(k);
                drawnow;
                pause(settle);
                drawnow;
                key = 'b';
                if app.Store.get('Label', app.Page.Ids(k)) == "Bad", key = 'x'; end
                c1 = condition();
                t1 = tic;
                app.handleKey(key, {});
                drawnow;
                t(i) = 1000 * toc(t1);
                ok(i) = c1 && condition();
            end
            t = t(w + 1:end);
            ok = ok(w + 1:end);
        end
    end
end
