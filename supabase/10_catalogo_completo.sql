-- =====================================================================
-- Olden Sports - 10_catalogo_completo.sql
-- Catálogo completo da loja (passo 2 e 3 do guia técnico da vitrine):
-- um registro por modelo, um SKU por tamanho, vitrines e a busca da Lia.
--
-- Fica SEPARADO das tabelas "produtos" e "estoque" da demonstração atual,
-- que continua funcionando igual. Os dados entram pelos arquivos
-- 11_carga_catalogo_parte_*.sql.
-- Pode rodar de novo sem duplicar nada.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists unaccent with schema extensions;
create extension if not exists pg_trgm  with schema extensions;

-- unaccent "imutável", para poder usar em índice e coluna calculada
create or replace function f_unaccent(texto text)
returns text language sql immutable parallel safe strict set search_path = public, extensions as $$
  select extensions.unaccent('extensions.unaccent'::regdictionary, texto)
$$;

-- ---------- Modelos (um por produto da loja) ----------
create table if not exists catalogo_produtos (
  item_group_id     text primary key,          -- junta os tamanhos do mesmo modelo (ex.: OLD-P1293)
  id_loja           text not null unique,      -- id do produto na loja (Tray)
  nome              text not null,
  slug              text,
  url               text,
  marca             text,
  categoria         text,                      -- ex.: Camisa, Body, Boné (vem da loja)
  departamento      text,                      -- agrupamento usado nos menus e vitrines
  clube             text,
  genero            text,                      -- masculino, feminino, unissex, infantil
  faixa_etaria      text,                      -- adulto, infantil, bebe
  descricao         text,
  medidas           text,
  preco             numeric(10,2),
  preco_promocional numeric(10,2),
  preco_pix         numeric(10,2),
  parcelamento      text,
  imagens           jsonb not null default '[]'::jsonb,  -- [{url, tipo}]
  video_url         text,
  propriedades      jsonb not null default '{}'::jsonb,
  lancamento        boolean not null default false,
  destaque          boolean not null default false,
  ativo             boolean not null default true,
  coletado_em       timestamptz not null default now(),
  busca             tsvector generated always as (
    setweight(to_tsvector('portuguese', f_unaccent(coalesce(nome, ''))), 'A') ||
    setweight(to_tsvector('portuguese', f_unaccent(coalesce(categoria, '') || ' ' || coalesce(clube, '') || ' ' ||
                                                    coalesce(genero, '') || ' ' || coalesce(marca, ''))), 'B') ||
    setweight(to_tsvector('portuguese', f_unaccent(coalesce(descricao, ''))), 'C')
  ) stored
);
create index if not exists catalogo_produtos_busca on catalogo_produtos using gin (busca);
create index if not exists catalogo_produtos_nome_trgm on catalogo_produtos using gin (f_unaccent(nome) extensions.gin_trgm_ops);
create index if not exists catalogo_produtos_filtros on catalogo_produtos (departamento, genero, clube);

-- ---------- Tamanhos (um SKU por tamanho; é o retailer_id da Meta) ----------
create table if not exists catalogo_variantes (
  sku               text primary key,          -- ex.: OLD-5197
  id_loja_variante  text not null unique,
  item_group_id     text not null references catalogo_produtos(item_group_id) on delete cascade,
  tamanho           text,
  cor               text,
  ordem             int not null default 0,
  preco             numeric(10,2),
  preco_promocional numeric(10,2),
  preco_pix         numeric(10,2),
  disponivel        boolean not null default true,
  quantidade        int not null default 0 check (quantidade >= 0),  -- fictício no teste: 8 se disponível
  imagem            text,
  meta_sincronizado_em timestamptz
);
create index if not exists catalogo_variantes_grupo on catalogo_variantes (item_group_id);

-- ---------- Vitrines montadas pela Olden ----------
create table if not exists vitrines (
  nome      text primary key,                  -- ex.: lancamentos, mais-vendidos, palmeiras
  titulo    text not null,
  descricao text,
  modelos   text[] not null default '{}',      -- item_group_id, na ordem de exibição
  ativa     boolean not null default true,
  ordem     int not null default 0
);

