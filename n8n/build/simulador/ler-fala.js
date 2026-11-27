// Lê a fala do cliente simulado e decide o que a Lia recebe.
const s = $('Montar fala do cliente').first().json;
const bruto = String($json.text ?? '');
let f = {};
try { f = JSON.parse(bruto.slice(bruto.indexOf('{'), bruto.lastIndexOf('}') + 1)); }
catch (e) { f = bruto.trim() && !$json.error ? { acao: 'mensagem', mensagem: bruto.trim().slice(0, 500) } : { acao: 'encerrar', desfecho: 'erro', mensagem: '' }; }
const acao = String(f.acao || 'mensagem').toLowerCase();
const texto = String(f.mensagem || '').trim();
let mensagem = texto;   // o que a Lia recebe
let exibido = texto;    // o que aparece na transcrição
if (acao === 'selfie') {
  mensagem = s.canal === 'whatsapp' ? '[FOTO RECEBIDA] O cliente mandou uma foto' + (texto ? ', com a legenda: ' + texto : '.') : (texto || 'mandei uma foto');
  exibido = '[manda uma selfie]' + (texto ? ' ' + texto : '');
} else if (acao === 'audio') {
  mensagem = '[ÁUDIO] O cliente mandou um áudio, que você não consegue ouvir.';
  exibido = '[manda um áudio]' + (texto ? ' (diria: ' + texto + ')' : '');
} else if (acao === 'pagar') {
  mensagem = '#pagamento_aprovado';
  exibido = '[paga o link de pagamento]';
}
const encerra = acao === 'encerrar' || (!mensagem && acao === 'mensagem');
const { prompt_cliente, ...estado } = s;
return [{ json: {
  ...estado, acao, exibido, continua: !encerra,
  desfecho: encerra ? (String(f.desfecho || '').toLowerCase() || 'satisfeito') : null,
  // campos que o Núcleo lê
  mensagem, modelo: s.cfg.modelo_lia, esforco: s.cfg.esforco, janela: s.cfg.janela,
} }];
