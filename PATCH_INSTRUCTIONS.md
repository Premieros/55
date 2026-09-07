# Cashier Hardening UI integration

Production database hardening is already applied. Add these files to the same paths.

## 1) Layout.tsx
Add:
`import { ApprovalInbox } from './ApprovalInbox';`

Inside the header actions, immediately before the Active orders button, add:
`<ApprovalInbox ar={ar} />`

## 2) PaymentPanel.tsx
Add:
`import { CashierDiscountApprovalCard } from './CashierDiscountApprovalCard';`

Before the payment-method grid, add:
```tsx
<CashierDiscountApprovalCard
  subtotal={p.subtotal}
  currentType={p.discountType}
  ar={isAr}
  onApproved={(type, amount) => {
    p.onDiscountTypeChange(type);
    p.onDiscountAmountChange(amount);
  }}
/>
```

## 3) Receipt printing
Before printing a completed sale, call:
`supabase.rpc('authorize_sale_print', { p_sale_id: saleId, p_approval_request_id: approvalRequestId ?? null })`
Only print when `success === true`.
On `MANAGER_APPROVAL_REQUIRED`, create a `reprint` request with entity_id = saleId and wait for manager approval.

## 4) Commit
Suggested commit:
`feat: add cashier manager approval workflow and anti-fraud controls`
