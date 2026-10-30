process.env.SCRIPTS_DIR = './tmp/scripts';

jest.mock('../src/db', () => ({ query: jest.fn() }));
jest.mock('../src/envctl', () => ({
  create: jest.fn(),
  status: jest.fn(),
  list: jest.fn(),
  stop: jest.fn(),
  remove: jest.fn(),
  logs: jest.fn(),
}));

const fs = require('fs');
const path = require('path');
const request = require('supertest');
const db = require('../src/db');
const app = require('../src/server');

beforeEach(() => {
  jest.clearAllMocks();
  db.query.mockResolvedValue([[]]);
});

afterAll(async () => {
  await fs.promises.rm(path.join(__dirname, '..', 'tmp'), { recursive: true, force: true });
});

// C10: POST /api/scripts com arquivo -> 201, arquivo em SCRIPTS_DIR, linha no banco
test('C10 - envia um script com sucesso', async () => {
  db.query
    .mockResolvedValueOnce([{ insertId: 5 }]) // INSERT
    .mockResolvedValueOnce([[]]) // UPDATE filename
    .mockResolvedValueOnce([[{ id: 5, name: 'meu script', filename: '5.sh', description: null }]]); // SELECT final

  const res = await request(app)
    .post('/api/scripts')
    .field('name', 'meu script')
    .attach('file', Buffer.from('#!/bin/bash\necho ola\n'), 'original.sh');

  expect(res.status).toBe(201);
  expect(res.body.filename).toBe('5.sh');

  const saved = await fs.promises.readFile(path.join(__dirname, '..', 'tmp', 'scripts', '5.sh'), 'utf8');
  expect(saved).toContain('echo ola');
});

// C11: POST /api/scripts sem arquivo -> 400
test('C11 - upload sem arquivo retorna 400', async () => {
  const res = await request(app).post('/api/scripts').field('name', 'sem arquivo');

  expect(res.status).toBe(400);
});

// C11: arquivo grande demais -> 413
test('C11 - arquivo maior que 1MB retorna 413', async () => {
  const bigBuffer = Buffer.alloc(2 * 1024 * 1024, 'a');

  const res = await request(app)
    .post('/api/scripts')
    .field('name', 'grande')
    .attach('file', bigBuffer, 'grande.sh');

  expect(res.status).toBe(413);
});

// C12: DELETE /api/scripts/:id usado por um ambiente -> 409
test('C12 - remover script em uso retorna 409', async () => {
  db.query
    .mockResolvedValueOnce([[{ id: 3, filename: '3.sh' }]]) // SELECT script
    .mockResolvedValueOnce([[{ id: 10 }]]); // SELECT environments usando o script

  const res = await request(app).delete('/api/scripts/3');

  expect(res.status).toBe(409);
});

// C14: nome de arquivo malicioso no upload -> salvo como <id>.sh, nada fora de SCRIPTS_DIR
test('C14 - nome de arquivo malicioso e sempre salvo como <id>.sh', async () => {
  db.query
    .mockResolvedValueOnce([{ insertId: 9 }])
    .mockResolvedValueOnce([[]])
    .mockResolvedValueOnce([[{ id: 9, name: 'malicioso', filename: '9.sh', description: null }]]);

  const res = await request(app)
    .post('/api/scripts')
    .field('name', 'malicioso')
    .attach('file', Buffer.from('echo hi'), '../../etc/passwd');

  expect(res.status).toBe(201);
  expect(res.body.filename).toBe('9.sh');

  const scriptsDir = path.join(__dirname, '..', 'tmp', 'scripts');
  const files = await fs.promises.readdir(scriptsDir);
  expect(files).toContain('9.sh');
  expect(files.some((f) => f.includes('..') || f.includes('passwd'))).toBe(false);

  const outside = await fs.promises
    .access(path.join(__dirname, '..', '..', 'etc', 'passwd'))
    .then(() => true)
    .catch(() => false);
  expect(outside).toBe(false);
});
