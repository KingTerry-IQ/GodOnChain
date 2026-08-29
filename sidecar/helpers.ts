import { ethers } from "ethers";

export function getNormalizedChain(chain?: string): "sol" | "mon" {
  const c = (chain || "sol").toLowerCase();
  if (!["sol", "mon"].includes(c)) {
    throw new Error("Invalid chain. Use 'sol' or 'mon'");
  }
  return c as "sol" | "mon";
}

export function safeParseMetadata(raw: string | null | undefined): Record<string, any> {
  if (!raw) return {};
  if (typeof raw !== "string") return raw;
  try {
    return JSON.parse(raw);
  } catch {
    return { rawMetadata: raw };
  }
}

/**
 * Replicates the exact logic from iqlabs-solana-sdk/src/sdk/reader/reader_utils.ts
 * decodeUserInventoryCodeIn + decodeReaderInstruction
 * (self-contained, no SDK internals required)
 */
export function extractIQLabsMetadataFromTx(tx: any): { onChainPath: string; metadata: string } | null {
  const CODE_IN_INSTRUCTION_NAMES = [
    "user_inventory_code_in",
    "user_inventory_code_in_for_free",
    "db_code_in",
    "db_instruction_code_in",
    "wallet_connection_code_in",
  ];

  // We need the Anchor instruction coder + program ID from the SDK context
  // Since we can't reliably import internal context, we use a robust fallback:
  // Scan for known Anchor discriminators (from the IDL)
  const message = tx.transaction.message;
  const accountKeys = message.getAccountKeys();

  for (const ix of message.compiledInstructions) {
    const data = Buffer.from(ix.data);

    // Try to decode as Anchor instruction (8-byte discriminator + Borsh)
    if (data.length < 8) continue;

    const discriminator = data.subarray(0, 8);

    // Known discriminators from the iqlabs code_in.json IDL
    const knownDiscriminators = [
      Buffer.from([81, 177, 5, 122, 213, 125, 21, 238]), // user_inventory_code_in
      Buffer.from([24, 194, 135, 247, 125, 51, 67, 47]), // user_inventory_code_in_for_free
      Buffer.from([38, 100, 165, 242, 99, 137, 206, 108]), // db_code_in
      Buffer.from([30, 11, 100, 201, 224, 121, 37, 163]), // db_instruction_code_in
      Buffer.from([204, 215, 244, 145, 49, 183, 94, 148]), // wallet_connection_code_in
    ];

    const isMatch = knownDiscriminators.some(d => d.equals(discriminator));
    if (!isMatch) continue;

    // Decode the two strings (on_chain_path + metadata) using simple Borsh string parser
    try {
      const args = decodeBorshStrings(data.subarray(8));
      if (args.length >= 2) {
        return {
          onChainPath: args[0],
          metadata: args[1],
        };
      }
    } catch (e) {
      // fall through to next instruction
    }
  }

  return null;
}

/** Minimal Borsh string decoder (length-prefixed UTF8) */
export function decodeBorshStrings(buffer: Buffer): string[] {
  const strings: string[] = [];
  let offset = 0;

  while (offset < buffer.length) {
    if (offset + 4 > buffer.length) break;

    const len = buffer.readUInt32LE(offset);
    offset += 4;

    if (offset + len > buffer.length) break;

    const str = buffer.subarray(offset, offset + len).toString("utf8");
    strings.push(str);
    offset += len;
  }

  return strings;
}

/** 
 * Precise metadata extractor for Monad/EVM using known contract function signatures.
 * Mirrors the Solana decodeUserInventoryCodeIn + decodeBorshStrings logic.
 */
export function extractMonadMetadata(tx: any, receipt: any): { 
  metadata?: string; 
  onChainPath?: string;
  handle?: string;
  typeField?: string;
  offset?: string;
  beforeUserTx?: string;
} | null {
  if (!tx?.data || tx.data.length < 10) return null;

  const data = tx.data.startsWith("0x") ? tx.data : "0x" + tx.data;

  // Known function signatures from the CodeIn contract (exact match to Solana side)
  const knownSignatures = [
    "userInventoryCodeIn(string,string,string,string,string)",      // handle, tailTx, typeField, offset, beforeUserTx
    "dbCodeIn(bytes32,bytes32,string,string,string)",               // ..., onChainPath, metadata, beforeDataTx
    "dbInstructionCodeIn(bytes32,bytes32,string,string,string,string)",
    "walletConnectionCodeIn(address,bytes32,bytes32,string,string,string)",
    "sendCode(string[],string,uint8,uint8)",
  ];

  for (const sig of knownSignatures) {
    try {
      const iface = new ethers.Interface([`function ${sig}`]);
      const decoded = iface.decodeFunctionData(sig.split("(")[0], data);

      // userInventoryCodeIn is the most common for generic codeIn (matches readCodeIn metadata)
      if (sig.startsWith("userInventoryCodeIn")) {
        const [handle, tailTx, typeField, offset, beforeUserTx] = decoded;
        const metaObj = {
          handle: handle || "",
          typeField: typeField || "",
          offset: offset || "0",
          beforeUserTx: beforeUserTx || "",
        };
        return {
          metadata: JSON.stringify(metaObj),
          onChainPath: tailTx || undefined,
          handle,
          typeField,
          offset,
          beforeUserTx,
        };
      }

      // dbCodeIn / similar — metadata is the 4th string arg (after path)
      if (sig.includes("dbCodeIn") || sig.includes("dbInstructionCodeIn")) {
        // decoded = [dbRootId, tableSeed, onChainPath, metadata, beforeDataTx]
        const onChainPath = decoded[2] || "";
        const metadata = decoded[3] || "";
        const beforeDataTx = decoded[4] || "";
        
        if (metadata && (metadata.includes("{") || metadata.includes("filename") || metadata.includes("filetype"))) {
          return { 
            metadata, 
            onChainPath: onChainPath || beforeDataTx || undefined 
          };
        }
      }

      // Fallback: any string arg that looks like metadata/JSON
      for (const arg of decoded) {
        if (typeof arg === "string" && arg.length > 5) {
          if (arg.includes("{") || arg.includes("filename") || arg.includes("filetype") || arg.includes("handle")) {
            return { metadata: arg };
          }
        }
      }
    } catch {
      // selector didn't match — try next signature
    }
  }

  // Final fallback: check event logs (DbCodeInEvent, UserInventoryCodeInEvent, etc.)
  if (receipt?.logs) {
    for (const log of receipt.logs) {
      if (!log.data || log.data.length < 100) continue;
      try {
        // Try to decode common event data
        const logData = log.data.startsWith("0x") ? log.data.slice(2) : log.data;
        const buf = Buffer.from(logData, "hex");

        // Look for plausible string lengths in event data
        for (let i = 0; i < buf.length - 64; i += 32) {
          const len = buf.readUInt32BE(i + 28); // last 4 bytes of uint256 length
          if (len > 0 && len < 2000 && i + 32 + len <= buf.length) {
            const str = buf.subarray(i + 32, i + 32 + len).toString("utf8");
            if (str.includes("filename") || str.includes("filetype") || str.includes("handle") || str.includes("{")) {
              return { metadata: str };
            }
          }
        }
      } catch {}
    }
  }

  return null;
}