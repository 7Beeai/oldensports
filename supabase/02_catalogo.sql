-- =====================================================================
-- Olden Sports - 02_catalogo.sql: carga dos 8 produtos e do estoque
-- Rode depois do 01_schema.sql. Pode rodar de novo: atualiza os dados.
-- Estoque de teste: 8 unidades de cada tamanho.
-- =====================================================================

insert into produtos (sku, nome, categoria, publico, descricao, caracteristicas, medidas, preco, preco_original, preco_pix) values

('CEL-BR', 'Camisa Palmeiras Palestra Celebration - Masculino', 'Camisa', 'Masculino',
 'Camisa branca que combina tradição, elegância e conforto. Finas listras verticais verdes na frente, escudo bordado no peito, gola V com acabamento interno cinza prateado e acabamentos verdes nas mangas e nas laterais. Tecido leve, resistente e respirável, para usar dentro e fora do estádio.',
 'Material 100% poliéster | escudo bordado no peito | gola V com acabamento interno cinza prateado | listras verticais verdes na frente | painéis laterais verdes.',
 'P 66x51 cm | M 70x54 cm | G 73x58 cm | GG 76x61 cm',
 169.90, null, 161.41),

('LENCO-CB', 'Lenço Palmeiras Campeão do Brasil', 'Acessório', 'Unissex',
 'Bandana em verde e branco com a frase “O Maior Campeão do Brasil” e detalhes ornamentais. Tecido acetinado, toque macio e brilho elegante. Versátil: pode ser usada como cropped ou top, na cabeça (lenço, faixa ou bandana), no pescoço, na cintura como cinto, amarrada na alça da bolsa ou como bandeira decorativa.',
 'Estampa “O Maior Campeão do Brasil” | tecido acetinado | verde com detalhes em branco | toque suave e brilho acetinado | estilo casual, esportivo e fashion.',
 null,
 199.90, null, 189.91),

('TECH-AZ', 'Camisa Palmeiras Individual 1914 Tech Azul - Masculino', 'Camisa polo', 'Masculino',
 'Camisa polo masculina Tech azul, de design minimalista e acabamento premium. Tecido tecnológico macio, leve e elástico, que acompanha os movimentos. Gola polo com botões e logo estampado discretamente no peito. Boa para o dia a dia, passeios e ocasiões casuais.',
 'Composição 77% poliamida e 23% elastano | tecido Tech leve, macio e confortável | gola polo com fechamento em botões | logo estampado no peito | estilo casual, esportivo e sofisticado.',
 'P 66x52 cm | M 69x53 cm | G 70x58 cm | GG 71x61 cm',
 399.90, null, 379.91),

('TECH-VD', 'Camisa Palmeiras Individual 1914 Tech Verde - Masculino', 'Camisa polo', 'Masculino',
 'Camisa polo masculina Tech verde, de design minimalista e acabamento premium. Tecido tecnológico macio, leve e elástico, que acompanha os movimentos. Gola polo com botões e logo estampado discretamente no peito. Boa para o dia a dia, passeios e ocasiões casuais.',
 'Composição 77% poliamida e 23% elastano | tecido Tech leve, macio e confortável | gola polo com fechamento em botões | logo estampado no peito | estilo casual, esportivo e sofisticado.',
 'P 66x52 cm | M 69x53 cm | G 70x58 cm | GG 71x61 cm',
 399.90, null, 379.91),

('VEST-OW', 'Vestido Palmeiras Individual 1914 Off White - Infantil', 'Vestido', 'Infantil',
 'Vestido polo infantil off-white, clássico e delicado, para as pequenas torcedoras. Algodão macio e confortável. Gola polo verde-escura com botões, detalhes verdes nas laterais e nas cavas, letra “P” do Palestra bordada no peito. Sem mangas, saia levemente evasê.',
 'Modelo vestido polo infantil | algodão | gola polo com abertura frontal de botões | letra P bordada no peito | acabamentos verdes nas laterais e nas cavas.',
 'Tamanhos 4 a 8: 59x27 cm | tamanhos 10 a 12: 69x33 cm',
 189.90, null, 180.41),

