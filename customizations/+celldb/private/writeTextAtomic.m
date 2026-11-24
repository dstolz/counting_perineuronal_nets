function writeTextAtomic(file, text)
%WRITETEXTATOMIC Write TEXT (UTF-8) to FILE through a temporary file and a rename.
%   A reader sees the whole file or none of it, and a crash leaves at most a
%   stray .partial file, never half a record.

folder = fileparts(file);
if folder ~= "" && ~isfolder(folder)
    mkdir(folder);
end
tmp = file + ".partial";
fid = fopen(tmp, "w", "n", "UTF-8");
if fid < 0
    error("celldb:CannotWrite", "Cannot write %s.", tmp);
end
fwrite(fid, unicode2native(char(text), "UTF-8"));
fclose(fid);
[ok, msg] = movefile(tmp, file, "f");
if ~ok
    if isfile(tmp); delete(tmp); end
    error("celldb:CannotWrite", "Cannot write %s: %s", file, msg);
end
end
