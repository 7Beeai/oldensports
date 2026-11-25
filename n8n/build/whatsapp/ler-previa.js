// Pega a imagem gerada (data URL em base64) e transforma em arquivo para subir no WhatsApp.
const r = $json || {};
const msg = (((r.choices || [])[0] || {}).message) || {};
const img = (msg.images || [])[0] || {};
const dataUrl = (img.image_url || {}).url || img.url || '';
const m = /^data:(image\/[a-z0-9.+-]+);base64,([\s\S]+)$/i.exec(dataUrl);
if (!m) {
  const erro = r.error ? (r.error.message || JSON.stringify(r.error)) : 'o modelo não devolveu imagem';
  return [{ json: { ok: false, motivo: String(erro).slice(0, 300) } }];
}
const ext = m[1].split('/')[1].replace('jpeg', 'jpg');
return [{
  json: { ok: true, mime: m[1], bytes: Math.round(m[2].length * 3 / 4) },
  binary: { data: { data: m[2], mimeType: m[1], fileName: 'previa.' + ext } },
}];
