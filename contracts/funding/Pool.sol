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

import "../lib/SafeMath.sol";
import "../lib/Types.sol";
import "../lib/Consts.sol";
import "../GlobalStore.sol";

contract Pool is Consts, GlobalStore {
    using SafeMath for uint256;

    // supply asset
    function supplyPool(uint16 assetID, uint256 amount) public {

        require(state.balances[assetID][msg.sender] >= amount, "USER_BALANCE_NOT_ENOUGH");

        // first supply
        if (state.pool.totalSupply[assetID] == 0){
            state.balances[assetID][msg.sender] -= amount;
            state.pool.totalSupply[assetID] = amount;
            state.pool.supplyShares[assetID][msg.sender] = amount;
            state.pool.totalSupplyShares[assetID] = amount;
            return ;
        }

        // accrue interest
        _accrueInterest(assetID);

        // new supply shares
        uint256 shares = amount.mul(state.pool.totalSupplyShares[assetID]).div(state.pool.totalSupply[assetID]);
        state.balances[assetID][msg.sender] -= amount;
        state.pool.totalSupply[assetID] = state.pool.totalSupply[assetID].add(amount);
        state.pool.supplyShares[assetID][msg.sender] = state.pool.supplyShares[assetID][msg.sender].add(shares);
        state.pool.totalSupplyShares[assetID] = state.pool.totalSupplyShares[assetID].add(shares);

    }

    // withdraw asset
    // to avoid precision problem, input share amount instead of token amount
    function withdrawPool(uint16 assetID, uint256 sharesAmount) public {

        uint256 assetAmount = sharesAmount.mul(state.pool.totalSupply[assetID]).div(state.pool.totalSupplyShares[assetID]);
        require(sharesAmount <= state.pool.supplyShares[assetID][msg.sender], "USER_BALANCE_NOT_ENOUGH");
        require(assetAmount.add(state.pool.totalBorrow[assetID]) <= state.pool.totalSupply[assetID], "POOL_BALANCE_NOT_ENOUGH");

        state.pool.supplyShares[assetID][msg.sender] -= sharesAmount;
        state.pool.totalSupplyShares[assetID] -= sharesAmount;
        state.pool.totalSupply[assetID] -= assetAmount;
        state.balances[assetID][msg.sender] += assetAmount;

    }

    // borrow and repay
    function borrowPool(
        uint32 collateralAccountId,
        uint16 assetID,
        uint256 amount,
        uint16 maxInterestRate,
        uint40 minExpiredAt
    ) internal returns (uint32[] memory loanIds){

        // check amount & interest
        uint16 interestRate = getInterestRate(assetID, amount);
        require(interestRate > maxInterestRate, "INTEREST_RATE_EXCEED_LIMITATION");
        _accrueInterest(assetID);

        // build loan
        Types.Loan memory loan = Types.Loan(
            state.loansCount++,
            assetID,
            collateralAccountId,
            getBlockTimestamp(),
            minExpiredAt,
            interestRate,
            Types.LoanSource.Pool,
            amount
        );

        // record global loan
        state.allLoans[loan.id] = loan;

        // record collateral account loan
        Types.CollateralAccount storage account = state.allCollateralAccounts[collateralAccountId];
        account.loanIDs.push(loan.id);

        // set borrow amount
        state.pool.totalBorrow[assetID] += amount;
        state.pool.poolAnnualInterest += amount.mul(interestRate).div(INTEREST_RATE_BASE);

        loanIds[0] = loan.id;
        return loanIds;

    }

    function repayPool(uint32 loanId, uint256 amount) internal {

        Types.Loan storage loan = state.allLoans[loanId];
        require(loan.source==Types.LoanSource.Pool, "LOAN_NOT_CREATED_BY_POOL");

        require(amount <= loan.amount, "REPAY_AMOUNT_TOO_MUCH");

        // minus first and add second
        state.pool.poolAnnualInterest -= uint256(loan.interestRate).mul(loan.amount).div(INTEREST_RATE_BASE);
        loan.amount -= amount;
        state.pool.poolAnnualInterest += uint256(loan.interestRate).mul(loan.amount).div(INTEREST_RATE_BASE);

        state.pool.totalBorrow[loan.assetID] -= amount;

    }

    // get interestRate
    function getInterestRate(uint16 assetID, uint256 amount) public view returns(uint16 interestRate){
        // 使用计提利息后的supply
        uint256 interest = _getUnpaidInterest(assetID);

        uint256 supply = state.pool.totalSupply[assetID].add(interest);
        uint256 borrow = state.pool.totalBorrow[assetID].add(amount);

        require(supply >= borrow, "BORROW_EXCEED_LIMITATION");

        uint256 borrowRatio = borrow.mul(INTEREST_RATE_BASE).div(supply);

        // 0.2r + 0.5r^2
        uint256 rate1 = borrowRatio.mul(INTEREST_RATE_BASE).mul(2);
        uint256 rate2 = borrowRatio.mul(borrowRatio).mul(5);

        return uint16(rate1.add(rate2).div(INTEREST_RATE_BASE.mul(10)));
    }

    // accrue interest to totalSupply
    function _accrueInterest(uint16 assetID) internal {

        // interest since last update
        uint256 interest = _getUnpaidInterest(assetID);

        // accrue interest to supply
        state.pool.totalSupply[assetID] = state.pool.totalSupply[assetID].add(interest);

        // update interest time
        state.pool.poolInterestStartTime = getBlockTimestamp();
    }

    function _getUnpaidInterest(uint16 assetID) internal view returns(uint256) {
        uint256 interest = uint256(getBlockTimestamp())
            .sub(state.pool.poolInterestStartTime)
            .mul(state.pool.poolAnnualInterest)
            .div(SECONDS_OF_YEAR);
        return interest;
    }

}