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

const request = require('supertest');
const db = require('../src/db');
const envctl = require('../src/envctl');
const app = require('../src/server');

const validBody = {
  name: 'teste',
  cpu_percent: 50,
  memory_mb: 256,
  io_mbps: 10,
  mode: 'cmd',
  command: 'echo ola',
};

beforeEach(() => {
  jest.clearAllMocks();
  db.query.mockResolvedValue([[]]);
});

// C1: POST /api/environments com dados validos (modo cmd) -> 201, linha criada com pid
test('C1 - cria ambiente valido em modo cmd', async () => {
  db.query
    .mockResolvedValueOnce([{ insertId: 42 }]) // INSERT
    .mockResolvedValueOnce([[]]) // UPDATE (ignorado)
    .mockResolvedValueOnce([[{ id: 42, pid: 4821, status: 'running', exit_code: null }]]); // SELECT final
  envctl.create.mockResolvedValueOnce({ id: 42, pid: 4821, status: 'running', exit_code: null });

  const res = await request(app).post('/api/environments').send(validBody);

  expect(res.status).toBe(201);
  expect(res.body.pid).toBe(4821);
  expect(envctl.create).toHaveBeenCalledWith(42, { cpu: 50, mem: 256, io: 10, cmd: 'echo ola' });
});

// C2: cpu_percent fora da faixa -> 400, motor nao e chamado
test.each([0, 150])('C2 - cpu_percent %i invalido retorna 400 sem chamar o motor', async (cpu) => {
  const res = await request(app)
    .post('/api/environments')
    .send({ ...validBody, cpu_percent: cpu });

  expect(res.status).toBe(400);
  expect(envctl.create).not.toHaveBeenCalled();
  expect(db.query).not.toHaveBeenCalled();
});

// C3: command e script_id juntos -> 400
test('C3 - command e script_id juntos retorna 400', async () => {
  const res = await request(app)
    .post('/api/environments')
    .send({ ...validBody, mode: 'script', script_id: 1 });

  expect(res.status).toBe(400);
  expect(envctl.create).not.toHaveBeenCalled();
});

// C4: modo script com script_id inexistente -> 400 ou 404
test('C4 - modo script com script_id inexistente retorna 400', async () => {
  db.query.mockResolvedValueOnce([[]]); // SELECT scripts WHERE id=? -> nao encontrado

  const res = await request(app)
    .post('/api/environments')
    .send({
      name: 'teste',
      cpu_percent: 50,
      memory_mb: 256,
      io_mbps: 10,
      mode: 'script',
      script_id: 999,
    });

  expect([400, 404]).toContain(res.status);
  expect(envctl.create).not.toHaveBeenCalled();
});

// C5: GET /api/environments -> 200, status vindo do envctl list
test('C5 - lista ambientes com status atualizado pelo motor', async () => {
  db.query
    .mockResolvedValueOnce([[{ id: 1, status: 'creating', pid: null, exit_code: null }]]) // SELECT
    .mockResolvedValueOnce([[]]); // UPDATE
  envctl.list.mockResolvedValueOnce([{ id: 1, pid: 123, status: 'running', exit_code: null }]);

  const res = await request(app).get('/api/environments');

  expect(res.status).toBe(200);
  expect(res.body[0].status).toBe('running');
  expect(res.body[0].pid).toBe(123);
});

// C6: GET /api/environments/999 -> 404
test('C6 - ambiente inexistente retorna 404', async () => {
  db.query.mockResolvedValueOnce([[]]);

  const res = await request(app).get('/api/environments/999');

  expect(res.status).toBe(404);
});

// C7: GET /api/environments/:id/logs -> 200, texto do output
test('C7 - retorna o log em texto puro', async () => {
  db.query.mockResolvedValueOnce([[{ id: 1 }]]);
  envctl.logs.mockResolvedValueOnce('linha 1 do output\nlinha 2 do output\n');

  const res = await request(app).get('/api/environments/1/logs');

  expect(res.status).toBe(200);
  expect(res.text).toContain('linha 1 do output');
  expect(res.headers['content-type']).toMatch(/text\/plain/);
});

// C8: POST /api/environments/:id/stop -> 200, status stopped
test('C8 - encerra o ambiente', async () => {
  db.query
    .mockResolvedValueOnce([[{ id: 1 }]]) // existe?
    .mockResolvedValueOnce([[]]) // UPDATE
    .mockResolvedValueOnce([[{ id: 1, status: 'stopped', pid: null, exit_code: null }]]); // SELECT final
  envctl.stop.mockResolvedValueOnce({ id: 1, pid: null, status: 'stopped', exit_code: null });

  const res = await request(app).post('/api/environments/1/stop');

  expect(res.status).toBe(200);
  expect(res.body.status).toBe('stopped');
});

// C9: DELETE /api/environments/:id -> 204
test('C9 - remove o ambiente', async () => {
  db.query
    .mockResolvedValueOnce([[{ id: 1 }]]) // existe?
    .mockResolvedValueOnce([[]]); // DELETE
  envctl.remove.mockResolvedValueOnce({ id: 1, removed: true });

  const res = await request(app).delete('/api/environments/1');

  expect(res.status).toBe(204);
});

// C13: motor retorna exit 4 -> 500 com mensagem, app nao cai
test('C13 - falha interna do motor retorna 500 sem derrubar a app', async () => {
  db.query
    .mockResolvedValueOnce([{ insertId: 7 }]) // INSERT
    .mockResolvedValueOnce([[]]); // UPDATE status='error'
  const err = new Error('falha ao criar cgroup');
  err.exitCode = 4;
  envctl.create.mockRejectedValueOnce(err);

  const res = await request(app).post('/api/environments').send(validBody);

  expect(res.status).toBe(500);
  expect(res.body.error).toBe('falha ao criar cgroup');

  const healthCheck = await request(app).get('/api/environments/404');
  expect(healthCheck.status).not.toBe(500);
});
