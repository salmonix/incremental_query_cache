/* QUERY CACHE

The query cache is an incremental cache for caching complex result sets
that have at least one monotone incremental attribute. We use TS as incremental attribute.
The current implementation does not delete from the cache.

*/

--SELECT create_new_schema('query_cache');

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION querycache" to load this file. \quit

--CREATE SCHEMA query_cache;

DROP TABLE IF EXISTS query_cache.query_cache_metadata CASCADE;
CREATE TABLE query_cache.query_cache_metadata (
  id serial PRIMARY KEY,
  sql_original text NOT NULL,
  last_updated_ts timestamp without time zone DEFAULT now(),
  cached_table_name text,
  pk_constraints TEXT[] NOT NULL,
  groupid BIGINT NOT NULL,
  notes   JSONB
);
COMMENT ON COLUMN query_cache.query_cache_metadata.sql_original IS 'the sql statment to be cached';
COMMENT ON COLUMN query_cache.query_cache_metadata.last_updated_ts IS 'the last update time of the cache';
COMMENT ON COLUMN query_cache.query_cache_metadata.cached_table_name IS 'the table name for the cache';
COMMENT ON COLUMN query_cache.query_cache_metadata.pk_constraints IS 'the primary key constraint column names for the cached table';
COMMENT ON COLUMN query_cache.query_cache_metadata.groupid IS 'a user provided id. used in composing the cache table name';
COMMENT ON COLUMN query_cache.query_cache_metadata.notes IS 'notes. these may possibly store invalidation arrays
, as { "invalidation" : { "XXX" : [1,2,3...n] }}';

DROP INDEX IF EXISTS ix_query_cache_metadata_pk;
CREATE UNIQUE INDEX ix_query_cache_metadata_group_sqlmd5
    ON query_cache.query_cache_metadata (groupid,md5(sql_original));


--DROP FUNCTION IF EXISTS query_cache.get_cached_query(text,bigint);
CREATE OR REPLACE FUNCTION query_cache.get_cached_query(sql text, groupid BIGINT)
RETURNS TABLE (cached_table_name TEXT, last_updated_ts INTEGER, notes JSONB)
AS $$
BEGIN
  -- we need here to extract with time zone because it is by default stored in db time zone (Berlin)
  -- and for any math we need to honor it
  RETURN QUERY EXECUTE format('SELECT cached_table_name
                ,extract(epoch FROM last_updated_ts::timestamp with time zone)::INTEGER as last_updated_ts
                ,notes
            FROM query_cache.query_cache_metadata qc
            WHERE md5(sql_original) = %L
              AND groupid = %s',
              md5(sql), groupid);
END $$ LANGUAGE plpgsql STABLE;
COMMENT ON FUNCTION query_cache.get_cached_query(text, bigint) IS
      'looks up the cached_table_name and last updated from the query_cache_metadata table';

DROP FUNCTION IF EXISTS query_cache.cache_query(text,bigint, text[],jsonb);
CREATE OR REPLACE FUNCTION query_cache.cache_query(sql_original text
                ,groupid BIGINT, pk_constraints TEXT[], notes JSONB DEFAULT NULL
                ,OUT new_cached_table_name TEXT, OUT v_cnt NUMERIC)
  AS $$
DECLARE
  cache_id BIGINT;
  inv_name TEXT;
  inv_id BIGINT;
  inv_jsonb_type BIGINT;
  --v_cnt NUMERIC;
