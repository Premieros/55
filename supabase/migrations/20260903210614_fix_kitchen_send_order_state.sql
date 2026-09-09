create or replace function public.send_to_kitchen(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_order public.orders%rowtype;
  v_item record;
  v_sent numeric;
  v_delta numeric;
  v_items_sent int := 0;
  v_all_sent boolean := true;
  v_uid uuid := auth.uid();
  v_first_sent_at timestamptz;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'error', 'AUTH_REQUIRED');
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id;

  if not found then
    return jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
  end if;

  if not public.user_may_access_branch(v_order.branch_id) then
    return jsonb_build_object('success', false, 'error', 'BRANCH_DENIED');
  end if;

  if not (public.is_platform_admin()
          or public.has_permission('pos.sell')
          or public.has_permission('pos.manage_orders')
          or public.has_permission('pos.kds')
          or public.has_permission('pos.manage_kds')) then
    return jsonb_build_object('success', false, 'error', 'PERMISSION_DENIED');
  end if;

  if v_order.status in ('completed','cancelled') or coalesce(v_order.payment_status,'unpaid') = 'void' then
    return jsonb_build_object('success', false, 'error', 'ORDER_CLOSED');
  end if;

  for v_item in
    select oi.id, oi.quantity
    from public.order_items oi
    where oi.order_id = p_order_id
    order by oi.created_at, oi.id
  loop
    select coalesce(oks.sent_quantity,0)
      into v_sent
    from public.order_kitchen_sends oks
    where oks.order_item_id = v_item.id;

    v_delta := greatest(coalesce(v_item.quantity,0) - coalesce(v_sent,0), 0);

    if v_delta > 0 then
      insert into public.order_kitchen_sends(order_id, order_item_id, sent_quantity, sent_at, sent_by)
      values (p_order_id, v_item.id, v_delta, now(), v_uid)
      on conflict (order_item_id)
      do update set
        sent_quantity = public.order_kitchen_sends.sent_quantity + excluded.sent_quantity,
        sent_at = excluded.sent_at,
        sent_by = excluded.sent_by;

      v_items_sent := v_items_sent + 1;
    end if;

    select coalesce(oks.sent_quantity,0)
      into v_sent
    from public.order_kitchen_sends oks
    where oks.order_item_id = v_item.id;

    if coalesce(v_sent,0) < coalesce(v_item.quantity,0) then
      v_all_sent := false;
    end if;
  end loop;

  select min(oks.sent_at)
    into v_first_sent_at
  from public.order_kitchen_sends oks
  where oks.order_id = p_order_id;

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
    'items_sent', v_items_sent,
    'all_sent', v_all_sent
  );
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
