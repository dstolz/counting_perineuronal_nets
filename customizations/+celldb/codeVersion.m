function [version, info] = codeVersion(opts)
%CELLDB.CODEVERSION This repository's git commit, "-dirty" with uncommitted changes.
%   v = celldb.codeVersion()                 % e.g. "1936760" or "1936760-dirty"
%   [v, info] = celldb.codeVersion()         % info: Commit, Branch, Dirty, Text, MatlabRelease, Root
%   v = celldb.codeVersion(Refresh = true)   % ask git again
%
% A result is only as reproducible as the code that made it is identifiable.
% The answer is kept for the MATLAB session (git costs a few hundred
% milliseconds, and the working tree changes while a person curates; the
% commit is what the session started on, "-dirty" if it already differed).
% The repository is the one this file is in. Never an error: without git, or
% outside a git checkout, the version is "unknown".
%
% See also CELLDB.RUN.

arguments
    opts.Refresh (1,1) logical = false
end

persistent cache

if opts.Refresh
    cache = [];
end

if isempty(cache)
    cache = ask();
end
info = cache;
version = info.Version;

end

function info = ask()
root = string(fileparts(fileparts(fileparts(mfilename("fullpath")))));
info = struct("Version", "unknown", "Commit", "", "Branch", "", "Dirty", false, ...
    "Text", "unknown (not a git checkout, or git is not installed)", ...
    "MatlabRelease", releaseText(), "Root", root);
try
    hash = gitOutput(root, "rev-parse --short HEAD");
    if hash == ""
        return
    end
    info.Commit = hash;
    info.Version = hash;
    info.Text = hash;
    branch = gitOutput(root, "rev-parse --abbrev-ref HEAD");
    if branch ~= "" && branch ~= "HEAD"
        info.Branch = branch;
        info.Text = info.Text + " on " + branch;
    end
    info.Dirty = gitOutput(root, "status --porcelain") ~= "";
    if info.Dirty
        info.Version = hash + "-dirty";
        info.Text = info.Text + " (with uncommitted changes)";
    end
catch
end
end

function out = gitOutput(root, args)
out = "";
try
    [status, raw] = system(sprintf('git -C "%s" %s', root, args));
catch
    return
end
if status ~= 0
    return
end
out = strtrim(string(raw));
end

function text = releaseText()
try
    R = matlabRelease;
    text = string(R.Release) + " " + string(R.Update);
catch
    text = string(version);
end
end
