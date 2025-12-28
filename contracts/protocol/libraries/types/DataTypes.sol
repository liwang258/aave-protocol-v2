// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

library DataTypes {
  // refer to the whitepaper, section 1.1 basic concepts for a formal description of these properties.
  struct ReserveData {
    //stores the reserve configuration
    //储备配置信息
    ReserveConfigurationMap configuration;
    //the liquidity index. Expressed in ray
    //存款index
    uint128 liquidityIndex;
    /**
     * 累计利息指数，用于计算可变利率债务的增长   用户最终还款额=归一化后的接口额度 * (当前可变借款指数 / 借款时的可变借款指数)
     * 为什么要用除法？
     * 这个设计用户任意时刻的还款金额=scaledBalanceAmount * (当前可变借款指数)
     * 而: scaledBalanceAmount = 用户借款时的实际借款金额 / 借款时的可变借款指数
     * 代入上式: 用户还款金额 = (用户借款时的实际借款金额 / 借款时的可变借款指数) * 当前可变借款指数
     * 所以最终用户还款金额 = 用户借款时的实际借款金额 * (当前可变借款指数 / 借款时的可变借款指数)
     */
    uint128 variableBorrowIndex; //浮动借款指数
    //the current supply rate. Expressed in ray
    uint128 currentLiquidityRate; //当前存款利率
    //the current variable borrow rate. Expressed in ray
    uint128 currentVariableBorrowRate; //浮动利率类型借款利率
    //the current stable borrow rate. Expressed in ray
    uint128 currentStableBorrowRate; // 固定利率类型借款利率
    uint40 lastUpdateTimestamp;
    //tokens addresses
    address aTokenAddress; // 存款合约地址
    address stableDebtTokenAddress; // 固定利率贷款合约地址
    address variableDebtTokenAddress; // 浮动利率贷款合约地址
    //address of the interest rate strategy
    address interestRateStrategyAddress; //利息策略合约地址
    //the id of the reserve. Represents the position in the list of the active reserves
    uint8 id;
  }

  struct ReserveConfigurationMap {
    //bit 0-15: LTV
    //bit 16-31: Liq. threshold
    //bit 32-47: Liq. bonus
    //bit 48-55: Decimals
    //bit 56: Reserve is active
    //bit 57: reserve is frozen
    //bit 58: borrowing is enabled
    //bit 59: stable rate borrowing enabled
    //bit 60-63: reserved
    //bit 64-79: reserve factor
    uint256 data;
  }

  struct UserConfigurationMap {
    uint256 data;
  }

  enum InterestRateMode {
    NONE,
    STABLE,
    VARIABLE
  }
}
