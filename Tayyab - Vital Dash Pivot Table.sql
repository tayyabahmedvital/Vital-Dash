-- ============================================================
-- PIVOT TABLE — Stats Pivot (Master Pivot)
-- Standardized MAD: assay + sample_group_name + day
-- Outlier now flagged at INDIVIDUAL measurement level before aggregation
-- Phase 1: run_id, atlantis_run_link added to electrolyte rows
-- Electrolyte signals preserved
-- ============================================================

WITH sample_details AS (
    SELECT 
        m.run_id, m.run_code, m.study_code,
        m.instrument_id,
        m.run_status, m.run_start_time, 
        m.run_end_time, m.run_duration, m.source_env,
        smpl.id AS sample_id,
        grp.code AS sample_group_code,
        COALESCE(grp.name, CONCAT('Run Lot: ', m.run_code)) AS sample_group_name
    FROM (
        SELECT tr.*, rcfg.sample_id 
        FROM (
            SELECT 
                r.id AS run_id, 
                r.code AS run_code, 
                r.status AS run_status,
                r.run_start_time,
                r.run_end_time,
                r.run_duration,
                r.source_env,
                r.instrument_id,
                s.code AS study_code
            FROM experiment_run r
            INNER JOIN experiment_study s ON r.study_id = s.id
            WHERE s.code = '{{study_code}}'
        ) tr 
        LEFT JOIN experiment_runconfig rcfg ON tr.run_id = rcfg.run_id
    ) m 
    LEFT JOIN experiment_sample smpl ON m.sample_id = smpl.id
    LEFT JOIN experiment_samplegroup grp ON smpl.sample_group_id = grp.id
),
raw_assay_metrics AS (
    SELECT 
        sd.study_code,
        sd.run_id,
        sd.run_code,
        sd.run_status,
        sd.run_start_time,
        sd.run_end_time,
        sd.run_duration,
        sd.source_env,
        sd.instrument_id,
        sd.sample_group_name,
        sd.sample_id,
        COALESCE(sub.code, 'unknown') AS subsystem,
        ind.code AS assay_name,
        res.calculated_value AS measured_value,
        res.actual_value AS reference_value,
        res.created_at AS date_of_measurement
    FROM 
        sample_details sd
    INNER JOIN experiment_runresult res ON sd.run_id = res.run_id
    INNER JOIN experiment_indice ind ON res.indice_id = ind.id
    LEFT JOIN instrumentation_subsystem sub ON res.subsystem_id = sub.id
),
cleaned_measurements AS (
    SELECT 
        study_code,
        run_id,
        run_code,
        run_status,
        run_start_time,
        run_end_time,
        run_duration,
        source_env,
        instrument_id,
        sample_group_name,
        sample_id,
        subsystem,
        assay_name,
        measured_value,
        reference_value,
        date_of_measurement,
        (measured_value - reference_value) AS raw_bias,
        ROUND(((measured_value - reference_value) 
            / NULLIF(reference_value, 0) * 100)::numeric, 4) AS relative_error_pct,
        STDDEV(measured_value) OVER(PARTITION BY sample_group_name, assay_name) AS sample_wide_sd,
        AVG(measured_value) OVER(PARTITION BY sample_group_name, assay_name) AS sample_wide_mean
    FROM raw_assay_metrics
    WHERE 
        measured_value IS NOT NULL 
        AND reference_value IS NOT NULL  
        AND measured_value < 10000
        AND reference_value < 10000
        AND measured_value >= 0
        AND sample_group_name NOT LIKE 'Run Lot:%'
        AND sample_group_name IS NOT NULL
),
run_medians AS (
    SELECT 
        run_code, assay_name,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY measured_value) AS run_median_value
    FROM cleaned_measurements
    GROUP BY run_code, assay_name
),
-- STANDARD MAD PARTITION: assay + sample_group_name + day
outlier_medians AS (
    SELECT
        assay_name, sample_group_name,
        DATE_TRUNC('day', date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY measured_value) AS median_value
    FROM cleaned_measurements
    GROUP BY assay_name, sample_group_name, DATE_TRUNC('day', date_of_measurement)::date
),
outlier_mad AS (
    SELECT
        c.assay_name, c.sample_group_name,
        DATE_TRUNC('day', c.date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY ABS(c.measured_value - om.median_value)
        ) AS mad_value
    FROM cleaned_measurements c
    INNER JOIN outlier_medians om
        ON c.assay_name = om.assay_name
        AND c.sample_group_name = om.sample_group_name
        AND DATE_TRUNC('day', c.date_of_measurement)::date = om.measurement_day
    GROUP BY c.assay_name, c.sample_group_name, DATE_TRUNC('day', c.date_of_measurement)::date
),
-- Flag outliers at INDIVIDUAL measurement level before aggregation
individual_flags AS (
    SELECT
        c.*,
        om.median_value,
        mv.mad_value,
        ROUND(
            (ABS(c.measured_value - om.median_value) / NULLIF(mv.mad_value, 0))::numeric
        , 4) AS deviation_score,
        CASE 
            WHEN mv.mad_value = 0 THEN FALSE
            WHEN (ABS(c.measured_value - om.median_value) / NULLIF(mv.mad_value, 0)) > 3 THEN TRUE
            ELSE FALSE
        END AS is_mad_outlier,
        -- CV threshold: >10% clinically unacceptable
        CASE
            WHEN (MAX(c.sample_wide_sd) OVER(PARTITION BY c.sample_group_name, c.assay_name)
                  / NULLIF(MAX(c.sample_wide_mean) OVER(PARTITION BY c.sample_group_name, c.assay_name), 0)) * 100 > 10 THEN TRUE
            ELSE FALSE
        END AS is_cv_outlier
    FROM cleaned_measurements c
    LEFT JOIN outlier_medians om
        ON c.assay_name = om.assay_name
        AND c.sample_group_name = om.sample_group_name
        AND DATE_TRUNC('day', c.date_of_measurement)::date = om.measurement_day
    LEFT JOIN outlier_mad mv
        ON c.assay_name = mv.assay_name
        AND c.sample_group_name = mv.sample_group_name
        AND DATE_TRUNC('day', c.date_of_measurement)::date = mv.measurement_day
),
electrolyte_signals AS (
    SELECT
        sd.study_code, sd.run_code, sd.sample_group_name,
        TO_CHAR(MIN(ef.created_at), 'YYYY-MM-DD HH24:MI:SS') AS timestamp,
        AVG((ef.input_cols->>'na-signal')::numeric)      AS na_signal,
        AVG((ef.input_cols->>'k-signal')::numeric)       AS k_signal,
        AVG((ef.input_cols->>'protonation')::numeric)    AS protonation,
        AVG((ef.output_cols->>'NA')::numeric)            AS na_output,
        AVG((ef.output_cols->>'POTASSIUM')::numeric)     AS potassium_output
    FROM sample_details sd
    INNER JOIN experiment_feature ef ON sd.run_id = ef.run_id
    WHERE
        sd.sample_group_name NOT LIKE 'Run Lot:%'
        AND sd.sample_group_name IS NOT NULL
        AND (
            ef.input_cols->>'na-signal' IS NOT NULL
            OR ef.input_cols->>'k-signal' IS NOT NULL
            OR ef.input_cols->>'protonation' IS NOT NULL
        )
    GROUP BY sd.study_code, sd.run_code, sd.sample_group_name
),
calculated_summary AS (
    SELECT 
        c.study_code, c.run_code, c.run_status,
        TO_CHAR(c.run_start_time, 'YYYY-MM-DD HH24:MI:SS')     AS run_start_time,
        TO_CHAR(c.run_end_time, 'YYYY-MM-DD HH24:MI:SS')       AS run_end_time,
        c.run_duration::text                                     AS run_duration,
        c.source_env,
        TO_CHAR(c.date_of_measurement, 'YYYY-MM-DD HH24:MI:SS') AS timestamp,
        DATE_TRUNC('day', c.date_of_measurement)::date           AS measurement_day,
        c.subsystem,
        c.assay_name,
        c.sample_group_name,
        COUNT(*) AS total_replicates,
        -- % of individual measurements in this group that are outliers
        ROUND((SUM(CASE WHEN (c.is_mad_outlier OR c.is_cv_outlier) THEN 1 ELSE 0 END)::numeric / COUNT(*)) * 100, 1) AS outlier_pct,
        ROUND((MAX(c.sample_wide_sd) / NULLIF(MAX(c.sample_wide_mean), 0))::numeric, 4) AS overall_cv,
        ROUND(AVG(c.raw_bias)::numeric, 4)                      AS mean_directional_bias,
        ROUND(AVG(c.relative_error_pct)::numeric, 4)            AS mean_relative_error_pct,
        ROUND(AVG(ABS(c.measured_value - m.run_median_value))::numeric, 4) AS median_absolute_difference,
        ROUND(AVG(c.measured_value)::numeric, 4)                AS mean_measured_value,
        ROUND(MAX(c.sample_wide_sd)::numeric, 4)                AS stdev_measured_value,
        ROUND((ABS(AVG(c.raw_bias)) + 1.65 * COALESCE(MAX(c.sample_wide_sd), 0))::numeric, 4) AS total_analytical_error_abs,
        ROUND(((ABS(AVG(c.raw_bias)) + 1.65 * COALESCE(MAX(c.sample_wide_sd), 0)) / NULLIF(AVG(c.reference_value), 0))::numeric, 4) AS total_analytical_error_pct,
        -- Outlier status: any individual MAD or CV outlier in group = flag group
        CASE WHEN (BOOL_OR(c.is_mad_outlier) OR BOOL_OR(c.is_cv_outlier)) THEN 'Outlier' ELSE 'Normal' END AS outlier_status
    FROM individual_flags c
    INNER JOIN run_medians m ON c.run_code = m.run_code AND c.assay_name = m.assay_name
    GROUP BY 
        c.study_code, c.run_code, c.run_status,
        c.run_start_time, c.run_end_time, c.run_duration, c.source_env,
        c.date_of_measurement, c.subsystem, c.assay_name, c.sample_group_name,
        m.run_median_value
)

