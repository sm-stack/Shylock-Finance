
import { useState, useEffect } from 'react';
import { useWeb3ModalProvider, useWeb3ModalAccount } from '@web3modal/ethers5/react';
import { ethers } from 'ethers';
import { getChainName } from '@/app/utils/getChainName';

export default function RepayBox() {
  const [repayAmount, setRepayAmount] = useState('');
  const [defaultCurrency, setDefaultCurrency] = useState('ETH');
  const { address, chainId, isConnected } = useWeb3ModalAccount();
  const { walletProvider } = useWeb3ModalProvider();

  useEffect(() => {
    const chainName = getChainName(chainId ?? 0);
    const currency = chainName === 'Avalanche Fuji' ? 'AVAX' : 'ETH';
    setDefaultCurrency(currency);
  }, [chainId]);


  const handleInputChange = (e: any) => {
    setRepayAmount(e.target.value);
    console.log(defaultCurrency);
  };

  const handleBorrow = (e: any) => {
    e.preventDefault();
    console.log(`Depositing ${repayAmount} ${defaultCurrency}`);

    // Add here the logic to interact with your smart contract or backend service
  };

  return (
    <div className='w-full'>
      <form onSubmit={handleBorrow}>
        <div className="mb-4 w-full">
          <label htmlFor="repayAmount" className="block text-gray-700 text-sm font-bold mb-2">
            Repay Amount ({defaultCurrency}):
          </label>
          <input
            type="number"
            id="repayAmount"
            value={repayAmount}
            onChange={handleInputChange}
            placeholder={`Enter amount in ${defaultCurrency}`}
            min="0"
            step="0.00001"
            className="shadow appearance-none border rounded w-full h-full py-2 px-3 text-gray-700 leading-tight focus:outline-none focus:shadow-outline"
          />
        </div>
        <button type="submit" className="bg-[#755f44] hover:bg-[#765f99] text-white font-bold py-2 px-4 rounded focus:outline-none focus:shadow-outline">
          Repay
        </button>
      </form>
    </div>
  );
}
