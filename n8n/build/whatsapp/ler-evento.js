// Lê o evento que a Meta mandou. Cada mensagem do cliente vira um item com o texto
// que a Lia vai ler. Recibos de entrega (enviada, entregue, lida, falhou) viram itens "status".
const corpo = $('Recebe do WhatsApp').first().json.body || {};

const artigo = (nome) => (/^\S*a\b/i.test(String(nome).trim()) ? 'a' : 'o');
// Botões montados pelo n8n levam "acao|codigo|nome" no id (ex.: "quero|OLD-P97|Camisa Flamengo")
const decodificar = (id, titulo) => {
  const p = String(id || '').split('|');
  if (p.length >= 3) {
    const nome = p.slice(2).join('|');
    const a = artigo(nome);
    if (p[0] === 'quero') return 'Quero ' + a + ' ' + nome;
    if (p[0] === 'fotos') return 'Quero ver mais fotos d' + a + ' ' + nome;
    if (p[0] === 'tam') return 'Qual tamanho fica bom em mim n' + a + ' ' + nome + '?';
    if (p[0] === 'provar') return 'Quero ver como ' + a + ' ' + nome + ' fica em mim';
  }
  return titulo;
};

const traduzir = (m) => {
  switch (m.type) {
    case 'text':
      return (m.text || {}).body || '';
    case 'interactive': {
      const i = m.interactive || {};
      if (i.type === 'button_reply') return decodificar(i.button_reply.id, i.button_reply.title);
      if (i.type === 'list_reply') return decodificar(i.list_reply.id, i.list_reply.title);
      if (i.type === 'nfm_reply') {
        // Resposta do Flow "Descubra seu tamanho": vira a mesma frase que a página de chat envia
        let r = {};
        try { r = JSON.parse((i.nfm_reply || {}).response_json || '{}'); } catch (e) { r = {}; }
        if (String(r.idade || '').trim()) return 'Idade da criança para a ' + r.nome + ': ' + r.idade + ' anos';
        if (String(r.altura || '').trim()) return 'Minhas medidas para a ' + r.nome + ': altura ' + r.altura + ' cm, peso ' + r.peso + ' kg, caimento ' + (r.caimento || 'normal');
        return 'Preenchi o formulário de tamanho';
      }
      return null;
    }
    case 'button':
      return (m.button || {}).text || '';
    case 'image':
      return '[FOTO RECEBIDA] O cliente mandou uma foto' + ((m.image || {}).caption ? ', com a legenda: ' + m.image.caption : '.');
    case 'order': {
      const o = m.order || {};
      const itens = (o.product_items || []).map((x) => x.quantity + 'x ' + x.product_retailer_id).join(', ');
      return 'Montei um carrinho e quero fechar: ' + itens + (o.text ? '. ' + o.text : '');
    }
    case 'audio':
      return '[ÁUDIO] O cliente mandou um áudio, que você não consegue ouvir.';
    case 'video': case 'document': case 'sticker': case 'location': case 'contacts':
      return '[ARQUIVO] O cliente mandou um arquivo (' + m.type + ') que você não consegue abrir.';
    default:
      return null; // reação, mensagem de sistema, tipo não suportado: a Lia não responde
  }
};

// Números liberados (configuracao.whatsapp_numeros_teste, separados por vírgula). Vazio = todos.
// Mensagens de quem não está na lista são ignoradas: a Lia não responde, não marca como lida e nada é gravado.
const cfg = $json.cfg || {};
const digitos = (n) => String(n || '').replace(/\D/g, '');
const sem9 = (n) => n.replace(/^55(\d{2})9(\d{8})$/, '55$1$2'); // compara com e sem o 9 do celular
const liberados = String(cfg.whatsapp_numeros_teste || '').split(',').map(digitos).filter(Boolean).map(sem9);
const permitido = (n) => !liberados.length || liberados.includes(sem9(digitos(n)));

const saida = [];
for (const entry of corpo.entry || []) {
  for (const ch of entry.changes || []) {
    const v = ch.value || {};
    const nomes = {};
    for (const c of v.contacts || []) nomes[c.wa_id] = (c.profile || {}).name || '';
    for (const m of v.messages || []) {
      if (!permitido(m.from)) continue;
      const texto = traduzir(m);
      if (texto === null || texto === '') continue;
      saida.push({ json: {
        evento: 'mensagem', wamid: m.id, sessao: 'wa:' + String(m.from).replace(/\D/g, ''),
        nome: nomes[m.from] || '', tipo: m.type, texto: String(texto).slice(0, 2000), payload: m,
      } });
    }
    for (const s of v.statuses || []) {
      const erro = (s.errors || []).map((e) => [e.code, e.title, (e.error_data || {}).details].filter(Boolean).join(' ')).join('; ');
      saida.push({ json: { evento: 'status', wamid: s.id, status: s.status, erro } });
    }
  }
}
return saida;
