# Ambiente de testes e demonstração

Este guia monta o ambiente que você mostra ao cliente e usa para medir a qualidade do agente. Ele substitui o workflow único da primeira versão (Gemini).

O ambiente tem três peças:

| Workflow | Para que serve |
|---|---|
| `n8n/1-nucleo-agente.json`: **Olden \| 1. Núcleo do agente** | O agente em si (modelo, memória e ferramentas). Os outros dois chamam este. Mude o agente aqui e os dois recebem a mudança. |
| `n8n/2-chat-demo.json`: **Olden \| 2. Chat de demonstração** | Página de chat pública, com a cor da Olden, para o cliente testar pelo navegador ou celular. |
| `n8n/3-bateria-testes.json`: **Olden \| 3. Bateria de testes** | Roda conversas prontas em várias configurações, confere o banco, dá nota e guarda tudo no Supabase. |

```
Chat de demonstração ──┐
                       ├──► Núcleo do agente ──► Supabase (catálogo, pedidos, avaliações, memória)
Bateria de testes ─────┘          │
        │                         └── Claude Haiku 5.5 via OpenRouter
        └── IA avaliadora (Claude Sonnet 5.5 via OpenRouter) ──► resultados_teste
```

![Chat de demonstração](img/chat-demo.png)

*A página pública do chat. A resposta da imagem veio de um modelo simulado, usado no teste local.*

---

## 1. Supabase: tabelas de teste

No **SQL Editor**, em uma **New query**, cole o arquivo `supabase/04_ambiente_testes.sql` inteiro e clique em **Run** sem nada selecionado.

Ele cria:

- **`cenarios_teste`**: 14 conversas prontas, cada uma com o que o cliente diz e o que se espera.
- **`resultados_teste`**: o resultado de cada conversa da bateria.
- **`resumo_testes`** (view): uma linha por configuração testada, com quantos cenários passaram e a nota média.
- **`limpar_testes()`**: apaga as conversas de teste e **devolve ao estoque** as peças "vendidas" nos testes.

As conversas da bateria usam identificador `teste:...` e as do chat público usam `demo:...`. Assim dá para separar e limpar cada uma sem mexer na outra.

> **Quer um ambiente totalmente separado para o cliente?** O plano Free do Supabase permite 2 projetos. Crie um projeto novo (ex.: `olden-demo`), rode nele os arquivos `01`, `02`, `03` e `04` e use as credenciais dele no n8n. Assim o que você testa no dia a dia não aparece para o cliente.

## 2. OpenRouter: chave e créditos

1. Crie uma conta em **openrouter.ai** e adicione créditos em **Credits**. O Claude Haiku 5.5 não tem camada gratuita.
2. Em **Keys → Create Key**, gere uma chave. Se quiser, defina um limite de gasto na chave.
3. No n8n, crie a credencial **OpenRouter** (nome sugerido: `OpenRouter`) e cole a chave.

Preço do Claude Haiku 5.5 na OpenRouter: US$ 0,10 por milhão de tokens de entrada e US$ 0,50 por milhão de saída (para prompts de até 100 mil tokens). Uma conversa de 5 mensagens custa uma fração de centavo.

## 3. n8n: importar na ordem certa

1. **Importe o núcleo primeiro.** Crie um workflow, use **⋯ → Import from File** e escolha `1-nucleo-agente.json`. Selecione as credenciais:
   - **Contexto do atendimento**, **Memória da conversa** e as 3 ferramentas → `Supabase Postgres`.
   - **Claude via OpenRouter** → `OpenRouter`.

   Salve e clique em **Publish** (canto superior direito). **No n8n 2.x, um workflow só pode ser chamado por outro depois de publicado.** Sem isso, aparece o erro *"Workflow is not active and cannot be executed"*.
2. **Importe o chat de demonstração** (`2-chat-demo.json`).
   - No nó **Chamar núcleo do agente**, em **Workflow**, escolha **Olden | 1. Núcleo do agente**.
   - Salve e clique em **Publish**.
3. **Importe a bateria** (`3-bateria-testes.json`).
   - No nó **Conversar com o agente**, escolha **Olden | 1. Núcleo do agente**.
   - Selecione `Supabase Postgres` nos nós de banco e `OpenRouter` no **Modelo avaliador**.
   - Salve. Este não precisa ser publicado, porque você roda manualmente.

Depois de publicar o núcleo, toda alteração nele precisa de **Publish** de novo para valer no chat e na bateria.

## 4. As variáveis do agente

Ficam no nó **Configuração** do núcleo. Quem chama o núcleo pode mandar outro valor; o que vier vazio usa o padrão:

