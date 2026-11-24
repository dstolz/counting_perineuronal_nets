classdef tCuratorTraining < matlab.unittest.TestCase
    %tCuratorTraining  The Training tab of CellCurator (integration pass C, item 5): the Training...
    %   button opens it (within 300 ms) with what the curated labels can train for the channel kind on
    %   screen; the three exports run through the tab's own code (the folder picker is a seam); the
    %   detector export is off, saying what is missing, until a section is complete and swept; the
    %   export's plain-text summary shows; the detector command goes to the clipboard and the tab;
    %   (Slow, Python) a one-epoch fine-tune on the CPU through the tab, deployed as a model folder.
    %   Saves curator_training.png.
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorTraining [-IncludeSlow]

    properties
        Root
        Parent
        Truth
        Chosen = {}
    end

    methods (TestMethodSetup)
        function makeProject(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_NO_CLIENT', '1'));
            tc.Root = fx.Folder;
            tc.Parent = fullfile(tc.Root, 'project');
            % 4 sections of 3 animals, PV labelled; sections 1 and 3 complete and swept
            tc.Truth = tExportStage2.makeProject(tc.Parent, tExportStage1.LAYOUT, @tExportStage1.labelAll);
        end
    end

    methods
        function app = openApp(tc, trainerOpts)
            if nargin < 2, trainerOpts = struct(); end
            tOpts = struct('ChooseFolderFcn', @(s, t) tc.nextChoice(), ...
                'ChooseFileFcn', @(f, t, d) tc.nextFile(), ...
                'ExportOptions', struct('MinPerClass', 5), 'TrainerOptions', trainerOpts, ...
                'CacheDir', fullfile(tc.Root, 'cache'));
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'ConfirmAudit', false, ...
                'AssistOptions', struct('CacheDir', fullfile(tc.Root, 'cache'), 'Holdout', false), ...
                'TrainingOptions', tOpts);
            tc.addTeardown(@() tCuratorTraining.closeApp(app));
            app.openParent(tc.Parent, 'SUBJ-ID-9103IHC_sec1_proj', 'PV2');
            app.waitForLayout();
            app.waitForAssist(120);
        end

        function f = nextChoice(tc)
            f = tc.Chosen{1};
            tc.Chosen(1) = [];
        end

        function [fn, fp] = nextFile(tc)
            [fp, n, e] = fileparts(tc.nextChoice());
            fn = [n e];
        end

        function reviewOnePage(tc, app)
            %reviewOnePage  Open the ECM1 channel of the section on screen (unlabelled) and confirm a
            %   page there: the review keys work while the Training tab shows or a fine-tune runs.
            t = tc.Truth.(matlab.lang.makeValidName(tExportStage1.LAYOUT(4, 2)));
            app.openSource(t.paths.ecm1Locs);
            tc.assertEqual(app.SourceKey, "ECM1", app.StatusText);
            P = app.Page;
            tc.assertEqual(P.Kind, "active");
            pause(1.5); drawnow;                  % the opening's idle work done (the budget's condition)
            counting = app.Training.isCounting();
            jobs = "";
            if ~isempty(app.Assist), jobs = strjoin(app.Assist.jobSummary(), ", "); end
            t0 = tic;
            app.handleKey('return', {});
            drawnow;
            fprintf(['[training] Enter -> next page with the Training tab showing: %.0f ms (a count running: %d; ' ...
                'assist jobs then: %s)\n'], 1000 * toc(t0), counting, jobs);
            tc.verifyNotEqual(app.Page.PageId, P.PageId, 'Enter moved on');
            tc.verifyTrue(all(app.Store.get('LabelSource', P.Ids(~P.Blind)) == "confirmed"));
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app), delete(app); end
        end

        function h = byTag(app, tag)
            h = findall(app.Figure, 'Tag', tag);
            h = h(1);
        end

        function push(app, tag)
            b = tCuratorTraining.byTag(app, tag);
            b.ButtonPushedFcn(b, []);
            drawnow;
        end

        function [t, held] = keyTimes(app, n, condition)
            %keyTimes  N label keys on tiles of the page: ms from the call until drawnow returned;
            %   HELD: CONDITION() held before and after the key.
            K = numel(app.Page.Ids);
            t = zeros(n, 1);
            held = false(n, 1);
            for i = 1:n
                k = mod(7 * i, K) + 1;
                app.hoverTile(k);
                drawnow;
                key = 'b';
                if app.Store.get('Label', app.Page.Ids(k)) == "Bad", key = 'x'; end
                c1 = condition();
                t0 = tic;
                app.handleKey(key, {});
                drawnow;
                t(i) = 1000 * toc(t0);
                held(i) = c1 && condition();
            end
        end

        function makeLargeProject(parent, nAnimals, nSections)
            %makeLargeProject  NANIMALS x NSECTIONS small synthetic sections (two sources each): half
            %   of every PV2 source labelled by a person (true cells Good, false ones Bad); the odd
            %   sections' PV2 marked complete and swept.
            k = 0;
            for a = 1:nAnimals
                for s = 1:nSections
                    k = k + 1;
                    base = sprintf('SUBJ-ID-93%02dIHC_sec%d', a, s);
                    [~, t] = makeSyntheticDataset(fullfile(parent, sprintf('SUBJ-ID-93%02d', a), sprintf('sec%d', s)), ...
                        'BaseName', base, 'Seed', 300 + k, 'Variants', false, 'ImageSize', [240 320], ...
                        'NumCells', [20 30]);
                    st = curation.Store.openCsv(t.paths.pv2Locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
                    det = t.PV2.det;
                    tp = find(det.Kind == "tp");
                    fp = find(det.Kind == "fp");
                    st.setLabel(tp(1:ceil(end / 2)), "Good", "human");
                    st.setLabel(fp(1:ceil(end / 2)), "Bad", "human");
                    if mod(k, 2) == 1
                        st.setSweepDone(true);
                        st.setComplete(true);
                    end
                    st.close();
                end
            end
        end

        function saveScreen(fig, name)
            d = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'test_logs', 'screens');
            if ~isfolder(d), mkdir(d); end
            file = fullfile(d, name);
            drawnow; pause(0.8); drawnow;
            try
                exportapp(fig, file);
            catch
                F = getframe(fig);
                imwrite(F.cdata, file);
            end
            fprintf('[screens] %s\n', file);
        end
    end

    methods (Test)
        function tabOpensWithWhatCanBeTrained(tc)
            app = tc.openApp();
            tc.assertEqual(app.SourceKey, "PV2");
            t1 = tic;
            tCuratorTraining.push(app, 'btn:training');
            ms = 1000 * toc(t1);
            fprintf('[training] Training... -> tab shown: %.0f ms (panel refresh %.0f ms)\n', ms, app.Training.LastRefreshMs);
            tc.verifyLessThanOrEqual(ms, 300, 'opening the Training tab within 300 ms');
            tg = tCuratorTraining.byTag(app, 'tg:right');
            tc.verifyEqual(tg.SelectedTab.Tag, 'tab:training');
            % the counts follow in the background: until then the tab says so, exports wait for them
            if ~app.Training.Summary.HasCounts
                tc.verifySubstring(string(tCuratorTraining.byTag(app, 'lbl:trainCounts').Text), ...
                    'Counting what can be exported');
                e2 = tCuratorTraining.byTag(app, 'btn:trainExport2');
                tc.verifyFalse(logical(e2.Enable));
                tc.verifySubstring(e2.Tooltip, 'counting what can be exported');
            end
            tc.assertTrue(app.Training.waitForCounts(120), 'the counts came');
            fprintf('[training] counts shown %.0f ms after the click (the count itself %.0f ms, %d sources)\n', ...
                app.Training.LastCountWallMs, 1000 * app.Training.Summary.CountSec, app.Training.Summary.SourcesRead);
            S = app.Training.Summary;
            tc.verifyEqual(S.Kind, "pv");
            tc.verifyGreaterThan(S.Good, 0);
            tc.verifyGreaterThan(S.Bad, 0);
            tc.verifyEqual(S.Animals, 3);
            tc.verifyEqual(S.Swept, 2, 'sections 1 and 3 are complete and swept');
            tc.verifyEqual(S.Complete, 3);
            txt = string(tCuratorTraining.byTag(app, 'lbl:trainCounts').Text);
            tc.verifySubstring(txt, sprintf('%d Good', S.Good));
            tc.verifySubstring(txt, '2 of 4 sources complete and swept');
            meaning = string(tCuratorTraining.byTag(app, 'lbl:trainMeaning').Text);
            tc.verifySubstring(meaning, 'changes the meaning of rescore');
            % nothing exported yet: the fine-tune and the detector command say what comes first
            ft = tCuratorTraining.byTag(app, 'btn:trainFineTune');
            tc.verifyFalse(logical(ft.Enable));
            tc.verifySubstring(ft.Tooltip, 'export a scorer training set first');
            cc = tCuratorTraining.byTag(app, 'btn:trainCopyCmd');
            tc.verifyFalse(logical(cc.Enable));
            tc.verifySubstring(cc.Tooltip, 'export a detector training set first');
            % Stage 2 through the button (the folder picker answered by the seam)
            out2 = fullfile(tc.Root, 'exp2');
            tc.Chosen = {out2};
            tCuratorTraining.push(app, 'btn:trainExport2');
            tc.verifyTrue(isfile(fullfile(out2, 'export_report.json')), app.StatusText);
            tc.verifyEqual(string(app.Training.LastStage2), string(out2));
            sm = strjoin(string(tCuratorTraining.byTag(app, 'ta:trainSummary').Value), newline);
            tc.verifySubstring(sm, 'Curated export: stage2, kind pv');
            tc.verifySubstring(sm, 'assumed');
            tc.verifySubstring(char(app.StatusText), 'Exported the scorer training set');
            tc.verifyTrue(logical(ft.Enable), 'the fine-tune can start now');
            % Stage 1 and the command
            out1 = fullfile(tc.Root, 'exp1');
            tc.Chosen = {out1};
            tCuratorTraining.push(app, 'btn:trainExport1');
            tc.verifyTrue(isfile(fullfile(out1, 'train', 'annotations.csv')), app.StatusText);
            tCuratorTraining.push(app, 'btn:trainCopyCmd');
            cmd = string(strjoin(tCuratorTraining.byTag(app, 'ta:trainCommand').Value, newline));
            tc.verifySubstring(cmd, 'train.py');
            tc.verifySubstring(cmd, 'experiment=curated/fasterrcnn_640');
            tc.verifySubstring(cmd, strrep(out1, '\', '/'));
            clip = "";
            try clip = string(clipboard('paste')); catch, end
            if strlength(clip) > 0
                tc.verifyEqual(clip, app.Training.LastCommand, 'the command is on the clipboard');
                tc.verifySubstring(char(app.StatusText), 'Copied the detector training command');
            else
                % the hidden test desktop has no clipboard: the tab says so and shows the command
                tc.verifySubstring(char(app.StatusText), 'clipboard is not available');
            end
            % the observation table
            obs = fullfile(tc.Root, 'obs', 'observations_pv.csv');
            mkdir(fileparts(obs));
            tc.Chosen = {obs};
            tCuratorTraining.push(app, 'btn:trainExportObs');
            tc.verifyTrue(isfile(obs), app.StatusText);
            tCuratorTraining.saveScreen(app.Figure, 'curator_training.png');
            % review goes on with the tab showing (the PNN channel still has cells to review); the
            % tab follows the channel kind on screen, from the same count of the folder
            n0 = app.Training.CountsStarted;
            tc.reviewOnePage(app);
            pause(0.6); drawnow;                  % (the panels follow at the next idle moment)
            tc.verifyEqual(app.Training.Summary.Kind, "pnn");
            tc.verifyTrue(app.Training.Summary.HasCounts);
            tc.verifyEqual(app.Training.CountsStarted, n0, 'no count of the folder for a source switch or a page');
            tc.verifyGreaterThan(app.Training.Summary.Good + app.Training.Summary.Bad, 0, ...
                'the confirmed PNN page is counted');
        end

        function aLargeProjectIsCountedOffTheClick(tc)
            % 40 sources (20 sections of 5 animals, two channels each), no assist runner: the tab
            % shows within the budget while the folder is counted in the background (once, both
            % kinds); going back to the tab shows the counts without a recount; a confirmed page is
            % counted from the open store in memory at the next idle moment (no file, no worker)
            parent = fullfile(tc.Root, 'large');
            t0 = tic;
            tCuratorTraining.makeLargeProject(parent, 5, 4);
            fprintf('\n[training] large project: 40 sources written and labelled in %.1f s\n', toc(t0));
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, 'ConfirmAudit', false, ...
                'TrainingOptions', struct('CacheDir', fullfile(tc.Root, 'cache2')));
            tc.addTeardown(@() tCuratorTraining.closeApp(app));
            app.openParent(parent, 'SUBJ-ID-9301IHC_sec2_proj', 'PV2');      % (a section not complete)
            app.waitForLayout();
            tc.assertEqual(app.SourceKey, "PV2", app.StatusText);
            pause(0.5); drawnow;
            P = app.Training;
            t1 = tic;
            tCuratorTraining.push(app, 'btn:training');
            ms = 1000 * toc(t1);
            txt = string(tCuratorTraining.byTag(app, 'lbl:trainCounts').Text);
            tc.verifyTrue(P.Summary.HasCounts || contains(txt, 'Counting what can be exported'), txt);
            % label keys while the folder is counted (a thread worker shares MATLAB's process)
            [tDuring, during] = tCuratorTraining.keyTimes(app, 6, @() P.isCounting());
            tc.assertTrue(P.waitForCounts(180), 'the counts came');
            S = P.Summary;
            fprintf(['[training] %d sources: Training... -> tab shown %.0f ms (panel refresh %.0f ms); the count ' ...
                '%.0f ms in the background; counts shown %.0f ms after the click\n'], S.SourcesRead, ms, ...
                P.LastRefreshMs, 1000 * S.CountSec, P.LastCountWallMs);
            tc.verifyLessThanOrEqual(ms, 300, 'the tab shows within 300 ms, whatever the size of the project');
            tc.verifyEqual(S.SourcesRead, 40);
            tc.verifyEqual(S.Sources, 20, 'the PV sources');
            tc.verifyEqual(S.Animals, 5);
            tc.verifyEqual(S.Complete, 10);
            tc.verifyEqual(S.Swept, 10);
            tc.verifyGreaterThan(S.Good, 0);
            n0 = P.CountsStarted;
            tc.verifyEqual(n0, 1, 'one count of the folder');
            % back to the tab: the counts at once, no recount
            tg = tCuratorTraining.byTag(app, 'tg:right');
            tg.SelectedTab = tCuratorTraining.byTag(app, 'tab:inspector');
            tg.SelectionChangedFcn(tg, []);
            t2 = tic;
            tCuratorTraining.push(app, 'btn:training');
            ms2 = 1000 * toc(t2);
            pause(0.5); drawnow;
            tc.verifyEqual(P.CountsStarted, n0, 'a tab switch does not count again');
            [tAfter, ~] = tCuratorTraining.keyTimes(app, 6, @() true);
            fprintf(['[training] label key -> border: %s ms (%d of them while the folder was counted); with no ' ...
                'count running: %s ms\n'], mat2str(round(tDuring', 1)), nnz(during), mat2str(round(tAfter', 1)));
            % a confirmed page with the tab showing: counted from the store in memory, after the Enter
            Pg = app.Page;
            tc.assertEqual(Pg.Kind, "active");
            pause(0.5); drawnow;
            before = S.Good + S.Bad;
            t3 = tic;
            app.handleKey('return', {});
            drawnow;
            msEnter = 1000 * toc(t3);
            tc.verifyNotEqual(app.Page.PageId, Pg.PageId);
            pause(0.6); drawnow;
            S2 = P.Summary;
            tc.verifyEqual(P.CountsStarted, n0, 'no full count after a confirmed page');
            tc.verifyGreaterThan(S2.Good + S2.Bad, before, 'the counts follow the confirmed page');
            st = app.Store;
            C = struct();
            for f = ["State" "Reviewed" "LabelSource" "Label" "Excluded" "Flag" "AuditRole"]
                C.(f) = st.get(f);
            end
            q = curation.TrainingPanel.partialOf(C);
            row = P.Partials(lower(P.Partials.SourceId) == lower(app.Session.SourceId), :);
            tc.assertEqual(height(row), 1);
            tc.verifyEqual([row.Good row.Uncertain row.Bad], [q.Good q.Uncertain q.Bad], ...
                'the open source is counted from its store');
            fprintf(['[training] back to the tab: %.0f ms, no recount; Enter with the tab showing: %.0f ms; ' ...
                'the open source recounted from memory in %.1f ms\n'], ms2, msEnter, P.LastLiveMs);
        end


        function detectorExportOffWithoutASweptSection(tc)
            % a project where no section is complete and swept: the detector export says so
            for k = [1 3]
                t = tc.Truth.(matlab.lang.makeValidName(tExportStage1.LAYOUT(k, 2)));
                s = curation.Store.openCsv(t.paths.pv2Locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
                s.setSweepDone(false);
                s.close();
            end
            app = tc.openApp();
            app.showTraining();
            tc.assertTrue(app.Training.waitForCounts(120));
            b = tCuratorTraining.byTag(app, 'btn:trainExport1');
            tc.verifyFalse(logical(b.Enable));
            tc.verifySubstring(b.Tooltip, 'unavailable now');
            tc.verifySubstring(b.Tooltip, 'none swept');
            tc.verifyTrue(logical(tCuratorTraining.byTag(app, 'btn:trainExport2').Enable));
        end
    end

    methods (Test, TestTags = {'Slow', 'Python'})
        function oneEpochFineTuneThroughTheTab(tc)
            opts = struct('Epochs', 1, 'Device', "cpu", 'BatchSize', 16, 'RunDir', fullfile(tc.Root, 'run'), ...
                'DeployRoot', fullfile(tc.Root, 'models'), 'DeployName', "pv_curated_tab_scoring_ordinal_regression");
            app = tc.openApp(opts);
            app.showTraining();
            tc.assertTrue(app.Training.waitForCounts(120));
            out2 = fullfile(tc.Root, 'exp2');
            tc.Chosen = {out2};
            tCuratorTraining.push(app, 'btn:trainExport2');
            tc.assertTrue(isfile(fullfile(out2, 'export_report.json')), app.StatusText);
            t0 = tic;
            tCuratorTraining.push(app, 'btn:trainFineTune');
            tc.verifyLessThan(toc(t0), 5, 'the button returns while the fine-tune runs');
            tr = app.Training.Trainer;
            tc.assertNotEmpty(tr);
            tc.verifyEqual(tr.State, "running", app.StatusText);
            % review goes on while it trains
            tc.reviewOnePage(app);
            ok = app.Training.waitForTraining(900);
            tc.assertTrue(ok, 'the fine-tune did not finish in time');
            tc.assertEqual(tr.State, "succeeded", strjoin(tr.Lines(max(1, end - 30):end), newline));
            pause(1.2); drawnow;
            st = string(tCuratorTraining.byTag(app, 'lbl:trainState').Text);
            tc.verifySubstring(st, string(tr.DeployedTo));
            tc.verifySubstring(st, 'keep their old scores until they are rescored');
            lg = string(tCuratorTraining.byTag(app, 'ta:trainLog').Value);
            tc.verifyNotEmpty(lg);
            tc.verifyTrue(isfile(fullfile(tr.DeployedTo, 'best.pth')));
            fprintf('[training] fine-tune: %s -> %s\n', tr.RunDir, tr.DeployedTo);
        end
    end
end
