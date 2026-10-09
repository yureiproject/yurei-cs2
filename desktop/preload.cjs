const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('yureiDesktop', {
  getVersion: () => ipcRenderer.invoke('app:version'),
  getUpdateStatus: () => ipcRenderer.invoke('app:update-status'),
  checkForUpdates: () => ipcRenderer.invoke('app:check-update'),
  installUpdate: () => ipcRenderer.invoke('app:install-update'),
  authRedirectUrl: () => 'yurei://auth/callback',
  passwordRecoveryUrl: () => 'yurei://reset-password',
  onUpdateStatus: callback => {
    const listener = (_event, status) => callback(status);
    ipcRenderer.on('app:update-status', listener);
    return () => ipcRenderer.removeListener('app:update-status', listener);
  },
});
