function resultado = procesoERA5(ERA5, t1, t2, opciones)
% procesoERA5: Versión corregida y mejorada (basada en OldOpt_v5)
%   - Manejo consistente de Crecimiento Higroscópico (RH).
%   - Opciones para controlar la restricción de derivada y refinamiento nocturno.
%   - Advertencias claras sobre limitaciones de Validación Cruzada.
%   - Nuevas opciones para límites de ajuste y manejo de RH.
%
% Argumentos:
%   ERA5: Estructura con datos, debe incluir 'times' y campos AOD (e.g., AOD340).
%         Puede incluir un campo para Humedad Relativa (ver opciones.rh_field_name).
%   t1, t2: datetime, inicio y fin del periodo a procesar.
%   opciones: struct, opciones de configuración.
%
% Opciones Nuevas/Modificadas:
%   rh_field_name (default 'RH'): Nombre del campo en ERA5 con Humedad Relativa (%).
%   default_rh (default 80): Valor de RH a usar si no se encuentra el campo o tiene NaNs.
%   w_deriv_refine (default 1.0): Peso para la restricción de derivada en el refinamiento final. Poner 0 para desactivarla.
%   refineNightData (default true): Si es true, el refinamiento final ajusta activamente los puntos nocturnos. Si false, los conserva del paso anterior.
%   coef_lb (default 0): Límite inferior para coeficientes en lsqcurvefit.
%   coef_ub (default 10.0): Límite superior para coeficientes en lsqcurvefit.
%   w_lb (default 0.2): Límite inferior para fracción marina 'w' si integratedMarine=true.
%   w_ub (default 0.8): Límite superior para fracción marina 'w' si integratedMarine=true.
%
% Autor: (Tu Nombre) - Corregido por Asistente AI

    %% 0) Handle input arguments and default options
    if nargin < 4, opciones = struct(); end
    % Opciones originales
    if ~isfield(opciones, 'activos'),           opciones.activos = true(1,4);        end
    if ~isfield(opciones, 'refinamientoFinal'), opciones.refinamientoFinal = true;   end
    if ~isfield(opciones, 'horarioValido'),     opciones.horarioValido = [6,20];     end % Horas LST consideradas "diurnas"
    if ~isfield(opciones, 'validacionCV'),      opciones.validacionCV = true;        end
    if ~isfield(opciones, 'forzarMarinos'),     opciones.forzarMarinos = true;       end
    if ~isfield(opciones, 'fraccionFinaIni'),   opciones.fraccionFinaIni = 0.4;      end
    if ~isfield(opciones, 'fraccionCoarseIni'), opciones.fraccionCoarseIni = 0.6;    end
    if ~isfield(opciones, 'pesoBandas'),        opciones.pesoBandas = [1,1,1,1,1,1,1];     end
    if ~isfield(opciones, 'useParfor'),         opciones.useParfor = false;          end
    if ~isfield(opciones, 'cv_k'),              opciones.cv_k = 5;                   end
    if ~isfield(opciones, 'integratedMarine'),  opciones.integratedMarine = true;    end
    % Nuevas opciones y valores por defecto
    if ~isfield(opciones, 'rh_field_name'),     opciones.rh_field_name = 'RH';       end
    if ~isfield(opciones, 'default_rh'),        opciones.default_rh = 60.0;          end
    if ~isfield(opciones, 'w_deriv_refine'),    opciones.w_deriv_refine = 0.1;       end
    if ~isfield(opciones, 'refineNightData'),   opciones.refineNightData = true;     end
    if ~isfield(opciones, 'coef_lb'),           opciones.coef_lb = 0.0;              end
    if ~isfield(opciones, 'coef_ub'),           opciones.coef_ub = 10.0;             end
    if ~isfield(opciones, 'w_lb'),              opciones.w_lb = 0.2;                 end
    if ~isfield(opciones, 'w_ub'),              opciones.w_ub = 0.8;                 end

    % Validaciones básicas de opciones
    if isrow(opciones.pesoBandas), opciones.pesoBandas = opciones.pesoBandas'; end
    if numel(opciones.pesoBandas) ~= 7
        warning('pesoBandas debe tener 7 elementos. Usando unos.');
        opciones.pesoBandas = ones(7,1);
    end
    if abs(opciones.fraccionFinaIni + opciones.fraccionCoarseIni - 1.0) > 1e-6 && ~opciones.integratedMarine
        warning('fraccionFinaIni y fraccionCoarseIni deberían sumar 1 cuando integratedMarine es false.');
    end
    if opciones.w_lb >= opciones.w_ub
       warning('w_lb debe ser menor que w_ub. Ajustando a valores por defecto [0.2, 0.8]');
       opciones.w_lb = 0.2; opciones.w_ub = 0.8;
    end
     if opciones.coef_lb >= opciones.coef_ub
       warning('coef_lb debe ser menor que coef_ub. Ajustando a valores por defecto [0, 10]');
       opciones.coef_lb = 0.0; opciones.coef_ub = 50.0;
    end

    disp('>> Configured options (Corrected Version):');
    disp(opciones);

    %% 1) Filter data by dates
    idx = (ERA5.times >= t1) & (ERA5.times <= t2); % Incluir bordes t1 y t2
    if ~any(idx)
        disp('>> [WARN] No data in the specified time range.');
        resultado = struct();
        return;
    end
    T = table(ERA5.times(idx), ERA5.AOD340(idx), ERA5.AOD380(idx), ERA5.AOD440(idx), ERA5.AOD500(idx), ERA5.AOD675(idx), ERA5.AOD870(idx), ERA5.AOD1020(idx), ...
        'VariableNames', {'time','AOD340','AOD380','AOD440','AOD500','AOD675','AOD870','AOD1020'});
    nRec = height(T);


     %% === NUEVA EXTRACCIÓN DE RH USANDO RH_dates (promedio hora‑antes / hora‑después) ===
    if isfield(ERA5, opciones.rh_field_name) && isfield(ERA5, 'RH_dates')
        rh_full  = ERA5.(opciones.rh_field_name);
        rh_times = ERA5.RH_dates;

        % ── Validar longitudes ────────────────────────────────────────────
        if numel(rh_full) ~= numel(rh_times)
            warning('RH (%d) y RH_dates (%d) tienen distinto largo. Usando default RH.', ...
                    numel(rh_full), numel(rh_times));
            rh_data = repmat(opciones.default_rh, nRec, 1);
        else
            % ── Filtrar lecturas exactamente en minuto=0, segundo=0 ─────────
            isHourly        = (minute(rh_times)==0) & (second(rh_times)==0);
            rh_times_hourly = rh_times(isHourly);
            rh_vals_hourly  = rh_full(isHourly);

            % Prealocar
            rh_data = nan(nRec,1);

            % ── Para cada AOD, promediar RH dentro de ±1 h ────────────────
            for ii = 1:nRec
                t = T.time(ii);
                sel = abs(rh_times_hourly - t) <= hours(1);
                if any(sel)
                    rh_data(ii) = mean(rh_vals_hourly(sel), 'omitnan');
                else
                    rh_data(ii) = opciones.default_rh;
                end
            end

            % ── Rellenar posibles NaN y asegurar rango [0 100] ────────────
            nan_idx = isnan(rh_data);
            if any(nan_idx)
                rh_data(nan_idx) = opciones.default_rh;
                fprintf('>> [WARN] %d RH promedios resultaron NaN; reemplazados por default=%.1f%%\n', ...
                        sum(nan_idx), opciones.default_rh);
            end
            rh_data = max(0, min(100, rh_data));

            fprintf('>> RH calculado como promedio ±1 h usando ERA5.RH_dates y campo ”%s”.\n', opciones.rh_field_name);
        end

    else
        fprintf('>> No existe ERA5.%s o ERA5.RH_dates. Usando RH fija = %.1f %%.\n', ...
                opciones.rh_field_name, opciones.default_rh);
        rh_data = repmat(opciones.default_rh, nRec, 1);
    end

    % Añadir RH al table T
    T.RH = rh_data;


    %% 2) Check for NaN/Inf in numeric AOD columns
    numData = T{:,2:8};
    nan_inf_rows = any(isnan(numData),2) | any(isinf(numData),2);
    if any(nan_inf_rows)
        disp(['>> [WARN] NaN/Inf found in ', num2str(sum(nan_inf_rows)), ' AOD rows. These rows will be skipped in adjustments.']);
        % Note: The loops later check for NaNs per row, so no need to remove rows here.
    end

%% 3) Define sources and setup marine optimization
fuentesAll = defineSources_OptAntiguo(); % Load base source definitions

% --- Define ALL possible fields from any source type ---
% (Based on defineSources_OptAntiguo output)
all_possible_fields = {'name', 'type', 'wavelengths', 'data', 'tau_levels', 'full_data'};

% --- Select active sources ensuring they are homogeneous ---
active_indices = find(opciones.activos);
fuentes = struct(); % Initialize as an empty struct array
if ~isempty(active_indices)
    % Ensure all selected sources have all possible fields
    for i = 1:length(active_indices)
        idx = active_indices(i);
        tempSource = fuentesAll(idx);
        for f = 1:length(all_possible_fields)
            field_name = all_possible_fields{f};
            if ~isfield(tempSource, field_name)
                % Add missing field with default empty value
                tempSource.(field_name) = [];
            end
        end
        if i == 1
            fuentes = tempSource; % Initialize array with the first correct struct
        else
            fuentes(i) = tempSource; % Add subsequent structs
        end
    end
else
    % If no sources are active, fuentes remains an empty struct array
    warning('No sources selected as active.');
    fuentes = struct(all_possible_fields{1}, {}, ... % Create empty struct with all fields
                     all_possible_fields{2}, {}, ...
                     all_possible_fields{3}, {}, ...
                     all_possible_fields{4}, {}, ...
                     all_possible_fields{5}, {}, ...
                     all_possible_fields{6}, {});
end


% Store original marine data (uncorrected) if needed for later use in iterData
marineFineData_orig = [];
marineCoarseData_orig = [];
% Find original marine indices *within the initially loaded fuentesAll*
% Find indices *within the currently active 'fuentes' array*
idx_fine_active = find(strcmp({fuentes.name}, 'Marino_Fine'));
idx_coarse_active = find(strcmp({fuentes.name}, 'Marino_Coarse'));

has_fine_active = ~isempty(idx_fine_active);
has_coarse_active = ~isempty(idx_coarse_active);

if has_fine_active
    marineFineData_orig = fuentes(idx_fine_active).data(:); % Extract original fine data from active source
end
if has_coarse_active
    marineCoarseData_orig = fuentes(idx_coarse_active).data(:); % Extract original coarse data from active source
end

% Handle marine source merging based on options
marineIdxInFinalFuentes = []; % Index of the combined 'Marino' source in the 'fuentes' list used for fitting
marineInfoForIterData = struct(); % Temporary struct to hold specific info for iterData

if opciones.forzarMarinos && has_fine_active && has_coarse_active
    % --- Combine Fine and Coarse into a single 'Marino' source entry ---

    % Create a new structure ensuring ALL fields exist
    newSource = struct();
    newSource.name = 'Marino';          % Set new name
    newSource.wavelengths = [0.34, 0.38, 0.44, 0.50, 0.675, 0.87, 1.02];
    newSource.data = [];                % Data is dynamic
    newSource.tau_levels = [];          % Not applicable, set to empty/NaN
    newSource.full_data = [];           % Not applicable, set to empty/NaN

    if opciones.integratedMarine
        disp('>> Setting up integrated marine optimization (w will be optimized).');
        newSource.type = 'combined_marine'; % Special type for integrated optimization
        % Store necessary original data and info in the temporary struct for iterData
        marineInfoForIterData.marineOriginalFine = marineFineData_orig;
        marineInfoForIterData.marineOriginalCoarse = marineCoarseData_orig;
    else
        disp('>> Combining marine sources with fixed fraction (w is fixed).');
        newSource.type = 'fixed_marine'; % Special type for fixed fraction combination
        % Store necessary original data and info in the temporary struct for iterData
        marineInfoForIterData.marineOriginalFine = marineFineData_orig;
        marineInfoForIterData.marineOriginalCoarse = marineCoarseData_orig;
        marineInfoForIterData.fixed_w = opciones.fraccionFinaIni; % Store the fixed fraction itself
    end

    % Remove original fine and coarse sources from the *active* 'fuentes' array
    indices_to_remove_active = [];
    if has_coarse_active, indices_to_remove_active = [indices_to_remove_active, idx_coarse_active]; end
    if has_fine_active,   indices_to_remove_active = [indices_to_remove_active, idx_fine_active]; end

    fuentes(unique(indices_to_remove_active)) = []; % Remove originals from active list

    % *** CORRECTION HERE ***
    % Add the NEW source structure (which now has all fields, matching others)
    if isempty(fuentes) % If removing marines left fuentes empty
         fuentes = newSource;
    else
         fuentes(end+1) = newSource; % Add to the end
    end
    marineIdxInFinalFuentes = length(fuentes); % Its index is the new last element
    disp('>> Marino_Fine and Marino_Coarse replaced by combined Marino source.');

