// Tabela da secao 5.5 do README: traduz o exit code do envctl em status HTTP.
const EXIT_CODE_TO_HTTP = {
  1: 400, // argumento invalido
  2: 404, // ambiente nao existe
  3: 409, // ambiente ja existe
  4: 500, // falha interna
};

module.exports = function httpFromExitCode(exitCode) {
  return EXIT_CODE_TO_HTTP[exitCode] || 500;
};
