classdef tLegacyImportEdge < matlab.unittest.TestCase
%tLegacyImportEdge  Regression tests of the legacy resolver import at its edges: which rows the
%   resolver appended (independent evidence first, the score-repeat guess only with proximity),
%   resolver work saved to the resized CSV, and a note on deleted rows that had no partner.
%   Review findings 7, 8 and E. Stores open at the default 0.645 um/px (no image).
%
%   Run: pwsh -File tools\Run-Tests.ps1 tLegacyImportEdge

    properties (Access = private)
        Dir char
    end

    methods (TestClassSetup)
        function addPaths(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
        end
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = tmp.Folder;
        end
    end

    %% ---- finding 7: which rows were appended -------------------------------------------------------
    methods (Test)
        function genuineLastRowSharingAScoreWithADeletedRowIsNotMoved(tc)
            % No appended rows; the last detection happens to repeat the (score, class) of a row the
            % resolver deleted 700 px away. It must stay the detection it is.
            p = tc.writeResolver('secA_proj_ECM1', [100 100; 300 300; 600 600; 800 800], ...
                [0.91; 0.50; 0.73; 0.50], [false; true; false; false]);
            s = tc.openP(p);
            T = s.T;
            k = find(T.DET_X == 800 | T.X == 800);
            tc.assertNumElements(k, 1, 'the last detection keeps its position');
            r = T(k, :);
            tc.verifyEqual([r.X r.Y r.DET_X r.DET_Y], [800 800 800 800]);
            tc.verifyEqual([r.Origin r.State r.PosSource], ["detected" "active" "det"]);
            d = T(T.X == 300, :);
            tc.verifyEqual([d.Label d.LabelSource d.State], ["Bad" "legacy-resolver" "active"], ...
                'the deleted row is a plain deletion');
        end

        function resizedTwinRowCountIsEvidenceOfTheAppendedRows(tc)
            % Row 4 was appended by hand as a copy of row 2 (deleted later). Only the pristine resized
            % twin (3 rows) can tell; the score-repeat guess would need proximity to row 2.
            p = tc.writeResolver('secB_proj_ECM1', [100 100; 300 300; 600 600; 900 600], ...
                [0.91; 0.50; 0.73; 0.50], [false; true; false; false]);
            twin = mkLocs([100 100; 300 300; 600 600] / 2, [0.91; 0.50; 0.73]);
            writetable(twin, fullfile(tc.Dir, 'secB_proj_ECM1_locs_resized.csv'));
            s = tc.openP(p);
            r = s.T(s.T.X == 900, :);
            tc.assertEqual(height(r), 1);
            tc.verifyEqual([r.Origin r.PosSource], ["added" "human"], 'the appended row is a hand-added cell');
            tc.verifyEqual(s.LastImport.resolver.nOrigSource, "resized", 'the report names the evidence');
            tc.verifyEqual(s.LastImport.resolver.nOrig, 3);
        end

        function importReportSaysWhenTheAppendedRowsWereInferred(tc)
            p = tc.writeResolver('secC_proj_ECM1', [100 100; 300 300; 600 600; 800 800], ...
                [0.91; 0.50; 0.73; 0.50], [false; true; false; false]);
            s = tc.openP(p);
            tc.verifyEqual(s.LastImport.resolver.nOrigSource, "heuristic");
            tc.verifyTrue(any(contains(s.LastImport.warnings, "inferred")), ...
                'without a resized twin or a manifest count the report says the rows were inferred');
        end
    end

    %% ---- finding 8: resolver work saved to the resized CSV --------------------------------------------
    methods (Test)
        function resolverWorkSavedInTheResizedCsvIsImportedAtFullResolution(tc)
            full = [100 100; 200 200; 205 200; 400 400; 600 600];
            sc = [0.91; 0.82; 0.73; 0.64; 0.55];
            p = fullfile(tc.Dir, 'secR_proj_ECM1_locs.csv');
            writetable(mkLocs(full, sc), p);             % detector output, untouched
            tw = mkLocs([full / 2; 350 50], [sc; 0.55]); % + a point added by hand (copy of row 5)
            tw.CURATED_X = tw.X; tw.CURATED_Y = tw.Y;
            tw.CURATED_X(1) = 52; tw.CURATED_Y(1) = 50;  % moved
            tw.CURATED_X([3 4]) = NaN; tw.CURATED_Y([3 4]) = NaN;
            tw.NeighborResolved = false(6, 1);
            tw.NeighborPairID = strings(6, 1); tw.NeighborResolvedStatus = strings(6, 1);
            tw.NeighborPairID([2 3]) = "2-3"; tw.NeighborResolvedStatus([2 3]) = "Keep A";
            writetable(tw, fullfile(tc.Dir, 'secR_proj_ECM1_locs_resized.csv'));
            s = tc.openP(p);
            g = @(f, x, y) s.get(f, idAtDet(s, x, y));
            tc.verifyEqual([g('X', 100, 100) g('Y', 100, 100)], [104 100], 'AbsTol', 1e-9, ...
                'a move saved in resized coordinates lands at full resolution');
            tc.verifyEqual(g('PosSource', 100, 100), "human");
            tc.verifyEqual(g('State', 205, 200), "merged", 'Keep A: the loser is merged');
            tc.verifyEqual(g('MergedInto', 205, 200), uint32(idAtDet(s, 200, 200)));
            tc.verifyEqual([g('Label', 400, 400) g('LabelSource', 400, 400)], ["Bad" "legacy-resolver"]);
            added = s.T(s.T.Origin == "added", :);
            tc.assertEqual(height(added), 1, 'the hand-added point of the resized file is imported');
            tc.verifyEqual([added.X added.Y], [700 100], 'AbsTol', 1e-9);
            tc.verifyTrue(s.LastImport.resolver.fromResized, 'the report says where the work came from');
            tc.verifyTrue(any(contains(s.LastImport.warnings, "_resized")));
        end
    end

    %% ---- finding E: a deletion without a partner ---------------------------------------------------------
    methods (Test)
        function deletedRowWithoutAPartnerCarriesANoteSayingSo(tc)
            p = tc.writeResolver('secE_proj_ECM1', [100 100; 300 300; 600 600], ...
                [0.91; 0.82; 0.73], [false; true; false]);
            s = tc.openP(p);
            d = s.T(s.T.X == 300, :);
            tc.verifyEqual(d.Label, "Bad");
            tc.verifySubstring(d.Notes, "legacy resolver", 'a later consumer can tell it from a person''s Bad');
            tc.verifySubstring(d.Notes, "no partner");
        end
    end

    methods (Access = private)
        function p = writeResolver(tc, stem, xy, score, deleted)
            n = size(xy, 1);
            T = table(repmat("img.tif", n, 1), xy(:, 2), xy(:, 1), zeros(n, 1), score(:), zeros(n, 1), ...
                'VariableNames', {'imgName', 'Y', 'X', 'class', 'score', 'thr'});
            T.CURATED_X = xy(:, 1); T.CURATED_Y = xy(:, 2);
            T.CURATED_X(deleted) = NaN; T.CURATED_Y(deleted) = NaN;
            T.NeighborResolved = false(n, 1);
            T.NeighborResolvedStatus = strings(n, 1);
            T.NeighborPairID = strings(n, 1);
            p = fullfile(tc.Dir, [stem '_locs.csv']);
            writetable(T, p);
        end

        function s = openP(tc, p)
            s = curation.Store.openCsv(p, struct('AutosaveDelay', 0, 'Reviewer', 'tester'));
            tc.addTeardown(@() closeQuiet(s));
        end
    end
end

function L = mkLocs(xy, score)
n = size(xy, 1);
L = table(xy(:, 1), xy(:, 2), zeros(n, 1), score(:), repmat("img.tif", n, 1), zeros(n, 1), ...
    'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr'});
end

function id = idAtDet(s, x, y)
T = s.T;
k = find(abs(T.DET_X - x) < 0.011 & abs(T.DET_Y - y) < 0.011);
assert(numel(k) == 1, 'expected one row detected at (%g, %g), found %d', x, y, numel(k));
id = T.CellID(k);
end

function closeQuiet(s)
try
    if isvalid(s), s.close(); end
catch
end
end
