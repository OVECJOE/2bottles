// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";
import "../libraries/LibReentrancyGuard.sol";
import "../libraries/LibSafeERC20.sol";
import "../interfaces/IERC20.sol";

/**
 * @title ProofTokenFacet
 * @notice PROOF stable utility token (~$1 peg, 6 decimals)
 * @dev Minted exclusively through staking 2BTL and redeemable 1:1 for USDC
 *      from the treasury. No transfer fee is applied. Collateralization is
 *      enforced before every mint to maintain treasury health. Redemptions
 *      execute real ERC20 USDC transfers via LibSafeERC20.
 */
contract ProofTokenFacet {

    // ============ Events ============
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event ProofMinted(address indexed user, uint256 amount, uint256 btlStaked);
    event ProofRedeemed(address indexed user, uint256 proofAmount, uint256 usdcAmount);

    // ============ Modifiers ============
    modifier nonReentrant() {
        LibReentrancyGuard.nonReentrantBefore();
        _;
        LibReentrancyGuard.nonReentrantAfter();
    }

    // ============ ERC20 View Functions ============

    function proofName() external view returns (string memory) {
        return LibAppStorage.appStorage().proofName;
    }

    function proofSymbol() external view returns (string memory) {
        return LibAppStorage.appStorage().proofSymbol;
    }

    function proofDecimals() external pure returns (uint8) {
        return 6;
    }

    function proofTotalSupply() external view returns (uint256) {
        return LibAppStorage.appStorage().proofTotalSupply;
    }

    function proofBalanceOf(address account) external view returns (uint256) {
        return LibAppStorage.appStorage().proofBalances[account];
    }

    function proofAllowance(address owner, address spender) external view returns (uint256) {
        return LibAppStorage.appStorage().proofAllowances[owner][spender];
    }

    // ============ ERC20 State-Changing Functions ============

    function proofTransfer(address to, uint256 amount) external nonReentrant returns (bool) {
        LibAppStorage.enforceNotPaused();
        _proofTransfer(msg.sender, to, amount);
        return true;
    }

    function proofTransferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();

        uint256 currentAllowance = s.proofAllowances[from][msg.sender];
        require(currentAllowance >= amount, "PROOF: Insufficient allowance");

        if (currentAllowance != type(uint256).max) {
            unchecked {
                s.proofAllowances[from][msg.sender] = currentAllowance - amount;
            }
        }

        _proofTransfer(from, to, amount);
        return true;
    }

    function proofApprove(address spender, uint256 amount) external returns (bool) {
        LibAppStorage.enforceNotPaused();
        require(spender != address(0), "PROOF: Approve to zero address");

        LibAppStorage.appStorage().proofAllowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function proofIncreaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();

        s.proofAllowances[msg.sender][spender] += addedValue;
        emit Approval(msg.sender, spender, s.proofAllowances[msg.sender][spender]);
        return true;
    }

    function proofDecreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();

        uint256 currentAllowance = s.proofAllowances[msg.sender][spender];
        require(currentAllowance >= subtractedValue, "PROOF: Allowance below zero");

        unchecked {
            s.proofAllowances[msg.sender][spender] = currentAllowance - subtractedValue;
        }
        emit Approval(msg.sender, spender, s.proofAllowances[msg.sender][spender]);
        return true;
    }

    // ============ Wrapper Support ============

    function proofWrapperTransfer(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(msg.sender == s.proofWrapper, "PROOF: Caller is not wrapper");
        LibAppStorage.enforceNotPaused();
        _proofTransfer(from, to, amount);
        return true;
    }

    function proofWrapperTransferFrom(address spender, address from, address to, uint256 amount) external nonReentrant returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(msg.sender == s.proofWrapper, "PROOF: Caller is not wrapper");
        LibAppStorage.enforceNotPaused();

        uint256 currentAllowance = s.proofAllowances[from][spender];
        require(currentAllowance >= amount, "PROOF: Insufficient allowance");

        if (currentAllowance != type(uint256).max) {
            unchecked {
                s.proofAllowances[from][spender] = currentAllowance - amount;
            }
        }

        _proofTransfer(from, to, amount);
        return true;
    }

    function proofWrapperApprove(address owner_, address spender, uint256 amount) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(msg.sender == s.proofWrapper, "PROOF: Caller is not wrapper");
        LibAppStorage.enforceNotPaused();
        require(spender != address(0), "PROOF: Approve to zero address");

        s.proofAllowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
        return true;
    }

    // ============ Mint / Burn / Redeem ============

    /**
     * @notice Admin-only PROOF minting (with collateral enforcement)
     */
    function proofMint(address to, uint256 amount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(s.roles[LibAppStorage.ADMIN_ROLE][msg.sender], "PROOF: Not authorized to mint");
        LibAppStorage.enforceNotPaused();
        require(to != address(0), "PROOF: Mint to zero address");

        _enforceCollateralization(s.proofTotalSupply + amount);

        s.proofBalances[to] += amount;
        s.proofTotalSupply += amount;
        s.totalProofMinted += amount;

        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Anyone can burn their own PROOF
     */
    function proofBurn(uint256 amount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(s.proofBalances[msg.sender] >= amount, "PROOF: Insufficient balance");

        unchecked {
            s.proofBalances[msg.sender] -= amount;
            s.proofTotalSupply -= amount;
        }

        emit Transfer(msg.sender, address(0), amount);
    }

    /**
     * @notice Redeem PROOF for USDC from treasury (1% bonus to incentivize peg)
     * @dev Burns PROOF and sends real USDC via SafeERC20. Checks-effects-interactions.
     */
    function redeemProofForUSDC(uint256 proofAmount) external nonReentrant {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(proofAmount > 0, "PROOF: Cannot redeem zero");
        require(s.proofBalances[msg.sender] >= proofAmount, "PROOF: Insufficient balance");
        require(s.usdcAddress != address(0), "PROOF: USDC address not configured");

        // 1% bonus: 100 PROOF → 101 USDC
        uint256 usdcAmount = (proofAmount * 101) / 100;
        require(s.treasuryUSDC >= usdcAmount, "PROOF: Insufficient treasury USDC");

        // Effects (before external call)
        unchecked {
            s.proofBalances[msg.sender] -= proofAmount;
            s.proofTotalSupply -= proofAmount;
        }
        s.totalProofRedeemed += proofAmount;
        s.treasuryUSDC -= usdcAmount;

        // Interaction: send real USDC
        LibSafeERC20.safeTransfer(IERC20(s.usdcAddress), msg.sender, usdcAmount);

        emit ProofRedeemed(msg.sender, proofAmount, usdcAmount);
        emit Transfer(msg.sender, address(0), proofAmount);
    }

    // ============ Admin ============

    function proofSetWrapper(address wrapper) external {
        LibAppStorage.enforceIsAdmin();
        require(wrapper != address(0), "PROOF: Invalid wrapper address");
        LibAppStorage.appStorage().proofWrapper = wrapper;
    }

    // ============ View Functions ============

    /**
     * @notice Collateralization ratio using normalized decimals
     */
    function proofGetCollateralizationRatio() external view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        if (s.proofTotalSupply == 0) return type(uint256).max;

        uint256 totalCollateral = LibAppStorage.normalizedTreasuryTotal();
        return (totalCollateral * LibAppStorage.BASIS_POINTS) / s.proofTotalSupply;
    }

    function proofIsSystemHealthy() external view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        if (s.proofTotalSupply == 0) return true;

        uint256 totalCollateral = LibAppStorage.normalizedTreasuryTotal();
        uint256 requiredCollateral = (s.proofTotalSupply * s.minCollateralRatio) / LibAppStorage.BASIS_POINTS;
        return totalCollateral >= requiredCollateral;
    }

    // ============ Internal ============

    function _enforceCollateralization(uint256 newSupply) internal view {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        uint256 requiredCollateral = (newSupply * s.minCollateralRatio) / LibAppStorage.BASIS_POINTS;
        uint256 totalCollateral = LibAppStorage.normalizedTreasuryTotal();
        require(totalCollateral >= requiredCollateral, "PROOF: Insufficient collateral for minting");
    }

    function _proofTransfer(address from, address to, uint256 amount) internal {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();

        require(from != address(0), "PROOF: Transfer from zero address");
        require(to != address(0), "PROOF: Transfer to zero address");
        require(s.proofBalances[from] >= amount, "PROOF: Insufficient balance");

        unchecked {
            s.proofBalances[from] -= amount;
            s.proofBalances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }
}
