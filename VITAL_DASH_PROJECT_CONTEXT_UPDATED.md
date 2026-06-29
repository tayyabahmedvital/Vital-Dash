# Vital Dash — Full Project Context & Design Doc

**Last Updated:** June 29, 2026
**Study:** VIKING_SYS_FOLLOW_UP_STUDY
**Built by:** Tayyab Ahmed (Data/Software Intern)
**Stack:** Redash + PostgreSQL + Atlantis (Django)

---

## Project Overview

Vital Dash is a real-time data quality dashboard built in Redash, connected to a PostgreSQL database. Scientists use it to monitor measurements coming in from clinical blood analyzers during live studies. The backend is called Atlantis (Django-based admin).

The goal is to give lab scientists — primarily Rachael Jean — a live view of precision metrics, outlier flags, and instrument performance without having to run manual queries or export CSVs.

---

## People

| Name | Role | Notes |
|------|------|-------|
| Tayyab Ahmed | Intern (me) | Data/software, building Vital Dash |
| Rachael Jean | Scientist | Main dashboard user, raising feature requests |
| Iman | Manager | Hired Tayyab |
| Mounir | CTO | Proposed Tayyab, senior stakeholder |
| Rhys | Backend/Atlantis | Handles DB structure, uF status, electrolytes work |
| Vasu | Unknown | Tagged alongside Iman |

---

## Tech Stack

- **Redash** — dashboarding and visualization
- **PostgreSQL** — database (all queries in PostgreSQL dialect)
- **Atlantis** — internal Django admin backend
- **experiment_run** — one row per analyzer run
- **experiment_runresult** — individual measurements (`calculated_value`, `actual_value`)

---

## Current Study — VIKING_SYS_FOLLOW_UP_STUDY

### Instruments
- **Erik family:** E-201 to E-208
- **Sigrid family:** S-199 to S-207
- **Helga:** single instrument (H-234, H-256)

### Key Data Structure Facts
- Measurements come from `experiment_runresult.calculated_value`
- Reference values (`actual_value`) are **not yet populated** for Viking
- `experiment_runconfig` is **empty** for Viking — no run-to-sample linkage exists
- Each run measures each assay **exactly once** — no within-run replication
- CV% must be calculated **across runs sharing the same control lot**, not within a single run
- CL, NA, K are excluded from heatmap (electrolyte exclusion for Viking)

### Control Lot Structure
Each run uses exactly one control lot, but each control lot is used across multiple runs. This is what makes cross-run CV% meaningful.

```
TEST_RUN_A → VIKING_BIORAD1_L
TEST_RUN_B → VIKING_BIORAD1_L  (same lot, different run)
TEST_RUN_C → VIKING_BIORAD2_M  (different lot)
```

---

## Key Database Tables

| Table | What it holds |
|-------|--------------|
| `experiment_run` | One row per analyzer run |
| `experiment_study` | Study metadata |
| `experiment_runresult` | Individual measurements (calculated_value, actual_value) |
| `experiment_indice` | Assay definitions (code = assay name e.g. ALB, GLU) |
| `experiment_runconfig` | Links runs to samples — empty for Viking |
| `experiment_sample` | Sample metadata (barcode is the human-readable ID) |
| `experiment_samplegroup` | Control lot groupings |
| `experiment_runsnapshot` | Run start time and metadata |
| `instrumentation_instrument` | Instrument metadata including name |
| `instrumentation_subsystem` | Subsystem/assay type codes |
| `inventory_wellmaster` | Well positions |

---

## Key Metrics

| Metric | Formula | Requires | Notes |
|--------|---------|----------|-------|
| CV% | (StdDev / Mean) x 100 | Multiple measurements | Needs N > 1, calculated across runs per control lot |
| Deviation Score | abs(value - median) / MAD | Multiple measurements | > 3 = outlier |
| MAD | Median(abs(x - median)) | Multiple measurements | Robust spread measure |
| Bias | Measured - Reference | Reference value | Blocked for Viking |
| Relative Error % | (Bias / Reference) x 100 | Reference value | Blocked for Viking |

---

## Dashboard Widgets

### Working

