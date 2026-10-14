# CharacterConnect

**Matching fictional characters to real-world jobs, like a professional network for characters.**

Data Engineering course project, Assignment 1 (Data Architecture & Modeling).

> **Status: first proposal.** The pipeline runs end to end on the real data, but the character-to-job similarity values are still **random placeholders** (`method = RANDOM-TEST`). Fit scores and rankings produced today are only a test of the plumbing, not results. See [Known issues](#known-issues-and-open-decisions).

## What it does

A character is described by 525 personality scales (e.g. playful ↔ serious, scored 1 to 100). A job is described by 21 O\*NET® "work styles" (e.g. Integrity, Attention to Detail), each with an impact value for that job. We compare the two through word-embedding similarity between the personality words and the work-style names, and combine them into a **Job Fit Score from 0 to 100** for every character and job pair (50 = neutral).

Questions the model answers (see `sql/demo_queries.sql`):

1. Which jobs fit a given character best?
2. Which characters fit a given job best?
3. Which jobs come up most often as a character's best match?
4. Why is a character risky for a job (which traits count against them)?
5. Which universes produce the best applicants for a job?
6. KPIs: average best-fit score and number of distinct best-match jobs.

## Data sources

| Source | Content | Link | Licence |
|---|---|---|---|
| Open-Source Psychometrics Project, "Which Character" quiz | 2,125 scored characters x 525 bipolar trait pairs, plus character and universe names | https://openpsychometrics.org/tests/characters/data/ | CC BY-NC-SA 4.0 |
| O\*NET® 31.0 Database, Work Styles | 891 jobs x 21 work styles (Work Styles Impact, `WI`) | https://www.onetcenter.org/database.html#wv | CC BY 4.0 |

The raw files are **not stored in this repository** (size and licence terms). `notebooks/dataengproject.ipynb` shows how they were loaded and checked.

## Repository layout

```
notebooks/   dataengproject.ipynb       data exploration and first checks
scripts/     prepare_csv.py             raw files -> clean CSVs, with a data-quality report
sql/         schema_v2_for_real_data.sql   star schema (tables and views)
             load_real_data.sql            clean CSVs -> staging tables -> dimensions and facts
             load_similarity.sql           similarity table -> fact_trait_similarity
             materialize_fit.sql           stores the fit view as a table (fact_job_fit)
             demo_queries.sql              the six demo queries
data/sample/ test_data_1.sql            tiny invented dataset (3 characters, 2 jobs) to test the schema
```

## Architecture

| Stage | Where | What happens |
|---|---|---|
| Source | the two websites above | downloaded files |
| Landing | `data/raw/` (not committed) | raw files, untouched |
| Staging | `data/raw/clean/` CSVs, then `stg_*` tables in Postgres | decoded, validated, one row per character and trait; staging tables are kept |
| Production | star schema in Postgres | 4 dimensions, 3 facts, 6 views, plus the `fact_job_fit` data mart |
| Serving | SQL (`sql/demo_queries.sql`) | answers the business questions |

The steps are run by hand for now. Airflow orchestration is planned for Assignment 2.

Star schema in short:

- Dimensions: `dim_character`, `dim_job`, `dim_onet_trait`, `dim_character_trait`.
- Facts: `fact_character_trait_score` (grain: one character x one trait pair), `fact_job_trait_importance` (job x O\*NET trait), `fact_trait_similarity` (O\*NET trait x trait pair).
- Derived: views `v_*` compute the match, and `fact_job_fit` (job x character) stores the result so queries stay fast.

## How to run it

**You need:** Python 3 with pandas (`pip install pandas`), and Docker Desktop. On Windows, use `py` instead of `python`.

1. **Get the input files.** Create a folder `data/raw/` and put `key.js`, `characterScores.txt` and `work_styles.csv` in it (prepared from the two sources above, see the notebook).
2. **Clean the data** from the repository root:
   ```
   python scripts/prepare_csv.py data/raw --placeholder-similarity
   ```
   This writes `data/raw/clean/` and prints a data-quality report. The flag also creates a **random** similarity file for testing. Leave it out once the real similarity file exists.
3. **Start Postgres:**
   ```
   docker run --name charconnect -e POSTGRES_PASSWORD=pass -d postgres:16
   ```
   Wait a few seconds.
4. **Copy the files into the container:**
   ```
   docker cp sql/schema_v2_for_real_data.sql charconnect:/schema.sql
   docker cp sql/load_real_data.sql charconnect:/load.sql
   docker cp sql/load_similarity.sql charconnect:/load_sim.sql
   docker cp sql/materialize_fit.sql charconnect:/mat.sql
   docker cp sql/demo_queries.sql charconnect:/demo.sql
   docker cp data/raw/clean charconnect:/clean
   ```
5. **Build and load, in this order:**
   ```
   docker exec charconnect psql -U postgres -f /schema.sql
   docker exec charconnect psql -U postgres -f /load.sql
   docker exec charconnect psql -U postgres -f /load_sim.sql
   docker exec charconnect psql -U postgres -f /mat.sql
   ```
   `load.sql` ends with a table where `n_rows` must equal `expected` on every line. `mat.sql` ends with 1,893,375 rows (891 jobs x 2,125 characters).
6. **Run the demo queries:**
   ```
   docker exec charconnect psql -U postgres -f /demo.sql
   ```

To reload after changing the data, run `docker exec charconnect rm -rf /clean` before copying the `clean` folder again (otherwise it is nested inside the old one), then repeat steps 5 and 6. `mat.sql` must be re-run every time the data or the similarity table changes. To start from scratch: `docker rm -f charconnect`.

**Quick test with the tiny sample data** (no CSV needed): run `schema_v2_for_real_data.sql`, then `data/sample/test_data_1.sql`. It prints 6 rows for 3 invented characters and 2 jobs.

## Data-quality rules

Applied by `scripts/prepare_csv.py` and `sql/load_real_data.sql`:

- **Characters without scores are dropped:** key.js names 2,242 characters but only 2,125 have scores (117 dropped). Every scored character has a name.
- **No duplicates, no missing values** in the scores (checked: 0 duplicate codes, 0 missing cells) or in the O\*NET data (0 duplicate job and trait pairs).
- **Score range check:** scores must be between 0 and 100 (observed 1 to 100).
- **HTML entities are decoded** in names and trait words (e.g. `H&#xE9;ctor` becomes `Héctor`), and stray spaces are stripped, including a leading space in the score file's column names.
- **O\*NET `DR` rows are ignored:** only Work Styles Impact (`WI`) is used, giving 891 x 21 = 18,711 rows.
- **Negative O\*NET values are kept:** 1,983 impact values are negative (down to -1.42). They look like traits that work against a job, so the schema accepts values from -3 to 3.
- **Referential integrity:** facts are filled by joining on natural keys, and the load check confirms that no staging row is lost on the way.

## Known issues and open decisions

- **Similarity values are random placeholders** until the real table (word-embedding similarity between each O\*NET trait and each trait pair) is produced.
- **35 of the 525 trait pairs are emojis**, which word-embedding models cannot embed. They must be dropped or translated to words.
- **Fit formula not final:** `v_job_fit` uses a `tanh` curve, but the test file's expected values assume the linear formula `50 * (1 + sum(match) / sum(importance))`.
- **Concentration check:** with random similarity, 10 jobs take about 73% of the characters' best-match spots. Query Q3 should be re-run on the real similarity table.

## Licensing and attribution

- **Code:** no licence chosen yet.
- **Open-Source Psychometrics Project data:** credit to the Open-Source Psychometrics Project, "Statistical 'Which Character' Personality Quiz" dataset (https://openpsychometrics.org/tests/characters/data/), used under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) (attribution, non-commercial, share-alike). The data was transformed (see [Data-quality rules](#data-quality-rules)). Only short excerpts appear in the saved outputs of `notebooks/dataengproject.ipynb`; the full data and the derived tables are not redistributed here.
- **O\*NET data:** this project includes information from the [O\*NET 31.0 Database](https://www.onetcenter.org/database.html) by the U.S. Department of Labor, Employment and Training Administration (USDOL/ETA). Used under the [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) license. O\*NET® is a trademark of USDOL/ETA. The CharacterConnect project team has modified all or some of this information (only Work Styles Impact is used, and it is loaded into database tables; the changes are listed under [Data-quality rules](#data-quality-rules) and in `scripts/prepare_csv.py`). USDOL/ETA has not approved, endorsed, or tested these modifications.

## Team

Three students:

- Raphael Winttersdolf, data lead
- Joudy Souleiman, modelling lead
- Rania Chaari ([@Ranixcx](https://github.com/Ranixcx)), SQL and integration lead
