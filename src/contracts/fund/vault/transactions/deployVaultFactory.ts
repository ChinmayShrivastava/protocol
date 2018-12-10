import { Environment } from '~/utils/environment/Environment';
import { deploy as deployContract } from '~/utils/solidity/deploy';
import { Contracts } from '~/Contracts';

export const deployVaultFactory = async (environment: Environment) => {
  const address = await deployContract(environment, Contracts.VaultFactory);

  return address;
};
