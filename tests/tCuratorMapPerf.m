classdef (TestTags = {'Benchmark'}) tCuratorMapPerf < matlab.unittest.TestCase
    %tCuratorMapPerf  Speed budgets of CellCurator's map paths on a real-size source (a 3277 x 2355
    %   float32 page pair, ~1,650 WFA detections), each from the call until drawnow has returned:
    %     first source of the MATLAB session (the window waited empty first, as when a person
    %     chooses a folder; the warm-up runs then unless CURATOR_WARMUP=0)        2000 ms
    %     first Map show of a source (map created / map exists)                     500 ms
    %     Gallery <-> Map for a loaded source                                       150 ms
    %     label key on a selected map point -> colour changed                        50 ms
    %     add a cell (click -> point shown), without / with snap              100 / 250 ms
    %     next close pair, next sweep field                                         100 ms
    %   Prints every measurement and a summary table; fails over budget (medians).
    %
    %   Run on the hidden desktop, alone (a fresh MATLAB, so the first open is the session's first):
    %     tools\Run-Tests.ps1 -IncludeSlow tCuratorMapPerf
    %     $env:CURATOR_WARMUP = '0'; tools\Run-Tests.ps1 -IncludeSlow tCuratorMapPerf   (no warm-up)

    properties (Constant)
        Budget = struct('FirstOpen', 2000, 'MapFirst', 500, 'Toggle', 150, 'MapLabel', 50, 'Add', 100, ...
            'AddSnap', 250, 'NextPair', 100, 'NextField', 100)
    end

    properties
        Folder
    end

    methods (TestClassSetup)
        function makeFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            t0 = tic;
            tc.Folder = makeSyntheticDataset(fullfile(fx.Folder, 'big'), 'ImageSize', [3277 2355], ...
                'NumCells', [1000 2000]);
            fprintf('\n[map-perf] real-size fixture written in %.1f s\n', toc(t0));
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function settle()
            pause(0.3);
            drawnow;
        end

        function xy = emptySpot(app, minDistPx, k)
            %emptySpot  The K-th image point (on a coarse grid) at least MINDISTPX from every point.
            m = app.Map;
            sz = m.ImageSize;
            found = 0;
            for y = 150:97:sz(1) - 150
                for x = 150:89:sz(2) - 150
                    if min(hypot(m.XY(:, 1) - x, m.XY(:, 2) - y)) > minDistPx
                        found = found + 1;
                        if found == k
                            xy = [x y];
                            return
                        end
                    end
                end
            end
            error('no empty spot %d', k);
        end

        function v = p90(x)
            x = sort(x(:));
            v = x(max(1, ceil(0.9 * numel(x))));
        end
    end

    methods (Test)
        function budgets(tc)
            C = curation.UiText.colors();
            warm = ~strcmp(getenv('CURATOR_WARMUP'), '0');
            R = struct();

            % 0 the first source of the session
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'WarmUp', warm);
            tc.addTeardown(@() tCuratorMapPerf.closeApp(app));
            app.waitForLayout(6);
            pause(3);                 % the window waits for a folder; the warm-up (when on) runs now
            drawnow;
            warmMs = NaN;
            if isfield(app.LastTimings, 'WarmUpMs'), warmMs = app.LastTimings.WarmUpMs; end
            t1 = tic;
            app.openParent(tc.Folder, '', 'ECM1');
            drawnow;
            R.FirstOpen = 1000 * toc(t1);
            L = app.LastTimings;
            fprintf(['[map-perf] first source of the session (warm-up %s, it took %.0f ms while the window ' ...
                'waited): openParent -> first page drawn %.0f ms; openSourceAt %.0f = store %.0f + images %.0f + ' ...
                'crops %.0f + page/UI %.0f\n'], string(warm), warmMs, R.FirstOpen, L.OpenSourceMs, L.StoreOpenMs, ...
                L.ImageReadMs, L.CacheBuildMs, L.OpenSourceMs - L.StoreOpenMs - L.ImageReadMs - L.CacheBuildMs);
            app.waitForLayout();
            tc.assertEqual(app.Page.Kind, "active");
            st = app.Store;
            fprintf('[map-perf] ECM1: %d detections; image %s\n', st.counts().total, mat2str(size(app.Session.PageT)));

            % 1 first Map show: the map was created (hidden) while the person looked at the first page
            pause(CellCurator.PrepareIdleSec + 1);
            drawnow;
            tc.assertNotEmpty(app.Map, 'the map is created at the first pause');
            L = app.LastTimings;
            fprintf('[map-perf] map created at the first pause in %.0f ms (action bars %.0f ms)\n', ...
                L.MapCreateMs, L.MapBarsMs);
            tCuratorMapPerf.settle();
            t1 = tic;
            app.handleKey('tab', {});
            drawnow;
            mapFirst = 1000 * toc(t1);
            tc.assertEqual(app.CentreView, "map");
            L = app.LastTimings;
            fprintf('[map-perf] first Map show of ECM1: %.0f ms = load %.0f ms + the rest and drawnow\n', ...
                mapFirst, L.MapLoadMs);
            n = 10;
            t = zeros(n, 1);
            for i = 1:n
                tCuratorMapPerf.settle();
                t1 = tic;
                app.handleKey('tab', {});
                drawnow;
                t(i) = 1000 * toc(t1);
            end
            R.Toggle = t;
            fprintf('[map-perf] Gallery -> Map %.1f ms (median), Map -> Gallery %.1f ms (median)\n', ...
                median(t(1:2:end)), median(t(2:2:end)));
            tc.assertEqual(app.CentreView, "map");

            % 3 label key on a selected map point -> colour changed
            m = app.Map;
            k = find(all(double(m.RGB) == C.Unreviewed, 2), 1);
            id = m.Ids(k);
            app.mapClick(m.XY(k, :));
            tc.assertEqual(app.MapSelection, id);
            n = 20; w = 3;
            t = zeros(n + w, 1);
            ok = true;
            for i = 1:n + w
                tCuratorMapPerf.settle();
                if mod(i, 2), key = 'g'; want = C.Good; else, key = 'b'; want = C.Bad; end
                t1 = tic;
                app.handleKey(key, {});
                drawnow;
                t(i) = 1000 * toc(t1);
                ok = ok && isequal(double(m.RGB(m.rowsOf(id), :)), want);
            end
            R.MapLabel = t(w + 1:end);
            tc.verifyTrue(ok, 'the point wears the new colour');

            % 4 add a cell: click -> point shown, without and with snap
            app.handleKey('escape', {});
            m.fit();
            drawnow;
            app.setMapTool('add');
            for snap = [false true]
                app.setSnap(snap);
                n = 10; w = 2;
                t = zeros(n + w, 1);
                for i = 1:n + w
                    xy = tCuratorMapPerf.emptySpot(app, 60, i + 20 * snap);
                    n0 = st.NumRows;
                    tCuratorMapPerf.settle();
                    t1 = tic;
                    app.mapClick(xy);
                    drawnow;
                    t(i) = 1000 * toc(t1);
                    ids = st.get('CellID');
                    tc.assertEqual(st.NumRows, n0 + 1, app.StatusText);
                    tc.assertGreaterThan(m.rowsOf(ids(end)), 0);
                end
                if snap, R.AddSnap = t(w + 1:end); else, R.Add = t(w + 1:end); end
            end
            app.setSnap(false);

            % 5 next close pair
            ids = st.get('CellID');
            st.setLabel(ids(st.get('State') == "active"), "Good", "human");
            app.showQueue('closePairs');
            np = numel(app.PairList);
            fprintf('[map-perf] close pairs: %d clusters\n', np);
            tc.assertGreaterThanOrEqual(np, 5);
            n = min(15, np - 1);
            t = zeros(n, 1);
            for i = 1:n
                tCuratorMapPerf.settle();
                t1 = tic;
                app.handleKey('rightarrow', {});
                drawnow;
                t(i) = 1000 * toc(t1);
            end
            R.NextPair = t;

            % 6 next sweep field
            app.showQueue('sweep');
            nf = size(app.Map.SweepRects, 1);
            fprintf('[map-perf] sweep: %d fields of %g um\n', nf, app.SweepFieldUm);
            n = min(15, nf - 1);
            t = zeros(n, 1);
            for i = 1:n
                tCuratorMapPerf.settle();
                t1 = tic;
                app.handleKey('space', {});
                drawnow;
                t(i) = 1000 * toc(t1);
            end
            R.NextField = t;

            % 7 first Map show of the next source (the map exists; PV2, the same section)
            app.handleKey('tab', {});
            app.handleKey('rightarrow', {'control'});
            tc.assertEqual(app.SourceKey, "PV2");
            app.waitForLayout();
            tCuratorMapPerf.settle();
            t1 = tic;
            app.handleKey('tab', {});
            drawnow;
            mapNext = 1000 * toc(t1);
            R.MapFirst = [mapFirst; mapNext];
            fprintf('[map-perf] first Map show: %.0f ms (ECM1); %.0f ms (PV2, the same section)\n', mapFirst, mapNext);
            delete(app);

            % (reported) the map created on demand: Tab right after the first page, no pause
            app2 = CellCurator('UseSettings', false, 'PrepareNext', false, 'PrepareMap', false);
            tc.addTeardown(@() tCuratorMapPerf.closeApp(app2));
            app2.openParent(tc.Folder, '', 'ECM1');
            app2.waitForLayout();
            tCuratorMapPerf.settle();
            t1 = tic;
            app2.handleKey('tab', {});
            drawnow;
            tDemand = 1000 * toc(t1);
            L = app2.LastTimings;
            fprintf(['[map-perf] first Map show with the map created on demand (second window of the session): ' ...
                '%.0f ms = create %.0f (action bars %.0f) + load %.0f + drawnow\n'], tDemand, L.MapCreateMs, ...
                L.MapBarsMs, L.MapLoadMs);

            fprintf('\n[map-perf] ============ CellCurator map budgets (ms, call -> drawnow returned) ============\n');
            fprintf('[map-perf] %-46s %8s %8s %8s %8s  %s\n', 'action', 'median', 'p90', 'max', 'budget', 'verdict');
            names = ["FirstOpen" "MapFirst" "Toggle" "MapLabel" "Add" "AddSnap" "NextPair" "NextField"];
            what = ["first source of the session" "first Map show of a source" "Gallery <-> Map (loaded)" ...
                "label key on a map point -> colour" "add a cell, no snap" "add a cell, snap" ...
                "next close pair" "next sweep field"];
            for i = 1:numel(names)
                v = R.(names(i));
                b = tc.Budget.(names(i));
                verdict = "ok";
                if median(v) > b || (names(i) == "MapFirst" && max(v) > b), verdict = "OVER BUDGET"; end
                fprintf('[map-perf] %-46s %8.1f %8.1f %8.1f %8.0f  %s (n=%d)\n', what(i), median(v), ...
                    tCuratorMapPerf.p90(v), max(v), b, verdict, numel(v));
            end
            fprintf('[map-perf] ===============================================================================\n');
            for i = 1:numel(names)
                v = R.(names(i));
                tc.verifyLessThanOrEqual(median(v), tc.Budget.(names(i)), ...
                    sprintf('%s: median %.1f ms exceeds %g ms', what(i), median(v), tc.Budget.(names(i))));
            end
            tc.verifyLessThanOrEqual(max(R.MapFirst), tc.Budget.MapFirst, 'every first Map show');
        end
    end
end
