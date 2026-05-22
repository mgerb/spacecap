# Store

The store implements similar patterns to that of Redux, although state change is
not immutable. The state MUST only be mutated in the `update` function, because
there is a lock around the update. This is necessary because it runs
independently of the UI thread.

## Main Store

`Store` owns the global application state, the message queue, and the effect
thread pool. Messages are dispatched to the main store, processed by the
appropriate child store `update` function, and then any effects declared for
that message are scheduled. Effects run after the `update` function,
asynchronously on the effect thread pool.

## Child Stores

A child store is a domain-specific slice of the main store. It consists of:

- `Message` - a union of domain messages that can be dispatched (like Redux actions).
- `State` - the state owned by the child store.
- `update` - the only place the child store mutates its state in response to
  messages (like Redux reducer).
- `Message.effects` - optional side effects that run after a message is handled.

Child stores are registered in `Store.ChildStores`. The main store uses that
list to execute updates and discover effect declarations.
