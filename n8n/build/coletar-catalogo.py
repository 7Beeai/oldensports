# Coleta os produtos disponíveis do site oficial (API web pública da Tray), com pausa entre consultas e retomada.
# Uso: python3 n8n/build/coletar-catalogo.py PASTA_DOS_DADOS   (depois: montar-carga-catalogo.py)
import json, os, sys, time, urllib.request, urllib.error
BASE = 'https://www.oldensports.com.br/web_api'
OUT = sys.argv[1]
UA = 'Mozilla/5.0 (compatible; catalog-demo)'
PAUSA = 0.6
os.makedirs(os.path.join(OUT, 'detalhes'), exist_ok=True)

def get(path):
    for tentativa in range(5):
        try:
            req = urllib.request.Request(BASE + path, headers={'User-Agent': UA, 'Accept': 'application/json'})
            with urllib.request.urlopen(req, timeout=40) as r:
                dados = json.loads(r.read().decode('utf-8'))
            time.sleep(PAUSA)
            return dados
        except Exception as e:
            print('erro', path, e, flush=True)
            time.sleep(3 * (tentativa + 1))
    raise SystemExit('falhou: ' + path)

def paginado(path, chave, arquivo):
    alvo = os.path.join(OUT, arquivo)
    if os.path.exists(alvo):
        return json.load(open(alvo))
    itens, pagina = [], 1
    while True:
        d = get(f"{path}{'&' if '?' in path else '?'}limit=50&page={pagina}")
        itens += d.get(chave, [])
        total = d['paging']['total']
        print(f'{arquivo}: {len(itens)}/{total}', flush=True)
        if len(itens) >= total or not d.get(chave):
            break
        pagina += 1
    json.dump(itens, open(alvo, 'w'))
    return itens

produtos = paginado('/products?available=1', 'Products', 'produtos.json')
variantes = paginado('/products/variants?', 'Variants', 'variantes.json')
ids = [p['Product']['id'] for p in produtos]
for i, pid in enumerate(ids, 1):
    alvo = os.path.join(OUT, 'detalhes', pid + '.json')
    if os.path.exists(alvo):
        continue
    d = get('/products/' + pid)
    json.dump(d.get('Product', {}), open(alvo, 'w'))
    if i % 50 == 0:
        print(f'detalhes: {i}/{len(ids)}', flush=True)
print('FIM', len(ids), 'produtos', len(variantes), 'variantes', flush=True)
