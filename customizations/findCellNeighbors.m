function neighbors = findCellNeighbors(T, distance)
% Returns a cell array where neighbors{i} contains row indices of all cells
% within Euclidean distance of cell i (excludes the cell itself).
%
% T        - table with at minimum columns X and Y (e.g. loaded from a
%            detection CSV produced by predict.py)
% distance - search radius in pixels (default: 10)

    arguments
        T        table
        distance (1,1) double {mustBePositive} = 10
    end

    xy = [T.X, T.Y];
    n  = height(T);

    % Build k-d tree and query all points at once
    idx = rangesearch(xy, xy, distance);

    % Remove each point from its own neighbor list
    neighbors = cellfun(@(list, self) list(list ~= self), ...
                        idx, num2cell((1:n)'), ...
                        UniformOutput=false);
end
