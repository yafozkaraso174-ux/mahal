BEGIN;
DO $$ DECLARE r record; BEGIN
 FOR r IN SELECT * FROM pg_policies WHERE schemaname='public'
  AND tablename IN('products','customers','suppliers','invoices','purchases','payments','movements','expenses','sales_returns','service_txns','day_closes','drawer_entries','backups')
  AND cmd IN('SELECT','ALL') LOOP
   EXECUTE format('ALTER POLICY %I ON public.%I USING ((%s) AND public.tenant_active())',r.policyname,r.tablename,r.qual);
 END LOOP;
END $$;
alter table public.orders alter column tenant_id set default coalesce(public.my_tenant(),public.store_tenant());
drop policy if exists "public insert orders" on public.orders;
create policy "public insert store orders" on public.orders for insert to anon,authenticated with check
 (tenant_id=public.store_tenant() and exists(select 1 from public.shop_info s where s.tenant_id=public.store_tenant()));
COMMIT;