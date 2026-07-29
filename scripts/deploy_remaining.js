/**
 * Medichain — Continue Deployment
 * ─────────────────────────────────
 * IdentityRegistry is already deployed at:
 *   0x5f35ba878a5919f803355b974537305270c8d8d0  (nonce 1, latest)
 *
 * This script deploys only the remaining 2 contracts:
 *   1. RecordRegistry       (needs IdentityRegistry address)
 *   2. MediAccessControl    (needs both addresses)
 */

const { ethers } = require("hardhat");
const fs          = require("fs");
const path        = require("path");
require("dotenv").config();

// ── Already deployed ────────────────────────────────────────────────────────
const IDENTITY_REGISTRY_ADDRESS = "0x5f35ba878a5919f803355b974537305270c8d8d0";

// Raw provider for reliable tx confirmation
const rawProvider = new ethers.JsonRpcProvider(process.env.POLYGON_AMOY_RPC_URL);

async function waitForTx(txHash, confirmations = 2) {
  console.log(`     ⏳ Waiting for confirmation (tx: ${txHash.slice(0, 12)}...)`);
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
  console.log("║       MEDICHAIN — CONTINUE DEPLOYMENT            ║");
  console.log("╚══════════════════════════════════════════════════╝\n");
  console.log(`Deployer           : ${deployer.address}`);

  const balance = await rawProvider.getBalance(deployer.address);
  console.log(`Balance            : ${ethers.formatEther(balance)} MATIC`);
  console.log(`IdentityRegistry   : ${IDENTITY_REGISTRY_ADDRESS} (already deployed)\n`);

  // ── 1. RecordRegistry ────────────────────────────────────────────────
  console.log("1/2  Deploying RecordRegistry...");
  const RecordRegistry = await ethers.getContractFactory("RecordRegistry");
  const recordTx       = await RecordRegistry.deploy(IDENTITY_REGISTRY_ADDRESS);
  const recordAddress  = await recordTx.getAddress();
  await waitForTx(recordTx.deploymentTransaction().hash);
  console.log(`     ✔  RecordRegistry    → ${recordAddress}`);

  // ── 2. MediAccessControl ─────────────────────────────────────────────
  console.log("2/2  Deploying MediAccessControl...");
  const MediAccessControl = await ethers.getContractFactory("MediAccessControl");
  const accessTx          = await MediAccessControl.deploy(
    IDENTITY_REGISTRY_ADDRESS,
    recordAddress
  );
  const accessAddress = await accessTx.getAddress();
  await waitForTx(accessTx.deploymentTransaction().hash);
  console.log(`     ✔  MediAccessControl → ${accessAddress}`);

  // ── Summary ───────────────────────────────────────────────────────────
  console.log("\n╔══════════════════════════════════════════════════╗");
  console.log("║                DEPLOYMENT COMPLETE               ║");
  console.log("╠══════════════════════════════════════════════════╣");
  console.log(`║  IdentityRegistry   : ${IDENTITY_REGISTRY_ADDRESS}  ║`);
  console.log(`║  RecordRegistry     : ${recordAddress}  ║`);
  console.log(`║  MediAccessControl  : ${accessAddress}  ║`);
  console.log("╚══════════════════════════════════════════════════╝\n");

  // ── Save addresses ────────────────────────────────────────────────────
  const network      = await rawProvider.getNetwork();
  const deployedData = {
    network:     "amoy",
    chainId:     network.chainId.toString(),
    deployedAt:  new Date().toISOString(),
    deployer:    deployer.address,
    contracts: {
      IdentityRegistry:  IDENTITY_REGISTRY_ADDRESS,
      RecordRegistry:    recordAddress,
      MediAccessControl: accessAddress,
    },
  };

  const outDir  = path.join(__dirname, "../deployments");
  const outFile = path.join(outDir, "amoy.json");

  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(outFile, JSON.stringify(deployedData, null, 2));

  console.log(`Addresses saved to: deployments/amoy.json`);
  console.log("Copy these into your Flutter app config.\n");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
