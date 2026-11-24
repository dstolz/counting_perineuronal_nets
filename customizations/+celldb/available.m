function [tf, why] = available(opts)
%CELLDB.AVAILABLE True when the lab database client (CarasLabDB's labclient package) can be used here.
%   tf = celldb.available()
%   [tf, why] = celldb.available()          % WHY: plain text saying why not (for a tooltip), "" when true
%   tf = celldb.available(Refresh = true)   % look again (tests)
%
% The curation app records its work in the lab database through the client
% every lab toolbox on a computer shares: the +labclient package of a
% CarasLabDB checkout (one setup, one password, one outbox and one sender per
% computer). This package, celldb, is the only code here that uses it, and
% this function the only one that decides whether it can: everything else in
% celldb does nothing when it says false.
%
% The package is looked for once per MATLAB: already on the path; else in the
% folder the environment variable CARASLABDB_DIR names; else in a CarasLabDB
% folder beside this checkout (celldb.clientCandidates). A folder holding
% +labclient is added to the path. The client must also be recent enough:
% labclient.Api.atLeast(3) (version 3 is the first with an interface version,
% the rules a record is held to, and replacement files that may name any
% earlier version). The environment variable CELLDB_NO_CLIENT=1 makes the
% answer false whatever is installed (tools\Run-Tests.ps1 -WithoutClient), so
% a run can prove nothing here needs the client.
%
% WHY is one of "not installed", "too old", "disabled by the environment",
% each with what to do about it.
%
% Never an error: a client that is missing, too old or broken is "false".
%
% Without the client nothing is lost: every curation record still writes its
% provenance sidecar beside the curation files (celldb.recordCuration), and
% celldb.backfill puts those records in the outbox once the client is here.
%
% See also CELLDB.RECORDCURATION, CELLDB.BACKFILL, CELLDB.CAPTURING.

arguments
    opts.Refresh (1,1) logical = false
end

persistent found reason

if opts.Refresh
    found = [];
    reason = "";
end

if string(getenv("CELLDB_NO_CLIENT")) == "1"
    tf = false;
    why = "The lab database client is switched off by the environment variable CELLDB_NO_CLIENT=1.";
    return
end

if ~isempty(found)
    tf = found && exist("labclient.DB", "class") == 8;
    why = reason;
    if ~tf && why == ""
        why = "The lab database client is not available.";
    end
    return
end

tf = false;
why = "";

try
    if exist("labclient.DB", "class") ~= 8 || exist("labclient.Api", "class") ~= 8
        % not on the path (or an older copy is): the first candidate that has +labclient with the interface class
        for c = celldb.clientCandidates()
            if strlength(c) > 0 && isfolder(fullfile(c, "+labclient"))
                addpath(char(c));
                if exist("labclient.DB", "class") == 8 && exist("labclient.Api", "class") == 8
                    break
                end
            end
        end
    end
    if exist("labclient.DB", "class") ~= 8
        why = "The lab database client is not installed: clone https://github.com/dstolz/CarasLabDB beside " + ...
            "this checkout (looked in " + strjoin(celldb.clientCandidates(), ", ") + "), or set " + ...
            "CARASLABDB_DIR to a checkout of it, and restart MATLAB.";
    elseif exist("labclient.Api", "class") ~= 8
        why = "The lab database client on the MATLAB path is too old (it has no interface version): " + ...
            "update the CarasLabDB checkout (git pull).";
    else
        [ok, msg] = labclient.Api.atLeast(3);
        if ok
            tf = true;
        else
            why = "The lab database client is too old. " + string(msg);
        end
    end
catch ME
    tf = false;
    why = "The lab database client could not be used: " + string(ME.message);
end

found = tf;
reason = why;

end
