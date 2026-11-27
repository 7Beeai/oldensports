-- =====================================================================
-- Olden Sports - 17_regra_precos.sql
-- Regra de preço da Olden: existem só dois valores.
--   Cartão = preço cheio (preco)
--   Pix    = valor promocional (preco_promocional do site, quando houver;
--            sem promoção, o preço Pix do site)
-- O preço promocional NUNCA vale no cartão, e o cheio nunca vale no Pix.
--
-- Esta função reescreve os preços do catálogo nessa regra (os valores
-- originais do site ficam em *_site). Depois dela, preco é sempre o
-- cartão e preco_pix é sempre o Pix, em todas as funções e no pedido.
-- Depois de recarregar o catálogo do site (arquivos 11), rode:
--   update catalogo_produtos set precos_site_salvos = false;
--   update catalogo_variantes set precos_site_salvos = false;
--   select aplicar_regra_precos();
-- =====================================================================

alter table catalogo_produtos  add column if not exists preco_promocional_site numeric;
alter table catalogo_produtos  add column if not exists preco_pix_site numeric;
alter table catalogo_produtos  add column if not exists parcelamento_site text;
alter table catalogo_variantes add column if not exists preco_promocional_site numeric;
alter table catalogo_variantes add column if not exists preco_pix_site numeric;
alter table catalogo_produtos  add column if not exists precos_site_salvos boolean not null default false;
alter table catalogo_variantes add column if not exists precos_site_salvos boolean not null default false;

create or replace function aplicar_regra_precos()
returns jsonb
language plpgsql
set search_path = public
as $$
declare v_modelos int; v_tamanhos int;
begin
  -- Guarda os valores do site uma única vez (idempotente)
  -- (uma carga nova do site entra com precos_site_salvos = false)
  update catalogo_produtos set preco_promocional_site = preco_promocional, preco_pix_site = preco_pix,
         parcelamento_site = parcelamento, precos_site_salvos = true
   where not precos_site_salvos;
  update catalogo_variantes set preco_promocional_site = preco_promocional, preco_pix_site = preco_pix, precos_site_salvos = true
   where not precos_site_salvos;

  -- Pix = promocional do site (se houver promoção); cartão = cheio. Não há mais "promoção no cartão".
  update catalogo_produtos set
         preco_pix = case when coalesce(preco_promocional_site, 0) > 0 and preco_promocional_site < preco
                          then preco_promocional_site else preco_pix_site end,
         preco_promocional = null
   where true;
  get diagnostics v_modelos = row_count;

  update catalogo_variantes set
         preco_pix = case when coalesce(preco_promocional_site, 0) > 0 and preco_promocional_site < preco
                          then preco_promocional_site else preco_pix_site end,
         preco_promocional = null
   where true;
  get diagnostics v_tamanhos = row_count;

  -- Parcelamento recalculado sobre o preço do cartão (o site calculava sobre o promocional)
  update catalogo_produtos set parcelamento =
         case when parcelamento_site ~ '^\d+x'
              then substring(parcelamento_site from '^(\d+)x') || 'x de R$ '
                   || replace(to_char(round(preco / substring(parcelamento_site from '^(\d+)x')::int, 2), 'FM999999990.00'), '.', ',')
                   || ' sem juros'
              else parcelamento_site end
   where true;

  return jsonb_build_object('modelos', v_modelos, 'tamanhos', v_tamanhos);
end $$;

select aplicar_regra_precos();
