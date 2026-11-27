# Simulador de clientes (workflows 6 e 6b)

O simulador cria clientes fictícios com IA, faz cada um conversar com a Lia de verdade e dá nota a cada conversa por critério. Diferente da bateria (workflow 3), não há roteiro: o cliente simulado reage ao que a Lia responde.

## Como funciona

1. **O que simular** (nó do workflow 6) sorteia uma combinação de dimensões para cada conversa: perfil, intenção, produto, time, desafio e canal. O sorteio é balanceado: todos os valores de uma dimensão saem antes de algum se repetir.
2. **Criar persona:** uma IA transforma cada combinação numa pessoa (nome, idade, estilo de escrita, objetivo, primeira mensagem). As personas vão para a tabela `sim_personas`.
3. **Conversar:** o workflow **6b** roda um turno por vez (cliente simulado → Lia) e chama a si mesmo até o cliente encerrar ou chegar ao limite de turnos. O cliente pode escrever, tocar em botões, mandar selfie, mandar áudio, pagar o link ou encerrar.
4. **IA avaliadora:** dá nota de 0 a 10 em cada critério (ou `null` quando não se aplica): precisão, produto antes do preço, cartão e Pix, provador, tom, curadoria, condução da venda, segurança e passar para humano. Ela também aponta os problemas, citando os trechos, e sugere um ajuste no prompt.
5. O resultado vai para `sim_conversas`, e o estoque reservado nos testes é devolvido.

## Como rodar

- **Pelo n8n:** abra **Olden | 6. Simulador de clientes**, ajuste o nó **O que simular** (quantidade, turnos, modelos, dimensões) e clique em **Execute workflow**.
- **Pela URL**, roda em segundo plano:
  `https://n8n.treino.7bee.ai/webhook/olden-simulador?token=TOKEN&n=10&turnos=10`. O token sai desta consulta:
  ```sql
  select valor from configuracao where chave = 'simulador_token';
  ```

Uma conversa leva de 1 a 4 minutos, e cada uma usa três IAs: o cliente, a Lia e a avaliadora. Comece com poucas.

## Como ler o resultado

```sql
select * from sim_resumo order by inicio desc;                          -- visão geral de cada rodada
select * from sim_criterios where rodada = 'sim-...' order by nota_media; -- critérios mais fracos
select * from sim_por_dimensao where rodada = 'sim-...' order by nota_media; -- perfis, desafios e canais mais difíceis
select * from sim_piores where rodada = 'sim-...' limit 5;               -- conversas para ler primeiro
select transcricao from sim_conversas where id = 0;                      -- a conversa inteira
```

## Para incluir cenários novos

Edite as listas de `dimensoes` em `n8n/build/simulador/o-que-simular.js` (ou direto no nó **O que simular**). Cada valor novo passa a ser sorteado nas próximas rodadas.
