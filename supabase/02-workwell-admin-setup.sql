-- Workwell Interiors: admin dashboard setup
-- Run AFTER workwell-supabase-setup.sql. Safe to run more than once.

-- ---------- 1. Products: photos, show/hide, and the original name ----------
alter table public.products add column if not exists images      text[]  not null default '{}';
alter table public.products add column if not exists is_active   boolean not null default true;
alter table public.products add column if not exists legacy_name text;

-- The 21 products already on the website keep their original name as a stable key,
-- so you can rename them in the dashboard without losing their built-in photo.
update public.products set legacy_name = name where legacy_name is null;
create unique index if not exists products_legacy_name_key on public.products(legacy_name) where legacy_name is not null;

-- Make the database description match the website copy exactly
update public.products
   set description = 'Chrome tube, padded vinyl seat and back. Stacks of them look great in meeting rooms.'
 where name = 'Bottle-green cantilever chair';

do $$ begin
  alter table public.products add constraint products_images_max  check (cardinality(images) <= 12);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.products add constraint products_name_len    check (char_length(name) between 2 and 120);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.products add constraint products_desc_len    check (description is null or char_length(description) <= 600);
exception when duplicate_object then null; end $$;

create index if not exists orders_created_idx on public.orders(created_at desc);

-- ---------- 2. Who is an admin ----------
-- Only people listed here can use the dashboard. Nobody can add themselves:
-- there is no insert policy, so rows are added only from the Supabase SQL editor.
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
drop policy if exists "admins read own" on public.admins;
create policy "admins read own" on public.admins for select to authenticated using (auth.uid() = user_id);

create or replace function public.is_admin()
returns boolean
language sql
stable
set search_path = public
as $$ select exists (select 1 from public.admins a where a.user_id = (select auth.uid())) $$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

-- ---------- 3. Table permissions (least privilege) ----------
revoke all on public.admins, public.products, public.orders, public.order_items, public.profiles from anon, authenticated;
grant select on public.admins to anon, authenticated;                       -- rows are still limited by the policy above
grant select on public.products to anon, authenticated;
grant insert, update, delete on public.products to authenticated;           -- allowed for admins only (policies below)
grant select on public.orders to authenticated;
grant update (status) on public.orders to authenticated;                    -- an admin can change status, nothing else
grant delete on public.orders to authenticated;
grant select on public.order_items to authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, phone, location) on public.profiles to authenticated;

-- ---------- 4. Row-level security for the dashboard ----------
-- Products: the public sees only visible products; admins see and change everything
drop policy if exists "products public read" on public.products;
create policy "products public read" on public.products for select to anon, authenticated
  using (is_active or public.is_admin());
drop policy if exists "admin add products" on public.products;
create policy "admin add products" on public.products for insert to authenticated with check (public.is_admin());
drop policy if exists "admin edit products" on public.products;
create policy "admin edit products" on public.products for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin delete products" on public.products;
create policy "admin delete products" on public.products for delete to authenticated using (public.is_admin());

-- Orders: admins can read all orders, change status, delete. Clients still see only their own.
drop policy if exists "admin read orders" on public.orders;
create policy "admin read orders" on public.orders for select to authenticated using (public.is_admin());
drop policy if exists "admin update orders" on public.orders;
create policy "admin update orders" on public.orders for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin delete orders" on public.orders;
create policy "admin delete orders" on public.orders for delete to authenticated using (public.is_admin());
drop policy if exists "admin read order items" on public.order_items;
create policy "admin read order items" on public.order_items for select to authenticated using (public.is_admin());

-- ---------- 5. place_order(): also refuse hidden products ----------
create or replace function public.place_order(
  p_name     text,
  p_phone    text,
  p_location text,
  p_mpesa    text,
  p_items    jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order uuid;
  v_total integer := 0;
  v_item  jsonb;
  v_price integer;
  v_qty   integer;
begin
  if coalesce(length(trim(p_name)), 0) < 2 or length(p_name) > 100 then
    raise exception 'Please enter your name';
  end if;
  if coalesce(length(trim(p_phone)), 0) < 9 or length(p_phone) > 20 then
    raise exception 'Please enter a valid phone number';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'Your order is empty';
  end if;

  insert into public.orders (user_id, customer_name, phone, delivery_location, mpesa_code, total_kes)
  values (auth.uid(), trim(p_name), trim(p_phone), left(p_location, 200), left(p_mpesa, 30), 0)
  returning id into v_order;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := greatest(1, least(100, coalesce((v_item->>'qty')::int, 1)));
    select price_kes into v_price from public.products
      where name = v_item->>'name' and in_stock and is_active;
    if v_price is null then
      raise exception 'Item not available: %', v_item->>'name';
    end if;
    insert into public.order_items (order_id, product_name, unit_price_kes, quantity)
    values (v_order, v_item->>'name', v_price, v_qty);
    v_total := v_total + v_price * v_qty;
  end loop;

  update public.orders set total_kes = v_total where id = v_order;
  return v_order;
end;
$$;
revoke all on function public.place_order(text,text,text,text,jsonb) from public;
grant execute on function public.place_order(text,text,text,text,jsonb) to anon, authenticated;

-- ---------- 6. Product photo storage ----------
-- Public bucket: anyone can VIEW photos on the store; only admins can add or remove them.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = 5242880, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "admin upload product images" on storage.objects;
create policy "admin upload product images" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_admin());
drop policy if exists "admin update product images" on storage.objects;
create policy "admin update product images" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and public.is_admin()) with check (bucket_id = 'product-images' and public.is_admin());
drop policy if exists "admin delete product images" on storage.objects;
create policy "admin delete product images" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and public.is_admin());

-- ---------- 6b. Performance tidy (same rules, evaluated once per query, one read policy per table) ----------
drop policy if exists "profiles read own"   on public.profiles;
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles read own"   on public.profiles for select to authenticated using ((select auth.uid()) = id);
create policy "profiles update own" on public.profiles for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

drop policy if exists "admins read own" on public.admins;
create policy "admins read own" on public.admins for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "orders read own"   on public.orders;
drop policy if exists "admin read orders" on public.orders;
create policy "orders read" on public.orders for select to authenticated
  using ((select auth.uid()) = user_id or public.is_admin());

drop policy if exists "order items read own"   on public.order_items;
drop policy if exists "admin read order items" on public.order_items;
create policy "order items read" on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and o.user_id = (select auth.uid())) or public.is_admin());

-- ---------- 7. Make yourself the admin (run ONCE, after you create your login) ----------
-- 1) Supabase dashboard > Authentication > Users > Add user > Create new user
--    (type your email and a strong password, tick "Auto Confirm User").
-- 2) Then run this, with your email:
--
--   insert into public.admins (user_id)
--   select id from auth.users where email = 'YOUR-EMAIL-HERE'
--   on conflict do nothing;
