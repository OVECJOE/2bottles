// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../libraries/LibAppStorage.sol";

/**
 * @title ProofTokenFacet
 * @notice Implements the PROOF token - the stable utility token for payments
 * @dev Standard ERC20 designed to maintain $1 peg
 *      
 *      PROOF is minted by:
 *      - Staking 2BTL (bonding curve)
 *      
 *      PROOF is used for:
 *      - Paying at partner venues
 *      - Tipping servers
 *      - Gifting to friends
 *      
 *      PROOF can be redeemed for:
 *      - USDC from treasury (at slightly favorable rate to maintain peg)
 *      
 *      Unlike 2BTL, PROOF has NO transfer fee (it's for spending!)
 */
contract ProofTokenFacet {
    
    // ============ Events ============
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event ProofMinted(address indexed user, uint256 amount, uint256 btlStaked);
    event ProofRedeemed(address indexed user, uint256 proofAmount, uint256 usdcAmount);

    // ============ ERC20 View Functions ============

    function proofName() external view returns (string memory) {
        return LibAppStorage.appStorage().proofName;
    }

    function proofSymbol() external view returns (string memory) {
        return LibAppStorage.appStorage().proofSymbol;
    }

    function proofDecimals() external pure returns (uint8) {
        return 6; // Match USDC for easy conversion
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

    // ============ ERC20 Transfer Functions ============

    /**
     * @notice Transfer PROOF tokens (NO FEE!)
     */
    function proofTransfer(address to, uint256 amount) external returns (bool) {
        LibAppStorage.enforceNotPaused();
        _proofTransfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Transfer PROOF tokens from another account
     */
    function proofTransferFrom(address from, address to, uint256 amount) external returns (bool) {
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

    /**
     * @notice Approve a spender to use your PROOF
     */
    function proofApprove(address spender, uint256 amount) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        
        s.proofAllowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Increase allowance for a spender
     */
    function proofIncreaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        
        s.proofAllowances[msg.sender][spender] += addedValue;
        emit Approval(msg.sender, spender, s.proofAllowances[msg.sender][spender]);
        return true;
    }

    /**
     * @notice Decrease allowance for a spender
     */
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

    // ============ Mint/Burn Functions ============

    /**
     * @notice Mint PROOF tokens (only admin/staking)
     */
    function proofMint(address to, uint256 amount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        require(s.roles[LibAppStorage.ADMIN_ROLE][msg.sender], "PROOF: Not authorized to mint");
        LibAppStorage.enforceNotPaused();
        
        // Check collateralization before minting
        uint256 newSupply = s.proofTotalSupply + amount;
        uint256 requiredCollateral = (newSupply * s.minCollateralRatio) / LibAppStorage.BASIS_POINTS;
        require(s.treasuryUSDC + s.treasuryDAI >= requiredCollateral, "PROOF: Insufficient collateral");
        
        s.proofBalances[to] += amount;
        s.proofTotalSupply += amount;
        s.totalProofMinted += amount;
        
        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Burn PROOF tokens (anyone can burn their own)
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
     * @notice Redeem PROOF for USDC from treasury (1% bonus)
     */
    function redeemProofForUSDC(uint256 proofAmount) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        LibAppStorage.enforceNotPaused();
        require(s.proofBalances[msg.sender] >= proofAmount, "PROOF: Insufficient balance");
        
        // Calculate USDC to give (1% bonus to help maintain peg)
        uint256 usdcAmount = (proofAmount * 101) / 100;
        require(s.treasuryUSDC >= usdcAmount, "PROOF: Insufficient treasury USDC");
        
        // Burn PROOF
        unchecked {
            s.proofBalances[msg.sender] -= proofAmount;
            s.proofTotalSupply -= proofAmount;
        }
        s.totalProofRedeemed += proofAmount;
        
        // Deduct from treasury accounting
        s.treasuryUSDC -= usdcAmount;
        
        // Note: Actual USDC transfer happens via external call in production
        
        emit ProofRedeemed(msg.sender, proofAmount, usdcAmount);
        emit Transfer(msg.sender, address(0), proofAmount);
    }

    // ============ View Functions ============

    /**
     * @notice Get current collateralization ratio
     */
    function proofGetCollateralizationRatio() external view returns (uint256) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        if (s.proofTotalSupply == 0) {
            return type(uint256).max;
        }
        
        uint256 totalCollateral = s.treasuryUSDC + s.treasuryDAI;
        return (totalCollateral * LibAppStorage.BASIS_POINTS) / s.proofTotalSupply;
    }

    /**
     * @notice Check if system is healthy
     */
    function proofIsSystemHealthy() external view returns (bool) {
        LibAppStorage.AppStorage storage s = LibAppStorage.appStorage();
        
        if (s.proofTotalSupply == 0) {
            return true;
        }
        
        uint256 totalCollateral = s.treasuryUSDC + s.treasuryDAI;
        uint256 requiredCollateral = (s.proofTotalSupply * s.minCollateralRatio) / LibAppStorage.BASIS_POINTS;
        
        return totalCollateral >= requiredCollateral;
    }

    // ============ Internal Functions ============

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