else
    % --- Keep Fine and Coarse Separate (or handle if only one exists/is active) ---
    if opciones.forzarMarinos && (~has_fine_active || ~has_coarse_active)
        warning('Could not force/combine marine sources. Original Marino_Fine and/or Marino_Coarse not found or not both active.');
    end
    % Original types 'fija_marine' should have been set during initial homogenization if needed
    % Ensure they still have the correct type after selection.
    if has_fine_active
        idx_f = find(strcmp({fuentes.name}, 'Marino_Fine'));
        if ~isempty(idx_f), fuentes(idx_f).type = 'fija_marine'; end
    end
     if has_coarse_active
        idx_c = find(strcmp({fuentes.name}, 'Marino_Coarse'));
        if ~isempty(idx_c), fuentes(idx_c).type = 'fija_marine'; end
     end
     % marineIdxInFinalFuentes remains empty as there's no single combined index
end

nFuentes = length(fuentes);
if nFuentes == 0
    warning('No active sources remaining after processing marine options. Check configuration.');
    resultado = struct('error', 'No active sources.'); return;
end
disp('>> Active sources for fitting:'); disp({fuentes.name}');


% Prepare iterData structure
iterData = struct();
iterData.wl = [0.34;0.38;0.44;0.50;0.675;0.87;1.02]; % Wavelengths
iterData.cols_idx = 2:8; % Indices of AOD columns in table T
iterData.nFuentes = nFuentes;
iterData.fuentes = fuentes; % Pass the final list of *homogeneous* source structures
iterData.integratedMarine = opciones.integratedMarine; % Pass this flag too

% *** Add specific marine info to iterData ***
iterData.marineIndex = marineIdxInFinalFuentes; % Index of the combined source, or empty
if ~isempty(marineIdxInFinalFuentes)
    % These fields will ONLY exist in iterData if a combined source was created
    iterData.marineOriginalFine = marineInfoForIterData.marineOriginalFine;
    iterData.marineOriginalCoarse = marineInfoForIterData.marineOriginalCoarse;
    if isfield(marineInfoForIterData, 'fixed_w')
        iterData.marineFixedW = marineInfoForIterData.fixed_w;
    else
        iterData.marineFixedW = NaN; % Not applicable for integratedMarine mode
    end
else
    % Ensure fields exist but are empty/NaN if no combined source, avoids errors later
    iterData.marineOriginalFine = [];
    iterData.marineOriginalCoarse = [];
    iterData.marineFixedW = NaN;
end

% Define indices for different source types within the *final* 'fuentes' list
% These find the indices based on the 'type' field in the final 'fuentes' array
iterData.idxFija = find(strcmp({fuentes.type}, 'fija'));            % Standard fixed sources
iterData.idxTau = find(strcmp({fuentes.type}, 'tau'));             % Tau-dependent sources
iterData.idxFixedMarine = find(strcmp({fuentes.type}, 'fixed_marine')); % Index for the combined marine source with fixed w
iterData.idxCombinedMarine = find(strcmp({fuentes.type}, 'combined_marine')); % Index for the combined marine source with variable w
iterData.idxFijaMarine = find(strcmp({fuentes.type}, 'fija_marine')); % Indices for original marine sources if kept separate

% Store data needed for interpolation (only for 'tau' type sources)
iterData.tauLevels = {};
iterData.fullData = {};
iterData.fullData500 = {};
if ~isempty(iterData.idxTau)
    % Pre-allocate cell arrays matching the number of tau sources found
    numTauSources = length(iterData.idxTau);
    iterData.tauLevels = cell(1, numTauSources);
    iterData.fullData = cell(1, numTauSources);
    iterData.fullData500 = cell(1, numTauSources);

    for k = 1:numTauSources
        tau_idx_in_fuentes = iterData.idxTau(k); % Get the actual index in the 'fuentes' array
        % Safely access fields, checking they are not empty
        if isfield(fuentes(tau_idx_in_fuentes), 'tau_levels') && ~isempty(fuentes(tau_idx_in_fuentes).tau_levels)
             iterData.tauLevels{k} = fuentes(tau_idx_in_fuentes).tau_levels;
        else
             iterData.tauLevels{k} = []; % Assign empty if missing/empty
             warning('Tau source "%s" is missing tau_levels.', fuentes(tau_idx_in_fuentes).name);
        end

        if isfield(fuentes(tau_idx_in_fuentes), 'full_data') && ~isempty(fuentes(tau_idx_in_fuentes).full_data)
            iterData.fullData{k} = fuentes(tau_idx_in_fuentes).full_data;
            % Ensure full_data has enough columns before accessing column 4
            if size(fuentes(tau_idx_in_fuentes).full_data, 2) >= 4
                 iterData.fullData500{k} = fuentes(tau_idx_in_fuentes).full_data(:, 4); % Extract 500nm column
            else
                 warning('Full_data for source "%s" has fewer than 4 columns.', fuentes(tau_idx_in_fuentes).name);
                 iterData.fullData500{k} = nan(size(fuentes(tau_idx_in_fuentes).full_data, 1), 1); % Assign NaN
            end
        else
             iterData.fullData{k} = []; % Assign empty if missing/empty
             iterData.fullData500{k} = [];
              warning('Tau source "%s" is missing full_data.', fuentes(tau_idx_in_fuentes).name);
        end
    end
end    

%% 4) Initial iterative adjustment (only daytime records)
    coef_fit = nan(nRec, nFuentes);
    tau_inputs = nan(nRec, 1); % AOD500 value used as input for tau-dependent sources
    w_optimizado = nan(nRec, 1); % Vector for optimized w (only relevant if integratedMarine=true)
    if ~opciones.integratedMarine % If not optimizing w, set it based on fixed fraction
        w_optimizado(:) = opciones.fraccionFinaIni;
    end

    % Select adjustment function (Wrappers currently point to the same function)
    ajusteFunc = @ajusteAngstromMie_iter_OptAntiguo_v3_corrected;

    disp(['>> Starting initial adjustment (' func2str(ajusteFunc) ' - daytime only)...']);
    tic;
    h = hour(T.time);
    % Indices for daytime (within valid hours) and nighttime
    idx_daytime = find(h >= opciones.horarioValido(1) & h < opciones.horarioValido(2));
    idx_night = find(h < opciones.horarioValido(1) | h >= opciones.horarioValido(2));
    nRec_day = length(idx_daytime);

    if nRec_day == 0
        warning('No daytime records found in the specified interval and horarioValido. Skipping initial adjustment.');
    else
        if opciones.useParfor
            disp('>> Using parfor for daytime adjustment loop.');
            pool = gcp('nocreate'); if isempty(pool), parpool; end

            % Pre-extract data for parfor
            T_day_par = T(idx_daytime, [1, iterData.cols_idx, width(T)]); % Include time, AODs, RH
            opciones_par = opciones; % Broadcast options
            iterData_par = iterData; % Broadcast iterData

            % Initialize results arrays for daytime records
            coef_fit_day = nan(nRec_day, nFuentes);
            tau_inputs_day = nan(nRec_day, 1);
            w_day = nan(nRec_day, 1);
             if ~opciones_par.integratedMarine
                 w_day(:) = opciones_par.fraccionFinaIni;
             end

            parfor k = 1:nRec_day
                meas_k = T_day_par{k, 2:(end-1)}'; % AOD data for record k
                rh_k = T_day_par{k, end};         % RH for record k
                time_k = T_day_par.time(k); % Time for potential debugging/logging inside loop

                if any(isnan(meas_k)) || any(isinf(meas_k)) || isnan(rh_k)
                    % Log skipped record if needed: fprintf('Skipping daytime record k=%d (time %s) due to NaN/Inf\n', k, datestr(time_k));
                    continue; % Skip if data is bad
                end

                try
                    [coef_k_res, tau_k_res, w_k_res] = ajusteFunc(meas_k, rh_k, iterData_par, opciones_par);
                    coef_fit_day(k, :) = coef_k_res;
                    tau_inputs_day(k) = tau_k_res;
                    if iterData_par.integratedMarine % Only store w if it was actually optimized
                        w_day(k) = w_k_res;
                    end
                catch ME_parfor
                     fprintf('Error during parfor adjustment for daytime record k=%d (time %s): %s\n', k, datestr(time_k), ME_parfor.message);
                     % Leave results as NaN for this record
                end
            end

            % Assign results back to the main arrays
            coef_fit(idx_daytime, :) = coef_fit_day;
            tau_inputs(idx_daytime) = tau_inputs_day;
            w_optimizado(idx_daytime) = w_day; % Contains optimized w or fixed fraction

        else % Sequential loop (easier debugging)
             pb = CmdLineProgressBar('>> Processing daytime records... ');
             for k = 1:nRec_day
                i = idx_daytime(k); % Index in the original table T
                meas_i = T{i, iterData.cols_idx}'; % AOD data
                rh_i = T.RH(i);                   % RH data

                if any(isnan(meas_i)) || any(isinf(meas_i)) || isnan(rh_i)
                   continue; % Skip bad data
                end

                try
                    [coef_fit(i, :), tau_inputs(i), w_optimizado(i)] = ajusteFunc(meas_i, rh_i, iterData, opciones);
                     % Note: ajusteFunc returns the fixed w if integratedMarine is false
                catch ME_seq
                     fprintf('\nError during sequential adjustment for record i=%d (time %s): %s\n', i, datestr(T.time(i)), ME_seq.message);
                     % Leave results as NaN
                end
                 pb.print(k, nRec_day);
             end
        end
    end
    toc;
    disp(['>> Initial adjustment completed for ' num2str(sum(~isnan(tau_inputs(idx_daytime)))) ' valid daytime records.']);

%% 5) NIGHT adjustment: day‑trend + species forcing
disp('>> Setting night coefficients/tau/w based on preceding daytime average + species forcing...');
tic;

% índices de especies
smoke_idx = find(strcmp({iterData.fuentes.name},'Strongly_Absorbing'));
urban_idx = find(strcmp({iterData.fuentes.name},'Weakly_Absorbing'));

% umbrales
thr_zero   = 1e-3;   % |coef| < thr_zero  ⇒ ≈ 0
thr_smoke  = 1e-2;   % si smoke sube por encima de esto, forzamos
thr_change = 0.10;   % 30 % de cambio relativo para forzar Urban

