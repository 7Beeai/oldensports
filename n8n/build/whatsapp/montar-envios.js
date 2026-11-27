// Converte os blocos da Lia em mensagens da API oficial do WhatsApp (Cloud API).
// Com catálogo da Meta (whatsapp_catalogo_id): fichas e listas nativas de produto.
// Sem catálogo: foto + preço + botões de resposta, que funcionam em qualquer conta.
const corta = (s, n) => { s = String(s ?? '').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
const brl = (v) => (v == null ? '' : 'R$ ' + Number(v).toFixed(2).replace('.', ','));
// Negrito do WhatsApp é *assim*; link em markdown vira "texto: link"
const md = (s) => String(s ?? '')
  .replace(/\*\*([^*]+)\*\*/g, '*$1*')
  .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '$1: $2');
const idAcao = (acao, p) => corta(acao + '|' + p.item_group_id + '|' + p.nome, 256);
// Primeiro contato: só o produto (nome e tamanhos). Com o preço: cartão primeiro e o Pix como condição especial.
const ficha = (p, comPreco) => {
  const tamanhos = (p.tamanhos || []).length ? '\nTamanhos: ' + p.tamanhos.join(', ') : '';
  if (!comPreco) return '*' + p.nome + '*' + tamanhos;
  const promo = p.preco_original && p.preco_original > p.preco ? '~' + brl(p.preco_original) + '~ ' : '';
  return '*' + p.nome + '*\n' + promo + brl(p.preco) + ' no cartão' + (p.parcelamento ? ' (' + p.parcelamento + ')' : '')
    + (p.preco_pix && p.preco_pix < p.preco ? '\n✨ Condição especial no Pix: ' + brl(p.preco_pix) : '')
    + tamanhos;
};
const artigo = (nome) => (/^\S*a\b/i.test(String(nome || '').trim()) ? 'a' : 'o');
const linkVideo = (u) => String(u || '').replace('youtube.com/embed/', 'youtube.com/watch?v=');
const rotulos = { material: 'Material', gola: 'Gola', escudo: 'Escudo', manga: 'Manga' };

