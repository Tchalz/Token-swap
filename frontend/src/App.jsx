import { useEffect, useState } from 'react'
import {
  createPublicClient, createWalletClient, custom, http,
  formatUnits, parseUnits, maxUint256,
} from 'viem'
import { POOL, TOKEN_A, TOKEN_B, CHAIN, RPC_URL, CHAIN_PARAMS, poolAbi, tokenAbi } from './config'

const pub = createPublicClient({ chain: CHAIN, transport: http(RPC_URL) })
const read = (address, abi, functionName, args = []) =>
  pub.readContract({ address, abi, functionName, args })
const fmt = (v) =>
  Number(formatUnits(v ?? 0n, 18)).toLocaleString(undefined, { maximumFractionDigits: 4 })
const parse = (s) => {
  try { return /^\d*\.?\d+$/.test(s) ? parseUnits(s, 18) : 0n } catch { return 0n }
}

export default function App() {
  const [account, setAccount] = useState(null)
  const [d, setD] = useState({ rA: 0n, rB: 0n, balA: 0n, balB: 0n, shares: 0n, total: 0n })
  const [aToB, setAToB] = useState(true)
  const [amtIn, setAmtIn] = useState('')
  const [quote, setQuote] = useState(0n)
  const [liqA, setLiqA] = useState('')
  const [liqB, setLiqB] = useState('')
  const [msg, setMsg] = useState('')

  async function refresh(acc = account) {
    const [[rA, rB], total] = await Promise.all([
      read(POOL, poolAbi, 'getReserves'),
      read(POOL, poolAbi, 'totalShares'),
    ])
    let balA = 0n, balB = 0n, shares = 0n
    if (acc) {
      ;[balA, balB, shares] = await Promise.all([
        read(TOKEN_A, tokenAbi, 'balanceOf', [acc]),
        read(TOKEN_B, tokenAbi, 'balanceOf', [acc]),
        read(POOL, poolAbi, 'liquidityShares', [acc]),
      ])
    }
    setD({ rA, rB, balA, balB, shares, total })
  }

  useEffect(() => {
    refresh().catch((e) => setMsg(e.shortMessage || e.message))
    if (!window.ethereum) return
    const onChange = (accs) => {
      const a = accs[0] ?? null
      setAccount(a)
      refresh(a)
    }
    window.ethereum.on('accountsChanged', onChange)
    return () => window.ethereum.removeListener('accountsChanged', onChange)
  }, [])

  useEffect(() => {
    const n = parse(amtIn)
    if (n === 0n) { setQuote(0n); return }
    read(POOL, poolAbi, 'getAmountOut', [aToB ? TOKEN_A : TOKEN_B, n])
      .then(setQuote).catch(() => setQuote(0n))
  }, [amtIn, aToB, d.rA])

  async function connect() {
    try {
      const [acc] = await window.ethereum.request({ method: 'eth_requestAccounts' })
      try {
        await window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: CHAIN_PARAMS.chainId }],
        })
      } catch {
        try {
          await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [CHAIN_PARAMS] })
        } catch { /* rejected */ }
      }
      setAccount(acc)
      await refresh(acc)
    } catch (e) { setMsg(e.shortMessage || e.message) }
  }

  const wallet = () => createWalletClient({ chain: CHAIN, transport: custom(window.ethereum) })

  async function send(address, abi, functionName, args) {
    const hash = await wallet().writeContract({ address, abi, functionName, args, account })
    await pub.waitForTransactionReceipt({ hash })
  }

  async function ensureAllowance(token, amount) {
    const cur = await read(token, tokenAbi, 'allowance', [account, POOL])
    if (cur < amount) await send(token, tokenAbi, 'approve', [POOL, maxUint256])
  }

  async function run(label, fn) {
    try {
      setMsg(`${label}...`)
      await fn()
      await refresh()
      setMsg(`${label}: done`)
    } catch (e) { setMsg(e.shortMessage || e.message) }
  }

  const faucet = () => run('Faucet', async () => {
    await send(TOKEN_A, tokenAbi, 'mint', [account, parseUnits('1000', 18)])
    await send(TOKEN_B, tokenAbi, 'mint', [account, parseUnits('1000', 18)])
  })

  const swap = () => run('Swap', async () => {
    const n = parse(amtIn)
    const tokenIn = aToB ? TOKEN_A : TOKEN_B
    await ensureAllowance(tokenIn, n)
    await send(POOL, poolAbi, 'swap', [tokenIn, n, (quote * 99n) / 100n]) // 1% slippage
    setAmtIn('')
  })

  const addLiq = () => run('Add liquidity', async () => {
    const a = parse(liqA), b = parse(liqB)
    await ensureAllowance(TOKEN_A, a)
    await ensureAllowance(TOKEN_B, b)
    await send(POOL, poolAbi, 'addLiquidity', [a, b])
    setLiqA(''); setLiqB('')
  })

  const removeLiq = (pct) => run('Remove liquidity', () =>
    send(POOL, poolAbi, 'removeLiquidity', [(d.shares * BigInt(pct)) / 100n]))

  function onLiqA(v) {
    setLiqA(v)
    const a = parse(v)
    setLiqB(d.rA > 0n && a > 0n ? formatUnits((a * d.rB) / d.rA, 18) : '')
  }

  const [inSym, outSym] = aToB ? ['TKA', 'TKB'] : ['TKB', 'TKA']
  const price = d.rA > 0n ? Number(formatUnits(d.rB, 18)) / Number(formatUnits(d.rA, 18)) : 0
  const ready = !!account

  return (
    <main>
      <h1>Token Swap Pool</h1>
      <div className="muted">Constant-product AMM on {CHAIN_PARAMS.chainName}</div>

      {!ready ? (
        <div className="card"><button onClick={connect}>Connect MetaMask</button></div>
      ) : (
        <div className="card">
          <div className="row"><span className="muted">Account</span><span>{account.slice(0, 6)}...{account.slice(-4)}</span></div>
          <div className="row"><span className="muted">Your TKA</span><span>{fmt(d.balA)}</span></div>
          <div className="row"><span className="muted">Your TKB</span><span>{fmt(d.balB)}</span></div>
          <button className="alt" onClick={faucet}>Get 1,000 TKA + 1,000 TKB</button>
        </div>
      )}

      <div className="card">
        <h2>Pool</h2>
        <div className="row"><span className="muted">Reserve TKA</span><span>{fmt(d.rA)}</span></div>
        <div className="row"><span className="muted">Reserve TKB</span><span>{fmt(d.rB)}</span></div>
        <div className="row"><span className="muted">Price</span><span>1 TKA = {price.toFixed(4)} TKB</span></div>
        <div className="row"><span className="muted">Your pool share</span>
          <span>{d.total > 0n ? ((Number(d.shares) / Number(d.total)) * 100).toFixed(2) : '0.00'}%</span></div>
      </div>

      <div className="card">
        <h2>Swap</h2>
        <input placeholder={`Amount of ${inSym}`} value={amtIn} onChange={(e) => setAmtIn(e.target.value)} />
        <div className="row"><span className="muted">You receive (est.)</span><span>{fmt(quote)} {outSym}</span></div>
        <button className="alt" onClick={() => setAToB(!aToB)}>Flip direction</button>
        <button disabled={!ready || quote === 0n} onClick={swap}>Swap {inSym} for {outSym}</button>
      </div>

      <div className="card">
        <h2>Liquidity</h2>
        <input placeholder="Amount of TKA" value={liqA} onChange={(e) => onLiqA(e.target.value)} />
        <input placeholder="Amount of TKB (auto-matched)" value={liqB} onChange={(e) => setLiqB(e.target.value)} />
        <button disabled={!ready || parse(liqA) === 0n || parse(liqB) === 0n} onClick={addLiq}>Add liquidity</button>
        <div className="row" style={{ marginTop: 14 }}>
          <span className="muted">Your shares</span><span>{fmt(d.shares)}</span>
        </div>
        {[25, 50, 100].map((p) => (
          <button key={p} className="alt" disabled={!ready || d.shares === 0n} onClick={() => removeLiq(p)}>
            Remove {p}%
          </button>
        ))}
      </div>

      {msg && <div className="msg">{msg}</div>}
    </main>
  )
}
