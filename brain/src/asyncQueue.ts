/**
 * A minimal unbounded async queue. The Agent SDK reads user messages from an
 * async iterable, so each spoken question is pushed here and the SDK pulls it
 * when the session is ready for the next turn.
 */
export class AsyncQueue<Item> implements AsyncIterable<Item> {
  private readonly bufferedItems: Item[] = [];
  private readonly waitingConsumers: Array<(result: IteratorResult<Item>) => void> = [];
  private isClosed = false;

  push(item: Item): void {
    if (this.isClosed) return;
    const waitingConsumer = this.waitingConsumers.shift();
    if (waitingConsumer) {
      waitingConsumer({ value: item, done: false });
    } else {
      this.bufferedItems.push(item);
    }
  }

  close(): void {
    this.isClosed = true;
    for (const waitingConsumer of this.waitingConsumers.splice(0)) {
      waitingConsumer({ value: undefined, done: true });
    }
  }

  [Symbol.asyncIterator](): AsyncIterator<Item> {
    return {
      next: () => {
        const bufferedItem = this.bufferedItems.shift();
        if (bufferedItem !== undefined) {
          return Promise.resolve({ value: bufferedItem, done: false });
        }
        if (this.isClosed) {
          return Promise.resolve({ value: undefined, done: true });
        }
        return new Promise((resolve) => this.waitingConsumers.push(resolve));
      },
    };
  }
}
