// Decide se a selfie serve para a prévia. Se não servir, explica ao cliente o porquê.
const pedido = $('Pedido de conferência').first();
const r = $json || {};
const texto = String((((r.choices || [])[0] || {}).message || {}).content || '');
let c = null;
try { c = JSON.parse(texto.slice(texto.indexOf('{'), texto.lastIndexOf('}') + 1)); } catch (e) { c = null; }
const recusa = (motivo, mensagem) => [{ json: { aprovada: false, ok: false, motivo, mensagem, conferencia: c } }];
if (!pedido.json.corpo) return recusa('sem_foto', 'Não consegui abrir a sua foto 😕 Me manda de novo, como foto normal (não como documento)?');
if (!c) return recusa('conferencia_falhou', 'Tive um probleminha pra analisar a foto agora 😕 Pode me mandar de novo daqui a pouco?');
if (c.conteudo_improprio) return recusa('improprio', 'Essa foto eu não consigo usar pra prévia. Me manda uma selfie de frente, vestida, da cintura pra cima?');
if (!c.foto_de_pessoa_real) return recusa('sem_pessoa', 'Não consegui ver uma pessoa nessa foto 😅 Me manda uma selfie sua, de frente, da cintura pra cima?');
if (c.print_desenho_ou_montagem) return recusa('print_ou_desenho', 'Parece um print, anúncio ou desenho 😅 Pra prévia eu preciso de uma foto sua de verdade, de frente, da cintura pra cima.');
if (Number(c.quantas_pessoas) > 1) return recusa('varias_pessoas', 'Nessa foto aparece mais de uma pessoa. Me manda uma só sua, de frente, da cintura pra cima?');
if (c.parece_menor_de_idade) return recusa('menor', 'O provador funciona só com fotos de adultos, então não consigo gerar a prévia com essa foto. Se a peça for pra você, me manda uma selfie sua 😊');
if (c.qualidade === 'escura') return recusa('escura', 'A foto ficou um pouco escura 😕 Tira de novo num lugar com mais luz, de frente e da cintura pra cima?');
if (c.qualidade === 'borrada') return recusa('borrada', 'A foto ficou tremida 😕 Tenta de novo com o celular parado, de frente e da cintura pra cima?');
if (c.qualidade === 'muito_pequena') return recusa('pequena', 'A foto veio muito pequena pra eu vestir a peça direitinho. Me manda de novo, com você mais perto da câmera?');
if (!c.rosto_visivel || !c.tronco_visivel_de_frente || c.qualidade === 'cortada') {
  return recusa('enquadramento', 'Pra vestir a peça direitinho, preciso ver você de frente, do rosto até a cintura 📸 Me manda outra assim?');
}
return [{ json: { aprovada: true, conferencia: c }, binary: pedido.binary }];