| Widget | Query Basis | Notes |
|--------|-------------|-------|
| Master Table | `run_code` as sample_name, `run_snapshot` join | Per-run and assay filters, outlier flag, Atlantis links |
| Precision Heatmap | CV% by control lot x assay | CL, NA, K excluded. Scale anchor row at 10% CV target. Outlier run exclusion via `excluded_run_codes` parameter |
| Heatmap N Counts | Replicate count per cell | Companion table to heatmap |
| Heatmap Outlier Drill-Down | Per-run measured values + MAD deviation score | New. Identifies which run is driving a high CV% cell. Filter by Sample Control + Assay to scope to one cell |
| Stats Timecourse Plot | Per run_code + assay, compressed timeline | NULL injection for line breaks between runs |
| Outlier Detail Table | MAD-based outlier flagging | Atlantis links included |
| Swarm Plot | Calculated values by control lot | Per-assay filter recommended |
| Correlation Diagnostic | Calculated vs reference scatter | Works where reference values exist |
| Global Swarm Plot | All measurements, color by instrument | Reference independent |
| Global Instrument Drift | Run sequence x measured value by instrument | Answers side-by-side instrument comparison request |
| Global Run Volume | Daily measurement count by instrument | Bar chart, TO_CHAR date formatting |

### Blocked (need reference values)
- Accuracy Overview
- Precision and Accuracy Scatter
- Pivot Table bias/relative error columns

---

## Outlier Detection

**Method: MAD (Median Absolute Deviation)**
- Partition: per assay + control lot + day
- Threshold: deviation score > 3 = outlier
- Does NOT distinguish between uF failure, calibration issue, or genuine biological variation

**uF Failure Handling:**
- uF = microfluidics disc failure — entire run is unreliable
- Current approach: manual exclusion via `excluded_run_codes` parameter on heatmap
- Parameter fed by a Query Based Dropdown List (`Param — Excluded Run Codes` query)
- Sentinel value `-- No Exclusions (Default)` always appears at the top of the dropdown and excludes nothing
- The heatmap uses `NOT IN (SELECT UNNEST(STRING_TO_ARRAY('{{excluded_run_codes}}', ',')))` to handle this cleanly
- Long term: needs proper uF pass/fail status from Atlantis/Rhys

---

## Heatmap Outlier Workflow

The workflow for investigating a high CV% cell:

1. Spot a high CV% cell in the Precision Heatmap (e.g. TRIG x VIKING_BIORAD2_M showing 157%)
2. Open the **Heatmap Outlier Drill-Down** widget
3. Filter by **Sample Control** = VIKING_BIORAD2_M and **Assay** = TRIG
4. Rows sort by deviation score descending — the outlier run is at the top, flagged as OUTLIER
5. Copy the run code
6. Paste it into the `excluded_run_codes` dropdown on the Precision Heatmap
7. Heatmap recalculates CV% without that run

---

## SQL Conventions

- Always use `{{study_code}}` as the parameterized study filter
- Instrument name always resolved dynamically: `LEFT JOIN instrumentation_instrument inst ON inst.id = r.instrument_id` — never hardcoded
- Filter columns use `::filter` suffix e.g. `assay_name AS "Assay::filter"` for Redash dropdown filters
- All "All X" filter options are prefixed with `0 ` (e.g. `'0 All Assays'`) so they sort to the top of Redash dropdowns alphabetically
- Cross join pattern generates all filter combinations so Redash dropdowns show both specific values and "All X" options simultaneously
- NULL injection pattern for timecourse line breaks between runs:
```sql
UNION ALL
SELECT (ts.timeline_shift + os.total_points + 1)::float, NULL, NULL, ...
```
- UNION ALL sides must always have identical column counts
- Date formatting for Redash X axis: `TO_CHAR(DATE_TRUNC('day', date), 'YYYY-MM-DD')` not raw timestamps
- Always set Missing and NULL values to "Do not display in chart" for line/scatter charts
- `ROUND(..., n)` always requires explicit `::numeric` cast — PostgreSQL has no `ROUND(double precision, integer)` overload
- `DISTINCT ON (id)` used in run_groups CTEs to prevent fan-out from multiple runconfig rows per run
- Nested aggregate functions (e.g. MAD calculation) must be split across two CTEs — compute median first, then join it in for the MAD PERCENTILE_CONT

---

## Redash Configuration Notes

