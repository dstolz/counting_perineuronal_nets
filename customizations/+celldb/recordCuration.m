function rec = recordCuration(store, opts)
%CELLDB.RECORDCURATION Record that a source was curated: its provenance sidecar, and an event for the lab database.
%   rec = celldb.recordCuration(store)                        % after "mark source complete" wrote _final.csv
%   rec = celldb.recordCuration(store, Force = true)          % record even when nothing changed
%   rec = celldb.recordCuration(store, ManifestFacts = facts) % (tests) stand in for the manifest
%
% STORE is an open curation.Store whose snapshot (<stem>_curation.csv, so
% store.flush() first) and <stem>_final.csv (store.exportFinal) are on disk.
% This builds and finishes one celldb.Run, "counting_perineuronal_nets/curate":
%
%   subject     the section's SUBJ-ID-<n> from the image's file name
%               (celldb.parseSectionName), or none when the name does not fit
%   inputs      the section image (role "derived", kind "section_image", NOT
%               hashed: 50-60 MB, and what histology_analysis's roi_edit does
%               too; the database has no "image" role), the detector's locs
%               CSV, and <image stem>_roi.roi when it exists
%   outputs     <stem>_curation.csv and <stem>_final.csv (role "derived"),
%               each with its SHA-256; when an earlier record of this source
%               lists the same file with other bytes, the output names what it
%               replaces (replaces_sha256, replaces_artifact_id)
%   parameters  source_key, channel_kind (curation.Proposals.kindOf),
%               um_per_pixel, detector_tool/_model and scorer_tool/_model (the
%               manifest's stages.detection / stages.rescore, "" when not
%               recorded), assist_model_version (the most common ModelVersion
%               in the store, "" when none), reconcile_tolerance_um
%   attributes  app = "CellCurator", every field of store.counts(), complete,
%               reviewer, the parsed section fields (subject_number,
%               sample_id, protocol, series, section_id, hemisphere, stain,
%               z_plane, date_code, image_number, variant), image_key and
%               exclusion_regions (the regions that apply to this source)
%
% The sidecar is written whatever the state of the lab database (celldb.Run);
% the event is queued when this computer keeps records for it
% (celldb.capturing) and sent later, when the server answers. NO EVENT WHEN
% NOTHING CHANGED: when the latest earlier record of the same source (same
% image_key and source key, status succeeded) lists outputs with the same
% SHA-256s, nothing is written or queued (unless Force).
%
% Options
%   ManifestFacts  struct overriding what the manifest says; any of Image,
%                  DetectorTool, DetectorModel, ScorerTool, ScorerModel
%   Force          record even when nothing changed
%
% Returns a struct with
%   written   a sidecar was written
%   file      its path ("" when none was)
%   queued    the event is in the lab database client's outbox
%   runId     the record's id (the earlier record's, when nothing changed)
%   reason    one plain sentence for a status bar, e.g. "Recorded for the lab
%             database (will be sent when it is reachable)", "Nothing changed
%             since the last record", "Recorded locally; the lab database
%             client is not installed"
%   previousFile  the earlier sidecar when nothing changed, else ""
%
% Never an error and never blocks on the server: a problem warns
% (celldb:Provenance) and gives written = false. It never changes what the
% store or the app writes.
%
% See also CELLDB.RUN, CELLDB.PARSESECTIONNAME, CELLDB.STATUSTEXT, CURATION.STORE.

arguments
    store
    opts.ManifestFacts struct = struct()
    opts.Force (1,1) logical = false
end

rec = struct("written", false, "file", "", "queued", false, "runId", "", "reason", "", "previousFile", "");

try
    rec = record(store, opts, rec);
catch ME
    warning("celldb:Provenance", "The curation record was not kept: %s", ME.message);
    rec.written = false;
    rec.file = "";
    rec.queued = false;
    rec.reason = "The provenance record could not be made (" + string(ME.message) + ")";
end

end

function rec = record(store, opts, rec)
meta = store.Meta;
key = string(meta.Key);
stem = string(meta.Stem);
curationFile = string(store.Paths.csv);
finalFile = string(store.Paths.final);
locsFile = string(meta.LocsFile);

