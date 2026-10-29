const express = require('express');
const db = require('../db');
const envctl = require('../envctl');
const httpFromExitCode = require('../httpFromExitCode');

const router = express.Router();

const LIMITS = {
  cpu_percent: { min: 1, max: 100 },
  memory_mb: { min: 32, max: 2048 },
  io_mbps: { min: 1, max: 500 },
};

function toValidatedInt(value, { min, max }) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || n > max) return null;
  return n;
}

function validateCreateBody(body) {
  const errors = [];
  const { name, mode, command, script_id } = body;

  if (!name || typeof name !== 'string' || !name.trim()) {
    errors.push('name é obrigatório');
  }

  const cpu = toValidatedInt(body.cpu_percent, LIMITS.cpu_percent);
  if (cpu === null) {
    errors.push(`cpu_percent deve ser um inteiro entre ${LIMITS.cpu_percent.min} e ${LIMITS.cpu_percent.max}`);
  }

  const mem = toValidatedInt(body.memory_mb, LIMITS.memory_mb);
  if (mem === null) {
    errors.push(`memory_mb deve ser um inteiro entre ${LIMITS.memory_mb.min} e ${LIMITS.memory_mb.max}`);
  }

  const io = toValidatedInt(body.io_mbps, LIMITS.io_mbps);
  if (io === null) {
    errors.push(`io_mbps deve ser um inteiro entre ${LIMITS.io_mbps.min} e ${LIMITS.io_mbps.max}`);
  }

  if (mode !== 'cmd' && mode !== 'script') {
    errors.push('mode deve ser "cmd" ou "script"');
  }

  const hasCommand = typeof command === 'string' && command.trim() !== '';
  const hasScript = script_id !== undefined && script_id !== null && String(script_id).trim() !== '';

  if (hasCommand && hasScript) {
    errors.push('command e script_id são mutuamente exclusivos');
  } else if (!hasCommand && !hasScript) {
    errors.push('é necessário informar command ou script_id');
  } else if (mode === 'cmd' && !hasCommand) {
    errors.push('mode "cmd" requer command');
  } else if (mode === 'script' && !hasScript) {
    errors.push('mode "script" requer script_id');
  }

  return { errors, cpu, mem, io, hasCommand, hasScript };
}

router.get('/', async (req, res, next) => {
  try {
    const [rows] = await db.query('SELECT * FROM environments ORDER BY id DESC');

    let liveList = [];
    try {
      liveList = await envctl.list();
    } catch {
      liveList = [];
    }
    const liveById = new Map(liveList.map((e) => [Number(e.id), e]));

    for (const row of rows) {
      const live = liveById.get(row.id);
      if (live && (live.status !== row.status || live.pid !== row.pid || live.exit_code !== row.exit_code)) {
        await db.query('UPDATE environments SET status=?, pid=?, exit_code=? WHERE id=?', [
          live.status,
          live.pid,
          live.exit_code,
          row.id,
        ]);
        row.status = live.status;
        row.pid = live.pid;
        row.exit_code = live.exit_code;
      }
    }

    res.json(rows);
  } catch (err) {
    next(err);
  }
});

