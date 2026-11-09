-- One consistent, read-only view of the admitted substrate. A sampled status
-- histogram is not an exact tier count or a containment/closure check.
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '20min';
SET LOCAL max_parallel_workers_per_gather = 4;
SET LOCAL work_mem = '512MB';
SET LOCAL hash_mem_multiplier = 2.0;
SET LOCAL enable_partitionwise_join = on;
SET LOCAL enable_partitionwise_aggregate = on;
SET LOCAL enable_sort = off;

WITH edge_audit AS (
    SELECT count(*) AS edges,
           count(*) FILTER (WHERE child.tier >= p.tier) AS height_violations
    FROM public.physicality p
    CROSS JOIN LATERAL unnest(public.laplace_vertex_ids(p.path)) v(id)
    LEFT JOIN public.entity child ON child.id = v.id
    WHERE p.tier > 0
), missing AS MATERIALIZED (
    SELECT v.id
    FROM public.physicality p
    CROSS JOIN LATERAL unnest(public.laplace_vertex_ids(p.path)) v(id)
    LEFT JOIN public.entity child ON child.id = v.id
    WHERE child.id IS NULL
    GROUP BY v.id
), closure_audit AS (
    SELECT count(*) AS missing_entity_rows,
           count(*) FILTER (WHERE public.laplace_codepoint(id) IS NOT NULL) AS virtual_codepoints,
           count(*) FILTER (WHERE public.laplace_codepoint(id) IS NULL) AS unresolved_references
    FROM missing
), physicality_audit AS (
    SELECT count(*) AS paths,
           count(*) FILTER (WHERE e.id IS NULL) AS paths_without_entity,
           count(*) FILTER (WHERE p.tier <> e.tier) AS path_height_mismatches
    FROM public.physicality p LEFT JOIN public.entity e ON e.id = p.entity
), tiers AS (
    SELECT tier, count(*) AS entities FROM public.entity GROUP BY tier
)
SELECT jsonb_build_object(
    'captured_at', clock_timestamp(),
    'database', current_database(),
    'server', version(),
    'extension', (SELECT extversion FROM pg_extension WHERE extname = 'laplace'),
    'tier0', public.laplace_fingerprint(),
    'highway', public.laplace_highway_fingerprint(),
    'canonical_text_probe', jsonb_build_object(
        'id', public.laplace_text_id('mississippi')::text,
        'tier', public.laplace_tier('mississippi')),
    'database_bytes', pg_database_size(current_database()),
    'entities', (SELECT coalesce(sum(entities), 0) FROM tiers),
    'maximum_tier', (SELECT max(tier) FROM tiers),
    'tiers', (SELECT coalesce(jsonb_agg(jsonb_build_object('tier', tier, 'entities', entities)
                                    ORDER BY tier), '[]'::jsonb) FROM tiers),
    'edges', (SELECT to_jsonb(edge_audit) FROM edge_audit),
    'closure', (SELECT to_jsonb(closure_audit) FROM closure_audit),
    'physicality', (SELECT to_jsonb(physicality_audit) FROM physicality_audit),
    'witnesses', (SELECT coalesce(jsonb_agg(id::text ORDER BY id), '[]'::jsonb) FROM public.witness)
);
COMMIT;
