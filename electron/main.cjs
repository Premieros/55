// ============================================================================
// Johns POS - Windows Desktop (Electron Main Process)
// Provides:
//  1. Clean Frameless/App Window (No URL bar or browser chrome visible)
//  2. Direct Access to Local Windows Printers (USB, Network, Bluetooth)
//  3. Silent Printing (Print tickets & receipts without any user prompt)
//  4. Cash Drawer Kick Automation
// ============================================================================

const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execFile } = require('child_process');

// Default Cloud URL (can be overridden via environment variable or config file)
const DEFAULT_URL = process.env.POS_APP_URL || 'https://ais-pre-utf35dfbelzmbfjp7etxwq-287327909955.europe-west1.run.app';

let mainWindow = null;
let printWorkerWindow = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 1024,
    minHeight: 700,
    title: 'Johns POS',
    autoHideMenuBar: true,
    backgroundColor: '#0f172a',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: false,
      webSecurity: true,
    },
  });

  // Remove default menu to ensure no browser controls exist
  mainWindow.setMenuBarVisibility(false);

  // Hidden worker window for silent offscreen printing
  printWorkerWindow = new BrowserWindow({
    show: false,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  const targetUrl = process.env.ELECTRON_START_URL || DEFAULT_URL;
  console.log(`[Johns POS Desktop] Loading URL: ${targetUrl}`);

  mainWindow.loadURL(targetUrl).catch((err) => {
    console.error('[Johns POS Desktop] Failed to load URL:', err);
    // If offline, attempt to load local dist if available
    const localIndex = path.join(__dirname, '..', 'dist', 'index.html');
    if (fs.existsSync(localIndex)) {
      mainWindow.loadFile(localIndex);
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
    if (printWorkerWindow) {
      printWorkerWindow.destroy();
      printWorkerWindow = null;
    }
  });
}

// ----------------------------------------------------------------------------
// IPC Handlers for Local Hardware
// ----------------------------------------------------------------------------

// 1. Get list of all installed printers
ipcMain.handle('pos:get-printers', async () => {
  try {
    if (!mainWindow) return [];
    const printers = await mainWindow.webContents.getPrintersAsync();
    return printers.map((p) => ({
      name: p.name,
      displayName: p.displayName || p.name,
      description: p.description || '',
      status: p.status,
      isDefault: p.isDefault,
    }));
  } catch (err) {
    console.error('[Printer] Error fetching printers:', err);
    return [];
  }
});

// 2. Silent Print HTML or Text to a specific printer
ipcMain.handle('pos:print-silent', async (_event, options) => {
  const { html, text, printerName, copies = 1, pageSize = '80mm' } = options;
  try {
    if (!printerName) {
      throw new Error('PRINTER_NAME_REQUIRED');
    }

    if (html) {
      // Use the offscreen print worker window for clean silent HTML printing
      if (!printWorkerWindow) {
        printWorkerWindow = new BrowserWindow({ show: false });
      }

      await printWorkerWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(html)}`);

      return new Promise((resolve) => {
        printWorkerWindow.webContents.print(
          {
            silent: true,
            printBackground: true,
            deviceName: printerName,
            copies: Math.max(1, Math.min(5, copies)),
            margins: { marginType: 'none' },
          },
          (success, failureReason) => {
            if (success) {
              resolve({ success: true, printerName });
            } else {
              resolve({ success: false, error: failureReason || 'PRINT_FAILED' });
            }
          }
        );
      });
    }

    if (text) {
      // Text fallback using PowerShell Out-Printer for high compatibility
      const tmp = path.join(os.tmpdir(), `ticket-${Date.now()}-${Math.random().toString(16).slice(2)}.txt`);
      fs.writeFileSync(tmp, text, 'utf8');

      return new Promise((resolve) => {
        const script = "$p=$args[0];$f=$args[1];Get-Content -LiteralPath $f -Raw -Encoding UTF8 | Out-Printer -Name $p";
        execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script, printerName, tmp], { windowsHide: true }, (err, _stdout, stderr) => {
          try { fs.unlinkSync(tmp); } catch {}
          if (err) {
            resolve({ success: false, error: (stderr || err.message || '').trim() });
          } else {
            resolve({ success: true, printerName });
          }
        });
      });
    }

    throw new Error('NO_CONTENT_TO_PRINT');
  } catch (err) {
    return { success: false, error: err instanceof Error ? err.message : 'PRINT_ERROR' };
  }
});

// 3. Kick Cash Drawer pulse via printer
ipcMain.handle('pos:kick-drawer', async (_event, printerName) => {
  try {
    if (!printerName) throw new Error('PRINTER_NAME_REQUIRED');
    const tmp = path.join(os.tmpdir(), `drawer-${Date.now()}.bin`);
    // Standard ESC/POS kick pulse
    const kickBytes = Buffer.from([0x1B, 0x70, 0x00, 0x19, 0xFA]);
    fs.writeFileSync(tmp, kickBytes);

    return new Promise((resolve) => {
      const script = "$p=$args[0];$f=$args[1];Get-Content -LiteralPath $f -Encoding Byte -Raw | Out-Printer -Name $p";
      execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script, printerName, tmp], { windowsHide: true }, (err, _stdout, stderr) => {
        try { fs.unlinkSync(tmp); } catch {}
        if (err) {
          resolve({ success: false, error: (stderr || err.message || '').trim() });
        } else {
          resolve({ success: true });
        }
      });
    });
  } catch (err) {
    return { success: false, error: err instanceof Error ? err.message : 'DRAWER_ERROR' };
  }
});

// 4. App Platform Information
ipcMain.handle('pos:get-system-info', async () => {
  return {
    isElectron: true,
    platform: process.platform,
    hostname: os.hostname(),
    arch: process.arch,
    version: app.getVersion(),
  };
});

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
