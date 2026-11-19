-- One consistent, read-only view of the admitted substrate. A sampled status
-- histogram is not an exact tier count or a containment/closure check.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '20min';
SELECT public.laplace_audit_admitted('mississippi');
COMMIT;
