// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./compound/CToken.sol";
import "./interface/ShylockCTokenInterfaces.sol";
import "./interface/ShylockComptrollerInterface.sol";
import "./interface/ShylockComptrollerStorage.sol";
import "@openzeppelin-upgradeable/contracts/metatx/ERC2771ContextUpgradeable.sol";

/**
 * @title Shylock Finance's CToken Contract
 * @notice Abstract base for CTokens
 * @author Shylock Finance
 */


abstract contract ShylockCToken is CToken, ShylockCTokenInterface, ERC2771ContextUpgradeable {    
    function getAccountGuarantee(address account) public view returns (uint) {
        return shylockGuarantee[account].principal * borrowIndex / shylockGuarantee[account].interestIndex; 
    }

    function getBorrowContractdByIndex(address account, uint index) public returns (borrowContract memory) {
        // check the borrowContrac[index] is exist
        if(borrowContracts[account].length <= index){
            revert BrrowContracNotExist();
        }

        borrowContract memory borrowContract = borrowContracts[account][index];

        if (borrowContract.principal == 0) {
            revert BrrowContracNotExist();
        }

        uint newPrincipal = borrowContract.principal * borrowIndex / borrowContract.interestIndex;
        uint memberCollateralRateMantissa = ShylockComptrollerStorage(address(comptroller)).governanceContract().getMemberCollateralRate(borrowContract.dao, account);
        uint memberGuaranteeCollateral = div_(newPrincipal, memberCollateralRateMantissa);
        uint totalGuaranteeCollateral = newPrincipal - memberGuaranteeCollateral;
        uint protocolToDaoGuaranteeRateMantissa = ShylockComptrollerStorage(address(comptroller)).governanceContract().getProtocolToDaoGuaranteeRate(borrowContract.dao);
        uint daoGuaranteeCollateral = div_(totalGuaranteeCollateral, add_(Exp({mantissa: protocolToDaoGuaranteeRateMantissa}), Exp({mantissa: mantissaOne})));
        uint protocolGuaranteeCollateral = mul_ScalarTruncate(Exp({mantissa: protocolToDaoGuaranteeRateMantissa}), daoGuaranteeCollateral);
        memberGuaranteeCollateral = newPrincipal - daoGuaranteeCollateral - protocolGuaranteeCollateral;

        borrowContract.principal = newPrincipal;
        borrowContract.memberCollateral = memberGuaranteeCollateral;
        borrowContract.daoCollateral = daoGuaranteeCollateral;
        borrowContract.protocolCollateral = protocolGuaranteeCollateral;

        return borrowContract;
    }

    function addDaoReserveInternal(uint reserveAmount) internal nonReentrant {
        /* Fail if Dao not allowed */
        uint allowed = comptroller.addDaoReserveAllowed(address(this), _msgSender(), reserveAmount);
        if (allowed != 0) {
            revert AddDaoReserveComptrollerRejection(allowed);
        }

        uint actualReserveAmount = doTransferIn(_msgSender(), reserveAmount);

        shylockReserve[_msgSender()] = shylockReserve[_msgSender()] + actualReserveAmount;
        totalShylockReserve = totalShylockReserve + actualReserveAmount;

        emit AddDaoReserve(_msgSender(), actualReserveAmount, shylockReserve[_msgSender()]);
    }

    function addMemberReserveInternal(address dao, uint reserveAmount) internal nonReentrant {
        /* Fail if Member not allowed */
        uint allowed = comptroller.addMemberReserveAllowed(address(this), dao, _msgSender(), reserveAmount);
        if (allowed != 0) {
            revert AddMemberReserveComptrollerRejection(allowed);
        }

        uint actualReserveAmount = doTransferIn(_msgSender(), reserveAmount);

        shylockReserve[_msgSender()] = shylockReserve[_msgSender()] + actualReserveAmount;
        totalShylockReserve = totalShylockReserve + actualReserveAmount;

        emit AddMemberReserve(_msgSender(), actualReserveAmount, shylockReserve[_msgSender()]);
    }

    function withdrawDaoReserveInternal(uint withdrawTokens) internal nonReentrant {
        /* Fail if Dao not allowed */
        uint allowed = comptroller.withdrawDaoReserveAllowed(address(this), _msgSender(), withdrawTokens);
        if (allowed != 0) {
            revert WithdrawDaoReserveComptrollerRejection(allowed);
        }

        if (shylockReserve[_msgSender()] < withdrawTokens) {
            revert WithdrawDaoReserveInsufficientBalance();
        }
        
        doTransferOut(payable(_msgSender()), withdrawTokens);

        shylockReserve[_msgSender()] = shylockReserve[_msgSender()] - withdrawTokens;
        totalShylockReserve = totalShylockReserve - withdrawTokens;

        emit WithdrawDaoReserve(_msgSender(), withdrawTokens, shylockReserve[_msgSender()]);
    }
    
    function withdrawMemberReserveInternal(address dao, uint withdrawTokens) internal nonReentrant {
        /* Fail if Member not allowed */
        uint allowed = comptroller.withdrawMemberReserveAllowed(address(this), dao, _msgSender(), withdrawTokens);
        if (allowed != 0) {
            revert WithdrawMemberReserveComptrollerRejection(allowed);
        }
        
        if (shylockReserve[_msgSender()] < withdrawTokens) {
            revert WithdrawMemberReserveInsufficientBalance();
        }
        
        doTransferOut(payable(_msgSender()), withdrawTokens);

        shylockReserve[_msgSender()] = shylockReserve[_msgSender()] - withdrawTokens;
        totalShylockReserve = totalShylockReserve- withdrawTokens;

        emit WithdrawMemberReserve(_msgSender(), withdrawTokens, shylockReserve[_msgSender()]);
    }

    function borrowInternal(address dao, uint dueTimestamp, uint borrowAmount) internal nonReentrant {
        accrueInterest();
        // borrowFresh emits borrow-specific logs on errors, so we don't need to
        borrowFresh(dao, payable(_msgSender()), dueTimestamp, borrowAmount);
    }

    function borrowFresh(address dao, address payable borrower, uint dueTimestamp, uint borrowAmount) internal {
        /* Fail if borrow not allowed */
        uint allowed = comptroller.borrowAllowed(address(this), dao, borrower, borrowAmount);
        if (allowed != 0) {
            revert BorrowComptrollerRejection(allowed);
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            revert BorrowFreshnessCheck();
        }

        /* Fail gracefully if protocol has insufficient underlying cash */
        if (getCashPrior() < borrowAmount) {
            revert BorrowCashNotAvailable();
        }

        
        uint memberCollateralRateMantissa = ShylockComptrollerStorage(address(comptroller)).governanceContract().getMemberCollateralRate(dao, borrower);
        uint memberGuaranteeCollateral = div_(borrowAmount, memberCollateralRateMantissa);
        uint totalGuaranteeCollateral = borrowAmount - memberGuaranteeCollateral;
        uint protocolToDaoGuaranteeRateMantissa = ShylockComptrollerStorage(address(comptroller)).governanceContract().getProtocolToDaoGuaranteeRate(dao);
        uint daoGuaranteeCollateral = div_(totalGuaranteeCollateral, add_(Exp({mantissa: protocolToDaoGuaranteeRateMantissa}), Exp({mantissa: mantissaOne})));
        uint protocolGuaranteeCollateral = mul_ScalarTruncate(Exp({mantissa: protocolToDaoGuaranteeRateMantissa}), daoGuaranteeCollateral);
        uint actualBorrowAmount = memberGuaranteeCollateral + daoGuaranteeCollateral + protocolGuaranteeCollateral;
        
        shylockGuarantee[borrower].principal = getAccountGuarantee(borrower) + memberGuaranteeCollateral;
        shylockGuarantee[borrower].interestIndex = borrowIndex;
        shylockGuarantee[dao].principal = getAccountGuarantee(dao) + daoGuaranteeCollateral;
        shylockGuarantee[dao].interestIndex = borrowIndex;
        shylockGuarantee[address(comptroller)].principal = getAccountGuarantee(address(comptroller)) + protocolGuaranteeCollateral;
        shylockGuarantee[address(comptroller)].interestIndex = borrowIndex;

        borrowContracts[borrower].push(borrowContract({
            dao : dao,
            principal: actualBorrowAmount,
            memberCollateral: memberGuaranteeCollateral,
            daoCollateral: daoGuaranteeCollateral,
            protocolCollateral: protocolGuaranteeCollateral,
            interestIndex: borrowIndex,
            openTimestamp: block.timestamp,
            dueTimestamp: dueTimestamp
        }));

        uint accountBorrowsPrev = borrowBalanceStoredInternal(borrower);

        accountBorrows[borrower].principal = accountBorrowsPrev + actualBorrowAmount;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = totalBorrows + actualBorrowAmount;

        doTransferOut(borrower, actualBorrowAmount);

        /* We emit a Borrow event */
        emit Borrow(borrower, actualBorrowAmount, accountBorrowsPrev + actualBorrowAmount, totalBorrows + actualBorrowAmount);
    }


    function repayBorrowInternal(address dao, uint repayAmount, uint index) internal nonReentrant {
        accrueInterest();
        // repayBorrowFresh emits repay-borrow-specific logs on errors, so we don't need to
        repayBorrowFresh(_msgSender(), dao, _msgSender(), repayAmount, index);
    }

    function repayBorrowFresh(address payer, address dao, address borrower, uint repayAmount, uint index) internal returns (uint) {
        /* Fail if repayBorrow not allowed */
        uint allowed = comptroller.repayBorrowAllowed(address(this), payer, borrower, repayAmount);
        if (allowed != 0) {
            revert RepayBorrowComptrollerRejection(allowed);
        }

        /* Verify market's block number equals current block number */
        if (accrualBlockNumber != getBlockNumber()) {
            revert RepayBorrowFreshnessCheck();
        }

        /* We fetch the amount the borrower owes, with accumulated interest */
        uint accountBorrowsPrev = borrowBalanceStoredInternal(borrower);

        /* If repayAmount == -1, repayAmount = accountBorrows */
        uint repayAmountFinal = repayAmount == type(uint).max ? accountBorrowsPrev : repayAmount;

        uint actualRepayAmount;
        actualRepayAmount = doTransferIn(payer, repayAmountFinal);

        uint memberCollateralRateMantissa = ShylockComptrollerStorage(address(comptroller)).governanceContract().getMemberCollateralRate(dao, borrower);
        uint memberGuaranteeCollateral = div_(actualRepayAmount, memberCollateralRateMantissa);
        uint totalGuaranteeCollateral = actualRepayAmount - memberGuaranteeCollateral;
        uint protocolToDaoGuaranteeRateMantissa = ShylockComptrollerStorage(address(comptroller)).governanceContract().getProtocolToDaoGuaranteeRate(dao);
        uint daoGuaranteeCollateral = div_(totalGuaranteeCollateral, add_(Exp({mantissa: protocolToDaoGuaranteeRateMantissa}), Exp({mantissa: mantissaOne})));
        uint protocolGuaranteeCollateral = mul_ScalarTruncate(Exp({mantissa: protocolToDaoGuaranteeRateMantissa}), daoGuaranteeCollateral);
        memberGuaranteeCollateral = actualRepayAmount - daoGuaranteeCollateral - protocolGuaranteeCollateral;

        shylockGuarantee[borrower].principal = getAccountGuarantee(borrower) - memberGuaranteeCollateral;
        shylockGuarantee[borrower].interestIndex = borrowIndex;
        shylockGuarantee[dao].principal = getAccountGuarantee(dao) - daoGuaranteeCollateral;
        shylockGuarantee[dao].interestIndex = borrowIndex;
        shylockGuarantee[address(comptroller)].principal = getAccountGuarantee(address(comptroller)) - protocolGuaranteeCollateral;
        shylockGuarantee[address(comptroller)].interestIndex = borrowIndex;

        borrowContract memory nextBorrowContract = getBorrowContractdByIndex(borrower, index);

        borrowContract storage prevBorrowContract = borrowContracts[borrower][index];
        prevBorrowContract.principal = nextBorrowContract.principal- actualRepayAmount;
        prevBorrowContract.memberCollateral = nextBorrowContract.memberCollateral - memberGuaranteeCollateral;
        prevBorrowContract.daoCollateral = nextBorrowContract.daoCollateral - daoGuaranteeCollateral;
        prevBorrowContract.protocolCollateral = nextBorrowContract.protocolCollateral - protocolGuaranteeCollateral;
        prevBorrowContract.interestIndex = borrowIndex;

        if(prevBorrowContract.principal == 0 && prevBorrowContract.memberCollateral == 0 && prevBorrowContract.daoCollateral == 0 && prevBorrowContract.protocolCollateral == 0){
            uint len = borrowContracts[borrower].length;
            borrowContracts[borrower][index] = borrowContracts[borrower][len - 1];
            borrowContracts[borrower].pop();
        }

        /* We write the previously calculated values into storage */
        accountBorrows[borrower].principal = accountBorrowsPrev - actualRepayAmount;
        accountBorrows[borrower].interestIndex = borrowIndex;
        totalBorrows = totalBorrows - actualRepayAmount;

        /* We emit a RepayBorrow event */
        emit RepayBorrow(payer, borrower, actualRepayAmount, accountBorrowsPrev - actualRepayAmount, totalBorrows - actualRepayAmount);

        return actualRepayAmount;
    }

    
    /**
     * @dev Override for `msg.sender`. Defaults to the original `msg.sender` whenever
     * a call is not performed by the trusted forwarder or the calldata length is less than
     * 20 bytes (an address length).
     */
    function _msgSender() internal view virtual override returns (address) {
        uint256 calldataLength = msg.data.length;
        uint256 contextSuffixLength = _contextSuffixLength();
        if (isTrustedForwarder(msg.sender) && calldataLength >= contextSuffixLength) {
            return address(bytes20(msg.data[calldataLength - contextSuffixLength:]));
        } else {
            return super._msgSender();
        }
    }

    /**
     * @dev Override for `msg.data`. Defaults to the original `msg.data` whenever
     * a call is not performed by the trusted forwarder or the calldata length is less than
     * 20 bytes (an address length).
     */
    function _msgData() internal view virtual override returns (bytes calldata) {
        uint256 calldataLength = msg.data.length;
        uint256 contextSuffixLength = _contextSuffixLength();
        if (isTrustedForwarder(msg.sender) && calldataLength >= contextSuffixLength) {
            return msg.data[:calldataLength - contextSuffixLength];
        } else {
            return super._msgData();
        }
    }

    /**
     * @dev ERC-2771 specifies the context as being a single address (20 bytes).
     */
    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 20;
    }


}