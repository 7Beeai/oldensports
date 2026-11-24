# Transforma os dados coletados da loja (API web pública da Tray) nos SQL de carga do catálogo.
# Uso: python3 n8n/build/montar-carga-catalogo.py PASTA_DOS_DADOS PASTA_DE_SAIDA
#   PASTA_DOS_DADOS tem produtos.json, variantes.json e detalhes/<id>.json
#   Gera 11_carga_catalogo_parte_N.sql (cada parte cabe no SQL Editor do Supabase)
import html, json, os, re, sys, unicodedata
from datetime import datetime, timezone

DADOS, SAIDA = sys.argv[1], sys.argv[2]
PRODUTOS_POR_PARTE = 161
ORDEM_TAMANHOS = ['RN', 'PP', 'P', 'M', 'G', 'GG', 'XG', 'XGG', 'EG', 'EGG', 'G1', 'G2', 'G3', 'G4', 'U', 'UNICO', 'ÚNICO']

DEPARTAMENTOS = {
    'Camisa': 'camisas', 'Boné': 'bones', 'Kits': 'kits', 'Body': 'bebe', 'Conjunto Infantil': 'infantil',
    'Tênis': 'calcados', 'Chuteira Futsal': 'calcados', 'Chuteira Campo': 'calcados', 'Chuteira Society': 'calcados',
    'Babuche': 'calcados', 'Chinelo': 'calcados', 'Sapatilha': 'calcados',
    'Bola': 'equipamentos', 'Luvas de Goleiro': 'equipamentos', 'Caneleira': 'equipamentos', 'Luva': 'equipamentos',
    'Blusas e Jaquetas': 'roupas', 'Bermuda': 'roupas', 'Vestido': 'roupas', 'Top': 'roupas', 'Meia': 'roupas',
    'Cueca': 'roupas', 'Calça': 'roupas',
    'Acessórios': 'acessorios', 'Mochila': 'acessorios', 'Copos e Canecas': 'acessorios', 'Óculos': 'acessorios',
    'Squeeze': 'acessorios', 'Cachecol': 'acessorios', 'Mascote': 'acessorios',
}


def sem_acento(s):
    return ''.join(c for c in unicodedata.normalize('NFD', s or '') if unicodedata.category(c) != 'Mn').lower()


def texto_de_html(h):
    if not h:
        return ''
    h = re.sub(r'(?i)<br\s*/?>|</p>|</li>|</h\d>', '\n', h)
    h = re.sub(r'<[^>]+>', '', h)
    h = html.unescape(h).replace('\xa0', ' ')
    linhas = [re.sub(r'[ \t]+', ' ', l).strip() for l in h.split('\n')]
    return '\n'.join(l for l in linhas if l).strip()


def numero(v):
    try:
        n = float(v)
        return round(n, 2) if n > 0 else None
    except (TypeError, ValueError):
        return None


def preco_pix(opcao):
    m = re.search(r'R\$\s*([\d.]+,\d{2})\s*(?:&agrave;|à) vista', html.unescape(opcao or '').replace('&agrave;', 'à'))
    return round(float(m.group(1).replace('.', '').replace(',', '.')), 2) if m else None


def parcelamento(opcao):
    m = re.search(r'(\d+x de R\$\s*[\d.,]+[^<]*)', html.unescape(opcao or ''))
    return m.group(1).strip() if m else None


def primeiro(props, *chaves):
    for k in chaves:
        v = (props or {}).get(k)
        if v:
            return v[0]
    return None


def genero_e_faixa(props, nome):
    g = sem_acento(primeiro(props, 'Gênero') or '')
    n = sem_acento(nome)
    if any(x in n for x in ['baby', 'bebe', 'body ']) or n.startswith('body'):
        return 'infantil', 'bebe'
    if g in ('infantil', 'juvenil', 'menino') or 'infantil' in n or 'juvenil' in n:
        return 'infantil', 'infantil'
    if g == 'feminino' or 'feminin' in n or 'baby look' in n:
        return 'feminino', 'adulto'
    if g == 'masculino' or 'masculin' in n:
        return 'masculino', 'adulto'
    return 'unissex', 'adulto'


