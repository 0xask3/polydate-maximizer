// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface ILockedStrategy {
    function withdrawablePrincipalOf(address account) external view returns (uint);
}