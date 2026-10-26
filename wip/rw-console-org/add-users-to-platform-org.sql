-- Add people to the Console's shared organisation (org 1) on op-usxpress-dev.
--
-- WHY: the Console gives every SSO user a private organisation on first sign-in,
-- and the RisingWave cluster is registered PER ORGANISATION. Rows exist in
-- public.cluster_connection_info for orgs 1-8 only, created in one batch on
-- 2026-10-06 19:02 covering every org that existed at that moment. Anyone whose
-- org was created after that sees an empty Console and a successful login.
--
-- Idris (user 6) is the only person already in org 1, which is why he never hit this.
--
-- Idempotent: the INSERT skips anyone already a member. Reversible: DELETE the
-- org_users rows and set user_default_orgs back to the person's own org id.
-- DEV ONLY. Do not run against QA or prod until the bootstrap change lands.

BEGIN;

INSERT INTO anclax.org_users (org_id, user_id, created_at, updated_at)
SELECT 1, u.id, now(), now()
FROM anclax.users u
WHERE u.name IN ('doke@usxpress.com', 'jlray@usxpress.com')
  AND NOT EXISTS (
    SELECT 1 FROM anclax.org_users ou WHERE ou.org_id = 1 AND ou.user_id = u.id);

UPDATE anclax.user_default_orgs d SET org_id = 1
FROM anclax.users u
WHERE d.user_id = u.id
  AND u.name IN ('doke@usxpress.com', 'jlray@usxpress.com');

SELECT u.id, u.name, ou.org_id AS member_of, d.org_id AS defaults_to
FROM anclax.users u
LEFT JOIN anclax.org_users ou ON ou.user_id = u.id
LEFT JOIN anclax.user_default_orgs d ON d.user_id = u.id
WHERE u.name IN ('doke@usxpress.com', 'jlray@usxpress.com')
ORDER BY u.id, ou.org_id;

COMMIT;
