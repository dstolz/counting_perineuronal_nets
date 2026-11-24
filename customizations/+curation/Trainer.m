classdef Trainer < handle
%TRAINER  Fine-tune the Stage-2 scorer on a curated export (non-blocking) and deploy the result as a
%   model folder; build the Stage-1 command line (Stage-1 fine-tuning takes hours to days and is
%   launched by a person).
%
%   cmd = curation.Trainer.stage2Command(exportRoot, opts)   the train_score.py command for an export
%   cmd = curation.Trainer.stage1Command(exportRoot, opts)   the train.py command for an export
%   t   = curation.Trainer.start(exportRoot, opts)           launch Stage 2, return at once
%   t.poll()                 drain output, notice the end (a timer calls it every opts.PollPeriod s)
%   ok  = t.wait(timeoutSec) block until the run ends (scripts, tests); false on timeout
%   t.cancel()               kill the run
%   dest = t.deploy()        deploy the finished run (done automatically when opts.Deploy)
%   dest = curation.Trainer.deployRun(runDir, name, opts)
%   py  = curation.Trainer.defaultPython(repoRoot)           CellToolkit.pythonConfig of the countpnn env
%
%   cmd (struct): Script, Args (cellstr after the interpreter), Parts (every token), Line (to paste
%   into a shell at WorkingDir), WorkingDir (the repository root), RunDir, Kind, Pretrained,
%   DeployName.
%
%   STAGE 2 defaults (opts, all optional):
%     Kind        "pnn" | "pv"; default: the Kind of the export's export_report.json
%     Pretrained  <repo>/<kind>_v2_scoring_ordinal_regression/best.pth (the shipped ordinal scorer:
%                 same 8-level scale as the export, so rescore keeps its meaning)
%     Epochs 10, LearningRate 1e-4 (a tenth of the from-scratch Adam rate), BatchSize 32, Seed 10
%     Device      "cuda" (gpu=0) | "cpu" (gpu=null)
%     RunDir      <repo>/runs_score/curated_<kind>_<yyyyMMdd_HHmmss> (hydra.run.dir; Hydra's
%                 default name, built from the overrides, would hold ':' and '\' on Windows)
%     Python      CellToolkit.pythonConfig struct (default defaultPython: the countpnn env)
%     RepoRoot    CellToolkit.detectRepoRoot()
%     Extra       cellstr of further Hydra overrides, appended last
%   The command:
%     python train_score.py data=curated method=ordinal_regression
%       data.train.root=<export>/train data.validation.root=<export>/validation
%       data.train.neg_fraction=0 data.validation.neg_fraction=0
%       model.pretrained=<Pretrained> optim.epochs=10 optim.optimizer.lr=0.0001 optim.batch_size=32
%       optim.num_workers=0 seed=10 gpu=0 hydra.run.dir=<RunDir>
%   (both data roots: the run must not read the default data; paths with forward slashes, quoted
%   for Hydra when they hold one of , = [ ] { } ( ) ' ")
%   start() also takes: OnLine (fn(line) per output line), OnDone (fn(trainer) at the end),
%   Deploy (true: deploy on success), DeployName, DeployRoot (default RepoRoot), Metric
%   ("rank/spearman": the best_models checkpoint deployed), PollPeriod 0.5. Output goes to
%   <RunDir>/curation_trainer.log as it arrives.
%
%   DEPLOY: <DeployRoot>/<name>/.hydra/config.yaml (the run's) + best.pth (the run's best
%   checkpoint on Metric, else on loss, else last.pth), plus train_log.csv, valid_log.csv and
%   curation_provenance.json (export, command, checkpoint). name defaults to
%   <kind>_curated_<yyyyMMdd>_scoring_ordinal_regression; an existing folder is never
%   overwritten: _2, _3, ... are appended. score.py, CellDetector and CellDiscovery's model lists
%   (CellToolkit.discoverModels: a folder with best.pth, no 'fasterrcnn' in its name) use it as is.
%
%   STAGE 1 (stage1Command only): Kind, Pretrained (<repo>/<kind>_v2_fasterrcnn_640/best.pth),
%   Epochs 20, Device, RunDir (<repo>/runs/curated_<kind>_<stamp>), Python, RepoRoot, Extra:
%     python train.py experiment=curated/fasterrcnn_640 data.train.root=<export>
%       data.validation.root=<export> model.pretrained=<Pretrained> optim.epochs=20 gpu=0
%       hydra.run.dir=<RunDir>
%   Deploy a Stage-1 run by copying <RunDir>/.hydra/config.yaml and the chosen
%   best_models/best_model_metric_*.pth (e.g. count-game-3-macro, as detector.py picks) to
%   <repo>/<kind>_curated_<date>_fasterrcnn_640/{.hydra/config.yaml, best.pth}; CellDetector reads
%   the detection threshold from checkpoint['metrics']['count/game-3/macro']['threshold'].
%
%   See also curation.Export, curation.Rescore, CellToolkit.launchPythonAsync.

    properties (SetAccess = private)
        State string = "idle"        % idle | running | succeeded | failed | cancelled
        ExitCode double = NaN
        Command struct = struct()
        ExportRoot char = ''
        RunDir char = ''
        LogFile char = ''
        DeployedTo char = ''
        Lines string = strings(0, 1) % the last MaxLines output lines
        Options struct = struct()
        Error string = ""
    end

    properties (Access = private)
        Proc = []
        Reader = []
        Timer = []
        Busy logical = false
        Log = -1
    end

    properties (Constant)
        MaxLines = 400
    end

    %% ====================================================================== commands
    methods (Static)

        function cmd = stage2Command(exportRoot, opts)
            if nargin < 2, opts = struct(); end
            exportRoot = char(exportRoot);
            o = curation.Trainer.fill(opts, struct('Kind', "", 'Pretrained', "", 'Epochs', 10, ...
                'LearningRate', 1e-4, 'BatchSize', 32, 'Seed', 10, 'Device', "cuda", 'RunDir', "", ...
                'Python', [], 'RepoRoot', "", 'Extra', {{}}, 'DeployName', ""));
            repo = curation.Trainer.repo(o.RepoRoot);
            kind = curation.Trainer.kindOf(o.Kind, exportRoot);
            pre = string(o.Pretrained);
            if pre == ""
                pre = string(fullfile(repo, sprintf('%s_v2_scoring_ordinal_regression', kind), 'best.pth'));
            end
            stamp = string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
            runDir = string(o.RunDir);
            if runDir == "", runDir = string(fullfile(repo, 'runs_score', "curated_" + kind + "_" + stamp)); end
            q = @curation.Trainer.hydraValue;
            args = {'train_score.py', 'data=curated', 'method=ordinal_regression', ...
                ['data.train.root=' q(fullfile(exportRoot, 'train'))], ...
                ['data.validation.root=' q(fullfile(exportRoot, 'validation'))], ...
                'data.train.neg_fraction=0', 'data.validation.neg_fraction=0', ...
                ['model.pretrained=' q(pre)], ...
                sprintf('optim.epochs=%d', round(o.Epochs)), ...
                ['optim.optimizer.lr=' curation.Trainer.num(o.LearningRate)], ...
                sprintf('optim.batch_size=%d', round(o.BatchSize)), 'optim.num_workers=0', ...
                sprintf('seed=%d', round(o.Seed)), curation.Trainer.gpuArg(o.Device), ...
                ['hydra.run.dir=' q(runDir)]};
            args = [args, cellstr(string(o.Extra(:)'))];
            name = string(o.DeployName);
            if name == ""
                name = kind + "_curated_" + string(datetime('now', 'Format', 'yyyyMMdd')) + "_scoring_ordinal_regression";
            end
            cmd = curation.Trainer.pack('train_score.py', args, o.Python, repo, runDir, kind, pre, name);
        end

        function cmd = stage1Command(exportRoot, opts)
            if nargin < 2, opts = struct(); end
            exportRoot = char(exportRoot);
            o = curation.Trainer.fill(opts, struct('Kind', "", 'Pretrained', "", 'Epochs', 20, ...
                'Device', "cuda", 'RunDir', "", 'Python', [], 'RepoRoot', "", 'Extra', {{}}));
            repo = curation.Trainer.repo(o.RepoRoot);
            kind = curation.Trainer.kindOf(o.Kind, exportRoot);
            pre = string(o.Pretrained);
            if pre == ""
                pre = string(fullfile(repo, sprintf('%s_v2_fasterrcnn_640', kind), 'best.pth'));
            end
            runDir = string(o.RunDir);
            if runDir == ""
                runDir = string(fullfile(repo, 'runs', "curated_" + kind + "_" + ...
                    string(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))));
            end
            q = @curation.Trainer.hydraValue;
            args = {'train.py', 'experiment=curated/fasterrcnn_640', ['data.train.root=' q(exportRoot)], ...
                ['data.validation.root=' q(exportRoot)], ['model.pretrained=' q(pre)], ...
                sprintf('optim.epochs=%d', round(o.Epochs)), curation.Trainer.gpuArg(o.Device)};
            if string(o.Device) == "cpu", args{end + 1} = 'optim.val_device=cpu'; end
            args = [args, {['hydra.run.dir=' q(runDir)]}, cellstr(string(o.Extra(:)'))];
            name = kind + "_curated_" + string(datetime('now', 'Format', 'yyyyMMdd')) + "_fasterrcnn_640";
            cmd = curation.Trainer.pack('train.py', args, o.Python, repo, runDir, kind, pre, name);
        end

        function t = start(exportRoot, opts)
            %START  Launch the Stage-2 fine-tune of an export; returns at once (see the class help).
            if nargin < 2, opts = struct(); end
            run = struct('OnLine', [], 'OnDone', [], 'Deploy', true, 'DeployRoot', "", 'Metric', "rank/spearman", ...
                'PollPeriod', 0.5);
            cmdOpts = struct();
            f = fieldnames(opts);
            for i = 1:numel(f)
                if isfield(run, f{i}), run.(f{i}) = opts.(f{i}); else, cmdOpts.(f{i}) = opts.(f{i}); end
            end
            t = curation.Trainer();
            t.ExportRoot = char(exportRoot);
            t.Command = curation.Trainer.stage2Command(exportRoot, cmdOpts);
            t.Options = run;
            if string(run.DeployRoot) == "", t.Options.DeployRoot = t.Command.WorkingDir; end
            t.RunDir = char(t.Command.RunDir);
            if ~isfolder(t.RunDir), mkdir(t.RunDir); end
            t.LogFile = fullfile(t.RunDir, 'curation_trainer.log');
            t.Log = fopen(t.LogFile, 'a', 'n', 'UTF-8');
            t.say("[curation.Trainer] " + t.Command.Line);
            cfg = t.Command.Python;
            cfg.WorkingDir = t.Command.WorkingDir;
            try
                [t.Proc, t.Reader] = CellToolkit.launchPythonAsync(cfg, t.Command.Args);
            catch ME
                t.State = "failed";
                t.Error = string(ME.message);
                t.say("[curation.Trainer] could not start: " + t.Error);
                t.closeLog();
                return;
            end
            t.State = "running";
            t.Timer = timer('Period', max(0.1, run.PollPeriod), 'ExecutionMode', 'fixedSpacing', ...
                'BusyMode', 'drop', 'Name', 'curation.Trainer', 'TimerFcn', @(~, ~) t.poll());
            start(t.Timer);
        end

        function dest = deployRun(runDir, name, opts)
            %DEPLOYRUN  Copy a finished train_score.py run into a model folder (see DEPLOY).
            if nargin < 3, opts = struct(); end
            o = curation.Trainer.fill(opts, struct('DeployRoot', "", 'Metric', "rank/spearman", ...
                'Provenance', struct(), 'RepoRoot', ""));
            runDir = char(runDir);
            root = char(o.DeployRoot);
            if isempty(root), root = curation.Trainer.repo(o.RepoRoot); end
            cfgFile = fullfile(runDir, '.hydra', 'config.yaml');
            if ~isfile(cfgFile)
                error('curation:Trainer:noRun', 'No .hydra/config.yaml in %s.', runDir);
            end
            [ckpt, which] = curation.Trainer.bestCheckpoint(runDir, o.Metric);
            if isempty(ckpt)
                error('curation:Trainer:noCheckpoint', 'No checkpoint in %s.', runDir);
            end
            name = char(name);
            dest = fullfile(root, name);
            k = 1;
            while isfolder(dest) || isfile(dest)
                k = k + 1;
                dest = fullfile(root, sprintf('%s_%d', name, k));
            end
            mkdir(fullfile(dest, '.hydra'));
            copyfile(cfgFile, fullfile(dest, '.hydra', 'config.yaml'));
            for extra = {'overrides.yaml', 'hydra.yaml'}
                p = fullfile(runDir, '.hydra', extra{1});
                if isfile(p), copyfile(p, fullfile(dest, '.hydra', extra{1})); end
            end
            curation.Trainer.copyResolved(ckpt, fullfile(dest, 'best.pth'));
            for extra = {'train_log.csv', 'valid_log.csv'}
                p = fullfile(runDir, extra{1});
                if isfile(p), copyfile(p, fullfile(dest, extra{1})); end
            end
            prov = o.Provenance;
            prov.runDir = string(runDir);
            prov.checkpoint = string(ckpt);
            prov.checkpointChosenBy = string(which);
            prov.deployed = string(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));
            fid = fopen(fullfile(dest, 'curation_provenance.json'), 'w', 'n', 'UTF-8');
            if fid > 0
                fwrite(fid, jsonencode(prov, 'PrettyPrint', true), 'char');
                fclose(fid);
            end
        end

        function cfg = defaultPython(repoRoot)
            %DEFAULTPYTHON  The countpnn env's python.exe when found, else 'python' on the PATH.
            if nargin < 1 || isempty(repoRoot), repoRoot = curation.Trainer.repo(""); end
            cands = {fullfile(getenv('LOCALAPPDATA'), 'miniconda3', 'envs', 'countpnn', 'python.exe'), ...
                fullfile(getenv('USERPROFILE'), 'miniconda3', 'envs', 'countpnn', 'python.exe'), ...
                fullfile(getenv('USERPROFILE'), 'anaconda3', 'envs', 'countpnn', 'python.exe'), ...
                fullfile(getenv('LOCALAPPDATA'), 'anaconda3', 'envs', 'countpnn', 'python.exe'), ...
                'C:\ProgramData\miniconda3\envs\countpnn\python.exe'};
            exe = 'python';
            for k = 1:numel(cands)
                if isfile(cands{k}), exe = cands{k}; break; end
            end
            cfg = CellToolkit.pythonConfig('PythonExe', exe, 'CondaEnv', '', 'WorkingDir', char(repoRoot));
        end

        function v = hydraValue(p)
            %HYDRAVALUE  A path as a Hydra override value: forward slashes (a backslash escapes in
            %   Hydra's grammar), single-quoted when it holds a character the grammar treats specially.
            v = strrep(char(p), '\', '/');
            if any(ismember(v, ',=[]{}()''"$'))
                v = ['''' strrep(v, '''', '\''') ''''];
            end
        end
    end

    %% ====================================================================== the run
    methods

        function poll(t)
            if t.Busy || t.State ~= "running", return; end
            t.Busy = true;
            c = onCleanup(@() t.setBusy(false));
            t.take(CellToolkit.drainReader(t.Reader));
            code = NaN;
            try
                code = double(t.Proc.exitValue());
            catch
                return;   % still running
            end
            t.take(CellToolkit.drainReader(t.Reader, true));
            t.ExitCode = code;
            t.stopTimer();
            if code == 0 && ~isempty(curation.Trainer.bestCheckpoint(t.RunDir, t.Options.Metric))
                t.State = "succeeded";
                t.say(sprintf('[curation.Trainer] finished (exit 0): %s', t.RunDir));
                if t.Options.Deploy
                    try
                        t.deploy();
                    catch ME
                        t.Error = "deploy failed: " + string(ME.message);
                        t.say("[curation.Trainer] " + t.Error);
                    end
                end
            else
                t.State = "failed";
                t.Error = sprintf("exit code %d", code);
                t.say(sprintf('[curation.Trainer] failed (exit %d); see %s', code, t.LogFile));
            end
            t.closeLog();
            t.Proc = []; t.Reader = [];
            if ~isempty(t.Options.OnDone)
                try t.Options.OnDone(t); catch, end
            end
        end

        function ok = wait(t, timeoutSec)
            if nargin < 2, timeoutSec = Inf; end
            t0 = tic;
            while t.State == "running" && toc(t0) < timeoutSec
                t.poll();
                if t.State ~= "running", break; end
                pause(0.25);
            end
            ok = t.State ~= "running";
        end

        function cancel(t)
            if t.State ~= "running", return; end
            try t.Proc.destroyForcibly(); catch, end
            t.stopTimer();
            t.State = "cancelled";
            t.say("[curation.Trainer] cancelled");
            t.closeLog();
            t.Proc = []; t.Reader = [];
        end

        function dest = deploy(t, name)
            if t.State ~= "succeeded"
                error('curation:Trainer:notFinished', 'The run has not finished successfully (%s).', t.State);
            end
            if nargin < 2 || isempty(name), name = t.Command.DeployName; end
            prov = struct('export', string(t.ExportRoot), 'command', t.Command.Line, 'kind', t.Command.Kind, ...
                'pretrained', string(t.Command.Pretrained));
            rep = fullfile(t.ExportRoot, curation.Export.REPORT);
            if isfile(rep), prov.exportReport = string(rep); end
            dest = curation.Trainer.deployRun(t.RunDir, name, struct('DeployRoot', string(t.Options.DeployRoot), ...
                'Metric', t.Options.Metric, 'Provenance', prov));
            t.DeployedTo = dest;
            t.say("[curation.Trainer] deployed: " + string(dest));
        end

        function delete(t)
            t.stopTimer();
            t.closeLog();
        end
    end

    methods (Access = private)
        function t = Trainer()
        end

        function setBusy(t, v)
            t.Busy = v;
        end

        function take(t, lines)
            for k = 1:numel(lines)
                t.say(string(lines{k}));
            end
        end

        function say(t, line)
            t.Lines(end + 1, 1) = line;
            if numel(t.Lines) > t.MaxLines, t.Lines = t.Lines(end - t.MaxLines + 1:end); end
            if t.Log > 0
                fprintf(t.Log, '%s\n', line);
            end
            if isstruct(t.Options) && isfield(t.Options, 'OnLine') && ~isempty(t.Options.OnLine)
                try t.Options.OnLine(line); catch, end
            end
        end

        function stopTimer(t)
            if ~isempty(t.Timer) && isvalid(t.Timer)
                stop(t.Timer);
                delete(t.Timer);
            end
            t.Timer = [];
        end

        function closeLog(t)
            if t.Log > 0
                try fclose(t.Log); catch, end
            end
            t.Log = -1;
        end
    end

    methods (Static, Access = private)
        function o = fill(opts, d)
            o = d;
            if ~isstruct(opts), return; end
            f = fieldnames(opts);
            for i = 1:numel(f)
                if ~isfield(d, f{i})
                    error('curation:Trainer:badArgument', 'Unknown option "%s".', f{i});
                end
                o.(f{i}) = opts.(f{i});
            end
        end

        function r = repo(r)
            r = char(r);
            if isempty(r), r = CellToolkit.detectRepoRoot(); end
        end

        function kind = kindOf(kind, exportRoot)
            kind = string(kind);
            if kind == "" || ismissing(kind)
                rep = fullfile(exportRoot, curation.Export.REPORT);
                if isfile(rep)
                    try
                        J = jsondecode(fileread(rep));
                        kind = string(J.Kind);
                    catch
                    end
                end
            end
            if ~ismember(kind, ["pnn" "pv"])
                error('curation:Trainer:badArgument', 'opts.Kind must be "pnn" or "pv" (none found in the export report).');
            end
        end

        function a = gpuArg(device)
            if string(device) == "cpu"
                a = 'gpu=null';
            else
                a = 'gpu=0';
            end
        end

        function s = num(v)
            s = char(string(sprintf('%.6g', v)));
        end

        function cmd = pack(script, args, py, repo, runDir, kind, pre, name)
            if isempty(py) || ~isstruct(py), py = curation.Trainer.defaultPython(repo); end
            parts = CellToolkit.pythonCommandParts(py, args);
            cmd = struct('Script', string(script), 'Args', {args}, 'Parts', {parts}, ...
                'Line', string(CellToolkit.commandString(parts)), 'WorkingDir', char(repo), ...
                'RunDir', char(runDir), 'Kind', string(kind), 'Pretrained', string(pre), ...
                'DeployName', string(name), 'Python', py);
        end

        function [ckpt, which] = bestCheckpoint(runDir, metric)
            ckpt = ''; which = '';
            names = {sprintf('best_model_metric_%s.pth', strrep(char(metric), '/', '-')), ...
                'best_model_metric_loss.pth'};
            for k = 1:numel(names)
                p = fullfile(runDir, 'best_models', names{k});
                if isfile(p)
                    ckpt = p; which = names{k};
                    return;
                end
            end
            p = fullfile(runDir, 'last.pth');
            if isfile(p), ckpt = p; which = 'last.pth'; end
        end

        function copyResolved(src, dst)
            % copy the file a best_models link points to (CheckpointManager links when it can)
            try
                target = java.nio.file.Paths.get(src, javaArray('java.lang.String', 0)).toRealPath( ...
                    javaArray('java.nio.file.LinkOption', 0));
                src = char(target.toString());
            catch
            end
            copyfile(src, dst);
        end
    end
end
