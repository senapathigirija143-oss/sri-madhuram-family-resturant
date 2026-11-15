-- Read-only preflight checks for supabase/COMPLETE_SETUP.sql.
-- Run this script before the consolidated setup script. It performs SELECTs
-- only and does not create temporary objects or modify application data.

-- 1. Inventory public tables/columns and the Supabase Auth user table.
select
    table_schema,
    table_name,
    ordinal_position,
    column_name,
    data_type,
    is_nullable,
    column_default
from information_schema.columns
where table_schema in ('public', 'auth')
  and (
      table_schema = 'public'
      or table_name = 'users'
  )
order by table_schema, table_name, ordinal_position;

-- 1a. Report missing application tables/columns expected by COMPLETE_SETUP.sql.
with expected(table_name, column_name) as (
    values
        ('profiles', 'id'),
        ('profiles', 'email'),
        ('profiles', 'full_name'),
        ('profiles', 'phone'),
        ('profiles', 'role'),
        ('profiles', 'created_at'),
        ('profiles', 'updated_at'),
        ('menu_items', 'id'),
        ('menu_items', 'name'),
        ('menu_items', 'category'),
        ('menu_items', 'price'),
        ('menu_items', 'image_url'),
        ('menu_items', 'description'),
        ('menu_items', 'is_available'),
        ('menu_items', 'created_at'),
        ('menu_items', 'updated_at'),
        ('posters', 'id'),
        ('posters', 'title'),
        ('posters', 'description'),
        ('posters', 'category'),
        ('posters', 'image_url'),
        ('posters', 'is_published'),
        ('posters', 'expires_at'),
        ('posters', 'button_label'),
        ('posters', 'button_url'),
        ('posters', 'created_at'),
        ('restaurant_settings', 'id'),
        ('restaurant_settings', 'restaurant_name'),
        ('restaurant_settings', 'phone'),
        ('restaurant_settings', 'email'),
        ('restaurant_settings', 'address'),
        ('restaurant_settings', 'opening_hours'),
        ('restaurant_settings', 'delivery_fee'),
        ('restaurant_settings', 'tax_rate'),
        ('restaurant_settings', 'updated_at'),
        ('orders', 'id'),
        ('orders', 'user_id'),
        ('orders', 'name'),
        ('orders', 'phone'),
        ('orders', 'order_type'),
        ('orders', 'total'),
        ('orders', 'payment_method'),
        ('orders', 'status'),
        ('orders', 'address'),
        ('orders', 'created_at'),
        ('orders', 'legacy_data'),
        ('orders', 'location_latitude'),
        ('orders', 'location_longitude'),
        ('orders', 'location_accuracy_m'),
        ('orders', 'location_captured_at'),
        ('orders', 'food_subtotal'),
        ('orders', 'delivery_charge'),
        ('orders', 'payment_status'),
        ('orders', 'paid_amount'),
        ('orders', 'razorpay_order_id'),
        ('orders', 'razorpay_payment_id'),
        ('orders', 'cancelled_at'),
        ('orders', 'cancellation_reason'),
        ('orders', 'cancellation_policy'),
        ('orders', 'food_making_deduction'),
        ('orders', 'delivery_deduction'),
        ('orders', 'refund_amount'),
        ('orders', 'refund_status'),
        ('orders', 'razorpay_refund_id'),
        ('order_items', 'id'),
        ('order_items', 'order_id'),
        ('order_items', 'menu_item_id'),
        ('order_items', 'item_name'),
        ('order_items', 'quantity'),
        ('order_items', 'unit_price')
)
select
    expected.table_name,
    expected.column_name,
    case
        when t.table_name is null then 'MISSING TABLE'
        when c.column_name is null then 'MISSING COLUMN'
        else 'present'
    end as preflight_status
from expected
left join information_schema.tables t
    on t.table_schema = 'public'
   and t.table_name = expected.table_name
   and t.table_type = 'BASE TABLE'
left join information_schema.columns c
    on c.table_schema = 'public'
   and c.table_name = expected.table_name
   and c.column_name = expected.column_name
order by expected.table_name, expected.column_name;

-- 1b. Current orders status constraint(s), including constraints with names
-- different from the one replaced by COMPLETE_SETUP.sql.
select
    conname as constraint_name,
    pg_get_constraintdef(oid, true) as definition
from pg_constraint
where conrelid = to_regclass('public.orders')
  and contype = 'c'
order by conname;

