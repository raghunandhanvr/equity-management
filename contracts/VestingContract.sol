// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
        address employee;
        bytes32 equityClass;
        uint96 totalTokens;
        uint40 startTime;
        uint96 claimedTokens;
    }

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    TokenContract public immutable token;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    AccessControlContract public immutable accessControl;
    
    mapping(bytes32 => EquityClass) private equityClasses;        
    mapping(address => EmployeeEquity) private employeeEquities;      
    mapping(address => uint96) private totalReleasedTokens;
    
    mapping(bytes32 => uint256) private equityClassIndex;
    bytes32[] private equityClassNames;                       

    uint16 public constant BASIS_POINTS = 10000;

    uint256[49] private __gap;

    event EquityClassDefined(bytes32 indexed name, uint96 tokenCount);
    event EquityGranted(address indexed employee, bytes32 indexed equityClassName, uint40 grantTime);
    event TokensClaimed(address indexed employee, uint96 amount);

    error InvalidEquityClass(string reason);
    error NoEquityGranted(address employee);
    error NoTokensToClaim(address employee);
    error InsufficientBalance(uint256 required, uint256 available);
    error CliffPeriodNotMet(uint256 remainingTime);
    error ZeroAddress();
    error InvalidVestingParameters();

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

    modifier onlyAdmin() {
        require(accessControl.isAdmin(msg.sender), "Only admin can perform this action");
        _;
    }

    modifier onlyGranter() {
        require(accessControl.isGranter(msg.sender), "Only granter can perform this action");
        _;
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
    ) external onlyAdmin {
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
        
        if (equityClassIndex[name] == 0) {
            equityClassNames.push(name);
            equityClassIndex[name] = equityClassNames.length;
        }
        
        emit EquityClassDefined(name, tokenCount);
    }

    function grantEquity(
        address employee,
        bytes32 equityClassName
    ) external onlyGranter {
        if (employee == address(0)) revert ZeroAddress();
        
        EquityClass storage equityClass = equityClasses[equityClassName];
        if (equityClass.tokenCount == 0) revert InvalidEquityClass("Equity class does not exist");
        if (employeeEquities[employee].equityClass != bytes32(0)) revert InvalidEquityClass("Employee already has equity granted");
        
        employeeEquities[employee] = EmployeeEquity({
            employee: employee,
            equityClass: equityClassName,
            totalTokens: equityClass.tokenCount,
            startTime: uint40(block.timestamp),
            claimedTokens: 0
        });
        
        emit EquityGranted(employee, equityClassName, uint40(block.timestamp));
    }

    function calculateVestedTokens(address employee) public view returns (uint256) {
        EmployeeEquity storage equity = employeeEquities[employee];
        if (equity.equityClass == bytes32(0)) {
            return 0;
        }

        EquityClass storage equityClass = equityClasses[equity.equityClass];
        uint256 elapsedTime = block.timestamp - equity.startTime;

        // check if cliff period has passed
        if (elapsedTime < equityClass.cliffPeriod) {
            return 0;
        }

        // calculate number of complete vesting periods
        uint256 vestingTime = elapsedTime - equityClass.cliffPeriod;
        uint256 completedPeriods = vestingTime / equityClass.vestingPeriod;
        
        // calculate vested percentage including cliff and completed periods
        uint256 vestedPercentage = equityClass.vestingPercentage + (completedPeriods * equityClass.vestingPercentage);
        if (vestedPercentage > BASIS_POINTS) {
            vestedPercentage = BASIS_POINTS;
        }

        // calculate total vested tokens
        uint256 totalVestedAmount = (equity.totalTokens * vestedPercentage) / BASIS_POINTS;
        
        // if already claimed more than currently vested, return 0
        if (equity.claimedTokens >= totalVestedAmount) {
            return 0;
        }
        
        return totalVestedAmount - equity.claimedTokens;
    }

    function getNextVestingAmount(address employee) external view returns (uint256 amount, uint256 unlockTime) {
        EmployeeEquity storage equity = employeeEquities[employee];
        if (equity.equityClass == bytes32(0)) {
            return (0, 0);
        }

        EquityClass storage equityClass = equityClasses[equity.equityClass];
        uint256 elapsedTime = block.timestamp - equity.startTime;

        // if cliff period hasn't passed yet
        if (elapsedTime < equityClass.cliffPeriod) {
            // first batch after cliff
            uint256 firstBatch = (equity.totalTokens * equityClass.vestingPercentage) / BASIS_POINTS;
            return (firstBatch, equity.startTime + equityClass.cliffPeriod);
        }

        // calculate current and next vesting milestones
        uint256 vestingTime = elapsedTime - equityClass.cliffPeriod;
        uint256 currentPeriods = 1 + (vestingTime / equityClass.vestingPeriod);
        uint256 totalVestedPercentage = currentPeriods * equityClass.vestingPercentage;

        // if fully vested
        if (totalVestedPercentage >= BASIS_POINTS) {
            return (0, 0);
        }

        // calculate next batch
        uint256 batchAmount = (equity.totalTokens * equityClass.vestingPercentage) / BASIS_POINTS;
        uint256 nextUnlockTime = equity.startTime + equityClass.cliffPeriod + (currentPeriods * equityClass.vestingPeriod);

        return (batchAmount, nextUnlockTime);
    }

    function claimVestedTokens() external nonReentrant {
        EmployeeEquity storage equity = employeeEquities[msg.sender];
        if (equity.equityClass == bytes32(0)) revert NoEquityGranted(msg.sender);
        
        EquityClass storage equityClass = equityClasses[equity.equityClass];
        uint256 elapsedTime = block.timestamp - equity.startTime;
        
        // enforce cliff period
        if (elapsedTime < equityClass.cliffPeriod) {
            revert CliffPeriodNotMet(equityClass.cliffPeriod - elapsedTime);
        }
        
        uint256 unclaimedTokens = calculateVestedTokens(msg.sender);
        if (unclaimedTokens == 0) revert NoTokensToClaim(msg.sender);

        // update claimed tokens
        unchecked {
            equity.claimedTokens += uint96(unclaimedTokens);
            totalReleasedTokens[msg.sender] += uint96(unclaimedTokens);
        }
        
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

    function getEquityClassNames() external view returns (bytes32[] memory) {
        return equityClassNames;
    }

    function getEquityClassDetails(
        bytes32 name
    ) external view returns (uint96, uint32, uint32, uint16) {
        EquityClass storage equityClass = equityClasses[name];
        return (
            equityClass.tokenCount,
            equityClass.cliffPeriod,
            equityClass.vestingPeriod,
            equityClass.vestingPercentage
        );
    }

    function getTotalTokensForCompany() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function getTotalTokensLockedForEmployees() external view returns (uint96) {
        uint96 totalLocked;
        for (uint256 i = 0; i < equityClassNames.length;) {
            bytes32 className = equityClassNames[i];
            totalLocked += equityClasses[className].tokenCount;
            unchecked { ++i; }
        }
        return totalLocked;
    }

    function getTotalTokensReleasedToEmployees() external view returns (uint96) {
        uint96 totalReleased;
        for (uint256 i = 0; i < equityClassNames.length;) {
            bytes32 className = equityClassNames[i];
            EquityClass storage equityClass = equityClasses[className];
            unchecked {
                for (uint256 j = 0; j < equityClass.tokenCount;) {
                    totalReleased += totalReleasedTokens[employeeEquities[msg.sender].employee];
                    ++j;
                }
                ++i;
            }
        }
        return totalReleased;
    }

    function getClaimedTokens(address employee) external view returns (uint96) {
        return employeeEquities[employee].claimedTokens;
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