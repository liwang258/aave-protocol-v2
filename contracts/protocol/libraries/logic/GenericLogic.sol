// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeMath} from '../../../dependencies/openzeppelin/contracts/SafeMath.sol';
import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {UserConfiguration} from '../configuration/UserConfiguration.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {IPriceOracleGetter} from '../../../interfaces/IPriceOracleGetter.sol';
import {DataTypes} from '../types/DataTypes.sol';

/**
 * @title GenericLogic library
 * @author Aave
 * @title Implements protocol-level logic to calculate and validate the state of a user
 */
library GenericLogic {
  using ReserveLogic for DataTypes.ReserveData;
  using SafeMath for uint256;
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using UserConfiguration for DataTypes.UserConfigurationMap;

  uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1 ether;

  struct balanceDecreaseAllowedLocalVars {
    uint256 decimals;
    uint256 liquidationThreshold;
    uint256 totalCollateralInETH;
    uint256 totalDebtInETH;
    uint256 avgLiquidationThreshold;
    uint256 amountToDecreaseInETH;
    uint256 collateralBalanceAfterDecrease;
    uint256 liquidationThresholdAfterDecrease;
    uint256 healthFactorAfterDecrease;
    bool reserveUsageAsCollateralEnabled;
  }

  /**
   * @dev Checks if a specific balance decrease is allowed
   * (i.e. doesn't bring the user borrow position health factor under HEALTH_FACTOR_LIQUIDATION_THRESHOLD)
   * @param asset The address of the underlying asset of the reserve
   * @param user The address of the user
   * @param amount The amount to decrease
   * @param reservesData The data of all the reserves
   * @param userConfig The user configuration
   * @param reserves The list of all the active reserves
   * @param oracle The address of the oracle contract
   * @return true if the decrease of the balance is allowed
   **/
  function balanceDecreaseAllowed(
    address asset,
    address user,
    uint256 amount,
    mapping(address => DataTypes.ReserveData) storage reservesData,
    DataTypes.UserConfigurationMap calldata userConfig,
    mapping(uint256 => address) storage reserves,
    uint256 reservesCount,
    address oracle
  ) external view returns (bool) {
    if (!userConfig.isBorrowingAny() || !userConfig.isUsingAsCollateral(reservesData[asset].id)) {
      return true;
    }

    balanceDecreaseAllowedLocalVars memory vars;

    (, vars.liquidationThreshold, , vars.decimals, ) = reservesData[asset]
      .configuration
      .getParams();

    if (vars.liquidationThreshold == 0) {
      return true;
    }

    (
      vars.totalCollateralInETH,
      vars.totalDebtInETH,
      ,
      vars.avgLiquidationThreshold,

    ) = calculateUserAccountData(user, reservesData, userConfig, reserves, reservesCount, oracle);

    if (vars.totalDebtInETH == 0) {
      return true;
    }

    vars.amountToDecreaseInETH = IPriceOracleGetter(oracle).getAssetPrice(asset).mul(amount).div(
      10 ** vars.decimals
    );

    vars.collateralBalanceAfterDecrease = vars.totalCollateralInETH.sub(vars.amountToDecreaseInETH);

    //if there is a borrow, there can't be 0 collateral
    if (vars.collateralBalanceAfterDecrease == 0) {
      return false;
    }

    vars.liquidationThresholdAfterDecrease = vars
      .totalCollateralInETH
      .mul(vars.avgLiquidationThreshold)
      .sub(vars.amountToDecreaseInETH.mul(vars.liquidationThreshold))
      .div(vars.collateralBalanceAfterDecrease);

    uint256 healthFactorAfterDecrease = calculateHealthFactorFromBalances(
      vars.collateralBalanceAfterDecrease,
      vars.totalDebtInETH,
      vars.liquidationThresholdAfterDecrease
    );

    return healthFactorAfterDecrease >= GenericLogic.HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
  }

  struct CalculateUserAccountDataVars {
    uint256 reserveUnitPrice;
    uint256 tokenUnit; //token单位
    uint256 compoundedLiquidityBalance; //单个代币的存款金额(只是在循环中临时存储，循环中会覆盖)
    uint256 compoundedBorrowBalance; //单个代币欠款金额(只是在循环中临时存储，循环中会覆盖)
    uint256 decimals; //小数位数
    uint256 ltv; //获取抵押率 即:抵押的获取能按照什么比例借出代币
    uint256 liquidationThreshold; //清算阈值(0,1)
    uint256 i;
    uint256 healthFactor; //健康因子
    uint256 totalCollateralInETH; //总抵押金额(按照ETH计价)
    uint256 totalDebtInETH; //总欠款金额(按照ETH计价)
    uint256 avgLtv; //计算加权平均LTV=Sum(资产价值(i)*ltv(i))/Sum(总抵押价值), 表示用户所有抵押资产的 平均最大可借比例
    uint256 avgLiquidationThreshold; //加权平均清算阈值 表示当用户的 总借款价值/总抵押品价值 达到这个比例时，就会触发清算
    uint256 reservesLength;
    bool healthFactorBelowThreshold;
    address currentReserveAddress;
    bool usageAsCollateralEnabled;
    bool userUsesReserveAsCollateral;
  }

  /**
   * 获取用户账户信息 返回：
   * 1、总抵押品价值(ETH计价)
   * 2、总欠款价值(ETH计价)
   * 3、平均ltv
   * 4、平均清算阈值
   * 5、健康因子
   *
   * @param user 用户地址
   * @param reservesData 资产储备信息
   * @param userConfig 用户配置
   * @param reserves aave支持的资产列表
   * @param oracle 预言机地址
   * @return 总抵押品价值(ETH计价)，总欠款价值(ETH计价)，平均ltv，平均清算阈值，健康因子
   **/
  function calculateUserAccountData(
    address user,
    //存储资产地址到 资产储备信息的映射  key:资产地址 value:资产储备信息
    mapping(address => DataTypes.ReserveData) storage reservesData,
    DataTypes.UserConfigurationMap memory userConfig,
    //存储资产索引到资产地址的映射 key:资产索引 value:资产地址
    mapping(uint256 => address) storage reserves,
    uint256 reservesCount,
    address oracle
  ) internal view returns (uint256, uint256, uint256, uint256, uint256) {
    CalculateUserAccountDataVars memory vars;

    if (userConfig.isEmpty()) {
      return (0, 0, 0, 0, uint256(-1));
    }
    for (vars.i = 0; vars.i < reservesCount; vars.i++) {
      //不允许作为抵押的资产则跳过
      if (!userConfig.isUsingAsCollateralOrBorrowing(vars.i)) {
        continue;
      }
      //资产地址
      vars.currentReserveAddress = reserves[vars.i];
      //资产储备信息
      DataTypes.ReserveData storage currentReserve = reservesData[vars.currentReserveAddress];
      //配置的LTV，清算阈值,小数位数
      (vars.ltv, vars.liquidationThreshold, , vars.decimals, ) = currentReserve
        .configuration
        .getParams();

      vars.tokenUnit = 10 ** vars.decimals;
      vars.reserveUnitPrice = IPriceOracleGetter(oracle).getAssetPrice(vars.currentReserveAddress);

      if (vars.liquidationThreshold != 0 && userConfig.isUsingAsCollateral(vars.i)) {
        //用户存款余额
        vars.compoundedLiquidityBalance = IERC20(currentReserve.aTokenAddress).balanceOf(user);
        //用户存款换算成ETH
        uint256 liquidityBalanceETH = vars
          .reserveUnitPrice
          .mul(vars.compoundedLiquidityBalance)
          .div(vars.tokenUnit);
        // 用户的总可抵押品价值按照ETH计价
        vars.totalCollateralInETH = vars.totalCollateralInETH.add(liquidityBalanceETH);
        // 得到可借价值=已经计算的可借价值+用户存储的ETH价值*LTV
        // 注意这个avgLtv并不是一个比例，而已经是实实在在的换算之后的可借金额数量
        vars.avgLtv = vars.avgLtv.add(liquidityBalanceETH.mul(vars.ltv));
        // 得到总清算价值
        vars.avgLiquidationThreshold = vars.avgLiquidationThreshold.add(
          liquidityBalanceETH.mul(vars.liquidationThreshold)
        );
      }
      //有借款的情况下
      if (userConfig.isBorrowing(vars.i)) {
        //对应资产的固定利率欠款金额
        vars.compoundedBorrowBalance = IERC20(currentReserve.stableDebtTokenAddress).balanceOf(
          user
        );
        //对应资产的欠款金额=固定利率欠款金额+浮动利率欠款金额
        vars.compoundedBorrowBalance = vars.compoundedBorrowBalance.add(
          IERC20(currentReserve.variableDebtTokenAddress).balanceOf(user)
        );
        //计算总欠款金额(换算成ETH计价)=已计算的欠款金额(ETH计价)+汇率(来自预言机)*欠款数量/token单位
        vars.totalDebtInETH = vars.totalDebtInETH.add(
          vars.reserveUnitPrice.mul(vars.compoundedBorrowBalance).div(vars.tokenUnit)
        );
      }
    }
    //计算加权平均LTV=Sum(资产价值(i)*ltv(i))/Sum(总抵押价值), 表示用户所有抵押资产的 平均最大可借比例
    vars.avgLtv = vars.totalCollateralInETH > 0 ? vars.avgLtv.div(vars.totalCollateralInETH) : 0;
    //计算加权平均清算阈值=Sum(资产价值(i)*清算阈值(i))/Sum(总抵押价值) ,表示用户所有抵押资产的 平均清算触发比例
    vars.avgLiquidationThreshold = vars.totalCollateralInETH > 0
      ? vars.avgLiquidationThreshold.div(vars.totalCollateralInETH)
      : 0;
    //计算健康因子 =总抵押价值*清算阈值/总债务
    vars.healthFactor = calculateHealthFactorFromBalances(
      vars.totalCollateralInETH,
      vars.totalDebtInETH,
      vars.avgLiquidationThreshold
    );
    return (
      vars.totalCollateralInETH,
      vars.totalDebtInETH,
      vars.avgLtv,
      vars.avgLiquidationThreshold,
      vars.healthFactor
    );
  }

  /**
   * 计算健康因子 =总抵押价值*清算阈值/总债务
   * @dev Calculates the health factor from the corresponding balances
   * @param totalCollateralInETH The total collateral in ETH
   * @param totalDebtInETH The total debt in ETH
   * @param liquidationThreshold The avg liquidation threshold
   * @return The health factor calculated from the balances provided
   **/
  function calculateHealthFactorFromBalances(
    uint256 totalCollateralInETH,
    uint256 totalDebtInETH,
    uint256 liquidationThreshold
  ) internal pure returns (uint256) {
    if (totalDebtInETH == 0) return uint256(-1);

    return (totalCollateralInETH.percentMul(liquidationThreshold)).wadDiv(totalDebtInETH);
  }

  /**
   * @dev Calculates the equivalent amount in ETH that an user can borrow, depending on the available collateral and the
   * average Loan To Value
   * @param totalCollateralInETH The total collateral in ETH
   * @param totalDebtInETH The total borrow balance
   * @param ltv The average loan to value
   * @return the amount available to borrow in ETH for the user
   **/

  function calculateAvailableBorrowsETH(
    uint256 totalCollateralInETH, //总抵押金额
    uint256 totalDebtInETH, //已借金额
    uint256 ltv //ltv
  ) internal pure returns (uint256) {
    //计算总可借价值
    uint256 availableBorrowsETH = totalCollateralInETH.percentMul(ltv);

    if (availableBorrowsETH < totalDebtInETH) {
      //这种场景说明已经是资不抵债，需要清算了，不允许在继续借
      return 0;
    }

    availableBorrowsETH = availableBorrowsETH.sub(totalDebtInETH);
    return availableBorrowsETH;
  }
}
