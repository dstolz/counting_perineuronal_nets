classdef tFeatures < matlab.unittest.TestCase
    %TFEATURES  curation.Features: intensity-scale invariance, ring vs blob separation, exact
    %   border / neighbor distances, companion handling, no NaN for interior points, names.
    %   The Benchmark test times 2,800 candidates on 3277 x 2355 pages (budget 1.5 s).
    %   Run: pwsh -File tools\Run-Tests.ps1 tFeatures [-IncludeSlow for the benchmark]

    properties
        Folder
        Truth
        PageE      % ECM page (rings)
        PageP      % PV page (blobs)
    end

    methods (TestClassSetup)
        function makeData(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [tc.Folder, tc.Truth] = makeSyntheticDataset(fullfile(fx.Folder, 'ds'), 'Variants', false, 'Seed', 7);
            tif = tc.Truth.paths.tif;
            tc.PageE = imread(tif, 1);
            tc.PageP = imread(tif, 2);
        end
    end

    methods (Static)
        function img = render(H, W, xy, kinds, upp, seed)
            % Background 100 + noise 2, rings (net, peak radius 6.7 um) or blobs (FWHM 15 um).
            rs = RandStream('mt19937ar', 'Seed', seed);
            img = 100 + 2 * randn(rs, H, W);
            [XX, YY] = meshgrid(1:W, 1:H);
            for k = 1:size(xy, 1)
                d = hypot(XX - xy(k, 1), YY - xy(k, 2)) * upp;     % um
                if kinds(k) == "ring"
                    img = img + 60 * exp(-(d - 6.7) .^ 2 / (2 * 2 ^ 2));
                else
                    img = img + 60 * exp(-d .^ 2 / (2 * 6.4 ^ 2));
                end
            end
        end
    end

    methods (Test)
        function namesMatchColumns(tc)
            T = tc.Truth.ECM1.locs;
            [F, names] = curation.Features.compute(tc.PageE, tc.PageP, T, tc.Truth.umPerPixel);
            tc.verifySize(F, [height(T), numel(names)]);
            tc.verifyEqual(names, curation.Features.names());
            tc.verifyEqual(numel(unique(names)), numel(names), 'names must be unique');
            D = curation.Features.describe();
            tc.verifyEqual(D.Name', names, 'describe() covers every column in order');
            tc.verifyEqual(F(:, names == "score"), T.score);
            tc.verifyEqual(F(:, names == "rescore"), T.rescore);
        end

        function affineIntensityInvariance(tc)
            % 1000 * page + offset (and another gain/offset for the companion) leaves F unchanged.
            T = tc.Truth.ECM1.locs;
            upp = tc.Truth.umPerPixel;
            pE = double(tc.PageE);
            pP = double(tc.PageP);
            F1 = curation.Features.compute(pE, pP, T, upp);
            F2 = curation.Features.compute(1000 * pE + 12345, 0.001 * pP - 7, T, upp);
            tc.verifyEqual(F2, F1, 'AbsTol', 1e-9, 'RelTol', 1e-9);
            % float32 rescaling: equal up to float32 rounding (pixel counts of the blob area can
            % flip at the threshold, so those two columns are left out of this looser check)
            F3 = curation.Features.compute(single(pE / 3000), single(pP * 1e4 + 5), T, upp);
            names = curation.Features.names();
            img = setdiff(5:24, find(ismember(names, ["blobAreaUm2", "blobCompactness"])));
            tc.verifyEqual(F3(:, img), F1(:, img), 'AbsTol', 1e-3, 'RelTol', 1e-3);
        end

        function ringVersusBlob(tc)
            % Hand-placed nets and somata on a clean background: ringRatio separates them.
            upp = 1.657;
            xy = [40 40; 100 40; 160 40; 40 120; 100 120; 160 120];
            kinds = ["ring" "ring" "ring" "blob" "blob" "blob"];
            page = tFeatures.render(170, 210, xy, kinds, upp, 3);
            T = table(xy(:, 1), xy(:, 2), 'VariableNames', {'X', 'Y'});
            [F, names] = curation.Features.compute(page, [], T, upp);
            rr = F(:, names == "ringRatio");
            ct = F(:, names == "contrast");
            isRing = kinds' == "ring";
            tc.verifyGreaterThan(min(rr(isRing)), 0.5, 'nets: annulus much brighter than the center');
            tc.verifyLessThan(max(rr(~isRing)), 0, 'somata: the center is the brightest');
            tc.verifyLessThan(max(ct(isRing)), 0);
            tc.verifyGreaterThan(min(ct(~isRing)), 0);
            pr = F(:, names == "peakRadiusUm");
            tc.verifyGreaterThan(min(pr(isRing)), 4);
            tc.verifyLessThan(max(pr(~isRing)), 3);
            bc = F(:, names == "blobCompactness");
            tc.verifyGreaterThan(min(bc(~isRing)), max(bc(isRing)), 'solid somata are more compact');

            % the synthetic fixture: true nets (ECM1) vs true somata (PV2)
            fE = curation.Features.compute(tc.PageE, [], tc.Truth.ECM1.locs, upp);
            fP = curation.Features.compute(tc.PageP, [], tc.Truth.PV2.locs, upp);
            tpE = tc.Truth.ECM1.det.Kind == "tp";
            tpP = tc.Truth.PV2.det.Kind == "tp";
            c = names == "ringRatio";
            tc.verifyGreaterThan(median(fE(tpE, c)), 0.5);
            tc.verifyLessThan(median(fP(tpP, c)), 0);
            tc.verifyGreaterThan(mean(fE(tpE, c) > 0.25), 0.9);
            tc.verifyGreaterThan(mean(fP(tpP, c) < 0.25), 0.9);
        end

        function borderAndNeighborDistancesExact(tc)
            H = 100; W = 200; upp = 2;
            page = 100 + zeros(H, W);
            X = [1; 50.5; 100; 103; 180; 60; 60];
            Y = [1; 30; 50; 54; 80; 70; 70];
            T = table(X, Y);
            [F, names] = curation.Features.compute(page, [], T, upp);
            b = F(:, names == "borderUm");
            expB = min([X - 0.5, W + 0.5 - X, Y - 0.5, H + 0.5 - Y], [], 2) * upp;
            tc.verifyEqual(b, expB, 'AbsTol', 1e-12);
            tc.verifyEqual(b(1:2), [1; 59], 'AbsTol', 1e-12);
            nn = F(:, names == "nnUm");
            D = hypot(X - X', Y - Y') * upp;
            D(1:numel(X) + 1:end) = Inf;
            tc.verifyEqual(nn, min(min(D, [], 2), 200), 'AbsTol', 1e-9);
            tc.verifyEqual(nn(3:4), [10; 10], 'AbsTol', 1e-12);     % 3-4-5 triangle, 5 px
            tc.verifyEqual(nn(6:7), [0; 0], 'exact duplicates are 0 apart (a row never counts itself)');
            dens = F(:, names == "densityN");
            tc.verifyEqual(dens, sum(D <= 50, 2));

            % neighbor mask: row 4 does not count as a neighbor, but still gets its own values
            m = true(numel(X), 1); m(4) = false;
            F2 = curation.Features.compute(page, [], T, upp, struct('NeighborMask', m));
            Dm = D; Dm(:, 4) = Inf;
            tc.verifyEqual(F2(:, names == "nnUm"), min(min(Dm, [], 2), 200), 'AbsTol', 1e-9);
            tc.verifyEqual(F2(4, names == "nnUm"), 10, 'AbsTol', 1e-12);
            tc.verifyEqual(F2(:, names == "densityN"), sum(Dm <= 50, 2));
        end

        function companionNaNHandling(tc)
            T = tc.Truth.ECM1.locs;
            upp = tc.Truth.umPerPixel;
            [F0, names] = curation.Features.compute(tc.PageE, [], T, upp);
            comp = ismember(names, ["compContrast", "compCenterZ"]);
            tc.verifyTrue(all(isnan(F0(:, comp)), 'all'), 'no companion -> NaN');
            F1 = curation.Features.compute(tc.PageE, tc.PageP, T, upp);
            interior = F1(:, names == "borderUm") > 25;
            tc.verifyTrue(all(isfinite(F1(interior, comp)), 'all'), 'companion given -> finite inside');
            tc.verifyEqual(F1(:, ~comp), F0(:, ~comp), 'the companion changes only its own columns');
            tc.verifyError(@() curation.Features.compute(tc.PageE, tc.PageP(1:10, :), T, upp), ...
                'curation:Features:badPage');
        end

        function noNaNForInteriorPoints(tc)
            T = tc.Truth.PV2.locs;
            T.rescore(1:5) = NaN;
            upp = tc.Truth.umPerPixel;
            [F, names] = curation.Features.compute(tc.PageP, tc.PageE, T, upp);
            interior = F(:, names == "borderUm") > 25;
            tc.assertGreaterThan(nnz(interior), 100);
            notRescore = ~ismember(names, ["rescore", "rescoreRank"]);
            tc.verifyTrue(all(isfinite(F(interior, notRescore)), 'all'), ...
                'interior points: every image and context feature is finite');
            tc.verifyTrue(all(isnan(F(1:5, names == "rescore"))), 'NaN rescore kept as NaN');
            tc.verifyTrue(all(isnan(F(1:5, names == "rescoreRank"))));
            r = F(6:end, names == "rescoreRank");
            tc.verifyEqual([min(r) max(r)], [0 1], 'ranks span 0..1');
            % a candidate whose whole window is outside the page: NaN image features, no error
            T2 = table([-100; 50], [-100; 50], 'VariableNames', {'X', 'Y'});
            F2 = curation.Features.compute(tc.PageP, [], T2, upp);
            tc.verifyTrue(all(isnan(F2(1, names == "centerZ"))));
            tc.verifyTrue(isfinite(F2(2, names == "centerZ")));
        end
    end

    methods (Test)
        function paddingDoesNotChangeTissueFeatures(tc)
            % Finding 6: a page that is mostly one value (zero padding outside the tissue) made
            % the page median and MAD that value: the noise floor became 1e-6 x range, bgLevel and
            % bgNoise exploded and the profile bins shrank. The page statistics must come from the
            % tissue only, so padding the same tissue changes no feature of a tissue candidate.
            upp = 1.657;
            xy = [40 40; 100 40; 160 40; 40 120; 100 120; 160 120; 70 160; 130 160];
            kinds = ["ring" "ring" "ring" "blob" "blob" "blob" "ring" "blob"];
            tissue = tFeatures.render(200, 200, xy, kinds, upp, 3);
            T = table(xy(:, 1), xy(:, 2), 'VariableNames', {'X', 'Y'});
            names = curation.Features.names();
            cmp = ~ismember(names, "borderUm");          % the page edge moves with the padding
            F0 = curation.Features.compute(tissue, [], T, upp);
            for frac = [0.6 0.85]
                W = ceil(200 / (1 - frac));
                page = zeros(200, W);
                page(:, 1:200) = tissue;                  % tissue left, padding right
                tc.assertGreaterThanOrEqual(nnz(page == 0) / numel(page), frac - 0.01);
                F = curation.Features.compute(page, [], T, upp);
                d = max(abs(F(:, cmp) - F0(:, cmp)), [], 1);
                [worst, j] = max(d);
                cn = names(cmp);
                tc.verifyLessThan(worst, 1e-9, sprintf('%.0f%% padding changed %s by %.3g', ...
                    100 * frac, cn(j), worst));
                % and the same with the padding at another constant after an affine change
                F2 = curation.Features.compute(1000 * page + 12345, [], T, upp);
                tc.verifyEqual(F2(:, cmp), F0(:, cmp), 'AbsTol', 1e-8, 'RelTol', 1e-8);
            end
            s = curation.Features.pageStats(page);
            tc.verifyEqual(s.Median, median(tissue(:)), 'AbsTol', 1e-12, 'page median of the tissue');
            tc.verifyEqual(s.Pad, 0, 'the padding value is recognized');
        end
    end

    methods (Test, TestTags = {'Slow'})
        function realSectionFeaturesAreSane(tc)
            % One real source from the local copy of real sections (never the NAS). Prints the
            % median and range of every feature.
            root = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'real_sections');
            tc.assumeTrue(isfolder(root), sprintf('no local real sections at %s', root));
            d = dir(fullfile(root, '*', '*', '*_proj_ECM1_locs.csv'));
            tc.assumeNotEmpty(d, 'no *_proj_ECM1_locs.csv below the real sections folder');
            locs = fullfile(d(1).folder, d(1).name);
            tif = replace(locs, "_ECM1_locs.csv", ".tif");
            tc.assumeTrue(isfile(tif), 'the projection TIFF is missing');
            pE = imread(tif, 1);
            pP = imread(tif, 2);
            L = readtable(locs);
            upp = CellToolkit.tiffPixelSizeUm(char(tif), 1);
            if ~(isfinite(upp) && upp > 0), upp = 0.645; end
            s = curation.Features.pageStats(pE);
            fprintf('\n[real section] %s: %d x %d px, %.3f um/px, %d candidates; pad value %g (%.1f%% of the page), page median %.4g, noise %.4g, spread %.4g\n', ...
                d(1).name, size(pE, 1), size(pE, 2), upp, height(L), s.Pad, 100 * s.PadFraction, s.Median, s.Noise, s.Spread);
            t0 = tic;
            [F, names] = curation.Features.compute(pE, pP, L, upp);
            fprintf('[real section] features in %.2f s\n', toc(t0));
            interior = F(:, names == "borderUm") > 25;
            fprintf('%-16s %10s %10s %10s %10s %8s\n', 'feature', 'median', 'p1', 'p99', 'max|.|', 'NaN %');
            for j = 1:numel(names)
                v = F(:, j);
                fprintf('%-16s %10.4g %10.4g %10.4g %10.4g %7.1f%%\n', names(j), median(v, 'omitnan'), ...
                    prctile(v, 1), prctile(v, 99), max(abs(v)), 100 * mean(isnan(v)));
            end
            notRescore = ~ismember(names, ["rescore", "rescoreRank", "compContrast", "compCenterZ"]);
            tc.verifyTrue(all(isfinite(F(interior, notRescore)), 'all'), 'interior candidates: finite features');
            % sane scales: page-normalized levels within a few hundred noise units, local noise
            % comparable to the page noise, profile bins of order one spread
            med = median(F(interior, :), 1, 'omitnan');
            tc.verifyLessThan(abs(med(names == "bgLevel")), 50, 'local background near the tissue median');
            tc.verifyGreaterThan(med(names == "bgNoise"), 0.2);
            tc.verifyLessThan(med(names == "bgNoise"), 5, 'local noise comparable to the page noise');
            prof = med(startsWith(names, "prof"));
            tc.verifyLessThan(max(abs(prof)), 2, 'profile bins are of order the page spread');
            tc.verifyGreaterThan(max(abs(prof)), 0.01, 'and not collapsed to zero');
        end
    end

    methods (Test, TestTags = {'Benchmark'})
        function benchmark2800(tc)
            % 2,800 candidates on two 3277 x 2355 float32 pages at 1.657 um/px.
            H = 3277; W = 2355; upp = 1.657; n = 2800;
            rs = RandStream('mt19937ar', 'Seed', 11);
            pT = single(500 + 30 * randn(rs, H, W));
            pC = single(80 + 5 * randn(rs, H, W));
            T = table(20 + (W - 40) * rand(rs, n, 1), 20 + (H - 40) * rand(rs, n, 1), rand(rs, n, 1), ...
                randn(rs, n, 1), 'VariableNames', {'X', 'Y', 'score', 'rescore'});
            curation.Features.compute(pT, pC, T(1:50, :), upp);   % warm up
            t = zeros(1, 3);
            for k = 1:3
                t0 = tic;
                F = curation.Features.compute(pT, pC, T, upp);
                t(k) = toc(t0);
            end
            ms = 1000 * median(t);
            fprintf('\n[benchmark] Features.compute: %d candidates, %dx%d pages + companion: %.0f ms (median of 3; budget 1500 ms)\n', ...
                n, H, W, ms);
            tc.verifySize(F, [n numel(curation.Features.names())]);
            tc.verifyLessThanOrEqual(ms, 1500);
        end
    end
end
