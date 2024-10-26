// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "./TokenContract.sol";
import "./AccessControlContract.sol";

contract VestingContract is 
    Initializable, 
    ReentrancyGuardUpgradeable,
    Ownable2StepUpgradeable   
{  
    struct EquityClass {
        uint96 tokenCount;   
        uint32 cliffPeriod;  
        uint32 vestingPeriod;
        uint16 vestingPercentage;
    }

    struct EmployeeEquity {
        bytes32 equityClass;
        uint96 totalTokens;
        uint40 startTime;
    }

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    TokenContract public immutable token;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    AccessControlContract public immutable accessControl;
    
    mapping(bytes32 => EquityClass) private equityClasses;        
    mapping(address => EmployeeEquity) private employeeEquities;      
    mapping(address => uint96) private claimedTokens;     
    
    address[] private employeeAddresses;
    bytes32[] private equityClassNames;                       

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GRANTER_ROLE = keccak256("GRANTER_ROLE");
    uint16 public constant BASIS_POINTS = 10000;

    uint256[49] private __gap;

    event EquityClassDefined(bytes32 indexed name, uint96 tokenCount);
    event EquityGranted(address indexed employee, bytes32 indexed equityClassName, uint40 grantTime);
    event TokensClaimed(address indexed employee, uint96 amount);

    error NotAuthorized(bytes32 role);
    error InvalidEquityClass(string reason);
    error NoEquityGranted(address employee);
    error NoTokensToClaim(address employee);
    error InsufficientBalance(uint256 required, uint256 available);
    error CliffPeriodNotMet(uint256 remainingTime);
    error ZeroAddress();
    error InvalidVestingParameters();

    modifier onlyRole(bytes32 role) {
        if (!accessControl.hasRole(role, msg.sender)) {
            revert NotAuthorized(role);
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address tokenAddress, 
        address accessControlAddress
    ) {
        if (tokenAddress == address(0) || accessControlAddress == address(0)) revert ZeroAddress();
        token = TokenContract(tokenAddress);
        accessControl = AccessControlContract(accessControlAddress);
        _disableInitializers();
    }

    // write functions

    function initialize() external initializer {
        __ReentrancyGuard_init();
        __Ownable2Step_init();
    }

    function defineEquityClass(
        bytes32 name,
        uint96 tokenCount,
        uint32 cliffPeriod,
        uint32 vestingPeriod,
        uint16 vestingPercentage
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vestingPercentage > 100) revert InvalidEquityClass("Percentage exceeds 100%");
        if (vestingPercentage == 0) revert InvalidEquityClass("Percentage cannot be zero");
        if (tokenCount == 0) revert InvalidEquityClass("Token count cannot be zero");
        if (vestingPeriod == 0) revert InvalidEquityClass("Vesting period cannot be zero");
        
        uint16 vestingPercentageBP = vestingPercentage * 100;
        
        equityClasses[name] = EquityClass({
            tokenCount: tokenCount,
            cliffPeriod: cliffPeriod,
            vestingPeriod: vestingPeriod,
            vestingPercentage: vestingPercentageBP
        });
        equityClassNames.push(name);
        
        emit EquityClassDefined(name, tokenCount);
    }

    function grantEquity(
        address employee,
        bytes32 equityClassName
    ) external onlyRole(GRANTER_ROLE) {
        if (employee == address(0)) revert ZeroAddress();
        
        EquityClass memory eqClass = equityClasses[equityClassName];
        if (eqClass.tokenCount == 0) revert InvalidEquityClass("Equity class does not exist");
        if (employeeEquities[employee].equityClass != bytes32(0)) revert InvalidEquityClass("Employee already has equity granted");
        
        employeeEquities[employee] = EmployeeEquity({
            equityClass: equityClassName,
            totalTokens: eqClass.tokenCount,
            startTime: uint40(block.timestamp)
        });
        employeeAddresses.push(employee);
        
        emit EquityGranted(employee, equityClassName, uint40(block.timestamp));
    }

    function calculateVestedTokens(address employee) public view returns (uint256) {
        EmployeeEquity memory equity = employeeEquities[employee];
        if (equity.equityClass == bytes32(0)) {
            return 0;
        }

        EquityClass memory eqClass = equityClasses[equity.equityClass];
        uint256 elapsedTime = block.timestamp - equity.startTime;

        // check if cliff period has passed
        if (elapsedTime < eqClass.cliffPeriod) {
            return 0;
        }

        // calculate number of complete vesting periods
        uint256 vestingTime = elapsedTime - eqClass.cliffPeriod;
        uint256 completedPeriods = vestingTime / eqClass.vestingPeriod;
        
        // calculate vested percentage including cliff and completed periods
        uint256 vestedPercentage = eqClass.vestingPercentage + (completedPeriods * eqClass.vestingPercentage);
        if (vestedPercentage > BASIS_POINTS) {
            vestedPercentage = BASIS_POINTS;
        }

        // calculate total vested tokens
        uint256 alreadyClaimed = claimedTokens[employee];
        uint256 totalVestedAmount = (equity.totalTokens * vestedPercentage) / BASIS_POINTS;
        
        // if already claimed more than currently vested, return 0
        if (alreadyClaimed >= totalVestedAmount) {
            return 0;
        }
        
        return totalVestedAmount - alreadyClaimed;
    }

    function getNextVestingAmount(address employee) external view returns (uint256 amount, uint256 unlockTime) {
        EmployeeEquity memory equity = employeeEquities[employee];
        if (equity.equityClass == bytes32(0)) {
            return (0, 0);
        }

        EquityClass memory eqClass = equityClasses[equity.equityClass];
        uint256 elapsedTime = block.timestamp - equity.startTime;

        // if cliff period hasn't passed yet
        if (elapsedTime < eqClass.cliffPeriod) {
            // first batch after cliff
            uint256 firstBatch = (equity.totalTokens * eqClass.vestingPercentage) / BASIS_POINTS;
            return (firstBatch, equity.startTime + eqClass.cliffPeriod);
        }

        // calculate current and next vesting milestones
        uint256 vestingTime = elapsedTime - eqClass.cliffPeriod;
        uint256 currentPeriods = 1 + (vestingTime / eqClass.vestingPeriod);
        uint256 totalVestedPercentage = currentPeriods * eqClass.vestingPercentage;

        // if fully vested
        if (totalVestedPercentage >= BASIS_POINTS) {
            return (0, 0);
        }

        // calculate next batch
        uint256 batchAmount = (equity.totalTokens * eqClass.vestingPercentage) / BASIS_POINTS;
        uint256 nextUnlockTime = equity.startTime + eqClass.cliffPeriod + (currentPeriods * eqClass.vestingPeriod);

        return (batchAmount, nextUnlockTime);
    }

    function claimVestedTokens() external nonReentrant {
        EmployeeEquity memory equity = employeeEquities[msg.sender];
        if (equity.equityClass == bytes32(0)) revert NoEquityGranted(msg.sender);
        
        EquityClass memory eqClass = equityClasses[equity.equityClass];
        uint256 elapsedTime = block.timestamp - equity.startTime;
        
        // enforce cliff period
        if (elapsedTime < eqClass.cliffPeriod) {
            revert CliffPeriodNotMet(eqClass.cliffPeriod - elapsedTime);
        }
        
        uint256 unclaimedTokens = calculateVestedTokens(msg.sender);
        if (unclaimedTokens == 0) revert NoTokensToClaim(msg.sender);

        // update claimed tokens
        claimedTokens[msg.sender] += uint96(unclaimedTokens);
        
        // transfer tokens
        bool success = token.transfer(msg.sender, unclaimedTokens);
        if (!success) revert InsufficientBalance(unclaimedTokens, token.balanceOf(address(this)));
        
        emit TokensClaimed(msg.sender, uint96(unclaimedTokens));
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        super.transferOwnership(newOwner);
    }

    function confirmOwnership() public virtual {
        require(msg.sender == pendingOwner(), "Ownable2Step: caller is not the new owner");
        acceptOwnership();
    }

    // read functions

    function getEmployeeAddresses() external view onlyRole(DEFAULT_ADMIN_ROLE) returns (address[] memory) {
        return employeeAddresses;
    }

    function getEquityClassNames() external view returns (bytes32[] memory) {
        return equityClassNames;
    }

    function getEquityClassDetails(
        bytes32 name
    ) external view returns (uint96, uint32, uint32, uint16) {
        EquityClass memory eqClass = equityClasses[name];
        return (
            eqClass.tokenCount,
            eqClass.cliffPeriod,
            eqClass.vestingPeriod,
            eqClass.vestingPercentage
        );
    }

    function getTotalTokensForCompany() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getTotalTokensLockedForEmployees() external view returns (uint96) {
        uint256 length = employeeAddresses.length;
        uint96 totalLocked;
        for (uint256 i = 0; i < length;) {
            totalLocked += employeeEquities[employeeAddresses[i]].totalTokens;
            unchecked { ++i; }
        }
        return totalLocked;
    }

    function getTotalTokensReleasedToEmployees() external view returns (uint96) {
        uint256 length = employeeAddresses.length;
        uint96 totalReleased;
        for (uint256 i = 0; i < length;) {
            totalReleased += claimedTokens[employeeAddresses[i]];
            unchecked { ++i; }
        }
        return totalReleased;
    }

    function getClaimedTokens(address employee) external view returns (uint96) {
        return claimedTokens[employee];
    }

    function getEmployeeEquityClass(address employee) external view returns (bytes32) {
        return employeeEquities[employee].equityClass;
    }

    function getVestedTokens(address employee) external view returns (uint96) {
        return employeeEquities[employee].totalTokens;
    }

    function getGrantTimestamp(address employee) external view returns (uint256) {
        return employeeEquities[employee].startTime;
    }
}