-- ============================================================
-- GLOBAL RUN VOLUME
-- X = day (categorical string), Y = runs per instrument per day
-- Group by instrument_name for clustered bars
-- No assay grouping — each run covers all assays
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
run_dates AS (
    SELECT
        sr.run_id,
        sr.run_code,
        sr.instrument_name,
        MIN(res.created_at) AS run_date
    FROM study_runs sr
    INNER JOIN experiment_runresult res ON sr.run_id = res.run_id
    WHERE res.calculated_value IS NOT NULL
    GROUP BY sr.run_id, sr.run_code, sr.instrument_name
)
SELECT
    TO_CHAR(DATE_TRUNC('day', run_date), 'YYYY-MM-DD') AS measurement_day,
    instrument_name,
    COUNT(DISTINCT run_id)                              AS n_runs,
    -- Date filter only, no assay filter
    TO_CHAR(DATE_TRUNC('day', run_date), 'YYYY-MM-DD') AS "Date::filter"
FROM run_dates
GROUP BY
    TO_CHAR(DATE_TRUNC('day', run_date), 'YYYY-MM-DD'),
    instrument_name
ORDER BY
    measurement_day DESC,
    instrument_name;