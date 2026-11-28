// Troca o bloco "provador" pela prévia pronta (ou pelo aviso de que não deu certo).
const cfg = $('Configuração do WhatsApp').first().json.cfg;
const base = $('Tem provador?').first(0).json;
const lp = $('Ler prévia').isExecuted ? $('Ler prévia').first().json : $input.first().json;
const real = cfg.whatsapp_modo === 'real';
const mediaId = $('Subir prévia').isExecuted ? (($('Subir prévia').first().json || {}).id || null) : null;
const ok = !!lp.ok && (!real || !!mediaId);
const blocos = [];
for (const b of base.blocos || []) {
  if (b.tipo !== 'provador') { blocos.push(b); continue; }
  if (b.texto) blocos.push({ tipo: 'texto', texto: b.texto, botoes: [] });
  blocos.push({ tipo: 'previa', ok, media_id: mediaId, produto: b.produto, bytes: lp.bytes || 0,
    motivo: ok ? null : (lp.motivo || 'falha ao subir a imagem'), mensagem: ok ? null : (lp.mensagem || null) });
}
return [{ json: { ...base, blocos } }];
