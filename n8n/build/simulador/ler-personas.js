// Junta cada persona criada pela IA com a combinação sorteada e prepara a conversa.
const pedidos = $('O que simular').all();
return $input.all().map((it, i) => {
  const base = pedidos[i].json;
  const bruto = String(it.json.text ?? '');
  let persona;
  try { persona = JSON.parse(bruto.slice(bruto.indexOf('{'), bruto.lastIndexOf('}') + 1)); }
  catch (e) { persona = { nome: 'Cliente ' + base.indice, sobre: 'Persona não gerada (' + (it.json.error ? 'erro da IA' : 'resposta inválida') + ').', primeira_mensagem: 'oi' }; }
  const c = base.combinacao;
  return { json: {
    rodada: base.rodada, combinacao: c, persona, cfg: base.cfg, canal: c.canal,
    // "teste:" faz a limpeza devolver o estoque; "wa:" faz a Lia se comportar como no WhatsApp
    sessao: 'teste:' + (c.canal === 'whatsapp' ? 'wa:' : '') + base.rodada + '-' + base.indice,
    historico: [], turno: 0, inicio: Date.now(),
  } };
});
