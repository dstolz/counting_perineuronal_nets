classdef (TestTags = {'Slow', 'RealData'}) tRealSection < matlab.unittest.TestCase
    %TREALSECTION  The headless curation pipeline on real sections.
    %   Needs a LOCAL copy of real sections (never the NAS itself) in
    %   %LOCALAPPDATA%\counting_perineuronal_nets\real_sections\<animal>\<section>\ holding
    %   <x>_proj.tif, <x>_proj_ECM1_locs.csv, <x>_proj_PV2_locs.csv and <x>_proj_roi.roi.
    %   Filtered (not failed) when that folder is absent. Every test works on a temporary
    %   copy, so the local master copy stays as it was copied.
    %
    %   Run:  pwsh -File tools\Run-Tests.ps1 -IncludeSlow tRealSection
    %   Mosaics for a person to look at are written to
    %   %LOCALAPPDATA%\counting_perineuronal_nets\test_logs\screens\real_*.png

    properties
        Section      % temporary copy of the first real section
        Stem         % <x>_proj
        ScreenDir
    end

    methods (TestMethodSetup)
        function copySection(tc)
            root = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'real_sections');
            tc.assumeTrue(isfolder(root), 'no local copy of real sections');
            tifs = dir(fullfile(root, '**', '*_proj.tif'));
            tc.assumeNotEmpty(tifs, 'no *_proj.tif under the local copy');
            [~, order] = sort(string({tifs.name}));
            src = tifs(order(1));
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Section = fullfile(fx.Folder, 'section');
            copyfile(src.folder, tc.Section);
            tc.Stem = erase(src.name, '.tif');
            tc.ScreenDir = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', ...
                'test_logs', 'screens');
            if ~isfolder(tc.ScreenDir), mkdir(tc.ScreenDir); end
        end
    end

    methods (Test)
        function storeOpensRealSources(tc)
            for key = ["ECM1", "PV2"]
                locs = fullfile(tc.Section, tc.Stem + "_" + key + "_locs.csv");
                tc.assertTrue(isfile(locs), "missing " + locs);
                before = dir(locs);
                raw = readtable(locs, 'TextType', 'string', 'VariableNamingRule', 'preserve');

                t0 = tic;
                s = curation.Store.openCsv(char(locs), struct('AutosaveDelay', 0));
                tOpen = toc(t0) * 1000;
                tc.addTeardown(@() s.close());
                c = s.counts();
                fprintf('[real] %s: %d locs rows -> %d store rows (%d active); um/px %.4f (%s); first open %.0f ms\n', ...
                    key, height(raw), height(s.T), c.active, s.Meta.UmPerPixel, ...
                    string(s.Meta.UmSource), tOpen);
                if isfield(s.LastReconcile, 'warnings') && ~isempty(s.LastReconcile.warnings)
                    fprintf('[real] %s warnings: %s\n', key, strjoin(string(s.LastReconcile.warnings), ' | '));
                end
                tc.verifyEqual(height(s.T), height(raw), 'one store row per detection');
                tc.verifyEqual(s.Meta.UmPerPixel, 1.657, 'AbsTol', 0.01, ...
                    'scale must come from the TIFF calibration, not the 0.645 default');
                tc.verifyEqual(s.T.X, raw.X, 'AbsTol', 1e-9, 'positions carried over exactly');
                tc.verifyEqual(s.T.rescore, raw.rescore, 'AbsTol', 1e-9);
                tc.verifyEqual(c.reviewed, 0, 'a fresh real source has no reviewed rows');

                s.flush();
                t0 = tic;
                s.close();
                s2 = curation.Store.openCsv(char(locs), struct('AutosaveDelay', 0));
                fprintf('[real] %s: reopen %.0f ms\n', key, toc(t0) * 1000);
                tc.verifyFalse(s2.LastReconcile.Ran, 'an unchanged locs file must not reconcile again');
                s2.close();
                after = dir(locs);
                tc.verifyEqual([after.bytes after.datenum], [before.bytes before.datenum], ...
                    'the detector locs file must never be modified');
            end
        end

        function cropsFeaturesAndPages(tc)
            tif = fullfile(tc.Section, tc.Stem + ".tif");
            info = imfinfo(tif);
            tc.assertGreaterThanOrEqual(numel(info), 2, 'expected a 2-page projection');
            t0 = tic;
            pages = {imread(tif, 1), imread(tif, 2)};
            fprintf('[real] image: %d x %d %s, 2 pages read in %.0f ms; page1 range [%.4g %.4g], page2 [%.4g %.4g]\n', ...
                size(pages{1}, 1), size(pages{1}, 2), class(pages{1}), toc(t0) * 1000, ...
                min(pages{1}(:)), max(pages{1}(:)), min(pages{2}(:)), max(pages{2}(:)));

            keys = ["ECM1", "PV2"];
            for k = 1:2
                key = keys(k);
                locs = fullfile(tc.Section, tc.Stem + "_" + key + "_locs.csv");
                s = curation.Store.openCsv(char(locs), struct('AutosaveDelay', 0));
                tc.addTeardown(@() s.close());
                T = s.T;
                um = s.Meta.UmPerPixel;
                pageT = pages{k};
                pageC = pages{3 - k};

                t0 = tic;
                cache = curation.CropCache.build(pageT, pageC, T.CellID, [T.X T.Y], um);
                tCrop = toc(t0) * 1000;
                t0 = tic;
                [F, names] = curation.Features.compute(pageT, pageC, T, um, struct());
                tFeat = toc(t0) * 1000;
                fprintf('[real] %s: %d cells; crop cache %.0f ms (budget 2000); features %.0f ms (budget 1500); limits %s; %d touch the border\n', ...
                    key, height(T), tCrop, tFeat, mat2str(cache.Limits, 4), nnz(cache.TouchesBorder));
                tc.verifyLessThan(tCrop, 2000);
                tc.verifyLessThan(tFeat, 1500);
                tc.verifyEqual(size(F), [height(T) numel(names)]);
                imgCols = ~ismember(string(names), ["rescore", "rescoreRank", "compContrast", "compCentreZ"]);
                tc.verifyFalse(any(isnan(F(:, imgCols)), 'all'), 'no NaN in image features on real data');

                p = curation.Proposals.current(T, key);
                pages126 = curation.Queues.review(T, p, struct('PageSize', 126));
                sm = curation.Queues.summary(T, p, struct('PageSize', 126));
                bands = string({pages126.Band});
                fprintf('[real] %s: P(Good) quantiles 5/25/50/75/95 = %s; pages of 126: %d (', ...
                    key, mat2str(round(quantile(p, [.05 .25 .5 .75 .95]), 2)), numel(pages126));
                for b = unique(bands, 'stable')
                    fprintf('%s %d pages / %d cells; ', b, nnz(bands == b), ...
                        sum(arrayfun(@(q) numel(q.Ids), pages126(bands == b))));
                end
                fprintf(')\n');
                tc.verifyEqual(sm.reviewRemaining, height(T));
                tc.verifyEqual(numel(unique(vertcat(pages126.Ids))), height(T), ...
                    'every real detection appears on exactly one page');

                % Mosaics for a person to look at: the first page of each band.
                for b = unique(bands, 'stable')
                    pg = pages126(find(bands == b, 1));
                    ids = pg.Ids;
                    nCols = 14; nRows = ceil(numel(ids) / nCols);
                    for mode = ["target", "overlay"]
                        img = cache.compose(ids, nRows, nCols, struct('Mode', char(mode)));
                        imwrite(img, fullfile(tc.ScreenDir, sprintf('real_%s_%s_%s.png', key, b, mode)));
                    end
                end

                cl = curation.Pairs.find(T, um, struct('Subset', "active"));
                d = arrayfun(@(c) c.MinDistUm, cl);
                fprintf('[real] %s: close-pair clusters within 16.6 um among ALL detections: %d (%d nearer than 8.3 um)\n', ...
                    key, numel(cl), nnz(d < 8.3));
            end
        end

        function roiStripImports(tc)
            roi = fullfile(tc.Section, tc.Stem + "_roi.roi");
            tc.assumeTrue(isfile(roi), 'this section has no ROI file');
            r = curation.Regions.importImageJRoi(char(roi));
            xy = r.xy;
            side = sqrt(sum(diff(xy([1:end 1], :)).^2, 2));
            fprintf('[real] ROI: kind %s, %d vertices, sides %s px, area %.3f mm^2\n', ...
                r.kind, size(xy, 1), mat2str(round(side')), ...
                curation.Regions.areaUm2(r, 1.657) / 1e6);
            tc.verifyEqual(r.kind, "reference");
            tc.verifyEqual(size(xy, 1), 4, 'a wide line imports as a 4-corner strip');
            tc.verifyEqual(min(side), 600, 'AbsTol', 1, 'the strip is 600 px wide');
            info = imfinfo(fullfile(tc.Section, tc.Stem + ".tif"));
            centre = mean(xy, 1);
            tc.verifyTrue(centre(1) > 0 && centre(1) < info(1).Width && ...
                centre(2) > 0 && centre(2) < info(1).Height, 'the strip lies on the image');
        end
    end
end
