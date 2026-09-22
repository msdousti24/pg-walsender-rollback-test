-- Publisher schema: four tables, only ONE of them published.
-- This is the common CDC shape: a consumer watches a small set of tables while
-- most write traffic goes to tables that are not part of the publication.
CREATE TABLE published_tbl (id bigserial PRIMARY KEY, payload text);
CREATE TABLE unpub_small   (id bigserial PRIMARY KEY, n int);
CREATE TABLE unpub_wide    (id bigserial PRIMARY KEY, payload text);
CREATE TABLE unpub_other   (id bigserial PRIMARY KEY, n int);

CREATE PUBLICATION pub_one FOR TABLE published_tbl;
