require('dotenv').config();

const express = require('express');
const path = require('path');
const environmentsRouter = require('./routes/environments');
const scriptsRouter = require('./routes/scripts');

const app = express();

app.use(express.json());
app.use(express.static(path.join(__dirname, '..', 'public')));

app.use('/api/environments', environmentsRouter);
app.use('/api/scripts', scriptsRouter);

app.use((req, res) => {
  res.status(404).json({ error: 'rota não encontrada' });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'erro interno do servidor' });
});

if (require.main === module) {
  const PORT = process.env.PORT || 3000;
  const HOST = process.env.HOST || '127.0.0.1';
  app.listen(PORT, HOST, () => {
    console.log(`Servidor rodando em http://${HOST}:${PORT}`);
  });
}

module.exports = app;
