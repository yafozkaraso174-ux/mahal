-- ============================================================
-- محلي — إعداد قاعدة بيانات المتجر الإلكتروني (Supabase)
-- شغّل السكربت ده مرة واحدة في: SQL Editor ← New query ← Paste ← Run
-- ============================================================

-- جدول الأصناف (بيتملى من البرنامج بزرار "نزّل الأصناف على المتجر")
create table if not exists products (
  id text primary key,
  name text not null,
  cat text,
  unit text,
  price numeric not null default 0,
  stock numeric not null default 0,
  updated_at timestamptz default now()
);

-- جدول بيانات المحل (اسم المحل ورقم الواتساب اللي يظهر للزباين)
create table if not exists shop_info (
  id int primary key,
  shop_name text,
  owner_name text,
  phone text,
  updated_at timestamptz default now()
);

-- جدول الطلبات (الزباين بيبعتوا من المتجر، وصاحب المحل بيشوفها في البرنامج)
create table if not exists orders (
  id bigint generated always as identity primary key,
  customer_name text not null,
  phone text,
  note text,
  items jsonb not null,
  total numeric not null default 0,
  status text not null default 'new',
  created_at timestamptz not null default now()
);

create index if not exists orders_created_at_idx on orders (created_at desc);
create index if not exists orders_status_idx on orders (status);

-- تفعيل الحماية على الجداول
alter table products enable row level security;
alter table shop_info enable row level security;
alter table orders enable row level security;

-- الزوار (من غير تسجيل دخول): يشوفوا الأصناف وبيانات المحل بس
drop policy if exists "public read products" on products;
create policy "public read products" on products for select to anon using (true);

drop policy if exists "public read shop_info" on shop_info;
create policy "public read shop_info" on shop_info for select to anon using (true);

-- الزوار: يقدروا يبعتوا طلب جديد، من غير ما يشوفوا طلبات حد تاني ولا يغيّروا حاجة
drop policy if exists "public insert orders" on orders;
create policy "public insert orders" on orders for insert to anon with check (true);

-- صاحب المحل (الحساب المسجل في Authentication): صلاحية كاملة
drop policy if exists "owner all products" on products;
create policy "owner all products" on products for all to authenticated using (true) with check (true);

drop policy if exists "owner all shop_info" on shop_info;
create policy "owner all shop_info" on shop_info for all to authenticated using (true) with check (true);

drop policy if exists "owner all orders" on orders;
create policy "owner all orders" on orders for all to authenticated using (true) with check (true);