-- 2. Existing cancelled orders: missing required cancellation fields,
-- unsupported policy values, and amounts inconsistent with the script's
-- restaurant-stage/delivery-stage calculations.
select case
    when to_regclass('public.orders') is null then
        '<orders_check><status>MISSING public.orders</status></orders_check>'::xml
    when (
        select count(*)
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'orders'
          and column_name = any (array[
              'status', 'cancelled_at', 'cancellation_reason',
              'cancellation_policy', 'food_making_deduction',
              'delivery_deduction', 'refund_amount', 'paid_amount',
              'food_subtotal', 'delivery_charge'
          ])
    ) < 10 then
        '<orders_check><status>REQUIRED CANCELLATION/PAYMENT COLUMNS ARE INCOMPLETE; see inventory above</status></orders_check>'::xml
    else query_to_xml($q$
        select
            count(*) filter (where status = 'Cancelled') as cancelled_orders,
            count(*) filter (
                where status = 'Cancelled'
                  and (
                      cancelled_at is null
                      or cancellation_reason is null
                      or cancellation_policy is null
                      or food_making_deduction is null
                      or delivery_deduction is null
                      or refund_amount is null
                  )
            ) as cancelled_orders_missing_required_details,
            count(*) filter (
                where status = 'Cancelled'
                  and cancellation_policy not in (
                      'restaurant_stage_full_refund',
                      'delivery_stage_deductions'
                  )
            ) as cancelled_orders_with_unsupported_policy,
            count(*) filter (
                where status = 'Cancelled'
                  and cancellation_policy = 'restaurant_stage_full_refund'
                  and (
                      food_making_deduction <> 0
                      or delivery_deduction <> 0
                      or refund_amount <> paid_amount
                  )
            ) as restaurant_stage_amount_mismatches,
            count(*) filter (
                where status = 'Cancelled'
                  and cancellation_policy = 'delivery_stage_deductions'
                  and (
                      food_subtotal is null
                      or delivery_charge is null
                      or food_making_deduction <> round(food_subtotal * 0.10, 2)
                      or delivery_deduction <> delivery_charge
                      or refund_amount <> greatest(
                          round(paid_amount - food_making_deduction - delivery_deduction, 2),
                          0
                      )
                  )
            ) as delivery_stage_amount_mismatches
        from public.orders
    $q$, false, false, '') end as cancelled_order_check;

-- 2a. Values covered by the consolidated status/payment/refund constraints.
select case
    when to_regclass('public.orders') is null then
        '<status_payment_check><status>MISSING public.orders</status></status_payment_check>'::xml
    when (
        select count(*)
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'orders'
          and column_name = any (array[
              'status', 'payment_status', 'payment_method', 'paid_amount',
              'razorpay_order_id', 'razorpay_payment_id', 'refund_status',
              'razorpay_refund_id'
          ])
    ) < 8 then
        '<status_payment_check><status>REQUIRED STATUS/PAYMENT COLUMNS ARE INCOMPLETE; see inventory above</status></status_payment_check>'::xml
    else query_to_xml($q$
        select
            count(*) filter (
                where status is null
                   or status not in (
                    'Pending', 'Approved', 'Cooking', 'Out for Delivery',
                    'Delivered', 'Cancelled'
                )
            ) as orders_with_status_outside_allowed_values,
            count(*) filter (
                where payment_status is null
                   or payment_status not in ('unverified', 'unpaid', 'paid')
            ) as orders_with_unknown_payment_status,
            count(*) filter (
                where payment_status = 'paid'
                  and (
                      payment_method <> 'upi'
                      or paid_amount <= 0
                      or razorpay_order_id is null
                      or razorpay_payment_id is null
                  )
            ) as paid_orders_missing_verified_razorpay_references,
            count(*) filter (
                where refund_status is null
                   or refund_status not in (
                    'not_requested', 'not_required', 'admin_requested',
                    'processing', 'processed', 'failed'
                )
            ) as orders_with_unknown_refund_status,
            count(*) filter (
                where refund_status = 'processed'
                  and razorpay_refund_id is null
            ) as processed_refunds_missing_razorpay_refund_id
        from public.orders
    $q$, false, false, '') end as status_payment_check;

-- 3. GPS coordinate completeness and validity for existing orders.
select case
    when to_regclass('public.orders') is null then
        '<gps_check><status>MISSING public.orders</status></gps_check>'::xml
    when (
        select count(*)
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'orders'
          and column_name = any (array[
              'location_latitude', 'location_longitude',
              'location_accuracy_m', 'location_captured_at'
          ])
    ) < 4 then
        '<gps_check><status>GPS COLUMNS NOT ALL PRESENT; see inventory above</status></gps_check>'::xml
    else query_to_xml($q$
        select
            count(*) as total_orders,
            count(*) filter (
                where location_latitude is null
                  and location_longitude is null
                  and location_accuracy_m is null
                  and location_captured_at is null
            ) as orders_without_gps,
            count(*) filter (
                where location_latitude is not null
                   or location_longitude is not null
                   or location_accuracy_m is not null
                   or location_captured_at is not null
            ) as orders_with_any_gps_value,
            count(*) filter (
                where not (
                    location_latitude is null
                    and location_longitude is null
                    and location_accuracy_m is null
                    and location_captured_at is null
                )
                and not (
                    location_latitude is not null
                    and location_longitude is not null
                    and location_accuracy_m is not null
                    and location_captured_at is not null
                    and location_latitude between -90 and 90
                    and location_longitude between -180 and 180
                    and location_accuracy_m > 0
                    and location_accuracy_m <= 100000
                )
            ) as incomplete_or_out_of_range_gps
        from public.orders
    $q$, false, false, '') end as gps_check;

