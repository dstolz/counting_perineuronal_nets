function [T, asOf] = subjectVariables(ids)
%CELLDB.SUBJECTVARIABLES The lab database variables of each subject, from this computer's cache (never the network).
%   T = celldb.subjectVariables(["SUBJ-ID-1127"; "SUBJ-ID-1146"])
%   [T, asOf] = celldb.subjectVariables(ids)
%
% A variable is a named value a lab member set on the subject in the lab
% database (CarasLabDB): "age at perfusion" = 92 d, "housing" = "pair". Each
% holds one number (with units) or one piece of text. The answers are the ones
% the lab database client keeps on this computer
% (labclient.SubjectCache.variables), renewed by celldb.refreshSubjects.
%
% T has one row per value:
%   subject_id
%   variable    the canonical name ("age at perfusion")
%   label       the name shown to people ("Age at perfusion")
%   value       the value as text, whichever kind it is (exact digits)
%   value_num   the number (NaN for a text variable)
%   units       of a number ("" when none)
%   value_type  "number" | "text"
%   set_at      when that value was set
% A subject without values gives no row. ASOF (a row per id, in the order
% given) is when the subject's variables were read, NaT when never.
%
% Never an error; without the client, or with one too old to keep variables, T
% has no rows and ASOF is NaT.
%
% See also CELLDB.SUBJECTTAGS, CELLDB.SUBJECTFACTORS, CELLDB.REFRESHSUBJECTS.

arguments
    ids string
end

ids = reshape(ids, [], 1);
T = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), zeros(0, 1), strings(0, 1), ...
    strings(0, 1), NaT(0, 1, "TimeZone", "local"), 'VariableNames', {'subject_id', 'variable', 'label', ...
    'value', 'value_num', 'units', 'value_type', 'set_at'});
asOf = NaT(numel(ids), 1, "TimeZone", "local");
try
    ask = ids;
    ask(ismissing(ask)) = "";
    if isempty(ids) || ~factsUsable()
        return
    end
    [R, at] = labclient.SubjectCache.variables(ask);
    R = R(strlength(R.subject_id) > 0, :);
    T = R(:, T.Properties.VariableNames);
    asOf = at;
catch
    T = T([], :);
    asOf = NaT(numel(ids), 1, "TimeZone", "local");
end
end
