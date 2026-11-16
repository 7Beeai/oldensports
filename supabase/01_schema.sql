-- =====================================================================
-- Olden Sports - Agente de WhatsApp
-- 01_schema.sql: tabelas, regras de negócio e funções
-- Rode no Supabase: SQL Editor > New query > cole tudo > Run
-- =====================================================================

-- ---------- Tabelas ----------

create table if not exists clientes (
  id            uuid primary key default gen_random_uuid(),
  identificador text unique not null,       -- telefone no WhatsApp, ou sessionId no chat de teste
  nome          text,
  criado_em     timestamptz not null default now()
);

create table if not exists produtos (
  sku             text primary key,         -- código curto que o agente usa nas ferramentas
  nome            text not null,
  categoria       text not null,
  publico         text not null,            -- Masculino, Feminino, Infantil, Bebê, Unissex
  descricao       text not null,
  caracteristicas text,
  medidas         text,
  preco           numeric(10,2) not null,   -- preço no cartão
  preco_original  numeric(10,2),            -- preço "de" quando há promoção
  preco_pix       numeric(10,2) not null,
  parcelas        int not null default 6,   -- parcelas sem juros
  ativo           boolean not null default true
);

create table if not exists estoque (
  sku        text not null references produtos(sku) on delete cascade,
  tamanho    text not null,
  ordem      int  not null default 0,       -- ordem de exibição dos tamanhos
  quantidade int  not null default 0 check (quantidade >= 0),
  primary key (sku, tamanho)
);

create table if not exists conversas (
  id           uuid primary key default gen_random_uuid(),
  cliente_id   uuid not null references clientes(id),
  status       text not null default 'aberta'
               check (status in ('aberta','aguardando_avaliacao','encerrada')),
  iniciada_em  timestamptz not null default now(),
  encerrada_em timestamptz
);

create table if not exists interesses (
  id          uuid primary key default gen_random_uuid(),
  conversa_id uuid not null references conversas(id),
  sku         text not null references produtos(sku),
  criado_em   timestamptz not null default now()
);

create table if not exists pedidos (
  id              uuid primary key default gen_random_uuid(),
  conversa_id     uuid not null references conversas(id),
  sku             text not null references produtos(sku),
  tamanho         text not null,
  quantidade      int  not null default 1 check (quantidade between 1 and 10),
  forma_pagamento text not null check (forma_pagamento in ('pix','cartao')),
  nome_cliente    text,
  valor_unitario  numeric(10,2),            -- preenchido pelo banco, nunca pela IA
  valor_total     numeric(10,2),            -- preenchido pelo banco, nunca pela IA
  status          text not null default 'reservado',
  criado_em       timestamptz not null default now()
);

create table if not exists avaliacoes (
  id          uuid primary key default gen_random_uuid(),
  conversa_id uuid not null unique references conversas(id),
  nota        int  not null check (nota between 1 and 5),
  comentario  text,
  criada_em   timestamptz not null default now()
);

-- ---------- Regra: pedido valida estoque, calcula preço e baixa estoque ----------

create or replace function trg_pedido_antes_inserir()
returns trigger language plpgsql set search_path = public as $$
declare
  v_prod produtos%rowtype;
  v_qtd  int;
begin
  new.sku := upper(trim(new.sku));
  new.tamanho := upper(trim(new.tamanho));
  new.forma_pagamento := lower(trim(new.forma_pagamento));

  select * into v_prod from produtos where sku = new.sku and ativo;
  if not found then
    raise exception 'Produto % não existe ou está inativo.', new.sku;
  end if;

  select quantidade into v_qtd from estoque
   where sku = new.sku and tamanho = new.tamanho
   for update;
  if not found then
    raise exception 'O produto % não tem o tamanho %.', new.sku, new.tamanho;
  end if;
  if v_qtd < new.quantidade then
    raise exception 'Estoque insuficiente de % tamanho %: restam % unidade(s).',
      new.sku, new.tamanho, v_qtd;
  end if;

  new.valor_unitario := case when new.forma_pagamento = 'pix'
                             then v_prod.preco_pix else v_prod.preco end;
  new.valor_total := new.valor_unitario * new.quantidade;
  new.status := 'reservado';

  update estoque set quantidade = quantidade - new.quantidade
   where sku = new.sku and tamanho = new.tamanho;
  return new;
end $$;

