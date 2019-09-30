# query_cache
 
## Synopsis

The query cache is an incremental cache for complex result sets that have at least one monotone incremental attribute - that is time stamp at the time of writing - and where there is no removal from the cached dataset. The cache is used in a scenario that is not write intensive, but the data sets are results of expensive computation.

## Installation

Required Pg version: 9.6+ as JSONB data type is needed.
Installation:

``` sh
$ cd queryCace/
$ make install
$ make installcheck
```
Then for the given database execute

```sql
CREATE EXTENSION query_cache;
```

Notes: The extension is written in plpgsql and has no external dependencies. The extension lives in its own query_cache schema creating its own tables.

## Concept

Compared to low level approaches, there is no heuristics to figure out how to chache and update the result set.
The client is expected to know his query and table structure, can provide the update SQL and writes a minimum boilerplate code to use the cache properly. For automated update wrap the boilerplate code into a procedure and use a cron, eg. [pg_cron](https://github.com/citusdata/pg_cron).

The cache is wrapped in a set of stored procedures serving as API. The query is on-demand updated by the client via the proper API calls. On each update the query calculates the deltas since the last call, using the incremental attibute, updates the cache and returns the table name of the cached values to the client.

### Costs

- the cost of building the cache is
  - the cost of the SQL to be cached
  - the creation of the cache table and its indices
  - writing the metadata into the internal technical metadata table
- the cost of updating the cache is
  - the access of the internal technical metadata for the cached query
  - the cost of running the SQL on the deltas
  - the update of the cache table and its indices

The aboves indicate that when the data set has many new inserts the performance drops.

## Usage

A suggested boilerplate for retrieving the cached table name is:

```python

    (table_name, last_updated,notes) = db( 'SELECT * FROM query_cache.get_cached_query(sql, groupid)' )
    if !table_name:
        (table_name, row_count,notes) = db( 'SELECT * FROM query_cache.cache_query(sql, groupid, pk_constraints::ARRAY, notes)' )
    else if last_updated > notes{update_interval}:   # optional, the client is free to decide on update.
        updated_row_count = db( 'SELECT * FROM query_cache.update_cache_query(sql_update, table_name)' )
    return table_name

```

where

- sql is the query to cache
- groupid acts like a namespace for the various queries
- pk_constraints is a (list) of columns in the result set to cache that act as pk for the returned table
- sql_update is for updating the cache
- table_name is the name of the table storing the cached result set

The first DB procedure to call, the get_cached_query() returns the cached table name, the last update as UNIX timestamp, and the notes JSON object. The client can decide if update is needed. If yes, the client must prepare the update query, possibly using the provided timestamp and/or some other custom value, possibly stored in the notes JSON object. The location where and how the condition for the difference is to be inserted into the SQL string can be identified only on the client side. Then the update_cached_query() stored procedure must be called with the update sql and the cached table name. The update_cached_query() returns the number of updated rows.

    If the get_cached_query() procedure returns nothing, the query is not yet cached. In this case the client can call the cache_query() procedure to create a cache for the sql. The procedure returns the cache table name and the number of rows inserted into the cache table.


## Cache invalidation

Currently no sophisticated method is implemented to remove entries from a cached set. However, the user can provide some identifiers that can be used to invalidate the cache. When the query is to be cached, the last parameter is a JSON object. Its top-level key can contain the invalidation credentials on the following way:

     {invalidation : { NAME : [ VALUES BIGINT ] } }


### Example

We assume that in our system there is a _department_ table storing the members of the departments. If any entity is changed then the it can potentially invalidate a cache. That likely requires a DELETE/UPDATE trigger on the _department_ table. In the example the key in the invalidation JSON object is 'department', the value is an ARRAY of primary keys of the department table.

     {invalidation : { "department" : [ 1,2,3] } }

A corresponding trigger is created on the _department_ table. On UPDATE or DELETE, the query_cache invalidation procedure is called with the parameter 'specifications' and the id of the changed or deleted entity, removing all the corresponding caches - ie. caches that are associated with the arguments passed to the query_cache API in the trigger.

```sql

CREATE OR REPLACE FUNCTION public.department_invalidate_cache_fn() RETURNS TRIGGER AS $$
BEGIN

  PERFORM * FROM query_cache.delete_invalid_cache('department',OLD.id); -- remove any cache associated with 'department' and OLD.id
  CASE TG_OP
    WHEN 'DELETE' THEN RETURN OLD;
    WHEN 'UPDATE' THEN RETURN NEW;
    ELSE RAISE EXCEPTION 'UPDATE/DELETE: query_cache.fn_query_cache_metadata_drop_cache_table() used in wrong trigger context: % ', TG_OP;
  END CASE;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER tr_department_invalidate_cache
  BEFORE UPDATE OR DELETE ON department FOR EACH ROW
  EXECUTE PROCEDURE public.department_invalidate_cache_fn();

```


## Maintenance and cache rebuild

Currently no maintenance procedures are implemented. The cache information is transparently stored in the query_cache.query_cache_metadata table.


## Implementation overview

At the time of writing each query gets an own table, regardless the size of the return set. It is planned to
store queries that return a small - eg. aggregated - result set on a different way.
The query_cache.query_cache_metadata stores the information about each cached query. The query_cache.cache_invalidation table stores information that is used to drop a cache table. The table is used by query_cache.delete_invalid_cache stored procedure.


# Licencing

The extension is released under [PostgreSQL License](Licence.md). For the quick summary of use of the license, see [this link](https%3A%2F%2Ftldrlegal.com%2Flicense%2Fpostgresql-license-%28postgresql%29).
