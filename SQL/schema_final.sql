-- =============================================================================
-- CoffeeClub Post-Migration Optimization & Analytics
-- schema_final.sql
--
-- All tasks are executed against the already-restored CoffeeClub database.
-- Run this script in order: Task 1 → Task 2 → Task 3 → Task 4.
-- Each section is self-contained and idempotent where possible.
-- =============================================================================


-- =============================================================================
-- TASK 1: OPTIMIZATION & CONSTRAINTS
-- Goal: Add PRIMARY KEY constraints, FOREIGN KEY relationships, and B-Tree
--       indexes to enforce referential integrity and keep queries fast.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1a. PRIMARY KEYS
-- After a flat-file migration, tables usually land without constraints.
-- We add them now. IF they already exist, the ALTER will fail gracefully —
-- comment out any line that throws "already exists" in your environment.
-- -----------------------------------------------------------------------------

-- customers: customer_id is the natural unique identifier for each person.
ALTER TABLE customers
    ADD CONSTRAINT pk_customers PRIMARY KEY (customer_id);

-- offers: offer_id uniquely identifies each promotion in the catalog.
ALTER TABLE offers
    ADD CONSTRAINT pk_offers PRIMARY KEY (offer_id);

-- events: event_id is a surrogate key — one row per individual event record.
-- If your migrated table does not have an event_id column, see note below.
ALTER TABLE events
    ADD CONSTRAINT pk_events PRIMARY KEY (event_id);

/*
 NOTE — if the events table has no event_id after migration, create one:

     ALTER TABLE events ADD COLUMN event_id SERIAL;
     ALTER TABLE events ADD CONSTRAINT pk_events PRIMARY KEY (event_id);

 A SERIAL column auto-generates a unique integer for every row, giving us
 the surrogate key we need without touching the business data.
*/


-- -----------------------------------------------------------------------------
-- 1b. FOREIGN KEYS
-- These enforce referential integrity:
--   • Every event must belong to a real customer  → no orphaned events
--   • Every offer-related event must reference a real offer
--
-- ON DELETE RESTRICT (the default) means you cannot delete a customer or
-- offer while events still reference them — the database protects the data.
-- -----------------------------------------------------------------------------

-- Link events → customers
ALTER TABLE events
    ADD CONSTRAINT fk_events_customer
    FOREIGN KEY (customer_id)
    REFERENCES customers (customer_id)
    ON DELETE RESTRICT;

-- Link events → offers
-- offer_id is NULL for plain "transaction" events (no offer involved),
-- so we only enforce the FK where a value is present.
ALTER TABLE events
    ADD CONSTRAINT fk_events_offer
    FOREIGN KEY (offer_id)
    REFERENCES offers (offer_id)
    ON DELETE RESTRICT;


-- -----------------------------------------------------------------------------
-- 1c. B-TREE INDEXES
-- B-Tree is PostgreSQL's default index type — optimal for equality filters
-- (WHERE customer_id = 42) and range scans (WHERE time BETWEEN 0 AND 48).
--
-- We index every column that will appear in:
--   • JOIN conditions       → customer_id, offer_id
--   • WHERE filters         → event_type, time
--   • GROUP BY aggregations → offer_id, event_type
-- -----------------------------------------------------------------------------

-- Fast customer lookup — used in nearly every analytical query
CREATE INDEX IF NOT EXISTS idx_events_customer_id
    ON events (customer_id);

-- Fast offer lookup — used for offer aggregation and completion rate queries
CREATE INDEX IF NOT EXISTS idx_events_offer_id
    ON events (offer_id);

-- Filter by event type (received / viewed / completed / transaction)
CREATE INDEX IF NOT EXISTS idx_events_event_type
    ON events (event_type);

-- Range scan on time — used in the informational offer time-window query (Task 3)
CREATE INDEX IF NOT EXISTS idx_events_time
    ON events (time);

-- Composite index: offer + event type together — covers the completion rate
-- aggregation in one index scan instead of two separate lookups
CREATE INDEX IF NOT EXISTS idx_events_offer_event_type
    ON events (offer_id, event_type);

-- Customer demographics — used in demographic reporting (Task 4)
CREATE INDEX IF NOT EXISTS idx_customers_income
    ON customers (income);

CREATE INDEX IF NOT EXISTS idx_customers_age
    ON customers (age);


-- =============================================================================
-- TASK 2: FEATURE ENGINEERING & INTEGRITY
-- Goal: Derive human-readable time features from the raw integer, add an
--       INTERVAL column, and handle the "Age 118" data quality issue.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2a. Add day and hour_of_day columns
--
-- The raw "time" column stores hours elapsed since the campaign started (0–719
-- for a 30-day campaign). Dividing by 24 gives campaign day (0–29);
-- modulo 24 gives the hour within that day (0–23).
-- -----------------------------------------------------------------------------

-- Add the new columns (no data yet, just the structure)
ALTER TABLE events
    ADD COLUMN IF NOT EXISTS day          SMALLINT,
    ADD COLUMN IF NOT EXISTS hour_of_day  SMALLINT;

