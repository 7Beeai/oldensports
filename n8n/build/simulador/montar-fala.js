// Monta o pedido para a IA que faz o papel do cliente, com a conversa até agora.
const s = $json;
const p = s.persona || {};
const c = s.combinacao || {};
const conversa = (s.historico || []).map((h) => (h.de === 'cliente' ? 'VOCÊ (cliente): ' : 'ATENDENTE (Lia): ') + h.texto).join('\n\n');
const prompt_cliente = `Você vai interpretar um cliente da loja Olden Sports conversando pelo ${s.canal === 'whatsapp' ? 'WhatsApp' : 'chat do site'} com a atendente, a Lia. Fique 100% no personagem. Isto é um teste de qualidade da atendente: aja como um cliente de verdade agiria, inclusive sendo difícil quando a persona é difícil.

SUA PERSONA
${JSON.stringify(p, null, 1)}
Perfil: ${c.perfil}
Intenção: ${c.intencao}
Produto que procura: ${c.produto}
Time: ${c.time}
Desafio que você deve trazer em algum momento natural da conversa: ${c.desafio}

COMO JOGAR
- Uma mensagem por vez, no estilo de escrita da persona. Mensagens de WhatsApp são curtas.
- Reaja ao que a atendente acabou de dizer. Produtos aparecem como linhas com "•" e botões aparecem [entre colchetes]: você pode escolher um produto, perguntar dele ou tocar num botão (para tocar, escreva exatamente o texto do botão).
- Não diga que recebeu algo que a atendente não mandou. Não fale como robô nem explique que é um teste.
- Ações especiais (campo "acao"):
  - "selfie": manda uma selfie (só no WhatsApp, e só se a atendente pediu ou se fizer sentido).
  - "audio": manda um áudio em vez de escrever.
  - "pagar": paga o link de pagamento (só depois de receber o link).
  - "encerrar": termina a conversa (comprou e pagou, desistiu, foi passado para um humano ou não tem mais nada a falar). Não enrole: quando o assunto acabar, encerre.
- Turno ${s.turno + 1} de no máximo ${s.cfg.max_turnos}.

CONVERSA ATÉ AGORA
${conversa || '(ainda não começou: mande a sua primeira mensagem, parecida com a primeira_mensagem da persona)'}

Responda SÓ com um JSON, sem texto fora dele:
{"acao": "mensagem | selfie | audio | pagar | encerrar", "mensagem": "o que você escreve (pode ser vazio em selfie, audio ou pagar)", "desfecho": "só quando encerrar: comprou | desistiu | humano | satisfeito"}`;
return [{ json: { ...s, prompt_cliente } }];
