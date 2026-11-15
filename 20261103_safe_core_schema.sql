-- PROPOSAL ONLY: Sri Madhuram Family Restaurant core Supabase schema.
-- Do not run until the preflight results, existing policies, and refund policy
-- have been reviewed by the project owner. This file is outside migrations/
-- so automated migration runners will not apply it.
--
-- This migration does not insert restaurant/menu seed data, delete rows,
-- modify Supabase Auth settings, or implement cancellation/refund decisions.
-- It intentionally replaces only the two API RPCs defined below with
-- non-destructive implementations. The existing cancellation RPC is untouched.
-- IMPORTANT: api.js and 20261101000000_order_cancellations.sql already contain
-- a 10% delivery-stage food deduction. This proposal does not approve or alter it.

-- READ-ONLY PRE-FLIGHT INVENTORY
-- Save the row-count results below and compare with the post-migration counts.
select
    table_name,
    to_regclass(format('public.%I', table_name)) is not null as exists
from (values
    ('profiles'), ('menu_items'), ('posters'), ('restaurant_settings'),
    ('orders'), ('order_items')
) as required(table_name)
order by table_name;

select table_name, ordinal_position, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = any (array[
      'profiles', 'menu_items', 'posters', 'restaurant_settings', 'orders',
      'order_items'
  ])
order by table_name, ordinal_position;

select
    conrelid::regclass as table_name,
    conname as constraint_name,
    contype as constraint_type,
    pg_get_constraintdef(oid, true) as definition
from pg_constraint
where conrelid in (
    to_regclass('public.profiles'),
    to_regclass('public.menu_items'),
    to_regclass('public.posters'),
    to_regclass('public.restaurant_settings'),
    to_regclass('public.orders'),
    to_regclass('public.order_items')
)
order by table_name, constraint_name;

select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename = any (array[
      'profiles', 'menu_items', 'posters', 'restaurant_settings', 'orders',
      'order_items'
  ])
order by tablename, policyname;

select
    p.oid::regprocedure as function_signature,
    language_row.lanname as language,
    p.prosecdef as security_definer,
    p.proacl as access_control_list,
    pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_language language_row on language_row.oid = p.prolang
where n.nspname = 'public'
  and p.proname = any (array[
      'create_customer_order', 'replace_posters', 'replace_menu_items',
      'cancel_customer_order', 'create_profile_for_auth_user'
  ])
order by p.proname, p.oid::regprocedure::text;

select
    trigger_schema.nspname as schema_name,
    table_class.relname as table_name,
    trigger_row.tgname as trigger_name,
    trigger_row.tgenabled as trigger_enabled,
    trigger_row.tgfoid::regprocedure as trigger_function,
    pg_get_triggerdef(trigger_row.oid, true) as trigger_definition
from pg_trigger trigger_row
join pg_class table_class on table_class.oid = trigger_row.tgrelid
join pg_namespace trigger_schema on trigger_schema.oid = table_class.relnamespace
where not trigger_row.tgisinternal
  and (
      (trigger_schema.nspname = 'auth' and table_class.relname = 'users')
      or (trigger_schema.nspname = 'public' and table_class.relname = 'profiles')
  )
order by schema_name, table_name, trigger_name;

select
    table_name,
    coalesce((xpath('/row/count/text()', query_to_xml(
        format('select count(*) as count from public.%I', table_name),
        false, true, ''
    )))[1]::text, '0')::bigint as row_count
from (values ('menu_items'), ('posters')) as data_tables(table_name)
where to_regclass(format('public.%I', table_name)) is not null
order by table_name;

-- MIGRATION
begin;

