function s = fileSnapshot(file)
%FILESNAPSHOT A file's size and modification time: bytes, mtime (zoned text, ms); NaN and "" when it is not there.
s = struct("bytes", NaN, "mtime", "");
d = dir(file);
if isempty(d) || d(1).isdir
    return
end
s.bytes = double(d(1).bytes);
dt = datetime(d(1).datenum, "ConvertFrom", "datenum", "TimeZone", "local");
dt.Format = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx";
s.mtime = string(dt);
end
