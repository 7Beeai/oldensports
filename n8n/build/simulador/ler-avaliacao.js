// Lê as notas da IA avaliadora e prepara o registro da conversa.
const pedidos = $('Montar avaliação').all();
return $input.all().map((it, i) => {
  const s = pedidos[i].json.s;
  const bruto = String(it.json.text ?? '');
  let j;
  try { j = JSON.parse(bruto.slice(bruto.indexOf('{'), bruto.lastIndexOf('}') + 1)); }
  catch (e) { j = { notas: {}, nota_geral: null, aprovado: false, problemas: ['avaliação não veio em JSON'], sugestao: '', resumo: bruto.slice(0, 300) }; }
  return { json: {
    rodada: s.rodada, persona_id: s.persona_id, sessao: s.sessao, canal: s.canal,
    transcricao: s.historico || [], turnos: (s.historico || []).filter((h) => h.de === 'cliente').length,
    desfecho: s.desfecho, fatos: s.fatos || {}, notas: j.notas || {}, nota_geral: j.nota_geral,
    aprovado: !!j.aprovado, problemas: [...(j.resumo ? ['Resumo: ' + j.resumo] : []), ...(j.problemas || [])],
    sugestao: j.sugestao || '', duracao_ms: Date.now() - (s.inicio || Date.now()),
  } };
});
