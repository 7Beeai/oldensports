# Lia no WhatsApp: contas da Meta e virada do ambiente de teste

Este guia leva o ambiente de teste da página de chat para o WhatsApp de verdade. A Lia usa a **API oficial da Meta (Cloud API)**, sem intermediário (BSP): é a forma mais barata e a única que tem fichas de produto, listas, Flows e carrinho nativos.

Tudo do lado do n8n e do Supabase já está pronto e testado em **modo simulado**. No modo simulado, a Lia recebe e responde normalmente, mas o n8n só registra o que mandaria, sem chamar a Meta. Falta só criar as contas e trocar para o modo `real`.

## O que já está pronto

| Peça | Onde | Para que serve |
|---|---|---|
| Workflow **Olden \| 5. WhatsApp** | n8n | Recebe as mensagens da Meta, chama a Lia, converte os blocos em mensagens do WhatsApp e envia |
| Endereço do webhook | `https://n8n.treino.7bee.ai/webhook/olden-whatsapp` | Onde a Meta entrega as mensagens dos clientes |
| Feed do catálogo | `https://n8n.treino.7bee.ai/webhook/olden-catalogo-meta` | CSV com os 3.623 tamanhos, no formato do Commerce Manager |
| Flow "Descubra seu tamanho" | `n8n/whatsapp/flow-tamanho.json` | Tela nativa de altura, peso e caimento (ou idade, para infantil) |
| Credencial **WhatsApp Olden (token da Meta)** | n8n > Credentials | Onde você cola o token. Hoje tem um valor provisório |
| Tabela `whatsapp_mensagens` | Supabase | Tudo que entrou e saiu, com status de entrega e erros da Meta |
| `supabase/14_whatsapp.sql` | Supabase | Já aplicado. Configuração `whatsapp_*` e `provador_*` |

## Os 3 momentos da jornada que esta etapa liga

| Momento | No WhatsApp, sem catálogo da Meta | Com catálogo da Meta |
|---|---|---|
| **3. Ver de perto** | Cartão com foto, preço e botões "Quero essa", "Ver mais fotos" e "Qual meu tamanho?". "Ver mais fotos" manda até 5 fotos (o WhatsApp agrupa em álbum) e o link do vídeo | Ficha nativa do produto, com fotos, preço e "Adicionar ao carrinho" |
| **5. Tamanho certo** | Sem o Flow: a Lia pergunta altura, peso e caimento por texto. Com o Flow: abre a tela nativa | Igual |
| **6. Provador virtual** | O cliente manda uma selfie e recebe a prévia gerada por IA. A referência da foto é apagada logo depois | Igual |

O provador é **experimental**. A prévia usa o modelo `google/gemini-3.1-flash-image` pelo mesmo OpenRouter da Lia. Ela custa alguns centavos por imagem e leva de 10 a 30 segundos. Só é oferecido para peças de adulto. Para desligar:

```sql
update configuracao set valor = 'não' where chave = 'provador_ativo';
```

---

## Passo 1. Criar as contas da Meta

### 1.1 Portfólio empresarial (Business Manager)
1. Entre em **business.facebook.com** com um Facebook pessoal de alguém da Olden. Esse perfil vira administrador.
2. Crie o portfólio empresarial **Olden Sports** com os dados da empresa (razão social, CNPJ, site, e-mail).
3. Em **Configurações > Central de segurança**, inicie a **verificação da empresa**: contrato social ou cartão CNPJ, e um comprovante com o mesmo endereço ou telefone. A verificação leva de alguns dias a 2 semanas. Dá para testar enquanto isso, mas ela é necessária para:
   - aprovar o nome de exibição;
   - aumentar o limite de conversas por dia;
   - ter o selo de conta comercial verificada no futuro.

### 1.2 App de desenvolvedor com WhatsApp
1. Entre em **developers.facebook.com** com o mesmo perfil e clique em **Meus apps > Criar app**.
2. Escolha o caso de uso **"Conectar-se com clientes pelo WhatsApp"** e vincule ao portfólio Olden Sports.
3. Em **WhatsApp > Configuração da API**, a Meta cria uma **conta de teste com um número de teste**. Com ele já dá para testar, antes de ter o número definitivo:
   - Em **Para**, adicione o seu celular (a Meta manda um código). O número de teste só conversa com até 5 números cadastrados.
   - Anote o **Identificação do número de telefone** (*phone number ID*). Não é segredo, pode me mandar no chat.

