import path from 'node:path';
import { argentTool, readJSON, root } from './common.mjs';

const { appPath, udid } = readJSON(path.join(root, 'build/mobile-smoke-session.json'));
if (!appPath || !udid) throw new Error('Run this test through npm run mobile:smoke:ios.');
const result = argentTool('reinstall-app', { appPath, udid, bundleId: 'com.thumble.ios' });
if (!result.reinstalled) throw new Error('Clean installation failed.');
