-- Atualiza só a descrição do Body (não mexe no estoque nem nos dados de teste)
update produtos set
  descricao = 'Body infantil para os pequenos torcedores começarem desde cedo a demonstrar a paixão pelo Verdão. Confortável, prático e com visual inspirado no clube, ótimo para o dia a dia, passeios ou para presentear. Tecido leve, mangas curtas, gola em V, acabamento branco na parte inferior e fechamento por botões de pressão, que facilitam a troca do bebê. Na frente, o escudo em evidência acompanhado de detalhes especiais para a nova geração de torcedores.',
  caracteristicas = 'Gola V | fechamento inferior com botões de pressão | composição 100% poliéster | leve, confortável e prático para o dia a dia. Cuidados: por ter mais de uma cor, não deixar de molho, não usar alvejante e evitar excesso de sabão. Após lavar, centrifugar ou torcer bem antes de secar.'
where sku = 'BODY-AZ';
