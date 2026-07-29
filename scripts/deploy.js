/**
 * Medichain Deployment Script — Approach 2 (Hybrid)
 * ──────────────────────────────────────────────────
 * Only ONE contract needs to be deployed:
 *   MediAccessControl — handles access grants + immutable audit log
 *
 * Supabase handles: auth, user profiles, record metadata
 * IPFS handles: encrypted file storage
 * This contract handles: access control + audit trail only
 *
 * Usage:
 *   npx hardhat run scripts/deploy.js --network hardhat    (local — instant, free)
 *   npx hardhat run scripts/deploy.js --network amoy       (Polygon testnet)
 *   npx hardhat run scripts/deploy.js --network polygon    (Polygon mainnet)
 */

const { ethers, network } = require("hardhat");
const fs                   = require("fs");
const path                 = require("path");
require("dotenv").config();

function getRpcUrl() {
  if (network.name === "hardhat" || network.name === "localhost") {
    return "http://127.0.0.1:8545";
  }
  if (network.name === "amoy") return process.env.POLYGON_AMOY_RPC_URL;
  return process.env.POLYGON_MAINNET_RPC_URL;
}

async function waitForTx(txHash, confirmations = 2) {
  console.log(`     ⏳ Waiting for confirmation (tx: ${txHash.slice(0, 12)}...)`);

  // Local Hardhat network — tx is instant
  if (network.name === "hardhat" || network.name === "localhost") {
    console.log(`     ✅ Local network — confirmed instantly`);
    return;
  }

  // Testnet / Mainnet — poll until confirmed
  const rawProvider = new ethers.JsonRpcProvider(getRpcUrl());
  for (let i = 0; i < 60; i++) {
    try {
      const receipt = await rawProvider.getTransactionReceipt(txHash);
      if (receipt && receipt.blockNumber) {
        const currentBlock = await rawProvider.getBlockNumber();
        if (currentBlock >= receipt.blockNumber + confirmations - 1) {
          return receipt;
        }
      }
    } catch (_) {}
    await new Promise(r => setTimeout(r, 3000));
  }
  throw new Error(`Timeout waiting for tx ${txHash}`);
}

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("\n╔══════════════════════════════════════════════════╗");
  console.log("║       MEDICHAIN CONTRACT DEPLOYMENT              ║");
  console.log("║       Approach 2 — Hybrid Architecture           ║");
  console.log("╚══════════════════════════════════════════════════╝\n");
  console.log(`Network   : ${network.name}`);
  console.log(`Deployer  : ${deployer.address}`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance   : ${ethers.formatEther(balance)} MATIC\n`);

  // ── Deploy MediAccessControl ─────────────────────────────────────────
  console.log("Deploying MediAccessControl...");
  const MediAccessControl = await ethers.getContractFactory("MediAccessControl");
  const accessTx          = await MediAccessControl.deploy();
  const accessAddress     = await accessTx.getAddress();
  await waitForTx(accessTx.deploymentTransaction().hash);
  console.log(`     ✔  MediAccessControl → ${accessAddress}`);

  // ── Summary ───────────────────────────────────────────────────────────
  console.log("\n╔══════════════════════════════════════════════════╗");
  console.log("║                DEPLOYMENT COMPLETE               ║");
  console.log("╠══════════════════════════════════════════════════╣");
  console.log(`║  MediAccessControl : ${accessAddress}  ║`);
  console.log("╠══════════════════════════════════════════════════╣");
  console.log("║  Supabase          : handles auth + metadata      ║");
  console.log("║  IPFS              : handles encrypted files       ║");
  console.log("║  MediAccessControl : handles access + audit log   ║");
  console.log("╚══════════════════════════════════════════════════╝\n");

  // ── Save address to JSON ──────────────────────────────────────────────
  const networkInfo  = await ethers.provider.getNetwork();
  const deployedData = {
    approach:    "Hybrid (Approach 2)",
    network:     network.name,
    chainId:     networkInfo.chainId.toString(),
    deployedAt:  new Date().toISOString(),
    deployer:    deployer.address,
    contracts: {
      MediAccessControl: accessAddress,
    },
    notes: {
      identity:       "Managed by Supabase Auth",
      recordMetadata: "Managed by Supabase Database",
      fileStorage:    "Managed by IPFS (Pinata)",
      accessControl:  "Managed by MediAccessControl contract",
      auditLog:       "Immutable on-chain via MediAccessControl events",
    },
  };

  const outDir  = path.join(__dirname, "../deployments");
  const outFile = path.join(outDir, `${network.name}.json`);

  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(outFile, JSON.stringify(deployedData, null, 2));

  console.log(`Contract address saved to: deployments/${network.name}.json`);
  console.log("Add this address to your Flutter app config.\n");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
