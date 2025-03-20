// contracts/FlashLoan.sol
// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;
import {IVault} from "./IVault.sol";

interface IBalancerQueries {
    function querySwap(
        IVault.SingleSwap memory singleSwap,
        IVault.FundManagement memory funds
    ) external returns (uint256);
}