if ~isempty(idx_night)
    [~,ord]   = sort(T.time(idx_night));      % orden cronológico
    night_ix  = idx_night(ord);

    for k = 1:numel(night_ix)
        i = night_ix(k);

        % saltar registros con medición mala
        if any(isnan(T{i,iterData.cols_idx})) || any(isinf(T{i,iterData.cols_idx}))
            coef_fit(i,:)   = NaN; tau_inputs(i) = NaN; w_optimizado(i) = NaN;
            continue
        end

        % ---------- promedio diurno del mismo día ----------
        d0        = dateshift(T.time(i),'start','day');
        prev_day  = idx_daytime(T.time(idx_daytime)<T.time(i) & ...
                                dateshift(T.time(idx_daytime),'start','day')==d0);
        prev_day  = prev_day(~isnan(tau_inputs(prev_day)));       % válidos

        if ~isempty(prev_day)
            coef_med = mean(coef_fit(prev_day,:),1,'omitnan');
            tau_med  = mean(tau_inputs(prev_day)   ,'omitnan');
            w_med    = mean(w_optimizado(prev_day) ,'omitnan');
        else                                         % sin datos diurnos ese día
            coef_med = repmat(1e-5,1,nFuentes);
            tau_med  = 1e-4;
            w_med    = opciones.integratedMarine*NaN + ~opciones.integratedMarine*opciones.fraccionFinaIni;
        end

        coef_fit(i,:)   = coef_med;
        tau_inputs(i)   = tau_med;
        w_optimizado(i) = w_med;

        % ---------- forzado species ----------
        prev_i = find(~isnan(tau_inputs(1:i-1)),1,'last');   % último válido
        if isempty(prev_i),  continue, end

        % (a) Smoke: evita paso 0→alto
        if coef_fit(prev_i,smoke_idx)<thr_zero && coef_fit(i,smoke_idx)>thr_smoke
            coef_fit(i,smoke_idx) = coef_fit(prev_i,smoke_idx);
        end

        % (b) Urban: evita caída brusca (> thr_change)
        urb_prev = coef_fit(prev_i,urban_idx);
        urb_now  = coef_fit(i,urban_idx);

        if urb_prev>thr_zero   % hay urbano antes
            if urb_now<thr_zero || abs(urb_now-urb_prev)/urb_prev > thr_change
                coef_fit(i,urban_idx) = urb_prev;          % copiar valor previo
            end
        end

        % ---------- actualizar tau500 ----------
        [~,b500]    = buildBasis_OptAntiguo_v3_corrected(tau_inputs(i),T.RH(i),iterData);
        tau_inputs(i) = sum(b500 .* coef_fit(i,:));
    end
end

toc;
disp('>> Night values assigned.');

% guardar base antes del refinamiento
coef_fit_base     = coef_fit;
tau_inputs_base   = tau_inputs;
w_optimizado_base = w_optimizado;

%% 5.1) Final Refinement (Optional)
if opciones.refinamientoFinal
    disp('>> Starting final refinement step (adjusting all points)...');
    tic;
    try
        [coef_fit, tau_inputs, w_optimizado] = ...
            ajusteAngstromMie_iterConFijos_OptAntiguo_v3_corrected( ...
                T, coef_fit_base, tau_inputs_base, w_optimizado_base, iterData, opciones );
        toc;
        disp('>> Final refinement completed.');
    catch ME_refine
        toc;
        warning('ProcesoERA5:FinalRefine', ...
                'Error during final refinement step: %s. Using results before refinement.', ...
                ME_refine.message);
        % revertir a pre-refinamiento
        coef_fit     = coef_fit_base;
        tau_inputs   = tau_inputs_base;
        w_optimizado = w_optimizado_base;
    end
else
    disp('>> Final refinement step deactivated.');
end

 
    
    
    %% 6) Recalculate final contributions and modeled AOD using final parameters
    disp('>> Recalculating final AOD contributions...');
    AOD500_sources = recalcularAOD500_OptAntiguo_v3_corrected(nRec, T.RH, iterData, coef_fit, tau_inputs, w_optimizado);
    AOD500_model = sum(AOD500_sources, 2, 'omitnan');
    AOD500_meas = T.AOD500;

    % Recalculate AOD for all bands using final parameters


   %% 6.1) Compute Error Matrix
disp('>> Calculating error matrix...');
AOD_model_all = calcularAODporBanda_OptAntiguo_v3_corrected(nRec, T.RH, iterData, coef_fit, tau_inputs, w_optimizado); % Ensure recalculated with current params
AOD_meas_all = T{:, iterData.cols_idx}; % Measured AOD all bands

errorMatrix = nan(size(AOD_meas_all)); % Initialize with NaN

valid_meas_idx = AOD_meas_all > 1e-9; % Where measurement is significant
valid_model_idx = ~isnan(AOD_model_all); % Where model calculation was successful

% Indices for calculation: where both measurement and model are valid
calc_idx = valid_model_idx & valid_meas_idx; % Element-wise AND, both matrices
% Calculate relative error where measurement is significant and model is valid
errorMatrix(calc_idx) = abs(AOD_meas_all(calc_idx) - AOD_model_all(calc_idx)) ./ AOD_meas_all(calc_idx) * 100;

% Handle cases where measurement is near zero, but model is valid
zero_meas_idx = valid_model_idx & ~valid_meas_idx; % Element-wise AND
% Find where model is also near zero within this subset
model_near_zero_idx = abs(AOD_model_all) < 1e-9; % Matrix matching AOD_model_all size

% Assign 0 error where both measurement and model are near zero
errorMatrix(zero_meas_idx & model_near_zero_idx) = 0; % All matrices, element-wise AND

% Assign Inf error where measurement is near zero but model is not
errorMatrix(zero_meas_idx & ~model_near_zero_idx) = Inf; % All matrices, element-wise AND

% Where model calculation failed (NaN), errorMatrix remains NaN (from initialization).
disp('>> Error matrix calculated.');

    %% 7) Post-processing (Thresholding small values)
    disp('>> Applying post-processing threshold...');
    threshold_zero = 1e-4; % Slightly larger threshold? Or make it an option?

    % Apply threshold to coefficients first
    coef_fit_final = coef_fit;
    coef_fit_final(abs(coef_fit_final) < threshold_zero) = 0;

    % Recalculate based on thresholded coefficients
    AOD500_sources_final = recalcularAOD500_OptAntiguo_v3_corrected(nRec, T.RH, iterData, coef_fit_final, tau_inputs, w_optimizado);
    AOD500_model_final = sum(AOD500_sources_final, 2, 'omitnan');

    % Apply threshold to final results for clarity
    AOD500_sources_final(abs(AOD500_sources_final) < threshold_zero) = 0;
    AOD500_model_final(abs(AOD500_model_final) < threshold_zero) = 0;
    % Also threshold tau_inputs? Optional.
    tau_inputs_final = tau_inputs;
    tau_inputs_final(abs(tau_inputs_final)< threshold_zero) = 0;


    %% 8) Assemble output structure
    disp('>> Assembling output structure...');
    resultado = struct();
    resultado.time = T.time;
    resultado.AOD500_meas = AOD500_meas;
    resultado.AOD500_model = AOD500_model_final; % Final thresholded model
    resultado.coef_fit = coef_fit_final; % Final thresholded coefficients
    resultado.tau_inputs = tau_inputs_final; % Final thresholded tau inputs
    resultado.w_optimizado = w_optimizado; % Optimized or fixed w (not thresholded)
    resultado.RH_used = T.RH; % RH values used for each time step

    % Include non-thresholded results for comparison if needed
    resultado.AOD500_model_raw = AOD500_model;
    resultado.coef_fit_raw = coef_fit;
    resultado.tau_inputs_raw = tau_inputs;

    resultado.sources = struct();
    fuenteNombresFinal = {iterData.fuentes.name};
    for j = 1:nFuentes
        safeName = matlab.lang.makeValidName(fuenteNombresFinal{j});
        resultado.sources.(safeName) = AOD500_sources_final(:, j);
    end

    % Calculate percentage contribution table
    disp('>> Calculating percentage contribution table...');
    resultado.tablaBandas = computeBandPercTable_OptAntiguo_v3_corrected(...
    T, T.RH, iterData, coef_fit_final, tau_inputs_final, w_optimizado);

    % Error table
    varNamesError = {'time','error340','error380','error440','error500','error675','error870','error1020'};
    tablaError = [table(T.time, 'VariableNames', {'time'}), array2table(errorMatrix, 'VariableNames', varNamesError(2:end))];
    resultado.errorPorBanda = tablaError;

    resultado.opciones = opciones; % Store options used
    resultado.fuentes_usadas = iterData.fuentes; % Store final source structures used
    resultado.iterData = iterData; % Store iterData for debugging/info

   
   
   %% 
   %% 9) Cálculo de H espectral (Altura de la capa de aerosoles en km)
disp('>> Calculando H espectral...');

% Nombres de las fuentes utilizadas en el ajuste final
fuenteNombresFinal = {resultado.fuentes_usadas.name};

% Inicializar la suma de coeficientes en cero para cada registro
suma_coeficientes = zeros(height(resultado.time), 1);

% Sumar todos los coeficientes de las fuentes para cada registro de tiempo.
% El ajuste ya proporciona un coeficiente por cada fuente principal (e.g., Marino,
% Strongly_Absorbing, Weakly_Absorbing), por lo que simplemente los sumamos.
% La variable `resultado.coef_fit` tiene dimensiones [nRec x nFuentes]
if ~isempty(resultado.coef_fit)
    suma_coeficientes = sum(resultado.coef_fit, 2, 'omitnan');
else
    warning('No se encontraron coeficientes (resultado.coef_fit) para calcular H espectral.');
end

% Calcular H espectral en kilómetros
H_espectral_km = suma_coeficientes * 1000;

% Añadir el resultado a la estructura de salida
resultado.H_espectral_km = H_espectral_km;

disp('>> H espectral calculado y añadido a la estructura de resultados.');
   %% 9) Cross-validation (optional) - WITH CLEAR WARNINGS
    if opciones.validacionCV
        disp('>> Starting cross-validation...');
        disp('>> ======================= CROSS-VALIDATION WARNING =======================');
        disp('>> The following CV metrics evaluate ONLY the INITIAL DAYTIME ADJUSTMENT step.');
        disp('>> They DO NOT reflect the impact of NIGHTTIME data handling or FINAL REFINEMENT.');
        disp('>> Use these metrics with caution, primarily for comparing relative performance');
        disp('>> of the initial fitting stage under different options/source sets.');
        disp('>> ==========================================================================');
        tic;
        try
            cvMetrics = validacionCruzadaAOD_OptAntiguo_v3_corrected(T, iterData, opciones);
            toc;
            disp('>> Cross-validation results (Initial Daytime Fit Only):');
            disp(cvMetrics);
            resultado.validacionCV = cvMetrics;
        catch ME_cv
            toc;
            resultado.validacionCV = struct('error', ME_cv.message);
        end
         disp('>> REMINDER: CV metrics above DO NOT include night treatment or final refinement.');
    end
%   %% 10) Plot results
% disp('>> Generating plots...');
% 
% % Plot FINAL results (Thresholded)
 figure; 
 ax2 = gca; 
 hold(ax2, 'on');
 set(ax2, 'FontSize', 30);
% 
% Measured AOD500 (only non-NaN points will appear)
 hMeas2 = plot(ax2, resultado.time, AOD500_meas, 'k.', ...
    'LineWidth', 1.5, 'MarkerSize', 10);
 legendEntries2 = {'Measured AOD500'};
grid on

 % 
% cols    = lines(nFuentes);
% markers = {'o','s','d','^','v','<','>','+','*'};
% markers = repmat(markers, 1, ceil(nFuentes/length(markers)));
% hF2     = gobjects(nFuentes, 1);
% legendEntries2 = {'Measured AOD500'};
% 
% % Contributions by source
% for j = 1:nFuentes
%     safeName = matlab.lang.makeValidName(fuenteNombresFinal{j});
%     if isfield(resultado.sources, safeName)
%         plotData = resultado.sources.(safeName);
%         if any(plotData > threshold_zero)
%             mk = markers{j};
%             hF2(j) = plot(ax2, resultado.time, plotData, ['-' mk], ...
%                 'Color', cols(j,:), 'LineWidth', 1.0, 'MarkerSize', 6);
%             legendEntries2{end+1} = strrep(safeName, '_', ' ');
%         else
%             hF2(j) = gobjects(1);
%         end
%     end
% end
% 

 %Final modeled sum, plotted only where measured data exists
 modelPlot_final = AOD500_model_final;
 validMeas = ~isnan(AOD500_meas);
 
 
if any(validMeas)
     hModel2 = plot(ax2, resultado.time(validMeas), modelPlot_final(validMeas), ...
         'ro', 'LineWidth', 2);
legendEntries2{end+1} = 'Final Modeled Sum';
 else
     hModel2 = gobjects(1);
end

legend(ax2, legendEntries2, ...
           'Location', 'best', 'Interpreter', 'none', 'FontSize', 20);

