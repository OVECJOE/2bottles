// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";
import "../libraries/LibReentrancyGuard.sol";
import "../libraries/LibSafeERC20.sol";
import "../libraries/LibVotes.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ISwapRouter.sol";

/**
 * @title TreasuryFacet
 * @notice Treasury management for the 2bottles protocol
 * @dev Manages USDC and DAI reserves that collateralize the PROOF token.
 *      All deposits and withdrawals execute real ERC20 transfers via LibSafeERC20.
 *
 *      KEY MECHANISMS:
 *      - Deposits require TREASURY_MANAGER or ADMIN authorization
 *      - Withdrawals enforce minimum collateralization ratios
 *      - Cross-decimal normalization: USDC (6 decimals) and DAI (18 decimals)
 *      - Buybacks route through a configurable DEX router and burn purchased 2BTL
 *      - Admin self-revoke protection prevents accidental lockout
 *
 *      DEPLOYMENT NOTE: The Diamond owner should be a multisig or timelock contract.
 */
contract TreasuryFacet {

    // ============ Events ============
    event TreasuryDeposit(address indexed token, uint256 amount, address indexed from);
    event TreasuryWithdrawal(address indexed token, uint256 amount, address indexed to);
    event CollateralRatioUpdated(uint256 newMinRatio, uint256 newTargetRatio);
    event BuybackExecuted(uint256 usdcSpent, uint256 btlBurned);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);
    event DexRouterUpdated(address indexed newRouter);

    // ============ Modifiers ============
    modifier nonReentrant() {
        LibReentrancyGuard.nonReentrantBefore();
        _;
        LibReentrancyGuard.nonReentrantAfter();
    }

    // ============ Deposit Functions (Real ERC20 Transfers) ============

    /**
     * @notice Deposit USDC into the treasury
     * @dev Caller must have approved the Diamond contract to spend their USDC.
     *      Restricted to TREASURY_MANAGER and ADMIN roles.
     * @param amount Amount of USDC to deposit (6 decimals)
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(amount > 0, "Treasury: Cannot deposit zero");
        require(s.usdcAddress != address(0), "Treasury: USDC not configured");
        require(
            s.roles[LibAppStorage.TREASURY_MANAGER_ROLE][msg.sender] ||
            s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "Treasury: Not authorized to deposit"
        );

        // Real ERC20 transfer
        LibSafeERC20.safeTransferFrom(IERC20(s.usdcAddress), msg.sender, address(this), amount);
        s.treasuryUSDC += amount;

        emit TreasuryDeposit(s.usdcAddress, amount, msg.sender);
    }

    /**
     * @notice Deposit DAI into the treasury
     * @dev Caller must have approved the Diamond contract to spend their DAI.
     *      Restricted to TREASURY_MANAGER and ADMIN roles.
     * @param amount Amount of DAI to deposit (18 decimals)
     */
    function depositDAI(uint256 amount) external nonReentrant {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(amount > 0, "Treasury: Cannot deposit zero");
        require(s.daiAddress != address(0), "Treasury: DAI not configured");
        require(
            s.roles[LibAppStorage.TREASURY_MANAGER_ROLE][msg.sender] ||
            s.roles[LibAppStorage.ADMIN_ROLE][msg.sender],
            "Treasury: Not authorized to deposit"
        );

        LibSafeERC20.safeTransferFrom(IERC20(s.daiAddress), msg.sender, address(this), amount);
        s.treasuryDAI += amount;

        emit TreasuryDeposit(s.daiAddress, amount, msg.sender);
    }

    // ============ Withdrawal Functions (Real ERC20 Transfers) ============

    function withdrawUSDC(uint256 amount, address to) external nonReentrant {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(s.roles[LibAppStorage.TREASURY_MANAGER_ROLE][msg.sender], "Treasury: Not authorized");
        LibAppStorage.enforceNotPaused();
        require(amount > 0 && to != address(0), "Treasury: Invalid params");
        require(s.treasuryUSDC >= amount, "Treasury: Insufficient USDC");

        // Check collateral after withdrawal (normalized)
        uint256 newNormalized = (s.treasuryUSDC - amount) + (s.treasuryDAI / LibAppStorage.DECIMAL_NORMALIZATION);
        uint256 requiredCollateral = (s.proofTotalSupply * s.minCollateralRatio) / LibAppStorage.BASIS_POINTS;
        require(newNormalized >= requiredCollateral, "Treasury: Would break collateral ratio");

        // Effects
        s.treasuryUSDC -= amount;

        // Interaction
        LibSafeERC20.safeTransfer(IERC20(s.usdcAddress), to, amount);

        emit TreasuryWithdrawal(s.usdcAddress, amount, to);
    }

    function withdrawDAI(uint256 amount, address to) external nonReentrant {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(s.roles[LibAppStorage.TREASURY_MANAGER_ROLE][msg.sender], "Treasury: Not authorized");
        LibAppStorage.enforceNotPaused();
        require(amount > 0 && to != address(0), "Treasury: Invalid params");
        require(s.treasuryDAI >= amount, "Treasury: Insufficient DAI");

        uint256 newNormalized = s.treasuryUSDC + ((s.treasuryDAI - amount) / LibAppStorage.DECIMAL_NORMALIZATION);
        uint256 requiredCollateral = (s.proofTotalSupply * s.minCollateralRatio) / LibAppStorage.BASIS_POINTS;
        require(newNormalized >= requiredCollateral, "Treasury: Would break collateral ratio");

        s.treasuryDAI -= amount;
        LibSafeERC20.safeTransfer(IERC20(s.daiAddress), to, amount);

        emit TreasuryWithdrawal(s.daiAddress, amount, to);
    }

    // ============ Buyback (via DEX Router) ============

    /**
     * @notice Buy and burn 2BTL using excess USDC reserves via DEX
     * @param usdcAmount Amount of USDC to spend on buyback
     * @param minBtlOut Minimum BTL to receive (slippage protection)
     */
    function executeBuyback(uint256 usdcAmount, uint256 minBtlOut) external nonReentrant {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(s.roles[LibAppStorage.TREASURY_MANAGER_ROLE][msg.sender], "Treasury: Not authorized");
        LibAppStorage.enforceNotPaused();
        require(usdcAmount > 0, "Treasury: Cannot buyback zero");
        require(s.dexRouter != address(0), "Treasury: DEX router not configured");
        require(s.usdcAddress != address(0), "Treasury: USDC not configured");

        // Ensure overcollateralized
        uint256 currentRatio = _getCollateralizationRatio();
        require(currentRatio > s.targetCollateralRatio, "Treasury: Not overcollateralized");

        // Only spend excess collateral
        uint256 totalCollateral = LibAppStorage.normalizedTreasuryTotal();
        uint256 targetCollateral = (s.proofTotalSupply * s.targetCollateralRatio) / LibAppStorage.BASIS_POINTS;
        uint256 excessCollateral = totalCollateral > targetCollateral ? totalCollateral - targetCollateral : 0;
        require(usdcAmount <= excessCollateral, "Treasury: Amount exceeds excess collateral");
        require(usdcAmount <= s.treasuryUSDC, "Treasury: Insufficient USDC");

        // Effects
        s.treasuryUSDC -= usdcAmount;

        // Approve DEX router to spend USDC
        LibSafeERC20.safeApprove(IERC20(s.usdcAddress), s.dexRouter, usdcAmount);

        // Swap USDC for BTL via DEX
        address btlAddress = s.btlWrapper != address(0) ? s.btlWrapper : address(this);
        address[] memory path = new address[](2);
        path[0] = s.usdcAddress;
        path[1] = btlAddress;

        uint256[] memory amounts = ISwapRouter(s.dexRouter).swapExactTokensForTokens(
            usdcAmount,
            minBtlOut,
            path,
            address(this),
            block.timestamp
        );

        uint256 btlBought = amounts[amounts.length - 1];

        // Burn the purchased BTL from contract balance
        require(s.btlBalances[address(this)] >= btlBought, "Treasury: Insufficient BTL after swap");
        unchecked {
            s.btlBalances[address(this)] -= btlBought;
            s.btlTotalSupply -= btlBought;
        }

        LibVotes.transferVotingUnits(address(this), address(0), btlBought);

        emit BuybackExecuted(usdcAmount, btlBought);
    }

    // ============ View Functions ============

    function getTreasuryBalances() external view returns (
        uint256 usdcBalance,
        uint256 daiBalance,
        uint256 totalValueNormalized
    ) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        usdcBalance = s.treasuryUSDC;
        daiBalance = s.treasuryDAI;
        totalValueNormalized = LibAppStorage.normalizedTreasuryTotal();
    }

    function getCollateralizationRatio() external view returns (uint256) {
        return _getCollateralizationRatio();
    }

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

    function getExcessCollateral() external view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint256 currentRatio = _getCollateralizationRatio();
        if (currentRatio <= s.targetCollateralRatio) return 0;

        uint256 totalCollateral = LibAppStorage.normalizedTreasuryTotal();
        uint256 targetCollateral = (s.proofTotalSupply * s.targetCollateralRatio) / LibAppStorage.BASIS_POINTS;
        return totalCollateral > targetCollateral ? totalCollateral - targetCollateral : 0;
    }

    // ============ Admin Functions ============

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

    function setStablecoinAddresses(address usdcAddress, address daiAddress) external {
        LibAppStorage.enforceIsAdmin();
        require(usdcAddress != address(0), "Treasury: Invalid USDC address");
        require(daiAddress != address(0), "Treasury: Invalid DAI address");

        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        s.usdcAddress = usdcAddress;
        s.daiAddress = daiAddress;
    }

    function setDexRouter(address router) external {
        LibAppStorage.enforceIsAdmin();
        require(router != address(0), "Treasury: Invalid router address");
        LibAppStorage.appStorage().dexRouter = router;
        emit DexRouterUpdated(router);
    }

    /**
     * @notice Emergency withdrawal that bypasses collateral ratio checks
     * @dev Restricted to ADMIN. Intended for incident response only.
     *      Should be behind a timelock or multisig in production.
     * @param token Address of the ERC20 token to withdraw
     * @param amount Amount to withdraw
     * @param to Recipient address
     */
    function emergencyWithdraw(address token, uint256 amount, address to) external nonReentrant {
        LibAppStorage.enforceIsAdmin();
        require(to != address(0), "Treasury: Invalid recipient");

        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();

        if (token == s.usdcAddress) {
            require(s.treasuryUSDC >= amount, "Treasury: Insufficient USDC");
            s.treasuryUSDC -= amount;
        } else if (token == s.daiAddress) {
            require(s.treasuryDAI >= amount, "Treasury: Insufficient DAI");
            s.treasuryDAI -= amount;
        }
        // For untracked tokens (accidentally sent), just transfer without bookkeeping

        LibSafeERC20.safeTransfer(IERC20(token), to, amount);

        emit EmergencyWithdraw(token, amount, to);
    }

    function setPaused(bool _paused) external {
        LibAppStorage.enforceIsAdmin();
        LibAppStorage.appStorage().paused = _paused;
    }

    // ============ Role Management (with admin self-revoke protection) ============

    function grantRole(bytes32 role, address account) external {
        LibAppStorage.enforceIsAdmin();
        LibAppStorage.grantRole(role, account);
    }

    /**
     * @notice Revoke a role from an account
     * @dev Prevents the caller from revoking their own ADMIN_ROLE to avoid lockout.
     * @param role The role identifier to revoke
     * @param account The address to revoke the role from
     */
    function revokeRole(bytes32 role, address account) external {
        LibAppStorage.enforceIsAdmin();
        require(
            !(role == LibAppStorage.ADMIN_ROLE && account == msg.sender),
            "Treasury: Cannot revoke own admin role"
        );
        LibAppStorage.revokeRole(role, account);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return LibAppStorage.hasRole(role, account);
    }

    // ============ Internal ============

    function _getCollateralizationRatio() internal view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        if (s.proofTotalSupply == 0) return type(uint256).max;
        uint256 totalCollateral = LibAppStorage.normalizedTreasuryTotal();
        return (totalCollateral * LibAppStorage.BASIS_POINTS) / s.proofTotalSupply;
    }
}
