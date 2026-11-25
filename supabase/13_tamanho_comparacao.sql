-- =====================================================================
-- Olden Sports - 13_tamanho_comparacao.sql
-- Passo 5 do guia: ajuda com o tamanho e comparação entre duas peças.
-- Rode depois do 12. Pode rodar de novo sem duplicar nada.
-- =====================================================================

-- Normaliza o nome de um tamanho para comparar ("04 ANOS" = "4", "XG(3G)" = "XG")
create or replace function tamanho_normalizado(t text)
returns text language sql immutable set search_path = public, extensions as $$
  select regexp_replace(
           regexp_replace(upper(f_unaccent(regexp_replace(coalesce(t, ''), '\(.*\)', '', 'g'))), '\s*ANOS?\y|[^A-Z0-9-]', '', 'g'),
           '(^|-)0+(\d)', '\1\2', 'g')
$$;

-- ---------- Tabela de medidas (tirada da descrição de cada produto) ----------
create table if not exists tabela_medidas (
  item_group_id  text not null references catalogo_produtos(item_group_id) on delete cascade,
  tamanho        text not null,          -- como aparece na descrição (ex.: P, 06 ANOS, XG(3G))
  tamanho_norm   text not null,
  comprimento_cm numeric(5,1),           -- A (altura da peça)
  largura_cm     numeric(5,1),           -- L (largura da peça, de lado a lado)
  indicacao      text,                   -- ex.: "1 a 3 meses"
  primary key (item_group_id, tamanho_norm)
);
alter table tabela_medidas enable row level security;

create or replace function atualizar_tabela_medidas()
returns int language plpgsql set search_path = public as $$
declare v int;
begin
  delete from tabela_medidas;
  insert into tabela_medidas (item_group_id, tamanho, tamanho_norm, comprimento_cm, largura_cm, indicacao)
  select distinct on (item_group_id, tamanho_normalizado(rotulo))
         item_group_id, rotulo, tamanho_normalizado(rotulo), comp, larg, indic
  from (
    select p.item_group_id, l.ordem,
           trim(m[1]) as rotulo,
           replace(m[2], ',', '.')::numeric as comp,
           replace(m[3], ',', '.')::numeric as larg,
           null::text as indic
    from catalogo_produtos p
    cross join lateral regexp_split_to_table(p.medidas, '\n') with ordinality as l(linha, ordem)
    cross join lateral regexp_match(l.linha,
      '^\s*(?:tam(?:anho)?\.?\s*)?([A-Za-z0-9]{1,3}(?:\s*\(?[A-Za-z0-9 ]{0,6}\)?)?(?:\s*anos?)?)\s*(?:\([^)]*\))?\s*:\s*(\d+(?:[.,]\d+)?)\s*[xX]\s*(\d+(?:[.,]\d+)?)') as m
    where p.medidas is not null
    union all
    select p.item_group_id, l.ordem, trim(m[1]), null, null, trim(m[2])
    from catalogo_produtos p
    cross join lateral regexp_split_to_table(p.medidas, '\n') with ordinality as l(linha, ordem)
    cross join lateral regexp_match(l.linha, '^\s*([A-Za-z0-9]{1,3})\s*:\s*(\d+\s*a\s*\d+\s*mes(?:es)?)') as m
    where p.medidas is not null
  ) x
  where tamanho_normalizado(rotulo) <> ''
  order by item_group_id, tamanho_normalizado(rotulo), ordem;   -- fica a primeira peça do kit (a camisa)
  get diagnostics v = row_count;
  return v;
end $$;

select atualizar_tabela_medidas();

-- ---------- Atributos para comparar (tirados da descrição) ----------
create or replace function atributo_da_descricao(p_descricao text, p_palavras text, p_so_linha boolean default false)
returns text language sql immutable set search_path = public as $$
  -- 1º: linha do tipo "Composição: ..." ou "- Gola: ..."; 2º: a frase que cita a palavra
  select coalesce(
    (select trim(m[1]) from regexp_matches(p_descricao, '(?im)^\s*[-•*]?\s*((?:' || p_palavras || ')[^:\n]{0,20}:\s*[^\n]{1,120})') as m limit 1),
    case when p_so_linha then null else
      (select left(trim(m[1]), 140) from regexp_matches(p_descricao, '(?i)([^.\n]*\y(?:' || p_palavras || ')\y[^.\n]*)') as m limit 1) end)
$$;

