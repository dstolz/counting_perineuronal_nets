classdef tAssistRunner < matlab.unittest.TestCase
    %tAssistRunner  curation.AssistRunner on a two-section synthetic project, in the background
    %   (backgroundPool): the project is read, the holdout chosen, a registered source gets features
    %   and (after the label gate) a model, predictions and raw scores; the model is saved and loaded by
    %   the next runner; the agreement counts use blind labels only; the audit report is built.
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tAssistRunner

    properties
        Folder
        Truth
        Cache
    end

    methods (TestMethodSetup)
        function makeProject(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Folder = fullfile(fx.Folder, 'proj');
            [~, t1] = makeSyntheticDataset(fullfile(tc.Folder, 'SUBJ-ID-9001'), ...
                'BaseName', "SUBJ-ID-9001IHC_sec1", 'Variants', false);
            [~, t2] = makeSyntheticDataset(fullfile(tc.Folder, 'SUBJ-ID-9002'), ...
                'BaseName', "SUBJ-ID-9002IHC_sec1", 'Seed', 2, 'Variants', false);
            tc.Truth = {t1, t2};
            tc.Cache = fullfile(fx.Folder, 'cache');
        end
    end

    methods
        function [st, info, mf] = openSource(tc, i, key)
            sub = sprintf('SUBJ-ID-900%d', i);
            base = sprintf('SUBJ-ID-900%dIHC_sec1', i);
            locs = fullfile(tc.Folder, sub, [base '_proj_' char(key) '_locs.csv']);
            mf = CellDatasetManifest.forCsv(locs);
            st = curation.Store.open(mf, char(key), struct('AutosaveDelay', 0));
            tc.addTeardown(@() tAssistRunner.closeStore(st));
            tif = fullfile(tc.Folder, sub, [base '_proj.tif']);
            pages = [1 2];
            if key == "PV2", pages = [2 1]; end
            rows = table(st.get('CellID'), st.get('X'), st.get('Y'), st.get('score'), st.get('rescore'), ...
                st.get('InLocs'), 'VariableNames', {'CellID', 'X', 'Y', 'score', 'rescore', 'InLocs'});
            info = struct('SourceId', curation.BlindTiles.sourceId(tc.Folder, mf.Folder, mf.Base, key), ...
                'Kind', curation.Proposals.kindOf(key), 'Rows', rows, 'PageT', imread(tif, pages(1)), ...
                'PageC', imread(tif, pages(2)), 'Um', double(st.Meta.UmPerPixel));
        end

        function r = runner(tc, varargin)
            o = struct('RefreshSec', 0, 'CacheDir', tc.Cache, 'MinNewLabels', 150);
            for k = 1:2:numel(varargin), o.(varargin{k}) = varargin{k + 1}; end
            r = curation.AssistRunner(tc.Folder, o);
            tc.addTeardown(@() delete(r));
        end

        function labelByTruth(tc, st, i, key, n, source)
            %labelByTruth  Label the first N rows by the fixture's truth (tp Good, else Bad).
            det = tc.Truth{i}.(char(key)).det;
            ids = st.get('CellID');
            n = min(n, numel(ids));
            good = det.Kind(1:n) == "tp";
            st.setLabel(ids(good), "Good", source);
            st.setLabel(ids(~good), "Bad", source);
            st.flush();
        end
    end

    methods (Static)
        function closeStore(st)
            if ~isempty(st) && isvalid(st)
                st.close();
                delete(st);
            end
        end

        function ev = waitIdle(r, timeout)
            if nargin < 2, timeout = 120; end
            t0 = tic;
            ev = r.step(10);
            all = ev;
            while (r.isBusy() || ev.Busy) && toc(t0) < timeout
                pause(0.1);
                ev = r.step(10);
                all.Index = all.Index || ev.Index;
                all.Holdout = [all.Holdout ev.Holdout];
                all.Predictions = [all.Predictions ev.Predictions];
                all.Fitted = [all.Fitted ev.Fitted];
                all.Report = all.Report || ev.Report;
            end
            if strlength(r.LastError) > 0
                fprintf('[runner] last error: %s\n', r.LastError);
            end
            ev = all;
        end
    end

    methods (Test)
        function readsTheProjectAndChoosesTheHoldout(tc)
            r = tc.runner();
            tc.verifyTrue(r.Background, 'work runs on backgroundPool');
            r.start();
            ev = tAssistRunner.waitIdle(r);
            tc.verifyTrue(ev.Index, r.LastError);
            tc.verifyEqual(r.IndexState, "ready");
            tc.verifyEqual(sort(ev.Holdout), ["pnn" "pv"], 'a holdout list per kind');
            for k = ["pnn" "pv"]
                tc.verifyTrue(isfile(curation.BlindTiles.holdoutPath(tc.Folder, k)));
                L = r.holdout(k);
                tc.verifyGreaterThan(height(L), 5);
            end
            s = r.summary("pnn");
            tc.verifyEqual(s.Mode, "cold");
            tc.verifyEqual(s.Labels, 0);
            % a second runner reads the same lists (never samples again)
            L1 = r.holdout("pnn");
            bytes = fileread(curation.BlindTiles.holdoutPath(tc.Folder, "pnn"));
            r2 = tc.runner();
            r2.start();
            ev2 = tAssistRunner.waitIdle(r2);
            tc.verifyEqual(sort(ev2.Holdout), ["pnn" "pv"], 'the lists are read (and reported to the owner)');
            tc.verifyEqual(fileread(curation.BlindTiles.holdoutPath(tc.Folder, "pnn")), bytes, 'nothing new is chosen');
            tc.verifyEqual(r2.holdout("pnn"), L1);
        end

        function modelSwitchesOnAtTheGateAndPredicts(tc)
            [st1, info1] = tc.openSource(1, "ECM1");
            [st2, info2] = tc.openSource(2, "ECM1");
            r = tc.runner('Holdout', false);
            r.start();
            tAssistRunner.waitIdle(r);
            r.register("s1", info1);
            r.register("s2", info2);
            ev = tAssistRunner.waitIdle(r);
            tc.verifyEmpty(ev.Predictions, 'no model before the label gate');
            tc.verifyFalse(r.hasModel("pnn"));
            % below the gate: 120 labels
            tc.labelByTruth(st1, 1, "ECM1", 120, "human");
            r.noteLabels();
            tAssistRunner.waitIdle(r);
            s = r.summary("pnn");
            tc.verifyEqual(s.Labels, 120);
            tc.verifyEqual(s.Mode, "cold", 'not enough labels yet');
            % over it: 120 + 150
            tc.labelByTruth(st2, 2, "ECM1", 150, "confirmed");
            r.noteLabels();
            ev = tAssistRunner.waitIdle(r);
            tc.verifyEqual(ev.Fitted, "pnn", r.LastError);
            tc.verifyTrue(r.hasModel("pnn"));
            tc.verifyEqual(sort(ev.Predictions), ["s1" "s2"], 'both sources on screen are predicted');
            s = r.summary("pnn");
            tc.verifyEqual(s.Mode, "model");
            tc.verifyEqual(s.Number, 1);
            tc.verifyEqual(s.NTrain, 270);
            tc.verifyEqual(s.NSections, 2);
            tc.verifyEqual(s.NAnimals, 2);
            tc.verifyGreaterThan(s.AUC, 0.6);
            [ok, P] = r.takePredictions("s1");
            tc.verifyTrue(ok);
            tc.verifyEqual(P.Ids, st1.get('CellID'));
            tc.verifyTrue(all(P.P > 0 & P.P < 1));
            tc.verifyEqual(P.Version, r.model("pnn").Version);
            [ok2, ~] = r.takePredictions("s1");
            tc.verifyFalse(ok2, 'taken once');
            raw = r.rawFor("s1", P.Ids([3 1 2]));
            tc.verifyEqual(raw, P.Raw([3 1 2]));
            tc.verifyTrue(isnan(r.rawFor("s1", uint32(999999))));
            tc.verifyTrue(isfile(curation.ProjectIndex.modelPath(tc.Folder, "pnn")), 'the model is saved');
            tc.verifyTrue(isfile(fullfile(tc.Folder, '.cellcuration', 'assist_pnn.json')));
            % fewer than 150 new labels: no refit
            st1.setLabel(st1.get('CellID', 121:140), "Bad", "human");    %#ok<*NASGU>
            r.noteLabels();
            ev = tAssistRunner.waitIdle(r);
            tc.verifyEmpty(ev.Fitted, 'a refit waits for 150 new labels');
            % a new runner (the next session) loads the saved model and predicts at once
            r2 = tc.runner('Holdout', false);
            r2.start();
            tAssistRunner.waitIdle(r2);
            tc.verifyTrue(r2.hasModel("pnn"), 'loaded');
            tc.verifyEqual(r2.summary("pnn").Number, 1);
            r2.register("s1", info1);
            ev = tAssistRunner.waitIdle(r2);
            tc.verifyEqual(ev.Predictions, "s1");
        end

        function agreementCountsBlindLabelsOnly(tc)
            st = tc.openSource(1, "ECM1");
            ids = st.get('CellID');
            st.setLabel(ids(1:40), "Good", "human");          % with a proposal: never counted
            st.setLabel(ids(41:60), "Bad", "confirmed");
            st.setAuditRole(ids(61:70), "holdout");
            st.setLabel(ids(61:70), "Good", "blind");
            st.setLabel(ids(71:72), "Uncertain", "blind");      % not Good or Bad: not counted
            st.flush();
            T = table(st.get('rescore'), st.get('score'), 'VariableNames', {'rescore', 'score'});
            p = curation.Proposals.coldStart(T(61:70, :), "ECM1");
            r = tc.runner('Holdout', false);
            r.start();
            tAssistRunner.waitIdle(r);
            s = r.summary("pnn");
            tc.verifyEqual(s.BlindN, 10, 'only the labels decided blind');
            tc.verifyEqual(s.BlindMatch, nnz(p >= 0.5), 'matched where the proposal said Good');
        end

        function auditReportIsBuilt(tc)
            st = tc.openSource(1, "ECM1");
            ids = st.get('CellID');
            st.setLabel(ids(1:100), "Good", "confirmed");
            st.setAuditRole(ids(1:5), "confirm-audit");
            st.setLabel(ids(1:2), "Bad", "blind");
            st.setLabel(ids(3:5), "Good", "blind");
            st.flush();
            r = tc.runner('Holdout', false);
            r.start();
            tAssistRunner.waitIdle(r);
            r.requestReport();
            ev = tAssistRunner.waitIdle(r);
            tc.verifyTrue(ev.Report);
            [ok, R] = r.takeReport();
            tc.verifyTrue(ok);
            txt = strjoin(R.Text, newline);
            tc.verifySubstring(txt, 'PNN (WFA)');
            tc.verifySubstring(txt, 'of 5 tiles first confirmed by default and later shown again blind, 2 got a different label');
            tc.verifySubstring(txt, '+-1 point');
            tc.verifyNotEmpty(R.Lines);
            tc.verifyEqual(R.Report.Kinds(1).ConfirmAuditN, 5);
        end

        function worksWithoutTheBackground(tc)
            r = tc.runner('Background', false, 'Holdout', false);
            tc.verifyFalse(r.Background);
            r.start();
            ev = r.step(0);
            tc.verifyTrue(ev.Index, 'the work runs inside step');
            tc.verifyEqual(r.IndexState, "ready");
        end

        function jobsOfAnEarlierRegistrationAreDropped(tc)
            % (pass C, review finding d) a feature job queued before a source was closed and opened
            % again with other rows attached its features to the new rows: jobs carry the
            % registration's token now, and rows that do not match are refused
            [~, infoA] = tc.openSource(1, "ECM1");
            r = tc.runner('Background', false);
            r.register("s1", infoA);                          % runs at once (no pool): a done job waits
            infoB = infoA;
            infoB.Rows = infoA.Rows(1:20, :);                 % reopened with other rows ...
            infoB.Um = NaN;                                   % ... whose features fail (no pixel size)
            r.register("s1", infoB);
            r.step(10);
            k = find([r.Sources.Id] == "s1", 1);
            S = r.Sources(k);
            tc.verifyNotEqual(S.FeatState, "ready", 'the earlier job''s features are not the new rows''');
            tc.verifyTrue(isempty(S.F) || size(S.F, 1) == height(infoB.Rows), ...
                sprintf('features of %d rows for %d rows', size(S.F, 1), height(infoB.Rows)));
        end
    end
end
