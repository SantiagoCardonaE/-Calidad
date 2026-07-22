-- ═══════════════════════════════════════════════════════════════════════
-- XTENSOR — Esquema de base de datos (Supabase / PostgreSQL)
-- Pega este archivo completo en: Supabase → SQL Editor → New query → Run
-- ═══════════════════════════════════════════════════════════════════════

create extension if not exists "pgcrypto";  -- para gen_random_uuid()

-- ───────────────────────────────────────────────────────────────────────
-- RECEPCIÓN
-- ───────────────────────────────────────────────────────────────────────
create table if not exists rec_registros (
  id          uuid primary key default gen_random_uuid(),
  categoria   text not null check (categoria in ('material','dobladas','inyectadas','cojines')),
  fecha       date not null default current_date,
  campos      jsonb not null default '{}'::jsonb,   -- campos específicos de cada categoría (proveedor, oc, tipo, etc.)
  resultado   text not null default 'Condicional' check (resultado in ('Aprobado','Condicional','Rechazado')),
  created_at  timestamptz not null default now()
);
create index if not exists idx_rec_categoria   on rec_registros(categoria);
create index if not exists idx_rec_created_at  on rec_registros(created_at desc);

-- ───────────────────────────────────────────────────────────────────────
-- CALIDAD
-- ───────────────────────────────────────────────────────────────────────
-- Un registro por máquina en inspección activa (se sobrescribe con upsert
-- cada vez que se marca un ítem, para no perder el progreso).
create table if not exists calidad_inspecciones (
  serial      text primary key,
  data        jsonb not null default '{}'::jsonb,  -- {stageData, inspectors, responsables, stageObs, currentStageIdx}
  updated_at  timestamptz not null default now()
);

-- Cuando una inspección llega al 100% se archiva aquí (histórico permanente).
create table if not exists calidad_historico (
  id            uuid primary key default gen_random_uuid(),
  serial        text not null,
  code          text,
  name          text,
  client        text,
  prometido     text,
  color         text,
  fecha_insp    text,
  conformes     int not null default 0,
  no_conformes  int not null default 0,
  total         int not null default 0,
  pct           int not null default 0,
  inspectors    text,
  stage_data    jsonb,
  created_at    timestamptz not null default now()
);
create index if not exists idx_cal_historico_created on calidad_historico(created_at desc);
create index if not exists idx_cal_historico_serial  on calidad_historico(serial);