create or replace function atributos_produto(p_grupo text)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'material', atributo_da_descricao(p.descricao, 'composi[cç][aã]o|material|tecido'),
    'gola',     atributo_da_descricao(p.descricao, 'gola'),
    'escudo',   atributo_da_descricao(p.descricao, 'escudo|emblema'),
    'manga',    atributo_da_descricao(p.descricao, 'manga', true)))
  from catalogo_produtos p where p.item_group_id = p_grupo
$$;

-- produtos_para_blocos passa a levar os atributos e a categoria (para o formulário de tamanho)
create or replace function produtos_para_blocos(p_skus jsonb)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_object_agg(x.chave, x.dados), '{}'::jsonb)
  from (
    select s.chave, jsonb_build_object(
             'item_group_id', p.item_group_id, 'nome', p.nome,
             'preco', coalesce(nullif(p.preco_promocional, 0), p.preco), 'preco_original', p.preco,
             'preco_pix', p.preco_pix, 'parcelamento', p.parcelamento,
             'imagem', p.imagens->0->>'url', 'imagens', p.imagens, 'video', p.video_url, 'url', p.url,
             'departamento', p.departamento, 'faixa_etaria', p.faixa_etaria, 'genero', p.genero,
             'atributos', atributos_produto(p.item_group_id),
             'tamanho', v.tamanho,
             'tamanhos', (select jsonb_agg(v2.tamanho order by v2.ordem) from catalogo_variantes v2
                           where v2.item_group_id = p.item_group_id and v2.disponivel and v2.quantidade > 0),
             'disponivel', case when v.sku is not null then v.disponivel and v.quantidade > 0
                                else exists (select 1 from catalogo_variantes v3 where v3.item_group_id = p.item_group_id
                                              and v3.disponivel and v3.quantidade > 0) end and p.ativo,
             'resumo', left(p.descricao, 160)) as dados
    from (select distinct upper(trim(value)) as chave from jsonb_array_elements_text(coalesce(p_skus, '[]'::jsonb))) s
    left join catalogo_variantes v on v.sku = s.chave
    join catalogo_produtos p on p.item_group_id = coalesce(v.item_group_id, s.chave)
  ) x
$$;

-- ---------- Detalhes completos de uma peça (ferramenta da Lia) ----------
create or replace function detalhes_produto(p_sku text)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'item_group_id', p.item_group_id, 'nome', p.nome, 'marca', p.marca, 'clube', p.clube,
    'preco', coalesce(nullif(p.preco_promocional, 0), p.preco), 'preco_original', p.preco,
    'preco_pix', p.preco_pix, 'parcelamento', p.parcelamento,
    'descricao', p.descricao, 'medidas', p.medidas, 'atributos', atributos_produto(p.item_group_id),
    'tamanhos', (select jsonb_agg(jsonb_build_object('tamanho', v.tamanho, 'sku', v.sku,
                   'disponivel', v.disponivel and v.quantidade > 0) order by v.ordem)
                 from catalogo_variantes v where v.item_group_id = p.item_group_id),
    'fotos', jsonb_array_length(p.imagens), 'tem_video', p.video_url is not null, 'link', p.url)
  from catalogo_produtos p
  where p.item_group_id = coalesce((select item_group_id from catalogo_variantes where sku = upper(trim(p_sku))), upper(trim(p_sku)))
$$;

-- ---------- Recomendação de tamanho ----------
-- Adulto: estima o tórax pela altura e pelo peso e escolhe o menor tamanho cuja largura
-- da peça (x2) cobre o tórax mais a folga do caimento. Sem medidas, usa uma tabela por peso.
-- Infantil: usa a idade. É uma estimativa: a Lia apresenta como sugestão.
create or replace function recomendar_tamanho(p_sku text, p_altura_cm numeric default null, p_peso_kg numeric default null,
                                              p_caimento text default 'normal', p_idade_anos numeric default null)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_grupo text; v_prod catalogo_produtos%rowtype;
  v_torax numeric; v_folga numeric; v_alvo text; v_motivo text; v_disp jsonb; v_disponivel boolean;
  v_alt text;
