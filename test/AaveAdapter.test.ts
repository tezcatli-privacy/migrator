import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import hre from "hardhat";
import { expect } from "chai";

describe("Tezcatli Aave V3 adapter", function () {
  async function deployFixture() {
    const [deployer, vault, receiver] = await hre.ethers.getSigners();

    const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const MockAToken = await hre.ethers.getContractFactory("MockAToken");
    const aToken = await MockAToken.deploy("Aave USDC", "aUSDC");
    await aToken.waitForDeployment();

    const MockPool = await hre.ethers.getContractFactory("MockAaveV3Pool");
    const pool = await MockPool.deploy(await usdc.getAddress(), await aToken.getAddress());
    await pool.waitForDeployment();

    await (await aToken.setPool(await pool.getAddress())).wait();

    const Adapter = await hre.ethers.getContractFactory("TezcatliStrategyAdapterAaveV3");
    const adapter = await Adapter.deploy(
      vault.address,
      await usdc.getAddress(),
      await pool.getAddress(),
      await aToken.getAddress(),
      deployer.address,
    );
    await adapter.waitForDeployment();

    await (await usdc.mint(vault.address, 100_000_000n)).wait();
    await (await usdc.connect(vault).approve(await adapter.getAddress(), hre.ethers.MaxUint256)).wait();

    return {
      deployer,
      vault,
      receiver,
      usdc,
      aToken,
      pool,
      adapter,
    };
  }

  it("deploys and redeems with proportional yield accounting", async function () {
    const { deployer, vault, receiver, usdc, aToken, pool, adapter } = await loadFixture(deployFixture);

    await adapter.connect(vault).deploy(10_000_000n, 9_900_000n);
    expect(await adapter.managedShares()).to.equal(10_000_000n);
    expect(await aToken.balanceOf(await adapter.getAddress())).to.equal(10_000_000n);

    await (await usdc.mint(deployer.address, 2_000_000n)).wait();
    await (await usdc.connect(deployer).approve(await pool.getAddress(), 2_000_000n)).wait();
    await pool.connect(deployer).simulateYield(await adapter.getAddress(), 2_000_000n);

    expect(await adapter.totalManagedAssets()).to.equal(12_000_000n);

    await adapter.connect(vault).redeem(5_000_000n, 5_900_000n, receiver.address);
    expect(await usdc.balanceOf(receiver.address)).to.equal(6_000_000n);
    expect(await adapter.managedShares()).to.equal(5_000_000n);

    await adapter.connect(vault).redeem(5_000_000n, 5_900_000n, receiver.address);
    expect(await usdc.balanceOf(receiver.address)).to.equal(12_000_000n);
    expect(await adapter.managedShares()).to.equal(0n);
    expect(await adapter.totalManagedAssets()).to.equal(0n);
  });

  it("enforces minAssetsOut slippage protection", async function () {
    const { deployer, vault, receiver, usdc, pool, adapter } = await loadFixture(deployFixture);

    await adapter.connect(vault).deploy(10_000_000n, 9_900_000n);

    await (await usdc.mint(deployer.address, 1_000_000n)).wait();
    await (await usdc.connect(deployer).approve(await pool.getAddress(), 1_000_000n)).wait();
    await pool.connect(deployer).simulateYield(await adapter.getAddress(), 1_000_000n);

    await expect(
      adapter.connect(vault).redeem(5_000_000n, 5_600_000n, receiver.address),
    ).to.be.revertedWithCustomError(adapter, "SlippageExceeded");
  });
});