xlabel(ax2, 'Time');
ylabel(ax2, 'AOD at 500 nm');

% 
% 
% % Build legend
% validHandles2 = [hMeas2; hF2(isgraphics(hF2)); hModel2(isgraphics(hModel2))];
% if ~isempty(validHandles2)
%     legend(ax2, validHandles2, legendEntries2, ...
%            'Location', 'best', 'Interpreter', 'none', 'FontSize', 10);
% end
% 
% xlabel(ax2, 'Time');
% ylabel(ax2, 'AOD at 500 nm');
% title(ax2, 'AOD 500 nm: Measured vs Final Modeled (Corrected)');
% grid(ax2, 'on');
% dynamicDateTicks(ax2, 'linked');
% ylim(ax2, 'auto');
% 
% % Optional: Plot Base results (before refinement/thresholding) for comparison
% plot_base = false;  % Set to true to generate the base plot
% if plot_base && opciones.refinamientoFinal
%     disp('>> Generating plot for Base results (before refinement)...');
% 
%     figure; 
%     ax1 = gca; 
%     hold(ax1, 'on');
%     set(ax1, 'FontSize', 12);
% 
%     % Measured
%     plot(ax1, resultado.time, AOD500_meas, 'k.-', 'LineWidth', 1.5, 'MarkerSize', 10);
% 
%     % Base sources
%     AOD500_sources_base_recalc = recalcularAOD500_OptAntiguo_v3_corrected( ...
%         nRec, T.RH, iterData, coef_fit_base, tau_inputs_base, w_optimizado_base );
%     basePlot = sum(AOD500_sources_base_recalc, 2, 'omitnan');
% 
%     legendEntries1 = {'Measured AOD500'};
%     hF1 = gobjects(nFuentes, 1);
%     for j = 1:nFuentes
%         safeName = matlab.lang.makeValidName(fuenteNombresFinal{j});
%         plotDataBase = AOD500_sources_base_recalc(:, j);
%         if any(plotDataBase > threshold_zero)
%             mk = markers{j};
%             hF1(j) = plot(ax1, resultado.time, plotDataBase, ['-' mk], ...
%                 'Color', cols(j,:), 'LineWidth', 1.0, 'MarkerSize', 6);
% 
%            legendEntries1{end+1} = strrep(safeName, '_', ' ');
%         else
%             hF1(j) = gobjects(1);
%         end
%     end
% 
%     % Base modeled sum, only where measured exists
%     if any(validMeas)
%         hModel1 = plot(ax1, resultado.time(validMeas), basePlot(validMeas), ...
%             'r--', 'LineWidth', 2);
%         legendEntries1{end+1} = 'Base Modeled Sum';
%     else
%         hModel1 = gobjects(1);
%     end
% 
%     validHandles1 = [hF1(isgraphics(hF1)); hModel1(isgraphics(hModel1))];
%     if ~isempty(validHandles1)
%         legend(ax1, ['Measured AOD500'; legendEntries1(2:end)] , ...
%                'Location', 'best', 'Interpreter', 'none', 'FontSize', 10);
%     end
% 
%     xlabel(ax1, 'Time');
%     ylabel(ax1, 'AOD at 500 nm');
%     title(ax1, 'AOD 500 nm: Measured vs Base Modeled (Before Refinement)');
%     grid(ax1, 'on');
%     dynamicDateTicks(ax1, 'linked');
%     linkaxes([ax1, ax2], 'x');
%     legend('Measured AOD500','Marino','Strong Absorber','Weak Absorber')
% end
% 
% 
% disp('>> Processing finished.');
% --- GRÁFICA 1: Todos los resultados del modelo (contribuciones por fuente) ---

disp('>> Generando gráfica de contribuciones del modelo (solo puntos)...');
figure;
ax1 = gca;
hold(ax1, 'on');
set(ax1, 'FontSize', 12);

% --- Configuración de estilo ---
cols = lines(nFuentes);
markers = {'o','s','d','^','v','<','>','+','*'};
markers = repmat(markers, 1, ceil(nFuentes/length(markers)));

h_model_sources = gobjects(nFuentes, 1);
legend_model_sources = {};

% --- Graficar contribuciones por cada fuente (solo marcadores) ---
for j = 1:nFuentes
    safeName = matlab.lang.makeValidName(fuenteNombresFinal{j});
    if isfield(resultado.sources, safeName)
        plotData = resultado.sources.(safeName);
        if any(plotData > threshold_zero)
            mk = markers{j};
            h_model_sources(j) = plot(ax1, resultado.time, plotData, mk, ...
                'Color', cols(j,:), 'MarkerSize', 6,'LineWidth', 2);
            legend_model_sources{end+1} = strrep(safeName, '_', ' ');
        end
    end
end

% --- Añadir elementos de la gráfica ---
valid_handles_model = h_model_sources(isgraphics(h_model_sources));
if ~isempty(valid_handles_model)
    legend(ax1, valid_handles_model, legend_model_sources, ...
           'Location', 'best', 'Interpreter', 'none', 'FontSize', 20);
end

xlabel(ax1, 'Time');
ylabel(ax1, 'AOD @ 500 nm');
title(ax1, 'Model AOD Contributions by Source');
grid(ax1, 'on');
%dynamicDateTicks(ax1, 'linked');
set(ax1, 'FontSize', 30);
ylim(ax1, 'auto');
hold(ax1, 'off');
end
%% ==================== ADJUSTMENT FUNCTIONS ====================

