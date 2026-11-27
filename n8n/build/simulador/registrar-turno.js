// Guarda a fala do cliente e a resposta da Lia, e avança o turno.
const s = $('Ler fala do cliente').first().json;
const r = $json || {};
const historico = [...(s.historico || []),
  { de: 'cliente', texto: s.exibido },
  { de: 'lia', texto: r.output ?? ('[ERRO DA LIA] ' + JSON.stringify(r.error ?? r).slice(0, 300)),
    blocos: (r.blocos || []).map((b) => b.tipo), validacao: r.validacao || [] },
];
const { mensagem, modelo, esforco, janela, exibido, acao, continua, ...estado } = s;
return [{ json: { ...estado, historico, turno: s.turno + 1 } }];
