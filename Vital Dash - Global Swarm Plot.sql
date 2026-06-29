-- ============================================================
-- GLOBAL SWARM PLOT
-- All measurements across all runs, colored by sample/control lot
-- X = instrument name (categorical)
-- Y = measured value
-- Instrument name resolved dynamically from instrumentation_instrument
-- No reference value dependency
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
        res.id                                AS result_id,
        ind.code                              AS assay_name,
        res.calculated_value                  AS measured_value,
        res.created_at                        AS date_of_measurement,
        COALESCE(wm.name, wm.code, 'Unknown') AS well,
        COALESCE(grp.name, CONCAT('Run Lot: ', sr.run_code)) AS control_lot
    FROM study_runs sr
    INNER JOIN experiment_runresult res        ON sr.run_id = res.run_id
    INNER JOIN experiment_indice ind           ON res.indice_id = ind.id
    LEFT  JOIN inventory_wellmaster wm         ON wm.id = res.well_master_id
    LEFT  JOIN experiment_runconfig rcfg       ON rcfg.run_id = sr.run_id
    LEFT  JOIN experiment_sample smpl          ON smpl.id = rcfg.sample_id
    LEFT  JOIN experiment_samplegroup grp      ON grp.id = smpl.sample_group_id
    WHERE res.calculated_value IS NOT NULL
),
assay_stats AS (
    SELECT
        assay_name,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY measured_value) AS assay_median,
        AVG(measured_value)                                          AS assay_mean,
        STDDEV_POP(measured_value)                                   AS assay_stddev,
        COUNT(*)                                                     AS assay_n
    FROM raw_data
    GROUP BY assay_name
),
iqr_bounds AS (
    SELECT
        assay_name,
        instrument_name,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY measured_value) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY measured_value) AS q3,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY measured_value) -
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY measured_value) AS iqr
    FROM raw_data
    GROUP BY assay_name, instrument_name
),
base_rows AS (
    SELECT
        r.assay_name,
        r.instrument_name,
        r.run_code,
        r.result_id,
        r.control_lot,
        ROUND(r.measured_value::numeric, 3)                         AS measured_value,
        r.well,
        r.date_of_measurement,
        r.instrument_name || ' | ' ||
            TO_CHAR(DATE_TRUNC('day', r.date_of_measurement), 'YYYY-MM-DD')
            || ' | ' || r.run_code                                  AS run_label,
        ROUND(ast.assay_median::numeric, 3)                         AS assay_median,
        ROUND(ast.assay_mean::numeric, 3)                           AS assay_mean,
        ROUND(ast.assay_stddev::numeric, 3)                         AS assay_stddev,
        ast.assay_n,
        ROUND(iq.q1::numeric, 3)                                    AS q1,
        ROUND(iq.q3::numeric, 3)                                    AS q3,
        ROUND(iq.iqr::numeric, 3)                                   AS iqr,
        CASE
            WHEN iq.iqr = 0                                         THEN 'Normal'
            WHEN r.measured_value < (iq.q1 - 1.5 * iq.iqr)        THEN 'Suspected Outlier'
            WHEN r.measured_value > (iq.q3 + 1.5 * iq.iqr)        THEN 'Suspected Outlier'
            ELSE 'Normal'
        END                                                         AS outlier_status,
        CONCAT('https://atlantis.stable.vital.company/admin/experiment/run/', r.run_id, '/change/') AS atlantis_run_link,
        DATE_TRUNC('day', r.date_of_measurement)::date             AS measurement_day
    FROM raw_data r
    LEFT JOIN assay_stats ast ON r.assay_name = ast.assay_name
    LEFT JOIN iqr_bounds iq
        ON  r.assay_name      = iq.assay_name
        AND r.instrument_name = iq.instrument_name
)

SELECT
    b.assay_name,
    b.instrument_name,
    b.run_code,
    b.result_id,
    b.control_lot                                                   AS sample,
    b.measured_value,
    b.well,
    b.date_of_measurement,
    b.run_label,
    b.assay_median,
    b.assay_mean,
    b.assay_stddev,
    b.assay_n,
    b.q1,
    b.q3,
    b.iqr,
    b.outlier_status,
    b.atlantis_run_link,
    b.measurement_day                                               AS "Date::filter",
    b.assay_name                                                    AS "Assay::filter",
    b.outlier_status                                                AS "Outlier::filter",
    CASE WHEN fg.use_all_instrument
        THEN 'All Instruments'
        ELSE b.instrument_name
    END                                                             AS "Instrument::filter"
FROM base_rows b
CROSS JOIN (
    SELECT i.v AS use_all_instrument
    FROM (VALUES (false), (true)) i(v)
) fg

ORDER BY b.assay_name, b.instrument_name, b.date_of_measurement;