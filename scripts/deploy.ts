import { ethers, upgrades } from "hardhat";
import fs from "fs";
import inquirer from "inquirer";
import { BytesLike } from "ethers";

const DEFAULT_EQUITY_CLASSES: EquityClass[] = [
  { 
    name: "CXO", 
    tokenCount: 1000, 
    cliffPeriod: 120, 
    vestingPeriod: 120, 
    vestingPercentage: 25 
  },
  { 
    name: "Senior Manager", 
    tokenCount: 800, 
    cliffPeriod: 120, 
    vestingPeriod: 120, 
    vestingPercentage: 25 
  },
  { 
    name: "Others", 
    tokenCount: 400, 
    cliffPeriod: 120, 
    vestingPeriod: 120, 
    vestingPercentage: 50 
  }
];

interface EquityClass {
  name: string;
  tokenCount: number;
  cliffPeriod: number;
  vestingPeriod: number;
  vestingPercentage: number;
}

interface DeploymentData {
  tokenContract: string;
  vestingContract: string;
  accessControlContract: string;
  deploymentTime: string;
  network: string;
}

async function deployContracts() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  const TokenContract = await ethers.getContractFactory("TokenContract");
  const tokenContract = await upgrades.deployProxy(
    TokenContract,
    ["Equity Token", "EQT"],
    { 
      initializer: "initialize",
      kind: "transparent"
    }
  );
  await tokenContract.waitForDeployment();
  const tokenAddress = await tokenContract.getAddress();
  console.log("Token Contract deployed to:", tokenAddress);

  const AccessControlContract = await ethers.getContractFactory("AccessControlContract");
  const accessControlContract = await upgrades.deployProxy(
    AccessControlContract,
    [],
    { 
      initializer: "initialize",
      kind: "transparent"
    }
  );
  await accessControlContract.waitForDeployment();
  const accessControlAddress = await accessControlContract.getAddress();
  console.log("Access Control Contract deployed to:", accessControlAddress);

  const VestingContract = await ethers.getContractFactory("VestingContract");
  const vestingContract = await upgrades.deployProxy(
    VestingContract,
    [],
    { 
      initializer: "initialize",
      kind: "transparent",
      constructorArgs: [tokenAddress, accessControlAddress]
    }
  );
  await vestingContract.waitForDeployment();
  const vestingAddress = await vestingContract.getAddress();
  console.log("Vesting Contract deployed to:", vestingAddress);

  return {
    tokenContract,
    accessControlContract,
    vestingContract,
    addresses: {
      token: tokenAddress,
      accessControl: accessControlAddress,
      vesting: vestingAddress
    }
  };
}

async function setupContracts(
  tokenContract: any, 
  vestingContract: any, 
  vestingAddress: string
) {
  console.log("Setting up contract permissions and initial configuration...");

  const minterRole = ethers.id("MINTER_ROLE");
  await tokenContract.grantRole(minterRole, vestingAddress);
  console.log("Granted MINTER_ROLE to VestingContract");

  for (const equityClass of DEFAULT_EQUITY_CLASSES) {
    const nameBytes32 = ethers.encodeBytes32String(equityClass.name);
    await vestingContract.defineEquityClass(
      nameBytes32,
      equityClass.tokenCount,
      equityClass.cliffPeriod,
      equityClass.vestingPeriod,
      equityClass.vestingPercentage
    );
    console.log(`Defined equity class: ${equityClass.name}`);
  }

  const { totalTokens } = await inquirer.prompt([
    {
      type: "input",
      name: "totalTokens",
      message: "Enter the total number of tokens to mint:",
      validate: (input: string) => {
        const value = parseInt(input);
        return !isNaN(value) && value > 0;
      },
    },
  ]);

  await tokenContract.mint(vestingAddress, totalTokens);
  console.log(`Minted ${totalTokens} tokens to VestingContract`);
}

