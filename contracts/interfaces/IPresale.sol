// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IPresale {
    function totalBalance() view external returns (uint);
    function flipToken() view external returns (address);
}