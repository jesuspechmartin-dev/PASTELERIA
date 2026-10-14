const { createClient } = require('@supabase/supabase-js');
const res = (s, o) => ({ statusCode: s, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(o) });

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return res(405, { error: 'Método no permitido' });
  const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const token = (event.headers.authorization || '').replace('Bearer ', '');
  const { data: { user }, error } = await sb.auth.getUser(token);
  if (error || !user) return res(401, { error: 'No autorizado' });
  const { data: me } = await sb.from('profiles').select('role').eq('id', user.id).maybeSingle();
  if (!me || me.role !== 'admin') return res(403, { error: 'Solo el superusuario puede administrar usuarios' });
  let b;
  try { b = JSON.parse(event.body || '{}'); } catch (e) { return res(400, { error: 'Solicitud inválida' }); }

  if (b.action === 'upsert') {
    const u = String(b.username || '').toLowerCase();
    const pw = String(b.password || '');
    if (!/^[a-z0-9._-]{3,30}$/.test(u) || pw.length < 6) return res(400, { error: 'Datos inválidos' });
    const { data: br } = await sb.from('branches').select('name').eq('name', b.branch).maybeSingle();
    if (!br) return res(400, { error: 'La sucursal no existe' });
    const { data: ex } = await sb.from('profiles').select('id,role').eq('username', u).maybeSingle();
    if (ex) {
      const { error: e } = await sb.auth.admin.updateUserById(ex.id, { password: pw });
      if (e) return res(400, { error: e.message });
      if (ex.role !== 'admin') await sb.from('profiles').update({ branch: b.branch, all_branches: !!b.all_branches }).eq('id', ex.id);
      return res(200, { ok: true });
    }
    const { data: c, error: e } = await sb.auth.admin.createUser({ email: u + '@bellita.app', password: pw, email_confirm: true });
    if (e) return res(400, { error: e.message });
    const { error: e2 } = await sb.from('profiles').insert({ id: c.user.id, username: u, role: 'cajero', branch: b.branch, all_branches: !!b.all_branches });
    if (e2) { await sb.auth.admin.deleteUser(c.user.id); return res(400, { error: e2.message }); }
    return res(200, { ok: true });
  }

  if (b.action === 'delete') {
    const { data: t } = await sb.from('profiles').select('role').eq('id', b.id).maybeSingle();
    if (!t || t.role === 'admin') return res(400, { error: 'No se puede eliminar ese usuario' });
    const { error: e } = await sb.auth.admin.deleteUser(b.id);
    if (e) return res(400, { error: e.message });
    return res(200, { ok: true });
  }
  return res(400, { error: 'Acción desconocida' });
};
