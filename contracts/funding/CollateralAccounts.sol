/*

    Copyright 2019 The Hydro Protocol Foundation

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;


import "../GlobalStore.sol";

import "../lib/SafeMath.sol";
import "../lib/Consts.sol";
import { Types, Loan, Asset } from "../lib/Types.sol";

contract CollateralAccounts is GlobalStore, Consts {
    using SafeMath for uint256;
    using Loan for Types.Loan;
    using Asset for Types.Asset;

    function findOrCreateDefaultCollateralAccount(address user) internal returns (Types.CollateralAccount storage) {
        uint256 id = state.userDefaultCollateralAccounts[user];
        Types.CollateralAccount storage account = state.allCollateralAccounts[id];

        if (account.owner != user) {
            // default account liquidate rate is 150%
            id = createCollateralAccount(user, 150);
            state.userDefaultCollateralAccounts[user] = id;
            account = state.allCollateralAccounts[id];
        }

        return account;
    }

    function createCollateralAccount(address user, uint16 liquidateRate) internal returns (uint256) {
        uint32 id = state.collateralAccountCount++;
        Types.CollateralAccount memory account;

        account.id = id;
        account.liquidateRate = liquidateRate;
        account.owner = user;

        state.allCollateralAccounts[id] = account;
        return id;
    }

    // // deposit collateral for default account
    // function depositCollateral(address token, address user, uint256 amount) public {
    //     if (amount == 0) {
    //         return;
    //     }

    //     DepositProxyInterface(proxyAddress).depositFor(token, user, user, amount);
    //     depositCollateralFromProxy(token, user, amount);
    // }

    // function depositCollateralFromProxy(address token, address user, uint256 amount) public {
    //     if (amount == 0) {
    //         return;
    //     }

    //     address payable currentContract = address(uint160(address(this)));
    //     DepositProxyInterface(proxyAddress).withdrawTo(token, user, currentContract, amount);

    //     CollateralAccount storage account = findOrCreateDefaultCollateralAccount(user);
    //     account.assetAmounts[token] = account.assetAmounts[token].add(amount);

    //     emit DepositCollateral(token, user, amount);
    // }

    /**
     * Get a user's default collateral account asset balance
     */
    function collateralBalanceOf(uint16 assetID, address user) public view returns (uint256) {
        uint256 id = state.userDefaultCollateralAccounts[user];
        Types.CollateralAccount storage account = state.allCollateralAccounts[id];

        if (account.owner != user) {
            return 0;
        }

        return account.collateralAssetAmounts[assetID];
    }

    // to allow proxy transfer ether into this current contract
    // TODO: is there a way to prevent a user from depositing unexpectedly??
    function () external payable {}

    function getCollateralAccountDetails(uint256 id)
        public view
        returns (Types.CollateralAccountDetails memory details)
    {
        Types.CollateralAccount storage account = state.allCollateralAccounts[id];
        details.collateralAssetAmounts = new uint256[](state.assetsCount);

        for (uint16 i = 0; i < state.assetsCount; i++) {
            Types.Asset storage asset = state.assets[i];

            uint256 amount = account.collateralAssetAmounts[i];

            details.collateralAssetAmounts[i] = amount;
            details.collateralsTotalUSDlValue = details.collateralsTotalUSDlValue.add(asset.getPrice().mul(amount));
        }

        details.loans = getLoansByIDs(account.loanIDs);

        if (details.loans.length <= 0) {
            return details;
        }

        details.loanValues = new uint256[](details.loans.length);

        for (uint256 i = 0; i < details.loans.length; i++) {

            uint256 totalInterest = details.loans[i].
                interest(details.loans[i].amount, getBlockTimestamp()).
                div(INTEREST_RATE_BASE.mul(SECONDS_OF_YEAR));

            Types.Asset storage asset = state.assets[details.loans[i].assetID];

            details.loanValues[i] = asset.getPrice().mul(details.loans[i].amount.add(totalInterest));
            details.loansTotalUSDValue = details.loansTotalUSDValue.add(details.loanValues[i]);
        }

        details.liquidable = details.collateralsTotalUSDlValue < details.loansTotalUSDValue.mul(account.liquidateRate).div(LIQUIDATE_RATE_BASE);
    }

    function liquidateCollateralAccounts(uint256[] memory accountIDs) public {
        for( uint256 i = 0; i < accountIDs.length; i++ ) {
            liquidateCollateralAccount(accountIDs[i]);
        }
    }

    function isCollateralAccountLiquidable(uint256 id) public view returns (bool) {
        Types.CollateralAccountDetails memory details = getCollateralAccountDetails(id);
        return details.liquidable;
    }

    function liquidateCollateralAccount(uint256 id) public returns (bool) {
        Types.CollateralAccount storage account = state.allCollateralAccounts[id];
        Types.CollateralAccountDetails memory details = getCollateralAccountDetails(id);

        if (!details.liquidable) {
            return false;
        }

        // storage changes
        for (uint256 i = 0; i < details.loans.length; i++ ) {
            createAuction(details.loans[i].id, details.loans[i].amount, details.collateralAssetAmounts);
            removeLoanIDFromCollateralAccount(details.loans[i].id, id);
        }

        // confiscate all collaterals
        // transfer all user collateral to liquidatingAssets;
        for (uint16 i = 0; i < state.assetsCount; i++) {
            // liquidatingAssets[asset.tokenAddress] = liquidatingAssets[asset.tokenAddress].add(account.assetAmounts[asset.tokenAddress]);
            account.collateralAssetAmounts[i] = 0;
        }

        return true;
    }
}