function [coef_fit_i, tau_input_i, w_opt_i] = ajusteAngstromMie_iter_OptAntiguo_v3_corrected(meas_i, rh_i, iterData, opciones)
    % Performs iterative adjustment for a single time record (initial fit).
    % Includes consistent RH handling via buildBasis.
    % CORRECTED v3: Ensures marine data is accessed from iterData fields.

    wl = iterData.wl;
    nFuentes = iterData.nFuentes;
    tol = 1e-3;      % Convergence tolerance for tau_current
    max_iter = 20;   % Max iterations for tau convergence
    w_deriv = 0.0;   % Weight for derivative term (usually 0 for initial fit)
    peso = opciones.pesoBandas; % Weighting for AOD bands

    opts_lsq = optimoptions('lsqcurvefit','Display','off','Algorithm','trust-region-reflective','TolFun',1e-7,'TolX',1e-7);

    % Determine parameter vector size and bounds based on marine option
    is_integrated_case = iterData.integratedMarine && ~isempty(iterData.marineIndex);
    if is_integrated_case
        nParams = nFuentes + 1; % Coefficients + w
        x0 = [ones(nFuentes,1)*0.1; 0.5]; % Initial guess
        lb = [repmat(opciones.coef_lb, nFuentes, 1); opciones.w_lb];
        ub = [repmat(opciones.coef_ub, nFuentes, 1); opciones.w_ub];
    else
        nParams = nFuentes; % Only coefficients
        x0 = ones(nFuentes,1)*0.1;
        lb = repmat(opciones.coef_lb, nFuentes, 1);
        ub = repmat(opciones.coef_ub, nFuentes, 1);
    end

    % Initialize outputs

    w_opt_i = NaN; % Will hold optimized w or fixed w

    % Assign fixed w if not integrated mode but combined source exists
    if ~is_integrated_case
        % Check if the combined source with fixed w exists
        if isfield(iterData, 'idxFixedMarine') && ~isempty(iterData.idxFixedMarine) && isfield(iterData, 'marineFixedW')
             w_opt_i = iterData.marineFixedW; % Get fixed w from iterData
        elseif isfield(iterData, 'idxFijaMarine') && ~isempty(iterData.idxFijaMarine) % Separate fine/coarse sources
             w_opt_i = NaN; % w is not applicable/defined
        end
        % If idxFixedMarine existed but marineFixedW wasn't populated (shouldn't happen), w_opt_i remains NaN
    end


    % --- Initial Tau Estimation ---
    tau_current = 0.1; % Default guess
    try
        meas_pos = max(1e-9, meas_i);
        if ~any(isnan(meas_pos))
             if ~isnan(meas_pos(4)) && meas_pos(4) > 1e-9
                 tau_current = meas_pos(4); % Use 500nm measurement if valid
             else
                 % Ensure enough valid points for polyfit
                 valid_poly_idx = ~isnan(meas_pos) & meas_pos > 0;
                 if sum(valid_poly_idx) >= 2
                     p_meas = polyfit(log(wl(valid_poly_idx)), log(meas_pos(valid_poly_idx)), min(4, sum(valid_poly_idx)-1) ); % Use lower degree if few points
                     tau_val_500nm_log = polyval(p_meas, log(0.50));
                     tau_current = exp(tau_val_500nm_log);
                 else
                      tau_current = 0.1; % Fallback if not enough points
                 end
             end
        end
    catch ME_polyfit
        if ~isnan(meas_i(4)) && meas_i(4) > 1e-9 % Prefer 500nm measurement on error
            tau_current = meas_i(4);
        else
            tau_current = 0.1; % Keep default if 500nm also bad
        end
    end
    tau_current = max(1e-4, min(tau_current, 2.0)); % Bound initial tau guess
    % tau_input_i = tau_current; % Store initial guess - NO, store final result later

    % --- Derivative of Measurement (for model function) ---
    deriv_meas = zeros(size(wl)); % Default to zero derivative
    if w_deriv > 1e-6 % Only calculate if derivative term is weighted
        try
            meas_pos = max(1e-9, meas_i);
             valid_poly_idx = ~isnan(meas_pos) & meas_pos > 0;
             if sum(valid_poly_idx) >= 2
                 p_meas_deriv = polyfit(log(wl(valid_poly_idx)), log(meas_pos(valid_poly_idx)), min(4, sum(valid_poly_idx)-1));
                 deriv_meas = polyval(polyder(p_meas_deriv), log(wl));
             end
        catch ME_derivfit
             deriv_meas = zeros(size(wl));
        end
    end
    target = [peso .* meas_i; w_deriv * deriv_meas]; % Target vector for lsqcurvefit

    % --- Solve Tau via root-finding ---
    x_fit = NaN(nParams, 1);            % Will hold fit parameters
    tau_lb = 1e-4; tau_ub = 5.0;        % Bounds for tau
    opts_tau = optimoptions('lsqnonlin','Display','off','TolX',1e-4,'TolFun',1e-4,'MaxIter',max_iter);
    tau_diff = @(tau) diffTau(tau);     % Difference function

    [tau_iter, ~, residual, exitflag_tau] = lsqnonlin(tau_diff, tau_current, tau_lb, tau_ub, opts_tau);

    if exitflag_tau <= 0 || isnan(tau_iter) || any(isnan(residual))
        tau_iter = NaN;
        x_fit = NaN(nParams, 1);
    else
        tau_diff(tau_iter); % Ensure x_fit corresponds to final tau
    end

    % --- Assign Final Results for this time step ---
    tau_input_i = tau_iter; % Assign the final tau_iter (could be NaN if failed)

    if ~isnan(tau_input_i) && ~any(isnan(x_fit)) % Check if fit was successful
        if is_integrated_case
            coef_fit_i = x_fit(1:end-1)';
            w_opt_i = x_fit(end); % The optimized w
        else
            coef_fit_i = x_fit';
            % w_opt_i was assigned fixed value or NaN at the beginning
        end
    else
        % If fit failed, ensure all outputs are NaN
        coef_fit_i = NaN(1, nFuentes);
        tau_input_i = NaN;
        w_opt_i = NaN;
    end
    function diff = diffTau(tau)
        % Build basis for current tau
        try
            [basis, basis500_vals] = buildBasis_OptAntiguo_v3_corrected(tau, rh_i, iterData);
            if any(isnan(basis),'all') || any(isinf(basis),'all') || any(isnan(basis500_vals),'all') || any(isinf(basis500_vals),'all')
                diff = NaN; return;
            end
        catch ME_basis
            warning('Error building basis for tau=%.4f, rh=%.1f: %s. Aborting fit.', tau, rh_i, ME_basis.message);
            diff = NaN; return;
        end

        modelFun = @(x, ~) modeloConAngstrom_OptAntiguo_corrected(x, basis, wl, rh_i, w_deriv, peso, iterData);
        try
            [x_temp, ~, ~, exitflag, ~] = lsqcurvefit(modelFun, x0, [], target, lb, ub, opts_lsq);
            if exitflag <= 0 || any(isnan(x_temp))
                diff = NaN; return;
            end
        catch ME_lsq
            warning('Error during lsqcurvefit for tau=%.4f: %s. Aborting fit.', tau, ME_lsq.message);
            diff = NaN; return;
        end

        if is_integrated_case
            current_w = x_temp(end);
            x_use = x_temp(1:end-1);
            if ~isfield(iterData,'marineOriginalFine') || ~isfield(iterData,'marineOriginalCoarse')
                diff = NaN; return;
            end
            fine_orig = iterData.marineOriginalFine;
            coarse_orig = iterData.marineOriginalCoarse;
            if isempty(fine_orig) || isempty(coarse_orig)
                diff = NaN; return;
            end
            try
                fine500_orig = interp1(iterData.wl, fine_orig, 0.5, 'linear','extrap');
                coarse500_orig = interp1(iterData.wl, coarse_orig, 0.5, 'linear','extrap');
            catch ME_interp500
                warning(ME_interp500.identifier, ...
                    'UpdateTau InitialFit: Interpolation error for marine 500 nm: %s. Aborting fit.', ...
                    ME_interp500.message);
                diff = NaN; return;
            end
            fine500_rh = fine500_orig * calculate_fRH(rh_i,'fine');
            coarse500_rh = coarse500_orig * calculate_fRH(rh_i,'coarse');
            basis500_vals(iterData.marineIndex) = current_w * fine500_rh + (1-current_w) * coarse500_rh;
        else
            x_use = x_temp;
        end

        AOD500_new = sum(basis500_vals .* x_use', 'omitnan');
        if isnan(AOD500_new) || isinf(AOD500_new)
            diff = NaN; return;
        end

        diff = AOD500_new - tau;
        x_fit = x_temp; % store parameters
    end
end

% --- Final Refinement Function ---
function [coef_fit, tau_inputs, w_vector] = ajusteAngstromMie_iterConFijos_OptAntiguo_v3_corrected(T, coef_fit_inicial, tau_inputs_inicial, w_vector_inicial, iterData, opciones)
    % Performs a final refinement fit on ALL records (day and night).
    % Uses results from initial fit/night averaging as starting points.
    % Allows skipping night points via opciones.refineNightData.
    % Uses opciones.w_deriv_refine for derivative constraint.
    % CORRECTED: Accesses marine data consistently from iterData.

    wl = iterData.wl;
    nFuentes = iterData.nFuentes;
    nRec = height(T);
    cols_idx = iterData.cols_idx;
    hours = hour(T.time); % Get hours for night check

    % Initialize output arrays with initial values
    coef_fit = coef_fit_inicial;
    tau_inputs = tau_inputs_inicial;
    w_vector = w_vector_inicial; % Contains optimized w (day) or averaged w (night) or fixed w

    tol = 1e-3;      % Convergence tolerance for tau
    max_iter = 10;   % Max iterations for tau convergence per record
    w_deriv = opciones.w_deriv_refine; % Use option for derivative weight
    peso = opciones.pesoBandas;

    opts_lsq = optimoptions('lsqcurvefit','Display','off','Algorithm','trust-region-reflective','TolFun',1e-7,'TolX',1e-7);

    % Determine parameter vector size and bounds (same logic as initial fit)
    if iterData.integratedMarine && ~isempty(iterData.marineIndex)
        lb = [repmat(opciones.coef_lb, nFuentes, 1); opciones.w_lb];
        ub = [repmat(opciones.coef_ub, nFuentes, 1); opciones.w_ub];
    else
        lb = repmat(opciones.coef_lb, nFuentes, 1);
        ub = repmat(opciones.coef_ub, nFuentes, 1);
    end

     pb = CmdLineProgressBar('>> Refining fits... ');
     for i = 1:nRec
        meas_i = T{i, cols_idx}'; % Measured AOD
        rh_i = T.RH(i);           % RH for this record

        % Check if initial data or state is bad
        if any(isnan(meas_i)) || any(isinf(meas_i)) || isnan(rh_i) || any(isnan(coef_fit(i,:))) || isnan(tau_inputs(i))
            coef_fit(i,:) = nan; % Ensure consistency
            tau_inputs(i) = nan;
            w_vector(i) = nan;
            pb.print(i,nRec);
            continue; % Skip if measurement or initial state is invalid
        end

        % Check if night point and if refinement for night points is disabled
        is_night = hours(i) < opciones.horarioValido(1) || hours(i) >= opciones.horarioValido(2);
        if is_night && ~opciones.refineNightData
            % Skip refinement for this night point, keep initial/averaged values
             pb.print(i,nRec);
             continue;
        end

        % --- Initial Tau for this refinement step ---
        tau_current = tau_inputs(i);
        tau_current = max(1e-4, min(tau_current, 2.0)); % Ensure bounds

        % --- Derivative of Measurement ---
        deriv_meas = zeros(size(wl));
        if w_deriv > 1e-6
            try
                meas_pos = max(1e-9, meas_i);
                 if ~any(isnan(meas_pos))
                     p_meas_deriv = polyfit(log(wl), log(meas_pos),4);
                     deriv_meas = polyval(polyder(p_meas_deriv), log(wl));
                 end
            catch ME_derivfit_refine
                 deriv_meas = zeros(size(wl));
            end
        end
        target = [peso .* meas_i; w_deriv * deriv_meas];

        % --- Initial Guess for lsqcurvefit ---
        if iterData.integratedMarine && ~isempty(iterData.marineIndex)
            w_guess = w_vector(i);
            if isnan(w_guess) || w_guess < lb(end) || w_guess > ub(end)
                w_guess = 0.5; % Default if initial w is bad
            end
            x_fit0 = [coef_fit(i,:)'; w_guess];
        else
            x_fit0 = coef_fit(i,:)';
        end
         x_fit0(1:nFuentes) = max(lb(1:nFuentes), min(ub(1:nFuentes), x_fit0(1:nFuentes)));

        % --- Iterative Tau Adjustment for Refinement ---
        x_fit = x_fit0; % Start with the initial guess
        for iter = 1:max_iter
            tau_prev_iter = tau_current;

            % 1. Build Basis (using current tau and RH)
            try
                [basis, basis500_vals] = buildBasis_OptAntiguo_v3_corrected(tau_current, rh_i, iterData);
                 if any(isnan(basis),'all') || any(isinf(basis),'all') || any(isnan(basis500_vals),'all') || any(isinf(basis500_vals),'all')
                     tau_current = tau_prev_iter; break; % Use previous state if basis fails
                 end
            catch ME_basis_refine
                 warning('Error building basis during refinement i=%d: %s. Using previous tau.', i, ME_basis_refine.message);
                 tau_current = tau_prev_iter; break;
            end

            % 2. Define Model Function Handle
             modelFun = @(x, ~) modeloConAngstrom_OptAntiguo_corrected(x, basis, wl, rh_i, w_deriv, peso, iterData);

            % 3. Perform Fit
            try
                [x_fit_iter, ~, ~, exitflag, ~] = lsqcurvefit(modelFun, x_fit, [], target, lb, ub, opts_lsq); % Use current x_fit as guess
                if exitflag <= 0
                    tau_current = tau_prev_iter; break; % Keep previous state if fit fails
                else
                    x_fit = x_fit_iter; % Store successful fit
                end
            catch ME_lsq_refine
                 warning('Error during lsqcurvefit (refinement) i=%d: %s. Using previous result.', i, ME_lsq_refine.message);
                 tau_current = tau_prev_iter; break;
            end

            % 4. Update Tau

             if iterData.integratedMarine && ~isempty(iterData.marineIndex)
                 current_w = x_fit(end); % Get optimized w from this iteration
                 x_use = x_fit(1:end-1); % Coefficients

                 % *** CORRECTION HERE: Use iterData for original marine data ***
                 fine_orig = iterData.marineOriginalFine;
                 coarse_orig = iterData.marineOriginalCoarse;
                 if isempty(fine_orig) || isempty(coarse_orig)
                      warning('Refinement UpdateTau: Missing original marine data in iterData for record i=%d', i);
                      tau_current = tau_prev_iter; break; % Abort iteration if data missing
                 end
                 fine500_orig = interp1(iterData.wl, fine_orig, 0.5, 'linear', 'extrap');
                 coarse500_orig = interp1(iterData.wl, coarse_orig, 0.5, 'linear', 'extrap');
                 fine500_rh = fine500_orig * calculate_fRH(rh_i, 'fine');
                 coarse500_rh = coarse500_orig * calculate_fRH(rh_i, 'coarse');
                 % Update the 500nm value for the combined source using new w
                 basis500_vals(iterData.marineIndex) = current_w * fine500_rh + (1-current_w) * coarse500_rh;
             else
                 x_use = x_fit; % All parameters are coefficients
             end

            AOD500_new = sum(basis500_vals .* x_use', 'omitnan'); % Calculate new AOD500 estimate
            AOD500_new = max(1e-4, min(AOD500_new, 5.0)); % Bound the result

            if isnan(AOD500_new) || isinf(AOD500_new)
                tau_current = tau_prev_iter; break; % Revert tau if update fails
            end

            % 5. Check Convergence
            if abs(AOD500_new - tau_current)/max(tau_current, 1e-9) < tol
                tau_current = AOD500_new; break; % Converged
            else
                tau_current = AOD500_new; % Not converged, update tau
            end
        end % End of inner iteration loop for record i

        % --- Assign Final Refined Results for record i ---
        tau_inputs(i) = tau_current; % Assign final tau for this record

        if ~isnan(tau_current) && ~any(isnan(x_fit))
            if iterData.integratedMarine && ~isempty(iterData.marineIndex)
                coef_fit(i,:) = x_fit(1:end-1)';
                w_vector(i) = x_fit(end);
            else
                coef_fit(i,:) = x_fit';
            end
        else
             % If refinement failed (NaN tau or x_fit), revert to initial values
             coef_fit(i,:) = coef_fit_inicial(i,:);
             tau_inputs(i) = tau_inputs_inicial(i);
             w_vector(i) = w_vector_inicial(i);
              % warning('Refinement failed or produced NaN for record i=%d, reverting to pre-refinement values.', i);
        end
         pb.print(i, nRec);
     end % End of loop over records

end

%% ==================== RECALCULATION FUNCTIONS ====================

function AOD_model_all = calcularAODporBanda_OptAntiguo_v3_corrected(nRec, rh_vector, iterData, coef_fit, tau_inputs, w_vector)
    % Calculates the modeled AOD spectrum for each record using final parameters.
    % Handles integratedMarine mode by reconstructing the combined basis dynamically.

    nBands = length(iterData.wl);
    AOD_model_all = nan(nRec, nBands);

    for i = 1:nRec
        tau_val = tau_inputs(i);
        rh_i = rh_vector(i);
        w_i = w_vector(i); % Final w for this time step (optimized or fixed)
        coef_i = coef_fit(i,:)'; % Coefficients for this record (as column vector)

        % Check for invalid inputs for this time step
        is_integrated_case = iterData.integratedMarine && ~isempty(iterData.marineIndex);
         if isnan(tau_val) || any(isnan(coef_i)) || isnan(rh_i) || (is_integrated_case && isnan(w_i))
            continue; % Skip calculation if inputs are bad
         end

        try
            % Build basis using the final tau, RH.
            % Basis column for 'combined_marine' will be zero initially.
            [basis_i, ~] = buildBasis_OptAntiguo_v3_corrected(tau_val, rh_i, iterData);

             % If integrated marine is active, dynamically build the combined marine
             % column in the basis using the final w_i and RH.
             if is_integrated_case
                 marineIdx = iterData.marineIndex;
                 % Get original data from iterData
                 fine_orig = iterData.marineOriginalFine;
                 coarse_orig = iterData.marineOriginalCoarse;

                 if isempty(fine_orig) || isempty(coarse_orig)
                      warning('calcAODbanda: Missing original marine data in iterData for record i=%d', i);
                      AOD_model_all(i,:) = NaN; continue;
                 end

                 % Apply RH correction
                 fRH_fine = calculate_fRH(rh_i, 'fine');
                 fRH_coarse = calculate_fRH(rh_i, 'coarse');
                 marineFine_corr = fine_orig * fRH_fine;
                 marineCoarse_corr = coarse_orig * fRH_coarse;
                 % Combine using the final w_i
                 combinedMarine = w_i * marineFine_corr + (1-w_i) * marineCoarse_corr;
                 % Update the basis column for this calculation
                 basis_i(:, marineIdx) = combinedMarine; % Overwrite placeholder zeros
             end
             % If not integratedMarine, basis_i from buildBasis is already correct.

             % Calculate final modeled spectrum: basis * coefficients
             AOD_model_all(i,:) = (basis_i * coef_i)'; % Matrix multiplication, transpose result to row

        catch ME_recalcBands
             warning('Error during AOD band recalculation for record i=%d: %s', i, ME_recalcBands.message);
             AOD_model_all(i,:) = NaN; % Mark as NaN on error
        end
    end
end
function AOD500_sources = recalcularAOD500_OptAntiguo_v3_corrected(nRec, rh_vector, iterData, coef_fit, tau_inputs, w_vector)
    % Calculates the AOD contribution of each source at 500nm.
    % Uses final parameters and consistent RH correction via buildBasis.
    % Handles integratedMarine mode by reconstructing the 500nm value using final w.

    nFuentes = iterData.nFuentes;
    AOD500_sources = nan(nRec, nFuentes);

    for i = 1:nRec
        tau_val = tau_inputs(i);
        rh_i = rh_vector(i);
        w_i = w_vector(i); % Final w for this time step (optimized or fixed)

        % Check for invalid inputs for this time step
        is_integrated_case = iterData.integratedMarine && ~isempty(iterData.marineIndex);
        if isnan(tau_val) || any(isnan(coef_fit(i,:))) || isnan(rh_i) || (is_integrated_case && isnan(w_i))
            continue; % Skip if essential inputs are NaN
        end

         try
             % Get basis values at 500nm, RH-corrected by buildBasis
             % Note: For 'combined_marine', basis500_vals contains a value calculated
             % with w=0.5 (used for tau update). We need to recalculate it here
             % using the actual final w_i if in integratedMarine mode.
             [~, basis500_vals_i] = buildBasis_OptAntiguo_v3_corrected(tau_val, rh_i, iterData);

             % If integratedMarine, recalculate the 500nm value
             % for the combined source using the final w_i and RH.
             if is_integrated_case % Equivalent to: iterData.integratedMarine && ~isempty(iterData.marineIndex)
                 marineIdx = iterData.marineIndex;
                 % Get original data from iterData
                 fine_orig = iterData.marineOriginalFine;
                 coarse_orig = iterData.marineOriginalCoarse;

                 if isempty(fine_orig) || isempty(coarse_orig)
                      warning('recalcAOD500: Missing original marine data in iterData for record i=%d', i);
                      AOD500_sources(i,:) = NaN; continue;
                 end

                 % Interpolate original fine/coarse data to 500nm
                 wl_orig = iterData.wl; % Wavelengths corresponding to original data
                 fine500_orig = interp1(wl_orig, fine_orig, 0.5, 'linear', 'extrap');
                 coarse500_orig = interp1(wl_orig, coarse_orig, 0.5, 'linear', 'extrap');
                 % Apply RH correction
                 fine500_rh = fine500_orig * calculate_fRH(rh_i, 'fine');
                 coarse500_rh = coarse500_orig * calculate_fRH(rh_i, 'coarse');
                 % Combine using the final w_i for this time step
                 combinedMarine500 = w_i * fine500_rh + (1 - w_i) * coarse500_rh;
                 % Update the value in the basis500 vector for this calculation
                 basis500_vals_i(marineIdx) = combinedMarine500;
             end
             % If not integratedMarine mode, the basis500_vals_i calculated by
             % buildBasis (for 'fixed_marine' or 'fija_marine') is already correct.

             % Calculate final contribution: coefficient * basis_value_at_500nm
             AOD500_sources(i,:) = coef_fit(i,:) .* basis500_vals_i;

         catch ME_recalc500
              warning('Error during AOD500 source recalculation for record i=%d: %s', i, ME_recalc500.message);
              AOD500_sources(i,:) = NaN; % Assign NaN on error
         end
    end
end


function tablaBandas = computeBandPercTable_OptAntiguo_v3_corrected(...
    T_input, rh_vector, iterData, coef_fit, tau_inputs, w_vector)
% computeBandPercTable_OptAntiguo_v3_corrected
%   Calcula la contribución porcentual de cada fuente al AOD modelado
%   para cada banda y cada registro de tiempo.
%
% USO:
%   tablaBandas = computeBandPercTable_OptAntiguo_v3_corrected( ...
%                     T_input, rh_vector, iterData, ...
%                     coef_fit, tau_inputs, w_vector )
%
% ENTRADAS:
%   T_input    : tabla con columna 'time' (datetime) y AODs en iterData.cols_idx
%   rh_vector  : [nRec×1] vector de Humedad Relativa (%)
%   iterData   : struct con campos:
%                  .nFuentes, .integratedMarine, .marineIndex,
%                  .marineOriginalFine, .marineOriginalCoarse,
%                  .fuentes, .wl, .cols_idx, etc.
%   coef_fit   : [nRec×nFuentes] coeficientes ajustados
%   tau_inputs : [nRec×1]  tau usados
%   w_vector   : [nRec×1]  fracción marina (opt. o fija)
%
% SALIDA:
%   tablaBandas: tabla con columnas:
%                  time | banda | <fuente1>% | … | <fuenteN>%

    % 0) Validación de la tabla de tiempos
    if ~istable(T_input) || ~ismember('time',T_input.Properties.VariableNames)
        error('computeBandPercTable: T_input debe ser una tabla con columna ''time''.');
    end

    nRec     = height(T_input);
    bandNames = {'AOD340','AOD380','AOD440','AOD500','AOD675','AOD870','AOD1020'};
    nBands   = numel(bandNames);
    nFuentes = iterData.nFuentes;

    % 1) Prealocar
    totalRows = nRec * nBands;
    timeCol   = NaT(totalRows,1);
    bandaCol  = cell(totalRows,1);
    dataMat   = nan(totalRows,nFuentes);

    % Nombres válidos para variables de tabla
    fuenteNombres = matlab.lang.makeValidName({iterData.fuentes.name});

    % 2) Loop por registro
    rowStart = 1;
    for i = 1:nRec
        rows_i = rowStart:(rowStart+nBands-1);

        % rellenar time/banda
        timeCol(rows_i)  = repmat(T_input.time(i), nBands,1);
        bandaCol(rows_i) = bandNames';

        % parámetros
        tau_i  = tau_inputs(i);
        rh_i   = rh_vector(i);
        w_i    = w_vector(i);
        coef_i = coef_fit(i,:);

        % si falta algo crítico, saltar
        isInt = iterData.integratedMarine && ~isempty(iterData.marineIndex);
        if any(isnan(coef_i)) || isnan(tau_i) || isnan(rh_i) || (isInt && isnan(w_i))
            rowStart = rowStart + nBands;
            continue;
        end

        try
            % 2.1) base espectral
            [basis_i,~] = buildBasis_OptAntiguo_v3_corrected(tau_i, rh_i, iterData);

            % 2.2) reconstruir columna marina si aplica
            if isInt
                idxM = iterData.marineIndex;
                fineOrig   = iterData.marineOriginalFine;
                coarseOrig = iterData.marineOriginalCoarse;
                if isempty(fineOrig) || isempty(coarseOrig)
                    warning('computeBandPercTable: faltan datos marinos iterData para i=%d.',i);
                    rowStart = rowStart + nBands;
                    continue;
                end
                fRH_fine   = calculate_fRH(rh_i,'fine');
                fRH_coarse = calculate_fRH(rh_i,'coarse');
                mf = fineOrig   * fRH_fine;
                mc = coarseOrig * fRH_coarse;
                basis_i(:,idxM) = w_i*mf + (1-w_i)*mc;
            end

            % 2.3) contribuciones absolutas
            contrib = basis_i .* coef_i;          % [nBands×nFuentes]
            sumAll  = sum(contrib,2,'omitnan');   % [nBands×1]

            % 2.4) calcular porcentaje
            perc = nan(nBands,nFuentes);
            valid = abs(sumAll)>1e-9;
            perc(valid,:) = contrib(valid,:)./sumAll(valid)*100;

            % 2.5) casos sumAll≈0
            zeroIdx = ~valid;
            for j=1:nFuentes
                z = zeroIdx & abs(contrib(:,j))<1e-9;
                perc(z,j)=0;
                % los demás quedan NaN
            end

            dataMat(rows_i,:) = perc;

        catch ME
            warning('Error en computeBandPercTable i=%d (%s): %s', i, datestr(T_input.time(i)), ME.message);
        end

        rowStart = rowStart + nBands;
    end

    % 3) montar tabla
    varNames   = [{'time','banda'}, fuenteNombres];
    tablaBandas = table(timeCol, bandaCol, 'VariableNames',varNames(1:2));
    tablaBandas = [ tablaBandas, array2table(dataMat,'VariableNames',varNames(3:end)) ];
