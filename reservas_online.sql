-- Reservas online: funciones públicas (sin acceso directo a las tablas).
create table if not exists public.res_intentos (
  id bigserial primary key,
  clave text not null,
  at timestamptz not null default now()
);
create index if not exists res_intentos_idx on public.res_intentos (clave, at);
alter table public.res_intentos enable row level security;
create index if not exists res_docs_token_idx on public.res_docs ((data->>'cancelToken')) where col = 'reservations';
create index if not exists res_docs_cust_idx on public.res_docs ((data->>'customerId')) where col = 'reservations';

create or replace function public.res_min(t text) returns int
language sql immutable set search_path = public as $$
  select split_part(t, ':', 1)::int * 60 + coalesce(nullif(split_part(t, ':', 2), '')::int, 0)
$$;

create or replace function public.res_norm_phone(s text) returns text
language plpgsql immutable set search_path = public as $$
declare d text := regexp_replace(coalesce(s, ''), '[\s().-]', '', 'g');
begin
  if left(d, 2) = '00' then d := '+' || substr(d, 3); end if;
  if left(d, 3) = '+34' then d := substr(d, 4);
  elsif left(d, 1) <> '+' and d ~ '^34\d{9}$' then d := substr(d, 3);
  end if;
  return d;
end $$;

create or replace function public.res_cfg() returns jsonb
language sql stable security definer set search_path = public as $$
  select data from public.res_docs where col = 'config' and id = 'main'
$$;

create or replace function public.res_dur(cfg jsonb, p_size int) returns int
language sql stable set search_path = public as $$
  select coalesce(
    (select (r->>'minutes')::int from jsonb_array_elements(coalesce(cfg->'durationRules', '[]'::jsonb)) r
      where (r->>'from')::int <= p_size order by (r->>'from')::int desc limit 1),
    coalesce((cfg->>'durationBase')::int, 90))
$$;

-- Turno al que pertenece una hora (misma regla que la web) o null si no es una hora ofrecida.
create or replace function public.res_slot_shift(cfg jsonb, p_time text) returns text
language plpgsql stable set search_path = public as $$
declare sh jsonb; m int; step int := coalesce((cfg->>'slotStep')::int, 15); ok boolean := false; sid text;
begin
  if p_time !~ '^\d{2}:\d{2}$' then return null; end if;
  m := res_min(p_time);
  for sh in select s from jsonb_array_elements(cfg->'shifts') s order by res_min(s->>'start') loop
    if m >= res_min(sh->>'start') and m <= res_min(sh->>'end') and (m - res_min(sh->>'start')) % step = 0 then ok := true; end if;
  end loop;
  if not ok then return null; end if;
  select s->>'id' into sid from jsonb_array_elements(cfg->'shifts') s
    where m <= res_min(s->>'end') order by res_min(s->>'start') limit 1;
  if sid is null then
    select s->>'id' into sid from jsonb_array_elements(cfg->'shifts') s order by res_min(s->>'start') desc limit 1;
  end if;
  return sid;
end $$;

create or replace function public.res_mesa_libre(cfg jsonb, p_date text, p_min int, p_size int) returns text
language plpgsql stable security definer set search_path = public as $$
declare base int := coalesce((cfg->>'durationBase')::int, 90); dur int := res_dur(cfg, p_size); tid text;
begin
  select t->>'id' into tid
  from jsonb_array_elements(coalesce(cfg->'tables', '[]'::jsonb)) t
  where coalesce((t->>'online')::boolean, true)
    and (t->>'seats')::int >= p_size and (t->>'seats')::int <= p_size + 2
    and not exists (
      select 1 from public.res_docs r
      where r.col = 'reservations' and r.data->>'date' = p_date
        and r.data->>'status' in ('confirmada', 'sentada')
        and r.data->'tables' ? (t->>'id')
        and p_min < res_min(r.data->>'time') + coalesce((r.data->>'duration')::int, base)
        and res_min(r.data->>'time') < p_min + dur)
  order by (t->>'seats')::int, coalesce(nullif(regexp_replace(t->>'label', '\D', '', 'g'), '')::int, 9999), t->>'label'
  limit 1;
  return tid;
end $$;

-- Comprobaciones comunes de fecha y tamaño. Devuelve un código de error o null.
create or replace function public.res_chequeo(cfg jsonb, p_date date, p_size int) returns text
language plpgsql stable set search_path = public as $$
declare o jsonb := coalesce(cfg->'online', '{}'::jsonb); hoy date := (now() at time zone 'Europe/Madrid')::date;
begin
  if cfg is null or coalesce((o->>'enabled')::boolean, false) is not true then return 'desactivado'; end if;
  if p_size is null or p_size < 1 then return 'tamano'; end if;
  if p_size > coalesce((o->>'maxSize')::int, 8) then return 'grupo_grande'; end if;
  if p_date is null or p_date < hoy or p_date > hoy + coalesce((o->>'maxDaysAhead')::int, 60) then return 'fecha'; end if;
  if coalesce(o->'closedDates', '[]'::jsonb) ? to_char(p_date, 'YYYY-MM-DD') then return 'cerrado'; end if;
  return null;
