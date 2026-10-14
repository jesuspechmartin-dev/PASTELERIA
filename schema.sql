-- Doña Bellita POS · esquema de Supabase (varios cajeros a la vez)
-- Pégalo completo en Supabase > SQL Editor > Run. Se puede ejecutar más de una vez.

drop table if exists public.kv cascade;   -- del esquema anterior, si existía

create table if not exists public.branches (name text primary key);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  role text not null default 'cajero' check (role in ('admin','cajero')),
  branch text references public.branches(name) on update cascade on delete set null,
  all_branches boolean not null default false
);

create table if not exists public.products (
  id bigint generated always as identity primary key,
  branch text not null references public.branches(name) on update cascade on delete cascade,
  n text not null,
  p numeric(10,2) not null check (p >= 0),
  s integer check (s is null or s >= 0)          -- null = sin control de inventario
);

create table if not exists public.sales (
  id bigint generated always as identity primary key,
  branch text not null references public.branches(name) on update cascade on delete cascade,
  d date not null,
  t timestamptz not null default now(),
  m text not null check (m in ('Efectivo','Tarjeta','Transferencia')),
  total numeric(10,2) not null,
  rec numeric(10,2),
  ch numeric(10,2),
  items jsonb not null,
  cashier text
);
create index if not exists sales_branch_d on public.sales (branch, d);

create table if not exists public.cajas (
  branch text not null references public.branches(name) on update cascade on delete cascade,
  d date not null,
  value jsonb not null,
  primary key (branch, d)
);

alter table public.branches enable row level security;
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.sales    enable row level security;
alter table public.cajas    enable row level security;

create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') $$;

create or replace function public.can_branch(b text) returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from public.profiles p
   where p.id = auth.uid() and (p.role = 'admin' or p.all_branches or p.branch = b)) $$;

-- Políticas: cada usuario solo toca los datos de SU sucursal (o las que el superusuario autorizó)
drop policy if exists branches_read  on public.branches;
drop policy if exists branches_admin on public.branches;
drop policy if exists profiles_self  on public.profiles;
drop policy if exists profiles_admin on public.profiles;
drop policy if exists products_branch on public.products;
drop policy if exists sales_branch    on public.sales;
drop policy if exists products_read  on public.products;
drop policy if exists products_admin on public.products;
drop policy if exists sales_read  on public.sales;
drop policy if exists sales_admin on public.sales;
drop policy if exists cajas_branch    on public.cajas;

create policy branches_read  on public.branches for select using (true);
create policy branches_admin on public.branches for all using (public.is_admin()) with check (public.is_admin());
create policy profiles_self  on public.profiles for select using (id = auth.uid());
create policy profiles_admin on public.profiles for all using (public.is_admin()) with check (public.is_admin());
-- Cajeros: solo LEEN productos y ventas de su sucursal. Escribir (precios, productos, cancelar) es del superusuario.
-- Las ventas y los ajustes de inventario de los cajeros pasan por las funciones de abajo.
create policy products_read  on public.products for select using (public.can_branch(branch));
create policy products_admin on public.products for all using (public.is_admin()) with check (public.is_admin());
create policy sales_read  on public.sales for select using (public.can_branch(branch));
create policy sales_admin on public.sales for all using (public.is_admin()) with check (public.is_admin());
create policy cajas_branch    on public.cajas    for all using (public.can_branch(branch)) with check (public.can_branch(branch));

-- Registrar una venta (cajeros y superusuario). El total se calcula con los precios de la base de datos,
-- el inventario se descuenta con bloqueo de fila y no se vende si la caja del día está cerrada.
create or replace function public.registrar_venta(
  p_branch text, p_m text, p_total numeric, p_rec numeric, p_ch numeric, p_items jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare it jsonb; pr public.products; q int; v_total numeric := 0; v_id bigint;
begin
  if not public.can_branch(p_branch) then raise exception 'Sin acceso a la sucursal'; end if;
  if exists (select 1 from public.cajas where branch = p_branch
      and d = (now() at time zone 'America/Merida')::date and (value->>'closed') = 'true') then
    raise exception 'La caja de hoy está cerrada';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'q')::int;
    if q is null or q < 1 then raise exception 'Cantidad inválida'; end if;
    select * into pr from public.products where id = (it->>'id')::bigint and branch = p_branch for update;
    if not found then raise exception 'Producto no válido'; end if;
    if pr.s is not null then
      if pr.s < q then raise exception 'Sin stock suficiente de %', pr.n; end if;
      update public.products set s = s - q where id = pr.id;
    end if;
    v_total := v_total + pr.p * q;
  end loop;
  if v_total <= 0 then raise exception 'Venta vacía'; end if;
  insert into public.sales (branch, d, m, total, rec, ch, items, cashier)
  values (p_branch, (now() at time zone 'America/Merida')::date, p_m, v_total,
          case when p_m = 'Efectivo' then p_rec else v_total end,
          case when p_m = 'Efectivo' then p_rec - v_total else 0 end,
          p_items, (select username from public.profiles where id = auth.uid()))
  returning id into v_id;
  return v_id;
