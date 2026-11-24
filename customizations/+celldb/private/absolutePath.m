function p = absolutePath(p)
%ABSOLUTEPATH P made absolute against the current folder (a path that already is, as it is).
p = string(p);
if ~(startsWith(p, ["/", "\"]) || ~isempty(regexp(p, "^[A-Za-z]:", "once")))
    p = string(fullfile(pwd, p));
end
end
