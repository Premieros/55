import { type ReactNode } from 'react';

export interface Column<T> {
  key: string;
  header: string;
  render?: (row: T) => ReactNode;
  className?: string;
}

interface DataTableProps<T> {
  columns: Column<T>[];
  data: T[];
  loading?: boolean;
  error?: ReactNode | null;
  emptyMessage?: string;
  onRowClick?: (row: T) => void;
  selectedIds?: Set<string>;
  onSelectionChange?: (ids: Set<string>) => void;
  showCheckbox?: boolean;
}

export function DataTable<T extends { id?: string }>({ columns, data, loading, error, emptyMessage, onRowClick, selectedIds, onSelectionChange, showCheckbox }: DataTableProps<T>) {
  if (loading) {
    return (
      <div data-testid="table-loading" className="flex items-center justify-center py-16">
        <div className="flex flex-col items-center gap-3">
          <div className="animate-spin rounded-full h-8 w-8 border-3 border-ui-primary border-t-transparent" />
          <p className="text-sm text-ui-subtle">Loading...</p>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div data-testid="table-error" className="flex flex-col items-center justify-center py-16 text-ui-muted">
        <div className="w-16 h-16 rounded-full bg-ui-danger-soft flex items-center justify-center mb-3">
          <svg className="w-8 h-8 text-ui-danger" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M12 9v4m0 4h.01M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z" />
          </svg>
        </div>
        <p className="text-sm font-medium text-ui-text">{error}</p>
      </div>
    );
  }

  if (data.length === 0) {
    return (
      <div data-testid="table-empty" className="flex flex-col items-center justify-center py-16 text-ui-muted">
        <div className="w-16 h-16 rounded-full bg-ui-page-alt flex items-center justify-center mb-3">
          <svg className="w-8 h-8 text-ui-subtle" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-3.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 006.586 13H4" /></svg>
        </div>
        <p className="text-sm font-medium text-ui-text">{emptyMessage || 'No data'}</p>
      </div>
    );
  }

  const allSelected = showCheckbox && selectedIds && data.length > 0 && data.every((r) => r.id && selectedIds.has(r.id));

  const toggleAll = () => {
    if (!onSelectionChange || !selectedIds) return;
    if (allSelected) {
      onSelectionChange(new Set());
    } else {
      onSelectionChange(new Set(data.map((r) => r.id!).filter(Boolean)));
    }
  };

  const toggleRow = (id: string) => {
    if (!onSelectionChange || !selectedIds) return;
    const next = new Set(selectedIds);
    if (next.has(id)) next.delete(id); else next.add(id);
    onSelectionChange(next);
  };

  const renderCell = (row: T, col: Column<T>) =>
    col.render ? col.render(row) : (row as Record<string, unknown>)[col.key] as ReactNode;

  return (
    <div data-testid="data-table" className="min-w-0 max-w-full">
      <div className="space-y-3 sm:hidden">
        {showCheckbox && (
          <div className="flex items-center rounded-xl border border-ui-border bg-ui-surface px-3 py-2 shadow-ui-sm">
            <input
              type="checkbox"
              aria-label="Select all rows"
              checked={!!allSelected}
              onChange={toggleAll}
              className="h-5 w-5 rounded border-ui-border-strong text-ui-primary focus:ring-ui-ring"
            />
          </div>
        )}

        {data.map((row, i) => (
          <div
            key={row.id || i}
            onClick={(e) => {
              if (showCheckbox && (e.target as HTMLElement).closest('input[type="checkbox"]')) return;
              onRowClick?.(row);
            }}
            className={`min-w-0 overflow-hidden rounded-xl border border-ui-border bg-ui-surface p-3 shadow-ui-sm transition-colors ${onRowClick ? 'cursor-pointer active:bg-ui-page-alt' : ''} ${selectedIds?.has(row.id || '') ? 'border-ui-primary bg-ui-primary-soft/30' : ''}`}
          >
            {showCheckbox && (
              <div className="mb-2 flex items-center" onClick={(e) => e.stopPropagation()}>
                <input
                  type="checkbox"
                  aria-label="Select row"
                  checked={!!(row.id && selectedIds?.has(row.id))}
                  onChange={() => row.id && toggleRow(row.id)}
                  className="h-5 w-5 rounded border-ui-border-strong text-ui-primary focus:ring-ui-ring"
                />
              </div>
            )}

            <dl className="divide-y divide-ui-border">
              {columns.map((col) => (
                <div
                  key={col.key}
                  className="grid min-w-0 grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)] items-start gap-3 py-2 first:pt-0 last:pb-0"
                >
                  <dt className="min-w-0 break-words text-xs font-semibold text-ui-muted">{col.header}</dt>
                  <dd className="min-w-0 break-words text-sm text-ui-text [&>*]:max-w-full">
                    {renderCell(row, col)}
                  </dd>
                </div>
              ))}
            </dl>
          </div>
        ))}
      </div>

      <div className="hidden max-w-full overflow-x-auto overscroll-x-contain rounded-xl touch-pan-x [scrollbar-gutter:stable] sm:block">
        <table className="w-full min-w-max text-sm">
          <thead>
            <tr className="border-b border-ui-border bg-ui-page-alt/70">
              {showCheckbox && (
                <th className="w-10 px-4 py-3">
                  <input type="checkbox" checked={!!allSelected} onChange={toggleAll}
                    className="h-4 w-4 rounded border-ui-border-strong text-ui-primary focus:ring-ui-ring" />
                </th>
              )}
              {columns.map((col) => (
                <th
                  key={col.key}
                  className={`whitespace-nowrap px-4 py-3 text-start text-xs font-semibold uppercase tracking-wider text-ui-muted ${col.className || ''}`}
                >
                  {col.header}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-ui-border">
            {data.map((row, i) => (
              <tr
                key={row.id || i}
                onClick={(e) => {
                  if (showCheckbox && (e.target as HTMLElement).closest('input[type="checkbox"]')) return;
                  onRowClick?.(row);
                }}
                className={`hover:bg-ui-page-alt/60 transition-colors duration-150 ${onRowClick ? 'cursor-pointer' : ''} ${selectedIds?.has(row.id || '') ? 'bg-ui-primary-soft/50' : ''}`}
              >
                {showCheckbox && (
                  <td className="px-4 py-3" onClick={(e) => e.stopPropagation()}>
                    <input type="checkbox" checked={!!(row.id && selectedIds?.has(row.id))}
                      onChange={() => row.id && toggleRow(row.id)}
                      className="h-4 w-4 rounded border-ui-border-strong text-ui-primary focus:ring-ui-ring" />
                  </td>
                )}
                {columns.map((col) => (
                  <td key={col.key} className={`px-4 py-3 text-ui-text ${col.className || ''}`}>
                    {renderCell(row, col)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
