SELECT '0 - No Exclusions (Default)' AS run_code

UNION ALL

SELECT DISTINCT r.code AS run_code
FROM experiment_run r
INNER JOIN experiment_study s ON s.id = r.study_id
INNER JOIN experiment_runresult res ON res.run_id = r.id
WHERE s.code = 'VIKING_SYS_FOLLOW_UP_STUDY'
  AND res.calculated_value IS NOT NULL

ORDER BY run_code ASC
