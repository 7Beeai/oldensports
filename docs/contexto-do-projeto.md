# Projeto Lia · Olden Sports: contexto completo

*Atualizado em 24/11/2026. Repositório `7beeai/oldensports`, branch `claude/magical-cori-iybvak`.*

---

## 1. Resumo

A **Lia** é uma agente de IA que atende clientes da **Olden Sports** (loja de produtos oficiais do Palmeiras). Ela faz o atendimento do começo ao fim:

1. Entende o que o cliente procura e tira dúvidas.
2. Registra o pedido e envia o link de pagamento.
3. Avisa sozinha quando o pagamento é aprovado e a cada etapa da entrega.
4. Pede a avaliação do atendimento.

Hoje o projeto é um **ambiente de testes funcionando**, com 8 produtos, pagamento e rastreio fictícios, chat de demonstração na web e uma bateria de testes automática que mede a qualidade da Lia.

O próximo passo em discussão é **oferecer a solução à loja oficial da Olden** como novo canal de aquisição no WhatsApp. Isso exige um catálogo de mais de 1000 produtos e a API oficial do WhatsApp (seção 11).

---

## 2. Objetivo de negócio

- **Canal de aquisição:** criar um canal de vendas pelo WhatsApp, divulgado inicialmente pelas influenciadoras **Gêmeas All Star**.
- **Atendente:** a Lia substitui a atendente humana no dia a dia, com linguagem natural e humanizada. Casos sensíveis (troca, reclamação, problema de pagamento) vão para uma pessoa da equipe.
- **Experiência:** o cliente resolve tudo na conversa, da descoberta do produto ao pós-venda.
- **Fase atual:** teste e validação, para apresentar à loja oficial e depois conectar a dados reais (pagamento, rastreio e WhatsApp).

---

## 3. Situação atual

| Item | Situação |
|---|---|
| Banco no Supabase (catálogo, pedidos, pagamentos, rastreio, testes, prompt) | Instalado e funcionando |
| Lia no n8n com Claude Haiku 5.5 via OpenRouter | Funcionando |
| Chat de demonstração (página própria) | Funcionando |
| Bateria de testes automática | Funcionando (rodada pelo usuário) |
| Pagamento fictício e aviso automático da Lia | Funcionando (confirmado pelo usuário) |
| Avisos automáticos a cada etapa do rastreio | Implementado e testado localmente; a ser confirmado no ambiente do usuário |
| Fotos dos produtos | Estrutura pronta; links das fotos não cadastrados |
| WhatsApp | Não conectado (provedor ainda não escolhido) |
| Pagamento e rastreio reais | Não conectados (fictícios no teste) |
| Catálogo completo da loja oficial | 961 modelos e 3.623 tamanhos coletados do site (Tray), com a busca `buscar_produtos` |
| Lia com catálogo completo e respostas em blocos (passo 3 do guia) | Implementado e testado localmente com modelo simulado; a validar com o Claude real |
| Ajuda com tamanho e comparação (passo 5 do guia) | Implementado no chat de demonstração e testado localmente; o Flow e a imagem do WhatsApp entram com o canal |

---

## 4. Arquitetura

```
Cliente ──► Página de chat (web)  ─┐                    ┌─► Claude Haiku 5.5 (OpenRouter)
           Open chat do n8n       ─┼─► 1. Núcleo da Lia ─┤
           Bateria de testes      ─┤   (n8n)            └─► Supabase (Postgres)
           Aviso de pagamento     ─┤                         catálogo, estoque, pedidos,
           Verificação de rastreio─┘                         pagamentos, rastreio, memória,
                                                             prompt, testes, mensagens
Páginas públicas (n8n): pagamento de teste · confirmação · rastreio
```

**Ferramentas usadas**

| Ferramenta | Uso | Observação |
|---|---|---|
| **n8n 2.47** (self-hosted) | Orquestra o agente, as páginas e as rotinas | 5 workflows |
| **Supabase** (Postgres, plano Free) | Dados, regras de negócio, memória, prompt e testes | Regras de preço e estoque ficam no banco, não na IA |
| **OpenRouter** | Acesso aos modelos Claude | Haiku 5.5 para a Lia; Sonnet 5.5 para a IA avaliadora |
| **Claude Haiku 5.5** | Cérebro da Lia | Não aceita mudança de temperatura; a precisão vem de esforço, prompt e testes |

