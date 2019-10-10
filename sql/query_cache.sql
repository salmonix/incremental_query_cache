BEGIN transaction;


CREATE extension query_cache;

/* STRUCTURAL TESTS FOR THE EXTENSION
  - check for table structure
  - functions and their parameter signature
*/
SELECT table_name, column_name, data_type FROM information_schema.columns
WHERE table_schema = 'query_cache' ORDER BY table_name, column_name;

SELECT routines.routine_name, parameters.data_type, parameters.ordinal_position
FROM information_schema.routines
    LEFT JOIN information_schema.parameters ON routines.specific_name=parameters.specific_name
WHERE routines.specific_schema='query_cache'
ORDER BY routines.routine_name, parameters.ordinal_position;


SELECT event_object_table AS table_name, trigger_schema, trigger_name,
       string_agg(event_manipulation, ',') AS event, action_timing,
       action_condition AS condition
FROM information_schema.triggers
WHERE event_object_schema = 'query_cache' group by 1,2,3,5,6 order by table_name;


/* FUNCTIONAL TESTS FOR THE EXTENSION

PREPARATION: create the table that is the table for the query to catch and add an entry

*/


CREATE TABLE data_table( id BIGSERIAL PRIMARY KEY, last_value_ts INTEGER, the_data TEXT);
INSERT INTO data_table(last_value_ts, the_data) VALUES ( 0, 'FIRST');

-- CACHE the data and check if the expected entries are generated
SELECT * FROM query_cache.cache_query('SELECT * FROM data_table', 123,'{id}','{"invalidation": {"department" : [1,2]}}'::JSONB);
SELECT cached_table_name FROM query_cache.get_cached_query('SELECT * FROM data_table', 123);
SELECT COUNT(*)::INT FROM query_cache.cache_1;
SELECT COUNT(*) FROM query_cache.cache_invalidation WHERE entity_name = 'department';
SELECT * FROM query_cache.cache_query('SELECT * FROM data_table', 123,'{id}','{"invalidation": {"department" : [1,2,3]}}'::JSONB);

-- add a new entry with higher TS in the data_table and check the cached table if the entry is added.
INSERT INTO data_table(last_value_ts, the_data) VALUES ( 3600 ,'SECOND');


SELECT * FROM query_cache.update_cached_query('SELECT * FROM data_table WHERE last_value_ts > 0','query_cache.cache_1');

SELECT c.id cache_id, c.last_value_ts cache_ts,c.the_data cache_value,
       d.id data_id,d.last_value_ts data_ts,d.the_data data_value
  FROM query_cache.cache_1 c FULL OUTER JOIN data_table d ON c.id = d.id ORDER BY d.id;


-- INVALIDATION

SELECT * FROM query_cache.delete_invalid_cache('department',1::BIGINT);

-- after invalidation neither the cache_1 cached table, nor a corresponding entry in the cache_invalidation table,
-- nor the entry in the query_cache_metadata exists anymore.
SELECT table_name FROM information_schema.tables WHERE table_schema = 'query_cache' AND table_name = 'cache_1';
SELECT COUNT(*) FROM query_cache.cache_invalidation WHERE entity_name = 'department';
SELECT COUNT(*) FROM query_cache.get_cached_query('SELECT * FROM data_table', 123);


-- test if multi column pk parameter is correctly handled
SELECT * FROM query_cache.cache_query(
  'SELECT * FROM data_table', 123,'{id,last_value_ts}','{"invalidation": {"department" : [1,2,3]}}'::JSONB);

-- CLEAN UP
DROP extension query_cache cascade;

ROLLBACK;
