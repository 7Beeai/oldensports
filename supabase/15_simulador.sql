-- =====================================================================
-- Olden Sports - 15_simulador.sql
-- Simulador de clientes (workflow 6): personas geradas por IA conversam
-- com a Lia e uma IA avaliadora dá nota por critério.
-- Pode rodar mais de uma vez: não apaga dados.
-- =====================================================================

create table if not exists sim_personas (
  id          bigserial primary key,
  rodada      text not null,
  combinacao  jsonb not null,      -- as dimensões sorteadas (perfil, intenção, produto, time, desafio, canal)
  persona     jsonb not null,      -- nome, idade, estilo de escrita, objetivo, primeira mensagem...
  criado_em   timestamptz not null default now()
);
create index if not exists sim_personas_rodada on sim_personas (rodada);

create table if not exists sim_conversas (
  id          bigserial primary key,
  rodada      text not null,
  persona_id  bigint references sim_personas (id) on delete cascade,
  sessao      text,
  canal       text,
  transcricao jsonb,               -- [{de: 'cliente'|'lia', texto, blocos}]
  turnos      int,
  desfecho    text,                -- comprou, desistiu, humano, limite_de_turnos, erro
  fatos       jsonb,               -- o que ficou no banco (pedido, pagamento, avaliação)
  notas       jsonb,               -- nota de 0 a 10 por critério (null = não se aplica)
  nota_geral  numeric,
  aprovado    boolean,
  problemas   jsonb,               -- lista de problemas apontados pela avaliadora
  sugestao    text,                -- sugestão de ajuste no prompt
  duracao_ms  int,
  criado_em   timestamptz not null default now()
);
create index if not exists sim_conversas_rodada on sim_conversas (rodada);

-- Token que libera iniciar o simulador pela URL (o botão do n8n não precisa dele)
insert into configuracao (chave, valor)
values ('simulador_token', substr(md5(random()::text || clock_timestamp()::text), 1, 24))
on conflict (chave) do nothing;

-- Resumo de cada rodada
create or replace view sim_resumo as
select c.rodada,
       count(*)                                              as conversas,
       count(*) filter (where c.aprovado)                    as aprovadas,
       round(avg(c.nota_geral), 1)                           as nota_media,
       round(avg(c.turnos), 1)                               as turnos_medios,
       count(*) filter (where c.desfecho = 'comprou')        as compraram,
       count(*) filter (where c.desfecho = 'desistiu')       as desistiram,
       count(*) filter (where c.desfecho = 'humano')         as pediram_humano,
       count(*) filter (where c.desfecho = 'limite_de_turnos') as sem_desfecho,
       min(c.criado_em)                                      as inicio
from sim_conversas c
group by c.rodada;

-- Nota média de cada critério, por rodada (só onde o critério se aplicou)
create or replace view sim_criterios as
select c.rodada, n.key as criterio,
       count(*)                          as avaliadas,
       round(avg(n.value::numeric), 1)   as nota_media,
       count(*) filter (where n.value::numeric < 7) as abaixo_de_7
from sim_conversas c, jsonb_each_text(c.notas) n
where n.value is not null and n.value ~ '^[0-9.]+$'
group by c.rodada, n.key;

-- Nota por dimensão da persona (ex.: qual perfil de cliente a Lia atende pior)
create or replace view sim_por_dimensao as
select c.rodada, d.key as dimensao, d.value as valor,
       count(*) as conversas, round(avg(c.nota_geral), 1) as nota_media,
       count(*) filter (where not c.aprovado) as reprovadas
from sim_conversas c
join sim_personas p on p.id = c.persona_id,
     jsonb_each_text(p.combinacao) d
group by c.rodada, d.key, d.value;

-- Conversas para ler primeiro: as piores de cada rodada
create or replace view sim_piores as
select c.rodada, c.id, c.nota_geral, c.desfecho, p.combinacao, p.persona->>'nome' as persona,
       c.problemas, c.sugestao
from sim_conversas c join sim_personas p on p.id = c.persona_id
order by c.rodada desc, c.nota_geral asc nulls first;

-- Conversas em paralelo: cada conversa devolve o próprio estoque ao terminar
create or replace function limpar_sessao_teste(p_sessao text)
returns jsonb
language plpgsql
set search_path = public
as $$
declare v_conversas int;
begin
  if p_sessao not like 'teste:%' then
    raise exception 'só limpa sessões de teste (teste:...)';
  end if;
  create temp table _alvo_sessao on commit drop as
    select c.id from conversas c join clientes cl on cl.id = c.cliente_id where cl.identificador = p_sessao;
  select count(*) into v_conversas from _alvo_sessao;
  update catalogo_variantes v set quantidade = v.quantidade + d.qtd
    from (select sku, sum(quantidade) as qtd from pedidos where conversa_id in (select id from _alvo_sessao) group by sku) d
   where v.sku = d.sku;
  delete from n8n_chat_histories where session_id in (select id::text from _alvo_sessao);
  delete from rastreio_avisos where pagamento_id in (select id from pagamentos where conversa_id in (select id from _alvo_sessao));
  delete from pagamentos where conversa_id in (select id from _alvo_sessao);
  delete from avaliacoes where conversa_id in (select id from _alvo_sessao);
  delete from interesses where conversa_id in (select id from _alvo_sessao);
  delete from pedidos    where conversa_id in (select id from _alvo_sessao);
  delete from conversas  where id in (select id from _alvo_sessao);
  delete from mensagens_saida where sessao = p_sessao;
  return jsonb_build_object('conversas_apagadas', v_conversas);
end $$;

-- Resumo mostra também quantas personas a rodada tem (conversas < personas = ainda rodando)
create or replace view sim_resumo as
select c.rodada,
       count(*)                                              as conversas,
       count(*) filter (where c.aprovado)                    as aprovadas,
       round(avg(c.nota_geral), 1)                           as nota_media,
       round(avg(c.turnos), 1)                               as turnos_medios,
       count(*) filter (where c.desfecho = 'comprou')        as compraram,
       count(*) filter (where c.desfecho = 'desistiu')       as desistiram,
       count(*) filter (where c.desfecho = 'humano')         as pediram_humano,
       count(*) filter (where c.desfecho = 'limite_de_turnos') as sem_desfecho,
       min(c.criado_em)                                      as inicio,
       (select count(*) from sim_personas p where p.rodada = c.rodada) as personas
from sim_conversas c
group by c.rodada;
