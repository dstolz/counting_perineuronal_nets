function h = sha256File(file)
%SHA256FILE SHA-256 of a file as 64 lowercase hexadecimal digits, read in 16 MB chunks.
%   Java's MessageDigest, so it needs no toolbox and no other process.
%   Errors (celldb:CannotRead) when the file cannot be opened.

md = java.security.MessageDigest.getInstance("SHA-256");
fid = fopen(file, "r");
if fid < 0
    error("celldb:CannotRead", "Cannot read %s to hash it.", file);
end
closeFile = onCleanup(@() fclose(fid));
chunk = 16 * 2^20;
while true
    data = fread(fid, chunk, "*uint8");
    if isempty(data)
        break
    end
    md.update(data);
end
h = string(lower(reshape(dec2hex(typecast(md.digest(), "uint8"), 2)', 1, [])));
end
