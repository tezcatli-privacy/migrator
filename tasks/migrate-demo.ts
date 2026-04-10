import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Encryptable, FheTypes } from "@cofhe/sdk";
import { createCofheClient, getDeployment } from "./utils";

task("migrate-demo", "Run a demo stealth-to-smart-account migration on the selected network").setAction(
  async (_, hre: HardhatRuntimeEnvironment) => {
    const { ethers, network } = hre;
    const [stealthSigner, accountOwner, recipientSigner] = await ethers.getSigners();

    const usdcAddress = getDeployment(network.name, "MockUSDC");
    const wrappedAddress = getDeployment(network.name, "TezcatliWrappedToken");
    const migratorAddress = getDeployment(network.name, "TezcatliMigrator");
    const smartAccountFactoryAddress = getDeployment(network.name, "TezcatliSmartAccountFactory");

    if (!usdcAddress || !wrappedAddress || !migratorAddress || !smartAccountFactoryAddress) {
      throw new Error(`Missing deployment for ${network.name}. Run hardhat deploy-migrator-stack first.`);
    }

    const usdc = await ethers.getContractAt("MockUSDC", usdcAddress);
    const wrappedToken = await ethers.getContractAt("TezcatliWrappedToken", wrappedAddress);
    const migrator = await ethers.getContractAt("TezcatliMigrator", migratorAddress);
    const smartAccountFactory = await ethers.getContractAt("TezcatliSmartAccountFactory", smartAccountFactoryAddress);

    const salt = 1n;
    const smartAccountAddress = await smartAccountFactory.predictAccountAddress(accountOwner.address, salt);
    await (await smartAccountFactory.createAccount(accountOwner.address, salt)).wait();

    await (await usdc.mint(stealthSigner.address, 250_000_000n)).wait();
    await (await usdc.connect(stealthSigner).approve(migratorAddress, 25_000_000n)).wait();

    const deadline = Math.floor(Date.now() / 1000) + 3600;
    const nonce = await migrator.nonces(stealthSigner.address);
    const digest = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "address", "address", "address", "address", "uint256", "uint256", "uint256"],
        [
          migratorAddress,
          BigInt((await ethers.provider.getNetwork()).chainId),
          stealthSigner.address,
          smartAccountAddress,
          usdcAddress,
          wrappedAddress,
          25_000_000n,
          nonce,
          BigInt(deadline),
        ],
      ),
    );
    const signature = await stealthSigner.signMessage(ethers.getBytes(digest));

    await (
      await migrator.sweepAndMigrate(
        {
          stealthAddress: stealthSigner.address,
          recipient: smartAccountAddress,
          token: usdcAddress,
          confidentialToken: wrappedAddress,
          amount: 25_000_000n,
          nonce,
          deadline,
        },
        signature,
      )
    ).wait();

    const ownerClient = await createCofheClient(hre, accountOwner);
    const [encryptedTransfer] = await ownerClient
      .encryptInputs([Encryptable.uint64(5_000_000n)])
      .setAccount(smartAccountAddress)
      .execute();

    const smartAccount = await ethers.getContractAt("TezcatliSmartAccount", smartAccountAddress);
    const transferCalldata = wrappedToken.interface.encodeFunctionData(
      "confidentialTransfer(address,(uint256,uint8,uint8,bytes))",
      [recipientSigner.address, encryptedTransfer],
    );

    await (
      await smartAccount.connect(accountOwner).execute(
        wrappedAddress,
        0,
        transferCalldata,
      )
    ).wait();

    const recipientClient = await createCofheClient(hre, recipientSigner);
    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipientSigner.address);
    const receivedBalance = await recipientClient
      .decryptForView(recipientHandle, FheTypes.Uint64)
      .execute();

    console.log(`Smart account deployed at: ${smartAccountAddress}`);
    console.log(`Recipient confidential balance after smart-account transfer: ${receivedBalance.toString()}`);
  },
);
