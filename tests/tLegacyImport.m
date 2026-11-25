classdef tLegacyImport < matlab.unittest.TestCase
%tLegacyImport  Specification tests of the one-time legacy import of curation.Store (QC file, resolver columns).
%   Written from the contract, not from the implementation, against the truth of
%   tests\fixtures\makeSyntheticDataset: truth.qc (PV2 channel) and truth.resolver (ECM1 channel).

    properties (Access = private)
        Src char
        Truth struct
        Dir char
    end

    properties (Constant, Access = private)
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

    %% ---- legacy QC file -------------------------------------------------------------------------
    methods (Test)
        function qcLabelsLandOnTheirCells(tc)
            s = tc.openKey('PV2');
            tc.checkQcImport(s);
        end

        function qcRowOrderShuffledAndSourceRowStaleStillLandsOnTheRightCells(tc)
            f = tc.file('_proj_PV2_locs_QC.csv');
            Q = readtable(f, 'TextType', 'string');
            p = randperm(RandStream('mt19937ar', 'Seed', 11), height(Q));
            tc.assertNotEqual(p, 1:height(Q));
            writetable(Q(p, :), f);                     % QCSourceRow now disagrees with the locs row order
            s = tc.openKey('PV2');
            tc.checkQcImport(s);
        end

        function qcCountsAddUpAndOnlyGoodIsKept(tc)
            s = tc.openKey('PV2');
            q = tc.Truth.qc;
            c = s.counts();
            tc.verifyEqual(c.good, nnz(q.Label == "Good"));
            tc.verifyEqual(c.bad, nnz(q.Label == "Bad"));
            tc.verifyEqual(c.uncertain, nnz(q.Label == "Uncertain"));
            tc.verifyEqual(c.kept, nnz(q.Label == "Good"), 'legacy-qc Good is kept');
            tc.verifyEqual(c.reviewed, nnz(ismember(q.Label, ["Good" "Bad" "Uncertain"])), 'reviewed = imported labeled rows');
            tc.verifyEqual(c.total, height(tc.Truth.PV2.locs));
            tc.verifyEqual(c.flagged, nnz(q.Label == "Ignore"), 'Ignore rows become Flag=later');
        end

        function legacyFilesAreNeverModified(tc)
            files = {tc.file('_proj_PV2_locs_QC.csv'), tc.file('_proj_PV2_locs.csv')};
            sig0 = cellfun(@fileSig, files, 'UniformOutput', false);
            s = tc.openKey('PV2');
            s.setLabel(s.T.CellID(1:5), 'Good', 'human');
            s.flush(); s.close();
            tc.verifyEqual(cellfun(@fileSig, files, 'UniformOutput', false), sig0, ...
                'the QC file and the locs file must stay byte-identical');
        end

        function aSecondOpenDoesNotImportAgain(tc)
            s = tc.openKey('PV2');
            tc.verifyTrue(logical(s.Meta.LegacyImported), 'first open imports');
            q = tc.Truth.qc;
            L = tc.Truth.PV2.locs;
            goodRow = q.Row(find(q.Label == "Good", 1));
            clearRow = q.Row(find(q.Label == "Bad", 1));
            idGood = idAtDet(s.T, L.X(goodRow), L.Y(goodRow));
            idClear = idAtDet(s.T, L.X(clearRow), L.Y(clearRow));
            s.setLabel(idGood, 'Bad', 'human');         % overrides an imported label
            s.setLabel(idClear, "", 'human');           % clears an imported label
            s.flush(); s.close();
            s2 = tc.openKey('PV2');
            r1 = s2.T(s2.T.CellID == idGood, :);
            r2 = s2.T(s2.T.CellID == idClear, :);
            tc.verifyEqual([r1.Label r1.LabelSource], ["Bad" "human"], 'a re-import would have restored Good/legacy-qc');
            tc.verifyEqual(r2.Label, "", 'a re-import would have restored the cleared label');
            tc.verifyTrue(logical(s2.Meta.LegacyImported));
        end

        function importLegacyFalseImportsNothing(tc)
            s = tc.openKey('PV2', 'ImportLegacy', false);
            tc.verifyTrue(all(s.T.Label == "") && ~any(s.T.Reviewed), 'no legacy label may appear');
            tc.verifyFalse(any(s.T.LabelSource == "legacy-qc"));
            tc.verifyFalse(logical(s.Meta.LegacyImported));
        end

        function ecmChannelHasNoLegacyFilesAndStaysUntouched(tc)
            s = tc.openKey('ECM1');
            tc.verifyTrue(all(s.T.Label == ""), 'no QC file for ECM1: nothing to import');
            tc.verifyEqual(s.counts().merged, 0);
        end
    end

    %% ---- legacy resolver columns -------------------------------------------------------------------
    methods (Test)
        function resolverKeepAAndKeepBLosersAreMergedNotBad(tc)
            [s, R, id] = tc.openResolver();
            res = tc.Truth.resolver;
            % Keep A: row B lost to row A
            a = res.keepA;
            loser = rowOfId(s.T, id(a(2))); winner = rowOfId(s.T, id(a(1)));
            tc.verifyEqual(loser.State, "merged", 'Keep A: B is merged away');
            tc.verifyEqual(loser.MergedInto, uint32(id(a(1))), 'MergedInto = the partner''s CellID');
            tc.verifyNotEqual(loser.Label, "Bad", 'a duplicate loser is never Bad');
            tc.verifyEqual(winner.State, "active");
            tc.verifyEqual(winner.MergedInto, uint32(0));
            % Keep B: row A lost to row B
            b = res.keepB;
            loser = rowOfId(s.T, id(b(1))); winner = rowOfId(s.T, id(b(2)));
            tc.verifyEqual(loser.State, "merged", 'Keep B: A is merged away');
            tc.verifyEqual(loser.MergedInto, uint32(id(b(2))));
            tc.verifyNotEqual(loser.Label, "Bad");
            tc.verifyEqual(winner.State, "active");
            tc.verifyNotEmpty(R);
        end

        function resolverMergedPairBecomesOneMergedRowAtTheMean(tc)
            [s, R, id] = tc.openResolver();
            res = tc.Truth.resolver;
            m = res.merged;
            mergedId = id(res.mergedRow);
            mr = rowOfId(s.T, mergedId);
            for k = 1:2
                p = rowOfId(s.T, id(m(k)));
                tc.verifyEqual(p.State, "merged", 'both parents of a Merged pair are merged away');
                tc.verifyEqual(p.MergedInto, uint32(mergedId), 'into the appended merged row');
                tc.verifyNotEqual(p.Label, "Bad");
            end
            tc.verifyEqual(mr.Origin, "merged");
            tc.verifyEqual(mr.State, "active");
            mean2 = [mean(R.X(m)) mean(R.Y(m))];
            tc.verifyEqual([mr.X mr.Y], mean2, 'AbsTol', 0.011, 'the merged row sits at the mean of its parents');
            tc.verifyEqual([mr.X mr.Y], res.mergedXY, 'AbsTol', 0.011);
        end

        function resolverRowDeletedOutrightIsBadLegacyResolver(tc)
            [s, ~, id] = tc.openResolver();
            res = tc.Truth.resolver;
            r = rowOfId(s.T, id(res.deletedRow));
            tc.verifyEqual(r.Label, "Bad");
            tc.verifyEqual(r.LabelSource, "legacy-resolver");
            tc.verifyTrue(r.Reviewed);
            tc.verifyEqual(r.MergedInto, uint32(0), 'a deleted row is not part of any merge');
        end

        function resolverKeepBothPairIsRecordedAndNothingMerges(tc)
            [s, ~, id] = tc.openResolver();
            kb = tc.Truth.resolver.keepBoth;
            tc.verifyTrue(hasPair(s.Meta.KeptPairs, id(kb)), 'Keep Both pair is in Meta.KeptPairs');
            for k = 1:2
                r = rowOfId(s.T, id(kb(k)));
                tc.verifyEqual(r.State, "active");
                tc.verifyNotEqual(r.Label, "Bad");
            end
        end

        function resolverHandAddedRowIsAddedAndHuman(tc)
            [s, ~, id] = tc.openResolver();
            res = tc.Truth.resolver;
            r = rowOfId(s.T, id(res.addedRow));
            tc.verifyEqual(r.Origin, "added");
            tc.verifyEqual(r.PosSource, "human");
            tc.verifyEqual([r.X r.Y], res.addedXY, 'AbsTol', 0.011);
            tc.verifyEqual(r.State, "active");
        end

        function resolverCountsAndUntouchedRows(tc)
            [s, ~, id] = tc.openResolver();
            res = tc.Truth.resolver;
            c = s.counts();
            tc.verifyEqual(height(s.T), res.nRows, 'one row per row of the resolver file');
            tc.verifyEqual(c.merged, 4, 'Keep A loser, Keep B loser and the two parents of the Merged pair');
            tc.verifyEqual(c.bad, 1, 'only the row deleted outright is Bad; merged losers are not');
            tc.verifyEqual(c.added, 1);
            % rows of unresolved pairs and everything else are untouched
            unresolved = unique([res.pairs.RowA(res.pairs.Status == "Unresolved"); res.pairs.RowB(res.pairs.Status == "Unresolved")]);
            for k = unresolved(:)'
                r = rowOfId(s.T, id(k));
                tc.verifyEqual([r.State r.Label], ["active" ""], "unresolved pair row " + k + " must be unchanged");
            end
            tc.verifyEqual(numel(unique(s.T.CellID)), height(s.T));
        end

        function resolverFilesAreNotModifiedAndImportRunsOnce(tc)
            f = tc.file('_proj_ECM1_locs.csv');
            copyfile(tc.file('_proj_ECM1_locs.resolver.csv'), f);
            sig0 = fileSig(f);
            s = tc.openKey('ECM1');
            res = tc.Truth.resolver;
            R = readtable(f, 'TextType', 'string');
            id = idsByXY(s.T, R);
            tc.verifyEqual(fileSig(f), sig0, 'the resolver-format locs file must not be modified');
            % undo what the import did to one row; a reopen must not redo it
            loser = id(res.keepA(2));
            s.unmerge(loser);
            s.flush(); s.close();
            s2 = tc.openKey('ECM1');
            tc.verifyEqual(rowOfId(s2.T, loser).State, "active", 'the import must not run a second time');
            s2.close();
            tc.verifyEqual(fileSig(f), sig0);
        end
    end

    methods (Access = private)
        function checkQcImport(tc, s)
            q = tc.Truth.qc;
            L = tc.Truth.PV2.locs;
            n = height(L);
            ids = idsByDet(s.T, L);
            tc.assertEqual(height(s.T), n);
            labeled = false(n, 1);
            labeled(q.Row) = true;
            for k = 1:height(q)
                r = rowOfId(s.T, ids(q.Row(k)));
                lab = q.Label(k);
                if ismember(lab, ["Good" "Bad" "Uncertain"])
                    tc.verifyEqual([r.Label r.LabelSource], [lab "legacy-qc"], "QC row " + q.Row(k) + " label " + lab);
                    tc.verifyTrue(r.Reviewed, "QC row " + q.Row(k) + " must be Reviewed");
                else
                    tc.verifyEqual(r.Label, "", 'Ignore/custom category -> no label');
                    tc.verifyEqual(r.Flag, "later", 'Ignore/custom category -> Flag=later');
                    tc.verifyTrue(contains(r.Notes, lab, 'IgnoreCase', true), 'a note mentions the legacy label');
                end
            end
            others = ~labeled;
            T = s.T(ismember(s.T.CellID, ids(others)), :);
            tc.verifyTrue(all(T.Label == "" & ~T.Reviewed & T.Flag == ""), 'rows the QC file did not review stay untouched');
        end

        function [s, R, id] = openResolver(tc)
            copyfile(tc.file('_proj_ECM1_locs.resolver.csv'), tc.file('_proj_ECM1_locs.csv'));
            s = tc.openKey('ECM1');
            R = readtable(tc.file('_proj_ECM1_locs.csv'), 'TextType', 'string');
            id = idsByXY(s.T, R);
        end

        function f = file(tc, suffix)
            f = fullfile(tc.Dir, [tc.Base suffix]);
        end

        function s = openKey(tc, key, varargin)
            csv = tc.file(sprintf('_proj_%s_locs.csv', key));
            mf = CellDatasetManifest.forCsv(csv);
            s = curation.Store.open(mf, key, mkOpts(varargin{:}));
            tc.addTeardown(@() closeQuiet(s));
        end
    end
