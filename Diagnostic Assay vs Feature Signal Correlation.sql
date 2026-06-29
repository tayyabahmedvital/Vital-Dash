WITH sample_details AS (
    SELECT 
        m.run_id, m.run_code, m.study_code,
        smpl.id AS sample_id,
        grp.code AS sample_group_code,
        COALESCE(grp.name, CONCAT('Run Lot: ', m.run_code)) AS sample_group_name
    FROM (
        SELECT tr.*, rcfg.sample_id 
        FROM (
            SELECT 
                r.id AS run_id, 
                r.code AS run_code, 
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
raw_measurements AS (
    SELECT
        sd.sample_group_name,
        ind.code                            AS assay_name,
        sub.code                            AS subsystem,
        inst.name                           AS instrument_name,
        res.actual_value                    AS vital_value,
        res.calculated_value                AS measured_value,
        res.created_at                      AS date_of_measurement,
        ROUND(CORR(res.calculated_value, res.actual_value)
            OVER(PARTITION BY ind.code)::numeric, 4) AS pearson_r,
        ROUND(REGR_SLOPE(res.calculated_value, res.actual_value)
            OVER(PARTITION BY ind.code)::numeric, 4) AS regression_slope,
        ROUND(REGR_INTERCEPT(res.calculated_value, res.actual_value)
            OVER(PARTITION BY ind.code)::numeric, 4) AS regression_intercept
    FROM
        sample_details sd
    INNER JOIN
        experiment_runresult res ON sd.run_id = res.run_id
    INNER JOIN
        experiment_indice ind ON res.indice_id = ind.id
    LEFT JOIN
        instrumentation_subsystem sub ON res.subsystem_id = sub.id
    LEFT JOIN
        experiment_run r ON sd.run_id = r.id
    LEFT JOIN
        instrumentation_instrument inst ON inst.id = r.instrument_id
    WHERE
        res.calculated_value IS NOT NULL
        AND res.actual_value IS NOT NULL
        AND res.calculated_value < 10000
        AND res.actual_value < 10000
        AND res.calculated_value >= 0
)
SELECT
    sample_group_name                                           AS sample,
    assay_name,
    subsystem,
    instrument_name,
    vital_value                                                 AS reference_value,
    measured_value                                              AS calculated_value,
    ROUND((regression_slope * vital_value
        + regression_intercept)::numeric, 4)                   AS correlation_line,
    pearson_r,
    regression_slope,
    regression_intercept,
    DATE_TRUNC('day', date_of_measurement)::date               AS "Date::filter",
    CONCAT(subsystem, ': ', assay_name)                        AS "Assay::filter",
    instrument_name                                             AS "Instrument::filter"
FROM raw_measurements
ORDER BY assay_name, vital_value;