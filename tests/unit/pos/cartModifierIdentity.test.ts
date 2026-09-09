import { describe, expect, it } from 'vitest';
import { cartLineKey, orderItemLineKey, sameCartConfiguration, cartToItems } from '@/features/pos/utils/cart';
import type { CartItem, OrderItem, Product } from '@/lib/types';

const burger = { id: 'product-burger', name: 'Burger', sale_price: 100 } as Product;

function item(optionIds: string[], note?: string): CartItem {
  return {
    product: burger,
    unit_name: 'piece',
    quantity: 1,
    unit_price: 100,
    discount_amount: 0,
    bonus_quantity: 0,
    modifier_option_ids: optionIds,
    modifiers: optionIds.map((id) => ({ id, group_name: 'Size', name: id, price_delta: 0 })),
    item_note: note,
  } as CartItem;
}

describe('POS modifier cart identity', () => {
  it('keeps Single and Double of the same product as different lines', () => {
    const single = item(['single']);
    const double = item(['double']);

    expect(cartLineKey(single)).not.toBe(cartLineKey(double));
    expect(sameCartConfiguration(single, double)).toBe(false);
  });

  it('normalizes modifier ordering while preserving the same configuration', () => {
    const a = item(['double', 'extra-cheese']);
    const b = item(['extra-cheese', 'double']);

    expect(cartLineKey(a)).toBe(cartLineKey(b));
    expect(sameCartConfiguration(a, b)).toBe(true);
  });

  it('treats notes as part of the line identity', () => {
    const normal = item(['double']);
    const noOnion = item(['double'], 'No onion');

    expect(cartLineKey(normal)).not.toBe(cartLineKey(noOnion));
  });

  it('preserves trusted modifier option ids in the order payload', () => {
    const payload = cartToItems([item(['double', 'extra-cheese'], 'No onion')]);

    expect(payload[0].modifier_option_ids).toEqual(['double', 'extra-cheese']);
    expect(payload[0].notes).toBe('No onion');
  });

  it('matches order-item identity to the equivalent cart configuration', () => {
    const cartItem = item(['double', 'extra-cheese'], 'No onion');
    const orderItem = {
      product_id: burger.id,
      modifier_option_ids: ['extra-cheese', 'double'],
      notes: 'No onion',
    } as OrderItem;

    expect(cartLineKey(cartItem)).toBe(orderItemLineKey(orderItem));
  });
});
