// Gera os 3 workflows do n8n a partir de n8n/system-prompt.md
// Uso: node n8n/build/gerar-workflows.js
//
//   1-nucleo-agente.json   Agente + memória + ferramentas. Chamado pelos outros dois.
//   2-chat-demo.json       Chat público para o cliente testar.
//   3-bateria-testes.json  Roda os cenários do banco em várias configurações e dá nota.
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '..');
// O prompt (n8n/system-prompt.md) vai para o banco pelo node n8n/build/gerar-sql.js

// Padrões do agente: mude aqui ou no nó "Configuração" do núcleo
const PADRAO = { modelo: 'anthropic/claude-haiku-5.5', esforco: 'medium', janela: 20 };

let seq = 0;
const id = () => `b2000000-0000-4000-8000-${String(++seq).padStart(12, '0')}`;
const conn = (to, type = 'main', index = 0) => ({ node: to, type, index });
const main = (...targets) => ({ main: targets.map((t) => (Array.isArray(t) ? t : [t]).map((x) => conn(x))) });
const save = (file, wf) => {
  fs.writeFileSync(path.join(dir, file), JSON.stringify(wf, null, 2) + '\n');
  console.log('gerado:', file);
};
const pg = (name, position, query, replacement, extra = {}) => ({
  id: id(), name, type: 'n8n-nodes-base.postgres', typeVersion: 2.6, position,
  parameters: { operation: 'executeQuery', query, options: replacement ? { queryReplacement: replacement } : {} },
  ...extra,
});
const code = (name, position, jsCode, { mode, ...extra } = {}) => ({
  id: id(), name, type: 'n8n-nodes-base.code', typeVersion: 2, position,
  parameters: { ...(mode ? { mode } : {}), jsCode }, ...extra,
});
const openRouter = (name, position, modelExpr, effortExpr) => ({
  id: id(), name, type: '@n8n/n8n-nodes-langchain.lmChatOpenRouter', typeVersion: 1, position,
  // Sem temperatura: o Claude Haiku 5.5 recusa valores diferentes do padrão.
  parameters: {
    model: modelExpr,
    options: { ...(effortExpr ? { reasoningEffort: effortExpr } : {}), maxRetries: 2, timeout: 90000 },
  },
});