### 1.3 Token permanente (o token da página expira em 24 horas)
1. Em **business.facebook.com > Configurações > Usuários > Usuários do sistema**, clique em **Adicionar** e crie, por exemplo, "Lia n8n", com função **Administrador**.
2. Em **Atribuir ativos**, dê controle total ao **app** e à **conta do WhatsApp**. Quando tiver o catálogo, faça o mesmo com ele.
3. Clique em **Gerar token**:
   - Escolha o app.
   - Em **Expiração**, escolha **Nunca**.
   - Marque as permissões `whatsapp_business_messaging`, `whatsapp_business_management` e `catalog_management`.
4. **Não mande esse token no chat.** No n8n, abra **Credentials > WhatsApp Olden (token da Meta)** e, em **Value**, troque `COLE-AQUI-O-TOKEN-DA-META` pelo token. Mantenha o `Bearer ` na frente. Salve.

### 1.4 Webhook (a Meta avisa o n8n quando chega mensagem)
1. Descubra o token de verificação com esta consulta no SQL Editor do Supabase:
   ```sql
   select valor from configuracao where chave = 'whatsapp_verify_token';
   ```
2. No app, abra **WhatsApp > Configuração > Webhook > Editar**:
   - **URL de callback:** `https://n8n.treino.7bee.ai/webhook/olden-whatsapp`
   - **Token de verificação:** o valor da consulta
3. Clique em **Verificar e salvar**. O n8n responde sozinho.
4. Em **Campos do webhook**, assine **messages**.

### 1.5 Ligar o modo real
Com o *phone number ID* e o token salvo no n8n, rode no Supabase (ou me mande o ID que eu rodo):

```sql
update configuracao set valor = 'COLE_O_PHONE_NUMBER_ID' where chave = 'whatsapp_phone_number_id';
update configuracao set valor = 'real' where chave = 'whatsapp_modo';
```

Mande "oi" do seu celular para o número de teste. A Lia responde em poucos segundos.

### 1.6 Número definitivo (quando for para valer)
1. Em **WhatsApp Manager > Telefones > Adicionar número**, use um número que **não** esteja no WhatsApp comum nem no WhatsApp Business do celular. Um número já em uso precisa ser apagado do app antes de migrar.
2. Cadastre o **nome de exibição** ("Olden Sports"). A Meta revisa o nome.
3. Cadastre uma **forma de pagamento** na conta do WhatsApp:
   - Resposta a cliente dentro de 24 horas: gratuita.
   - Mensagem que a loja inicia depois de 24 horas sem resposta: paga, e precisa de modelo aprovado.
4. Para usar com clientes reais, o app precisa estar em **modo Ao vivo**. Isso pede uma URL de política de privacidade.
5. Troque o `whatsapp_phone_number_id` para o ID do número novo.

---

## Catálogo da Meta (fichas e listas nativas de produto)

1. **business.facebook.com > Commerce Manager > Adicionar catálogo**, do tipo **E-commerce**, de nome "Olden Sports".
2. **Fontes de dados > Adicionar itens > Feed de dados > Feed programado**:
   - **URL:** `https://n8n.treino.7bee.ai/webhook/olden-catalogo-meta`
   - **Frequência:** a cada hora
   - **Moeda:** BRL
3. Espere o processamento. A Meta revisa os itens, e alguns podem ser recusados pela política de comércio. O feed tem um item por tamanho, agrupados por modelo (`item_group_id`).
4. **WhatsApp Manager > Ferramentas da conta > Catálogo:** conecte o catálogo à conta do WhatsApp. Se quiser, ligue o **carrinho**.
5. Copie o **ID do catálogo** e rode:
   ```sql
   update configuracao set valor = 'COLE_O_ID_DO_CATALOGO' where chave = 'whatsapp_catalogo_id';
   ```
   A partir daí, produto, carrossel, vitrine e catálogo viram mensagens nativas. Sem o ID, a Lia continua usando foto + botões.

> No número de teste, a conexão do catálogo pode não aparecer. Nesse caso, faça este passo com o número definitivo.

