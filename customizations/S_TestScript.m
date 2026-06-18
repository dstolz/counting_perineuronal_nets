%%

addpath_nogit('c:\src\counting_perineuronal_nets\')

close all force
clear classes

clc

%%
histRoot = "D:/HISTOLOGY (Z1)/";

%% test

ffn = "D:/HISTOLOGY (Z1)/SUBJ-ID-1155/SUBJ-ID-1155IHC_ECM26A260519S2_1E_L_WFA-PV_Z3_260603_1_mid.tif";

I = tiffreadVolume(ffn);

tic
J = correctBidirectionalLSMArtifact(I,NumIterations=5,PyramidDownsample=[4 2 1],ApplyGuidedFilter=true,GuidedNeighborhoodSize=[2 2]);
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

axis(a)

%% Run Cell Discovery on Tifs

CellDiscovery;

%% Fix neighbors
CellNeighborResolverApp;


%% Classify observations
clear CellLocalizationQCApp

CellLocalizationQCApp;

%% Convert exported classified cells

ds = BinaryCellCropDataset( ...
    histRoot + "CellLocalizationQC_observations_20260617_082808.csv", ...
    histRoot + "CellLocalizationQC_observations_20260617_082808", ...
    ClassNames=["Good","Bad"], ...
    Overwrite=true);


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