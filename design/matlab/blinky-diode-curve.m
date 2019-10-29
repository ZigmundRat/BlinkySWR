clear;
# Read the data produced by ltspice simulating '..\ltspice\blinky-diode-curve-parametric.asc'
simresult = LTspice2Matlab('..\ltspice\blinky-diode-curve-parametric.raw');

# Indices of starts of each of the time sequence produced by ltspice.
starts = find(simresult.time_vect == simresult.time_vect(1));
# Process the ltspice simulation data, 
steps     = size(starts)(2);
vsrc_max  = zeros(steps, 1);
vload_max = zeros(steps, 1);
vadc_mean = zeros(steps, 1);
id_max    = zeros(steps, 1);
for i = 1:steps
	istart = starts(i);
	if (i == steps)
        iend = size(simresult.time_vect)(2);
	else
        iend = starts(i + 1);
	endif
	iend = iend - 1;
	time_vect = simresult.time_vect(istart:iend);
	variable_mat = simresult.variable_mat(:, istart:iend);
	times = diff(time_vect) / (time_vect(end) - time_vect(1));
	# volts
	vsrc_max(i)  = max(abs(variable_mat(1,:) - variable_mat(2, :)));
	# volts
	vload_max(i) = max(abs(variable_mat(3, :)));
	vadc  = variable_mat(4, :);
	# volts, averaged over the time samples
	vadc_mean(i) = sum((vadc(1:end-1)+vadc(2:end)) .* times) / 2;
	# mAmps
	id_max(i) = max(abs(variable_mat(5, :))) * 1000;
end

save "blinky-diode-curve.mat" vload_max vload_max vadc_mean id_max

# Interpolate the load voltage 'vload_max' with a line crossing [0, 0]. The splinefit function fits in a least squares sense.
# Robust fitting is used to eliminate outliers.
load_slope = splinefit(0:1:size(vload_max)(1)-1, vload_max', [0 size(vload_max)(1)-1], "order", 1, "beta", 0.9, "constraints", struct ("xc", [0], "yc", [0])).coefs(1);
# Interpolate 'vload_max' described by 'load_slope'.
vload = (0:1:size(vsrc_max)(1)-1)' * load_slope;
# Relative approximation error.
plot((vload - vload_max) ./ vload)
# Absolute approximation error.
plot(vload - vload_max)

# Correction of the diode drop with a 150kOhm / 10kOhm resistive divider.
vadc_corr = vload * 10 / (150+10) - vadc_mean;
plot(vadc_mean, vadc_corr)

# ADC reference.
adc_vmax = 1.1;
# Size of the low resolution table, capturing the rest of the diode curve.
table_size = 32;
corr_step_x = adc_vmax / table_size;
# Size of the high resolution table, capturing the diode curve knee.
table_size2 = 16;
corr_step_x2 = corr_step_x / 16;
# Samples of the correction table, to be fitted with a linear interpolation curve.
corr_samples = [0:corr_step_x2:corr_step_x-corr_step_x2, corr_step_x:corr_step_x:adc_vmax];

# Fit the polyline to the rough table with a fine table knee over the ADC interval <0, 1.1).
vadc_mean_trimmed = [vadc_mean(1:find(vadc_mean >= 1.1)(1)-1); 1.1];
vadc_corr_trimmed = [vadc_corr(1:find(vadc_mean >= 1.1)(1)-1); interp1(vadc_mean, vadc_corr, 1.1)];
vadc_corr_poly1 = splinefit(vadc_mean_trimmed, vadc_corr_trimmed, corr_samples, "order", 1);
corr_firmware_knee = vadc_corr_poly1.coefs(1:table_size2,2);
corr_firmware_rough = [ vadc_corr_poly1.coefs(table_size2+1:end,2); vadc_corr_poly1.coefs(end, 2) + vadc_corr_poly1.coefs(end, 1) * corr_step_x ];

# Visualize interpolation errors.
err_samples = 0:adc_vmax/1024:adc_vmax;
interp_error = interp1(vadc_mean, vadc_corr, err_samples) - ppval(vadc_corr_poly1, err_samples);
plot(corr_samples(1:end-1), vadc_corr_poly1.coefs(:,2), 'g+', vadc_mean, vadc_corr, 'b', err_samples, interp_error, 'r');

# Scaling to 13 + 4 = 17 bits of resolution.
# This is 4 bits more than the 8 summed samples of the ADC data.
bits = 8 * 1024 * 16;
corr_firmware_rough_scaled = round((bits / 1.1) * corr_firmware_rough);

% Writing corr_firmware_rough_scaled into Intel HEX file to be stored into EEPROM of the AtTiny13A. 
fname = "eeprom.hex";
delete(fname);
fileID = fopen(fname, 'w');
for (line_idx = 0:3)
	words = corr_firmware_rough_scaled(line_idx * 8 + 1 : (line_idx + 1) * 8)';
	line = [ 16, 0, line_idx * 16, 0, [ mod(words, 256); floor(words / 256); ](:)' ];
	checksum = mod(256 - mod(sum(line), 256), 256);
	line = [ line, checksum ];
	fprintf(fileID, ":%s\n", strcat(dec2hex(line,2)'(:)'));
end
fprintf(fileID, ":00000001FF\n");
fclose(fileID);

% Writing corr_firmware_fine_scaled into a C file to be included into the firmware source.
corr_firmware_knee_scaled = round((bits / 1.1) * corr_firmware_knee);
corr_firmware_knee_scaled_hexcstr = strcat("0x", dec2hex(corr_firmware_knee_scaled, 4), ", ")'(:)'(1:end-1)
fname = "table_fine.inc";
delete(fname);
fileID = fopen(fname, 'w');
fprintf(fileID, "%s\n", corr_firmware_fine_scaled_hexcstr);
fclose(fileID);
