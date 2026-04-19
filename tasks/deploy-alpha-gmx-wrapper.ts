import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadSharedManifest, saveDeployment, saveSharedManifest } from "./utils";

const DEFAULT_AAVE_ARB_SEPOLIA_USDC = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d";
const DEFAULT_AAVE_ARB_SEPOLIA_WETH = "0x1dF462e2712496373A347f8ad10802a5E95f053D";

const parseAddressList = (raw: string | undefined, fallback: string[]) =>
  (raw ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter((value) => value.length > 0)
    .concat((raw ?? "").trim().length === 0 ? fallback : []);

task("deploy-alpha-gmx-wrapper", "Deploy the GMX privacy wrapper and wire it into the shared alpha manifest").setAction(
  async (_, hre: HardhatRuntimeEnvironment) => {
    const { ethers, network } = hre;
    const [deployer] = await ethers.getSigners();
    const chainId = Number((await ethers.provider.getNetwork()).chainId);

    const gmxRouter = process.env.GMX_EXCHANGE_ROUTER_ADDRESS?.trim();
    if (!gmxRouter) {
      throw new Error("GMX_EXCHANGE_ROUTER_ADDRESS is required");
    }

    const collateralTokens = parseAddressList(process.env.GMX_COLLATERAL_TOKEN_ADDRESSES, [
      DEFAULT_AAVE_ARB_SEPOLIA_USDC,
      DEFAULT_AAVE_ARB_SEPOLIA_WETH,
    ]);

    const Wrapper = await ethers.getContractFactory("TezcatliGmxPrivacyWrapper");
    const wrapper = await Wrapper.deploy(deployer.address);
    await wrapper.waitForDeployment();

    await (await wrapper.setApprovedRouter(gmxRouter, true)).wait();
    for (const token of collateralTokens) {
      await (await wrapper.setApprovedCollateralToken(token, true)).wait();
    }

    const wrapperAddress = await wrapper.getAddress();
    saveDeployment(network.name, "TezcatliGmxPrivacyWrapper", wrapperAddress);

    const manifest = loadSharedManifest("arbitrum-sepolia");
    const currentMigrator = manifest?.migrator ?? {};
    const currentDefi =
      typeof currentMigrator.defi === "object" && currentMigrator.defi !== null
        ? (currentMigrator.defi as Record<string, unknown>)
        : {};

    saveSharedManifest("arbitrum-sepolia", chainId, "migrator", {
      defi: {
        ...currentDefi,
        buyGoldAdapter: wrapperAddress,
        gmxRouter,
        gmxCollateralTokens: collateralTokens,
      },
    });

    console.log(`TezcatliGmxPrivacyWrapper: ${wrapperAddress}`);
    console.log(`Approved GMX router: ${gmxRouter}`);
    console.log(`Approved collateral tokens: ${collateralTokens.join(", ")}`);
  },
);
