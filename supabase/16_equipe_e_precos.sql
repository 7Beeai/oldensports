-- =====================================================================
-- Olden Sports - 16_equipe_e_precos.sql
-- 1. A Lia passa casos para a equipe de verdade (chamar_equipe), com aviso
--    no WhatsApp do número cadastrado em configuracao.equipe_whatsapp.
-- 2. Busca e vitrine trazem o preço "de" (preco_de) dos produtos em promoção.
-- 3. registrar_interesse só aceita códigos de produto que existem.
-- Pode rodar mais de uma vez.
-- =====================================================================

-- 1. Chamados para a equipe ------------------------------------------------
alter table conversas drop constraint if exists conversas_status_check;
alter table conversas add constraint conversas_status_check
  check (status in ('aberta', 'aguardando_pagamento', 'aguardando_avaliacao', 'aguardando_equipe', 'encerrada'));

create table if not exists chamados_equipe (
  id           bigserial primary key,
  conversa_id  uuid references conversas (id) on delete cascade,
  sessao       text,
  motivo       text not null,       -- troca, devolucao, reclamacao, atraso, pedido_antigo, pagamento, pediu_humano, outro
  resumo       text,
  referencia   text,                -- número do pedido, e-mail da compra etc., do jeito que o cliente passou
  status       text not null default 'aberto' check (status in ('aberto', 'resolvido')),
  criado_em    timestamptz not null default now(),
  resolvido_em timestamptz
);
create index if not exists chamados_equipe_abertos on chamados_equipe (status, criado_em desc);

insert into configuracao (chave, valor) values ('equipe_whatsapp', '5531997067742')
on conflict (chave) do nothing;

create or replace function chamar_equipe(p_conversa_id uuid, p_motivo text, p_resumo text, p_referencia text default null)
returns text
language plpgsql
set search_path = public
as $$
declare
  v_ident   text;
  v_nome    text;
  v_status  text;
  v_id      bigint;
  v_equipe  text;
  v_contato text;
begin
  select cl.identificador, cl.nome, c.status into v_ident, v_nome, v_status
    from conversas c join clientes cl on cl.id = c.cliente_id where c.id = p_conversa_id;
  if v_ident is null then
    return 'Erro: conversa não encontrada.';
  end if;

  -- Mesmo assunto já chamado e ainda aberto: não duplica
  select id into v_id from chamados_equipe
   where conversa_id = p_conversa_id and status = 'aberto' and motivo = coalesce(nullif(p_motivo, ''), 'outro')
   order by id desc limit 1;
  if v_id is not null then
    return 'A equipe já foi avisada deste caso (chamado #' || v_id || '). Diga ao cliente que já está com a equipe e que eles respondem por aqui, sem prometer prazo.';
  end if;

  insert into chamados_equipe (conversa_id, sessao, motivo, resumo, referencia)
  values (p_conversa_id, v_ident, coalesce(nullif(p_motivo, ''), 'outro'), p_resumo, nullif(p_referencia, ''))
  returning id into v_id;

  if v_status = 'aberta' then
    update conversas set status = 'aguardando_equipe' where id = p_conversa_id;
  end if;

  -- Aviso no WhatsApp da equipe (não para conversas de teste automático)
  v_equipe := regexp_replace(coalesce((select valor from configuracao where chave = 'equipe_whatsapp'), ''), '\D', '', 'g');
  if v_equipe <> '' and v_ident not like 'teste:%' then
    v_contato := case when v_ident like 'wa:%' then '+' || substr(v_ident, 4) || ' (wa.me/' || substr(v_ident, 4) || ')'
                      else v_ident || ' (chat do site)' end;
    insert into mensagens_saida (sessao, texto)
    values ('wa:' || v_equipe,
            '🔔 *Chamado #' || v_id || ' da Lia*' || E'\n'
            || 'Cliente: ' || coalesce(nullif(v_nome, ''), 'sem nome') || ' · ' || v_contato || E'\n'
            || 'Motivo: ' || coalesce(nullif(p_motivo, ''), 'outro') || E'\n'
            || coalesce('Referência: ' || nullif(p_referencia, '') || E'\n', '')
            || 'Resumo: ' || coalesce(p_resumo, '') || E'\n\n'
            || 'Para encerrar: select resolver_chamado(' || v_id || ');');
  end if;

  return 'Equipe avisada (chamado #' || v_id || '). Diga ao cliente, numa frase, que a equipe já foi avisada e responde por aqui. Não prometa prazo nem solução.';