end $$;

create or replace function public.res_pub_config() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cfg jsonb := res_cfg(); o jsonb;
begin
  if cfg is null then return jsonb_build_object('enabled', false); end if;
  o := coalesce(cfg->'online', '{}'::jsonb);
  return jsonb_build_object(
    'enabled', coalesce((o->>'enabled')::boolean, false),
    'name', coalesce(o->>'name', ''),
    'phone', coalesce(o->>'phone', ''),
    'maxSize', coalesce((o->>'maxSize')::int, 8),
    'minAdvanceH', coalesce((o->>'minAdvanceH')::numeric, 2),
    'maxDaysAhead', coalesce((o->>'maxDaysAhead')::int, 60),
    'closedDates', coalesce(o->'closedDates', '[]'::jsonb),
    'shifts', (select coalesce(jsonb_agg(jsonb_build_object('id', s->>'id', 'name', s->>'name', 'start', s->>'start', 'end', s->>'end') order by res_min(s->>'start')), '[]'::jsonb) from jsonb_array_elements(cfg->'shifts') s));
end $$;

create or replace function public.res_pub_disponibilidad(p_date date, p_size int) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cfg jsonb := res_cfg(); err text; o jsonb; step int; sh jsonb; m int; out jsonb := '[]'::jsonb; slots jsonb;
  ahora timestamp := now() at time zone 'Europe/Madrid'; adv numeric; ds text := to_char(p_date, 'YYYY-MM-DD');
begin
  err := res_chequeo(cfg, p_date, p_size);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  o := coalesce(cfg->'online', '{}'::jsonb);
  adv := coalesce((o->>'minAdvanceH')::numeric, 2);
  step := coalesce((cfg->>'slotStep')::int, 15);
  for sh in select s from jsonb_array_elements(cfg->'shifts') s order by res_min(s->>'start') loop
    slots := '[]'::jsonb;
    m := res_min(sh->>'start');
    while m <= res_min(sh->>'end') loop
      if (p_date + make_interval(mins => m)) >= ahora + make_interval(secs => (adv * 3600)::int)
         and res_mesa_libre(cfg, ds, m, p_size) is not null then
        slots := slots || to_jsonb(lpad((m / 60)::text, 2, '0') || ':' || lpad((m % 60)::text, 2, '0'));
      end if;
      m := m + step;
    end loop;
    out := out || jsonb_build_object('id', sh->>'id', 'name', sh->>'name', 'slots', slots);
  end loop;
  return jsonb_build_object('ok', true, 'shifts', out);
end $$;

create or replace function public.res_pub_reservar(p_date date, p_time text, p_size int, p_name text, p_phone text, p_email text, p_notes text, p_privacy boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare cfg jsonb := res_cfg(); err text; o jsonb; ph text := res_norm_phone(p_phone); em text := lower(trim(coalesce(p_email, '')));
  nm text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'); sid text; m int; ds text := to_char(p_date, 'YYYY-MM-DD');
  ahora timestamp := now() at time zone 'Europe/Madrid'; adv numeric; ip text; tid text; cid text; rid text := gen_random_uuid()::text;
  tok text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''); dur int; nowts text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  hdr jsonb;
