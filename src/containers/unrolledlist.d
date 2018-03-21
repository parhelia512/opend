/**
 * Unrolled Linked List.
 * Copyright: © 2015 Economic Modeling Specialists, Intl.
 * Authors: Brian Schott
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 */

module containers.unrolledlist;

private import containers.internal.node : shouldAddGCRange;
private import stdx.allocator.mallocator : Mallocator;

/**
 * Unrolled Linked List.
 *
 * Nodes are (by default) sized to fit within a 64-byte cache line. The number
 * of items stored per node can be read from the $(B nodeCapacity) field.
 * See_also: $(LINK http://en.wikipedia.org/wiki/Unrolled_linked_list)
 * Params:
 *     T = the element type
 *     Allocator = the allocator to use. Defaults to `Mallocator`.
 *     supportGC = true to ensure that the GC scans the nodes of the unrolled
 *         list, false if you are sure that no references to GC-managed memory
 *         will be stored in this container.
 *     cacheLineSize = Nodes will be sized to fit within this number of bytes.
 */
struct UnrolledList(T, Allocator = Mallocator,
	bool supportGC = shouldAddGCRange!T, size_t cacheLineSize = 64)
{
	this(this) @disable;

	private import stdx.allocator.common : stateSize;

	static if (stateSize!Allocator != 0)
	{
		/// No default construction if an allocator must be provided.
		this() @disable;

		/**
		 * Use the given `allocator` for allocations.
		 */
		this(Allocator allocator)
		in
		{
			assert(allocator !is null);
		}
		body
		{
			this.allocator = allocator;
		}
	}

	~this() nothrow
	{
		scope (failure) assert(false);
		clear();
	}

	/**
	 * Removes all items from the list
	 */
	void clear()
	{
		Node* prev;
		Node* cur = _front;
		while (cur !is null)
		{
			prev = cur;
			cur = cur.next;
			static if (!(is(T == class) || is(T == interface)))
				foreach (ref item; cur.items)
					typeid(T).destroy(&item);
			deallocateNode(prev);
		}
		_length = 0;
	}

	/**
	 * Inserts the given item into the end of the list.
	 *
	 * Returns: a pointer to the inserted item.
	 */
	T* insertBack(T item)
	{
		ContainerStorageType!T* result;
		if (_back is null)
		{
			assert (_front is null);
			_back = allocateNode(item);
			_front = _back;
			result = &_back.items[0];
		}
		else
		{
			size_t index = _back.nextAvailableIndex();
			if (index >= nodeCapacity)
			{
				Node* n = allocateNode(item);
				n.prev = _back;
				_back.next = n;
				_back = n;
				index = 0;
				result = &n.items[0];
			}
			else
			{
				_back.items[index] = item;
				_back.markUsed(index);
				result = &_back.items[index];
			}
		}
		_length++;
		assert (_back.registry <= fullBitPattern);
		return cast(T*) result;
	}

	/**
	 * Inserts the given range into the end of the list
	 */
	void insertBack(R)(auto ref R range)
	{
		foreach (ref r; range)
			insertBack(r);
	}

	/// ditto
	T* opOpAssign(string op)(T item) if (op == "~")
	{
		return insertBack(item);
	}

	/// ditto
	alias put = insertBack;

	/// ditto
	alias insert = insertBack;

	/**
	 * Inserts the given item in the frontmost available cell, which may put the
	 * item anywhere in the list as removal may leave gaps in list nodes. Use
	 * this only if the order of elements is not important.
	 *
	 * Returns: a pointer to the inserted item.
	 */
	T* insertAnywhere(T item) @trusted
	{
		Node* n = _front;
		while (n !is null)
		{
			size_t i = n.nextAvailableIndex();
			if (i >= nodeCapacity)
			{
				if (n.next is null)
				{
					assert (n is _back);
					break;
				}
				n = n.next;
				continue;
			}
			n.items[i] = item;
			n.markUsed(i);
			_length++;
			assert (n.registry <= fullBitPattern);
			return cast(T*) &n.items[i];
		}
		n = allocateNode(item);
		n.items[0] = item;
		n.markUsed(0);
		_length++;
		auto retVal = cast(T*) &n.items[0];
		if (_front is null)
		{
			assert(_back is null);
			_front = n;
		}
		else
			_back.next = n;
		_back = n;
		assert (_back.registry <= fullBitPattern);
		return retVal;
	}

	/// Returns: the length of the list
	size_t length() const nothrow pure @property @safe @nogc
	{
		return _length;
	}

	/// Returns: true if the list is empty
	bool empty() const nothrow pure @property @safe @nogc
	{
		return _length == 0;
	}

	/**
	 * Removes the first instance of the given item from the list.
	 *
	 * Returns: true if something was removed.
	 */
	bool remove(T item)
	{
		import containers.internal.backwards : popcnt;
		if (_front is null)
			return false;
		bool retVal;
		loop: for (Node* n = _front; n !is null; n = n.next)
		{
			foreach (i; 0 .. nodeCapacity)
			{
				if (!n.isFree(i) && n.items[i] == item)
				{
					n.markUnused(i);
					--_length;
					retVal = true;
					if (n.registry == 0)
						deallocateNode(n);
					else if (shouldMerge(n, n.next))
						mergeNodes(n, n.next);
					else if (shouldMerge(n.prev, n))
						mergeNodes(n.prev, n);
					break loop;
				}
			}
		}
		return retVal;
	}

	/// Pops the front item off of the list
	void popFront()
	{
		moveFront();
		assert (_front is null || _front.registry != 0);
	}

	/// Pops the front item off of the list and returns it
	T moveFront()
	in
	{
		assert (!empty());
		assert (_front.registry != 0);
	}
	body
	{
		import containers.internal.backwards : bsf;
		size_t index = bsf(_front.registry);
		T r = _front.items[index];
		_front.markUnused(index);
		_length--;
		if (_front.registry == 0)
		{
			auto f = _front;
			if (_front.next !is null)
				_front.next.prev = null;
			assert (_front.next !is _front);
			_front = _front.next;
			if (_front is null)
				_back = null;
			else
				assert (_front.registry <= fullBitPattern);
			deallocateNode(f);
			return r;
		}
		if (shouldMerge(_front, _front.next))
			mergeNodes(_front, _front.next);
		return r;
	}

	debug (EMSI_CONTAINERS) invariant
	{
		import std.string: format;
		assert (_front is null || _front.registry != 0, format("%x, %b", _front, _front.registry));
		assert (_front !is null || _back is null);
		if (_front !is null)
		{
			const(Node)* c = _front;
			while (c.next !is null)
				c = c.next;
			assert(c is _back, "_back pointer is wrong");
		}
	}

	/**
	 * Time complexity is O(1)
	 * Returns: the item at the front of the list
	 */
	ref inout(T) front() inout nothrow @property
	in
	{
		assert (!empty);
		assert (_front.registry != 0);
	}
	body
	{
		import containers.internal.backwards : bsf;

		immutable size_t index = bsf(_front.registry);
		return *(cast(typeof(return)*) &_front.items[index]);
	}

	/**
	 * Time complexity is O(nodeCapacity), where the nodeCapacity
	 * is the number of items in a single list node. It is a constant
	 * related to the cache line size.
	 * Returns: the item at the back of the list
	 */
	ref inout(T) back() inout nothrow @property
	in
	{
		assert (!empty);
		assert (!_back.empty);
	}
	body
	{
		size_t i = nodeCapacity - 1;
		while (_back.isFree(i))
			i--;
		return *(cast(typeof(return)*) &_back.items[i]);
	}

	/// Pops the back item off of the list.
	void popBack()
	{
		moveBack();
	}

	/// Removes an item from the back of the list and returns it.
	T moveBack()
	in
	{
		assert (!empty);
		assert (!_back.empty);
	}
	body
	{
		import containers.internal.backwards : popcnt;
		size_t i = nodeCapacity - 1;
		while (_back.isFree(i))
		{
			if (i == 0)
				break;
			else
				i--;
		}
		assert (!_back.isFree(i));
		T item = _back.items[i];
		_back.markUnused(i);
		_length--;
		if (_back.registry == 0)
		{
			deallocateNode(_back);
			return item;
		}
		else if (shouldMerge(_back.prev, _back))
			mergeNodes(_back.prev, _back);
		return item;
	}

	/// Returns: a range over the list
	auto opSlice(this This)() const nothrow pure @nogc @trusted
	{
		return Range!(This)(_front);
	}

	static struct Range(ThisT)
	{
		@disable this();

		this(inout(Node)* current)
		{
			import containers.internal.backwards : bsf;
			import std.format:format;

			this.current = current;
			if (current !is null)
			{
				index = bsf(current.registry);
				assert (index < nodeCapacity);
			}
			else
				current = null;
		}

		ref ET front() const nothrow @property @trusted @nogc
		{
			return *(cast(ET*) &current.items[index]);
			//return cast(T) current.items[index];
		}

		void popFront() nothrow pure @safe @nogc
		{
			index++;
			while (true)
			{

				if (index >= nodeCapacity)
				{
					current = current.next;
					if (current is null)
						return;
					index = 0;
				}
				else
				{
					if (current.isFree(index))
						index++;
					else
						return;
				}
			}
		}

		bool empty() const nothrow pure @property @safe @nogc
		{
			return current is null;
		}

		Range save() const nothrow pure @property @safe @nogc
		{
			return this;
		}

	private:

		alias ET = ContainerElementType!(ThisT, T);
		const(Node)* current;
		size_t index;
	}

private:

	import stdx.allocator: make, dispose;
	import containers.internal.node : FatNodeInfo, shouldAddGCRange,
		fullBits, shouldNullSlot;
	import containers.internal.storage_type : ContainerStorageType;
	import containers.internal.element_type : ContainerElementType;
	import containers.internal.mixins : AllocatorState;

	alias N = FatNodeInfo!(T.sizeof, 2, cacheLineSize);
	enum size_t nodeCapacity = N[0];
	alias BookkeepingType = N[1];
	enum fullBitPattern = fullBits!(BookkeepingType, nodeCapacity);
	enum bool useGC = supportGC && shouldAddGCRange!T;

	Node* _back;
	Node* _front;
	size_t _length;
	mixin AllocatorState!Allocator;

	Node* allocateNode(T item)
	{
		Node* n = make!Node(allocator);
		static if (useGC)
		{
			import core.memory: GC;
			GC.addRange(n, Node.sizeof);
		}
		n.items[0] = item;
		n.markUsed(0);
		return n;
	}

	void deallocateNode(Node* n)
	{
		if (n.prev !is null)
			n.prev.next = n.next;
		if (n.next !is null)
			n.next.prev = n.prev;
		if (_front is n)
			_front = n.next;
		if (_back is n)
			_back = n.prev;

		allocator.dispose(n);
		static if (useGC)
		{
			import core.memory: GC;
			GC.removeRange(n);
		}
	}

	static bool shouldMerge(const Node* first, const Node* second)
	{
		import containers.internal.backwards : popcnt;

		if (first is null || second is null)
			return false;
		immutable f = popcnt(first.registry);
		immutable s = popcnt(second.registry);
		return f + s <= nodeCapacity;
	}

	void mergeNodes(Node* first, Node* second)
	in
	{
		assert (first !is null);
		assert (second !is null);
		assert (second is first.next);
	}
	body
	{
		import containers.internal.backwards : bsf;
		size_t i;
		ContainerStorageType!T[nodeCapacity] temp;
		foreach (j; 0 .. nodeCapacity)
			if (!first.isFree(j))
				temp[i++] = first.items[j];
		foreach (j; 0 .. nodeCapacity)
			if (!second.isFree(j))
				temp[i++] = second.items[j];
		first.items[0 .. i] = temp[0 .. i];
		first.registry = 0;
		foreach (k; 0 .. i)
			first.markUsed(k);
		assert (first.registry <= fullBitPattern);
		deallocateNode(second);
	}

	static struct Node
	{
		size_t nextAvailableIndex() const nothrow pure @safe @nogc
		{
			import containers.internal.backwards : bsf;
			static if (BookkeepingType.sizeof < uint.sizeof)
				return bsf(~(cast(uint) registry));
			else
				return bsf(~registry);
		}

		void markUsed(size_t index) nothrow pure @safe @nogc
		{
			registry |= (BookkeepingType(1) << index);
		}

		void markUnused(size_t index) nothrow pure @safe @nogc
		{
			registry &= ~(BookkeepingType(1) << index);
			static if (shouldNullSlot!T)
				items[index] = null;
		}

		bool empty() const nothrow pure @safe @nogc
		{
			return registry == 0;
		}

		bool isFree(size_t index) const nothrow pure @safe @nogc
		{
			return (registry & (BookkeepingType(1) << index)) == 0;
		}

		debug(EMSI_CONTAINERS) invariant()
		{
			import std.string : format;
			assert (registry <= fullBitPattern, format("%016b %016b", registry, fullBitPattern));
			assert (prev !is &this);
			assert (next !is &this);
		}

		BookkeepingType registry;
		ContainerStorageType!T[nodeCapacity] items;
		Node* prev;
		Node* next;
	}
}

