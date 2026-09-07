// Taking turns on a shared, global "which network am I on" setting.
//
// The IQ Labs Ethereum SDK keeps its active network in module state, and that
// state decides which contract address the writer signs against. With one EVM
// chain it could not go wrong. With two it can: a Robinhood read landing
// between a Monad write's setNetwork and its send would point that write at
// the other chain's deployment — same call, wrong contract, real funds.
//
// So a turn belongs to one chain at a time. This is the whole mechanism, kept
// apart from the SDK so it can be tested without one: it knows nothing about
// chains beyond that they are told apart by ===, and calls back to whoever
// owns the actual switch.

/** Points the shared state at one chain. Called once when a turn starts. */
export type ApplyNetwork<C> = (chain: C) => void;

export interface NetworkTurns<C> {
  /** Runs `work` with the shared state on `chain`, and nothing else moving it. */
  run<T>(chain: C, work: () => Promise<T>): Promise<T>;
  /** Who holds the turn and how many are queued. For tests and diagnostics. */
  state(): { chain: C; users: number; waiting: number } | { chain: null; users: 0; waiting: number };
}

export function createNetworkTurns<C>(apply: ApplyNetwork<C>): NetworkTurns<C> {
  let holder: { chain: C; users: number } | null = null;
  const waiting: Array<{ chain: C; grant: () => void }> = [];

  const pump = (): void => {
    // Somebody is still working; the turn is not over.
    if (holder !== null && holder.users > 0) return;
    if (waiting.length === 0) {
      holder = null;
      return;
    }
    // The head of the queue decides whose turn is next, so nobody is skipped.
    const chain = waiting[0].chain;
    apply(chain);
    holder = { chain, users: 0 };
    // Everyone already waiting on that chain shares the turn we just started.
    while (waiting.length > 0 && waiting[0].chain === chain) {
      holder.users++;
      waiting.shift()!.grant();
    }
  };

  const acquire = (chain: C): Promise<void> => {
    // Join a turn in progress on this chain — but only while nobody else is
    // waiting. Without that condition a steady stream of same-chain requests
    // would hold the turn forever and starve the other chain.
    if (holder !== null && holder.users > 0 && holder.chain === chain && waiting.length === 0) {
      holder.users++;
      return Promise.resolve();
    }
    return new Promise<void>((grant) => {
      waiting.push({ chain, grant });
      pump();
    });
  };

  return {
    async run<T>(chain: C, work: () => Promise<T>): Promise<T> {
      await acquire(chain);
      try {
        return await work();
      } finally {
        // Released even when the work threw: a failed write that kept its turn
        // would deadlock every later request.
        if (holder !== null) holder.users = Math.max(holder.users - 1, 0);
        pump();
      }
    },

    state() {
      if (holder === null || holder.users === 0) {
        return { chain: null, users: 0 as const, waiting: waiting.length };
      }
      return { chain: holder.chain, users: holder.users, waiting: waiting.length };
    },
  };
}
