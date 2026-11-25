function [W, info] = subjectFactors(ids)
%CELLDB.SUBJECTFACTORS The subjects' lab database tags and variables as columns to group and plot by (cache only).
%   [W, info] = celldb.subjectFactors(["SUBJ-ID-1127"; "SUBJ-ID-1146"])
%
% W has one row per id, in the order given: subject_id, then one column for
%   each tag namespace a subject here has a tag of ("cohort" -> Tag_cohort):
%       text, the value ("a"); several values of a multi-valued namespace
%       joined with ", "; "" for a subject without one
%   each bare tag a subject here carries ("pilot" -> HasTag_pilot):
%       text, "pilot" or "not pilot"; "" for a subject whose tags were never
%       read (so "does not have it" and "not known" stay apart)
%   each variable a subject here has a value of ("age at perfusion" ->
%   Var_age_at_perfusion):
%       a number variable: double, NaN for a subject without a value
%       a text variable: text, "" for a subject without a value
%
% INFO has one row per such column:
%   Name     the column of W (a valid MATLAB name, unique)
%   Label    what to call it: "cohort", "pilot", "Age at perfusion (d)"
%   Source   "tag" | "variable"
%   Type     "text" | "number"
%   Units    of a number variable ("" otherwise)
%   Key      the namespace, the bare tag or the variable's canonical name
%   Meaning  one sentence for a tooltip
%
% Everything is read from this computer's cache (celldb.subjectTags,
% celldb.subjectVariables); celldb.refreshSubjects renews it. Never an error;
% without the client W has only subject_id and INFO no rows.
%
% See also CELLDB.SUBJECTTAGS, CELLDB.SUBJECTVARIABLES, CELLANALYSIS.PROJECT.

arguments
    ids string
end

ids = reshape(ids, [], 1);
n = numel(ids);
W = table(ids, 'VariableNames', {'subject_id'});
info = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
    'VariableNames', {'Name', 'Label', 'Source', 'Type', 'Units', 'Key', 'Meaning'});
if n == 0
    return
end

try
    [T, tagsAt] = celldb.subjectTags(ids);
    V = celldb.subjectVariables(ids);
catch
    return
end

used = "subject_id";

% ---- tag namespaces
bareNs = "tag";
for ns = reshape(unique(T.namespace(T.namespace ~= bareNs)), 1, [])
    col = strings(n, 1);
    for k = 1:n
        v = sort(T.value(T.subject_id == ids(k) & T.namespace == ns));
        col(k) = strjoin(v, ", ");
    end
    [name, used] = columnName("Tag_" + ns, used);
    W.(name) = col;
    info(end + 1, :) = {name, ns, "tag", "text", "", ns, ...
        "The subject's tag of the namespace """ + ns + """ in the lab database (" + ns + ":<value>)."}; %#ok<AGROW>
end

% ---- bare tags
for tg = reshape(unique(T.value(T.namespace == bareNs)), 1, [])
    col = strings(n, 1);
    for k = 1:n
        if isnat(tagsAt(k)), continue; end
        if any(T.subject_id == ids(k) & T.namespace == bareNs & T.value == tg)
            col(k) = tg;
        else
            col(k) = "not " + tg;
        end
    end
    [name, used] = columnName("HasTag_" + tg, used);
    W.(name) = col;
    info(end + 1, :) = {name, tg, "tag", "text", "", tg, ...
        "Whether the subject carries the tag """ + tg + """ in the lab database."}; %#ok<AGROW>
end

% ---- variables
for vn = reshape(unique(V.variable), 1, [])
    rows = V(V.variable == vn, :);
    isNum = all(rows.value_type == "number");
    label = rows.label(1);
    if strlength(label) == 0, label = vn; end
    units = "";
    if isNum
        u = rows.units(strlength(rows.units) > 0);
        if ~isempty(u), units = u(1); end
        col = nan(n, 1);
    else
        col = strings(n, 1);
    end
    for k = 1:n
        r = find(rows.subject_id == ids(k), 1);
        if isempty(r), continue; end
        if isNum
            col(k) = rows.value_num(r);
        else
            col(k) = rows.value(r);
        end
    end
    [name, used] = columnName("Var_" + vn, used);
    W.(name) = col;
    shown = label;
    if strlength(units) > 0, shown = label + " (" + units + ")"; end
    info(end + 1, :) = {name, shown, "variable", string(ternary(isNum, 'number', 'text')), units, vn, ...
        "The subject's value of the variable """ + vn + """ in the lab database."}; %#ok<AGROW>
end

end

function [name, used] = columnName(wanted, used)
name = string(matlab.lang.makeValidName(char(regexprep(wanted, '[\s.\-]+', '_'))));
name = string(matlab.lang.makeUniqueStrings(char(name), cellstr(used), namelengthmax));
used(end + 1) = name;
end

function v = ternary(tf, a, b)
if tf, v = a; else, v = b; end
end
