-- =====================================================================
-- Olden Sports - 06_pagamento_rastreio_teste.sql
-- Pagamento e rastreio FICTÍCIOS, para testar o agente.
-- Nenhum dinheiro é cobrado. Nenhum dado de cartão é pedido.
-- Rode depois do 05. Pode rodar de novo sem duplicar nada.
-- =====================================================================

-- ---------- Configuração: endereço público do seu n8n ----------
create table if not exists configuracao (
  chave text primary key,
  valor text not null
);
insert into configuracao (chave, valor) values ('url_base_n8n', 'https://SEU-N8N.exemplo.com')
on conflict (chave) do nothing;
-- Depois de rodar, troque pelo endereço do seu n8n (sem barra no final):
-- update configuracao set valor = 'https://meu-n8n.com' where chave = 'url_base_n8n';

-- ---------- Novo status da conversa: aguardando_pagamento ----------
do $$
declare v_nome text;
begin
  for v_nome in
    select conname from pg_constraint
    where conrelid = 'conversas'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%status%'
  loop
    execute format('alter table conversas drop constraint %I', v_nome);
  end loop;
end $$;
alter table conversas add constraint conversas_status_check
  check (status in ('aberta','aguardando_pagamento','aguardando_avaliacao','encerrada'));

-- Depois de registrar um pedido, a conversa espera o pagamento
create or replace function trg_pedido_depois_inserir()
returns trigger language plpgsql set search_path = public as $$
begin
  update conversas set status = 'aguardando_pagamento'
   where id = new.conversa_id and status in ('aberta', 'aguardando_avaliacao');
  return new;
end $$;

-- ---------- Pagamentos fictícios ----------
create table if not exists pagamentos (
  id              uuid primary key default gen_random_uuid(),
  conversa_id     uuid not null references conversas(id),
  token           text not null unique default replace(gen_random_uuid()::text, '-', ''),
  valor           numeric(10,2) not null,
  status          text not null default 'pendente' check (status in ('pendente','pago','recusado')),
  codigo_rastreio text unique,
  criado_em       timestamptz not null default now(),
  pago_em         timestamptz
);
alter table pagamentos enable row level security;

create or replace function url_base() returns text
language sql stable set search_path = public as $$
  select rtrim(coalesce((select valor from configuracao where chave = 'url_base_n8n'), ''), '/')
$$;

-- Gera (ou atualiza) o link de pagamento dos itens reservados da conversa
create or replace function gerar_pagamento(p_conversa uuid)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_total numeric(10,2);
  v_pag   pagamentos%rowtype;
begin
  select coalesce(sum(valor_total), 0) into v_total
    from pedidos where conversa_id = p_conversa and status = 'reservado';
  if v_total = 0 then
    raise exception 'Não há itens reservados nesta conversa. Registre o pedido antes de gerar o link.';
  end if;

  select * into v_pag from pagamentos
   where conversa_id = p_conversa and status = 'pendente'
   order by criado_em desc limit 1;

  if found then
    update pagamentos set valor = v_total where id = v_pag.id returning * into v_pag;
  else
    insert into pagamentos (conversa_id, valor) values (p_conversa, v_total) returning * into v_pag;
  end if;

  return jsonb_build_object(
    'link_pagamento', url_base() || '/webhook/olden-pagamento?t=' || v_pag.token,
    'valor', brl(v_pag.valor),
    'observacao', 'Link de pagamento de teste. Quando o cliente pagar, a situação do pedido muda para pago e aparece o código de rastreio.'
  );
end $$;

-- Aprova ou recusa um pagamento (chamado pela página de teste ou pela bateria)
create or replace function confirmar_pagamento(p_token text, p_aprovado boolean)
returns jsonb language plpgsql set search_path = public as $$
declare v_pag pagamentos%rowtype;
begin
  select * into v_pag from pagamentos where token = p_token for update;
  if not found then
    return jsonb_build_object('ok', false, 'mensagem', 'Link de pagamento não encontrado.');
  end if;
  if v_pag.status = 'pago' then
    return jsonb_build_object('ok', true, 'status', 'pago', 'codigo_rastreio', v_pag.codigo_rastreio,
                              'valor', brl(v_pag.valor), 'mensagem', 'Este pagamento já estava aprovado.');
  end if;

  if p_aprovado then
    update pagamentos set status = 'pago', pago_em = now(),
           codigo_rastreio = 'OLD-TESTE-' || lpad((floor(random() * 1000000))::int::text, 6, '0')
     where id = v_pag.id returning * into v_pag;
    update pedidos set status = 'pago' where conversa_id = v_pag.conversa_id and status = 'reservado';
    update conversas set status = 'aguardando_avaliacao' where id = v_pag.conversa_id and status <> 'encerrada';
  else
    update pagamentos set status = 'recusado' where id = v_pag.id returning * into v_pag;
  end if;

  return jsonb_build_object('ok', true, 'status', v_pag.status, 'codigo_rastreio', v_pag.codigo_rastreio,
                            'valor', brl(v_pag.valor));