| Variável | Padrão | O que faz |
|---|---|---|
| `modelo` | `anthropic/claude-haiku-5.5` | Qualquer modelo da OpenRouter. Para comparar, ex.: `anthropic/claude-sonnet-5.5` |
| `esforco` | `medium` | Quanto o modelo raciocina antes de responder: `low`, `medium` ou `high`. Mais esforço = mais preciso e mais lento |
| `janela` | `20` | Quantas interações anteriores da conversa o agente lembra |
| `sessao` | vem do chat | Identifica o cliente. `demo:` no chat público, `teste:` na bateria, `teste:manual` quando o Núcleo é executado sozinho |
| `mensagem` | vem do chat | O que o cliente escreveu. Executando o Núcleo sozinho, usa uma mensagem de teste |

### "Janela de contexto": dois sentidos

- **Janela do modelo:** quanto texto o modelo aceita de uma vez. No Claude Haiku 5.5 é 1 milhão de tokens, muito mais do que este atendimento usa, então não é uma limitação aqui.
- **Janela de memória (`janela`):** quantas trocas anteriores o n8n reenvia ao modelo a cada mensagem. **É esta que vale testar.** Janela pequena deixa a resposta mais barata e rápida, mas o agente esquece o que o cliente disse no começo. O cenário **C11** existe para medir isso: o cliente diz produto, tamanho e pagamento no 1º turno e só fecha no 8º.

### Sobre temperatura

O Claude Haiku 5.5 **não aceita** mudar a temperatura (a API recusa valores diferentes do padrão). Por isso o nó do modelo não envia esse campo; não ative essa opção no nó. A precisão vem de outros lugares:

1. **Esforço de raciocínio** (`esforco`), medido na bateria.
2. **Prompt** com regras de precisão: conferir tudo no catálogo, calcular o total pelo preço da forma de pagamento, não perguntar de novo o que o cliente já disse.
3. **O banco faz as contas:** preço, total e estoque são calculados pelo Supabase, nunca pela IA.
4. **A bateria de testes**, que mostra onde ele ainda erra.

## 5. Rodar a bateria de testes

1. Abra **Olden | 3. Bateria de testes** e o nó **O que testar**. Ajuste as listas:

   ```js
   modelos:  ['anthropic/claude-haiku-5.5'],
   esforcos: ['low', 'medium'],
   janelas:  [3, 10, 30],
   cenarios: [],            // vazio = todos; ou ['C01', 'C11']
   modelo_juiz: 'anthropic/claude-sonnet-5.5',
   ```

   Cada cenário roda em **todas** as combinações. Com os valores acima: 14 cenários × 2 esforços × 3 janelas = 84 conversas.
2. Clique em **Execute workflow**. Para um primeiro teste, use `cenarios: ['C01']`, `esforcos: ['medium']` e `janelas: [20]`.
3. Para cada conversa, o workflow:
   - manda as mensagens do cliente uma a uma ao núcleo;
   - lê no banco o que ficou gravado (interesses, pedidos, avaliação, status);
   - faz as **checagens automáticas**: o pedido saiu com o SKU, tamanho, quantidade e pagamento certos? A nota foi gravada?
   - pede à **IA avaliadora** uma nota de 0 a 10 sobre a conversa (preços certos, confirmou antes, não inventou nada);
   - salva tudo em `resultados_teste` e devolve o estoque.
4. No fim, o nó **Resumo da rodada** mostra uma linha por configuração.

### Ver os resultados no Supabase

```sql
-- Comparar configurações (a melhor no topo)
select * from resumo_testes order by rodada desc, aprovados_auto desc, nota_media_juiz desc;

-- O que deu errado na última rodada
select cenario_id, esforco, janela, checagens, nota_juiz, comentario_juiz, transcricao
from resultados_teste
where rodada = (select max(rodada) from resultados_teste)
  and (not aprovado_auto or not aprovado_juiz)
order by cenario_id;
```

Os dois critérios funcionam juntos: **`aprovado_auto`** é objetivo (o banco ficou certo?) e **`aprovado_juiz`** avalia o texto (o que o agente disse estava certo e bem dito?). Use a configuração com mais aprovações nos dois, e entre empates a mais rápida (`segundos_por_cenario`).

### Custo e tempo

Pelo meu cálculo, uma bateria completa como a do exemplo (84 conversas) custa em torno de **US$ 1** e leva de 15 a 30 minutos. A maior parte do custo vem da IA avaliadora. Para economizar, troque `modelo_juiz` para `anthropic/claude-haiku-5.5`, sabendo que o avaliador fica menos rigoroso.

## 6. Cobrir todas as possibilidades

Cada cenário é uma linha na tabela `cenarios_teste`. Para criar mais, use o **Table Editor** do Supabase, ou um `insert` copiando o formato do `04_ambiente_testes.sql`.

O que os 14 cenários já cobrem e o que vale acrescentar:

| Tipo | Cenários prontos | Ideias para acrescentar |
|---|---|---|
| Compra que dá certo | C01, C14 | Cartão parcelado, cliente que muda o tamanho antes de confirmar |
| Dúvidas sobre produto | C02, C09, C10 | Comparar medidas, "serve em quem tem 1,90 m?", cuidados de lavagem |
| Limites de estoque e tamanho | C03, C04 | Pedir mais que o estoque em 2 produtos ao mesmo tempo |
| Fora do catálogo | C05 | Produto parecido com nome errado ("camisa Palestra azul") |
| Negociação | C06 | Cupom, frete grátis, prazo de entrega |
| Passar para humano | C07 | Reclamação irritada, pedido de nota fiscal |
| Fora do escopo e segurança | C08, C13 | Pedir dados de outros clientes, xingamentos |
| Memória | C11 | Conversa de 15+ turnos, cliente que volta a falar de uma peça anterior |
| Desistência | C12 | Cliente some no meio e volta depois |
| Avaliação | C01, C11 | Nota baixa com reclamação, nota fora de 1 a 5 ("nota 10!") |
| Escrita real | (nenhum) | Gírias, erros de digitação, tudo em minúsculas, áudio transcrito |

### O ciclo de melhoria

1. Rode a bateria.
2. Abra os cenários que falharam e leia a `transcricao` e o `comentario_juiz`.
3. Ajuste **uma coisa só**: o prompt (System Message do núcleo), o `esforco`, a `janela` ou uma descrição do catálogo.
4. Clique em **Publish** no núcleo e rode a bateria de novo.
5. Compare as rodadas em `resumo_testes`. Se melhorou sem piorar outros cenários, mantenha a mudança.

Quando um erro aparecer no chat de demonstração, transforme-o em cenário. Assim ele nunca volta sem você perceber.

## 7. Mostrar ao cliente

### O link do chat

Abra o nó **Chat público** do workflow de demonstração: o link aparece em **Chat URL** (algo como `https://seu-n8n/webhook/c3d2e1f0-.../chat`). Ele só funciona com o workflow publicado.

- **n8n num servidor com domínio** (VPS, Easypanel, Railway etc.): é só mandar o link.
- **n8n no seu computador:** o cliente não consegue abrir `localhost`. Uma saída gratuita é o Cloudflare Tunnel:

  ```bash
  cloudflared tunnel --url http://localhost:5678
  ```

  Ele mostra um endereço `https://....trycloudflare.com`. Reinicie o n8n com a variável `WEBHOOK_URL` apontando para esse endereço, para o n8n mostrar o link certo. O endereço muda a cada vez que o túnel reinicia.

Para limitar quem acessa, no nó **Chat público** troque **Authentication** para **Basic Auth** e passe usuário e senha ao cliente.

### O painel para o cliente acompanhar

Mostre no Supabase (**Table Editor**) as tabelas `pedidos`, `avaliacoes` e `interesses` durante a demonstração. Ou use estas consultas:

```sql
-- Pedidos feitos no chat de demonstração
select p.criado_em, p.nome_cliente, p.sku, p.tamanho, p.quantidade, p.forma_pagamento, p.valor_total
from pedidos p join conversas c on c.id = p.conversa_id join clientes cl on cl.id = c.cliente_id
where cl.identificador like 'demo:%' order by p.criado_em desc;

-- Nota média do atendimento
select round(avg(a.nota), 2) as nota_media, count(*) as avaliacoes
from avaliacoes a join conversas c on c.id = a.conversa_id join clientes cl on cl.id = c.cliente_id
where cl.identificador like 'demo:%';
```

### Zerar a demonstração antes de mostrar

Esta consulta apaga as conversas do chat público e devolve o estoque, como a `limpar_testes()` faz para a bateria:

```sql
update clientes set identificador = 'teste:' || identificador where identificador like 'demo:%';
select limpar_testes();
```

## 8. Fotos dos produtos

O agente mostra a foto do produto quando o apresenta pela primeira vez. Ele só usa o link cadastrado no banco e nunca inventa um.

### Preparar o banco

No **SQL Editor**, rode `supabase/05_fotos.sql` inteiro. Ele cria a coluna `foto_url` na tabela `produtos` e faz o catálogo enviado ao agente incluir a linha `Foto:`.

### Hospedar as fotos (Supabase Storage, gratuito)

1. No Supabase, abra **Storage → New bucket**, dê o nome `produtos` e ligue **Public bucket**.
2. Clique em **Upload files** e envie uma foto por produto. JPG ou PNG, de preferência quadrada e com até 300 KB, para carregar rápido no celular.
3. Clique na foto e em **Get URL** (ou **Copy URL**). O link fica assim: `https://SEU-PROJETO.supabase.co/storage/v1/object/public/produtos/cel-br.jpg`.
4. Em **Table Editor → produtos**, cole o link na coluna `foto_url` do produto. Ou use o SQL:

   ```sql
   update produtos set foto_url = 'COLE-O-LINK-AQUI' where sku = 'CEL-BR';
   ```