end

%% ---- helpers ---------------------------------------------------------------------------------

function r = rowOfId(T, id)
r = T(T.CellID == id, :);
assert(height(r) == 1, 'no unique row for CellID %d', id);
end

function id = idAtDet(T, x, y)
r = T(abs(T.DET_X - x) < 0.011 & abs(T.DET_Y - y) < 0.011, :);
assert(height(r) == 1, 'no unique row at detector position (%g, %g)', x, y);
id = r.CellID;
end

function ids = idsByDet(T, L)
[tf, loc] = ismember([L.X L.Y], [T.DET_X T.DET_Y], 'rows');
assert(all(tf), 'some detections have no row');
ids = T.CellID(loc);
end

function ids = idsByXY(T, R)
%idsByXY  CellID of each row of the resolver table: the row sitting at its X/Y (effective position).
ids = zeros(height(R), 1, 'uint32');
for k = 1:height(R)
    r = T(abs(T.X - R.X(k)) < 0.011 & abs(T.Y - R.Y(k)) < 0.011, :);
    assert(height(r) == 1, 'resolver row %d: %d store rows at (%g, %g)', k, height(r), R.X(k), R.Y(k));
    ids(k) = r.CellID;
end
end

function tf = hasPair(kp, ids)
ids = sort(double(ids(:)'));
tf = false;
if isnumeric(kp) && size(kp, 2) == 2
    tf = any(all(sort(double(kp), 2) == ids, 2));
elseif iscell(kp)
    tf = any(cellfun(@(c) isequal(sort(double(c(:)')), ids), kp));
end
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
