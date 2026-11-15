
-- Sri Madhuram Family Restaurant
-- Additional Supabase preflight inspection
-- READ ONLY: SELECT queries only.
-- Run after preflight_check.sql and before any migration.

-- 1. Existing indexes on the six application tables.
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename IN (
      'profiles',
      'menu_items',
      'posters',
      'restaurant_settings',
      'orders',
      'order_items'
  )
ORDER BY tablename, indexname;


-- 2. RLS status for the six application tables.
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN (
      'profiles',
      'menu_items',
      'posters',
      'restaurant_settings',
      'orders',
      'order_items'
  )
  AND c.relkind = 'r'
ORDER BY c.relname;


-- 3. Existing policies on target tables.
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
      'profiles',
      'menu_items',
      'posters',
      'restaurant_settings',
      'orders',
      'order_items'
  )
ORDER BY tablename, policyname;


-- 4. Existing triggers on target tables and auth.users.
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    t.tgname AS trigger_name,
    pg_get_triggerdef(t.oid, true) AS trigger_definition,
    p.proname AS function_name,
    pn.nspname AS function_schema,
    p.oid::regprocedure AS function_signature
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_proc p ON p.oid = t.tgfoid
JOIN pg_namespace pn ON pn.oid = p.pronamespace
WHERE NOT t.tgisinternal
  AND (
      (n.nspname = 'public' AND c.relname IN (
          'profiles',
          'menu_items',
          'posters',
          'restaurant_settings',
          'orders',
          'order_items'
      ))
      OR (n.nspname = 'auth' AND c.relname = 'users')
  )
ORDER BY schema_name, table_name, trigger_name;


-- 5. Existing foreign keys and check constraints.
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    con.conname AS constraint_name,
    CASE con.contype
        WHEN 'f' THEN 'FOREIGN KEY'
        WHEN 'c' THEN 'CHECK'
        WHEN 'p' THEN 'PRIMARY KEY'
        WHEN 'u' THEN 'UNIQUE'
        ELSE con.contype::text
    END AS constraint_type,
    pg_get_constraintdef(con.oid, true) AS definition
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN (
      'profiles',
      'menu_items',
      'posters',
      'restaurant_settings',
      'orders',
      'order_items'
  )
ORDER BY table_name, constraint_type, constraint_name;


-- 6. Existing RPC functions and overloaded signatures.
SELECT
    pn.nspname AS function_schema,
    p.proname AS function_name,
    p.oid::regprocedure AS function_signature,
    pg_get_function_identity_arguments(p.oid) AS identity_arguments,
    pg_get_function_result(p.oid) AS return_type,
    l.lanname AS language,
    p.prosecdef AS security_definer,
    p.provolatile AS volatility,
    p.proconfig AS function_configuration
FROM pg_proc p
JOIN pg_namespace pn ON pn.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE pn.nspname IN ('public', 'auth')
  AND p.proname IN (
      'create_customer_order',
      'cancel_customer_order',
      'replace_menu_items',
      'replace_posters'
  )
ORDER BY function_schema, function_name, function_signature;


-- 7. Existing function dependencies for the target RPCs.
SELECT DISTINCT
    source_ns.nspname AS dependent_schema,
    source_proc.proname AS dependent_function,
    source_proc.oid::regprocedure AS dependent_signature,
    referenced_ns.nspname AS referenced_schema,
    referenced_proc.proname AS referenced_function,
    referenced_proc.oid::regprocedure AS referenced_signature
FROM pg_depend d
JOIN pg_proc source_proc ON source_proc.oid = d.objid
JOIN pg_namespace source_ns ON source_ns.oid = source_proc.pronamespace
JOIN pg_proc referenced_proc ON referenced_proc.oid = d.refobjid
JOIN pg_namespace referenced_ns ON referenced_ns.oid = referenced_proc.pronamespace
WHERE source_proc.pronamespace = 'public'::regnamespace
  AND (
      source_proc.proname IN (
          'create_customer_order',
          'cancel_customer_order',
          'replace_menu_items',
          'replace_posters'
      )
      OR referenced_proc.proname IN (
          'create_customer_order',
          'cancel_customer_order',
          'replace_menu_items',
          'replace_posters'
      )
  )
ORDER BY dependent_schema, dependent_function;


-- 8. Table privileges for Supabase roles.
SELECT
    table_schema,
    table_name,
    grantee,
    privilege_type,
    is_grantable
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN (
      'profiles',
      'menu_items',
      'posters',
      'restaurant_settings',
      'orders',
      'order_items'
  )
  AND grantee IN (
      'anon',
      'authenticated',
      'service_role',
      'PUBLIC'
  )
ORDER BY table_name, grantee, privilege_type;



-- 9. Sequence privileges for Supabase roles.
SELECT
    object_schema AS sequence_schema,
    object_name AS sequence_name,
    grantee,
    privilege_type,
    is_grantable
FROM information_schema.role_usage_grants
WHERE object_schema = 'public'
  AND object_type = 'SEQUENCE'
  AND grantee IN (
      'anon',
      'authenticated',
      'service_role',
      'PUBLIC'
  )
ORDER BY object_name, grantee, privilege_type;


-- 10. Required Supabase roles and Auth helper functions.
SELECT
    EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'anon'
    ) AS anon_role_exists,
    EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'authenticated'
    ) AS authenticated_role_exists,
    EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'service_role'
    ) AS service_role_exists,
    to_regprocedure('auth.uid()') IS NOT NULL
        AS auth_uid_exists,
    to_regprocedure('auth.role()') IS NOT NULL
        AS auth_role_exists;

