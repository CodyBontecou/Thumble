// Shared, explicit allowlist for the hosted and local MCP servers.
export const thumbleAssets = Object.freeze([
  { name: 'thumble-icon', title: 'Thumble app icon', file: 'icon.png' },
  { name: 'thumble-menu', title: 'Thumble menu artwork', file: 'thumble-menu.png' },
  { name: 'thumble-splash', title: 'Thumble splash image', file: 'splash-icon.png' },
  { name: 'thumble-favicon', title: 'Thumble favicon', file: 'favicon.png' },
].map(asset => Object.freeze({ ...asset, path: `/assets/thumble/${asset.file}`, uri: `thumble://assets/${asset.file}`, mimeType: 'image/png' })));

export function thumbleResources() {
  return thumbleAssets.map(({ name, title, uri, mimeType }) => ({ name, title, uri, mimeType }));
}

export function findThumbleResource(uri) {
  return thumbleAssets.find(asset => asset.uri === uri);
}

export function thumbleIcons(origin) {
  return [{ src: new URL(thumbleAssets[0].path, origin).href, mimeType: 'image/png', sizes: ['1024x1024'] }];
}
