import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { saveDeployment } from "./utils";

task("deploy-migrator-stack", "Deploy the Tezcatli wallet migrator MVP").setAction(
  async (_, hre: HardhatRuntimeEnvironment) => {
    const { ethers, network } = hre;
    const [deployer] = await ethers.getSigners();

    console.log(`Deploying Tezcatli migrator stack to ${network.name} with ${deployer.address}`);

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockDustToken = await ethers.getContractFactory("MockDustToken");
    const mockDustToken = await MockDustToken.deploy();
    await mockDustToken.waitForDeployment();

    const WrappedToken = await ethers.getContractFactory("TezcatliWrappedToken");
    const wrappedToken = await WrappedToken.deploy(
      "Tezcatli Confidential USD",
      "tzcUSD",
      await mockUSDC.getAddress(),
      6,
    );
    await wrappedToken.waitForDeployment();

    const Registry = await ethers.getContractFactory("TezcatliStealthRegistry");
    const registry = await Registry.deploy();
    await registry.waitForDeployment();

    const Announcer = await ethers.getContractFactory("TezcatliStealthAnnouncer");
    const announcer = await Announcer.deploy();
    await announcer.waitForDeployment();

    const Migrator = await ethers.getContractFactory("TezcatliMigrator");
    const migrator = await Migrator.deploy();
    await migrator.waitForDeployment();

    const DustSwap = await ethers.getContractFactory("TezcatliDustSwap");
    const dustSwap = await DustSwap.deploy(
      await mockUSDC.getAddress(),
      deployer.address,
    );
    await dustSwap.waitForDeployment();

    const SmartAccountFactory = await ethers.getContractFactory("TezcatliSmartAccountFactory");
    const smartAccountFactory = await SmartAccountFactory.deploy();
    await smartAccountFactory.waitForDeployment();

    await (await mockUSDC.mint(deployer.address, 2_000_000_000n)).wait();
    await (await mockUSDC.approve(await dustSwap.getAddress(), 1_000_000_000n)).wait();
    await (await dustSwap.fundSettlement(1_000_000_000n)).wait();
    await (await dustSwap.setRate(
      await mockDustToken.getAddress(),
      2_000_000n,
      1_000_000_000_000_000_000n,
      true,
    )).wait();

    const deployments = {
      MockUSDC: await mockUSDC.getAddress(),
      MockDustToken: await mockDustToken.getAddress(),
      TezcatliWrappedToken: await wrappedToken.getAddress(),
      TezcatliStealthRegistry: await registry.getAddress(),
      TezcatliStealthAnnouncer: await announcer.getAddress(),
      TezcatliMigrator: await migrator.getAddress(),
      TezcatliDustSwap: await dustSwap.getAddress(),
      TezcatliSmartAccountFactory: await smartAccountFactory.getAddress(),
    };

    for (const [name, address] of Object.entries(deployments)) {
      console.log(`${name}: ${address}`);
      saveDeployment(network.name, name, address);
    }
  },
);