end $$;

-- Cancelar una venta: SOLO el superusuario. Regresa los productos al inventario.
create or replace function public.cancelar_venta(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare sl public.sales; it jsonb;
begin
  if not public.is_admin() then raise exception 'Solo el superusuario puede cancelar ventas'; end if;
  delete from public.sales where id = p_id returning * into sl;
  if not found then return; end if;
  for it in select * from jsonb_array_elements(sl.items) loop
    update public.products set s = s + (it->>'q')::int
      where id = (it->>'id')::bigint and branch = sl.branch and s is not null;
  end loop;
end $$;

-- Ajuste de inventario al cerrar caja (conteo físico). Queda registrado en el corte de caja.
create or replace function public.ajustar_stock(p_branch text, p_id bigint, p_real int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_branch(p_branch) then raise exception 'Sin acceso a la sucursal'; end if;
  if p_real is null or p_real < 0 then raise exception 'Cantidad inválida'; end if;
  update public.products set s = p_real where id = p_id and branch = p_branch and s is not null;
end $$;

-- Una caja cerrada solo la puede reabrir o modificar el superusuario.
create or replace function public.guard_caja() returns trigger language plpgsql as $$
begin
  if (old.value->>'closed') = 'true' and not public.is_admin() then
    raise exception 'La caja está cerrada; solo el superusuario puede modificarla';
  end if;
  return new;
end $$;
drop trigger if exists cajas_guard on public.cajas;
create trigger cajas_guard before update on public.cajas for each row execute function public.guard_caja();

-- Cada sucursal nueva nace con productos de ejemplo (el superusuario los edita después)
create or replace function public.seed_products() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.products (branch, n, p, s) values
    (new.name,'Rebanada de pastel de chocolate',45,null),(new.name,'Rebanada de pastel de vainilla',40,null),
    (new.name,'Pastel mediano (12 porciones)',380,null),(new.name,'Pastel grande (20 porciones)',620,null),
    (new.name,'Cupcake',30,null),(new.name,'Galleta',15,null),(new.name,'Pan dulce',12,null),(new.name,'Gelatina',25,null);
  return new;
end $$;
drop trigger if exists branches_seed on public.branches;
create trigger branches_seed after insert on public.branches for each row execute function public.seed_products();

insert into public.branches values ('Motul'), ('Tixkokob') on conflict do nothing;

-- Si ya tenías sucursales sin productos, se los agrega
insert into public.products (branch, n, p, s)
select b.name, v.n, v.p, null
from public.branches b
cross join (values ('Rebanada de pastel de chocolate',45),('Rebanada de pastel de vainilla',40),('Pastel mediano (12 porciones)',380),
  ('Pastel grande (20 porciones)',620),('Cupcake',30),('Galleta',15),('Pan dulce',12),('Gelatina',25)) as v(n,p)
where not exists (select 1 from public.products x where x.branch = b.name);

-- Actualización en vivo entre cajeros
alter table public.products replica identity full;
alter table public.sales    replica identity full;
alter table public.cajas    replica identity full;
do $$ declare t text; begin
  foreach t in array array['products','sales','cajas'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then null; end;
  end loop;
end $$;

-- PASO FINAL (después de crear el usuario en Authentication > Users):
-- Crea el usuario con el correo admin@bellita.app y marca "Auto Confirm User". Luego ejecuta:
-- insert into public.profiles (id, username, role)
-- select id, 'admin', 'admin' from auth.users where email = 'admin@bellita.app' on conflict do nothing;
