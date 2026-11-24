function r = suspend()
%CELLDB.SUSPEND No sending to the lab database until R is cleared (a batch is running).
%   r = celldb.suspend();   % ... the batch ...;   clear r
%
% Sending a record takes the database's time and a little of MATLAB's; a long
% batch is better left alone until it is done. Without the client there is
% nothing to pause, and R is an object whose clearing does nothing. Never an
% error.
%
% See also LABCLIENT.SYNC.

r = onCleanup(@() []);
try
    if celldb.available()
        r = labclient.Sync.suspend();
    end
catch
end
end
