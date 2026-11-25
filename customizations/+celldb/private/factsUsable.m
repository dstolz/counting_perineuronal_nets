function [tf, why] = factsUsable()
%FACTSUSABLE True when the lab database client here keeps subjects' tags and variables (labclient interface 4).
%   [tf, why] = factsUsable()    % WHY: what to do when it does not ("" when true)
%
% The rest of celldb needs interface version 3 (celldb.available); tags and
% variables came with version 4, so a computer with an older CarasLabDB
% checkout keeps recording and only shows no tags. Never an error.

tf = false;
why = "";
try
    [ok, why] = celldb.available();
    if ~ok
        return
    end
    [tf, why] = labclient.Api.atLeast(4);
    why = string(why);
    if ~tf
        why = "Tags and variables need a newer lab database client. " + why;
    end
catch ME
    tf = false;
    why = "Tags and variables could not be read: " + string(ME.message);
end
end
