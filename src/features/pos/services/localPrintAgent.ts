import type { KitchenSendItem } from '../types';
import { supabase } from '@/api';
import type { ReceiptData } from '../utils/printing';
import { buildReceiptHtml } from '../utils/printing';
import type { Settings, Language } from '@/lib/types';

export const PRINT_AGENT_URL = 'http://127.0.0.1:17654';
const PRINT_TIMEOUT_MS = 2500;
const STORAGE_ROUTING_KEY = 'johns_pos_printer_routes';
const STORAGE_SERVER_KEY = 'johns_pos_is_branch_print_server';
const STORAGE_DRAWER_KICK_KEY = 'johns_pos_auto_drawer_kick';
const STORAGE_SILENT_PRINT_KEY = 'johns_pos_silent_print_enabled';
const STORAGE_SINGLE_PRINT_POLICY_KEY = 'johns_pos_single_print_policy_enabled';

export function isSilentPrintEnabled(): boolean {
  if (typeof window === 'undefined') return true;
  const val = localStorage.getItem(STORAGE_SILENT_PRINT_KEY);
  return val !== 'false'; // default to true: fast silent printing without asking cashier
}

export function setSilentPrintEnabled(enabled: boolean): void {
  if (typeof window === 'undefined') return;
  localStorage.setItem(STORAGE_SILENT_PRINT_KEY, enabled ? 'true' : 'false');
}

export function isSinglePrintPolicyEnabled(): boolean {
  if (typeof window === 'undefined') return true;
  const val = localStorage.getItem(STORAGE_SINGLE_PRINT_POLICY_KEY);
  return val !== 'false'; // default to true: print once only, reprints require manager approval
}

export function setSinglePrintPolicyEnabled(enabled: boolean): void {
  if (typeof window === 'undefined') return;
  localStorage.setItem(STORAGE_SINGLE_PRINT_POLICY_KEY, enabled ? 'true' : 'false');
}

declare global {
  interface Window {
    electronAPI?: {
      isElectron: boolean;
      getPrinters: () => Promise<Array<{ name: string; displayName?: string; isDefault: boolean; status?: number }>>;
      printSilent: (options: { html?: string; text?: string; printerName: string; copies?: number }) => Promise<{ success: boolean; error?: string }>;
      kickDrawer: (printerName?: string) => Promise<{ success: boolean; error?: string }>;
      getSystemInfo: () => Promise<{ isElectron: boolean; platform: string; hostname: string }>;
    };
  }
}

export interface PrinterRouteConfig {
  [stationCode: string]: string; // e.g. 'cashier': 'XP-80C', 'main': 'Kitchen-POS', 'drinks': 'Bar-Printer'
}

export interface LocalKitchenPrintContext {
  orderNumber?: string | null;
  tableName?: string | null;
  orderType?: string | null;
  guestCount?: number | null;
  branchId?: string | null;
  isAr: boolean;
}

export interface DetectedPrinter {
  name: string;
  displayName?: string;
  isDefault?: boolean;
}

export type HardwareEnvironment = 'electron' | 'local_agent' | 'mobile_cloud' | 'browser';

function safeText(value: unknown): string {
  return Array.from(String(value ?? ''))
    .filter((ch) => ch === '\n' || ch === '\r' || ch === '\t' || ch >= ' ')
    .join('')
    .trim();
}

function modifierNames(item: KitchenSendItem): string[] {
  return (item.modifiers || [])
    .map((m) => safeText(m.option_name || m.option_name_en))
    .filter(Boolean);
}

// ----------------------------------------------------------------------------
// Local Storage & Configuration Helpers
// ----------------------------------------------------------------------------

export function getLocalPrinterRoutes(): PrinterRouteConfig {
  if (typeof window === 'undefined') return {};
  try {
    const raw = localStorage.getItem(STORAGE_ROUTING_KEY);
    return raw ? (JSON.parse(raw) as PrinterRouteConfig) : {};
  } catch {
    return {};
  }
}

export function saveLocalPrinterRoutes(routes: PrinterRouteConfig): void {
  if (typeof window === 'undefined') return;
  try {
    localStorage.setItem(STORAGE_ROUTING_KEY, JSON.stringify(routes));
  } catch (err) {
    console.error('Failed to save printer routes to localStorage:', err);
  }
}