- **Scatter chart** — X = assay_name, Y = measured_value, Group by = instrument_name
- **Heatmap** — X = structured_assay, Y = sample_control, Color = color_scale_cv
- **Timecourse** — X = continuous_timeline, Y columns = measured_outlier_point + measured_normal_point + average_value_line + reference_value_line, Group by = empty, Missing values = Do not display
- **Bar chart (run volume)** — X = measurement_day, Y = n_measurements, Group by = instrument_name, X Axis Scale = Category
- **LIMIT 1000** must be unchecked for any query using cross join filter expansion — the multiplier (2^N combos) causes the limit to cut off real data rows and break dropdown values
- Filter dropdown order is controlled by value prefixes, not ORDER BY — Redash builds dropdowns from distinct values alphabetically

---

## Filter Design Pattern

All widgets that use Redash dropdown filters follow this pattern:

```sql
-- Cross join generates both specific and "All X" rows for every filter dimension
CROSS JOIN (
    SELECT a.v AS use_all_assay, i.v AS use_all_instrument
    FROM       (VALUES (false), (true)) a(v)
    CROSS JOIN (VALUES (false), (true)) i(v)
) fg

-- Filter columns in SELECT use 0-prefix on "All" values to sort to top
CASE WHEN fg.use_all_assay THEN '0 All Assays' ELSE assay_name END AS "Assay::filter",
CASE WHEN fg.use_all_instrument THEN '0 All Instruments' ELSE instrument_name END AS "Instrument::filter"
```

Display columns (what actually shows in the table) are kept separate from filter columns and always show the real value regardless of filter state.

---

## Known Issues & Workarounds

| Issue | Workaround | Long-term Fix |
|-------|-----------|---------------|
| `experiment_runconfig` empty for Viking | Fallback to `CONCAT('Run Lot: ', run_code)` as control lot label | Populate runconfig records |
| `actual_value` NULL for all Viking | Accuracy/bias widgets blocked | Populate reference values |
| uF failure runs spike CV% | Manual exclusion via `excluded_run_codes` dropdown | Get uF pass/fail status from Rhys |
| Redash LIMIT cuts cross-join expanded rows | Uncheck LIMIT 1000 in query settings | N/A — just leave unchecked |
| PostgreSQL `ROUND(double precision, integer)` error | Cast expression to `::numeric` before ROUND | N/A — always cast |
| Fan-out from multiple runconfig rows per run | `DISTINCT ON (run_id)` in run_groups CTE | N/A — pattern is correct |

---

## Pending / Next Steps

### Immediate
- [ ] Get uF pass/fail status from Rhys/Atlantis team so uF failures can be flagged automatically rather than manually excluded

### Short-term
- [ ] Populate reference values (`actual_value`) for Viking study to unlock accuracy widgets
- [ ] Confirm with data team when `experiment_runconfig` records will be created for Viking
- [ ] Add dashboard-level text widget with key metrics reference table for scientists

### Medium-term
- [ ] Reference range-based outlier detection once `actual_value` is populated
- [ ] Automate uF exclusion logic once Atlantis exposes pass/fail status per run
- [ ] Instrument side-by-side comparison — current recommendation is separate browser tabs with instrument filter scoped per tab

### Long-term
- [ ] Unlock Accuracy Overview, Precision and Accuracy Scatter, Pivot Table bias columns once reference values exist
- [ ] Consider adding run-level status tracking (passed/failed/excluded) as a first-class concept in the dashboard

---

## Summary of Design Decisions

**CV% across runs, not within runs.** Each run measures each assay once, so STDDEV within a run is NULL. CV% is calculated by grouping all runs that share the same control lot together.

**MAD for outlier detection, not z-score.** MAD is robust to the outliers it's trying to detect. Z-score gets distorted by the very outlier you're looking for.

**Scale anchor row in heatmap.** A synthetic `Scale Anchor (10% CV Target)` row is injected with `color_scale_cv = 10.0` to pin the color scale maximum. Without it, Redash auto-scales to the max value in the data, making moderate CV% values look fine when they aren't.

**Separate display and filter columns.** Filter columns (`::filter` suffix) carry the cross-join "All X" logic and are hidden in the table. Display columns always show the real value so the table reads cleanly.

**Sentinel value for excluded_run_codes.** The `-- No Exclusions (Default)` option at the top of the exclusion dropdown uses a string that will never match a real run code, so selecting it includes all runs. The `UNNEST(STRING_TO_ARRAY(...))` pattern handles this without requiring SQL changes when switching between exclusion and no-exclusion states.
