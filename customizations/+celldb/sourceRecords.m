function R = sourceRecords(curationFiles, opts)
%CELLDB.SOURCERECORDS Where the lab database record of each curated source is: none, kept here, waiting, sent.
%   R = celldb.sourceRecords(curationFiles)
%   R = celldb.sourceRecords(curationFiles, Previous = R)   % only ask the outbox again (cheap)
%
% CURATIONFILES are the sources' <stem>_curation.csv paths ("" for a source
% that was never curated). For each, the latest provenance record that lists
% it as an output is looked for where celldb.Run writes them (the .provenance
% folder beside the file, by the file's name, so a dataset folder that was
% moved or is seen through another drive letter still matches; and the
% fallback folder, by the file's path), and this computer's outbox is asked
% where that record is. Only files are read: no server is asked, nothing
% waits, and it works the same without the lab database client.
%
% R is a struct array of the size of CURATIONFILES with
%   state     "none"      no record: the source was never marked complete
%                         (celldb.recordCuration runs at Mark source complete)
%             "local"     a record is kept beside the files, and this
%                         computer's outbox does not hold it: the client is
%                         not installed or turned off here, or the record was
%                         made on another computer (celldb.backfill queues it)
%             "queued"    in the outbox, waiting to be sent
%             "sent"      sent to the lab database from this computer
%             "held"      waits for a person (a subject to assign, ...)
%             "failed"    the database refused it
%             "discarded" put aside by a person, never to be sent
%   current   true when the record describes the curation files as they are
%             now (same size and time, else same SHA-256); false when they
%             changed since (curation went on after the record) or are gone
%   text      a few words for a table cell, e.g. "sent", "waiting to be sent",
%             "kept here (not queued)", "sent (changed since)", "" for none
%   detail    one sentence for a tooltip
%   note      why it is held or failed ("" otherwise)
%   runId, file, recordedAt, subjectId   of the record ("" when none)
%
% With PREVIOUS (an earlier answer for the same files) the records are not
% read again: only the outbox is asked where each one is, which is what
% changes while records are being sent.
%
% Never an error: a record or folder that cannot be read counts as not there.
%
% See also CELLDB.RECORDCURATION, CELLDB.BACKFILL, CELLDB.STATUSTEXT.

arguments
    curationFiles string
    opts.Previous struct = struct([])
end

R = repmat(blank(), size(curationFiles));
if isempty(curationFiles)
    return
end

client = false;
try
    client = celldb.available();
catch
end

if ~isempty(opts.Previous) && numel(opts.Previous) == numel(curationFiles) ...
        && all(isfield(opts.Previous, fieldnames(R)))
    R = reshape(opts.Previous, size(curationFiles));
    for k = 1:numel(R)
        if R(k).runId ~= ""
            R(k) = describe(R(k), client);
        end
    end
    return
end

known = containers.Map("KeyType", "char", "ValueType", "any");   % folder -> its curate records
fallback = "";
try
    fallback = celldb.Run.fallbackFolder();
catch
end
for k = 1:numel(curationFiles)
    file = curationFiles(k);
    try
        if ismissing(file) || strlength(file) == 0
            continue
        end
        file = absolutePath(file);
        [folder, name, ext] = fileparts(file);
        best = [];
        beside = recordsIn(known, fullfile(folder, ".provenance"));
        for r = beside
            if any(r.names == lower(name + ext)) && (isempty(best) || r.order > best.order)
                best = r;
            end
        end
        if isempty(best) && fallback ~= ""
            for r = recordsIn(known, fallback)
                if any(r.paths == lower(file)) && (isempty(best) || r.order > best.order)
                    best = r;
                end
            end
        end
        if isempty(best)
            continue
        end
        R(k).runId = best.runId;
        R(k).file = best.file;
        R(k).recordedAt = best.finishedAt;
        R(k).subjectId = best.subjectId;
        R(k).current = isCurrent(best, folder);
        R(k) = describe(R(k), client);
    catch
        R(k) = blank();
    end
end

end

function r = blank()
r = struct("state", "none", "current", false, "text", "", ...
    "detail", "No lab database record: one is made when the source is marked complete in Cell Curator.", ...
    "note", "", "runId", "", "file", "", "recordedAt", "", "subjectId", "");
end

function list = recordsIn(known, folder)
%RECORDSIN The successful curate records of FOLDER (read once per call): a struct row.
key = char(lower(folder));
if isKey(known, key)
    list = known(key);
    return
end
list = struct("file", {}, "runId", {}, "finishedAt", {}, "subjectId", {}, "order", {}, ...
    "names", {}, "paths", {}, "outputs", {});
if isfolder(folder)
    d = dir(fullfile(folder, "*_curate_*.json"));
    for k = 1:numel(d)
        file = string(fullfile(d(k).folder, d(k).name));
        try
            r = jsondecode(fileread(file));
            if ~isstruct(r) || ~isfield(r, "format") || string(r.format) ~= celldb.Run.Format ...
                    || string(r.pipeline_name) ~= "counting_perineuronal_nets/curate" ...
                    || string(r.status) ~= "succeeded"
                continue
            end
            outs = asList(r.outputs);
            if isempty(outs)
                continue
            end
            paths = lower(reshape(string({outs.path}), 1, []));
            [~, n, e] = fileparts(paths);
            list(end + 1) = struct("file", file, "runId", string(r.run_id), ...
                "finishedAt", string(r.finished_at), "subjectId", string(r.subject_id), ...
                "order", string(r.finished_at) + "|" + d(k).name, ...
                "names", n + e, "paths", paths, "outputs", outs); %#ok<AGROW>
        catch
        end
    end
end
known(key) = list; %#ok<NASGU> (a handle: the caller sees it)
end

function tf = isCurrent(rec, folder)
%ISCURRENT True when every output the record lists is in FOLDER with the bytes the record names.
tf = false;
outs = rec.outputs;
for k = 1:numel(outs)
    file = fullfile(folder, rec.names(k));
    if ~isfile(file)
        return
    end
    now = fileSnapshot(file);
    bytes = outs(k).bytes;
    if isempty(bytes); bytes = NaN; end
    if now.bytes ~= double(bytes)
        return
    end
    if now.mtime == string(outs(k).mtime)
        continue            % same size and time: the same file
    end
    sha = string(outs(k).sha256);
    if strlength(sha) == 0 || sha256File(file) ~= sha
        return
    end
end
tf = true;
end

function r = describe(r, client)
%DESCRIBE Ask the outbox where record R is, and word its state.
state = "";
note = "";
if client
    try
        state = string(labclient.Outbox.stateOf(r.runId));
        if any(state == ["held" "failed"])
            note = string(labclient.Outbox.note(r.runId, state).reason);
        end
    catch
        state = "";
    end
end
when = extractBefore(r.recordedAt + "          ", 11);
when = strtrim(when);
switch state
    case {"pending", "claimed"}
        r.state = "queued";
        r.text = "waiting to be sent";
        r.detail = "The record of " + when + " is in this computer's outbox and is sent when the lab database answers.";
    case "done"
        r.state = "sent";
        r.text = "sent";
        r.detail = "The record of " + when + " was sent to the lab database from this computer.";
    case "held"
        r.state = "held";
        r.text = "needs you";
        r.detail = "The record of " + when + " waits for you in the Database window" + reason(note) + ".";
    case "failed"
        r.state = "failed";
        r.text = "refused";
        r.detail = "The lab database refused the record of " + when + reason(note) + ". See the Database window.";
    case "discarded"
        r.state = "discarded";
        r.text = "discarded";
        r.detail = "The record of " + when + " was put aside in the Database window and is never sent.";
    otherwise
        r.state = "local";
        r.text = "kept here (not queued)";
        if client
            r.detail = "The record of " + when + " is kept beside the files and is not in this computer's outbox " + ...
                "(the database was turned off here then, or it was made on another computer). Queue records puts it there.";
        else
            r.detail = "The record of " + when + " is kept beside the files. The lab database client is not usable " + ...
                "on this computer, so nothing is sent from here.";
        end
end
r.note = note;
if ~r.current
    r.text = r.text + " (changed since)";
    r.detail = r.detail + " The curation files changed after it was made: marking the source complete again records the new state.";
end
end

function t = reason(note)
t = "";
if strlength(note) > 0
    t = ": " + regexprep(note, "[.\s]+$", "");
end
end

function list = asList(x)
if isempty(x)
    list = struct([]);
elseif iscell(x)
    list = [x{:}];
else
    list = reshape(x, 1, []);
end
end
