'use strict';
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const mapRoot = path.join(root, 'assets', 'maps');
const maps = ['Mirage', 'Inferno', 'Ancient', 'Nuke', 'Anubis', 'Dust II', 'Vertigo', 'Cache', 'Overpass'];
const groups = {
  lineups: new Set(['.mp4', '.webm', '.mov', '.m4v']),
  boosts: new Set(['.mp4', '.webm', '.mov', '.m4v']),
  callouts: new Set(['.png', '.jpg', '.jpeg', '.webp']),
};
const mimeTypes = {
  '.mp4': 'video/mp4', '.webm': 'video/webm', '.mov': 'video/quicktime', '.m4v': 'video/mp4',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp',
};
const catalog = [];
for (const map of maps) {
  for (const [group, extensions] of Object.entries(groups)) {
    const folder = path.join(mapRoot, map, group);
    if (!fs.existsSync(folder)) continue;
    for (const fileName of fs.readdirSync(folder).sort((a, b) => a.localeCompare(b, 'fr'))) {
      const fullPath = path.join(folder, fileName);
      if (!fs.statSync(fullPath).isFile()) continue;
      const extension = path.extname(fileName).toLowerCase();
      if (!extensions.has(extension)) continue;
      const key = fileName.slice(0, -path.extname(fileName).length);
      catalog.push({
        map,
        group,
        title: key,
        fileName,
        mimeType: mimeTypes[extension],
        localPath: path.posix.join('assets/maps', map, group, fileName),
        mediaId: 'local:' + [map, group, key].join(':').toLowerCase(),
      });
    }
  }
}
const output = '// Generated from assets/maps/*/*; filenames are displayed as titles. Do not edit by hand.\n'
  + 'window.YUREI_LOCAL_MAP_MEDIA = ' + JSON.stringify(catalog, null, 2) + ';\n';
fs.writeFileSync(path.join(root, 'local-map-media.js'), output, 'utf8');
console.log('Generated local map media catalog (' + catalog.length + ' files).');