if strlength(curationFile) == 0 || ~isfile(curationFile)
    rec.reason = "Nothing recorded: the curation file is not on disk yet.";
    return
end

facts = manifestFacts(locsFile, key);
for f = reshape(string(fieldnames(opts.ManifestFacts)), 1, [])
    facts.(f) = string(opts.ManifestFacts.(f));
end

% the section: from the image's file name (the manifest's base when there is no image)
imageFile = facts.Image;
if strlength(imageFile) > 0
    [~, imageStem] = fileparts(imageFile);
else
    imageStem = string(meta.ManifestBase);
end
imageStem = string(imageStem);
section = celldb.parseSectionName(imageStem);
imageKey = section.ImageKey;
if imageKey == ""; imageKey = imageStem; end

outputs = curationFile;
if strlength(finalFile) > 0 && isfile(finalFile)
    outputs(end + 1, 1) = finalFile;
end
shas = strings(size(outputs));
for k = 1:numel(outputs)
    shas(k) = sha256File(outputs(k));
end

% what the last record of this source says
folders = [fullfile(fileparts(curationFile), ".provenance"), celldb.Run.fallbackFolder()];
prev = previousRecord(string(folders), imageKey, key);
if ~isempty(prev) && ~opts.Force && sameOutputs(prev, outputs, shas)
    rec.runId = prev.runId;
    rec.previousFile = prev.file;
    rec.reason = "Nothing changed since the last record";
    return
end

counts = store.counts();
regions = store.regions();
nExclude = 0;
if ~isempty(regions)
    scope = string({regions.scope});
    nExclude = nnz(string({regions.kind}) == "exclude" & (scope == "image" | scope == key));
end

parameters = struct( ...
    "source_key", key, ...
    "channel_kind", curation.Proposals.kindOf(key), ...
    "um_per_pixel", meta.UmPerPixel, ...
    "detector_tool", facts.DetectorTool, ...
    "detector_model", facts.DetectorModel, ...
    "scorer_tool", facts.ScorerTool, ...
    "scorer_model", facts.ScorerModel, ...
    "assist_model_version", assistVersion(store), ...
    "reconcile_tolerance_um", store.Options.TolUm);

attributes = struct("app", "CellCurator");
for f = reshape(string(fieldnames(counts)), 1, [])
    attributes.(f) = counts.(f);
end
attributes.complete = logical(meta.Complete);
attributes.reviewer = string(store.Reviewer);
attributes.source_key = key;
attributes.subject_number = section.SubjectNumber;
attributes.sample_id = section.SampleID;
attributes.protocol = section.Protocol;
attributes.series = section.Series;
attributes.section_id = section.SectionID;
attributes.hemisphere = section.Hemisphere;
attributes.stain = section.Stain;
attributes.z_plane = section.ZPlane;
attributes.date_code = section.DateCode;
attributes.image_number = section.ImageNumber;
attributes.variant = section.Variant;
attributes.image_key = imageKey;
attributes.exclusion_regions = nExclude;

run = celldb.Run("counting_perineuronal_nets/curate", Parameters = parameters, ...
    SubjectId = section.SubjectID, Attributes = attributes, ...
    MetadataSource = struct("kind", "file_name", "convention", ...
    "SUBJ-ID-<n><SampleID>_<Section>_<Hemi>_<Stain>_<Z>_<Date>_<ImageNumber>[_<variant>]", ...
    "parsed", section.ok));
if strlength(imageFile) > 0 && isfile(imageFile)
    run.input(imageFile, Role = "derived", Kind = "section_image", Hash = false);
    roi = fullfile(fileparts(imageFile), imageStem + "_roi.roi");
    if isfile(roi)
        run.input(roi, Role = "derived", Kind = "reference_roi");
    end
end
if strlength(locsFile) > 0 && isfile(locsFile)
    run.input(locsFile, Role = "derived", Kind = "detections_csv");
end
if ~isempty(prev)
    for k = 1:numel(outputs)
        j = find(prev.paths == lower(absolutePath(outputs(k))), 1);
        if ~isempty(j)
            run.replacing(outputs(k), prev.shas(j), prev.ids(j));
        end
    end
end
kinds = ["curation_csv"; "final_csv"];
for k = 1:numel(outputs)
    run.output(outputs(k), Role = "derived", Kind = kinds(k));
