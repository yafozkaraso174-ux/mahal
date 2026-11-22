-- LOCAL PROPOSAL ONLY. Apply after round19, before publishing updated HTML.
begin;
create or replace function public.store_is_active(p_tenant uuid) returns boolean
language sql stable security definer set search_path=public as $$
 select exists(select 1 from tenants where id=p_tenant and status='active' and (sub_end is null or sub_end>=current_date))
$$;
revoke all on function public.store_is_active(uuid) from public;
grant execute on function public.store_is_active(uuid) to anon,authenticated;
-- One requested store only. No tenant directory, customer/order/staff/cost/device data.
create or replace function public.get_store(p_tenant uuid) returns jsonb
language sql stable security definer set search_path=public as $$
 select jsonb_build_object('tenant_id',t.id,
 'info',jsonb_build_object('shop_name',coalesce(s.shop_name,t.name),'phone',s.phone,'delivery_fee',coalesce(s.delivery_fee,0),'delivery_on',coalesce(s.delivery_on,true),
 'zones',coalesce((select jsonb_agg(jsonb_build_object('name',z->>'name','fee',z->'fee')) from jsonb_array_elements(coalesce(s.zones,'[]')) z),'[]'::jsonb),
 'payment',jsonb_build_object('cash',jsonb_build_object('on',s.payment->'cash'->'on'),'vf',jsonb_build_object('on',s.payment->'vf'->'on','num',case when coalesce((s.payment->'vf'->>'on')::boolean,false) then s.payment->'vf'->'num' else null end),'insta',jsonb_build_object('on',s.payment->'insta'->'on','num',case when coalesce((s.payment->'insta'->>'on')::boolean,false) then s.payment->'insta'->'num' else null end),'bank',jsonb_build_object('on',s.payment->'bank'->'on','num',case when coalesce((s.payment->'bank'->>'on')::boolean,false) then s.payment->'bank'->'num' else null end))),
 'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'cat',p.cat,'unit',p.unit,'price',p.price,'stock',p.stock,'photo_url',p.photo_url,
 'unit_config',case when p.unit_config is null then null else jsonb_strip_nulls(jsonb_build_object('base',p.unit_config->'base','packLabel',p.unit_config->'packLabel','packFactor',p.unit_config->'packFactor','area',p.unit_config->'area','discrete',p.unit_config->'discrete','wholePack',p.unit_config->'wholePack')) end) order by p.cat,p.name) from products p where p.tenant_id=t.id and not p.deleted),'[]'::jsonb),
 'offers',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'data',jsonb_build_object('name',o.data->>'name','productIds',o.data->'productIds','kind',o.data->>'kind','value',o.data->'value','startsAt',o.data->'startsAt','endsAt',o.data->'endsAt','active',o.data->'active'))) from offers o where o.tenant_id=t.id and not o.deleted and coalesce((o.data->>'active')::boolean,false) and now()>=coalesce(nullif(o.data->>'startsAt','')::timestamptz,'-infinity') and now()<=coalesce(nullif(o.data->>'endsAt','')::timestamptz,'infinity')),'[]'::jsonb))
 from tenants t left join shop_info s on s.tenant_id=t.id and s.id=1
 where t.id=p_tenant and public.store_is_active(t.id)
$$;
revoke all on function public.get_store(uuid) from public;
grant execute on function public.get_store(uuid) to anon,authenticated;
-- Private raw shop settings remain visible to that shop only. Public fields use get_store.
drop policy if exists "public read store shop_info" on public.shop_info;
create policy "public read store shop_info" on public.shop_info for select to authenticated using(tenant_id=public.my_tenant());
drop policy if exists "public insert orders" on public.orders;
drop policy if exists "public insert store orders" on public.orders;
create policy "public insert orders" on public.orders for insert to anon,authenticated with check(public.store_is_active(tenant_id));

create or replace function public.validate_commerce_order() returns trigger
 language plpgsql security definer set search_path=public as $$
