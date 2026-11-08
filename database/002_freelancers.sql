-- Migration: support freelancers (individuals) alongside businesses
-- Run AFTER schema.sql.

create type provider_type as enum ('freelancer', 'business');

alter table providers
  add column provider_type provider_type not null default 'business',
  add column display_name text,            -- person's (stage) name or the business name shown on cards
  add column headline text,                -- e.g. 'Bridal HMUA', 'Hip-hop choreographer'
  add column portfolio_links jsonb not null default '[]',   -- [{"label":"Instagram","url":"..."}]
  add column years_experience smallint check (years_experience >= 0),
  add column service_areas text[] not null default '{}',    -- barangays they will travel to
  add column is_mobile boolean not null default false;      -- travels to the client's venue

-- Existing rows: show the business name as the display name
update providers set display_name = business_name where display_name is null;
alter table providers alter column display_name set not null;

-- Freelancers may not have a business name
alter table providers alter column business_name drop not null;
alter table providers add constraint business_needs_name
  check (provider_type = 'freelancer' or business_name is not null);

-- One freelancer profile per person
create unique index one_freelancer_per_owner
  on providers (owner_id) where provider_type = 'freelancer';

create index on providers (provider_type);

-- Bookings: where the service happens (client's venue for mobile freelancers like an HMUA)
alter table bookings add column venue text;

-- Categories that fit freelancers better than Production or Events
insert into categories (name, icon) values
  ('Beauty & Makeup', 'sparkles'),
  ('Performing Arts', 'music')
on conflict (name) do nothing;