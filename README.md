# oldensports

Agente de atendimento da Olden Sports (n8n + Supabase + Claude Haiku 5.5 via OpenRouter).

- **Guia atual:** [docs/ambiente-de-testes.md](docs/ambiente-de-testes.md): chat de demonstração, bateria de testes e variáveis do agente
- Guia inicial (Supabase e primeira versão): [docs/guia-passo-a-passo.md](docs/guia-passo-a-passo.md)
- Banco: `supabase/01_schema.sql`, `02_catalogo.sql`, `03_atualiza_body.sql`, `04_ambiente_testes.sql`, `05_fotos.sql`, `06_pagamento_rastreio_teste.sql`
- Workflows do n8n: `n8n/1-nucleo-agente.json`, `n8n/2-chat-demo.json`, `n8n/3-bateria-testes.json`, `n8n/4-pagamento-rastreio-teste.json`
- Prompt do agente: `n8n/system-prompt.md` (regere os workflows com `node n8n/build/gerar-workflows.js`)
