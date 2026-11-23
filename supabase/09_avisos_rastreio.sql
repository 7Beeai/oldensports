-- =====================================================================
-- Olden Sports - 09_avisos_rastreio.sql
-- A Lia avisa o cliente sozinha a cada etapa nova do rastreio (fictício).
-- Rode depois do 08. Pode rodar de novo sem duplicar nada.
-- =====================================================================

-- ---------- Intervalo entre as etapas (em minutos) ----------
insert into configuracao (chave, valor) values ('minutos_por_etapa_rastreio', '2')
on conflict (chave) do nothing;
-- Para mudar: update configuracao set valor = '5' where chave = 'minutos_por_etapa_rastreio';

create or replace function minutos_por_etapa() returns numeric
language sql stable set search_path = public as $$
  select coalesce((select nullif(valor, '')::numeric from configuracao where chave = 'minutos_por_etapa_rastreio'), 2)
$$;

-- Etapas do rastreio: uma a cada N minutos depois do pagamento
create or replace function eventos_rastreio(p_codigo text)
returns table (etapa text, quando timestamptz, concluida boolean)
language sql stable set search_path = public as $$
  select e.etapa,
         p.pago_em + e.ordem * minutos_por_etapa() * interval '1 minute',
         now() >= p.pago_em + e.ordem * minutos_por_etapa() * interval '1 minute'
  from pagamentos p
  cross join (values
    (0, 'Pagamento aprovado'),
    (1, 'Pedido separado no estoque'),
    (2, 'Objeto postado'),
    (3, 'Em trânsito para a cidade de destino'),
    (4, 'Saiu para entrega'),
    (5, 'Entregue')
  ) as e(ordem, etapa)
  where p.codigo_rastreio = p_codigo
  order by e.ordem
$$;

-- ---------- Etapas já avisadas ao cliente ----------
create table if not exists rastreio_avisos (
  pagamento_id uuid not null references pagamentos(id) on delete cascade,
  etapa        text not null,
  avisado_em   timestamptz not null default now(),
  primary key (pagamento_id, etapa)
);
alter table rastreio_avisos enable row level security;

-- Texto do aviso interno de uma etapa nova
create or replace function aviso_rastreio(p_pagamento uuid, p_etapa text)
returns text language sql stable set search_path = public as $$
  select '[AVISO INTERNO] A entrega do pedido deste cliente avançou. Etapa atual: "' || p_etapa || '". '
      || 'Itens: ' || coalesce((select string_agg(pd.quantidade || 'x ' || pr.nome, '; ')
                                  from pedidos pd join produtos pr on pr.sku = pd.sku
                                 where pd.conversa_id = pg.conversa_id), 'pedido') || '. '
      || 'Código de rastreio: ' || pg.codigo_rastreio || '. '
      || 'Link de rastreio: ' || url_base() || '/webhook/olden-rastreio?c=' || pg.codigo_rastreio || '. '
      || case when p_etapa = 'Entregue'
              then 'Escreva agora ao cliente, por iniciativa sua, uma mensagem curta contando que o pedido foi entregue e perguntando se chegou tudo certinho.'
              else 'Escreva agora ao cliente, por iniciativa sua, uma mensagem curta contando a novidade e lembrando o link de rastreio.'
         end
      || ' Não peça avaliação de novo e não invente prazos.'
  from pagamentos pg where pg.id = p_pagamento
$$;

-- Separa os avisos que precisam ser enviados agora e já os marca como avisados.
-- Se várias etapas passaram de uma vez, avisa só a mais recente.
-- A etapa "Pagamento aprovado" não entra: ela já é avisada na hora do pagamento.
-- Sessões de teste da bateria ("teste:") ficam de fora.
create or replace function avisos_rastreio_pendentes()
returns table (sessao text, mensagem text, origem text)
language plpgsql set search_path = public as $$
begin
  return query
  with concluidas as (
    select pg.id as pagamento_id, cl.identificador as sessao, e.etapa, e.quando
    from pagamentos pg
    join conversas c  on c.id = pg.conversa_id
    join clientes cl  on cl.id = c.cliente_id
    cross join lateral eventos_rastreio(pg.codigo_rastreio) e
    where pg.status = 'pago'
      and pg.pago_em > now() - interval '1 day'
      and cl.identificador not like 'teste:%'
      and e.concluida
      and e.etapa <> 'Pagamento aprovado'
      and not exists (select 1 from rastreio_avisos ra where ra.pagamento_id = pg.id and ra.etapa = e.etapa)
  ),
  marcadas as (
    insert into rastreio_avisos (pagamento_id, etapa)
    select pagamento_id, etapa from concluidas
    on conflict do nothing
    returning rastreio_avisos.pagamento_id, rastreio_avisos.etapa
  ),
  mais_recente as (
    select distinct on (c.pagamento_id) c.pagamento_id, c.sessao, c.etapa
    from concluidas c
    join marcadas m on m.pagamento_id = c.pagamento_id and m.etapa = c.etapa
    order by c.pagamento_id, c.quando desc
  )
  select mr.sessao, aviso_rastreio(mr.pagamento_id, mr.etapa), 'sistema'::text
  from mais_recente mr;
