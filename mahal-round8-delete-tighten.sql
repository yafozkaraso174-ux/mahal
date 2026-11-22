-- جولة ٨: ربط المسح النهائي بصلاحية "مسح بيانات" في كل الجداول
-- الجلسة السابقة كانت بتسمح بالمسح النهائي بصلاحية التعديل العادية (أصناف/زباين/موردين/طلبات)
drop policy if exists "perm delete products" on public.products;
create policy "perm delete products" on public.products for delete to authenticated
  using (public.has_shop_perm('del'));
drop policy if exists "perm delete customers" on public.customers;
create policy "perm delete customers" on public.customers for delete to authenticated
  using (public.has_shop_perm('del'));
drop policy if exists "perm delete suppliers" on public.suppliers;
create policy "perm delete suppliers" on public.suppliers for delete to authenticated
  using (public.has_shop_perm('del'));
drop policy if exists "perm delete orders" on public.orders;
create policy "perm delete orders" on public.orders for delete to authenticated
  using (public.has_shop_perm('del'));
-- تحقق ذاتي
select (select count(*) from pg_policies where schemaname='public' and cmd='DELETE' and qual like '%has_shop_perm(''del'')%') as del_policies_with_del_flag;
