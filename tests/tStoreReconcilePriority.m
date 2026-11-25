classdef tStoreReconcilePriority < matlab.unittest.TestCase
%tStoreReconcilePriority  Regression tests of curation.Store reconcile: rows a person decided or
%   touched get the detections first, a detection next to a kept cell is never a silent second
%   candidate, non-finite detections do not churn, a badly matched locs is refused, audit samples
%   are never purged. Review findings 5, 16, G and H.
%   In-memory stores at 1 um/px, so the 8 um tolerance is 8 px. Five far-away filler detections
%   stay in every locs table so that a test is not refused as a mismatch (finding G) by accident.
%
%   Run: pwsh -File tools\Run-Tests.ps1 tStoreReconcilePriority

    properties (Constant, Access = private)
        Fill = [1000 1000; 1100 1000; 1200 1000; 1300 1000; 1400 1000]
    end

    methods (TestClassSetup)
        function addPaths(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
        end
    end

    %% ---- finding 5: pass priority ---------------------------------------------------------------
    methods (Test)
        function reviewedRowGetsTheDetectionBeforeAnUnreviewedNeighbor(tc)
            s = tc.mem([100 100; 110 100]);
            g = idAt(s, 100, 100); u = idAt(s, 110, 100);
            s.setLabel(g, "Good");
            rep = s.reconcile(mkLocs([106 100; tc.Fill]));   % 6 px from G, 4 px from U
            tc.verifyTrue(s.get('InLocs', g), 'the reviewed row takes the detection');
            tc.verifyEqual(s.get('DET_X', g), 106);
            tc.verifyEqual(s.get('State', u), "stale", 'the unreviewed neighbor loses it');
            tc.verifyEqual(rep.nVanishedGood, 0, 'the reviewed Good is not left "vanished"');
            tc.verifyEqual(rep.nAppended, 0);
        end

        function handAddedCellGetsTheDetectionAtItsPosition(tc)
            s = tc.mem([108.5 100]);
            n = idAt(s, 108.5, 100);
            h = s.addCell([100 100]);                   % hand-added Good, no detector position
            rep = s.reconcile(mkLocs([101 100; tc.Fill]));   % 1 px from H, 7.5 px from N
            tc.verifyTrue(s.get('InLocs', h), 'the hand-added cell links to the detection at its position');
            tc.verifyEqual([s.get('DET_X', h) s.get('X', h)], [101 100]);
            tc.verifyEqual(s.get('State', n), "stale");
            tc.verifyEqual(rep.nAppended, 0);
        end

        function reDetectedMergedDuplicateStaysMerged(tc)
            s = tc.mem([100 100; 106 100; 112 100]);
            k = idAt(s, 100, 100); m = idAt(s, 106, 100); u = idAt(s, 112, 100);
            s.mergeCells([k m], k);
            s.setLabel(k, "Good");
            rep = s.reconcile(mkLocs([100 100; 108 100; tc.Fill]));   % 2 px from M, 4 px from U
            tc.verifyTrue(s.get('InLocs', m), 'the merged duplicate takes its re-detection');
            tc.verifyEqual(s.get('State', m), "merged", 'and stays merged');
            tc.verifyEqual(s.get('State', u), "stale", 'the unreviewed neighbor does not');
            tc.verifyEqual(rep.nAppended, 0);
            tc.verifyEqual(s.counts().kept, 1, 'the cell is counted once');
        end

        function personRowIsMatchedOnItsDetectorPositionBeforeItsMovedPosition(tc)
            % pass (i) DET before pass (ii) X/Y: a moved reviewed cell keeps its own detection even
            % when another detection lies closer to where it was moved
            s = tc.mem([100 100; 140 100]);
            a = idAt(s, 100, 100);
            s.setLabel(a, "Good");
            s.moveCell(a, [120 100]);
            s.reconcile(mkLocs([101 100; 119 100; tc.Fill]));
            tc.verifyEqual(s.get('DET_X', a), 101);
            tc.verifyEqual([s.get('X', a) s.get('Y', a)], [120 100], 'the person''s position is kept');
        end

        function newDetectionNextToAKeptCellIsReportedNotSilent(tc)
            s = tc.mem([100 100]);
            g = idAt(s, 100, 100);
            s.setLabel(g, "Good");
            rep = s.reconcile(mkLocs([100 100; 104 100; tc.Fill]));
            tc.verifyEqual(rep.nAppended, 1);
            nw = idAt(s, 104, 100);
            tc.verifyEqual(rep.nNearKept, 1, 'a detection within tolerance of a reviewed row is reported');
            tc.verifyEqual(rep.nearKeptIds, uint32([nw g]), 'as [new id, reviewed id] for the close-pair queue');
        end

        function nearestWinsAmongRowsOfTheSamePriority(tc)
            s = tc.mem([100 100; 106 100]);
            a = idAt(s, 100, 100); b = idAt(s, 106, 100);
            s.reconcile(mkLocs([103.5 100; tc.Fill]));
            tc.verifyTrue(s.get('InLocs', b));
            tc.verifyFalse(s.get('InLocs', a));
        end
    end

    %% ---- finding 16: non-finite detections ------------------------------------------------------------
    methods (Test)
        function nonFiniteDetectionsAreDroppedWithAWarning(tc)
            L = mkLocs([100 100; NaN 50; 200 100; 300 Inf]);
            s = curation.Store.fromTable(L, struct('Key', 'ECM1', 'UmPerPixel', 1));
            tc.addTeardown(@() closeQuiet(s));
            tc.verifyEqual(s.NumRows, 2, 'rows without a finite position are not created');
            tc.verifyTrue(any(contains(s.LastReconcile.warnings, "2 detection")), 'the warning says how many');
            rep = s.reconcile(L);
            tc.verifyEqual([rep.nAppended rep.nStale rep.nPurged], [0 0 0]);
            tc.verifyTrue(any(contains(rep.warnings, "2 detection")));
            rep = s.reconcile(L);
            tc.verifyEqual([rep.nAppended rep.nStale rep.nPurged], [0 0 0], 'no churn on every reconcile');
            tc.verifyEqual(s.NumRows, 2);
        end
    end

    %% ---- finding G: a badly matched locs ----------------------------------------------------------------
    methods (Test)
        function badlyMatchedReconcileIsRefusedUnlessForced(tc)
            [gx, gy] = meshgrid(100:50:300, 100:50:150);
            xy = [gx(:) gy(:)];
            s = tc.mem(xy);
            s.setLabel(s.T.CellID(1:3), "Good");
            T0 = s.T;
            shifted = mkLocs(xy + 30);                  % e.g. the other page, or resized coordinates
            tc.verifyError(@() s.reconcile(shifted), 'curation:Store:reconcileMismatch');
            tc.verifyEqual(s.T, T0, 'a refused reconcile changes nothing');
            tc.verifyTrue(s.LastReconcile.Refused, 'the refused report is kept in LastReconcile');
            tc.verifyEqual(s.LastReconcile.nNew, size(xy, 1));
            rep = s.reconcile(shifted, struct('Force', true));
            tc.verifyTrue(rep.Ran);
            tc.verifyFalse(rep.Refused);
            tc.verifyEqual(rep.nAppended, size(xy, 1));
        end

        function badlyMatchedLocsAtOpenOpensReadOnly(tc)
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [gx, gy] = meshgrid(100:50:300, 100:50:150);
            xy = [gx(:) gy(:)];
            p = fullfile(tmp.Folder, 'secG_proj_ECM1_locs.csv');
            writetable(mkLocs(xy), p);
            s = curation.Store.openCsv(p, struct('AutosaveDelay', 0, 'Reviewer', 'tester'));
            s.setLabel(s.T.CellID(1:3), "Good");
            T0 = s.T;
            s.close();
            pause(1.1);                                 % same byte size: let the time stamp differ
            writetable(mkLocs(xy * 2), p);              % resized-space coordinates, say
            r = curation.Store.openCsv(p, struct('AutosaveDelay', 0));
            tc.addTeardown(@() closeQuiet(r));
            tc.verifyTrue(r.ReadOnly, 'a refused reconcile at open leaves the store read-only');
            tc.verifyTrue(any(contains(r.LastReconcile.warnings, "matched")));
            tc.verifyEqual(r.T, T0, 'and shows the rows as they were');
        end
    end

    %% ---- finding H: audit samples ------------------------------------------------------------------------
    methods (Test)
        function auditSampleRowsAreNeverPurged(tc)
            s = tc.mem([100 100; 200 100]);
            a = idAt(s, 100, 100);
            s.setAuditRole(a, "holdout");
            s.reconcile(mkLocs([200 100; tc.Fill]));
            tc.assertEqual(s.get('State', a), "stale");
            rep = s.reconcile(mkLocs([200 100; tc.Fill]));
            tc.verifyTrue(ismember(a, s.T.CellID), 'a member of an audit sample is never purged');
            tc.verifyEqual(rep.nPurged, 0);
        end
    end

    methods (Access = private)
        function s = mem(tc, xy)
            s = curation.Store.fromTable(mkLocs([xy; tc.Fill]), struct('Key', 'ECM1', 'UmPerPixel', 1, ...
                'Reviewer', 'tester'));
            tc.addTeardown(@() closeQuiet(s));
        end
    end
end

function L = mkLocs(xy)
n = size(xy, 1);
L = table(xy(:, 1), xy(:, 2), zeros(n, 1), linspace(0.5, 0.9, n)', repmat("img.tif", n, 1), zeros(n, 1), ...
    (1:n)', 'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
end

function id = idAt(s, x, y)
T = s.T;
k = find(abs(T.X - x) < 0.011 & abs(T.Y - y) < 0.011);
assert(numel(k) == 1, 'expected one row at (%g, %g), found %d', x, y, numel(k));
id = T.CellID(k);
end

function closeQuiet(s)
try
    if isvalid(s), s.close(); end
catch
end
end
