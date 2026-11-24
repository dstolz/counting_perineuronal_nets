classdef tDiscoveryBatch < matlab.unittest.TestCase
    %TDISCOVERYBATCH  CellDiscovery runs a batch end to end in its window (Slow, Python): page 1 of a
    %   small synthetic TIFF (ring-like nets, makeSyntheticDataset; calibrated at 1.657 um/px, so the
    %   auto resize applies) goes through predict.py and score.py on the CPU with the shipped PNN
    %   models, driven through the window's Hidden seams (configure, start, requestStop, isRunning,
    %   batchState, lastTally, stageLog). Threshold 0, so the deterministic synthetic page always
    %   has detections to rescore.
    %     detectAndRescoreOnePage  the _locs.csv and its resized companion have a finite 'rescore'
    %                              column; the manifest records the detection and the rescore; the
    %                              tally says 1 done, 0 failed; scoring ran as its own asynchronous
    %                              stage (launched and finished in different timer ticks, and this
    %                              test ran while score.py worked); the run's scratch folder is gone.
    %                              A second Start in Ignore mode counts the page as skipped and starts
    %                              no Python process.
    %     abortDuringDetection     Stop while predict.py runs turns the button into Abort now; Abort
    %                              now kills the process, nothing is written for the page (no CSV,
    %                              manifest or TIF), the tally says aborted, the scratch folder is
    %                              gone and the button reads Stop again.
    %   Skipped (assumption) without the countpnn environment or the models. Uses a preference group
    %   of its own and closes every window it opens.
    %
    %   Run: pwsh -File tools\Run-Tests.ps1 tDiscoveryBatch -IncludeSlow

    properties (Constant)
        PREFS    = 'tDiscoveryBatchPrefs'
        DETECTOR = 'pnn_v2_fasterrcnn_640'
        SCORERS  = {'pnn_v2_scoring_ordinal_regression', 'pnn_v2_scoring_rank_learning'}
    end

    properties
        Repo
        Python      % CellToolkit.pythonConfig of the countpnn env
        Scorer
        Dir         % the folder the batch searches: the synthetic TIFF only
        Tif
    end

    methods (TestMethodSetup)
        function setup(tc)
            tc.Repo = fileparts(fileparts(mfilename('fullpath')));
            [ok, why, cfg] = curation.RescoreRunner.pythonStatus(tc.Repo);
            tc.assumeTrue(ok, char(why));
            tc.assumeTrue(isfile(fullfile(tc.Repo, tc.DETECTOR, 'best.pth')), ...
                sprintf('%s is not in the repository', tc.DETECTOR));
            have = cellfun(@(m) isfile(fullfile(tc.Repo, m, 'best.pth')), tc.SCORERS);
            tc.assumeTrue(any(have), 'no PNN scoring model in the repository');
            tc.Scorer = tc.SCORERS{find(have, 1)};
            tc.Python = cfg;

            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [~, tr] = makeSyntheticDataset(fullfile(fx.Folder, 'syn'), 'Variants', false, ...
                'ImageSize', [300 400], 'NumCells', [25 30]);
            tc.Dir = fullfile(fx.Folder, 'data');
            mkdir(tc.Dir);
            copyfile(tr.paths.tif, tc.Dir);
            [~, name, ext] = fileparts(tr.paths.tif);
            tc.Tif = fullfile(tc.Dir, [name ext]);

            before = findall(groot, 'Type', 'figure');
            tc.addTeardown(@() tDiscoveryBatch.closeNewFigures(before));   % PNNResultFig and any other
            tc.addTeardown(@() tDiscoveryBatch.removePrefs(tc.PREFS));
        end
    end

    methods
        function app = openApp(tc)
            % The window on tc.Dir with the test's settings: page 1 (suffix ECM) -> PNN detector +
            % PNN scorer, threshold 0, cpu, the countpnn python directly (no conda run).
            delete(findall(groot, 'Tag', 'PNNBatchGUIMain'));   % an open window would be reused
            app = CellDiscovery(tc.Dir, 'PrefGroup', tc.PREFS, 'Search', false);
            tc.addTeardown(@() tDiscoveryBatch.closeApp(app));
            app.configure('PythonExe', tc.Python.PythonExe, 'CondaExe', '', 'CondaEnv', '', ...
                'Device', 'cpu', 'BatchSize', '1', 'Threshold', '0', 'Overwrite', false, ...
                'SavePng', false, 'SaveTif', false, 'Diagnostic', false, ...
                'PageMap', {1, 'ECM', tc.DETECTOR, tc.Scorer, false, 0, 0, false, true});
            app.setSearchDir(tc.Dir);   % the file list
        end

        function [stages, secs] = waitForBatch(tc, app, timeout)
            % Let the batch run (its timer fires during pause) until it ends; STAGES = the stages
            % of the page in flight this loop saw between ticks.
            t0 = tic;
            stages = strings(0, 1);
            while app.isRunning() && toc(t0) < timeout
                pause(0.1);
                st = string(app.batchState().Stage);
                if st ~= "" && ~ismember(st, stages)
                    stages(end + 1, 1) = st; %#ok<AGROW>
                end
            end
            secs = toc(t0);
            tc.assertFalse(app.isRunning(), sprintf('the batch did not end within %d s', timeout));
        end
    end

    methods (Test, TestTags = {'Slow', 'Python'})

        function detectAndRescoreOnePage(tc)
            app = tc.openApp();
            runs0 = app.batchState().PythonRuns;
            t0 = tic;
            app.start();
            tc.assertTrue(app.isRunning(), app.batchState().Progress);
            stages = tc.waitForBatch(app, 900);
            secs = toc(t0);
            T = app.lastTally();
            L = app.stageLog();
            st = app.batchState();
            fprintf('[batch] one page detected and rescored in %.1f s (from Start, env check included)\n', secs);
            fprintf('[batch] stages seen between ticks: %s\n', strjoin(stages', ', '));
            rows = [cellstr(L.Event)'; num2cell(L.Tick)'; num2cell(L.Seconds)'];
            fprintf('[batch]   %-16s tick %4d  %6.1f s\n', rows{:});
            fprintf('[batch] progress label: %s\n', st.Progress);

            % the tally
            tc.verifyEqual(T.state, 'complete');
            tc.verifyEqual(T.done, 1);
            tc.verifyEqual(T.skipped, 0);
            tc.verifyEmpty(T.failed, tDiscoveryBatch.reasons(T.failed));
            tc.verifyEmpty(T.aborted);
            tc.verifyEmpty(T.warnings, tDiscoveryBatch.reasons(T.warnings));
            tc.verifyEqual(st.Progress, 'Complete: 1 done, 0 skipped, 0 failed');
            tc.verifyEqual(st.ProgressColor, [0 0 0], 'not red: nothing failed');
            tc.verifyEqual(st.StopText, 'Stop');
            tc.verifyFalse(st.StopEnabled);

            % the results
            csv = fullfile(tc.Dir, 'SYN-0001_sec1_proj_ECM1_locs.csv');
            tc.assertTrue(isfile(csv), 'no _locs.csv');
            R = readtable(csv);
            fprintf('[batch] %d detections, rescore %s\n', height(R), mat2str(R.rescore(1:min(5, end))', 3));
            tc.assertGreaterThan(height(R), 0, 'predict.py found no cell on the synthetic page (threshold 0)');
            tc.assertTrue(ismember('rescore', R.Properties.VariableNames), 'no rescore column');
            tc.verifyTrue(all(isfinite(R.rescore)), 'every detection has a score');
            rcsv = fullfile(tc.Dir, 'SYN-0001_sec1_proj_ECM1_locs_resized.csv');
            tc.assertTrue(isfile(rcsv), 'no resized-coordinate CSV');
            Rr = readtable(rcsv);
            tc.verifyEqual(Rr.rescore, R.rescore, 'the same scores in both spaces');
            tc.verifyGreaterThan(Rr.X(1) / R.X(1), 2, 'the page was resized (1.657 -> 0.645 um/px)');

            % the manifest
            mf = CellDatasetManifest.forImage(tc.Tif);
            key = CellDatasetManifest.keyForCsv(csv);
            s = mf.source(key);
            tc.assertNotEmpty(s, sprintf('no source %s in %s', key, mf.ManifestPath));
            tc.verifyTrue(isequal(s.stages.detection.done, true));
            tc.verifyEqual(char(s.stages.detection.model), tc.DETECTOR);
            tc.verifyEqual(double(s.stages.detection.count), height(R));
            tc.assertTrue(isfield(s.stages, 'rescore'), 'the rescore is not recorded');
            tc.verifyTrue(isequal(s.stages.rescore.done, true));
            tc.verifyEqual(char(s.stages.rescore.model), tc.Scorer);

            % the stages: scoring as its own asynchronous stage
            ev = L.Event(L.Job == 1)';
            tc.verifyEqual(ev, ["detect-launch" "detect-exit" "after-detection" "score-launch" "score-exit" "finish"]);
            tick = @(e) L.Tick(L.Job == 1 & L.Event == e);
            tc.verifyGreaterThan(tick("score-exit"), tick("score-launch"), 'score.py ran across timer ticks');
            tc.verifyEqual(tick("score-launch"), tick("detect-exit"), 'scoring starts in the tick predict.py ended');
            tc.verifyTrue(ismember("score", stages), 'this test ran (pause) while score.py worked');
            tc.verifyEqual(st.PythonRuns - runs0, 3, 'the env check, predict.py and score.py');

            % the scratch folder
            tc.verifyNotEmpty(st.ScratchDir);
            tc.verifyFalse(isfolder(st.ScratchDir), 'the run''s scratch folder is removed');

            % a second Start in Ignore mode: the page is skipped, no Python starts
            app.start();
            tc.verifyFalse(app.isRunning());
            T2 = app.lastTally();
            tc.verifyEqual([T2.done T2.skipped numel(T2.failed)], [0 1 0]);
            st2 = app.batchState();
            tc.verifyEqual(st2.PythonRuns, st.PythonRuns, 'no Python process (no env check either)');
            tc.verifySubstring(st2.Progress, 'Nothing to do: all 1 page job(s) already have results');
            tc.verifyEmpty(app.stageLog());
        end

        function environmentCheckReportsCuda(tc)
            % testPythonEnv: output still has OK; the 4th output says whether CUDA is available
            % (true | false; NaN when torch is not among the modules).
            [ok, msg, out, cuda] = CellToolkit.testPythonEnv(tc.Python, {'hydra', 'torch'});
            tc.assertTrue(ok, msg);
            tc.verifySubstring(out, 'OK');
            tc.verifyTrue(islogical(cuda) && isscalar(cuda), 'CUDA availability is known when torch is imported');
            fprintf('[env] CUDA available in the countpnn env: %d\n', cuda);
            [ok, ~, out, cuda] = CellToolkit.testPythonEnv(tc.Python, {'os'});
            tc.assertTrue(ok);
            tc.verifySubstring(out, 'OK');
            tc.verifyTrue(isnan(cuda), 'unknown without torch');
            [ok, ~, ~, cuda] = CellToolkit.testPythonEnv(tc.Python, {'no_such_module_xyz'});
            tc.verifyFalse(ok);
            tc.verifyTrue(isnan(cuda));
        end

        function abortDuringDetection(tc)
            app = tc.openApp();
            app.configure('Overwrite', true);
            app.start();
            tc.assertTrue(app.isRunning(), app.batchState().Progress);
            t0 = tic;
            while app.isRunning() && string(app.batchState().Stage) ~= "detect" && toc(t0) < 60
                pause(0.05);
            end
            tc.assertEqual(string(app.batchState().Stage), "detect", 'predict.py did not start');
            scratch = app.batchState().ScratchDir;
            tc.verifyTrue(isfolder(scratch));

            app.requestStop();   % Stop: the page would finish, the button turns into Abort now
            st = app.batchState();
            tc.verifyTrue(st.Running);
            tc.verifyEqual(st.StopText, 'Abort now');
            tc.verifyTrue(st.StopEnabled);
            tc.verifySubstring(st.StopTooltip, 'discard the page in flight');
            tc.verifySubstring(st.Progress, 'Stop requested');

            t1 = tic;
            app.requestStop();   % Abort now
            tc.waitForBatch(app, 30);
            fprintf('[abort] the batch ended %.2f s after Abort now\n', toc(t1));

            T = app.lastTally();
            st = app.batchState();
            tc.verifyEqual(T.state, 'aborted');
            tc.verifyEqual(T.aborted, 'SYN-0001_sec1_proj  (page 1/2)');
            tc.verifyEqual([T.done T.skipped numel(T.failed) T.notRun], [0 0 0 0]);
            tc.verifyEqual(st.Progress, 'Aborted: 0 done, 0 skipped, 0 failed, 1 aborted (see the Command Window)');
            tc.verifyEqual(st.StopText, 'Stop');
            tc.verifySubstring(st.StopTooltip, 'Click again to abort');
            tc.verifyFalse(st.StopEnabled);
            L = app.stageLog();
            tc.verifyEqual(L.Event', ["detect-launch" "abort"]);
            listing = dir(tc.Dir);
            names = sort(string({listing(~[listing.isdir]).name}));
            tc.verifyEqual(names, "SYN-0001_sec1_proj.tif", 'nothing written for the aborted page');
            tc.verifyFalse(isfolder(scratch), 'the run''s scratch folder is removed');
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app), delete(app); end
        end

        function closeNewFigures(before)
            figs = findall(groot, 'Type', 'figure');
            delete(figs(~ismember(figs, before)));
        end

        function removePrefs(g)
            if ispref(g), rmpref(g); end
        end

        function txt = reasons(s)
            % "label: reason" lines of a tally's failed / warnings struct array
            txt = strjoin(reshape(arrayfun(@(x) sprintf('%s: %s', x.label, x.reason), s, ...
                'UniformOutput', false), 1, []), newline);
        end
    end
end