-- Fail closed rather than silently retain an unknown permissive policy, change
-- a non-table object, or grant browser roles direct write access.
do $preflight$
begin
    if to_regclass('auth.users') is null
       or to_regprocedure('auth.uid()') is null
       or to_regprocedure('auth.jwt()') is null then
        raise exception 'Supabase Auth prerequisites are missing; no schema changes were applied.';
    end if;

    if not exists (select 1 from pg_roles where rolname = 'anon')
       or not exists (select 1 from pg_roles where rolname = 'authenticated')
       or not exists (select 1 from pg_roles where rolname = 'service_role') then
        raise exception 'Expected Supabase database roles are missing; no schema changes were applied.';
    end if;

    if exists (
        select 1
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname = any (array[
              'profiles', 'menu_items', 'posters', 'restaurant_settings',
              'orders', 'order_items'
          ])
          and c.relkind not in ('r', 'p')
    ) then
        raise exception 'A target name is already used by a non-table object; inspect it before continuing.';
    end if;

    if exists (
        select 1
        from pg_policies
        where schemaname = 'public'
          and tablename = any (array[
              'profiles', 'menu_items', 'posters', 'restaurant_settings',
              'orders', 'order_items'
          ])
    ) then
        raise exception 'Policies already exist on a target table. Review the read-only policy inventory and resolve them explicitly; this migration will not drop or override policies.';
    end if;

    if exists (
        select 1
        from pg_constraint
        where conrelid = to_regclass('public.orders')
          and contype = 'c'
          and pg_get_constraintdef(oid, true) ilike '%status%'
          and pg_get_constraintdef(oid, true) not ilike '%cancelled%'
    ) then
        raise exception 'An existing orders status constraint does not permit Cancelled. Review it explicitly; this migration will not replace constraints.';
    end if;

    if to_regprocedure('public.cancel_customer_order(uuid,text,text,text)') is null then
        raise exception 'The API cancellation RPC is missing. This proposal will not create cancellation/refund logic; obtain owner approval and prepare that separately.';
    end if;

    if has_function_privilege(
           'anon',
           to_regprocedure('public.cancel_customer_order(uuid,text,text,text)'),
           'EXECUTE'
       )
       or has_function_privilege(
           'authenticated',
           to_regprocedure('public.cancel_customer_order(uuid,text,text,text)'),
           'EXECUTE'
       )
       or not has_function_privilege(
           'service_role',
           to_regprocedure('public.cancel_customer_order(uuid,text,text,text)'),
           'EXECUTE'
       ) then
        raise exception 'The existing cancellation RPC grants are not service-role-only. Review them explicitly; this proposal will not change the function or its grants.';
    end if;

end;
$preflight$;

