import { beforeEach, describe, expect, it, vi } from 'vitest';
import { rpc } from '@/api/rpc';
import { sendOrderToKitchen } from '@/features/pos/services/kitchen';

vi.mock('@/api/rpc', () => ({
  rpc: vi.fn(),
}));

const mockedRpc = vi.mocked(rpc);

describe('kitchen ticket payload', () => {
  beforeEach(() => {
    mockedRpc.mockReset();
  });

  it('keeps authoritative delta quantity and includes modifiers and notes in the printed name', async () => {
    mockedRpc.mockResolvedValue({
      data: {
        success: true,
        order_id: 'order-1',
        items_sent_count: 1,
        all_sent: true,
        sent: [{
          send_id: 'send-1',
          order_item_id: 'item-1',
          product_id: 'product-1',
          product_name: 'Burger',
          unit_name: 'piece',
          quantity: 2,
          unit_price: 100,
          discount_amount: 0,
          bonus_quantity: 0,
          total: 200,
          notes: 'بدون بصل',
          modifiers: [{
            group_id: 'group-1',
            group_name: 'Extras',
            group_name_en: 'Extras',
            option_id: 'option-1',
            option_name: 'جبنة إضافية',
            option_name_en: 'Extra cheese',
            price_delta: 20,
          }],
        }],
      },
      error: null,
    } as never);

    const result = await sendOrderToKitchen({ p_order_id: 'order-1' });

    expect(result.success).toBe(true);
    expect(result.sent?.[0]?.quantity).toBe(2);
    expect(result.sent?.[0]?.product_name).toContain('Burger');
    expect(result.sent?.[0]?.product_name).toContain('جبنة إضافية');
    expect(result.sent?.[0]?.product_name).toContain('بدون بصل');
  });
});
