import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import hre from "hardhat";

const TASK_COFHE_MOCKS_DEPLOY = "task:cofhe-mocks:deploy";

describe("TezcatliBatchMigratorPermit2", function () {
  async function futureDeadline(seconds = 3600) {
    const latest = await hre.ethers.provider.getBlock("latest");
    return BigInt((latest?.timestamp ?? 0) + seconds);
  }

  async function deployFixture() {
    await hre.run(TASK_COFHE_MOCKS_DEPLOY);

    const [deployer, owner] = await hre.ethers.getSigners();

    const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const MockERC20 = await hre.ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy("Mock Tether USD", "USDT", 6);
    await usdt.waitForDeployment();

    const WrappedToken = await hre.ethers.getContractFactory("TezcatliWrappedToken");
    const wrappedUsdc = await WrappedToken.deploy(
      "Tezcatli Confidential USD Coin",
      "tzcUSDC",
      await usdc.getAddress(),
      6,
    );
    await wrappedUsdc.waitForDeployment();

    const wrappedUsdt = await WrappedToken.deploy(
      "Tezcatli Confidential Tether",
      "tzcUSDT",
      await usdt.getAddress(),
      6,
    );
    await wrappedUsdt.waitForDeployment();

    const EntryPoint = await hre.ethers.getContractFactory("TezcatliEntryPointMock");
    const entryPoint = await EntryPoint.deploy();
    await entryPoint.waitForDeployment();

    const Smart4337Factory = await hre.ethers.getContractFactory("Tezcatli4337AccountFactory");
    const smart4337Factory = await Smart4337Factory.deploy(await entryPoint.getAddress());
    await smart4337Factory.waitForDeployment();

    const MockPermit2 = await hre.ethers.getContractFactory("MockPermit2");
    const mockPermit2 = await MockPermit2.deploy();
    await mockPermit2.waitForDeployment();

    const BatchMigrator = await hre.ethers.getContractFactory("TezcatliBatchMigratorPermit2");
    const batchMigrator = await BatchMigrator.deploy(await mockPermit2.getAddress(), await smart4337Factory.getAddress());
    await batchMigrator.waitForDeployment();

    const MockComplianceGate = await hre.ethers.getContractFactory("MockComplianceGate");
    const complianceGate = await MockComplianceGate.deploy();
    await complianceGate.waitForDeployment();

    await (await batchMigrator.setWrappedTokens(
      [await usdc.getAddress(), await usdt.getAddress()],
      [await wrappedUsdc.getAddress(), await wrappedUsdt.getAddress()],
    )).wait();

    await (await usdc.mint(owner.address, 100_000_000n)).wait();
    await (await usdt.mint(owner.address, 200_000_000n)).wait();

    await (await usdc.connect(owner).approve(await mockPermit2.getAddress(), hre.ethers.MaxUint256)).wait();
    await (await usdt.connect(owner).approve(await mockPermit2.getAddress(), hre.ethers.MaxUint256)).wait();

    return {
      deployer,
      owner,
      usdc,
      usdt,
      wrappedUsdc,
      wrappedUsdt,
      smart4337Factory,
      mockPermit2,
      batchMigrator,
      complianceGate,
    };
  }

  it("creates a 4337 account and migrates multiple ERC20s in one batch", async function () {
    const {
      owner,
      usdc,
      usdt,
      wrappedUsdc,
      wrappedUsdt,
      smart4337Factory,
      batchMigrator,
    } = await loadFixture(deployFixture);

    const salt = 77n;
    const deadline = await futureDeadline();
    const predictedAccount = await smart4337Factory.predictAccountAddress(owner.address, salt);

    await batchMigrator.createAccountAndMigrateBatchWithPermit2(
      owner.address,
      salt,
      {
        details: [
          {
            token: await usdc.getAddress(),
            amount: 24_000_000n,
            expiration: deadline,
            nonce: 0,
          },
          {
            token: await usdt.getAddress(),
            amount: 51_000_000n,
            expiration: deadline,
            nonce: 0,
          },
        ],
        spender: await batchMigrator.getAddress(),
        sigDeadline: deadline,
      },
      "0x1234",
    );

    expect(await hre.ethers.provider.getCode(predictedAccount)).to.not.equal("0x");

    const usdcHandle = await wrappedUsdc.confidentialBalanceOf(predictedAccount);
    const usdtHandle = await wrappedUsdt.confidentialBalanceOf(predictedAccount);
    expect(await hre.cofhe.mocks.getPlaintext(usdcHandle)).to.equal(24_000_000n);
    expect(await hre.cofhe.mocks.getPlaintext(usdtHandle)).to.equal(51_000_000n);

    expect(await usdc.balanceOf(owner.address)).to.equal(76_000_000n);
    expect(await usdt.balanceOf(owner.address)).to.equal(149_000_000n);
  });

  it("blocks the batch when compliance rejects shielding into the new account", async function () {
    const { owner, usdc, batchMigrator, complianceGate } = await loadFixture(deployFixture);

    await (await batchMigrator.setComplianceGate(await complianceGate.getAddress())).wait();
    await (await batchMigrator.setComplianceEnabled(true)).wait();
    await (await complianceGate.setShieldDecision(false, 7)).wait();

    const salt = 91n;
    const deadline = await futureDeadline();

    await expect(
      batchMigrator.createAccountAndMigrateBatchWithPermit2(
        owner.address,
        salt,
        {
          details: [
            {
              token: await usdc.getAddress(),
              amount: 10_000_000n,
              expiration: deadline,
              nonce: 0,
            },
          ],
          spender: await batchMigrator.getAddress(),
          sigDeadline: deadline,
        },
        "0x1234",
      ),
    ).to.be.revertedWithCustomError(batchMigrator, "ComplianceRejected");
  });
});
