# Cell Analysis — User Guide

**Cell Analysis** measures every detected cell and shows how the measurements
are distributed: within one section, or across sections grouped by subject, by
what the lab database knows about the subject, or by groups you define.

For each cell it measures

- **where it is**: its distance from the brain surface, its nearest neighbor
  and the local density;
- **its colocalization**: whether a cell of the other channel sits at the same
  place (a PV cell inside a net), how often that would happen by chance, and
  how bright the other channel is inside it;
- **its luminance**: mean, local background, contrast, signal to noise,
  integrated intensity, and the other channel's signal inside it;
- **its morphology**: area, diameter, axes, aspect ratio, perimeter,
  circularity, solidity;
- and for **perineuronal nets**, the net itself: radius, wall thickness, how
  empty the center is, how complete and how even the wall is.

Nothing here changes your detections or your curation: those files are only
read.

---

## Opening it

- From the **[Cell Dataset Manager](CellDatasetManager.md)**: **Analyze…**
- From MATLAB: `CellAnalysis` (then **Browse…**), or `CellAnalysis('<folder>')`.

The folder is the same parent folder you give the other tools; every section
below it is listed.

## The steps

1. **Scan** the folder. The list on the left shows one row per section that has
   the chosen **Cell type** (PNN or PV).
2. **Measure all**. Each channel takes about three seconds. The results are
   kept beside the data, so this is done once; later runs only measure what is
   new. You can stop and continue another day.
3. Choose a **Plot**, a **Metric** and a **Group by** on the *Distributions*
   tab. The table under the plot holds the numbers.
4. Check the brain surface of your sections on the *Section* tab (see below).
5. **Export cells…** or **Export sections…** for statistics elsewhere.

## Which cells are analyzed

| Cells | Meaning |
| --- | --- |
| **Kept cells** (default) | The cells a person kept in [Cell Curator](CellCurator.md): labeled Good, reviewed, outside exclusion regions. A section that was never curated has none. |
| **All detections** | Every candidate that is not merged, stale or inside an exclusion region, reviewed or not. Use it to look at sections before they are curated; with a detection threshold of 0 this includes many false detections. |

Positions are the curated ones: cells you moved, added or merged are measured
where you put them.

