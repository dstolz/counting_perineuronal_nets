classdef (TestTags = {'Benchmark'}) tGalleryPerf < matlab.unittest.TestCase
    %tGalleryPerf  Speed budgets of the gallery on a real-size source: two 3277 x 2355 float32 pages,
    %   2,000 cells, 126 tiles of 80 px per page (14 x 9, a 1120 x 720 mosaic). Each time is the median
    %   of >= 20 repetitions after a warm-up, measured from tic until drawnow has returned. Fails when a
    %   budget is exceeded; prints every measurement and a summary table, plus the comparison of display
    %   arrangements and how the page swap scales with the tile count.
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 -IncludeSlow tGalleryPerf

    properties (Constant)
        PageSize = [3277 2355]
        UmPerPx = 1.657
        NCells = 2000
        Grid = [9 14]
        Reps = 25
        Warmup = 3
        Budget = struct('Build', 2000, 'Compose', 10, 'ShowPrefetched', 100, 'ShowCold', 130, ...
            'UpdateOne', 30, 'UpdateAll', 30)
    end

    properties
        PageT
        PageC
        Ids
        XY
        Cache
        Fig
        View
        Perm
        Results      % containers.Map shared by the test methods: name -> [median budget]
    end

    % ------------------------------------------------------------------------------------------------
    methods (TestClassSetup)
        function setupSourceAndFigure(tc)
            % one method: TestClassSetup methods run in no guaranteed order
            tc.makeSource();
            tc.makeFigure();
        end
    end

    methods
        function makeSource(tc)
            rng(2026);
            H = tc.PageSize(1);
            W = tc.PageSize(2);
            n = tc.NCells;
            xy = [1 + rand(n, 1) * (W - 1), 1 + rand(n, 1) * (H - 1)];
            imp = zeros(H, W, 'single');
            imp(sub2ind([H W], round(xy(:, 2)), round(xy(:, 1)))) = 1;
            r = -15:15;
            gw = single(exp(-r.^2 / (2 * 4^2)));
            gn = single(exp(-r.^2 / (2 * 2^2)));
            wide = conv2(gw, gw, imp, 'same');
            narrow = conv2(gn, gn, imp, 'same');
            noise = randn(H, W, 'single');
            tc.PageT = 37.5 * (3 + 6 * (wide - 0.7 * narrow) + 0.4 * noise);   % ring-like cells, arbitrary scale
            tc.PageC = 0.0021 * (1 + 5 * narrow + 0.3 * noise);                % solid cells, another scale
            tc.Ids = uint32((1:n)' + 1000);
            tc.XY = xy;
            tc.Perm = randperm(n);
            tc.Results = containers.Map();
            t0 = tic;
            tc.Cache = curation.CropCache.build(tc.PageT, tc.PageC, tc.Ids, tc.XY, tc.UmPerPx);
            fprintf('\n[perf] source: %d x %d %s pages, %d cells, first build %.0f ms\n', H, W, ...
                class(tc.PageT), n, 1000 * toc(t0));
            ss = get(groot, 'ScreenSize');
            fprintf('[perf] screen %d x %d px, %s, MATLAB %s\n', ss(3), ss(4), computer, version);
        end

        function makeFigure(tc)
            tc.Fig = uifigure('Name', 'tGalleryPerf', 'Position', [10 10 1140 740]);
            gl = uigridlayout(tc.Fig, [1 1], 'Padding', [0 0 0 0]);
            tc.View = curation.GalleryView(gl);
            tc.View.setCache(tc.Cache);
            t0 = tic;    % the grid is laid out in the browser: wait until the panel has its size
            while toc(t0) < 10
                drawnow;
                if isequal(tc.View.Panel.Position(3:4), tc.Fig.Position(3:4)); break; end
                pause(0.05);
            end
            [r, c] = tc.View.capacity();
            fprintf('[perf] gallery panel fits %d x %d tiles; the benchmark uses %d x %d\n', c, r, ...
                tc.Grid(2), tc.Grid(1));
            tc.View.setGrid(tc.Grid(1), tc.Grid(2));
        end
    end

    methods (TestClassTeardown)
        function summaryAndClose(tc)
            tc.printSummary();
            if ~isempty(tc.Fig) && isvalid(tc.Fig); delete(tc.Fig); end
        end
    end

    methods
        function printSummary(tc)
            names = ["Build" "Compose" "ShowPrefetched" "ShowCold" "UpdateOne" "UpdateAll"];
            what = ["CropCache.build, 2000 cells, both channels" "compose 126 tiles (target)" ...
                "showPage, prefetched" "showPage, not prefetched" "updateTiles, 1 tile" "updateTiles, 126 tiles"];
            fprintf('\n[perf] ================= summary (median ms, tic -> drawnow returned) =================\n');
            fprintf('[perf] %-46s %10s %10s  %s\n', 'action', 'measured', 'budget', 'verdict');
            for i = 1:numel(names)
                if ~isKey(tc.Results, names(i)); continue; end
                v = tc.Results(names(i));
                verdict = "ok";
                if v(1) > v(2); verdict = "OVER BUDGET"; end
                fprintf('[perf] %-46s %10.1f %10.0f  %s\n', what(i), v(1), v(2), verdict);
            end
            fprintf('[perf] =====================================================================================\n');
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods
        function ids = pageIds(tc, i, n)
            k = mod((i - 1) * n + (0:n - 1), numel(tc.Perm)) + 1;
            ids = tc.Ids(tc.Perm(k));
        end

        function s = pageStyle(~, i, n, mode)
            %pageStyle  A realistic page style: label borders (most unreviewed), a few flag badges.
            if nargin < 4; mode = "target"; end
            st = RandStream('mt19937ar', 'Seed', i);
            u = rand(st, n, 1);
            col = repmat([110 110 110], n, 1);          % unreviewed
            col(u > 0.7, :) = repmat([0 158 115], nnz(u > 0.7), 1);     % Good
            col(u > 0.9, :) = repmat([213 94 0], nnz(u > 0.9), 1);      % Bad
            corner = NaN(n, 3);
            f = rand(st, n, 1) > 0.95;
            corner(f, :) = repmat([240 228 66], nnz(f), 1);
            s = struct('Mode', mode, 'BorderRGB', uint8(col), 'CornerRGB', corner, 'Dim', false(n, 1));
        end

        function record(tc, name, ms, extra)
            budget = tc.Budget.(name);
            tc.Results(name) = [median(ms) budget];
            fprintf('[perf] %-16s median %7.1f ms  (min %6.1f, p90 %6.1f, n=%d)  budget %g ms%s\n', name, ...
                median(ms), min(ms), prctile90(ms), numel(ms), budget, extra);
            tc.verifyLessThanOrEqual(median(ms), budget, sprintf('%s: median %.1f ms exceeds the %g ms budget', ...
                name, median(ms), budget));
        end

        function [tTotal, tCall] = timeShow(tc, prefetched, grid, nRep)
            %timeShow  Median-able times of showPage (+ drawnow) over NREP pages of GRID.
            g = tc.View;
            g.setGrid(grid(1), grid(2));
            n = prod(grid);
            total = tc.Warmup + nRep;
            tTotal = zeros(total, 1);
            tCall = zeros(total, 1);
            for i = 1:total
                ids = tc.pageIds(i, n);
                s = tc.pageStyle(i, n);
                if prefetched; g.prefetch(ids, s); end
                drawnow;
                t0 = tic;
                g.showPage(ids, s);
                tCall(i) = toc(t0);
                drawnow;
                tTotal(i) = toc(t0);
                tc.assertEqual(g.LastTimings.Prefetched, prefetched);
            end
            tTotal = 1000 * tTotal(tc.Warmup + 1:end);
            tCall = 1000 * tCall(tc.Warmup + 1:end);
            g.setGrid(tc.Grid(1), tc.Grid(2));
        end

        function reportLargestGrid(tc, prefetched, budget)
            %reportLargestGrid  After a missed budget: the largest page that meets it.
            grids = [8 13; 8 12; 7 11; 7 10; 6 9; 6 8; 5 7; 4 6];
            for j = 1:size(grids, 1)
                t = tc.timeShow(prefetched, grids(j, :), 20);
                fprintf('[perf]   %2d x %2d = %3d tiles: median %.1f ms\n', grids(j, 2), grids(j, 1), prod(grids(j, :)), median(t));
                if median(t) <= budget
                    fprintf('[perf]   largest page within %g ms: %d tiles (%d x %d)\n', budget, prod(grids(j, :)), ...
                        grids(j, 2), grids(j, 1));
                    return
                end
            end
            fprintf('[perf]   no page size meets %g ms\n', budget);
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Test)
        function testBuild(tc)
            total = 2 + 20;
            t = zeros(total, 1);
            for i = 1:total
                t0 = tic;
                c = curation.CropCache.build(tc.PageT, tc.PageC, tc.Ids, tc.XY, tc.UmPerPx); %#ok<NASGU>
                t(i) = toc(t0);
            end
            clear c
            % the parts: page percentiles vs extraction
            t0 = tic;
            curation.CropCache.pageLimits(tc.PageT, [1 99.9], 1e6);
            curation.CropCache.pageLimits(tc.PageC, [1 99.9], 1e6);
            tLim = toc(t0);
            tc.record('Build', 1000 * t(3:end), sprintf('  [page percentiles of both pages: %.0f ms]', 1000 * tLim));
        end

        function testCompose(tc)
            c = tc.Cache;
            n = prod(tc.Grid);
            modes = ["target" "companion" "overlay" "side"];
            for m = modes
                grid = tc.Grid;
                if m == "side"; grid = [9 7]; end            % same pixels: tiles twice as wide
                k = prod(grid);
                total = 5 + 40;
                t = zeros(total, 1);
                for i = 1:total
                    ids = tc.pageIds(i, k);
                    s = tc.pageStyle(i, k, m);
                    t0 = tic;
                    mosaic = c.compose(ids, grid(1), grid(2), s); %#ok<NASGU>
                    t(i) = toc(t0);
                end
                t = 1000 * t(6:end);
                fprintf('[perf] compose %-9s %3d tiles: median %.2f ms (min %.2f, p90 %.2f)\n', m, k, median(t), ...
                    min(t), prctile90(t));
                if m == "target"
                    tc.record('Compose', t, '');
                else
                    tc.verifyLessThanOrEqual(median(t), tc.Budget.Compose, sprintf('compose (%s) %.1f ms', m, median(t)));
                end
            end
            % repaint of one tile (the core of updateTiles)
            ids = tc.pageIds(1, n);
            s = tc.pageStyle(1, n);
            [mosaic, L] = c.compose(ids, tc.Grid(1), tc.Grid(2), s);
            t = zeros(40, 1);
            for i = 1:40
                s.BorderRGB(mod(i, n) + 1, :) = uint8([213 94 0]);
                t0 = tic;
                mosaic = c.repaint(mosaic, L, mod(i, n) + 1, s);
                t(i) = toc(t0);
            end
            fprintf('[perf] repaint 1 tile: median %.2f ms\n', 1000 * median(t(6:end)));
        end

        function testShowPagePrefetched(tc)
            [t, tCall] = tc.timeShow(true, tc.Grid, tc.Reps);
            tc.record('ShowPrefetched', t, sprintf('  [showPage call %.1f ms, drawnow %.1f ms]', median(tCall), ...
                median(t - tCall)));
            if median(t) > tc.Budget.ShowPrefetched
                tc.reportLargestGrid(true, tc.Budget.ShowPrefetched);
            end
        end

        function testShowPageNotPrefetched(tc)
            [t, tCall] = tc.timeShow(false, tc.Grid, tc.Reps);
            tc.record('ShowCold', t, sprintf('  [showPage call incl. compose %.1f ms, drawnow %.1f ms]', median(tCall), ...
                median(t - tCall)));
            if median(t) > tc.Budget.ShowCold
                tc.reportLargestGrid(false, tc.Budget.ShowCold);
            end
        end

        function testUpdateOneTile(tc)
            g = tc.View;
            n = prod(tc.Grid);
            s = tc.pageStyle(1, n);
            g.showPage(tc.pageIds(1, n), s);
            drawnow;
            colors = uint8([0 158 115; 213 94 0; 110 110 110]);
            total = tc.Warmup + tc.Reps;
            t = zeros(total, 1);
            tCall = zeros(total, 1);
            for i = 1:total
                k = mod(7 * i, n) + 1;
                s.BorderRGB(k, :) = colors(mod(i, 3) + 1, :);
                t0 = tic;
                g.updateTiles(k, s);
                tCall(i) = toc(t0);
                drawnow;
                t(i) = toc(t0);
            end
            t = 1000 * t(tc.Warmup + 1:end);
            tCall = 1000 * tCall(tc.Warmup + 1:end);
            tc.record('UpdateOne', t, sprintf('  [updateTiles call %.1f ms, drawnow %.1f ms]', median(tCall), median(t - tCall)));
        end

        function testUpdateAllTiles(tc)
            g = tc.View;
            n = prod(tc.Grid);
            s = tc.pageStyle(2, n);
            g.showPage(tc.pageIds(2, n), s);
            drawnow;
            colors = uint8([0 158 115; 213 94 0]);
            total = tc.Warmup + tc.Reps;
            t = zeros(total, 1);
            tCall = zeros(total, 1);
            for i = 1:total
                s.BorderRGB = repmat(colors(mod(i, 2) + 1, :), n, 1);
                t0 = tic;
                g.updateTiles(1:n, s);
                tCall(i) = toc(t0);
                drawnow;
                t(i) = toc(t0);
            end
            t = 1000 * t(tc.Warmup + 1:end);
            tCall = 1000 * tCall(tc.Warmup + 1:end);
            tc.record('UpdateAll', t, sprintf('  [updateTiles call %.1f ms, drawnow %.1f ms]', median(tCall), median(t - tCall)));
        end

        function testVisibleLatency(tc)
            % drawnow returning does not prove the browser has painted. getframe returns what is drawn, so
            % (change + drawnow + getframe) - (drawnow + getframe without a change) estimates the time
            % until the new pixels are on screen. The captured frame is checked to show them.
            g = tc.View;
            n = prod(tc.Grid);
            g.setGrid(tc.Grid(1), tc.Grid(2));
            red = struct('BorderRGB', uint8([255 0 0]), 'BorderPx', 4);
            blue = struct('BorderRGB', uint8([0 0 255]), 'BorderPx', 4);
            g.showPage(tc.pageIds(1, n), red);
            drawnow;
            try
                F = getframe(g.Axes);
            catch err
                tc.assumeFail("getframe of a uifigure axes failed here: " + err.message);
            end
            reps = 12;
            [tBase, tSwap, tOne, tCur] = deal(zeros(reps, 1));
            [okSwap, okOne] = deal(false(reps, 1));
            for i = 1:reps
                t0 = tic;
                drawnow;
                F = getframe(g.Axes);
                tBase(i) = toc(t0);
                t0 = tic;                    % control: a trivial change (the cursor line moves)
                g.setCursor(mod(i, n) + 1);
                drawnow;
                F = getframe(g.Axes);
                tCur(i) = toc(t0);
                s = red;
                if mod(i, 2); s = blue; end
                ids = tc.pageIds(i + 3, n);
                g.prefetch(ids, s);
                t0 = tic;
                g.showPage(ids, s);
                drawnow;
                F = getframe(g.Axes);
                tSwap(i) = toc(t0);
                okSwap(i) = isequal(tGalleryPerf.frameColor(F, g, 1), double(s.BorderRGB));
                k = 20 + i;
                s.BorderRGB = repmat(s.BorderRGB, n, 1);
                s.BorderRGB(k, :) = [0 255 0];
                t0 = tic;
                g.updateTiles(k, s);
                drawnow;
                F = getframe(g.Axes);
                tOne(i) = toc(t0);
                okOne(i) = isequal(tGalleryPerf.frameColor(F, g, k), [0 255 0]);
            end
            fprintf(['[perf] visible latency (change + drawnow + getframe of the axes), median of %d:\n' ...
                '[perf]   capture, nothing changed       %6.1f ms\n' ...
                '[perf]   capture after a cursor move    %6.1f ms  (control: a trivial change)\n' ...
                '[perf]   capture after a page swap      %6.1f ms  (%+.1f ms vs the control; frame showed the new page %d/%d)\n' ...
                '[perf]   capture after a 1-tile update  %6.1f ms  (%+.1f ms vs the control; frame showed it %d/%d)\n'], ...
                reps, 1000 * median(tBase), 1000 * median(tCur), 1000 * median(tSwap), ...
                1000 * (median(tSwap) - median(tCur)), nnz(okSwap), reps, 1000 * median(tOne), ...
                1000 * (median(tOne) - median(tCur)), nnz(okOne), reps);

            % sustained paging: N swaps back to back, then one capture as a barrier (all rendered)
            N = 30;
            t0 = tic;
            for i = 1:N
                s = red;
                if mod(i, 2); s = blue; end
                g.showPage(tc.pageIds(i + 20, n), s);
                drawnow;
            end
            tLoop = toc(t0);
            F = getframe(g.Axes);
            tAll = toc(t0);
            okLast = isequal(tGalleryPerf.frameColor(F, g, 1), double(s.BorderRGB));
            fprintf(['[perf]   %d page swaps back to back: %.1f ms each until drawnow returned; with the final capture ' ...
                '%.0f ms in all = %.1f ms per page after subtracting one control capture (last page shown: %d)\n'], ...
                N, 1000 * tLoop / N, 1000 * tAll, 1000 * (tAll - median(tCur)) / N, okLast);
            tc.verifyTrue(all(okSwap), 'after drawnow + getframe the captured frame shows the new page');
            tc.verifyTrue(all(okOne), 'after drawnow + getframe the captured frame shows the new border');
        end

        function testDisplayArrangements(tc)
            % How fast a new CData reaches the screen in different arrangements (no budget: informs the
            % design). Two different 1120 x 720 mosaics alternate, so every push changes the pixels.
            n = prod(tc.Grid);
            m1 = tc.Cache.compose(tc.pageIds(1, n), tc.Grid(1), tc.Grid(2), tc.pageStyle(1, n));
            m2 = tc.Cache.compose(tc.pageIds(2, n), tc.Grid(1), tc.Grid(2), tc.pageStyle(2, n));
            M = {m1, m2};
            I = {m1(:, :, 2), m2(:, :, 2)};
            cfgs = {
                'uifigure > uipanel > axes, pixel-exact, nearest', 'uipanel-axes', 'drawnow', 'rgb'
                '  same, drawnow limitrate', 'uipanel-axes', 'limitrate', 'rgb'
                '  same, drawnow nocallbacks', 'uipanel-axes', 'nocallbacks', 'rgb'
                '  same, no CData change (drawnow round trip only)', 'uipanel-axes', 'nochange', 'rgb'
                '  same, indexed uint8 CData + gray colormap', 'uipanel-axes', 'drawnow', 'indexed'
                '  same, default axes interactions left on', 'uipanel-axes-interactive', 'drawnow', 'rgb'
                '  same, zoom 1.25, bilinear interpolation', 'uipanel-axes-zoom', 'drawnow', 'rgb'
                'uifigure > uipanel > uiaxes, pixel-exact', 'uipanel-uiaxes', 'drawnow', 'rgb'
                'uifigure > uigridlayout > uiaxes, stretched to cell', 'grid-uiaxes', 'drawnow', 'rgb'
                'figure (not uifigure) > axes, pixel-exact', 'figure-axes', 'drawnow', 'rgb'
                };
            fprintf('\n[perf] display arrangements: CData push of a %d x %d RGB mosaic + flush (median of 25 ms)\n', ...
                size(m1, 2), size(m1, 1));
            for j = 1:size(cfgs, 1)
                try
                    [f, img] = tGalleryPerf.arrangement(cfgs{j, 2}, size(m1), cfgs{j, 4});
                    cleanup = onCleanup(@() delete(f));
                    if cfgs{j, 4} == "indexed"; data = I; else; data = M; end
                    t = zeros(28, 1);
                    for i = 1:28
                        t0 = tic;
                        if cfgs{j, 3} ~= "nochange"; img.CData = data{mod(i, 2) + 1}; end
                        switch cfgs{j, 3}
                            case 'limitrate';   drawnow limitrate;
                            case 'nocallbacks'; drawnow nocallbacks;
                            otherwise;          drawnow;
                        end
                        t(i) = toc(t0);
                    end
                    if cfgs{j, 3} == "limitrate"; drawnow; end
                    fprintf('[perf]   %-58s %7.1f ms (min %5.1f)\n', cfgs{j, 1}, 1000 * median(t(4:end)), 1000 * min(t(4:end)));
                    clear cleanup
                catch err
                    fprintf('[perf]   %-58s failed: %s\n', cfgs{j, 1}, err.message);
                end
            end

            % the page swap against the tile count (the GalleryView, prefetched pages)
            fprintf('[perf] GalleryView.showPage (prefetched) + drawnow against the page size:\n');
            grids = [4 6; 6 9; 7 11; 8 12; 9 14; 10 16; 12 18];
            for j = 1:size(grids, 1)
                t = tc.timeShow(true, grids(j, :), 20);
                fprintf('[perf]   %2d x %2d = %3d tiles (%4d x %4d px): median %6.1f ms\n', grids(j, 2), grids(j, 1), ...
                    prod(grids(j, :)), grids(j, 2) * 80, grids(j, 1) * 80, median(t));
            end
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Static)
        function c = frameColor(F, g, k)
            %frameColor  Color of a captured frame (getframe of the gallery axes) in the middle of tile
            %   K's left border band (the frame may be scaled by the display's DPI).
            L = g.Layout;
            sc = size(F.cdata, 2) / L.Size(2);
            r = L.Rect(k, :);
            x = r(1) + L.BorderPx / 2 - 0.5;            % center of the band, mosaic units
            y = r(2) + r(4) / 2;
            fx = min(size(F.cdata, 2), max(1, round((x - 0.5) * sc + 0.5)));
            fy = min(size(F.cdata, 1), max(1, round((y - 0.5) * sc + 0.5)));
            c = double(reshape(F.cdata(fy, fx, :), 1, 3));
        end

        function [f, img] = arrangement(kind, sz, data)
            %arrangement  A figure with one image of size SZ shown the way KIND says.
            H = sz(1); W = sz(2);
            pos = [10 10 W + 20 H + 20];
            if kind == "figure-axes"
                f = figure('Position', pos, 'Name', 'arrangement', 'MenuBar', 'none', 'ToolBar', 'none');
                parent = f;
            else
                f = uifigure('Position', pos, 'Name', 'arrangement');
                if kind == "grid-uiaxes"
                    parent = uigridlayout(f, [1 1], 'Padding', [0 0 0 0]);
                else
                    parent = uipanel(f, 'Position', [1 1 pos(3:4)], 'BorderType', 'none', 'AutoResizeChildren', 'off');
                end
            end
            zoom = 1;
            if kind == "uipanel-axes-zoom"; zoom = 1.25; f.Position(3:4) = ceil(pos(3:4) * 1.25); end
            switch kind
                case {"uipanel-uiaxes", "grid-uiaxes"}
                    ax = uiaxes(parent);
                otherwise
                    ax = axes(parent);
            end
            set(ax, 'XLim', [0.5 W + 0.5], 'YLim', [0.5 H + 0.5], 'YDir', 'reverse', 'XTick', [], 'YTick', [], ...
                'XColor', 'none', 'YColor', 'none', 'XLimMode', 'manual', 'YLimMode', 'manual');
            if kind == "grid-uiaxes"
                ax.DataAspectRatio = [1 1 1];
            else
                ax.Units = 'pixels';
                ax.InnerPosition = [11 11 round(W * zoom) round(H * zoom)];
            end
            if kind ~= "uipanel-axes-interactive"
                try ax.Toolbar = []; catch; end
                try disableDefaultInteractivity(ax); catch; end
                try ax.Interactions = []; catch; end
            end
            if data == "indexed"
                img = image('Parent', ax, 'CData', zeros(H, W, 'uint8'), 'CDataMapping', 'direct');
                colormap(ax, gray(256));
            else
                img = image('Parent', ax, 'CData', zeros(H, W, 3, 'uint8'));
            end
            if kind == "uipanel-axes-zoom"
                try img.Interpolation = 'bilinear'; catch; end
            end
            drawnow;
        end
    end
end

function v = prctile90(x)
x = sort(x(:));
v = x(max(1, ceil(0.9 * numel(x))));
end
