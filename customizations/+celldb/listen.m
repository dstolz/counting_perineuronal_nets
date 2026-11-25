function L = listen(fcn)
%CELLDB.LISTEN Call FCN() whenever the lab database's state or this computer's outbox changes.
%   L = celldb.listen(@() app.onDatabaseChanged())
%
% For a window that shows where records are (celldb.sourceRecords): a record
% that is sent, held or released while the window is open changes what it
% shows. L is a cell of listeners; the calls stop when it is cleared (delete
% each one, or let L go out of scope). FCN's errors are caught and warned
% (celldb:Listen), so a window that closed cannot break the sending.
%
% Without the client there is nothing to listen to and L is {}. Never an error.
%
% See also CELLDB.SOURCERECORDS, CELLDB.ADDLAMP, LABCLIENT.DB.

arguments
    fcn (1,1) function_handle
end

L = {};
try
    if ~celldb.available()
        return
    end
    db = labclient.DB.instance();
    L = {listener(db, "StateChanged", @(~, ~) call(fcn)), ...
        listener(db, "OutboxChanged", @(~, ~) call(fcn))};
catch ME
    warning("celldb:Listen", "The lab database's changes are not followed: %s", ME.message);
    L = {};
end

end

function call(fcn)
try
    fcn();
catch ME
    warning("celldb:Listen", "A listener of the lab database failed: %s", ME.message);
end
end
