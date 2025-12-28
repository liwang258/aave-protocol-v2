// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

import {SafeMath} from '../../../dependencies/openzeppelin/contracts/SafeMath.sol';
import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '../../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {IAToken} from '../../../interfaces/IAToken.sol';
import {IStableDebtToken} from '../../../interfaces/IStableDebtToken.sol';
import {IVariableDebtToken} from '../../../interfaces/IVariableDebtToken.sol';
import {IReserveInterestRateStrategy} from '../../../interfaces/IReserveInterestRateStrategy.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {MathUtils} from '../math/MathUtils.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {Errors} from '../helpers/Errors.sol';
import {DataTypes} from '../types/DataTypes.sol';

/**
 * @title ReserveLogic library
 * @author Aave
 * @notice Implements the logic to update the reserves state
 */
library ReserveLogic {
  using SafeMath for uint256;
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using SafeERC20 for IERC20;

  /**
   * @dev Emitted when the state of a reserve is updated
   * @param asset The address of the underlying asset of the reserve
   * @param liquidityRate The new liquidity rate
   * @param stableBorrowRate The new stable borrow rate
   * @param variableBorrowRate The new variable borrow rate
   * @param liquidityIndex The new liquidity index
   * @param variableBorrowIndex The new variable borrow index
   **/
  event ReserveDataUpdated(
    address indexed asset,
    uint256 liquidityRate,
    uint256 stableBorrowRate,
    uint256 variableBorrowRate,
    uint256 liquidityIndex,
    uint256 variableBorrowIndex
  );

  using ReserveLogic for DataTypes.ReserveData;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  /**
   * @dev Returns the ongoing normalized income for the reserve
   * A value of 1e27 means there is no income. As time passes, the income is accrued
   * A value of 2*1e27 means for each unit of asset one unit of income has been accrued
   * @param reserve The reserve object
   * @return the normalized income. expressed in ray
   **/
  function getNormalizedIncome(
    DataTypes.ReserveData storage reserve
  ) internal view returns (uint256) {
    uint40 timestamp = reserve.lastUpdateTimestamp;

    //solium-disable-next-line
    if (timestamp == uint40(block.timestamp)) {
      //if the index was updated in the same block, no need to perform any calculation
      return reserve.liquidityIndex;
    }

    uint256 cumulated = MathUtils
      .calculateLinearInterest(reserve.currentLiquidityRate, timestamp)
      .rayMul(reserve.liquidityIndex);

    return cumulated;
  }

  /**
   * 标准化可变债务利率
   * @dev Returns the ongoing normalized variable debt for the reserve
   * 1 ray（10^27）表示无债务或债务未产生利息. 用于计算用户在不同时间点的实际债务余额
   * 2 ray 表示每单位债务已累积了 1 单位的利息（债务总额翻倍）
   * @param reserve 储备资产对象
   * @return 标准化可变债务，单位为 ray（1 ray = 10^27）
   **/
  function getNormalizedDebt(
    DataTypes.ReserveData storage reserve
  ) internal view returns (uint256) {
    //是储备资产状态（包括可变借款指数）上一次更新的时间戳
    uint40 timestamp = reserve.lastUpdateTimestamp;

    //solium-disable-next-line
    if (timestamp == uint40(block.timestamp)) {
      //当前区块时间与上次更新时间相同，说明指数未发生变化，直接返回现有可变借款指数
      return reserve.variableBorrowIndex;
    }
    //计算从 timestamp 到当前区块时间的累积利息因子
    //MathUtils.calculateCompoundedInterest 参数解释
    //   reserve.currentVariableBorrowRate:当前可变借款利率（以 ray 为单位）
    //   timestamp:上次更新时间戳
    //rayMul(reserve.variableBorrowIndex):将累积利息因子与上次存储的可变借款指数相乘，得到最新的标准化可变债务指数
    uint256 cumulated = MathUtils
      .calculateCompoundedInterest(reserve.currentVariableBorrowRate, timestamp)
      .rayMul(reserve.variableBorrowIndex);
    //最新的标准化可变债务指数
    return cumulated;
  }

  /**
   *  更新储备资产的状态指标
   *  1、更新浮动利率类型借款类型index
   *  2、更新固定借款利率类型index
   *  3、更新存款index
   *  4、将利息的增量部分按照协议规定的比例 向国库 增发/销毁 相应数量的atoken
   * @param reserve 储备量对象
   **/
  function updateState(DataTypes.ReserveData storage reserve) internal {
    //从储备资产的 variableDebtTokenAddress 地址（可变利率债务代币的地址）调用 scaledTotalSupply() 方法
    //scaledTotalSupply() 返回的是 按比例缩放的总可变债务（不是实际的代币数量，而是用于计算累积利息的内部数值）
    uint256 scaledVariableDebt = IVariableDebtToken(reserve.variableDebtTokenAddress)
      .scaledTotalSupply();
    // 记录前一个浮动借款索引
    uint256 previousVariableBorrowIndex = reserve.variableBorrowIndex;
    // 记录前一个存款索引
    uint256 previousLiquidityIndex = reserve.liquidityIndex;
    // 上一次更新时间
    uint40 lastUpdatedTimestamp = reserve.lastUpdateTimestamp;
    // 更新存款index和浮动利率index以及更新时间，返回新的存款index以及浮动利率借款index
    (uint256 newLiquidityIndex, uint256 newVariableBorrowIndex) = _updateIndexes(
      reserve,
      scaledVariableDebt,
      previousLiquidityIndex,
      previousVariableBorrowIndex,
      lastUpdatedTimestamp
    );
    //将利息按照一定的比例增发atoken到国库
    _mintToTreasury(
      reserve,
      scaledVariableDebt,
      previousVariableBorrowIndex,
      newLiquidityIndex,
      newVariableBorrowIndex,
      lastUpdatedTimestamp
    );
  }

  /**
   * @dev Accumulates a predefined amount of asset to the reserve as a fixed, instantaneous income. Used for example to accumulate
   * the flashloan fee to the reserve, and spread it between all the depositors
   * @param reserve The reserve object
   * @param totalLiquidity The total liquidity available in the reserve
   * @param amount The amount to accomulate
   **/
  function cumulateToLiquidityIndex(
    DataTypes.ReserveData storage reserve,
    uint256 totalLiquidity,
    uint256 amount
  ) internal {
    uint256 amountToLiquidityRatio = amount.wadToRay().rayDiv(totalLiquidity.wadToRay());

    uint256 result = amountToLiquidityRatio.add(WadRayMath.ray());

    result = result.rayMul(reserve.liquidityIndex);
    require(result <= type(uint128).max, Errors.RL_LIQUIDITY_INDEX_OVERFLOW);

    reserve.liquidityIndex = uint128(result);
  }

  /**
   * @dev Initializes a reserve
   * @param reserve The reserve object
   * @param aTokenAddress The address of the overlying atoken contract
   * @param interestRateStrategyAddress The address of the interest rate strategy contract
   **/
  function init(
    DataTypes.ReserveData storage reserve,
    address aTokenAddress,
    address stableDebtTokenAddress,
    address variableDebtTokenAddress,
    address interestRateStrategyAddress
  ) external {
    require(reserve.aTokenAddress == address(0), Errors.RL_RESERVE_ALREADY_INITIALIZED);

    reserve.liquidityIndex = uint128(WadRayMath.ray());
    reserve.variableBorrowIndex = uint128(WadRayMath.ray());
    reserve.aTokenAddress = aTokenAddress;
    reserve.stableDebtTokenAddress = stableDebtTokenAddress;
    reserve.variableDebtTokenAddress = variableDebtTokenAddress;
    reserve.interestRateStrategyAddress = interestRateStrategyAddress;
  }

  struct UpdateInterestRatesLocalVars {
    address stableDebtTokenAddress;
    uint256 availableLiquidity;
    uint256 totalStableDebt;
    uint256 newLiquidityRate;
    uint256 newStableRate;
    uint256 newVariableRate;
    uint256 avgStableRate;
    uint256 totalVariableDebt;
  }

  /**
   * 更新当前资产的稳定借款利率指标、可变借款利率指标和流动性利率指标
   * @param reserve 待更新的储备资产对象
   * @param liquidityAdded 通过(添加抵押或还款方式)添加到协议的流动性数量
   * @param liquidityTaken 通过（赎回或者借款方式）从协议中提取的流动性数量
   * */
  function updateInterestRates(
    DataTypes.ReserveData storage reserve,
    address reserveAddress,
    address aTokenAddress,
    uint256 liquidityAdded,
    uint256 liquidityTaken
  ) internal {
    UpdateInterestRatesLocalVars memory vars;
    //稳定债务代币地址
    vars.stableDebtTokenAddress = reserve.stableDebtTokenAddress;

    // 获取固定利率债务总量以及对应的平均利率
    (vars.totalStableDebt, vars.avgStableRate) = IStableDebtToken(vars.stableDebtTokenAddress)
      .getTotalSupplyAndAvgRate();

    //calculates the total variable debt locally using the scaled total supply instead
    //of totalSupply(), as it's noticeably cheaper. Also, the index has been
    //updated by the previous updateState() call
    //获取当前的总可变债务
    vars.totalVariableDebt = IVariableDebtToken(reserve.variableDebtTokenAddress)
      .scaledTotalSupply()
      .rayMul(reserve.variableBorrowIndex);
    //根据存款合约地址、流动性的增加和减少、总稳定债务、总可变债务、平均稳定利率和储备资产的储备因子计算新的利率
    //vars.newLiquidityRate:存款利率
    //vars.newStableRate:固定利率类型借款利率
    //vars.newVariableRate: 可变利率类型借款利率
    (
      vars.newLiquidityRate,
      vars.newStableRate,
      vars.newVariableRate
    ) = IReserveInterestRateStrategy(reserve.interestRateStrategyAddress).calculateInterestRates(
      reserveAddress,
      aTokenAddress,
      liquidityAdded,
      liquidityTaken,
      vars.totalStableDebt,
      vars.totalVariableDebt,
      vars.avgStableRate,
      reserve.configuration.getReserveFactor()
    );
    require(vars.newLiquidityRate <= type(uint128).max, Errors.RL_LIQUIDITY_RATE_OVERFLOW);
    require(vars.newStableRate <= type(uint128).max, Errors.RL_STABLE_BORROW_RATE_OVERFLOW);
    require(vars.newVariableRate <= type(uint128).max, Errors.RL_VARIABLE_BORROW_RATE_OVERFLOW);
    //更新资产信息的当前存款利率
    reserve.currentLiquidityRate = uint128(vars.newLiquidityRate);
    //更新当前固定利率类型借款利率
    reserve.currentStableBorrowRate = uint128(vars.newStableRate);
    //更新当前浮动利率类型借款利率
    reserve.currentVariableBorrowRate = uint128(vars.newVariableRate);

    emit ReserveDataUpdated(
      reserveAddress,
      vars.newLiquidityRate,
      vars.newStableRate,
      vars.newVariableRate,
      reserve.liquidityIndex,
      reserve.variableBorrowIndex
    );
  }

  struct MintToTreasuryLocalVars {
    uint256 currentStableDebt; //当前固定利率类型总债务(包含利息)
    uint256 principalStableDebt; //原始固定类型借款总债务(不包含利息)
    uint256 previousStableDebt; //上一次固定类型总债务(含利息)
    uint256 currentVariableDebt; //当前浮动利率类型总债务(含利息)
    uint256 previousVariableDebt; //上一次浮动利率类型总债务(含利息)
    uint256 avgStableRate; //固定利率类型借款平均利率
    uint256 cumulatedStableInterest; //固定利率类型利息变化量(可能大于0（用户借款或者借款产生利息），可能<0:用户还款或者用户资产被清算)
    uint256 totalDebtAccrued; //总欠款变化量
    uint256 amountToMint; //国库增发货需要销毁的atoken量
    uint256 reserveFactor; //国库利息预留比例
    uint40 stableSupplyUpdatedTimestamp; //固定利率债务总量更新时间戳
  }

  /**
   *
   * @dev 根据特定资产的储备系数，将部分已偿还的利息作为铸币税存入储备国库。
   * @param reserve 资产对象
   * @param scaledVariableDebt The current scaled total variable debt
   * @param previousVariableBorrowIndex The variable borrow index before the last accumulation of the interest
   * @param newLiquidityIndex 新存款index
   * @param newVariableBorrowIndex The variable borrow index after the last accumulation of the interest
   **/
  function _mintToTreasury(
    DataTypes.ReserveData storage reserve, //资产对象
    uint256 scaledVariableDebt, // 浮动利率借款额
    uint256 previousVariableBorrowIndex, //上一次浮动利率借款index
    uint256 newLiquidityIndex, //新的存款index
    uint256 newVariableBorrowIndex, // 新的浮动利率借款index
    uint40 timestamp //目标时间戳，传入的是上一次更新储备量的时间戳
  ) internal {
    MintToTreasuryLocalVars memory vars;
    //协议比例
    vars.reserveFactor = reserve.configuration.getReserveFactor();

    if (vars.reserveFactor == 0) {
      return;
    }

    // 获取原始借款金额
    (
      vars.principalStableDebt, //固定利率类型原始借款金额(不包含利息)
      vars.currentStableDebt, //固定利率类型借款总金额(包含利息)
      vars.avgStableRate, // 平均借款利率
      vars.stableSupplyUpdatedTimestamp //上一次更新时间
    ) = IStableDebtToken(reserve.stableDebtTokenAddress).getSupplyData();

    //calculate the last principal variable debt
    //之前的浮动利率类型总借款金额
    vars.previousVariableDebt = scaledVariableDebt.rayMul(previousVariableBorrowIndex);

    //calculate the new total supply after accumulation of the index
    //当前的浮动利率类型总借款金额
    vars.currentVariableDebt = scaledVariableDebt.rayMul(newVariableBorrowIndex);

    //calculate the stable debt until the last timestamp update
    //计算固定利率累计量到当前区块时间
    vars.cumulatedStableInterest = MathUtils.calculateCompoundedInterest(
      vars.avgStableRate,
      vars.stableSupplyUpdatedTimestamp,
      timestamp
    );
    //上一次的固定利率总债务
    vars.previousStableDebt = vars.principalStableDebt.rayMul(vars.cumulatedStableInterest);

    //debt accrued is the sum of the current debt minus the sum of the debt at the last update
    //债务变化量=最新浮动利率总债务+最新的固定利率总债务-上一次计算时的浮动利率总债务-上一次计算时的固定利率总债务
    //这个债务变化量可能>0(用户借款增加或者借款利息增长)也可能<0(用户还款或者用户债务被清算)也可能=0
    vars.totalDebtAccrued = vars
      .currentVariableDebt
      .add(vars.currentStableDebt)
      .sub(vars.previousVariableDebt)
      .sub(vars.previousStableDebt);
    // 债务利息中的vars.reserveFactor%作为atoken的增发量
    vars.amountToMint = vars.totalDebtAccrued.percentMul(vars.reserveFactor);

    if (vars.amountToMint != 0) {
      //对于amountToMint>0的情况，增发atoken给到国库，用于社区治理,表面上看用户的atoken占比下降了，
      //但是因为总利息增加，实际用户能分到的利息增加了
      //对于amountToMint<0的情况， 会销毁国库中一定数量的atoken数量，相当于atoken数量减少，用户

      IAToken(reserve.aTokenAddress).mintToTreasury(vars.amountToMint, newLiquidityIndex);
    }
  }

  /**
   * @dev 更新存款index，浮动利率借款index
   * @param reserve 待更新的资产信息
   * @param scaledVariableDebt 归一化后的浮动利率借款
   * @param liquidityIndex 上一次存款index
   * @param variableBorrowIndex 上一次浮动利率借款index
   * @return 更新后的存款index，更新后的浮动利率借款index
   **/
  function _updateIndexes(
    DataTypes.ReserveData storage reserve,
    uint256 scaledVariableDebt,
    uint256 liquidityIndex,
    uint256 variableBorrowIndex,
    uint40 timestamp
  ) internal returns (uint256, uint256) {
    // 当前存款利率
    uint256 currentLiquidityRate = reserve.currentLiquidityRate;
    // 当前存款index  用户的实时余额=atoken数量*liquidityIndex/存款时候的liquidityIndex
    uint256 newLiquidityIndex = liquidityIndex;
    // 浮动借款索引  浮动欠款金额=借款金额*variableBorrowIndex/借款时候的variableBorrowIndex
    uint256 newVariableBorrowIndex = variableBorrowIndex;

    //only cumulating if there is any income being produced
    if (currentLiquidityRate > 0) {
      // 计算存款利息线性累积因子=当前存款利率*(1+(当前时间戳-上一次利率更新时间)/1年(秒数))
      uint256 cumulatedLiquidityInterest = MathUtils.calculateLinearInterest(
        currentLiquidityRate,
        timestamp
      );
      //新的存款index=款利息线性累积因子*上一次存款index
      newLiquidityIndex = cumulatedLiquidityInterest.rayMul(liquidityIndex);
      require(newLiquidityIndex <= type(uint128).max, Errors.RL_LIQUIDITY_INDEX_OVERFLOW);
      //更新存款index
      reserve.liquidityIndex = uint128(newLiquidityIndex);

      //as the liquidity rate might come only from stable rate loans, we need to ensure
      //that there is actual variable debt before accumulating
      if (scaledVariableDebt != 0) {
        //有浮动利率借款，则计算浮动利息累积因子
        uint256 cumulatedVariableBorrowInterest = MathUtils.calculateCompoundedInterest(
          reserve.currentVariableBorrowRate,
          timestamp
        );
        //浮动借款index=浮动借款利息累积因子*上一次浮动利率借款index
        newVariableBorrowIndex = cumulatedVariableBorrowInterest.rayMul(variableBorrowIndex);
        require(
          newVariableBorrowIndex <= type(uint128).max,
          Errors.RL_VARIABLE_BORROW_INDEX_OVERFLOW
        );
        //更新浮动借款index
        reserve.variableBorrowIndex = uint128(newVariableBorrowIndex);
      }
    }

    //solium-disable-next-line
    reserve.lastUpdateTimestamp = uint40(block.timestamp);
    return (newLiquidityIndex, newVariableBorrowIndex);
  }
}
