-- =====================================================================
-- Olden Sports - 08_prompt_no_banco.sql
-- O comportamento da Lia (o prompt) passa a ficar no banco, com histórico
-- de versões. O n8n busca a versão ativa a cada mensagem.
-- Rode depois do 07. Pode rodar de novo sem duplicar nada.
--
-- Marcadores trocados a cada mensagem:
--   {{agora}} {{cliente_nome}} {{situacao_pedido}} {{status}} {{catalogo}}
-- =====================================================================

create table if not exists prompt_agente (
  versao     serial primary key,
  texto      text not null,
  descricao  text,
  ativo      boolean not null default false,
  criado_em  timestamptz not null default now()
);
create unique index if not exists prompt_agente_um_ativo on prompt_agente (ativo) where ativo;
alter table prompt_agente enable row level security;

-- Cria uma versão nova e ativa (se o texto for igual ao da versão ativa, não faz nada)
create or replace function nova_versao_prompt(p_texto text, p_descricao text default null)
returns text language plpgsql set search_path = public as $$
declare v_atual prompt_agente%rowtype; v_nova int;
begin
  select * into v_atual from prompt_agente where ativo;
  if found and v_atual.texto = p_texto then
    return 'Sem mudança: a versão ' || v_atual.versao || ' já é igual a este texto.';
  end if;
  update prompt_agente set ativo = false where ativo;
  insert into prompt_agente (texto, descricao, ativo) values (p_texto, p_descricao, true) returning versao into v_nova;
  return 'Versão ' || v_nova || ' criada e ativada.';
end $$;

-- Volta para uma versão anterior
create or replace function ativar_prompt(p_versao int)
returns text language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from prompt_agente where versao = p_versao) then
    return 'Versão ' || p_versao || ' não existe.';
  end if;
  update prompt_agente set ativo = false where ativo;
  update prompt_agente set ativo = true where versao = p_versao;
  return 'Versão ' || p_versao || ' ativada.';
end $$;

-- Monta o prompt final, trocando os marcadores pelos dados da conversa
create or replace function prompt_montado(p_cliente_nome text, p_status text, p_situacao text, p_catalogo text)
returns text language sql stable set search_path = public as $$
  select replace(replace(replace(replace(replace(
           coalesce((select texto from prompt_agente where ativo), 'Você é a Lia, do atendimento da Olden Sports.'),
           '{{agora}}', to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')),
           '{{cliente_nome}}', coalesce(nullif(p_cliente_nome, ''), 'ainda não informado')),
           '{{situacao_pedido}}', coalesce(p_situacao, '')),
           '{{status}}', coalesce(p_status, '')),
           '{{catalogo}}', coalesce(p_catalogo, ''))
$$;

revoke execute on function nova_versao_prompt(text, text) from public;
revoke execute on function ativar_prompt(int) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function nova_versao_prompt(text, text) from anon, authenticated';
    execute 'revoke execute on function ativar_prompt(int) from anon, authenticated';
  end if;
end $$;