router.post('/', async (req, res, next) => {
  try {
    const { errors, cpu, mem, io } = validateCreateBody(req.body);
    if (errors.length) {
      return res.status(400).json({ error: errors.join('; ') });
    }

    const { name, mode, command, script_id } = req.body;
    let scriptPath = null;
    let scriptIdNum = null;

    if (mode === 'script') {
      scriptIdNum = Number(script_id);
      const [scripts] = await db.query('SELECT * FROM scripts WHERE id=?', [scriptIdNum]);
      if (!scripts.length) {
        return res.status(400).json({ error: 'script_id inexistente' });
      }
      scriptPath = `${process.env.SCRIPTS_DIR}/${scripts[0].filename}`;
    }

    const [result] = await db.query(
      `INSERT INTO environments (name, cpu_percent, memory_mb, io_mbps, mode, command, script_id, status)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'creating')`,
      [name.trim(), cpu, mem, io, mode, mode === 'cmd' ? command : null, mode === 'script' ? scriptIdNum : null]
    );
    const id = result.insertId;

    try {
      const created =
        mode === 'cmd'
          ? await envctl.create(id, { cpu, mem, io, cmd: command })
          : await envctl.create(id, { cpu, mem, io, script: scriptPath });

      await db.query('UPDATE environments SET pid=?, status=?, exit_code=? WHERE id=?', [
        created.pid,
        created.status,
        created.exit_code,
        id,
      ]);
      const [rows] = await db.query('SELECT * FROM environments WHERE id=?', [id]);
      return res.status(201).json(rows[0]);
    } catch (err) {
      await db.query("UPDATE environments SET status='error' WHERE id=?", [id]);
      return res.status(httpFromExitCode(err.exitCode)).json({ error: err.message });
    }
  } catch (err) {
    next(err);
  }
});

router.get('/:id', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    const [rows] = await db.query('SELECT * FROM environments WHERE id=?', [id]);
    if (!rows.length) {
      return res.status(404).json({ error: 'ambiente não encontrado' });
    }
    const row = rows[0];

    try {
      const live = await envctl.status(id);
      if (live.status !== row.status || live.pid !== row.pid || live.exit_code !== row.exit_code) {
        await db.query('UPDATE environments SET status=?, pid=?, exit_code=? WHERE id=?', [
          live.status,
          live.pid,
          live.exit_code,
          id,
        ]);
        row.status = live.status;
        row.pid = live.pid;
        row.exit_code = live.exit_code;
      }
    } catch {
      // motor pode ja ter removido o ambiente; mantem o ultimo estado conhecido no banco
    }

    res.json(row);
  } catch (err) {
    next(err);
  }
});

router.get('/:id/logs', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    const [rows] = await db.query('SELECT id FROM environments WHERE id=?', [id]);
    if (!rows.length) {
      return res.status(404).json({ error: 'ambiente não encontrado' });
    }

    const tail = req.query.tail !== undefined ? Number(req.query.tail) : undefined;

    try {
      const output = await envctl.logs(id, tail);
      res.type('text/plain').send(output);
    } catch (err) {
      res.status(httpFromExitCode(err.exitCode)).json({ error: err.message });
    }
  } catch (err) {
    next(err);
  }
});

router.post('/:id/stop', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    const [rows] = await db.query('SELECT id FROM environments WHERE id=?', [id]);
    if (!rows.length) {
      return res.status(404).json({ error: 'ambiente não encontrado' });
    }

    try {
      const result = await envctl.stop(id);
      await db.query('UPDATE environments SET status=?, pid=?, exit_code=? WHERE id=?', [
        result.status,
        result.pid,
        result.exit_code,
        id,
      ]);
      const [updated] = await db.query('SELECT * FROM environments WHERE id=?', [id]);
      res.json(updated[0]);
    } catch (err) {
      res.status(httpFromExitCode(err.exitCode)).json({ error: err.message });
    }
  } catch (err) {
    next(err);
  }
});

router.delete('/:id', async (req, res, next) => {
  try {
    const id = Number(req.params.id);
    const [rows] = await db.query('SELECT id FROM environments WHERE id=?', [id]);
    if (!rows.length) {
      return res.status(404).json({ error: 'ambiente não encontrado' });
    }

    try {
      await envctl.remove(id);
    } catch (err) {
      if (err.exitCode !== 2) {
        return res.status(httpFromExitCode(err.exitCode)).json({ error: err.message });
      }
      // exitCode 2: motor ja nao conhece o ambiente, segue removendo do banco
    }

    await db.query('DELETE FROM environments WHERE id=?', [id]);
    res.status(204).end();
  } catch (err) {
    next(err);
  }
});

module.exports = router;
