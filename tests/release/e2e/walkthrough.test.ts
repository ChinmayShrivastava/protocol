import { EthereumTestnetProvider, randomAddress, SignerWithAddress } from '@crestproject/crestproject';
import {
  adapterBlacklistArgs,
  adapterWhitelistArgs,
  assetBlacklistArgs,
  ComptrollerLib,
  entranceRateFeeConfigArgs,
  feeManagerConfigArgs,
  investorWhitelistArgs,
  IUniswapV2Router2,
  managementFeeConfigArgs,
  maxConcentrationArgs,
  performanceFeeConfigArgs,
  policyManagerConfigArgs,
  StandardToken,
  VaultLib,
} from '@melonproject/protocol';
import {
  addTrackedAssets,
  buyShares,
  createNewFund,
  defaultForkDeployment,
  ForkReleaseDeploymentConfig,
  KyberNetworkProxy,
  kyberTakeOrder,
  redeemShares,
  uniswapV2TakeOrder,
} from '@melonproject/testutils';
import { utils } from 'ethers';

export type Snapshot = ReturnType<typeof snapshot> extends Promise<infer T> ? T : never;

// [x] Create fund with all policies (use backlists instead of whitelists) and all three fees
// [x] deploy an investor whitelist
// [x] Invest in fund as an investor (not manager)
// [x] Trade on Kyber
// [x] Trade on Uniswap
// [ ] Lend/Redeem Chai (TODO: fix mainnet fork deployment)
// [x] Seed the fund with 19 assets (both derivatives and assets; transfer tokens and use addTrackedAssets())
// [x] Trade for 20th asset on Kyber (should be most expensive)
// [x] Trade on Uniswap again
// [ ] Lend/Redeem Chai again (TODO: fix mainnet fork deployment)
// [x] (Warp time) and send more of any asset to the fund's vault (will increase GAV)
// [x] Redeem some shares
// [x] (Warp time) and send more of any asset to the fund's vault (will increase GAV)
// [x] change investor whitelist
// [x] Buy more shares
// [x] Redeem all remaining shares

async function snapshot(provider: EthereumTestnetProvider) {
  const { accounts, deployment, config } = await defaultForkDeployment(provider);

  const denominationAsset = config.tokens.weth;
  const manager = accounts[0];

  // fees
  const managementFeeSettings = managementFeeConfigArgs(utils.parseEther('0.01'));
  const performanceFeeSettings = performanceFeeConfigArgs({
    rate: utils.parseEther('0.1'),
    period: 365 * 24 * 60 * 60,
  });
  const entranceRateFeeSettings = entranceRateFeeConfigArgs(utils.parseEther('0.05'));

  const feeManagerConfig = feeManagerConfigArgs({
    fees: [deployment.managementFee, deployment.performanceFee, deployment.entranceRateBurnFee],
    settings: [managementFeeSettings, performanceFeeSettings, entranceRateFeeSettings],
  });

  // policies
  const maxConcentrationSettings = maxConcentrationArgs(utils.parseEther('1'));
  const adapterBlacklistSettings = adapterBlacklistArgs([deployment.compoundAdapter]);
  const adapterWhitelistSettings = adapterWhitelistArgs([
    deployment.kyberAdapter,
    deployment.uniswapV2Adapter,
    deployment.trackedAssetsAdapter,
    deployment.chaiAdapter,
  ]);
  const assetBlacklistSettings = assetBlacklistArgs([config.tokens.knc]);

  const policyManagerConfig = policyManagerConfigArgs({
    policies: [
      deployment.maxConcentration,
      deployment.adapterBlacklist,
      deployment.adapterWhitelist,
      deployment.assetBlacklist,
    ],
    settings: [maxConcentrationSettings, adapterBlacklistSettings, adapterWhitelistSettings, assetBlacklistSettings],
  });

  const { comptrollerProxy, vaultProxy } = await createNewFund({
    signer: manager,
    fundDeployer: deployment.fundDeployer,
    fundOwner: manager,
    denominationAsset,
    feeManagerConfig,
    policyManagerConfig,
  });

  return {
    accounts,
    deployment,
    denominationAsset,
    config,
    comptrollerProxy,
    vaultProxy,
  };
}