**Variáveis do agente** (nó **Configuração** do Núcleo)

| Variável | Padrão | O que faz |
|---|---|---|
| `modelo` | `anthropic/claude-haiku-5.5` | Qual modelo responde |
| `esforco` | `medium` | Quanto ele raciocina (`low`, `medium`, `high`) |
| `janela` | 20 | Quantas interações anteriores a Lia lembra |
| `sessao` | vem do canal | Identifica o cliente (`demo:`, `teste:` ou `wa:` + telefone no WhatsApp) |

---

## 5. Os 5 workflows do n8n

| Workflow | Função | Nós principais |
|---|---|---|
| **1. Núcleo do agente** | A Lia em si. Todos os outros chamam este. | Configuração → Contexto do atendimento → Agente Olden (Claude + memória + 4 ferramentas). O prompt vem do banco a cada mensagem. |
| **2. Chat de demonstração** | Onde o cliente conversa | Página de chat própria (`/webhook/olden-chat`), que busca a cada 3 s as mensagens que a Lia manda sozinha; também o Open chat do n8n, para testes rápidos |
| **3. Bateria de testes** | Mede a qualidade da Lia | Roda cenários em várias configurações, confere o banco, dá nota com IA avaliadora e salva o resultado |
| **4. Pagamento e rastreio de teste** | Páginas públicas e rotinas | Página de pagamento fictício, confirmação, página de rastreio e uma verificação a cada minuto que dispara os avisos de entrega |
| **5. WhatsApp** | A Lia na API oficial da Meta | Webhook `/webhook/olden-whatsapp`, conversão dos blocos em mensagens nativas, provador virtual, avisos da loja e feed do catálogo (`/webhook/olden-catalogo-meta`). Começa em modo simulado; veja [whatsapp.md](whatsapp.md) |

**Ferramentas da Lia**

- **`registrar_interesse`:** anota os produtos que o cliente perguntou.
- **`registrar_pedido`:** reserva o item. O banco calcula o preço e baixa o estoque.
- **`gerar_link_pagamento`:** cria o link de pagamento de teste dos itens reservados.
- **`registrar_avaliacao`:** grava a nota de 1 a 5 e encerra a conversa.

---

## 6. Banco de dados (Supabase)

Tudo é instalado pelo `supabase/00_instalar_tudo.sql`, que junta os arquivos 01 a 09. Ele pode ser rodado de novo sem duplicar nada, mas volta o estoque para 8 unidades por tamanho.

| Grupo | Tabelas e funções |
|---|---|
| Catálogo | `produtos` (8 itens, com `foto_url`), `estoque` (por tamanho), `catalogo_texto()` |
| Atendimento | `clientes`, `conversas` (status: aberta → aguardando_pagamento → aguardando_avaliacao → encerrada), `interesses`, `pedidos`, `avaliacoes`, `contexto_atendimento()` |
| Pagamento e rastreio (fictícios) | `pagamentos`, `gerar_pagamento()`, `confirmar_pagamento()`, `eventos_rastreio()`, `rastreio_avisos`, `avisos_rastreio_pendentes()`, `situacao_pedido()` |
| Mensagens da Lia por iniciativa própria | `mensagens_saida`, `aviso_pagamento()`, `aviso_rastreio()` |
| Prompt | `prompt_agente` (versões com histórico), `nova_versao_prompt()`, `ativar_prompt()`, `prompt_montado()` |
| Memória | `n8n_chat_histories` (por conversa) |
| Testes | `cenarios_teste` (25), `resultados_teste`, `resumo_testes` (view), `fatos_sessao()`, `limpar_testes()` |
| Configuração | `configuracao`: `url_base_n8n` e `minutos_por_etapa_rastreio` (2) |

