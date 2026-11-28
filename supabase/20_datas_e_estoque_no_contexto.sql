-- =====================================================================
-- Olden Sports - 20_datas_e_estoque_no_contexto.sql
-- 1. A Lia recebe pronto: data e hora de hoje, se a equipe está atendendo
--    agora e quando volta (sem ela fazer conta de calendário).
-- 2. prazo_entrega(uf): janela de entrega estimada em datas, pela política
--    (postagem em até 2 dias úteis + faixa da região). Sem feriados.
-- 3. A Lia recebe as peças que já mostrou nesta conversa com o estoque
--    atual, para não dizer "não tem" de algo que acabou de mostrar.
-- Pode rodar mais de uma vez.
-- =====================================================================

-- Soma dias úteis (seg a sex) a uma data
create or replace function somar_dias_uteis(p_data date, p_dias int)
returns date
language plpgsql
immutable
as $$
declare d date := p_data; n int := 0;
begin
  while n < p_dias loop
    d := d + 1;
    if extract(isodow from d) < 6 then n := n + 1; end if;
  end loop;
  return d;
end $$;

create or replace function dia_semana_pt(p_data date)
returns text
language sql
immutable
as $$
  select (array['segunda','terça','quarta','quinta','sexta','sábado','domingo'])[extract(isodow from p_data)::int]
$$;

-- Horário da equipe (política "atendimento_humano"): seg a sex 9h-18h, sáb 9h-13h
create or replace function situacao_equipe_agora()
returns text
language plpgsql
stable
as $$
declare
  agora timestamp := now() at time zone 'America/Sao_Paulo';
  d date := agora::date;
  h numeric := extract(hour from agora) + extract(minute from agora) / 60;
  dow int := extract(isodow from agora);
  prox date;
begin
  if (dow between 1 and 5 and h >= 9 and h < 18) or (dow = 6 and h >= 9 and h < 13) then
    return 'a equipe está atendendo agora (até as ' || case when dow = 6 then '13h' else '18h' end || ').';
  end if;
  -- próximo dia de atendimento
  prox := case when (dow between 1 and 6 and h < 9) then d else d + 1 end;
  while extract(isodow from prox) = 7 loop prox := prox + 1; end loop;
  return 'a equipe está fora do horário agora; volta ' ||
         case when prox = d then 'hoje (' || dia_semana_pt(prox) || ', ' || to_char(prox, 'DD/MM') || ')'
              when prox = d + 1 then 'amanhã (' || dia_semana_pt(prox) || ', ' || to_char(prox, 'DD/MM') || ')'
              else 'na ' || dia_semana_pt(prox) || ', ' || to_char(prox, 'DD/MM') end || ', às 9h.';
end $$;

-- Janela de entrega estimada por UF (pagando hoje)
create or replace function prazo_entrega(p_uf text)
returns text
language plpgsql
stable
as $$
declare
  uf text := upper(trim(coalesce(p_uf, '')));
  regiao text; minimo int; maximo int;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  postagem date; de date; ate date;
begin
  regiao := case
    when uf in ('SP','RJ','MG','ES') then 'Sudeste'
    when uf in ('PR','SC','RS') then 'Sul'
    when uf in ('DF','GO','MT','MS') then 'Centro-Oeste'
    when uf in ('BA','SE','AL','PE','PB','RN','CE','PI','MA') then 'Nordeste'
    when uf in ('AM','PA','AC','RO','RR','AP','TO') then 'Norte'
  end;
  if regiao is null then
    return 'UF não reconhecida. Pergunte ao cliente o estado (ex.: MG, SP) e chame de novo.';
  end if;
  select case regiao when 'Sudeste' then 3 when 'Sul' then 4 when 'Norte' then 8 else 6 end,
         case regiao when 'Sudeste' then 6 when 'Sul' then 8 when 'Norte' then 14 else 10 end
    into minimo, maximo;
  postagem := somar_dias_uteis(hoje, 2);
  de := somar_dias_uteis(hoje, minimo);           -- postagem pode ser no mesmo dia: melhor caso
  ate := somar_dias_uteis(postagem, maximo);       -- postagem no 2º dia útil + máximo da região
  return 'Região ' || regiao || '. Se o pagamento for aprovado hoje (' || dia_semana_pt(hoje) || ', ' || to_char(hoje, 'DD/MM') ||
         '), a postagem sai até ' || dia_semana_pt(postagem) || ', ' || to_char(postagem, 'DD/MM') ||
         ', e a entrega estimada fica entre ' || to_char(de, 'DD/MM') || ' e ' || to_char(ate, 'DD/MM') ||
         ' (' || dia_semana_pt(ate) || '). Estimativa dos Correios em dias úteis, sem feriados: não é garantia. ' ||
         'Compare com a data que o cliente precisa e diga com clareza se a data dele fica antes, dentro ou depois dessa janela.';
