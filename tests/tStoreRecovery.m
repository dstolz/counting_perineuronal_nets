classdef tStoreRecovery < matlab.unittest.TestCase
%tStoreRecovery  Regression tests: curation.Store recovers from crashes, missing, unreadable or
%   restored files, concurrent writers and a lost lock without putting a decision on the wrong cell
%   and without losing one. Review findings 1-4, 12-15 and A-C (one or more tests each; the test
%   name states the rule it protects).
%
%   Run: pwsh -File tools\Run-Tests.ps1 tStoreRecovery

    properties (Access = private)
        Dir char
        Kinds string = strings(0, 1)
    end

    methods (TestClassSetup)
        function addPaths(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(here, 'fixtures')));
        end
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = tmp.Folder;
            tc.Kinds = strings(0, 1);
        end
    end

    %% ---- finding 1: a missing snapshot -----------------------------------------------------------
    methods (Test)
        function missingSnapshotAfterAReconcileIsNeverGuessedFromTheLocsOrder(tc)
            % Rows A B C D, B Good; a reconcile against E D C B A appends E (Bad); then the snapshot
            % CSV disappears. Rebuilding rows 1..n from the current locs order would put B's label
            % on D: the open must refuse instead and leave every file as it is.
            p = writeLocs(tc.Dir, 'secA_proj_ECM1', mkLocs([100 100; 200 100; 300 100; 400 100]));
            s = tc.openP(p);
            s.setLabel(idAt(s, 200, 100), "Good");
            s.close();
            writeLocs(tc.Dir, 'secA_proj_ECM1', mkLocs([500 100; 400 100; 300 100; 200 100; 100 100]));
            s = tc.openP(p);
            tc.assertTrue(s.LastReconcile.Ran, 'precondition: the changed locs reconciled at open');
            s.setLabel(idAt(s, 500, 100), "Bad");
            paths = s.Paths;
            s.close();
            delete(paths.csv);
            sig0 = {fileSig(paths.journal), fileSig(paths.json)};
            tc.verifyError(@() tc.openP(p), 'curation:Store:snapshotMissing', ...
                'without its snapshot a reconciled store must not be rebuilt from the locs order');
            try
                tc.openP(p);
            catch ME
                tc.verifySubstring(ME.message, 'secA_proj_ECM1_curation.csv', 'the message names the missing file');
                tc.verifySubstring(ME.message, 'Rebuild', 'the message says what the person can do');
            end
            tc.verifyEqual({fileSig(paths.journal), fileSig(paths.json)}, sig0, 'a refused open changes no file');
            tc.verifyFalse(isfile(paths.lock), 'a refused open leaves no lock behind');
        end

        function missingSnapshotRebuildArchivesTheJournalAndRecord(tc)
            p = writeLocs(tc.Dir, 'secA_proj_ECM1', mkLocs([100 100; 200 100; 300 100; 400 100]));
            s = tc.openP(p);
            s.setLabel(idAt(s, 200, 100), "Good");
            s.close();
            writeLocs(tc.Dir, 'secA_proj_ECM1', mkLocs([500 100; 400 100; 300 100; 200 100; 100 100]));
            s = tc.openP(p);
            s.setLabel(idAt(s, 500, 100), "Bad");
            paths = s.Paths;
            s.close();
            journal0 = fileread(paths.journal);
            J0 = jsondecode(fileread(paths.json));
            delete(paths.csv);
            r = tc.openP(p, 'Rebuild', true);
            tc.verifyFalse(r.ReadOnly);
            tc.verifyEqual(r.NumRows, 5, 'a fresh store from the current locs');
            tc.verifyFalse(any(r.get('Reviewed')), 'the fresh store starts without decisions');
            aj = dir(fullfile(tc.Dir, 'secA_proj_ECM1_curation.journal.archived-*.csv'));
            tc.assertNumElements(aj, 1, 'the old journal is archived under a timestamped name');
            tc.verifyEqual(fileread(fullfile(aj.folder, aj.name)), journal0, 'archived, not edited');
            ar = dir(fullfile(tc.Dir, 'secA_proj_ECM1_curation.record.archived-*.json'));
            tc.assertNumElements(ar, 1, 'the old JSON record is archived under a timestamped name');
            rec = jsondecode(fileread(fullfile(ar.folder, ar.name)));
            tc.verifyEqual(rec.revision, J0.sources.ECM1.revision, 'the archived record is the old one');
        end

        function missingSnapshotWithUnchangedLocsIsRebuiltAndReplayed(tc)
            % The one safe case: same locs file, no reconcile or import in the journal.
            p = writeLocs(tc.Dir, 'secA_proj_ECM1', mkLocs([100 100; 200 100; 300 100; 400 100]));
            s = tc.openP(p);
            s.setLabel(idAt(s, 200, 100), "Good");
            s.setLabel(idAt(s, 400, 100), "Bad");
            paths = s.Paths;
            s.close();
            delete(paths.csv);
            r = tc.openP(p);
            tc.verifyEqual(r.get('Label', idAt(r, 200, 100)), "Good");
            tc.verifyEqual(r.get('Label', idAt(r, 400, 100)), "Bad");
            tc.verifyTrue(isfile(paths.csv), 'the snapshot is written again');
        end
    end

    %% ---- finding 2: a reconcile whose snapshot write fails ---------------------------------------
    methods (Test)
        function reconcileIsUndoneWhenItsSnapshotCannotBeWritten(tc)
            p = writeLocs(tc.Dir, 'secB_proj_ECM1', mkLocs([100 100; 200 100; 300 100; 400 100]));
            s = tc.openP(p);
            s.setLabel(idAt(s, 200, 100), "Good");
            s.flush();
            T0 = s.T; M0 = s.Meta;
            tc.assertTrue(s.CanUndo);
            fs = tc.holdOpen(s.Paths.csv);
            tc.verifyError(@() s.reconcile(mkLocs([100 100; 200 100; 300 100; 400 100; 500 100])), ...
                'curation:AtomicIO:writeFailed');
            fs.Close();
            tc.verifyEqual(s.T, T0, 'a reconcile that could not be saved leaves the rows as they were');
            tc.verifyEqual(s.Meta.LocsFingerprint, M0.LocsFingerprint);
            tc.verifyEqual(s.Meta.NextCellId, M0.NextCellId);
            tc.verifyTrue(s.CanUndo, 'and keeps the undo history');
        end

        function journalWrittenAfterAnOpenTimeReconcileReplaysOnTheRightCells(tc)
            p = writeLocs(tc.Dir, 'secB_proj_ECM1', mkLocs([100 100; 200 100; 300 100; 400 100]));
            s = tc.openP(p);
            s.setLabel(idAt(s, 100, 100), "Good");
            csv = s.Paths.csv;
            s.close();
            writeLocs(tc.Dir, 'secB_proj_ECM1', mkLocs([100 100; 200 100; 300 100; 400 100; 500 100]));
            fs = tc.holdOpen(csv);                     % the snapshot cannot be replaced during the open
            s = tc.openP(p);
            tc.verifyFalse(s.ReadOnly, 'the journal holds the reconcile, so the open goes on');
            tc.verifyTrue(any(contains(s.LastReconcile.warnings, "_curation.csv")), ...
                'the failed snapshot write is reported');
            s.setLabel(idAt(s, 500, 100), "Bad");      % a label on the appended row
            crash = crashCopy(tc.Dir);
            fs.Close();
            c = tc.openP(fullfile(crash, 'secB_proj_ECM1_locs.csv'));
            tc.verifyEqual(c.NumRows, 5);
            tc.verifyEqual(c.get('Label', idAt(c, 500, 100)), "Bad", 'the label on the appended row survives');
            tc.verifyEqual(c.get('Label', idAt(c, 100, 100)), "Good");
            tc.verifyEqual(nnz(c.get('Label') ~= ""), 2, 'no label lands anywhere else');
        end
    end

    %% ---- finding 3: an unreadable shared JSON -----------------------------------------------------
    methods (Test)
        function unreadableJsonIsNeverOverwritten(tc)
            [e, pv] = tc.twoChannels('secJ');
            e.addRegion(struct('kind', 'exclude', 'xy', [0 0; 30 0; 30 30; 0 30]));
            pv.setLabel(pv.T.CellID(1), "Good");
            pv.flush(); e.flush();
            json = e.Paths.json;
            good = fileread(json);
            bad = good(1:floor(end / 2));               % e.g. a sync tool caught it mid-write
            writeRaw(json, bad);
            e.setLabel(e.T.CellID(2), "Good");
            tc.verifyError(@() e.flush(), 'curation:AtomicIO:jsonUnreadable', 'the failure is surfaced');
            tc.verifyEqual(fileread(json), bad, 'an unreadable JSON must never be rebuilt from nothing');
            writeRaw(json, good);
            e.flush();
            J = jsondecode(fileread(json));
            tc.verifyNumElements(J.regions, 1, 'the regions survive');
            tc.verifyTrue(isfield(J.sources, 'PV2'), 'the other channel''s record survives');
            tc.verifyEqual(J.sources.ECM1.counts.kept, 1, 'the pending record is written once the file reads again');
        end

        function updateJsonRefusesAFileItCannotDecode(tc)
            f = fullfile(tc.Dir, 'x.curation.json');
            writeRaw(f, '{"regions": [ {"id": 1');
            tc.verifyError(@() curation.AtomicIO.updateJson(f, @(J) J), 'curation:AtomicIO:jsonUnreadable');
            tc.verifyEqual(fileread(f), '{"regions": [ {"id": 1', 'nothing is written');
            g = fullfile(tc.Dir, 'new.curation.json');
            curation.AtomicIO.updateJson(g, @(J) setfield(J, 'a', 1)); %#ok<SFLD>
            tc.verifyEqual(jsondecode(fileread(g)).a, 1, 'an absent file starts empty');
        end

        function openWithAnUnreadableJsonIsReadOnlyAndWritesNothing(tc)
            p = writeLocs(tc.Dir, 'secK_proj_ECM1', mkLocs([100 100; 200 100; 300 100]));
            s = tc.openP(p);
            s.setLabel(s.T.CellID(1), "Good");
            paths = s.Paths;
            s.close();
            writeRaw(paths.json, '{"schema": "cellcuration/1.0", "sources": {');
            sig0 = fileSig(paths.json);
            r = tc.openP(p);
            tc.verifyTrue(r.ReadOnly, 'a store that cannot read its JSON record must not write');
            tc.verifyTrue(any(contains(r.LastReconcile.warnings, ".curation.json")), 'the warning names the JSON');
            r.close();
            tc.verifyEqual(fileSig(paths.json), sig0);
        end
    end

    %% ---- finding 4: legacy import on a curated store ---------------------------------------------
    methods (Test)
        function legacyImportNeverRunsOnAStoreLoadedFromASnapshot(tc)
            p = writeLocs(tc.Dir, 'secL_proj_ECM1', resolverTable());
            s = tc.openP(p, 'ImportLegacy', false);
            del = idAt(s, 300, 300);                    % the row the resolver deleted outright
            s.setLabel(del, "Good");                    % a person decided otherwise
            s.close();
            s2 = tc.openP(p);                           % default ImportLegacy=true
            tc.verifyEqual([s2.get('Label', del), s2.get('LabelSource', del)], ["Good", "human"], ...
                'a later default open must not import onto a curated store');
            tc.verifyFalse(logical(s2.Meta.LegacyImported));
        end

        function legacyImportEventIsProofTheImportRan(tc)
            p = writeLocs(tc.Dir, 'secL_proj_ECM1', resolverTable());
            s = tc.openP(p);
            tc.assertTrue(logical(s.Meta.LegacyImported));
            loser = idAt(s, 505, 500);                  % Keep A: row 4 merged into row 3
            tc.assertEqual(s.get('State', loser), "merged");
            s.unmerge(loser);
            paths = s.Paths;
            s.close();
            delete(paths.json);                         % Meta.LegacyImported is lost with the record
            s2 = tc.openP(p);
            tc.verifyEqual(s2.get('State', loser), "active", 'the import must not run again');
        end

        function forcedLegacyImportSkipsRowsAPersonDecided(tc)
            p = writeLocs(tc.Dir, 'secL_proj_ECM1', resolverTable());
            s = tc.openP(p, 'ImportLegacy', false);
            del = idAt(s, 300, 300);
            mov = idAt(s, 700, 700);                    % the resolver moved it to (710, 705)
            a = idAt(s, 500, 500); b = idAt(s, 505, 500);   % resolver: Keep A (b deleted)
            s.setLabel(del, "Good");
            s.moveCell(mov, [702 701]);
            s.mergeCells([a b], b);                     % the person kept B instead
            s.close();
            s2 = tc.openP(p, 'ImportLegacy', "force");
            tc.verifyTrue(logical(s2.Meta.LegacyImported));
            tc.verifyEqual([s2.get('Label', del), s2.get('LabelSource', del)], ["Good", "human"], ...
                'a person''s label is never overwritten by a resolver rule');
            tc.verifyEqual([s2.get('X', mov), s2.get('Y', mov)], [702 701], 'a person''s position is kept');
            tc.verifyEqual(s2.get('State', [a; b]), ["merged"; "active"], 'a person''s merge is kept');
            tc.verifyEqual(s2.get('MergedInto', a), uint32(b));
        end
    end

    %% ---- finding 12: half-written transactions ----------------------------------------------------
    methods (Test)
        function tornTransactionIsNotReplayed(tc)
            p = writeLocs(tc.Dir, 'secT_proj_ECM1', mkLocs([100 100; 200 100; 300 100; 400 100]));
            s = tc.openP(p, 'AutosaveDelay', 3600);
            s.flush();
            ids = s.T.CellID(1:3);
            s.setLabel(ids, "Good");
            crash = crashCopy(tc.Dir);
            jf = fullfile(crash, 'secT_proj_ECM1_curation.journal.csv');
            L = readlines(jf);
            last = find(contains(L, ",Label,"), 1, 'last');
            writeRaw(jf, char(join(L(1:last), newline) + newline));   % a crash after the Label lines
            c = tc.openP(fullfile(crash, 'secT_proj_ECM1_locs.csv'));
            tc.verifyEqual(c.get('Label', ids), ["", "", ""]', 'a half-written transaction is not applied');
            tc.verifyEqual(c.get('LabelSource', ids), ["", "", ""]');
            tc.verifyTrue(any(contains(c.LastReconcile.warnings, "incomplete")), 'the torn tail is reported');
        end

        function journalWithoutMarkersReplaysAllButItsLastTransaction(tc)
            p = writeLocs(tc.Dir, 'secT_proj_ECM1', mkLocs([100 100; 200 100; 300 100; 400 100]));
            s = tc.openP(p, 'AutosaveDelay', 3600);
            s.flush();
            ids = s.T.CellID(1:2);
            s.setLabel(ids(1), "Good");
            s.setFlag(ids(2), "later");
            crash = crashCopy(tc.Dir);
            jf = fullfile(crash, 'secT_proj_ECM1_curation.journal.csv');
            L = readlines(jf);
            L = L(~contains(L, [",#begin,", ",#commit,"]) & strlength(L) > 0);   % a journal of the old format
            writeRaw(jf, char(join(L, newline) + newline));
            c = tc.openP(fullfile(crash, 'secT_proj_ECM1_locs.csv'));
            tc.verifyEqual(c.get('Label', ids(1)), "Good", 'followed by a later transaction: committed');
            tc.verifyEqual(c.get('Flag', ids(2)), "", 'the last transaction of an old journal is suspect');
            tc.verifyTrue(any(contains(c.LastReconcile.warnings, "incomplete")));
        end
    end

    %% ---- finding 13: CellIDs after a crash ---------------------------------------------------------
    methods (Test)
        function cellIdsAreNeverReusedAfterACrash(tc)
            p = writeLocs(tc.Dir, 'secN_proj_ECM1', mkLocs([100 100; 200 100; 300 100]));
            s = tc.openP(p, 'AutosaveDelay', 3600);
            s.flush();
            id = s.addCell([10 10]);
            s.undo();                                   % the id is burnt, not given back
            crash = crashCopy(tc.Dir);
            c = tc.openP(fullfile(crash, 'secN_proj_ECM1_locs.csv'));
            id2 = c.addCell([20 20]);
            tc.verifyGreaterThan(id2, id, 'a CellID handed out before a crash is never handed out again');
        end
    end

    %% ---- finding 14: temporaries of the writer ----------------------------------------------------
    methods (Test)
        function readOnlyOpenLeavesTheWritersTemporaryFiles(tc)
            p = writeLocs(tc.Dir, 'secW_proj_ECM1', mkLocs([100 100; 200 100]));
            w = tc.openP(p);
            tmp = fullfile(tc.Dir, '.secW_proj_ECM1_curation.csv.4242_1_beef.tmp');
            writeRaw(tmp, 'half of a snapshot being written');
            r = tc.openP(p);
            tc.assertTrue(r.ReadOnly);
            tc.verifyTrue(isfile(tmp), 'only the lock holder may clean temporaries');
            tc.verifyFalse(w.ReadOnly);
        end
    end

    %% ---- finding 15: a locs file without detections ------------------------------------------------
    methods (Test)
        function reconcileAgainstEmptyLocsIsRefused(tc)
            s = tc.mem([100 100; 200 100; 300 100]);
            s.setLabel(s.T.CellID(1), "Good");
            T0 = s.T;
            tc.verifyError(@() s.reconcile(mkLocs(zeros(0, 2))), 'curation:Store:emptyLocs');
            tc.verifyEqual(s.T, T0, 'nothing changes');
            rep = s.reconcile(mkLocs(zeros(0, 2)), struct('AllowEmpty', true));
            tc.verifyEqual(rep.nStale, 2, 'AllowEmpty applies it');
        end

        function emptyLocsAtOpenOpensReadOnlyAndKeepsTheRows(tc)
            p = writeLocs(tc.Dir, 'secE_proj_ECM1', mkLocs([100 100; 200 100; 300 100]));
            s = tc.openP(p);
            s.setLabel(s.T.CellID(1), "Good");
            s.close();
            pause(1.1);
            writeLocs(tc.Dir, 'secE_proj_ECM1', mkLocs(zeros(0, 2)));
            r = tc.openP(p);
            tc.verifyTrue(r.ReadOnly, 'an empty locs file is not applied at open');
            tc.verifyTrue(all(r.get('State') == "active"), 'no row went stale');
            tc.verifyTrue(any(contains(r.LastReconcile.warnings, "no detections")));
        end

        function storeCreatedFromEmptyLocsStaysUsable(tc)
            p = writeLocs(tc.Dir, 'secZ_proj_ECM1', mkLocs(zeros(0, 2)));
            s = tc.openP(p);
            s.addCell([10 10]);
            s.close();
            pause(1.1);
            writeLocs(tc.Dir, 'secZ_proj_ECM1', mkLocs(zeros(0, 2)));   % touched, still empty
            r = tc.openP(p);
            tc.verifyFalse(r.ReadOnly, 'a source that never had detections stays valid');
            tc.verifyEqual(r.NumRows, 1);
        end
    end

    %% ---- finding A: two writers of the shared JSON --------------------------------------------------
    methods (Test)
        function aJsonWriteBetweenReadAndWriteIsMergedNotDropped(tc)
            f = fullfile(tc.Dir, 'c.curation.json');
            writeRaw(f, '{"sources": {"A": {"n": 1}}}');
            marker = fullfile(tc.Dir, 'injected.flag');
            curation.AtomicIO.updateJson(f, @(J) injectConcurrentWrite(J, f, marker));
            J = jsondecode(fileread(f));
            tc.verifyEqual(J.sources.A.n, 10, 'our change is written');
            tc.verifyTrue(isfield(J.sources, 'B'), 'the concurrent writer''s change is merged, not dropped');
            tc.verifyTrue(isfield(J, 'jsonRevision'), 'the top-level revision counter is kept');
        end

        function twoStoresWritingAlternatelyKeepEveryRegionAndRecord(tc)
            [e, pv] = tc.twoChannels('secM');
            sq = @(x) [x 0; x + 20 0; x + 20 20; x 20];
            e.addRegion(struct('kind', 'reference', 'xy', sq(0)));
            pv.setLabel(pv.T.CellID(1), "Good"); pv.flush();
            pv.addRegion(struct('kind', 'reference', 'xy', sq(100)));
            e.setLabel(e.T.CellID(1), "Bad"); e.flush();
            e.addRegion(struct('kind', 'reference', 'xy', sq(200)));
            pv.flush();
            pv.setLabel(pv.T.CellID(2), "Good"); pv.flush();
            J = jsondecode(fileread(e.Paths.json));
            tc.verifyNumElements(J.regions, 3, 'every region survives');
            tc.verifyTrue(isfield(J.sources, 'ECM1') && isfield(J.sources, 'PV2'), 'both records survive');
            tc.verifyEqual(J.sources.PV2.counts.kept, 2);
            tc.verifyEqual(J.sources.ECM1.counts.bad, 1);
            tc.verifyFalse(isfile([e.Paths.json '.lock']), 'the JSON lock is released');
        end

        function staleJsonLockIsBroken(tc)
            f = fullfile(tc.Dir, 's.curation.json');
            writeRaw(f, '{"a": 1}');
            lk = [f '.lock'];
            writeRaw(lk, 'left by a process that died');
            java.io.File(lk).setLastModified(java.lang.System.currentTimeMillis() - 60000);
            curation.AtomicIO.updateJson(f, @(J) setfield(J, 'a', 2)); %#ok<SFLD>
            tc.verifyEqual(jsondecode(fileread(f)).a, 2);
            tc.verifyFalse(isfile(lk));
        end
    end

    %% ---- finding B: locking -------------------------------------------------------------------------
    methods (Test)
        function lockOfALiveNonMatlabProcessIsRespected(tc)
            proc = tc.startOtherProcess();
            p = writeLocs(tc.Dir, 'secO_proj_ECM1', mkLocs([100 100; 200 100]));
            lockPath = curation.Store.pathsFor(tc.Dir, 'secO_proj_ECM1').lock;
            writeRaw(lockPath, jsonencode(struct('host', getenv('COMPUTERNAME'), 'user', 'someone', ...
                'pid', double(proc.Id), 'time', char(curation.AtomicIO.isoNow(true)), 'session', 'compiled-app')));
            s = tc.openP(p);
            tc.verifyTrue(s.ReadOnly, 'a running process that is not called MATLAB still holds its lock');
            tc.verifyTrue(s.LockInfo.Held);
        end

        function lockOfAReusedPidIsTakenOver(tc)
            proc = tc.startOtherProcess();
            p = writeLocs(tc.Dir, 'secO_proj_ECM1', mkLocs([100 100; 200 100]));
            lockPath = curation.Store.pathsFor(tc.Dir, 'secO_proj_ECM1').lock;
            writeRaw(lockPath, jsonencode(struct('host', getenv('COMPUTERNAME'), 'user', 'someone', ...
                'pid', double(proc.Id), 'time', '2020-01-01T00:00:00+00:00', 'session', 'old')));
            s = tc.openP(p);
            tc.verifyFalse(s.ReadOnly, 'the pid now belongs to a process started after the lock was written');
            tc.verifyTrue(s.LockInfo.TakenOver);
        end

        function storeWhoseLockWasTakenOverStopsWriting(tc)
            p = writeLocs(tc.Dir, 'secO_proj_ECM1', mkLocs([100 100; 200 100; 300 100]));
            a = tc.openP(p);
            lh = addlistener(a, 'Changed', @(~, e) tc.onChanged(e));
            tc.addTeardown(@() delete(lh));
            b = tc.openP(p, 'Force', true);
            tc.assertFalse(b.ReadOnly);
            id = a.T.CellID(1);
            j0 = fileSig(a.Paths.journal);
            c0 = fileSig(a.Paths.csv);
            tc.verifyError(@() a.setLabel(id, "Good"), 'curation:Store:lockLost');
            tc.verifyTrue(a.ReadOnly, 'the store turns read-only');
            tc.verifyTrue(a.LockInfo.Lost);
            tc.verifyNotEmpty(a.LockInfo.Message);
            tc.verifyTrue(any(tc.Kinds == "lockLost"), 'a Changed event the GUI can show');
            tc.verifyEqual(a.get('Label', id), "", 'the refused change is not kept in memory');
            a.flush();
            tc.verifyEqual(fileSig(a.Paths.journal), j0, 'no journal line after the takeover');
            tc.verifyEqual(fileSig(a.Paths.csv), c0, 'no snapshot after the takeover');
            b.setLabel(id, "Bad");
            tc.verifyEqual(b.get('Label', id), "Bad");
        end
    end

    %% ---- finding C: a restored older snapshot --------------------------------------------------------
    methods (Test)
        function restoredOlderSnapshotIsReplayedForward(tc)
            p = writeLocs(tc.Dir, 'secC_proj_ECM1', mkLocs([100 100; 200 100; 300 100]));
            s = tc.openP(p);
            ids = s.T.CellID;
            s.setLabel(ids(1), "Good");
            s.flush();
            bak = fullfile(tc.Dir, 'backup.csv');
            copyfile(s.Paths.csv, bak);
            s.setLabel(ids(2), "Bad");
            s.flush();
            csv = s.Paths.csv;
            s.close();
            copyfile(bak, csv);                         % e.g. restored from a backup
            r = tc.openP(p);
            tc.verifyFalse(r.ReadOnly);
            tc.verifyEqual(r.get('Label', ids(1:2)), ["Good"; "Bad"], ...
                'the journal is replayed from the revision the restored CSV holds');
            tc.verifyTrue(any(contains(r.LastReconcile.warnings, "_curation.csv")));
        end

        function snapshotNoRecordDescribesOpensReadOnly(tc)
            p = writeLocs(tc.Dir, 'secC_proj_ECM1', mkLocs([100 100; 200 100; 300 100]));
            s = tc.openP(p);
            s.setNote(s.T.CellID(1), "unique-note-1");
            s.setLabel(s.T.CellID(2), "Good");
            csv = s.Paths.csv;
            s.close();
            writeRaw(csv, strrep(fileread(csv), 'unique-note-1', 'edited-note-2'));
            r = tc.openP(p);
            tc.verifyTrue(r.ReadOnly, 'a snapshot no record describes is not trusted for writing');
            w = r.LastReconcile.warnings;
            tc.verifyTrue(any(contains(w, "_curation.csv") & contains(w, ".curation.json")), ...
                'the warning names both files');
        end
    end

    %% ---- helpers -------------------------------------------------------------------------------------
    methods (Access = private)
        function onChanged(tc, e)
            tc.Kinds(end + 1, 1) = string(e.Kind);
        end

        function s = openP(tc, path, varargin)
            o = struct('Reviewer', 'tester', 'AutosaveDelay', 0);
            for k = 1:2:numel(varargin)
                o.(varargin{k}) = varargin{k + 1};
            end
            s = curation.Store.openCsv(path, o);
            tc.addTeardown(@() closeQuiet(s));
        end

        function s = mem(tc, xy)
            s = curation.Store.fromTable(mkLocs(xy), struct('Key', 'ECM1', 'UmPerPixel', 1, 'Reviewer', 'tester'));
            tc.addTeardown(@() closeQuiet(s));
        end

        function [e, pv] = twoChannels(tc, base)
            pe = writeLocs(tc.Dir, [base '_proj_ECM1'], mkLocs([100 100; 200 100; 300 100; 400 100]));
            pp = writeLocs(tc.Dir, [base '_proj_PV2'], mkLocs([110 110; 210 110; 310 110]));
            e = tc.openP(pe);
            pv = tc.openP(pp);
            tc.assertEqual(e.Paths.json, pv.Paths.json, 'both channels share one JSON');
        end

        function fs = holdOpen(tc, path)
            % Open PATH the way a spreadsheet program does: readable, but not replaceable.
            tc.assumeTrue(ispc && NET.isNETSupported, 'needs .NET file sharing modes (Windows)');
            fs = System.IO.File.Open(path, System.IO.FileMode.Open, System.IO.FileAccess.Read, ...
                System.IO.FileShare.Read);
            tc.addTeardown(@() closeStream(fs));
        end

        function proc = startOtherProcess(tc)
            % A running process whose name does not contain "matlab" (stands for a compiled app).
            tc.assumeTrue(ispc && NET.isNETSupported, 'needs .NET process control (Windows)');
            psi = System.Diagnostics.ProcessStartInfo('ping.exe', '-n 60 127.0.0.1');
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            proc = System.Diagnostics.Process.Start(psi);
            tc.addTeardown(@() killQuiet(proc));
            pause(0.2);
        end
    end
end

%% ---- local functions ---------------------------------------------------------------------------------

function L = mkLocs(xy)
n = size(xy, 1);
L = table(xy(:, 1), xy(:, 2), zeros(n, 1), linspace(0.5, 0.9, n)', repmat("img.tif", n, 1), zeros(n, 1), ...
    (1:n)', 'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
end

function p = writeLocs(folder, stem, L)
p = fullfile(folder, [stem '_locs.csv']);
writetable(L, p);
end

function T = resolverTable()
%resolverTable  A resolver-edited locs (CellNeighborResolution): row 2 deleted outright (no partner
%   near), rows 3-4 a "Keep A" pair (4 deleted), row 5 moved to (710, 705), row 6 untouched.
X = [100; 300; 500; 505; 700; 900];
Y = [100; 300; 500; 500; 700; 900];
n = numel(X);
T = table(repmat("img.tif", n, 1), Y, X, zeros(n, 1), [0.91; 0.82; 0.73; 0.64; 0.55; 0.46], zeros(n, 1), ...
    'VariableNames', {'imgName', 'Y', 'X', 'class', 'score', 'thr'});
T.CURATED_X = X; T.CURATED_Y = Y;
T.NeighborResolved = false(n, 1);
T.NeighborResolvedStatus = strings(n, 1);
T.NeighborPairID = strings(n, 1);
T.CURATED_X([2 4]) = NaN; T.CURATED_Y([2 4]) = NaN;
T.NeighborPairID([3 4]) = "3-4"; T.NeighborResolvedStatus([3 4]) = "Keep A";
T.NeighborResolved([3 4]) = true;
T.CURATED_X(5) = 710; T.CURATED_Y(5) = 705;
end

function id = idAt(s, x, y)
T = s.T;
k = find(abs(T.X - x) < 0.011 & abs(T.Y - y) < 0.011);
assert(numel(k) == 1, 'expected one row at (%g, %g), found %d', x, y, numel(k));
id = T.CellID(k);
end

function crash = crashCopy(folder)
% The files as they are on disk now (a crash), without the dead process's lock files.
crash = [folder '_crash'];
if isfolder(crash), rmdir(crash, 's'); end
copyfile(folder, crash);
L = dir(fullfile(crash, '*.lock'));
for k = 1:numel(L)
    delete(fullfile(L(k).folder, L(k).name));
end
end

function writeRaw(f, txt)
fid = fopen(f, 'w', 'n', 'UTF-8');
fwrite(fid, txt, 'char');
fclose(fid);
end

function sig = fileSig(f)
d = dir(f);
fid = fopen(f, 'r'); b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('MD5');
md.update(b);
sig = {d.bytes, sprintf('%02x', typecast(md.digest(), 'uint8'))};
end

function J = injectConcurrentWrite(J, f, marker)
% Called between updateJson's read and its write: the first time, another writer (one that did not
% take the lock) changes the file.
if ~isfile(marker)
    writeRaw(marker, 'x');
    other = jsondecode(fileread(f));
    other.sources.B = struct('n', 2);
    curation.AtomicIO.writeText(f, jsonencode(other));
end
J.sources.A = struct('n', 10);
end

function closeQuiet(s)
try
    if isvalid(s), s.close(); end
catch
end
end

function closeStream(fs)
try fs.Close(); catch, end
end

function killQuiet(p)
try
    if ~p.HasExited, p.Kill(); end
catch
end
end
