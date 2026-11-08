-- Iligan Services Platform: Supabase schema (v2)
-- Run in the Supabase SQL editor on a fresh project (or a reset dev database).

create extension if not exists btree_gist;

-- ENUMS
create type user_role as enum ('customer', 'provider', 'admin');
create type booking_status as enum ('pending', 'confirmed', 'cancelled', 'completed');
create type price_unit as enum ('per_hour', 'per_session', 'per_day', 'per_project', 'per_item', 'fixed');

-- PROFILES
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  phone text,
  avatar_url text,
  role user_role not null default 'customer',
  created_at timestamptz not null default now()
);

-- CATEGORIES
create table categories (
  id serial primary key,
  name text not null unique,
  icon text
);

insert into categories (name, icon) values
  ('Production', 'video'),
  ('Tutoring', 'book-open'),
  ('Repair', 'wrench'),
  ('Events', 'calendar'),
  ('Popup Stores', 'store');

-- PROVIDERS
create table providers (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles(id) on delete cascade,
  business_name text not null,
  description text,
  barangay text,
  address text,
  lat double precision,
  lng double precision,
  contact text,
  is_verified boolean not null default false,
  created_at timestamptz not null default now()
);
create index on providers (owner_id);
create index on providers (barangay);

-- SERVICES
create table services (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references providers(id) on delete cascade,
  category_id int not null references categories(id),
  title text not null,
  description text,
  price numeric(10,2) check (price >= 0),
  price_unit price_unit not null default 'fixed',
  photos text[] not null default '{}',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index on services (provider_id);
create index on services (category_id);

-- AVAILABILITY: weekly recurring slots (0 = Sunday), optionally limited to a date range
-- e.g. a seasonal tutoring schedule: valid_from / valid_to
create table availability (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references services(id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 0 and 6),
  start_time time not null,
  end_time time not null,
  valid_from date,
  valid_to date,
  check (end_time > start_time),
  check (valid_to is null or valid_from is null or valid_to >= valid_from)
);
create index on availability (service_id);

-- EVENT DATES: one-off slots on specific dates (Popup Stores, Events, one-time workshops)
create table event_dates (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references services(id) on delete cascade,
  event_date date not null,
  start_time time not null,
  end_time time not null,
  location_note text,            -- e.g. "Robinsons Place Iligan, ground floor"
  capacity int,                  -- null = one booking at a time (see double-booking rule)
  check (end_time > start_time)
);
create index on event_dates (service_id, event_date);

-- BOOKINGS
create table bookings (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references services(id) on delete restrict,
  customer_id uuid not null references profiles(id) on delete cascade,
  date date not null,
  start_time time not null,
  end_time time not null,
  status booking_status not null default 'pending',
  notes text,
  created_at timestamptz not null default now(),
  check (end_time > start_time),

  -- DOUBLE-BOOKING GUARD: no two active bookings for the same service may overlap in time.
  -- Cancelled and completed bookings don't block the slot.
  constraint no_overlapping_bookings exclude using gist (
    service_id with =,
    tsrange(date + start_time, date + end_time) with &&
  ) where (status in ('pending', 'confirmed'))
);
create index on bookings (service_id, date);
create index on bookings (customer_id);

-- Booking must fall inside a weekly availability slot or a specific event date
create or replace function check_booking_in_availability() returns trigger
language plpgsql as $$
begin
  if exists (
    select 1 from availability a
    where a.service_id = new.service_id
      and a.day_of_week = extract(dow from new.date)
      and new.start_time >= a.start_time and new.end_time <= a.end_time
      and (a.valid_from is null or new.date >= a.valid_from)
      and (a.valid_to   is null or new.date <= a.valid_to)
  ) or exists (
    select 1 from event_dates e
    where e.service_id = new.service_id
      and e.event_date = new.date
      and new.start_time >= e.start_time and new.end_time <= e.end_time
  ) then
    return new;
  end if;
  raise exception 'Requested time is outside the provider''s availability'
    using errcode = 'P0001';
end;
$$;

create trigger bookings_check_availability
  before insert on bookings
  for each row execute function check_booking_in_availability();

-- REVIEWS
create table reviews (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references bookings(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

-- HELPERS
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

-- Auto-create a profile on signup (always as 'customer')
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ROLE CHANGE CONTROL
-- Direct role edits are blocked. Allowed paths:
--   1. become_provider()  : a customer upgrades themselves to provider (never admin)
--   2. set_user_role()    : admins only
--   3. SQL editor / service-role key (auth.uid() is null), e.g. the first admin
create or replace function block_role_change() returns trigger
language plpgsql as $$
begin
  if new.role is distinct from old.role
     and auth.uid() is not null
     and coalesce(current_setting('app.allow_role_change', true), '') <> 'on' then
    raise exception 'Role cannot be changed directly' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_block_role_change
  before update on profiles
  for each row execute function block_role_change();

create or replace function become_provider() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.allow_role_change', 'on', true);
  update profiles set role = 'provider'
   where id = auth.uid() and role = 'customer';
end;
$$;

create or replace function set_user_role(target uuid, new_role user_role) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;
  perform set_config('app.allow_role_change', 'on', true);
  update profiles set role = new_role where id = target;
end;
$$;

revoke all on function set_user_role(uuid, user_role) from public, anon;
grant execute on function set_user_role(uuid, user_role) to authenticated;
revoke all on function become_provider() from public, anon;
grant execute on function become_provider() to authenticated;

-- First admin (run manually in the SQL editor, with your own user id):
-- update profiles set role = 'admin' where id = '<your-auth-user-uuid>';

-- ROW LEVEL SECURITY
alter table profiles enable row level security;
alter table categories enable row level security;
alter table providers enable row level security;
alter table services enable row level security;
alter table availability enable row level security;
alter table event_dates enable row level security;
alter table bookings enable row level security;
alter table reviews enable row level security;

-- profiles
create policy "profiles read own" on profiles for select using (id = auth.uid() or is_admin());
create policy "profiles update own" on profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- categories
create policy "categories public read" on categories for select using (true);
create policy "categories admin write" on categories for all using (is_admin()) with check (is_admin());

-- providers (only users with the provider or admin role can create one)
create policy "providers public read" on providers for select
  using (is_verified or owner_id = auth.uid() or is_admin());
create policy "providers owner insert" on providers for insert with check (
  owner_id = auth.uid()
  and exists (select 1 from profiles where id = auth.uid() and role in ('provider', 'admin'))
);
create policy "providers owner update" on providers for update
  using (owner_id = auth.uid() or is_admin())
  with check (owner_id = auth.uid() or is_admin());
create policy "providers owner delete" on providers for delete
  using (owner_id = auth.uid() or is_admin());

-- Providers must not verify themselves
create or replace function block_self_verification() returns trigger
language plpgsql as $$
begin
  if new.is_verified is distinct from old.is_verified
     and auth.uid() is not null and not is_admin() then
    raise exception 'Only admins can verify providers' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger providers_block_self_verification
  before update on providers
  for each row execute function block_self_verification();

-- services
create policy "services public read" on services for select using (
  (is_active and exists (select 1 from providers p where p.id = provider_id and p.is_verified))
  or exists (select 1 from providers p where p.id = provider_id and p.owner_id = auth.uid())
  or is_admin()
);
create policy "services owner write" on services for all
  using (exists (select 1 from providers p where p.id = provider_id and p.owner_id = auth.uid()) or is_admin())
  with check (exists (select 1 from providers p where p.id = provider_id and p.owner_id = auth.uid()) or is_admin());

-- availability
create policy "availability public read" on availability for select using (true);
create policy "availability owner write" on availability for all
  using (exists (select 1 from services s join providers p on p.id = s.provider_id
                 where s.id = service_id and p.owner_id = auth.uid()) or is_admin())
  with check (exists (select 1 from services s join providers p on p.id = s.provider_id
                      where s.id = service_id and p.owner_id = auth.uid()) or is_admin());

-- event_dates
create policy "event_dates public read" on event_dates for select using (true);
create policy "event_dates owner write" on event_dates for all
  using (exists (select 1 from services s join providers p on p.id = s.provider_id
                 where s.id = service_id and p.owner_id = auth.uid()) or is_admin())
  with check (exists (select 1 from services s join providers p on p.id = s.provider_id
                      where s.id = service_id and p.owner_id = auth.uid()) or is_admin());

-- bookings
create policy "bookings read" on bookings for select using (
  customer_id = auth.uid()
  or exists (select 1 from services s join providers p on p.id = s.provider_id
             where s.id = service_id and p.owner_id = auth.uid())
  or is_admin()
);
create policy "bookings customer insert" on bookings for insert
  with check (customer_id = auth.uid() and status = 'pending');
create policy "bookings update" on bookings for update using (
  customer_id = auth.uid()
  or exists (select 1 from services s join providers p on p.id = s.provider_id
             where s.id = service_id and p.owner_id = auth.uid())
  or is_admin()
);

-- reviews
create policy "reviews public read" on reviews for select using (true);
create policy "reviews customer insert" on reviews for insert with check (
  exists (select 1 from bookings b
          where b.id = booking_id and b.customer_id = auth.uid() and b.status = 'completed')
);