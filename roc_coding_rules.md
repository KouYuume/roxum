# Development Rules for Effects and Pure Functions in Roc

## Core Principle

Roc application code should use pure functions by default.

Effects are unavoidable in practical applications, but their scope should remain as narrow as possible. The goal is not to eliminate effects.

> **Keep effects at the boundaries and decisions in pure functions.**

## Roc Terminology and Syntax

Roc infers whether a function is pure or effectful.

- A pure function type uses `->`.
- An effectful function type uses `=>`.
- A trailing `!` is the naming convention for a function that performs effects.

The `!` suffix does not make a function effectful by itself. Calling an effectful function makes the caller effectful, whether the effect is performed directly or through another function. An effectful function should end in `!` so that its behavior is visible at the call site.

```roc
calculate_total : Order -> Amount
calculate_total = |order| ...

load_order! : OrderId => Result(Order, LoadErr)
load_order! = |id| ...
```

The examples in this document use `...` as illustrative pseudocode where the implementation is not relevant.

## Rules

### 1. Default to Pure Functions

Implement a function as pure when interaction with the external world is not essential to its responsibility.

Calculations, validation, transformations, and decisions should normally be pure:

```roc
calculate_total = |order| ...
validate_order = |order| ...
decide_discount = |customer, order| ...
create_invoice = |order| ...
```

Do not make a function effectful merely because its caller is effectful.

### 2. Restrict Effectful Functions and `!` to Real Effects

Use effectful functions for interactions such as:

- Database access
- HTTP and other network access
- File-system access
- Standard input and output
- Reading the current time
- Generating randomness
- Calling external services
- Other effects provided by the platform
- Calling an effectful function, including an effectful callback

```roc
load_order! = |id| ...
save_order! = |order| ...
send_email! = |email| ...
```

Functions that only calculate, validate, transform, or decide should normally remain pure and should not have names ending in `!`.

Roc treats crashes, memory allocation, and programmer-facing `dbg` and `expect` output as permitted in pure functions. Do not confuse `dbg` or `expect` with application logging: observable production logging belongs in an effectful function.

### 3. Do Not Spread Effectfulness Beyond the Required Call Path

A function that calls an effectful function must itself be effectful. This is necessary propagation and should not be avoided.

The design goal is to keep unrelated calculations outside that effectful call path. An effectful function can freely call pure functions:

```roc
checkout! = |order_id| {
    order = load_order!(order_id)

    validated = validate_order(order)
    priced = calculate_total(validated)
    invoice = create_invoice(priced)

    save_invoice!(invoice)
}
```

The fact that `checkout!` is effectful does not require these functions to become effectful:

```text
validate_order
calculate_total
create_invoice
```

### 4. Separate I/O from Decision Logic

Prefer the following structure when the workflow permits it:

```text
Effect
  ↓
Read input or external state
  ↓
──────────────────
Pure decision logic
──────────────────
  ↓
Apply the result externally
  ↓
Effect
```

In particular, separate:

- Fetching data from evaluating that data
- Reading external state from transforming values
- Calculating a result from storing it
- Deciding what should happen from performing it

### 5. Express Domain Logic as State Transitions

Represent domain logic as a pure transformation whenever possible:

```text
Input -> Output
```

For stateful domains, prefer a result that makes state changes, rejection, and follow-up events explicit:

```text
State + Command -> Result({ state, events }, DomainError)
```

```roc
cancel_order : Order, CancelCommand
    -> Result({ order : Order, events : List(OrderEvent) }, CancelError)

cancel_order = |order, command| ...
```

Avoid mixing the domain decision directly into I/O when it can be extracted:

```roc
cancel_order! = |order_id| {
    order = load_order!(order_id)

    # Domain rules mixed into orchestration

    save_order!(...)
}
```

Instead, let the effectful boundary load and save data while a pure function decides the transition and returns any events or actions that the boundary should perform.

### 6. Keep Effectful Entry Points Thin

It is expected for high-level entry points such as these to be effectful:

```text
main!
handle_request!
checkout!
```

