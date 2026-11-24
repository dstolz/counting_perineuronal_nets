classdef tFixture < matlab.unittest.TestCase
%tFixture  Tests of tests\fixtures\makeSyntheticDataset: the files, their formats, the truth, determinism.

    properties (Access = private)
        Dir char
        Truth struct
    end

    properties (Constant, Access = private)
        LocsColumns = ["X" "Y" "class" "score" "imgName" "thr" "rescore"]
        QcColumns = ["QCLabel" "QCCode" "QCReviewed" "QCReviewer" "QCTimestamp" "QCNotes" "QCCropWidth" ...
            "QCCropHeight" "QCDatasetID" "QCChannel" "QCSourceCsv" "QCSourceRow" "QCImagePath" "QCVersion" ...
            "QCUniqueID" "QCOutOfBounds" "QCIncludesImageBorder" "QCWarning"]
    end

    methods (TestClassSetup)
        function buildFixture(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(here, 'fixtures')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [tc.Dir, tc.Truth] = makeSyntheticDataset(fullfile(tmp.Folder, 'ds'));
        end
    end

    methods (Test)
        function filesExist(tc)
            p = tc.Truth.paths;
            for f = string(fieldnames(p))'
                tc.verifyTrue(isfile(p.(f)), "missing " + f + ": " + string(p.(f)));
            end
            tc.verifyEqual(tc.Truth.baseName, 'SYN-0001_sec1');
            tc.verifyTrue(endsWith(p.ecm1Locs, '_proj_ECM1_locs.csv'));
            tc.verifyFalse(endsWith(p.ecm1Redet, '_locs.csv'), 'the redetected file must not look like a locs file');
            tc.verifyFalse(endsWith(p.resolver, '_locs.csv'));
        end

        function tiffFormat(tc)
            info = imfinfo(tc.Truth.paths.tif);
            tc.verifyEqual(numel(info), 2);
            for k = 1:2
                tc.verifyEqual([info(k).Height info(k).Width], [600 800]);
                tc.verifyEqual(info(k).BitsPerSample, 32);
                tc.verifyEqual(info(k).SampleFormat, 'IEEE floating point');
            end
            img = imread(tc.Truth.paths.tif, 2);
            tc.verifyClass(img, 'single');
            tc.verifyGreaterThan(max(img(:)), 1000, 'float32 data scaled well beyond 0-255');
            tc.verifyGreaterThanOrEqual(min(img(:)), 0);
        end

        function pixelSize(tc)
            info = imfinfo(tc.Truth.paths.tif);
            tc.verifyEqual(info(1).ResolutionUnit, 'Centimeter');
            tc.verifyEqual(1e4 / info(1).XResolution, 1.657, 'RelTol', 1e-3);
            tc.verifyEqual(1e4 / info(2).YResolution, 1.657, 'RelTol', 1e-3);
            tc.assumeTrue(exist('CellToolkit', 'class') == 8 && ismethod('CellToolkit', 'tiffPixelSizeUm'), ...
                'CellToolkit.tiffPixelSizeUm is not there');
            tc.verifyEqual(CellToolkit.tiffPixelSizeUm(tc.Truth.paths.tif, 1), 1.657, 'RelTol', 1e-3);
            tc.verifyEqual(CellToolkit.tiffPixelSizeUm(tc.Truth.paths.tif, 2), 1.657, 'RelTol', 1e-3);
        end

        function locsColumns(tc)
            for key = ["ECM1" "PV2"]
                T = tc.readLocs(key);
                tc.verifyEqual(string(T.Properties.VariableNames), tc.LocsColumns);
                tc.verifyTrue(all(T.class == 0) && all(T.thr == 0));
                tc.verifyTrue(all(T.imgName == "SYN-0001_sec1_proj_" + key));
                tc.verifyTrue(all(T.X >= 1 & T.X <= 800 & T.Y >= 1 & T.Y <= 600));
                tc.verifyTrue(all(T.score > 0 & T.score <= 1));
            end
        end

        function truthCountsMatchCsv(tc)
            nCells = struct('ECM1', 120, 'PV2', 180);
            for key = ["ECM1" "PV2"]
                ch = tc.Truth.(char(key));
                T = tc.readLocs(key);
                N = nCells.(char(key));
                tc.verifyEqual(size(ch.cellsXY), [N 2]);
                tc.verifyEqual(height(T), height(ch.det));
                tc.verifyEqual(ch.det.Row, (1:height(T))');
                nMiss = numel(ch.missedIdx);
                tc.verifyEqual(nMiss, round(0.05 * N));
                tc.verifyEqual(nnz(ch.det.Kind == "tp"), N - nMiss);
                tc.verifyEqual(nnz(ch.det.Kind == "fp"), round(0.6 * N));
                tc.verifyGreaterThanOrEqual(nnz(ch.det.Kind == "dup"), 4 + 2);
                % every true cell has at most one tp row, and the missed ones none
                tpIdx = ch.det.TrueIdx(ch.det.Kind == "tp");
                tc.verifyEqual(numel(unique(tpIdx)), numel(tpIdx));
                tc.verifyEmpty(intersect(tpIdx, ch.missedIdx));
                tc.verifyEqual(sort([tpIdx; ch.missedIdx]), (1:N)');

                % true cells at least ~22 um apart
                D = hypot(ch.cellsXY(:, 1) - ch.cellsXY(:, 1)', ch.cellsXY(:, 2) - ch.cellsXY(:, 2)');
                tc.verifyGreaterThanOrEqual(min(D(D > 0)), 22 / 1.657 - 1e-6);

                % positions: tp ~1 px, dup 3-9 px from their cell, fp on background
                P = [T.X T.Y];
                tpRows = find(ch.det.Kind == "tp");
                dTp = hypot(P(tpRows, 1) - ch.cellsXY(ch.det.TrueIdx(tpRows), 1), P(tpRows, 2) - ch.cellsXY(ch.det.TrueIdx(tpRows), 2));
                tc.verifyLessThan(max(dTp), 4);
                dupRows = find(ch.det.Kind == "dup");
                dDup = hypot(P(dupRows, 1) - ch.cellsXY(ch.det.TrueIdx(dupRows), 1), P(dupRows, 2) - ch.cellsXY(ch.det.TrueIdx(dupRows), 2));
                tc.verifyGreaterThanOrEqual(min(dDup), 3 - 0.02);
                tc.verifyLessThanOrEqual(max(dDup), 9 + 0.02);
                fpRows = find(ch.det.Kind == "fp");
                for r = fpRows'
                    tc.verifyGreaterThanOrEqual(min(hypot(ch.cellsXY(:, 1) - P(r, 1), ch.cellsXY(:, 2) - P(r, 2))), 14 - 0.02);
                end

                % duplicate groups: pairs plus one 3-member cluster, rows really are dups of one primary
                sizes = cellfun(@numel, ch.dupGroups);
                tc.verifyGreaterThanOrEqual(nnz(sizes == 2), 4);
                tc.verifyEqual(nnz(sizes == 3), 1);
                for g = 1:numel(ch.dupGroups)
                    m = ch.dupGroups{g};
                    tc.verifyEqual(ch.det.Kind(m(1)), "tp");
                    tc.verifyTrue(all(ch.det.Kind(m(2:end)) == "dup"));
                    tc.verifyTrue(all(ch.det.DupOfRow(m(2:end)) == m(1)));
                end

                % scores overlap but separate on the whole
                tc.verifyGreaterThan(median(T.score(tpRows)), median(T.score(fpRows)));
                tc.verifyGreaterThan(max(T.score(fpRows)), min(T.score(tpRows)), 'true and false scores overlap');
            end
        end

        function redetectedVariant(tc)
            for key = ["ECM1" "PV2"]
                ch = tc.Truth.(char(key));
                T0 = tc.readLocs(key);
                T1 = readtable(tc.Truth.paths.(lower(char(key)) + "Redet"), 'TextType', 'string');
                tc.verifyEqual(string(T1.Properties.VariableNames), tc.LocsColumns);
                R = ch.redet;
                tc.verifyEqual(height(T1), height(R));
                kept = R.OldRow > 0;
                tc.verifyEqual(numel(unique(R.OldRow(kept))), nnz(kept));
                tc.verifyEqual(sort(union(R.OldRow(kept), ch.droppedOldRows)), (1:height(T0))');
                tc.verifyEmpty(intersect(R.OldRow(kept), ch.droppedOldRows));
                nOld = height(T0);
                tc.verifyEqual(numel(ch.droppedOldRows), max(2, round(0.05 * nOld)));
                tc.verifyEqual(nnz(~kept), max(2, round(0.05 * nOld)));
                % dropped: some true, some false
                tc.verifyTrue(any(ch.det.Kind(ch.droppedOldRows) == "tp") && any(ch.det.Kind(ch.droppedOldRows) == "fp"));
                % kept detections moved by less than 2 px, scores changed, rows reordered
                rows = find(kept);
                d = hypot(T1.X(rows) - T0.X(R.OldRow(rows)), T1.Y(rows) - T0.Y(R.OldRow(rows)));
                tc.verifyLessThan(max(d), 2 + 0.02);
                tc.verifyGreaterThan(max(d), 0);
                tc.verifyTrue(any(T1.score(rows) ~= T0.score(R.OldRow(rows))));
                tc.verifyNotEqual(R.OldRow(kept), sort(R.OldRow(kept)), 'rows are in a different order');
                tc.verifyEqual(R.Kind(kept), ch.det.Kind(R.OldRow(kept)));
            end
        end

        function legacyQcFile(tc)
            T = readtable(tc.Truth.paths.qc, 'TextType', 'string');
            L = tc.readLocs("PV2");
            n = height(L);
            tc.verifyEqual(string(T.Properties.VariableNames), [tc.LocsColumns tc.QcColumns]);
            tc.verifyEqual(height(T), n);
            tc.verifyEqual([T.X T.Y], [L.X L.Y]);
            tc.verifyEqual(T.QCSourceRow, (1:n)');
            labelled = T.QCLabel ~= "" & ~ismissing(T.QCLabel);
            tc.verifyEqual(logical(T.QCReviewed), labelled);
            tc.verifyEqual(nnz(labelled) / n, 0.5, 'AbsTol', 0.12);
            tc.verifyEqual(sort(unique(T.QCLabel(labelled)))', ["Bad" "Good" "Ignore" "Uncertain"]);
            tc.verifyGreaterThanOrEqual(nnz(T.QCLabel == "Ignore"), 2);
            tc.verifyEqual(T.QCCode(T.QCLabel == "Good"), ones(nnz(T.QCLabel == "Good"), 1));
            % true cells mostly Good, false positives mostly Bad
            det = tc.Truth.PV2.det;
            tpLab = T.QCLabel(labelled & det.Kind == "tp");
            fpLab = T.QCLabel(labelled & det.Kind == "fp");
            tc.verifyGreaterThan(mean(tpLab == "Good"), 0.7);
            tc.verifyGreaterThan(mean(fpLab == "Bad"), 0.7);
            % truth table
            tc.verifyEqual(tc.Truth.qc.Row, find(labelled));
            tc.verifyEqual(tc.Truth.qc.Label, T.QCLabel(labelled));
        end

        function legacyResolverFile(tc)
            T = readtable(tc.Truth.paths.resolver, 'TextType', 'string');
            res = tc.Truth.resolver;
            tc.verifyEqual(string(T.Properties.VariableNames), [tc.LocsColumns ...
                ["CURATED_X" "CURATED_Y" "NeighborResolved" "NeighborResolvedStatus" "NeighborPairID"]]);
            n = res.nOriginalRows;
            tc.verifyEqual(height(T), n + 2);
            tc.verifyEqual(res.nRows, n + 2);
            nanRows = find(isnan(T.CURATED_X));
            tc.verifyEqual(nanRows(:)', res.curatedNaNRows);
            tc.verifyEqual(isnan(T.CURATED_X), isnan(T.CURATED_Y));
            % Keep A: B removed; Keep B: A removed; Keep Both: both kept; Merged: both removed + appended row
            tc.verifyTrue(isnan(T.CURATED_X(res.keepA(2))) && ~isnan(T.CURATED_X(res.keepA(1))));
            tc.verifyTrue(isnan(T.CURATED_X(res.keepB(1))) && ~isnan(T.CURATED_X(res.keepB(2))));
            tc.verifyTrue(~any(isnan(T.CURATED_X(res.keepBoth))));
            tc.verifyTrue(all(isnan(T.CURATED_X(res.merged))));
            tc.verifyEqual(res.mergedRow, n + 2);
            tc.verifyEqual([T.CURATED_X(res.mergedRow) T.CURATED_Y(res.mergedRow)], res.mergedXY);
            tc.verifyEqual(T.NeighborResolvedStatus(res.mergedRow), "Merged");
            % the row deleted outright: no pair, not resolved
            tc.verifyTrue(isnan(T.CURATED_X(res.deletedRow)));
            tc.verifyTrue(ismissing(T.NeighborPairID(res.deletedRow)) || T.NeighborPairID(res.deletedRow) == "");
            % the hand-added row sits after the originals
            tc.verifyEqual(res.addedRow, n + 1);
            tc.verifyEqual([T.CURATED_X(res.addedRow) T.CURATED_Y(res.addedRow)], res.addedXY);
            % statuses present
            st = join(T.NeighborResolvedStatus(~ismissing(T.NeighborResolvedStatus)), ";");
            for s = ["Keep A" "Keep B" "Keep Both" "Merged" "Unresolved"]
                tc.verifyTrue(contains(st, s), "status " + s + " missing");
            end
            tc.verifyEqual(nnz(res.pairs.Status == "Unresolved"), height(res.pairs) - 4);
        end

        function manifestResolvesFixture(tc)
            ecm = tc.Truth.paths.ecm1Locs;
            before = dir(tc.Dir);
            mf = CellDatasetManifest.forCsv(ecm);        % does not save by itself
            tc.verifyEqual(CellDatasetManifest.keyForCsv(ecm), 'ECM1');
            tc.verifyEqual(CellDatasetManifest.keyForCsv(tc.Truth.paths.pv2Locs), 'PV2');
            img = mf.imageForLocs(ecm);
            tc.verifyEqual(lower(img), lower(tc.Truth.paths.tif));
            tc.verifyEqual(numel(dir(tc.Dir)), numel(before), 'forCsv wrote something into the dataset folder');
            tc.verifyEmpty(dir(fullfile(tc.Dir, '*.celldataset.json')));
        end

        function deterministicFromSeed(tc)
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            rngBefore = rng;
            [d2, t2] = makeSyntheticDataset(fullfile(tmp.Folder, 'again'));
            tc.verifyEqual(rng, rngBefore, 'the global random stream was touched');
            for f = ["ecm1Locs" "pv2Locs" "ecm1Redet" "pv2Redet" "resolver"]
                [~, n1, e1] = fileparts(tc.Truth.paths.(f));
                tc.verifyEqual(fileread(fullfile(d2, [n1 e1])), fileread(tc.Truth.paths.(f)), char(f));
            end
            tc.verifyEqual(imread(t2.paths.tif, 1), imread(tc.Truth.paths.tif, 1));
            tc.verifyEqual(imread(t2.paths.tif, 2), imread(tc.Truth.paths.tif, 2));
            tc.verifyEqual(t2.qc, tc.Truth.qc);
            tc.verifyEqual(t2.ECM1.cellsXY, tc.Truth.ECM1.cellsXY);
            % another seed gives other cells; Variants=false writes only image and detections
            [~, t3] = makeSyntheticDataset(fullfile(tmp.Folder, 'seed2'), Seed=2, Variants=false);
            tc.verifyNotEqual(t3.ECM1.cellsXY, tc.Truth.ECM1.cellsXY);
            tc.verifyFalse(isfield(t3.paths, 'qc'));
            tc.verifyFalse(isfield(t3.paths, 'resolver'));
        end
    end

    methods (Access = private)
        function T = readLocs(tc, key)
            T = readtable(tc.Truth.paths.(lower(char(key)) + "Locs"), 'TextType', 'string');
        end
    end
end

