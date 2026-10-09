# Interface design for testability

Good interfaces make testing natural:

1. **Accept dependencies, don't create them** — pass external dependencies in rather than constructing them inside.

2. **Return results, don't produce side effects**

   ```typescript
   // Testable
   function calculateDiscount(cart): Discount {}

   // Hard to test
   function applyDiscount(cart): void {
     cart.total -= discount;
   }
   ```

3. **Small surface area**
   - Fewer methods = fewer tests needed
   - Fewer params = simpler test setup

## Deep modules

Prefer deep modules (small interface, most of the complexity hidden inside) over shallow ones (large interface, thin pass-through implementation). When designing interfaces, ask:

- Can I reduce the number of methods?
- Can I simplify the parameters?
- Can I hide more complexity inside?
