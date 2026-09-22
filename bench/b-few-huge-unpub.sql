-- Phase B: FEW transactions, each writing a large amount to an UNPUBLISHED table.
-- Minimises transaction count per byte of WAL. This is the decisive phase:
--   "one count per WAL-visible transaction" predicts a small flush here
--   "one count per ~360 bytes of WAL"      predicts a large flush here
INSERT INTO unpub_wide(payload) SELECT repeat('x', 200) FROM generate_series(1, 5000);
