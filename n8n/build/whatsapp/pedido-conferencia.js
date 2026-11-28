// Antes de gerar a prévia, um modelo de visão confere se a selfie serve.
// A imagem segue junto (binary) para o provador, se a foto for aprovada.
const cfg = $('Configuração do WhatsApp').first().json.cfg;
const bin = ($input.first().binary || {}).data;
if (!bin) return [{ json: { corpo: null } }];
const buf = await this.helpers.getBinaryDataBuffer(0, 'data');
const mime = /^image\//.test(bin.mimeType || '') ? bin.mimeType : 'image/jpeg';
const instrucao = `Você confere fotos enviadas por clientes para um provador virtual de roupas. Analise a imagem e responda SÓ com um JSON, sem texto fora dele:
{"foto_de_pessoa_real": true, "quantas_pessoas": 1, "parece_menor_de_idade": false, "rosto_visivel": true, "tronco_visivel_de_frente": true, "qualidade": "boa", "conteudo_improprio": false, "print_desenho_ou_montagem": false, "observacao": "uma frase curta"}
Regras:
- foto_de_pessoa_real: false se não houver pessoa (só objeto, roupa, paisagem, animal) ou se for boneco/manequim.
- tronco_visivel_de_frente: true só se aparecem de frente os ombros e o peito até perto da cintura (onde a camisa fica). Falso se a foto mostra só rosto, só pernas, só pés, costas ou um detalhe do corpo.
- qualidade: "boa", "escura", "borrada", "muito_pequena" ou "cortada" (a pessoa sai cortada no meio do tronco).
- parece_menor_de_idade: true se a pessoa aparenta ter menos de 18 anos. Na dúvida, true.
- conteudo_improprio: nudez, roupa íntima, violência, gesto ofensivo ou algo que não deveria ser editado.
- print_desenho_ou_montagem: print de tela, desenho, ilustração, meme ou foto de outra foto.`;
return [{
  json: { corpo: {
    model: cfg.provador_modelo_conferencia || 'anthropic/claude-haiku-5.5',
    max_tokens: 2000,
    reasoning: { effort: 'low' },
    messages: [{ role: 'user', content: [
      { type: 'image_url', image_url: { url: 'data:' + mime + ';base64,' + buf.toString('base64') } },
      { type: 'text', text: instrucao },
    ] }],
  } },
  binary: $input.first().binary,
}];
