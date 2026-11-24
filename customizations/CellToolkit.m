classdef CellToolkit
% CELLTOOLKIT  Shared helpers for the Cell* MATLAB GUIs.
%   A stateless utility class collecting functionality common to
%   CellDiscovery, CellNeighborResolution, and CellQualityControl so the
%   three GUIs share one tested implementation instead of three copies.
%
%   Every method is Static — call them on the class, no instance needed:
%       root            = CellToolkit.detectRepoRoot();
%       [det, score]    = CellToolkit.discoverModels(root);
%       files           = CellToolkit.scanFiles(root, '(?i)_locs\.csv$');
%
%   Running the Python models
%   -------------------------
%   Describe the interpreter once with a config struct, then run scripts
%   either synchronously (capture output) or asynchronously (stream stdout):
%
%       cfg = CellToolkit.pythonConfig( ...
%               'PythonExe',  'python', ...
%               'CondaExe',   CellToolkit.detectConda(), ...
%               'CondaEnv',   'countpnn', ...
%               'WorkingDir', repoRoot);
%
%       % Pre-flight: are hydra + torch importable?
%       [ok, msg] = CellToolkit.testPythonEnv(cfg);
%
%       % Synchronous (e.g. score.py) — blocks, returns exit code + output:
%       args = CellToolkit.scoreArgs(model, locsCsv, ...
%                  struct('root', imgDir, 'device', 'cuda:0', 'output', outCsv));
%       [status, output] = CellToolkit.runPython(cfg, args);
%
%       % Asynchronous (e.g. predict.py) — returns a live process you poll:
%       args = CellToolkit.predictArgs(model, imgPath, ...
%                  struct('output', outCsv, 'device', 'cuda:0', 'batchSize', 1));
%       [proc, reader] = CellToolkit.launchPythonAsync(cfg, args);
%       ...
%       lines = CellToolkit.drainReader(reader);   % poll from a timer
%
%   The config is a plain struct, so a caller may also build/modify it by
%   hand; pythonConfig only supplies sensible defaults and normalises types.
%
%   The model input
%   ---------------
%   The image the detector and the Stage-2 scorer read (LSM correction, top-hat,
%   resize to 0.645 um/px, normalisation to 0-255) is built by ONE pipeline,
%   used by CellDiscovery and by the curation exports / rescoring:
%       [img, info]  = CellToolkit.modelInputPage(page, facts);
%       img          = CellToolkit.modelInputFromFile(tif, pageNo, facts);
%       [facts, rep] = CellToolkit.modelInputFactsFor(det, tif, pageNo, locs, resizedLocs);
%   (det = the manifest's detection stage, where CellDiscovery records the
%   facts; see the "Model input" section below).

    %% ===================================================================
    %  Python environment & model execution
    %  ===================================================================
    methods (Static)

        function condaExe = detectConda()
            % Auto-detect the conda executable on Windows from common install
            % locations. Returns '' when nothing is found, so a caller can
            % prompt the user to browse for it (an empty path also lets a
            % conda already on PATH be used by name elsewhere).
            candidates = { ...
                fullfile(getenv('USERPROFILE'),  'miniconda3', 'Scripts',  'conda.exe'), ...
                fullfile(getenv('USERPROFILE'),  'miniconda3', 'condabin', 'conda.bat'), ...
                fullfile(getenv('USERPROFILE'),  'anaconda3',  'Scripts',  'conda.exe'), ...
                fullfile(getenv('USERPROFILE'),  'anaconda3',  'condabin', 'conda.bat'), ...
                fullfile(getenv('LOCALAPPDATA'), 'miniconda3', 'Scripts',  'conda.exe'), ...
                fullfile(getenv('LOCALAPPDATA'), 'miniconda3', 'condabin', 'conda.bat'), ...
                fullfile(getenv('LOCALAPPDATA'), 'anaconda3',  'Scripts',  'conda.exe'), ...
                fullfile(getenv('LOCALAPPDATA'), 'anaconda3',  'condabin', 'conda.bat'), ...
                'C:\ProgramData\miniconda3\Scripts\conda.exe', ...
                'C:\ProgramData\miniconda3\condabin\conda.bat', ...
                'C:\ProgramData\anaconda3\Scripts\conda.exe', ...
                'C:\ProgramData\anaconda3\condabin\conda.bat' ...
                };
            for k = 1:numel(candidates)
                if ~isempty(candidates{k}) && exist(candidates{k}, 'file')
                    condaExe = candidates{k};
                    return;
                end
            end
            condaExe = '';
        end

        function root = detectRepoRoot(sentinelFiles, startDir)
            % Locate the repo root: the directory containing a known sentinel
            % script (predict.py / score.py). Searches startDir and its
            % parent, so callers work whether they live at the repo root or
            % in a subfolder such as customizations/.
            %
            %   sentinelFiles : char/cellstr of filenames marking the root.
            %                   Default {'predict.py','score.py'}.
            %   startDir      : directory to begin the search.
            %                   Default: this class file's own folder.
            if nargin < 1 || isempty(sentinelFiles)
                sentinelFiles = {'predict.py', 'score.py'};
            end
            if ischar(sentinelFiles) || isstring(sentinelFiles)
                sentinelFiles = cellstr(sentinelFiles);
            end
            if nargin < 2 || isempty(startDir)
                startDir = fileparts(mfilename('fullpath'));
            end
            startDir = char(startDir);

            candidates = {startDir, fileparts(startDir)};
            for c = 1:numel(candidates)
                d = candidates{c};
                if isempty(d), continue; end
                for s = 1:numel(sentinelFiles)
                    if exist(fullfile(d, sentinelFiles{s}), 'file')
                        root = d;
                        return;
                    end
                end
            end
            root = startDir;   % fallback: best guess
        end

        function [detModels, scoreModels] = discoverModels(repoRoot)
            % Scan repoRoot for immediate subdirectories that contain best.pth
            % and split them by naming convention:
            %   * name contains 'fasterrcnn'  -> detection model
            %   * otherwise                   -> Stage-2 scoring model
            % Both lists are returned sorted. Either may be empty.
            detModels   = {};
            scoreModels = {};
            root = char(repoRoot);
            if isempty(root) || ~isfolder(root)
                return;
            end
            d       = dir(root);
            subdirs = {d([d.isdir]).name};
            subdirs = subdirs(~ismember(subdirs, {'.', '..'}));
            for k = 1:numel(subdirs)
                if exist(fullfile(root, subdirs{k}, 'best.pth'), 'file')
                    if isempty(regexpi(subdirs{k}, 'fasterrcnn', 'once'))
                        scoreModels{end+1} = subdirs{k}; %#ok<AGROW>
                    else
                        detModels{end+1}   = subdirs{k}; %#ok<AGROW>
                    end
                end
            end
            detModels   = sort(detModels);
            scoreModels = sort(scoreModels);
        end

        function cfg = pythonConfig(varargin)
            % Build a normalised Python-invocation config struct. Accepts
            % name-value pairs or a single struct to override these defaults:
            %   PythonExe  : interpreter (default 'python')
            %   CondaExe   : conda executable (default detectConda())
            %   CondaEnv   : conda env name; '' invokes Python directly
            %   WorkingDir : process working directory; '' = inherit
            cfg = struct('PythonExe', 'python', ...
                         'CondaExe',  CellToolkit.detectConda(), ...
                         'CondaEnv',  '', ...
                         'WorkingDir', '');
            if isscalar(varargin) && isstruct(varargin{1})
                src = varargin{1};
                fn  = fieldnames(src);
                for k = 1:numel(fn)
                    if isfield(cfg, fn{k})
                        cfg.(fn{k}) = src.(fn{k});
                    end
                end
            else
                if mod(numel(varargin), 2) ~= 0
                    error('CellToolkit:pythonConfig', ...
                        'Options must be name-value pairs.');
                end
                for k = 1:2:numel(varargin)
                    name = varargin{k};
                    if ~ischar(name) || ~isfield(cfg, name)
                        error('CellToolkit:pythonConfig', ...
                            'Unknown option "%s".', char(string(name)));
                    end
                    cfg.(name) = varargin{k+1};
                end
            end
            % Normalise all fields to char for downstream command building.
            cfg.PythonExe  = char(string(cfg.PythonExe));
            cfg.CondaExe   = char(string(cfg.CondaExe));
            cfg.CondaEnv   = char(string(cfg.CondaEnv));
            cfg.WorkingDir = char(string(cfg.WorkingDir));
            if isempty(cfg.PythonExe), cfg.PythonExe = 'python'; end
        end

        function parts = pythonCommandParts(cfg, scriptArgs)
            % Assemble the full command as a cellstr of argument tokens,
            % wrapping in 'conda run' when cfg.CondaEnv is set. Each token is
            % a separate argument (no quoting) — suitable for ProcessBuilder.
            % scriptArgs is a cellstr, e.g. {'predict.py', model, img, '--output', out}
            % or {'-c', 'import torch'} for an inline snippet.
            if nargin < 2 || isempty(scriptArgs)
                scriptArgs = {};
            end
            scriptArgs = cellfun(@(x) char(string(x)), scriptArgs(:)', ...
                'UniformOutput', false);

            pyExe = char(CellToolkit.fieldOr(cfg, 'PythonExe', 'python'));
            base  = [{pyExe}, scriptArgs];

            env = char(CellToolkit.fieldOr(cfg, 'CondaEnv', ''));
            if ~isempty(env)
                condaExe = char(CellToolkit.fieldOr(cfg, 'CondaExe', 'conda'));
                if isempty(condaExe), condaExe = 'conda'; end
                % --no-capture-output is required for real-time stdout streaming.
                parts = [{condaExe, 'run', '--no-capture-output', '-n', env}, base];
            else
                parts = base;
            end
        end

        function [status, output] = runPython(cfg, scriptArgs)
            % Run a Python command synchronously via system(), returning the
            % exit status and combined stdout/stderr. Honours cfg.WorkingDir.
            parts  = CellToolkit.pythonCommandParts(cfg, scriptArgs);
            cmd    = CellToolkit.commandString(parts);
            wd     = char(CellToolkit.fieldOr(cfg, 'WorkingDir', ''));
            if ~isempty(wd)
                if ispc
                    cmd = sprintf('cd /d "%s" && %s', wd, cmd);
                else
                    cmd = sprintf('cd "%s" && %s', wd, cmd);
                end
            end
            [status, output] = system(cmd);
        end

        function [proc, reader] = launchPythonAsync(cfg, scriptArgs)
            % Launch a Python command asynchronously through a Java
            % ProcessBuilder so its stdout can be streamed while it runs.
            % Returns the live java.lang.Process and a BufferedReader; poll
            % the reader with drainReader() and check proc.exitValue() for
            % completion. stderr is merged into stdout.
            parts = CellToolkit.pythonCommandParts(cfg, scriptArgs);
            n     = numel(parts);
            jCmd  = javaArray('java.lang.String', n);
            for k = 1:n
                jCmd(k) = java.lang.String(parts{k});
            end
            pb = java.lang.ProcessBuilder(jCmd);
            wd = char(CellToolkit.fieldOr(cfg, 'WorkingDir', ''));
            if ~isempty(wd) && isfolder(wd)
                pb.directory(java.io.File(wd));
            end
            pb.redirectErrorStream(true);
            proc   = pb.start();
            reader = java.io.BufferedReader( ...
                java.io.InputStreamReader(proc.getInputStream()));
        end

        function lines = drainReader(reader, untilEof)
            % Read lines from a BufferedReader returned by launchPythonAsync.
            % By default reads only what is currently buffered (non-blocking),
            % which is what a timer-driven poll wants. Pass untilEof=true to
            % block and drain everything remaining (e.g. after the process
            % has exited). Returns an Nx1 cellstr (possibly empty).
            lines = {};
            if isempty(reader)
                return;
            end
            if nargin < 2
                untilEof = false;
            end
            try
                if untilEof
                    line = reader.readLine();
                    while ~isequal(line, [])
                        lines{end+1, 1} = char(line); %#ok<AGROW>
                        line = reader.readLine();
                    end
                else
                    while reader.ready()
                        line = reader.readLine();
                        if isequal(line, []), break; end
                        lines{end+1, 1} = char(line); %#ok<AGROW>
                    end
                end
            catch
                % Reader closed or process gone — return whatever we collected.
            end
        end

        function [ok, msg, output, cudaAvailable] = testPythonEnv(cfg, importModules)
            % Quick synchronous check that the configured environment can
            % import the required modules. Defaults to {'hydra','torch'} —
            % the imports predict.py / score.py need. Returns ok (logical),
            % a human-readable msg ('' on success), and the raw command output.
            % cudaAvailable (optional): when torch is among the modules, whether
            % torch.cuda.is_available() (true / false); NaN when unknown (torch
            % not imported, or the check failed).
            if nargin < 2 || isempty(importModules)
                importModules = {'hydra', 'torch'};
            end
            if ischar(importModules) || isstring(importModules)
                importModules = cellstr(importModules);
            end
            modList = strjoin(importModules, ', ');
            code    = sprintf('import %s; print(''OK'')', modList);
            cudaAvailable = NaN;
            askCuda = any(strcmp(importModules, 'torch'));
            if askCuda
                % No double quotes or percent signs: the snippet goes through system().
                code = [code '; print(''CUDA'', int(torch.cuda.is_available()))'];
            end

            % Guard the common misconfiguration: env set but no conda exe.
            env = char(CellToolkit.fieldOr(cfg, 'CondaEnv', ''));
            if ~isempty(env) && isempty(char(CellToolkit.fieldOr(cfg, 'CondaExe', '')))
                ok = false; output = '';
                msg = sprintf(['Conda env "%s" is set but the conda executable ' ...
                    'path is empty.\nSet CondaExe (browse for conda.exe / ' ...
                    'conda.bat).'], env);
                return;
            end

            [status, output] = CellToolkit.runPython(cfg, {'-c', code});
            output = strtrim(output);
            ok = (status == 0) && contains(output, 'OK');
            if ok && askCuda
                tok = regexp(output, 'CUDA\s+([01])', 'tokens', 'once');
                if ~isempty(tok), cudaAvailable = (tok{1} == '1'); end
            end
            if ok
                msg = '';
            else
                if isempty(env)
                    where = sprintf('Python executable "%s"', ...
                        char(CellToolkit.fieldOr(cfg, 'PythonExe', 'python')));
                else
                    where = sprintf('conda env "%s"', env);
                end
                msg = sprintf(['%s could not import: %s\n\n' ...
                    'Check the interpreter/env is correct and has the repo ' ...
                    'dependencies installed.\n\nOutput:\n%s'], where, modList, output);
            end
        end

        function args = predictArgs(model, imagePath, opts)
            % Assemble a predict.py argument list (excluding the interpreter).
            % opts is an optional struct; recognised fields:
            %   output, device, batchSize, threshold, rescoreModel
            % A blank/NaN threshold is omitted (predict.py then uses the
            % checkpoint default); an empty rescoreModel skips rescoring.
            if nargin < 3, opts = struct(); end
            args = {'predict.py', char(string(model)), char(string(imagePath))};
            if CellToolkit.hasField(opts, 'output')
                args = [args, {'--output', char(string(opts.output))}];
            end
            if CellToolkit.hasField(opts, 'device')
                args = [args, {'--device', char(string(opts.device))}];
            end
            if CellToolkit.hasField(opts, 'batchSize')
                args = [args, {'--batch-size', CellToolkit.numToStr(opts.batchSize)}];
            end
            if CellToolkit.hasField(opts, 'threshold')
                thr = opts.threshold;
                if ischar(thr) || isstring(thr), thr = str2double(thr); end
                if ~isempty(thr) && ~isnan(thr)
                    args = [args, {'--threshold', CellToolkit.numToStr(thr)}];
                end
            end
            if CellToolkit.hasField(opts, 'rescoreModel')
                rm = char(string(opts.rescoreModel));
                if ~isempty(rm)
                    args = [args, {'--rescore', rm}];
                end
            end
        end

        function args = scoreArgs(model, locsCsv, opts)
            % Assemble a score.py argument list (excluding the interpreter).
            % score.py is the Stage-2 rescoring script: it crops a patch around
            % each localization and runs a scoring model to estimate inter-rater
            % agreement quality [0-1], written to a 'rescore' column.
            %
            %   model   : scoring-model run directory (score.py's 'run' arg)
            %   locsCsv : localizations CSV to rescore (score.py's 'locs' arg).
            %             Must carry imgName, Xp and Yp columns; the first
            %             column is consumed as the pandas index.
            % opts is an optional struct; recognised fields:
            %   root      : directory the imgName paths are resolved against
            %   device, batchSize, metric, patchSize, output
            if nargin < 3, opts = struct(); end
            args = {'score.py', char(string(model)), char(string(locsCsv))};
            if CellToolkit.hasField(opts, 'root')
                args = [args, {'--root', char(string(opts.root))}];
            end
            if CellToolkit.hasField(opts, 'device')
                args = [args, {'--device', char(string(opts.device))}];
            end
            if CellToolkit.hasField(opts, 'batchSize')
                args = [args, {'--batch-size', CellToolkit.numToStr(opts.batchSize)}];
            end
            if CellToolkit.hasField(opts, 'metric')
                args = [args, {'--metric', char(string(opts.metric))}];
            end
            if CellToolkit.hasField(opts, 'patchSize')
                args = [args, {'--patch-size', CellToolkit.numToStr(opts.patchSize)}];
            end
            if CellToolkit.hasField(opts, 'output')
                args = [args, {'--output', char(string(opts.output))}];
            end
        end

        function s = commandString(parts)
            % Join command tokens into a single string for logging/system(),
            % wrapping any token containing a space in double quotes.
            q = cellfun(@CellToolkit.quoteIfSpaced, parts, 'UniformOutput', false);
            s = strjoin(q, ' ');
        end

        function s = quoteIfSpaced(s)
            % Wrap a token in double-quotes when it contains a space.
            s = char(string(s));
            if ~isempty(s) && any(s == ' ') && ~(s(1) == '"' && s(end) == '"')
                s = ['"' s '"'];
            end
        end

    end

    %% ===================================================================
    %  Filesystem
    %  ===================================================================
    methods (Static)

        function allFiles = recDir(rootDir)
            % Recursively list every file under rootDir as an Nx1 cellstr of
            % absolute paths. Uses MATLAB's built-in '**' glob, which (unlike
            % a hand-rolled recursion) skips unreadable subfolders and reparse
            % points / cloud-sync junctions instead of stalling or erroring on
            % them.
            allFiles = {};
            listing  = dir(fullfile(char(rootDir), '**', '*'));
            if isempty(listing)
                return;
            end
            listing  = listing(~[listing.isdir]);
            allFiles = cell(numel(listing), 1);
            for k = 1:numel(listing)
                allFiles{k} = fullfile(listing(k).folder, listing(k).name);
            end
        end

        function [matched, keepMask] = filterByRegex(files, pattern)
            % Keep files whose basename (name + extension, not the full path)
            % matches a case-insensitive regular expression. An empty pattern
            % keeps everything. Bad matches on individual names are ignored.
            files = files(:);
            if isempty(files)
                matched = {}; keepMask = false(0, 1);
                return;
            end
            if nargin < 2 || isempty(pattern)
                matched = files; keepMask = true(numel(files), 1);
                return;
            end
            keepMask = false(numel(files), 1);
            for k = 1:numel(files)
                [~, nm, ext] = fileparts(files{k});
                try
                    if ~isempty(regexpi([nm ext], pattern, 'once'))
                        keepMask(k) = true;
                    end
                catch
                    % Treat a regex failure on this name as a non-match.
                end
            end
            matched = files(keepMask);
        end

        function files = scanFiles(rootDir, pattern)
            % Convenience: recursively list files under rootDir, optionally
            % filtered by a case-insensitive basename regex. This is the core
            % of every "scan a folder for CSVs/images" operation.
            files = CellToolkit.recDir(rootDir);
            if nargin >= 2 && ~isempty(pattern)
                files = CellToolkit.filterByRegex(files, pattern);
            end
        end

        function rel = makeRelativePath(absPath, rootDir)
            % Return absPath relative to rootDir (case-insensitive, separator
            % agnostic). Falls back to absPath when it is not under rootDir.
            absPath = strrep(char(absPath), '\', '/');
            rootDir = strrep(char(rootDir), '\', '/');
            if isempty(rootDir)
                rel = absPath;
                return;
            end
            if rootDir(end) ~= '/'
                rootDir = [rootDir '/'];
            end
            if strncmpi(absPath, rootDir, numel(rootDir))
                rel = absPath(numel(rootDir)+1:end);
            else
                rel = absPath;
            end
        end

        function deleteFiles(paths)
            % Delete one or more files if they exist, ignoring any error.
            % Accepts a char path, string array, or cell array of paths.
            if ischar(paths) || isstring(paths)
                paths = cellstr(paths);
            end
            for k = 1:numel(paths)
                p = char(string(paths{k}));
                if ~isempty(p) && exist(p, 'file')
                    try
                        delete(p);
                    catch
                    end
                end
            end
        end

        function openFolderInSystemBrowser(folderPath)
            % Open a folder in the OS file browser (Explorer / Finder / xdg).
            folderPath = char(string(folderPath));
            if ispc
                winopen(folderPath);
            elseif ismac
                system(sprintf('open "%s"', folderPath));
            else
                system(sprintf('xdg-open "%s" >/dev/null 2>&1 &', folderPath));
            end
        end

    end

    %% ===================================================================
    %  Image / TIFF & localization-file conventions
    %  ===================================================================
    methods (Static)

        function n = countPages(file)
            % Number of pages/frames in an image file (1 for single-image
            % formats or when the file cannot be probed).
            try
                n = numel(imfinfo(char(file)));
            catch
                n = 1;
            end
        end

        function img = readPage(file, page, nPages)
            % Read one page of an image. For single-image formats the frame
            % index is omitted (some formats reject it). nPages may be passed
            % to avoid a redundant imfinfo; if omitted it is probed.
            file = char(file);
            if nargin < 3 || isempty(nPages)
                nPages = CellToolkit.countPages(file);
            end
            if nPages <= 1
                img = imread(file);
            else
                img = imread(file, page);
            end
        end

        function um = tiffPixelSizeUm(file, page)
            % Micrometres per pixel of a TIFF page from its calibration, or NaN
            % when the file carries no usable physical scale.
            %
            % Two conventions are understood:
            %   * ImageJ/Fiji: XResolution is pixels per <unit>, where the unit
            %     is named in the ImageDescription ("unit=micron"); the TIFF
            %     ResolutionUnit tag is then typically "None".
            %   * Plain TIFF: XResolution is pixels per ResolutionUnit
            %     (Centimeter or Inch).
            % Implausible results (outside 0.01-100 um/px, e.g. the 72 dpi many
            % programs write by default) are reported as NaN rather than
            % trusted, so callers can fall back explicitly.
            um = NaN;
            if nargin < 2 || isempty(page), page = 1; end
            try
                info = imfinfo(char(file));
            catch
                return;
            end
            if isempty(info) || ~isfield(info, 'XResolution'), return; end
            pg = info(min(max(1, round(page)), numel(info)));
            if isempty(pg.XResolution), return; end
            xr = double(pg.XResolution(1));
            if ~isfinite(xr) || xr <= 0, return; end

            unitUm = NaN;   % micrometres per resolution unit
            if isfield(info, 'ImageDescription')
                desc = pg.ImageDescription;
                if isempty(desc), desc = info(1).ImageDescription; end   % ImageJ: first page only
                if ischar(desc) && contains(desc, 'ImageJ')
                    tok = regexp(desc, 'unit=(\S+)', 'tokens', 'once');
                    if ~isempty(tok)
                        switch lower(tok{1})
                            case {'micron', 'microns', 'um', [char(181) 'm'], 'µm'}
                                unitUm = 1;
                            case 'nm',   unitUm = 1e-3;
                            case 'mm',   unitUm = 1e3;
                            case 'cm',   unitUm = 1e4;
                            case 'inch', unitUm = 25400;
                        end
                    end
                end
            end
            if isnan(unitUm) && isfield(pg, 'ResolutionUnit')
                switch lower(char(string(pg.ResolutionUnit)))
                    case 'centimeter', unitUm = 1e4;
                    case 'inch',       unitUm = 25400;
                end
            end

            um = unitUm / xr;
            if ~(um >= 0.01 && um <= 100), um = NaN; end
        end

        function [out, lims] = normalizeIntensity(img, pct, target)
            % Linearly stretch an image so that its pct(1)-th percentile maps to
            % 0 and its pct(2)-th percentile to target, clipping outside.
            %   [out, lims] = CellToolkit.normalizeIntensity(img)            % [1 99.9] -> [0 255]
            %   [out, lims] = CellToolkit.normalizeIntensity(img, pct, target)
            %
            % The detection models were trained on 8-bit images and predict.py
            % divides pixel values by 255, so an image on any other scale
            % (16-bit, float projections, ...) reaches the model outside the
            % intensity range it learned and the number of detections follows
            % the image brightness. This puts every image on the same scale.
            %
            % out is single; lims = [lo hi] are the source intensities mapped to
            % 0 and target ([NaN NaN], with out = single(img), when the image
            % has no intensity spread to stretch). Multi-channel images are
            % stretched per channel (lims then has one row per channel).
            % Percentiles are taken over a regular subsample (<= ~4 M pixels)
            % of the finite pixels, so no toolbox is needed.
            % The stretch itself is applyIntensityLimits (also used to re-apply
            % recorded limits, see modelInputPage).
            if nargin < 2 || isempty(pct),    pct    = [1 99.9]; end
            if nargin < 3 || isempty(target), target = 255;      end
            lims = CellToolkit.intensityLimits(img, pct);
            out  = CellToolkit.applyIntensityLimits(img, lims, target);
        end

        function lims = intensityLimits(img, pct)
            % Per-channel [lo hi] = the pct(1)-th and pct(2)-th percentiles of the
            % finite pixels of img (regular subsample of <= ~4 M pixels), as
            % normalizeIntensity uses them; [NaN NaN] for a channel without spread.
            if nargin < 2 || isempty(pct), pct = [1 99.9]; end
            v0   = single(img);
            nCh  = size(v0, 3);
            lims = nan(nCh, 2);
            step = max(1, floor(sqrt(size(v0, 1) * size(v0, 2) / 4e6)));
            for c = 1:nCh
                v = v0(1:step:end, 1:step:end, c);
                v = sort(double(v(isfinite(v))));
                n = numel(v);
                if n == 0, continue; end
                lo = v(max(1, min(n, round(pct(1) / 100 * (n - 1)) + 1)));
                hi = v(max(1, min(n, round(pct(2) / 100 * (n - 1)) + 1)));
                if ~(hi > lo), continue; end
                lims(c, :) = [lo hi];
            end
        end

        function out = applyIntensityLimits(img, lims, target)
            % single(img) with each channel c mapped linearly lims(c,1) -> 0 and
            % lims(c,2) -> target, clipped to [0 target]. A channel whose limits
            % are not finite with hi > lo is left as single(img). The arithmetic
            % is normalizeIntensity's, so re-applying recorded limits reproduces
            % its output bit for bit.
            if nargin < 3 || isempty(target), target = 255; end
            out = single(img);
            nCh = size(out, 3);
            if isempty(lims), return; end
            lims = reshape(double(lims), [], 2);
            if size(lims, 1) == 1 && nCh > 1, lims = repmat(lims, nCh, 1); end
            for c = 1:min(nCh, size(lims, 1))
                lo = lims(c, 1); hi = lims(c, 2);
                if ~(isfinite(lo) && isfinite(hi) && hi > lo), continue; end
                ch = (out(:, :, c) - single(lo)) * single(target / (hi - lo));
                out(:, :, c) = min(max(ch, 0), single(target));
            end
        end

        function pg = pageFromIdentity(identity)
            % Page index encoded in a per-page identity string of the form
            % "<stem>_<suffix><page>", where <suffix> is alphabetic (e.g.
            % "page", "PNN", "PV") and <page> is the TIFF page index. Returns
            % NaN when no such page suffix is present (e.g. a bare filename).
            pg  = NaN;
            tok = regexp(char(identity), '_[A-Za-z]+(\d+)$', 'tokens', 'once');
            if ~isempty(tok)
                pg = str2double(tok{1});
            end
        end

        function pg = pageFromCsvName(csvPath)
            % Page index encoded in a localization CSV filename following the
            % CellDiscovery convention "<stem>_<suffix><page>_locs[_resized].csv".
            % Returns NaN when the name encodes no page.
            [~, name, ~] = fileparts(char(csvPath));
            core = regexprep(name, '_locs(_resized)?$', '', 'ignorecase');
            pg   = CellToolkit.pageFromIdentity(core);
        end

        function imagePath = inferImagePath(csvPath, suffixes, exts)
            % Find the companion TIFF for a localization CSV, following the
            % CellDiscovery naming convention:
            %   "img_PNN1_locs.csv"         -> "img.tif"
            %   "img_locs.csv"              -> "img.tif"
            %   "img_PNN1_locs_resized.csv" -> "img_resized.tif"
            %   "img_locs_resized.csv"      -> "img_resized.tif"
            % Stems are tried most- to least-specific; for each, the given
            % image suffixes are tried in order. A "*_locs_resized.csv" holds
            % coordinates in the resized image's space, so it is matched
            % ONLY against the resized image ("<stem>_resized.tif") — never the
            % full-resolution page, whose coordinate space differs. Returns ''
            % when nothing matches.
            %
            %   suffixes : image-stem suffixes to try. Default depends on the
            %              CSV: {'_resized'} for a resized CSV, otherwise
            %              {'_preprocessed','_proj',''}.
            %   exts     : file extensions to try (default {'.tif','.tiff'})
            [folder, name, ~] = fileparts(char(csvPath));
            isResized = ~isempty(regexpi(name, '_locs_resized$', 'once'));
            if nargin < 2 || isempty(suffixes)
                if isResized
                    suffixes = {'_resized'};
                else
                    suffixes = {'_preprocessed', '_proj', ''};
                end
            end
            if nargin < 3 || isempty(exts)
                exts = {'.tif', '.tiff'};
            end
            imagePath = '';

            % Candidate stems, most- to least-specific.
            stems = {};
            s1 = regexprep(name, '_[^_]+_locs(_resized)?$', '', 'ignorecase');
            if ~strcmp(s1, name), stems{end+1} = s1; end
            s2 = regexprep(name, '_locs(_resized)?$', '', 'ignorecase');
            if ~strcmp(s2, name), stems{end+1} = s2; end
            stems{end+1} = name;   % bare name as a last resort

            for si = 1:numel(stems)
                for pi = 1:numel(suffixes)
                    for ei = 1:numel(exts)
                        candidate = fullfile(folder, [stems{si}, suffixes{pi}, exts{ei}]);
                        if isfile(candidate)
                            imagePath = candidate;
                            return;
                        end
                    end
                end
            end
        end

        function [img, cache] = readImagePageCached(imagePath, pageIndex, cache)
            % Read a TIFF page, memoising it in a struct cache keyed by page so
            % repeated requests for the same page avoid re-reading from disk.
            %   cache : struct used as the store (pass struct() the first time)
            % Returns the page image (or [] on failure) and the updated cache,
            % which the caller stores back to retain the memoisation.
            %
            % Usage:
            %   [img, app.PageCache] = CellToolkit.readImagePageCached(p, k, app.PageCache);
            if nargin < 3 || ~isstruct(cache)
                cache = struct();
            end
            field = sprintf('p%d', pageIndex);
            if isfield(cache, field)
                img = cache.(field);
                return;
            end
            try
                img = imread(char(imagePath), pageIndex);
                cache.(field) = img;
            catch
                img = [];
            end
        end

    end

    %% ===================================================================
    %  Model input: the image the detector and the Stage-2 scorer read
    %  ===================================================================
    %
    %  CellDiscovery never saves the image the models see: per page it is the
    %  TIFF page after optional bidirectional-LSM correction (jointly over the
    %  pages corrected together), morphological background subtraction
    %  (top-hat), resize to the training pixel size and intensity normalisation
    %  to 0-255, stored in the class its scratch TIFF uses. predict.py divides
    %  it by 255; score.py (Stage 2) crops 64 x 64 patches from it raw.
    %  modelInputPage is that one pipeline, shared by CellDiscovery (which calls
    %  it to build the detector input) and by the curation exports and
    %  rescoring (which regenerate the image from the recorded facts).
    %
    %  FACTS (struct; modelInputFacts fills the defaults). CellDiscovery records
    %  them in the manifest's detection stage (CellDatasetManifest.recordDetection):
    %    resize           factor applied to the page (1 = none). A detection at
    %                     full-resolution X lies at X * resize in the model input
    %                     (CellDiscovery maps detector output back with X / resize)
    %    resizeMode       'auto' (from the TIFF calibration) | 'manual' | 'uncalibrated'
    %    srcUmPerPixel    the page's calibrated um/px (NaN = none)
    %    bgRadius         top-hat disk radius in source pixels (0 = none)
    %    correctLSM       bidirectional LSM correction before everything else
    %    lsmPages         the pages corrected together with this one (joint
    %                     registration over all of them; [] = this page alone)
    %    lsmOptions       correctBidirectionalLSMArtifact name-value options as
    %                     text (CellDiscovery's stored form; parsed by lsmNameValue)
    %    normalized       percentile stretch to 0-normTarget
    %    normPercentiles  [1 99.9]     normTarget  255
    %    normLimits       [lo hi] the stretch used (recorded; recomputed when absent)
    %  Provenance added by modelInputFactsFor: assumed (names of facts that were
    %  not recorded and were assumed), inferred (names inferred from other
    %  evidence), source ("manifest" | "inferred" | "given"), notes.

    properties (Constant)
        TRAIN_UM_PER_PIXEL = 0.645      % pixel size the shipped models were trained at
        NORM_PERCENTILES   = [1 99.9]   % CellDiscovery's intensity normalisation
        NORM_TARGET        = 255
    end

    methods (Static)

        function facts = modelInputFacts(s)
            % Canonical model-input facts: every field of the FACTS list above,
            % defaults filled in (no resize, no background, no LSM, not normalised).
            % s may be any struct holding some of them, e.g. a manifest detection stage.
            facts = struct('resize', 1, 'resizeMode', '', 'srcUmPerPixel', NaN, 'bgRadius', 0, ...
                'correctLSM', false, 'lsmPages', [], 'lsmOptions', struct(), ...
                'normalized', false, 'normPercentiles', CellToolkit.NORM_PERCENTILES, ...
                'normTarget', CellToolkit.NORM_TARGET, 'normLimits', [], ...
                'assumed', strings(1, 0), 'inferred', strings(1, 0), 'source', "given", 'notes', strings(1, 0));
            if nargin < 1 || ~isstruct(s), return; end
            f = fieldnames(facts);
            for k = 1:numel(f)
                if isfield(s, f{k}) && ~isempty(s.(f{k})), facts.(f{k}) = s.(f{k}); end
            end
            facts.resize          = double(facts.resize);
            facts.bgRadius        = double(facts.bgRadius);
            facts.correctLSM      = CellToolkit.parseLogical(facts.correctLSM, false);
            facts.normalized      = CellToolkit.parseLogical(facts.normalized, false);
            facts.lsmPages        = reshape(double(facts.lsmPages), 1, []);
            facts.normPercentiles = reshape(double(facts.normPercentiles), 1, []);
            facts.normTarget      = double(facts.normTarget);
            if ~isempty(facts.normLimits)
                facts.normLimits = reshape(double(facts.normLimits), [], 2);
            end
            facts.resizeMode = char(string(facts.resizeMode));
        end

        function [out, info] = modelInputPage(img, facts)
            % The image the detection and scoring models read, from one page.
            %   [out, info] = CellToolkit.modelInputPage(img, facts)
            % img is the page as read from the TIFF, after LSM correction when
            % facts.correctLSM (modelInputFromFile does that, jointly over
            % facts.lsmPages, as CellDiscovery does). Steps, in CellDiscovery's
            % order, each skipped when its fact says so:
            %   1 background  imtophat with strel('disk', round(bgRadius)), per channel   (bgRadius > 0)
            %   2 resize      imresize(img, resize, 'lanczos3', Antialiasing true)        (resize > 0, ~= 1)
            %   3 intensity   map normLimits -> [0 normTarget], clipped; the limits are
            %                 facts.normLimits when given, else the normPercentiles of
            %                 the resized image (normalizeIntensity)                     (normalized)
            %   4 class       as CellDiscovery's scratch TIFF stores it (modelInputClass)
            % info: full (after step 1, source resolution: CellDiscovery's snap input),
            % resized (after step 2: what CellDiscovery saves as *_resized.tif), normLimits
            % ([] when not normalised), size ([h w] of out), facts (as used).
            if nargin < 2, facts = struct(); end
            facts = CellToolkit.modelInputFacts(facts);
            if facts.bgRadius > 0
                se = strel('disk', round(facts.bgRadius));
                if size(img, 3) == 1
                    img = imtophat(img, se);
                else
                    for c = 1:size(img, 3)
                        img(:, :, c) = imtophat(img(:, :, c), se);
                    end
                end
            end
            full = img;
            if facts.resize > 0 && facts.resize ~= 1
                img = imresize(img, facts.resize, 'lanczos3', 'Antialiasing', true, ...
                    'Colormap', 'original', 'Dither', false);
            end
            resized = img;
            lims = [];
            if facts.normalized
                lims = facts.normLimits;
                if isempty(lims)
                    lims = CellToolkit.intensityLimits(img, facts.normPercentiles);
                end
                img = CellToolkit.applyIntensityLimits(img, lims, facts.normTarget);
            end
            out = CellToolkit.modelInputClass(img);
            if nargout > 1
                facts.normLimits = lims;
                info = struct('full', full, 'resized', resized, 'normLimits', lims, ...
                    'size', [size(out, 1) size(out, 2)], 'facts', facts);
            end
        end

        function img = modelInputClass(img)
            % The class CellDiscovery's scratch TIFF (the detector input file) stores
            % a page in: double -> single; single, uint16, int16, uint32 kept;
            % anything else -> uint8. predict.py / score.py read that file.
            switch class(img)
                case 'double'
                    img = single(img);
                case {'single', 'uint16', 'int16', 'uint32'}
                    % stored as is
                otherwise
                    img = uint8(img);
            end
        end

        function [out, info] = modelInputFromFile(imgFile, page, facts)
            % Read page PAGE of imgFile and return its model input (modelInputPage).
            % With facts.correctLSM the pages facts.lsmPages (default: PAGE alone;
            % PAGE is always included) are corrected together first, exactly as
            % CellDiscovery corrects the pages its page map marks LSM (lsmCorrectPages).
            if nargin < 3, facts = struct(); end
            facts  = CellToolkit.modelInputFacts(facts);
            imgFile = char(imgFile);
            nPages = CellToolkit.countPages(imgFile);
            if facts.correctLSM
                lsmIdx = unique([facts.lsmPages(:); page]', 'sorted');
                lsmIdx = lsmIdx(lsmIdx >= 1 & lsmIdx <= nPages);
                raws = cell(1, numel(lsmIdx));
                for k = 1:numel(lsmIdx)
                    raws{k} = CellToolkit.readPage(imgFile, lsmIdx(k), nPages);
                end
                corr = CellToolkit.lsmCorrectPages(raws, CellToolkit.lsmNameValue(facts.lsmOptions));
                img = corr{lsmIdx == page};
            else
                img = CellToolkit.readPage(imgFile, page, nPages);
            end
            [out, info] = CellToolkit.modelInputPage(img, facts);
        end

        function pages = lsmCorrectPages(pages, nameValue)
            % Bidirectional LSM correction of a set of pages, as CellDiscovery
            % does it: more than one page, all the same size and single-channel ->
            % one joint correctBidirectionalLSMArtifact call on the H x W x P stack
            % (every channel drives the registration); otherwise each page alone.
            %   nameValue : name-value cell for correctBidirectionalLSMArtifact
            %               (lsmNameValue of the stored options; {} = its defaults)
            if nargin < 2, nameValue = {}; end
            if isempty(pages), return; end
            if exist('correctBidirectionalLSMArtifact', 'file') ~= 2
                error('correctBidirectionalLSMArtifact.m must be on the MATLAB path to use Correct LSM.');
            end
            sameSize  = all(cellfun(@(im) isequal(size(im), size(pages{1})), pages));
            allSingle = all(cellfun(@(im) size(im, 3) == 1, pages));
            if numel(pages) > 1 && sameSize && allSingle
                stack  = cat(3, pages{:});
                Jstack = CellToolkit.callLsm(stack, nameValue);
                for k = 1:numel(pages)
                    pages{k} = Jstack(:, :, k);
                end
            else
                for k = 1:numel(pages)
                    pages{k} = CellToolkit.callLsm(pages{k}, nameValue);
                end
            end
        end

        function nv = lsmNameValue(opts)
            % Name-value cell for correctBidirectionalLSMArtifact from a struct of
            % option values in CellDiscovery's stored text form ('"even"', '8',
            % '[4 2 1]', 'true', 'NaN') or already typed. Field order is kept.
            nv = {};
            if ~isstruct(opts) || isempty(fieldnames(opts)), return; end
            names = fieldnames(opts);
            nv = cell(1, 2 * numel(names));
            for k = 1:numel(names)
                nv{2*k-1} = names{k};
                nv{2*k}   = CellToolkit.parseLsmOptionValue(opts.(names{k}));
            end
        end

        function v = parseLsmOptionValue(v)
            % One stored LSM option value -> the value passed to the function:
            % 'true'/'false' -> logical, numeric text -> number(s), '"text"' -> text.
            if isnumeric(v) || islogical(v)
                return;
            end
            if isstring(v)
                v = char(v);
            end
            if ~ischar(v)
                return;
            end
            txt = strtrim(v);
            low = lower(txt);
            if any(strcmp(low, {'true','false'}))
                v = strcmp(low, 'true');
                return;
            end
            num = str2num(txt); %#ok<ST2NM>
            if ~isempty(num)
                v = num;
                return;
            end
            if startsWith(txt, '"') && endsWith(txt, '"') && strlength(string(txt)) >= 2
                v = extractBetween(string(txt), 2, strlength(string(txt))-1);
                v = char(v);
            end
        end

        function [facts, rep] = modelInputFactsFor(det, imgFile, page, locsCsv, resizedCsv, opts)
            % The model-input facts of a detected source, with what was assumed.
            %   [facts, rep] = CellToolkit.modelInputFactsFor(det, imgFile, page, locsCsv, resizedCsv, opts)
            %   det        the manifest's detection stage of the source
            %              (mf.source(key).stages.detection), or struct() when none
            %   imgFile    the source TIFF; page its page
            %   locsCsv, resizedCsv   the detector's '*_locs.csv' and '*_locs_resized.csv'
            %              ('' when absent); used only to infer the resize factor
            %   opts.Assume  struct of facts to use for what was not recorded (e.g.
            %              struct('bgRadius', 20)); they are reported as assumed
            %
            % Recorded facts are used as recorded. For sections detected before the
            % facts were recorded (only the locs files exist), the FALLBACK is:
            %   resize      INFERRED: from the TIFF calibration, round(um/0.645, 4) (1 when
            %               within 1%), as CellDiscovery's auto mode computes it; without a
            %               calibration, the median ratio X_resized / X over the rows of the
            %               two locs files (the factor that detection used); else 1 (assumed).
            %               When both are available the ratio is reported as a cross-check.
            %   bgRadius    ASSUMED 0 (no background subtraction)
            %   correctLSM  ASSUMED false
            %   normalized  ASSUMED true with [1 99.9] -> 255, today's CellDiscovery default.
            %               Detections made before 2026-11-23 (no normalisation in
            %               CellDiscovery yet) saw the unnormalised page; a model trained
            %               for use with today's pipeline must see the normalised one.
            %   normLimits  recomputed from the regenerated image
            % rep (struct): assumed, inferred (string arrays), resizeSource, resizeFromCalibration,
            % resizeFromLocs, calibrationUm, notes (string array), text (one line per fact).
            if nargin < 4, locsCsv = ''; end
            if nargin < 5, resizedCsv = ''; end
            if nargin < 6 || ~isstruct(opts), opts = struct(); end
            assume = struct();
            if isfield(opts, 'Assume') && isstruct(opts.Assume), assume = opts.Assume; end
            if ~isstruct(det), det = struct(); end
            has = @(n) isfield(det, n) && ~isempty(det.(n)) && ~(isnumeric(det.(n)) && isscalar(det.(n)) && isnan(det.(n)));
            facts = CellToolkit.modelInputFacts(det);
            facts.normLimits = [];
            if has('normLimits'), facts.normLimits = reshape(double(det.normLimits), [], 2); end
            rep = struct('assumed', strings(1, 0), 'inferred', strings(1, 0), 'resizeSource', "", ...
                'resizeFromCalibration', NaN, 'resizeFromLocs', NaN, 'calibrationUm', NaN, ...
                'notes', strings(1, 0), 'text', strings(0, 1));

            um = NaN;
            try um = CellToolkit.tiffPixelSizeUm(imgFile, page); catch, end
            rep.calibrationUm = um;
            if isfinite(um)
                rz = round(um / CellToolkit.TRAIN_UM_PER_PIXEL, 4);
                if abs(rz - 1) < 0.01, rz = 1; end
                rep.resizeFromCalibration = rz;
            end
            rep.resizeFromLocs = CellToolkit.resizeFromLocs(locsCsv, resizedCsv);

            if has('resize')
                rep.resizeSource = "manifest";
            elseif isfinite(rep.resizeFromCalibration)
                facts.resize = rep.resizeFromCalibration;
                facts.resizeMode = 'auto';
                rep.resizeSource = "tiff calibration";
                rep.inferred(end+1) = "resize";
            elseif isfinite(rep.resizeFromLocs)
                facts.resize = round(rep.resizeFromLocs, 4);
                facts.resizeMode = 'manual';
                rep.resizeSource = "locs ratio";
                rep.inferred(end+1) = "resize";
            else
                facts.resize = 1;
                rep.resizeSource = "assumed";
                rep.assumed(end+1) = "resize";
            end
            if isfinite(rep.resizeFromLocs) && rep.resizeSource ~= "locs ratio"
                d = rep.resizeFromLocs / facts.resize - 1;
                rep.notes(end+1) = sprintf('resize x%.4f (%s); the locs files say x%.4f (%+.3f%%)', ...
                    facts.resize, rep.resizeSource, rep.resizeFromLocs, 100 * d);
            end
            if ~isfinite(facts.srcUmPerPixel), facts.srcUmPerPixel = um; end

            dflt = struct('bgRadius', 0, 'correctLSM', false, 'normalized', true);
            names = fieldnames(dflt);
            for k = 1:numel(names)
                n = names{k};
                if has(n), continue; end
                if isfield(assume, n), v = assume.(n); else, v = dflt.(n); end
                facts.(n) = v;
                rep.assumed(end+1) = string(n);
            end
            facts = CellToolkit.modelInputFacts(facts);
            if facts.normalized && ~has('normPercentiles')
                facts.normPercentiles = CellToolkit.NORM_PERCENTILES;
                facts.normTarget = CellToolkit.NORM_TARGET;
            end
            if facts.normalized && isempty(facts.normLimits)
                rep.notes(end+1) = "normLimits recomputed from the regenerated image";
            end
            if facts.correctLSM && ~has('lsmOptions')
                rep.notes(end+1) = "LSM options not recorded: correctBidirectionalLSMArtifact defaults";
            end
            if ~has('resize')
                facts.source = "inferred";      % no facts recorded for this detection
            elseif isempty(rep.assumed) && isempty(rep.inferred)
                facts.source = "manifest";
            else
                facts.source = "manifest+inferred";
            end
            facts.assumed  = rep.assumed;
            facts.inferred = rep.inferred;
            facts.notes    = rep.notes;
            tag = @(n) CellToolkit.ternary(any(rep.assumed == n), " (assumed)", ...
                CellToolkit.ternary(any(rep.inferred == n), " (inferred)", ""));
            rep.text = [ ...
                sprintf("resize x%.4f%s [%s]", facts.resize, tag("resize"), rep.resizeSource); ...
                sprintf("bgRadius %g%s", facts.bgRadius, tag("bgRadius")); ...
                sprintf("correctLSM %d%s", facts.correctLSM, tag("correctLSM")); ...
                sprintf("normalized %d%s", facts.normalized, tag("normalized"))];
        end

        function f = resizeFromLocs(locsCsv, resizedCsv)
            % Median ratio of X_resized / X (and Y) over the rows of a detector's
            % '*_locs_resized.csv' and '*_locs.csv', which CellDiscovery writes
            % together, row for row (X = X_resized / factor). NaN when either file
            % is missing, the row counts differ or no row has a usable ratio.
            f = NaN;
            if isempty(locsCsv) || isempty(resizedCsv) || ~isfile(locsCsv) || ~isfile(resizedCsv)
                return;
            end
            try
                o = readtable(char(locsCsv), 'VariableNamingRule', 'preserve');
                r = readtable(char(resizedCsv), 'VariableNamingRule', 'preserve');
            catch
                return;
            end
            if height(o) ~= height(r) || ~all(ismember({'X','Y'}, o.Properties.VariableNames)) ...
                    || ~all(ismember({'X','Y'}, r.Properties.VariableNames))
                return;
            end
            q = [r.X ./ o.X; r.Y ./ o.Y];
            q = q(isfinite(q) & q > 0 & [o.X; o.Y] > 1);
            if isempty(q), return; end
            f = median(q);
        end

    end

    %% ===================================================================
    %  Settings / preferences persistence
    %  ===================================================================
    methods (Static)

        function settings = loadSettingsStruct(group, key, defaults, matPath)
            % Load a persisted settings struct, preferring MATLAB preferences
            % and falling back to a MAT file, then merge onto defaults so any
            % missing/new fields are filled in. Robust to absent or corrupt
            % stores — always returns a complete struct.
            %
            %   group, key : getpref/setpref identifiers
            %   defaults   : struct of default values
            %   matPath    : optional MAT-file fallback path
            settings = defaults;
            stored   = [];
            if ispref(group, key)
                try
                    stored = getpref(group, key);
                catch
                end
            end
            if (isempty(stored) || ~isstruct(stored)) && nargin >= 4 ...
                    && ~isempty(matPath) && isfile(char(matPath))
                try
                    s = load(char(matPath), 'settings');
                    if isfield(s, 'settings')
                        stored = s.settings;
                    end
                catch
                end
            end
            if isstruct(stored)
                settings = CellToolkit.mergeSettings(defaults, stored);
            end
        end

        function saveSettingsStruct(group, key, settings, matPath)
            % Persist a settings struct to both MATLAB preferences and (when a
            % path is given) a MAT file. Failures are swallowed so a save can
            % never abort the caller.
            if nargin >= 4 && ~isempty(matPath)
                try
                    save(char(matPath), 'settings');   % var name 'settings'
                catch
                end
            end
            try
                setpref(group, key, settings);
            catch
            end
        end

        function s = getSettings(group, defaults)
            % Simple key-value settings load using the group name as both
            % the pref group and key. Used by classes that don't need the
            % full loadSettingsStruct path (no MAT-file fallback).
            if nargin < 2, defaults = struct(); end
            s = CellToolkit.loadSettingsStruct(group, 'Settings', defaults, '');
        end

        function setSettings(group, settings)
            % Persist settings written via getSettings.
            CellToolkit.saveSettingsStruct(group, 'Settings', settings, '');
        end

        function merged = mergeSettings(defaults, stored)
            % Overlay a stored settings struct onto a defaults struct: copy
            % every stored field that also exists in defaults, recursing into
            % scalar sub-structs so nested defaults survive partial saves.
            % Unknown stored fields are dropped; missing ones keep defaults.
            merged = defaults;
            if ~isstruct(stored) || ~isstruct(defaults)
                return;
            end
            fields = fieldnames(stored);
            for k = 1:numel(fields)
                f = fields{k};
                if ~isfield(defaults, f)
                    continue;
                end
                if isstruct(defaults.(f)) && isstruct(stored.(f)) ...
                        && isscalar(defaults.(f)) && isscalar(stored.(f))
                    merged.(f) = CellToolkit.mergeSettings(defaults.(f), stored.(f));
                else
                    merged.(f) = stored.(f);
                end
            end
        end

    end

    %% ===================================================================
    %  UI helpers
    %  ===================================================================
    methods (Static)

        function setTooltip(component, txt)
            % Set the Tooltip of one or more graphics components, guarding
            % against deleted handles and components without a Tooltip prop.
            if isempty(component)
                return;
            end
            component = component(:);
            for k = 1:numel(component)
                c = component(k);
                if isvalid(c) && isprop(c, 'Tooltip')
                    c.Tooltip = char(string(txt));
                end
            end
        end

        function setDropDownValue(dropDown, value)
            % Set a dropdown's Value to value when it is one of its Items;
            % otherwise fall back to the first item. No-op on invalid handles.
            if isempty(dropDown) || ~isvalid(dropDown)
                return;
            end
            items = string(dropDown.Items);
            value = string(value);
            if any(items == value)
                dropDown.Value = char(value);
            elseif ~isempty(items)
                dropDown.Value = char(items(1));
            end
        end

    end

    %% ===================================================================
    %  Value parsing / small utilities
    %  ===================================================================
    methods (Static)

        function v = parseNum(x, dflt)
            % Robustly coerce a table cell / edit-field value to a scalar
            % double, returning dflt for empty / non-scalar / NaN / unparseable.
            if nargin < 2, dflt = NaN; end
            if isnumeric(x)
                if isempty(x) || ~isscalar(x) || isnan(x)
                    v = dflt;
                else
                    v = double(x);
                end
                return;
            end
            v = str2double(strtrim(char(string(x))));
            if isnan(v), v = dflt; end
        end

        function tf = parseLogical(x, dflt)
            % Robustly coerce a value to a scalar logical. Recognises numeric
            % truthiness and common textual forms (true/yes/on/1, false/no/off/0).
            if nargin < 2, dflt = false; end
            if islogical(x)
                tf = isscalar(x) && x;
                return;
            end
            if isnumeric(x)
                tf = isscalar(x) && x ~= 0 && ~isnan(x);
                return;
            end
            if isstring(x) || ischar(x)
                v = lower(strtrim(char(string(x))));
                if ismember(v, {'true', 't', 'yes', 'y', 'on', '1'})
                    tf = true;  return;
                elseif ismember(v, {'false', 'f', 'no', 'n', 'off', '0', ''})
                    tf = false; return;
                end
            end
            tf = logical(dflt);
        end

        function result = ternary(cond, ifTrue, ifFalse)
            % Inline conditional expression: ternary(cond, a, b).
            if cond
                result = ifTrue;
            else
                result = ifFalse;
            end
        end

    end

    %% ===================================================================
    %  Internal helpers
    %  ===================================================================
    methods (Static, Access = private)

        function v = fieldOr(s, name, default)
            % Value of struct field name, or default when absent/empty.
            if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
                v = s.(name);
            else
                v = default;
            end
        end

        function img = callLsm(img, nameValue)
            % correctBidirectionalLSMArtifact with an optional name-value cell.
            if isempty(nameValue)
                img = correctBidirectionalLSMArtifact(img);
            else
                img = correctBidirectionalLSMArtifact(img, nameValue{:});
            end
        end

        function tf = hasField(s, name)
            % True when struct s has a non-empty field name.
            tf = isstruct(s) && isfield(s, name) && ~isempty(s.(name));
        end

        function str = numToStr(v)
            % Compact text for a numeric/char/string scalar command argument.
            if ischar(v)
                str = v;
            elseif isstring(v)
                str = char(v);
            else
                str = num2str(v);
            end
        end

    end

end
