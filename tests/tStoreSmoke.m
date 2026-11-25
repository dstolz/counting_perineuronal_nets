classdef tStoreSmoke < matlab.unittest.TestCase
%tStoreSmoke  Sanity tests of curation.Store and its helpers (create, label, undo/redo, edits,
%   save/reopen, journal replay after a crash, reconcile, locking, legacy import, autosave) plus
%   a Benchmark-tagged check of the speed budgets on a 2,000-row source.
%   Uses only tiny hand-made locs tables in temporary folders.
%
%   Run: pwsh -File tools\Run-Tests.ps1 tStoreSmoke [-IncludeSlow for the Benchmark test]

    properties
        Dir char = ''
    end

    methods (TestClassSetup)
        function addPaths(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                fullfile(fileparts(here), 'customizations')));
        end
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            d = tempname;
            mkdir(d);
            tc.Dir = d;
            tc.addTeardown(@() tStoreSmoke.cleanup(d));
        end
    end

    %% ------------------------------------------------------------------------------- tests
    methods (Test)

        function testCreateLabelUndoRedo(tc)
            L = tStoreSmoke.makeLocs(20, 1, 40);
            s = curation.Store.fromTable(L, struct('Key', 'ECM1', 'UmPerPixel', 0.645));
            tc.addTeardown(@() delete(s));
            T = s.T;
            tc.verifyEqual(height(T), 20);
            tc.verifyEqual(T.CellID, uint32(1:20)');
            tc.verifyTrue(all(T.Origin == "detected" & T.State == "active" & T.InLocs));
            tc.verifyEqual(T.DET_X, T.X);

            s.setLabel([1 2 3], "good", "human", struct('ProposalP', [0.9 0.8 0.7]));
            tc.verifyEqual(s.counts().kept, 3);
            tc.verifyEqual(s.get('Label', 2), "Good");
            tc.verifyEqual(s.get('ProposalP', 3), 0.7);
            tc.verifyTrue(s.get('Reviewed', 1));
            tc.verifyTrue(strlength(s.get('ReviewedAt', 1)) > 0);

            s.setLabel(4, "Bad", "auto");
            tc.verifyFalse(s.get('Reviewed', 4));
            tc.verifyEqual(s.counts().autoRejected, 1);
            tc.verifyError(@() s.setLabel(5, "Good", "auto"), 'curation:Store:autoNotBad');
            s.setLabel(1, "Bad", "auto");              % never overwrites a person's label
            tc.verifyEqual(s.get('Label', 1), "Good");
            tc.verifyError(@() s.setLabel(999, "Good"), 'curation:Store:unknownId');

            tc.verifyTrue(s.undo());                   % undo auto Bad on 4
            tc.verifyEqual(s.get('Label', 4), "");
            tc.verifyTrue(s.undo());                   % undo Good on 1..3
            tc.verifyEqual(s.counts().kept, 0);
            tc.verifyTrue(isnan(s.get('ProposalP', 3)));
            tc.verifyFalse(s.CanUndo);
            tc.verifyFalse(s.undo());
            tc.verifyTrue(s.redo());
            tc.verifyEqual(s.counts().kept, 3);
            tc.verifyTrue(s.CanRedo);

            s.beginBatch("page");
            s.setLabel(5, "Good");
            s.setFlag(6, "later");
            s.setLabel(7, "Uncertain");
            s.endBatch();
            tc.verifyEqual(s.counts().flagged, 1);
            tc.verifyEqual(s.counts().uncertain, 1);
            s.undo();                                  % one step for the whole batch
            tc.verifyEqual(s.get('Label', 5), "");
            tc.verifyEqual(s.get('Flag', 6), "");
            tc.verifyEqual(s.get('Label', 7), "");

            s.setLabel(1, "");
            tc.verifyFalse(s.get('Reviewed', 1));
            tc.verifyEqual(s.get('LabelSource', 1), "");
            c = s.counts();
            tc.verifyEqual(c.kept, 2);
            tc.verifyEqual(c.total, 20);
            tc.verifyEqual(c.unreviewed, 18);
        end

        function testAddMoveMergeUnmerge(tc)
            L = tStoreSmoke.makeLocs(10, 2, 40);
            s = curation.Store.fromTable(L, struct('Key', 'PV2', 'UmPerPixel', 0.645));
            tc.addTeardown(@() delete(s));
            lh = addlistener(s, 'Changed', @(~, ev) tStoreSmoke.collect(ev));
            tc.addTeardown(@() delete(lh));
            tStoreSmoke.collect([]);

            id = s.addCell([100 200]);
            tc.verifyEqual(id, uint32(11));
            r = s.rowsOf(id);
            tc.verifyEqual(s.T.Origin(r), "added");
            tc.verifyFalse(s.T.InLocs(r));
            tc.verifyTrue(isnan(s.T.DET_X(r)));
            tc.verifyEqual(s.T.Label(r), "Good");
            tc.verifyTrue(ismember(uint32(11), s.kept().CellID));

            s.moveCell(1, [5 6]);
            tc.verifyEqual([s.get('X', 1), s.get('Y', 1)], [5 6]);
            tc.verifyEqual(s.get('PosSource', 1), "human");

            s.mergeCells([2 3], 2);
            tc.verifyEqual(s.get('State', 3), "merged");
            tc.verifyEqual(s.get('MergedInto', 3), uint32(2));
            tc.verifyNotEqual(s.get('Label', 3), "Bad");
            s.unmerge(3);
            tc.verifyEqual(s.get('State', 3), "active");
            tc.verifyEqual(s.get('MergedInto', 3), uint32(0));

            s.mergeCells([2 3 4], 2, [10 10]);
            tc.verifyEqual([s.get('X', 2), s.get('Y', 2)], [10 10]);
            tc.verifyEqual(s.counts().merged, 2);
            tc.verifyError(@() s.mergeCells([5 6], 3), 'curation:Store:badMerge');
            s.undo();
            tc.verifyEqual(s.counts().merged, 0);
            tc.verifyNotEqual(s.get('X', 2), 10);

            s.keepBoth([5 4]);
            tc.verifyEqual(s.Meta.KeptPairs, uint32([4 5]));
            s.undo();
            tc.verifyEmpty(s.Meta.KeptPairs);

            % undo the whole history back to the add, then redo it
            while s.undo(), end
            tc.verifyEqual(s.NumRows, 10);
            tc.verifyError(@() s.rowsOf(11), 'curation:Store:unknownId');
            s.redo();
            tc.verifyEqual(s.NumRows, 11);
            tc.verifyEqual(s.get('Origin', 11), "added");
            id2 = s.addCell([300 300; 320 300], struct('Label', ""));
            tc.verifyEqual(id2, uint32([12; 13]));   % ids never reused
            tc.verifyFalse(any(s.get('Reviewed', id2)));

            s.setSweepDone(true);
            s.setComplete(true);
            tc.verifyTrue(s.Meta.SweepDone && s.Meta.Complete);
            s.undo();
            tc.verifyFalse(s.Meta.Complete);

            ev = tStoreSmoke.collect([]);
            tc.verifyGreaterThan(numel(ev), 5);
            tc.verifyClass(ev{1}, 'curation.ChangeEventData');
            tc.verifyEqual(ev{1}.CellIDs, uint32(11));
        end

        function testSaveReopenRoundTripTypes(tc)
            path = tStoreSmoke.writeLocs(tc.Dir, 'sec1_proj_ECM1', tStoreSmoke.makeLocs(30, 3, 40));
            s = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            tc.verifyFalse(s.ReadOnly);
            p = s.Paths;
            tc.verifyEqual(p, curation.Store.pathsFor(tc.Dir, 'sec1_proj_ECM1', 'sec1_proj'));
            tc.verifyEqual(p, curation.Store.pathsFor(tc.Dir, 'sec1_proj_ECM1'));   % default base
            tc.verifyTrue(isfile(p.csv) && isfile(p.json) && isfile(p.lock));
            s.setNote(1, 'a, "quoted" note');
            s.setLabel(2, "Bad");
            s.setLabel([3 4], "Good", "confirmed");
            s.setFlag(3, "recheck");
            tStoreSmoke.excludeAround(s, 4);             % review finding 6: exclusion = a region
            s.setModel(6, 0.25, "v1");
            s.addCell([77.125 88.5], struct('PosSource', "snap"));
            s.mergeCells([7 8], 7);
            s.keepBoth([9 10]);
            T1 = s.T;
            c1 = s.counts();
            tc.verifyTrue(s.Dirty);
            s.close();
            tc.verifyFalse(isfile(p.lock));
            tc.verifyError(@() s.setLabel(1, "Good"), 'curation:Store:closed');

            s2 = curation.Store.openCsv(path);
            tc.addTeardown(@() delete(s2));
            T2 = s2.T;
            tStoreSmoke.verifyTablesEqual(tc, T2, T1);
            tc.verifyClass(T2.CellID, 'uint32');
            tc.verifyClass(T2.MergedInto, 'uint32');
            tc.verifyClass(T2.Reviewed, 'logical');
            tc.verifyClass(T2.AuditRole, 'string');     % all empty, still string
            tc.verifyClass(T2.imgName, 'string');
            tc.verifyEqual(s2.counts(), c1);
            tc.verifyEqual(s2.Meta.KeptPairs, uint32([9 10]));
            tc.verifyEqual(s2.Meta.NextCellId, 32);
            J = jsondecode(fileread(p.json));
            tc.verifyEqual(J.schema, 'cellcuration/1.0');
            tc.verifyTrue(isfield(J.sources, 'ECM1'));
            tc.verifyEqual(J.sources.ECM1.counts.kept, c1.kept);
            % model data is saved but not journaled
            jtxt = fileread(p.journal);
            tc.verifyFalse(contains(jtxt, ',ModelP,'));
            tc.verifyTrue(contains(jtxt, ',Label,'));
            % export
            s2.exportFinal();
            F = readtable(p.final, 'TextType', 'string');
            tc.verifyEqual(height(F), c1.kept);
            tc.verifyEqual(string(F.Properties.VariableNames), ...
                ["X", "Y", "class", "score", "imgName", "thr", "rescore", "CellID"]);
        end

        function testJournalReplayAfterCrash(tc)
            name = 'sec2_proj_PV2';
            path = tStoreSmoke.writeLocs(tc.Dir, name, tStoreSmoke.makeLocs(25, 4, 40));
            s = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            s.setLabel(1:5, "Good");
            id = s.addCell([300 310]);
            s.setNote(2, "hello, world");
            s.keepBoth([3 4]);
            s.undo();
            s.setFlag(7, "later");
            s.mergeCells([8 9], 9, [400 401]);
            s.moveCell(id, [305 315]);
            s.setComplete(true);
            T1 = s.T;
            tc.verifyTrue(s.Dirty);
            % "crash": copy the files as they are now (snapshot older than the journal)
            crash = fullfile(tc.Dir, 'crash');
            mkdir(crash);
            copyfile(fullfile(tc.Dir, '*.*'), crash);
            s.close();
            s2 = curation.Store.openCsv(fullfile(crash, [name '_locs.csv']));
            tc.addTeardown(@() delete(s2));
            tc.verifyFalse(s2.ReadOnly);          % the copied lock is stale: taken over
            tStoreSmoke.verifyTablesEqual(tc, s2.T, T1);
            tc.verifyEmpty(s2.Meta.KeptPairs);
            tc.verifyTrue(s2.Meta.Complete);
            tc.verifyEqual(s2.Meta.NextCellId, 27);
        end

        function testReconcileJitterDroppedNew(tc)
            L0 = tStoreSmoke.makeLocs(200, 5, 40);
            s = curation.Store.fromTable(L0, struct('Key', 'ECM1', 'UmPerPixel', 0.5));
            tc.addTeardown(@() delete(s));
            s.setLabel(1:10, "Good");
            s.setLabel(11:15, "Bad");
            s.setLabel(16:20, "Good");
            x21 = s.get('X', 21);
            s.moveCell(21, [x21 + 3, s.get('Y', 21)]);
            s.setLabel(22, "Bad", "auto");
            rng(7, 'twister');
            L1 = L0;
            L1.X = L1.X + (rand(200, 1) - 0.5) * 2;   % +/- 1 px jitter
            L1.Y = L1.Y + (rand(200, 1) - 0.5) * 2;
            L1.score = rand(200, 1);
            drop = [16:20, 30:40]';
            L1(drop, :) = [];
            nw = L1(1:7, :);
            nw.X = 5000 + (1:7)' * 50;
            nw.Y = 5000 + (1:7)' * 50;
            L1 = [L1; nw];
            L1 = L1(randperm(height(L1)), :);

            rep = s.reconcile(L1);
            tc.verifyTrue(rep.Ran);
            tc.verifyEqual(rep.nNew, height(L1));
            tc.verifyEqual(rep.nAppended, 7);
            tc.verifyEqual(rep.nVanishedGood, 5);
            tc.verifyEqual(rep.nStale, 11);
            tc.verifyEqual(rep.nPurged, 0);
            tc.verifyEqual(rep.nExact + rep.nNear, 200 - numel(drop));
            tc.verifyLessThanOrEqual(rep.maxMatchDistUm, 8);
            tc.verifyFalse(s.CanUndo);
            tc.verifyTrue(all(s.get('Label', 1:10) == "Good"));
            tc.verifyTrue(all(s.get('Label', 11:15) == "Bad"));
            tc.verifyEqual(s.counts().kept, 15);            % vanished Good stay kept
            tc.verifyEqual(s.counts().vanishedGood, 5);
            tc.verifyFalse(any(s.get('InLocs', 16:20)));
            tc.verifyEqual(s.get('X', 21), x21 + 3);         % human position kept
            tc.verifyEqual(s.get('PosSource', 21), "human");
            tc.verifyTrue(all(s.get('State', 30:40) == "stale"));
            tc.verifyEqual(s.get('X', 1), s.get('DET_X', 1)); % detector positions followed
            T = s.T;
            tc.verifyEqual(sort(T.CellID(T.CellID > 200)), uint32(201:207)');

            rep2 = s.reconcile(L1);                          % same detections again
            tc.verifyEqual(rep2.nPurged, 11);
            tc.verifyEqual(rep2.nAppended, 0);
            tc.verifyEqual(s.NumRows, 207 - 11);
            tc.verifyError(@() s.rowsOf(30), 'curation:Store:unknownId');
            tc.verifyEqual(s.counts().kept, 15);
        end

        function testLockTakeover(tc)
            name = 'sec3_proj_ECM1';
            path = tStoreSmoke.writeLocs(tc.Dir, name, tStoreSmoke.makeLocs(5, 6, 40));
            s1 = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(s1));
            s2 = curation.Store.openCsv(path);
            tc.verifyTrue(s2.ReadOnly);
            tc.verifyTrue(s2.LockInfo.Held);
            tc.verifyTrue(any(contains(s2.LastReconcile.warnings, "read-only")));
            tc.verifyError(@() s2.setLabel(1, "Good"), 'curation:Store:readOnly');
            s2.close();
            s3 = curation.Store.openCsv(path, struct('Force', true));
            tc.verifyFalse(s3.ReadOnly);
            tc.verifyTrue(s3.LockInfo.TakenOver);
            s3.close();
            s1.close();

            lockPath = curation.Store.pathsFor(tc.Dir, name, 'sec3_proj').lock;
            host = getenv('COMPUTERNAME');
            curation.AtomicIO.writeJson(lockPath, struct('host', host, 'user', 'ghost', ...
                'pid', 999999, 'time', '2026-01-01T00:00:00+00:00', 'session', 'dead'));
            s4 = curation.Store.openCsv(path);
            tc.verifyFalse(s4.ReadOnly);                     % dead pid on this host
            tc.verifyTrue(s4.LockInfo.TakenOver);
            s4.close();
            tc.verifyFalse(isfile(lockPath));

            curation.AtomicIO.writeJson(lockPath, struct('host', 'SOME-OTHER-PC', 'user', 'bob', ...
                'pid', 1234, 'time', '2026-01-01T00:00:00+00:00', 'session', 'x'));
            s5 = curation.Store.openCsv(path);
            tc.verifyTrue(s5.ReadOnly);
            tc.verifyEqual(s5.LockInfo.User, "bob");
            s5.close();
            tc.verifyTrue(isfile(lockPath));                 % not ours: left alone
        end

        function testLegacyImport(tc)
            name = 'sec4_proj_ECM1';
            X = [100; 105; 300; 304; 600; 800];
            Y = [100; 100; 300; 300; 600; 800];
            n = numel(X);
            score = [0.91; 0.82; 0.73; 0.64; 0.55; 0.46];
            T = table(repmat("img.tif", n, 1), Y, X, zeros(n, 1), score, zeros(n, 1), ...
                'VariableNames', {'imgName', 'Y', 'X', 'class', 'score', 'thr'});
            T.CURATED_X = X; T.CURATED_Y = Y;
            T.NeighborResolved = false(n, 1);
            T.NeighborResolvedStatus = strings(n, 1);
            T.NeighborPairID = strings(n, 1);
            T.CURATED_X([1 2 4 5]) = NaN; T.CURATED_Y([1 2 4 5]) = NaN;   % merged, kept-A, deleted
            T.NeighborPairID([1 2]) = "1-2"; T.NeighborResolvedStatus([1 2]) = "Merged";
            T.NeighborPairID([3 4]) = "3-4"; T.NeighborResolvedStatus([3 4]) = "Keep A";
            T.CURATED_X(6) = 810; T.CURATED_Y(6) = 805;                  % moved
            m = T(1, :);                                                  % appended merged row
            m.X = 999; m.Y = 999; m.CURATED_X = 999; m.CURATED_Y = 999;   % legacy bug position
            m.NeighborPairID = "1-2"; m.NeighborResolvedStatus = "Merged"; m.NeighborResolved = true;
            T = [T; m];
            path = tStoreSmoke.writeLocs(tc.Dir, name, T);
            qc = table([300; 810; 999], [300; 805; 999], ["Good"; "Bad"; "Ignore"], ...
                [true; true; true], ["ann"; "ann"; "ann"], ...
                datetime(2026, 5, 1, 10, 0, 0) + hours(0:2)', ["nice"; ""; ""], ...
                'VariableNames', {'X', 'Y', 'QCLabel', 'QCReviewed', 'QCReviewer', 'QCTimestamp', 'QCNotes'});
            qcPath = fullfile(tc.Dir, [name '_locs_QC.csv']);
            writetable(qc, qcPath);
            before = {fileread(path), fileread(qcPath)};

            s = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(s));
            tc.verifyTrue(s.Meta.LegacyImported);
            g = @(f, id) s.get(f, id);
            tc.verifyEqual(g('Origin', 7), "merged");
            tc.verifyEqual([g('X', 7), g('Y', 7)], [102.5 100]);       % mean of the parents
            tc.verifyEqual(g('State', [1; 2]), ["merged"; "merged"]);
            tc.verifyEqual(g('MergedInto', [1; 2]), uint32([7; 7]));
            tc.verifyEqual(g('State', 4), "merged");
            tc.verifyEqual(g('MergedInto', 4), uint32(3));
            tc.verifyEqual(g('Label', 5), "Bad");
            tc.verifyEqual(g('LabelSource', 5), "legacy-resolver");
            tc.verifyEqual([g('X', 6), g('Y', 6)], [810 805]);
            tc.verifyEqual(g('PosSource', 6), "human");
            tc.verifyEqual(g('Label', 3), "Good");
            tc.verifyEqual(g('LabelSource', 3), "legacy-qc");
            tc.verifyEqual(g('Reviewer', 3), "ann");
            tc.verifyTrue(startsWith(g('ReviewedAt', 3), "2026-05-01T10:00:00"));
            tc.verifyEqual(g('Notes', 3), "nice");
            tc.verifyEqual(g('Label', 6), "Bad");
            tc.verifyEqual(g('Flag', 7), "later");
            tc.verifyTrue(contains(g('Notes', 7), "legacy QC label: Ignore"));
            tc.verifyEqual(s.LastImport.qc.nUnmatched, 0);
            tc.verifyEqual(s.counts().kept, 1);
            after = {fileread(path), fileread(qcPath)};
            tc.verifyEqual(after, before);                               % legacy files untouched
        end

        function testAutosaveTimer(tc)
            path = tStoreSmoke.writeLocs(tc.Dir, 'sec5_proj_ECM1', tStoreSmoke.makeLocs(8, 8, 40));
            s = curation.Store.openCsv(path, struct('AutosaveDelay', 0.3));
            s.setLabel(1, "Good");
            tc.verifyTrue(s.Dirty);
            t0 = tic;
            while s.Dirty && toc(t0) < 5
                pause(0.1);
            end
            tc.verifyFalse(s.Dirty);
            snap = readtable(s.Paths.csv, 'TextType', 'string');
            tc.verifyEqual(snap.Label(1), "Good");
            lockPath = s.Paths.lock;
            s.close();
            tc.verifyFalse(isfile(lockPath));
            tc.verifyEmpty(timerfindall('Name', 'curation.Store autosave'));
        end

        function testOpenViaManifestUsesDetectorLocs(tc)
            % The detector output ('locs') is read even when the active pointer is the resized CSV.
            Lf = tStoreSmoke.makeLocs(10, 13, 40);
            full = tStoreSmoke.writeLocs(tc.Dir, 'secM_ECM1', Lf);
            Lr = Lf; Lr.X = Lr.X * 0.5; Lr.Y = Lr.Y * 0.5;
            writetable(Lr, fullfile(tc.Dir, 'secM_ECM1_locs_resized.csv'));
            mf = CellDatasetManifest.forBase(tc.Dir, 'secM');
            mf.ensureSource('ECM1', 'ECM', 1);
            src = mf.Data.sources.ECM1;
            src.locs = 'secM_ECM1_locs.csv';
            src.locsResized = 'secM_ECM1_locs_resized.csv';
            src.activeLocs = 'secM_ECM1_locs_resized.csv';
            src.coordSpace = 'resized';
            mf.Data.sources.ECM1 = src;
            mf.Data.image.umPerPixel = 0.3225;
            s = curation.Store.open(mf, 'ECM1', struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(s));
            tc.verifyEqual(s.Meta.LocsFile, full);
            tc.verifyEqual(s.T.X, Lf.X, 'AbsTol', 1e-9);   % writetable keeps 15 digits
            tc.verifyEqual(s.Meta.UmPerPixel, 0.3225);
            tc.verifyEqual(s.Meta.UmSource, 'manifest');
            tc.verifyEqual(s.Meta.Stem, 'secM_ECM1');
            tc.verifyEqual(s.Paths.json, fullfile(tc.Dir, 'secM.curation.json'));
            tc.verifyFalse(isfile(CellDatasetManifest.pathFor(tc.Dir, 'secM')));   % manifest untouched
            s.close();
            % same with no 'locs' recorded: the resized active pointer maps to its full twin
            src.locs = '';
            mf.Data.sources.ECM1 = src;
            s2 = curation.Store.open(mf, 'ECM1', struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(s2));
            tc.verifyEqual(s2.Meta.LocsFile, full);
        end

        function testReopenReconcilesChangedLocs(tc)
            L0 = tStoreSmoke.makeLocs(30, 12, 40);
            path = tStoreSmoke.writeLocs(tc.Dir, 'sec6_proj_ECM1', L0);
            s = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            tc.verifyFalse(s.LastReconcile.Ran);
            s.setLabel(1:3, "Good");
            s.close();
            L1 = L0;
            L1.X = L1.X + 0.5;
            L1 = [L1; L1(1, :)];
            L1.X(end) = 3000; L1.Y(end) = 3000;
            writetable(L1, path);
            s2 = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(s2));
            rep = s2.LastReconcile;
            tc.verifyTrue(rep.Ran);
            tc.verifyEqual(rep.nAppended, 1);
            tc.verifyEqual(rep.nNear, 30);
            tc.verifyEqual(s2.counts().kept, 3);
            tc.verifyTrue(contains(s2.Meta.LocsFingerprint, "rows=31"));
            J = jsondecode(fileread(s2.Paths.json));
            tc.verifyEqual(J.sources.ECM1.locsFingerprint, s2.Meta.LocsFingerprint);
            s2.close();
            s3 = curation.Store.openCsv(path, struct('AutosaveDelay', 0));   % unchanged now
            tc.addTeardown(@() delete(s3));
            tc.verifyFalse(s3.LastReconcile.Ran);
        end

        function testLegacyQcRowIndexFallback(tc)
            L = tStoreSmoke.makeLocs(20, 14, 40);
            name = 'sec7_proj_ECM1';
            path = tStoreSmoke.writeLocs(tc.Dir, name, L);
            qc = L(:, {'X', 'Y'});
            qc.QCLabel = strings(20, 1);
            qc.QCReviewed = false(20, 1);
            qc.QCLabel([2 5 9]) = ["Good"; "Good"; "Uncertain"];
            qc.QCReviewed([2 5 9]) = true;
            qc.X(5) = qc.X(5) + 30;     % re-centered in QC, beyond the 8 um tolerance
            writetable(qc, fullfile(tc.Dir, [name '_locs_QC.csv']));
            s = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(s));
            q = s.LastImport.qc;
            tc.verifyEqual(q.nByIndex, 1);
            tc.verifyEqual(q.nMoves, 1);
            tc.verifyEqual(q.good, 2);
            tc.verifyEqual(s.get('Label', [2; 5; 9]), ["Good"; "Good"; "Uncertain"]);
            tc.verifyEqual(s.get('LabelSource', 5), "legacy-qc");
            tc.verifyEqual(s.get('X', 5), L.X(5) + 30, 'AbsTol', 1e-9);
            tc.verifyEqual(s.get('PosSource', 5), "human");
        end

        function testFailedOpenWritesNothing(tc)
            stem = 'secF_proj_ECM1';
            tc.verifyError(@() curation.Store.fromTable([], struct('Folder', tc.Dir, 'Stem', stem)), ...
                'curation:Store:noLocs');
            p = curation.Store.pathsFor(tc.Dir, stem, '');
            tc.verifyFalse(isfile(p.csv));
            tc.verifyFalse(isfile(p.json));
            tc.verifyFalse(isfile(p.lock));
        end

        function testZeroDetections(tc)
            L = tStoreSmoke.makeLocs(3, 15, 40);
            L(:, :) = [];
            path = tStoreSmoke.writeLocs(tc.Dir, 'sec8_proj_ECM1', L);
            s = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(s));
            tc.verifyEqual(s.NumRows, 0);
            id = s.addCell([10 10]);
            tc.verifyEqual(id, uint32(1));
            s.close();
            s2 = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(s2));
            tc.verifyEqual(s2.NumRows, 1);
            tc.verifyEqual(s2.counts().kept, 1);
        end
    end

    methods (Test)
        % ---- follow-up changes: excluded not kept, '' arguments, auto-reject, regions ----

        function testExcludedIsNotKept(tc)
            L = tStoreSmoke.makeLocs(10, 21, 40);
            s = curation.Store.fromTable(L, struct('UmPerPixel', 0.645));
            tc.addTeardown(@() delete(s));
            s.setLabel(1:4, "Good");
            tStoreSmoke.excludeAround(s, 2);             % review finding 6: exclusion = a region
            c = s.counts();
            tc.verifyEqual(c.kept, 3);
            tc.verifyEqual(c.excluded, 1);
            tc.verifyEqual(c.good, 4);                       % the label itself is untouched
            tc.verifyEqual(sort(s.kept().CellID), uint32([1; 3; 4]));
            m = s.keptMask();
            tc.verifyFalse(m(s.rowsOf(2)));
            f = fullfile(tc.Dir, 'final.csv');
            s.exportFinal(f);
            F = readtable(f);
            tc.verifyEqual(sort(F.CellID), [1; 3; 4], '_final.csv leaves out excluded cells');
            s.undo();                                        % un-exclude restores it
            tc.verifyEqual(s.counts().kept, 4);
        end

        function testEmptyCharArguments(tc)
            L = tStoreSmoke.makeLocs(12, 25, 40);
            s = curation.Store.fromTable(L, struct('UmPerPixel', 0.645));
            tc.addTeardown(@() delete(s));
            s.setLabel(1:2, 'Good');
            s.setLabel(1, '');
            tc.verifyEqual(s.get('Label', 1), "");
            tc.verifyFalse(s.get('Reviewed', 1));
            s.setLabel(2, '', '');
            tc.verifyEqual(s.get('Label', 2), "");
            s.setLabel(3, "Good", '');                       % '' source = default human
            tc.verifyEqual(s.get('LabelSource', 3), "human");
            s.setFlag(4, 'later');
            s.setFlag(4, '');
            tc.verifyEqual(s.get('Flag', 4), "");
            s.setFlag(5, "recheck");
            s.setFlag(5, []);
            tc.verifyEqual(s.get('Flag', 5), "");
            s.setAuditRole(6, 'holdout');
            s.setAuditRole(6, '');
            tc.verifyEqual(s.get('AuditRole', 6), "");
            s.setNote(7, 'x');
            s.setNote(7, '');
            tc.verifyEqual(s.get('Notes', 7), "");
            s.moveCell(8, [1 2], '');
            tc.verifyEqual(s.get('PosSource', 8), "human");
            s.moveCell(8, [3 4], "");
            tc.verifyEqual(s.get('X', 8), 3);
            id = s.addCell([500 500], struct('Label', ''));
            tc.verifyEqual(s.get('Label', id), "");
            tc.verifyFalse(s.get('Reviewed', id));
            id2 = s.addCell([600 600], struct('Label', 'Good', 'LabelSource', '', 'PosSource', '', 'Notes', ''));
            tc.verifyEqual([s.get('LabelSource', id2), s.get('PosSource', id2)], ["human", "human"]);
            s.setModel(9, 0.5, '');
            tc.verifyEqual(s.get('ModelVersion', 9), "");
        end

        function testAutoRejectRoundTripAndScaleSource(tc)
            name = 'sec9_proj_ECM1';
            path = tStoreSmoke.writeLocs(tc.Dir, name, tStoreSmoke.makeLocs(12, 22, 40));
            s = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            d = s.Meta.AutoReject;
            tc.verifyEqual(fieldnames(d)', {'enabled', 'tau', 'modelVersion', 'audit'});
            tc.verifyFalse(d.enabled);
            tc.verifyTrue(isnan(d.tau));
            tc.verifyEqual(d.modelVersion, "");
            tc.verifyTrue(isstruct(d.audit) && isempty(fieldnames(d.audit)));
            tc.verifyEqual(s.Meta.UmSource, 'default');
            st = struct('enabled', true, 'tau', 0.12, 'modelVersion', 'm3', ...
                'audit', struct('n', 15, 'rate', 0.02, 'ids', [1 2 3], 'note', "ok"));
            s.setAutoReject(st);
            A1 = s.Meta.AutoReject;
            tc.verifyTrue(A1.enabled);
            tc.verifyEqual(A1.tau, 0.12);
            tc.verifyEqual(A1.modelVersion, "m3");
            tc.verifyEqual(A1.audit.ids, [1; 2; 3]);          % canonical JSON form
            s.undo();
            tc.verifyTrue(isequaln(s.Meta.AutoReject, d));
            s.redo();
            tc.verifyTrue(isequaln(s.Meta.AutoReject, A1));
            s.setAutoReject(struct('enabled', true, 'tau', [], 'modelVersion', "m3", 'audit', A1.audit));
            A2 = s.Meta.AutoReject;
            tc.verifyTrue(isnan(A2.tau));
            tc.verifyError(@() s.setAutoReject(struct('tau', 'x')), 'curation:Store:badArgument');
            % crash: snapshot older than the journal -> replayed meta change
            crash = fullfile(tc.Dir, 'crash');
            mkdir(crash);
            copyfile(fullfile(tc.Dir, '*.*'), crash);
            s.close();
            c = curation.Store.openCsv(fullfile(crash, [name '_locs.csv']), struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(c));
            tc.verifyTrue(isequaln(c.Meta.AutoReject, A2), 'journal replay restores AutoReject');
            s2 = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(s2));
            tc.verifyTrue(isequaln(s2.Meta.AutoReject, A2), 'identical after close/reopen');
            tc.verifyEqual(s2.Meta.UmSource, 'default', 'scale source stable across reopen');
            J = jsondecode(fileread(s2.Paths.json));
            tc.verifyEmpty(J.sources.ECM1.autoReject.tau);   % null in the file
            tc.verifyEqual(J.sources.ECM1.umSource, 'default');
            % a scale given to fromTable stays "meta" when reopened without it
            L = tStoreSmoke.makeLocs(5, 26, 40);
            m = curation.Store.fromTable(L, struct('Folder', tc.Dir, 'Stem', 'meta_ECM1', 'UmPerPixel', 0.5));
            tc.verifyEqual(m.Meta.UmSource, 'meta');
            m.close();
            m2 = curation.Store.fromTable(L, struct('Folder', tc.Dir, 'Stem', 'meta_ECM1'));
            tc.addTeardown(@() delete(m2));
            tc.verifyEqual(m2.Meta.UmSource, 'meta');
            tc.verifyEqual(m2.Meta.UmPerPixel, 0.5);
        end

        function testRegionNormalizeFallbackMatches(tc)
            % The store's private fallback must give what curation.Regions.normalize gives for
            % the shapes jsondecode returns (used when Regions.m is absent).
            tc.assumeTrue(~isempty(meta.class.fromName('curation.Regions')), 'curation.Regions not present');
            inputs = { [], ...
                jsondecode(['[{"id":1,"kind":"exclude","scope":"image","xy":[[0,0],[1,0],[1,1]],"note":"a"},' ...
                    '{"id":2,"kind":"analysis","scope":"PV2","xy":[[0,0],[2,0],[2,2],[0,2]],"note":""}]']), ...
                jsondecode(['[{"id":1,"kind":"exclude","xy":[[0,0],[1,0],[1,1]]},' ...
                    '{"id":2,"kind":"reference","scope":"ECM1","xy":[[0,0],[2,0],[2,2],[0,2]],"note":"n"}]']), ...
                jsondecode('[{"id":5,"kind":"exclude","xy":[[0,0],[3,0],[3,3]]}]'), ...
                struct('id', 1, 'kind', "exclude", 'xy', {{[0 0]; [1 0]; [1 1]}}) };
            for k = 1:numel(inputs)
                tc.verifyEqual(curation.Store.fallbackNormRegions(inputs{k}), ...
                    curation.Regions.normalize(inputs{k}), sprintf('input %d', k));
            end
        end

        function testRegionsSharedUndoableAndBatched(tc)
            pe = tStoreSmoke.writeLocs(tc.Dir, 'secR_proj_ECM1', tStoreSmoke.makeLocs(16, 23, 40));
            pp = tStoreSmoke.writeLocs(tc.Dir, 'secR_proj_PV2', tStoreSmoke.makeLocs(16, 24, 40));
            e = curation.Store.openCsv(pe, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(e));
            p = curation.Store.openCsv(pp, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(p));
            R0 = e.regions();
            tc.verifySize(R0, [0 1]);
            tc.verifyEqual(fieldnames(R0)', {'id', 'kind', 'scope', 'xy', 'note'});

            % a square that holds no cell (review finding 6: an exclude region now excludes the
            % cells inside it by itself, so one over a cell would change the counts below)
            sq = [0 0; 40 0; 40 40; 0 40];
            id1 = e.addRegion(struct('kind', "exclude", 'xy', sq, 'note', 'fold'));
            tc.verifyEqual(id1, 1);
            r = e.regions();
            tc.verifyEqual(r.scope, "image");
            tc.verifyEqual(r.note, "fold");
            tc.verifyClass(r.kind, 'string');
            p.reloadRegions();
            tc.verifyEqual(p.regions(), e.regions());
            tri = [10 10; 60 10; 35 50];
            id2 = p.addRegion(struct('kind', 'analysis', 'scope', 'PV2', 'xy', tri, 'id', 0));
            tc.verifyEqual(id2, 2, 'ids continue across the channels');
            e.reloadRegions();
            R = e.regions();
            tc.verifyEqual([R.id]', [1; 2]);
            tc.verifyEqual(size(R(1).xy), [4 2]);
            tc.verifyEqual(size(R(2).xy), [3 2]);           % differing vertex counts
            J = jsondecode(fileread(e.Paths.json));
            tc.verifyTrue(isfield(J.sources, 'ECM1') && isfield(J.sources, 'PV2'));
            tc.verifyError(@() e.addRegion(struct('kind', 'exclude', 'xy', sq, 'id', 2)), 'curation:Store:badArgument');
            tc.verifyError(@() e.addRegion(struct('kind', 'bogus', 'xy', sq)), 'curation:Store:badArgument');
            tc.verifyError(@() e.addRegion(struct('kind', 'exclude', 'xy', [0 0; 1 1])), 'curation:Store:badArgument');

            % region + exclusion in one batch = one undo step
            poly = [0 0; 200 0; 200 200; 0 200];
            T = e.T;
            inside = T.CellID(inpolygon(T.X, T.Y, poly(:, 1), poly(:, 2)));
            tc.assertNotEmpty(inside);
            e.setLabel(inside, "Good");
            nKept = e.counts().kept;
            e.beginBatch("Exclude a fold");
            id3 = e.addRegion(struct('kind', 'exclude', 'xy', poly));
            e.setExcluded(inside, true);
            e.endBatch();
            tc.verifyEqual(id3, 3);
            tc.verifyTrue(all(e.get('Excluded', inside)));
            tc.verifyEqual(e.counts().kept, nKept - numel(inside));
            p.reloadRegions();
            tc.verifyEqual(numel(p.regions()), 3, 'committed batch is in the shared JSON');
            e.undo();
            tc.verifyFalse(any(e.get('Excluded', inside)));
            tc.verifyEqual([e.regions().id]', [1; 2]);
            p.reloadRegions();
            tc.verifyEqual(numel(p.regions()), 2, 'undo removed the region from the JSON');
            e.redo();
            tc.verifyEqual(numel(e.regions()), 3);
            tc.verifyTrue(all(e.get('Excluded', inside)));

            e.beginBatch("abandoned");
            e.addRegion(struct('kind', 'reference', 'xy', tri));
            tc.verifyEqual(numel(e.regions()), 4);
            e.cancelBatch();
            tc.verifyEqual(numel(e.regions()), 3);
            p.reloadRegions();
            tc.verifyEqual(numel(p.regions()), 3, 'a canceled batch writes nothing');

            tc.verifyTrue(e.removeRegion(1));
            tc.verifyFalse(any([e.regions().id] == 1));
            tc.verifyFalse(e.removeRegion(99));
            e.undo();
            R = e.regions();
            tc.verifyEqual(R([R.id] == 1).xy, sq);

            p.reloadRegions();
            p.removeRegion(2);
            p.removeRegion(3);
            e.reloadRegions();
            tc.verifyEqual([e.regions().id], 1);
            txt = fileread(e.Paths.json);
            tc.verifyNotEmpty(regexp(txt, '"regions"\s*:\s*\[', 'once'), 'one region is still an array');
            Rb = e.regions();
            e.flush(); p.flush();
            J = jsondecode(fileread(e.Paths.json));
            tc.verifyTrue(isfield(J.sources, 'ECM1') && isfield(J.sources, 'PV2'));
            e.close(); p.close();
            e2 = curation.Store.openCsv(pe, struct('AutosaveDelay', 0));
            tc.addTeardown(@() delete(e2));
            tc.verifyEqual(e2.regions(), Rb, 'regions identical after reopen');
            jtxt = fileread(e2.Paths.journal);
            tc.verifyTrue(contains(jtxt, ',+region,') && contains(jtxt, ',-region,'));

            m = curation.Store.fromTable(tStoreSmoke.makeLocs(5, 27, 40), struct('UmPerPixel', 0.645));
            tc.addTeardown(@() delete(m));
            tc.verifyEqual(m.addRegion(struct('kind', 'exclude', 'xy', sq)), 1);
            m.undo();
            tc.verifyEmpty(m.regions());
        end
    end

    methods (Test, TestTags = {'Benchmark'})
        function testSpeedBudgets(tc)
            n = 2000;
            L = tStoreSmoke.makeLocs(n, 9, 30);
            path = tStoreSmoke.writeLocs(tc.Dir, 'bench_proj_ECM1', L);
            reps = 20;
            rng(11, 'twister');
            sets = arrayfun(@(~) randperm(n, 150), 1:reps, 'UniformOutput', false);
            labels = ["Good", "Bad"];

            m = curation.Store.fromTable(L, struct('UmPerPixel', 0.645));   % no journal
            tc.addTeardown(@() delete(m));
            m.setLabel(sets{1}, "Good"); m.undo(); m.redo();                % warm up
            tMem = zeros(reps, 1);
            for k = 1:reps
                t = tic; m.setLabel(sets{k}, labels(mod(k, 2) + 1)); tMem(k) = toc(t);
            end

            s = curation.Store.openCsv(path, struct('AutosaveDelay', 0));
            s.setLabel(sets{1}, "Good"); s.undo(); s.redo();                % warm up
            tJ = zeros(reps, 1); tU = zeros(reps, 1); tR = zeros(reps, 1);
            for k = 1:reps
                t = tic; s.setLabel(sets{k}, labels(mod(k, 2) + 1)); tJ(k) = toc(t);
            end
            for k = 1:reps
                t = tic; s.undo(); tU(k) = toc(t);
            end
            for k = 1:reps
                t = tic; s.redo(); tR(k) = toc(t);
            end
            tF = zeros(5, 1);
            for k = 1:5
                s.setLabel(sets{k}, labels(mod(k, 2) + 1));
                t = tic; s.flush(); tF(k) = toc(t);
            end
            ji = s.JournalInfo;
            fprintf('\n[bench] journal file kept open between transactions: %d\n', ji.KeepOpen);
            fprintf('[bench] snapshot put in place by: %s\n', curation.AtomicIO.lastReplaceMethod());
            s.close();
            tO = zeros(4, 1);
            for k = 1:4
                t = tic; s = curation.Store.openCsv(path, struct('AutosaveDelay', 0)); tO(k) = toc(t);
                s.close();
            end
            ms = @(v) 1000 * median(v);
            fprintf('\n[bench] 2000-row source, median of runs (ms):\n');
            fprintf('[bench]   setLabel 150 ids, no journal   %7.2f  (budget 5)\n', ms(tMem));
            fprintf('[bench]   setLabel 150 ids, with journal %7.2f  (budget 15)\n', ms(tJ));
            fprintf('[bench]   undo of it                     %7.2f  (budget 15)\n', ms(tU));
            fprintf('[bench]   redo of it                     %7.2f  (budget 15)\n', ms(tR));
            fprintf('[bench]   flush                          %7.2f  (budget 150)\n', ms(tF));
            fprintf('[bench]   open existing store            %7.2f  (budget 300; first %.1f)\n', ms(tO(2:end)), 1000 * tO(1));
            fprintf('[bench]   max setLabel w/ journal %.2f, max undo %.2f, max flush %.2f\n', ...
                1000 * max(tJ), 1000 * max(tU), 1000 * max(tF));
            tc.verifyLessThanOrEqual(ms(tMem), 5);
            tc.verifyLessThanOrEqual(ms(tJ), 15);
            tc.verifyLessThanOrEqual(ms(tU), 15);
            tc.verifyLessThanOrEqual(ms(tR), 15);
            tc.verifyLessThanOrEqual(ms(tF), 150);
            tc.verifyLessThanOrEqual(ms(tO(2:end)), 300);
        end
    end

    %% ----------------------------------------------------------------------------- helpers
    methods (Static)

        function L = makeLocs(n, seed, spacing)
            % n detections on a jittered grid (detector order: sorted by Y, then X).
            rng(seed, 'twister');
            side = ceil(sqrt(n));
            [gx, gy] = meshgrid(1:side, 1:side);
            pick = randperm(numel(gx), n);
            X = 50 + spacing * gx(pick)' + rand(n, 1) * 2;
            Y = 50 + spacing * gy(pick)' + rand(n, 1) * 2;
            [~, o] = sortrows([Y, X]);
            X = X(o); Y = Y(o);
            L = table(repmat("img.tif", n, 1), Y, X, zeros(n, 1), rand(n, 1), ...
                zeros(n, 1), randn(n, 1), ...
                'VariableNames', {'imgName', 'Y', 'X', 'class', 'score', 'thr', 'rescore'});
        end

        function path = writeLocs(folder, stem, L)
            path = fullfile(folder, [stem '_locs.csv']);
            writetable(L, path);
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

        function rid = excludeAround(s, ids)
            % Exclude cells the way the store allows since review finding 6: Excluded follows the
            % exclusion regions, so a small exclude region of this source goes around each cell
            % (one batch, one undo step).
            rid = zeros(numel(ids), 1);
            s.beginBatch("Exclude");
            for k = 1:numel(ids)
                x = s.get('X', ids(k)); y = s.get('Y', ids(k));
                rid(k) = s.addRegion(struct('kind', 'exclude', 'scope', s.Meta.Key, ...
                    'xy', [x - 0.5, y - 0.5; x + 0.5, y - 0.5; x + 0.5, y + 0.5; x - 0.5, y + 0.5]));
            end
            s.endBatch();
        end

        function out = collect(ev)
            % Accumulate Changed events; collect([]) returns them and resets.
            persistent got
            if ~iscell(got), got = {}; end
            if isempty(ev)
                out = got;
                got = {};
                return;
            end
            got{end + 1} = ev;
            out = [];
        end

        function cleanup(d)
            try
                t = timerfindall('Name', 'curation.Store autosave');
                if ~isempty(t), stop(t); delete(t); end
            catch
            end
            if isfolder(d)
                try rmdir(d, 's'); catch, end
            end
        end
    end
end
