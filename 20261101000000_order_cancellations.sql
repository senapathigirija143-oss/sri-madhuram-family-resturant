alter table public.orders
    drop constraint if exists orders_status_check,
    add constraint orders_status_check check (
        status in ('Pending', 'Approved', 'Cooking', 'Out for Delivery', 'Delivered', 'Cancelled')
    ),
    add column if not exists food_subtotal numeric(10, 2),
    add column if not exists delivery_charge numeric(10, 2),
    add column if not exists payment_status text not null default 'unverified'
        check (payment_status in ('unverified', 'unpaid', 'paid')),
    add column if not exists paid_amount numeric(10, 2) not null default 0
        check (paid_amount >= 0),
    add column if not exists razorpay_order_id text,
    add column if not exists razorpay_payment_id text,
    add column if not exists cancelled_at timestamptz,
    add column if not exists cancellation_reason text,
    add column if not exists cancellation_policy text,
    add column if not exists food_making_deduction numeric(10, 2),
    add column if not exists delivery_deduction numeric(10, 2),
    add column if not exists refund_amount numeric(10, 2),
    add column if not exists refund_status text not null default 'not_requested'
        check (refund_status in ('not_requested', 'not_required', 'admin_requested', 'processing', 'processed', 'failed')),
    add column if not exists razorpay_refund_id text;

alter table public.orders
    add constraint orders_charge_snapshot_valid check (
        (food_subtotal is null and delivery_charge is null)
        or (
            food_subtotal is not null
            and delivery_charge is not null
            and food_subtotal >= 0
            and delivery_charge >= 0
        )
    ),
    add constraint orders_paid_payment_reference_valid check (
        payment_status <> 'paid'
        or (
            payment_method = 'upi'
            and paid_amount > 0
            and razorpay_order_id is not null
            and razorpay_payment_id is not null
        )
    ),
    add constraint orders_processed_refund_has_gateway_id check (
        refund_status <> 'processed' or razorpay_refund_id is not null
    ),
    add constraint orders_cancellation_details_valid check (
        (
            status <> 'Cancelled'
            and cancelled_at is null
            and cancellation_reason is null
            and cancellation_policy is null
            and food_making_deduction is null
            and delivery_deduction is null
            and refund_amount is null
        )
        or (
            status = 'Cancelled'
            and cancelled_at is not null
            and cancellation_reason is not null
            and cancellation_policy in ('restaurant_stage_full_refund', 'delivery_stage_deductions')
            and food_making_deduction is not null
            and food_making_deduction >= 0
            and delivery_deduction is not null
            and delivery_deduction >= 0
            and refund_amount is not null
            and refund_amount >= 0
        )
    );

create unique index if not exists orders_razorpay_order_id_idx
    on public.orders (razorpay_order_id)
    where razorpay_order_id is not null;
create unique index if not exists orders_razorpay_payment_id_idx
    on public.orders (razorpay_payment_id)
    where razorpay_payment_id is not null;
create unique index if not exists orders_razorpay_refund_id_idx
    on public.orders (razorpay_refund_id)
    where razorpay_refund_id is not null;

drop function if exists public.create_customer_order(
    uuid, text, text, text, text, jsonb, double precision, double precision,
    double precision, timestamptz
);

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
    p_location_captured_at timestamptz,
    p_paid_amount numeric,
    p_razorpay_order_id text,
    p_razorpay_payment_id text
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
    v_total numeric(10, 2);
