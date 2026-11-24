classdef tMapView < matlab.uitest.TestCase
    %tMapView  curation.MapView in a uifigure: persistent graphics objects, coordinates (X = column,
    %   Y = row, Y reversed), pick, zoom about the pointer, clamping, centerOn/viewRect, point edits,
    %   selection rings, lasso, move and add tools, sweep fields, display modes, scale independence,
    %   routing (consumed), hover, pointer shapes, regions, resizing, teardown; synthetic events plus a
    %   few matlab.uitest gestures. Opens figures: run it on the hidden desktop
    %   (tools\Run-Tests.ps1 tMapView).

    properties (Constant)
        H = 600
        W = 800
        UmPerPx = 1.657
        % ids 1..5 at known places (ids 3 and 4 are 6 px apart); the random points keep 40 px away
        Special = [650 120; 100 500; 300 300; 306 300; 520 420]
        Grey = [110 110 110]
    end

    properties
        PageT
        PageC
        Ids
        XY
        Fig
        Grid
        View
    end

    methods (TestClassSetup)
        function makePages(tc)
            rng(5);
            nr = tc.H;
            nc = tc.W;
            n = 300;
            xy = [20 + rand(n, 1) * (nc - 40), 20 + rand(n, 1) * (nr - 40)];
            sp = tc.Special;
            d = sqrt((xy(:, 1) - sp(:, 1)').^2 + (xy(:, 2) - sp(:, 2)').^2);
            xy = [sp; xy(all(d > 40, 2), :)];
            imp = zeros(nr, nc);
            imp(sub2ind([nr nc], round(xy(:, 2)), round(xy(:, 1)))) = 1;
            g = exp(-(-10:10).^2 / (2 * 3^2));
            tc.PageT = single(10 + 100 * conv2(g, g, imp, 'same') + rand(nr, nc));
            tc.PageC = single(5 + 50 * conv2(g, g, flipud(imp), 'same') + rand(nr, nc));
            tc.Ids = uint32((1:size(xy, 1))');
            tc.XY = xy;
        end
    end

    methods (TestMethodSetup)
        function makeFigure(tc)
            tc.Fig = uifigure('Name', 'tMapView', 'Position', [40 40 980 660]);
            tc.addTeardown(@() tMapView.closeFigure(tc.Fig));
            tc.Grid = uigridlayout(tc.Fig, [1 1], 'Padding', [0 0 0 0]);
            tc.View = curation.MapView(tc.Grid);
            tc.View.HoverInterval = 0;
            tc.View.setImage(tc.PageT, tc.PageC, [], tc.UmPerPx);
            tc.View.setPoints(tc.Ids, tc.XY, tc.Grey);
            tMapView.waitForLayout(tc.Fig, tc.View.Panel);
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Static)
        function closeFigure(f)
            if ~isempty(f) && isvalid(f); delete(f); end
        end

        function waitForLayout(fig, panel, sz)
            %waitForLayout  Wait (up to 10 s) until the grid has given PANEL its size (default the
            %   figure's): a uifigure lays its grids out in the browser, after drawnow returns.
            if nargin < 3; sz = fig.Position(3:4); end
            t0 = tic;
            while toc(t0) < 10
                drawnow;
                p = panel.Position;
                if isequal(p(3:4), sz); break; end
                pause(0.05);
            end
            drawnow;
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
            %at  A synthetic mouse event at image point PT.
            ev = struct('AxesPoint', pt, varargin{:});
        end

        function ev = fig(fp, varargin)
            %fig  A synthetic mouse event at figure point FP.
            ev = struct('FigurePoint', fp, varargin{:});
        end

        function k = kinds(store)
            L = store('log');
            k = strings(1, numel(L));
            for i = 1:numel(L); k(i) = L{i}.Kind; end
        end

        function c = infos(store, kind)
            L = store('log');
            c = {};
            for i = 1:numel(L)
                if L{i}.Kind == kind; c{end + 1} = L{i}.Info; end %#ok<AGROW>
            end
        end

        function r = someRegions()
            r = struct('xy', {[150 100; 330 120; 360 260; 210 300; 120 210], ...
                [40 40; 760 40; 760 560; 40 560], [380 0.5; 470 0.5; 470 600.5; 380 600.5]}, ...
                'kind', {"exclude", "analysis", "reference"}, 'id', {1, 2, 3});
        end

        function setTool(v, t)
            v.Tool = t;
        end
    end

    methods
        function store = recorder(tc)
            %recorder  Wire the view's callbacks to a log: store('log') is a cell of {Kind, Info}.
            store = containers.Map('KeyType', 'char', 'ValueType', 'any');
            store('log') = {};
            function add(kind, m, in)
                L = store('log');
                L{end + 1} = struct('Kind', kind, 'Info', in);
                store('log') = L;
                tc.verifySameHandle(m, tc.View);
            end
            v = tc.View;
            v.PointClickFcn = @(m, in) add("click", m, in);
            v.EmptyClickFcn = @(m, in) add("empty", m, in);
            v.PointDragFcn = @(m, in) add("drag", m, in);
            v.PointDropFcn = @(m, in) add("drop", m, in);
            v.LassoDoneFcn = @(m, in) add("lasso", m, in);
            v.HoverFcn = @(m, in) add("hover", m, in);
        end

        function p = emptySpot(tc, near)
            %emptySpot  An image point with no point within 30 px and 30 px inside the image, nearest NEAR.
            if nargin < 2; near = [tc.W tc.H] / 2; end
            [gx, gy] = meshgrid(30:5:tc.W - 30, 30:5:tc.H - 30);
            c = [gx(:) gy(:)];
            d = min(sqrt((c(:, 1) - tc.XY(:, 1)').^2 + (c(:, 2) - tc.XY(:, 2)').^2), [], 2);
            c = c(d > 30, :);
            [~, i] = min(sum((c - near).^2, 2));
            p = c(i, :);
        end

        function mid = panelMiddle(tc)
            pp = getpixelposition(tc.View.Panel, true);
            mid = pp(1:2) - 1 + pp(3:4) / 2;
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Test)
        function testGraphicsObjectsPersist(tc)
            v = tc.View;
            drawnow;
            h = {v.Image, v.Points, v.SelectionLine, v.HoverLine, v.DragLine, v.LassoLine, v.RegionGroup, ...
                v.ExcludeFill, v.ExcludeHatch, v.AnalysisLine, v.ReferenceLine, v.SweepLine, v.Axes, v.Panel};
            nChildren = numel(v.Axes.Children);
            nAll = numel(findall(tc.Fig));
            tc.verifyEqual(numel(findobj(v.Axes, 'Type', 'image')), 1);
            tc.verifyEqual(numel(findobj(v.Axes, 'Type', 'scatter')), 1);
            reg = tMapView.someRegions();
            v.sweepRects(200, 0.1);
            ids = tc.Ids;
            modes = ["target" "companion" "overlay"];
            tools = ["select" "add" "move" "lasso"];
            for k = 1:50
                v.updatePoints(ids(mod(k, numel(ids)) + 1), [0 158 115]);
                v.movePoints(ids(3), tc.XY(3, :) + [mod(k, 3) 0]);
                v.setVisible(ids(10:20), mod(k, 2) == 0);
                v.setSelection(ids(k:k + 4));
                v.setMode(modes(mod(k, 3) + 1));
                v.setGain(1 + mod(k, 2));
                v.setGamma(1 - 0.25 * mod(k, 2));
                v.setRegions(reg(1:mod(k, numel(reg)) + 1));
                v.zoomBy(1.25 ^ (2 * mod(k, 2) - 1));
                v.panBy(5, -5);
                v.showSweepRect(mod(k, size(v.SweepRects, 1)) + 1);
                v.addPoints(uint32(10000 + k), [100 + k, 200], [255 0 0]);
                if k > 1; v.removePoints(uint32(10000 + k - 1)); end
                v.Tool = tools(mod(k, 4) + 1);
                v.onMotion(tMapView.at(tc.XY(5, :)));
                v.onMotion(tMapView.at(tc.XY(6, :)));
                if mod(k, 10) == 0; drawnow; end
            end
            drawnow;
            for i = 1:numel(h)
                tc.verifyTrue(isvalid(h{i}));
            end
            tc.verifySameHandle(v.Image, h{1});
            tc.verifySameHandle(v.Points, h{2});
            tc.verifyEqual(numel(v.Axes.Children), nChildren, 'no growth in the axes'' children');
            tc.verifyEqual(numel(findall(tc.Fig)), nAll, 'no graphics objects created by updates');
            tc.verifyEqual(numel(findobj(v.Axes, 'Type', 'image')), 1);
            tc.verifyEqual(numel(findobj(v.Axes, 'Type', 'scatter')), 1);
            tc.verifyEqual(numel(findall(v.Panel, 'Type', 'axes')), 1);
            tc.verifyEqual(v.N, numel(ids) + 1);
        end

        function testCoordinatesXIsColumnYIsRow(tc)
            v = tc.View;
            drawnow;
            tc.verifyEqual(v.Image.XData, [1 tc.W]);
            tc.verifyEqual(v.Image.YData, [1 tc.H]);
            tc.verifyEqual(size(v.Image.CData), [tc.H tc.W 3]);
            tc.verifyEqual(string(v.Axes.YDir), "reverse");
            a = tc.Special(1, :);                  % column 650, row 120
            b = tc.Special(2, :);                  % column 100, row 500
            C = v.Image.CData;
            tc.verifyGreaterThan(double(C(a(2), a(1), 2)), 200, 'the blob of point 1 is at row Y, column X');
            tc.verifyGreaterThan(double(C(b(2), b(1), 2)), 200, 'the blob of point 2 is at row Y, column X');
            rows = v.rowsOf(uint32([1 2]));
            tc.verifyEqual([v.Points.XData(rows(1)) v.Points.YData(rows(1))], a);
            tc.verifyEqual([v.Points.XData(rows(2)) v.Points.YData(rows(2))], b);

            % figure pixels <-> image pixels, and agreement with MATLAB's own axes geometry
            fp = v.dataToFigure([a; b]);
            tc.verifyEqual(v.figureToData(fp), [a; b], 'AbsTol', 1e-9);
            ap = getpixelposition(v.Axes, true);
            xl = v.Axes.XLim;
            yl = v.Axes.YLim;
            tc.verifyEqual(v.viewRect(), [xl yl]);
            tc.verifyEqual(v.dataToFigure([xl(1) yl(1)]), [ap(1) - 1, ap(2) - 1 + ap(4)], 'AbsTol', 1e-6, ...
                'the top-left corner of the view is the top-left of the axes');
            tc.verifyEqual(v.dataToFigure([xl(2) yl(2)]), [ap(1) - 1 + ap(3), ap(2) - 1], 'AbsTol', 1e-6);
            tc.verifyEqual(diff(xl) / ap(3), diff(yl) / ap(4), 'RelTol', 1e-9, 'square pixels');

            % what is drawn: point 1 ringed red, point 2 blue, each over its blob
            v.updatePoints(uint32([1 2]), [255 0 0; 0 0 255]);
            drawnow;
            pause(0.4);          % the browser paints after drawnow has returned (slower under load)
            drawnow;
            try
                F = getframe(v.Axes);
            catch err
                tc.assumeFail("getframe of a uifigure axes failed here: " + err.message);
            end
            img = double(F.cdata);
            [fh, fw, ~] = size(img);
            expect = @(p) [(p(1) - xl(1)) / diff(xl) * fw + 0.5, (p(2) - yl(1)) / diff(yl) * fh + 0.5];
            red = img(:, :, 1) > 180 & img(:, :, 2) < 90 & img(:, :, 3) < 90;
            blue = img(:, :, 3) > 180 & img(:, :, 1) < 90 & img(:, :, 2) < 90;
            tc.assertGreaterThan(nnz(red), 5, 'the red ring is in the frame');
            tc.assertGreaterThan(nnz(blue), 5, 'the blue ring is in the frame');
            tc.verifyEqual(centroid(red), expect(a), 'AbsTol', 2.5, 'red ring centred on point 1');
            tc.verifyEqual(centroid(blue), expect(b), 'AbsTol', 2.5, 'blue ring centred on point 2');
            ea = round(expect(a));
            eb = round(expect(b));
            tc.verifyGreaterThan(img(ea(2), ea(1), 2), 150, 'the blob shows inside ring 1');
            tc.verifyGreaterThan(img(eb(2), eb(1), 2), 150, 'the blob shows inside ring 2');

            % the markers keep their screen size at every zoom
            ext1 = ringExtent(red, expect(a));
            spanFit = diff(xl);
            v.centerOn(a, 15);
            drawnow;
            pause(0.6);          % the browser paints a large zoom step after drawnow has returned
            drawnow;
            F = getframe(v.Axes);
            img = double(F.cdata);
            [fh, fw, ~] = size(img);
            xl = v.Axes.XLim;
            yl = v.Axes.YLim;
            tc.verifyLessThan(diff(xl), spanFit / 10, 'zoomed in more than 10x');
            red = img(:, :, 1) > 180 & img(:, :, 2) < 90 & img(:, :, 3) < 90;
            e2 = [(a(1) - xl(1)) / diff(xl) * fw + 0.5, (a(2) - yl(1)) / diff(yl) * fh + 0.5];
            tc.assertGreaterThan(nnz(red), 5, 'the red ring is in the zoomed frame');
            tc.verifyEqual(centroid(red), e2, 'AbsTol', 2.5, 'still centred on point 1 when zoomed in');
            tc.verifyEqual(ringExtent(red, e2), ext1, 'AbsTol', 2, 'the ring keeps its size on screen');
        end

        function testInterpolationFollowsTheZoom(tc)
            v = tc.View;
            big = repmat(tc.PageT, 3, 3);                 % 1800 x 2400: > 1.5 image px per screen px when fitted
            v.setImage(big, [], [], tc.UmPerPx);
            tc.verifyGreaterThanOrEqual(v.Scale, 1.5);
            tc.verifyEqual(v.Interpolation, "bilinear", 'zoomed out: bilinear');
            v.zoomBy(v.Scale / 0.8);
            tc.verifyEqual(v.Scale, 0.8, 'RelTol', 1e-9);
            tc.verifyEqual(v.Interpolation, "nearest", 'zoomed in: single pixels stay sharp');
            tc.verifyEqual(string(v.Image.Interpolation), "nearest");
            v.zoomBy(0.8 / 1.2);
            tc.verifyEqual(v.Scale, 1.2, 'RelTol', 1e-9);
            tc.verifyEqual(v.Interpolation, "nearest", 'between 1 and 1.5 the last choice is kept');
            v.fit();
            tc.verifyEqual(v.Interpolation, "bilinear");
            m = curation.MapView(tc.Grid, Interpolation="nearest");
            tc.addTeardown(@() delete(m));
            m.setImage(big, [], [], 1);
            tc.verifyEqual(m.Interpolation, "nearest", 'a fixed choice is kept');
        end

        function testPickNearestThresholdHidden(tc)
            v = tc.View;
            tc.verifyEqual(v.pick([302 300], 10), uint32(3));
            tc.verifyEqual(v.pick([304.5 300], 10), uint32(4), 'the nearest of two');
            tc.verifyEqual(v.pick([300 320], 10), uint32(0), 'nothing within the distance');
            tc.verifyEqual(v.pick([300 320], 21), uint32(3));
            v.setVisible(uint32(3), false);
            tc.verifyEqual(v.pick([302 300], 10), uint32(4), 'hidden points are ignored');
            tc.verifyEqual(v.pick([300 300], 5), uint32(0));
            v.setVisible(uint32(3), true);
            tc.verifyEqual(v.pick([301 300], 10), uint32(3));
            % the default distance: PickRadiusPx screen pixels at the current zoom
            v.centerOn([300 300], 30);
            r = v.PickRadiusPx * v.Scale;
            tc.verifyEqual(v.pick([300 300 + 0.9 * r]), uint32(3));
            tc.verifyEqual(v.pick([300 300 + 1.1 * r]), uint32(0));
            v.fit();
            r = v.PickRadiusPx * v.Scale;
            tc.verifyEqual(v.pick([300 300 + 0.9 * r]), uint32(3), 'zoomed out the same screen distance is more pixels');
            v.setPoints([], zeros(0, 2), zeros(0, 3));
            tc.verifyEqual(v.pick([300 300], 100), uint32(0), 'no points');
        end

        function testZoomKeepsThePointedPixel(tc)
            v = tc.View;
            mid = tc.panelMiddle();
            for i = 1:3
                tc.verifyTrue(v.onScroll(tMapView.fig(mid, 'VerticalScrollCount', -1)));
            end
            s0 = v.Scale;
            fp = mid + [180 -120];
            d0 = v.figureToData(fp);
            v.onScroll(tMapView.fig(fp, 'VerticalScrollCount', -1));
            tc.verifyEqual(v.Scale, s0 / 1.25, 'RelTol', 1e-12, 'one notch: 1.25x');
            tc.verifyEqual(v.figureToData(fp), d0, 'AbsTol', 1e-9, 'the pixel under the pointer stays put (in)');
            v.onScroll(tMapView.fig(fp, 'VerticalScrollCount', 1));
            tc.verifyEqual(v.Scale, s0, 'RelTol', 1e-12);
            tc.verifyEqual(v.figureToData(fp), d0, 'AbsTol', 1e-9, '(out)');
            v.onScroll(tMapView.fig(fp, 'VerticalScrollCount', -2));
            tc.verifyEqual(v.Scale, s0 / 1.25^2, 'RelTol', 1e-12, 'two notches');
            tc.verifyEqual(v.figureToData(fp), d0, 'AbsTol', 1e-9);
            % an image-point event: that pixel stays where it was
            q = [380 260];
            fq = v.dataToFigure(q);
            v.onScroll(tMapView.at(q, 'VerticalScrollCount', -1));
            tc.verifyEqual(v.figureToData(fq), q, 'AbsTol', 1e-9);
            % keyboard zoom about a point
            v.zoomBy(2, q);
            tc.verifyEqual(v.figureToData(fq), q, 'AbsTol', 1e-9);
        end

        function testZoomAndPanClampToTheImage(tc)
            v = tc.View;
            mid = tc.panelMiddle();
            pp = getpixelposition(v.Panel, true);
            for i = 1:5
                v.onScroll(tMapView.fig(mid + [300 200], 'VerticalScrollCount', 3));
            end
            tc.verifyTrue(v.IsFit, 'zooming out stops at the whole image');
            r = v.viewRect();
            tc.verifyEqual(v.Scale, max(tc.W / pp(3), tc.H / pp(4)), 'RelTol', 1e-12);
            tc.verifyEqual([mean(r(1:2)) mean(r(3:4))], ([tc.W tc.H] + 1) / 2, 'AbsTol', 1e-9, 'centred');
            tc.verifyLessThanOrEqual(r([1 3]), [0.5 0.5] + 1e-9);
            tc.verifyGreaterThanOrEqual(r([2 4]), [tc.W tc.H] + 0.5 - 1e-9);

            for i = 1:40
                v.onScroll(tMapView.fig(mid + [100 50], 'VerticalScrollCount', -1));
            end
            r = v.viewRect();
            tc.verifyEqual(min(diff(r(1:2)), diff(r(3:4))), v.MinSpanPx, 'RelTol', 1e-9, ...
                'the deepest zoom shows MinSpanPx pixels across the narrower side');

            v.panBy(1e6, 0);
            r = v.viewRect();
            tc.verifyEqual(r(1), 0.5, 'AbsTol', 1e-9, 'left edge');
            v.panBy(-1e6, 0);
            r = v.viewRect();
            tc.verifyEqual(r(2), tc.W + 0.5, 'AbsTol', 1e-9, 'right edge');
            v.panBy(0, -1e6);
            r = v.viewRect();
            tc.verifyEqual(r(3), 0.5, 'AbsTol', 1e-9, 'top edge');
            v.panBy(0, 1e6);
            r = v.viewRect();
            tc.verifyEqual(r(4), tc.H + 0.5, 'AbsTol', 1e-9, 'bottom edge');

            % a middle-button drag far past an edge stops at the edge
            v.centerOn([400 300], 100);
            tc.verifyTrue(v.onButtonDown(tMapView.fig(mid, 'SelectionType', 'extend')));
            tc.verifyEqual(v.Gesture, "pan");
            v.onMotion(tMapView.fig(mid + [5000 -5000]));
            r = v.viewRect();
            tc.verifyEqual(r([1 3]), [0.5 0.5], 'AbsTol', 1e-9);
            tc.verifyTrue(v.onButtonUp(tMapView.fig(mid + [5000 -5000])));
            % zooming out near a corner keeps the view on the image
            v.centerOn([10 10], 60);
            v.onScroll(tMapView.fig(mid, 'VerticalScrollCount', 2));
            r = v.viewRect();
            tc.verifyTrue((r(1) >= 0.5 - 1e-9 || abs(mean(r(1:2)) - (tc.W + 1) / 2) < 1e-9) && ...
                (r(3) >= 0.5 - 1e-9 || abs(mean(r(3:4)) - (tc.H + 1) / 2) < 1e-9), mat2str(r));
        end

        function testCenterOnAndViewRect(tc)
            v = tc.View;
            pp = getpixelposition(v.Panel, true);
            v.centerOn([400 300], 60);
            r = v.viewRect();
            tc.verifyEqual([mean(r(1:2)) mean(r(3:4))], [400 300], 'AbsTol', 1e-9);
            tc.verifyEqual(min(diff(r(1:2)), diff(r(3:4))), 2 * 60 / tc.UmPerPx, 'RelTol', 1e-9, ...
                'the narrower side spans 2 * halfWidthUm');
            tc.verifyEqual(diff(r(1:2)) / pp(3), diff(r(3:4)) / pp(4), 'RelTol', 1e-9);
            tc.verifyEqual(r, [v.Axes.XLim v.Axes.YLim], 'viewRect is the axes limits');
            v.centerOn([500 250]);
            r2 = v.viewRect();
            tc.verifyEqual(diff(r2(1:2)), diff(r(1:2)), 'RelTol', 1e-12, 'without a width the zoom is kept');
            tc.verifyEqual([mean(r2(1:2)) mean(r2(3:4))], [500 250], 'AbsTol', 1e-9);
            v.centerOn([3 4], 60);
            r = v.viewRect();
            tc.verifyEqual(r([1 3]), [0.5 0.5], 'AbsTol', 1e-9, 'clamped at the corner');
            rect = [100 300 200 260];
            v.setViewRect(rect);
            r = v.viewRect();
            tc.verifyTrue(r(1) <= rect(1) + 1e-9 && r(2) >= rect(2) - 1e-9 && r(3) <= rect(3) + 1e-9 && ...
                r(4) >= rect(4) - 1e-9, 'the rectangle is in view');
            tc.verifyEqual(diff(r(1:2)), diff(rect(1:2)), 'RelTol', 1e-9, 'as large as it fits');
            v.fit();
            tc.verifyTrue(v.IsFit);
        end

        function testRecolourMoveAddRemoveVisible(tc)
            v = tc.View;
            ids = tc.Ids;
            n = numel(ids);
            v.updatePoints(ids([7 9]), [0 158 115]);
            rows = v.rowsOf(ids([7 9]));
            tc.verifyEqual(v.Points.CData(rows, :), repmat([0 158 115] / 255, 2, 1), 'AbsTol', 1e-12);
            tc.verifyEqual(v.RGB(rows, :), uint8(repmat([0 158 115], 2, 1)));
            tc.verifyEqual(v.Points.CData(v.rowsOf(ids(8)), :), tc.Grey / 255, 'AbsTol', 1e-12, 'others unchanged');
            v.updatePoints(ids(1:3), uint8([255 0 0; 0 255 0; 0 0 255]));
            tc.verifyEqual(v.Points.CData(v.rowsOf(ids(1:3)), :), eye(3), 'AbsTol', 1e-12);
            tc.verifyError(@() v.updatePoints(uint32(99999), [1 2 3]), 'MapView:UnknownId');
            tc.verifyError(@() v.updatePoints(ids(1), [300 0 0]), 'MapView:BadColour');

            v.movePoints(ids(7), [123.25 456.5]);
            r = v.rowsOf(ids(7));
            tc.verifyEqual(v.XY(r, :), [123.25 456.5]);
            tc.verifyEqual([v.Points.XData(r) v.Points.YData(r)], [123.25 456.5]);
            tc.verifyEqual(v.pick([123 456.5], 1), ids(7));

            v.addPoints(uint32([5001; 5002]), [10 20; 30 40], [255 255 0]);
            tc.verifyEqual(v.N, n + 2);
            r = v.rowsOf(uint32(5002));
            tc.verifyEqual([v.Points.XData(r) v.Points.YData(r)], [30 40]);
            tc.verifyEqual(v.Points.CData(r, :), [1 1 0], 'AbsTol', 1e-12);
            tc.verifyEqual(numel(v.Points.XData), n + 2);
            tc.verifyError(@() v.addPoints(uint32(5001), [1 1], [0 0 0]), 'MapView:DuplicateIds');

            v.removePoints(uint32([5001 77777]));
            tc.verifyEqual(v.N, n + 1, 'unknown ids are ignored');
            tc.verifyEqual(v.rowsOf(uint32(5001)), 0);
            tc.verifyEqual(numel(v.Points.XData), n + 1);
            tc.verifyEqual(v.pick([10 20], 2), uint32(0));
            r = v.rowsOf(uint32(5002));
            tc.verifyEqual([v.Points.XData(r) v.Points.YData(r)], [30 40], 'the remaining rows still line up');

            v.setVisible(ids(1:2), false);
            tc.verifyTrue(all(isnan(v.Points.XData(v.rowsOf(ids(1:2))))));
            tc.verifyEqual(v.Shown(v.rowsOf(ids(1:2))), [false; false]);
            tc.verifyEqual(v.pick(tc.Special(1, :), 5), uint32(0));
            v.setVisible(ids(1:3), [true; false; false]);
            tc.verifyEqual(v.Points.XData(v.rowsOf(ids(1))), tc.Special(1, 1));
            tc.verifyTrue(isnan(v.Points.XData(v.rowsOf(ids(3)))));
            v.setVisible(ids, true);
            tc.verifyFalse(any(isnan(v.Points.XData)));
            tc.verifyError(@() v.setVisible(ids(1:3), [true false]), 'MapView:BadVisible');
        end

        function testMarkerLayers(tc)
            % one scatter per marker style; every layer's rows line up with Ids (NaN where a point
            % is in another layer); a relabel moves a point between layers; points, picking and the
            % rings do not care which layer a point is in
            v = tc.View;
            ids = tc.Ids;
            n = numel(ids);
            tc.verifyEqual(numel(v.Layers), 1);
            tc.verifySameHandle(v.Points, v.Layers(1));
            p1 = v.Points;
            nChildren = numel(v.Axes.Children);
            v.setMarkerStyles(struct('Marker', {'o', 's', 'x'}, 'Filled', {false, true, true}));
            drawnow;
            tc.verifyEqual(numel(findobj(v.Axes, 'Type', 'scatter')), 3);
            tc.verifyEqual(numel(v.Axes.Children), nChildren, 'the layers live in one group');
            tc.verifySameHandle(v.Points, p1, 'layer 1 keeps its scatter');
            tc.verifyEqual(char(v.Layers(2).Marker), 'square');
            tc.verifyEqual(char(v.Layers(2).MarkerFaceColor), 'flat', 'filled');
            tc.verifyEqual(v.Layers(2).MarkerEdgeColor, [0 0 0], 'with a dark edge');
            tc.verifyEqual(char(v.Layers(1).MarkerFaceColor), 'none', 'a ring');
            tc.verifyEqual(char(v.Layers(3).MarkerEdgeColor), 'flat', 'a line symbol is never filled');
            tc.verifyEqual(v.Layer, ones(n, 1), 'points keep layer 1');
            tc.verifyFalse(any(isnan(v.Points.XData)));

            v.updatePoints(ids(1:3), [0 114 178], 2);
            r = v.rowsOf(ids(1:3));
            tc.verifyEqual(v.Layer(r), [2; 2; 2]);
            tc.verifyTrue(all(isnan(v.Points.XData(r))), 'gone from layer 1');
            tc.verifyEqual([v.Layers(2).XData(r)' v.Layers(2).YData(r)'], tc.XY(1:3, :), 'drawn by layer 2');
            tc.verifyEqual(v.Layers(2).CData(r, :), repmat([0 114 178] / 255, 3, 1), 'AbsTol', 1e-12);
            tc.verifyEqual(nnz(~isnan(v.Layers(2).XData)), 3, 'only those');
            tc.verifyEqual(numel(v.Layers(2).XData), n, 'rows line up with Ids');
            tc.verifyEqual(v.Layers(3).XData, NaN, 'an empty layer draws nothing');
            tc.verifyEqual(v.pick(tc.Special(1, :), 2), ids(1), 'picking ignores layers');

            v.movePoints(ids(2), [222 333]);
            tc.verifyEqual([v.Layers(2).XData(r(2)) v.Layers(2).YData(r(2))], [222 333]);
            tc.verifyTrue(isnan(v.Points.XData(r(2))));
            v.setVisible(ids(3), false);
            tc.verifyTrue(isnan(v.Layers(2).XData(r(3))), 'hidden in its own layer');
            v.setVisible(ids(3), true);
            v.updatePoints(ids(1), [255 0 0]);
            tc.verifyEqual(v.Layer(r(1)), 2, 'a recolour without LAYER keeps the layer');

            v.addPoints(uint32([7001; 7002]), [40 50; 60 70], [255 255 0], [3; 1]);
            tc.verifyEqual(v.Layer(v.rowsOf(uint32([7001; 7002]))), [3; 1]);
            tc.verifyEqual([v.Layers(3).XData(v.rowsOf(uint32(7001))) v.Layers(3).YData(v.rowsOf(uint32(7001)))], [40 50]);
            tc.verifyEqual(numel(v.Layers(1).XData), n + 2);
            tc.verifyEqual(numel(v.Layers(2).XData), n + 2);
            v.removePoints(uint32(7001));
            tc.verifyEqual(v.Layers(3).XData, NaN, 'its only point removed');
            tc.verifyError(@() v.updatePoints(ids(1), [1 2 3], 4), 'MapView:BadLayer');
            tc.verifyError(@() v.setMarkerStyles(struct('Marker', 'Q', 'Filled', false)), 'MapView:BadStyles');

            v.setMarkerStyles(struct('Marker', 'd', 'Filled', false));
            drawnow;
            tc.verifyEqual(numel(findobj(v.Axes, 'Type', 'scatter')), 1, 'surplus layers deleted');
            tc.verifySameHandle(v.Points, p1);
            tc.verifyEqual(char(v.Points.Marker), 'diamond');
            tc.verifyEqual(v.Layer, ones(v.N, 1), 'their points back in layer 1');
            tc.verifyFalse(any(isnan(v.Points.XData)), 'every point drawn again');
            tc.verifyEqual(numel(v.Points.XData), v.N);
        end

        function testSelectionRingsFollowPoints(tc)
            v = tc.View;
            a = uint32(1); b = uint32(2);
            v.setSelection([b a b 99999]);
            tc.verifyEqual(v.Selection, [b; a], 'unique, in order, unknown ids dropped');
            tc.verifyEqual(sortrows([v.SelectionLine.XData(:) v.SelectionLine.YData(:)]), sortrows(tc.Special(1:2, :)));
            v.movePoints(a, [700 50]);
            tc.verifyTrue(ismember([700 50], [v.SelectionLine.XData(:) v.SelectionLine.YData(:)], 'rows'), ...
                'the ring follows the moved point');
            v.setVisible(b, false);
            tc.verifyEqual([v.SelectionLine.XData(:) v.SelectionLine.YData(:)], [700 50], 'no ring on a hidden point');
            v.setVisible(b, true);
            tc.verifyEqual(numel(v.SelectionLine.XData), 2);
            v.removePoints(a);
            tc.verifyEqual(v.Selection, b);
            tc.verifyEqual([v.SelectionLine.XData(:) v.SelectionLine.YData(:)], tc.Special(2, :));
            v.setSelection([]);
            tc.verifyTrue(all(isnan(v.SelectionLine.XData)));
            v.setSelection(b);
            v.setPoints(tc.Ids, tc.XY, tc.Grey);
            tc.verifyEmpty(v.Selection, 'setPoints clears the selection');
        end

        function testLassoReturnsTheVisiblePointsInside(tc)
            v = tc.View;
            store = tc.recorder();
            v.Tool = "lasso";
            poly = [200 150; 420 150; 420 360; 200 360];
            inside = inpolygon(tc.XY(:, 1), tc.XY(:, 2), poly(:, 1), poly(:, 2));
            tc.assumeGreaterThan(nnz(inside), 3);
            hid = tc.Ids(find(inside, 1));
            v.setVisible(hid, false);
            moved = tc.Ids(find(~inside, 1));
            v.movePoints(moved, [300 250]);                 % moved into the polygon
            path = zeros(0, 2);
            for e = 1:3
                t = (0:0.05:1)';
                path = [path; poly(e, :) + t .* (poly(e + 1, :) - poly(e, :))]; %#ok<AGROW>
            end
            tc.verifyTrue(v.onButtonDown(tMapView.at(path(1, :), 'SelectionType', 'normal')));
            tc.verifyEqual(v.Gesture, "lasso");
            for i = 2:size(path, 1) - 1
                tc.verifyTrue(v.onMotion(tMapView.at(path(i, :))));
            end
            x = v.LassoLine.XData;
            tc.verifyGreaterThan(numel(x), 20, 'the lasso line grows while drawing');
            tc.verifyEqual([x(end) v.LassoLine.YData(end)], path(1, :), 'AbsTol', 1e-9, 'drawn closed');
            tc.verifyTrue(v.onButtonUp(tMapView.at(path(end, :))));
            L = tMapView.infos(store, "lasso");
            tc.assertNumElements(L, 1);
            expected = sort([tc.Ids(inside & tc.Ids ~= hid & tc.Ids ~= moved); moved]);
            tc.verifyEqual(sort(L{1}.Ids), expected, 'exactly the visible points inside, at their current places');
            tc.verifyEqual([min(L{1}.Polygon) max(L{1}.Polygon)], [200 150 420 360], 'AbsTol', 1e-6);
            tc.verifyTrue(all(isnan(v.LassoLine.XData)), 'the lasso line is cleared');
            tc.verifyEqual(v.Gesture, "");
            tc.verifyFalse(any(tMapView.kinds(store) == "click"), 'no point clicks in the lasso tool');

            % Escape drops a lasso; a click draws none
            store('log') = {};
            v.onButtonDown(tMapView.at(path(1, :), 'SelectionType', 'normal'));
            v.onMotion(tMapView.at(path(5, :)));
            v.onMotion(tMapView.at(path(25, :)));
            tc.verifyTrue(v.onKeyPress(struct('Key', 'escape')));
            tc.verifyTrue(all(isnan(v.LassoLine.XData)));
            v.onButtonUp(tMapView.at(path(25, :)));
            v.onButtonDown(tMapView.at(path(1, :), 'SelectionType', 'normal'));
            v.onButtonUp(tMapView.at(path(1, :)));
            tc.verifyEmpty(tMapView.infos(store, "lasso"));
        end

        function testMoveToolDropAndCancel(tc)
            v = tc.View;
            store = tc.recorder();
            v.Tool = "move";
            id = uint32(5);
            from = tc.Special(5, :);
            row = v.rowsOf(id);
            grab = from + [1 0];
            tc.verifyTrue(v.onButtonDown(tMapView.at(grab, 'SelectionType', 'normal')));
            tc.verifyEqual(v.Gesture, "move");
            v.onMotion(tMapView.at(grab + [20 10]));
            v.onMotion(tMapView.at(grab + [40 25]));
            tc.verifyTrue(isnan(v.Points.XData(row)), 'the scatter hides the dragged point');
            tc.verifyEqual(v.DragLine.XData, [from(1) from(1) + 40], 'AbsTol', 1e-9, 'the point follows the pointer');
            tc.verifyEqual(v.DragLine.YData, [from(2) from(2) + 25], 'AbsTol', 1e-9);
            tc.verifyTrue(v.onButtonUp(tMapView.at(grab + [60 30])));
            k = tMapView.kinds(store);
            tc.verifyEqual(k(1), "click");
            tc.verifyEqual(k(end), "drop");
            tc.verifyTrue(all(k(2:end - 1) == "drag"));
            D = tMapView.infos(store, "drag");
            tc.verifyEqual(D{1}.XY, from + [20 10], 'AbsTol', 1e-9);
            drop = tMapView.infos(store, "drop");
            tc.verifyEqual(drop{1}.Id, id);
            tc.verifyEqual(drop{1}.FromXY, from);
            tc.verifyEqual(drop{1}.ToXY, from + [60 30], 'AbsTol', 1e-9);
            tc.verifyEqual(v.XY(row, :), from + [60 30], 'AbsTol', 1e-9, 'the view moved the point');
            tc.verifyEqual([v.Points.XData(row) v.Points.YData(row)], from + [60 30], 'AbsTol', 1e-9);
            tc.verifyTrue(all(isnan(v.DragLine.XData)));
            tc.verifyEqual(v.Gesture, "");

            % Escape: the point snaps back and nothing is dropped
            store('log') = {};
            cur = v.XY(row, :);
            v.setSelection(id);
            v.onButtonDown(tMapView.at(cur, 'SelectionType', 'normal'));
            v.onMotion(tMapView.at(cur + [30 30]));
            tc.verifyEqual([v.SelectionLine.XData v.SelectionLine.YData], cur + [30 30], 'AbsTol', 1e-9, ...
                'the selection ring follows the drag');
            tc.verifyTrue(v.onKeyPress(struct('Key', 'escape')));
            tc.verifyEqual(v.XY(row, :), cur);
            tc.verifyEqual([v.Points.XData(row) v.Points.YData(row)], cur);
            tc.verifyEqual([v.SelectionLine.XData v.SelectionLine.YData], cur, 'AbsTol', 1e-9);
            tc.verifyTrue(all(isnan(v.DragLine.XData)));
            tc.verifyTrue(v.onButtonUp(tMapView.at(cur + [30 30])), 'the release still belongs to the map');
            tc.verifyFalse(any(tMapView.kinds(store) == "drop"));

            % a release outside the image cancels
            r = v.viewRect();
            tc.assumeGreaterThan(r(2), tc.W + 20, 'needs room right of the image');
            outside = [r(2) - 10, cur(2)];
            v.onButtonDown(tMapView.at(cur, 'SelectionType', 'normal'));
            v.onMotion(tMapView.at(outside));
            tc.verifyTrue(v.onButtonUp(tMapView.at(outside)));
            tc.verifyEqual(v.XY(row, :), cur);
            tc.verifyEqual([v.Points.XData(row) v.Points.YData(row)], cur);
            tc.verifyFalse(any(tMapView.kinds(store) == "drop"));

            % a click without moving: no drop, nothing moved; cancelDrag from the app
            store('log') = {};
            v.onButtonDown(tMapView.at(cur, 'SelectionType', 'normal'));
            v.onButtonUp(tMapView.at(cur));
            tc.verifyEqual(tMapView.kinds(store), "click");
            v.onButtonDown(tMapView.at(cur, 'SelectionType', 'normal'));
            v.onMotion(tMapView.at(cur + [-40 10]));
            tc.verifyTrue(v.cancelDrag());
            tc.verifyEqual([v.Points.XData(row) v.Points.YData(row)], cur);
            tc.verifyFalse(v.cancelDrag(), 'nothing left to cancel');
            v.onButtonUp(tMapView.at(cur + [-40 10]));
            tc.verifyFalse(any(tMapView.kinds(store) == "drop"));
        end

        function testAddToolClickOnEmptySpaceVsOnAPoint(tc)
            v = tc.View;
            store = tc.recorder();
            v.Tool = "add";
            p = tc.emptySpot();
            tc.verifyTrue(v.onButtonDown(tMapView.at(p, 'SelectionType', 'normal')));
            tc.verifyTrue(v.onButtonUp(tMapView.at(p)));
            tc.verifyEqual(tMapView.kinds(store), "empty");
            E = tMapView.infos(store, "empty");
            tc.verifyEqual(E{1}.XY, p, 'AbsTol', 1e-9);
            tc.verifyEqual(E{1}.Tool, "add");
            tc.verifyEqual(E{1}.SelectionType, 'normal');

            store('log') = {};
            a = tc.Special(1, :);
            v.onButtonDown(tMapView.at(a + [2 1], 'SelectionType', 'normal'));
            v.onButtonUp(tMapView.at(a + [2 1]));
            tc.verifyEqual(tMapView.kinds(store), "click", 'a click on a point is a point click, not an add');
            C = tMapView.infos(store, "click");
            tc.verifyEqual(C{1}.Id, uint32(1));
            tc.verifyEqual(C{1}.XY, a);
            tc.verifyEqual(C{1}.PointerXY, a + [2 1], 'AbsTol', 1e-9);

            store('log') = {};
            r = v.viewRect();
            tc.assumeGreaterThan(r(2), tc.W + 20, 'needs room right of the image');
            q = [r(2) - 10, 300];
            tc.verifyTrue(v.onButtonDown(tMapView.at(q, 'SelectionType', 'normal')), 'outside the image, inside the map');
            tc.verifyTrue(v.onButtonUp(tMapView.at(q)));
            tc.verifyEmpty(store('log'), 'no add outside the image');

            % a drag on empty space pans instead of adding
            v.centerOn(p, 100);
            c0 = v.Center;
            fp = v.dataToFigure(p);
            v.onButtonDown(tMapView.fig(fp, 'SelectionType', 'normal'));
            v.onMotion(tMapView.fig(fp + [30 0]));
            v.onButtonUp(tMapView.fig(fp + [30 0]));
            tc.verifyEmpty(store('log'));
            tc.verifyEqual(v.Center(1), c0(1) - 30 * v.Scale, 'AbsTol', 1e-9);

            % a right click on empty space is reported with its SelectionType (the app ignores it)
            v.onButtonDown(tMapView.at(p, 'SelectionType', 'alt'));
            v.onButtonUp(tMapView.at(p));
            E = tMapView.infos(store, "empty");
            tc.assertNumElements(E, 1);
            tc.verifyEqual(E{1}.SelectionType, 'alt');
        end

        function testSelectToolClicksAndPans(tc)
            v = tc.View;
            store = tc.recorder();
            tc.verifyEqual(v.Tool, "select");
            a = tc.Special(2, :);
            v.onButtonDown(tMapView.at(a, 'SelectionType', 'normal'));
            v.onButtonUp(tMapView.at(a));
            v.onButtonDown(tMapView.at(a, 'SelectionType', 'extend', 'Modifier', "shift"));
            v.onButtonUp(tMapView.at(a));
            C = tMapView.infos(store, "click");
            tc.assertNumElements(C, 2);
            tc.verifyEqual([C{1}.Id C{2}.Id], uint32([2 2]));
            tc.verifyEqual({C{1}.SelectionType C{2}.SelectionType}, {'normal' 'extend'});
            tc.verifyEqual(C{2}.Modifier, "shift");

            p = tc.emptySpot([400 300]);
            v.centerOn(p, 80);
            c0 = v.Center;
            fp0 = v.dataToFigure(p);
            store('log') = {};
            v.onButtonDown(tMapView.fig(fp0, 'SelectionType', 'normal'));
            v.onMotion(tMapView.fig(fp0 + [1 1]));
            tc.verifyEqual(v.Center, c0, 'below the drag threshold nothing moves');
            v.onMotion(tMapView.fig(fp0 + [40 -25]));
            tc.verifyEqual(v.Gesture, "pan");
            tc.verifyEqual(v.figureToData(fp0 + [40 -25]), p, 'AbsTol', 1e-9, 'the grabbed pixel follows the pointer');
            v.onButtonUp(tMapView.fig(fp0 + [40 -25]));
            tc.verifyEmpty(store('log'), 'a pan is not a click');
            v.onButtonDown(tMapView.at(p, 'SelectionType', 'normal'));
            v.onButtonUp(tMapView.at(p));
            tc.verifyEqual(tMapView.kinds(store), "empty", 'a click on empty space');

            % the middle button pans in the lasso tool too
            v.Tool = "lasso";
            store('log') = {};
            c0 = v.Center;
            fp = tc.panelMiddle();
            v.onButtonDown(tMapView.fig(fp, 'SelectionType', 'extend'));
            v.onMotion(tMapView.fig(fp + [-20 0]));
            v.onButtonUp(tMapView.fig(fp + [-20 0]));
            tc.verifyEqual(v.Center(1), c0(1) + 20 * v.Scale, 'AbsTol', 1e-9);
            tc.verifyEmpty(store('log'));
        end

        function testSweepFieldsCoverTheImage(tc)
            v = tc.View;
            pp = getpixelposition(v.Panel, true);
            for cfg = [100 0.1; 250 0.25; 400 0; 60 0.5; 5000 0.1]'
                fieldUm = cfg(1);
                ov = cfg(2);
                R = v.sweepRects(fieldUm, ov);
                what = sprintf('field %g um, overlap %g', fieldUm, ov);
                tc.verifyEqual(R, v.SweepRects);
                tc.verifyGreaterThanOrEqual(R(:, [1 3]), 0.5 - 1e-9, what);
                tc.verifyLessThanOrEqual(R(:, 2), tc.W + 0.5 + 1e-9, what);
                tc.verifyLessThanOrEqual(R(:, 4), tc.H + 0.5 + 1e-9, what);
                xs = unique(R(:, 1:2), 'rows');
                ys = unique(R(:, 3:4), 'rows');
                tc.verifyEqual(size(R, 1), size(xs, 1) * size(ys, 1), [what ': a full grid']);
                tc.verifyEqual(size(unique(R, 'rows'), 1), size(R, 1), [what ': no field twice']);
                checkAxis(xs, tc.W, ov, what);
                checkAxis(ys, tc.H, ov, what);
                fw = R(1, 2) - R(1, 1);
                fh = R(1, 4) - R(1, 3);
                if fw < tc.W && fh < tc.H
                    tc.verifyEqual(fw, fieldUm / tc.UmPerPx, 'RelTol', 1e-9, what);
                    tc.verifyEqual(fh / fw, pp(4) / pp(3), 'RelTol', 1e-9, [what ': the viewport''s shape']);
                end
                % row by row: rows top to bottom, the next field always a neighbour (serpentine)
                tc.verifyTrue(issorted(R(:, 3)), what);
                for k = 2:size(R, 1)
                    if R(k, 3) == R(k - 1, 3)
                        tc.verifyLessThan(abs(R(k, 1) - R(k - 1, 1)), fw + 1e-9, what);
                    else
                        tc.verifyEqual(R(k, 1), R(k - 1, 1), 'AbsTol', 1e-9, [what ': next row starts below']);
                    end
                end
            end
            R = v.sweepRects(150, 0.2, Order="raster");
            for k = 2:size(R, 1)
                if R(k, 3) == R(k - 1, 3); tc.verifyGreaterThan(R(k, 1), R(k - 1, 1)); end
            end
            R = v.sweepRects(150, 0.2);
            v.showSweepRect(3);
            r = v.viewRect();
            tc.verifyEqual(v.SweepIndex, 3);
            tc.verifyTrue(r(1) <= R(3, 1) && r(2) >= R(3, 2) && r(3) <= R(3, 3) && r(4) >= R(3, 4), ...
                'the field is in view');
            tc.verifyLessThan(diff(r(1:2)), 1.2 * (R(3, 2) - R(3, 1)), 'zoomed to the field');
            tc.verifyEqual(v.SweepLine.XData, R(3, [1 2 2 1 1]));
            tc.verifyEqual(v.SweepLine.YData, R(3, [3 3 4 4 3]));
            v.showSweepRect(0);
            tc.verifyTrue(all(isnan(v.SweepLine.XData)));
            tc.verifyError(@() v.showSweepRect(size(R, 1) + 1), 'MapView:BadSweep');

            function checkAxis(iv, L, ov, what)
                % the fields of one axis cover [0.5, L + 0.5] with neighbours overlapping >= ov
                iv = sortrows(iv);
                tc.verifyEqual(iv(1, 1), 0.5, 'AbsTol', 1e-9, [what ': starts at the edge']);
                tc.verifyEqual(iv(end, 2), L + 0.5, 'AbsTol', 1e-9, [what ': ends at the edge']);
                w = iv(1, 2) - iv(1, 1);
                for j = 2:size(iv, 1)
                    tc.verifyLessThanOrEqual(iv(j, 1), iv(j - 1, 2) - ov * w + 1e-9, [what ': overlap']);
                end
            end
        end

        function testModesShowTheRightPages(tc)
            v = tc.View;
            limT = curation.CropCache.pageLimits(tc.PageT, [1 99.9], 1e6);
            limC = curation.CropCache.pageLimits(tc.PageC, [1 99.9], 1e6);
            tc.verifyEqual(v.Limits, [limT; limC]);
            bT = uint8((double(tc.PageT) - limT(1)) * (255 / diff(limT)));
            bC = uint8((double(tc.PageC) - limC(1)) * (255 / diff(limC)));
            v.setMode("target");
            C = v.Image.CData;
            tc.verifyEqual(C, cat(3, bT, bT, bT));
            v.setMode("companion");
            tc.verifyEqual(v.Image.CData, cat(3, bC, bC, bC));
            v.setMode("overlay");
            tc.verifyEqual(v.Image.CData, cat(3, bC, bT, bC), 'target green, companion magenta');
            v.setGain(2);
            v.setGamma([0.5 1]);
            x = (0:255)' / 255;
            lutT = uint8(255 * min(1, max(0, x * 2)) .^ 0.5);       % curation.CropCache's look-up table
            lutC = uint8(255 * min(1, max(0, x * 2)) .^ 1);
            tc.verifyEqual(v.Image.CData, cat(3, lutC(double(bC) + 1), lutT(double(bT) + 1), lutC(double(bC) + 1)));
            tc.verifyError(@() v.setMode("side"), 'MapView:BadMode');
            tc.verifyError(@() v.setGamma(0), 'MapView:BadGamma');

            % limits given are used as they are
            v.setGain(1);
            v.setGamma(1);
            v.setImage(tc.PageT, tc.PageC, [0 50; 0 30], tc.UmPerPx);
            tc.verifyEqual(v.Mode, "overlay", 'the mode survives a new source');
            C = v.Image.CData;
            tc.verifyEqual(C(:, :, 2), uint8(double(tc.PageT) * (255 / 50)));
            tc.verifyEqual(C(:, :, 1), uint8(double(tc.PageC) * (255 / 30)));
            % no companion: the magenta part is empty, the companion mode shows the target
            v.setImage(tc.PageT, [], [], tc.UmPerPx);
            C = v.Image.CData;
            tc.verifyEqual(C(:, :, 2), bT);
            tc.verifyEqual(nnz(C(:, :, [1 3])), 0);
            v.setMode("companion");
            tc.verifyEqual(v.Image.CData, cat(3, bT, bT, bT));
        end

        function testDisplayIsIndependentOfThePageScale(tc)
            v = tc.View;
            v.setMode("overlay");
            T = double(tc.PageT);
            Cp = double(tc.PageC);
            v.setImage(T, Cp, [], tc.UmPerPx);
            A = v.Image.CData;
            v.setImage(T * 1000, Cp * 1000, [], tc.UmPerPx);
            tc.verifyEqual(v.Image.CData, A, 'page x 1000 -> the identical image');
            v.setImage(T / 1000 + 7e-3, Cp * 1e6, [], tc.UmPerPx);
            tc.verifyEqual(v.Image.CData, A, 'any scale and offset');
            % single-precision pages: x 1000 rounds each value, so a few pixels may land one level apart
            v.setImage(tc.PageT, tc.PageC, [], tc.UmPerPx);
            A = v.Image.CData;
            v.setImage(tc.PageT * 1000, tc.PageC * 1000, [], tc.UmPerPx);
            d = abs(double(v.Image.CData) - double(A));
            tc.verifyLessThanOrEqual(max(d(:)), 1);
            tc.verifyLessThan(nnz(d) / numel(d), 1e-3);
        end

        function testRoutingSaysWhetherTheEventIsTheMaps(tc)
            f = uifigure('Name', 'tMapView routing', 'Position', [60 60 1000 500]);
            tc.addTeardown(@() tMapView.closeFigure(f));
            g = uigridlayout(f, [1 2], 'Padding', [0 0 0 0], 'ColumnSpacing', 0);
            m = curation.MapView(g);
            m.Panel.Layout.Column = 1;
            other = uipanel(g);
            other.Layout.Column = 2;
            m.setImage(tc.PageT, [], [], 1);
            m.setPoints(tc.Ids, tc.XY, tc.Grey);
            tMapView.waitForLayout(f, m.Panel, [500 500]);
            po = getpixelposition(other, true);
            pin = po(1:2) - 1 + po(3:4) / 2;
            pm = getpixelposition(m.Panel, true);
            pmid = pm(1:2) - 1 + pm(3:4) / 2;
            ev = @tMapView.fig;
            tc.verifyFalse(m.onButtonDown(ev(pin, 'SelectionType', 'normal')), 'press on the other panel');
            tc.verifyFalse(m.onMotion(ev(pin)));
            tc.verifyFalse(m.onButtonUp(ev(pin)));
            tc.verifyFalse(m.onScroll(ev(pin, 'VerticalScrollCount', -1)));
            tc.verifyFalse(m.onKeyPress(struct('Key', 'escape')), 'no gesture to cancel');
            tc.verifyTrue(m.IsFit, 'a scroll over the other panel did not zoom the map');
            tc.verifyTrue(m.onScroll(ev(pmid, 'VerticalScrollCount', -1)));
            tc.verifyTrue(m.onMotion(ev(pmid)));
            % a drag that starts on the map keeps its events when it leaves the map
            tc.verifyTrue(m.onButtonDown(ev(pmid, 'SelectionType', 'normal')));
            tc.verifyTrue(m.onMotion(ev(pin)));
            tc.verifyTrue(m.onButtonUp(ev(pin)));
            % a press on the other panel released over the map is not the map's
            tc.verifyFalse(m.onButtonDown(ev(pin, 'SelectionType', 'normal')));
            tc.verifyFalse(m.onButtonUp(ev(pmid)));
            % the edge: the map's last pixel column is the map's, the next one the other panel's
            edge = pm(1) - 1 + pm(3);
            tc.verifyTrue(m.onMotion(ev([edge - 0.5, pmid(2)])));
            tc.verifyFalse(m.onMotion(ev([edge + 1.5, pmid(2)])));
            % and a press on a point: the map takes it, and its release
            m.fit();
            tc.verifyTrue(m.onButtonDown(ev(m.dataToFigure(tc.Special(2, :)), 'SelectionType', 'normal')));
            tc.verifyTrue(m.onButtonUp(ev(m.dataToFigure(tc.Special(2, :)))));
        end

        function testHoverReportsThePointUnderThePointer(tc)
            v = tc.View;
            store = tc.recorder();
            a = tc.Special(1, :);
            tc.verifyTrue(v.onMotion(tMapView.at(a + [1 1])));
            v.onMotion(tMapView.at(a + [2 1]));
            tc.verifyEqual([v.HoverLine.XData v.HoverLine.YData], a, 'a ring on the hovered point');
            p = tc.emptySpot();
            v.onMotion(tMapView.at(p));
            tc.verifyTrue(all(isnan(v.HoverLine.XData)));
            tc.verifyFalse(v.onMotion(tMapView.fig([-50 -50])), 'outside the map');
            hv = tMapView.infos(store, "hover");
            tc.verifyEqual(cellfun(@(h) double(h.Id), hv), [1 0], 'each change once');
            % throttled: the last one is delivered after the interval
            store('log') = {};
            v.HoverInterval = 0.3;
            pause(0.35);                                    % the interval since the last delivery is over
            v.onMotion(tMapView.at(tc.Special(1, :)));
            v.onMotion(tMapView.at(tc.Special(2, :)));
            v.onMotion(tMapView.at(tc.Special(5, :)));
            hv = tMapView.infos(store, "hover");
            tc.verifyEqual(cellfun(@(h) double(h.Id), hv), 1);
            pause(0.6);
            drawnow;
            hv = tMapView.infos(store, "hover");
            tc.verifyEqual(cellfun(@(h) double(h.Id), hv), [1 5], 'the latest is delivered after the interval');
            tc.verifyEqual([v.HoverLine.XData v.HoverLine.YData], tc.Special(5, :), 'the ring is not throttled');
        end

        function testPointerShowsTheTool(tc)
            v = tc.View;
            p = tc.emptySpot();
            v.Tool = "add";
            v.onMotion(tMapView.at(p));
            tc.verifyEqual(string(tc.Fig.Pointer), "crosshair");
            v.Tool = "move";
            tc.verifyEqual(string(tc.Fig.Pointer), "fleur", 'changes at once while over the map');
            v.Tool = "lasso";
            tc.verifyEqual(string(tc.Fig.Pointer), "cross");
            v.Tool = "select";
            tc.verifyEqual(string(tc.Fig.Pointer), "arrow");
            v.Tool = "add";
            v.onMotion(tMapView.fig([-50 -50]));
            tc.verifyEqual(string(tc.Fig.Pointer), "arrow", 'given back when the pointer leaves');
            tc.verifyError(@() tMapView.setTool(v, "zoom"), 'MapView:BadTool');
            v.Tool = "SELECT";
            tc.verifyEqual(v.Tool, "select");
        end

        function testRegionsAreDrawnByKind(tc)
            v = tc.View;
            reg = tMapView.someRegions();
            v.setRegions(reg);
            ex = reg(1).xy;
            tc.verifyEqual(v.ExcludeFill.Vertices, ex);
            tc.verifyEqual(v.ExcludeFill.Faces, 1:5);
            tc.verifyGreaterThan(v.ExcludeFill.FaceAlpha, 0);
            tc.verifyLessThan(v.ExcludeFill.FaceAlpha, 0.5, 'translucent');
            hx = v.ExcludeHatch.XData(:);
            hy = v.ExcludeHatch.YData(:);
            seg = reshape([hx; NaN(mod(-numel(hx), 3), 1)], 3, []);
            sy = reshape([hy; NaN(mod(-numel(hy), 3), 1)], 3, []);
            tc.verifyGreaterThan(size(seg, 2), 4, 'hatch lines');
            mx = mean(seg(1:2, :), 1);
            my = mean(sy(1:2, :), 1);
            tc.verifyTrue(all(inpolygon(mx, my, ex(:, 1), ex(:, 2))), 'the hatch stays inside the polygon');
            tc.verifyEqual(diff(sy(1:2, :)), diff(seg(1:2, :)), 'AbsTol', 1e-9, 'diagonal');
            ax = v.AnalysisLine.XData(:);
            tc.verifyEqual(ax(1:6), [40; 760; 760; 40; 40; NaN], 'a closed outline');
            tc.verifyEqual(string(v.ReferenceLine.LineStyle), "--", 'reference: dashed');
            tc.verifyEqual(string(v.AnalysisLine.LineStyle), "-");
            tc.verifyEqual(numel(v.Regions), 3);
            % two exclusion regions: one patch, two faces
            two = reg([1 1 2]);
            two(2).xy = [500 400; 600 400; 600 500; 500 500; 500 400];      % closed form is accepted
            v.setRegions(two);
            tc.verifyEqual(size(v.ExcludeFill.Faces), [2 5]);
            tc.verifyTrue(isnan(v.ExcludeFill.Faces(2, 5)), 'NaN-padded');
            v.setRegions([]);
            tc.verifyEmpty(v.ExcludeFill.Faces);
            tc.verifyTrue(all(isnan(v.AnalysisLine.XData)) && all(isnan(v.ReferenceLine.XData)) && ...
                all(isnan(v.ExcludeHatch.XData)));
            bad = reg(1);
            bad.kind = "mask";
            tc.verifyError(@() v.setRegions(bad), 'MapView:BadRegions');
        end

        function testResizeKeepsTheViewAndReportsChanges(tc)
            v = tc.View;
            n = 0;
            function onView(~, in)
                n = n + 1;
                tc.verifyEqual(in.Rect, v.viewRect());
            end
            v.ViewChangedFcn = @(m, in) onView(m, in);
            v.zoomBy(2);
            v.panBy(10, 0);
            tc.verifyEqual(n, 2, 'zoom and pan report a view change');
            v.fit();
            tc.Fig.Position(3:4) = [700 500];
            tMapView.waitForLayout(tc.Fig, v.Panel, [700 500]);   % the requested size: a resize applies asynchronously
            pp = getpixelposition(v.Panel, true);
            tc.verifyTrue(v.IsFit, 'a fitted view stays fitted');
            r = v.viewRect();
            tc.verifyEqual(diff(r(1:2)) / pp(3), diff(r(3:4)) / pp(4), 'RelTol', 1e-9);
            tc.verifyEqual(max(tc.W / diff(r(1:2)), tc.H / diff(r(3:4))), 1, 'RelTol', 1e-9, 'the whole image fits');
            v.centerOn([400 300], 50);
            s = v.Scale;
            tc.Fig.Position(3:4) = [900 640];
            tMapView.waitForLayout(tc.Fig, v.Panel, [900 640]);
            tc.verifyEqual(v.Center, [400 300], 'AbsTol', 1e-9);
            tc.verifyEqual(v.Scale, s, 'RelTol', 1e-12);
            % a channel switch keeps the view; a new source fits
            v.setImage(tc.PageC, tc.PageT, [], tc.UmPerPx, KeepView=true);
            tc.verifyEqual(v.Center, [400 300], 'AbsTol', 1e-9);
            v.setImage(tc.PageC, tc.PageT, [], tc.UmPerPx);
            tc.verifyTrue(v.IsFit);
        end

        function testUitestPressOnAPoint(tc)
            % matlab.uitest gestures are given in FIGURE pixels computed from the view's own geometry
            % (v.dataToFigure): a gesture given in axes data coordinates is mapped to the screen by
            % the browser with the axes limits it last rendered, which may lag MATLAB's (integration
            % pass C, item 1: testUitestDragPans panned 0.2 of the distance in the full suite)
            v = tc.View;
            v.installRouting();
            store = tc.recorder();
            drawnow;
            a = tc.Special(1, :);
            tMapView.gestureOrSkip(tc, @() tc.press(tc.Fig, v.dataToFigure(a)), 'press on the figure');
            drawnow;
            C = tMapView.infos(store, "click");
            tc.assertNotEmpty(C, 'a real press reaches the view through the figure callbacks');
            tc.verifyEqual(C{1}.Id, uint32(1));
            tc.verifyEqual(C{1}.SelectionType, 'normal');
            tc.verifyEqual(C{1}.PointerXY, a, 'AbsTol', 2 * v.Scale + 1);
        end

        function testUitestDragMovesAPoint(tc)
            v = tc.View;
            v.Tool = "move";
            v.installRouting();
            store = tc.recorder();
            drawnow;
            from = tc.Special(5, :);
            to = from + [60 -40];
            tMapView.gestureOrSkip(tc, @() tc.drag(tc.Fig, v.dataToFigure(from), v.dataToFigure(to)), ...
                'drag on the figure');
            drawnow;
            D = tMapView.infos(store, "drop");
            tc.assertNumElements(D, 1, 'one drop');
            tc.verifyEqual(D{1}.Id, uint32(5));
            tc.verifyEqual(D{1}.ToXY, to, 'AbsTol', 2 * v.Scale + 1);
            tc.verifyEqual(v.XY(v.rowsOf(uint32(5)), :), D{1}.ToXY);
            tc.verifyGreaterThan(numel(tMapView.infos(store, "drag")), 0, 'the point followed the pointer');
        end

        function testUitestDragPans(tc)
            % A pan follows the pointer's pixels at the scale of the press. The drag is given in
            % figure pixels: the view zooms in just before it, and a drag in data coordinates is
            % mapped by the browser with the limits it rendered last (without the drawnow below,
            % always the fitted view's: the pan was then exactly 0.2 of the distance, the ratio of
            % the two scales; with it, now and then under a long suite's load)
            v = tc.View;
            v.installRouting();
            store = tc.recorder();
            p0 = tc.emptySpot([400 300]);
            v.centerOn(p0, 100);
            drawnow;
            c0 = v.Center;
            p1 = p0 + [40 25];
            f0 = v.dataToFigure(p0);
            f1 = v.dataToFigure(p1);
            tMapView.gestureOrSkip(tc, @() tc.drag(tc.Fig, f0, f1), 'drag on the figure');
            drawnow;
            tc.verifyEqual(v.Center, c0 - (p1 - p0), 'AbsTol', 2 * v.Scale + 1, 'the image followed the pointer');
            tc.verifyEmpty(tMapView.infos(store, "empty"), 'a pan is not a click');
        end

        function testDeletingTheFigureDeletesTheView(tc)
            v = tc.View;
            v.HoverFcn = @(varargin) [];
            v.HoverInterval = 0.5;
            v.onMotion(tMapView.at(tc.Special(1, :)));
            v.onMotion(tMapView.at(tc.Special(2, :)));     % arms the hover timer
            delete(tc.Fig);
            tc.verifyFalse(isvalid(v));
            tc.verifyEmpty(timerfindall('Name', 'MapView hover'), 'timers are deleted with the view');
            tc.verifyEmpty(timerfindall('Name', 'MapView layout'), 'the layout timer too');
        end

        function testMadeHiddenTakesItsSizeWhenShown(tc)
            % (pass B, defect a) a view made inside a hidden container had a stale size and scale
            % until a resize arrived: the next click picked with a huge radius, a drag never panned
            f = uifigure('Name', 'tMapView hidden', 'Position', [60 60 900 620]);
            tc.addTeardown(@() tMapView.closeFigure(f));
            g = uigridlayout(f, [1 1], 'Padding', [0 0 0 0]);
            host = uipanel(g, 'Visible', 'off', 'BorderType', 'none');
            hg = uigridlayout(host, [2 1], 'RowHeight', {40, '1x'}, 'Padding', [0 0 0 0]);
            uilabel(hg, 'Text', 'bar');
            v = curation.MapView(hg);
            v.Panel.Layout.Row = 2;
            v.HoverInterval = 0;
            v.setImage(tc.PageT, tc.PageC, [], tc.UmPerPx);
            v.setPoints(tc.Ids, tc.XY, tc.Grey);
            drawnow;
            pause(0.3);
            host.Visible = 'on';                        % shown: no code of the owner runs after this
            t0 = tic;
            while toc(t0) < 5
                drawnow;
                pp = getpixelposition(v.Panel, true);
                if pp(3) > 800 && pp(4) > 500, break; end
                pause(0.05);
            end
            pause(0.8);                                 % the view's own re-checks run
            drawnow;
            pp = getpixelposition(v.Panel, true);
            r = v.viewRect();
            tc.verifyTrue(v.IsFit, 'still the whole section');
            tc.verifyEqual(max(diff(r(1:2)) / pp(3), diff(r(3:4)) / pp(4)), v.Scale, 'RelTol', 1e-6, ...
                'the scale follows the panel''s real size');
            tc.verifyEqual(v.Axes.InnerPosition(3:4), pp(3:4), 'AbsTol', 1, 'the axes fill the panel');
            % a press: the pick radius is 8 screen pixels at the real scale
            a = tc.Special(1, :);
            hit = uint32(99);
            function onHit(id)
                hit = uint32(id);
            end
            v.PointClickFcn = @(~, in) onHit(in.Id);
            v.EmptyClickFcn = @(~, ~) onHit(0);
            off = a + [12 0] * v.Scale;                 % 12 screen px away: not a hit
            v.onButtonDown(tMapView.at(off, 'SelectionType', 'normal'));
            v.onButtonUp(tMapView.at(off));
            tc.verifyEqual(hit, uint32(0), 'a press 12 px off the point misses it');
            v.onButtonDown(tMapView.at(a + [3 0] * v.Scale, 'SelectionType', 'normal'));
            v.onButtonUp(tMapView.at(a + [3 0] * v.Scale));
            tc.verifyEqual(hit, uint32(1), 'a press 3 px off it hits it');
            % a drag of 30 screen px pans
            v.centerOn([400 300], 120);
            c0 = v.Center;
            p0 = tc.emptySpot([400 300]);
            v.onButtonDown(tMapView.at(p0, 'SelectionType', 'normal'));
            v.onMotion(tMapView.at(p0 + [30 0] * v.Scale));
            v.onButtonUp(tMapView.at(p0 + [30 0] * v.Scale));
            tc.verifyGreaterThan(norm(v.Center - c0), 0, 'the drag passed its threshold and panned');
            % hidden again, the window resized meanwhile, shown: refreshLayout takes the new size
            host.Visible = 'off';
            f.Position(3:4) = [760 560];
            drawnow;
            pause(0.3);
            host.Visible = 'on';
            t0 = tic;
            while toc(t0) < 5
                drawnow;
                pp = getpixelposition(v.Panel, true);
                if pp(3) < 800, break; end
                pause(0.05);
            end
            v.refreshLayout();
            pp = getpixelposition(v.Panel, true);
            r = v.viewRect();
            tc.verifyEqual(diff(r(1:2)) / pp(3), v.Scale, 'RelTol', 1e-6, 'refreshLayout re-reads the size');
            v.refreshLayout();                          % nothing changed: nothing happens
            tc.verifyEqual(v.viewRect(), r);
        end

        function testSetHoverFromCode(tc)
            % (pass B, defect c) the hover ring can be set from code
            v = tc.View;
            store = tc.recorder();
            v.setHover(uint32(2));
            tc.verifyEqual(v.HoverId, uint32(2));
            tc.verifyEqual([v.HoverLine.XData v.HoverLine.YData], tc.Special(2, :), 'the ring is on point 2');
            tc.verifyEmpty(tMapView.infos(store, "hover"), 'HoverFcn is not called for a hover set from code');
            v.setHover(0);
            tc.verifyEqual(v.HoverId, uint32(0));
            tc.verifyTrue(all(isnan(v.HoverLine.XData)), 'setHover(0) clears the ring');
            v.setVisible(uint32(3), false);
            v.setHover(uint32(3));
            tc.verifyEqual(v.HoverId, uint32(0), 'a hidden point is not ringed');
            v.setHover(uint32(99999));
            tc.verifyEqual(v.HoverId, uint32(0), 'nor an unknown one');
            v.setHover(uint32(5));
            v.onMotion(tMapView.at(tc.Special(1, :) + [1 1]));
            tc.verifyEqual(v.HoverId, uint32(1), 'the pointer takes the ring over');
            hv = tMapView.infos(store, "hover");
            tc.verifyEqual(cellfun(@(h) double(h.Id), hv), 1, 'and reports its own hover');
        end

        function testConstructionFromATimer(tc)
            % (pass B, defect b) a view constructed by a timer while another one is being constructed;
            % with the class loaded first (curation.MapView.preload) both are made
            curation.MapView.preload();
            g2 = uigridlayout(tc.Fig, [1 2]);
            made = {};
            errs = {};
            function fromTimer()
                try
                    made{end + 1} = curation.MapView(g2);
                catch err
                    errs{end + 1} = err.message;
                end
            end
            t = timer('StartDelay', 0.001, 'ExecutionMode', 'singleShot', 'TimerFcn', @(~, ~) fromTimer());
            tc.addTeardown(@() delete(t));
            start(t);
            m = curation.MapView(g2);
            tc.addTeardown(@() delete(m));
            t0 = tic;
            while isempty(made) && isempty(errs) && toc(t0) < 5
                pause(0.05);
            end
            tc.verifyEmpty(errs, 'the timer''s view is made');
            tc.verifyNumElements(made, 1);
            tc.verifyTrue(isvalid(m));
            for k = 1:numel(made), delete(made{k}); end
        end

        function testBeforeAnImageIsSet(tc)
            m = curation.MapView(tc.Grid);
            tc.addTeardown(@() delete(m));
            tc.verifyEqual(m.pick([5 5]), uint32(0));
            tc.verifyFalse(m.onButtonDown(tMapView.fig([-5 -5], 'SelectionType', 'normal')));
            m.setMode("overlay");
            m.setPoints(uint32(1), [3 3], [1 2 3]);
            tc.verifyEqual(m.N, 1);
            tc.verifyError(@() m.setImage(zeros(10, 10), zeros(5, 5), [], 1), 'MapView:BadPage');
            tc.verifyError(@() m.setPoints(uint32([1 1]), [1 1; 2 2], [0 0 0]), 'MapView:DuplicateIds');
        end
    end
end

function c = centroid(mask)
[r, k] = find(mask);
c = [mean(k) mean(r)];
end

function e = ringExtent(mask, c)
%ringExtent  [width height] in frame pixels of the mask pixels within 30 px of C.
[r, k] = find(mask);
near = hypot(k - c(1), r - c(2)) < 30;
e = [max(k(near)) - min(k(near)), max(r(near)) - min(r(near))] + 1;
end
