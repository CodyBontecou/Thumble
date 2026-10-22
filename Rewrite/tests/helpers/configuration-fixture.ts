import { LosslessJson } from "@thumble/contracts/json";
export const a = "aaaaaaaa-0000-0000-0000-000000000001",
  b = "bbbbbbbb-0000-0000-0000-000000000002";
export function catalogFixtureSource(count = 2): LosslessJson {
  const profiles = Array.from(
    { length: count },
    (_, i) =>
      `{"id":"${i === 0 ? a : i === 1 ? b : `cccccccc-0000-0000-0000-${String(i).padStart(12, "0")}`}","name":${JSON.stringify(i === 0 ? "First" : "Second")},"updatedAt":${i === 0 ? "9223372036854775806" : "0"},"profileFormatVersion":5,"customization":{"opaque":1e9999}}`,
  );
  return LosslessJson.parse(
    ` {"schema":"com.codybontecou.pocketpad.keypad-configuration","version":5,"profiles":[${profiles.join(",")}],"activeProfileID":"${b}","defaultProfileID":null,"opaque":{ "huge":18446744073709551615, "decimal":-0.0000 }} `,
  );
}
