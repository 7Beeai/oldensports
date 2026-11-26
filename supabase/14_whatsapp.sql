-- =====================================================================
-- Olden Sports - 14_whatsapp.sql
-- Ponte da Lia com o WhatsApp (API oficial da Meta, Cloud API).
-- Pode rodar mais de uma vez: não apaga dados.
--
--   whatsapp_mensagens      registro de tudo que entra e sai pelo WhatsApp
--   configuracao            chaves whatsapp_* e provador_* (sem segredos:
--                           o token da Meta fica numa credencial do n8n)
--   mensagens_saida         ganha "blocos" e "enviada_whatsapp_em" para os
--                           avisos de pagamento e rastreio chegarem no WhatsApp
--   produtos_para_blocos    passa a devolver os códigos de cada tamanho
--                           (o catálogo da Meta usa o código do tamanho)
--   feed_catalogo_meta()    arquivo CSV do catálogo para o Commerce Manager
--   ultima_foto_cliente()   selfie mais recente da conversa (provador)
-- =====================================================================

-- 1. Registro das mensagens do WhatsApp ------------------------------------
create table if not exists whatsapp_mensagens (
  id         bigserial primary key,
  wamid      text unique,                 -- id da mensagem na Meta (evita processar duas vezes)
  sessao     text not null,               -- "wa:5511999999999"
  direcao    text not null check (direcao in ('entrada', 'saida')),
  tipo       text,                        -- text, interactive, image, order...
  payload    jsonb,
  texto      text,                        -- o que a Lia leu (entrada) ou um resumo do que foi enviado (saída)
  status     text,                        -- recebida, simulada, enviada, entregue, lida, erro
  erro       text,
  criado_em  timestamptz not null default now()
);
alter table whatsapp_mensagens add column if not exists texto text;
create index if not exists whatsapp_mensagens_sessao on whatsapp_mensagens (sessao, id desc);

-- 2. Configuração (valores padrão; nada aqui é segredo) ---------------------
insert into configuracao (chave, valor) values
  ('whatsapp_modo', 'simulado'),            -- simulado: não chama a Meta, só registra o que enviaria | real
  ('whatsapp_graph_versao', 'v23.0'),
  ('whatsapp_phone_number_id', ''),         -- Meta > WhatsApp > Configuração da API
  ('whatsapp_catalogo_id', ''),             -- Commerce Manager: com ele a Lia manda as fichas nativas
  ('whatsapp_flow_tamanho_id', ''),         -- id do Flow "Descubra seu tamanho"
  ('whatsapp_flow_modo', 'draft'),          -- draft enquanto o Flow não for publicado | published
  ('whatsapp_verify_token', substr(md5(random()::text || clock_timestamp()::text), 1, 24)),
  ('whatsapp_numeros_teste', ''),          -- só estes números falam com a Lia (vírgula); vazio = todos
  ('provador_ativo', 'sim'),
  ('provador_modelo', 'google/gemini-3.1-flash-image')
on conflict (chave) do nothing;

-- 3. Avisos proativos (pagamento e rastreio) também no WhatsApp ------------
alter table mensagens_saida add column if not exists blocos jsonb;
alter table mensagens_saida add column if not exists enviada_whatsapp_em timestamptz;
-- O que já existia não deve ser reenviado
update mensagens_saida set enviada_whatsapp_em = coalesce(enviada_whatsapp_em, criado_em)
 where sessao not like 'wa:%' and enviada_whatsapp_em is null;

create or replace function avisos_whatsapp_pendentes()
returns table (id bigint, sessao text, texto text, blocos jsonb)
language sql
set search_path = public
as $$
  with fila as (
    select m.id from mensagens_saida m
     where m.sessao like 'wa:%' and m.enviada_whatsapp_em is null
       and m.criado_em > now() - interval '1 day'
     order by m.id
     for update skip locked
  )
  update mensagens_saida m set enviada_whatsapp_em = now()
    from fila where m.id = fila.id
  returning m.id, m.sessao, m.texto, m.blocos;
$$;

-- 4. Produtos para os blocos: agora com os códigos de cada tamanho ----------
create or replace function produtos_para_blocos(p_skus jsonb)
returns jsonb
language sql
stable
set search_path = public
as $$
  select coalesce(jsonb_object_agg(x.chave, x.dados), '{}'::jsonb)
  from (
    select s.chave, jsonb_build_object(
             'item_group_id', p.item_group_id, 'nome', p.nome,
             'preco', coalesce(nullif(p.preco_promocional, 0), p.preco), 'preco_original', p.preco,
             'preco_pix', p.preco_pix, 'parcelamento', p.parcelamento,
             'imagem', p.imagens->0->>'url', 'imagens', p.imagens, 'video', p.video_url, 'url', p.url,
             'departamento', p.departamento, 'faixa_etaria', p.faixa_etaria, 'genero', p.genero,
             'atributos', atributos_produto(p.item_group_id),
             'tamanho', v.tamanho,
             'tamanhos', (select jsonb_agg(v2.tamanho order by v2.ordem) from catalogo_variantes v2
                           where v2.item_group_id = p.item_group_id and v2.disponivel and v2.quantidade > 0),
             'skus', (select jsonb_agg(v2.sku order by v2.ordem) from catalogo_variantes v2
                       where v2.item_group_id = p.item_group_id and v2.disponivel and v2.quantidade > 0),
             'disponivel', case when v.sku is not null then v.disponivel and v.quantidade > 0
                                else exists (select 1 from catalogo_variantes v3 where v3.item_group_id = p.item_group_id
                                              and v3.disponivel and v3.quantidade > 0) end and p.ativo,
             'resumo', left(p.descricao, 160)) as dados
    from (select distinct upper(trim(value)) as chave from jsonb_array_elements_text(coalesce(p_skus, '[]'::jsonb))) s
    left join catalogo_variantes v on v.sku = s.chave
    join catalogo_produtos p on p.item_group_id = coalesce(v.item_group_id, s.chave)
  ) x