alter table catalogo_produtos  enable row level security;
alter table catalogo_variantes enable row level security;
alter table vitrines           enable row level security;

-- ---------- Busca da Lia ----------
-- Todos os filtros são opcionais: departamento, categoria, clube, genero, faixa_etaria,
-- tamanho, preco_max. Devolve no máximo 10 modelos, só com tamanhos disponíveis.
create or replace function buscar_produtos(consulta text default '', filtros jsonb default '{}'::jsonb, limite int default 5)
returns table (item_group_id text, nome text, preco numeric, preco_pix numeric, tamanhos text[], skus text[],
               resumo text, imagem text, url text, relevancia real)
language sql stable set search_path = public, extensions as $$
  with q as (
    select nullif(trim(coalesce(consulta, '')), '') as texto,
           case when nullif(trim(coalesce(consulta, '')), '') is null then null
                else nullif(replace(plainto_tsquery('portuguese', f_unaccent(consulta))::text, ' & ', ' | '), '')::tsquery
           end as tsq
  ),
  candidatos as (
    select p.*,
           case when q.texto is null then 0
                else coalesce(ts_rank(p.busca, q.tsq), 0)
                     + similarity(f_unaccent(lower(p.nome)), f_unaccent(lower(q.texto)))
           end as rel
    from catalogo_produtos p, q
    where p.ativo
      and (filtros->>'departamento' is null or p.departamento = filtros->>'departamento')
      and (filtros->>'categoria'    is null or f_unaccent(lower(p.categoria)) = f_unaccent(lower(filtros->>'categoria')))
      and (filtros->>'clube'        is null or f_unaccent(lower(p.clube))     = f_unaccent(lower(filtros->>'clube')))
      and (filtros->>'genero'       is null or p.genero = filtros->>'genero')
      and (filtros->>'faixa_etaria' is null or p.faixa_etaria = filtros->>'faixa_etaria')
      and (filtros->>'preco_max'    is null or coalesce(p.preco_pix, p.preco) <= (filtros->>'preco_max')::numeric)
      and (q.texto is null
           or (q.tsq is not null and p.busca @@ q.tsq)
           or similarity(f_unaccent(lower(p.nome)), f_unaccent(lower(q.texto))) > 0.2)
  )
  select c.item_group_id, c.nome, coalesce(nullif(c.preco_promocional, 0), c.preco), c.preco_pix,
         array_agg(v.tamanho order by v.ordem), array_agg(v.sku order by v.ordem),
         left(c.descricao, 200), c.imagens->0->>'url', c.url, c.rel::real
  from candidatos c
  join catalogo_variantes v on v.item_group_id = c.item_group_id and v.disponivel and v.quantidade > 0
  where (filtros->>'tamanho' is null
         or exists (select 1 from catalogo_variantes v2
                     where v2.item_group_id = c.item_group_id and v2.disponivel and v2.quantidade > 0
                       and upper(v2.tamanho) = upper(filtros->>'tamanho')))
  group by c.item_group_id, c.nome, c.preco, c.preco_promocional, c.preco_pix, c.descricao, c.imagens, c.url, c.rel, c.destaque, c.lancamento
  order by c.rel desc, c.destaque desc, c.lancamento desc, c.nome
  limit least(greatest(coalesce(limite, 5), 1), 10)
$$;

-- Departamentos e quantos modelos com estoque cada um tem (para o menu da Lia)
create or replace view departamentos_catalogo as
select p.departamento, count(distinct p.item_group_id) as modelos
from catalogo_produtos p
join catalogo_variantes v on v.item_group_id = p.item_group_id and v.disponivel and v.quantidade > 0
where p.ativo
group by p.departamento
order by modelos desc;

revoke execute on function buscar_produtos(text, jsonb, int) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function buscar_produtos(text, jsonb, int) from anon, authenticated';
    execute 'revoke select on departamentos_catalogo from anon, authenticated';
  end if;
end $$;
