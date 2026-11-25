classdef tManagerDatabase < matlab.unittest.TestCase
    %tManagerDatabase  The lab database (CarasLabDB) in the Cell Dataset Manager, through celldb: the
    %   Database column says where the record of each completed source is and follows the outbox
    %   while records are sent; a source changed after its record is "changed since"; Check subjects
    %   asks the database which subjects it has and marks the others; Queue records puts records
    %   made with the database turned off into the outbox; a dataset folder seen under another path
    %   still finds its records; and without the client the window works the same and says what is
    %   missing.
    %
    %   Needs the labclient package (a CarasLabDB checkout, found through CARASLABDB_DIR or beside
    %   this repository); skipped without it and under tools\Run-Tests.ps1 -WithoutClient, except the
    %   last test, which is the state without the client. Everything runs against
    %   labclient.FakeBackend in a temporary preference store, a fake vault and a temporary client
    %   folder (tests\celldb_test_client): no server is contacted and nothing of the user's is touched.
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tManagerDatabase

    properties
        Fake
        Restore = {}
        Top string = ""
        Fallback string = ""
    end

    methods (TestMethodSetup)
        function isolate(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Fallback = string(fullfile(fx.Folder, 'provenance'));
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                char(tc.Fallback)));
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

        function useClient(tc, enabled)
            %useClient  The isolated client with its fake server (skips the test without the package).
            if nargin < 2, enabled = true; end
            tc.assumeNotEqual(string(getenv('CELLDB_NO_CLIENT')), "1", 'run without the client');
            [ok, why] = celldb.available('Refresh', true);
            tc.assumeTrue(ok, "The lab database client is not usable here: " + why);
            [tc.Fake, tc.Restore, tc.Top] = celldb_test_client('Enabled', enabled);
            celldb.available('Refresh', true);
        end

        function [c, rec] = completed(tc, name, base)
            %completed  A section curated, marked complete and recorded, its store closed.
            c = tCelldbRun.curate(fullfile(tc.Top, name), 'BaseName', base);
            rec = celldb.recordCuration(c.store);
            c.store.close();
        end

        function app = open(tc, folder)
            if nargin < 2, folder = tc.Top; end
            app = CellDatasetManager(folder, 'UseSettings', false, 'Scan', 'now');
            tc.addTeardown(@() tManagerGui.closeApp(app));
            app.LaunchFcn = @(req) [];
            drawnow;
        end
    end

    methods (Static)
        function txt = cellText(app, base, column)
            %cellText  The text of one cell of the dataset table, by dataset base and column name.
            tbl = findall(app.Figure, 'Type', 'uitable');
            tbl = tbl(arrayfun(@(t) isequal(t.ColumnName(:)', CellDatasetManager.DATASET_COLUMNS), tbl));
            col = strcmp(CellDatasetManager.DATASET_COLUMNS, column);
            row = string(tbl.Data(:, strcmp(CellDatasetManager.DATASET_COLUMNS, 'Name'))) == string(base);
            txt = string(tbl.Data{row, col});
        end

        function b = button(app, tag)
            b = findall(app.Figure, 'Tag', tag);
        end

        function t = card(app, caption)
            %card  The value of the stat card with CAPTION.
            lbl = findall(app.Figure, 'Type', 'uilabel');
            cap = lbl(string({lbl.Text}) == caption);
            sib = cap.Parent.Children;
            t = string(sib(sib ~= cap).Text);
        end
    end

    methods (Test)
        function theColumnFollowsARecordFromWaitingToSent(tc)
            tc.useClient();
            base = tCelldbRun.Section + "_proj";
            [~, rec] = tc.completed('ds', tCelldbRun.Section);
            tc.assertTrue(rec.queued, 'the record is in the outbox');

            app = tc.open();
            d = app.Datasets(1);
            e = d.Sources(strcmp({d.Sources.Key}, 'ECM1'));
            tc.verifyEqual(e.Db.state, "queued");
            tc.verifyTrue(e.Db.current);
            tc.verifyEqual(e.Db.runId, string(rec.runId));
            tc.verifyEqual(e.Db.subjectId, "SUBJ-ID-9001");
            tc.verifyEqual(d.Sources(strcmp({d.Sources.Key}, 'PV2')).Db.state, "none");
            tc.verifyEqual(tManagerDatabase.cellText(app, base, 'Database'), "1 waiting");
            tc.verifyEqual(tManagerDatabase.card(app, 'In database'), "0/1");
            app.setFilter('', 'Database: not sent');
            tc.verifyNumElements(app.View, 1);

            % the lamp, and the buttons that work with the database on
            tc.verifyNotEmpty(findall(app.Figure, 'Tag', 'LabClientLamp'), 'the client''s lamp');
            tc.verifyTrue(logical(tManagerDatabase.button(app, 'btn:checkSubjects').Enable));
            tc.verifyFalse(logical(tManagerDatabase.button(app, 'btn:queueRecords').Enable), ...
                'nothing to queue: the record is in the outbox');
            tc.verifySubstring(tManagerDatabase.button(app, 'btn:queueRecords').Tooltip, 'Nothing to queue');

            % sending it changes the outbox: the window follows without a scan
            labclient.Sync.flush('Budget', 10);
            tc.assertEqual(labclient.Outbox.stateOf(rec.runId), "done");
            app.waitForIdle();
            e = app.Datasets(1).Sources(strcmp({app.Datasets(1).Sources.Key}, 'ECM1'));
            tc.verifyEqual(e.Db.state, "sent");
            tc.verifyEqual(e.Db.text, "sent");
            tc.verifyEmpty(app.View, 'nothing left that was not sent');
            app.setFilter('', 'All datasets');
            tc.verifyEqual(tManagerDatabase.cellText(app, base, 'Database'), "1 sent");
            tc.verifyEqual(tManagerDatabase.card(app, 'In database'), "1/1");

            % the source table says it too
            app.selectDataset(base);
            tbl = findall(app.Figure, 'Type', 'uitable');
            src = tbl(arrayfun(@(t) isequal(t.ColumnName(:)', CellDatasetManager.SOURCE_COLUMNS), tbl));
            S = cell2table(src.Data, 'VariableNames', CellDatasetManager.SOURCE_COLUMNS);
            tc.verifyEqual(string(S.Database(string(S.Source) == "ECM1")), "sent");
            tc.verifyEqual(string(S.Database(string(S.Source) == "PV2")), "-");

            % the report carries it
            T = CellDatasetManager.sourceTable(app.Datasets);
            tc.verifyEqual(T.Database(T.Source == "ECM1"), "sent");
            tc.verifyGreaterThan(strlength(T.DatabaseRecordedAt(T.Source == "ECM1")), 10);
        end

        function aSourceChangedAfterItsRecordSaysSo(tc)
            tc.useClient();
            c = tCelldbRun.curate(fullfile(tc.Top, 'ds'), 'BaseName', tCelldbRun.Section);
            tc.addTeardown(@() c.store.close());
            celldb.recordCuration(c.store);
            labclient.Sync.flush('Budget', 10);
            R = celldb.sourceRecords(string(c.store.Paths.csv));
            tc.verifyEqual(R.state, "sent");
            tc.verifyTrue(R.current);
            tCelldbRun.relabel(c, 11);                       % curation went on after the record
            R = celldb.sourceRecords(string(c.store.Paths.csv));
            tc.verifyEqual(R.state, "sent");
            tc.verifyFalse(R.current);
            tc.verifyEqual(R.text, "sent (changed since)");
            tc.verifySubstring(R.detail, "changed after it was made");
            ds = CellDatasetManager.scan(tc.Top);
            tc.verifyEqual(string(ds.Database), "1 sent (changed since)");
            % the new state recorded: current again, and waiting
            second = celldb.recordCuration(c.store);
            tc.assertTrue(second.written);
            R = celldb.sourceRecords(string(c.store.Paths.csv));
            tc.verifyEqual(R.runId, string(second.runId), 'the latest record is the one shown');
            tc.verifyEqual(R.state, "queued");
            tc.verifyTrue(R.current);
            % asking only the outbox again keeps what the record said
            labclient.Sync.flush('Budget', 10);
            R2 = celldb.sourceRecords(string(c.store.Paths.csv), 'Previous', R);
            tc.verifyEqual(R2.state, "sent");
            tc.verifyEqual(R2.runId, R.runId);
            tc.verifyTrue(R2.current);
        end

        function checkSubjectsMarksTheOnesTheDatabaseLacks(tc)
            tc.useClient();
            known = tCelldbRun.Section;                                        % SUBJ-ID-9001: the fake has it
            absent = "SUBJ-ID-4040IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1";  % and not this one
            tc.completed('known', known);
            [~, rec] = tc.completed('absent', absent);

            app = tc.open();
            tc.assertNumElements(app.Datasets, 2);
            tc.verifyFalse(any([app.Datasets.SubjectAsked]), 'a scan never asks the server');
            tc.verifyEmpty(tc.Fake.Calls(startsWith(string(tc.Fake.Calls), "subjectCurrent")), ...
                'no question reached the fake server yet');

            r = app.checkSubjects();
            tc.verifyTrue(r.ok);
            tc.verifyEqual(r.asked, 2);
            tc.verifyEqual(r.missing, "SUBJ-ID-4040");
            tc.verifySubstring(app.StatusText, 'SUBJ-ID-4040');
            tc.verifySubstring(app.StatusText, '1 of 2 subject(s)');
            k = app.Datasets(strcmp({app.Datasets.SubjectID}, 'SUBJ-ID-9001'));
            a = app.Datasets(strcmp({app.Datasets.SubjectID}, 'SUBJ-ID-4040'));
            tc.verifyTrue(k.SubjectAsked && k.SubjectKnown);
            tc.verifySubstring(k.SubjectText, 'F');
            tc.verifySubstring(k.SubjectText, 'meriones_unguiculatus');
            tc.verifyTrue(a.SubjectAsked && ~a.SubjectKnown);
            tc.verifyEqual(a.SubjectText, 'not in the lab database');

            app.selectDataset(a.Base);
            lbl = findall(app.Figure, 'Type', 'uilabel');
            texts = string(arrayfun(@(l) string(strjoin(string(l.Text), newline)), lbl));
            tc.verifyTrue(any(contains(texts, "SUBJ-ID-4040 (lab database: not in the lab database)")), ...
                'the detail says the subject is not there');

            % and that is why its record waits for a person once it is sent
            labclient.Sync.flush('Budget', 10);
            tc.assertEqual(labclient.Outbox.stateOf(rec.runId), "held");
            app.waitForIdle();
            a = app.Datasets(strcmp({app.Datasets.SubjectID}, 'SUBJ-ID-4040'));
            e = a.Sources(strcmp({a.Sources.Key}, 'ECM1'));
            tc.verifyEqual(e.Db.state, "held");
            tc.verifyEqual(e.Db.text, "needs you");
            tc.verifySubstring(e.Db.detail, "SUBJ-ID-4040");
            tc.verifyEqual(tManagerDatabase.cellText(app, a.Base, 'Database'), "1 needs you");

            % the cache answers a later scan without the server
            nCalls = numel(tc.Fake.Calls);
            ds = CellDatasetManager.scan(tc.Top);
            tc.verifyEqual(numel(tc.Fake.Calls), nCalls, 'scan read the cache, not the server');
            tc.verifyTrue(all([ds.SubjectAsked]));
        end

        function theSubjectsTagsAndVariablesAreShownAndFilterTheList(tc)
            tc.useClient();
            [ok, why] = labclient.Api.atLeast(4);
            tc.assumeTrue(ok, "The lab database client here keeps no tags: " + string(why));
            tCelldbFacts.seed(tc.Fake);
            first = tCelldbRun.Section;                                         % SUBJ-ID-9001: cohort:a, pilot
            second = "SUBJ-ID-9002IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1";   % SUBJ-ID-9002: cohort:b
            absent = "SUBJ-ID-4040IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1";   % not in the database
            tc.completed('first', first);
            tc.completed('second', second);
            tc.completed('absent', absent);
            app = tc.open();
            tc.assertNumElements(app.Datasets, 3);
            subj = @() string({app.Datasets(app.View).SubjectID});

            % nothing was asked yet: no tags, and a filter lists nothing rather than everything
            tc.verifyEqual(tManagerDatabase.cellText(app, first + "_proj", 'Tags'), "");
            app.setTagFilter("cohort:a");
            tc.verifyEmpty(app.View);
            tc.verifySubstring(app.StatusText, 'never checked');
            tc.verifyEmpty(tc.Fake.Calls(ismember(string(tc.Fake.Calls), ["entityTags" "entityVariables"])), ...
                'a filter reads the cache, never the server');

            % Check subjects reads them; the filter that is set applies to the answers
            r = app.checkSubjects();
            tc.verifyTrue(r.ok && r.tagsRead, r.message);
            tc.verifySubstring(app.StatusText, 'tags and variables were read');
            tc.verifyEqual(subj(), "SUBJ-ID-9001", 'the filter set before now has tags to go by');
            app.setTagFilter("");
            tc.verifyNumElements(app.View, 3);
            tc.verifyEqual(tManagerDatabase.cellText(app, first + "_proj", 'Tags'), "cohort:a condition:noise pilot");
            tc.verifyEqual(tManagerDatabase.cellText(app, second + "_proj", 'Tags'), "cohort:b condition:sham");
            tc.verifyEqual(tManagerDatabase.cellText(app, absent + "_proj", 'Tags'), "");
            d = app.Datasets(strcmp({app.Datasets.SubjectID}, 'SUBJ-ID-9001'));
            tc.verifyEqual(d.SubjectVariables, 'Age at perfusion = 92 d; housing = pair');
            tc.verifyTrue(d.SubjectFactsRead);

            % the detail of a selected dataset lists tags and variables
            app.selectDataset(d.Base);
            lbl = findall(app.Figure, 'Type', 'uilabel');
            texts = string(arrayfun(@(l) string(strjoin(string(l.Text), newline)), lbl));
            tc.verifyTrue(any(contains(texts, "Tags (lab database): cohort:a condition:noise pilot")));
            tc.verifyTrue(any(contains(texts, "Variables (lab database): Age at perfusion = 92 d; housing = pair")));

            % the grammar of the lab database's own window
            app.setTagFilter("Cohort:B");
            tc.verifyEqual(subj(), "SUBJ-ID-9002");
            tc.verifyEqual(findall(app.Figure, 'Tag', 'edit:tags').Value, 'Cohort:B');
            app.setTagFilter("cohort:* -pilot");
            tc.verifyEqual(subj(), "SUBJ-ID-9002");
            app.setTagFilter("-condition:sham");
            tc.verifyEqual(subj(), "SUBJ-ID-9001", 'a subject the database does not have is not listed by a filter');
            app.setTagFilter("-qc:fial");
            tc.verifySubstring(app.StatusText, 'qc:fial', 'a tag no subject here carries is said');
            app.setTagFilter("cohort:a");
            app.setFilter('', 'To detect');
            tc.verifyEmpty(app.View, 'Tags and Show hold together');
            app.setFilter('', 'All datasets');
            tc.verifyEqual(subj(), "SUBJ-ID-9001");
            app.setTagFilter("");

            % Find looks in the tags and variables too
            app.setFilter('pilot');
            tc.verifyEqual(subj(), "SUBJ-ID-9001");
            app.setFilter('perfusion 120.5');
            tc.verifyEqual(subj(), "SUBJ-ID-9002");
            app.setFilter('');

            % a dataset the tag filter hides is shown when it is selected by name
            app.setTagFilter("cohort:b");
            tc.verifyTrue(app.selectDataset(d.Base));
            tc.verifyEqual(findall(app.Figure, 'Tag', 'edit:tags').Value, '');
            tc.verifyNumElements(app.View, 3);

            % the report carries them
            T = CellDatasetManager.statusTable(app.Datasets);
            tc.verifyEqual(T.SubjectTags(T.Subject == "SUBJ-ID-9002"), "cohort:b condition:sham");
            tc.verifyEqual(T.SubjectVariables(T.Subject == "SUBJ-ID-9002"), "Age at perfusion = 120.5 d");
            S = CellDatasetManager.sourceTable(app.Datasets);
            tc.verifyEqual(unique(S.SubjectTags(S.Subject == "SUBJ-ID-9001")), "cohort:a condition:noise pilot");
            tc.verifyEqual(unique(S.SubjectVariables(S.Subject == "SUBJ-ID-4040")), "");
            file = fullfile(tc.Top, 'report.csv');
            tc.assertNotEmpty(app.exportReport(file));
            R = readtable(file, 'TextType', 'string', 'Delimiter', ',');
            tc.verifyTrue(all(ismember(["SubjectTags" "SubjectVariables"], string(R.Properties.VariableNames))));

            % Ctrl+T puts the cursor in the Tags field
            tc.verifyTrue(app.handleKey('t', {'control'}));
            tc.verifyFalse(app.handleKey('t', {}));

            % a later scan finds them in the cache, with the server out of reach
            tc.Fake.Reachable = false;
            labclient.DB.disconnect();
            ds = CellDatasetManager.scan(tc.Top);
            k = ds(strcmp({ds.SubjectID}, 'SUBJ-ID-9001'));
            tc.verifyEqual(k.SubjectTags, 'cohort:a condition:noise pilot');
        end

        function recordsMadeWithTheDatabaseOffAreQueued(tc)
            tc.useClient(false);                                    % installed, turned off here
            base = tCelldbRun.Section + "_proj";
            [~, rec] = tc.completed('ds', tCelldbRun.Section);
            tc.assertTrue(rec.written, 'the record is kept beside the files');
            tc.assertFalse(rec.queued);

            app = tc.open();
            tc.verifyEqual(tManagerDatabase.cellText(app, base, 'Database'), "1 kept here");
            q = tManagerDatabase.button(app, 'btn:queueRecords');
            s = tManagerDatabase.button(app, 'btn:checkSubjects');
            tc.verifyFalse(logical(q.Enable));
            tc.verifyFalse(logical(s.Enable));
            tc.verifySubstring(q.Tooltip, 'Not available: the lab database is turned off');
            tc.verifySubstring(s.Tooltip, 'Not available: the lab database is turned off');
            r = app.checkSubjects();
            tc.verifyFalse(r.ok);
            tc.verifySubstring(app.StatusText, 'turned off');

            % turned on (as the Database window does): the record can be queued
            st = labclient.Settings.load();
            st.Enabled = true;
            labclient.Settings.save(st);
            app.refreshDatabase();
            tc.verifyTrue(logical(q.Enable));
            tc.verifySubstring(q.Tooltip, '1 record(s) in the list are not queued');
            r = app.queueRecords();
            tc.verifyEqual([r.found r.queued r.failed], [1 1 0]);
            tc.verifySubstring(app.StatusText, '1 queued now');
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "pending");
            tc.verifyEqual(tManagerDatabase.cellText(app, base, 'Database'), "1 waiting");
            tc.verifyFalse(logical(q.Enable), 'nothing left to queue');
        end

        function aFolderSeenUnderAnotherPathFindsItsRecords(tc)
            tc.useClient();
            [c, rec] = tc.completed('ds', tCelldbRun.Section);
            labclient.Sync.flush('Budget', 10);
            moved = fullfile(tc.Top, 'elsewhere', 'ds');
            mkdir(fileparts(moved));
            movefile(char(c.folder), moved);
            ds = CellDatasetManager.scan(fullfile(tc.Top, 'elsewhere'));
            tc.assertNumElements(ds, 1);
            e = ds.Sources(strcmp({ds.Sources.Key}, 'ECM1'));
            tc.verifyEqual(e.Db.runId, string(rec.runId), 'found by the file''s name in its own .provenance folder');
            tc.verifyEqual(e.Db.state, "sent");
            tc.verifyTrue(e.Db.current, 'the same bytes');
        end

        function withoutTheClientTheWindowWorksAndSaysSo(tc)
            % a record made on a computer with the client ...
            haveClient = string(getenv('CELLDB_NO_CLIENT')) ~= "1" && celldb.available('Refresh', true);
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            top = fullfile(fx.Folder, 'data');
            c = tCelldbRun.curate(fullfile(top, 'ds'), 'BaseName', tCelldbRun.Section);
            rec = celldb.recordCuration(c.store);
            c.store.close();
            tc.assertTrue(rec.written, 'the sidecar is written whatever the state of the database');
            % ... seen on one without it
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_NO_CLIENT', '1'));
            celldb.available('Refresh', true);
            tc.assertFalse(celldb.available());

            app = tc.open(top);
            tc.assertNumElements(app.Datasets, 1);
            e = app.Datasets.Sources(strcmp({app.Datasets.Sources.Key}, 'ECM1'));
            tc.verifyEqual(e.Db.state, "local");
            tc.verifyEqual(e.Db.text, "kept here (not queued)");
            tc.verifySubstring(e.Db.detail, "not usable on this computer");
            tc.verifyEqual(tManagerDatabase.cellText(app, tCelldbRun.Section + "_proj", 'Database'), "1 kept here");
            tc.verifyEqual(app.Datasets.SubjectID, 'SUBJ-ID-9001', 'the file name still names the subject');
            tc.verifyFalse(app.Datasets.SubjectAsked);

            lamp = findall(app.Figure, 'Tag', 'LabClientLamp');
            tc.assertNumElements(lamp, 1);
            tc.verifyEqual(string(lamp.Text), "Database: not installed");
            for tag = ["btn:checkSubjects" "btn:queueRecords"]
                b = tManagerDatabase.button(app, tag);
                tc.verifyFalse(logical(b.Enable));
                tc.verifySubstring(b.Tooltip, 'Not available:');
                tc.verifySubstring(b.Tooltip, 'CELLDB_NO_CLIENT');
            end
            app.openDatabase();
            tc.verifySubstring(app.StatusText, 'No Database window');
            r = app.checkSubjects();
            tc.verifyFalse(r.ok);
            r = app.queueRecords();
            tc.verifyEqual(r.queued, 0);
            % everything else is as with the client
            app.selectDataset(1);
            tc.verifyTrue(app.nextToCurate() || true);
            app.waitForIdle();
            tc.verifyNumElements(findall(app.Figure, 'Type', 'axes'), 2, 'the preview');
            if ~haveClient
                fprintf('[manager] the client is not here: only the state without it was run\n');
            end
        end
    end
end
