const controls = [];
const mappings = [];
function add(id, type, label, frame, outputs, color) {
  controls.push({ id, type, label, frame, ...(color ? { color } : {}) });
  mappings.push({ controlId: id, outputs, ...(type === 'stick' ? { deadzone: 0.12, sensitivity: 1 } : {}) });
}
function button(id, label, x, y, output = id, color) {
  add(id, 'button', label, { x, y, width: 0.07, height: 0.14 }, [output], color);
}
add('left-stick', 'stick', 'Move', { x: 0.08, y: 0.22, width: 0.22, height: 0.4 }, ['lx', 'ly']);
add('right-stick', 'stick', 'Look', { x: 0.58, y: 0.57, width: 0.22, height: 0.4 }, ['rx', 'ry']);
button('up', 'Up', 0.335, 0.49);
button('left', 'Left', 0.265, 0.63);
button('right', 'Right', 0.405, 0.63);
button('down', 'Down', 0.335, 0.77);
button('a', 'A', 0.815, 0.50, 'a', '#55b959');
button('b', 'B', 0.895, 0.34, 'b', '#ed625a');
button('x', 'X', 0.735, 0.34, 'x', '#59a4ed');
button('y', 'Y', 0.815, 0.18, 'y', '#efc849');
button('back', 'View', 0.405, 0.3);
button('start', 'Menu', 0.515, 0.3);
button('ls', 'L3', 0.09, 0.72);
button('rs', 'R3', 0.87, 0.75);
add('lb', 'button', 'LB', { x: 0.05, y: 0.02, width: 0.16, height: 0.14 }, ['lb']);
add('rb', 'button', 'RB', { x: 0.79, y: 0.02, width: 0.14, height: 0.14 }, ['rb']);
add('lt', 'trigger', 'LT', { x: 0.24, y: 0.02, width: 0.15, height: 0.14 }, ['lt']);
add('rt', 'trigger', 'RT', { x: 0.61, y: 0.02, width: 0.15, height: 0.14 }, ['rt']);

// A template, never the mutable active profile. Consumers copy through assertProfile.
export const xboxProfile = Object.freeze({
  schemaVersion: 1,
  id: 'xbox-standard',
  name: 'Xbox-style controller',
  controls: Object.freeze(controls.map(control => Object.freeze({ ...control, frame: Object.freeze(control.frame) }))),
  mappings: Object.freeze(mappings.map(mapping => Object.freeze({ ...mapping, outputs: Object.freeze(mapping.outputs) }))),
});
