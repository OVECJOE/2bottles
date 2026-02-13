// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title ISwapRouter
 * @notice Minimal Uniswap V2-compatible router interface
 * @dev Used by TreasuryFacet for buyback-and-burn operations.
 *      Compatible with Uniswap V2, SushiSwap, and most V2-style AMM routers.
 *
 *      Reference router addresses:
 *      - Ethereum Mainnet (Uniswap V2): 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
 *      - Ethereum Mainnet (SushiSwap):  0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F
 */
interface ISwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}
