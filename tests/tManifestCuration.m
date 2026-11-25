classdef tManifestCuration < matlab.unittest.TestCase
    %TMANIFESTCURATION  The manifest's 'curation' stage: path resolution, status
    %   derived from the curation JSON that curation.Store writes, and provenance.

    properties
        Folder
        Truth
        EcmLocs
    end

    methods (TestMethodSetup)
        function buildFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [tc.Folder, tc.Truth] = makeSyntheticDataset(fullfile(fx.Folder, 'ds'));
            tc.EcmLocs = fullfile(tc.Folder, [char(tc.Truth.baseName) '_proj_ECM1_locs.csv']);
            tc.assertTrue(isfile(tc.EcmLocs), 'fixture ECM locs file must exist');
        end
    end

    methods (Test)
        function stageIsKnown(tc)
            tc.verifyTrue(any(strcmp(CellDatasetManifest.STAGES, 'curation')));
            mf = CellDatasetManifest.forCsv(tc.EcmLocs);
            mf.markStage('ECM1', 'curation', struct('tool', 'x'));   % must not throw
            tc.verifyTrue(mf.Data.sources.ECM1.stages.curation.done);
        end

        function statusBeforeAnyCuration(tc)
            mf = CellDatasetManifest.forCsv(tc.EcmLocs);
            st = mf.buildSourceStatus();
            s = st(strcmp({st.Key}, 'ECM1'));
            tc.verifyFalse(s.Curated, 'no curation JSON yet: not curated');
            tc.verifyFalse(s.CurComplete);
            tc.verifyEqual(s.CurReviewed, 0);
        end

        function pathFollowsDetectorLocsStem(tc)
            mf = CellDatasetManifest.forCsv(tc.EcmLocs);
            expected = fullfile(tc.Folder, [char(tc.Truth.baseName) '_proj_ECM1_curation.csv']);
            tc.verifyEqual(lower(mf.curationPath('ECM1')), lower(expected), ...
                'curation path must be <detector locs stem>_curation.csv even before the file exists');
        end

        function pathMatchesTheStore(tc)
            mf = CellDatasetManifest.forCsv(tc.EcmLocs);
            s = curation.Store.open(mf, 'ECM1', struct('AutosaveDelay', 0));
            tc.addTeardown(@() s.close());
            tc.verifyEqual(lower(mf.curationPath('ECM1')), lower(char(s.Paths.csv)), ...
                'manifest and store must agree on the snapshot path');
            tc.verifyEqual(lower(mf.curationJsonPath()), lower(char(s.Paths.json)), ...
                'manifest and store must agree on the JSON path');
        end

        function statusFollowsTheStore(tc)
            mf = CellDatasetManifest.forCsv(tc.EcmLocs);
            s = curation.Store.open(mf, 'ECM1', struct('AutosaveDelay', 0, 'ImportLegacy', false));
            ids = s.T.CellID;
            s.setLabel(ids(1:10), "Good", "human");
            s.setLabel(ids(11:15), "Bad", "human");
            s.setLabel(ids(16:17), "Uncertain", "human");
            s.flush();
            c = s.counts();

            st = CellDatasetManifest.forCsv(tc.EcmLocs).buildSourceStatus();
            e = st(strcmp({st.Key}, 'ECM1'));
            tc.verifyTrue(e.Curated, 'reviewed rows exist: curated');
            tc.verifyFalse(e.CurComplete);
            tc.verifyEqual(e.CurReviewed, 17);
            tc.verifyEqual(e.CurGood, 10);
            tc.verifyEqual(e.CurBad, 5);
            tc.verifyEqual(e.CurUncertain, 2);
            tc.verifyEqual(e.CurKept, c.kept);
            tc.verifyEqual(e.CurTotal, c.active);
            tc.verifyEqual(lower(e.CurationPath), lower(char(s.Paths.csv)));

            s.setComplete(true);
            s.flush();
            s.close();
            st = CellDatasetManifest.forCsv(tc.EcmLocs).buildSourceStatus();
            e = st(strcmp({st.Key}, 'ECM1'));
            tc.verifyTrue(e.CurComplete, 'complete flag must come through from the JSON');
        end

        function discoverReportsCurationAndKeepsLegacyFields(tc)
            % Note: with the real naming (<x>_proj.tif + <x>_proj_ECM1_locs.csv) discover
            % returns the image and the locs as two datasets (bases <x> and <x>_proj).
            % That is existing behavior; here only the effect of curation files matters.
            before = CellDatasetManifest.discover(tc.Folder, struct('WriteManifest', false));
            basesBefore = sort(string({before.Base}));

            s = curation.Store.openCsv(tc.EcmLocs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            s.setLabel(s.T.CellID(1:5), "Good", "human");
            s.setComplete(true);
            s.exportFinal(s.Paths.final);
            s.close();

            mfs = CellDatasetManifest.discover(tc.Folder, struct('WriteManifest', false));
            tc.verifyEqual(sort(string({mfs.Base})), basesBefore, ...
                'curation sidecars (csv, journal, json, final) must not be discovered as datasets');
            hasEcm = arrayfun(@(m) m.hasSource('ECM1'), mfs);
            tc.assertEqual(nnz(hasEcm), 1, 'exactly one dataset owns the ECM1 source');
            d = mfs(hasEcm).toDatasetStruct(tc.Folder);
            keys = {d.Sources.Key};
            tc.verifyNumElements(keys, 2, 'curation files must not add sources');
            tc.verifyTrue(all(ismember({'ECM1', 'PV2'}, keys)), 'both sources still discovered');
            e = d.Sources(strcmp(keys, 'ECM1'));
            p = d.Sources(strcmp(keys, 'PV2'));
            tc.verifyTrue(e.Curated);
            tc.verifyTrue(e.CurComplete);
            tc.verifyFalse(p.Curated, 'the other channel is untouched');
            tc.verifyTrue(e.Detected && p.Detected, 'legacy Detected flag unaffected');
            tc.verifyEqual(d.Status, 'Curating', 'one of two sources complete');
            tc.verifyTrue(mfs(hasEcm).Data.sources.ECM1.stages.curation.done);

            T = CellDatasetManifest.statusTable(tc.Folder, struct('WriteManifest', false));
            tc.verifyTrue(any(T.Curated == "1/2"), 'statusTable reports one of two sources curated');
        end

        function totalMeansActiveInBothWriters(tc)
            % recordCuration (called by the app) and reconcileFromDisk (called by every
            % scan) both write stages.curation.total; they must write the same number.
            s = curation.Store.openCsv(tc.EcmLocs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            ids = s.T.CellID;
            s.setLabel(ids(1:6), "Good", "human");
            s.mergeCells(ids(1:2), ids(1));          % one row leaves the active set
            s.flush();
            c = s.counts();
            tc.assertNotEqual(c.active, c.total, 'the scenario needs active and total to differ');

            mf = CellDatasetManifest.forCsv(tc.EcmLocs);
            mf.recordCuration('ECM1', s.Paths.csv, c);
            tc.verifyEqual(mf.Data.sources.ECM1.stages.curation.total, c.active, ...
                'recordCuration must record the active count');
            s.close();
            mf.reconcileFromDisk();
            tc.verifyEqual(mf.Data.sources.ECM1.stages.curation.total, c.active, ...
                'a scan must leave the same total');
        end

        function missingSidecarDoesNotZeroRecordedFacts(tc)
            % If the curation JSON is missing or unreadable during a scan, the facts a
            % real curation recorded must survive (the sidecar may be mid-write or on a
            % share that is briefly unavailable).
            mf = CellDatasetManifest.forCsv(tc.EcmLocs);
            mf.recordCuration('ECM1', fullfile(tc.Folder, 'x_curation.csv'), ...
                struct('active', 40, 'reviewed', 12, 'good', 9, 'bad', 3, 'tool', 'CellCurator'));
            tc.assertFalse(isfile(mf.curationJsonPath()), 'no sidecar in this scenario');
            mf.reconcileFromDisk();
            st = mf.Data.sources.ECM1.stages.curation;
            tc.verifyEqual(st.reviewed, 12, 'recorded facts must not be zeroed');
            tc.verifyEqual(st.total, 40);
            tc.verifyTrue(st.done, 'a recorded curation stays recorded');
        end

        function snapshotPathFollowsTheLocsFolder(tc)
            % The store writes its snapshot beside the locs file. When the recorded locs
            % lives outside the dataset folder, the manifest must look there too.
            other = fullfile(tc.Folder, 'elsewhere');
            mkdir(other);
            moved = fullfile(other, [char(tc.Truth.baseName) '_proj_ECM1_locs.csv']);
            copyfile(tc.EcmLocs, moved);
            mf = CellDatasetManifest.forCsv(tc.EcmLocs);
            mf.Data.sources.ECM1.locs = moved;       % absolute path outside the dataset folder
            expected = fullfile(other, [char(tc.Truth.baseName) '_proj_ECM1_curation.csv']);
            tc.verifyEqual(lower(mf.curationPath('ECM1')), lower(expected));
        end

        function recordCurationRoundTrips(tc)
            mf = CellDatasetManifest.forCsv(tc.EcmLocs);
            csv = fullfile(tc.Folder, 'elsewhere_curation.csv');
            mf.recordCuration('ECM1', csv, struct('reviewed', 7, 'good', 4, 'bad', 3, ...
                'kept', 4, 'complete', false, 'tool', 'CellCurator', 'ignored', 99));
            tc.verifyTrue(mf.save());
            mf2 = CellDatasetManifest.forCsv(tc.EcmLocs);
            st = mf2.Data.sources.ECM1.stages.curation;
            tc.verifyTrue(st.done);
            tc.verifyEqual(st.tool, 'CellCurator');
            tc.verifyEqual(st.reviewed, 7);
            tc.verifyFalse(isfield(st, 'ignored'), 'only whitelisted facts are stored');
            tc.verifyEqual(lower(mf2.curationPath('ECM1')), lower(csv), ...
                'a recorded path wins over the convention');
            tc.verifyNotEmpty(st.time);
        end
    end
end
