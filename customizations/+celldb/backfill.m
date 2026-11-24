function r = backfill(roots)
%CELLDB.BACKFILL Put the provenance records that never reached the outbox into it.
%   r = celldb.backfill(roots)
%   r = celldb.backfill()          % only the records kept in the fallback folder
%
% A run writes its provenance record beside its outputs whatever the state of
% the lab database (celldb.Run). It reaches the outbox at once only when this
% computer was keeping records for the database then (celldb.capturing): a
% run made with the database turned off, or before the client was installed,
% or on a computer without it, left its record on disk only. This finds those
% records, under the folders ROOTS (every .provenance folder at any depth)
% and in the fallback folder (celldb.Run.fallbackFolder), and puts each one
% the outbox does not hold yet, in any state, into it (celldb.enqueue). A
% record sent before is not sent again; a record sent twice is written once by
% the database anyway (its id and digest).
%
% Returns
%   r: struct with found (records seen), queued (put in the outbox now),
%      already (in the outbox before), failed (could not be read or queued),
%      problems (one line per failure) and message.
%
% See also CELLDB.RUN, CELLDB.ENQUEUE.

arguments
    roots string = strings(0, 1)
end

r = struct("found", 0, "queued", 0, "already", 0, "failed", 0, ...
    "problems", strings(0, 1), "message", "");

if ~celldb.capturing()
    r.message = "This computer keeps no records for the lab database (the client is not installed, " + ...
        "or the database is turned off here), so nothing was queued.";
    return
end

try
    files = strings(0, 1);
    folders = [reshape(roots, [], 1); celldb.Run.fallbackFolder()];
    for k = 1:numel(folders)
        f = folders(k);
        if ~isfolder(f); continue; end
        if k == numel(folders)
            d = dir(fullfile(f, "*.json"));
        else
            d = dir(fullfile(f, "**", ".provenance", "*.json"));
        end
        files = [files; string(fullfile({d.folder}, {d.name}))']; %#ok<AGROW>
    end
    files = unique(files, "stable");

    for file = reshape(files, 1, [])
        try
            rec = jsondecode(fileread(file));
            if ~isstruct(rec) || ~isfield(rec, "format") || string(rec.format) ~= celldb.Run.Format
                continue
            end
            r.found = r.found + 1;
            if labclient.Outbox.stateOf(string(rec.run_id)) ~= ""
                r.already = r.already + 1;
                continue
            end
            queueRecord(file);
            r.queued = r.queued + 1;
        catch ME
            r.failed = r.failed + 1;
            r.problems(end + 1, 1) = file + ": " + string(ME.message);
        end
    end

    r.message = sprintf("%d provenance record(s) found: %d queued now, %d already in the outbox, %d failed.", ...
        r.found, r.queued, r.already, r.failed);
catch ME
    warning("celldb:Provenance", "Backfilling the provenance records failed: %s", ME.message);
    r.failed = r.failed + 1;
    r.problems(end + 1, 1) = string(ME.message);
    r.message = "Backfilling stopped: " + string(ME.message);
end

end
