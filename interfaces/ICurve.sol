// contracts/FlashLoan.sol
// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.7.0 <0.9.0;

interface ICurve {
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 dy,
        bool use_eth
    ) external payable;

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 _dx
    ) external view returns (uint256);
}
