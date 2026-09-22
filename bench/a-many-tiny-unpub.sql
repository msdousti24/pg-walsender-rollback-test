-- Phase A: MANY transactions, each writing one tiny row to an UNPUBLISHED table.
-- Maximises transaction count per byte of WAL.
INSERT INTO unpub_small(n) VALUES (:client_id);