def medidas_da_descricao(texto):
    m = re.search(r'(?is)(medidas?[^\n]*\n?)(.*)', texto)
    if not m:
        return None
    bloco = (m.group(1) + m.group(2)).strip()
    return bloco[:800] if bloco else None


def ordem_tamanho(t):
    t2 = (t or '').upper().strip()
    if t2 in ORDEM_TAMANHOS:
        return ORDEM_TAMANHOS.index(t2)
    m = re.match(r'(\d+)', t2)
    return 100 + int(m.group(1)) if m else 500


produtos = [x['Product'] for x in json.load(open(os.path.join(DADOS, 'produtos.json')))]
variantes = [x['Variant'] for x in json.load(open(os.path.join(DADOS, 'variantes.json')))]
por_produto = {}
for v in variantes:
    por_produto.setdefault(v['product_id'], []).append(v)

agora = datetime.now(timezone.utc).isoformat()
linhas_p, linhas_v, pendencias = [], [], []
for p in produtos:
    pid = p['id']
    det_path = os.path.join(DADOS, 'detalhes', pid + '.json')
    det = json.load(open(det_path)) if os.path.exists(det_path) else {}
    props = p.get('Properties') or {}
    nome = html.unescape(p['name']).strip()
    descricao = texto_de_html(det.get('description'))
    imagens = [{'url': i.get('https'), 'tipo': 'frente' if n == 0 else 'extra'}
               for n, i in enumerate(p.get('ProductImage') or []) if i.get('https')]
    if not imagens:
        pendencias.append(f'{pid} {nome}: sem foto')
    genero, faixa = genero_e_faixa(props, nome)
    categoria = primeiro(props, 'Categoria')
    grupo = 'OLD-P' + pid
    linhas_p.append({
        'item_group_id': grupo, 'id_loja': pid, 'nome': nome, 'slug': p.get('slug'),
        'url': (p.get('url') or {}).get('https'), 'marca': p.get('brand') or None,
        'categoria': categoria, 'departamento': DEPARTAMENTOS.get(categoria, 'outros'),
        'clube': primeiro(props, 'Clubes', 'Times'), 'genero': genero, 'faixa_etaria': faixa,
        'descricao': descricao or None, 'medidas': medidas_da_descricao(descricao),
        'preco': numero(p.get('price')), 'preco_promocional': numero(p.get('promotional_price')),
        'preco_pix': preco_pix(p.get('payment_option')), 'parcelamento': parcelamento(p.get('payment_option')),
        'imagens': imagens, 'video_url': p.get('video') or None, 'propriedades': props,
        'lancamento': p.get('release') == '1', 'destaque': p.get('hot') == '1', 'coletado_em': agora,
    })
    vs = por_produto.get(pid, [])
    if not vs:
        # produto sem variação: vira um SKU de tamanho único
        vs = [{'id': 'U' + pid, 'Sku': [{'type': 'Tamanho', 'value': 'ÚNICO'}], 'price': p.get('price'),
               'promotional_price': p.get('promotional_price'), 'available': p.get('available'),
               'payment_option': p.get('payment_option'), 'VariantImage': []}]
    for v in vs:
        tamanho = cor = None
        for s in v.get('Sku') or []:
            t = sem_acento(s.get('type'))
            if 'tamanho' in t or 'numero' in t:
                tamanho = s.get('value')
            elif 'cor' in t:
                cor = s.get('value')
            elif tamanho is None:
                tamanho = s.get('value')
        disponivel = str(v.get('available')) == '1'
        img = (v.get('VariantImage') or [{}])[0].get('https') if v.get('VariantImage') else None
        linhas_v.append({
            'sku': 'OLD-' + str(v['id']), 'id_loja_variante': str(v['id']), 'item_group_id': grupo,
            'tamanho': tamanho or 'ÚNICO', 'cor': cor, 'ordem': ordem_tamanho(tamanho),
            'preco': numero(v.get('price')), 'preco_promocional': numero(v.get('promotional_price')),
            'preco_pix': preco_pix(v.get('payment_option')), 'disponivel': disponivel,
            'quantidade': 8 if disponivel else 0, 'imagem': img,
        })

os.makedirs(SAIDA, exist_ok=True)
for f in os.listdir(SAIDA):
    if f.startswith('11_carga_catalogo_parte_'):
        os.remove(os.path.join(SAIDA, f))

