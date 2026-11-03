classdef StrokeRehabDSS < matlab.apps.AppBase

    % Properties that correspond to app components
    properties (Access = public)
        UIFigure                 matlab.ui.Figure
        LoadModelButton          matlab.ui.control.Button
        LoadFolderButton         matlab.ui.control.Button
        RunClassificationButton  matlab.ui.control.Button

        PatientLabel             matlab.ui.control.Label
        PatientValueLabel        matlab.ui.control.Label

        FolderLabel              matlab.ui.control.Label
        FolderValueLabel         matlab.ui.control.Label

        ModelLabel               matlab.ui.control.Label
        ModelValueLabel          matlab.ui.control.Label

        PredictionLabel          matlab.ui.control.Label
        PredictionValueLabel     matlab.ui.control.Label

        CountsLabel              matlab.ui.control.Label
        CountsTextArea           matlab.ui.control.TextArea

        TrialTable               matlab.ui.control.Table

        RawAccAxes               matlab.ui.control.UIAxes
        RawGyroAxes              matlab.ui.control.UIAxes
        ResultantAxes            matlab.ui.control.UIAxes

        StatusTextArea           matlab.ui.control.TextArea
        SensorDropDownLabel      matlab.ui.control.Label
        SensorDropDown           matlab.ui.control.DropDown
        TrialDropDownLabel       matlab.ui.control.Label
        TrialDropDown            matlab.ui.control.DropDown
        UpdatePlotButton         matlab.ui.control.Button
    end

    properties (Access = private)
        trainedModel
        selectedFolder string = ""
        fs double = 60
        lp_fc double = 12
        hp_fc double = 0.1
        order double = 3

        trialsTable table = table()
        sensorMap
    end

    methods (Access = private)

        function startupFcn(app)
    app.StatusTextArea.Value = [
        "App ready."
        "1) Load Model"
        "2) Load Folder"
        "3) Run Classification"
    ];

    app.ModelValueLabel.Text = "No model loaded";
    app.FolderValueLabel.Text = "No folder selected";
    app.PatientValueLabel.Text = "-";
    app.PredictionValueLabel.Text = "-";
    app.CountsTextArea.Value = "";

    app.TrialTable.Data = table();
    app.TrialTable.ColumnName = {};
