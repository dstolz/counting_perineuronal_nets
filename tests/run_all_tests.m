function results = run_all_tests(names, opts)
%run_all_tests  Run the matlab.unittest tests in this folder (tests\t*.m).
%   run_all_tests                 runs every test class of this folder
%   run_all_tests(NAMES)          runs only the named classes (string array or cellstr). A name may be a
%                                 wildcard pattern ("tCuration*") or "Class/testMethod" for one test.
%
%   Options
%     ExcludeTag    string array of tags to leave out ("Slow", "Python", "Benchmark": tools\Run-Tests.ps1
%                   passes these unless -IncludeSlow; default none)
%     DialogWatch   true (default): a timer reports a dialog that waits for a person, one line
%                     [needs you] <dialog> "<window>" | asked by <fn> (<file>:<line>) | test <fn> (<file>:<line>)
%                   read by tools\Run-Tests.ps1, which then stops the run (exit 3)
%     DialogSec     seconds a dialog may wait before it is reported (default 30)
%     ResultsCSV    file to write one row per test to (default none)
%
%   Puts customizations and tests\fixtures on the path. Prints a final line
%     [results] tests=N passed=N failed=N incomplete=N seconds=S
%   (read by tools\Run-Tests.ps1) and returns the TestResult array. Raises an error at the end when a test
%   failed, so `matlab -batch` exits 1.
%
%   See also makeSyntheticDataset, tFixture.

arguments
    names (1,:) string = string.empty(1, 0)
    opts.ExcludeTag (1,:) string = string.empty(1, 0)
    opts.DialogWatch (1,1) logical = true
    opts.DialogSec (1,1) double {mustBePositive} = 30
    opts.ResultsCSV (1,1) string = ""
end

here = fileparts(mfilename('fullpath'));
repo = fileparts(here);
addpath(here);
addpath(fullfile(here, 'fixtures'));
addpath(fullfile(repo, 'customizations'));

suite = matlab.unittest.TestSuite.fromFolder(here);

if ~isempty(names)
    keep = false(1, numel(suite));
    for k = 1:numel(suite)
        full = string(suite(k).Name);                  % "tFixture/testFilesExist"
        cls = extractBefore(full, "/");
        if ismissing(cls); cls = full; end
        for n = names
            if contains(n, "/"); target = full; else; target = cls; end
            if contains(n, "*") || contains(n, "?")
                hit = ~isempty(regexp(target, "^" + regexptranslate('wildcard', n) + "$", 'once'));
            else
                hit = target == n;
            end
            keep(k) = keep(k) || hit;
        end
    end
    suite = suite(keep);
end
if ~isempty(opts.ExcludeTag)
    keep = true(1, numel(suite));
    for k = 1:numel(suite)
        keep(k) = ~any(ismember(string(suite(k).Tags), opts.ExcludeTag));
    end
    suite = suite(keep);
end
if isempty(suite)
    error('run_all_tests:NothingToRun', 'No test matches the names %s (excluded tags: %s).', ...
        strjoin(names, ", "), strjoin(opts.ExcludeTag, ", "));
end

runner = matlab.unittest.TestRunner.withTextOutput;
stopWatch = []; %#ok<NASGU>
if opts.DialogWatch
    stopWatch = startDialogWatch(opts.DialogSec, here);
end
tStart = tic;
R = runner.run(suite);
seconds = toc(tStart);
clear stopWatch

nTests = numel(R);
nFailed = nnz([R.Failed]);
nIncomplete = nnz([R.Incomplete] & ~[R.Failed]);   % assumption failures: skipped, not failed
nPassed = nnz([R.Passed]);

if opts.ResultsCSV ~= ""
    folder = fileparts(opts.ResultsCSV);
    if folder ~= "" && ~isfolder(folder); mkdir(folder); end
    T = table(string({R.Name})', [R.Passed]', [R.Failed]', [R.Incomplete]', [R.Duration]', ...
        'VariableNames', {'Test', 'Passed', 'Failed', 'Incomplete', 'Seconds'});
    writetable(T, char(opts.ResultsCSV));
    fprintf('Results: %s\n', opts.ResultsCSV);
end
fprintf('[results] tests=%d passed=%d failed=%d incomplete=%d seconds=%.1f\n', ...
    nTests, nPassed, nFailed, nIncomplete, seconds);
results = R;
if nFailed > 0
    error('run_all_tests:Failures', '%d of %d tests failed.', nFailed, nTests);
end
end


function stop = startDialogWatch(seconds, testsDir)
%startDialogWatch  A timer that reports a dialog waiting SECONDS or more for an answer.
%   Timers run while uiwait / waitfor wait, so the timer sees the waiting frames on the stack. A native
%   dialog that stops MATLAB's thread stops the timer too: the PowerShell runner finds those by window.
t = timer('Name', 'run_all_tests dialog watch', 'Period', 5, 'StartDelay', 5, ...
    'ExecutionMode', 'fixedSpacing', 'BusyMode', 'drop', 'ObjectVisibility', 'off', ...
    'TimerFcn', @(tm, ~) lookForDialog(tm, seconds, testsDir));
t.UserData = struct('Key', "", 'Since', 0, 'Told', false);
start(t);
stop = onCleanup(@() stopTimer(t));
end


function stopTimer(t)
%stopTimer  Stop and delete timer T (deleting a running timer warns).
if isvalid(t); stop(t); delete(t); end
end


function lookForDialog(tm, seconds, testsDir)
%lookForDialog  The watch's tick: print one [needs you] line per dialog that has waited SECONDS.
s = dbstack('-completenames');
names = string({s.name});
dialogs = ["uiconfirm" "questdlg" "inputdlg" "listdlg" "msgbox" "errordlg" "warndlg" "helpdlg" ...
    "uigetfile" "uiputfile" "uigetdir" "uisetcolor" "uisetfont"];
k = find(ismember(names, [dialogs "uiwait" "waitfor"]), 1, 'last');   % the outermost: what the code called
figs = findall(groot, 'Type', 'figure', 'Visible', 'on');
if isempty(k) || (~ismember(names(k), dialogs) && isempty(figs))
    tm.UserData = struct('Key', "", 'Since', 0, 'Told', false);
    return
end
caller = s(min(k + 1, numel(s)));
key = names(k) + "@" + caller.file + ":" + caller.line;
st = tm.UserData;
nowS = posixtime(datetime('now'));
if st.Key ~= key
    tm.UserData = struct('Key', key, 'Since', nowS, 'Told', false);
    return
end
if st.Told || nowS - st.Since < seconds; return; end
st.Told = true;
tm.UserData = st;
windows = "";
if ~isempty(figs); windows = " " + strjoin("""" + string({figs.Name}) + """", ", "); end
testPart = "";
inTests = startsWith(string({s.file}), string(testsDir)) & ~endsWith(string({s.file}), "run_all_tests.m");
j = find(inTests, 1, 'first');   % the test line nearest the dialog
if ~isempty(j); testPart = sprintf(' | test %s (%s:%d)', names(j), s(j).file, s(j).line); end
fprintf('\n[needs you] %s%s | asked by %s (%s:%d)%s\n', names(k), windows, caller.name, caller.file, caller.line, testPart);
end