end $$;

create or replace function resolver_chamado(p_id bigint)
returns text
language plpgsql
set search_path = public
as $$
declare v_conversa uuid;
begin
  update chamados_equipe set status = 'resolvido', resolvido_em = now()
   where id = p_id and status = 'aberto' returning conversa_id into v_conversa;
  if v_conversa is null then return 'Chamado não encontrado ou já resolvido.'; end if;
  if not exists (select 1 from chamados_equipe where conversa_id = v_conversa and status = 'aberto') then
    update conversas set status = 'aberta' where id = v_conversa and status = 'aguardando_equipe';
  end if;
  return 'Chamado #' || p_id || ' resolvido.';
end $$;

-- Os fatos da conversa (usados pelos testes) passam a mostrar os chamados
create or replace function fatos_sessao(p_sessao text)
returns jsonb
language sql
stable
set search_path = public
as $$
  with cv as (
    select c.* from conversas c
    join clientes cl on cl.id = c.cliente_id
    where cl.identificador = p_sessao
  )
  select jsonb_build_object(
    'interesses', coalesce((select jsonb_agg(distinct nome_produto(i.sku)) from interesses i where i.conversa_id in (select id from cv)), '[]'::jsonb),
    'interesses_sku', coalesce((select jsonb_agg(distinct i.sku) from interesses i where i.conversa_id in (select id from cv)), '[]'::jsonb),
    'pedidos', coalesce((select jsonb_agg(jsonb_build_object(
        'sku', p.sku, 'produto', nome_produto(p.sku), 'tamanho', p.tamanho, 'quantidade', p.quantidade,
        'forma_pagamento', p.forma_pagamento, 'nome_cliente', p.nome_cliente,
        'valor_total', p.valor_total, 'status', p.status) order by p.criado_em)
      from pedidos p where p.conversa_id in (select id from cv)), '[]'::jsonb),
    'pagamentos', coalesce((select jsonb_agg(jsonb_build_object(
        'status', pg.status, 'valor', pg.valor, 'codigo_rastreio', pg.codigo_rastreio) order by pg.criado_em)
      from pagamentos pg where pg.conversa_id in (select id from cv)), '[]'::jsonb),
    'avaliacoes', coalesce((select jsonb_agg(jsonb_build_object('nota', a.nota, 'comentario', a.comentario))
      from avaliacoes a where a.conversa_id in (select id from cv)), '[]'::jsonb),
    'chamados_equipe', coalesce((select jsonb_agg(jsonb_build_object('motivo', ch.motivo, 'resumo', ch.resumo, 'referencia', ch.referencia) order by ch.id)
      from chamados_equipe ch where ch.conversa_id in (select id from cv)), '[]'::jsonb),
    'status_final', (select status from cv order by iniciada_em desc limit 1)
  )
$$;

-- 2. Preço "de" na busca e na vitrine --------------------------------------
drop function if exists buscar_produtos(text, jsonb, integer);
create function buscar_produtos(consulta text default '', filtros jsonb default '{}'::jsonb, limite integer default 5)
returns table (item_group_id text, nome text, preco numeric, preco_de numeric, preco_pix numeric, tamanhos text[], skus text[],
               resumo text, imagem text, url text, relevancia real)
