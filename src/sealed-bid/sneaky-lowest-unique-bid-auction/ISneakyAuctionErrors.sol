// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

/// @title Custom errors for SneakyAuction
interface ISneakyAuctionErrors {
    error RevealPeriodOngoingError();
    error InvalidAuctionIndexError(uint32 index);
    error BidPeriodTooShortError(uint32 bidPeriod);
    error RevealPeriodTooShortError(uint32 revealPeriod);
    error NotInRevealPeriodError();
    error IncorrectVaultAddressError(
        address expectedVault,
        address actualVault
    );
    error UnrevealedBidError();
    error CannotWithdrawError();
    error BidAlreadyRevealedError(address vault);

    error CollateralizationDeadlineNotReachedError();
    error BidNotLowEnoughError();
    error CollateralizationDeadlineTooEarlyError();
    error NotAuthorizedError();

    error ContractPausedError();
    error OnlyOwnerError();
    error AuctionInProgressError();

    error AddressBannedError();
    error AddressForbiddenError();

    error InvalidPriceError();
    error InvalidDurationError();
    error TokenBlacklistedError();

    error InsufficientBalanceError();
    error InsufficientAllowanceError();
    error InvalidBidError();

    error CommitmentAlreadyOpenedError();
    error InvalidCommitmentError();
    error InvalidProofError();
    error CreateAuctionTokenNotOwned();
    // error ReservePriceEqualtoZero();
}
