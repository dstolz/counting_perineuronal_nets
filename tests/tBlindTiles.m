classdef tBlindTiles < matlab.unittest.TestCase
    %tBlindTiles  curation.BlindTiles: the holdout list (size, sampling of unreviewed rows only, written
    %   once and then stable, applied to a store idempotently with gone/reviewed rows counted) and the
    %   confirm audit (when it is due, 2% with at least 5, never twice).

    properties
        Folder
        Truth
    end

    methods (TestMethodSetup)
        function makeProject(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Folder = fullfile(fx.Folder, 'proj');
            [~, tc.Truth] = makeSyntheticDataset(fullfile(tc.Folder, 'SUBJ-ID-9001'), ...
                'BaseName', "SUBJ-ID-9001IHC_sec1", 'Variants', false);
            makeSyntheticDataset(fullfile(tc.Folder, 'SUBJ-ID-9002'), 'BaseName', "SUBJ-ID-9002IHC_sec1", ...
                'Seed', 2, 'Variants', false);
        end
    end

    methods
        function st = openStore(tc, sub, base, key)
            locs = fullfile(tc.Folder, sub, base + "_proj_" + key + "_locs.csv");
            mf = CellDatasetManifest.forCsv(char(locs));
            st = curation.Store.open(mf, key, struct('AutosaveDelay', 0));
            tc.addTeardown(@() tBlindTiles.closeStore(st));
        end

        function idx = index(tc)
            idx = curation.ProjectIndex.build(tc.Folder, struct('CacheDir', fullfile(tempdir, ...
                ['tBlindTiles_' char(curation.Hash.of(string(tc.Folder)))])));
        end
    end

    methods (Static)
        function closeStore(st)
            if ~isempty(st) && isvalid(st)
                st.close();
                delete(st);
            end
        end

        function T = queueTable(st)
            T = table(st.get('CellID'), st.get('State'), st.get('Reviewed'), st.get('Excluded'), ...
                st.get('Label'), st.get('Flag'), st.get('LabelSource'), st.get('AuditRole'), ...
                'VariableNames', {'CellID', 'State', 'Reviewed', 'Excluded', 'Label', 'Flag', 'LabelSource', 'AuditRole'});
        end
    end

    methods (Test)
        function holdoutSizeIsCappedForSmallProjects(tc)
            tc.verifyEqual(curation.BlindTiles.holdoutSize(100000), 400, 'a large project: 400 per kind');
            tc.verifyEqual(curation.BlindTiles.holdoutSize(386), 19, 'a small one: 5% of its candidates');
            tc.verifyEqual(curation.BlindTiles.holdoutSize(0), 0);
            tc.verifyEqual(curation.BlindTiles.holdoutSize(1000, struct('Target', 30)), 30);
        end

        function holdoutIsWrittenOnceAndAppliedIdempotently(tc)
            % a row reviewed before sampling is never chosen
            st = tc.openStore('SUBJ-ID-9001', "SUBJ-ID-9001IHC_sec1", "ECM1");
            ids = st.get('CellID');
            st.setLabel(ids(1:20), "Good", "human");
            st.flush();
            idx = tc.index();
            L = curation.BlindTiles.sampleHoldout(idx, "pnn");
            T = idx.table("pnn");
            n = nnz(T.State == "active" & ~T.Excluded);
            tc.verifyEqual(height(L), curation.BlindTiles.holdoutSize(n));
            tc.verifyEqual(numel(unique(L.SourceId)), 2, 'spread over both sections');
            mf =CellDatasetManifest.forCsv(char(fullfile(tc.Folder, 'SUBJ-ID-9001', ...
                "SUBJ-ID-9001IHC_sec1_proj_ECM1_locs.csv")));
            sid = curation.BlindTiles.sourceId(tc.Folder, mf.Folder, mf.Base, "ECM1");
            tc.verifyTrue(any(L.SourceId == sid), 'the source id is the one the index uses');
            mine = L.CellID(L.SourceId == sid);
            tc.verifyEmpty(intersect(mine, ids(1:20)), 'reviewed rows are never chosen');
            % written once: a second list does not replace it
            [L1, w1] = curation.BlindTiles.writeHoldout(tc.Folder, "pnn", L);
            tc.verifyTrue(w1);
            tc.verifyTrue(isfile(curation.BlindTiles.holdoutPath(tc.Folder, "pnn")));
            L2 = L;
            L2.CellID(:) = 1;
            [L3, w2] = curation.BlindTiles.writeHoldout(tc.Folder, "pnn", L2);
            tc.verifyFalse(w2, 'the first list wins');
            tc.verifyEqual(L3.CellID, L1.CellID);
            tc.verifyEqual(curation.BlindTiles.readHoldout(tc.Folder, "pnn"), L1, 'read back exactly');
            % applied: idempotent, reviewed and gone rows counted
            st.setLabel(mine(1), "Bad", "human");      % reviewed after it was chosen
            rep = curation.BlindTiles.applyHoldout(st, sid, L1);
            tc.verifyEqual(rep.Listed, numel(mine));
            tc.verifyEqual(rep.Reviewed, 1);
            tc.verifyEqual(rep.Applied, numel(mine) - 1);
            tc.verifyEqual(st.get('AuditRole', mine(2:end)), repmat("holdout", numel(mine) - 1, 1));
            tc.verifyEqual(st.get('AuditRole', mine(1)), "", 'a reviewed row stays ordinary');
            rep2 = curation.BlindTiles.applyHoldout(st, sid, L1);
            tc.verifyEqual(rep2.Applied, 0, 'idempotent');
            tc.verifyEqual(rep2.Already, numel(mine) - 1);
            Lg = L1;
            Lg.CellID(Lg.SourceId == sid) = Lg.CellID(Lg.SourceId == sid) + 100000;
            rep3 = curation.BlindTiles.applyHoldout(st, sid, Lg);
            tc.verifyEqual(rep3.Gone, numel(mine), 'rows that no longer exist are counted');
            % every pending holdout row is a pending blind tile
            T = tBlindTiles.queueTable(st);
            tc.verifyEqual(nnz(curation.BlindTiles.pendingMask(T)), numel(mine) - 1);
        end

        function confirmAuditOncePerSource(tc)
            st = tc.openStore('SUBJ-ID-9001', "SUBJ-ID-9001IHC_sec1", "ECM1");
            ids = st.get('CellID');
            T = tBlindTiles.queueTable(st);
            tc.verifyFalse(curation.BlindTiles.needsConfirmAudit(T), 'cells are left to review');
            st.setLabel(ids(1:10), "Good", "human");
            st.setLabel(ids(11:end), "Bad", "confirmed");
            T = tBlindTiles.queueTable(st);
            tc.verifyTrue(curation.BlindTiles.needsConfirmAudit(T));
            tc.verifyFalse(curation.BlindTiles.needsConfirmAudit(T, true), 'not for a complete source');
            a = curation.BlindTiles.confirmAuditIds(T, "x|ECM1");
            nConf = numel(ids) - 10;
            tc.verifyEqual(numel(a), max(5, ceil(0.02 * nConf)), '2%, at least 5');
            tc.verifyTrue(all(ismember(a, ids(11:end))), 'only rows confirmed by default');
            tc.verifyEqual(curation.BlindTiles.confirmAuditIds(T, "x|ECM1"), a, 'deterministic');
            tc.verifyNotEqual(curation.BlindTiles.confirmAuditIds(T, "y|ECM1"), a, 'a stream of its own per source');
            st.setAuditRole(a, "confirm-audit");
            T = tBlindTiles.queueTable(st);
            tc.verifyFalse(curation.BlindTiles.needsConfirmAudit(T), 'once per source');
            tc.verifyEqual(nnz(curation.BlindTiles.pendingMask(T)), numel(a));
            st.setLabel(a, "Good", "blind");
            T = tBlindTiles.queueTable(st);
            tc.verifyEqual(nnz(curation.BlindTiles.pendingMask(T)), 0, 'decided blind: not pending');
            tc.verifyEqual(curation.BlindTiles.ordinaryLeft(T), 0);
        end
    end
end
