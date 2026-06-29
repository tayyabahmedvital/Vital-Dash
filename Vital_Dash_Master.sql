-- ============================================================
-- VITAL DASH — Master Table
-- One row per measurement across all runs in the study
-- Outlier detection: MAD (deviation score > 3) 
-- Phase 1: well, instrument, run, and Atlantis deep links
-- ============================================================

WITH study_runs AS (
    SELECT
        r.id AS run_id,
        r.code AS run_code,
        r.instrument_id,
        s.code AS study_code
    FROM experiment_run r
    INNER JOIN experiment_study s ON r.study_id = s.id
    WHERE s.code = '{{study_code}}'
),
run_snapshot AS (
    SELECT
        snap.run_start_time,                  
        sr.run_code,            
        sr.study_code,
        sr.run_id,
        sr.instrument_id
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
        inst.name                                                      AS instrument_name,
        ind.code                                                       AS assay_base_name,
        sub.code                                                       AS assay_type,
        res.id                                                         AS runresult_id,
        res.calculated_value                                           AS raw_device_value,
        res.actual_value                                               AS raw_reference_value,
        (res.calculated_value - res.actual_value)                     AS computed_difference,
        ((res.calculated_value - res.actual_value)
            / NULLIF(res.actual_value, 0))                            AS computed_relative_error,
        COALESCE(wm.name, wm.code, 'Unknown')                        AS well,
        wm.id                                                          AS well_master_id,
        COALESCE(grp.name, CONCAT('Run Lot: ', rs.run_code))         AS control_lot
    FROM run_snapshot rs
    INNER JOIN experiment_runresult res       ON rs.run_id = res.run_id
    INNER JOIN experiment_indice ind          ON ind.id = res.indice_id
    INNER JOIN instrumentation_subsystem sub  ON sub.id = res.subsystem_id
    LEFT  JOIN instrumentation_instrument inst ON inst.id = rs.instrument_id
    LEFT  JOIN inventory_wellmaster wm        ON wm.id = res.well_master_id
    LEFT  JOIN experiment_runconfig rcfg      ON rcfg.run_id = rs.run_id
    LEFT  JOIN experiment_sample smpl         ON smpl.id = rcfg.sample_id
    LEFT  JOIN experiment_samplegroup grp     ON grp.id = smpl.sample_group_id
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
        c.sample_name, c.date_of_measurement, c.master_file_of_study,
        c.assay_base_name, c.assay_type, c.raw_device_value, c.raw_reference_value,
        c.computed_difference, c.computed_relative_error,
        c.run_id, c.runresult_id, c.instrument_id, c.instrument_name,
        c.control_lot, c.well,
        m.median_value, mv.mad_value,
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
assay_groups AS (
    SELECT
        assay_base_name,
        CASE
            WHEN assay_base_name IN ('NA', 'K', 'CL', 'CA', 'MG', 'PHOS')                        THEN 'Electrolytes'
            WHEN assay_base_name IN ('ALT', 'AST', 'ALP', 'ALB', 'TBIL', 'DBIL', 'TP', 'LDH')   THEN 'Liver Function'
            WHEN assay_base_name IN ('CREA', 'BUN', 'UA')                                          THEN 'Renal Function'
            WHEN assay_base_name IN ('GLU', 'CHOL', 'TRIG')                                        THEN 'Metabolic'
            ELSE 'Other'
        END AS assay_group
    FROM (SELECT DISTINCT assay_base_name FROM outlier_flags) t
),
base_rows AS (
    SELECT
        of.sample_name,
        of.run_id,
        of.date_of_measurement,
        DATE_TRUNC('day', of.date_of_measurement)::date                AS "Date::filter",
        of.master_file_of_study,
        of.assay_base_name,
        of.assay_type,
        ag.assay_group,
        of.instrument_name,
        of.control_lot,
        of.raw_device_value                                            AS values,
        of.raw_reference_value                                         AS reference_value,
        of.raw_device_value                                            AS assay_value,
        of.computed_difference                                         AS difference,
        of.computed_relative_error                                     AS relative_error,
        of.median_value,
        of.mad_value,
        of.deviation_score,
        CASE WHEN of.is_outlier THEN 'Outlier' ELSE 'Normal' END      AS "Outlier::filter",
        of.well,
        of.instrument_id,
        CONCAT('https://atlantis.stable.vital.company/admin/instrumentation/instrument/', of.instrument_id, '/change/') AS atlantis_instrument_link,
        CONCAT('https://atlantis.stable.vital.company/admin/experiment/run/', of.run_id, '/change/') AS atlantis_run_link,
        NULL                                                           AS imagestat_link
    FROM outlier_flags of
    LEFT JOIN assay_groups ag ON ag.assay_base_name = of.assay_base_name
),
filter_expansion AS (
    SELECT
        b.sample_name, b.run_id, b.date_of_measurement, b."Date::filter",
        b.master_file_of_study, b.assay_base_name, b.assay_type,
        b.instrument_name, b.control_lot,
        b.values, b.reference_value, b.assay_value, b.difference, b.relative_error,
        b.median_value, b.mad_value, b.deviation_score, b."Outlier::filter",
        b.well, b.instrument_id, b.atlantis_instrument_link, b.atlantis_run_link, b.imagestat_link,
        CASE WHEN fg.use_all_group      THEN '0 All Groups'      ELSE b.assay_group      END AS "Assay Group::filter",
        CASE WHEN fg.use_all_assay      THEN '0 All Assays'      ELSE b.assay_base_name  END AS "Assay Name::filter",
        CASE WHEN fg.use_all_instrument THEN '0 All Instruments' ELSE b.instrument_name  END AS "Instrument::filter",
        CASE WHEN fg.use_all_lot        THEN '0 All Lots'        ELSE b.control_lot      END AS "Control Lot::filter"
    FROM base_rows b
    CROSS JOIN (
        SELECT g.v AS use_all_group, a.v AS use_all_assay, 
               i.v AS use_all_instrument, l.v AS use_all_lot
        FROM (VALUES (false), (true)) g(v)
        CROSS JOIN (VALUES (false), (true)) a(v)
        CROSS JOIN (VALUES (false), (true)) i(v)
        CROSS JOIN (VALUES (false), (true)) l(v)
    ) fg

)

SELECT * FROM filter_expansion
ORDER BY sample_name, assay_base_name ASC;