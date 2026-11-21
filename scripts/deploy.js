const hre = require("hardhat");

async function main() {
  console.log("=================================================");
  console.log(" Deploying AvaxSentinel AI Vault on Avalanche... ");
  console.log("=================================================");

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with account:", deployer ? deployer.address : "Default Signer");

  // 1. Deploy Mock USDC
  const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy();
  await usdc.waitForDeployment();
  const usdcAddress = await usdc.getAddress();
  console.log("MockUSDC deployed to:", usdcAddress);

  // 2. Deploy AgentGuardVault
  // Config: Max single tx = 2,500 USDC ($2500 * 10^6), Daily limit = 10,000 USDC ($10000 * 10^6)
  const maxSingleTx = hre.ethers.parseUnits("2500", 6);
  const dailyLimit = hre.ethers.parseUnits("10000", 6);

  const AgentGuardVault = await hre.ethers.getContractFactory("AgentGuardVault");
  const vault = await AgentGuardVault.deploy(
    deployer.address, // AI Agent Signer
    deployer.address, // AI Risk Oracle
    maxSingleTx,
    dailyLimit
  );
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();
  console.log("AgentGuardVault deployed to:", vaultAddress);

  // 3. Configure initial whitelist for Trader Joe Router & Mock USDC
  const traderJoeRouter = "0x60aE616a2155BA3d9A68541Ba4544862310933d4";
  await vault.setWhitelistedProtocol(traderJoeRouter, true);
  await vault.setSupportedToken(usdcAddress, true);
  console.log("Configured Whitelisted Protocol (Trader Joe) & Supported Token (MockUSDC)");

  console.log("=================================================");
  console.log(" Deployment Completed Successfully on Fuji!     ");
  console.log(" Contract Address:", vaultAddress);
  console.log("=================================================");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
