
-- Q1. Which jobs fit a given character best, and does the match carry any risk flag?
--     (example: Jon Snow, character_code 'GOT/1')
SELECT c.name                          AS character_name,
       j.title                         AS job,
       ROUND(f.job_fit_score, 1)       AS fit_score,        -- 0 = opposite of the job, 50 = neutral, 100 = perfect
       f.risk_flag_count               AS risky_traits      -- how many of the 21 O*NET traits count against them
FROM fact_job_fit f
JOIN dim_character c ON c.character_key = f.character_key
JOIN dim_job j       ON j.job_key = f.job_key
WHERE c.character_code = 'GOT/1'
ORDER BY f.job_fit_score DESC, j.title
LIMIT 5;


-- Q2. Which characters fit a given job best?   (example: Nuclear Engineers)
SELECT c.name                          AS character_name,
       c.work_code                     AS universe,
       ROUND(f.job_fit_score, 1)       AS fit_score,
       f.risk_flag_count               AS risky_traits
FROM fact_job_fit f
JOIN dim_character c ON c.character_key = f.character_key
JOIN dim_job j       ON j.job_key = f.job_key
WHERE j.title = 'Nuclear Engineers'
ORDER BY f.job_fit_score DESC, c.name
LIMIT 10;


-- Q3. Which jobs come up most often as a character's single best match?
--     (checks that the model does not send everybody to the same few jobs)
WITH ranked AS (
    SELECT job_key, character_key, job_fit_score,
           ROW_NUMBER() OVER (PARTITION BY character_key
                              ORDER BY job_fit_score DESC, job_key) AS rn
    FROM fact_job_fit
)
SELECT j.title                         AS job,
       COUNT(*)                        AS n_characters_best_match
FROM ranked r
JOIN dim_job j ON j.job_key = r.job_key
WHERE r.rn = 1
GROUP BY j.title
ORDER BY n_characters_best_match DESC, j.title
LIMIT 10;


-- Q4. Why is a character risky for a job? List the O*NET traits that count against them.
--     (example: Jon Snow applying as a Nuclear Engineer)
SELECT t.name                          AS onet_trait,
       ROUND(v.importance, 2)          AS importance_for_job,
       ROUND(v.trait_level, 2)         AS character_level,  -- -1 = opposite of the trait, +1 = fully has it
       ROUND(v.match_score, 2)         AS match_score       -- negative = counts against the character
FROM v_fact_job_character_trait v
JOIN dim_character c  ON c.character_key = v.character_key
JOIN dim_job j        ON j.job_key = v.job_key
JOIN dim_onet_trait t ON t.onet_trait_key = v.onet_trait_key
WHERE c.character_code = 'GOT/1'
  AND j.title = 'Nuclear Engineers'
  AND v.match_score < 0
ORDER BY v.match_score;


-- Q5. HR question: for a given job, which universes (works) produce the best applicants on average?
--     Universes with fewer than 5 characters are ignored so that one lucky character does not win.
SELECT c.work_code                     AS universe,
       COUNT(*)                        AS n_characters,
       ROUND(AVG(f.job_fit_score), 1)  AS avg_fit_score
FROM fact_job_fit f
JOIN dim_character c ON c.character_key = f.character_key
JOIN dim_job j       ON j.job_key = f.job_key
WHERE j.title = 'Nuclear Engineers'
GROUP BY c.work_code
HAVING COUNT(*) >= 5
ORDER BY avg_fit_score DESC, c.work_code
LIMIT 10;


-- Q6. Which characters have a personality closest to a typed-in profile?
--     Example profile: bold, diligent and honorable. Scores run from 0 (low pole) to 100 (high pole).
--     Uses only the SWCPQ scores, so its answer does not depend on the similarity table.
WITH profile(trait_id, target) AS (
    VALUES (2, 90),     -- shy (0) to bold (100): bold
           (32, 10),    -- diligent (0) to lazy (100): diligent
           (14, 90)     -- cunning (0) to honorable (100): honorable
)
SELECT c.name,
       c.work_name                              AS universe,
       ROUND(AVG(ABS(f.score - p.target)), 1)   AS avg_gap    -- 0 = identical profile
FROM profile p
JOIN dim_character_trait t         ON t.trait_id = p.trait_id
JOIN fact_character_trait_score f  ON f.char_trait_key = t.char_trait_key
JOIN dim_character c               ON c.character_key = f.character_key
GROUP BY c.character_key, c.name, c.work_name
ORDER BY avg_gap, c.name
LIMIT 5;


-- Q7. KPI query: How good are the best matches overall, and are they spread over many jobs or piled onto a few?
--     (KPIs: average best-fit score across all characters, and how many different jobs are somebody's best match.)
WITH best AS (
    SELECT character_key, job_key, job_fit_score,
           ROW_NUMBER() OVER (PARTITION BY character_key
                              ORDER BY job_fit_score DESC, job_key) AS rn
    FROM fact_job_fit
)
SELECT COUNT(*)                        AS n_characters,
       ROUND(AVG(job_fit_score), 1)    AS avg_best_fit_score,
       COUNT(DISTINCT job_key)         AS distinct_best_jobs
FROM best
WHERE rn = 1;
