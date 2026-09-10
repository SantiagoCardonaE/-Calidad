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