end $$;

-- Peças que a Lia já mostrou nesta conversa, com o estoque de agora
create or replace function pecas_mostradas(p_conversa uuid)
returns text
language sql
stable
set search_path = public
as $$
  with codigos as (
    select distinct m[1] as codigo
      from n8n_chat_histories h,
           regexp_matches(h.message->>'content', '(OLD-P[0-9]+)', 'g') m
     where h.session_id = p_conversa::text and h.message->>'type' = 'ai'
  )
  select string_agg(p.nome || ' (' || p.item_group_id || '): ' ||
           coalesce((select 'tam. em estoque ' || string_agg(v.tamanho, ', ' order by v.ordem)
                       from catalogo_variantes v where v.item_group_id = p.item_group_id and v.disponivel and v.quantidade > 0),
                    'ESGOTADO'), E'\n  ' order by p.nome)
    from codigos c join catalogo_produtos p on p.item_group_id = c.codigo
$$;

-- Contexto a cada mensagem: canal, data/hora, equipe, peças já mostradas e políticas
create or replace function contexto_extra(p_conversa uuid, p_sessao text)
returns text
language sql
stable
set search_path = public
as $$
  select
    E'\n- Canal: ' || case when p_sessao like 'wa:%' or p_sessao like 'teste:wa:%'
                           then 'WhatsApp (o cliente pode mandar fotos)'
                           else 'página de chat (o cliente NÃO consegue mandar fotos: não ofereça o provador)' end
    || E'\n- Hoje é ' || dia_semana_pt((now() at time zone 'America/Sao_Paulo')::date) || ', '
       || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY "às" HH24:MI') || ' (Brasília); ' || situacao_equipe_agora()
       || ' Use isso para dizer quando a equipe responde; não faça conta de calendário por conta própria.'
    || E'\n- Equipe: ' || coalesce((
         select 'JÁ FOI CHAMADA nesta conversa (às ' || to_char(ch.criado_em at time zone 'America/Sao_Paulo', 'HH24:MI')
                || '). O que a equipe já sabe: ' || coalesce(ch.resumo, '') || coalesce(' | Referência: ' || ch.referencia, '')
                || '. Não diga que avisou algo que não está aqui; se o cliente trouxer informação nova sobre o caso, chame chamar_equipe para complementar.'
           from chamados_equipe ch
          where ch.conversa_id = p_conversa and ch.status = 'aberto'
          order by ch.id desc limit 1),
         'NÃO foi chamada nesta conversa. Não diga que avisou a equipe sem chamar chamar_equipe.')
    || coalesce(E'\n- Peças que você já mostrou nesta conversa (estoque de agora; confie nisto antes de dizer que algo não tem):\n  '
                || pecas_mostradas(p_conversa), '')
    || E'\n\n# Informações da loja\nUse estas informações para responder o cliente na hora, sem chamar a equipe. São as únicas políticas que existem: o que não está aqui, você não sabe.\n'
    || coalesce((select string_agg('- ' || initcap(replace(tema, '_', ' ')) || ': ' || texto, E'\n' order by ordem) from politicas_loja), '')
$$;