## Flow "Descubra seu tamanho"

1. **WhatsApp Manager > Ferramentas da conta > Flows > Criar Flow**. Use o nome "Descubra seu tamanho" e a categoria "Outro", **sem endpoint**.
2. No editor, apague o exemplo e cole o conteúdo de `n8n/whatsapp/flow-tamanho.json`. Se o editor reclamar da versão (`"version": "7.1"`), troque pela versão que ele sugerir.
3. Salve. Na pré-visualização, preencha os dados de exemplo para conferir a tela.
4. Copie o **ID do Flow** e rode:
   ```sql
   update configuracao set valor = 'COLE_O_ID_DO_FLOW' where chave = 'whatsapp_flow_tamanho_id';
   ```
5. Enquanto o Flow estiver em rascunho, ele só abre para quem é administrador do app. Isso basta para os testes. Depois de **Publicar**:
   ```sql
   update configuracao set valor = 'published' where chave = 'whatsapp_flow_modo';
   ```

Ao tocar em **Ver meu tamanho**, a resposta volta para a Lia com a mesma frase da página de chat ("Minhas medidas para a …"). Ela calcula o tamanho com `recomendar_tamanho` e responde na conversa. O resultado aparece no chat, e não dentro da tela como no protótipo. Mostrar dentro da tela exige um endpoint com criptografia. Isso fica para depois.

---

## Roteiro de teste no celular (momentos 3, 5 e 6)

| # | Você manda | O que deve chegar |
|---|---|---|
| 1 | "oi, tem camisa do corinthians feminina?" | Texto curto e até 5 cartões com foto, preço e 3 botões |
| 2 | Toque em **Ver mais fotos** num cartão | Até 5 fotos em álbum e o link do vídeo |
| 3 | Toque em **Qual meu tamanho?** | Botão **Ver meu tamanho** (com o Flow) ou pergunta por texto |
| 4 | Preencha 1,65 m, 62 kg e Normal | "Pra você, eu iria no M, e tem em estoque", com botões |
| 5 | "quero ver como ela fica em mim" | Pedido de selfie, avisando que a foto é apagada |
| 6 | Mande uma selfie de frente | "Deixa comigo…", a prévia gerada por IA e os botões "Quero essa" e "Qual meu tamanho?" |
| 7 | "quero no M, no pix, meu nome é Ana" e confirme | Resumo, depois o botão **Pagar agora** |
| 8 | Pague na página de teste | Sem você escrever nada: o aviso de pagamento aprovado e, a cada 2 minutos, uma etapa do rastreio |

Para começar do zero com o seu número:

```sql
select limpar_whatsapp_teste('wa:55DDDNUMERO');
```

## Como acompanhar e investigar

O que entrou e saiu (o `texto` mostra o que a Lia leu e um resumo do que foi enviado):

```sql
select criado_em, direcao, tipo, status, texto, erro
from whatsapp_mensagens order by id desc limit 30;
```

| Sintoma | Causa provável |
|---|---|
| `status = erro` e erro `131030` | Número não cadastrado como destinatário do número de teste |
| `status = erro` e erro `131047` | Passaram mais de 24 horas desde a última mensagem do cliente: só modelo aprovado pode ser enviado |
| `status = erro` e erro `190` ou `401` | Token inválido ou expirado: gere o token permanente (1.3) |
| Não chega nada no n8n | Webhook não verificado ou campo **messages** não assinado (1.4) |
| `status = simulada` | `whatsapp_modo` ainda está `simulado` (1.5) |

## Limites e próximos passos

- **Segurança do webhook:** hoje o n8n aceita qualquer POST no endereço do webhook. Antes de abrir para clientes reais, vale conferir a assinatura `X-Hub-Signature-256` com o *app secret*. O n8n precisa permitir o módulo `crypto` no nó Code.
- **Avisos depois de 24 horas:** o pagamento e o rastreio de teste acontecem em minutos, dentro da janela. Na operação real, um aviso de entrega dias depois precisa de **modelo de utilidade** aprovado pela Meta (momento 8 da jornada).
- **Origem #GEMEAS e carrossel de mídia** (momento 1) e **carrinho nativo** (momento 7) dependem do catálogo e de modelos aprovados. A mensagem de carrinho (`order`) já chega para a Lia, como texto.
