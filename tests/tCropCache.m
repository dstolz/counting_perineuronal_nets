classdef tCropCache < matlab.unittest.TestCase
    %tCropCache  curation.CropCache: extraction (orientation, sub-pixel, edges, contrast), cache edits,
    %   page composition in every mode and its pixel-exact decorations, repaint == compose.
    %   Uses its own small synthetic pages (no fixture files).

    methods (Static)
        function page = blobPage(H, W, xy, sigma, amp, background)
            %blobPage  H x W double page: BACKGROUND plus Gaussian blobs of SIGMA px and height AMP at XY
            %   ([X Y]: X the column, Y the row).
            if nargin < 6; background = 0; end
            [X, Y] = meshgrid(1:W, 1:H);
            page = background + zeros(H, W);
            for i = 1:size(xy, 1)
                page = page + amp * exp(-((X - xy(i, 1)).^2 + (Y - xy(i, 2)).^2) / (2 * sigma^2));
            end
        end

        function c = centroid(tile)
            %centroid  [col row] intensity-weighted centroid of the pixels above half the tile's maximum.
            t = double(tile);
            t(t < max(t(:)) / 2) = 0;
            [R, C] = ndgrid(1:size(t, 1), 1:size(t, 2));
            c = [sum(C(:) .* t(:)) sum(R(:) .* t(:))] / sum(t(:));
        end
    end

    methods (Test)
        function testOrientationXIsColumnYIsRow(tc)
            % a blob at (X, Y) is centered in the tile of a cell at (X, Y); one at +X is to the right,
            % one at +Y is below
            blob = [180.3 70.6];
            page = tCropCache.blobPage(200, 300, blob, 2, 1000);
            ids = [5; 6; 7];
            xy = [blob; blob - [8 0]; blob - [0 6]];
            c = curation.CropCache.build(page, [], ids, xy, 1, WindowUm = 40, TilePx = 80, Percentiles = [0 100]);
            tc.verifyEqual(c.TilePx, 80);
            tc.verifyEqual(c.WindowPx, 40);
            mid = (80 + 1) / 2;
            k = 80 / 40;    % tile px per page px
            tc.verifyEqual(tCropCache.centroid(c.Crops(:, :, c.rowsOf(5))), [mid mid], 'AbsTol', 0.5);
            tc.verifyEqual(tCropCache.centroid(c.Crops(:, :, c.rowsOf(6))), [mid + 8 * k, mid], 'AbsTol', 0.5, ...
                'a blob 8 px right of the cell (+X) must appear right of the tile center');
            tc.verifyEqual(tCropCache.centroid(c.Crops(:, :, c.rowsOf(7))), [mid, mid + 6 * k], 'AbsTol', 0.5, ...
                'a blob 6 px below the cell (+Y) must appear below the tile center');
            % the tile's brightest pixel is at the blob
            [~, i] = max(double(c.Crops(:, :, c.rowsOf(5))), [], 'all', 'linear');
            [r, cc] = ind2sub([80 80], i);
            tc.verifyLessThanOrEqual(abs([cc r] - mid), [1 1]);
        end

        function testSubPixelPosition(tc)
            % moving the cell by half a page pixel moves the blob by half a page pixel in the tile
            blob = [100.25 90.5];
            page = tCropCache.blobPage(200, 200, blob, 2.5, 1000);
            c = curation.CropCache.build(page, [], [1; 2], [blob; blob + [0.5 0]], 1, WindowUm = 40, ...
                TilePx = 80, Percentiles = [0 100]);
            c1 = tCropCache.centroid(c.Crops(:, :, 1));
            c2 = tCropCache.centroid(c.Crops(:, :, 2));
            tc.verifyEqual(c1(1) - c2(1), 0.5 * 80 / 40, 'AbsTol', 0.15);
            tc.verifyEqual(c1(2) - c2(2), 0, 'AbsTol', 0.15);
        end

        function testEdgePaddingAndTouchesBorder(tc)
            H = 120; W = 160;
            page = tCropCache.blobPage(H, W, [3 4], 2, 900, 100);
            page(110, 10) = 0;                      % the page minimum (away from the cells): low limit 0
            xy = [3 4; 80 60; W - 1, H - 2];
            c = curation.CropCache.build(page, [], [1; 2; 3], xy, 1, WindowUm = 40, TilePx = 80, Percentiles = [0 100]);
            tc.verifyEqual(c.TouchesBorder, [true; false; true]);
            t = c.Crops(:, :, 1);
            tc.verifySize(t, [80 80]);
            % sample j lies at X = 3 + (j - 40.5) * 0.5: outside the page (X < 0.5) for j <= 35;
            % rows: Y = 4 + (i - 40.5) * 0.5 < 0.5 for i <= 33
            tc.verifyTrue(all(t(:, 1:35) == 0, 'all'), 'columns outside the page must be padded with 0');
            tc.verifyTrue(all(t(1:33, :) == 0, 'all'), 'rows outside the page must be padded with 0');
            tc.verifyTrue(all(t(34:end, 36:end) > 0, 'all'), 'the part on the page must be drawn');
            tc.verifyEqual(tCropCache.centroid(t), [40.5 40.5], 'AbsTol', 0.6, 'the border cell stays centered');
            % the far corner: columns/rows past the page are 0
            t3 = c.Crops(:, :, 3);
            tc.verifyTrue(all(t3(:, end) == 0) && all(t3(end, :) == 0));
            tc.verifyFalse(any(c.Crops(:, :, 2) == 0, 'all'), 'an interior cell has no padding');
        end

        function testUpdateAfterMove(tc)
            blob = [150 80];
            page = tCropCache.blobPage(160, 240, blob, 2, 1000);
            c = curation.CropCache.build(page, [], [1; 2; 3], [40 40; 200 130; 60 120], 1, WindowUm = 40, ...
                TilePx = 64, Percentiles = [0 100]);
            before = c.Crops;
            v0 = c.Version;
            tc.verifyLessThan(max(c.Crops(:, :, 2), [], 'all'), 10, 'no blob near the old position');
            c.update(2, blob);
            tc.verifyEqual(c.Version, v0 + 1);
            tc.verifyEqual(c.XY(2, :), blob);
            tc.verifyEqual(c.Crops(:, :, [1 3]), before(:, :, [1 3]), 'other cells are untouched');
            tc.verifyEqual(tCropCache.centroid(c.Crops(:, :, 2)), [32.5 32.5], 'AbsTol', 0.5);
            fresh = curation.CropCache.build(page, [], 2, blob, 1, WindowUm = 40, TilePx = 64, Percentiles = [0 100]);
            tc.verifyEqual(c.Crops(:, :, 2), fresh.Crops(:, :, 1), 'update equals a fresh extraction');
            tc.verifyError(@() c.update(99, [10 10]), 'CropCache:UnknownId');
        end

        function testAddRemoveAndRowsOf(tc)
            page = tCropCache.blobPage(150, 150, [50 50; 100 100], 2, 1000);
            c = curation.CropCache.build(page, [], [3; 8; 1], [50 50; 100 100; 75 75], 1, WindowUm = 40, TilePx = 48);
            tc.verifyEqual(c.N, 3);
            tc.verifyEqual(c.rowsOf([1 3 8 4 0]), [3 1 2 0 0]);
            tileOf8 = c.Crops(:, :, c.rowsOf(8));
            c.add([20; 21], [100 100; 10 140]);
            tc.verifyEqual(c.N, 5);
            tc.verifyEqual(c.rowsOf([20; 21]), [4; 5]);
            tc.verifyEqual(c.Crops(:, :, 4), tileOf8, 'the same position gives the same crop');
            tc.verifyEqual(c.TouchesBorder(5), true);
            tc.verifyError(@() c.add(8, [1 1]), 'CropCache:DuplicateIds');
            c.remove([3 999]);
            tc.verifyEqual(c.N, 4);
            tc.verifyEqual(c.rowsOf(3), 0);
            tc.verifyEqual(c.Ids, uint32([8; 1; 20; 21]));
            tc.verifyEqual(c.Crops(:, :, c.rowsOf(8)), tileOf8);
            tc.verifyEqual(size(c.XY), [4 2]);
            tc.verifyEqual(numel(c.TouchesBorder), 4);
        end

        function testCompanionChannelAndOverlay(tc)
            pT = tCropCache.blobPage(120, 120, [60 60], 2, 1000);
            pC = tCropCache.blobPage(120, 120, [66 60], 3, 50);   % other scale, shifted +6 px in X
            c = curation.CropCache.build(pT, pC, [1; 2], [60 60; 30 90], 1, WindowUm = 40, TilePx = 40, ...
                Percentiles = [0 100]);
            tc.verifyTrue(c.HasCompanion);
            tc.verifyEqual(size(c.CropsC), [40 40 2]);
            tc.verifyTrue(all(isfinite(c.Limits(:))));
            tc.verifyEqual(c.Limits(2, 2), max(pC(:)), 'RelTol', 1e-12);
            cC = tCropCache.centroid(c.CropsC(:, :, 1));
            tc.verifyEqual(cC, [20.5 + 6, 20.5], 'AbsTol', 0.6, 'companion crop at the same window');

            mT = c.compose([1 2], 1, 2, struct('Mode', 'target', 'BorderPx', 0));
            mC = c.compose([1 2], 1, 2, struct('Mode', 'companion', 'BorderPx', 0));
            [mO, L] = c.compose([1 2], 1, 2, struct('Mode', 'overlay', 'BorderPx', 0));
            tc.verifyEqual(mT(:, :, 1), [c.Crops(:, :, 1) c.Crops(:, :, 2)]);
            tc.verifyEqual(mC(:, :, 1), [c.CropsC(:, :, 1) c.CropsC(:, :, 2)]);
            tc.verifyEqual(mO(:, :, 2), mT(:, :, 1), 'overlay: target in green');
            tc.verifyEqual(mO(:, :, 1), mC(:, :, 1), 'overlay: companion in red ...');
            tc.verifyEqual(mO(:, :, 3), mC(:, :, 1), '... and blue (magenta)');
            tc.verifyEqual(L.Mode, "overlay");
        end

        function testModeOutputSizesAndTypes(tc)
            page = tCropCache.blobPage(100, 100, [50 50], 2, 100);
            c = curation.CropCache.build(page, page * 2, (1:5)', repmat([50 50], 5, 1), 1, TilePx = 20, WindowUm = 30);
            for mode = ["target" "companion" "overlay" "side"]
                [m, L] = c.compose(1:5, 2, 3, struct('Mode', mode));
                w = 20 * (1 + (mode == "side"));
                tc.verifyClass(m, 'uint8');
                tc.verifySize(m, [2 * 20, 3 * w, 3], char(mode));
                tc.verifyEqual(L.Size, [40 3 * w]);
                tc.verifyEqual([L.TileH L.TileW L.K L.S], [20 w 5 6]);
                tc.verifyEqual(L.Rect(6, :), [2 * w + 1, 21, w, 20]);
            end
            % side: target | companion halves
            [m, ~] = c.compose(1, 1, 1, struct('Mode', 'side', 'BorderPx', 0));
            tc.verifyEqual(m(:, 1:20, 1), c.Crops(:, :, 1));
            tc.verifyEqual(m(:, 21:40, 1), c.CropsC(:, :, 1));
            % gaps and empty slots are background
            bg = uint8([10 20 30]);
            [m, L] = c.compose([1 2 999], 2, 2, struct('Gap', 2, 'Background', bg, 'BorderPx', 0));
            tc.verifySize(m, [2 * 20 + 2, 2 * 20 + 2, 3]);
            tc.verifyEqual(squeeze(m(21, 5, :))', bg, 'gap row');
            tc.verifyEqual(squeeze(m(5, 21, :))', bg, 'gap column');
            r3 = L.Rect(3, :);
            tc.verifyTrue(all(m(r3(2):r3(2) + 19, r3(1):r3(1) + 19, :) == reshape(bg, 1, 1, 3), 'all'), 'unknown id');
            r4 = L.Rect(4, :);
            tc.verifyTrue(all(m(r4(2):r4(2) + 19, r4(1):r4(1) + 19, :) == reshape(bg, 1, 1, 3), 'all'), 'empty slot');
            tc.verifyEqual(m(1:20, 1:20, 2), c.Crops(:, :, 1));
            tc.verifyError(@() c.compose(1:5, 1, 2), 'CropCache:TooManyTiles');
            tc.verifyError(@() c.compose(1, 1, 1, struct('Mode', 'nope')), 'CropCache:BadStyle');
        end

        function testDecorationsTouchOnlyTheirPixels(tc)
            page = tCropCache.blobPage(100, 100, [50 50], 3, 100, 20);
            c = curation.CropCache.build(page, [], (1:6)', repmat([50 50], 6, 1) + (0:5)' * [1 0], 1, TilePx = 24, WindowUm = 30);
            base = struct('BorderPx', 3, 'CornerPx', 5);
            [m0, L] = c.compose(1:6, 2, 3, base);   % no colors: plain tiles
            HW = L.Size(1) * L.Size(2);

            s = base;
            s.BorderRGB = NaN(6, 3);
            s.BorderRGB(2, :) = [255 0 128];
            m1 = c.compose(1:6, 2, 3, s);
            changed = any(m1 ~= m0, 3);
            expect = false(L.Size);
            r = L.Rect(2, :);
            expect(r(2):r(2) + 23, r(1):r(1) + 23) = true;
            expect(r(2) + 3:r(2) + 20, r(1) + 3:r(1) + 20) = false;      % frame of width 3
            tc.verifyEqual(changed | expect, expect, 'border paints only the frame of its tile');
            frame = find(expect);
            tc.verifyEqual(double([m1(frame) m1(frame + HW) m1(frame + 2 * HW)]), repmat([255 0 128], numel(frame), 1));

            s = base;
            s.CornerRGB = NaN(6, 3);
            s.CornerRGB(3, :) = [0 200 0];
            m2 = c.compose(1:6, 2, 3, s);
            changed = any(m2 ~= m0, 3);
            expect = false(L.Size);
            r = L.Rect(3, :);
            expect(r(2) + 3:r(2) + 7, r(1) + 24 - 3 - 5:r(1) + 24 - 3 - 1) = true;   % 5 x 5, top right, inside the border
            tc.verifyEqual(changed | expect, expect, 'the corner badge stays in its square');
            tc.verifyTrue(all(m2(:, :, 2) == 200 | ~expect, 'all'));

            s = base;
            s.Dim = false(6, 1);
            s.Dim(4) = true;
            m3 = c.compose(1:6, 2, 3, s);
            changed = any(m3 ~= m0, 3);
            r = L.Rect(4, :);
            inTile = false(L.Size);
            inTile(r(2):r(2) + 23, r(1):r(1) + 23) = true;
            tc.verifyEqual(changed | inTile, inTile, 'dimming stays inside its tile');
            blk0 = double(m0(r(2):r(2) + 23, r(1):r(1) + 23, :));
            blk3 = double(m3(r(2):r(2) + 23, r(1):r(1) + 23, :));
            tc.verifyEqual(blk3, round(blk0 * 0.4), 'AbsTol', 0.5 + 1e-9);
        end

        function testRepaintEqualsCompose(tc)
            rng(7);
            page = tCropCache.blobPage(200, 200, rand(12, 2) * 180 + 10, 2.5, 100, 10) + rand(200, 200);
            pageC = flipud(page) * 3;
            ids = (1:12)';
            c = curation.CropCache.build(page, pageC, ids, rand(12, 2) * 200, 1, TilePx = 32, WindowUm = 40);
            for mode = ["target" "overlay" "side" "companion"]
                K = 11;                                     % 11 tiles in 12 slots
                s1 = struct('Mode', mode, 'BorderRGB', repmat([90 90 90], K, 1), 'CornerRGB', NaN(K, 3), ...
                    'Dim', false(K, 1), 'Gain', 1.3);
                [m1, L] = c.compose(ids(1:K), 3, 4, s1);
                s2 = s1;
                s2.BorderRGB([1 5 9], :) = [0 158 115; 213 94 0; 240 228 66];
                s2.CornerRGB(5, :) = [255 255 255];
                s2.Dim(9) = true;
                fresh = c.compose(ids(1:K), 3, 4, s2);
                rep = c.repaint(m1, L, [1 5 9 12], s2);   % 12 is an empty slot
                tc.verifyEqual(rep, fresh, sprintf('repaint == compose (%s, few tiles)', mode));
                rep = c.repaint(m1, L, 1:12, s2);         % the whole page: the compose path
                tc.verifyEqual(rep, fresh, sprintf('repaint == compose (%s, all tiles)', mode));
            end
            tc.verifyError(@() c.repaint(m1, L, 1, struct('Mode', 'target', 'Gap', 1)), 'CropCache:LayoutChanged');
        end

        function testContrastIndependentOfPageScale(tc)
            rng(3);
            H = 150; W = 170;
            xy = rand(25, 2) .* [W H];
            page = tCropCache.blobPage(H, W, xy, 2, 50, 5) + rand(H, W);
            pageC = tCropCache.blobPage(H, W, xy + 3, 3, 20, 1) + rand(H, W);
            ids = (1:25)';
            a = curation.CropCache.build(page, pageC, ids, xy, 1.657);
            b = curation.CropCache.build(page * 1000, pageC * 1000, ids, xy, 1.657);
            tc.verifyEqual(b.Crops, a.Crops, 'x1000 page (double): identical target tiles');
            tc.verifyEqual(b.CropsC, a.CropsC, 'x1000 page (double): identical companion tiles');
            tc.verifyEqual(b.Limits, a.Limits * 1000, 'RelTol', 1e-12, 'the limits keep the page units');
            % single pages: scaling is itself rounded in single precision, so allow one gray level
            as = curation.CropCache.build(single(page), [], ids, xy, 1.657);
            bs = curation.CropCache.build(single(page) * 1000, [], ids, xy, 1.657);
            d = abs(double(as.Crops) - double(bs.Crops));
            tc.verifyLessThanOrEqual(max(d(:)), 1);
            tc.verifyGreaterThan(mean(d(:) == 0), 0.999);
            % percentile contrast is per page, not per tile: a faint cell stays faint
            tc.verifyFalse(a.PerTileContrast);
        end

        function testPageLimitsMatchPrctile(tc)
            tc.assumeTrue(exist('prctile', 'file') > 0, 'prctile (Statistics Toolbox) is not installed');
            rng(5);
            page = exp(randn(300, 400));
            lim = curation.CropCache.pageLimits(page, [1 99.9], 1e6);
            tc.verifyEqual(lim(:), reshape(prctile(page(:), [1 99.9]), [], 1), 'RelTol', 1e-12);
            lim2 = curation.CropCache.pageLimits(page, [0 100], 1e6);
            tc.verifyEqual(lim2, [min(page(:)) max(page(:))]);
            lim3 = curation.CropCache.pageLimits(single(page), [1 99.9], 2e4);   % subsampled
            tc.verifyEqual(lim3, lim, 'RelTol', 0.3);
            tc.verifyEqual(curation.CropCache.pageLimits(ones(10), [1 99]), [1 2], 'flat page');
        end

        function testGainGammaAndLut(tc)
            page = repmat(linspace(0, 1, 64), 64, 1);
            c = curation.CropCache.build(page, [], 1, [32.5 32.5], 1, TilePx = 64, WindowUm = 64, Percentiles = [0 100]);
            base = struct('BorderPx', 0);
            m = c.compose(1, 1, 1, base);
            s = base; s.Gain = 2;
            g = c.compose(1, 1, 1, s);
            tc.verifyEqual(double(g), min(255, round(double(m) * 2)), 'AbsTol', 1);
            s = base; s.LUT = uint8(0:255)';
            tc.verifyEqual(c.compose(1, 1, 1, s), m, 'the identity LUT changes nothing');
            s = base; s.LUT = uint8(255:-1:0)';
            tc.verifyEqual(c.compose(1, 1, 1, s), 255 - m, 'a LUT is applied');
            s = base; s.Gamma = 0.5;
            gm = c.compose(1, 1, 1, s);
            tc.verifyTrue(all(gm >= m, 'all'), 'Gamma < 1 brightens');
        end

        function testPerTileContrastOption(tc)
            page = tCropCache.blobPage(100, 200, [50 50; 150 50], 2, 1, 0);
            page(:, 101:200) = page(:, 101:200) * 0.05;     % a faint cell on the right
            c = curation.CropCache.build(page, [], [1; 2], [50 50; 150 50], 1, TilePx = 40, WindowUm = 40, ...
                Percentiles = [0 100]);
            tc.verifyLessThan(max(c.Crops(:, :, 2), [], 'all'), 20, 'page contrast: the faint cell stays faint');
            p = curation.CropCache.build(page, [], [1; 2], [50 50; 150 50], 1, TilePx = 40, WindowUm = 40, ...
                Percentiles = [0 100], PerTileContrast = true);
            tc.verifyGreaterThan(max(p.Crops(:, :, 2), [], 'all'), 240, 'per-tile contrast stretches it');
        end
    end
end
