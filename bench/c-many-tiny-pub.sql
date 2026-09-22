-- Phase C: MANY transactions writing one tiny row to the PUBLISHED table.
-- Tests "one count per published-table transaction".
INSERT INTO published_tbl(payload) VALUES ('p');
