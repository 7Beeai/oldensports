# oldensports

Agente de atendimento da Olden Sports (n8n + Supabase + Claude Haiku 5.5 via OpenRouter).

- **Guia atual:** [docs/ambiente-de-testes.md](docs/ambiente-de-testes.md): chat de demonstração, bateria de testes e variáveis do agente
- Guia inicial (Supabase e primeira versão): [docs/guia-passo-a-passo.md](docs/guia-passo-a-passo.md)
- Banco: **`supabase/00_instalar_tudo.sql` instala tudo de uma vez** (junta os arquivos 01 a 09: `supabase/01_schema.sql`, `02_catalogo.sql`, `03_atualiza_body.sql`, `04_ambiente_testes.sql`, `05_fotos.sql`, `06_pagamento_rastreio_teste.sql`, `07_mensagens_proativas.sql`, `08_prompt_no_banco.sql`, `09_avisos_rastreio.sql`)
- Workflows do n8n: `n8n/1-nucleo-agente.json`, `n8n/2-chat-demo.json`, `n8n/3-bateria-testes.json`, `n8n/4-pagamento-rastreio-teste.json`
- Prompt da Lia: fica no Supabase (tabela `prompt_agente`); a cópia de referência é `n8n/system-prompt.md`. Para gerar o SQL de atualização: `node n8n/build/gerar-sql.js "descrição"`
