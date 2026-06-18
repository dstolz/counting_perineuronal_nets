function [J, U, info] = correctBidirectionalLSMArtifact(I, opts)
% correctBidirectionalLSMArtifact Correct bidirectional LSM line-scan jaggedness artifact.
%
%   J = correctBidirectionalLSMArtifact(I) corrects bidirectional laser
%   scanning artifact by estimating a horizontal displacement field for
%   reverse-scan rows and warping those rows into alignment with neighboring
%   forward-scan rows.
%
%   [J,U,info] = correctBidirectionalLSMArtifact(I, opts) also returns the
%   estimated displacement field U in pixels. U is H-by-W-by-P, where P is
%   the number of corrected planes. Non-corrected rows have zero displacement.
%
%   This implements the main correction described by Papiez et al. (2020):
%   backward lines are registered to the adjacent forward lines using an SSD
%   criterion with smooth displacement regularization, then optionally
%   denoised using guided self-filtering.
%
%   Inputs
%   ------
%   I
%       Numeric image. Supported sizes:
%           H-by-W
%           H-by-W-by-C
%           H-by-W-by-C-by-P
%
%       C is interpreted as channels. P is interpreted as planes/timepoints.
%
%   opts
%       Name-value options:
%
%       ReverseRows
%           "even" or "odd". Rows scanned in the reverse direction and
%           corrected. Default is "even".
%
%       MaxDisplacement
%           Maximum horizontal displacement in pixels. Default is 8.
%
%       NumIterations
%           Number of iterations per pyramid level. Default is 15.
%
%       PyramidDownsample
%           Row vector of horizontal downsample factors, coarse to fine.
%           Default is [4 2 1].
%
%       SmoothSigma
%           Gaussian smoothing sigma, in pixels, applied to the 1-D
%           displacement after each update. Default is 4.
%
%       StepSize
%           Update step size. Default is 0.75.
%
%       UseAllChannels
%           If true, all channels drive registration. If false, only
%           RegistrationChannel is used. Default is true.
%
%       RegistrationChannel
%           Channel used if UseAllChannels is false. Default is 1.
%
%       ApplyGuidedFilter
%           If true, apply imguidedfilter after geometric correction.
%           Default is false.
%
%       GuidedNeighborhoodSize
%           Neighborhood size for imguidedfilter. Default is [5 5].
%
%       GuidedDegreeOfSmoothing
%           DegreeOfSmoothing for imguidedfilter. Default is 0.01.
%
%       FillValue
%           Value used outside image bounds during row warping. Default is NaN,
%           which triggers nearest-edge extrapolation.
%
%   Notes
%   -----
%   Positive U means the corrected output at column x samples the original
%   reverse row at x + U(x).
%
%   Requires Image Processing Toolbox for imgaussfilt, imresize, and
%   imguidedfilter when ApplyGuidedFilter is true.

arguments
    I {mustBeNumeric, mustBeNonempty}
    opts.ReverseRows (1,1) string {mustBeMember(opts.ReverseRows, ["even","odd"])} = "even"
    opts.MaxDisplacement (1,1) double {mustBePositive} = 8
    opts.NumIterations (1,1) double {mustBeInteger, mustBePositive} = 5
    opts.PyramidDownsample (1,:) double {mustBeInteger, mustBePositive} = [4 2 1]
    opts.SmoothSigma (1,1) double {mustBeNonnegative} = 4
    opts.StepSize (1,1) double {mustBePositive} = 0.75
    opts.UseAllChannels (1,1) logical = true
    opts.RegistrationChannel (1,1) double {mustBeInteger, mustBePositive} = 1
    opts.ApplyGuidedFilter (1,1) logical = false
    opts.GuidedNeighborhoodSize (1,2) double {mustBeInteger, mustBePositive} = [5 5]
    opts.GuidedDegreeOfSmoothing (1,1) double {mustBeNonnegative} = 0.01
    opts.FillValue (1,1) double = NaN
end

inputClass = class(I);
inputSize = size(I);
Iwork = im2single(I);

[H, W, C, P] = parseImageSize(Iwork);
Iwork = reshape(Iwork, H, W, C, P);

if opts.RegistrationChannel > C
    error("RegistrationChannel exceeds the number of image channels.")
end

if opts.UseAllChannels
    regChannels = 1:C;
else
    regChannels = opts.RegistrationChannel;
end

Jwork = Iwork;
U = zeros(H, W, P, "single");

if opts.ReverseRows == "even"
    reverseRows = 2:2:H;
else
    reverseRows = 1:2:H;
end

reverseRows = reverseRows(reverseRows > 1 & reverseRows < H);
x = single(1:W);

for p = 1:P
    for y = reverseRows
        fixedLine = 0.5 .* (Iwork(y - 1, :, regChannels, p) + Iwork(y + 1, :, regChannels, p));
        movingLine = Iwork(y, :, regChannels, p);

        fixedLine = formatLineForRegistration(fixedLine, W);
        movingLine = formatLineForRegistration(movingLine, W);

        u = estimateLineDisplacement(fixedLine, movingLine, opts);

        U(y, :, p) = u;

        for c = 1:C
            row = squeeze(Iwork(y, :, c, p));
            Jwork(y, :, c, p) = warpLine(row, x + u, opts.FillValue);
        end
    end
end

