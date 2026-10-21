export function withSolanaWriteProgress<T>(
  report: (percent: number) => void,
  work: () => Promise<T>,
): Promise<T>;

export function withSolanaReadProgress<T>(
  report: (percent: number) => void,
  work: () => Promise<T>,
  expected?: number,
): Promise<T>;

export function resetSolanaRead(count: number): void;

export function pinSolanaRead(count: number): void;

export function withEvmReadProgress<T>(
  report: (percent: number) => void,
  work: () => Promise<T>,
  provider?: { getTransaction: (...args: never[]) => Promise<unknown> },
): Promise<T>;
