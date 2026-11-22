-- round 11: شبكة كارت الشحن (فودافون/اتصالات/أورانج/وي) على عمليات الخدمات
-- ١) عمود جديد
alter table public.service_txns add column if not exists network text not null default '';

-- ٢) تحديث الـ RPC عشان يستقبل network
create or replace function public.save_service_txn(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text := nullif(p->>'id','');
  v_row public.service_txns%rowtype;
begin
  if not public.has_shop_perm('invoice') then raise exception 'no permission: invoice'; end if;
  if v_id is not null then
    select * into v_row from public.service_txns where id = v_id;
    if found then return to_jsonb(v_row); end if;
  end if;
  insert into public.service_txns (id, date, kind, service, network, amount, fee, customer_name, customer_phone, note, created_by)
  values (coalesce(v_id, gen_random_uuid()::text), coalesce((p->>'date')::timestamptz, now()),
          coalesce(nullif(p->>'kind',''),'تحويل'), coalesce(p->>'service',''),
          coalesce(p->>'network',''),
          coalesce((p->>'amount')::numeric,0), coalesce((p->>'fee')::numeric,0),
          coalesce(p->>'customerName',''), coalesce(p->>'customerPhone',''), coalesce(p->>'note',''), auth.uid())
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

revoke all on function public.save_service_txn(jsonb) from public;
grant execute on function public.save_service_txn(jsonb) to authenticated;

-- ٣) فحص ذاتي
do $$
begin
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='service_txns' and column_name='network') then
    raise exception 'ROUND11 FAIL: network missing';
  end if;
  raise notice 'ROUND11 PASS: network present, save_service_txn updated';
end $$;
