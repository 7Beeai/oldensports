# Agente de atendimento Olden: guia passo a passo

Objetivo: um agente que atende o cliente que chega querendo uma peça, tira dúvidas sobre outras, registra o pedido e, no final, pede uma avaliação de 1 a 5.

Custo do teste: zero. Usa o plano Free do Supabase, a camada gratuita do Gemini e o chat de teste do próprio n8n.

```
Cliente ──► Chat do n8n (depois: WhatsApp)
              │
              ▼
   Contexto do atendimento ── Supabase: cria cliente/conversa e lê catálogo + estoque
              │
              ▼
        Agente Olden ◄── Google Gemini (modelo)
              │      ◄── Memória da conversa (Supabase)
              │      ◄── registrar_interesse  ─┐
              │      ◄── registrar_pedido     ─┼─► Supabase
              │      ◄── registrar_avaliacao  ─┘
              ▼
        Resposta ao cliente
```

## Arquivos

| Arquivo | Para que serve |
|---|---|
| `supabase/01_schema.sql` | Tabelas, regras (estoque, preço, status) e a função que monta o catálogo |
| `supabase/02_catalogo.sql` | Os 8 produtos e o estoque de teste |
| `n8n/olden-agente-whatsapp.json` | Workflow para importar no n8n |
| `n8n/system-prompt.md` | O prompt do agente (o mesmo que já está dentro do workflow) |
| `n8n/build/gerar-workflow.js` | Regera o JSON se você editar o prompt: `node n8n/build/gerar-workflow.js` |

---

## Passo 1. Supabase: criar o banco

1. Crie uma conta em **supabase.com** e clique em **New project** (plano Free).
2. Anote a **senha do banco** que você definir. Ela será usada no n8n.
3. Abra **SQL Editor → New query**, cole todo o conteúdo de `supabase/01_schema.sql` e clique em **Run**.
4. Nova query: cole `supabase/02_catalogo.sql` e clique em **Run**.
5. Confira: rode `select catalogo_texto();` e veja os 8 produtos com preços e tamanhos.

**Importante:** cada arquivo precisa ser enviado **inteiro, de uma vez**. Abra uma query nova, apague o que houver nela, cole o arquivo todo e clique em **Run** sem nenhum trecho selecionado (com uma seleção, o Supabase roda só a seleção). Não use o Assistant do Supabase para executar: ele pode quebrar o script em pedaços. Se o erro mostrar `LINE 1` ou `LINE 2` apontando para o meio do arquivo, é sinal de que só um pedaço foi enviado.

Os dois arquivos podem rodar de novo sem duplicar nada. O `02_catalogo.sql` também serve para **resetar o estoque** para 8 depois dos testes.

### Pegar os dados de conexão

1. No topo do projeto, clique em **Connect**.
2. Escolha **Session pooler**. Não use a "Direct connection": ela só funciona em IPv6 e costuma falhar no n8n.
3. Anote: **host** (algo como `aws-0-sa-east-1.pooler.supabase.com`), **port** `5432`, **database** `postgres` e **user** (`postgres.xxxxxxxx`, com o código do projeto).

## Passo 2. Gemini: chave gratuita

1. Acesse **aistudio.google.com** e entre com sua conta Google.
2. Clique em **Get API key → Create API key**.
3. Copie a chave. Não precisa cadastrar cartão.

A camada gratuita tem limite de requisições por minuto. Se aparecer erro 429, espere um minuto e tente de novo.

## Passo 3. n8n: credenciais

No n8n, vá em **Credentials → Add credential** (ou **Overview → Create → Credential**):

**Postgres** (nome sugerido: `Supabase Postgres`)
- Host: o host do Session pooler.
- Database: `postgres`.
- User: `postgres.xxxxxxxx`.
- Password: a senha do banco.
- Port: `5432`.
- SSL: `require`. Se reclamar do certificado, ligue **Ignore SSL Issues**.
- Clique em **Save**. O n8n testa a conexão.

**Google Gemini (PaLM) API** (nome sugerido: `Google Gemini`)
- API Key: a chave do AI Studio.
- Host: deixe o padrão.

## Passo 4. n8n: importar o workflow

1. **Overview → Create workflow**.
2. Menu **⋯** (canto superior direito) **→ Import from File** e escolha `n8n/olden-agente-whatsapp.json`.
3. Os nós de banco e de modelo vão aparecer com alerta de credencial. Abra cada um e selecione a credencial:
   - **Contexto do atendimento**, **Memória da conversa**, **registrar_interesse**, **registrar_pedido** e **registrar_avaliacao**: `Supabase Postgres`.
   - **Google Gemini**: `Google Gemini`.
4. No nó **Google Gemini**, confira o modelo. O workflow usa `gemini-flash-latest`, que sempre aponta para o Flash mais recente. Se o seu n8n não aceitar, escolha na lista qualquer modelo **Flash**.
5. Clique em **Save**.

