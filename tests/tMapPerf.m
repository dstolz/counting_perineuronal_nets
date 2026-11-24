classdef (TestTags = {'Benchmark'}) tMapPerf < matlab.unittest.TestCase
    %tMapPerf  Speed budgets of the section map on a real-size source: 3277 x 2355 float32 pages (target
    %   and companion), 2,800 points, a 1200 x 800 px map. Each time is the median of >= 20 repetitions
    %   after a warm-up, measured from tic until drawnow has returned. Fails when a budget is exceeded;
    %   prints every measurement and a summary table, plus the comparison of the two image strategies
    %   (full-resolution image resampled by the axes vs. overview + re-cropped full-resolution window).
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 -IncludeSlow tMapPerf

    properties (Constant)
        PageSize = [3277 2355]
        UmPerPx = 1.657
        NCells = 2800
        MapSize = [1200 800]
        Reps = 25
        Warmup = 3
        Budget = struct('NewSource', 500, 'UpdateOne', 50, 'Update150', 50, 'ZoomStep', 50, 'PanStep', 50, ...
            'CenterOn', 50, 'Pick', 1, 'DragFrame', 30)
    end

    properties
        Src          % 1 x 2 struct: T, C, Limits, Ids, XY, RGB (two sources of the same size)
        Fig
        View
        Results      % containers.Map: name -> [median budget]
    end

    % ------------------------------------------------------------------------------------------------
    methods (TestClassSetup)
        function setupSourcesAndFigure(tc)
            % one method: TestClassSetup methods run in no guaranteed order
            tc.Results = containers.Map();
            t0 = tic;
            tc.Src = [tMapPerf.makeSource(2027, tc.PageSize, tc.NCells), tMapPerf.makeSource(2028, tc.PageSize, tc.NCells)];
            ss = get(groot, 'ScreenSize');
            fprintf('\n[perf] sources: 2 x %d x %d %s page pairs, %d points each (made in %.1f s); screen %d x %d px, %s\n', ...
                tc.PageSize(1), tc.PageSize(2), class(tc.Src(1).T), tc.NCells, toc(t0), ss(3), ss(4), version);
            tc.Fig = uifigure('Name', 'tMapPerf', 'Position', [10 10 tc.MapSize]);
            gl = uigridlayout(tc.Fig, [1 1], 'Padding', [0 0 0 0]);
            tc.View = curation.MapView(gl);
            t0 = tic;
            while toc(t0) < 10          % the grid is laid out in the browser: wait until the panel has its size
                drawnow;
                if isequal(tc.View.Panel.Position(3:4), tc.Fig.Position(3:4)); break; end
                pause(0.05);
            end
            t0 = tic;
            tc.showSource(1);
            drawnow;
            fprintf('[perf] first source in a fresh figure (setImage + setPoints + drawnow): %.0f ms\n', 1000 * toc(t0));
        end
    end

    methods (TestClassTeardown)
        function summaryAndClose(tc)
            tc.printSummary();
            if ~isempty(tc.Fig) && isvalid(tc.Fig); delete(tc.Fig); end
        end
    end

    methods (Static)
        function S = makeSource(seed, sz, n)
            %makeSource  Two float32 pages with ring-like (target) and solid (companion) cells, arbitrary scales.
            rng(seed);
            H = sz(1);
            W = sz(2);
            xy = [1 + rand(n, 1) * (W - 1), 1 + rand(n, 1) * (H - 1)];
            imp = zeros(H, W, 'single');
            imp(sub2ind([H W], round(xy(:, 2)), round(xy(:, 1)))) = 1;
            r = -15:15;
            gw = single(exp(-r.^2 / (2 * 4^2)));
            gn = single(exp(-r.^2 / (2 * 2^2)));
            wide = conv2(gw, gw, imp, 'same');
            narrow = conv2(gn, gn, imp, 'same');
            noise = randn(H, W, 'single');
            S.T = 37.5 * (3 + 6 * (wide - 0.7 * narrow) + 0.4 * noise);
            S.C = 0.0021 * (1 + 5 * narrow + 0.3 * noise);
            S.Limits = [curation.CropCache.pageLimits(S.T, [1 99.9], 1e6); curation.CropCache.pageLimits(S.C, [1 99.9], 1e6)];
            S.Ids = uint32((1:n)' + 1000 * seed);
            S.XY = xy;
            pal = uint8([110 110 110; 0 158 115; 213 94 0; 240 228 66]);
            S.RGB = pal(1 + mod((1:n)', 4), :);
        end
    end

    methods
        function showSource(tc, k, limits)
            if nargin < 3; limits = tc.Src(k).Limits; end
            S = tc.Src(k);
            tc.View.setImage(S.T, S.C, limits, tc.UmPerPx);
            tc.View.setPoints(S.Ids, S.XY, S.RGB);
        end

        function record(tc, name, ms, extra)
            budget = tc.Budget.(name);
            tc.Results(name) = [median(ms) budget];
            fprintf('[perf] %-12s median %8.3f ms  (min %7.3f, p90 %7.3f, n=%d)  budget %g ms%s\n', name, ...
                median(ms), min(ms), prctile90(ms), numel(ms), budget, extra);
            tc.verifyLessThanOrEqual(median(ms), budget, sprintf('%s: median %.2f ms exceeds the %g ms budget', ...
                name, median(ms), budget));
        end

        function printSummary(tc)
            names = ["NewSource" "UpdateOne" "Update150" "ZoomStep" "PanStep" "CenterOn" "Pick" "DragFrame"];
            what = ["setImage + setPoints, new source (2800 pts)" "updatePoints, 1 point" "updatePoints, 150 points" ...
                "zoom step (wheel notch)" "pan step (a frame while dragging)" "centerOn" "pick (no drawnow)" ...
                "live point drag frame (move tool)"];
            fprintf('\n[perf] ================= summary (median ms, tic -> drawnow returned) =================\n');
            fprintf('[perf] %-46s %10s %10s  %s\n', 'action', 'measured', 'budget', 'verdict');
            for i = 1:numel(names)
                if ~isKey(tc.Results, names(i)); continue; end
                v = tc.Results(names(i));
                verdict = "ok";
                if v(1) > v(2); verdict = "OVER BUDGET"; end
                fprintf('[perf] %-46s %10.3f %10g  %s\n', what(i), v(1), v(2), verdict);
            end
            fprintf('[perf] =====================================================================================\n');
        end

        function mid = middle(tc)
            pp = getpixelposition(tc.View.Panel, true);
            mid = pp(1:2) - 1 + pp(3:4) / 2;
        end

        function [t, scales, switched] = zoomSequence(tc, fp)
            %zoomSequence  Wheel notches at figure point FP from the whole image to the deepest zoom and back;
            %   SWITCHED marks the steps where the automatic interpolation changed.
            v = tc.View;
            v.fit();
            drawnow;
            t = zeros(0, 1);
            scales = zeros(0, 2);
            switched = false(0, 1);
            for dirn = [-1 1]
                for i = 1:60
                    s0 = v.Scale;
                    i0 = v.Interpolation;
                    t0 = tic;
                    v.onScroll(struct('FigurePoint', fp, 'VerticalScrollCount', dirn));
                    drawnow;
                    dt = toc(t0);
                    if v.Scale == s0; break; end
                    t(end + 1, 1) = dt; %#ok<AGROW>
                    scales(end + 1, :) = [s0 v.Scale]; %#ok<AGROW>
                    switched(end + 1, 1) = v.Interpolation ~= i0; %#ok<AGROW>
                end
            end
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Test)
        function testNewSource(tc)
            v = tc.View;
            total = tc.Warmup + 20;
            [t, tImg, tPts] = deal(zeros(total, 1));
            for i = 1:total
                k = 2 - mod(i, 2);
                drawnow;
                t0 = tic;
                S = tc.Src(k);
                v.setImage(S.T, S.C, S.Limits, tc.UmPerPx);
                tImg(i) = toc(t0);
                v.setPoints(S.Ids, S.XY, S.RGB);
                tPts(i) = toc(t0) - tImg(i);
                drawnow;
                t(i) = toc(t0);
            end
            r = tc.Warmup + 1:total;
            tc.record('NewSource', 1000 * t(r), sprintf('  [setImage call %.0f ms (build %.0f), setPoints call %.1f ms, drawnow %.0f ms]', ...
                1000 * median(tImg(r)), v.LastTimings.BuildMs, 1000 * median(tPts(r)), 1000 * median(t(r) - tImg(r) - tPts(r))));
            % without the limits (computed from page percentiles), and alternating page sizes
            t = zeros(8, 1);
            for i = 1:8
                drawnow;
                t0 = tic;
                tc.showSource(2 - mod(i, 2), []);
                drawnow;
                t(i) = toc(t0);
            end
            fprintf('[perf]   limits computed by setImage: median %.0f ms\n', 1000 * median(t(3:end)));
            small = tc.Src(2);
            small.T = small.T(1:3200, 1:2300);
            small.C = small.C(1:3200, 1:2300);
            for i = 1:8
                drawnow;
                t0 = tic;
                if mod(i, 2)
                    v.setImage(small.T, small.C, small.Limits, tc.UmPerPx);
                    v.setPoints(small.Ids, min(small.XY, [2300 3200]), small.RGB);
                else
                    tc.showSource(1);
                end
                drawnow;
                t(i) = toc(t0);
            end
            fprintf('[perf]   page size alternating 3277 x 2355 / 3200 x 2300: median %.0f ms (max %.0f)\n', ...
                1000 * median(t(3:end)), 1000 * max(t(3:end)));
            tc.showSource(1);
            drawnow;
            % display changes (one CData push each; not budgeted)
            modes = ["companion" "overlay" "target"];
            t = zeros(9, 1);
            for i = 1:9
                t0 = tic; v.setMode(modes(mod(i - 1, 3) + 1)); drawnow; t(i) = toc(t0);
            end
            fprintf('[perf]   setMode (cached after the first of each): median %.0f ms, first three %s ms\n', ...
                1000 * median(t(4:end)), mat2str(round(1000 * t(1:3)')));
            t = zeros(8, 1);
            for i = 1:8
                t0 = tic; v.setGain(1 + i / 4); drawnow; t(i) = toc(t0);
            end
            fprintf('[perf]   setGain (a new look-up table each time): median %.0f ms\n', 1000 * median(t));
            v.setGain(1);
            drawnow;
        end

        function testUpdatePoints(tc)
            v = tc.View;
            tc.showSource(1);
            drawnow;
            S = tc.Src(1);
            cols = uint8([0 158 115; 213 94 0; 110 110 110]);
            total = tc.Warmup + tc.Reps;
            [t1, t150] = deal(zeros(total, 1));
            for i = 1:total
                id = S.Ids(mod(37 * i, numel(S.Ids)) + 1);
                t0 = tic;
                v.updatePoints(id, cols(mod(i, 3) + 1, :));
                drawnow;
                t1(i) = toc(t0);
            end
            st = RandStream('mt19937ar', 'Seed', 3);
            for i = 1:total
                ids = S.Ids(randperm(st, numel(S.Ids), 150));
                t0 = tic;
                v.updatePoints(ids, cols(mod(i, 3) + 1, :));
                drawnow;
                t150(i) = toc(t0);
            end
            r = tc.Warmup + 1:total;
            tc.record('UpdateOne', 1000 * t1(r), '');
            tc.record('Update150', 1000 * t150(r), '');
            % other point operations (not budgeted)
            t = zeros(12, 1);
            for i = 1:12
                t0 = tic; v.setVisible(S.Ids, mod(i, 2) == 0 | mod(double(S.Ids), 3) == 0); drawnow; t(i) = toc(t0);
            end
            fprintf('[perf]   setVisible (all 2800, one push): median %.1f ms\n', 1000 * median(t(3:end)));
            v.setVisible(S.Ids, true);
            for i = 1:12
                t0 = tic; v.setSelection(S.Ids(i:i + 20)); drawnow; t(i) = toc(t0);
            end
            fprintf('[perf]   setSelection (21 rings): median %.1f ms\n', 1000 * median(t(3:end)));
            for i = 1:12
                t0 = tic; v.movePoints(S.Ids(5), S.XY(5, :) + i); drawnow; t(i) = toc(t0);
            end
            fprintf('[perf]   movePoints (1 point): median %.1f ms\n', 1000 * median(t(3:end)));
            for i = 1:12
                t0 = tic; v.addPoints(uint32(900000 + i), S.XY(i, :) + 3, [255 0 0]); drawnow; t(i) = toc(t0);
            end
            fprintf('[perf]   addPoints (1 point): median %.1f ms\n', 1000 * median(t(3:end)));
            for i = 1:12
                t0 = tic; v.removePoints(uint32(900000 + i)); drawnow; t(i) = toc(t0);
            end
            fprintf('[perf]   removePoints (1 point): median %.1f ms\n', 1000 * median(t(3:end)));
            v.setSelection([]);
        end

        function testZoomAndPan(tc)
            v = tc.View;
            tc.showSource(1);
            drawnow;
            mid = tc.middle();
            [t1, s1, w1] = tc.zoomSequence(mid + [137 -91]);
            [t2, s2, w2] = tc.zoomSequence(mid + [-260 150]);
            t = [t1(tc.Warmup + 1:end); t2];
            sc = [s1(tc.Warmup + 1:end, :); s2];
            sw = [w1(tc.Warmup + 1:end); w2];
            tc.record('ZoomStep', 1000 * t, sprintf(['  [%d steps; %.1f-%.3f image px per screen px; max %.1f ms; ' ...
                'steps that switched the interpolation %s ms, the others median %.1f ms]'], numel(t), max(sc(:)), ...
                min(sc(:)), 1000 * max(t), mat2str(round(1000 * t(sw)', 1)), 1000 * median(t(~sw))));
            bands = [Inf 2; 2 1; 1 0.25; 0.25 0];
            for b = 1:size(bands, 1)
                in = sc(:, 2) < bands(b, 1) & sc(:, 2) >= bands(b, 2);
                if any(in)
                    fprintf('[perf]   zoom steps at %5.2f-%4.2f image px per screen px: median %.1f ms (n=%d)\n', ...
                        bands(b, 2), min(bands(b, 1), max(sc(:))), 1000 * median(t(in)), nnz(in));
                end
            end

            % pan: a middle-button drag going round in a circle (no clamping), at three zoom levels
            levels = [4 1; 1 0; 0.06 0];
            label = ["4x zoom" "1 image px per screen px" "deepest zoom"];
            res = cell(1, 3);
            for L = 1:3
                v.fit();
                if L == 1
                    v.zoomBy(4);
                else
                    v.centerOn([1200 1600]);
                    v.zoomBy(v.Scale / max(levels(L, 1), 1e-9));
                end
                drawnow;
                v.onButtonDown(struct('FigurePoint', mid, 'SelectionType', 'extend'));
                n = tc.Warmup + 40;
                tp = zeros(n, 1);
                for i = 1:n
                    a = 2 * pi * i / 40;
                    fp = mid + 120 * [cos(a) - 1, sin(a)];
                    t0 = tic;
                    v.onMotion(struct('FigurePoint', fp));
                    drawnow;
                    tp(i) = toc(t0);
                end
                v.onButtonUp(struct('FigurePoint', fp));
                res{L} = 1000 * tp(tc.Warmup + 1:end);
                fprintf('[perf]   pan frames at %-26s median %.1f ms (max %.1f)\n', label(L), median(res{L}), max(res{L}));
            end
            tc.record('PanStep', vertcat(res{:}), '');

            % hover while moving the pointer (no button): pick + ring update
            v.fit();
            drawnow;
            S = tc.Src(1);
            th = zeros(30, 1);
            for i = 1:30
                t0 = tic;
                v.onMotion(struct('AxesPoint', S.XY(i, :) + [1 0]));
                drawnow;
                th(i) = toc(t0);
            end
            fprintf('[perf]   hover frame (pointer onto a new point): median %.1f ms\n', 1000 * median(th(4:end)));

            % the interpolation switch on its own
            ti = zeros(10, 1);
            modes = ["bilinear" "nearest"];
            for i = 1:10
                t0 = tic; v.Image.Interpolation = modes(mod(i, 2) + 1); drawnow; ti(i) = toc(t0);
            end
            fprintf('[perf]   Image.Interpolation toggled + drawnow: median %.1f ms\n', 1000 * median(ti(3:end)));
            v.fit();
        end

        function testCenterOn(tc)
            v = tc.View;
            tc.showSource(1);
            drawnow;
            st = RandStream('mt19937ar', 'Seed', 9);
            total = tc.Warmup + tc.Reps;
            t = zeros(total, 1);
            for i = 1:total
                xy = [rand(st) * tc.PageSize(2), rand(st) * tc.PageSize(1)];
                w = 100 + 100 * mod(i, 2);
                t0 = tic;
                v.centerOn(xy, w);
                drawnow;
                t(i) = toc(t0);
            end
            tc.record('CenterOn', 1000 * t(tc.Warmup + 1:end), '  [alternating 100 / 200 um half widths]');
            % the sweep stepper uses the same path
            R = v.sweepRects(400, 0.1);
            t = zeros(min(23, size(R, 1)), 1);
            for k = 1:numel(t)
                t0 = tic; v.showSweepRect(k); drawnow; t(k) = toc(t0);
            end
            fprintf('[perf]   showSweepRect (%d fields of 400 um): median %.1f ms\n', size(R, 1), 1000 * median(t(4:end)));
            v.showSweepRect(0);
            v.fit();
        end

        function testPick(tc)
            v = tc.View;
            tc.showSource(1);
            st = RandStream('mt19937ar', 'Seed', 4);
            n = 2000;
            q = [rand(st, n, 1) * tc.PageSize(2), rand(st, n, 1) * tc.PageSize(1)];
            t = zeros(n, 1);
            hits = 0;
            for i = 1:n
                t0 = tic;
                id = v.pick(q(i, :), 15);
                t(i) = toc(t0);
                hits = hits + (id > 0);
            end
            tc.record('Pick', 1000 * t(101:end), sprintf('  [%d of %d queries hit a point within 15 px]', hits, n));
        end

        function testDragFrame(tc)
            v = tc.View;
            tc.showSource(1);
            S = tc.Src(1);
            v.Tool = "move";
            res = [];
            for j = 1:3
                k = 100 * j;
                v.centerOn(S.XY(k, :), 150);
                if j == 3; v.setSelection(S.Ids(k)); end       % a selected point: its ring follows too
                drawnow;
                v.onButtonDown(struct('AxesPoint', S.XY(k, :), 'SelectionType', 'normal'));
                tc.assertEqual(v.Gesture, "move");
                fp0 = v.dataToFigure(S.XY(k, :));
                n = tc.Warmup + 25;
                t = zeros(n, 1);
                for i = 1:n
                    t0 = tic;
                    v.onMotion(struct('FigurePoint', fp0 + [4 * i, 2 * i]));
                    drawnow;
                    t(i) = toc(t0);
                end
                tPress = tic;
                v.onButtonUp(struct('FigurePoint', fp0 + [4 * n, 2 * n]));
                drawnow;
                tDrop = toc(tPress);
                res = [res; 1000 * t(tc.Warmup + 1:end)]; %#ok<AGROW>
                fprintf('[perf]   drag %d%s: frames median %.1f ms (first, which hides the point in the scatter, %.1f ms); drop %.1f ms\n', ...
                    j, string(ifelse(j == 3, ' (selected)', '')), 1000 * median(t(tc.Warmup + 1:end)), 1000 * t(1), 1000 * tDrop);
                v.movePoints(S.Ids(k), S.XY(k, :));
            end
            tc.record('DragFrame', res, '');
            v.setSelection([]);

            % a lasso frame (not budgeted)
            v.Tool = "lasso";
            v.fit();
            drawnow;
            mid = tc.middle();
            v.onButtonDown(struct('FigurePoint', mid, 'SelectionType', 'normal'));
            t = zeros(60, 1);
            for i = 1:60
                a = 2 * pi * i / 60;
                t0 = tic;
                v.onMotion(struct('FigurePoint', mid + 200 * [cos(a) - 1, sin(a)]));
                drawnow;
                t(i) = toc(t0);
            end
            t0 = tic;
            v.onButtonUp(struct('FigurePoint', mid));
            drawnow;
            fprintf('[perf]   lasso: frames median %.1f ms (60 vertices at the end); release incl. inpolygon %.1f ms\n', ...
                1000 * median(t(4:end)), 1000 * toc(t0));
            v.Tool = "select";
        end

        function testVisibleLatency(tc)
            % drawnow returning does not prove the browser has painted. getframe returns what is drawn, so
            % (change + drawnow + getframe) - (trivial change + drawnow + getframe) estimates the time until
            % a zoom step is on screen. Informative only (getframe itself takes hundreds of ms).
            v = tc.View;
            tc.showSource(1);
            v.fit();
            drawnow;
            try
                F = getframe(v.Axes); %#ok<NASGU>
            catch err
                tc.assumeFail("getframe of a uifigure axes failed here: " + err.message);
            end
            reps = 8;
            [tCtl, tZoom] = deal(zeros(reps, 1));
            S = tc.Src(1);
            for i = 1:reps
                t0 = tic;
                v.setSelection(S.Ids(i));
                drawnow;
                F = getframe(v.Axes); %#ok<NASGU>
                tCtl(i) = toc(t0);
                t0 = tic;
                v.zoomBy(1.25 ^ (2 * mod(i, 2) - 1), S.XY(i, :));
                drawnow;
                F = getframe(v.Axes); %#ok<NASGU>
                tZoom(i) = toc(t0);
            end
            fprintf(['[perf] visible latency (change + drawnow + getframe of the axes), median of %d:\n' ...
                '[perf]   after a selection ring moved (control)  %6.1f ms\n' ...
                '[perf]   after a zoom step                       %6.1f ms  (%+.1f ms vs the control)\n'], ...
                reps, 1000 * median(tCtl), 1000 * median(tZoom), 1000 * (median(tZoom) - median(tCtl)));
            v.setSelection([]);
            v.fit();
        end

        function testDisplayStrategies(tc)
            % (A) the full-resolution page pushed once, the axes resample it on every zoom/pan (what MapView
            % does) against (B) an overview plus a full-resolution window re-cut and pushed whenever the
            % view leaves it. Plain graphics in a separate figure of the same size; no budget: informs the
            % design.
            S = tc.Src(1);
            [H, W] = size(S.T);
            uT = uint8((double(S.T) - S.Limits(1, 1)) * (255 / diff(S.Limits(1, :))));
            uC = uint8((double(S.C) - S.Limits(2, 1)) * (255 / diff(S.Limits(2, :))));
            gray = cat(3, uT, uT, uT);
            over = cat(3, uC, uT, uC);
            t0 = tic;
            ov2 = imresize(gray, 0.5, 'box');
            tOv = toc(t0);
            f = uifigure('Name', 'tMapPerf strategies', 'Position', [10 10 tc.MapSize]);
            cleanup = onCleanup(@() delete(f));
            p = uipanel(f, 'Position', [1 1 tc.MapSize], 'BorderType', 'none', 'AutoResizeChildren', 'off');
            ax = axes(p, 'Units', 'pixels');
            ax.InnerPosition = [1 1 tc.MapSize];
            set(ax, 'YDir', 'reverse', 'XTick', [], 'YTick', [], 'XColor', 'none', 'YColor', 'none', ...
                'XLimMode', 'manual', 'YLimMode', 'manual', 'NextPlot', 'add', 'SortMethod', 'childorder');
            try ax.Toolbar = []; catch; end
            try disableDefaultInteractivity(ax); catch; end
            try ax.Interactions = []; catch; end
            img = image('Parent', ax, 'CData', zeros(1, 1, 3, 'uint8'), 'HitTest', 'off', 'PickableParts', 'none');
            drawnow;
            pw = tc.MapSize(1);
            ph = tc.MapSize(2);
            setView = @(c, s) set(ax, 'XLim', c(1) + [-1 1] * pw * s / 2, 'YLim', c(2) + [-1 1] * ph * s / 2);
            fitS = max(W / pw, H / ph);

            fprintf('\n[perf] display strategies (separate %d x %d figure; median ms, change + drawnow):\n', pw, ph);
            t = zeros(10, 1);
            set(img, 'XData', [1 W], 'YData', [1 H]);
            setView([W H] / 2 + 0.5, fitS);
            data = {gray, over};
            for i = 1:10
                t0 = tic; img.CData = data{mod(i, 2) + 1}; drawnow; t(i) = toc(t0);
            end
            fprintf('[perf]   (A) push the full-res RGB page (%d x %d x 3, %.0f MB): first %.0f ms, then median %.0f ms\n', ...
                W, H, numel(gray) / 2^20, 1000 * t(1), 1000 * median(t(3:end)));
            for interp = ["nearest" "bilinear"]
                img.Interpolation = interp;
                drawnow;
                c = [W * 0.4 H * 0.55];
                ns = ceil(log(fitS / (40 / ph)) / log(1.25));
                s = fitS ./ 1.25 .^ [0:ns, ns - 1:-1:0];
                tz = zeros(numel(s) - 1, 1);
                setView(c, s(1));
                drawnow;
                for i = 2:numel(s)
                    t0 = tic; setView(c, s(i)); drawnow; tz(i - 1) = toc(t0);
                end
                tp = zeros(30, 1);
                for i = 1:30
                    c(1) = c(1) + 20 * fitS / 4 * (1 - 2 * (i > 15));
                    t0 = tic; setView(c, fitS / 4); drawnow; tp(i) = toc(t0);
                end
                fprintf('[perf]   (A) %-8s zoom step (limits only) median %.1f ms (max %.1f, %d steps); pan step at 4x %.1f ms\n', ...
                    interp, 1000 * median(tz), 1000 * max(tz), numel(tz), 1000 * median(tp(4:end)));
            end
            img.Interpolation = 'nearest';
            fprintf('[perf]   (B) overview: box-downsampled x2 RGB page built in %.0f ms (%d x %d)\n', 1000 * tOv, ...
                size(ov2, 2), size(ov2, 1));
            sizes = [size(ov2, 2) size(ov2, 1); pw ph; round(1.5 * pw) round(1.5 * ph); 2 * pw 2 * ph];
            names = ["the overview" "a 1x window" "a 1.5x window (margin)" "a 2x window"];
            for k = 1:size(sizes, 1)
                w = min(W, sizes(k, 1));
                h = min(H, sizes(k, 2));
                t = zeros(12, 1);
                for i = 1:12
                    x0 = 1 + mod(37 * i, W - w + 1);
                    y0 = 1 + mod(53 * i, H - h + 1);
                    t0 = tic;
                    if k == 1
                        set(img, 'CData', ov2, 'XData', [1.5 W - 0.5], 'YData', [1.5 H - 0.5]);
                    else
                        set(img, 'CData', gray(y0:y0 + h - 1, x0:x0 + w - 1, :), 'XData', [x0 x0 + w - 1], 'YData', [y0 y0 + h - 1]);
                    end
                    setView([x0 + w / 2, y0 + h / 2], w / pw / 1.5);
                    drawnow;
                    t(i) = toc(t0);
                end
                fprintf('[perf]   (B) re-cut + push %-24s (%4d x %4d) + limits: median %.1f ms\n', names(k), w, h, 1000 * median(t(3:end)));
            end
            fprintf(['[perf]   => (A) zoom/pan steps change only the limits; (B) pays a re-cut + push whenever the view ' ...
                'leaves its window or the level changes\n']);
            clear cleanup
        end
    end
end

function v = prctile90(x)
x = sort(x(:));
v = x(max(1, ceil(0.9 * numel(x))));
end

function y = ifelse(c, a, b)
if c; y = a; else; y = b; end
end