// =====================================================================
// 1. Núcleo do agente
// =====================================================================
{
  seq = 0;
  const tool = (name, position, description, query, payload) => ({
    id: id(), name, type: 'n8n-nodes-base.postgresTool', typeVersion: 2.6, position,
    parameters: {
      descriptionType: 'manual', toolDescription: description, operation: 'executeQuery', query,
      options: { queryReplacement: `={{ JSON.stringify({ ${payload} }) }}` },
    },
  });
const LER_BLOCOS = `// Lê a resposta da Lia: um JSON {"blocos": [...]}. Se vier texto solto, vira um bloco de texto.
const bruto = String($json.output ?? '');
const problemas = [];
const tentar = (t) => { try { const j = JSON.parse(t); return Array.isArray(j) ? j : (j && Array.isArray(j.blocos) ? j.blocos : null); } catch (e) { return null; } };
let t = bruto.trim().replace(/^\\\`\\\`\\\`(?:json)?\\\\s*/i, '').replace(/\\\`\\\`\\\`\\\\s*$/, '');
let blocos = tentar(t);
if (!blocos) { const i = t.indexOf('{'), f = t.lastIndexOf('}'); if (i >= 0 && f > i) blocos = tentar(t.slice(i, f + 1)); }
if (!blocos && t.startsWith('{')) {
  // JSON quebrado: aproveita os textos que der para ler, sem mostrar código ao cliente
  const textos = [...t.matchAll(/"(?:texto|corpo)"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"/g)].map((m) => { try { return JSON.parse('"' + m[1] + '"'); } catch (e) { return ''; } }).filter(Boolean);
  blocos = [{ tipo: 'texto', texto: textos.join('\\n\\n') || 'Desculpa, me enrolei aqui. Pode repetir?' }];
  problemas.push('resposta não era um JSON válido');
}
if (!blocos) {
  blocos = [{ tipo: 'texto', texto: bruto }];
  problemas.push('resposta veio em texto, não em blocos');
}
const skus = [];
for (const b of blocos) {
  if (!b || typeof b !== 'object') continue;
  if (b.sku) skus.push(b.sku);
  for (const s of (b.skus || [])) skus.push(s);
  for (const sec of (b.secoes || [])) for (const s of (sec.skus || [])) skus.push(s);
}
return [{ json: { blocos, problemas, skus: [...new Set(skus.map((s) => String(s).trim().toUpperCase()))] } }];`;

const VALIDAR_BLOCOS = `// Confere os limites do WhatsApp e se cada produto existe e tem estoque; produto ruim sai, bloco ruim vira texto.
const lidos = $('Ler blocos').first().json;
const prods = $json.produtos || {};
const problemas = [...lidos.problemas];
const corta = (s, n) => { s = String(s ?? '').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
const filtra = (lista, onde) => {
  const bons = [];
  for (const s of (lista || [])) {
    const k = String(s || '').trim().toUpperCase();
    if (prods[k] && prods[k].disponivel) bons.push(k); else problemas.push(onde + ': código ' + s + ' não existe ou está esgotado');
  }
  return [...new Set(bons)];
};
const saida = [];
for (const b of lidos.blocos) {
  const tipo = b && b.tipo;
  if (tipo === 'texto') {
    if ((b.botoes || []).length > 3) problemas.push('texto: mais de 3 botões');
    const botoes = (b.botoes || []).slice(0, 3).map((x, i) => ({ id: corta(x.id || ('b' + i), 200), titulo: corta(x.titulo, 20) })).filter((x) => x.titulo);
    if (b.texto) saida.push({ tipo, texto: String(b.texto), botoes });
  } else if (tipo === 'menu') {
    if ((b.opcoes || []).length > 10) problemas.push('menu: mais de 10 opções');
    const opcoes = (b.opcoes || []).slice(0, 10).map((o, i) => ({ id: corta(o.id || ('op' + i), 200), titulo: corta(o.titulo, 24), descricao: o.descricao ? corta(o.descricao, 72) : '' })).filter((o) => o.titulo);
    if (opcoes.length) saida.push({ tipo, corpo: String(b.corpo || 'Escolha uma opção'), botao: corta(b.botao || 'Ver opções', 20), opcoes });
  } else if (tipo === 'produto' || tipo === 'midias') {
    const s = filtra([b.sku], tipo);
    if (s.length) saida.push({ tipo, sku: s[0], texto: String(b.texto || ''), produto: prods[s[0]], ...(tipo === 'produto' ? { mostrar_preco: b.preco === true } : {}) });
  } else if (tipo === 'carrossel_produtos') {
    let s = filtra(b.skus, tipo);
    if (s.length > 10) { problemas.push('carrossel: mais de 10 peças'); s = s.slice(0, 10); }
    if (s.length === 1) saida.push({ tipo: 'produto', sku: s[0], texto: String(b.corpo || ''), produto: prods[s[0]], mostrar_preco: b.preco === true });
    else if (s.length >= 2) saida.push({ tipo, corpo: String(b.corpo || ''), skus: s, produtos: s.map((x) => prods[x]), mostrar_preco: b.preco === true });
  } else if (tipo === 'vitrine') {
    let total = 0; const secoes = [];
    if ((b.secoes || []).length > 10) problemas.push('vitrine: mais de 10 seções');
    for (const sec of (b.secoes || []).slice(0, 10)) {
      const s = filtra(sec.skus, 'vitrine').slice(0, Math.max(0, 30 - total));
      total += s.length;
      if (s.length) secoes.push({ titulo: corta(sec.titulo || 'Seção', 24), skus: s, produtos: s.map((x) => prods[x]) });
    }
    if (secoes.length) saida.push({ tipo, cabecalho: corta(b.cabecalho || 'Vitrine', 60), corpo: String(b.corpo || ''), secoes, mostrar_preco: b.preco === true });
  } else if (tipo === 'tamanho') {
    const k = String(b.sku || '').trim().toUpperCase();
    if (prods[k]) saida.push({ tipo, sku: k, texto: String(b.texto || 'Me conta suas medidas que eu te digo o tamanho'), produto: prods[k] });
    else problemas.push('tamanho: código ' + b.sku + ' não existe');
  } else if (tipo === 'comparacao') {
    const s = filtra((b.skus || []).slice(0, 2), tipo);
    if ((b.skus || []).length !== 2) problemas.push('comparacao: precisa de exatamente 2 peças');
    if (s.length === 2) saida.push({ tipo, texto: String(b.texto || ''), skus: s, produtos: s.map((x) => prods[x]) });
    else if (s.length === 1) saida.push({ tipo: 'produto', sku: s[0], texto: String(b.texto || ''), produto: prods[s[0]] });
  } else if (tipo === 'provador') {
    const s = filtra([b.sku], tipo);
    if (s.length) saida.push({ tipo, sku: s[0], texto: String(b.texto || ''), produto: prods[s[0]] });
  } else if (tipo === 'catalogo') {
    saida.push({ tipo, corpo: String(b.corpo || 'Veja o catálogo completo') });
  } else if (tipo === 'pagamento') {
    const url = String(b.url || '');
    if (/\\/webhook\\/olden-pagamento\\?t=/.test(url)) saida.push({ tipo, texto: String(b.texto || 'Pague por aqui'), url });
    else { problemas.push('pagamento: link inválido'); if (b.texto) saida.push({ tipo: 'texto', texto: String(b.texto), botoes: [] }); }
  } else {
    problemas.push('bloco desconhecido: ' + tipo);
    const t = b && (b.texto || b.corpo);
    if (t) saida.push({ tipo: 'texto', texto: String(t), botoes: [] });
  }
}
if (!saida.length) { saida.push({ tipo: 'texto', texto: 'Desculpa, me enrolei aqui. Pode repetir?', botoes: [] }); problemas.push('nenhum bloco válido'); }

// Versão em texto (para quem não desenha blocos: bateria, avisos guardados, testes)
const brl = (v) => (v == null ? '' : 'R$ ' + Number(v).toFixed(2).replace('.', ','));
// Sem "preco": true o cartão mostra só o produto (o cliente vê o preço quando pergunta ou escolhe)
const linha = (p, comPreco = true) => '• ' + p.nome + (comPreco ? ' — ' + brl(p.preco) + ' no cartão (Pix ' + brl(p.preco_pix) + ')' : '') + (p.tamanhos ? ' · tam. ' + p.tamanhos.join(', ') : '');
const partes = saida.map((b) => {
  switch (b.tipo) {
    case 'texto': return b.texto + (b.botoes.length ? '\\n[' + b.botoes.map((x) => x.titulo).join('] [') + ']' : '');
    case 'menu': return b.corpo + '\\n' + b.opcoes.map((o) => '• ' + o.titulo).join('\\n');
    case 'produto': return (b.texto ? b.texto + '\\n' : '') + linha(b.produto, b.mostrar_preco);
    case 'midias': return (b.texto ? b.texto + '\\n' : '') + '[fotos de ' + b.produto.nome + ']';
    case 'carrossel_produtos': return (b.corpo ? b.corpo + '\\n' : '') + b.produtos.map((p) => linha(p, b.mostrar_preco)).join('\\n');
    case 'vitrine': return b.cabecalho + (b.corpo ? '\\n' + b.corpo : '') + '\\n' + b.secoes.map((s) => s.titulo + ':\\n' + s.produtos.map((p) => linha(p, b.mostrar_preco)).join('\\n')).join('\\n');
    case 'catalogo': return b.corpo + ' [Ver catálogo]';
    case 'tamanho': return b.texto + '\\n[formulário de tamanho: altura, peso e caimento da ' + b.produto.nome + ']';
    case 'comparacao': return (b.texto ? b.texto + '\\n' : '') + '[comparação lado a lado]\\n' + b.produtos.map((p) => linha(p) + Object.values(p.atributos || {}).map((a) => '\\n   ' + a).join('')).join('\\n');
    case 'pagamento': return b.texto + '\\n' + b.url;
    case 'provador': return (b.texto ? b.texto + '\\n' : '') + '[prévia do cliente vestindo ' + b.produto.nome + ']';
  }
  return '';
});
return [{ json: { output: partes.join('\\n\\n'), blocos: saida, validacao: problemas } }];`;

  const C = '$json.conversa_id';
  const nodes = [
    {
      id: id(), name: 'Entrada', type: 'n8n-nodes-base.executeWorkflowTrigger', typeVersion: 1.1,
      position: [0, 0], parameters: { inputSource: 'passthrough' },
    },
    {
      id: id(), name: 'Configuração', type: 'n8n-nodes-base.set', typeVersion: 3.4, position: [220, 0],
      parameters: {
        mode: 'manual',
        assignments: {
          assignments: [
            // Vazio quando o Núcleo é executado sozinho (botão Execute): usa uma sessão de teste
            ['sessao', 'string', "={{ $json.sessao || 'teste:manual' }}"],
            // Avisos internos ([AVISO INTERNO]) só valem quando vêm do sistema; se o cliente digitar, é removido
            ['mensagem', 'string', "={{ ($json.origem === 'sistema' ? $json.mensagem : String($json.mensagem || '').replace(/\\[\\s*AVISO INTERNO\\s*\\]/gi, '').trim()) || 'Oi, quero conhecer as camisas' }}"],
            ['modelo', 'string', `={{ $json.modelo || '${PADRAO.modelo}' }}`],
            ['esforco', 'string', `={{ $json.esforco || '${PADRAO.esforco}' }}`],
            ['janela', 'number', `={{ Number($json.janela) || ${PADRAO.janela} }}`],
          ].map(([name, type, value], i) => ({ id: `cfg-${i}`, name, type, value })),
        },
        options: {},
      },
    },
    {
      // Só a bateria usa: turnos "#pagamento_aprovado" / "#pagamento_recusado" em sessões "teste:"
      id: id(), name: 'Comando de teste?', type: 'n8n-nodes-base.if', typeVersion: 2.2, position: [330, 0],
      parameters: {
        conditions: {
          options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
          conditions: [{
            id: 'cmd-0',
            leftValue: "={{ $json.sessao.startsWith('teste:') && $json.mensagem.startsWith('#pagamento_') }}",
            rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true },
          }],
          combinator: 'and',
        },
        options: {},
      },
    },
    pg('Simular pagamento', [440, -200],
      "select $1::jsonb->>'sessao' as sessao,\n       simular_pagamento_sessao($1::jsonb->>'sessao', $1::jsonb->>'mensagem') as mensagem,\n       $1::jsonb->>'modelo' as modelo, $1::jsonb->>'esforco' as esforco, ($1::jsonb->>'janela')::int as janela",
      '={{ JSON.stringify($json) }}'),
    pg('Contexto do atendimento', [440, 0],
      "select c.*, prompt_montado(c.cliente_nome, c.status, c.situacao_pedido, c.catalogo)\n         || case when $1::jsonb->>'sessao' like 'wa:%' then E'\\n- Canal: WhatsApp (o cliente pode mandar fotos)'\n                 else E'\\n- Canal: página de chat (o cliente NÃO consegue mandar fotos: não ofereça o provador)' end as prompt_sistema,\n       $1::jsonb->>'mensagem' as mensagem, $1::jsonb->>'modelo' as modelo,\n       $1::jsonb->>'esforco' as esforco, ($1::jsonb->>'janela')::int as janela\nfrom contexto_atendimento($1::jsonb->>'sessao') c",
      '={{ JSON.stringify($json) }}'),
    {
      id: id(), name: 'Agente Olden', type: '@n8n/n8n-nodes-langchain.agent', typeVersion: 2.2, position: [700, 0],
      parameters: {
        promptType: 'define', text: '={{ $json.mensagem }}',
        // O prompt vem do banco (tabela prompt_agente, versão ativa), já com os dados da conversa
        options: { systemMessage: '={{ $json.prompt_sistema }}', maxIterations: 10 },
      },
    },
    openRouter('Claude via OpenRouter', [440, 260], '={{ $json.modelo }}', '={{ $json.esforco }}'),
    {
      id: id(), name: 'Memória da conversa', type: '@n8n/n8n-nodes-langchain.memoryPostgresChat', typeVersion: 1.3,
      position: [620, 260],
      parameters: {
        sessionIdType: 'customKey', sessionKey: `={{ ${C} }}`, tableName: 'n8n_chat_histories',
        contextWindowLength: '={{ $json.janela }}',
      },
    },
    tool('registrar_interesse', [780, 260],
      'Registra que o cliente demonstrou interesse num produto. Chame quando o cliente perguntar sobre uma peça específica.',
      "insert into interesses (conversa_id, sku)\nselect (j->>'conversa_id')::uuid, j->>'sku'\nfrom (select $1::jsonb as j) p\nreturning 'interesse registrado' as resultado, sku;",
      `conversa_id: ${C}, sku: $fromAI('sku', 'Código do modelo (OLD-P...) ou do tamanho (OLD-...) que veio da busca', 'string')`),
    tool('registrar_pedido', [940, 260],
      'Registra (reserva) um item do pedido e baixa o estoque. Só chame depois que o cliente confirmar produto, tamanho, quantidade, forma de pagamento e nome. Chame uma vez por produto/tamanho. O banco calcula o valor; se faltar estoque, devolve erro.',
      "insert into pedidos (conversa_id, sku, tamanho, quantidade, forma_pagamento, nome_cliente)\nselect (j->>'conversa_id')::uuid, j->>'sku', j->>'tamanho', (j->>'quantidade')::int,\n       j->>'forma_pagamento', j->>'nome_cliente'\nfrom (select $1::jsonb as j) p\nreturning sku, tamanho, quantidade, forma_pagamento, valor_unitario, valor_total, status;",
      `conversa_id: ${C}, sku: $fromAI('sku', 'Código do TAMANHO escolhido (OLD-...), copiado da busca; se só tiver o do modelo (OLD-P...), use ele e informe o tamanho', 'string'), tamanho: $fromAI('tamanho', 'Tamanho escolhido exatamente como veio na busca, ex.: M, GG, 4-8, Único', 'string'), quantidade: $fromAI('quantidade', 'Quantidade de peças, de 1 a 10', 'number'), forma_pagamento: $fromAI('forma_pagamento', 'pix ou cartao', 'string'), nome_cliente: $fromAI('nome_cliente', 'Nome do cliente', 'string')`),
    tool('registrar_avaliacao', [1100, 260],
      'Registra a avaliação do atendimento (nota de 1 a 5 e comentário opcional) e encerra a conversa. Chame quando o cliente der a nota.',
      "insert into avaliacoes (conversa_id, nota, comentario)\nselect (j->>'conversa_id')::uuid, (j->>'nota')::int, nullif(j->>'comentario', '')\nfrom (select $1::jsonb as j) p\nreturning 'avaliacao registrada' as resultado, nota;",
      `conversa_id: ${C}, nota: $fromAI('nota', 'Nota de 1 a 5 dada pelo cliente', 'number'), comentario: $fromAI('comentario', 'Comentário do cliente; vazio se não houver', 'string')`),
    tool('gerar_link_pagamento', [1260, 260],
      'Gera o link de pagamento de todos os itens já registrados nesta conversa e devolve o link e o valor total. Chame depois de registrar o(s) item(ns) com registrar_pedido, ou quando o cliente precisar de um novo link (ex.: pagamento recusado). Envie ao cliente exatamente o link devolvido.',
      "select gerar_pagamento(($1::jsonb->>'conversa_id')::uuid) as resultado",
      `conversa_id: ${C}`),
    tool('buscar_produtos', [1420, 260],
      'Busca produtos da loja com estoque. Use para QUALQUER pedido de produto. Devolve até 10 modelos com código do modelo (item_group_id), nome, preço, preço no Pix, tamanhos disponíveis com os códigos de cada tamanho (skus, na mesma ordem), resumo, foto e link.',
      "select * from buscar_produtos($1::jsonb->>'consulta',\n  coalesce(nullif($1::jsonb->>'filtros', '')::jsonb, '{}'::jsonb),\n  coalesce(($1::jsonb->>'limite')::int, 5))",
      `consulta: $fromAI('consulta', 'O que o cliente procura, em palavras simples (ex.: camisa verde feminina do Palmeiras). Pode ficar vazio se só usar filtros', 'string'), filtros: $fromAI('filtros', 'JSON com filtros opcionais: departamento (camisas, bones, calcados, equipamentos, roupas, acessorios, kits, bebe, infantil, outros), clube (ex.: Palmeiras), genero (masculino, feminino, unissex, infantil), faixa_etaria (adulto, infantil, bebe), tamanho (ex.: M), preco_max (número). Use {} se não houver filtro', 'string'), limite: $fromAI('limite', 'Quantos modelos trazer, de 1 a 10 (normalmente 5)', 'number')`),
    tool('ver_vitrine', [1580, 260],
      'Mostra os produtos de uma vitrine montada pela loja (ex.: promocoes, destaques, palmeiras). Devolve o mesmo formato de buscar_produtos.',
      "select * from itens_vitrine($1::jsonb->>'nome', coalesce(($1::jsonb->>'limite')::int, 10))",
      `nome: $fromAI('nome', 'Nome da vitrine, ex.: promocoes', 'string'), limite: $fromAI('limite', 'Quantos produtos trazer, de 1 a 30', 'number')`),
    tool('recomendar_tamanho', [1740, 260],
      'Calcula o tamanho sugerido de uma peça a partir de altura, peso e caimento (adulto) ou da idade (infantil), usando as medidas da peça e o estoque. Devolve o tamanho sugerido, se tem em estoque, o código do tamanho e como foi calculado. É uma sugestão: apresente como tal.',
      "select recomendar_tamanho($1::jsonb->>'sku', nullif(($1::jsonb->>'altura_cm')::numeric, 0), nullif(($1::jsonb->>'peso_kg')::numeric, 0),\n  coalesce(nullif($1::jsonb->>'caimento', ''), 'normal'), nullif(($1::jsonb->>'idade_anos')::numeric, 0)) as resultado",
      `sku: $fromAI('sku', 'Código do modelo (OLD-P...) que veio da busca', 'string'), altura_cm: $fromAI('altura_cm', 'Altura em centímetros (ex.: 172). Use 0 se não souber', 'number'), peso_kg: $fromAI('peso_kg', 'Peso em quilos (ex.: 70). Use 0 se não souber', 'number'), caimento: $fromAI('caimento', 'justa, normal ou solta', 'string'), idade_anos: $fromAI('idade_anos', 'Idade da criança em anos, para peças infantis. Use 0 para adulto', 'number')`),
    tool('detalhes_produto', [1900, 260],
      'Traz todos os detalhes de uma peça: descrição completa, material, gola, medidas, tamanhos com disponibilidade e códigos, preço, Pix, fotos e vídeo. Use quando o cliente perguntar algo que o resumo da busca não responde.',
      "select detalhes_produto($1::jsonb->>'sku') as detalhes",
      `sku: $fromAI('sku', 'Código do modelo (OLD-P...) ou do tamanho que veio da busca', 'string')`),
    code('Ler blocos', [960, 0], LER_BLOCOS),
    pg('Conferir produtos', [1180, 0], 'select produtos_para_blocos($1::jsonb) as produtos', '={{ JSON.stringify($json.skus) }}'),
    code('Validar blocos', [1400, 0], VALIDAR_BLOCOS),
  ];
  const connections = {
    Entrada: main('Configuração'),
    'Configuração': main('Comando de teste?'),
    'Comando de teste?': main('Simular pagamento', 'Contexto do atendimento'),
    'Simular pagamento': main('Contexto do atendimento'),
    'Contexto do atendimento': main('Agente Olden'),
    'Claude via OpenRouter': { ai_languageModel: [[conn('Agente Olden', 'ai_languageModel')]] },
    'Memória da conversa': { ai_memory: [[conn('Agente Olden', 'ai_memory')]] },
    registrar_interesse: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    registrar_pedido: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    registrar_avaliacao: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    gerar_link_pagamento: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    buscar_produtos: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    ver_vitrine: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    recomendar_tamanho: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    detalhes_produto: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    'Agente Olden': main('Ler blocos'),
    'Ler blocos': main('Conferir produtos'),
    'Conferir produtos': main('Validar blocos'),
  };
  save('1-nucleo-agente.json', {
    name: 'Olden | 1. Núcleo do agente', nodes, connections, pinData: {},
    settings: { executionOrder: 'v1', executionTimeout: 300 },
  });
}