export function isBranchPrintServer(): boolean {
  if (typeof window === 'undefined') return false;
  return localStorage.getItem(STORAGE_SERVER_KEY) === 'true';
}

export function setBranchPrintServer(enabled: boolean): void {
  if (typeof window === 'undefined') return;
  localStorage.setItem(STORAGE_SERVER_KEY, enabled ? 'true' : 'false');
}

export function isAutoDrawerKickEnabled(): boolean {
  if (typeof window === 'undefined') return true;
  const val = localStorage.getItem(STORAGE_DRAWER_KICK_KEY);
  return val !== 'false'; // default to true
}

export function setAutoDrawerKick(enabled: boolean): void {
  if (typeof window === 'undefined') return;
  localStorage.setItem(STORAGE_DRAWER_KICK_KEY, enabled ? 'true' : 'false');
}

// ----------------------------------------------------------------------------
// Environment Detection
// ----------------------------------------------------------------------------

export function isRunningInElectron(): boolean {
  return typeof window !== 'undefined' && Boolean(window.electronAPI?.isElectron);
}

export async function detectHardwareEnvironment(): Promise<HardwareEnvironment> {
  if (isRunningInElectron()) return 'electron';

  try {
    const res = await fetchWithTimeout(`${PRINT_AGENT_URL}/health`);
    if (res.ok) return 'local_agent';
  } catch {
    // local agent not reachable
  }

  // Check if mobile or normal browser
  const ua = typeof navigator !== 'undefined' ? navigator.userAgent : '';
  const isMobile = /Android|iPhone|iPad|iPod|Mobile/i.test(ua);
  return isMobile ? 'mobile_cloud' : 'browser';
}

// ----------------------------------------------------------------------------
// Printer Discovery
// ----------------------------------------------------------------------------

export async function getAvailablePrinters(): Promise<DetectedPrinter[]> {
  // 1. Check Electron native bridge
  if (isRunningInElectron() && window.electronAPI) {
    try {
      const printers = await window.electronAPI.getPrinters();
      if (Array.isArray(printers) && printers.length > 0) {
        return printers.map((p) => ({
          name: p.name,
          displayName: p.displayName || p.name,
          isDefault: p.isDefault,
        }));
      }
    } catch (err) {
      console.warn('Failed to get printers from Electron:', err);
    }
  }

  // 2. Check Local Windows Agent (port 17654)
  try {
    const res = await fetchWithTimeout(`${PRINT_AGENT_URL}/printers`);
    if (res.ok) {
      const data = await res.json() as { printers?: string[] };
      if (Array.isArray(data.printers)) {
        return data.printers.map((name, idx) => ({
          name,
          displayName: name,
          isDefault: idx === 0,
        }));
      }
    }
  } catch {
    // agent not reachable
  }

  return [];
}

// ----------------------------------------------------------------------------
// Low-Level Silent Print Executers
// ----------------------------------------------------------------------------