end



%% ==================== CROSS-VALIDATION FUNCTION ====================
function cvMetrics = validacionCruzadaAOD_OptAntiguo_v3_corrected(T, iterData, opciones)
    % Performs K-Fold Cross Validation.
    % WARNING: This evaluates ONLY the initial daytime fit performance.
    % Does NOT include night treatment or final refinement effects.

    k = opciones.cv_k;

    % --- IMPORTANT: Filter T to include only DAYTIME records for CV ---
    % CV should only be performed on the data that the evaluated model part uses.
    h = hour(T.time);
    idx_day_cv = h >= opciones.horarioValido(1) & h < opciones.horarioValido(2);
    T_day = T(idx_day_cv, :);
    nRec = height(T_day); % Number of daytime records for CV

    if nRec < k
        warning('Number of daytime records (%d) is less than K (%d) for CV. Aborting CV.', nRec, k);
        cvMetrics = struct('error', 'Insufficient daytime data for K-Fold CV.');
        return;
    end
    if nRec == 0
         warning('No daytime records found for CV. Aborting CV.');
         cvMetrics = struct('error', 'No daytime data for CV.');
         return;
    end


    indices = crossvalind('Kfold', nRec, k); % Generate indices for K folds on daytime data
    nBands = length(iterData.wl);
    band_cols_names = T.Properties.VariableNames(iterData.cols_idx);

    % Initialize metrics arrays
    rmseFolds = nan(k, nBands);
    r2Folds = nan(k, nBands);
    maeFolds = nan(k, nBands);

    disp('>> Starting K-Fold Cross-Validation (Initial Daytime Fit Only)...');
    % Use the initial adjustment function
    ajusteFuncCV = @ajusteAngstromMie_iter_OptAntiguo_v3_corrected;
    % Function to recalculate AOD for all bands
    recalcFuncCV = @calcularAODporBanda_OptAntiguo_v3_corrected;

    for i = 1:k % Loop through folds
        testIdxLog = (indices == i);  % Logical index for test set within T_day
        % trainIdxLog = ~testIdxLog; % Logical index for training set within T_day
        % Note: Training set is not explicitly used in this CV approach,
        % as the model (ajusteFuncCV) fits each point independently.

        T_test = T_day(testIdxLog,:); % Select test data for this fold
        nTest = height(T_test);

        if nTest == 0
            disp(['>> Fold ' num2str(i) ': Skipping (No test records).']);
            continue;
        end
        disp(['>> Fold ' num2str(i) ': Testing on ' num2str(nTest) ' daytime records.']);

        % --- Apply the initial fit model to the test set ---
        coef_test = nan(nTest, iterData.nFuentes);
        tau_test = nan(nTest, 1);
        w_test = nan(nTest, 1); % Capture w (optimized or fixed)
        rh_test = T_test.RH; % Get RH for test set

        for i_test = 1:nTest
            meas_i = T_test{i_test, iterData.cols_idx}'; % AOD data
            rh_i = rh_test(i_test); % RH data

            if any(isnan(meas_i)) || any(isinf(meas_i)) || isnan(rh_i)
                 continue; % Skip bad data points in test set
            end
            try
                % Apply the same initial fitting function used in the main code
                [coef_tmp, tau_tmp, w_tmp] = ajusteFuncCV(meas_i, rh_i, iterData, opciones);
                coef_test(i_test,:) = coef_tmp;
                tau_test(i_test) = tau_tmp;
                w_test(i_test) = w_tmp;
            catch ME_cv_fit
                 fprintf('Error during CV fit (Fold %d, Test Record %d): %s\n', i, i_test, ME_cv_fit.message);
                 % Leave results as NaN
            end
        end

        % --- Predict AOD on the test set using the fitted parameters ---
        try
            AOD_model_test = recalcFuncCV(nTest, rh_test, iterData, coef_test, tau_test, w_test);
        catch ME_cv_recalc
             fprintf('Error during CV recalculation (Fold %d): %s\n', i, ME_cv_recalc.message);
             AOD_model_test = nan(nTest, nBands); % Set model to NaN on error
        end

        AOD_meas_test = T_test{:, iterData.cols_idx}; % Measured AOD for the test set

        % --- Calculate metrics for this fold ---
        % Find rows where both measurement and model prediction are valid
        validRows = ~any(isnan(AOD_model_test),2) & ~any(isnan(AOD_meas_test),2);

        if sum(validRows) > 1 % Need at least 2 points for R2 calculation
            for b = 1:nBands
                model_valid = AOD_model_test(validRows, b);
                meas_valid = AOD_meas_test(validRows, b);

                diff = model_valid - meas_valid;
                rmseFolds(i,b) = sqrt(mean(diff.^2));
                maeFolds(i,b) = mean(abs(diff));

                % Calculate R2 score
                SS_res = sum(diff.^2); % Residual sum of squares
                SS_tot = sum((meas_valid - mean(meas_valid)).^2); % Total sum of squares

                if SS_tot < 1e-12 % Avoid division by zero if measured data is constant
                    if SS_res < 1e-12 % Model is also constant and matches -> R2 = 1
                        r2Folds(i,b) = 1.0;
                    else % Model differs from constant measurement -> R2 = 0 (or negative if worse than mean)
                        r2Folds(i,b) = 1 - SS_res / (SS_tot + 1e-12); % Prevent exact zero division
                    end
                else
                    r2Folds(i,b) = 1 - SS_res / SS_tot;
                end
                 % Ensure R2 doesn't go arbitrarily negative if SS_res >> SS_tot
                 % r2Folds(i,b) = max(-Inf, r2Folds(i,b)); % R2 can be negative
            end
            disp(['>> Fold ' num2str(i) ': RMSE(500nm)=' sprintf('%.4f', rmseFolds(i,4)) ', R2(500nm)=' sprintf('%.3f', r2Folds(i,4)) ', MAE(500nm)=' sprintf('%.4f', maeFolds(i,4))]);
        else
            disp(['>> Fold ' num2str(i) ': Skipping metrics calculation (insufficient valid points: ', num2str(sum(validRows)) ,').']);
        end
    end % End of fold loop

    % --- Aggregate metrics across folds ---
    cvMetrics = struct();
    cvMetrics.rmse_mean = mean(rmseFolds, 1, 'omitnan');
    cvMetrics.r2_mean = mean(r2Folds, 1, 'omitnan');
    cvMetrics.mae_mean = mean(maeFolds, 1, 'omitnan');
    cvMetrics.rmse_std = std(rmseFolds, 0, 1, 'omitnan');
    cvMetrics.r2_std = std(r2Folds, 0, 1, 'omitnan');
    cvMetrics.mae_std = std(maeFolds, 0, 1, 'omitnan');
    cvMetrics.bandas = band_cols_names;
    cvMetrics.K = k;
    cvMetrics.n_records_cv = nRec;
    cvMetrics.WARNING = 'Metrics evaluate INITIAL DAYTIME FIT ONLY. Does NOT include night treatment or final refinement.';

    disp('>> Cross-Validation (Initial Daytime Fit Only) Completed.');
