-- ============================================================
-- INSTRUMENT DRIFT CHART — Per Assay, Per Instrument Over Runs
-- X = run sequence (compressed, not actual time)
-- Y = measured value
-- Color by instrument (dynamic — whatever instruments exist)
-- Answers: "do Erik, Sigrid, Helga agree? Is anyone drifting?"
-- ============================================================

WITH study_runs AS (
    SELECT
        r.id            AS run_id,
        r.code          AS run_code,
        r.instrument_id,
        COALESCE(inst.name, r.instrument_id::varchar) AS instrument_name,
        s.code          AS study_code
    FROM experiment_run r
    INNER JOIN experiment_study s ON r.study_id = s.id
    LEFT  JOIN instrumentation_instrument inst ON inst.id = r.instrument_id
    WHERE s.code = '{{study_code}}'
),
raw_data AS (
    SELECT
        sr.run_id,
        sr.run_code,
        sr.instrument_name,
        ind.code                              AS assay_name,
        res.calculated_value                  AS measured_value,
        res.actual_value                      AS reference_value,
        res.created_at                        AS date_of_measurement,
        COALESCE(wm.name, wm.code, 'Unknown') AS well
    FROM study_runs sr
    INNER JOIN experiment_runresult res ON sr.run_id = res.run_id
    INNER JOIN experiment_indice ind    ON res.indice_id = ind.id
    LEFT  JOIN inventory_wellmaster wm  ON wm.id = res.well_master_id
    WHERE res.calculated_value IS NOT NULL
),
run_order AS (
    SELECT
        run_id,
        run_code,
        assay_name,
        MIN(date_of_measurement) AS run_start,
        ROW_NUMBER() OVER (
            PARTITION BY assay_name
            ORDER BY MIN(date_of_measurement), run_code
        ) AS run_seq
    FROM raw_data
    GROUP BY run_id, run_code, assay_name
),
outlier_medians AS (
    SELECT
        assay_name, instrument_name,
        DATE_TRUNC('day', date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY measured_value) AS median_value
    FROM raw_data
    GROUP BY assay_name, instrument_name, DATE_TRUNC('day', date_of_measurement)::date
),
outlier_mad AS (
    SELECT
        r.assay_name, r.instrument_name,
        DATE_TRUNC('day', r.date_of_measurement)::date AS measurement_day,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY ABS(r.measured_value - om.median_value)
        ) AS mad_value
    FROM raw_data r
    INNER JOIN outlier_medians om
        ON  r.assay_name      = om.assay_name
        AND r.instrument_name = om.instrument_name
        AND DATE_TRUNC('day', r.date_of_measurement)::date = om.measurement_day
    GROUP BY r.assay_name, r.instrument_name, DATE_TRUNC('day', r.date_of_measurement)::date
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
    FROM (SELECT DISTINCT assay_name FROM raw_data) t
),
base_rows AS (
    SELECT
        r.assay_name,
        ag.assay_group,
        r.instrument_name,
        r.run_code,
        ro.run_seq                                                  AS run_sequence,
        r.measured_value,
        r.date_of_measurement,
        r.well,
        AVG(r.measured_value) OVER (
            PARTITION BY r.assay_name, r.instrument_name
        )                                                           AS instrument_assay_mean,
        om.median_value,
        mad.mad_value,
        ROUND((ABS(r.measured_value - om.median_value) / NULLIF(mad.mad_value, 0))::numeric, 4) AS deviation_score,
        CASE
            WHEN mad.mad_value = 0 THEN 'Normal'
            WHEN (ABS(r.measured_value - om.median_value) / NULLIF(mad.mad_value, 0)) > 3 THEN 'Outlier'
            ELSE 'Normal'
        END                                                         AS outlier_status,
        CONCAT('https://atlantis.stable.vital.company/admin/experiment/run/', r.run_id, '/change/') AS atlantis_run_link,
        DATE_TRUNC('day', r.date_of_measurement)::date             AS measurement_day
    FROM raw_data r
    INNER JOIN run_order ro
        ON  r.run_id     = ro.run_id
        AND r.assay_name = ro.assay_name
    LEFT JOIN outlier_medians om
        ON  r.assay_name      = om.assay_name
        AND r.instrument_name = om.instrument_name
        AND DATE_TRUNC('day', r.date_of_measurement)::date = om.measurement_day
    LEFT JOIN outlier_mad mad
        ON  r.assay_name      = mad.assay_name
        AND r.instrument_name = mad.instrument_name
        AND DATE_TRUNC('day', r.date_of_measurement)::date = mad.measurement_day
    LEFT JOIN assay_groups ag ON ag.assay_name = r.assay_name
)

-- Cross join generates all 16 combinations (2^4) for four independent "All" filters:
--   Assay Group  (specific | All Groups)
--   Assay Name   (specific | All Assays)
--   Instrument   (specific | All Instruments)
--   Run Code     (specific | All Runs)
SELECT
    b.assay_name,
    b.assay_group,
    b.instrument_name,
    b.run_code,
    b.run_sequence,
    b.measured_value,
    b.date_of_measurement,
    b.well,
    b.instrument_assay_mean,
    b.median_value,
    b.mad_value,
    b.deviation_score,
    b.outlier_status,
    b.atlantis_run_link,
    b.measurement_day                                               AS "Date::filter",
    CASE WHEN fg.use_all_group      THEN 'All Groups'      ELSE b.assay_group      END AS "Assay Group::filter",
    CASE WHEN fg.use_all_assay      THEN 'All Assays'      ELSE b.assay_name       END AS "Assay Name::filter",
    CASE WHEN fg.use_all_instrument THEN 'All Instruments' ELSE b.instrument_name  END AS "Instrument::filter",
    CASE WHEN fg.use_all_run        THEN 'All Runs'        ELSE b.run_code         END AS "Run Code::filter"
FROM base_rows b
CROSS JOIN (
    SELECT
        g.v AS use_all_group,
        a.v AS use_all_assay,
        i.v AS use_all_instrument,
        r.v AS use_all_run
    FROM       (VALUES (false), (true)) g(v)
    CROSS JOIN (VALUES (false), (true)) a(v)
    CROSS JOIN (VALUES (false), (true)) i(v)
    CROSS JOIN (VALUES (false), (true)) r(v)
) fg

ORDER BY b.measurement_day DESC, b.assay_name, b.run_sequence, b.instrument_name;