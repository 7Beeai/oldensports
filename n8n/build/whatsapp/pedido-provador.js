// Monta o pedido para o modelo de imagem: a selfie do cliente + a foto da peça.
const cfg = $('Configuração do WhatsApp').first().json.cfg;
const base = $('Tem provador?').first(0).json;
const bloco = (base.blocos || []).find((b) => b.tipo === 'provador') || {};
const p = bloco.produto || {};
const bin = ($input.first().binary || {}).data;
if (!bin) return [{ json: { corpo: null, motivo: 'foto não baixada' } }];
const buf = await this.helpers.getBinaryDataBuffer(0, 'data');
const mime = /^image\//.test(bin.mimeType || '') ? bin.mimeType : 'image/jpeg';
const instrucao = 'Virtual try-on for a sports store. The FIRST image is a photo of a customer. The SECOND image is a product photo of "'
  + p.nome + '". Create one photorealistic image of the same person from the first photo wearing exactly this garment from the second photo. '
  + 'Keep the face, identity, hair, skin tone, body shape, pose, expression and background unchanged. '
  + 'Reproduce the garment faithfully: colors, crest and logo positions, stripes, collar and sleeves, with natural fabric folds and lighting. '
  + 'Do not add text, watermarks or other people.';
return [{ json: { corpo: {
  model: cfg.provador_modelo || 'google/gemini-3.1-flash-image',
  modalities: ['image', 'text'],
  messages: [{ role: 'user', content: [
    { type: 'text', text: instrucao },
    { type: 'image_url', image_url: { url: 'data:' + mime + ';base64,' + buf.toString('base64') } },
    { type: 'image_url', image_url: { url: p.imagem } },
  ] }],
} } }];
