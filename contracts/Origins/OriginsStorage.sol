pragma solidity ^0.5.17;

import "../Interfaces/IERC20.sol";
import "../Openzeppelin/SafeMath.sol";
import "../Openzeppelin/SafeERC20.sol";
import "../Interfaces/ILockedFund.sol";
import "../Interfaces/IStaking.sol";

/**
 *  @title A storage contract for Origins Platform.
 *  @author Shebin John - admin@remedcu.com
 *  @notice This plays as the harddisk for the Origins Platform.
 */
contract OriginsStorage {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	/* Storage */

	/// @notice This determines the number of tiers in the system. When creating a tier, it should always start at 1.
	uint256 internal tierCount;
	/// @notice The maximum allowed Basis Point.
	uint256 internal constant MAX_BASIS_POINT = 10000;
	/// @notice Contains the number of unique wallets who participated in the sale.
	uint256 internal participatingWalletCount;

	/// @notice The address to deposit the raised amount. If not set, will be holded in this contract itself, withdrawable by any owner.
	address payable internal depositAddress;
	/// @notice The token which is being sold.
	IERC20 internal token;
	/// @notice The Locked Fund contract.
	ILockedFund internal lockedFund;

	/**
	 * @notice The method by which users will be depositing in each tier.
	 * RBTC - The deposit will be made in RBTC.
	 * Token - The deposit will be made in any ERC20 Token set in depositToken in Tier Struct.
	 */
	enum DepositType {
		RBTC,
		Token
	}
	/**
	 * @notice The method by which we determine whether the sale ended or not.
	 * None - This type is not set, so no one is allowed for sale yet.
	 * UntilSupply - This type is set to allow sale until each tier runs out of token.
	 * Duration - This type is set to allow sale until a particular duration.
	 * Timestamp - This type is set to allow sale until a particular timestamp.
	 */
	enum SaleEndDurationOrTS {
		None,
		UntilSupply,
		Duration,
		Timestamp
	}
	/**
	 * @notice The method by which the verification is happening.
	 * None - The type is not set, so no one is approved for sale.
	 * Everyone - This type is set to allow everyone.
	 * ByAddress - This type is set to allow only verified addresses.
	 * ByStake - This type is set to allow only addresses with minimum stake requirement.
	 * TODO: ByVest - This type is set to allow only addresses with minimum vesting requirement.
	 */
	enum VerificationType {
		None,
		Everyone,
		ByAddress,
		ByStake
	}
	/**
	 * @notice The method by which the distribution is happening.
	 * None - The distribution is not set yet, so tokens remain in the contract.
	 * Unlocked - The tokens are distributed right away.
	 * WaitedUnlock - The tokens are withdrawable from this contract after a certain period.
	 * Vested - The tokens are vested (based on the contracts from Sovryn) for a certain period.
	 * Locked - The tokens are locked without any benefit based on cliff and duration.
	 * NWaitedUnlock - Same as WaitedUnlock, but No token transfer is done.
	 * NVested - Same as Vested, but No token transfer is done.
	 * NLocked - Same as Locked, but No token transfer is done.
	 * @dev Values starting with N (except None) is expected that Locked Fund will be receiving the Tokens directly.
	 */
	enum TransferType {
		None,
		Unlocked,
		WaitedUnlock,
		Vested,
		Locked,
		NWaitedUnlock,
		NVested,
		NLocked
	}

	/**
	 * @notice The method by which the sale is happening.
	 * None - Sale Type is not set. Default value.
	 * FCFS - Sale Type is First Come First Serve.
	 * Pooled - Sale Type is Pooled.
	 * @dev There could a new one called demand pooled or so, where there is no refund, and the token price is calculated based on demand.
	 */
	enum SaleType {
		None,
		FCFS,
		Pooled
	}

	/**
	 * @notice The type of Unlock for LockedFund.
	 * None - The unlock is not set yet.
	 * Immediate - The tokens will be unlocked immediately.
	 * Waited - The tokens will be unlocked only after a particular time period.
	 */
	enum UnlockType {
		None,
		Immediate,
		Waited
	}

	/// @notice The tiers based on the tier id, taken from tier count.
	mapping(uint256 => Tier) internal tiers;

	/// @notice The below would have been added to Struct `Tier` if the parameter list was not reaching the higher limits.
	/// @notice The address to tier ID to uint mapping which contains the amount of tokens bought by that particular address.
	mapping(address => mapping(uint256 => uint256)) internal tokensBoughtByAddressOnTier;
	/// @notice Contains the number of unique wallets who participated in the sale in a particular Tier.
	mapping(uint256 => uint256) internal participatingWalletCountPerTier;
	/// @notice The address to uint mapping which contains the amount of tokens bought by that particular address.
	mapping(address => uint256) internal tokensBoughtByAddress;
	/// @notice Contains the amount of token allocation provided by the tier.
	mapping(uint256 => uint256) internal totalTokenAllocationPerTier;
	/// @notice Contains the amount of tokens sold in a particular Tier.
	mapping(uint256 => uint256) internal tokensSoldPerTier;
	/// @notice Contains if a tier sale ended or not.
	mapping(uint256 => bool) internal tierSaleEnded;
	/// @notice Contains if a tier asset collected withdrawn or not.
	mapping(uint256 => bool) internal tierSaleWithdrawn;

	/// @notice The address to uint to bool mapping to see if the particular address is eligible or not for a tier.
	mapping(address => mapping(uint256 => bool)) internal addressApproved;
	/// @notice The uint to Stake mapping to see the particular stake conditions.
	mapping(uint256 => Stake) internal stakeCondition;
	/// @notice The address to bool mapping to see if user already claimed token in pool sale type or not.
	mapping(address => bool) internal userPoolClaimed;

	/**
	 * @notice The Stake Structure
	 * @param minStake The minimum stake requirement.
	 * @param maxStake The maximum stake requirement.
	 * @param blockNumber The array of blocknumbers to check.
	 * @param date The array of date (timestamps) to check.
	 * @param staking The staking address.
	 * @dev If the maxStake is set as zero, then there is no upper limit.
	 */
	struct Stake {
		uint256 minStake;
		uint256 maxStake;
		uint256[] blockNumber;
		uint256[] date;
		IStaking staking;
	}

	/**
	 * @notice The Tier Structure.
	 * minAmount - The minimum amount which can be deposited.
	 * maxAmount - The maximum amount which can be deposited.
	 * remainingTokens - Contains the remaining tokens for sale.
	 * saleStartTS - Contains the timestamp for the sale to start. Before which no user will be able to buy tokens.
	 * saleEnd - Contains the duration or timestamp for the sale to end. After which no user will be able to buy tokens.
	 * unlockBP - Contains the unlock amount in Basis Point for Vesting/Lock.
	 * vestOrLockCliff - Contains the cliff of the vesting/lock for distribution.
	 * vestOrLockDuration - Contains the duration of the vesting/lock for distribution.
	 * depositRate - Contains the rate of the token w.r.t. the depositing asset.
	 * depositToken - Contains the deposit token address if the deposit type is Token.
	 * verificationType - Contains the method by which verification happens.
	 * saleEndDurationOrTS - Contains whether end of sale is by Duration or Timestamp.
	 * transferType - Contains the type of token transfer after a user buys to get the tokens.
	 */
	struct Tier {
		uint256 minAmount;
		uint256 maxAmount;
		uint256 remainingTokens;
		uint256 saleStartTS;
		uint256 saleEnd;
		uint256 unlockedBP;
		uint256 vestOrLockCliff;
		uint256 vestOrLockDuration;
		uint256 depositRate;
		IERC20 depositToken;
		DepositType depositType;
		VerificationType verificationType;
		SaleEndDurationOrTS saleEndDurationOrTS;
		TransferType transferType;
		SaleType saleType;
	}
}
