-- ============================================================
-- OUTLIER DRILL-DOWN TABLE — Per-run values for a selected cell
-- Companion to Precision Heatmap.
-- Filter by Sample Control + Assay to inspect a heatmap cell.
-- Outlier run identified by deviation score > 3 (MAD method).
-- Copy flagged run_code into excluded_run_codes on the heatmap.
-- ============================================================
WITH study_runs AS (
    SELECT
        r.id   AS run_id,
        r.code AS run_code,
        r.instrument_id
    FROM experiment_run r
    INNER JOIN experiment_study s ON r.study_id = s.id
    WHERE s.code = '{{study_code}}'
),
run_groups AS (
    -- Deduplicate via DISTINCT ON to prevent fan-out from multiple runconfig rows
    SELECT DISTINCT ON (sr.run_id)
        sr.run_id,
        sr.run_code,
        sr.instrument_id,
        COALESCE(grp.name, 'Run Lot')          AS sample_group_name
    FROM study_runs sr
    LEFT JOIN experiment_runconfig rcfg  ON sr.run_id = rcfg.run_id
    LEFT JOIN experiment_sample smpl     ON rcfg.sample_id = smpl.id
    LEFT JOIN experiment_samplegroup grp ON smpl.sample_group_id = grp.id
    ORDER BY sr.run_id
),
measurements AS (
    SELECT
        rg.run_code,
        rg.sample_group_name                          AS sample_control,
        inst.name                                     AS instrument_name,
        ind.code                                      AS assay_name,
        res.calculated_value                          AS measured_value,
        DATE_TRUNC('day', res.created_at)::date       AS measured_date,
        res.created_at                                AS measured_at
    FROM run_groups rg
    INNER JOIN experiment_runresult       res  ON rg.run_id = res.run_id
    INNER JOIN experiment_indice          ind  ON res.indice_id = ind.id
    LEFT  JOIN instrumentation_instrument inst ON inst.id = rg.instrument_id
    WHERE res.calculated_value IS NOT NULL
      AND res.calculated_value >= 0
      AND res.calculated_value < 10000
),
group_medians AS (
    SELECT
        sample_control,
        assay_name,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY measured_value) AS group_median
    FROM measurements
    GROUP BY sample_control, assay_name
),
group_stats AS (
    SELECT
        m.sample_control,
        m.assay_name,
        AVG(m.measured_value)                                        AS group_mean,
        STDDEV(m.measured_value)                                     AS group_stddev,
        gmed.group_median,
        PERCENTILE_CONT(0.5) WITHIN GROUP
            (ORDER BY ABS(m.measured_value - gmed.group_median))     AS group_mad,
        ROUND(
            ((STDDEV(m.measured_value) / NULLIF(AVG(m.measured_value), 0)) * 100)::numeric
        , 2)                                                         AS group_cv_pct,
        COUNT(*)                                                     AS n_runs
    FROM measurements m
    INNER JOIN group_medians gmed
        ON gmed.sample_control = m.sample_control
        AND gmed.assay_name    = m.assay_name
    GROUP BY m.sample_control, m.assay_name, gmed.group_median
),
scored AS (
    -- Compute deviation score once, reuse in both display and filter columns
    SELECT
        m.run_code,
        m.sample_control,
        m.instrument_name,
        m.assay_name,
        m.measured_date,
        TO_CHAR(m.measured_at, 'YYYY-MM-DD HH24:MI')                AS measured_at,
        ROUND(m.measured_value::numeric, 3)                          AS measured_value,
        ROUND(gs.group_mean::numeric, 3)                             AS group_mean,
        ROUND(gs.group_stddev::numeric, 3)                           AS group_stddev,
        ROUND(gs.group_cv_pct::numeric, 2)                           AS group_cv_pct,
        ROUND(
            (CASE
                WHEN gs.group_mad = 0 THEN NULL
                ELSE ABS(m.measured_value - gs.group_median) / NULLIF(gs.group_mad, 0)
            END)::numeric, 2
        )                                                            AS deviation_score,
        CASE
            WHEN gs.group_mad = 0 THEN 'Check manually'
            WHEN (ABS(m.measured_value - gs.group_median) / NULLIF(gs.group_mad, 0)) > 3
                THEN 'OUTLIER'
            ELSE 'OK'
        END                                                          AS flag,
        gs.n_runs
    FROM measurements m
    INNER JOIN group_stats gs
        ON gs.sample_control = m.sample_control
        AND gs.assay_name    = m.assay_name
)
SELECT
    s.run_code,
    s.sample_control,
    s.instrument_name,
    s.assay_name,
    s.measured_at,
    s.measured_value,
    s.group_mean,
    s.group_stddev,
    s.group_cv_pct,
    s.deviation_score,
    s.flag,
    s.n_runs,
    -- Hidden filter columns
    CASE WHEN fg.use_all_sample     THEN 'All Samples'     ELSE s.sample_control  END AS "Sample Control::filter",
    CASE WHEN fg.use_all_instrument THEN 'All Instruments' ELSE s.instrument_name END AS "Instrument::filter",
    CASE WHEN fg.use_all_assay      THEN 'All Assays'      ELSE s.assay_name      END AS "Assay::filter",
    CASE WHEN fg.use_all_run        THEN 'All Runs'        ELSE s.run_code        END AS "Run Code::filter",
    CASE WHEN fg.use_all_date       THEN 'All Dates'       ELSE TO_CHAR(s.measured_date, 'YYYY-MM-DD') END AS "Date::filter",
    CASE WHEN fg.use_all_flag       THEN 'All'             ELSE s.flag            END AS "Outlier Flag::filter"
FROM scored s
CROSS JOIN (
    SELECT
        sc.v AS use_all_sample,
        i.v  AS use_all_instrument,
        a.v  AS use_all_assay,
        r.v  AS use_all_run,
        d.v  AS use_all_date,
        f.v  AS use_all_flag
    FROM       (VALUES (false), (true)) sc(v)
    CROSS JOIN (VALUES (false), (true)) i(v)
    CROSS JOIN (VALUES (false), (true)) a(v)
    CROSS JOIN (VALUES (false), (true)) r(v)
    CROSS JOIN (VALUES (false), (true)) d(v)
    CROSS JOIN (VALUES (false), (true)) f(v)
) fg
ORDER BY
    s.measured_date DESC,
    s.sample_control,
    s.assay_name,
    s.deviation_score DESC NULLS LAST;