end


%% ==================== BASIS & MODEL FUNCTIONS ====================

function [basis, basis500_vals] = buildBasis_OptAntiguo_v3_corrected(tau_current, rh_actual, iterData)
    % Builds the basis matrix for a given tau and RH.
    % Applies RH correction internally based on source type using data from iterData.
    % For 'combined_marine', returns placeholder basis=0, model function handles combination.

    nFuentes = iterData.nFuentes;
    nLambda = length(iterData.wl);
    basis = zeros(nLambda, nFuentes);
    basis500_vals = zeros(1, nFuentes); % Basis values specifically at 500nm

    % --- Process 'fija' sources (standard non-marine fixed) ---
    for k = 1:length(iterData.idxFija)
        j = iterData.idxFija(k); % Index in the 'fuentes' list
        basis(:, j) = iterData.fuentes(j).data(:); % Use data directly from source struct
        % Interpolate at 500nm, handle potential errors
        try
            basis500_vals(j) = interp1(iterData.wl, basis(:,j), 0.5, 'linear', 'extrap');
        catch
            basis500_vals(j) = NaN; % Assign NaN if interpolation fails
        end
    end

    % --- Process original 'Marino_Fine'/'Marino_Coarse' if kept separate ('fija_marine') ---
     for k = 1:length(iterData.idxFijaMarine)
         j = iterData.idxFijaMarine(k); % Index in 'fuentes' list
         fuente = iterData.fuentes(j);
         data_orig = fuente.data(:); % Original uncorrected data from source struct
         if contains(fuente.name, 'Fine', 'IgnoreCase', true)
              fRH = calculate_fRH(rh_actual, 'fine');
         elseif contains(fuente.name, 'Coarse', 'IgnoreCase', true)
              fRH = calculate_fRH(rh_actual, 'coarse');
         else
              warning('Source "%s" is type fija_marine but name mismatch for RH factor.', fuente.name);
              fRH = 1.0; % Default if name doesn't match
         end
         basis(:, j) = data_orig * fRH; % Apply RH correction
         try
             basis500_vals(j) = interp1(iterData.wl, basis(:,j), 0.5, 'linear', 'extrap');
         catch
             basis500_vals(j) = NaN;
         end
     end

    % --- Process combined 'Marino' source with FIXED fraction ('fixed_marine') ---
     for k = 1:length(iterData.idxFixedMarine)
         j = iterData.idxFixedMarine(k); % Index in 'fuentes' list
         % Ensure this index matches the globally stored marineIndex from iterData
         if j == iterData.marineIndex && ~isempty(iterData.marineIndex)
             % Get necessary info from iterData
             w_fixed = iterData.marineFixedW;
             fine_orig = iterData.marineOriginalFine;
             coarse_orig = iterData.marineOriginalCoarse;

             if isempty(fine_orig) || isempty(coarse_orig) || isnan(w_fixed)
                 warning('buildBasis: Missing original marine data or fixed_w in iterData for fixed_marine source at index %d', j);
                 basis(:,j) = NaN; basis500_vals(j) = NaN; continue;
             end

             % Apply RH correction
             fine_rh = fine_orig * calculate_fRH(rh_actual, 'fine');
             coarse_rh = coarse_orig * calculate_fRH(rh_actual, 'coarse');
             % Combine using fixed w stored in iterData
             basis(:, j) = w_fixed * fine_rh + (1 - w_fixed) * coarse_rh;
             try
                 basis500_vals(j) = interp1(iterData.wl, basis(:,j), 0.5, 'linear', 'extrap');
             catch
                 basis500_vals(j) = NaN;
             end
         else
              warning('buildBasis: Mismatch between idxFixedMarine and iterData.marineIndex? Index: %d', j);
              basis(:,j) = NaN; basis500_vals(j) = NaN;
         end
     end

     % --- Process combined 'Marino' source with VARIABLE fraction ('combined_marine') ---
     % For buildBasis: Set basis column to 0 (model function handles it).
     % Calculate basis500_vals using a default w=0.5 for the tau update step.
      for k = 1:length(iterData.idxCombinedMarine)
         j = iterData.idxCombinedMarine(k); % Index in 'fuentes' list
         if j == iterData.marineIndex && ~isempty(iterData.marineIndex)
             % Get original data from iterData
             fine_orig = iterData.marineOriginalFine;
             coarse_orig = iterData.marineOriginalCoarse;

             if isempty(fine_orig) || isempty(coarse_orig)
                  warning('buildBasis: Missing original marine data in iterData for combined_marine source at index %d', j);
                  basis(:,j) = NaN; basis500_vals(j) = NaN; continue;
             end

             % Apply RH correction
             fine_rh = fine_orig * calculate_fRH(rh_actual, 'fine');
             coarse_rh = coarse_orig * calculate_fRH(rh_actual, 'coarse');

             % For basis500_vals used in tau update, calculate with default w=0.5
             w_default = 0.5;
             combined_default = w_default * fine_rh + (1 - w_default) * coarse_rh;
             try
                 basis500_vals(j) = interp1(iterData.wl, combined_default, 0.5, 'linear', 'extrap');
             catch
                 basis500_vals(j) = NaN;
             end
             % Leave basis(:,j) as zeros, as it will be constructed in the model function.
             basis(:, j) = 0; % Placeholder - IMPORTANT
         else
              warning('buildBasis: Mismatch between idxCombinedMarine and iterData.marineIndex? Index: %d', j);
              basis(:,j) = NaN; basis500_vals(j) = NaN;
         end
     end


    % --- Process 'tau' dependent sources ---
    if ~isnan(tau_current)
        if length(iterData.idxTau) ~= length(iterData.tauLevels) % Basic sanity check
             error('buildBasis: Mismatch between number of tau sources and tauLevels in iterData.');
        end
        for k = 1:length(iterData.idxTau)
            j_tau = iterData.idxTau(k); % Index in the 'fuentes' list for this tau source
            try
                % Interpolate full spectrum data
                interp_row = interp1(iterData.tauLevels{k}, iterData.fullData{k}, tau_current, 'linear', 'extrap');
                basis(:, j_tau) = interp_row';
                % Interpolate 500nm data (already extracted)
                basis500_vals(j_tau) = interp1(iterData.tauLevels{k}, iterData.fullData500{k}, tau_current, 'linear', 'extrap');
            catch ME_interp
                 warning('buildBasis: Interpolation failed for tau source "%s" (index %d): %s', iterData.fuentes(j_tau).name, j_tau, ME_interp.message);
                 basis(:, j_tau) = NaN;
                 basis500_vals(j_tau) = NaN;
            end
        end
    else
        % If tau is NaN, set basis for tau-dependent sources to NaN
        basis(:, iterData.idxTau) = NaN;
        basis500_vals(iterData.idxTau) = NaN;
    end

    % Ensure basis is non-negative
    basis(basis < 0) = 0;
    basis500_vals(basis500_vals < 0) = 0;

end

