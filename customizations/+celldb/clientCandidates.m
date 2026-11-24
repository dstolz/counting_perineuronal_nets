function c = clientCandidates()
%CELLDB.CLIENTCANDIDATES The folders a CarasLabDB checkout (with +labclient) is looked for in, in order.
%   c = celldb.clientCandidates()   % a string row, no empty entries
%
% The folder CARASLABDB_DIR names (the variable ephys_analysis uses too),
% then a CarasLabDB folder beside this repository's root
% (C:\src\counting_perineuronal_nets -> C:\src\CarasLabDB). Never an error.
%
% See also CELLDB.AVAILABLE.

repo = string(fileparts(fileparts(fileparts(mfilename("fullpath")))));   % +celldb -> customizations -> repo
c = [string(getenv("CARASLABDB_DIR")), string(fullfile(fileparts(repo), "CarasLabDB"))];
c = c(strlength(c) > 0);
end
