classdef tGalleryView < matlab.uitest.TestCase
    %tGalleryView  curation.GalleryView in a uifigure: one persistent image, hit testing, cursor and
    %   selection geometry, capacity, prefetch, partial redraw, and the routed mouse events (synthetic
    %   events and matlab.uitest gestures). Opens figures: run it on the hidden desktop
    %   (tools\Run-Tests.ps1 tGalleryView).

    properties
        Cache
        Fig
        Grid
        View
    end

    methods (TestClassSetup)
        function makeCache(tc)
            rng(11);
            H = 600; W = 800; n = 300;
            xy = [rand(n, 1) * (W - 1) + 1, rand(n, 1) * (H - 1) + 1];
            imp = zeros(H, W);
            imp(sub2ind([H W], round(xy(:, 2)), round(xy(:, 1)))) = 1;
            g = exp(-(-8:8).^2 / (2 * 2.5^2));
            page = 10 + 100 * conv2(g, g, imp, 'same') + rand(H, W);
            tc.Cache = curation.CropCache.build(page, flipud(page), (101:100 + n)', xy, 1.657);
        end
    end

    methods (TestMethodSetup)
        function makeFigure(tc)
            tc.Fig = uifigure('Name', 'tGalleryView', 'Position', [40 40 980 660]);
            tc.addTeardown(@() tGalleryView.closeFigure(tc.Fig));
            tc.Grid = uigridlayout(tc.Fig, [1 1], 'Padding', [0 0 0 0]);
            tc.View = curation.GalleryView(tc.Grid);
            tc.View.HoverInterval = 0;
            tc.View.ResizeDebounce = 0;
            tc.View.setCache(tc.Cache);
            tGalleryView.waitForLayout(tc.Fig, tc.View.Panel);
        end
    end

    methods (Static)
        function closeFigure(f)
            if ~isempty(f) && isvalid(f); delete(f); end
        end

        function waitForLayout(fig, panel, expected)
            %waitForLayout  Wait (up to 10 s) until the grid has given PANEL the figure's size: a uifigure
            %   lays its grids out in the browser, and Position values arrive after drawnow returns.
            %   EXPECTED ([width height], optional) is the size just requested for the figure. A resize
            %   is applied asynchronously too, so right after setting Position the figure can still
            %   report its OLD size, and "panel matches figure" would then be true at once; with
            %   EXPECTED the wait ends only when both have reached the new size.
            if nargin < 3, expected = []; end
            t0 = tic;
            while toc(t0) < 10
                drawnow;
                p = panel.Position;
                f = fig.Position;
                if isequal(p(3:4), f(3:4)) && (isempty(expected) || isequal(f(3:4), expected)); break; end
                pause(0.05);
            end
            persistent told
            if isempty(told)
                told = true;
                fprintf('[tGalleryView] layout settled after %.2f s: figure %s, panel %s, screen %s\n', toc(t0), ...
                    mat2str(fig.Position), mat2str(panel.Position), mat2str(get(groot, 'ScreenSize')));
            end
        end

        function gestureOrSkip(tc, fn, what)
            %gestureOrSkip  Run a matlab.uitest gesture; skip the test when the framework cannot do it.
            try
                fn();
            catch err
                if contains(err.identifier, ["uiautomation", "uitest", "UIAutomation"], 'IgnoreCase', true)
                    tc.assumeFail(sprintf('matlab.uitest %s is not available here: %s', what, err.message));
                end
                rethrow(err);
            end
        end

        function ev = at(pt, varargin)
            %at  A synthetic mouse event at mosaic point PT.
            ev = struct('AxesPoint', pt, varargin{:});
        end
    end

    methods
        function ids = page(tc, k, n)
            %page  The ids of page K of N tiles.
            all = double(tc.Cache.Ids);
            i0 = mod((k - 1) * n, numel(all));
            ids = all(mod(i0 + (0:n - 1), numel(all)) + 1);
        end

        function rec = recorder(tc)
            %recorder  Wire every callback of the view to a log: rec('log') is a cell of event structs.
            store = containers.Map('KeyType', 'char', 'ValueType', 'any');
            store('log') = {};
            function add(kind, g, in)
                L = store('log');
                L{end + 1} = struct('Kind', kind, 'Tile', in.Tile, 'Id', in.Id, 'SelectionType', string(in.SelectionType), ...
                    'StartTile', in.StartTile, 'Tiles', in.Tiles); %#ok<AGROW>
                store('log') = L;
                tc.verifySameHandle(g, tc.View);
            end
            tc.View.TileClickFcn = @(g, in) add('click', g, in);
            tc.View.TileDragFcn = @(g, in) add('drag', g, in);
            tc.View.DragEndFcn = @(g, in) add('end', g, in);
            tc.View.TileHoverFcn = @(g, in) add('hover', g, in);
            rec = store;
        end
    end

    methods (Static)
        function [kinds, tiles] = events(store)
            L = store('log');
            kinds = strings(1, numel(L));
            tiles = zeros(1, numel(L));
            for i = 1:numel(L)
                kinds(i) = L{i}.Kind;
                tiles(i) = L{i}.Tile;
            end
        end
    end

    methods (Test)
        function testOneImagePersistsAcrossPages(tc)
            g = tc.View;
            [r, c] = g.capacity();
            n = r * c;
            tc.verifyGreaterThan(n, 20);
            g.showPage(tc.page(1, n), struct());
            drawnow;
            ax = g.Axes;
            img = g.Image;
            nChildren = numel(ax.Children);
            nPanel = numel(allchild(g.Panel));
            nAll = numel(findall(tc.Fig));
            tc.verifyEqual(nChildren, 3, 'image, cursor line, selection line');
            for k = 2:51
                style = struct('BorderRGB', repmat(uint8([90 90 90]), n, 1));
                if mod(k, 2); g.prefetch(tc.page(k, n), style); end
                g.showPage(tc.page(k, n), style);
                g.setCursor(mod(k, n) + 1);
                g.setSelection([1 3 5]);
                drawnow;
            end
            tc.verifySameHandle(g.Image, img);
            tc.verifyTrue(isvalid(img));
            tc.verifyEqual(numel(findobj(ax, 'Type', 'image')), 1);
            tc.verifyEqual(numel(ax.Children), nChildren, 'no growth in the axes'' children');
            tc.verifyEqual(numel(findall(g.Panel, 'Type', 'axes')), 1);
            tc.verifyEqual(numel(allchild(g.Panel)), nPanel, 'no growth in the panel');
            tc.verifyEqual(numel(findall(tc.Fig)), nAll, 'no graphics objects created by page swaps');
            [m, L] = tc.Cache.compose(tc.page(51, n), r, c, style);
            tc.verifyEqual(img.CData, m, 'the image shows the composed page');
            tc.verifyEqual(g.Layout.Size, L.Size);
            tc.verifyEqual(ax.XLim, [0.5 L.Size(2) + 0.5]);
            tc.verifyEqual(ax.YLim, [0.5 L.Size(1) + 0.5]);
            ip = ax.InnerPosition;
            tc.verifyEqual(ip(3:4), [L.Size(2) L.Size(1)], 'pixel-exact: one mosaic pixel per screen pixel');
            tc.verifyEqual(string(ax.YDir), "reverse");
        end

        function testHitTestRoundTripsTileCenters(tc)
            g = tc.View;
            [r, c] = g.capacity();
            K = r * c - 3;                                  % a partial page: the last 3 slots are empty
            g.showPage(tc.page(2, K), struct());
            drawnow;
            ctr = g.tileCenter((1:r * c)');
            tc.verifyEqual(g.hitTest(ctr(1:K, :)), (1:K)');
            tc.verifyEqual(g.hitTest(ctr(K + 1:end, :)), zeros(3, 1), 'empty slots are not tiles');
            fp = g.mosaicToFigure(ctr(1:K, :));
            tc.verifyEqual(g.hitTest(fp, "figure"), (1:K)', 'figure pixels');
            tc.verifyEqual(g.figureToMosaic(fp), ctr(1:K, :), 'AbsTol', 1e-9);
            tc.verifyEqual(g.hitTest([0 0; -5 10; g.Layout.Size(2) + 3, 10]), [0; 0; 0]);
            % tile edges: x = 80.5 is the boundary between tiles 1 and 2
            T = g.Layout.TileW;
            tc.verifyEqual(g.hitTest([T + 0.49, 5; T + 0.51, 5]), [1; 2]);
            % the figure mapping agrees with MATLAB's own axes geometry
            ap = getpixelposition(g.Axes, true);
            tc.verifyEqual(g.mosaicToFigure([0.5 0.5]), [ap(1) - 1, ap(2) - 1 + ap(4)], 'AbsTol', 1e-9);
        end

        function testCursorAndSelectionGeometry(tc)
            g = tc.View;
            [r, c] = g.capacity();
            g.showPage(tc.page(3, r * c), struct());
            g.setCursor(5);
            drawnow;
            x = g.CursorLine.XData;
            y = g.CursorLine.YData;
            rect = g.Layout.Rect(5, :);
            tc.verifyEqual(nnz(isnan(x)), 1, 'one rectangle');
            tc.verifyGreaterThan(min(x), rect(1) - 0.5);
            tc.verifyLessThan(max(x), rect(1) + rect(3) - 0.5);
            tc.verifyGreaterThan(min(y), rect(2) - 0.5);
            tc.verifyLessThan(max(y), rect(2) + rect(4) - 0.5);
            tc.verifyEqual([mean([min(x) max(x)]) mean([min(y) max(y)])], g.tileCenter(5), 'AbsTol', 1e-9);
            tc.verifyGreaterThan(min(x), rect(1) - 0.5 + g.Layout.BorderPx, 'drawn inside the label border');

            g.setSelection([9 2 7 2]);
            drawnow;
            tc.verifyEqual(g.Selection, [2 7 9]);
            xs = g.SelectionLine.XData;
            ys = g.SelectionLine.YData;
            tc.verifyEqual(nnz(isnan(xs)), 3, 'one rectangle per selected tile');
            seg = reshape(1:numel(xs), 6, []);
            for j = 1:3
                cx = mean([min(xs(seg(1:5, j))) max(xs(seg(1:5, j)))]);
                cy = mean([min(ys(seg(1:5, j))) max(ys(seg(1:5, j)))]);
                tc.verifyEqual(g.hitTest([cx cy]), g.Selection(j));
            end
            g.setCursor(0);
            tc.verifyTrue(all(isnan(g.CursorLine.XData)));
            g.setSelection([]);
            tc.verifyTrue(all(isnan(g.SelectionLine.XData)));
            g.setSelection([1 2]);
            g.showPage(tc.page(4, r * c), struct());
            tc.verifyEmpty(g.Selection, 'a new page clears the selection');
            tc.verifyTrue(all(isnan(g.SelectionLine.XData)));
        end

        function testCapacityFollowsFigureSizeAndZoom(tc)
            g = tc.View;
            changes = zeros(0, 2);
            function onCap(~, r, c)
                changes(end + 1, :) = [r c];
            end
            g.CapacityChangedFcn = @(v, r, c) onCap(v, r, c);
            [r1, c1] = g.capacity();
            p = getpixelposition(g.Panel);
            tc.verifyEqual([r1 c1], [floor(p(4) / 80) floor(p(3) / 80)]);
            tc.Fig.Position(3:4) = [500 380];
            tGalleryView.waitForLayout(tc.Fig, g.Panel, [500 380]);
            [r2, c2] = g.capacity();
            tc.verifyLessThan(r2 * c2, r1 * c1);
            p = getpixelposition(g.Panel);
            tc.verifyEqual([r2 c2], [floor(p(4) / 80) floor(p(3) / 80)]);
            tc.verifyNotEmpty(changes, 'CapacityChangedFcn fired');
            tc.verifyEqual(changes(end, :), [r2 c2]);
            tc.Fig.Position(3:4) = [980 660];
            tGalleryView.waitForLayout(tc.Fig, g.Panel, [980 660]);
            g.capacity();
            g.setZoom(2);
            [r3, c3] = g.capacity();
            p = getpixelposition(g.Panel);
            tc.verifyEqual([r3 c3], [floor(p(4) / 160) floor(p(3) / 160)], 'zoom 2: tiles of 160 screen px');
            g.showPage(tc.page(1, r3 * c3), struct());
            drawnow;
            ip = g.Axes.InnerPosition;
            tc.verifyEqual(ip(3:4), 2 * [g.Layout.Size(2) g.Layout.Size(1)], 'zoom 2 doubles the display size');
            ctr = g.tileCenter((1:r3 * c3)');
            tc.verifyEqual(g.hitTest(g.mosaicToFigure(ctr), "figure"), (1:r3 * c3)', 'hit testing follows the zoom');
            % side-by-side tiles are twice as wide
            g.setZoom(1);
            [~, cs] = g.capacity(struct('Mode', 'side'));
            [~, ct] = g.capacity(struct('Mode', 'target'));
            tc.verifyEqual(cs, floor(ct / 2), 'AbsTol', 1);
            % the pixel cap
            g.MaxPixels = 20 * 80 * 80;
            [r4, c4] = g.capacity();
            tc.verifyLessThanOrEqual(r4 * c4, 20);
        end

        function testPrefetchIsUsedOnlyWhenItMatches(tc)
            g = tc.View;
            [r, c] = g.capacity();
            n = r * c;
            s = struct('BorderRGB', [200 200 200], 'CornerRGB', [NaN NaN NaN]);   % NaN: no badge
            g.showPage(tc.page(1, n), s);
            g.prefetch(tc.page(2, n), s);
            g.showPage(tc.page(2, n), s);
            tc.verifyTrue(g.LastTimings.Prefetched);
            tc.verifyEqual(g.Image.CData, tc.Cache.compose(tc.page(2, n), r, c, s));
            g.prefetch(tc.page(3, n), s);
            g.showPage(tc.page(4, n), s);
            tc.verifyFalse(g.LastTimings.Prefetched, 'other ids');
            tc.verifyEqual(g.Image.CData, tc.Cache.compose(tc.page(4, n), r, c, s));
            g.prefetch(tc.page(5, n), s);
            s2 = s;
            s2.BorderRGB = [0 0 255];
            g.showPage(tc.page(5, n), s2);
            tc.verifyFalse(g.LastTimings.Prefetched, 'other style');
            g.prefetch(tc.page(6, n), s);
            ids = tc.page(6, n);
            tc.Cache.update(ids(1), tc.Cache.XY(tc.Cache.rowsOf(ids(1)), :) + 1);
            g.showPage(ids, s);
            tc.verifyFalse(g.LastTimings.Prefetched, 'the cache changed');
            tc.verifyEqual(g.Image.CData, tc.Cache.compose(ids, r, c, s));
            tc.Cache.update(ids(1), tc.Cache.XY(tc.Cache.rowsOf(ids(1)), :) - 1);
        end

        function testUpdateTilesRedrawsOnlyThoseTiles(tc)
            g = tc.View;
            [r, c] = g.capacity();
            n = r * c;
            s = struct('BorderRGB', repmat([90 90 90], n, 1));
            g.showPage(tc.page(1, n), s);
            before = g.Image.CData;
            s.BorderRGB(4, :) = [0 158 115];
            g.updateTiles(4, s);
            drawnow;
            after = g.Image.CData;
            changed = any(after ~= before, 3);
            rect = g.Layout.Rect(4, :);
            inTile = false(size(changed));
            inTile(rect(2):rect(2) + rect(4) - 1, rect(1):rect(1) + rect(3) - 1) = true;
            tc.verifyTrue(any(changed(:)));
            tc.verifyEqual(changed | inTile, inTile, 'only tile 4 changed');
            tc.verifyEqual(after, tc.Cache.compose(tc.page(1, n), r, c, s));
            s.BorderRGB(:, :) = 255;
            g.updateTiles(1:n, s);
            tc.verifyEqual(g.Image.CData, tc.Cache.compose(tc.page(1, n), r, c, s));
        end

        function testSyntheticClickDragHover(tc)
            g = tc.View;
            [r, c] = g.capacity();
            tc.assumeGreaterThanOrEqual(c, 6, 'needs a row of 6 tiles');
            g.showPage(tc.page(1, r * c), struct());
            store = tc.recorder();
            ctr = g.tileCenter((1:r * c)');
            at = @(k, varargin) tGalleryView.at(ctr(k, :), varargin{:});

            tc.verifyTrue(g.onButtonDown(at(3, 'SelectionType', 'alt', 'Modifier', "shift")));
            L = store('log');
            tc.verifyEqual(L{1}.Kind, 'click');
            tc.verifyEqual(L{1}.Tile, 3);
            tc.verifyEqual(L{1}.Id, uint32(g.Ids(3)));
            tc.verifyEqual(L{1}.SelectionType, "alt");
            tc.verifyTrue(g.onMotion(at(3)));                   % same tile: nothing new
            tc.verifyTrue(g.onMotion(at(4)));
            tc.verifyTrue(g.onMotion(at(4)));
            tc.verifyTrue(g.onMotion(at(6)));                   % skips over 5: delivered in order
            tc.verifyTrue(g.onMotion(at(4)));                   % back over visited tiles: nothing
            tc.verifyTrue(g.onButtonUp(at(4)));
            [kinds, tiles] = tGalleryView.events(store);
            tc.verifyEqual(kinds, ["click" "drag" "drag" "drag" "end"]);
            tc.verifyEqual(tiles(1:4), [3 4 5 6]);
            L = store('log');
            tc.verifyEqual(L{5}.Tiles, [3 4 5 6]);
            tc.verifyEqual([L{2}.StartTile L{4}.StartTile], [3 3]);
            tc.verifyEqual(L{3}.SelectionType, "alt", 'drags carry the press''s selection type');
            tc.verifyFalse(g.onButtonUp(at(4)), 'no drag: not consumed');

            % hover (HoverInterval = 0 in this test): each new tile once, 0 when leaving the tiles
            store('log') = {};
            g.onMotion(at(8));
            g.onMotion(at(8));
            g.onMotion(at(9));
            tc.verifyFalse(g.onMotion(tGalleryView.at([-50 -50])), 'outside the panel: not consumed');
            [kinds, tiles] = tGalleryView.events(store);
            tc.verifyEqual(kinds, ["hover" "hover" "hover"]);
            tc.verifyEqual(tiles, [8 9 0]);

            % a press outside the tiles starts nothing
            store('log') = {};
            tc.verifyFalse(g.onButtonDown(tGalleryView.at([-50 -50])));
            tc.verifyFalse(g.onButtonUp(tGalleryView.at([-50 -50])));
            tc.verifyEmpty(store('log'));
        end

        function testHoverIsThrottled(tc)
            g = tc.View;
            [r, c] = g.capacity();
            g.showPage(tc.page(1, r * c), struct());
            store = tc.recorder();
            g.HoverInterval = 0.3;
            ctr = g.tileCenter((1:r * c)');
            g.onMotion(tGalleryView.at(ctr(1, :)));      % delivered at once
            g.onMotion(tGalleryView.at(ctr(2, :)));      % within the interval: held back ...
            g.onMotion(tGalleryView.at(ctr(3, :)));      % ... and replaced by the latest
            [~, tiles] = tGalleryView.events(store);
            tc.verifyEqual(tiles, 1);
            pause(0.6);
            drawnow;
            [~, tiles] = tGalleryView.events(store);
            tc.verifyEqual(tiles, [1 3], 'the last hovered tile is delivered after the interval');
        end

        function testFigurePointEvents(tc)
            g = tc.View;
            [r, c] = g.capacity();
            g.showPage(tc.page(2, r * c), struct());
            drawnow;
            store = tc.recorder();
            fp = g.mosaicToFigure(g.tileCenter([7; 8]));
            tc.verifyTrue(g.onButtonDown(struct('FigurePoint', fp(1, :), 'SelectionType', 'normal')));
            g.onMotion(struct('FigurePoint', fp(2, :)));
            g.onButtonUp(struct('FigurePoint', fp(2, :)));
            [kinds, tiles] = tGalleryView.events(store);
            tc.verifyEqual(kinds, ["click" "drag" "end"]);
            tc.verifyEqual(tiles(1:2), [7 8]);
        end

        function testUitestPress(tc)
            g = tc.View;
            [r, c] = g.capacity();
            g.showPage(tc.page(1, r * c), struct());
            g.installRouting();
            store = tc.recorder();
            drawnow;
            ctr = g.tileCenter([5; 12]);
            tGalleryView.gestureOrSkip(tc, @() tc.press(g.Axes, ctr(1, :)), 'press on axes');
            drawnow;
            [kinds, tiles] = tGalleryView.events(store);
            tc.verifyTrue(ismember("click", kinds), 'a real press reaches the view through the figure callbacks');
            tc.verifyEqual(tiles(find(kinds == "click", 1)), 5);
            L = store('log');
            tc.verifyEqual(L{find(kinds == "click", 1)}.SelectionType, "normal");
            store('log') = {};
            try
                tc.press(g.Axes, ctr(2, :), 'SelectionType', 'alt');
                drawnow;
                [kinds, tiles] = tGalleryView.events(store);
                L = store('log');
                tc.verifyEqual(tiles(find(kinds == "click", 1)), 12);
                tc.verifyEqual(L{find(kinds == "click", 1)}.SelectionType, "alt");
            catch err
                tc.log(1, "press with SelectionType not available: " + err.message);
            end
        end

        function testUitestDragPaintsTiles(tc)
            g = tc.View;
            [r, c] = g.capacity();
            tc.assumeGreaterThanOrEqual(c, 5);
            g.showPage(tc.page(1, r * c), struct());
            g.installRouting();
            store = tc.recorder();
            drawnow;
            ctr = g.tileCenter([1; 5]);
            tGalleryView.gestureOrSkip(tc, @() tc.drag(g.Axes, ctr(1, :), ctr(2, :)), 'drag on axes');
            drawnow;
            [kinds, tiles] = tGalleryView.events(store);
            tc.verifyEqual(tiles(find(kinds == "click", 1)), 1);
            tc.verifyEqual(tiles(kinds == "drag"), 2:5, 'each tile entered once, in order');
            L = store('log');
            iEnd = find(kinds == "end", 1);
            tc.verifyNotEmpty(iEnd);
            tc.verifyEqual(L{iEnd}.Tiles, 1:5);
        end

        function testUitestHover(tc)
            g = tc.View;
            [r, c] = g.capacity();
            g.showPage(tc.page(1, r * c), struct());
            g.installRouting();
            store = tc.recorder();
            drawnow;
            ctr = g.tileCenter(6);
            tGalleryView.gestureOrSkip(tc, @() tc.hover(g.Axes, ctr), 'hover on axes');
            drawnow;
            [kinds, tiles] = tGalleryView.events(store);
            tc.verifyTrue(any(kinds == "hover" & tiles == 6), 'hovering a tile reports it');
        end

        function testDeletingTheFigureDeletesTheView(tc)
            g = tc.View;
            g.CapacityChangedFcn = @(varargin) [];
            g.ResizeDebounce = 0.5;
            tc.Fig.Position(3) = 700;   % arms the resize timer
            drawnow;
            delete(tc.Fig);
            tc.verifyFalse(isvalid(g));
            tc.verifyEmpty(timerfindall('Name', 'GalleryView resize'), 'timers are deleted with the view');
        end

        function testBeforeACacheIsSet(tc)
            g = curation.GalleryView(tc.Grid);
            tc.addTeardown(@() delete(g));
            tc.verifyError(@() g.showPage(1:3, struct()), 'GalleryView:NoCache');
            tc.verifyEqual(g.hitTest([5 5]), 0);
            [r, c] = g.capacity();
            tc.verifyGreaterThanOrEqual([r c], [1 1]);
        end
    end
end
