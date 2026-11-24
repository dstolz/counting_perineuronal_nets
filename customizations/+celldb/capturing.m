function tf = capturing()
%CELLDB.CAPTURING True when this computer keeps records for the lab database (client here, turned on).
%   tf = celldb.capturing()
%
% The client's own answer (labclient.Sync.enabled: the setting Enabled, and
% the CarasLabDB class usable). False, never an error, without the client or
% when it is too old.
%
% See also CELLDB.AVAILABLE, CELLDB.ENQUEUE.

tf = false;
if ~celldb.available()
    return
end
try
    tf = labclient.Sync.enabled();
catch
    tf = false;
end
end
