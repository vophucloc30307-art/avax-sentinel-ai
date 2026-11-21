const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("AvaxSentinel AI - AgentGuardVault Enterprise Tests", function () {
  let vault, mockUSDC, owner, aiAgent, riskOracle, targetProtocol, attacker;
  const maxSingleTx = ethers.parseUnits("2500", 6);
  const dailyLimit = ethers.parseUnits("10000", 6);
  const auditFee = ethers.parseUnits("0.05", 6);

  beforeEach(async function () {
    [owner, aiAgent, riskOracle, targetProtocol, attacker] = await ethers.getSigners();

    // 1. Deploy Mock USDC
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    // 2. Deploy AgentGuardVault
    const Vault = await ethers.getContractFactory("AgentGuardVault");
    vault = await Vault.deploy(
      aiAgent.address,
      riskOracle.address,
      maxSingleTx,
      dailyLimit,
      await mockUSDC.getAddress(),
      auditFee
    );
    await vault.waitForDeployment();

    // 3. Setup initial whitelists & deposit
    await vault.setWhitelistedProtocol(targetProtocol.address, true);
    await vault.setSupportedToken(await mockUSDC.getAddress(), true);

    await mockUSDC.approve(await vault.getAddress(), ethers.parseUnits("10000", 6));
    await vault.deposit(await mockUSDC.getAddress(), ethers.parseUnits("5000", 6));
  });

  it("Should initialize with correct Avalanche EIP-712 domain and state", async function () {
    expect(await vault.owner()).to.equal(owner.address);
    expect(await vault.aiAgentSigner()).to.equal(aiAgent.address);
    expect(await vault.aiRiskOracle()).to.equal(riskOracle.address);
    expect(await vault.circuitBreakerActive()).to.equal(false);
  });

  it("Should allow deposit of supported token", async function () {
    const vaultBal = await mockUSDC.balanceOf(await vault.getAddress());
    expect(vaultBal).to.equal(ethers.parseUnits("5000", 6));
  });

  it("Should block action if target protocol is not whitelisted", async function () {
    const deadline = Math.floor(Date.now() / 1000) + 3600;
    const fakeSignature = "0x" + "11".repeat(65);

    // Call from aiAgent to unwhitelisted attacker address
    await expect(
      vault.connect(aiAgent).executeGuardedAction(
        attacker.address,
        await mockUSDC.getAddress(),
        ethers.parseUnits("100", 6),
        "0x",
        10,
        deadline,
        fakeSignature,
        "Test swap"
      )
    ).to.be.reverted;
  });

  it("Should trigger Emergency Circuit Breaker and freeze vault", async function () {
    await vault.connect(owner).triggerEmergencyShutdown("MALICIOUS_AI_LOOP_DETECTED");
    expect(await vault.circuitBreakerActive()).to.equal(true);

    // Any deposit or action while frozen must revert
    await expect(
      vault.deposit(await mockUSDC.getAddress(), ethers.parseUnits("10", 6))
    ).to.be.revertedWith("AgentGuardVault: Circuit breaker active, funds frozen!");
  });

  it("Should allow x402 audit fee payment", async function () {
    await mockUSDC.transfer(attacker.address, ethers.parseUnits("10", 6));
    await mockUSDC.connect(attacker).approve(await vault.getAddress(), ethers.parseUnits("1", 6));

    await expect(
      vault.connect(attacker).payAuditFee(auditFee)
    ).to.emit(vault, "AuditFeePaid").withArgs(attacker.address, auditFee);

    expect(await vault.totalAuditFeesCollected()).to.equal(auditFee);
  });
});
