-- =====================================================================
-- Olden Sports - 05_fotos.sql: foto de cada produto
-- Rode depois do 04. Pode rodar de novo sem duplicar nada.
-- Depois preencha foto_url de cada produto (Table Editor ou update abaixo).
-- =====================================================================

alter table produtos add column if not exists foto_url text;

-- O catálogo enviado ao agente passa a incluir a foto (quando houver)
create or replace function catalogo_texto()
returns text language sql stable set search_path = public as $$
  select string_agg(
    format(
      E'[%s] %s\nCategoria: %s | Público: %s\nPreço: %s%s no cartão (até %sx de %s sem juros) ou %s no Pix\nTamanhos disponíveis: %s\n%s%sDescrição: %s\n%s',
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
      coalesce('Foto: ' || nullif(trim(p.foto_url), '') || E'\n', 'Foto: (sem foto cadastrada)' || E'\n'),
      p.descricao,
      coalesce('Características: ' || p.caracteristicas || E'\n', '')
    ),
    E'\n' order by p.sku)
  from produtos p
  where p.ativo
$$;

-- Exemplo: troque o link pelo da foto real e rode uma linha por produto
-- update produtos set foto_url = 'https://SEU-PROJETO.supabase.co/storage/v1/object/public/produtos/cel-br.jpg' where sku = 'CEL-BR';
