classdef FakeRescoreJob < handle
    %FakeRescoreJob  A stand-in for curation.Rescore.run in window tests (no Python): it records the
    %   cells and positions it was given, "runs" for DelaySec and then succeeds with a score per cell
    %   (rescore = 1 + X / 1000), keyed by CellID as curation.Rescore's Result is.
    %
    %   job = FakeRescoreJob.run(stores, opts, delaySec)   use as RunFcn = @(s, o) FakeRescoreJob.run(s, o, 0.3)
    %   FakeRescoreJob.last()                              the job made last (persistent)

    properties
        Result table = table()
        Error string = ""
        Log string = strings(0, 1)
        DelaySec double = 0
        Opts struct = struct()
        Fail logical = false
    end

    properties (Dependent)
        State
    end

    properties (Access = private)
        T0
        Canceled logical = false
    end

    methods (Static)
        function job = run(stores, opts, delaySec, fail)
            if nargin < 3, delaySec = 0; end
            if nargin < 4, fail = false; end
            job = FakeRescoreJob();
            job.DelaySec = delaySec;
            job.Opts = opts;
            job.Fail = fail;
            job.T0 = tic;
            s = stores{1};
            ids = opts.Ids{1};
            ids = ids(:);
            rows = s.rowsOf(ids);
            X = s.T.X(rows); Y = s.T.Y(rows);
            n = numel(ids);
            [~, nm] = fileparts(char(opts.Model));
            job.Result = table(ones(n, 1), repmat(string(s.Meta.Key), n, 1), double(ids), 1 + X / 1000, X, Y, ...
                X * 2.569, Y * 2.569, repmat(string(opts.Model), n, 1), repmat("img001.h5", n, 1), ...
                'VariableNames', {'Store', 'Key', 'CellID', 'Rescore', 'X', 'Y', 'Xp', 'Yp', 'Model', 'Image'});
            job.Log = "fake score.py with " + string(nm);
            FakeRescoreJob.last(job);
        end

        function j = last(set)
            persistent L
            if nargin > 0, L = set; end
            j = L;
        end
    end

    methods
        function s = get.State(job)
            if job.Canceled
                s = "canceled";
            elseif toc(job.T0) < job.DelaySec
                s = "running";
            elseif job.Fail
                s = "failed";
            else
                s = "succeeded";
            end
        end

        function cancel(job)
            job.Canceled = true;
        end
    end

    methods (Access = private)
        function job = FakeRescoreJob()
        end
    end
end