// =====================================================================
// 2. Chat de demonstração (público)
// =====================================================================
const NUCLEO = { __rl: true, mode: 'list', value: '' }; // escolhido no n8n depois de importar
{
  seq = 100;
  // Página de chat própria: mostra também as mensagens que a Lia manda sozinha
  const CHAT_HTML = fs.readFileSync(path.join(__dirname, 'chat-pagina.html'), 'utf8');
  const responderJson = (name, position, body) => ({
    id: id(), name, type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position,
    parameters: {
      respondWith: 'text', responseBody: body,
      options: { responseHeaders: { entries: [{ name: 'Content-Type', value: 'application/json; charset=utf-8' }, { name: 'Cache-Control', value: 'no-store' }] } },
    },
  });
  const nodes = [
    // Chat embutido do n8n: bom para testes rápidos no editor (Open chat).
    // Ele NÃO mostra as mensagens que a Lia manda sozinha; para isso use a página "olden-chat".
    {
      id: id(), name: 'Chat público', type: '@n8n/n8n-nodes-langchain.chatTrigger', typeVersion: 1.1,
      position: [0, 0], webhookId: 'c3d2e1f0-4a5b-4c6d-8e7f-0a1b2c3d4e5f',
      parameters: {
        public: true, mode: 'hostedChat', authentication: 'none',
        initialMessages: 'Oi! Aqui é a Lia, da Olden Sports 😊\nO que você está procurando hoje?',
        options: {
          title: 'Olden Sports',
          subtitle: 'Atendimento (ambiente de demonstração)',
          inputPlaceholder: 'Digite sua mensagem...',
          customCss: ':root {\n  --chat--color--primary: #0b6b3a;\n  --chat--color--primary-shade-50: #095a31;\n  --chat--color--primary--shade-100: #074a28;\n  --chat--color--secondary: #0b6b3a;\n  --chat--color-secondary-shade-50: #095a31;\n  --chat--header--background: #0b6b3a;\n}',
        },
      },
    },
    {
      id: id(), name: 'Preparar mensagem', type: 'n8n-nodes-base.set', typeVersion: 3.4, position: [240, 0],
      parameters: {
        mode: 'manual',
        assignments: {
          assignments: [
            { id: 'p-0', name: 'sessao', type: 'string', value: "={{ 'demo:' + $json.sessionId }}" },
            { id: 'p-1', name: 'mensagem', type: 'string', value: '={{ $json.chatInput }}' },
          ],
        },
        options: {},
      },
    },
    {
      id: id(), name: 'Chamar núcleo do agente', type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.2,
      position: [480, 0],
      parameters: { source: 'database', workflowId: NUCLEO, mode: 'once', options: { waitForSubWorkflow: true } },
    },

    // Página de chat da Olden
    {
      id: id(), name: 'Página do chat', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, 260],
      webhookId: 'a7b8c9d0-4e5f-4a6b-9c23-d4e5f6a7b8c9',
      parameters: { httpMethod: 'GET', path: 'olden-chat', responseMode: 'responseNode', options: {} },
    },
    {
      id: id(), name: 'Responder página', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [240, 260],
      parameters: {
        respondWith: 'text', responseBody: CHAT_HTML,
        options: { responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }] } },
      },
    },

    {
      id: id(), name: 'Mensagem da página', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, 460],
      webhookId: 'b8c9d0e1-5f6a-4b7c-8d34-e5f6a7b8c9d0',
      parameters: { httpMethod: 'POST', path: 'olden-chat-enviar', responseMode: 'responseNode', options: {} },
    },
    {
      id: id(), name: 'Preparar mensagem da página', type: 'n8n-nodes-base.set', typeVersion: 3.4, position: [240, 460],
      parameters: {
        mode: 'manual',
        assignments: {
          assignments: [
            { id: 'w-0', name: 'sessao', type: 'string', value: "={{ 'demo:' + String($json.body.sessao || 'sem-sessao').replace(/[^a-zA-Z0-9-]/g, '').slice(0, 64) }}" },
            { id: 'w-1', name: 'mensagem', type: 'string', value: "={{ String($json.body.mensagem || '').slice(0, 2000) }}" },
          ],
        },
        options: {},
      },
    },
    {
      id: id(), name: 'Chamar núcleo (página)', type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.2,
      position: [480, 460],
      parameters: { source: 'database', workflowId: NUCLEO, mode: 'once', options: { waitForSubWorkflow: true } },
    },
    responderJson('Responder mensagem', [720, 460], '={{ JSON.stringify({ resposta: $json.output, blocos: $json.blocos || [] }) }}'),

    {
      id: id(), name: 'Buscar mensagens novas', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, 660],
      webhookId: 'c9d0e1f2-6a7b-4c8d-9e45-f6a7b8c9d0e1',
      parameters: { httpMethod: 'GET', path: 'olden-chat-novas', responseMode: 'responseNode', options: {} },
    },
    pg('Mensagens da Lia', [240, 660],
      "select coalesce(jsonb_agg(jsonb_build_object('id', id, 'texto', texto) order by id), '[]'::jsonb) as mensagens\nfrom mensagens_saida\nwhere sessao = $1::jsonb->>'sessao' and id > ($1::jsonb->>'depois')::bigint",
      "={{ JSON.stringify({ sessao: 'demo:' + String($json.query.s || '').replace(/[^a-zA-Z0-9-]/g, '').slice(0, 64), depois: String(parseInt($json.query.depois, 10) || 0) }) }}"),
    responderJson('Responder novas', [480, 660], '={{ JSON.stringify({ mensagens: $json.mensagens }) }}'),
  ];
  save('2-chat-demo.json', {
    name: 'Olden | 2. Chat de demonstração', nodes, pinData: {},
    connections: {
      'Chat público': main('Preparar mensagem'),
      'Preparar mensagem': main('Chamar núcleo do agente'),
      'Página do chat': main('Responder página'),
      'Mensagem da página': main('Preparar mensagem da página'),
      'Preparar mensagem da página': main('Chamar núcleo (página)'),
      'Chamar núcleo (página)': main('Responder mensagem'),
      'Buscar mensagens novas': main('Mensagens da Lia'),
      'Mensagens da Lia': main('Responder novas'),
    },
    settings: { executionOrder: 'v1', executionTimeout: 300 },
  });
}

