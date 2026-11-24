classdef Run < handle
    %CELLDB.RUN What one curation step read and wrote, with which code and settings: its provenance record.
    %
    %   run = celldb.Run("counting_perineuronal_nets/curate", Parameters = p, SubjectId = "SUBJ-ID-1127");
    %   run.input(imageFile, Role = "derived", Kind = "section_image", Hash = false);
    %   run.output([curationCsv; finalCsv], Role = "derived", Kind = "curation_csv");
    %   run.finish();            % or run.fail(ME) when it did not
    %
    % FINISH writes the record beside the run's first output, in a .provenance
    % folder (<output folder>\.provenance\<time>_<step>_<id>.json, format
    % cellcuration-provenance/1: the fields of histology-provenance/1 plus
    % attributes, and per output replaces_artifact_id), whether or not the lab
    % database is set up, reachable or even installed: the record on disk is
    % the run's provenance, and the database is told of it from there. When this
    % computer keeps records for the database (celldb.capturing), the same record
    % goes to the lab database client's outbox (celldb.enqueue) and is sent when
    % the server answers; otherwise celldb.backfill sends it later.
    %
    % The record holds:
    %   run_id          a uuid, which becomes the event's id in the database
    %   pipeline_name   "counting_perineuronal_nets/<step>"
    %   subject_id      the one subject the run is about ("" for none)
    %   code_version    the commit, "-dirty" with uncommitted changes
    %                   (celldb.codeVersion); code_text, matlab_release
    %   host, os_user, started_at, finished_at, status, error
    %   parameters      the settings the run was made with (a JSON object)
    %   attributes      facts about the result, copied to the event's attributes
    %   metadata_source where the file names' metadata came from (a JSON object)
    %   inputs, outputs path, bytes, mtime, sha256, role, kind, format; an
    %                   output also has artifact_id (minted here, so the record
    %                   is the same however often it is sent), replaces_sha256
    %                   (the bytes it overwrote) and replaces_artifact_id (the
    %                   earlier output at that path, when known: replacing)
    %
    % Nothing here may change what the app computes or writes, or stop it:
    % every method catches its own errors and warns (celldb:Provenance)
    % instead. A file larger than MaxHashMB is recorded without its SHA-256.
    %
    % See also CELLDB.RECORDCURATION, CELLDB.ENQUEUE, CELLDB.BACKFILL.

    properties (Constant)
        Format = "cellcuration-provenance/1"
        App = "counting_perineuronal_nets"
        MaxHashMB = 512
    end

    properties (SetAccess = private)
        RunId (1,1) string = ""
        PipelineName (1,1) string = ""
        SubjectId (1,1) string = ""
        Parameters = struct()
        MetadataSource = struct()
        Attributes = struct()
        StartedAt (1,1) datetime = NaT("TimeZone", "local")
        Inputs struct = celldb.Run.noFiles()
        Outputs struct = celldb.Run.noFiles()
        SidecarFile (1,1) string = ""
        Finished (1,1) logical = false
    end

    properties (Access = private)
        Previous = []     % containers.Map path -> SHA-256 before the write (made in the constructor)
        PreviousId = []   % containers.Map path -> artifact_id of the earlier output there
    end

    methods
        function obj = Run(pipelineName, opts)
            %RUN Start the record of a run of PIPELINENAME ("counting_perineuronal_nets/<step>").
            arguments
                pipelineName (1,1) string
                opts.Parameters = struct()
                opts.SubjectId (1,1) string = ""
                opts.MetadataSource = struct()
                opts.Attributes = struct()
            end
            obj.RunId = newId();
            obj.PipelineName = pipelineName;
            obj.SubjectId = strtrim(opts.SubjectId);
            obj.Parameters = opts.Parameters;
            obj.MetadataSource = opts.MetadataSource;
            obj.Attributes = opts.Attributes;
            obj.StartedAt = datetime("now", "TimeZone", "local");
            obj.Previous = containers.Map("KeyType", "char", "ValueType", "char");
            obj.PreviousId = containers.Map("KeyType", "char", "ValueType", "char");
        end

        function input(obj, paths, opts)
            %INPUT Note files the run read, as they are now (size, time, SHA-256).
            %   Hash=false records only the size and time: for a large file
            %   read where a person is waiting (an image behind an ROI save).
            arguments
                obj
                paths string
                opts.Role (1,1) string = "derived"
                opts.Kind (1,1) string = ""
                opts.Hash (1,1) logical = true
            end
            try
                paths = unique(paths(strlength(paths) > 0 & ~ismissing(paths)), "stable");
                for p = reshape(paths, 1, [])
                    p = absolutePath(p); %#ok<FXSET>
                    if any(string({obj.Inputs.path}) == p); continue; end
                    obj.Inputs(end + 1) = celldb.Run.describe(p, opts.Role, opts.Kind, "", opts.Hash);
                end
            catch ME
                celldb.Run.warn(ME);
            end
        end

        function willWrite(obj, paths)
            %WILLWRITE Before a file is overwritten in place, note the bytes it holds now (replaces_sha256).
            arguments
                obj
                paths string
            end
            try
                for p = reshape(paths, 1, [])
                    if strlength(p) == 0 || ismissing(p); continue; end
                    p = absolutePath(p); %#ok<FXSET>
                    if isKey(obj.Previous, char(p)) || ~isfile(p)
                        continue
                    end
                    d = dir(p);
                    if d.bytes <= celldb.Run.MaxHashMB * 2^20
                        obj.Previous(char(p)) = char(sha256File(p));
                    end
                end
            catch ME
                celldb.Run.warn(ME);
            end
        end

        function replacing(obj, path, sha256, artifactId)
            %REPLACING Say the file at PATH held bytes SHA256 (artifact ARTIFACTID, "" if unknown) before this run wrote it.
            %   For a run that is recorded after its files were written, which
            %   knows the earlier bytes from the earlier record, not from
            %   willWrite. A different SHA-256 than the output has by then
            %   becomes the output's replaces_sha256 / replaces_artifact_id.
            arguments
                obj
                path (1,1) string
                sha256 (1,1) string
                artifactId (1,1) string = ""
            end
            try
                path = absolutePath(path);
                if strlength(sha256) > 0
                    obj.Previous(char(path)) = char(sha256);
                    obj.PreviousId(char(path)) = char(artifactId);
                end
            catch ME
                celldb.Run.warn(ME);
            end
        end

        function output(obj, paths, opts)
            %OUTPUT Note files the run wrote (described when the run finishes).
            arguments
                obj
                paths string
                opts.Role (1,1) string = "derived"
                opts.Kind (1,1) string = ""
            end
            try
                paths = unique(paths(strlength(paths) > 0 & ~ismissing(paths)), "stable");
                for p = reshape(paths, 1, [])
                    p = absolutePath(p); %#ok<FXSET>
                    if any(string({obj.Outputs.path}) == p); continue; end
                    f = celldb.Run.blank(p);
                    f.role = opts.Role;
                    f.kind = opts.Kind;
                    obj.Outputs(end + 1) = f;
                end
            catch ME
                celldb.Run.warn(ME);
            end
        end

        function file = finish(obj, opts)
            %FINISH Write the record (and put it in the outbox when the database is on here); its file.
            arguments
                obj
                opts.Status (1,1) string {mustBeMember(opts.Status, ["succeeded", "failed"])} = "succeeded"
                opts.Error (1,1) string = ""
            end
            file = "";
            if obj.Finished
                file = obj.SidecarFile;
                return
            end
            obj.Finished = true;
            try
                rec = obj.record(opts.Status, opts.Error);
                file = obj.writeRecord(rec);
                obj.SidecarFile = file;
            catch ME
                celldb.Run.warn(ME);
                return
            end
            try
                celldb.enqueue(file);
            catch ME
                celldb.Run.warn(ME);
            end
        end

        function file = fail(obj, ME)
            %FAIL Write the record of a run that stopped with error ME.
            file = obj.finish(Status = "failed", Error = string(ME.message));
        end
    end

    methods (Access = private)
        function rec = record(obj, status, err)
            outs = obj.Outputs;
            for k = 1:numel(outs)
                f = celldb.Run.describe(outs(k).path, outs(k).role, outs(k).kind, "", true);
                f.artifact_id = newId();
                if isKey(obj.Previous, char(outs(k).path))
                    before = string(obj.Previous(char(outs(k).path)));
                    if before ~= f.sha256
                        f.replaces_sha256 = before;
                        if isKey(obj.PreviousId, char(outs(k).path))
                            f.replaces_artifact_id = string(obj.PreviousId(char(outs(k).path)));
                        end
                    end
                end
                outs(k) = f;
            end
            [codeVersion, code] = celldb.codeVersion();
            rec = struct( ...
                "format", celldb.Run.Format, ...
                "run_id", obj.RunId, ...
                "app", celldb.Run.App, ...
                "pipeline_name", obj.PipelineName, ...
                "subject_id", obj.SubjectId, ...
                "code_version", codeVersion, ...
                "code_text", code.Text, ...
                "matlab_release", code.MatlabRelease, ...
                "host", celldb.Run.host(), ...
                "os_user", string(getenv("USERNAME")), ...
                "started_at", timeText(obj.StartedAt), ...
                "finished_at", timeText(datetime("now", "TimeZone", "local")), ...
                "status", status, ...
                "error", err, ...
                "parameters", celldb.Run.encodable(obj.Parameters), ...
                "attributes", celldb.Run.encodable(obj.Attributes), ...
                "metadata_source", celldb.Run.encodable(obj.MetadataSource), ...
                "inputs", {num2cell(obj.Inputs)}, ...
                "outputs", {num2cell(outs)});
        end

        function file = writeRecord(obj, rec)
            step = extractAfter(obj.PipelineName, "/");
            if ismissing(step) || step == ""; step = obj.PipelineName; end
            step = regexprep(step, "[^A-Za-z0-9_-]", "_");
            name = string(datetime("now", "Format", "yyyyMMdd'T'HHmmss")) + "_" + step + "_" + ...
                extractBefore(obj.RunId, 9) + ".json";
            text = string(jsonencode(rec, PrettyPrint = true));
            folders = strings(0, 1);
            if ~isempty(obj.Outputs)
                folders(end + 1) = fullfile(fileparts(obj.Outputs(1).path), ".provenance");
            end
            folders(end + 1) = celldb.Run.fallbackFolder();
            for f = reshape(folders, 1, [])
                candidate = string(fullfile(f, name));
                try
                    writeTextAtomic(candidate, text);
                    file = candidate;
                    return
                catch
                    % not writable: the next folder
                end
            end
            error("celldb:CannotWrite", "The provenance record of %s could not be written anywhere.", obj.PipelineName);
        end
    end

    methods (Static, Hidden)
        function f = noFiles()
            %NOFILES An empty list of file descriptions.
            f = struct("path", {}, "bytes", {}, "mtime", {}, "sha256", {}, "role", {}, ...
                "kind", {}, "format", {}, "artifact_id", {}, "replaces_sha256", {}, "replaces_artifact_id", {});
        end
    end

    methods (Static)
        function d = fallbackFolder()
            %FALLBACKFOLDER Where a record goes when its outputs' folder cannot take it.
            %   %LOCALAPPDATA%\counting_perineuronal_nets\provenance, or the folder
            %   the environment variable CELLDB_PROVENANCE_DIR names (tests).
            d = string(getenv("CELLDB_PROVENANCE_DIR"));
            if d ~= ""; return; end
            base = string(getenv("LOCALAPPDATA"));
            if base == ""; base = string(tempdir); end
            d = string(fullfile(base, "counting_perineuronal_nets", "provenance"));
        end
    end

    methods (Static, Access = private)
        function f = blank(p)
            f = struct("path", string(p), "bytes", NaN, "mtime", "", "sha256", "", "role", "", ...
                "kind", "", "format", "", "artifact_id", "", "replaces_sha256", "", "replaces_artifact_id", "");
        end

        function f = describe(p, role, kind, artifactId, hash)
            f = celldb.Run.blank(p);
            f.role = role;
            f.kind = kind;
            f.artifact_id = artifactId;
            [~, ~, ext] = fileparts(p);
            f.format = lower(erase(string(ext), "."));
            s = fileSnapshot(p);
            f.bytes = s.bytes;
            f.mtime = s.mtime;
            if hash && isfinite(s.bytes) && s.bytes <= celldb.Run.MaxHashMB * 2^20
                f.sha256 = sha256File(p);
            end
        end

        function v = encodable(v)
            %ENCODABLE V when jsonencode can write it; else a note saying what it was.
            try
                jsonencode(v);
            catch ME
                v = struct("not_recorded", "jsonencode could not write the " + class(v) + ...
                    ": " + string(ME.message));
            end
        end

        function h = host()
            h = string(getenv("COMPUTERNAME"));
            if h == ""; h = string(getenv("HOSTNAME")); end
        end

        function warn(ME)
            warning("celldb:Provenance", "The provenance record was not kept: %s", ME.message);
        end
    end
end