Their primary responsibility should be orchestration:

1. Obtain required values using effects.
2. Pass those values to pure functions.
3. Interpret the result and perform the required effects.

Do not place large amounts of calculation, validation, or domain decision logic directly inside an effectful entry point.

Some workflows necessarily alternate between effects and decisions more than once. In those cases, keep the orchestration effectful and extract each decision step into a pure function where practical.

### 7. Treat New Effectfulness as a Design Signal

When a previously pure function needs to become effectful, first ask:

> Does this function itself need to perform the effect?

If not, move the effect to an appropriate boundary and pass the resulting value into the pure function.

Prefer:

```roc
data = load_data!()
result = calculate(data)
save_result!(result)
```

Avoid:

```roc
calculate! = || {
    data = load_data!()

    # A calculation that could otherwise be pure
}
```

Changing a function from `->` to `=>`, or adding `!` because its implementation now performs an effect, should prompt this design review.

### 8. Do Not Hide Dependencies Inside Effectful Helpers

Implicitly obtaining dependencies inside a helper makes the helper effectful and obscures what its result depends on.

Avoid this when the dependencies can reasonably be supplied by the caller:

```roc
calculate_price! = |order| {
    config = load_config!()
    now = current_time!()
    customer = load_customer!()

    ...
}
```

Prefer explicit inputs:

```roc
calculate_price = |order, config, now, customer| ...
```

Acquire the values at an effectful boundary, then pass them to the pure decision logic. This keeps the decision referentially transparent and makes its dependencies visible in its type.

Do not force every dependency into a preloaded value when the workflow genuinely requires conditional I/O. An effectful port or callback can be appropriate, but the decision logic that does not require it should still be extracted.

### 9. Preserve Transactional and Resource Boundaries

Do not sacrifice correctness merely to make more functions pure. Keep operations together when separation would break:

- Database transaction atomicity
- Snapshot consistency or concurrency checks
- Lock and resource lifetimes
- Streaming or incremental processing
- Workflows whose next I/O operation depends on an earlier result

The containing workflow may remain effectful in these cases. Extract pure decisions within the boundary without moving reads or writes across a boundary that provides required correctness guarantees.

## Code Review Guidance

Reducing the number of `!` suffixes is not the objective.

The important question is:

> **How much important application logic remains understandable and testable as pure functions?**

This structure is healthy:

```text
handle_request!
├─ load_user!
├─ load_order!
├─ validate_order
├─ calculate_price
├─ decide_discount
├─ transition_order
├─ save_order!
└─ publish_event!
```

This structure should trigger a closer review:

```text
handle_request!
├─ validate_order!
├─ calculate_price!
├─ decide_discount!
├─ transition_order!
└─ format_response!
```

Consider converting functions that do not need external access back into pure functions.

### Review Checklist

- Does the function directly or indirectly call an effectful function?
- Does its type use `->` or `=>` consistently with its implementation?
- Does an effectful function name end in `!`?
- Can calculation, validation, transformation, or decision logic be extracted?
- Can time, configuration, or other dependencies be passed as values?
- Is effectfulness limited to the required call path?
- Would moving I/O break a transaction, consistency guarantee, or resource lifetime?
- Is the effectful function primarily orchestrating reads, decisions, and writes?

## Decision Order

Use the following order when designing a function:

1. Can this operation be written as a pure function?
2. Can required values be passed explicitly as arguments?
3. Can the effect be moved to an appropriate caller or boundary?
4. If interaction with the external world is still required, make the function effectful, use `=>` in its type annotation, and end its name in `!`.

Do not add effects casually, but do not avoid necessary effects at the expense of correctness. Make required effects explicit and limit their scope.

## Summary

The target architecture is a functional core surrounded by an effectful shell:

```text
Effectful Shell
      ↓
   Pure Core
      ↓
Effectful Shell
```

Effects are unavoidable, but they do not need to spread throughout the application. Maximize the part of the program that can be understood from inputs and outputs alone, and concentrate interactions with the external world at explicit boundaries.