begin
  select coalesce((select item_group_id from catalogo_variantes where sku = upper(trim(p_sku))), upper(trim(p_sku))) into v_grupo;
  select * into v_prod from catalogo_produtos where item_group_id = v_grupo;
  if not found then
    return jsonb_build_object('erro', 'Produto não encontrado. Use o código que veio da busca.');
  end if;

  select jsonb_agg(v.tamanho order by v.ordem) into v_disp
    from catalogo_variantes v where v.item_group_id = v_grupo and v.disponivel and v.quantidade > 0;

  if v_prod.faixa_etaria in ('infantil', 'bebe') then
    if p_idade_anos is null then
      return jsonb_build_object('precisa', 'idade', 'tamanhos_disponiveis', v_disp,
                                'medidas', v_prod.medidas, 'mensagem', 'Pergunte a idade da criança.');
    end if;
    -- tamanho cujo número (ou faixa, ex.: 4-8) contém a idade; senão o mais próximo acima
    select v.tamanho into v_alvo from catalogo_variantes v
     where v.item_group_id = v_grupo
       and (case when tamanho_normalizado(v.tamanho) ~ '^\d+-\d+$'
                 then p_idade_anos between split_part(tamanho_normalizado(v.tamanho), '-', 1)::numeric
                                       and split_part(tamanho_normalizado(v.tamanho), '-', 2)::numeric
                 when tamanho_normalizado(v.tamanho) ~ '^\d+$'
                 then tamanho_normalizado(v.tamanho)::numeric >= p_idade_anos
                 else false end)
     order by case when tamanho_normalizado(v.tamanho) ~ '^\d+$' then tamanho_normalizado(v.tamanho)::numeric else 0 end, v.ordem
     limit 1;
    v_motivo := 'pela idade de ' || p_idade_anos || ' anos';
  else
    if p_altura_cm is null or p_peso_kg is null then
      return jsonb_build_object('precisa', 'altura e peso', 'tamanhos_disponiveis', v_disp,
                                'medidas', v_prod.medidas, 'mensagem', 'Pergunte altura e peso, e se prefere justa, normal ou solta.');
    end if;
    v_torax := 0.45 * p_peso_kg + 0.30 * p_altura_cm + 14 - case when v_prod.genero = 'feminino' then 4 else 0 end;
    v_folga := case lower(coalesce(p_caimento, 'normal')) when 'justa' then 4 when 'solta' then 18 else 10 end;

    select v.tamanho into v_alvo
      from catalogo_variantes v
      join tabela_medidas t on t.item_group_id = v.item_group_id and t.tamanho_norm = tamanho_normalizado(v.tamanho)
     where v.item_group_id = v_grupo and t.largura_cm is not null and t.largura_cm * 2 >= v_torax + v_folga
     order by t.largura_cm, v.ordem
     limit 1;

    if v_alvo is null and exists (select 1 from tabela_medidas t where t.item_group_id = v_grupo and t.largura_cm is not null) then
      -- nenhum tamanho cobre: sugere o maior, avisando que pode ficar mais justo
      select v.tamanho into v_alvo
        from catalogo_variantes v
        join tabela_medidas t on t.item_group_id = v.item_group_id and t.tamanho_norm = tamanho_normalizado(v.tamanho)
       where v.item_group_id = v_grupo and t.largura_cm is not null
       order by t.largura_cm desc limit 1;
      v_motivo := 'é o maior tamanho desta peça, mas pode ficar mais justa que o caimento ' || coalesce(p_caimento, 'normal') || ' (tórax estimado de ' || round(v_torax) || ' cm)';
    elsif v_alvo is not null then
      v_motivo := 'pelas medidas da peça: tórax estimado de ' || round(v_torax) || ' cm + folga para caimento ' || coalesce(p_caimento, 'normal');
    else
      -- sem medidas (ou maior que a maior medida): tabela geral por peso
      v_alt := case when v_prod.genero = 'feminino'
                    then case when p_peso_kg <= 55 then 'P' when p_peso_kg <= 65 then 'M' when p_peso_kg <= 75 then 'G' when p_peso_kg <= 85 then 'GG' else 'XG' end
                    else case when p_peso_kg <= 65 then 'P' when p_peso_kg <= 77 then 'M' when p_peso_kg <= 88 then 'G' when p_peso_kg <= 100 then 'GG' else 'XG' end end;
      if lower(coalesce(p_caimento, '')) = 'solta' then
        v_alt := case v_alt when 'P' then 'M' when 'M' then 'G' when 'G' then 'GG' else 'XG' end;
      end if;
      select v.tamanho into v_alvo from catalogo_variantes v
       where v.item_group_id = v_grupo and tamanho_normalizado(v.tamanho) = v_alt limit 1;
      if v_alvo is null then
        -- a peça não tem esse tamanho: fica com o maior que ela tem
        select v.tamanho into v_alvo from catalogo_variantes v where v.item_group_id = v_grupo order by v.ordem desc limit 1;
      end if;
      v_motivo := 'pela tabela geral de tamanhos (peso ' || p_peso_kg || ' kg, caimento ' || coalesce(p_caimento, 'normal') || ')';
    end if;
  end if;

  if v_alvo is null then
    return jsonb_build_object('tamanho_sugerido', null, 'tamanhos_disponiveis', v_disp, 'medidas', v_prod.medidas,
                              'mensagem', 'Não consegui calcular com segurança. Mostre as medidas e sugira comparar com uma peça que o cliente já tem.');
  end if;

  select exists (select 1 from catalogo_variantes v where v.item_group_id = v_grupo and v.tamanho = v_alvo
                  and v.disponivel and v.quantidade > 0) into v_disponivel;

  return jsonb_build_object(
    'produto', v_prod.nome,
    'tamanho_sugerido', v_alvo,
    'disponivel', v_disponivel,
    'sku_sugerido', (select v.sku from catalogo_variantes v where v.item_group_id = v_grupo and v.tamanho = v_alvo limit 1),
    'tamanhos_disponiveis', v_disp,
    'medidas_do_sugerido', (select jsonb_build_object('comprimento_cm', t.comprimento_cm, 'largura_cm', t.largura_cm)
                             from tabela_medidas t where t.item_group_id = v_grupo and t.tamanho_norm = tamanho_normalizado(v_alvo)),
    'como_calculei', v_motivo,
    'observacao', 'É uma sugestão. Se o cliente tiver uma camisa que veste bem, comparar as medidas é o mais seguro.');