end
file = run.finish();

rec.runId = run.RunId;
rec.file = file;
rec.written = strlength(file) > 0;
if ~rec.written
    rec.reason = "The provenance record could not be written (see the warning)";
    return
end

queued = false;
try
    queued = celldb.capturing() && labclient.Outbox.stateOf(run.RunId) ~= "";
catch
end
rec.queued = queued;
if queued
    rec.reason = "Recorded for the lab database (will be sent when it is reachable)";
elseif celldb.available()
    if celldb.capturing()
        rec.reason = "Recorded locally; it could not be queued for the lab database yet (celldb.backfill will try again)";
    else
        rec.reason = "Recorded locally; the lab database is turned off on this computer";
    end
else
    [~, why] = celldb.available();
    if contains(why, "too old")
        rec.reason = "Recorded locally; the lab database client is too old";
    elseif contains(why, "CELLDB_NO_CLIENT")
        rec.reason = "Recorded locally; the lab database client is switched off by the environment";
    else
        rec.reason = "Recorded locally; the lab database client is not installed";
    end
end
end

function f = manifestFacts(locsFile, key)
%MANIFESTFACTS What the dataset's manifest says about this source: the image and the detector and scorer stages.
f = struct("Image", "", "DetectorTool", "", "DetectorModel", "", "ScorerTool", "", "ScorerModel", "");
try
    if strlength(locsFile) == 0 || ~isfile(locsFile) || exist("CellDatasetManifest", "class") ~= 8
        return
    end
    mf = CellDatasetManifest.forCsv(char(locsFile));
    f.Image = string(mf.imageForLocs(char(locsFile)));
    s = mf.source(char(key));
    if isstruct(s) && isfield(s, "stages") && isstruct(s.stages)
        [f.DetectorTool, f.DetectorModel] = stageFacts(s.stages, "detection");
        [f.ScorerTool, f.ScorerModel] = stageFacts(s.stages, "rescore");
    end
catch
end
end

function [tool, model] = stageFacts(stages, name)
tool = "";
model = "";
if isfield(stages, name) && isstruct(stages.(name))
    st = stages.(name);
    if isfield(st, "tool") && ~isempty(st.tool); tool = string(st.tool); end
    if isfield(st, "model") && ~isempty(st.model); model = string(st.model); end
end
end

function v = assistVersion(store)
%ASSISTVERSION The most common non-empty ModelVersion among the store's rows ("" when none).
v = "";
try
    mv = string(store.get('ModelVersion'));
    mv = mv(~ismissing(mv) & strlength(mv) > 0);
    if ~isempty(mv)
        [u, ~, g] = unique(mv);
        [~, k] = max(accumarray(g, 1));
        v = u(k);
    end
catch
end
end

function prev = previousRecord(folders, imageKey, key)
%PREVIOUSRECORD The latest successful earlier record of this source: file, runId, and its outputs (paths, shas, ids); [] if none.
prev = [];
best = "";
for folder = reshape(folders, 1, [])
    if ~isfolder(folder); continue; end
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
            if string(r.attributes.image_key) ~= imageKey || string(r.parameters.source_key) ~= key
                continue
            end
            order = string(r.finished_at) + "|" + d(k).name;
            if order <= best; continue; end
            outs = asList(r.outputs);
            prev = struct("file", file, "runId", string(r.run_id), ...
                "paths", lower(reshape(string({outs.path}), [], 1)), ...
                "shas", reshape(string({outs.sha256}), [], 1), ...
                "ids", reshape(string({outs.artifact_id}), [], 1));
            best = order;
        catch
        end
    end
end
end

function tf = sameOutputs(prev, outputs, shas)
%SAMEOUTPUTS True when the earlier record lists exactly these files with exactly these SHA-256s.
mine = strings(size(outputs));
for k = 1:numel(outputs)
    mine(k) = lower(absolutePath(outputs(k)));
end
tf = numel(mine) == numel(prev.paths) && all(ismember(mine, prev.paths));
if ~tf; return; end
[~, a] = ismember(mine, prev.paths);
tf = all(prev.shas(a) == reshape(shas, [], 1)) && all(strlength(shas) > 0);
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