**Regras de negócio no banco** (a IA não consegue errar nesses pontos):
- **Preço:** é calculado pelo banco, pela forma de pagamento escolhida.
- **Estoque:** só baixa se houver saldo; se faltar, o banco devolve erro.
- **Pagamento e rastreio:** o código de rastreio só existe depois do pagamento aprovado.
- **Segurança:** a chave pública do Supabase não lê nada, porque o RLS está ligado em todas as tabelas.

---

## 7. A Lia: comportamento

O prompt fica no Supabase, com histórico de versões; a cópia de referência é `n8n/system-prompt.md`. As regras principais:

- **Humanizada:** apresenta-se como "Lia, da Olden Sports", sem se dizer "atendente virtual". Escreve como uma vendedora no WhatsApp e cumprimenta de acordo com o horário de Brasília.
- **Honestidade:** se o cliente perguntar com sinceridade se é um robô, ela não nega. Diz que é a assistente digital e oferece chamar alguém da equipe.
- **Tom em dois modos:** começa neutra. Vira "torcida palmeirense" (expressões e emojis verdes 💚🟢) quando o cliente se diz palmeirense ou pede um produto do Palmeiras. Em reclamações, fica séria.
- **Apresentação enxuta:** mostra nome, destaque e foto. Preço, medidas e composição só quando o cliente precisa.
- **Precisão:** só fala do catálogo, não inventa preço, prazo, frete, desconto nem cupom. Também não confirma um pagamento que não consta no banco.
- **Gêmeas All Star:** recebe com carinho quem vem por elas, sem inventar promoções.
- **Pedido:** confirma tudo antes de registrar, envia o link de pagamento e avisa sozinha quando o pagamento é aprovado (com o rastreio) e a cada etapa da entrega.
- **Passa para um humano:** troca, devolução, reclamação, problema de pagamento ou pedido do cliente.
- **Fora do escopo:** recusa com gentileza.

Para mudar o comportamento: rodar o `supabase/atualizar_prompt.sql` no Supabase, sem mexer no n8n. Para voltar atrás: `select ativar_prompt(N);`.

---

## 8. Fluxo completo do cliente (teste)

1. **Conversa:** o cliente abre a página de chat e conversa com a Lia.
2. **Pedido:** a Lia registra o interesse, confirma produto, tamanho, quantidade, pagamento e nome, e registra o pedido.
3. **Link:** a Lia envia o link de pagamento. A página fictícia tem os botões **Simular pagamento aprovado** e **Simular pagamento recusado**.
4. **Aprovação:** a loja avisa a Lia, e ela escreve sozinha que viu o pagamento, com o código de rastreio (`OLD-TESTE-000000`), o link e o pedido de avaliação.
5. **Entrega:** a entrega fictícia avança uma etapa a cada **2 minutos**:
   - pedido separado no estoque;
   - objeto postado;
   - em trânsito para a cidade de destino;
   - saiu para entrega;
   - entregue.

   A cada etapa, a Lia avisa o cliente.
6. **Avaliação:** o cliente dá a nota, e a conversa é encerrada.

---

## 9. Ambiente de testes e qualidade

**Bateria de testes**
- **Combinações:** cada cenário roda em todas as combinações de modelo × esforço × janela de memória.
- **Checagens automáticas:** a bateria confere no banco interesse, pedido (SKU, tamanho, quantidade, pagamento), pagamento, código de rastreio enviado, avaliação e status final.
- **IA avaliadora:** o Claude Sonnet 5.5 dá nota de 0 a 10 para precisão, tom, apresentação e honestidade.
- **Resultados:** ficam em `resultados_teste`, com o resumo por configuração em `resumo_testes`.
- **Custo:** uma bateria completa custa por volta de US$ 1 (estimativa).

**25 cenários**

