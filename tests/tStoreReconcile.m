classdef tStoreReconcile < matlab.unittest.TestCase
%tStoreReconcile  Specification tests of curation.Store reconcile: matching a new detector output to the store.
%   Written from the contract (one-to-one passes: exact, mutual nearest neighbour within TolUm, effective
%   position for human/added rows; what happens to rows that are not matched), not from the implementation.
%   Fixture: tests\fixtures\makeSyntheticDataset (1.657 um/px, so the 8 um tolerance is about 4.83 px).

    properties (Access = private)
        Src char        % pristine fixture folder (built once)
        Truth struct
        Dir char        % this test's own copy of the fixture
    end

    properties (Constant, Access = private)
        Upp = 1.657
        Base = 'SYN-0001_sec1'
    end

    methods (TestClassSetup)
        function buildFixture(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(here, 'fixtures')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [tc.Src, tc.Truth] = makeSyntheticDataset(fullfile(tmp.Folder, 'pristine'));
        end
    end

    methods (TestMethodSetup)
        function copyFixture(tc)
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = fullfile(tmp.Folder, 'ds');
            copyfile(tc.Src, tc.Dir);
        end
    end

    %% ---- passes of the matcher ---------------------------------------------------------------
    methods (Test)
        function identicalLocsAreAllExactAndNothingChanges(tc)
            s = tc.openStore('ECM1');
            L = tc.readLocs('ECM1');
            n = height(L);
            tc.verifyEqual(height(s.T), n, 'a fresh store has one row per detection');
            labelCycle(s);
            before = s.T;
            rev0 = s.Meta.Revision;
            rep = s.reconcile(L);
            tc.verifyEqual(rep.nOld, n);
            tc.verifyEqual(rep.nNew, n);
            tc.verifyEqual(rep.nExact, n, 'identical positions must all match in the exact pass');
            tc.verifyEqual(rep.nNear, 0);
            tc.verifyEqual([rep.nAppended rep.nStale rep.nPurged rep.nVanishedGood rep.nVanishedOther], zeros(1, 5), ...
                'identical locs: nothing appended, stale, purged or vanished');
            tc.verifyEqual(keyCols(s.T), keyCols(before), 'identical locs must leave every curation field unchanged');
            tc.verifyTrue(all(s.T.InLocs));
            tc.verifyLessThan(max(s.T.MatchDistUm), 0.01 * tc.Upp + 1e-9, 'exact matches have MatchDistUm ~ 0');
            tc.verifyGreaterThan(s.Meta.Revision, rev0, 'reconcile bumps the revision');
        end

        function shuffledRowOrderLabelsFollowTheCells(tc)
            % The bug the store exists to fix: a label belongs to the cell, not to the row number.
            s = tc.openStore('ECM1');
            L = tc.readLocs('ECM1');
            n = height(L);
            labelCycle(s);
            before = s.T;
            p = randperm(RandStream('mt19937ar', 'Seed', 7), n);
            Lp = L(p, :);
            rep = s.reconcile(Lp);
            tc.verifyEqual(rep.nExact, n, 'a pure reordering is all exact matches');
            tc.verifyEqual(height(s.T), n);
            [tfA, locA] = ismember([Lp.X Lp.Y], [s.T.DET_X s.T.DET_Y], 'rows');
            [tfB, locB] = ismember([Lp.X Lp.Y], [before.X before.Y], 'rows');
            tc.verifyTrue(all(tfA) && all(tfB));
            tc.verifyEqual(s.T.Label(locA), before.Label(locB), 'each label must sit on the detection at the same position');
            tc.verifyEqual(s.T.LabelSource(locA), before.LabelSource(locB));
            tc.verifyEqual(s.T.Reviewed(locA), before.Reviewed(locB));
            tc.verifyEqual(s.T.CellID(locA), before.CellID(locB), 'a cell keeps its CellID when its row moves');
        end

        function subToleranceJitterMatchesAndKeepsLabels(tc)
            s = tc.openStore('ECM1');
            L = tc.readLocs('ECM1');
            n = height(L);
            labelCycle(s);
            before = s.T;
            th = 2 * pi * rand(RandStream('mt19937ar', 'Seed', 3), n, 1);
            Lj = L; Lj.X = L.X + cos(th); Lj.Y = L.Y + sin(th);      % exactly 1 px = 1.657 um away
            rep = s.reconcile(Lj);
            tc.verifyEqual(rep.nExact, 0);
            tc.verifyEqual(rep.nNear, n, 'every 1 px (1.657 um) displacement is inside the 8 um tolerance');
            tc.verifyEqual(rep.nAppended, 0);
            tc.verifyEqual(rep.tolUm, 8, 'default tolerance is 8 um');
            tc.verifyEqual(rep.maxMatchDistUm, tc.Upp, 'AbsTol', 0.01);
            [~, ia] = sort(before.CellID); [~, ib] = sort(s.T.CellID);
            A = before(ia, :); B = s.T(ib, :);
            tc.verifyEqual(B.CellID, A.CellID);
            tc.verifyEqual(B.Label, A.Label, 'labels preserved under jitter');
            tc.verifyEqual(B.Reviewed, A.Reviewed);
            tc.verifyEqual(B.MatchDistUm, repmat(tc.Upp, n, 1), 'AbsTol', 0.01, 'MatchDistUm = displacement in um');
            [tf, loc] = ismember([Lj.X Lj.Y], [B.DET_X B.DET_Y], 'rows');
            tc.verifyTrue(all(tf), 'DET_X/DET_Y refreshed to the new detector position');
            tc.verifyEqual([B.X B.Y], [B.DET_X B.DET_Y], 'PosSource det: effective position follows the detector');
            tc.verifyEqual(numel(unique(loc)), n);
        end

        function pointJustInsideToleranceIsMatched(tc)
            s = tc.memStore([100 100]);
            rep = s.reconcile(mkLocs([104.5 100]));           % 4.5 px = 7.46 um < 8 um
            tc.verifyEqual(rep.nNear, 1, 'inside tolerance must match');
            tc.verifyEqual(rep.nAppended, 0);
            tc.verifyEqual(s.T.MatchDistUm(1), 4.5 * tc.Upp, 'AbsTol', 0.01);
        end

        function pointJustOutsideToleranceIsNotMatched(tc)
            s = tc.memStore([100 100]);
            % Force: no stored row matches, which review finding G refuses without it
            rep = s.reconcile(mkLocs([105.2 100]), struct('Force', true));   % 5.2 px = 8.62 um > 8 um
            tc.verifyEqual(rep.nExact + rep.nNear, 0, 'outside tolerance must not match');
            tc.verifyEqual(rep.nAppended, 1, 'the unmatched new detection is appended');
            tc.verifyEqual(height(s.T), 2);
            old = rowAtXY(s.T, 100, 100);
            tc.verifyFalse(old.InLocs, 'the old row has no detection any more');
            tc.verifyEqual(old.State, "stale", 'unreviewed and unmatched -> stale');
        end

        function twoOldPointsCompetingForOneNewPointNearestWins(tc)
            % Both rows unreviewed, i.e. of the same priority: the nearer one wins. (Review finding
            % 5: a reviewed row now gets the detection first, whatever the distance; that case is
            % tStoreReconcilePriority/reviewedRowGetsTheDetectionBeforeAnUnreviewedNeighbour.)
            s = tc.memStore([100 100; 106 100]);
            idA = rowAtXY(s.T, 100, 100).CellID;
            idB = rowAtXY(s.T, 106, 100).CellID;
            rep = s.reconcile(mkLocs([103.5 100]));           % A is 3.5 px away, B 2.5 px: B wins
            tc.verifyEqual(rep.nExact + rep.nNear, 1, 'one new point can be matched only once');
            tc.verifyEqual(rep.nAppended, 0);
            rb = tc.rowOf(s, idB); ra = tc.rowOf(s, idA);
            tc.verifyEqual(rb.DET_X, 103.5, 'the nearer old row takes the detection');
            tc.verifyTrue(rb.InLocs);
            tc.verifyFalse(ra.InLocs, 'the farther old row loses the one-to-one competition');
            tc.verifyEqual(ra.State, "stale", 'the loser here is unreviewed: stale');
        end

        function matchRefreshesDetectorColumns(tc)
            s = tc.memStore([100 100; 200 100]);
            L = mkLocs([100 100; 200 100]);
            L.score = [0.11; 0.22]; L.rescore = [3.5; -2.5]; L.class = [1; 2]; L.thr = [0.4; 0.4];
            L.imgName = ["renamed_A"; "renamed_B"];
            s.reconcile(L);
            a = rowAtXY(s.T, 100, 100);
            tc.verifyEqual([a.score a.rescore a.class a.thr], [0.11 3.5 1 0.4], 'score/rescore/class/thr refreshed on match');
            tc.verifyEqual(a.imgName, "renamed_A");
            b = rowAtXY(s.T, 200, 100);
            tc.verifyEqual([b.score b.rescore], [0.22 -2.5]);
        end

        function humanRowIsMatchedAgainstItsEffectiveXY(tc)
            % Pass 3: a cell moved far from its detection is linked to a detection near where it was moved.
            s = tc.memStore([100 100]);
            id = s.T.CellID(1);
            s.setLabel(id, 'Good', 'human');
            s.moveCell(id, [150 150]);
            rep = s.reconcile(mkLocs([151 150]));
            tc.verifyEqual(rep.nAppended, 0, 'a detection next to a human-moved cell must link, not duplicate it');
            tc.verifyEqual(height(s.T), 1);
            r = tc.rowOf(s, id);
            tc.verifyEqual([r.DET_X r.DET_Y], [151 150]);
            tc.verifyEqual([r.X r.Y], [150 150], 'a human position is kept');
            tc.verifyEqual(r.Label, "Good");
        end
    end

    %% ---- what happens to unmatched rows -------------------------------------------------------
    methods (Test)
        function droppedDetectionsFollowThePerStatusRules(tc)
            [s, id] = tc.statusStore();
            % Force: 1 of 6 rows matches, which review finding G refuses without it
            rep = s.reconcile(mkLocs([600 100]), struct('Force', true));   % only P is still detected
            r = @(k) tc.rowOf(s, id.(k));
            tc.verifyEqual(r('U').State, "stale", 'unreviewed vanished -> stale');
            tc.verifyEqual(r('Aut').State, "stale", 'auto-Bad vanished -> stale');
            tc.verifyEqual(r('G').State, "active", 'reviewed Good must survive a vanished detection');
            tc.verifyFalse(r('G').InLocs);
            tc.verifyEqual(r('G').Label, "Good");
            tc.verifyTrue(ismember(id.G, s.kept().CellID), 'vanished Good stays kept');
            tc.verifyNotEqual(r('Bd').State, "stale", 'reviewed Bad is retained');
            tc.verifyEqual(r('Bd').Label, "Bad");
            tc.verifyFalse(r('Bd').InLocs);
            tc.verifyNotEqual(r('Q').State, "stale", 'reviewed Uncertain is retained');
            tc.verifyEqual(r('Q').Label, "Uncertain");
            tc.verifyEqual(r('H').State, "active", 'human-added rows are unaffected');
            tc.verifyTrue(ismember(id.H, s.kept().CellID));
            tc.verifyTrue(r('P').InLocs);
            tc.verifyEqual(rep.nVanishedGood, 1);
            tc.verifyEqual(rep.nVanishedOther, 2, 'reviewed Bad and Uncertain');
            tc.verifyEqual(rep.nStale, 2);
            tc.verifyEqual(rep.nPurged, 0);
            tc.verifyEqual(rep.nAppended, 0);
            c = s.counts();
            tc.verifyEqual(c.vanishedGood, 1);
            tc.verifyEqual(c.stale, 2);
        end

        function secondReconcilePurgesRowsThatWereAlreadyStale(tc)
            [s, id] = tc.statusStore();
            newLocs = mkLocs([600 100]);
            maxEver = max(s.T.CellID);
            s.reconcile(newLocs, struct('Force', true));        % 1 of 6 rows matches (finding G)
            rep = s.reconcile(newLocs);
            tc.verifyEqual(rep.nPurged, 2, 'rows stale before this reconcile and still unmatched are purged');
            tc.verifyEqual(rep.nStale, 0);
            tc.verifyFalse(any(ismember([id.U id.Aut], s.T.CellID)), 'purged rows are gone');
            tc.verifyTrue(all(ismember([id.G id.Bd id.Q id.H id.P], s.T.CellID)), 'reviewed and human rows are never purged');
            % an id is never reused, also not after a purge
            rep = s.reconcile([newLocs; mkLocs([700 100])]);
            tc.verifyEqual(rep.nAppended, 1);
            fresh = rowAtXY(s.T, 700, 100);
            tc.verifyGreaterThan(fresh.CellID, maxEver, 'CellIDs are never reused, not even after a purge');
            tc.verifyEqual(numel(unique(s.T.CellID)), height(s.T));
        end

        function staleRowThatReappearsBecomesActiveAgain(tc)
            [s, id] = tc.statusStore();
            s.reconcile(mkLocs([600 100]), struct('Force', true));   % 1 of 6 rows matches (finding G)
            tc.verifyEqual(tc.rowOf(s, id.U).State, "stale");
            rep = s.reconcile(mkLocs([100 100; 600 100]));
            tc.verifyEqual(rep.nPurged, 1, 'only the row that stayed stale (auto-Bad) is purged');
            tc.verifyTrue(ismember(id.U, s.T.CellID), 'a stale row that is matched again is not purged');
            u = tc.rowOf(s, id.U);
            tc.verifyEqual(u.State, "active", 'a matched stale row becomes active');
            tc.verifyTrue(u.InLocs);
            tc.verifyEqual(rep.nAppended, 0, 'it relinks to its own row instead of creating a new one');
        end

        function newDetectionsAreAppendedUnreviewedWithNewIds(tc)
            s = tc.memStore([100 100; 300 100]);
            maxId = max(s.T.CellID);
            rep = s.reconcile(mkLocs([100 100; 300 100; 500 200; 500 400]));
            tc.verifyEqual(rep.nAppended, 2);
            tc.verifyEqual(height(s.T), 4);
            for xy = [500 200; 500 400]'
                r = rowAtXY(s.T, xy(1), xy(2));
                tc.verifyGreaterThan(r.CellID, maxId, 'new detections get new CellIDs');
                tc.verifyEqual(r.Label, "");
                tc.verifyFalse(r.Reviewed);
                tc.verifyEqual(r.Origin, "detected");
                tc.verifyEqual(r.State, "active");
                tc.verifyTrue(r.InLocs);
                tc.verifyEqual([r.DET_X r.DET_Y], xy');
            end
            tc.verifyEqual(numel(unique(s.T.CellID)), 4);
            tc.verifyEqual(s.Meta.NextCellId, double(max(s.T.CellID)) + 1, 'NextCellId is one past the highest id handed out');
        end

        function humanMovedCellKeepsPositionWhileDetectionRefreshes(tc)
            s = tc.memStore([100 100; 200 100]);
            idA = rowAtXY(s.T, 100, 100).CellID;
            s.setLabel(idA, 'Good', 'human');
            s.moveCell(idA, [102 101]);
            rep = s.reconcile(mkLocs([101 100.5; 201 100]));
            tc.verifyEqual(rep.nAppended, 0);
            a = tc.rowOf(s, idA);
            tc.verifyEqual([a.X a.Y], [102 101], 'a human-moved cell keeps its effective position');
            tc.verifyEqual([a.DET_X a.DET_Y], [101 100.5], 'DET_X/DET_Y follow the detector');
            tc.verifyEqual(a.PosSource, "human");
            b = rowAtXY(s.T, 201, 100);
            tc.verifyEqual([b.X b.Y], [201 100], 'a non-human row follows the detector');
        end

        function handAddedCellLinksToALaterDetectionInsteadOfDuplicating(tc)
            s = tc.memStore([100 100]);
            id = s.addCell([300 300]);
            n0 = height(s.T);
            rep = s.reconcile(mkLocs([100 100; 301.5 300.5]));     % 2.1 px from the hand-added cell
            tc.verifyEqual(rep.nAppended, 0, 'the detection must link to the added cell, not become a duplicate row');
            tc.verifyEqual(height(s.T), n0);
            r = tc.rowOf(s, id);
            tc.verifyEqual([r.DET_X r.DET_Y], [301.5 300.5]);
            tc.verifyTrue(r.InLocs);
            tc.verifyEqual([r.X r.Y], [300 300], 'a hand-added cell keeps its position');
            tc.verifyEqual(r.Label, "Good");
            tc.verifyEqual(r.State, "active");
        end

        function reconcileClearsUndoAndReportHasAllFields(tc)
            s = tc.memStore([100 100; 200 100]);
            s.setLabel(s.T.CellID(1), 'Bad', 'human');
            tc.verifyTrue(s.CanUndo);
            rev0 = s.Meta.Revision;
            rep = s.reconcile(mkLocs([100 100; 200 100]));
            tc.verifyFalse(s.CanUndo, 'reconcile clears the undo history');
            tc.verifyFalse(s.CanRedo);
            tc.verifyGreaterThan(s.Meta.Revision, rev0);
            for f = ["nOld" "nNew" "nExact" "nNear" "nAppended" "nVanishedGood" "nVanishedOther" "nStale" "nPurged" "tolUm" "matchDistUm" "maxMatchDistUm" "warnings"]
                tc.verifyTrue(isfield(rep, char(f)), "report lacks field " + f);
            end
            tc.verifyEqual(s.LastReconcile.nNew, rep.nNew, 'LastReconcile holds the report');
        end

        function reconcileNeverTouchesTheLocsFile(tc)
            f = tc.locsPath('ECM1');
            sig0 = fileSig(f);
            s = tc.openStore('ECM1');
            L = tc.readLocs('ECM1');
            labelCycle(s);
            s.reconcile(L(randperm(RandStream('mt19937ar', 'Seed', 1), height(L)), :));
            s.flush(); s.close();
            tc.verifyEqual(fileSig(f), sig0, 'the detector locs CSV must stay byte-identical (size, mtime, hash)');
        end
    end

    %% ---- re-detection of the fixture -----------------------------------------------------------
    methods (Test)
        function redetectedFileReconcilesOnOpenAllRowsLabelled(tc)
            tc.redetectRoundTrip(1);
        end

        function redetectedFileReconcilesOnOpenHalfRowsLabelled(tc)
            tc.redetectRoundTrip(2);
        end

        function unchangedLocsFileDoesNotReconcileOnReopen(tc)
            s = tc.openStore('ECM1');
            s.setLabel(s.T.CellID(1), 'Good', 'human');
            s.flush(); s.close();
            s2 = tc.openStore('ECM1');
            lr = s2.LastReconcile;
            tc.verifyTrue(isempty(lr) || isempty(fieldnames(lr)) || ~(isfield(lr, 'Ran') && lr.Ran), ...
                'no reconcile unless the locs fingerprint (size, mtime, rows) changed');
        end
    end

    methods (Access = private)
        function redetectRoundTrip(tc, labelEvery)
            truth = tc.Truth.ECM1;
            det = truth.det; R = truth.redet;
            s = tc.openStore('ECM1');
            L0 = tc.readLocs('ECM1');
            n = height(L0);
            ids = idsOfRows(s.T, L0);
            labelled = mod((1:n)', labelEvery) == 0;
            if labelEvery == 1; labelled(:) = true; end
            for r = find(labelled)'
                if det.Kind(r) == "tp"
                    s.setLabel(ids(r), 'Good', 'human');
                else
                    s.setLabel(ids(r), 'Bad', 'human');
                end
            end
            s.flush(); s.close();
            copyfile(fullfile(tc.Dir, [tc.Base '_proj_ECM1_locs.redetected.csv']), tc.locsPath('ECM1'));
            s = tc.openStore('ECM1');
            rep = s.LastReconcile;
            tc.assertNotEmpty(rep, 'a changed locs file must trigger a reconcile at open');
            Lr = tc.readLocs('ECM1');
            tc.assertEqual(height(Lr), height(R));
            dropped = truth.droppedOldRows;
            isNew = R.OldRow == 0;

            % every surviving detection kept its CellID and label
            for i = find(~isNew)'
                row = rowByDet(s.T, Lr.X(i), Lr.Y(i));
                tc.assertEqual(height(row), 1, "no row sits on redetected detection " + i);
                old = R.OldRow(i);
                tc.verifyEqual(row.CellID, ids(old), "detection " + i + " must keep the CellID of old row " + old);
                tc.verifyTrue(row.InLocs);
            end
            % per-status rules for the dropped rows
            for d = dropped(:)'
                row = s.T(s.T.CellID == ids(d), :);
                tc.assertEqual(height(row), 1, "dropped old row " + d + " vanished from the store");
                tc.verifyFalse(row.InLocs);
                if labelled(d) && det.Kind(d) == "tp"
                    tc.verifyEqual([row.State row.Label], ["active" "Good"], 'reviewed Good must survive a vanished detection');
                elseif labelled(d)
                    tc.verifyEqual(row.Label, "Bad");
                    tc.verifyNotEqual(row.State, "stale");
                else
                    tc.verifyEqual(row.State, "stale", 'unreviewed vanished -> stale');
                end
            end
            % new detections
            tc.verifyEqual(height(s.T), n + nnz(isNew));
            for i = find(isNew)'
                row = rowByDet(s.T, Lr.X(i), Lr.Y(i));
                tc.assertEqual(height(row), 1);
                tc.verifyGreaterThan(row.CellID, max(ids), 'new detections get new ids');
                tc.verifyFalse(row.Reviewed);
            end
            % report and counts versus truth
            dl = labelled(dropped);
            dk = det.Kind(dropped);
            tc.verifyEqual(rep.nOld, n);
            tc.verifyEqual(rep.nNew, height(R));
            tc.verifyEqual(rep.nExact + rep.nNear, nnz(~isNew), 'every surviving detection is matched exactly once');
            tc.verifyEqual(rep.nAppended, nnz(isNew));
            tc.verifyEqual(rep.nVanishedGood, nnz(dl & dk == "tp"));
            tc.verifyEqual(rep.nVanishedOther, nnz(dl & dk ~= "tp"));
            tc.verifyEqual(rep.nStale, nnz(~dl));
            tc.verifyEqual(rep.nPurged, 0);
            c = s.counts();
            goodRows = labelled & det.Kind == "tp";
            tc.verifyEqual(c.good, nnz(goodRows));
            tc.verifyEqual(c.kept, nnz(goodRows), 'vanished Good rows are still kept');
            tc.verifyEqual(c.vanishedGood, nnz(dl & dk == "tp"));
            tc.verifyEqual(c.stale, nnz(~dl));
            tc.verifyEqual(c.total, height(s.T));
        end

        function [s, id] = statusStore(tc)
            % rows far apart: U unreviewed, Aut auto-Bad, G Good, Bd Bad, Q Uncertain, P present Good; H hand-added Good
            s = tc.memStore([100 100; 200 100; 300 100; 400 100; 500 100; 600 100]);
            id = struct();
            keys = ["U" "Aut" "G" "Bd" "Q" "P"];
            for k = 1:6
                id.(char(keys(k))) = rowAtXY(s.T, 100 * k, 100).CellID;
            end
            s.setLabel(id.Aut, 'Bad', 'auto');
            s.setLabel(id.G, 'Good', 'human');
            s.setLabel(id.Bd, 'Bad', 'human');
            s.setLabel(id.Q, 'Uncertain', 'human');
            s.setLabel(id.P, 'Good', 'human');
            id.H = s.addCell([300 300]);
        end

        function row = rowOf(~, s, id)
            row = s.T(s.T.CellID == id, :);
        end

        function csv = locsPath(tc, key)
            csv = fullfile(tc.Dir, sprintf('%s_proj_%s_locs.csv', tc.Base, key));
        end

        function T = readLocs(tc, key)
            T = readtable(tc.locsPath(key), 'TextType', 'string');
        end

        function s = openStore(tc, key, varargin)
            mf = CellDatasetManifest.forCsv(tc.locsPath(key));
            s = curation.Store.open(mf, key, mkOpts(varargin{:}));
            tc.addTeardown(@() closeQuiet(s));
        end

        function s = memStore(tc, xy)
            s = curation.Store.fromTable(mkLocs(xy), struct('Key', 'ECM1', 'UmPerPixel', tc.Upp));
            tc.addTeardown(@() closeQuiet(s));
        end
    end
end

%% ---- helpers ---------------------------------------------------------------------------------

function L = mkLocs(xy)
n = size(xy, 1);
L = table(xy(:, 1), xy(:, 2), zeros(n, 1), linspace(0.5, 0.9, n)', repmat("T_proj_ECM1", n, 1), zeros(n, 1), (1:n)', ...
    'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
end

function labelCycle(s)
%labelCycle  Good / Bad / Uncertain in turn over all rows, so a label identifies its position.
ids = s.T.CellID;
labs = ["Good" "Bad" "Uncertain"];
for k = 1:3
    s.setLabel(ids(k:3:end), char(labs(k)), 'human');
end
end

function C = keyCols(T)
C = sortrows(T(:, {'CellID', 'X', 'Y', 'DET_X', 'DET_Y', 'Origin', 'State', 'MergedInto', 'PosSource', 'Label', ...
    'LabelSource', 'Reviewed', 'Flag', 'Excluded', 'score', 'rescore'}), 'CellID');
end

function row = rowAtXY(T, x, y)
row = T(abs(T.X - x) < 0.011 & abs(T.Y - y) < 0.011, :);
assert(height(row) == 1, 'expected exactly one row at (%g, %g), found %d', x, y, height(row));
end

function row = rowByDet(T, x, y)
row = T(abs(T.DET_X - x) < 0.011 & abs(T.DET_Y - y) < 0.011, :);
end

function ids = idsOfRows(T, L)
[tf, loc] = ismember([L.X L.Y], [T.DET_X T.DET_Y], 'rows');
assert(all(tf), 'some locs rows have no store row');
ids = T.CellID(loc);
end

function sig = fileSig(f)
d = dir(f);
fid = fopen(f, 'r'); b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('MD5');
md.update(b);
sig = {d.bytes, d.datenum, sprintf('%02x', typecast(md.digest(), 'uint8'))};
end

function closeQuiet(s)
try
    if isvalid(s); s.close(); end
catch
end
end

function o = mkOpts(varargin)
o = struct('Reviewer', 'tester');
for k = 1:2:numel(varargin)
    o.(varargin{k}) = varargin{k + 1};
end
end
