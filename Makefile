
EXTENSION = query_cache
DATA = query_cache--0.0.1.sql
REGRESS = query_cache

# postgres build stuff
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
