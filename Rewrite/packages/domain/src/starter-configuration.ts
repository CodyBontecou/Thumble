import { LosslessJson } from "@thumble/contracts/json";
import {
  configurationProfileId,
  configurationProfileName,
} from "@thumble/contracts/configuration";
import { counter } from "@thumble/contracts/receiver";
import { standardControllerMap } from "./controller-layout.ts";

/** Production-owned starter v1. No repository fixture, desktop, resource or runtime dependency. */
export function starterConfiguration(
  profileId: string,
  name: string,
  updatedAt: string,
): LosslessJson {
  profileId = configurationProfileId(profileId);
  name = configurationProfileName(name);
  updatedAt = counter(updatedAt);
  if (BigInt(updatedAt) > 9223372036854775807n)
    throw new Error("configuration_clock_invalid");
  const centers: Readonly<Record<string, readonly [number, number]>> = {
    leftStick: [0.18, 0.78],
    rightStick: [0.82, 0.78],
    dpadUp: [0.155, 0.11],
    dpadLeft: [0.075, 0.24],
    dpadRight: [0.235, 0.24],
    dpadDown: [0.155, 0.37],
    north: [0.845, 0.11],
    west: [0.765, 0.24],
    east: [0.925, 0.24],
    south: [0.845, 0.37],
    leftShoulder: [0.37, 0.11],
    rightShoulder: [0.63, 0.11],
    leftTrigger: [0.37, 0.43],
    rightTrigger: [0.63, 0.43],
    select: [0.43, 0.56],
    start: [0.57, 0.56],
    leftStickPress: [0.43, 0.78],
    rightStickPress: [0.57, 0.78],
  };
  const outputBindings: Record<string, { gamepadButtons: string[] }> = {};
  const elements = standardControllerMap("1", "0")
    .controls.filter((c) => c.action !== "home")
    .map((control, index) => {
      const action = control.action;
      const center = centers[action];
      if (!center) throw new Error("configuration_starter_invalid");
      const id = `ce000000-0000-0000-0000-${(index + 1).toString(16).padStart(12, "0")}`;
      const stick = action === "leftStick" || action === "rightStick";
      const trigger = action === "leftTrigger" || action === "rightTrigger";
      const kind = stick ? "joystick" : trigger ? "trigger" : "button";
      const layout = {
        centerX: center[0],
        centerY: center[1],
        widthScale: stick ? 0.95 : trigger ? 0.65 : 0.5,
        heightScale: stick ? 0.95 : trigger ? 0.8 : 0.5,
        shape: stick ? "circle" : "rectangle",
        isHidden: false,
        rotationDegrees: 0,
        zIndex: 0,
        hitInsets: { top: 0, leading: 0, bottom: 0, trailing: 0 },
      };
      if (stick)
        return {
          id,
          kind,
          label: action === "leftStick" ? "Movement" : "Camera",
          layout,
          joystickOutputSettings: {
            analogTarget: action === "leftStick" ? "left_stick" : "right_stick",
            sendsDigitalDirections: false,
            deadZone: 0.12,
            sensitivity: 1,
            invertX: false,
            invertY: false,
            snapToCardinal: false,
          },
        };
      if (trigger)
        return {
          id,
          kind,
          label: action === "leftTrigger" ? "Left trigger" : "Right trigger",
          layout,
          triggerSettings: {
            target: action === "leftTrigger" ? "left" : "right",
            orientation: "vertical",
            deadZone: 0.03,
            sensitivity: 1,
            sendsDigitalButton: false,
            digitalThreshold: 0.5,
          },
        };
      const output = { gamepadButtons: [action] };
      outputBindings[id] = output;
      return { id, kind, label: action, layout, output };
    });
  return LosslessJson.parse(
    JSON.stringify({
      schema: "com.codybontecou.pocketpad.keypad-configuration",
      version: 5,
      profiles: [
        {
          id: profileId,
          name,
          updatedAt: 0,
          profileFormatVersion: 5,
          outputMode: "controller",
          customization: {
            deviceCanvas: { frameID: "iphone-16-landscape" },
            controlScale: "standard",
            elements,
            customButtons: [],
          },
        },
      ],
      activeProfileID: profileId,
      defaultProfileID: profileId,
      keyBindings: {},
      outputBindings,
      profileKeyBindings: { [profileId]: {} },
      profileOutputBindings: { [profileId]: outputBindings },
    }),
  ).set("/profiles/0/updatedAt", updatedAt);
}
