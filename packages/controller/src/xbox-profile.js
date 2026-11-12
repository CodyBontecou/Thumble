const controls = [];
const mappings = [];
function add(id, type, label, frame, outputs, color) {
  controls.push({ id, type, label, frame, ...(color ? { color } : {}) });
  mappings.push({ controlId: id, outputs, ...(type === 'stick' ? { deadzone: 0.12, sensitivity: 1 } : {}) });
}
function button(id, label, x, y, output = id, color) {
  add(id, 'button', label, { x, y, width: 0.09, height: 0.17 }, [output], color);
}
// Every target clears 48 points (96 for sticks) on a 568 × 300 landscape canvas
// and stays out of the menu and chat corners at the top.
add('left-stick', 'stick', 'Move', { x: 0.04, y: 0.22, width: 0.2, height: 0.42 }, ['lx', 'ly']);
add('right-stick', 'stick', 'Look', { x: 0.56, y: 0.58, width: 0.2, height: 0.4 }, ['rx', 'ry']);
button('up', 'Up', 0.315, 0.48);
button('left', 'Left', 0.225, 0.65);
button('right', 'Right', 0.405, 0.65);
button('down', 'Down', 0.315, 0.82);
button('a', 'A', 0.795, 0.54, 'a', '#30D158');
button('b', 'B', 0.885, 0.37, 'b', '#FF6961');
button('x', 'X', 0.705, 0.37, 'x', '#64A8FF');
button('y', 'Y', 0.795, 0.2, 'y', '#FFD60A');
button('back', 'View', 0.4, 0.3);
button('start', 'Menu', 0.51, 0.3);
button('ls', 'L3', 0.03, 0.8);
button('rs', 'R3', 0.88, 0.78);
add('lt', 'trigger', 'LT', { x: 0.02, y: 0.02, width: 0.14, height: 0.17 }, ['lt']);
add('lb', 'button', 'LB', { x: 0.18, y: 0.02, width: 0.14, height: 0.17 }, ['lb']);
add('rb', 'button', 'RB', { x: 0.6, y: 0.02, width: 0.14, height: 0.17 }, ['rb']);
add('rt', 'trigger', 'RT', { x: 0.76, y: 0.02, width: 0.14, height: 0.17 }, ['rt']);

// A template, never the mutable active profile. Consumers copy through assertProfile.
export const xboxProfile = Object.freeze({
  schemaVersion: 1,
  id: 'xbox-standard',
  name: 'Xbox-style controller',
  controls: Object.freeze(controls.map(control => Object.freeze({ ...control, frame: Object.freeze(control.frame) }))),
  mappings: Object.freeze(mappings.map(mapping => Object.freeze({ ...mapping, outputs: Object.freeze(mapping.outputs) }))),
});