('POLO-VD', 'Camisa Palmeiras Polo 1914 Palestra Verde - Masculino', 'Camisa polo', 'Masculino',
 'Polo verde usada pelo técnico Abel Ferreira. Algodão premium macio e respirável, gola polo com zíper e a letra “P” histórica do Palestra bordada no lado esquerdo do peito. Produto oficial licenciado Palmeiras.',
 'Composição 97% algodão premium e 3% elastano | escudo bordado | manga curta | gola polo com zíper | produto oficial licenciado.',
 'P 70x51 cm | M 72x54 cm | G 74x57 cm | GG 76x60 cm | XGG 78x63 cm',
 259.90, null, 246.91),

('BODY-AZ', 'Body Palmeiras Torcida Baby 2026 Jogo 3 Oficial', 'Body', 'Bebê',
 'Body infantil para os pequenos torcedores começarem desde cedo a demonstrar a paixão pelo Verdão. Confortável, prático e com visual inspirado no clube, ótimo para o dia a dia, passeios ou para presentear. Tecido leve, mangas curtas, gola em V, acabamento branco na parte inferior e fechamento por botões de pressão, que facilitam a troca do bebê. Na frente, o escudo em evidência acompanhado de detalhes especiais para a nova geração de torcedores.',
 'Gola V | fechamento inferior com botões de pressão | composição 100% poliéster | leve, confortável e prático para o dia a dia. Cuidados: por ter mais de uma cor, não deixar de molho, não usar alvejante e evitar excesso de sabão. Após lavar, centrifugar ou torcer bem antes de secar.',
 'Tamanho único, padrão para bebês de 9 meses',
 149.90, null, 142.41),

('BLOOK-BR', 'Camisa Palmeiras Baby Look 1914 Símbolo Branca - Feminina', 'Camisa', 'Feminino',
 'Baby look branca para as palestrinas usarem no dia a dia. Nome Palmeiras com efeito emboss na gola, escudo estampado no peito e o ano de fundação estampado na lateral. Produto oficial licenciado Palmeiras.',
 'Material 100% poliéster | escudo estampado | gola careca | manga curta | produto oficial licenciado.',
 'P 58x42 cm | M 60x44 cm | G 62x46 cm | GG 66x56 cm',
 45.90, 119.90, 43.61)

on conflict (sku) do update set
  nome = excluded.nome, categoria = excluded.categoria, publico = excluded.publico,
  descricao = excluded.descricao, caracteristicas = excluded.caracteristicas,
  medidas = excluded.medidas, preco = excluded.preco,
  preco_original = excluded.preco_original, preco_pix = excluded.preco_pix,
  ativo = true;

insert into estoque (sku, tamanho, ordem, quantidade)
select v.sku, v.tamanho, v.ordem, 8
from (values
  ('CEL-BR','P',1),('CEL-BR','M',2),('CEL-BR','G',3),('CEL-BR','GG',4),
  ('LENCO-CB','ÚNICO',1),
  ('TECH-AZ','P',1),('TECH-AZ','M',2),('TECH-AZ','G',3),('TECH-AZ','GG',4),
  ('TECH-VD','P',1),('TECH-VD','M',2),('TECH-VD','G',3),('TECH-VD','GG',4),
  ('VEST-OW','4',1),('VEST-OW','6',2),('VEST-OW','8',3),('VEST-OW','10',4),('VEST-OW','12',5),
  ('POLO-VD','P',1),('POLO-VD','M',2),('POLO-VD','G',3),('POLO-VD','GG',4),('POLO-VD','XGG',5),
  ('BODY-AZ','9 MESES',1),
  ('BLOOK-BR','P',1),('BLOOK-BR','M',2),('BLOOK-BR','G',3),('BLOOK-BR','GG',4)
) as v(sku, tamanho, ordem)
on conflict (sku, tamanho) do update set quantidade = 8, ordem = excluded.ordem;

-- Remove tamanhos provisórios antigos do Body, se existirem
delete from estoque where sku = 'BODY-AZ' and tamanho <> '9 MESES';
