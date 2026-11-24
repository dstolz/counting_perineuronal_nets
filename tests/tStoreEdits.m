classdef tStoreEdits < matlab.unittest.TestCase
%tStoreEdits  Specification tests of curation.Store editing: labels, kept rule, add/move/merge, counts, undo/redo.
%   Written from the contract, not from the implementation. Works on the ECM1 channel of the synthetic fixture
%   (no legacy files for it, so a fresh open yields one unreviewed row per detection).

    properties (Access = private)
        Src char
        Dir char
        EvN double = 0
        EvLast = []
    end

    properties (Constant, Access = private)
        Base = 'SYN-0001_sec1'
        Cols = ["CellID" "X" "Y" "DET_X" "DET_Y" "class" "score" "rescore" "RescoreSource" "imgName" "thr" "Origin" "State" "MergedInto" ...
            "PosSource" "InLocs" "DetRun" "MatchDistUm" "Label" "LabelSource" "Reviewed" "Flag" "Excluded" "ProposalP" ...
            "ModelP" "ModelVersion" "AuditRole" "Reviewer" "ReviewedAt" "Notes"]
    end

    properties (TestParameter)
        HumanSource = {'human', 'confirmed', 'blind'}
    end

    methods (TestClassSetup)
        function buildFixture(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(here, 'fixtures')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Src = makeSyntheticDataset(fullfile(tmp.Folder, 'pristine'));
        end
    end

    methods (TestMethodSetup)
        function copyFixture(tc)
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = fullfile(tmp.Folder, 'ds');
            copyfile(tc.Src, tc.Dir);
        end
    end

    %% ---- initial state and ids -------------------------------------------------------------------
    methods (Test)
        function freshStoreHasUniqueIdsFromOneAndUnreviewedRows(tc)
            s = tc.openEcm();
            T = s.T;
            tc.verifyEqual(string(T.Properties.VariableNames), tc.Cols, 'column set and order of the contract');
            tc.verifyClass(T.CellID, 'uint32');
            tc.verifyEqual(min(T.CellID), uint32(1), 'CellIDs start at 1');
            tc.verifyEqual(numel(unique(T.CellID)), height(T), 'CellIDs are unique');
            tc.verifyTrue(all(T.State == "active" & T.Origin == "detected" & T.PosSource == "det" & T.InLocs));
            tc.verifyTrue(all(T.Label == "" & ~T.Reviewed & T.MergedInto == 0));
            c = s.counts();
            tc.verifyEqual([c.total c.active c.unreviewed c.kept c.reviewed], [height(T) height(T) height(T) 0 0]);
            tc.verifyEqual(s.Meta.NextCellId, double(max(T.CellID)) + 1);
            tc.verifyFalse(s.CanUndo);
            tc.verifyFalse(s.CanRedo);
        end
    end

    %% ---- labels and the kept rule ---------------------------------------------------------------
    methods (Test)
        function humanSourcesMakeAGoodRowKeptAndReviewed(tc, HumanSource)
            s = tc.openEcm();
            id = s.T.CellID(3);
            s.setLabel(id, 'Good', HumanSource);
            r = tc.rowOf(s, id);
            tc.verifyEqual([r.Label r.LabelSource], ["Good" string(HumanSource)]);
            tc.verifyTrue(r.Reviewed, 'human/confirmed/blind set Reviewed');
            tc.verifyEqual(r.Reviewer, "tester");
            tc.verifyNotEqual(r.ReviewedAt, "", 'ReviewedAt is stamped');
            tc.verifyTrue(ismember(id, s.kept().CellID), 'Good + Reviewed + source in {human,confirmed,blind} is kept');
        end

        function autoSourceMayOnlyCarryBadAndLeavesUnreviewed(tc)
            s = tc.openEcm();
            id = s.T.CellID(4);
            tc.verifyError(@() s.setLabel(id, 'Good', 'auto'), ?MException, 'auto may never produce Good');
            tc.verifyEqual(tc.rowOf(s, id).Label, "", 'the failed call must not change the row');
            s.setLabel(id, 'Bad', 'auto');
            r = tc.rowOf(s, id);
            tc.verifyEqual([r.Label r.LabelSource], ["Bad" "auto"]);
            tc.verifyFalse(r.Reviewed, 'auto leaves Reviewed false');
            tc.verifyFalse(ismember(id, s.kept().CellID));
            tc.verifyEqual(s.counts().autoRejected, 1);
        end

        function uncertainAndBadAreReviewedButNotKept(tc)
            s = tc.openEcm();
            ids = s.T.CellID(1:2);
            s.setLabel(ids(1), 'Uncertain', 'human');
            s.setLabel(ids(2), 'Bad', 'human');
            tc.verifyTrue(all(tc.rowsOf(s, ids).Reviewed));
            tc.verifyEmpty(intersect(ids, s.kept().CellID), 'only Good is kept');
        end

        function clearingALabelUnreviewsTheRow(tc)
            s = tc.openEcm();
            id = s.T.CellID(5);
            s.setLabel(id, 'Good', 'human');
            s.setLabel(id, "", 'human');
            r = tc.rowOf(s, id);
            tc.verifyEqual(r.Label, "");
            tc.verifyFalse(r.Reviewed, 'clearing a label sets Reviewed=false');
            tc.verifyFalse(ismember(id, s.kept().CellID));
        end

        function labellingSeveralIdsAtOnce(tc)
            s = tc.openEcm();
            ids = s.T.CellID(10:19);
            s.setLabel(ids, 'Good', 'confirmed');
            r = tc.rowsOf(s, ids);
            tc.verifyTrue(all(r.Label == "Good" & r.Reviewed & r.LabelSource == "confirmed"));
            tc.verifyEqual(s.counts().kept, numel(ids));
        end

        function contextIsStoredAndJournalled(tc)
            s = tc.openEcm();
            id = s.T.CellID(2);
            s.setLabel(id, 'Good', 'human', struct('ProposalP', 0.7, 'Queue', 'Middle', 'PageId', 'pg3', 'DwellMs', 1234));
            tc.verifyEqual(tc.rowOf(s, id).ProposalP, 0.7, 'AbsTol', 1e-12);
            J = readJournalTable(s.Paths.journal);
            L = J(double(J.CellID) == double(id) & J.Field == "Label", :);
            tc.assertEqual(height(L), 1, 'one journal line for the changed Label field');
            tc.verifyEqual([L.Old L.New], ["" "Good"]);
            tc.verifyEqual(L.Queue, "Middle");
            tc.verifyEqual(L.PageId, "pg3");
            tc.verifyEqual(double(L.DwellMs), 1234);
            tc.verifyEqual(L.Reviewer, "tester");
        end

        function journalHasContractColumnsAndOneLinePerChangedField(tc)
            s = tc.openEcm();
            id = s.T.CellID(2);
            s.setFlag(id, 'later');
            J = readJournalTable(s.Paths.journal);
            tc.verifyEqual(string(J.Properties.VariableNames), ...
                ["Time" "Reviewer" "Session" "Seq" "Revision" "Action" "CellID" "Field" "Old" "New" "Queue" "PageId" "DwellMs"]);
            L = J(double(J.CellID) == double(id), :);
            tc.verifyEqual(L.Field, "Flag", 'only the changed field is journalled');
            tc.verifyEqual([L.Old L.New], ["" "later"]);
        end

        function flagNoteExcludedAndAuditRole(tc)
            s = tc.openEcm();
            ids = s.T.CellID(1:3);
            s.setFlag(ids, 'recheck');
            s.setNote(ids(1), 'looks like a dendrite');
            rid = excludeAround(s, ids(2:3));           % review finding 6: exclusion = a region
            s.setAuditRole(ids(3), 'holdout');
            r = tc.rowsOf(s, ids);
            tc.verifyEqual(r.Flag, ["recheck"; "recheck"; "recheck"]);
            tc.verifyEqual(r.Notes(1), "looks like a dendrite");
            tc.verifyEqual(r.Excluded, [false; true; true]);
            tc.verifyEqual(r.AuditRole, ["" ; ""; "holdout"]);
            s.setFlag(ids, "");
            for k = 1:numel(rid), s.removeRegion(rid(k)); end
            r = tc.rowsOf(s, ids);
            tc.verifyTrue(all(r.Flag == "") && ~any(r.Excluded), 'flag and exclusion can be cleared');
        end
    end

    %% ---- add, move, merge -------------------------------------------------------------------------
    methods (Test)
        function addCellCreatesAKeptHumanRowWithANewId(tc)
            s = tc.openEcm();
            n0 = height(s.T); maxId = max(s.T.CellID);
            id = s.addCell([123.5 234.25]);
            r = tc.rowOf(s, id);
            tc.verifyGreaterThan(id, maxId);
            tc.verifyEqual(height(s.T), n0 + 1);
            tc.verifyEqual([r.X r.Y], [123.5 234.25]);
            tc.verifyTrue(all(isnan([r.DET_X r.DET_Y])), 'added by hand: no detector position');
            tc.verifyEqual([r.Origin r.PosSource r.State], ["added" "human" "active"]);
            tc.verifyEqual([r.Label r.LabelSource], ["Good" "human"], 'default label of an added cell');
            tc.verifyTrue(r.Reviewed);
            tc.verifyTrue(ismember(id, s.kept().CellID));
            tc.verifyEqual(s.counts().added, 1);
        end

        function addCellSnapPosSourceIsHonoured(tc)
            s = tc.openEcm();
            id = s.addCell([50 60], struct('PosSource', 'snap'));
            tc.verifyEqual(tc.rowOf(s, id).PosSource, "snap");
        end

        function moveCellDefaultsToHumanAndLeavesDetectorPosition(tc)
            s = tc.openEcm();
            r0 = s.T(7, :);
            s.moveCell(r0.CellID, [r0.X + 3, r0.Y - 2]);
            r = tc.rowOf(s, r0.CellID);
            tc.verifyEqual([r.X r.Y], [r0.X + 3, r0.Y - 2], 'AbsTol', 1e-9);
            tc.verifyEqual([r.DET_X r.DET_Y], [r0.DET_X r0.DET_Y], 'moving never touches the detector position');
            tc.verifyEqual(r.PosSource, "human");
            s.moveCell(r0.CellID, [r0.X r0.Y], 'snap');
            tc.verifyEqual(tc.rowOf(s, r0.CellID).PosSource, "snap");
        end

        function mergeMakesLosersMergedNeverBadAndNotKept(tc)
            s = tc.openEcm();
            ids = s.T.CellID(20:22);
            s.setLabel(ids, 'Good', 'human');
            s.mergeCells(ids, ids(2));
            r = tc.rowsOf(s, ids);
            tc.verifyEqual(r.State, ["merged"; "active"; "merged"]);
            tc.verifyEqual(r.MergedInto, uint32([ids(2); 0; ids(2)]));
            tc.verifyFalse(any(r.Label == "Bad"), 'a duplicate loser is merged, never Bad');
            kept = s.kept().CellID;
            tc.verifyEqual(intersect(ids, kept), ids(2), 'only the keeper stays kept');
            c = s.counts();
            tc.verifyEqual([c.merged c.bad c.good], [2 0 1], 'merged rows are not counted as bad or good');
        end

        function mergeWithPositionMovesTheKeeper(tc)
            s = tc.openEcm();
            ids = s.T.CellID(30:31);
            s.mergeCells(ids, ids(1), [11.5 22.5]);
            r = tc.rowOf(s, ids(1));
            tc.verifyEqual([r.X r.Y], [11.5 22.5]);
            tc.verifyEqual(tc.rowOf(s, ids(2)).MergedInto, uint32(ids(1)));
        end

        function unmergeRestoresTheLoser(tc)
            s = tc.openEcm();
            ids = s.T.CellID(40:41);
            s.mergeCells(ids, ids(1));
            s.unmerge(ids(2));
            r = tc.rowOf(s, ids(2));
            tc.verifyEqual(r.State, "active");
            tc.verifyEqual(r.MergedInto, uint32(0));
            tc.verifyEqual(s.counts().merged, 0);
        end

        function keepBothRecordsThePair(tc)
            s = tc.openEcm();
            ids = s.T.CellID(50:51);
            s.keepBoth(ids);
            kp = s.Meta.KeptPairs;
            tc.verifyTrue(all(ismember(double(ids(:)), double(kp(:)))), 'Meta.KeptPairs holds the two ids');
            tc.verifyTrue(all(tc.rowsOf(s, ids).State == "active"), 'keeping both changes no state');
        end
    end

    %% ---- counts ----------------------------------------------------------------------------------
    methods (Test)
        function countsAreConsistentWithTheTable(tc)
            s = tc.openEcm();
            ids = s.T.CellID;
            s.setLabel(ids(1:6), 'Good', 'human');
            s.setLabel(ids(7:9), 'Bad', 'confirmed');
            s.setLabel(ids(10:11), 'Uncertain', 'blind');
            s.setLabel(ids(12:13), 'Bad', 'auto');
            s.setFlag(ids(14:15), 'later');
            excludeAround(s, ids(16));                  % review finding 6: exclusion = a region
            s.mergeCells(ids(17:18), ids(17));
            s.addCell([300 300]);
            T = s.T;
            act = T.State == "active";
            keptMask = act & T.Label == "Good" & T.Reviewed & ismember(T.LabelSource, ["human" "confirmed" "blind" "legacy-qc"]);
            c = s.counts();
            tc.verifyEqual(c.total, height(T), 'total');
            tc.verifyEqual(c.active, nnz(act), 'active');
            tc.verifyEqual(c.reviewed, nnz(act & T.Reviewed), 'reviewed');
            tc.verifyEqual(c.unreviewed, nnz(act & ~T.Reviewed), 'unreviewed');
            tc.verifyEqual(c.good, nnz(act & T.Label == "Good"), 'good');
            tc.verifyEqual(c.bad + c.autoRejected, nnz(act & T.Label == "Bad"), 'bad (person-decided) + autoRejected = all Bad rows');
            tc.verifyEqual(c.uncertain, nnz(act & T.Label == "Uncertain"), 'uncertain');
            tc.verifyEqual(c.kept, nnz(keptMask), 'kept');
            tc.verifyEqual(c.autoRejected, nnz(act & T.LabelSource == "auto"), 'autoRejected');
            tc.verifyEqual(c.flagged, nnz(act & T.Flag ~= ""), 'flagged');
            tc.verifyEqual(c.merged, nnz(T.State == "merged"), 'merged');
            tc.verifyEqual(c.added, nnz(T.Origin == "added"), 'added');
            tc.verifyEqual(c.stale, nnz(T.State == "stale"), 'stale');
            tc.verifyEqual(c.excluded, nnz(act & T.Excluded), 'excluded');
            tc.verifyTrue(isfield(c, 'vanishedGood'));
            tc.verifyEqual(sort(s.kept().CellID), sort(T.CellID(keptMask)), 'kept() agrees with the kept rule');
            tc.verifyEqual(c.reviewed + c.unreviewed, c.active, 'reviewed + unreviewed = active');
        end

        function keptAndRowsOfAndExportFinal(tc)
            s = tc.openEcm();
            ids = s.T.CellID(1:6);
            s.setLabel(ids(1:3), 'Good', 'human');
            s.setLabel(ids(4), 'Bad', 'human');
            s.mergeCells(ids(1:2), ids(1));
            r = s.rowsOf(ids(3:-1:1));
            tc.verifyEqual(s.T.CellID(r), uint32(ids(3:-1:1)), 'rowsOf locates the rows of the ids, in the order asked');
            f = fullfile(tc.Dir, 'export_final.csv');
            s.exportFinal(f);
            tc.assertTrue(isfile(f));
            E = readtable(f, 'TextType', 'string');
            tc.verifyEqual(string(E.Properties.VariableNames), ["X" "Y" "class" "score" "imgName" "thr" "rescore" "CellID"]);
            k = s.kept();
            tc.verifyEqual(sort(double(E.CellID)), sort(double(k.CellID)), 'kept rows only');
            tc.verifyEqual(sort(double(E.CellID)), sort(double(ids([1 3]))), 'keeper and the other Good, not the merged loser or the Bad');
            [~, loc] = ismember(double(E.CellID), double(s.T.CellID));
            tc.verifyEqual([E.X E.Y], [s.T.X(loc) s.T.Y(loc)], 'AbsTol', 1e-6);
        end
    end

    %% ---- undo and redo ---------------------------------------------------------------------------
    methods (Test)
        function undoRedoOfALabelRestoresEveryField(tc)
            s = tc.openEcm();
            id = s.T.CellID(3);
            s.setLabel(id, 'Bad', 'human');                   % a prior state with reviewer fields set
            tc.undoRedoRoundTrip(s, @() s.setLabel(id, 'Good', 'confirmed'));
        end

        function undoRedoOfLabelOnVirginRow(tc)
            s = tc.openEcm();
            ids = s.T.CellID(5:8);
            tc.undoRedoRoundTrip(s, @() s.setLabel(ids, 'Good', 'blind', struct('ProposalP', 0.4)));
        end

        function undoRedoOfClearingALabel(tc)
            s = tc.openEcm();
            id = s.T.CellID(3);
            s.setLabel(id, 'Good', 'human');
            tc.undoRedoRoundTrip(s, @() s.setLabel(id, "", 'human'));
        end

        function undoRedoOfMove(tc)
            s = tc.openEcm();
            r = s.T(9, :);
            tc.undoRedoRoundTrip(s, @() s.moveCell(r.CellID, [r.X + 5 r.Y + 5]));
        end

        function undoRedoOfFlagNoteExcludedAudit(tc)
            s = tc.openEcm();
            id = s.T.CellID(11);
            tc.undoRedoRoundTrip(s, @() s.setFlag(id, 'later'));
            tc.undoRedoRoundTrip(s, @() s.setNote(id, 'note one'));
            tc.undoRedoRoundTrip(s, @() excludeAround(s, id));   % review finding 6
            tc.undoRedoRoundTrip(s, @() s.setAuditRole(id, 'catch'));
        end

        function undoRedoOfMergeUnmergeAndKeepBoth(tc)
            s = tc.openEcm();
            ids = s.T.CellID(20:22);
            s.setLabel(ids, 'Good', 'human');
            tc.undoRedoRoundTrip(s, @() s.mergeCells(ids, ids(2), [5 6]));
            s.mergeCells(ids(1), ids(2));
            tc.undoRedoRoundTrip(s, @() s.unmerge(ids(1)));
            kp0 = s.Meta.KeptPairs;
            s.keepBoth(ids(2:3));
            tc.verifyTrue(s.undo());
            tc.verifyEqual(s.Meta.KeptPairs, kp0, 'undo of keepBoth restores KeptPairs');
            tc.verifyTrue(s.redo());
            tc.verifyTrue(all(ismember(double(ids(2:3)), double(s.Meta.KeptPairs(:)))));
        end

        function undoRedoOfAddCellMakesTheRowDisappearAndReappear(tc)
            s = tc.openEcm();
            T0 = sortrows(s.T, 'CellID');
            id = s.addCell([77 88]);
            T1 = sortrows(s.T, 'CellID');
            tc.verifyTrue(s.undo());
            tc.verifyEqual(sortrows(s.T, 'CellID'), T0, 'undo of an add removes the row');
            tc.verifyFalse(ismember(id, s.T.CellID));
            tc.verifyTrue(s.redo());
            tc.verifyEqual(sortrows(s.T, 'CellID'), T1, 'redo brings the same row back');
            tc.verifyTrue(ismember(id, s.T.CellID));
        end

        function idsAreNeverReusedAfterUndoOfAnAdd(tc)
            s = tc.openEcm();
            id1 = s.addCell([10 10]);
            s.undo();
            id2 = s.addCell([20 20]);
            tc.verifyNotEqual(id2, id1, 'an id handed out is never reused, even after undo');
            tc.verifyGreaterThan(id2, id1);
            tc.verifyEqual(s.Meta.NextCellId, double(id2) + 1);
        end

        function undoRedoOfSweepDoneAndComplete(tc)
            s = tc.openEcm();
            tc.verifyFalse(s.Meta.SweepDone);
            tc.verifyFalse(s.Meta.Complete);
            s.setSweepDone(true);
            tc.verifyTrue(s.Meta.SweepDone);
            s.setComplete(true);
            tc.verifyTrue(s.Meta.Complete);
            tc.verifyTrue(s.undo());
            tc.verifyFalse(s.Meta.Complete, 'undo restores the complete flag');
            tc.verifyTrue(s.Meta.SweepDone);
            tc.verifyTrue(s.undo());
            tc.verifyFalse(s.Meta.SweepDone, 'undo restores the sweep flag');
            tc.verifyTrue(s.redo());
            tc.verifyTrue(s.Meta.SweepDone);
            J = readJournalTable(s.Paths.journal);
            tc.verifyGreaterThanOrEqual(height(J), 2, 'sweep/complete changes are journalled');
        end

        function undoOnEmptyHistoryReturnsFalse(tc)
            s = tc.openEcm();
            tc.verifyFalse(s.undo());
            tc.verifyFalse(s.redo());
        end

        function aNewActionAfterUndoClearsRedo(tc)
            s = tc.openEcm();
            ids = s.T.CellID(1:2);
            s.setLabel(ids(1), 'Good', 'human');
            s.undo();
            tc.verifyTrue(s.CanRedo);
            s.setLabel(ids(2), 'Bad', 'human');
            tc.verifyFalse(s.CanRedo, 'a new action clears redo');
            tc.verifyFalse(s.redo());
            tc.verifyEqual(tc.rowOf(s, ids(1)).Label, "");
        end

        function aBatchIsOneUndoStep(tc)
            s = tc.openEcm();
            ids = s.T.CellID(1:4);
            T0 = sortrows(s.T, 'CellID');
            s.beginBatch('three edits');
            s.setLabel(ids(1:2), 'Good', 'human');
            s.setFlag(ids(3), 'later');
            s.moveCell(ids(4), [1 2]);
            s.endBatch();
            T1 = sortrows(s.T, 'CellID');
            tc.verifyNotEqual(T1, T0);
            tc.verifyTrue(s.undo());
            tc.verifyEqual(sortrows(s.T, 'CellID'), T0, 'one undo reverts the whole batch');
            tc.verifyFalse(s.CanUndo, 'the batch was a single step');
            tc.verifyTrue(s.redo());
            tc.verifyEqual(sortrows(s.T, 'CellID'), T1, 'one redo re-applies the whole batch');
        end

        function setModelIsDerivedNotUndoableNotJournalled(tc)
            s = tc.openEcm();
            ids = s.T.CellID(1:3);
            s.setLabel(ids(1), 'Good', 'human');
            nJournal = height(readJournalTable(s.Paths.journal));
            s.setModel(ids, [0.1; 0.5; 0.9], 'v1');
            r = tc.rowsOf(s, ids);
            tc.verifyEqual(r.ModelP, [0.1; 0.5; 0.9], 'AbsTol', 1e-12);
            tc.verifyEqual(r.ModelVersion, ["v1"; "v1"; "v1"]);
            tc.verifyEqual(height(readJournalTable(s.Paths.journal)), nJournal, 'setModel is not journalled');
            tc.verifyTrue(s.undo(), 'the earlier label is the undo step');
            tc.verifyEqual(tc.rowOf(s, ids(1)).Label, "");
            tc.verifyEqual(tc.rowsOf(s, ids).ModelP, [0.1; 0.5; 0.9], 'AbsTol', 1e-12, 'undo does not touch model predictions');
            tc.verifyFalse(s.undo(), 'setModel added nothing to the undo stack');
        end

        function undoDepthOfFiveHundredSteps(tc)
            s = tc.openEcm();
            id = s.T.CellID(1);
            T0 = sortrows(s.T, 'CellID');
            labs = ["Good" "Bad"];
            for k = 1:500
                s.setLabel(id, char(labs(mod(k, 2) + 1)), 'human');
            end
            ok = true;
            for k = 1:500
                ok = s.undo() && ok;
            end
            tc.verifyTrue(ok, 'all 500 steps must be undoable');
            tc.verifyEqual(sortrows(s.T, 'CellID'), T0, 'after 500 undos the original table is back');
            tc.verifyFalse(s.CanUndo);
        end

        function changedEventFiresOncePerTransaction(tc)
            s = tc.openEcm();
            tc.EvN = 0; tc.EvLast = [];
            lh = addlistener(s, 'Changed', @(~, e) tc.onChanged(e));
            tc.addTeardown(@() delete(lh));
            ids = s.T.CellID(1:3);
            s.setLabel(ids, 'Good', 'human');
            tc.verifyEqual(tc.EvN, 1, 'one event per transaction, however many cells');
            s.beginBatch('b'); s.setFlag(ids(1), 'later'); s.setNote(ids(2), 'x'); s.endBatch();
            tc.verifyEqual(tc.EvN, 2, 'a batch fires one event');
            s.undo();
            tc.verifyEqual(tc.EvN, 3, 'undo fires an event');
            tc.verifyNotEmpty(tc.EvLast, 'the event carries a change set');
        end
    end

    methods (Access = private)
        function onChanged(tc, e)
            tc.EvN = tc.EvN + 1;
            tc.EvLast = e;
        end

        function undoRedoRoundTrip(tc, s, fcn)
            T0 = sortrows(s.T, 'CellID');
            M0 = metaState(s.Meta);
            fcn();
            T1 = sortrows(s.T, 'CellID');
            M1 = metaState(s.Meta);
            tc.verifyTrue(s.CanUndo);
            tc.verifyTrue(s.undo());
            tc.verifyEqual(sortrows(s.T, 'CellID'), T0, 'undo must restore every field exactly');
            tc.verifyEqual(metaState(s.Meta), M0, 'undo must restore sweep/complete/kept pairs');
            tc.verifyTrue(s.CanRedo);
            tc.verifyTrue(s.redo());
            tc.verifyEqual(sortrows(s.T, 'CellID'), T1, 'redo must re-apply every field exactly');
            tc.verifyEqual(metaState(s.Meta), M1);
        end

        function row = rowOf(~, s, id)
            row = s.T(s.T.CellID == id, :);
        end

        function rows = rowsOf(~, s, ids)
            [tf, loc] = ismember(ids, s.T.CellID);
            assert(all(tf));
            rows = s.T(loc, :);
        end

        function s = openEcm(tc)
            csv = fullfile(tc.Dir, sprintf('%s_proj_ECM1_locs.csv', tc.Base));
            mf = CellDatasetManifest.forCsv(csv);
            s = curation.Store.open(mf, 'ECM1', mkOpts());
            tc.addTeardown(@() closeQuiet(s));
        end
    end
end

%% ---- helpers ---------------------------------------------------------------------------------

function m = metaState(M)
m = struct('SweepDone', M.SweepDone, 'Complete', M.Complete, 'KeptPairs', {M.KeptPairs});
end

function J = readJournalTable(f)
opts = detectImportOptions(f, 'TextType', 'string');
opts = setvartype(opts, opts.VariableNames, 'string');
J = readtable(f, opts);
for v = ["Old" "New" "Queue" "PageId" "Reviewer" "Field" "Action"]
    if ismember(v, string(J.Properties.VariableNames))
        J.(char(v)) = fillmissing(J.(char(v)), 'constant', "");
    end
end
end

function rid = excludeAround(s, ids)
%excludeAround  Exclude cells the way the store allows since review finding 6: Excluded follows the
%   exclusion regions, so a small exclude region of this source goes around each cell (one batch,
%   one undo step). setExcluded can no longer set a state the regions contradict.
rid = zeros(numel(ids), 1);
s.beginBatch("Exclude");
for k = 1:numel(ids)
    x = s.get('X', ids(k)); y = s.get('Y', ids(k));
    rid(k) = s.addRegion(struct('kind', 'exclude', 'scope', s.Meta.Key, ...
        'xy', [x - 0.5, y - 0.5; x + 0.5, y - 0.5; x + 0.5, y + 0.5; x - 0.5, y + 0.5]));
end
s.endBatch();
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
