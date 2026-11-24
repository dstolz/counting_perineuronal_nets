classdef tTrainSmoke < matlab.unittest.TestCase
    %TTRAINSMOKE  The trainers run on curated exports (CPU, tiny):
    %   STAGE 2  curation.Trainer.start launches train_score.py on a synthetic Stage-2 export
    %            (1 epoch, fine-tuned from the shipped PV ordinal scorer) without blocking MATLAB,
    %            the run completes and writes a checkpoint, the Trainer deploys it as a model
    %            folder (.hydra/config.yaml + best.pth; a second deploy never overwrites it), and
    %            score.py then scores points with the DEPLOYED model (curation.Rescore) to finite
    %            values.
    %   STAGE 1  curation.Trainer.stage1Command's overrides compose train.py's configuration
    %            (conf/experiment/curated/fasterrcnn_640) on a synthetic Stage-1 export, the datasets
    %            are instantiated on it, the shipped PV detector is loaded and ONE optimizer step
    %            and one validation forward pass run (tests\python\stage1_one_step.py). A full
    %            train.py epoch is not run here (the trainer fixes' Python test runs one on a tiny
    %            dataset of the same format).
    %   Run: pwsh -File tools\Run-Tests.ps1 tTrainSmoke -IncludeSlow

    properties
        Root
        Repo
    end

    methods (TestClassSetup)
        function setup(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fx.Folder;
            tc.Repo = fileparts(fileparts(mfilename('fullpath')));
        end
    end

    methods (Test, TestTags = {'Slow', 'Python'})

        function stage2FineTuneDeployAndScore(tc)
            parent = fullfile(tc.Root, 'p2');
            layout = tExportStage2.LAYOUT([1 3 4], :);
            truth = tExportStage2.makeProject(parent, layout, @tExportStage2.labelStage2);
            idx = curation.ProjectIndex.build(parent, struct('CacheDir', fullfile(tc.Root, 'cache2')));
            exp = fullfile(tc.Root, 'exp2');
            r = curation.Export.stage2(idx, exp, struct('Kind', "pv", 'MinPerClass', 5));
            tc.assertEqual(r.Status, "ok");

            lines = strings(0, 1);
            done = false;
            t = curation.Trainer.start(exp, struct('Epochs', 1, 'Device', "cpu", 'BatchSize', 16, ...
                'RunDir', fullfile(tc.Root, 'run2'), 'DeployRoot', fullfile(tc.Root, 'models'), ...
                'DeployName', "pv_curated_test_scoring_ordinal_regression", ...
                'OnLine', @(l) addLine(l), 'OnDone', @(~) markDone()));
            tc.addTeardown(@() t.cancel());
            tc.verifyEqual(t.State, "running", 'start() returns while the run goes on');
            fprintf('[stage2] %s\n', t.Command.Line);
            t0 = tic;
            ok = t.wait(900);
            fprintf('[stage2] run ended after %.0f s: %s (exit %g)\n', toc(t0), t.State, t.ExitCode);
            fprintf('[stage2]   %s\n', t.Lines(max(1, end - 6):end));
            tc.assertTrue(ok, 'the run did not finish in time');
            tc.assertEqual(t.State, "succeeded", strjoin(t.Lines(max(1, end - 30):end), newline));
            tc.verifyTrue(done, 'OnDone was called');
            tc.verifyNotEmpty(lines, 'OnLine received the output');
            tc.verifyTrue(isfile(t.LogFile));
            tc.verifyTrue(isfile(fullfile(t.RunDir, 'last.pth')));
            tc.verifyNotEmpty(dir(fullfile(t.RunDir, 'best_models', 'best_model_metric_*.pth')));
            tc.verifySubstring(fileread(t.LogFile), 'Training ended');

            dest = t.DeployedTo;
            fprintf('[stage2] deployed: %s\n', dest);
            tc.assertTrue(isfile(fullfile(dest, 'best.pth')) && isfile(fullfile(dest, '.hydra', 'config.yaml')));
            tc.verifyTrue(isfile(fullfile(dest, 'curation_provenance.json')));
            cfg = fileread(fullfile(dest, '.hydra', 'config.yaml'));
            tc.verifySubstring(cfg, 'method: ordinal_regression');
            tc.verifySubstring(cfg, 'PerineuronalNetsRankDataset');
            [~, name] = fileparts(dest);
            tc.verifyEqual(string(name), "pv_curated_test_scoring_ordinal_regression");
            d = dir(fullfile(dest, 'best.pth'));
            tc.verifyGreaterThan(d.bytes, 1e6, 'the checkpoint itself, not a link');
            dest2 = curation.Trainer.deployRun(t.RunDir, name, struct('DeployRoot', fullfile(tc.Root, 'models')));
            tc.verifyTrue(endsWith(string(dest2), "_2"), 'an existing model folder is never overwritten');
            [dm, sm] = CellToolkit.discoverModels(fullfile(tc.Root, 'models'));
            isScore = any(strcmp(sm, name)); isDet = any(strcmp(dm, name));
            tc.verifyTrue(isScore && ~isDet, 'listed as a scoring model by CellToolkit.discoverModels');

            % ---- score.py with the deployed model
            tr = truth.(matlab.lang.makeValidName(layout(1, 2)));
            s = curation.Store.openCsv(tr.paths.pv2Locs, struct('ReadOnly', true, 'ImportLegacy', false));
            tc.addTeardown(@() s.close());
            ids = tr.plan.G(1:5);
            job = curation.Rescore.run(s, struct('Ids', {{ids}}, 'Model', string(dest), 'Wait', true, 'Timeout', 300));
            tc.assertEqual(job.State, "succeeded", strjoin(job.Log, newline));
            tc.verifyEqual(sort(job.Result.CellID)', sort(double(ids)));
            tc.verifyTrue(all(isfinite(job.Result.Rescore)));
            tc.verifyTrue(all(job.Result.Model == string(dest)));
            fprintf('[stage2] rescore with the deployed model: %s\n', mat2str(job.Result.Rescore', 4));

            function addLine(l), lines(end + 1, 1) = string(l); end
            function markDone(), done = true; end
        end

        function stage1OneTrainingStep(tc)
            parent = fullfile(tc.Root, 'p1');
            layout = tExportStage1.LAYOUT(1:3, :);     % sections 1 and 3 complete + swept, 2 not swept
            tExportStage2.makeProject(parent, layout, @tExportStage1.labelAll);
            idx = curation.ProjectIndex.build(parent, struct('CacheDir', fullfile(tc.Root, 'cache1')));
            exp = fullfile(tc.Root, 'exp1');
            r = curation.Export.stage1(idx, exp, struct('Kind', "pv"));
            tc.assertEqual(height(r.Images), 2);
            cmd = curation.Trainer.stage1Command(exp, struct('Kind', "pv", 'Device', "cpu", ...
                'RunDir', fullfile(tc.Root, 'run1')));
            fprintf('[stage1] command: %s\n', cmd.Line);
            py = curation.Trainer.defaultPython(tc.Repo);
            js = fullfile(tc.Root, 'step.json');
            t0 = tic;
            [st, txt] = CellToolkit.runPython(py, [{fullfile(tc.Repo, 'tests', 'python', 'stage1_one_step.py'), js}, ...
                cmd.Args(2:end)]);
            tc.assertEqual(st, 0, txt);
            J = jsondecode(fileread(js));
            fprintf('[stage1] one step in %.0f s: %s | %s | loss %.4f (%s), %d detections on a validation patch\n', ...
                toc(t0), J.train, J.validation, J.loss, jsonencode(J.losses), J.validationDetections);
            tc.verifyTrue(isfinite(J.loss));
            tc.verifyEqual(J.trainImages, 2);
            tc.verifyEqual(J.trainAnnotations + J.validationAnnotations, sum(r.Counts.Total));
            tc.verifyEqual(J.epochs, 20);
            tc.verifyEqual(J.lr, 0.001, 'AbsTol', 1e-12);
            tc.verifySubstring(J.pretrained, 'pv_v2_fasterrcnn_640');
        end
    end
end