drop trigger if exists pedido_antes_inserir on pedidos;
create trigger pedido_antes_inserir before insert on pedidos
  for each row execute function trg_pedido_antes_inserir();

create or replace function trg_pedido_depois_inserir()
returns trigger language plpgsql set search_path = public as $$
begin
  update conversas set status = 'aguardando_avaliacao'
   where id = new.conversa_id and status = 'aberta';
  return new;
end $$;

drop trigger if exists pedido_depois_inserir on pedidos;
create trigger pedido_depois_inserir after insert on pedidos
  for each row execute function trg_pedido_depois_inserir();

-- ---------- Regra: avaliação encerra a conversa ----------

create or replace function trg_avaliacao_depois_inserir()
returns trigger language plpgsql set search_path = public as $$
begin
  update conversas set status = 'encerrada', encerrada_em = now()
   where id = new.conversa_id;
  return new;
end $$;

drop trigger if exists avaliacao_depois_inserir on avaliacoes;
create trigger avaliacao_depois_inserir after insert on avaliacoes
  for each row execute function trg_avaliacao_depois_inserir();

-- ---------- Interesse: normaliza o SKU ----------

create or replace function trg_interesse_antes_inserir()
returns trigger language plpgsql set search_path = public as $$
begin
  new.sku := upper(trim(new.sku));
  return new;
end $$;

drop trigger if exists interesse_antes_inserir on interesses;
create trigger interesse_antes_inserir before insert on interesses
  for each row execute function trg_interesse_antes_inserir();

-- ---------- Catálogo em texto, para entrar no prompt do agente ----------

create or replace function brl(v numeric) returns text
language sql immutable set search_path = public as $$
  select 'R$ ' || replace(to_char(v, 'FM999990.00'), '.', ',')
$$;

create or replace function catalogo_texto()
returns text language sql stable set search_path = public as $$
  select string_agg(
    format(
      E'[%s] %s\nCategoria: %s | Público: %s\nPreço: %s%s no cartão (até %sx de %s sem juros) ou %s no Pix\nTamanhos disponíveis: %s\n%sDescrição: %s\n%s',
      p.sku, p.nome, p.categoria, p.publico,
      brl(p.preco),
      case when p.preco_original is not null
           then ' (promoção, de ' || brl(p.preco_original) || ')' else '' end,
      p.parcelas, brl(round(p.preco / p.parcelas, 2)), brl(p.preco_pix),
      coalesce((
        select string_agg(e.tamanho || ' (' || e.quantidade || ' un.)', ', ' order by e.ordem)
          from estoque e where e.sku = p.sku and e.quantidade > 0
      ), 'ESGOTADO'),
      coalesce('Medidas aproximadas (altura x largura): ' || p.medidas || E'\n', ''),
      p.descricao,
      coalesce('Características: ' || p.caracteristicas || E'\n', '')
    ),
    E'\n' order by p.sku)
  from produtos p
  where p.ativo
$$;

-- ---------- Contexto de cada mensagem (chamado pelo n8n) ----------
-- Cria o cliente e a conversa se não existirem e devolve tudo que o agente precisa.

create or replace function contexto_atendimento(p_identificador text, p_nome text default null)
returns table (conversa_id uuid, status text, cliente_nome text, catalogo text)
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

  return query select v_conversa.id, v_conversa.status, v_cliente.nome, catalogo_texto();
end $$;

-- ---------- Memória do agente ----------
-- Mesma estrutura que o nó "Postgres Chat Memory" do n8n cria sozinho.
-- Criamos antes para já nascer com RLS ligado.

create table if not exists n8n_chat_histories (
  id         serial primary key,
  session_id varchar(255) not null,
  message    jsonb not null
);

-- ---------- Segurança ----------
-- O n8n usa a conexão Postgres e a chave service_role, que ignoram o RLS.
-- Com RLS ligado e sem políticas, a chave pública (anon) não lê nem grava nada.

alter table clientes   enable row level security;
alter table produtos   enable row level security;
alter table estoque    enable row level security;
alter table conversas  enable row level security;
alter table interesses enable row level security;
alter table pedidos    enable row level security;
alter table avaliacoes enable row level security;
alter table n8n_chat_histories enable row level security;

revoke execute on function contexto_atendimento(text, text) from public;
revoke execute on function catalogo_texto() from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function contexto_atendimento(text, text) from anon, authenticated';
    execute 'revoke execute on function catalogo_texto() from anon, authenticated';
  end if;
end $$;
