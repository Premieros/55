type BranchBadgeProps = {
  name?: string | null;
};

export function BranchBadge({ name }: BranchBadgeProps) {
  const label = name?.trim();
  return (
    <span className="inline-flex items-center rounded-full border border-ui-border bg-ui-page-alt px-2.5 py-1 text-xs font-medium text-ui-text">
      {label || '—'}
    </span>
  );
}
