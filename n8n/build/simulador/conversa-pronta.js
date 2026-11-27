// Garante o estado da conversa, mesmo se o sub-workflow do turno falhar.
const base = $('Entrada').first().json;
const r = $json || {};
if (Array.isArray(r.historico)) return [{ json: r }];
return [{ json: { ...base, desfecho: 'erro', erro: JSON.stringify(r).slice(0, 500) } }];
