%%

addpath_nogit('c:\src\counting_perineuronal_nets\')

close all force
clear classes

clc

%%
histRoot = "D:/HISTOLOGY (Z1)/";


%% Dataset overview + status dashboard
% Find every dataset under histRoot, report which pipeline stages have run,
% and launch the per-dataset tools from one window.

CellDatasetManager(histRoot);

%% Headless equivalents (no GUI):
datasets = CellDatasetManager.scan(histRoot);
T = CellDatasetManager.statusTable(histRoot);


%% Headless self-test: CellDatasetManifest authority + round-trip
% Builds a throwaway dataset (2-page TIFF + a PNN1 locs CSV), drives the
% manifest the way the GUIs do, and checks that file resolution, the active
% analysis pointer, recording, discovery and the dashboard projection all work.
% Self-contained: does not touch histRoot.

mfRoot = fullfile(tempdir, ['celldataset_selftest_' char(java.util.UUID.randomUUID)]);
mkdir(mfRoot);
if ispref('CellDatasetManager','locsToken')
    mfOldTok = getpref('CellDatasetManager','locsToken');
else
    mfOldTok = [];
end
setpref('CellDatasetManager','locsToken','_locs');   % deterministic for the test
try
    mfBase = 'slice42';
    mfTif  = fullfile(mfRoot, [mfBase '.tif']);
    imwrite(uint8(zeros(32,32)), mfTif);
    imwrite(uint8(zeros(32,32)), mfTif, 'WriteMode', 'append');   % 2 pages
    % A fully-processed plain locs CSV: carries CURATED_* (resolved) and
    % rescore columns, so the dashboard re-derives Resolved/Rescored = true.
    mfCsv  = fullfile(mfRoot, [mfBase '_PNN1_locs.csv']);
    writetable(table([10;20],[30;40],[10;20],[30;40],[0.8;0.4], ...
        'VariableNames',{'X','Y','CURATED_X','CURATED_Y','rescore'}), mfCsv);
    mfRcsv = fullfile(mfRoot, [mfBase '_PNN1_locs_resized.csv']);
    writetable(table([5;10],[15;20],'VariableNames',{'X','Y'}), mfRcsv);
    % A QC review file paired with the plain locs CSV.
    mfQc = fullfile(mfRoot, [mfBase '_PNN1_locs_QC.csv']);
    writetable(table(["Good";"Bad"],[true;true], ...
        'VariableNames',{'QCLabel','QCReviewed'}), mfQc);

    % Resolution authority
    mf  = CellDatasetManifest.forCsv(mfCsv);
    key = CellDatasetManifest.keyForCsv(mfCsv);
    assert(strcmp(key,'PNN1'));
    assert(strcmp(mf.activeLocs(key), mfCsv));
    assert(strcmp(mf.locsPath(key,'resized'), mfRcsv));
    assert(strcmp(mf.imageForLocs(mfCsv), mfTif));            % full-res image
    assert(strcmp(mf.imageForLocs(mfRcsv), ''));             % no resized TIFF yet

    % Simulate the pipeline the way the GUIs record it
    mf.recordDetection(key, struct('image',mfTif,'page',1,'locs',mfCsv, ...
        'tool','CellDiscovery','model','det','count',2));
    mf.recordResized(key, mfRcsv, '');
    mf.recordResolve(key, struct('tool','CellNeighborResolution'));
    mf.recordRescore(key, struct('tool','CellNeighborResolution','model','sc'));
    mf.recordQc(key, mfQc, ...
        struct('reviewed',2,'good',1,'bad',1,'uncertain',0,'tool','CellQualityControl'));
    assert(mf.save());

    % Reload + dashboard projection
    mf2 = CellDatasetManifest.forBase(mfRoot, mfBase);
    assert(isequal(mf2.analyzedPages(), 1));
    assert(strcmp(mf2.Data.image.file, [mfBase '.tif']));

    ds = CellDatasetManager.scan(mfRoot);
    assert(numel(ds)==1 && numel(ds(1).Sources)==1);
    assert(isa(ds(1).ManifestObj,'CellDatasetManifest'));
    assert(ds(1).Sources(1).Resolved && ds(1).Sources(1).Rescored);
    assert(ds(1).Sources(1).Reviewed);
    assert(strcmp(ds(1).Status,'Reviewed'));

    % User override via setActiveLocs (what the dashboard's "Set active locs" does)
    mf2.setActiveLocs(key, mfRcsv);
    assert(strcmp(mf2.coordSpace(key),'resized'));
    assert(strcmp(mf2.activeLocs(key), mfRcsv));
    mf2.save();

    disp('CellDatasetManifest self-test: PASSED');
catch ME
    disp(['CellDatasetManifest self-test: FAILED -- ' ME.message]);
end
% Restore the locs-token preference and clean up the throwaway dataset.
if isempty(mfOldTok)
    if ispref('CellDatasetManager','locsToken'); rmpref('CellDatasetManager','locsToken'); end
else
    setpref('CellDatasetManager','locsToken', mfOldTok);
end
rmdir(mfRoot, 's');
clear mfRoot mfOldTok mfBase mfTif mfCsv mfRcsv mf mf2 key ds ME


%% Run Cell Discovery on Tifs

CellDiscovery;




%% Fix neighbors

CellNeighborResolution;




%% Classify observations

CellQualityControl;




%% test

ffn = "D:/HISTOLOGY (Z1)/SUBJ-ID-1127/SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_mid.tif";

I = tiffreadVolume(ffn);

tic
J = correctBidirectionalLSMArtifact(I,NumIterations=5,PyramidDownsample=[8 4 2 1],ApplyGuidedFilter=false);
toc

figure
ax(1) = subplot(121);
imagesc(I(:,:,1));
axis image

ax(2) = subplot(122);
imagesc(J(:,:,1));
axis image


colormap gray

linkaxes(ax)


%% Gabor filters
% https://www.mathworks.com/help/images/texture-segmentation-using-gabor-filters.html
imds = imageDatastore(histRoot + "CellLocalizationQC_observations_20260617_082808", ...
    IncludeSubfolders=true, ...
    LabelSource = 'foldernames', ...
    FileExtensions=[".tif" ".tiff"]);

A = imread(imds.Files{1});


[numRows,numCols,~] = size(A);

wavelengthMin = 4/sqrt(2);
wavelengthMax = hypot(numRows,numCols);
n = floor(log2(wavelengthMax/wavelengthMin));
wavelength = 2.^(0:(n-2)) * wavelengthMin;

deltaTheta = 12;
orientation = 0:deltaTheta:(180-deltaTheta);



g = gabor(wavelength,orientation);


idx = randperm(length(imds.Files));
for i = idx
    A = imread(imds.Files{i});
    Agray = im2gray(A);

    gabormag = imgaborfilt(Agray,g);

    K = 2;
    for k = 1:length(g)
        sigma = 0.5*g(k).Wavelength;
        gabormag(:,:,k) = imgaussfilt(gabormag(:,:,k),K*sigma);
    end


    X = 1:numCols;
    Y = 1:numRows;
    [X,Y] = meshgrid(X,Y);
    featureSet = cat(3,gabormag,X,Y);


    X = reshape(featureSet,numRows*numCols,[]);
    Xnorm = (X-mean(X))./std(X);
    featureSetNorm = reshape(Xnorm,numRows,numCols,[]);

    t = tiledlayout('flow');

    nexttile
    montage(featureSetNorm,[],Size=[5 6],Background="w")


    featureSet = im2single(featureSet);
    L = imsegkmeans(featureSet,2,NormalizeInput=true,NumAttempts=5);

    Aseg1 = zeros(size(A),"like",A);
    Aseg2 = zeros(size(A),"like",A);
    BW = L == 2;
    Aseg1(BW) = A(BW);
    Aseg2(~BW) = A(~BW);

    nexttile
    montage({Aseg1,Aseg2});

    title(t,imds.Files{i},Interpreter = 'none');
    pause(1)
end


%% Post-Processing Reclassification
% adapted from: https://www.mathworks.com/help/deeplearning/gs/create-simple-image-classification-network-using-deep-network-designer.html
imds = imageDatastore("CellLocalizationQC_observations_20260617_082808", ...
    IncludeSubfolders=true, ...
    LabelSource = 'foldernames', ...
    FileExtensions=[".tif" ".tiff"]);

classNames = categories(imds.Labels);

[imdsTrain,imdsValidation,imdsTest] = splitEachLabel(imds,0.7,0.15,0.15,"randomized");

%%

% deepNetworkDesigner
net = dlnetwork;

tempNet = [
    imageInputLayer([30 30 1],"Name","imageinput")
    convolution2dLayer([3 3],32,"Name","conv","Padding","same")
    batchNormalizationLayer("Name","batchnorm")
    reluLayer("Name","relu")
    fullyConnectedLayer(2,"Name","fc")
    softmaxLayer("Name","sigmoid")];
net = addLayers(net,tempNet);

% clean up helper variable
clear tempNet;

net = initialize(net);

% plot(net)

%%
options = trainingOptions("sgdm", ...
    MaxEpochs=4, ...
    ValidationData=imdsValidation, ...
    ValidationFrequency=30, ...
    Plots="training-progress", ...
    Metrics="accuracy", ...
    Verbose=false);


net = trainnet(imdsTrain,net,"crossentropy",options);


accuracy = testnet(net,imdsValidation,"accuracy")

scores = minibatchpredict(net,imdsValidation);
YValidation = scores2label(scores,classNames);

%%

nClasses = length(classNames);

numValidationObservations = numel(imdsValidation.Files);
idx = randi(numValidationObservations,nClasses,1);

figure
tiledlayout("flow")
for i = 1:nClasses
    nexttile
    img = readimage(imdsValidation,idx(i));
    imshow(img)
    title("Predicted Class: " + string(YValidation(idx(i))))
end