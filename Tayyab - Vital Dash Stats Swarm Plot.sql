WITH sample_details AS (
    SELECT 
        m.run_id, m.run_code, m.study_code,
        smpl.id AS sample_id,
        grp.code AS sample_group_code,
        grp.name AS sample_group_name
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
raw_assay_metrics AS (
    SELECT 
        sd.study_code,
        sd.sample_group_name,
        sd.sample_id,
        ind.code AS assay_name,
        res.calculated_value AS measured_value,
        res.actual_value AS reference_value,
        res.created_at AS date_of_measurement
    FROM 
        sample_details sd
    INNER JOIN 
        experiment_runresult res ON sd.run_id = res.run_id
    INNER JOIN 
        experiment_indice ind ON res.indice_id = ind.id
),
cleaned_measurements AS (
    SELECT 
        study_code,
        sample_group_name,
        sample_id,
        assay_name,
        measured_value,
        reference_value,
        date_of_measurement,
        (measured_value - reference_value) AS absolute_bias,
        ((measured_value - reference_value) / NULLIF(reference_value, 0)) AS relative_error
    FROM 
        raw_assay_metrics
    WHERE 
        measured_value IS NOT NULL 
        AND reference_value IS NOT NULL  
        AND measured_value < 10000
        AND reference_value < 10000
        AND measured_value > 0
),

-- STEP: Median per assay per sample group per day
outlier_medians AS (
    SELECT
        assay_name,
        sample_group_name,
        DATE_TRUNC('day', date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY measured_value) AS median_value
    FROM cleaned_measurements
    GROUP BY
        assay_name,
        sample_group_name,
        DATE_TRUNC('day', date_of_measurement)::date
),

-- STEP: MAD per assay per sample group per day
outlier_mad AS (
    SELECT
        c.assay_name,
        c.sample_group_name,
        DATE_TRUNC('day', c.date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY ABS(c.measured_value - om.median_value)
        ) AS mad_value
    FROM cleaned_measurements c
    INNER JOIN outlier_medians om
        ON c.assay_name = om.assay_name
        AND c.sample_group_name = om.sample_group_name
        AND DATE_TRUNC('day', c.date_of_measurement)::date = om.measurement_day
    GROUP BY
        c.assay_name,
        c.sample_group_name,
        DATE_TRUNC('day', c.date_of_measurement)::date
),

-- STEP: Join outlier flags back to individual measurement rows
flagged_measurements AS (
    SELECT
        c.study_code,
        c.sample_group_name,
        c.sample_id,
        c.assay_name,
        c.measured_value,
        c.reference_value,
        c.date_of_measurement,
        c.relative_error,
        om.median_value,
        mad.mad_value,
        ROUND(
            (ABS(c.measured_value - om.median_value) / NULLIF(mad.mad_value, 0))::numeric
        , 4) AS deviation_score,
        CASE
            WHEN mad.mad_value = 0 THEN 'Normal'
            WHEN (ABS(c.measured_value - om.median_value) / NULLIF(mad.mad_value, 0)) > 3 THEN 'Outlier'
            ELSE 'Normal'
        END AS outlier_status
    FROM cleaned_measurements c
    LEFT JOIN outlier_medians om
        ON c.assay_name = om.assay_name
        AND c.sample_group_name = om.sample_group_name
        AND DATE_TRUNC('day', c.date_of_measurement)::date = om.measurement_day
    LEFT JOIN outlier_mad mad
        ON c.assay_name = mad.assay_name
        AND c.sample_group_name = mad.sample_group_name
        AND DATE_TRUNC('day', c.date_of_measurement)::date = mad.measurement_day
)

-- SWARM PLOT DATA ENGINE
SELECT 
    assay_name AS "Assay::filter",
    DATE_TRUNC('day', date_of_measurement)::date AS "Date::filter",
    outlier_status AS "Outlier::filter",
    DENSE_RANK() OVER (ORDER BY sample_group_name) * 2 + (RANDOM() * 0.8 - 0.4) AS "jittered_x",
    relative_error AS "relative_error",
    deviation_score,
    sample_group_name AS "sample"
FROM 
    flagged_measurements
ORDER BY 
    sample_group_name ASC;