| Grupo | Cenários |
|---|---|
| Vendas | C01 compra no Pix com avaliação · C02 compara duas peças · C14 pedido com dois produtos · C12 desiste antes de confirmar |
| Limites | C03 quantidade acima do estoque · C04 tamanho inexistente · C05 produto fora do catálogo · C06 pedido de desconto · C09 body para outra idade · C10 uso do lenço |
| Memória | C11 fecha o que pediu dez mensagens antes |
| Segurança e escopo | C07 troca (passa para humano) · C08 fora do escopo · C13 tentativa de manipulação · C21 pergunta se é robô |
| Tom | C15 torcida na venda · C16 veio pelas Gêmeas e pede cupom · C17 cliente chateado · C18 neutro · C19 neutro que vira torcida · C20 saudação curta |
| Pagamento e entrega | C22 diz que pagou sem pagar · C23 pagamento recusado · C24 pergunta quando chega · C25 avisos de rastreio |

---

## 10. Decisões tomadas e por quê

| Decisão | Motivo |
|---|---|
| Regras de preço e estoque no banco | A IA não erra conta nem vende sem estoque |
| Núcleo separado dos canais | Um só agente para chat, testes, avisos e, no futuro, WhatsApp |
| Prompt no Supabase com versões | Mudar comportamento sem mexer no n8n, com possibilidade de voltar atrás |
| Claude Haiku 5.5 via OpenRouter | Bom custo para atendimento em volume; troca de modelo por variável |
| Sem temperatura | O Haiku 5.5 recusa valores diferentes do padrão |
| Página de chat própria | O chat do n8n não mostra mensagens que a Lia manda sozinha |
| Lia não finge ser humana quando perguntada | Honestidade, confiança na marca e Código de Defesa do Consumidor |
| Pagamento e rastreio fictícios com a mesma estrutura dos reais | Trocar pelos reais depois sem mudar a Lia |
| Bateria de testes com cenários no banco | Medir a qualidade antes de cada mudança e comparar configurações |

---

## 11. Próxima fase: loja oficial (1000+ produtos no WhatsApp)

**Problema:** mostrar o portfólio completo, ou filtrado pelo interesse do cliente, sem que ele saia do WhatsApp e com uma boa experiência.

**Proposta**

1. **WhatsApp oficial (Cloud API da Meta)**, direto ou por um parceiro (360dialog, Twilio, Gupshup, Blip, Zenvia). É necessário para as vitrines interativas e evita o risco de bloqueio do número.
2. **Catálogo da Meta** (Commerce Manager) sincronizado automaticamente com a loja, organizado em **coleções** (lançamentos, camisas de jogo, feminino, infantil, acessórios, promoções).
3. **Busca no lugar do catálogo no prompt:** os produtos ficam no Supabase com uma busca por significado. A Lia ganha a ferramenta `buscar_produtos` e recebe só os melhores resultados.
4. **Formas de mostrar os produtos sem link externo:**
   - **Botão "Ver catálogo":** abre o catálogo nativo do WhatsApp, para navegar livremente.
   - **Menu de departamentos** (até 10 opções): o cliente só toca, sem precisar de filtro.
   - **Vitrine de vários produtos** (até 30, em seções), por departamento ou por busca.
   - **Produto único**, para uma peça específica.
   - **Vitrines montadas pela própria Olden** (mais vendidos, lançamentos, promoções, campanhas das Gêmeas).
5. **Compra:** o carrinho enviado na conversa vira pedido. O pagamento é feito por link de checkout da loja, ou dentro do WhatsApp, se houver disponibilidade no Brasil para a Olden.
6. **Pós-venda:** o que já foi feito no teste, conectado ao pagamento e ao rastreio reais. Mais recompra e lembrete de carrinho abandonado, só para quem autorizou.

**Fases**

| Fase | Entrega |
|---|---|
| 0 | Número oficial, empresa verificada na Meta, parceiro escolhido |
| 1 | Sincronização da loja com o Supabase e o catálogo da Meta; busca; Lia sem o catálogo no prompt |
| 2 | Vitrines: menu de departamentos, vitrine de vários produtos, produto único, catálogo |
| 3 | Carrinho → pedido → pagamento |
| 4 | Pagamento e rastreio reais, avaliação, recompra |
| 5 | Painel de métricas: conversas, conversão, ticket médio, nota do atendimento |

**Demonstração sugerida para a Olden:** WhatsApp de verdade, com o número de teste da Meta e 50 a 100 produtos reais (por exemplo, só Palmeiras). Mostrar a conversa → vitrine → carrinho → pagamento → avisos de rastreio, junto com o resultado da bateria de testes.

