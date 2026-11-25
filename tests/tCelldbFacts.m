classdef tCelldbFacts < matlab.unittest.TestCase
    %tCelldbFacts  The lab database's tags and variables of the subjects, through celldb: read from
    %   this computer's cache only (celldb.subjectTags, celldb.subjectVariables), renewed by
    %   celldb.refreshSubjects, in a few words for a table (celldb.subjectInfo), as columns to group
    %   and plot by (celldb.subjectFactors), and as a filter (celldb.tagFilter). And the same
    %   functions without the client: nothing, and never an error.
    %
    %   Needs the labclient package with interface version 4 (a current CarasLabDB checkout);
    %   skipped without it and under tools\Run-Tests.ps1 -WithoutClient, except the last test.
    %   Everything runs against labclient.FakeBackend (tests\celldb_test_client): no server is
    %   contacted and nothing of the user's is touched.
    %
    %   tCelldbFacts.seed(fake) gives the fake server the tags and variables the GUI tests use too.
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tCelldbFacts

    properties
        Fake
        Restore = {}
        Top string = ""
    end

    properties (Constant)
        Ids = ["SUBJ-ID-9001"; "SUBJ-ID-9002"; "SUBJ-ID-1127"]
    end

    methods (TestMethodSetup)
        function isolate(tc)
            tc.addTeardown(@() tc.restoreClient());
        end
    end

    methods
        function restoreClient(tc)
            for k = numel(tc.Restore):-1:1
                tc.Restore{k} = [];
            end
            tc.Restore = {};
            if tc.Top ~= "" && isfolder(tc.Top)
                rmdir(tc.Top, 's');
            end
            try celldb.available('Refresh', true); catch, end
        end

        function useClient(tc)
            tc.assumeNotEqual(string(getenv('CELLDB_NO_CLIENT')), "1", 'run without the client');
            [ok, why] = celldb.available('Refresh', true);
            tc.assumeTrue(ok, "The lab database client is not usable here: " + why);
            [ok, why] = labclient.Api.atLeast(4);
            tc.assumeTrue(ok, "The lab database client here keeps no tags: " + string(why));
            [tc.Fake, tc.Restore, tc.Top] = celldb_test_client();
            celldb.available('Refresh', true);
            tCelldbFacts.seed(tc.Fake);
        end
    end

    methods (Static)
        function seed(fake)
            %seed  Tags and variables for the test client's three subjects (and one tag that is no subject's).
            %   SUBJ-ID-9001  cohort:a  condition:noise  pilot     age at perfusion 92 d   housing pair
            %   SUBJ-ID-9002  cohort:b  condition:sham             age at perfusion 120.5 d
            %   SUBJ-ID-1127  cohort:a  qc:fail  topic:x topic:y   age at perfusion 60 d   housing single
            t0 = datetime(2026, 11, 2, 9, 0, 0, "TimeZone", "UTC");
            who = ["SUBJ-ID-9001"; "SUBJ-ID-9001"; "SUBJ-ID-9001"; "SUBJ-ID-9002"; "SUBJ-ID-9002"; ...
                "SUBJ-ID-1127"; "SUBJ-ID-1127"; "SUBJ-ID-1127"; "SUBJ-ID-1127"; "SUBJ-ID-9001"];
            tag = ["cohort:a"; "condition:noise"; "Pilot"; "cohort:b"; "condition:sham"; ...
                "cohort:a"; "qc:fail"; "topic:y"; "topic:x"; "stage:curated"];
            kind = [repmat("subject", 9, 1); "artifact"];
            fake.Tags = table(kind, who, tag, repmat(t0, numel(who), 1), ...
                'VariableNames', fake.Tags.Properties.VariableNames);
            fake.Variables = table(repmat("subject", 5, 1), ...
                ["SUBJ-ID-9001"; "SUBJ-ID-9001"; "SUBJ-ID-9002"; "SUBJ-ID-1127"; "SUBJ-ID-1127"], ...
                ["age at perfusion"; "housing"; "age at perfusion"; "age at perfusion"; "housing"], ...
                ["92"; "pair"; "120.5"; "60"; "single"], [92; NaN; 120.5; 60; NaN], ...
                [""; "pair"; ""; ""; "single"], ["d"; ""; "d"; "d"; ""], repmat(t0, 5, 1), ...
                'VariableNames', fake.Variables.Properties.VariableNames);
            fake.VariableLabels = table("age at perfusion", "Age at perfusion", 'VariableNames', {'variable', 'label'});
        end
    end

    methods (Test)

        function nothingIsKnownBeforeTheDatabaseWasAsked(tc)
            tc.useClient();
            [T, at] = celldb.subjectTags(tc.Ids);
            tc.verifyEqual(height(T), 0);
            tc.verifyTrue(all(isnat(at)));
            [V, vat] = celldb.subjectVariables(tc.Ids);
            tc.verifyEqual(height(V), 0);
            tc.verifyTrue(all(isnat(vat)));
            I = celldb.subjectInfo(tc.Ids);
            tc.verifyEqual(I.tags, ["" ; ""; ""]);
            tc.verifyFalse(any(I.facts_read));
            tc.verifyEmpty(tc.Fake.Calls(ismember(string(tc.Fake.Calls), ["entityTags" "entityVariables"])), ...
                'reading never asks the server');
            [W, info] = celldb.subjectFactors(tc.Ids);
            tc.verifyEqual(string(W.Properties.VariableNames), "subject_id");
            tc.verifyEqual(height(info), 0);
        end

        function refreshReadsTagsAndVariablesAndTheCacheGivesThemBack(tc)
            tc.useClient();
            r = celldb.refreshSubjects([tc.Ids; "SUBJ-ID-4040"]);
            tc.verifyTrue(r.ok, r.message);
            tc.verifyTrue(r.tagsRead);
            tc.verifySubstring(r.message, "tags and variables were read");
            tc.verifyEqual(r.missing, "SUBJ-ID-4040");

            tc.Fake.Reachable = false;          % from here on: the file only
            labclient.DB.disconnect();
            [T, at] = celldb.subjectTags([tc.Ids; "SUBJ-ID-4040"; "SUBJ-ID-7"; ""]);
            tc.verifyEqual(isnat(at), [false; false; false; false; true; true], ...
                'asked and none is not never asked; no id is never asked');
            mine = @(id) reshape(T.display_tag(T.subject_id == id), 1, []);
            tc.verifyEqual(mine("SUBJ-ID-9001"), ["cohort:a" "condition:noise" "pilot"]);
            tc.verifyEqual(mine("SUBJ-ID-9002"), ["cohort:b" "condition:sham"]);
            tc.verifyEqual(mine("SUBJ-ID-1127"), ["cohort:a" "qc:fail" "topic:x" "topic:y"]);
            tc.verifyEqual(T.tag(T.display_tag == "pilot"), "tag:pilot", 'a bare tag is stored in the namespace tag');
            tc.verifyFalse(any(T.tag == "stage:curated"), 'a tag of an artifact is not the subject''s');

            V = celldb.subjectVariables(tc.Ids);
            a = V(V.subject_id == "SUBJ-ID-9002", :);
            tc.verifyEqual(a.variable, "age at perfusion");
            tc.verifyEqual(a.label, "Age at perfusion");
            tc.verifyEqual(a.value_num, 120.5);
            tc.verifyEqual(a.units, "d");
            tc.verifyEqual(a.value_type, "number");
            h = V(V.subject_id == "SUBJ-ID-9001" & V.variable == "housing", :);
            tc.verifyEqual(h.value, "pair");
            tc.verifyTrue(isnan(h.value_num));
            tc.verifyEqual(h.value_type, "text");

            I = celldb.subjectInfo(tc.Ids);
            tc.verifyEqual(I.tags(1), "cohort:a condition:noise pilot", 'as a tag filter is typed');
            tc.verifyEqual(I.variables(1), "Age at perfusion = 92 d; housing = pair");
            tc.verifyEqual(I.variables(2), "Age at perfusion = 120.5 d");
            tc.verifyTrue(all(I.facts_read));
            tc.verifyEqual(I.sex(1), "F", 'the rest of the answer is as before');
        end

        function factorsAreOneColumnPerNamespaceBareTagAndVariable(tc)
            tc.useClient();
            celldb.refreshSubjects(tc.Ids);
            ids = [tc.Ids; "SUBJ-ID-7"];
            [W, info] = celldb.subjectFactors(ids);
            tc.verifyEqual(W.subject_id, ids);
            tc.verifyEqual(sort(info.Name)', sort(["Tag_cohort" "Tag_condition" "Tag_qc" "Tag_topic" "HasTag_pilot" ...
                "Var_age_at_perfusion" "Var_housing"]));
            tc.verifyEqual(W.Tag_cohort, ["a"; "b"; "a"; ""]);
            tc.verifyEqual(W.Tag_condition, ["noise"; "sham"; ""; ""]);
            tc.verifyEqual(W.Tag_topic, [""; ""; "x, y"; ""], 'the values of a multi-valued namespace, sorted');
            tc.verifyEqual(W.HasTag_pilot, ["pilot"; "not pilot"; "not pilot"; ""], ...
                'a subject never asked about neither has the tag nor lacks it');
            tc.verifyEqual(W.Var_age_at_perfusion, [92; 120.5; 60; NaN]);
            tc.verifyClass(W.Var_age_at_perfusion, 'double');
            tc.verifyEqual(W.Var_housing, ["pair"; ""; "single"; ""]);

            row = @(name) info(info.Name == name, :);
            tc.verifyEqual(row("Var_age_at_perfusion").Label, "Age at perfusion (d)");
            tc.verifyEqual(row("Var_age_at_perfusion").Type, "number");
            tc.verifyEqual(row("Var_age_at_perfusion").Source, "variable");
            tc.verifyEqual(row("Var_age_at_perfusion").Units, "d");
            tc.verifyEqual(row("Var_housing").Type, "text");
            tc.verifyEqual(row("Tag_cohort").Source, "tag");
            tc.verifyEqual(row("Tag_cohort").Label, "cohort");
            tc.verifyEqual(row("HasTag_pilot").Label, "pilot");
            tc.verifyTrue(all(strlength(info.Meaning) > 0));
        end

        function theTagFilterKeepsWhatIsKnownToMatch(tc)
            tc.useClient();
            celldb.refreshSubjects(tc.Ids);
            ids = [tc.Ids; "SUBJ-ID-7"; ""];          % one never asked about, one row that names no subject

            [keep, note] = celldb.tagFilter(ids, "");
            tc.verifyEqual(keep, true(5, 1), 'no filter: everything passes');
            tc.verifyEqual(note, "");

            [keep, note] = celldb.tagFilter(ids, "Cohort:A");
            tc.verifyEqual(keep, [true; false; true; false; false]);
            tc.verifySubstring(note, "1 subject(s) were never checked");

            keep = celldb.tagFilter(tc.Ids, "cohort:a -qc:fail");
            tc.verifyEqual(keep, [true; false; false]);
            keep = celldb.tagFilter(tc.Ids, "topic:*");
            tc.verifyEqual(keep, [false; false; true]);
            keep = celldb.tagFilter(tc.Ids, "-condition:*");
            tc.verifyEqual(keep, [false; false; true], 'never given a condition');
            keep = celldb.tagFilter(tc.Ids, "pilot");
            tc.verifyEqual(keep, [true; false; false], 'a bare word is a bare tag');

            % the dangerous direction: a typo behind "-" would hide nothing, so it is said
            [keep, note] = celldb.tagFilter(tc.Ids, "-qc:fial");
            tc.verifyEqual(keep, true(3, 1));
            tc.verifySubstring(note, "qc:fial");
            tc.verifySubstring(note, "No subject here carries");

            [keep, note] = celldb.tagFilter(tc.Ids, "my:bad:tag");
            tc.verifyFalse(any(keep), 'a filter that is no tag shows nothing rather than everything');
            tc.verifySubstring(note, "is not a tag");

            % a never-asked subject does not pass a filter of "-" tokens either, nor one the database lacks
            keep = celldb.tagFilter(["SUBJ-ID-7"; "SUBJ-ID-9002"], "-qc:fail");
            tc.verifyEqual(keep, [false; true]);
            celldb.refreshSubjects("SUBJ-ID-4040");
            [keep, note] = celldb.tagFilter(["SUBJ-ID-4040"; "SUBJ-ID-9002"], "-qc:fail");
            tc.verifyEqual(keep, [false; true]);
            tc.verifySubstring(note, "1 subject(s) are not in the lab database");
        end

        function aTagThatWasRemovedIsGoneAfterTheNextCheck(tc)
            tc.useClient();
            celldb.refreshSubjects(tc.Ids);
            tc.verifyTrue(celldb.tagFilter("SUBJ-ID-1127", "qc:fail"));
            tc.Fake.Tags = tc.Fake.Tags(tc.Fake.Tags.tag ~= "qc:fail", :);
            tc.Fake.Variables.value_num(tc.Fake.Variables.entity_id == "SUBJ-ID-9001" & ...
                tc.Fake.Variables.variable == "age at perfusion") = 95;
            tc.Fake.Variables.value(tc.Fake.Variables.entity_id == "SUBJ-ID-9001" & ...
                tc.Fake.Variables.variable == "age at perfusion") = "95";
            tc.verifyTrue(celldb.tagFilter("SUBJ-ID-1127", "qc:fail"), 'until someone asks again the cache answers');
            celldb.refreshSubjects(tc.Ids);
            tc.verifyFalse(celldb.tagFilter("SUBJ-ID-1127", "qc:fail"));
            W = celldb.subjectFactors("SUBJ-ID-9001");
            tc.verifyEqual(W.Var_age_at_perfusion, 95);
        end

        function withoutTheClientThereIsNothingAndNoError(tc)
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_NO_CLIENT', '1'));
            celldb.available('Refresh', true);
            [T, at] = celldb.subjectTags(tc.Ids);
            tc.verifyEqual(height(T), 0);
            tc.verifyEqual(string(T.Properties.VariableNames), ["subject_id" "tag" "display_tag" "namespace" "value"]);
            tc.verifyTrue(all(isnat(at)));
            [V, vat] = celldb.subjectVariables(tc.Ids);
            tc.verifyEqual(height(V), 0);
            tc.verifyTrue(all(isnat(vat)));
            [W, info] = celldb.subjectFactors(tc.Ids);
            tc.verifyEqual(width(W), 1);
            tc.verifyEqual(height(info), 0);
            I = celldb.subjectInfo(tc.Ids);
            tc.verifyEqual(I.tags, strings(3, 1));
            tc.verifyEqual(I.variables, strings(3, 1));
            tc.verifyEqual(celldb.tagFilter(tc.Ids, ""), true(3, 1), 'no filter still shows everything');
            [keep, note] = celldb.tagFilter(tc.Ids, "cohort:a");
            tc.verifyFalse(any(keep));
            tc.verifySubstring(note, "shows nothing");
            r = celldb.refreshSubjects(tc.Ids);
            tc.verifyFalse(r.ok);
            tc.verifyFalse(r.tagsRead);
        end

    end
end
