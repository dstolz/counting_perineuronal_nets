classdef AtomicIO
%ATOMICIO  Crash-safe file writes and the small text codecs the curation files share.
%
%   Every file the curation store writes goes through writeText: the text goes to a temporary
%   file in the same folder ('.<name>.<random>.tmp'), is closed, and then replaces the target in
%   one step (Win32 ReplaceFile through .NET File.Replace when the target exists, else a rename).
%   A reader therefore sees either the old file or the new one, never a truncated one. When the
%   one-step replace is unavailable (no .NET, a share that refuses it) the fallback is
%   movefile(tmp, target, 'f'), which may delete-then-rename; the temporary file is kept until
%   the target is in place, so a crash can leave a stray '.tmp' but never an empty target.
%
%   Static methods
%     curation.AtomicIO.writeText(path, txt)     write char/string text as UTF-8, atomically
%     txt = curation.AtomicIO.readText(path)     whole file as char ('' when missing)
%     curation.AtomicIO.writeJson(path, s)       jsonencode (pretty) + writeText
%     s = curation.AtomicIO.readJson(path)       jsondecode of the file, [] when missing/invalid
%                                                (lenient: for lock files and other hints only)
%     s = curation.AtomicIO.readJsonStrict(path) jsondecode of the file, [] ONLY when the file does
%                                                not exist; a file that exists but cannot be read
%                                                or decoded is retried for about half a second
%                                                (another process may be replacing it) and then
%                                                throws curation:AtomicIO:jsonUnreadable
%     s = curation.AtomicIO.updateJson(path, f)  locked load-modify-write, see UPDATEJSON
%     tf = curation.AtomicIO.createExclusive(path, txt)  create PATH holding TXT only if it does
%                                                not exist yet (one atomic step); false when it exists
%     curation.AtomicIO.cleanTemps(folder, name) delete stray temporaries of one target name
%     s = curation.AtomicIO.fmtDouble(v)         shortest text that reads back to the same double
%                                                ('' for NaN), string column
%     s = curation.AtomicIO.csvEscape(s)         quote a string column for CSV where needed
%     s = curation.AtomicIO.cleanText(x)         string, no missing, line breaks -> space, trimmed
%     s = curation.AtomicIO.isoNow(withMs)       local time 'yyyy-mm-ddTHH:MM:SS[.mmm]+hh:mm'
%     s = curation.AtomicIO.isoFromDatetime(t)   same format from datetime values ('' for NaT)
%
%   UPDATEJSON (s = updateJson(path, f)): the shared '<base>.curation.json' is written by both
%   channels' stores, possibly from two MATLAB processes. updateJson
%     1 takes '<path>.lock' with an exclusive create (a lock older than 10 s is stale and broken;
%       otherwise it waits, retrying for up to 5 s, then throws curation:AtomicIO:jsonBusy),
%     2 reads the file strictly (readJsonStrict: an absent file is struct(), an unreadable one
%       throws curation:AtomicIO:jsonUnreadable and nothing is written),
%     3 calls s = f(current) and sets the top-level counter s.jsonRevision = current's + 1,
%     4 re-reads the file just before writing: if it changed meanwhile (a writer that did not take
%       the lock, or broke it as stale), it starts again from 2 with the new content, so that
%       writer's change is merged rather than dropped (f must be a pure load-modify-write),
%     5 writes atomically and releases the lock (only if it is still its own).

    methods (Static)

        function writeText(path, txt)
        %WRITETEXT  Write TXT (char or string) to PATH as UTF-8 without ever exposing a partial file.
        %   Throws curation:AtomicIO:writeFailed when the temporary file cannot be written or the
        %   replace fails; the target is then left as it was.
            path = char(path);
            [folder, name, ext] = fileparts(path);
            if isempty(folder), folder = pwd; end
            tmp = fullfile(folder, sprintf('.%s%s.%s.tmp', name, ext, curation.AtomicIO.randomToken()));
            fid = fopen(tmp, 'w', 'n', 'UTF-8');
            if fid < 0
                error('curation:AtomicIO:writeFailed', 'Cannot create temporary file next to %s.', path);
            end
            try
                fwrite(fid, char(txt), 'char');
                st = fclose(fid);
                fid = -1;
                if st ~= 0
                    error('curation:AtomicIO:writeFailed', 'Closing %s failed.', tmp);
                end
                curation.AtomicIO.replaceFile(tmp, path);
            catch ME
                if fid >= 0, fclose(fid); end
                if isfile(tmp), try delete(tmp); catch, end, end
                if strcmp(ME.identifier, 'curation:AtomicIO:writeFailed')
                    rethrow(ME);
                end
                error('curation:AtomicIO:writeFailed', 'Writing %s failed: %s', path, ME.message);
            end
        end

        function txt = readText(path)
        %READTEXT  Whole file as char (UTF-8), '' when the file does not exist.
            txt = '';
            path = char(path);
            if ~isfile(path), return; end
            fid = fopen(path, 'r', 'n', 'UTF-8');
            if fid < 0, return; end
            c = onCleanup(@() fclose(fid));
            txt = fread(fid, [1 Inf], '*char');
        end

        function writeJson(path, s)
        %WRITEJSON  Pretty-printed jsonencode of S, written atomically.
            try
                txt = jsonencode(s, 'PrettyPrint', true);
            catch
                txt = jsonencode(s);
            end
            curation.AtomicIO.writeText(path, txt);
        end

        function s = readJson(path)
        %READJSON  jsondecode of PATH, or [] when the file is missing, empty or not valid JSON.
        %   Lenient: never use it for a file whose content is written back (see readJsonStrict).
        %   Note: jsondecode collapses nested arrays ([[1,2]] -> 1x2, [1,2] -> 2x1); readers
        %   normalize the shapes they need.
            s = [];
            txt = curation.AtomicIO.readText(path);
            if isempty(strtrim(txt)), return; end
            try
                s = jsondecode(txt);
            catch
                s = [];
            end
        end

        function s = readJsonStrict(path)
        %READJSONSTRICT  jsondecode of PATH; [] only when the file does not exist. A file that
        %   exists but cannot be opened or decoded (also an empty one) is retried for about half
        %   a second, then curation:AtomicIO:jsonUnreadable is thrown.
            s = curation.AtomicIO.readJsonText(path);
        end

        function s = updateJson(path, fcn)
        %UPDATEJSON  Locked load-modify-write of a shared JSON file (see UPDATEJSON in the help):
        %   s = fcn(current) with current the decoded file (struct() only when it does not exist),
        %   s.jsonRevision = current's + 1, written atomically; returns s. Throws
        %   curation:AtomicIO:jsonUnreadable (file exists but cannot be read; nothing written) and
        %   curation:AtomicIO:jsonBusy (another process holds the lock for more than 5 s).
            path = char(path);
            lk = curation.AtomicIO.lockPath(path);
            token = curation.AtomicIO.acquireFileLock(lk, path);
            c = onCleanup(@() curation.AtomicIO.releaseFileLock(lk, token));
            for attempt = 1:5
                [cur, txt0] = curation.AtomicIO.readJsonText(path);
                if isempty(cur) && isempty(txt0)
                    cur = struct();
                elseif ~isstruct(cur) || ~isscalar(cur)
                    error('curation:AtomicIO:jsonUnreadable', ['%s does not hold a JSON object; ' ...
                        'it is left as it is.'], path);
                end
                rev = 0;
                if isfield(cur, 'jsonRevision') && isnumeric(cur.jsonRevision) && isscalar(cur.jsonRevision)
                    rev = double(cur.jsonRevision);
                end
                s = fcn(cur);
                if ~isstruct(s) || ~isscalar(s)
                    error('curation:AtomicIO:writeFailed', 'updateJson: the update of %s did not return a struct.', path);
                end
                s.jsonRevision = rev + 1;
                if ~strcmp(curation.AtomicIO.readText(path), txt0)
                    continue;   % changed under us: merge by applying fcn to the new content
                end
                curation.AtomicIO.writeJson(path, s);
                return;
            end
            error('curation:AtomicIO:jsonBusy', '%s kept changing while it was being updated; nothing was written.', path);
        end

        function tf = createExclusive(path, txt)
        %CREATEEXCLUSIVE  Create PATH holding TXT only if no such file exists, in one atomic step
        %   (CREATE_NEW). false when it exists already; throws curation:AtomicIO:writeFailed when
        %   it cannot be created for another reason (missing folder, no permission).
            path = char(path);
            if nargin < 2, txt = ''; end
            tf = false;
            created = false;
            done = false;
            if ispc && curation.AtomicIO.haveNet()
                try
                    fs = System.IO.File.Open(path, System.IO.FileMode.CreateNew, ...
                        System.IO.FileAccess.Write, System.IO.FileShare.Read);
                    fs.Close();
                    created = true;
                catch
                end
                done = true;
            end
            if ~done
                try
                    created = logical(java.io.File(path).createNewFile());
                    done = true;
                catch
                end
            end
            if ~done
                % last resort, not atomic: no .NET and no Java
                if ~isfile(path)
                    fid = fopen(path, 'w');
                    if fid >= 0, fclose(fid); created = true; end
                end
            end
            if ~created
                if isfile(path), return; end
                error('curation:AtomicIO:writeFailed', 'Cannot create %s.', path);
            end
            if ~isempty(txt)
                fid = fopen(path, 'w', 'n', 'UTF-8');
                if fid < 0
                    error('curation:AtomicIO:writeFailed', 'Cannot write %s.', path);
                end
                fwrite(fid, char(txt), 'char');
                fclose(fid);
            end
            tf = true;
        end

        function cleanTemps(folder, fileName)
        %CLEANTEMPS  Delete stray '.<fileName>.*.tmp' temporaries left by an interrupted write.
            try
                d = dir(fullfile(char(folder), ['.' char(fileName) '.*.tmp']));
                for k = 1:numel(d)
                    try delete(fullfile(d(k).folder, d(k).name)); catch, end
                end
            catch
            end
        end

        function s = fmtDouble(v)
        %FMTDOUBLE  Column of shortest decimal texts that read back to exactly the same doubles.
        %   NaN -> "" (an empty CSV field reads back as NaN), +/-Inf -> "Inf"/"-Inf".
            v = double(v(:));
            s = compose("%.15g", v);
            fin = isfinite(v);
            if any(fin)
                % one sprintf/sscanf pass instead of str2double, which loops per element
                vf = v(fin);
                back = sscanf(sprintf('%.15g ', vf), '%f');
                if numel(back) == numel(vf)
                    bad = back ~= vf;
                else
                    bad = true(size(vf));
                end
                if any(bad)
                    idx = find(fin);
                    idx = idx(bad);
                    s(idx) = compose("%.17g", v(idx));
                end
            end
            s(isnan(v)) = "";
            s(v == Inf) = "Inf";
            s(v == -Inf) = "-Inf";
        end

        function s = csvEscape(s)
        %CSVESCAPE  Quote string-column fields that hold a comma, quote or line break (RFC 4180).
            s = string(s(:));
            s(ismissing(s)) = "";
            q = contains(s, [",", """", newline, char(13)]);
            if any(q)
                s(q) = """" + replace(s(q), """", """""") + """";
            end
        end

        function s = cleanText(x)
        %CLEANTEXT  string array with no <missing>, CR/LF replaced by a space, trimmed.
        %   A char row is one text ('' -> ""), as for string scalars.
            if ischar(x)
                x = string(x);
            end
            if isempty(x)
                s = strings(size(x));
                if isempty(s), s = strings(0, 1); end
                return;
            end
            s = string(x);
            s(ismissing(s)) = "";
            if any(contains(s, [newline, char(13)]))
                s = regexprep(s, '[\r\n]+', ' ');
            end
            s = strtrim(s);
        end

        function s = isoNow(withMs)
        %ISONOW  Current local time as ISO 8601 with offset, e.g. 2026-11-23T14:05:33-05:00
        %   (withMs true: 2026-11-23T14:05:33.123-05:00). Cheap: clock + a cached UTC offset.
            if nargin < 1, withMs = false; end
            c = clock; %#ok<CLOCK>
            off = curation.AtomicIO.utcOffsetText();
            if withMs
                sec = floor(c(6));
                ms = min(999, floor((c(6) - sec) * 1000));
                s = sprintf('%04d-%02d-%02dT%02d:%02d:%02d.%03d%s', c(1:5), sec, ms, off);
            else
                s = sprintf('%04d-%02d-%02dT%02d:%02d:%02d%s', c(1:5), floor(c(6)), off);
            end
        end

        function s = isoFromDatetime(t)
        %ISOFROMDATETIME  string column of ISO 8601 local times with offset; NaT -> "".
        %   A datetime without a time zone is taken as local time.
            t = t(:);
            s = strings(numel(t), 1);
            ok = ~isnat(t);
            if ~any(ok), return; end
            tt = t(ok);
            if isempty(tt.TimeZone)
                tt.TimeZone = 'local';
            end
            tt.Format = 'yyyy-MM-dd''T''HH:mm:ssxxx';
            s(ok) = string(tt);
        end
    end

    methods (Static)
        function m = lastReplaceMethod(m)
            %LASTREPLACEMETHOD  How the last writeText put its file in place (diagnostics):
            %   "replace" (one-step ReplaceFile), "move" (movefile) or "" (nothing yet).
            persistent last
            if isempty(last), last = ""; end
            if nargin > 0
                last = string(m);
            end
            m = last;
        end
    end

    methods (Static, Access = private)

        function tf = haveNet()
            persistent useNet
            if isempty(useNet)
                useNet = false;
                try
                    useNet = ispc && NET.isNETSupported;
                catch
                end
            end
            tf = useNet;
        end

        function [s, txt] = readJsonText(path)
            % Strict read: s = [] and txt = '' only when the file does not exist.
            path = char(path);
            s = []; txt = '';
            lastErr = '';
            for attempt = 1:6
                if ~isfile(path)
                    if attempt == 1
                        pause(0.02);   % a rename-based replace may be between its two steps
                        continue;
                    end
                    s = []; txt = '';
                    return;
                end
                try
                    fid = fopen(path, 'r', 'n', 'UTF-8');
                    if fid < 0
                        error('curation:AtomicIO:cannotOpen', 'it cannot be opened');
                    end
                    txt = fread(fid, [1 Inf], '*char');
                    fclose(fid);
                    if isempty(strtrim(txt))
                        error('curation:AtomicIO:empty', 'it is empty');
                    end
                    s = jsondecode(txt);
                    return;
                catch ME
                    lastErr = ME.message;
                end
                pause(0.04 * attempt);
            end
            error('curation:AtomicIO:jsonUnreadable', ['The JSON file %s exists but cannot be read ' ...
                '(%s). Nothing was written to it; if it stays unreadable, restore it from a backup.'], ...
                path, lastErr);
        end

        function lk = lockPath(path)
            lk = [char(path) '.lock'];
        end

        function token = acquireFileLock(lk, path)
            % Exclusive create of the lock file; breaks a lock older than 10 s; waits up to 5 s.
            persistent count
            if isempty(count), count = 0; end
            count = count + 1;
            token = sprintf('%s %d %d %s', getenv('COMPUTERNAME'), curation.AtomicIO.myPid(), count, ...
                curation.AtomicIO.isoNow(true));
            t0 = tic;
            while true
                if curation.AtomicIO.createExclusive(lk, token)
                    return;
                end
                d = dir(lk);
                if ~isempty(d) && (now - d(1).datenum) * 86400 > 10 %#ok<TNOW1>
                    try delete(lk); catch, end   % left by a process that died mid-update
                    continue;
                end
                if toc(t0) > 5
                    error('curation:AtomicIO:jsonBusy', ['Another process is writing %s (its lock %s ' ...
                        'is held); nothing was written. Try again.'], path, lk);
                end
                pause(0.02 + 0.03 * rand);
            end
        end

        function releaseFileLock(lk, token)
            try
                fid = fopen(lk, 'r', 'n', 'UTF-8');
                if fid < 0, return; end
                txt = fread(fid, [1 Inf], '*char');
                fclose(fid);
                if strcmp(strtrim(txt), token)
                    delete(lk);   % only our own lock (it may have been broken as stale)
                end
            catch
            end
        end

        function p = myPid()
            persistent pid
            if isempty(pid)
                try
                    pid = double(feature('getpid'));
                catch
                    pid = 0;
                end
            end
            p = pid;
        end

        function replaceFile(tmp, target)
            % One-step replace when possible, rename otherwise.
            useNet = curation.AtomicIO.haveNet();
            if isfile(target) && useNet
                try
                    System.IO.File.Replace(tmp, target, [], true);
                    curation.AtomicIO.lastReplaceMethod("replace");
                    return;
                catch
                    % e.g. a share that does not support ReplaceFile: fall through
                end
            end
            [ok, msg] = movefile(tmp, target, 'f');
            curation.AtomicIO.lastReplaceMethod("move");
            if ~ok
                error('curation:AtomicIO:writeFailed', 'Replacing %s failed: %s', target, msg);
            end
        end

        function t = randomToken()
            % Unique per process and call: pid + a call counter + the tic counter (rand alone would
            % repeat across freshly started MATLAB sessions, which share the default seed).
            persistent pid count
            if isempty(pid)
                try
                    pid = double(feature('getpid'));
                catch
                    pid = 0;
                end
                count = 0;
            end
            count = count + 1;
            t = sprintf('%d_%d_%x', pid, count, tic);
        end

        function off = utcOffsetText()
            % '+hh:mm' / '-hh:mm' of local time, recomputed every 10 minutes (DST changes).
            persistent cached stamp
            if isempty(cached) || toc(stamp) > 600
                try
                    d = tzoffset(datetime('now', 'TimeZone', 'local'));
                    m = round(minutes(d));
                catch
                    m = 0;
                end
                sgn = '+';
                if m < 0, sgn = '-'; end
                m = abs(m);
                cached = sprintf('%s%02d:%02d', sgn, floor(m / 60), mod(m, 60));
                stamp = tic;
            end
            off = cached;
        end
    end
end
