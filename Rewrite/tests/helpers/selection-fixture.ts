import { LosslessJson } from "@thumble/contracts/json";
import { a, b } from "./configuration-fixture.ts";
export { a, b };
export const firstControl = "ca000000-0000-0000-0000-000000000001",
  secondControl = "db000000-0000-0000-0000-000000000002";
/** Two fully owned profiles deliberately sharing no control identity. */
export function selectionFixtureSource(): LosslessJson {
  const keysA = {
      [firstControl]: {
        keyCode: 1,
        modifiers: 0,
        futureBinding: { preserve: "first" },
      },
    },
    keysB = {
      [secondControl]: {
        keyCode: 2,
        modifiers: 4,
        futureBinding: { preserve: "second" },
      },
    };
  const outputsA = {
      [firstControl]: {
        gamepadButtons: ["north"],
        futureBinding: { preserve: "first" },
      },
    },
    outputsB = {
      [secondControl]: {
        gamepadButtons: ["south"],
        futureBinding: { preserve: "second" },
      },
    };
  return LosslessJson.parse(
    JSON.stringify({
      schema: "com.codybontecou.pocketpad.keypad-configuration",
      version: 5,
      activeProfileID: b,
      defaultProfileID: null,
      profiles: [
        {
          id: a,
          name: "First",
          updatedAt: 1,
          profileFormatVersion: 5,
          customization: {
            deviceCanvas: { frameID: "iphone-16-landscape" },
            elements: [
              {
                id: firstControl,
                kind: "button",
                output: {
                  keyboard: { keyCode: 10, modifiersRawValue: 0 },
                  gamepadButtons: ["west"],
                },
              },
            ],
            customButtons: [],
          },
        },
        {
          id: b,
          name: "Second",
          updatedAt: 2,
          profileFormatVersion: 5,
          outputMode: "keyboard",
          customization: {
            deviceCanvas: { frameID: "iphone-16-landscape" },
            elements: [
              {
                id: secondControl,
                kind: "button",
                defaultOutput: {
                  keyboard: { keyCode: 30, modifiersRawValue: 0 },
                  gamepadButtons: ["east"],
                },
                output: {
                  keyboard: { keyCode: 20, modifiersRawValue: 2 },
                  gamepadButtons: ["south"],
                },
              },
            ],
            customButtons: [],
          },
        },
      ],
      keyBindings: keysB,
      outputBindings: outputsB,
      profileKeyBindings: { [a]: keysA, [b]: keysB },
      profileOutputBindings: { [a]: outputsA, [b]: outputsB },
      opaque: { preserve: true },
    }),
  ).set("/opaque/large", "9007199254740993.0000");
}
