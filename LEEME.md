# Doña Bellita POS · Supabase + Netlify

## 1. Supabase
1. Crea un proyecto en supabase.com.
2. SQL Editor → pega `schema.sql` (sin la última parte comentada) → Run. Si ya habías ejecutado la versión anterior, vuelve a ejecutar esta: es segura y borra la tabla vieja `kv`.
3. Authentication → Users → Add user: correo `admin@bellita.app`, tu contraseña, y marca **Auto Confirm User**.
4. SQL Editor → ejecuta el `insert into public.profiles ...` que está al final de `schema.sql` (quita los `--`).
5. Project Settings → API: copia **Project URL** y **anon key** en `public/config.js`.
   Copia también la **service_role key** (solo para el paso 2, nunca en config.js).

## 2. Netlify
1. Sube esta carpeta a un repositorio de GitHub y en Netlify elige **Import from Git**
   (o usa `netlify deploy --prod` con la CLI). El arrastrar y soltar NO sirve: no instala la función.
2. Site configuration → Environment variables:
   - `SUPABASE_URL` = tu Project URL
   - `SUPABASE_SERVICE_ROLE_KEY` = tu service_role key
3. Deploy. Entra con usuario `admin` y la contraseña del paso 3.

## 3. Uso
Con `admin` (superusuario) crea sucursales y usuarios en la pestaña Productos.

## 4. Varios cajeros a la vez
- Cada venta es un registro propio y el inventario se descuenta en la base de datos: dos cajeros de la misma sucursal pueden vender al mismo tiempo sin pisarse.
- Los dispositivos se actualizan solos (en vivo y cada 15 segundos).
- Cada sucursal solo ve sus propios datos (reglas RLS en `schema.sql`).
- La app carga los últimos 92 días de ventas; lo anterior sigue guardado en Supabase.

## 5. Permisos de los cajeros
- **Cajero:** vender, ver el reporte de su sucursal, abrir y cerrar la caja del día y hacer el conteo de inventario al cerrar (los ajustes quedan en el corte).
- **Solo el superusuario:** cancelar ventas, crear/editar/quitar productos y precios, editar inventario, reabrir una caja cerrada, ver cajas de días anteriores y administrar usuarios y sucursales.
- Estas reglas viven en la base de datos (`schema.sql`), no solo en la pantalla. El total de cada venta se calcula con los precios guardados en Supabase, y no se puede vender con la caja del día cerrada.