version(emsi_containers_unittest) unittest
{
	import std.algorithm : equal;
	import std.range : iota;
	import std.string : format;
	UnrolledList!ubyte l;
	static assert (l.Node.sizeof <= 64);
	assert (l.empty);
	l.insert(0);
	assert (l.length == 1);
	assert (!l.empty);
	foreach (i; 1 .. 100)
		l.insert(cast(ubyte) i);
	assert (l.length == 100);
	assert (equal(l[], iota(100)));
	foreach (i; 0 .. 100)
		assert (l.remove(cast(ubyte) i), format("%d", i));
	assert (l.length == 0, format("%d", l.length));
	assert (l.empty);

	assert(*l.insert(1) == 1);
	assert(*l.insert(2) == 2);
	assert (l.remove(1));
	assert (!l.remove(1));
	assert (!l.empty);

	UnrolledList!ubyte l2;
	l2.insert(1);
	l2.insert(2);
	l2.insert(3);
	assert (l2.front == 1);
	l2.popFront();
	assert (l2.front == 2);
	assert (equal(l2[], [2, 3]));
	l2.popFront();
	assert (equal(l2[], [3]));
	l2.popFront();
	assert (l2.empty, format("%d", l2.front));
	assert (equal(l2[], cast(int[]) []));
	UnrolledList!int l3;
	foreach (i; 0 .. 200)
		l3.insert(i);
	foreach (i; 0 .. 200)
	{
		auto x = l3.moveFront();
		assert (x == i, format("%d %d", i, x));
	}
	assert (l3.empty);
	foreach (i; 0 .. 200)
		l3.insert(i);
	assert (l3.length == 200);
	foreach (i; 0 .. 200)
	{
		assert (l3.length == 200 - i);
		auto x = l3.moveBack();
		assert (x == 200 - i - 1, format("%d %d", 200 - 1 - 1, x));
	}
	assert (l3.empty);
}

version(emsi_containers_unittest) unittest
{
	struct A { int a; int b; }
	UnrolledList!(const(A)) objs;
	objs.insert(A(10, 11));
	static assert (is (typeof(objs.front) == const));
	static assert (is (typeof(objs[].front) == const));
}

version(emsi_containers_unittest) unittest
{
	static class A
	{
		int a;
		int b;

		this(int a, int b)
		{
			this.a = a;
			this.b = b;
		}
	}

	UnrolledList!(A) objs;
	objs.insert(new A(10, 11));
}

// Issue #52
version(emsi_containers_unittest) unittest
{
	UnrolledList!int list;
	list.insert(0);
	list.insert(0);
	list.insert(0);
	list.insert(0);
	list.insert(0);

	foreach (ref it; list[])
		it = 1;

	foreach (it; list[])
		assert(it == 1);
}

// Issue #53
version(emsi_containers_unittest) unittest
{
	UnrolledList!int ints;
	ints.insertBack(0);
	ints.insertBack(0);

	ints.front = 1;
	ints.back = 11;

	assert(ints.front == 1);
	assert(ints.back == 11);
}
