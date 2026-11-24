-- =====================================================================
-- Olden Sports - 12_lia_catalogo.sql
-- Passo 3 do guia: a Lia vende o catálogo completo (catalogo_produtos e
-- catalogo_variantes). Pedidos e interesses passam a aceitar os SKUs do
-- catálogo; os 8 produtos antigos da demonstração continuam funcionando.
-- Rode depois do 10 e das partes 11. Pode rodar de novo sem duplicar nada.
-- =====================================================================

-- ---------- Pedidos e interesses deixam de exigir os produtos antigos ----------
do $$
declare r record;
begin
  for r in
    select c.conname, c.conrelid::regclass as tabela
    from pg_constraint c
    where c.contype = 'f' and c.confrelid = 'produtos'::regclass
      and c.conrelid in ('pedidos'::regclass, 'interesses'::regclass)
  loop
    execute format('alter table %s drop constraint %I', r.tabela, r.conname);
  end loop;
end $$;

-- Nome do produto de um SKU (catálogo completo ou demonstração antiga)
create or replace function nome_produto(p_sku text)
returns text language sql stable set search_path = public as $$
  select coalesce(
    (select p.nome from catalogo_variantes v join catalogo_produtos p using (item_group_id) where v.sku = p_sku),
    (select p.nome from catalogo_produtos p where p.item_group_id = p_sku),
    (select nome from produtos where sku = p_sku),
    p_sku)
$$;

-- ---------- Pedido: preço e estoque vêm do catálogo completo ----------
-- Aceita o SKU do tamanho (OLD-5197) ou o modelo (OLD-P1293) + tamanho.
create or replace function trg_pedido_antes_inserir()
returns trigger language plpgsql set search_path = public, extensions as $$
declare
  v_var  catalogo_variantes%rowtype;
  v_cat  catalogo_produtos%rowtype;
  v_prod produtos%rowtype;
  v_qtd  int;
begin
  new.sku := upper(trim(new.sku));
  new.tamanho := nullif(upper(trim(coalesce(new.tamanho, ''))), '');
  new.forma_pagamento := lower(trim(new.forma_pagamento));

  -- modelo + tamanho: acha o SKU do tamanho
  if new.sku like 'OLD-P%' then
    select v.* into v_var from catalogo_variantes v
     where v.item_group_id = new.sku
       and f_unaccent(upper(v.tamanho)) = f_unaccent(coalesce(new.tamanho, ''))
     limit 1;
    if not found then
      raise exception 'O modelo % não tem o tamanho %. Confira os tamanhos com buscar_produtos.', new.sku, coalesce(new.tamanho, '(não informado)');
    end if;
    new.sku := v_var.sku;
  end if;

  select * into v_var from catalogo_variantes where sku = new.sku for update;
  if found then
    select * into v_cat from catalogo_produtos where item_group_id = v_var.item_group_id;
    if not v_cat.ativo or not v_var.disponivel or v_var.quantidade <= 0 then
      raise exception 'O tamanho % de % está esgotado.', v_var.tamanho, v_cat.nome;
    end if;
    if v_var.quantidade < new.quantidade then
      raise exception 'Estoque insuficiente de % tamanho %: restam % unidade(s).', v_cat.nome, v_var.tamanho, v_var.quantidade;
    end if;
    new.tamanho := upper(v_var.tamanho);
    new.valor_unitario := case when new.forma_pagamento = 'pix'
                               then coalesce(v_var.preco_pix, v_cat.preco_pix, nullif(v_var.preco_promocional, 0), v_var.preco, v_cat.preco)
                               else coalesce(nullif(v_var.preco_promocional, 0), v_var.preco, nullif(v_cat.preco_promocional, 0), v_cat.preco) end;
    new.valor_total := new.valor_unitario * new.quantidade;
    new.status := 'reservado';
    update catalogo_variantes set quantidade = quantidade - new.quantidade where sku = v_var.sku;
    return new;
  end if;

  -- demonstração antiga (8 produtos)
  select * into v_prod from produtos where sku = new.sku and ativo;
  if not found then
    raise exception 'Produto % não existe. Use o SKU que veio de buscar_produtos.', new.sku;
  end if;
  select quantidade into v_qtd from estoque where sku = new.sku and tamanho = new.tamanho for update;
  if not found then
    raise exception 'O produto % não tem o tamanho %.', new.sku, new.tamanho;
  end if;
  if v_qtd < new.quantidade then
    raise exception 'Estoque insuficiente de % tamanho %: restam % unidade(s).', new.sku, new.tamanho, v_qtd;
  end if;
  new.valor_unitario := case when new.forma_pagamento = 'pix' then v_prod.preco_pix else v_prod.preco end;
  new.valor_total := new.valor_unitario * new.quantidade;
  new.status := 'reservado';
  update estoque set quantidade = quantidade - new.quantidade where sku = new.sku and tamanho = new.tamanho;
  return new;