export async function executeSilentPrint(options: {
  printerName: string;
  text?: string;
  html?: string;
  copies?: number;
}): Promise<boolean> {
  const { printerName, text, html, copies = 1 } = options;
  if (!printerName) return false;

  // 1. If inside Electron
  if (isRunningInElectron() && window.electronAPI) {
    try {
      const res = await window.electronAPI.printSilent({
        printerName,
        text,
        html,
        copies,
      });
      return Boolean(res.success);
    } catch (err) {
      console.error('Electron silent print failed:', err);
      return false;
    }
  }

  // 2. If via Local Agent HTTP
  try {
    const endpoint = html ? `${PRINT_AGENT_URL}/print-receipt` : `${PRINT_AGENT_URL}/print`;
    const body = html
      ? { printer: printerName, text: html }
      : { printer: printerName, text: text || '', station: 'custom' };

    const res = await fetchWithTimeout(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (res.ok) {
      const json = await res.json() as { success?: boolean };
      return Boolean(json.success);
    }
  } catch (err) {
    console.error('Local Agent print failed:', err);
  }

  return false;
}

export async function executeCashDrawerKick(printerName?: string): Promise<boolean> {
  const routes = getLocalPrinterRoutes();
  const targetPrinter = printerName || routes.cashier || routes.receipt || routes.main;

  if (isRunningInElectron() && window.electronAPI && targetPrinter) {
    try {
      const res = await window.electronAPI.kickDrawer(targetPrinter);
      return Boolean(res.success);
    } catch {
      return false;
    }
  }

  try {
    const res = await fetchWithTimeout(`${PRINT_AGENT_URL}/drawer`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ printer: targetPrinter }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

// ----------------------------------------------------------------------------
// Station Ticket Builder
// ----------------------------------------------------------------------------

export function groupKitchenItemsByStation(items: KitchenSendItem[]): Record<string, KitchenSendItem[]> {
  const groups: Record<string, KitchenSendItem[]> = {};
  for (const item of items) {
    const station = safeText(item.station_code) || 'main';
    (groups[station] ||= []).push(item);
  }
  return groups;
}

export function buildStationTicketText(
  station: string,
  items: KitchenSendItem[],
  ctx: LocalKitchenPrintContext,
): string {
  const lines: string[] = [];
  const ar = ctx.isAr;
  lines.push('================================');
  lines.push(ar ? `محطة: ${station.toUpperCase()}` : `Station: ${station.toUpperCase()}`);
  if (ctx.orderNumber) lines.push(`${ar ? 'طلب' : 'Order'}: ${safeText(ctx.orderNumber)}`);
  if (ctx.tableName) lines.push(`${ar ? 'طاولة' : 'Table'}: ${safeText(ctx.tableName)}`);
  if (ctx.orderType) lines.push(`${ar ? 'النوع' : 'Type'}: ${safeText(ctx.orderType)}`);
  if (ctx.guestCount) lines.push(`${ar ? 'ضيوف' : 'Guests'}: ${ctx.guestCount}`);
  lines.push(new Date().toLocaleString(ar ? 'ar-EG' : 'en-US'));
  lines.push('--------------------------------');

  for (const item of items) {
    const qty = Number(item.quantity || 0);
    lines.push(`${qty} x ${safeText(item.product_name || '—')}`);
    for (const modifier of modifierNames(item)) lines.push(`  + ${modifier}`);
    if (item.notes?.trim()) lines.push(`  * ${safeText(item.notes)}`);
    lines.push('');
  }

  lines.push('================================');
  lines.push('\r\n\r\n');
  return lines.join('\r\n');
}

async function fetchWithTimeout(input: string, init?: RequestInit): Promise<Response> {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), PRINT_TIMEOUT_MS);
  try {
    return await fetch(input, { ...init, signal: controller.signal, cache: 'no-store' });
  } finally {
    window.clearTimeout(timer);
  }
}

// ----------------------------------------------------------------------------
// Cloud Print Queue (Phone -> Windows Terminal)
// ----------------------------------------------------------------------------

export async function enqueuePrintJob(params: {
  branchId: string;
  jobType: 'kitchen_ticket' | 'receipt' | 'drawer_kick';
  stationCode?: string;
  ticketText?: string;
  ticketHtml?: string;
  title?: string;
  orderId?: string | null;
  saleId?: string | null;
  metadata?: Record<string, unknown>;
}): Promise<string | null> {
  try {
    const { data, error } = await supabase
      .from('print_jobs')
      .insert({
        branch_id: params.branchId,
        job_type: params.jobType,
        station_code: params.stationCode || 'main',
        ticket_text: params.ticketText || null,
        ticket_html: params.ticketHtml || null,
        title: params.title || null,
        order_id: params.orderId || null,
        sale_id: params.saleId || null,
        metadata: params.metadata || {},
        status: 'pending',
      })
      .select('id')
      .single();

    if (error) {
      console.warn('Failed to enqueue print job:', error.message);
      return null;
    }
    return data?.id || null;
  } catch (err) {
    console.warn('Enqueue print job exception:', err);
    return null;
  }
}

// ----------------------------------------------------------------------------
// Realtime Print Queue Listener for Windows Central Station
// ----------------------------------------------------------------------------

let activePrintSubscription: ReturnType<typeof supabase.channel> | null = null;

export function startBranchPrintQueueListener(
  branchId: string,
  onStatusChange?: (job: { id: string; title: string; station: string; status: string }) => void,
): () => void {
  if (!branchId || typeof window === 'undefined') return () => {};

  if (activePrintSubscription) {
    supabase.removeChannel(activePrintSubscription);
    activePrintSubscription = null;
  }

  const channelName = `print_jobs_${branchId}_${Date.now()}`;
  const channel = supabase
    .channel(channelName)
    .on(
      'postgres_changes',
      {
        event: 'INSERT',
        schema: 'public',
        table: 'print_jobs',
        filter: `branch_id=eq.${branchId}`,
      },
      async (payload) => {
        const job = payload.new as {
          id: string;
          job_type: string;
          station_code: string;
          ticket_text?: string;
          ticket_html?: string;
          title?: string;
          status: string;
        };

        if (job.status !== 'pending') return;

        console.log('[PrintQueue] New print job received from branch mobile:', job);
        onStatusChange?.({
          id: job.id,
          title: job.title || job.job_type,
          station: job.station_code,
          status: 'printing',
        });

        // Determine target printer based on station
        const routes = getLocalPrinterRoutes();
        const printer = routes[job.station_code] || routes.main || routes.cashier;

        let success = false;
        try {
          if (job.job_type === 'drawer_kick') {
            success = await executeCashDrawerKick(printer);
          } else if (printer) {
            success = await executeSilentPrint({
              printerName: printer,
              text: job.ticket_text,
              html: job.ticket_html,
            });
          }

          // If successful or fallback, update job in DB
          await supabase
            .from('print_jobs')
            .update({
              status: success ? 'completed' : 'failed',
              printed_at: new Date().toISOString(),
              target_printer: printer || 'unassigned',
            })
            .eq('id', job.id);

          onStatusChange?.({
            id: job.id,
            title: job.title || job.job_type,
            station: job.station_code,
            status: success ? 'completed' : 'failed',
          });
        } catch (err) {
          console.error('[PrintQueue] Error printing job:', err);
          await supabase
            .from('print_jobs')
            .update({
              status: 'failed',
              error_message: err instanceof Error ? err.message : 'Unknown print error',
            })
            .eq('id', job.id);
        }
      }
    )
    .subscribe();

  activePrintSubscription = channel;

  return () => {
    if (activePrintSubscription) {
      supabase.removeChannel(activePrintSubscription);
      activePrintSubscription = null;
    }
  };
}

// ----------------------------------------------------------------------------
// High-Level Orchestration Functions
// ----------------------------------------------------------------------------

/**
 * Print kitchen stations.
 * If running on Desktop with local printer -> prints immediately and silently.
 * If running on Mobile or terminal without local printers -> enqueues to Cloud Print Queue for the branch!
 */
export async function printKitchenStationsLocally(
  items: KitchenSendItem[],
  ctx: LocalKitchenPrintContext,
): Promise<boolean> {
  if (typeof window === 'undefined' || items.length === 0) return false;

  const groups = groupKitchenItemsByStation(items);
  const stations = Object.keys(groups);
  if (stations.length === 0) return false;

  const env = await detectHardwareEnvironment();
  const routes = getLocalPrinterRoutes();

  // If we are on Windows Desktop (Electron or Local Agent) and have configured printers
  if ((env === 'electron' || env === 'local_agent') && Object.keys(routes).length > 0) {
    let allSucceeded = true;

    for (const [station, stationItems] of Object.entries(groups)) {
      const printer = routes[station] || routes.main;
      if (!printer) {
        allSucceeded = false;
        continue;
      }

      const text = buildStationTicketText(station, stationItems, ctx);
      const printed = await executeSilentPrint({ printerName: printer, text });
      if (!printed) allSucceeded = false;
    }

    if (allSucceeded) {
      suppressNextKitchenBrowserPopup();
      return true;
    }
  }

  // If on Mobile or no local printer configured on this device -> Enqueue to Cloud Queue for Windows terminal!
  if (ctx.branchId) {
    try {
      for (const [station, stationItems] of Object.entries(groups)) {
        const text = buildStationTicketText(station, stationItems, ctx);
        await enqueuePrintJob({
          branchId: ctx.branchId,
          jobType: 'kitchen_ticket',
          stationCode: station,
          title: `${ctx.isAr ? 'تذكرة مطبخ' : 'Kitchen Ticket'} - #${ctx.orderNumber || ''}`,
          ticketText: text,
          orderId: null,
          metadata: {
            table: ctx.tableName,
            orderNumber: ctx.orderNumber,
            itemsCount: stationItems.length,
          },
        });
      }
      // Since it was enqueued for the Windows terminal to print silently, suppress browser popup!
      suppressNextKitchenBrowserPopup();
      return true;
    } catch (err) {
      console.warn('Failed to enqueue kitchen tickets to cloud queue:', err);
    }
  }

  return false;
}

export function printSilentlyViaIframe(html: string): Promise<boolean> {
  return new Promise((resolve) => {
    if (typeof window === 'undefined') {
      resolve(false);
      return;
    }
    try {
      const oldIframe = document.getElementById('silent-print-iframe');
      if (oldIframe) {
        oldIframe.remove();
      }

      const iframe = document.createElement('iframe');
      iframe.id = 'silent-print-iframe';
      iframe.style.position = 'fixed';
      iframe.style.right = '0';
      iframe.style.bottom = '0';
      iframe.style.width = '0';
      iframe.style.height = '0';
      iframe.style.border = '0';
      iframe.style.opacity = '0';
      iframe.style.pointerEvents = 'none';
      document.body.appendChild(iframe);

      const doc = iframe.contentWindow?.document;
      if (!doc) {
        iframe.remove();
        resolve(false);
        return;
      }

      doc.open();
      doc.write(html);
      doc.close();

      setTimeout(() => {
        try {
          iframe.contentWindow?.focus();
          iframe.contentWindow?.print();
          resolve(true);
        } catch (e) {
          console.warn('Silent iframe print warning:', e);
          resolve(false);
        } finally {
          setTimeout(() => {
            try {
              iframe.remove();
            } catch {
              // ignore
            }
          }, 4000);
        }
      }, 250);
    } catch (err) {
      console.warn('Failed to print silently via iframe:', err);
      resolve(false);
    }
  });
}

/**
 * Print receipt.
 * If local Cashier printer is configured -> prints silently and kicks drawer!
 * If on Mobile -> enqueues to Cloud Queue for the Windows terminal!
 * If in Browser -> prints via fast invisible iframe without opening disruptive popups!
 */
export async function printReceiptLocally(
  receipt: ReceiptData,
  settings: Settings,
  lang: Language,
  isAr: boolean,
  branchId?: string,
): Promise<boolean> {
  const env = await detectHardwareEnvironment();
  const routes = getLocalPrinterRoutes();
  const cashierPrinter = routes.cashier || routes.receipt || routes.main;

  let html = '';
  try {
    html = await buildReceiptHtml(receipt, settings, lang, isAr);
  } catch (err) {
    console.error('Receipt authorization / build error:', err);
    throw err;
  }

  // 1. If on Desktop with Cashier printer (Electron or Local Windows Agent)
  if ((env === 'electron' || env === 'local_agent') && cashierPrinter) {
    const success = await executeSilentPrint({
      printerName: cashierPrinter,
      html,
      copies: settings.receipt_copies || 1,
    });

    if (success && isAutoDrawerKickEnabled()) {
      void executeCashDrawerKick(cashierPrinter);
    }
    return success;
  }

  // 2. If on Mobile or remote device -> Enqueue to Cloud Queue for central terminal
  if (branchId && env === 'mobile_cloud') {
    const jobId = await enqueuePrintJob({
      branchId,
      jobType: 'receipt',
      stationCode: 'cashier',
      title: `${isAr ? 'فاتورة حساب' : 'Receipt'} - ${receipt.invoice}`,
      ticketHtml: html,
      ticketText: `${receipt.branchName || ''}\n${receipt.invoice}\nTotal: ${receipt.total}`,
      metadata: {
        invoice: receipt.invoice,
        total: receipt.total,
      },
    });

    if (jobId && isAutoDrawerKickEnabled()) {
      void enqueuePrintJob({
        branchId,
        jobType: 'drawer_kick',
        stationCode: 'cashier',
        title: `Kick Drawer - ${receipt.invoice}`,
      });
    }

    return Boolean(jobId);
  }

  // 3. Fast Silent Browser Printing (using invisible iframe directly)
  if (isSilentPrintEnabled()) {
    const iframePrinted = await printSilentlyViaIframe(html);
    return iframePrinted;
  }

  return false;
}

export function suppressNextKitchenBrowserPopup(): void {
  if (typeof window === 'undefined') return;
  const original = window.open;
  let restored = false;
  const restore = () => {
    if (restored) return;
    restored = true;
    window.open = original;
  };
  window.open = (() => {
    restore();
    return null;
  }) as typeof window.open;
  window.setTimeout(restore, 1500);
}
