// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/*
  ___                      _   _
 | _ )_  _ _ _  _ _ _  _  | | | |
 | _ \ || | ' \| ' \ || | |_| |_|
 |___/\_,_|_||_|_||_\_, | (_) (_)
                    |__/

*
* MIT License
* ===========
*
* Copyright (c) 2020 DateFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IDateMinterV2.sol";
import "../interfaces/IStakingRewards.sol";
import "../interfaces/IPriceCalculator.sol";
import "../interfaces/IPancakeRouter02.sol";
import "../interfaces/IPancakePair.sol";
import "../interfaces/IZap.sol";

import "../library/SafeToken.sol";

contract DateMinterV2 is IDateMinterV2, OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    //All addresses should be replaced with correspoding contract address of polydate

    address private constant TIMELOCK = 0xf36eC1522625b2eBD0b4071945F3e97134653F8f;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public constant DEPLOYER = 0xbC776ac3af4D993774A54af497055170C81c113F;

    address public constant DATE = 0x869a6f4Bee6A09221a7dB6F5d04c166342B05a3E;
    address public constant DATE_ETH = 0x62052b489Cb5bC72a9DC8EEAE4B24FD50639921a;
    address public constant DATE_POOL = 0x10C8CFCa4953Bc554e71ddE3Fa19c335e163D7Ac;
    address public constant DATE_MAXIMIZER = 0x4Ad69DC9eA7Cc01CE13A37F20817baC4bF0De1ba;
    IBEP20 public constant ETH = IBEP20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);

    IZap private constant zapPolygon = IZap(0x663462430834E220851a3E981D0E1199501b84F6);
    IZap private constant zapSushi = IZap(0x93bCE7E49E26AF0f87b74583Ba6551DF5E4867B7);
    IPriceCalculator private constant priceCalculator = IPriceCalculator(0xE3B11c3Bd6d90CfeBBb4FB9d59486B0381D38021);
    address private constant quickRouter = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
    address private constant sushiRouter = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;

    uint public constant FEE_MAX = 10000;

    /* ========== STATE VARIABLES ========== */

    address public DateChef;
    mapping(address => bool) private _minters;

    uint public PERFORMANCE_FEE;
    uint public override WITHDRAWAL_FEE_FREE_PERIOD;
    uint public override WITHDRAWAL_FEE;

    uint public override DatePerProfitBNB;

    uint private _floatingRateEmission;
    uint private _freThreshold;

    /* ========== MODIFIERS ========== */

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "DateMinterV2: caller is not the minter");
        _;
    }

    modifier onlyDateChef {
        require(msg.sender == DateChef, "DateMinterV2: caller not the Date chef");
        _;
    }

    /* ========== EVENTS ========== */

    event PerformanceFee(address indexed asset, uint amount, uint value);

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
        WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
        WITHDRAWAL_FEE = 50;
        PERFORMANCE_FEE = 3000;

        IBEP20(DATE).approve(DATE_POOL, ~uint(0));
        IBEP20(DATE).approve(DATE_MAXIMIZER, ~uint(0));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferDateOwner(address _owner) external onlyOwner {
        Ownable(DATE).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");
        // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint) external override onlyOwner {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function setDateChef(address _DateChef) external onlyOwner {
        require(DateChef == address(0), "DateMinterV2: setDateChef only once");
        DateChef = _DateChef;
    }

    function setFloatingRateEmission(uint __floatingRateEmission) external onlyOwner {
        require(__floatingRateEmission > 1e18 && __floatingRateEmission < 10e18, "DateMinterV2: floatingRateEmission wrong range");
        _floatingRateEmission = __floatingRateEmission;
    }

    function setFREThreshold(uint threshold) external onlyOwner {
        _freThreshold = threshold;
    }

    /* ========== VIEWS ========== */

    function isMinter(address account) public view override returns (bool) {
        if (IBEP20(DATE).getOwner() != address(this)) {
            return false;
        }
        return _minters[account];
    }

    function amountDateToMint(uint ethProfit) public view override returns (uint) {
        if (priceCalculator.priceOfDate() == 0) {
            return 0;
        }
        return ethProfit.mul(priceCalculator.priceOfETH()).div(priceCalculator.priceOfDate()).mul(floatingRateEmission()).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) external view override returns (uint) {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) public view override returns (uint) {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    function floatingRateEmission() public view returns (uint) {
        return _floatingRateEmission == 0 ? 200e16 : _floatingRateEmission;
    }

    function freThreshold() public view returns (uint) {
        return _freThreshold == 0 ? 500e18 : _freThreshold;
    }

    function shouldMarketBuy() public view returns (bool) {
        return priceCalculator.priceOfDate().mul(freThreshold()).div(priceCalculator.priceOfETH()) < 1e18 - 1000;
    }

    /* ========== V1 FUNCTIONS ========== */

    function mintFor(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint) public payable override onlyMinter {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        _transferAsset(asset, feeSum);

        if (asset == DATE) {
            IBEP20(DATE).safeTransfer(TIMELOCK, feeSum);
            return;
        }

        bool marketBuy = shouldMarketBuy();
        if (marketBuy == false) {

            uint DateETHAmount = _zapAssets(asset, feeSum, DATE_ETH);
            if (DateETHAmount == 0) return;

            IBEP20(DATE_ETH).safeTransfer(DATE_POOL, DateETHAmount);
            IStakingRewards(DATE_POOL).notifyRewardAmount(DateETHAmount);
        } else {
            if (_withdrawalFee > 0) {

                uint DateETHAmount = _zapAssets(asset, _withdrawalFee, DATE_ETH);
                if (DateETHAmount == 0) return;

                IBEP20(DATE_ETH).safeTransfer(DATE_POOL, DateETHAmount);
                IStakingRewards(DATE_POOL).notifyRewardAmount(DateETHAmount);
            }

            if (_performanceFee == 0) return;

            uint DateAmount = _zapAssets(asset, _performanceFee, DATE);
            IBEP20(DATE).safeTransfer(to, DateAmount);

            _performanceFee = _performanceFee.mul(floatingRateEmission().sub(1e18)).div(floatingRateEmission());
        }

        (uint contributionInETH, uint contributionInUSD) = priceCalculator.valueOfAsset(asset, _performanceFee);

        uint mintDate = amountDateToMint(contributionInETH);
        if (mintDate == 0) return;
        _mint(mintDate, to);

        if (marketBuy) {
            uint usd = contributionInUSD.mul(floatingRateEmission()).div(floatingRateEmission().sub(1e18));
            emit PerformanceFee(asset, _performanceFee, usd);
        } else {
            emit PerformanceFee(asset, _performanceFee, contributionInUSD);
        }
    }

    /* ========== PancakeSwap V2 FUNCTIONS ========== */

    function mintForV2(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint timestamp) external payable override onlyMinter {
        mintFor(asset, _withdrawalFee, _performanceFee, to, timestamp);
    }

    /* ========== DateChef FUNCTIONS ========== */

    function mint(uint amount) external override onlyDateChef {
        if (amount == 0) return;
        _mint(amount, address(this));
    }

    function safeDateTransfer(address _to, uint _amount) external override onlyDateChef {
        if (_amount == 0) return;

        uint bal = IBEP20(DATE).balanceOf(address(this));
        if (_amount <= bal) {
            IBEP20(DATE).safeTransfer(_to, _amount);
        } else {
            IBEP20(DATE).safeTransfer(_to, bal);
        }
    }

    // @dev should be called when determining mint in governance. Date is transferred to the timelock contract.
    function mintGov(uint amount) external override onlyOwner {
        if (amount == 0) return;
        _mint(amount, TIMELOCK);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _zapAssets(address asset, uint amount, address toAsset) private returns (uint toAssetAmount) {
        if (asset == toAsset) return amount;
        uint _initToAssetAmount = IBEP20(toAsset).balanceOf(address(this));

        if (asset == address(0)) {
            zapPolygon.zapIn{value : amount}(toAsset);
        }
        else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("UNI-V2") ||
            keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("SLP")) {
            IPancakeRouter02 router = IPancakeRouter02(_getRouterAddress(asset));

            if (IBEP20(asset).allowance(address(this), address(router)) == 0) {
                IBEP20(asset).safeApprove(address(router), ~uint(0));
            }

            IPancakePair pair = IPancakePair(asset);
            address token0 = pair.token0();
            address token1 = pair.token1();

            if (IPancakePair(asset).balanceOf(asset) > 0) {
                IPancakePair(asset).burn(address(DEPLOYER));
            }
            (uint amountToken0, uint amountToken1) = router.removeLiquidity(token0, token1, amount, 0, 0, address(this), block.timestamp);

            _tokenToAsset(token0, amountToken0, toAsset);
            _tokenToAsset(token1, amountToken1, toAsset);
        }
        else {
            // default. zap single asset to other asset in quickswap
            if (IBEP20(asset).allowance(address(this), address(zapPolygon)) == 0) {
                IBEP20(asset).safeApprove(address(zapPolygon), ~uint(0));
            }

            zapPolygon.zapInToken(asset, amount, toAsset);
        }

        toAssetAmount = IBEP20(toAsset).balanceOf(address(this)).sub(_initToAssetAmount);
    }

    function _tokenToAsset(address _token, uint _amount, address _toAsset) private {
        if (zapPolygon.covers(_token)) {
            if (_token != _toAsset) {
                if (IBEP20(_token).allowance(address(this), address(zapPolygon)) == 0) {
                    IBEP20(_token).safeApprove(address(zapPolygon), ~uint(0));
                }

                zapPolygon.zapInToken(_token, _amount, _toAsset);
            }
        } else {
            if (IBEP20(_token).allowance(address(this), address(zapSushi)) == 0) {
                IBEP20(_token).safeApprove(address(zapSushi), ~uint(0));
            }

            uint initETHBalance = ETH.balanceOf(address(this));
            zapSushi.zapInToken(_token, _amount, address(ETH));

            if (ETH.allowance(address(this), address(zapPolygon)) == 0) {
                ETH.safeApprove(address(zapPolygon), ~uint(0));
            }
            zapPolygon.zapInToken(address(ETH), ETH.balanceOf(address(this)).sub(initETHBalance), _toAsset);
        }
    }

    function _transferAsset(address asset, uint amount) private {
        if (asset == address(0)) {
            // case) transferred BNB
            require(msg.value >= amount);
        } else {
            IBEP20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _mint(uint amount, address to) private {
        BEP20 tokenDATE = BEP20(DATE);

        tokenDATE.mint(amount);
        if (to != address(this)) {
            tokenDATE.transfer(to, amount);
        }

        uint DateForDev = amount.mul(15).div(100);
        tokenDATE.mint(DateForDev);
        IStakingRewards(DATE_MAXIMIZER).stakeTo(DateForDev, DEPLOYER);
    }

    function _getRouterAddress(address asset) private pure returns (address _routerAddress) {
        _routerAddress = keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("SLP") ? sushiRouter : quickRouter;
    }

}