BEGIN
  EXECUTE format('SELECT id FROM query_cache.query_cache_metadata WHERE sql_original = %L AND groupid = %s', sql_original, groupid) INTO cache_id;
  IF cache_id IS NOT null THEN -- we have a cache and re-cache means re-build.
    new_cached_table_name := 'query_cache.' || concat_ws('_', 'cache', cache_id);
    EXECUTE format('DROP TABLE IF EXISTS %s', new_cached_table_name);
    EXECUTE format('DELETE FROM query_cache.cache_invalidation WHERE cache_id = %s', cache_id);
    EXECUTE format('UPDATE query_cache.query_cache_metadata SET last_updated_ts = now(), notes = %L, pk_constraints = %L
                      WHERE id = %s', notes, pk_constraints, cache_id);
  ELSE
    EXECUTE format('INSERT INTO query_cache.query_cache_metadata
                   (sql_original,cached_table_name,pk_constraints,groupid, notes)
                    VALUES(%L,%L,%L,%L,%L) RETURNING id',
                     sql_original, NULL, pk_constraints, groupid, notes)
    INTO cache_id;
  new_cached_table_name := 'query_cache.' || concat_ws('_', 'cache', cache_id);
END IF;

  new_cached_table_name := 'query_cache.' || concat_ws('_', 'cache', cache_id);
  EXECUTE format('UPDATE query_cache.query_cache_metadata SET cached_table_name = %L WHERE id = %s'
                  ,new_cached_table_name, cache_id );

  v_cnt := 0;
  EXECUTE format('DROP TABLE IF EXISTS %s; CREATE TABLE %s AS %s'
    ,new_cached_table_name,new_cached_table_name, sql_original);
  GET DIAGNOSTICS v_cnt := ROW_COUNT;

  EXECUTE format('ALTER TABLE %s ADD PRIMARY KEY (%s)', new_cached_table_name ,array_to_string(pk_constraints,',') );

  IF notes IS NOT NULL THEN
    IF notes->'invalidation' IS NOT NULL AND jsonb_typeof(notes->'invalidation') <> 'object' THEN
      RAISE EXCEPTION 'notes->invalidation is not type of object: %', jsonb_typeof(notes->'invalidation');
    END IF;
     IF jsonb_object_keys(notes->'invalidation') IS NOT NULL THEN
      -- EXECUTE format ('SELECT id FROM query_cache.query_cache_metadata WHERE md5(sql_original) = %L AND groupid = %s',
      --        md5(sql_original), groupid) INTO cache_id;
      FOR inv_name, inv_id IN
                    SELECT d.key, jsonb_array_elements(d.value)
                    FROM jsonb_each(notes->'invalidation') d
      LOOP
        EXECUTE format('INSERT INTO query_cache.cache_invalidation(cache_id, entity_name, entity_id)
          VALUES(%s,%L,%s)',cache_id, inv_name, inv_id);
      END LOOP;
    END IF;
  END IF;
END
$$ LANGUAGE plpgsql VOLATILE;
COMMENT ON FUNCTION query_cache.cache_query(text, bigint, text [], jsonb) IS
      'creates a cached table for the provided sql query using the PK constraint columns for uniqueness.';


-- returning the cached table name
--DROP FUNCTION IF EXISTS query_cache.update_cached_query(TEXT,TEXT);
CREATE OR REPLACE FUNCTION query_cache.update_cached_query(sql_update TEXT, cached_table_name TEXT )
RETURNS NUMERIC AS $$
DECLARE
  pk_constraints TEXT[];
  groupid TEXT;
  sql_md5 TEXT;
  update_fields TEXT;
  ae TEXT;
  upsert_column_list TEXT[];
  upsert_set_conditions TEXT;
  upsert_sql TEXT;
  v_cnt NUMERIC;
  _cache_id BIGINT;

BEGIN

  EXECUTE format('SELECT a[1]::BIGINT FROM regexp_matches(%L,%L) a',cached_table_name,E'cache_(\\d+)')
     INTO _cache_id;

  EXECUTE format('SELECT pk_constraints
                  FROM query_cache.query_cache_metadata
                  WHERE id = %s', _cache_id)
    INTO pk_constraints; -- if null, the table name is wrong

  IF pk_constraints IS NULL THEN
    RAISE EXCEPTION 'Not existing table name';
  END IF;

  -- TODO: store the upsert_column_list when creating the cache
  EXECUTE format('SELECT array_agg(attname::TEXT) FROM pg_attribute
                  WHERE attrelid = %L::regclass
                    AND attname <> ALL (%L)
                    AND attnum > 0
                    AND NOT attisdropped'
                 , cached_table_name, pk_constraints)
      INTO upsert_column_list;

  v_cnt := 0;
  -- build the UPSERT for the cache using the sql_update parameter for the select
  SELECT array_to_string(array_agg( format('%s = excluded.%s ', ae.col, ae.col)),', ')
      INTO upsert_set_conditions FROM (SELECT unnest(upsert_column_list) col) ae;
  upsert_sql := format('WITH deltas AS (%s)
      INSERT INTO %s SELECT * FROM deltas
        ON CONFLICT(%s) DO UPDATE SET
        %s'
      ,sql_update,cached_table_name,array_to_string(pk_constraints,',')
      ,upsert_set_conditions);
  --RAISE WARNING '%', upsert_sql;
  EXECUTE upsert_sql;

  GET DIAGNOSTICS v_cnt := ROW_COUNT;
  EXECUTE format('UPDATE query_cache.query_cache_metadata SET last_updated_ts = now()
    WHERE id = %s', _cache_id);
  RETURN v_cnt;
END;
$$ LANGUAGE plpgsql VOLATILE;
COMMENT ON FUNCTION query_cache.update_cached_query(text, text) IS
      'updates the cache identified by table name using the update sql query returning the no of affected rows';


DROP TABLE IF EXISTS query_cache.cache_invalidation;
CREATE TABLE query_cache.cache_invalidation(
  cache_id BIGINT REFERENCES query_cache.query_cache_metadata(id) ON DELETE CASCADE,
  entity_name TEXT,
  entity_id   BIGINT
);
COMMENT ON COLUMN query_cache.cache_invalidation.cache_id IS 'the PK id of the cache metadata';
COMMENT ON COLUMN query_cache.cache_invalidation.entity_name IS 'the user provided entity name for cache invalidation';
COMMENT ON COLUMN query_cache.cache_invalidation.cache_id IS 'the user provided entity id for cache invalidation';
CREATE INDEX ix_query_cache_invalidation_pk ON query_cache.cache_invalidation(entity_name, entity_id);


--DROP FUNCTION IF EXISTS query_cache.delete_invalid_cache(TEXT, BIGINT);
CREATE OR REPLACE FUNCTION query_cache.delete_invalid_cache(inv_name TEXT, inv_id BIGINT )
RETURNS void AS $$
DECLARE
  cached_table_name TEXT;
  cache_id BIGINT;
BEGIN
  FOR cached_table_name, cache_id IN EXECUTE format('SELECT DISTINCT(cached_table_name) cached_table_name, qcm.id
    FROM query_cache.query_cache_metadata qcm, query_cache.cache_invalidation ci
    WHERE ci.entity_name = %L AND ci.entity_id = %s AND ci.cache_id = qcm.id GROUP BY cached_table_name, qcm.id'
      ,inv_name, inv_id)
      LOOP
      RAISE NOTICE 'Dropping table %',cached_table_name;
      EXECUTE 'DROP TABLE IF EXISTS '|| cached_table_name;
      --RAISE NOTICE '%', 'DELETE FROM query_cache.query_cache_metadata WHERE id = '||cache_id;
      EXECUTE 'DELETE FROM query_cache.query_cache_metadata WHERE id = '||cache_id;
    END LOOP;
END;
$$ LANGUAGE plpgsql VOLATILE;
COMMENT ON FUNCTION query_cache.delete_invalid_cache(text,bigint) IS
  'dropping the cache table and its metadata using the provided identifiers. The identifies refer to the columns in query_cache.cache_invalidation table';



-- query_cache.query_cache_metadata delete trigger
DROP FUNCTION IF EXISTS query_cache.query_cache_metadata_drop_cache_table();
CREATE OR REPLACE FUNCTION query_cache.query_cache_metadata_drop_cache_table() RETURNS TRIGGER AS $$
BEGIN
  EXECUTE format('DROP TABLE IF EXISTS %s', OLD.cached_table_name);
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION query_cache.query_cache_metadata_drop_cache_table() IS
 'trigger function to drop a cache table if a cache metadata entry is deleted';

DROP TRIGGER IF EXISTS tr_query_cache_metadata_drop_cache_table ON query_cache.query_cache_metadata;
CREATE TRIGGER tr_query_cache_metadata_drop_cache_table
  BEFORE DELETE ON query_cache.query_cache_metadata
  FOR EACH ROW
  EXECUTE PROCEDURE query_cache.query_cache_metadata_drop_cache_table();
