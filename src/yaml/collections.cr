# :nodoc:
#
# The scanner's token queue and the emitter's event queue: libyaml's `QUEUE`
# macros. The queued items are `@buffer[@head...@tail]`, and
# `yaml_queue_extend` makes room at the tail by moving them to the front or
# by doubling the buffer. Dequeued slots are cleared, so their strings can be
# collected (libyaml frees each dequeued token and event). Indices never
# leave `0..@capacity`, so they use wrapping arithmetic (no overflow check).
class YAML::Queue(T)
  INITIAL_CAPACITY = 4

  # Allocated by the first `#<<`.
  @buffer = Pointer(T).null
  @capacity = 0
  @head = 0
  @tail = 0

  @[AlwaysInline]
  def size : Int32
    @tail &- @head
  end

  @[AlwaysInline]
  def empty? : Bool
    @tail == @head
  end

  # The item at the head of the queue.
  @[AlwaysInline]
  def first : T
    raise IndexError.new if empty?
    @buffer[@head]
  end

  # The item *index* positions after the head.
  @[AlwaysInline]
  def [](index : Int32) : T
    raise IndexError.new unless 0 <= index < size
    @buffer[@head + index]
  end

  def each(& : T ->) : Nil
    i = @head
    while i < @tail
      yield @buffer[i]
      i += 1
    end
  end

  # DEQUEUE. An emptied queue starts over at the front of the buffer, so
  # `extend_queue` rarely has items to move.
  @[AlwaysInline]
  def shift : T
    raise IndexError.new if empty?
    item = @buffer[@head]
    (@buffer + @head).clear
    @head &+= 1
    if @head == @tail
      @head = 0
      @tail = 0
    end
    item
  end

  # ENQUEUE
  @[AlwaysInline]
  def <<(item : T) : self
    extend_queue if @tail == @capacity
    @buffer[@tail] = item
    @tail &+= 1
    self
  end

  # QUEUE_INSERT: inserts *item* *index* positions after the head.
  @[AlwaysInline]
  def insert(index : Int32, item : T) : self
    raise IndexError.new unless 0 <= index <= size
    extend_queue if @tail == @capacity
    at = @head &+ index
    # Usually only an item or two follow the insertion point.
    i = @tail
    while i > at
      @buffer[i] = @buffer[i &- 1]
      i &-= 1
    end
    @buffer[at] = item
    @tail &+= 1
    self
  end

  # yaml_queue_extend
  private def extend_queue : Nil
    if @head == 0
      capacity = @capacity == 0 ? INITIAL_CAPACITY : @capacity * 2
      buffer = Pointer(T).malloc(capacity)
      buffer.copy_from(@buffer, @capacity) if @capacity > 0
      @buffer = buffer
      @capacity = capacity
    else
      @buffer.move_from(@buffer + @head, size)
      # The vacated tail still holds copies of the moved items.
      (@buffer + size).clear(@head)
      @tail -= @head
      @head = 0
    end
  end
end

# :nodoc:
#
# The state, indentation and mark stacks of the scanner, parser and emitter:
# libyaml's `STACK` macros (`PUSH`, `POP`). Unlike `Array#push` and
# `Array#pop`, both are inlined at the call site, as the macros are in libyaml.
# `@size` never leaves `0..@capacity`, so it uses wrapping arithmetic.
class YAML::Stack(T)
  INITIAL_CAPACITY = 4

  # Allocated by the first `#push`.
  @buffer = Pointer(T).null
  @capacity = 0
  @size = 0

  # PUSH
  @[AlwaysInline]
  def push(item : T) : self
    extend_stack if @size == @capacity
    @buffer[@size] = item
    @size &+= 1
    self
  end

  @[AlwaysInline]
  def <<(item : T) : self
    push(item)
  end

  # POP
  @[AlwaysInline]
  def pop : T
    raise IndexError.new if @size == 0
    @size &-= 1
    @buffer[@size]
  end

  # yaml_stack_extend
  private def extend_stack : Nil
    capacity = @capacity == 0 ? INITIAL_CAPACITY : @capacity * 2
    buffer = Pointer(T).malloc(capacity)
    buffer.copy_from(@buffer, @capacity) if @capacity > 0
    @buffer = buffer
    @capacity = capacity
  end
end
