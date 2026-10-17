#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs";
import { decodeEventLog, getAddress, parseAbi } from "viem";

const POSITION_MANAGER = getAddress("0x58daec3116aae6D93017bAAea7749052E8a04fA7");
const transfer = parseAbi(["event Transfer(address indexed from, address indexed to, uint256 indexed id)"]);

const [script = "Launch", chainId = "4663", write] = process.argv.slice(2);
const run = JSON.parse(readFileSync(`broadcast/${script}.s.sol/${chainId}/run-latest.json`, "utf8"));
const minted = run.receipts
  .flatMap((r) => r.logs)
  .filter((l) => getAddress(l.address) === POSITION_MANAGER && l.topics.length === 4)
  .map((l) => decodeEventLog({ abi: transfer, data: l.data, topics: l.topics }).args)
  .filter((e) => BigInt(e.from) === 0n);
if (minted.length !== 1) throw new Error(`expected one minted position in the last ${script} run, found ${minted.length}`);

const { id, to } = minted[0];
console.log(`position NFT ${id} owned by ${to}`);
if (write) {
  const deployment = JSON.parse(readFileSync(write, "utf8"));
  deployment.positionId = Number(id);
  writeFileSync(write, `${JSON.stringify(deployment, null, 2)}\n`);
  console.log(`updated ${write}`);
}
