-- Star schema (Postgres) for loading the real data. Two edits to the first draft are marked PATCH 1 and PATCH 2.
-- The fit formula (tanh in v_job_fit) is unchanged.
-- Schema v2, built for the data:
--   SWCPQ: 2125 characters scored on 525 bipolar trait pairs (trait_low / trait_high)
--   O*NET: 891 jobs x 21 traits (18,711 rows)
-- Design decisions: surrogate integer key on each dimension, natural key kept
-- as a UNIQUE column; dim_onet_trait static, dim_job Type 1, dim_character Type 1.

-- ===== Dimensions =====

CREATE TABLE dim_character (
    character_key  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    character_code TEXT    NOT NULL UNIQUE,   -- natural key from SWCPQ, e.g. 'GOT/1'
    name           TEXT    NOT NULL,
    work_code      TEXT,                     -- source work/universe code, e.g. 'GOT' (optional)
    work_name      TEXT                      -- PATCH 2: readable universe name from key.js, e.g. 'Game of Thrones'
);

CREATE TABLE dim_job (
    job_key          INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title            TEXT    NOT NULL UNIQUE, -- the extract only has the work name
    onet_code        TEXT    UNIQUE,          -- O*NET-SOC code (natural key)
    job_zone         SMALLINT,
    job_family_code  TEXT
);

CREATE TABLE dim_onet_trait (                 -- static: the 21 O*NET traits
    onet_trait_key   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name             TEXT NOT NULL UNIQUE,    -- natural key
    descriptor_type  TEXT NOT NULL DEFAULT 'work_style',
    description      TEXT
);

CREATE TABLE dim_character_trait (            -- the 525 SWCPQ bipolar trait pairs
    char_trait_key   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trait_id         INTEGER NOT NULL UNIQUE, -- natural key (1..525 in the source)
    trait_low        TEXT NOT NULL,           -- low pole, e.g. 'playful'
    trait_high       TEXT NOT NULL            -- high pole, e.g. 'serious'
);

-- ===== Facts =====

-- Character scores (replaces the old character_trait bridge: now a real measure)
CREATE TABLE fact_character_trait_score (
    character_key   INTEGER NOT NULL REFERENCES dim_character,
    char_trait_key  INTEGER NOT NULL REFERENCES dim_character_trait,
    -- position between the low pole (0) and the high pole (max)
    -- scale checked on the data: scores run from 1 to 100
    score           NUMERIC(5,2) NOT NULL CHECK (score BETWEEN 0 AND 100),
    PRIMARY KEY (character_key, char_trait_key)      -- grain: character x trait pair
);
CREATE INDEX idx_char_score_trait ON fact_character_trait_score (char_trait_key);

CREATE TABLE fact_job_trait_importance (
    job_key         INTEGER NOT NULL REFERENCES dim_job,
    onet_trait_key  INTEGER NOT NULL REFERENCES dim_onet_trait,
    -- PATCH 1: the real O*NET file has negative Work Styles Impact values (min -1.42, max 3.0),
    -- so the old check (importance >= 0) rejected 1,983 rows. -3..3 is a loose sanity bound (assumption).
    importance      NUMERIC NOT NULL CHECK (importance BETWEEN -3 AND 3),
    PRIMARY KEY (job_key, onet_trait_key)            -- grain: job x O*NET trait
);

-- Similarity of each O*NET trait to BOTH poles of each SWCPQ pair,
-- because the pairs are bipolar and the high pole is not always the "positive" one.
CREATE TABLE fact_trait_similarity (
    onet_trait_key  INTEGER NOT NULL REFERENCES dim_onet_trait,
    char_trait_key  INTEGER NOT NULL REFERENCES dim_character_trait,
    sim_to_high     NUMERIC(4,3) NOT NULL CHECK (sim_to_high BETWEEN -1 AND 1),
    sim_to_low      NUMERIC(4,3) NOT NULL CHECK (sim_to_low  BETWEEN -1 AND 1),
    method          TEXT,                            -- e.g. 'word2vec cosine' + model name
    PRIMARY KEY (onet_trait_key, char_trait_key)     -- grain: O*NET trait x trait pair
);

-- =====================================================================
-- ===== Views: the similarity and fit equations =======================
-- =====================================================================
-- Order of the equations:
--   1. signed similarity   s = (sim_to_high - sim_to_low) / 2            in [-1, 1]
--   2. centered score      c = score / 50 - 1   (0-100 scale)            in [-1, 1]
--   3. trait level         level(char, O*NET trait) = AVG over the K best pairs of (s * c)
--   4. match score         match = importance * level
--   5. Job Fit Score       fit = 50 * (1 + tanh(G * SUM(match) / SUM(importance))), G = 5  in [0, 100]  (G to tune on real data)
--        0 = opposite of everything the job needs, 50 = neutral, 100 = perfect match
--   6. risk flag count     number of O*NET traits with a negative match

-- 1) Signed similarity per O*NET trait x trait pair.
--    s > 0: the O*NET trait is closer to the HIGH pole; s < 0: closer to the LOW pole.
CREATE  VIEW v_signed_similarity AS
SELECT onet_trait_key,
       char_trait_key,
       (sim_to_high - sim_to_low) / 2 AS signed_similarity
FROM fact_trait_similarity;

-- 2) For each O*NET trait, keep the K trait pairs with the highest absolute similarity.
--    K = 5 here. K = 1 would be the "highest absolute value" rule (only 21 pairs used).
CREATE  VIEW v_onet_trait_pairs AS
SELECT onet_trait_key, char_trait_key, signed_similarity
FROM (
    SELECT t.*,
           ROW_NUMBER() OVER (PARTITION BY onet_trait_key
                              ORDER BY ABS(signed_similarity) DESC, char_trait_key) AS rn
    FROM v_signed_similarity t
) ranked
WHERE rn <= 5;   -- K (number of best pairs per O*NET trait)

-- 3) Character score centered on 0: low pole = -1, middle = 0, high pole = +1.
CREATE VIEW v_character_score_centered AS
SELECT character_key,
       char_trait_key,
       score / 50.0 - 1 AS centered_score   -- scores run 0-100, so centred = score / 50 - 1
FROM fact_character_trait_score;

-- 4) Character level on each O*NET trait, in [-1, 1].
CREATE VIEW v_character_onet_level AS
SELECT c.character_key,
       p.onet_trait_key,
       AVG(p.signed_similarity * c.centered_score) AS trait_level
FROM v_onet_trait_pairs p
JOIN v_character_score_centered c USING (char_trait_key)
GROUP BY c.character_key, p.onet_trait_key;

-- 5) Merged fact: job x character x O*NET trait, with the match score.
--    About 40 million rows if fully materialized: keep it as a view and filter by job.
CREATE  VIEW v_fact_job_character_trait AS
SELECT i.job_key,
       l.character_key,
       i.onet_trait_key,
       i.importance,
       l.trait_level,
       i.importance * l.trait_level AS match_score
FROM fact_job_trait_importance i
JOIN v_character_onet_level l USING (onet_trait_key);

-- 6) Job Fit Score (0-100) and risk flag count per job x character.

CREATE VIEW v_job_fit AS
SELECT job_key,
       character_key,
       SUM(match_score)                                           AS raw_score,
       SUM(match_score) / NULLIF(SUM(importance), 0)              AS fit_ratio,
       (50 * (1 + tanh(5.0 * SUM(match_score) / NULLIF(SUM(importance), 0))))::numeric AS job_fit_score,
       COUNT(*) FILTER (WHERE match_score < 0)                    AS risk_flag_count
FROM v_fact_job_character_trait
GROUP BY job_key, character_key;