end
        function logStatus(app, msg)
            old = app.StatusTextArea.Value;
            if ischar(old)
                old = {old};
            end
            app.StatusTextArea.Value = [old; {char(msg)}];
            drawnow;
        end

        function loadModel(app)
            [file, path] = uigetfile('*.mat', 'Select trained model MAT file');
            if isequal(file, 0)
                app.logStatus("Model load cancelled.");
                return;
            end

            S = load(fullfile(path, file));

            if isfield(S, 'trainedModel')
                app.trainedModel = S.trainedModel;
                app.ModelValueLabel.Text = file;
                app.logStatus("Loaded model: " + string(file));
            else
                uialert(app.UIFigure, ...
                    'MAT file must contain a variable named trainedModel.', ...
                    'Model Error');
            end
        end

        function loadFolder(app)
            folder = uigetdir(pwd, 'Select folder containing MT_*.txt files');
            if isequal(folder, 0)
                app.logStatus("Folder selection cancelled.");
                return;
            end

            app.selectedFolder = string(folder);
            app.FolderValueLabel.Text = app.selectedFolder;

            % Infer patient name from folder name
            [~, patientName] = fileparts(folder);
            app.PatientValueLabel.Text = patientName;

            app.logStatus("Selected folder: " + app.selectedFolder);
        end

        function runClassification(app)
            if isempty(app.trainedModel)
                uialert(app.UIFigure, 'Load the trained model first.', 'Missing Model');
                return;
            end

            if strlength(app.selectedFolder) == 0
                uialert(app.UIFigure, 'Select a folder first.', 'Missing Folder');
                return;
            end

            try
                app.logStatus("Processing folder...");
                [trialResults, sensorMap] = app.processFolder(app.selectedFolder);
                app.sensorMap = sensorMap;
                app.trialsTable = trialResults;
                app.populateSensorAndTrialDropdowns();

                if height(trialResults) == 0
                    uialert(app.UIFigure, 'No valid trials found in this folder.', 'No Data');
                    return;
                end

                % Predict all trials
                predLabels = strings(height(trialResults), 1);

                for i = 1:height(trialResults)
                    Xrow = trialResults(i, :);

                    % If exported model has RequiredVariables, align to that
                    if isfield(app.trainedModel, 'RequiredVariables')
                        reqVars = app.trainedModel.RequiredVariables;
                        Xrow = Xrow(:, reqVars);
                    end

                    pred = app.trainedModel.predictFcn(Xrow);
                    if iscategorical(pred)
                        pred = string(pred);
                    elseif iscell(pred)
                        pred = string(pred{1});
                    elseif ischar(pred)
                        pred = string(pred);
                    else
                        pred = string(pred);
                    end
                    predLabels(i) = pred;
                end

                resultTable = table(trialResults.Trial, predLabels, ...
                    'VariableNames', {'Trial', 'PredictedMovement'});

                app.TrialTable.Data = resultTable;
                app.TrialTable.ColumnName = resultTable.Properties.VariableNames;

                % Show first prediction as main result
                app.PredictionValueLabel.Text = predLabels(1);

                % Movement counts
                [u, ~, idx] = unique(predLabels);
                counts = accumarray(idx, 1);
                txt = strings(numel(u), 1);
                for k = 1:numel(u)
                    txt(k) = u(k) + ": " + counts(k);
                end
                app.CountsTextArea.Value = cellstr(txt);

                % Plot first trial by default
                firstTrial = trialResults.Trial(1);
                app.plotSelectedSensorTrial();

                app.logStatus("Classification complete.");
            catch ME
                app.logStatus("Error: " + string(ME.message));
                uialert(app.UIFigure, ME.message, 'Processing Error');
            end
        end

        function [featureTable, sensorMap] = processFolder(app, inDir)
            files = dir(fullfile(inDir, "MT_*.txt"));
            sensorMap = containers.Map('KeyType', 'char', 'ValueType', 'any');

            [b_lp, a_lp] = butter(app.order, app.lp_fc/(app.fs/2), 'low');
            [b_hp, a_hp] = butter(app.order, app.hp_fc/(app.fs/2), 'high');

            for k = 1:numel(files)
                fname = files(k).name;
                fpath = fullfile(files(k).folder, fname);

                tok = regexp(fname, '^MT_(\d+)_([0-9\-]+)_([A-Fa-f0-9]+)\.txt$', 'tokens', 'once');
                if isempty(tok)
                    app.logStatus("Skipping unexpected filename: " + string(fname));
                    continue
                end

                trialToken = tok{2};
                sensorID   = upper(tok{3});
                trialNum   = str2double(trialToken(1:3));

                opts = detectImportOptions(fpath, ...
                    'FileType', 'text', ...
                    'Delimiter', '\t', ...
                    'VariableNamingRule', 'preserve');

                T = readtable(fpath, opts);

                neededVars = {'Acc_X','Acc_Y','Acc_Z','Gyr_X','Gyr_Y','Gyr_Z'};
                if ~all(ismember(neededVars, T.Properties.VariableNames))
                    app.logStatus("Skipping " + string(fname) + ": required columns not found");
                    continue
                end

                for c = neededVars
                    col = T.(c{1});
                    if iscell(col) || isstring(col)
                        T.(c{1}) = str2double(col);
                    end
                end

                rawAcc  = [T.Acc_X, T.Acc_Y, T.Acc_Z];
                rawGyro = [T.Gyr_X, T.Gyr_Y, T.Gyr_Z];

                X = [rawAcc, rawGyro];
                X(~isfinite(X)) = NaN;
                X = fillmissing(X, 'linear', 1, 'EndValues', 'nearest');
                X(isnan(X)) = 0;

                X_lp = filtfilt(b_lp, a_lp, X);

                lpfAcc  = X_lp(:, 1:3);
                lpfGyro = X_lp(:, 4:6);

                accRes = sqrt(sum(lpfAcc.^2, 2));
                accRes_hp = filtfilt(b_hp, a_hp, accRes);

                if ~isKey(sensorMap, sensorID)
                    S.trials  = [];
                    S.rawAcc  = {};
                    S.lpfAcc  = {};
                    S.rawGyro = {};
                    S.lpfGyro = {};
                    S.res     = {};
                    S.res_hp  = {};
                else
                    S = sensorMap(sensorID);
                end

                S.trials(end+1)   = trialNum;
                S.rawAcc{end+1}   = rawAcc;
                S.lpfAcc{end+1}   = lpfAcc;
                S.rawGyro{end+1}  = rawGyro;
                S.lpfGyro{end+1}  = lpfGyro;
                S.res{end+1}      = accRes;
                S.res_hp{end+1}   = accRes_hp;

                sensorMap(sensorID) = S;
            end

            % Build one feature row per trial
            sensorKeys = sort(keys(sensorMap));
            allTrials = [];
            for i = 1:numel(sensorKeys)
                S = sensorMap(sensorKeys{i});
                allTrials = [allTrials, S.trials];
            end
            trialList = unique(allTrials);

            featureTable = table();

            for tt = 1:numel(trialList)
                trialNum = trialList(tt);
                row = table(trialNum, 'VariableNames', {'Trial'});

                for i = 1:numel(sensorKeys)
                    sensorID = sensorKeys{i};
                    S = sensorMap(sensorID);

                    [~, idx]  = sort(S.trials);
                    S.trials  = S.trials(idx);
                    S.lpfGyro = S.lpfGyro(idx);
                    S.res_hp  = S.res_hp(idx);

                    thisIdx = find(S.trials == trialNum, 1);
                    if isempty(thisIdx)
                        continue
                    end

                    accSig  = S.res_hp{thisIdx};
                    gyroSig = sqrt(sum(S.lpfGyro{thisIdx}.^2, 2));

                    accFeat  = app.extract6Features(accSig, app.fs);
                    gyroFeat = app.extract6Features(gyroSig, app.fs);

                    row.(sprintf('S%s_Acc_STD', sensorID))     = accFeat.std;
                    row.(sprintf('S%s_Acc_RMS', sensorID))     = accFeat.rms;
                    row.(sprintf('S%s_Acc_Entropy', sensorID)) = accFeat.entropy;
                    row.(sprintf('S%s_Acc_Jerk', sensorID))    = accFeat.jerk;
                    row.(sprintf('S%s_Acc_PeakNum', sensorID)) = accFeat.peakNum;
                    row.(sprintf('S%s_Acc_MaxPeak', sensorID)) = accFeat.maxPeak;

                    row.(sprintf('S%s_Gyr_STD', sensorID))     = gyroFeat.std;
                    row.(sprintf('S%s_Gyr_RMS', sensorID))     = gyroFeat.rms;
                    row.(sprintf('S%s_Gyr_Entropy', sensorID)) = gyroFeat.entropy;
                    row.(sprintf('S%s_Gyr_Jerk', sensorID))    = gyroFeat.jerk;
                    row.(sprintf('S%s_Gyr_PeakNum', sensorID)) = gyroFeat.peakNum;
                    row.(sprintf('S%s_Gyr_MaxPeak', sensorID)) = gyroFeat.maxPeak;
                end

                featureTable = [featureTable; row];
            end
        end

        function feat = extract6Features(app, sig, fs)
            sig = sig(:);
            sig(~isfinite(sig)) = 0;

            feat.std = std(sig);
            feat.rms = rms(sig);

            nbins = 30;
            p = histcounts(sig, nbins, 'Normalization', 'probability');
            p = p(p > 0);
            feat.entropy = -sum(p .* log2(p));

            jerkSig = diff(sig) * fs;
            feat.jerk = rms(jerkSig);

            minProm = 0.1 * std(sig);
            if minProm <= 0
                minProm = 1e-6;
            end
            [pks, ~] = findpeaks(abs(sig), 'MinPeakProminence', minProm);
            feat.peakNum = numel(pks);

            if isempty(pks)
                feat.maxPeak = 0;
            else
                feat.maxPeak = max(pks);
            end
        end

            function plotSelectedSensorTrial(app)
        if isempty(app.sensorMap)
            return;
        end
    
        if isempty(app.SensorDropDown.Items) || isempty(app.TrialDropDown.Items)
            return;
        end
    
        sensorID = char(app.SensorDropDown.Value);
        trialNum = str2double(app.TrialDropDown.Value);
    
        if ~isKey(app.sensorMap, sensorID)
            return;
        end
    
        S = app.sensorMap(sensorID);
    
        [~, idx] = sort(S.trials);
        S.trials   = S.trials(idx);
        S.rawAcc   = S.rawAcc(idx);
        S.rawGyro  = S.rawGyro(idx);
        S.res_hp   = S.res_hp(idx);
    
        thisIdx = find(S.trials == trialNum, 1);
        if isempty(thisIdx)
            return;
        end
    
        rawAcc  = S.rawAcc{thisIdx};
        rawGyro = S.rawGyro{thisIdx};
        resHP   = S.res_hp{thisIdx};
    
        cla(app.RawAccAxes);
        plot(app.RawAccAxes, rawAcc, 'LineWidth', 1);
        title(app.RawAccAxes, sprintf('Raw Acceleration - Sensor %s Trial %03d', sensorID, trialNum));
        xlabel(app.RawAccAxes, 'Samples');
        ylabel(app.RawAccAxes, 'Acceleration');
        legend(app.RawAccAxes, {'Acc X','Acc Y','Acc Z'}, 'Location', 'best');
        grid(app.RawAccAxes, 'on');
    
        cla(app.RawGyroAxes);
        plot(app.RawGyroAxes, rawGyro, 'LineWidth', 1);
        title(app.RawGyroAxes, sprintf('Raw Gyroscope - Sensor %s Trial %03d', sensorID, trialNum));
        xlabel(app.RawGyroAxes, 'Samples');
        ylabel(app.RawGyroAxes, 'Angular Velocity');
        legend(app.RawGyroAxes, {'Gyr X','Gyr Y','Gyr Z'}, 'Location', 'best');
        grid(app.RawGyroAxes, 'on');
    
        cla(app.ResultantAxes);
        plot(app.ResultantAxes, resHP, 'LineWidth', 1);
        title(app.ResultantAxes, sprintf('HP-Filtered Acc Resultant - Sensor %s Trial %03d', sensorID, trialNum));
        xlabel(app.ResultantAxes, 'Samples');
        ylabel(app.ResultantAxes, 'Resultant');
        grid(app.ResultantAxes, 'on');
    end

        % Callbacks
        function LoadModelButtonPushed(app, ~)
            app.loadModel();
        end

        function LoadFolderButtonPushed(app, ~)
            app.loadFolder();
        end

        function RunClassificationButtonPushed(app, ~)
            app.runClassification();
        end
        function SensorDropDownValueChanged(app, ~)
            app.plotSelectedSensorTrial();
        end
        
        function TrialDropDownValueChanged(app, ~)
            app.plotSelectedSensorTrial();
        end
        
        function UpdatePlotButtonPushed(app, ~)
            app.plotSelectedSensorTrial();
        end

        function TrialTableCellSelection(app, event)
    if isempty(event.Indices)
        return;
    end

    row = event.Indices(1);
    data = app.TrialTable.Data;

    if istable(data) && row <= height(data)
        trialNum = data.Trial(row);

        if any(strcmp(app.TrialDropDown.Items, sprintf('%d', trialNum)))
            app.TrialDropDown.Value = sprintf('%d', trialNum);
        end

        if ismember('PredictedMovement', data.Properties.VariableNames)
            app.PredictionValueLabel.Text = string(data.PredictedMovement(row));
        end

        app.plotSelectedSensorTrial();
    end
