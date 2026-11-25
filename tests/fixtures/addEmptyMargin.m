function addEmptyMargin(tifFile, marginPx)
%addEmptyMargin  Blank the left MARGINPX columns of every page of a float32 TIFF (the empty space beside a section).
%   Rewrites the file with the same pixel size. The synthetic sections of makeSyntheticDataset fill
%   their frame; cellanalysis.Surface needs empty space to find a brain surface in.
%
%   See also makeSyntheticDataset, tAnalysisProject.

arguments
    tifFile (1,1) string
    marginPx (1,1) double {mustBePositive, mustBeInteger}
end

file = char(tifFile);
info = imfinfo(file);
upp = CellToolkit.tiffPixelSizeUm(file, 1);
imgs = cell(1, numel(info));
for p = 1:numel(info)
    img = imread(file, p);
    img(:, 1:min(marginPx, size(img, 2))) = 0;
    imgs{p} = single(img);
end
delete(file);
t = Tiff(file, 'w');
cleaner = onCleanup(@() t.close());
for p = 1:numel(imgs)
    tag = struct();
    tag.ImageLength = size(imgs{p}, 1);
    tag.ImageWidth = size(imgs{p}, 2);
    tag.Photometric = Tiff.Photometric.MinIsBlack;
    tag.BitsPerSample = 32;
    tag.SamplesPerPixel = 1;
    tag.SampleFormat = Tiff.SampleFormat.IEEEFP;
    tag.PlanarConfiguration = Tiff.PlanarConfiguration.Chunky;
    tag.Compression = Tiff.Compression.None;
    tag.RowsPerStrip = 16;
    tag.XResolution = 1e4 / upp;
    tag.YResolution = 1e4 / upp;
    tag.ResolutionUnit = Tiff.ResolutionUnit.Centimeter;
    tag.Software = 'addEmptyMargin';
    t.setTag(tag);
    t.write(imgs{p});
    if p < numel(imgs); t.writeDirectory(); end
end
end