declare it jsonb; p public.products%rowtype; o record; off jsonb; q numeric; expected numeric; total_items numeric:=0; rebuilt jsonb:='[]'; advanced boolean:=false; n integer;
begin
 if not public.store_is_active(new.tenant_id) then raise exception 'missing: store tenant'; end if;
 if exists(select 1 from jsonb_array_elements(new.items) x where coalesce((x->>'qty')::numeric,0)<=0) then raise exception 'missing: positive order quantity';end if;
 if exists(select 1 from jsonb_array_elements(new.items) x where not exists(select 1 from products pp where pp.id=x->>'id' and pp.tenant_id=new.tenant_id and not pp.deleted)) then raise exception 'missing product';end if;
 if not exists(select 1 from jsonb_array_elements(new.items) x join products pr on pr.id=x->>'id' and pr.tenant_id=new.tenant_id where x ? 'commerce' or pr.unit_config is not null or exists(select 1 from offers f where f.tenant_id=new.tenant_id and not f.deleted and coalesce((f.data->>'active')::boolean,false) and (f.data->'productIds') ? pr.id and now()>=coalesce(nullif(f.data->>'startsAt','')::timestamptz,'-infinity') and now()<=coalesce(nullif(f.data->>'endsAt','')::timestamptz,'infinity'))) then return new;end if;
 for it in select * from jsonb_array_elements(new.items) loop
  select * into p from products where id=it->>'id' and tenant_id=new.tenant_id and not deleted;
  if not found then raise exception 'missing product'; end if;
  q:=coalesce((it->>'qty')::numeric,0);if q<=0 or q>p.stock then raise exception 'shortage: store quantity';end if;
  off:=null;n:=0;expected:=p.price;
  for o in select * from offers where tenant_id=new.tenant_id and not deleted and coalesce((data->>'active')::boolean,false) and (data->'productIds') ? p.id and now()>=coalesce(nullif(data->>'startsAt','')::timestamptz,'-infinity') and now()<=coalesce(nullif(data->>'endsAt','')::timestamptz,'infinity') order by id loop
   n:=n+1;
   expected:=round(greatest(0,case when o.data->>'kind'='pct' then p.price*(1-(o.data->>'value')::numeric/100) else p.price-(o.data->>'value')::numeric end),6);
   off:=jsonb_build_object('id',o.id,'name',o.data->>'name','kind',o.data->>'kind','value',o.data->'value','original',p.price,'price',expected,'quotedAt',now());
  end loop;
  if n>1 then raise exception 'missing: overlapping offers';end if;
  if p.unit_config is not null or off is not null or it ? 'commerce' then
   advanced:=true;
   if abs(coalesce((it->>'price')::numeric,-1)-expected)>0.000001 then raise exception 'missing: price changed, reload store';end if;
   if p.unit_config is not null and coalesce((p.unit_config->>'discrete')::boolean,false) and q<>trunc(q) then raise exception 'missing: whole pieces required';end if;
   if q<>round(q,3) then raise exception 'missing: quantity precision';end if;
   it:=it||jsonb_build_object('name',p.name,'unit',p.unit,'price',expected,'commerce',jsonb_strip_nulls(jsonb_build_object('offer',off,'unitConfig',p.unit_config,'saleQty',q,'saleUnit',p.unit,'factor',1)));
  end if;
  total_items:=total_items+q*(it->>'price')::numeric;rebuilt:=rebuilt||jsonb_build_array(it);
 end loop;
 if advanced then
  if abs(new.total-round(total_items+coalesce(new.delivery_fee,0),2))>0.001 then raise exception 'missing: store total';end if;
  new.items:=rebuilt;
 end if;
 return new;
end $$;
drop trigger if exists commerce_store_order on public.orders;
create trigger commerce_store_order before insert on public.orders for each row execute function public.validate_commerce_order();

NOTIFY pgrst, 'reload schema';
commit;