describe("Walkthrough a fund's lifecycle", () => {
  let manager: SignerWithAddress;
  let investor: SignerWithAddress;
  let anotherInvestor: SignerWithAddress;
  let comptrollerProxy: ComptrollerLib;
  let vaultProxy: VaultLib;
  let deployment: Snapshot['deployment'];
  let denominationAsset: StandardToken;
  let config: ForkReleaseDeploymentConfig;

  beforeAll(async () => {
    const forkSnapshot = await provider.snapshot(snapshot);

    manager = forkSnapshot.accounts[0];
    investor = forkSnapshot.accounts[1];
    anotherInvestor = forkSnapshot.accounts[2];
    comptrollerProxy = forkSnapshot.comptrollerProxy;
    vaultProxy = forkSnapshot.vaultProxy;
    deployment = forkSnapshot.deployment;
    denominationAsset = forkSnapshot.denominationAsset;
    config = forkSnapshot.config;
  });

  it('enables the InvestorWhitelist policy for the fund', async () => {
    const enabled = await deployment.policyManager
      .connect(manager)
      .enablePolicyForFund.args(
        comptrollerProxy.address,
        deployment.investorWhitelist,
        investorWhitelistArgs({
          investorsToAdd: [randomAddress(), randomAddress(), investor.address],
        }),
      )
      .send();

    expect(enabled).toBeReceipt();
  });

  it('buys shares of a fund', async () => {
    const investmentAmount = utils.parseEther('1');
    const minSharesAmount = utils.parseEther('0.00000000001');

    const buySharesArgs = {
      investmentAmount,
      amguValue: investmentAmount,
      minSharesAmount,
    };

    const buySharesTx = await buyShares({
      comptrollerProxy,
      signer: investor,
      buyer: investor,
      denominationAsset,
      ...buySharesArgs,
    });

    expect(buySharesTx).toCostLessThan(340000);

    const rate = utils.parseEther('0.05');
    const rateDivisor = utils.parseEther('1');
    const expectedFee = utils.parseEther('1').mul(rate).div(rateDivisor.add(rate));

    expect(await vaultProxy.balanceOf(investor)).toBeGteBigNumber(utils.parseEther('1').sub(expectedFee));
  });

  it('buys more shares of a fund', async () => {
    const previousBalance = await vaultProxy.balanceOf(investor);

    const investmentAmount = utils.parseEther('1');
    const minSharesAmount = utils.parseEther('0.00000000001');

    const buySharesArgs = {
      investmentAmount,
      amguValue: utils.parseEther('1'),
      minSharesAmount,
    };

    const buySharesTx = await buyShares({
      comptrollerProxy,
      signer: investor,
      buyer: investor,
      denominationAsset,
      ...buySharesArgs,
    });

    expect(buySharesTx).toCostLessThan(380000);
    expect(await vaultProxy.balanceOf(investor)).toBeGteBigNumber(minSharesAmount.add(previousBalance));
  });

  it('trades on Kyber', async () => {
    const kyberNetworkProxy = new KyberNetworkProxy(config.integratees.kyber, provider);

    const outgoingAsset = config.tokens.weth;
    const incomingAsset = config.tokens.dai;
    const outgoingAssetAmount = utils.parseEther('0.1');

    const { expectedRate } = await kyberNetworkProxy.getExpectedRate(outgoingAsset, incomingAsset, outgoingAssetAmount);
    expect(expectedRate).toBeGtBigNumber(0);

    const minIncomingAssetAmount = expectedRate.mul(outgoingAssetAmount).div(utils.parseEther('1'));

    const takeOrder = await kyberTakeOrder({
      comptrollerProxy,
      vaultProxy,
      integrationManager: deployment.integrationManager,
      fundOwner: manager,
      kyberAdapter: deployment.kyberAdapter,
      incomingAsset,
      minIncomingAssetAmount,
      outgoingAsset,
      outgoingAssetAmount,
    });

    expect(takeOrder).toCostLessThan(980000);

    const balance = await incomingAsset.balanceOf(vaultProxy);
    expect(balance).toBeGteBigNumber(minIncomingAssetAmount);
  });

  it('trades on Uniswap', async () => {
    const outgoingAssetAmount = utils.parseEther('0.1');

    const path = [config.tokens.weth, config.tokens.rep];
    const routerContract = new IUniswapV2Router2(config.integratees.uniswapV2.router, provider);
    const amountsOut = await routerContract.getAmountsOut(outgoingAssetAmount, path);

    const takeOrder = await uniswapV2TakeOrder({
      comptrollerProxy,
      vaultProxy,
      integrationManager: deployment.integrationManager,
      fundOwner: manager,
      uniswapV2Adapter: deployment.uniswapV2Adapter,
      path,
      minIncomingAssetAmount: amountsOut[1],
      outgoingAssetAmount,
    });

    expect(takeOrder).toCostLessThan(630000);
  });

  xit('lends and redeems Chai', async () => {
    // const daiAmount = utils.parseEther('1');
    // const lend = await chaiLend({
    //   comptrollerProxy,
    //   vaultProxy,
    //   integrationManager: deployment.integrationManager,
    //   fundOwner: manager,
    //   chaiAdapter: deployment.chaiAdapter,
    //   dai: config.tokens.dai,
    //   daiAmount,
    //   minChaiAmount: daiAmount.div(2),
    // });
    // expect(lend).toCostLessThan(100000);
    // const chaiAmount = utils.parseEther('1');
    // const redeem = await chaiRedeem({
    //   comptrollerProxy,
    //   vaultProxy,
    //   integrationManager: deployment.integrationManager,
    //   fundOwner: manager,
    //   chai: config.derivatives.chai,
    //   chaiAdapter: deployment.chaiAdapter,
    //   chaiAmount,
    //   // minDaiAmount: chaiAmount.div(2),
    // });
    // expect(lend).toCostLessThan(100000);
  });

  it('seeds the fund with all existing assets', async () => {
    const assets = [
      config.tokens.bat,
      config.tokens.bnb,
      config.tokens.bnt,
      config.tokens.comp,
      config.tokens.link,
      config.tokens.mana,
      config.tokens.ren,
      config.tokens.uni,
      config.tokens.usdc,
      config.tokens.usdt,
      config.tokens.zrx,
    ];
    const compoundAssets = [
      new StandardToken(config.derivatives.compound.cbat, provider),
      new StandardToken(config.derivatives.compound.ccomp, provider),
      new StandardToken(config.derivatives.compound.cdai, provider),
      new StandardToken(config.derivatives.compound.ceth, provider),
      new StandardToken(config.derivatives.compound.crep, provider),
      new StandardToken(config.derivatives.compound.cuni, provider),
    ];

    for (const asset of [...assets, ...compoundAssets]) {
      const decimals = await asset.decimals();
      const transferAmount = utils.parseUnits('1', decimals);

      await asset.connect(manager).transfer.args(vaultProxy, transferAmount).send();

      const balance = await asset.balanceOf(vaultProxy);
      expect(balance).toBeGteBigNumber(transferAmount);
    }

    await addTrackedAssets({
      comptrollerProxy,
      integrationManager: deployment.integrationManager,
      fundOwner: manager,
      trackedAssetsAdapter: deployment.trackedAssetsAdapter,
      incomingAssets: assets,
    });

    await addTrackedAssets({
      comptrollerProxy,
      integrationManager: deployment.integrationManager,
      fundOwner: manager,
      trackedAssetsAdapter: deployment.trackedAssetsAdapter,
      incomingAssets: compoundAssets,
    });
  });

  it('trades on Kyber again', async () => {
    const kyberNetworkProxy = new KyberNetworkProxy(config.integratees.kyber, provider);

    const outgoingAsset = config.tokens.weth;
    const incomingAsset = config.tokens.dai;
    const outgoingAssetAmount = utils.parseEther('0.1');

    const { expectedRate } = await kyberNetworkProxy.getExpectedRate(outgoingAsset, incomingAsset, outgoingAssetAmount);
    expect(expectedRate).toBeGteBigNumber(0);

    const minIncomingAssetAmount = expectedRate.mul(outgoingAssetAmount).div(utils.parseEther('1'));

    const takeOrder = await kyberTakeOrder({
      comptrollerProxy,
      vaultProxy,
      integrationManager: deployment.integrationManager,
      fundOwner: manager,
      kyberAdapter: deployment.kyberAdapter,
      incomingAsset,
      minIncomingAssetAmount,
      outgoingAsset,
      outgoingAssetAmount,
    });

    expect(takeOrder).toBeReceipt();
    expect(takeOrder).toCostLessThan(2050000);

    const balance = await incomingAsset.balanceOf(vaultProxy);
    expect(balance).toBeGteBigNumber(minIncomingAssetAmount);
  });

  it('trades on Uniswap again', async () => {
    const outgoingAssetAmount = utils.parseEther('0.1');

    const path = [config.tokens.weth, config.tokens.rep];
    const routerContract = new IUniswapV2Router2(config.integratees.uniswapV2.router, provider);
    const amountsOut = await routerContract.getAmountsOut(outgoingAssetAmount, path);

    const takeOrder = await uniswapV2TakeOrder({
      comptrollerProxy,
      vaultProxy,
      integrationManager: deployment.integrationManager,
      fundOwner: manager,
      uniswapV2Adapter: deployment.uniswapV2Adapter,
      path,
      minIncomingAssetAmount: amountsOut[1],
      outgoingAssetAmount,
    });

    expect(takeOrder).toBeReceipt();
    expect(takeOrder).toCostLessThan(1620000);
  });

  it("sends an asset amount to the fund's vault", async () => {
    const gavBefore = await comptrollerProxy.calcGav.call();
    const grossShareValueBefore = await comptrollerProxy.calcGrossShareValue.call();

    const asset = config.tokens.dai;
    const amount = utils.parseEther('1');

    await asset.connect(manager).transfer(vaultProxy, amount);

    const gavAfter = await comptrollerProxy.calcGav.call();
    const grossShareValueAfter = await comptrollerProxy.calcGrossShareValue.call();

    expect(gavAfter.gav_).toBeGtBigNumber(gavBefore.gav_);
    expect(grossShareValueAfter.grossShareValue_).toBeGtBigNumber(grossShareValueBefore.grossShareValue_);
  });

  it('redeems some shares of the investor', async () => {
    const balance = await vaultProxy.balanceOf(investor);
    const redeemQuantity = balance.div(2);

    const redeemed = await redeemShares({
      comptrollerProxy,
      signer: investor,
      quantity: redeemQuantity,
    });

    expect(redeemed).toCostLessThan(2600000);
    expect(await vaultProxy.balanceOf(investor)).toEqBigNumber(balance.sub(redeemQuantity));
  });

  it("sends an asset amount to the fund's vault again", async () => {
    const gavBefore = await comptrollerProxy.calcGav.call();
    const grossShareValueBefore = await comptrollerProxy.calcGrossShareValue.call();

    const asset = config.tokens.zrx;
    const amount = utils.parseEther('1');

    await asset.connect(manager).transfer(vaultProxy, amount);

    const gavAfter = await comptrollerProxy.calcGav.call();
    const grossShareValueAfter = await comptrollerProxy.calcGrossShareValue.call();

    expect(gavAfter.gav_).toBeGtBigNumber(gavBefore.gav_);
    expect(grossShareValueAfter.grossShareValue_).toBeGtBigNumber(grossShareValueBefore.grossShareValue_);
  });

  it('changes the InvestorWhitelist', async () => {
    const enabled = await deployment.policyManager
      .connect(manager)
      .updatePolicySettingsForFund.args(
        comptrollerProxy.address,
        deployment.investorWhitelist,
        investorWhitelistArgs({
          investorsToAdd: [anotherInvestor],
          investorsToRemove: [investor],
        }),
      )
      .send();

    expect(enabled).toBeReceipt();
  });

  it('buys shares of a fund as another investor', async () => {
    const investmentAmount = utils.parseEther('1');

    const grossShareValue = await comptrollerProxy.calcGrossShareValue.call();
    const minSharesAmount = investmentAmount
      .mul(utils.parseEther('1'))
      .div(grossShareValue.grossShareValue_)
      .mul(95) // deduct 5% for safety
      .div(100);

    const buySharesArgs = {
      investmentAmount,
      amguValue: investmentAmount,
      minSharesAmount,
    };

    const buySharesTx = await buyShares({
      comptrollerProxy,
      signer: anotherInvestor,
      buyer: anotherInvestor,
      denominationAsset,
      ...buySharesArgs,
    });

    expect(buySharesTx).toCostLessThan(1500000);
    expect(await vaultProxy.balanceOf(anotherInvestor)).toBeGteBigNumber(minSharesAmount);
  });

  it('redeems all remaining shares of the first investor', async () => {
    const redeemed = await redeemShares({
      comptrollerProxy,
      signer: investor,
    });

    expect(redeemed).toCostLessThan(2600000);
    expect(await vaultProxy.balanceOf(investor)).toEqBigNumber(utils.parseEther('0'));
  });

  it('redeems all remaining shares of the other investor', async () => {
    const redeemed = await redeemShares({
      comptrollerProxy,
      signer: anotherInvestor,
    });

    expect(redeemed).toCostLessThan(2600000);
    expect(await vaultProxy.balanceOf(anotherInvestor)).toEqBigNumber(utils.parseEther('0'));
  });
});
