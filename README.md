<p align="center">
 <img src="equity.png" alt="Equity Management" width="100" height="100"/>
</p>

<h2 align="center">Equity Management Smart Contracts</h1>

<p align="center">
This repository contains a set of Ethereum smart contracts for managing employee equity in a transparent and automated manner. The contracts are designed to handle equity grants, vesting schedules, and token transfers based on predefined equity classes.
</p>

#### Features

- Define and manage multiple equity classes with different token allocations and vesting schedules
- Grant equity to employees based on their designation
- Automatically calculate and release vested tokens according to the specified cliff and vesting periods
- Provide a user-friendly CLI for interacting with the contracts
- Secure access control using role-based permissions
- Upgradeable contracts using the Transparent Proxy pattern

#### Security Features
- Reentrancy protection using OpenZeppelin's ReentrancyGuard
- Role-based access control  
- Upgradeable contracts using Transparent Proxy Pattern
- Two-step ownership transfer