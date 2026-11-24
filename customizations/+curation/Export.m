classdef Export
%EXPORT  Curated labels -> training data for the two Python models, and the legacy observation CSV.
%   Static and headless; reads the project through curation.ProjectIndex and writes only below the
%   export folder (never into the data tree).
%
%   r = curation.Export.stage2(index, outRoot, opts)        Stage-2 scorer data (train_score.py)
%   r = curation.Export.stage1(index, outRoot, opts)        Stage-1 detector data (train.py)
%   r = curation.Export.observations(index, outFile, opts)  every reviewed cell, legacy QC schema
%   index: a curation.ProjectIndex, or a project folder (built with curation.ProjectIndex.build).
%   r is the report; it is also written as export_report.json + export_summary.txt in the export
%   folder (observations: <name>_export_report.json / <name>_export_summary.txt beside the CSV).
%
%   ---------------------------------------------------------------------------------------------
%   THE IMAGE. The models read the detector input, never saved by CellDiscovery: the page after
%   LSM correction, top-hat background subtraction, resize to 0.645 um/px and normalisation to
%   0-255. Each export regenerates it with CellToolkit.modelInputFromFile from the facts the
%   manifest recorded for the source's detection (CellToolkit.modelInputFactsFor; for sections
%   detected before the facts were recorded, the resize factor is inferred and the rest assumed,
%   and the report says which, per image). Coordinates: a cell at full-resolution X (the store's
%   X, MATLAB's convention) lies at X * resize in the model input: the inverse of CellDiscovery's
%   mapping of detector output (X = X_model / resize), so a detection exports exactly where the
%   detector found it. (MATLAB treats X as 1-based and the detector writes 0-based columns; a
%   person's click therefore sits 0.5 * (resize + 1) ~ 1.8 px, ~1.2 um, right/down of where the
%   detector would put the same cell. The convention is the CellDiscovery one throughout.)
%   Images are float32 HDF5 '/data' of shape (H, W) as h5py reads it (MATLAB writes the
%   transpose), chunked (256 x 256) and deflate-compressed.
%
%   ---------------------------------------------------------------------------------------------
%   STAGE 2 (curation.Export.stage2). Folder layout, read by datasets.PerineuronalNetsRankDataset
%   with split=all (conf_score/data/curated.yaml):
%     <outRoot>/train/annotations.csv           imgName, X, Y, AV, R2, R3, R4, R5, R6, VT
%     <outRoot>/train/annotations_provenance.csv  the same rows + SourceId, Section, Animal, Key,
%                                               CellID, Label, LabelSource, Xfull, Yfull
%     <outRoot>/train/fullFramesH5/<stem>.h5    one image per source; imgName = <stem>.tif
%     <outRoot>/validation/...                  the same for the validation animals
%   X, Y = round(X_full * resize), integers (the dataset slices with them). The seven 0/1 rater
%   columns AV..VT carry the label on the 8-level agreement scale the shipped scorers were
%   trained on (agreement = their sum): Good -> 7, Uncertain -> opts.UncertainLevel (default 4),
%   Bad -> 0. So shipped weights fine-tune directly and rescore keeps its scale.
%   A row is exported when it is: State active; Reviewed; LabelSource human, confirmed, blind or
%   legacy-qc; Label Good, Bad or Uncertain; not Excluded (by the store's flag or by the current
%   regions of the curation JSON); not in curation.Audit.exportExclusionMask (holdout,
%   reject-audit and catch rows never train any model); no Flag (unless opts.IncludeFlagged);
%   inside the model image. Everything else is left out and counted per rule, first rule that
%   applies: "merged duplicate", "stale", "audit evidence (holdout/reject-audit/catch)",
%   "inside an exclusion region", "auto label", "legacy-resolver label", "not reviewed",
%   "no label", "flagged", "other label source", "outside the model image".
%   SPLIT by animal (curation.ProjectIndex.animalId): an animal's sections all go to train or all
%   to validation. opts.ValidationAnimals names them; otherwise animals are drawn in a seeded
%   random order (opts.SplitSeed) until validation holds >= opts.ValidationFraction of the rows,
%   keeping at least one animal for training. With ONE animal there is nothing to split: the
%   export stops (curation:Export:oneAnimal) unless opts.AllowSameValidation, which writes the
%   training images again as the validation set (the run then trains, but its checkpoint choice
%   is not validated; the report says so). Because the split is by folders, train_score.py runs
%   with split=all: its own image split (which needs >= 4 images and would split animals) is not
%   used, so any number of images >= 1 per side works.
%   opts (all optional):
%     Kind              "pnn" | "pv" (required): the channel kind (curation.Proposals.kindOf)
%     Sections          string array: restrict to these sections (Section, Base or SourceId)
%     UncertainLevel    4      0..7
%     MinPerClass       10     fewer Good or Bad rows in train or validation -> the report is
%                              written, no data, error curation:Export:tooFew
%     ValidationFraction 0.25, SplitSeed 1, ValidationAnimals [], AllowSameValidation false
%     IncludeFlagged    false
%     Overwrite         false  replace an earlier export in outRoot (only the files an export
%                              writes are removed); without it a non-empty outRoot is an error
%     Assume            struct of model-input facts to assume when not recorded (see
%                       CellToolkit.modelInputFactsFor), e.g. struct('bgRadius', 20)
%     Python            CellToolkit.pythonConfig struct used only for the command lines
%
%   STAGE 1 (curation.Export.stage1). Layout read by datasets.PerineuronalNetsDataset
%   (conf/experiment/curated/fasterrcnn_640.yaml):
%     <outRoot>/train/annotations.csv           index imgName (= <stem>.tif), Y, X, class (0)
%     <outRoot>/train/annotations_provenance.csv  + CellID, SourceId, Label, Half
%     <outRoot>/train/fullFramesH5/<stem>.h5
%   Only sources whose store says Complete AND SweepDone are exported: FasterRCNN treats every
%   unannotated pixel as background, so a section with unreviewed cells or an unswept area would
%   teach it that missed cells are background. Positives: active, Reviewed, person label source
%   (as Stage 2), not excluded, not audit evidence, no Flag, Label Good, and Uncertain when
%   opts.UncertainIsCell (default true); at X_full * resize, Y_full * resize, unrounded. Bad and
%   unreviewed rows (and auto Bad) are background: nothing is written for them.
%   PAINTED OUT (set to 0 in the exported image). Training has no ignore mechanism: an area can
%   only be left out by removing its pixels. Painted: every "exclude" region of the section (scope
%   "image" or the source key; tissue folds, edge artefacts: their cells are neither positive nor
%   background), and a disk of opts.IgnoreRadiusUm (12 um) around every active row that may not
%   be a positive or background: audit evidence (any label), labels from a non-person source
%   other than auto Bad (legacy-resolver), flagged rows with a Good/Uncertain label, and
%   Uncertain rows when ~UncertainIsCell. A positive whose centre pixel is painted is dropped
%   (counted). An image is skipped when either half (the train-half1/half2 splits alternate left
%   and right halves per image) has no positive (the validation loop indexes every image's
%   annotations), or when a half is narrower or the image lower than one 640 px patch (the
%   training patch offset then produces empty patches). Caveat of the upstream split: training
%   patches of a right half may reach 320 px into the left (validation) half.
%   opts: Kind (required), Sections, UncertainIsCell true, IgnoreRadiusUm 12, PatchSize 640,
%   Overwrite, Assume, Python (as above).
%
%   OBSERVATIONS (curation.Export.observations): one CSV with the columns of CellQualityControl's
%   observation export, ObservationID, ImagePath, TiffPageNumber, PageAlias, X, Y, Score, Rescore,
%   CropHeight, CropWidth, Classification: every active, Reviewed row with a label, not excluded
%   (audit rows included: they are valid observations). ObservationID = md5 of
%   "<ImagePath>|<PageAlias>|%.15g X|%.15g Y" as the legacy export; PageAlias = the channel name
%   of the source key ("ECM" for "ECM1"); X, Y full-resolution; Crop* = opts.CropSize (64).
%   opts: Kind ("" = all kinds), Sections, CropSize 64, Overwrite false.
%
%   REPORT r (every export): Stage, Kind, OutRoot, Created, Status ("ok" | "refused"), Options,
%   Counts (per section: Section, Animal, Split, Image, Good, Uncertain, Bad, Total), PerAnimal,
%   LeftOut (Rule, Count), LeftOutBySection (Section, Rule, Count), Skipped (Section, SourceId,
%   Reason), Images (imgName, SourceId, Section, Animal, Split, Height, Width, Resize,
%   FactsSource, Assumed, Inferred, Notes, and for Stage 1 the painted share and half counts),
%   Commands (the command lines to train with it, curation.Trainer), Files, Notes.
%
%   See also curation.Trainer, curation.Rescore, CellToolkit.modelInputPage, curation.Audit.

    properties (Constant)
        RATERS = ["AV" "R2" "R3" "R4" "R5" "R6" "VT"]
        REPORT = 'export_report.json'
        SUMMARY = 'export_summary.txt'
    end

    methods (Static)

        %% ======================================================================= Stage 2
        function r = stage2(index, outRoot, opts)
            if nargin < 3, opts = struct(); end
            o = curation.Export.fill(opts, struct('Kind', "", 'Sections', strings(0, 1), ...
                'UncertainLevel', 4, 'MinPerClass', 10, 'ValidationFraction', 0.25, 'SplitSeed', 1, ...
                'ValidationAnimals', strings(0, 1), 'AllowSameValidation', false, 'IncludeFlagged', false, ...
                'Overwrite', false, 'Assume', struct(), 'Python', [], 'TransposeForTest', false));
            o.Kind = curation.Export.needKind(o.Kind);
            lvl = double(o.UncertainLevel);
            if ~(isscalar(lvl) && lvl == round(lvl) && lvl >= 0 && lvl <= 7)
                error('curation:Export:badArgument', 'UncertainLevel must be an integer 0..7.');
            end
            index = curation.Export.asIndex(index);
            outRoot = curation.Export.prepareRoot(outRoot, o.Overwrite, ...
                {'train', 'validation', '.staging', curation.Export.REPORT, curation.Export.SUMMARY});
            r = curation.Export.newReport("stage2", o, outRoot);

            [S, T] = curation.Export.selectSources(index, o.Kind, o.Sections);
            parts = {};
            jsonCache = containers.Map();
            staging = fullfile(outRoot, '.staging');   % images wait here until the split is known
            used = strings(0, 1);
            for i = 1:height(S)
                s = S(i, :);
                R = T(T.SourceId == s.SourceId, :);
                [J, jsonCache] = curation.Export.json(char(s.CurationJson), jsonCache);
                [keep, why] = curation.Export.stage2Rows(R, J, s.Key, o.IncludeFlagged);
                if ~any(keep)
                    r = curation.Export.tally(r, s, why);
                    r.Skipped(end + 1, :) = {s.Section, s.SourceId, "no exportable labels"};
                    continue;
                end
                [facts, frep] = curation.Export.factsOf(s, o.Assume);
                [img, ok, msg] = curation.Export.modelImage(s, facts);
                if ~ok
                    r = curation.Export.tally(r, s, why);
                    r.Skipped(end + 1, :) = {s.Section, s.SourceId, msg};
                    continue;
                end
                f = facts.resize;
                [H, W] = size(img);
                Xm = round(R.X * f); Ym = round(R.Y * f);
                inside = Xm >= 0 & Xm <= W - 1 & Ym >= 0 & Ym <= H - 1;
                why(keep & ~inside) = "outside the model image";
                keep = keep & inside;
                r = curation.Export.tally(r, s, why);
                if ~any(keep)
                    r.Skipped(end + 1, :) = {s.Section, s.SourceId, "no exportable labels inside the image"};
                    continue;
                end
                level = zeros(height(R), 1);
                level(R.Label == "Good") = 7;
                level(R.Label == "Uncertain") = lvl;
                k = find(keep);
                P = table(repmat(s.SourceId, numel(k), 1), repmat(s.Section, numel(k), 1), ...
                    repmat(s.Animal, numel(k), 1), repmat(s.Key, numel(k), 1), double(R.CellID(k)), ...
                    R.Label(k), R.LabelSource(k), R.X(k), R.Y(k), Xm(k), Ym(k), level(k), ...
                    'VariableNames', {'SourceId', 'Section', 'Animal', 'Key', 'CellID', 'Label', ...
                    'LabelSource', 'Xfull', 'Yfull', 'X', 'Y', 'Level'});
                stem = curation.Export.uniqueStem(s.Base + "_" + s.Key, used);
                used(end + 1) = stem; %#ok<AGROW>
                if ~isfolder(staging), mkdir(staging); end
                curation.Export.writeH5(fullfile(staging, [char(stem) '.h5']), img, s, facts, o.TransposeForTest);
                parts{end + 1} = struct('s', s, 'P', P, 'size', [H W], 'facts', facts, 'frep', frep, ...
                    'stem', stem); %#ok<AGROW>
                clear img
            end
            if isempty(parts)
                if isfolder(staging), rmdir(staging, 's'); end
                r.Status = "refused";
                r.Notes(end + 1) = "nothing to export";
                curation.Export.writeReport(r, outRoot, '');
                error('curation:Export:nothing', 'No exportable %s labels in %s (see %s).', o.Kind, ...
                    index.ParentDir, fullfile(outRoot, curation.Export.REPORT));
            end

            % ---- split by animal
            allP = cellfun(@(p) p.P, parts, 'UniformOutput', false);
            allP = vertcat(allP{:});
            try
                [valAnimals, same, note] = curation.Export.splitAnimals(allP.Animal, o);
            catch ME
                curation.Export.removeData(outRoot);   % no half-made export left behind
                rethrow(ME);
            end
            if note ~= "", r.Notes(end + 1) = note; end

            % ---- images into their split folders, per-split tables
            tables = struct('train', {{}}, 'validation', {{}});
            for i = 1:numel(parts)
                p = parts{i};
                stem = p.stem;
                isVal = any(valAnimals == p.s.Animal);
                splits = "train";
                if isVal, splits = "validation"; end
                if same, splits = ["train" "validation"]; end
                src = fullfile(staging, [char(stem) '.h5']);
                for sp = splits
                    d = fullfile(outRoot, char(sp), 'fullFramesH5');
                    if ~isfolder(d), mkdir(d); end
                    copyfile(src, fullfile(d, [char(stem) '.h5']));
                    P = p.P;
                    P.imgName = repmat(stem + ".tif", height(P), 1);
                    tables.(char(sp)){end + 1} = P;
                end
                delete(src);
                r = curation.Export.addImage(r, p, stem, strjoin(splits, "+"), struct());
            end
            if isfolder(staging), rmdir(staging, 's'); end

            % ---- counts, class minimum, annotations
            for sp = ["train" "validation"]
                if isempty(tables.(char(sp))), continue; end
                P = vertcat(tables.(char(sp)){:});
                tables.(char(sp)) = {P};
            end
            short = strings(0, 1);
            for sp = ["train" "validation"]
                if isempty(tables.(char(sp)))
                    short(end + 1) = sp + ": no rows"; %#ok<AGROW>
                    continue;
                end
                P = tables.(char(sp)){1};
                nG = nnz(P.Label == "Good"); nB = nnz(P.Label == "Bad");
                if nG < o.MinPerClass || nB < o.MinPerClass
                    short(end + 1) = sprintf("%s: %d Good, %d Bad (MinPerClass %d)", sp, nG, nB, o.MinPerClass); %#ok<AGROW>
                end
            end
            r = curation.Export.countsStage2(r, tables, valAnimals, same);
            r.Commands = curation.Export.commands("stage2", outRoot, o);
            if ~isempty(short)
                r.Status = "refused";
                r.Notes = [r.Notes, "too few labels per class: " + strjoin(short, "; ")];
                curation.Export.removeData(outRoot);
                curation.Export.writeReport(r, outRoot, '');
                error('curation:Export:tooFew', 'Too few labels per class: %s (see %s).', ...
                    strjoin(short, '; '), fullfile(outRoot, curation.Export.REPORT));
            end
            for sp = ["train" "validation"]
                P = tables.(char(sp)){1};
                A = table(P.imgName, P.X, P.Y, 'VariableNames', {'imgName', 'X', 'Y'});
                for j = 1:7
                    A.(char(curation.Export.RATERS(j))) = double(P.Level >= j);
                end
                writetable(A, fullfile(outRoot, char(sp), 'annotations.csv'));
                Pv = P(:, {'imgName', 'X', 'Y', 'Level', 'SourceId', 'Section', 'Animal', 'Key', 'CellID', ...
                    'Label', 'LabelSource', 'Xfull', 'Yfull'});
                writetable(Pv, fullfile(outRoot, char(sp), 'annotations_provenance.csv'));
                r.Files.(char(sp)) = string(fullfile(outRoot, char(sp)));
            end
            if same
                r.Notes(end + 1) = "validation = the training data (one animal; AllowSameValidation): the checkpoint choice is not validated";
            end
            curation.Export.writeReport(r, outRoot, '');
        end

        %% ======================================================================= Stage 1
        function r = stage1(index, outRoot, opts)
            if nargin < 3, opts = struct(); end
            o = curation.Export.fill(opts, struct('Kind', "", 'Sections', strings(0, 1), ...
                'UncertainIsCell', true, 'IgnoreRadiusUm', 12, 'PatchSize', 640, 'Overwrite', false, ...
                'Assume', struct(), 'Python', []));
            o.Kind = curation.Export.needKind(o.Kind);
            index = curation.Export.asIndex(index);
            outRoot = curation.Export.prepareRoot(outRoot, o.Overwrite, ...
                {'train', curation.Export.REPORT, curation.Export.SUMMARY});
            r = curation.Export.newReport("stage1", o, outRoot);
            r.Images.PaintedPct = zeros(0, 1);
            r.Images.Positives = zeros(0, 1);
            r.Images.LeftPositives = zeros(0, 1);
            r.Images.RightPositives = zeros(0, 1);
            r.Images.Ignored = zeros(0, 1);

            [S, T] = curation.Export.selectSources(index, o.Kind, o.Sections);
            jsonCache = containers.Map();
            used = strings(0, 1);
            rows = {};
            imgDir = fullfile(outRoot, 'train', 'fullFramesH5');
            for i = 1:height(S)
                s = S(i, :);
                R = T(T.SourceId == s.SourceId, :);
                [J, jsonCache] = curation.Export.json(char(s.CurationJson), jsonCache);
                rec = curation.Export.record(J, s.Key);
                complete = curation.Export.flag(rec, 'complete');
                swept = curation.Export.flag(rec, 'sweepDone');
                if ~(complete && swept)
                    why = strings(0, 1);
                    if ~complete, why(end + 1) = "not marked Complete"; end %#ok<AGROW>
                    if ~swept, why(end + 1) = "missed-cell sweep not done"; end %#ok<AGROW>
                    r.Skipped(end + 1, :) = {s.Section, s.SourceId, strjoin(why, "; ")};
                    continue;
                end
                [pos, ign, why] = curation.Export.stage1Rows(R, J, s.Key, o.UncertainIsCell);
                [facts, frep] = curation.Export.factsOf(s, o.Assume);
                [img, ok, msg] = curation.Export.modelImage(s, facts);
                if ~ok
                    r.Skipped(end + 1, :) = {s.Section, s.SourceId, msg};
                    continue;
                end
                f = facts.resize;
                [H, W] = size(img);
                umModel = curation.Export.modelUm(facts);
                % ---- paint: exclusion regions and ignore disks (MATLAB model pixel = 0-based + 1)
                mask = false(H, W);
                regs = curation.Export.excludeRegions(J, s.Key);
                for q = 1:numel(regs)
                    xy = regs(q).xy;
                    mask = mask | poly2mask(xy(:, 1) * f + 1, xy(:, 2) * f + 1, H, W);
                end
                rad = o.IgnoreRadiusUm / umModel;
                gi = find(ign);
                for q = gi'
                    mask = curation.Export.paintDisk(mask, R.X(q) * f + 1, R.Y(q) * f + 1, rad);
                end
                img(mask) = 0;
                X = R.X * f; Y = R.Y * f;
                cc = round(X) + 1; rr = round(Y) + 1;
                inImg = cc >= 1 & cc <= W & rr >= 1 & rr <= H;
                painted = false(height(R), 1);
                painted(inImg) = mask(sub2ind([H W], rr(inImg), cc(inImg)));
                dropped = pos & (painted | ~inImg);
                why(pos & ~inImg) = "outside the model image";
                why(pos & inImg & painted) = "positive whose centre was painted out";
                pos = pos & ~dropped;
                r = curation.Export.tally(r, s, why(why ~= "positive" & why ~= "background"));
                half = floor(W / 2);
                nL = nnz(pos & X < half); nR = nnz(pos & X >= half);
                tooSmall = H < o.PatchSize || half < o.PatchSize || W - half < o.PatchSize;
                if tooSmall
                    r.Skipped(end + 1, :) = {s.Section, s.SourceId, sprintf( ...
                        "model image %d x %d: a half is smaller than one %d px patch", H, W, o.PatchSize)};
                    continue;
                end
                if nL == 0 || nR == 0
                    r.Skipped(end + 1, :) = {s.Section, s.SourceId, sprintf( ...
                        "a half without positives (left %d, right %d)", nL, nR)};
                    continue;
                end
                stem = curation.Export.uniqueStem(s.Base + "_" + s.Key, used);
                used(end + 1) = stem; %#ok<AGROW>
                if ~isfolder(imgDir), mkdir(imgDir); end
                curation.Export.writeH5(fullfile(imgDir, [char(stem) '.h5']), img, s, facts, false);
                k = find(pos);
                sideTxt = repmat("left", numel(k), 1);
                sideTxt(X(k) >= half) = "right";
                rows{end + 1} = table(repmat(stem + ".tif", numel(k), 1), Y(k), X(k), zeros(numel(k), 1), ...
                    double(R.CellID(k)), repmat(s.SourceId, numel(k), 1), repmat(s.Section, numel(k), 1), ...
                    repmat(s.Animal, numel(k), 1), R.Label(k), sideTxt, 'VariableNames', {'imgName', 'Y', 'X', ...
                    'class', 'CellID', 'SourceId', 'Section', 'Animal', 'Label', 'Half'}); %#ok<AGROW>
                p = struct('s', s, 'facts', facts, 'frep', frep, 'img', img);
                extra = struct('PaintedPct', 100 * nnz(mask) / numel(mask), 'Positives', numel(k), ...
                    'LeftPositives', nL, 'RightPositives', nR, 'Ignored', numel(gi));
                r = curation.Export.addImage(r, p, stem, "train-half1/half2", extra);
                r.Counts(end + 1, :) = {s.Section, s.Animal, "train", stem + ".tif", ...
                    nnz(pos & R.Label == "Good"), nnz(pos & R.Label == "Uncertain"), ...
                    nnz(why == "background" & R.Label == "Bad"), numel(k)};
            end
            if isempty(rows)
                r.Status = "refused";
                r.Notes(end + 1) = "no complete, swept section with positives in both halves";
                curation.Export.writeReport(r, outRoot, '');
                error('curation:Export:nothing', 'Nothing to export for Stage 1 (see %s).', ...
                    fullfile(outRoot, curation.Export.REPORT));
            end
            A = vertcat(rows{:});
            A = sortrows(A, {'imgName', 'Y', 'X'});
            writetable(A(:, {'imgName', 'Y', 'X', 'class'}), fullfile(outRoot, 'train', 'annotations.csv'));
            writetable(A, fullfile(outRoot, 'train', 'annotations_provenance.csv'));
            % which half trains: images sorted by name alternate left, right, left, ... (train-half1)
            names = sort(unique(A.imgName));
            r.Images.TrainHalf = strings(height(r.Images), 1);
            for q = 1:numel(names)
                j = find(r.Images.imgName + ".tif" == names(q), 1);
                if ~isempty(j)
                    r.Images.TrainHalf(j) = curation.Export.ternary(mod(q - 1, 2) == 0, "left", "right");
                end
            end
            r.PerAnimal = curation.Export.perAnimal(r.Counts);
            r.Files.train = string(fullfile(outRoot, 'train'));
            r.Commands = curation.Export.commands("stage1", outRoot, o);
            r.Notes(end + 1) = "train-half1 trains on the left half of the 1st, 3rd, ... image (by name) and the right half of the others; train-half2 validates on the other halves";
            curation.Export.writeReport(r, outRoot, '');
        end

        %% ======================================================================= observations
        function r = observations(index, outFile, opts)
            if nargin < 3, opts = struct(); end
            o = curation.Export.fill(opts, struct('Kind', "", 'Sections', strings(0, 1), 'CropSize', 64, ...
                'Overwrite', false));
            index = curation.Export.asIndex(index);
            outFile = char(outFile);
            [folder, name] = fileparts(outFile);
            if isempty(folder), folder = pwd; outFile = fullfile(folder, [name '.csv']); end
            if ~isfolder(folder), mkdir(folder); end
            if isfile(outFile) && ~o.Overwrite
                error('curation:Export:exists', '%s exists (opts.Overwrite = true to replace it).', outFile);
            end
            r = curation.Export.newReport("observations", o, string(folder));
            kinds = string(o.Kind);
            if kinds == "", kinds = unique(index.Sources.Kind)'; end
            parts = {};
            jsonCache = containers.Map();
            for kind = kinds
                [S, T] = curation.Export.selectSources(index, kind, o.Sections);
                for i = 1:height(S)
                    s = S(i, :);
                    R = T(T.SourceId == s.SourceId, :);
                    [J, jsonCache] = curation.Export.json(char(s.CurationJson), jsonCache);
                    exc = curation.Export.excludedNow(R, J, s.Key);
                    act = R.State == "active";
                    lab = R.Reviewed & ismember(R.Label, ["Good" "Bad" "Uncertain"]);
                    why = strings(height(R), 1);
                    why(~act) = "not active (merged or stale)";
                    why(act & exc) = "inside an exclusion region";
                    why(act & ~exc & ~lab) = "not reviewed";
                    keep = act & ~exc & lab;
                    r = curation.Export.tally(r, s, why(~keep));
                    if ~any(keep), continue; end
                    R = R(keep, :);
                    n = height(R);
                    alias = string(regexprep(char(s.Key), '\d+$', ''));
                    img = repmat(string(s.ImageFile), n, 1);
                    ids = strings(n, 1);
                    for q = 1:n
                        ids(q) = curation.Export.md5(sprintf('%s|%s|%.15g|%.15g', img(q), alias, R.X(q), R.Y(q)));
                    end
                    parts{end + 1} = table(ids, img, repmat(double(s.Page), n, 1), repmat(alias, n, 1), ...
                        R.X, R.Y, R.score, R.rescore, repmat(double(o.CropSize), n, 1), ...
                        repmat(double(o.CropSize), n, 1), R.Label, 'VariableNames', {'ObservationID', ...
                        'ImagePath', 'TiffPageNumber', 'PageAlias', 'X', 'Y', 'Score', 'Rescore', ...
                        'CropHeight', 'CropWidth', 'Classification'}); %#ok<AGROW>
                    r.Counts(end + 1, :) = {s.Section, s.Animal, "", string(s.ImageFile), ...
                        nnz(R.Label == "Good"), nnz(R.Label == "Uncertain"), nnz(R.Label == "Bad"), n};
                end
            end
            if isempty(parts)
                O = table(strings(0, 1), strings(0, 1), zeros(0, 1), strings(0, 1), zeros(0, 1), zeros(0, 1), ...
                    zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), strings(0, 1), 'VariableNames', ...
                    {'ObservationID', 'ImagePath', 'TiffPageNumber', 'PageAlias', 'X', 'Y', 'Score', 'Rescore', ...
                    'CropHeight', 'CropWidth', 'Classification'});
            else
                O = vertcat(parts{:});
            end
            writetable(O, outFile);
            r.PerAnimal = curation.Export.perAnimal(r.Counts);
            r.Files.csv = string(outFile);
            curation.Export.writeReport(r, folder, name);
        end

        %% ======================================================================= helpers (public)
        function stem = imageStem(base, key)
            %IMAGESTEM  Export image stem of a source: '<base>_<key>' with every character other than
            %   letters, digits, '-' and '_' replaced by '_' (no dots: the trainers swap the suffix).
            stem = string(regexprep(char(base + "_" + key), '[^A-Za-z0-9_\-]', '_'));
        end

        function writeH5(file, img, s, facts, transpose)
            %WRITEH5  float32 '/data' of shape (H, W) as h5py reads it, chunked + deflate, with
            %   provenance attributes. (transpose = true writes the wrong orientation: tests only.)
            if nargin < 5, transpose = false; end
            if isfile(file), delete(file); end
            [H, W] = size(img);
            data = single(img).';
            dims = [W H];
            if transpose, data = single(img); dims = [H W]; end
            h5create(file, '/data', dims, 'Datatype', 'single', ...
                'ChunkSize', [min(256, dims(1)) min(256, dims(2))], 'Deflate', 4);
            h5write(file, '/data', data);
            if nargin >= 4 && ~isempty(s)
                h5writeatt(file, '/data', 'SourceId', char(s.SourceId));
                h5writeatt(file, '/data', 'ImageFile', char(s.ImageFile));
                h5writeatt(file, '/data', 'Page', double(s.Page));
                h5writeatt(file, '/data', 'Resize', double(facts.resize));
                h5writeatt(file, '/data', 'Facts', jsonencode(rmfield(facts, intersect(fieldnames(facts), ...
                    {'notes'}))));
            end
        end
    end

    %% ========================================================================== private helpers
    methods (Static, Access = private)

        function o = fill(opts, d)
            o = d;
            if ~isstruct(opts), return; end
            f = fieldnames(opts);
            for i = 1:numel(f)
                if ~isfield(d, f{i})
                    error('curation:Export:badArgument', 'Unknown option "%s".', f{i});
                end
                o.(f{i}) = opts.(f{i});
            end
            if isfield(o, 'Sections'), o.Sections = string(o.Sections(:)); end
            if isfield(o, 'ValidationAnimals'), o.ValidationAnimals = string(o.ValidationAnimals(:)); end
        end

        function k = needKind(k)
            k = string(k);
            if ~isscalar(k) || ~ismember(k, ["pnn" "pv"])
                error('curation:Export:badArgument', 'opts.Kind must be "pnn" or "pv" (one model per kind).');
            end
        end

        function index = asIndex(index)
            if isa(index, 'curation.ProjectIndex'), return; end
            if (ischar(index) || isstring(index)) && isfolder(index)
                index = curation.ProjectIndex.build(char(index));
                return;
            end
            error('curation:Export:badArgument', 'index must be a curation.ProjectIndex or a project folder.');
        end

        function root = prepareRoot(root, overwrite, ours)
            root = char(root);
            if ~isfolder(root), mkdir(root); end
            d = dir(root);
            d = d(~ismember({d.name}, {'.', '..'}));
            if isempty(d), return; end
            if ~overwrite
                error('curation:Export:exists', ['%s is not empty (opts.Overwrite = true replaces an earlier ' ...
                    'export there).'], root);
            end
            for i = 1:numel(ours)
                p = fullfile(root, ours{i});
                if isfolder(p), rmdir(p, 's'); elseif isfile(p), delete(p); end
            end
        end

        function removeData(root)
            for d = {'train', 'validation', '.staging'}
                p = fullfile(root, d{1});
                if isfolder(p), rmdir(p, 's'); end
            end
        end

        function r = newReport(stage, o, outRoot)
            oo = o;
            if isfield(oo, 'Python'), oo = rmfield(oo, 'Python'); end
            if isfield(oo, 'TransposeForTest'), oo = rmfield(oo, 'TransposeForTest'); end
            e = strings(0, 1);
            r = struct('Stage', string(stage), 'Kind', string(o.Kind), 'OutRoot', string(outRoot), ...
                'Created', string(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss')), 'Status', "ok", ...
                'Options', oo, ...
                'Counts', table(e, e, e, e, zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), 'VariableNames', ...
                {'Section', 'Animal', 'Split', 'Image', 'Good', 'Uncertain', 'Bad', 'Total'}), ...
                'PerAnimal', table(), ...
                'LeftOut', table(e, zeros(0, 1), 'VariableNames', {'Rule', 'Count'}), ...
                'LeftOutBySection', table(e, e, zeros(0, 1), 'VariableNames', {'Section', 'Rule', 'Count'}), ...
                'Skipped', table(e, e, e, 'VariableNames', {'Section', 'SourceId', 'Reason'}), ...
                'Images', table(e, e, e, e, e, zeros(0, 1), zeros(0, 1), zeros(0, 1), e, e, e, e, ...
                'VariableNames', {'imgName', 'SourceId', 'Section', 'Animal', 'Split', 'Height', 'Width', ...
                'Resize', 'FactsSource', 'Assumed', 'Inferred', 'Notes'}), ...
                'Commands', struct(), 'Files', struct(), 'Notes', strings(1, 0));
        end

        function [S, T] = selectSources(index, kind, sections)
            S = index.Sources(index.Sources.Kind == string(kind), :);
            if ~isempty(sections)
                m = ismember(S.Section, sections) | ismember(S.Base, sections) | ismember(S.SourceId, sections);
                S = S(m, :);
            end
            T = index.table(kind);
        end

        function [J, cache] = json(path, cache)
            if isKey(cache, path)
                J = cache(path);
                return;
            end
            J = struct();
            if isfile(path)
                try
                    J = jsondecode(fileread(path));
                catch
                    J = struct();
                end
            end
            cache(path) = J;
        end

        function rec = record(J, key)
            rec = struct();
            if isstruct(J) && isfield(J, 'sources') && isstruct(J.sources) && isfield(J.sources, char(key))
                rec = J.sources.(char(key));
            end
        end

        function tf = flag(rec, name)
            tf = isstruct(rec) && isfield(rec, name) && ~isempty(rec.(name)) && isequal(logical(rec.(name)), true);
        end

        function R = excludeRegions(J, key)
            R = curation.Regions.normalize([]);
            if isstruct(J) && isfield(J, 'regions')
                try R = curation.Regions.normalize(J.regions); catch, end
            end
            if isempty(R), return; end
            R = R([R.kind]' == "exclude" & ([R.scope]' == "image" | [R.scope]' == string(key)));
        end

        function exc = excludedNow(R, J, key)
            % the store's flag, or inside an exclusion region of the curation JSON now (another
            % channel may have drawn an image-scope region while this source was closed)
            exc = logical(R.Excluded);
            regs = curation.Export.excludeRegions(J, key);
            if ~isempty(regs) && height(R) > 0
                exc = exc | curation.Regions.excluded(regs, [R.X R.Y], string(key));
            end
        end

        function [keep, why] = stage2Rows(R, J, key, includeFlagged)
            n = height(R);
            why = strings(n, 1);
            src = R.LabelSource;
            audit = curation.Audit.exportExclusionMask(R);
            exc = curation.Export.excludedNow(R, J, key);
            rules = { ...
                R.State == "merged",                          "merged duplicate"; ...
                R.State ~= "active",                          "stale"; ...
                audit,                                        "audit evidence (holdout/reject-audit/catch)"; ...
                exc,                                          "inside an exclusion region"; ...
                src == "auto",                                "auto label"; ...
                src == "legacy-resolver",                     "legacy-resolver label"; ...
                ~R.Reviewed,                                  "not reviewed"; ...
                ~ismember(R.Label, ["Good" "Bad" "Uncertain"]), "no label"; ...
                R.Flag ~= "" & ~includeFlagged,               "flagged"; ...
                ~ismember(src, curation.Store.KEEP_SOURCES),  "other label source"};
            for k = 1:size(rules, 1)
                m = rules{k, 1} & why == "";
                why(m) = rules{k, 2};
            end
            keep = why == "";
        end

        function [pos, ign, why] = stage1Rows(R, J, key, uncertainIsCell)
            % pos: positives; ign: rows to paint out; why: one word per row ("positive",
            % "background", or the reason it is neither)
            n = height(R);
            why = strings(n, 1);
            act = R.State == "active";
            audit = curation.Audit.exportExclusionMask(R);
            exc = curation.Export.excludedNow(R, J, key);
            person = ismember(R.LabelSource, curation.Store.KEEP_SOURCES) & R.Reviewed;
            cellLike = R.Label == "Good" | (R.Label == "Uncertain" & uncertainIsCell);
            why(~act & R.State == "merged") = "merged duplicate";
            why(~act & why == "") = "stale";
            why(act & exc) = "inside an exclusion region (painted)";
            free = act & ~exc;
            why(free & audit) = "audit evidence (painted)";
            free = free & ~audit;
            why(free & person & cellLike & R.Flag == "") = "positive";
            why(free & person & cellLike & R.Flag ~= "") = "flagged (painted)";
            why(free & person & R.Label == "Uncertain" & ~uncertainIsCell) = "Uncertain, not a cell here (painted)";
            why(free & why == "" & R.Label == "Bad") = "background";             % person or auto Bad
            why(free & why == "" & ~R.Reviewed & R.Label == "") = "background";   % unreviewed
            why(free & why == "" & R.LabelSource == "legacy-resolver") = "legacy-resolver label (painted)";
            why(free & why == "") = "other (painted)";
            pos = why == "positive";
            ign = endsWith(why, "(painted)") & ~startsWith(why, "inside an exclusion region");
        end

        function [facts, frep] = factsOf(s, assume)
            det = struct();
            try
                mf = CellDatasetManifest.forBase(char(s.Folder), char(s.Base));
                src = mf.source(char(s.Key));
                if isstruct(src) && isfield(src, 'stages') && isfield(src.stages, 'detection') ...
                        && isstruct(src.stages.detection)
                    det = src.stages.detection;
                end
            catch
            end
            locs = char(s.LocsFile);
            resized = regexprep(locs, '_locs\.csv$', '_locs_resized.csv', 'ignorecase');
            if ~isfile(resized), resized = ''; end
            [facts, frep] = CellToolkit.modelInputFactsFor(det, char(s.ImageFile), double(s.Page), ...
                locs, resized, struct('Assume', assume));
        end

        function [img, ok, msg] = modelImage(s, facts)
            img = []; ok = false; msg = "";
            f = char(s.ImageFile);
            if isempty(f) || ~isfile(f)
                msg = "image not found: " + string(f);
                return;
            end
            try
                img = CellToolkit.modelInputFromFile(f, double(s.Page), facts);
            catch ME
                msg = "model input could not be made: " + string(ME.message);
                return;
            end
            if size(img, 3) ~= 1
                msg = "not a single-channel page";
                return;
            end
            ok = true;
        end

        function um = modelUm(facts)
            um = CellToolkit.TRAIN_UM_PER_PIXEL;
            if isfinite(facts.srcUmPerPixel) && facts.resize > 0
                um = facts.srcUmPerPixel / facts.resize;
            end
        end

        function mask = paintDisk(mask, cx, cy, rad)
            [H, W] = size(mask);
            c0 = max(1, floor(cx - rad)); c1 = min(W, ceil(cx + rad));
            r0 = max(1, floor(cy - rad)); r1 = min(H, ceil(cy + rad));
            if c0 > c1 || r0 > r1, return; end
            [cc, rr] = meshgrid(c0:c1, r0:r1);
            mask(r0:r1, c0:c1) = mask(r0:r1, c0:c1) | ((cc - cx) .^ 2 + (rr - cy) .^ 2 <= rad ^ 2);
        end

        function [valAnimals, same, note] = splitAnimals(animal, o)
            animals = unique(animal);
            same = false; note = "";
            if ~isempty(o.ValidationAnimals)
                valAnimals = intersect(string(o.ValidationAnimals), animals);
                if isempty(valAnimals)
                    error('curation:Export:badArgument', 'None of opts.ValidationAnimals has exportable rows.');
                end
                if numel(valAnimals) == numel(animals)
                    error('curation:Export:badArgument', 'opts.ValidationAnimals leaves no animal for training.');
                end
                note = "validation animals given: " + strjoin(valAnimals, ", ");
                return;
            end
            if numel(animals) < 2
                if o.AllowSameValidation
                    valAnimals = strings(0, 1); same = true;
                    note = "one animal (" + strjoin(animals, ", ") + "): validation = training data";
                    return;
                end
                error('curation:Export:oneAnimal', ['All exportable rows come from one animal (%s): there ' ...
                    'is no animal to validate on. Label sections of another animal, or set ' ...
                    'opts.AllowSameValidation = true to validate on the training data.'], strjoin(animals, ', '));
            end
            rs = RandStream('mt19937ar', 'Seed', o.SplitSeed);
            order = animals(randperm(rs, numel(animals)));
            n = numel(animal);
            valAnimals = strings(0, 1);
            got = 0;
            for a = order'
                if numel(valAnimals) >= numel(animals) - 1, break; end
                if got >= o.ValidationFraction * n, break; end
                valAnimals(end + 1, 1) = a; %#ok<AGROW>
                got = got + nnz(animal == a);
            end
            note = sprintf("validation animals (seed %d, >= %.0f%% of rows): %s", o.SplitSeed, ...
                100 * o.ValidationFraction, strjoin(valAnimals, ", "));
        end

        function stem = uniqueStem(name, used)
            stem = curation.Export.imageStem(name, "");
            stem = regexprep(stem, '_$', '');
            base = stem;
            k = 1;
            while any(used == stem)
                k = k + 1;
                stem = base + "_" + k;
            end
        end

        function r = tally(r, s, why)
            why = why(why ~= "");
            if isempty(why), return; end
            [u, ~, j] = unique(why);
            c = accumarray(j, 1);
            for k = 1:numel(u)
                i = find(r.LeftOut.Rule == u(k), 1);
                if isempty(i)
                    r.LeftOut(end + 1, :) = {u(k), c(k)};
                else
                    r.LeftOut.Count(i) = r.LeftOut.Count(i) + c(k);
                end
                r.LeftOutBySection(end + 1, :) = {s.Section + " | " + s.Key, u(k), c(k)};
            end
        end

        function r = addImage(r, p, stem, split, extra)
            w = warning('off', 'MATLAB:table:RowsAddedExistingVars');   % extra variables set below
            c = onCleanup(@() warning(w));
            fr = p.frep;
            notes = strjoin(fr.notes, "; ");
            if isfield(p, 'size'), sz = p.size; else, sz = [size(p.img, 1) size(p.img, 2)]; end
            r.Images(end + 1, {'imgName', 'SourceId', 'Section', 'Animal', 'Split', 'Height', 'Width', 'Resize', ...
                'FactsSource', 'Assumed', 'Inferred', 'Notes'}) = {stem, p.s.SourceId, p.s.Section, p.s.Animal, ...
                split, sz(1), sz(2), p.facts.resize, p.facts.source, strjoin(fr.assumed, ", "), ...
                strjoin(fr.inferred, ", "), notes};
            f = fieldnames(extra);
            for k = 1:numel(f)
                r.Images.(f{k})(end) = extra.(f{k});
            end
        end

        function r = countsStage2(r, tables, valAnimals, same)
            for sp = ["train" "validation"]
                if isempty(tables.(char(sp))), continue; end
                P = tables.(char(sp)){1};
                [g, sec, img] = findgroups(P.Section, P.imgName);
                for k = 1:max(g)
                    m = g == k;
                    an = P.Animal(find(m, 1));
                    r.Counts(end + 1, :) = {sec(k), an, sp, img(k), nnz(m & P.Label == "Good"), ...
                        nnz(m & P.Label == "Uncertain"), nnz(m & P.Label == "Bad"), nnz(m)};
                end
            end
            r.PerAnimal = curation.Export.perAnimal(r.Counts);
            r.Split = struct('ValidationAnimals', valAnimals(:)', 'SameAsTraining', same);
        end

        function A = perAnimal(C)
            if isempty(C)
                A = table();
                return;
            end
            [g, an, sp] = findgroups(C.Animal, C.Split);
            A = table(an, sp, splitapply(@sum, C.Good, g), splitapply(@sum, C.Uncertain, g), ...
                splitapply(@sum, C.Bad, g), splitapply(@sum, C.Total, g), splitapply(@numel, C.Section, g), ...
                'VariableNames', {'Animal', 'Split', 'Good', 'Uncertain', 'Bad', 'Total', 'Images'});
        end

        function c = commands(stage, outRoot, o)
            c = struct();
            py = [];
            if isfield(o, 'Python'), py = o.Python; end
            try
                if stage == "stage2"
                    cmd = curation.Trainer.stage2Command(outRoot, struct('Kind', o.Kind, 'Python', py));
                    c.stage2 = cmd.Line;
                    c.stage2WorkingDir = string(cmd.WorkingDir);
                else
                    cmd = curation.Trainer.stage1Command(outRoot, struct('Kind', o.Kind, 'Python', py));
                    c.stage1 = cmd.Line;
                    c.stage1WorkingDir = string(cmd.WorkingDir);
                end
            catch ME
                c.error = string(ME.message);
            end
        end

        function writeReport(r, folder, name)
            if isempty(name)
                jf = fullfile(folder, curation.Export.REPORT);
                tf = fullfile(folder, curation.Export.SUMMARY);
            else
                jf = fullfile(folder, [name '_export_report.json']);
                tf = fullfile(folder, [name '_export_summary.txt']);
            end
            J = r;
            for f = fieldnames(J)'
                v = J.(f{1});
                if istable(v)
                    J.(f{1}) = table2struct(v);
                end
            end
            fid = fopen(jf, 'w', 'n', 'UTF-8');
            if fid > 0
                fwrite(fid, jsonencode(J, 'PrettyPrint', true), 'char');
                fclose(fid);
            end
            fid = fopen(tf, 'w', 'n', 'UTF-8');
            if fid > 0
                fwrite(fid, char(strjoin(curation.Export.summaryLines(r), newline) + newline), 'char');
                fclose(fid);
            end
        end

        function L = summaryLines(r)
            L = strings(0, 1);
            L(end + 1, 1) = sprintf("Curated export: %s, kind %s, %s", r.Stage, r.Kind, r.Created);
            L(end + 1, 1) = "Folder: " + r.OutRoot;
            L(end + 1, 1) = "Status: " + r.Status;
            if ~isempty(r.Notes), L = [L; "Notes:"; "  " + r.Notes(:)]; end
            if ~isempty(r.Counts)
                L(end + 1, 1) = "";
                if r.Stage == "stage1"
                    L(end + 1, 1) = "Counts per image (positives Good / Uncertain, background Bad, positives total):";
                else
                    L(end + 1, 1) = "Counts per section (Good / Uncertain / Bad / total):";
                end
                for i = 1:height(r.Counts)
                    c = r.Counts(i, :);
                    L(end + 1, 1) = sprintf("  %-10s %-8s %-40s %5d %5d %5d %6d", c.Split, c.Animal, c.Section, ...
                        c.Good, c.Uncertain, c.Bad, c.Total); %#ok<AGROW>
                end
            end
            if ~isempty(r.PerAnimal) && height(r.PerAnimal) > 0
                L(end + 1, 1) = "Per animal:";
                for i = 1:height(r.PerAnimal)
                    a = r.PerAnimal(i, :);
                    L(end + 1, 1) = sprintf("  %-10s %-8s Good %d, Uncertain %d, Bad %d, total %d, images %d", ...
                        a.Split, a.Animal, a.Good, a.Uncertain, a.Bad, a.Total, a.Images); %#ok<AGROW>
                end
            end
            if ~isempty(r.LeftOut)
                L(end + 1, 1) = "Left out, by rule:";
                for i = 1:height(r.LeftOut)
                    L(end + 1, 1) = sprintf("  %6d  %s", r.LeftOut.Count(i), r.LeftOut.Rule(i)); %#ok<AGROW>
                end
            end
            if ~isempty(r.Skipped)
                L(end + 1, 1) = "Sources skipped:";
                for i = 1:height(r.Skipped)
                    L(end + 1, 1) = "  " + r.Skipped.SourceId(i) + ": " + r.Skipped.Reason(i); %#ok<AGROW>
                end
            end
            if ~isempty(r.Images)
                L(end + 1, 1) = "Images (model input regenerated from the detection facts):";
                for i = 1:height(r.Images)
                    m = r.Images(i, :);
                    L(end + 1, 1) = sprintf("  %s  %dx%d  resize x%.4f  facts: %s; assumed: %s; inferred: %s%s", ...
                        m.imgName, m.Height, m.Width, m.Resize, m.FactsSource, ...
                        curation.Export.ternary(m.Assumed == "", "none", m.Assumed), ...
                        curation.Export.ternary(m.Inferred == "", "none", m.Inferred), ...
                        curation.Export.ternary(m.Notes == "", "", "; " + m.Notes)); %#ok<AGROW>
                end
            end
            f = fieldnames(r.Commands);
            if ~isempty(f)
                L(end + 1, 1) = "To train with it (from the repository root):";
                for i = 1:numel(f)
                    L(end + 1, 1) = "  " + string(r.Commands.(f{i})); %#ok<AGROW>
                end
            end
        end

        function h = md5(txt)
            d = java.security.MessageDigest.getInstance('MD5');
            b = typecast(d.digest(uint8(char(txt))), 'uint8');
            h = string(lower(sprintf('%02x', b)));
        end

        function v = ternary(c, a, b)
            if c, v = a; else, v = b; end
        end
    end
end
