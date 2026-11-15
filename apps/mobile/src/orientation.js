import native from '../modules/tapping-link';
import { createOrientationController } from './orientation-core';

const controller = createOrientationController(landscape => native.requestOrientation?.(landscape));
export const requestOrientation = landscape => controller.request(landscape).catch(error => {
  // Resizable iOS windows can refuse a lock. ControllerScreen uses its measured
  // window shape to pause input and show recovery instead of distorted controls.
  if (__DEV__) console.warn('Thumble orientation request:', error.message);
});
export const landscapeRoute = path => ['/', '/controller-menu', '/layout-editor'].includes(path);
