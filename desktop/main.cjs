const { app, BrowserWindow, ipcMain, shell, protocol, net, Notification } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const { pathToFileURL } = require('node:url');
const { autoUpdater } = require('electron-updater');

const scheme = 'yurei';
const contentScheme = 'yurei-app';
const indexPath = path.join(app.getAppPath(), 'index.html');
let mainWindow;
const updateEnforcementEnabled = app.isPackaged && process.platform === 'win32';
let updateStatus = { state: updateEnforcementEnabled ? 'checking' : 'unavailable' };
const preferencePath = () => path.join(app.getPath('userData'), 'preferences.json');
function readPreferences() {
  try {
    const saved = JSON.parse(fs.readFileSync(preferencePath(), 'utf8'));
    return { launchAtStartup: saved.launchAtStartup !== false, notifications: saved.notifications !== false };
  } catch {
    return { launchAtStartup: true, notifications: true };
  }
}
function writePreferences(patch) {
  const current = readPreferences();
  const next = { ...current, ...patch };
  fs.mkdirSync(app.getPath('userData'), { recursive: true });
  fs.writeFileSync(preferencePath(), JSON.stringify(next, null, 2), 'utf8');
  if (process.platform === 'win32') app.setLoginItemSettings({ openAtLogin: next.launchAtStartup });
  return next;
}

protocol.registerSchemesAsPrivileged([{
  scheme: contentScheme,
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true },
}]);

function loadApp(query = {}) {
  const target = new URL(`${contentScheme}://desktop/index.html`);
  for (const [key, value] of Object.entries(query)) target.searchParams.set(key, value);
  return mainWindow.loadURL(target.toString());
}

function publishUpdateStatus(state, details = {}) {
  updateStatus = { state, ...details };
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send('app:update-status', updateStatus);
  }
}

function parseAuthCallback(deepLink) {
  if (!deepLink) return null;
  let callback;
  try {
    callback = new URL(deepLink);
  } catch {
    return null;
  }
  const isRecovery = callback.protocol === `${scheme}:` && callback.hostname === 'reset-password';
  const isAuth = callback.protocol === `${scheme}:` && callback.hostname === 'auth' && callback.pathname === '/callback';
  if (!isRecovery && !isAuth) return null;
  const query = Object.fromEntries(callback.searchParams.entries());
  if (callback.hash) query.hash = callback.hash.slice(1);
  query.yurei_callback = isRecovery ? 'recovery' : 'auth';
  return query;
}

function openAuthCallback(deepLink) {
  const query = parseAuthCallback(deepLink);
  if (!query) return;
  if (mainWindow && !mainWindow.isDestroyed()) {
    loadApp(query);
    mainWindow.show();
    mainWindow.focus();
  } else {
    app.whenReady().then(() => createWindow(query));
  }
}

