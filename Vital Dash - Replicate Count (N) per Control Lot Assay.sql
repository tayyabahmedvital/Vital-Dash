-- ============================================================
-- HEATMAP N COUNTS — Replicates per Control Lot × Assay
-- Companion to the CV% heatmap
-- Instrument filter added with All Instruments option
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
        sd.sample_group_name,
        inst.name                                   AS instrument_name,
        sub.code                                    AS structure_name,
        ind.code                                    AS assay_name,
        res.calculated_value                        AS measured_value
    FROM sample_details sd
    INNER JOIN experiment_runresult res        ON sd.run_id = res.run_id
    INNER JOIN experiment_indice ind           ON res.indice_id = ind.id
    INNER JOIN instrumentation_subsystem sub   ON sub.id = res.subsystem_id
    LEFT  JOIN instrumentation_instrument inst ON inst.id = sd.instrument_id
    WHERE res.calculated_value IS NOT NULL
      AND res.calculated_value < 10000
      AND res.calculated_value >= 0
),
base_rows AS (
    SELECT
        sample_group_name                           AS control_lot,
        instrument_name,
        CONCAT(structure_name, ': ', assay_name)    AS structured_assay,
        assay_name,
        COUNT(*)                                    AS n_replicates
    FROM raw_assay_metrics
    GROUP BY sample_group_name, instrument_name, structure_name, assay_name
)

SELECT
    b.control_lot,
    b.structured_assay,
    b.assay_name,
    b.n_replicates,
    b.control_lot                                   AS "Control Lot::filter",
    b.assay_name                                    AS "Assay::filter",
    CASE WHEN fg.use_all_instrument
        THEN 'All Instruments'
        ELSE b.instrument_name
    END                                             AS "Instrument::filter"
FROM base_rows b
CROSS JOIN (
    SELECT i.v AS use_all_instrument
    FROM (VALUES (false), (true)) i(v)
) fg

ORDER BY control_lot, structured_assay;