end
    end

    methods (Access = private)

        % Create components
                function createComponents(app)
        
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Name = 'Stroke Rehabilitation DSS';
        
            scr = get(groot,'ScreenSize');
            w = 1280;
            h = 760;
            x = max(1, round((scr(3)-w)/2));
            y = max(1, round((scr(4)-h)/2));
            app.UIFigure.Position = [x y w h];
            app.UIFigure.WindowState = 'normal';
        
            % Top buttons
            app.LoadModelButton = uibutton(app.UIFigure, 'push');
            app.LoadModelButton.Position = [20 715 120 30];
            app.LoadModelButton.Text = 'Load Model';
            app.LoadModelButton.ButtonPushedFcn = createCallbackFcn(app, @LoadModelButtonPushed, true);
        
            app.LoadFolderButton = uibutton(app.UIFigure, 'push');
            app.LoadFolderButton.Position = [155 715 120 30];
            app.LoadFolderButton.Text = 'Load Folder';
            app.LoadFolderButton.ButtonPushedFcn = createCallbackFcn(app, @LoadFolderButtonPushed, true);
        
            app.RunClassificationButton = uibutton(app.UIFigure, 'push');
            app.RunClassificationButton.Position = [290 715 140 30];
            app.RunClassificationButton.Text = 'Run Classification';
            app.RunClassificationButton.ButtonPushedFcn = createCallbackFcn(app, @RunClassificationButtonPushed, true);
        
            % Left info panel
            app.PatientLabel = uilabel(app.UIFigure);
            app.PatientLabel.Position = [20 675 70 22];
            app.PatientLabel.Text = 'Patient:';
        
            app.PatientValueLabel = uilabel(app.UIFigure);
            app.PatientValueLabel.Position = [100 675 250 22];
            app.PatientValueLabel.Text = '-';
        
            app.FolderLabel = uilabel(app.UIFigure);
            app.FolderLabel.Position = [20 645 70 22];
            app.FolderLabel.Text = 'Folder:';
        
            app.FolderValueLabel = uilabel(app.UIFigure);
            app.FolderValueLabel.Position = [100 645 300 40];
            app.FolderValueLabel.WordWrap = 'on';
            app.FolderValueLabel.Text = 'No folder selected';
        
            app.ModelLabel = uilabel(app.UIFigure);
            app.ModelLabel.Position = [20 605 70 22];
            app.ModelLabel.Text = 'Model:';
        
            app.ModelValueLabel = uilabel(app.UIFigure);
            app.ModelValueLabel.Position = [100 605 250 22];
            app.ModelValueLabel.Text = 'No model loaded';
        
            app.PredictionLabel = uilabel(app.UIFigure);
            app.PredictionLabel.Position = [20 565 130 22];
            app.PredictionLabel.Text = 'Predicted Movement:';
        
            app.PredictionValueLabel = uilabel(app.UIFigure);
            app.PredictionValueLabel.Position = [160 565 180 22];
            app.PredictionValueLabel.FontWeight = 'bold';
            app.PredictionValueLabel.Text = '-';
        
            app.CountsLabel = uilabel(app.UIFigure);
            app.CountsLabel.Position = [20 525 120 22];
            app.CountsLabel.Text = 'Movement Counts:';
        
            app.CountsTextArea = uitextarea(app.UIFigure);
            app.CountsTextArea.Position = [20 385 360 135];
        
            % Sensor dropdown
            app.SensorDropDownLabel = uilabel(app.UIFigure);
            app.SensorDropDownLabel.Position = [20 350 50 22];
            app.SensorDropDownLabel.Text = 'Sensor:';
        
            app.SensorDropDown = uidropdown(app.UIFigure);
            app.SensorDropDown.Position = [80 350 140 22];
            app.SensorDropDown.Items = {};
            app.SensorDropDown.ValueChangedFcn = createCallbackFcn(app, @SensorDropDownValueChanged, true);
        
            % Trial dropdown
            app.TrialDropDownLabel = uilabel(app.UIFigure);
            app.TrialDropDownLabel.Position = [20 320 40 22];
            app.TrialDropDownLabel.Text = 'Trial:';
        
            app.TrialDropDown = uidropdown(app.UIFigure);
            app.TrialDropDown.Position = [80 320 140 22];
            app.TrialDropDown.Items = {};
            app.TrialDropDown.ValueChangedFcn = createCallbackFcn(app, @TrialDropDownValueChanged, true);
        
            % Update plot button
            app.UpdatePlotButton = uibutton(app.UIFigure, 'push');
            app.UpdatePlotButton.Position = [240 320 120 52];
            app.UpdatePlotButton.Text = 'Update Plot';
            app.UpdatePlotButton.ButtonPushedFcn = createCallbackFcn(app, @UpdatePlotButtonPushed, true);
        
            % Trial table
            app.TrialTable = uitable(app.UIFigure);
            app.TrialTable.Position = [20 120 360 185];
            app.TrialTable.CellSelectionCallback = createCallbackFcn(app, @TrialTableCellSelection, true);
        
            % Status area
            app.StatusTextArea = uitextarea(app.UIFigure);
            app.StatusTextArea.Position = [20 20 360 80];
        
            % Right plots
            app.RawAccAxes = uiaxes(app.UIFigure);
            title(app.RawAccAxes, 'Raw Acceleration')
            xlabel(app.RawAccAxes, 'Samples')
            ylabel(app.RawAccAxes, 'Acceleration')
            app.RawAccAxes.Position = [420 410 380 300];
        
            app.RawGyroAxes = uiaxes(app.UIFigure);
            title(app.RawGyroAxes, 'Raw Gyroscope')
            xlabel(app.RawGyroAxes, 'Samples')
            ylabel(app.RawGyroAxes, 'Angular Velocity')
            app.RawGyroAxes.Position = [840 410 380 300];
        
            app.ResultantAxes = uiaxes(app.UIFigure);
            title(app.ResultantAxes, 'HP-Filtered Acc Resultant')
            xlabel(app.ResultantAxes, 'Samples')
            ylabel(app.ResultantAxes, 'Resultant')
            app.ResultantAxes.Position = [420 60 800 260];
        
            app.UIFigure.Visible = 'on';
        end
    
    function populateSensorAndTrialDropdowns(app)
    if isempty(app.sensorMap)
        return;
    end

    sensorKeys = sort(keys(app.sensorMap));
    app.SensorDropDown.Items = sensorKeys;

    allTrials = [];
    for i = 1:numel(sensorKeys)
        S = app.sensorMap(sensorKeys{i});
        allTrials = [allTrials, S.trials];
    end

    trialList = unique(allTrials);
    trialItems = arrayfun(@(x) sprintf('%d', x), trialList, 'UniformOutput', false);
    app.TrialDropDown.Items = trialItems;

    if ~isempty(sensorKeys)
        app.SensorDropDown.Value = sensorKeys{1};
    end
    if ~isempty(trialItems)
        app.TrialDropDown.Value = trialItems{1};
    end
    end
    end
    methods (Access = public)

        % Construct app
        function app = StrokeRehabDSS
            createComponents(app)
            runStartupFcn(app, @startupFcn)

            if nargout == 0
                clear app
            end
        end

        % Delete app
        function delete(app)
            delete(app.UIFigure)
        end
    end
end