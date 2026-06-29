WITH study_runs AS (
    SELECT
        r.id AS run_id,
        r.code AS run_code,
        r.instrument_id,
        COALESCE(inst.name, r.instrument_id::varchar) AS instrument_name,
        s.code AS study_code
    FROM experiment_run r
    INNER JOIN experiment_study s ON r.study_id = s.id
    LEFT  JOIN instrumentation_instrument inst ON inst.id = r.instrument_id
    WHERE s.code = '{{study_code}}'
),
run_snapshot AS (
    SELECT
        snap.run_start_time,                  
        sr.run_code,            
        sr.study_code,
        sr.run_id,
        sr.instrument_id,
        sr.instrument_name
    FROM study_runs sr
    LEFT JOIN experiment_runsnapshot snap ON sr.run_id = snap.run_id
),
calculated_metrics AS (
    SELECT
        rs.run_code                                                    AS sample_name,
        COALESCE(rs.run_start_time, res.created_at)                   AS date_of_measurement,
        rs.study_code                                                  AS master_file_of_study,
        rs.run_id,
        rs.instrument_id,
        rs.instrument_name,
        ind.code                                                       AS assay_base_name,
        sub.code                                                       AS assay_type,
        res.id                                                         AS runresult_id,
        res.calculated_value                                           AS raw_device_value,
        res.actual_value                                               AS raw_reference_value,
        (res.calculated_value - res.actual_value)                     AS computed_difference,
        ((res.calculated_value - res.actual_value)
            / NULLIF(res.actual_value, 0))                            AS computed_relative_error,
        COALESCE(wm.name, wm.code, 'Unknown')                        AS well,
        wm.id                                                          AS well_master_id
    FROM run_snapshot rs
    INNER JOIN experiment_runresult res       ON rs.run_id = res.run_id
    INNER JOIN experiment_indice ind          ON ind.id = res.indice_id
    INNER JOIN instrumentation_subsystem sub  ON sub.id = res.subsystem_id
    LEFT  JOIN inventory_wellmaster wm        ON wm.id = res.well_master_id
),
medians AS (
    SELECT
        assay_base_name,
        sample_name,
        DATE_TRUNC('day', date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY raw_device_value) AS median_value
    FROM calculated_metrics
    WHERE raw_device_value IS NOT NULL
    GROUP BY assay_base_name, sample_name, DATE_TRUNC('day', date_of_measurement)::date
),
mad_values AS (
    SELECT
        c.assay_base_name,
        c.sample_name,
        DATE_TRUNC('day', c.date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY ABS(c.raw_device_value - m.median_value)
        ) AS mad_value
    FROM calculated_metrics c
    INNER JOIN medians m 
        ON c.assay_base_name = m.assay_base_name
        AND c.sample_name = m.sample_name
        AND DATE_TRUNC('day', c.date_of_measurement)::date = m.measurement_day
    WHERE c.raw_device_value IS NOT NULL
    GROUP BY c.assay_base_name, c.sample_name, DATE_TRUNC('day', c.date_of_measurement)::date
),
outlier_flags AS (
    SELECT
        c.sample_name,
        c.date_of_measurement,
        c.master_file_of_study,
        c.assay_base_name,
        c.assay_type,
        c.raw_device_value,
        c.raw_reference_value,
        c.computed_difference,
        c.computed_relative_error,
        c.run_id,
        c.runresult_id,
        c.instrument_id,
        c.instrument_name,
        c.well,
        m.median_value,
        mv.mad_value,
        ROUND(
            (ABS(c.raw_device_value - m.median_value) / NULLIF(mv.mad_value, 0))::numeric
        , 4) AS deviation_score,
        CASE 
            WHEN mv.mad_value = 0 THEN FALSE
            WHEN (ABS(c.raw_device_value - m.median_value) / NULLIF(mv.mad_value, 0)) > 3 THEN TRUE
            ELSE FALSE
        END AS is_outlier
    FROM calculated_metrics c
    INNER JOIN medians m
        ON c.assay_base_name = m.assay_base_name
        AND c.sample_name = m.sample_name
        AND DATE_TRUNC('day', c.date_of_measurement)::date = m.measurement_day
    INNER JOIN mad_values mv
        ON c.assay_base_name = mv.assay_base_name
        AND c.sample_name = mv.sample_name
        AND DATE_TRUNC('day', c.date_of_measurement)::date = mv.measurement_day
),
base_rows AS (
    SELECT
        sample_name,
        run_id,
        date_of_measurement,
        DATE_TRUNC('day', date_of_measurement)::date  AS measurement_day,
        master_file_of_study,
        assay_base_name,
        assay_type,
        raw_device_value,
        raw_reference_value,
        computed_difference,
        computed_relative_error,
        median_value,
        mad_value,
        deviation_score,
        instrument_name,
        well,
        instrument_id,
        CASE WHEN is_outlier THEN 'Outlier' ELSE 'Normal' END AS outlier_status,
        CONCAT('https://atlantis.stable.vital.company/admin/instrumentation/instrument/', instrument_id, '/change/') AS atlantis_instrument_link,
        CONCAT('https://atlantis.stable.vital.company/admin/experiment/run/', run_id, '/change/') AS atlantis_run_link,
        NULL AS imagestat_link
    FROM outlier_flags
)

SELECT
    b.sample_name,
    b.run_id,
    b.date_of_measurement,
    b.measurement_day                                               AS "Date::filter",
    b.assay_base_name                                              AS "Assay::filter",
    b.assay_type,
    b.instrument_name,
    b.raw_device_value                                             AS values,
    b.raw_reference_value                                          AS reference_value,
    b.raw_device_value                                             AS assay_value,
    b.computed_difference                                          AS difference,
    b.computed_relative_error                                      AS relative_error,
    b.median_value,
    b.mad_value,
    b.deviation_score,
    b.outlier_status                                               AS "Outlier::filter",
    b.well,
    b.instrument_id,
    b.atlantis_instrument_link,
    b.atlantis_run_link,
    b.imagestat_link,
    CASE WHEN fg.use_all_run
        THEN 'All Runs'
        ELSE b.sample_name
    END                                                            AS "Run::filter",
    CASE WHEN fg.use_all_instrument
        THEN 'All Instruments'
        ELSE b.instrument_name
    END                                                            AS "Instrument::filter"
FROM base_rows b
CROSS JOIN (
    SELECT
        r.v AS use_all_run,
        i.v AS use_all_instrument
    FROM       (VALUES (false), (true)) r(v)
    CROSS JOIN (VALUES (false), (true)) i(v)
) fg

ORDER BY b.sample_name, b.assay_base_name;