begin
  err := res_chequeo(cfg, p_date, p_size);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  o := coalesce(cfg->'online', '{}'::jsonb);
  if p_privacy is not true then return jsonb_build_object('ok', false, 'error', 'privacidad'); end if;
  if length(nm) < 2 or length(nm) > 80 then return jsonb_build_object('ok', false, 'error', 'nombre'); end if;
  if not (ph ~ '^[6-9]\d{8}$' or ph ~ '^\+\d{8,15}$') then return jsonb_build_object('ok', false, 'error', 'telefono'); end if;
  if em !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' or length(em) > 120 then return jsonb_build_object('ok', false, 'error', 'email'); end if;
  p_notes := left(trim(coalesce(p_notes, '')), 300);
  sid := res_slot_shift(cfg, p_time);
  if sid is null then return jsonb_build_object('ok', false, 'error', 'hora'); end if;
  m := res_min(p_time);
  adv := coalesce((o->>'minAdvanceH')::numeric, 2);
  if (p_date + make_interval(mins => m)) < ahora + make_interval(secs => (adv * 3600)::int) then
    return jsonb_build_object('ok', false, 'error', 'antelacion');
  end if;

  -- límite de intentos (teléfono, correo, IP) en la última hora
  begin hdr := nullif(current_setting('request.headers', true), '')::jsonb; exception when others then hdr := null; end;
  ip := coalesce(split_part(coalesce(hdr->>'x-forwarded-for', hdr->>'cf-connecting-ip', '?'), ',', 1), '?');
  delete from public.res_intentos where at < now() - interval '1 day';
  insert into public.res_intentos (clave) values ('p:' || ph), ('e:' || em), ('i:' || trim(ip));
  if (select count(*) from public.res_intentos where clave = 'p:' || ph and at > now() - interval '1 hour') > 6
     or (select count(*) from public.res_intentos where clave = 'e:' || em and at > now() - interval '1 hour') > 6
     or (select count(*) from public.res_intentos where clave = 'i:' || trim(ip) and at > now() - interval '1 hour') > 20 then
    return jsonb_build_object('ok', false, 'error', 'demasiados');
  end if;

  perform pg_advisory_xact_lock(hashtext('res:' || ds));

  -- misma persona, mismo turno y día: no duplicar
  if exists (select 1 from public.res_docs r where r.col = 'reservations' and r.data->>'date' = ds and r.data->>'status' = 'confirmada'
             and r.data->>'shiftId' = sid and (r.data->>'phone' = ph or lower(r.data->>'email') = em)) then
    return jsonb_build_object('ok', false, 'error', 'duplicada');
  end if;
  -- máximo de reservas futuras abiertas por teléfono
  if (select count(*) from public.res_docs r where r.col = 'reservations' and r.data->>'status' = 'confirmada'
        and r.data->>'date' >= to_char(ahora, 'YYYY-MM-DD') and r.data->>'phone' = ph) >= 3 then
    return jsonb_build_object('ok', false, 'error', 'limite');
  end if;

  tid := res_mesa_libre(cfg, ds, m, p_size);
  if tid is null then return jsonb_build_object('ok', false, 'error', 'sin_mesa'); end if;
  dur := res_dur(cfg, p_size);

  -- cliente: por teléfono o correo; si no existe, se crea
  select r.id into cid from public.res_docs r where r.col = 'customers' and (r.data->>'phone' = ph or lower(r.data->>'email') = em)
    order by (r.data->>'phone' = ph) desc limit 1;
  if cid is null then
    cid := gen_random_uuid()::text;
    insert into public.res_docs (col, id, data) values ('customers', cid, jsonb_build_object('name', nm, 'phone', ph, 'email', em, 'notes', '', 'source', 'online', 'createdAt', nowts, 'updatedAt', nowts));
  end if;

  insert into public.res_docs (col, id, data) values ('reservations', rid, jsonb_build_object(
    'date', ds, 'shiftId', sid, 'time', p_time, 'size', p_size, 'name', nm, 'phone', ph, 'email', em, 'notes', p_notes,
    'tables', jsonb_build_array(tid), 'duration', dur, 'status', 'confirmada', 'source', 'online', 'customerId', cid,
    'cancelToken', tok, 'createdAt', nowts, 'updatedAt', nowts));

  return jsonb_build_object('ok', true, 'token', tok, 'date', ds, 'time', p_time, 'size', p_size, 'name', nm, 'duration', dur);
end $$;

create or replace function public.res_pub_ver(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r public.res_docs; ahora timestamp := now() at time zone 'Europe/Madrid';
begin
  if p_token is null or length(p_token) < 32 then return jsonb_build_object('ok', false, 'error', 'no_existe'); end if;
  select * into r from public.res_docs where col = 'reservations' and data->>'cancelToken' = p_token;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_existe'); end if;
  return jsonb_build_object('ok', true, 'date', r.data->>'date', 'time', r.data->>'time', 'size', (r.data->>'size')::int,
    'name', r.data->>'name', 'status', r.data->>'status',
    'canCancel', r.data->>'status' = 'confirmada' and ((r.data->>'date')::date + make_interval(mins => res_min(r.data->>'time'))) > ahora);
end $$;

create or replace function public.res_pub_cancelar(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r public.res_docs; ahora timestamp := now() at time zone 'Europe/Madrid';
begin
  if p_token is null or length(p_token) < 32 then return jsonb_build_object('ok', false, 'error', 'no_existe'); end if;
  select * into r from public.res_docs where col = 'reservations' and data->>'cancelToken' = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_existe'); end if;
  if r.data->>'status' <> 'confirmada' then return jsonb_build_object('ok', false, 'error', 'estado', 'status', r.data->>'status'); end if;
  if ((r.data->>'date')::date + make_interval(mins => res_min(r.data->>'time'))) <= ahora then return jsonb_build_object('ok', false, 'error', 'pasada'); end if;
  update public.res_docs set data = data || jsonb_build_object('status', 'cancelada', 'cancelledBy', 'cliente', 'updatedAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')), updated_at = now()
    where col = r.col and id = r.id;
  return jsonb_build_object('ok', true);
end $$;

-- Permisos: solo las funciones públicas pueden llamarlas los visitantes.
revoke all on function public.res_min(text), public.res_norm_phone(text), public.res_cfg(), public.res_dur(jsonb, int),
  public.res_slot_shift(jsonb, text), public.res_mesa_libre(jsonb, text, int, int), public.res_chequeo(jsonb, date, int) from public, anon, authenticated;
revoke all on function public.res_pub_config(), public.res_pub_disponibilidad(date, int),
  public.res_pub_reservar(date, text, int, text, text, text, text, boolean), public.res_pub_ver(text), public.res_pub_cancelar(text) from public;
grant execute on function public.res_pub_config(), public.res_pub_disponibilidad(date, int),
  public.res_pub_reservar(date, text, int, text, text, text, text, boolean), public.res_pub_ver(text), public.res_pub_cancelar(text) to anon, authenticated;
