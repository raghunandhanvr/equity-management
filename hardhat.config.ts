import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-ethers";
import "@openzeppelin/hardhat-upgrades";
import "dotenv/config";

function getAccounts(): string[] {
  const role = process.env.ROLE || 'admin';
  switch (role) {
    case 'admin':
      return [`0x${process.env.ADMIN_PRIVATE_KEY}`];
    case 'employee':
      return [`0x${process.env.EMPLOYEE_PRIVATE_KEY}`];
    case 'employee2':
      return [`0x${process.env.EMPLOYEE_2_PRIVATE_KEY}`];
    default:
      return [];
  }
}

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.27",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
      mining: {
        auto: true,
        interval: 0
      }
    },
    amoy: {
      url: process.env.INFURA_AMOY_URL,
      accounts: getAccounts(),
      chainId: parseInt(process.env.AMOY_CHAIN_ID || '80002')
    },
  }
};

export default config;