function out = modeloConAngstrom_OptAntiguo_corrected(x, basis_in, wl, rh_i, w_deriv, peso, iterData)
    % Calculates the modeled AOD spectrum + derivative term for lsqcurvefit.
    % Handles the 'w' parameter dynamically if integratedMarine is active.
    % Reads necessary original marine data from iterData.

    basis = basis_in; % Start with the basis provided (RH corrected for fixed sources)
                      % Note: basis column for 'combined_marine' is initially zero.

    % If integrated marine is active, x includes w at the end.
    if iterData.integratedMarine && ~isempty(iterData.marineIndex)
        % Check if parameter vector length matches expectation
        if length(x) ~= iterData.nFuentes + 1
             error('modeloConAngstrom: Incorrect number of parameters x (%d) received for integratedMarine mode (expected %d).', length(x), iterData.nFuentes + 1);
        end
        w = x(end);         % Extract w (last element)
        x_use = x(1:end-1); % Coefficients are the first nFuentes elements
        marineIdx = iterData.marineIndex; % Index in 'fuentes' of the combined marine source

        % Dynamically build the combined marine spectrum using current w and RH
        % Get original (uncorrected) data from iterData
        marineFine_orig = iterData.marineOriginalFine;
        marineCoarse_orig = iterData.marineOriginalCoarse;

        % Check if data was loaded correctly into iterData
        if isempty(marineFine_orig) || isempty(marineCoarse_orig)
             error('modeloConAngstrom: Missing original marine data in iterData for integratedMarine mode.');
        end

        % Apply RH correction
        fRH_fine = calculate_fRH(rh_i, 'fine');
        fRH_coarse = calculate_fRH(rh_i, 'coarse');
        marineFine_corr = marineFine_orig * fRH_fine;
        marineCoarse_corr = marineCoarse_orig * fRH_coarse;

        % Combine using the current w being tested by the optimizer
        combinedMarine = w * marineFine_corr + (1-w) * marineCoarse_corr;

        % Update the basis matrix column for the combined marine source for this calculation
        basis(:, marineIdx) = combinedMarine; % Overwrite the placeholder zeros from buildBasis
    else
        % If not integrated marine, all elements of x are coefficients
        if length(x) ~= iterData.nFuentes
             error('modeloConAngstrom: Incorrect number of parameters x (%d) received for non-integratedMarine mode (expected %d).', length(x), iterData.nFuentes);
        end
        x_use = x; % All parameters are coefficients
        % Basis should already be correctly RH-corrected from buildBasis for fixed/fija_marine types
    end

    % Calculate modeled spectrum: basis * coefficients
    model_spec = basis * x_use; % Matrix multiplication
    model_spec(model_spec <= 1e-9) = 1e-9; % Floor values for log operations in derivative calculation

    % Calculate derivative of the model spectrum (if needed)
    deriv_model = zeros(size(wl));
    if w_deriv > 1e-6
        try
             % Use polyfit for derivative estimation
             p_model = polyfit(log(wl), log(model_spec), 4); % Fit on log-log scale
             deriv_model = polyval(polyder(p_model), log(wl)); % Evaluate derivative of polynomial
        catch ME_modelderiv
             % warning('Polyfit failed for model derivative: %s', ME_modelderiv.message);
             deriv_model = zeros(size(wl)); % Use zero derivative if fit fails
        end
    end

    % Output vector for lsqcurvefit (weighted spectrum + weighted derivative)
    out = [peso(:) .* model_spec; w_deriv * deriv_model];
end

%% ==================== Hygroscopic Growth Factor ====================
function fRH = calculate_fRH(RH, mode_type)
    % Calculates hygroscopic growth factor f(RH).
    % RH is in percent (e.g., 80).
    % mode_type is 'fine' or 'coarse'.

    if isnan(RH)
        fRH = 1.0; % No growth if RH is unknown
        return;
    end

    RH_frac = max(0, min(0.99, RH / 100)); % Ensure RH fraction is in [0, 0.99] for stability

    % Parameters (example, adjust based on literature/measurements)
    % Using a common kappa-Köhler approximation style: f(RH) = (1 - RH_frac)^(-gamma)
    % Or simpler power law: f(RH) = 1 + a*(RH_frac)^b
    % Using the power law form from the original snippet for consistency:
    if strcmpi(mode_type, 'fine')
        a = 0.5; b = 2; % Parameters for fine mode marine
    elseif strcmpi(mode_type, 'coarse')
        a = 1.5; b = 2; % Parameters for coarse mode marine
    else
        a = 0; b = 1;   % Default: no growth
    end

    fRH = 1 + a * (RH_frac)^b;

    % Ensure fRH is reasonable (e.g., not negative or excessively large)
    fRH = max(1.0, fRH);

end

%% ==================== Original Source Definitions ====================
function fuentes = defineSources_OptAntiguo()
    % Defines the base aerosol source spectra (uncorrected for RH).
    % Marino_Fine (fine mode)
    fuentes(1).name = 'Marino_Fine';
    fuentes(1).type = 'fija_marine'; % Changed type for RH handling
    fuentes(1).wavelengths = [0.34,0.38,0.44,0.50,0.675,0.87,1.02];
    fuentes(1).data = [9.629366e-02;8.805716e-02;7.635752e-02;6.62385e-02;4.292353e-02;2.655339e-02;1.661978e-02];
    % Marino_Coarse (coarse mode)
    fuentes(2).name = 'Marino_Coarse';
    fuentes(2).type = 'fija_marine'; % Changed type for RH handling
    fuentes(2).wavelengths = [0.34,0.38,0.44,0.50,0.675,0.87,1.02];
    fuentes(2).data = [5.333897e+00;5.412068e+00;5.531496e+00;5.6794e+00;6.020233e+00;6.322361e+00;6.445188e+00];
    % Strongly_Absorbing (e.g., Smoke/BC)
    fuentes(3).name = 'Strongly_Absorbing';
    fuentes(3).type = 'tau'; % Type indicates AOD dependency
    fuentes(3).wavelengths = [0.34,0.38,0.44,0.50,0.675,0.87,1.02];
    fuentes(3).tau_levels = [0.02,0.04,0.06,0.08,0.09,0.10,0.12,0.15,0.18,0.20,0.40,0.60,0.80,1.00,1.20]; % AOD500 levels
    fuentes(3).full_data = [... % Corresponding spectra for each tau_level
        2.626e-02,2.286e-02,1.857e-02,1.522e-02,9.341e-03,6.472e-03,5.418e-03;
        4.799e-02,4.168e-02,3.372e-02,2.750e-02,1.655e-02,1.118e-02,9.195e-03;
        6.837e-02,5.932e-02,4.789e-02,3.895e-02,2.320e-02,1.544e-02,1.256e-02;
        8.795e-02,7.625e-02,6.149e-02,4.994e-02,2.953e-02,1.945e-02,1.569e-02;
        9.751e-02,8.453e-02,6.813e-02,5.530e-02,3.261e-02,2.138e-02,1.719e-02;
        1.069e-01,9.270e-02,7.469e-02,6.059e-02,3.564e-02,2.328e-02,1.866e-02;
        1.255e-01,1.088e-01,8.760e-02,7.101e-02,4.159e-02,2.699e-02,2.152e-02;
        1.527e-01,1.324e-01,1.065e-01,8.629e-02,5.031e-02,3.238e-02,2.564e-02;
        1.794e-01,1.554e-01,1.251e-01,1.013e-01,5.883e-02,3.761e-02,2.960e-02;
        1.968e-01,1.706e-01,1.373e-01,1.111e-01,6.443e-02,4.103e-02,3.218e-02;
        3.640e-01,3.161e-01,2.549e-01,2.063e-01,1.186e-01,7.368e-02,5.638e-02;
        5.228e-01,4.551e-01,3.682e-01,2.988e-01,1.717e-01,1.054e-01,7.939e-02;
        6.763e-01,5.905e-01,4.796e-01,3.904e-01,2.252e-01,1.373e-01,1.023e-01;
        8.259e-01,7.232e-01,5.898e-01,4.818e-01,2.794e-01,1.699e-01,1.257e-01;
        9.720e-01,8.535e-01,6.989e-01,5.731e-01,3.347e-01,2.034e-01,1.497e-01];
    % Weakly_Absorbing (e.g., Urban/Sulfate)
    fuentes(4).name = 'Weakly_Absorbing';
    fuentes(4).type = 'tau';
    fuentes(4).wavelengths = [0.340,0.380,0.440,0.500,0.675,0.87,1.02];
    fuentes(4).tau_levels = [0.02,0.04,0.06,0.08,0.09,0.10,0.12,0.15,0.18,0.20,0.40,0.60,0.80,1.00,1.20];
    fuentes(4).full_data = [...
        2.750e-02,2.404e-02,1.968e-02,1.627e-02,1.025e-02,7.255e-03,6.126e-03;
        4.797e-02,4.188e-02,3.419e-02,2.817e-02,1.747e-02,1.210e-02,1.006e-02;
        6.653e-02,5.808e-02,4.738e-02,3.898e-02,2.398e-02,1.641e-02,1.351e-02;
        8.397e-02,7.333e-02,5.982e-02,4.918e-02,3.011e-02,2.043e-02,1.671e-02;
        9.238e-02,8.070e-02,6.585e-02,5.413e-02,3.309e-02,2.237e-02,1.825e-02;
        1.006e-01,8.793e-02,7.177e-02,5.900e-02,3.602e-02,2.428e-02,1.975e-02;
        1.167e-01,1.021e-01,8.335e-02,6.853e-02,4.176e-02,2.801e-02,2.268e-02;
        1.400e-01,1.226e-01,1.002e-01,8.245e-02,5.016e-02,3.345e-02,2.693e-02;
        1.625e-01,1.424e-01,1.166e-01,9.604e-02,5.841e-02,3.878e-02,3.106e-02;
        1.771e-01,1.554e-01,1.274e-01,1.050e-01,6.384e-02,4.228e-02,3.378e-02;
        3.120e-01,2.764e-01,2.294e-01,1.908e-01,1.174e-01,7.694e-02,6.037e-02;
        4.327e-01,3.869e-01,3.251e-01,2.732e-01,1.712e-01,1.125e-01,8.758e-02;
        5.426e-01,4.892e-01,4.158e-01,3.530e-01,2.259e-01,1.496e-01,1.162e-01;
        6.430e-01,5.838e-01,5.014e-01,4.298e-01,2.809e-01,1.882e-01,1.462e-01;
        7.350e-01,6.713e-01,5.818e-01,5.031e-01,3.356e-01,2.276e-01,1.774e-01];
end

%% ==================== PLOTTING HELPER ====================
function dynamicDateTicks(ax, mode)
    % dynamicDateTicks Adjusts date ticks for better readability on time series plots.
    % AX: Handle of the axes object.
    % MODE: Optional 'linked' argument to link axes if multiple plots use this.
    if nargin < 2, mode = ''; end
    try
        xtickformat(ax, 'dd-MMM-yyyy HH:mm');    % o el formato que necesites
        % Después de ajustar xticks/formato, asegúrate de no cambiar los límites
        ax.XLim = ax.XLim;

        drawnow; % Update the plot to get current tick labels
        
        tickLabels = get(ax, 'XTickLabel');
        if isempty(tickLabels) || ~iscell(tickLabels)
             if ischar(tickLabels) % Sometimes it's a char array
                  tickLabels = cellstr(tickLabels);
             else
                  % Cannot determine labels, maybe no data plotted yet
                  return;
             end
        end
        
        numTicks = length(tickLabels);
        if numTicks < 2, return; end % Need at least two ticks

        % Estimate label density (very rough)
        axesWidth = ax.Position(3); % Width in normalized units
        avgLabelWidth = 0.05; % Guess average label width in normalized units
        maxLabels = floor(axesWidth / avgLabelWidth);

        if numTicks > maxLabels * 1.5 % If significantly overcrowded
             tickAngle = 45;
        else
             tickAngle = 0; % Horizontal if not too crowded
        end
        
        xtickangle(ax, tickAngle);

        % Link axes if requested (useful if called on multiple subplots)
        if strcmpi(mode, 'linked')
             dynamicDateTicks(findall(gcf,'type','axes'),'nolink'); % Apply to all axes
             linkaxes(findall(gcf,'type','axes'),'x'); % Then link them
        end

    catch ME
        warning(ME.identifier,'dynamicDateTicks failed: %s', ME.message);
    end
end

%% ==================== PROGRESS BAR HELPER ====================
% Simple command line progress bar
function pb = CmdLineProgressBar(title)
    fprintf('%s\n', title);
    fprintf('[%s]', repmat(' ', 1, 50)); % Empty bar
    fprintf(' %3d%%', 0); % Percentage
    last_len = 0;
    bar_len = 50;

    pb.print = @(current, total) update_progress(current, total);

    function update_progress(current, total)
        if total == 0, percent = 0; 
        else 
            percent = floor(100 * current / total); 
        end
        filled_len = floor(bar_len * current / max(total,1));
        bar_str = repmat('=', 1, filled_len);
        space_str = repmat(' ', 1, bar_len - filled_len);
        % Clear previous line using backspaces
        fprintf(repmat('\b', 1, last_len));
        % Print new progress
        status_line = sprintf('[%s%s] %3d%% (%d/%d)', bar_str, space_str, percent, current, total);
        fprintf('%s', status_line);
        last_len = length(status_line); % Store length for next clear
         if current == total
             fprintf('\n'); % New line when finished
         end
    end
end