create table if not exists public.profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    email text not null unique,
    full_name text not null default '',
    phone text unique,
    role text not null default 'customer'
        check (role in ('customer', 'admin')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.menu_items (
    id bigint generated by default as identity primary key,
    name text not null,
    category text not null,
    price numeric(10, 2) not null check (price > 0),
    image_url text not null,
    description text not null default '',
    is_available boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.posters (
    id bigint generated by default as identity primary key,
    title text not null,
    description text not null default '',
    category text not null default '',
    image_url text not null,
    is_published boolean not null default true,
    expires_at date,
    button_label text not null default '',
    button_url text not null default '',
    created_at timestamptz not null default now()
);

create table if not exists public.restaurant_settings (
    id text primary key default 'default',
    restaurant_name text not null,
    phone text not null default '',
    email text not null default '',
    address text not null default '',
    opening_hours text not null default '',
    delivery_fee numeric(10, 2) not null
        check (delivery_fee >= 0),
    tax_rate numeric(5, 4) not null
        check (tax_rate >= 0 and tax_rate <= 1),
    updated_at timestamptz not null default now()
);

create table if not exists public.orders (
    id text primary key,
    user_id uuid references public.profiles (id) on delete set null,
    name text not null,
    phone text not null,
    order_type text not null default 'Delivery',
    total numeric(10, 2) not null check (total > 0),
    payment_method text not null check (payment_method in ('upi', 'cod')),
    status text not null default 'Pending'
        check (status in (
            'Pending', 'Approved', 'Cooking', 'Out for Delivery',
            'Delivered', 'Cancelled'
        )),
    address text not null,
    created_at timestamptz not null default now(),
    legacy_data jsonb,
    location_latitude double precision,
    location_longitude double precision,
    location_accuracy_m double precision,
    location_captured_at timestamptz,
    food_subtotal numeric(10, 2),
    delivery_charge numeric(10, 2),
    payment_status text,
    paid_amount numeric(10, 2),
    razorpay_order_id text,
    razorpay_payment_id text,
    cancelled_at timestamptz,
    cancellation_reason text,
    cancellation_policy text,
    food_making_deduction numeric(10, 2),
    delivery_deduction numeric(10, 2),
    refund_amount numeric(10, 2),
    refund_status text,
    razorpay_refund_id text
);

create table if not exists public.order_items (
    id bigint generated by default as identity primary key,
    order_id text not null references public.orders (id) on delete cascade,
    menu_item_id bigint references public.menu_items (id) on delete set null,
    item_name text not null,
    quantity integer not null check (quantity between 1 and 100),
    unit_price numeric(10, 2) not null check (unit_price > 0),
    unique (order_id, item_name)
);

-- Add only absent order columns. No defaults are applied to existing rows.
alter table public.orders
    add column if not exists location_latitude double precision,
    add column if not exists location_longitude double precision,
    add column if not exists location_accuracy_m double precision,
    add column if not exists location_captured_at timestamptz,
    add column if not exists food_subtotal numeric(10, 2),
    add column if not exists delivery_charge numeric(10, 2),
    add column if not exists payment_status text,
    add column if not exists paid_amount numeric(10, 2),
    add column if not exists razorpay_order_id text,
    add column if not exists razorpay_payment_id text,
    add column if not exists cancelled_at timestamptz,
    add column if not exists cancellation_reason text,
    add column if not exists cancellation_policy text,
    add column if not exists food_making_deduction numeric(10, 2),
    add column if not exists delivery_deduction numeric(10, 2),
    add column if not exists refund_amount numeric(10, 2),
    add column if not exists refund_status text,
    add column if not exists razorpay_refund_id text;

-- Do not silently accept a partial/incompatible pre-existing table.
do $schema_check$
declare
    v_missing text;
begin
    select string_agg(format('%s.%s', expected.table_name, expected.column_name), ', ' order by expected.table_name, expected.column_name)
    into v_missing
    from (values
        ('profiles', 'id'), ('profiles', 'email'), ('profiles', 'full_name'),
        ('profiles', 'phone'), ('profiles', 'role'), ('profiles', 'created_at'),
        ('profiles', 'updated_at'),
        ('menu_items', 'id'), ('menu_items', 'name'), ('menu_items', 'category'),
        ('menu_items', 'price'), ('menu_items', 'image_url'),
        ('menu_items', 'description'), ('menu_items', 'is_available'),
        ('menu_items', 'created_at'), ('menu_items', 'updated_at'),
        ('posters', 'id'), ('posters', 'title'), ('posters', 'description'),
        ('posters', 'category'), ('posters', 'image_url'),
        ('posters', 'is_published'), ('posters', 'expires_at'),
        ('posters', 'button_label'), ('posters', 'button_url'),
        ('posters', 'created_at'),
        ('restaurant_settings', 'id'), ('restaurant_settings', 'restaurant_name'),
        ('restaurant_settings', 'phone'), ('restaurant_settings', 'email'),
        ('restaurant_settings', 'address'), ('restaurant_settings', 'opening_hours'),
        ('restaurant_settings', 'delivery_fee'), ('restaurant_settings', 'tax_rate'),
        ('restaurant_settings', 'updated_at'),
        ('orders', 'id'), ('orders', 'user_id'), ('orders', 'name'),
        ('orders', 'phone'), ('orders', 'order_type'), ('orders', 'total'),
        ('orders', 'payment_method'), ('orders', 'status'), ('orders', 'address'),
        ('orders', 'created_at'), ('orders', 'legacy_data'),
        ('orders', 'location_latitude'), ('orders', 'location_longitude'),
        ('orders', 'location_accuracy_m'), ('orders', 'location_captured_at'),
        ('orders', 'food_subtotal'), ('orders', 'delivery_charge'),
        ('orders', 'payment_status'), ('orders', 'paid_amount'),
        ('orders', 'razorpay_order_id'), ('orders', 'razorpay_payment_id'),
        ('orders', 'cancelled_at'), ('orders', 'cancellation_reason'),
        ('orders', 'cancellation_policy'), ('orders', 'food_making_deduction'),
        ('orders', 'delivery_deduction'), ('orders', 'refund_amount'),
        ('orders', 'refund_status'), ('orders', 'razorpay_refund_id'),
        ('order_items', 'id'), ('order_items', 'order_id'),
        ('order_items', 'menu_item_id'), ('order_items', 'item_name'),
        ('order_items', 'quantity'), ('order_items', 'unit_price')
    ) as expected(table_name, column_name)
    left join information_schema.columns actual
      on actual.table_schema = 'public'
     and actual.table_name = expected.table_name
     and actual.column_name = expected.column_name
    where actual.column_name is null;

    if v_missing is not null then
        raise exception 'Required API columns are missing: %. Review the schema before retrying.', v_missing;
    end if;
end;
$schema_check$;

-- Confirm pre-existing tables have the same key relationships as newly
-- created tables. Missing constraints are reported instead of being replaced
-- or added against unreviewed existing data.
do $integrity_check$
declare
    v_missing text;
begin
    select string_agg(format('%s primary key (%s)', expected.table_name, expected.column_name), ', ')
    into v_missing
    from (values
        ('profiles', 'id'),
        ('menu_items', 'id'),
        ('posters', 'id'),
        ('restaurant_settings', 'id'),
        ('orders', 'id'),
        ('order_items', 'id')
    ) as expected(table_name, column_name)
    where not exists (
        select 1
        from pg_constraint constraint_row
        join pg_attribute attribute_row
          on attribute_row.attrelid = constraint_row.conrelid
         and attribute_row.attname = expected.column_name
         and not attribute_row.attisdropped
        where constraint_row.conrelid =
                  to_regclass(format('public.%I', expected.table_name))
          and constraint_row.contype = 'p'
          and array_length(constraint_row.conkey, 1) = 1
          and constraint_row.conkey[1] = attribute_row.attnum
    );

    if v_missing is not null then
        raise exception 'Required primary keys are missing: %. Review the existing schema before retrying.', v_missing;
    end if;

    select string_agg(
        format('%s.%s -> %s.%s (%s)', expected.table_name, expected.column_name,
               expected.foreign_schema || '.' || expected.foreign_table,
               expected.foreign_column, expected.delete_action),
        ', '
    )
    into v_missing
    from (values
        ('profiles', 'id', 'auth', 'users', 'id', 'c'),
        ('orders', 'user_id', 'public', 'profiles', 'id', 'n'),
        ('order_items', 'order_id', 'public', 'orders', 'id', 'c'),
        ('order_items', 'menu_item_id', 'public', 'menu_items', 'id', 'n')
    ) as expected(
        table_name, column_name, foreign_schema, foreign_table,
        foreign_column, delete_action
    )
    where not exists (
        select 1
        from pg_constraint constraint_row
        join pg_attribute source_column
          on source_column.attrelid = constraint_row.conrelid
         and source_column.attname = expected.column_name
         and not source_column.attisdropped
        join pg_attribute target_column
          on target_column.attrelid = constraint_row.confrelid
         and target_column.attname = expected.foreign_column
         and not target_column.attisdropped
        where constraint_row.conrelid =
                  to_regclass(format('public.%I', expected.table_name))
          and constraint_row.confrelid =
                  to_regclass(format('%I.%I', expected.foreign_schema, expected.foreign_table))
          and constraint_row.contype = 'f'
          and constraint_row.confdeltype::text = expected.delete_action
          and array_length(constraint_row.conkey, 1) = 1
          and constraint_row.conkey[1] = source_column.attnum
          and array_length(constraint_row.confkey, 1) = 1
          and constraint_row.confkey[1] = target_column.attnum
    );

    if v_missing is not null then
        raise exception 'Required foreign keys are missing or differ: %. Review existing data and constraints before retrying.', v_missing;
    end if;

    select string_agg(
        format('%s unique (%s)', expected.table_name, expected.columns),
        ', '
    )
    into v_missing
    from (values
        ('profiles', 'email', 'single'),
        ('profiles', 'phone', 'single'),
        ('order_items', 'order_id, item_name', 'order_item')
    ) as expected(table_name, columns, key_kind)
    where not exists (
        select 1
        from pg_constraint constraint_row
        where constraint_row.conrelid =
                  to_regclass(format('public.%I', expected.table_name))
          and constraint_row.contype = 'u'
          and (
              (
                  expected.key_kind = 'single'
                  and array_length(constraint_row.conkey, 1) = 1
                  and constraint_row.conkey[1] = (
                      select attribute_row.attnum
                      from pg_attribute attribute_row
                      where attribute_row.attrelid = constraint_row.conrelid
                        and attribute_row.attname = expected.columns
                        and not attribute_row.attisdropped
                  )
              )
              or (
                  expected.key_kind = 'order_item'
                  and array_length(constraint_row.conkey, 1) = 2
                  and constraint_row.conkey = array[
                      (
                          select attribute_row.attnum
                          from pg_attribute attribute_row
                          where attribute_row.attrelid = constraint_row.conrelid
                            and attribute_row.attname = 'order_id'
                            and not attribute_row.attisdropped
                      ),
                      (
                          select attribute_row.attnum
                          from pg_attribute attribute_row
                          where attribute_row.attrelid = constraint_row.conrelid
                            and attribute_row.attname = 'item_name'
                            and not attribute_row.attisdropped
                      )
                  ]::smallint[]
              )
          )
    );

    if v_missing is not null then
        raise exception 'Required uniqueness constraints are missing: %. Review existing rows before retrying.', v_missing;
    end if;
end;
$integrity_check$;

create index if not exists orders_user_id_created_at_idx
    on public.orders (user_id, created_at desc);
create index if not exists order_items_order_id_idx
    on public.order_items (order_id);
create unique index if not exists orders_razorpay_order_id_safe_uidx
    on public.orders (razorpay_order_id)
    where razorpay_order_id is not null;
create unique index if not exists orders_razorpay_payment_id_safe_uidx
    on public.orders (razorpay_payment_id)
    where razorpay_payment_id is not null;
create unique index if not exists orders_razorpay_refund_id_safe_uidx
    on public.orders (razorpay_refund_id)
    where razorpay_refund_id is not null;

-- Keep the existing Auth/OTP configuration unchanged. This trigger only
-- creates a customer profile for future Auth users; it does not backfill users.
do $profile_function_setup$
declare
    v_security_definer boolean;
begin
    if to_regprocedure('public.create_profile_for_auth_user()') is null then
        execute $create_profile_function$
            create function public.create_profile_for_auth_user()
            returns trigger
            language plpgsql
            security definer
            set search_path = ''
            as $profile_trigger$
            begin
                insert into public.profiles (id, email, full_name, phone)
                values (
                    new.id,
                    lower(coalesce(new.email, '')),
                    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
                    nullif(new.raw_user_meta_data ->> 'phone', '')
                )
                on conflict (id) do nothing;
                return new;
            end;
            $profile_trigger$;
        $create_profile_function$;
    else
        select p.prosecdef
        into v_security_definer
        from pg_proc p
        where p.oid = to_regprocedure('public.create_profile_for_auth_user()');
        if not coalesce(v_security_definer, false) then
            raise exception 'The existing profile trigger function is not SECURITY DEFINER; review it instead of replacing it.';
        end if;
    end if;
end;
$profile_function_setup$;

do $profile_trigger_setup$
begin
    if exists (
        select 1
        from pg_trigger
        where tgrelid = 'auth.users'::regclass
          and tgname = 'on_auth_user_created'
          and not tgisinternal
          and tgenabled <> 'O'
    ) then
        raise exception 'The existing on_auth_user_created trigger is disabled; review it instead of replacing it.';
    end if;

    if exists (
        select 1
        from pg_trigger
        where tgrelid = 'auth.users'::regclass
          and tgname = 'on_auth_user_created'
          and not tgisinternal
          and tgfoid <> to_regprocedure('public.create_profile_for_auth_user()')
    ) then
        raise exception 'The existing on_auth_user_created trigger points to a different function; review it instead of replacing it.';
    end if;

    if not exists (
        select 1
        from pg_trigger
        where tgrelid = 'auth.users'::regclass
          and tgname = 'on_auth_user_created'
          and not tgisinternal
    ) then
        create trigger on_auth_user_created
            after insert on auth.users
            for each row execute function public.create_profile_for_auth_user();
    end if;
end;
$profile_trigger_setup$;

revoke all on function public.create_profile_for_auth_user()
    from public, anon, authenticated;

-- API-compatible poster upsert. Omitted posters are deliberately left as-is:
-- no row is deleted or unpublished by a partial/empty request.
create or replace function public.replace_posters(p_posters jsonb)
returns void
language plpgsql
security invoker
set search_path = ''
as $replace_posters$
declare
    v_sequence text;
    v_sequence_last bigint;
    v_max_id bigint;
begin
    if (auth.jwt() ->> 'role') is distinct from 'service_role' then
        raise exception 'Not authorized.';
    end if;
    if jsonb_typeof(p_posters) is distinct from 'array'
       or jsonb_array_length(p_posters) > 100 then
        raise exception 'Poster payload must be an array of at most 100 records.';
    end if;

    if exists (
        select 1
        from jsonb_to_recordset(p_posters) as incoming(
            id bigint, title text, description text, category text, image text,
            is_published boolean, expires_at date, button_label text,
            button_url text
        )
        where incoming.id is null or incoming.id <= 0
           or incoming.title is null or length(btrim(incoming.title)) not between 1 and 100
           or incoming.image is null
    ) then
        raise exception 'Poster payload contains invalid records.';
    end if;

    if exists (
        select incoming.id
        from jsonb_to_recordset(p_posters) as incoming(
            id bigint, title text, description text, category text, image text,
            is_published boolean, expires_at date, button_label text,
            button_url text
        )
        group by incoming.id
        having count(*) > 1
    ) then
        raise exception 'Poster payload contains duplicate IDs.';
    end if;

    insert into public.posters (
        id, title, description, category, image_url, is_published,
        expires_at, button_label, button_url
    )
    select
        incoming.id,
        incoming.title,
        coalesce(incoming.description, ''),
        coalesce(incoming.category, ''),
        incoming.image,
        coalesce(incoming.is_published, true),
        incoming.expires_at,
        coalesce(incoming.button_label, ''),
        coalesce(incoming.button_url, '')
    from jsonb_to_recordset(p_posters) as incoming(
        id bigint, title text, description text, category text, image text,
        is_published boolean, expires_at date, button_label text,
        button_url text
    )
    on conflict (id) do update set
        title = excluded.title,
        description = excluded.description,
        category = excluded.category,
        image_url = excluded.image_url,
        is_published = excluded.is_published,
        expires_at = excluded.expires_at,
        button_label = excluded.button_label,
        button_url = excluded.button_url;

    select max(id) into v_max_id from public.posters;
    v_sequence := pg_catalog.pg_get_serial_sequence('public.posters', 'id');
    if v_sequence is not null and v_max_id is not null then
        execute format('select last_value from %s', v_sequence::regclass)
            into v_sequence_last;
        if v_max_id > v_sequence_last then
            perform pg_catalog.setval(v_sequence::regclass, v_max_id, true);
        end if;
    end if;
end;
$replace_posters$;

-- This RPC matches api.js's 13-argument create_customer_order call. It uses
-- live menu/settings rows and fails if settings are absent; it inserts no seeds.
create or replace function public.create_customer_order(
    p_user_id uuid,
    p_name text,
    p_phone text,
    p_address text,
    p_payment_method text,
    p_items jsonb,
    p_location_latitude double precision,
    p_location_longitude double precision,
    p_location_accuracy_m double precision,
    p_location_captured_at timestamptz,
    p_paid_amount numeric,
    p_razorpay_order_id text,
    p_razorpay_payment_id text
)
returns text
language plpgsql
security invoker
set search_path = ''
as $create_customer_order$
declare
    v_order_id text;
    v_subtotal numeric(10, 2);
    v_item_count integer;
    v_distinct_count integer;
    v_input_count integer;
    v_tax_rate numeric(5, 4);
    v_delivery_fee numeric(10, 2);
    v_total numeric(10, 2);
begin
    if (auth.jwt() ->> 'role') is distinct from 'service_role' then
        raise exception 'Not authorized.';
    end if;
    if p_user_id is null
       or p_name is null or length(btrim(p_name)) not between 1 and 100
       or p_phone is null or length(btrim(p_phone)) not between 7 and 20
       or p_address is null or length(btrim(p_address)) not between 1 and 500
       or p_payment_method is null
       or p_payment_method not in ('upi', 'cod')
       or p_paid_amount is null or p_paid_amount < 0
       or jsonb_typeof(p_items) is distinct from 'array'
       or jsonb_array_length(p_items) not between 1 and 50 then
        raise exception 'Order details are invalid.';
    end if;

    if (
        (
            p_location_latitude is null
            and p_location_longitude is null
            and p_location_accuracy_m is null
            and p_location_captured_at is null
        )
        or (
            p_location_latitude between -90 and 90
            and p_location_longitude between -180 and 180
            and p_location_accuracy_m > 0
            and p_location_accuracy_m <= 100000
            and p_location_captured_at is not null
        )
    ) is not true then
        raise exception 'Order location details are invalid.';
    end if;

    if (p_payment_method = 'upi'
        and (p_paid_amount <= 0 or p_razorpay_order_id is null
             or p_razorpay_payment_id is null))
       or (p_payment_method = 'cod'
        and (p_paid_amount <> 0 or p_razorpay_order_id is not null
             or p_razorpay_payment_id is not null)) then
        raise exception 'Payment details are invalid.';
    end if;

    select count(*), count(distinct incoming.menu_item_id),
           coalesce(sum(menu.price * incoming.quantity), 0)
    into v_item_count, v_distinct_count, v_subtotal
    from jsonb_to_recordset(p_items) as incoming(
        menu_item_id bigint, quantity integer
    )
    join public.menu_items as menu
      on menu.id = incoming.menu_item_id
     and menu.is_available
    where incoming.quantity between 1 and 100;

    select count(*) into v_input_count
    from jsonb_to_recordset(p_items) as incoming(
        menu_item_id bigint, quantity integer
    );

    if v_input_count = 0 or v_item_count <> v_input_count
       or v_distinct_count <> v_input_count then
        raise exception 'One or more order items are invalid or unavailable.';
    end if;

    select delivery_fee, tax_rate
    into v_delivery_fee, v_tax_rate
    from public.restaurant_settings
    where id = 'default';

    if not found then
        raise exception 'Restaurant settings are not configured; no order was placed.';
    end if;

    v_total := round(v_subtotal * (1 + v_tax_rate) + v_delivery_fee);
    if p_payment_method = 'upi' and p_paid_amount <> v_total then
        raise exception 'The verified payment amount does not match the order total.';
    end if;

    v_order_id := 'ORD-' || upper(replace(pg_catalog.gen_random_uuid()::text, '-', ''));

    insert into public.orders (
        id, user_id, name, phone, order_type, total, payment_method, status,
        address, location_latitude, location_longitude, location_accuracy_m,
        location_captured_at, food_subtotal, delivery_charge, payment_status,
        paid_amount, razorpay_order_id, razorpay_payment_id, refund_status
    )
    values (
        v_order_id, p_user_id, btrim(p_name), btrim(p_phone), 'Delivery',
        v_total, p_payment_method, 'Pending', btrim(p_address),
        p_location_latitude, p_location_longitude, p_location_accuracy_m,
        p_location_captured_at, v_subtotal, v_delivery_fee,
        case when p_payment_method = 'upi' then 'paid' else 'unpaid' end,
        p_paid_amount, p_razorpay_order_id, p_razorpay_payment_id, 'not_requested'
    );

    insert into public.order_items (
        order_id, menu_item_id, item_name, quantity, unit_price
    )
    select v_order_id, menu.id, menu.name, incoming.quantity, menu.price
    from jsonb_to_recordset(p_items) as incoming(
        menu_item_id bigint, quantity integer
    )
    join public.menu_items as menu
      on menu.id = incoming.menu_item_id
     and menu.is_available;

    return v_order_id;
end;
$create_customer_order$;

revoke all on function public.replace_posters(jsonb)
    from public, anon, authenticated;
grant execute on function public.replace_posters(jsonb) to service_role;

revoke all on function public.create_customer_order(
    uuid, text, text, text, text, jsonb, double precision, double precision,
    double precision, timestamptz, numeric, text, text
) from public, anon, authenticated;
grant execute on function public.create_customer_order(
    uuid, text, text, text, text, jsonb, double precision, double precision,
    double precision, timestamptz, numeric, text, text
) to service_role;

alter table public.profiles enable row level security;
alter table public.menu_items enable row level security;
alter table public.posters enable row level security;
alter table public.restaurant_settings enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

create policy "Profiles select own row"
    on public.profiles for select to authenticated
    using ((select auth.uid()) = id);

create policy "Public select available menu"
    on public.menu_items for select to anon, authenticated
    using (is_available);

create policy "Public select published posters"
    on public.posters for select to anon, authenticated
    using (is_published and (expires_at is null or expires_at >= current_date));

create policy "Public select default restaurant settings"
    on public.restaurant_settings for select to anon, authenticated
    using (id = 'default');

create policy "Customers select own orders"
    on public.orders for select to authenticated
    using ((select auth.uid()) = user_id);

create policy "Customers select own order items"
    on public.order_items for select to authenticated
    using (
        exists (
            select 1
            from public.orders
            where orders.id = order_items.order_id
              and orders.user_id = (select auth.uid())
        )
    );

-- Supabase projects may have permissive default grants on public tables.
-- Remove browser/PUBLIC access first, then grant only the read paths backed
-- by the policies below. All application writes go through the server role.
revoke all on public.profiles, public.menu_items, public.posters,
    public.restaurant_settings, public.orders, public.order_items
    from public, anon, authenticated;

grant select on public.profiles, public.menu_items, public.posters,
    public.restaurant_settings, public.orders, public.order_items
    to authenticated;
grant select on public.menu_items, public.posters, public.restaurant_settings
    to anon;
grant all on public.profiles, public.menu_items, public.posters,
    public.restaurant_settings, public.orders, public.order_items
    to service_role;

-- Grant sequence access only for these identity columns, not every public
-- sequence. Dynamic quoting uses the sequence OIDs returned by PostgreSQL.
do $sequence_grants$
declare
    v_table text;
    v_sequence text;
begin
    foreach v_table in array array['menu_items', 'posters', 'order_items'] loop
        v_sequence := pg_catalog.pg_get_serial_sequence(
            format('public.%I', v_table), 'id'
        );
        if v_sequence is not null then
            execute format('grant usage, select on sequence %s to service_role',
                           v_sequence::regclass);
        end if;
    end loop;
end;
$sequence_grants$;

notify pgrst, 'reload schema';
commit;

-- POST-MIGRATION VERIFICATION (read-only)
select table_name, column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = any (array[
      'profiles', 'menu_items', 'posters', 'restaurant_settings', 'orders',
      'order_items'
  ])
order by table_name, ordinal_position;

select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename = any (array[
      'profiles', 'menu_items', 'posters', 'restaurant_settings', 'orders',
      'order_items'
  ])
order by tablename, policyname;

select
    c.relname as table_name,
    c.relrowsecurity as rls_enabled,
    c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = any (array[
      'profiles', 'menu_items', 'posters', 'restaurant_settings', 'orders',
      'order_items'
  ])
order by c.relname;

select
    conrelid::regclass as table_name,
    conname as constraint_name,
    contype as constraint_type,
    pg_get_constraintdef(oid, true) as definition
from pg_constraint
where conrelid in (
    'public.profiles'::regclass,
    'public.menu_items'::regclass,
    'public.posters'::regclass,
    'public.restaurant_settings'::regclass,
    'public.orders'::regclass,
    'public.order_items'::regclass
)
order by table_name, constraint_name;

select
    to_regprocedure('public.create_customer_order(uuid,text,text,text,text,jsonb,double precision,double precision,double precision,timestamp with time zone,numeric,text,text)') is not null
        as create_customer_order_api_signature_present,
    to_regprocedure('public.replace_posters(jsonb)') is not null
        as replace_posters_api_signature_present,
    to_regprocedure('public.cancel_customer_order(uuid,text,text,text)') is not null
        as existing_cancellation_rpc_signature_present_not_changed;

select
    p.oid::regprocedure as function_signature,
    has_function_privilege('service_role', p.oid, 'EXECUTE') as service_role_can_execute,
    has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('create_customer_order', 'replace_posters', 'cancel_customer_order')
order by p.proname, p.oid::regprocedure::text;

select
    table_name,
    has_table_privilege('anon', format('public.%I', table_name), 'SELECT') as anon_can_select,
    (
        has_table_privilege('anon', format('public.%I', table_name), 'INSERT')
        or has_table_privilege('anon', format('public.%I', table_name), 'UPDATE')
        or has_table_privilege('anon', format('public.%I', table_name), 'DELETE')
        or has_table_privilege('anon', format('public.%I', table_name), 'TRUNCATE')
    ) as anon_has_write_privileges,
    has_table_privilege('authenticated', format('public.%I', table_name), 'SELECT') as authenticated_can_select,
    (
        has_table_privilege('authenticated', format('public.%I', table_name), 'INSERT')
        or has_table_privilege('authenticated', format('public.%I', table_name), 'UPDATE')
        or has_table_privilege('authenticated', format('public.%I', table_name), 'DELETE')
        or has_table_privilege('authenticated', format('public.%I', table_name), 'TRUNCATE')
    ) as authenticated_has_write_privileges
from (values
    ('profiles'), ('menu_items'), ('posters'), ('restaurant_settings'),
    ('orders'), ('order_items')
) as target_tables(table_name)
order by table_name;

select
    table_name,
    coalesce((xpath('/row/count/text()', query_to_xml(
        format('select count(*) as count from public.%I', table_name),
        false, true, ''
    )))[1]::text, '0')::bigint as row_count
from (values ('menu_items'), ('posters')) as data_tables(table_name)
order by table_name;
