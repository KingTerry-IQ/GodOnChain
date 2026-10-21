// The Solana progress patch, against the real SDK exports, with the network
// calls replaced. Nothing here writes or reads a chain.
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const require = createRequire(join(root, "package.json"));
const upload = require("./node_modules/@iqlabs-official/solana-sdk/dist/sdk/writer/code_in.js");
const reader = require("./node_modules/@iqlabs-official/solana-sdk/dist/sdk/reader/read_code_in.js");
const readerUtils = require("./node_modules/@iqlabs-official/solana-sdk/dist/sdk/reader/reader_utils.js");

upload.prepareCodeIn = async function spyPrepare(_input, data, _filename, _method, _filetype, onProgress) {
  if (typeof onProgress === "function") onProgress(Number(data) || 40);
  return "ok";
};
async function spyFetch() {
  return spyFetch.rows;
}
spyFetch.rows = [];
readerUtils.fetchAccountTransactions = spyFetch;
async function spyRead(_signature, _speed, onProgress) {
  if (typeof onProgress === "function") {
    onProgress(50);
    onProgress(100);
  }
  if (spyRead.after) await spyRead.after();
  return { data: "{}" };
}
spyRead.after = null;
reader.readCodeIn = spyRead;

const {
  pinSolanaRead,
  resetSolanaRead,
  withEvmReadProgress,
  withSolanaReadProgress,
  withSolanaWriteProgress,
} = await import("../sdk_progress.cjs");

const failures = [];
const check = (name, ok) => {
  if (!ok) failures.push(name);
  console.log(`${ok ? "ok" : "FAIL"}  ${name}`);
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const written = [];
await withSolanaWriteProgress((percent) => written.push(percent), () =>
  upload.prepareCodeIn({}, "0"),
);
check("a solana write reports the sdk chunk percent", same(written, [40]));

const explicit = [];
const leaked = [];
await withSolanaWriteProgress((percent) => leaked.push(percent), () =>
  upload.prepareCodeIn({}, "7", "f", 0, "", (percent) => explicit.push(percent)),
);
check(
  "an explicit progress callback stays on its own call",
  same(explicit, [7]) && leaked.length === 0,
);

const left = [];
const right = [];
await Promise.all([
  withSolanaWriteProgress((percent) => left.push(percent), async () => {
    await new Promise((resolve) => setTimeout(resolve, 20));
    return upload.prepareCodeIn({}, "11");
  }),
  withSolanaWriteProgress((percent) => right.push(percent), () =>
    upload.prepareCodeIn({}, "22"),
  ),
]);
check("overlapping writes keep their own percent", same(left, [11]) && same(right, [22]));

spyFetch.rows = [{ signature: "a" }, { signature: "b" }];
const read = [];
await withSolanaReadProgress((percent) => read.push(percent), async () => {
  const signatures = await readerUtils.fetchAccountTransactions("table", {});
  for (const row of signatures) await reader.readCodeIn(row.signature, "light");
});
check(
  "a table read blends chunk percent across the signature list",
  same(read, [25, 50, 50, 75, 100, 100]),
);

const pinnedFirst = [];
spyFetch.rows = [{ signature: "a" }, { signature: "b" }, { signature: "c" }, { signature: "d" }];
await withSolanaReadProgress((percent) => pinnedFirst.push(percent), async () => {
  await readerUtils.fetchAccountTransactions("table", {});
  spyFetch.rows = [{ signature: "inner" }];
  spyRead.after = () => readerUtils.fetchAccountTransactions("inner", {});
  await reader.readCodeIn("a", "light");
});
spyRead.after = null;
check(
  "a later signature fetch does not replace the row count",
  pinnedFirst[0] === 12.5 && pinnedFirst[pinnedFirst.length - 1] === 25,
);

const preloaded = [];
await withSolanaReadProgress(
  (percent) => preloaded.push(percent),
  () => reader.readCodeIn("already", "light"),
  4,
);
check("a preloaded signature list is the denominator", preloaded[0] === 12.5 && preloaded.at(-1) === 25);

const walked = [];
await withSolanaReadProgress((percent) => walked.push(percent), async () => {
  resetSolanaRead(4);
  pinSolanaRead(1);
  pinSolanaRead(3);
});
check("a salvage walk reports how far it is through the signatures", same(walked, [25, 75]));

const evmSeen = [];
const evmProvider = {
  async getTransaction() {
    return { hash: "0x1" };
  },
};
await withEvmReadProgress((percent) => evmSeen.push(percent), async () => {
  await evmProvider.getTransaction("a");
  await evmProvider.getTransaction("b");
  await evmProvider.getTransaction("c");
}, evmProvider);
await evmProvider.getTransaction("outside");
check(
  "an evm table read reports the sdk chain fraction",
  evmSeen.length === 3
  && Math.abs(evmSeen[0] - 50) < 0.001
  && Math.abs(evmSeen[1] - (200 / 3)) < 0.001
  && Math.abs(evmSeen[2] - 75) < 0.001,
);

if (failures.length > 0) {
  console.error(`${failures.length} failed`);
  process.exit(1);
}
console.log("sdk progress ok");
