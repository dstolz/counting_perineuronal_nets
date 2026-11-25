function r = refreshSubjects(ids, opts)
%CELLDB.REFRESHSUBJECTS Ask the lab database about these subjects (which it has, their tags and variables) and keep the answers here.
%   r = celldb.refreshSubjects(["SUBJ-ID-1127"; "SUBJ-ID-1146"])
%   r = celldb.refreshSubjects(ids, Budget = 5)     % seconds to wait for the server at most
%
% The one function here that asks the server, and only when a person asks for
% it (the Dataset Manager's Check subjects button). It waits BUDGET seconds at
% most for the server to answer (labclient.SubjectCache.refresh, which probes
% the server before it opens a connection), then celldb.subjectInfo,
% celldb.subjectTags and celldb.subjectVariables read the renewed answers: the
% subject's sex, species and project, its current tags and its current
% variable values. Nothing is changed when the database cannot be reached.
%
% Returns a struct with
%   ok        the database answered
%   asked     the number of subjects it was asked about
%   missing   the ids it does not have (a string column)
%   tagsRead  the subjects' tags and variables were read too (false with a
%             client too old to keep them, or when the database did not give
%             them: the earlier ones stay)
%   message   one plain sentence for a status bar
%
% Never an error. Without the client, or with the database turned off on this
% computer, ok is false and MESSAGE says why.
%
% See also CELLDB.SUBJECTINFO, CELLDB.SUBJECTTAGS, CELLDB.SUBJECTVARIABLES, LABCLIENT.SUBJECTCACHE.

arguments
    ids string
    opts.Budget (1,1) double {mustBePositive} = 10
end

r = struct("ok", false, "asked", 0, "missing", strings(0, 1), "message", "", "tagsRead", false);
try
    ids = reshape(ids, [], 1);
    ids = unique(strtrim(ids(~ismissing(ids) & strlength(strtrim(ids)) > 0)), "stable");
    [ok, why] = celldb.available();
    if ~ok
        r.message = "Subjects not checked. " + why;
        return
    end
    if ~celldb.capturing()
        r.message = "Subjects not checked: the lab database is turned off on this computer (see the Database window).";
        return
    end
    if isempty(ids)
        r.message = "No subject to check: no file name here names a SUBJ-ID.";
        return
    end
    x = labclient.SubjectCache.refresh(ids, Budget = opts.Budget);
    r.ok = logical(x.Connected);
    if ~r.ok
        r.message = "Subjects not checked: " + string(x.Message);
        return
    end
    r.asked = double(x.Refreshed);
    r.missing = reshape(string(x.NotFound), [], 1);
    if isempty(r.missing)
        r.message = sprintf("The lab database has all %d subject(s) named here.", r.asked);
    else
        shown = r.missing(1:min(4, end));
        more = "";
        if numel(r.missing) > numel(shown)
            more = sprintf(" and %d more", numel(r.missing) - numel(shown));
        end
        r.message = sprintf("The lab database has %d of %d subject(s). Not there: %s%s. Their records wait in the " + ...
            "outbox until the subject is added or assigned (Database window).", ...
            r.asked - numel(r.missing), r.asked, strjoin(shown, ", "), more);
    end
    r.tagsRead = isfield(x, "TagsRead") && logical(x.TagsRead);
    if r.tagsRead
        r.message = r.message + " Their tags and variables were read.";
    else
        [~, why] = factsUsable();
        if strlength(why) == 0, why = string(x.Message); end
        r.message = strtrim(r.message + " Their tags and variables were not read. " + why);
    end
catch ME
    r.ok = false;
    r.message = "Subjects not checked: " + string(ME.message);
end

end