async function upgradeContracts(
  deploymentData: DeploymentData
) {
  console.log("Starting contract upgrade process...");

  const VestingContract = await ethers.getContractFactory("VestingContract");
  const upgradedVestingContract = await upgrades.upgradeProxy(
    deploymentData.vestingContract,
    VestingContract,
    {
      kind: "transparent",
      constructorArgs: [deploymentData.tokenContract, deploymentData.accessControlContract]
    }
  );
  await upgradedVestingContract.waitForDeployment();
  console.log("Vesting Contract upgraded");

  const equityClassNames = await upgradedVestingContract.getEquityClassNames();
  const decodedNames = equityClassNames.map((name: BytesLike) => 
    ethers.decodeBytes32String(name)
  );
  console.log("Existing equity classes:", decodedNames.join(", "));

  return upgradedVestingContract;
}

async function addNewEquityClass(
  vestingContract: any
) {
  const { addEquityClass } = await inquirer.prompt([
    {
      type: "confirm",
      name: "addEquityClass",
      message: "Do you want to add a new equity class?",
      default: false,
    },
  ]);

  if (addEquityClass) {
    const { name, tokenCount, cliffPeriod, vestingPeriod, vestingPercentage } = 
      await inquirer.prompt([
        {
          type: "input",
          name: "name",
          message: "Enter the name of the new equity class:",
          validate: (input: string) => input.trim().length > 0,
        },
        {
          type: "input",
          name: "tokenCount",
          message: "Enter the token count for the new equity class:",
          validate: (input: string) => {
            const value = parseInt(input);
            return !isNaN(value) && value > 0;
          },
        },
        {
          type: "input",
          name: "cliffPeriod",
          message: "Enter the cliff period (in seconds):",
          validate: (input: string) => {
            const value = parseInt(input);
            return !isNaN(value) && value > 0;
          },
        },
        {
          type: "input",
          name: "vestingPeriod",
          message: "Enter the vesting period (in seconds):",
          validate: (input: string) => {
            const value = parseInt(input);
            return !isNaN(value) && value > 0;
          },
        },
        {
          type: "input",
          name: "vestingPercentage",
          message: "Enter the vesting percentage (1-100):",
          validate: (input: string) => {
            const value = parseInt(input);
            return !isNaN(value) && value > 0 && value <= 100;
          },
        },
      ]);

    const nameBytes32 = ethers.encodeBytes32String(name);
    await vestingContract.defineEquityClass(
      nameBytes32,
      tokenCount,
      cliffPeriod,
      vestingPeriod,
      vestingPercentage
    );
    console.log("New equity class added successfully");
  }
}

async function saveDeploymentData(
  data: DeploymentData
) {
  fs.writeFileSync(
    "deployment.json", 
    JSON.stringify(data, null, 2)
  );
  console.log("Deployment data saved to deployment.json");
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Starting deployment process with deployer:", deployer.address);

  const { action } = await inquirer.prompt([
    {
      type: "list",
      name: "action",
      message: "Select an action:",
      choices: ["Deploy 🚀", "Upgrade ⬆️"],
    },
  ]);

  if (action === "Deploy 🚀") {
    const { tokenContract, vestingContract, addresses } = await deployContracts();

    await setupContracts(tokenContract, vestingContract, addresses.vesting);

    const deploymentData: DeploymentData = {
      tokenContract: addresses.token,
      vestingContract: addresses.vesting,
      accessControlContract: addresses.accessControl,
      deploymentTime: new Date().toISOString(),
      network: (await ethers.provider.getNetwork()).name,
    };
    await saveDeploymentData(deploymentData);

  } else if (action === "Upgrade ⬆️") {
    if (!fs.existsSync("deployment.json")) {
      console.error("deployment.json not found. Please deploy the contracts first.");
      return;
    }

    const deploymentData: DeploymentData = JSON.parse(
      fs.readFileSync("deployment.json", "utf-8")
    );

    const upgradedVestingContract = await upgradeContracts(deploymentData);

    await addNewEquityClass(upgradedVestingContract);

    const { confirmUpgrade } = await inquirer.prompt([
      {
        type: "confirm",
        name: "confirmUpgrade",
        message: "Are you sure you want to proceed with the upgrade?",
        default: false,
      },
    ]);

    if (!confirmUpgrade) {
      console.log("Upgrade cancelled.");
      return;
    }

    console.log("Upgrade completed successfully.");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });