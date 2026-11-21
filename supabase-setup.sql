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
  photo_url text,
  updated_at timestamptz default now()
);

-- لو الجدول اتعمل قبل كده من غير عمود الصور
alter table products add column if not exists photo_url text;

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
create policy "public read products" on products for select to public using (true);

drop policy if exists "public read shop_info" on shop_info;
create policy "public read shop_info" on shop_info for select to public using (true);

-- الزوار: يقدروا يبعتوا طلب جديد، من غير ما يشوفوا طلبات حد تاني ولا يغيّروا حاجة
drop policy if exists "public insert orders" on orders;
create policy "public insert orders" on orders for insert to public with check (true);

-- صاحب المحل (الحساب المسجل في Authentication): صلاحية كاملة
drop policy if exists "owner all products" on products;
create policy "owner all products" on products for all to authenticated using (true) with check (true);

drop policy if exists "owner all shop_info" on shop_info;
create policy "owner all shop_info" on shop_info for all to authenticated using (true) with check (true);

drop policy if exists "owner all orders" on orders;
create policy "owner all orders" on orders for all to authenticated using (true) with check (true);

-- ============================================================
-- صور الأصناف (Supabase Storage)
-- ============================================================

-- باكت عام للصور (الزوار يشوفوا الصور، بس محدش يقدر يرفع أو يعدّل غير صاحب المحل)
insert into storage.buckets (id, name, public)
values ('product-photos', 'product-photos', true)
on conflict (id) do nothing;

drop policy if exists "public read product photos" on storage.objects;
create policy "public read product photos" on storage.objects for select to public
using (bucket_id = 'product-photos');

drop policy if exists "owner write product photos" on storage.objects;
create policy "owner write product photos" on storage.objects for all to authenticated
using (bucket_id = 'product-photos') with check (bucket_id = 'product-photos');

-- ============================================================
-- تحديث ٢١ نوفمبر ٢٠٢٦: الدليفري وطرق الدفع
-- لو الجداول عندك اتعملت قبل التحديث ده، شغّل الأسطر دي مرة واحدة
-- ============================================================
alter table shop_info add column if not exists payment jsonb;
alter table shop_info add column if not exists delivery_fee numeric not null default 0;
alter table shop_info add column if not exists zones jsonb;
alter table orders add column if not exists delivery text;
alter table orders add column if not exists payment text;
alter table orders add column if not exists address text;
alter table orders add column if not exists delivery_fee numeric not null default 0;
alter table orders add column if not exists zone text;
