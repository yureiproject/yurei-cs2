const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('yureiDesktop', {
  getVersion: () => ipcRenderer.invoke('app:version'),
  getUpdateStatus: () => ipcRenderer.invoke('app:update-status'),
  checkForUpdates: () => ipcRenderer.invoke('app:check-update'),
  installUpdate: () => ipcRenderer.invoke('app:install-update'),
  getPreferences: () => ipcRenderer.invoke('app:preferences:get'),
  setPreferences: patch => ipcRenderer.invoke('app:preferences:set', patch),
  notify: payload => ipcRenderer.invoke('app:notify', payload),
  authRedirectUrl: () => 'yurei://auth/callback',
  passwordRecoveryUrl: () => 'yurei://reset-password',
  onUpdateStatus: callback => {
    const listener = (_event, status) => callback(status);
    ipcRenderer.on('app:update-status', listener);
    return () => ipcRenderer.removeListener('app:update-status', listener);
  },
});
