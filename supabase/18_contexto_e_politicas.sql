-- =====================================================================
-- Olden Sports - 18_contexto_e_politicas.sql
-- 1. Políticas da loja (frete, prazo, troca, empresa...) que a Lia usa
--    para responder pré-venda sem chamar a equipe.
--    ATENÇÃO: os textos abaixo são FICTÍCIOS, só para o ambiente de teste.
--    Troque pelos dados reais da Olden com: update politicas_loja set texto = '...', ficticio = false where tema = '...';
-- 2. contexto_extra(): a cada mensagem, a Lia recebe o canal, a situação
--    real do chamado da equipe e as políticas. Assim ela não "esquece" o
--    que as ferramentas fizeram (a memória guarda só as mensagens).
-- 3. chamar_equipe(): um chamado aberto por conversa; informação nova
--    complementa o mesmo chamado; recusa chamado vazio ou de "teste".
-- =====================================================================

-- 1. Políticas ---------------------------------------------------------------
create table if not exists politicas_loja (
  tema      text primary key,
  ordem     int not null,
  texto     text not null,
  ficticio  boolean not null default true
);

insert into politicas_loja (tema, ordem, texto) values
  ('frete', 1, 'Frete grátis para todo o Brasil, em qualquer compra, no cartão ou no Pix. Não existe frete pago, frete expresso nem retirada na loja.'),
  ('prazo', 2, 'A Olden posta o pedido em até 2 dias úteis depois do pagamento aprovado. Depois da postagem, a entrega leva em média: Sudeste 3 a 6 dias úteis; Sul 4 a 8; Centro-Oeste e Nordeste 6 a 10; Norte 8 a 14. São prazos estimados dos Correios, não garantidos: nunca prometa que chega até uma data.'),
  ('rastreio', 3, 'O código de rastreio é enviado por aqui assim que o pagamento é aprovado.'),
  ('pagamento', 4, 'Formas de pagamento: Pix (valor promocional) ou cartão de crédito em até 6x sem juros (valor cheio). Não há boleto. O pagamento é feito pelo link que a Lia envia, sem baixar aplicativo.'),
  ('troca', 5, 'Primeira troca grátis em até 30 dias depois do recebimento, com a peça sem uso e com etiqueta (troca de tamanho ou de modelo, sujeita a estoque). Devolução por arrependimento em até 7 dias corridos depois do recebimento, com reembolso integral. Para pedir troca ou devolução de uma compra já feita, a Lia passa o caso para a equipe.'),
  ('originalidade', 6, 'Todos os produtos da Olden são oficiais licenciados, com etiqueta do fabricante, e toda compra vai com nota fiscal eletrônica enviada por e-mail.'),
  ('empresa', 7, 'Olden Sports Comércio de Artigos Esportivos Ltda., CNPJ 00.000.000/0001-00, Belo Horizonte (MG). Loja só online, no site oldensports.com.br; não há loja física para visitar.'),
  ('reserva', 8, 'Não existe reserva de peça sem pedido. Quando o cliente confirma o pedido, a peça fica separada no estoque enquanto o pagamento está pendente.'),
  ('descontos', 9, 'Não há cupons, descontos para aposentado ou estudante, nem desconto por atraso. O único valor menor é o do Pix.'),
  ('atendimento_humano', 10, 'A equipe atende de segunda a sexta, das 9h às 18h, e sábado das 9h às 13h (horário de Brasília). Fora desse horário, responde no próximo horário de atendimento.')
on conflict (tema) do nothing;

-- 2. Contexto real da conversa -----------------------------------------------
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
    || E'\n- Equipe: ' || coalesce((
         select 'JÁ FOI CHAMADA nesta conversa (às ' || to_char(ch.criado_em at time zone 'America/Sao_Paulo', 'HH24:MI')
                || '). O que a equipe já sabe: ' || coalesce(ch.resumo, '') || coalesce(' | Referência: ' || ch.referencia, '')
                || '. Não diga que avisou algo que não está aqui; se o cliente trouxer informação nova sobre o caso, chame chamar_equipe para complementar.'
           from chamados_equipe ch
          where ch.conversa_id = p_conversa and ch.status = 'aberto'
          order by ch.id desc limit 1),
         'NÃO foi chamada nesta conversa. Não diga que avisou a equipe sem chamar chamar_equipe.')
    || E'\n\n# Informações da loja\nUse estas informações para responder o cliente na hora, sem chamar a equipe. São as únicas políticas que existem: o que não está aqui, você não sabe.\n'
    || coalesce((select string_agg('- ' || initcap(replace(tema, '_', ' ')) || ': ' || texto, E'\n' order by ordem) from politicas_loja), '')
$$;

-- 3. chamar_equipe: um chamado por conversa, com complementos ----------------
create or replace function chamar_equipe(p_conversa_id uuid, p_motivo text, p_resumo text, p_referencia text default null)
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
    return 'Não registrado e nada foi enviado à equipe: chamar_equipe é só para pós-venda (troca, devolucao, atraso, pedido_antigo, pagamento, reclamacao) ou quando o cliente pede uma pessoa (pediu_humano). Dúvidas de frete, prazo, CNPJ, originalidade, cupom e afins você responde com as Informações da loja. Responda ao cliente normalmente, sem falar da equipe.';
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
    -- Já existe chamado aberto: complementa
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
  values (p_conversa_id, v_ident, coalesce(nullif(p_motivo, ''), 'outro'), v_resumo, nullif(p_referencia, ''))
  returning id into v_id;

  if v_status = 'aberta' then
    update conversas set status = 'aguardando_equipe' where id = p_conversa_id;
  end if;

  if v_equipe <> '' and v_ident not like 'teste:%' then
    insert into mensagens_saida (sessao, texto)
    values ('wa:' || v_equipe,
            '🔔 *Chamado #' || v_id || ' da Lia*' || E'\n'
            || 'Cliente: ' || coalesce(nullif(v_nome, ''), 'sem nome') || ' · ' || v_contato || E'\n'
            || 'Motivo: ' || coalesce(nullif(p_motivo, ''), 'outro') || E'\n'
            || coalesce('Referência: ' || nullif(p_referencia, '') || E'\n', '')
            || 'Resumo: ' || v_resumo || E'\n\n'
            || 'Para encerrar: select resolver_chamado(' || v_id || ');');
  end if;

  return 'Equipe avisada. Diga ao cliente, numa frase, que a equipe já está com o caso e responde por aqui, no horário de atendimento. Não cite número de chamado nem prometa prazo ou solução.';
end $$;
