import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import hre from "hardhat";
import { expect } from "chai";

describe("Tezcatli Morpho vault adapter", function () {
  async function deployFixture() {
    const [deployer, vault, receiver] = await hre.ethers.getSigners();

    const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const MockYieldVault = await hre.ethers.getContractFactory("MockYieldVault");
    const morphoVault = await MockYieldVault.deploy(await usdc.getAddress());
    await morphoVault.waitForDeployment();

    const Adapter = await hre.ethers.getContractFactory("TezcatliStrategyAdapterMorphoVault");
    const adapter = await Adapter.deploy(
      vault.address,
      await usdc.getAddress(),
      await morphoVault.getAddress(),
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
      morphoVault,
      adapter,
    };
  }

  it("deploys and redeems against a Morpho-style ERC-4626 vault", async function () {
    const { deployer, vault, receiver, usdc, morphoVault, adapter } = await loadFixture(deployFixture);

    await adapter.connect(vault).deploy(10_000_000n, 9_900_000n);
    expect(await adapter.managedShares()).to.equal(10_000_000n);

    await (await usdc.mint(deployer.address, 2_000_000n)).wait();
    await (await usdc.connect(deployer).approve(await morphoVault.getAddress(), 2_000_000n)).wait();
    await morphoVault.connect(deployer).donate(2_000_000n);

    const managedAssets = await adapter.totalManagedAssets();
    expect(managedAssets).to.be.gte(11_999_999n);
    expect(managedAssets).to.be.lte(12_000_000n);

    await adapter.connect(vault).redeem(5_000_000n, 5_900_000n, receiver.address);
    const firstReceiverBalance = await usdc.balanceOf(receiver.address);
    expect(firstReceiverBalance).to.be.gte(5_999_999n);
    expect(firstReceiverBalance).to.be.lte(6_000_000n);
    expect(await adapter.managedShares()).to.equal(5_000_000n);

    await adapter.connect(vault).redeem(5_000_000n, 5_900_000n, receiver.address);
    const finalReceiverBalance = await usdc.balanceOf(receiver.address);
    expect(finalReceiverBalance).to.be.gte(11_999_999n);
    expect(finalReceiverBalance).to.be.lte(12_000_000n);
    expect(await adapter.managedShares()).to.equal(0n);
  });

  it("enforces slippage bounds", async function () {
    const { vault, receiver, adapter } = await loadFixture(deployFixture);

    await adapter.connect(vault).deploy(10_000_000n, 9_900_000n);

    await expect(
      adapter.connect(vault).redeem(5_000_000n, 6_000_001n, receiver.address),
    ).to.be.revertedWithCustomError(adapter, "SlippageExceeded");
  });
});