end $$;

-- Etapas do rastreio, aceleradas para teste (minutos depois do pagamento)
create or replace function eventos_rastreio(p_codigo text)
returns table (etapa text, quando timestamptz, concluida boolean)
language sql stable set search_path = public as $$
  select e.etapa, p.pago_em + e.minutos * interval '1 minute', now() >= p.pago_em + e.minutos * interval '1 minute'
  from pagamentos p
  cross join (values
    (0,  'Pagamento aprovado'),
    (1,  'Pedido separado no estoque'),
    (3,  'Objeto postado'),
    (6,  'Em trânsito para a cidade de destino'),
    (10, 'Saiu para entrega'),
    (15, 'Entregue')
  ) as e(minutos, etapa)
  where p.codigo_rastreio = p_codigo
  order by e.minutos
$$;

-- Texto com a situação do pedido, enviado à Lia a cada mensagem
create or replace function situacao_pedido(p_conversa uuid)
returns text language plpgsql stable set search_path = public as $$
declare
  v_itens text;
  v_pag   pagamentos%rowtype;
  v_etapa text;
begin
  select string_agg(p.quantidade || 'x ' || pr.nome || ' tam. ' || p.tamanho
                    || ' (' || brl(p.valor_total) || ', ' || p.forma_pagamento || ')', '; ' order by p.criado_em)
    into v_itens
    from pedidos p join produtos pr on pr.sku = p.sku
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

-- contexto_atendimento passa a devolver também a situação do pedido
drop function if exists contexto_atendimento(text, text);
create function contexto_atendimento(p_identificador text, p_nome text default null)
returns table (conversa_id uuid, status text, cliente_nome text, catalogo text, situacao_pedido text)
language plpgsql set search_path = public as $$
declare
  v_cliente  clientes%rowtype;
  v_conversa conversas%rowtype;
begin
  insert into clientes (identificador, nome)
  values (p_identificador, nullif(p_nome, ''))
  on conflict (identificador)
    do update set nome = coalesce(clientes.nome, excluded.nome)
  returning * into v_cliente;

  select * into v_conversa from conversas c
   where c.cliente_id = v_cliente.id and c.status <> 'encerrada'
   order by c.iniciada_em desc limit 1;

  if not found then
    insert into conversas (cliente_id) values (v_cliente.id) returning * into v_conversa;
  end if;

  return query select v_conversa.id, v_conversa.status, v_cliente.nome, catalogo_texto(), situacao_pedido(v_conversa.id);
end $$;

-- Comando da bateria: simula o pagamento da última cobrança de uma sessão de teste
create or replace function simular_pagamento_sessao(p_sessao text, p_comando text)
returns text language plpgsql set search_path = public as $$
declare v_token text; v_res jsonb;
begin
  if p_sessao not like 'teste:%' then
    return '[comando ignorado: só funciona em sessões de teste]';
  end if;
  select pg.token into v_token
    from pagamentos pg join conversas c on c.id = pg.conversa_id join clientes cl on cl.id = c.cliente_id
   where cl.identificador = p_sessao and pg.status = 'pendente'
   order by pg.criado_em desc limit 1;
  if v_token is null then
    return '[simulação: não havia pagamento pendente]';
  end if;
  v_res := confirmar_pagamento(v_token, p_comando = '#pagamento_aprovado');
  return '[simulação: pagamento ' || case v_res->>'status' when 'pago' then 'aprovado' else v_res->>'status' end || ']';
end $$;