-- UNPIVOT STACK
SELECT study_code, run_code, run_code AS "Run::filter", run_status, run_start_time, run_end_time, run_duration, source_env, timestamp, measurement_day AS "Date::filter", subsystem, assay_name, assay_name AS "Assay::filter", sample_group_name, outlier_status AS "Outlier::filter", 'Overall CV (Precision)'        AS stat_metric_name, overall_cv                  AS stat_value FROM calculated_summary
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", run_status, run_start_time, run_end_time, run_duration, source_env, timestamp, measurement_day AS "Date::filter", subsystem, assay_name, assay_name AS "Assay::filter", sample_group_name, outlier_status AS "Outlier::filter", 'Mean Directional Bias'         AS stat_metric_name, mean_directional_bias         AS stat_value FROM calculated_summary
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", run_status, run_start_time, run_end_time, run_duration, source_env, timestamp, measurement_day AS "Date::filter", subsystem, assay_name, assay_name AS "Assay::filter", sample_group_name, outlier_status AS "Outlier::filter", 'Mean Relative Error (%)'       AS stat_metric_name, mean_relative_error_pct       AS stat_value FROM calculated_summary
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", run_status, run_start_time, run_end_time, run_duration, source_env, timestamp, measurement_day AS "Date::filter", subsystem, assay_name, assay_name AS "Assay::filter", sample_group_name, outlier_status AS "Outlier::filter", 'Median Absolute Difference'    AS stat_metric_name, median_absolute_difference    AS stat_value FROM calculated_summary
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", run_status, run_start_time, run_end_time, run_duration, source_env, timestamp, measurement_day AS "Date::filter", subsystem, assay_name, assay_name AS "Assay::filter", sample_group_name, outlier_status AS "Outlier::filter", 'Mean Measured Value'           AS stat_metric_name, mean_measured_value           AS stat_value FROM calculated_summary
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", run_status, run_start_time, run_end_time, run_duration, source_env, timestamp, measurement_day AS "Date::filter", subsystem, assay_name, assay_name AS "Assay::filter", sample_group_name, outlier_status AS "Outlier::filter", 'Total Analytical Error (Abs)'  AS stat_metric_name, total_analytical_error_abs    AS stat_value FROM calculated_summary
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", run_status, run_start_time, run_end_time, run_duration, source_env, timestamp, measurement_day AS "Date::filter", subsystem, assay_name, assay_name AS "Assay::filter", sample_group_name, outlier_status AS "Outlier::filter", 'Total Analytical Error (%)'    AS stat_metric_name, total_analytical_error_pct    AS stat_value FROM calculated_summary
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", run_status, run_start_time, run_end_time, run_duration, source_env, timestamp, measurement_day AS "Date::filter", subsystem, assay_name, assay_name AS "Assay::filter", sample_group_name, outlier_status AS "Outlier::filter", 'Total Replicates'              AS stat_metric_name, total_replicates::numeric     AS stat_value FROM calculated_summary
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", run_status, run_start_time, run_end_time, run_duration, source_env, timestamp, measurement_day AS "Date::filter", subsystem, assay_name, assay_name AS "Assay::filter", sample_group_name, outlier_status AS "Outlier::filter", 'Outlier % in Group'            AS stat_metric_name, outlier_pct                   AS stat_value FROM calculated_summary
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", NULL AS run_status, NULL AS run_start_time, NULL AS run_end_time, NULL AS run_duration, NULL AS source_env, timestamp, NULL AS "Date::filter", NULL AS subsystem, 'NA'   AS assay_name, 'NA'   AS "Assay::filter", sample_group_name, NULL AS "Outlier::filter", 'Raw Signal: na-signal'      AS stat_metric_name, ROUND(na_signal::numeric, 6)        AS stat_value FROM electrolyte_signals WHERE na_signal IS NOT NULL
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", NULL AS run_status, NULL AS run_start_time, NULL AS run_end_time, NULL AS run_duration, NULL AS source_env, timestamp, NULL AS "Date::filter", NULL AS subsystem, 'K'    AS assay_name, 'K'    AS "Assay::filter", sample_group_name, NULL AS "Outlier::filter", 'Raw Signal: k-signal'       AS stat_metric_name, ROUND(k_signal::numeric, 6)         AS stat_value FROM electrolyte_signals WHERE k_signal IS NOT NULL
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", NULL AS run_status, NULL AS run_start_time, NULL AS run_end_time, NULL AS run_duration, NULL AS source_env, timestamp, NULL AS "Date::filter", NULL AS subsystem, 'NA/K' AS assay_name, 'NA/K' AS "Assay::filter", sample_group_name, NULL AS "Outlier::filter", 'Raw Signal: protonation'    AS stat_metric_name, ROUND(protonation::numeric, 6)      AS stat_value FROM electrolyte_signals WHERE protonation IS NOT NULL
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", NULL AS run_status, NULL AS run_start_time, NULL AS run_end_time, NULL AS run_duration, NULL AS source_env, timestamp, NULL AS "Date::filter", NULL AS subsystem, 'NA'   AS assay_name, 'NA'   AS "Assay::filter", sample_group_name, NULL AS "Outlier::filter", 'Output Signal: NA'          AS stat_metric_name, ROUND(na_output::numeric, 6)        AS stat_value FROM electrolyte_signals WHERE na_output IS NOT NULL
UNION ALL
SELECT study_code, run_code, run_code AS "Run::filter", NULL AS run_status, NULL AS run_start_time, NULL AS run_end_time, NULL AS run_duration, NULL AS source_env, timestamp, NULL AS "Date::filter", NULL AS subsystem, 'K'    AS assay_name, 'K'    AS "Assay::filter", sample_group_name, NULL AS "Outlier::filter", 'Output Signal: POTASSIUM'   AS stat_metric_name, ROUND(potassium_output::numeric, 6) AS stat_value FROM electrolyte_signals WHERE potassium_output IS NOT NULL

ORDER BY study_code, run_code, timestamp, subsystem, assay_name, sample_group_name, stat_metric_name;