COLS_P = list(linhas_p[0].keys())
COLS_V = list(linhas_v[0].keys())
TIPOS = {'imagens': 'jsonb', 'propriedades': 'jsonb', 'lancamento': 'boolean', 'destaque': 'boolean',
         'disponivel': 'boolean', 'ordem': 'int', 'quantidade': 'int', 'coletado_em': 'timestamptz',
         'preco': 'numeric', 'preco_promocional': 'numeric', 'preco_pix': 'numeric'}


def recordset(cols):
    return ', '.join(f'{c} {TIPOS.get(c, "text")}' for c in cols)


def bloco_json(dados):
    s = json.dumps(dados, ensure_ascii=False)
    assert '$dados$' not in s
    return '$dados$' + s + '$dados$'


partes = [linhas_p[i:i + PRODUTOS_POR_PARTE] for i in range(0, len(linhas_p), PRODUTOS_POR_PARTE)]
for n, parte in enumerate(partes, 1):
    grupos = {x['item_group_id'] for x in parte}
    vars_parte = [v for v in linhas_v if v['item_group_id'] in grupos]
    upd_p = ', '.join(f'{c} = excluded.{c}' for c in COLS_P if c != 'item_group_id')
    upd_v = ', '.join(f'{c} = excluded.{c}' for c in COLS_V if c != 'sku')
    sql = f"""-- Carga do catálogo da Olden: parte {n} de {len(partes)} ({len(parte)} modelos, {len(vars_parte)} tamanhos)
-- Coletado do site oficial em {agora[:10]}. Rode depois do 10_catalogo_completo.sql. Pode rodar de novo.

insert into catalogo_produtos ({', '.join(COLS_P)}, ativo)
select {', '.join(COLS_P)}, true
from jsonb_to_recordset({bloco_json(parte)}::jsonb) as x({recordset(COLS_P)})
on conflict (item_group_id) do update set {upd_p}, ativo = true;

insert into catalogo_variantes ({', '.join(COLS_V)})
select {', '.join(COLS_V)}
from jsonb_to_recordset({bloco_json(vars_parte)}::jsonb) as x({recordset(COLS_V)})
on conflict (sku) do update set {upd_v};
"""
    if n == len(partes):
        sql += """
-- ---------- Vitrines iniciais (a Olden pode editar depois) ----------
insert into vitrines (nome, titulo, descricao, modelos, ordem)
select 'promocoes', 'Promoções', 'Peças com preço promocional',
       coalesce((select array_agg(item_group_id order by (preco - preco_promocional) / nullif(preco, 0) desc)
                 from (select * from catalogo_produtos
                       where ativo and preco_promocional > 0 and preco_promocional < preco
                       order by (preco - preco_promocional) / nullif(preco, 0) desc limit 30) s), '{}'), 1
on conflict (nome) do update set modelos = excluded.modelos;

insert into vitrines (nome, titulo, descricao, modelos, ordem)
select 'destaques', 'Destaques da loja', 'Peças em destaque no site',
       coalesce((select array_agg(item_group_id order by nome) from catalogo_produtos where ativo and destaque), '{}'), 2
on conflict (nome) do update set modelos = excluded.modelos;

insert into vitrines (nome, titulo, descricao, modelos, ordem)
select 'palmeiras', 'Palmeiras', 'Linha Palmeiras (campanha das Gêmeas)',
       coalesce((select array_agg(item_group_id order by destaque desc, nome)
                 from (select * from catalogo_produtos where ativo and clube = 'Palmeiras'
                       order by destaque desc, nome limit 30) s), '{}'), 3
on conflict (nome) do update set modelos = excluded.modelos;
"""
    open(os.path.join(SAIDA, f'11_carga_catalogo_parte_{n}.sql'), 'w').write(sql)
    print(f'parte {n}: {len(parte)} modelos, {len(vars_parte)} tamanhos, {len(sql) // 1024} KB')

open(os.path.join(SAIDA, 'pendencias_catalogo.txt'), 'w').write('\n'.join(pendencias) + ('\n' if pendencias else ''))
print('total', len(linhas_p), 'modelos,', len(linhas_v), 'tamanhos;', len(pendencias), 'pendências')
