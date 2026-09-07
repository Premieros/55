const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execFile } = require('child_process');

const DEFAULT_URL = process.env.POS_APP_URL || 'https://premieros.github.io/55/';

let mainWindow = null;
let printWorkerWindow = null;

function createPrintWorker() {
  if (printWorkerWindow && !printWorkerWindow.isDestroyed()) return printWorkerWindow;
  printWorkerWindow = new BrowserWindow({
    show: false,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
    },
  });
  return printWorkerWindow;
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 1024,
    minHeight: 700,
    title: 'Premier POS',
    autoHideMenuBar: true,
    fullscreen: true,
    backgroundColor: '#0f172a',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: false,
      webSecurity: true,
    },
  });

  mainWindow.setMenuBarVisibility(false);
  createPrintWorker();

  const targetUrl = process.env.ELECTRON_START_URL || DEFAULT_URL;
  mainWindow.loadURL(targetUrl).catch((error) => {
    console.error('[Premier POS Desktop] Failed to load remote app:', error);
    const localIndex = path.join(__dirname, '..', 'dist', 'index.html');
    if (fs.existsSync(localIndex)) {
      void mainWindow.loadFile(localIndex);
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
    if (printWorkerWindow && !printWorkerWindow.isDestroyed()) {
      printWorkerWindow.destroy();
    }
    printWorkerWindow = null;
  });
}

ipcMain.handle('pos:get-printers', async () => {
  try {
    if (!mainWindow) return [];
    const printers = await mainWindow.webContents.getPrintersAsync();
    return printers.map((printer) => ({
      name: printer.name,
      displayName: printer.displayName || printer.name,
      description: printer.description || '',
      status: printer.status,
      isDefault: printer.isDefault,
    }));
  } catch (error) {
    console.error('[Premier POS Desktop] Printer discovery failed:', error);
    return [];
  }
});

ipcMain.handle('pos:print-silent', async (_event, options = {}) => {
  const { html, text, printerName, copies = 1 } = options;
  try {
    if (!printerName) throw new Error('PRINTER_NAME_REQUIRED');

    if (html) {
      const worker = createPrintWorker();
      await worker.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(html)}`);
      return await new Promise((resolve) => {
        worker.webContents.print(
          {
            silent: true,
            printBackground: true,
            deviceName: printerName,
            copies: Math.max(1, Math.min(5, Number(copies) || 1)),
            margins: { marginType: 'none' },
          },
          (success, failureReason) => resolve(
            success
              ? { success: true, printerName }
              : { success: false, error: failureReason || 'PRINT_FAILED' },
          ),
        );
      });
    }

    if (text) {
      const tempFile = path.join(os.tmpdir(), `premier-pos-${Date.now()}.txt`);
      fs.writeFileSync(tempFile, String(text), 'utf8');
      return await new Promise((resolve) => {
        const script = '$p=$args[0];$f=$args[1];Get-Content -LiteralPath $f -Raw -Encoding UTF8 | Out-Printer -Name $p';
        execFile(
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script, printerName, tempFile],
          { windowsHide: true },
          (error, _stdout, stderr) => {
            try { fs.unlinkSync(tempFile); } catch {}
            resolve(error
              ? { success: false, error: (stderr || error.message || '').trim() }
              : { success: true, printerName });
          },
        );
      });
    }

    throw new Error('NO_CONTENT_TO_PRINT');
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : 'PRINT_ERROR' };
  }
});

ipcMain.handle('pos:kick-drawer', async (_event, printerName) => {
  if (!printerName) return { success: false, error: 'PRINTER_NAME_REQUIRED' };

  const tempFile = path.join(os.tmpdir(), `premier-drawer-${Date.now()}.bin`);
  fs.writeFileSync(tempFile, Buffer.from([0x1b, 0x70, 0x00, 0x19, 0xfa]));

  return await new Promise((resolve) => {
    const script = '$p=$args[0];$f=$args[1];Get-Content -LiteralPath $f -Encoding Byte -Raw | Out-Printer -Name $p';
    execFile(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script, printerName, tempFile],
      { windowsHide: true },
      (error, _stdout, stderr) => {
        try { fs.unlinkSync(tempFile); } catch {}
        resolve(error
          ? { success: false, error: (stderr || error.message || '').trim() }
          : { success: true, printerName });
      },
    );
  });
});

ipcMain.handle('pos:get-system-info', async () => ({
  isElectron: true,
  platform: process.platform,
  hostname: os.hostname(),
  arch: process.arch,
  version: app.getVersion(),
}));

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
