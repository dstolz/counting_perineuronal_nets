function info = parseSectionName(stem)
%CELLDB.PARSESECTIONNAME The tissue section a file name says it is of, per the lab's naming convention.
%   info = celldb.parseSectionName("SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj")
%
% The convention (docs of the histology_analysis repository, Data Layout and
% File Formats), parsed from the right so the SampleID may contain "_":
%
%   SUBJ-ID-<n><SampleID>_<Section>_<Hemi>_<Stain>_<Z>_<Date>_<ImageNumber>[_<variant>]
%
% with an optional variant marker (_proj, _mid, _composite) and the
% _values / _roi tails of the files written beside an image
% (<image>_proj_roi, <image>_proj_<ROI>_values, ...), which are stripped
% first. A path or extension is ignored. The rules are those of
% histology_analysis's parse_histology_filename (ported, not called: that
% repository need not be here), so both name a section the same way.
%
% Returns a struct with
%   ok            true when the name fits; otherwise every other field is ""
%   SubjectID     "SUBJ-ID-1127": the form the lab database uses
%   SubjectNumber "1127"
%   SampleID      e.g. "IHC_ECM26A260519S2"
%   Protocol      e.g. "IHC_ECM26A" and Series "2" (SampleID = Protocol, a
%                 YYMMDD date, "S", Series); "" when the SampleID has not
%                 that shape (the name still fits)
%   SectionID, Hemisphere, Stain, ZPlane, DateCode, ImageNumber
%   Variant       "raw" (no marker), "proj", "mid" or "composite"
%   ImageKey      the image file's stem, marker included, e.g.
%                 "SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj":
%                 the database's section_image.image_key
%
% A name that does not fit (too few parts, no SUBJ-ID-<n> prefix, empty)
% gives ok = false. Never an error, whatever STEM is.
%
% See also CELLDB.RECORDCURATION.

info = blank();
try
    s = string(stem);
    if ~isscalar(s) || ismissing(s) || strlength(s) == 0
        return
    end
    [~, base] = fileparts(s);
    base = string(base);
    if base == ""
        return
    end
    [core, variant] = stripMarkers(base);
    parts = split(core, "_");
    if numel(parts) < 7
        return
    end
    prefix = join(parts(1:end-6), "_");
    t = regexp(prefix, "^(?<SubjectID>SUBJ-ID-[0-9]+)(?<SampleID>.*)$", "names", "once");
    if isempty(t)
        return
    end
    info.ok = true;
    info.SubjectID = string(t.SubjectID);
    info.SubjectNumber = extractAfter(string(t.SubjectID), "SUBJ-ID-");
    info.SampleID = string(t.SampleID);
    info.SectionID = string(parts(end-5));
    info.Hemisphere = string(parts(end-4));
    info.Stain = string(parts(end-3));
    info.ZPlane = string(parts(end-2));
    info.DateCode = string(parts(end-1));
    info.ImageNumber = string(parts(end));
    info.Variant = variant;
    p = regexp(info.SampleID, "^(?<Protocol>.*?)\d{6}S(?<Series>\d+)$", "names", "once");
    if ~isempty(p)
        info.Protocol = string(p.Protocol);
        info.Series = string(p.Series);
    end
    info.ImageKey = core;
    if variant ~= "raw"
        info.ImageKey = core + "_" + variant;
    end
catch
    info = blank();
end
end

function info = blank()
info = struct("ok", false, "SubjectID", "", "SubjectNumber", "", "SampleID", "", ...
    "Protocol", "", "Series", "", "SectionID", "", "Hemisphere", "", "Stain", "", ...
    "ZPlane", "", "DateCode", "", "ImageNumber", "", "Variant", "", "ImageKey", "");
end

function [stem, variant] = stripMarkers(stem)
%STRIPMARKERS Remove the values/roi tails and the variant marker (as parse_histology_filename does).
variant = "raw";
for suffix = ["values", "roi"]
    token = regexp(stem, "^(?<base>.*?)_proj_(?<roi>\w*?)_?" + suffix + "$", "names", "once");
    if isempty(token)
        continue
    end
    stem = string(token.base);
    variant = "proj";
    return
end
if endsWith(stem, "values")
    stem = regexprep(stem, "_?values$", "");
end
if endsWith(stem, "_roi")
    stem = extractBefore(stem, strlength(stem) - 3);
end
for marker = ["proj", "mid", "composite"]
    if endsWith(stem, "_" + marker)
        stem = extractBefore(stem, strlength(stem) - strlength(marker));
        variant = marker;
        return
    end
end
end
