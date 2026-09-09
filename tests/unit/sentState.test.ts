import { describe, expect, it } from 'vitest';
import { computeSentState } from '@/features/pos/utils/sentState';
import { cartLineKey } from '@/features/pos/utils/cart';
import type { CartItem, OrderItem, Product } from '@/lib/types';
import type { KitchenSendItem } from '@/features/pos/types';

const product = (id: string, name = id) => ({
  id,
  name,
  name_en: name,
  sale_price: 10,
} as Product);

const cartItem = (p: Product, quantity = 1, modifierIds: string[] = [], note?: string) => ({
  product: p,
  unit_name: 'piece',
  quantity,
  unit_price: 10,
  discount_amount: 0,
  bonus_quantity: 0,
  modifier_option_ids: modifierIds,
  item_note: note,
} as CartItem);

const orderItem = (id: string, productId: string, quantity = 1, modifierIds: string[] = [], note: string | null = null): OrderItem => ({
  id,
  order_id: 'order-1',
  product_id: productId,
  unit_name: 'piece',
  quantity,
  unit_price: 10,
  discount_amount: 0,
  bonus_quantity: 0,
  total: quantity * 10,
  notes: note,
  created_at: '2026-09-02T00:00:00.000Z',
  modifier_option_ids: modifierIds,
  modifiers_snapshot: [],
});

const kitchenSend = (orderItemId: string, productId: string, quantity = 1) => ({
  send_id: `send-${orderItemId}`,
  order_item_id: orderItemId,
  product_id: productId,
  product_name: productId,
  unit_name: 'piece',
  quantity,
  unit_price: 10,
  discount_amount: 0,
  bonus_quantity: 0,
  total: quantity * 10,
  notes: null,
} as KitchenSendItem);

describe('computeSentState', () => {
  it('keeps a newly added product unsent after earlier lines were sent', () => {
    const burger = product('burger');
    const fries = product('fries');
    const burgerLine = cartItem(burger);
    const friesLine = cartItem(fries);
    const cart = [burgerLine, friesLine];
    const items = [orderItem('item-burger', 'burger'), orderItem('item-fries', 'fries')];

    const state = computeSentState(
      cart,
      items,
      new Set(['item-burger']),
      [kitchenSend('item-burger', 'burger')],
    );

    expect(state[cartLineKey(burgerLine)].sent).toBe(true);
    expect(state[cartLineKey(burgerLine)].newQty).toBe(0);
    expect(state[cartLineKey(friesLine)].sent).toBe(false);
    expect(state[cartLineKey(friesLine)].newQty).toBe(1);
  });

  it('does not leak a stale session send onto a newly added line', () => {
    const burger = product('burger');
    const burgerLine = cartItem(burger);
    const cart = [burgerLine];
    const items: OrderItem[] = [];

    const state = computeSentState(
      cart,
      items,
      new Set(),
      [kitchenSend('old-order-item', 'burger')],
    );

    expect(state[cartLineKey(burgerLine)].sent).toBe(false);
    expect(state[cartLineKey(burgerLine)].newQty).toBe(1);
  });

  it('preserves persisted sent state for an existing line', () => {
    const burger = product('burger');
    const burgerLine = cartItem(burger, 2);
    const cart = [burgerLine];
    const items = [orderItem('item-burger', 'burger', 2)];

    const state = computeSentState(
      cart,
      items,
      new Set(['item-burger']),
      [kitchenSend('item-burger', 'burger', 1)],
    );

    expect(state[cartLineKey(burgerLine)].sentQty).toBe(2);
    expect(state[cartLineKey(burgerLine)].newQty).toBe(0);
    expect(state[cartLineKey(burgerLine)].sent).toBe(true);
  });

  it('keeps Single and Double of the same product as separate kitchen lines', () => {
    const burger = product('burger');
    const single = cartItem(burger, 1, ['single']);
    const double = cartItem(burger, 1, ['double']);
    const items = [
      orderItem('item-single', 'burger', 1, ['single']),
      orderItem('item-double', 'burger', 1, ['double']),
    ];

    const state = computeSentState(
      [single, double],
      items,
      new Set(['item-single']),
      [kitchenSend('item-single', 'burger')],
    );

    expect(state[cartLineKey(single)].sent).toBe(true);
    expect(state[cartLineKey(double)].sent).toBe(false);
    expect(state[cartLineKey(double)].newQty).toBe(1);
  });
});