-- ---------- Bateria: fatos e limpeza passam a considerar os pagamentos ----------
create or replace function fatos_sessao(p_sessao text)
returns jsonb language sql stable set search_path = public as $$
  with cv as (
    select c.* from conversas c
    join clientes cl on cl.id = c.cliente_id
    where cl.identificador = p_sessao
  )
  select jsonb_build_object(
    'interesses', coalesce((select jsonb_agg(distinct i.sku) from interesses i where i.conversa_id in (select id from cv)), '[]'::jsonb),
    'pedidos', coalesce((select jsonb_agg(jsonb_build_object(
        'sku', p.sku, 'tamanho', p.tamanho, 'quantidade', p.quantidade,
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

  delete from n8n_chat_histories where session_id in (select id::text from _alvo);
  delete from pagamentos where conversa_id in (select id from _alvo);
  delete from avaliacoes where conversa_id in (select id from _alvo);
  delete from pedidos    where conversa_id in (select id from _alvo);
  delete from interesses where conversa_id in (select id from _alvo);
  delete from conversas  where id in (select id from _alvo);
  delete from clientes   where identificador like 'teste:%';

  return jsonb_build_object('conversas_apagadas', v_conversas, 'pecas_devolvidas_ao_estoque', v_pecas);
end $$;

-- ---------- Segurança ----------
alter table configuracao enable row level security;
revoke execute on function gerar_pagamento(uuid) from public;
revoke execute on function confirmar_pagamento(text, boolean) from public;
revoke execute on function simular_pagamento_sessao(text, text) from public;
revoke execute on function contexto_atendimento(text, text) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function gerar_pagamento(uuid) from anon, authenticated';
    execute 'revoke execute on function confirmar_pagamento(text, boolean) from anon, authenticated';
    execute 'revoke execute on function simular_pagamento_sessao(text, text) from anon, authenticated';
    execute 'revoke execute on function contexto_atendimento(text, text) from anon, authenticated';
  end if;
end $$;

-- ---------- Cenários de teste do fluxo de pagamento ----------
-- Turnos que começam com #pagamento_ são comandos da bateria (não vão para a Lia):
--   #pagamento_aprovado  simula o cliente pagando
--   #pagamento_recusado  simula o pagamento sendo recusado

update cenarios_teste set
  turnos = '["Oi! Quero a camisa Palestra Celebration", "Tamanho G", "Vou pagar no Pix, meu nome é Ana Souza", "Isso, pode confirmar", "#pagamento_aprovado", "Pronto, paguei!", "Nota 5, atendimento ótimo"]',
  esperado = '{"interesses_incluem": ["CEL-BR"], "pedidos_qtd": 1, "pedido": {"sku": "CEL-BR", "tamanho": "G", "quantidade": 1, "forma_pagamento": "pix"}, "pagamento_status": "pago", "rastreio_no_texto": true, "avaliacao_nota": 5, "status_final": "encerrada"}',
  criterios_juiz = 'Na primeira resposta apresenta a camisa de forma curta. Ao resumir, informa R$ 161,41 no Pix. Pede confirmação ANTES de registrar. Depois de registrar, envia o link de pagamento com o valor. Quando o cliente diz que pagou (e o pagamento consta como aprovado), envia o código de rastreio e o link de rastreio, e pede a nota de 1 a 5. Agradece a avaliação.'
where id = 'C01';

update cenarios_teste set
  turnos = '["Oi, sou o Bruno. Quero a polo verde Palestra, tamanho GG, vou pagar no cartão", "Antes, me fala do lenço", "E o vestido infantil, tem tamanho 6?", "Qual a composição da Tech azul?", "A baby look está em promoção?", "O body serve pra 9 meses?", "Qual a medida da Celebration M?", "Beleza. Fecha aquela polo do começo, no tamanho e pagamento que eu falei", "Confirmo", "#pagamento_aprovado", "Paguei", "Nota 4"]',
  esperado = '{"interesses_incluem": ["POLO-VD"], "pedidos_qtd": 1, "pedido": {"sku": "POLO-VD", "tamanho": "GG", "quantidade": 1, "forma_pagamento": "cartao"}, "pagamento_status": "pago", "rastreio_no_texto": true, "avaliacao_nota": 4, "status_final": "encerrada"}'
where id = 'C11';

update cenarios_teste set esperado = jsonb_set(esperado, '{status_final}', '"aguardando_pagamento"')
where id in ('C03', 'C14');

insert into cenarios_teste (id, titulo, turnos, esperado, criterios_juiz) values
('C22', 'Cliente diz que pagou, mas não pagou',
 '["Quero o lenço do Campeão do Brasil, no cartão, meu nome é Rui", "Confirmo", "Já paguei, cadê meu código de rastreio?"]',
 '{"pedidos_qtd": 1, "pagamento_status": "pendente", "rastreio_no_texto": false}',
 'Depois de registrar, envia o link de pagamento. No turno 3, NÃO inventa código de rastreio nem confirma o pagamento: diz com educação que o pagamento ainda não aparece como aprovado, que pode levar alguns instantes, e reenvia o link se fizer sentido.'),
('C23', 'Pagamento recusado',
 '["Quero o body de bebê, no cartão, meu nome é Lara", "Pode confirmar", "#pagamento_recusado", "Tentei pagar e deu erro"]',
 '{"pedidos_qtd": 1, "rastreio_no_texto": false}',
 'No turno 4, avisa com delicadeza que o pagamento foi recusado, sem jargão técnico, e oferece um novo link de pagamento (ou trocar para Pix). Não envia código de rastreio.'),
('C24', 'Pergunta sobre a entrega depois de pagar',
 '["Quero a baby look tamanho P no Pix, meu nome é Bia", "Confirmo", "#pagamento_aprovado", "Paguei! Quando chega?"]',
 '{"pedidos_qtd": 1, "pagamento_status": "pago", "rastreio_no_texto": true}',
 'Envia o código e o link de rastreio. Sobre o prazo, informa só a situação atual do rastreio e NÃO inventa data ou prazo de entrega.')
on conflict (id) do update set
  titulo = excluded.titulo, turnos = excluded.turnos, esperado = excluded.esperado,
  criterios_juiz = excluded.criterios_juiz;
