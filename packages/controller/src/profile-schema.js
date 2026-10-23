import { BUTTONS, AXES, TRIGGERS } from './controller.js';
const text = { type: 'string', minLength: 1, maxLength: 80 };
const number = (minimum, maximum) => ({ type: 'number', minimum, maximum });
export const profileSchema = {
  type: 'object', additionalProperties: false, required: ['schemaVersion', 'id', 'name', 'controls', 'mappings'],
  properties: {
    schemaVersion: { const: 1 }, id: { type: 'string', pattern: '^[a-z0-9][a-z0-9-]{0,63}$' }, name: text,
    theme: { enum: ['consoleport'] },
    modifiers: { type: 'object', additionalProperties: false, properties: Object.fromEntries(['shift', 'ctrl', 'alt'].map(key => [key, { enum: [...BUTTONS, ...TRIGGERS, 'none'] }])) },
    controls: { type: 'array', minItems: 1, maxItems: 64, items: {
      type: 'object', additionalProperties: false, required: ['id', 'type', 'label', 'frame'], properties: {
        id: text, type: { enum: ['button', 'stick', 'trigger'] }, label: text, color: { type: 'string', pattern: '^#[0-9a-fA-F]{6}$' },
        icon: { type: 'string', pattern: '^[a-z0-9_]{1,128}$' }, badge: text,
        layers: { type: 'object', additionalProperties: false, properties: Object.fromEntries(['', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-'].map(key => [key, { type: 'object', additionalProperties: false, required: ['label'], properties: { label: text, icon: { type: 'string', pattern: '^[a-z0-9_]{1,128}$' } } }])) },
        frame: { type: 'object', additionalProperties: false, required: ['x', 'y', 'width', 'height'], properties: { x: number(0, 1), y: number(0, 1), width: number(0.01, 1), height: number(0.01, 1) } },
      },
    } },
    mappings: { type: 'array', maxItems: 64, items: {
      type: 'object', additionalProperties: false, required: ['controlId', 'outputs'], properties: {
        controlId: text, outputs: { type: 'array', minItems: 1, maxItems: 2, items: { enum: [...BUTTONS, ...AXES, ...TRIGGERS] } }, deadzone: number(0, 0.5), sensitivity: number(0.1, 3), invertX: { type: 'boolean' }, invertY: { type: 'boolean' },
      },
    } },
  },
  description: 'Normalized safe-area coordinates; x+width and y+height must fit within 1. IDs must be unique. Each control needs exactly one mapping: button to one button, trigger to lt/rt, stick to [lx,ly] or [rx,ry]. Optional invertX/invertY booleans reverse stick output axes without changing thumb visuals. Analog outputs have one owner. Labels do not bind WoW spells. Use validate_profile for semantic checks. No executable code, macros, timers or generated input.',
};
