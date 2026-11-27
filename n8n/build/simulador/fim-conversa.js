// O cliente encerrou: guarda a última fala (se houver) e o desfecho.
const s = $json;
const historico = [...(s.historico || [])];
if (s.exibido) historico.push({ de: 'cliente', texto: s.exibido });
const { mensagem, modelo, esforco, janela, exibido, acao, continua, ...estado } = s;
return [{ json: { ...estado, historico, desfecho: s.desfecho || 'satisfeito' } }];
