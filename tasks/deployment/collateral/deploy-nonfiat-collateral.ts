import { getChainId } from '../../../common/blockchain-utils'
import { task } from 'hardhat/config'
import { ContractFactory } from 'ethers'
import { NonFiatCollateral } from '../../../typechain'

task('deploy-nonfiat-collateral', 'Deploys a non-fiat Collateral')
  .addParam('priceTimeout', 'The amount of time before a price decays to 0')
  .addParam('referenceUnitFeed', 'Reference Price Feed address')
  .addParam('targetUnitFeed', 'Target Unit Price Feed address')
  .addParam('combinedOracleError', 'The combined % error from both oracle sources')
  .addParam('tokenAddress', 'ERC20 token address')
  .addParam('maxTradeVolume', 'Max Trade Volume (in UoA)')
  .addParam('oracleTimeout', 'Max oracle timeout for the reference unit feed')
  .addParam('targetUnitOracleTimeout', 'Max oracle timeout for the target unit feed')
  .addParam('targetName', 'Target Name')
  .addParam('defaultThreshold', 'Default Threshold')
  .addParam('delayUntilDefault', 'Delay until default')
  .setAction(async (params, hre) => {
    const [deployer] = await hre.ethers.getSigners()

    const chainId = await getChainId(hre)

    const NonFiatCollateralFactory: ContractFactory = await hre.ethers.getContractFactory(
      'NonFiatCollateral'
    )

    const collateral = <NonFiatCollateral>await NonFiatCollateralFactory.connect(deployer).deploy(
      {
        priceTimeout: params.priceTimeout,
        chainlinkFeed: params.referenceUnitFeed,
        oracleError: params.combinedOracleError,
        erc20: params.tokenAddress,
        maxTradeVolume: params.maxTradeVolume,
        oracleTimeout: params.oracleTimeout,
        targetName: params.targetName,
        defaultThreshold: params.defaultThreshold,
        delayUntilDefault: params.delayUntilDefault,
      },
      params.targetUnitFeed,
      params.targetUnitOracleTimeout
    )
    await collateral.deployed()

    if (!params.noOutput) {
      console.log(
        `Deployed Non-Fiat Collateral to ${hre.network.name} (${chainId}): ${collateral.address}`
      )
    }

    return { collateral: collateral.address }
  })
