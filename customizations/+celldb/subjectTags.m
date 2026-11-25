function [T, asOf] = subjectTags(ids)
%CELLDB.SUBJECTTAGS The lab database tags of each subject, from this computer's cache (never the network).
%   T = celldb.subjectTags(["SUBJ-ID-1127"; "SUBJ-ID-1146"])
%   [T, asOf] = celldb.subjectTags(ids)
%
% A tag is a label a lab member put on the subject in the lab database
% (CarasLabDB): "cohort:a", "condition:noise", or a bare word such as "pilot".
% The answers are the ones the lab database client keeps on this computer
% (labclient.SubjectCache.tags), renewed by celldb.refreshSubjects (the Dataset
% Manager's and Cell Analysis's Check subjects button).
%
% T has one row per tag:
%   subject_id
%   tag          as the database stores it: "cohort:a", "tag:pilot"
%   display_tag  as it is shown: a bare tag without its "tag:"
%   namespace    "cohort", "tag" (the namespace of bare tags), ...
%   value        "a", "pilot", ...
% A subject without tags gives no row. ASOF (a row per id, in the order
% given) is when the subject's tags were read, NaT when never: it tells "no
% tags" from "never asked".
%
% Never an error; without the client, or with one too old to keep tags, T has
% no rows and ASOF is NaT.
%
% See also CELLDB.SUBJECTVARIABLES, CELLDB.SUBJECTFACTORS, CELLDB.TAGFILTER, CELLDB.REFRESHSUBJECTS.

arguments
    ids string
end

ids = reshape(ids, [], 1);
T = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
    'VariableNames', {'subject_id', 'tag', 'display_tag', 'namespace', 'value'});
asOf = NaT(numel(ids), 1, "TimeZone", "local");
try
    ask = ids;
    ask(ismissing(ask)) = "";
    if isempty(ids) || ~factsUsable()
        return
    end
    [R, at] = labclient.SubjectCache.tags(ask);
    R = R(strlength(R.subject_id) > 0, :);
    T = R(:, T.Properties.VariableNames);
    asOf = at;
catch
    T = T([], :);
    asOf = NaT(numel(ids), 1, "TimeZone", "local");
end
end
