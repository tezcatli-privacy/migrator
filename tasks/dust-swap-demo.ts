import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { FheTypes } from "@cofhe/sdk";
import { createCofheClient, getDeployment } from "./utils";

task("dust-swap-demo", "Run a demo stealth dust-swap migration into confidential USDC").setAction(
  async (_, hre: HardhatRuntimeEnvironment) => {
    const { ethers, network } = hre;
    const [stealthSigner, recipientSigner] = await ethers.getSigners();

    const dustTokenAddress = getDeployment(network.name, "MockDustToken");
    const wrappedAddress = getDeployment(network.name, "TezcatliWrappedToken");
    const migratorAddress = getDeployment(network.name, "TezcatliMigrator");
    const dustSwapAddress = getDeployment(network.name, "TezcatliDustSwap");

    if (!dustTokenAddress || !wrappedAddress || !migratorAddress || !dustSwapAddress) {
      throw new Error(`Missing deployment for ${network.name}. Run hardhat deploy-migrator-stack first.`);
    }

    const dustToken = await ethers.getContractAt("MockDustToken", dustTokenAddress);
    const wrappedToken = await ethers.getContractAt("TezcatliWrappedToken", wrappedAddress);
    const migrator = await ethers.getContractAt("TezcatliMigrator", migratorAddress);

    const dustAmount = 3_000_000_000_000_000_000n;
    const minSettlementAmount = 5_900_000n;

    await (await dustToken.mint(stealthSigner.address, 10_000_000_000_000_000_000n)).wait();
    await (await dustToken.connect(stealthSigner).approve(migratorAddress, dustAmount)).wait();

    const deadline = Math.floor(Date.now() / 1000) + 3600;
    const nonce = await migrator.nonces(stealthSigner.address);
    const digest = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "address", "address", "address", "address", "address", "uint256", "uint256", "uint256", "uint256"],
        [
          migratorAddress,
          BigInt((await ethers.provider.getNetwork()).chainId),
          stealthSigner.address,
          recipientSigner.address,
          dustTokenAddress,
          wrappedAddress,
          dustSwapAddress,
          dustAmount,
          minSettlementAmount,
          nonce,
          BigInt(deadline),
        ],
      ),
    );
    const signature = await stealthSigner.signMessage(ethers.getBytes(digest));

    await (
      await migrator.sweepSwapAndMigrate(
        {
          stealthAddress: stealthSigner.address,
          recipient: recipientSigner.address,
          dustToken: dustTokenAddress,
          confidentialToken: wrappedAddress,
          dustSwap: dustSwapAddress,
          dustAmount,
          minSettlementAmount,
          nonce,
          deadline,
        },
        signature,
      )
    ).wait();

    const recipientClient = await createCofheClient(hre, recipientSigner);
    const recipientHandle = await wrappedToken.confidentialBalanceOf(recipientSigner.address);
    const recipientBalance = await recipientClient
      .decryptForView(recipientHandle, FheTypes.Uint64)
      .execute();

    console.log(`Recipient confidential balance after dust swap: ${recipientBalance.toString()}`);
  },
);