if opts.ApplyGuidedFilter
    for p = 1:P
        for c = 1:C
            plane = Jwork(:, :, c, p);
            Jwork(:, :, c, p) = imguidedfilter(plane, plane, ...
                NeighborhoodSize=opts.GuidedNeighborhoodSize, ...
                DegreeOfSmoothing=opts.GuidedDegreeOfSmoothing);
        end
    end
end

Jwork = reshape(Jwork, inputSize);
J = castLikeInput(Jwork, I, inputClass);

info = struct;
info.Method = "Bidirectional line registration with diffusion-smoothed horizontal displacement";
info.ReverseRows = opts.ReverseRows;
info.MaxDisplacement = opts.MaxDisplacement;
info.NumIterations = opts.NumIterations;
info.PyramidDownsample = opts.PyramidDownsample;
info.SmoothSigma = opts.SmoothSigma;
info.StepSize = opts.StepSize;
info.ApplyGuidedFilter = opts.ApplyGuidedFilter;

end

function X = formatLineForRegistration(X, W)

X = squeeze(X);

if isvector(X)
    X = X(:).';
elseif size(X, 1) == W
    X = X.';
elseif size(X, 2) ~= W
    error("Unable to format registration line as C-by-W data.")
end

X = single(X);

end

function u = estimateLineDisplacement(fixedLine, movingLine, opts)

W = size(fixedLine, 2);
uFull = zeros(1, W, "single");

levels = unique(opts.PyramidDownsample, "stable");
levels = sort(levels, "descend");

for s = levels
    Ws = max(8, round(W / s));

    fixedS = resizeLine(fixedLine, Ws);
    movingS = resizeLine(movingLine, Ws);

    if s == levels(1)
        u = zeros(1, Ws, "single");
    else
        u = resizeVector1D(uFull, Ws) ./ single(s);
    end

    maxDispS = single(opts.MaxDisplacement / s);
    smoothSigmaS = max(0.25, opts.SmoothSigma / s);

    xs = single(1:Ws);

    for iter = 1:opts.NumIterations
        moved = zeros(size(movingS), "single");
        gradMoved = zeros(size(movingS), "single");

        for c = 1:size(movingS, 1)
            moved(c, :) = warpLine(movingS(c, :), xs + u, opts.FillValue);
            gradLine = gradient(movingS(c, :));
            gradMoved(c, :) = warpLine(gradLine, xs + u, 0);
        end

        residual = fixedS - moved;

        numerator = sum(residual .* gradMoved, 1);
        denominator = sum(gradMoved .^ 2, 1) + 1e-6;

        du = opts.StepSize .* numerator ./ denominator;
        du = max(min(du, 1), -1);

        u = u + single(du);
        u = smoothdata(u, "gaussian", max(3, 2 * ceil(2 * smoothSigmaS) + 1));
        u = max(min(u, maxDispS), -maxDispS);
    end

    uFull = resizeVector1D(u, W) .* single(s);
end

u = single(uFull);
u = reshape(u, 1, []);
u = max(min(u, single(opts.MaxDisplacement)), -single(opts.MaxDisplacement));

end

function yq = warpLine(y, xq, fillValue)

x = single(1:numel(y));
y = single(y(:).');

if isnan(fillValue)
    xq = max(min(single(xq), x(end)), x(1));
    yq = interp1(x, y, xq, "linear");
else
    yq = interp1(x, y, single(xq), "linear", single(fillValue));
end

yq = single(yq);

end

function Y = resizeLine(X, Wout)

Cin = size(X, 1);
Y = zeros(Cin, Wout, "single");

for c = 1:Cin
    Y(c, :) = resizeVector1D(X(c, :), Wout);
end

end

function [H, W, C, P] = parseImageSize(I)

sz = size(I);
H = sz(1);
W = sz(2);

if ndims(I) == 2
    C = 1;
    P = 1;
elseif ndims(I) == 3
    C = sz(3);
    P = 1;
else
    C = sz(3);
    P = prod(sz(4:end));
end

end

function J = castLikeInput(Jwork, I, inputClass)

switch inputClass
    case "uint8"
        J = im2uint8(mat2grayIfNeeded(Jwork, I));
    case "uint16"
        J = im2uint16(mat2grayIfNeeded(Jwork, I));
    case "uint32"
        J = cast(round(rescaleToInputRange(Jwork, I)), "uint32");
    case "single"
        J = single(Jwork);
    case "double"
        J = double(Jwork);
    otherwise
        J = cast(Jwork, inputClass);
end

end

function J = mat2grayIfNeeded(Jwork, I)

if isinteger(I)
    J = min(max(Jwork, 0), 1);
else
    J = Jwork;
end

end

function J = rescaleToInputRange(Jwork, I)

lo = double(min(I(:)));
hi = double(max(I(:)));

J = double(Jwork);
J = min(max(J, lo), hi);

end

function yOut = resizeVector1D(yIn, nOut)

yIn = single(yIn(:).');
nIn = numel(yIn);

if nIn == nOut
    yOut = yIn;
    return
end

if nIn == 1
    yOut = repmat(yIn, 1, nOut);
    return
end

xIn = single(linspace(1, nOut, nIn));
xOut = single(1:nOut);

yOut = interp1(xIn, yIn, xOut, "linear", "extrap");
yOut = single(reshape(yOut, 1, []));

end