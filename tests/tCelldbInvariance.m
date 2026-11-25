classdef tCelldbInvariance < matlab.unittest.TestCase
%tCelldbInvariance  What the curation app writes does not depend on the state of the lab database.
%
%   The same curation (the same synthetic section, the same labels in the same order, marked complete)
%   is made in a fresh folder once with no client at all, as the reference, and once in each state:
%
%     absent       no client (CELLDB_NO_CLIENT=1)
%     disabled     the client here, the database turned off
%     unreachable  turned on, the server not answering
%     connected    turned on, the (fake) server answering
%
%   Then <stem>_curation.csv, <stem>_final.csv and store.counts() must be identical to the reference's, every
%   state keeps its provenance sidecar, and the outbox holds nothing (absent, disabled), waits (unreachable)
%   or has sent the record (connected). The client states need the labclient package and are skipped without it.
%
%   The only thing normalized before the files are compared byte for byte is the ReviewedAt column of
%   <stem>_curation.csv, which holds the time each label was set (an ISO 8601 time with its offset: it
%   differs between any two runs, and is replaced by "<time>"). Nothing else differs between two runs: the
%   reviewer is fixed, the synthetic detections come from a seed, and _final.csv, the journal's session id
%   (not compared) and the lock are not in either file.
%
%   Run: pwsh -File tools\Run-Tests.ps1 tCelldbInvariance

    properties (TestParameter)
        State = {"absent", "disabled", "unreachable", "connected"}
    end

    properties
        OldNoClient string
        OldFallback string
        Restore = {}
        Folders = strings(0, 1)
    end

    methods (TestClassSetup)
        function addPaths(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(here, 'fixtures')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
        end
    end

    methods (TestMethodSetup)
        function remember(tc)
            tc.OldNoClient = string(getenv("CELLDB_NO_CLIENT"));
            tc.OldFallback = string(getenv("CELLDB_PROVENANCE_DIR"));
            fallback = string(tempname);
            tc.Folders(end + 1) = fallback;
            setenv("CELLDB_PROVENANCE_DIR", char(fallback));
            tc.addTeardown(@() tc.cleanUp());
        end
    end

    methods
        function cleanUp(tc)
            for k = numel(tc.Restore):-1:1
                tc.Restore{k} = [];
            end
            tc.Restore = {};
            setenv("CELLDB_NO_CLIENT", char(tc.OldNoClient));
            setenv("CELLDB_PROVENANCE_DIR", char(tc.OldFallback));
            celldb.available(Refresh = true);
            for f = reshape(tc.Folders, 1, [])
                if isfolder(f); rmdir(f, "s"); end
            end
        end

        function [fake, top] = enter(tc, state)
            fake = [];
            if state == "absent"
                setenv("CELLDB_NO_CLIENT", "1");
                celldb.available(Refresh = true);
                top = string(tempname);
                mkdir(top);
                tc.Folders(end + 1) = top;
                return
            end
            % the client states: whatever CELLDB_NO_CLIENT the whole run was started with decides (skipped when 1)
            setenv("CELLDB_NO_CLIENT", char(tc.OldNoClient));
            [ok, why] = celldb.available(Refresh = true);
            tc.assumeTrue(ok, "The lab database client is not usable here: " + why);
            [fake, tc.Restore, top] = celldb_test_client(Enabled = state ~= "disabled");
            fake.Reachable = state ~= "unreachable";
            tc.Folders(end + 1) = top;
        end

        function leave(tc)
            for k = numel(tc.Restore):-1:1
                tc.Restore{k} = [];
            end
            tc.Restore = {};
        end

        function R = makeCuration(~, top)
            %CURATION The same curation in TOP: what it wrote, and the record.
            c = tCelldbRun.curate(fullfile(top, "ds"));
            closeStore = onCleanup(@() c.store.close());
            t = tic;
            rec = celldb.recordCuration(c.store);
            R.elapsed = toc(t);
            R.rec = rec;
            R.counts = c.store.counts();
            R.curationCsv = normalize(string(fileread(c.store.Paths.csv)));
            R.finalCsv = string(fileread(c.store.Paths.final));
            R.finalName = fileSuffix(c.store.Paths.final);
            R.records = dir(fullfile(top, "ds", ".provenance", "*.json"));
        end
    end

    methods (Test)
        function whatTheAppWritesDoesNotDependOnTheDatabase(tc, State)
            tc.enter("absent");
            refTop = string(tempname);
            tc.Folders(end + 1) = refTop;
            ref = tc.makeCuration(refTop);
            tc.leave();

            [fake, top] = tc.enter(State);
            got = tc.makeCuration(top);

            tc.verifyEqual(got.curationCsv, ref.curationCsv, "<stem>_curation.csv, byte for byte (ReviewedAt normalized)");
            tc.verifyEqual(got.finalCsv, ref.finalCsv, "<stem>_final.csv, byte for byte");
            tc.verifyEqual(got.finalName, ref.finalName);
            tc.verifyEqual(got.counts, ref.counts, "store.counts()");
            tc.verifyGreaterThan(got.counts.good, 0);
            tc.verifyTrue(got.rec.written, "the sidecar is kept in every state");
            tc.verifyNumElements(got.records, 1);
            tc.verifyNumElements(ref.records, 1);

            switch State
                case "absent"
                    tc.verifyFalse(celldb.capturing());
                    tc.verifyFalse(got.rec.queued);
                case "disabled"
                    c = labclient.Outbox.counts();
                    tc.verifyEqual(c.pending + c.held + c.failed + c.done, 0, "nothing kept for the database");
                    tc.verifyFalse(got.rec.queued);
                case "unreachable"
                    fprintf('[timing] recording with the server unreachable: %.0f ms (limit 3000)\n', 1000 * got.elapsed);
                    tc.verifyLessThan(got.elapsed, 3, "recording never waits for the server");
                    labclient.Sync.flush(Budget = 2);
                    c = labclient.Outbox.counts();
                    tc.verifyEqual(c.pending, 1, "the record waits in the outbox");
                    tc.verifyTrue(got.rec.queued);
                case "connected"
                    labclient.Sync.flush(Budget = 20);
                    c = labclient.Outbox.counts();
                    tc.verifyEqual([c.done c.pending c.held c.failed], [1 0 0 0], "the record was sent");
                    tc.verifyNumElements(fake.Events, 1);
            end
            tc.leave();
        end
    end
end

function t = normalize(t)
%NORMALIZE The curation snapshot with the times of the labels (ReviewedAt) replaced: nothing else.
t = regexprep(t, "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?([+-]\d\d:\d\d|Z)", "<time>");
end

function n = fileSuffix(f)
[~, n, e] = fileparts(f);
n = regexprep(string(n) + string(e), "^.*(_[A-Z]+\d+_final\.csv)$", "$1");
end
