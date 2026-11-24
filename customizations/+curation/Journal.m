classdef Journal < handle
%JOURNAL  Append-only change log of one curation source ('<stem>_curation.journal.csv').
%
%   One CSV line per changed field per cell, written as part of each Store transaction, so a crash
%   between a change and the next snapshot loses nothing (Store.open replays the transactions whose
%   Revision is newer than the snapshot). Columns:
%
%     Time      ISO 8601 local time with offset and milliseconds of the commit
%     Reviewer  who made the change
%     Session   writer session id (host-pid-start), one per Store instance
%     Seq       transaction number within the session (all lines of a transaction share it)
%     Revision  store revision after the transaction (the replay order key)
%     Action    Store method (setLabel, addCell, ...), "undo"/"redo", a structural transaction
%               ("reconcile", "legacy-import", "regions": rows added/removed/changed by the store
%               itself; "setRescore": Stage-2 scores stored for the cells' positions; journaled
%               like any other transaction but never undoable), or an event line
%               ("open", "create", "snapshot", "reconcile", "legacy-import") that replay ignores
%     CellID    the cell (empty for meta, marker and event lines)
%     Field     a store column name; "+row" (row added: New = JSON of the full row);
%               "-row" (row removed: Old = JSON of the row);
%               "meta.<Name>" (KeptPairs as JSON [[a,b],...], SweepDone/Complete/LegacyImported as
%               1/0, AutoReject as JSON, LocsFingerprint as text, NextCellId as [n]);
%               "+region" / "-region" (a region added / removed: New / Old = JSON of the region;
%               audit only, replay ignores them: regions live in the shared JSON, written at commit);
%               "#begin" / "#commit" (transaction markers, see TRANSACTIONS);
%               empty on event lines (New may hold a JSON summary)
%     Old, New  values as text: doubles in shortest round-trip form ('' = NaN), uint32 as
%               integers, logicals as 1/0, strings verbatim (CSV-quoted when needed)
%     Queue, PageId, DwellMs   GUI context of the transaction (may be empty)
%
%   TRANSACTIONS. Every transaction is written with ONE write call as
%       <Time,Reviewer,Session,Seq,Revision,Action>,,#begin,,<n>,<Queue,PageId,DwellMs>
%       <the n data lines>
%       <Time,Reviewer,Session,Seq,Revision,Action>,,#commit,,<n>,<Queue,PageId,DwellMs>
%   all with the same Session and Seq. curation.Journal.transactions groups the lines by
%   (Session, Seq) and calls a transaction committed only when its #commit line is present and
%   exactly n well-formed data lines of it were read; a crash in the middle of a write leaves a
%   torn tail that replay skips (and reports), never half applies. Journals written before the
%   markers existed: a transaction counts as committed when lines of a later transaction follow
%   it; only the last transaction of such a journal is suspect (not committed). Event lines
%   (Seq 0, empty Field) are not transactions.
%
%   The file is kept open between transactions (when MATLAB hands writes to the operating
%   system immediately, which the first append checks against the file size); otherwise each
%   append opens, writes and closes the file. A writer that finds the file not ending in a line
%   break (a crash cut its last line) starts on a new line, so the cut line stays malformed and
%   is never glued to the next one.
%
%   Methods
%     j = curation.Journal(path, session)
%     n = j.append(cs)                      write a curation.ChangeSet as one transaction (n = data
%                                           lines written, markers not counted)
%     j.event(action, revision, reviewer, payload)   one event line (ignored by replay)
%     j.close()
%   Static
%     R = curation.Journal.read(path, fromByte)  parsed lines (struct of string columns plus
%                                                numeric Seq/Revision), complete lines only
%     G = curation.Journal.transactions(R)       the transactions of R (see TRANSACTIONS)
%     L = curation.Journal.transactionLines(cs, session)  the lines append writes (markers included)
%     L = curation.Journal.formatLines(cs, session)       the data lines only
%     s = curation.Journal.encode(v)             typed column -> journal text column
%     v = curation.Journal.decode(s, type)       journal text column -> typed column
%                                                (type: 'double'|'uint32'|'logical'|'string')

    properties (Constant)
        HEADER = 'Time,Reviewer,Session,Seq,Revision,Action,CellID,Field,Old,New,Queue,PageId,DwellMs'
        COLUMNS = ["Time","Reviewer","Session","Seq","Revision","Action","CellID","Field", ...
            "Old","New","Queue","PageId","DwellMs"]
        BEGIN = "#begin"
        COMMIT = "#commit"
    end

    properties (SetAccess = private)
        Path char = ''
        Session string = ""
        Bytes double = 0          % file size after the last write
        KeepOpen logical = true   % false after the first append showed buffered writes
        LastError string = ""
    end

    properties (Access = private)
        Fid double = -1
        Checked logical = false
    end

    methods
        function j = Journal(path, session)
            j.Path = char(path);
            if nargin >= 2, j.Session = string(session); end
            j.Bytes = curation.Journal.fileLength(j.Path);
        end

        function n = append(j, cs)
            %APPEND  Write a committed ChangeSet as one transaction (#begin, data lines, #commit);
            %   returns the number of data lines. Never throws: a failure is kept in LastError and
            %   warned about (curation:Journal:writeFailed), and n = 0.
            n = 0;
            try
                [lines, nData] = curation.Journal.transactionLines(cs, j.Session);
                if nData == 0, return; end
                txt = char(join(lines, newline) + newline);
                j.writeRaw(txt);
                n = nData;
            catch ME
                j.LastError = string(ME.message);
                warning('curation:Journal:writeFailed', 'Journal write failed (%s): %s', j.Path, ME.message);
            end
        end

        function event(j, action, revision, reviewer, payload)
            %EVENT  One event line (Action = action, empty CellID/Field, New = payload text).
            %   Replay ignores event lines; they document opens, snapshots, reconciles and imports.
            if nargin < 5, payload = ""; end
            if nargin < 4, reviewer = ""; end
            try
                f = [string(curation.AtomicIO.isoNow(true)), string(reviewer), j.Session, "0", ...
                    string(sprintf('%d', round(revision))), string(action), "", "", "", ...
                    string(payload), "", "", ""];
                f = curation.AtomicIO.csvEscape(f(:))';
                j.writeRaw([char(join(f, ",")) newline]);
            catch ME
                j.LastError = string(ME.message);
                warning('curation:Journal:writeFailed', 'Journal write failed (%s): %s', j.Path, ME.message);
            end
        end

        function close(j)
            if j.Fid >= 0
                try fclose(j.Fid); catch, end
            end
            j.Fid = -1;
        end

        function delete(j)
            j.close();
        end
    end

    methods (Access = private)
        function writeRaw(j, txt)
            % Append TXT (char), creating the file with its header first.
            if j.KeepOpen
                if j.Fid < 0
                    j.openForAppend();
                end
                cnt = fwrite(j.Fid, txt, 'char');
                if cnt == 0 && ~isempty(txt)
                    error('curation:Journal:writeFailed', 'Nothing written to %s.', j.Path);
                end
                expected = j.Bytes + numel(unicode2native(txt, 'UTF-8'));
                j.Bytes = expected;
                if ~j.Checked
                    % Did the bytes reach the operating system? Ask a second handle for the
                    % file length (a directory listing can lag on Windows). If MATLAB buffered
                    % them, fall back to open-write-close per transaction (safety over speed).
                    j.Checked = true;
                    if curation.Journal.fileLength(j.Path) < expected
                        j.close();
                        j.KeepOpen = false;
                        j.Bytes = curation.Journal.fileLength(j.Path);
                    end
                end
            else
                j.openForAppend();
                cnt = fwrite(j.Fid, txt, 'char');
                j.close();
                if cnt == 0 && ~isempty(txt)
                    error('curation:Journal:writeFailed', 'Nothing written to %s.', j.Path);
                end
                j.Bytes = curation.Journal.fileLength(j.Path);
            end
        end

        function openForAppend(j)
            sz = curation.Journal.fileLength(j.Path);
            isNew = sz == 0;
            cut = ~isNew && ~curation.Journal.endsWithNewline(j.Path);
            fid = fopen(j.Path, 'a', 'n', 'UTF-8');
            if fid < 0
                error('curation:Journal:writeFailed', 'Cannot open %s for appending.', j.Path);
            end
            j.Fid = fid;
            if isNew
                hdr = [curation.Journal.HEADER newline];
                fwrite(fid, hdr, 'char');
                j.Bytes = numel(hdr);
            else
                if cut
                    fwrite(fid, newline, 'char');   % the last line was cut off by a crash
                    sz = sz + 1;
                end
                j.Bytes = sz;
            end
        end
    end

    methods (Static)

        function [lines, nData] = transactionLines(cs, session)
            %TRANSACTIONLINES  The lines of one transaction: #begin, the data lines, #commit.
            if nargin < 2, session = ""; end
            data = curation.Journal.formatLines(cs, session);
            nData = numel(data);
            lines = strings(0, 1);
            if nData == 0, return; end
            [pre, post] = curation.Journal.prePost(cs, session);
            nTxt = string(sprintf('%d', nData));
            lines = [pre + ",," + curation.Journal.BEGIN + ",," + nTxt + "," + post; data; ...
                pre + ",," + curation.Journal.COMMIT + ",," + nTxt + "," + post];
        end

        function lines = formatLines(cs, session)
            %FORMATLINES  Data lines (string column, no newline, no markers) of a ChangeSet.
            if nargin < 2, session = ""; end
            lines = strings(0, 1);
            if isempty(cs.Entries), return; end
            esc = @(x) curation.AtomicIO.csvEscape(string(x));
            [pre, post] = curation.Journal.prePost(cs, session);
            parts = cell(numel(cs.Entries), 1);
            for k = 1:numel(cs.Entries)
                e = cs.Entries(k);
                switch e.Kind
                    case 'set'
                        ids = string(e.CellID(:));
                        o = curation.Journal.encode(e.Old);
                        nw = curation.Journal.encode(e.New);
                        parts{k} = pre + "," + ids + "," + e.Field + "," + o + "," + nw + "," + post;
                    case 'add'
                        js = curation.Journal.rowsToJson(e.New);
                        parts{k} = pre + "," + string(e.CellID(:)) + ",+row,," + esc(js) + "," + post;
                    case 'remove'
                        js = curation.Journal.rowsToJson(e.Old);
                        parts{k} = pre + "," + string(e.CellID(:)) + ",-row," + esc(js) + ",," + post;
                    case 'meta'
                        o = curation.Journal.encodeMeta(e.Old);
                        nw = curation.Journal.encodeMeta(e.New);
                        parts{k} = pre + ",,meta." + e.Field + "," + o + "," + nw + "," + post;
                    case 'region'
                        ln = strings(0, 1);
                        if ~isempty(e.Old)
                            ln(end + 1, 1) = pre + ",,-region," + esc(curation.Journal.regionJson(e.Old)) + ",," + post; %#ok<AGROW>
                        end
                        if ~isempty(e.New)
                            ln(end + 1, 1) = pre + ",,+region,," + esc(curation.Journal.regionJson(e.New)) + "," + post; %#ok<AGROW>
                        end
                        parts{k} = ln;
                end
            end
            lines = vertcat(parts{:});
            if isempty(lines), lines = strings(0, 1); end
        end

        function G = transactions(R)
            %TRANSACTIONS  The transactions among the lines R (curation.Journal.read): struct with
            %   one element per (Session, Seq) group in file order, as columns
            %     Session, Seq, Action (string), Revision (double), FirstLine, LastLine (indices into
            %     R), DataLines (cell of index columns, file order, markers left out), Count (data
            %     lines declared by the markers, NaN without), Committed (logical), Status
            %     ("committed" | "incomplete" | "legacy" (no markers, a later transaction follows) |
            %     "suspect" (no markers, the last one))
            G = struct('Session', strings(0, 1), 'Seq', strings(0, 1), 'Action', strings(0, 1), ...
                'Revision', zeros(0, 1), 'FirstLine', zeros(0, 1), 'LastLine', zeros(0, 1), ...
                'DataLines', {cell(0, 1)}, 'Count', zeros(0, 1), 'Committed', false(0, 1), ...
                'Status', strings(0, 1));
            if ~isfield(R, 'Field') || isempty(R.Field), return; end
            idx = find(strlength(R.Field) > 0);
            if isempty(idx), return; end
            key = R.Session(idx) + "|" + R.Seq(idx);
            [~, ~, g] = unique(key, 'stable');
            nG = max(g);
            fld = R.Field(idx);
            isB = fld == curation.Journal.BEGIN;
            isC = fld == curation.Journal.COMMIT;
            isD = ~isB & ~isC;
            hasB = accumarray(g, double(isB), [nG 1]) > 0;
            hasC = accumarray(g, double(isC), [nG 1]) > 0;
            nData = accumarray(g, double(isD), [nG 1]);
            cnt = nan(nG, 1);
            if any(isC)
                v = str2double(R.New(idx(isC)));
                cnt = accumarray(g(isC), v, [nG 1], @max, NaN);
            end
            first = accumarray(g, idx, [nG 1], @min);
            last = accumarray(g, idx, [nG 1], @max);
            [~, o] = sortrows([g, idx]);
            gs = g(o); is = idx(o); ds = isD(o);
            bounds = [0; find(diff(gs)); numel(gs)];
            dl = cell(nG, 1);
            for k = 1:nG
                seg = bounds(k) + 1:bounds(k + 1);
                dl{k} = is(seg(ds(seg)));
            end
            G.Session = R.Session(first);
            G.Seq = R.Seq(first);
            G.Action = R.Action(first);
            G.Revision = R.RevisionNum(first);
            G.FirstLine = first;
            G.LastLine = last;
            G.DataLines = dl;
            G.Count = cnt;
            committed = false(nG, 1);
            status = strings(nG, 1);
            withC = hasC;
            committed(withC) = nData(withC) == cnt(withC);
            status(withC & committed) = "committed";
            status(withC & ~committed) = "incomplete";
            torn = ~hasC & hasB;
            status(torn) = "incomplete";
            legacy = ~hasC & ~hasB;
            later = last < max(idx);          % lines of another transaction follow this one
            committed(legacy & later) = true;
            status(legacy & later) = "legacy";
            status(legacy & ~later) = "suspect";
            G.Committed = committed;
            G.Status = status;
        end

        function s = encode(v)
            %ENCODE  Typed column -> journal text column (strings are CSV-escaped).
            if isstring(v) || iscellstr(v) || ischar(v)
                s = curation.AtomicIO.csvEscape(curation.AtomicIO.cleanText(v));
            elseif islogical(v)
                s = repmat("0", numel(v), 1);
                s(v(:)) = "1";
            elseif isinteger(v)
                s = string(v(:));
            else
                s = curation.AtomicIO.fmtDouble(v);
            end
        end

        function v = decode(s, type)
            %DECODE  Journal text column -> typed column of TYPE.
            s = string(s(:));
            switch char(type)
                case 'double'
                    v = str2double(s);
                case 'uint32'
                    d = str2double(s);
                    d(isnan(d)) = 0;
                    v = uint32(d);
                case 'logical'
                    v = s == "1" | lower(s) == "true";
                otherwise
                    v = s;
                    v(ismissing(v)) = "";
            end
        end

        function s = encodeMeta(v)
            if isstruct(v)
                s = curation.AtomicIO.csvEscape(string(jsonencode(v)));   % e.g. AutoReject
                return;
            end
            if islogical(v) && isscalar(v)
                s = string(double(v));
            elseif isnumeric(v)
                if isempty(v)
                    s = "[]";
                else
                    s = string(jsonencode(num2cell(double(v), 2)));
                end
            else
                s = string(v);
            end
            s = curation.AtomicIO.csvEscape(s);
        end

        function s = regionStruct(r)
            %REGIONSTRUCT  Plain struct of one region for jsonencode: xy as rows [[x,y],...].
            s = struct('id', double(r.id), 'kind', char(r.kind), 'scope', char(r.scope), ...
                'xy', [], 'note', char(r.note));
            s.xy = num2cell(double(r.xy), 2);
        end

        function js = regionJson(r)
            js = string(jsonencode(curation.Journal.regionStruct(r)));
        end

        function js = rowsToJson(R)
            % JSON text (string column) of each row of a struct of columns.
            names = fieldnames(R);
            if isempty(names)
                js = strings(0, 1);
                return;
            end
            n = numel(R.(names{1}));
            js = strings(n, 1);
            for i = 1:n
                r = struct();
                for k = 1:numel(names)
                    col = R.(names{k});
                    val = col(i);
                    if isnumeric(val) && isfloat(val) && isnan(val)
                        val = 'NaN';   % jsonencode writes NaN as null; keep it explicit
                    end
                    r.(names{k}) = val;
                end
                js(i) = string(jsonencode(r));
            end
        end

        function R = read(path, fromByte)
            %READ  Parse the complete lines of the journal from byte FROMBYTE (default 0).
            %   Returns a struct with string columns named as COLUMNS (Seq/Revision also as
            %   double columns SeqNum/RevisionNum) in file order, and a field Bytes (file size read
            %   up to). A partial last line (no newline yet) and lines with the wrong field count are
            %   skipped. When FROMBYTE is beyond the file size the whole file is read.
            if nargin < 2 || isempty(fromByte) || ~isfinite(fromByte), fromByte = 0; end
            R = curation.Journal.emptyRead();
            path = char(path);
            if ~isfile(path), return; end
            fid = fopen(path, 'r', 'n', 'UTF-8');
            if fid < 0, return; end
            c = onCleanup(@() fclose(fid));
            fseek(fid, 0, 'eof');
            sz = ftell(fid);
            R.Bytes = sz;
            if fromByte > sz || fromByte < 0, fromByte = 0; end
            fseek(fid, fromByte, 'bof');
            raw = fread(fid, [1 Inf], 'uint8=>uint8');
            if isempty(raw), return; end
            txt = native2unicode(raw, 'UTF-8');
            lastNl = find(txt == newline, 1, 'last');
            if isempty(lastNl), return; end
            txt = txt(1:lastNl);
            lines = splitlines(string(txt));
            lines = strip(lines, 'right', char(13));
            lines = lines(strlength(lines) > 0);
            lines = lines(lines ~= curation.Journal.HEADER);
            if isempty(lines), return; end
            nc = numel(curation.Journal.COLUMNS);
            F = strings(numel(lines), nc);
            ok = false(numel(lines), 1);
            hasQ = contains(lines, """");
            simple = find(~hasQ);
            if ~isempty(simple)
                nComma = count(lines(simple), ",");
                good = simple(nComma == nc - 1);
                if ~isempty(good)
                    P = split(lines(good), ",");
                    if isvector(P) && numel(good) == 1, P = reshape(P, 1, []); end
                    F(good, :) = P;
                    ok(good) = true;
                end
            end
            for i = find(hasQ)'
                f = curation.Journal.parseCsvLine(char(lines(i)));
                if numel(f) == nc
                    F(i, :) = f;
                    ok(i) = true;
                end
            end
            F = F(ok, :);
            for k = 1:nc
                R.(char(curation.Journal.COLUMNS(k))) = F(:, k);
            end
            R.SeqNum = str2double(R.Seq);
            R.RevisionNum = str2double(R.Revision);
        end

        function f = parseCsvLine(line)
            %PARSECSVLINE  Fields (string row) of one RFC 4180 CSV line.
            f = strings(1, 0);
            n = numel(line);
            i = 1;
            buf = blanks(0);
            inQ = false;
            while i <= n
                ch = line(i);
                if inQ
                    if ch == '"'
                        if i < n && line(i + 1) == '"'
                            buf(end + 1) = '"'; %#ok<AGROW>
                            i = i + 1;
                        else
                            inQ = false;
                        end
                    else
                        buf(end + 1) = ch; %#ok<AGROW>
                    end
                else
                    if ch == ','
                        f(end + 1) = string(buf); %#ok<AGROW>
                        buf = blanks(0);
                    elseif ch == '"'
                        inQ = true;
                    else
                        buf(end + 1) = ch; %#ok<AGROW>
                    end
                end
                i = i + 1;
            end
            if inQ
                f = strings(1, 0);      % an unterminated quote: the line was cut off (malformed)
                return;
            end
            f(end + 1) = string(buf);
        end

        function n = fileLength(path)
            %FILELENGTH  Bytes in PATH as seen through a fresh handle (0 when missing).
            n = 0;
            fid = fopen(char(path), 'r');
            if fid < 0, return; end
            fseek(fid, 0, 'eof');
            n = ftell(fid);
            fclose(fid);
        end

        function tf = endsWithNewline(path)
            %ENDSWITHNEWLINE  true when the last byte of PATH is a line feed (or the file is empty).
            tf = true;
            fid = fopen(char(path), 'r');
            if fid < 0, return; end
            c = onCleanup(@() fclose(fid));
            if fseek(fid, -1, 'eof') ~= 0, return; end
            b = fread(fid, 1, 'uint8=>uint8');
            tf = isempty(b) || b == 10;
        end

        function R = emptyRead()
            R = struct();
            for k = 1:numel(curation.Journal.COLUMNS)
                R.(char(curation.Journal.COLUMNS(k))) = strings(0, 1);
            end
            R.SeqNum = zeros(0, 1);
            R.RevisionNum = zeros(0, 1);
            R.Bytes = 0;
        end
    end

    methods (Static, Access = private)
        function [pre, post] = prePost(cs, session)
            esc = @(x) curation.AtomicIO.csvEscape(string(x));
            pre = join([esc(cs.Time), esc(cs.Reviewer), esc(session), ...
                string(sprintf('%d', round(cs.Seq))), string(sprintf('%d', round(cs.Revision))), ...
                esc(cs.Action)], ",");
            dwell = "";
            if ~isnan(cs.DwellMs), dwell = string(sprintf('%d', round(cs.DwellMs))); end
            post = join([esc(cs.Queue), esc(cs.PageId), dwell], ",");
        end
    end
end