$$;

-- 5. Catálogo no formato da Meta (CSV, um tamanho por linha) ----------------
-- O n8n publica em /webhook/olden-catalogo-meta e o Commerce Manager busca
-- de hora em hora ("Fonte de dados > Feed programado").
create or replace function feed_catalogo_meta()
returns text
language sql
stable
set search_path = public
as $$
  with q(v) as (select 1),
  linhas as (
    select
      v.sku as id,
      p.item_group_id,
      left(p.nome || case when v.tamanho is not null and v.tamanho <> '' then ' - ' || v.tamanho else '' end, 200) as title,
      left(coalesce(nullif(p.descricao, ''), p.nome), 1500) as description,
      case when v.disponivel and v.quantidade > 0 and p.ativo then 'in stock' else 'out of stock' end as availability,
      'new' as condition,
      to_char(coalesce(v.preco, p.preco), 'FM999999990.00') || ' BRL' as price,
      case when coalesce(v.preco_promocional, p.preco_promocional, 0) > 0
                and coalesce(v.preco_promocional, p.preco_promocional) < coalesce(v.preco, p.preco)
           then to_char(coalesce(v.preco_promocional, p.preco_promocional), 'FM999999990.00') || ' BRL' else '' end as sale_price,
      p.url as link,
      coalesce(nullif(v.imagem, ''), p.imagens->0->>'url', '') as image_link,
      coalesce((select string_agg(i->>'url', ',') from jsonb_array_elements(p.imagens) with ordinality t(i, n)
                 where n between 2 and 10), '') as additional_image_link,
      coalesce(nullif(p.marca, ''), 'Olden Sports') as brand,
      coalesce(v.tamanho, '') as size,
      case p.genero when 'masculino' then 'male' when 'feminino' then 'female' else 'unisex' end as gender,
      case p.faixa_etaria when 'infantil' then 'kids' when 'bebe' then 'infant' else 'adult' end as age_group,
      greatest(coalesce(v.quantidade, 0), 0)::text as quantity_to_sell_on_facebook
    from catalogo_variantes v
    join catalogo_produtos p on p.item_group_id = v.item_group_id
  ),
  esc as (
    select '"' || replace(coalesce(x, ''), '"', '""') || '"' as c, l.id, ord
    from linhas l,
    lateral (values (1, l.id), (2, l.item_group_id), (3, l.title), (4, l.description), (5, l.availability),
                    (6, l.condition), (7, l.price), (8, l.sale_price), (9, l.link), (10, l.image_link),
                    (11, l.additional_image_link), (12, l.brand), (13, l.size), (14, l.gender),
                    (15, l.age_group), (16, l.quantity_to_sell_on_facebook)) as campos(ord, x)
  )
  select 'id,item_group_id,title,description,availability,condition,price,sale_price,link,image_link,'
         || 'additional_image_link,brand,size,gender,age_group,quantity_to_sell_on_facebook' || E'\n'
         || coalesce((select string_agg(linha, E'\n' order by id)
                        from (select id, string_agg(c, ',' order by ord) as linha from esc group by id) t), '')
$$;

-- 6. Provador: a selfie mais recente da conversa (últimos 30 minutos) -------
create or replace function ultima_foto_cliente(p_sessao text)
returns table (registro_id bigint, media text)
language sql
stable
set search_path = public
as $$
  select id, payload->'image'->>'id'
    from whatsapp_mensagens
   where sessao = p_sessao and direcao = 'entrada' and tipo = 'image'
     and payload->'image'->>'id' is not null
     and criado_em > now() - interval '30 minutes'
   order by id desc
   limit 1
$$;

-- Depois de gerar a prévia, a referência da foto é apagada (LGPD)
create or replace function apagar_foto_cliente(p_registro_id bigint)
returns void
language sql
set search_path = public
as $$
  update whatsapp_mensagens
     set payload = (payload - 'image') || '{"foto_apagada": true}'::jsonb
   where id = p_registro_id
$$;

-- 7. Limpeza das conversas de teste também apaga o registro do WhatsApp -----
create or replace function limpar_whatsapp_teste(p_sessao text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_conversas int;
begin
  if p_sessao not like 'wa:%' then
    raise exception 'só limpa sessões do WhatsApp (wa:...)';
  end if;
  create temp table _alvo on commit drop as
    select c.id from conversas c join clientes cl on cl.id = c.cliente_id where cl.identificador = p_sessao;
  select count(*) into v_conversas from _alvo;
  update catalogo_variantes v set quantidade = v.quantidade + d.qtd
    from (select sku, sum(quantidade) as qtd from pedidos where conversa_id in (select id from _alvo) group by sku) d
   where v.sku = d.sku;
  delete from n8n_chat_histories where session_id in (select id::text from _alvo);
  delete from rastreio_avisos where pagamento_id in (select id from pagamentos where conversa_id in (select id from _alvo));
  delete from pagamentos where conversa_id in (select id from _alvo);
  delete from avaliacoes where conversa_id in (select id from _alvo);
  delete from interesses where conversa_id in (select id from _alvo);
  delete from pedidos    where conversa_id in (select id from _alvo);
  delete from conversas  where id in (select id from _alvo);
  delete from mensagens_saida where sessao = p_sessao;
  delete from whatsapp_mensagens where sessao = p_sessao;
  return jsonb_build_object('conversas_apagadas', v_conversas);
end $$;
