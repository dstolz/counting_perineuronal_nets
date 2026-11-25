classdef tManifestBase < matlab.unittest.TestCase
    %tManifestBase  The base of a dataset (CellDatasetManifest, "The base of a dataset"): a section stored
    %   the way the lab stores it (<x>_proj.tif beside <x>_proj_ECM1_locs.csv) is ONE dataset whose base
    %   is the stem its localization files start with; forImage, forCsv and discover agree on it; a
    %   projection beside a raw image of its own stays that image's companion; what CellDiscovery
    %   records about a detection is where every reader looks and survives a scan; and what an
    %   earlier version recorded in the stray manifest "<x>.celldataset.json" is adopted.
    %
    %   Run: pwsh -File tools\Run-Tests.ps1 tManifestBase

    properties
        Root
    end

    methods (TestMethodSetup)
        function makeRoot(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fx.Folder;
        end
    end

    methods (Static)
        function p = tif(folder, name)
            if ~isfolder(folder), mkdir(folder); end
            p = fullfile(folder, [name '.tif']);
            imwrite(uint8(magic(8)), p);
        end

        function p = locs(folder, name)
            p = fullfile(folder, [name '.csv']);
            writetable(table([1; 2; 3], [4; 5; 6], 'VariableNames', {'X', 'Y'}), p);
        end

        function facts = detectionFacts(image, locs)
            facts = struct('image', image, 'page', 1, 'locs', locs, 'tool', 'CellDiscovery', ...
                'model', 'pnn_v2_fasterrcnn_640', 'count', 3, 'resize', 2.569, 'resizeMode', 'auto', ...
                'bgRadius', 0, 'correctLSM', false, 'normalized', true);
        end
    end

    methods (Test)
        function aProjSectionIsOneDataset(tc)
            [folder, truth] = makeSyntheticDataset(fullfile(tc.Root, 'ds'), 'Variants', false);
            base = [char(truth.baseName) '_proj'];
            mfs = CellDatasetManifest.discover(folder, struct('WriteManifest', false));
            tc.assertNumElements(mfs, 1, 'the image and its localization files are one dataset');
            tc.verifyEqual(mfs.Base, base);
            tc.verifyEqual(sort(reshape(string(mfs.sourceKeys()), 1, [])), ["ECM1", "PV2"]);
            tc.verifyEqual(mfs.imagePath(), char(truth.paths.tif));
            d = mfs.toDatasetStruct(folder);
            tc.verifyEqual(d.ImagePath, char(truth.paths.tif));
            tc.verifyEqual(d.RawImage, char(truth.paths.tif), 'the projection is THE image of this dataset');
            tc.verifyEmpty(d.ProjImage, 'and so not also its companion');
            tc.verifyEqual(d.Status, 'Rescored');
        end

        function forImageForCsvAndDiscoverAgree(tc)
            [folder, truth] = makeSyntheticDataset(fullfile(tc.Root, 'ds'), 'Variants', false);
            base = [char(truth.baseName) '_proj'];
            tc.verifyEqual(CellDatasetManifest.forImage(truth.paths.tif).Base, base);
            tc.verifyEqual(CellDatasetManifest.forCsv(truth.paths.ecm1Locs).Base, base);
            tc.verifyEqual(CellDatasetManifest.forImage(truth.paths.tif).ManifestPath, ...
                CellDatasetManifest.forCsv(truth.paths.pv2Locs).ManifestPath);
            mfs = CellDatasetManifest.discover(folder, struct('WriteManifest', false));
            tc.verifyEqual(mfs.ManifestPath, CellDatasetManifest.forCsv(truth.paths.ecm1Locs).ManifestPath);
        end

        function aProjectionAloneKeepsItsBaseWhenDetectionsArrive(tc)
            folder = fullfile(tc.Root, 'alone');
            img = tManifestBase.tif(folder, 'sec7_proj');
            before = CellDatasetManifest.discover(folder, struct('WriteManifest', false));
            tc.assertNumElements(before, 1);
            tc.verifyEqual(before.Base, 'sec7_proj');
            tc.verifyEqual(before.imagePath(), img);
            tc.verifyEqual(CellDatasetManifest.forImage(img).Base, 'sec7_proj');
            csv = tManifestBase.locs(folder, 'sec7_proj_ECM1_locs');
            after = CellDatasetManifest.discover(folder, struct('WriteManifest', false));
            tc.assertNumElements(after, 1, 'detections do not make a second dataset');
            tc.verifyEqual(after.Base, 'sec7_proj', 'nor rename the first');
            tc.verifyEqual(CellDatasetManifest.forCsv(csv).Base, 'sec7_proj');
            tc.verifyEqual(CellDatasetManifest.forImage(img).Base, 'sec7_proj');
        end

        function aProjectionBesideItsRawImageIsACompanion(tc)
            folder = fullfile(tc.Root, 'companion');
            raw = tManifestBase.tif(folder, 'sec8');
            proj = tManifestBase.tif(folder, 'sec8_proj');
            tManifestBase.locs(folder, 'sec8_PNN1_locs');
            mfs = CellDatasetManifest.discover(folder, struct('WriteManifest', false));
            tc.assertNumElements(mfs, 1);
            tc.verifyEqual(mfs.Base, 'sec8');
            d = mfs.toDatasetStruct(folder);
            tc.verifyEqual(d.RawImage, raw);
            tc.verifyEqual(d.ProjImage, proj);
            tc.verifyEqual(CellDatasetManifest.forImage(proj).Base, 'sec8');
            tc.verifyEqual(CellDatasetManifest.forImage(raw).Base, 'sec8');
        end

        function rawAndProjectionEachDetectedAreTwoDatasets(tc)
            folder = fullfile(tc.Root, 'both');
            raw = tManifestBase.tif(folder, 'sec9');
            proj = tManifestBase.tif(folder, 'sec9_proj');
            tManifestBase.locs(folder, 'sec9_PNN1_locs');
            tManifestBase.locs(folder, 'sec9_proj_PNN1_locs');
            mfs = CellDatasetManifest.discover(folder, struct('WriteManifest', false));
            tc.assertNumElements(mfs, 2);
            bases = sort(string({mfs.Base}));
            tc.verifyEqual(bases, ["sec9", "sec9_proj"]);
            for k = 1:2
                d = mfs(k).toDatasetStruct(folder);
                if strcmp(mfs(k).Base, 'sec9')
                    tc.verifyEqual(d.ImagePath, raw);
                else
                    tc.verifyEqual(d.ImagePath, proj);
                end
                tc.verifyNumElements(d.Sources, 1);
            end
            tc.verifyEqual(CellDatasetManifest.forImage(proj).Base, 'sec9_proj', 'as discover and forCsv say');
        end

        function aResizedImageGoesWithItsSection(tc)
            % CellDiscovery saves "<stem>_resized.tif" beside the image it read.
            [folder, truth] = makeSyntheticDataset(fullfile(tc.Root, 'ds'), 'Variants', false);
            base = [char(truth.baseName) '_proj'];
            resized = tManifestBase.tif(folder, [base '_resized']);
            mfs = CellDatasetManifest.discover(folder, struct('WriteManifest', false));
            tc.assertNumElements(mfs, 1);
            d = mfs.toDatasetStruct(folder);
            tc.verifyEqual(d.PreprocImage, resized);
            tc.verifyEqual(CellDatasetManifest.forImage(resized).Base, base);
        end

        function recordedDetectionFactsSurviveAScan(tc)
            % What CellDiscovery records (it uses forCsv on the file it wrote) is what the readers
            % (exports, rescoring, the lab database record) find, before and after a scan.
            [folder, truth] = makeSyntheticDataset(fullfile(tc.Root, 'ds'), 'Variants', false);
            mf = CellDatasetManifest.forCsv(truth.paths.ecm1Locs);
            mf.recordDetection('ECM1', tManifestBase.detectionFacts(char(truth.paths.tif), char(truth.paths.ecm1Locs)));
            tc.assertTrue(mf.save());
            for pass = 1:2
                det = CellDatasetManifest.forCsv(truth.paths.ecm1Locs).source('ECM1').stages.detection;
                tc.verifyEqual(char(det.model), 'pnn_v2_fasterrcnn_640', sprintf('pass %d', pass));
                tc.verifyEqual(double(det.resize), 2.569, sprintf('pass %d', pass));
                tc.verifyTrue(logical(det.normalized));
                det2 = CellDatasetManifest.forImage(truth.paths.tif).source('ECM1').stages.detection;
                tc.verifyEqual(char(det2.model), 'pnn_v2_fasterrcnn_640', 'forImage is the same manifest');
                CellDatasetManifest.discover(folder);        % writes the reconciled manifests
            end
            d = dir(fullfile(folder, '*.celldataset.json'));
            tc.verifyNumElements(d, 1, 'one manifest for the section');

            % a scan of a folder where nothing changed writes nothing
            file = fullfile(d.folder, d.name);
            text = fileread(file);
            pause(1.2);
            CellDatasetManifest.discover(folder);
            d2 = dir(file);
            tc.verifyEqual(fileread(file), text, 'the manifest says the same');
            tc.verifyEqual(d2.datenum, d.datenum, 'and was not written again');
        end

        function aStrayManifestIsAdopted(tc)
            % Until 2026-11-24 CellDiscovery recorded the detection of "<x>_proj.tif" in
            % "<x>.celldataset.json". discover takes over what it recorded for the same locs file.
            [folder, truth] = makeSyntheticDataset(fullfile(tc.Root, 'ds'), 'Variants', false);
            stray = CellDatasetManifest.forBase(folder, char(truth.baseName));
            stray.recordDetection('ECM1', tManifestBase.detectionFacts(char(truth.paths.tif), char(truth.paths.ecm1Locs)));
            stray.recordRescore('ECM1', struct('tool', 'CellDiscovery', 'model', 'pnn_v2_scoring_ordinal_regression'));
            % a source it lists with ANOTHER locs file says nothing about this dataset's PV2
            stray.recordDetection('PV2', struct('locs', fullfile(folder, 'something_else_PV2_locs.csv'), ...
                'tool', 'CellDiscovery', 'model', 'wrong'));
            tc.assertTrue(stray.save());
            strayText = fileread(stray.ManifestPath);

            mfs = CellDatasetManifest.discover(folder);
            tc.assertNumElements(mfs, 1);
            s = CellDatasetManifest.forCsv(truth.paths.ecm1Locs).source('ECM1');
            tc.verifyEqual(char(s.stages.detection.model), 'pnn_v2_fasterrcnn_640');
            tc.verifyEqual(double(s.stages.detection.resize), 2.569);
            tc.verifyEqual(char(s.stages.rescore.model), 'pnn_v2_scoring_ordinal_regression');
            p = CellDatasetManifest.forCsv(truth.paths.pv2Locs).source('PV2');
            tc.verifyFalse(isfield(p.stages.detection, 'model') && strcmp(char(p.stages.detection.model), 'wrong'), ...
                'facts about another file are not taken');
            tc.verifyEqual(fileread(stray.ManifestPath), strayText, 'the stray manifest is left as it is');

            % what this manifest recorded itself is never overwritten by the stray one
            mf = CellDatasetManifest.forCsv(truth.paths.ecm1Locs);
            facts = tManifestBase.detectionFacts(char(truth.paths.tif), char(truth.paths.ecm1Locs));
            facts.model = 'newer_model';
            mf.recordDetection('ECM1', facts);
            tc.assertTrue(mf.save());
            CellDatasetManifest.discover(folder);
            s = CellDatasetManifest.forCsv(truth.paths.ecm1Locs).source('ECM1');
            tc.verifyEqual(char(s.stages.detection.model), 'newer_model');
        end
    end
end