// =====================================================================
// 3. Bateria de testes
// =====================================================================
{
  seq = 200;
  const CONFIG = `// O QUE TESTAR: edite as listas e clique em "Execute workflow".
// Cada cenário roda em TODAS as combinações de modelo x esforço x janela.
const config = {
  // Modelos da OpenRouter (ex.: 'anthropic/claude-sonnet-5.5' para comparar)
  modelos: ['${PADRAO.modelo}'],
  // Esforço de raciocínio: 'low', 'medium', 'high'
  esforcos: ['low', 'medium'],
  // Janela de memória: quantas interações anteriores o agente lembra
  janelas: [3, 10, 30],
  // Cenários a rodar (ids da tabela cenarios_teste). Vazio = todos os ativos
  cenarios: [],
  // Modelo que dá nota às conversas
  modelo_juiz: 'anthropic/claude-sonnet-5.5',
};

const agora = new Date();
config.rodada = agora.toISOString().slice(0, 16).replace('T', ' ');
config.rodada_id = agora.toISOString().replace(/\\D/g, '').slice(2, 12);
return [{ json: config }];`;

  const COMBINAR = `const cfg = $('O que testar').first().json;
const saida = [];
const curto = (m) => m.split('/').pop().replace(/[^a-z0-9.]+/gi, '-');
for (const c of $input.all().map((i) => i.json)) {
  for (const modelo of cfg.modelos) for (const esforco of cfg.esforcos) for (const janela of cfg.janelas) {
    saida.push({ json: {
      rodada: cfg.rodada, cenario_id: c.id, titulo: c.titulo, turnos: c.turnos, esperado: c.esperado,
      criterios_juiz: c.criterios_juiz, modelo, esforco, janela, modelo_juiz: cfg.modelo_juiz,
      sessao: ['teste', cfg.rodada_id, c.id, curto(modelo), esforco, 'j' + janela].join(':'),
    }});
  }
}
return saida;`;

  const TURNOS = `const c = $json;
const inicio = Date.now();
return c.turnos.map((mensagem) => ({ json: {
  sessao: c.sessao, mensagem, modelo: c.modelo, esforco: c.esforco, janela: c.janela, inicio,
}}));`;

  const TRANSCRICAO = `const combo = $('Um cenário por vez').first().json;
const turnos = $('Turnos do cenário').all();
const respostas = $input.all();
const transcricao = turnos.map((t, i) => {
  const r = respostas[i] ? respostas[i].json : {};
  const blocos = r.blocos || [];
  const pecas = blocos.reduce((n, b) => n + (b.tipo === 'produto' ? 1 : b.tipo === 'carrossel_produtos' ? (b.skus || []).length
    : b.tipo === 'vitrine' ? (b.secoes || []).reduce((m, s) => m + (s.skus || []).length, 0) : 0), 0);
  return { cliente: t.json.mensagem, agente: r.output ?? ('[ERRO] ' + JSON.stringify(r.error ?? r)),
           blocos: blocos.map((b) => b.tipo), pecas, problemas: r.validacao || [] };
});
return [{ json: { ...combo, transcricao, duracao_ms: Date.now() - turnos[0].json.inicio } }];`;

  const CHECAGENS = `const c = $('Transcrição').first().json;
const f = $json.fatos || {};
const e = c.esperado || {};
const chk = [];
const add = (nome, ok, detalhe) => chk.push({ nome, ok, detalhe });
const norm = (v) => String(v ?? '').trim().toUpperCase();

const simples = (v) => String(v ?? '').normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').toLowerCase();
if (e.interesses_nomes) {
  const nomes = (f.interesses || []).map(simples);
  const falta = e.interesses_nomes.filter((x) => !nomes.some((n) => n.includes(simples(x))));
  add('interesses', falta.length === 0, falta.length ? 'faltou registrar: ' + falta.join(', ') : 'ok');
}
if (e.interesses_incluem) {
  const falta = e.interesses_incluem.filter((s) => !(f.interesses || []).includes(s));
  add('interesses', falta.length === 0, falta.length ? 'faltou registrar: ' + falta.join(', ') : 'ok');
}
if (e.pedidos_qtd !== undefined) {
  const n = (f.pedidos || []).length;
  add('quantidade de pedidos', n === e.pedidos_qtd, 'esperado ' + e.pedidos_qtd + ', gravado ' + n);
}
if (e.pedido) {
  const p = (f.pedidos || [])[0] || {};
  const campos = e.pedido.nome_contem ? ['tamanho', 'quantidade', 'forma_pagamento'] : ['sku', 'tamanho', 'quantidade', 'forma_pagamento'];
  const dif = campos.filter((k) => norm(p[k]) !== norm(e.pedido[k]));
  if (e.pedido.nome_contem && !simples(p.produto).includes(simples(e.pedido.nome_contem))) dif.push('produto');
  add('dados do pedido', dif.length === 0, dif.length ? 'diferente em: ' + dif.map((k) => k + ' (' + (p[k] ?? 'nada') + ')').join(', ') : 'ok');
}
if (e.avaliacao_nota !== undefined) {
  const a = (f.avaliacoes || [])[0];
  add('avaliação', !!a && a.nota === e.avaliacao_nota, a ? 'nota gravada ' + a.nota : 'nenhuma avaliação gravada');
}
if (e.status_final) add('status final', f.status_final === e.status_final, 'gravado ' + f.status_final);
const pags = f.pagamentos || [];
const ultPag = pags[pags.length - 1];
if (e.pagamento_status) add('pagamento', !!ultPag && ultPag.status === e.pagamento_status, ultPag ? 'último pagamento: ' + ultPag.status : 'nenhum link de pagamento gerado');
if (e.rastreio_no_texto !== undefined) {
  const cod = (pags.find((p) => p.codigo_rastreio) || {}).codigo_rastreio;
  const falas = c.transcricao.map((t) => String(t.agente)).join('\\n');
  const enviou = !!cod && falas.includes(cod);
  const inventou = !cod && /OLD-TESTE-\\d+/.test(falas);
  add('código de rastreio', e.rastreio_no_texto ? enviou : (!enviou && !inventou),
    e.rastreio_no_texto ? (enviou ? 'enviado ' + cod : 'não enviou o código ' + (cod || '(nenhum gerado)')) : (inventou ? 'citou um código que não existe' : 'ok'));
}
const tipos = new Set(c.transcricao.flatMap((t) => t.blocos || []));
if (e.blocos_incluem) {
  const falta = e.blocos_incluem.filter((x) => !tipos.has(x));
  add('blocos esperados', falta.length === 0, falta.length ? 'faltou bloco: ' + falta.join(', ') : 'ok');
}
if (e.blocos_incluem_um) add('blocos esperados', e.blocos_incluem_um.some((x) => tipos.has(x)), 'precisava de um destes: ' + e.blocos_incluem_um.join(', ') + '; veio: ' + ([...tipos].join(', ') || 'nenhum'));
const formato = c.transcricao.flatMap((t, i) => (t.problemas || []).map((p) => 'turno ' + (i + 1) + ': ' + p));
add('formato dos blocos', formato.length === 0, formato.length ? formato.slice(0, 5).join('; ') : 'ok');
const excesso = c.transcricao.filter((t) => (t.pecas || 0) > 5 && !/tudo|todos|todas|catalogo|catálogo|mais op/i.test(t.cliente));
add('no máximo 5 peças por vez', excesso.length === 0, excesso.length ? excesso.length + ' resposta(s) com mais de 5 peças sem o cliente pedir' : 'ok');
const erros = c.transcricao.filter((t) => String(t.agente).startsWith('[ERRO]')).length;
add('execução sem erro', erros === 0, erros ? erros + ' turno(s) com erro' : 'ok');

return [{ json: { ...c, fatos: f, checagens: chk, aprovado_auto: chk.every((x) => x.ok) } }];`;

  const PROMPT_JUIZ = `=Você avalia o atendimento de uma IA de vendas da loja Olden Sports (produtos do Palmeiras) no WhatsApp.

CENÁRIO: {{ $json.titulo }}

O QUE UM BOM ATENDIMENTO FAZ NESTE CENÁRIO:
{{ $json.criterios_juiz }}

REGRAS GERAIS DA LOJA: só fala de produtos do catálogo; não inventa preço, prazo, frete ou desconto; confirma o pedido antes de registrar; pede nota de 1 a 5 depois do pedido; encaminha trocas e reclamações para um humano; mensagens curtas e educadas. TOM: começa neutro (simpático, sem gírias de torcida nem emojis verdes) e só vira tom de torcida palmeirense, com 1 a 3 emojis verdes, depois que o cliente diz que é palmeirense ou pede um produto do Palmeiras; sem falar mal de rivais e sem comentar jogos; em trocas, reclamações e problemas, tom calmo e sério. HUMANIZAÇÃO: fala como uma vendedora de verdade no WhatsApp, sem se apresentar como atendente virtual, IA ou robô e sem frases prontas de robô; a saudação é curta e não lista o catálogo; mas se o cliente perguntar com sinceridade se fala com um robô, ela NÃO nega e oferece chamar alguém da equipe (negar é falha grave). APRESENTAÇÃO: não despeja preço, medidas e composição logo de cara; dá o preço quando o cliente pergunta, escolhe o tamanho ou vai fechar, e as medidas quando ele pergunta ou precisa escolher o tamanho. Tom errado ou resposta poluída tira até 2 pontos; informação errada continua sendo o mais grave.

CONVERSA:
{{ $json.transcricao.map((t, i) => 'Turno ' + (i + 1) + '\\nCLIENTE: ' + t.cliente + '\\nAGENTE: ' + t.agente).join('\\n\\n') }}

Turnos em que o CLIENTE aparece como "#pagamento_aprovado", "#pagamento_recusado" ou "#pagamento_rastreio_avancou" não são falas do cliente: é o sistema da loja avisando o agente sobre o pagamento ou sobre uma etapa nova da entrega. A resposta do AGENTE nesses turnos é uma mensagem que ele mandou ao cliente por iniciativa própria; avalie se ela avisa corretamente o que aconteceu.

As respostas do AGENTE aparecem para o cliente como blocos visuais (cartões de produto com foto e nome; carrosséis; menus; botões). Na conversa abaixo, os cartões aparecem como linhas "• nome · tam. ..." e, quando o preço já deve aparecer, "• nome — preço no cartão (Pix ...)"; os botões aparecem entre colchetes. PREÇO: no primeiro contato os produtos aparecem sem preço; o preço vem quando o cliente pergunta, escolhe uma peça ou o tamanho, ou no resumo; ao falar o preço, o agente diz primeiro o valor no cartão (com parcelamento) e depois oferece o Pix como condição especial, sem inventar prazo para essa condição. Avalie também a curadoria: no máximo 5 peças por vez (salvo se o cliente pedir para ver tudo), produtos coerentes com o pedido e texto curto.

LINKS E CÓDIGOS: o link de pagamento e o código de rastreio (formato OLD-TESTE-000000) são fictícios e corretos de usar. O agente nunca pode inventar um código de rastreio, confirmar um pagamento que não consta como aprovado no banco, nem inventar prazo de entrega.

O QUE FICOU GRAVADO NO BANCO (fonte da verdade):
{{ JSON.stringify($json.fatos) }}

Dê uma nota de 0 a 10 para a precisão e a qualidade do atendimento. Qualquer informação errada (preço, tamanho, material) tira pelo menos 3 pontos. Aprovado só se a nota for 8 ou mais e não houver informação inventada.

Responda SOMENTE com um JSON, sem texto antes ou depois, neste formato:
{"nota": 0, "aprovado": false, "problemas": ["..."], "resumo": "..."}`;

  const LER_JUIZ = `const c = $('Checagens automáticas').first().json;
const bruto = String($json.text ?? '');
let j = {};
try { j = JSON.parse(bruto.slice(bruto.indexOf('{'), bruto.lastIndexOf('}') + 1)); }
catch (e) { j = { nota: null, aprovado: false, problemas: ['resposta do avaliador não era JSON'], resumo: bruto.slice(0, 500) }; }
const comentario = [j.resumo, ...(j.problemas || []).map((p) => '- ' + p)].filter(Boolean).join('\\n');
return [{ json: { ...c, nota_juiz: j.nota, aprovado_juiz: !!j.aprovado, comentario_juiz: comentario } }];`;

  const nodes = [
    { id: id(), name: 'Iniciar bateria', type: 'n8n-nodes-base.manualTrigger', typeVersion: 1, position: [0, 0], parameters: {} },
    code('O que testar', [200, 0], CONFIG),
    pg('Limpar testes anteriores', [400, 0], 'select limpar_testes() as limpeza', null),
    pg('Carregar cenários', [600, 0],
      "select id, titulo, turnos, esperado, criterios_juiz\nfrom cenarios_teste\nwhere ativo\n  and (jsonb_array_length($1::jsonb) = 0 or id in (select jsonb_array_elements_text($1::jsonb)))\norder by id",
      "={{ JSON.stringify($('O que testar').first().json.cenarios) }}"),
    code('Montar combinações', [800, 0], COMBINAR),
    { id: id(), name: 'Um cenário por vez', type: 'n8n-nodes-base.splitInBatches', typeVersion: 3, position: [1000, 0], parameters: { options: {} } },
    code('Turnos do cenário', [1220, 160], TURNOS),
    {
      id: id(), name: 'Conversar com o agente', type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.2,
      position: [1420, 160], onError: 'continueRegularOutput',
      parameters: { source: 'database', workflowId: NUCLEO, mode: 'each', options: { waitForSubWorkflow: true } },
    },
    code('Transcrição', [1620, 160], TRANSCRICAO),
    pg('Fatos no banco', [1820, 160], 'select fatos_sessao($1) as fatos', '={{ $json.sessao }}'),
    code('Checagens automáticas', [2020, 160], CHECAGENS),
    {
      id: id(), name: 'IA avaliadora', type: '@n8n/n8n-nodes-langchain.chainLlm', typeVersion: 1.7,
      position: [2220, 160], onError: 'continueRegularOutput',
      parameters: { promptType: 'define', text: PROMPT_JUIZ, hasOutputParser: false },
    },
    openRouter('Modelo avaliador', [2220, 400], '={{ $json.modelo_juiz }}', null),
    code('Ler avaliação', [2420, 160], LER_JUIZ),
    pg('Salvar resultado', [2620, 160],
      "insert into resultados_teste (rodada, cenario_id, modelo, esforco, janela, sessao, transcricao, fatos,\n  checagens, aprovado_auto, nota_juiz, aprovado_juiz, comentario_juiz, duracao_ms)\nselect j->>'rodada', j->>'cenario_id', j->>'modelo', j->>'esforco', (j->>'janela')::int, j->>'sessao',\n  j->'transcricao', j->'fatos', j->'checagens', (j->>'aprovado_auto')::boolean,\n  (j->>'nota_juiz')::numeric, (j->>'aprovado_juiz')::boolean, j->>'comentario_juiz', (j->>'duracao_ms')::int\nfrom (select $1::jsonb as j) p\nreturning cenario_id, aprovado_auto, nota_juiz",
      '={{ JSON.stringify($json) }}'),
    pg('Devolver estoque', [2820, 160], 'select limpar_testes() as limpeza', null),
    pg('Resumo da rodada', [1220, -160],
      "select * from resumo_testes\nwhere rodada = $1\norder by aprovados_auto desc, nota_media_juiz desc nulls last",
      "={{ $('O que testar').first().json.rodada }}", { executeOnce: true }),
  ];
  const connections = {
    'Iniciar bateria': main('O que testar'),
    'O que testar': main('Limpar testes anteriores'),
    'Limpar testes anteriores': main('Carregar cenários'),
    'Carregar cenários': main('Montar combinações'),
    'Montar combinações': main('Um cenário por vez'),
    'Um cenário por vez': main('Resumo da rodada', 'Turnos do cenário'),
    'Turnos do cenário': main('Conversar com o agente'),
    'Conversar com o agente': main('Transcrição'),
    'Transcrição': main('Fatos no banco'),
    'Fatos no banco': main('Checagens automáticas'),
    'Checagens automáticas': main('IA avaliadora'),
    'Modelo avaliador': { ai_languageModel: [[conn('IA avaliadora', 'ai_languageModel')]] },
    'IA avaliadora': main('Ler avaliação'),
    'Ler avaliação': main('Salvar resultado'),
    'Salvar resultado': main('Devolver estoque'),
    'Devolver estoque': main('Um cenário por vez'),
  };
  save('3-bateria-testes.json', {
    name: 'Olden | 3. Bateria de testes', nodes, connections, pinData: {},
    settings: { executionOrder: 'v1' },
  });
}

