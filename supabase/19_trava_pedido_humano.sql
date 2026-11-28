-- =====================================================================
-- Olden Sports - 19_trava_pedido_humano.sql
-- chamar_equipe passa a receber a mensagem atual do cliente. O motivo
-- "pediu_humano" só é aceito se o cliente pediu uma pessoa de verdade
-- (nesta mensagem ou na anterior), ou se respondeu "sim/pode" logo depois
-- de a Lia oferecer chamar a equipe. Evita usar "pediu_humano" como
-- atalho para dúvidas de pré-venda.
-- Pode rodar mais de uma vez.
-- =====================================================================

create or replace function cliente_pediu_humano(p_conversa_id uuid, p_mensagem text)
returns boolean
language sql
stable
set search_path = public, extensions
as $$
  with hist as (
    select message->>'type' as tipo, message->>'content' as conteudo, id
      from n8n_chat_histories where session_id = p_conversa_id::text
     order by id desc limit 4
  ),
  pedido(rx) as (values ('(pessoa|humano|atendente|alguem|supervisor|gerente|equipe|chama|falar com|responsavel|vendedor|de verdade|gente de verdade|real)'))
  select
    -- pediu nesta mensagem
    f_unaccent(lower(coalesce(p_mensagem, ''))) ~ (select rx from pedido)
    -- ou pediu na mensagem anterior
    or exists (select 1 from hist where tipo = 'human' and id = (select max(id) from hist where tipo = 'human')
                 and f_unaccent(lower(conteudo)) ~ (select rx from pedido))
    -- ou disse "sim/pode" logo depois de a Lia oferecer a equipe
    or (f_unaccent(lower(trim(coalesce(p_mensagem, '')))) ~ '^(sim|s|pode|ok|quero|claro|por favor|pfv|isso|bora|manda|chama|uhum|aham)\M'
        and exists (select 1 from hist where tipo = 'ai' and id = (select max(id) from hist where tipo = 'ai')
                      and f_unaccent(lower(conteudo)) like '%equipe%'))
$$;

drop function if exists chamar_equipe(uuid, text, text, text);

create or replace function chamar_equipe(p_conversa_id uuid, p_motivo text, p_resumo text, p_referencia text default null, p_mensagem text default null)
returns text
language plpgsql
set search_path = public
as $$
declare
  v_ident   text;
  v_nome    text;
  v_status  text;
  v_aberto  chamados_equipe%rowtype;
  v_id      bigint;
  v_equipe  text;
  v_contato text;
  v_resumo  text := trim(coalesce(p_resumo, ''));
begin
  if coalesce(p_motivo, '') not in ('troca', 'devolucao', 'atraso', 'pedido_antigo', 'pagamento', 'reclamacao', 'pediu_humano') then
    return 'Não registrado e nada foi enviado à equipe: chamar_equipe é só para pós-venda (troca, devolucao, atraso, pedido_antigo, pagamento, reclamacao) ou quando o cliente pede uma pessoa (pediu_humano). Dúvidas de frete, prazo, CNPJ, originalidade, cupom, produto que não temos e afins você responde com as Informações da loja. Responda ao cliente normalmente, sem falar da equipe.';
  end if;
  if p_motivo = 'pediu_humano' and not cliente_pediu_humano(p_conversa_id, p_mensagem) then
    return 'Não registrado e nada foi enviado à equipe: o cliente não pediu para falar com uma pessoa. Responda você mesma a dúvida dele com as Informações da loja e as ferramentas, sem falar da equipe. Se não souber, diga que não tem essa informação e ofereça chamar alguém da equipe, sem chamar ainda.';
  end if;
  if length(v_resumo) < 15 or v_resumo ~* '^(n[ãa]o cham|teste|exemplo|nada)' then
    return 'Não registrado: o resumo precisa descrever o caso real do cliente. Só chame chamar_equipe quando for passar um caso de verdade para a equipe.';
  end if;

  select cl.identificador, cl.nome, c.status into v_ident, v_nome, v_status
    from conversas c join clientes cl on cl.id = c.cliente_id where c.id = p_conversa_id;
  if v_ident is null then
    return 'Erro: conversa não encontrada.';
  end if;

  v_equipe := regexp_replace(coalesce((select valor from configuracao where chave = 'equipe_whatsapp'), ''), '\D', '', 'g');
  v_contato := case when v_ident like 'wa:%' then '+' || substr(v_ident, 4) || ' (wa.me/' || substr(v_ident, 4) || ')'
                    else v_ident || ' (chat do site)' end;

  select * into v_aberto from chamados_equipe
   where conversa_id = p_conversa_id and status = 'aberto' order by id desc limit 1;

  if v_aberto.id is not null then
    update chamados_equipe
       set resumo = coalesce(resumo, '') || E'\n+ ' || v_resumo,
           referencia = coalesce(nullif(p_referencia, ''), referencia)
     where id = v_aberto.id;
    if v_equipe <> '' and v_ident not like 'teste:%' then
      insert into mensagens_saida (sessao, texto)
      values ('wa:' || v_equipe, '➕ *Complemento do chamado #' || v_aberto.id || '*' || E'\n'
              || 'Cliente: ' || coalesce(nullif(v_nome, ''), 'sem nome') || ' · ' || v_contato || E'\n'
              || coalesce('Referência: ' || nullif(p_referencia, '') || E'\n', '') || v_resumo);
    end if;
    return 'Informação acrescentada ao caso que já está com a equipe. Diga ao cliente, numa frase, que passou a informação nova para a equipe. Não cite número de chamado nem prometa prazo.';
  end if;

  insert into chamados_equipe (conversa_id, sessao, motivo, resumo, referencia)
  values (p_conversa_id, v_ident, p_motivo, v_resumo, nullif(p_referencia, ''))
  returning id into v_id;

  if v_status = 'aberta' then
    update conversas set status = 'aguardando_equipe' where id = p_conversa_id;
  end if;

  if v_equipe <> '' and v_ident not like 'teste:%' then
    insert into mensagens_saida (sessao, texto)
    values ('wa:' || v_equipe,
            '🔔 *Chamado #' || v_id || ' da Lia*' || E'\n'
            || 'Cliente: ' || coalesce(nullif(v_nome, ''), 'sem nome') || ' · ' || v_contato || E'\n'
            || 'Motivo: ' || p_motivo || E'\n'
            || coalesce('Referência: ' || nullif(p_referencia, '') || E'\n', '')
            || 'Resumo: ' || v_resumo || E'\n\n'
            || 'Para encerrar: select resolver_chamado(' || v_id || ');');
  end if;

  return 'Equipe avisada. Diga ao cliente, numa frase, que a equipe já está com o caso e responde por aqui, no horário de atendimento. Não cite número de chamado nem prometa prazo ou solução.';
end $$;