language sql
stable
set search_path = public, extensions
as $$
  with q as (
    select nullif(trim(coalesce(consulta, '')), '') as texto,
           case when nullif(trim(coalesce(consulta, '')), '') is null then null
                else nullif(replace(plainto_tsquery('portuguese', f_unaccent(consulta))::text, ' & ', ' | '), '')::tsquery
           end as tsq
  ),
  candidatos as (
    select p.*,
           case when q.texto is null then 0
                else coalesce(ts_rank(p.busca, q.tsq), 0)
                     + similarity(f_unaccent(lower(p.nome)), f_unaccent(lower(q.texto)))
           end as rel
    from catalogo_produtos p, q
    where p.ativo
      and (filtros->>'departamento' is null or p.departamento = filtros->>'departamento')
      and (filtros->>'categoria'    is null or f_unaccent(lower(p.categoria)) = f_unaccent(lower(filtros->>'categoria')))
      and (filtros->>'clube'        is null or f_unaccent(lower(p.clube))     = f_unaccent(lower(filtros->>'clube')))
      and (filtros->>'genero'       is null or p.genero = filtros->>'genero')
      and (filtros->>'faixa_etaria' is null or p.faixa_etaria = filtros->>'faixa_etaria')
      and (filtros->>'preco_max'    is null or coalesce(p.preco_pix, p.preco) <= (filtros->>'preco_max')::numeric)
      and (q.texto is null
           or (q.tsq is not null and p.busca @@ q.tsq)
           or similarity(f_unaccent(lower(p.nome)), f_unaccent(lower(q.texto))) > 0.2)
  )
  select c.item_group_id, c.nome, coalesce(nullif(c.preco_promocional, 0), c.preco),
         case when coalesce(c.preco_promocional, 0) > 0 and c.preco_promocional < c.preco then c.preco end,
         c.preco_pix, array_agg(v.tamanho order by v.ordem), array_agg(v.sku order by v.ordem),
         left(c.descricao, 200), c.imagens->0->>'url', c.url, c.rel::real
  from candidatos c
  join catalogo_variantes v on v.item_group_id = c.item_group_id and v.disponivel and v.quantidade > 0
  where (filtros->>'tamanho' is null
         or exists (select 1 from catalogo_variantes v2
                     where v2.item_group_id = c.item_group_id and v2.disponivel and v2.quantidade > 0
                       and upper(v2.tamanho) = upper(filtros->>'tamanho')))
  group by c.item_group_id, c.nome, c.preco, c.preco_promocional, c.preco_pix, c.descricao, c.imagens, c.url, c.rel, c.destaque, c.lancamento
  order by c.rel desc, c.destaque desc, c.lancamento desc, c.nome
  limit least(greatest(coalesce(limite, 5), 1), 10)
$$;

drop function if exists itens_vitrine(text, integer);
create function itens_vitrine(p_nome text, p_limite integer default 10)
returns table (item_group_id text, nome text, preco numeric, preco_de numeric, preco_pix numeric, tamanhos text[], skus text[],
               resumo text, imagem text, url text)
language sql
stable
set search_path = public
as $$
  select p.item_group_id, p.nome, coalesce(nullif(p.preco_promocional, 0), p.preco),
         case when coalesce(p.preco_promocional, 0) > 0 and p.preco_promocional < p.preco then p.preco end,
         p.preco_pix, array_agg(v.tamanho order by v.ordem), array_agg(v.sku order by v.ordem),
         left(p.descricao, 200), p.imagens->0->>'url', p.url
  from vitrines vt
  cross join lateral unnest(vt.modelos) with ordinality as m(grupo, pos)
  join catalogo_produtos p on p.item_group_id = m.grupo and p.ativo
  join catalogo_variantes v on v.item_group_id = p.item_group_id and v.disponivel and v.quantidade > 0
  where vt.nome = p_nome and vt.ativa
  group by p.item_group_id, p.nome, p.preco, p.preco_promocional, p.preco_pix, p.descricao, p.imagens, p.url, m.pos
  order by m.pos
  limit least(greatest(coalesce(p_limite, 10), 1), 30)
$$;

-- 3. Interesse só com código de produto que existe -------------------------
create or replace function registrar_interesse(p_conversa_id uuid, p_sku text)
returns text
language plpgsql
set search_path = public
as $$
declare v_sku text := upper(trim(coalesce(p_sku, '')));
begin
  if not exists (select 1 from catalogo_produtos where item_group_id = v_sku)
     and not exists (select 1 from catalogo_variantes where sku = v_sku)
     and not exists (select 1 from produtos where sku = v_sku) then
    return 'Não registrado: "' || coalesce(p_sku, '') || '" não é um código de produto. Use só códigos OLD-... que vieram da busca. Para troca, reclamação ou pedido, use chamar_equipe.';
  end if;
  insert into interesses (conversa_id, sku) values (p_conversa_id, v_sku);
  return 'interesse registrado: ' || v_sku;
end $$;
