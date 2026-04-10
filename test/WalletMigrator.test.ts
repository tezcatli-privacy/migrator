import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import hre from "hardhat";
import { Encryptable, FheTypes } from "@cofhe/sdk";
import { PermitUtils } from "@cofhe/sdk/permits";
import { expect } from "chai";

const TASK_COFHE_MOCKS_DEPLOY = "task:cofhe-mocks:deploy";

describe("Tezcatli wallet migrator", function () {
  async function buildSweepDigest(
    migratorAddress: string,
    chainId: bigint,
    stealthAddress: string,
    recipient: string,
    token: string,
    confidentialToken: string,
    amount: bigint,
    nonce: bigint,
    deadline: bigint,
  ) {
    return hre.ethers.keccak256(
      hre.ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "address", "address", "address", "address", "uint256", "uint256", "uint256"],
        [
          migratorAddress,
          chainId,
          stealthAddress,
          recipient,
          token,
          confidentialToken,
          amount,
          nonce,
          deadline,
        ],
      ),
    );
  }

  async function buildDustSwapDigest(
    migratorAddress: string,
    chainId: bigint,
    stealthAddress: string,
    recipient: string,
    dustToken: string,
    confidentialToken: string,
    dustSwap: string,
    dustAmount: bigint,
    minSettlementAmount: bigint,
    nonce: bigint,
    deadline: bigint,
  ) {
    return hre.ethers.keccak256(
      hre.ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "address", "address", "address", "address", "address", "uint256", "uint256", "uint256", "uint256"],
        [
          migratorAddress,
          chainId,
          stealthAddress,
          recipient,
          dustToken,
          confidentialToken,
          dustSwap,
          dustAmount,
          minSettlementAmount,
          nonce,
          deadline,
        ],
      ),
    );
  }

  async function deployFixture() {
    await hre.run(TASK_COFHE_MOCKS_DEPLOY);

    const [deployer, stealthSigner, recipient, secondStealthSigner, accountOwner] = await hre.ethers.getSigners();

    const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const MockDustToken = await hre.ethers.getContractFactory("MockDustToken");
    const dustToken = await MockDustToken.deploy();
    await dustToken.waitForDeployment();

    const WrappedToken = await hre.ethers.getContractFactory("TezcatliWrappedToken");
    const wrappedToken = await WrappedToken.deploy(
      "Tezcatli Confidential USD",
      "tzcUSD",
      await usdc.getAddress(),
      6,
    );
    await wrappedToken.waitForDeployment();

    const Registry = await hre.ethers.getContractFactory("TezcatliStealthRegistry");
    const registry = await Registry.deploy();
    await registry.waitForDeployment();

    const Announcer = await hre.ethers.getContractFactory("TezcatliStealthAnnouncer");
    const announcer = await Announcer.deploy();
    await announcer.waitForDeployment();

    const Migrator = await hre.ethers.getContractFactory("TezcatliMigrator");
    const migrator = await Migrator.deploy();
    await migrator.waitForDeployment();

    const DustSwap = await hre.ethers.getContractFactory("TezcatliDustSwap");
    const dustSwap = await DustSwap.deploy(
      await usdc.getAddress(),
      deployer.address,
    );
    await dustSwap.waitForDeployment();

    const SmartAccountFactory = await hre.ethers.getContractFactory("TezcatliSmartAccountFactory");
    const smartAccountFactory = await SmartAccountFactory.deploy();
    await smartAccountFactory.waitForDeployment();

    await (await usdc.mint(deployer.address, 2_500_000_000n)).wait();
    await (await usdc.mint(stealthSigner.address, 500_000_000n)).wait();
    await (await usdc.mint(secondStealthSigner.address, 500_000_000n)).wait();
    await (await dustToken.mint(stealthSigner.address, 100_000_000_000_000_000_000n)).wait();
    await (await dustToken.mint(secondStealthSigner.address, 100_000_000_000_000_000_000n)).wait();

    await (await usdc.connect(deployer).approve(await dustSwap.getAddress(), 1_000_000_000n)).wait();
    await (await dustSwap.connect(deployer).fundSettlement(1_000_000_000n)).wait();
    await (await dustSwap.connect(deployer).setRate(
      await dustToken.getAddress(),
      2_000_000n,
      1_000_000_000_000_000_000n,
      true,
    )).wait();

    const deployerClient = await hre.cofhe.createClientWithBatteries(deployer);
    const stealthClient = await hre.cofhe.createClientWithBatteries(stealthSigner);
    const recipientClient = await hre.cofhe.createClientWithBatteries(recipient);

    return {
      deployer,
      stealthSigner,
      secondStealthSigner,
      recipient,
      accountOwner,
      usdc,
      dustToken,
      wrappedToken,
      registry,
      announcer,
      migrator,
      dustSwap,
      smartAccountFactory,
      deployerClient,
      stealthClient,
      recipientClient,
    };
  }

  it("registers a stealth meta-address", async function () {
    const { stealthSigner, registry } = await loadFixture(deployFixture);
    const metaAddress = "0x" + "11".repeat(66);

    await registry.connect(stealthSigner).registerStealthMetaAddress(1, metaAddress);

    expect(await registry.stealthMetaAddressOf(stealthSigner.address, 1)).to.equal(metaAddress);
  });

  it("announces and transfers public funds to a stealth address", async function () {
    const { deployer, stealthSigner, announcer, usdc } = await loadFixture(deployFixture);

    await usdc.connect(deployer).approve(await announcer.getAddress(), 12_500_000n);

    await announcer.connect(deployer).announceAndTransfer(
      1,
      stealthSigner.address,
      "0x1234",
      "0xabcd",
      await usdc.getAddress(),
      12_500_000n,
    );

    expect(await usdc.balanceOf(stealthSigner.address)).to.equal(512_500_000n);
  });

  it("sweeps public funds from a stealth address into a confidential balance", async function () {
    const { stealthSigner, recipient, usdc, wrappedToken, migrator, recipientClient } =
      await loadFixture(deployFixture);

    const amount = 25_000_000n;
    await usdc.connect(stealthSigner).approve(await migrator.getAddress(), amount);

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const nonce = await migrator.nonces(stealthSigner.address);
    const digest = await buildSweepDigest(
      await migrator.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      recipient.address,
      await usdc.getAddress(),
      await wrappedToken.getAddress(),
      amount,
      nonce,
      deadline,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    await hre.cofhe.mocks.withLogs("migrator.sweepAndMigrate()", async () => {
      await migrator.sweepAndMigrate(
        {
          stealthAddress: stealthSigner.address,
          recipient: recipient.address,
          token: await usdc.getAddress(),
          confidentialToken: await wrappedToken.getAddress(),
          amount,
          nonce,
          deadline,
        },
        signature,
      );
    });

    expect(await usdc.balanceOf(stealthSigner.address)).to.equal(475_000_000n);
    expect(await usdc.balanceOf(await wrappedToken.getAddress())).to.equal(amount);

    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const decrypted = await recipientClient
      .decryptForView(recipientHandle, FheTypes.Uint64)
      .execute();
    expect(decrypted).to.equal(amount);
  });

  it("lets the recipient unshield confidential funds back to the underlying token", async function () {
    const { stealthSigner, recipient, usdc, wrappedToken, migrator, recipientClient } =
      await loadFixture(deployFixture);

    const amount = 40_000_000n;
    await usdc.connect(stealthSigner).approve(await migrator.getAddress(), amount);

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const nonce = await migrator.nonces(stealthSigner.address);
    const digest = await buildSweepDigest(
      await migrator.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      recipient.address,
      await usdc.getAddress(),
      await wrappedToken.getAddress(),
      amount,
      nonce,
      deadline,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    await migrator.sweepAndMigrate(
      {
        stealthAddress: stealthSigner.address,
        recipient: recipient.address,
        token: await usdc.getAddress(),
        confidentialToken: await wrappedToken.getAddress(),
        amount,
        nonce,
        deadline,
      },
      signature,
    );

    await wrappedToken.connect(recipient).unshield(15_000_000n);

    expect(await usdc.balanceOf(recipient.address)).to.equal(15_000_000n);

    const handle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const decrypted = await recipientClient
      .decryptForView(handle, FheTypes.Uint64)
      .execute();
    expect(decrypted).to.equal(25_000_000n);
  });

  it("supports dust swaps into confidential USDC balances", async function () {
    const { stealthSigner, recipient, dustToken, wrappedToken, migrator, dustSwap, recipientClient } =
      await loadFixture(deployFixture);

    const dustAmount = 3_000_000_000_000_000_000n;
    const minSettlementAmount = 5_900_000n;

    await dustToken.connect(stealthSigner).approve(await migrator.getAddress(), dustAmount);

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const nonce = await migrator.nonces(stealthSigner.address);
    const digest = await buildDustSwapDigest(
      await migrator.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      recipient.address,
      await dustToken.getAddress(),
      await wrappedToken.getAddress(),
      await dustSwap.getAddress(),
      dustAmount,
      minSettlementAmount,
      nonce,
      deadline,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    await migrator.sweepSwapAndMigrate(
      {
        stealthAddress: stealthSigner.address,
        recipient: recipient.address,
        dustToken: await dustToken.getAddress(),
        confidentialToken: await wrappedToken.getAddress(),
        dustSwap: await dustSwap.getAddress(),
        dustAmount,
        minSettlementAmount,
        nonce,
        deadline,
      },
      signature,
    );

    expect(await dustToken.balanceOf(stealthSigner.address)).to.equal(97_000_000_000_000_000_000n);
    expect(await dustToken.balanceOf(await dustSwap.getAddress())).to.equal(dustAmount);
    expect(await wrappedToken.confidentialBalanceOf(recipient.address)).to.not.equal(hre.ethers.ZeroHash);

    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const decrypted = await recipientClient
      .decryptForView(recipientHandle, FheTypes.Uint64)
      .execute();
    expect(decrypted).to.equal(6_000_000n);
  });

  it("supports confidential transfers after migration completes", async function () {
    const { deployer, stealthSigner, recipient, usdc, wrappedToken, migrator, deployerClient, recipientClient } =
      await loadFixture(deployFixture);

    const amount = 30_000_000n;
    await usdc.connect(stealthSigner).approve(await migrator.getAddress(), amount);

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const nonce = await migrator.nonces(stealthSigner.address);
    const digest = await buildSweepDigest(
      await migrator.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      recipient.address,
      await usdc.getAddress(),
      await wrappedToken.getAddress(),
      amount,
      nonce,
      deadline,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    await migrator.sweepAndMigrate(
      {
        stealthAddress: stealthSigner.address,
        recipient: recipient.address,
        token: await usdc.getAddress(),
        confidentialToken: await wrappedToken.getAddress(),
        amount,
        nonce,
        deadline,
      },
      signature,
    );

    const [encryptedTransfer] = await recipientClient
      .encryptInputs([Encryptable.uint64(7_000_000n)])
      .setAccount(recipient.address)
      .execute();

    await wrappedToken
      .connect(recipient)
      ["confidentialTransfer(address,(uint256,uint8,uint8,bytes))"](deployer.address, encryptedTransfer);

    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const recipientBalance = await recipientClient
      .decryptForView(recipientHandle, FheTypes.Uint64)
      .execute();
    expect(recipientBalance).to.equal(23_000_000n);

    const deployerHandle = await wrappedToken.confidentialBalanceOf(deployer.address);
    const received = await deployerClient
      .decryptForView(deployerHandle, FheTypes.Uint64)
      .execute();
    expect(received).to.equal(7_000_000n);
  });

  it("supports a smart-account destination and outbound confidential transfers", async function () {
    const {
      stealthSigner,
      recipient,
      accountOwner,
      usdc,
      wrappedToken,
      migrator,
      smartAccountFactory,
      recipientClient,
    } = await loadFixture(deployFixture);

    const salt = 7n;
    const smartAccountAddress = await smartAccountFactory.predictAccountAddress(accountOwner.address, salt);
    await (await smartAccountFactory.createAccount(accountOwner.address, salt)).wait();

    const amount = 27_000_000n;
    await usdc.connect(stealthSigner).approve(await migrator.getAddress(), amount);

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const nonce = await migrator.nonces(stealthSigner.address);
    const digest = await buildSweepDigest(
      await migrator.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      smartAccountAddress,
      await usdc.getAddress(),
      await wrappedToken.getAddress(),
      amount,
      nonce,
      deadline,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    await migrator.sweepAndMigrate(
      {
        stealthAddress: stealthSigner.address,
        recipient: smartAccountAddress,
        token: await usdc.getAddress(),
        confidentialToken: await wrappedToken.getAddress(),
        amount,
        nonce,
        deadline,
      },
      signature,
    );

    const smartAccount = await hre.ethers.getContractAt("TezcatliSmartAccount", smartAccountAddress);
    const ownerClient = await hre.cofhe.createClientWithBatteries(accountOwner);
    const [encryptedTransfer] = await ownerClient
      .encryptInputs([Encryptable.uint64(9_000_000n)])
      .setAccount(smartAccountAddress)
      .execute();

    const transferCalldata = wrappedToken.interface.encodeFunctionData(
      "confidentialTransfer(address,(uint256,uint8,uint8,bytes))",
      [recipient.address, encryptedTransfer],
    );

    await smartAccount.connect(accountOwner).execute(
      await wrappedToken.getAddress(),
      0,
      transferCalldata,
    );

    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const recipientBalance = await recipientClient
      .decryptForView(recipientHandle, FheTypes.Uint64)
      .execute();
    expect(recipientBalance).to.equal(9_000_000n);

    const smartAccountHandle = await wrappedToken.confidentialBalanceOf(smartAccountAddress);
    const smartAccountBalance = await hre.cofhe.mocks.getPlaintext(smartAccountHandle);
    expect(smartAccountBalance).to.equal(18_000_000n);
  });

  it("supports batching multiple stealth-address migrations in one call", async function () {
    const { deployer, stealthSigner, secondStealthSigner, recipient, usdc, wrappedToken, migrator, deployerClient, recipientClient } =
      await loadFixture(deployFixture);

    const firstAmount = 11_000_000n;
    const secondAmount = 19_000_000n;

    await usdc.connect(stealthSigner).approve(await migrator.getAddress(), firstAmount);
    await usdc.connect(secondStealthSigner).approve(await migrator.getAddress(), secondAmount);

    const chainId = BigInt((await hre.ethers.provider.getNetwork()).chainId);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

    const firstNonce = await migrator.nonces(stealthSigner.address);
    const firstDigest = await buildSweepDigest(
      await migrator.getAddress(),
      chainId,
      stealthSigner.address,
      recipient.address,
      await usdc.getAddress(),
      await wrappedToken.getAddress(),
      firstAmount,
      firstNonce,
      deadline,
    );
    const firstSignature = await stealthSigner.signMessage(hre.ethers.getBytes(firstDigest));

    const secondNonce = await migrator.nonces(secondStealthSigner.address);
    const secondDigest = await buildSweepDigest(
      await migrator.getAddress(),
      chainId,
      secondStealthSigner.address,
      deployer.address,
      await usdc.getAddress(),
      await wrappedToken.getAddress(),
      secondAmount,
      secondNonce,
      deadline,
    );
    const secondSignature = await secondStealthSigner.signMessage(hre.ethers.getBytes(secondDigest));

    await hre.cofhe.mocks.withLogs("migrator.sweepAndMigrateBatch()", async () => {
      await migrator.sweepAndMigrateBatch(
        [
          {
            stealthAddress: stealthSigner.address,
            recipient: recipient.address,
            token: await usdc.getAddress(),
            confidentialToken: await wrappedToken.getAddress(),
            amount: firstAmount,
            nonce: firstNonce,
            deadline,
          },
          {
            stealthAddress: secondStealthSigner.address,
            recipient: deployer.address,
            token: await usdc.getAddress(),
            confidentialToken: await wrappedToken.getAddress(),
            amount: secondAmount,
            nonce: secondNonce,
            deadline,
          },
        ],
        [firstSignature, secondSignature],
      );
    });

    expect(await migrator.nonces(stealthSigner.address)).to.equal(1n);
    expect(await migrator.nonces(secondStealthSigner.address)).to.equal(1n);
    expect(await usdc.balanceOf(stealthSigner.address)).to.equal(489_000_000n);
    expect(await usdc.balanceOf(secondStealthSigner.address)).to.equal(481_000_000n);
    expect(await usdc.balanceOf(await wrappedToken.getAddress())).to.equal(firstAmount + secondAmount);

    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipient.address);
    const recipientBalance = await recipientClient
      .decryptForView(recipientHandle, FheTypes.Uint64)
      .execute();
    expect(recipientBalance).to.equal(firstAmount);

    const deployerHandle = await wrappedToken.confidentialBalanceOf(deployer.address);
    const deployerBalance = await deployerClient
      .decryptForView(deployerHandle, FheTypes.Uint64)
      .execute();
    expect(deployerBalance).to.equal(secondAmount);
  });

  it("keeps permit validation available in the project surface", async function () {
    const { stealthSigner, stealthClient } = await loadFixture(deployFixture);

    const permit = await stealthClient.permits.createSelf({
      issuer: stealthSigner.address,
      name: "Migration Permit",
    });

    const isValid = await PermitUtils.checkValidityOnChain(
      permit,
      stealthClient.getSnapshot().publicClient!,
    );

    expect(isValid).to.be.true;
  });
});
