import type { LosslessJson } from "@thumble/contracts/json";
export function invalidOwned(): never {
  throw new Error("invalid_owned_configuration");
}
export function object(value: LosslessJson | undefined): LosslessJson {
  if (value?.kind !== "object") invalidOwned();
  return value;
}
export function field(
  value: LosslessJson,
  key: string,
): LosslessJson | undefined {
  const result = value.get(
    "/" + key.replaceAll("~", "~0").replaceAll("/", "~1"),
  );
  return result?.kind === "null" ? undefined : result;
}
export function entries(
  value: LosslessJson | undefined,
  maximum = 4096,
): readonly (readonly [string, LosslessJson])[] {
  const item = object(value);
  if (item.keys.length > maximum) invalidOwned();
  return item.keys.map(
    (key) =>
      [
        key,
        item.get("/" + key.replaceAll("~", "~0").replaceAll("/", "~1"))!,
      ] as const,
  );
}
export function rows(
  value: LosslessJson | undefined,
  maximum = 4096,
): readonly LosslessJson[] {
  if (value?.kind !== "array" || value.length! > maximum) invalidOwned();
  return Array.from({ length: value.length! }, (_, i) => value.get("/" + i)!);
}
export function uuid(value: string | undefined): string {
  if (
    value === undefined ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      value,
    )
  )
    invalidOwned();
  return value.toLowerCase();
}
export function unsigned(
  value: LosslessJson | undefined,
  maximum: number,
): number {
  const integer = value?.integerValue;
  if (integer === undefined || integer < 0 || integer > maximum) invalidOwned();
  return integer;
}
export function only(value: LosslessJson, fields: readonly string[]): void {
  if (object(value).keys.some((key) => !fields.includes(key))) invalidOwned();
}
export function visit(
  value: LosslessJson,
  inspect: (node: LosslessJson) => void,
): void {
  inspect(value);
  if (value.kind === "object")
    for (const [, item] of entries(value, 131072)) visit(item, inspect);
  else if (value.kind === "array")
    for (const item of rows(value, 131072)) visit(item, inspect);
}
/** Swift UUID-keyed dictionaries may use alternating key/value arrays. */
export function uuidPairs(
  value: LosslessJson | undefined,
  maximum = 2048,
): ReadonlyMap<string, LosslessJson> {
  if (!value || value.kind === "null") return new Map();
  let pairs: readonly (readonly [string | undefined, LosslessJson])[];
  if (value.kind === "object") pairs = entries(value, maximum);
  else {
    const values = rows(value, maximum * 2);
    if (values.length % 2) invalidOwned();
    pairs = Array.from(
      { length: values.length / 2 },
      (_, i) => [values[i * 2]!.stringValue, values[i * 2 + 1]!] as const,
    );
  }
  const result = new Map<string, LosslessJson>();
  for (const [key, item] of pairs) {
    const id = uuid(key);
    if (result.has(id)) invalidOwned();
    result.set(id, item);
  }
  return result;
}