-- Populate with integer division and modulo
UPDATE events
SET
    day         = time / 24,       -- e.g. time=50  → day 2  (hours 48–71)
    hour_of_day = time % 24;       -- e.g. time=50  → hour 2 (50 mod 24 = 2)


-- -----------------------------------------------------------------------------
-- 2b. Add time_interval column (INTERVAL type)
--
-- Multiplying an integer by INTERVAL '1 hour' produces a proper PostgreSQL
-- duration value. time=50 becomes '2 days 02:00:00', which is both human-
-- readable and usable in date arithmetic (e.g. start_date + time_interval).
-- -----------------------------------------------------------------------------

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS time_interval INTERVAL;

UPDATE events
SET time_interval = time * INTERVAL '1 hour';


-- -----------------------------------------------------------------------------
-- 2c. Data Quality Audit — handle "Age 118"
--
-- Age 118 is a sentinel/placeholder value used during migration to flag
-- records whose real age was missing or unknown. It is not a real age.
-- Leaving it in would inflate average age calculations and break age-bucket
-- aggregations in Task 4.
--
-- We set it to NULL, which is the correct SQL representation of "unknown".
-- NULL values are excluded from AVG(), MIN(), MAX() automatically.
-- -----------------------------------------------------------------------------

-- Confirm the problem exists first (informational — run manually if you want)
-- SELECT COUNT(*) FROM customers WHERE age = 118;

UPDATE customers
SET age = NULL
WHERE age = 118;

