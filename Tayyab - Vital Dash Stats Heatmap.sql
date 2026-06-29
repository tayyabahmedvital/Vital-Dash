-- ============================================================
-- PRECISION HEATMAP — CV% by Assay & Control Lot
-- Aggregates across all runs for meaningful CV% calculation
-- Per-instrument CV% partitioning + instrument filter
-- Outlier exclusion: select run codes from excluded_run_codes dropdown
-- Select 'NONE' or '-- No Exclusions (Default)' to include all runs
-- contributing_runs column shows which runs went into each CV% cell
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
        sd.sample_group_name,
        sd.sample_id,
        sd.run_code,
        inst.name                                                      AS instrument_name,
        sub.code                                                       AS structure_name,
        ind.code                                                       AS assay_name,
        res.calculated_value                                           AS measured_value,
        res.actual_value                                               AS reference_value,
        res.created_at                                                 AS date_of_measurement
    FROM sample_details sd
    INNER JOIN experiment_runresult res ON sd.run_id = res.run_id
    INNER JOIN experiment_indice ind ON res.indice_id = ind.id
    INNER JOIN instrumentation_subsystem sub ON res.subsystem_id = sub.id
    LEFT  JOIN instrumentation_instrument inst ON inst.id = sd.instrument_id
    WHERE sd.run_code NOT IN (SELECT UNNEST(STRING_TO_ARRAY('{{excluded_run_codes}}', ',')))
),
assay_groups AS (
    SELECT
        assay_name,
        CASE
            WHEN assay_name IN ('NA', 'K', 'CL', 'CA', 'MG', 'PHOS')                        THEN 'Electrolytes'
            WHEN assay_name IN ('ALT', 'AST', 'ALP', 'ALB', 'TBIL', 'DBIL', 'TP', 'LDH')   THEN 'Liver Function'
            WHEN assay_name IN ('CREA', 'BUN', 'UA')                                          THEN 'Renal Function'
            WHEN assay_name IN ('GLU', 'CHOL', 'TRIG')                                        THEN 'Metabolic'
            ELSE 'Other'
        END AS assay_group
    FROM (SELECT DISTINCT assay_name FROM raw_assay_metrics) t
),
cv_all_runs AS (
    SELECT 
        r.sample_group_name                                            AS sample_control,
        r.instrument_name,
        CONCAT(r.structure_name, ': ', r.assay_name)                  AS structured_assay,
        r.assay_name,
        MAX(DATE_TRUNC('day', r.date_of_measurement)::date)           AS latest_date,
        STRING_AGG(DISTINCT r.run_code, ', ' ORDER BY r.run_code)     AS contributing_runs,
        ROUND(COALESCE(
            (STDDEV(r.measured_value) / NULLIF(AVG(r.measured_value), 0)) * 100,
        0)::numeric, 4)                                                AS true_cv
    FROM raw_assay_metrics r
    WHERE r.measured_value IS NOT NULL
      AND r.measured_value < 10000
      AND r.measured_value >= 0
    GROUP BY r.sample_group_name, r.instrument_name, r.structure_name, r.assay_name
),
final_matrix AS (
    SELECT
        a.sample_control, a.instrument_name, a.structured_assay,
        a.assay_name, a.latest_date, a.contributing_runs,
        a.true_cv AS overall_cv, a.true_cv AS color_scale_cv,
        'Include All Runs'                                             AS "Outlier Filter::filter"
    FROM cv_all_runs a

    UNION ALL

    SELECT
        'Scale Anchor (10% CV Target)'                                AS sample_control,
        i.instrument_name,
        (SELECT MIN(structured_assay) FROM cv_all_runs)               AS structured_assay,
        NULL                                                           AS assay_name,
        NULL                                                           AS latest_date,
        NULL                                                           AS contributing_runs,
        NULL                                                           AS overall_cv,
        10.0                                                           AS color_scale_cv,
        'Include All Runs'                                             AS "Outlier Filter::filter"
    FROM (SELECT DISTINCT instrument_name FROM cv_all_runs) i
)

SELECT
    f.sample_control,
    f.structured_assay,
    f.overall_cv,
    f.color_scale_cv,
    f.contributing_runs,
    f."Outlier Filter::filter",
    CASE WHEN fg.use_all_instrument    THEN 'All Instruments'    ELSE f.instrument_name       END AS "Instrument::filter",
    CASE WHEN fg.use_all_group         THEN 'All Groups'         ELSE ag.assay_group          END AS "Assay Group::filter",
    CASE WHEN fg.use_all_date          THEN 'All Dates'          ELSE f.latest_date::text     END AS "Date::filter",
    CASE WHEN fg.use_all_sample        THEN 'All Samples'        ELSE f.sample_control        END AS "Sample Control::filter",
    CASE WHEN fg.use_all_assay         THEN 'All Assays'         ELSE f.assay_name            END AS "Assay::filter",
    CASE WHEN fg.use_all_runs          THEN 'All Runs'           ELSE f.contributing_runs     END AS "Contributing Runs::filter"
FROM final_matrix f
LEFT JOIN assay_groups ag ON ag.assay_name = f.assay_name
CROSS JOIN (
    SELECT
        i.v  AS use_all_instrument,
        g.v  AS use_all_group,
        d.v  AS use_all_date,
        s.v  AS use_all_sample,
        a.v  AS use_all_assay,
        r.v  AS use_all_runs
    FROM       (VALUES (false), (true)) i(v)
    CROSS JOIN (VALUES (false), (true)) g(v)
    CROSS JOIN (VALUES (false), (true)) d(v)
    CROSS JOIN (VALUES (false), (true)) s(v)
    CROSS JOIN (VALUES (false), (true)) a(v)
    CROSS JOIN (VALUES (false), (true)) r(v)
) fg

ORDER BY sample_control ASC, structured_assay ASC;