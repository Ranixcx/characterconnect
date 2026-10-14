-- materialize_fit.sql
-- Run AFTER load_real_data.sql and load_similarity.sql, BEFORE demo_queries.sql.
-- Stores the Job Fit Score for every job x character pair in a real table (a data mart),
-- so the demo queries read it directly instead of recomputing the view every time.
-- Re-run it whenever the similarity table, the scores or the job importances change.
-- It can take a while the first time (it computes the whole view once).

DROP TABLE IF EXISTS fact_job_fit;

CREATE TABLE fact_job_fit AS
SELECT job_key, character_key, raw_score, fit_ratio, job_fit_score, risk_flag_count
FROM v_job_fit;

ALTER TABLE fact_job_fit ADD PRIMARY KEY (job_key, character_key);
CREATE INDEX idx_fit_character ON fact_job_fit (character_key, job_fit_score DESC);
CREATE INDEX idx_fit_job       ON fact_job_fit (job_key, job_fit_score DESC);
ANALYZE fact_job_fit;

SELECT COUNT(*) AS n_rows, 891 * 2125 AS expected FROM fact_job_fit;
