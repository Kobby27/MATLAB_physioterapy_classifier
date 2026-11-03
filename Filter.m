% ============================================
% Pre-processing for Xsens text files
% Clean version
% 1) LPF sensor data: 3rd-order Butterworth, 12 Hz
% 2) Compute acceleration resultant
% 3) HPF resultant: 3rd-order Butterworth, 0.1 Hz
% ============================================

clear
clc
close all

inDir  = "C:\Users\user\OneDrive\Desktop\Soton\year 2\BD6\Horizontal arm\Steve";
outDir = fullfile(inDir, "processed_lpf_hpf");

if ~exist(outDir, 'dir')
    mkdir(outDir);
end
personName   = "Khaled";
exerciseName = "Cup2Mouth";
% --------------------------------------------
% Filter parameters
% --------------------------------------------
fs = 60;
lp_fc = 12;
hp_fc = 0.1;
order = 3;

[b_lp, a_lp] = butter(order, lp_fc/(fs/2), 'low');
[b_hp, a_hp] = butter(order, hp_fc/(fs/2), 'high');

files = dir(fullfile(inDir, "MT_*.txt"));


sensorMap = containers.Map('KeyType','char','ValueType','any');

% ============================================
% READ + PROCESS FILES
% ============================================
for k = 1:numel(files)

    fname = files(k).name;
    fpath = fullfile(files(k).folder, fname);

    tok = regexp(fname, '^MT_(\d+)_([0-9\-]+)_([A-Fa-f0-9]+)\.txt$', 'tokens', 'once');
    if isempty(tok)
        fprintf('Skipping unexpected filename: %s\n', fname);
        continue
    end

    trialToken = tok{2};
    sensorID   = upper(tok{3});
    trialNum   = str2double(trialToken(1:3));

    % Read table
    opts = detectImportOptions(fpath, ...
        'FileType', 'text', ...
        'Delimiter', '\t', ...
        'VariableNamingRule', 'preserve');

    T = readtable(fpath, opts);

    neededVars = {'Acc_X','Acc_Y','Acc_Z','Gyr_X','Gyr_Y','Gyr_Z'};
    if ~all(ismember(neededVars, T.Properties.VariableNames))
        fprintf('Skipping %s: required columns not found\n', fname);
        continue
    end

    % Convert to numeric if needed
    for c = neededVars
        col = T.(c{1});
        if iscell(col) || isstring(col)
            T.(c{1}) = str2double(col);
        end
    end

    % Build signal matrix
    rawAcc  = [T.Acc_X, T.Acc_Y, T.Acc_Z];
    rawGyro = [T.Gyr_X, T.Gyr_Y, T.Gyr_Z];

    X = [rawAcc, rawGyro];

    X(~isfinite(X)) = NaN;
    X = fillmissing(X, 'linear', 1, 'EndValues', 'nearest');
    X(isnan(X)) = 0;

    % LPF sensor data
    X_lp = filtfilt(b_lp, a_lp, X);

    lpfAcc  = X_lp(:,1:3);
    lpfGyro = X_lp(:,4:6);

    % Resultant from LPF acceleration
    accRes = sqrt(sum(lpfAcc.^2, 2));
    accRes_hp = filtfilt(b_hp, a_hp, accRes);

    % Save processed table
    Tf = T;
    Tf.Acc_X = lpfAcc(:,1);
    Tf.Acc_Y = lpfAcc(:,2);
    Tf.Acc_Z = lpfAcc(:,3);

    Tf.Gyr_X = lpfGyro(:,1);
    Tf.Gyr_Y = lpfGyro(:,2);
    Tf.Gyr_Z = lpfGyro(:,3);

    Tf.Acc_Resultant    = accRes;
    Tf.Acc_Resultant_HP = accRes_hp;

    writetable(Tf, fullfile(outDir, fname), 'Delimiter', '\t');

    % Store by sensor
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

disp("Processing complete")

