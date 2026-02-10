// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";

/**
 * @title TreasuryFacet
 * @notice Manages the protocol treasury and collateralization
 * @dev The treasury is the heart of the PROOF stability mechanism
 *      
 *      TREASURY HOLDINGS:
 *      - USDC (primary stablecoin)
 *      - DAI (diversification)
 *      - Protocol fees from transactions
 *      
 *      CRITICAL FUNCTIONS:
 *      1. Maintain collateralization ratio (min 125%, target 150%)
 *      2. Allow PROOF redemption for USDC
 *      3. Accept deposits from various sources
 *      4. Buyback 2BTL with excess reserves
 */
contract TreasuryFacet {
    
    // ============ Events ============
    event TreasuryDeposit(address indexed token, uint256 amount, address indexed from);
    event TreasuryWithdrawal(address indexed token, uint256 amount, address indexed to);
    event CollateralRatioUpdated(uint256 newMinRatio, uint256 newTargetRatio);
    event BuybackExecuted(uint256 usdcSpent, uint256 btlBought);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);

    // ============ Deposit Functions ============

    /**
     * @notice Deposit USDC into treasury
     */
    function depositUSDC(uint256 amount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(amount > 0, "Treasury: Cannot deposit zero");
        
        // Note: In production, transfer USDC from msg.sender
        // IERC20(s.usdcAddress).transferFrom(msg.sender, address(this), amount)
        
        s.treasuryUSDC += amount;
        
        emit TreasuryDeposit(s.usdcAddress, amount, msg.sender);
    }

    /**
     * @notice Deposit DAI into treasury
     */
    function depositDAI(uint256 amount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(amount > 0, "Treasury: Cannot deposit zero");
        
        s.treasuryDAI += amount;
        
        emit TreasuryDeposit(s.daiAddress, amount, msg.sender);
    }

    // ============ Withdrawal Functions ============

    /**
     * @notice Withdraw USDC from treasury (maintains collateral ratio)
     */
    function withdrawUSDC(uint256 amount, address to) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(s.roles[LibAppStorage.TREASURY_MANAGER_ROLE][msg.sender], "Treasury: Not authorized");
        LibAppStorage.enforceNotPaused();
        require(amount > 0, "Treasury: Cannot withdraw zero");
        require(to != address(0), "Treasury: Invalid recipient");
        require(s.treasuryUSDC >= amount, "Treasury: Insufficient USDC");
        
        // Check collateralization after withdrawal
        uint256 newUSDC = s.treasuryUSDC - amount;
        uint256 totalCollateral = newUSDC + s.treasuryDAI;
        uint256 requiredCollateral = (s.proofTotalSupply * s.minCollateralRatio) / LibAppStorage.BASIS_POINTS;
        
        require(totalCollateral >= requiredCollateral, "Treasury: Would break collateral ratio");
        
        s.treasuryUSDC = newUSDC;
        
        emit TreasuryWithdrawal(s.usdcAddress, amount, to);
    }

    /**
     * @notice Withdraw DAI from treasury (maintains collateral ratio)
     */
    function withdrawDAI(uint256 amount, address to) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(s.roles[LibAppStorage.TREASURY_MANAGER_ROLE][msg.sender], "Treasury: Not authorized");
        LibAppStorage.enforceNotPaused();
        require(amount > 0, "Treasury: Cannot withdraw zero");
        require(to != address(0), "Treasury: Invalid recipient");
        require(s.treasuryDAI >= amount, "Treasury: Insufficient DAI");
        
        // Check collateralization after withdrawal
        uint256 newDAI = s.treasuryDAI - amount;
        uint256 totalCollateral = s.treasuryUSDC + newDAI;
        uint256 requiredCollateral = (s.proofTotalSupply * s.minCollateralRatio) / LibAppStorage.BASIS_POINTS;
        
        require(totalCollateral >= requiredCollateral, "Treasury: Would break collateral ratio");
        
        s.treasuryDAI = newDAI;
        
        emit TreasuryWithdrawal(s.daiAddress, amount, to);
    }

    // ============ Buyback Functions ============

    /**
     * @notice Execute 2BTL buyback with excess reserves
     */
    function executeBuyback(uint256 usdcAmount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(s.roles[LibAppStorage.TREASURY_MANAGER_ROLE][msg.sender], "Treasury: Not authorized");
        LibAppStorage.enforceNotPaused();
        require(usdcAmount > 0, "Treasury: Cannot buyback zero");
        
        // Check we're overcollateralized
        uint256 currentRatio = _getCollateralizationRatio();
        require(currentRatio > s.targetCollateralRatio, "Treasury: Not overcollateralized");
        
        // Calculate how much we can safely spend
        uint256 totalCollateral = s.treasuryUSDC + s.treasuryDAI;
        uint256 targetCollateral = (s.proofTotalSupply * s.targetCollateralRatio) / LibAppStorage.BASIS_POINTS;
        uint256 excessCollateral = totalCollateral > targetCollateral ? totalCollateral - targetCollateral : 0;
        
        require(usdcAmount <= excessCollateral, "Treasury: Amount exceeds excess collateral");
        require(usdcAmount <= s.treasuryUSDC, "Treasury: Insufficient USDC");
        
        s.treasuryUSDC -= usdcAmount;
        
        // Simulate buying 2BTL (in production: use DEX)
        // Assume price of 1 2BTL = $0.05
        uint256 btlBought = (usdcAmount * 1e18) / (5 * 1e16);
        
        // Burn the bought 2BTL (deflationary)
        if (btlBought > 0 && s.btlTotalSupply >= btlBought) {
            s.btlTotalSupply -= btlBought;
        }
        
        emit BuybackExecuted(usdcAmount, btlBought);
    }

    // ============ View Functions ============

    /**
     * @notice Get treasury balances
     */
    function getTreasuryBalances() external view returns (
        uint256 usdcBalance,
        uint256 daiBalance,
        uint256 totalValue
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        usdcBalance = s.treasuryUSDC;
        daiBalance = s.treasuryDAI;
        totalValue = usdcBalance + daiBalance;
    }

    /**
     * @notice Get current collateralization ratio
     */
    function getCollateralizationRatio() external view returns (uint256) {
        return _getCollateralizationRatio();
    }

    /**
     * @notice Get collateralization health status
     */
    function getCollateralizationHealth() external view returns (
        bool isHealthy,
        uint256 currentRatio,
        uint256 minRatio,
        uint256 targetRatio
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        currentRatio = _getCollateralizationRatio();
        minRatio = s.minCollateralRatio;
        targetRatio = s.targetCollateralRatio;
        isHealthy = currentRatio >= minRatio;
    }

    /**
     * @notice Calculate excess collateral available for buyback
     */
    function getExcessCollateral() external view returns (uint256 excessUSDC) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        uint256 currentRatio = _getCollateralizationRatio();
        if (currentRatio <= s.targetCollateralRatio) {
            return 0;
        }
        
        uint256 totalCollateral = s.treasuryUSDC + s.treasuryDAI;
        uint256 targetCollateral = (s.proofTotalSupply * s.targetCollateralRatio) / LibAppStorage.BASIS_POINTS;
        
        return totalCollateral > targetCollateral ? totalCollateral - targetCollateral : 0;
    }

    // ============ Admin Functions ============

    /**
     * @notice Set collateralization ratios
     */
    function setCollateralRatios(uint256 newMinRatio, uint256 newTargetRatio) external {
        LibAppStorage.enforceIsAdmin();
        require(newMinRatio >= 10000, "Treasury: Min ratio must be >= 100%");
        require(newTargetRatio >= newMinRatio, "Treasury: Target must be >= min");
        require(newTargetRatio <= 30000, "Treasury: Target ratio too high");
        
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        s.minCollateralRatio = newMinRatio;
        s.targetCollateralRatio = newTargetRatio;
        
        emit CollateralRatioUpdated(newMinRatio, newTargetRatio);
    }

    /**
     * @notice Set stablecoin addresses
     */
    function setStablecoinAddresses(address usdcAddress, address daiAddress) external {
        LibAppStorage.enforceIsAdmin();
        require(usdcAddress != address(0), "Treasury: Invalid USDC address");
        require(daiAddress != address(0), "Treasury: Invalid DAI address");
        
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        s.usdcAddress = usdcAddress;
        s.daiAddress = daiAddress;
    }

    /**
     * @notice Emergency withdraw (bypasses collateral checks - use with caution!)
     */
    function emergencyWithdraw(address token, uint256 amount, address to) external {
        LibAppStorage.enforceIsAdmin();
        require(to != address(0), "Treasury: Invalid recipient");
        
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        if (token == s.usdcAddress) {
            require(s.treasuryUSDC >= amount, "Treasury: Insufficient USDC");
            s.treasuryUSDC -= amount;
        } else if (token == s.daiAddress) {
            require(s.treasuryDAI >= amount, "Treasury: Insufficient DAI");
            s.treasuryDAI -= amount;
        } else {
            revert("Treasury: Unsupported token");
        }
        
        emit EmergencyWithdraw(token, amount, to);
    }

    /**
     * @notice Set global pause state
     */
    function setPaused(bool paused) external {
        LibAppStorage.enforceIsAdmin();
        LibAppStorage.appStorage().paused = paused;
    }

    // ============ Role Management ============

    /**
     * @notice Grant a role to an address
     */
    function grantRole(bytes32 role, address account) external {
        LibAppStorage.enforceIsAdmin();
        LibAppStorage.grantRole(role, account);
    }

    /**
     * @notice Revoke a role from an address
     */
    function revokeRole(bytes32 role, address account) external {
        LibAppStorage.enforceIsAdmin();
        LibAppStorage.revokeRole(role, account);
    }

    /**
     * @notice Check if an address has a role
     */
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return LibAppStorage.hasRole(role, account);
    }

    // ============ Internal Functions ============

    function _getCollateralizationRatio() internal view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        if (s.proofTotalSupply == 0) {
            return type(uint256).max;
        }
        
        uint256 totalCollateral = s.treasuryUSDC + s.treasuryDAI;
        return (totalCollateral * LibAppStorage.BASIS_POINTS) / s.proofTotalSupply;
    }
}