---

## 12. Limitações e riscos conhecidos

- **Chat de demonstração:** reabrir a página começa uma conversa nova, porque o n8n não deixa a página guardar dados no navegador.
- **Catálogo no prompt:** só funciona com poucos produtos; com 1000+, a busca da seção 11 é obrigatória.
- **Camada gratuita de modelos:** o Gemini gratuito ficou instável (sobrecarga), e a migração para o Claude pago via OpenRouter resolveu.
- **Avisos de rastreio:** dependem de o workflow 4 estar publicado. A verificação de cada minuto também enche a aba **Executions** do n8n.
- **Avisos depois do encerramento:** a conversa se encerra com a avaliação; os avisos de entrega que chegam depois abrem uma conversa nova para o mesmo cliente.
- **Recursos do WhatsApp:** vitrines, menus e catálogo dependem da API oficial; limites e custos precisam ser confirmados com a Meta ou com o parceiro.
- **Aspectos legais:** avaliar com o jurídico a necessidade de avisar que o atendimento é automatizado, e as regras de autorização (opt-in) para mensagens de marketing.
- **Testes:** os comportamentos novos foram testados localmente com modelo simulado; a validação final é sempre com o Claude real, pela bateria.

---

## 13. Pendências e perguntas em aberto

**Pendências do teste**
- Cadastrar os links das fotos (`foto_url`).
- Confirmar no ambiente do usuário os avisos de cada etapa do rastreio.
- Rodar a bateria completa com o Claude real e comparar esforço e janela de memória.

**Decisões para a próxima fase**
1. ~~Plataforma da loja~~: **Tray** (descoberto na coleta). Gateway visto no site: **Vindi**.
2. A Olden já tem número oficial do WhatsApp (API)? Qual parceiro?
3. Pagamento: checkout da loja (link) ou pagamento dentro do WhatsApp?
4. Escopo da demonstração: quais produtos e quais departamentos?
5. Quem na Olden cuida das vitrines e coleções?
6. Quais métricas definem o sucesso do canal (conversão, ticket, nota, custo por venda)?

---

## 14. Custos (ordem de grandeza, a confirmar)

| Item | Custo |
|---|---|
| Supabase | Plano Free no teste |
| n8n | Self-hosted |
| Claude Haiku 5.5 (OpenRouter) | US$ 0,10 por milhão de tokens de entrada e US$ 0,50 de saída; uma conversa sai por uma fração de centavo |
| Bateria completa de testes | Cerca de US$ 1 (a maior parte é a IA avaliadora) |
| WhatsApp oficial | Respostas a quem chamou a loja normalmente sem custo; mensagens iniciadas pela loja cobradas por mensagem (confirmar tabela da Meta para o Brasil) |
| Parceiro do WhatsApp | Varia conforme o parceiro |

---

## 15. Arquivos do repositório

| Caminho | Conteúdo |
|---|---|
| `supabase/00_instalar_tudo.sql` | Instala todo o banco (01 a 09) |
| `supabase/01` … `09_*.sql` | Etapas do banco, separadas |
| `supabase/atualizar_prompt.sql` | Atualiza o comportamento da Lia |
| `n8n/1-nucleo-agente.json` … `5-whatsapp.json` | Os 5 workflows |
| `n8n/whatsapp/flow-tamanho.json` | Flow "Descubra seu tamanho" para colar no WhatsApp Manager |
| `supabase/14_whatsapp.sql` | Ponte com o WhatsApp (registro, configuração, feed do catálogo, provador) |
| `docs/whatsapp.md` | Passo 1 (contas da Meta) e virada do teste para o WhatsApp |
| `n8n/system-prompt.md` | Cópia de referência do prompt da Lia |
| `n8n/build/` | Geradores dos workflows e dos SQL, e a página de chat |
| `docs/ambiente-de-testes.md` | Guia operacional (instalação, testes, demonstração) |
| `docs/guia-passo-a-passo.md` | Guia da primeira versão (Supabase inicial) |