% % FEATURE EXTRACTION

% sensorKeys = sort(keys(sensorMap));   % keep sensor order consistent
% 
% % Get all trial numbers present across sensors
% allTrials = [];
% for i = 1:numel(sensorKeys)
%     S = sensorMap(sensorKeys{i});
%     allTrials = [allTrials, S.trials];
% end
% trialList = unique(allTrials);
% 
% featureTable = table();
% 
% for tt = 1:numel(trialList)
% 
%     trialNum = trialList(tt);
% 
%     % Start one row
%     row = table(string(personName), string(exerciseName), trialNum, ...
%         'VariableNames', {'Person','Exercise','Trial'});
% 
%     for i = 1:numel(sensorKeys)
% 
%         sensorID = sensorKeys{i};
%         S = sensorMap(sensorID);
% 
%         % sort this sensor by trial
%         [~, idx]  = sort(S.trials);
%         S.trials  = S.trials(idx);
%         S.lpfGyro = S.lpfGyro(idx);
%         S.res_hp  = S.res_hp(idx);
% 
%         thisIdx = find(S.trials == trialNum, 1);
% 
%         if isempty(thisIdx)
%             warning('Sensor %s missing trial %d', sensorID, trialNum);
%             continue
%         end
% 
%         % Signals for this trial/sensor
%         accSig  = S.res_hp{thisIdx};                          % 1D
%         gyroSig = sqrt(sum(S.lpfGyro{thisIdx}.^2, 2));        % 1D magnitude
% 
%         % Extract 6 features from each
%         accFeat  = extract6Features(accSig, fs);
%         gyroFeat = extract6Features(gyroSig, fs);
% 
%         % Add to row with sensor-specific names
%         row.(sprintf('S%s_Acc_STD', sensorID))        = accFeat.std;
%         row.(sprintf('S%s_Acc_RMS', sensorID))        = accFeat.rms;
%         row.(sprintf('S%s_Acc_Entropy', sensorID))    = accFeat.entropy;
%         row.(sprintf('S%s_Acc_Jerk', sensorID))       = accFeat.jerk;
%         row.(sprintf('S%s_Acc_PeakNum', sensorID))    = accFeat.peakNum;
%         row.(sprintf('S%s_Acc_MaxPeak', sensorID))    = accFeat.maxPeak;
% 
%         row.(sprintf('S%s_Gyr_STD', sensorID))        = gyroFeat.std;
%         row.(sprintf('S%s_Gyr_RMS', sensorID))        = gyroFeat.rms;
%         row.(sprintf('S%s_Gyr_Entropy', sensorID))    = gyroFeat.entropy;
%         row.(sprintf('S%s_Gyr_Jerk', sensorID))       = gyroFeat.jerk;
%         row.(sprintf('S%s_Gyr_PeakNum', sensorID))    = gyroFeat.peakNum;
%         row.(sprintf('S%s_Gyr_MaxPeak', sensorID))    = gyroFeat.maxPeak;
%     end
% 
%     featureTable = [featureTable; row];
% end
% 
% disp("Feature extraction complete")
% disp(featureTable)
% 
% writetable(featureTable, fullfile(outDir, "features_table.csv"));
% disp("Feature table saved")

% ============================================
% PLOTTING
% ============================================
sensorKeys = keys(sensorMap);