function createWindow(query = {}) {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 1024,
    minHeight: 700,
    title: 'Yurei',
    icon: path.join(app.getAppPath(), 'yurei.ico'),
    backgroundColor: '#0b0d11',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  // This is a desktop app: keep the UI at native 100% scale and block browser zoom shortcuts.
  mainWindow.webContents.setZoomFactor(1);
  mainWindow.webContents.setVisualZoomLevelLimits(1, 1).catch(() => {});
  mainWindow.webContents.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown' || !(input.control || input.meta)) return;
    const key = input.key.toLowerCase();
    if (key === '+' || key === '=' || key === '-' || key === '_' || key === '0') {
      event.preventDefault();
    }
  });
  mainWindow.maximize();

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith('https://')) shell.openExternal(url);
    return { action: 'deny' };
  });
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (url.startsWith('https://') || url.startsWith(`${scheme}://`)) {
      event.preventDefault();
      if (url.startsWith('https://')) shell.openExternal(url);
      else openAuthCallback(url);
    }
  });
  mainWindow.on('closed', () => { mainWindow = null; });
  loadApp(query);
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', (_event, argv) => {
    openAuthCallback(argv.find(arg => arg.toLowerCase().startsWith(`${scheme}://`)));
    if (mainWindow) { mainWindow.show(); mainWindow.focus(); }
  });
  app.on('open-url', (event, url) => {
    event.preventDefault();
    openAuthCallback(url);
  });

  app.setAsDefaultProtocolClient(scheme);
  app.whenReady().then(() => {
    const preferences = readPreferences();
    if (process.platform === 'win32') app.setLoginItemSettings({ openAtLogin: preferences.launchAtStartup });
    protocol.handle(contentScheme, request => {
      const { host, pathname } = new URL(request.url);
      if (host !== 'desktop') return new Response('Not found', { status: 404 });
      const assetPath = pathname === '/' || pathname === '/index.html' ? indexPath
        : pathname === '/supabase-client.js' ? path.join(app.getAppPath(), 'supabase-client.js')
        : pathname === '/yurei.png' ? path.join(app.getAppPath(), 'yurei.png')
        : null;
      if (!assetPath) return new Response('Not found', { status: 404 });
      return net.fetch(pathToFileURL(assetPath).toString());
    });
    const initialLink = process.argv.find(arg => arg.toLowerCase().startsWith(`${scheme}://`));
    const query = parseAuthCallback(initialLink) || {};
    createWindow(query);
    app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
    if (updateEnforcementEnabled) {
      autoUpdater.autoDownload = true;
      autoUpdater.autoInstallOnAppQuit = true;
      autoUpdater.on('checking-for-update', () => publishUpdateStatus('checking'));
      autoUpdater.on('update-available', info => publishUpdateStatus('available', { version: info.version }));
      autoUpdater.on('update-not-available', info => publishUpdateStatus('current', { version: info.version }));
      autoUpdater.on('download-progress', progress => publishUpdateStatus('downloading', { percent: Math.round(progress.percent) }));
      autoUpdater.on('update-downloaded', info => publishUpdateStatus('downloaded', { version: info.version }));
      autoUpdater.on('error', error => publishUpdateStatus('error', { message: error.message }));
      setTimeout(() => autoUpdater.checkForUpdates().catch(error => publishUpdateStatus('error', { message: error.message })), 1000);
    }
  });

  ipcMain.handle('app:version', () => app.getVersion());
  ipcMain.handle('app:update-status', () => updateStatus);
  ipcMain.handle('app:check-update', async () => {
    if (!app.isPackaged || process.platform !== 'win32') {
      publishUpdateStatus('unavailable', { message: 'La recherche est disponible dans la version installée.' });
      return updateStatus;
    }
    try {
      await autoUpdater.checkForUpdates();
      return updateStatus;
    } catch (error) {
      publishUpdateStatus('error', { message: error.message });
      return updateStatus;
    }
  });
  ipcMain.handle('app:install-update', () => {
    if (updateStatus.state === 'downloaded') autoUpdater.quitAndInstall();
  });
  ipcMain.handle('app:preferences:get', () => readPreferences());
  ipcMain.handle('app:preferences:set', (_event, patch) => {
    if (!patch || typeof patch !== 'object') throw new Error('Préférences invalides');
    const allowed = {};
    if (typeof patch.launchAtStartup === 'boolean') allowed.launchAtStartup = patch.launchAtStartup;
    if (typeof patch.notifications === 'boolean') allowed.notifications = patch.notifications;
    return writePreferences(allowed);
  });
  ipcMain.handle('app:notify', (_event, payload) => {
    if (!readPreferences().notifications || !Notification.isSupported()) return false;
    const title = String(payload?.title || 'Yurei').slice(0, 80);
    const body = String(payload?.body || '').slice(0, 220);
    new Notification({ title, body, icon: path.join(app.getAppPath(), 'yurei.ico') }).show();
    return true;
  });

  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
}