end $$;

-- Interesse: guarda o modelo (OLD-P...) quando vier o SKU de um tamanho
create or replace function trg_interesse_antes_inserir()
returns trigger language plpgsql set search_path = public as $$
begin
  new.sku := upper(trim(new.sku));
  select v.item_group_id into new.sku from catalogo_variantes v where v.sku = new.sku
  union all select new.sku limit 1;
  return new;
end $$;

-- ---------- Textos que citam produtos passam a usar nome_produto ----------
create or replace function situacao_pedido(p_conversa uuid)
returns text language plpgsql stable set search_path = public as $$
declare
  v_itens text;
  v_pag   pagamentos%rowtype;
  v_etapa text;
begin
  select string_agg(p.quantidade || 'x ' || nome_produto(p.sku) || ' tam. ' || p.tamanho
                    || ' (' || brl(p.valor_total) || ', ' || p.forma_pagamento || ')', '; ' order by p.criado_em)
    into v_itens
    from pedidos p
   where p.conversa_id = p_conversa;

  if v_itens is null then
    return 'Nenhum pedido registrado nesta conversa.';
  end if;

  select * into v_pag from pagamentos where conversa_id = p_conversa order by criado_em desc limit 1;

  if not found then
    return 'Itens reservados: ' || v_itens || '. Link de pagamento ainda NÃO foi gerado.';
  elsif v_pag.status = 'pendente' then
    return 'Itens reservados: ' || v_itens || '. Pagamento PENDENTE (ainda não pago). Valor: ' || brl(v_pag.valor)
        || '. Link: ' || url_base() || '/webhook/olden-pagamento?t=' || v_pag.token;
  elsif v_pag.status = 'recusado' then
    return 'Itens reservados: ' || v_itens || '. O último pagamento foi RECUSADO. Ofereça gerar um novo link.';
  end if;

  select etapa into v_etapa from eventos_rastreio(v_pag.codigo_rastreio) where concluida order by quando desc limit 1;
  return 'Itens: ' || v_itens || '. Pagamento APROVADO em ' || to_char(v_pag.pago_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')
      || '. Código de rastreio: ' || v_pag.codigo_rastreio
      || '. Link de rastreio: ' || url_base() || '/webhook/olden-rastreio?c=' || v_pag.codigo_rastreio
      || '. Situação atual da entrega: ' || coalesce(v_etapa, 'Pagamento aprovado') || '.';
end $$;

create or replace function aviso_rastreio(p_pagamento uuid, p_etapa text)
returns text language sql stable set search_path = public as $$
  select '[AVISO INTERNO] A entrega do pedido deste cliente avançou. Etapa atual: "' || p_etapa || '". '
      || 'Itens: ' || coalesce((select string_agg(pd.quantidade || 'x ' || nome_produto(pd.sku), '; ')
                                  from pedidos pd where pd.conversa_id = pg.conversa_id), 'pedido') || '. '
      || 'Código de rastreio: ' || pg.codigo_rastreio || '. '
      || 'Link de rastreio: ' || url_base() || '/webhook/olden-rastreio?c=' || pg.codigo_rastreio || '. '
      || case when p_etapa = 'Entregue'
              then 'Escreva agora ao cliente, por iniciativa sua, uma mensagem curta contando que o pedido foi entregue e perguntando se chegou tudo certinho.'
              else 'Escreva agora ao cliente, por iniciativa sua, uma mensagem curta contando a novidade e lembrando o link de rastreio.'
         end
      || ' Não peça avaliação de novo e não invente prazos.'
  from pagamentos pg where pg.id = p_pagamento
$$;

-- ---------- Bateria: fatos com o nome dos produtos ----------
create or replace function fatos_sessao(p_sessao text)
returns jsonb language sql stable set search_path = public as $$
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
    'status_final', (select status from cv order by iniciada_em desc limit 1)
  )
