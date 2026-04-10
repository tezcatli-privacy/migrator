import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import hre from "hardhat";
import { Encryptable, FheTypes } from "@cofhe/sdk";
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

    await (await usdc.mint(user.address, 100_000_000n)).wait();
    await (await usdc.connect(user).approve(await wrappedToken.getAddress(), 100_000_000n)).wait();
    await (await wrappedToken.connect(user).shield(60_000_000n)).wait();

    const userClient = await hre.cofhe.createClientWithBatteries(user);
    const recipientClient = await hre.cofhe.createClientWithBatteries(recipient);

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
      recipientClient,
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
      userClient,
      recipientClient,
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

    await coordinator.connect(operator).deployToStrategy(await vault.getAddress(), 10_000_000, 10_000_000n);
    expect(await vault.strategyShares()).to.equal(10_000_000n);

    const vaultHandleAfterDeploy = await wrappedToken.confidentialBalanceOf(await vault.getAddress());
    const vaultBalanceAfterDeploy = await hre.cofhe.mocks.getPlaintext(vaultHandleAfterDeploy);
    expect(vaultBalanceAfterDeploy).to.equal(20_000_000n);

    await (await usdc.mint(deployer.address, 5_000_000n)).wait();
    await (await usdc.connect(deployer).approve(await strategyVault.getAddress(), 2_000_000n)).wait();
    await (await strategyVault.connect(deployer).donate(2_000_000n)).wait();

    await coordinator.connect(operator).redeemFromStrategy(await vault.getAddress(), 10_000_000n, 11_000_000);
    expect(await vault.strategyShares()).to.equal(0n);

    const vaultHandleAfterRedeem = await wrappedToken.confidentialBalanceOf(await vault.getAddress());
    const vaultBalanceAfterRedeem = await hre.cofhe.mocks.getPlaintext(vaultHandleAfterRedeem);
    expect(vaultBalanceAfterRedeem).to.be.gte(31_999_999n);

    const [encryptedWithdraw] = await userClient
      .encryptInputs([Encryptable.uint64(30_000_000n)])
      .setAccount(user.address)
      .execute();

    await time.increase(7 * 24 * 60 * 60);
    await vault.connect(user).withdrawConfidential(encryptedWithdraw, recipient.address);

    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const recipientBalance = await hre.cofhe.mocks.getPlaintext(recipientHandle);
    expect(recipientBalance).to.equal(30_000_000n);

    const vaultHandleAfterWithdraw = await wrappedToken.confidentialBalanceOf(await vault.getAddress());
    const vaultBalanceAfterWithdraw = await hre.cofhe.mocks.getPlaintext(vaultHandleAfterWithdraw);
    expect(vaultBalanceAfterWithdraw).to.be.gte(1_999_999n);
  });

  it("blocks non-coordinator strategy execution", async function () {
    const { user, vault } = await loadFixture(deployFixture);

    await expect(vault.connect(user).coordinatorDeployToStrategy(1_000_000, 1))
      .to.be.revertedWithCustomError(vault, "UnauthorizedCoordinator");
  });
});