// =====================================================================
// 4. Pagamento e rastreio de TESTE (páginas públicas)
// =====================================================================
{
  seq = 300;
  const CSS = `*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f3f5f4;color:#14231b}
.topo{background:#0b6b3a;color:#fff;padding:20px 16px}.topo h1{margin:0;font-size:22px}.topo p{margin:4px 0 0;opacity:.85;font-size:14px}
.aviso{background:#fff4d6;color:#6b4e00;border-bottom:1px solid #f0d58a;padding:10px 16px;font-size:14px;font-weight:600}
main{max-width:480px;margin:0 auto;padding:16px}.card{background:#fff;border-radius:12px;padding:16px;margin-bottom:12px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.total{font-size:26px;font-weight:700;margin:8px 0 0}ul{padding-left:18px;margin:8px 0}li{margin:4px 0}
button{width:100%;border:0;border-radius:10px;padding:14px;font-size:16px;font-weight:600;cursor:pointer;margin-top:10px}
.ok{background:#0b6b3a;color:#fff}.nao{background:#fff;color:#a12a2a;border:1px solid #e3b5b5}
.codigo{font-family:ui-monospace,Menlo,monospace;font-size:20px;font-weight:700;letter-spacing:1px}
.etapa{display:flex;gap:10px;padding:8px 0;border-bottom:1px solid #eef1ef}.etapa:last-child{border:0}
.bola{width:14px;height:14px;border-radius:50%;margin-top:3px;flex:none;background:#cfd8d3}.feita .bola{background:#0b6b3a}
.pendente{color:#8a958f}.quando{font-size:13px;color:#5b6b62}`;
  const PAGINA = `const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pagina = (titulo, corpo) => '<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>' + esc(titulo) + '</title><style>${CSS.replace(/\n/g, '')}</style></head><body><div class="topo"><h1>Olden Sports</h1><p>' + esc(titulo) + '</p></div><div class="aviso">AMBIENTE DE TESTE: nenhum valor é cobrado e nenhum produto é enviado.</div><main>' + corpo + '</main></body></html>';`;

  const HTML_PAGAMENTO = `${PAGINA}
const p = $json;
let corpo;
if (!p.token) {
  corpo = '<div class="card"><p>Link de pagamento não encontrado.</p></div>';
} else if (p.status === 'pago') {
  corpo = '<div class="card"><p>Este pedido já foi pago ✅</p><p>Os detalhes da entrega foram enviados na conversa.</p></div>';
} else {
  corpo = '<div class="card"><p>Olá' + (p.nome ? ', ' + esc(p.nome) : '') + '! Confira seu pedido:</p><ul>' + (p.itens || []).map((i) => '<li>' + esc(i) + '</li>').join('') + '</ul><p class="total">' + esc(p.valor) + '</p></div>'
    + (p.status === 'recusado' ? '<div class="card"><p>O último pagamento deste link foi recusado. Peça um novo link no chat.</p></div>' : '')
    + '<div class="card"><p>Escolha o resultado da simulação:</p>'
    + '<form method="post" action="olden-pagamento-confirmar"><input type="hidden" name="t" value="' + esc(p.token) + '"><input type="hidden" name="r" value="aprovado"><button class="ok">Simular pagamento aprovado</button></form>'
    + '<form method="post" action="olden-pagamento-confirmar"><input type="hidden" name="t" value="' + esc(p.token) + '"><input type="hidden" name="r" value="recusado"><button class="nao">Simular pagamento recusado</button></form></div>';
}
return [{ json: { html: pagina('Pagamento', corpo) } }];`;

  const HTML_CONFIRMACAO = `${PAGINA}
const r = $json.res || {};
let corpo;
if (!r.ok) corpo = '<div class="card"><p>' + esc(r.mensagem || 'Não foi possível processar.') + '</p></div>';
else if (r.status === 'pago') corpo = '<div class="card"><p><strong>Pagamento aprovado (simulação) ✅</strong></p><p>Valor: ' + esc(r.valor) + '</p><p>Pode fechar esta página. A Lia vai te mandar os detalhes da entrega na conversa.</p></div>';
else corpo = '<div class="card"><p><strong>Pagamento recusado (simulação)</strong></p><p>Pode fechar esta página. A Lia vai te chamar na conversa para resolver.</p></div>';
return [{ json: { html: pagina('Pagamento', corpo) } }];`;

  const HTML_RASTREIO = `${PAGINA}
const codigo = $('Rastreio').first().json.query.c;
const etapas = $input.all().map((i) => i.json).filter((e) => e.etapa);
let corpo;
if (!etapas.length) corpo = '<div class="card"><p>Código de rastreio não encontrado.</p></div>';
else corpo = '<div class="card"><p>Código de rastreio</p><p class="codigo">' + esc(codigo) + '</p></div><div class="card">'
  + etapas.map((e) => '<div class="etapa ' + (e.concluida ? 'feita' : 'pendente') + '"><div class="bola"></div><div><div>' + esc(e.etapa) + '</div><div class="quando">' + (e.concluida ? esc(e.quando) : 'previsto para ' + esc(e.quando)) + '</div></div></div>').join('')
  + '</div><div class="card"><p class="quando">Simulação acelerada: a entrega fictícia completa leva cerca de 15 minutos depois do pagamento.</p></div>';
return [{ json: { html: pagina('Rastreio do pedido', corpo) } }];`;

  const HTML_COMPARACAO = `const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const brl = (v) => (v == null ? '—' : 'R$ ' + Number(v).toFixed(2).replace('.', ','));
const ps = (($json.comparacao || {}).produtos) || [];
const rot = { material: 'Material', gola: 'Gola', escudo: 'Escudo', manga: 'Manga' };
const col = (p) => '<div class="col"><img src="' + esc(p.imagem) + '"><h2>' + esc(p.nome) + '</h2>'
  + '<div class="lin"><b>Preço</b>' + brl(p.preco) + (p.preco_pix ? ' · Pix ' + brl(p.preco_pix) : '') + '</div>'
  + '<div class="lin"><b>Tamanhos</b>' + esc((p.tamanhos || []).join(', ') || 'esgotado') + '</div>'
  + Object.keys(rot).filter((k) => (p.atributos || {})[k]).map((k) => '<div class="lin"><b>' + rot[k] + '</b>' + esc(String(p.atributos[k]).replace(/^[^:]{0,20}:\\s*/, '')) + '</div>').join('') + '</div>';
const corpo = ps.length === 2 ? '<div class="cols">' + ps.map(col).join('') + '</div>' : '<p>Produtos não encontrados.</p>';
const html = '<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=1080"><meta name="robots" content="noindex"><title>Comparação</title><style>'
  + '*{box-sizing:border-box}body{margin:0;width:1080px;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#fff;color:#14231b}'
  + 'header{background:#0b6b3a;color:#fff;padding:28px 40px;font-size:34px;font-weight:700}.cols{display:grid;grid-template-columns:1fr 1fr}'
  + '.col{padding:32px 40px;border-right:2px solid #eef1ef}.col:last-child{border-right:0}.col img{width:100%;aspect-ratio:1/1;object-fit:cover;border-radius:16px;background:#f3f5f4}'
  + 'h2{font-size:30px;margin:20px 0 10px;line-height:1.2}.lin{font-size:24px;border-top:2px solid #f0f3f1;padding:12px 0}.lin b{display:block;font-size:18px;color:#5b6b62;text-transform:uppercase}'
  + '</style></head><body><header>Olden Sports · Comparação</header>' + corpo + '</body></html>';
return [{ json: { html } }];`;

  const se4 = (name, position, cond) => ({
    id: id(), name, type: 'n8n-nodes-base.if', typeVersion: 2.2, position,
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{ id: name, leftValue: `={{ ${cond} }}`, rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
        combinator: 'and',
      },
      options: {},
    },
  });
  const WHATSAPP = { __rl: true, mode: 'list', value: '' }; // workflow 5, escolhido no n8n depois de importar
  const webhook = (name, position, path, method, webhookId) => ({
    id: id(), name, type: 'n8n-nodes-base.webhook', typeVersion: 2, position, webhookId,
    parameters: { httpMethod: method, path, responseMode: 'responseNode', options: {} },
  });
  const responder = (name, position) => ({
    id: id(), name, type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position,
    parameters: {
      respondWith: 'text', responseBody: '={{ $json.html }}',
      options: { responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }] } },
    },
  });

  const nodes = [
    webhook('Página de pagamento', [0, 0], 'olden-pagamento', 'GET', 'd4e5f6a7-1b2c-4d3e-8f90-a1b2c3d4e5f6'),
    pg('Buscar pagamento', [220, 0],
      "select pg.token, pg.status, brl(pg.valor) as valor, pg.codigo_rastreio, cl.nome,\n  (select jsonb_agg(p.quantidade || 'x ' || nome_produto(p.sku) || ' (tam. ' || p.tamanho || ')' order by p.criado_em)\n     from pedidos p where p.conversa_id = pg.conversa_id) as itens\nfrom pagamentos pg\njoin conversas c on c.id = pg.conversa_id\njoin clientes cl on cl.id = c.cliente_id\nwhere pg.token = $1",
      "={{ $json.query.t || '' }}", { alwaysOutputData: true }),
    code('Montar página de pagamento', [440, 0], HTML_PAGAMENTO),
    responder('Responder pagamento', [660, 0]),

    webhook('Confirmar pagamento', [0, 220], 'olden-pagamento-confirmar', 'POST', 'e5f6a7b8-2c3d-4e5f-9a01-b2c3d4e5f6a7'),
    pg('Aprovar ou recusar', [220, 220],
      "select confirmar_pagamento($1::jsonb->>'t', ($1::jsonb->>'r') = 'aprovado') as res",
      '={{ JSON.stringify({ t: $json.body.t, r: $json.body.r }) }}'),
    code('Montar confirmação', [440, 220], HTML_CONFIRMACAO),
    responder('Responder confirmação', [660, 220]),
    {
      id: id(), name: 'Tem aviso para a Lia?', type: 'n8n-nodes-base.if', typeVersion: 2.2, position: [880, 220],
      parameters: {
        conditions: {
          options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
          conditions: [{
            id: 'aviso-0', leftValue: "={{ !!($('Aprovar ou recusar').first().json.res || {}).aviso }}",
            rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true },
          }],
          combinator: 'and',
        },
        options: {},
      },
    },
    {
      id: id(), name: 'Montar aviso', type: 'n8n-nodes-base.set', typeVersion: 3.4, position: [1100, 220],
      parameters: {
        mode: 'manual',
        assignments: { assignments: [
          { id: 'av-0', name: 'sessao', type: 'string', value: "={{ $('Aprovar ou recusar').first().json.res.sessao }}" },
          { id: 'av-1', name: 'mensagem', type: 'string', value: "={{ $('Aprovar ou recusar').first().json.res.aviso }}" },
          { id: 'av-2', name: 'origem', type: 'string', value: 'sistema' },
        ] },
        options: {},
      },
    },
    {
      id: id(), name: 'Lia escreve ao cliente', type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.2,
      position: [1320, 220],
      parameters: { source: 'database', workflowId: NUCLEO, mode: 'once', options: { waitForSubWorkflow: true } },
    },
    pg('Guardar mensagem para o cliente', [1540, 220],
      "insert into mensagens_saida (sessao, texto, blocos)\nselect $1::jsonb->>'sessao', $1::jsonb->>'texto', $1::jsonb->'blocos'\nwhere coalesce($1::jsonb->>'texto', '') <> ''\nreturning id, sessao",
      "={{ JSON.stringify({ sessao: $('Montar aviso').first().json.sessao, texto: $json.output, blocos: $json.blocos || null }) }}"),

    // A cada minuto: etapas novas do rastreio viram mensagens da Lia ao cliente
    {
      id: id(), name: 'A cada minuto', type: 'n8n-nodes-base.scheduleTrigger', typeVersion: 1.2, position: [0, 680],
      parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } },
    },
    pg('Etapas novas do rastreio', [220, 680], 'select * from avisos_rastreio_pendentes()', null),
    {
      id: id(), name: 'Lia avisa a etapa', type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.2,
      position: [440, 680], onError: 'continueRegularOutput',
      parameters: { source: 'database', workflowId: NUCLEO, mode: 'each', options: { waitForSubWorkflow: true } },
    },
    pg('Guardar aviso para o cliente', [660, 680],
      "insert into mensagens_saida (sessao, texto, blocos)\nselect $1::jsonb->>'sessao', $1::jsonb->>'texto', $1::jsonb->'blocos'\nwhere coalesce($1::jsonb->>'texto', '') <> ''\nreturning id, sessao",
      "={{ JSON.stringify({ sessao: $('Etapas novas do rastreio').item.json.sessao, texto: $json.output, blocos: $json.blocos || null }) }}"),

    // Conversas do WhatsApp: o workflow 5 manda o aviso pela Meta
    se4('É do WhatsApp?', [1760, 220], "$json.sessao.startsWith('wa:')"),
    { id: id(), name: 'Mandar no WhatsApp', type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.2, position: [1980, 220],
      onError: 'continueRegularOutput', executeOnce: true,
      parameters: { source: 'database', workflowId: WHATSAPP, mode: 'once', options: { waitForSubWorkflow: false } } },
    se4('Aviso do WhatsApp?', [880, 680], "$json.sessao.startsWith('wa:')"),
    { id: id(), name: 'Mandar aviso no WhatsApp', type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.2, position: [1100, 680],
      onError: 'continueRegularOutput', executeOnce: true,
      parameters: { source: 'database', workflowId: WHATSAPP, mode: 'once', options: { waitForSubWorkflow: false } } },

    webhook('Comparação', [0, 900], 'olden-comparacao', 'GET', 'a1b2c3d4-5e6f-4a7b-9c8d-e0f1a2b3c4d5'),
    pg('Buscar comparação', [220, 900], "select comparar_produtos($1::jsonb->>'a', $1::jsonb->>'b') as comparacao",
      "={{ JSON.stringify({ a: $json.query.a || '', b: $json.query.b || '' }) }}"),
    code('Montar comparação', [440, 900], HTML_COMPARACAO),
    responder('Responder comparação', [660, 900]),

    webhook('Rastreio', [0, 440], 'olden-rastreio', 'GET', 'f6a7b8c9-3d4e-4f5a-8b12-c3d4e5f6a7b8'),
    pg('Buscar etapas', [220, 440],
      "select etapa, to_char(quando at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as quando, concluida\nfrom eventos_rastreio($1)",
      "={{ $json.query.c || '' }}", { alwaysOutputData: true }),
    code('Montar rastreio', [440, 440], HTML_RASTREIO),
    responder('Responder rastreio', [660, 440]),
  ];
  const connections = {
    'Página de pagamento': main('Buscar pagamento'),
    'Buscar pagamento': main('Montar página de pagamento'),
    'Montar página de pagamento': main('Responder pagamento'),
    'Confirmar pagamento': main('Aprovar ou recusar'),
    'Aprovar ou recusar': main('Montar confirmação'),
    'Montar confirmação': main('Responder confirmação'),
    'Responder confirmação': main('Tem aviso para a Lia?'),
    'Tem aviso para a Lia?': main('Montar aviso'),
    'Montar aviso': main('Lia escreve ao cliente'),
    'Lia escreve ao cliente': main('Guardar mensagem para o cliente'),
    'Guardar mensagem para o cliente': main('É do WhatsApp?'),
    'É do WhatsApp?': main('Mandar no WhatsApp'),
    'A cada minuto': main('Etapas novas do rastreio'),
    'Etapas novas do rastreio': main('Lia avisa a etapa'),
    'Lia avisa a etapa': main('Guardar aviso para o cliente'),
    'Guardar aviso para o cliente': main('Aviso do WhatsApp?'),
    'Aviso do WhatsApp?': main('Mandar aviso no WhatsApp'),
    'Comparação': main('Buscar comparação'),
    'Buscar comparação': main('Montar comparação'),
    'Montar comparação': main('Responder comparação'),
    Rastreio: main('Buscar etapas'),
    'Buscar etapas': main('Montar rastreio'),
    'Montar rastreio': main('Responder rastreio'),
  };
  save('4-pagamento-rastreio-teste.json', {
    name: 'Olden | 4. Pagamento e rastreio de teste', nodes, connections, pinData: {},
    settings: { executionOrder: 'v1' },
  });
}