$$;

-- Limpeza devolve o estoque também no catálogo completo
create or replace function limpar_testes()
returns jsonb language plpgsql set search_path = public as $$
declare
  v_conversas int;
  v_pecas int;
begin
  create temp table _alvo on commit drop as
    select c.id from conversas c
    join clientes cl on cl.id = c.cliente_id
    where cl.identificador like 'teste:%';

  select count(*) into v_conversas from _alvo;
  select coalesce(sum(quantidade), 0) into v_pecas from pedidos where conversa_id in (select id from _alvo);

  update estoque e set quantidade = e.quantidade + d.qtd
  from (select sku, tamanho, sum(quantidade) as qtd from pedidos
        where conversa_id in (select id from _alvo) group by sku, tamanho) d
  where e.sku = d.sku and e.tamanho = d.tamanho;

  update catalogo_variantes v set quantidade = v.quantidade + d.qtd
  from (select sku, sum(quantidade) as qtd from pedidos
        where conversa_id in (select id from _alvo) group by sku) d
  where v.sku = d.sku;

  delete from n8n_chat_histories where session_id in (select id::text from _alvo);
  delete from rastreio_avisos where pagamento_id in (select id from pagamentos where conversa_id in (select id from _alvo));
  delete from pagamentos where conversa_id in (select id from _alvo);
  delete from avaliacoes where conversa_id in (select id from _alvo);
  delete from pedidos    where conversa_id in (select id from _alvo);
  delete from interesses where conversa_id in (select id from _alvo);
  delete from conversas  where id in (select id from _alvo);
  delete from clientes   where identificador like 'teste:%';
  delete from mensagens_saida where sessao like 'teste:%';

  return jsonb_build_object('conversas_apagadas', v_conversas, 'pecas_devolvidas_ao_estoque', v_pecas);
end $$;

-- ---------- Ferramentas da Lia ----------
-- Itens de uma vitrine montada pela Olden (mesmo formato de buscar_produtos)
create or replace function itens_vitrine(p_nome text, p_limite int default 10)
returns table (item_group_id text, nome text, preco numeric, preco_pix numeric, tamanhos text[], skus text[],
               resumo text, imagem text, url text)
language sql stable set search_path = public as $$
  select p.item_group_id, p.nome, coalesce(nullif(p.preco_promocional, 0), p.preco), p.preco_pix,
         array_agg(v.tamanho order by v.ordem), array_agg(v.sku order by v.ordem),
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

