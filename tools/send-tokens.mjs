#!/usr/bin/env node
// Sends TICKS to a list of wallets from a CSV: the 100-wallet distribution, or a season's rewards straight
// from the admin's PAYOUTS export (columns wallet_address and total_ticks).
//
//   node tools/send-tokens.mjs --file payouts.csv --token 0x… [--address-column wallet_address]
//     [--amount-column total_ticks] [--ledger ledgers/season-1.jsonl] [--rpc …] [--send]
//
// Without --send it only checks the file and prints what it would do. With --send it signs with PRIVATE_KEY
// and writes every confirmed transfer to the ledger, so a run that stops halfway can be started again and
// pays nobody twice.

import { readFileSync, existsSync, appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { createPublicClient, createWalletClient, erc20Abi, formatUnits, getAddress, http, parseUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const DECIMALS = 18;

function args() {
  const out = { addressColumn: "address", amountColumn: "amount", send: false };
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    if (key === "--send") out.send = true;
    else if (key === "--file") out.file = argv[++i];
    else if (key === "--token") out.token = argv[++i];
    else if (key === "--rpc") out.rpc = argv[++i];
    else if (key === "--ledger") out.ledger = argv[++i];
    else if (key === "--address-column") out.addressColumn = argv[++i];
    else if (key === "--amount-column") out.amountColumn = argv[++i];
    else throw new Error(`Unknown option ${key}`);
  }
  if (!out.file || !out.token) throw new Error("--file and --token are required");
  out.rpc ??= process.env.ROBINHOOD_RPC_URL;
  out.ledger ??= `ledgers/${out.file.split("/").pop().replace(/\.csv$/i, "")}.jsonl`;
  return out;
}

/** RFC 4180: quoted cells may hold commas and doubled quotes, as the admin export writes them. */
function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ",") {
      row.push(cell);
      cell = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(cell);
      if (row.some((c) => c !== "")) rows.push(row);
      row = [];
      cell = "";
    } else cell += ch;
  }
  row.push(cell);
  if (row.some((c) => c !== "")) rows.push(row);
  return rows;
}

function readTransfers(opts) {
  const [header, ...body] = parseCsv(readFileSync(opts.file, "utf8"));
  const a = header.indexOf(opts.addressColumn);
  const m = header.indexOf(opts.amountColumn);
  if (a === -1 || m === -1) throw new Error(`The file needs the columns ${opts.addressColumn} and ${opts.amountColumn}`);

  const transfers = [];
  const skipped = [];
  const seen = new Set();
  body.forEach((cells, i) => {
    const line = i + 2;
    const raw = (cells[a] ?? "").trim();
    const amountText = (cells[m] ?? "").trim();
    if (!raw) return skipped.push(`line ${line}: no wallet`);
    let address;
    try {
      address = getAddress(raw);
    } catch {
      throw new Error(`line ${line}: ${raw} is not a wallet address`);
    }
    if (seen.has(address)) throw new Error(`line ${line}: ${address} appears twice`);
    seen.add(address);
    const amount = parseUnits(amountText || "0", DECIMALS);
    if (amount <= 0n) return skipped.push(`line ${line}: ${address} has nothing to receive`);
    transfers.push({ address, amount });
  });
  return { transfers, skipped };
}

function readLedger(path) {
  if (!existsSync(path)) return new Map();
  const done = new Map();
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim()) continue;
    const entry = JSON.parse(line);
    done.set(getAddress(entry.address), entry);
  }
  return done;
}

async function main() {
  const opts = args();
  const token = getAddress(opts.token);
  const { transfers, skipped } = readTransfers(opts);
  const done = readLedger(opts.ledger);
  const pending = transfers.filter((t) => !done.has(t.address));
  for (const t of transfers) {
    const entry = done.get(t.address);
    if (entry && BigInt(entry.amount) !== t.amount) {
      throw new Error(`${t.address} was already paid ${entry.amount} in ${entry.tx}, but the file now says ${t.amount}`);
    }
  }

  const total = pending.reduce((sum, t) => sum + t.amount, 0n);
  console.log(`${transfers.length} wallets in the file, ${done.size} already paid, ${pending.length} to pay`);
  console.log(`to send: ${formatUnits(total, DECIMALS)} TICKS`);
  for (const s of skipped) console.log(`skipped ${s}`);
  if (!pending.length) return;

  const client = createPublicClient({ transport: http(opts.rpc) });
  if (!opts.send) {
    for (const t of pending.slice(0, 5)) console.log(`  ${t.address}  ${formatUnits(t.amount, DECIMALS)}`);
    if (pending.length > 5) console.log(`  … and ${pending.length - 5} more`);
    console.log("dry run: nothing was sent. Add --send to send");
    return;
  }

  const key = process.env.PRIVATE_KEY;
  if (!key) throw new Error("PRIVATE_KEY is not set");
  const account = privateKeyToAccount(key.startsWith("0x") ? key : `0x${key}`);
  const chain = { id: await client.getChainId(), name: "robinhood", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [opts.rpc] } } };
  const wallet = createWalletClient({ account, chain, transport: http(opts.rpc) });

  const balance = await client.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [account.address] });
  if (balance < total) {
    throw new Error(`${account.address} holds ${formatUnits(balance, DECIMALS)} TICKS, ${formatUnits(total, DECIMALS)} are needed`);
  }

  mkdirSync(dirname(opts.ledger), { recursive: true });
  for (const [i, t] of pending.entries()) {
    const hash = await wallet.writeContract({ address: token, abi: erc20Abi, functionName: "transfer", args: [t.address, t.amount] });
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`transfer to ${t.address} failed in ${hash}`);
    appendFileSync(opts.ledger, `${JSON.stringify({ address: t.address, amount: t.amount.toString(), tx: hash })}\n`);
    console.log(`${i + 1}/${pending.length}  ${t.address}  ${formatUnits(t.amount, DECIMALS)}  ${hash}`);
  }
  console.log(`done, the ledger is in ${opts.ledger}`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
