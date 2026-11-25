function T = subjectInfo(ids)
%CELLDB.SUBJECTINFO What the lab database last said about each subject, from this computer's cache (never the network).
%   T = celldb.subjectInfo(["SUBJ-ID-1127"; "SUBJ-ID-1146"])
%
% A curation record names its section's subject (SUBJ-ID-<n>, from the file
% name: celldb.parseSectionName). The database takes the record only for a
% subject it has; for any other the record waits in the outbox for a person.
% This says, before any curation, which subjects the database has, from the
% answers the lab database client keeps on this computer
% (labclient.SubjectCache.status: one file, so it is as fast as a file read and
% the same with the server out of reach). celldb.refreshSubjects asks the
% database and renews those answers.
%
% T has one row per id, in the order given:
%   subject_id
%   asked      the database was asked about this subject at some time
%   known      it had the subject then (false when never asked: test asked first)
%   sex, species, project   as the database has them ("" when not known)
%   endpointed the subject has an endpoint recorded
%   as_of      when the database said so (NaT when never asked)
%   text       a few words for a table or tooltip: "F, meriones_unguiculatus,
%              project P1", "not in the lab database", or "" when never asked
%              or when the client is not usable here
%   tags       the subject's tags as they are shown and as a tag filter is
%              typed, separated by spaces: "cohort:a pilot" ("" for none)
%   variables  its variable values in a few words: "Age at perfusion = 92 d;
%              housing = pair" ("" for none)
%   facts_read the subject's tags and variables were read at some time (false
%              tells "never asked" from "none")
%
% Never an error; without the client every row is "never asked".
%
% See also CELLDB.REFRESHSUBJECTS, CELLDB.SUBJECTTAGS, CELLDB.SUBJECTVARIABLES, CELLDB.PARSESECTIONNAME,
% LABCLIENT.SUBJECTCACHE.

arguments
    ids string
end

ids = reshape(ids, [], 1);
n = numel(ids);
asked = false(n, 1);
known = false(n, 1);
sex = strings(n, 1);
species = strings(n, 1);
project = strings(n, 1);
endpointed = false(n, 1);
asOf = NaT(n, 1, "TimeZone", "local");
text = strings(n, 1);
tags = strings(n, 1);
variables = strings(n, 1);
factsRead = false(n, 1);

try
    if n > 0 && celldb.available()
        C = labclient.SubjectCache.status(ids);
        asOf = C.as_of;
        asked = ~isnat(asOf);
        known = asked & logical(C.known);
        sex = orBlank(C.sex);
        species = orBlank(C.species);
        project = orBlank(C.project);
        endpointed = known & logical(C.is_endpointed);
        for k = 1:n
            if ~asked(k)
                continue
            end
            if ~known(k)
                text(k) = "not in the lab database";
                continue
            end
            parts = [sex(k), species(k)];
            if project(k) ~= ""
                parts(end + 1) = "project " + project(k); %#ok<AGROW>
            end
            if endpointed(k)
                parts(end + 1) = "endpointed"; %#ok<AGROW>
            end
            parts = parts(strlength(parts) > 0);
            text(k) = strjoin(parts, ", ");
            if text(k) == ""
                text(k) = "in the lab database";
            end
        end
        [G, tagsAt] = celldb.subjectTags(ids);
        [V, varsAt] = celldb.subjectVariables(ids);
        factsRead = ~isnat(tagsAt) | ~isnat(varsAt);
        for k = 1:n
            tags(k) = strjoin(G.display_tag(G.subject_id == ids(k)), " ");
            rows = find(V.subject_id == ids(k));
            said = strings(1, numel(rows));
            for q = 1:numel(rows)
                r = rows(q);
                said(q) = V.label(r) + " = " + strtrim(V.value(r) + " " + V.units(r));
            end
            variables(k) = strjoin(said, "; ");
        end
    end
catch
    asked(:) = false;
    known(:) = false;
    endpointed(:) = false;
    sex(:) = "";
    species(:) = "";
    project(:) = "";
    asOf = NaT(n, 1, "TimeZone", "local");
    text(:) = "";
    tags(:) = "";
    variables(:) = "";
    factsRead(:) = false;
end

T = table(ids, asked, known, sex, species, project, endpointed, asOf, text, tags, variables, factsRead, ...
    'VariableNames', {'subject_id', 'asked', 'known', 'sex', 'species', 'project', 'endpointed', 'as_of', 'text', ...
    'tags', 'variables', 'facts_read'});

end

function s = orBlank(s)
s = string(s);
s(ismissing(s)) = "";
end
