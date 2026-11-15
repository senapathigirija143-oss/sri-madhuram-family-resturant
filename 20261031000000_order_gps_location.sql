alter table public.orders
    add column location_latitude double precision,
    add column location_longitude double precision,
    add column location_accuracy_m double precision,
    add column location_captured_at timestamptz,
    add constraint orders_location_coordinates_valid check (
        (
            location_latitude is null
            and location_longitude is null
            and location_accuracy_m is null
            and location_captured_at is null
        )
        or (
            location_latitude is not null
            and location_longitude is not null
            and location_accuracy_m is not null
            and location_captured_at is not null
            and location_latitude between -90 and 90
            and location_longitude between -180 and 180
            and location_accuracy_m > 0
            and location_accuracy_m <= 100000
            and location_captured_at is not null
        )
    );

drop function if exists public.create_customer_order(uuid, text, text, text, text, jsonb);

create function public.create_customer_order(
    p_user_id uuid,
    p_name text,
    p_phone text,
    p_address text,
    p_payment_method text,
    p_items jsonb,
    p_location_latitude double precision,
    p_location_longitude double precision,
    p_location_accuracy_m double precision,
    p_location_captured_at timestamptz
)
returns text
language plpgsql
set search_path = public
as $$
declare
    v_order_id text;
    v_subtotal numeric(10, 2);
    v_item_count integer;
    v_expected_count integer;
    v_tax_rate numeric(5, 4);
    v_delivery_fee numeric(10, 2);
begin
    if auth.role() <> 'service_role'
        or jsonb_typeof(p_items) <> 'array'
        or jsonb_array_length(p_items) = 0
        or p_payment_method not in ('upi', 'cod')
        or not (
            (
                p_location_latitude is null
                and p_location_longitude is null
                and p_location_accuracy_m is null
                and p_location_captured_at is null
            )
            or (
                p_location_latitude is not null
                and p_location_longitude is not null
                and p_location_accuracy_m is not null
                and p_location_captured_at is not null
                and p_location_latitude between -90 and 90
                and p_location_longitude between -180 and 180
                and p_location_accuracy_m > 0
                and p_location_accuracy_m <= 100000
            )
        ) then
        raise exception 'Not authorized or order details are invalid.';
    end if;

    select count(*), coalesce(sum(menu.price * incoming.quantity), 0)
    into v_item_count, v_subtotal
    from jsonb_to_recordset(p_items) as incoming(menu_item_id bigint, quantity integer)
    join public.menu_items menu
        on menu.id = incoming.menu_item_id and menu.is_available
    where incoming.quantity between 1 and 100;

    select count(*) into v_expected_count
    from jsonb_to_recordset(p_items) as incoming(menu_item_id bigint, quantity integer);

    if v_item_count <> v_expected_count or v_item_count = 0 then
        raise exception 'One or more order items are invalid or unavailable.';
    end if;

    select delivery_fee, tax_rate
    into v_delivery_fee, v_tax_rate
    from public.restaurant_settings
    where id = 'default';

    v_delivery_fee := coalesce(v_delivery_fee, 30);
    v_tax_rate := coalesce(v_tax_rate, 0.05);
    v_order_id := 'ORD-' || upper(replace(gen_random_uuid()::text, '-', ''));

    insert into public.orders (
        id,
        user_id,
        name,
        phone,
        total,
        payment_method,
        status,
        address,
        location_latitude,
        location_longitude,
        location_accuracy_m,
        location_captured_at
    )
    values (
        v_order_id,
        p_user_id,
        p_name,
        p_phone,
        round(v_subtotal * (1 + v_tax_rate) + v_delivery_fee),
        p_payment_method,
        'Pending',
        p_address,
        p_location_latitude,
        p_location_longitude,
        p_location_accuracy_m,
        p_location_captured_at
    );

    insert into public.order_items (order_id, menu_item_id, item_name, quantity, unit_price)
    select v_order_id, menu.id, menu.name, incoming.quantity, menu.price
    from jsonb_to_recordset(p_items) as incoming(menu_item_id bigint, quantity integer)
    join public.menu_items menu
        on menu.id = incoming.menu_item_id and menu.is_available;

    return v_order_id;
end;
$$;

revoke all on function public.create_customer_order(
    uuid, text, text, text, text, jsonb, double precision, double precision,
    double precision, timestamptz
) from public, anon, authenticated;
grant execute on function public.create_customer_order(
    uuid, text, text, text, text, jsonb, double precision, double precision,
    double precision, timestamptz
) to service_role;

notify pgrst, 'reload schema';