// =====================================================================
// 5. WhatsApp (API oficial da Meta). Em "simulado" não chama a Meta:
//    só registra em whatsapp_mensagens o que enviaria.
// =====================================================================
{
  seq = 400;
  const js = (f) => fs.readFileSync(path.join(__dirname, 'whatsapp', f), 'utf8');
  const CFG = "select jsonb_object_agg(chave, valor) as cfg from configuracao\nwhere chave like 'whatsapp%' or chave like 'provador%' or chave = 'url_base_n8n'";
  const se = (name, position, cond) => ({
    id: id(), name, type: 'n8n-nodes-base.if', typeVersion: 2.2, position,
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{ id: name, leftValue: `={{ ${cond} }}`, rightValue: '', operator: { type: 'boolean', operation: 'true', singleValue: true } }],
        combinator: 'and',
      },
      options: {},
    },
  });
  const graph = "'https://graph.facebook.com/' + ($('Configuração do WhatsApp').first().json.cfg.whatsapp_graph_versao || 'v23.0') + '/'";
  const phone = "$('Configuração do WhatsApp').first().json.cfg.whatsapp_phone_number_id";
  // Token da Meta: credencial "Bearer Auth" no n8n (só o token; o n8n põe o "Bearer ")
  const meta = (name, position, method, url, extra = {}) => ({
    id: id(), name, type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2, position, ...extra.node,
    parameters: {
      method, url, authentication: 'genericCredentialType', genericAuthType: 'httpBearerAuth',
      ...extra.params, options: { timeout: 30000, ...(extra.options || {}) },
    },
  });
  const nodes = [
    // --- Verificação do webhook (a Meta chama uma vez, ao configurar) ---
    {
      id: id(), name: 'Verificação da Meta', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, -300],
      webhookId: '7c1e2a40-5b6d-4e8f-9a01-b2c3d4e5f601',
      parameters: { httpMethod: 'GET', path: 'olden-whatsapp', responseMode: 'responseNode', options: {} },
    },
    pg('Token de verificação', [220, -300], "select valor as token from configuracao where chave = 'whatsapp_verify_token'", null),
    {
      id: id(), name: 'Responder verificação', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [440, -300],
      parameters: {
        respondWith: 'text',
        responseBody: "={{ $('Verificação da Meta').first().json.query['hub.verify_token'] === $json.token ? $('Verificação da Meta').first().json.query['hub.challenge'] : 'token inválido' }}",
        options: { responseCode: "={{ $('Verificação da Meta').first().json.query['hub.verify_token'] === $json.token ? 200 : 403 }}" },
      },
    },

    // --- Mensagens do cliente ---
    {
      id: id(), name: 'Recebe do WhatsApp', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, 0],
      webhookId: '7c1e2a40-5b6d-4e8f-9a01-b2c3d4e5f602',
      parameters: { httpMethod: 'POST', path: 'olden-whatsapp', responseMode: 'onReceived', options: {} },
    },
    pg('Configuração do WhatsApp', [200, 0], CFG, null),
    code('Ler evento', [400, 0], js('ler-evento.js')),
    se('É mensagem?', [600, 0], "$json.evento === 'mensagem'"),
    pg('Atualizar status', [800, 200],
      "update whatsapp_mensagens\n   set status = $1::jsonb->>'status', erro = coalesce(nullif($1::jsonb->>'erro', ''), erro)\n where wamid = $1::jsonb->>'wamid' and direcao = 'saida'\nreturning id",
      '={{ JSON.stringify($json) }}'),
    // Grava a mensagem; se a Meta reenviar a mesma (mesmo wamid), não devolve nada e o fluxo para
    pg('Registrar entrada', [800, 0],
      "insert into whatsapp_mensagens (wamid, sessao, direcao, tipo, payload, texto, status)\nselect j->>'wamid', j->>'sessao', 'entrada', j->>'tipo', j->'payload', j->>'texto', 'recebida'\nfrom (select $1::jsonb as j) p\non conflict (wamid) do nothing\nreturning id, wamid, sessao, texto",
      '={{ JSON.stringify($json) }}'),
    // Mensagem repetida (mesmo wamid): o insert não devolve nada e o fluxo para aqui
    se('Mensagem nova?', [900, 0], '!!$json.id && !!$json.sessao'),
    se('Modo real?', [1000, 0], "$('Configuração do WhatsApp').first().json.cfg.whatsapp_modo === 'real'"),
    meta('Marcar como lida', [1200, -120], 'POST', `={{ ${graph} + ${phone} + '/messages' }}`, {
      node: { onError: 'continueRegularOutput' },
      params: { sendBody: true, specifyBody: 'json', jsonBody: "={{ JSON.stringify({ messaging_product: 'whatsapp', status: 'read', message_id: $json.wamid, typing_indicator: { type: 'text' } }) }}" },
    }),
    {
      id: id(), name: 'Mensagem para a Lia', type: 'n8n-nodes-base.set', typeVersion: 3.4, position: [1400, 0],
      parameters: {
        mode: 'manual',
        assignments: { assignments: [
          { id: 'wa-0', name: 'sessao', type: 'string', value: "={{ $('Registrar entrada').item.json.sessao }}" },
          { id: 'wa-1', name: 'mensagem', type: 'string', value: "={{ $('Registrar entrada').item.json.texto }}" },
          { id: 'wa-2', name: 'wamid', type: 'string', value: "={{ $('Registrar entrada').item.json.wamid }}" },
        ] },
        options: {},
      },
    },
    {
      id: id(), name: 'Lia responde', type: 'n8n-nodes-base.executeWorkflow', typeVersion: 1.2, position: [1600, 0],
      onError: 'continueRegularOutput',
      parameters: { source: 'database', workflowId: NUCLEO, mode: 'each', options: { waitForSubWorkflow: true } },
    },
    code('Juntar resposta', [1800, 0], `// Junta a resposta da Lia com a conversa de origem (mesma ordem das mensagens)
const entradas = $('Mensagem para a Lia').all();
const cfg = $('Configuração do WhatsApp').first().json.cfg;
return $input.all().map((it, i) => ({ json: {
  sessao: entradas[i].json.sessao, cfg,
  blocos: (it.json.blocos || []).length ? it.json.blocos : [{ tipo: 'texto', texto: 'Desculpa, tive um probleminha aqui. Pode repetir?', botoes: [] }],
} }));`),
    se('Tem provador?', [2000, 0], "$json.cfg.provador_ativo === 'sim' && ($json.blocos || []).some((b) => b.tipo === 'provador')"),

    // --- Provador virtual (experimental): selfie + foto da peça -> prévia gerada por IA ---
    pg('Última selfie', [2200, -400], 'select * from ultima_foto_cliente($1)', '={{ $json.sessao }}', { alwaysOutputData: true, executeOnce: true }),
    se('Tem selfie?', [2400, -400], '!!$json.media'),
    code('Sem selfie', [2600, -200], "return [{ json: { ok: false, motivo: 'sem_foto' } }];"),
    // Teste sem a Meta: a "selfie" é um link público e é baixada sem o token
    se('Selfie de teste?', [2600, -400], "String($json.media).startsWith('https://')"),
    {
      id: id(), name: 'Baixar selfie de teste', type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2, position: [2800, -500],
      onError: 'continueRegularOutput',
      parameters: { method: 'GET', url: '={{ $json.media }}', options: { timeout: 30000, response: { response: { responseFormat: 'file' } } } },
    },
    meta('Endereço da selfie', [2800, -320], 'GET', `={{ ${graph} + $json.media }}`, { node: { onError: 'continueRegularOutput' } }),
    meta('Baixar selfie', [3000, -320], 'GET', '={{ $json.url }}', {
      node: { onError: 'continueRegularOutput' }, options: { response: { response: { responseFormat: 'file' } } },
    }),
    code('Pedido ao provador', [3200, -400], js('pedido-provador.js')),
    {
      id: id(), name: 'Gerar prévia', type: 'n8n-nodes-base.httpRequest', typeVersion: 4.2, position: [3400, -400],
      onError: 'continueRegularOutput',
      parameters: {
        method: 'POST', url: 'https://openrouter.ai/api/v1/chat/completions',
        authentication: 'predefinedCredentialType', nodeCredentialType: 'openRouterApi',
        sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.corpo) }}',
        options: { timeout: 120000 },
      },
    },
    code('Ler prévia', [3600, -400], js('ler-previa.js')),
    pg('Apagar referência da selfie', [3800, -560], 'select apagar_foto_cliente($1::bigint)', "={{ $('Última selfie').first().json.registro_id || 0 }}", { executeOnce: true }),
    se('Subir prévia?', [3800, -400], "$json.ok && $('Configuração do WhatsApp').first().json.cfg.whatsapp_modo === 'real'"),
    meta('Subir prévia', [4000, -480], 'POST', `={{ ${graph} + ${phone} + '/media' }}`, {
      node: { onError: 'continueRegularOutput' },
      params: {
        sendBody: true, contentType: 'multipart-form-data',
        bodyParameters: { parameters: [
          { parameterType: 'formData', name: 'messaging_product', value: 'whatsapp' },
          { parameterType: 'formData', name: 'type', value: '={{ $json.mime }}' },
          { parameterType: 'formBinaryData', name: 'file', inputDataFieldName: 'data' },
        ] },
      },
    }),
    code('Juntar prévia', [4200, -400], js('juntar-previa.js')),

    // --- Envio: blocos da Lia -> mensagens do WhatsApp ---
    code('Montar envios', [4400, 0], js('montar-envios.js')),
    se('Enviar de verdade?', [4600, 0], '$json.real'),
    meta('Enviar ao WhatsApp', [4800, -120], 'POST', '={{ $json.url }}', {
      node: { onError: 'continueRegularOutput' },
      params: { sendBody: true, specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.payload) }}' },
      // Uma mensagem por vez, na ordem, com um respiro entre elas
      options: { batching: { batch: { batchSize: 1, batchInterval: 400 } }, response: { response: { fullResponse: true, neverError: true } } },
    }),
    code('Resultado do envio', [5000, -120], `// Junta a resposta da Meta com a mensagem enviada (uma por item)
const env = $('Montar envios').item.json;
const r = $json.body || {};
const ok = $json.statusCode >= 200 && $json.statusCode < 300 && (r.messages || []).length > 0;
const e = r.error || {};
return { json: { ...env, wamid: ok ? r.messages[0].id : null, status: ok ? 'enviada' : 'erro',
  erro: ok ? null : (e.message || 'HTTP ' + $json.statusCode) + (e.error_data ? ' - ' + JSON.stringify(e.error_data) : '') } };`, { mode: 'runOnceForEachItem' }),
    pg('Registrar saída', [5200, 0],
      "insert into whatsapp_mensagens (wamid, sessao, direcao, tipo, payload, texto, status, erro)\nselect nullif(j->>'wamid', ''), j->>'sessao', 'saida', j->>'tipo', j->'payload', j->>'texto', j->>'status', nullif(j->>'erro', '')\nfrom (select $1::jsonb as j) p\non conflict (wamid) do nothing\nreturning id",
      '={{ JSON.stringify($json) }}'),

    // --- Avisos da loja (pagamento aprovado, etapas do rastreio): chamado pelo workflow 4 ---
    {
      id: id(), name: 'Avisos da loja', type: 'n8n-nodes-base.executeWorkflowTrigger', typeVersion: 1.1,
      position: [3800, 300], parameters: { inputSource: 'passthrough' },
    },
    pg('Avisos pendentes', [4000, 300], `select a.*, (${CFG}) as cfg from avisos_whatsapp_pendentes() a`, null, { executeOnce: true }),
    code('Preparar avisos', [4200, 300], `return $input.all().filter((i) => i.json.sessao).map((i) => ({ json: {
  sessao: i.json.sessao, cfg: i.json.cfg,
  blocos: (i.json.blocos || []).length ? i.json.blocos : [{ tipo: 'texto', texto: i.json.texto, botoes: [] }],
} }));`),

    // --- Catálogo para o Commerce Manager da Meta (feed CSV) ---
    {
      id: id(), name: 'Feed do catálogo', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, 600],
      webhookId: '7c1e2a40-5b6d-4e8f-9a01-b2c3d4e5f603',
      parameters: { httpMethod: 'GET', path: 'olden-catalogo-meta', responseMode: 'responseNode', options: {} },
    },
    pg('Montar feed', [220, 600], 'select feed_catalogo_meta() as csv', null),
    {
      id: id(), name: 'Responder feed', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [440, 600],
      parameters: {
        respondWith: 'text', responseBody: '={{ $json.csv }}',
        options: { responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/csv; charset=utf-8' }, { name: 'Content-Disposition', value: 'inline; filename="olden-catalogo.csv"' }] } },
      },
    },
  ];
  const connections = {
    'Verificação da Meta': main('Token de verificação'),
    'Token de verificação': main('Responder verificação'),
    'Recebe do WhatsApp': main('Configuração do WhatsApp'),
    'Configuração do WhatsApp': main('Ler evento'),
    'Ler evento': main('É mensagem?'),
    'É mensagem?': main('Registrar entrada', 'Atualizar status'),
    'Registrar entrada': main('Mensagem nova?'),
    'Mensagem nova?': main('Modo real?'),
    'Modo real?': main('Marcar como lida', 'Mensagem para a Lia'),
    'Marcar como lida': main('Mensagem para a Lia'),
    'Mensagem para a Lia': main('Lia responde'),
    'Lia responde': main('Juntar resposta'),
    'Juntar resposta': main('Tem provador?'),
    'Tem provador?': main('Última selfie', 'Montar envios'),
    'Última selfie': main('Tem selfie?'),
    'Tem selfie?': main('Selfie de teste?', 'Sem selfie'),
    'Sem selfie': main('Juntar prévia'),
    'Selfie de teste?': main('Baixar selfie de teste', 'Endereço da selfie'),
    'Baixar selfie de teste': main('Pedido ao provador'),
    'Endereço da selfie': main('Baixar selfie'),
    'Baixar selfie': main('Pedido ao provador'),
    'Pedido ao provador': main('Gerar prévia'),
    'Gerar prévia': main('Ler prévia'),
    'Ler prévia': { main: [[conn('Apagar referência da selfie'), conn('Subir prévia?')]] },
    'Subir prévia?': main('Subir prévia', 'Juntar prévia'),
    'Subir prévia': main('Juntar prévia'),
    'Juntar prévia': main('Montar envios'),
    'Montar envios': main('Enviar de verdade?'),
    'Enviar de verdade?': main('Enviar ao WhatsApp', 'Registrar saída'),
    'Enviar ao WhatsApp': main('Resultado do envio'),
    'Resultado do envio': main('Registrar saída'),
    'Avisos da loja': main('Avisos pendentes'),
    'Avisos pendentes': main('Preparar avisos'),
    'Preparar avisos': main('Montar envios'),
    'Feed do catálogo': main('Montar feed'),
    'Montar feed': main('Responder feed'),
  };
  save('5-whatsapp.json', {
    name: 'Olden | 5. WhatsApp', nodes, connections, pinData: {},
    settings: { executionOrder: 'v1', executionTimeout: 300 },
  });
}
