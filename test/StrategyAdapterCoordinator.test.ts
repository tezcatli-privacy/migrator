import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import hre from "hardhat";
import { Encryptable } from "@cofhe/sdk";
import { expect } from "chai";

const TASK_COFHE_MOCKS_DEPLOY = "task:cofhe-mocks:deploy";

describe("Tezcatli strategy adapter and coordinator", function () {
  async function deployFixture() {
    await hre.run(TASK_COFHE_MOCKS_DEPLOY);

    const [deployer, operator, user, recipient] = await hre.ethers.getSigners();

    const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const WrappedToken = await hre.ethers.getContractFactory("TezcatliWrappedToken");
    const wrappedToken = await WrappedToken.deploy(
      "Tezcatli Confidential USD",
      "tzcUSD",
      await usdc.getAddress(),
      6,
    );
    await wrappedToken.waitForDeployment();

    const Vault = await hre.ethers.getContractFactory("TezcatliConfidentialVault");
    const vault = await Vault.deploy(await wrappedToken.getAddress(), deployer.address);
    await vault.waitForDeployment();

    const Coordinator = await hre.ethers.getContractFactory("TezcatliVaultCoordinator");
    const coordinator = await Coordinator.deploy(deployer.address);
    await coordinator.waitForDeployment();

    await (await coordinator.setOperator(operator.address, true)).wait();
    await (await coordinator.setApprovedVault(await vault.getAddress(), true)).wait();
    await (await vault.setCoordinator(await coordinator.getAddress())).wait();

    const MockYieldVault = await hre.ethers.getContractFactory("MockYieldVault");
    const strategyVault = await MockYieldVault.deploy(await usdc.getAddress());
    await strategyVault.waitForDeployment();

    const Adapter = await hre.ethers.getContractFactory("TezcatliStrategyAdapterERC4626");
    const adapter = await Adapter.deploy(
      await vault.getAddress(),
      await usdc.getAddress(),
      await strategyVault.getAddress(),
      deployer.address,
    );
    await adapter.waitForDeployment();

    await (await vault.setStrategyAdapter(await adapter.getAddress())).wait();
    await (await coordinator.setStrategyConfig(
      await vault.getAddress(),
      await adapter.getAddress(),
      1,
      10_000,
      10_000,
      true,
    )).wait();

    await (await usdc.mint(user.address, 100_000_000n)).wait();
    await (await usdc.connect(user).approve(await wrappedToken.getAddress(), 100_000_000n)).wait();
    await (await wrappedToken.connect(user).shield(60_000_000n)).wait();

    const userClient = await hre.cofhe.createClientWithBatteries(user);
    return {
      deployer,
      operator,
      user,
      recipient,
      usdc,
      wrappedToken,
      vault,
      coordinator,
      strategyVault,
      adapter,
      userClient,
    };
  }

  it("routes confidential liquidity through strategy and back with coordinator", async function () {
    const {
      deployer,
      operator,
      user,
      recipient,
      usdc,
      wrappedToken,
      vault,
      coordinator,
      strategyVault,
      adapter,
      userClient,
    } = await loadFixture(deployFixture);

    const depositAmount = 30_000_000n;
    const [encryptedDeposit] = await userClient
      .encryptInputs([Encryptable.uint64(depositAmount)])
      .setAccount(user.address)
      .execute();

    await wrappedToken
      .connect(user)
      ["confidentialTransferAndCall(address,(uint256,uint8,uint8,bytes),bytes)"](
        await vault.getAddress(),
        encryptedDeposit,
        hre.ethers.AbiCoder.defaultAbiCoder().encode(["address"], [user.address]),
      );

    await coordinator.connect(operator).deployToStrategyWithAdapter(
      await vault.getAddress(),
      await adapter.getAddress(),
      10_000_000,
      10_000_000n,
    );
    expect(await vault.strategyShares()).to.equal(10_000_000n);

    const vaultHandleAfterDeploy = await wrappedToken.confidentialBalanceOf(await vault.getAddress());
    const vaultBalanceAfterDeploy = await hre.cofhe.mocks.getPlaintext(vaultHandleAfterDeploy);
    expect(vaultBalanceAfterDeploy).to.equal(20_000_000n);

    await (await usdc.mint(deployer.address, 5_000_000n)).wait();
    await (await usdc.connect(deployer).approve(await strategyVault.getAddress(), 2_000_000n)).wait();
    await (await strategyVault.connect(deployer).donate(2_000_000n)).wait();

    await time.increase(7 * 24 * 60 * 60);
    await expect(vault.connect(user).withdrawConfidential(recipient.address))
      .to.be.revertedWithCustomError(vault, "StrategyPositionOpen");

    await coordinator.connect(operator).redeemFromStrategyWithAdapter(
      await vault.getAddress(),
      await adapter.getAddress(),
      10_000_000n,
      11_000_000,
    );
    expect(await vault.strategyShares()).to.equal(0n);

    const vaultHandleAfterRedeem = await wrappedToken.confidentialBalanceOf(await vault.getAddress());
    const vaultBalanceAfterRedeem = await hre.cofhe.mocks.getPlaintext(vaultHandleAfterRedeem);
    expect(vaultBalanceAfterRedeem).to.be.gte(31_999_999n);

    await vault.connect(user).withdrawConfidential(recipient.address);

    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const recipientBalance = await hre.cofhe.mocks.getPlaintext(recipientHandle);
    expect(recipientBalance).to.be.gte(31_999_999n);

    const vaultHandleAfterWithdraw = await wrappedToken.confidentialBalanceOf(await vault.getAddress());
    const vaultBalanceAfterWithdraw = await hre.cofhe.mocks.getPlaintext(vaultHandleAfterWithdraw);
    expect(vaultBalanceAfterWithdraw).to.equal(0n);
  });

  it("blocks non-coordinator strategy execution", async function () {
    const { user, vault, adapter } = await loadFixture(deployFixture);

    await expect(vault.connect(user).coordinatorDeployToStrategy(await adapter.getAddress(), 1_000_000, 1))
      .to.be.revertedWithCustomError(vault, "UnauthorizedCoordinator");
  });

  it("enforces allocation caps across multiple strategy adapters", async function () {
    const { deployer, operator, user, usdc, wrappedToken, vault, coordinator, adapter, userClient } = await loadFixture(deployFixture);

    const MockYieldVault = await hre.ethers.getContractFactory("MockYieldVault");
    const highRiskStrategyVault = await MockYieldVault.deploy(await usdc.getAddress());
    await highRiskStrategyVault.waitForDeployment();

    const Adapter = await hre.ethers.getContractFactory("TezcatliStrategyAdapterERC4626");
    const highRiskAdapter = await Adapter.deploy(
      await vault.getAddress(),
      await usdc.getAddress(),
      await highRiskStrategyVault.getAddress(),
      deployer.address,
    );
    await highRiskAdapter.waitForDeployment();

    await (await vault.setStrategyAdapterApproval(await highRiskAdapter.getAddress(), true)).wait();

    await (await coordinator.setStrategyConfig(
      await vault.getAddress(),
      await adapter.getAddress(),
      0,
      7000,
      8000,
      true,
    )).wait();
    await (await coordinator.setStrategyConfig(
      await vault.getAddress(),
      await highRiskAdapter.getAddress(),
      2,
      2000,
      3000,
      true,
    )).wait();

    const depositAmount = 30_000_000n;
    const [encryptedDeposit] = await userClient
      .encryptInputs([Encryptable.uint64(depositAmount)])
      .setAccount(user.address)
      .execute();

    await wrappedToken
      .connect(user)
      ["confidentialTransferAndCall(address,(uint256,uint8,uint8,bytes),bytes)"](
        await vault.getAddress(),
        encryptedDeposit,
        hre.ethers.AbiCoder.defaultAbiCoder().encode(["address"], [user.address]),
      );

    await coordinator.connect(operator).deployToStrategyWithAdapter(
      await vault.getAddress(),
      await adapter.getAddress(),
      20_000_000,
      20_000_000n,
    );
    await coordinator.connect(operator).deployToStrategyWithAdapter(
      await vault.getAddress(),
      await highRiskAdapter.getAddress(),
      8_000_000,
      8_000_000n,
    );

    const highRiskAllocationBps = await coordinator.currentAllocationBps(
      await vault.getAddress(),
      await highRiskAdapter.getAddress(),
    );
    expect(highRiskAllocationBps).to.be.lte(3000);

    await expect(
      coordinator.connect(operator).deployToStrategyWithAdapter(
        await vault.getAddress(),
        await highRiskAdapter.getAddress(),
        2_000_000,
        2_000_000n,
      ),
    ).to.be.revertedWithCustomError(coordinator, "AllocationExceeded");
  });

  it("enforces risk policy checks in coordinator execution", async function () {
    const { deployer, operator, user, usdc, wrappedToken, vault, coordinator, adapter, userClient } = await loadFixture(deployFixture);

    const RiskPolicy = await hre.ethers.getContractFactory("TezcatliStrategyRiskPolicy");
    const riskPolicy = await RiskPolicy.deploy(deployer.address);
    await riskPolicy.waitForDeployment();

    await (await coordinator.setRiskPolicy(await riskPolicy.getAddress())).wait();
    await (await riskPolicy.setPolicy(
      await vault.getAddress(),
      await adapter.getAddress(),
      true,
      10_000,
      100,
      3600,
      20_000,
      true,
    )).wait();

    const depositAmount = 30_000_000n;
    const [encryptedDeposit] = await userClient
      .encryptInputs([Encryptable.uint64(depositAmount)])
      .setAccount(user.address)
      .execute();

    await wrappedToken
      .connect(user)
      ["confidentialTransferAndCall(address,(uint256,uint8,uint8,bytes),bytes)"](
        await vault.getAddress(),
        encryptedDeposit,
        hre.ethers.AbiCoder.defaultAbiCoder().encode(["address"], [user.address]),
      );

    await expect(
      coordinator.connect(operator).deployToStrategyWithPolicy(
        await vault.getAddress(),
        await adapter.getAddress(),
        10_000_000,
        10_000_000,
        9_800_000,
        20_000,
      ),
    ).to.be.revertedWithCustomError(riskPolicy, "SlippageExceeded");

    await expect(
      coordinator.connect(operator).deployToStrategyWithPolicy(
        await vault.getAddress(),
        await adapter.getAddress(),
        10_000_000,
        10_000_000,
        9_950_000,
        25_000,
      ),
    ).to.be.revertedWithCustomError(riskPolicy, "LeverageExceeded");

    await coordinator.connect(operator).deployToStrategyWithPolicy(
      await vault.getAddress(),
      await adapter.getAddress(),
      10_000_000,
      10_000_000,
      9_950_000,
      20_000,
    );
    expect(await vault.strategyShares()).to.equal(10_000_000n);
  });

  it("tracks and clears critical settlement windows", async function () {
    const { deployer, operator, vault, coordinator, adapter } = await loadFixture(deployFixture);

    const RiskPolicy = await hre.ethers.getContractFactory("TezcatliStrategyRiskPolicy");
    const riskPolicy = await RiskPolicy.deploy(deployer.address);
    await riskPolicy.waitForDeployment();

    await (await coordinator.setRiskPolicy(await riskPolicy.getAddress())).wait();
    await (await riskPolicy.setPolicy(
      await vault.getAddress(),
      await adapter.getAddress(),
      true,
      10_000,
      500,
      3600,
      0,
      false,
    )).wait();

    await coordinator.connect(operator).startCriticalSettlement(await vault.getAddress(), await adapter.getAddress());
    expect(await vault.settlementPending()).to.equal(true);
    expect(await coordinator.pendingSettlementCountByVault(await vault.getAddress())).to.equal(1n);
    expect(await coordinator.isCriticalSettlementOverdue(await vault.getAddress(), await adapter.getAddress())).to.equal(false);

    await expect(
      coordinator.connect(operator).startCriticalSettlement(await vault.getAddress(), await adapter.getAddress()),
    ).to.be.revertedWithCustomError(coordinator, "SettlementPending");

    await coordinator.connect(operator).clearCriticalSettlement(await vault.getAddress(), await adapter.getAddress());
    expect(await vault.settlementPending()).to.equal(false);
    expect(await coordinator.pendingSettlementCountByVault(await vault.getAddress())).to.equal(0n);
  });
});