-- 4. Duplicate Razorpay identifiers. Each result is guarded so the script
-- also works before the Razorpay columns have been added.
select case
    when to_regclass('public.orders') is null then
        '<razorpay_order_id_check><status>MISSING public.orders</status></razorpay_order_id_check>'::xml
    when not exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'orders'
          and column_name = 'razorpay_order_id'
    ) then
        '<razorpay_order_id_check><status>COLUMN NOT PRESENT</status></razorpay_order_id_check>'::xml
    else query_to_xml($q$
        select razorpay_order_id, count(*) as occurrences
        from public.orders
        where razorpay_order_id is not null
        group by razorpay_order_id
        having count(*) > 1
        order by occurrences desc, razorpay_order_id
    $q$, false, false, '') end as duplicate_razorpay_order_ids;

select case
    when to_regclass('public.orders') is null then
        '<razorpay_payment_id_check><status>MISSING public.orders</status></razorpay_payment_id_check>'::xml
    when not exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'orders'
          and column_name = 'razorpay_payment_id'
    ) then
        '<razorpay_payment_id_check><status>COLUMN NOT PRESENT</status></razorpay_payment_id_check>'::xml
    else query_to_xml($q$
        select razorpay_payment_id, count(*) as occurrences
        from public.orders
        where razorpay_payment_id is not null
        group by razorpay_payment_id
        having count(*) > 1
        order by occurrences desc, razorpay_payment_id
    $q$, false, false, '') end as duplicate_razorpay_payment_ids;

select case
    when to_regclass('public.orders') is null then
        '<razorpay_refund_id_check><status>MISSING public.orders</status></razorpay_refund_id_check>'::xml
    when not exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'orders'
          and column_name = 'razorpay_refund_id'
    ) then
        '<razorpay_refund_id_check><status>COLUMN NOT PRESENT</status></razorpay_refund_id_check>'::xml
    else query_to_xml($q$
        select razorpay_refund_id, count(*) as occurrences
        from public.orders
        where razorpay_refund_id is not null
        group by razorpay_refund_id
        having count(*) > 1
        order by occurrences desc, razorpay_refund_id
    $q$, false, false, '') end as duplicate_razorpay_refund_ids;

-- 5. Existing restaurant settings, without changing or exposing credentials.
select case
    when to_regclass('public.restaurant_settings') is null then
        '<restaurant_settings_check><status>MISSING public.restaurant_settings</status></restaurant_settings_check>'::xml
    when (
        select count(*)
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'restaurant_settings'
          and column_name = any (array[
              'id', 'restaurant_name', 'phone', 'email', 'address',
              'opening_hours', 'delivery_fee', 'tax_rate'
          ])
    ) < 8 then
        '<restaurant_settings_check><status>EXPECTED SETTINGS COLUMNS ARE INCOMPLETE; see inventory above</status></restaurant_settings_check>'::xml
    else query_to_xml($q$
        select
            id,
            restaurant_name,
            phone,
            email,
            address,
            opening_hours,
            delivery_fee,
            tax_rate
        from public.restaurant_settings
        order by id
    $q$, false, false, '') end as restaurant_settings;

-- 6. Required Supabase Auth schema/table, roles and helper functions.
select
    exists (
        select 1 from pg_namespace where nspname = 'auth'
    ) as auth_schema_exists,
    to_regclass('auth.users') is not null as auth_users_table_exists,
    exists (select 1 from pg_roles where rolname = 'anon') as anon_role_exists,
    exists (select 1 from pg_roles where rolname = 'authenticated') as authenticated_role_exists,
    exists (select 1 from pg_roles where rolname = 'service_role') as service_role_exists,
    to_regprocedure('auth.uid()') is not null as auth_uid_function_exists,
    to_regprocedure('auth.role()') is not null as auth_role_function_exists;

-- Auth user columns consumed by the profile-creation trigger.
select
    expected.column_name,
    case when actual.column_name is null then 'MISSING COLUMN' else 'present' end
        as preflight_status
from (
    values ('id'), ('email'), ('raw_user_meta_data')
) as expected(column_name)
left join information_schema.columns actual
    on actual.table_schema = 'auth'
   and actual.table_name = 'users'
   and actual.column_name = expected.column_name
order by expected.column_name;

-- 6a. Required base application tables.
select
    required.table_name,
    to_regclass(format('public.%I', required.table_name)) is not null as table_exists
from (
    values
        ('profiles'),
        ('menu_items'),
        ('posters'),
        ('restaurant_settings'),
        ('orders'),
        ('order_items')
) as required(table_name)
order by required.table_name;
