-- =====================================================================
-- Workwell Interiors: Supabase database setup
-- Run this once in Supabase: SQL Editor > New query > paste > Run.
-- It is safe to read first. Nothing here deletes existing data.
-- =====================================================================

-- ---------- 1. Client profiles (one row per logged-in client) ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  phone       text,
  location    text,
  created_at  timestamptz not null default now()
);

-- Create a profile automatically when a client signs up
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 2. Products ----------
create table if not exists public.products (
  id          bigint generated always as identity primary key,
  name        text not null unique,
  category    text not null,
  description text,
  price_kes   integer not null check (price_kes >= 0),
  in_stock    boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

-- ---------- 3. Orders and their items ----------
create table if not exists public.orders (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid references auth.users(id) on delete set null,  -- null = guest order
  customer_name     text not null,
  phone             text not null,
  delivery_location text,
  mpesa_code        text,
  total_kes         integer not null check (total_kes >= 0),
  status            text not null default 'new'
                    check (status in ('new','confirmed','paid','delivered','cancelled')),
  created_at        timestamptz not null default now()
);

create table if not exists public.order_items (
  id             bigint generated always as identity primary key,
  order_id       uuid not null references public.orders(id) on delete cascade,
  product_name   text not null,
  unit_price_kes integer not null,
  quantity       integer not null check (quantity between 1 and 100)
);

create index if not exists orders_user_idx on public.orders(user_id, created_at desc);
create index if not exists order_items_order_idx on public.order_items(order_id);

-- ---------- 4. Row-level security ----------
alter table public.profiles    enable row level security;
alter table public.products    enable row level security;
alter table public.orders      enable row level security;
alter table public.order_items enable row level security;

-- Profiles: a client can read and edit only their own
drop policy if exists "profiles read own"   on public.profiles;
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles read own"   on public.profiles for select using (auth.uid() = id);
create policy "profiles update own" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- Products: anyone can read, nobody can change them from the website
drop policy if exists "products public read" on public.products;
create policy "products public read" on public.products for select using (true);

-- Orders: a logged-in client can read only their own orders.
-- There is deliberately NO insert policy: orders are created only through
-- place_order() below, which checks prices on the server.
drop policy if exists "orders read own" on public.orders;
create policy "orders read own" on public.orders for select using (auth.uid() = user_id);

drop policy if exists "order items read own" on public.order_items;
create policy "order items read own" on public.order_items for select
  using (exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()));

-- ---------- 5. place_order(): safe way for the website to create an order ----------
-- Prices are looked up here, so a customer cannot change what they pay.
-- Works for guests (not logged in) and for logged-in clients.
create or replace function public.place_order(
  p_name     text,
  p_phone    text,
  p_location text,
  p_mpesa    text,
  p_items    jsonb      -- e.g. [{"name":"Olive armchair","qty":2}]
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
      where name = v_item->>'name' and in_stock;
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

-- ---------- 6. Your products (edit prices here any time) ----------
insert into public.products (name, category, description, price_kes, sort_order) values
 ('Walnut lounge chair','Chairs','Moss velvet cushions, solid wood frame',9000,1),
 ('Bottle-green cantilever chair','Chairs','Chrome tube, padded vinyl seat and back',9500,2),
 ('Saddle leather chair','Chairs','Polished steel, stitched leather sling',24000,3),
 ('Bolster-back chair','Chairs','Black leather, chrome legs',14500,4),
 ('Walnut slatted TV stand','Storage','Solid walnut, open shelves and two drawers',15000,5),
 ('Oak-finish TV stand','Storage','Two drawers, open shelf, black legs',4500,6),
 ('Olive armchair','Chairs','Curved fabric body, walnut-stained legs',10500,7),
 ('Leafy plant in woven pot','Plants','Tall green plant, ready to place',7200,8),
 ('Monstera in stone-effect pot','Plants','Large split leaves, textured pot',2400,9),
 ('Arc floor lamp','Lighting','Perforated metal shade, marble base',6500,10),
 ('Turntable with dust cover','Decor','Walnut-effect plinth, clear lid',12000,11),
 ('Cube pendant light trio','Lighting','Three black metal cubes on one ceiling plate',7200,12),
 ('Wire cage pendant light trio','Lighting','Three black wire shades in mixed shapes',3900,13),
 ('Smoked glass pendant light trio','Lighting','Three smoked glass globes with filament bulbs',5500,14),
 ('Black figure table lamp, seated','Lighting','Matte black shade, soft glowing body',5000,15),
 ('Black figure table lamp, leaning','Lighting','Matte black shade, soft glowing body',5000,16),
 ('Rust corduroy corner sofa','Sofas','Full set with chaise, soft corduroy fabric',124000,17),
 ('Walnut tripod floor lamp','Lighting','Wooden tripod legs, linen drum shade',12700,18),
 ('Black tripod floor lamp','Lighting','Matte black legs, black drum shade',11000,19),
 ('Mustard velvet sofa','Sofas','Soft velvet, wooden arm supports',34000,20),
 ('Olive linen sofa','Sofas','Linen-look fabric, wooden arm supports',34000,21)
on conflict (name) do update
  set price_kes = excluded.price_kes,
      category = excluded.category,
      description = excluded.description,
      sort_order = excluded.sort_order;

-- =====================================================================
-- Done. To see orders: Table Editor > orders (and order_items).
-- To change a price: Table Editor > products > edit price_kes.
-- =====================================================================
