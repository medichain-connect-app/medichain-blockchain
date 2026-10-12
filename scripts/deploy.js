/**
 * MediChain deployment
 * ────────────────────
 * Deploys two contracts:
 *   1. MediChainForwarder — OpenZeppelin ERC-2771 forwarder. The backend relayer
 *      submits users' signed requests through it and pays their gas.
 *   2. MediAccessControl  — access grants + immutable audit log, trusting (1).
 *
 * Usage:
 *   npx hardhat run scripts/deploy.js --network localhost  (local node)
 *   npx hardhat run scripts/deploy.js --network amoy       (Polygon Amoy testnet)
 *   npx hardhat run scripts/deploy.js --network polygon    (Polygon mainnet)
 *
 * Addresses are written to deployments/<network>.json.
 */

const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

const EXPLORERS = {
  amoy: "https://amoy.polygonscan.com",
  polygon: "https://polygonscan.com",
};

// Public networks need a couple of confirmations before we trust the address.
const CONFIRMATIONS = network.name === "hardhat" || network.name === "localhost" ? 1 : 2;

async function deploy(name, args = []) {
  console.log(`Deploying ${name}...`);
  const factory = await ethers.getContractFactory(name);
  const contract = await factory.deploy(...args);
  const tx = contract.deploymentTransaction();
  console.log(`  tx ${tx.hash} — waiting for ${CONFIRMATIONS} confirmation(s)`);
  await tx.wait(CONFIRMATIONS);
  const address = await contract.getAddress();
  console.log(`  ✔ ${name} → ${address}\n`);
  return address;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  const { chainId } = await ethers.provider.getNetwork();

  console.log(`\nNetwork  : ${network.name} (chain ${chainId})`);
  console.log(`Deployer : ${deployer.address}`);
  console.log(`Balance  : ${ethers.formatEther(balance)} POL\n`);

  if (balance === 0n) {
    throw new Error("Deployer has no funds. Get test POL from https://faucet.polygon.technology/");
  }

  const forwarder = await deploy("MediChainForwarder");
  const accessControl = await deploy("MediAccessControl", [forwarder]);

  const explorer = EXPLORERS[network.name] || null;
  const deployment = {
    network: network.name,
    chainId: chainId.toString(),
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {
      MediChainForwarder: forwarder,
      MediAccessControl: accessControl,
    },
    explorer,
  };

  const outDir = path.join(__dirname, "../deployments");
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, `${network.name}.json`), JSON.stringify(deployment, null, 2) + "\n");

  console.log(`Saved to deployments/${network.name}.json\n`);
  console.log("Backend .env settings:");
  console.log(`  BLOCKCHAIN_CHAIN_ID=${chainId}`);
  console.log(`  CONTRACT_ADDRESS=${accessControl}`);
  console.log(`  FORWARDER_ADDRESS=${forwarder}`);
  if (explorer) {
    console.log(`  BLOCKCHAIN_EXPLORER_URL=${explorer}`);
    console.log(`\nView on explorer: ${explorer}/address/${accessControl}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
