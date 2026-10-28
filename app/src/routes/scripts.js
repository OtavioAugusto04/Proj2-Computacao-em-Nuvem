const express = require('express');
const multer = require('multer');
const fs = require('fs');
const path = require('path');
const db = require('../db');

const router = express.Router();

const MAX_SIZE_BYTES = 1 * 1024 * 1024; // 1 MB
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: MAX_SIZE_BYTES } });

function uploadSingle(req, res, next) {
  upload.single('file')(req, res, (err) => {
    if (err) {
      if (err.code === 'LIMIT_FILE_SIZE') {
        return res.status(413).json({ error: 'arquivo excede o tamanho máximo permitido (1 MB)' });
      }
      return res.status(400).json({ error: err.message });
    }
    next();
  });
}

function scriptsDir() {
  return process.env.SCRIPTS_DIR;
}

router.get('/', async (req, res, next) => {
  try {
    const [rows] = await db.query(
      'SELECT id, name, filename, description, created_at FROM scripts ORDER BY id DESC'
    );
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

router.post('/', uploadSingle, async (req, res, next) => {
  try {
    const { name, description } = req.body;
    if (!name || !name.trim()) {
      return res.status(400).json({ error: 'name é obrigatório' });
    }
    if (!req.file || !req.file.buffer || !req.file.buffer.length) {
      return res.status(400).json({ error: 'arquivo é obrigatório' });
    }

    // nome gravado no banco e usado como caminho e sempre "<id>.sh"; o nome
    // enviado pelo usuario nunca e usado para montar um caminho no disco.
    const [result] = await db.query('INSERT INTO scripts (name, filename, description) VALUES (?, ?, ?)', [
      name.trim(),
      'pending',
      description && description.trim() ? description.trim() : null,
    ]);
    const id = result.insertId;
    const filename = `${id}.sh`;

    await fs.promises.mkdir(scriptsDir(), { recursive: true });
    await fs.promises.writeFile(path.join(scriptsDir(), filename), req.file.buffer, { mode: 0o750 });
    await db.query('UPDATE scripts SET filename=? WHERE id=?', [filename, id]);

    const [rows] = await db.query(
      'SELECT id, name, filename, description, created_at FROM scripts WHERE id=?',
      [id]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    next(err);
  }
});

router.get('/:id', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    const [rows] = await db.query('SELECT * FROM scripts WHERE id=?', [id]);
    if (!rows.length) {
      return res.status(404).json({ error: 'script não encontrado' });
    }
    const script = rows[0];

    let content = '';
    try {
      content = await fs.promises.readFile(path.join(scriptsDir(), script.filename), 'utf8');
    } catch {
      content = '';
    }

    res.json({ ...script, content });
  } catch (err) {
    next(err);
  }
});

router.delete('/:id', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    const [rows] = await db.query('SELECT * FROM scripts WHERE id=?', [id]);
    if (!rows.length) {
      return res.status(404).json({ error: 'script não encontrado' });
    }

    const [usedBy] = await db.query('SELECT id FROM environments WHERE script_id=?', [id]);
    if (usedBy.length) {
      return res.status(409).json({ error: 'script em uso por um ou mais ambientes' });
    }

    const script = rows[0];
    await fs.promises.unlink(path.join(scriptsDir(), script.filename)).catch(() => {});
    await db.query('DELETE FROM scripts WHERE id=?', [id]);
    res.status(204).end();
  } catch (err) {
    next(err);
  }
});

module.exports = router;