end $$;

-- ---------- Bateria: comando "#pagamento_rastreio_avancou" ----------
-- Avança o rastreio da sessão de teste em uma etapa e devolve o aviso para a Lia.
create or replace function simular_pagamento_sessao(p_sessao text, p_comando text)
returns text language plpgsql set search_path = public as $$
declare v_token text; v_res jsonb; v_pag pagamentos%rowtype; v_etapa text;
begin
  if p_sessao not like 'teste:%' then
    return '[AVISO INTERNO] Comando de teste ignorado. Não escreva nada sobre pagamento; só cumprimente o cliente.';
  end if;

  if p_comando = '#pagamento_rastreio_avancou' then
    select pg.* into v_pag
      from pagamentos pg join conversas c on c.id = pg.conversa_id join clientes cl on cl.id = c.cliente_id
     where cl.identificador = p_sessao and pg.status = 'pago'
     order by pg.pago_em desc limit 1;
    if not found then
      return '[AVISO INTERNO] Teste: não havia pedido pago para avançar o rastreio. Não escreva nada sobre entrega.';
    end if;
    -- volta o horário do pagamento em uma etapa, para a próxima etapa ficar concluída agora
    select e.etapa into v_etapa from eventos_rastreio(v_pag.codigo_rastreio) e
     where not e.concluida order by e.quando limit 1;
    if v_etapa is null then
      return '[AVISO INTERNO] Teste: o pedido já foi entregue. Não escreva nada sobre entrega.';
    end if;
    update pagamentos set pago_em = pago_em - minutos_por_etapa() * interval '1 minute' where id = v_pag.id;
    insert into rastreio_avisos (pagamento_id, etapa)
      select v_pag.id, e.etapa from eventos_rastreio(v_pag.codigo_rastreio) e
       where e.concluida and e.etapa <> 'Pagamento aprovado'
    on conflict do nothing;
    return aviso_rastreio(v_pag.id, v_etapa);
  end if;

  select pg.token into v_token
    from pagamentos pg join conversas c on c.id = pg.conversa_id join clientes cl on cl.id = c.cliente_id
   where cl.identificador = p_sessao and pg.status = 'pendente'
   order by pg.criado_em desc limit 1;
  if v_token is null then
    return '[AVISO INTERNO] Teste: não havia pagamento pendente para simular. Não escreva nada sobre pagamento ao cliente.';
  end if;
  v_res := confirmar_pagamento(v_token, p_comando = '#pagamento_aprovado');
  return v_res->>'aviso';
end $$;

-- ---------- Limpeza ----------
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

-- ---------- Segurança ----------
revoke execute on function avisos_rastreio_pendentes() from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function avisos_rastreio_pendentes() from anon, authenticated';
  end if;
end $$;

-- ---------- Cenário de teste ----------
insert into cenarios_teste (id, titulo, turnos, esperado, criterios_juiz) values
('C25', 'Avisos de rastreio ao longo da entrega',
 '["Quero o lenço do Campeão do Brasil no Pix, meu nome é Leo", "Confirmo", "#pagamento_aprovado", "#pagamento_rastreio_avancou", "#pagamento_rastreio_avancou", "Que legal! Já posso esperar em casa?"]',
 '{"pedidos_qtd": 1, "pagamento_status": "pago", "rastreio_no_texto": true}',
 'Nos turnos #pagamento_rastreio_avancou, escreve SOZINHA uma mensagem curta contando a etapa nova da entrega (Pedido separado no estoque, depois Objeto postado), com o link de rastreio, sem pedir avaliação de novo e sem inventar prazos. No último turno, responde com base na etapa atual, sem prometer data.')
on conflict (id) do update set
  titulo = excluded.titulo, turnos = excluded.turnos, esperado = excluded.esperado,
  criterios_juiz = excluded.criterios_juiz;
