classdef tStoreRescore < matlab.unittest.TestCase
%tStoreRescore  curation.Store keeps each cell's Stage-2 rescore together with what produced it
%   (column RescoreSource): "detector" (the locs file, at the row's detector position), a scoring
%   model's name (computed by curation.Rescore for the row's effective position, stored with
%   setRescore) or "" (pending: no valid score for the current position).
%     schema / rows from the locs / counts().rescorePending / rescorePending()
%     setRescore: values and model stored, NaN = pending, validated before writing, not undoable,
%       Changed Kind "rescore", journaled and replayed after a crash, round trip through the snapshot
%     moves and merges: the score of a moved cell becomes pending, the detector's comes back when
%       the cell is put back on its detector position; undo/redo restore value and source exactly
%     reconcile: rows that follow the detector are refreshed; a person's position keeps its own
%       score while score and DET_X/Y are refreshed; appended rows
%     a snapshot written before the column existed (with an older journal) opens, is filled by the
%       rule and rewritten
%     rescorePending vs curation.Rescore.pending on a store with every case
%     Benchmark: setRescore on 150 ids of a 2,000-row source with the journal (budget 15 ms)
%
%   Run: pwsh -File tools\Run-Tests.ps1 tStoreRescore [-IncludeSlow for the Benchmark test]

    properties
        Dir char = ''
        Events cell = {}
    end

    properties (Constant)
        Model = "pnn_v2_scoring_ordinal_regression"
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
            tc.Events = {};
        end
    end

    %% ---- schema and rows from the locs ---------------------------------------------------------
    methods (Test)
        function schemaPlacesRescoreSourceRightAfterRescore(tc)
            c = curation.Store.COLUMNS;
            k = find(c == "rescore");
            tc.assertNumElements(k, 1);
            tc.verifyEqual(c(k + 1), "RescoreSource");
            tc.verifyEqual(curation.Store.TYPES(k + 1), "string");
            tc.verifyEqual(numel(curation.Store.TYPES), numel(c));
            S = curation.Store.schema();
            tc.verifyEqual(S.Name, c(:));
            tc.verifyEqual(S.Type, curation.Store.TYPES(:));
            tc.verifyEqual(S.Type(k + 1), "string");
            tc.verifyEqual(S.Default(k + 1), """""");
            tc.verifyTrue(contains(S.Meaning(k + 1), "detector"));
        end

        function rowsFromTheLocsAreDetectorOrPending(tc)
            s = tc.mem(mkLocs([100 100; 200 100; 300 100], [1.5; NaN; -2]));
            tc.verifyClass(s.T.RescoreSource, 'string');
            tc.verifyEqual(s.get('RescoreSource', 1:3), ["detector"; ""; "detector"]);
            tc.verifyEqual(s.rescorePending(), uint32(2), 'a detection without a rescore is pending');
            c = s.counts();
            tc.verifyTrue(isfield(c, 'rescorePending'));
            tc.verifyEqual(c.rescorePending, 1);
            L = removevars(mkLocs([100 100; 200 100]), 'rescore');
            s2 = tc.mem(L);
            tc.verifyTrue(all(isnan(s2.get('rescore'))));
            tc.verifyEqual(s2.get('RescoreSource'), ["", ""]');
            tc.verifyEqual(s2.counts().rescorePending, 2);
        end

        function addedCellsArePendingAndCounted(tc)
            s = tc.mem(mkLocs([100 100; 200 100]));
            ids = s.addCell([150 300; 160 310], struct('Label', ""));
            tc.verifyTrue(all(isnan(s.get('rescore', ids))));
            tc.verifyEqual(s.get('RescoreSource', ids), ["", ""]');
            tc.verifyEqual(sort(s.rescorePending()), sort(ids));
            tc.verifyEqual(s.counts().rescorePending, 2);
            s.mergeCells(ids, ids(1));                    % merged-away rows are not pending
            tc.verifyEqual(s.rescorePending(), ids(1));
            tc.verifyEqual(s.counts().rescorePending, 1);
        end
    end

    %% ---- setRescore ------------------------------------------------------------------------------
    methods (Test)
        function setRescoreStoresValueAndModelAndIsNotAUserAction(tc)
            s = tc.mem(mkLocs([100 100; 200 100; 300 100; 400 100], [1; 2; 3; 4]));
            a = s.addCell([150 150]);
            s.moveCell(2, [210 100]);
            tc.verifyEqual(sort(s.rescorePending()), sort(uint32([2; a])));
            lh = addlistener(s, 'Changed', @(~, e) tc.note(e));
            tc.addTeardown(@() delete(lh));
            rev = s.Meta.Revision;
            s.setRescore([a; 2], [0.75; -1.25], tc.Model);
            tc.verifyEqual(s.get('rescore', [a; 2]), [0.75; -1.25]);
            tc.verifyEqual(s.get('RescoreSource', [a; 2]), [tc.Model; tc.Model]);
            tc.verifyEmpty(s.rescorePending());
            tc.verifyEqual(s.counts().rescorePending, 0);
            tc.verifyGreaterThan(s.Meta.Revision, rev, 'a new revision: saved with the next snapshot');
            tc.assertNumElements(tc.Events, 1, 'one Changed event');
            e = tc.Events{1};
            tc.verifyEqual(e.Kind, "rescore", 'a Kind the GUI can tell from a user action');
            tc.verifyEqual(sort(e.CellIDs), sort(uint32([2; a])));
            tc.verifyTrue(all(ismember(["RescoreSource" "rescore"], e.Fields)));
            tc.verifyFalse(e.FullRefresh);
            tc.verifyEqual(e.ChangeSet.Action, "setRescore");
            % not undoable: undo reverts the move (the last user action), not the scores
            tc.verifyTrue(s.undo());
            tc.verifyEqual([s.get('X', 2) s.get('Y', 2)], [200 100]);
            tc.verifyEqual(s.get('rescore', 2), 2, 'back on its detector position: the detector''s value');
            tc.verifyEqual(s.get('RescoreSource', 2), "detector");
            tc.verifyEqual(s.get('rescore', a), 0.75, 'the added cell keeps its score');
            tc.verifyEqual(s.get('RescoreSource', a), tc.Model);
            tc.verifyTrue(s.undo(), 'the add is the next undo step');
            tc.verifyFalse(s.CanUndo, 'setRescore left no undo step of its own');
        end

        function setRescoreNaNMeansPendingAndDuplicatesApplyOnce(tc)
            s = tc.mem(mkLocs([100 100; 200 100; 300 100], [1; 2; 3]));
            s.setRescore([1; 2], [NaN; 5], "C:\models\" + tc.Model);   % a model folder path: its name
            tc.verifyTrue(isnan(s.get('rescore', 1)), 'NaN: could not be scored');
            tc.verifyEqual(s.get('RescoreSource', 1:2), [""; tc.Model]);
            tc.verifyEqual(s.rescorePending(), uint32(1));
            s.setRescore([3; 3], [7; 8], tc.Model);                    % duplicate ids: applied once
            tc.verifyEqual(s.get('rescore', 3), 7);
            rev = s.Meta.Revision;
            s.setRescore(1, NaN, "");                                  % all NaN: no model name needed
            s.setRescore([], [], "");
            tc.verifyEqual(s.Meta.Revision, rev, 'nothing changed: no revision');
        end

        function setRescoreValidatesBeforeWriting(tc)
            s = tc.mem(mkLocs([100 100; 200 100; 300 100], [1; 2; 3]));
            T0 = s.T; rev = s.Meta.Revision;
            tc.verifyError(@() s.setRescore([1; 99], [1; 2], tc.Model), 'curation:Store:unknownId');
            tc.verifyError(@() s.setRescore([1; 2], [1; 2; 3], tc.Model), 'curation:Store:badArgument');
            tc.verifyError(@() s.setRescore([1; 2], 1, tc.Model), 'curation:Store:badArgument');
            tc.verifyError(@() s.setRescore([1; 2], ["a"; "b"], tc.Model), 'curation:Store:badArgument');
            tc.verifyError(@() s.setRescore(1, 1i, tc.Model), 'curation:Store:badArgument');
            tc.verifyError(@() s.setRescore(1, Inf, tc.Model), 'curation:Store:badArgument');
            tc.verifyError(@() s.setRescore(1, 2, ""), 'curation:Store:badArgument');
            tc.verifyError(@() s.setRescore(1, 2), 'curation:Store:badArgument');
            tc.verifyError(@() s.setRescore(1, 2, ["a" "b"]), 'curation:Store:badArgument');
            tc.verifyError(@() s.setRescore(1, 2, 7), 'curation:Store:badArgument');
            tc.verifyError(@() s.setRescore(1, 2, "detector"), 'curation:Store:badArgument');
            s.beginBatch("page");
            tc.verifyError(@() s.setRescore(1, 2, tc.Model), 'curation:Store:inBatch');
            s.endBatch();
            tc.verifyEqual(s.T, T0, 'nothing was written');
            tc.verifyEqual(s.Meta.Revision, rev);
            % read-only and closed stores
            path = writeLocs(tc.Dir, 'secV_proj_PV2', mkLocs([100 100; 200 100]));
            w = tc.openP(path);
            r = tc.openP(path);
            tc.assertTrue(r.ReadOnly);
            tc.verifyError(@() r.setRescore(1, 2, tc.Model), 'curation:Store:readOnly');
            w.close();
            tc.verifyError(@() w.setRescore(1, 2, tc.Model), 'curation:Store:closed');
        end

        function setRescoreSurvivesACrash(tc)
            name = 'secA_proj_PV2';
            path = writeLocs(tc.Dir, name, mkLocs([100 100; 200 100; 300 100; 400 100; 500 100]));
            s = tc.openP(path);
            s.setLabel(1, "Good");
            s.flush();
            a = s.addCell([555 444]);
            s.moveCell(2, [205 100]);
            s.setRescore([a; 2], [0.5; 1.5], tc.Model);
            s.moveCell(3, [304 100]);
            s.setRescore(4, 9.25, "other_scorer");                    % a detection re-scored by a model
            s.setRescore(5, NaN, "");                                 % could not be scored
            T1 = s.T;
            tc.verifyTrue(s.Dirty, 'precondition: the snapshot is older than the journal');
            crash = crashCopy(tc.Dir);
            s.close();
            c = tc.openP(fullfile(crash, [name '_locs.csv']));
            tc.verifyFalse(c.ReadOnly);
            verifyTablesEqual(tc, c.T, T1);
            tc.verifyEqual(c.get('RescoreSource', [a; 2; 3; 4; 5]), [tc.Model; tc.Model; ""; "other_scorer"; ""]);
            R = curation.Journal.read(c.Paths.journal, 0);
            k = R.Action == "setRescore" & R.Field == "RescoreSource";
            tc.verifyEqual(sort(str2double(R.CellID(k))), sort(double([a; 2; 4; 5])), ...
                'setRescore is journaled as its own transaction');
        end

        function rescoreSourceRoundTripsThroughTheSnapshot(tc)
            path = writeLocs(tc.Dir, 'secR_proj_PV2', mkLocs([100 100; 200 100; 300 100; 400 100]));
            s = tc.openP(path);
            a = s.addCell([150 300]);
            s.setRescore(a, 0.1 + 1/3, "pnn_v3,scorer ""b""");         % CSV quoting
            s.moveCell(2, [222 100]);
            s.setRescore(3, 2.5, tc.Model);
            s.flush();
            T1 = s.T;
            csv = s.Paths.csv;
            s.close();
            lines = readlines(csv, 'EmptyLineRule', 'skip');
            hdr = split(lines(1), ',')';
            k = find(hdr == "rescore");
            tc.verifyEqual(hdr(k + 1), "RescoreSource", 'the column follows rescore in the file');
            s2 = tc.openP(path);
            verifyTablesEqual(tc, s2.T, T1);
            tc.verifyFalse(s2.Dirty);
            tc.verifyFalse(any(contains(s2.LastReconcile.warnings, "RescoreSource")), 'no upgrade warning');
            tc.verifyEqual(s2.get('RescoreSource', [a; 2; 3; 4]), ["pnn_v3,scorer ""b"""; ""; tc.Model; "detector"]);
            tc.verifyEqual(s2.get('rescore', a), 0.1 + 1/3, 'shortest round-trip text');
            R = readtable(csv, 'TextType', 'string', 'VariableNamingRule', 'preserve', 'Delimiter', ',');
            tc.verifyEqual(R.RescoreSource(R.CellID == 3), tc.Model, 'readers by column name see it');
        end
    end

    %% ---- moves, merges, undo/redo -----------------------------------------------------------------
    methods (Test)
        function movesInvalidateAndUndoRedoRestoreExactly(tc)
            s = tc.mem(mkLocs([100 100; 200 100; 300 100; 400 100; 500 100; 600 100], (1:6)' + 0.25));
            s.moveCell(1, [110 100]);
            tc.verifyTrue(isnan(s.get('rescore', 1)), 'moved: the detector''s value is for another position');
            tc.verifyEqual(s.get('RescoreSource', 1), "");
            s.undo();
            tc.verifyEqual([s.get('rescore', 1) s.get('X', 1)], [1.25 100]);
            tc.verifyEqual(s.get('RescoreSource', 1), "detector");
            s.redo();
            tc.verifyTrue(isnan(s.get('rescore', 1)));
            tc.verifyEqual(s.get('RescoreSource', 1), "");
            s.moveCell(1, [100 100], "det");                         % back on its detector position
            tc.verifyEqual(s.get('rescore', 1), 1.25, 'the detector''s value is restored');
            tc.verifyEqual(s.get('RescoreSource', 1), "detector");
            s.undo();
            tc.verifyEqual(s.get('X', 1), 110);
            tc.verifyTrue(isnan(s.get('rescore', 1)));
            tc.verifyEqual(s.get('RescoreSource', 1), "");
            % within 0.01 px: not a move of the score
            s.moveCell(2, [200.005 100]);
            tc.verifyEqual(s.get('rescore', 2), 2.25);
            tc.verifyEqual(s.get('RescoreSource', 2), "detector");
            % a merge that moves the keeper; the merged-away row did not move
            s.mergeCells([3 4], 3, [350 100]);
            tc.verifyTrue(isnan(s.get('rescore', 3)));
            tc.verifyEqual(s.get('RescoreSource', 3:4), [""; "detector"]);
            tc.verifyEqual(s.get('rescore', 4), 4.25);
            s.undo();
            tc.verifyEqual(s.get('rescore', 3), 3.25);
            tc.verifyEqual(s.get('RescoreSource', 3), "detector");
            s.mergeCells([3 4], 3);                                  % no xy: the keeper keeps its score
            tc.verifyEqual(s.get('RescoreSource', 3), "detector");
            % a model's score is dropped by a move and comes back with its undo
            s.moveCell(5, [510 100]);
            s.setRescore(5, 55.5, tc.Model);
            s.moveCell(5, [520 100]);
            tc.verifyTrue(isnan(s.get('rescore', 5)));
            tc.verifyEqual(s.get('RescoreSource', 5), "");
            s.undo();
            tc.verifyEqual([s.get('X', 5) s.get('rescore', 5)], [510 55.5]);
            tc.verifyEqual(s.get('RescoreSource', 5), tc.Model);
            s.redo();
            tc.verifyTrue(isnan(s.get('rescore', 5)));
            tc.verifyEqual(s.get('RescoreSource', 5), "");
            % scored after a move that found the cell pending already: undoing that move does not
            % carry the score (made for the new position) back to the old one
            a = s.addCell([700 300]);
            s.moveCell(a, [720 300]);
            s.setRescore(a, 7.5, tc.Model);
            s.undo();
            tc.verifyEqual(s.get('X', a), 700);
            tc.verifyTrue(isnan(s.get('rescore', a)));
            tc.verifyEqual(s.get('RescoreSource', a), "");
            s.redo();
            tc.verifyEqual(s.get('X', a), 720);
            tc.verifyTrue(isnan(s.get('rescore', a)), 'redo cannot know the score is still valid: pending');
            tc.verifyEqual(s.get('RescoreSource', a), "");
        end

        function movesAreJournaledWithTheirScore(tc)
            name = 'secM_proj_PV2';
            path = writeLocs(tc.Dir, name, mkLocs([100 100; 200 100; 300 100], [1; 2; 3]));
            s = tc.openP(path);
            s.moveCell(1, [130 100]);
            s.mergeCells([2 3], 2, [250 100]);
            s.undo();
            s.moveCell(3, [300 100.004]);                            % within 0.01 px
            T1 = s.T;
            crash = crashCopy(tc.Dir);
            s.close();
            c = tc.openP(fullfile(crash, [name '_locs.csv']));
            verifyTablesEqual(tc, c.T, T1);
            tc.verifyEqual(c.get('RescoreSource', 1:3), [""; "detector"; "detector"]);
        end

        function backOnTheDetectorPositionAfterAReopenReadsTheLocs(tc)
            L = mkLocs([100 100; 200 100; 300 100], [1.5; 2.5; 3.5]);
            path = writeLocs(tc.Dir, 'secB_proj_PV2', L);
            s = tc.openP(path);
            s.moveCell([1; 2], [130 100; 230 100]);
            s.close();
            s2 = tc.openP(path);
            tc.assertEqual(s2.get('RescoreSource', [1; 2]), [""; ""]);
            s2.moveCell(1, [100 100], "det");
            tc.verifyEqual(s2.get('rescore', 1), 1.5, 'the value of the locs file the rows match');
            tc.verifyEqual(s2.get('RescoreSource', 1), "detector");
            s2.close();
            % the locs file changed since the last reconcile: its values are not this run's -> pending
            s3 = tc.openP(path);
            L2 = [L; mkLocs([900 900], 9)];
            L2.rescore(2) = 99;
            writetable(L2, path);
            s3.moveCell(2, [200 100], "det");
            tc.verifyTrue(isnan(s3.get('rescore', 2)));
            tc.verifyEqual(s3.get('RescoreSource', 2), "");
        end
    end

    %% ---- reconcile -------------------------------------------------------------------------------
    methods (Test)
        function reconcileRefreshesDetectorFollowersAndLeavesAPersonsScore(tc)
            L0 = mkLocs([100 100; 200 100; 300 100; 400 100; 500 100; 600 100; 700 100], (1:7)', ...
                (1:7)' / 10);
            s = tc.mem(L0);
            s.moveCell(2, [203 100], "snap");                        % snapped away, then scored
            s.setRescore(2, 22, tc.Model);
            s.moveCell(3, [305 100]);                                % a person's position, scored
            s.setRescore(3, 33, tc.Model);
            s.moveCell(4, [404 100]);                                % scored where the new detection will be
            s.setRescore(4, 44, tc.Model);
            s.moveCell(5, [500.005 100]);                            % human, still on its detector position
            s.setLabel(7, "Good");                                   % vanishes but is kept
            a = s.addCell([800 300], struct('PosSource', "snap"));   % added, then detected
            s.setRescore(a, 88, tc.Model);
            h = s.addCell([800 500]);                                % added by hand, never detected
            s.setRescore(h, 99, tc.Model);
            L1 = mkLocs([100.5 100; 200.5 100; 300.5 100; 404 100; 502 100; 801 300; 900 100; 1000 100], ...
                [11; 12; 13; 14; 15; 18; 19; NaN], [0.11; 0.12; 0.13; 0.14; 0.15; 0.18; 0.19; 0.2]);
            rep = s.reconcile(L1);
            tc.assertTrue(rep.Ran);
            g = @(f, id) s.get(f, id);
            % 1: follows the detector -> refreshed
            tc.verifyEqual([g('X', 1) g('rescore', 1)], [100.5 11]);
            tc.verifyEqual(g('RescoreSource', 1), "detector");
            % 2: snapped rows follow the detector in a reconcile -> refreshed, the model's value replaced
            tc.verifyEqual([g('X', 2) g('rescore', 2)], [200.5 12]);
            tc.verifyEqual([g('RescoreSource', 2) g('PosSource', 2)], ["detector" "det"]);
            % 3: a person's position away from the detection: its own score stays, score/DET refresh
            tc.verifyEqual([g('X', 3) g('rescore', 3)], [305 33]);
            tc.verifyEqual(g('RescoreSource', 3), tc.Model);
            tc.verifyEqual([g('score', 3) g('DET_X', 3)], [0.13 300.5]);
            % 4: a person's position within 0.01 px of its new detection -> the detector's value
            tc.verifyEqual([g('X', 4) g('rescore', 4)], [404 14]);
            tc.verifyEqual(g('RescoreSource', 4), "detector");
            % 5: the detector value of an earlier run, its detector position moved away: pending
            tc.verifyEqual(g('X', 5), 500.005);
            tc.verifyTrue(isnan(g('rescore', 5)));
            tc.verifyEqual(g('RescoreSource', 5), "");
            tc.verifyEqual(g('score', 5), 0.15);
            % 6, 7: not matched -> unchanged
            tc.verifyEqual(g('State', 6:7), ["stale"; "active"]);
            tc.verifyEqual(g('rescore', 6:7), [6; 7]);
            tc.verifyEqual(g('RescoreSource', 6:7), ["detector"; "detector"]);
            % the added cell detected now follows the detection (snap) -> refreshed
            tc.verifyEqual([g('X', a) g('rescore', a)], [801 18]);
            tc.verifyEqual(g('RescoreSource', a), "detector");
            % the added cell never detected keeps its score
            tc.verifyEqual(g('rescore', h), 99);
            tc.verifyEqual(g('RescoreSource', h), tc.Model);
            % appended detections
            T = s.T;
            new = T.CellID(T.CellID > max([double(a) double(h)]));
            tc.assertNumElements(new, 2);
            tc.verifyEqual(g('rescore', new(1)), 19);
            tc.verifyEqual(g('RescoreSource', new), ["detector"; ""], 'no finite rescore: pending');
            tc.verifyEqual(sort(s.rescorePending()), sort(uint32([5; new(2)])));
        end
    end

    %% ---- a snapshot written before RescoreSource existed --------------------------------------------
    methods (Test)
        function aSnapshotWithoutTheColumnOpensAndIsUpgraded(tc)
            L = mkLocs([100 100; 200 100; 300 100; 400 100; 500 100; 600 100], [1; 2; 3; 4; 5; NaN]);
            path = writeLocs(tc.Dir, 'secO_proj_PV2', L);
            s = tc.openP(path);
            a = s.addCell([700 300]);
            s.moveCell(2, [215 100]);
            s.mergeCells([3 4], 3, [350 100]);
            s.setLabel(5, "Good");
            s.flush();
            csv = s.Paths.csv; json = s.Paths.json;
            s.close();
            % what the store wrote before: no column, the detector's value still on the moved cells,
            % and a detection that vanished in a later reconcile (InLocs 0)
            toOldFormat(csv, [2; 3], [2; 3], 5);
            dropCsvFingerprint(json, 'PV2');
            r = tc.openP(path);
            tc.verifyFalse(r.ReadOnly, 'an old snapshot opens writable');
            tc.verifyEqual(r.get('RescoreSource', [1; 4]), ["detector"; "detector"], ...
                'matched, on its detector position, finite: the detector''s');
            tc.verifyEqual(r.get('rescore', [1; 4]), [1; 4]);
            tc.verifyEqual(r.get('RescoreSource', [2; 3; 5; 6; a]), strings(5, 1));
            tc.verifyTrue(all(isnan(r.get('rescore', [2; 3; 5; 6; a]))), 'stale values are dropped');
            w = r.LastReconcile.warnings;
            tc.verifyTrue(any(contains(w, "RescoreSource") & contains(w, "3 stale")), ...
                'the warning says how many values were dropped');
            hdr = readlines(csv, 'EmptyLineRule', 'skip');
            tc.verifyTrue(contains(hdr(1), "rescore,RescoreSource,"), 'the upgraded snapshot is written');
            T1 = r.T;
            r.close();
            r2 = tc.openP(path);
            verifyTablesEqual(tc, r2.T, T1);
            tc.verifyFalse(any(contains(r2.LastReconcile.warnings, "RescoreSource")));
        end

        function oldSnapshotWithANewerOldJournalIsFilledAfterTheReplay(tc)
            path = writeLocs(tc.Dir, 'secJ_proj_PV2', mkLocs([100 100; 200 100; 300 100], [1; 2; 3]));
            s = tc.openP(path);
            s.setLabel(1, "Good");
            s.flush();
            rev = s.Meta.Revision; csv = s.Paths.csv; json = s.Paths.json; jp = s.Paths.journal;
            s.close();
            toOldFormat(csv, [], [], []);
            dropCsvFingerprint(json, 'PV2');
            % a move journaled by the old code (crash before its snapshot): X and PosSource, no rescore
            E = [curation.ChangeSet.entry('set', 'X', 2, 200, 240); ...
                curation.ChangeSet.entry('set', 'PosSource', 2, "det", "human")];
            cs = curation.ChangeSet("Move 1 cell(s)", "moveCell", E);
            cs.Revision = rev + 1; cs.Seq = 1; cs.Time = string(curation.AtomicIO.isoNow(true));
            cs.Reviewer = "old";
            j = curation.Journal(jp, "old-session");
            j.append(cs);
            j.close();
            before = fileread(csv);
            ro = tc.openP(path, struct('ReadOnly', true));
            tc.verifyEqual(ro.get('X', 2), 240, 'the old journal is replayed');
            tc.verifyEqual(ro.get('RescoreSource', 1:3), ["detector"; ""; "detector"]);
            tc.verifyTrue(isnan(ro.get('rescore', 2)), 'filled after the replay: the moved cell is pending');
            ro.close();
            tc.verifyEqual(fileread(csv), before, 'a read-only open writes nothing');
            w = tc.openP(path);
            tc.verifyFalse(w.ReadOnly);
            tc.verifyEqual(w.get('RescoreSource', 1:3), ["detector"; ""; "detector"]);
            tc.verifyTrue(isnan(w.get('rescore', 2)));
            hdr = readlines(csv, 'EmptyLineRule', 'skip');
            tc.verifyTrue(contains(hdr(1), "rescore,RescoreSource,"));
        end
    end

    %% ---- rescorePending vs curation.Rescore.pending -------------------------------------------------
    methods (Test)
        function rescorePendingAgreesWithRescorePendingOnEveryCase(tc)
            % Before any score is computed, the store's set (State active, RescoreSource "") and
            % curation.Rescore.pending (its own position rule) must be the same.
            x = (1:14)' * 100;
            s = tc.mem(mkLocs([x, repmat(100, 14, 1)], x / 100 + 0.5));
            s.moveCell(2, [x(2) + 3, 100]);                          % human move away
            s.moveCell(3, [x(3) + 2, 102], "snap");                  % snapped away
            s.moveCell(4, [x(4) + 0.005, 100], "snap");              % within 0.01 px
            s.moveCell(5, [x(5), 100]);                              % "moved" to where it was
            s.moveCell(6, [x(6) + 4, 100]); s.moveCell(6, [x(6), 100]);   % away and back
            a1 = s.addCell([450 300]);                               % added, Good
            a2 = s.addCell([650 400], struct('Label', "", 'PosSource', "snap"));
            s.mergeCells([7 8], 7, [x(7) + 4, 100]);                 % keeper moved, 8 merged away
            s.mergeCells([9 10], 9);                                 % keeper not moved
            s.setLabel(11, "Good");                                  % a label is not a position
            tc.verifyEqual(sort(s.rescorePending()), sort(curation.Rescore.pending(s)), 'before a reconcile');
            s.setLabel(13, "Good");
            s.moveCell(14, [x(14) + 5, 100]);
            keep = setdiff(1:14, [12 13]);                           % 12 goes stale, 13 vanishes kept
            L1 = [mkLocs([x(keep), repmat(100, numel(keep), 1)], x(keep) / 100 + 0.5); mkLocs([1600 600], 7.5)];
            s.reconcile(L1);
            tc.verifyEqual(sort(s.rescorePending()), sort(curation.Rescore.pending(s)), 'after a reconcile');
            tc.verifyTrue(all(ismember([2; 7; 14; double(a1); double(a2)], double(s.rescorePending()))), ...
                'moved by a person, keeper moved by its merge, added');
            tc.verifyFalse(any(ismember([1; 3; 4; 5; 6; 9; 11; 13], double(s.rescorePending()))), ...
                'untouched, snapped (followed the detector), within 0.01 px, back on the detector, vanished');
            % legacy import: merge results, added and moved rows
            ls = tc.legacyStore();
            tc.verifyEqual(sort(ls.rescorePending()), sort(curation.Rescore.pending(ls)), 'legacy import');
            tc.verifyTrue(all(ismember(uint32([6; 7]), ls.rescorePending())), 'moved and merge result');
        end

        function rescorePendingDiffersFromRescorePendingOnlyAsDocumented(tc)
            % Where the two rules differ by design (reported, not changed in curation.Rescore):
            %   store pending, Rescore not: a detection whose locs has no finite rescore; a cell
            %     moved with posSource "det"; setRescore(id, NaN)
            %   Rescore pending, store not: a cell whose score was computed (setRescore); an added
            %     cell a reconcile matched that now follows its detection (Origin stays "added")
            s = tc.mem(mkLocs([100 100; 200 100; 300 100; 400 100; 500 100], [1; NaN; 3; 4; 5]));
            a = s.addCell([700 300]);
            s.setRescore(a, 0.5, tc.Model);
            b = s.addCell([800 300], struct('PosSource', "snap"));
            L1 = mkLocs([100 100; 200 100; 300 100; 400 100; 500 100; 801 300], [1; NaN; 3; 4; 5; 8]);
            s.reconcile(L1);
            tc.assertEqual(s.get('X', b), 801, 'the snapped added cell follows its detection');
            s.moveCell(3, [306 100], "det");
            s.setRescore(4, NaN, "");
            mine = double(s.rescorePending());
            theirs = double(curation.Rescore.pending(s));
            tc.verifyEqual(sort(setdiff(mine, theirs)), [2; 3; 4], 'pending in the store only');
            tc.verifyEqual(sort(setdiff(theirs, mine)), sort(double([a; b])), 'pending in Rescore only');
            tc.verifyEqual(s.get('RescoreSource', b), "detector");
            tc.verifyEqual(s.get('Origin', b), "added");
        end
    end

    %% ---- speed -----------------------------------------------------------------------------------
    methods (Test, TestTags = {'Benchmark'})
        function setRescoreSpeedBudget(tc)
            n = 2000;
            L = benchLocs(n);
            path = writeLocs(tc.Dir, 'bench_proj_ECM1', L);
            s = tc.openP(path);
            reps = 20;
            rng(5, 'twister');
            sets = arrayfun(@(~) randperm(n, 150)', 1:reps, 'UniformOutput', false);
            s.setRescore(sets{1}, randn(150, 1), "warm-up");          % warm up
            t = zeros(reps, 1);
            for k = 1:reps
                v = randn(150, 1);
                t0 = tic; s.setRescore(sets{k}, v, tc.Model); t(k) = toc(t0);
            end
            tm = zeros(reps, 1);
            for k = 1:reps
                ids = sets{k}(1:10);
                xy = [s.get('X', ids) + 1, s.get('Y', ids)];
                t0 = tic; s.moveCell(ids, xy); tm(k) = toc(t0);
            end
            tu = zeros(reps, 1);
            for k = 1:reps
                t0 = tic; s.undo(); tu(k) = toc(t0);
            end
            fprintf('\n[bench] 2000-row source, median of %d runs (ms):\n', reps);
            fprintf('[bench]   setRescore 150 ids, with journal %7.2f  (budget 15; max %.2f)\n', ...
                1000 * median(t), 1000 * max(t));
            fprintf('[bench]   moveCell 10 ids, with journal   %7.2f  (max %.2f)\n', 1000 * median(tm), 1000 * max(tm));
            fprintf('[bench]   undo of that move               %7.2f  (budget 15; max %.2f)\n', ...
                1000 * median(tu), 1000 * max(tu));
            tc.verifyLessThanOrEqual(1000 * median(t), 15);
            tc.verifyLessThanOrEqual(1000 * median(tu), 15);
        end
    end

    %% ---- helpers ---------------------------------------------------------------------------------
    methods (Access = private)
        function note(tc, e)
            tc.Events{end + 1} = e;
        end

        function s = mem(tc, L)
            s = curation.Store.fromTable(L, struct('Key', 'PV2', 'UmPerPixel', 0.645, 'Reviewer', 'tester'));
            tc.addTeardown(@() delete(s));
        end

        function s = openP(tc, path, opts)
            if nargin < 3, opts = struct(); end
            if ~isfield(opts, 'AutosaveDelay'), opts.AutosaveDelay = 0; end
            if ~isfield(opts, 'Reviewer'), opts.Reviewer = 'tester'; end
            s = curation.Store.openCsv(path, opts);
            tc.addTeardown(@() closeQuiet(s));
        end

        function s = legacyStore(tc)
            % The legacy resolver case of tStoreSmoke.testLegacyImport, with a rescore column:
            % rows 1, 2 merged into the appended merge result 7 (Origin merged, mean position),
            % 4 merged into 3, 5 deleted (Bad), 6 moved by the resolver, QC labels on 3 and 6.
            name = 'secL_proj_ECM1';
            X = [100; 105; 300; 304; 600; 800];
            Y = [100; 100; 300; 300; 600; 800];
            n = numel(X);
            T = table(repmat("img.tif", n, 1), Y, X, zeros(n, 1), [0.91; 0.82; 0.73; 0.64; 0.55; 0.46], ...
                zeros(n, 1), (1:n)' + 0.5, 'VariableNames', {'imgName', 'Y', 'X', 'class', 'score', 'thr', 'rescore'});
            T.CURATED_X = X; T.CURATED_Y = Y;
            T.NeighborResolved = false(n, 1);
            T.NeighborResolvedStatus = strings(n, 1);
            T.NeighborPairID = strings(n, 1);
            T.CURATED_X([1 2 4 5]) = NaN; T.CURATED_Y([1 2 4 5]) = NaN;
            T.NeighborPairID([1 2]) = "1-2"; T.NeighborResolvedStatus([1 2]) = "Merged";
            T.NeighborPairID([3 4]) = "3-4"; T.NeighborResolvedStatus([3 4]) = "Keep A";
            T.CURATED_X(6) = 810; T.CURATED_Y(6) = 805;
            m = T(1, :);
            m.X = 999; m.Y = 999; m.CURATED_X = 999; m.CURATED_Y = 999;
            m.NeighborPairID = "1-2"; m.NeighborResolvedStatus = "Merged"; m.NeighborResolved = true;
            T = [T; m];
            path = writeLocs(tc.Dir, name, T);
            qc = table([300; 810; 999], [300; 805; 999], ["Good"; "Bad"; "Ignore"], ...
                [true; true; true], ["ann"; "ann"; "ann"], ...
                datetime(2026, 5, 1, 10, 0, 0) + hours(0:2)', ["nice"; ""; ""], ...
                'VariableNames', {'X', 'Y', 'QCLabel', 'QCReviewed', 'QCReviewer', 'QCTimestamp', 'QCNotes'});
            writetable(qc, fullfile(tc.Dir, [name '_locs_QC.csv']));
            s = tc.openP(path);
            tc.assertTrue(s.Meta.LegacyImported);
            tc.assertEqual(s.get('Origin', 7), "merged");
            tc.assertEqual(s.get('PosSource', 6), "human");
        end
    end
end

%% ---- file-local helpers --------------------------------------------------------------------------

function L = mkLocs(xy, rescore, score)
n = size(xy, 1);
if nargin < 2, rescore = (1:n)' + 0.5; end
if nargin < 3, score = linspace(0.5, 0.9, n)'; end
L = table(xy(:, 1), xy(:, 2), zeros(n, 1), score(:), repmat("img.tif", n, 1), zeros(n, 1), rescore(:), ...
    'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
end

function L = benchLocs(n)
rng(9, 'twister');
side = ceil(sqrt(n));
[gx, gy] = meshgrid(1:side, 1:side);
pick = randperm(numel(gx), n);
X = 50 + 30 * gx(pick)' + rand(n, 1) * 2;
Y = 50 + 30 * gy(pick)' + rand(n, 1) * 2;
[~, o] = sortrows([Y, X]);
L = mkLocs([X(o), Y(o)], randn(n, 1), rand(n, 1));
end

function path = writeLocs(folder, stem, L)
path = fullfile(folder, [stem '_locs.csv']);
writetable(L, path);
end

function crash = crashCopy(folder)
% The files as they are on disk now (a crash: the snapshot older than the journal).
crash = fullfile(folder, 'crash');
mkdir(crash);
f = dir(folder);
f = f(~[f.isdir]);
for k = 1:numel(f)
    copyfile(fullfile(folder, f(k).name), fullfile(crash, f(k).name));
end
end

function toOldFormat(csv, staleIds, staleVals, notInLocs)
% Rewrite a snapshot as the store wrote it before RescoreSource existed: no such column, and the
% detector's rescore still on cells that had been moved (STALEIDS get STALEVALS). NOTINLOCS: rows
% given InLocs 0 (a detection that vanished in a later reconcile).
lines = readlines(csv, 'EmptyLineRule', 'skip');
hdr = split(lines(1), ",")';
kS = find(hdr == "RescoreSource");
kR = find(hdr == "rescore");
kI = find(hdr == "CellID");
kL = find(hdr == "InLocs");
keep = setdiff(1:numel(hdr), kS);
out = strings(numel(lines), 1);
out(1) = strjoin(hdr(keep), ",");
for i = 2:numel(lines)
    f = curation.Journal.parseCsvLine(char(lines(i)));
    id = str2double(f(kI));
    j = find(staleIds == id, 1);
    if ~isempty(j), f(kR) = curation.AtomicIO.fmtDouble(staleVals(j)); end
    if any(notInLocs == id), f(kL) = "0"; end
    g = curation.AtomicIO.csvEscape(reshape(f(keep), [], 1));
    out(i) = strjoin(reshape(g, 1, []), ",");
end
fid = fopen(csv, 'w', 'n', 'UTF-8');
fwrite(fid, char(strjoin(out, newline) + newline), 'char');
fclose(fid);
end

function dropCsvFingerprint(json, key)
% A record written before csvFingerprint existed: the (edited) snapshot is trusted as before.
curation.AtomicIO.updateJson(json, @(J) dropFp(J, key));
end

function J = dropFp(J, key)
r = J.sources.(key);
if isfield(r, 'csvFingerprint'), r = rmfield(r, 'csvFingerprint'); end
J.sources.(key) = r;
end

function verifyTablesEqual(tc, A, B)
tc.verifyEqual(height(A), height(B), 'row count');
tc.verifyEqual(A.Properties.VariableNames, B.Properties.VariableNames);
if height(A) ~= height(B), return; end
for k = 1:width(B)
    nm = B.Properties.VariableNames{k};
    tc.verifyClass(A.(nm), class(B.(nm)), nm);
    tc.verifyTrue(isequaln(A.(nm), B.(nm)), sprintf('column %s differs', nm));
end
end

function closeQuiet(s)
try
    if isvalid(s), s.close(); end
catch
end
end
