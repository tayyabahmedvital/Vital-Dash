-- ============================================================
-- TIMECOURSE QUERY — Stats Timecourse Plot
-- Dual outlier detection: MAD + CV >10%
-- Compressed X axis: fixed 1h gap between runs (not actual elapsed time)
-- NULL injection preserved for line breaks between runs
-- ============================================================

WITH sample_details AS (
    SELECT 
        m.run_id, m.run_code, m.study_code,
        m.instrument_id,
        smpl.id AS sample_id,
        grp.code AS sample_group_code,
        COALESCE(grp.name, CONCAT('Run Lot: ', m.run_code)) AS sample_group_name
    FROM (
        SELECT tr.*, rcfg.sample_id 
        FROM (
            SELECT 
                r.id AS run_id, 
                r.code AS run_code,
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
raw_data AS (
    SELECT 
        sd.run_id,
        sd.run_code,
        sd.instrument_id,
        sd.sample_id,
        sd.sample_group_name,
        ind.code AS assay_name,
        res.calculated_value AS measured_value,
        res.actual_value AS reference_value,
        res.created_at AS date_of_measurement,
        COALESCE(wm.name, wm.code, 'Unknown') AS well,
        -- Relative position within a run (0 to N-1) instead of actual hours
        ROW_NUMBER() OVER(PARTITION BY sd.sample_id, ind.code ORDER BY res.created_at) - 1 AS internal_seq
    FROM sample_details sd
    INNER JOIN experiment_runresult res ON sd.run_id = res.run_id
    INNER JOIN experiment_indice ind ON res.indice_id = ind.id
    LEFT JOIN inventory_wellmaster wm ON wm.id = res.well_master_id
    WHERE res.calculated_value IS NOT NULL
),
-- STANDARD MAD PARTITION: assay + sample_group_name + day
outlier_medians AS (
    SELECT
        assay_name, sample_group_name,
        DATE_TRUNC('day', date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY measured_value) AS median_value
    FROM raw_data
    GROUP BY assay_name, sample_group_name, DATE_TRUNC('day', date_of_measurement)::date
),
outlier_mad AS (
    SELECT
        r.assay_name, r.sample_group_name,
        DATE_TRUNC('day', r.date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY ABS(r.measured_value - om.median_value)
        ) AS mad_value
    FROM raw_data r
    INNER JOIN outlier_medians om
        ON r.assay_name = om.assay_name
        AND r.sample_group_name = om.sample_group_name
        AND DATE_TRUNC('day', r.date_of_measurement)::date = om.measurement_day
    GROUP BY r.assay_name, r.sample_group_name, DATE_TRUNC('day', r.date_of_measurement)::date
),
ordered_samples AS (
    SELECT 
        sample_id, assay_name, sample_group_name,
        -- Total points in this run (for compressed spacing)
        MAX(internal_seq) AS total_points,
        ROW_NUMBER() OVER (ORDER BY MIN(date_of_measurement), assay_name, sample_group_name) AS sample_sequence
    FROM raw_data
    GROUP BY sample_id, assay_name, sample_group_name
),
timeline_shifts AS (
    SELECT 
        sample_id, assay_name, sample_group_name,
        -- Each run takes (total_points + 2) units, with 2 unit gap between runs
        COALESCE(
            SUM(total_points + 3) OVER(
                ORDER BY sample_sequence 
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ), 
            0
        ) AS timeline_shift
    FROM ordered_samples
),
final_points AS (    
    SELECT 
        (ts.timeline_shift + r.internal_seq)::float    AS continuous_timeline,
        r.run_id,
        r.run_code,
        r.instrument_id,
        r.assay_name,
        r.sample_group_name,
        r.date_of_measurement,
        r.well,
        r.measured_value                               AS measured_points,
        AVG(r.measured_value) OVER(PARTITION BY r.sample_id, r.assay_name, r.sample_group_name) AS average_value_line,
        AVG(r.reference_value) OVER(PARTITION BY r.sample_id, r.assay_name, r.sample_group_name) AS reference_value_line,
        om.median_value,
        mad.mad_value,
        ROUND((ABS(r.measured_value - om.median_value) / NULLIF(mad.mad_value, 0))::numeric, 4) AS deviation_score,
        -- METHOD 1: MAD outlier
        CASE
            WHEN mad.mad_value = 0 THEN FALSE
            WHEN (ABS(r.measured_value - om.median_value) / NULLIF(mad.mad_value, 0)) > 3 THEN TRUE
            ELSE FALSE
        END AS is_mad_outlier,
        -- METHOD 2: CV threshold >10%
        CASE
            WHEN (STDDEV(r.measured_value) OVER(PARTITION BY r.assay_name, r.sample_group_name)
                / NULLIF(AVG(r.measured_value) OVER(PARTITION BY r.assay_name, r.sample_group_name), 0)) * 100 > 10 THEN TRUE
            ELSE FALSE
        END AS is_cv_outlier,
        os.total_points,
        ts.timeline_shift
    FROM raw_data r
    INNER JOIN ordered_samples os
        ON r.sample_id = os.sample_id
        AND r.assay_name = os.assay_name
        AND r.sample_group_name = os.sample_group_name
    INNER JOIN timeline_shifts ts 
        ON r.sample_id = ts.sample_id
        AND r.assay_name = ts.assay_name
        AND r.sample_group_name = ts.sample_group_name
    LEFT JOIN outlier_medians om
        ON r.assay_name = om.assay_name
        AND r.sample_group_name = om.sample_group_name
        AND DATE_TRUNC('day', r.date_of_measurement)::date = om.measurement_day
    LEFT JOIN outlier_mad mad
        ON r.assay_name = mad.assay_name
        AND r.sample_group_name = mad.sample_group_name
        AND DATE_TRUNC('day', r.date_of_measurement)::date = mad.measurement_day
)

-- MAIN DATA POINTS
SELECT 
    continuous_timeline,
    measured_points,
    average_value_line,
    reference_value_line,
    -- Outlier visual split
    CASE WHEN (is_mad_outlier OR is_cv_outlier) THEN measured_points ELSE NULL END AS measured_outlier_point,
    CASE WHEN NOT (is_mad_outlier OR is_cv_outlier) THEN measured_points ELSE NULL END AS measured_normal_point,
    -- Hover info
    run_code,
    well,
    instrument_id,
    date_of_measurement,
    deviation_score,
    sample_group_name,
    CASE WHEN (is_mad_outlier OR is_cv_outlier) THEN 'Outlier' ELSE 'Normal' END AS outlier_status,
    CONCAT('https://atlantis.stable.vital.company/admin/experiment/run/', run_id, '/change/') AS atlantis_run_link,
    -- Filters
    assay_name                                                      AS "Assay::filter",
    DATE_TRUNC('day', date_of_measurement)::date                   AS "Date::filter",
    CASE WHEN (is_mad_outlier OR is_cv_outlier) THEN 'Outlier' ELSE 'Normal' END AS "Outlier::filter"

FROM final_points

UNION ALL

-- NULL INJECTION — 2 unit gap breaks line connections between runs
SELECT 
    (ts.timeline_shift + os.total_points + 1)::float AS continuous_timeline,
    NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL

FROM ordered_samples os
INNER JOIN timeline_shifts ts 
    ON os.sample_id = ts.sample_id
    AND os.assay_name = ts.assay_name
    AND os.sample_group_name = ts.sample_group_name

ORDER BY continuous_timeline ASC;