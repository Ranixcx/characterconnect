-- load_similarity.sql
-- Run AFTER load_real_data.sql, and only when /clean/similarity.csv exists.
-- Expected columns: onet_trait, trait_id, sim_to_high, sim_to_low, method   (21 x 525 = 11,025 rows)
-- If the file came from prepare_csv.py --placeholder-similarity, the method column says RANDOM-TEST:
-- those numbers are random, so anything computed from them is only a test.

TRUNCATE fact_trait_similarity;

DROP TABLE IF EXISTS stg_similarity;
CREATE TABLE stg_similarity (onet_trait TEXT, trait_id INTEGER, sim_to_high NUMERIC, sim_to_low NUMERIC, method TEXT);

\copy stg_similarity FROM '/clean/similarity.csv' CSV HEADER

INSERT INTO fact_trait_similarity (onet_trait_key, char_trait_key, sim_to_high, sim_to_low, method)
SELECT o.onet_trait_key, t.char_trait_key, s.sim_to_high, s.sim_to_low, s.method
FROM stg_similarity s
JOIN dim_onet_trait o      ON o.name = s.onet_trait
JOIN dim_character_trait t ON t.trait_id = s.trait_id;

SELECT COUNT(*) AS n_rows, 11025 AS expected, MIN(method) AS method FROM fact_trait_similarity;
