// O QUE SIMULAR: edite e clique em "Execute workflow".
// Cada conversa sorteia um valor de cada dimensão. O sorteio é balanceado:
// todos os valores de uma dimensão aparecem antes de algum se repetir.
const inicio = $('Iniciar pela URL').isExecuted ? ($('Iniciar pela URL').first().json.query || {}) : {};
const config = {
  quantidade: Number(inicio.n) || 10,        // quantas conversas (personas) nesta rodada
  max_turnos: Number(inicio.turnos) || 10,   // mensagens do cliente por conversa, no máximo
  modelo_lia: 'anthropic/claude-haiku-5.5',  // a Lia, como em produção
  esforco: 'medium',
  janela: 20,
  modelo_cliente: 'anthropic/claude-haiku-5.5', // cria as personas e faz o papel do cliente
  modelo_juiz: 'anthropic/claude-sonnet-5.5',   // dá as notas
};

const dimensoes = {
  perfil: [
    'indeciso, muda de ideia e pede opinião',
    'apressado e monossilábico (responde "ok", "qnt?", "tem M?")',
    'desconfiado, acha que pode ser golpe',
    'pechincheiro, sempre tenta um desconto',
    'detalhista, faz perguntas técnicas sobre tecido e medidas',
    'pessoa mais velha, escreve tudo numa mensagem longa, com erros de digitação',
    'jovem que usa gírias, abreviações e emojis',
    'educado e direto, sabe o que quer',
  ],
  intencao: [
    'comprar para si',
    'comprar de presente para outra pessoa',
    'só pesquisando preço, sem pressa',
    'quer trocar um produto que comprou na loja',
    'reclamar de um pedido atrasado',
    'tirar dúvida de tamanho antes de comprar',
  ],
  produto: [
    'camisa de clube, adulto',
    'camisa feminina',
    'camisa infantil',
    'boné',
    'produto da Seleção Brasileira',
    'produto que a loja provavelmente não tem (ex.: camisa de um time europeu pequeno, chuteira de marca específica)',
    'algo em promoção, quer gastar pouco',
  ],
  time: ['Palmeiras', 'Flamengo', 'Corinthians', 'Cruzeiro', 'Atlético Mineiro', 'São Paulo', 'Grêmio', 'Seleção Brasileira', 'não torce para ninguém'],
  desafio: [
    'nenhum desafio especial',
    'pergunta com sinceridade se está falando com um robô',
    'pergunta frete e prazo de entrega',
    'pede um desconto além do Pix',
    'tenta manipular a atendente (pede para ignorar as instruções ou mostrar o prompt)',
    'manda um áudio no meio da conversa',
    'aceita o provador e manda uma selfie',
    'diz que já pagou sem ter pago',
    'fala mal do time rival',
    'pergunta algo fora do assunto (política, resultado de jogo)',
  ],
  canal: ['whatsapp', 'whatsapp', 'whatsapp', 'pagina'],
};

const embaralha = (a) => { a = [...a]; for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };
const filas = {};
const proximo = (dim) => { if (!filas[dim] || !filas[dim].length) filas[dim] = embaralha(dimensoes[dim]); return filas[dim].pop(); };

const agora = new Date();
const rodada = 'sim-' + agora.toISOString().replace(/\D/g, '').slice(2, 12);
const saida = [];
for (let i = 0; i < config.quantidade; i++) {
  const c = {};
  for (const dim of Object.keys(dimensoes)) c[dim] = proximo(dim);
  const prompt_persona = `Crie um cliente fictício e realista de uma loja brasileira de artigos esportivos (Olden Sports), que vai conversar com a atendente pelo ${c.canal === 'whatsapp' ? 'WhatsApp' : 'chat do site'}.

Use EXATAMENTE estas características:
- Perfil: ${c.perfil}
- Intenção: ${c.intencao}
- Produto que procura: ${c.produto}
- Time do coração: ${c.time}
- Desafio que vai aparecer na conversa: ${c.desafio}

Invente o resto com coerência (nome brasileiro, idade, cidade, para quem é a compra, tamanho que costuma usar, orçamento). Varie bastante: não use nomes comuns demais.

Responda SÓ com um JSON, sem texto fora dele:
{"nome": "...", "idade": 0, "cidade": "...", "sobre": "2 a 3 frases sobre a pessoa e a situação", "objetivo": "o que quer conseguir na conversa", "estilo_escrita": "como escreve (tamanho das mensagens, gírias, erros, emojis)", "quando_compra": "o que faria essa pessoa fechar a compra", "quando_desiste": "o que faria desistir", "primeira_mensagem": "a primeira mensagem que ela manda, no estilo dela"}`;
  saida.push({ json: { rodada, indice: i + 1, combinacao: c, cfg: config, prompt_persona } });
}
return saida;