begin
    if auth.role() <> 'service_role'
        or jsonb_typeof(p_items) <> 'array'
        or jsonb_array_length(p_items) = 0
        or p_payment_method not in ('upi', 'cod')
        or p_paid_amount is null
        or p_paid_amount < 0
        or (
            p_payment_method = 'upi'
            and (
                p_razorpay_order_id is null
                or p_razorpay_payment_id is null
                or p_paid_amount <= 0
            )
        )
        or (
            p_payment_method = 'cod'
            and (
                p_razorpay_order_id is not null
                or p_razorpay_payment_id is not null
                or p_paid_amount <> 0
            )
        )
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
    v_total := round(v_subtotal * (1 + v_tax_rate) + v_delivery_fee);

    if p_payment_method = 'upi' and p_paid_amount <> v_total then
        raise exception 'The verified payment amount does not match the order total.';
    end if;

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
        location_captured_at,
        food_subtotal,
        delivery_charge,
        payment_status,
        paid_amount,
        razorpay_order_id,
        razorpay_payment_id
    )
    values (
        v_order_id,
        p_user_id,
        p_name,
        p_phone,
        v_total,
        p_payment_method,
        'Pending',
        p_address,
        p_location_latitude,
        p_location_longitude,
        p_location_accuracy_m,
        p_location_captured_at,
        v_subtotal,
        v_delivery_fee,
        case when p_payment_method = 'upi' then 'paid' else 'unpaid' end,
        p_paid_amount,
        p_razorpay_order_id,
        p_razorpay_payment_id
    );

    insert into public.order_items (order_id, menu_item_id, item_name, quantity, unit_price)
    select v_order_id, menu.id, menu.name, incoming.quantity, menu.price
    from jsonb_to_recordset(p_items) as incoming(menu_item_id bigint, quantity integer)
    join public.menu_items menu
        on menu.id = incoming.menu_item_id and menu.is_available;

    return v_order_id;
end;
$$;

drop function if exists public.cancel_customer_order(uuid, text, text);

create function public.cancel_customer_order(
    p_user_id uuid,
    p_order_id text,
    p_reason text,
    p_expected_status text
)
returns public.orders
language plpgsql
set search_path = public
as $$
declare
    v_order public.orders;
    v_policy text;
    v_food_deduction numeric(10, 2);
    v_delivery_deduction numeric(10, 2);
    v_refund_amount numeric(10, 2);
begin
    if auth.role() <> 'service_role'
        or p_user_id is null
        or p_order_id is null
        or p_expected_status is null
        or length(trim(coalesce(p_reason, ''))) not between 1 and 500 then
        raise exception 'Not authorized or cancellation details are invalid.';
    end if;

    select * into v_order
    from public.orders
    where id = p_order_id and user_id = p_user_id
    for update;

    if not found then
        raise exception using errcode = 'P0002', message = 'Order was not found.';
    end if;

    if v_order.status not in ('Pending', 'Approved', 'Cooking', 'Out for Delivery') then
        raise exception using errcode = 'P0001', message = 'This order cannot be cancelled at its current status.';
    end if;

    if v_order.status <> p_expected_status then
        raise exception using errcode = 'P0001', message = 'Order status changed. Review the updated cancellation calculation.';
    end if;

    if v_order.food_subtotal is null or v_order.delivery_charge is null then
        raise exception using errcode = 'P0001', message = 'Saved charge details are unavailable for this order.';
    end if;

    if v_order.status = 'Out for Delivery' then
        v_policy := 'delivery_stage_deductions';
        v_food_deduction := round(v_order.food_subtotal * 0.10, 2);
        v_delivery_deduction := v_order.delivery_charge;
        v_refund_amount := greatest(
            round(v_order.paid_amount - v_food_deduction - v_delivery_deduction, 2),
            0
        );
    else
        v_policy := 'restaurant_stage_full_refund';
        v_food_deduction := 0;
        v_delivery_deduction := 0;
        v_refund_amount := v_order.paid_amount;
    end if;

    update public.orders
    set status = 'Cancelled',
        cancelled_at = now(),
        cancellation_reason = trim(p_reason),
        cancellation_policy = v_policy,
        food_making_deduction = v_food_deduction,
        delivery_deduction = v_delivery_deduction,
        refund_amount = v_refund_amount,
        refund_status = case
            when v_refund_amount > 0 then 'admin_requested'
            else 'not_required'
        end
    where id = p_order_id
    returning * into v_order;

    return v_order;
end;
$$;

revoke all on function public.create_customer_order(
    uuid, text, text, text, text, jsonb, double precision, double precision,
    double precision, timestamptz, numeric, text, text
) from public, anon, authenticated;
grant execute on function public.create_customer_order(
    uuid, text, text, text, text, jsonb, double precision, double precision,
    double precision, timestamptz, numeric, text, text
) to service_role;

revoke all on function public.cancel_customer_order(uuid, text, text, text)
    from public, anon, authenticated;
grant execute on function public.cancel_customer_order(uuid, text, text, text)
    to service_role;

notify pgrst, 'reload schema';
