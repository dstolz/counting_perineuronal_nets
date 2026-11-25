function [keep, note, f] = tagFilter(ids, expr)
%CELLDB.TAGFILTER Which subjects pass a tag filter, by the tags this computer's cache holds (never the network).
%   [keep, note] = celldb.tagFilter(["SUBJ-ID-1127"; "SUBJ-ID-1146"; ""], "cohort:a -qc:fail")
%
% EXPR is the tag filter of the lab database's own window and dashboards:
% tags separated by spaces that must ALL hold; a leading "-" means "does not
% have"; "namespace:*" means any tag of that namespace; a bare word is a bare
% tag; case does not matter (labclient.Tags).
%
%   keep   logical, one per id: the subject is known to pass. With an empty
%          filter every id passes. With a filter, an id that names no subject
%          (""), a subject whose tags were never read and a subject the
%          database does not have do NOT pass (not even a filter of "-" tags
%          only): the filter shows what is known to match, never what might.
%   note   one plain sentence for a status bar, "" when there is nothing to
%          say: what in EXPR is no tag, a tag no subject here carries (a typo
%          hides nothing behind "-", so it is said), how many subjects were
%          never checked or are not in the database, or why tags cannot be
%          read on this computer
%   f      the filter as read: struct All, None (canonical tags)
%
% Never an error.
%
% See also CELLDB.SUBJECTTAGS, CELLDB.REFRESHSUBJECTS.

arguments
    ids string
    expr {mustBeText} = ""
end

ids = reshape(ids, [], 1);
ids(ismissing(ids)) = "";
keep = true(numel(ids), 1);
note = "";
f = struct("All", strings(1, 0), "None", strings(1, 0));
expr = strtrim(strjoin(string(expr), " "));
if strlength(expr) == 0
    return
end

try
    [ok, why] = factsUsable();
    if ~ok
        keep(:) = false;
        note = "The tag filter shows nothing: " + why;
        return
    end
    [f, problems] = labclient.Tags.parseFilter(expr);
    if isempty(f.All) && isempty(f.None)
        keep(:) = false;
        note = "The tag filter shows nothing: " + strjoin(problems, " ");
        return
    end
    uniq = unique(ids(strlength(ids) > 0));
    [T, at] = celldb.subjectTags(uniq);
    absent = false(numel(uniq), 1);
    if ~isempty(uniq)
        I = celldb.subjectInfo(uniq);
        absent = I.asked & ~I.known;
    end
    for k = 1:numel(ids)
        j = find(uniq == ids(k), 1);
        if isempty(j) || isnat(at(j)) || absent(j)
            keep(k) = false;
            continue
        end
        keep(k) = labclient.Tags.match(T.tag(T.subject_id == ids(k)), f);
    end
    never = nnz(isnat(at) & ~absent);
    parts = strings(1, 0);
    if ~isempty(problems)
        parts(end + 1) = strjoin(problems, " ");
    end
    gone = labclient.Tags.unmatched(f, T.tag);
    if ~isempty(gone)
        parts(end + 1) = "No subject here carries " + strjoin(gone, ", ") + " (check the spelling).";
    end
    if never > 0
        parts(end + 1) = sprintf("%d subject(s) were never checked for tags and are left out: Check subjects.", never);
    end
    if any(absent)
        parts(end + 1) = sprintf("%d subject(s) are not in the lab database and are left out.", nnz(absent));
    end
    note = strjoin(parts, " ");
catch ME
    keep(:) = false;
    note = "The tag filter shows nothing: " + string(ME.message);
end
end
