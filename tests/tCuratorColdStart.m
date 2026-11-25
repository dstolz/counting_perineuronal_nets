classdef (TestTags = {'Slow', 'RealData', 'Benchmark'}) tCuratorColdStart < matlab.unittest.TestCase
    %tCuratorColdStart  How long CellCurator takes to open the first time in a MATLAB session.
    %   Meaningful only when run ALONE, so that the app is the first window of the session:
    %       tools\Run-Tests.ps1 -IncludeSlow tCuratorColdStart
    %   The other benchmarks measure a warm session; this one measures what a person waits for
    %   after starting MATLAB. It opens a temporary copy of the local real sections
    %   (%LOCALAPPDATA%\counting_perineuronal_nets\real_sections; skipped when absent), first
    %   paying for MATLAB's own first window, then timing CellCurator(folder) to the first page.
    %   Set CURATOR_COLD_PROFILE=1 to print the profiler's most expensive functions instead of
    %   checking the budget (the profiler slows the run).

    properties (Constant)
        % CellCurator(folder) -> first page drawn, after MATLAB's first window. Measured 11.0 s on
        % 2026-11-25 (13.2 s before the keyboard focus was deferred and the file time stamp stopped
        % calling Java). What is left is mostly code MATLAB loads the first time it is used: about
        % 150 UI components (4 s), the table import behind readtable (1.5 s), the first window of
        % the session. The budget is a guard against getting slower, not a target.
        BudgetMs = 14000
    end

    methods (Test)
        function firstOpenOfTheSession(tc)
            master = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'real_sections');
            tc.assumeTrue(isfolder(master), 'no local copy of real sections here');
            figsBefore = findall(groot, 'Type', 'figure');
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            folder = fullfile(fx.Folder, 'real_sections');
            copyfile(master, folder);
            profiling = strcmp(getenv('CURATOR_COLD_PROFILE'), '1');

            t0 = tic;
            f = uifigure('Visible', 'off');
            uibutton(f);
            drawnow;
            delete(f);
            tFig = 1000 * toc(t0);
            fprintf('\n[cold] windows open before this test: %d\n', numel(figsBefore));
            fprintf('[cold] MATLAB''s first (hidden, empty) uifigure: %.0f ms\n', tFig);

            if profiling, profile clear; profile on; end
            t1 = tic;
            app = CellCurator(folder, 'UseSettings', false);
            tc.addTeardown(@() tCuratorColdStart.closeApp(app));
            tCtor = 1000 * toc(t1);
            drawnow;
            tDrawn = 1000 * toc(t1);
            if profiling, profile off; end
            fprintf('[cold] CellCurator(folder) returned after %.0f ms; first page drawn after %.0f ms\n', tCtor, tDrawn);
            L = app.LastTimings;
            names = fieldnames(L);
            for i = 1:numel(names)
                v = L.(names{i});
                if isnumeric(v) && isscalar(v)
                    fprintf('[cold]   %-20s %8.0f\n', names{i}, v);
                end
            end
            tc.verifyNotEmpty(app.Store, 'a source is open');

            if profiling
                S = profile('info');
                T = struct2table(S.FunctionTable);
                T = sortrows(T(:, {'FunctionName', 'NumCalls', 'TotalTime'}), 'TotalTime', 'descend');
                self = zeros(height(T), 1);
                [~, order] = sort([S.FunctionTable.TotalTime], 'descend');
                for i = 1:height(T)
                    ft = S.FunctionTable(order(i));
                    kids = 0;
                    if ~isempty(ft.Children), kids = sum([ft.Children.TotalTime]); end
                    self(i) = ft.TotalTime - kids;
                end
                T.SelfTime = self;
                fprintf('[cold] --- by total time (s) ---\n');
                for i = 1:min(45, height(T))
                    fprintf('[cold] %7.2f  self %6.2f  x%-6d %s\n', T.TotalTime(i), T.SelfTime(i), T.NumCalls(i), T.FunctionName{i});
                end
                T2 = sortrows(T, 'SelfTime', 'descend');
                fprintf('[cold] --- by self time (s) ---\n');
                for i = 1:min(35, height(T2))
                    fprintf('[cold] %7.2f  x%-6d %s\n', T2.SelfTime(i), T2.NumCalls(i), T2.FunctionName{i});
                end
            else
                tc.verifyLessThanOrEqual(tDrawn, tc.BudgetMs, sprintf( ...
                    'the first CellCurator of a MATLAB session took %.0f ms to its first page (budget %d ms)', ...
                    tDrawn, tc.BudgetMs));
            end
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end
    end
end
