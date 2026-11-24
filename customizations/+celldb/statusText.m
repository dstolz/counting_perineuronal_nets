function text = statusText()
%CELLDB.STATUSTEXT One plain sentence on the lab database's state here, for a status bar or a tooltip.
%   text = celldb.statusText()
%
% Says, from what this computer already knows (celldb.available, the client's
% settings, labclient.DB.status and labclient.Outbox.counts: no server is
% asked, nothing waits):
%   the client is not installed / too old / switched off by the environment
%   (and what to do), it is installed but turned off here, how many records
%   wait to be sent (and how many need a person), or that it is connected
%   and nothing waits. Never an error: a failure gives a sentence saying the
%   state is not known.
%
% See also CELLDB.AVAILABLE, CELLDB.CAPTURING, CELLDB.ADDLAMP.

try
    [ok, why] = celldb.available();
    if ~ok
        text = "Lab database: " + why + " Curation works the same; each completed source keeps its provenance record beside its files.";
        return
    end
    if ~celldb.capturing()
        text = "Lab database: the client is installed but turned off on this computer, so completed sources keep their " + ...
            "provenance record beside their files only (celldb.backfill queues them later).";
        return
    end
    c = labclient.Outbox.counts();
    waiting = c.pending + c.claimed;
    needYou = c.held + c.failed;
    st = labclient.DB.status();
    state = lower(string(st.State));
    if needYou > 0
        text = sprintf("Lab database: %d record(s) need you (see the Database window)", needYou);
        if waiting > 0
            text = text + sprintf(", %d waiting to be sent", waiting);
        end
        text = text + ".";
    elseif waiting > 0
        text = sprintf("Lab database: %d record(s) waiting to be sent (%s).", waiting, describe(state));
    else
        text = "Lab database: " + describe(state) + ", nothing waiting.";
    end
catch ME
    text = "Lab database: its state is not known (" + string(ME.message) + ").";
end
end

function s = describe(state)
switch state
    case "connected"
        s = "connected";
    case "offline"
        s = "the server is out of reach; they are sent when it answers";
    case "attention"
        s = "something on this computer must be fixed: see the Database window";
    otherwise
        s = "not connected yet: " + state;
end
end
