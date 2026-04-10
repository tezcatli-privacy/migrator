import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import hre from "hardhat";
import { Encryptable, FheTypes } from "@cofhe/sdk";
import { expect } from "chai";

const TASK_COFHE_MOCKS_DEPLOY = "task:cofhe-mocks:deploy";

describe("Tezcatli confidential vault", function () {
  async function deployFixture() {
    await hre.run(TASK_COFHE_MOCKS_DEPLOY);

    const [deployer, user, recipient, other] = await hre.ethers.getSigners();

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

    const FeeModel = await hre.ethers.getContractFactory("TezcatliVaultFeeModel");
    const feeModel = await FeeModel.deploy();
    await feeModel.waitForDeployment();

    await (await vault.setFeeModel(await feeModel.getAddress())).wait();
    await (await vault.setFeeRecipient(deployer.address)).wait();

    await (await usdc.mint(user.address, 100_000_000n)).wait();
    await (await usdc.connect(user).approve(await wrappedToken.getAddress(), 100_000_000n)).wait();
    await (await wrappedToken.connect(user).shield(30_000_000n)).wait();

    const userClient = await hre.cofhe.createClientWithBatteries(user);
    const recipientClient = await hre.cofhe.createClientWithBatteries(recipient);

    return {
      deployer,
      user,
      recipient,
      other,
      usdc,
      wrappedToken,
      vault,
      feeModel,
      userClient,
      recipientClient,
    };
  }

  it("accepts confidential deposits via transferAndCall and updates confidential shares", async function () {
    const { user, wrappedToken, vault, userClient } = await loadFixture(deployFixture);

    const depositAmount = 12_000_000n;
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

    const sharesHandle = await vault.confidentialSharesOf(user.address);
    const shares = await userClient.decryptForView(sharesHandle, FheTypes.Uint64).execute();
    expect(shares).to.equal(depositAmount);

    const vaultBalanceHandle = await wrappedToken.confidentialBalanceOf(await vault.getAddress());
    const vaultBalance = await hre.cofhe.mocks.getPlaintext(vaultBalanceHandle);
    expect(vaultBalance).to.equal(depositAmount);
  });

  it("supports confidential withdrawals and preserves user accounting", async function () {
    const { user, recipient, wrappedToken, vault, userClient, recipientClient } = await loadFixture(deployFixture);

    const depositAmount = 16_000_000n;
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

    const withdrawAmount = 5_000_000n;
    const [encryptedWithdraw] = await userClient
      .encryptInputs([Encryptable.uint64(withdrawAmount)])
      .setAccount(user.address)
      .execute();

    await time.increase(7 * 24 * 60 * 60);
    await vault.connect(user).withdrawConfidential(encryptedWithdraw, recipient.address);

    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const recipientBalance = await hre.cofhe.mocks.getPlaintext(recipientHandle);
    expect(recipientBalance).to.equal(withdrawAmount);

    const sharesHandle = await vault.confidentialSharesOf(user.address);
    const remainingShares = await hre.cofhe.mocks.getPlaintext(sharesHandle);
    expect(remainingShares).to.equal(depositAmount - withdrawAmount);
  });

  it("enforces a 7-day minimum withdrawal delay", async function () {
    const { user, wrappedToken, vault, userClient } = await loadFixture(deployFixture);

    const depositAmount = 6_000_000n;
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

    const [encryptedWithdraw] = await userClient
      .encryptInputs([Encryptable.uint64(1_000_000n)])
      .setAccount(user.address)
      .execute();

    await expect(vault.connect(user).withdrawConfidential(encryptedWithdraw, user.address))
      .to.be.revertedWithCustomError(vault, "WithdrawLocked");

    await time.increase(7 * 24 * 60 * 60);
    await expect(vault.connect(user).withdrawConfidential(encryptedWithdraw, user.address))
      .to.not.be.reverted;
  });

  it("blocks deposits and withdrawals while paused", async function () {
    const { user, wrappedToken, vault, userClient } = await loadFixture(deployFixture);

    await vault.pause();

    const [encryptedDeposit] = await userClient
      .encryptInputs([Encryptable.uint64(2_000_000n)])
      .setAccount(user.address)
      .execute();

    await expect(
      wrappedToken
        .connect(user)
        ["confidentialTransferAndCall(address,(uint256,uint8,uint8,bytes),bytes)"](
          await vault.getAddress(),
          encryptedDeposit,
          hre.ethers.AbiCoder.defaultAbiCoder().encode(["address"], [user.address]),
        ),
    ).to.be.revertedWithCustomError(vault, "EnforcedPause");

    const [encryptedWithdraw] = await userClient
      .encryptInputs([Encryptable.uint64(1_000_000n)])
      .setAccount(user.address)
      .execute();

    await expect(vault.connect(user).withdrawConfidential(encryptedWithdraw, user.address))
      .to.be.revertedWithCustomError(vault, "EnforcedPause");
  });

  it("stores lock option and decays fee over time", async function () {
    const { user, wrappedToken, vault, userClient } = await loadFixture(deployFixture);

    const depositAmount = 8_000_000n;
    const [encryptedDeposit] = await userClient
      .encryptInputs([Encryptable.uint64(depositAmount)])
      .setAccount(user.address)
      .execute();

    await wrappedToken
      .connect(user)
      ["confidentialTransferAndCall(address,(uint256,uint8,uint8,bytes),bytes)"](
        await vault.getAddress(),
        encryptedDeposit,
        hre.ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint8"], [user.address, 3]),
      );

    expect(await vault.hasLockOption(user.address)).to.equal(true);
    expect(await vault.lockOptionOf(user.address)).to.equal(3n);
    expect(await vault.currentWithdrawalFeeBps(user.address)).to.equal(500);

    await time.increase(540 * 24 * 60 * 60);
    expect(await vault.currentWithdrawalFeeBps(user.address)).to.equal(50);
  });

  it("applies 0.5% floor fee after full lock period for the 3-month option", async function () {
    const { user, wrappedToken, vault, userClient } = await loadFixture(deployFixture);

    const depositAmount = 4_000_000n;
    const [encryptedDeposit] = await userClient
      .encryptInputs([Encryptable.uint64(depositAmount)])
      .setAccount(user.address)
      .execute();

    await wrappedToken
      .connect(user)
      ["confidentialTransferAndCall(address,(uint256,uint8,uint8,bytes),bytes)"](
        await vault.getAddress(),
        encryptedDeposit,
        hre.ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint8"], [user.address, 0]),
      );

    expect(await vault.currentWithdrawalFeeBps(user.address)).to.equal(500);
    await time.increase(90 * 24 * 60 * 60);
    expect(await vault.currentWithdrawalFeeBps(user.address)).to.equal(50);
  });

  it("applies fee to realized yield only when lock option is configured", async function () {
    const { deployer, user, recipient, usdc, wrappedToken, vault, userClient, recipientClient } = await loadFixture(deployFixture);

    const depositAmount = 20_000_000n;
    const [encryptedDeposit] = await userClient
      .encryptInputs([Encryptable.uint64(depositAmount)])
      .setAccount(user.address)
      .execute();

    await wrappedToken
      .connect(user)
      ["confidentialTransferAndCall(address,(uint256,uint8,uint8,bytes),bytes)"](
        await vault.getAddress(),
        encryptedDeposit,
        hre.ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint8"], [user.address, 0]),
      );

    await (await usdc.mint(deployer.address, 5_000_000n)).wait();
    await (await usdc.connect(deployer).approve(await wrappedToken.getAddress(), 2_000_000n)).wait();
    await (await wrappedToken.connect(deployer).shieldTo(await vault.getAddress(), 2_000_000n)).wait();

    const [encryptedWithdraw] = await userClient
      .encryptInputs([Encryptable.uint64(depositAmount)])
      .setAccount(user.address)
      .execute();

    await time.increase(7 * 24 * 60 * 60);
    await vault.connect(user).withdrawConfidential(encryptedWithdraw, recipient.address);

    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const recipientBalance = await hre.cofhe.mocks.getPlaintext(recipientHandle);
    expect(recipientBalance).to.equal(21_907_000n);

    const feeRecipientHandle = await wrappedToken.confidentialBalanceOf(deployer.address);
    const feeRecipientBalance = await hre.cofhe.mocks.getPlaintext(feeRecipientHandle);
    expect(feeRecipientBalance).to.equal(93_000n);
  });

  it("factory creates one vault per asset", async function () {
    const { deployer, wrappedToken } = await loadFixture(deployFixture);

    const Factory = await hre.ethers.getContractFactory("TezcatliConfidentialVaultFactory");
    const factory = await Factory.deploy(deployer.address);
    await factory.waitForDeployment();

    await (await factory.createVault(await wrappedToken.getAddress(), deployer.address)).wait();

    const vaultAddress = await factory.vaultByAsset(await wrappedToken.getAddress());
    expect(vaultAddress).to.not.equal(hre.ethers.ZeroAddress);

    await expect(factory.createVault(await wrappedToken.getAddress(), deployer.address))
      .to.be.revertedWithCustomError(factory, "VaultAlreadyExists");
  });
});
