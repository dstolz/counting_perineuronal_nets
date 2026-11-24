function status = enqueue(file)
%CELLDB.ENQUEUE Put a run's provenance record in the lab database client's outbox, to be sent when it can be.
%   status = celldb.enqueue(file)         % the record file celldb.Run wrote
%
% The record becomes one analysis event (labclient.Bundles.event) whose id is
% the run's id: its inputs and outputs are the files the run read and wrote
% (with their SHA-256, so the database can tell copies and earlier versions
% apart), the subject is the run's one subject or none, and the code version,
% parameters and environment are the record's. The event is always built from
% the record file as written, so a record put in the outbox now and one put
% there later by celldb.backfill are the same bytes, and the database writes
% it once whichever arrives (it keeps the record's digest with the event).
%
% Returns
%   status: "off" when this computer keeps no records for the database
%       (celldb.capturing), else labclient.Outbox.put's answer: "added",
%       "unchanged" or "replaced"; "failed" when the record could not be
%       read or queued (celldb:Provenance warns, nothing is raised: the
%       record stays on disk, and celldb.backfill queues it later). Never
%       blocks on the server: it only writes the outbox folder.
%
% See also CELLDB.RUN, CELLDB.BACKFILL, LABCLIENT.BUNDLES.

arguments
    file (1,1) string
end

status = "off";
try
    status = string(queueRecord(file));
catch ME
    status = "failed";
    warning("celldb:Provenance", "The provenance record %s was not queued for the lab database: %s", file, ME.message);
end

end