-- Dados para desenhar e conferir os blocos: recebe SKUs de tamanho ou de modelo
create or replace function produtos_para_blocos(p_skus jsonb)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_object_agg(x.chave, x.dados), '{}'::jsonb)
  from (
    select s.chave, jsonb_build_object(
             'item_group_id', p.item_group_id, 'nome', p.nome,
             'preco', coalesce(nullif(p.preco_promocional, 0), p.preco), 'preco_original', p.preco,
             'preco_pix', p.preco_pix, 'parcelamento', p.parcelamento,
             'imagem', p.imagens->0->>'url', 'imagens', p.imagens, 'video', p.video_url, 'url', p.url,
             'tamanho', v.tamanho,
             'tamanhos', (select jsonb_agg(v2.tamanho order by v2.ordem) from catalogo_variantes v2
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

-- O prompt pode citar {{departamentos}} e {{vitrines}} (montados a cada mensagem)
create or replace function prompt_montado(p_cliente_nome text, p_status text, p_situacao text, p_catalogo text)
returns text language sql stable set search_path = public as $$
  select replace(replace(replace(replace(replace(replace(replace(
           coalesce((select texto from prompt_agente where ativo), 'Você é a Lia, do atendimento da Olden Sports.'),
           '{{agora}}', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')),
           '{{cliente_nome}}', coalesce(nullif(p_cliente_nome, ''), 'ainda não informado')),
           '{{situacao_pedido}}', coalesce(p_situacao, '')),
           '{{status}}', coalesce(p_status, '')),
           '{{catalogo}}', coalesce(p_catalogo, '')),
           '{{departamentos}}', coalesce((select string_agg(departamento || ' (' || modelos || ' modelos)', ', ')
                                            from departamentos_catalogo), 'catálogo ainda não carregado')),
           '{{vitrines}}', coalesce((select string_agg(nome || ': ' || titulo, '; ' order by ordem)
                                       from vitrines where ativa), 'nenhuma'))
$$;

revoke execute on function produtos_para_blocos(jsonb) from public;
revoke execute on function itens_vitrine(text, int) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function produtos_para_blocos(jsonb) from anon, authenticated';
    execute 'revoke execute on function itens_vitrine(text, int) from anon, authenticated';
  end if;
end $$;

-- ---------- Cenários: produtos do catálogo real ----------
-- As checagens passam a usar o nome do produto (não mais os SKUs antigos).
update cenarios_teste set esperado = jsonb_build_object(
    'interesses_nomes', '["Celebration"]'::jsonb, 'pedidos_qtd', 1,
    'pedido', '{"nome_contem": "Celebration", "tamanho": "G", "quantidade": 1, "forma_pagamento": "pix"}'::jsonb,
    'pagamento_status', 'pago', 'rastreio_no_texto', true, 'avaliacao_nota', 5, 'status_final', 'encerrada')
where id = 'C01';
update cenarios_teste set esperado = '{"interesses_nomes": ["Polo 1914 Palestra Verde", "Tech Azul"], "pedidos_qtd": 0}' where id = 'C02';
update cenarios_teste set esperado = '{"interesses_nomes": ["Baby Look"], "pedidos_qtd": 1, "pedido": {"nome_contem": "Baby Look", "tamanho": "M", "quantidade": 8, "forma_pagamento": "cartao"}, "status_final": "aguardando_pagamento"}' where id = 'C03';
update cenarios_teste set esperado = '{"interesses_nomes": ["Tech Verde"], "pedidos_qtd": 0}' where id = 'C06';
update cenarios_teste set esperado = '{"interesses_nomes": ["Body"], "pedidos_qtd": 0}',
  criterios_juiz = 'Responde com os tamanhos realmente disponíveis do body (conferir na busca) e a indicação de idade da descrição, sem prometer que serve em 1 ano se a descrição não disser. Não despeja preço e medidas sem necessidade.'
where id = 'C09';
update cenarios_teste set esperado = '{"interesses_nomes": ["Lenço"], "pedidos_qtd": 0}' where id = 'C10';
update cenarios_teste set esperado = '{"interesses_nomes": ["Polo 1914 Palestra Verde"], "pedidos_qtd": 1, "pedido": {"nome_contem": "Polo 1914 Palestra Verde", "tamanho": "GG", "quantidade": 1, "forma_pagamento": "cartao"}, "pagamento_status": "pago", "rastreio_no_texto": true, "avaliacao_nota": 4, "status_final": "encerrada"}' where id = 'C11';
update cenarios_teste set turnos = '["Quero o vestido infantil do Palmeiras, tamanho 8, no Pix, meu nome é Júlia", "Na verdade espera, vou ver com minha esposa antes"]',
  esperado = '{"interesses_nomes": ["Vestido"], "pedidos_qtd": 0, "status_final": "aberta"}' where id = 'C12';
update cenarios_teste set esperado = '{"interesses_nomes": ["Celebration", "Lenço"], "pedidos_qtd": 2, "status_final": "aguardando_pagamento"}' where id = 'C14';
update cenarios_teste set esperado = '{"pedidos_qtd": 0}', turnos = '["Quero o body de bebê do Palmeiras, tamanho M, no cartão, meu nome é Lara", "Pode confirmar", "#pagamento_recusado", "Poxa, e agora?"]' where id = 'C23';
update cenarios_teste set esperado = '{"pedidos_qtd": 1, "pagamento_status": "pago", "rastreio_no_texto": true}',
  turnos = '["Quero a baby look do Palmeiras tamanho M no Pix, meu nome é Bia", "Confirmo", "#pagamento_aprovado", "Oba! E quando chega?"]' where id = 'C24';
update cenarios_teste set esperado = '{"pedidos_qtd": 1, "pagamento_status": "pago", "rastreio_no_texto": true}' where id = 'C25';
update cenarios_teste set esperado = '{"pedidos_qtd": 1}' where id = 'C22';
-- Preços citados nos critérios: o avaliador confere com o catálogo, que vai junto nos fatos
update cenarios_teste set criterios_juiz = replace(criterios_juiz, 'Informa R$ ', 'Informa (conferir com o catálogo) R$ ');

insert into cenarios_teste (id, titulo, turnos, esperado, criterios_juiz) values
('C26', 'Quer conhecer os produtos, sem filtro',
 '["Oi! Queria ver umas coisas de vocês"]',
 '{"pedidos_qtd": 0, "blocos_incluem": ["menu"]}',
 'Cumprimenta curto e manda um MENU de departamentos (bloco menu), sem despejar produtos nem preços. Pode oferecer também o catálogo completo.'),
('C27', 'Pede uma camisa específica',
 '["Quero a camisa verde de jogo do Palmeiras"]',
 '{"pedidos_qtd": 0, "blocos_incluem_um": ["produto", "carrossel_produtos"]}',
 'Usa a busca e mostra a peça em um bloco produto ou carrossel_produtos com no máximo 3 opções, todas reais e com estoque. Pergunta o tamanho ou se quer ver mais.'),
('C28', 'Quer ver tudo de um departamento',
 '["Quero ver tudo de feminino"]',
 '{"pedidos_qtd": 0, "blocos_incluem_um": ["vitrine", "catalogo", "carrossel_produtos"]}',
 'Mostra uma vitrine (até 30 peças em seções) ou o botão do catálogo, só com peças femininas reais e com estoque.'),
('C30', 'Não sabe o tamanho',
 '["Gostei da Palestra Celebration, mas não sei meu tamanho"]',
 '{"pedidos_qtd": 0}',
 'Ajuda a escolher o tamanho: pergunta altura e peso ou usa as medidas da descrição. Não inventa tabela de medidas.'),
('C34', 'Pede peça esgotada',
 '["Quero a Baby Look 1914 Símbolo Branca do Palmeiras no tamanho P"]',
 '{"pedidos_qtd": 0}',
 'Avisa que o tamanho P está esgotado (conferir na busca) e oferece os tamanhos disponíveis ou peça parecida. Não mostra o tamanho esgotado como disponível.'),
('C36', 'Torcedor de outro time',
 '["Fala! Sou flamenguista doente, tem camisa do Mengão?"]',
 '{"pedidos_qtd": 0, "blocos_incluem_um": ["produto", "carrossel_produtos", "vitrine"]}',
 'Entra no modo torcida DO FLAMENGO (não do Palmeiras), com respeito e sem provocar rivais. Mostra camisas reais do Flamengo com estoque.')
on conflict (id) do update set
  titulo = excluded.titulo, turnos = excluded.turnos, esperado = excluded.esperado,
  criterios_juiz = excluded.criterios_juiz;
