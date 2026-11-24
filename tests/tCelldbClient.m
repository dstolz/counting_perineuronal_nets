classdef tCelldbClient < matlab.unittest.TestCase
%tCelldbClient  celldb with the lab database client: curation records reach the outbox and are sent once.
%
%   Needs the labclient package (a CarasLabDB checkout with +labclient of interface version 3 or later,
%   found through CARASLABDB_DIR or beside this repository); skipped without it, and when
%   CELLDB_NO_CLIENT=1 (tools\Run-Tests.ps1 -WithoutClient). Everything runs against labclient.FakeBackend
%   in a temporary preference store, a fake vault and a temporary client folder: no server is contacted
%   and nothing of the user's is touched (the last test, and the class teardown, prove it).
%
%   Run: pwsh -File tools\Run-Tests.ps1 tCelldbClient

    properties
        Fake
        Restore = {}
        Top string
        Fallback string
        RealClient struct   % the user's own client state before the class ran
    end

    methods (TestClassSetup)
        function needTheClient(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(here, 'fixtures')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
            % before anything is isolated: what the user's real client holds
            tc.RealClient = tCelldbClient.realState();
            tc.addTeardown(@() tc.verifyRealStateUnchanged("after the whole class"));
            [ok, why] = celldb.available(Refresh = true);
            tc.assumeTrue(ok, "The lab database client is not usable here: " + why);
        end
    end

    methods (TestMethodSetup)
        function isolate(tc)
            tc.Fallback = string(tempname);
            old = string(getenv("CELLDB_PROVENANCE_DIR"));
            setenv("CELLDB_PROVENANCE_DIR", char(tc.Fallback));
            [tc.Fake, tc.Restore, tc.Top] = celldb_test_client();
            tc.addTeardown(@() tc.cleanUp(old));
        end
    end

    methods
        function cleanUp(tc, oldFallback)
            for k = numel(tc.Restore):-1:1
                tc.Restore{k} = [];
            end
            tc.Restore = {};
            setenv("CELLDB_PROVENANCE_DIR", char(oldFallback));
            for f = [tc.Top, tc.Fallback]
                if isfolder(f); rmdir(f, "s"); end
            end
        end

        function c = curated(tc, opts)
            arguments
                tc
                opts.BaseName (1,1) string = tCelldbRun.Section
                opts.Folder (1,1) string = "ds"
            end
            c = tCelldbRun.curate(fullfile(tc.Top, opts.Folder), BaseName = opts.BaseName);
            tc.addTeardown(@() c.store.close());
        end

        function verifyRealStateUnchanged(tc, when)
            now = tCelldbClient.realState(tc.RealClient.folder);
            tc.verifyEqual(now, tc.RealClient, "the user's own client state changed " + when);
        end
    end

    methods (Static)
        function s = realState(base)
            %REALSTATE The user's real client folder (listed, not created), and their preference group.
            %   BASE is the folder; left out, where the client keeps it when nothing is isolated.
            if nargin < 1
                base = string(getenv("CARASLABDB_CLIENT_DIR"));
                if base == ""
                    base = string(fullfile(getenv("LOCALAPPDATA"), "caraslabdb", "client"));
                end
            end
            files = strings(0, 1);
            if isfolder(base)
                d = dir(fullfile(base, "**", "*"));
                d = d(~[d.isdir]);
                files = string(fullfile({d.folder}, {d.name}))' + "|" + string([d.bytes])' + "|" + string([d.datenum])';
                files = sort(files);
            end
            s = struct("folder", base, "exists", isfolder(base), "files", files, ...
                "prefs", ispref("CarasLabDBClient"));
        end
    end

    methods (Test)
        function aCompletedSourceIsQueuedOnceAndSentOnce(tc)
            c = tc.curated();
            rec = celldb.recordCuration(c.store);
            tc.verifyTrue(rec.written);
            tc.verifyTrue(rec.queued);
            tc.verifyEqual(rec.reason, "Recorded for the lab database (will be sent when it is reachable)");
            cnt = labclient.Outbox.counts();
            tc.verifyEqual([cnt.pending cnt.held cnt.failed cnt.done], [1 0 0 0], "exactly one bundle");
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "pending");
            [b, ~] = labclient.Outbox.read(rec.runId);
            tc.verifyTrue(labclient.Bundles.isSealed(b));
            tc.verifyEqual(b.record.event.event_type, "analysis");
            tc.verifyEqual(string(b.record.event.detail.pipeline_name), "counting_perineuronal_nets/curate");

            labclient.Sync.flush(Budget = 10);
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "done");
            tc.verifyNumElements(tc.Fake.Events, 1);
            e = tc.Fake.Events(1);
            tc.verifyEqual(string(e.event_id), rec.runId);
            tc.verifyEqual(string(e.event_type), "analysis");
            tc.verifyEqual(string(e.subject_id), "SUBJ-ID-9001");
            tc.verifyEqual(string(e.detail.pipeline_name), "counting_perineuronal_nets/curate");
            tc.verifyEqual(string(e.detail.code_version), celldb.codeVersion());
            a = jsondecode(char(e.attributes));
            counts = c.store.counts();
            for f = string(fieldnames(counts))'
                tc.verifyEqual(a.(f), counts.(f), "attribute " + f);
            end
            tc.verifyEqual(string(a.app), "CellCurator");
            tc.verifyEqual(string(a.image_key), tCelldbRun.Section + "_proj");
            tc.verifyEqual(string(a.hemisphere), "L");
            tc.verifyTrue(a.complete);

            A = tc.Fake.Artifacts;
            tc.verifyEqual(height(A), 2, "the two output files");
            tc.verifyEqual(sort(string(A.relative_path)), ...
                sort(["ds/" + stemOf(c.store.Paths.csv); "ds/" + stemOf(c.store.Paths.final)]));
            tc.verifyTrue(all(A.role == "derived"));
            tc.verifyEqual(sort(string(A.checksum)), sort(string([tCelldbRun.sha256(c.store.Paths.csv); ...
                tCelldbRun.sha256(c.store.Paths.final)])));
            tc.verifyTrue(all(A.produced_by_event_id == rec.runId));

            again = celldb.recordCuration(c.store);
            tc.verifyFalse(again.written, "nothing changed: no second event");
            labclient.Sync.flush(Budget = 10);
            tc.verifyNumElements(tc.Fake.Events, 1);
        end

        function sendingAgainIsExistingNotADuplicate(tc)
            c = tc.curated();
            rec = celldb.recordCuration(c.store);
            labclient.Sync.flush(Budget = 10);
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "done");
            delete(labclient.Outbox.file(rec.runId, "done"));     % as if it had never been sent from here
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "");
            r = celldb.backfill(tc.Top);
            tc.verifyEqual([r.found r.queued r.already r.failed], [1 1 0 0]);
            labclient.Sync.flush(Budget = 10);
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "done");
            n = labclient.Outbox.note(rec.runId, "done");
            tc.verifySubstring(string(n.reason), "already in the database");
            tc.verifyNumElements(tc.Fake.Events, 1);
            tc.verifyEqual(height(tc.Fake.Artifacts), 2);
        end

        function aChangedSourceIsASecondEventThatReplacesTheFiles(tc)
            c = tc.curated();
            first = celldb.recordCuration(c.store);
            labclient.Sync.flush(Budget = 10);
            tCelldbRun.relabel(c, 11);
            second = celldb.recordCuration(c.store);
            tc.verifyTrue(second.written);
            labclient.Sync.flush(Budget = 10);
            tc.verifyEqual(labclient.Outbox.stateOf(second.runId), "done");
            tc.verifyNumElements(tc.Fake.Events, 2);
            D = tc.Fake.Dispositions;
            tc.verifyEqual(height(D), 2, "both files of the first event are marked replaced");
            tc.verifyTrue(all(D.disposition == "replaced"));
            tc.verifyTrue(all(ismember(D.artifact_id, tc.Fake.Artifacts.artifact_id(tc.Fake.Artifacts.produced_by_event_id == first.runId))));
        end

        function aSubjectTheDatabaseLacksHoldsTheRecord(tc)
            c = tc.curated(BaseName = "SUBJ-ID-4040IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1");
            rec = celldb.recordCuration(c.store);
            tc.verifyTrue(rec.queued);
            labclient.Sync.flush(Budget = 10);
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "held");
            n = labclient.Outbox.note(rec.runId, "held");
            tc.verifySubstring(lower(string(n.reason)), "subject");
            tc.verifySubstring(string(n.reason), "SUBJ-ID-4040");
            tc.verifyEmpty(tc.Fake.Events);
        end

        function aNameThatDoesNotFitIsAnEventWithNoSubject(tc)
            c = tc.curated(BaseName = "SYN-0001_sec1");
            rec = celldb.recordCuration(c.store);
            tc.verifyTrue(rec.queued);
            labclient.Sync.flush(Budget = 10);
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "done");
            tc.verifyNumElements(tc.Fake.Events, 1);
            tc.verifyEqual(string(tc.Fake.Events(1).subject_id), "");
            a = jsondecode(char(tc.Fake.Events(1).attributes));
            tc.verifyEqual(string(a.image_key), "SYN-0001_sec1_proj");
        end

        function anUnreachableServerLeavesItWaitingAndNeverBlocks(tc)
            tc.Fake.Reachable = false;
            c = tc.curated();
            t = tic;
            rec = celldb.recordCuration(c.store);
            secs = toc(t);
            fprintf('[timing] recording with the server unreachable: %.0f ms (limit 3000)\n', 1000 * secs);
            tc.verifyLessThan(secs, 3, "recording never waits for the server");
            tc.verifyTrue(rec.written);
            tc.verifyTrue(rec.queued);
            tc.verifySubstring(celldb.statusText(), "1 record(s) waiting");
            labclient.Sync.flush(Budget = 2);
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "pending");
            tc.verifyEmpty(tc.Fake.Events);
        end

        function backfillQueuesWhatWasKeptWhileOffAndOnlyOnce(tc)
            s = labclient.Settings.load();
            s.Enabled = false;
            labclient.Settings.save(s);
            c = tc.curated();
            rec = celldb.recordCuration(c.store);
            tc.verifyTrue(rec.written);
            tc.verifyFalse(rec.queued);
            tc.verifySubstring(rec.reason, "turned off");
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "", "the database was off: kept on disk only");
            tc.verifySubstring(celldb.statusText(), "turned off");

            s.Enabled = true;
            labclient.Settings.save(s);
            r = celldb.backfill(tc.Top);
            tc.verifyEqual([r.found r.queued r.already r.failed], [1 1 0 0]);
            r = celldb.backfill(tc.Top);
            tc.verifyEqual([r.found r.queued r.already], [1 0 1]);
            labclient.Sync.flush(Budget = 10);
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "done");
            tc.verifyNumElements(tc.Fake.Events, 1);
        end

        function theSameRecordQueuedTwiceIsOneRecord(tc)
            c = tc.curated();
            rec = celldb.recordCuration(c.store);
            tc.verifyEqual(celldb.enqueue(rec.file), "unchanged");
        end

        function anUnreadableRecordIsNotQueuedAndDoesNotThrow(tc)
            c = tc.curated();
            rec = celldb.recordCuration(c.store);
            tc.verifyWarning(@() tc.verifyEqual(celldb.enqueue("no such file.json"), "failed"), "celldb:Provenance");
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "pending");
        end

        function theStatusSentenceFollowsTheOutbox(tc)
            tc.verifySubstring(celldb.statusText(), "nothing waiting");
            c = tc.curated();
            celldb.recordCuration(c.store);
            tc.verifySubstring(celldb.statusText(), "1 record(s) waiting");
        end

        function theRealClientStateIsNotTouched(tc)
            c = tc.curated();
            rec = celldb.recordCuration(c.store);
            labclient.Sync.flush(Budget = 10);
            tc.verifyEqual(labclient.Outbox.stateOf(rec.runId), "done");
            tc.verifyTrue(startsWith(string(labclient.Outbox.root()), string(tempdir)) || ...
                contains(string(labclient.Outbox.root()), string(getenv("CARASLABDB_CLIENT_DIR"))), ...
                "the outbox of this test is a temporary one");
            tc.verifyRealStateUnchanged("during the class");
        end
    end
end

function n = stemOf(f)
[~, name, ext] = fileparts(f);
n = string(name) + string(ext);
end
