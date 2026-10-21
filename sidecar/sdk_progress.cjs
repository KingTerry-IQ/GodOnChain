// Solana's writeRow uploads through prepareCodeIn, and readTableRows walks
// signatures through readCodeIn. Both report a chunk percent, and neither
// public call forwards it. These are the same exports the SDK calls, so
// replacing them is enough. A plain require is what the bundler dedupes
// onto that object. createRequire(import.meta.url) stays a runtime require
// and patches a second copy the writer never sees.
const { AsyncLocalStorage } = require("node:async_hooks");
const upload = require("./node_modules/@iqlabs-official/solana-sdk/dist/sdk/writer/code_in.js");
const reader = require("./node_modules/@iqlabs-official/solana-sdk/dist/sdk/reader/read_code_in.js");
const readerUtils = require("./node_modules/@iqlabs-official/solana-sdk/dist/sdk/reader/reader_utils.js");

const writeReport = new AsyncLocalStorage();
const readMeter = new AsyncLocalStorage();

const clamp = (percent) => Math.max(0, Math.min(100, Number(percent) || 0));

const originalPrepare = upload.prepareCodeIn;
upload.prepareCodeIn = function arkSolanaPrepare(input, data, filename, method, filetype, onProgress, speed) {
  const report = onProgress ?? writeReport.getStore();
  return originalPrepare(input, data, filename, method, filetype, report, speed);
};

const originalFetch = readerUtils.fetchAccountTransactions;
readerUtils.fetchAccountTransactions = async function arkSolanaSignatures(account, options) {
  const rows = await originalFetch(account, options);
  const meter = readMeter.getStore();
  // The first page is the row list. A later fetch in the same read is a
  // chunk walk and must not replace that count.
  if (meter && meter.total === 0 && Array.isArray(rows) && rows.length > 0) {
    meter.total = rows.length;
  }
  return rows;
};

const originalRead = reader.readCodeIn;
reader.readCodeIn = async function arkSolanaRead(signature, speed, onProgress) {
  const meter = readMeter.getStore();
  const report = onProgress ?? (meter
    ? (percent) => {
        const inner = clamp(percent);
        if (meter.total > 0) meter.report(((meter.done + inner / 100) / meter.total) * 100);
        else meter.report(inner);
      }
    : undefined);
  try {
    return await originalRead(signature, speed, report);
  } finally {
    if (meter && !onProgress) {
      meter.done += 1;
      if (meter.total > 0) meter.report((meter.done / meter.total) * 100);
    }
  }
};

function withSolanaWriteProgress(report, work) {
  return writeReport.run(report, work);
}

function withSolanaReadProgress(report, work, expected = 0) {
  return readMeter.run({ total: expected > 0 ? expected : 0, done: 0, report }, work);
}

function resetSolanaRead(count) {
  const meter = readMeter.getStore();
  if (!meter || !(count > 0)) return;
  meter.done = 0;
  meter.total = count;
}

// The tolerant collector does not walk every signature through readCodeIn.
// Pinning the finished count keeps the bar on the signature list anyway.
function pinSolanaRead(count) {
  const meter = readMeter.getStore();
  if (!meter || !(count >= 0)) return;
  meter.done = count;
  if (meter.total > 0) meter.report((count / meter.total) * 100);
}

// Monad and Robinhood read a table by walking a linked list. The SDK reports
// count/(count+1) while a read chain's length is still unknown, and
// readTableRows never forwards it. The walk calls provider.getTransaction,
// so counting those calls is the same fraction.
const evmRead = new AsyncLocalStorage();

function watchEvmProvider(provider) {
  if (!provider || typeof provider.getTransaction !== "function") return;
  if (provider.getTransaction.arkEvmRead) return;
  const original = provider.getTransaction.bind(provider);
  const wrapped = async function arkEvmGetTransaction(...args) {
    const tx = await original(...args);
    const meter = evmRead.getStore();
    if (meter) {
      meter.fetched += 1;
      meter.report((meter.fetched / (meter.fetched + 1)) * 100);
    }
    return tx;
  };
  wrapped.arkEvmRead = true;
  provider.getTransaction = wrapped;
}

function withEvmReadProgress(report, work, provider) {
  const target = provider ?? require("./node_modules/@iqlabs-official/ethereum-sdk/dist/esm/sdk/utils/provider.js").getProvider();
  watchEvmProvider(target);
  return evmRead.run({ fetched: 0, report }, work);
}

module.exports = {
  withSolanaWriteProgress,
  withSolanaReadProgress,
  resetSolanaRead,
  pinSolanaRead,
  watchEvmProvider,
  withEvmReadProgress,
};
