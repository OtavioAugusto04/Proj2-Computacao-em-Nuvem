// Unico arquivo que fala com o motor (envctl). O resto da app so chama
// as funcoes exportadas aqui. Se o contrato da secao 5 mudar, só este
// arquivo precisa mudar.
const { execFile } = require('child_process');

const TIMEOUT_MS = 10000;

class EnvctlError extends Error {
  constructor(message, exitCode) {
    super(message);
    this.name = 'EnvctlError';
    this.exitCode = exitCode;
  }
}

function envctlPath() {
  return process.env.ENVCTL_PATH || '/usr/local/bin/envctl';
}

function useSudo() {
  return String(process.env.ENVCTL_SUDO ?? 'true').toLowerCase() === 'true';
}

function run(args) {
  const cmd = useSudo() ? 'sudo' : envctlPath();
  const cmdArgs = useSudo() ? [envctlPath(), ...args] : args;

  return new Promise((resolve) => {
    execFile(cmd, cmdArgs, { timeout: TIMEOUT_MS }, (error, stdout) => {
      resolve({ exitCode: error ? (error.code ?? 4) : 0, stdout: stdout || '' });
    });
  });
}

function parseJsonOrThrow(stdout, fallbackExitCode) {
  try {
    return JSON.parse(stdout);
  } catch {
    throw new EnvctlError('resposta invalida do motor', fallbackExitCode || 4);
  }
}

async function callJson(args) {
  const { exitCode, stdout } = await run(args);
  const data = parseJsonOrThrow(stdout, exitCode || 4);
  if (exitCode !== 0) {
    throw new EnvctlError(data.error || 'erro desconhecido do motor', exitCode);
  }
  return data;
}

async function create(id, { cpu, mem, io, cmd, script }) {
  const args = ['create', String(id), '--cpu', String(cpu), '--mem', String(mem), '--io', String(io)];
  args.push(cmd !== undefined ? '--cmd' : '--script', cmd !== undefined ? cmd : script);
  return callJson(args);
}

async function status(id) {
  return callJson(['status', String(id)]);
}

async function list() {
  return callJson(['list']);
}

async function stop(id) {
  return callJson(['stop', String(id)]);
}

async function remove(id) {
  return callJson(['remove', String(id)]);
}

async function logs(id, tail) {
  const args = ['logs', String(id)];
  if (tail !== undefined && tail !== null && !Number.isNaN(tail)) {
    args.push('--tail', String(tail));
  }
  const { exitCode, stdout } = await run(args);
  if (exitCode !== 0) {
    let message = 'erro ao obter logs do ambiente';
    try {
      message = JSON.parse(stdout).error || message;
    } catch {
      // stdout nao era JSON; mantem mensagem padrao
    }
    throw new EnvctlError(message, exitCode);
  }
  return stdout;
}

module.exports = { create, status, list, stop, remove, logs, EnvctlError };
