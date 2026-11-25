classdef tAnalysisMeasure < matlab.unittest.TestCase
    %tAnalysisMeasure  cellanalysis.Measure: luminance and morphology of synthetic cells whose size, shape,
    %   brightness and ring geometry are known. A soma of a given width is measured as that width at two
    %   pixel sizes; an ellipse gives its axis ratio and its angle; a ring its radius, an empty center and
    %   a closed wall, half a ring an open one; nothing depends on the gain or offset of the picture;
    %   cells at the frame, outside the tissue or without signal give "not segmented", never an error.
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tAnalysisMeasure

    methods (Static)
        function [img, xy] = scene(um, shape, opts)
            %scene  A 3 x 3 grid of identical cells on a flat, slightly noisy background (level BG).
            arguments
                um (1,1) double
                shape (1,1) string
                opts.Bg (1,1) double = 200
                opts.Amp (1,1) double = 600
                opts.Noise (1,1) double = 4
                opts.SigmaUm (1,2) double = [5 5]          % blob: sigma along x', y'
                opts.AngleDeg (1,1) double = 0            % counter-clockwise as displayed (y up)
                opts.RingUm (1,1) double = 8
                opts.WallUm (1,1) double = 1.6
                opts.Arc (1,2) double = [-Inf Inf]        % ring: angles (deg, y up) that carry the wall
                opts.Seed (1,1) double = 1
            end
            pitch = round(90 / um);
            n = 3 * pitch + 1;
            s = RandStream('mt19937ar', 'Seed', opts.Seed);
            img = opts.Bg + opts.Noise * randn(s, n, n);
            [gx, gy] = meshgrid((1:3) * pitch - pitch / 2 + 0.3, (1:3) * pitch - pitch / 2 - 0.2);
            xy = [gx(:), gy(:)];
            [X, Y] = meshgrid(1:n, 1:n);
            for k = 1:size(xy, 1)
                dx = (X - xy(k, 1)) * um;
                dy = -(Y - xy(k, 2)) * um;                % y up
                switch shape
                    case "blob"
                        c = cosd(opts.AngleDeg); sn = sind(opts.AngleDeg);
                        u = c * dx + sn * dy;
                        v = -sn * dx + c * dy;
                        img = img + opts.Amp * exp(-u .^ 2 / (2 * opts.SigmaUm(1)^2) - v .^ 2 / (2 * opts.SigmaUm(2)^2));
                    case "ring"
                        r = hypot(dx, dy);
                        th = atan2d(dy, dx);
                        on = th >= opts.Arc(1) & th <= opts.Arc(2);
                        img = img + opts.Amp * exp(-(r - opts.RingUm) .^ 2 / (2 * opts.WallUm^2)) .* on;
                    case "none"
                end
            end
            img = single(img);
        end
    end

    methods (Test)
        function aRoundSomaHasItsSize(tc)
            sigma = 5;                                   % um: full width at half maximum 11.8 um
            for um = [1.657 0.645]
                [img, xy] = tAnalysisMeasure.scene(um, "blob", SigmaUm = [sigma sigma]);
                [T, info] = cellanalysis.Measure.cells(img, xy, um, "pv");
                tc.verifyTrue(all(T.Segmented), sprintf('%.3f um/px: every cell is outlined', um));
                tc.verifyFalse(any(T.TouchesEdge));
                tc.verifyLessThanOrEqual(info.StepUm, 0.66, 'resampled on steps of 0.6 um or finer');
                tc.verifyEqual(median(T.DiameterUm), 2.355 * sigma, 'RelTol', 0.08, sprintf('%.3f um/px: diameter at half maximum', um));
                tc.verifyEqual(median(T.RadiusUm), 1.177 * sigma, 'RelTol', 0.10, 'half-maximum radius of the profile');
                tc.verifyEqual(median(T.AreaUm2), pi * (1.177 * sigma)^2, 'RelTol', 0.15);
                tc.verifyEqual(median(T.PerimeterUm), 2 * pi * 1.177 * sigma, 'RelTol', 0.10);
                tc.verifyGreaterThan(median(T.Circularity), 0.9);
                tc.verifyLessThan(median(T.AspectRatio), 1.12);
                tc.verifyGreaterThan(median(T.Solidity), 0.93);
                tc.verifyEqual(median(T.Background), 200, 'AbsTol', 3, 'the local background');
                tc.verifyEqual(median(T.PeakNet), 600, 'RelTol', 0.08, 'the peak above background');
                % mean of a Gaussian above its half maximum: A * (1 - 1/2) / ln 2 = 0.721 A
                tc.verifyEqual(median(T.NetMean), 0.721 * 600, 'RelTol', 0.08);
                tc.verifyEqual(median(T.Contrast), 0.721 * 600 / 200, 'RelTol', 0.09);
                tc.verifyGreaterThan(median(T.Snr), 30);
                tc.verifyTrue(all(isnan(T.RingRadiusUm)), 'net measures are for nets');
            end
        end

        function anEllipseHasItsAxesAndAngle(tc)
            um = 0.8;
            for ang = [0 30 -60 90]
                [img, xy] = tAnalysisMeasure.scene(um, "blob", SigmaUm = [6 3], AngleDeg = ang);
                T = cellanalysis.Measure.cells(img, xy, um, "pv");
                tc.verifyEqual(median(T.AspectRatio), 2, 'RelTol', 0.08, sprintf('angle %d: aspect ratio', ang));
                tc.verifyEqual(median(T.MajorUm), 2.355 * 6, 'RelTol', 0.10);
                tc.verifyEqual(median(T.MinorUm), 2.355 * 3, 'RelTol', 0.12);
                d = mod(median(T.OrientationDeg) - ang + 90, 180) - 90;
                tc.verifyEqual(d, 0, 'AbsTol', 4, sprintf('angle %d: orientation, counter-clockwise as displayed', ang));
                tc.verifyLessThan(median(T.Circularity), 0.9);
            end
        end

        function aNetHasItsRing(tc)
            for um = [1.657 0.645]
                [img, xy] = tAnalysisMeasure.scene(um, "ring", RingUm = 8, WallUm = 1.6);
                T = cellanalysis.Measure.cells(img, xy, um, "pnn");
                tc.verifyTrue(all(T.Segmented));
                tc.verifyEqual(median(T.RingRadiusUm), 8, 'AbsTol', 0.8, sprintf('%.3f um/px: the wall is 8 um from the center', um));
                tc.verifyGreaterThan(median(T.RingContrast), 0.85, 'an empty center');
                tc.verifyEqual(median(T.Completeness), 1, 'a closed ring');
                tc.verifyLessThan(median(T.AngularCV), 0.12, 'an even wall');
                tc.verifyEqual(median(T.WallThicknessUm), 2.355 * 1.6, 'AbsTol', 1.3, 'full width at half maximum of the wall');
                % the footprint is the hull of the wall: a disk out to the wall's outer half maximum
                tc.verifyEqual(median(T.DiameterUm), 2 * (8 + 1.177 * 1.6), 'RelTol', 0.08);
                tc.verifyEqual(median(T.RadiusUm), 8 + 1.177 * 1.6, 'RelTol', 0.10);
                tc.verifyLessThan(median(T.Solidity), 0.7, 'a ring fills little of its hull');
                tc.verifyGreaterThan(median(T.WallAreaUm2), 0.3 * median(T.AreaUm2));
                tc.verifyLessThan(median(T.WallAreaUm2), 0.75 * median(T.AreaUm2));
                tc.verifyGreaterThan(median(T.Circularity), 0.9);
            end
        end

        function halfANetIsOpen(tc)
            um = 0.8;
            [img, xy] = tAnalysisMeasure.scene(um, "ring", Arc = [0 180]);
            T = cellanalysis.Measure.cells(img, xy, um, "pnn");
            tc.verifyTrue(all(T.Segmented));
            tc.verifyEqual(median(T.Completeness), 0.5, 'AbsTol', 0.13, 'half of the directions carry a wall');
            tc.verifyGreaterThan(median(T.AngularCV), 0.6, 'a patchy wall');
            [imgF, xyF] = tAnalysisMeasure.scene(um, "ring");
            F = cellanalysis.Measure.cells(imgF, xyF, um, "pnn");
            tc.verifyLessThan(median(T.AreaUm2), 0.75 * median(F.AreaUm2), 'half a ring has a smaller footprint');
        end

        function gainAndOffsetDoNotChangeShape(tc)
            um = 1.657;
            [img, xy] = tAnalysisMeasure.scene(um, "ring");
            A = cellanalysis.Measure.cells(img, xy, um, "pnn");
            a = 37; b = 5000;
            B = cellanalysis.Measure.cells(a * img + b, xy, um, "pnn");
            for nm = ["AreaUm2" "DiameterUm" "MajorUm" "MinorUm" "PerimeterUm" "Circularity" "Solidity" ...
                    "RingRadiusUm" "WallThicknessUm" "RingContrast" "Completeness" "AngularCV" "RadiusUm" "Snr"]
                tc.verifyEqual(B.(nm), A.(nm), 'RelTol', 1e-3, 'AbsTol', 1e-3, nm + " does not depend on gain and offset");
            end
            tc.verifyEqual(B.Mean, a * A.Mean + b, 'RelTol', 1e-4);
            tc.verifyEqual(B.Background, a * A.Background + b, 'RelTol', 1e-4);
            tc.verifyEqual(B.NetMean, a * A.NetMean, 'RelTol', 1e-3);
            tc.verifyEqual(B.Integrated, a * A.Integrated, 'RelTol', 1e-3);
            tc.verifyEqual(B.ApertureNet, a * A.ApertureNet, 'RelTol', 1e-3);
        end

        function theOtherChannelIsMeasuredInsideTheCell(tc)
            um = 1.657;
            [net, xy] = tAnalysisMeasure.scene(um, "ring");
            [pv, ~] = tAnalysisMeasure.scene(um, "blob", SigmaUm = [4 4], Amp = 300, Bg = 50, Noise = 2, Seed = 2);
            empty = tAnalysisMeasure.scene(um, "none", Bg = 50, Noise = 2, Seed = 3);
            W = cellanalysis.Measure.cells(net, xy, um, "pnn", struct('Other', pv));
            N = cellanalysis.Measure.cells(net, xy, um, "pnn", struct('Other', empty));
            tc.verifyGreaterThan(min(W.OtherNet), 40, 'a PV soma inside each net');
            tc.verifyGreaterThan(min(W.OtherSnr), 10);
            tc.verifyEqual(median(N.OtherNet), 0, 'AbsTol', 2, 'nothing in the other channel');
            tc.verifyLessThan(max(abs(N.OtherSnr)), 4);
            O = cellanalysis.Measure.cells(net, xy, um, "pnn");
            tc.verifyTrue(all(isnan(O.OtherNet)), 'no other channel given');
        end

        function tissueStatisticsNormalizeTheMean(tc)
            um = 1.657;
            [img, xy] = tAnalysisMeasure.scene(um, "blob");
            st = cellanalysis.Measure.pageStats(img);
            tc.verifyEqual(st.Median, 200, 'AbsTol', 5);
            tc.verifyEqual(st.Mad, 4, 'AbsTol', 2.5);
            T = cellanalysis.Measure.cells(img, xy, um, "pv", struct('PageStats', st));
            tc.verifyEqual(T.MeanNorm, T.Mean / st.Median, 'RelTol', 1e-9);
            U = cellanalysis.Measure.cells(img, xy, um, "pv");
            tc.verifyTrue(all(isnan(U.MeanNorm)), 'without the tissue median there is no normalized mean');
        end

        function cellsWithoutSignalOrPixelsAreNotSegmented(tc)
            um = 1.657;
            [img, xy] = tAnalysisMeasure.scene(um, "blob");
            n = size(img, 1);
            pts = [xy(5, :);                 % a real cell
                n / 2 + 27, n / 2 + 27;      % between cells: nothing there
                3, 3;                        % in the corner: most of its window is outside the picture
                -50, 40;                     % outside the picture
                NaN, 10];
            T = cellanalysis.Measure.cells(img, pts, um, "pv");
            tc.verifyEqual(T.Segmented, [true; false; false; false; false]);
            tc.verifyTrue(isnan(T.AreaUm2(2)) && isnan(T.Mean(2)));
            tc.verifyEqual(T.ApertureNet(2), 0, 'AbsTol', 6, 'the aperture mean exists without an outline');
            tc.verifyTrue(all(isnan(T{4:5, "Background"})), 'no pixels, no numbers');
            % pixels outside the tissue are missing: a cell whose surround is half outside keeps its background
            valid = true(size(img));
            valid(:, 1:round(xy(1, 1) + 6 / um)) = false;       % the tissue ends 6 um right of the first column of cells
            V = cellanalysis.Measure.cells(img, xy, um, "pv", struct('Valid', valid));
            F = cellanalysis.Measure.cells(img, xy, um, "pv");
            tc.verifyEqual(V.Background(4:9), F.Background(4:9), 'AbsTol', 3, 'cells well inside are as before');
            tc.verifyTrue(all(isnan(V.Background(1:3)) | abs(V.Background(1:3) - 200) < 5), ...
                'a cell at the edge of the tissue has no background from outside it');
            E = cellanalysis.Measure.cells(img, zeros(0, 2), um, "pv");
            tc.verifyEqual(height(E), 0);
            tc.verifyTrue(all(ismember(cellanalysis.Measure.imageNames(), string(E.Properties.VariableNames))));
        end

        function aCellThatRunsIntoItsNeighborIsFlagged(tc)
            um = 0.8;
            s = 6;
            n = 201;
            [X, Y] = meshgrid(1:n, 1:n);
            c = [101 101];
            img = 200 + 600 * exp(-(((X - c(1)) * um) .^ 2 + ((Y - c(2)) * um) .^ 2) / (2 * s^2)) ...
                + 600 * exp(-(((X - c(1) - 14 / um) * um) .^ 2 + ((Y - c(2)) * um) .^ 2) / (2 * s^2));
            T = cellanalysis.Measure.cells(single(img), c, um, "pv");
            tc.verifyTrue(T.Segmented);
            tc.verifyTrue(T.TouchesEdge, 'two somata 14 um apart are one outline that reaches the search limit');
        end

        function outlinesCanBeReturned(tc)
            um = 1.657;
            [img, xy] = tAnalysisMeasure.scene(um, "ring");
            [T, info] = cellanalysis.Measure.cells(img, xy, um, "pnn", struct('Masks', true));
            n = numel(info.AxisUm);
            tc.verifySize(info.Foot, [n n size(xy, 1)]);
            tc.verifyEqual(squeeze(sum(sum(info.Foot, 1), 2)) * info.StepUm^2, T.AreaUm2, 'RelTol', 1e-9, 'the footprint is the area');
            tc.verifyEqual(squeeze(sum(sum(info.Wall, 1), 2)) * info.StepUm^2, T.WallAreaUm2, 'RelTol', 1e-9);
            tc.verifyTrue(all(info.Wall(:) <= info.Foot(:)), 'the wall lies inside the footprint');
            mid = (n + 1) / 2;
            tc.verifyFalse(any(info.Wall(mid, mid, :)), 'the center of a net is not wall');
            tc.verifyTrue(all(info.Foot(mid, mid, :)), 'but it is inside the footprint');
        end

        function shapeFormulasAgreeWithGeometry(tc)
            [X, Y] = meshgrid(-60:60, -60:60);
            disk = hypot(X, Y) <= 30;
            tc.verifyEqual(cellanalysis.Measure.crofton(disk), 2 * pi * 30, 'RelTol', 0.02, 'perimeter of a disk');
            sh = cellanalysis.Measure.shapeOf(disk);
            tc.verifyEqual(sh.area, pi * 30^2, 'RelTol', 0.01);
            tc.verifyEqual([sh.major sh.minor], [60 60], 'RelTol', 0.02);
            tc.verifyEqual(sh.hullArea, sh.area, 'RelTol', 0.005, 'a disk is its own hull');
            tc.verifyEqual(sh.wallArea / sh.hullArea, 1, 'AbsTol', 0.005, 'so its solidity is 1');
            t = 25;                                               % an ellipse 80 x 40, turned 25 degrees (y up)
            u = cosd(t) * X - sind(t) * Y;
            v = sind(t) * X + cosd(t) * Y;
            ell = (u / 40) .^ 2 + (v / 20) .^ 2 <= 1;
            sh = cellanalysis.Measure.shapeOf(ell);
            tc.verifyEqual([sh.major sh.minor], [80 40], 'RelTol', 0.02);
            tc.verifyEqual(sh.orientation, 25, 'AbsTol', 1);
            % Ramanujan's perimeter of the ellipse
            a = 40; b = 20;
            tc.verifyEqual(sh.perimeter, pi * (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b))), 'RelTol', 0.03);
            sq = abs(X) <= 20 & abs(Y) <= 10;
            sh = cellanalysis.Measure.shapeOf(sq);
            tc.verifyEqual(sh.hullArea, 41 * 21, 'RelTol', 1e-9, 'the hull of a rectangle of pixels is the rectangle');
            ring = hypot(X, Y) <= 30 & hypot(X, Y) >= 24;
            sh = cellanalysis.Measure.shapeOf(disk, ring, true);
            tc.verifyEqual(sh.wallArea / sh.hullArea, 1 - (24 / 30)^2, 'AbsTol', 0.03, 'solidity of a ring');
            tc.verifyEqual(sh.perimeter, 2 * pi * 30, 'RelTol', 0.03, 'a net''s perimeter is its hull''s');
            e = cellanalysis.Measure.shapeOf(false(5));
            tc.verifyEqual(e.area, 0);
            tc.verifyTrue(isnan(e.major));
        end

        function neighborhood(tc)
            um = 2;
            xy = [10 10; 20 10; 10 40; 300 300; NaN 5];           % pixels
            other = [11 10; 200 200];
            T = cellanalysis.Measure.spatial(xy, um, other);
            tc.verifyEqual(T.NnUm, [20; 20; 60; 2 * hypot(290, 260); NaN], 'RelTol', 1e-9);
            tc.verifyEqual(T.OtherDistUm(1:2), [2; 18], 'RelTol', 1e-9);
            tc.verifyTrue(isnan(T.OtherDistUm(5)));
            per = 1e6 / (pi * 100^2);
            tc.verifyEqual(T.LocalDensity, [3; 3; 3; 1; NaN] * per, 'RelTol', 1e-9, 'cells within 100 um, itself included');
            N = cellanalysis.Measure.spatial(xy, um);
            tc.verifyTrue(all(isnan(N.OtherDistUm)), 'no other channel');
            one = cellanalysis.Measure.spatial([5 5], um, zeros(0, 2));
            tc.verifyTrue(isnan(one.NnUm), 'a single cell has no neighbor');
        end

        function channelsArePairedOneToOne(tc)
            um = 2;                                               % so 5 px = 10 um
            nets = [10 10; 20 10; 100 100; 200 200; NaN 1];
            pv = [11 10; 103 104; 300 300];                       % 2 um from net 1 (18 from net 2), 10 um from net 3
            R = cellanalysis.Measure.colocalize(nets, pv, um);
            tc.verifyEqual(R.Colocalized, [true; false; true; false; false]);
            tc.verifyEqual(R.Partner, [1; 0; 2; 0; 0]);
            tc.verifyEqual(R.DistUm, [2; NaN; 10; NaN; NaN], 'AbsTol', 1e-9);
            tc.verifyEqual(R.OtherColocalized, [true; true; false]);
            tc.verifyEqual(nnz(R.Colocalized), nnz(R.OtherColocalized), 'as many pairs seen from either channel');
            % a PV cell is the partner of one net only: the closer one
            R2 = cellanalysis.Measure.colocalize([10 10; 13 10], [12 10], um);
            tc.verifyEqual(R2.Colocalized, [false; true]);
            tc.verifyEqual(R2.DistUm(2), 2, 'AbsTol', 1e-9);
            wide = cellanalysis.Measure.colocalize(nets, pv, um, struct('MaxUm', 30));
            tc.verifyEqual(wide.Partner(1:2), [1; 0], 'still one partner each: net 2 does not take net 1''s cell');
            none = cellanalysis.Measure.colocalize(nets, zeros(0, 2), um);
            tc.verifyFalse(any(none.Colocalized));
            tc.verifyTrue(all(isnan(none.Chance)), 'no other channel: no chance level either');
            tc.verifyError(@() cellanalysis.Measure.colocalize(nets, pv, um, struct('Nope', 1)), 'cellanalysis:Measure:badOption');
        end

        function theChanceLevelFollowsTheDensity(tc)
            um = 1;
            s = RandStream('mt19937ar', 'Seed', 11);
            L = 3000;
            nets = L * rand(s, 1500, 2);
            lambda = 400 / L^2;                                   % PV cells per um^2
            pv = L * rand(s, 400, 2);
            R = cellanalysis.Measure.colocalize(nets, pv, um, struct('MaxUm', 20));
            % independent channels: observed = chance, and both near the Poisson expectation
            expect = 1 - exp(-lambda * pi * 20^2);
            tc.verifyEqual(mean(R.Chance), expect, 'AbsTol', 0.02);
            tc.verifyEqual(mean(R.Colocalized), mean(R.Chance), 'AbsTol', 0.02);
            tc.verifyEqual(R.ShiftUm, 100, 'displaced by 5 x the distance');
            % every PV cell sits inside a net: all are paired, far above chance
            pv2 = nets(1:400, :) + 2 * randn(s, 400, 2);
            T = cellanalysis.Measure.colocalize(nets, pv2, um, struct('MaxUm', 10));
            tc.verifyGreaterThan(mean(T.OtherColocalized), 0.97);
            tc.verifyEqual(mean(T.Colocalized), 400 / 1500, 'AbsTol', 0.01);
            tc.verifyLessThan(mean(T.Chance), 0.03);
            tc.verifyEqual(T.ShiftUm, 50);
        end

        function theCatalogNamesWhatIsMeasured(tc)
            C = cellanalysis.Measure.catalog();
            tc.verifyEqual(numel(unique(C.Name)), height(C), 'every metric has its own name');
            tc.verifyEqual(numel(unique(C.Label)), height(C), 'and its own label');
            tc.verifyTrue(all(strlength(C.Meaning) > 20), 'and says what it is');
            tc.verifyTrue(all(ismember(C.Kinds, ["both" "pnn"])));
            tc.verifyTrue(all(ismember(C.Source, ["image" "position"])));
            [img, xy] = tAnalysisMeasure.scene(1.657, "ring");
            T = cellanalysis.Measure.cells(img, xy, 1.657, "pnn");
            tc.verifyEqual(string(T.Properties.VariableNames), [C.Name(C.Source == "image")', "Segmented", "TouchesEdge"]);
            P = cellanalysis.Measure.cells(img, xy, 1.657, "pv");
            for nm = C.Name(C.Kinds == "pnn")'
                tc.verifyTrue(all(isnan(P.(nm))), nm + " is a net measure");
            end
        end

        function badInputIsRefused(tc)
            img = ones(50, 'single');
            tc.verifyError(@() cellanalysis.Measure.cells(img, [10 10], -1, "pv"), 'cellanalysis:Measure:badScale');
            tc.verifyError(@() cellanalysis.Measure.cells(ones(2), [1 1], 1, "pv"), 'cellanalysis:Measure:badPage');
            tc.verifyError(@() cellanalysis.Measure.cells(img, [10 10], 1, "pv", struct('Other', ones(3))), 'cellanalysis:Measure:badPage');
            tc.verifyError(@() cellanalysis.Measure.cells(img, [10 10], 1, "pv", struct('Nope', 1)), 'cellanalysis:Measure:badOption');
        end
    end
end
