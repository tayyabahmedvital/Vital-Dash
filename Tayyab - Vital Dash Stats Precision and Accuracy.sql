-- ============================================================
-- SCATTER QUERY — shared by CV Scatter + Bias Scatter widgets
-- Standardized MAD: assay + sample_group_name + day
-- Phase 1: well, instrument_id, run_id, atlantis_run_link
-- Outlier split: normal_point / outlier_point for visual encoding
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
raw_assay_metrics AS (
    SELECT 
        sd.study_code,
        sd.run_id,
        sd.run_code,
        sd.instrument_id,
        sd.sample_group_name,
        sd.sample_id,
        sub.code AS structure_name,
        ind.code AS assay_name,
        res.id AS runresult_id,
        res.calculated_value AS measured_value,
        res.actual_value AS reference_value,
        res.created_at AS date_of_measurement,
        -- Well identifier
        COALESCE(wm.name, wm.code, 'Unknown') AS well,
        STDDEV(res.calculated_value) OVER(PARTITION BY sd.sample_group_name, ind.code) AS lot_sd,
        AVG(res.calculated_value) OVER(PARTITION BY sd.sample_group_name, ind.code) AS lot_mean
    FROM 
        sample_details sd
    INNER JOIN experiment_runresult res ON sd.run_id = res.run_id
    INNER JOIN experiment_indice ind ON res.indice_id = ind.id
    INNER JOIN instrumentation_subsystem sub ON res.subsystem_id = sub.id
    LEFT JOIN inventory_wellmaster wm ON wm.id = res.well_master_id
),
cleaned_measurements AS (
    SELECT 
        study_code,
        run_id,
        run_code,
        instrument_id,
        sample_group_name,
        sample_id,
        structure_name,
        assay_name,
        well,
        measured_value,
        reference_value,
        date_of_measurement,
        lot_sd,
        lot_mean,
        (measured_value - reference_value) AS bias,
        ((measured_value - reference_value) / NULLIF(reference_value, 0) * 100) AS relative_error_pct,
        ROUND(COALESCE((lot_sd / NULLIF(lot_mean, 0)) * 100, 0)::numeric, 4) AS cv_pct
    FROM raw_assay_metrics
    WHERE 
        measured_value IS NOT NULL 
        AND reference_value IS NOT NULL  
        AND measured_value < 10000
        AND reference_value < 10000
        AND measured_value >= 0 
),
-- STANDARD MAD PARTITION: assay + sample_group_name + day
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
flagged AS (
    SELECT
        c.*,
        om.median_value,
        mad.mad_value,
        ROUND(
            (ABS(c.measured_value - om.median_value) / NULLIF(mad.mad_value, 0))::numeric
        , 4) AS deviation_score,
        -- METHOD 1: MAD-based (catches anomalous individual measurements)
        CASE
            WHEN mad.mad_value = 0 THEN FALSE
            WHEN (ABS(c.measured_value - om.median_value) / NULLIF(mad.mad_value, 0)) > 3 THEN TRUE
            ELSE FALSE
        END AS is_mad_outlier,
        -- METHOD 2: CV threshold >10% = clinically unacceptable precision
        CASE
            WHEN ROUND(COALESCE((c.lot_sd / NULLIF(c.lot_mean, 0)) * 100, 0)::numeric, 4) > 10 THEN TRUE
            ELSE FALSE
        END AS is_cv_outlier
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

SELECT
    -- Core identifiers
    sample_group_name                                               AS sample,
    run_code,
    CONCAT(structure_name, ': ', assay_name)                       AS structured_assay,

    -- Measurements
    reference_value,
    measured_value,
    bias,
    relative_error_pct,
    cv_pct,

    -- Outlier metrics
    deviation_score,
    median_value,
    mad_value,

    -- Dual outlier flags (scientists can see WHY it was flagged)
    CASE WHEN is_mad_outlier THEN 'Yes' ELSE 'No' END              AS flagged_by_mad,
    CASE WHEN is_cv_outlier  THEN 'Yes' ELSE 'No' END              AS flagged_by_cv,

    -- Combined outlier status: either method triggers flag
    CASE WHEN (is_mad_outlier OR is_cv_outlier) THEN 'Outlier' ELSE 'Normal' END AS outlier_status,

    -- Outlier visual split (X marker vs circle in Redash)
    -- CV scatter: use cv_pct as Y axis
    CASE WHEN (is_mad_outlier OR is_cv_outlier) THEN cv_pct  ELSE NULL END AS cv_outlier_point,
    CASE WHEN NOT (is_mad_outlier OR is_cv_outlier) THEN cv_pct ELSE NULL END AS cv_normal_point,
    -- Bland-Altman scatter: Y = relative error % (measured - ref) / ref * 100
    CASE WHEN (is_mad_outlier OR is_cv_outlier) THEN relative_error_pct ELSE NULL END AS bias_outlier_point,
    CASE WHEN NOT (is_mad_outlier OR is_cv_outlier) THEN relative_error_pct ELSE NULL END AS bias_normal_point,

    -- Hover info (Phase 1)
    well,
    instrument_id,
    date_of_measurement,
    CONCAT('https://atlantis.stable.vital.company/admin/experiment/run/', run_id, '/change/') AS atlantis_run_link,
    CONCAT('https://atlantis.stable.vital.company/admin/instrumentation/instrument/', instrument_id, '/change/') AS atlantis_instrument_link,

    -- Filters
    DATE_TRUNC('day', date_of_measurement)::date                   AS "Date::filter",
    CONCAT(structure_name, ': ', assay_name)                       AS "Assay::filter",
    CASE WHEN (is_mad_outlier OR is_cv_outlier) THEN 'Outlier' ELSE 'Normal' END AS "Outlier::filter"

FROM flagged
ORDER BY sample_group_name, assay_name, date_of_measurement;