### Onde ficam as variáveis do agente

Não há tela separada de variáveis. Elas são **expressões** que o n8n preenche a cada mensagem:

| Variável | Onde aparece | De onde vem |
|---|---|---|
| `chatInput` → `mensagem` | Campo **Prompt** do Agente (`$json.mensagem`) | Texto que o cliente enviou |
| `sessionId` | Nó **Contexto do atendimento** | Identifica o cliente (no WhatsApp será o telefone) |
| `conversa_id` | Memória e as 3 ferramentas (`$json.conversa_id`) | Criada pelo Supabase; separa cada atendimento |
| `cliente_nome`, `status` | System Message do Agente | Supabase |
| `catalogo` | System Message do Agente | Função `catalogo_texto()`: preço e estoque atualizados |
| `$fromAI('sku')`, `$fromAI('nota')`… | Ferramentas | A IA preenche ao decidir usar a ferramenta |

Tudo que o Agente usa vem do nó anterior (`$json`), sem referência a outros nós. Por isso, teste sempre pelo **Open chat**, que roda o fluxo inteiro, e não pelo botão **Execute step** de um nó isolado.

Para mudar o comportamento, edite a **System Message** no nó **Agente Olden** (Options → System Message). Para mudar produtos, preços ou estoque, edite as tabelas `produtos` e `estoque` no **Table Editor** do Supabase. O agente lê os dados novos na próxima mensagem, sem mexer no n8n.

## Passo 5. Testar

1. Com o workflow aberto, clique em **Open chat** (embaixo, no centro).
2. Converse como cliente. Cada vez que você abre um chat novo, o n8n cria uma nova sessão, ou seja, um "cliente" novo.
3. Depois de cada teste, confira no Supabase (**Table Editor**): `conversas`, `interesses`, `pedidos`, `avaliacoes` e `estoque`.
4. Para ver o que o agente fez, abra **Executions** e clique numa execução. Lá aparecem as ferramentas chamadas e os erros.

### Roteiro de testes

| # | Você escreve | Esperado |
|---|---|---|
| 1 | "Oi, quero a camisa Celebration" | Apresenta a camisa, preço no cartão e no Pix, pergunta o tamanho. Grava em `interesses` |
| 2 | "Tenho 1,80 m, qual tamanho?" | Usa as medidas do catálogo, sem inventar tabela |
| 3 | "E a polo verde do Abel, como é?" | Apresenta a POLO-VD e registra interesse |
| 4 | "Fecha 1 Celebration G no Pix, meu nome é Ana" | Resume e pede confirmação **antes** de registrar |
| 5 | "Confirmo" | Grava em `pedidos` com valor R$ 161,41, baixa o estoque e pede a nota |
| 6 | "Nota 5, adorei, atendimento rápido" | Grava em `avaliacoes`; a conversa fica `encerrada` |
| 7 | "Quero 20 baby looks M" | Recusa com base no estoque (8) e oferece o que há |
| 8 | "Vocês têm camisa do Corinthians?" | Diz que não tem e sugere algo do catálogo |
| 9 | "Faz por 100 reais?" | Não dá desconto além do Pix |
| 10 | "Quero trocar um pedido antigo" | Encaminha para um humano |
| 11 | "Me escreve um poema" | Volta educadamente para os produtos |
| 12 | Avaliação só com "4" | Grava sem comentário e não insiste |

Se algo sair errado, ajuste a System Message e repita o teste.

### Zerar os dados de teste

No SQL Editor do Supabase:

```sql
truncate avaliacoes, pedidos, interesses, conversas, clientes, n8n_chat_histories restart identity cascade;
```

Depois rode de novo o `02_catalogo.sql` para voltar o estoque a 8.

## Passo 6. Depois dos testes: ligar no WhatsApp

Quando o agente estiver bom no chat de teste:

1. Suba uma **Evolution API**. Ela é gratuita se você hospedar (Docker).
2. Troque o nó **Mensagem recebida** por um **Webhook** e configure a Evolution para enviar as mensagens para a URL dele.
3. Adicione um nó **Set** depois do Webhook com:
   - `sessionId` = telefone (`data.key.remoteJid`);
   - `chatInput` = texto (`data.message.conversation`).
   Assim o resto do fluxo não muda.
4. Filtre mensagens de grupo e as enviadas por você (`data.key.fromMe`).
5. No fim, adicione um **HTTP Request** para o endpoint de envio de texto da Evolution, com a resposta do agente.

## Segurança

- O RLS está ligado em todas as tabelas, então a chave pública (`anon`) do Supabase não lê nada. O n8n entra pela conexão Postgres, que tem acesso total. Não compartilhe a senha do banco.
- Preço e valor total são calculados **pelo banco**, nunca pela IA. Mesmo que o modelo erre, o pedido grava o valor certo.
- O estoque só baixa se houver saldo. Se não houver, o banco devolve erro e o agente explica ao cliente.
