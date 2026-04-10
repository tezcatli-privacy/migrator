import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Encryptable, FheTypes } from "@cofhe/sdk";
import { createCofheClient, getDeployment } from "./utils";

task("paymaster-demo", "Run a sponsored 4337 user-op after stealth migration").setAction(
  async (_, hre: HardhatRuntimeEnvironment) => {
    const { ethers, network } = hre;
    const [deployer, stealthSigner, accountOwner, recipientSigner] = await ethers.getSigners();

    const usdcAddress = getDeployment(network.name, "MockUSDC");
    const wrappedAddress = getDeployment(network.name, "TezcatliWrappedToken");
    const migratorAddress = getDeployment(network.name, "TezcatliMigrator");
    const entryPointAddress = getDeployment(network.name, "TezcatliEntryPointMock");
    const accountFactoryAddress = getDeployment(network.name, "Tezcatli4337AccountFactory");
    const paymasterAddress = getDeployment(network.name, "TezcatliPaymaster");

    if (!usdcAddress || !wrappedAddress || !migratorAddress || !entryPointAddress || !accountFactoryAddress || !paymasterAddress) {
      throw new Error(`Missing deployment for ${network.name}. Run hardhat deploy-migrator-stack first.`);
    }

    const usdc = await ethers.getContractAt("MockUSDC", usdcAddress);
    const wrappedToken = await ethers.getContractAt("TezcatliWrappedToken", wrappedAddress);
    const migrator = await ethers.getContractAt("TezcatliMigrator", migratorAddress);
    const entryPoint = await ethers.getContractAt("TezcatliEntryPointMock", entryPointAddress);
    const accountFactory = await ethers.getContractAt("Tezcatli4337AccountFactory", accountFactoryAddress);
    const paymaster = await ethers.getContractAt("TezcatliPaymaster", paymasterAddress);

    const salt = 7n;
    const accountAddress = await accountFactory.predictAccountAddress(accountOwner.address, salt);
    await (await accountFactory.createAccount(accountOwner.address, salt)).wait();
    const account = await ethers.getContractAt("Tezcatli4337Account", accountAddress);

    const migrationAmount = 25_000_000n;
    await (await usdc.mint(stealthSigner.address, 300_000_000n)).wait();
    await (await usdc.connect(stealthSigner).approve(migratorAddress, migrationAmount)).wait();

    const nonce = await migrator.nonces(stealthSigner.address);
    const deadline = Math.floor(Date.now() / 1000) + 3600;

    const authorization = {
      stealthAddress: stealthSigner.address,
      recipient: accountAddress,
      token: usdcAddress,
      confidentialToken: wrappedAddress,
      amount: migrationAmount,
      nonce,
      deadline: BigInt(deadline),
    };

    const digest = await migrator.getSweepDigest(authorization);
    const signature = await stealthSigner.signMessage(ethers.getBytes(digest));

    await (await migrator.sweepAndMigrate(
      {
        ...authorization,
        deadline,
      },
      signature,
    )).wait();

    await (await usdc.mint(accountAddress, 10_000_000n)).wait();
    const approvePaymasterCalldata = usdc.interface.encodeFunctionData("approve", [paymasterAddress, ethers.MaxUint256]);
    await (await account.connect(accountOwner).execute(usdcAddress, 0, approvePaymasterCalldata)).wait();

    const ownerClient = await createCofheClient(hre, accountOwner);
    const sponsoredTransferAmount = 7_000_000n;
    const [encryptedTransfer] = await ownerClient
      .encryptInputs([Encryptable.uint64(sponsoredTransferAmount)])
      .setAccount(accountAddress)
      .execute();

    const wrappedTransferCalldata = wrappedToken.interface.encodeFunctionData(
      "confidentialTransfer(address,(uint256,uint8,uint8,bytes))",
      [recipientSigner.address, encryptedTransfer],
    );
    const accountCallData = account.interface.encodeFunctionData("execute", [wrappedAddress, 0, wrappedTransferCalldata]);

    const userOp = {
      sender: accountAddress,
      nonce: 0n,
      initCode: "0x",
      callData: accountCallData,
      accountGasLimits: ethers.ZeroHash,
      preVerificationGas: 0n,
      gasFees: ethers.ZeroHash,
      paymasterAndData: ethers.solidityPacked(
        ["address", "uint256"],
        [paymasterAddress, sponsoredTransferAmount],
      ),
      signature: "0x",
    };

    const userOpHash = await entryPoint.getUserOpHash(userOp);
    userOp.signature = await accountOwner.signMessage(ethers.getBytes(userOpHash));

    const treasuryBefore = await usdc.balanceOf(deployer.address);
    await (await entryPoint.handleOps([userOp], deployer.address)).wait();
    const treasuryAfter = await usdc.balanceOf(deployer.address);

    const recipientClient = await createCofheClient(hre, recipientSigner);
    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipientSigner.address);
    const recipientBalance = await recipientClient
      .decryptForView(recipientHandle, FheTypes.Uint64)
      .execute();

    const feePaid = treasuryAfter - treasuryBefore;

    console.log(`4337 account: ${accountAddress}`);
    console.log(`Recipient confidential balance after sponsored op: ${recipientBalance.toString()}`);
    console.log(`Paymaster fee paid in USDC: ${feePaid.toString()}`);
  },
);
