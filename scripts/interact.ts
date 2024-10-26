import { ethers } from "hardhat";
import inquirer from "inquirer";
import fs from "fs";
import Table from "cli-table3";

async function main() {
  console.log("Loading deployment data...");
  const deploymentData = JSON.parse(fs.readFileSync("deployment.json", "utf-8"));

  console.log("Connecting to contracts...");
  const vestingContract = await ethers.getContractAt("VestingContract", deploymentData.vestingContract);
  const accessControlContract = await ethers.getContractAt("AccessControlContract", deploymentData.accessControlContract);
  const tokenContract = await ethers.getContractAt("TokenContract", deploymentData.tokenContract);
  
  const [signer] = await ethers.getSigners();
  console.log("Connected with address:", signer.address);

  async function checkRole(
    address: string
  ): Promise<string> {
    try {
      const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
      const ADMIN_ROLE = ethers.id("ADMIN_ROLE");
      const GRANTER_ROLE = ethers.id("GRANTER_ROLE");

      try {
        if (await accessControlContract.connect(signer).hasRole(DEFAULT_ADMIN_ROLE, address)) {
          console.log("User has DEFAULT_ADMIN_ROLE");
          return "Admin";
        }
      } catch (error) {
        console.log("Error checking DEFAULT_ADMIN_ROLE:", (error as Error).message);
      }

      try {
        if (await accessControlContract.connect(signer).hasRole(ADMIN_ROLE, address)) {
          console.log("User has ADMIN_ROLE");
          return "Admin";
        }
      } catch (error: unknown) {
        console.log("Error checking ADMIN_ROLE:", (error as Error).message);
      }

      try {
        if (await accessControlContract.connect(signer).hasRole(GRANTER_ROLE, address)) {
          console.log("User has GRANTER_ROLE");
          return "Granter";
        }
      } catch (error) {
        console.log("Error checking GRANTER_ROLE:", (error as Error).message);
      }

      return "Employee";
    } catch (error) {
      console.error("Error in checkRole:", error);
      return "Unknown";
    }
  }

  async function grantEquity() {
    const equityClassNames = await vestingContract.getEquityClassNames();
    const equityClassChoices = await Promise.all(
      equityClassNames.map(async (name: string) => {
        const [tokenCount, cliffPeriod, vestingPeriod, vestingPercentage] = await vestingContract.getEquityClassDetails(name);
        const formattedPercentage = Number(vestingPercentage) / 100;
        return {
          name: `${name} (Tokens: ${tokenCount}, Cliff: ${cliffPeriod}, Vesting: ${vestingPeriod}, Percentage: ${formattedPercentage}%)`,
          value: name,
        };
      })
    );

    const { employeeAddress, equityClassName } = await inquirer.prompt([
      { type: "input", name: "employeeAddress", message: "Enter employee address: 🙍‍♂️" },
      {
        type: "list",
        name: "equityClassName",
        message: "Select equity class: 📊",
        choices: equityClassChoices,
      },
    ]);

    await vestingContract.grantEquity(employeeAddress, equityClassName);
    console.log("Equity granted successfully! ✅");
  }

  async function claimVestedTokens() {
    try {
      const totalVested = await vestingContract.calculateVestedTokens(signer.address);
      const claimed = await vestingContract.getClaimedTokens(signer.address);
      const claimable = totalVested - claimed;
      
      if (claimable === 0n) {
        console.log("No tokens available to claim. ❌");
        return;
      }

      await vestingContract.connect(signer).claimVestedTokens();
      console.log(`Successfully claimed ${claimable.toString()} tokens! 💰`);
    } catch (error: any) {
      if (error.message.includes("CliffPeriodNotMet")) {
        console.log("Cliff period not met yet. Please wait longer before claiming. ⏳");
      } else if (error.message.includes("NoTokensToClaim")) {
        console.log("No tokens available to claim. ❌");
      } else {
        console.error("Error claiming tokens:", error);
      }
    }
  }

  async function viewEmployeeEquity(
    address?: string
  ) {
    const employeeAddress = address || signer.address;
    
    const equityClass = await vestingContract.getEmployeeEquityClass(employeeAddress);
    const totalTokens = await vestingContract.getVestedTokens(employeeAddress);
    const claimedTokens = await vestingContract.getClaimedTokens(employeeAddress);
    const remainingTokens = totalTokens - claimedTokens;
    const vestingPercentage = totalTokens > 0n
        ? Number((claimedTokens * 100n) / totalTokens)
        : 0;

    const availableToRelease = await vestingContract.calculateVestedTokens(employeeAddress);

    const table = new Table({
      head: ["Address", "Equity Class", "Total Tokens", "Available to Release", "Released Tokens", "Remaining Tokens", "Vesting Done"],
      style: {
        head: ['cyan'],
        border: ['grey']
      }
    }) as Table.Table & { push: (row: string[]) => number };

    table.push([
      employeeAddress,
      equityClass,
      totalTokens.toString(),
      availableToRelease.toString(),
      claimedTokens.toString(),
      remainingTokens.toString(),
      `${vestingPercentage.toFixed(2)}%`
    ]);

    console.log(table.toString());
  }

  async function checkBalance() {
    try {
      const tokenBalance = await tokenContract.balanceOf(signer.address);
      const claimed = await vestingContract.getClaimedTokens(signer.address);
      const availableToRelease = await vestingContract.calculateVestedTokens(signer.address);
  
      console.log("\n🪙 Your ERC20 Token Balance:");
      console.log('Tokens in Wallet 💰:', tokenBalance.toString());
      console.log('Tokens Available to Claim 🎁:', (availableToRelease - claimed).toString());
  
      if (availableToRelease > claimed) {
        console.log("\n💡 You can claim", (availableToRelease - claimed).toString(), "tokens now!");
      }
    } catch (error) {
      if ((error as Error).message.includes("NoEquityGranted")) {
        console.log("\n❌ No tokens have been granted to your address yet.");
      } else {
        console.error("Error checking token balance:", error);
      }
    }
  }
  

  async function viewCompanyTokens() {
    const [admin] = await ethers.getSigners();
    const role = await checkRole(admin.address);
    if (role !== "Admin") {
      console.log("Only admin can view company tokens. 🔒");
      return;
    }
  
    const totalTokensForCompany = await vestingContract.getTotalTokensForCompany();
    const totalTokensLockedForEmployees = await vestingContract.getTotalTokensLockedForEmployees();
    const totalTokensReleasedToEmployees = await vestingContract.getTotalTokensReleasedToEmployees();
  
    console.log("\nCompany Token Information:");
    console.log('Total Tokens for Company 💼:', totalTokensForCompany.toString());
    console.log('Total Tokens Locked for Employees 🔒:', totalTokensLockedForEmployees.toString());
    console.log('Total Tokens Released to Employees 🔓:', totalTokensReleasedToEmployees.toString());
  }
  
  async function transferTokens() {
    const balance = await tokenContract.balanceOf(signer.address);
    if (balance === 0n) {
      console.log("No tokens to transfer. ❌");
      return;
    }

    const { recipientAddress, amount } = await inquirer.prompt([
      { type: "input", name: "recipientAddress", message: "Enter recipient address: 🙍‍♂️" },
      { type: "input", name: "amount", message: "Enter amount to transfer: 💸" },
    ]);

    await tokenContract.connect(signer).transfer(recipientAddress, amount);
    console.log("Tokens transferred successfully! 💸");
  }

  async function transferOwnership() {
    const { newOwnerAddress } = await inquirer.prompt([
      { type: "input", name: "newOwnerAddress", message: "Enter the address of the new owner: 🆕👤" },
    ]);
  
    await vestingContract.transferOwnership(newOwnerAddress);
    console.log("Ownership transfer initiated. Waiting for the new owner to accept... ⏳");
  }
  
  async function acceptOwnership() {
    await vestingContract.confirmOwnership();
    console.log("Ownership accepted. You are now the new owner! 🎉");
  }

  async function adminCLI() {
    while (true) {
      const [account] = await ethers.getSigners();
      const role = await checkRole(account.address);
      const choices = ["View Company Tokens 💼", "View Employee Equity 📋", "Grant Equity 🎁", "Transfer Ownership 🔑", "Accept Ownership 🤝", "Exit 🚪"];


      console.log(`\nWelcome to the Admin Equity Management CLI! 🌟`);
      console.log(`You are logged in as: ${role} 👤`);

      const { choice } = await inquirer.prompt([
        {
          type: "list",
          name: "choice",
          message: "Select an action:",
          choices,
        },
      ]);

      switch (choice) {
        case "View Company Tokens 💼":
          await viewCompanyTokens();
          break;
        case "View Employee Equity 📋":
          const { employeeAddress } = await inquirer.prompt([
            { type: "input", name: "employeeAddress", message: "Enter employee address (leave empty for your own): 🙍‍♂️" },
          ]);
          await viewEmployeeEquity(employeeAddress || undefined);
          break;
        case "Grant Equity 🎁":
          await grantEquity();
          break;
        case "Transfer Ownership 🔑":
          await transferOwnership();
          break;
        case "Accept Ownership 🤝":
          await acceptOwnership();
          break;
        case "Exit 🚪":
          console.log("Goodbye! 👋");
          return;
      }
    }
  }

  async function employeeCLI() {
    while (true) {
      const [account] = await ethers.getSigners();
      const role = await checkRole(account.address);
      const choices = [
        "Check Balance 💰",
        "View My Equity 📋", 
        "Claim Vested Tokens 💰", 
        "Transfer Tokens 💸", 
        "Accept Ownership 🔑", 
        "Exit 🚪"
      ];

      console.log(`\nWelcome to the Employee Equity Management CLI! 🌟`);
      console.log(`You are logged in as: ${role} 👤`);

      const { choice } = await inquirer.prompt([
        {
          type: "list",
          name: "choice",
          message: "Select an action:",
          choices,
        },
      ]);

      switch (choice) {
        case "Check Balance 💰":
          await checkBalance();
          break;
        case "View My Equity 📋":
          await viewEmployeeEquity();
          break;
        case "Claim Vested Tokens 💰":
          await claimVestedTokens();
          break;
        case "Transfer Tokens 💸":
          await transferTokens();
          break;
        case "Accept Ownership 🔑":
          await acceptOwnership();
          break;
        case "Exit 🚪":
          console.log("Goodbye! 👋");
          return;
      }
    }
  }

  async function main() {
    const { role } = await inquirer.prompt([
      {
        type: "list",
        name: "role",
        message: "Select your role:",
        choices: ["Admin 🔑", "Employee 👤"],
      },
    ]);

    if (role === "Admin 🔑") {
      await adminCLI();
    } else {
      await employeeCLI();
    }
  }

  await main();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
