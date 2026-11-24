classdef tStoreLockReads < matlab.unittest.TestCase
%tStoreLockReads  (integration pass C, review finding e) curation.Store reads its lock file at most
%   every 2 s before a journal append (it read it on EVERY commit: one synchronous file read per
%   label key, a network round trip on the NAS), always before a snapshot write, and a takeover is
%   still seen: at once by another store of this MATLAB, within 2 s otherwise.
%
%   Run: pwsh -File tools\Run-Tests.ps1 tStoreLockReads

    properties
        Dir char = ''
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = tmp.Folder;
        end
    end

    methods (Test)
        function labelKeysReadTheLockRarely(tc)
            s = tc.openP(tc.locs('secL_proj_ECM1', 160));
            ids = s.T.CellID;
            r0 = s.LockReads;
            t0 = tic;
            for k = 1:150
                s.setLabel(ids(k), "Good", "human");
            end
            secs = toc(t0);
            n = s.LockReads - r0;
            fprintf('[lock] 150 setLabel calls in %.2f s read the lock file %d times\n', secs, n);
            tc.verifyLessThanOrEqual(n, 1 + ceil(secs / curation.Store.LOCK_CHECK_SEC), ...
                'at most one read per 2 s of label keys');
            r1 = s.LockReads;
            s.flush();
            tc.verifyGreaterThan(s.LockReads, r1, 'a snapshot write always reads the lock');
        end

        function aTakeoverIsStillSeen(tc)
            p = tc.locs('secT_proj_ECM1', 5);
            a = tc.openP(p);
            a.setLabel(1, "Good");                      % the lock was just read
            b = tc.openP(p, struct('Force', true));      % another store of this MATLAB takes it
            tc.assertFalse(b.ReadOnly);
            tc.verifyError(@() a.setLabel(2, "Good"), 'curation:Store:lockLost', 'seen at once');
            tc.verifyEqual(a.get('Label', 2), "");
            % another process: the file changes behind the store's back; seen within 2 s, and at the
            % latest by the snapshot write
            q = tc.locs('secU_proj_ECM1', 5);
            c = tc.openP(q);
            c.setLabel(1, "Good");
            lockPath = c.Paths.lock;
            fid = fopen(lockPath, 'w');
            fwrite(fid, jsonencode(struct('host', 'elsewhere', 'user', 'other', 'pid', 1, ...
                'time', char(curation.AtomicIO.isoNow(true)), 'session', 'other-process')));
            fclose(fid);
            pause(curation.Store.LOCK_CHECK_SEC + 0.2);
            tc.verifyError(@() c.setLabel(2, "Good"), 'curation:Store:lockLost', 'seen after 2 s');
        end
    end

    methods (Access = private)
        function p = locs(tc, stem, n)
            x = 50 * (1:n)';
            L = table(x, 100 + 0 * x, zeros(n, 1), rand(n, 1), repmat("img.tif", n, 1), zeros(n, 1), ...
                randn(n, 1), 'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
            p = fullfile(tc.Dir, [stem '_locs.csv']);
            writetable(L, p);
        end

        function s = openP(tc, path, opts)
            if nargin < 3, opts = struct(); end
            opts.AutosaveDelay = 0;
            opts.Reviewer = 'tester';
            s = curation.Store.openCsv(path, opts);
            tc.addTeardown(@() closeQuiet(s));
        end
    end
end

function closeQuiet(s)
try
    if isvalid(s), s.close(); end
catch
end
end
