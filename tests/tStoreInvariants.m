classdef tStoreInvariants < matlab.unittest.TestCase
%tStoreInvariants  Regression tests of curation.Store invariants: a person's label counts even on a
%   stale row; a failing call never undoes the rest of its batch and never writes before it has
%   validated its arguments; the default JSON name agrees with the manifest; locs time stamps are
%   compared in UTC. Review findings 10, 11, 17 and D.
%
%   Run: pwsh -File tools\Run-Tests.ps1 tStoreInvariants

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

    %% ---- finding 10 --------------------------------------------------------------------------------
    methods (Test)
        function personLabelOnAStaleRowMakesItActiveAndCounted(tc)
            s = tc.mem([100 100; 200 100; 300 100; 400 100]);
            id = idAt(s, 100, 100);
            s.reconcile(mkLocs([200 100; 300 100; 400 100]));
            tc.assertEqual(s.get('State', id), "stale");
            s.setLabel(id, "Good");
            tc.verifyEqual(s.get('State', id), "active", 'a person''s label brings a stale row back');
            tc.verifyTrue(ismember(id, s.kept().CellID), 'and it is counted');
            tc.verifyTrue(s.undo());
            tc.verifyEqual([s.get('State', id) s.get('Label', id)], ["stale" ""], 'one undo step');
            s.setLabel(id, "Bad", "auto");
            tc.verifyEqual(s.get('State', id), "stale", 'an auto label is not a person''s decision');
        end
    end

    %% ---- finding 11 --------------------------------------------------------------------------------
    methods (Test)
        function failingCallInsideABatchRollsBackOnlyItself(tc)
            s = tc.mem([100 100; 200 100; 300 100; 400 100]);
            ids = s.T.CellID;
            s.beginBatch("page");
            s.setLabel(ids(1), "Good");
            tc.verifyError(@() s.mergeCells(ids(2:3), ids(2), [NaN 5]), 'curation:Store:badArgument');
            s.setLabel(ids(4), "Bad");
            s.endBatch();
            tc.verifyEqual(s.get('Label', ids([1 4])), ["Good"; "Bad"], 'the rest of the batch is kept');
            tc.verifyEqual(s.get('State', ids(2:3)), ["active"; "active"], 'the failed merge wrote nothing');
            tc.verifyTrue(s.undo());
            tc.verifyEqual(s.get('Label', ids([1 4])), [""; ""], 'the batch is still one undo step');
            tc.verifyFalse(s.CanUndo);
        end

        function everyMutatorValidatesItsArgumentsBeforeWriting(tc)
            s = tc.mem([100 100; 200 100; 300 100; 400 100]);
            ids = s.T.CellID;
            T0 = s.T;
            bad = {
                @() s.setLabel(ids(1:3), "Good", "human", struct('ProposalP', [0.1 0.2]))
                @() s.setLabel(ids(1), "Maybe")
                @() s.setLabel(99999, "Good")
                @() s.setFlag(ids(1), "bogus")
                @() s.setNote(ids(1), ["a" "b"])
                @() s.setExcluded(ids(1:3), [true false])
                @() s.setAuditRole(ids(1), "bogus")
                @() s.addCell([1 NaN])
                @() s.addCell([1 2; 3 4], struct('ProposalP', [0.1 0.2 0.3]))
                @() s.addCell([1 2], struct('PosSource', "det"))
                @() s.moveCell(ids(1:2), [1 2 3])
                @() s.moveCell(ids(1), [1 2], "bogus")
                @() s.mergeCells(ids(1:2), ids(1), [NaN 1])
                @() s.mergeCells(ids(1:2), ids(1:2))
                @() s.keepBoth(ids(1:3)')
                @() s.setAutoReject(struct('tau', 'x'))
                @() s.setSweepDone([true false])
                @() s.addRegion(struct('kind', 'bogus', 'xy', [0 0; 1 0; 1 1]))
                @() s.addRegion(struct('kind', 'exclude', 'xy', [0 0; 1 1]))
                };
            s.beginBatch("page");
            s.setLabel(ids(4), "Good");
            for k = 1:numel(bad)
                tc.verifyError(bad{k}, ?MException, sprintf('invalid call %d', k));
            end
            s.endBatch();
            T1 = s.T;
            tc.verifyEqual(T1.Label(T1.CellID == ids(4)), "Good", 'the valid call of the batch is kept');
            tc.verifyEqual(T1(T1.CellID ~= ids(4), :), T0(T0.CellID ~= ids(4), :), 'no invalid call left a trace');
            tc.verifyEmpty(s.regions());
            tc.verifyFalse(s.Meta.SweepDone);
            tc.verifyTrue(s.undo());
            tc.verifyEqual(s.T, T0);
            tc.verifyFalse(s.CanUndo, 'one undo step');
        end
    end

    %% ---- finding 17 --------------------------------------------------------------------------------
    methods (Test)
        function defaultJsonBaseMatchesTheManifestForCsv(tc)
            stems = ["SYN-0001_sec1_proj_ECM1", "sec1_ECM1", "x_proj_ECM_1", "plainname", "a_b_PV2", "s_2_proj_GFP12"];
            for stem = stems
                f = fullfile(tc.Dir, char(stem + "_locs.csv"));
                writetable(mkLocs([1 1]), f);
                mf = CellDatasetManifest.forCsv(f);
                p = curation.Store.pathsFor(tc.Dir, char(stem));
                tc.verifyEqual(lower(p.json), lower(char(mf.curationJsonPath())), ...
                    "pathsFor's default JSON for " + stem + " must be the manifest's (forCsv)");
            end
        end
    end

    %% ---- finding D ---------------------------------------------------------------------------------
    methods (Test)
        function locsFingerprintRecordsTheModificationTimeInUtc(tc)
            f = fullfile(tc.Dir, 'u_proj_ECM1_locs.csv');
            writetable(mkLocs([1 1; 2 2]), f);
            fp = curation.Reconciler.fingerprint(f, 2);
            ms = java.io.File(f).lastModified();
            t = datetime(double(ms) / 1000, 'ConvertFrom', 'posixtime', 'TimeZone', 'UTC');
            expected = char(t, 'yyyy-MM-dd''T''HH:mm:ss') + "Z";
            tc.verifySubstring(string(fp), "mtime=" + expected, 'a daylight-saving change must not alter the stamp');
            tc.verifyTrue(curation.Reconciler.sameStamp(fp, f));
        end

        function legacyLocalFingerprintOfAnUnchangedFileDoesNotReconcile(tc)
            f = fullfile(tc.Dir, 'v_proj_ECM1_locs.csv');
            writetable(mkLocs([100 100; 200 100; 300 100]), f);
            s = curation.Store.openCsv(f, struct('AutosaveDelay', 0));
            json = s.Paths.json;
            s.close();
            d = dir(f);
            legacy = sprintf('bytes=%d;mtime=%s;rows=%d', d.bytes, ...
                char(datetime(d.datenum, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd''T''HH:mm:ss')), 3);
            J = jsondecode(fileread(json));
            J.sources.ECM1.locsFingerprint = legacy;   % as written before the UTC change
            curation.AtomicIO.writeText(json, jsonencode(J));
            s2 = curation.Store.openCsv(f, struct('AutosaveDelay', 0));
            tc.addTeardown(@() closeQuiet(s2));
            tc.verifyFalse(s2.LastReconcile.Ran, 'an older local-time stamp of the same file is not a change');
        end
    end

    methods (Access = private)
        function s = mem(tc, xy)
            s = curation.Store.fromTable(mkLocs(xy), struct('Key', 'ECM1', 'UmPerPixel', 1, 'Reviewer', 'tester'));
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
