// Gera n8n/olden-agente-whatsapp.json a partir de n8n/system-prompt.md
// Uso: node n8n/build/gerar-workflow.js
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '..');
const prompt = fs.readFileSync(path.join(dir, 'system-prompt.md'), 'utf8').trim();

const PG = undefined; // credenciais são escolhidas no n8n depois de importar
const GEMINI = undefined;
const CONVERSA = "$('Contexto do atendimento').first().json.conversa_id";

const tool = (id, name, position, description, query, payload) => ({
  id, name, position,
  type: 'n8n-nodes-base.postgresTool',
  typeVersion: 2.6,
  credentials: PG,
  parameters: {
    descriptionType: 'manual',
    toolDescription: description,
    operation: 'executeQuery',
    query,
    // Um único parâmetro JSON: vírgulas no texto do cliente não quebram a query
    options: { queryReplacement: `={{ JSON.stringify({ ${payload} }) }}` },
  },
});

const nodes = [
  {
    id: 'a1000000-0000-4000-8000-000000000001',
    name: 'Mensagem recebida',
    type: '@n8n/n8n-nodes-langchain.chatTrigger',
    typeVersion: 1.1,
    position: [0, 0],
    webhookId: 'b7c1e9a2-5d3f-4e8a-9c6b-0f1d2e3a4b5c',
    parameters: { options: {} },
  },
  {
    id: 'a1000000-0000-4000-8000-000000000002',
    name: 'Contexto do atendimento',
    type: 'n8n-nodes-base.postgres',
    typeVersion: 2.6,
    position: [240, 0],
    credentials: PG,
    alwaysOutputData: false,
    parameters: {
      operation: 'executeQuery',
      query: 'select * from contexto_atendimento($1)',
      options: { queryReplacement: "={{ $('Mensagem recebida').item.json.sessionId }}" },
    },
  },
  {
    id: 'a1000000-0000-4000-8000-000000000003',
    name: 'Agente Olden',
    type: '@n8n/n8n-nodes-langchain.agent',
    typeVersion: 2.2,
    position: [520, 0],
    parameters: {
      promptType: 'define',
      text: "={{ $('Mensagem recebida').item.json.chatInput }}",
      options: { systemMessage: '=' + prompt, maxIterations: 8 },
    },
  },
  {
    id: 'a1000000-0000-4000-8000-000000000004',
    name: 'Google Gemini',
    type: '@n8n/n8n-nodes-langchain.lmChatGoogleGemini',
    typeVersion: 1,
    position: [300, 260],
    credentials: GEMINI,
    parameters: {
      modelName: 'models/gemini-flash-latest',
      options: { temperature: 0.4, maxOutputTokens: 1024 },
    },
  },
  {
    id: 'a1000000-0000-4000-8000-000000000005',
    name: 'Memória da conversa',
    type: '@n8n/n8n-nodes-langchain.memoryPostgresChat',
    typeVersion: 1.3,
    position: [460, 260],
    credentials: PG,
    parameters: {
      sessionIdType: 'customKey',
      sessionKey: `={{ ${CONVERSA} }}`,
      tableName: 'n8n_chat_histories',
      contextWindowLength: 20,
    },
  },
  tool('a1000000-0000-4000-8000-000000000006', 'registrar_interesse', [620, 260],
    'Registra que o cliente demonstrou interesse num produto. Chame quando o cliente perguntar sobre um produto específico do catálogo.',
    "insert into interesses (conversa_id, sku)\nselect (j->>'conversa_id')::uuid, j->>'sku'\nfrom (select $1::jsonb as j) p\nreturning 'interesse registrado' as resultado, sku;",
    `conversa_id: ${CONVERSA}, sku: $fromAI('sku', 'SKU do produto exatamente como no catálogo, ex.: CEL-BR', 'string')`),
  tool('a1000000-0000-4000-8000-000000000007', 'registrar_pedido', [780, 260],
    'Registra (reserva) um item do pedido e baixa o estoque. Só chame depois que o cliente confirmar produto, tamanho, quantidade, forma de pagamento e nome. Chame uma vez por produto/tamanho. O banco calcula o valor; se faltar estoque, devolve erro.',
    "insert into pedidos (conversa_id, sku, tamanho, quantidade, forma_pagamento, nome_cliente)\nselect (j->>'conversa_id')::uuid, j->>'sku', j->>'tamanho', (j->>'quantidade')::int,\n       j->>'forma_pagamento', j->>'nome_cliente'\nfrom (select $1::jsonb as j) p\nreturning sku, tamanho, quantidade, forma_pagamento, valor_unitario, valor_total, status;",
    `conversa_id: ${CONVERSA}, sku: $fromAI('sku', 'SKU do produto exatamente como no catálogo', 'string'), tamanho: $fromAI('tamanho', 'Tamanho exatamente como no catálogo, ex.: M, GG, 8, ÚNICO', 'string'), quantidade: $fromAI('quantidade', 'Quantidade de peças, de 1 a 10', 'number'), forma_pagamento: $fromAI('forma_pagamento', 'pix ou cartao', 'string'), nome_cliente: $fromAI('nome_cliente', 'Nome do cliente', 'string')`),
  tool('a1000000-0000-4000-8000-000000000008', 'registrar_avaliacao', [940, 260],
    'Registra a avaliação do atendimento (nota de 1 a 5 e comentário opcional) e encerra a conversa. Chame quando o cliente der a nota.',
    "insert into avaliacoes (conversa_id, nota, comentario)\nselect (j->>'conversa_id')::uuid, (j->>'nota')::int, nullif(j->>'comentario', '')\nfrom (select $1::jsonb as j) p\nreturning 'avaliacao registrada' as resultado, nota;",
    `conversa_id: ${CONVERSA}, nota: $fromAI('nota', 'Nota de 1 a 5 dada pelo cliente', 'number'), comentario: $fromAI('comentario', 'Comentário do cliente; vazio se não houver', 'string')`),
];

const ai = (type) => (to) => ({ node: to, type, index: 0 });
const connections = {
  'Mensagem recebida': { main: [[{ node: 'Contexto do atendimento', type: 'main', index: 0 }]] },
  'Contexto do atendimento': { main: [[{ node: 'Agente Olden', type: 'main', index: 0 }]] },
  'Google Gemini': { ai_languageModel: [[ai('ai_languageModel')('Agente Olden')]] },
  'Memória da conversa': { ai_memory: [[ai('ai_memory')('Agente Olden')]] },
  registrar_interesse: { ai_tool: [[ai('ai_tool')('Agente Olden')]] },
  registrar_pedido: { ai_tool: [[ai('ai_tool')('Agente Olden')]] },
  registrar_avaliacao: { ai_tool: [[ai('ai_tool')('Agente Olden')]] },
};

const workflow = {
  name: 'Olden - Agente de atendimento (teste)',
  nodes,
  connections,
  settings: { executionOrder: 'v1' },
  pinData: {},
};

const out = path.join(dir, 'olden-agente-whatsapp.json');
fs.writeFileSync(out, JSON.stringify(workflow, null, 2) + '\n');
console.log('gerado:', out);
