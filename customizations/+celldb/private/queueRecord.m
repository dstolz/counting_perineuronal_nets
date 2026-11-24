function status = queueRecord(file)
%QUEUERECORD Put the provenance record FILE in the outbox (the work of celldb.enqueue); errors are raised.
%   status: "off" without the client, else labclient.Outbox.put's answer.

status = "off";
if ~celldb.capturing()
    return
end

% The file as written, never the struct the run still holds: the same text
% gives the same event, however often and from wherever it is enqueued.
rec = jsondecode(fileread(file));

inputs = labclient.Bundles.noItems();
for f = asList(rec.inputs)
    inputs(end + 1) = labclient.Bundles.item(string(f.path), Role = string(f.role), ...
        Kind = string(f.kind), Format = string(f.format), Sha256 = string(f.sha256), ...
        Snapshot = snapshotOf(f)); %#ok<AGROW>
end

outputs = labclient.Bundles.noItems();
for f = asList(rec.outputs)
    attributes = struct();
    if isfield(f, "replaces_sha256") && strlength(string(f.replaces_sha256)) > 0
        attributes.replaces_sha256 = string(f.replaces_sha256);
    end
    replaces = "";
    if isfield(f, "replaces_artifact_id") && strlength(string(f.replaces_artifact_id)) > 0
        replaces = string(f.replaces_artifact_id);   % the earlier file at this path: the database marks it replaced
    end
    outputs(end + 1) = labclient.Bundles.item(string(f.path), Role = string(f.role), ...
        Kind = string(f.kind), Format = string(f.format), Sha256 = string(f.sha256), ...
        ArtifactId = string(f.artifact_id), Replaces = replaces, Attributes = attributes, ...
        Snapshot = snapshotOf(f)); %#ok<AGROW>
end

environment = struct("app", string(rec.app), "code_text", string(rec.code_text), ...
    "matlab_release", string(rec.matlab_release), "host", string(rec.host), ...
    "os_user", string(rec.os_user), "metadata_source", rec.metadata_source);

detail = struct( ...
    "pipeline_name", string(rec.pipeline_name), ...
    "code_version", string(rec.code_version), ...
    "parameters_json", string(jsonencode(rec.parameters)), ...
    "environment_json", string(jsonencode(environment)), ...
    "started_at", string(rec.started_at), ...
    "finished_at", string(rec.finished_at), ...
    "status", string(rec.status));

attributes = struct("app", string(rec.app), "provenance_file", file);
if isfield(rec, "attributes") && isstruct(rec.attributes)
    for name = reshape(string(fieldnames(rec.attributes)), 1, [])
        if name ~= "provenance_file"
            attributes.(name) = rec.attributes.(name);   % the record's own app ("CellCurator") names the tool
        end
    end
end
if strlength(string(rec.error)) > 0
    attributes.error = string(rec.error);
end

b = labclient.Bundles.event( ...
    EventId = string(rec.run_id), ...
    EventType = "analysis", ...
    OccurredAt = string(rec.started_at), ...
    Detail = detail, ...
    Attributes = attributes, ...
    SubjectId = string(rec.subject_id), ...
    Inputs = inputs, ...
    Outputs = outputs, ...
    CapturedAt = string(rec.finished_at));   % the record's own time, so the bundle is the same bytes however often it is queued

b = labclient.Bundles.seal(b);
status = string(labclient.Outbox.put(b));
labclient.DB.outboxChanged();

end

function list = asList(x)
%ASLIST The decoded JSON list X as a row of structs (jsondecode gives a struct array or a cell).
if isempty(x)
    list = struct([]);
    list = reshape(list, 1, 0);
    return
end
if iscell(x)
    list = [x{:}];
else
    list = reshape(x, 1, []);
end
end

function s = snapshotOf(f)
bytes = f.bytes;
if isempty(bytes); bytes = NaN; end
s = struct("bytes", double(bytes), "mtime", string(f.mtime));
end
