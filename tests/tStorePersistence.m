classdef tStorePersistence < matlab.unittest.TestCase
%tStorePersistence  Specification tests of curation.Store files: snapshot, journal, JSON, locks, crash safety.
%   Written from the contract, not from the implementation. Uses the synthetic fixture (ECM1 has no legacy
%   files; PV2 has a legacy QC file, which is irrelevant here except that it is a second source in the dataset).

    properties (Access = private)
        Src char
        Dir char
    end

    properties (Constant, Access = private)
        Base = 'SYN-0001_sec1'
        Stem = 'SYN-0001_sec1_proj_ECM1'
        Cols = ["CellID" "X" "Y" "DET_X" "DET_Y" "class" "score" "rescore" "RescoreSource" "imgName" "thr" "Origin" "State" "MergedInto" ...
            "PosSource" "InLocs" "DetRun" "MatchDistUm" "Label" "LabelSource" "Reviewed" "Flag" "Excluded" "ProposalP" ...
            "ModelP" "ModelVersion" "AuditRole" "Reviewer" "ReviewedAt" "Notes"]
        Classes = ["uint32" "double" "double" "double" "double" "double" "double" "double" "string" "string" "double" "string" "string" ...
            "uint32" "string" "logical" "string" "double" "string" "string" "logical" "string" "logical" "double" "double" ...
            "string" "string" "string" "string" "string"]
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

    %% ---- files and format ----------------------------------------------------------------------
    methods (Test)
        function pathsForUsesTheContractNames(tc)
            p = curation.Store.pathsFor(tc.Dir, tc.Stem, tc.Base);
            tc.verifyEqual(char(p.csv), fullfile(tc.Dir, [tc.Stem '_curation.csv']));
            tc.verifyEqual(char(p.journal), fullfile(tc.Dir, [tc.Stem '_curation.journal.csv']));
            tc.verifyEqual(char(p.json), fullfile(tc.Dir, [tc.Base '.curation.json']));
            tc.verifyEqual(char(p.lock), fullfile(tc.Dir, [tc.Stem '_curation.lock']));
            tc.verifyEqual(char(p.final), fullfile(tc.Dir, [tc.Stem '_final.csv']));
        end

        function flushWritesSnapshotAndJsonAndClearsDirty(tc)
            s = tc.openKey('ECM1');
            s.setLabel(s.T.CellID(1), 'Good', 'human');
            tc.verifyTrue(s.Dirty, 'an edit makes the store dirty');
            s.flush();
            tc.verifyFalse(s.Dirty, 'Dirty goes false after flush');
            tc.verifyTrue(isfile(s.Paths.csv), 'snapshot csv');
            tc.verifyTrue(isfile(s.Paths.json), 'dataset curation json');
            tc.verifyEqual(char(s.Paths.csv), fullfile(tc.Dir, [tc.Stem '_curation.csv']));
        end

        function snapshotHeaderHasContractColumnsInOrder(tc)
            s = tc.openKey('ECM1');
            s.flush();
            first = readlines(s.Paths.csv);
            names = strip(split(erase(first(1), '"'), ','))';
            tc.verifyEqual(names, tc.Cols, 'snapshot column order');
        end

        function reopenedTypesMatchTheContractAndEmptyStringsStayStrings(tc)
            s = tc.openKey('ECM1');
            s.flush(); s.close();
            s2 = tc.openKey('ECM1');
            T = s2.T;
            tc.verifyEqual(string(T.Properties.VariableNames), tc.Cols);
            for k = 1:numel(tc.Cols)
                tc.verifyClass(T.(char(tc.Cols(k))), char(tc.Classes(k)), "column " + tc.Cols(k));
            end
            for v = ["Notes" "AuditRole" "ModelVersion" "Reviewer" "ReviewedAt" "Flag" "Label" "LabelSource"]
                tc.verifyClass(T.(char(v)), 'string', "all-empty column " + v + " must come back as string, not NaN");
                tc.verifyFalse(any(ismissing(T.(char(v)))), "column " + v + " must hold empty strings, not missing");
            end
        end

        function metaHasTheContractFields(tc)
            s = tc.openKey('ECM1');
            M = s.Meta;
            for f = ["Key" "Stem" "Folder" "UmPerPixel" "ImageSize" "LocsFile" "LocsFingerprint" "NextCellId" "Revision" ...
                    "KeptPairs" "SweepDone" "Complete" "LegacyImported"]
                tc.verifyTrue(isfield(M, char(f)) || isprop(M, char(f)), "Meta lacks " + f);
            end
            tc.verifyEqual(string(M.Key), "ECM1");
            tc.verifyEqual(string(M.Stem), string(tc.Stem));
            tc.verifyEqual(M.UmPerPixel, 1.657, 'RelTol', 1e-3, 'um per pixel comes from the TIFF resolution tags');
            tc.verifyEqual(double(M.ImageSize(:))', [600 800]);
            tc.verifyEqual(M.NextCellId, double(max(s.T.CellID)) + 1);
        end

        function jsonHoldsTheContractSchema(tc)
            s = tc.openKey('ECM1');
            s.setLabel(s.T.CellID(1:3), 'Good', 'human');
            s.flush();
            J = jsondecode(fileread(s.Paths.json));
            tc.verifyEqual(string(J.schema), "cellcuration/1.0");
            tc.verifyTrue(isfield(J, 'regions'));
            tc.assertTrue(isfield(J, 'sources') && isfield(J.sources, 'ECM1'), 'sources.ECM1');
            e = J.sources.ECM1;
            for f = ["nextCellId" "revision" "locsFile" "locsFingerprint" "umPerPixel" "imageSize" "legacyImported" ...
                    "keptPairs" "sweepDone" "complete" "counts" "autoReject"]
                tc.verifyTrue(isfield(e, char(f)), "sources.ECM1 lacks " + f);
            end
            tc.verifyEqual(e.nextCellId, s.Meta.NextCellId);
            tc.verifyEqual(e.revision, s.Meta.Revision);
            tc.verifyEqual(e.umPerPixel, 1.657, 'RelTol', 1e-3);
            tc.verifyEqual(e.counts.kept, 3, 'json counts follow the store');
        end
    end

    %% ---- round trips ---------------------------------------------------------------------------
    methods (Test)
        function flushCloseReopenGivesIdenticalTableAndMeta(tc)
            s = tc.openKey('ECM1');
            ids = s.T.CellID;
            s.setLabel(ids(1:5), 'Good', 'human', struct('ProposalP', 0.8, 'Queue', 'Middle', 'PageId', 'p1', 'DwellMs', 10));
            s.setLabel(ids(6:8), 'Bad', 'confirmed');
            s.setLabel(ids(9), 'Uncertain', 'blind');
            s.setLabel(ids(10), 'Bad', 'auto');
            s.setFlag(ids(11), 'recheck');
            s.setNote(ids(12), 'a note, with "quotes" and, commas');
            excludeAround(s, ids(13));                  % review finding 6: exclusion = a region
            s.setAuditRole(ids(14), 'holdout');
            s.moveCell(ids(15), [33.5 44.5]);
            s.mergeCells(ids(16:17), ids(16));
            s.keepBoth(ids(18:19));
            s.addCell([321.25 123.75]);
            s.setModel(ids(20:22), [0.2; 0.4; 0.6], 'm1');
            s.setSweepDone(true);
            s.flush();
            T0 = s.T; M0 = s.Meta;
            s.close();
            s2 = tc.openKey('ECM1');
            tc.verifyEqual(s2.T, T0, 'reopen must give the identical table, every column and type');
            for f = ["Key" "Stem" "Folder" "UmPerPixel" "ImageSize" "LocsFile" "LocsFingerprint" "NextCellId" "Revision" "KeptPairs" "SweepDone" "Complete" "LegacyImported"]
                tc.verifyEqual(s2.Meta.(char(f)), M0.(char(f)), "Meta." + f + " after reopen");
            end
            tc.verifyFalse(s2.Dirty);
        end

        function secondSourceKeepsItsJsonEntry(tc)
            e = tc.openKey('ECM1');
            p = tc.openKey('PV2');
            e.setLabel(e.T.CellID(1), 'Good', 'human');
            p.setLabel(p.T.CellID(1), 'Bad', 'human');
            e.flush(); p.flush();
            J = jsondecode(fileread(e.Paths.json));
            tc.assertTrue(isfield(J.sources, 'ECM1') && isfield(J.sources, 'PV2'), 'both channels have an entry');
            pv0 = J.sources.PV2;
            e.setLabel(e.T.CellID(2), 'Good', 'human');
            e.flush();
            J = jsondecode(fileread(e.Paths.json));
            tc.verifyTrue(isfield(J.sources, 'PV2'), 'writing one source must preserve the other''s entry');
            tc.verifyEqual(J.sources.PV2, pv0);
            tc.verifyEqual(J.sources.ECM1.counts.kept, 2);
            jsonFile = char(e.Paths.json);
            e.close(); p.close();
            % one source alone, later: the other entry still survives
            e2 = tc.openKey('ECM1');
            e2.setLabel(e2.T.CellID(3), 'Good', 'human');
            e2.flush(); e2.close();
            J = jsondecode(fileread(jsonFile));
            tc.verifyEqual(J.sources.PV2, pv0);
        end

        function nextCellIdPersistsAcrossReopen(tc)
            s = tc.openKey('ECM1');
            a = s.addCell([10 10]);
            s.undo();                                   % the id is burnt
            b = s.addCell([20 20]);
            next = s.Meta.NextCellId;
            tc.verifyGreaterThan(b, a);
            s.flush(); s.close();
            s2 = tc.openKey('ECM1');
            tc.verifyEqual(s2.Meta.NextCellId, next, 'NextCellId persists');
            c = s2.addCell([30 30]);
            tc.verifyEqual(double(c), next, 'the next id handed out is NextCellId');
            tc.verifyNotEqual(c, a);
        end

        function closeWithoutFlushStillSavesEdits(tc)
            s = tc.openKey('ECM1');
            id = s.T.CellID(4);
            s.setLabel(id, 'Good', 'human');
            s.close();
            s2 = tc.openKey('ECM1');
            tc.verifyEqual(s2.T.Label(s2.T.CellID == id), "Good", 'close saves');
        end

        function autosaveTimerSavesAfterTheDelay(tc)
            s = tc.openKey('ECM1', 'AutosaveDelay', 0.3);
            s.setLabel(s.T.CellID(1), 'Good', 'human');
            s.scheduleSave();
            t0 = tic;
            while s.Dirty && toc(t0) < 15
                pause(0.2);
            end
            tc.verifyFalse(s.Dirty, 'scheduleSave must flush by itself after AutosaveDelay');
            tc.verifyTrue(isfile(s.Paths.csv));
        end

        function locsFileIsNeverModified(tc)
            f = fullfile(tc.Dir, [tc.Stem '_locs.csv']);
            sig0 = fileSig(f);
            s = tc.openKey('ECM1');
            ids = s.T.CellID;
            s.setLabel(ids(1:10), 'Good', 'human');
            s.addCell([5 5]);
            s.mergeCells(ids(11:12), ids(11));
            s.flush(); s.exportFinal(s.Paths.final); s.close();
            s2 = tc.openKey('ECM1');
            s2.setLabel(ids(20), 'Bad', 'human');
            s2.flush(); s2.close();
            tc.verifyEqual(fileSig(f), sig0, 'the detector locs CSV must stay byte-identical (size, mtime, hash)');
        end
    end

    %% ---- journal and crash safety ----------------------------------------------------------------
    methods (Test)
        function journalIsWrittenPerTransactionAndOnlyAppended(tc)
            s = tc.openKey('ECM1');
            ids = s.T.CellID;
            s.setLabel(ids(1), 'Good', 'human');
            tc.assertTrue(isfile(s.Paths.journal), 'the journal exists right after the first edit, without any flush');
            b1 = readBytes(s.Paths.journal);
            s.setFlag(ids(2), 'later');
            b2 = readBytes(s.Paths.journal);
            tc.verifyGreaterThan(numel(b2), numel(b1), 'each transaction appends to the journal at once');
            tc.verifyEqual(b2(1:numel(b1)), b1, 'append-only: earlier bytes never change');
            s.flush();
            b3 = readBytes(s.Paths.journal);
            tc.verifyEqual(b3(1:numel(b2)), b2, 'a flush does not rewrite or truncate the journal');
            s.undo();
            b4 = readBytes(s.Paths.journal);
            tc.verifyGreaterThan(numel(b4), numel(b3), 'undo is journalled by appending');
            tc.verifyEqual(b4(1:numel(b3)), b3);
        end

        function crashAfterFlushedBaselineLosesNoJournalledEdit(tc)
            s = tc.openKey('ECM1', 'AutosaveDelay', 3600);
            ids = s.T.CellID;
            s.setLabel(ids(1:3), 'Good', 'human');
            s.flush();
            tc.makeEdits(s, ids);
            T0 = sortrows(s.T, 'CellID'); M0 = s.Meta;
            tc.verifyTrue(s.Dirty, 'precondition: unsaved edits');
            copyDir = tc.crashCopy();
            c = tc.openIn(copyDir, 'ECM1');
            tc.verifyEqual(sortrows(c.T, 'CellID'), T0, 'after a crash every journalled edit must be present');
            tc.verifyEqual(c.Meta.SweepDone, M0.SweepDone);
            tc.verifyEqual(c.Meta.NextCellId, M0.NextCellId);
        end

        function crashWithoutAnyFlushLosesNoJournalledEdit(tc)
            s = tc.openKey('ECM1', 'AutosaveDelay', 3600);
            ids = s.T.CellID;
            tc.makeEdits(s, ids);
            T0 = sortrows(s.T, 'CellID');
            copyDir = tc.crashCopy();
            c = tc.openIn(copyDir, 'ECM1');
            tc.verifyEqual(sortrows(c.T, 'CellID'), T0, 'edits since the open must be replayed from the journal');
        end
    end

    %% ---- locking ---------------------------------------------------------------------------------
    methods (Test)
        function lockFileExistsWhileOpenAndGoesOnClose(tc)
            s = tc.openKey('ECM1');
            lockFile = char(s.Paths.lock);
            tc.verifyTrue(isfile(lockFile), 'a lock file while the store is open');
            tc.verifyFalse(s.ReadOnly);
            s.close();
            tc.verifyFalse(isfile(lockFile), 'close removes the lock');
        end

        function secondOpenOfALiveSourceIsReadOnly(tc)
            a = tc.openKey('ECM1');
            b = tc.openKey('ECM1');
            tc.verifyFalse(a.ReadOnly);
            tc.verifyTrue(b.ReadOnly, 'a live lock makes the second open read-only');
            tc.verifyEqual(b.T, a.T, 'a read-only store still shows the data');
            ids = b.T.CellID(1:2);
            mutators = {
                @() b.setLabel(ids(1), 'Good', 'human')
                @() b.setFlag(ids(1), 'later')
                @() b.setNote(ids(1), 'n')
                @() b.setExcluded(ids(1), true)
                @() b.setAuditRole(ids(1), 'holdout')
                @() b.addCell([1 1])
                @() b.moveCell(ids(1), [2 2])
                @() b.mergeCells(ids, ids(1))
                @() b.unmerge(ids(1))
                @() b.keepBoth(ids)
                @() b.setSweepDone(true)
                @() b.setComplete(true)
                @() b.reconcile(readtable(fullfile(tc.Dir, [tc.Stem '_locs.csv']), 'TextType', 'string'))
                };
            for k = 1:numel(mutators)
                tc.verifyError(mutators{k}, 'curation:Store:readOnly', "mutator " + k + " on a read-only store");
            end
            tc.verifyFalse(any(strlength(a.T.Label) > 0), 'the failed mutations changed nothing');
            lockFile = char(a.Paths.lock);
            b.close();
            tc.verifyTrue(isfile(lockFile), 'closing the read-only store must not remove the holder''s lock');
        end

        function afterTheHolderClosesANewOpenIsWritable(tc)
            a = tc.openKey('ECM1');
            a.close();
            b = tc.openKey('ECM1');
            tc.verifyFalse(b.ReadOnly);
            b.setLabel(b.T.CellID(1), 'Good', 'human');
        end

        function forceOpensWritableDespiteALiveLock(tc)
            a = tc.openKey('ECM1');
            b = tc.openKey('ECM1', 'Force', true);
            tc.verifyFalse(b.ReadOnly, 'Force takes the source');
            b.setLabel(b.T.CellID(1), 'Good', 'human');
            tc.verifyNotEmpty(a);
        end

        function staleLockOfADeadProcessOnThisHostIsTakenOver(tc)
            a = tc.openKey('ECM1');
            lockFile = char(a.Paths.lock);
            L = jsondecode(fileread(lockFile));
            a.close();
            tc.assertFalse(isfile(lockFile));
            L.pid = 999999;                              % no such process
            L.session = 'dead-session';
            fid = fopen(lockFile, 'w'); fwrite(fid, jsonencode(L)); fclose(fid);
            b = tc.openKey('ECM1');
            tc.verifyFalse(b.ReadOnly, 'a stale lock (same host, dead pid) is taken over');
            b.setLabel(b.T.CellID(1), 'Good', 'human');
            b.close();
            tc.verifyFalse(isfile(lockFile));
        end

        function readOnlyOptionIsHonouredAndWritesNothing(tc)
            s = tc.openKey('ECM1');
            s.setLabel(s.T.CellID(1:3), 'Good', 'human');
            s.flush(); s.close();
            files = {s.Paths.csv, s.Paths.journal, s.Paths.json};
            sig0 = cellfun(@fileSig, files, 'UniformOutput', false);
            r = tc.openKey('ECM1', 'ReadOnly', true);
            tc.verifyTrue(r.ReadOnly);
            tc.verifyError(@() r.setLabel(r.T.CellID(5), 'Good', 'human'), 'curation:Store:readOnly');
            tc.verifyEqual(nnz(r.kept().CellID > 0), 3);
            r.close();
            tc.verifyEqual(cellfun(@fileSig, files, 'UniformOutput', false), sig0, 'a read-only session writes nothing');
        end
    end

    methods (Access = private)
        function makeEdits(~, s, ids)
            s.setLabel(ids(4:6), 'Good', 'confirmed');
            s.setLabel(ids(7), 'Bad', 'human');
            s.setLabel(ids(8), "", 'human');
            s.setFlag(ids(9), 'later');
            s.setNote(ids(10), 'crash note');
            excludeAround(s, ids(11));                  % review finding 6: exclusion = a region
            s.moveCell(ids(12), [40.5 41.5]);
            s.mergeCells(ids(13:14), ids(13));
            s.addCell([250.5 260.5]);
            s.undo();
            s.addCell([251.5 261.5]);
            s.setSweepDone(true);
        end

        function copyDir = crashCopy(tc)
            % Simulate a crash: the files as they are on disk now, with the dead process's lock file dropped.
            copyDir = fullfile(fileparts(tc.Dir), 'crashed');
            copyfile(tc.Dir, copyDir);
            L = dir(fullfile(copyDir, '*_curation.lock'));
            for k = 1:numel(L)
                delete(fullfile(L(k).folder, L(k).name));
            end
        end

        function s = openIn(tc, folder, key)
            csv = fullfile(folder, sprintf('%s_proj_%s_locs.csv', tc.Base, key));
            mf = CellDatasetManifest.forCsv(csv);
            s = curation.Store.open(mf, key, mkOpts());
            tc.addTeardown(@() closeQuiet(s));
        end

        function s = openKey(tc, key, varargin)
            csv = fullfile(tc.Dir, sprintf('%s_proj_%s_locs.csv', tc.Base, key));
            mf = CellDatasetManifest.forCsv(csv);
            s = curation.Store.open(mf, key, mkOpts(varargin{:}));
            tc.addTeardown(@() closeQuiet(s));
        end
    end
end

%% ---- helpers ---------------------------------------------------------------------------------

function b = readBytes(f)
fid = fopen(f, 'r'); b = fread(fid, Inf, '*uint8'); fclose(fid);
end

function sig = fileSig(f)
d = dir(f);
b = readBytes(f);
md = java.security.MessageDigest.getInstance('MD5');
md.update(b);
sig = {d.bytes, d.datenum, sprintf('%02x', typecast(md.digest(), 'uint8'))};
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