const saida = [];
for (const item of $input.all()) {
  const { sessao, blocos = [], cfg = {} } = item.json;
  // Celular brasileiro pode chegar sem o 9 (ex.: 553199991234). Para enviar, a Meta casa com o número
  // cadastrado, que tem o 9 (5531999991234): então o 9 é recolocado depois do DDD.
  const to = String(sessao || '').replace(/^wa:/, '').replace(/^55(\d{2})([6-9]\d{7})$/, (m, ddd, num) => '55' + ddd + '9' + num);
  const real = cfg.whatsapp_modo === 'real';
  const url = 'https://graph.facebook.com/' + (cfg.whatsapp_graph_versao || 'v23.0') + '/' + (cfg.whatsapp_phone_number_id || 'SEM-PHONE-NUMBER-ID') + '/messages';
  const cat = String(cfg.whatsapp_catalogo_id || '').trim();
  const flowId = String(cfg.whatsapp_flow_tamanho_id || '').trim();
  const baseN8n = String(cfg.url_base_n8n || '').replace(/\/$/, '');
  const msgs = [];

  const texto = (t) => { t = md(t).trim(); while (t) { msgs.push({ type: 'text', text: { body: t.slice(0, 4096), preview_url: true } }); t = t.slice(4096); } };
  const botoes = (corpo, lista, header) => msgs.push({ type: 'interactive', interactive: {
    type: 'button', ...(header ? { header } : {}), body: { text: corta(md(corpo), 1024) },
    action: { buttons: lista.slice(0, 3).map((b, i) => ({ type: 'reply', reply: { id: corta(b.id || 'b' + i, 256), title: corta(b.titulo, 20) } })) },
  } });
  const imagem = (link, legenda) => { if (/^https?:\/\//.test(link || '')) msgs.push({ type: 'image', image: { link, ...(legenda ? { caption: corta(md(legenda), 1024) } : {}) } }); };
  const linkBotao = (corpo, rotulo, link) => msgs.push({ type: 'interactive', interactive: {
    type: 'cta_url', body: { text: corta(md(corpo), 1024) }, action: { name: 'cta_url', parameters: { display_text: corta(rotulo, 20), url: link } },
  } });
  // Cartão de produto sem catálogo: foto no topo, preço no corpo e 3 botões
  const cartao = (p, extra, comPreco) => botoes((extra ? extra + '\n\n' : '') + ficha(p, comPreco), [
    { id: idAcao('quero', p), titulo: 'Quero essa' },
    { id: idAcao('fotos', p), titulo: 'Ver mais fotos' },
    { id: idAcao('tam', p), titulo: 'Qual meu tamanho?' },
  ], /^https?:\/\//.test(p.imagem || '') ? { type: 'image', image: { link: p.imagem } } : null);
  // No catálogo da Meta cada tamanho é um item; a ficha abre no primeiro tamanho com estoque
  const codigoMeta = (p) => (p.skus || [])[0] || p.item_group_id;
  const fichaNativa = (p, corpo) => msgs.push({ type: 'interactive', interactive: {
    type: 'product', ...(corpo ? { body: { text: corta(md(corpo), 1024) } } : {}),
    action: { catalog_id: cat, product_retailer_id: codigoMeta(p) },
  } });
  const listaNativa = (cabecalho, corpo, secoes) => msgs.push({ type: 'interactive', interactive: {
    type: 'product_list', header: { type: 'text', text: corta(cabecalho || 'Olden Sports', 60) },
    body: { text: corta(md(corpo) || 'Dá uma olhada 👇', 1024) },
    action: { catalog_id: cat, sections: secoes.slice(0, 10).map((s) => ({ title: corta(s.titulo, 24), product_items: s.produtos.map((p) => ({ product_retailer_id: codigoMeta(p) })) })) },
  } });

  for (const b of blocos) {
    const p = b.produto || {};
    switch (b.tipo) {
      case 'texto':
        if ((b.botoes || []).length) botoes(b.texto, b.botoes.map((x) => ({ id: x.id, titulo: x.titulo })));
        else texto(b.texto);
        break;
      case 'menu':
        msgs.push({ type: 'interactive', interactive: {
          type: 'list', body: { text: corta(md(b.corpo), 1024) },
          action: { button: corta(b.botao || 'Ver opções', 20), sections: [{ title: 'Opções', rows: (b.opcoes || []).slice(0, 10).map((o, i) => ({
            id: corta(o.id || 'op' + i, 200), title: corta(o.titulo, 24), ...(o.descricao ? { description: corta(o.descricao, 72) } : {}),
          })) }] },
        } });
        break;
      case 'produto':
        if (cat) { if (b.texto) texto(b.texto); fichaNativa(p); } else cartao(p, b.texto, b.mostrar_preco);
        break;
      case 'carrossel_produtos': {
        const ps = (b.produtos || []).slice(0, 10);
        if (cat) listaNativa('Separei pra você', b.corpo, [{ titulo: 'Sugestões', produtos: ps }]);
        else { if (b.corpo) texto(b.corpo); ps.slice(0, 5).forEach((x) => cartao(x, '', b.mostrar_preco)); }
        break;
      }
      case 'vitrine': {
        const secoes = (b.secoes || []).map((s) => ({ titulo: s.titulo, produtos: s.produtos || [] }));
        if (cat) listaNativa(b.cabecalho, b.corpo, secoes);
        else {
          // Sem catálogo: lista interativa (até 10 peças); tocar numa peça é o mesmo que "Quero essa"
          let resta = 10;
          const sections = secoes.map((s) => {
            const rows = s.produtos.slice(0, resta).map((x) => ({ id: idAcao('quero', x), title: corta(x.nome, 24), description: corta(b.mostrar_preco ? brl(x.preco) + ' no cartão' + (x.preco_pix ? ' · Pix ' + brl(x.preco_pix) : '') : ((x.tamanhos || []).length ? 'Tam.: ' + x.tamanhos.join(', ') : ''), 72) }));
            resta -= rows.length;
            return { title: corta(s.titulo, 24), rows };
          }).filter((s) => s.rows.length);
          msgs.push({ type: 'interactive', interactive: {
            type: 'list', header: { type: 'text', text: corta(b.cabecalho || 'Vitrine', 60) },
            body: { text: corta(md(b.corpo) || 'Toque para ver as peças 👇', 1024) },
            action: { button: 'Ver peças', sections },
          } });
        }
        break;
      }
      case 'catalogo':
        if (cat) msgs.push({ type: 'interactive', interactive: { type: 'catalog_message', body: { text: corta(md(b.corpo), 1024) }, action: { name: 'catalog_message' } } });
        else linkBotao(b.corpo, 'Ver catálogo', 'https://www.oldensports.com.br/');
        break;
      case 'midias': {
        const fotos = (p.imagens || []).map((i) => i.url).filter(Boolean).slice(0, 5);
        fotos.forEach((u, i) => imagem(u, i === 0 ? (b.texto || p.nome) : ''));
        if (p.video) texto('🎥 Vídeo: ' + linkVideo(p.video));
        break;
      }
      case 'comparacao': {
        if (b.texto) texto(b.texto);
        (b.produtos || []).forEach((x) => imagem(x.imagem, ficha(x, true) + Object.keys(rotulos).filter((k) => (x.atributos || {})[k])
          .map((k) => '\n' + rotulos[k] + ': ' + String(x.atributos[k]).replace(/^[^:]{0,20}:\s*/, '')).join('')));
        if (baseN8n && (b.skus || []).length === 2) linkBotao('Quer ver as duas lado a lado?', 'Ver lado a lado', baseN8n + '/webhook/olden-comparacao?a=' + encodeURIComponent(b.skus[0]) + '&b=' + encodeURIComponent(b.skus[1]));
        break;
      }
      case 'tamanho': {
        const crianca = p.faixa_etaria === 'infantil' || p.faixa_etaria === 'bebe';
        if (flowId) {
          msgs.push({ type: 'interactive', interactive: {
            type: 'flow', body: { text: corta(md(b.texto) || 'Me conta suas medidas que eu te digo o tamanho', 1024) },
            action: { name: 'flow', parameters: {
              flow_message_version: '3', flow_id: flowId, flow_cta: 'Ver meu tamanho',
              mode: cfg.whatsapp_flow_modo === 'published' ? 'published' : 'draft',
              flow_token: corta('tamanho|' + sessao + '|' + p.item_group_id, 200),
              flow_action: 'navigate',
              flow_action_payload: { screen: 'TAMANHO', data: { sku: p.item_group_id, nome: corta(p.nome, 80), adulto: !crianca, crianca } },
            } },
          } });
        } else {
          texto((b.texto ? b.texto + '\n\n' : '') + (crianca ? 'Me conta a idade da criança 😊' : 'Me conta sua altura, seu peso e se você gosta mais justa, normal ou solta 😊'));
        }
        break;
      }
      case 'pagamento':
        linkBotao(b.texto, 'Pagar agora', b.url);
        break;
      case 'previa':
        // Resultado do provador (montado em "Juntar prévia")
        if (b.ok) {
          const legenda = '✨ Prévia gerada por IA: você com ' + artigo(p.nome) + ' ' + p.nome + '. Sua foto já foi apagada.';
          if (b.media_id) msgs.push({ type: 'image', image: { id: b.media_id, caption: corta(legenda, 1024) } });
          else msgs.push({ type: 'image', image: { id: 'SIMULADO', caption: legenda }, _simulacao: 'prévia gerada com ' + Math.round((b.bytes || 0) / 1024) + ' KB' });
          botoes('Curtiu? 😊', [{ id: idAcao('quero', p), titulo: 'Quero essa' }, { id: idAcao('tam', p), titulo: 'Qual meu tamanho?' }]);
        } else {
          texto(b.motivo === 'sem_foto'
            ? 'Não achei a sua foto aqui 😕 Me manda a selfie de novo?'
            : 'Poxa, não consegui gerar a prévia agora 😕 Quer tentar com outra foto, de frente e com boa luz?');
        }
        break;
      case 'provador':
        // Só chega aqui se o provador estiver desligado (provador_ativo diferente de "sim")
        texto('O provador virtual está desligado no momento 😕 Mas te ajudo com o tamanho e as fotos da peça!');
        break;
      default:
        if (b.texto || b.corpo) texto(b.texto || b.corpo);
    }
  }

  for (const m of msgs) {
    const { _simulacao, ...msg } = m;
    const resumo = msg.type === 'text' ? msg.text.body
      : msg.type === 'image' ? '[imagem] ' + (msg.image.caption || msg.image.link || '')
      : '[' + msg.interactive.type + '] ' + ((msg.interactive.body || {}).text || '');
    saida.push({ json: {
      sessao, url, real, tipo: msg.type === 'interactive' ? 'interactive:' + msg.interactive.type : msg.type,
      texto: corta(resumo, 500) + (_simulacao ? ' (' + _simulacao + ')' : ''),
      status: real ? 'enviando' : 'simulada',
      payload: { messaging_product: 'whatsapp', recipient_type: 'individual', to, ...msg },
    } });
  }
}
return saida;
