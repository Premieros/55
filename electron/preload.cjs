// ============================================================================
// Johns POS - Preload Script
// Exposes secure hardware bridge to the web application window
// ============================================================================

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  isElectron: true,
  getPrinters: () => ipcRenderer.invoke('pos:get-printers'),
  printSilent: (options) => ipcRenderer.invoke('pos:print-silent', options),
  kickDrawer: (printerName) => ipcRenderer.invoke('pos:kick-drawer', printerName),
  getSystemInfo: () => ipcRenderer.invoke('pos:get-system-info'),
});
