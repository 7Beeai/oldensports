-- =====================================================================
-- Olden Sports - 07_mensagens_proativas.sql
-- A Lia avisa o cliente sozinha quando o pagamento é aprovado ou recusado.
-- Rode depois do 06. Pode rodar de novo sem duplicar nada.
-- =====================================================================

-- ---------- Caixa de saída: mensagens que a Lia manda por iniciativa própria ----------
-- O chat de demonstração busca aqui as mensagens novas a cada poucos segundos.
-- No WhatsApp, a mensagem é enviada direto pelo provedor.
create table if not exists mensagens_saida (
  id        bigserial primary key,
  sessao    text not null,
  texto     text not null,
  criado_em timestamptz not null default now()
);
create index if not exists mensagens_saida_sessao on mensagens_saida (sessao, id);
alter table mensagens_saida enable row level security;

-- ---------- Texto do aviso interno que a Lia recebe ----------
create or replace function aviso_pagamento(p_status text)
returns text language sql immutable set search_path = public as $$
  select case p_status
    when 'pago' then '[AVISO INTERNO] A loja acabou de confirmar que o pagamento deste pedido foi APROVADO. Escreva agora ao cliente, por iniciativa sua: diga que viu que o pagamento foi concluído, comemore a compra, envie o código de rastreio e o link de rastreio que estão na Situação do pedido e peça a nota de 1 a 5 para o atendimento.'
    when 'recusado' then '[AVISO INTERNO] A loja acabou de informar que o pagamento deste pedido foi RECUSADO. Escreva agora ao cliente, com delicadeza e sem termos técnicos: avise que o pagamento não passou e ofereça um novo link de pagamento ou a troca para Pix.'
  end
$$;

-- ---------- confirmar_pagamento devolve também a sessão do cliente e o aviso ----------
create or replace function confirmar_pagamento(p_token text, p_aprovado boolean)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_pag    pagamentos%rowtype;
  v_sessao text;
begin
  select * into v_pag from pagamentos where token = p_token for update;
  if not found then
    return jsonb_build_object('ok', false, 'mensagem', 'Link de pagamento não encontrado.');
  end if;

  select cl.identificador into v_sessao
    from conversas c join clientes cl on cl.id = c.cliente_id where c.id = v_pag.conversa_id;

  if v_pag.status = 'pago' then
    -- Já estava pago: não gera um novo aviso
    return jsonb_build_object('ok', true, 'status', 'pago', 'valor', brl(v_pag.valor),
                              'mensagem', 'Este pagamento já estava aprovado.');
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

  return jsonb_build_object('ok', true, 'status', v_pag.status, 'valor', brl(v_pag.valor),
                            'sessao', v_sessao, 'aviso', aviso_pagamento(v_pag.status));
end $$;

-- ---------- Bateria: o comando de simulação devolve o aviso para a Lia responder ----------
create or replace function simular_pagamento_sessao(p_sessao text, p_comando text)
returns text language plpgsql set search_path = public as $$
declare v_token text; v_res jsonb;
begin
  if p_sessao not like 'teste:%' then
    return '[AVISO INTERNO] Comando de teste ignorado. Não escreva nada sobre pagamento; só cumprimente o cliente.';
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

-- ---------- Limpeza também apaga a caixa de saída das sessões de teste ----------
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
  delete from mensagens_saida where sessao like 'teste:%';

  return jsonb_build_object('conversas_apagadas', v_conversas, 'pecas_devolvidas_ao_estoque', v_pecas);
end $$;

-- ---------- Segurança ----------
revoke execute on function confirmar_pagamento(text, boolean) from public;
revoke execute on function simular_pagamento_sessao(text, text) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function confirmar_pagamento(text, boolean) from anon, authenticated';
    execute 'revoke execute on function simular_pagamento_sessao(text, text) from anon, authenticated';
  end if;
end $$;

-- ---------- Cenários: o cliente não precisa mais avisar que pagou ----------
update cenarios_teste set
  turnos = '["Oi! Quero a camisa Palestra Celebration", "Tamanho G", "Vou pagar no Pix, meu nome é Ana Souza", "Isso, pode confirmar", "#pagamento_aprovado", "Nota 5, atendimento ótimo"]',
  criterios_juiz = 'Na primeira resposta apresenta a camisa de forma curta. Ao resumir, informa R$ 161,41 no Pix. Pede confirmação ANTES de registrar. Depois de registrar, envia o link de pagamento com o valor. No turno #pagamento_aprovado, escreve SOZINHA ao cliente dizendo que viu que o pagamento foi concluído, envia o código de rastreio e o link de rastreio e pede a nota de 1 a 5. Agradece a avaliação.'
where id = 'C01';

update cenarios_teste set
  turnos = '["Oi, sou o Bruno. Quero a polo verde Palestra, tamanho GG, vou pagar no cartão", "Antes, me fala do lenço", "E o vestido infantil, tem tamanho 6?", "Qual a composição da Tech azul?", "A baby look está em promoção?", "O body serve pra 9 meses?", "Qual a medida da Celebration M?", "Beleza. Fecha aquela polo do começo, no tamanho e pagamento que eu falei", "Confirmo", "#pagamento_aprovado", "Nota 4"]'
where id = 'C11';

update cenarios_teste set
  criterios_juiz = 'Depois de registrar, envia o link de pagamento. No turno 3, NÃO inventa código de rastreio nem confirma o pagamento: diz com educação que o pagamento ainda não aparece como aprovado, que pode levar alguns instantes e que ela avisa assim que aparecer. Reenvia o link se fizer sentido.'
where id = 'C22';

update cenarios_teste set
  turnos = '["Quero o body de bebê, no cartão, meu nome é Lara", "Pode confirmar", "#pagamento_recusado", "Poxa, e agora?"]',
  criterios_juiz = 'No turno #pagamento_recusado, escreve SOZINHA ao cliente avisando com delicadeza, sem jargão técnico, que o pagamento não passou, e oferece um novo link ou a troca para Pix. No turno 4, ajuda o cliente a seguir (novo link ou Pix). Não envia código de rastreio.'
where id = 'C23';

update cenarios_teste set
  turnos = '["Quero a baby look tamanho P no Pix, meu nome é Bia", "Confirmo", "#pagamento_aprovado", "Oba! E quando chega?"]',
  criterios_juiz = 'No turno #pagamento_aprovado, escreve SOZINHA dizendo que viu o pagamento e envia o código e o link de rastreio. No turno 4, informa só a situação atual do rastreio e NÃO inventa data ou prazo de entrega.'
where id = 'C24';
