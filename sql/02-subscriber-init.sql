-- Subscriber only needs the published table. The subscription itself is created
-- by run-experiment.sh so that failures are visible rather than buried in initdb.
CREATE TABLE published_tbl (id bigint PRIMARY KEY, payload text);
