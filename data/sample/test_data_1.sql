-- TEST DATA (invented) for schema_v2_draft.sql. Run it AFTER the schema, on an empty database.
-- Two jobs, three characters, two O*NET traits, three trait pairs.
-- Expected result of the final SELECT with K = 5:
--   J1 | C1 | raw  0.463 | fit 55.79 | risk 0
--   J1 | C2 | raw -0.463 | fit 44.21 | risk 2
--   J1 | C3 | raw  0.000 | fit 50.00 | risk 0
--   J2 | C1 | raw  0.398 | fit 55.69 | risk 0
--   J2 | C2 | raw -0.398 | fit 44.31 | risk 2
--   J2 | C3 | raw  0.000 | fit 50.00 | risk 0
-- C1 = calm and generous, C2 = the opposite, C3 = neutral (all scores 50).

INSERT INTO dim_character (character_code, name, work_code) VALUES ('X/1','C1','X'),('X/2','C2','X'),('X/3','C3','X');
INSERT INTO dim_job (title) VALUES ('J1'),('J2');
INSERT INTO dim_onet_trait (name) VALUES ('Cooperation'),('Self-Control');
INSERT INTO dim_character_trait (trait_id, trait_low, trait_high) VALUES (1,'selfish','generous'),(2,'hot-headed','calm'),(3,'playful','serious');
INSERT INTO fact_trait_similarity VALUES
 (1,1,0.6,-0.2,'test'),(1,2,0.2,0.1,'test'),(1,3,0.1,0.1,'test'),
 (2,1,0.1,0.0,'test'),(2,2,0.7,-0.3,'test'),(2,3,0.3,-0.1,'test');
INSERT INTO fact_character_trait_score VALUES
 (1,1,90),(1,2,80),(1,3,50),(2,1,10),(2,2,20),(2,3,50),(3,1,50),(3,2,50),(3,3,50);
INSERT INTO fact_job_trait_importance VALUES (1,1,3.0),(1,2,1.0),(2,1,0.5),(2,2,3.0);
SELECT j.title, c.name, round(raw_score,3) raw, round(job_fit_score,2) fit, risk_flag_count
FROM v_job_fit f JOIN dim_job j USING (job_key) JOIN dim_character c USING (character_key)
ORDER BY j.title, c.name;
