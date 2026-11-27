// Garante uma conversa por persona, mesmo se o sub-workflow falhar.
const preparadas = $('Preparar conversas').all();
return $input.all().map((it, i) => {
  const base = preparadas[i] ? preparadas[i].json : {};
  if (it.json && Array.isArray(it.json.historico)) return { json: it.json };
  return { json: { ...base, desfecho: 'erro', erro: JSON.stringify(it.json || {}).slice(0, 500) } };
});
