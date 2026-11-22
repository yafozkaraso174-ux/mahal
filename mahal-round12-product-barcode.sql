-- round 12: barcode column on products
alter table products add column if not exists barcode text not null default '';
