// Gera os 3 workflows do n8n a partir de n8n/system-prompt.md
// Uso: node n8n/build/gerar-workflows.js
//
//   1-nucleo-agente.json   Agente + memória + ferramentas. Chamado pelos outros dois.
//   2-chat-demo.json       Chat público para o cliente testar.
//   3-bateria-testes.json  Roda os cenários do banco em várias configurações e dá nota.
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '..');
const prompt = fs.readFileSync(path.join(dir, 'system-prompt.md'), 'utf8').trim();

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
const code = (name, position, jsCode, extra = {}) => ({
  id: id(), name, type: 'n8n-nodes-base.code', typeVersion: 2, position, parameters: { jsCode }, ...extra,
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
            ['mensagem', 'string', "={{ $json.mensagem || 'Oi, quero conhecer as camisas' }}"],
            ['modelo', 'string', `={{ $json.modelo || '${PADRAO.modelo}' }}`],
            ['esforco', 'string', `={{ $json.esforco || '${PADRAO.esforco}' }}`],
            ['janela', 'number', `={{ Number($json.janela) || ${PADRAO.janela} }}`],
          ].map(([name, type, value], i) => ({ id: `cfg-${i}`, name, type, value })),
        },
        options: {},
      },
    },
    pg('Contexto do atendimento', [440, 0],
      "select c.*, $1::jsonb->>'mensagem' as mensagem, $1::jsonb->>'modelo' as modelo,\n       $1::jsonb->>'esforco' as esforco, ($1::jsonb->>'janela')::int as janela\nfrom contexto_atendimento($1::jsonb->>'sessao') c",
      '={{ JSON.stringify($json) }}'),
    {
      id: id(), name: 'Agente Olden', type: '@n8n/n8n-nodes-langchain.agent', typeVersion: 2.2, position: [700, 0],
      parameters: {
        promptType: 'define', text: '={{ $json.mensagem }}',
        options: { systemMessage: '=' + prompt, maxIterations: 8 },
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
      'Registra que o cliente demonstrou interesse num produto. Chame quando o cliente perguntar sobre um produto específico do catálogo.',
      "insert into interesses (conversa_id, sku)\nselect (j->>'conversa_id')::uuid, j->>'sku'\nfrom (select $1::jsonb as j) p\nreturning 'interesse registrado' as resultado, sku;",
      `conversa_id: ${C}, sku: $fromAI('sku', 'SKU do produto exatamente como no catálogo, ex.: CEL-BR', 'string')`),
    tool('registrar_pedido', [940, 260],
      'Registra (reserva) um item do pedido e baixa o estoque. Só chame depois que o cliente confirmar produto, tamanho, quantidade, forma de pagamento e nome. Chame uma vez por produto/tamanho. O banco calcula o valor; se faltar estoque, devolve erro.',
      "insert into pedidos (conversa_id, sku, tamanho, quantidade, forma_pagamento, nome_cliente)\nselect (j->>'conversa_id')::uuid, j->>'sku', j->>'tamanho', (j->>'quantidade')::int,\n       j->>'forma_pagamento', j->>'nome_cliente'\nfrom (select $1::jsonb as j) p\nreturning sku, tamanho, quantidade, forma_pagamento, valor_unitario, valor_total, status;",
      `conversa_id: ${C}, sku: $fromAI('sku', 'SKU do produto exatamente como no catálogo', 'string'), tamanho: $fromAI('tamanho', 'Tamanho exatamente como no catálogo, ex.: M, GG, 8, ÚNICO, 9 MESES', 'string'), quantidade: $fromAI('quantidade', 'Quantidade de peças, de 1 a 10', 'number'), forma_pagamento: $fromAI('forma_pagamento', 'pix ou cartao', 'string'), nome_cliente: $fromAI('nome_cliente', 'Nome do cliente', 'string')`),
    tool('registrar_avaliacao', [1100, 260],
      'Registra a avaliação do atendimento (nota de 1 a 5 e comentário opcional) e encerra a conversa. Chame quando o cliente der a nota.',
      "insert into avaliacoes (conversa_id, nota, comentario)\nselect (j->>'conversa_id')::uuid, (j->>'nota')::int, nullif(j->>'comentario', '')\nfrom (select $1::jsonb as j) p\nreturning 'avaliacao registrada' as resultado, nota;",
      `conversa_id: ${C}, nota: $fromAI('nota', 'Nota de 1 a 5 dada pelo cliente', 'number'), comentario: $fromAI('comentario', 'Comentário do cliente; vazio se não houver', 'string')`),
  ];
  const connections = {
    Entrada: main('Configuração'),
    'Configuração': main('Contexto do atendimento'),
    'Contexto do atendimento': main('Agente Olden'),
    'Claude via OpenRouter': { ai_languageModel: [[conn('Agente Olden', 'ai_languageModel')]] },
    'Memória da conversa': { ai_memory: [[conn('Agente Olden', 'ai_memory')]] },
    registrar_interesse: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    registrar_pedido: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
    registrar_avaliacao: { ai_tool: [[conn('Agente Olden', 'ai_tool')]] },
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
  const nodes = [
    {
      id: id(), name: 'Chat público', type: '@n8n/n8n-nodes-langchain.chatTrigger', typeVersion: 1.1,
      position: [0, 0], webhookId: 'c3d2e1f0-4a5b-4c6d-8e7f-0a1b2c3d4e5f',
      parameters: {
        public: true, mode: 'hostedChat', authentication: 'none',
        initialMessages: 'Oi! Eu sou a Lia, atendente virtual da Olden Sports.\nComo posso te ajudar hoje?',
        options: {
          title: 'Olden Sports',
          subtitle: 'Atendimento virtual (ambiente de demonstração)',
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
  ];
  save('2-chat-demo.json', {
    name: 'Olden | 2. Chat de demonstração', nodes, pinData: {},
    connections: { 'Chat público': main('Preparar mensagem'), 'Preparar mensagem': main('Chamar núcleo do agente') },
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
  return { cliente: t.json.mensagem, agente: r.output ?? ('[ERRO] ' + JSON.stringify(r.error ?? r)) };
});
return [{ json: { ...combo, transcricao, duracao_ms: Date.now() - turnos[0].json.inicio } }];`;

  const CHECAGENS = `const c = $('Transcrição').first().json;
const f = $json.fatos || {};
const e = c.esperado || {};
const chk = [];
const add = (nome, ok, detalhe) => chk.push({ nome, ok, detalhe });
const norm = (v) => String(v ?? '').trim().toUpperCase();

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
  const dif = ['sku', 'tamanho', 'quantidade', 'forma_pagamento'].filter((k) => norm(p[k]) !== norm(e.pedido[k]));
  add('dados do pedido', dif.length === 0, dif.length ? 'diferente em: ' + dif.map((k) => k + ' (' + (p[k] ?? 'nada') + ')').join(', ') : 'ok');
}
if (e.avaliacao_nota !== undefined) {
  const a = (f.avaliacoes || [])[0];
  add('avaliação', !!a && a.nota === e.avaliacao_nota, a ? 'nota gravada ' + a.nota : 'nenhuma avaliação gravada');
}
if (e.status_final) add('status final', f.status_final === e.status_final, 'gravado ' + f.status_final);
const erros = c.transcricao.filter((t) => String(t.agente).startsWith('[ERRO]')).length;
add('execução sem erro', erros === 0, erros ? erros + ' turno(s) com erro' : 'ok');

return [{ json: { ...c, fatos: f, checagens: chk, aprovado_auto: chk.every((x) => x.ok) } }];`;

  const PROMPT_JUIZ = `=Você avalia o atendimento de uma IA de vendas da loja Olden Sports (produtos do Palmeiras) no WhatsApp.

CENÁRIO: {{ $json.titulo }}

O QUE UM BOM ATENDIMENTO FAZ NESTE CENÁRIO:
{{ $json.criterios_juiz }}

REGRAS GERAIS DA LOJA: só fala de produtos do catálogo; não inventa preço, prazo, frete ou desconto; confirma o pedido antes de registrar; pede nota de 1 a 5 depois do pedido; encaminha trocas e reclamações para um humano; mensagens curtas e educadas.

CONVERSA:
{{ $json.transcricao.map((t, i) => 'Turno ' + (i + 1) + '\\nCLIENTE: ' + t.cliente + '\\nAGENTE: ' + t.agente).join('\\n\\n') }}

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