-- Optional: add a CHECK constraint to prevent impossible ages going forward
-- (uncomment if your data has no other outliers you haven't inspected first)
-- ALTER TABLE customers
--     ADD CONSTRAINT chk_customers_age CHECK (age IS NULL OR (age >= 18 AND age <= 100));


-- =============================================================================
-- TASK 3: ANALYTICS — OFFER AGGREGATIONS
-- Goal: Create SQL Views that summarize offer performance so non-technical
--       users can read the results without writing any SQL themselves.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3a. View: vw_offer_summary
--
-- Counts how many times each offer was received vs completed, then calculates
-- the completion rate as a percentage.
--
-- How it works:
--   • A COUNT with a FILTER clause counts only the rows where the condition
--     is true — this is cleaner than a CASE WHEN inside SUM().
--   • ROUND(..., 2) gives a tidy percentage.
--   • LEFT JOIN ensures offers that were never sent still appear in the list
--     (with 0 counts) rather than being silently excluded.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW vw_offer_summary AS
SELECT
    o.offer_id,
    o.offer_type,
    o.difficulty,
    o.reward,
    o.duration,

    -- Total times this offer was sent to customers
    COUNT(e.event_id) FILTER (WHERE e.event_type = 'offer received')    AS total_received,

    -- Total times a customer viewed the offer
    COUNT(e.event_id) FILTER (WHERE e.event_type = 'offer viewed')      AS total_viewed,

    -- Total times a customer completed the offer (BOGO / discount only;
    -- informational offers never generate a "completed" event)
    COUNT(e.event_id) FILTER (WHERE e.event_type = 'offer completed')   AS total_completed,

    -- Completion rate = completed / received, expressed as a percentage.
    -- NULLIF prevents divide-by-zero if an offer was never received.
    ROUND(
        100.0
        * COUNT(e.event_id) FILTER (WHERE e.event_type = 'offer completed')
        / NULLIF(COUNT(e.event_id) FILTER (WHERE e.event_type = 'offer received'), 0),
        2
    ) AS completion_rate_pct

FROM offers o
LEFT JOIN events e ON e.offer_id = o.offer_id
GROUP BY
    o.offer_id,
    o.offer_type,
    o.difficulty,
    o.reward,
    o.duration
ORDER BY completion_rate_pct DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 3b. View: vw_top_offers
--
-- A simplified leaderboard — the top offers by completion rate, easy for
-- a non-technical manager to read at a glance.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW vw_top_offers AS
SELECT
    offer_id,
    offer_type,
    total_received,
    total_completed,
    completion_rate_pct
FROM vw_offer_summary
ORDER BY completion_rate_pct DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- 3c. STRETCH GOAL — View: vw_informational_offer_influence
--
-- PROBLEM: Informational offers never generate an "offer completed" event,
-- so we cannot measure them the same way as BOGO/discount offers.
-- Instead, we define "influenced" as: a transaction that occurred AFTER
-- the customer viewed the informational offer AND BEFORE the offer expired
-- (viewed_time + duration hours).
--
-- HOW THE SELF-JOIN WORKS:
--   1. From the events table, pull all "offer viewed" rows for informational
--      offers → call this alias "viewed".
--   2. From the same events table, pull all "transaction" rows → alias "txn".
--   3. JOIN on the same customer, then filter WHERE txn.time is BETWEEN
--      viewed.time AND (viewed.time + offer.duration).
--   4. One transaction can only be counted once per offer (DISTINCT).
--
-- This is the time-window join described in the capstone hint.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW vw_informational_offer_influence AS
SELECT
    o.offer_id,
    o.offer_type,
    o.duration                                           AS offer_duration_hours,

    -- How many times the informational offer was viewed
    COUNT(DISTINCT viewed.event_id)                      AS total_viewed,

    -- How many distinct transactions were influenced (fell within the window)
    COUNT(DISTINCT txn.event_id)                         AS influenced_transactions,

    -- Influence rate: transactions per view (not a percentage — can exceed 1
    -- if a customer made multiple purchases during one viewed window)
    ROUND(
        1.0 * COUNT(DISTINCT txn.event_id)
            / NULLIF(COUNT(DISTINCT viewed.event_id), 0),
        2
    ) AS transactions_per_view

FROM offers o

-- Step 1: Get every "offer viewed" event for informational offers
JOIN events viewed
    ON viewed.offer_id  = o.offer_id
    AND viewed.event_type = 'offer viewed'

-- Step 2: Find transactions by the same customer within the offer window
--         txn.time must be >= when they viewed it AND
--         <= viewed_time + offer duration (still within the valid window)
LEFT JOIN events txn
    ON txn.customer_id  = viewed.customer_id
    AND txn.event_type   = 'transaction'
    AND txn.time         BETWEEN viewed.time
                             AND (viewed.time + o.duration)

WHERE o.offer_type = 'informational'

GROUP BY
    o.offer_id,
    o.offer_type,
    o.duration
ORDER BY influenced_transactions DESC;


-- =============================================================================
-- TASK 4: DEMOGRAPHIC FEATURE SCALING — BUCKETING
-- Goal: Add income_bucket and age_group columns to the customers table so
--       demographic reports can GROUP BY these labels directly.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4a. Add the new columns
-- -----------------------------------------------------------------------------

ALTER TABLE customers
    ADD COLUMN IF NOT EXISTS income_bucket VARCHAR(20),
    ADD COLUMN IF NOT EXISTS age_group     VARCHAR(20);


-- -----------------------------------------------------------------------------
-- 4b. Populate income_bucket
--
-- Thresholds are based on common business reporting conventions.
-- Every customer with a non-NULL income gets exactly one bucket.
-- NULL income stays NULL — do not assign a fake label to unknown data.
-- -----------------------------------------------------------------------------

UPDATE customers
SET income_bucket = CASE
    WHEN income IS NULL          THEN NULL
    WHEN income < 30000          THEN 'Low Income'        -- < $30k
    WHEN income < 60000          THEN 'Lower-Mid Income'  -- $30k–$59,999
    WHEN income < 80000          THEN 'Upper-Mid Income'  -- $60k–$79,999
    WHEN income >= 80000         THEN 'High Income'       -- $80k+
END;


-- -----------------------------------------------------------------------------
-- 4c. Populate age_group
--
-- Uses the cleaned age data from Task 2 (age = 118 is already NULL).
-- NULL ages remain NULL — we do not force them into a "Unknown" bucket
-- because that would make aggregations misleading.
-- Standard generational / marketing age bands are used.
-- -----------------------------------------------------------------------------

UPDATE customers
SET age_group = CASE
    WHEN age IS NULL             THEN NULL
    WHEN age < 25                THEN 'Under 25'
    WHEN age BETWEEN 25 AND 34   THEN '25–34'
    WHEN age BETWEEN 35 AND 44   THEN '35–44'
    WHEN age BETWEEN 45 AND 54   THEN '45–54'
    WHEN age BETWEEN 55 AND 64   THEN '55–64'
    WHEN age >= 65               THEN '65+'
END;


-- =============================================================================
-- VERIFICATION QUERIES
-- Run these after executing all tasks above to confirm everything worked.
-- They are SELECT-only — safe to run at any time.
-- =============================================================================

-- Check 1: Confirm constraints exist
SELECT conname, contype, conrelid::regclass AS table_name
FROM pg_constraint
WHERE conrelid::regclass::text IN ('customers', 'offers', 'events')
ORDER BY table_name, contype;

-- Check 2: Confirm indexes exist
SELECT indexname, tablename, indexdef
FROM pg_indexes
WHERE tablename IN ('customers', 'offers', 'events')
ORDER BY tablename, indexname;

-- Check 3: Confirm time feature columns were populated
SELECT
    MIN(day)          AS min_day,
    MAX(day)          AS max_day,
    MIN(hour_of_day)  AS min_hour,
    MAX(hour_of_day)  AS max_hour,
    COUNT(*)          FILTER (WHERE time_interval IS NULL) AS null_intervals
FROM events;

-- Check 4: Confirm age 118 is gone
SELECT COUNT(*) AS should_be_zero
FROM customers
WHERE age = 118;

-- Check 5: Preview offer summary view
SELECT * FROM vw_offer_summary LIMIT 10;

-- Check 6: Preview informational offer influence view
SELECT * FROM vw_informational_offer_influence;

-- Check 7: Confirm demographic buckets
SELECT income_bucket, COUNT(*) AS customer_count
FROM customers
GROUP BY income_bucket
ORDER BY income_bucket;

SELECT age_group, COUNT(*) AS customer_count
FROM customers
GROUP BY age_group
ORDER BY age_group;

-- =============================================================================
-- END OF schema_final.sql
-- =============================================================================
