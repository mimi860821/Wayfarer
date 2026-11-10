-- Database setup for the iKiwi shared list (run once in the Supabase SQL Editor).
-- The table is locked; the app only talks to two functions that require a room code.

create table if not exists public.ikiwi_items (
  room text not null,
  id uuid not null,
  name text not null default '',
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  category text not null default '',
  note text not null default '',
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (room, id)
);

create index if not exists ikiwi_items_room_updated
  on public.ikiwi_items (room, updated_at);

alter table public.ikiwi_items enable row level security;
revoke all on public.ikiwi_items from anon, authenticated;

create or replace function public.ikiwi_pull(p_room text, p_since timestamptz default 'epoch')
returns setof public.ikiwi_items
language plpgsql security definer set search_path = public as $$
begin
  if length(p_room) < 20 then raise exception 'bad room'; end if;
  return query
    select * from public.ikiwi_items
    where room = p_room and updated_at > p_since
    order by updated_at;
end $$;

create or replace function public.ikiwi_push(p_room text, p_items jsonb)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  it jsonb;
  t timestamptz := clock_timestamp();
begin
  if length(p_room) < 20 then raise exception 'bad room'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 200 then
    raise exception 'bad items';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into public.ikiwi_items (room, id, name, lat, lng, category, note, deleted, updated_at)
    values (
      p_room, (it->>'id')::uuid,
      left(coalesce(it->>'name', ''), 200),
      (it->>'lat')::float8, (it->>'lng')::float8,
      left(coalesce(it->>'category', ''), 100),
      left(coalesce(it->>'note', ''), 1000),
      coalesce((it->>'deleted')::boolean, false),
      t
    )
    on conflict (room, id) do update set
      name = excluded.name, lat = excluded.lat, lng = excluded.lng,
      category = excluded.category, note = excluded.note,
      deleted = excluded.deleted, updated_at = t;
  end loop;
  return t;
end $$;

revoke all on function public.ikiwi_pull(text, timestamptz) from public;
revoke all on function public.ikiwi_push(text, jsonb) from public;
grant execute on function public.ikiwi_pull(text, timestamptz) to anon;
grant execute on function public.ikiwi_push(text, jsonb) to anon;