-- ───────────────────────────────────────────────────────────────────────
-- GARANTÍAS
-- ───────────────────────────────────────────────────────────────────────
create table if not exists garantias_solicitudes (
  id                  uuid primary key default gen_random_uuid(),
  numero              bigserial unique,   -- correlativo generado por la BD (sin condiciones de carrera entre dispositivos)
  cliente             text not null,
  celular             text,
  direccion           text,
  fecha_visita        date,
  tecnico             text,
  serial_maquina      text,   -- serial de la máquina en Calidad desde la que se generó esta garantía (trazabilidad); null si se creó manualmente
  desc_garantia       text,
  obs                 text,
  estado              text not null default 'Pendiente'
                        check (estado in ('Pendiente','En revisión','Aprobada','Rechazada','Resuelta')),
  responsable         text,
  fecha_compromiso    date,
  firma_cliente       text,   -- dataURL base64 de la firma (PNG)
  firma_tecnico       text,
  fecha_registro      timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists idx_gar_created_at    on garantias_solicitudes(created_at desc);
create index if not exists idx_gar_estado        on garantias_solicitudes(estado);
create index if not exists idx_gar_serial_maquina on garantias_solicitudes(serial_maquina);

create table if not exists garantias_maquinas (
  id             uuid primary key default gen_random_uuid(),
  solicitud_id   uuid not null references garantias_solicitudes(id) on delete cascade,
  factura        text,
  fecha_compra   date,
  codigo         text,
  descripcion    text
);
create index if not exists idx_gar_maquinas_solicitud on garantias_maquinas(solicitud_id);

create table if not exists garantias_defectos (
  id                 uuid primary key default gen_random_uuid(),
  solicitud_id       uuid not null references garantias_solicitudes(id) on delete cascade,
  proceso            text,
  item               text,
  criterio           text,
  resultado          text,
  severidad          text check (severidad in ('Leve','Media','Crítica')),
  causa              text,
  accion             text,
  corregido          boolean not null default false,
  fecha_correccion   date
);
create index if not exists idx_gar_defectos_solicitud on garantias_defectos(solicitud_id);
create index if not exists idx_gar_defectos_pendientes on garantias_defectos(solicitud_id) where corregido = false;

-- Migración segura: si la tabla ya existía (proyecto ya desplegado), el
-- "create table if not exists" de arriba no agrega columnas nuevas.
-- Esta línea sí la agrega, sin afectar los datos existentes.
alter table garantias_solicitudes add column if not exists serial_maquina text;

-- trigger simple para mantener updated_at al día en solicitudes
create or replace function set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_gar_solicitudes_updated on garantias_solicitudes;
create trigger trg_gar_solicitudes_updated
  before update on garantias_solicitudes
  for each row execute function set_updated_at();

-- ───────────────────────────────────────────────────────────────────────
-- FUNCIÓN TRANSACCIONAL: crear una solicitud de garantía completa
-- (solicitud + máquinas + defectos) en una sola operación atómica.
-- Si algo falla a mitad de camino, no queda nada a medio guardar.
-- ───────────────────────────────────────────────────────────────────────
create or replace function crear_garantia(payload jsonb)
returns uuid
language plpgsql
as $$
declare
  new_id uuid;
  m jsonb;
  d jsonb;
begin
  insert into garantias_solicitudes
    (cliente, celular, direccion, fecha_visita, tecnico, serial_maquina, desc_garantia, obs,
     estado, responsable, fecha_compromiso, firma_cliente, firma_tecnico)
  values (
    payload->>'cliente',
    payload->>'celular',
    payload->>'direccion',
    nullif(payload->>'fechaVisita','')::date,
    payload->>'tecnico',
    nullif(payload->>'serialMaquina',''),
    payload->>'descGarantia',
    payload->>'obs',
    coalesce(nullif(payload->>'estado',''), 'Pendiente'),
    payload->>'responsable',
    nullif(payload->>'fechaCompromiso','')::date,
    payload->>'firmaCliente',
    payload->>'firmaTecnico'
  )
  returning id into new_id;

  for m in select * from jsonb_array_elements(coalesce(payload->'maquinas','[]'::jsonb)) loop
    insert into garantias_maquinas (solicitud_id, factura, fecha_compra, codigo, descripcion)
    values (new_id, m->>'factura', nullif(m->>'fechaCompra','')::date, m->>'codigo', m->>'desc');
  end loop;

  for d in select * from jsonb_array_elements(coalesce(payload->'defectos','[]'::jsonb)) loop
    insert into garantias_defectos (solicitud_id, proceso, item, criterio, resultado, severidad, causa, accion, corregido)
    values (new_id, d->>'proceso', d->>'item', d->>'criterio', d->>'resultado', d->>'severidad', d->>'causa', d->>'accion',
            coalesce((d->>'corregido')::boolean, false));
  end loop;

  return new_id;
end;
$$;

-- ───────────────────────────────────────────────────────────────────────
-- SEGURIDAD (RLS)
-- Sin autenticación por ahora: toda la empresa comparte una sola base de
-- datos, así que las políticas son abiertas para el rol "anon" (la app
-- usa la anon key pública). Quedan ya con RLS activado para que, cuando
-- se agregue login más adelante, sólo haya que CAMBIAR estas políticas
-- (ej. "using (auth.uid() is not null)") sin tocar el esquema ni el código.
-- ───────────────────────────────────────────────────────────────────────
alter table rec_registros         enable row level security;
alter table calidad_inspecciones  enable row level security;
alter table calidad_historico     enable row level security;
alter table garantias_solicitudes enable row level security;
alter table garantias_maquinas    enable row level security;
alter table garantias_defectos    enable row level security;

drop policy if exists anon_all on rec_registros;
create policy anon_all on rec_registros for all using (true) with check (true);

drop policy if exists anon_all on calidad_inspecciones;
create policy anon_all on calidad_inspecciones for all using (true) with check (true);

drop policy if exists anon_all on calidad_historico;
create policy anon_all on calidad_historico for all using (true) with check (true);

drop policy if exists anon_all on garantias_solicitudes;
create policy anon_all on garantias_solicitudes for all using (true) with check (true);

drop policy if exists anon_all on garantias_maquinas;
create policy anon_all on garantias_maquinas for all using (true) with check (true);

drop policy if exists anon_all on garantias_defectos;
create policy anon_all on garantias_defectos for all using (true) with check (true);

grant execute on function crear_garantia(jsonb) to anon, authenticated;

-- ───────────────────────────────────────────────────────────────────────
-- REALTIME — permite que todos los dispositivos vean cambios al instante
-- ───────────────────────────────────────────────────────────────────────
alter publication supabase_realtime add table rec_registros;
alter publication supabase_realtime add table calidad_inspecciones;
alter publication supabase_realtime add table calidad_historico;
alter publication supabase_realtime add table garantias_solicitudes;
alter publication supabase_realtime add table garantias_maquinas;
alter publication supabase_realtime add table garantias_defectos;

-- ═══════════════════════════════════════════════════════════════════════
-- Fin del esquema. Siguiente paso: Project Settings → API → copiar
-- "Project URL" y "anon public key" y pegarlos en la app (bloque CONFIG).
-- ═══════════════════════════════════════════════════════════════════════