**Reject near surface (um)** leaves out every cell closer than that many
micrometers to the [brain surface](#the-brain-surface), for example the bright
rim of stain along the pia, where most detections are not cells. 0 (the
default) rejects none. The rejected cells take no part in anything: the plots,
the list, the pairing with the other channel (its cells near the surface are
rejected too), the nearest neighbors and the exports. The tissue that close to
the surface is left out of the tissue area, so densities stay densities of the
tissue that is analyzed. A section whose surface was not found keeps all its
cells; the status line says how many such sections there are. Changing the
distance needs no new measurement, and your curation is not changed: in Cell
Curator the cells are as you left them. The plot titles say *at least … um from
the surface* while it is on, and the window remembers it.

## The list of sections

| Column | Meaning |
| --- | --- |
| **Use** | Uncheck a section to leave it out of the plots and the exports. |
| **Subject**, **Section** | From the file name (`SUBJ-ID-<n>…_<Section>_<Hemi>_…`). |
| **Group** | Your own group. Type a name, or select several rows and press **Set group…**. |
| **Cells** | Cells of the chosen type and population, without those rejected near the surface. |
| **Measured** | `yes`, `no`, or `out of date`: the curation, the image or the brain surface changed since the section was measured. Measure it again; only what changed is redone. |
| **Surface** | How the brain surface is defined: automatic, every area, or traced. `not found` means the picture shows no empty space beside the tissue. |

Select a row to see that section on the *Section* tab. Select several rows
(Shift or Ctrl) to measure them or to set their group.

## Grouping

**Group by** offers

- from the file names: **Section**, **Subject**, **Hemisphere**, **Stain**;
- from the lab database: **Sex**, **Species**, **Project**, and the subject's
  tags and variables (see [Lab database tags and variables](#lab-database-tags-and-variables)).
  These are what this computer last heard from the database about each subject
  (press **Check subjects**, here or in the Cell Dataset Manager, to ask it).
  Without the database they are empty and everything else works the same;
- yours: **Group**, and every column you imported;
- **Colocalized**: splits the cells of each section by whether they are paired
  with a cell of the other channel (see [Colocalization](#colocalization)).

**Import groups…** reads a spreadsheet or CSV. One column must name the
subject (`Subject`, `SubjectID`, `Animal`) or the section (`Dataset`,
`Section`, `Image Filename`); every other column becomes a grouping, for
example:

```
Subject,Treatment,Age
1127,noise,P90
1146,sham,P90
```

A section tracker exported as CSV works too (its `Image Filename` column is
the key). Your groups are kept in `cellanalysis_groups.csv` in the scanned
folder, so they are there next time and for everyone who opens that folder.

## Lab database tags and variables

In the lab database (CarasLabDB) a subject can carry **tags** (labels such as
`cohort:a`, `condition:noise`, or a bare word such as `pilot`) and
**variables** (named values such as `age at perfusion` = 92 d or `housing` =
pair). They are set in the lab database's own window, not here. **Check
subjects** (under the list) asks the database about the subjects the file
names here name; it takes a few seconds, the answers are kept on this
computer, and nothing else in this window talks to the server. After that:

| In the database | Here |
| --- | --- |
| a tag namespace (`cohort:a`, `cohort:b`) | **Group by → Tag: cohort**, with the groups `a`, `b` |
| a bare tag (`pilot`) | **Group by → Tag: pilot**, with the groups `pilot`, `not pilot` |
| a text variable (`housing`) | **Group by → Variable: housing** |
| a number variable (`age at perfusion`, in d) | **Group by → Variable: Age at perfusion (d)** (one group per value), and **Metric** and **Against (scatter) → Variable: Age at perfusion (d)** |

A number variable is one value per subject, the same for every cell of it. To
plot a measurement against it, choose **Scatter**, the measurement as
**Metric**, the variable under **Against (scatter)** and **One point per →
Subjects** (or Sections): each point is then the median of a subject's cells
at that subject's value. With *Cells* every cell is a point and the cells of a
subject form a column.

**Use by tags** checks the sections by the tags of their subject and unchecks the
others: type a filter and press Enter. It is the filter of the lab database's
own window: tags separated by spaces must all hold, a leading `-` means "does
not have", `cohort:*` means any tag of that namespace, a bare word is a bare
tag. `cohort:a -qc:fail` checks the sections of cohort a that are not marked as
failed. A subject that was never checked, or that the database does not have,
is left out, and the status line says when no subject here carries a tag you
typed (a misspelt tag behind `-` would otherwise hide nothing without a word).

The detail under the list shows the selected section's tags and variables, and
both exports carry them as columns (`Tag_cohort`, `HasTag_pilot`,
`Var_age_at_perfusion`, ...). Nothing of this is stored with the measurements:
a scan reads it again from this computer's cache.

## The plots

| Plot | Shows |
| --- | --- |
| **Histogram** | How the values are spread. With groups, the share of each group in each bin, so groups of different size compare. |
| **Cumulative** | The share of cells at or below each value. The clearest way to compare the distributions of two groups. |
| **Box by group** | Median, quartiles and whiskers (1.5 × the interquartile range) per group, with the observations on top when there are few. |
| **Metric by depth** | The metric against the distance from the brain surface: one profile per section, the group's mean with a band of ± 1 SEM. |
| **Cell density by depth** | Cells per mm² of tissue at each depth. The tissue area at each depth is measured in the picture, without exclusion regions and, if the section has analysis regions, only inside them. With **Reject near surface** the depths within it have no value, and a bin across its border counts only the tissue beyond it; a dashed line marks the border (also on the histogram and cumulative plot of the distance from the surface). |
| **Colocalization** | Per group, the share of the analyzed cells that are paired with a cell of the other channel, the share of the other channel's cells that are paired with one of these, and the share chance alone would give. See [Colocalization](#colocalization). |
| **Scatter** | One metric against another, with the Spearman correlation. |

**One point per** decides what an observation is:

- **Cells**: every cell counts once. Sections with many cells weigh more, and
  cells of one animal are not independent, so use this to look, not to test.
- **Sections**: one value per section, the median of its cells (the fraction
  for *Colocalized*).
- **Subjects**: one value per animal.

**Sections** switches between the checked sections (across sections) and the
selected one (within a section).

With more than eight groups the groups are drawn in one color (eight is as
many as can be told apart); the table still lists each group.

## Colocalization

A section with two channels (WFA and PV) answers three questions.

**Which cells are colocalized?** The nets and the PV cells of a section are
paired **one to one**: every net and PV cell no farther apart than **Coloc.
within (um)** is a candidate pair, the closest pairs are made first, and a
cell is in one pair at most. So a PV cell between two nets belongs to the
nearer one, and the number of colocalized cells is the same whichever channel
you look from. Only cells of the chosen population are paired: with *Kept
cells*, kept nets with kept PV cells; with **Reject near surface**, neither
channel's cells near the surface.

To choose the distance, plot the **Histogram** of *Nearest cell of other
channel*: true pairs pile up within a few micrometers and everything else is
spread out far beyond; the dashed line marks your distance. 10 µm is the
default.

**How much is colocalized?** Choose the plot **Colocalization**. For each
group it shows

- the percentage of the analyzed cells that have a partner (for example *PNN
  with PV*: nets that surround a PV cell),
- the percentage of the other channel's cells that have a partner (*PV with
  PNN*: PV cells that carry a net),
- a gray line: the percentage of the analyzed cells that would be paired **by
  chance**.

Bars are the mean of the sections, dots the sections. The table adds the
counts (cells of each channel, pairs), the standard error over sections, and
**x chance**: how many times above chance the pairing is.

The chance level is measured in the section itself: the other channel is
displaced by 50 µm (or 5 × the colocalization distance, if that is more) in
eight directions, and the pairing is repeated each time. A displacement of
that size keeps the layers and the local density of the other channel but
breaks every true pairing, so what remains is what density alone gives. A
percentage near the chance line means the two channels do not coincide more
than their densities make them.

**Do colocalized cells differ?**

- **Group by → Colocalized** splits any plot into colocalized and not
  colocalized cells: are nets around PV cells brighter, larger, more complete,
  deeper?
- The metric **Colocalized (fraction)** can be plotted like any other, for
  example with **Metric by depth**: the share of nets with a PV cell at each
  depth.
- The metrics **Other channel above background** and **Other channel signal
  to noise** measure the other channel inside each cell without any pairing:
  the PV signal inside every net. **Scatter** *Mean above background* against
  it to relate the brightness of a net to that of the cell inside it.

**Export cells…** writes `Colocalized`, `ColocChance`, `OtherDistUm` and
`PartnerID` for every cell. `PartnerID` is the `CellID` of the partner in the
other channel's export of the same section, so the two exports can be joined
pair by pair. **Export sections…** writes the counts per section (`Cells`,
`OtherCells`, `Pairs`, `ColocalizedOfOther`, `TissueMm2`).

## The brain surface

The distance from the brain surface is the shortest distance from the cell to
the edge between the tissue and the empty space outside it. The edge of the
picture is never surface: tissue that is cut off by the frame simply continues.

On the *Section* tab the surface is drawn in **red**. Check it for each
section; it takes a second. With **Reject near surface** on, a dashed red line
marks the border of the band it rejects and red crosses the cells it leaves
out.

| Brain surface | Meaning |
| --- | --- |
| **Automatic** | The edge of the largest empty area of the picture. A ventricle or a tear is empty too, but is not the outside of the brain, so its edge is drawn dotted blue and does not count. |
| **Every empty area** | Every empty area counts, ventricles included. |
| **Traced line** | The line you drew with **Trace surface…** (click along the surface, double-click to finish). |

To correct the automatic surface, switch **Pick empty areas** on and click an
empty area: its edge is switched on or off as surface. Use it to switch a
ventricle off, or to switch on a part of the outside that a shred of tissue
cut off from the rest.

Trace the surface when the picture shows no empty space beside the tissue
(`not found`), or when the automatic one is wrong in a way picking cannot fix.

The surface belongs to the section and is shared by its channels. After you
change it the section is `out of date`: press **Measure selected**.

Distances are good to a few micrometers. They are distances in the plane of
the picture; where the cortex curves or is cut obliquely, depth is not the
same as cortical layer.

## The metrics

Hover over the **Metric** list for a description of the chosen one. Lengths
are in micrometers; luminance is in the units of the picture as it is stored
(not normalized), unless the name says otherwise.

### Position

| Metric | Meaning |
| --- | --- |
| Distance from brain surface | See above. |
| Nearest neighbor | Distance to the nearest other cell of the same channel, among the cells analyzed. |
| Local density | Cells of the same channel within 100 µm, per mm². Not corrected at the edge of the tissue. |
| Nearest cell of other channel | PV for a net, a net for a PV cell. |
| Colocalized (fraction) | 1 when the cell is paired with a cell of the other channel (see [Colocalization](#colocalization)); the mean is the fraction of colocalized cells. |
| Colocalized by chance (fraction) | How often the cell would be paired by chance (the other channel displaced by 50 µm). |
| Long axis vs surface normal | 0° = the cell's long axis points away from the surface, 90° = parallel to it. Only meaningful for elongated cells. |

### Luminance

| Metric | Meaning |
| --- | --- |
| Mean intensity | Mean pixel value inside the cell (a net: its stained wall). |
| Local background | Median of a ring around the cell (15–23 µm from a soma, 20–28 µm from a net). |
| Mean above background | Mean − background. |
| Contrast | (Mean − background) / background. Does not depend on the gain of the picture. |
| Signal to noise | (Mean − background) / the spread of the background ring. |
| Mean / tissue median | Mean divided by the median of the section's tissue: comparable between sections of different brightness. |
| Integrated intensity | Sum of (pixel − background) over the cell × pixel area: the total stain. |
| Peak above background | The brightest point of the cell − background. |
| Aperture mean above background | Mean within a fixed radius (6 µm for a soma, 11 µm for a net) − background. Needs no outline, so every cell has it. |
| Other channel above background, signal to noise | The other channel inside the cell's footprint: PV inside a net, WFA around a PV cell. |

Comparing luminance between sections only makes sense when they were stained
and imaged the same way. *Contrast*, *Signal to noise* and *Mean / tissue
median* are relative to the section and tolerate differences in brightness
better than the raw values.

### Morphology

The cell is outlined at half of its brightness above the background: a soma is
the connected bright piece under the detection, with holes filled; a net is
the convex hull of its stained wall, so an open (C-shaped) net has a footprint
too.

| Metric | Meaning |
| --- | --- |
| Area, Equivalent diameter | Of the footprint. |
| Half-maximum radius | Where the cell's radial brightness profile falls to half: a size that needs no outline. |
| Major axis, Minor axis, Aspect ratio | Of the ellipse with the same second moments as the footprint. |
| Perimeter, Circularity | 4π·area / perimeter²: 1 = a circle. |
| Solidity | Stained area / area of its convex hull: 1 = solid and convex; a thin or open net is low. |
| Orientation in the image | Angle of the long axis, counter-clockwise from the horizontal. |

### Nets only

| Metric | Meaning |
| --- | --- |
| Net stained area | Area of the wall. |
| Net radius | Distance of the wall from the center (the peak of the radial profile). |
| Net wall thickness | Full width at half maximum of the wall. |
| Net ring contrast | (wall − center) / (wall − background): 1 = an empty center, 0 = the center is as bright as the wall. |
| Net completeness | Share of 16 directions in which the wall is present: 1 = a closed ring. |
| Net wall unevenness | Variation of the wall's brightness around the ring: 0 = even. |

**How far to trust the shapes.** The picture sets the limit. At 1.66 µm per
pixel a PV soma is about 8 pixels across, so the shape of a single cell is
coarse; the distributions over hundreds of cells are meaningful. A cell that
runs into a bright neighbor is flagged (`TouchesEdge` in the export): its size
is a lower bound. A cell with no signal above its background is not outlined
(`Segmented` = 0) and has no shape; it still has its position and its aperture
luminance.

## Exports

- **Export cells…** — one row per cell behind the plot: section, subject,
  hemisphere, stain, sex, species, project, the subject's lab database tags and
  variables, your groups, `CellID`, `X`, `Y`,
  `score`, `rescore`, `Label`, `Kept`, every metric, `PartnerID`, and the flags
  `Segmented`, `TouchesEdge`, `InTissue`, `InAnalysis`.
- **Export sections…** — one row per section: its tags, the number of cells,
  the cells of the other channel, the pairs and the tissue area, the
  **Reject near surface** distance (`MinDepthUm`, 0 = off) and how many cells
  it rejected (`RejectedNearSurface`), and the median of every metric (the
  fraction for *Colocalized*).
- **Save figure…** — the plot or the map of the visible tab (PNG, PDF, SVG).

## Shortcuts

| Key | Action |
| --- | --- |
| **F5** | Scan |
| **Ctrl+M** | Measure the selected sections |
| **Ctrl+E** | Export cells |

## The files it writes

| File | Where | Holds |
| --- | --- | --- |
| `<stem>_metrics.csv` | beside the `_locs.csv` | the measurements of every cell of one channel |
| `<base>.cellanalysis.json` | the section's folder | the surface definition, when each channel was measured and from what, the tissue area at each depth |
| `cellanalysis_groups.csv` | the scanned folder | your groups |

They can be deleted at any time; measuring writes them again.

## From code

```matlab
S = cellanalysis.Project.sources(folder);              % one row per channel of a section
for i = 1:height(S), cellanalysis.Project.measure(S(i, :)); end
S = cellanalysis.Project.sources(folder);
[C, Sec] = cellanalysis.Project.load(S, "pnn");        % one row per kept net, with tags and metrics
C50 = cellanalysis.Project.load(S, "pnn", struct('MinDepthUm', 50));   % none within 50 um of the surface
K = cellanalysis.Stats.colocalization(C, Sec, "Subject");   % pairs with the PV channel, per section and group
R = cellanalysis.Stats.summary(C, "RingRadiusUm", "Subject", "section");
D = cellanalysis.Stats.depthProfile(C, S, "Density", "Subject", struct('BinUm', 100));

% one image, no files
Sf = cellanalysis.Surface.detect({wfa, pv}, umPerPx);
d  = cellanalysis.Surface.distanceAt(Sf, [X Y]);
T  = cellanalysis.Measure.cells(wfa, [X Y], umPerPx, "pnn", struct('Other', pv));
R  = cellanalysis.Measure.colocalize(netsXY, pvXY, umPerPx, struct('MaxUm', 10));   % pairs and chance level
cellanalysis.Measure.catalog()                          % every metric and what it means
```

The help of `cellanalysis.Measure`, `cellanalysis.Surface`,
`cellanalysis.Project` and `cellanalysis.Stats` describes each step exactly.
