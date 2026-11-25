classdef tManagerScan < matlab.unittest.TestCase
    %tManagerScan  CellDatasetManager without its window: scan lists a section once, names its subject
    %   and section from the file name, and counts what was reviewed; progressOf gives the stage
    %   (detect, curate, curating, curated); statusTable and sourceTable (the report) carry the
    %   curation counts and the final CSV of a completed source; a struct from scan can be passed
    %   on instead of scanning again.
    %
    %   Run: pwsh -File tools\Run-Tests.ps1 tManagerScan

    properties (Constant)
        Section = "SUBJ-ID-9001IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1"
    end

    properties
        Root
    end

    methods (TestMethodSetup)
        function makeRoot(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fx.Folder;
            % records are looked for beside the files and in the fallback folder: keep that one empty
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'no_provenance')));
        end
    end

    methods (Static)
        function [folder, truth] = section(root, name, base)
            [folder, truth] = makeSyntheticDataset(fullfile(root, name), 'BaseName', base, ...
                'NumCells', [24 30], 'ImageSize', [300 400], 'Variants', false);
        end

        function curate(locs, nGood, nBad, complete)
            s = curation.Store.openCsv(locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            ids = double(s.T.CellID);
            if nGood > 0, s.setLabel(ids(1:nGood), "Good", "human"); end
            if nBad > 0, s.setLabel(ids(nGood + (1:nBad)), "Bad", "human"); end
            if complete
                rest = double(s.T.CellID(strlength(string(s.T.Label)) == 0));   % whatever is not decided yet
                if ~isempty(rest), s.setLabel(rest, "Bad", "human"); end
                s.setComplete(true);
                s.flush();
                s.exportFinal(s.Paths.final);
            end
            s.close();
        end
    end

    methods (Test)
        function aSectionIsListedOnceWithItsSubject(tc)
            [folder, truth] = tManagerScan.section(tc.Root, 'a', tc.Section);
            ds = CellDatasetManager.scan(tc.Root);
            tc.assertNumElements(ds, 1, 'one dataset for one section');
            d = ds(1);
            tc.verifyEqual(d.Base, [char(tc.Section) '_proj']);
            tc.verifyEqual(d.Folder, folder);
            tc.verifyEqual(d.SubjectID, 'SUBJ-ID-9001');
            tc.verifyEqual(d.SectionLabel, '1A L');
            tc.verifyTrue(d.Section.ok);
            tc.verifyEqual(d.Section.Stain, "WFA-PV");
            tc.verifyNumElements(d.Sources, 2);
            tc.verifyEqual(d.TotalDetections, height(truth.ECM1.locs) + height(truth.PV2.locs));
            for s = d.Sources(:)'
                tc.verifyEqual(s.Db.state, "none", 'no record before a source is completed');
                tc.verifyEqual(s.Db.text, "");
            end
            tc.verifyEqual(d.Database, '');
            tc.verifyFalse(d.SubjectAsked, 'nothing asks the database during a scan');
        end

        function aNameThatDoesNotFitHasNoSubject(tc)
            tManagerScan.section(tc.Root, 'syn', "SYN-0001_sec1");
            ds = CellDatasetManager.scan(tc.Root, struct('Database', false));
            tc.assertNumElements(ds, 1);
            tc.verifyEqual(ds.SubjectID, '');
            tc.verifyEqual(ds.SectionLabel, '');
            tc.verifyFalse(ds.Section.ok);
            tc.verifyEqual(ds.Sources(1).Db.state, "none");
        end

        function progressFollowsTheCuration(tc)
            [~, truth] = tManagerScan.section(tc.Root, 'a', tc.Section);
            imgOnly = fullfile(tc.Root, 'b');
            mkdir(imgOnly);
            copyfile(truth.paths.tif, fullfile(imgOnly, 'SUBJ-ID-9002IHC_ECM26A260519S2_2B_R_WFA-PV_Z3_260511_1_proj.tif'));
            nEcm = height(truth.ECM1.locs);
            nPv = height(truth.PV2.locs);

            ds = CellDatasetManager.scan(tc.Root);
            tc.assertNumElements(ds, 2);
            [~, order] = sort(string({ds.SubjectID}));
            ds = ds(order);
            p = CellDatasetManager.progressOf(ds(1));
            tc.verifyEqual(p.Stage, 'curate');
            tc.verifyEqual([p.Sources p.Detected p.Rescored p.Complete], [2 2 2 0]);
            tc.verifyEqual([p.Cells p.Reviewed p.Kept p.Pct], [nEcm + nPv, 0, 0, 0]);
            q = CellDatasetManager.progressOf(ds(2));
            tc.verifyEqual(q.Stage, 'detect', 'an image without detections');
            tc.verifyEqual(q.Sources, 0);
            tc.verifyEqual(ds(2).Status, 'New (image only)');
            tc.verifyEqual(ds(2).SubjectID, 'SUBJ-ID-9002');

            tManagerScan.curate(truth.paths.ecm1Locs, 6, 3, false);
            ds = CellDatasetManager.scan(tc.Root);
            d = ds(strcmp({ds.SubjectID}, 'SUBJ-ID-9001'));
            p = CellDatasetManager.progressOf(d);
            tc.verifyEqual(p.Stage, 'curating');
            tc.verifyEqual(p.Reviewed, 9);
            tc.verifyEqual(p.Kept, 6);
            tc.verifyEqual(p.Pct, floor(100 * 9 / p.Cells));
            tc.verifyEqual(d.Status, 'Curating');

            tManagerScan.curate(truth.paths.ecm1Locs, 0, 0, true);
            tManagerScan.curate(truth.paths.pv2Locs, 5, 0, true);
            ds = CellDatasetManager.scan(tc.Root);
            d = ds(strcmp({ds.SubjectID}, 'SUBJ-ID-9001'));
            p = CellDatasetManager.progressOf(d);
            tc.verifyEqual(p.Stage, 'curated');
            tc.verifyEqual(p.Complete, 2);
            tc.verifyEqual(p.Reviewed, p.Cells, 'every cell decided');
            tc.verifyEqual(p.Pct, 100);
            tc.verifyEqual(p.Kept, 6 + 5);
            tc.verifyEqual(d.Status, 'Curated');
        end

        function theTablesCarryTheCuration(tc)
            [folder, truth] = tManagerScan.section(tc.Root, 'a', tc.Section);
            tManagerScan.curate(truth.paths.ecm1Locs, 6, 3, true);
            ds = CellDatasetManager.scan(tc.Root);

            T = CellDatasetManager.statusTable(ds);
            tc.assertEqual(height(T), 1);
            for name = ["DatasetID" "Folder" "Pages" "Sources" "Detections" "Detected" "Resolved" "Rescored" ...
                    "Reviewed" "Status" "Subject" "Curated" "CellsReviewed" "Kept" "Database"]
                tc.verifyTrue(ismember(name, string(T.Properties.VariableNames)), "statusTable has " + name);
            end
            tc.verifyEqual(T.Subject, "SUBJ-ID-9001");
            tc.verifyEqual(T.Curated, "1/2");
            tc.verifyEqual(T.Kept, 6);
            tc.verifyEqual(T.CellsReviewed, height(truth.ECM1.locs));
            tc.verifyEqual(T.Status, "Curating");
            T2 = CellDatasetManager.statusTable(tc.Root);
            tc.verifyEqual(T2, T, 'a folder is scanned, a scan result is used as it is');

            S = CellDatasetManager.sourceTable(ds);
            tc.assertEqual(height(S), 2, 'one row per source');
            e = S(S.Source == "ECM1", :);
            p = S(S.Source == "PV2", :);
            tc.verifyEqual(e.Subject, "SUBJ-ID-9001");
            tc.verifyEqual(e.Section, "1A");
            tc.verifyEqual(e.Hemisphere, "L");
            tc.verifyEqual(e.Stain, "WFA-PV");
            tc.verifyEqual(e.Dataset, tc.Section + "_proj");
            tc.verifyEqual(e.Page, 1);
            tc.verifyEqual(e.Detections, height(truth.ECM1.locs));
            tc.verifyTrue(e.Rescored);
            tc.verifyEqual([e.Good e.Kept], [6 6]);
            tc.verifyEqual(e.Bad, height(truth.ECM1.locs) - 6);
            tc.verifyTrue(e.Complete);
            tc.verifyEqual(e.FinalCsv, string(fullfile(folder, tc.Section + "_proj_ECM1_final.csv")));
            tc.verifyTrue(isfile(e.FinalCsv));
            tc.verifyEqual(height(readtable(e.FinalCsv)), 6, 'the final CSV holds the kept cells');
            tc.verifyFalse(p.Complete);
            tc.verifyEqual(p.FinalCsv, "");
            tc.verifyEqual([p.Reviewed p.Kept], [0 0]);
            tc.verifyEqual(p.Folder, string(folder));

            tc.verifyEqual(height(CellDatasetManager.sourceTable(struct([]))), 0);
            tc.verifyEqual(width(CellDatasetManager.sourceTable(struct([]))), width(S), 'same columns when empty');
        end

        function aLegacyQcFileCountsAsReviewedNotKept(tc)
            [~, truth] = makeSyntheticDataset(fullfile(tc.Root, 'legacy'), 'NumCells', [24 30], ...
                'ImageSize', [300 400], 'Variants', true);
            ds = CellDatasetManager.scan(tc.Root, struct('Database', false));
            tc.assertNumElements(ds, 1);
            pv = ds.Sources(strcmp({ds.Sources.Key}, 'PV2'));
            tc.assertTrue(pv.Reviewed, 'the fixture''s legacy QC file is found');
            p = CellDatasetManager.progressOf(ds);
            tc.verifyEqual(p.Stage, 'curating', 'legacy review is work in progress');
            tc.verifyEqual(p.Reviewed, height(truth.qc));
            tc.verifyEqual(p.Kept, 0, 'nothing is kept before Cell Curator');
        end
    end
end
