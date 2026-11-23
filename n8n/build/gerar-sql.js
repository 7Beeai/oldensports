// Gera os SQL que dependem de arquivos do repositório:
//   supabase/08_prompt_no_banco.sql  instala o prompt (n8n/system-prompt.md) como versão ativa
//   supabase/00_instalar_tudo.sql    junta 01 a 09 na ordem
//   supabase/atualizar_prompt.sql    só a troca do prompt, para colar no SQL Editor
// Uso: node n8n/build/gerar-sql.js "descrição da versão"
const fs = require('fs');
const path = require('path');
const raiz = path.join(__dirname, '..', '..');
const sup = path.join(raiz, 'supabase');
const prompt = fs.readFileSync(path.join(raiz, 'n8n', 'system-prompt.md'), 'utf8').trim();
const descricao = (process.argv[2] || 'Prompt do repositório').replace(/'/g, "''");
if (prompt.includes('$prompt$')) throw new Error('o prompt não pode conter $prompt$');

const troca = `select nova_versao_prompt($prompt$${prompt}$prompt$, '${descricao}');\n`;

const base = fs.readFileSync(path.join(__dirname, '08_base.sql'), 'utf8');
fs.writeFileSync(path.join(sup, '08_prompt_no_banco.sql'),
  base + '\n-- ---------- Versão do prompt que vem do repositório (só cria se o texto mudou) ----------\n' + troca);
console.log('gerado: supabase/08_prompt_no_banco.sql');

fs.writeFileSync(path.join(sup, 'atualizar_prompt.sql'),
  `-- Atualiza o comportamento da Lia: cria uma versão nova do prompt e ativa.\n-- Para voltar: select ativar_prompt(NUMERO_DA_VERSAO);\n` + troca);
console.log('gerado: supabase/atualizar_prompt.sql');

const arquivos = ['01_schema', '02_catalogo', '03_atualiza_body', '04_ambiente_testes', '05_fotos',
  '06_pagamento_rastreio_teste', '07_mensagens_proativas', '08_prompt_no_banco', '09_avisos_rastreio'];
let tudo = `-- =====================================================================
-- Olden Sports - INSTALAR TUDO
-- Junta os arquivos 01 a 09, na ordem. Cole o arquivo inteiro numa
-- query nova do SQL Editor do Supabase e clique em Run, sem nada selecionado.
-- Pode rodar de novo: não duplica nada. Atenção: rodar de novo volta o
-- estoque de todos os produtos para 8 unidades por tamanho.
--
-- Depois de rodar, ajuste o endereço do seu n8n (sem barra no final):
--   update configuracao set valor = 'https://SEU-N8N' where chave = 'url_base_n8n';
-- =====================================================================
`;
for (const a of arquivos) {
  tudo += `\n\n-- #####################################################################\n-- ${a}.sql\n-- #####################################################################\n\n`;
  tudo += fs.readFileSync(path.join(sup, a + '.sql'), 'utf8');
}
fs.writeFileSync(path.join(sup, '00_instalar_tudo.sql'), tudo);
console.log('gerado: supabase/00_instalar_tudo.sql');