for i = 1:numel(sensorKeys)

    sensorID = sensorKeys{i};
    S = sensorMap(sensorID);

    % Sort everything by trial number
    [~, idx]   = sort(S.trials);
    S.trials   = S.trials(idx);
    S.rawAcc   = S.rawAcc(idx);
    S.lpfAcc   = S.lpfAcc(idx);
    S.rawGyro  = S.rawGyro(idx);
    S.lpfGyro  = S.lpfGyro(idx);
    S.res      = S.res(idx);
    S.res_hp   = S.res_hp(idx);

    for t = 1:numel(S.trials)

        trialNum = S.trials(t);

        rawAcc   = S.rawAcc{t};
        lpfAcc   = S.lpfAcc{t};
        rawGyro  = S.rawGyro{t};
        lpfGyro  = S.lpfGyro{t};
        accRes   = S.res{t};
        accResHP = S.res_hp{t};

        % ============================================
        % ACCELERATION PLOT (commented)
        % ============================================

        figure('Name', sprintf('Sensor %s Trial %03d - Acc', sensorID, trialNum));

        subplot(2,1,1)
        plot(rawAcc, 'LineWidth', 1)
        title('Unfiltered Acceleration')
        xlabel('Samples')
        ylabel('Acceleration')
        legend('Acc X','Acc Y','Acc Z','Location','best')
        grid on

        subplot(2,1,2)
        plot(lpfAcc, 'LineWidth', 1)
        title('Low-pass Filtered Acceleration (12 Hz)')
        xlabel('Samples')
        ylabel('Acceleration')
        legend('Acc X','Acc Y','Acc Z','Location','best')
        grid on

        % ============================================
        % RESULTANT PLOT (commented)
        % ============================================
        %
        % figure('Name', sprintf('Sensor %s Trial %03d - Resultant', sensorID, trialNum));
        %
        % subplot(2,1,1)
        % plot(accRes, 'LineWidth', 1)
        % title('Acceleration Resultant')
        % xlabel('Samples')
        % ylabel('Resultant Acc')
        % grid on
        %
        % subplot(2,1,2)
        % plot(accResHP, 'LineWidth', 1)
        % title('High-pass Filtered Resultant (0.1 Hz)')
        % xlabel('Samples')
        % ylabel('Resultant Acc')
        % grid on

        % ============================================
        % GYROSCOPE PLOT (active)
        % ============================================
        % figure('Name', sprintf('Sensor %s Trial %03d - Gyroscope', sensorID, trialNum));
        % 
        % subplot(2,1,1)
        % plot(rawGyro, 'LineWidth', 1)
        % title('Unfiltered Gyroscope')
        % xlabel('Samples')
        % ylabel('Angular Velocity')
        % legend('Gyr X','Gyr Y','Gyr Z','Location','best')
        % grid on
        % 
        % subplot(2,1,2)
        % plot(lpfGyro, 'LineWidth', 1)
        % title('Low-pass Filtered Gyroscope (12 Hz)')
        % xlabel('Samples')
        % ylabel('Angular Velocity')
        % legend('Gyr X','Gyr Y','Gyr Z','Location','best')
        % grid on
% 
    end
end

% disp("Done plotting")
% 
std(rawAcc)
std(lpfAcc)

% function feat = extract6Features(sig, fs)
%     % Make sure it's a column vector
%     sig = sig(:);
% 
%     % Remove non-finite values just in case
%     sig(~isfinite(sig)) = 0;
% 
%     % 1) Standard deviation
%     feat.std = std(sig);
% 
%     % 2) RMS
%     feat.rms = rms(sig);
% 
%     % 3) Information entropy (histogram-based Shannon entropy)
%     nbins = 30;
%     p = histcounts(sig, nbins, 'Normalization', 'probability');
%     p = p(p > 0);
%     feat.entropy = -sum(p .* log2(p));
% 
%     % 4) Jerk metric
%     % derivative scaled by sampling frequency
%     jerkSig = diff(sig) * fs;
%     feat.jerk = rms(jerkSig);
% 
%     % 5) Peak number
%     minProm = 0.1 * std(sig);
%     if minProm <= 0
%         minProm = 1e-6;
%     end
%     [pks, ~] = findpeaks(abs(sig), 'MinPeakProminence', minProm);
%     feat.peakNum = numel(pks);
% 
%     % 6) Maximum peak amplitude
%     if isempty(pks)
%         feat.maxPeak = 0;
%     else
%         feat.maxPeak = max(pks);
%     end
% end