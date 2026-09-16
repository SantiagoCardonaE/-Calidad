-- ═══════════════════════════════════════════════════════════════════════
-- XTENSOR — Esquema de base de datos (Supabase / PostgreSQL)
-- Pega este archivo completo en: Supabase → SQL Editor → New query → Run
-- ═══════════════════════════════════════════════════════════════════════

begin;
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
  machine_key   text,
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
create index if not exists idx_cal_historico_machine_key on calidad_historico(machine_key);

-- Permite conservar inspecciones separadas cuando varias máquinas comparten serial.
-- Es seguro para bases ya creadas y no modifica los registros históricos existentes.
alter table calidad_historico add column if not exists machine_key text;

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
  fecha_correccion   date,
  costo              numeric  -- costo estimado de la no calidad para este defecto (opcional)
);
create index if not exists idx_gar_defectos_solicitud on garantias_defectos(solicitud_id);
create index if not exists idx_gar_defectos_pendientes on garantias_defectos(solicitud_id) where corregido = false;

-- Migración segura: si la tabla ya existía (proyecto ya desplegado), el
-- "create table if not exists" de arriba no agrega columnas nuevas.
-- Esta línea sí la agrega, sin afectar los datos existentes.
alter table garantias_solicitudes add column if not exists serial_maquina text;
alter table garantias_defectos     add column if not exists costo numeric;
alter table garantias_solicitudes  add column if not exists fecha_cierre timestamptz;

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
-- CATÁLOGO DE PRODUCTOS PARA CALIDAD
-- Relaciona código → producto → grupo y atributos detectados desde BOM/costeos.
-- Los atributos sirven para activar puntos de inspección específicos del producto.
-- ───────────────────────────────────────────────────────────────────────
create table if not exists calidad_productos (
  codigo       text primary key,
  nombre       text not null,
  grupo        text not null check (grupo in ('Musculación con placas','Musculación con discos','Bioparques','Circuitos','Parques infantiles','Servicios')),
  fuente       text,
  atributos    jsonb not null default '{}'::jsonb,
  activo       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

alter table calidad_productos add column if not exists nombre text;
alter table calidad_productos add column if not exists grupo text;
alter table calidad_productos add column if not exists fuente text;
alter table calidad_productos add column if not exists atributos jsonb not null default '{}'::jsonb;
alter table calidad_productos add column if not exists activo boolean not null default true;
alter table calidad_productos add column if not exists created_at timestamptz not null default now();
alter table calidad_productos add column if not exists updated_at timestamptz not null default now();

drop trigger if exists trg_calidad_productos_updated on calidad_productos;
create trigger trg_calidad_productos_updated
  before update on calidad_productos
  for each row execute function set_updated_at();

create index if not exists idx_cal_productos_grupo on calidad_productos(grupo);
create index if not exists idx_cal_productos_activo on calidad_productos(activo);

insert into calidad_productos (codigo,nombre,grupo,fuente,atributos,activo,created_at,updated_at) values
('ARE-1','AREA 90  BIO','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('BAC-1','BANCA ABDOMINAL CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('BAL-01','Balancin mixto movilidad reducida','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('BAN-1','BANCO PLANO P LIBRE BIO','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('BAN-2','BANCO MULTIFUNCION 2','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('BAR-1','BARRAS GIMNASIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('BAR-2','BARRAS PARALELAS','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('BAR-3','BARRA DOMINADAS CLASICA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('BAR-4','BARRA MONKEY','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('CIRC-1','CIRCUITO DE CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('CIRC-2','CIRCUITO DE CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('CIRC-3','CIRCUITO DE CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('CIRC-4','CIRCUITO DE CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('CIRC-5','CIRCUITO DE CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('CIRC-6','CIRCUITO DE CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('CIRC-7','CIRCUITO DE CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('CIRC-8','CIRCUITO DE CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('CIRC-9','CIRCUITO DE CALISTENIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('ESC-1','ESCALERA SUECA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('FON-1','FONDOS JAULA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('HIP-1','HIPEREXTENSOR HORIZONTAL BIO','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('JAU-1','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('JAU-10','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":false,"laser":false}'::jsonb,true,now(),now()),
('JAU-11','JAULA PARA CROSFIT','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('JAU-2','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('JAU-3','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('JAU-4','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('JAU-5','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('JAU-6','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('JAU-7','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('JAU-8','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('JAU-9','JAULA DE POTENCIA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('PIV-1','PIVOTE JAULA','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('RAC-1','RACK SENTADILLA BIO','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('VOL-01','Volante de mano mixto movilidad reducida','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('XB400','Banco Abdominal Inclinado','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB402','Banco Abdominal doble','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":false,"laser":false}'::jsonb,true,now(),now()),
('XB414','Barras Paralelas','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB416','Bicicleta','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB420','Dominadas y Fondos Doble','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB422','Eliptica','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB423','Escalador doble','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":false,"laser":false}'::jsonb,true,now(),now()),
('XB425','Esqui','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB426','Extensor BIO','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":false,"laser":false}'::jsonb,true,now(),now()),
('XB431','Pony','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB432','Prensa de pierna doble','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB434','Press de espalda doble','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB437','Press de pecho con discos','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB438','Press de pecho Doble','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB440','Press de pierna con discos','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB442','Sentadilla con discos','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB443','Timón','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":false,"laser":false}'::jsonb,true,now(),now()),
('XB444','Twister','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB445','Vai Ven','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB447','Volante de Mano','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB449','Halon de espalda con discos','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB451','Columpio mixto movilidad reducida','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('XB452','Carrusel Mixto movilidad reducida','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB455','CIRCUITO DE CALISTENIA #1','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB456','CIRCUITO DE CALISTENIA #2','Circuitos','Costeo Circuitos_Jaulas','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB460','Sube y baja mixto movilidad reducida','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XB462','Banco inclinado Bio','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('XB463','Banco Hombro bio','Bioparques','Costeo Bioparques','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('XM100','Abductor Aductor','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM103','Banco abdominal','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM104','Banco hombro peso libre','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('XM105','Banco Multifunción','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM106','Banco olímpico declinado','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM107','Banco olímpico inclinado','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM108','Banco olímpico plano','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM109','Banco plano peso libre','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('XM110','Banco Predicador con placas','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM111','Banco Predicador Libre','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM112','Constructor glúteo','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM113','Crossover clásica','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":false,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM114','Crossover Compacto, en V.','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM115','Dominadas y fondos.','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM116','Elevador de pelvis','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM119','Extensor','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM120','Flexo Extensor','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":false,"laser":false}'::jsonb,true,now(),now()),
('XM121','Flexor','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM122','Flexor de Pie','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM125','Hammer de Espalda','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM126','Hammer de Hombro','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM127','Hammer pecho declinado','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM128','Hammer pecho inclinado','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM129','Hammer pecho plano','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":false,"laser":false}'::jsonb,true,now(),now()),
('XM130','Hammer remo','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM131','Hammer tibia','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM132','Hiperextensor Horizontal','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('XM133','Hiperextensor Inclinado','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM138','Multifuerza 4 estaciones','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM139','Multifuerza 8 estaciones','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM140','Pantorrillero','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM143','Patada gluteo peso libre','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM145','Peck Deck Doble función','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM148','Polea Alta','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM151','Polea Baja 2.0','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM153','Portadiscos','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM156','Prensa 90','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM161','Rack Sentadilla','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM162','Remo en punta','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM165','Sentadilla Búlgara','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM166','Sentadilla combinada','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM169','Sentadilla Sissy','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":false}'::jsonb,true,now(),now()),
('XM170','Sentadilla Smith 2.0 (clasica)','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":true,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM172','Torre auxiliar','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM176','Sentadilla con pantorrillero','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM178','Hammer isolateral vuelos','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM181','Jaula de Potencia con poleas','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":true,"cushion":false,"bearing":true,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM184','prensa atlética 3.0 lineal','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM185','Sentadilla hack up 3.0','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM186','Dominadas y fondos asistido','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":true,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM187','Sentadilla Smith con poleas 3.0','Musculación con placas','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":true,"cable":true,"cushion":false,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM188','Fondos Triceps Peso libre','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM189','smith con polea sin placas','Musculación con discos','BOM MUSCULACION','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":false,"laser":false}'::jsonb,true,now(),now()),
('XM193','Hammer isolateral vuelos con placas','Musculación con placas','BOM MUSCULACION','{"plates":true,"cable":true,"cushion":true,"bearing":true,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM906','Rack para mancuernas 3 niveles','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM908','Rack para mancuernas 2 niveles','Musculación con discos','BASE COSTEOS MAQUINAS MUSC_BIO','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":false,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now()),
('XM911','Rack para barras olimpicas','Musculación con discos','BOM MUSCULACION','{"plates":false,"cable":false,"cushion":false,"bearing":false,"shaft":true,"pulley":false,"portapeso":false,"tube":true,"laser":true}'::jsonb,true,now(),now())
on conflict (codigo) do update set
  nombre=excluded.nombre, grupo=excluded.grupo, fuente=excluded.fuente, atributos=excluded.atributos, activo=true, updated_at=now();

alter table calidad_productos enable row level security;
drop policy if exists anon_all on calidad_productos;
create policy anon_all on calidad_productos for all using (true) with check (true);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='calidad_productos'
  ) then
    alter publication supabase_realtime add table calidad_productos;
  end if;
end $$;

-- ───────────────────────────────────────────────────────────────────────
-- fecha_cierre automática: se marca sola cuando el estado pasa a uno de
-- cierre (Aprobada/Rechazada/Resuelta) y se limpia si se reabre. Esto es
-- lo que usa el dashboard de Estadísticas para calcular tiempos de cierre
-- reales, sin depender de que alguien la diligencie a mano.
-- ───────────────────────────────────────────────────────────────────────
create or replace function set_fecha_cierre() returns trigger as $$
begin
  if new.estado in ('Aprobada','Rechazada','Resuelta') and old.estado not in ('Aprobada','Rechazada','Resuelta') then
    new.fecha_cierre = now();
  elsif new.estado not in ('Aprobada','Rechazada','Resuelta') and old.estado in ('Aprobada','Rechazada','Resuelta') then
    new.fecha_cierre = null;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_gar_fecha_cierre on garantias_solicitudes;
create trigger trg_gar_fecha_cierre
  before update on garantias_solicitudes
  for each row execute function set_fecha_cierre();

-- ───────────────────────────────────────────────────────────────────────
-- CONFIGURACIÓN COMPARTIDA (ej. límites del semáforo de calidad en el
-- dashboard de Estadísticas). Toda la empresa comparte la misma config.
-- ───────────────────────────────────────────────────────────────────────
create table if not exists app_settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now()
);

drop trigger if exists trg_app_settings_updated on app_settings;
create trigger trg_app_settings_updated
  before update on app_settings
  for each row execute function set_updated_at();

alter table app_settings enable row level security;
drop policy if exists anon_all on app_settings;
create policy anon_all on app_settings for all using (true) with check (true);

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
    insert into garantias_defectos (solicitud_id, proceso, item, criterio, resultado, severidad, causa, accion, corregido, costo)
    values (new_id, d->>'proceso', d->>'item', d->>'criterio', d->>'resultado', d->>'severidad', d->>'causa', d->>'accion',
            coalesce((d->>'corregido')::boolean, false), nullif(d->>'costo','')::numeric);
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
-- REALTIME — permite que todos los dispositivos vean cambios al instante.
-- Se agrega cada tabla SOLO SI todavía no está en la publicación, para que
-- este archivo se pueda volver a pegar y correr las veces que sea
-- necesario sin error, aunque ya lo hayas ejecutado antes.
-- ───────────────────────────────────────────────────────────────────────
do $$
declare
  t text;
begin
  foreach t in array array[
    'rec_registros','calidad_inspecciones','calidad_historico',
    'garantias_solicitudes','garantias_maquinas','garantias_defectos','app_settings'
  ]
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table %I', t);
    end if;
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════
-- Fin del esquema. Siguiente paso: Project Settings → API → copiar
-- "Project URL" y "anon public key" y pegarlos en la app (bloque CONFIG).
-- ═══════════════════════════════════════════════════════════════════════

-- Notificaciones de Calidad: ARM, PIN y ENS. Migracion aditiva e idempotente.
-- Ejecutar en el SQL Editor del mismo proyecto Supabase de Calidad.
create table if not exists public.calidad_etapas_produccion (
  machine_key text not null,
  etapa text not null check (etapa in ('armado','pintado','ensamble')),
  completada boolean,
  ciclo integer not null default 0,
  observed_at timestamptz,
  primary key (machine_key, etapa)
);
create table if not exists public.calidad_notificaciones (
  id uuid primary key,
  machine_key text not null,
  etapa text not null check (etapa in ('armado','pintado','ensamble')),
  ciclo integer not null check (ciclo > 0),
  maquina jsonb not null,
  detectada_at timestamptz not null,
  leida_at timestamptz,
  unique (machine_key, etapa, ciclo)
);
create index if not exists idx_cal_notificaciones_fecha on public.calidad_notificaciones(detectada_at desc, id);

alter table public.calidad_etapas_produccion enable row level security;
alter table public.calidad_notificaciones enable row level security;
-- Mismo acceso compartido de la app actual, sin permitir eliminar avisos.
drop policy if exists cal_etapas_select on public.calidad_etapas_produccion;
create policy cal_etapas_select on public.calidad_etapas_produccion for select to anon, authenticated using (true);
drop policy if exists cal_etapas_insert on public.calidad_etapas_produccion;
create policy cal_etapas_insert on public.calidad_etapas_produccion for insert to anon, authenticated with check (true);
drop policy if exists cal_etapas_update on public.calidad_etapas_produccion;
create policy cal_etapas_update on public.calidad_etapas_produccion for update to anon, authenticated using (true) with check (true);
drop policy if exists cal_not_select on public.calidad_notificaciones;
create policy cal_not_select on public.calidad_notificaciones for select to anon, authenticated using (true);
drop policy if exists cal_not_insert on public.calidad_notificaciones;
create policy cal_not_insert on public.calidad_notificaciones for insert to anon, authenticated with check (true);
drop policy if exists cal_not_update on public.calidad_notificaciones;
create policy cal_not_update on public.calidad_notificaciones for update to anon, authenticated using (true) with check (true);
grant select, insert, update on public.calidad_etapas_produccion to anon, authenticated;
grant select, insert, update(leida_at) on public.calidad_notificaciones to anon, authenticated;

create or replace function public.calidad_observar_produccion(observaciones jsonb)
returns table (input_token uuid, notification jsonb)
language plpgsql
security invoker
set search_path = public
as $$
declare
  o jsonb;
  previous public.calidad_etapas_produccion%rowtype;
  event_row public.calidad_notificaciones%rowtype;
  seen_at timestamptz;
  done boolean;
begin
  if jsonb_typeof(observaciones) is distinct from 'array' then
    raise exception 'Se requiere una lista de observaciones';
  end if;
  for o in select value from jsonb_array_elements(observaciones)
    order by value->>'machine_key',value->>'etapa',value->>'observed_at'
  loop
    input_token := (o->>'token')::uuid;
    notification := null;
    if coalesce(o->>'machine_key','') = ''
       or coalesce(o->>'etapa','') not in ('armado','pintado','ensamble')
       or jsonb_typeof(o->'completada') is distinct from 'boolean'
       or jsonb_typeof(o->'maquina') is distinct from 'object'
       or o->>'observed_at' is null then
      raise exception 'Observacion de produccion invalida';
    end if;
    seen_at := (o->>'observed_at')::timestamptz;
    done := (o->>'completada')::boolean;
    insert into public.calidad_etapas_produccion(machine_key,etapa)
    values (o->>'machine_key',o->>'etapa') on conflict do nothing;
    select * into previous from public.calidad_etapas_produccion
    where machine_key=o->>'machine_key' and etapa=o->>'etapa' for update;

    if previous.observed_at is null or seen_at > previous.observed_at then
      if done and previous.completada is distinct from true then
        previous.ciclo := previous.ciclo + 1;
        insert into public.calidad_notificaciones(id,machine_key,etapa,ciclo,maquina,detectada_at)
        values (input_token,o->>'machine_key',o->>'etapa',previous.ciclo,o->'maquina',seen_at);
      end if;
      update public.calidad_etapas_produccion
      set completada=done,ciclo=previous.ciclo,observed_at=seen_at
      where machine_key=o->>'machine_key' and etapa=o->>'etapa';
    end if;
    if done then
      select * into event_row from public.calidad_notificaciones
      where machine_key=o->>'machine_key' and etapa=o->>'etapa'
        and (id=input_token or detectada_at<=seen_at)
      order by (id=input_token) desc,detectada_at desc limit 1;
      if found then notification := to_jsonb(event_row); end if;
    end if;
    return next;
  end loop;
end;
$$;
revoke all on function public.calidad_observar_produccion(jsonb) from public;
grant execute on function public.calidad_observar_produccion(jsonb) to anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='calidad_notificaciones'
  ) then
    alter publication supabase_realtime add table public.calidad_notificaciones;
  end if;
end $$;

-- Calidad interna y externa. Migracion aditiva para la base existente.
alter table public.garantias_solicitudes
  add column if not exists tipo_reporte text not null default 'Garantía';
do $$
begin
  if not exists (select 1 from pg_constraint where conname='gar_tipo_reporte_check'
    and conrelid='public.garantias_solicitudes'::regclass) then
    alter table public.garantias_solicitudes add constraint gar_tipo_reporte_check
      check (tipo_reporte in ('Garantía','Inconformidad','Reclamo','Sugerencia'));
  end if;
end $$;

-- La solicitud, sus maquinas, defectos y clasificacion se guardan juntos.
-- Se conserva intacta la funcion original para clientes anteriores.
create or replace function public.crear_reporte_calidad(payload jsonb)
returns uuid language plpgsql security invoker set search_path=public
as $$
declare
  reporte_id uuid;
  tipo text := coalesce(nullif(payload->>'tipoReporte',''),'Garantía');
begin
  if tipo not in ('Garantía','Inconformidad','Reclamo','Sugerencia') then
    raise exception 'Tipo de reporte no valido';
  end if;
  reporte_id := public.crear_garantia(payload);
  update public.garantias_solicitudes set tipo_reporte=tipo where id=reporte_id;
  return reporte_id;
end;
$$;
revoke all on function public.crear_reporte_calidad(jsonb) from public;
grant execute on function public.crear_reporte_calidad(jsonb) to anon, authenticated;

-- No permite que un cliente desactualizado borre hallazgos ya guardados
-- ni reabra un evento corregido. Una nueva ocurrencia tiene un ID distinto.
create or replace function public.calidad_conservar_hallazgos()
returns trigger language plpgsql set search_path=public
as $$
declare merged jsonb;
begin
  select coalesce(jsonb_agg(e order by e->>'id'),'[]'::jsonb) into merged
  from (
    select distinct on (event->>'id') event as e
    from (
      select value as event,0 as version from jsonb_array_elements(
        case when jsonb_typeof(old.data->'internalFindings')='array' then old.data->'internalFindings' else '[]'::jsonb end)
      union all
      select value as event,1 as version from jsonb_array_elements(
        case when jsonb_typeof(new.data->'internalFindings')='array' then new.data->'internalFindings' else '[]'::jsonb end)
    ) events
    where coalesce(event->>'id','')<>''
    order by event->>'id',nullif(event->>'closedAt','') asc nulls last,version desc
  ) dedup;
  if jsonb_array_length(merged)>0 then
    new.data:=jsonb_set(new.data,'{internalFindings}',merged,true);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_calidad_conservar_hallazgos on public.calidad_inspecciones;
create trigger trg_calidad_conservar_hallazgos
  before update on public.calidad_inspecciones
  for each row execute function public.calidad_conservar_hallazgos();

-- Ejecutar despues de notificaciones_calidad.sql y calidad_interna_externa.sql.
-- Retirar avisos sin perder el ciclo que impide generarlos nuevamente.
alter table public.calidad_notificaciones add column if not exists eliminada_at timestamptz;
grant update(eliminada_at) on public.calidad_notificaciones to anon, authenticated;

create or replace function public.calidad_conservar_aviso_eliminado()
returns trigger language plpgsql set search_path=public
as $$
begin
  new.eliminada_at:=coalesce(old.eliminada_at,new.eliminada_at);
  return new;
end;
$$;
drop trigger if exists trg_calidad_aviso_eliminado on public.calidad_notificaciones;
create trigger trg_calidad_aviso_eliminado before update on public.calidad_notificaciones
  for each row execute function public.calidad_conservar_aviso_eliminado();

-- Conserva correcciones y anulaciones incluso si otro equipo envia una copia vieja.
-- No se modifica ningun resultado del checklist ni del historial.
create or replace function public.calidad_conservar_hallazgos()
returns trigger language plpgsql set search_path=public
as $$
declare merged jsonb;
begin
  with events as (
    select value as event,0 as version from jsonb_array_elements(
      case when jsonb_typeof(old.data->'internalFindings')='array' then old.data->'internalFindings' else '[]'::jsonb end)
    union all
    select value as event,1 as version from jsonb_array_elements(
      case when jsonb_typeof(new.data->'internalFindings')='array' then new.data->'internalFindings' else '[]'::jsonb end)
  ), latest as (
    select distinct on (event->>'id') event, event->>'id' as id
    from events where coalesce(event->>'id','')<>''
    order by event->>'id',version desc
  ), milestones as (
    select event->>'id' as id,min(nullif(event->>'closedAt','')) as closed_at,
      min(nullif(event->>'voidedAt','')) as voided_at,
      (jsonb_agg(event->'closure' order by version) filter (where jsonb_typeof(event->'closure')='object'))->0 as closure
    from events group by event->>'id'
  )
  select coalesce(jsonb_agg(latest.event||jsonb_build_object('closedAt',milestones.closed_at,'voidedAt',milestones.voided_at,'closure',milestones.closure)
    order by latest.id),'[]'::jsonb) into merged
  from latest join milestones using(id);
  if jsonb_array_length(merged)>0 then
    new.data:=jsonb_set(new.data,'{internalFindings}',merged,true);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_calidad_conservar_hallazgos on public.calidad_inspecciones;
create trigger trg_calidad_conservar_hallazgos before update on public.calidad_inspecciones
  for each row execute function public.calidad_conservar_hallazgos();

-- Elimina el contenido de una version y evita que un cliente antiguo lo restaure.
create or replace function public.calidad_eliminar_version_matriz(p_key text)
returns void language plpgsql security invoker set search_path=public
as $$
declare marker text;
begin
  if p_key is null or p_key !~ '^quality_matrix:v1:version:[0-9a-f-]{36}$' then
    raise exception 'Clave de version no valida';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_key,0));
  marker := replace(p_key,'quality_matrix:v1:version:','quality_matrix:v1:deleted-version:');
  insert into public.app_settings(key,value) values(marker,jsonb_build_object('deletedAt',now())) on conflict(key) do nothing;
  delete from public.app_settings where key=p_key;
end;
$$;
revoke all on function public.calidad_eliminar_version_matriz(text) from public;
grant execute on function public.calidad_eliminar_version_matriz(text) to anon,authenticated;

create or replace function public.calidad_proteger_version_eliminada()
returns trigger language plpgsql set search_path=public
as $$
begin
  if strpos(new.key,'quality_matrix:v1:version:')=1 then
    perform pg_advisory_xact_lock(hashtextextended(new.key,0));
    if exists(select 1 from public.app_settings where key=replace(new.key,'quality_matrix:v1:version:','quality_matrix:v1:deleted-version:')) then
      raise exception 'Esta version fue eliminada';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_calidad_version_eliminada on public.app_settings;
create trigger trg_calidad_version_eliminada before insert or update on public.app_settings
for each row execute function public.calidad_proteger_version_eliminada();

-- Acceso por seccion. Crear primero la cuenta admin en Authentication > Users
-- con correo confirmado. Este bloque no crea usuarios ni cambia contrasenas.
create table if not exists public.calidad_usuarios (
  user_id uuid primary key references auth.users(id) on delete cascade,
  rol text not null check (rol in ('admin','armado','resoldado','pulido','pintado','ensamble','empacado')),
  activo boolean not null default true,
  updated_at timestamptz not null default now()
);
create table if not exists public.calidad_accesos_auditoria (
  id uuid primary key default gen_random_uuid(), actor uuid, usuario uuid,
  anterior jsonb, nuevo jsonb, fecha timestamptz not null default now()
);
create or replace function public.calidad_rol() returns text
language sql stable security definer set search_path = '' as $$
  select rol from public.calidad_usuarios where user_id=auth.uid() and activo
    and (rol<>'admin' or coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'is_anonymous','false')<>'true');
$$;
create or replace function public.calidad_etapa_usuario() returns text
language sql stable security definer set search_path = '' as $$
  select case public.calidad_rol() when 'armado' then 'material' when 'resoldado' then 'armado'
    when 'pulido' then 'resoldado' when 'pintado' then 'pulido' when 'ensamble' then 'pintado'
    when 'empacado' then 'ensamble' end;
$$;
do $$
declare u uuid;
begin
  if not exists(select 1 from public.calidad_usuarios where rol='admin' and activo) then
    select id into u from auth.users where lower(email)='santiagocardona.15.98@gmail.com' and email_confirmed_at is not null;
    if u is null then raise exception 'Cree primero el usuario admin santiagocardona.15.98@gmail.com con correo confirmado en Authentication > Users y ejecute nuevamente TODO schema.sql. No se aplicaron cambios.'; end if;
    insert into public.calidad_usuarios(user_id,rol) values(u,'admin') on conflict(user_id) do update set rol='admin',activo=true;
  end if;
end $$;

-- Sustituye las politicas anonimas anteriores solo en las tablas de esta app.
-- Cuentas de seccion: crearlas primero mediante Authentication > Users con
-- correo confirmado y la clave elegida por el administrador. No se almacenan
-- contrasenas en este archivo ni se modifica directamente auth.users.
-- Usuario visible -> identificador tecnico de Supabase:
-- admin -> santiagocardona.15.98@gmail.com (cuenta existente)
-- armado -> armado@usuarios.xtensor.invalid
-- resoldado -> resoldado@usuarios.xtensor.invalid
-- pulido -> pulido@usuarios.xtensor.invalid
-- pintado -> pintado@usuarios.xtensor.invalid
-- ensamble -> ensamble@usuarios.xtensor.invalid
-- empacado -> empacado@usuarios.xtensor.invalid
-- Los correos .invalid son identificadores internos, no buzones de correo.
-- Despues de crearlas, el admin asigna y activa cada seccion desde Ajustes >
-- Usuarios. No se conceden permisos automaticamente por coincidir el correo.

do $$
declare t text; p record;
begin
  foreach t in array array['rec_registros','calidad_inspecciones','calidad_historico','calidad_productos',
    'garantias_solicitudes','garantias_maquinas','garantias_defectos','app_settings',
    'calidad_etapas_produccion','calidad_notificaciones','calidad_usuarios','calidad_accesos_auditoria'] loop
    execute format('alter table public.%I enable row level security',t);
    for p in select policyname from pg_policies where schemaname='public' and tablename=t loop
      execute format('drop policy %I on public.%I',p.policyname,t);
    end loop;
    execute format('revoke all on public.%I from anon',t);
    execute format('grant select,insert,update,delete on public.%I to authenticated',t);
    execute format('create policy acceso_admin on public.%I for all to authenticated using ((select public.calidad_rol())=''admin'') with check ((select public.calidad_rol())=''admin'')',t);
  end loop;
end $$;
-- Los roles solo se cambian mediante la funcion auditada.
revoke insert,update,delete on public.calidad_usuarios from authenticated;
revoke insert,update,delete on public.calidad_accesos_auditoria from authenticated;
create policy perfil_propio on public.calidad_usuarios for select to authenticated using(user_id=auth.uid());
create policy catalogo_operario on public.calidad_productos for select to authenticated using(public.calidad_rol() is not null);
create policy matriz_operario on public.app_settings for select to authenticated using(
  public.calidad_etapa_usuario() is not null and
  (key like 'quality_matrix:v1:item:%' or key like 'quality_matrix:v1:assign:%' or key like 'quality_matrix:v1:order:%')
);
create or replace function public.calidad_listar_usuarios() returns table(user_id uuid,email text,rol text,activo boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if public.calidad_rol() is distinct from 'admin' then raise exception 'Acceso restringido'; end if;
  return query select u.id,u.email::text,p.rol,coalesce(p.activo,false) from auth.users u
    left join public.calidad_usuarios p on p.user_id=u.id order by u.email;
end $$;
create or replace function public.calidad_asignar_usuario(p_user uuid,p_rol text,p_activo boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare previo jsonb;
begin
  perform pg_advisory_xact_lock(730214);
  if public.calidad_rol() is distinct from 'admin' then raise exception 'Acceso restringido'; end if;
  if p_user=auth.uid() then raise exception 'No puede modificar su propio acceso'; end if;
  if p_rol is null or p_rol not in ('admin','armado','resoldado','pulido','pintado','ensamble','empacado') or p_activo is null then raise exception 'Rol no valido'; end if;
  select to_jsonb(p) into previo from public.calidad_usuarios p where user_id=p_user;
  insert into public.calidad_usuarios(user_id,rol,activo) values(p_user,p_rol,p_activo)
    on conflict(user_id) do update set rol=excluded.rol,activo=excluded.activo,updated_at=now();
  insert into public.calidad_accesos_auditoria(actor,usuario,anterior,nuevo)
    values(auth.uid(),p_user,previo,jsonb_build_object('rol',p_rol,'activo',p_activo));
end $$;

-- Proyeccion privada: nunca entrega al operario respuestas de otras etapas.
create or replace function public.calidad_datos_etapa(d jsonb,s text) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('stageData',jsonb_build_object(s,coalesce(d->'stageData'->s,'{}'::jsonb)),
    'inspectors',case when d->'inspectors' ? s then jsonb_build_object(s,d->'inspectors'->s) else '{}'::jsonb end,
    'responsables',case when d->'responsables' ? s then jsonb_build_object(s,d->'responsables'->s) else '{}'::jsonb end,
    'stageObs',jsonb_build_object(s,coalesce(d->'stageObs'->s,'""'::jsonb)),
    'resultDates',jsonb_build_object(s,coalesce(d->'resultDates'->s,'{}'::jsonb)),
    'stageRevision',coalesce(d->'stageRevisions'->s,'0'::jsonb),'currentStageIdx',0,
    'internalFindings',coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(d->'internalFindings','[]'::jsonb)) e where e->>'stage'=s),'[]'::jsonb));
$$;
create or replace function public.calidad_leer_mi_etapa() returns table(serial text,data jsonb,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare s text:=public.calidad_etapa_usuario();
begin
  if s is null then raise exception 'Sin etapa autorizada'; end if;
  return query select i.serial,public.calidad_datos_etapa(i.data,s),i.updated_at from public.calidad_inspecciones i;
end $$;
create or replace function public.calidad_guardar_mi_etapa(p_serial text,p_data jsonb,p_revision bigint)
returns table(serial text,data jsonb,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare s text:=public.calidad_etapa_usuario(); d jsonb; campo text; respuestas jsonb; eventos jsonb;
  it record; ev jsonb; candidato jsonb; correo text; inspector text; oldval text;
begin
  if s is null then raise exception 'Sin etapa autorizada'; end if;
  if p_serial is null or length(p_serial)>2000 or p_serial='' or jsonb_typeof(p_data)<>'object' then raise exception 'Inspeccion no valida'; end if;
  respuestas:=p_data->'stageData'->s;
  if jsonb_typeof(respuestas) is distinct from 'object' then raise exception 'Respuestas no validas'; end if;
  if exists(select 1 from jsonb_object_keys(p_data->'stageData') k where k<>s) then raise exception 'No puede modificar otra etapa'; end if;
  if exists(select 1 from jsonb_each_text(respuestas) x where x.value is null or x.value not in ('','ok','fail')) then raise exception 'Resultado no valido'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_serial,730215));
  select i.data into d from public.calidad_inspecciones i where i.serial=p_serial for update;
  d:=coalesce(d,'{}'::jsonb);
  if p_revision is distinct from coalesce((d->'stageRevisions'->>s)::bigint,0) then raise exception 'Esta etapa cambio en otro equipo. Revise los cambios antes de reintentar.'; end if;
  select u.email into correo from auth.users u where u.id=auth.uid();
  if p_data->'inspectors' ? s and jsonb_typeof(p_data->'inspectors'->s) is distinct from 'string' then raise exception 'Nombre de inspector no valido'; end if;
  inspector:=coalesce(nullif(btrim(p_data->'inspectors'->>s),''),correo);
  if length(inspector)>120 then raise exception 'Nombre de inspector demasiado largo'; end if;
  eventos:=coalesce(d->'internalFindings','[]'::jsonb);
  for it in select * from jsonb_each_text(respuestas) loop
    oldval:=d->'stageData'->s->>it.key;
    if it.value='fail' and oldval is distinct from 'fail' and not exists(select 1 from jsonb_array_elements(eventos) e where e->>'stage'=s and e->>'itemId'=it.key and nullif(e->>'closedAt','') is null) then
      select e into candidato from jsonb_array_elements(coalesce(p_data->'internalFindings','[]'::jsonb)) e where e->>'stage'=s and e->>'itemId'=it.key order by e->>'detectedAt' desc limit 1;
      ev:=jsonb_build_object('id','finding:'||gen_random_uuid()::text,'machineKey',p_serial,
        'machine',coalesce(d->'machineSnapshot',p_data->'machineSnapshot','{}'::jsonb),'stage',s,'area',initcap(s),
        'itemId',it.key,'item',coalesce(candidato->>'item',it.key),'criterio',coalesce(candidato->>'criterio',''),
        'detectedAt',now(),'closedAt',null,'inspector',inspector,'actor',auth.uid(),'actorEmail',correo);
      eventos:=eventos||jsonb_build_array(ev);
    elsif it.value='ok' and oldval='fail' then
      select coalesce(jsonb_agg(case when e->>'stage'=s and e->>'itemId'=it.key and nullif(e->>'closedAt','') is null
        then e||jsonb_build_object('closedAt',now(),'closure',jsonb_build_object('at',now(),'by',inspector,'actor',auth.uid(),'actorEmail',correo,'note','Corregido durante la inspeccion')) else e end),'[]'::jsonb)
        into eventos from jsonb_array_elements(eventos) e;
    end if;
  end loop;
  foreach campo in array array['stageData','responsables','stageObs','resultDates'] loop
    d:=jsonb_set(d,array[campo],coalesce(d->campo,'{}'::jsonb)||jsonb_build_object(s,coalesce(p_data->campo->s,case when campo in ('stageData','resultDates') then '{}'::jsonb else '""'::jsonb end)),true);
  end loop;
  d:=jsonb_set(d,'{inspectors}',coalesce(d->'inspectors','{}'::jsonb)||jsonb_build_object(s,inspector),true);
  d:=jsonb_set(d,'{stageEditors}',coalesce(d->'stageEditors','{}'::jsonb)||jsonb_build_object(s,jsonb_build_object('userId',auth.uid(),'email',correo,'at',now())),true);
  d:=jsonb_set(d,'{stageRevisions}',coalesce(d->'stageRevisions','{}'::jsonb)||jsonb_build_object(s,p_revision+1),true);
  d:=jsonb_set(d,'{internalFindings}',eventos,true);
  if not(d ? 'machineSnapshot') then d:=d||jsonb_build_object('machineSnapshot',coalesce(p_data->'machineSnapshot','{}'::jsonb)); end if;
  insert into public.calidad_inspecciones as dest(serial,data,updated_at) values(p_serial,d,now())
    on conflict on constraint calidad_inspecciones_pkey do update set data=excluded.data,updated_at=excluded.updated_at;
  return query select i.serial,public.calidad_datos_etapa(i.data,s),i.updated_at from public.calidad_inspecciones i where i.serial=p_serial;
end $$;
-- Nada de estas funciones queda accesible con la clave publica sin sesion.
revoke all on function public.calidad_rol(),public.calidad_etapa_usuario(),public.calidad_listar_usuarios(),
  public.calidad_asignar_usuario(uuid,text,boolean),public.calidad_leer_mi_etapa(),public.calidad_guardar_mi_etapa(text,jsonb,bigint),
  public.calidad_datos_etapa(jsonb,text) from public,anon;
grant execute on function public.calidad_rol(),public.calidad_etapa_usuario(),public.calidad_listar_usuarios(),
  public.calidad_asignar_usuario(uuid,text,boolean),public.calidad_leer_mi_etapa(),public.calidad_guardar_mi_etapa(text,jsonb,bigint) to authenticated;
grant usage,select on sequence public.garantias_solicitudes_numero_seq to authenticated;
-- Evita que una copia antigua del admin reemplace avances recientes de un operario.
create or replace function public.calidad_validar_revision() returns trigger
language plpgsql set search_path = '' as $$
declare s text;
begin
  if public.calidad_rol()='admin' then
    foreach s in array array['material','armado','resoldado','pulido','pintado','ensamble','empacado'] loop
      if coalesce(new.data->'stageRevisions'->s,'0'::jsonb)<>coalesce(old.data->'stageRevisions'->s,'0'::jsonb) then
        raise exception 'Esta etapa cambio en otro equipo. Revise los cambios antes de reintentar.';
      end if;
      if (new.data->'stageData'->s) is distinct from (old.data->'stageData'->s)
         or (new.data->'stageObs'->s) is distinct from (old.data->'stageObs'->s)
         or (new.data->'responsables'->s) is distinct from (old.data->'responsables'->s) then
        if coalesce(new.data->'stageRevisions'->s,'0'::jsonb)<>coalesce(old.data->'stageRevisions'->s,'0'::jsonb) then
          raise exception 'Esta etapa cambio en otro equipo. Revise los cambios antes de reintentar.';
        end if;
        new.data:=jsonb_set(new.data,'{stageRevisions}',coalesce(new.data->'stageRevisions','{}'::jsonb)||jsonb_build_object(s,coalesce((old.data->'stageRevisions'->>s)::bigint,0)+1),true);
      end if;
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists trg_calidad_revision on public.calidad_inspecciones;
create trigger trg_calidad_revision before update on public.calidad_inspecciones for each row execute function public.calidad_validar_revision();
-- Tiempos observados: colector independiente, sin escribir en Produccion.
create schema if not exists extensions;
create extension if not exists http with schema extensions;
create table if not exists public.produccion_tiempos_config (
  id boolean primary key default true check(id),
  clave text not null,
  cookie text,
  ultimo_intento timestamptz,
  ultima_lectura timestamptz,
  detalle text
);
insert into public.produccion_tiempos_config(id,clave) values(true,'planta2026') on conflict do nothing;
alter table public.produccion_tiempos_config enable row level security;
revoke all on public.produccion_tiempos_config from public,anon,authenticated;

create table if not exists public.produccion_fabricaciones (
  id uuid primary key,
  codigo text,
  producto text not null,
  serial text,
  cliente text,
  primera_observacion timestamptz not null,
  ultima_observacion timestamptz not null,
  etapa_actual integer not null check(etapa_actual between 0 and 8),
  estado text not null default 'observando'
);
-- Calendario laboral America/Bogota. No descuenta festivos no especificados.
create or replace function public.produccion_siguiente_franja(t timestamptz) returns timestamptz
language plpgsql immutable strict set search_path='' as $$
declare dia date; dow integer; apertura timestamptz; cierre timestamptz; tramo integer;
begin
  if not isfinite(t) then return null; end if;
  dia:=(t at time zone 'America/Bogota')::date;
  loop
    dow:=extract(isodow from dia)::integer;
    if dow<=5 then
      for tramo in 0..1 loop
        apertura:=(dia+case when tramo=0 then time '07:00' else time '13:30' end) at time zone 'America/Bogota';
        cierre:=(dia+case when tramo=0 then time '13:00' when dow=5 then time '14:45' else time '16:30' end) at time zone 'America/Bogota';
        if t<cierre then return greatest(t,apertura); end if;
      end loop;
    end if;
    dia:=dia+1;
  end loop;
end $$;
create or replace function public.produccion_minutos_laborales(desde timestamptz,hasta timestamptz) returns double precision
language plpgsql immutable strict set search_path='' as $$
declare dia date; ultimo date; dow integer; tramo integer; a timestamptz; b timestamptz; total double precision:=0;
begin
  if not isfinite(desde) or not isfinite(hasta) or hasta<desde then return null; end if;
  dia:=(desde at time zone 'America/Bogota')::date;ultimo:=(hasta at time zone 'America/Bogota')::date;
  while dia<=ultimo loop
    dow:=extract(isodow from dia)::integer;
    if dow<=5 then
      for tramo in 0..1 loop
        a:=(dia+case when tramo=0 then time '07:00' else time '13:30' end) at time zone 'America/Bogota';
        b:=(dia+case when tramo=0 then time '13:00' when dow=5 then time '14:45' else time '16:30' end) at time zone 'America/Bogota';
        total:=total+greatest(0,extract(epoch from least(hasta,b)-greatest(desde,a))/60.0);
      end loop;
    end if;
    dia:=dia+1;
  end loop;
  return total;
end $$;
create table if not exists public.produccion_tiempos (
  id bigint generated always as identity primary key,
  fabricacion_id uuid not null references public.produccion_fabricaciones(id),
  etapa integer not null check(etapa between 0 and 7),
  inicio timestamptz,
  finalizacion timestamptz,
  duracion_minutos double precision generated always as (extract(epoch from (finalizacion-inicio))/60.0) stored,
  primera_observacion timestamptz not null,
  responsable text,
  interrumpido boolean not null default false,
  observaciones text not null default '',
  check(finalizacion is null or inicio is null or finalizacion>=inicio)
);
create unique index if not exists produccion_tiempos_abierto on public.produccion_tiempos(fabricacion_id) where finalizacion is null;
create index if not exists produccion_tiempos_historial on public.produccion_tiempos(fabricacion_id,primera_observacion);
alter table public.produccion_tiempos add column if not exists inicio_laboral timestamptz generated always as (public.produccion_siguiente_franja(inicio)) stored;
alter table public.produccion_tiempos add column if not exists finalizacion_laboral timestamptz generated always as (public.produccion_siguiente_franja(finalizacion)) stored;
alter table public.produccion_tiempos add column if not exists duracion_laboral_minutos double precision generated always as (public.produccion_minutos_laborales(inicio,finalizacion)) stored;

-- Festivos nacionales y ajustes operativos. Las observaciones originales no se modifican.
create table if not exists public.produccion_festivos_colombia (
  fecha date primary key,
  nombre text not null,
  fuente text not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.produccion_calendario_ajustes (
  id uuid primary key default gen_random_uuid(),
  orden bigserial unique,
  tipo text not null check(tipo in ('no_laboral','tiempo_extra')),
  inicio timestamptz not null,
  fin timestamptz not null,
  etapa integer check(etapa between 0 and 7),
  descripcion text not null,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid(),
  check(fin>inicio)
);
alter table public.produccion_calendario_ajustes add column if not exists orden bigserial;
create index if not exists produccion_calendario_ajustes_rango on public.produccion_calendario_ajustes(inicio,fin);

create or replace function public.produccion_pascua(y integer) returns date
language plpgsql immutable strict set search_path='' as $$
declare a integer;b integer;c integer;d integer;e integer;f integer;g integer;h integer;i integer;k integer;l integer;m integer;mes integer;dia integer;
begin
  if y<1583 or y>4099 then raise exception 'Ano fuera de rango'; end if;
  a:=y%19;b:=y/100;c:=y%100;d:=b/4;e:=b%4;f:=(b+8)/25;g:=(b-f+1)/3;
  h:=(19*a+b-d-g+15)%30;i:=c/4;k:=c%4;l:=(32+2*e+2*i-h-k)%7;m:=(a+11*h+22*l)/451;
  mes:=(h+l-7*m+114)/31;dia:=((h+l-7*m+114)%31)+1;
  return make_date(y,mes,dia);
end $$;
create or replace function public.produccion_lunes_festivo(d date) returns date
language sql immutable strict set search_path='' as $$select d+((8-extract(isodow from d)::integer)%7)$$;
create or replace function public.produccion_festivos_del_ano(y integer) returns table(fecha date,nombre text)
language sql immutable strict set search_path='' as $$
with p as (select public.produccion_pascua(y) d), f(fecha,nombre) as (values
  (make_date(y,1,1),'Año Nuevo'),
  (public.produccion_lunes_festivo(make_date(y,1,6)),'Día de los Reyes Magos'),
  (public.produccion_lunes_festivo(make_date(y,3,19)),'Día de San José'),
  ((select d-3 from p),'Jueves Santo'),((select d-2 from p),'Viernes Santo'),
  (make_date(y,5,1),'Día del Trabajo'),
  (public.produccion_lunes_festivo((select d+39 from p)),'Ascensión del Señor'),
  (public.produccion_lunes_festivo((select d+60 from p)),'Corpus Christi'),
  (public.produccion_lunes_festivo((select d+68 from p)),'Sagrado Corazón de Jesús'),
  (public.produccion_lunes_festivo(make_date(y,6,29)),'San Pedro y San Pablo'),
  (make_date(y,7,20),'Día de la Independencia'),(make_date(y,8,7),'Batalla de Boyacá'),
  (public.produccion_lunes_festivo(make_date(y,8,15)),'Asunción de la Virgen'),
  (public.produccion_lunes_festivo(make_date(y,10,12)),'Día de la Diversidad Étnica y Cultural'),
  (public.produccion_lunes_festivo(make_date(y,11,1)),'Todos los Santos'),
  (public.produccion_lunes_festivo(make_date(y,11,11)),'Independencia de Cartagena'),
  (make_date(y,12,8),'Inmaculada Concepción'),(make_date(y,12,25),'Navidad'))
select * from f union all
select public.produccion_lunes_festivo(make_date(y,7,9)),'Nuestra Señora del Rosario de Chiquinquirá' where y>=2026
$$;
insert into public.produccion_festivos_colombia(fecha,nombre,fuente)
select f.fecha,string_agg(distinct f.nombre,' / ' order by f.nombre),
  case when bool_or(f.nombre='Nuestra Señora del Rosario de Chiquinquirá')
    then 'Ley 51 de 1983 / Ley 2578 de 2026' else 'Ley 51 de 1983' end
from generate_series(2020,2050) y cross join lateral public.produccion_festivos_del_ano(y) f
group by f.fecha
on conflict(fecha) do update set nombre=excluded.nombre,fuente=excluded.fuente;

alter table public.produccion_festivos_colombia enable row level security;
alter table public.produccion_calendario_ajustes enable row level security;
revoke all on public.produccion_festivos_colombia,public.produccion_calendario_ajustes from public,anon,authenticated;
grant select on public.produccion_festivos_colombia to authenticated;
grant select,insert,update,delete on public.produccion_calendario_ajustes to authenticated;
drop policy if exists calendario_admin on public.produccion_festivos_colombia;
create policy calendario_admin on public.produccion_festivos_colombia for select to authenticated using(public.calidad_rol()='admin');
drop policy if exists calendario_admin on public.produccion_calendario_ajustes;
create policy calendario_admin on public.produccion_calendario_ajustes for all to authenticated
  using(public.calidad_rol()='admin') with check(public.calidad_rol()='admin' and created_by=auth.uid());

create or replace function public.produccion_es_laboral(t timestamptz,p_etapa integer default null) returns boolean
language plpgsql stable set search_path='' as $$
declare local_ts timestamp:=t at time zone 'America/Bogota';tipo_ajuste text;dow integer;hora time;
begin
  select a.tipo into tipo_ajuste from public.produccion_calendario_ajustes a
    where a.inicio<=t and a.fin>t and (a.etapa is null or a.etapa=p_etapa)
    order by a.created_at desc,a.orden desc,a.id desc limit 1;
  if found then return tipo_ajuste='tiempo_extra'; end if;
  dow:=extract(isodow from local_ts)::integer;hora:=local_ts::time;
  if dow>5 or exists(select 1 from public.produccion_festivos_colombia f where f.fecha=local_ts::date) then return false; end if;
  return (hora>=time '07:00' and hora<time '13:00') or
    (hora>=time '13:30' and hora<case when dow=5 then time '14:45' else time '16:30' end);
end $$;
create or replace function public.produccion_minutos_calendario(desde timestamptz,hasta timestamptz,p_etapa integer default null) returns double precision
language sql stable set search_path='' as $$
with recursive dias as (
  select (desde at time zone 'America/Bogota')::date d
  union all select d+1 from dias where d<(hasta at time zone 'America/Bogota')::date
), puntos as (
  select desde p union select hasta
  union select (d+time '07:00') at time zone 'America/Bogota' from dias
  union select (d+time '13:00') at time zone 'America/Bogota' from dias
  union select (d+time '13:30') at time zone 'America/Bogota' from dias
  union select (d+case when extract(isodow from d)=5 then time '14:45' else time '16:30' end) at time zone 'America/Bogota' from dias
  union select greatest(desde,a.inicio) from public.produccion_calendario_ajustes a where a.fin>desde and a.inicio<hasta and (a.etapa is null or a.etapa=p_etapa)
  union select least(hasta,a.fin) from public.produccion_calendario_ajustes a where a.fin>desde and a.inicio<hasta and (a.etapa is null or a.etapa=p_etapa)
), segmentos as (select p,lead(p) over(order by p) q from puntos where p between desde and hasta)
select case when desde is null or hasta is null or hasta<desde then null else coalesce(sum(extract(epoch from(q-p))/60.0)
  filter(where q>p and public.produccion_es_laboral(p+(q-p)/2,p_etapa)),0) end from segmentos
$$;
alter table public.produccion_fabricaciones enable row level security;
alter table public.produccion_tiempos enable row level security;
revoke all on public.produccion_fabricaciones,public.produccion_tiempos from public,anon,authenticated;
grant select on public.produccion_fabricaciones,public.produccion_tiempos to authenticated;
drop policy if exists tiempos_admin on public.produccion_fabricaciones;
create policy tiempos_admin on public.produccion_fabricaciones for select to authenticated using(public.calidad_rol()='admin');
drop policy if exists tiempos_admin on public.produccion_tiempos;
create policy tiempos_admin on public.produccion_tiempos for select to authenticated using(public.calidad_rol()='admin');

-- Lee exclusivamente componentes de datos de Next; no ejecuta JavaScript del origen.
create or replace function public.produccion_texto_nodo(p jsonb,clase text) returns text
language sql immutable set search_path='' as $$
  select n->>'children' from jsonb_path_query(p,'strict $.** ? (@.type() == "object")') n
  where clase=any(string_to_array(n->>'className',' ')) and jsonb_typeof(n->'children') in ('string','number') limit 1
$$;
create or replace function public.produccion_parsear_tablero(html text) returns jsonb
language plpgsql set search_path='' as $$
declare m text[]; stream text:=''; linea text; p jsonb; n jsonb; filas jsonb:='{}'; ident text; etapa text; idx integer;
begin
  for m in select regexp_matches(html,'self\.__next_f\.push\((.*?)\)</script>','g') loop
    begin p:=m[1]::jsonb; if p->>0='1' then stream:=stream||(p->>1); end if;
    exception when others then null; end;
  end loop;
  foreach linea in array string_to_array(stream,E'\n') loop
    if linea !~ '^[0-9a-f]+:\[' then continue; end if;
    begin p:=substring(linea from position(':' in linea)+1)::jsonb;
    exception when others then continue; end;
    for n in select value from jsonb_path_query(p,'strict $.** ? (@.type() == "array")') value loop
      if coalesce(n->>0,'')<>'$' or not coalesce('xt-board-row'=any(string_to_array(n->3->>'className',' ')),false) then continue; end if;
      ident:=n->>2;
      if ident !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then raise exception 'Fabricacion sin identificador estable'; end if;
      etapa:=public.produccion_texto_nodo(n->3,'xt-board-next');
      idx:=array_position(array['Material','Armar','Resoldar','Pulir','Pintar','Ensamblar','Empacar','Despacho','Terminada'],etapa)-1;
      if idx is null then raise exception 'Etapa no reconocida'; end if;
      filas:=filas||jsonb_build_object(ident,jsonb_build_object('id',ident,'etapa',idx,
        'serial',public.produccion_texto_nodo(n->3,'xt-board-serial'),
        'producto',public.produccion_texto_nodo(n->3,'xt-board-machine'),
        'cliente',public.produccion_texto_nodo(n->3,'xt-board-client')));
    end loop;
  end loop;
  if filas='{}'::jsonb then raise exception 'Tablero sin filas verificables'; end if;
  return (select jsonb_agg(value) from jsonb_each(filas));
end $$;

-- Serializa todos los equipos. La hora de deteccion pertenece al servidor.
create or replace function public.produccion_aplicar_observacion(filas jsonb, momento timestamptz) returns void
language plpgsql set search_path='' as $$
declare m jsonb; f public.produccion_fabricaciones%rowtype; ident uuid; idx integer; salto boolean; consecutiva boolean; alta_observada boolean;
begin
  for m in select value from jsonb_array_elements(filas) loop
    ident:=(m->>'id')::uuid; idx:=(m->>'etapa')::integer;
    select * into f from public.produccion_fabricaciones where id=ident for update;
    if not found then
      -- Solo altas nuevas en Material, despues de una lectura reciente y completa.
      -- La primera carga y los arranques tras interrupciones conservan inicio desconocido.
      select idx=0 and ultima_lectura is not null and detalle is null
        and ultima_lectura<momento and public.produccion_minutos_calendario(ultima_lectura,momento,idx)<=3
        into alta_observada from public.produccion_tiempos_config where id=true;
      insert into public.produccion_fabricaciones(id,producto,serial,cliente,primera_observacion,ultima_observacion,etapa_actual,estado)
      values(ident,m->>'producto',m->>'serial',m->>'cliente',momento,momento,idx,case when idx=8 then 'terminada_sin_despacho' else 'observando' end);
      if idx<8 then insert into public.produccion_tiempos(fabricacion_id,etapa,inicio,primera_observacion,observaciones)
        values(ident,idx,case when alta_observada then momento end,momento,
          case when alta_observada then 'Alta observada en Material; inicio por sincronizacion, no cronometraje de trabajo.' else 'Inicio desconocido: primera observacion.' end); end if;
      continue;
    end if;
    if momento<=f.ultima_observacion then continue; end if;
    salto:=public.produccion_minutos_calendario(f.ultima_observacion,momento,f.etapa_actual)>3;
    if salto then update public.produccion_tiempos set interrumpido=true where fabricacion_id=ident and finalizacion is null; end if;
    if idx<>f.etapa_actual then
      -- La cartelera pasa de Empacar a Terminada sin exponer Despacho.
      -- Cierra fabricacion; no crea ni completa un intervalo de Despacho.
      consecutiva:=idx=f.etapa_actual+1 or (f.etapa_actual=6 and idx=8);
      update public.produccion_tiempos set finalizacion=momento,
        interrumpido=interrumpido or salto or not consecutiva,
        observaciones=observaciones||case when not consecutiva then ' Transicion no consecutiva; no se reconstruyen etapas omitidas.' when f.etapa_actual=6 and idx=8 then ' Fin de fabricacion observado; Despacho no informado.' else '' end
        where fabricacion_id=ident and finalizacion is null;
      if idx<8 then
        insert into public.produccion_tiempos(fabricacion_id,etapa,inicio,primera_observacion,interrumpido,observaciones)
        values(ident,idx,case when not salto and idx=f.etapa_actual+1 then momento end,momento,salto,
          case when salto or idx<>f.etapa_actual+1 then 'Inicio desconocido: interrupcion o transicion no consecutiva.' else '' end);
      end if;
    end if;
    update public.produccion_fabricaciones set ultima_observacion=momento,etapa_actual=idx,
      producto=m->>'producto',serial=m->>'serial',cliente=m->>'cliente',
      estado=case when idx=8 then case when f.etapa_actual=7 or f.estado='despachada' then 'despachada' else 'terminada_sin_despacho' end else 'observando' end
      where id=ident;
  end loop;
  -- Desaparecer de la cartelera no prueba despacho ni finalizacion.
  update public.produccion_tiempos t set interrumpido=true
    where finalizacion is null and not exists(select 1 from jsonb_array_elements(filas) item where (item->>'id')::uuid=t.fabricacion_id);
end $$;

create or replace function public.produccion_observar_tablero() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.produccion_tiempos_config%rowtype; r extensions.http_response;
  accion text; cookies text; filas jsonb; momento timestamptz; fallo text; limite text; cuerpo text;
begin
  if public.calidad_rol() is null then raise exception 'Acceso no autorizado'; end if;
  if not pg_try_advisory_xact_lock(9175261) then return jsonb_build_object('estado','ocupado'); end if;
  select * into c from public.produccion_tiempos_config where id=true;
  if c.ultimo_intento>clock_timestamp()-interval '110 seconds' then
    return jsonb_build_object('estado',case when c.detalle is null then 'actualizado' else 'pendiente' end,'ultima',c.ultima_lectura,'detalle',c.detalle);
  end if;
  update public.produccion_tiempos_config set ultimo_intento=clock_timestamp() where id=true;
  begin
    perform set_config('http.curlopt_timeout_ms','8000',true);
    perform set_config('http.curlopt_connecttimeout_ms','4000',true);
    perform set_config('http.curlopt_followlocation','0',true);
    cookies:=c.cookie;
    select * into r from extensions.http(('GET','https://xtensor-one.vercel.app/planta/tablero',
      array[('Cookie',coalesce(cookies,''))::extensions.http_header],null,null)::extensions.http_request);
    if r.status in (301,302,303,307,308) or r.content not like '%xt-board-row%' then
      select * into r from extensions.http_get('https://xtensor-one.vercel.app/planta');
      accion:=substring(r.content from 'name="(\$ACTION_ID_[a-zA-Z0-9]+)"');
      if accion is null then raise exception 'Acceso de planta pendiente'; end if;
      limite:='xtensor'||replace(gen_random_uuid()::text,'-','');
      cuerpo:='--'||limite||E'\r\nContent-Disposition: form-data; name="'||accion||E'"\r\n\r\n\r\n--'||limite||
        E'\r\nContent-Disposition: form-data; name="password"\r\n\r\n'||c.clave||E'\r\n--'||limite||E'--\r\n';
      select * into r from extensions.http_post('https://xtensor-one.vercel.app/planta',cuerpo,'multipart/form-data; boundary='||limite);
      select string_agg(split_part(h.value,';',1),'; ') into cookies from unnest(r.headers) h where lower(h.field)='set-cookie';
      if cookies is null then raise exception 'No se pudo acceder a planta'; end if;
      select * into r from extensions.http(('GET','https://xtensor-one.vercel.app/planta/tablero',
        array[('Cookie',cookies)::extensions.http_header],null,null)::extensions.http_request);
    end if;
    if r.status<>200 then raise exception 'Tablero temporalmente no disponible'; end if;
    filas:=public.produccion_parsear_tablero(r.content);
    momento:=clock_timestamp();
    perform public.produccion_aplicar_observacion(filas,momento);
    update public.produccion_tiempos_config set cookie=cookies,ultima_lectura=momento,detalle=null where id=true;
    return jsonb_build_object('estado','actualizado','ultima',momento,'maquinas',jsonb_array_length(filas));
  exception when others then
    -- No se devuelve la respuesta HTTP ni cookies al navegador.
    fallo:='Lectura pendiente; se conserva el historico.';
    update public.produccion_tiempos_config set detalle=fallo where id=true;
    update public.produccion_tiempos t set interrumpido=true where finalizacion is null
      and (c.ultima_lectura is null or public.produccion_minutos_calendario(c.ultima_lectura,clock_timestamp(),t.etapa)>3);
    return jsonb_build_object('estado','pendiente','ultima',c.ultima_lectura,'detalle',fallo);
  end;
end $$;

-- Completa codigos solo por UUID de Produccion, nunca por serial ni parecido de nombre.
create or replace function public.produccion_identificar(p_maquinas jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare m jsonb;
begin
  if public.calidad_rol()<>'admin' or public.calidad_rol() is null then raise exception 'Solo admin'; end if;
  if jsonb_typeof(p_maquinas)<>'array' or jsonb_array_length(p_maquinas)>2000 then raise exception 'Lista invalida'; end if;
  for m in select value from jsonb_array_elements(p_maquinas) loop
    if coalesce(m->>'code','') !~ '^X[A-Z][0-9A-Z-]+$' then continue; end if;
    update public.produccion_fabricaciones set codigo=m->>'code' where id=(m->>'id')::uuid and codigo is null;
  end loop;
end $$;
revoke all on function public.produccion_texto_nodo(jsonb,text), public.produccion_parsear_tablero(text),
  public.produccion_aplicar_observacion(jsonb,timestamptz),public.produccion_observar_tablero(),public.produccion_identificar(jsonb) from public,anon,authenticated;
grant execute on function public.produccion_observar_tablero(),public.produccion_identificar(jsonb) to authenticated;
-- Entrada por seleccion para operarios. Activar Anonymous Sign-Ins en Authentication.
-- No habilita al rol anon: requiere una sesion tecnica firmada por Supabase.
create or replace function public.calidad_entrar_seccion(p_rol text) returns void
language plpgsql security definer set search_path='' as $$
declare previo public.calidad_usuarios%rowtype;
begin
  if auth.uid() is null or coalesce(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'is_anonymous','false')<>'true' then
    raise exception 'Se requiere una sesion tecnica de seccion';
  end if;
  if p_rol is null or p_rol not in ('armado','resoldado','pulido','pintado','ensamble','empacado') then raise exception 'Seccion no permitida'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,717));
  select * into previo from public.calidad_usuarios where user_id=auth.uid() for update;
  if found then
    if not previo.activo then raise exception 'Acceso deshabilitado por admin'; end if;
    if previo.rol<>p_rol then raise exception 'Esta sesion pertenece a otra seccion'; end if;
    return;
  end if;
  insert into public.calidad_usuarios(user_id,rol,activo) values(auth.uid(),p_rol,true);
  insert into public.calidad_accesos_auditoria(actor,usuario,anterior,nuevo)
    values(auth.uid(),auth.uid(),null,jsonb_build_object('rol',p_rol,'activo',true,'origen','seleccion_seccion'));
end $$;
revoke all on function public.calidad_entrar_seccion(text) from public,anon;
grant execute on function public.calidad_entrar_seccion(text) to authenticated;
NOTIFY pgrst, 'reload schema';
commit;
