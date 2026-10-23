export type TestSelection = {
  packageMode: boolean;
  shard: { index: number; count: number } | null;
};
export function parseTestSelection(args: readonly string[]): TestSelection {
  if (args.length === 0) return { packageMode: false, shard: null };
  if (args.length === 1 && args[0] === "--package")
    return { packageMode: true, shard: null };
  if (args.length === 2 && args[0] === "--shard") {
    const match = /^([1-9][0-9]*)\/([1-9][0-9]*)$/.exec(args[1]!);
    if (match) {
      const index = Number(match[1]),
        count = Number(match[2]);
      if (count <= 16 && index <= count)
        return { packageMode: false, shard: { index, count } };
    }
  }
  throw new Error("Invalid CI test arguments");
}
export function selectTestFiles(
  files: readonly string[],
  selection: TestSelection,
): string[] {
  if (
    new Set(files).size !== files.length ||
    files.some(
      (file) =>
        !/^\.\/tests\/[A-Za-z0-9_./-]+\.(?:[cm]?[jt]sx?)$/.test(file) ||
        file.includes(".."),
    )
  )
    throw new Error("Invalid CI test inventory");
  const sorted = [...files].sort();
  const selected = selection.packageMode
    ? sorted.filter((file) => file === "./tests/package.test.ts")
    : selection.shard
      ? sorted.filter(
          (_, index) =>
            index % selection.shard!.count === selection.shard!.index - 1,
        )
      : sorted;
  if (selected.length === 0) throw new Error("Empty CI test selection");
  return selected;
}
