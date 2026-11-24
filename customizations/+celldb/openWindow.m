function openWindow(opts)
%CELLDB.OPENWINDOW The lab database's Database window, or why there is none here.
%   celldb.openWindow(Parent = fig)
%
% With the client here, the Database window every lab toolbox shares
% (labclient.Panel): the server, your login and password, the storage roots
% mapped on this computer, and the outbox. Without it, a message saying how to
% get it (a dialog over PARENT, or printed when there is none); the curation
% app works the same either way. Never an error (celldb:Window warns).
%
% See also CELLDB.ADDLAMP, LABCLIENT.PANEL.

arguments
    opts.Parent = []
end

try
    [ok, why] = celldb.available();
    if ok
        labclient.Panel.open(Parent = opts.Parent);
        return
    end
    text = why + newline + newline + ...
        "Without it nothing is sent to the lab database. The curation app works the same, and each " + ...
        "source marked complete keeps its provenance record beside its files (a .provenance folder). " + ...
        "Once the client is installed, celldb.backfill(<data folder>) puts the records kept so far in the outbox.";
    if ~isempty(opts.Parent) && isvalid(opts.Parent)
        uialert(opts.Parent, text, "Lab Database", Icon = "info");
    else
        fprintf("%s\n", text);
    end
catch ME
    warning("celldb:Window", "The Database window could not be opened: %s", ME.message);
end

end