end $$;

-- ---------- Comparação de duas peças (página pública e bloco do chat) ----------
create or replace function comparar_produtos(p_a text, p_b text)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object('produtos', jsonb_agg(d order by ord))
  from (
    select ord, jsonb_build_object(
      'item_group_id', p.item_group_id, 'nome', p.nome, 'imagem', p.imagens->0->>'url',
      'preco', coalesce(nullif(p.preco_promocional, 0), p.preco), 'preco_original', p.preco, 'preco_pix', p.preco_pix,
      'tamanhos', (select jsonb_agg(v.tamanho order by v.ordem) from catalogo_variantes v
                    where v.item_group_id = p.item_group_id and v.disponivel and v.quantidade > 0),
      'atributos', atributos_produto(p.item_group_id)) as d
    from (values (1, p_a), (2, p_b)) as x(ord, sku)
    join catalogo_produtos p on p.item_group_id = coalesce((select item_group_id from catalogo_variantes where sku = upper(trim(x.sku))), upper(trim(x.sku)))
  ) s
$$;

revoke execute on function recomendar_tamanho(text, numeric, numeric, text, numeric) from public;
revoke execute on function detalhes_produto(text) from public;
revoke execute on function comparar_produtos(text, text) from public;
revoke execute on function atualizar_tabela_medidas() from public;
revoke execute on function atributo_da_descricao(text, text, boolean) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function recomendar_tamanho(text, numeric, numeric, text, numeric) from anon, authenticated';
    execute 'revoke execute on function detalhes_produto(text) from anon, authenticated';
    execute 'revoke execute on function comparar_produtos(text, text) from anon, authenticated';
    execute 'revoke execute on function atualizar_tabela_medidas() from anon, authenticated';
  end if;
end $$;

-- ---------- Cenários do passo 5 ----------
insert into cenarios_teste (id, titulo, turnos, esperado, criterios_juiz) values
('C29', 'Indecisa entre duas camisas',
 '["Tô em dúvida entre a Palestra Celebration e a polo verde Palestra do Palmeiras, qual a diferença?"]',
 '{"pedidos_qtd": 0, "blocos_incluem": ["comparacao"]}',
 'Manda a comparação lado a lado (bloco comparacao) das duas peças certas e botões para escolher uma delas. Diferenças só com dados reais (material, gola, preço).'),
('C31', 'Responde o formulário de tamanho',
 '["Gostei da camisa Palmeiras Palestra Celebration masculina", "Minhas medidas: altura 172 cm, peso 70 kg, caimento normal"]',
 '{"pedidos_qtd": 0}',
 'No turno 2 usa a recomendação de tamanho e responde o tamanho sugerido (M para esse caso, conferir no cálculo) dizendo se tem em estoque, como sugestão e não como certeza. Não inventa medidas.')
on conflict (id) do update set
  titulo = excluded.titulo, turnos = excluded.turnos, esperado = excluded.esperado,
  criterios_juiz = excluded.criterios_juiz;

update cenarios_teste set esperado = '{"pedidos_qtd": 0, "blocos_incluem": ["tamanho"]}',
  criterios_juiz = 'Manda o formulário de tamanho (bloco tamanho) da Palestra Celebration, ou pergunta altura, peso e caimento. Não inventa tabela de medidas.'
where id = 'C30';