Produto sem `foto_url` aparece para o agente como "(sem foto cadastrada)", e ele segue sem foto.

Também dá para usar o link da imagem que já está no site da loja (clique com o botão direito na foto → **Copiar endereço da imagem**). Alguns sites bloqueiam imagens abertas fora deles; se a foto não aparecer no chat, use o Supabase Storage.

### Atualizar o n8n

O prompt ganhou uma seção **Fotos**. Para aplicar, faça uma das duas opções:

- Baixe o `n8n/1-nucleo-agente.json` novo e importe de novo, como na seção 3. Depois religue o Núcleo no chat e na bateria.
- Ou cole o conteúdo de `n8n/system-prompt.md` na **System Message** do nó **Agente Olden** e clique em **Publish**.

### No WhatsApp

No chat de demonstração, a foto aparece dentro da conversa porque o chat do n8n entende Markdown (`![nome](link)`). O WhatsApp não entende Markdown: lá a foto precisa ser enviada como mídia, por uma chamada ao provedor (por exemplo, o envio de mídia da Evolution API). Quando o WhatsApp for conectado, o agente ganha uma ferramenta `enviar_foto` que manda a imagem pelo provedor, usando o mesmo `foto_url` do banco.

## 9. Tom e apresentação dos produtos

### Começa neutro, vira torcida com o sinal do cliente

Nem todo cliente é palmeirense, então a Lia começa **neutra**: simpática e profissional, sem gírias de torcida e sem emojis verdes (no máximo um 😊).

Ela passa para o **modo torcida** quando o cliente dá o sinal: diz que é palmeirense, fala com carinho do Palmeiras ou do Verdão, ou pede um produto do Palmeiras pelo nome ou pelo time. Uma pergunta genérica ("o que vocês vendem?") não conta. No modo torcida, ela usa expressões como Verdão, Palestra e Avanti, com 1 a 3 emojis por mensagem (💚 🟢 ✅ 🍀 🌳 ⚽ 🏆 🐷), e continua assim até o fim da conversa.

Em qualquer modo:
- não fala mal de rivais e não comenta jogos, resultados ou jogadores;
- recebe com carinho quem vem pelas Gêmeas All Star, mas nunca inventa cupom, brinde ou promoção;
- em trocas, reclamações, atrasos e problemas de pagamento, fala com calma, sem brincadeiras.

### Apresentação enxuta

A Lia dá a informação na hora em que o cliente precisa dela:

| Momento | O que ela mostra |
|---|---|
| Apresentar um produto | Nome, meia frase com o destaque, foto (se houver) e uma pergunta |
| Listar várias opções | Só nome e meia frase de cada uma, sem preços |
| Cliente pergunta o preço, escolhe o tamanho ou vai fechar | Preço no cartão (com parcelamento) e no Pix |
| Cliente pergunta medidas ou precisa escolher o tamanho | Medidas do catálogo |
| Resumo antes de registrar o pedido | Tudo: produto, tamanho, quantidade, pagamento, nome e total |

### Aplicar no n8n

1. No **Núcleo**, cole o conteúdo de `n8n/system-prompt.md` na **System Message** do nó **Agente Olden** e clique em **Publish**.
2. No **Chat de demonstração**, abra o nó **Chat público** e troque **Initial Message(s)** pela saudação neutra. Salve e clique em **Publish**:

   ```
   Oi! Eu sou a Lia, da Olden Sports 😊
   Como posso te ajudar hoje?
   ```

3. No Supabase, rode de novo o `supabase/04_ambiente_testes.sql`. Ele ajusta os cenários antigos para a apresentação enxuta e acrescenta os de tom (C15 a C19), sem apagar resultados anteriores.
4. A regra de tom e de apresentação da IA avaliadora fica no workflow da bateria: importe de novo o `3-bateria-testes.json` num workflow vazio, religue o nó **Conversar com o agente** ao Núcleo e selecione as credenciais.

### Testar

Na bateria, rode `cenarios: ['C01', 'C15', 'C18', 'C19']`. A avaliadora confere tom e apresentação: tom errado ou resposta poluída tiram até 2 pontos, e informação errada continua sendo o mais grave.

## Regerar os workflows

Os três JSON são gerados a partir de `n8n/system-prompt.md` e `n8n/build/gerar-workflows.js`:

```bash
node n8n/build/gerar-workflows.js
```

Se você editar o prompt direto no n8n, lembre de copiar a versão final para `n8n/system-prompt.md`, para não perder a mudança na próxima geração.
