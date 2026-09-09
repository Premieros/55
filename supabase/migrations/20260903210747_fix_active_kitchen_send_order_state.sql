create or replace function public.send_to_kitchen(p_order_id uuid, p_sent_by uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_branch_id uuid;
  v_status text;
  v_order_number text;
  v_table_id uuid;
  v_table_name text;
  v_order_type text;
  v_guest_count integer;
  v_user_branch uuid;
  v_sent_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_all_sent boolean := false;
  v_is_service_role boolean := coalesce(current_setting('role', true), '') = 'service_role';
  v_first_sent_at timestamptz;
begin
  begin
    select branch_id, status, order_number, table_id, order_type, guest_count
      into v_branch_id, v_status, v_order_number, v_table_id, v_order_type, v_guest_count
    from public.orders
    where id = p_order_id;

    if v_branch_id is null then
      return jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    end if;

    if v_status not in ('open', 'held') then
      return jsonb_build_object(
        'success', false,
        'error', 'ORDER_NOT_EDITABLE',
        'detail', 'Only open or held orders can be sent to the kitchen.'
      );
    end if;

    if v_table_id is not null then
      select name into v_table_name
      from public.dining_tables
      where id = v_table_id and branch_id = v_branch_id;
    end if;

    if not v_is_service_role then
      if auth.uid() is null then
        return jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
      end if;

      select branch_id into v_user_branch
      from public.users
      where id = auth.uid() and is_active = true;

      if not is_pos_admin()
         and coalesce(v_user_branch, '00000000-0000-0000-0000-000000000000'::uuid) <> v_branch_id then
        return jsonb_build_object('success', false, 'error', 'BRANCH_MISMATCH');
      end if;

      if not is_pos_admin() and not can_permission('pos.send_kitchen') then
        return jsonb_build_object(
          'success', false,
          'error', 'PERMISSION_DENIED',
          'detail', 'pos.send_kitchen'
        );
      end if;
    end if;

    create temp table if not exists _kns_delta (
      order_item_id uuid,
      send_id uuid,
      delta_quantity numeric(14,4)
    ) on commit drop;
    truncate _kns_delta;

    with candidates as (
      select
        oi.id as order_item_id,
        oi.quantity as target_quantity,
        oi.quantity - coalesce(s.sent_quantity, 0) as delta_quantity
      from public.order_items oi
      left join public.order_kitchen_sends s on s.order_item_id = oi.id
      where oi.order_id = p_order_id
        and oi.quantity > coalesce(s.sent_quantity, 0)
    ), upserted as (
      insert into public.order_kitchen_sends(
        branch_id, order_id, order_item_id, sent_at, sent_by, sent_quantity
      )
      select
        v_branch_id,
        p_order_id,
        c.order_item_id,
        now(),
        coalesce(p_sent_by, auth.uid()),
        c.target_quantity
      from candidates c
      on conflict (order_item_id) do update
      set sent_quantity = excluded.sent_quantity,
          sent_at = now(),
          sent_by = excluded.sent_by
      where public.order_kitchen_sends.sent_quantity < excluded.sent_quantity
      returning id, order_item_id
    )
    insert into _kns_delta(order_item_id, send_id, delta_quantity)
    select u.order_item_id, u.id, c.delta_quantity
    from upserted u
    join candidates c on c.order_item_id = u.order_item_id;

    select count(*) into v_count from _kns_delta;

    if v_count > 0 then
      select coalesce(jsonb_agg(jsonb_build_object(
        'send_id', k.send_id,
        'order_item_id', k.order_item_id,
        'product_id', oi.product_id,
        'product_name', p.name,
        'unit_name', oi.unit_name,
        'station_code', coalesce(ks.code, 'main'),
        'quantity', k.delta_quantity,
        'current_quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'discount_amount', oi.discount_amount,
        'bonus_quantity', oi.bonus_quantity,
        'total', oi.total,
        'notes', oi.notes,
        'modifiers', coalesce(oi.modifiers_snapshot, '[]'::jsonb)
      ) order by oi.created_at), '[]'::jsonb)
      into v_sent_items
      from _kns_delta k
      join public.order_items oi on oi.id = k.order_item_id
      left join public.products p on p.id = oi.product_id
      left join public.categories c
        on c.id = p.category_id and c.branch_id = v_branch_id
      left join public.kitchen_stations ks
        on ks.id = c.kitchen_station_id and ks.is_active = true;
    end if;

    select not exists (
      select 1
      from public.order_items oi
      left join public.order_kitchen_sends s on s.order_item_id = oi.id
      where oi.order_id = p_order_id
        and oi.quantity > coalesce(s.sent_quantity, 0)
    ) into v_all_sent;

    select min(s.sent_at)
      into v_first_sent_at
    from public.order_kitchen_sends s
    where s.order_id = p_order_id;

    if v_first_sent_at is not null then
      update public.orders
      set
        kitchen_status = case
          when kitchen_status = 'pending' then 'sent'
          else kitchen_status
        end,
        kitchen_sent_at = coalesce(kitchen_sent_at, v_first_sent_at)
      where id = p_order_id;
    end if;

    return jsonb_build_object(
      'success', true,
      'order_id', p_order_id,
      'order_number', v_order_number,
      'table_name', v_table_name,
      'order_type', v_order_type,
      'guest_count', v_guest_count,
      'sent', v_sent_items,
      'items_sent_count', v_count,
      'all_sent', v_all_sent
    );
  exception when others then
    return jsonb_build_object(
      'success', false,
      'error', 'TRANSACTION_FAILED',
      'detail', sqlerrm
    );
  end;
end;
$function$;

update public.orders o
set
  kitchen_status = 'sent',
  kitchen_sent_at = coalesce(o.kitchen_sent_at, s.first_sent_at)
from (
  select order_id, min(sent_at) as first_sent_at
  from public.order_kitchen_sends
  group by order_id
) s
where o.id = s.order_id
  and o.kitchen_status = 'pending'
  and o.status not in ('completed','cancelled');
