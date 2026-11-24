classdef tCuratorRescore < matlab.unittest.TestCase
    %tCuratorRescore  Rescoring edited cells in CellCurator (integration pass C, item 4): the finish
    %   checklist's optional "Cells waiting for a score" row and the left panel's Score edited cells
    %   button; the rescore runs off the key path (curation.RescoreRunner; here a fake score.py,
    %   FakeRescoreJob, unless Python) and its scores are stored between pages: deferred while a tile
    %   drag holds a batch open, dropped for cells moved while it ran; 200 scores stored within 50 ms;
    %   a missing Python environment is said in the status bar and the tooltips.
    %   (Slow, Python) a real rescore of cells added on a synthetic page with the shipped scorer.
    %   Saves curator_finish.png (the checklist with the rescore row).
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorRescore [-IncludeSlow]

    properties
        Folder
        Truth
    end

    methods (TestMethodSetup)
        function makeFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_NO_CLIENT', '1'));
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'provenance')));
            [tc.Folder, tc.Truth] = makeSyntheticDataset(fullfile(fx.Folder, 'ds'), 'Variants', false, ...
                'ImageSize', [400 500], 'NumCells', [40 50]);
        end
    end

    methods
        function app = openApp(tc, rescoreOpts, key)
            if nargin < 2, rescoreOpts = struct('RunFcn', @(s, o) FakeRescoreJob.run(s, o, 0.3)); end
            if nargin < 3, key = 'ECM1'; end
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, ...
                'ConfirmAudit', false, 'RescoreOptions', rescoreOpts);
            tc.addTeardown(@() tCuratorRescore.closeApp(app));
            app.openParent(tc.Folder, '', key);
            app.waitForLayout();
        end

        function ids = addCells(~, app, xy)
            st = app.Store;
            ids = st.addCell(xy, struct('Label', "Good"));
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
            b = tCuratorRescore.byTag(app, tag);
            b.ButtonPushedFcn(b, []);
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
        function finishRowRescoresAndNeverBlocksCompletion(tc)
            app = tc.openApp();
            st = app.Store;
            added = tc.addCells(app, [60 60; 120 300; 400 90]);
            ids = st.get('CellID');
            st.moveCell(ids(1), [st.get('X', ids(1)) + 4, st.get('Y', ids(1))]);
            st.setLabel(ids(st.get('Label') == ""), "Good", "human");      % everything reviewed
            C = curation.Pairs.find(st.kept(), st.Meta.UmPerPixel, struct('KeptPairs', st.Meta.KeptPairs));
            for k = 1:numel(C), st.keepBoth(C(k).Edges); end              % and the close pairs resolved
            app.showQueue('review');
            pause(0.4); drawnow;
            tc.assertEqual(app.Page.Kind, "empty", 'the finish checklist');
            row = tCuratorRescore.byTag(app, 'btn:finishRescore');
            tc.verifySubstring(row.Text, 'Cells waiting for a score: 4');
            tc.verifySubstring(row.Text, 'Rescore now');
            tc.verifySubstring(row.Tooltip, 'Optional (it does not block completing)');
            tc.verifySubstring(row.Tooltip, 'ordinal');
            btn = tCuratorRescore.byTag(app, 'btn:rescoreEdited');
            tc.verifySubstring(btn.Text, '(4)');
            tc.verifyTrue(logical(btn.Enable));
            tCuratorRescore.saveScreen(app.Figure, 'curator_finish.png');
            % pending scores never block completing
            app.markComplete();
            tc.verifyTrue(logical(st.Meta.Complete), app.StatusText);
            % Rescore now: the click returns at once; the scores are stored at idle
            t0 = tic;
            tCuratorRescore.push(app, 'btn:finishRescore');
            secs = toc(t0);
            fprintf('[rescore] Rescore now: the click returned in %.0f ms (limit 500)\n', 1000 * secs);
            tc.verifyLessThan(secs, 0.5, 'the click returns at once');
            tc.verifySubstring(char(app.StatusText), 'Scoring 4 edited cells');
            app.waitForRescore(30);
            tc.verifyEmpty(st.rescorePending(), app.StatusText);
            tc.verifyEqual(st.get('rescore', added), 1 + st.get('X', added) / 1000, 'AbsTol', 1e-12);
            tc.verifyEqual(st.get('RescoreSource', added), repmat("pnn_v2_scoring_ordinal_regression", 3, 1));
            tc.verifySubstring(char(app.StatusText), 'Scored 4 edited cells');
            pause(0.3); drawnow;
            row = tCuratorRescore.byTag(app, 'btn:finishRescore');
            tc.verifySubstring(row.Text, 'nothing to do');
            tc.verifyTrue(logical(st.Meta.Complete), 'still complete: the kept cells did not change');
        end

        function aDragDefersAndAMoveDropsTheScore(tc)
            app = tc.openApp(struct('RunFcn', @(s, o) FakeRescoreJob.run(s, o, 0.6)));
            st = app.Store;
            added = tc.addCells(app, [60 60; 120 300; 400 90]);
            app.requestRescore();
            app.waitForRescore(0.05);                     % started: the fake score.py runs 0.6 s
            tc.assertEqual(app.Rescorer.State, "running");
            st.moveCell(added(2), [130 300]);             % moved while the job ran: its score is stale
            app.showQueue('review');
            g = app.Gallery;
            g.onButtonDown(struct('AxesPoint', g.tileCenter(1), 'SelectionType', 'normal'));   % a drag: a batch
            tc.assertTrue(st.InBatch);
            pause(0.8);
            app.waitForRescore(1);
            tc.verifyEqual(app.Rescorer.State, "ready", 'nothing is stored inside the drag');
            tc.verifyTrue(all(isnan(st.get('rescore', added))));
            g.onButtonUp(struct('AxesPoint', g.tileCenter(1)));
            pause(0.2);
            app.waitForRescore(5);
            tc.verifyTrue(all(isfinite(st.get('rescore', added([1 3])))), 'stored once the drag ended');
            tc.verifyTrue(isnan(st.get('rescore', added(2))), 'the moved cell keeps waiting');
            tc.verifyEqual(st.rescorePending(), added(2));
            tc.verifySubstring(char(app.StatusText), '1 moved while it ran');
            % undo is the reviewer's last action (the drag), not the scores
            app.handleKey('z', {'control'});
            tc.verifyTrue(all(isfinite(st.get('rescore', added([1 3])))));
        end

        function storingTwoHundredScoresTakesUnder50ms(tc)
            app = tc.openApp(struct('RunFcn', @(s, o) FakeRescoreJob.run(s, o, 0)));
            st = app.Store;
            [gx, gy] = meshgrid(linspace(30, 470, 20), linspace(30, 370, 10));
            added = tc.addCells(app, [gx(:) gy(:)]);
            tc.assertNumElements(added, 200);
            t = zeros(3, 1);
            for i = 1:3
                if i > 1
                    st.moveCell(added, [st.get('X', added) + 0.5, st.get('Y', added)]);   % pending again
                end
                pause(0.3); drawnow;
                app.requestRescore();
                app.waitForRescore(10);
                tc.assertEmpty(st.rescorePending(), app.StatusText);
                t(i) = app.LastTimings.ApplyRescoreMs;
            end
            fprintf('[rescore] storing 200 scores between pages: %s ms (median %.1f)\n', mat2str(t', 3), median(t));
            tc.verifyLessThanOrEqual(median(t), 50, 'store 200 scores between pages within 50 ms');
        end

        function aMissingPythonIsSaid(tc)
            app = tc.openApp(struct('PythonCheck', @(~) deal(false, "The countpnn Python environment was not found (test).")));
            tc.addCells(app, [60 60]);
            pause(0.3); drawnow;
            app.requestRescore();
            tc.verifySubstring(char(app.StatusText), 'Cannot rescore here');
            tc.verifySubstring(char(app.StatusText), 'countpnn');
            app.showQueue('review');
            pause(0.5); drawnow;
            btn = tCuratorRescore.byTag(app, 'btn:rescoreEdited');
            tc.verifyFalse(logical(btn.Enable));
            tc.verifySubstring(btn.Tooltip, 'countpnn Python environment was not found');
        end
    end

    methods (Test, TestTags = {'Slow', 'Python'})
        function realRescoreOfAddedCells(tc)
            app = tc.openApp(struct(), 'PV2');
            st = app.Store;
            tr = tc.Truth.PV2;
            miss = tr.cellsXY(tr.missedIdx(1:min(2, numel(tr.missedIdx))), :);
            added = tc.addCells(app, [miss; 250 200]);
            t0 = tic;
            app.requestRescore();
            app.waitForRescore(300);
            fprintf('[rescore] %d added cells scored in %.1f s (image preparation %.0f ms blocking): %s; %s\n', ...
                numel(added), toc(t0), app.LastTimings.RescorePrepareMs, mat2str(st.get('rescore', added)', 3), ...
                app.StatusText);
            tc.verifyTrue(all(isfinite(st.get('rescore', added))), app.StatusText);
            tc.verifyEqual(st.get('RescoreSource', added), repmat("pv_v2_scoring_ordinal_regression", numel(added), 1));
            tc.verifyEmpty(st.rescorePending());
        end
    end
end
