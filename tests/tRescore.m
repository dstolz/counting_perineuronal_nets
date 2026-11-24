classdef tRescore < matlab.unittest.TestCase
    %TRESCORE  curation.Rescore: which cells need a Stage-2 score (pending), and scoring them with a
    %   shipped scorer on the detector's scale.
    %     pendingRule            on a hand-made in-memory store: added, moved (human / snap beyond
    %                            0.01 px) and merge keepers moved by the merge are pending; untouched
    %                            detections, a "move" to the same place, merged-away rows are not.
    %     runWithAShippedScorer  (Slow, Python) a cell added at a missed true cell and a moved
    %                            detection get finite scores from pv_v2_scoring_ordinal_regression.
    %     detectorScale          (Slow, Python) Rescore's scores of untouched detections equal
    %                            score.py run directly on CellDiscovery's detector input (the
    %                            normalised, resized page as a TIFF, points at X * resize): the
    %                            scale CellDiscovery rescores on. The legacy CellNeighborResolution
    %                            way (the raw full-resolution page through imwrite, points at X) is
    %                            run too and its scores printed: they differ.
    %   Run: pwsh -File tools\Run-Tests.ps1 tRescore [-IncludeSlow]

    properties
        Dir
        Repo
    end

    methods (TestMethodSetup)
        function setup(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = fx.Folder;
            tc.Repo = fileparts(fileparts(mfilename('fullpath')));
        end
    end

    methods (Test)
        function pendingRule(tc)
            n = 8;
            L = table((100:100:800)', (50:50:400)', zeros(n, 1), rand(n, 1), repmat("img", n, 1), ...
                zeros(n, 1), randn(n, 1), 'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
            s = curation.Store.fromTable(L, struct('Key', 'PV2', 'UmPerPixel', 1.657));
            tc.addTeardown(@() s.close());
            T = s.T;
            id = T.CellID;
            tc.verifyEmpty(curation.Rescore.pending(s), 'fresh detections need nothing');
            added = s.addCell([450 333]);
            s.moveCell(id(2), [T.X(2) + 3, T.Y(2)]);                 % human move
            s.moveCell(id(3), [T.X(3), T.Y(3)]);                     % "moved" to where it was
            s.moveCell(id(4), [T.X(4) + 0.005, T.Y(4)], "snap");     % within 0.01 px
            s.moveCell(id(5), [T.X(5) + 2, T.Y(5) + 2], "snap");     % snapped away
            s.mergeCells([id(6) id(7)], id(6), [T.X(6) + 4, T.Y(6)]);  % keeper moved by the merge
            s.setLabel(id(8), "Good", "human");                      % a label is not a position
            got = sort(curation.Rescore.pending(s));
            tc.verifyEqual(got, sort([added; id(2); id(5); id(6)]));
            tc.verifyFalse(any(got == id(7)), 'a merged-away row is never scored');
        end
    end

    methods (Test, TestTags = {'Slow', 'Python'})
        function runWithAShippedScorer(tc)
            [~, tr] = makeSyntheticDataset(fullfile(tc.Dir, 'syn'), 'Variants', false, ...
                'ImageSize', [400 500], 'NumCells', [40 50]);
            s = curation.Store.openCsv(tr.paths.pv2Locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            tc.addTeardown(@() s.close());
            miss = tr.PV2.cellsXY(tr.PV2.missedIdx(1), :);
            added = s.addCell(miss);
            T = s.T;
            moved = T.CellID(find(tr.PV2.det.Kind == "tp", 1));
            s.moveCell(moved, [T.X(moved) + 1.5, T.Y(moved) - 1]);
            ids = curation.Rescore.pending(s);
            tc.verifyEqual(sort(ids), sort([added; moved]));
            done = false;
            job = curation.Rescore.run(s, struct('OnDone', @(~) markDone()));
            tc.addTeardown(@() job.cancel());
            tc.verifyEqual(job.State, "running", 'run() returns while score.py works');
            tc.assertTrue(job.wait(300));
            tc.assertEqual(job.State, "succeeded", strjoin(job.Log, newline));
            tc.verifyTrue(done);
            R = job.Result;
            tc.verifyEqual(sort(R.CellID), sort(double(ids)));
            tc.verifyTrue(all(isfinite(R.Rescore)));
            tc.verifySubstring(char(R.Model(1)), 'pv_v2_scoring_ordinal_regression');
            F = job.Facts{1};
            fprintf('[rescore] %s page %d with %s: facts %s (%s)\n', F.image, F.page, F.model, ...
                F.facts.source, strjoin(F.report.text, '; '));
            fprintf('[rescore] added cell %.3f, moved cell %.3f\n', R.Rescore(R.CellID == added), ...
                R.Rescore(R.CellID == moved));
            tc.verifyEqual(R.Xp, R.X * F.facts.resize, 'AbsTol', 1e-9, 'points on the detector scale');
            tc.verifyFalse(isfolder(job.WorkDir), 'temporary files removed');

            function markDone(), done = true; end
        end

        function detectorScale(tc)
            [~, tr] = makeSyntheticDataset(fullfile(tc.Dir, 'syn'), 'Variants', false, ...
                'ImageSize', [400 500], 'NumCells', [40 50]);
            s = curation.Store.openCsv(tr.paths.pv2Locs, struct('ReadOnly', true, 'ImportLegacy', false));
            tc.addTeardown(@() s.close());
            T = s.T;
            ids = T.CellID(tr.PV2.det.Kind == "tp");
            ids = ids(1:12);
            job = curation.Rescore.run(s, struct('Ids', {{ids}}, 'Wait', true, 'KeepFiles', true));
            tc.addTeardown(@() rmdir(job.WorkDir, 's'));   % KeepFiles: the test removes them
            tc.assertEqual(job.State, "succeeded", strjoin(job.Log, newline));
            F = job.Facts{1};
            model = char(F.model);

            % the same points scored the way CellDiscovery.launchScoring does: its scratch TIFF
            % (the detector input) and X * resize
            tif = fullfile(tc.Dir, 'scratch.tif');
            tc.writeSingleTiff(tif, CellToolkit.modelInputFromFile(F.image, F.page, F.facts));
            rows = s.rowsOf(ids);
            direct = tc.score(model, tif, T.X(rows) * F.facts.resize, T.Y(rows) * F.facts.resize);
            [~, j] = ismember(double(ids), job.Result.CellID);
            mine = job.Result.Rescore(j);
            tc.verifyEqual(mine, direct, 'AbsTol', 1e-5, 'Rescore = CellDiscovery''s rescoring scale');

            % the legacy resolver's way (CellNeighborResolution.rescoreOneFile): the raw page through
            % imwrite to a temporary TIFF, full-resolution points. imwrite refuses float32 data, so
            % on the float32 projections it never produced a score ("could not write temp image")
            raw = imread(F.image, F.page);
            leg = fullfile(tc.Dir, 'legacy.tif');
            tc.verifyError(@() imwrite(raw, leg), 'MATLAB:imagesci:writetif:unsupportedDataType', ...
                'imwrite of a float32 page');
            % a 16-bit page goes through: score it the legacy way
            raw16 = uint16(min(raw * 10, 65535));
            imwrite(raw16, leg);
            back = imread(leg);
            legacy = tc.score(model, leg, T.X(rows), T.Y(rows));
            fprintf(['[scale] imwrite of the float32 page: refused; of a uint16 page: stored as %s (%g..%g)\n' ...
                '[scale] detector scale        : %s\n[scale] legacy resolver (uint16): %s\n' ...
                '[scale] mean |difference| %.3f, correlation %.3f\n'], class(back), min(back(:)), max(back(:)), ...
                mat2str(mine', 3), mat2str(legacy', 3), mean(abs(mine - legacy)), corr(mine, legacy));
            tc.verifyGreaterThan(mean(abs(mine - legacy)), 0.1, 'the legacy scale differs');
        end
    end

    methods
        function v = score(tc, model, img, xp, yp)
            % score.py on one image with points (xp, yp) in its pixel space; returns rescore per point
            [d, nm, ex] = fileparts(img);
            n = numel(xp);
            in = fullfile(tc.Dir, [nm '_in.csv']);
            out = fullfile(tc.Dir, [nm '_out.csv']);
            writetable(table((0:n - 1)', repmat(string([nm ex]), n, 1), xp(:), yp(:), (1:n)', ...
                'VariableNames', {'idx', 'imgName', 'Xp', 'Yp', 'rescore_key'}), in);
            py = curation.Trainer.defaultPython(tc.Repo);
            [st, txt] = CellToolkit.runPython(py, CellToolkit.scoreArgs(model, in, ...
                struct('root', d, 'device', 'cpu', 'output', out)));
            tc.assertEqual(st, 0, txt);
            R = readtable(out);
            v = nan(n, 1);
            v(R.rescore_key) = R.rescore;
        end
    end

    methods (Static)
        function writeSingleTiff(file, img)
            % as CellDiscovery.writeScratchTiff writes the detector input (float32, one page)
            t = Tiff(file, 'w');
            c = onCleanup(@() t.close());
            t.setTag('ImageLength', size(img, 1));
            t.setTag('ImageWidth', size(img, 2));
            t.setTag('Photometric', Tiff.Photometric.MinIsBlack);
            t.setTag('BitsPerSample', 32);
            t.setTag('SamplesPerPixel', 1);
            t.setTag('SampleFormat', Tiff.SampleFormat.IEEEFP);
            t.setTag('PlanarConfiguration', Tiff.PlanarConfiguration.Chunky);
            t.setTag('Compression', Tiff.Compression.None);
            t.write(single(img));
        end
    end
end
