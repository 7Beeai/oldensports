-- =====================================================================
-- Olden Sports - verificar_instalacao.sql
-- Confere se tudo o que a Lia precisa está instalado no Supabase.
-- SÓ LÊ: não altera nada. Cole inteiro numa query nova e clique em Run.
-- Cada linha mostra ✅ (ok) ou ❌ (falta), e o arquivo que resolve.
-- =====================================================================

with
tabelas(ordem, nome, arquivo) as (values
  (1, 'clientes', '00 (01)'), (2, 'produtos', '00 (01)'), (3, 'estoque', '00 (01)'), (4, 'conversas', '00 (01)'),
  (5, 'interesses', '00 (01)'), (6, 'pedidos', '00 (01)'), (7, 'avaliacoes', '00 (01)'), (8, 'n8n_chat_histories', '00 (01)'),
  (9, 'cenarios_teste', '00 (04)'), (10, 'resultados_teste', '00 (04)'), (11, 'configuracao', '00 (06)'),
  (12, 'pagamentos', '00 (06)'), (13, 'mensagens_saida', '00 (07)'), (14, 'prompt_agente', '00 (08)'),
  (15, 'rastreio_avisos', '00 (09)'), (16, 'catalogo_produtos', '10'), (17, 'catalogo_variantes', '10'),
  (18, 'vitrines', '10'), (19, 'tabela_medidas', '13')
),
funcoes(ordem, assinatura, arquivo) as (values
  (1, 'contexto_atendimento(text,text)', '00'), (2, 'catalogo_texto()', '00'), (3, 'limpar_testes()', '00'),
  (4, 'fatos_sessao(text)', '00'), (5, 'gerar_pagamento(uuid)', '00 (06)'), (6, 'confirmar_pagamento(text,boolean)', '00 (07)'),
  (7, 'situacao_pedido(uuid)', '00 (06)'), (8, 'simular_pagamento_sessao(text,text)', '00 (09)'),
  (9, 'aviso_pagamento(text)', '00 (07)'), (10, 'avisos_rastreio_pendentes()', '00 (09)'), (11, 'aviso_rastreio(uuid,text)', '00 (09)'),
  (12, 'nova_versao_prompt(text,text)', '00 (08)'), (13, 'ativar_prompt(integer)', '00 (08)'),
  (14, 'prompt_montado(text,text,text,text)', '00 (08)'), (15, 'buscar_produtos(text,jsonb,integer)', '10'),
  (16, 'f_unaccent(text)', '10'), (17, 'nome_produto(text)', '12'), (18, 'itens_vitrine(text,integer)', '12'),
  (19, 'produtos_para_blocos(jsonb)', '12'), (20, 'recomendar_tamanho(text,numeric,numeric,text,numeric)', '13'),
  (21, 'detalhes_produto(text)', '13'), (22, 'comparar_produtos(text,text)', '13'), (23, 'atributos_produto(text)', '13'),
  (24, 'atualizar_tabela_medidas()', '13')
),
-- conta linhas só se a tabela existir (senão devolve null, sem dar erro)
conta(nome, n) as (
  select t.nome,
         case when to_regclass('public.' || t.nome) is not null
              then (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.' || t.nome, false, true, '')))[1]::text::bigint
         end
  from tabelas t
),
config(chave, valor) as (
  select chave, valor from (select null::text chave, null::text valor) x where false
  union all
  select (xpath('/row/chave/text()', r))[1]::text, (xpath('/row/valor/text()', r))[1]::text
  from unnest(case when to_regclass('public.configuracao') is not null
                   then xpath('/table/row', query_to_xml('select chave, valor from public.configuracao', false, false, ''))
                   else '{}'::xml[] end) as r
),
prompt as (
  select case when to_regclass('public.prompt_agente') is not null
              then (xpath('/row/v/text()', query_to_xml('select versao as v from public.prompt_agente where ativo', false, true, '')))[1]::text
         end as versao,
         case when to_regclass('public.prompt_agente') is not null
              then (xpath('/row/t/text()', query_to_xml('select (texto like ''%recomendar_tamanho%'')::text as t from public.prompt_agente where ativo', false, true, '')))[1]::text
         end as tem_v4,
         case when to_regclass('public.prompt_agente') is not null
              then (xpath('/row/t/text()', query_to_xml('select (texto like ''%buscar_produtos%'')::text as t from public.prompt_agente where ativo', false, true, '')))[1]::text
         end as tem_v3
),
linhas(grupo, ordem, item, ok, detalhe, arquivo) as (
  -- extensões
  select '1. Extensões', 1, 'unaccent', exists (select 1 from pg_extension where extname = 'unaccent'), null, '10'
  union all select '1. Extensões', 2, 'pg_trgm', exists (select 1 from pg_extension where extname = 'pg_trgm'), null, '10'
  -- tabelas
  union all
  select '2. Tabelas', t.ordem, t.nome, to_regclass('public.' || t.nome) is not null,
         coalesce(c.n || ' linha(s)', 'não existe'), t.arquivo
  from tabelas t join conta c using (nome)
  -- funções
  union all
  select '3. Funções', f.ordem, f.assinatura, to_regprocedure('public.' || f.assinatura) is not null,
         case when to_regprocedure('public.' || f.assinatura) is null then 'não existe' end, f.arquivo
  from funcoes f
  -- dados e versões
  union all select '4. Dados', 1, 'Catálogo completo: 961 modelos',
         coalesce((select n from conta where nome = 'catalogo_produtos'), 0) >= 961,
         coalesce((select n from conta where nome = 'catalogo_produtos'), 0) || ' modelo(s)', '11 (partes 1 a 6)'
  union all select '4. Dados', 2, 'Catálogo completo: 3.623 tamanhos',
         coalesce((select n from conta where nome = 'catalogo_variantes'), 0) >= 3623,
         coalesce((select n from conta where nome = 'catalogo_variantes'), 0) || ' tamanho(s)', '11 (partes 1 a 6)'
  union all select '4. Dados', 3, 'Vitrines (promoções, destaques, palmeiras)',
         coalesce((select n from conta where nome = 'vitrines'), 0) >= 3,
         coalesce((select n from conta where nome = 'vitrines'), 0) || ' vitrine(s)', '11 (parte 6)'
  union all select '4. Dados', 4, 'Tabela de medidas preenchida',
         coalesce((select n from conta where nome = 'tabela_medidas'), 0) > 0,
         coalesce((select n from conta where nome = 'tabela_medidas'), 0) || ' linha(s)', '13 (ou: select atualizar_tabela_medidas();)'
  union all select '4. Dados', 5, 'Cenários de teste (C01 a C36)',
         coalesce((select n from conta where nome = 'cenarios_teste'), 0) >= 33,
         coalesce((select n from conta where nome = 'cenarios_teste'), 0) || ' cenário(s)', '12 e 13'
  union all select '4. Dados', 6, 'Demonstração antiga: 8 produtos',
         coalesce((select n from conta where nome = 'produtos'), 0) >= 8,
         coalesce((select n from conta where nome = 'produtos'), 0) || ' produto(s)', '00 (02)'
  union all select '5. Configuração', 1, 'Endereço do n8n (url_base_n8n)',
         coalesce((select valor from config where chave = 'url_base_n8n'), '') not in ('', 'https://SEU-N8N.exemplo.com'),
         coalesce((select valor from config where chave = 'url_base_n8n'), 'não cadastrado'),
         'update configuracao set valor = ''https://SEU-N8N'' where chave = ''url_base_n8n'';'
  union all select '5. Configuração', 2, 'Minutos por etapa do rastreio',
         (select valor from config where chave = 'minutos_por_etapa_rastreio') is not null,
         coalesce((select valor from config where chave = 'minutos_por_etapa_rastreio'), 'não cadastrado'), '00 (09)'
  union all select '5. Configuração', 3, 'Prompt ativo é a versão 4 (tamanho e comparação)',
         (select tem_v4 from prompt) = 'true',
         case when (select versao from prompt) is null then 'nenhuma versão ativa'
              when (select tem_v4 from prompt) = 'true' then 'versão ' || (select versao from prompt)
              when (select tem_v3 from prompt) = 'true' then 'versão ' || (select versao from prompt) || ' (é a do passo 3, falta a do passo 5)'
              else 'versão ' || (select versao from prompt) || ' (antiga, sem catálogo completo)' end,
         'atualizar_prompt.sql'
  union all select '5. Configuração', 4, 'Pedidos aceitam produtos do catálogo completo',
         not exists (select 1 from pg_constraint where contype = 'f' and conrelid = to_regclass('public.pedidos')
                      and confrelid = to_regclass('public.produtos')),
         null, '12'
)
select grupo, case when ok then '✅' else '❌' end as status, item, detalhe,
       case when ok then '' else 'rode: ' || arquivo end as como_resolver
from linhas
order by grupo, ok, ordem;
