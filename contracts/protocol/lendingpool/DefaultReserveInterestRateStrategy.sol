// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

import {SafeMath} from '../../dependencies/openzeppelin/contracts/SafeMath.sol';
import {IReserveInterestRateStrategy} from '../../interfaces/IReserveInterestRateStrategy.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
import {PercentageMath} from '../libraries/math/PercentageMath.sol';
import {ILendingPoolAddressesProvider} from '../../interfaces/ILendingPoolAddressesProvider.sol';
import {ILendingRateOracle} from '../../interfaces/ILendingRateOracle.sol';
import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';

/**
 * @title DefaultReserveInterestRateStrategy contract
 * @notice Implements the calculation of the interest rates depending on the reserve state
 * @dev The model of interest rate is based on 2 slopes, one before the `OPTIMAL_UTILIZATION_RATE`
 * point of utilization and another from that one to 100%
 * - An instance of this same contract, can't be used across different Aave markets, due to the caching
 *   of the LendingPoolAddressesProvider
 * @author Aave
 **/
contract DefaultReserveInterestRateStrategy is IReserveInterestRateStrategy {
  using WadRayMath for uint256;
  using SafeMath for uint256;
  using PercentageMath for uint256;

  /**
   * @dev this constant represents the utilization rate at which the pool aims to obtain most competitive borrow rates.
   * Expressed in ray
   **/
  uint256 public immutable OPTIMAL_UTILIZATION_RATE;

  /**
   * @dev This constant represents the excess utilization rate above the optimal. It's always equal to
   * 1-optimal utilization rate. Added as a constant here for gas optimizations.
   * Expressed in ray
   **/

  uint256 public immutable EXCESS_UTILIZATION_RATE;

  ILendingPoolAddressesProvider public immutable addressesProvider;

  // Base variable borrow rate when Utilization rate = 0. Expressed in ray
  uint256 internal immutable _baseVariableBorrowRate;

  // Slope of the variable interest curve when utilization rate > 0 and <= OPTIMAL_UTILIZATION_RATE. Expressed in ray
  uint256 internal immutable _variableRateSlope1;

  // Slope of the variable interest curve when utilization rate > OPTIMAL_UTILIZATION_RATE. Expressed in ray
  uint256 internal immutable _variableRateSlope2;

  // Slope of the stable interest curve when utilization rate > 0 and <= OPTIMAL_UTILIZATION_RATE. Expressed in ray
  uint256 internal immutable _stableRateSlope1;

  // Slope of the stable interest curve when utilization rate > OPTIMAL_UTILIZATION_RATE. Expressed in ray
  uint256 internal immutable _stableRateSlope2;

  constructor(
    ILendingPoolAddressesProvider provider,
    uint256 optimalUtilizationRate,
    uint256 baseVariableBorrowRate,
    uint256 variableRateSlope1,
    uint256 variableRateSlope2,
    uint256 stableRateSlope1,
    uint256 stableRateSlope2
  ) public {
    OPTIMAL_UTILIZATION_RATE = optimalUtilizationRate;
    EXCESS_UTILIZATION_RATE = WadRayMath.ray().sub(optimalUtilizationRate);
    addressesProvider = provider;
    _baseVariableBorrowRate = baseVariableBorrowRate;
    _variableRateSlope1 = variableRateSlope1;
    _variableRateSlope2 = variableRateSlope2;
    _stableRateSlope1 = stableRateSlope1;
    _stableRateSlope2 = stableRateSlope2;
  }

  function variableRateSlope1() external view returns (uint256) {
    return _variableRateSlope1;
  }

  function variableRateSlope2() external view returns (uint256) {
    return _variableRateSlope2;
  }

  function stableRateSlope1() external view returns (uint256) {
    return _stableRateSlope1;
  }

  function stableRateSlope2() external view returns (uint256) {
    return _stableRateSlope2;
  }

  function baseVariableBorrowRate() external view override returns (uint256) {
    return _baseVariableBorrowRate;
  }

  function getMaxVariableBorrowRate() external view override returns (uint256) {
    return _baseVariableBorrowRate.add(_variableRateSlope1).add(_variableRateSlope2);
  }

  /**
   * @dev Calculates the interest rates depending on the reserve's state and configurations
   * @param reserve The address of the reserve
   * @param liquidityAdded The liquidity added during the operation
   * @param liquidityTaken The liquidity taken during the operation
   * @param totalStableDebt The total borrowed from the reserve a stable rate
   * @param totalVariableDebt The total borrowed from the reserve at a variable rate
   * @param averageStableBorrowRate The weighted average of all the stable rate loans
   * @param reserveFactor The reserve portion of the interest that goes to the treasury of the market
   * @return The liquidity rate, the stable borrow rate and the variable borrow rate
   **/
  function calculateInterestRates(
    address reserve, // 资产信息
    address aToken, //aToken 合约地址
    uint256 liquidityAdded, // 增加的流动性
    uint256 liquidityTaken, //提取的流动性
    uint256 totalStableDebt, //总稳定债务
    uint256 totalVariableDebt, // 总浮动利率债务
    uint256 averageStableBorrowRate, // 平均稳定借款利率
    uint256 reserveFactor // 储备因子
  ) external view override returns (uint256, uint256, uint256) {
    uint256 availableLiquidity = IERC20(reserve).balanceOf(aToken);
    //avoid stack too deep
    // 总（存款）可用流动性 = 当前可用流动性 + 新增流动性 - 提取流动性
    availableLiquidity = availableLiquidity.add(liquidityAdded).sub(liquidityTaken);

    return
      calculateInterestRates(
        reserve,
        availableLiquidity,
        totalStableDebt,
        totalVariableDebt,
        averageStableBorrowRate,
        reserveFactor
      );
  }

  struct CalcInterestRatesLocalVars {
    uint256 totalDebt; //总借款量
    uint256 currentVariableBorrowRate; // 当前浮动利率类型借款利率
    uint256 currentStableBorrowRate; //当前固定利率类型借款利率
    uint256 currentLiquidityRate; // 当前的存款利率=平均借款利率*资金利用率*(1-协议费率)
    uint256 utilizationRate; // 当前资金使用率(=总借款量/（借款量+剩余可借款资金量）)
  }

  /**
   * 计算利率
   * @dev Calculates the interest rates depending on the reserve's state and configurations.
   * NOTE This function is kept for compatibility with the previous DefaultInterestRateStrategy interface.
   * New protocol implementation uses the new calculateInterestRates() interface
   * @param reserve 资产地址信息
   * @param availableLiquidity 当前剩余的流动性(可借出数量)
   * @param totalStableDebt 固定利率类型总借款量
   * @param totalVariableDebt 浮动利率类型总借款量
   * @param averageStableBorrowRate 所有固定利息债务的平均利率
   * @param reserveFactor The reserve portion of the interest that goes to the treasury of the market
   * @return The liquidity rate, the stable borrow rate and the variable borrow rate
   **/
  function calculateInterestRates(
    address reserve,
    uint256 availableLiquidity,
    uint256 totalStableDebt,
    uint256 totalVariableDebt,
    uint256 averageStableBorrowRate,
    uint256 reserveFactor
  ) public view override returns (uint256, uint256, uint256) {
    CalcInterestRatesLocalVars memory vars;
    //总债务 = 总稳定债务 + 总可变债务
    vars.totalDebt = totalStableDebt.add(totalVariableDebt);
    vars.currentVariableBorrowRate = 0;
    vars.currentStableBorrowRate = 0;
    vars.currentLiquidityRate = 0;
    //计算利用率 = 总债务 / （可用流动性 + 总债务）
    vars.utilizationRate = vars.totalDebt == 0
      ? 0
      : vars.totalDebt.rayDiv(availableLiquidity.add(vars.totalDebt));
    // 当前的稳定借款利率 = 从借贷利率预言机获取的市场借款利率 ---考虑预言机操纵风险
    vars.currentStableBorrowRate = ILendingRateOracle(addressesProvider.getLendingRateOracle())
      .getMarketBorrowRate(reserve);
    // 资金利用率> 最优利用率
    if (vars.utilizationRate > OPTIMAL_UTILIZATION_RATE) {
      // 计算超额利用率比例 = （资金利用率 - 最优利用率） /（1-最优利用率)
      // EXCESS_UTILIZATION_RATE=1-最优利用率
      uint256 excessUtilizationRateRatio = vars
        .utilizationRate
        .sub(OPTIMAL_UTILIZATION_RATE)
        .rayDiv(EXCESS_UTILIZATION_RATE);
      // 当前借款利率=基础固定借款利率+固定借款利率斜率1+固定借款利率斜率2 * 超额利用率比例
      vars.currentStableBorrowRate = vars.currentStableBorrowRate.add(_stableRateSlope1).add(
        _stableRateSlope2.rayMul(excessUtilizationRateRatio)
      );
      // 当前浮动借款利率=基础浮动借款利率+浮动借款利率1斜率+浮动借款利率斜率2 * 超额利用率比例
      vars.currentVariableBorrowRate = _baseVariableBorrowRate.add(_variableRateSlope1).add(
        _variableRateSlope2.rayMul(excessUtilizationRateRatio)
      );
    } else {
      // 资金利用率 <= 最优利用率
      // 当前固定借款利率= 当前固定借款利率 + 固定借款利率斜率1 * （资金利用率 / 最优利用率）
      vars.currentStableBorrowRate = vars.currentStableBorrowRate.add(
        _stableRateSlope1.rayMul(vars.utilizationRate.rayDiv(OPTIMAL_UTILIZATION_RATE))
      );
      // 当前浮动借款利率=基础浮动借款利率+当前资金利用率*浮动借款利率斜率1/最优利用率
      vars.currentVariableBorrowRate = _baseVariableBorrowRate.add(
        vars.utilizationRate.rayMul(_variableRateSlope1).rayDiv(OPTIMAL_UTILIZATION_RATE)
      );
    }
    //_getOverallBorrowRate 返回平均借款利率
    //currentLiquidityRate=平均借款利率*资金使用率
    //记录存款利率=平均借款利率*资金使用率*(1-协议比例)
    vars.currentLiquidityRate = _getOverallBorrowRate(
      totalStableDebt,
      totalVariableDebt,
      vars.currentVariableBorrowRate,
      averageStableBorrowRate
    ).rayMul(vars.utilizationRate).percentMul(PercentageMath.PERCENTAGE_FACTOR.sub(reserveFactor));

    return (
      vars.currentLiquidityRate,
      vars.currentStableBorrowRate,
      vars.currentVariableBorrowRate
    );
  }

  /**
   * 这里计算的是平均借款利率 (包含浮动借款利息和固定借款利息)
   * @dev Calculates the overall borrow rate as the weighted average between the total variable debt and total stable debt
   * @param totalStableDebt 总固定利率借款量
   * @param totalVariableDebt 总浮动利率借款量
   * @param currentVariableBorrowRate 当前浮动借款利率
   * @param currentAverageStableBorrowRate 当前固定利率借款的平均利率
   * @return 平均借款利率
   **/
  function _getOverallBorrowRate(
    uint256 totalStableDebt, // 总固定利率债务
    uint256 totalVariableDebt, // 总浮动利率债务
    uint256 currentVariableBorrowRate, //当前浮动借款利率
    uint256 currentAverageStableBorrowRate //当当前所有固定利率债务中的平均借款利率
  ) internal pure returns (uint256) {
    uint256 totalDebt = totalStableDebt.add(totalVariableDebt);
    // 没有借款
    if (totalDebt == 0) return 0;
    // totalVariableDebt.wadToRay() =totalVariableDebt*1e9
    // 得到总浮动借款的利息 *1e9
    uint256 weightedVariableRate = totalVariableDebt.wadToRay().rayMul(currentVariableBorrowRate);
    // 得到总固定借款的总利息 *1e9
    uint256 weightedStableRate = totalStableDebt.wadToRay().rayMul(currentAverageStableBorrowRate);
    // 得到总借款利率=(浮动借款总利息+固定借款利率总利息)/总债务
    uint256 overallBorrowRate = weightedVariableRate.add(weightedStableRate).rayDiv(
      totalDebt.wadToRay()
    );

    return overallBorrowRate;
  }
}
