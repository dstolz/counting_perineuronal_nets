function lamp = addLamp(grid, opts)
%CELLDB.ADDLAMP The lab database's lamp in an app's status bar (or a note that the client is not installed).
%   lamp = celldb.addLamp(grid, Row = 1, Column = 4, Parent = fig)
%
% With the lab database client here (celldb.available), the client's own
% lamp (labclient.Lamp): the database's state and what waits in the outbox,
% the Database window on a click, and the sending started when the database
% is turned on. Without it, a grey button "Database: not installed" whose
% tooltip says what to install and where it is looked for (or that the
% environment switched it off), and whose click says the same in a window.
% Never an error: a lamp that cannot be made is [] (and a warning,
% celldb:Lamp).
%
% See also CELLDB.OPENWINDOW, CELLDB.STATUSTEXT, LABCLIENT.LAMP.

arguments
    grid
    opts.Row (1,1) double = 1
    opts.Column (1,1) double = 1
    opts.Parent = []
end

try
    [ok, why] = celldb.available();
    if ok
        lamp = labclient.Lamp(grid, Row = opts.Row, Column = opts.Column, Parent = opts.Parent);
        return
    end
    lamp = uibutton(grid, "Text", "Database: not installed", "FontSize", 11, ...
        "FontColor", [0.45 0.45 0.45], "Tag", "LabClientLamp", ...
        "Tooltip", why + " The curation app works the same without it; each curated source's " + ...
        "provenance record is kept beside its files (a .provenance folder).", ...
        "ButtonPushedFcn", @(~, ~) celldb.openWindow(Parent = opts.Parent));
    lamp.Layout.Row = opts.Row;
    lamp.Layout.Column = opts.Column;
catch ME
    warning("celldb:Lamp", "No lab database lamp: %s", ME.message);
    lamp = [];
end

end
